//! Stable row widgets backing every pane line. vxfw's ListView has no
//! click-to-select support, so persistent Row userdata gives hit testing a
//! stable identity; the draw function renders the pane-owned row string.

const std = @import("std");
const Allocator = std.mem.Allocator;

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Pane = @import("Pane.zig");

const Row = @This();

// Borrowed from the pane that owns this row's backing slice.
pane: *Pane,
index: usize,

/// Returns a widget borrowing `self`; the row's address inside its pane's
/// rows array is the click-identity key.
pub fn widget(self: *const Row) vxfw.Widget {
    return .{
        .userdata = @constCast(self),
        .eventHandler = typeErasedEventHandler,
        .drawFn = typeErasedDrawFn,
    };
}

// vxfw fixes the error set of its type-erased widget callbacks.
fn typeErasedEventHandler(
    ptr: *anyopaque,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
) anyerror!void {
    const self: *Row = @ptrCast(@alignCast(ptr));
    switch (event) {
        .mouse => |mouse| {
            if (self.pane.model.mode != .browse) return;
            if (mouse.button != .left or mouse.type != .press) return;
            if (self.pane.role != .here) {
                ctx.consumeEvent();
                return;
            }

            if (self.index >= self.pane.itemCount()) return;
            const previous_cursor = self.pane.list_view.cursor;
            self.pane.list_view.cursor = @intCast(self.index);
            if (self.pane.listing) |*listing| listing.cursor = self.index;
            if (previous_cursor != self.index) {
                try self.pane.model.deferRightSync(ctx);
            }
            ctx.consumeAndRedraw();
        },
        else => {},
    }
}

fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const self: *Row = @ptrCast(@alignCast(ptr));
    var style: vaxis.Cell.Style = .{};
    const row_text = row_text: {
        if (self.pane.listing) |*listing| {
            if (self.index >= listing.rows.len) return self.emptySurface(ctx);
            const entry = listing.entries[self.index];
            const selected = listing.selected.isSet(self.index);
            style.fg = if (selected)
                .{ .index = 11 }
            else if (entry.is_sym)
                .{ .index = 6 }
            else if (entry.is_dir)
                .{ .index = 12 }
            else
                .default;
            style.bold = selected or entry.is_dir;
            const active_cursor = self.pane.role == .here and
                self.pane.model.mode != .command and
                self.pane.list_view.cursor == self.index;
            const parent_cwd_index = self.pane.role == .parent and
                self.pane.cwd_index == self.index;
            style.reverse = active_cursor or parent_cwd_index;
            return self.drawClippedRow(ctx, listing.rows[self.index], style);
        }
        if (self.pane.preview) |*preview| {
            if (self.index >= preview.lines.len) return self.emptySurface(ctx);
            style.dim = preview.kind == .placeholder;
            style.italic = preview.kind == .placeholder;
            if (preview.kind == .metadata) {
                return self.drawMetadataRow(ctx, preview.lines[self.index], style);
            }
            break :row_text preview.lines[self.index];
        }
        return self.emptySurface(ctx);
    };

    const text: vxfw.Text = .{
        .text = row_text,
        .style = style,
        .softwrap = false,
        .overflow = .ellipsis,
        .width_basis = .parent,
    };
    var surface = try text.draw(ctx);
    // Text is a stack-local helper; the row is the persistent widget that
    // must appear in the surface tree for mouse hit testing.
    surface.widget = self.widget();
    return surface;
}

/// Draws one row into an exact-width surface. Grapheme-aware clipping stops
/// at the pane width and writes an ellipsis over the last fitting cell, so a
/// long off-screen link target adds no per-frame work beyond the viewport.
fn drawClippedRow(
    self: *const Row,
    ctx: vxfw.DrawContext,
    line: []const u8,
    style: vaxis.Cell.Style,
) Allocator.Error!vxfw.Surface {
    const width = ctx.max.width.?;
    const requested_height = @max(ctx.min.height, 1);
    const height = if (ctx.max.height) |maximum|
        @min(requested_height, maximum)
    else
        requested_height;
    const surface = try vxfw.Surface.init(
        ctx.arena,
        self.widget(),
        .{ .width = width, .height = height },
    );
    @memset(surface.buffer, vaxis.Cell{ .style = style });
    if (width == 0 or height == 0) return surface;

    var bytes_consumed: usize = 0;
    var column: u16 = 0;
    var graphemes = ctx.graphemeIterator(line);
    while (graphemes.next()) |character| {
        const grapheme = character.bytes(line);
        bytes_consumed += grapheme.len;
        const grapheme_width: u16 = @intCast(ctx.stringWidth(grapheme));
        if (grapheme_width == 0) continue;

        const has_more = bytes_consumed < line.len;
        const end_column = @as(u32, column) + grapheme_width;
        if (end_column > width or (has_more and end_column >= width)) {
            surface.writeCell(column, 0, .{
                .char = .{ .grapheme = "…", .width = 1 },
                .style = style,
            });
            break;
        }
        surface.writeCell(column, 0, .{
            .char = .{ .grapheme = grapheme, .width = @intCast(grapheme_width) },
            .style = style,
        });
        column = @intCast(end_column);
        if (column == width) break;
    }
    return surface;
}

/// Draws a metadata sheet line with the key up to the first colon bolded.
fn drawMetadataRow(
    self: *const Row,
    ctx: vxfw.DrawContext,
    line: []const u8,
    style: vaxis.Cell.Style,
) Allocator.Error!vxfw.Surface {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse unreachable;
    var key_style = style;
    key_style.bold = true;
    const spans: [2]vaxis.Segment = .{
        .{ .text = line[0 .. colon + 1], .style = key_style },
        .{ .text = line[colon + 1 ..], .style = style },
    };
    const text: vxfw.RichText = .{
        .text = &spans,
        .base_style = style,
        .softwrap = false,
        .overflow = .ellipsis,
        .width_basis = .parent,
    };
    var surface = try text.draw(ctx);
    surface.widget = self.widget();
    return surface;
}

fn emptySurface(self: *const Row, ctx: vxfw.DrawContext) vxfw.Surface {
    return .{
        .size = ctx.min,
        .widget = self.widget(),
        .buffer = &.{},
        .children = &.{},
    };
}
