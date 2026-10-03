// SPDX-License-Identifier: MIT
//! StartModbusServer: a server answering from the program's tables, on
//! a process of its own.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const modbus = sdk.modbus;
const utility = sdk.utility;
const rs485 = sdk.devices.rs485;
const DosBase = sdk.interface.dos.DosBase;
const ModbusBase = @import("../modbus_base.zig").ModbusBase;
const _server = @import("_server.zig");
const Server = _server.Server;

/// How much stack the server's process has: a question and its answer
/// are in the server, not on it.
const stack_size = 8192;

/// Starts a server.
///
/// SYNOPSIS:
/// ```zig
/// fn StartModbusServer(base: *ModbusBase, tags: ?[*]const utility.TagItem, err: ?*i32) ?*modbus.ModbusServer
/// ```
///
/// SINCE: 1.0. LVO -72.
///
/// INPUTS:
/// - `tags`:
///   - MBS_Transport (u32): MBT_RTU (the default) or MBT_TCP.
///   - MBS_Unit (u32): the unit it answers as, 1 to 247; required on
///     RTU. On TCP 0, the default, answers every unit.
///   - MBS_Coils, MBS_CoilCount; MBS_DiscreteInputs,
///     MBS_DiscreteCount: the bit tables, a byte each, from address 0.
///   - MBS_HoldingRegisters, MBS_HoldingCount; MBS_InputRegisters,
///     MBS_InputCount: the register tables, from address 0.
///   - MBS_Lock (`*exec.SignalSemaphore`): held while the server reads
///     or writes the tables.
///   - MBS_Hook (`*utility.Hook`): called after a client changed them.
///   - RTU: MBA_Device, MBA_DeviceUnit, MBA_Baud, MBA_Parity,
///     MBA_StopBits, as OpenModbusRTU takes them.
///   - TCP: MBA_Port (u32), 502; MBS_MaxClients (u32), 4, at most 8.
/// - `err`: where the reason goes when the answer is null, or null.
///
/// RESULT:
/// The server, running; `err` is then MBERR_OK. Null for no memory
/// (MBERR_NOMEM); no table at all, a unit out of range, or a line or
/// limit that cannot be (MBERR_ARGS); a bus device that cannot be opened
/// or set (MBERR_DEVICE); a port that cannot be listened on
/// (MBERR_CONNECT); or no network (MBERR_IO).
///
/// BEHAVIOR:
/// A process is started that opens the bus or listens on the port, and
/// answers every question for its unit from the tables: reads from
/// them, writes into them - functions 1 to 6, 15, 16 and 23; any other
/// is answered with MBEX_ILLEGAL_FUNCTION, an address past a table's end
/// with MBEX_ILLEGAL_ADDRESS. On RTU a broadcast is carried out without
/// an answer. The call returns once the process is listening, or has
/// failed to.
///
/// After a question that wrote, the hook is called on the server's
/// process with the ModbusServer as its object and a ModbusWrite - the
/// function, the first address, the count, the unit - as its message,
/// the lock let go.
///
/// CONTEXT:
/// - Waits: yes, for the process to start.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The tables, the lock and the hook stay the program's, and must be
/// there until StopModbusServer has returned. The server is the
/// program's to stop.
///
/// NOTES:
/// The server writes a table with no word to the program: a value the
/// program reads without the lock may be half of one write and half of
/// the next.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StopModbusServer`
///
/// EXAMPLES:
/// ```zig
/// var registers: [16]u16 = @splat(0);
/// var err: i32 = 0;
/// const server = mb.StartModbusServer(&[_]utility.TagItem{
///     .{ .tag = modbus.MBS_Transport, .data = modbus.MBT_TCP },
///     .{ .tag = modbus.MBS_HoldingRegisters, .data = @intFromPtr(&registers) },
///     .{ .tag = modbus.MBS_HoldingCount, .data = registers.len },
///     .{},
/// }, &err) orelse return err;
/// defer mb.StopModbusServer(server);
/// ```
pub fn StartModbusServer(base: *ModbusBase, tags: ?[*]const utility.TagItem, err: ?*i32) ?*modbus.ModbusServer {
    var reason: i32 = modbus.MBERR_OK;
    const server = start(base, tags, &reason);
    if (err) |into| into.* = reason;
    return server;
}

fn start(base: *ModbusBase, tags: ?[*]const utility.TagItem, reason: *i32) ?*modbus.ModbusServer {
    const sys = base.sys_base;
    const ub = base.utility_base;
    const memory = sys.AllocVec(@sizeOf(Server), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        reason.* = modbus.MBERR_NOMEM;
        return null;
    };
    const server: *Server = @ptrCast(@alignCast(memory));
    server.* = .{ .base = base };
    server.transport = @intCast(ub.GetTagData(modbus.MBS_Transport, modbus.MBT_RTU, tags));
    server.unit = @intCast(ub.GetTagData(modbus.MBS_Unit, 0, tags));
    server.coils = @ptrFromInt(ub.GetTagData(modbus.MBS_Coils, 0, tags));
    server.coil_count = @intCast(ub.GetTagData(modbus.MBS_CoilCount, 0, tags));
    server.discrete = @ptrFromInt(ub.GetTagData(modbus.MBS_DiscreteInputs, 0, tags));
    server.discrete_count = @intCast(ub.GetTagData(modbus.MBS_DiscreteCount, 0, tags));
    server.holding = @ptrFromInt(ub.GetTagData(modbus.MBS_HoldingRegisters, 0, tags));
    server.holding_count = @intCast(ub.GetTagData(modbus.MBS_HoldingCount, 0, tags));
    server.input = @ptrFromInt(ub.GetTagData(modbus.MBS_InputRegisters, 0, tags));
    server.input_count = @intCast(ub.GetTagData(modbus.MBS_InputCount, 0, tags));
    server.lock = @ptrFromInt(ub.GetTagData(modbus.MBS_Lock, 0, tags));
    server.hook = @ptrFromInt(ub.GetTagData(modbus.MBS_Hook, 0, tags));
    const device: [*:0]const u8 = @ptrFromInt(ub.GetTagData(modbus.MBA_Device, @intFromPtr(rs485.RS485NAME.ptr), tags));
    server.device_unit = @intCast(ub.GetTagData(modbus.MBA_DeviceUnit, 0, tags));
    server.baud = @intCast(ub.GetTagData(modbus.MBA_Baud, 19200, tags));
    server.parity = @intCast(ub.GetTagData(modbus.MBA_Parity, modbus.MB_PARITY_EVEN, tags));
    server.stop_bits = @intCast(ub.GetTagData(modbus.MBA_StopBits, 1, tags));
    server.port = @intCast(ub.GetTagData(modbus.MBA_Port, 502, tags));
    server.client_limit = @intCast(ub.GetTagData(modbus.MBS_MaxClients, 4, tags));

    var name_length: usize = 0;
    while (device[name_length] != 0) : (name_length += 1) {}
    const valid = check: {
        if (server.coils == null and server.discrete == null and server.holding == null and server.input == null) break :check false;
        if (server.coil_count > 0x10000 or server.discrete_count > 0x10000 or server.holding_count > 0x10000 or server.input_count > 0x10000) break :check false;
        switch (server.transport) {
            modbus.MBT_RTU => {
                if (server.unit == 0 or server.unit > 247) break :check false;
                if (server.parity > modbus.MB_PARITY_ODD or (server.stop_bits != 1 and server.stop_bits != 2)) break :check false;
                if (name_length >= server.device.len) break :check false;
            },
            modbus.MBT_TCP => {
                if (server.unit > 255 or server.port == 0 or server.port > 0xFFFF) break :check false;
                if (server.client_limit == 0 or server.client_limit > _server.max_clients) break :check false;
            },
            else => break :check false,
        }
        break :check true;
    };
    if (!valid) {
        sys.FreeVec(memory);
        reason.* = modbus.MBERR_ARGS;
        return null;
    }
    @memcpy(server.device[0..name_length], device[0..name_length]);

    const failed = fail: {
        const dos_lib = sys.OpenLibrary(dos.DOSNAME, 1) orelse break :fail modbus.MBERR_NOMEM;
        server.dos_base = @ptrCast(dos_lib);
        sys.InitSemaphore(&server.alive);
        const signal = sys.AllocSignal(-1);
        if (signal < 0) break :fail modbus.MBERR_NOMEM;
        server.start_signal = signal;
        server.starter = sys.FindTask(null);
        const dl: *DosBase = server.dos_base.?;
        const process = dl.CreateNewProc(&[_]utility.TagItem{
            .{ .tag = dos.NP_Entry, .data = @intFromPtr(&_server.serverMain) },
            .{ .tag = dos.NP_Name, .data = @intFromPtr(if (server.transport == modbus.MBT_TCP) "modbus tcp server" else "modbus rtu server") },
            .{ .tag = dos.NP_StackSize, .data = stack_size },
            .{ .tag = dos.NP_UserData, .data = @intFromPtr(server) },
            .{},
        }) orelse {
            sys.FreeSignal(signal);
            break :fail modbus.MBERR_NOMEM;
        };
        _ = sys.Wait(@as(u32, 1) << @intCast(signal));
        sys.FreeSignal(signal);
        server.start_signal = -1;
        server.process = @ptrCast(process);
        if (server.start_error != modbus.MBERR_OK) {
            // The process ends by itself; it lets go of `alive` last.
            sys.ObtainSemaphore(&server.alive);
            sys.ReleaseSemaphore(&server.alive);
            break :fail server.start_error;
        }
        return @ptrCast(server);
    };
    if (server.dos_base) |library| sys.CloseLibrary(@ptrCast(@alignCast(library)));
    sys.FreeVec(memory);
    reason.* = failed;
    return null;
}
