//! Right-pane content for non-directory entries: detailed file metadata, a
//! plain text file's contents, or an italic placeholder message. Rows reuse
//! the directory row widgets so previews scroll and clip consistently with
//! listings.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const FileMetadata = @import("FileMetadata.zig");
const IdentityCache = @import("IdentityCache.zig");
const format = @import("format.zig");
const test_support = @import("../test_support.zig");

/// Upper bound on bytes read from one file for a content preview. Files at or
/// below this size render fully; larger files show a truncation marker.
pub const max_preview_bytes: usize = 128 * 1024;
/// Text previews are not independently scrollable, so constructing more rows
/// than any practical terminal can display only adds allocation and teardown
/// work to the UI-thread preview commit.
pub const max_preview_lines: usize = 1024;

const Preview = @This();

/// Render meaning and ownership for one preview row. Field labels are static;
/// every text/value payload is owned by the preview allocator.
pub const Row = union(enum) {
    text: []const u8,
    notice: []const u8,
    spacer,
    field: Field,

    pub const Field = struct {
        label: []const u8,
        value: []const u8,
    };

    fn deinit(self: *Row, alloc: Allocator, owns_text: bool) void {
        switch (self.*) {
            .text => |value| if (owns_text) alloc.free(value),
            .notice => |value| alloc.free(value),
            .spacer => {},
            .field => |field| alloc.free(field.value),
        }
        self.* = undefined;
    }
};

alloc: Allocator,
rows: []Row = &.{},
// Text-preview rows borrow slices of this one allocation. Other preview kinds
// leave it null and continue to own their row payloads individually.
text_storage: ?[]u8 = null,

pub fn deinit(self: *Preview) void {
    const owns_text = self.text_storage == null;
    for (self.rows) |*row| row.deinit(self.alloc, owns_text);
    self.alloc.free(self.rows);
    if (self.text_storage) |storage| self.alloc.free(storage);
    self.* = undefined;
}

/// Returns verbatim display text for non-field rows. A spacer is an empty
/// display line; metadata fields are queried by label instead.
pub fn displayTextAt(self: *const Preview, index: usize) ?[]const u8 {
    if (index >= self.rows.len) return null;
    return switch (self.rows[index]) {
        .text => |value| value,
        .notice => |value| value,
        .spacer => "",
        .field => null,
    };
}

pub fn fieldValue(self: *const Preview, label: []const u8) ?[]const u8 {
    for (self.rows) |row| switch (row) {
        .field => |field| if (std.mem.eql(u8, field.label, label)) return field.value,
        else => {},
    };
    return null;
}

/// A single italic message line, such as the empty-directory placeholder.
pub fn initMessage(alloc: Allocator, message: []const u8) Allocator.Error!Preview {
    const rows = try alloc.alloc(Row, 1);
    errdefer alloc.free(rows);
    rows[0] = .{ .notice = try alloc.dupe(u8, message) };
    return .{
        .alloc = alloc,
        .rows = rows,
    };
}

/// A dimmed non-text notice, one blank separator line, and an eight-line
/// metadata sheet for a regular file whose contents are not rendered.
/// `loaded_metadata` may carry metadata already stat'ed for the same path;
/// otherwise one native stat call runs.
pub fn initFile(
    alloc: Allocator,
    identities: *IdentityCache,
    path: []const u8,
    loaded_metadata: ?FileMetadata,
) !Preview {
    return initSheet(alloc, identities, path, loaded_metadata, false);
}

/// The same sheet, statting through symbolic links so it describes the
/// linked file's target rather than the link itself.
pub fn initFileFollow(
    alloc: Allocator,
    identities: *IdentityCache,
    path: []const u8,
) !Preview {
    return initSheet(alloc, identities, path, null, true);
}

fn initSheet(
    alloc: Allocator,
    identities: *IdentityCache,
    path: []const u8,
    loaded_metadata: ?FileMetadata,
    follow_symlinks: bool,
) !Preview {
    const metadata = if (follow_symlinks)
        try FileMetadata.initFollow(path)
    else
        loaded_metadata orelse try FileMetadata.init(path);

    var made: usize = 0;
    const rows = try alloc.alloc(Row, 10);
    errdefer {
        for (rows[0..made]) |*row| row.deinit(alloc, true);
        alloc.free(rows);
    }

    rows[0] = .{
        .notice = try alloc.dupe(u8, "non-text files are not rendered"),
    };
    made += 1;
    rows[1] = .spacer;
    made += 1;
    rows[2] = .{ .field = .{
        .label = "Name",
        .value = try alloc.dupe(u8, std.fs.path.basename(path)),
    } };
    made += 1;
    rows[3] = .{ .field = .{
        .label = "Type",
        .value = try alloc.dupe(u8, @tagName(metadata.kind)),
    } };
    made += 1;
    rows[4] = .{ .field = .{
        .label = "Mode",
        .value = try formatMode(alloc, metadata.kind, metadata.mode),
    } };
    made += 1;
    rows[5] = .{ .field = .{
        .label = "Owner",
        .value = try formatOwner(alloc, identities, metadata.uid, metadata.gid),
    } };
    made += 1;
    rows[6] = .{ .field = .{
        .label = "Size",
        .value = try std.fmt.allocPrint(alloc, "{Bi:.2} ({d} bytes)", .{
            metadata.size,
            metadata.size,
        }),
    } };
    made += 1;
    rows[7] = .{ .field = .{
        .label = "Modified",
        .value = try formatModifiedTime(alloc, metadata.mtime),
    } };
    made += 1;
    rows[8] = .{ .field = .{
        .label = "Writable",
        .value = try alloc.dupe(
            u8,
            if (metadata.mode & 0o222 == 0) "no" else "yes",
        ),
    } };
    made += 1;
    rows[9] = .{ .field = .{
        .label = "Links",
        .value = try std.fmt.allocPrint(alloc, "{d}", .{metadata.nlink}),
    } };

    return .{
        .alloc = alloc,
        .rows = rows,
    };
}

fn formatMode(
    alloc: Allocator,
    kind: Io.File.Kind,
    mode: u32,
) Allocator.Error![]const u8 {
    const bits = format.modeBits(kind, mode);
    return std.fmt.allocPrint(alloc, "{s}", .{bits[0..]});
}

fn formatOwner(
    alloc: Allocator,
    identities: *IdentityCache,
    uid: u32,
    gid: u32,
) Allocator.Error![]const u8 {
    const user = try identities.userName(alloc, uid);
    const group = try identities.groupName(alloc, gid);
    return std.fmt.allocPrint(
        alloc,
        "{s}:{s} ({d}:{d})",
        .{ user, group, uid, gid },
    );
}

fn formatModifiedTime(
    alloc: Allocator,
    timestamp: Io.Timestamp,
) Allocator.Error![]const u8 {
    const seconds = @divFloor(timestamp.nanoseconds, std.time.ns_per_s);
    if (seconds < 0 or seconds > 253_402_300_799) {
        return std.fmt.allocPrint(
            alloc,
            "{d} ns since Unix epoch",
            .{timestamp.nanoseconds},
        );
    }

    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    return std.fmt.allocPrint(
        alloc,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

/// Errors from opening and reading a candidate text file, plus allocation.
pub const TextContentError =
    Allocator.Error || Io.File.OpenError || Io.File.StatError || Io.File.ReadPositionalError;

/// Reads at most `max_bytes` of `path` and renders its contents as one preview
/// line per source line. Returns null when the file is not text: a NUL byte
/// or invalid UTF-8 in the read portion classifies it as binary, leaving the
/// metadata sheet as the preview. Empty files preview as a placeholder
/// message. `size_hint` avoids one `stat` when the caller already knows the
/// file size.
pub fn initTextContent(
    alloc: Allocator,
    io: Io,
    path: []const u8,
    size_hint: ?u64,
    max_bytes: usize,
) TextContentError!?Preview {
    const file = try Io.Dir.openFileAbsolute(io, path, .{});
    defer Io.File.close(file, io);

    const size: u64 = if (size_hint) |hint|
        hint
    else
        (try file.stat(io)).size;
    const read_length: usize = @intCast(@min(size, max_bytes));
    const bytes = try alloc.alloc(u8, read_length);
    defer alloc.free(bytes);
    const filled = try file.readPositionalAll(io, bytes, 0);
    const content = bytes[0..filled];

    // Binary heuristics: a NUL byte anywhere, or invalid UTF-8, means the
    // terminal cannot render this safely as text.
    if (std.mem.indexOfScalar(u8, content, 0) != null) return null;
    if (!std.unicode.utf8ValidateSlice(content)) return null;

    if (content.len == 0) return try initMessage(alloc, "(empty file)");

    const TextSpan = struct { start: usize, len: usize };
    var storage: std.ArrayList(u8) = .empty;
    defer storage.deinit(alloc);
    var spans: std.ArrayList(TextSpan) = .empty;
    defer spans.deinit(alloc);

    var line_limit_reached = false;
    var iterator = std.mem.splitScalar(u8, content, '\n');
    while (iterator.next()) |raw_line| {
        if (spans.items.len == max_preview_lines) {
            // A file ending in a newline yields one final empty segment; it
            // does not represent an additional visible row.
            line_limit_reached = raw_line.len != 0 or iterator.rest().len != 0;
            break;
        }
        const start = storage.items.len;
        try appendSanitizedText(alloc, &storage, raw_line);
        try spans.append(alloc, .{
            .start = start,
            .len = storage.items.len - start,
        });
    }
    // splitScalar yields a trailing empty segment for content ending in '\n';
    // drop it so the list holds exactly the visible lines.
    if (!line_limit_reached and spans.items.len > 0 and spans.items[spans.items.len - 1].len == 0) {
        _ = spans.pop();
    }
    if (spans.items.len == 0) return try initMessage(alloc, "(empty file)");

    if (size > content.len or line_limit_reached) {
        const start = storage.items.len;
        try storage.appendSlice(alloc, "… (truncated)");
        try spans.append(alloc, .{
            .start = start,
            .len = storage.items.len - start,
        });
    }

    const text_storage = try storage.toOwnedSlice(alloc);
    errdefer alloc.free(text_storage);
    const rows = try alloc.alloc(Row, spans.items.len);
    for (rows, spans.items) |*row, span| {
        row.* = .{ .text = text_storage[span.start..][0..span.len] };
    }
    return .{
        .alloc = alloc,
        .rows = rows,
        .text_storage = text_storage,
    };
}

/// Appends one sanitized source line to the preview's contiguous text storage.
/// Tabs expand to four spaces; other control characters are dropped so
/// terminal escape sequences cannot hide inside file contents.
fn appendSanitizedText(
    alloc: Allocator,
    storage: *std.ArrayList(u8),
    raw_line: []const u8,
) Allocator.Error!void {
    for (raw_line) |byte| {
        switch (byte) {
            '\t' => try storage.appendSlice(alloc, "    "),
            0x00...0x08, 0x0a...0x1f, 0x7f => {},
            else => try storage.append(alloc, byte),
        }
    }
}

fn checkTextAllocationFailures(
    alloc: Allocator,
    io: Io,
    path: []const u8,
) !void {
    var preview = (try initTextContent(alloc, io, path, null, max_preview_bytes)).?;
    defer preview.deinit();
}

fn checkSheetAllocationFailures(
    alloc: Allocator,
    path: []const u8,
) !void {
    var identities: IdentityCache = .{};
    defer identities.deinit(alloc);
    var preview = try initFile(alloc, &identities, path, null);
    defer preview.deinit();
}

test "preview builders release every allocation failure" {
    const testing = std.testing;
    var tree = try test_support.TempTree.init(testing.allocator, testing.io);
    defer tree.deinit();
    try tree.writeFile("notes.txt", "alpha\nbeta\ngamma");

    const path = try tree.absolutePath("notes.txt");
    defer testing.allocator.free(path);
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkTextAllocationFailures,
        .{ testing.io, path },
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkSheetAllocationFailures,
        .{path},
    );
}

test "text file preview splits sanitized lines" {
    const testing = std.testing;
    var tree = try test_support.TempTree.init(testing.allocator, testing.io);
    defer tree.deinit();
    try tree.writeFile("notes.txt", "alpha\r\nbe\tta\nga\x01mma\nfinal");

    const path = try tree.absolutePath("notes.txt");
    defer testing.allocator.free(path);

    var preview = try initTextContent(
        testing.allocator,
        testing.io,
        path,
        null,
        max_preview_bytes,
    );
    try testing.expect(preview != null);
    defer preview.?.deinit();

    try testing.expectEqual(@as(usize, 4), preview.?.rows.len);
    for (preview.?.rows) |row| try testing.expect(row == .text);
    try testing.expectEqualStrings("alpha", preview.?.displayTextAt(0).?);
    try testing.expectEqualStrings("be    ta", preview.?.displayTextAt(1).?);
    try testing.expectEqualStrings("gamma", preview.?.displayTextAt(2).?);
    try testing.expectEqualStrings("final", preview.?.displayTextAt(3).?);
    const storage = preview.?.text_storage.?;
    const storage_start = @intFromPtr(storage.ptr);
    const storage_end = storage_start + storage.len;
    for (preview.?.rows) |row| {
        const text = row.text;
        const start = @intFromPtr(text.ptr);
        try testing.expect(start >= storage_start and start + text.len <= storage_end);
    }
}

test "text preview caps source lines in contiguous storage" {
    const testing = std.testing;
    var tree = try test_support.TempTree.init(testing.allocator, testing.io);
    defer tree.deinit();

    const source_line_count = max_preview_lines + 2;
    const content = try testing.allocator.alloc(u8, source_line_count * 2);
    defer testing.allocator.free(content);
    for (0..source_line_count) |index| {
        content[index * 2] = 'x';
        content[index * 2 + 1] = '\n';
    }
    try tree.writeFile("many-lines.txt", content);

    const path = try tree.absolutePath("many-lines.txt");
    defer testing.allocator.free(path);
    var preview = (try initTextContent(
        testing.allocator,
        testing.io,
        path,
        null,
        content.len,
    )).?;
    defer preview.deinit();

    try testing.expectEqual(max_preview_lines + 1, preview.rows.len);
    try testing.expectEqualStrings("x", preview.displayTextAt(max_preview_lines - 1).?);
    try testing.expectEqualStrings("… (truncated)", preview.displayTextAt(max_preview_lines).?);
    try testing.expect(preview.text_storage != null);
}

test "binary and invalid utf-8 files decline text preview" {
    const testing = std.testing;
    var tree = try test_support.TempTree.init(testing.allocator, testing.io);
    defer tree.deinit();
    try tree.writeFile("blob.bin", "ok\x00not ok");
    try tree.writeFile("mojibake.txt", "\xff\xfe broken");

    const binary_path = try tree.absolutePath("blob.bin");
    defer testing.allocator.free(binary_path);
    try testing.expect(try initTextContent(
        testing.allocator,
        testing.io,
        binary_path,
        null,
        max_preview_bytes,
    ) == null);

    const invalid_path = try tree.absolutePath("mojibake.txt");
    defer testing.allocator.free(invalid_path);
    try testing.expect(try initTextContent(
        testing.allocator,
        testing.io,
        invalid_path,
        null,
        max_preview_bytes,
    ) == null);
}

test "empty file previews as a placeholder message" {
    const testing = std.testing;
    var tree = try test_support.TempTree.init(testing.allocator, testing.io);
    defer tree.deinit();
    try tree.writeFile("hollow.txt", "");

    const path = try tree.absolutePath("hollow.txt");
    defer testing.allocator.free(path);

    var preview = try initTextContent(
        testing.allocator,
        testing.io,
        path,
        0,
        max_preview_bytes,
    );
    try testing.expect(preview != null);
    defer preview.?.deinit();

    try testing.expect(preview.?.rows[0] == .notice);
    try testing.expectEqualStrings("(empty file)", preview.?.displayTextAt(0).?);
}

test "oversized files truncate with a marker line" {
    const testing = std.testing;
    var tree = try test_support.TempTree.init(testing.allocator, testing.io);
    defer tree.deinit();
    try tree.writeFile("long.txt", "0123456789\nabcdefghij\nklmnopqrst\n");

    const path = try tree.absolutePath("long.txt");
    defer testing.allocator.free(path);

    var preview = try initTextContent(testing.allocator, testing.io, path, null, 16);
    try testing.expect(preview != null);
    defer preview.?.deinit();

    // The 16-byte cap ends mid-line; partial lines render as-is.
    try testing.expectEqualStrings("0123456789", preview.?.displayTextAt(0).?);
    try testing.expectEqualStrings("abcde", preview.?.displayTextAt(1).?);
    try testing.expectEqualStrings("… (truncated)", preview.?.displayTextAt(2).?);
    try testing.expectEqual(@as(usize, 3), preview.?.rows.len);
}

test "file symlink sheets follow targets behind the notice" {
    const testing = std.testing;
    var tree = try test_support.TempTree.init(testing.allocator, testing.io);
    defer tree.deinit();
    try tree.writeFile("blob.dat", "bin\x00ary");
    try tree.symLink("blob.dat", "link.dat");

    const path = try tree.absolutePath("link.dat");
    defer testing.allocator.free(path);

    var identities: IdentityCache = .{};
    defer identities.deinit(testing.allocator);

    var preview = try initFileFollow(testing.allocator, &identities, path);
    defer preview.deinit();

    // The sheet describes the followed file, not the link, and its one layout
    // test keeps notice/spacer/field order explicit.
    try testing.expectEqual(@as(usize, 10), preview.rows.len);
    try testing.expect(preview.rows[0] == .notice);
    try testing.expect(preview.rows[1] == .spacer);
    try testing.expectEqualStrings(
        "non-text files are not rendered",
        preview.displayTextAt(0).?,
    );
    const expected_labels = [_][]const u8{
        "Name", "Type", "Mode", "Owner", "Size", "Modified", "Writable", "Links",
    };
    for (expected_labels, 2..) |label, index| switch (preview.rows[index]) {
        .field => |field| try testing.expectEqualStrings(label, field.label),
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings("link.dat", preview.fieldValue("Name").?);
    try testing.expectEqualStrings("file", preview.fieldValue("Type").?);
}
