//! Relative symlink lookup used while building listings.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;

const linux = @import("symlink/linux.zig");

pub const ReadError = Allocator.Error || Dir.ReadLinkError || Dir.StatFileError;

pub const Result = struct {
    /// Owned by the allocator passed to `read`.
    target: []const u8,
    /// Whether following the link resolves to a directory.
    is_dir: bool,
};

/// Returns a relative link's target, owned by `alloc`, and whether it resolves
/// to a directory. Target-resolution failures leave the link non-navigable.
pub fn read(alloc: Allocator, io: Io, dir: Dir, name: []const u8) ReadError!Result {
    var buffer: [Dir.max_path_bytes]u8 = undefined;
    const length = try dir.readLink(io, name, &buffer);
    // readLink reports bytes written, including a possibly truncated buffer.
    if (length == buffer.len) return error.NameTooLong;
    const target = try alloc.dupe(u8, buffer[0..length]);
    errdefer alloc.free(target);

    const is_dir = is_dir: {
        // Zig 0.16's Linux statFile treats ENAMETOOLONG from symlink
        // resolution as a programmer bug, even for a short input name.
        if (comptime builtin.os.tag == .linux) break :is_dir try linux.isDirectory(dir, name);
        const stat = dir.statFile(io, name, .{}) catch |err| switch (err) {
            // Keep dangling or inaccessible links visible but non-navigable.
            error.AccessDenied,
            error.PermissionDenied,
            error.SymLinkLoop,
            error.NameTooLong,
            error.FileNotFound,
            error.NotDir,
            => break :is_dir false,
            else => return err,
        };
        break :is_dir stat.kind == .directory;
    };
    return .{ .target = target, .is_dir = is_dir };
}
