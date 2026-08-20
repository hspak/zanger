//! Owns Zanger's Linux inotify descriptor and the active HERE directory watch.

const Watcher = @This();

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const linux = std.os.linux;
const log = std.log.scoped(.watcher);

comptime {
    if (builtin.os.tag != .linux) @compileError("Zanger's watcher requires Linux");
}

io: Io,
file: Io.File,
current_descriptor: ?i32 = null,

pub const InitError = combined: {
    break :combined error{
        ProcessFdQuotaExceeded,
        SystemFdQuotaExceeded,
        SystemResources,
    } || std.posix.UnexpectedError;
};

pub const ArmError = combined: {
    break :combined error{
        AccessDenied,
        FileNotFound,
        NameTooLong,
        NotDir,
        SymLinkLoop,
        SystemResources,
        WatchLimitReached,
    } || std.posix.UnexpectedError;
};

pub const DrainError = combined: {
    break :combined std.posix.ReadError || error{MalformedEvent};
};

/// A watch added during pane preparation but not yet made current.
pub const Pending = struct {
    descriptor: i32,
    remove_on_cancel: bool,
};

/// Strongest refresh action required by the drained inotify events.
pub const Refresh = enum {
    none,
    content,
    rearm,
};

/// Creates one close-on-exec, nonblocking inotify instance.
pub fn init(io: Io) InitError!Watcher {
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

/// Removes the active watch, closes the inotify descriptor, and poisons `self`.
pub fn deinit(self: *Watcher) void {
    if (self.current_descriptor) |descriptor| self.remove(descriptor);
    Io.File.close(self.file, self.io);
    self.* = undefined;
}

/// Adds `path` to the inotify instance without changing the current watch.
/// Call `commit` after the pane transaction succeeds or `cancel` on rollback.
pub fn prepare(self: *Watcher, path: []const u8) ArmError!Pending {
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

/// Makes `pending` current and removes the previous watch.
pub fn commit(self: *Watcher, pending: Pending) void {
    const previous = self.current_descriptor;
    self.current_descriptor = pending.descriptor;
    if (previous) |descriptor| {
        if (descriptor != pending.descriptor) self.remove(descriptor);
    }
}

/// Removes a prepared watch that was not already the current watch.
pub fn cancel(self: *Watcher, pending: Pending) void {
    if (pending.remove_on_cancel) self.remove(pending.descriptor);
}

/// Whether a HERE directory watch is currently active.
pub fn hasCurrent(self: *const Watcher) bool {
    return self.current_descriptor != null;
}

/// Drains all queued events without blocking. Events from retired watches and
/// hidden names excluded from the listing are ignored. Self-invalidating
/// events clear the current watch.
pub fn drain(self: *Watcher, show_hidden: bool) DrainError!Refresh {
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

fn remove(self: *Watcher, descriptor: i32) void {
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

fn tmpAbsPath(alloc: Allocator, temp: *std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, alloc);
    defer alloc.free(cwd);
    return std.fs.path.join(alloc, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
}

test "reports changes only for the current directory" {
    const testing = std.testing;
    var first = testing.tmpDir(.{});
    defer first.cleanup();
    var second = testing.tmpDir(.{});
    defer second.cleanup();

    const first_path = try tmpAbsPath(testing.allocator, &first);
    defer testing.allocator.free(first_path);
    const second_path = try tmpAbsPath(testing.allocator, &second);
    defer testing.allocator.free(second_path);

    var watcher = try Watcher.init(testing.io);
    defer watcher.deinit();
    watcher.commit(try watcher.prepare(first_path));
    try Io.Dir.writeFile(first.dir, testing.io, .{
        .sub_path = "first.txt",
        .data = "first",
    });
    try testing.expectEqual(Refresh.content, try watcher.drain(true));
    try testing.expectEqual(Refresh.none, try watcher.drain(true));

    watcher.commit(try watcher.prepare(second_path));
    try Io.Dir.writeFile(first.dir, testing.io, .{
        .sub_path = "retired.txt",
        .data = "retired",
    });
    try Io.Dir.writeFile(second.dir, testing.io, .{
        .sub_path = "second.txt",
        .data = "second",
    });
    try testing.expectEqual(Refresh.content, try watcher.drain(true));
}

test "clears a watch invalidated by directory deletion" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.createDir(temp.dir, testing.io, "watched", .default_dir);

    const root_path = try tmpAbsPath(testing.allocator, &temp);
    defer testing.allocator.free(root_path);
    const watched_path = try std.fs.path.join(testing.allocator, &.{ root_path, "watched" });
    defer testing.allocator.free(watched_path);

    var watcher = try Watcher.init(testing.io);
    defer watcher.deinit();
    watcher.commit(try watcher.prepare(watched_path));
    try Io.Dir.deleteDir(temp.dir, testing.io, "watched");

    try testing.expectEqual(Refresh.rearm, try watcher.drain(true));
    try testing.expect(!watcher.hasCurrent());
}

test "ignores hidden entry changes when hidden files are excluded" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();

    const path = try tmpAbsPath(testing.allocator, &temp);
    defer testing.allocator.free(path);

    var watcher = try Watcher.init(testing.io);
    defer watcher.deinit();
    watcher.commit(try watcher.prepare(path));

    try Io.Dir.writeFile(temp.dir, testing.io, .{
        .sub_path = ".hidden",
        .data = "hidden",
    });
    try testing.expectEqual(Refresh.none, try watcher.drain(false));

    try Io.Dir.writeFile(temp.dir, testing.io, .{
        .sub_path = "visible",
        .data = "visible",
    });
    try testing.expectEqual(Refresh.content, try watcher.drain(false));
}
