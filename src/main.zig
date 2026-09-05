//! Runs the libvaxis three-pane navigator.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const options = @import("build_options");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Model = @import("Model.zig");

// vxfw services input and timers on frame boundaries. A 120 Hz cadence keeps
// the scheduling contribution below one typical 60 Hz terminal refresh while
// redraws themselves remain demand-driven.
const app_framerate = 120;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(alloc);
    defer alloc.free(args);
    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "-v") or std.mem.eql(u8, args[1], "--version")) {
            const current_version = try std.fmt.allocPrint(alloc, "version: {s}\n", .{options.version});
            defer alloc.free(current_version);
            try Io.File.stdout().writeStreamingAll(io, current_version);
        } else {
            try Io.File.stdout().writeStreamingAll(io, "usage: zanger [-h/--help/-v/--version]\n");
        }
        return;
    }

    var app_buffer: [4096]u8 = undefined;
    var app: vxfw.App = try .init(io, alloc, init.environ_map, &app_buffer);
    defer app.deinit();

    const cwd = try std.process.currentPathAlloc(io, alloc);
    defer alloc.free(cwd);
    const user = init.environ_map.get("USER") orelse "user";
    var hostname_buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = std.posix.gethostname(&hostname_buffer) catch
        (init.environ_map.get("HOSTNAME") orelse "localhost");

    const model = try alloc.create(Model);
    defer alloc.destroy(model);
    try model.init(alloc, io, .{
        .start_path = cwd,
        .user = user,
        .hostname = hostname,
        .time_zone = .{
            .tz = init.environ_map.get("TZ"),
            .tzdir = init.environ_map.get("TZDIR"),
        },
    });
    defer model.deinit();

    try app.run(model.widget(), .{ .framerate = app_framerate });
}

test {
    _ = @import("command.zig");
    _ = @import("file_system.zig");
    _ = @import("Model.zig");
    _ = @import("Watcher.zig");
}
