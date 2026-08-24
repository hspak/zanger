//! Owns the libvaxis three-pane navigator's interactive model.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.model);

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Key = vaxis.Key;
const zeit = @import("zeit");

const Watcher = @import("Watcher.zig");
const command = @import("command.zig");
const file_system = @import("file_system.zig");
const format = @import("Model/format.zig");
pub const FileMetadata = @import("Model/FileMetadata.zig");
pub const IdentityCache = @import("Model/IdentityCache.zig");
pub const Preview = @import("Model/Preview.zig");
pub const Pane = @import("Model/Pane.zig");
pub const PendingView = @import("Model/PendingView.zig");
pub const Row = @import("Model/Row.zig");
pub const HereCursor = @import("Model/cursor.zig").Here;

const ListingTransfer = PendingView.ListingTransfer;
const DirectoryEmptyTransfer = PendingView.DirectoryEmptyTransfer;

const Model = @This();

alloc: Allocator,
io: Io,
panes: [3]Pane,
mode: Mode = .browse,
text_field: vxfw.TextField,
identities: IdentityCache,
watcher: Watcher,
local_time_zone: zeit.TimeZone,
// Metadata for the last committed CHILDREN target. Cursor movement retains it
// until the debounced CHILDREN refresh commits.
cursor_status: ?CursorStatus = null,
show_hidden: bool = false,
watch_refresh: WatchRefresh = .none,
// Cursor movement leaves committed CHILDREN content visible and defers its
// replacement until input has been idle for `preview_debounce_ms`.
preview_dirty: bool = false,
preview_tick_pending: bool = false,
preview_due: Io.Timestamp = .zero,
// Left-press bookkeeping for double-click descent on HERE rows.
last_click: ?LastClick = null,
/// Timestamp of the last press on the `..` row, for its own double-click
/// detection.
up_click_at_ns: ?i128 = null,

/// Authoritative logical cursor for HERE. The vxfw and listing cursors are
/// projections updated only by `applyHereCursor` and view commit.
here_cursor: HereCursor = .none,
/// Transient blocked-input notice rendered beside the header path until
/// `error_deadline`, then cleared on a watcher tick.
error_message: ?[]u8 = null,
error_deadline: Io.Timestamp = .zero,
/// Program spawned to open files with; overridable in tests.
open_program: []const u8 = "xdg-open",
/// Test seam: when set, open requests append the target path here instead
/// of spawning a process. Borrowed for the model's lifetime.
open_recorder: ?*std.ArrayList([]const u8) = null,
// Terminals may encode one physical wheel notch as a burst of reports.
wheel_tick_pending: bool = false,
wheel_direction: ?WheelDirection = null,
// Updated during layout; HERE has one item per terminal row.
cwd_visible_rows: u16 = 1,
// Owned and replaced transactionally by `setMessage`.
message: []u8 = &.{},
confirm_count: usize = 0,
// Replaced pane row arrays, kept readable until the next draw. vxfw retains
// the previous frame's surface tree for hit testing until a new frame
// renders, so freeing rows at commit time could leave mouse handlers reading
// freed memory when input events share one queue batch with a commit.
retired_rows: std.ArrayList([]Row) = .empty,
// Both names are borrowed for the model's lifetime.
user: []const u8 = "user",
hostname: []const u8 = "localhost",

const Mode = enum { browse, command, confirm };
const WatchRefresh = enum { none, refresh, rearm };
const watcher_interval_ms = 150;
pub const double_click_interval_ms = 400;
const error_flash_ms = 3000;
const preview_debounce_ms = 12;
const wheel_coalesce_ms = 12;

const WheelDirection = Pane.WheelDirection;

const CursorScroll = enum {
    none,
    ensure_visible,
    jump,
};

const LastClick = struct {
    index: usize,
    at_ns: i128,
};

pub const PaneRole = enum(u2) {
    parent = 0,
    here = 1,
    children = 2,

    pub fn toIndex(self: PaneRole) usize {
        return @intFromEnum(self);
    }
};

pub const CursorStatus = struct {
    metadata: FileMetadata,
    mode_bits: [10]u8,
    // Borrowed from HERE's listing, which remains stable during cursor movement.
    entry_name: []const u8,
    // Borrowed from `identities`; cached identity strings have stable storage.
    user_name: []const u8,
    group_name: []const u8,
};

// Preparing replacement content first keeps re-anchoring atomic. Matching live
// listings move between pane roles only after all fallible work succeeds.
/// Inputs borrowed for the lifetime of an initialized model.
pub const InitOptions = struct {
    /// Absolute directory to install as HERE.
    start_path: []const u8,
    /// Identity rendered in the header.
    user: []const u8 = "user",
    /// Host name rendered in the header.
    hostname: []const u8 = "localhost",
};

/// Errors from creating the watcher or preparing the initial anchored view.
pub const InitError = combined: {
    break :combined Watcher.InitError ||
        Watcher.ArmError ||
        file_system.ReadDirError ||
        file_system.IsDirEmptyError ||
        error{EmptyDirectory};
};

const DeleteTarget = struct {
    // Owned by `executeDelete` until its target list is deinitialized.
    path: []const u8,
    is_dir: bool,
};

const InstallOptions = struct {
    listing: *?file_system.Listing,
    preview: *?Preview,
    cursor: u32 = 0,
    cwd_index: ?usize = null,
};

const ReplaceViewOptions = struct {
    preferred_name: ?[]const u8 = null,
    fallback_cursor: ?usize = null,
    transfers: []const ListingTransfer = &.{},
    restore_here_from: ?*const file_system.Listing = null,
    preserve_message: bool = false,
    rearm_watcher: bool = false,
    reject_empty_center: bool = false,
};

/// Owns a headless model used by the profiling executable.
pub const ProfileSession = struct {
    alloc: Allocator,
    model: *Model,

    /// Creates a model with stable heap storage for headless measurements.
    pub fn init(alloc: Allocator, io: Io, path: []const u8) InitError!ProfileSession {
        const model = try alloc.create(Model);
        errdefer alloc.destroy(model);
        try model.init(alloc, io, .{
            .start_path = path,
            .user = "profile",
            .hostname = "localhost",
        });
        return .{ .alloc = alloc, .model = model };
    }

    /// Deinitializes and frees the owned model.
    pub fn deinit(self: *ProfileSession) void {
        self.model.deinit();
        self.alloc.destroy(self.model);
        self.* = undefined;
    }

    /// Draws one frame into `ctx.arena`.
    pub fn draw(
        self: *ProfileSession,
        ctx: vxfw.DrawContext,
    ) Allocator.Error!vxfw.Surface {
        return self.model.draw(ctx);
    }

    /// Moves HERE by one entry and schedules its CHILDREN preview.
    pub fn moveCursor(
        self: *ProfileSession,
        ctx: *vxfw.EventContext,
        down: bool,
    ) Allocator.Error!void {
        try self.model.moveCenter(ctx, down);
    }

    /// Moves HERE to its first or last entry.
    pub fn jumpCursor(
        self: *ProfileSession,
        ctx: *vxfw.EventContext,
        bottom: bool,
    ) Allocator.Error!void {
        try self.model.jumpCenter(ctx, bottom);
    }

    /// Rebuilds CHILDREN immediately for the current HERE cursor.
    pub fn syncPreview(self: *ProfileSession) file_system.ReadDirError!void {
        try self.model.syncRight();
    }

    /// Returns the number of entries in HERE.
    pub fn entryCount(self: *ProfileSession) usize {
        return self.model.centerListing().entries.len;
    }
};

/// Initializes stable storage. `self` must not move before `deinit`, because
/// panes and vxfw widgets retain its address.
pub fn init(self: *Model, alloc: Allocator, io: Io, options: InitOptions) InitError!void {
    var local_time_zone = zeit.local(alloc, io, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => zeit.utc,
    };
    const watcher = Watcher.init(io) catch |err| {
        local_time_zone.deinit();
        return err;
    };
    self.* = .{
        .alloc = alloc,
        .io = io,
        .panes = undefined,
        .text_field = vxfw.TextField.init(alloc),
        .identities = .{},
        .watcher = watcher,
        .local_time_zone = local_time_zone,
        .user = options.user,
        .hostname = options.hostname,
    };

    for (&self.panes, 0..) |*pane, index| {
        pane.init(self, @enumFromInt(index));
    }
    self.text_field.userdata = self;
    self.text_field.onSubmit = typeErasedCommandSubmit;

    errdefer self.deinit();
    try self.replaceAnchoredView(options.start_path, .{});
}

/// Frees all model-owned resources and poisons `self`.
pub fn deinit(self: *Model) void {
    for (&self.panes) |*pane| pane.deinit();
    self.watcher.deinit();
    self.local_time_zone.deinit();
    self.text_field.deinit();
    self.identities.deinit(self.alloc);
    self.freeRetiredRows();
    self.retired_rows.deinit(self.alloc);
    if (self.error_message) |message| self.alloc.free(message);
    self.alloc.free(self.message);
    self.* = undefined;
}

/// Returns a widget borrowing `self` until the model is deinitialized.
pub fn widget(self: *Model) vxfw.Widget {
    return .{
        .userdata = self,
        .captureHandler = Model.typeErasedCaptureHandler,
        .eventHandler = Model.typeErasedEventHandler,
        .drawFn = Model.typeErasedDrawFn,
    };
}

fn previewTimerWidget(self: *Model) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = typeErasedPreviewTimerHandler,
        .drawFn = typeErasedPreviewTimerDrawFn,
    };
}

fn wheelTimerWidget(self: *Model) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = typeErasedWheelTimerHandler,
        .drawFn = typeErasedWheelTimerDrawFn,
    };
}

fn getPane(self: *Model, role: PaneRole) *Pane {
    return &self.panes[role.toIndex()];
}

fn centerListing(self: *Model) *file_system.Listing {
    return &self.getPane(.here).listing.?;
}

fn hereEntryIndex(self: *const Model) ?usize {
    return self.here_cursor.selectedEntry();
}

fn normalizeHereCursor(self: *Model, target: HereCursor) HereCursor {
    const pane = self.getPane(.here);
    const listing = &(pane.listing orelse return .none);
    return switch (target) {
        .none => HereCursor.fromEntryCount(listing.entries.len, 0),
        .entry => |index| HereCursor.fromEntryCount(listing.entries.len, index),
        .up => |remembered| if (pane.showsUpRow())
            .{ .up = if (listing.entries.len == 0)
                null
            else
                @min(remembered orelse 0, listing.entries.len - 1) }
        else
            HereCursor.fromEntryCount(listing.entries.len, remembered orelse 0),
    };
}

/// Applies HERE's logical cursor to its vxfw and temporary listing mirrors.
/// Returns whether the logical target changed.
fn applyHereCursor(
    self: *Model,
    target: HereCursor,
    scroll: CursorScroll,
) bool {
    const normalized = self.normalizeHereCursor(target);
    if (self.here_cursor.eql(normalized)) return false;

    self.here_cursor = normalized;
    const pane = self.getPane(.here);
    const numeric_index = normalized.rememberedEntry() orelse 0;
    pane.list_view.cursor = @intCast(numeric_index);
    if (!normalized.isUp()) switch (scroll) {
        .none => {},
        .ensure_visible => pane.list_view.ensureScroll(),
        .jump => pane.list_view.jumpToItem(@intCast(numeric_index)),
    };
    return true;
}

fn setHereCursor(
    self: *Model,
    ctx: *vxfw.EventContext,
    target: HereCursor,
    scroll: CursorScroll,
) Allocator.Error!bool {
    const changed = self.applyHereCursor(target, scroll);
    if (changed) try self.deferRightSync(ctx);
    return changed;
}

/// Selects HERE's pinned `..` row while remembering the current real entry.
pub fn selectUp(self: *Model, ctx: *vxfw.EventContext) Allocator.Error!void {
    if (!self.getPane(.here).showsUpRow()) return;
    _ = try self.setHereCursor(
        ctx,
        .{ .up = self.here_cursor.rememberedEntry() },
        .none,
    );
}

/// Asserts the model's structural invariants without allocating or touching
/// the filesystem. Kept in production builds so Debug callers can validate
/// every commit boundary; tests also call it after mixed action sequences.
pub fn assertValid(self: *const Model) void {
    const here = &self.panes[PaneRole.here.toIndex()];
    const center = &(here.listing orelse @panic("HERE must own a listing"));

    for (&self.panes) |*pane| {
        std.debug.assert(!(pane.listing != null and pane.preview != null));
        const item_count = pane.itemCount();
        std.debug.assert(pane.rows.len == item_count);
        std.debug.assert(pane.list_view.item_count == @as(u32, @intCast(item_count)));
        if (item_count == 0) {
            std.debug.assert(pane.list_view.cursor == 0);
        } else {
            std.debug.assert(pane.list_view.cursor < item_count);
        }
        if (pane.listing) |listing| {
            std.debug.assert(listing.rows.len == listing.entries.len);
            std.debug.assert(listing.selected.capacity() == listing.entries.len);
            std.debug.assert(listing.selected_count == listing.selected.count());
        }
        if (pane.preview) |preview| {
            std.debug.assert(preview.header_lines <= preview.lines.len);
        }
    }

    switch (self.here_cursor) {
        .none => std.debug.assert(center.entries.len == 0),
        .up => |remembered| {
            std.debug.assert(here.showsUpRow());
            if (remembered) |index| {
                std.debug.assert(index < center.entries.len);
                std.debug.assert(index == here.list_view.cursor);
            } else {
                std.debug.assert(center.entries.len == 0);
            }
        },
        .entry => |index| {
            std.debug.assert(index < center.entries.len);
            std.debug.assert(index == here.list_view.cursor);
        },
    }
    if (self.panes[PaneRole.parent.toIndex()].listing) |parent| {
        const cwd_index = self.panes[PaneRole.parent.toIndex()].cwd_index.?;
        std.debug.assert(cwd_index < parent.entries.len);
        std.debug.assert(std.mem.eql(
            u8,
            parent.path,
            std.fs.path.dirname(center.path) orelse "/",
        ));
        std.debug.assert(std.mem.eql(
            u8,
            parent.entries[cwd_index].name,
            std.fs.path.basename(center.path),
        ));
    }

    const children = &self.panes[PaneRole.children.toIndex()];
    if (!self.preview_dirty and !self.here_cursor.isUp() and children.listing != null) {
        std.debug.assert(center.entries.len > 0);
        const entry = center.entries[self.hereEntryIndex().?];
        const child = children.listing.?;
        std.debug.assert(entry.is_dir);
        std.debug.assert(std.mem.eql(
            u8,
            std.fs.path.dirname(child.path) orelse "/",
            center.path,
        ));
        std.debug.assert(std.mem.eql(u8, std.fs.path.basename(child.path), entry.name));
    }
}

/// Loads the bottom-bar metadata for one entry. Stat failures return null so
/// the bar degrades to counts; allocation failure propagates because callers
/// roll back transactionally on OOM.
fn loadCursorStatus(
    self: *Model,
    path: []const u8,
    entry_name: []const u8,
) Allocator.Error!?CursorStatus {
    const metadata = FileMetadata.init(path) catch return null;
    const user_name = try self.identities.userName(self.alloc, metadata.uid);
    const group_name = try self.identities.groupName(self.alloc, metadata.gid);
    return .{
        .metadata = metadata,
        .mode_bits = format.modeBits(metadata.kind, metadata.mode),
        .entry_name = entry_name,
        .user_name = user_name,
        .group_name = group_name,
    };
}

// vxfw fixes the error set of its type-erased widget callbacks.
fn typeErasedCaptureHandler(
    ptr: *anyopaque,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
) anyerror!void {
    const self: *Model = @ptrCast(@alignCast(ptr));
    try self.captureEvent(ctx, event);
}

fn typeErasedEventHandler(
    ptr: *anyopaque,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
) anyerror!void {
    const self: *Model = @ptrCast(@alignCast(ptr));
    try self.handleEvent(ctx, event);
}

fn typeErasedPreviewTimerHandler(
    ptr: *anyopaque,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
) anyerror!void {
    const self: *Model = @ptrCast(@alignCast(ptr));
    switch (event) {
        .tick => try self.handlePreviewTimer(ctx),
        else => {},
    }
}

fn typeErasedPreviewTimerDrawFn(
    ptr: *anyopaque,
    ctx: vxfw.DrawContext,
) Allocator.Error!vxfw.Surface {
    const self: *Model = @ptrCast(@alignCast(ptr));
    return .{
        .size = ctx.min,
        .widget = self.previewTimerWidget(),
        .buffer = &.{},
        .children = &.{},
    };
}

fn typeErasedWheelTimerHandler(
    ptr: *anyopaque,
    _: *vxfw.EventContext,
    event: vxfw.Event,
) anyerror!void {
    const self: *Model = @ptrCast(@alignCast(ptr));
    switch (event) {
        .tick => {
            self.wheel_tick_pending = false;
            self.wheel_direction = null;
        },
        else => {},
    }
}

fn typeErasedWheelTimerDrawFn(
    ptr: *anyopaque,
    ctx: vxfw.DrawContext,
) Allocator.Error!vxfw.Surface {
    const self: *Model = @ptrCast(@alignCast(ptr));
    return .{
        .size = ctx.min,
        .widget = self.wheelTimerWidget(),
        .buffer = &.{},
        .children = &.{},
    };
}

fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const self: *Model = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

fn typeErasedCommandSubmit(
    ptr: ?*anyopaque,
    ctx: *vxfw.EventContext,
    value: []const u8,
) anyerror!void {
    const self: *Model = @ptrCast(@alignCast(ptr.?));
    try self.submitCommand(ctx, value);
}

fn transferTo(transfers: []const ListingTransfer, target: PaneRole) ?ListingTransfer {
    var match: ?ListingTransfer = null;
    for (transfers) |transfer| {
        if (transfer.target != target) continue;
        std.debug.assert(match == null);
        match = transfer;
    }
    return match;
}

fn setStagedDirectoryEmpty(
    pending_view: *PendingView,
    target: PaneRole,
    listing: *file_system.Listing,
    index: usize,
    is_empty: bool,
) void {
    const target_index = target.toIndex();
    if (pending_view.listing_sources[target_index] != null) {
        pending_view.directory_empty_transfers[target_index] = .{
            .index = index,
            .is_empty = is_empty,
        };
    } else {
        listing.setDirectoryEmpty(index, is_empty);
    }
}

fn prepareView(
    self: *Model,
    center_path: []const u8,
    preferred_name: ?[]const u8,
    transfers: []const ListingTransfer,
    fallback_cursor: ?usize,
    reject_empty_center: bool,
) !PendingView {
    var pending_view: PendingView = .{};
    errdefer pending_view.deinit();

    const center_index = PaneRole.here.toIndex();
    const center_reused = center_reused: {
        const transfer = transferTo(transfers, .here) orelse break :center_reused false;
        const candidate = self.getPane(transfer.source).listing orelse
            break :center_reused false;
        if (!std.mem.eql(u8, candidate.path, center_path)) break :center_reused false;
        _ = pending_view.borrowListing(transfer.source, .here, candidate);
        break :center_reused true;
    };
    if (!center_reused) {
        pending_view.listings[center_index] = try file_system.readDir(
            self.alloc,
            self.io,
            center_path,
            .{ .show_hidden = self.show_hidden },
        );
    }
    const center = &pending_view.listings[center_index].?;
    if (reject_empty_center and center_reused and try file_system.isDirEmpty(
        self.io,
        center_path,
        .{ .show_hidden = self.show_hidden },
    )) return error.EmptyDirectory;
    if (reject_empty_center and center.entries.len == 0) return error.EmptyDirectory;
    const center_cursor = center.cursorFor(preferred_name, fallback_cursor);
    pending_view.cursors[center_index] = @intCast(center_cursor);

    if (!std.mem.eql(u8, center.path, "/")) {
        const parent_path = try file_system.parentPath(self.alloc, center.path);
        defer self.alloc.free(parent_path);
        const parent_index = PaneRole.parent.toIndex();
        const parent_reused = parent_reused: {
            const transfer = transferTo(transfers, .parent) orelse
                break :parent_reused false;
            const candidate = self.getPane(transfer.source).listing orelse
                break :parent_reused false;
            if (!std.mem.eql(u8, candidate.path, parent_path))
                break :parent_reused false;
            const parent = pending_view.borrowListing(transfer.source, .parent, candidate);
            const parent_cursor = parent.cursorFor(std.fs.path.basename(center.path), null);
            pending_view.cursors[parent_index] = @intCast(parent_cursor);
            pending_view.cwd_indices[parent_index] = parent_cursor;
            pending_view.directory_empty_transfers[parent_index] = .{
                .index = parent_cursor,
                .is_empty = center.entries.len == 0,
            };
            break :parent_reused true;
        };
        if (!parent_reused) {
            pending_view.listings[parent_index] = file_system.readDir(
                self.alloc,
                self.io,
                parent_path,
                .{ .show_hidden = self.show_hidden },
            ) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => parent_listing: {
                    pending_view.rememberErrorName(@errorName(err));
                    break :parent_listing null;
                },
            };
            if (pending_view.listings[parent_index]) |*parent| {
                const parent_cursor = parent.cursorFor(
                    std.fs.path.basename(center.path),
                    null,
                );
                parent.setDirectoryEmpty(parent_cursor, center.entries.len == 0);
                pending_view.cursors[parent_index] = @intCast(parent_cursor);
                pending_view.cwd_indices[parent_index] = parent_cursor;
            }
        }
    }

    if (center.entries.len > 0) {
        const entry = center.entries[center_cursor];
        const cursor_path = try file_system.joinPath(self.alloc, center.path, entry.name);
        defer self.alloc.free(cursor_path);
        pending_view.cursor_status = try self.loadCursorStatus(cursor_path, entry.name);
    }

    const children_transfer = transferTo(transfers, .children);
    const reused_children = if (children_transfer) |transfer|
        self.getPane(transfer.source).listing
    else
        null;
    var reused_applied = false;
    if (reused_children) |candidate| {
        const children_parent = std.fs.path.dirname(candidate.path) orelse "/";
        const matches_selected = center.entries.len > 0 and
            center.entries[center_cursor].is_dir and
            std.mem.eql(u8, center.path, children_parent) and
            std.mem.eql(
                u8,
                center.entries[center_cursor].name,
                std.fs.path.basename(candidate.path),
            );
        if (matches_selected) {
            setStagedDirectoryEmpty(
                &pending_view,
                .here,
                center,
                center_cursor,
                candidate.entries.len == 0,
            );
            if (candidate.entries.len == 0) {
                pending_view.previews[PaneRole.children.toIndex()] = try Preview.initMessage(
                    self.alloc,
                    "empty directory",
                );
            } else {
                const transfer = children_transfer.?;
                const children = pending_view.borrowListing(
                    transfer.source,
                    .children,
                    candidate,
                );
                _ = children;
                pending_view.cursors[PaneRole.children.toIndex()] =
                    self.getPane(transfer.source).list_view.cursor;
            }
            reused_applied = true;
        }
    }

    if (!reused_applied) {
        const child_index = PaneRole.children.toIndex();
        if (center.entries.len == 0) {
            pending_view.previews[child_index] = try Preview.initMessage(
                self.alloc,
                "empty directory",
            );
        } else {
            const entry = center.entries[center_cursor];
            const outcome = try self.buildChildrenOutcome(
                center.path,
                entry,
                if (pending_view.cursor_status) |status| status.metadata else null,
            );
            if (outcome.error_name) |error_name| {
                pending_view.rememberErrorName(error_name);
            } else {
                if (outcome.dir_is_empty) |is_empty| {
                    setStagedDirectoryEmpty(
                        &pending_view,
                        .here,
                        center,
                        center_cursor,
                        is_empty,
                    );
                }
                // Null content: the entry shows nothing, such as a
                // non-directory symbolic link.
                if (outcome.content) |content| switch (content) {
                    .listing => |listing| {
                        pending_view.listings[child_index] = listing;
                        pending_view.cursors[child_index] = 0;
                    },
                    .preview => |preview| pending_view.previews[child_index] = preview,
                    .none => {},
                };
            }
        }
    }

    return pending_view;
}

const ChildrenContent = union(enum) {
    listing: file_system.Listing,
    preview: Preview,
    none,
};

/// What CHILDREN should display for HERE's cursor entry. Only allocation
/// failure propagates as an error; every other failure is reported through
/// `error_name` so each caller degrades independently.
const ChildrenOutcome = struct {
    content: ?ChildrenContent = null,
    /// Set when a directory listing was read; whether it had no visible
    /// entries. Null when no directory was read.
    dir_is_empty: ?bool = null,
    /// Name of the first non-OOM preparation error, if any.
    error_name: ?[]const u8 = null,
};

fn buildChildrenOutcome(
    self: *Model,
    center_path: []const u8,
    entry: file_system.Entry,
    metadata_hint: ?FileMetadata,
) Allocator.Error!ChildrenOutcome {
    const child_path = try file_system.joinPath(self.alloc, center_path, entry.name);
    defer self.alloc.free(child_path);

    if (!entry.is_dir) {
        // Symbolic links render like their targets: reads and stats resolve
        // through the link, so a linked text file shows its contents and a
        // linked binary file shows the notice plus its target's sheet.
        // Text files render their contents; anything binary or invalid
        // UTF-8 keeps the metadata sheet.
        const size_hint: ?u64 = if (entry.is_sym)
            null // A link's statx size is the target-path length, not content.
        else if (metadata_hint) |hint| hint.size else null;
        const text_preview = Preview.initTextContent(
            self.alloc,
            self.io,
            child_path,
            size_hint,
            Preview.max_preview_bytes,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .error_name = @errorName(err) },
        };
        if (text_preview) |preview| return .{ .content = .{ .preview = preview } };
        const preview = if (entry.is_sym)
            Preview.initFileFollow(self.alloc, &self.identities, child_path)
        else
            Preview.initFile(self.alloc, &self.identities, child_path, metadata_hint);
        const sheet = preview catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .error_name = @errorName(err) },
        };
        return .{ .content = .{ .preview = sheet } };
    }

    var listing = file_system.readDir(
        self.alloc,
        self.io,
        child_path,
        .{ .show_hidden = self.show_hidden },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .error_name = @errorName(err) },
    };
    const dir_is_empty = listing.entries.len == 0;
    if (dir_is_empty) {
        listing.deinit();
        const preview = try Preview.initMessage(self.alloc, "empty directory");
        return .{ .content = .{ .preview = preview }, .dir_is_empty = true };
    }
    return .{ .content = .{ .listing = listing }, .dir_is_empty = false };
}

fn makeRows(self: *Model, pane: *Pane, count: usize) Allocator.Error![]Row {
    const rows = try self.alloc.alloc(Row, count);
    for (rows, 0..) |*row, index| row.* = .{ .pane = pane, .index = index };
    return rows;
}

/// Defers freeing replaced row widgets until the next draw. vxfw hit tests
/// against the previous frame's surface tree, and App drains the whole input
/// queue before rendering; freeing rows at commit time could otherwise leave
/// an in-flight mouse handler reading freed memory.
pub fn retireRows(self: *Model, rows: []Row) void {
    if (rows.len == 0) {
        self.alloc.free(rows);
        return;
    }
    self.retired_rows.appendAssumeCapacity(rows);
}

fn freeRetiredRows(self: *Model) void {
    for (self.retired_rows.items) |rows| self.alloc.free(rows);
    self.retired_rows.clearRetainingCapacity();
}

fn replaceAnchoredView(
    self: *Model,
    center_path: []const u8,
    options: ReplaceViewOptions,
) !void {
    const current_center_path = if (self.getPane(.here).listing) |listing|
        listing.path
    else
        null;
    const path_changed = if (current_center_path) |path|
        !std.mem.eql(u8, path, center_path)
    else
        true;
    var pending_watch: ?Watcher.Pending = null;
    if (options.rearm_watcher or path_changed or !self.watcher.hasCurrent()) {
        pending_watch = try self.watcher.prepare(center_path);
    }
    errdefer if (pending_watch) |watch| self.watcher.cancel(watch);

    var pending_view = try self.prepareView(
        center_path,
        options.preferred_name,
        options.transfers,
        options.fallback_cursor,
        options.reject_empty_center,
    );
    defer pending_view.deinit();

    const next_center = &pending_view.listings[PaneRole.here.toIndex()].?;
    if (options.restore_here_from) |previous| {
        std.debug.assert(pending_view.listing_sources[PaneRole.here.toIndex()] == null);
        // Rewrite only rows whose selection bit changed; work is proportional
        // to restored selections, not to the size of the new listing.
        for (previous.entries, 0..) |entry, index| {
            if (!previous.selected.isSet(index)) continue;
            const next_index = file_system.indexOfName(next_center, entry.name) orelse continue;
            next_center.selected.set(next_index);
            next_center.selected_count += 1;
            next_center.refreshRow(next_index);
        }
    }

    var rows: [3][]Row = undefined;
    var made: usize = 0;
    errdefer for (rows[0..made]) |slice| self.alloc.free(slice);
    for (&rows, 0..) |*slice, index| {
        const count = if (pending_view.listings[index]) |listing|
            listing.entries.len
        else if (pending_view.previews[index]) |preview|
            preview.lines.len
        else
            0;
        slice.* = try self.makeRows(&self.panes[index], count);
        made += 1;
    }

    const next_message = if (pending_view.preview_error_name) |error_name|
        try std.fmt.allocPrint(self.alloc, "preview unavailable: {s}", .{error_name})
    else if (options.preserve_message)
        try self.alloc.dupe(u8, self.message)
    else
        try self.alloc.dupe(u8, "");
    errdefer self.alloc.free(next_message);

    // Pane replacement retires up to three rendered row arrays. Reserve the
    // tracker before commit so retirement cannot fail after live state starts
    // changing or free userdata still retained by vxfw's previous frame.
    try self.retired_rows.ensureUnusedCapacity(self.alloc, self.panes.len);

    for (pending_view.directory_empty_transfers, 0..) |maybe_empty, target_index| {
        const empty_transfer = maybe_empty orelse continue;
        const source_role = pending_view.listing_sources[target_index].?;
        const source = self.getPane(source_role);
        source.listing.?.setDirectoryEmpty(empty_transfer.index, empty_transfer.is_empty);
    }

    // No fallible work may remain once live panes begin changing.
    if (pending_watch) |watch| self.watcher.commit(watch);

    var detached_sources: [3]bool = .{ false, false, false };
    for (pending_view.listing_sources) |maybe_source| {
        const source_role = maybe_source orelse continue;
        const source_index = source_role.toIndex();
        std.debug.assert(!detached_sources[source_index]);
        std.debug.assert(self.getPane(source_role).listing != null);
        self.getPane(source_role).listing = null;
        detached_sources[source_index] = true;
    }

    for (&self.panes, 0..) |*pane, index| {
        pane.replace(.{
            .listing = pending_view.listings[index],
            .preview = pending_view.previews[index],
            .rows = rows[index],
            .cursor = pending_view.cursors[index],
            .cwd_index = pending_view.cwd_indices[index],
        });
        pending_view.listings[index] = null;
        pending_view.previews[index] = null;
    }
    self.alloc.free(self.message);
    self.message = next_message;
    self.cursor_status = pending_view.cursor_status;
    self.preview_dirty = false;
    // A press from before this transaction must not pair with a press after
    // it: row indices belong to different listings.
    self.last_click = null;
    self.up_click_at_ns = null;
    const committed_center = self.centerListing();
    self.here_cursor = HereCursor.fromEntryCount(
        committed_center.entries.len,
        self.getPane(.here).list_view.cursor,
    );
    self.assertValid();
}

fn installPane(self: *Model, role: PaneRole, options: InstallOptions) !void {
    const count = if (options.listing.*) |listing|
        listing.entries.len
    else if (options.preview.*) |preview|
        preview.lines.len
    else
        0;
    const target = self.getPane(role);
    const rows = try self.makeRows(target, count);
    errdefer self.alloc.free(rows);
    try self.retired_rows.ensureUnusedCapacity(self.alloc, 1);
    target.replace(.{
        .listing = options.listing.*,
        .preview = options.preview.*,
        .rows = rows,
        .cursor = options.cursor,
        .cwd_index = options.cwd_index,
    });
    options.listing.* = null;
    options.preview.* = null;
}

fn clearPane(self: *Model, role: PaneRole) !void {
    var listing: ?file_system.Listing = null;
    var preview: ?Preview = null;
    try self.installPane(role, .{ .listing = &listing, .preview = &preview });
}

fn armPreviewTimer(
    self: *Model,
    ctx: *vxfw.EventContext,
    delay_ms: u32,
) Allocator.Error!void {
    if (self.preview_tick_pending) return;
    try ctx.tick(delay_ms, self.previewTimerWidget());
    self.preview_tick_pending = true;
}

pub fn deferRightSync(self: *Model, ctx: *vxfw.EventContext) Allocator.Error!void {
    self.preview_dirty = true;
    self.preview_due = Io.Clock.awake.now(self.io).addDuration(
        .fromMilliseconds(preview_debounce_ms),
    );
    try self.armPreviewTimer(ctx, preview_debounce_ms);
}

fn handlePreviewTimer(self: *Model, ctx: *vxfw.EventContext) !void {
    self.preview_tick_pending = false;
    if (!self.preview_dirty) return;

    const now = Io.Clock.awake.now(self.io);
    if (now.nanoseconds < self.preview_due.nanoseconds) {
        const remaining_ns = self.preview_due.nanoseconds - now.nanoseconds;
        const remaining_ms = @divTrunc(
            remaining_ns + std.time.ns_per_ms - 1,
            std.time.ns_per_ms,
        );
        try self.armPreviewTimer(ctx, @intCast(remaining_ms));
        return;
    }

    self.syncRight() catch |err| {
        self.preview_dirty = false;
        try self.reportError("preview", @errorName(err));
    };
    ctx.redraw = true;
}

fn syncRight(self: *Model) !void {
    const center = self.centerListing();
    const right = self.getPane(.children);
    var replacement_listing: ?file_system.Listing = null;
    errdefer if (replacement_listing) |*listing| listing.deinit();
    var replacement_preview: ?Preview = null;
    errdefer if (replacement_preview) |*preview| preview.deinit();

    if (self.here_cursor.isUp() and self.getPane(.here).showsUpRow()) {
        // Highlighting `..`: hint at what it does instead of previewing the
        // remembered entry.
        self.cursor_status = null;
        replacement_preview = try Preview.initMessage(self.alloc, "go up one level");
    } else if (center.entries.len == 0) {
        self.cursor_status = null;
        replacement_preview = try Preview.initMessage(self.alloc, "empty directory");
    } else {
        const center_cursor = self.hereEntryIndex().?;
        const entry = center.entries[center_cursor];
        const desired = try file_system.joinPath(self.alloc, center.path, entry.name);
        defer self.alloc.free(desired);
        self.cursor_status = try self.loadCursorStatus(desired, entry.name);
        if (entry.is_dir) {
            if (right.listing) |listing| {
                if (std.mem.eql(u8, listing.path, desired)) {
                    center.setDirectoryEmpty(center_cursor, false);
                    self.preview_dirty = false;
                    self.assertValid();
                    return;
                }
            }
        }

        const outcome = try self.buildChildrenOutcome(
            center.path,
            entry,
            if (self.cursor_status) |status| status.metadata else null,
        );
        if (outcome.error_name) |error_name| {
            try self.clearPane(.children);
            try self.setMessage("preview unavailable: {s}", .{error_name});
            self.preview_dirty = false;
            self.assertValid();
            return;
        }
        if (outcome.dir_is_empty) |is_empty| {
            center.setDirectoryEmpty(center_cursor, is_empty);
        }
        if (outcome.content) |content| switch (content) {
            .listing => |listing| replacement_listing = listing,
            .preview => |preview| replacement_preview = preview,
            .none => {},
        };
    }

    try self.installPane(.children, .{
        .listing = &replacement_listing,
        .preview = &replacement_preview,
        .cursor = 0,
    });
    self.preview_dirty = false;
    self.assertValid();
}

fn reconcileWatcher(self: *Model) !bool {
    switch (try self.watcher.drain(self.show_hidden)) {
        .none => {},
        .content => if (self.watch_refresh == .none) {
            self.watch_refresh = .refresh;
        },
        .rearm => self.watch_refresh = .rearm,
    }
    if (self.watch_refresh == .none or self.mode == .confirm or self.preview_dirty)
        return false;

    const center = self.centerListing();
    const center_cursor = self.hereEntryIndex();
    const preferred = if (center_cursor) |index| center.entries[index].name else null;
    const rearm_watcher = self.watch_refresh == .rearm;
    self.replaceAnchoredView(center.path, .{
        .preferred_name = preferred,
        .fallback_cursor = center_cursor,
        .transfers = &.{.{ .source = .parent, .target = .parent }},
        .restore_here_from = center,
        .preserve_message = true,
        .rearm_watcher = rearm_watcher,
    }) catch |err| {
        // Clear the pending refresh either way: later filesystem events
        // schedule a fresh one, so retrying on a timer would only repeat the
        // failure every tick.
        self.watch_refresh = .none;
        if (err == error.OutOfMemory) return err;
        try self.recoverMissingCenter(err);
        return true;
    };
    self.watch_refresh = .none;
    return true;
}

/// Re-anchors HERE at the nearest surviving ancestor after the anchored view
/// could not be rebuilt, typically because the directory was deleted or
/// unmounted externally. Every path is duped first: re-anchoring releases the
/// live listing that `center.path` borrows. Reports the original failure when
/// even `/` cannot host the view.
fn recoverMissingCenter(self: *Model, failure: anyerror) !void {
    const center_path = try self.alloc.dupe(u8, self.centerListing().path);
    defer self.alloc.free(center_path);
    const deleted_name = try self.alloc.dupe(u8, std.fs.path.basename(center_path));
    defer self.alloc.free(deleted_name);

    var candidate: []const u8 = try file_system.parentPath(self.alloc, center_path);
    defer self.alloc.free(candidate);
    while (true) {
        const usable = blk: {
            const dir = Io.Dir.openDirAbsolute(self.io, candidate, .{}) catch
                break :blk false;
            Io.Dir.close(dir, self.io);
            break :blk true;
        };
        if (usable or std.mem.eql(u8, candidate, "/")) break;
        const next = try file_system.parentPath(self.alloc, candidate);
        self.alloc.free(candidate);
        candidate = next;
    }

    self.replaceAnchoredView(candidate, .{}) catch |err| {
        try self.reportError("watcher", @errorName(failure));
        return err;
    };
    try self.setMessage("{s} is gone ({s})", .{ deleted_name, @errorName(failure) });
}

/// Opens `path` with the system opener. Restricted to regular files
/// without execute bits: `xdg-open` may execute whatever it is handed.
/// Symbolic links are classified by their targets. In tests the request may
/// be recorded instead of spawned; see `open_recorder`.
fn openWithSystem(self: *Model, path: []const u8, name: []const u8) !void {
    const metadata = FileMetadata.initFollow(path) catch |err| {
        try self.reportError("open", @errorName(err));
        return;
    };
    if (metadata.kind != .file or metadata.mode & 0o111 != 0) {
        try self.flashError("cannot open executables", .{});
        return;
    }
    if (self.open_recorder) |recorder| {
        try recorder.append(self.alloc, try self.alloc.dupe(u8, path));
    } else {
        self.spawnOpen(path) catch |err| {
            try self.flashError("open: {s}", .{@errorName(err)});
            return;
        };
    }
    try self.setMessage("opened {s}", .{name});
}

/// Spawns `self.open_program` for one path without waiting for it. The
/// child is left for `reapChildren` to collect on later watcher ticks.
fn spawnOpen(self: *Model, path: []const u8) std.process.SpawnError!void {
    _ = try std.process.spawn(self.io, .{
        .argv = &.{ self.open_program, path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

/// Collects exited opener children so detached spawns leave no zombies.
/// Nonblocking: returns as soon as no child has exited.
fn reapChildren() void {
    var status: u32 = undefined;
    while (true) {
        const rc = std.os.linux.wait4(-1, &status, std.os.linux.W.NOHANG, null);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                // rc is the child pid, or 0 when children exist but none has
                // exited yet.
                if (rc == 0) return;
            },
            .CHILD => return,
            .INTR => continue,
            else => return,
        }
    }
}

fn openCenter(self: *Model) !void {
    if (self.hereCursorOnUp()) {
        try self.ascend();
        return;
    }
    const listing = self.centerListing();
    const center_cursor = self.hereEntryIndex() orelse return;
    const entry = listing.entries[center_cursor];
    if (!entry.is_dir) {
        const target = try file_system.joinPath(self.alloc, listing.path, entry.name);
        defer self.alloc.free(target);
        try self.openWithSystem(target, entry.name);
        return;
    }
    const target = try file_system.joinPath(self.alloc, listing.path, entry.name);
    defer self.alloc.free(target);

    var transfers: [2]ListingTransfer = undefined;
    transfers[0] = .{ .source = .here, .target = .parent };
    var transfer_count: usize = 1;
    if (self.getPane(.children).listing) |children| {
        if (std.mem.eql(u8, children.path, target)) {
            transfers[1] = .{ .source = .children, .target = .here };
            transfer_count = 2;
        }
    }
    self.replaceAnchoredView(target, .{
        .transfers = transfers[0..transfer_count],
        .reject_empty_center = true,
    }) catch |err| switch (err) {
        error.EmptyDirectory => {
            listing.setDirectoryEmpty(center_cursor, true);
            try self.flashError("empty directory: {s}", .{entry.name});
        },
        else => return err,
    };
}

pub fn ascend(self: *Model) !void {
    const center = self.centerListing();
    if (std.mem.eql(u8, center.path, "/")) {
        try self.flashError("already at filesystem root", .{});
        return;
    }
    const target = try file_system.parentPath(self.alloc, center.path);
    defer self.alloc.free(target);
    const previous_parent = if (self.getPane(.parent).listing) |*parent|
        parent
    else
        null;
    try self.replaceAnchoredView(target, .{
        .preferred_name = std.fs.path.basename(center.path),
        .transfers = &.{.{
            .source = .here,
            .target = .children,
        }},
        // PARENT may be stale, so HERE is still read afresh. Its selection is
        // restored by entry name from the side-pane snapshot.
        .restore_here_from = previous_parent,
    });
}

fn moveCenter(self: *Model, ctx: *vxfw.EventContext, down: bool) !void {
    const pane = self.getPane(.here);
    const listing = &(pane.listing orelse return);
    const target = self.here_cursor.step(
        down,
        listing.entries.len,
        pane.showsUpRow(),
    );
    _ = try self.setHereCursor(ctx, target, .ensure_visible);
}

/// Handles a left press on a HERE row. A single press moves the cursor; a
/// second press on the same row within `double_click_interval_ms` descends
/// when that row is a directory.
pub fn handleRowClick(
    self: *Model,
    ctx: *vxfw.EventContext,
    index: usize,
) Allocator.Error!void {
    _ = try self.setHereCursor(ctx, .{ .entry = index }, .none);

    const now_ns = Io.Clock.awake.now(self.io).nanoseconds;
    const is_double = if (self.last_click) |click|
        click.index == index and
            now_ns - click.at_ns <= double_click_interval_ms * std.time.ns_per_ms
    else
        false;
    self.last_click = .{ .index = index, .at_ns = now_ns };
    if (!is_double) return;

    self.last_click = null;
    const listing = self.centerListing();
    const center_cursor = self.hereEntryIndex() orelse return;
    const entry = listing.entries[center_cursor];
    if (!entry.is_dir) {
        // Double-clicking anything but a directory opens it like `l` does.
        const target = try file_system.joinPath(self.alloc, listing.path, entry.name);
        defer self.alloc.free(target);
        try self.openWithSystem(target, entry.name);
        return;
    }
    self.openCenter() catch |err| try self.reportError("open", @errorName(err));
}

/// Navigates HERE into the parent directory with the clicked row selected
/// as its cursor: like `h`, except the user picks the row. Every row kind
/// qualifies — the click only chooses where the cursor lands.
pub fn handleParentClick(self: *Model, index: usize) !void {
    const pane = self.getPane(.parent);
    const listing = &(pane.listing orelse return);
    if (index >= listing.entries.len) return;
    const entry = listing.entries[index];

    // Ascending transfers the old HERE listing to CHILDREN, which is exact:
    // the new HERE is the old children's parent directory.
    try self.replaceAnchoredView(listing.path, .{
        .preferred_name = entry.name,
        .transfers = &.{.{ .source = .here, .target = .children }},
    });
}

/// Promotes the children pane to HERE with the clicked row selected as its
/// cursor: the pane's listing transfers to HERE (zero-cost), the old HERE
/// becomes PARENT, and the children pane renders the clicked entry's
/// content — a directory listing, a text preview, or a metadata sheet.
pub fn handleChildrenClick(self: *Model, index: usize) !void {
    const pane = self.getPane(.children);
    const listing = &(pane.listing orelse return);
    if (index >= listing.entries.len) return;
    const entry = listing.entries[index];

    try self.replaceAnchoredView(listing.path, .{
        .preferred_name = entry.name,
        .transfers = &.{
            .{ .source = .children, .target = .here },
            .{ .source = .here, .target = .parent },
        },
    });
}

pub fn handleWheel(
    self: *Model,
    ctx: *vxfw.EventContext,
    direction: WheelDirection,
) !void {
    if (self.wheel_tick_pending and self.wheel_direction == direction) {
        ctx.consumeEvent();
        return;
    }

    self.wheel_direction = direction;
    if (!self.wheel_tick_pending) {
        try ctx.tick(wheel_coalesce_ms, self.wheelTimerWidget());
        self.wheel_tick_pending = true;
    }
    try self.moveCenter(ctx, direction == .down);
    ctx.consumeAndRedraw();
}

fn halfJumpCenter(self: *Model, ctx: *vxfw.EventContext, down: bool) !void {
    const pane = self.getPane(.here);
    const listing = if (pane.listing) |*listing| listing else return;
    if (listing.entries.len == 0 or self.here_cursor.isUp() and !down) {
        ctx.consumeEvent();
        return;
    }

    const distance = @max(@as(usize, 1), @as(usize, self.cwd_visible_rows) / 2);
    const target = self.here_cursor.halfPage(
        down,
        listing.entries.len,
        distance,
    );
    if (!try self.setHereCursor(ctx, target, .ensure_visible)) {
        ctx.consumeEvent();
        return;
    }
    ctx.consumeAndRedraw();
}

fn jumpCenter(self: *Model, ctx: *vxfw.EventContext, bottom: bool) !void {
    const pane = self.getPane(.here);
    const listing = if (pane.listing) |*listing| listing else return;
    const target = HereCursor.jump(listing.entries.len, bottom);
    _ = try self.setHereCursor(ctx, target, .jump);
}

fn toggleSelection(self: *Model, ctx: *vxfw.EventContext) !void {
    const pane = self.getPane(.here);
    const listing = if (pane.listing) |*listing| listing else return;
    const center_cursor = self.hereEntryIndex() orelse return;
    listing.toggleSelected(center_cursor);
    try self.setMessage("", .{});

    const target = self.here_cursor.step(true, listing.entries.len, pane.showsUpRow());
    _ = try self.setHereCursor(ctx, target, .ensure_visible);
}

fn selectedCount(self: *const Model) usize {
    const listing = self.panes[PaneRole.here.toIndex()].listing orelse return 0;
    return listing.selectedCount();
}

fn deleteCount(self: *const Model) usize {
    const pane = &self.panes[PaneRole.here.toIndex()];
    const listing = pane.listing orelse return 0;
    const center_cursor = self.hereEntryIndex() orelse return 0;
    const use_selection = listing.selectedCount() > 0;
    var count: usize = 0;
    for (listing.entries, 0..) |_, index| {
        if (use_selection and !listing.selected.isSet(index)) continue;
        if (!use_selection and index != center_cursor) continue;
        count += 1;
    }
    return count;
}

fn beginDelete(self: *Model, ctx: *vxfw.EventContext) !void {
    if (self.hereCursorOnUp()) {
        try self.flashError("nothing safe to delete", .{});
        return;
    }
    const count = self.deleteCount();
    if (count == 0) {
        try self.returnToBrowse(ctx);
        try self.flashError("nothing safe to delete", .{});
        return;
    }
    self.confirm_count = count;
    self.mode = .confirm;
    try ctx.requestFocus(self.getPane(.here).list_view.widget());
}

fn executeDelete(self: *Model) !void {
    const listing = self.centerListing();
    const center_cursor = self.hereEntryIndex() orelse return;
    const use_selection = listing.selectedCount() > 0;
    const preferred = listing.entries[center_cursor].name;
    const center_path = listing.path;

    var targets: std.ArrayList(DeleteTarget) = .empty;
    defer {
        for (targets.items) |target| self.alloc.free(target.path);
        targets.deinit(self.alloc);
    }
    try targets.ensureTotalCapacity(self.alloc, self.deleteCount());
    for (listing.entries, 0..) |entry, index| {
        if (use_selection and !listing.selected.isSet(index)) continue;
        if (!use_selection and index != center_cursor) continue;

        const target_path = try file_system.joinPath(self.alloc, listing.path, entry.name);
        targets.appendAssumeCapacity(.{
            .path = target_path,
            .is_dir = entry.deleteAsDirectory(),
        });
    }

    var deleted: usize = 0;
    var failed: usize = 0;
    var first_error_name: ?[]const u8 = null;
    // Filesystem deletes, including partial directory-tree deletion, cannot be
    // rolled back. Attempt every target and report failures after refreshing.
    for (targets.items) |target| {
        file_system.deleteEntry(self.io, target.path, target.is_dir) catch |err| {
            failed += 1;
            if (first_error_name == null) first_error_name = @errorName(err);
            continue;
        };
        deleted += 1;
    }

    try self.replaceAnchoredView(center_path, .{
        .preferred_name = preferred,
        .fallback_cursor = center_cursor,
        .transfers = &.{.{ .source = .parent, .target = .parent }},
    });
    if (failed > 0) {
        try self.setMessage(
            "deleted {d}; {d} failed ({s})",
            .{
                deleted,
                failed,
                first_error_name.?,
            },
        );
    } else {
        try self.setMessage("deleted {d} item{s}", .{ deleted, if (deleted == 1) "" else "s" });
    }
}

fn setMessage(self: *Model, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    const replacement = try std.fmt.allocPrint(self.alloc, fmt, args);
    self.alloc.free(self.message);
    self.message = replacement;
}

pub fn reportError(self: *Model, action: []const u8, error_name: []const u8) Allocator.Error!void {
    try self.setMessage("{s}: {s}", .{ action, error_name });
}

/// Flashes a blocked-input notice beside the header path in red for
/// `error_flash_ms`; a watcher tick clears it once the deadline passes.
/// Replaces any pending notice and restarts its window.
fn flashError(self: *Model, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    const replacement = try std.fmt.allocPrint(self.alloc, fmt, args);
    if (self.error_message) |old| self.alloc.free(old);
    self.error_message = replacement;
    self.error_deadline = Io.Clock.awake.now(self.io).addDuration(
        .fromMilliseconds(error_flash_ms),
    );
}

/// Whether the HERE cursor currently highlights the `..` row.
pub fn hereCursorOnUp(self: *const Model) bool {
    return self.here_cursor.isUp() and
        self.panes[PaneRole.here.toIndex()].showsUpRow();
}

/// Drops any active flash immediately in response to user input.
fn dismissError(self: *Model, ctx: *vxfw.EventContext) void {
    const message = self.error_message orelse return;
    self.alloc.free(message);
    self.error_message = null;
    ctx.redraw = true;
}

/// Drops an expired flash, requesting a redraw when it did.
fn clearExpiredError(self: *Model) bool {
    const message = self.error_message orelse return false;
    if (Io.Clock.awake.now(self.io).nanoseconds < self.error_deadline.nanoseconds)
        return false;
    self.alloc.free(message);
    self.error_message = null;
    return true;
}

fn openCommand(self: *Model, ctx: *vxfw.EventContext) !void {
    self.mode = .command;
    self.text_field.clearRetainingCapacity();
    try ctx.requestFocus(self.text_field.widget());
}

fn returnToBrowse(self: *Model, ctx: *vxfw.EventContext) !void {
    self.mode = .browse;
    self.confirm_count = 0;
    self.text_field.clearRetainingCapacity();
    try ctx.requestFocus(self.getPane(.here).list_view.widget());
}

fn changeHiddenVisibility(self: *Model) !void {
    const previous = self.show_hidden;
    const enabled = !previous;
    self.show_hidden = enabled;

    const center = self.centerListing();
    const preferred = if (self.hereEntryIndex()) |index|
        center.entries[index].name
    else
        null;
    self.replaceAnchoredView(center.path, .{ .preferred_name = preferred }) catch |err| {
        self.show_hidden = previous;
        return err;
    };
    try self.setMessage("hidden files {s}", .{if (enabled) "on" else "off"});
}

fn submitCommand(self: *Model, ctx: *vxfw.EventContext, value: []const u8) !void {
    const parsed = command.parse(value) catch |err| {
        try self.returnToBrowse(ctx);
        switch (err) {
            error.Empty => try self.setMessage("empty command", .{}),
            error.UnknownCommand => try self.setMessage("unknown command", .{}),
            error.InvalidArguments => try self.setMessage("invalid command arguments", .{}),
        }
        return;
    };

    switch (parsed) {
        .help => {
            try self.returnToBrowse(ctx);
            try self.setMessage(
                "j/k move · Ctrl-D/U half-page · enter/l open · h up · space select · " ++
                    "Ctrl-H hidden · : commands · q quit",
                .{},
            );
        },
        .hidden => {
            self.changeHiddenVisibility() catch |err| {
                try self.returnToBrowse(ctx);
                try self.reportError("hidden", @errorName(err));
                return;
            };
            try self.returnToBrowse(ctx);
        },
        .delete => try self.beginDelete(ctx),
        .quit => ctx.quit = true,
    }
}

fn isDownKey(key: Key) bool {
    return key.matches('j', .{}) or
        key.matches('n', .{ .ctrl = true }) or
        key.matches(Key.down, .{});
}

fn isUpKey(key: Key) bool {
    return key.matches('k', .{}) or
        key.matches('p', .{ .ctrl = true }) or
        key.matches(Key.up, .{});
}

fn captureEvent(self: *Model, ctx: *vxfw.EventContext, event: vxfw.Event) !void {
    switch (event) {
        .key_press => {},
        // Only press-type input dismisses an active header flash: the
        // release and motion reports that trail a click must not wipe a
        // flash the press itself just raised.
        .mouse => |mouse| if (mouse.type != .press) return,
        else => return,
    }
    // Deliberate input always dismisses an active header flash.
    self.dismissError(ctx);

    const key = switch (event) {
        .key_press => |key| key,
        else => return,
    };

    switch (self.mode) {
        .browse => {
            if (key.matches('d', .{ .ctrl = true })) {
                self.halfJumpCenter(ctx, true) catch |err|
                    try self.reportError("half-page", @errorName(err));
                return;
            }
            if (key.matches('u', .{ .ctrl = true })) {
                self.halfJumpCenter(ctx, false) catch |err|
                    try self.reportError("half-page", @errorName(err));
                return;
            }
            if (isDownKey(key)) {
                self.moveCenter(ctx, true) catch |err|
                    try self.reportError("move", @errorName(err));
                // Movement is fully handled here. Consuming stops propagation
                // before the focused ListView's own movement handler would
                // step the cursor a second time.
                ctx.consumeEvent();
                return;
            }
            if (isUpKey(key)) {
                self.moveCenter(ctx, false) catch |err|
                    try self.reportError("move", @errorName(err));
                ctx.consumeEvent();
                return;
            }
        },
        .command => {
            if (key.matches(Key.escape, .{})) {
                try self.returnToBrowse(ctx);
                try self.setMessage("command cancelled", .{});
                ctx.consumeAndRedraw();
            }
        },
        .confirm => {
            if (key.matches('y', .{}) or key.matches('Y', .{})) {
                try self.returnToBrowse(ctx);
                self.executeDelete() catch |err|
                    try self.reportError("delete", @errorName(err));
                ctx.consumeAndRedraw();
            } else if (key.matches('n', .{}) or
                key.matches('N', .{}) or
                key.matches(Key.escape, .{}))
            {
                try self.returnToBrowse(ctx);
                try self.setMessage("delete cancelled", .{});
                ctx.consumeAndRedraw();
            } else {
                // Confirmation is modal: do not let movement or commands
                // leak into the CWD list.
                ctx.consumeEvent();
            }
        },
    }
}

fn handleEvent(self: *Model, ctx: *vxfw.EventContext, event: vxfw.Event) !void {
    switch (event) {
        .init => {
            try ctx.requestFocus(self.getPane(.here).list_view.widget());
            try ctx.setTitle("zanger");
            try ctx.tick(watcher_interval_ms, self.widget());
            ctx.consumeEvent();
        },
        .tick => {
            reapChildren();
            if (self.clearExpiredError()) ctx.redraw = true;
            try ctx.tick(watcher_interval_ms, self.widget());
            const refreshed = self.reconcileWatcher() catch |err| {
                try self.reportError("watcher", @errorName(err));
                ctx.redraw = true;
                return;
            };
            if (refreshed) ctx.redraw = true;
        },
        .key_press => |key| {
            if (self.mode != .browse) return;

            if (key.matches('h', .{ .ctrl = true })) {
                self.changeHiddenVisibility() catch |err|
                    try self.reportError("hidden", @errorName(err));
                ctx.consumeAndRedraw();
            } else if (key.matches(Key.enter, .{}) or key.matches('l', .{})) {
                self.openCenter() catch |err| try self.reportError("open", @errorName(err));
                ctx.consumeAndRedraw();
            } else if (key.matches('h', .{}) or key.matches(Key.backspace, .{})) {
                self.ascend() catch |err| try self.reportError("up", @errorName(err));
                ctx.consumeAndRedraw();
            } else if (key.matches('g', .{})) {
                self.jumpCenter(ctx, false) catch |err|
                    try self.reportError("jump", @errorName(err));
                ctx.consumeAndRedraw();
            } else if (key.matches('g', .{ .shift = true }) or key.matches('G', .{})) {
                self.jumpCenter(ctx, true) catch |err|
                    try self.reportError("jump", @errorName(err));
                ctx.consumeAndRedraw();
            } else if (key.matches(Key.space, .{})) {
                self.toggleSelection(ctx) catch |err|
                    try self.reportError("select", @errorName(err));
                ctx.consumeAndRedraw();
            } else if (key.matches(Key.tab, .{ .shift = true }) or
                key.matches(Key.tab, .{}))
            {
                ctx.consumeEvent();
            } else if (key.matches(':', .{})) {
                try self.openCommand(ctx);
                ctx.consumeAndRedraw();
            } else if (key.matches('q', .{})) {
                ctx.quit = true;
                ctx.consumeEvent();
            }
        },
        else => {},
    }
}

fn drawHeader(self: *Model, ctx: vxfw.DrawContext, width: u16) Allocator.Error!vxfw.Surface {
    const identity_style: vaxis.Cell.Style = .{
        .fg = .{ .index = 2 },
        .bold = true,
    };
    var header_text: [7]vaxis.Segment = .{
        .{ .text = self.user, .style = identity_style },
        .{ .text = "@", .style = identity_style },
        .{ .text = self.hostname, .style = identity_style },
        .{ .text = " " },
        .{ .text = self.centerListing().path },
        undefined,
        undefined,
    };
    var segment_count: usize = 5;
    if (self.error_message) |message| {
        header_text[5] = .{ .text = "  " };
        header_text[6] = .{
            .text = message,
            .style = .{ .fg = .{ .index = 1 }, .bold = true },
        };
        segment_count = 7;
    }
    const header: vxfw.RichText = .{
        .text = header_text[0..segment_count],
        .softwrap = false,
        .overflow = .ellipsis,
        .width_basis = .parent,
    };
    return header.draw(ctx.withConstraints(
        .{ .width = width, .height = 1 },
        .{ .width = width, .height = 1 },
    ));
}

fn drawCounts(
    ctx: vxfw.DrawContext,
    child_ctx: vxfw.DrawContext,
    counts_text: []const u8,
) Allocator.Error!vxfw.Surface {
    const counts = try ctx.arena.create(vxfw.Text);
    counts.* = .{
        .text = counts_text,
        .text_align = .right,
        .softwrap = false,
        .overflow = .ellipsis,
        .width_basis = .parent,
    };
    return counts.draw(child_ctx);
}

fn drawBottom(self: *Model, ctx: vxfw.DrawContext, width: u16) Allocator.Error!vxfw.Surface {
    const child_ctx = ctx.withConstraints(
        .{ .width = width, .height = 1 },
        .{ .width = width, .height = 1 },
    );
    if (self.mode == .command) {
        const prompt = try ctx.arena.create(vxfw.Text);
        prompt.* = .{ .text = ":", .softwrap = false };
        const prefix_buffer = try ctx.arena.alloc(u8, self.text_field.byteOffsetToCursor());
        const prefix = self.text_field.sliceToCursor(prefix_buffer);
        const suggested_name = command.suggestion(prefix);
        const hint_text = if (suggested_name) |name|
            try std.fmt.allocPrint(ctx.arena, "  → :{s}", .{name})
        else
            null;
        const show_hint = if (hint_text) |hint|
            ctx.stringWidth(hint) + 1 < width
        else
            false;

        const items = try ctx.arena.alloc(vxfw.FlexItem, if (show_hint) 3 else 2);
        items[0] = .{ .widget = prompt.widget(), .flex = 0 };
        items[1] = .{ .widget = self.text_field.widget(), .flex = 1 };
        if (show_hint) {
            const hint = try ctx.arena.create(vxfw.Text);
            hint.* = .{
                .text = hint_text.?,
                .style = .{ .dim = true },
                .softwrap = false,
            };
            items[2] = .{ .widget = hint.widget(), .flex = 0 };
        }
        const row: vxfw.FlexRow = .{ .children = items };
        return row.draw(child_ctx);
    }

    if (self.mode == .confirm) {
        const status_text = try std.fmt.allocPrint(
            ctx.arena,
            "Delete {d} item{s}? [y/N]",
            .{ self.confirm_count, if (self.confirm_count == 1) "" else "s" },
        );
        const status: vxfw.Text = .{
            .text = status_text,
            .softwrap = false,
            .overflow = .ellipsis,
            .width_basis = .parent,
        };
        return status.draw(child_ctx);
    }

    const center = self.centerListing();
    const counts_text = try std.fmt.allocPrint(
        ctx.arena,
        "{d} entries · {d} selected",
        .{ center.entries.len, self.selectedCount() },
    );
    const cursor_status = self.cursor_status orelse
        return drawCounts(ctx, child_ctx, counts_text);
    if (center.entries.len == 0 or ctx.stringWidth(counts_text) + 2 >= width) {
        return drawCounts(ctx, child_ctx, counts_text);
    }

    const link_count = try std.fmt.allocPrint(
        ctx.arena,
        "{d}",
        .{cursor_status.metadata.nlink},
    );
    const size = try format.humanSize(ctx.arena, cursor_status.metadata.size);
    const modified = try format.statusTime(
        ctx.arena,
        cursor_status.metadata.mtime,
        &self.local_time_zone,
    );
    // RichText cells borrow their grapheme bytes after drawBottom returns, so
    // keep the copied optional's inline mode array in the frame arena.
    const rendered_mode = try ctx.arena.dupe(u8, &cursor_status.mode_bits);
    const bits_style: vaxis.Cell.Style = .{ .fg = .{ .index = 12 } };
    const name_style: vaxis.Cell.Style = .{ .bold = true };
    const spans = try ctx.arena.dupe(vaxis.Segment, &.{
        .{ .text = rendered_mode, .style = bits_style },
        .{ .text = " " },
        .{ .text = link_count },
        .{ .text = " " },
        .{ .text = cursor_status.user_name },
        .{ .text = " " },
        .{ .text = cursor_status.group_name },
        .{ .text = " " },
        .{ .text = size },
        .{ .text = " " },
        .{ .text = modified },
        .{ .text = " " },
        .{ .text = cursor_status.entry_name, .style = name_style },
        .{ .text = "  " },
    });
    const details = try ctx.arena.create(vxfw.RichText);
    details.* = .{
        .text = spans,
        .softwrap = false,
        .overflow = .ellipsis,
        .width_basis = .parent,
    };
    const counts = try ctx.arena.create(vxfw.Text);
    counts.* = .{ .text = counts_text, .softwrap = false };
    const items = try ctx.arena.alloc(vxfw.FlexItem, 2);
    items[0] = .{ .widget = details.widget(), .flex = 1 };
    items[1] = .{ .widget = counts.widget(), .flex = 0 };
    const row: vxfw.FlexRow = .{ .children = items };
    return row.draw(child_ctx);
}

fn draw(self: *Model, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    // Rows retired since the last draw are only now unreachable by hit
    // testing, because the new tree replaces the retained one.
    self.freeRetiredRows();
    const size = ctx.max.size();
    self.cwd_visible_rows = if (size.height >= 4 and size.width >= 6)
        size.height - 3
    else
        1;
    const header = try self.drawHeader(ctx, size.width);
    const bottom = try self.drawBottom(ctx, size.width);

    // Each pane keeps one column of horizontal breathing room. Below that
    // minimum, preserve the header and command/status row without panes.
    if (size.height < 4 or size.width < 6) {
        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
        children[0] = .{ .origin = .{ .col = 0, .row = 0 }, .surface = header };
        children[1] = .{
            .origin = .{ .col = 0, .row = @intCast(size.height -| 1) },
            .surface = bottom,
        };
        return .{
            .size = size,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }

    const pane_height = size.height - 3;
    const items = try ctx.arena.alloc(vxfw.FlexItem, 3);
    for (&self.panes, 0..) |*pane, index| {
        pane.list_view.draw_cursor = false;

        const padding = try ctx.arena.create(vxfw.Padding);
        padding.* = .{
            .child = pane.widget(),
            .padding = vxfw.Padding.horizontal(1),
        };
        items[index] = .{ .widget = padding.widget(), .flex = 1 };
    }
    const row: vxfw.FlexRow = .{ .children = items };
    const panes_surface = try row.draw(ctx.withConstraints(
        .{ .width = size.width, .height = pane_height },
        .{ .width = size.width, .height = pane_height },
    ));

    const children = try ctx.arena.alloc(vxfw.SubSurface, 3);
    children[0] = .{ .origin = .{ .col = 0, .row = 0 }, .surface = header };
    children[1] = .{ .origin = .{ .col = 0, .row = 2 }, .surface = panes_surface };
    children[2] = .{
        .origin = .{ .col = 0, .row = @intCast(size.height - 1) },
        .surface = bottom,
    };
    return .{
        .size = size,
        .widget = self.widget(),
        .buffer = &.{},
        .children = children,
    };
}

test "headless model draw" {
    const testing = std.testing;
    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = cwd,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    vxfw.DrawContext.init(.unicode);
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{ .width = 90, .height = 24 },
        .max = .{ .width = 90, .height = 24 },
        .cell_size = .{ .width = 8, .height = 16 },
    };
    const surface = try model.draw(ctx);
    try testing.expectEqual(@as(u16, 90), surface.size.width);
    try testing.expectEqual(@as(u16, 24), surface.size.height);
    try testing.expectEqual(@as(usize, 3), surface.children.len);
    try testing.expectEqual(@as(i17, 2), surface.children[1].origin.row);
    try testing.expectEqualStrings("t", surface.children[0].surface.buffer[0].char.grapheme);
    const header_buffer = surface.children[0].surface.buffer;
    for (header_buffer[0.."tester@host".len]) |cell| {
        try testing.expect(cell.style.bold);
        try testing.expectEqual(vaxis.Cell.Color{ .index = 2 }, cell.style.fg);
    }
    try testing.expect(!header_buffer["tester@host".len].style.bold);
    try testing.expectEqual(
        vaxis.Cell.Color.default,
        header_buffer["tester@host".len].style.fg,
    );
    var expected_status_buffer: [64]u8 = undefined;
    const expected_status = try std.fmt.bufPrint(
        &expected_status_buffer,
        "{d} entries · 0 selected",
        .{model.centerListing().entries.len},
    );
    const bottom_surface = surface.children[2].surface;
    try testing.expectEqual(@as(usize, 2), bottom_surface.children.len);
    const status_buffer = bottom_surface.children[1].surface.buffer;
    var status_col: usize = 0;
    var expected_graphemes = ctx.graphemeIterator(expected_status);
    while (expected_graphemes.next()) |grapheme| {
        try testing.expectEqualStrings(
            grapheme.bytes(expected_status),
            status_buffer[status_col].char.grapheme,
        );
        status_col += ctx.stringWidth(grapheme.bytes(expected_status));
    }
    try testing.expectEqual(status_buffer.len, status_col);
    try testing.expectEqual(
        @as(i17, 90),
        bottom_surface.children[1].origin.col + bottom_surface.children[1].surface.size.width,
    );
    try testing.expect(model.getPane(.here).listing != null);
}

test "command status previews unique completion" {
    const testing = std.testing;
    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{ .start_path = cwd });
    defer model.deinit();
    model.mode = .command;
    try model.text_field.insertSliceAtCursor("d");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    vxfw.DrawContext.init(.unicode);
    const width = 40;
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{ .width = width, .height = 1 },
        .max = .{ .width = width, .height = 1 },
        .cell_size = .{ .width = 8, .height = 16 },
    };
    const bottom = try model.drawBottom(ctx, width);
    try testing.expectEqual(@as(usize, 3), bottom.children.len);

    const expected_hint = "  → :delete";
    const hint = bottom.children[2].surface.buffer;
    var column: usize = 0;
    var graphemes = ctx.graphemeIterator(expected_hint);
    while (graphemes.next()) |grapheme| {
        try testing.expectEqualStrings(
            grapheme.bytes(expected_hint),
            hint[column].char.grapheme,
        );
        try testing.expect(hint[column].style.dim);
        column += ctx.stringWidth(grapheme.bytes(expected_hint));
    }
    try testing.expectEqual(hint.len, column);

    model.text_field.clearRetainingCapacity();
    try model.text_field.insertSliceAtCursor("h");
    _ = arena.reset(.free_all);
    const ambiguous = try model.drawBottom(ctx, width);
    try testing.expectEqual(@as(usize, 2), ambiguous.children.len);
}

test "ctrl-h toggles hidden files" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.writeFile(temp.dir, testing.io, .{
        .sub_path = ".secret",
        .data = "hidden",
    });
    try Io.Dir.writeFile(temp.dir, testing.io, .{
        .sub_path = "visible",
        .data = "shown",
    });

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();
    try testing.expect(file_system.indexOfName(model.centerListing(), ".secret") == null);

    var ctx: vxfw.EventContext = .{
        .io = testing.io,
        .alloc = testing.allocator,
        .cmds = .empty,
        .redraw = false,
    };
    defer ctx.cmds.deinit(ctx.alloc);
    const ctrl_h: Key = .{
        .codepoint = 'h',
        .mods = .{ .ctrl = true },
    };
    try model.handleEvent(&ctx, .{ .key_press = ctrl_h });

    try testing.expect(model.show_hidden);
    try testing.expect(file_system.indexOfName(model.centerListing(), ".secret") != null);
    try testing.expectEqualStrings("hidden files on", model.message);
    try testing.expect(ctx.consume_event);
    try testing.expect(ctx.redraw);

    ctx.consume_event = false;
    ctx.redraw = false;
    try model.handleEvent(&ctx, .{ .key_press = ctrl_h });
    try testing.expect(!model.show_hidden);
    try testing.expect(file_system.indexOfName(model.centerListing(), ".secret") == null);
    try testing.expectEqualStrings("hidden files off", model.message);
    try testing.expect(ctx.consume_event);
    try testing.expect(ctx.redraw);

    ctx.consume_event = false;
    ctx.redraw = false;
    ctx.cmds.clearRetainingCapacity();
    try model.submitCommand(&ctx, "hi");
    try testing.expect(model.show_hidden);
    try testing.expect(file_system.indexOfName(model.centerListing(), ".secret") != null);
    try testing.expectEqualStrings("hidden files on", model.message);
}

test "ctrl-d and ctrl-u move half the visible cwd rows" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    for (0..20) |index| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "file-{d:0>2}", .{index});
        try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = name, .data = "" });
    }

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    vxfw.DrawContext.init(.unicode);
    _ = try model.draw(.{
        .arena = arena.allocator(),
        .min = .{ .width = 90, .height = 13 },
        .max = .{ .width = 90, .height = 13 },
        .cell_size = .{ .width = 8, .height = 16 },
    });
    try testing.expectEqual(@as(u16, 10), model.cwd_visible_rows);

    var ctx: vxfw.EventContext = .{
        .io = testing.io,
        .alloc = testing.allocator,
        .cmds = .empty,
        .redraw = false,
    };
    defer ctx.cmds.deinit(ctx.alloc);
    const ctrl_d: Key = .{ .codepoint = 'd', .mods = .{ .ctrl = true } };
    const ctrl_u: Key = .{ .codepoint = 'u', .mods = .{ .ctrl = true } };

    try model.captureEvent(&ctx, .{ .key_press = ctrl_d });
    try testing.expectEqual(@as(usize, 5), model.hereEntryIndex().?);
    try testing.expect(ctx.consume_event);
    try testing.expect(ctx.redraw);

    ctx.consume_event = false;
    ctx.redraw = false;
    try model.captureEvent(&ctx, .{ .key_press = ctrl_u });
    try testing.expectEqual(@as(usize, 0), model.hereEntryIndex().?);
    try testing.expect(ctx.consume_event);
    try testing.expect(ctx.redraw);

    _ = model.applyHereCursor(.{ .entry = 18 }, .none);
    ctx.consume_event = false;
    ctx.redraw = false;
    try model.captureEvent(&ctx, .{ .key_press = ctrl_d });
    try testing.expectEqual(@as(usize, 19), model.hereEntryIndex().?);

    ctx.consume_event = false;
    ctx.redraw = false;
    try model.captureEvent(&ctx, .{ .key_press = ctrl_u });
    try testing.expectEqual(@as(usize, 14), model.hereEntryIndex().?);
}

test "browse movement keys move one row and are consumed" {
    // Model.captureEvent moves the cursor during the capture phase. It must
    // consume the key so vxfw stops propagation before the focused ListView
    // applies its built-in movement handling to the same event.
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    for (0..3) |index| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "file-{d}", .{index});
        try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = name, .data = "" });
    }

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    var ctx: vxfw.EventContext = .{
        .io = testing.io,
        .alloc = testing.allocator,
        .cmds = .empty,
        .redraw = false,
    };
    defer ctx.cmds.deinit(ctx.alloc);

    const down: Key = .{ .codepoint = 'j' };
    try model.captureEvent(&ctx, .{ .key_press = down });
    try testing.expectEqual(@as(usize, 1), model.hereEntryIndex().?);
    try testing.expectEqual(@as(u32, 1), model.getPane(.here).list_view.cursor);
    try testing.expect(ctx.consume_event);
    ctx.consume_event = false;

    const up: Key = .{ .codepoint = 'k' };
    try model.captureEvent(&ctx, .{ .key_press = up });
    try testing.expectEqual(@as(usize, 0), model.hereEntryIndex().?);
    try testing.expectEqual(@as(u32, 0), model.getPane(.here).list_view.cursor);
    try testing.expect(ctx.consume_event);
}

test "ctrl-u saturates at the first entry instead of wrapping" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    for (0..8) |index| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "file-{d:0>2}", .{index});
        try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = name, .data = "" });
    }

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    vxfw.DrawContext.init(.unicode);
    _ = try model.draw(.{
        .arena = arena.allocator(),
        .min = .{ .width = 90, .height = 13 },
        .max = .{ .width = 90, .height = 13 },
        .cell_size = .{ .width = 8, .height = 16 },
    });
    // distance = (13 - 3) / 2 = 5, so any cursor index 0..=4 must saturate.

    var ctx: vxfw.EventContext = .{
        .io = testing.io,
        .alloc = testing.allocator,
        .cmds = .empty,
        .redraw = false,
    };
    defer ctx.cmds.deinit(ctx.alloc);
    const ctrl_u: Key = .{ .codepoint = 'u', .mods = .{ .ctrl = true } };

    try testing.expectEqual(@as(usize, 0), model.hereEntryIndex().?);
    try model.captureEvent(&ctx, .{ .key_press = ctrl_u });
    try testing.expectEqual(@as(usize, 0), model.hereEntryIndex().?);
}

test "space toggles consecutive selections and advances the cursor" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "a.txt", .data = "a" });
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "b.txt", .data = "b" });
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "c.txt", .data = "c" });

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    var ctx: vxfw.EventContext = .{
        .io = testing.io,
        .alloc = testing.allocator,
        .cmds = .empty,
        .redraw = false,
    };
    defer ctx.cmds.deinit(ctx.alloc);
    const space: Key = .{ .codepoint = Key.space };

    try model.handleEvent(&ctx, .{ .key_press = space });
    var center = model.centerListing();
    try testing.expect(center.selected.isSet(0));
    try testing.expectEqual(@as(usize, 1), model.hereEntryIndex().?);
    try testing.expectEqual(@as(u32, 1), model.getPane(.here).list_view.cursor);
    try testing.expect(model.preview_dirty);
    try testing.expect(model.preview_tick_pending);
    try testing.expectEqualStrings("a", model.getPane(.children).preview.?.lines[0]);
    try testing.expectEqualStrings("a.txt", model.cursor_status.?.entry_name);
    var pending_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer pending_arena.deinit();
    vxfw.DrawContext.init(.unicode);
    const pending_surface = try model.getPane(.children).widget().draw(.{
        .arena = pending_arena.allocator(),
        .min = .{ .width = 30, .height = 10 },
        .max = .{ .width = 30, .height = 10 },
        .cell_size = .{ .width = 8, .height = 16 },
    });
    try testing.expectEqual(@as(usize, 1), pending_surface.children.len);
    const pending_bottom = try model.drawBottom(.{
        .arena = pending_arena.allocator(),
        .min = .{ .width = 160, .height = 1 },
        .max = .{ .width = 160, .height = 1 },
        .cell_size = .{ .width = 8, .height = 16 },
    }, 160);
    try testing.expectEqual(@as(usize, 2), pending_bottom.children.len);
    model.preview_due = .zero;
    try model.previewTimerWidget().handleEvent(&ctx, .tick);
    try testing.expectEqualStrings("b", model.getPane(.children).preview.?.lines[0]);
    try testing.expectEqualStrings("b.txt", model.cursor_status.?.entry_name);
    try testing.expect(!model.preview_dirty);
    try testing.expect(ctx.consume_event);
    try testing.expect(ctx.redraw);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    vxfw.DrawContext.init(.unicode);
    const selected_surface = try model.getPane(.here).rows[0].widget().draw(.{
        .arena = arena.allocator(),
        .min = .{ .width = 30, .height = 1 },
        .max = .{ .width = 30, .height = 1 },
        .cell_size = .{ .width = 8, .height = 16 },
    });
    try testing.expect(selected_surface.buffer[0].style.bold);
    try testing.expectEqual(
        vaxis.Cell.Color{ .index = 11 },
        selected_surface.buffer[0].style.fg,
    );

    try model.handleEvent(&ctx, .{ .key_press = space });
    center = model.centerListing();
    try testing.expect(center.selected.isSet(1));
    try testing.expectEqual(@as(usize, 2), model.hereEntryIndex().?);
    try testing.expectEqual(@as(usize, 2), center.selectedCount());

    try model.handleEvent(&ctx, .{ .key_press = space });
    center = model.centerListing();
    try testing.expect(center.selected.isSet(2));
    try testing.expectEqual(@as(usize, 2), model.hereEntryIndex().?);
    try testing.expectEqual(@as(usize, 3), center.selectedCount());
}

test "delete recursively removes selected directories and their children" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.createDir(temp.dir, testing.io, "selected", .default_dir);
    try Io.Dir.createDir(temp.dir, testing.io, "selected/nested", .default_dir);
    try Io.Dir.writeFile(temp.dir, testing.io, .{
        .sub_path = "selected/nested/deep.txt",
        .data = "deep",
    });
    try Io.Dir.writeFile(temp.dir, testing.io, .{
        .sub_path = "selected.txt",
        .data = "selected",
    });
    try Io.Dir.writeFile(temp.dir, testing.io, .{
        .sub_path = "kept.txt",
        .data = "kept",
    });

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    const listing = model.centerListing();
    const directory_index = file_system.indexOfName(listing, "selected").?;
    _ = model.applyHereCursor(.{ .entry = directory_index }, .none);
    listing.toggleSelected(directory_index);
    const file_index = file_system.indexOfName(listing, "selected.txt").?;
    _ = model.applyHereCursor(.{ .entry = file_index }, .none);
    listing.toggleSelected(file_index);

    try model.executeDelete();

    const directory_path = try file_system.joinPath(
        testing.allocator,
        path,
        "selected",
    );
    defer testing.allocator.free(directory_path);
    const file_path = try file_system.joinPath(testing.allocator, path, "selected.txt");
    defer testing.allocator.free(file_path);
    const kept_path = try file_system.joinPath(testing.allocator, path, "kept.txt");
    defer testing.allocator.free(kept_path);
    try testing.expectError(
        error.FileNotFound,
        Io.Dir.accessAbsolute(testing.io, directory_path, .{}),
    );
    try testing.expectError(
        error.FileNotFound,
        Io.Dir.accessAbsolute(testing.io, file_path, .{}),
    );
    try Io.Dir.accessAbsolute(testing.io, kept_path, .{});
    try testing.expectEqualStrings("deleted 2 items", model.message);
    try testing.expectEqual(@as(usize, 0), model.centerListing().selectedCount());
}

test "delete keeps the cursor row and clamps it at the end" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "a.txt", .data = "a" });
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "b.txt", .data = "b" });
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "c.txt", .data = "c" });

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    var listing = model.centerListing();
    const middle_index = file_system.indexOfName(listing, "b.txt").?;
    _ = model.applyHereCursor(.{ .entry = middle_index }, .none);

    try model.executeDelete();

    listing = model.centerListing();
    var center_cursor = model.hereEntryIndex().?;
    try testing.expectEqual(@as(usize, 1), center_cursor);
    try testing.expectEqual(@as(u32, 1), model.getPane(.here).list_view.cursor);
    try testing.expectEqualStrings("c.txt", listing.entries[center_cursor].name);
    try testing.expectEqualStrings("c.txt", model.cursor_status.?.entry_name);

    try model.executeDelete();

    listing = model.centerListing();
    center_cursor = model.hereEntryIndex().?;
    try testing.expectEqual(@as(usize, 0), center_cursor);
    try testing.expectEqual(@as(u32, 0), model.getPane(.here).list_view.cursor);
    try testing.expectEqualStrings("a.txt", listing.entries[center_cursor].name);
    try testing.expectEqualStrings("a.txt", model.cursor_status.?.entry_name);
}

test "enter on a file opens it through the system opener" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "f.txt", .data = "f" });
    try Io.Dir.createDir(temp.dir, testing.io, "sub", .default_dir);
    try Io.Dir.writeFile(temp.dir, testing.io, .{
        .sub_path = "sub/inner.txt",
        .data = "i",
    });

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    var opened: std.ArrayList([]const u8) = .empty;
    defer {
        for (opened.items) |item| testing.allocator.free(item);
        opened.deinit(testing.allocator);
    }
    model.open_recorder = &opened;

    const index = file_system.indexOfName(model.centerListing(), "f.txt").?;
    _ = model.applyHereCursor(.{ .entry = index }, .none);

    const enter: Key = .{ .codepoint = Key.enter };
    var ctx: vxfw.EventContext = .{
        .io = testing.io,
        .alloc = testing.allocator,
        .cmds = .empty,
        .redraw = false,
    };
    defer ctx.cmds.deinit(ctx.alloc);
    try model.handleEvent(&ctx, .{ .key_press = enter });

    // The request went to the opener seam, not to navigation.
    try testing.expectEqual(@as(usize, 1), opened.items.len);
    const expected = try std.fs.path.join(testing.allocator, &.{ path, "f.txt" });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, opened.items[0]);
    try testing.expectEqualStrings(path, model.centerListing().path);
    try testing.expectEqualStrings("opened f.txt", model.message);

    // Directories still descend and are never sent to the opener.
    const dir_index = file_system.indexOfName(model.centerListing(), "sub").?;
    _ = model.applyHereCursor(.{ .entry = dir_index }, .none);
    ctx.cmds.clearRetainingCapacity();
    try model.handleEvent(&ctx, .{ .key_press = enter });
    try testing.expectEqual(@as(usize, 1), opened.items.len);
    try testing.expect(model.centerListing().path.len > path.len);
}

test "executable files are excluded from the system opener" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "f.txt", .data = "f" });
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "run.sh", .data = "#!/bin/sh\n" });
    try Io.Dir.setFilePermissions(
        temp.dir,
        testing.io,
        "run.sh",
        .fromMode(0o755),
        .{},
    );
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "quiet.bin", .data = "x\x00y" });
    try Io.Dir.setFilePermissions(
        temp.dir,
        testing.io,
        "quiet.bin",
        .fromMode(0o700),
        .{},
    );
    try Io.Dir.symLink(temp.dir, testing.io, "run.sh", "linked.sh", .{});

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    var opened: std.ArrayList([]const u8) = .empty;
    defer {
        for (opened.items) |item| testing.allocator.free(item);
        opened.deinit(testing.allocator);
    }
    model.open_recorder = &opened;

    const enter: Key = .{ .codepoint = Key.enter };
    var ctx: vxfw.EventContext = .{
        .io = testing.io,
        .alloc = testing.allocator,
        .cmds = .empty,
        .redraw = false,
    };
    defer ctx.cmds.deinit(ctx.alloc);

    // The keyboard path refuses executables, including behind a symlink.
    for ([_][]const u8{ "run.sh", "linked.sh" }) |name| {
        const index = file_system.indexOfName(model.centerListing(), name).?;
        _ = model.applyHereCursor(.{ .entry = index }, .none);
        ctx.cmds.clearRetainingCapacity();
        try model.handleEvent(&ctx, .{ .key_press = enter });
        try testing.expectEqualStrings(
            "cannot open executables",
            model.error_message.?,
        );
        try testing.expectEqual(@as(usize, 0), opened.items.len);
    }

    // The mouse path shares the same gate.
    const press: vaxis.Mouse = .{
        .col = 0,
        .row = 0,
        .button = .left,
        .mods = .{},
        .type = .press,
    };
    const exe_index = file_system.indexOfName(model.centerListing(), "quiet.bin").?;
    const rows = model.getPane(.here).rows;
    try rows[exe_index].widget().handleEvent(&ctx, .{ .mouse = press });
    try rows[exe_index].widget().handleEvent(&ctx, .{ .mouse = press });
    try testing.expectEqualStrings(path, model.centerListing().path);
    try testing.expectEqualStrings("cannot open executables", model.error_message.?);
    try testing.expectEqual(@as(usize, 0), opened.items.len);

    // A non-executable file in the same session still opens.
    const plain_index = file_system.indexOfName(model.centerListing(), "f.txt").?;
    try rows[plain_index].widget().handleEvent(&ctx, .{ .mouse = press });
    try rows[plain_index].widget().handleEvent(&ctx, .{ .mouse = press });
    try testing.expectEqual(@as(usize, 1), opened.items.len);
    try testing.expectEqualStrings("opened f.txt", model.message);

    // Any deliberate input dismisses an active flash immediately.
    const tab: Key = .{ .codepoint = Key.tab };
    ctx.redraw = false;
    try model.captureEvent(&ctx, .{ .key_press = tab });
    try testing.expect(model.error_message == null);
    try testing.expect(ctx.redraw);

    // A second dismissal with no flash pending is a harmless no-op.
    ctx.redraw = false;
    try model.captureEvent(&ctx, .{ .key_press = tab });
    try testing.expect(!ctx.redraw);
}

test "flashed errors render red beside the path and expire" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "f.txt", .data = "f" });

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    // Refuse an executable to trigger a flash.
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "run.sh", .data = "#!/bin/sh\n" });
    try Io.Dir.setFilePermissions(
        temp.dir,
        testing.io,
        "run.sh",
        .fromMode(0o755),
        .{},
    );
    // Rebuild HERE so run.sh is visible.
    try model.replaceAnchoredView(path, .{});
    const index = file_system.indexOfName(model.centerListing(), "run.sh").?;
    _ = model.applyHereCursor(.{ .entry = index }, .none);
    try model.openCenter();

    try testing.expectEqualStrings(
        "cannot open executables",
        model.error_message.?,
    );

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    vxfw.DrawContext.init(.unicode);
    const header = try model.drawHeader(.{
        .arena = arena.allocator(),
        .min = .{ .width = 120, .height = 1 },
        .max = .{ .width = 120, .height = 1 },
        .cell_size = .{ .width = 8, .height = 16 },
    }, 120);

    // Exactly one run of red bold cells exists after the path.
    var red_cells: usize = 0;
    var saw_red = false;
    for (header.buffer) |cell| {
        if (cell.style.fg == .index and cell.style.fg.index == 1) {
            saw_red = true;
            red_cells += 1;
            try testing.expect(cell.style.bold);
        } else {
            if (saw_red) break;
        }
    }
    try testing.expect(saw_red);
    try testing.expectEqual(@as(usize, "cannot open executables".len), red_cells);

    var ctx: vxfw.EventContext = .{
        .io = testing.io,
        .alloc = testing.allocator,
        .cmds = .empty,
        .redraw = false,
    };
    defer ctx.cmds.deinit(ctx.alloc);

    // A tick before the deadline keeps the flash.
    try model.handleEvent(&ctx, .tick);
    try testing.expect(model.error_message != null);

    // A tick past the deadline clears it and redraws.
    model.error_deadline.nanoseconds -= error_flash_ms * std.time.ns_per_ms + 1;
    ctx.redraw = false;
    try model.handleEvent(&ctx, .tick);
    try testing.expect(model.error_message == null);
    try testing.expect(ctx.redraw);
}

test "a failed system open reports the spawn error" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "f.txt", .data = "f" });

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();
    model.open_program = "/nonexistent/opener-for-tests";

    const index = file_system.indexOfName(model.centerListing(), "f.txt").?;
    _ = model.applyHereCursor(.{ .entry = index }, .none);

    const enter: Key = .{ .codepoint = Key.enter };
    var ctx: vxfw.EventContext = .{
        .io = testing.io,
        .alloc = testing.allocator,
        .cmds = .empty,
        .redraw = false,
    };
    defer ctx.cmds.deinit(ctx.alloc);
    try model.handleEvent(&ctx, .{ .key_press = enter });
    try testing.expectEqualStrings("open: FileNotFound", model.error_message.?);

    // Sweeping with no children must be a harmless no-op.
    reapChildren();
}

test "stepping onto dotdot hints and enter ascends" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.createDir(temp.dir, testing.io, "d", .default_dir);
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "d/inner.txt", .data = "i" });

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const root_path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(root_path);
    const d_path = try std.fs.path.join(testing.allocator, &.{ root_path, "d" });
    defer testing.allocator.free(d_path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = d_path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    var ctx: vxfw.EventContext = .{
        .io = testing.io,
        .alloc = testing.allocator,
        .cmds = .empty,
        .redraw = false,
    };
    defer ctx.cmds.deinit(ctx.alloc);

    // k from the first entry steps up onto '..'.
    const up_key: Key = .{ .codepoint = 'k' };
    try model.captureEvent(&ctx, .{ .key_press = up_key });
    try testing.expect(model.hereCursorOnUp());

    // The children pane hints instead of previewing a stale entry.
    try model.syncRight();
    const child_pane = model.getPane(.children);
    try testing.expect(child_pane.listing == null);
    try testing.expect(child_pane.preview.?.kind == .placeholder);
    try testing.expectEqualStrings("go up one level", child_pane.preview.?.lines[0]);
    try testing.expect(model.cursor_status == null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    vxfw.DrawContext.init(.unicode);
    const draw_ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{ .width = 20, .height = 1 },
        .max = .{ .width = 20, .height = 1 },
        .cell_size = .{ .width = 8, .height = 16 },
    };
    const up_surface = try model.getPane(.here).up_row.widget().draw(draw_ctx);
    try testing.expect(up_surface.buffer[0].style.reverse);

    // The first real entry must drop its highlight while '..' is selected.
    const first_row = try model.getPane(.here).rows[0].widget().draw(draw_ctx);
    try testing.expect(!first_row.buffer[0].style.reverse);

    // Enter on '..' ascends.
    const enter: Key = .{ .codepoint = Key.enter };
    try model.handleEvent(&ctx, .{ .key_press = enter });
    try testing.expectEqualStrings(root_path, model.centerListing().path);
    try testing.expect(!model.hereCursorOnUp());

    // j steps back off '..' and the children pane resumes normally.
    const down_key: Key = .{ .codepoint = 'j' };
    _ = model.applyHereCursor(.{ .up = model.here_cursor.rememberedEntry() }, .none);
    try model.captureEvent(&ctx, .{ .key_press = down_key });
    try testing.expect(!model.hereCursorOnUp());
    try model.syncRight();
    try testing.expect(model.cursor_status != null);
}

test "mouse releases do not dismiss a fresh flash" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "run.sh", .data = "#!/bin/sh\n" });
    try Io.Dir.setFilePermissions(
        temp.dir,
        testing.io,
        "run.sh",
        .fromMode(0o755),
        .{},
    );

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    var ctx: vxfw.EventContext = .{
        .io = testing.io,
        .alloc = testing.allocator,
        .cmds = .empty,
        .redraw = false,
    };
    defer ctx.cmds.deinit(ctx.alloc);

    // Refuse an executable to raise the flash.
    const enter: Key = .{ .codepoint = Key.enter };
    try model.handleEvent(&ctx, .{ .key_press = enter });
    try testing.expectEqualStrings(
        "cannot open executables",
        model.error_message.?,
    );
    ctx.consume_event = false;

    // The hardware release that trails a click must not wipe it.
    const release: vaxis.Mouse = .{
        .col = 0,
        .row = 0,
        .button = .left,
        .mods = .{},
        .type = .release,
    };
    try model.captureEvent(&ctx, .{ .mouse = release });
    try testing.expectEqualStrings(
        "cannot open executables",
        model.error_message.?,
    );

    // And nearly the whole three-second window remains.
    const remaining_ns =
        model.error_deadline.nanoseconds -
        Io.Clock.awake.now(testing.io).nanoseconds;
    try testing.expect(remaining_ns > 2 * std.time.ns_per_s);

    // A press, by contrast, dismisses immediately.
    var press: vaxis.Mouse = .{
        .col = 0,
        .row = 0,
        .button = .left,
        .mods = .{},
        .type = .press,
    };
    press.type = .press;
    try model.captureEvent(&ctx, .{ .mouse = press });
    try testing.expect(model.error_message == null);
}

test "repeated up keys hold the dotdot selection" {
    // Regression: key repeat spamming `k` toggled the highlight between
    // `..` and the first entry because a redundant clear ran after the
    // boundary step.
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "a.txt", .data = "a" });
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "z.txt", .data = "z" });

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    // Start below the top so the first press is an ordinary move.
    const z_index = file_system.indexOfName(model.centerListing(), "z.txt").?;
    _ = model.applyHereCursor(.{ .entry = z_index }, .none);

    var ctx: vxfw.EventContext = .{
        .io = testing.io,
        .alloc = testing.allocator,
        .cmds = .empty,
        .redraw = false,
    };
    defer ctx.cmds.deinit(ctx.alloc);
    const up_key: Key = .{ .codepoint = 'k' };

    // Hold-the-key spam: three presses in a row.
    var press: usize = 0;
    while (press < 3) : (press += 1) {
        ctx.consume_event = false;
        ctx.redraw = false;
        try model.captureEvent(&ctx, .{ .key_press = up_key });
        try testing.expect(ctx.consume_event);
    }

    // The selection must rest on `..`, with nothing else highlighted.
    try testing.expect(model.hereCursorOnUp());
    try testing.expectEqual(@as(u32, 0), model.getPane(.here).list_view.cursor);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    vxfw.DrawContext.init(.unicode);
    const draw_ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{ .width = 20, .height = 1 },
        .max = .{ .width = 20, .height = 1 },
        .cell_size = .{ .width = 8, .height = 16 },
    };
    const up_surface = try model.getPane(.here).up_row.widget().draw(draw_ctx);
    try testing.expect(up_surface.buffer[0].style.reverse);
    for (model.getPane(.here).rows) |row| {
        const surface = try row.widget().draw(draw_ctx);
        try testing.expect(!surface.buffer[0].style.reverse);
    }
}

test "dotdot selection blocks entry-scoped input and jumps clear it" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "a.txt", .data = "a" });
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "b.txt", .data = "b" });

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    var ctx: vxfw.EventContext = .{
        .io = testing.io,
        .alloc = testing.allocator,
        .cmds = .empty,
        .redraw = false,
    };
    defer ctx.cmds.deinit(ctx.alloc);

    const up_key: Key = .{ .codepoint = 'k' };
    try model.captureEvent(&ctx, .{ .key_press = up_key });
    try testing.expect(model.hereCursorOnUp());

    // Space has nothing to toggle.
    const space: Key = .{ .codepoint = Key.space };
    try model.handleEvent(&ctx, .{ .key_press = space });
    try testing.expectEqual(@as(usize, 0), model.centerListing().selectedCount());

    // Deletion is refused with the standard flash.
    try model.beginDelete(&ctx);
    try testing.expect(model.mode != .confirm);
    try testing.expectEqualStrings(
        "nothing safe to delete",
        model.error_message.?,
    );

    // Jumping to the bottom clears the '..' selection.
    const jump_key: Key = .{ .codepoint = 'G' };
    try model.handleEvent(&ctx, .{ .key_press = jump_key });
    try testing.expect(!model.hereCursorOnUp());
    try testing.expectEqualStrings(
        "b.txt",
        model.centerListing().entries[model.hereEntryIndex().?].name,
    );
}

test "clicking the dotdot row ascends and it hides at the root" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.createDir(temp.dir, testing.io, "d", .default_dir);
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "d/inner.txt", .data = "i" });

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const root_path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(root_path);
    const d_path = try std.fs.path.join(testing.allocator, &.{ root_path, "d" });
    defer testing.allocator.free(d_path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = d_path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    // The row exists only for HERE panes below the root.
    try testing.expect(model.getPane(.here).showsUpRow());
    try testing.expect(!model.getPane(.parent).showsUpRow());
    try testing.expect(!model.getPane(.children).showsUpRow());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    vxfw.DrawContext.init(.unicode);
    const pane_surface = try model.getPane(.here).widget().draw(.{
        .arena = arena.allocator(),
        .min = .{ .width = 40, .height = 8 },
        .max = .{ .width = 40, .height = 8 },
        .cell_size = .{ .width = 8, .height = 16 },
    });
    // Top band renders "..", styled like a directory.
    const up_band = pane_surface.children[0].surface;
    // Marker layout matches an unselected directory row: "  ▸  ..".
    try testing.expectEqualStrings(" ", up_band.buffer[0].char.grapheme);
    try testing.expectEqualStrings(" ", up_band.buffer[1].char.grapheme);
    try testing.expectEqualStrings("▸", up_band.buffer[2].char.grapheme);
    try testing.expectEqualStrings(".", up_band.buffer[5].char.grapheme);
    try testing.expectEqualStrings(".", up_band.buffer[6].char.grapheme);
    for (up_band.buffer[2..7]) |cell| {
        try testing.expect(cell.style.bold);
    }

    // First press highlights; a second press inside the window ascends.
    const press: vaxis.Mouse = .{
        .col = 0,
        .row = 0,
        .button = .left,
        .mods = .{},
        .type = .press,
    };
    var ctx: vxfw.EventContext = .{
        .io = testing.io,
        .alloc = testing.allocator,
        .cmds = .empty,
        .redraw = false,
    };
    defer ctx.cmds.deinit(ctx.alloc);

    try model.getPane(.here).up_row.widget().handleEvent(&ctx, .{ .mouse = press });
    try testing.expect(model.hereCursorOnUp());
    try testing.expectEqualStrings(d_path, model.centerListing().path);
    try testing.expect(ctx.consume_event);
    try testing.expect(ctx.redraw);

    ctx.consume_event = false;
    try model.getPane(.here).up_row.widget().handleEvent(&ctx, .{ .mouse = press });
    try testing.expectEqualStrings(root_path, model.centerListing().path);
    try testing.expect(ctx.consume_event);
    try testing.expect(ctx.redraw);
}

test "the dotdot row hides at the filesystem root" {
    const testing = std.testing;
    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = "/",
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    try testing.expect(!model.getPane(.here).showsUpRow());
}

test "parent clicks ascend and select an empty picked row" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.createDir(temp.dir, testing.io, "home", .default_dir);
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "home/x", .data = "x" });
    try Io.Dir.createDir(temp.dir, testing.io, "target", .default_dir);

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const root_path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(root_path);
    const home_path = try std.fs.path.join(testing.allocator, &.{ root_path, "home" });
    defer testing.allocator.free(home_path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = home_path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    // An empty directory row is as pickable as any other: clicking it
    // ascends into the parent with that row highlighted.
    const index = file_system.indexOfName(
        &model.getPane(.parent).listing.?,
        "target",
    ).?;
    try model.handleParentClick(index);
    try testing.expectEqualStrings(root_path, model.centerListing().path);
    try testing.expectEqual(index, model.hereEntryIndex().?);

    // CHILDREN mirrors the picked empty directory.
    const child_pane = model.getPane(.children);
    try testing.expect(child_pane.listing == null);
    try testing.expect(child_pane.preview.?.kind == .placeholder);
    try testing.expectEqualStrings("empty directory", child_pane.preview.?.lines[0]);
}

test "parent clicks ascend and select a picked file row" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.createDir(temp.dir, testing.io, "home", .default_dir);
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "notes.txt", .data = "n" });

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const root_path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(root_path);
    const home_path = try std.fs.path.join(testing.allocator, &.{ root_path, "home" });
    defer testing.allocator.free(home_path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = home_path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    // Files are pickable too — the click only chooses the cursor target.
    const index = file_system.indexOfName(
        &model.getPane(.parent).listing.?,
        "notes.txt",
    ).?;
    try model.handleParentClick(index);
    try testing.expectEqualStrings(root_path, model.centerListing().path);
    try testing.expectEqual(index, model.hereEntryIndex().?);

    // CHILDREN mirrors the picked file with its rendered contents.
    const child_pane = model.getPane(.children);
    try testing.expect(child_pane.listing == null);
    try testing.expect(child_pane.preview.?.kind == .text);
    try testing.expectEqualStrings("n", child_pane.preview.?.lines[0]);
}

test "double click on a directory descends into it" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.createDir(temp.dir, testing.io, "child", .default_dir);
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "child/x.txt", .data = "x" });
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "top.txt", .data = "t" });

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    var ctx: vxfw.EventContext = .{
        .io = testing.io,
        .alloc = testing.allocator,
        .cmds = .empty,
        .redraw = false,
    };
    defer ctx.cmds.deinit(ctx.alloc);
    const press: vaxis.Mouse = .{
        .col = 0,
        .row = 0,
        .button = .left,
        .mods = .{},
        .type = .press,
    };

    const index = file_system.indexOfName(model.centerListing(), "child").?;
    const row_widget = model.getPane(.here).rows[index].widget();

    // First press only moves the cursor.
    try row_widget.handleEvent(&ctx, .{ .mouse = press });
    try testing.expectEqualStrings(path, model.centerListing().path);
    try testing.expectEqual(index, model.hereEntryIndex().?);

    // Second press inside the window descends.
    try row_widget.handleEvent(&ctx, .{ .mouse = press });
    const child_path = try std.fs.path.join(testing.allocator, &.{ path, "child" });
    defer testing.allocator.free(child_path);
    try testing.expectEqualStrings(child_path, model.centerListing().path);
    // The transaction cleared pending click state.
    try testing.expect(model.last_click == null);
}

test "double click requires the same row within the interval" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.createDir(temp.dir, testing.io, "a-dir", .default_dir);
    try Io.Dir.createDir(temp.dir, testing.io, "b-dir", .default_dir);
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "b-dir/x.txt", .data = "x" });
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "f.txt", .data = "f" });

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    var ctx: vxfw.EventContext = .{
        .io = testing.io,
        .alloc = testing.allocator,
        .cmds = .empty,
        .redraw = false,
    };
    defer ctx.cmds.deinit(ctx.alloc);
    const press: vaxis.Mouse = .{
        .col = 0,
        .row = 0,
        .button = .left,
        .mods = .{},
        .type = .press,
    };
    const rows = model.getPane(.here).rows;

    // File double-clicks route to the opener seam instead of spawning.
    var opened: std.ArrayList([]const u8) = .empty;
    defer {
        for (opened.items) |item| testing.allocator.free(item);
        opened.deinit(testing.allocator);
    }
    model.open_recorder = &opened;

    // A second press past the interval is just another single click.
    const a_index = file_system.indexOfName(model.centerListing(), "a-dir").?;
    try rows[a_index].widget().handleEvent(&ctx, .{ .mouse = press });
    model.last_click.?.at_ns -=
        (double_click_interval_ms + 1) * std.time.ns_per_ms;
    try rows[a_index].widget().handleEvent(&ctx, .{ .mouse = press });
    try testing.expectEqualStrings(path, model.centerListing().path);
    model.last_click = null;

    // Presses on different rows never pair up.
    const b_index = file_system.indexOfName(model.centerListing(), "b-dir").?;
    try rows[a_index].widget().handleEvent(&ctx, .{ .mouse = press });
    try rows[b_index].widget().handleEvent(&ctx, .{ .mouse = press });
    try testing.expectEqualStrings(path, model.centerListing().path);
    try testing.expectEqual(b_index, model.hereEntryIndex().?);

    // Double-clicking a regular file opens it through the system opener.
    const f_index = file_system.indexOfName(model.centerListing(), "f.txt").?;
    try rows[f_index].widget().handleEvent(&ctx, .{ .mouse = press });
    try rows[f_index].widget().handleEvent(&ctx, .{ .mouse = press });
    try testing.expectEqual(@as(usize, 1), opened.items.len);
    const expected_path = try std.fs.path.join(
        testing.allocator,
        &.{ path, "f.txt" },
    );
    defer testing.allocator.free(expected_path);
    try testing.expectEqualStrings(expected_path, opened.items[0]);
    try testing.expectEqualStrings("opened f.txt", model.message);
    try testing.expectEqualStrings(path, model.centerListing().path);

    // Directory double-clicks still descend and never reach the opener.
    try rows[b_index].widget().handleEvent(&ctx, .{ .mouse = press });
    try rows[b_index].widget().handleEvent(&ctx, .{ .mouse = press });
    try testing.expectEqual(@as(usize, 1), opened.items.len);
    const b_child = try std.fs.path.join(testing.allocator, &.{ path, "b-dir" });
    defer testing.allocator.free(b_child);
    try testing.expectEqualStrings(b_child, model.centerListing().path);
}

test "a view transaction invalidates pending double clicks" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.createDir(temp.dir, testing.io, "child", .default_dir);

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    model.last_click = .{
        .index = 0,
        .at_ns = Io.Clock.awake.now(testing.io).nanoseconds,
    };
    try model.ascend();
    try testing.expect(model.last_click == null);
}

test "mouse wheel moves cwd one item and is ignored by side panes" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "a.txt", .data = "a" });
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "b.txt", .data = "b" });
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "c.txt", .data = "c" });
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "d.txt", .data = "d" });

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();
    var ctx: vxfw.EventContext = .{
        .io = testing.io,
        .alloc = testing.allocator,
        .cmds = .empty,
        .redraw = false,
    };
    defer ctx.cmds.deinit(ctx.alloc);
    var mouse: vaxis.Mouse = .{
        .col = 0,
        .row = 0,
        .button = .wheel_down,
        .mods = .{},
        .type = .press,
    };

    const parent_cursor = model.getPane(.parent).list_view.cursor;
    try model.getPane(.parent).widget().captureEvent(&ctx, .{ .mouse = mouse });
    try testing.expectEqual(parent_cursor, model.getPane(.parent).list_view.cursor);
    try testing.expectEqual(@as(usize, 0), model.hereEntryIndex().?);
    try testing.expect(ctx.consume_event);
    try testing.expect(!ctx.redraw);

    ctx.consume_event = false;
    try model.getPane(.here).widget().captureEvent(&ctx, .{ .mouse = mouse });
    try testing.expectEqual(@as(usize, 1), model.hereEntryIndex().?);
    try testing.expect(model.preview_dirty);
    try testing.expectEqualStrings("a", model.getPane(.children).preview.?.lines[0]);
    model.preview_due = .zero;
    try model.previewTimerWidget().handleEvent(&ctx, .tick);
    try testing.expectEqualStrings("b", model.getPane(.children).preview.?.lines[0]);
    try testing.expectEqual(@as(u8, 0), model.getPane(.here).list_view.wheel_scroll);
    try testing.expectEqual(@as(u8, 0), model.getPane(.parent).list_view.wheel_scroll);
    try testing.expectEqual(@as(u8, 0), model.getPane(.children).list_view.wheel_scroll);
    try testing.expect(ctx.consume_event);
    try testing.expect(ctx.redraw);

    // Coalesce duplicate reports from a single physical wheel notch.
    ctx.consume_event = false;
    ctx.redraw = false;
    const command_count = ctx.cmds.items.len;
    try model.getPane(.here).widget().captureEvent(&ctx, .{ .mouse = mouse });
    try testing.expectEqual(@as(usize, 1), model.hereEntryIndex().?);
    try testing.expectEqual(command_count, ctx.cmds.items.len);
    try testing.expect(ctx.consume_event);
    try testing.expect(!ctx.redraw);

    ctx.consume_event = false;
    ctx.redraw = false;
    ctx.cmds.clearRetainingCapacity();
    mouse.button = .wheel_up;
    try model.getPane(.here).widget().captureEvent(&ctx, .{ .mouse = mouse });
    try testing.expectEqual(@as(usize, 0), model.hereEntryIndex().?);
    try testing.expect(model.preview_dirty);
    try testing.expectEqualStrings("b", model.getPane(.children).preview.?.lines[0]);
    model.preview_due = .zero;
    try model.previewTimerWidget().handleEvent(&ctx, .tick);
    try testing.expectEqualStrings("a", model.getPane(.children).preview.?.lines[0]);
    try testing.expect(ctx.consume_event);
    try testing.expect(ctx.redraw);
}

test "side pane clicks navigate and browse focus returns to cwd" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.createDir(temp.dir, testing.io, "cwd", .default_dir);
    try Io.Dir.createDir(temp.dir, testing.io, "cwd/child", .default_dir);
    try Io.Dir.createDir(temp.dir, testing.io, "sibling", .default_dir);
    try Io.Dir.writeFile(temp.dir, testing.io, .{
        .sub_path = "sibling/inner.txt",
        .data = "i",
    });
    try Io.Dir.writeFile(temp.dir, testing.io, .{
        .sub_path = "cwd/child/a.txt",
        .data = "a",
    });
    try Io.Dir.writeFile(temp.dir, testing.io, .{
        .sub_path = "cwd/child/b.txt",
        .data = "b",
    });

    const process_cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(process_cwd);
    const path = try std.fs.path.join(testing.allocator, &.{
        process_cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
        "cwd",
    });
    defer testing.allocator.free(path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    var opened: std.ArrayList([]const u8) = .empty;
    defer {
        for (opened.items) |item| testing.allocator.free(item);
        opened.deinit(testing.allocator);
    }
    model.open_recorder = &opened;

    var ctx: vxfw.EventContext = .{
        .io = testing.io,
        .alloc = testing.allocator,
        .cmds = .empty,
        .redraw = false,
    };
    defer ctx.cmds.deinit(ctx.alloc);
    const click: vaxis.Mouse = .{
        .col = 0,
        .row = 0,
        .button = .left,
        .mods = .{},
        .type = .press,
    };

    // Clicking a children row promotes the children pane to HERE with the
    // clicked row selected; the children pane then renders that entry.
    const children = model.getPane(.children);
    try testing.expect(children.rows.len >= 2);
    try children.rows[0].widget().handleEvent(&ctx, .{ .mouse = click });

    const child_path = try std.fs.path.join(
        testing.allocator,
        &.{ path, "child" },
    );
    defer testing.allocator.free(child_path);
    try testing.expectEqualStrings(child_path, model.centerListing().path);
    try testing.expectEqual(@as(usize, 0), model.hereEntryIndex().?);
    // The clicked file renders its text preview in the children pane.
    const child_pane = model.getPane(.children);
    try testing.expect(child_pane.listing == null);
    try testing.expect(child_pane.preview.?.kind == .text);
    try testing.expectEqualStrings("a", child_pane.preview.?.lines[0]);
    // No opener involved for pane promotion.
    try testing.expectEqual(@as(usize, 0), opened.items.len);
    try testing.expect(ctx.consume_event);
    try testing.expect(ctx.redraw);

    // Clicking a parent row ascends into the parent directory with that
    // row selected — like `h`, but picking the row.
    ctx.consume_event = false;
    ctx.redraw = false;
    var parent = model.getPane(.parent);
    var pick_index = file_system.indexOfName(&parent.listing.?, "child").?;
    try parent.rows[pick_index].widget().handleEvent(&ctx, .{ .mouse = click });
    try testing.expectEqualStrings(path, model.centerListing().path);
    try testing.expectEqual(pick_index, model.hereEntryIndex().?);
    // The old HERE listing transferred to CHILDREN.
    try testing.expectEqualStrings(
        child_path,
        model.getPane(.children).listing.?.path,
    );

    // A second parent click climbs again, this time picking `sibling`.
    parent = model.getPane(.parent);
    pick_index = file_system.indexOfName(&parent.listing.?, "sibling").?;
    try parent.rows[pick_index].widget().handleEvent(&ctx, .{ .mouse = click });
    const sub_expected = try std.fs.path.join(testing.allocator, &.{
        process_cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(sub_expected);
    try testing.expectEqualStrings(sub_expected, model.centerListing().path);
    try testing.expectEqual(pick_index, model.hereEntryIndex().?);

    // Return home for the focus-flow checks: select cwd, then descend.
    ctx.consume_event = false;
    ctx.redraw = false;
    const cwd_here = file_system.indexOfName(model.centerListing(), "cwd").?;
    _ = model.applyHereCursor(.{ .entry = cwd_here }, .none);
    try model.openCenter();
    try testing.expectEqualStrings(path, model.centerListing().path);
    ctx.redraw = false;

    const center_cursor = model.getPane(.here).list_view.cursor;
    const tab: Key = .{ .codepoint = Key.tab };
    try model.handleEvent(&ctx, .{ .key_press = tab });
    try testing.expectEqual(center_cursor, model.getPane(.here).list_view.cursor);
    try testing.expect(ctx.consume_event);
    try testing.expect(!ctx.redraw);

    try model.openCommand(&ctx);
    try testing.expectEqual(@as(usize, 1), ctx.cmds.items.len);
    try testing.expect(ctx.cmds.items[0] == .request_focus);
    try testing.expect(ctx.cmds.items[0].request_focus.eql(model.text_field.widget()));

    ctx.cmds.clearRetainingCapacity();
    try model.returnToBrowse(&ctx);
    try testing.expectEqual(@as(usize, 1), ctx.cmds.items.len);
    try testing.expect(ctx.cmds.items[0] == .request_focus);
    try testing.expect(ctx.cmds.items[0].request_focus.eql(
        model.getPane(.here).list_view.widget(),
    ));
}

test "watcher re-anchors at the parent when HERE disappears" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.createDir(temp.dir, testing.io, "gone", .default_dir);

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const root_path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(root_path);
    const gone_path = try std.fs.path.join(testing.allocator, &.{ root_path, "gone" });
    defer testing.allocator.free(gone_path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = gone_path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    var ctx: vxfw.EventContext = .{
        .io = testing.io,
        .alloc = testing.allocator,
        .cmds = .empty,
        .redraw = false,
    };
    defer ctx.cmds.deinit(ctx.alloc);

    try Io.Dir.deleteDir(temp.dir, testing.io, "gone");
    try model.handleEvent(&ctx, .tick);

    try testing.expectEqualStrings(root_path, model.centerListing().path);
    try testing.expectEqualStrings("gone is gone (FileNotFound)", model.message);
    try testing.expect(model.watcher.hasCurrent());
    try testing.expect(ctx.redraw);

    // The failure must not repeat on later ticks.
    ctx.redraw = false;
    ctx.cmds.clearRetainingCapacity();
    try model.handleEvent(&ctx, .tick);
    try testing.expect(!ctx.redraw);
    try testing.expectEqualStrings("gone is gone (FileNotFound)", model.message);
}

test "watcher refresh preserves cursor selection and parent listing" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.writeFile(temp.dir, testing.io, .{
        .sub_path = "alpha.txt",
        .data = "alpha",
    });
    try Io.Dir.writeFile(temp.dir, testing.io, .{
        .sub_path = "beta.txt",
        .data = "beta",
    });

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    var center = model.centerListing();
    const beta_index = file_system.indexOfName(center, "beta.txt").?;
    _ = model.applyHereCursor(.{ .entry = beta_index }, .none);
    center.toggleSelected(beta_index);
    center.rebuildRows();
    try model.setMessage("keep this message", .{});
    const parent_path_pointer = model.getPane(.parent).listing.?.path.ptr;

    try Io.Dir.writeFile(temp.dir, testing.io, .{
        .sub_path = "gamma.txt",
        .data = "gamma",
    });
    var ctx: vxfw.EventContext = .{
        .io = testing.io,
        .alloc = testing.allocator,
        .cmds = .empty,
        .redraw = false,
    };
    defer ctx.cmds.deinit(ctx.alloc);
    model.preview_dirty = true;
    try model.handleEvent(&ctx, .tick);

    center = model.centerListing();
    try testing.expect(file_system.indexOfName(center, "gamma.txt") == null);
    try testing.expectEqual(WatchRefresh.refresh, model.watch_refresh);
    try testing.expect(!ctx.redraw);

    model.preview_dirty = false;
    ctx.cmds.clearRetainingCapacity();
    try model.handleEvent(&ctx, .tick);

    center = model.centerListing();
    try testing.expect(file_system.indexOfName(center, "gamma.txt") != null);
    var center_cursor = model.hereEntryIndex().?;
    try testing.expectEqualStrings("beta.txt", center.entries[center_cursor].name);
    try testing.expect(center.selected.isSet(center_cursor));
    try testing.expectEqual(@as(usize, 1), center.selectedCount());
    try testing.expectEqual(parent_path_pointer, model.getPane(.parent).listing.?.path.ptr);
    try testing.expectEqualStrings("keep this message", model.message);
    try testing.expect(ctx.redraw);
    try testing.expectEqual(@as(usize, 1), ctx.cmds.items.len);
    try testing.expect(ctx.cmds.items[0] == .tick);

    ctx.cmds.clearRetainingCapacity();
    ctx.redraw = false;
    try Io.Dir.deleteFile(temp.dir, testing.io, "beta.txt");
    try model.handleEvent(&ctx, .tick);

    center = model.centerListing();
    try testing.expect(file_system.indexOfName(center, "beta.txt") == null);
    center_cursor = model.hereEntryIndex().?;
    try testing.expectEqualStrings("gamma.txt", center.entries[center_cursor].name);
    try testing.expectEqual(@as(usize, 0), center.selectedCount());
    try testing.expect(ctx.redraw);
}

test "init stages children for a directory of only file symlinks" {
    // Regression: a non-directory symlink produces no content, and the
    // staging path must tolerate an outcome with neither listing nor preview.
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "target", .data = "t" });
    try Io.Dir.symLink(temp.dir, testing.io, "target", "link", .{});

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    // A file symlink renders its target's contents like a normal file.
    const child_pane = model.getPane(.children);
    try testing.expect(child_pane.listing == null);
    try testing.expect(child_pane.preview.?.kind == .text);
    try testing.expectEqualStrings("t", child_pane.preview.?.lines[0]);

    // The debounced sync must tolerate the same entry as well.
    var ctx: vxfw.EventContext = .{
        .io = testing.io,
        .alloc = testing.allocator,
        .cmds = .empty,
        .redraw = false,
    };
    defer ctx.cmds.deinit(ctx.alloc);
    try model.syncRight();
    try testing.expect(model.getPane(.children).listing == null);
    try testing.expect(model.getPane(.children).preview.?.kind == .text);
    try testing.expectEqualStrings("t", model.getPane(.children).preview.?.lines[0]);
}

test "replaced rows stay readable until the next draw" {
    // A commit frees pane content while vxfw's retained surface tree may
    // still reference its row widgets. Retirement must keep that memory
    // alive until the next draw replaces the hit-testing tree.
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.createDir(temp.dir, testing.io, "child", .default_dir);
    try Io.Dir.writeFile(temp.dir, testing.io, .{
        .sub_path = "child/a.txt",
        .data = "a",
    });

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    const retired_rows = model.getPane(.here).rows.ptr;
    try model.openCenter();
    try testing.expect(model.retired_rows.items.len > 0);
    // The retired array is still readable; handlers dispatched from a stale
    // hit list would read these Row values.
    try testing.expectEqual(@as(usize, 0), retired_rows[0].index);

    // Drawing releases retirement storage and deinit must not double free.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    vxfw.DrawContext.init(.unicode);
    _ = try model.draw(.{
        .arena = arena.allocator(),
        .min = .{ .width = 60, .height = 12 },
        .max = .{ .width = 60, .height = 12 },
        .cell_size = .{ .width = 8, .height = 16 },
    });
    try testing.expectEqual(@as(usize, 0), model.retired_rows.items.len);
}

test "anchored model navigation" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.createDir(temp.dir, testing.io, "child", .default_dir);
    try Io.Dir.writeFile(temp.dir, testing.io, .{
        .sub_path = "child/nested.txt",
        .data = "nested",
    });
    try Io.Dir.writeFile(temp.dir, testing.io, .{ .sub_path = "file.txt", .data = "file" });

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    const center = model.centerListing();
    const center_cursor = model.hereEntryIndex().?;
    try testing.expectEqualStrings(path, center.path);
    try testing.expectEqualStrings("child", center.entries[center_cursor].name);
    const right = model.getPane(.children).listing.?;
    const expected_right = try file_system.joinPath(testing.allocator, path, "child");
    defer testing.allocator.free(expected_right);
    try testing.expectEqualStrings(expected_right, right.path);
    const original_path_pointer = center.path.ptr;
    const preview_path_pointer = right.path.ptr;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    vxfw.DrawContext.init(.unicode);
    const row_surface = try model.getPane(.here).rows[center_cursor].widget().draw(.{
        .arena = arena.allocator(),
        .min = .{ .width = 30, .height = 1 },
        .max = .{ .width = 30, .height = 1 },
        .cell_size = .{ .width = 8, .height = 16 },
    });
    try testing.expect(row_surface.buffer[0].style.bold);
    try testing.expect(row_surface.buffer[0].style.reverse);
    try testing.expectEqual(vaxis.Cell.Color{ .index = 12 }, row_surface.buffer[0].style.fg);

    const parent_pane = model.getPane(.parent);
    const parent_cwd_index = parent_pane.cwd_index.?;
    try testing.expectEqualStrings(
        std.fs.path.basename(path),
        parent_pane.listing.?.entries[parent_cwd_index].name,
    );
    const parent_surface = try parent_pane.rows[parent_cwd_index].widget().draw(.{
        .arena = arena.allocator(),
        .min = .{ .width = 30, .height = 1 },
        .max = .{ .width = 30, .height = 1 },
        .cell_size = .{ .width = 8, .height = 16 },
    });
    try testing.expect(parent_surface.buffer[0].style.reverse);

    center.toggleSelected(center_cursor);
    try testing.expectEqual(@as(usize, 1), center.selectedCount());
    try model.openCenter();
    try testing.expectEqualStrings(expected_right, model.centerListing().path);
    try testing.expectEqual(preview_path_pointer, model.centerListing().path.ptr);
    try testing.expectEqual(original_path_pointer, model.getPane(.parent).listing.?.path.ptr);
    try testing.expectEqual(@as(usize, 1), model.getPane(.parent).listing.?.selectedCount());
    try testing.expectEqual(@as(usize, 0), model.centerListing().selectedCount());
    const descended_path_pointer = model.centerListing().path.ptr;
    model.centerListing().toggleSelected(model.hereEntryIndex().?);
    try testing.expectEqual(@as(usize, 1), model.centerListing().selectedCount());

    try model.ascend();
    const ascended = model.centerListing();
    const ascended_cursor = model.hereEntryIndex().?;
    try testing.expectEqualStrings(path, ascended.path);
    try testing.expectEqualStrings(
        "child",
        ascended.entries[ascended_cursor].name,
    );
    try testing.expect(ascended.selected.isSet(ascended_cursor));
    try testing.expectEqual(@as(usize, 1), ascended.selectedCount());
    try testing.expectEqual(
        descended_path_pointer,
        model.getPane(.children).listing.?.path.ptr,
    );
    try testing.expectEqual(
        @as(usize, 1),
        model.getPane(.children).listing.?.selectedCount(),
    );

    // Moving the selected CHILDREN listing back to HERE keeps its selection.
    try model.openCenter();
    try testing.expectEqual(descended_path_pointer, model.centerListing().path.ptr);
    try testing.expect(model.centerListing().selected.isSet(0));
    try testing.expectEqual(@as(usize, 1), model.centerListing().selectedCount());
    try model.ascend();
    const reascended_path_pointer = model.centerListing().path.ptr;

    // CHILDREN is not watched recursively. Revalidate a reusable snapshot so a
    // directory emptied externally cannot become HERE with stale contents.
    try Io.Dir.deleteFile(temp.dir, testing.io, "child/nested.txt");
    try model.openCenter();
    try testing.expectEqual(reascended_path_pointer, model.centerListing().path.ptr);
    try testing.expectEqualStrings("empty directory: child", model.error_message.?);
    try testing.expect(model.centerListing().entries[model.hereEntryIndex().?].is_empty.?);
}

test "children preview shows empty directories and file metadata" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.createDir(temp.dir, testing.io, "empty", .default_dir);
    // A NUL byte classifies the file as binary, keeping the metadata sheet.
    try Io.Dir.writeFile(temp.dir, testing.io, .{
        .sub_path = "notes.txt",
        .data = "four\x00",
    });
    try Io.Dir.setFilePermissions(
        temp.dir,
        testing.io,
        "notes.txt",
        .fromMode(0o640),
        .{},
    );

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    const center = model.centerListing();
    const center_cursor = model.hereEntryIndex().?;
    try testing.expectEqualStrings("empty", center.entries[center_cursor].name);
    try testing.expectEqualStrings("     empty", center.rows[center_cursor]);
    var child_pane = model.getPane(.children);
    try testing.expect(child_pane.listing == null);
    try testing.expect(child_pane.preview.?.kind == .placeholder);
    try testing.expectEqualStrings("empty directory", child_pane.preview.?.lines[0]);
    const empty_message_pointer = child_pane.preview.?.lines[0].ptr;
    var event_ctx: vxfw.EventContext = .{
        .io = testing.io,
        .alloc = testing.allocator,
        .cmds = .empty,
    };
    defer event_ctx.cmds.deinit(event_ctx.alloc);
    try model.jumpCenter(&event_ctx, false);
    try testing.expectEqual(
        empty_message_pointer,
        model.getPane(.children).preview.?.lines[0].ptr,
    );

    const original_center_path = model.centerListing().path.ptr;
    try model.openCenter();
    try testing.expectEqual(original_center_path, model.centerListing().path.ptr);
    try testing.expectEqualStrings(path, model.centerListing().path);
    try testing.expectEqualStrings("empty directory: empty", model.error_message.?);

    // Enter may arrive before the debounced CHILDREN preview has established
    // emptiness. The pending view must still be rejected before commit.
    model.centerListing().entries[model.hereEntryIndex().?].is_empty = null;
    try model.openCenter();
    try testing.expectEqual(original_center_path, model.centerListing().path.ptr);
    try testing.expect(model.centerListing().entries[model.hereEntryIndex().?].is_empty.?);

    child_pane = model.getPane(.children);
    try testing.expect(child_pane.preview.?.kind == .placeholder);
    try testing.expectEqualStrings("empty directory", child_pane.preview.?.lines[0]);
    try testing.expectEqualStrings(
        "     empty",
        model.centerListing().rows[model.hereEntryIndex().?],
    );

    const current_center = model.centerListing();
    const file_index = file_system.indexOfName(current_center, "notes.txt").?;
    _ = model.applyHereCursor(.{ .entry = file_index }, .none);
    try model.syncRight();

    child_pane = model.getPane(.children);
    try testing.expect(child_pane.listing == null);
    try testing.expect(child_pane.preview.?.kind != .placeholder);
    try testing.expectEqual(@as(usize, 2), child_pane.preview.?.header_lines);
    try testing.expectEqual(@as(usize, 10), child_pane.preview.?.lines.len);
    try testing.expectEqualStrings(
        "non-text files are not rendered",
        child_pane.preview.?.lines[0],
    );
    try testing.expectEqualStrings("", child_pane.preview.?.lines[1]);
    try testing.expectEqualStrings("Name: notes.txt", child_pane.preview.?.lines[2]);
    try testing.expectEqualStrings("Type: file", child_pane.preview.?.lines[3]);
    try testing.expectEqualStrings("Mode: -rw-r-----", child_pane.preview.?.lines[4]);
    try testing.expect(std.mem.startsWith(u8, child_pane.preview.?.lines[5], "Owner: "));
    try testing.expectEqualStrings("Size: 5B (5 bytes)", child_pane.preview.?.lines[6]);
    try testing.expect(std.mem.startsWith(u8, child_pane.preview.?.lines[7], "Modified: "));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    vxfw.DrawContext.init(.unicode);
    const bottom_width = 160;
    const bottom_surface = try model.drawBottom(.{
        .arena = arena.allocator(),
        .min = .{ .width = bottom_width, .height = 1 },
        .max = .{ .width = bottom_width, .height = 1 },
        .cell_size = .{ .width = 8, .height = 16 },
    }, bottom_width);
    try testing.expectEqual(@as(usize, 2), bottom_surface.children.len);
    const details = bottom_surface.children[0].surface.buffer;
    for (details[0..10], "-rw-r-----") |cell, expected| {
        try testing.expectEqualStrings(&.{expected}, cell.char.grapheme);
        try testing.expectEqual(vaxis.Cell.Color{ .index = 12 }, cell.style.fg);
    }
    const name = "notes.txt";
    const name_column = name_column: {
        var start: usize = 0;
        while (start + name.len <= details.len) : (start += 1) {
            var matches = true;
            for (name, 0..) |expected, offset| {
                const grapheme = details[start + offset].char.grapheme;
                if (grapheme.len != 1 or grapheme[0] != expected) {
                    matches = false;
                    break;
                }
            }
            if (matches) break :name_column start;
        }
        return error.TestExpectedEqual;
    };
    for (details[name_column..][0..name.len]) |cell| try testing.expect(cell.style.bold);

    const header_surface = try child_pane.rows[0].widget().draw(.{
        .arena = arena.allocator(),
        .min = .{ .width = 40, .height = 1 },
        .max = .{ .width = 40, .height = 1 },
        .cell_size = .{ .width = 8, .height = 16 },
    });
    // The notice renders like the empty-directory placeholder: dimmed and
    // italic, without metadata key styling.
    try testing.expect(header_surface.buffer[0].style.dim);
    try testing.expect(header_surface.buffer[0].style.italic);
    try testing.expect(!header_surface.buffer[0].style.bold);

    // The blank separator renders without metadata styling either.
    const spacer_surface = try child_pane.rows[1].widget().draw(.{
        .arena = arena.allocator(),
        .min = .{ .width = 40, .height = 1 },
        .max = .{ .width = 40, .height = 1 },
        .cell_size = .{ .width = 8, .height = 16 },
    });
    try testing.expect(!spacer_surface.buffer[0].style.bold);

    const metadata_surface = try child_pane.rows[2].widget().draw(.{
        .arena = arena.allocator(),
        .min = .{ .width = 40, .height = 1 },
        .max = .{ .width = 40, .height = 1 },
        .cell_size = .{ .width = 8, .height = 16 },
    });
    for (metadata_surface.buffer[0.."Name:".len]) |cell| {
        try testing.expect(cell.style.bold);
    }
    try testing.expect(!metadata_surface.buffer["Name:".len].style.bold);
}

test "non-text notice keeps its blank rows in list layout" {
    // Regression: ListView constrains row widgets to min.height 0, so empty
    // preview lines drawn as plain Text collapsed to zero height and pulled
    // the metadata sheet up against the notice.
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.writeFile(temp.dir, testing.io, .{
        .sub_path = "blob.dat",
        .data = "bin\x00ary",
    });

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    vxfw.DrawContext.init(.unicode);

    // Draw through the pane's ListView exactly like the real frame does.
    const pane_surface = try model.getPane(.children).widget().draw(.{
        .arena = arena.allocator(),
        .min = .{ .width = 40, .height = 12 },
        .max = .{ .width = 40, .height = 12 },
        .cell_size = .{ .width = 8, .height = 16 },
    });

    // Walk the surface tree collecting (row, first grapheme) for visible rows.
    const RenderedRow = struct { row: i17, grapheme: []const u8 };
    const Collector = struct {
        fn walk(
            surface: vxfw.Surface,
            row_offset: i17,
            rows: *std.ArrayList(RenderedRow),
            alloc: Allocator,
        ) Allocator.Error!void {
            if (surface.buffer.len >= surface.size.width) {
                try rows.append(alloc, .{
                    .row = row_offset,
                    .grapheme = surface.buffer[0].char.grapheme,
                });
            }
            for (surface.children) |child| {
                try walk(
                    child.surface,
                    row_offset + child.origin.row,
                    rows,
                    alloc,
                );
            }
        }
    };

    var rows: std.ArrayList(RenderedRow) = .empty;
    defer rows.deinit(testing.allocator);
    try Collector.walk(pane_surface, 0, &rows, testing.allocator);

    var notice_row: ?i17 = null;
    var name_row: ?i17 = null;
    var blank_rows: usize = 0;
    for (rows.items) |item| {
        // Blank cells carry vaxis's default single-space grapheme.
        if (std.mem.eql(u8, item.grapheme, " ")) blank_rows += 1;
        if (std.mem.eql(u8, item.grapheme, "n")) notice_row = item.row;
        if (std.mem.eql(u8, item.grapheme, "N")) name_row = item.row;
    }
    const start = notice_row orelse return error.TestUnexpectedResult;
    const sheet = name_row orelse return error.TestUnexpectedResult;
    // Notice, one blank, then the sheet's first line.
    try testing.expectEqual(@as(i17, 2), sheet - start);
    try testing.expectEqual(@as(usize, 1), blank_rows);
}

test "text file preview renders contents without metadata styling" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.writeFile(temp.dir, testing.io, .{
        .sub_path = "readme.txt",
        // The first line has no colon; metadata styling would crash on it.
        .data = "no colon here\nsecond: line\n",
    });

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    const index = file_system.indexOfName(model.centerListing(), "readme.txt").?;
    _ = model.applyHereCursor(.{ .entry = index }, .none);
    try model.syncRight();

    const child_pane = model.getPane(.children);
    try testing.expect(child_pane.listing == null);
    try testing.expect(child_pane.preview.?.kind == .text);
    try testing.expectEqual(@as(usize, 2), child_pane.preview.?.lines.len);
    try testing.expectEqualStrings("no colon here", child_pane.preview.?.lines[0]);
    try testing.expectEqualStrings("second: line", child_pane.preview.?.lines[1]);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    vxfw.DrawContext.init(.unicode);
    const surface = try child_pane.rows[0].widget().draw(.{
        .arena = arena.allocator(),
        .min = .{ .width = 30, .height = 1 },
        .max = .{ .width = 30, .height = 1 },
        .cell_size = .{ .width = 8, .height = 16 },
    });
    try testing.expectEqualStrings("n", surface.buffer[0].char.grapheme);
    // Text lines render verbatim: no bolded key span.
    try testing.expect(!surface.buffer[0].style.bold);
}

test "directory symlinks list targets and file symlinks render them" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try Io.Dir.createDir(temp.dir, testing.io, "target-dir", .default_dir);
    try Io.Dir.writeFile(temp.dir, testing.io, .{
        .sub_path = "target-dir/inside.txt",
        .data = "inside",
    });
    try Io.Dir.writeFile(temp.dir, testing.io, .{
        .sub_path = "target.txt",
        .data = "target",
    });
    try Io.Dir.symLink(temp.dir, testing.io, "target-dir", "dir-link", .{
        .is_directory = true,
    });
    try Io.Dir.symLink(temp.dir, testing.io, "target.txt", "file-link", .{});
    var long_target: [4000]u8 = undefined;
    @memset(&long_target, 'x');
    try Io.Dir.symLink(temp.dir, testing.io, &long_target, "long-link", .{});

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const path = try std.fs.path.join(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &temp.sub_path,
    });
    defer testing.allocator.free(path);

    var model: Model = undefined;
    try model.init(testing.allocator, testing.io, .{
        .start_path = path,
        .user = "tester",
        .hostname = "host",
    });
    defer model.deinit();

    var center = model.centerListing();
    const dir_link_index = file_system.indexOfName(center, "dir-link").?;
    try testing.expect(center.entries[dir_link_index].is_sym);
    try testing.expect(center.entries[dir_link_index].is_dir);
    _ = model.applyHereCursor(.{ .entry = dir_link_index }, .none);
    try model.syncRight();

    const link_path = try file_system.joinPath(testing.allocator, path, "dir-link");
    defer testing.allocator.free(link_path);
    try testing.expectEqualStrings(link_path, model.getPane(.children).listing.?.path);
    try testing.expect(
        file_system.indexOfName(&model.getPane(.children).listing.?, "inside.txt") != null,
    );

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    vxfw.DrawContext.init(.unicode);
    const dir_link_surface = try model.getPane(.here).rows[dir_link_index].widget().draw(.{
        .arena = arena.allocator(),
        .min = .{ .width = 20, .height = 1 },
        .max = .{ .width = 20, .height = 1 },
        .cell_size = .{ .width = 8, .height = 16 },
    });
    try testing.expectEqual(
        vaxis.Cell.Color{ .index = 6 },
        dir_link_surface.buffer[0].style.fg,
    );

    try model.openCenter();
    try testing.expectEqualStrings(link_path, model.centerListing().path);
    try testing.expect(file_system.indexOfName(model.centerListing(), "inside.txt") != null);
    try model.ascend();

    center = model.centerListing();
    const file_link_index = file_system.indexOfName(center, "file-link").?;
    try testing.expect(center.entries[file_link_index].is_sym);
    try testing.expect(!center.entries[file_link_index].is_dir);
    _ = model.applyHereCursor(.{ .entry = file_link_index }, .none);
    try model.syncRight();
    const link_child = model.getPane(.children);
    try testing.expect(link_child.listing == null);
    try testing.expect(link_child.preview.?.kind == .text);
    try testing.expectEqualStrings("target", link_child.preview.?.lines[0]);

    const long_link_index = file_system.indexOfName(center, "long-link").?;
    try testing.expectEqual(
        @as(usize, long_target.len),
        center.entries[long_link_index].link_target.?.len,
    );
    const clipped_surface = try model.getPane(.here).rows[long_link_index].widget().draw(.{
        .arena = arena.allocator(),
        .min = .{ .width = 20, .height = 1 },
        .max = .{ .width = 20, .height = 1 },
        .cell_size = .{ .width = 8, .height = 16 },
    });
    try testing.expectEqual(
        vaxis.Cell.Color{ .index = 6 },
        clipped_surface.buffer[0].style.fg,
    );
    try testing.expectEqualStrings("…", clipped_surface.buffer[19].char.grapheme);
}
