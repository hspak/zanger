//! Pure state machines for deferred model work.

const std = @import("std");
const Io = std.Io;

/// CHILDREN debounce state. `dirty` always means a tick is already queued to
/// service its deadline; `stale_tick` means the view is clean but a previously
/// queued tick still has to drain.
pub const Preview = union(enum) {
    idle,
    stale_tick,
    dirty: Io.Timestamp,

    pub fn isDirty(self: Preview) bool {
        return self == .dirty;
    }

    /// Updates a deadline already covered by a queued tick. Returns true only
    /// when the caller must queue the first tick before publishing `dirty`.
    pub fn request(self: *Preview, due: Io.Timestamp) bool {
        switch (self.*) {
            .idle => return true,
            .stale_tick => self.* = .{ .dirty = due },
            .dirty => |*deadline| deadline.* = due,
        }
        return false;
    }

    /// Publishes dirty work only after the caller successfully queued its
    /// servicing tick.
    pub fn publishQueued(self: *Preview, due: Io.Timestamp) void {
        std.debug.assert(self.* == .idle);
        self.* = .{ .dirty = due };
    }

    /// Consumes one delivered tick. Dirty work yields its deadline; a stale
    /// tick simply returns the scheduler to idle.
    pub fn takeTick(self: *Preview) ?Io.Timestamp {
        return switch (self.*) {
            .idle => null,
            .stale_tick => stale: {
                self.* = .idle;
                break :stale null;
            },
            .dirty => |due| dirty: {
                self.* = .idle;
                break :dirty due;
            },
        };
    }

    /// Marks committed CHILDREN content clean without cancelling a queued
    /// tick. A dirty tick becomes harmless and drains through `stale_tick`.
    pub fn markClean(self: *Preview) void {
        if (self.* == .dirty) self.* = .stale_tick;
    }
};

test "preview scheduling keeps dirty work paired with a tick" {
    const testing = std.testing;
    const first = Io.Timestamp.zero.addDuration(.fromMilliseconds(10));
    const second = Io.Timestamp.zero.addDuration(.fromMilliseconds(20));
    var schedule: Preview = .idle;

    try testing.expect(schedule.request(first));
    try testing.expect(schedule == .idle);
    schedule.publishQueued(first);
    try testing.expect(schedule.isDirty());

    try testing.expect(!schedule.request(second));
    try testing.expectEqual(second, schedule.dirty);
    schedule.markClean();
    try testing.expect(schedule == .stale_tick);

    try testing.expect(!schedule.request(first));
    try testing.expectEqual(first, schedule.takeTick().?);
    try testing.expect(schedule == .idle);

    schedule = .stale_tick;
    try testing.expect(schedule.takeTick() == null);
    try testing.expect(schedule == .idle);
}
