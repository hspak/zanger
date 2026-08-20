//! Runs the libvaxis three-pane navigator.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Model = @import("Model.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

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
    });
    defer model.deinit();

    try app.run(model.widget(), .{});
}

test {
    _ = @import("command.zig");
    _ = @import("file_system.zig");
    _ = @import("Model.zig");
    _ = @import("Watcher.zig");
}
