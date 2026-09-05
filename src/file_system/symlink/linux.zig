//! Linux target classification that tolerates overlong symlink resolution.

const std = @import("std");
const Dir = std.Io.Dir;
const linux = std.os.linux;
const log = std.log.scoped(.file_system);

/// Keeps dangling or inaccessible targets non-navigable. Zig 0.16's
/// Io.Dir.statFile cannot safely handle ENAMETOOLONG from a link target.
pub fn isDirectory(dir: Dir, name: []const u8) Dir.StatFileError!bool {
    const name_z = try std.posix.toPosixPath(name);
    const requested: linux.STATX = .{ .TYPE = true };
    var statx = std.mem.zeroes(linux.Statx);
    while (true) switch (linux.errno(linux.statx(
        dir.handle,
        &name_z,
        linux.AT.NO_AUTOMOUNT,
        requested,
        &statx,
    ))) {
        .SUCCESS => break,
        .INTR => continue,
        .ACCES, .LOOP, .NAMETOOLONG, .NOENT, .NOTDIR, .PERM => return false,
        .NOMEM => return error.SystemResources,
        // The directory handle, buffers, flags, and requested mask are ours.
        .BADF, .FAULT, .INVAL => unreachable,
        else => |err| {
            log.warn("statx failed with unexpected errno {s}", .{@tagName(err)});
            return std.posix.unexpectedErrno(err);
        },
    };
    if (!statx.mask.TYPE) return error.Unexpected;
    return statx.mode & linux.S.IFMT == linux.S.IFDIR;
}
