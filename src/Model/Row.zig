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
            if (self.index >= self.pane.itemCount()) return;
            defer ctx.consumeAndRedraw();
            switch (self.pane.role) {
                .here => try self.pane.model.handleRowClick(ctx, self.index),
                // Side-pane clicks navigate instead of focusing: a parent row
                // jumps HERE to that sibling, a children row descends into it.
                .parent => try self.pane.model.handleParentClick(self.index),
                .children => try self.pane.model.handleChildrenClick(self.index),
            }
        },
        else => {},
    }
}

fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const self: *Row = @ptrCast(@alignCast(ptr));
    var style: vaxis.Cell.Style = .{};
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
        // While the cursor rests on `..`, no real entry is highlighted.
        const active_cursor = self.pane.role == .here and
            self.pane.model.mode != .command and
            !self.pane.model.hereCursorOnUp() and
            self.pane.list_view.cursor == self.index;
        const parent_cwd_index = self.pane.role == .parent and
            self.pane.cwd_index == self.index;
        style.reverse = active_cursor or parent_cwd_index;
        return drawClippedSurface(ctx, self.widget(), listing.rows[self.index], style);
    }
    if (self.pane.preview) |*preview| {
        if (self.index >= preview.lines.len) return self.emptySurface(ctx);
        // A preview's leading lines may be a notice rendered like the
        // placeholder messages ahead of otherwise metadata content.
        const in_header = self.index < preview.header_lines;
        const dimmed = preview.kind == .placeholder or in_header;
        style.dim = dimmed;
        style.italic = dimmed;
        if (preview.kind == .metadata and !in_header) {
            return self.drawMetadataRow(ctx, preview.lines[self.index], style);
        }
        // Empty lines must still occupy a row: ListView constrains children
        // to min.height 0, so an empty Text collapses to zero height and
        // pulls every following row up. drawClippedRow always fills one row.
        return drawClippedSurface(ctx, self.widget(), preview.lines[self.index], style);
    }
    return self.emptySurface(ctx);
}

/// Draws one line into an exact-width surface owned by `widget`.
/// Grapheme-aware clipping stops at the pane width and writes an ellipsis
/// over the last fitting cell, so long lines add no per-frame work beyond
/// the viewport.
pub fn drawClippedSurface(
    ctx: vxfw.DrawContext,
    owner: vxfw.Widget,
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
        owner,
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
