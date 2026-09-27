// SPDX-License-Identifier: MIT
//! Wireless network devices (devices/sana2wireless.h): the requests a
//! radio's unit takes beside the network device API's (network.zig), to
//! find networks, join one and see how the link is. wifi.device speaks
//! them.
//!
//! Information goes both ways as tag lists of `S2INFO_*`. What a device
//! hands back - a scan's networks, the current one - it builds in an exec
//! memory pool the caller gives (`ios2_Data`), so the caller frees it all
//! by deleting the pool.
//!
//!   S2_GETNETWORKS       Scan. ios2_Data: the pool; ios2_StatData: a tag
//!                        list of what to scan for (S2INFO_SSID: only that
//!                        network) or null. Answered when the scan is done:
//!                        ios2_StatData an array of tag lists, one per
//!                        network, ios2_DataLength how many.
//!   S2_SETOPTIONS        ios2_Data: a tag list. S2INFO_SSID and
//!                        S2INFO_Passphrase join that network (the device
//!                        does the key handshake), S2INFO_BSSID picks one
//!                        access point of it, S2INFO_Disassociate leaves.
//!                        Answered at once; whether the join worked comes
//!                        as S2EVENT_ONLINE (or its absence) on S2_ONEVENT.
//!   S2_GETNETWORKINFO    ios2_Data: the pool. ios2_StatData: a tag list
//!                        of the network joined. S2ERR_OUTOFSERVICE if none.
//!   S2_GETSIGNALQUALITY  ios2_StatData: a Sana2SignalQuality, filled.
//!   S2_GETCRYPTTYPES     ios2_Data: the pool. ios2_StatData: an array of
//!                        S2ENC_*, ios2_DataLength long.
//!
//! In a network's tag list: S2INFO_SSID (a C string), S2INFO_BSSID (6
//! bytes), S2INFO_Channel, S2INFO_Signal (dBm, a signed value in ti_Data),
//! S2INFO_Encryption (S2ENC_*, the cipher for its traffic) and
//! S2INFO_AuthMode (S2AUTH_*, how a station proves it may join).
//! S2INFO_AuthMode is this system's: the extension has no tag for the key
//! management a network asks for, and a list of networks is little use
//! without it.

const tagitem = @import("../libs/utility/tagitem.zig");
const TAG_USER = tagitem.TAG_USER;
const TagItem = tagitem.TagItem;
const dos = @import("../libs/dos/dos.zig");
const DosBase = @import("../interface/dos.zig").DosBase;
const ExecBase = @import("../interface/exec.zig").ExecBase;
const network = @import("network.zig");

/// Where a known network's passphrase is kept: a file named after the
/// network in this directory, the passphrase its first line. The interface
/// file names the network and holds no secret, so it can be shown or
/// shared; several networks can be known at once.
pub const NETWORKS_DIRECTORY = "ENVARC:Sys/net/networks/";

/// The longest passphrase: 63 characters, or the key itself in 64 hex
/// digits.
pub const PASSPHRASE_MAX = 64;

/// The passphrase kept for the network `ssid`, NUL-terminated in `into`;
/// null when none is kept (no file, or an empty first line).
pub fn knownPassphrase(dl: *DosBase, ssid: [*:0]const u8, into: *[PASSPHRASE_MAX + 1]u8) ?[*:0]const u8 {
    var path: [NETWORKS_DIRECTORY.len + 33:0]u8 = @splat(0);
    @memcpy(path[0..NETWORKS_DIRECTORY.len], NETWORKS_DIRECTORY);
    var at: usize = 0;
    while (ssid[at] != 0) : (at += 1) {
        if (at == 32) return null;
        path[NETWORKS_DIRECTORY.len + at] = ssid[at];
    }
    const file = dl.Open(@ptrCast(&path), dos.MODE_OLDFILE) orelse return null;
    defer _ = dl.Close(file);
    const got = dl.Read(file, into, into.len);
    if (got <= 0) return null;
    var end: usize = 0;
    while (end < @as(usize, @intCast(got)) and end < PASSPHRASE_MAX and into[end] != '\n' and into[end] != '\r') end += 1;
    while (end > 0 and (into[end - 1] == ' ' or into[end - 1] == '\t')) end -= 1;
    if (end == 0) return null;
    into[end] = 0;
    return @ptrCast(into);
}

/// The copy calls a device wants from every opener; an opener that only
/// sends wireless requests has nothing to copy.
fn noCopy(to: ?*anyopaque, from: ?*const anyopaque, length: u32) callconv(.c) bool {
    _ = .{ to, from, length };
    return false;
}

/// The network `ssid` joined through `device`'s `unit`, with `passphrase`
/// for a protected one: the device opened, S2_SETOPTIONS sent, the device
/// closed. Answers the request's error (0 when the join was taken; whether
/// it worked comes as the link), or the open's.
pub fn join(sys: *ExecBase, device: [*:0]const u8, unit: u32, ssid: [*:0]const u8, passphrase: ?[*:0]const u8) i32 {
    const port = sys.CreateMsgPort() orelse return network.S2ERR_NO_RESOURCES;
    defer sys.DeleteMsgPort(port);
    const buffers = [_]TagItem{
        .{ .tag = network.S2_CopyToBuff, .data = @intFromPtr(&noCopy) },
        .{ .tag = network.S2_CopyFromBuff, .data = @intFromPtr(&noCopy) },
        .{},
    };
    var req: network.IOSana2Req = .{};
    req.req.message.reply_port = port;
    req.req.message.length = @sizeOf(network.IOSana2Req);
    req.buffer_management = @constCast(&buffers);
    const opened = sys.OpenDevice(device, unit, &req.req, 0);
    if (opened != 0) return opened;
    defer sys.CloseDevice(&req.req);
    var tags = [_]TagItem{ .{ .tag = S2INFO_SSID, .data = @intFromPtr(ssid) }, .{}, .{} };
    if (passphrase) |text| tags[1] = .{ .tag = S2INFO_Passphrase, .data = @intFromPtr(text) };
    req.req.command = S2_SETOPTIONS;
    req.data = &tags;
    _ = sys.DoIO(&req.req);
    return req.req.err;
}

// Tags to get and set information.
pub const S2INFO_SSID: u32 = TAG_USER + 0;
pub const S2INFO_BSSID: u32 = TAG_USER + 1;
pub const S2INFO_AuthTypes: u32 = TAG_USER + 2;
pub const S2INFO_AssocID: u32 = TAG_USER + 3;
pub const S2INFO_Encryption: u32 = TAG_USER + 4;
pub const S2INFO_PortType: u32 = TAG_USER + 5;
pub const S2INFO_BeaconInterval: u32 = TAG_USER + 6;
pub const S2INFO_Channel: u32 = TAG_USER + 7;
pub const S2INFO_Signal: u32 = TAG_USER + 8;
pub const S2INFO_Noise: u32 = TAG_USER + 9;
pub const S2INFO_Capabilities: u32 = TAG_USER + 10;
pub const S2INFO_InfoElements: u32 = TAG_USER + 11;
pub const S2INFO_WPAInfo: u32 = TAG_USER + 12;
pub const S2INFO_Band: u32 = TAG_USER + 13;
pub const S2INFO_DefaultKeyNo: u32 = TAG_USER + 14;
/// A network's passphrase: the device derives the key and does the
/// handshake itself.
pub const S2INFO_Passphrase: u32 = TAG_USER + 15;
/// S2_SETOPTIONS: leave the network.
pub const S2INFO_Disassociate: u32 = TAG_USER + 16;
/// How a station proves it may join (S2AUTH_*).
pub const S2INFO_AuthMode: u32 = TAG_USER + 32;

// The commands.
pub const S2_GETSIGNALQUALITY: u16 = 0xC010;
pub const S2_GETNETWORKS: u16 = 0xC011;
pub const S2_SETOPTIONS: u16 = 0xC012;
pub const S2_SETKEY: u16 = 0xC013;
pub const S2_GETNETWORKINFO: u16 = 0xC014;
pub const S2_READMGMT: u16 = 0xC015;
pub const S2_WRITEMGMT: u16 = 0xC016;
pub const S2_GETRADIOBANDS: u16 = 0xC017;
pub const S2_GETCRYPTTYPES: u16 = 0xC018;

// Encryption types.
pub const S2ENC_NONE: u32 = 0;
pub const S2ENC_WEP: u32 = 1;
pub const S2ENC_TKIP: u32 = 2;
pub const S2ENC_CCMP: u32 = 3;

// Radio modes.
pub const S2BAND_A: u32 = 0;
pub const S2BAND_B: u32 = 1;
pub const S2BAND_G: u32 = 2;
pub const S2BAND_N: u32 = 3;

// Network topologies.
pub const S2PORT_MANAGED: u32 = 7;
pub const S2PORT_ADHOC: u32 = 8;

// How a station proves it may join.
pub const S2AUTH_OPEN: u32 = 0;
pub const S2AUTH_WEP: u32 = 1;
pub const S2AUTH_WPA_PSK: u32 = 2;
pub const S2AUTH_WPA2_PSK: u32 = 3;
pub const S2AUTH_WPA_WPA2_PSK: u32 = 4;
pub const S2AUTH_WPA3_PSK: u32 = 5;
pub const S2AUTH_WPA2_WPA3_PSK: u32 = 6;
/// With a server behind the access point (802.1X).
pub const S2AUTH_ENTERPRISE: u32 = 7;
/// Anything else.
pub const S2AUTH_OTHER: u32 = 8;

/// struct Sana2SignalQuality: in dBm.
pub const Sana2SignalQuality = extern struct {
    signal_level: i32 = 0,
    noise_level: i32 = 0,
};
