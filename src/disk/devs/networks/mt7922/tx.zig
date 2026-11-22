// SPDX-License-Identifier: MIT
//! Frames out, on the data ring (TX ring 0): the station's management
//! frames as 802.11 ones at a fixed rate, its data as Ethernet frames the
//! chip turns into 802.11 ones and sends at the rate its firmware picks.
//!
//! **A frame** goes out as a 64-byte block the ring's descriptor points
//! at - the chip's 32-byte transmit descriptor, then the list of where
//! the frame's bytes are - with the frame right behind it in the slot's
//! own buffer. The chip takes the block when the ring passes it, but the
//! frame only when it sends it; so a slot is not used again until the
//! chip says it is through with its frame (a TX-free note), which names
//! the frame by the token the list carries: the slot's number. A slot the
//! chip says nothing of for `lost_ms` is taken back.
//!
//! **Management frames** go on the queue the firmware keeps for them,
//! at the network's slowest basic rate, on every chain. **Data** goes on
//! the queue of its access category: the handshake's frames on the voice
//! one, every other on best effort; with QoS the chip makes them QoS data
//! frames, and once the pairwise key is in it encrypts them.
//!
//! **A frame of the handshake's** keeps the handshake's number in its
//! slot: when the chip is through with it, the handshake is told it has
//! gone (join.zig).
//!
//! **The unit's writes** go out while the station is on a network and the
//! unit is online: each is answered once it is in its slot, and the next
//! is taken when a slot is free again.

const sdk = @import("sdk");
const ethernet = sdk.devices.network.ethernet;
const _mt = @import("_mt7922.zig");
const mcu = @import("mcu.zig");
const dma = @import("dma.zig");
const station = @import("station.zig");
const join = @import("join.zig");
const Work = _mt.Work;

const slots = _mt.tx_data_count;
const block_bytes = 64;
const descriptor_bytes = 32;
/// How long a slot waits for the chip's note before it is taken back.
const lost_ms = 5000;

/// The queues: the firmware's for management frames, the access
/// categories' (best effort, voice) for data.
const Q_MANAGEMENT = 0x10;
const Q_BEST_EFFORT = 1;
const Q_VOICE = 3;
/// The traffic identifiers the two data queues stand for.
pub const TID_BEST_EFFORT = 0;
pub const TID_VOICE = 7;

const TXD0_Q_IDX_SHIFT: u5 = 25;
const TXD1_LONG_FORMAT: u32 = 1 << 31;
const TXD1_TID_SHIFT: u5 = 20;
const TXD1_HDR_FORMAT_802_11: u32 = 2 << 16;
const TXD1_HDR_INFO_SHIFT: u5 = 11;
const TXD1_ETH_802_3: u32 = 1 << 15;
const TXD2_FIX_RATE: u32 = 1 << 31;
const TXD2_HTC_VLD: u32 = 1 << 13;
const TXD2_MULTICAST: u32 = 1 << 10;
const TXD2_FRAME_TYPE_SHIFT: u5 = 4;
const TXD3_BA_DISABLE: u32 = 1 << 28;
const TXD3_REM_TX_COUNT: u32 = 15 << 11;
const TXD3_PROTECT_FRAME: u32 = 1 << 1;
const TXD6_TX_RATE_SHIFT: u5 = 16;
const TXD6_FIXED_BW: u32 = 1 << 2;
const TXD7_TYPE_SHIFT: u5 = 20;
const TXD7_SUB_TYPE_SHIFT: u5 = 16;
const TXD7_SPE_IDX_SHIFT: u5 = 11;
/// No report of the send wanted.
const PID_NO_STATUS = 1;
const FRAME_TYPE_DATA = 2;
const SUB_TYPE_QOS_DATA = 8;
const TXP_TOKEN_VALID: u16 = 1 << 15;
const TXP_LEN_LAST: u16 = 1 << 15;

pub const Sending = struct {
    /// Whether each slot's frame is still the chip's, since when, and the
    /// handshake's number of the frame in it (0 for none).
    busy: [slots]bool = @splat(false),
    since: [slots]u32 = @splat(0),
    numbers: [slots]u32 = @splat(0),
};

/// Where the next frame is written, behind its block: null while no slot
/// is free.
pub fn frameBuffer(work: *Work) ?[]u8 {
    const ring = &work.tx_data;
    ring.reclaim(work.regs);
    if (!ring.hasRoom()) return null;
    const slot = ring.head;
    const sending = &work.sending;
    if (sending.busy[slot]) {
        if (elapsed(work) -% sending.since[slot] < lost_ms) return null;
        release(work, slot);
    }
    return ring.bufferOf(slot)[block_bytes.._mt.tx_buffer];
}

/// The management frame of `length` bytes in the frame buffer sent, to
/// the table entry `wcid`, at the chip's fixed `rate`.
pub fn sendManagement(work: *Work, length: usize, wcid: u16, rate: u16) void {
    const block = work.tx_data.nextBuffer();
    const frame = block[block_bytes..][0..length];
    const kind = frame[0];
    @memset(block[0..block_bytes], 0);
    mcu.put32(block, 0, @as(u32, @intCast(length + descriptor_bytes)) | @as(u32, Q_MANAGEMENT) << TXD0_Q_IDX_SHIFT);
    mcu.put32(block, 4, TXD1_LONG_FORMAT | TXD1_HDR_FORMAT_802_11 | @as(u32, 24 / 2) << TXD1_HDR_INFO_SHIFT | wcid);
    const frame_type: u32 = (kind >> 2) & 0x3;
    const sub_type: u32 = (kind >> 4) & 0xf;
    var word2 = TXD2_FIX_RATE | TXD2_HTC_VLD | frame_type << TXD2_FRAME_TYPE_SHIFT | sub_type;
    if (frame[4] & 1 != 0) word2 |= TXD2_MULTICAST;
    mcu.put32(block, 8, word2);
    mcu.put32(block, 12, TXD3_REM_TX_COUNT | TXD3_BA_DISABLE);
    mcu.put32(block, 20, PID_NO_STATUS);
    mcu.put32(block, 24, TXD6_FIXED_BW | @as(u32, rate) << TXD6_TX_RATE_SHIFT);
    mcu.put32(block, 28, frame_type << TXD7_TYPE_SHIFT | sub_type << TXD7_SUB_TYPE_SHIFT | @as(u32, spreading(work)) << TXD7_SPE_IDX_SHIFT);
    hand(work, length, 0);
}

/// What a data frame asks of the chip.
pub const Data = struct {
    wcid: u16,
    tid: u8 = TID_BEST_EFFORT,
    qos: bool = false,
    /// Encrypted with the entry's key.
    protect: bool = false,
    /// The handshake's number of the frame, 0 for none.
    number: u32 = 0,
};

/// The Ethernet frame of `length` bytes in the frame buffer sent.
pub fn sendData(work: *Work, length: usize, data: Data) void {
    const block = work.tx_data.nextBuffer();
    const frame = block[block_bytes..][0..length];
    @memset(block[0..block_bytes], 0);
    const queue: u32 = if (data.tid == TID_VOICE) Q_VOICE else Q_BEST_EFFORT;
    mcu.put32(block, 0, @as(u32, @intCast(length + descriptor_bytes)) | queue << TXD0_Q_IDX_SHIFT);
    var word1 = TXD1_LONG_FORMAT | @as(u32, data.tid) << TXD1_TID_SHIFT | data.wcid;
    if (mcu.getBe16(frame, 12) >= 0x600) word1 |= TXD1_ETH_802_3;
    mcu.put32(block, 4, word1);
    const sub_type: u32 = if (data.qos) SUB_TYPE_QOS_DATA else 0;
    mcu.put32(block, 8, FRAME_TYPE_DATA << TXD2_FRAME_TYPE_SHIFT | sub_type);
    mcu.put32(block, 12, TXD3_REM_TX_COUNT | if (data.protect) TXD3_PROTECT_FRAME else 0);
    mcu.put32(block, 20, PID_NO_STATUS);
    mcu.put32(block, 28, FRAME_TYPE_DATA << TXD7_TYPE_SHIFT | sub_type << TXD7_SUB_TYPE_SHIFT);
    hand(work, length, data.number);
}

/// The block in the head slot completed with the frame's list, and handed
/// to the chip.
fn hand(work: *Work, length: usize, number: u32) void {
    const ring = &work.tx_data;
    const slot = ring.head;
    const block = ring.bufferOf(slot);
    mcu.put16(block, 32, @as(u16, @intCast(slot)) | TXP_TOKEN_VALID);
    mcu.put32(block, 40, dma.address(@intFromPtr(block + block_bytes)));
    mcu.put16(block, 44, @as(u16, @intCast(length)) | TXP_LEN_LAST);
    const sending = &work.sending;
    sending.busy[slot] = true;
    sending.since[slot] = elapsed(work);
    sending.numbers[slot] = number;
    ring.send(work.regs, @intFromPtr(block), block_bytes);
}

/// Which of the chip's paths a fixed-rate frame takes: every chain the
/// card has.
fn spreading(work: *const Work) u8 {
    const by_chains = [_]u8{ 0, 0, 1, 0, 3, 2, 4, 0, 9, 8, 6, 10, 16, 12, 18, 0 };
    const chains = station.chainMask(work);
    const index = by_chains[chains & 0xf];
    if (index == 0 and @popCount(chains) > 1) return 24;
    return index;
}

/// The chip's note of the frames it is through with: their slots free,
/// and the handshake told of its own.
pub fn freed(work: *Work, bytes: []const u8) void {
    if (bytes.len < 8) return;
    var count: usize = (mcu.get32(bytes, 0) >> 16) & 0x3ff;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const at = 8 + index * 4;
        if (at + 4 > bytes.len) break;
        const info = mcu.get32(bytes, at);
        // A pair names the station the entries after it are for; it is
        // not counted among them.
        if (info & (1 << 31) != 0) {
            count += 1;
            continue;
        }
        const token = (info >> 16) & 0x7fff;
        if (token < slots and work.sending.busy[token]) release(work, token);
    }
    startWrites(work);
}

fn release(work: *Work, slot: u32) void {
    const sending = &work.sending;
    sending.busy[slot] = false;
    const number = sending.numbers[slot];
    sending.numbers[slot] = 0;
    if (number != 0) join.frameGone(work, number);
}

/// The unit's writes waiting, sent while the station is on a network and
/// a slot is free.
pub fn startWrites(work: *Work) void {
    const base = work.base;
    if (!join.carrying(work)) return;
    while (frameBuffer(work)) |buffer| {
        const req = base.net.nextWrite() orelse return;
        const length = base.net.buildFrame(req, buffer[0..ethernet.frame_max]);
        if (length == 0) continue;
        sendData(work, length, join.dataTo(work, TID_BEST_EFFORT));
        base.net.written(req, true);
    }
}

fn elapsed(work: *const Work) u32 {
    return @truncate(work.sys.UptimeUs() / 1000);
}
