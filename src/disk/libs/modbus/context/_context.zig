// SPDX-License-Identifier: MIT
//! What a ModbusContext is, and how a question goes over it: `transact`
//! sends a PDU to a unit and brings back the answer's PDU, by RTU or by
//! TCP. Every call of the library's that asks something comes through
//! here.
//!
//! **RTU.** The frames kept from before are dropped, the question is sent
//! as one frame, and the device's next frame is read within the time-out.
//! A frame from another unit - one that answered late, or a client's
//! question on a bus with two - is passed over and the next read, up to
//! three; a damaged one (its CRC, a parity bit) ends the question. A
//! question to unit 0, the broadcast, has no answer to wait for.
//!
//! **TCP.** Each question gets the next transaction number, and the
//! answer is the message that repeats it; one with another number, left
//! from a question that timed out, is read past. Waiting is by
//! WaitSelect with the time-out, so a server that never answers leaves
//! the connection as it was.

const sdk = @import("sdk");
const exec = sdk.exec;
const modbus = sdk.modbus;
const rs485 = sdk.devices.rs485;
const bsd = sdk.bsdsocket;
const timer = sdk.devices.timer;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const ModbusBase = @import("../modbus_base.zig").ModbusBase;
const rtu = @import("../protocol/rtu.zig");
const mbap = @import("../protocol/mbap.zig");

pub const Transport = enum(u8) { rtu, tcp };

pub const Context = extern struct {
    base: *ModbusBase,
    transport: Transport,
    pad: [3]u8 = @splat(0),
    /// How long an answer is waited for, in milliseconds.
    timeout: u32 = 1000,
    // RTU: the device's request and its port.
    port: ?*exec.MsgPort = null,
    io: ?*rs485.IORS485 = null,
    device_open: bool = false,
    pad2: [3]u8 = @splat(0),
    // TCP: the program's base and the connection.
    socket_base: ?*SocketBase = null,
    socket: i32 = -1,
    /// Whether the library made the socket and closes it.
    own_socket: bool = false,
    pad3: [1]u8 = @splat(0),
    transaction: u16 = 0,
    /// A frame or a message, both ways.
    buffer: [rtu.max_frame + mbap.header_length]u8 = undefined,
};

pub fn contextOf(public: *modbus.ModbusContext) *Context {
    return @ptrCast(@alignCast(public));
}

pub fn create(base: *ModbusBase, transport: Transport) ?*Context {
    const memory = base.sys_base.AllocVec(@sizeOf(Context), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const context: *Context = @ptrCast(@alignCast(memory));
    context.* = .{ .base = base, .transport = transport };
    return context;
}

/// Everything the context holds let go of, and the context freed.
pub fn destroy(context: *Context) void {
    const sys = context.base.sys_base;
    if (context.io) |io| {
        if (context.device_open) sys.CloseDevice(&io.std.req);
        sys.DeleteIORequest(@ptrCast(io));
    }
    if (context.port) |port| sys.DeleteMsgPort(port);
    if (context.own_socket and context.socket >= 0) _ = context.socket_base.?.CloseSocket(context.socket);
    sys.FreeVec(context);
}

/// The question `question` (a PDU) to `unit`, and the answer's PDU into
/// `answer`: MBERR_OK and its length, or what went wrong. The answer is
/// not looked into here.
pub fn transact(context: *Context, unit: u32, question: []const u8, answer: []u8, length: *usize) i32 {
    length.* = 0;
    if (question.len == 0 or question.len > modbus.MB_MAX_PDU) return modbus.MBERR_ARGS;
    return switch (context.transport) {
        .rtu => transactRtu(context, unit, question, answer, length),
        .tcp => transactTcp(context, unit, question, answer, length),
    };
}

fn transactRtu(context: *Context, unit: u32, question: []const u8, answer: []u8, length: *usize) i32 {
    if (unit > 247) return modbus.MBERR_ARGS;
    const sys = context.base.sys_base;
    const io = context.io.?;
    io.std.req.command = exec.CMD_CLEAR;
    _ = sys.DoIO(&io.std.req);

    const sent = rtu.frame(unit, question, &context.buffer);
    io.std.req.command = exec.CMD_WRITE;
    io.std.data = &context.buffer;
    io.std.length = sent;
    if (sys.DoIO(&io.std.req) != 0) return modbus.MBERR_IO;
    if (unit == modbus.MB_BROADCAST) return modbus.MBERR_OK;

    var tries: u32 = 0;
    while (tries < 3) : (tries += 1) {
        io.std.req.command = exec.CMD_READ;
        io.std.data = &context.buffer;
        io.std.length = rtu.max_frame;
        io.timeout = context.timeout * 1000;
        const failed = sys.DoIO(&io.std.req);
        switch (failed) {
            0 => {},
            rs485.RS485ERR_TIMEOUT => return modbus.MBERR_TIMEOUT,
            rs485.RS485ERR_PARITY, rs485.RS485ERR_FRAMING, rs485.RS485ERR_OVERFLOW => return modbus.MBERR_CRC,
            else => return modbus.MBERR_IO,
        }
        const got: usize = @intCast(io.std.actual);
        const opened = rtu.open(context.buffer[0..got]) orelse return modbus.MBERR_CRC;
        if (opened.unit != unit) continue;
        if (opened.pdu.len > answer.len) return modbus.MBERR_REPLY;
        @memcpy(answer[0..opened.pdu.len], opened.pdu);
        length.* = opened.pdu.len;
        return modbus.MBERR_OK;
    }
    return modbus.MBERR_TIMEOUT;
}

/// All of `bytes` sent.
fn sendAll(context: *Context, bytes: []const u8) i32 {
    const sb = context.socket_base.?;
    var done: usize = 0;
    while (done < bytes.len) {
        const sent = sb.Send(context.socket, bytes[done..].ptr, @intCast(bytes.len - done), 0);
        if (sent <= 0) return modbus.MBERR_IO;
        done += @intCast(sent);
    }
    return modbus.MBERR_OK;
}

/// Exactly `into.len` bytes received, each wait for more at most the
/// time-out.
fn receiveAll(context: *Context, into: []u8) i32 {
    const sb = context.socket_base.?;
    var done: usize = 0;
    while (done < into.len) {
        var readable: bsd.fd_set = .{};
        readable.set(context.socket);
        var wait = timer.TimeVal.fromMicros(context.timeout * 1000);
        const ready = sb.WaitSelect(context.socket + 1, &readable, null, null, &wait, null);
        if (ready < 0) return modbus.MBERR_IO;
        if (ready == 0) return modbus.MBERR_TIMEOUT;
        const got = sb.Recv(context.socket, into[done..].ptr, @intCast(into.len - done), 0);
        if (got == 0) return modbus.MBERR_CLOSED;
        if (got < 0) return modbus.MBERR_IO;
        done += @intCast(got);
    }
    return modbus.MBERR_OK;
}

fn transactTcp(context: *Context, unit: u32, question: []const u8, answer: []u8, length: *usize) i32 {
    if (unit > 255) return modbus.MBERR_ARGS;
    context.transaction +%= 1;
    const transaction = context.transaction;
    const message_length = mbap.message(transaction, unit, question, &context.buffer);
    const sent = sendAll(context, context.buffer[0..message_length]);
    if (sent != modbus.MBERR_OK) return sent;
    while (true) {
        const read = receiveAll(context, context.buffer[0..mbap.header_length]);
        if (read != modbus.MBERR_OK) return read;
        const header = mbap.header(context.buffer[0..mbap.header_length]) orelse return modbus.MBERR_REPLY;
        const pdu_length: usize = header.length - 1;
        const body = receiveAll(context, context.buffer[mbap.header_length..][0..pdu_length]);
        if (body != modbus.MBERR_OK) return body;
        if (header.transaction != transaction) continue;
        if (pdu_length > answer.len) return modbus.MBERR_REPLY;
        @memcpy(answer[0..pdu_length], context.buffer[mbap.header_length..][0..pdu_length]);
        length.* = pdu_length;
        return modbus.MBERR_OK;
    }
}
