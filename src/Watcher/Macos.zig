//! macOS kqueue backend for `Watcher`.

const Macos = @This();

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const c = std.c;
const log = std.log.scoped(.watcher);
const posix = std.posix;

comptime {
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) {
        @compileError("the macOS watcher backend requires aarch64 macOS");
    }
}

io: Io,
queue_descriptor: i32,
current_descriptor: ?i32 = null,

pub const InitError = error{
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
} || posix.UnexpectedError;

pub const ArmError = error{
    AccessDenied,
    FileNotFound,
    NameTooLong,
    NotDir,
    SymLinkLoop,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    UnsupportedFileSystem,
} || posix.UnexpectedError;

pub const DrainError = posix.UnexpectedError;

/// A prepared watch owns its directory descriptor. Closing that descriptor
/// atomically removes its EVFILT_VNODE registration from the kqueue.
pub const Pending = struct {
    descriptor: i32,
};

pub const Refresh = enum {
    none,
    content,
    rearm,
};

pub fn init(io: Io) InitError!Macos {
    const descriptor = descriptor: {
        const result = c.kqueue();
        switch (posix.errno(result)) {
            .SUCCESS => break :descriptor result,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            else => |err| return posix.unexpectedErrno(err),
        }
    };
    errdefer close(io, descriptor);

    // kqueue descriptors are not inherited by fork, but close-on-exec also
    // protects process-spawn implementations that do not fork.
    while (true) switch (posix.errno(c.fcntl(
        descriptor,
        c.F.SETFD,
        @as(c_int, c.FD_CLOEXEC),
    ))) {
        .SUCCESS => break,
        .INTR => continue,
        .BADF, .INVAL => unreachable,
        else => |err| return posix.unexpectedErrno(err),
    };

    return .{
        .io = io,
        .queue_descriptor = descriptor,
    };
}

pub fn deinit(self: *Macos) void {
    if (self.current_descriptor) |descriptor| close(self.io, descriptor);
    close(self.io, self.queue_descriptor);
    self.* = undefined;
}

pub fn prepare(self: *Macos, path: []const u8) ArmError!Pending {
    const path_z = try posix.toPosixPath(path);
    const descriptor = descriptor: {
        const result = c.open(&path_z, c.O{
            .EVTONLY = true,
            .DIRECTORY = true,
            .CLOEXEC = true,
        });
        switch (posix.errno(result)) {
            .SUCCESS => break :descriptor result,
            .ACCES, .PERM => return error.AccessDenied,
            .LOOP => return error.SymLinkLoop,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOMEM => return error.SystemResources,
            .NOTDIR => return error.NotDir,
            .FAULT, .INVAL => unreachable,
            else => |err| return posix.unexpectedErrno(err),
        }
    };
    errdefer close(self.io, descriptor);

    const change: [1]c.Kevent = .{.{
        .ident = @intCast(descriptor),
        .filter = c.EVFILT.VNODE,
        .flags = c.EV.ADD | c.EV.ENABLE | c.EV.CLEAR,
        .fflags = c.NOTE.DELETE |
            c.NOTE.WRITE |
            c.NOTE.EXTEND |
            c.NOTE.ATTRIB |
            c.NOTE.LINK |
            c.NOTE.RENAME |
            c.NOTE.REVOKE,
        .data = 0,
        .udata = 0,
    }};
    var unused_event: [1]c.Kevent = undefined;
    while (true) switch (posix.errno(c.kevent(
        self.queue_descriptor,
        &change,
        change.len,
        &unused_event,
        0,
        null,
    ))) {
        .SUCCESS => break,
        .INTR => continue,
        .ACCES => return error.AccessDenied,
        .NOMEM => return error.SystemResources,
        .OPNOTSUPP => return error.UnsupportedFileSystem,
        .BADF, .FAULT, .INVAL, .NOENT => unreachable,
        else => |err| return posix.unexpectedErrno(err),
    };

    return .{ .descriptor = descriptor };
}

pub fn commit(self: *Macos, pending: Pending) void {
    const previous = self.current_descriptor;
    self.current_descriptor = pending.descriptor;
    if (previous) |descriptor| close(self.io, descriptor);
}

pub fn cancel(self: *Macos, pending: Pending) void {
    close(self.io, pending.descriptor);
}

pub fn hasCurrent(self: *const Macos) bool {
    return self.current_descriptor != null;
}

pub fn currentId(self: *const Macos) ?usize {
    return if (self.current_descriptor) |descriptor| @intCast(descriptor) else null;
}

pub fn drain(self: *Macos, show_hidden: bool) DrainError!Refresh {
    // EVFILT_VNODE identifies the changed directory, not the child name. A
    // hidden-only mutation therefore causes a conservative snapshot refresh.
    _ = show_hidden;

    var refresh: Refresh = .none;
    var events: [16]c.Kevent = undefined;
    const timeout: c.timespec = .{ .sec = 0, .nsec = 0 };
    while (true) {
        const count: usize = while (true) {
            const rc = c.kevent(
                self.queue_descriptor,
                &events,
                0,
                &events,
                events.len,
                &timeout,
            );
            switch (posix.errno(rc)) {
                .SUCCESS => break @intCast(rc),
                .INTR => continue,
                .BADF, .FAULT, .INVAL => unreachable,
                else => |err| return posix.unexpectedErrno(err),
            }
        };
        if (count == 0) return refresh;

        for (events[0..count]) |event| {
            const current = self.current_descriptor orelse continue;
            if (event.ident != @as(usize, @intCast(current))) continue;

            if (event.flags & c.EV.ERROR != 0) {
                log.warn("kqueue watch failed with errno {d}", .{event.data});
                self.current_descriptor = null;
                close(self.io, current);
                refresh = .rearm;
                continue;
            }

            const invalidating = c.NOTE.DELETE | c.NOTE.RENAME | c.NOTE.REVOKE;
            if (event.fflags & invalidating != 0) {
                self.current_descriptor = null;
                close(self.io, current);
                refresh = .rearm;
                continue;
            }

            const content = c.NOTE.WRITE |
                c.NOTE.EXTEND |
                c.NOTE.ATTRIB |
                c.NOTE.LINK;
            if (event.fflags & content != 0 and refresh == .none) refresh = .content;
        }
    }
}

fn close(io: Io, descriptor: i32) void {
    Io.File.close(.{
        .handle = descriptor,
        .flags = .{ .nonblocking = false },
    }, io);
}
