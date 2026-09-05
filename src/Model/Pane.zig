//! One of the three navigator panes: one tagged owned payload, its stable row
//! widgets, and the vxfw ListView that displays them. Pane roles are ownership
//! slots (parent / here / children), never focus indicators.

const std = @import("std");
const Allocator = std.mem.Allocator;

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const file_system = @import("../file_system.zig");
const Model = @import("../Model.zig");
const interaction = @import("interaction.zig");
const Preview = @import("Preview.zig");
const Row = @import("Row.zig");

/// Exactly one owned payload displayed by a pane. The tag is the ownership
/// state: listing and preview can never coexist or require peer optionals.
pub const Content = union(enum) {
    empty,
    listing: file_system.Listing,
    preview: Preview,

    pub fn deinit(self: *Content) void {
        switch (self.*) {
            .empty => {},
            .listing => |*payload| payload.deinit(),
            .preview => |*payload| payload.deinit(),
        }
        self.* = .empty;
    }

    pub fn itemCount(self: *const Content) usize {
        return switch (self.*) {
            .empty => 0,
            .listing => |payload| payload.entries.len,
            .preview => |payload| payload.rows.len,
        };
    }

    pub fn listingPtr(self: *Content) ?*file_system.Listing {
        return switch (self.*) {
            .listing => |*payload| payload,
            else => null,
        };
    }

    pub fn listingConst(self: *const Content) ?*const file_system.Listing {
        return switch (self.*) {
            .listing => |*payload| payload,
            else => null,
        };
    }

    pub fn previewPtr(self: *Content) ?*Preview {
        return switch (self.*) {
            .preview => |*payload| payload,
            else => null,
        };
    }
};

const Pane = @This();

model: *Model,
role: Model.PaneRole,
content: Content,
// Owned widgets parallel to the active listing or preview lines.
rows: []Row,
// Stable location marker for the center directory in the parent listing.
cwd_index: ?usize,
list_view: vxfw.ListView,

/// Direction of a wheel report, coalesced by the model.
pub const WheelDirection = enum {
    up,
    down,
};

pub const Replacement = struct {
    content: Content = .empty,
    rows: []Row,
    cursor: u32 = 0,
    cwd_index: ?usize = null,
};

/// Initializes an empty pane bound to `model` with the given ownership role.
pub fn init(self: *Pane, model: *Model, role: Model.PaneRole) void {
    self.* = .{
        .model = model,
        .role = role,
        .content = .empty,
        .rows = &.{},
        .cwd_index = null,
        .list_view = undefined,
    };
    self.resetListView(0);
}

/// Releases the owned listing, preview, and row widgets, then poisons
/// `self`.
pub fn deinit(self: *Pane) void {
    self.content.deinit();
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
    if (!interaction.isPress(mouse)) {
        ctx.consumeEvent();
        return;
    }

    // Wheel navigation belongs exclusively to the center directory. Consume
    // wheel events over side panes so their nested ListViews cannot scroll.
    if (self.role != .here) {
        ctx.consumeEvent();
        return;
    }

    const moved = self.model.handleWheel(ctx, direction) catch |err| {
        try self.model.reportError("move", @errorName(err));
        ctx.consumeAndRedraw();
        return;
    };
    if (moved) {
        ctx.consumeAndRedraw();
    } else {
        ctx.consumeEvent();
    }
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
    self.list_view.jumpToItem(self.list_view.cursor);
}

/// Replaces the pane payload, moving ownership of every staged field and
/// releasing the previous content.
pub fn replace(self: *Pane, replacement: Replacement) void {
    const previous_top: ?u32 = previous_top: {
        const previous = self.listing() orelse break :previous_top null;
        const next = replacement.content.listingConst() orelse break :previous_top null;
        if (!std.mem.eql(u8, previous.path, next.path)) break :previous_top null;
        break :previous_top self.list_view.scroll.top;
    };
    self.content.deinit();
    self.model.retireRows(self.rows);

    self.content = replacement.content;
    self.rows = replacement.rows;
    self.cwd_index = replacement.cwd_index;
    self.resetListView(replacement.cursor);
    if (previous_top) |top| {
        const cursor = self.list_view.cursor;
        // Reuse the viewport only while the restored cursor still fits. A
        // distant cursor starts at its own row without building skipped rows.
        if (top <= cursor and cursor - top < self.model.cwd_visible_rows) {
            self.list_view.jumpToItem(top);
            self.list_view.cursor = cursor;
        }
    }
}

pub fn itemCount(self: *const Pane) usize {
    return self.content.itemCount();
}

pub fn listing(self: *Pane) ?*file_system.Listing {
    return self.content.listingPtr();
}

pub fn listingConst(self: *const Pane) ?*const file_system.Listing {
    return self.content.listingConst();
}

pub fn preview(self: *Pane) ?*Preview {
    return self.content.previewPtr();
}

fn buildRow(ptr: *const anyopaque, index: usize, _: usize) ?vxfw.Widget {
    const self: *const Pane = @ptrCast(@alignCast(ptr));
    if (index >= self.rows.len) return null;
    return self.rows[index].widget();
}
