//! Staged replacement content for all three panes plus candidate model state.
//! Preparing everything before any live mutation keeps re-anchoring atomic: a
//! failure deinitializes this owner and leaves the committed view untouched.

const std = @import("std");

const file_system = @import("../file_system.zig");
const Model = @import("../Model.zig");
const Pane = @import("Pane.zig");
const Row = @import("Row.zig");

const PendingView = @This();

panes: [3]PendingPane = .{ .{}, .{}, .{} },
preview_error_name: ?[]const u8 = null,
cursor_status: ?Model.CursorStatus = null,

/// Moves one existing snapshot from a source pane role to a target role.
pub const ListingTransfer = struct {
    source: Model.PaneRole,
    target: Model.PaneRole,
};

/// Deferred emptiness update for a borrowed listing, applied to its live
/// source only after the whole transaction has prepared successfully.
pub const DirectoryEmptyTransfer = struct {
    index: usize,
    is_empty: bool,
};

/// Everything staged for one pane ownership slot. A non-null source means
/// `content` is a borrowed shallow listing copy until commit detaches the live
/// owner; `deinit` therefore never frees it in that state.
pub const PendingPane = struct {
    content: Pane.Content = .empty,
    cursor: u32 = 0,
    cwd_index: ?usize = null,
    listing_source: ?Model.PaneRole = null,
    directory_empty_transfer: ?DirectoryEmptyTransfer = null,

    fn deinit(self: *PendingPane) void {
        if (self.listing_source == null) {
            self.content.deinit();
        } else {
            std.debug.assert(self.content.listingPtr() != null);
            self.content = .empty;
        }
        self.* = undefined;
    }

    pub fn listing(self: *PendingPane) ?*file_system.Listing {
        return self.content.listingPtr();
    }

    pub fn setDirectoryEmpty(
        self: *PendingPane,
        index: usize,
        is_empty: bool,
    ) void {
        const payload = self.listing() orelse unreachable;
        if (self.listing_source != null) {
            self.directory_empty_transfer = .{
                .index = index,
                .is_empty = is_empty,
            };
        } else {
            payload.setDirectoryEmpty(index, is_empty);
        }
    }
};

pub fn deinit(self: *PendingView) void {
    for (&self.panes) |*pending| pending.deinit();
    self.* = undefined;
}

pub fn pane(self: *PendingView, role: Model.PaneRole) *PendingPane {
    return &self.panes[role.toIndex()];
}

/// Moves newly allocated content into one target pane.
pub fn stageOwned(
    self: *PendingView,
    target: Model.PaneRole,
    content: Pane.Content,
) *Pane.Content {
    const pending = self.pane(target);
    std.debug.assert(std.meta.activeTag(pending.content) == .empty);
    std.debug.assert(pending.listing_source == null);
    pending.content = content;
    return &pending.content;
}

/// Stages a shallow copy of a live listing under `target`. Ownership moves
/// only in `detachTransferredSources`; `deinit` never frees borrowed content.
pub fn borrowListing(
    self: *PendingView,
    source: Model.PaneRole,
    target: Model.PaneRole,
    listing: file_system.Listing,
) *file_system.Listing {
    const pending = self.pane(target);
    std.debug.assert(std.meta.activeTag(pending.content) == .empty);
    std.debug.assert(pending.listing_source == null);
    for (self.panes) |candidate| {
        if (candidate.listing_source) |existing| std.debug.assert(existing != source);
    }
    pending.content = .{ .listing = listing };
    pending.listing_source = source;
    return pending.listing().?;
}

/// Records the first non-fatal preview error for reporting after commit.
pub fn rememberErrorName(self: *PendingView, error_name: []const u8) void {
    if (self.preview_error_name == null) self.preview_error_name = error_name;
}

/// Applies mutations deferred for shallow borrowed listings to their live
/// owners. Preparation and row-retirement reservation must already be done.
pub fn applyDeferredListingMutations(
    self: *PendingView,
    live_panes: *[3]Pane,
) void {
    for (&self.panes) |*pending| {
        const mutation = pending.directory_empty_transfer orelse continue;
        const source = pending.listing_source orelse unreachable;
        live_panes[source.toIndex()].listing().?.setDirectoryEmpty(
            mutation.index,
            mutation.is_empty,
        );
        pending.directory_empty_transfer = null;
    }
}

/// Converts every borrowed shallow copy into the sole owner by clearing its
/// live source tag. No fallible work may follow this commit operation.
pub fn detachTransferredSources(
    self: *PendingView,
    live_panes: *[3]Pane,
) void {
    var detached: [3]bool = .{ false, false, false };
    for (&self.panes) |*pending| {
        const source = pending.listing_source orelse continue;
        const source_index = source.toIndex();
        std.debug.assert(!detached[source_index]);
        std.debug.assert(live_panes[source_index].listing() != null);
        live_panes[source_index].content = .empty;
        pending.listing_source = null;
        detached[source_index] = true;
    }
}

/// Moves one fully owned staged pane into a replacement record. The pending
/// slot remains a valid empty owner for the deferred `deinit` call.
pub fn takeForInstall(
    self: *PendingView,
    role: Model.PaneRole,
    rows: []Row,
) Pane.Replacement {
    const pending = self.pane(role);
    std.debug.assert(pending.listing_source == null);
    const replacement: Pane.Replacement = .{
        .content = pending.content,
        .rows = rows,
        .cursor = pending.cursor,
        .cwd_index = pending.cwd_index,
    };
    pending.content = .empty;
    return replacement;
}
