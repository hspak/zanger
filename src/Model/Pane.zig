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

/// The clickable `..` line above the HERE listing. Lives inside its pane so
/// the widget address is stable for hit testing across frames.
pub const UpRow = struct {
    pane: *Pane,

    pub fn widget(self: *const UpRow) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .eventHandler = upTypeErasedEventHandler,
            .drawFn = upTypeErasedDrawFn,
        };
    }

    fn upTypeErasedEventHandler(
        ptr: *anyopaque,
        ctx: *vxfw.EventContext,
        event: vxfw.Event,
    ) anyerror!void {
        const self: *UpRow = @ptrCast(@alignCast(ptr));
        switch (event) {
            .mouse => |mouse| {
                if (self.pane.model.mode != .browse) return;
                if (mouse.button != .left or mouse.type != .press) return;
                defer ctx.consumeAndRedraw();
                return self.pane.model.ascend() catch |err| {
                    try self.pane.model.reportError("up", @errorName(err));
                };
            },
            else => {},
        }
    }

    fn upTypeErasedDrawFn(
        ptr: *anyopaque,
        ctx: vxfw.DrawContext,
    ) Allocator.Error!vxfw.Surface {
        const self: *UpRow = @ptrCast(@alignCast(ptr));
        const style: vaxis.Cell.Style = .{
            .fg = .{ .index = 12 },
            .bold = true,
        };
        return Row.drawClippedSurface(ctx, self.widget(), "..", style);
    }
};

const Pane = @This();

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
// Clickable `..` row; only rendered by HERE panes below the filesystem root.
up_row: UpRow,

/// Direction of a wheel report, coalesced by the model.
pub const WheelDirection = enum {
    up,
    down,
};

pub const Replacement = struct {
    listing: ?file_system.Listing = null,
    preview: ?Preview = null,
    rows: []Row,
    cursor: u32 = 0,
    cwd_index: ?usize = null,
};

/// Initializes an empty pane bound to `model` with the given ownership role.
pub fn init(self: *Pane, model: *Model, role: Model.PaneRole) void {
    self.* = .{
        .model = model,
        .role = role,
        .listing = null,
        .preview = null,
        .rows = &.{},
        .cwd_index = null,
        .list_view = undefined,
        .up_row = .{ .pane = self },
    };
    self.resetListView(0);
}

/// Releases the owned listing, preview, and row widgets, then poisons
/// `self`.
pub fn deinit(self: *Pane) void {
    if (self.listing) |*listing| listing.deinit();
    if (self.preview) |*preview| preview.deinit();
    self.model.alloc.free(self.rows);
    self.* = undefined;
}

/// Returns a widget borrowing `self`. The pane address must stay stable for
/// the widget's lifetime.
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

/// Whether this pane renders the clickable `..` line: only a HERE pane that
/// sits below the filesystem root.
pub fn showsUpRow(self: *const Pane) bool {
    if (self.role != .here or self.listing == null) return false;
    return !std.mem.eql(u8, self.listing.?.path, "/");
}

fn typeErasedDrawFn(
    ptr: *anyopaque,
    ctx: vxfw.DrawContext,
) Allocator.Error!vxfw.Surface {
    const self: *Pane = @ptrCast(@alignCast(ptr));
    const size = ctx.max.size();

    if (self.showsUpRow()) {
        // Reserve the top row for `..` and give the rest to the list.
        const list_height = size.height -| 1;
        const up_ctx = ctx.withConstraints(
            .{ .width = size.width, .height = 1 },
            .{ .width = size.width, .height = 1 },
        );
        const up_surface = try self.up_row.widget().draw(up_ctx);
        const list_ctx = ctx.withConstraints(
            .{ .width = size.width, .height = list_height },
            .{ .width = size.width, .height = list_height },
        );
        const list_surface = try self.list_view.widget().draw(list_ctx);
        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
        children[0] = .{ .origin = .{ .col = 0, .row = 0 }, .surface = up_surface };
        children[1] = .{
            .origin = .{ .col = 0, .row = 1 },
            .surface = list_surface,
        };
        return .{
            .size = size,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }

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
    self.model.retireRows(self.rows);

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
