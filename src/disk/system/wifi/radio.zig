// SPDX-License-Identifier: MIT
//! The radios WiFi works on, and what it asks of them through the wireless
//! requests (`sdk/devices/wireless.zig`).
//!
//! **A radio is a network interface whose device answers them.** The
//! interfaces are bsdsocket.library's (`find`): each one's device is
//! opened and asked for the network it is on, S2_GETNETWORKINFO, and a
//! device that does not know the request (IOERR_NOCMD) is a wire, not a
//! radio. So a radio is only found once its interface is up - which is
//! also what gives the station an address once it is on a network.
//!
//! **A link is one radio opened** (`Link`): one request for what is
//! answered at once - the network joined, the signal, a join and a leave -
//! and a copy of it for the scan, which takes seconds and runs while the
//! window goes on (`startScan`, `scanDone`). A scan's networks are built
//! by the device in a pool the link gives it and keeps until the next
//! scan; `gather` sorts them into one line per network name, the
//! strongest access point's, strongest first.

const sdk = @import("sdk");
const exec = sdk.exec;
const net = sdk.devices.network;
const wireless = sdk.devices.wireless;
const bsd = sdk.bsdsocket;
const text = @import("text.zig");
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const UtilityBase = sdk.interface.utility.UtilityBase;

/// The most radios one machine is looked at for.
pub const max_radios = 4;
/// The most network names a scan is gathered into.
pub const max_networks = 64;
/// The longest network name, without its NUL.
pub const ssid_max = 32;

/// One radio: its interface, and the device and unit under it.
pub const Radio = struct {
    interface: [16:0]u8 = @splat(0),
    device: [64:0]u8 = @splat(0),
    unit: u32 = 0,
    /// What the window's chooser shows for it.
    label: text.Line = .{},
};

/// The device's copy calls: nothing is read or written through them, but
/// every opener gives them.
fn noCopy(to: ?*anyopaque, from: ?*const anyopaque, length: u32) callconv(.c) bool {
    _ = .{ to, from, length };
    return false;
}

/// The tags that give a request the copy calls: made where it is opened,
/// since a call's address is known only once the program is loaded.
fn buffersInto(tags: *[3]TagItem) void {
    tags.* = .{
        .{ .tag = net.S2_CopyToBuff, .data = @intFromPtr(&noCopy) },
        .{ .tag = net.S2_CopyFromBuff, .data = @intFromPtr(&noCopy) },
        .{},
    };
}

/// The radios among the interfaces, into `into`: how many there are.
pub fn find(sys: *ExecBase, sb: *SocketBase, into: *[max_radios]Radio) usize {
    const list = sb.ObtainInterfaceList() orelse return 0;
    defer sb.ReleaseInterfaceList(list);
    var count: usize = 0;
    var it = list.iterator();
    while (it.next()) |node| {
        if (count == into.len) break;
        const name = node.name orelse continue;
        var device: ?[*:0]const u8 = null;
        var unit: u32 = 0;
        const tags = [_]TagItem{
            .{ .tag = bsd.IFQ_DeviceName, .data = @intFromPtr(&device) },
            .{ .tag = bsd.IFQ_DeviceUnit, .data = @intFromPtr(&unit) },
            .{},
        };
        if (sb.QueryInterfaceTagList(name, &tags) != 0) continue;
        const device_name = device orelse continue;
        if (!answersWireless(sys, device_name, unit)) continue;
        const radio = &into[count];
        radio.* = .{ .unit = unit };
        _ = text.copyInto(&radio.interface, text.spanOf(name));
        _ = text.copyInto(&radio.device, text.spanOf(device_name));
        radio.label.say(sys, "%s - %s unit %u", .{ name, device_name, unit });
        count += 1;
    }
    return count;
}

/// Whether `device`'s `unit` knows the wireless requests: it is opened
/// and asked for the network it is on, which a radio answers whether it
/// is on one or not.
fn answersWireless(sys: *ExecBase, device: [*:0]const u8, unit: u32) bool {
    const port = sys.CreateMsgPort() orelse return false;
    defer sys.DeleteMsgPort(port);
    const pool = sys.CreatePool(exec.MEMF_ANY, 512, 256) orelse return false;
    defer sys.DeletePool(pool);
    var buffers: [3]TagItem = undefined;
    buffersInto(&buffers);
    var req: net.IOSana2Req = .{};
    req.req.message.reply_port = port;
    req.req.message.length = @sizeOf(net.IOSana2Req);
    req.buffer_management = &buffers;
    if (sys.OpenDevice(device, unit, &req.req, 0) != 0) return false;
    defer sys.CloseDevice(&req.req);
    req.req.command = wireless.S2_GETNETWORKINFO;
    req.data = pool;
    req.stat_data = null;
    _ = sys.DoIO(&req.req);
    return req.req.err != exec.IOERR_NOCMD;
}

/// How a station joins a network, in a word.
pub fn authName(mode: usize) [*:0]const u8 {
    return switch (mode) {
        wireless.S2AUTH_OPEN => "open",
        wireless.S2AUTH_WEP => "WEP",
        wireless.S2AUTH_WPA_PSK => "WPA",
        wireless.S2AUTH_WPA2_PSK => "WPA2",
        wireless.S2AUTH_WPA_WPA2_PSK => "WPA/WPA2",
        wireless.S2AUTH_WPA3_PSK => "WPA3",
        wireless.S2AUTH_WPA2_WPA3_PSK => "WPA2/WPA3",
        wireless.S2AUTH_ENTERPRISE => "enterprise",
        else => "other",
    };
}

/// The bands, as `Network.bands` has them.
pub const BAND_2G: u8 = 1 << 0;
pub const BAND_5G: u8 = 1 << 1;

/// The band a channel is in: 1 to 14 are 2.4 GHz, the rest 5 GHz.
pub fn bandOf(channel: u64) u8 {
    return if (channel >= 1 and channel <= 14) BAND_2G else BAND_5G;
}

/// A network name in range: its strongest access point's signal, channel
/// and way in, and the bands any of its access points are on.
pub const Network = struct {
    ssid: [ssid_max:0]u8 = @splat(0),
    signal: i32 = 0,
    channel: u32 = 0,
    auth: u32 = wireless.S2AUTH_OTHER,
    bands: u8 = 0,

    pub fn name(network: *const Network) []const u8 {
        return text.untilNul(&network.ssid);
    }

    pub fn open(network: *const Network) bool {
        return network.auth == wireless.S2AUTH_OPEN;
    }
};

/// The network joined, as the device says it.
pub const Joined = struct {
    ssid: [ssid_max:0]u8 = @splat(0),
    bssid: [6]u8 = @splat(0),
    channel: u32 = 0,
    signal: i32 = 0,
    auth: u32 = wireless.S2AUTH_OTHER,

    pub fn name(joined: *const Joined) []const u8 {
        return text.untilNul(&joined.ssid);
    }
};

/// One radio opened.
pub const Link = struct {
    sys: *ExecBase,
    utility: *UtilityBase,
    port: ?*exec.MsgPort = null,
    scan_port: ?*exec.MsgPort = null,
    req: net.IOSana2Req = .{},
    scan_req: net.IOSana2Req = .{},
    /// The pool the last scan's networks are in, and whether a scan is
    /// out.
    scan_pool: ?*anyopaque = null,
    scanning: bool = false,
    opened: bool = false,
    /// The copy calls' tags, which the device reads as it is opened.
    buffers: [3]TagItem = @splat(.{}),

    /// `radio` opened: false, and nothing kept, when its device will not.
    pub fn open(link: *Link, radio: *const Radio) bool {
        const sys = link.sys;
        link.port = sys.CreateMsgPort() orelse return false;
        link.scan_port = sys.CreateMsgPort() orelse {
            link.close();
            return false;
        };
        link.req = .{};
        link.req.req.message.reply_port = link.port;
        link.req.req.message.length = @sizeOf(net.IOSana2Req);
        buffersInto(&link.buffers);
        link.req.buffer_management = &link.buffers;
        if (sys.OpenDevice(@ptrCast(&radio.device), radio.unit, &link.req.req, 0) != 0) {
            link.close();
            return false;
        }
        link.opened = true;
        link.scan_req = link.req;
        link.scan_req.req.message.reply_port = link.scan_port;
        return true;
    }

    /// The scan taken back if one is out, the device closed, and what was
    /// kept given back.
    pub fn close(link: *Link) void {
        const sys = link.sys;
        if (link.scanning) {
            _ = sys.AbortIO(&link.scan_req.req);
            _ = sys.WaitIO(&link.scan_req.req);
            link.scanning = false;
        }
        if (link.opened) sys.CloseDevice(&link.req.req);
        link.opened = false;
        if (link.scan_pool) |pool| sys.DeletePool(pool);
        link.scan_pool = null;
        if (link.scan_port) |port| sys.DeleteMsgPort(port);
        if (link.port) |port| sys.DeleteMsgPort(port);
        link.scan_port = null;
        link.port = null;
    }

    /// The signal a scan's answer comes on.
    pub fn scanMask(link: *const Link) u32 {
        const port = link.scan_port orelse return 0;
        return port.sigMask();
    }

    /// A scan sent, the last one's networks given back: false when there
    /// is no memory for its pool, or one is out already.
    pub fn startScan(link: *Link) bool {
        if (!link.opened or link.scanning) return false;
        const sys = link.sys;
        if (link.scan_pool) |pool| sys.DeletePool(pool);
        link.scan_pool = sys.CreatePool(exec.MEMF_ANY, 4096, 1024) orelse return false;
        link.scan_req.req.command = wireless.S2_GETNETWORKS;
        link.scan_req.data = link.scan_pool;
        link.scan_req.stat_data = null;
        link.scan_req.data_length = 0;
        sys.SendIO(&link.scan_req.req);
        link.scanning = true;
        return true;
    }

    /// The scan's answer, once its signal came: the networks gathered
    /// into `into` - how many - or null while it is still out. The error
    /// is in `failed` when the device refused it.
    pub fn scanDone(link: *Link, into: *[max_networks]Network, failed: *i8) ?usize {
        if (!link.scanning) return null;
        if (link.sys.CheckIO(&link.scan_req.req) == null) return null;
        _ = link.sys.WaitIO(&link.scan_req.req);
        link.scanning = false;
        failed.* = link.scan_req.req.err;
        if (failed.* != 0 or link.scan_req.data_length == 0) return 0;
        const lists: [*]const [*]const TagItem = @ptrCast(@alignCast(link.scan_req.stat_data orelse return 0));
        return gather(link.utility, lists[0..link.scan_req.data_length], into);
    }

    /// The network the station is on, into `into`; false while it is on
    /// none.
    pub fn joined(link: *Link, into: *Joined) bool {
        if (!link.opened) return false;
        const sys = link.sys;
        const pool = sys.CreatePool(exec.MEMF_ANY, 512, 256) orelse return false;
        defer sys.DeletePool(pool);
        link.req.req.command = wireless.S2_GETNETWORKINFO;
        link.req.data = pool;
        link.req.stat_data = null;
        _ = sys.DoIO(&link.req.req);
        if (link.req.req.err != 0) return false;
        const tags: [*]const TagItem = @ptrCast(@alignCast(link.req.stat_data orelse return false));
        const utility = link.utility;
        into.* = .{};
        const ssid: [*:0]const u8 = @ptrFromInt(utility.GetTagData(wireless.S2INFO_SSID, @intFromPtr(""), tags));
        _ = text.copyInto(&into.ssid, text.spanOf(ssid));
        const bssid = utility.GetTagData(wireless.S2INFO_BSSID, 0, tags);
        if (bssid != 0) into.bssid = @as(*const [6]u8, @ptrFromInt(bssid)).*;
        into.channel = @truncate(utility.GetTagData(wireless.S2INFO_Channel, 0, tags));
        into.signal = @truncate(@as(isize, @bitCast(utility.GetTagData(wireless.S2INFO_Signal, 0, tags))));
        into.auth = @truncate(utility.GetTagData(wireless.S2INFO_AuthMode, wireless.S2AUTH_OTHER, tags));
        return true;
    }

    /// The signal heard from the access point now, in dBm; null while the
    /// station is on no network, or the device does not say.
    pub fn signal(link: *Link) ?i32 {
        if (!link.opened) return null;
        var quality: wireless.Sana2SignalQuality = .{};
        link.req.req.command = wireless.S2_GETSIGNALQUALITY;
        link.req.stat_data = &quality;
        _ = link.sys.DoIO(&link.req.req);
        if (link.req.req.err != 0) return null;
        return quality.signal_level;
    }

    /// The network `ssid` asked for, with `passphrase` for a protected
    /// one: the device's error, 0 when it took the request - whether the
    /// station gets on comes after.
    pub fn join(link: *Link, ssid: [*:0]const u8, passphrase: ?[*:0]const u8) i8 {
        if (!link.opened) return exec.IOERR_OPENFAIL;
        var tags = [_]TagItem{ .{ .tag = wireless.S2INFO_SSID, .data = @intFromPtr(ssid) }, .{}, .{} };
        if (passphrase) |given| tags[1] = .{ .tag = wireless.S2INFO_Passphrase, .data = @intFromPtr(given) };
        return link.setOptions(&tags);
    }

    /// The network the station is on left, and no longer asked for.
    pub fn leave(link: *Link) i8 {
        if (!link.opened) return exec.IOERR_OPENFAIL;
        const tags = [_]TagItem{ .{ .tag = wireless.S2INFO_Disassociate, .data = 1 }, .{} };
        return link.setOptions(&tags);
    }

    fn setOptions(link: *Link, tags: []const TagItem) i8 {
        link.req.req.command = wireless.S2_SETOPTIONS;
        link.req.data = @constCast(tags.ptr);
        _ = link.sys.DoIO(&link.req.req);
        return link.req.req.err;
    }
};

/// A scan's access points, a tag list each, gathered into one network per
/// name - the strongest one's - strongest first; an access point that
/// gives no name is left out, since a station joins by name. How many
/// there are.
pub fn gather(utility: *UtilityBase, lists: []const [*]const TagItem, into: *[max_networks]Network) usize {
    var count: usize = 0;
    for (lists) |tags| {
        const ssid: [*:0]const u8 = @ptrFromInt(utility.GetTagData(wireless.S2INFO_SSID, @intFromPtr(""), tags));
        const name = text.spanOf(ssid);
        if (name.len == 0 or name.len > ssid_max) continue;
        const channel = utility.GetTagData(wireless.S2INFO_Channel, 0, tags);
        const heard: i32 = @truncate(@as(isize, @bitCast(utility.GetTagData(wireless.S2INFO_Signal, 0, tags))));
        const auth: u32 = @truncate(utility.GetTagData(wireless.S2INFO_AuthMode, wireless.S2AUTH_OTHER, tags));
        add(into, &count, name, heard, @truncate(channel), auth);
    }
    sortBySignal(into[0..count]);
    return count;
}

/// An access point taken into the networks: a name not yet there is
/// added, one that is takes its signal, channel and way in when it is the
/// stronger, and its band either way.
pub fn add(into: *[max_networks]Network, count: *usize, name: []const u8, heard: i32, channel: u32, auth: u32) void {
    for (into[0..count.*]) |*network| {
        if (!text.same(network.name(), name)) continue;
        network.bands |= bandOf(channel);
        if (heard > network.signal) {
            network.signal = heard;
            network.channel = channel;
            network.auth = auth;
        }
        return;
    }
    if (count.* == into.len) return;
    const network = &into[count.*];
    network.* = .{ .signal = heard, .channel = channel, .auth = auth, .bands = bandOf(channel) };
    _ = text.copyInto(&network.ssid, name);
    count.* += 1;
}

fn sortBySignal(networks: []Network) void {
    var at: usize = 1;
    while (at < networks.len) : (at += 1) {
        const one = networks[at];
        var place = at;
        while (place > 0 and networks[place - 1].signal < one.signal) : (place -= 1) networks[place] = networks[place - 1];
        networks[place] = one;
    }
}

const testing = @import("std").testing;

test "access points gathered by name: the strongest one's channel and way in, every band" {
    var networks: [max_networks]Network = undefined;
    var count: usize = 0;
    add(&networks, &count, "Home", -70, 1, wireless.S2AUTH_WPA2_PSK);
    add(&networks, &count, "Cafe", -50, 6, wireless.S2AUTH_OPEN);
    add(&networks, &count, "Home", -40, 36, wireless.S2AUTH_WPA2_WPA3_PSK);
    add(&networks, &count, "Home", -80, 11, wireless.S2AUTH_WPA2_PSK);
    sortBySignal(networks[0..count]);
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqualStrings("Home", networks[0].name());
    try testing.expectEqual(@as(i32, -40), networks[0].signal);
    try testing.expectEqual(@as(u32, 36), networks[0].channel);
    try testing.expectEqual(wireless.S2AUTH_WPA2_WPA3_PSK, networks[0].auth);
    try testing.expectEqual(BAND_2G | BAND_5G, networks[0].bands);
    try testing.expectEqualStrings("Cafe", networks[1].name());
    try testing.expect(networks[1].open());
    try testing.expectEqual(BAND_2G, networks[1].bands);
}
