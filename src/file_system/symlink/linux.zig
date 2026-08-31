//! Linux relative symlink lookup using `readlinkat` and `statx`.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const linux = std.os.linux;
const log = std.log.scoped(.file_system);

comptime {
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) {
        @compileError("the Linux symlink backend requires x86_64 Linux");
    }
}

pub const ReadError =
    Allocator.Error ||
    error{
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

/// Populates `Result` with a target owned by `alloc`, following the link only
/// to classify directory targets. Resolution failures produce `is_dir = false`.
pub fn read(
    comptime Result: type,
    alloc: Allocator,
    dir: Dir,
    name: []const u8,
) ReadError!Result {
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
            // The caller supplies a live directory handle and stack buffers.
            .BADF, .FAULT => unreachable,
            else => |err| {
                log.warn("readlinkat failed with unexpected errno {s}", .{@tagName(err)});
                return std.posix.unexpectedErrno(err);
            },
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
            // Keep dangling or inaccessible links visible but non-navigable.
            .ACCES, .LOOP, .NAMETOOLONG, .NOENT, .NOTDIR, .PERM => break :is_dir false,
            .NOMEM => return error.SystemResources,
            // The inputs and requested mask are controlled above.
            .BADF, .FAULT, .INVAL => unreachable,
            else => |err| {
                log.warn("statx failed with unexpected errno {s}", .{@tagName(err)});
                return std.posix.unexpectedErrno(err);
            },
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
