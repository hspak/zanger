//! Staged replacement content for all three panes plus the candidate watcher
//! state. Preparing everything before any live mutation keeps re-anchoring
//! atomic: a failure deinitializes the staging area and leaves the committed
//! view untouched.

const std = @import("std");

const file_system = @import("../file_system.zig");
const Model = @import("../Model.zig");
const Preview = @import("Preview.zig");

const PendingView = @This();

listings: [3]?file_system.Listing = .{ null, null, null },
cursors: [3]u32 = .{ 0, 0, 0 },
previews: [3]?Preview = .{ null, null, null },
cwd_indices: [3]?usize = .{ null, null, null },
preview_error_name: ?[]const u8 = null,
cursor_status: ?Model.CursorStatus = null,
// A non-null source means the target slot is a borrowed shallow copy of a
// live listing. Ownership moves only after all fallible preparation ends.
listing_sources: [3]?Model.PaneRole = .{ null, null, null },
directory_empty_transfers: [3]?DirectoryEmptyTransfer = .{ null, null, null },

/// Moves one existing snapshot from a source pane role to a target role.
pub const ListingTransfer = struct {
    source: Model.PaneRole,
    target: Model.PaneRole,
};

/// Deferred emptiness update for a borrowed listing, applied to its source
/// pane only after the whole transaction commits.
pub const DirectoryEmptyTransfer = struct {
    index: usize,
    is_empty: bool,
};

pub fn deinit(self: *PendingView) void {
    for (&self.listings, 0..) |*maybe_listing, index| {
        if (self.listing_sources[index] != null) continue;
        if (maybe_listing.*) |*listing| listing.deinit();
    }
    for (&self.previews) |*maybe_preview| {
        if (maybe_preview.*) |*preview| preview.deinit();
    }
    self.* = undefined;
}

/// Records the first non-fatal preview error for reporting after commit.
pub fn rememberErrorName(self: *PendingView, error_name: []const u8) void {
    if (self.preview_error_name == null) self.preview_error_name = error_name;
}

/// Stages a shallow copy of a live listing under `target`. The source slot is
/// detached by the commit path; `deinit` never frees borrowed slots.
pub fn borrowListing(
    self: *PendingView,
    source: Model.PaneRole,
    target: Model.PaneRole,
    listing: file_system.Listing,
) *file_system.Listing {
    const target_index = target.toIndex();
    std.debug.assert(self.listings[target_index] == null);
    std.debug.assert(self.listing_sources[target_index] == null);
    for (self.listing_sources) |maybe_source| {
        if (maybe_source) |existing_source| std.debug.assert(existing_source != source);
    }
    self.listings[target_index] = listing;
    self.listing_sources[target_index] = source;
    return &self.listings[target_index].?;
}
