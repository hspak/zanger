//! Shared fixtures for filesystem and headless vxfw tests.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.posix.mode_t) c_int;

pub const TempTree = struct {
    alloc: Allocator,
    io: Io,
    temp: std.testing.TmpDir,
    /// Owned absolute path to `temp`.
    path: []u8,

    pub fn init(alloc: Allocator, io: Io) !TempTree {
        var temp = std.testing.tmpDir(.{});
        errdefer temp.cleanup();
        const cwd = try std.process.currentPathAlloc(io, alloc);
        defer alloc.free(cwd);
        const path = try std.fs.path.join(alloc, &.{
            cwd,
            ".zig-cache",
            "tmp",
            &temp.sub_path,
        });
        return .{
            .alloc = alloc,
            .io = io,
            .temp = temp,
            .path = path,
        };
    }

    pub fn deinit(self: *TempTree) void {
        self.alloc.free(self.path);
        self.temp.cleanup();
        self.* = undefined;
    }

    pub fn createDir(self: *TempTree, sub_path: []const u8) !void {
        try Io.Dir.createDir(self.temp.dir, self.io, sub_path, .default_dir);
    }

    pub fn namedPipe(self: *TempTree, sub_path: []const u8) !void {
        const path = try self.absolutePath(sub_path);
        defer self.alloc.free(path);
        const path_z = try std.posix.toPosixPath(path);
        try std.testing.expectEqual(@as(c_int, 0), mkfifo(&path_z, 0o600));
    }

    pub fn writeFile(self: *TempTree, sub_path: []const u8, data: []const u8) !void {
        try Io.Dir.writeFile(self.temp.dir, self.io, .{
            .sub_path = sub_path,
            .data = data,
        });
    }

    pub fn symLink(
        self: *TempTree,
        target: []const u8,
        link_path: []const u8,
    ) !void {
        try Io.Dir.symLink(self.temp.dir, self.io, target, link_path, .{});
    }

    pub fn absolutePath(self: *const TempTree, sub_path: []const u8) ![]u8 {
        if (sub_path.len == 0) return self.alloc.dupe(u8, self.path);
        return std.fs.path.join(self.alloc, &.{ self.path, sub_path });
    }
};

/// Isolates a potentially blocking regression in a child, which is always
/// reaped. Call only from serial tests with no background work in progress.
pub fn expectCompletes(
    io: Io,
    timeout_ms: u32,
    function: anytype,
    args: anytype,
) !void {
    const pid = std.c.fork();
    if (pid < 0) return error.ForkUnavailable;
    if (pid == 0) {
        @call(.auto, function, args) catch |err| {
            std.debug.print("child check: {s}\n", .{@errorName(err)});
            std.c._exit(1);
        };
        std.c._exit(0);
    }
    var reaped = false;
    defer if (!reaped) {
        _ = std.c.kill(pid, .KILL);
        var status: c_int = undefined;
        while (std.c.waitpid(pid, &status, 0) < 0) {
            if (std.posix.errno(-1) != .INTR) break;
        }
    };
    const deadline = Io.Clock.awake.now(io).addDuration(.fromMilliseconds(timeout_ms));
    while (true) {
        var status: c_int = undefined;
        const result = std.c.waitpid(pid, &status, std.posix.W.NOHANG);
        if (result == pid) {
            reaped = true;
            try std.testing.expectEqual(@as(c_int, 0), status);
            return;
        }
        if (result < 0 and std.posix.errno(result) != .INTR) return error.WaitChild;
        if (Io.Clock.awake.now(io).nanoseconds >= deadline.nanoseconds) {
            return error.TestTimeout;
        }
        try io.sleep(.fromMilliseconds(5), .awake);
    }
}

pub const EventHarness = struct {
    ctx: vxfw.EventContext,

    pub fn init(alloc: Allocator, io: Io) EventHarness {
        return .{ .ctx = .{
            .io = io,
            .alloc = alloc,
            .cmds = .empty,
            .redraw = false,
        } };
    }

    pub fn deinit(self: *EventHarness) void {
        self.ctx.cmds.deinit(self.ctx.alloc);
        self.* = undefined;
    }

    pub fn resetEffects(self: *EventHarness) void {
        self.ctx.consume_event = false;
        self.ctx.redraw = false;
    }

    /// Replays the key phases while retaining the focus target chosen before
    /// an input batch; vxfw applies queued focus requests after that batch.
    pub fn dispatchKey(
        self: *EventHarness,
        root: vxfw.Widget,
        focused: vxfw.Widget,
        key: vaxis.Key,
    ) !void {
        self.resetEffects();
        const event: vxfw.Event = .{ .key_press = key };
        self.ctx.phase = .capturing;
        try root.captureEvent(&self.ctx, event);
        if (self.ctx.consume_event) return;
        self.ctx.phase = .at_target;
        try focused.handleEvent(&self.ctx, event);
        if (self.ctx.consume_event) return;
        self.ctx.phase = .bubbling;
        try root.handleEvent(&self.ctx, event);
    }
};

pub fn keyPress(codepoint: u21, mods: vaxis.Key.Modifiers) vaxis.Key {
    return .{ .codepoint = codepoint, .mods = mods };
}

pub fn containsWidget(surface: vxfw.Surface, target: vxfw.Widget) bool {
    if (surface.widget.eql(target)) return true;
    for (surface.children) |child| {
        if (containsWidget(child.surface, target)) return true;
    }
    return false;
}

pub fn containsText(surface: vxfw.Surface, text: []const u8) !bool {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    for (surface.buffer) |cell| try bytes.appendSlice(std.testing.allocator, cell.char.grapheme);
    if (std.mem.indexOf(u8, bytes.items, text) != null) return true;
    for (surface.children) |child| {
        if (try containsText(child.surface, text)) return true;
    }
    return false;
}

pub fn drawContext(arena: Allocator, size: vxfw.Size) vxfw.DrawContext {
    vxfw.DrawContext.init(.unicode);
    return .{
        .arena = arena,
        .min = size,
        .max = .{ .width = size.width, .height = size.height },
        .cell_size = .{ .width = 8, .height = 16 },
    };
}

pub fn leftMouse(event_type: vaxis.Mouse.Type) vaxis.Mouse {
    return .{
        .col = 0,
        .row = 0,
        .button = .left,
        .mods = .{},
        .type = event_type,
    };
}

pub fn wheelMouse(button: vaxis.Mouse.Button, event_type: vaxis.Mouse.Type) vaxis.Mouse {
    std.debug.assert(button == .wheel_up or button == .wheel_down);
    return .{
        .col = 0,
        .row = 0,
        .button = button,
        .mods = .{},
        .type = event_type,
    };
}
