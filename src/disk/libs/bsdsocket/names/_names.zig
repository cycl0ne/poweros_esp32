// SPDX-License-Identifier: MIT
//! Names: the name servers the stack asks, the cache of what they
//! answered, and the buffer an opener's answers are written into.

const sdk = @import("sdk");
const builtin = @import("builtin");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const hosts = @import("hosts.zig");

/// Names the cache keeps, and for how long at the least and the most.
pub const cache_max = 32;
pub const ttl_min_us: u64 = 30_000_000;
pub const ttl_max_us: u64 = 3_600_000_000;
pub const addresses_max = 8;

pub const CacheEntry = extern struct {
    name: [64]u8 = @splat(0),
    addresses: [addresses_max]u32 = @splat(0),
    count: u32 = 0,
    expires: u64 align(4) = 0,
};

pub const Cache = extern struct {
    entries: [cache_max]CacheEntry = @splat(.{}),
    /// For DNS ids on the host, where there is no generator.
    random_state: u32 = 0x9E37_79B9,
};

/// The addresses `name` had when it was last looked up, while they are
/// still good. Under the lock.
pub fn cached(stack: *StackBase, name: []const u8, now: u64, into: *[addresses_max]u32) usize {
    for (&stack.names.entries) |*entry| {
        if (entry.count == 0 or entry.expires <= now) continue;
        if (!hosts.same(entryName(entry), name)) continue;
        into.* = entry.addresses;
        return entry.count;
    }
    return 0;
}

/// A name's addresses kept for `ttl_s` seconds, held to 30 s .. 1 h; the
/// entry closest to its end makes room. Under the lock.
pub fn remember(stack: *StackBase, name: []const u8, addresses: []const u32, ttl_s: u32, now: u64) void {
    if (name.len >= 64 or addresses.len == 0) return;
    var slot: *CacheEntry = &stack.names.entries[0];
    for (&stack.names.entries) |*entry| {
        if (entry.count == 0 or entry.expires <= now) {
            slot = entry;
            break;
        }
        if (entry.expires < slot.expires) slot = entry;
    }
    slot.* = .{};
    @memcpy(slot.name[0..name.len], name);
    const count = @min(addresses.len, addresses_max);
    @memcpy(slot.addresses[0..count], addresses[0..count]);
    slot.count = @intCast(count);
    const ttl = @max(ttl_min_us, @min(@as(u64, ttl_s) * 1_000_000, ttl_max_us));
    slot.expires = now + ttl;
}

/// 16 random bits: a DNS id.
pub fn random16(stack: *StackBase) u16 {
    if (builtin.cpu.arch == .xtensa) return @truncate(sdk.hardware.rng.read());
    const state = &stack.names.random_state;
    state.* ^= state.* << 13;
    state.* ^= state.* >> 17;
    state.* ^= state.* << 5;
    return @truncate(state.*);
}

/// What GetHostByName and GetHostByAddr answer: a hostent and what it
/// points at, in the opener's base.
pub const HostBuffer = extern struct {
    entry: bsd.hostent = .{},
    name: [256]u8 = @splat(0),
    aliases: [1]?[*:0]u8 = .{null},
    addresses: [addresses_max][4]u8 = @splat(@splat(0)),
    list: [addresses_max + 1]?[*]u8 = @splat(null),

    /// The buffer filled with `name` and `addresses`: the hostent.
    pub fn fill(buffer: *HostBuffer, name: []const u8, addresses: []const u32) *bsd.hostent {
        const length = @min(name.len, buffer.name.len - 1);
        @memcpy(buffer.name[0..length], name[0..length]);
        buffer.name[length] = 0;
        const count = @min(addresses.len, addresses_max);
        for (addresses[0..count], 0..) |address, index| {
            buffer.addresses[index] = @bitCast(address);
            buffer.list[index] = &buffer.addresses[index];
        }
        buffer.list[count] = null;
        buffer.aliases[0] = null;
        buffer.entry = .{
            .h_name = @ptrCast(&buffer.name),
            .h_aliases = &buffer.aliases,
            .h_addr_list = &buffer.list,
        };
        return &buffer.entry;
    }
};

fn entryName(entry: *const CacheEntry) []const u8 {
    var length: usize = 0;
    while (length < entry.name.len and entry.name[length] != 0) length += 1;
    return entry.name[0..length];
}

/// A name server added, if it is not there already; false when the list
/// is full. Under the lock.
pub fn addServer(stack: *StackBase, address: u32) bool {
    if (address == 0) return false;
    for (stack.nameservers[0..stack.nameserver_count]) |server| {
        if (server == address) return true;
    }
    if (stack.nameserver_count == bsd.NAMESERVERS_MAX) return false;
    stack.nameservers[stack.nameserver_count] = address;
    stack.nameserver_count += 1;
    return true;
}

/// A name server taken off the list; false if it was not on it. Under
/// the lock.
pub fn removeServer(stack: *StackBase, address: u32) bool {
    const count = stack.nameserver_count;
    for (stack.nameservers[0..count], 0..) |server, index| {
        if (server != address) continue;
        var at = index;
        while (at + 1 < count) : (at += 1) stack.nameservers[at] = stack.nameservers[at + 1];
        stack.nameserver_count -= 1;
        return true;
    }
    return false;
}
