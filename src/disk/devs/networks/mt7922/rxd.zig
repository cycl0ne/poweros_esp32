// SPDX-License-Identifier: MIT
//! What the chip says about a frame it received: the receive descriptor
//! in front of it.
//!
//! **The descriptor** is six words, then the groups the second word says
//! follow, in this order: the frame's header words (group 4, four words),
//! its security (group 1, four), its time (group 2, two), its rate and
//! signal (group 3, two) and, inside that, the long rate report (group 5,
//! eighteen), which this device turns off. The frame starts after them,
//! moved on by the pad the third word counts in two-byte steps.
//!
//! **The channel** the radio was on is in the fourth word: up to 14 a
//! 2.4 GHz channel, up to 180 a 5 GHz one, above that 6 GHz in steps of
//! four from 181. **The signal** is the channels' RCPI in group 3, half a
//! dB per step from -110 dBm, the chains the card has combined: the
//! stronger one, raised as the weaker comes near it.

const mcu = @import("mcu.zig");

const descriptor_words = 6;

const RXD0_LENGTH: u32 = 0xffff;
const RXD1_GROUP_1: u32 = 1 << 11;
const RXD1_GROUP_2: u32 = 1 << 12;
const RXD1_GROUP_3: u32 = 1 << 13;
const RXD1_GROUP_4: u32 = 1 << 14;
const RXD1_GROUP_5: u32 = 1 << 15;
const RXD1_SEC_MODE_SHIFT: u5 = 16;
const RXD1_CM: u32 = 1 << 23;
const RXD1_CLM: u32 = 1 << 24;
const RXD1_ICV_ERR: u32 = 1 << 25;
const RXD1_FCS_ERR: u32 = 1 << 27;
const RXD1_BAND_IDX: u32 = 1 << 28;
const RXD2_HDR_TRANS: u32 = 1 << 13;
const RXD2_HDR_OFFSET_SHIFT: u5 = 14;
const RXD2_AMSDU_ERR: u32 = 1 << 23;
const RXD2_MAX_LEN_ERROR: u32 = 1 << 24;
const RXD3_CH_FREQ_SHIFT: u5 = 8;

/// A frame the chip received, and what its descriptor says of it.
pub const Received = struct {
    /// The frame: an 802.11 one, or an Ethernet one when the chip
    /// translated its header.
    frame: []const u8,
    translated: bool,
    /// Decrypted by the chip, its security header and check taken off.
    decrypted: bool,
    channel: u8,
    /// dBm; -128 when the descriptor has no signal.
    signal: i8,
};

/// The frame in `bytes` - a buffer of the data ring - and what its
/// descriptor says; null for one the chip marks as broken, or cut short.
/// `chains` are the card's receiving chains, a bit each.
pub fn read(bytes: []const u8, chains: u8) ?Received {
    if (bytes.len < descriptor_words * 4) return null;
    const rxd0 = mcu.get32(bytes, 0);
    const rxd1 = mcu.get32(bytes, 4);
    const rxd2 = mcu.get32(bytes, 8);
    const rxd3 = mcu.get32(bytes, 12);
    if (rxd1 & (RXD1_BAND_IDX | RXD1_FCS_ERR | RXD1_ICV_ERR) != 0) return null;
    if (rxd2 & (RXD2_AMSDU_ERR | RXD2_MAX_LEN_ERROR) != 0) return null;
    const translated = rxd2 & RXD2_HDR_TRANS != 0;
    if (translated and rxd1 & RXD1_CM != 0) return null;
    const length = @min(@as(usize, rxd0 & RXD0_LENGTH), bytes.len);

    var words: usize = descriptor_words;
    if (rxd1 & RXD1_GROUP_4 != 0) words += 4;
    if (rxd1 & RXD1_GROUP_1 != 0) words += 4;
    if (rxd1 & RXD1_GROUP_2 != 0) words += 2;
    var signal: i8 = -128;
    if (rxd1 & RXD1_GROUP_3 != 0) {
        const vector = words;
        words += 2;
        var rcpi_word = vector + 1;
        if (rxd1 & RXD1_GROUP_5 != 0) {
            rcpi_word = words + 6;
            words += 18;
        }
        if (rcpi_word * 4 + 4 > length) return null;
        signal = combined(mcu.get32(bytes, rcpi_word * 4), chains);
    }
    const start = words * 4 + 2 * @as(usize, (rxd2 >> RXD2_HDR_OFFSET_SHIFT) & 0x3);
    if (start >= length) return null;
    const sec_mode = (rxd1 >> RXD1_SEC_MODE_SHIFT) & 0x1f;
    return .{
        .frame = bytes[start..length],
        .translated = translated,
        .decrypted = sec_mode != 0 and rxd1 & (RXD1_CLM | RXD1_CM) == 0,
        .channel = channelOf(@truncate(rxd3 >> RXD3_CH_FREQ_SHIFT)),
        .signal = signal,
    };
}

/// The channel the descriptor's channel field names.
fn channelOf(value: u8) u8 {
    if (value <= 180) return value;
    return @truncate((@as(u16, value) - 181) * 4 + 1);
}

/// The chains' RCPI combined into one signal, in dBm.
fn combined(rcpi: u32, chains: u8) i8 {
    var signal: i32 = -128;
    for (0..4) |chain| {
        if (chains & (@as(u8, 1) << @intCast(chain)) == 0) continue;
        const value: i32 = @intCast((rcpi >> @intCast(chain * 8)) & 0xff);
        var current = @divTrunc(value - 220, 2);
        if (current > 0) continue;
        if (current > signal) {
            const stronger = current;
            current = signal;
            signal = stronger;
        }
        const below = signal - current;
        if (below == 0) {
            signal += 3;
        } else if (below <= 2) {
            signal += 2;
        } else if (below <= 6) {
            signal += 1;
        }
    }
    return @intCast(@max(-128, @min(127, signal)));
}
