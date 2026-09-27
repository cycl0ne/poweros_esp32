// SPDX-License-Identifier: MIT
//! GetAddrInfo: a host and a service as addresses to connect to or bind,
//! of either family.

const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const StackBase = _base.StackBase;
const _lock = @import("../lock/_lock.zig");
const _netif = @import("../netif/_netif.zig");
const resolver = @import("resolver.zig");
const _names = @import("_names.zig");
const hosts = @import("hosts.zig");
const order = @import("order.zig");
const address_file = @import("../ip6/address.zig");
const Address = address_file.Address;

/// The addresses of `node` for `service`, as a list of `addrinfo`
/// ready for Socket and Connect (or Bind).
///
/// SYNOPSIS:
/// ```zig
/// fn GetAddrInfo(base: *SocketBase, node: ?[*:0]const u8, service: ?[*:0]const u8, hints: ?*const addrinfo, result: *?*addrinfo) i32
/// ```
///
/// SINCE: 1.1. LVO -200.
///
/// INPUTS:
/// - `node` - a name, a dotted IPv4 address, or IPv6 text - a link-local
///   one may carry its interface, `fe80::1%eth0`; null for this machine.
/// - `service` - a port number, or one of the names `ftp`, `ssh`,
///   `telnet`, `smtp`, `domain`, `http`, `ntp`, `https`; null for port 0.
/// - `hints` - null, or an `addrinfo` whose `ai_family` (AF_UNSPEC,
///   AF_INET, AF_INET6), `ai_socktype` (0, SOCK_STREAM, SOCK_DGRAM),
///   `ai_protocol` and `ai_flags` (AI_*) narrow what is wanted; every
///   other field 0.
/// - `result` - where the list goes.
///
/// RESULT:
/// 0 with the list in `*result`, or an EAI_* code with `*result` null:
/// `EAI_NONAME` (no such host, or neither node nor service), `EAI_AGAIN`
/// (no name server answered), `EAI_FAIL` (no name server to ask, or an
/// answer that made no sense), `EAI_FAMILY`, `EAI_SOCKTYPE`,
/// `EAI_SERVICE` (a service with no port for it), `EAI_BADFLAGS`,
/// `EAI_MEMORY`.
///
/// BEHAVIOR:
/// A name is looked up as GetHostByName looks it up - hosts file, cache,
/// DNS - for AAAA and A records as the family asks; IPv4 addresses come
/// as `sockaddr_in`, IPv6 ones as `sockaddr_in6`, and for AF_INET6 with
/// AI_V4MAPPED the IPv4 ones mapped when there are no IPv6 ones (with
/// AI_ALL too, as well as them). Without AI_PASSIVE a null node is the
/// loopback, with it the address that means all of the machine's. With
/// no socket type there is an entry for each of TCP and UDP per address.
/// The addresses come in the order RFC 6724 has for them: the ones there
/// is a route to first, then by scope, the policy table's precedence
/// and the longest prefix shared with the source that would be used.
/// AI_ADDRCONFIG leaves out a family no interface but lo0 has an address
/// of - an IPv6 link-local address does not count.
///
/// CONTEXT:
/// - Waits: yes: for the name servers, as GetHostByName.
/// - Interrupts: no.
/// - Forbid: not held.
/// - Process: a process, to read the hosts file; a Task will do for an
///   address given as text.
///
/// OWNERSHIP:
/// The list is the caller's, one block, given back whole with
/// FreeAddrInfo on its first entry.
///
/// NOTES:
/// The canonical name is the name the lookup found the addresses under -
/// in the stack's domain, for a name without dots that was found there.
///
/// BUGS:
/// No services database: a service is a number or one of the names above.
///
/// SEE ALSO:
/// `FreeAddrInfo`, `GetHostByName`, `Inet_PtoN`
///
/// EXAMPLES:
/// ```zig
/// const hints: bsd.addrinfo = .{ .ai_socktype = bsd.SOCK_STREAM };
/// var list: ?*bsd.addrinfo = null;
/// if (sb.GetAddrInfo("example.org", "80", &hints, &list) != 0) return;
/// defer sb.FreeAddrInfo(list.?);
/// var entry = list;
/// while (entry) |each| : (entry = each.ai_next) {
///     const socket = sb.Socket(each.ai_family, each.ai_socktype, each.ai_protocol);
///     if (socket >= 0 and sb.Connect(socket, each.ai_addr.?, each.ai_addrlen) == 0) break;
/// }
/// ```
pub fn GetAddrInfo(sb: *SocketBase, node: ?[*:0]const u8, service: ?[*:0]const u8, hints: ?*const bsd.addrinfo, result: *?*bsd.addrinfo) i32 {
    result.* = null;
    const wanted: bsd.addrinfo = if (hints) |given| given.* else .{};
    const known_flags = bsd.AI_PASSIVE | bsd.AI_CANONNAME | bsd.AI_NUMERICHOST | bsd.AI_NUMERICSERV | bsd.AI_ALL | bsd.AI_ADDRCONFIG | bsd.AI_V4MAPPED;
    if (wanted.ai_flags & ~known_flags != 0) return bsd.EAI_BADFLAGS;
    const family = wanted.ai_family;
    if (family != bsd.AF_UNSPEC and family != bsd.AF_INET and family != bsd.AF_INET6) return bsd.EAI_FAMILY;
    switch (wanted.ai_socktype) {
        0, bsd.SOCK_STREAM, bsd.SOCK_DGRAM => {},
        else => return bsd.EAI_SOCKTYPE,
    }
    if (node == null and service == null) return bsd.EAI_NONAME;
    const port = if (service) |text| (portOf(text, wanted.ai_flags) orelse return if (wanted.ai_flags & bsd.AI_NUMERICSERV != 0) bsd.EAI_NONAME else bsd.EAI_SERVICE) else 0;

    var found: [2 * _names.addresses_max]order.Candidate = undefined;
    var count: usize = 0;
    var scope: u32 = 0;
    var canonical: resolver.Found = .{};
    const v6 = family != bsd.AF_INET;
    const v4 = family != bsd.AF_INET6;
    if (node) |text| {
        const whole = textOf(text);
        // IPv6 text, perhaps with its interface; then a dotted address.
        var host = whole;
        var zone: ?[]const u8 = null;
        for (whole, 0..) |char, index| {
            if (char == '%') {
                host = whole[0..index];
                zone = whole[index + 1 ..];
                break;
            }
        }
        if (address_file.parse(host)) |literal| {
            if (!v6) return bsd.EAI_NONAME;
            if (zone) |name| scope = interfaceIndex(sb, name) orelse return bsd.EAI_NONAME;
            found[0] = .{ .address = literal };
            count = 1;
            canonical.name_length = @min(whole.len, canonical.name.len - 1);
            @memcpy(canonical.name[0..canonical.name_length], whole[0..canonical.name_length]);
        } else if (hosts.dotted(whole)) |dotted| {
            const address = Address.fromV4(bsd.ntohl(dotted));
            if (!v4 and wanted.ai_flags & bsd.AI_V4MAPPED == 0) return bsd.EAI_NONAME;
            found[0] = .{ .address = address };
            count = 1;
            canonical.name_length = whole.len;
            @memcpy(canonical.name[0..whole.len], whole);
        } else {
            if (wanted.ai_flags & bsd.AI_NUMERICHOST != 0) return bsd.EAI_NONAME;
            var any_v4 = true;
            var any_v6 = true;
            if (wanted.ai_flags & bsd.AI_ADDRCONFIG != 0) configured(sb.stack, &any_v4, &any_v6);
            var failure: i32 = bsd.HOST_NOT_FOUND;
            var looked: resolver.Found = .{};
            if (v6 and any_v6) {
                if (resolver.lookup(sb, whole, bsd.AF_INET6, &looked)) {
                    for (looked.addresses[0..looked.count]) |address| {
                        found[count] = .{ .address = address };
                        count += 1;
                    }
                    canonical = looked;
                } else failure = sb.h_errno;
            }
            const mapped_wanted = family == bsd.AF_INET6 and wanted.ai_flags & bsd.AI_V4MAPPED != 0 and
                (count == 0 or wanted.ai_flags & bsd.AI_ALL != 0);
            if ((v4 or mapped_wanted) and any_v4) {
                if (resolver.lookup(sb, whole, bsd.AF_INET, &looked)) {
                    for (looked.addresses[0..looked.count]) |address| {
                        found[count] = .{ .address = address };
                        count += 1;
                    }
                    if (canonical.name_length == 0) canonical = looked;
                } else if (count == 0) failure = sb.h_errno;
            }
            if (count == 0) return switch (failure) {
                bsd.TRY_AGAIN => bsd.EAI_AGAIN,
                bsd.NO_RECOVERY => bsd.EAI_FAIL,
                else => bsd.EAI_NONAME,
            };
        }
    } else {
        const passive = wanted.ai_flags & bsd.AI_PASSIVE != 0;
        if (v6) {
            found[count] = .{ .address = if (passive) Address.any else Address.loopback };
            count += 1;
        }
        if (v4) {
            found[count] = .{ .address = Address.fromV4(if (passive) 0 else bsd.INADDR_LOOPBACK) };
            count += 1;
        }
    }

    if (count > 1) {
        const held = _lock.take(sb.stack);
        order.prepare(sb.stack, found[0..count]);
        _lock.give(sb.stack, held);
        order.sort(found[0..count]);
    }
    return build(sb, found[0..count], family, port, scope, &wanted, &canonical, result);
}

/// Whether any interface but lo0 has an IPv4 address, and an IPv6 one
/// that is not link-local.
fn configured(stack: *StackBase, v4: *bool, v6: *bool) void {
    v4.* = false;
    v6.* = false;
    const held = _lock.take(stack);
    defer _lock.give(stack, held);
    for (&stack.interfaces) |*interface| {
        if (interface.used == 0 or interface.loopback != 0) continue;
        if (interface.address != 0) v4.* = true;
        for (&interface.ip6.addresses) |*entry| {
            if (entry.usable() and !entry.address.isLinkLocal()) v6.* = true;
        }
    }
}

fn interfaceIndex(sb: *SocketBase, name: []const u8) ?u32 {
    var text: [bsd.IFNAMSIZ]u8 = @splat(0);
    if (name.len == 0 or name.len >= text.len) return null;
    @memcpy(text[0..name.len], name);
    const held = _lock.take(sb.stack);
    defer _lock.give(sb.stack, held);
    const interface = _netif.named(sb.stack, @ptrCast(&text)) orelse return null;
    return _netif.index(sb.stack, interface);
}

fn textOf(text: [*:0]const u8) []const u8 {
    var length: usize = 0;
    while (text[length] != 0 and length < 256) length += 1;
    return text[0..length];
}

const Service = struct { name: []const u8, port: u16 };
const services = [_]Service{
    .{ .name = "ftp", .port = 21 },
    .{ .name = "ssh", .port = 22 },
    .{ .name = "telnet", .port = 23 },
    .{ .name = "smtp", .port = 25 },
    .{ .name = "domain", .port = 53 },
    .{ .name = "http", .port = 80 },
    .{ .name = "ntp", .port = 123 },
    .{ .name = "https", .port = 443 },
};

/// A service's port, in the chip's order: a number, or a name the table
/// knows unless AI_NUMERICSERV; null when it is neither.
fn portOf(text: [*:0]const u8, flags: i32) ?u16 {
    const service = textOf(text);
    if (service.len == 0) return null;
    var value: u32 = 0;
    for (service) |char| {
        if (char < '0' or char > '9') break;
        value = value * 10 + (char - '0');
        if (value > 65535) return null;
    } else return @intCast(value);
    if (flags & bsd.AI_NUMERICSERV != 0) return null;
    for (services) |known| {
        if (hosts.same(known.name, service)) return known.port;
    }
    return null;
}

/// One entry of the list, and room for its address behind it.
const Entry = extern struct {
    info: bsd.addrinfo,
    address: bsd.sockaddr_in6,
};

/// The list made in one block: an entry per address and socket type,
/// the canonical name behind the last.
fn build(sb: *SocketBase, found: []const order.Candidate, family: i32, port: u16, scope: u32, wanted: *const bsd.addrinfo, canonical: *const resolver.Found, result: *?*bsd.addrinfo) i32 {
    const kinds = [_]struct { socktype: i32, protocol: i32 }{
        .{ .socktype = bsd.SOCK_STREAM, .protocol = bsd.IPPROTO_TCP },
        .{ .socktype = bsd.SOCK_DGRAM, .protocol = bsd.IPPROTO_UDP },
    };
    const kind_count: usize = if (wanted.ai_socktype == 0) 2 else 1;
    const entries = found.len * kind_count;
    const name_bytes = canonical.name_length + 1;
    const memory = sb.sys_base.AllocVec(entries * @sizeOf(Entry) + name_bytes, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return bsd.EAI_MEMORY;
    const list: [*]Entry = @ptrCast(@alignCast(memory));
    const name: [*]u8 = @as([*]u8, @ptrCast(memory)) + entries * @sizeOf(Entry);
    @memcpy(name[0..canonical.name_length], canonical.name[0..canonical.name_length]);
    name[canonical.name_length] = 0;
    var at: usize = 0;
    for (found) |candidate| {
        for (kinds[0..kind_count]) |kind| {
            const each = &list[at];
            const chosen: [2]i32 = if (kind_count == 1) kindWanted(wanted) else .{ kind.socktype, kind.protocol };
            // An IPv4 address as a sockaddr_in, unless AF_INET6 asked
            // for it mapped.
            const as_v4 = candidate.address.isV4() and family != bsd.AF_INET6;
            each.info = .{
                .ai_flags = wanted.ai_flags,
                .ai_family = if (as_v4) bsd.AF_INET else bsd.AF_INET6,
                .ai_socktype = chosen[0],
                .ai_protocol = chosen[1],
                .ai_addr = @ptrCast(&each.address),
            };
            if (as_v4) {
                const in: *bsd.sockaddr_in = @ptrCast(&each.address);
                in.* = .{ .sin_port = bsd.htons(port), .sin_addr = .{ .s_addr = bsd.htonl(candidate.address.v4()) } };
                each.info.ai_addrlen = @sizeOf(bsd.sockaddr_in);
            } else {
                each.address = .{ .sin6_port = bsd.htons(port), .sin6_addr = .{ .s6_addr = candidate.address.bytes } };
                if (candidate.address.isLinkLocal()) each.address.sin6_scope_id = scope;
                each.info.ai_addrlen = @sizeOf(bsd.sockaddr_in6);
            }
            if (at > 0) list[at - 1].info.ai_next = &each.info;
            at += 1;
        }
    }
    if (wanted.ai_flags & bsd.AI_CANONNAME != 0) list[0].info.ai_canonname = @ptrCast(name);
    result.* = &list[0].info;
    return 0;
}

/// The socket type and protocol of every entry when the hints named a
/// socket type.
fn kindWanted(wanted: *const bsd.addrinfo) [2]i32 {
    if (wanted.ai_socktype == bsd.SOCK_DGRAM) return .{ bsd.SOCK_DGRAM, if (wanted.ai_protocol != 0) wanted.ai_protocol else bsd.IPPROTO_UDP };
    return .{ bsd.SOCK_STREAM, if (wanted.ai_protocol != 0) wanted.ai_protocol else bsd.IPPROTO_TCP };
}
