// SPDX-License-Identifier: MIT
//! What a ModbusServer is, and the process that runs it.
//!
//! The process is made by StartModbusServer and lives until
//! StopModbusServer: it holds `alive` from its first moment to its last,
//! so stopping it is a CTRL_C and then waiting for that semaphore. It
//! lets go of it under Forbid, so the stopper - which may close the
//! library next - runs only once the process is gone.
//!
//! **RTU.** The process opens the bus's device itself and keeps a read
//! waiting on it. A frame for its unit, or for unit 0, the broadcast, is
//! answered from the tables (`pdu.serve`); a broadcast is carried out
//! and not answered, and a frame for another unit, or one whose CRC is
//! wrong, is passed over in silence, as a device on the bus must.
//!
//! **TCP.** The process opens bsdsocket.library for itself, listens on
//! the port - IPv4 and IPv6 on one socket - and keeps up to
//! `max_clients` connections, waiting on all of them and on CTRL_C with
//! WaitSelect. Each connection gathers bytes until it holds a whole
//! message, answers it with the question's transaction number, and goes
//! on with what is left. A connection over the limit is closed at once.
//!
//! The tables are read and written with the program's lock held, if it
//! gave one; the program's hook is called after a write, the lock let
//! go.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const modbus = sdk.modbus;
const utility = sdk.utility;
const rs485 = sdk.devices.rs485;
const bsd = sdk.bsdsocket;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const ModbusBase = @import("../modbus_base.zig").ModbusBase;
const pdu = @import("../protocol/pdu.zig");
const rtu = @import("../protocol/rtu.zig");
const mbap = @import("../protocol/mbap.zig");

/// The most connections a TCP server keeps.
pub const max_clients = 8;

/// A TCP connection, and the bytes of the message it is gathering.
pub const Client = extern struct {
    socket: i32 = -1,
    have: u32 = 0,
    buffer: [mbap.max_message]u8 = undefined,
};

pub const Server = extern struct {
    base: *ModbusBase,
    dos_base: ?*DosBase = null,
    transport: u32 = modbus.MBT_RTU,
    /// The unit it answers as; on TCP 0 is every unit.
    unit: u32 = 0,
    coils: ?[*]u8 = null,
    coil_count: u32 = 0,
    discrete: ?[*]const u8 = null,
    discrete_count: u32 = 0,
    holding: ?[*]u16 = null,
    holding_count: u32 = 0,
    input: ?[*]const u16 = null,
    input_count: u32 = 0,
    lock: ?*exec.SignalSemaphore = null,
    hook: ?*utility.Hook = null,
    // RTU: the bus.
    device: [64:0]u8 = @splat(0),
    device_unit: u32 = 0,
    baud: u32 = 19200,
    parity: u32 = modbus.MB_PARITY_EVEN,
    stop_bits: u32 = 1,
    // TCP: where it listens, and how many it keeps.
    port: u32 = 502,
    client_limit: u32 = 4,
    // The process.
    process: ?*exec.Task = null,
    alive: exec.SignalSemaphore = .{},
    starter: ?*exec.Task = null,
    start_signal: i32 = -1,
    /// What the process could not do at its start, or MBERR_OK.
    start_error: i32 = modbus.MBERR_OK,
    clients: [max_clients]Client = @splat(.{}),
    /// A frame, both ways (RTU), or an answer's PDU (TCP).
    frame: [rtu.max_frame]u8 = undefined,
    answer: [mbap.max_message]u8 = undefined,
};

pub fn serverOf(public: *modbus.ModbusServer) *Server {
    return @ptrCast(@alignCast(public));
}

fn tablesOf(server: *const Server) pdu.Tables {
    return .{
        .coils = server.coils,
        .coil_count = server.coil_count,
        .discrete = server.discrete,
        .discrete_count = server.discrete_count,
        .holding = server.holding,
        .holding_count = server.holding_count,
        .input = server.input,
        .input_count = server.input_count,
    };
}

/// A question answered from the tables, under the program's lock, and
/// the program's hook told of a write after it.
fn serve(server: *Server, unit: u32, question: []const u8, into: []u8) usize {
    const sys = server.base.sys_base;
    if (server.lock) |lock| sys.ObtainSemaphore(lock);
    const served = pdu.serve(tablesOf(server), question, into);
    if (server.lock) |lock| sys.ReleaseSemaphore(lock);
    if (served.wrote) |wrote| {
        if (server.hook) |hook| {
            var message = modbus.ModbusWrite{ .function = wrote.function, .address = wrote.address, .count = wrote.count, .unit = unit };
            if (hook.entry) |entry| _ = entry(hook, @ptrCast(server), @ptrCast(&message));
        }
    }
    return served.length;
}

/// The process's start, told to StartModbusServer.
fn started(server: *Server, result: i32) void {
    server.start_error = result;
    server.base.sys_base.Signal(server.starter.?, @as(u32, 1) << @intCast(server.start_signal));
}

/// The server's process: up, serving until CTRL_C, then gone.
pub fn serverMain(sys: *ExecBase) callconv(.c) void {
    const me = sys.FindTask(null).?;
    const server: *Server = @ptrCast(@alignCast(me.user_data orelse return));
    sys.ObtainSemaphore(&server.alive);
    switch (server.transport) {
        modbus.MBT_TCP => runTcp(server),
        else => runRtu(server),
    }
    sys.Forbid();
    sys.ReleaseSemaphore(&server.alive);
}

// --- RTU ------------------------------------------------------------------------

fn runRtu(server: *Server) void {
    const sys = server.base.sys_base;
    const port = sys.CreateMsgPort() orelse return started(server, modbus.MBERR_NOMEM);
    defer sys.DeleteMsgPort(port);
    const request = sys.CreateIORequest(port, @sizeOf(rs485.IORS485)) orelse return started(server, modbus.MBERR_NOMEM);
    defer sys.DeleteIORequest(request);
    const io: *rs485.IORS485 = @ptrCast(@alignCast(request));
    if (sys.OpenDevice(&server.device, server.device_unit, &io.std.req, 0) != 0) return started(server, modbus.MBERR_DEVICE);
    defer sys.CloseDevice(&io.std.req);
    const character_bits = 1 + 8 + @as(u32, if (server.parity != modbus.MB_PARITY_NONE) 1 else 0) + server.stop_bits;
    io.std.req.command = rs485.RS485CMD_SETPARAMS;
    io.baud = server.baud;
    io.data_bits = 8;
    io.parity = @intCast(server.parity);
    io.stop_bits = @intCast(server.stop_bits);
    io.gap = rtu.gapTenths(server.baud, character_bits);
    if (sys.DoIO(&io.std.req) != 0) return started(server, modbus.MBERR_DEVICE);
    started(server, modbus.MBERR_OK);

    while (true) {
        io.std.req.command = exec.CMD_READ;
        io.std.data = &server.frame;
        io.std.length = server.frame.len;
        io.timeout = 0;
        sys.SendIO(&io.std.req);
        const got = sys.Wait(port.sigMask() | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0 and sys.CheckIO(&io.std.req) == null) {
            _ = sys.AbortIO(&io.std.req);
            _ = sys.WaitIO(&io.std.req);
            return;
        }
        if (sys.WaitIO(&io.std.req) != 0) continue;
        const length: usize = @intCast(io.std.actual);
        const opened = rtu.open(server.frame[0..length]) orelse continue;
        if (opened.unit != server.unit and opened.unit != modbus.MB_BROADCAST) continue;
        var question: [modbus.MB_MAX_PDU]u8 = undefined;
        if (opened.pdu.len == 0 or opened.pdu.len > question.len) continue;
        @memcpy(question[0..opened.pdu.len], opened.pdu);
        const answered = serve(server, opened.unit, question[0..opened.pdu.len], &server.answer);
        if (opened.unit == modbus.MB_BROADCAST or answered == 0) continue;
        const sent = rtu.frame(server.unit, server.answer[0..answered], &server.frame);
        io.std.req.command = exec.CMD_WRITE;
        io.std.data = &server.frame;
        io.std.length = sent;
        _ = sys.DoIO(&io.std.req);
    }
}

// --- TCP ------------------------------------------------------------------------

fn closeClient(sb: *SocketBase, client: *Client) void {
    _ = sb.CloseSocket(client.socket);
    client.* = .{};
}

/// The whole messages a connection has gathered, each answered.
fn answerClient(server: *Server, sb: *SocketBase, client: *Client) bool {
    while (client.have >= mbap.header_length) {
        const header = mbap.header(client.buffer[0..mbap.header_length]) orelse return false;
        const total: u32 = mbap.header_length - 1 + header.length;
        if (client.have < total) return true;
        const question = client.buffer[mbap.header_length..total];
        var pdu_answer: [modbus.MB_MAX_PDU]u8 = undefined;
        var answered: usize = 0;
        if (server.unit == 0 or header.unit == server.unit) {
            answered = serve(server, header.unit, question, &pdu_answer);
        } else {
            // No such unit behind this server.
            pdu_answer[0] = question[0] | 0x80;
            pdu_answer[1] = @intCast(modbus.MBEX_GATEWAY_TARGET);
            answered = 2;
        }
        if (answered > 0) {
            const length = mbap.message(header.transaction, header.unit, pdu_answer[0..answered], &server.answer);
            var done: usize = 0;
            while (done < length) {
                const sent = sb.Send(client.socket, server.answer[done..].ptr, @intCast(length - done), 0);
                if (sent <= 0) return false;
                done += @intCast(sent);
            }
        }
        const rest = client.have - total;
        if (rest > 0) {
            var i: u32 = 0;
            while (i < rest) : (i += 1) client.buffer[i] = client.buffer[total + i];
        }
        client.have = rest;
    }
    return true;
}

fn runTcp(server: *Server) void {
    const sys = server.base.sys_base;
    const socket_lib = sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse return started(server, modbus.MBERR_IO);
    defer sys.CloseLibrary(socket_lib);
    const sb: *SocketBase = @ptrCast(socket_lib);

    const listener = sb.Socket(bsd.PF_INET6, bsd.SOCK_STREAM, 0);
    if (listener < 0) return started(server, modbus.MBERR_IO);
    defer _ = sb.CloseSocket(listener);
    const on: i32 = 1;
    _ = sb.SetSockOpt(listener, bsd.SOL_SOCKET, bsd.SO_REUSEADDR, &on, @sizeOf(i32));
    var here: bsd.sockaddr_in6 = .{ .sin6_port = bsd.htons(@intCast(server.port)) };
    if (sb.Bind(listener, here.anyConst(), @sizeOf(bsd.sockaddr_in6)) < 0 or sb.Listen(listener, 4) < 0) {
        return started(server, modbus.MBERR_CONNECT);
    }
    started(server, modbus.MBERR_OK);
    defer for (&server.clients) |*client| {
        if (client.socket >= 0) closeClient(sb, client);
    };

    while (true) {
        var readable: bsd.fd_set = .{};
        readable.set(listener);
        var highest = listener;
        for (&server.clients) |*client| {
            if (client.socket < 0) continue;
            readable.set(client.socket);
            highest = @max(highest, client.socket);
        }
        var signals: u32 = exec.SIGBREAKF_CTRL_C;
        const ready = sb.WaitSelect(highest + 1, &readable, null, null, null, &signals);
        if (signals & exec.SIGBREAKF_CTRL_C != 0) return;
        if (ready < 0) {
            if (sb.Errno() == bsd.EINTR) return;
            continue;
        }
        if (ready == 0) continue;

        if (readable.isSet(listener)) {
            const connection = sb.Accept(listener, null, null);
            if (connection >= 0) {
                var placed = false;
                for (server.clients[0..server.client_limit]) |*client| {
                    if (client.socket >= 0) continue;
                    client.* = .{ .socket = connection };
                    _ = sb.SetSockOpt(connection, bsd.IPPROTO_TCP, bsd.TCP_NODELAY, &on, @sizeOf(i32));
                    placed = true;
                    break;
                }
                if (!placed) _ = sb.CloseSocket(connection);
            }
        }
        for (&server.clients) |*client| {
            if (client.socket < 0 or !readable.isSet(client.socket)) continue;
            const room = client.buffer.len - client.have;
            const got = sb.Recv(client.socket, client.buffer[client.have..].ptr, @intCast(room), 0);
            if (got <= 0) {
                closeClient(sb, client);
                continue;
            }
            client.have += @intCast(got);
            if (!answerClient(server, sb, client)) closeClient(sb, client);
        }
    }
}
