// SPDX-License-Identifier: MIT
//! The resolver: a name's addresses, and an address's name, looked up in
//! turn in the dotted text itself, the hosts file, the cache and DNS - on
//! the caller's task, which reads the file through dos.library and asks
//! the name servers through a socket of its own, made with the library's
//! own calls.
//!
//! **Asking a name server.** Each server is asked in turn, three times,
//! two seconds each, with a random id; an answer counts only if it comes
//! from the server asked, from port 53, with the id asked with - anything
//! else is dropped and waited past. A name without dots is asked for in
//! the stack's domain first, then as it is. What DNS answers is kept in
//! the cache for its time to live, held to between 30 s and an hour.
//!
//! The break signals end a wait as in every other call: the lookup then
//! fails with TRY_AGAIN.

const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const dos = sdk.dos;
const DosBase = sdk.interface.dos.DosBase;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const StackBase = _base.StackBase;
const _lock = @import("../lock/_lock.zig");
const _timer = @import("../timer/_timer.zig");
const _names = @import("_names.zig");
const hosts = @import("hosts.zig");
const dns = @import("dns.zig");

const tries = 3;
const wait_s = 2;
/// Answers from elsewhere a try waits past, before it is given up.
const strays_max = 16;
/// The most of the hosts file that is read.
const hosts_bytes = 8192;

fn textOf(name: [*:0]const u8) []const u8 {
    var length: usize = 0;
    while (name[length] != 0 and length < 256) length += 1;
    return name[0..length];
}

/// The addresses `name` has, as a hostent in the opener's buffer; null
/// with `h_errno` set when it has none.
pub fn byName(sb: *SocketBase, name: [*:0]const u8) ?*bsd.hostent {
    const text = textOf(name);
    if (text.len == 0 or text.len > 253) return missing(sb, bsd.HOST_NOT_FOUND);
    if (hosts.dotted(text)) |address| return sb.host.fill(text, &.{address});

    // The hosts file; `localhost` is known without it.
    if (hostsAddress(sb, text)) |address| return sb.host.fill(text, &.{address});
    if (hosts.same(text, "localhost")) return sb.host.fill(text, &.{bsd.htonl(bsd.INADDR_LOOPBACK)});

    const stack = sb.stack;
    var addresses: [_names.addresses_max]u32 = undefined;
    {
        const held = _lock.take(stack);
        defer _lock.give(stack, held);
        const count = _names.cached(stack, text, _timer.clock(stack), &addresses);
        if (count > 0) return sb.host.fill(text, addresses[0..count]);
    }

    // DNS: in the domain first, for a name without dots.
    var qualified: [256]u8 = undefined;
    var candidates: [2][]const u8 = undefined;
    var candidate_count: usize = 0;
    const domain = domainOf(stack);
    if (domain.len > 0 and indexOf(text, '.') == null and text.len + 1 + domain.len < qualified.len) {
        @memcpy(qualified[0..text.len], text);
        qualified[text.len] = '.';
        @memcpy(qualified[text.len + 1 ..][0..domain.len], domain);
        candidates[candidate_count] = qualified[0 .. text.len + 1 + domain.len];
        candidate_count += 1;
    }
    candidates[candidate_count] = text;
    candidate_count += 1;
    var failure: i32 = bsd.HOST_NOT_FOUND;
    for (candidates[0..candidate_count]) |candidate| {
        const found = ask(sb, candidate, dns.type_a) orelse {
            failure = sb.h_errno;
            if (failure == bsd.TRY_AGAIN or failure == bsd.NO_RECOVERY) break;
            continue;
        };
        if (found.count == 0) {
            failure = bsd.NO_DATA;
            continue;
        }
        {
            const held = _lock.take(stack);
            defer _lock.give(stack, held);
            _names.remember(stack, text, found.addresses[0..found.count], found.ttl, _timer.clock(stack));
        }
        return sb.host.fill(candidate, found.addresses[0..found.count]);
    }
    return missing(sb, failure);
}

/// The name `address` (network order) has; null with `h_errno` set.
pub fn byAddress(sb: *SocketBase, address: u32) ?*bsd.hostent {
    if (hostsName(sb, address)) |entry| return entry;
    if (address == bsd.htonl(bsd.INADDR_LOOPBACK)) return sb.host.fill("localhost", &.{address});
    const octets: [4]u8 = @bitCast(address);
    var name: [32]u8 = undefined;
    var at: usize = 0;
    var index: usize = 4;
    while (index > 0) {
        index -= 1;
        at += decimal(name[at..], octets[index]);
        name[at] = '.';
        at += 1;
    }
    const suffix = "in-addr.arpa";
    @memcpy(name[at..][0..suffix.len], suffix);
    at += suffix.len;
    const found = ask(sb, name[0..at], dns.type_ptr) orelse return missing(sb, sb.h_errno);
    if (!found.has_name) return missing(sb, bsd.NO_DATA);
    return sb.host.fill(textOf(@ptrCast(&found.name)), &.{address});
}

fn decimal(into: []u8, value: u8) usize {
    var at: usize = 0;
    if (value >= 100) {
        into[at] = '0' + value / 100;
        at += 1;
    }
    if (value >= 10) {
        into[at] = '0' + value / 10 % 10;
        at += 1;
    }
    into[at] = '0' + value % 10;
    return at + 1;
}

fn missing(sb: *SocketBase, errno: i32) ?*bsd.hostent {
    sb.h_errno = errno;
    return null;
}

fn indexOf(text: []const u8, wanted: u8) ?usize {
    for (text, 0..) |char, index| {
        if (char == wanted) return index;
    }
    return null;
}

fn domainOf(stack: *StackBase) []const u8 {
    var length: usize = 0;
    while (length < stack.domain.len and stack.domain[length] != 0) length += 1;
    return stack.domain[0..length];
}

/// The address `name` has in the hosts file, if it is there. The file is
/// read into memory of its own: the caller's stack may be a command's,
/// too small for it.
fn hostsAddress(sb: *SocketBase, name: []const u8) ?u32 {
    const sys = sb.sys_base;
    const memory = sys.AllocVec(hosts_bytes, exec.MEMF_ANY) orelse return null;
    defer sys.FreeVec(memory);
    return hosts.find(readHosts(sb, @as([*]u8, @ptrCast(memory))[0..hosts_bytes]), name);
}

/// The first name `address` has in the hosts file, as a hostent in the
/// opener's buffer; null when it is not there.
fn hostsName(sb: *SocketBase, address: u32) ?*bsd.hostent {
    const sys = sb.sys_base;
    const memory = sys.AllocVec(hosts_bytes, exec.MEMF_ANY) orelse return null;
    defer sys.FreeVec(memory);
    const name = hosts.reverse(readHosts(sb, @as([*]u8, @ptrCast(memory))[0..hosts_bytes]), address) orelse return null;
    return sb.host.fill(name, &.{address});
}

/// The hosts file's text, as much as fits in `into`; empty when there is
/// none, or no dos.library to read it with.
fn readHosts(sb: *SocketBase, into: []u8) []const u8 {
    const sys = sb.sys_base;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return &.{};
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    const file = dl.Open(bsd.HOSTS_FILE, dos.MODE_OLDFILE) orelse return &.{};
    defer _ = dl.Close(file);
    const got = dl.Read(file, into.ptr, @intCast(into.len));
    if (got <= 0) return &.{};
    return into[0..@intCast(got)];
}

/// The name servers ENVARC:Sys/net/nameservers lists, an address to a
/// line, in the chip's order: how many. For a machine whose interfaces
/// name none and get none from DHCP.
fn serversFromFile(sb: *SocketBase, into: *[bsd.NAMESERVERS_MAX]u32) usize {
    const sys = sb.sys_base;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return 0;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    const file = dl.Open(bsd.NAMESERVERS_FILE, dos.MODE_OLDFILE) orelse return 0;
    defer _ = dl.Close(file);
    var text: [512]u8 = undefined;
    const got = dl.Read(file, &text, text.len);
    if (got <= 0) return 0;
    var count: usize = 0;
    var start: usize = 0;
    const end: usize = @intCast(got);
    var index: usize = 0;
    while (index <= end and count < into.len) : (index += 1) {
        if (index < end and text[index] != '\n' and text[index] != '\r') continue;
        var line = text[start..index];
        while (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) line = line[1..];
        while (line.len > 0 and (line[line.len - 1] == ' ' or line[line.len - 1] == '\t')) line = line[0 .. line.len - 1];
        if (hosts.dotted(line)) |address| {
            into[count] = bsd.ntohl(address);
            count += 1;
        }
        start = index + 1;
    }
    return count;
}

/// `name` of `kind` asked of each name server in turn: the answer, or null
/// with `h_errno` set - HOST_NOT_FOUND for a name the server says does
/// not exist, TRY_AGAIN when no server answered, NO_RECOVERY with no
/// server to ask.
fn ask(sb: *SocketBase, name: []const u8, kind: u16) ?dns.Answer {
    const stack = sb.stack;
    var servers: [bsd.NAMESERVERS_MAX]u32 = undefined;
    var server_count: usize = 0;
    {
        const held = _lock.take(stack);
        defer _lock.give(stack, held);
        server_count = stack.nameserver_count;
        servers = stack.nameservers;
    }
    if (server_count == 0) server_count = serversFromFile(sb, &servers);
    if (server_count == 0) {
        sb.h_errno = bsd.NO_RECOVERY;
        return null;
    }
    const calls = _base.iface(sb);
    const socket = calls.Socket(bsd.PF_INET, bsd.SOCK_DGRAM, 0);
    if (socket < 0) {
        sb.h_errno = bsd.NO_RECOVERY;
        return null;
    }
    defer _ = calls.CloseSocket(socket);
    var message: [300]u8 = undefined;
    var packet: [512]u8 = undefined;
    for (servers[0..server_count]) |server| {
        var try_count: usize = 0;
        while (try_count < tries) : (try_count += 1) {
            const id = _names.random16(stack);
            const length = dns.question(&message, id, name, kind);
            if (length == 0) {
                sb.h_errno = bsd.HOST_NOT_FOUND;
                return null;
            }
            var to: bsd.sockaddr_in = .{ .sin_port = bsd.htons(dns.port), .sin_addr = .{ .s_addr = bsd.htonl(server) } };
            if (calls.SendTo(socket, &message, @intCast(length), 0, to.anyConst(), @sizeOf(bsd.sockaddr_in)) < 0) break;
            var strays: usize = 0;
            while (strays < strays_max) : (strays += 1) {
                var read: bsd.fd_set = .{};
                read.set(socket);
                var patience: bsd.timeval = .{ .secs = wait_s };
                const ready = calls.WaitSelect(socket + 1, &read, null, null, &patience, null);
                if (ready < 0) {
                    sb.h_errno = bsd.TRY_AGAIN;
                    return null;
                }
                if (ready == 0) break;
                var from: bsd.sockaddr_in = .{};
                var from_length: u32 = @sizeOf(bsd.sockaddr_in);
                const got = calls.RecvFrom(socket, &packet, packet.len, 0, from.any(), &from_length);
                if (got <= 0) continue;
                // Only the server asked, from its port, with our id.
                if (from.sin_addr.s_addr != bsd.htonl(server) or from.sin_port != bsd.htons(dns.port)) continue;
                const found = dns.answer(packet[0..@intCast(got)], id, kind) orelse continue;
                if (found.rcode == dns.rcode_name_error) {
                    sb.h_errno = bsd.HOST_NOT_FOUND;
                    return null;
                }
                if (found.rcode != dns.rcode_ok) break;
                return found;
            }
        }
    }
    sb.h_errno = bsd.TRY_AGAIN;
    return null;
}
