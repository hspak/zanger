//! Transactional watcher for Zanger's active HERE directory.
//!
//! The model owns this platform-neutral facade. Backends may use different
//! kernel objects, but all of them prepare, commit, and cancel watches without
//! exposing those objects to navigation transactions.

const Watcher = @This();

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Backend = switch (builtin.os.tag) {
    .linux => @import("Watcher/Linux.zig"),
    .macos => @import("Watcher/Macos.zig"),
    else => @compileError("Zanger supports only Linux and macOS"),
};

const test_support = @import("test_support.zig");

backend: Backend,

pub const InitError = Backend.InitError;
pub const ArmError = Backend.ArmError;
pub const DrainError = Backend.DrainError;
pub const Pending = Backend.Pending;
pub const Refresh = Backend.Refresh;
const reports_child_names = Backend.reports_child_names;

/// Initializes the native event queue with no current directory watch.
pub fn init(io: Io) InitError!Watcher {
    return .{ .backend = try Backend.init(io) };
}

/// Releases the current watch and native event queue, then poisons `self`.
pub fn deinit(self: *Watcher) void {
    self.backend.deinit();
    self.* = undefined;
}

/// Prepares a watch without changing the current watch. Call `commit` after
/// the pane transaction succeeds or `cancel` on rollback.
pub fn prepare(self: *Watcher, path: []const u8) ArmError!Pending {
    return self.backend.prepare(path);
}

/// Makes `pending` current and retires the previous watch.
pub fn commit(self: *Watcher, pending: Pending) void {
    self.backend.commit(pending);
}

/// Retires a prepared watch after its pane transaction fails.
pub fn cancel(self: *Watcher, pending: Pending) void {
    self.backend.cancel(pending);
}

/// Whether a HERE directory watch is currently active.
pub fn hasCurrent(self: *const Watcher) bool {
    return self.backend.hasCurrent();
}

/// Stable only until the next successful commit. Intended for invariant and
/// rollback tests; callers must not interpret the platform-specific value.
pub fn currentId(self: *const Watcher) ?usize {
    return self.backend.currentId();
}

/// Drains pending kernel notifications and reduces them to the strongest
/// refresh action required.
pub fn drain(self: *Watcher, show_hidden: bool) DrainError!Refresh {
    return self.backend.drain(show_hidden);
}

test "reports changes only for the current directory" {
    const testing = std.testing;
    var first = try test_support.TempTree.init(testing.allocator, testing.io);
    defer first.deinit();
    var second = try test_support.TempTree.init(testing.allocator, testing.io);
    defer second.deinit();

    var watcher = try Watcher.init(testing.io);
    defer watcher.deinit();
    watcher.commit(try watcher.prepare(first.path));
    try first.writeFile("first.txt", "first");
    try testing.expectEqual(Refresh.content, try watcher.drain(true));
    try testing.expectEqual(Refresh.none, try watcher.drain(true));

    watcher.commit(try watcher.prepare(second.path));
    try first.writeFile("retired.txt", "retired");
    try second.writeFile("second.txt", "second");
    try testing.expectEqual(Refresh.content, try watcher.drain(true));
}

test "clears a watch invalidated by directory deletion" {
    const testing = std.testing;
    var tree = try test_support.TempTree.init(testing.allocator, testing.io);
    defer tree.deinit();
    try tree.createDir("watched");

    const watched_path = try tree.absolutePath("watched");
    defer testing.allocator.free(watched_path);

    var watcher = try Watcher.init(testing.io);
    defer watcher.deinit();
    watcher.commit(try watcher.prepare(watched_path));
    try Io.Dir.deleteDir(tree.temp.dir, testing.io, "watched");

    try testing.expectEqual(Refresh.rearm, try watcher.drain(true));
    try testing.expect(!watcher.hasCurrent());
}

test "clears a watch invalidated by directory rename" {
    const testing = std.testing;
    var tree = try test_support.TempTree.init(testing.allocator, testing.io);
    defer tree.deinit();
    try tree.createDir("watched");

    const watched_path = try tree.absolutePath("watched");
    defer testing.allocator.free(watched_path);

    var watcher = try Watcher.init(testing.io);
    defer watcher.deinit();
    watcher.commit(try watcher.prepare(watched_path));
    try Io.Dir.rename(tree.temp.dir, "watched", tree.temp.dir, "renamed", testing.io);

    try testing.expectEqual(Refresh.rearm, try watcher.drain(true));
    try testing.expect(!watcher.hasCurrent());
}

test "ignores hidden entry changes when hidden files are excluded" {
    const testing = std.testing;
    var tree = try test_support.TempTree.init(testing.allocator, testing.io);
    defer tree.deinit();

    var watcher = try Watcher.init(testing.io);
    defer watcher.deinit();
    watcher.commit(try watcher.prepare(tree.path));

    try tree.writeFile(".hidden", "hidden");
    const hidden_refresh: Refresh = if (reports_child_names) .none else .content;
    try testing.expectEqual(hidden_refresh, try watcher.drain(false));

    try tree.writeFile("visible", "visible");
    try testing.expectEqual(Refresh.content, try watcher.drain(false));
}
