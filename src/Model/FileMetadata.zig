//! One file's metadata as returned by a single relative `statx` call.

const std = @import("std");
const Io = std.Io;

const FileMetadata = @This();

kind: Io.File.Kind,
size: u64,
mtime: Io.Timestamp,
nlink: u64,
mode: u32,
uid: u32,
gid: u32,

/// Stats `path` without following symlinks. The error set contains no
/// allocation failure; every failure is an `statx` outcome.
pub fn init(path: []const u8) !FileMetadata {
    const linux = std.os.linux;
    const path_z = try std.posix.toPosixPath(path);
    const requested: linux.STATX = .{
        .TYPE = true,
        .MODE = true,
        .NLINK = true,
        .UID = true,
        .GID = true,
        .MTIME = true,
        .SIZE = true,
    };

    var statx = std.mem.zeroes(linux.Statx);
    while (true) switch (linux.errno(linux.statx(
        linux.AT.FDCWD,
        &path_z,
        linux.AT.NO_AUTOMOUNT | linux.AT.SYMLINK_NOFOLLOW,
        requested,
        &statx,
    ))) {
        .SUCCESS => break,
        .INTR => continue,
        .ACCES => return error.AccessDenied,
        .LOOP => return error.SymLinkLoop,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NOMEM => return error.SystemResources,
        else => |err| return std.posix.unexpectedErrno(err),
    };

    const actual_mask: u32 = @bitCast(statx.mask);
    const requested_mask: u32 = @bitCast(requested);
    if (actual_mask & requested_mask != requested_mask) return error.Unexpected;

    const mode: u32 = statx.mode;
    return .{
        .kind = kindFromLinuxMode(statx.mode),
        .size = statx.size,
        .mtime = .{
            .nanoseconds = @intCast(
                @as(i128, statx.mtime.sec) * std.time.ns_per_s + statx.mtime.nsec,
            ),
        },
        .nlink = statx.nlink,
        .mode = mode,
        .uid = statx.uid,
        .gid = statx.gid,
    };
}

fn kindFromLinuxMode(mode: u16) Io.File.Kind {
    const linux = std.os.linux;
    return switch (mode & linux.S.IFMT) {
        linux.S.IFBLK => .block_device,
        linux.S.IFCHR => .character_device,
        linux.S.IFDIR => .directory,
        linux.S.IFIFO => .named_pipe,
        linux.S.IFLNK => .sym_link,
        linux.S.IFREG => .file,
        linux.S.IFSOCK => .unix_domain_socket,
        else => .unknown,
    };
}
