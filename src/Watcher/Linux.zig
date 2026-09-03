//! Linux inotify backend for `Watcher`.

const Linux = @This();

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const linux = std.os.linux;
const log = std.log.scoped(.watcher);

comptime {
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) {
        @compileError("the Linux watcher backend requires x86_64 Linux");
    }
}

io: Io,
file: Io.File,
current_descriptor: ?i32 = null,

pub const InitError = error{
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
} || std.posix.UnexpectedError;

pub const ArmError = error{
    AccessDenied,
    FileNotFound,
    NameTooLong,
    NotDir,
    SymLinkLoop,
    SystemResources,
    WatchLimitReached,
} || std.posix.UnexpectedError;

pub const DrainError = std.posix.ReadError || error{MalformedEvent};

pub const Pending = struct {
    descriptor: i32,
    remove_on_cancel: bool,
};

pub const Refresh = enum {
    none,
    content,
    rearm,
};

pub fn init(io: Io) InitError!Linux {
    const rc = linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK);
    return switch (linux.errno(rc)) {
        .SUCCESS => .{
            .io = io,
            .file = .{
                .handle = @intCast(rc),
                .flags = .{ .nonblocking = true },
            },
        },
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        .INVAL => unreachable,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

pub fn deinit(self: *Linux) void {
    if (self.current_descriptor) |descriptor| self.remove(descriptor);
    Io.File.close(self.file, self.io);
    self.* = undefined;
}

pub fn prepare(self: *Linux, path: []const u8) ArmError!Pending {
    const path_z = try std.posix.toPosixPath(path);

    const mask = linux.IN.CREATE |
        linux.IN.DELETE |
        linux.IN.MOVED_FROM |
        linux.IN.MOVED_TO |
        linux.IN.DELETE_SELF |
        linux.IN.MOVE_SELF |
        linux.IN.UNMOUNT |
        linux.IN.ONLYDIR;
    const rc = linux.inotify_add_watch(self.file.handle, &path_z, mask);
    const descriptor: i32 = switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .ACCES => return error.AccessDenied,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOMEM => return error.SystemResources,
        .NOSPC => return error.WatchLimitReached,
        .NOTDIR => return error.NotDir,
        .BADF, .FAULT, .INVAL => unreachable,
        else => |err| return std.posix.unexpectedErrno(err),
    };
    return .{
        .descriptor = descriptor,
        .remove_on_cancel = self.current_descriptor != descriptor,
    };
}

pub fn commit(self: *Linux, pending: Pending) void {
    const previous = self.current_descriptor;
    self.current_descriptor = pending.descriptor;
    if (previous) |descriptor| {
        if (descriptor != pending.descriptor) self.remove(descriptor);
    }
}

pub fn cancel(self: *Linux, pending: Pending) void {
    if (pending.remove_on_cancel) self.remove(pending.descriptor);
}

pub fn hasCurrent(self: *const Linux) bool {
    return self.current_descriptor != null;
}

pub fn currentId(self: *const Linux) ?usize {
    return if (self.current_descriptor) |descriptor| @intCast(descriptor) else null;
}

pub fn drain(self: *Linux, show_hidden: bool) DrainError!Refresh {
    var refresh: Refresh = .none;
    var buffer: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
    while (true) {
        const count = std.posix.read(self.file.handle, &buffer) catch |err| switch (err) {
            error.WouldBlock => return refresh,
            else => return err,
        };
        if (count == 0) return refresh;

        var offset: usize = 0;
        while (offset < count) {
            if (count - offset < @sizeOf(linux.inotify_event)) return error.MalformedEvent;
            const event: *const linux.inotify_event = @ptrCast(@alignCast(&buffer[offset]));
            const event_size = @sizeOf(linux.inotify_event) + event.len;
            if (event_size > count - offset) return error.MalformedEvent;
            offset += event_size;

            if (event.mask & linux.IN.Q_OVERFLOW != 0) {
                refresh = .rearm;
                continue;
            }
            if (event.wd != (self.current_descriptor orelse continue)) continue;

            const invalidating = linux.IN.DELETE_SELF |
                linux.IN.MOVE_SELF |
                linux.IN.UNMOUNT |
                linux.IN.IGNORED;
            if (event.mask & invalidating != 0) {
                const descriptor = self.current_descriptor.?;
                self.current_descriptor = null;
                self.remove(descriptor);
                refresh = .rearm;
                continue;
            }

            const content = linux.IN.CREATE |
                linux.IN.DELETE |
                linux.IN.MOVED_FROM |
                linux.IN.MOVED_TO;
            if (event.mask & content != 0) {
                const name = event.getName() orelse {
                    if (refresh == .none) refresh = .content;
                    continue;
                };
                if (show_hidden or name.len == 0 or name[0] != '.') {
                    if (refresh == .none) refresh = .content;
                }
            }
        }
    }
}

fn remove(self: *Linux, descriptor: i32) void {
    while (true) switch (linux.errno(linux.inotify_rm_watch(
        self.file.handle,
        descriptor,
    ))) {
        .SUCCESS, .INVAL => return,
        .INTR => continue,
        .BADF => unreachable,
        else => |err| {
            log.warn("failed to remove inotify watch: {s}", .{@tagName(err)});
            return;
        },
    };
}
