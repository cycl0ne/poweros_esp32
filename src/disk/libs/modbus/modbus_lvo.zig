// SPDX-License-Identifier: MIT
//! modbus.library's jump table: every `lvo<Name>` wrapper, the table of them
//! in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const modbus = sdk.modbus;
const utility = sdk.utility;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const vec = exec.vec;
const ModbusBase = @import("modbus_base.zig").ModbusBase;
const modbus_init = @import("modbus_init.zig");

const OpenModbusRTU = @import("context/openmodbusrtu.zig").OpenModbusRTU;
const OpenModbusTCP = @import("context/openmodbustcp.zig").OpenModbusTCP;
const CloseModbus = @import("context/closemodbus.zig").CloseModbus;
const ReadCoils = @import("data/readcoils.zig").ReadCoils;
const ReadDiscreteInputs = @import("data/readdiscreteinputs.zig").ReadDiscreteInputs;
const ReadHoldingRegisters = @import("data/readholdingregisters.zig").ReadHoldingRegisters;
const ReadInputRegisters = @import("data/readinputregisters.zig").ReadInputRegisters;
const WriteCoil = @import("data/writecoil.zig").WriteCoil;
const WriteRegister = @import("data/writeregister.zig").WriteRegister;
const WriteCoils = @import("data/writecoils.zig").WriteCoils;
const WriteRegisters = @import("data/writeregisters.zig").WriteRegisters;
const ReadWriteRegisters = @import("data/readwriteregisters.zig").ReadWriteRegisters;
const ModbusTransaction = @import("context/modbustransaction.zig").ModbusTransaction;
const StartModbusServer = @import("server/startmodbusserver.zig").StartModbusServer;
const StopModbusServer = @import("server/stopmodbusserver.zig").StopModbusServer;
const ModbusErrorText = @import("text/modbuserrortext.zig").ModbusErrorText;

/// modbus.library's interface, as the SDK generates it from
/// sdk/fd/modbus_lib.fd.
const interface = sdk.interface.modbus;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("modbus.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "modbus.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("context/openmodbusrtu.zig"),
    @embedFile("context/openmodbustcp.zig"),
    @embedFile("context/closemodbus.zig"),
    @embedFile("data/readcoils.zig"),
    @embedFile("data/readdiscreteinputs.zig"),
    @embedFile("data/readholdingregisters.zig"),
    @embedFile("data/readinputregisters.zig"),
    @embedFile("data/writecoil.zig"),
    @embedFile("data/writeregister.zig"),
    @embedFile("data/writecoils.zig"),
    @embedFile("data/writeregisters.zig"),
    @embedFile("data/readwriteregisters.zig"),
    @embedFile("context/modbustransaction.zig"),
    @embedFile("server/startmodbusserver.zig"),
    @embedFile("server/stopmodbusserver.zig"),
    @embedFile("text/modbuserrortext.zig"),
};

fn lvoOpenModbusRTU(base: *ModbusBase, tags: ?[*]const utility.TagItem, err: ?*i32) callconv(.c) ?*modbus.ModbusContext {
    return OpenModbusRTU(base, tags, err);
}
fn lvoOpenModbusTCP(base: *ModbusBase, socket_base: *SocketBase, tags: ?[*]const utility.TagItem, err: ?*i32) callconv(.c) ?*modbus.ModbusContext {
    return OpenModbusTCP(base, socket_base, tags, err);
}
fn lvoCloseModbus(base: *ModbusBase, context: ?*modbus.ModbusContext) callconv(.c) void {
    return CloseModbus(base, context);
}
fn lvoReadCoils(base: *ModbusBase, context: *modbus.ModbusContext, unit: u32, address: u32, count: u32, values: [*]u8) callconv(.c) i32 {
    return ReadCoils(base, context, unit, address, count, values);
}
fn lvoReadDiscreteInputs(base: *ModbusBase, context: *modbus.ModbusContext, unit: u32, address: u32, count: u32, values: [*]u8) callconv(.c) i32 {
    return ReadDiscreteInputs(base, context, unit, address, count, values);
}
fn lvoReadHoldingRegisters(base: *ModbusBase, context: *modbus.ModbusContext, unit: u32, address: u32, count: u32, values: [*]u16) callconv(.c) i32 {
    return ReadHoldingRegisters(base, context, unit, address, count, values);
}
fn lvoReadInputRegisters(base: *ModbusBase, context: *modbus.ModbusContext, unit: u32, address: u32, count: u32, values: [*]u16) callconv(.c) i32 {
    return ReadInputRegisters(base, context, unit, address, count, values);
}
fn lvoWriteCoil(base: *ModbusBase, context: *modbus.ModbusContext, unit: u32, address: u32, value: u32) callconv(.c) i32 {
    return WriteCoil(base, context, unit, address, value);
}
fn lvoWriteRegister(base: *ModbusBase, context: *modbus.ModbusContext, unit: u32, address: u32, value: u32) callconv(.c) i32 {
    return WriteRegister(base, context, unit, address, value);
}
fn lvoWriteCoils(base: *ModbusBase, context: *modbus.ModbusContext, unit: u32, address: u32, count: u32, values: [*]const u8) callconv(.c) i32 {
    return WriteCoils(base, context, unit, address, count, values);
}
fn lvoWriteRegisters(base: *ModbusBase, context: *modbus.ModbusContext, unit: u32, address: u32, count: u32, values: [*]const u16) callconv(.c) i32 {
    return WriteRegisters(base, context, unit, address, count, values);
}
fn lvoReadWriteRegisters(base: *ModbusBase, context: *modbus.ModbusContext, unit: u32, transfer: *const modbus.ModbusReadWrite) callconv(.c) i32 {
    return ReadWriteRegisters(base, context, unit, transfer);
}
fn lvoModbusTransaction(base: *ModbusBase, context: *modbus.ModbusContext, unit: u32, question: *const modbus.ModbusPdu, answer: *modbus.ModbusPdu) callconv(.c) i32 {
    return ModbusTransaction(base, context, unit, question, answer);
}
fn lvoStartModbusServer(base: *ModbusBase, tags: ?[*]const utility.TagItem, err: ?*i32) callconv(.c) ?*modbus.ModbusServer {
    return StartModbusServer(base, tags, err);
}
fn lvoStopModbusServer(base: *ModbusBase, server: ?*modbus.ModbusServer) callconv(.c) void {
    return StopModbusServer(base, server);
}
fn lvoModbusErrorText(base: *ModbusBase, code: i32) callconv(.c) [*:0]const u8 {
    return ModbusErrorText(base, code);
}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(modbus_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoOpenModbusRTU),
    vec(lvoOpenModbusTCP),
    vec(lvoCloseModbus),
    vec(lvoReadCoils),
    vec(lvoReadDiscreteInputs),
    vec(lvoReadHoldingRegisters),
    vec(lvoReadInputRegisters),
    vec(lvoWriteCoil),
    vec(lvoWriteRegister),
    vec(lvoWriteCoils),
    vec(lvoWriteRegisters),
    vec(lvoReadWriteRegisters),
    vec(lvoModbusTransaction),
    vec(lvoStartModbusServer),
    vec(lvoStopModbusServer),
    vec(lvoModbusErrorText),
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "the jump table: the standard four, then this library's own" {
    try testing.expectEqual(@as(usize, 4 + @typeInfo(LVO).@"struct".decls.len), vectors.len);
    inline for (@typeInfo(LVO).@"struct".decls) |d| {
        const index: usize = @intCast(@divExact(-@field(LVO, d.name), exec.slot_size) - 1);
        try testing.expectEqual(vec(@field(@This(), "lvo" ++ d.name)), vectors[index]);
    }
}

test "every wrapper hands its parameters on, in order, to the call it is named after" {
    try exec.libraries.checkForwarding(@embedFile("modbus_lvo.zig"), LVO, &.{});
}
