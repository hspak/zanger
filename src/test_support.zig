//! Shared fixtures for filesystem and headless vxfw tests.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

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
};

pub fn keyPress(codepoint: u21, mods: vaxis.Key.Modifiers) vaxis.Key {
    return .{ .codepoint = codepoint, .mods = mods };
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
