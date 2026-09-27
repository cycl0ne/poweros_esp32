// SPDX-License-Identifier: MIT
//! GetNameInfo: an address and a port as a host's name and a service's.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _lock = @import("../lock/_lock.zig");
const _netif = @import("../netif/_netif.zig");
const resolver = @import("resolver.zig");
const getaddrinfo = @import("getaddrinfo.zig");
const address_file = @import("../ip6/address.zig");
const Address = address_file.Address;

/// A sockaddr's address as a host name and its port as a service's, the
/// reverse of GetAddrInfo.
///
/// SYNOPSIS:
/// ```zig
/// fn GetNameInfo(base: *SocketBase, address: *const sockaddr, address_length: u32, host: ?[*]u8, host_length: u32, service: ?[*]u8, service_length: u32, flags: i32) i32
/// ```
///
/// SINCE: 1.1. LVO -208.
///
/// INPUTS:
/// - `address`, `address_length` - a `sockaddr_in` or a `sockaddr_in6`.
/// - `host`, `host_length` - where the host goes, NUL-terminated; null
///   for none. `NI_MAXHOST` bytes always do.
/// - `service`, `service_length` - where the service goes; null for none.
///   `NI_MAXSERV` bytes always do.
/// - `flags` - `NI_*`.
///
/// RESULT:
/// 0, or an EAI_* code: `EAI_FAMILY` (another family, or a sockaddr too
/// short for its own), `EAI_NONAME` (no name, with `NI_NAMEREQD`, or
/// neither host nor service asked for), `EAI_AGAIN` (no name server
/// answered, with `NI_NAMEREQD`), `EAI_OVERFLOW` (a buffer too small).
///
/// BEHAVIOR:
/// The host is the name GetHostByAddr finds - the hosts file, `localhost`,
/// a PTR question - or, with `NI_NUMERICHOST` or when there is none, the
/// address as Inet_NtoP writes it: an IPv4 one mapped into IPv6 as its
/// dotted quad, a link-local one followed by `%` and its interface. With
/// `NI_NOFQDN` a name ending in the stack's domain loses it. The service is
/// the port's name if GetAddrInfo knows one, else its number.
///
/// CONTEXT:
/// - Waits: yes, for the name servers, unless `NI_NUMERICHOST`.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a process, to read the hosts file.
///
/// OWNERSHIP:
/// The buffers are the caller's; nothing is kept.
///
/// NOTES:
/// None.
///
/// BUGS:
/// No services database: a port has a name only among GetAddrInfo's.
///
/// SEE ALSO:
/// `GetAddrInfo`, `GetHostByAddr`, `Inet_NtoP`
///
/// EXAMPLES:
/// ```zig
/// var host: [bsd.NI_MAXHOST]u8 = undefined;
/// var service: [bsd.NI_MAXSERV]u8 = undefined;
/// if (sb.GetNameInfo(from.any(), from_length, &host, host.len, &service, service.len, 0) == 0) {
///     _ = Printf(dl, "%s port %s\n", .{ @as([*:0]const u8, @ptrCast(&host)), @as([*:0]const u8, @ptrCast(&service)) });
/// }
/// ```
pub fn GetNameInfo(sb: *SocketBase, address: *const bsd.sockaddr, address_length: u32, host: ?[*]u8, host_length: u32, service: ?[*]u8, service_length: u32, flags: i32) i32 {
    if (host == null and service == null) return bsd.EAI_NONAME;
    var peer: Address = .{};
    var port: u16 = 0;
    var scope: u32 = 0;
    if (address_length >= @sizeOf(bsd.sockaddr_in) and address.sa_family == bsd.AF_INET) {
        const in: *const bsd.sockaddr_in = @ptrCast(@alignCast(address));
        peer = Address.fromV4(bsd.ntohl(in.sin_addr.s_addr));
        port = bsd.ntohs(in.sin_port);
    } else if (address_length >= @sizeOf(bsd.sockaddr_in6) and address.sa_family == bsd.AF_INET6) {
        const in6: *const bsd.sockaddr_in6 = @ptrCast(@alignCast(address));
        peer = .{ .bytes = in6.sin6_addr.s6_addr };
        port = bsd.ntohs(in6.sin6_port);
        scope = in6.sin6_scope_id;
    } else return bsd.EAI_FAMILY;

    if (host) |into| {
        const room = into[0..host_length];
        var name: [256]u8 = undefined;
        const found: ?usize = if (flags & bsd.NI_NUMERICHOST != 0) null else resolver.nameOf(sb, peer, &name);
        if (found) |length| {
            const kept = if (flags & bsd.NI_NOFQDN != 0) withoutDomain(sb, name[0..length]) else name[0..length];
            if (!put(room, kept)) return bsd.EAI_OVERFLOW;
        } else {
            if (flags & bsd.NI_NAMEREQD != 0) return if (sb.h_errno == bsd.TRY_AGAIN) bsd.EAI_AGAIN else bsd.EAI_NONAME;
            var text: [address_file.text_max + 1 + bsd.IFNAMSIZ]u8 = undefined;
            if (!put(room, numeric(sb, peer, scope, &text))) return bsd.EAI_OVERFLOW;
        }
    }
    if (service) |into| {
        const room = into[0..service_length];
        var digits: [6]u8 = undefined;
        const named = if (flags & bsd.NI_NUMERICSERV != 0) null else serviceName(port);
        if (!put(room, named orelse decimal(port, &digits))) return bsd.EAI_OVERFLOW;
    }
    return 0;
}

/// `text` and its NUL into `room`, if it fits.
fn put(room: []u8, text: []const u8) bool {
    if (text.len + 1 > room.len) return false;
    @memcpy(room[0..text.len], text);
    room[text.len] = 0;
    return true;
}

/// The address as text: IPv4 dotted, IPv6 as RFC 5952 writes it, a
/// link-local one with `%` and the interface its scope names.
fn numeric(sb: *SocketBase, peer: Address, scope: u32, into: []u8) []const u8 {
    if (peer.isV4()) {
        var quad: [15]u8 = undefined;
        const length = address_file.formatV4(peer.v4(), &quad);
        @memcpy(into[0..length], quad[0..length]);
        return into[0..length];
    }
    var text: [address_file.text_max]u8 = undefined;
    var length = address_file.format(peer, &text);
    @memcpy(into[0..length], text[0..length]);
    if (scope != 0 and peer.isLinkLocal()) {
        const held = _lock.take(sb.stack);
        defer _lock.give(sb.stack, held);
        if (_netif.byIndex(sb.stack, scope)) |interface| {
            into[length] = '%';
            length += 1;
            var at: usize = 0;
            while (at < interface.name.len and interface.name[at] != 0) : (at += 1) {
                into[length] = interface.name[at];
                length += 1;
            }
        }
    }
    return into[0..length];
}

/// A name without the stack's domain at its end, if it ends so.
fn withoutDomain(sb: *SocketBase, name: []const u8) []const u8 {
    const domain = sb.stack.domain;
    var length: usize = 0;
    while (length < domain.len and domain[length] != 0) length += 1;
    if (length == 0 or name.len <= length + 1) return name;
    const tail = name[name.len - length ..];
    if (name[name.len - length - 1] != '.' or !@import("hosts.zig").same(tail, domain[0..length])) return name;
    return name[0 .. name.len - length - 1];
}

fn serviceName(port: u16) ?[]const u8 {
    for (getaddrinfo.services) |known| {
        if (known.port == port) return known.name;
    }
    return null;
}

fn decimal(value: u16, into: *[6]u8) []const u8 {
    var digits: [5]u8 = undefined;
    var count: usize = 0;
    var rest = value;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(rest % 10));
        count += 1;
        rest /= 10;
        if (rest == 0) break;
    }
    for (0..count) |index| into[index] = digits[count - 1 - index];
    return into[0..count];
}
