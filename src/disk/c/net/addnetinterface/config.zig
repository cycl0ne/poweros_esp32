// SPDX-License-Identifier: MIT
//! What an interface file says: its keywords read into a Config, with
//! the place of anything wrong in it.
//!
//! ```
//! /* DEVS:NetInterfaces/ETH0 */
//! Device    = networks/openeth.device
//! Unit      = 0
//! Configure = DHCP
//! ```
//!
//! | Keyword | What it sets |
//! |---------|--------------|
//! | `Device`, `Unit` | the network device in DEVS: and its unit |
//! | `Configure` | `DHCP`, or `FIXED` (the default) with the three below |
//! | `Address`, `NetMask`, `Gateway` | the address, its net, the default route |
//! | `NameServer` | a name server to ask; up to four, one per line |
//! | `Domain` | where a name without dots is looked for |
//! | `MTU` | less than the link takes |
//! | `ReadRequests`, `WriteRequests` | how many requests the stack keeps with the device |
//! | `TCPSendSpace`, `TCPRecvSpace` | the ring sizes of every TCP connection |
//! | `Network` | the Wi-Fi network to join, for a Wi-Fi device |
//!
//! Every keyword not in the table is an error, reported with its line and
//! column: a misspelt one would otherwise leave the interface without what
//! it was meant to say.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const Scanner = sdk.dos.keywords.Scanner;

pub const Keyword = enum { device, unit, configure, address, netmask, gateway, nameserver, domain, mtu, read_requests, write_requests, tcp_send_space, tcp_recv_space, network };

const names = [_]struct { name: []const u8, keyword: Keyword }{
    .{ .name = "DEVICE", .keyword = .device },
    .{ .name = "UNIT", .keyword = .unit },
    .{ .name = "CONFIGURE", .keyword = .configure },
    .{ .name = "ADDRESS", .keyword = .address },
    .{ .name = "NETMASK", .keyword = .netmask },
    .{ .name = "GATEWAY", .keyword = .gateway },
    .{ .name = "NAMESERVER", .keyword = .nameserver },
    .{ .name = "DOMAIN", .keyword = .domain },
    .{ .name = "MTU", .keyword = .mtu },
    .{ .name = "READREQUESTS", .keyword = .read_requests },
    .{ .name = "WRITEREQUESTS", .keyword = .write_requests },
    .{ .name = "TCPSENDSPACE", .keyword = .tcp_send_space },
    .{ .name = "TCPRECVSPACE", .keyword = .tcp_recv_space },
    .{ .name = "NETWORK", .keyword = .network },
};

pub const Config = struct {
    device: [64:0]u8 = @splat(0),
    unit: u32 = 0,
    dhcp: bool = false,
    /// Addresses in network order; 0 when not given.
    address: u32 = 0,
    netmask: u32 = 0,
    gateway: u32 = 0,
    nameservers: [bsd.NAMESERVERS_MAX]u32 = @splat(0),
    nameserver_count: usize = 0,
    domain: [64:0]u8 = @splat(0),
    mtu: u32 = 0,
    reads: u32 = 0,
    writes: u32 = 0,
    tcp_send_space: u32 = 0,
    tcp_recv_space: u32 = 0,
    network: [33:0]u8 = @splat(0),
};

/// What is wrong, and where.
pub const Problem = struct {
    kind: enum { none, unknown, equal, number, text, address, configure, missing } = .none,
    /// The token it is about, and where it began.
    token: [sdk.dos.keywords.max_token:0]u8 = @splat(0),
    line: u32 = 0,
    column: u32 = 0,
};

fn upper(char: u8) u8 {
    return if (char >= 'a' and char <= 'z') char - 32 else char;
}

fn keywordOf(token: []const u8) ?Keyword {
    for (names) |entry| {
        if (entry.name.len != token.len) continue;
        var same = true;
        for (entry.name, token) |want, got| {
            if (want != upper(got)) same = false;
        }
        if (same) return entry.keyword;
    }
    return null;
}

/// A dotted address in network order, or null.
pub fn parseAddress(text: []const u8) ?u32 {
    var octets: [4]u8 = @splat(0);
    var part: usize = 0;
    var value: u32 = 0;
    var digits: u32 = 0;
    for (text) |char| {
        if (char >= '0' and char <= '9') {
            value = value * 10 + (char - '0');
            digits += 1;
            if (value > 255 or digits > 3) return null;
        } else if (char == '.') {
            if (digits == 0 or part == 3) return null;
            octets[part] = @intCast(value);
            part += 1;
            value = 0;
            digits = 0;
        } else return null;
    }
    if (digits == 0 or part != 3) return null;
    octets[3] = @intCast(value);
    return @bitCast(octets);
}

fn problem(scanner: *const Scanner, kind: @FieldType(Problem, "kind")) Problem {
    var found: Problem = .{ .kind = kind, .line = scanner.token_line, .column = scanner.token_column };
    @memcpy(found.token[0..scanner.len], scanner.token[0..scanner.len]);
    return found;
}

fn copyText(into: []u8, scanner: *const Scanner) void {
    const length = @min(scanner.len, into.len - 1);
    @memcpy(into[0..length], scanner.token[0..length]);
    into[length] = 0;
}

/// Every keyword in the file read into `config`: the first problem found,
/// or `.none`.
pub fn read(scanner: *Scanner, config: *Config) Problem {
    while (scanner.next()) {
        const keyword = keywordOf(scanner.token[0..scanner.len]) orelse return problem(scanner, .unknown);
        if (!scanner.next() or scanner.len != 1 or scanner.token[0] != '=') return problem(scanner, .equal);
        if (!scanner.next()) return problem(scanner, .text);
        const value = scanner.token[0..scanner.len];
        const number: u32 = @bitCast(scanner.number);
        switch (keyword) {
            .device => copyText(&config.device, scanner),
            .domain => copyText(&config.domain, scanner),
            .network => copyText(&config.network, scanner),
            .configure => {
                if (keywordIs(value, "DHCP")) {
                    config.dhcp = true;
                } else if (keywordIs(value, "FIXED")) {
                    config.dhcp = false;
                } else return problem(scanner, .configure);
            },
            .address, .netmask, .gateway, .nameserver => {
                const address = parseAddress(value) orelse return problem(scanner, .address);
                switch (keyword) {
                    .address => config.address = address,
                    .netmask => config.netmask = address,
                    .gateway => config.gateway = address,
                    else => if (config.nameserver_count < config.nameservers.len) {
                        config.nameservers[config.nameserver_count] = address;
                        config.nameserver_count += 1;
                    },
                }
            },
            .unit, .mtu, .read_requests, .write_requests, .tcp_send_space, .tcp_recv_space => {
                if (scanner.kind != .number or scanner.number < 0) return problem(scanner, .number);
                switch (keyword) {
                    .unit => config.unit = number,
                    .mtu => config.mtu = number,
                    .read_requests => config.reads = number,
                    .write_requests => config.writes = number,
                    .tcp_send_space => config.tcp_send_space = number,
                    else => config.tcp_recv_space = number,
                }
            },
        }
    }
    if (config.device[0] == 0) return .{ .kind = .missing, .token = tokenOf("Device") };
    if (!config.dhcp and config.address == 0) return .{ .kind = .missing, .token = tokenOf("Address") };
    return .{};
}

fn keywordIs(value: []const u8, want: []const u8) bool {
    if (value.len != want.len) return false;
    for (value, want) |got, expected| {
        if (upper(got) != expected) return false;
    }
    return true;
}

fn tokenOf(comptime text: []const u8) [sdk.dos.keywords.max_token:0]u8 {
    var token: [sdk.dos.keywords.max_token:0]u8 = @splat(0);
    @memcpy(token[0..text.len], text);
    return token;
}

// --- tests (host) ------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

fn readText(text: []const u8, config: *Config) Problem {
    var scanner = Scanner.ofText(text);
    return read(&scanner, config);
}

test "a file with every keyword" {
    var config: Config = .{};
    const found = readText(
        \\/* the board's wired network */
        \\Device = "networks/w5500.device"; Unit = 1
        \\configure = fixed
        \\Address = 192.168.1.20
        \\NetMask = 255.255.255.0
        \\Gateway = 192.168.1.1
        \\NameServer = 192.168.1.1
        \\NameServer = 9.9.9.9
        \\Domain = home.lan
        \\MTU = 1400
        \\ReadRequests = 8
        \\WriteRequests = 0x4
        \\TCPSendSpace = 16384
        \\TCPRecvSpace = 16384
    , &config);
    try testing.expectEqual(.none, found.kind);
    try testing.expectEqualStrings("networks/w5500.device", std.mem.sliceTo(&config.device, 0));
    try testing.expectEqual(@as(u32, 1), config.unit);
    try testing.expect(!config.dhcp);
    try testing.expectEqual(parseAddress("192.168.1.20").?, config.address);
    try testing.expectEqual(@as(usize, 2), config.nameserver_count);
    try testing.expectEqualStrings("home.lan", std.mem.sliceTo(&config.domain, 0));
    try testing.expectEqual(@as(u32, 4), config.writes);
    try testing.expectEqual(@as(u32, 16384), config.tcp_recv_space);
}

test "DHCP needs no address" {
    var config: Config = .{};
    try testing.expectEqual(.none, readText("Device = networks/openeth.device\nConfigure = DHCP\n", &config).kind);
    try testing.expect(config.dhcp);
}

test "what is wrong is said, with its place" {
    var config: Config = .{};
    const misspelt = readText("Device = x.device\nAdress = 10.0.0.1\n", &config);
    try testing.expectEqual(.unknown, misspelt.kind);
    try testing.expectEqualStrings("Adress", std.mem.sliceTo(&misspelt.token, 0));
    try testing.expectEqual(@as(u32, 2), misspelt.line);
    try testing.expectEqual(@as(u32, 1), misspelt.column);
    config = .{};
    try testing.expectEqual(.address, readText("Device = x\nAddress = 10.0.0\n", &config).kind);
    config = .{};
    try testing.expectEqual(.number, readText("Device = x\nUnit = one\n", &config).kind);
    config = .{};
    try testing.expectEqual(.equal, readText("Device x\n", &config).kind);
    config = .{};
    try testing.expectEqual(.configure, readText("Device = x\nConfigure = maybe\n", &config).kind);
    config = .{};
    const missing = readText("Device = x\n", &config);
    try testing.expectEqual(.missing, missing.kind);
    try testing.expectEqualStrings("Address", std.mem.sliceTo(&missing.token, 0));
}

test "addresses as text" {
    try testing.expectEqual(bsd.htonl(0x0A00_020F), parseAddress("10.0.2.15").?);
    for ([_][]const u8{ "10.0.2", "10.0.2.256", "1..2.3", "a.b.c.d", "1.2.3.4.5", "" }) |bad| {
        try testing.expectEqual(@as(?u32, null), parseAddress(bad));
    }
}
