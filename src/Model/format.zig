//! Formats metadata values into display strings and permission bits. Every
//! function is pure apart from allocation through the caller's allocator.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const zeit = @import("zeit");

/// Renders the ten-character `ls`-style permission string for a file kind
/// and raw mode word, including setuid/setgid/sticky characters.
pub fn modeBits(kind: Io.File.Kind, mode: u32) [10]u8 {
    return .{
        kindCharacter(kind),
        permissionCharacter(mode, 0o400, 'r'),
        permissionCharacter(mode, 0o200, 'w'),
        executeCharacter(mode, 0o100, 0o4000, 's', 'S'),
        permissionCharacter(mode, 0o040, 'r'),
        permissionCharacter(mode, 0o020, 'w'),
        executeCharacter(mode, 0o010, 0o2000, 's', 'S'),
        permissionCharacter(mode, 0o004, 'r'),
        permissionCharacter(mode, 0o002, 'w'),
        executeCharacter(mode, 0o001, 0o1000, 't', 'T'),
    };
}

fn kindCharacter(kind: Io.File.Kind) u8 {
    return switch (kind) {
        .file => '-',
        .directory => 'd',
        .sym_link => 'l',
        .block_device => 'b',
        .character_device => 'c',
        .named_pipe => 'p',
        .unix_domain_socket => 's',
        .whiteout => 'w',
        .door => 'D',
        .event_port => 'P',
        .unknown => '?',
    };
}

fn permissionCharacter(mode: u32, mask: u32, allowed: u8) u8 {
    return if (mode & mask != 0) allowed else '-';
}

fn executeCharacter(
    mode: u32,
    execute_mask: u32,
    special_mask: u32,
    special_execute: u8,
    special_no_execute: u8,
) u8 {
    if (mode & special_mask != 0) {
        return if (mode & execute_mask != 0) special_execute else special_no_execute;
    }
    return permissionCharacter(mode, execute_mask, 'x');
}

/// Formats `size` like `ls`: plain bytes below 1024, otherwise a mantissa
/// with one decimal that collapses to an integer at three digits.
pub fn humanSize(alloc: Allocator, size: u64) Allocator.Error![]const u8 {
    if (size < 1024) return std.fmt.allocPrint(alloc, "{d}", .{size});

    const suffixes = "KMGTPE";
    var suffix_index: usize = 0;
    var divisor: u64 = 1024;
    while (suffix_index + 1 < suffixes.len and size >= divisor * 1024) {
        divisor *= 1024;
        suffix_index += 1;
    }

    const tenths: u128 = (@as(u128, size) * 10 + divisor / 2) / divisor;
    if (tenths < 100) {
        return std.fmt.allocPrint(alloc, "{d}.{d}{c}", .{
            tenths / 10,
            tenths % 10,
            suffixes[suffix_index],
        });
    }
    return std.fmt.allocPrint(alloc, "{d}{c}", .{
        (tenths + 5) / 10,
        suffixes[suffix_index],
    });
}

/// Renders an `ls`-style local timestamp such as `Dec 31 16:00`. Out-of-range
/// timestamps fall back to printing raw epoch seconds.
pub fn statusTime(
    alloc: Allocator,
    timestamp: Io.Timestamp,
    time_zone: *const zeit.TimeZone,
) Allocator.Error![]const u8 {
    const seconds = @divFloor(timestamp.nanoseconds, std.time.ns_per_s);
    if (std.math.cast(zeit.Seconds, seconds) == null or
        std.math.cast(zeit.Days, @divFloor(seconds, std.time.s_per_day)) == null)
    {
        return std.fmt.allocPrint(alloc, "{d}", .{seconds});
    }

    const local = zeit.instant(.{ .unix_nano = timestamp.nanoseconds }, time_zone).time();
    return std.fmt.allocPrint(alloc, "{s} {d: >2} {d:0>2}:{d:0>2}", .{
        local.month.shortName(),
        local.day,
        local.hour,
        local.minute,
    });
}

test "mode formatter includes special execute bits" {
    const testing = std.testing;
    const bits = modeBits(.file, 0o7644);
    try testing.expectEqualStrings("-rwSr-Sr-T", &bits);
}

test "status size formatter uses ls-like units" {
    const testing = std.testing;
    const bytes = try humanSize(testing.allocator, 999);
    defer testing.allocator.free(bytes);
    const kibibytes = try humanSize(testing.allocator, 4096);
    defer testing.allocator.free(kibibytes);

    try testing.expectEqualStrings("999", bytes);
    try testing.expectEqualStrings("4.0K", kibibytes);
}

test "status timestamp omits signs from positive fields" {
    const testing = std.testing;
    const rendered = try statusTime(testing.allocator, .{
        .nanoseconds = 1_700_000_000 * std.time.ns_per_s,
    }, &zeit.utc);
    defer testing.allocator.free(rendered);

    try testing.expect(std.mem.indexOfScalar(u8, rendered, '+') == null);
}

test "status timestamp uses the supplied time zone" {
    const testing = std.testing;
    const fixed: zeit.TimeZone = .{ .fixed = .{
        .name = "UTC-8",
        .offset = -8 * std.time.s_per_hour,
        .is_dst = false,
    } };
    const rendered = try statusTime(testing.allocator, .zero, &fixed);
    defer testing.allocator.free(rendered);

    try testing.expectEqualStrings("Dec 31 16:00", rendered);
}
