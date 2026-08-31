//! Linux metadata query using `statx`.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const log = std.log.scoped(.file_metadata);

comptime {
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) {
        @compileError("the Linux metadata backend requires x86_64 Linux");
    }
}

pub const InitError =
    error{
        NameTooLong,
        AccessDenied,
        SymLinkLoop,
        FileNotFound,
        NotDir,
        SystemResources,
    } || std.posix.UnexpectedError;

/// Populates `Result` from one `statx`, following the final symlink when
/// `follow_symlinks` is true.
pub fn init(
    comptime Result: type,
    path: []const u8,
    comptime follow_symlinks: bool,
) InitError!Result {
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
    // AT.SYMLINK_NOFOLLOW's packed-struct bit comes from a comptime int, so
    // build the flag word as a runtime u32 instead.
    const at_flags = if (follow_symlinks)
        linux.AT.NO_AUTOMOUNT
    else
        linux.AT.NO_AUTOMOUNT | linux.AT.SYMLINK_NOFOLLOW;

    var statx = std.mem.zeroes(linux.Statx);
    while (true) switch (linux.errno(linux.statx(
        linux.AT.FDCWD,
        &path_z,
        at_flags,
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
        else => |err| {
            log.warn("statx failed with unexpected errno {s}", .{@tagName(err)});
            return std.posix.unexpectedErrno(err);
        },
    };

    const actual_mask: u32 = @bitCast(statx.mask);
    const requested_mask: u32 = @bitCast(requested);
    if (actual_mask & requested_mask != requested_mask) return error.Unexpected;

    const mode: u32 = statx.mode;
    return .{
        .kind = kindFromMode(statx.mode),
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

fn kindFromMode(mode: u16) Io.File.Kind {
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
