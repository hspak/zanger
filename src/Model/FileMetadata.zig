//! One file's metadata as returned by one native stat call.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const native = switch (builtin.os.tag) {
    .linux => @import("FileMetadata/linux.zig"),
    .macos => @import("FileMetadata/macos.zig"),
    else => @compileError("Zanger supports only Linux and macOS"),
};

const FileMetadata = @This();

kind: Io.File.Kind,
size: u64,
mtime: Io.Timestamp,
nlink: u64,
mode: u32,
uid: u32,
gid: u32,

/// Errors from path conversion, native stat error mapping, and unexpected
/// kernel responses.
pub const InitError = native.InitError;

/// Stats `path` without following symlinks. The error set contains no
/// allocation failure; every failure is a native stat outcome.
pub fn init(path: []const u8) InitError!FileMetadata {
    return initPath(path, false);
}

/// Stats `path`, resolving symbolic links to their targets. Used when a
/// preview describes what a linked file behaves as rather than the link
/// itself.
pub fn initFollow(path: []const u8) InitError!FileMetadata {
    return initPath(path, true);
}

fn initPath(path: []const u8, comptime follow_symlinks: bool) InitError!FileMetadata {
    return native.init(FileMetadata, path, follow_symlinks);
}
