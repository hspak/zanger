//! Caches numeric UID/GID to name resolution. NSS lookups may consult
//! services outside local files, so results are cached for the process
//! lifetime; cached strings are owned by this cache.

const std = @import("std");
const Allocator = std.mem.Allocator;

const IdentityCache = @This();

users: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
groups: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,

pub fn deinit(self: *IdentityCache, alloc: Allocator) void {
    var users = self.users.valueIterator();
    while (users.next()) |name| alloc.free(name.*);
    self.users.deinit(alloc);
    var groups = self.groups.valueIterator();
    while (groups.next()) |name| alloc.free(name.*);
    self.groups.deinit(alloc);
    self.* = undefined;
}

/// Returns the cached or newly resolved account name for `uid`. Falls back to
/// the decimal UID when no account resolves. The returned slice borrows the
/// cache and stays valid until `deinit`.
pub fn userName(self: *IdentityCache, alloc: Allocator, uid: u32) Allocator.Error![]const u8 {
    if (self.users.get(uid)) |name| return name;
    const name = try lookupUserName(alloc, uid);
    errdefer alloc.free(name);
    try self.users.putNoClobber(alloc, uid, name);
    return name;
}

/// Returns the cached or newly resolved group name for `gid`. Falls back to
/// the decimal GID when no group resolves. The returned slice borrows the
/// cache and stays valid until `deinit`.
pub fn groupName(self: *IdentityCache, alloc: Allocator, gid: u32) Allocator.Error![]const u8 {
    if (self.groups.get(gid)) |name| return name;
    const name = try lookupGroupName(alloc, gid);
    errdefer alloc.free(name);
    try self.groups.putNoClobber(alloc, gid, name);
    return name;
}

fn lookupUserName(alloc: Allocator, uid: u32) Allocator.Error![]const u8 {
    var record: std.c.passwd = undefined;
    var result: ?*std.c.passwd = null;
    var buffer: [16 * 1024]u8 = undefined;
    const rc = std.c.getpwuid_r(
        @intCast(uid),
        &record,
        &buffer,
        buffer.len,
        &result,
    );
    if (rc == 0 and result != null) {
        if (result.?.name) |name| return alloc.dupe(u8, std.mem.span(name));
    }
    return std.fmt.allocPrint(alloc, "{d}", .{uid});
}

fn lookupGroupName(alloc: Allocator, gid: u32) Allocator.Error![]const u8 {
    var record: std.c.group = undefined;
    var result: ?*std.c.group = null;
    var buffer: [16 * 1024]u8 = undefined;
    const rc = std.c.getgrgid_r(
        @intCast(gid),
        &record,
        &buffer,
        buffer.len,
        &result,
    );
    if (rc == 0 and result != null) {
        if (result.?.name) |name| return alloc.dupe(u8, std.mem.span(name));
    }
    return std.fmt.allocPrint(alloc, "{d}", .{gid});
}
