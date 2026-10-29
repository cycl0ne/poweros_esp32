// SPDX-License-Identifier: MIT
//! The frames between the host and the chip's firmware, for
//! cyw43455.device: SDPCM, the framing of Broadcom's SDIO firmwares, as
//! Linux's brcmfmac speaks it.
//!
//! **A frame** goes through function 2, all of it to one address - the
//! SDIO core's FIFO - in blocks of 512 bytes and the rest as bytes. It
//! starts with a hardware header, the frame's length and that length
//! inverted, and a software header: the frame's sequence number, its
//! channel (control, event or data) and where its payload starts; and,
//! from the firmware, how long its next frame is, which channels the host
//! may send on, and the highest sequence number it takes now - the
//! host's credit.
//!
//! **Sending** pads a frame to a word, or to whole blocks past one block,
//! and spends a credit: the host sends while its sequence number is short
//! of the firmware's highest.
//!
//! **Receiving** reads a frame's first 64 bytes, which hold its headers,
//! then the rest; a header of zeros says there is no frame left. A frame
//! the host cannot take is ended on the chip's side. Whether the firmware
//! has frames, or wrote to the host's mailbox, the SDIO core's interrupt
//! status says, which the card's interrupt stands for (`poll`).
//!
//! **Coalesced frames** - several in one, on their own channel - the
//! firmware sends only when told it may; nothing here tells it.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const _cyw = @import("_cyw43455.zig");
const host_file = @import("host.zig");
const sdio = @import("sdio.zig");
const backplane = @import("backplane.zig");
const chip_file = @import("chip.zig");
const CywBase = _cyw.CywBase;
const Error = host_file.Error;
const DEVICE_NAME = _cyw.DEVICE_NAME;

/// The channels.
pub const CHANNEL_CONTROL: u8 = 0;
pub const CHANNEL_EVENT: u8 = 1;
pub const CHANNEL_DATA: u8 = 2;
pub const CHANNEL_GLOM: u8 = 3;

/// Both headers: where a sent frame's payload starts.
pub const HEADER = 12;
/// How much of a frame is read before its length is known.
const first_read = 64;
/// Function 2's block size, which the device gives it: Linux's.
pub const block_bytes = 512;
/// The FIFO: chipcommon's place in the window, as a 4-byte access.
const fifo: u32 = (backplane.CHIPCOMMON & backplane.OFFSET_MASK) | backplane.ACCESS_4B;

/// The largest frames: what the firmware answers a command with - up to
/// 8 KiB of its buffer, the headers and the margin Linux leaves - and
/// what the host sends, an Ethernet frame and its headers in whole
/// blocks.
pub const rx_bytes = 12 * 1024;
pub const tx_bytes = 2048;

/// Function 1's registers for ending a frame: the frame control, and the
/// bytes of the frame being read, and written, still in the FIFO.
const F1_FRAMECTRL = 0x1000D;
const F1_WFRAMEBCLO = 0x10019;
const F1_WFRAMEBCHI = 0x1001A;
const F1_RFRAMEBCLO = 0x1001B;
const F1_RFRAMEBCHI = 0x1001C;
const SFC_RF_TERM: u8 = 1 << 0;
const SFC_WF_TERM: u8 = 1 << 1;
/// How often the FIFO is asked whether an ended frame has gone: Linux's.
const rx_term_tries = 0xFFFF;
const tx_term_tries = 3;

/// The SDIO core's interrupts the host takes: the firmware's mailbox ones
/// - flow control, frames for the host, a message in the mailbox - and
/// the chip waking.
const I_HMB_FC_STATE: u32 = 1 << 4;
const I_HMB_FC_CHANGE: u32 = 1 << 5;
const I_HMB_FRAME_IND: u32 = 1 << 6;
const I_HMB_HOST_INT: u32 = 1 << 7;
const I_CHIPACTIVE: u32 = 1 << 29;
pub const host_int_mask = I_HMB_FC_STATE | I_HMB_FC_CHANGE | I_HMB_FRAME_IND | I_HMB_HOST_INT | I_CHIPACTIVE;

/// The host's side of the mailbox: its acknowledgement, and the protocol
/// version it gives the firmware at the start.
const SMB_INT_ACK: u32 = 1 << 1;
pub const SDPCM_PROT_VERSION: u32 = 4;
pub const SMB_DATA_VERSION_SHIFT = 16;
/// The firmware's: ready, halted, and its protocol's version.
const HMB_DATA_DEVREADY: u32 = 0x02;
const HMB_DATA_FWREADY: u32 = 0x08;
const HMB_DATA_FWHALT: u32 = 0x10;
const HMB_DATA_VERSION_SHIFT = 16;

/// The frames' state: the SDIO core's registers, the sequence numbers
/// both ways, the firmware's credit and the channels it lets the host
/// send on, whether it has frames, and the buffers.
pub const Bus = extern struct {
    sdio_core: u32 = 0,
    tx_seq: u8 = 0,
    tx_max: u8 = 4,
    rx_seq: u8 = 0,
    flow_control: u8 = 0,
    rx_pending: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
    rx: ?[*]u8 = null,
    tx: ?[*]u8 = null,
};

/// A frame from the firmware: its channel, and its payload in the
/// receive buffer, until the next frame is read.
pub const Frame = struct {
    channel: u8,
    payload: []u8,
};

fn say(sys: *exec.ExecBase, comptime text: [:0]const u8) void {
    exec.kprintf(sys, "%s: " ++ text ++ "\n", .{@as([*:0]const u8, DEVICE_NAME)});
}

/// The buffers taken, and the sequence numbers and the credit at their
/// start: the firmware's. False if there is no memory.
pub fn open(base: *CywBase) bool {
    const sys = base.sys_base;
    const rx = sys.AllocVec(rx_bytes, exec.MEMF_ANY) orelse return false;
    const tx = sys.AllocVec(tx_bytes, exec.MEMF_ANY) orelse {
        sys.FreeVec(rx);
        return false;
    };
    base.bus = .{
        .sdio_core = base.chip.core(backplane.CORE_SDIO_DEV).?.base,
        .rx = @ptrCast(rx),
        .tx = @ptrCast(tx),
    };
    return true;
}

/// The SDIO core's interrupts read and taken, and the firmware's mailbox
/// read and acknowledged if it wrote to it; whether the firmware has
/// frames is kept for `receive`.
pub fn poll(base: *CywBase) Error!void {
    const bp = &base.backplane;
    const status = try backplane.read32(bp, base.bus.sdio_core + chip_file.SD_INTSTATUS) & host_int_mask;
    if (status == 0) return;
    try backplane.write32(bp, base.bus.sdio_core + chip_file.SD_INTSTATUS, status);
    if (status & I_HMB_HOST_INT != 0) try mailbox(base);
    if (status & I_HMB_FRAME_IND != 0) base.bus.rx_pending = 1;
}

/// What the firmware wrote to the host's mailbox, acknowledged: it
/// halting is said on the log and stops the device; it being ready with
/// a protocol other than the host's is said.
fn mailbox(base: *CywBase) Error!void {
    const sys = base.sys_base;
    const bp = &base.backplane;
    const data = try backplane.read32(bp, base.bus.sdio_core + chip_file.SD_TOHOSTMAILBOXDATA);
    try backplane.write32(bp, base.bus.sdio_core + chip_file.SD_TOSBMAILBOX, SMB_INT_ACK);
    if (data & HMB_DATA_FWHALT != 0) {
        say(sys, "the firmware has halted");
        base.running = 0;
    }
    if (data & (HMB_DATA_DEVREADY | HMB_DATA_FWREADY) != 0) {
        const version = (data >> HMB_DATA_VERSION_SHIFT) & 0xFF;
        if (version != SDPCM_PROT_VERSION) {
            exec.kprintf(sys, "%s: the firmware speaks SDPCM version %u, not %u\n", .{
                @as([*:0]const u8, DEVICE_NAME), version, SDPCM_PROT_VERSION,
            });
        }
    }
}

/// The next frame the firmware has for the host, or null when it has
/// none - or `poll` has not seen it say it has.
pub fn receive(base: *CywBase) Error!?Frame {
    const bus = &base.bus;
    if (bus.rx_pending == 0) return null;
    const buffer = bus.rx.?[0..rx_bytes];
    readFrame(base, buffer[0..first_read]) catch |err| {
        endRead(base, true);
        return err;
    };
    const length = std.mem.readInt(u16, buffer[0..2], .little);
    const check = std.mem.readInt(u16, buffer[2..4], .little);
    if (length | check == 0) {
        bus.rx_pending = 0;
        return null;
    }
    if (length ^ check != 0xFFFF or length < HEADER) {
        endRead(base, false);
        return error.Failed;
    }
    const tag = std.mem.readInt(u32, buffer[4..8], .little);
    const flow = std.mem.readInt(u32, buffer[8..12], .little);
    const offset = tag >> 24;
    if (offset < HEADER or offset > length) {
        endRead(base, false);
        return error.Failed;
    }
    if (length > first_read) {
        const rest = padded(length - first_read);
        if (first_read + rest > rx_bytes) {
            endRead(base, false);
            return error.Failed;
        }
        readFrame(base, buffer[first_read..][0..rest]) catch |err| {
            endRead(base, true);
            return err;
        };
    }
    bus.rx_seq = @as(u8, @truncate(tag)) +% 1;
    bus.flow_control = @truncate(flow);
    const most: u8 = @truncate(flow >> 8);
    bus.tx_max = if (most -% bus.tx_seq > 0x40) bus.tx_seq +% 2 else most;
    return .{ .channel = @truncate((tag >> 8) & 0xF), .payload = buffer[offset..length] };
}

/// Whether the firmware takes another frame now: the host's sequence
/// number short of the firmware's highest.
pub fn canSend(bus: *const Bus) bool {
    const room = bus.tx_max -% bus.tx_seq;
    return room != 0 and room & 0x80 == 0;
}

/// Where a frame's payload is put before it is sent: the send buffer past
/// the headers.
pub fn payload(base: *CywBase) []u8 {
    return base.bus.tx.?[HEADER..tx_bytes];
}

/// The `length` bytes at `payload` sent on `channel`, with the next
/// sequence number: the headers before them, the padding after.
pub fn send(base: *CywBase, channel: u8, length: usize) Error!void {
    const bus = &base.bus;
    const frame_length: u16 = @intCast(HEADER + length);
    const frame = bus.tx.?[0..padded(frame_length)];
    @memset(frame[frame_length..], 0);
    std.mem.writeInt(u16, frame[0..2], frame_length, .little);
    std.mem.writeInt(u16, frame[2..4], ~frame_length, .little);
    std.mem.writeInt(u32, frame[4..8], @as(u32, bus.tx_seq) | @as(u32, channel) << 8 | @as(u32, HEADER) << 24, .little);
    std.mem.writeInt(u32, frame[8..12], 0, .little);
    fifoAccess(base, true, frame) catch |err| {
        endWrite(base);
        return err;
    };
    bus.tx_seq +%= 1;
}

/// How much of a frame of `length` bytes is moved: past a block, whole
/// blocks; else whole words.
fn padded(length: usize) usize {
    if (length > block_bytes) return std.mem.alignForward(usize, length, block_bytes);
    return std.mem.alignForward(usize, length, 4);
}

fn readFrame(base: *CywBase, buffer: []u8) Error!void {
    try fifoAccess(base, false, buffer);
}

/// `buffer` read from the FIFO or written to it: its whole blocks, then
/// the rest as bytes.
fn fifoAccess(base: *CywBase, write: bool, buffer: []u8) Error!void {
    const bp = &base.backplane;
    try backplane.setWindow(bp, backplane.CHIPCOMMON);
    const whole = buffer.len / block_bytes * block_bytes;
    if (whole != 0) try sdio.blocks(&bp.card, write, 2, fifo, buffer[0..whole], block_bytes, false);
    if (whole != buffer.len) try sdio.bytes(&bp.card, write, 2, fifo, buffer[whole..], false);
}

/// The frame being read dropped: the transfer abandoned if it failed, the
/// chip told to end the frame, and its FIFO waited on until the frame has
/// gone. What fails here is left to the next frame to find.
fn endRead(base: *CywBase, abort: bool) void {
    const card = &base.backplane.card;
    if (abort) sdio.abort(card, 2) catch {};
    sdio.write8(card, 1, F1_FRAMECTRL, SFC_RF_TERM) catch return;
    for (0..rx_term_tries) |_| {
        const high = sdio.read8(card, 1, F1_RFRAMEBCHI) catch return;
        const low = sdio.read8(card, 1, F1_RFRAMEBCLO) catch return;
        if (high == 0 and low == 0) return;
    }
}

/// The frame being written dropped, as Linux drops it.
fn endWrite(base: *CywBase) void {
    const card = &base.backplane.card;
    sdio.abort(card, 2) catch {};
    sdio.write8(card, 1, F1_FRAMECTRL, SFC_WF_TERM) catch return;
    for (0..tx_term_tries) |_| {
        const high = sdio.read8(card, 1, F1_WFRAMEBCHI) catch return;
        const low = sdio.read8(card, 1, F1_WFRAMEBCLO) catch return;
        if (high == 0 and low == 0) return;
    }
}
