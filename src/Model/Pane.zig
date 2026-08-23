//! One of the three navigator panes: an owned listing or preview, its stable
//! row widgets, and the vxfw ListView that displays them. Pane roles are
//! ownership slots (parent / here / children), never focus indicators.

const std = @import("std");
const Allocator = std.mem.Allocator;

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const file_system = @import("../file_system.zig");
const Model = @import("../Model.zig");
const Preview = @import("Preview.zig");
const Row = @import("Row.zig");

const Pane = @This();

/// Direction of a wheel report, coalesced by the model.
pub const WheelDirection = enum {
    up,
    down,
};

model: *Model,
role: Model.PaneRole,
// Owned snapshot; null when this pane has no readable directory.
listing: ?file_system.Listing,
// Owned file details or placeholder when no listing is displayed.
preview: ?Preview,
// Owned widgets parallel to the active listing or preview lines.
rows: []Row,
// Stable location marker for the center directory in the parent listing.
cwd_index: ?usize,
list_view: vxfw.ListView,

pub const Replacement = struct {
    listing: ?file_system.Listing = null,
    preview: ?Preview = null,
    rows: []Row,
    cursor: u32 = 0,
    cwd_index: ?usize = null,
};

pub fn init(self: *Pane, model: *Model, role: Model.PaneRole) void {
    self.* = .{
        .model = model,
        .role = role,
        .listing = null,
        .preview = null,
        .rows = &.{},
        .cwd_index = null,
        .list_view = undefined,
    };
    self.resetListView(0);
}

pub fn deinit(self: *Pane) void {
    if (self.listing) |*listing| listing.deinit();
    if (self.preview) |*preview| preview.deinit();
    self.model.alloc.free(self.rows);
    self.* = undefined;
}

pub fn widget(self: *Pane) vxfw.Widget {
    return .{
        .userdata = self,
        .captureHandler = typeErasedCaptureHandler,
        .drawFn = typeErasedDrawFn,
    };
}

fn typeErasedCaptureHandler(
    ptr: *anyopaque,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
) anyerror!void {
    const self: *Pane = @ptrCast(@alignCast(ptr));
    if (self.model.mode != .browse) return;
    const mouse = switch (event) {
        .mouse => |mouse| mouse,
        else => return,
    };
    const direction: WheelDirection = switch (mouse.button) {
        .wheel_up => .up,
        .wheel_down => .down,
        else => return,
    };

    // Some terminals emit release-shaped wheel reports. They are part of
    // the same input action and must not produce another cursor step.
    if (mouse.type != .press) {
        ctx.consumeEvent();
        return;
    }

    // Wheel navigation belongs exclusively to the center directory. Consume
    // wheel events over side panes so their nested ListViews cannot scroll.
    if (self.role != .here) {
        ctx.consumeEvent();
        return;
    }

    try self.model.handleWheel(ctx, direction);
}

fn typeErasedDrawFn(
    ptr: *anyopaque,
    ctx: vxfw.DrawContext,
) Allocator.Error!vxfw.Surface {
    const self: *Pane = @ptrCast(@alignCast(ptr));
    const list_surface = try self.list_view.widget().draw(ctx);
    const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
    children[0] = .{
        .origin = .{ .col = 0, .row = 0 },
        .surface = list_surface,
    };
    return .{
        .size = list_surface.size,
        .widget = self.widget(),
        .buffer = &.{},
        .children = children,
    };
}

pub fn resetListView(self: *Pane, cursor: u32) void {
    const count: u32 = @intCast(self.itemCount());
    self.list_view = .{
        .children = .{ .builder = .{
            .userdata = self,
            .buildFn = buildRow,
        } },
        .cursor = if (count == 0) 0 else @min(cursor, count - 1),
        .draw_cursor = false,
        // Zanger owns wheel navigation in Pane's capture handler. Keeping
        // this at zero prevents ListView's viewport multiplier from ever
        // handling a report that reaches it.
        .wheel_scroll = 0,
        .item_count = count,
    };
    if (self.listing) |*listing| listing.cursor = self.list_view.cursor;
}

/// Replaces the pane payload, moving ownership of every staged field and
/// releasing the previous content.
pub fn replace(self: *Pane, replacement: Replacement) void {
    if (self.listing) |*old| old.deinit();
    if (self.preview) |*old| old.deinit();
    self.model.alloc.free(self.rows);

    self.listing = replacement.listing;
    self.preview = replacement.preview;
    self.rows = replacement.rows;
    self.cwd_index = replacement.cwd_index;
    self.resetListView(replacement.cursor);
}

pub fn itemCount(self: *const Pane) usize {
    if (self.listing) |listing| return listing.entries.len;
    if (self.preview) |preview| return preview.lines.len;
    return 0;
}

fn buildRow(ptr: *const anyopaque, index: usize, _: usize) ?vxfw.Widget {
    const self: *const Pane = @ptrCast(@alignCast(ptr));
    if (index >= self.rows.len) return null;
    return self.rows[index].widget();
}
