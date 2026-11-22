// SPDX-License-Identifier: MIT
//! The firmware's messages: a command to the chip's processor (the MCU)
//! and the event that answers it.
//!
//! **A command** goes out on TX ring 17: a 64-byte header - the hardware's
//! descriptor words, then the command's own (its length, its id, a
//! sequence number, whether it sets or asks) - and the payload behind it.
//! The "unified" commands of the running firmware have a 48-byte header
//! of their own. The firmware's code itself goes out on ring 16 as bare
//! data, with no header (`sendData`).
//!
//! **An event** comes in on RX ring 0 (the boot ROM's) or 4 (the running
//! firmware's): the 24-byte receive descriptor, then the event's id, its
//! sequence number and options, its payload at +36. One whose sequence
//! number is a command's is that command's answer; one the firmware sends
//! by itself - its option says so, or its sequence number is 0 - is
//! handed to the radio (radio.zig's `event`), and so is every frame the
//! chip received, on whichever ring it came.
//!
//! The worker sends one command at a time and waits for its answer
//! before the next, up to three seconds; a command not waited for may
//! still be answered, and that answer is passed over by its sequence
//! number.

const sdk = @import("sdk");
const _mt = @import("_mt7922.zig");
const regs_file = @import("regs.zig");
const dma = @import("dma.zig");
const radio = @import("radio.zig");
const Work = _mt.Work;
const Ring = dma.Ring;

/// What kind of command an id is: the boot ROM's and the firmware's
/// plain ones, the "CE" and "extended" ones of the running firmware, and
/// its unified ones.
pub const Kind = enum { plain, ce, ext, uni };

pub const Cmd = struct {
    id: u8,
    kind: Kind = .plain,
    /// A question rather than a setting (CE and extended commands).
    query: bool = false,
};

pub fn plain(id: u8) Cmd {
    return .{ .id = id };
}
pub fn ce(id: u8) Cmd {
    return .{ .id = id, .kind = .ce };
}
pub fn ceQuery(id: u8) Cmd {
    return .{ .id = id, .kind = .ce, .query = true };
}
pub fn ext(id: u8) Cmd {
    return .{ .id = id, .kind = .ext };
}
pub fn extQuery(id: u8) Cmd {
    return .{ .id = id, .kind = .ext, .query = true };
}
pub fn uni(id: u8) Cmd {
    return .{ .id = id, .kind = .uni };
}

// The boot ROM's commands.
pub const TARGET_ADDRESS_LEN_REQ = 0x01;
pub const FW_START_REQ = 0x02;
pub const NIC_POWER_CTRL = 0x04;
pub const PATCH_START_REQ = 0x05;
pub const PATCH_FINISH_REQ = 0x07;
pub const PATCH_SEM_CONTROL = 0x10;
/// The extended commands' id in the header; theirs is the extended id.
const EXT_CID = 0xed;

// The running firmware's.
pub const CE_START_HW_SCAN = 0x03;
pub const CE_SET_RX_FILTER = 0x0a;
pub const CE_SET_CHAN_DOMAIN = 0x0f;
pub const CE_CANCEL_HW_SCAN = 0x1b;
pub const CE_SET_RATE_TX_POWER = 0x5d;
pub const CE_GET_NIC_CAPAB = 0x8a;
pub const CE_REG_READ = 0xc0;
pub const CE_CHIP_CONFIG = 0xca;
pub const EXT_RADIO_ON_OFF_CTRL = 0x05;
pub const EXT_EFUSE_BUFFER_MODE = 0x21;
pub const EXT_PROTECT_CTRL = 0x3e;
pub const EXT_MAC_INIT_CTRL = 0x46;
pub const EXT_SET_RX_PATH = 0x4e;
pub const UNI_DEV_INFO_UPDATE = 0x01;
pub const UNI_BSS_INFO_UPDATE = 0x02;

/// The events.
pub const EVENT_RESPONSE = 0x06;
pub const EVENT_LP_INFO = 0x07;
pub const EVENT_SCAN_DONE = 0x0d;
pub const EVENT_TX_DONE = 0x0f;
pub const EVENT_BSS_BEACON_LOSS = 0x13;
pub const EVENT_SCHED_SCAN_DONE = 0x23;
pub const EVENT_DBG_MSG = 0x27;
pub const EVENT_RSSI_NOTIFY = 0x96;
pub const EVENT_COREDUMP = 0xf0;

/// What a receive descriptor's first word says: the buffer's length, its
/// flag and its type - 7 an event.
const RXD0_PKT_TYPE_SHIFT = 27;
const RXD0_PKT_FLAG_SHIFT = 16;
pub const PKT_TYPE_TXS = 0;
pub const PKT_TYPE_NORMAL = 2;
pub const PKT_TYPE_RX_EVENT = 7;
pub const PKT_TYPE_NORMAL_MCU = 8;
pub const PKT_TYPE_TXRX_NOTIFY = 4;

const legacy_header = 64;
const uni_header = 48;
const event_header = 36;
const option_unsolicited = 1 << 2;

pub const Error = error{ NoRoom, TooLong, NoAnswer };

/// An answer: the whole event, its header included.
pub const Answer = struct {
    event: []const u8,

    /// What follows the event's header.
    pub fn payload(answer: Answer) []const u8 {
        return if (answer.event.len > event_header) answer.event[event_header..] else answer.event[0..0];
    }

    /// The boot ROM's one-byte result (the semaphore, the patch's end).
    pub fn status(answer: Answer) u8 {
        return if (answer.event.len > 32) answer.event[32] else 0xff;
    }
};

/// `payload` sent as `cmd`; with `wait`, its answer.
pub fn send(work: *Work, cmd: Cmd, payload: []const u8, wait: bool) Error!?Answer {
    const ring = &work.tx_wm;
    ring.reclaim(work.regs);
    if (!ring.hasRoom()) return error.NoRoom;
    const header: u32 = if (cmd.kind == .uni) uni_header else legacy_header;
    const total: u32 = header + @as(u32, @intCast(payload.len));
    if (total > ring.buffer_size) return error.TooLong;

    work.seq +%= 1;
    if (work.seq & 0xf == 0) work.seq +%= 1;
    const seq: u8 = work.seq & 0xf;

    const buffer = ring.nextBuffer();
    @memset(buffer[0..header], 0);
    // The hardware's words: the length, a command for the MCU's port.
    put32(buffer, 0, total | 0x41000000);
    put32(buffer, 4, 0x80010000);
    put16(buffer, 32, @intCast(total - 32));
    switch (cmd.kind) {
        .uni => {
            put16(buffer, 34, cmd.id);
            buffer[37] = 0xa0;
            buffer[39] = seq;
            // An answer wanted, a unified command, a setting.
            buffer[43] = 0x07;
        },
        else => {
            put16(buffer, 34, 0x8000);
            buffer[36] = if (cmd.kind == .ext) EXT_CID else cmd.id;
            buffer[37] = 0xa0;
            buffer[38] = switch (cmd.kind) {
                .ce, .ext => if (cmd.query) 0 else 1,
                else => 3,
            };
            buffer[39] = seq;
            if (cmd.kind == .ext) {
                buffer[41] = cmd.id;
                buffer[43] = 1;
            }
        },
    }
    @memcpy(buffer[header..total], payload);
    ring.send(work.regs, @intFromPtr(buffer), total);
    if (!wait) return null;
    return try waitFor(work, seq);
}

/// `bytes` sent to the firmware's ring as they are, in pieces of at most
/// `piece` bytes, nothing waited for but room in the ring. The bytes stay
/// where they are until the ring is through with them, which `drain`
/// waits for.
pub fn sendData(work: *Work, bytes: []const u8, piece: usize) Error!void {
    const ring = &work.tx_fwdl;
    var at: usize = 0;
    while (at < bytes.len) {
        const length = @min(piece, bytes.len - at);
        var waited: u32 = 0;
        ring.reclaim(work.regs);
        while (!ring.hasRoom()) : (waited += 1) {
            if (waited > 3000) return error.NoRoom;
            work.pause(1000);
            ring.reclaim(work.regs);
        }
        // The sequence number goes by, as it does for every command.
        work.seq +%= 1;
        if (work.seq & 0xf == 0) work.seq +%= 1;
        ring.send(work.regs, @intFromPtr(bytes.ptr) + at, @intCast(length));
        at += length;
    }
}

/// Until the firmware's ring has taken everything handed to it.
pub fn drain(work: *Work) bool {
    const ring = &work.tx_fwdl;
    var waited: u32 = 0;
    while (true) : (waited += 1) {
        ring.reclaim(work.regs);
        if (ring.tail == ring.head) return true;
        if (waited > 3000) return false;
        work.pause(1000);
    }
}

/// The event answering `seq`, the others taken as they come; null after
/// three seconds.
fn waitFor(work: *Work, seq: u8) Error!Answer {
    var waited: u32 = 0;
    while (true) : (waited += 1) {
        if (takeEvents(work, seq)) return .{ .event = work.answer[0..work.answer_len] };
        if (waited >= 3000) return error.NoAnswer;
        work.pause(1000);
    }
}

/// Everything the event rings and the frame ring hold, taken: true when
/// the answer to `seq` was among it, which is then in `work.answer`.
/// `seq` 0 waits for no answer.
pub fn takeEvents(work: *Work, seq: u8) bool {
    var found = false;
    for ([_]*Ring{ &work.rx_wm, &work.rx_wm2, &work.rx_data }) |ring| {
        if (takeRing(work, ring, seq)) found = true;
    }
    return found;
}

fn takeRing(work: *Work, ring: *Ring, seq: u8) bool {
    var found = false;
    // A buffer that does not end its frame belongs to one too long for a
    // buffer; it is passed over up to its last.
    var skipping = false;
    while (ring.peek()) |taken| {
        defer ring.next(work.regs);
        if (skipping or !taken.last) {
            skipping = !taken.last;
            continue;
        }
        if (one(work, taken.bytes, seq)) found = true;
    }
    return found;
}

/// One buffer the chip filled: an event, or a frame for the radio.
fn one(work: *Work, bytes: []const u8, seq: u8) bool {
    if (bytes.len < 4) return false;
    const rxd0 = get32(bytes, 0);
    const kind = rxd0 >> RXD0_PKT_TYPE_SHIFT;
    const flag = (rxd0 >> RXD0_PKT_FLAG_SHIFT) & 0xf;
    if (kind != PKT_TYPE_RX_EVENT or flag == 1) {
        radio.received(work, kind, bytes);
        return false;
    }
    if (bytes.len < event_header - 3) return false;
    const eid = bytes[28];
    const event_seq = bytes[29];
    const option = bytes[30];
    const by_itself = option & option_unsolicited != 0 or event_seq == 0 or switch (eid) {
        EVENT_SCAN_DONE, EVENT_SCHED_SCAN_DONE, EVENT_BSS_BEACON_LOSS, EVENT_RSSI_NOTIFY, EVENT_TX_DONE, EVENT_DBG_MSG, EVENT_LP_INFO, EVENT_COREDUMP => true,
        else => false,
    };
    if (by_itself) {
        radio.event(work, eid, bytes);
        return false;
    }
    if (seq == 0 or event_seq != seq) return false;
    const length = @min(bytes.len, work.answer.len);
    @memcpy(work.answer[0..length], bytes[0..length]);
    work.answer_len = @intCast(length);
    return true;
}

pub fn put16(buffer: [*]u8, at: usize, value: u16) void {
    buffer[at] = @truncate(value);
    buffer[at + 1] = @truncate(value >> 8);
}

pub fn put32(buffer: [*]u8, at: usize, value: u32) void {
    buffer[at] = @truncate(value);
    buffer[at + 1] = @truncate(value >> 8);
    buffer[at + 2] = @truncate(value >> 16);
    buffer[at + 3] = @truncate(value >> 24);
}

pub fn get16(bytes: []const u8, at: usize) u16 {
    return @as(u16, bytes[at]) | @as(u16, bytes[at + 1]) << 8;
}

pub fn get32(bytes: []const u8, at: usize) u32 {
    return @as(u32, bytes[at]) | @as(u32, bytes[at + 1]) << 8 | @as(u32, bytes[at + 2]) << 16 | @as(u32, bytes[at + 3]) << 24;
}

pub fn getBe32(bytes: []const u8, at: usize) u32 {
    return @as(u32, bytes[at]) << 24 | @as(u32, bytes[at + 1]) << 16 | @as(u32, bytes[at + 2]) << 8 | @as(u32, bytes[at + 3]);
}
