// SPDX-License-Identifier: MIT
//! The Wi-Fi firmware brought up, once it runs (A69C:8801): from its
//! registers to a station interface.
//!
//! **In order** (`bringUp`): the registers it needs; the stack started;
//! its version asked; the transmit power levels and the RF calibration;
//! the MAC address from its eFuse; the MAC reset; the MAC's version; its
//! capabilities (`ME_CONFIG` - one stream, HT at 20 and 40 MHz, no VHT or
//! HE); the channels it may use (`ME_CHAN_CONFIG` - 1 to 13, and at 5
//! GHz 36 to 48, where the stick has the band); the MAC started; the
//! coexistence with Bluetooth; and a station interface added, whose
//! number every later message names.
//!
//! The values - the calibration, the power levels, the registers - are
//! this chip's: the firmware is tuned to them, and none of them is a
//! choice of the host's.

const msg = @import("msg.zig");
const lmac = @import("lmac.zig");

/// What the bring-up found.
pub const Station = struct {
    /// The firmware's version, as it says it.
    version: [64:0]u8 = @splat(0),
    /// The address from the eFuse; null where it holds none.
    mac: ?[6]u8 = null,
    /// Whether the stick has the 5 GHz band.
    has_5g: bool = false,
    /// The station interface's number.
    vif: u8 = 0,
};

/// Everything up to the station interface, with `address` - the eFuse's,
/// unless the caller gives one - as its address. `address` is filled in.
pub fn bringUp(c: *lmac.Caller, station: *Station, address: *[6]u8) lmac.Error!void {
    // The registers: the revision read again, the clocks, a gate.
    const chip = try c.readMem(0x40500000);
    const sub = try c.readMem(0x00000004);
    if (@as(u8, @truncate(chip >> 16)) == 7 and @as(u8, @truncate(sub >> 4)) == 0x20) {
        for (system_u04) |pair| try c.writeMem(pair[0], pair[1]);
    }
    try c.writeMem(0x40500014, 0x00000101);
    try c.writeMem(0x40500018, 0x0000010D);
    try c.writeMem(0x40500004, 0x00000010);
    try c.maskWrite(0x40506024, 0x000000FF, 0x000000DF);

    // The stack: started, Bluetooth's vendor information as it says, no
    // trace redirected.
    var started: [2]u8 = @splat(0);
    _ = try c.call(lmac.MM_SET_STACK_START_REQ, &.{ 1, 0, 0x20, 0 }, lmac.MM_SET_STACK_START_CFM, &started);
    station.has_5g = started[0] != 0;

    var version: [64]u8 = @splat(0);
    _ = try c.call(lmac.MM_GET_FW_VERSION_REQ, &.{0}, lmac.MM_GET_FW_VERSION_CFM, &version);
    const length = @min(version[0], station.version.len);
    @memcpy(station.version[0..length], version[1..][0..length]);

    // The power levels: enabled; DSSS, then OFDM at 2.4 GHz by
    // modulation, then at 5 GHz.
    try c.tell(lmac.MM_SET_TXPWR_IDX_LVL_REQ, &.{ 1, 9, 8, 8, 8, 8, 11, 10, 9, 9 }, lmac.MM_SET_TXPWR_IDX_LVL_CFM);

    // The RF calibration: what to calibrate at each band, its parameters,
    // the crystal's trim left as it is.
    var calib: [24]u8 = @splat(0);
    msg.put32(&calib, 0, 0xBF);
    msg.put32(&calib, 4, 0x3F);
    msg.put32(&calib, 8, 0x0C34C008);
    msg.put32(&calib, 12, 0);
    msg.put32(&calib, 16, 0x00264203);
    var gains: [16]u8 = undefined;
    _ = try c.call(lmac.MM_SET_RF_CALIB_REQ, &calib, lmac.MM_SET_RF_CALIB_CFM, &gains);

    var mac: [6]u8 = @splat(0);
    _ = try c.call(lmac.MM_GET_MAC_ADDR_REQ, &.{ 1, 0, 0, 0 }, lmac.MM_GET_MAC_ADDR_CFM, &mac);
    if (mac[0] | mac[1] | mac[2] | mac[3] != 0) station.mac = mac;
    if (station.mac) |own| {
        if (address[0] | address[1] | address[2] | address[3] | address[4] | address[5] == 0) address.* = own;
    }

    try c.tell(lmac.MM_RESET_REQ, &.{}, lmac.MM_RESET_CFM);
    var mac_version: [28]u8 = undefined;
    _ = try c.call(lmac.MM_VERSION_REQ, &.{}, lmac.MM_VERSION_CFM, &mac_version);

    try c.tell(lmac.ME_CONFIG_REQ, &meConfig(), lmac.ME_CONFIG_CFM);
    try c.tell(lmac.ME_CHAN_CONFIG_REQ, &channels(station.has_5g), lmac.ME_CHAN_CONFIG_CFM);

    // The MAC started: no PHY settings of the host's, U-APSD's timeout,
    // the sleep clock's accuracy.
    var start: [72]u8 = @splat(0);
    msg.put32(&start, 64, 300);
    start[68] = 20;
    try c.tell(lmac.MM_START_REQ, &start, lmac.MM_START_CFM);

    // Bluetooth on beside it, CTS to itself before Bluetooth's turns.
    var coex: [16]u8 = @splat(0);
    coex[0] = 1;
    coex[2] = 1;
    try c.tell(lmac.MM_SET_COEX_REQ, &coex, lmac.MM_SET_COEX_CFM);

    // A station interface.
    var add: [10]u8 = @splat(0);
    add[0] = 0;
    @memcpy(add[2..8], address);
    var added: [2]u8 = @splat(0xFF);
    _ = try c.call(lmac.MM_ADD_IF_REQ, &add, lmac.MM_ADD_IF_CFM, &added);
    if (added[0] != 0) return lmac.Error.NoAnswer;
    station.vif = added[1];
}

/// `ME_CONFIG_REQ`: the station's capabilities, 112 bytes.
fn meConfig() [112]u8 {
    var config: [112]u8 = @splat(0);
    // HT: the capability word, the A-MPDU parameters, the MCS set - MCS 0
    // to 7, and 32, at most 150 Mbit/s.
    config[0] = 0x63;
    config[1] = 0x09;
    config[2] = 0x1F;
    config[3] = 0xFF;
    config[3 + 4] = 0x01;
    config[3 + 10] = 150;
    config[3 + 12] = 0x01;
    // The frames' lifetime, the widest channel (40 MHz), HT on, VHT and
    // HE off, power save and antenna diversity allowed.
    config[100] = @truncate(1000);
    config[101] = 1000 >> 8;
    config[102] = 1;
    config[103] = 1;
    config[104] = 0;
    config[105] = 0;
    config[106] = 0;
    config[107] = 1;
    config[108] = 1;
    config[109] = 0;
    return config;
}

/// `ME_CHAN_CONFIG_REQ`: 14 places at 2.4 GHz from byte 0, 28 at 5 GHz
/// from byte 84, then how many of each are used.
fn channels(has_5g: bool) [254]u8 {
    var list: [254]u8 = @splat(0);
    for (1..14) |number| {
        lmac.putChannel(&list, (number - 1) * lmac.channel_bytes, lmac.freq2g4(@intCast(number)), lmac.BAND_2G4, 0, 20);
    }
    list[252] = 13;
    if (has_5g) {
        for ([_]u16{ 36, 40, 44, 48 }, 0..) |number, i| {
            lmac.putChannel(&list, 84 + i * lmac.channel_bytes, lmac.freq5g(number), lmac.BAND_5G, 0, 20);
        }
        list[253] = 4;
    }
    return list;
}

/// Revision U04 again, as at the boot ROM.
const system_u04 = [_][2]u32{
    .{ 0x40040000, 0x0000042C }, .{ 0x40040004, 0x0000DD44 },
    .{ 0x40040008, 0x00000448 }, .{ 0x4004000C, 0x0000044C },
    .{ 0x0019B800, 0xB9F0F19B }, .{ 0x0019B804, 0x0019B81D },
    .{ 0x0019B808, 0xBF00FA79 }, .{ 0x0019B80C, 0xF007BF00 },
    .{ 0x0019B810, 0x4605B672 }, .{ 0x0019B814, 0x21E0F04F },
    .{ 0x0019B818, 0xBE0BF664 }, .{ 0x0019B81C, 0xF665B510 },
    .{ 0x0019B820, 0x4804FC9D }, .{ 0x0019B824, 0xFA9EF66C },
    .{ 0x0019B828, 0xFCA8F665 }, .{ 0x0019B82C, 0x4010E8BD },
    .{ 0x0019B830, 0xBAC6F66C }, .{ 0x0019B834, 0x0019A0C4 },
    .{ 0x40040084, 0x0019B800 }, .{ 0x40040080, 0x0000000F },
    .{ 0x40100058, 0x00000000 },
};
