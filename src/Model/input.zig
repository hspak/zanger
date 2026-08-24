//! Pure key-to-action policy shared by vxfw capture and bubble adapters.

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

    pub const Phase = enum { capture, bubble };

    pub fn phase(self: BrowseAction) Phase {
        return switch (self) {
            .half_page_down, .half_page_up, .move_down, .move_up => .capture,
            else => .bubble,
        };
    }

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

test "browse keys map once to capture or bubble actions" {
    const testing = std.testing;
    const Case = struct {
        key: Key,
        action: BrowseAction,
        phase: BrowseAction.Phase,
    };
    const cases = [_]Case{
        .{ .key = .{ .codepoint = 'd', .mods = .{ .ctrl = true } }, .action = .half_page_down, .phase = .capture },
        .{ .key = .{ .codepoint = 'u', .mods = .{ .ctrl = true } }, .action = .half_page_up, .phase = .capture },
        .{ .key = .{ .codepoint = 'j' }, .action = .move_down, .phase = .capture },
        .{ .key = .{ .codepoint = Key.up }, .action = .move_up, .phase = .capture },
        .{ .key = .{ .codepoint = 'h', .mods = .{ .ctrl = true } }, .action = .toggle_hidden, .phase = .bubble },
        .{ .key = .{ .codepoint = Key.enter }, .action = .open, .phase = .bubble },
        .{ .key = .{ .codepoint = Key.backspace }, .action = .ascend, .phase = .bubble },
        .{ .key = .{ .codepoint = 'g' }, .action = .jump_first, .phase = .bubble },
        .{ .key = .{ .codepoint = 'G' }, .action = .jump_last, .phase = .bubble },
        .{ .key = .{ .codepoint = Key.space }, .action = .toggle_selection, .phase = .bubble },
        .{ .key = .{ .codepoint = Key.tab, .mods = .{ .shift = true } }, .action = .absorb_tab, .phase = .bubble },
        .{ .key = .{ .codepoint = ':' }, .action = .command, .phase = .bubble },
        .{ .key = .{ .codepoint = 'q' }, .action = .quit, .phase = .bubble },
    };
    for (cases) |case| {
        const action = browseAction(case.key).?;
        try testing.expectEqual(case.action, action);
        try testing.expectEqual(case.phase, action.phase());
    }
    try testing.expect(browseAction(.{ .codepoint = 'x' }) == null);
}
