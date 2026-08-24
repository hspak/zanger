//! Pure pointer-input policy shared by model and widget adapters.

const std = @import("std");
const vaxis = @import("vaxis");

pub const ClickTarget = union(enum) {
    up,
    entry: usize,

    fn eql(a: ClickTarget, b: ClickTarget) bool {
        return switch (a) {
            .up => b == .up,
            .entry => |a_index| switch (b) {
                .entry => |b_index| a_index == b_index,
                else => false,
            },
        };
    }
};

pub const DoubleClickTracker = struct {
    const Press = struct {
        target: ClickTarget,
        at_ns: i128,
        generation: u64,
    };

    last: ?Press = null,
    generation: u64 = 0,

    /// Records one press and returns whether it completes a double click.
    /// A completed pair is consumed so a third press starts a new pair.
    pub fn press(
        self: *DoubleClickTracker,
        target: ClickTarget,
        now_ns: i128,
        interval_ns: i128,
    ) bool {
        const is_double = if (self.last) |last| double: {
            const elapsed = now_ns - last.at_ns;
            break :double last.generation == self.generation and
                last.target.eql(target) and
                elapsed >= 0 and
                elapsed <= interval_ns;
        } else false;
        self.last = if (is_double) null else .{
            .target = target,
            .at_ns = now_ns,
            .generation = self.generation,
        };
        return is_double;
    }

    /// Starts a new view generation so row identities from the replaced view
    /// can never pair with later presses.
    pub fn invalidateView(self: *DoubleClickTracker) void {
        self.generation +%= 1;
        self.last = null;
    }
};

pub fn isPress(mouse: vaxis.Mouse) bool {
    return mouse.type == .press;
}

pub fn isLeftPress(mouse: vaxis.Mouse) bool {
    return mouse.button == .left and isPress(mouse);
}

test "double clicks require target interval and view generation" {
    const testing = std.testing;
    const interval = 400 * std.time.ns_per_ms;
    var tracker: DoubleClickTracker = .{};

    try testing.expect(!tracker.press(.{ .entry = 1 }, 1_000, interval));
    try testing.expect(!tracker.press(.{ .entry = 2 }, 2_000, interval));
    try testing.expect(tracker.press(.{ .entry = 2 }, 2_000 + interval, interval));
    try testing.expect(!tracker.press(.up, 3_000, interval));
    try testing.expect(!tracker.press(.up, 3_001 + interval, interval));
    try testing.expect(!tracker.press(.{ .entry = 1 }, 8_000, interval));
    tracker.invalidateView();
    try testing.expect(!tracker.press(.{ .entry = 1 }, 8_001, interval));
    try testing.expect(tracker.press(.{ .entry = 1 }, 8_002, interval));
}

test "mouse policy accepts only matching presses" {
    const testing = std.testing;
    var mouse: vaxis.Mouse = .{
        .col = 0,
        .row = 0,
        .button = .left,
        .mods = .{},
        .type = .press,
    };
    try testing.expect(isPress(mouse));
    try testing.expect(isLeftPress(mouse));

    inline for (.{ .release, .motion, .drag }) |event_type| {
        mouse.type = event_type;
        try testing.expect(!isPress(mouse));
        try testing.expect(!isLeftPress(mouse));
    }
    mouse.type = .press;
    mouse.button = .right;
    try testing.expect(isPress(mouse));
    try testing.expect(!isLeftPress(mouse));
}
