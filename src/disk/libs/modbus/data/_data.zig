// SPDX-License-Identifier: MIT
//! What the questions by name share: a question built into a PDU, put
//! through the context (`_context.transact`), and its answer checked
//! against the function asked - the device's exception passed on, an
//! answer to something else refused.

const sdk = @import("sdk");
const modbus = sdk.modbus;
const _context = @import("../context/_context.zig");
const pdu = @import("../protocol/pdu.zig");

/// A question and the room for its answer.
pub const Exchange = struct {
    question: [modbus.MB_MAX_PDU]u8 = undefined,
    asked: usize = 0,
    answer: [modbus.MB_MAX_PDU]u8 = undefined,
    answered: usize = 0,

    pub fn answerPdu(exchange: *const Exchange) []const u8 {
        return exchange.answer[0..exchange.answered];
    }

    pub fn questionPdu(exchange: *const Exchange) []const u8 {
        return exchange.question[0..exchange.asked];
    }
};

/// The question in `exchange` asked of `unit`: MBERR_OK with the answer
/// in it, the device's exception, or what kept it from being answered.
/// A broadcast is answered by nobody, and is done once it is sent.
pub fn ask(public: *modbus.ModbusContext, unit: u32, exchange: *Exchange) i32 {
    const context = _context.contextOf(public);
    const sent = _context.transact(context, unit, exchange.questionPdu(), &exchange.answer, &exchange.answered);
    if (sent != modbus.MBERR_OK) return sent;
    if (unit == modbus.MB_BROADCAST and context.transport == .rtu) return modbus.MBERR_OK;
    return pdu.check(exchange.question[0], exchange.answerPdu());
}

/// A read of bits (functions 1 and 2): `count` a byte each into `values`.
pub fn readBits(public: *modbus.ModbusContext, unit: u32, function: u8, address: u32, count: u32, values: [*]u8) i32 {
    if (count == 0 or count > modbus.MB_MAX_READ_BITS or address > 0xFFFF or count > 0x10000 - address) return modbus.MBERR_ARGS;
    if (unit == modbus.MB_BROADCAST and _context.contextOf(public).transport == .rtu) return modbus.MBERR_ARGS;
    var exchange: Exchange = .{};
    exchange.asked = pdu.readQuestion(function, address, count, &exchange.question);
    const asked = ask(public, unit, &exchange);
    if (asked != modbus.MBERR_OK) return asked;
    return pdu.takeBits(exchange.answerPdu(), count, values);
}

/// A read of registers (functions 3 and 4) into `values`.
pub fn readRegisters(public: *modbus.ModbusContext, unit: u32, function: u8, address: u32, count: u32, values: [*]u16) i32 {
    if (count == 0 or count > modbus.MB_MAX_READ_REGISTERS or address > 0xFFFF or count > 0x10000 - address) return modbus.MBERR_ARGS;
    if (unit == modbus.MB_BROADCAST and _context.contextOf(public).transport == .rtu) return modbus.MBERR_ARGS;
    var exchange: Exchange = .{};
    exchange.asked = pdu.readQuestion(function, address, count, &exchange.question);
    const asked = ask(public, unit, &exchange);
    if (asked != modbus.MBERR_OK) return asked;
    return pdu.takeRegisters(exchange.answerPdu(), count, values);
}

/// A write whose answer repeats the question's first five bytes.
pub fn write(public: *modbus.ModbusContext, unit: u32, exchange: *Exchange) i32 {
    const asked = ask(public, unit, exchange);
    if (asked != modbus.MBERR_OK) return asked;
    if (unit == modbus.MB_BROADCAST and _context.contextOf(public).transport == .rtu) return modbus.MBERR_OK;
    return pdu.checkEcho(exchange.questionPdu(), exchange.answerPdu());
}
