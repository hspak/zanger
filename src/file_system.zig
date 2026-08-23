//! Owns absolute directory listings and their preformatted display rows. Parent
//! navigation stays in the UI model, so listings never synthesize `.` or `..`.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const Path = std.fs.path;
const log = std.log.scoped(.file_system);

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
    /// Zero for an empty listing; otherwise indexes `entries`.
    cursor: usize = 0,
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

    /// Restores a cursor by name, then by fallback index, and otherwise selects
    /// the first entry. An empty listing always uses index zero.
    pub fn restoreCursor(
        self: *Listing,
        preferred_name: ?[]const u8,
        fallback: ?usize,
    ) void {
        if (preferred_name) |name| {
            for (self.entries, 0..) |entry, index| {
                if (std.mem.eql(u8, entry.name, name)) {
                    self.cursor = index;
                    return;
                }
            }
        }
        self.cursor = if (self.entries.len == 0)
            0
        else
            @min(fallback orelse 0, self.entries.len - 1);
    }

    /// Number of entries currently selected.
    pub fn selectedCount(self: Listing) usize {
        return self.selected_count;
    }

    /// Toggles the cursor entry. The cursor must identify an existing entry.
    pub fn toggleSelected(self: *Listing) void {
        std.debug.assert(self.cursor < self.entries.len);
        if (self.selected.isSet(self.cursor)) {
            self.selected.unset(self.cursor);
            self.selected_count -= 1;
        } else {
            self.selected.set(self.cursor);
            self.selected_count += 1;
        }
        self.refreshRow(self.cursor);
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
        Dir.Iterator.Error ||
        ReadSymlinkError;
};

/// Errors returned while checking whether a directory has any visible entries.
pub const IsDirEmptyError = combined: {
    break :combined Dir.OpenError || Dir.Iterator.Error;
};

/// Whether absolute `path` has no entries included by `options`.
pub fn isDirEmpty(io: Io, path: []const u8, options: ReadOptions) IsDirEmptyError!bool {
    const dir = try Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer Dir.close(dir, io);

    var it = Dir.iterate(dir);
    while (try it.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        const hidden = entry.name.len > 0 and entry.name[0] == '.';
        if (!hidden or options.show_hidden) return false;
    }
    return true;
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
    var it = Dir.iterate(dir);
    while (try it.next(io)) |de| {
        // Some directory iterators report these; parent navigation is handled
        // by the model rather than as a rendered entry.
        if (std.mem.eql(u8, de.name, ".") or std.mem.eql(u8, de.name, "..")) continue;
        const hidden = de.name.len > 0 and de.name[0] == '.';
        if (hidden and !options.show_hidden) continue;

        if (count == entries.len) {
            entries = try alloc.realloc(entries, @max(32, entries.len * 2));
        }
        const is_sym = de.kind == .sym_link;
        var link_target: ?[]const u8 = null;
        var is_dir = de.kind == .directory;
        if (is_sym) {
            const symlink = try readSymlink(string_alloc, dir, de.name);
            link_target = symlink.target;
            is_dir = symlink.is_dir;
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

const ReadSymlinkError = Allocator.Error || error{
    AccessDenied,
    BadPathName,
    FileNotFound,
    FileSystem,
    NameTooLong,
    NotDir,
    NotLink,
    PermissionDenied,
    SymLinkLoop,
    SystemResources,
} || std.posix.UnexpectedError;

const Symlink = struct {
    target: []const u8,
    is_dir: bool,
};

fn readSymlink(alloc: Allocator, dir: Dir, name: []const u8) ReadSymlinkError!Symlink {
    const linux = std.os.linux;
    if (name.len > Dir.max_name_bytes) return error.NameTooLong;
    var name_buffer: [Dir.max_name_bytes + 1]u8 = undefined;
    @memcpy(name_buffer[0..name.len], name);
    name_buffer[name.len] = 0;

    var target_buffer: [Dir.max_path_bytes]u8 = undefined;
    const target_length: usize = while (true) {
        const rc = linux.readlinkat(
            dir.handle,
            @ptrCast(&name_buffer),
            &target_buffer,
            target_buffer.len,
        );
        switch (linux.errno(rc)) {
            .SUCCESS => break @intCast(rc),
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .INVAL => return error.NotLink,
            .IO => return error.FileSystem,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOMEM => return error.SystemResources,
            .NOTDIR => return error.NotDir,
            .PERM => return error.PermissionDenied,
            .ILSEQ => return error.BadPathName,
            .BADF, .FAULT => unreachable,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    };
    if (target_length == target_buffer.len) return error.NameTooLong;
    const target = try alloc.dupe(u8, target_buffer[0..target_length]);
    errdefer alloc.free(target);

    const is_dir = is_dir: {
        const requested: linux.STATX = .{ .TYPE = true };
        var statx = std.mem.zeroes(linux.Statx);
        while (true) switch (linux.errno(linux.statx(
            dir.handle,
            @ptrCast(&name_buffer),
            linux.AT.NO_AUTOMOUNT,
            requested,
            &statx,
        ))) {
            .SUCCESS => break,
            .INTR => continue,
            .ACCES, .LOOP, .NAMETOOLONG, .NOENT, .NOTDIR, .PERM => break :is_dir false,
            .NOMEM => return error.SystemResources,
            .BADF, .FAULT, .INVAL => unreachable,
            else => |err| return std.posix.unexpectedErrno(err),
        };
        const actual_mask: u32 = @bitCast(statx.mask);
        const requested_mask: u32 = @bitCast(requested);
        if (actual_mask & requested_mask != requested_mask) return error.Unexpected;
        break :is_dir statx.mode & linux.S.IFMT == linux.S.IFDIR;
    };
    return .{
        .target = target,
        .is_dir = is_dir,
    };
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

fn tmpAbsPath(alloc: Allocator, temp: *std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(testing_io, alloc);
    defer alloc.free(cwd);
    return Path.join(alloc, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
}

fn makeDir(temp: *std.testing.TmpDir, name: []const u8) !void {
    try Dir.createDir(temp.dir, testing_io, name, .default_dir);
}

fn makeFile(temp: *std.testing.TmpDir, name: []const u8, data: []const u8) !void {
    try Dir.writeFile(temp.dir, testing_io, .{ .sub_path = name, .data = data });
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
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();

    try makeFile(&temp, "b.txt", "b");
    try makeFile(&temp, "a.txt", "a");
    try makeFile(&temp, ".hidden", "h");
    try makeDir(&temp, "zdir");
    try makeDir(&temp, "A_dir");

    const path = try tmpAbsPath(alloc, &temp);
    defer alloc.free(path);

    var listing = try readDir(alloc, testing_io, path, .{});
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
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();

    try makeFile(&temp, "a.txt", "a");
    try makeFile(&temp, ".hidden", "h");

    const path = try tmpAbsPath(alloc, &temp);
    defer alloc.free(path);

    var listing = try readDir(alloc, testing_io, path, .{});
    defer listing.deinit();
    try testing.expectEqual(@as(usize, 1), listing.entries.len);
    try testing.expectEqualStrings("a.txt", listing.entries[0].name);

    var hidden_listing = try readDir(alloc, testing_io, path, .{ .show_hidden = true });
    defer hidden_listing.deinit();
    try testing.expectEqual(@as(usize, 2), hidden_listing.entries.len);
    try testing.expect(indexOfName(&hidden_listing, ".hidden") != null);
}

test "directory emptiness follows hidden visibility" {
    const alloc = testing.allocator;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();

    try makeFile(&temp, ".hidden", "h");
    const path = try tmpAbsPath(alloc, &temp);
    defer alloc.free(path);

    try testing.expect(try isDirEmpty(testing_io, path, .{}));
    try testing.expect(!try isDirEmpty(testing_io, path, .{ .show_hidden = true }));

    try makeFile(&temp, "visible", "v");
    try testing.expect(!try isDirEmpty(testing_io, path, .{}));
}

test "symlinks display targets and classify directory targets" {
    const alloc = testing.allocator;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();

    try makeFile(&temp, "target.txt", "12345");
    try makeDir(&temp, "target-dir");
    try Dir.symLink(temp.dir, testing_io, "target.txt", "link.txt", .{});
    try Dir.symLink(temp.dir, testing_io, "target-dir", "link-dir", .{
        .is_directory = true,
    });
    try Dir.symLink(temp.dir, testing_io, "missing", "dangling", .{});

    const path = try tmpAbsPath(alloc, &temp);
    defer alloc.free(path);

    var listing = try readDir(alloc, testing_io, path, .{});
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

test "restoreCursor prefers names and clamps fallback indices" {
    const alloc = testing.allocator;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();

    try makeFile(&temp, "a.txt", "a");
    try makeFile(&temp, "b.txt", "b");

    const path = try tmpAbsPath(alloc, &temp);
    defer alloc.free(path);

    var listing = try readDir(alloc, testing_io, path, .{});
    defer listing.deinit();

    listing.cursor = 0;
    listing.restoreCursor("b.txt", null);
    try testing.expectEqual(@as(usize, 1), listing.cursor);

    listing.restoreCursor("no-such-file", 1);
    try testing.expectEqual(@as(usize, 1), listing.cursor);

    listing.restoreCursor(null, 99);
    try testing.expectEqual(@as(usize, 1), listing.cursor);
}

test "selection toggle and count" {
    const alloc = testing.allocator;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();

    try makeFile(&temp, "a.txt", "a");

    const path = try tmpAbsPath(alloc, &temp);
    defer alloc.free(path);

    var listing = try readDir(alloc, testing_io, path, .{});
    defer listing.deinit();

    const row_storage_pointer = listing.row_storage.ptr;
    try testing.expectEqual(@as(usize, 0), listing.selectedCount());
    listing.toggleSelected();
    try testing.expectEqual(@as(usize, 1), listing.selectedCount());
    try testing.expectEqualStrings("✓    a.txt", listing.rows[0]);
    try testing.expectEqual(row_storage_pointer, listing.row_storage.ptr);
    listing.toggleSelected();
    try testing.expectEqual(@as(usize, 0), listing.selectedCount());
    try testing.expectEqualStrings("     a.txt", listing.rows[0]);
    try testing.expectEqual(row_storage_pointer, listing.row_storage.ptr);

    listing.toggleSelected();
    listing.clearSelection();
    try testing.expectEqual(@as(usize, 0), listing.selectedCount());
    try testing.expectEqualStrings("     a.txt", listing.rows[0]);
    try testing.expectEqual(row_storage_pointer, listing.row_storage.ptr);
}

test "deleteEntry file" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();

    try makeFile(&temp, "gone.txt", "x");
    const alloc = testing.allocator;
    const path = try tmpAbsPath(alloc, &temp);
    defer alloc.free(path);
    const file_path = try joinPath(alloc, path, "gone.txt");
    defer alloc.free(file_path);

    try deleteEntry(testing_io, file_path, false);
    try testing.expectError(error.FileNotFound, Dir.accessAbsolute(testing_io, file_path, .{}));
}

test "deleteEntry recursively deletes a directory tree" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();

    try makeDir(&temp, "sub");
    try makeDir(&temp, "sub/nested");
    try makeDir(&temp, "outside");
    try makeFile(&temp, "sub/inner.txt", "x");
    try makeFile(&temp, "sub/nested/deep.txt", "x");
    try makeFile(&temp, "outside/kept.txt", "kept");
    try Dir.symLink(
        temp.dir,
        testing_io,
        "../../outside",
        "sub/nested/outside-link",
        .{ .is_directory = true },
    );
    const alloc = testing.allocator;
    const path = try tmpAbsPath(alloc, &temp);
    defer alloc.free(path);
    const directory_path = try joinPath(alloc, path, "sub");
    defer alloc.free(directory_path);
    const outside_path = try joinPath(alloc, path, "outside/kept.txt");
    defer alloc.free(outside_path);

    try deleteEntry(testing_io, directory_path, true);
    try testing.expectError(
        error.FileNotFound,
        Dir.accessAbsolute(testing_io, directory_path, .{}),
    );
    try Dir.accessAbsolute(testing_io, outside_path, .{});
}

test "deleteEntry unlinks a directory symlink without touching its target" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();

    try makeDir(&temp, "target");
    try makeFile(&temp, "target/kept.txt", "kept");
    try Dir.symLink(temp.dir, testing_io, "target", "link", .{ .is_directory = true });

    const alloc = testing.allocator;
    const path = try tmpAbsPath(alloc, &temp);
    defer alloc.free(path);
    const link_path = try joinPath(alloc, path, "link");
    defer alloc.free(link_path);
    const target_path = try joinPath(alloc, path, "target/kept.txt");
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
