//! Pure key-to-action policy for the model's capture adapter.

const std = @import("std");
const vaxis = @import("vaxis");
const Key = vaxis.Key;

pub const BrowseAction = enum {
    half_page_down,
    half_page_up,
    move_down,
    move_up,
    toggle_hidden,
    open,
    ascend,
    jump_first,
    jump_last,
    toggle_selection,
    absorb_tab,
    command,
    quit,

    pub fn errorLabel(self: BrowseAction) []const u8 {
        return switch (self) {
            .half_page_down, .half_page_up => "half-page",
            .move_down, .move_up => "move",
            .toggle_hidden => "hidden",
            .open => "open",
            .ascend => "up",
            .jump_first, .jump_last => "jump",
            .toggle_selection => "select",
            .command => "command",
            .absorb_tab, .quit => "input",
        };
    }
};

pub fn browseAction(key: Key) ?BrowseAction {
    if (key.matches('d', .{ .ctrl = true })) return .half_page_down;
    if (key.matches('u', .{ .ctrl = true })) return .half_page_up;
    if (key.matches('j', .{}) or
        key.matches('n', .{ .ctrl = true }) or
        key.matches(Key.down, .{})) return .move_down;
    if (key.matches('k', .{}) or
        key.matches('p', .{ .ctrl = true }) or
        key.matches(Key.up, .{})) return .move_up;
    if (key.matches('h', .{ .ctrl = true })) return .toggle_hidden;
    if (key.matches(Key.enter, .{}) or key.matches('l', .{})) return .open;
    if (key.matches('h', .{}) or key.matches(Key.backspace, .{})) return .ascend;
    if (key.matches('g', .{})) return .jump_first;
    if (key.matches('g', .{ .shift = true }) or key.matches('G', .{})) return .jump_last;
    if (key.matches(Key.space, .{})) return .toggle_selection;
    if (key.matches(Key.tab, .{ .shift = true }) or
        key.matches(Key.tab, .{})) return .absorb_tab;
    if (key.matches(':', .{})) return .command;
    if (key.matches('q', .{})) return .quit;
    return null;
}

test "browse keys map to model actions" {
    const testing = std.testing;
    const Case = struct {
        key: Key,
        action: BrowseAction,
    };
    const cases = [_]Case{
        .{ .key = .{ .codepoint = 'd', .mods = .{ .ctrl = true } }, .action = .half_page_down },
        .{ .key = .{ .codepoint = 'u', .mods = .{ .ctrl = true } }, .action = .half_page_up },
        .{ .key = .{ .codepoint = 'j' }, .action = .move_down },
        .{ .key = .{ .codepoint = Key.up }, .action = .move_up },
        .{ .key = .{ .codepoint = 'h', .mods = .{ .ctrl = true } }, .action = .toggle_hidden },
        .{ .key = .{ .codepoint = Key.enter }, .action = .open },
        .{ .key = .{ .codepoint = Key.backspace }, .action = .ascend },
        .{ .key = .{ .codepoint = 'g' }, .action = .jump_first },
        .{ .key = .{ .codepoint = 'G' }, .action = .jump_last },
        .{ .key = .{ .codepoint = Key.space }, .action = .toggle_selection },
        .{ .key = .{ .codepoint = Key.tab, .mods = .{ .shift = true } }, .action = .absorb_tab },
        .{ .key = .{ .codepoint = ':' }, .action = .command },
        .{ .key = .{ .codepoint = 'q' }, .action = .quit },
    };
    for (cases) |case| {
        const action = browseAction(case.key).?;
        try testing.expectEqual(case.action, action);
    }
    try testing.expect(browseAction(.{ .codepoint = 'x' }) == null);
}
