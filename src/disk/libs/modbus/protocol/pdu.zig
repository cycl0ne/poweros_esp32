// SPDX-License-Identifier: MIT
//! Modbus's protocol data units, both ways: a client's questions built
//! and the answers checked and unpacked, and a server's answers worked
//! out from its tables. The same on RTU and TCP; only the wrapping
//! differs (`rtu.zig`, `mbap.zig`).
//!
//! A PDU is a function code and its data, every number big-endian. Bits
//! go eight to a byte, the lowest address in the lowest bit. An answer
//! whose function code has its top bit set is an exception: the byte
//! after it says which.

const sdk = @import("sdk");
const modbus = sdk.modbus;

fn put16(into: []u8, at: usize, value: u32) void {
    into[at] = @truncate(value >> 8);
    into[at + 1] = @truncate(value);
}

fn get16(from: []const u8, at: usize) u32 {
    return @as(u32, from[at]) << 8 | from[at + 1];
}

fn bytesForBits(count: u32) u32 {
    return (count + 7) / 8;
}

// --- the client's side ------------------------------------------------------------

/// A read of `count` bits or registers from `address`: functions 1 to 4.
pub fn readQuestion(function: u8, address: u32, count: u32, into: []u8) usize {
    into[0] = function;
    put16(into, 1, address);
    put16(into, 3, count);
    return 5;
}

/// A write of one coil (function 5, `value` not 0 for on) or one
/// register (function 6).
pub fn writeOneQuestion(function: u8, address: u32, value: u32, into: []u8) usize {
    into[0] = function;
    put16(into, 1, address);
    put16(into, 3, if (function == modbus.MBFC_WRITE_SINGLE_COIL) (if (value != 0) 0xFF00 else 0) else value);
    return 5;
}

/// A write of `count` coils, a byte each in `values`: function 15.
pub fn writeBitsQuestion(address: u32, count: u32, values: [*]const u8, into: []u8) usize {
    into[0] = modbus.MBFC_WRITE_MULTIPLE_COILS;
    put16(into, 1, address);
    put16(into, 3, count);
    const bytes = bytesForBits(count);
    into[5] = @intCast(bytes);
    packBits(values, count, into[6..][0..bytes]);
    return 6 + bytes;
}

/// A write of `count` registers: function 16.
pub fn writeRegistersQuestion(address: u32, count: u32, values: [*]const u16, into: []u8) usize {
    into[0] = modbus.MBFC_WRITE_MULTIPLE_REGISTERS;
    put16(into, 1, address);
    put16(into, 3, count);
    into[5] = @intCast(count * 2);
    for (0..count) |i| put16(into, 6 + i * 2, values[i]);
    return 6 + count * 2;
}

/// A write and a read in one: function 23.
pub fn readWriteQuestion(transfer: *const modbus.ModbusReadWrite, into: []u8) usize {
    into[0] = modbus.MBFC_READ_WRITE_REGISTERS;
    put16(into, 1, transfer.read_address);
    put16(into, 3, transfer.read_count);
    put16(into, 5, transfer.write_address);
    put16(into, 7, transfer.write_count);
    into[9] = @intCast(transfer.write_count * 2);
    for (0..transfer.write_count) |i| put16(into, 10 + i * 2, transfer.write[i]);
    return 10 + transfer.write_count * 2;
}

/// Whether an answer is to `function`: 0; the device's exception; or
/// MBERR_REPLY for one to something else, or too short to be any.
pub fn check(function: u8, answer: []const u8) i32 {
    if (answer.len < 2) return modbus.MBERR_REPLY;
    if (answer[0] == function | 0x80) return answer[1];
    if (answer[0] != function) return modbus.MBERR_REPLY;
    return modbus.MBERR_OK;
}

/// The bits of a read's answer, a byte each into `values`.
pub fn takeBits(answer: []const u8, count: u32, values: [*]u8) i32 {
    const bytes = bytesForBits(count);
    if (answer.len != 2 + bytes or answer[1] != bytes) return modbus.MBERR_REPLY;
    for (0..count) |i| values[i] = @intFromBool(answer[2 + i / 8] & (@as(u8, 1) << @intCast(i % 8)) != 0);
    return modbus.MBERR_OK;
}

/// The registers of a read's answer into `values`.
pub fn takeRegisters(answer: []const u8, count: u32, values: [*]u16) i32 {
    if (answer.len != 2 + count * 2 or answer[1] != count * 2) return modbus.MBERR_REPLY;
    for (0..count) |i| values[i] = @intCast(get16(answer, 2 + i * 2));
    return modbus.MBERR_OK;
}

/// A write's answer, which repeats the question's first five bytes.
pub fn checkEcho(question: []const u8, answer: []const u8) i32 {
    if (answer.len != 5) return modbus.MBERR_REPLY;
    for (question[0..5], answer) |asked, said| if (asked != said) return modbus.MBERR_REPLY;
    return modbus.MBERR_OK;
}

fn packBits(values: [*]const u8, count: u32, into: []u8) void {
    @memset(into, 0);
    for (0..count) |i| {
        if (values[i] != 0) into[i / 8] |= @as(u8, 1) << @intCast(i % 8);
    }
}

// --- the server's side ------------------------------------------------------------

/// A server's data: the four tables, each from address 0.
pub const Tables = struct {
    coils: ?[*]u8 = null,
    coil_count: u32 = 0,
    discrete: ?[*]const u8 = null,
    discrete_count: u32 = 0,
    holding: ?[*]u16 = null,
    holding_count: u32 = 0,
    input: ?[*]const u16 = null,
    input_count: u32 = 0,
};

/// What a question changed in the tables.
pub const Wrote = struct { function: u8, address: u32, count: u32 };

/// An answer: its length, and what it wrote.
pub const Served = struct { length: usize, wrote: ?Wrote = null };

fn exception(function: u8, code: i32, into: []u8) Served {
    into[0] = function | 0x80;
    into[1] = @intCast(code);
    return .{ .length = 2 };
}

/// Whether `count` from `address` lies in a table of `size`.
fn inside(address: u32, count: u32, size: u32) bool {
    return address < size and count <= size - address;
}

/// The answer to `question` from `tables`, into `into` (MB_MAX_PDU
/// bytes): the data asked for, the write done, or an exception.
pub fn serve(tables: Tables, question: []const u8, into: []u8) Served {
    if (question.len == 0) return .{ .length = 0 };
    const function = question[0];
    switch (function) {
        modbus.MBFC_READ_COILS, modbus.MBFC_READ_DISCRETE_INPUTS => {
            if (question.len != 5) return exception(function, modbus.MBEX_ILLEGAL_VALUE, into);
            const address = get16(question, 1);
            const count = get16(question, 3);
            if (count == 0 or count > modbus.MB_MAX_READ_BITS) return exception(function, modbus.MBEX_ILLEGAL_VALUE, into);
            const table: ?[*]const u8, const size = if (function == modbus.MBFC_READ_COILS)
                .{ tables.coils, tables.coil_count }
            else
                .{ tables.discrete, tables.discrete_count };
            if (table == null or !inside(address, count, size)) return exception(function, modbus.MBEX_ILLEGAL_ADDRESS, into);
            const bytes = bytesForBits(count);
            into[0] = function;
            into[1] = @intCast(bytes);
            packBits(table.? + address, count, into[2..][0..bytes]);
            return .{ .length = 2 + bytes };
        },
        modbus.MBFC_READ_HOLDING_REGISTERS, modbus.MBFC_READ_INPUT_REGISTERS => {
            if (question.len != 5) return exception(function, modbus.MBEX_ILLEGAL_VALUE, into);
            const address = get16(question, 1);
            const count = get16(question, 3);
            if (count == 0 or count > modbus.MB_MAX_READ_REGISTERS) return exception(function, modbus.MBEX_ILLEGAL_VALUE, into);
            const table: ?[*]const u16, const size = if (function == modbus.MBFC_READ_HOLDING_REGISTERS)
                .{ tables.holding, tables.holding_count }
            else
                .{ tables.input, tables.input_count };
            if (table == null or !inside(address, count, size)) return exception(function, modbus.MBEX_ILLEGAL_ADDRESS, into);
            into[0] = function;
            into[1] = @intCast(count * 2);
            for (0..count) |i| put16(into, 2 + i * 2, table.?[address + i]);
            return .{ .length = 2 + count * 2 };
        },
        modbus.MBFC_WRITE_SINGLE_COIL => {
            if (question.len != 5) return exception(function, modbus.MBEX_ILLEGAL_VALUE, into);
            const address = get16(question, 1);
            const value = get16(question, 3);
            if (value != 0xFF00 and value != 0) return exception(function, modbus.MBEX_ILLEGAL_VALUE, into);
            const coils = tables.coils orelse return exception(function, modbus.MBEX_ILLEGAL_ADDRESS, into);
            if (!inside(address, 1, tables.coil_count)) return exception(function, modbus.MBEX_ILLEGAL_ADDRESS, into);
            coils[address] = @intFromBool(value != 0);
            @memcpy(into[0..5], question[0..5]);
            return .{ .length = 5, .wrote = .{ .function = function, .address = address, .count = 1 } };
        },
        modbus.MBFC_WRITE_SINGLE_REGISTER => {
            if (question.len != 5) return exception(function, modbus.MBEX_ILLEGAL_VALUE, into);
            const address = get16(question, 1);
            const holding = tables.holding orelse return exception(function, modbus.MBEX_ILLEGAL_ADDRESS, into);
            if (!inside(address, 1, tables.holding_count)) return exception(function, modbus.MBEX_ILLEGAL_ADDRESS, into);
            holding[address] = @intCast(get16(question, 3));
            @memcpy(into[0..5], question[0..5]);
            return .{ .length = 5, .wrote = .{ .function = function, .address = address, .count = 1 } };
        },
        modbus.MBFC_WRITE_MULTIPLE_COILS => {
            if (question.len < 6) return exception(function, modbus.MBEX_ILLEGAL_VALUE, into);
            const address = get16(question, 1);
            const count = get16(question, 3);
            const bytes = bytesForBits(count);
            if (count == 0 or count > modbus.MB_MAX_WRITE_BITS or question[5] != bytes or question.len != 6 + bytes) {
                return exception(function, modbus.MBEX_ILLEGAL_VALUE, into);
            }
            const coils = tables.coils orelse return exception(function, modbus.MBEX_ILLEGAL_ADDRESS, into);
            if (!inside(address, count, tables.coil_count)) return exception(function, modbus.MBEX_ILLEGAL_ADDRESS, into);
            for (0..count) |i| coils[address + i] = @intFromBool(question[6 + i / 8] & (@as(u8, 1) << @intCast(i % 8)) != 0);
            @memcpy(into[0..5], question[0..5]);
            return .{ .length = 5, .wrote = .{ .function = function, .address = address, .count = count } };
        },
        modbus.MBFC_WRITE_MULTIPLE_REGISTERS => {
            if (question.len < 6) return exception(function, modbus.MBEX_ILLEGAL_VALUE, into);
            const address = get16(question, 1);
            const count = get16(question, 3);
            if (count == 0 or count > modbus.MB_MAX_WRITE_REGISTERS or question[5] != count * 2 or question.len != 6 + count * 2) {
                return exception(function, modbus.MBEX_ILLEGAL_VALUE, into);
            }
            const holding = tables.holding orelse return exception(function, modbus.MBEX_ILLEGAL_ADDRESS, into);
            if (!inside(address, count, tables.holding_count)) return exception(function, modbus.MBEX_ILLEGAL_ADDRESS, into);
            for (0..count) |i| holding[address + i] = @intCast(get16(question, 6 + i * 2));
            @memcpy(into[0..5], question[0..5]);
            return .{ .length = 5, .wrote = .{ .function = function, .address = address, .count = count } };
        },
        modbus.MBFC_READ_WRITE_REGISTERS => {
            if (question.len < 10) return exception(function, modbus.MBEX_ILLEGAL_VALUE, into);
            const read_address = get16(question, 1);
            const read_count = get16(question, 3);
            const write_address = get16(question, 5);
            const write_count = get16(question, 7);
            if (read_count == 0 or read_count > modbus.MB_MAX_READ_REGISTERS or write_count == 0 or
                write_count > modbus.MB_MAX_READWRITE_REGISTERS or question[9] != write_count * 2 or
                question.len != 10 + write_count * 2)
            {
                return exception(function, modbus.MBEX_ILLEGAL_VALUE, into);
            }
            const holding = tables.holding orelse return exception(function, modbus.MBEX_ILLEGAL_ADDRESS, into);
            if (!inside(read_address, read_count, tables.holding_count) or !inside(write_address, write_count, tables.holding_count)) {
                return exception(function, modbus.MBEX_ILLEGAL_ADDRESS, into);
            }
            for (0..write_count) |i| holding[write_address + i] = @intCast(get16(question, 10 + i * 2));
            into[0] = function;
            into[1] = @intCast(read_count * 2);
            for (0..read_count) |i| put16(into, 2 + i * 2, holding[read_address + i]);
            return .{ .length = 2 + read_count * 2, .wrote = .{ .function = function, .address = write_address, .count = write_count } };
        },
        else => return exception(function & 0x7F, modbus.MBEX_ILLEGAL_FUNCTION, into),
    }
}

// --- tests ----------------------------------------------------------------------

const testing = @import("std").testing;

test "a read of registers, asked and answered" {
    var holding = [_]u16{ 10, 0x1234, 0xFFFF, 4 };
    const tables = Tables{ .holding = &holding, .holding_count = holding.len };
    var question: [16]u8 = undefined;
    const asked = readQuestion(modbus.MBFC_READ_HOLDING_REGISTERS, 1, 2, &question);
    try testing.expectEqualSlices(u8, &.{ 3, 0, 1, 0, 2 }, question[0..asked]);
    var answer: [modbus.MB_MAX_PDU]u8 = undefined;
    const served = serve(tables, question[0..asked], &answer);
    try testing.expectEqualSlices(u8, &.{ 3, 4, 0x12, 0x34, 0xFF, 0xFF }, answer[0..served.length]);
    try testing.expectEqual(@as(i32, 0), check(3, answer[0..served.length]));
    var got: [2]u16 = undefined;
    try testing.expectEqual(@as(i32, 0), takeRegisters(answer[0..served.length], 2, &got));
    try testing.expectEqual(@as(u16, 0x1234), got[0]);
    try testing.expectEqual(@as(u16, 0xFFFF), got[1]);
}

test "bits, eight to a byte, both ways" {
    var coils = [_]u8{ 1, 0, 1, 1, 0, 0, 0, 0, 1, 1 };
    const tables = Tables{ .coils = &coils, .coil_count = coils.len };
    var question: [16]u8 = undefined;
    var answer: [modbus.MB_MAX_PDU]u8 = undefined;
    const asked = readQuestion(modbus.MBFC_READ_COILS, 0, 10, &question);
    const served = serve(tables, question[0..asked], &answer);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 0x0D, 0x03 }, answer[0..served.length]);
    var got: [10]u8 = undefined;
    try testing.expectEqual(@as(i32, 0), takeBits(answer[0..served.length], 10, &got));
    try testing.expectEqualSlices(u8, &coils, &got);

    const set = [_]u8{ 0, 1, 1 };
    const write = writeBitsQuestion(7, 3, &set, &question);
    const wrote = serve(tables, question[0..write], &answer);
    try testing.expectEqual(@as(i32, 0), checkEcho(question[0..write], answer[0..wrote.length]));
    try testing.expectEqualSlices(u8, &.{ 1, 0, 1, 1, 0, 0, 0, 0, 1, 1 }, &coils);
    try testing.expectEqual(@as(u32, 3), wrote.wrote.?.count);
}

test "the exceptions" {
    var holding = [_]u16{ 1, 2 };
    const tables = Tables{ .holding = &holding, .holding_count = holding.len };
    var question: [16]u8 = undefined;
    var answer: [modbus.MB_MAX_PDU]u8 = undefined;
    // Past the end.
    var asked = readQuestion(modbus.MBFC_READ_HOLDING_REGISTERS, 1, 2, &question);
    var served = serve(tables, question[0..asked], &answer);
    try testing.expectEqualSlices(u8, &.{ 0x83, 2 }, answer[0..served.length]);
    try testing.expectEqual(modbus.MBEX_ILLEGAL_ADDRESS, check(3, answer[0..served.length]));
    // No such table.
    asked = readQuestion(modbus.MBFC_READ_INPUT_REGISTERS, 0, 1, &question);
    served = serve(tables, question[0..asked], &answer);
    try testing.expectEqual(modbus.MBEX_ILLEGAL_ADDRESS, check(4, answer[0..served.length]));
    // Too many.
    asked = readQuestion(modbus.MBFC_READ_HOLDING_REGISTERS, 0, 126, &question);
    served = serve(tables, question[0..asked], &answer);
    try testing.expectEqual(modbus.MBEX_ILLEGAL_VALUE, check(3, answer[0..served.length]));
    // A function nobody asks.
    served = serve(tables, &.{ 0x2B, 0x0E, 1, 0 }, &answer);
    try testing.expectEqualSlices(u8, &.{ 0xAB, 1 }, answer[0..served.length]);
    // A coil written with neither on nor off.
    served = serve(.{}, &.{ 5, 0, 0, 0x12, 0x34 }, &answer);
    try testing.expectEqual(modbus.MBEX_ILLEGAL_VALUE, check(5, answer[0..served.length]));
    try testing.expectEqual(modbus.MBERR_REPLY, check(3, &.{ 4, 0 }));
}

test "single writes and the read-write" {
    var holding = [_]u16{ 0, 0, 0, 0 };
    var coils = [_]u8{ 0, 0 };
    const tables = Tables{ .holding = &holding, .holding_count = holding.len, .coils = &coils, .coil_count = coils.len };
    var question: [32]u8 = undefined;
    var answer: [modbus.MB_MAX_PDU]u8 = undefined;
    var asked = writeOneQuestion(modbus.MBFC_WRITE_SINGLE_COIL, 1, 7, &question);
    try testing.expectEqualSlices(u8, &.{ 5, 0, 1, 0xFF, 0 }, question[0..asked]);
    var served = serve(tables, question[0..asked], &answer);
    try testing.expectEqual(@as(i32, 0), checkEcho(question[0..asked], answer[0..served.length]));
    try testing.expectEqual(@as(u8, 1), coils[1]);
    asked = writeOneQuestion(modbus.MBFC_WRITE_SINGLE_REGISTER, 2, 0xBEEF, &question);
    served = serve(tables, question[0..asked], &answer);
    try testing.expectEqual(@as(u16, 0xBEEF), holding[2]);

    const values = [_]u16{ 7, 8 };
    var read: [3]u16 = undefined;
    const transfer = modbus.ModbusReadWrite{ .read_address = 1, .read_count = 3, .read = &read, .write_address = 0, .write_count = 2, .write = &values };
    asked = readWriteQuestion(&transfer, &question);
    served = serve(tables, question[0..asked], &answer);
    try testing.expectEqual(@as(i32, 0), check(0x17, answer[0..served.length]));
    try testing.expectEqual(@as(i32, 0), takeRegisters(answer[0..served.length], 3, &read));
    try testing.expectEqualSlices(u16, &.{ 8, 0xBEEF, 0 }, &read);

    const many = [_]u16{ 1, 2, 3 };
    asked = writeRegistersQuestion(1, 3, &many, &question);
    served = serve(tables, question[0..asked], &answer);
    try testing.expectEqual(@as(i32, 0), checkEcho(question[0..asked], answer[0..served.length]));
    try testing.expectEqualSlices(u16, &.{ 7, 1, 2, 3 }, &holding);
}
