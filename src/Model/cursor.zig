//! Pure HERE cursor states and transitions. The vxfw cursor is an applied
//! projection of this logical value, not an additional source of truth.

const std = @import("std");

pub const Here = union(enum) {
    /// HERE has no entries and `..` is not selected.
    none,
    /// The pinned `..` row is selected. The optional entry remembers which
    /// real row to restore when a mouse click selected `..` away from row zero.
    up: ?usize,
    entry: usize,

    pub fn fromEntryCount(entry_count: usize, index: usize) Here {
        if (entry_count == 0) return .none;
        return .{ .entry = @min(index, entry_count - 1) };
    }

    pub fn selectedEntry(self: Here) ?usize {
        return switch (self) {
            .none, .up => null,
            .entry => |index| index,
        };
    }

    pub fn rememberedEntry(self: Here) ?usize {
        return switch (self) {
            .none => null,
            .up => |index| index,
            .entry => |index| index,
        };
    }

    pub fn isUp(self: Here) bool {
        return self == .up;
    }

    pub fn eql(a: Here, b: Here) bool {
        return switch (a) {
            .none => b == .none,
            .up => |a_index| switch (b) {
                .up => |b_index| a_index == b_index,
                else => false,
            },
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
        shows_up: bool,
    ) Here {
        if (entry_count == 0) {
            if (!down and shows_up) return .{ .up = null };
            return .none;
        }
        return switch (self) {
            .none => if (!down and shows_up)
                .{ .up = null }
            else
                fromEntryCount(entry_count, 0),
            .up => |remembered| if (down)
                fromEntryCount(entry_count, remembered orelse 0)
            else
                self,
            .entry => |index| if (down)
                fromEntryCount(entry_count, index +| 1)
            else if (index == 0 and shows_up)
                .{ .up = 0 }
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
        const current = switch (self) {
            .none => unreachable,
            .up => |remembered| up: {
                if (!down) return self;
                break :up remembered orelse 0;
            },
            .entry => |index| index,
        };
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

test "one-step transitions include none and the pinned up row" {
    const testing = std.testing;
    const Case = struct {
        start: Here,
        down: bool,
        count: usize,
        shows_up: bool,
        expected: Here,
    };
    const cases = [_]Case{
        .{ .start = .none, .down = false, .count = 0, .shows_up = true, .expected = .{ .up = null } },
        .{ .start = .{ .up = null }, .down = true, .count = 0, .shows_up = true, .expected = .none },
        .{ .start = .{ .entry = 0 }, .down = false, .count = 3, .shows_up = true, .expected = .{ .up = 0 } },
        .{ .start = .{ .up = 2 }, .down = true, .count = 3, .shows_up = true, .expected = .{ .entry = 2 } },
        .{ .start = .{ .up = 2 }, .down = false, .count = 3, .shows_up = true, .expected = .{ .up = 2 } },
        .{ .start = .{ .entry = 0 }, .down = false, .count = 3, .shows_up = false, .expected = .{ .entry = 0 } },
        .{ .start = .{ .entry = 1 }, .down = false, .count = 3, .shows_up = true, .expected = .{ .entry = 0 } },
        .{ .start = .{ .entry = 1 }, .down = true, .count = 3, .shows_up = true, .expected = .{ .entry = 2 } },
        .{ .start = .{ .entry = 2 }, .down = true, .count = 3, .shows_up = true, .expected = .{ .entry = 2 } },
    };
    for (cases) |case| {
        try testing.expect(case.expected.eql(case.start.step(
            case.down,
            case.count,
            case.shows_up,
        )));
    }
}

test "half-page and jump transitions saturate" {
    const testing = std.testing;
    try testing.expect((Here{ .entry = 4 }).halfPage(true, 8, 3).eql(.{ .entry = 7 }));
    try testing.expect((Here{ .entry = 4 }).halfPage(false, 8, 3).eql(.{ .entry = 1 }));
    try testing.expect((Here{ .up = 2 }).halfPage(true, 8, 3).eql(.{ .entry = 5 }));
    try testing.expect((Here{ .up = 2 }).halfPage(false, 8, 3).eql(.{ .up = 2 }));
    try testing.expect(Here.jump(8, false).eql(.{ .entry = 0 }));
    try testing.expect(Here.jump(8, true).eql(.{ .entry = 7 }));
    try testing.expect(Here.jump(0, true).eql(.none));
}
