// SPDX-License-Identifier: MIT
//! The firmware's commands, for cyw43455.device: BCDC, the control
//! protocol of Broadcom's SDIO firmwares, as Linux's brcmfmac speaks it.
//!
//! **A command** is a frame on the control channel (sdpcm.zig): a header
//! - the command's number, its buffer's length, its flags (whether it
//! sets or gets, the interface, a request ID) and a status the firmware
//! fills in - and the buffer. The firmware answers on the same channel
//! with the header, the same request ID and the buffer: what was asked
//! for, in place of what was sent. The answer is waited for by polling,
//! for now, and what comes meanwhile - events, data - is handed to the
//! radio (radio.zig) as if the worker had read it in its loop.
//!
//! **Variables** ("iovars") are read and written by two of the commands,
//! GET_VAR and SET_VAR, whose buffer is the variable's name, a NUL and
//! its value.

const std = @import("std");
const _cyw = @import("_cyw43455.zig");
const host_file = @import("host.zig");
const sdpcm = @import("sdpcm.zig");
const radio = @import("radio.zig");
const CywBase = _cyw.CywBase;
const Error = host_file.Error;

/// The header, and its flags: a failed command, a command that sets, the
/// interface's place and the request ID's.
const HEADER = 16;
const FLAG_ERROR: u32 = 1 << 0;
const FLAG_SET: u32 = 1 << 1;
const FLAG_IF_SHIFT = 12;
const FLAG_ID_SHIFT = 16;

/// The commands.
pub const C_GET_VAR: u32 = 262;
pub const C_SET_VAR: u32 = 263;

/// The most of a command that goes out - an Ethernet frame's worth - and
/// so the largest buffer: Linux's.
const max_message = 1518;
pub const max_buffer = max_message - HEADER;

/// How long the firmware may take to take a command and to answer it:
/// Linux's two seconds; and how often it is looked at meanwhile.
const answer_us = 2_000_000;
const poll_us = 1_000;
/// How many frames are read at a time: Linux's.
const rx_bound = 50;

/// Command `number` sent with `buffer`, and the buffer of its answer
/// copied back over it, as much as fits: the firmware's status, 0 or its
/// error, a negative number.
pub fn command(base: *CywBase, number: u32, set: bool, buffer: []u8) Error!i32 {
    if (buffer.len > max_buffer) return error.Failed;
    var waited: u64 = 0;
    while (!sdpcm.canSend(&base.bus)) : (waited += poll_us) {
        if (waited >= answer_us) return error.Timeout;
        _ = try take(base, 0, buffer);
        base.delay(poll_us);
    }
    base.command_id +%= 1;
    if (base.command_id == 0) base.command_id = 1;
    const id: u32 = base.command_id;
    const message = sdpcm.payload(base);
    std.mem.writeInt(u32, message[0..4], number, .little);
    std.mem.writeInt(u32, message[4..8], @intCast(buffer.len), .little);
    std.mem.writeInt(u32, message[8..12], id << FLAG_ID_SHIFT | (if (set) FLAG_SET else 0), .little);
    std.mem.writeInt(u32, message[12..16], 0, .little);
    @memcpy(message[HEADER..][0..buffer.len], buffer);
    try sdpcm.send(base, sdpcm.CHANNEL_CONTROL, HEADER + buffer.len);
    waited = 0;
    while (waited < answer_us) : (waited += poll_us) {
        if (try take(base, id, buffer)) |status| return status;
        base.delay(poll_us);
    }
    return error.Timeout;
}

/// The frames the firmware has for the host read: the answer to request
/// `id`, if it is among them, copied into `buffer` - its status returned
/// - and the rest handed to the radio. Request 0 is none.
fn take(base: *CywBase, id: u32, buffer: []u8) Error!?i32 {
    try sdpcm.poll(base);
    var status: ?i32 = null;
    for (0..rx_bound) |_| {
        const frame = (try sdpcm.receive(base)) orelse break;
        if (frame.channel != sdpcm.CHANNEL_CONTROL) {
            radio.frameIn(base, frame);
            continue;
        }
        if (frame.payload.len < HEADER) continue;
        const flags = std.mem.readInt(u32, frame.payload[8..12], .little);
        if (id == 0 or flags >> FLAG_ID_SHIFT != id) continue;
        const answer = frame.payload[HEADER..];
        const length = @min(answer.len, buffer.len);
        @memcpy(buffer[0..length], answer[0..length]);
        status = if (flags & FLAG_ERROR != 0) @bitCast(std.mem.readInt(u32, frame.payload[12..16], .little)) else 0;
    }
    return status;
}

/// Variable `name` read into `value`: the firmware's status.
pub fn getVar(base: *CywBase, name: []const u8, value: []u8) Error!i32 {
    var buffer: [max_buffer]u8 = undefined;
    const length = name.len + 1 + value.len;
    if (length > buffer.len) return error.Failed;
    @memcpy(buffer[0..name.len], name);
    buffer[name.len] = 0;
    @memcpy(buffer[name.len + 1 ..][0..value.len], value);
    const status = try command(base, C_GET_VAR, false, buffer[0..length]);
    if (status == 0) @memcpy(value, buffer[0..value.len]);
    return status;
}

/// Variable `name` set to `value`: the firmware's status.
pub fn setVar(base: *CywBase, name: []const u8, value: []const u8) Error!i32 {
    var buffer: [max_buffer]u8 = undefined;
    const length = name.len + 1 + value.len;
    if (length > buffer.len) return error.Failed;
    @memcpy(buffer[0..name.len], name);
    buffer[name.len] = 0;
    @memcpy(buffer[name.len + 1 ..][0..value.len], value);
    return command(base, C_SET_VAR, true, buffer[0..length]);
}

/// Variable `name`, a 32-bit number, set to `value`.
pub fn setVar32(base: *CywBase, name: []const u8, value: u32) Error!i32 {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    return setVar(base, name, &bytes);
}

/// Command `number`, which sets a 32-bit number, given `value`: the
/// firmware's status.
pub fn set32(base: *CywBase, number: u32, value: u32) Error!i32 {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    return command(base, number, true, &bytes);
}
