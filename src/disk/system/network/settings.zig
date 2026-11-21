// SPDX-License-Identifier: MIT
//! An interface's settings as Network's window shows them - how it gets
//! its IPv4 address, the address itself, the name servers, IPv6 - read
//! from its file in DEVS:NetInterfaces/ (`read`) and written back into it
//! (`write`), through the `netinterface` module, which leaves the rest of
//! the file as it was.
//!
//! **What is written** follows what the window says, keyword by keyword:
//! `Configure` always; `Address`, `NetMask` and `Gateway` only for a fixed
//! address - an interface that asks DHCP keeps the ones its file has, for
//! the day it is set back - and the same for `Address6`, `Prefix6` and
//! `Gateway6` under a fixed IPv6 address. `IPv6` is written when the file
//! has it or the window asks for anything but the default. An empty field
//! takes its keyword out. That the values are addresses is the window's to
//! see to, before it writes (network.zig).

const netinterface = @import("netinterface");
const Value = netinterface.Value;

/// A field's text, as long as an IPv6 address with a zone.
pub const Field = [64:0]u8;

/// The name servers, as many as the file takes - four of each kind - with
/// a space between each two.
pub const Servers = [8 * 48:0]u8;

pub const Ipv6 = enum(u8) { auto, fixed, off };

pub const Settings = struct {
    /// What the file says the device is, for the window to name the
    /// interface by.
    device: Field = @splat(0),
    unit: Field = @splat(0),
    dhcp: bool = false,
    address: Field = @splat(0),
    netmask: Field = @splat(0),
    gateway: Field = @splat(0),
    nameservers: Servers = @splat(0),
    domain: Field = @splat(0),
    ipv6: Ipv6 = .auto,
    address6: Field = @splat(0),
    prefix6: Field = @splat(0),
    gateway6: Field = @splat(0),
};

/// The longest a name server's text is, an IPv6 one's with room to spare.
pub const server_max: usize = 46;
/// The most name servers of each kind the file takes.
pub const servers_max: usize = 4;

fn put(into: []u8, text: []const u8) void {
    const count = @min(text.len, into.len - 1);
    @memcpy(into[0..count], text[0..count]);
    into[count] = 0;
}

pub fn untilNul(bytes: []const u8) []const u8 {
    for (bytes, 0..) |byte, at| if (byte == 0) return bytes[0..at];
    return bytes;
}

/// What the file `bytes` says, into `settings` - a kilobyte, which the
/// caller keeps where it has the room.
pub fn read(bytes: []const u8, settings: *Settings) void {
    settings.* = .{};
    if (netinterface.valueOf(bytes, "Device")) |text| put(&settings.device, text);
    if (netinterface.valueOf(bytes, "Unit")) |text| put(&settings.unit, text);
    // FIXED is what a file without the keyword means.
    if (netinterface.valueOf(bytes, "Configure")) |text| settings.dhcp = netinterface.sameWord(text, "DHCP");
    if (netinterface.valueOf(bytes, "Address")) |text| put(&settings.address, text);
    if (netinterface.valueOf(bytes, "NetMask")) |text| put(&settings.netmask, text);
    if (netinterface.valueOf(bytes, "Gateway")) |text| put(&settings.gateway, text);
    var servers: [2 * servers_max][]const u8 = undefined;
    const count = netinterface.valuesOf(bytes, "NameServer", &servers);
    var at: usize = 0;
    for (servers[0..count]) |server| {
        if (at + server.len + 1 >= settings.nameservers.len) break;
        if (at != 0) {
            settings.nameservers[at] = ' ';
            at += 1;
        }
        @memcpy(settings.nameservers[at..][0..server.len], server);
        at += server.len;
    }
    if (netinterface.valueOf(bytes, "Domain")) |text| put(&settings.domain, text);
    if (netinterface.valueOf(bytes, "IPv6")) |text| {
        if (netinterface.sameWord(text, "FIXED")) settings.ipv6 = .fixed;
        if (netinterface.sameWord(text, "OFF")) settings.ipv6 = .off;
    }
    if (netinterface.valueOf(bytes, "Address6")) |text| put(&settings.address6, text);
    if (netinterface.valueOf(bytes, "Prefix6")) |text| put(&settings.prefix6, text);
    if (netinterface.valueOf(bytes, "Gateway6")) |text| put(&settings.gateway6, text);
}

/// The words of a list of name servers: what is between spaces and
/// commas, as many as `into` holds; how many there are.
pub fn serversOf(text: []const u8, into: [][]const u8) usize {
    var count: usize = 0;
    var at: usize = 0;
    while (at < text.len) {
        while (at < text.len and isGap(text[at])) at += 1;
        const start = at;
        while (at < text.len and !isGap(text[at])) at += 1;
        if (at == start) break;
        if (count == into.len) return count + 1;
        into[count] = text[start..at];
        count += 1;
    }
    return count;
}

fn isGap(char: u8) bool {
    return char == ' ' or char == ',' or char == '\t';
}

/// Two buffers the file is changed in, a keyword at a time: each change
/// reads the last one's result and writes into the other buffer.
const Editor = struct {
    current: []const u8,
    buffers: [2][]u8,
    next: usize = 0,
    full: bool = false,

    fn set(editor: *Editor, keyword: []const u8, values: []const Value) void {
        if (editor.full) return;
        const result = netinterface.withValues(editor.current, keyword, values, editor.buffers[editor.next]) orelse {
            editor.full = true;
            return;
        };
        editor.current = result;
        editor.next = 1 - editor.next;
    }

    /// `keyword` given `field`'s text, or taken out when it is empty.
    fn field(editor: *Editor, keyword: []const u8, text: []const u8) void {
        if (text.len == 0) return editor.set(keyword, &.{});
        editor.set(keyword, &.{.{ .text = text }});
    }
};

/// The file `bytes` with `settings` written into it, in one of `first` and
/// `second`, which must not be `bytes`; null when it would not fit.
pub fn write(bytes: []const u8, settings: *const Settings, first: []u8, second: []u8) ?[]const u8 {
    var editor: Editor = .{ .current = bytes, .buffers = .{ first, second } };
    editor.set("Configure", &.{.{ .text = if (settings.dhcp) "DHCP" else "FIXED" }});
    if (!settings.dhcp) {
        editor.field("Address", untilNul(&settings.address));
        editor.field("NetMask", untilNul(&settings.netmask));
        editor.field("Gateway", untilNul(&settings.gateway));
    }
    var words: [2 * servers_max][]const u8 = undefined;
    const count = @min(serversOf(untilNul(&settings.nameservers), &words), words.len);
    var values: [2 * servers_max]Value = undefined;
    for (words[0..count], 0..) |word, at| values[at] = .{ .text = word };
    editor.set("NameServer", values[0..count]);
    editor.field("Domain", untilNul(&settings.domain));
    if (netinterface.find(editor.current, "IPv6") != null or settings.ipv6 != .auto) {
        editor.set("IPv6", &.{.{ .text = switch (settings.ipv6) {
            .auto => "AUTO",
            .fixed => "FIXED",
            .off => "OFF",
        } }});
    }
    if (settings.ipv6 == .fixed) {
        editor.field("Address6", untilNul(&settings.address6));
        editor.field("Prefix6", untilNul(&settings.prefix6));
        editor.field("Gateway6", untilNul(&settings.gateway6));
    }
    return if (editor.full) null else editor.current;
}

// --- tests (host) -------------------------------------------------------------

const testing = @import("std").testing;

const eth0 =
    \\/* DEVS:NetInterfaces/ETH0: the board's own Ethernet */
    \\Device     = networks/emac.device
    \\Unit       = 0
    \\Configure  = DHCP
    \\
;

fn setText(field: anytype, text: []const u8) void {
    put(field, text);
}

test "a file read: DHCP, the device, IPv6 by default" {
    var settings: Settings = .{};
    read(eth0, &settings);
    try testing.expect(settings.dhcp);
    try testing.expectEqualStrings("networks/emac.device", untilNul(&settings.device));
    try testing.expectEqualStrings("0", untilNul(&settings.unit));
    try testing.expectEqual(Ipv6.auto, settings.ipv6);
    try testing.expectEqualStrings("", untilNul(&settings.nameservers));
}

test "a fixed address written, then DHCP again: the address stays in the file" {
    var settings: Settings = .{};
    read(eth0, &settings);
    settings.dhcp = false;
    setText(&settings.address, "192.168.1.20");
    setText(&settings.netmask, "255.255.255.0");
    setText(&settings.gateway, "192.168.1.1");
    setText(&settings.nameservers, "192.168.1.1, 2620:fe::fe");
    setText(&settings.domain, "home.lan");
    var first: [1024]u8 = undefined;
    var second: [1024]u8 = undefined;
    const fixed = write(eth0, &settings, &first, &second).?;
    try testing.expectEqualStrings(
        \\/* DEVS:NetInterfaces/ETH0: the board's own Ethernet */
        \\Device     = networks/emac.device
        \\Unit       = 0
        \\Configure  = FIXED
        \\Address    = 192.168.1.20
        \\NetMask    = 255.255.255.0
        \\Gateway    = 192.168.1.1
        \\NameServer = 192.168.1.1
        \\NameServer = 2620:fe::fe
        \\Domain     = home.lan
        \\
    , fixed);
    var again: Settings = .{};
    read(fixed, &again);
    try testing.expect(!again.dhcp);
    try testing.expectEqualStrings("192.168.1.1 2620:fe::fe", untilNul(&again.nameservers));

    var copy: [1024]u8 = undefined;
    @memcpy(copy[0..fixed.len], fixed);
    var dhcp = again;
    dhcp.dhcp = true;
    setText(&dhcp.nameservers, "");
    setText(&dhcp.domain, "");
    var third: [1024]u8 = undefined;
    var fourth: [1024]u8 = undefined;
    const back = write(copy[0..fixed.len], &dhcp, &third, &fourth).?;
    try testing.expectEqualStrings(
        \\/* DEVS:NetInterfaces/ETH0: the board's own Ethernet */
        \\Device     = networks/emac.device
        \\Unit       = 0
        \\Configure  = DHCP
        \\Address    = 192.168.1.20
        \\NetMask    = 255.255.255.0
        \\Gateway    = 192.168.1.1
        \\
    , back);
}

test "IPv6 written only when the file has it or it is not the default" {
    var settings: Settings = .{};
    read(eth0, &settings);
    var first: [1024]u8 = undefined;
    var second: [1024]u8 = undefined;
    try testing.expectEqualStrings(eth0, write(eth0, &settings, &first, &second).?);
    settings.ipv6 = .fixed;
    setText(&settings.address6, "2001:db8::20");
    setText(&settings.prefix6, "64");
    const fixed = write(eth0, &settings, &first, &second).?;
    try testing.expectEqualStrings(eth0 ++
        \\IPv6       = FIXED
        \\Address6   = 2001:db8::20
        \\Prefix6    = 64
        \\
    , fixed);
    var again: Settings = .{};
    read(fixed, &again);
    try testing.expectEqual(Ipv6.fixed, again.ipv6);
    try testing.expectEqualStrings("2001:db8::20", untilNul(&again.address6));
}

test "name servers split at spaces and commas; one too many is said" {
    var words: [8][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 3), serversOf(" 1.1.1.1,8.8.8.8 ,  9.9.9.9 ", &words));
    try testing.expectEqualStrings("8.8.8.8", words[1]);
    var two: [2][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 3), serversOf("a b c", &two));
}
