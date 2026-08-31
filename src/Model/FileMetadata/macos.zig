//! macOS metadata query using `fstatat`.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const log = std.log.scoped(.file_metadata);
const posix = std.posix;

comptime {
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) {
        @compileError("the macOS metadata backend requires aarch64 macOS");
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
    } || posix.UnexpectedError;

/// Populates `Result` from one `fstatat`, following the final symlink when
/// `follow_symlinks` is true.
pub fn init(
    comptime Result: type,
    path: []const u8,
    comptime follow_symlinks: bool,
) InitError!Result {
    const path_z = try posix.toPosixPath(path);
    const at_flags: u32 = if (follow_symlinks) 0 else posix.AT.SYMLINK_NOFOLLOW;

    var stat = std.mem.zeroes(posix.Stat);
    while (true) switch (posix.errno(posix.system.fstatat(
        posix.AT.FDCWD,
        &path_z,
        &stat,
        at_flags,
    ))) {
        .SUCCESS => break,
        .INTR => continue,
        .ACCES, .PERM => return error.AccessDenied,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NOMEM => return error.SystemResources,
        .BADF, .FAULT, .INVAL => unreachable,
        else => |err| {
            log.warn("fstatat failed with unexpected errno {s}", .{@tagName(err)});
            return posix.unexpectedErrno(err);
        },
    };

    const mtime = stat.mtime();
    return .{
        .kind = kindFromMode(stat.mode),
        .size = @bitCast(stat.size),
        .mtime = .{
            .nanoseconds = @intCast(
                @as(i128, mtime.sec) * std.time.ns_per_s + mtime.nsec,
            ),
        },
        .nlink = stat.nlink,
        .mode = stat.mode,
        .uid = stat.uid,
        .gid = stat.gid,
    };
}

fn kindFromMode(mode: u16) Io.File.Kind {
    return switch (mode & posix.S.IFMT) {
        posix.S.IFBLK => .block_device,
        posix.S.IFCHR => .character_device,
        posix.S.IFDIR => .directory,
        posix.S.IFIFO => .named_pipe,
        posix.S.IFLNK => .sym_link,
        posix.S.IFREG => .file,
        posix.S.IFSOCK => .unix_domain_socket,
        posix.S.IFWHT => .whiteout,
        else => .unknown,
    };
}
