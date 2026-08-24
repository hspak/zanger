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

const Preview = @This();

/// How a preview's lines should render. Metadata sheets bold the key up to
/// the first colon; text and placeholder lines render verbatim.
pub const Kind = enum {
    /// A single dimmed italic status message.
    placeholder,
    /// File metadata sheet lines shaped like `Key: value`.
    metadata,
    /// Verbatim file content lines.
    text,
};

alloc: Allocator,
lines: []const []const u8 = &.{},
kind: Kind = .metadata,
/// Number of leading lines rendered with placeholder styling ahead of
/// otherwise metadata-kind content, including any blank separator.
header_lines: usize = 0,

pub fn deinit(self: *Preview) void {
    for (self.lines) |line| self.alloc.free(line);
    self.alloc.free(self.lines);
    self.* = undefined;
}

/// A single italic message line, such as the empty-directory placeholder.
pub fn initMessage(alloc: Allocator, message: []const u8) Allocator.Error!Preview {
    const lines = try alloc.alloc([]const u8, 1);
    errdefer alloc.free(lines);
    lines[0] = try alloc.dupe(u8, message);
    return .{
        .alloc = alloc,
        .lines = lines,
        .kind = .placeholder,
    };
}

/// A dimmed non-text notice, one blank separator line, and an eight-line
/// metadata sheet for a regular file whose contents are not rendered.
/// `loaded_metadata` may carry metadata already stat'ed for the same path;
/// otherwise one `statx` runs.
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
    const lines = try alloc.alloc([]const u8, 10);
    errdefer {
        for (lines[0..made]) |line| alloc.free(line);
        alloc.free(lines);
    }

    lines[0] = try alloc.dupe(u8, "non-text files are not rendered");
    made += 1;
    lines[1] = try alloc.dupe(u8, "");
    made += 1;
    lines[2] = try std.fmt.allocPrint(alloc, "Name: {s}", .{std.fs.path.basename(path)});
    made += 1;
    lines[3] = try std.fmt.allocPrint(alloc, "Type: {s}", .{@tagName(metadata.kind)});
    made += 1;
    lines[4] = try formatMode(alloc, metadata.kind, metadata.mode);
    made += 1;
    lines[5] = try formatOwner(alloc, identities, metadata.uid, metadata.gid);
    made += 1;
    lines[6] = try std.fmt.allocPrint(alloc, "Size: {Bi:.2} ({d} bytes)", .{
        metadata.size,
        metadata.size,
    });
    made += 1;
    lines[7] = try formatModifiedTime(alloc, metadata.mtime);
    made += 1;
    lines[8] = try std.fmt.allocPrint(
        alloc,
        "Writable: {s}",
        .{if (metadata.mode & 0o222 == 0) "no" else "yes"},
    );
    made += 1;
    lines[9] = try std.fmt.allocPrint(alloc, "Links: {d}", .{metadata.nlink});

    return .{
        .alloc = alloc,
        .lines = lines,
        .kind = .metadata,
        .header_lines = 2,
    };
}

fn formatMode(
    alloc: Allocator,
    kind: Io.File.Kind,
    mode: u32,
) Allocator.Error![]const u8 {
    const bits = format.modeBits(kind, mode);
    return std.fmt.allocPrint(alloc, "Mode: {s}", .{bits[0..]});
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
        "Owner: {s}:{s} ({d}:{d})",
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
            "Modified: {d} ns since Unix epoch",
            .{timestamp.nanoseconds},
        );
    }

    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    return std.fmt.allocPrint(
        alloc,
        "Modified: {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC",
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

    var lines: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (lines.items) |line| alloc.free(line);
        lines.deinit(alloc);
    }
    var iterator = std.mem.splitScalar(u8, content, '\n');
    while (iterator.next()) |raw_line| {
        try appendTextLine(alloc, &lines, raw_line);
    }
    // splitScalar yields a trailing empty segment for content ending in '\n';
    // drop it so the list holds exactly the visible lines.
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) {
        const last = lines.pop().?;
        alloc.free(last);
    }
    if (lines.items.len == 0) return try initMessage(alloc, "(empty file)");

    if (size > content.len) {
        try appendTextLine(alloc, &lines, "… (truncated)");
    }

    return .{
        .alloc = alloc,
        .lines = try lines.toOwnedSlice(alloc),
        .kind = .text,
    };
}

/// Copies one source line into an owned display line. Tabs expand to four
/// spaces; other control characters are dropped so terminal escape sequences
/// cannot hide inside file contents.
fn appendTextLine(
    alloc: Allocator,
    lines: *std.ArrayList([]const u8),
    raw_line: []const u8,
) Allocator.Error!void {
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(alloc);
    for (raw_line) |byte| {
        switch (byte) {
            '\t' => try line.appendSlice(alloc, "    "),
            0x00...0x08, 0x0a...0x1f, 0x7f => {},
            else => try line.append(alloc, byte),
        }
    }
    try lines.append(alloc, try line.toOwnedSlice(alloc));
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

    try testing.expectEqual(Kind.text, preview.?.kind);
    try testing.expectEqual(@as(usize, 4), preview.?.lines.len);
    try testing.expectEqualStrings("alpha", preview.?.lines[0]);
    try testing.expectEqualStrings("be    ta", preview.?.lines[1]);
    try testing.expectEqualStrings("gamma", preview.?.lines[2]);
    try testing.expectEqualStrings("final", preview.?.lines[3]);
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

    try testing.expectEqual(Kind.placeholder, preview.?.kind);
    try testing.expectEqualStrings("(empty file)", preview.?.lines[0]);
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

    try testing.expectEqual(Kind.text, preview.?.kind);
    // The 16-byte cap ends mid-line; partial lines render as-is.
    try testing.expectEqualStrings("0123456789", preview.?.lines[0]);
    try testing.expectEqualStrings("abcde", preview.?.lines[1]);
    try testing.expectEqualStrings("… (truncated)", preview.?.lines[2]);
    try testing.expectEqual(@as(usize, 3), preview.?.lines.len);
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

    // The sheet describes the followed file, not the link.
    try testing.expectEqual(@as(usize, 2), preview.header_lines);
    try testing.expectEqualStrings(
        "non-text files are not rendered",
        preview.lines[0],
    );
    try testing.expectEqualStrings("", preview.lines[1]);
    try testing.expectEqualStrings("Name: link.dat", preview.lines[2]);
    try testing.expectEqualStrings("Type: file", preview.lines[3]);
}
