// SPDX-License-Identifier: MIT
//! Names: the name servers the stack asks, the cache of what they
//! answered, and the buffer an opener's answers are written into.

const sdk = @import("sdk");
const builtin = @import("builtin");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const hosts = @import("hosts.zig");
const Address = @import("../ip6/address.zig").Address;
const dos = sdk.dos;
const _lock = @import("../lock/_lock.zig");
const SocketBase = _base.SocketBase;
const DosBase = sdk.interface.dos.DosBase;

/// Whether `name` may be the machine's name: 1 to 63 letters, digits and
/// hyphens, not beginning or ending with a hyphen - a host name as a DNS
/// label and a DHCP server take it.
pub fn validHostName(name: []const u8) bool {
    if (name.len == 0 or name.len > 63) return false;
    if (name[0] == '-' or name[name.len - 1] == '-') return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// The name in a host name file's text: its first line that is neither
/// blank nor a comment ('#'), trimmed; null when there is none, or it is
/// not a valid name.
pub fn hostNameIn(text: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (start < text.len) {
        var end = start;
        while (end < text.len and text[end] != '\n' and text[end] != '\r') end += 1;
        var line = text[start..end];
        while (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) line = line[1..];
        while (line.len > 0 and (line[line.len - 1] == ' ' or line[line.len - 1] == '\t')) line = line[0 .. line.len - 1];
        if (line.len != 0 and line[0] != '#') return if (validHostName(line)) line else null;
        start = end + 1;
    }
    return null;
}

/// The machine's name from `HOSTNAME_FILE`, once: the first time an
/// interface is added or the name asked for, on the caller's task, which
/// has dos.library to read it with. A name SetHostName gave first stays.
pub fn loadHostName(sb: *SocketBase) void {
    const stack = sb.stack;
    // A look before the file is read; whether it is set is decided again
    // under the stack's lock below.
    if (@as(*volatile u32, &stack.hostname_set).* != 0) return;
    var text: [hostname_file_max]u8 = undefined;
    const got = readHostNameFile(stack, &text);
    const held = _lock.take(stack);
    defer _lock.give(stack, held);
    if (stack.hostname_set != 0) return;
    stack.hostname_set = 1;
    const name = hostNameIn(text[0..got]) orelse return;
    setName(stack, name);
}

/// The most of the hostname file read: room for a comment above the name
/// as long as the file's own.
const hostname_file_max = 1024;

/// The hostname file's text into `into`: how many bytes; 0 with no file.
/// Without the stack's lock: it waits for the file.
fn readHostNameFile(stack: *StackBase, into: *[hostname_file_max]u8) usize {
    const sys = stack.sys_base;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return 0;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    const file = dl.Open(bsd.HOSTNAME_FILE, dos.MODE_OLDFILE) orelse return 0;
    defer _ = dl.Close(file);
    const length = dl.Read(file, into, into.len);
    return if (length > 0) @intCast(length) else 0;
}

/// The hostname file changed: its name taken, in the place of the one in
/// force, SetHostName's too. On the stack task, which watches the file. A
/// file gone, or one that names no name, changes nothing.
pub fn reloadHostName(stack: *StackBase) void {
    var text: [hostname_file_max]u8 = undefined;
    const got = readHostNameFile(stack, &text);
    const held = _lock.take(stack);
    defer _lock.give(stack, held);
    takeHostName(stack, text[0..got]);
}

/// The name in a hostname file's `text` in force, if it names one. Under
/// the lock.
pub fn takeHostName(stack: *StackBase, text: []const u8) void {
    const name = hostNameIn(text) orelse return;
    stack.hostname_set = 1;
    setName(stack, name);
}

fn setName(stack: *StackBase, name: []const u8) void {
    @memcpy(stack.hostname[0..name.len], name);
    @memset(stack.hostname[name.len..], 0);
}

/// Names the cache keeps, and for how long at the least and the most.
pub const cache_max = 32;
pub const ttl_min_us: u64 = 30_000_000;
pub const ttl_max_us: u64 = 3_600_000_000;
pub const addresses_max = 8;

/// A name's addresses of one family: IPv4 ones mapped.
pub const CacheEntry = extern struct {
    name: [64]u8 = @splat(0),
    addresses: [addresses_max]Address = @splat(.{}),
    count: u32 = 0,
    /// AF_INET or AF_INET6.
    family: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
    expires: u64 align(4) = 0,
};

pub const Cache = extern struct {
    entries: [cache_max]CacheEntry = @splat(.{}),
    /// For DNS ids on the host, where there is no generator.
    random_state: u32 = 0x9E37_79B9,
};

/// The addresses of `family` `name` had when it was last looked up,
/// while they are still good. Under the lock.
pub fn cached(stack: *StackBase, name: []const u8, family: u8, now: u64, into: *[addresses_max]Address) usize {
    for (&stack.names.entries) |*entry| {
        if (entry.count == 0 or entry.expires <= now or entry.family != family) continue;
        if (!hosts.same(entryName(entry), name)) continue;
        into.* = entry.addresses;
        return entry.count;
    }
    return 0;
}

/// A name's addresses of `family` kept for `ttl_s` seconds, held to
/// 30 s .. 1 h; the entry closest to its end makes room. Under the lock.
pub fn remember(stack: *StackBase, name: []const u8, family: u8, addresses: []const Address, ttl_s: u32, now: u64) void {
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
    slot.family = family;
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
    addresses: [addresses_max][16]u8 = @splat(@splat(0)),
    list: [addresses_max + 1]?[*]u8 = @splat(null),

    /// The buffer filled with `name` and `addresses`, IPv4 ones mapped,
    /// as a hostent of `family`: AF_INET's four bytes an address, or
    /// AF_INET6's sixteen.
    pub fn fill(buffer: *HostBuffer, name: []const u8, addresses: []const Address, family: u8) *bsd.hostent {
        const length = @min(name.len, buffer.name.len - 1);
        @memcpy(buffer.name[0..length], name[0..length]);
        buffer.name[length] = 0;
        const count = @min(addresses.len, addresses_max);
        for (addresses[0..count], 0..) |address, index| {
            if (family == bsd.AF_INET) {
                buffer.addresses[index][0..4].* = address.bytes[12..16].*;
            } else {
                buffer.addresses[index] = address.bytes;
            }
            buffer.list[index] = &buffer.addresses[index];
        }
        buffer.list[count] = null;
        buffer.aliases[0] = null;
        buffer.entry = .{
            .h_name = @ptrCast(&buffer.name),
            .h_aliases = &buffer.aliases,
            .h_addrtype = family,
            .h_length = if (family == bsd.AF_INET) 4 else 16,
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

/// A name server added, of either family, if it is not there already;
/// false when the list is full. Under the lock.
pub fn addServer(stack: *StackBase, address: Address) bool {
    if (address.isUnspecified()) return false;
    for (stack.nameservers[0..stack.nameserver_count]) |server| {
        if (server.eql(address)) return true;
    }
    if (stack.nameserver_count == bsd.NAMESERVERS_MAX) return false;
    stack.nameservers[stack.nameserver_count] = address;
    stack.nameserver_count += 1;
    return true;
}

/// A name server taken off the list; false if it was not on it. Under
/// the lock.
pub fn removeServer(stack: *StackBase, address: Address) bool {
    const count = stack.nameserver_count;
    for (stack.nameservers[0..count], 0..) |server, index| {
        if (!server.eql(address)) continue;
        var at = index;
        while (at + 1 < count) : (at += 1) stack.nameservers[at] = stack.nameservers[at + 1];
        stack.nameserver_count -= 1;
        return true;
    }
    return false;
}
