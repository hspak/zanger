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

/// Eight-line metadata sheet for a regular file. `loaded_metadata` may carry
/// metadata already stat'ed for the same path; otherwise one `statx` runs.
pub fn initFile(
    alloc: Allocator,
    identities: *IdentityCache,
    path: []const u8,
    loaded_metadata: ?FileMetadata,
) !Preview {
    const metadata = loaded_metadata orelse try FileMetadata.init(path);

    var made: usize = 0;
    const lines = try alloc.alloc([]const u8, 8);
    errdefer {
        for (lines[0..made]) |line| alloc.free(line);
        alloc.free(lines);
    }

    lines[0] = try std.fmt.allocPrint(alloc, "Name: {s}", .{std.fs.path.basename(path)});
    made += 1;
    lines[1] = try std.fmt.allocPrint(alloc, "Type: {s}", .{@tagName(metadata.kind)});
    made += 1;
    lines[2] = try formatMode(alloc, metadata.kind, metadata.mode);
    made += 1;
    lines[3] = try formatOwner(alloc, identities, metadata.uid, metadata.gid);
    made += 1;
    lines[4] = try std.fmt.allocPrint(alloc, "Size: {Bi:.2} ({d} bytes)", .{
        metadata.size,
        metadata.size,
    });
    made += 1;
    lines[5] = try formatModifiedTime(alloc, metadata.mtime);
    made += 1;
    lines[6] = try std.fmt.allocPrint(
        alloc,
        "Writable: {s}",
        .{if (metadata.mode & 0o222 == 0) "no" else "yes"},
    );
    made += 1;
    lines[7] = try std.fmt.allocPrint(alloc, "Links: {d}", .{metadata.nlink});

    return .{ .alloc = alloc, .lines = lines };
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
