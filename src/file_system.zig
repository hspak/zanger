//! Owns absolute directory listings and their preformatted display rows. Parent
//! navigation stays in the UI model, so listings never synthesize `.` or `..`.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const Path = std.fs.path;
const log = std.log.scoped(.file_system);

const symlink = @import("file_system/symlink.zig");
const test_support = @import("test_support.zig");

const directory_reader_buffer_bytes = 32 * 1024;
const directory_entry_batch_count = 128;

/// A directory entry whose name is owned by its containing `Listing`.
pub const Entry = struct {
    /// Owned by the containing `Listing`.
    name: []const u8 = "",
    /// Owned by the containing `Listing`; present only for symbolic links.
    link_target: ?[]const u8 = null,
    /// Whether navigation should treat the entry as a directory. This includes
    /// symbolic links whose targets resolve to directories.
    is_dir: bool = false,
    /// True only when the entry itself is a symbolic link.
    is_sym: bool = false,
    /// Null until previewed; otherwise whether the directory had no visible entries.
    is_empty: ?bool = null,

    /// Whether deletion should use directory rather than unlink semantics.
    pub fn deleteAsDirectory(self: Entry) bool {
        return self.is_dir and !self.is_sym;
    }
};

/// An owned, sorted directory snapshot with selection and display state.
pub const Listing = struct {
    /// Allocator used for all owned fields.
    alloc: Allocator,
    /// Owns all entry names and symbolic-link targets.
    strings: std.heap.ArenaAllocator,
    /// Owned absolute path.
    path: []const u8,
    /// Owned entries; names and optional link targets are backed by `strings`.
    entries: []Entry,
    /// Contains one bit per entry.
    selected: std.DynamicBitSetUnmanaged = .{},
    /// Cached population count for constant-time status rendering.
    selected_count: usize = 0,
    /// Display strings parallel to `entries`, backed by `row_storage`.
    rows: [][]const u8 = &.{},
    /// Owned capacity for every display row in one contiguous allocation.
    row_storage: []u8 = &.{},

    /// Frees the owned path, entries, row strings, and selection storage.
    pub fn deinit(self: *Listing) void {
        self.strings.deinit();
        self.alloc.free(self.entries);
        self.alloc.free(self.row_storage);
        self.alloc.free(self.rows);
        self.selected.deinit(self.alloc);
        self.alloc.free(self.path);
        self.* = undefined;
    }

    /// Chooses a UI cursor by name, then by fallback index, and otherwise the
    /// first entry. An empty listing uses index zero as the vxfw sentinel.
    pub fn cursorFor(
        self: *const Listing,
        preferred_name: ?[]const u8,
        fallback: ?usize,
    ) usize {
        if (preferred_name) |name| {
            for (self.entries, 0..) |entry, index| {
                if (std.mem.eql(u8, entry.name, name)) return index;
            }
        }
        return if (self.entries.len == 0)
            0
        else
            @min(fallback orelse 0, self.entries.len - 1);
    }

    /// Number of entries currently selected.
    pub fn selectedCount(self: Listing) usize {
        return self.selected_count;
    }

    /// Toggles one entry's selection. `index` must identify an entry.
    pub fn toggleSelected(self: *Listing, index: usize) void {
        std.debug.assert(index < self.entries.len);
        if (self.selected.isSet(index)) {
            self.selected.unset(index);
            self.selected_count -= 1;
        } else {
            self.selected.set(index);
            self.selected_count += 1;
        }
        self.refreshRow(index);
    }

    /// Clears every selected entry and updates their display rows.
    pub fn clearSelection(self: *Listing) void {
        if (self.selected_count == 0) return;
        var index: usize = 0;
        while (index < self.entries.len) : (index += 1) {
            if (!self.selected.isSet(index)) continue;
            self.selected.unset(index);
            self.refreshRow(index);
        }
        self.selected_count = 0;
    }

    /// Updates one directory's known emptiness and its display row.
    /// Asserts that `index` identifies a directory entry.
    pub fn setDirectoryEmpty(
        self: *Listing,
        index: usize,
        is_empty: bool,
    ) void {
        std.debug.assert(index < self.entries.len);
        std.debug.assert(self.entries[index].is_dir);
        if (self.entries[index].is_empty == is_empty) return;

        self.entries[index].is_empty = is_empty;
        self.refreshRow(index);
    }

    /// Rewrites every display row. Prefer `refreshRow` when only known
    /// entries changed.
    pub fn rebuildRows(self: *Listing) void {
        for (self.entries, 0..) |_, index| self.refreshRow(index);
    }

    fn initRows(self: *Listing) Allocator.Error!void {
        const rows = try self.alloc.alloc([]const u8, self.entries.len);
        errdefer self.alloc.free(rows);

        var storage_length: usize = 0;
        for (self.entries) |entry| {
            storage_length = std.math.add(
                usize,
                storage_length,
                rowCapacity(entry),
            ) catch return error.OutOfMemory;
        }
        const storage = try self.alloc.alloc(u8, storage_length);
        errdefer self.alloc.free(storage);

        var offset: usize = 0;
        for (rows, self.entries, 0..) |*row, entry, index| {
            const capacity = rowCapacity(entry);
            row.* = writeRow(
                storage[offset..][0..capacity],
                entry,
                self.selected.isSet(index),
            );
            offset += capacity;
        }
        self.rows = rows;
        self.row_storage = storage;
    }

    /// Rewrites one row's display text in place after its selection or known
    /// emptiness changed. The row allocation is unchanged, so the update is
    /// visible to already-rendered frame borrows only via the next draw.
    pub fn refreshRow(self: *Listing, index: usize) void {
        const entry = self.entries[index];
        const capacity = rowCapacity(entry);
        const buffer = @constCast(self.rows[index].ptr)[0..capacity];
        self.rows[index] = writeRow(buffer, entry, self.selected.isSet(index));
    }
};

/// Absolute path of the parent directory; `/` maps to itself.
/// The result is always owned by `alloc` (a fresh dupe).
pub fn parentPath(alloc: Allocator, path: []const u8) Allocator.Error![]const u8 {
    const without_trailing = std.mem.trimEnd(u8, path, "/");
    const normalized = if (without_trailing.len == 0) "/" else without_trailing;
    const parent = if (std.mem.eql(u8, normalized, "/"))
        "/"
    else
        Path.dirname(normalized) orelse "/";
    return alloc.dupe(u8, parent);
}

/// Returns an owned path formed by joining `path` and `name`.
pub fn joinPath(alloc: Allocator, path: []const u8, name: []const u8) Allocator.Error![]const u8 {
    return Path.join(alloc, &.{ path, name });
}

/// Index of the entry with the given name, or null.
pub fn indexOfName(listing: *const Listing, name: []const u8) ?usize {
    for (listing.entries, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.name, name)) return index;
    }
    return null;
}

/// Controls which entries are included in a directory snapshot.
pub const ReadOptions = struct {
    /// Include entries whose names start with a dot.
    show_hidden: bool = false,
};

/// Errors returned while allocating, opening, or reading a directory snapshot.
pub const ReadDirError = combined: {
    break :combined Allocator.Error ||
        Dir.OpenError ||
        Dir.Reader.Error ||
        Dir.StatFileError ||
        symlink.ReadError;
};

/// Errors returned while checking whether a directory has any visible entries.
pub const IsDirEmptyError = combined: {
    break :combined Dir.OpenError || Dir.Reader.Error;
};

/// Whether absolute `path` has no entries included by `options`.
pub fn isDirEmpty(io: Io, path: []const u8, options: ReadOptions) IsDirEmptyError!bool {
    const dir = try Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer Dir.close(dir, io);

    var reader_buffer: [directory_reader_buffer_bytes]u8 align(@alignOf(usize)) = undefined;
    var reader = freshDirectoryReader(dir, &reader_buffer);
    var entry_batch: [directory_entry_batch_count]Dir.Entry = undefined;
    while (true) {
        const entry_count = try reader.read(io, &entry_batch);
        if (entry_count == 0) return true;
        for (entry_batch[0..entry_count]) |entry| {
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
            const hidden = entry.name.len > 0 and entry.name[0] == '.';
            if (!hidden or options.show_hidden) return false;
        }
    }
}

/// Reads absolute `path`. The returned listing owns all of its storage.
pub fn readDir(
    alloc: Allocator,
    io: Io,
    path: []const u8,
    options: ReadOptions,
) ReadDirError!Listing {
    const without_trailing = std.mem.trimEnd(u8, path, "/");
    const normalized_path = if (without_trailing.len == 0) "/" else without_trailing;
    const path_copy = try alloc.dupe(u8, normalized_path);
    errdefer alloc.free(path_copy);

    var strings = std.heap.ArenaAllocator.init(alloc);
    errdefer strings.deinit();
    const string_alloc = strings.allocator();

    var entries = try alloc.alloc(Entry, 16);
    errdefer alloc.free(entries);
    var count: usize = 0;

    const dir = try Dir.openDirAbsolute(io, normalized_path, .{ .iterate = true });
    defer Dir.close(dir, io);
    var reader_buffer: [directory_reader_buffer_bytes]u8 align(@alignOf(usize)) = undefined;
    var reader = freshDirectoryReader(dir, &reader_buffer);
    var entry_batch: [directory_entry_batch_count]Dir.Entry = undefined;
    while (true) {
        const entry_count = try reader.read(io, &entry_batch);
        if (entry_count == 0) break;
        for (entry_batch[0..entry_count]) |de| {
            // Some directory readers report these; parent navigation is handled
            // by the model rather than as a rendered entry.
            if (std.mem.eql(u8, de.name, ".") or std.mem.eql(u8, de.name, "..")) continue;
            const hidden = de.name.len > 0 and de.name[0] == '.';
            if (hidden and !options.show_hidden) continue;

            if (count == entries.len) {
                entries = try alloc.realloc(entries, @max(32, entries.len * 2));
            }
            // d_type is optional on POSIX filesystems. Resolve only unknown
            // entries, without following links until link classification.
            const kind = if (de.kind == .unknown)
                (try dir.statFile(io, de.name, .{ .follow_symlinks = false })).kind
            else
                de.kind;
            const is_sym = kind == .sym_link;
            var link_target: ?[]const u8 = null;
            var is_dir = kind == .directory;
            if (is_sym) {
                const link = try symlink.read(string_alloc, dir, de.name);
                link_target = link.target;
                is_dir = link.is_dir;
            }

            const name = try string_alloc.dupe(u8, de.name);
            const entry: Entry = .{
                .name = name,
                .link_target = link_target,
                .is_dir = is_dir,
                .is_sym = is_sym,
            };
            entries[count] = entry;
            count += 1;
        }
    }

    sortEntries(entries[0..count]);

    // The stored slice length must match the allocation passed to free.
    entries = try alloc.realloc(entries, count);

    var selected = try std.DynamicBitSetUnmanaged.initEmpty(alloc, count);
    errdefer selected.deinit(alloc);

    var listing: Listing = .{
        .alloc = alloc,
        .strings = strings,
        .path = path_copy,
        .entries = entries[0..count],
        .selected = selected,
    };
    try listing.initRows();
    return listing;
}

/// Errors returned while deleting files, links, or directory trees.
pub const DeleteEntryError = combined: {
    break :combined Dir.DeleteFileError || Dir.DeleteTreeError;
};

/// Deletes a file or directory tree. Pass `is_dir = false` for symlinks so only
/// the link is removed and its target remains untouched.
pub fn deleteEntry(io: Io, path: []const u8, is_dir: bool) DeleteEntryError!void {
    if (is_dir) {
        try Dir.deleteTree(.cwd(), io, path);
    } else {
        try Dir.deleteFileAbsolute(io, path);
    }
}

fn sortEntries(entries: []Entry) void {
    std.sort.pdq(Entry, entries, {}, entryLess);
}

fn entryLess(_: void, a: Entry, b: Entry) bool {
    if (a.is_dir != b.is_dir) return a.is_dir;
    return nameLess(a.name, b.name);
}

fn nameLess(a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    for (0..n) |i| {
        const ca = toLower(a[i]);
        const cb = toLower(b[i]);
        if (ca != cb) return ca < cb;
    }
    return a.len < b.len;
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
}

fn freshDirectoryReader(
    dir: Dir,
    buffer: []align(@alignOf(usize)) u8,
) Dir.Reader {
    var reader = Dir.Reader.init(dir, buffer);
    // Every caller has just opened `dir`, so rewinding it before the first
    // native batch read would be a redundant syscall.
    reader.state = .reading;
    return reader;
}

fn rowCapacity(entry: Entry) usize {
    const arrow_length = if (entry.link_target) |target| " -> ".len + target.len else 0;
    return "✓ ".len + "▸ ".len + 1 + entry.name.len + arrow_length;
}

fn rowLength(entry: Entry, selected: bool) usize {
    const mark_length = if (selected) "✓ ".len else "  ".len;
    const kind_length = if (entry.is_dir and entry.is_empty != true)
        "▸ ".len
    else
        "  ".len;
    const arrow_length = if (entry.link_target) |target| " -> ".len + target.len else 0;
    return mark_length + kind_length + 1 + entry.name.len + arrow_length;
}

fn formatRow(
    alloc: Allocator,
    entry: Entry,
    selected: bool,
) Allocator.Error![]const u8 {
    const row = try alloc.alloc(u8, rowLength(entry, selected));
    return writeRow(row, entry, selected);
}

fn writeRow(buffer: []u8, entry: Entry, selected: bool) []const u8 {
    const mark = if (selected) "✓ " else "  ";
    const kind = if (entry.is_dir and entry.is_empty != true)
        "▸ "
    else
        "  ";
    const arrow = " -> ";
    const target_length = if (entry.link_target) |target| arrow.len + target.len else 0;
    const length = mark.len + kind.len + 1 + entry.name.len + target_length;
    std.debug.assert(buffer.len >= length);
    var offset: usize = 0;
    @memcpy(buffer[offset..][0..mark.len], mark);
    offset += mark.len;
    @memcpy(buffer[offset..][0..kind.len], kind);
    offset += kind.len;
    buffer[offset] = ' ';
    offset += 1;
    @memcpy(buffer[offset..][0..entry.name.len], entry.name);
    offset += entry.name.len;
    if (entry.link_target) |target| {
        @memcpy(buffer[offset..][0..arrow.len], arrow);
        offset += arrow.len;
        @memcpy(buffer[offset..][0..target.len], target);
        offset += target.len;
    }
    std.debug.assert(offset == length);
    return buffer[0..length];
}

const testing = std.testing;
const testing_io = testing.io;

test "all declarations compile" {
    std.testing.refAllDecls(@This());
}

test "parentPath returns owned normalized parents" {
    const alloc = testing.allocator;
    const nested_parent = try parentPath(alloc, "/a/b");
    defer alloc.free(nested_parent);
    try testing.expectEqualStrings("/a", nested_parent);
    const top_parent = try parentPath(alloc, "/a");
    defer alloc.free(top_parent);
    try testing.expectEqualStrings("/", top_parent);
    const root_parent = try parentPath(alloc, "/");
    defer alloc.free(root_parent);
    try testing.expectEqualStrings("/", root_parent);
    const trailing_parent = try parentPath(alloc, "/a/b/");
    defer alloc.free(trailing_parent);
    try testing.expectEqualStrings("/a", trailing_parent);
}

test "joinPath returns an owned joined path" {
    const alloc = testing.allocator;
    const nested_path = try joinPath(alloc, "/a", "b");
    defer alloc.free(nested_path);
    try testing.expectEqualStrings("/a/b", nested_path);
    const root_path = try joinPath(alloc, "/", "b");
    defer alloc.free(root_path);
    try testing.expectEqualStrings("/b", root_path);
}

test "sort order: dirs then case-insensitive names" {
    const alloc = testing.allocator;
    var tree = try test_support.TempTree.init(alloc, testing_io);
    defer tree.deinit();

    try tree.writeFile("b.txt", "b");
    try tree.writeFile("a.txt", "a");
    try tree.writeFile(".hidden", "h");
    try tree.createDir("zdir");
    try tree.createDir("A_dir");

    var listing = try readDir(alloc, testing_io, tree.path, .{});
    defer listing.deinit();

    try testing.expectEqual(@as(usize, 4), listing.entries.len);
    try testing.expectEqualStrings("A_dir", listing.entries[0].name);
    try testing.expect(listing.entries[0].is_dir);
    try testing.expectEqualStrings("zdir", listing.entries[1].name);
    try testing.expectEqualStrings("a.txt", listing.entries[2].name);
    try testing.expectEqualStrings("b.txt", listing.entries[3].name);
}

test "hidden files filtered" {
    const alloc = testing.allocator;
    var tree = try test_support.TempTree.init(alloc, testing_io);
    defer tree.deinit();

    try tree.writeFile("a.txt", "a");
    try tree.writeFile(".hidden", "h");

    var listing = try readDir(alloc, testing_io, tree.path, .{});
    defer listing.deinit();
    try testing.expectEqual(@as(usize, 1), listing.entries.len);
    try testing.expectEqualStrings("a.txt", listing.entries[0].name);

    var hidden_listing = try readDir(alloc, testing_io, tree.path, .{ .show_hidden = true });
    defer hidden_listing.deinit();
    try testing.expectEqual(@as(usize, 2), hidden_listing.entries.len);
    try testing.expect(indexOfName(&hidden_listing, ".hidden") != null);
}

test "directory emptiness follows hidden visibility" {
    const alloc = testing.allocator;
    var tree = try test_support.TempTree.init(alloc, testing_io);
    defer tree.deinit();

    try tree.writeFile(".hidden", "h");

    try testing.expect(try isDirEmpty(testing_io, tree.path, .{}));
    try testing.expect(!try isDirEmpty(testing_io, tree.path, .{ .show_hidden = true }));

    try tree.writeFile("visible", "v");
    try testing.expect(!try isDirEmpty(testing_io, tree.path, .{}));
}

test "batched directory reads cross an entry batch boundary" {
    const alloc = testing.allocator;
    var tree = try test_support.TempTree.init(alloc, testing_io);
    defer tree.deinit();

    for (0..directory_entry_batch_count + 1) |index| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, ".file-{d:0>6}", .{index});
        try tree.writeFile(name, "");
    }

    try testing.expect(try isDirEmpty(testing_io, tree.path, .{}));

    var listing = try readDir(alloc, testing_io, tree.path, .{ .show_hidden = true });
    defer listing.deinit();
    try testing.expectEqual(directory_entry_batch_count + 1, listing.entries.len);
    try testing.expect(indexOfName(&listing, ".file-000000") != null);
    try testing.expect(indexOfName(&listing, ".file-000128") != null);
}

test "symlinks display targets and classify directory targets" {
    const alloc = testing.allocator;
    var tree = try test_support.TempTree.init(alloc, testing_io);
    defer tree.deinit();

    try tree.writeFile("target.txt", "12345");
    try tree.createDir("target-dir");
    try tree.symLink("target.txt", "link.txt");
    try Dir.symLink(tree.temp.dir, testing_io, "target-dir", "link-dir", .{
        .is_directory = true,
    });
    try tree.symLink("missing", "dangling");

    var listing = try readDir(alloc, testing_io, tree.path, .{});
    defer listing.deinit();

    const file_link_index = indexOfName(&listing, "link.txt").?;
    const file_link = listing.entries[file_link_index];
    try testing.expect(file_link.is_sym);
    try testing.expect(!file_link.is_dir);
    try testing.expect(!file_link.deleteAsDirectory());
    try testing.expectEqualStrings("target.txt", file_link.link_target.?);
    try testing.expectEqualStrings("     link.txt -> target.txt", listing.rows[file_link_index]);

    const dir_link_index = indexOfName(&listing, "link-dir").?;
    const dir_link = listing.entries[dir_link_index];
    try testing.expect(dir_link.is_sym);
    try testing.expect(dir_link.is_dir);
    try testing.expect(!dir_link.deleteAsDirectory());
    try testing.expectEqualStrings("target-dir", dir_link.link_target.?);
    try testing.expectEqualStrings(
        "  ▸  link-dir -> target-dir",
        listing.rows[dir_link_index],
    );

    const dangling_index = indexOfName(&listing, "dangling").?;
    const dangling = listing.entries[dangling_index];
    try testing.expect(dangling.is_sym);
    try testing.expect(!dangling.is_dir);
    try testing.expectEqualStrings("missing", dangling.link_target.?);
    try testing.expectEqualStrings("     dangling -> missing", listing.rows[dangling_index]);
}

test "cursorFor prefers names and clamps fallback indices" {
    const alloc = testing.allocator;
    var tree = try test_support.TempTree.init(alloc, testing_io);
    defer tree.deinit();

    try tree.writeFile("a.txt", "a");
    try tree.writeFile("b.txt", "b");

    var listing = try readDir(alloc, testing_io, tree.path, .{});
    defer listing.deinit();

    try testing.expectEqual(@as(usize, 1), listing.cursorFor("b.txt", null));
    try testing.expectEqual(@as(usize, 1), listing.cursorFor("no-such-file", 1));
    try testing.expectEqual(@as(usize, 1), listing.cursorFor(null, 99));
}

test "selection toggle and count" {
    const alloc = testing.allocator;
    var tree = try test_support.TempTree.init(alloc, testing_io);
    defer tree.deinit();

    try tree.writeFile("a.txt", "a");

    var listing = try readDir(alloc, testing_io, tree.path, .{});
    defer listing.deinit();

    const row_storage_pointer = listing.row_storage.ptr;
    try testing.expectEqual(@as(usize, 0), listing.selectedCount());
    listing.toggleSelected(0);
    try testing.expectEqual(@as(usize, 1), listing.selectedCount());
    try testing.expectEqualStrings("✓    a.txt", listing.rows[0]);
    try testing.expectEqual(row_storage_pointer, listing.row_storage.ptr);
    listing.toggleSelected(0);
    try testing.expectEqual(@as(usize, 0), listing.selectedCount());
    try testing.expectEqualStrings("     a.txt", listing.rows[0]);
    try testing.expectEqual(row_storage_pointer, listing.row_storage.ptr);

    listing.toggleSelected(0);
    listing.clearSelection();
    try testing.expectEqual(@as(usize, 0), listing.selectedCount());
    try testing.expectEqualStrings("     a.txt", listing.rows[0]);
    try testing.expectEqual(row_storage_pointer, listing.row_storage.ptr);
}

test "deleteEntry file" {
    const alloc = testing.allocator;
    var tree = try test_support.TempTree.init(alloc, testing_io);
    defer tree.deinit();

    try tree.writeFile("gone.txt", "x");
    const file_path = try tree.absolutePath("gone.txt");
    defer alloc.free(file_path);

    try deleteEntry(testing_io, file_path, false);
    try testing.expectError(error.FileNotFound, Dir.accessAbsolute(testing_io, file_path, .{}));
}

test "deleteEntry recursively deletes a directory tree" {
    const alloc = testing.allocator;
    var tree = try test_support.TempTree.init(alloc, testing_io);
    defer tree.deinit();

    try tree.createDir("sub");
    try tree.createDir("sub/nested");
    try tree.createDir("outside");
    try tree.writeFile("sub/inner.txt", "x");
    try tree.writeFile("sub/nested/deep.txt", "x");
    try tree.writeFile("outside/kept.txt", "kept");
    try Dir.symLink(
        tree.temp.dir,
        testing_io,
        "../../outside",
        "sub/nested/outside-link",
        .{ .is_directory = true },
    );
    const directory_path = try tree.absolutePath("sub");
    defer alloc.free(directory_path);
    const outside_path = try tree.absolutePath("outside/kept.txt");
    defer alloc.free(outside_path);

    try deleteEntry(testing_io, directory_path, true);
    try testing.expectError(
        error.FileNotFound,
        Dir.accessAbsolute(testing_io, directory_path, .{}),
    );
    try Dir.accessAbsolute(testing_io, outside_path, .{});
}

test "deleteEntry unlinks a directory symlink without touching its target" {
    const alloc = testing.allocator;
    var tree = try test_support.TempTree.init(alloc, testing_io);
    defer tree.deinit();

    try tree.createDir("target");
    try tree.writeFile("target/kept.txt", "kept");
    try Dir.symLink(tree.temp.dir, testing_io, "target", "link", .{
        .is_directory = true,
    });

    const link_path = try tree.absolutePath("link");
    defer alloc.free(link_path);
    const target_path = try tree.absolutePath("target/kept.txt");
    defer alloc.free(target_path);

    try deleteEntry(testing_io, link_path, false);
    try testing.expectError(error.FileNotFound, Dir.accessAbsolute(testing_io, link_path, .{}));
    try Dir.accessAbsolute(testing_io, target_path, .{});
}

test "row formatting" {
    const alloc = testing.allocator;
    const file_entry: Entry = .{ .name = "main.zig" };
    const row = try formatRow(alloc, file_entry, true);
    defer alloc.free(row);
    try testing.expectEqualStrings("✓    main.zig", row);

    const directory_entry: Entry = .{ .name = "src", .is_dir = true };
    const directory_row = try formatRow(alloc, directory_entry, false);
    defer alloc.free(directory_row);
    try testing.expectEqualStrings("  ▸  src", directory_row);

    const empty_directory: Entry = .{
        .name = "empty",
        .is_dir = true,
        .is_empty = true,
    };
    const empty_row = try formatRow(alloc, empty_directory, false);
    defer alloc.free(empty_row);
    try testing.expectEqualStrings("     empty", empty_row);
}

test "unknown entry kinds preserve directory and symlink behavior" {
    var tree = try test_support.TempTree.init(testing.allocator, testing.io);
    defer tree.deinit();
    try tree.createDir("directory");
    try tree.writeFile("directory/inside", "text");
    try tree.writeFile("file", "text");
    try tree.symLink("directory", "directory-link");
    try tree.symLink("file", "file-link");
    try tree.symLink("missing", "dangling-link");
    const reader = struct {
        fn read(userdata: ?*anyopaque, r: *Dir.Reader, buffer: []Dir.Entry) Dir.Reader.Error!usize {
            const count = try testing.io.vtable.dirRead(userdata, r, buffer);
            for (buffer[0..count]) |*entry| entry.kind = .unknown;
            return count;
        }
    };
    var vtable = testing.io.vtable.*;
    vtable.dirRead = reader.read;
    const io: Io = .{ .userdata = testing.io.userdata, .vtable = &vtable };
    var listing = try readDir(testing.allocator, io, tree.path, .{});
    defer listing.deinit();
    const directory = listing.entries[indexOfName(&listing, "directory").?];
    try testing.expect(directory.is_dir);
    try testing.expect(directory.deleteAsDirectory());
    const directory_link = listing.entries[indexOfName(&listing, "directory-link").?];
    try testing.expect(directory_link.is_dir and directory_link.is_sym);
    try testing.expect(!directory_link.deleteAsDirectory());
    for ([_][]const u8{ "file-link", "dangling-link" }) |name| {
        const entry = listing.entries[indexOfName(&listing, name).?];
        try testing.expect(entry.is_sym and !entry.is_dir);
    }
    const file = listing.entries[indexOfName(&listing, "file").?];
    try testing.expect(!file.is_dir and !file.is_sym);
    const link_path = try tree.absolutePath("directory-link");
    defer testing.allocator.free(link_path);
    try deleteEntry(io, link_path, directory_link.deleteAsDirectory());
    const target = try tree.temp.dir.openFile(testing.io, "directory/inside", .{});
    defer target.close(testing.io);
}
