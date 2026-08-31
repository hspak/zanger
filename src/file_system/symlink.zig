//! Target-selected relative symlink lookup used while building listings.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const native = switch (builtin.os.tag) {
    .linux => @import("symlink/linux.zig"),
    .macos => @import("symlink/macos.zig"),
    else => @compileError("Zanger supports only Linux and macOS"),
};

pub const ReadError = native.ReadError;

pub const Result = struct {
    /// Owned by the allocator passed to `read`.
    target: []const u8,
    /// Whether following the link resolves to a directory.
    is_dir: bool,
};

/// Returns a relative link's target, owned by `alloc`, and whether it resolves
/// to a directory. Target-resolution failures leave the link non-navigable.
pub fn read(alloc: Allocator, dir: Dir, name: []const u8) ReadError!Result {
    return native.read(Result, alloc, dir, name);
}
