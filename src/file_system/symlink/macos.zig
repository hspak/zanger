//! macOS relative symlink lookup using Darwin `readlinkat` and `fstatat`.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const darwin = std.c;
const Dir = std.Io.Dir;
const log = std.log.scoped(.file_system);
const posix = std.posix;

comptime {
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) {
        @compileError("the macOS symlink backend requires aarch64 macOS");
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
    } || posix.UnexpectedError;

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
        const rc = darwin.readlinkat(
            dir.handle,
            @ptrCast(&name_buffer),
            &target_buffer,
            target_buffer.len,
        );
        switch (darwin.errno(rc)) {
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
                return posix.unexpectedErrno(err);
            },
        }
    };
    if (target_length == target_buffer.len) return error.NameTooLong;
    const target = try alloc.dupe(u8, target_buffer[0..target_length]);
    errdefer alloc.free(target);

    const is_dir = is_dir: {
        var stat = std.mem.zeroes(posix.Stat);
        while (true) switch (darwin.errno(darwin.fstatat(
            dir.handle,
            @ptrCast(&name_buffer),
            &stat,
            0,
        ))) {
            .SUCCESS => break,
            .INTR => continue,
            // Keep dangling or inaccessible links visible but non-navigable.
            .ACCES, .LOOP, .NAMETOOLONG, .NOENT, .NOTDIR, .PERM => break :is_dir false,
            .NOMEM => return error.SystemResources,
            // The inputs and flags are controlled above.
            .BADF, .FAULT, .INVAL => unreachable,
            else => |err| {
                log.warn("fstatat failed with unexpected errno {s}", .{@tagName(err)});
                return posix.unexpectedErrno(err);
            },
        };
        break :is_dir stat.mode & posix.S.IFMT == posix.S.IFDIR;
    };
    return .{
        .target = target,
        .is_dir = is_dir,
    };
}
