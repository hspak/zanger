//! Parses the navigator's colon-command language into closed command values.

const std = @import("std");

/// A validated command accepted by the navigator.
pub const Command = enum {
    help,
    hidden,
    delete,
    quit,
};

const CommandSpec = struct {
    name: []const u8,
    command: Command,
};

const command_specs = [_]CommandSpec{
    .{ .name = "help", .command = .help },
    .{ .name = "hidden", .command = .hidden },
    .{ .name = "delete", .command = .delete },
    .{ .name = "quit", .command = .quit },
};

/// Errors returned when command text is absent or invalid.
pub const ParseError = error{
    Empty,
    UnknownCommand,
    InvalidArguments,
};

fn matchingCommand(name: []const u8) ?usize {
    if (name.len == 0) return null;

    var match: ?usize = null;
    for (command_specs, 0..) |spec, index| {
        if (!std.mem.startsWith(u8, spec.name, name)) continue;
        if (match != null) return null;
        match = index;
    }
    return match;
}

/// Returns the full command name for a strict, unique prefix. Exact command
/// names, ambiguous prefixes, and input containing arguments have no hint.
pub fn suggestion(input: []const u8) ?[]const u8 {
    var text = std.mem.trim(u8, input, " \t\r\n");
    if (text.len > 0 and text[0] == ':') {
        text = std.mem.trimStart(u8, text[1..], " \t");
    }
    if (std.mem.indexOfAny(u8, text, " \t\r\n") != null) return null;

    const spec = command_specs[matchingCommand(text) orelse return null];
    if (std.mem.eql(u8, text, spec.name)) return null;
    return spec.name;
}

/// Parses the contents of the command field. A leading `:` is accepted so the
/// parser is also convenient outside the UI.
pub fn parse(input: []const u8) ParseError!Command {
    var text = std.mem.trim(u8, input, " \t\r\n");
    if (text.len > 0 and text[0] == ':') {
        text = std.mem.trimStart(u8, text[1..], " \t");
    }

    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const name = words.next() orelse return error.Empty;
    const spec = command_specs[matchingCommand(name) orelse return error.UnknownCommand];
    if (words.next() != null) return error.InvalidArguments;
    return spec.command;
}

test "parse commands" {
    const testing = std.testing;

    try testing.expectEqual(Command.help, try parse("help"));
    try testing.expectEqual(Command.help, try parse(" :help  "));
    try testing.expectEqual(Command.help, try parse("he"));
    try testing.expectEqual(Command.delete, try parse("delete"));
    try testing.expectEqual(Command.delete, try parse(":d"));
    try testing.expectEqual(Command.delete, try parse("dele"));
    try testing.expectEqual(Command.quit, try parse("quit"));
    try testing.expectEqual(Command.quit, try parse("q"));
    try testing.expectEqual(Command.hidden, try parse("hidden"));
    try testing.expectEqual(Command.hidden, try parse(":hi"));
}

test "suggest unique command completions" {
    const testing = std.testing;

    try testing.expectEqualStrings("delete", suggestion("d").?);
    try testing.expectEqualStrings("delete", suggestion(":dele").?);
    try testing.expectEqualStrings("help", suggestion("he").?);
    try testing.expectEqualStrings("hidden", suggestion("hi").?);
    try testing.expectEqualStrings("quit", suggestion("q").?);
    try testing.expect(suggestion("h") == null);
    try testing.expect(suggestion("delete") == null);
    try testing.expect(suggestion("delete now") == null);
    try testing.expect(suggestion("wat") == null);
}

test "reject invalid commands" {
    const testing = std.testing;

    try testing.expectError(error.Empty, parse("  "));
    try testing.expectError(error.UnknownCommand, parse("wat"));
    try testing.expectError(error.UnknownCommand, parse("h"));
    try testing.expectError(error.InvalidArguments, parse("help now"));
    try testing.expectError(error.InvalidArguments, parse("d now"));
    try testing.expectError(error.InvalidArguments, parse("hidden on"));
    try testing.expectError(error.InvalidArguments, parse(":hi off"));
}
