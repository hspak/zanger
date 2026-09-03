//! Pure HERE cursor states and transitions. The vxfw cursor is an applied
//! projection of this logical value, not an additional source of truth.

const std = @import("std");

pub const Here = union(enum) {
    /// HERE has no entries.
    none,
    entry: usize,

    pub fn fromEntryCount(entry_count: usize, index: usize) Here {
        if (entry_count == 0) return .none;
        return .{ .entry = @min(index, entry_count - 1) };
    }

    pub fn selectedEntry(self: Here) ?usize {
        return switch (self) {
            .none => null,
            .entry => |index| index,
        };
    }

    pub fn eql(a: Here, b: Here) bool {
        return switch (a) {
            .none => b == .none,
            .entry => |a_index| switch (b) {
                .entry => |b_index| a_index == b_index,
                else => false,
            },
        };
    }

    pub fn step(
        self: Here,
        down: bool,
        entry_count: usize,
    ) Here {
        if (entry_count == 0) return .none;
        return switch (self) {
            .none => fromEntryCount(entry_count, 0),
            .entry => |index| if (down)
                fromEntryCount(entry_count, index +| 1)
            else
                fromEntryCount(entry_count, index -| 1),
        };
    }

    pub fn halfPage(
        self: Here,
        down: bool,
        entry_count: usize,
        distance: usize,
    ) Here {
        if (entry_count == 0 or self == .none) return self;
        const current = self.entry;
        const target = if (down)
            @min(current +| @max(distance, 1), entry_count - 1)
        else
            current -| @max(distance, 1);
        return .{ .entry = target };
    }

    pub fn jump(entry_count: usize, bottom: bool) Here {
        if (entry_count == 0) return .none;
        return .{ .entry = if (bottom) entry_count - 1 else 0 };
    }
};

test "one-step transitions include none" {
    const testing = std.testing;
    const Case = struct {
        start: Here,
        down: bool,
        count: usize,
        expected: Here,
    };
    const cases = [_]Case{
        .{ .start = .none, .down = false, .count = 0, .expected = .none },
        .{ .start = .none, .down = true, .count = 0, .expected = .none },
        .{ .start = .{ .entry = 0 }, .down = false, .count = 3, .expected = .{ .entry = 0 } },
        .{ .start = .{ .entry = 1 }, .down = false, .count = 3, .expected = .{ .entry = 0 } },
        .{ .start = .{ .entry = 1 }, .down = true, .count = 3, .expected = .{ .entry = 2 } },
        .{ .start = .{ .entry = 2 }, .down = true, .count = 3, .expected = .{ .entry = 2 } },
    };
    for (cases) |case| {
        try testing.expectEqual(case.expected, case.start.step(case.down, case.count));
    }
}

test "half-page and jump transitions saturate" {
    const testing = std.testing;
    try testing.expectEqual(Here{ .entry = 7 }, (Here{ .entry = 4 }).halfPage(
        true,
        8,
        3,
    ));
    try testing.expectEqual(Here{ .entry = 1 }, (Here{ .entry = 4 }).halfPage(
        false,
        8,
        3,
    ));
    try testing.expectEqual(Here{ .entry = 0 }, Here.jump(8, false));
    try testing.expectEqual(Here{ .entry = 7 }, Here.jump(8, true));
    try testing.expectEqual(Here.none, Here.jump(0, true));
}

test "cursor equality distinguishes tags and entry indices" {
    const testing = std.testing;

    try testing.expect(@as(Here, .none).eql(.none));
    try testing.expect(!@as(Here, .none).eql(.{ .entry = 0 }));
    try testing.expect((Here{ .entry = 0 }).eql(.{ .entry = 0 }));
    try testing.expect(!(Here{ .entry = 0 }).eql(.{ .entry = 1 }));
}
