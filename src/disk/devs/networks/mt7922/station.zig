// SPDX-License-Identifier: MIT
//! The radio made ready once its firmware runs: the MAC's registers,
//! what the firmware is told at its start, and the station.
//!
//! **In this order**, the chip's: the temperature at which the card
//! sends on fewer streams, the calibration taken from the card's own
//! fuses, the MAC's receive path - frames up to 1536 bytes, data frames'
//! headers made Ethernet ones and their aggregates taken apart by the
//! chip, the counters of every station entry cleared, the signal
//! measured on each frame - then the deep sleep switched off, the MAC
//! on, the channels the radio may use (scan.zig), the receiving chains
//! on the first channel, the card's own power limits, the radio's LED,
//! the station's interface and its network entry, and the frames it is
//! to be given.
//!
//! **The power limits** are the card's own: every rate is given the
//! highest value there is, which leaves it to the limits the card's
//! calibration and the firmware's tables hold.
//!
//! **Deep sleep is off** for as long as the device runs: the card is
//! woken by nothing else, so the radio stays on and the driver keeps the
//! chip, at the cost of the power a sleeping radio would save.
//!
//! Only band 0 is set up: the MT7922 has one.

const sdk = @import("sdk");
const _mt = @import("_mt7922.zig");
const regs_file = @import("regs.zig");
const mcu = @import("mcu.zig");
const scan = @import("scan.zig");
const Work = _mt.Work;
const say = _mt.say;

pub const Error = error{Refused} || mcu.Error;

/// The station's entry in the chip's table of stations, which its
/// network's group frames are counted against; the table has 20.
pub const WCID_STATION = 19;
const wtbl_entries = 20;

/// The country the firmware is told: none in particular.
const country = [4]u8{ '0', '0', 0, 0 };

pub fn setUp(work: *Work) Error!void {
    try chipConfig(work, "DowngradeTxStreamTemp 105 115");
    _ = try mcu.send(work, mcu.ext(mcu.EXT_EFUSE_BUFFER_MODE), &[_]u8{ 0, 1, 0, 0 }, true);
    try macInit(work);
    try chipConfig(work, "KeepFullPwr 1");
    _ = try mcu.send(work, mcu.ext(mcu.EXT_MAC_INIT_CTRL), &[_]u8{ 1, 0, 0, 0 }, true);
    try channelDomain(work);
    try rxPath(work);
    try txPower(work, scan.BAND_2G4);
    if (work.has_5g) try txPower(work, scan.BAND_5G);
    _ = try mcu.send(work, mcu.ext(mcu.EXT_RADIO_ON_OFF_CTRL), &[_]u8{ RADIO_LED_ENABLE, 0, 0, 0 }, false);
    _ = try mcu.send(work, mcu.ext(mcu.EXT_RADIO_ON_OFF_CTRL), &[_]u8{ RADIO_LED_ON, 0, 0, 0 }, false);
    try addInterface(work);
    try rxFilter(work);
}

const RADIO_LED_ENABLE = 1;
const RADIO_LED_ON = 2;

/// A setting of the firmware's, as its text: "name value".
fn chipConfig(work: *Work, comptime text: []const u8) Error!void {
    var payload: [328]u8 = @splat(0);
    @memcpy(payload[8..][0..text.len], text);
    _ = try mcu.send(work, mcu.ce(mcu.CE_CHIP_CONFIG), &payload, false);
}

/// The MAC's receive path and its station table, and the length a frame
/// is protected from above.
fn macInit(work: *Work) Error!void {
    const regs = work.regs;
    regs.rmwFar(regs_file.MDP_DCR1, regs_file.MAX_RX_LEN_MASK, max_rx_len << regs_file.MAX_RX_LEN_SHIFT);
    regs.rmwFar(regs_file.MDP_DCR0, 0, regs_file.MDP_DCR0_DAMSDU_EN | regs_file.MDP_DCR0_RX_HDR_TRANS_EN);
    for (0..wtbl_entries) |entry| clearCounts(work, @intCast(entry));

    regs.rmwFar(regs_file.TMAC_CTCR0, regs_file.CTCR0_INS_DDLMT_REFTIME, 0x3f);
    regs.rmwFar(regs_file.TMAC_CTCR0, 0, regs_file.CTCR0_INS_DDLMT_VHT_SMPDU_EN | regs_file.CTCR0_INS_DDLMT_EN);
    regs.rmwFar(regs_file.RMAC_MIB_TIME0, 0, regs_file.RMAC_MIB_RXTIME_EN);
    regs.rmwFar(regs_file.RMAC_MIB_AIRTIME0, 0, regs_file.RMAC_MIB_RXTIME_EN);
    regs.rmwFar(regs_file.MIB_SCR1, 0, regs_file.MIB_TXDUR_EN | regs_file.MIB_RXDUR_EN);
    // The long rate report off: the chip's is not to be relied on.
    regs.rmwFar(regs_file.DMA_DCR0, regs_file.MAX_RX_LEN_MASK | regs_file.DMA_DCR0_RXD_G5_EN, max_rx_len << regs_file.MAX_RX_LEN_SHIFT);
    // Each frame's own signal, the frames that answer nothing left out.
    regs.rmwFar(regs_file.WTBLOFF_TOP_RSCR, regs_file.RSCR_RCPI_MODE | regs_file.RSCR_RCPI_PARAM, 3 << regs_file.RSCR_RCPI_PARAM_SHIFT);

    // An RTS before every frame longer than 2347 bytes.
    var protect: [12]u8 = @splat(0);
    protect[0] = 1;
    mcu.put32(&protect, 4, 0x92b);
    mcu.put32(&protect, 8, 2);
    _ = try mcu.send(work, mcu.ext(mcu.EXT_PROTECT_CTRL), &protect, true);
}

const max_rx_len = 1536;

/// A station entry's counters cleared.
pub fn clearCounts(work: *Work, entry: u16) void {
    work.regs.rmwFar(regs_file.WTBL_UPDATE, regs_file.WTBL_UPDATE_WLAN_IDX, entry | regs_file.WTBL_UPDATE_ADM_COUNT_CLEAR);
    _ = work.pollFar(regs_file.WTBL_UPDATE, regs_file.WTBL_UPDATE_BUSY, 0, 5);
}

/// The channels the radio may use, and what each allows.
fn channelDomain(work: *Work) Error!void {
    var payload: [12 + scan.channels.len * 8]u8 = @splat(0);
    @memcpy(payload[0..4], &country);
    payload[4] = 0; // 2.4 GHz: 20 and 40 MHz
    payload[5] = 3; // 5 GHz: up to 160 MHz
    payload[6] = 3;
    const count: usize = if (work.has_5g) scan.channels.len else scan.channels_2g4;
    payload[8] = scan.channels_2g4;
    payload[9] = @intCast(count - scan.channels_2g4);
    for (scan.channels[0..count], 0..) |channel, index| {
        const at = 12 + index * 8;
        mcu.put16(&payload, at, channel.number);
        mcu.put32(&payload, at + 4, channel.flags);
    }
    _ = try mcu.send(work, mcu.ce(mcu.CE_SET_CHAN_DOMAIN), payload[0 .. 12 + count * 8], false);
}

/// The receiving chains on channel 1, 20 MHz wide.
fn rxPath(work: *Work) Error!void {
    var payload: [76]u8 = @splat(0);
    payload[0] = 1;
    payload[1] = 1;
    payload[3] = work.streams;
    payload[4] = chainMask(work);
    _ = try mcu.send(work, mcu.ext(mcu.EXT_SET_RX_PATH), &payload, true);
}

/// The card's receiving chains, a bit each.
pub fn chainMask(work: *const Work) u8 {
    const streams = @min(work.streams, 4);
    return @intCast((@as(u16, 1) << @intCast(streams)) - 1);
}

/// The power limits of a band's channels, eight to a message. After each
/// a register is read through the firmware, which keeps its buffers
/// from running dry.
fn txPower(work: *Work, band: u8) Error!void {
    const list = if (band == scan.BAND_2G4) &power_2g4 else &power_5g;
    const last_band = if (work.has_5g) scan.BAND_5G else scan.BAND_2G4;
    var at: usize = 0;
    while (at < list.len) {
        const count: usize = @min(power_batch, list.len - at);
        const payload = &work.scratch;
        @memset(payload[0..power_header], 0);
        payload[4] = @intCast(count);
        payload[5] = band;
        @memcpy(payload[8..12], &country);
        for (0..count) |index| {
            const entry = payload[power_header + index * power_entry ..][0..power_entry];
            entry[0] = list[at + index];
            @memset(entry[1..], 127);
        }
        if (band == last_band and at + count == list.len) payload[6] = 1;
        _ = try mcu.send(work, mcu.ce(mcu.CE_SET_RATE_TX_POWER), payload[0 .. power_header + count * power_entry], false);
        var read: [8]u8 = @splat(0);
        mcu.put32(&read, 0, regs_file.PSE_BASE);
        _ = try mcu.send(work, mcu.ceQuery(mcu.CE_REG_READ), &read, true);
        at += count;
    }
}

const power_batch = 8;
const power_header = 44;
const power_entry = 162;
pub const power_bytes = power_header + power_batch * power_entry;

const power_2g4 = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 };
const power_5g = [_]u8{
    36,  38,  40,  42,  44,  46,  48,  50,  52,  54,  56,  58,  60,  62,
    64,  100, 102, 104, 106, 108, 110, 112, 114, 116, 118, 120, 122, 124,
    126, 128, 132, 134, 136, 138, 140, 142, 144, 149, 151, 153, 155, 157,
    159, 161, 165, 169, 173, 177,
};

/// The station's interface, then its network entry, which the firmware
/// keeps for the network it joins; its group entry's counters cleared.
fn addInterface(work: *Work) Error!void {
    var device: [16]u8 = @splat(0);
    mcu.put16(&device, 4, 0); // DEV_INFO_ACTIVE
    mcu.put16(&device, 6, 12);
    device[8] = 1;
    @memcpy(device[10..16], &work.station);
    try uni(work, mcu.UNI_DEV_INFO_UPDATE, &device);

    var bss: [4 + 32]u8 = @splat(0);
    mcu.put16(&bss, 4, 0); // BSS_INFO_BASIC
    mcu.put16(&bss, 6, 32);
    bss[8] = 1; // active
    mcu.put32(&bss, 12, CONNECTION_INFRA_STA);
    bss[16] = 1; // not connected
    try uni(work, mcu.UNI_BSS_INFO_UPDATE, &bss);
    clearCounts(work, WCID_STATION);
}

const CONNECTION_INFRA_STA: u32 = 0x00010001;

/// A unified command, its answer's status checked.
pub fn uni(work: *Work, id: u8, payload: []const u8) Error!void {
    const answer = (try mcu.send(work, mcu.uni(id), payload, true)).?;
    const status = answer.payload();
    if (status.len >= 8 and mcu.get32(status, 4) != 0) {
        say(work.sys, "the firmware refuses command %x: %x", .{ @as(u32, id), mcu.get32(status, 4) });
        return error.Refused;
    }
}

/// The frames the station is given: every one its MAC takes.
fn rxFilter(work: *Work) Error!void {
    var payload: [68]u8 = @splat(0);
    payload[4] = 1;
    mcu.put32(&payload, 8, 0x80000000);
    _ = try mcu.send(work, mcu.ce(mcu.CE_SET_RX_FILTER), &payload, false);
}
