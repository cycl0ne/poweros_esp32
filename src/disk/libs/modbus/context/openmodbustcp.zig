// SPDX-License-Identifier: MIT
//! OpenModbusTCP: a client on a TCP connection, made with the program's
//! own bsdsocket.library base.

const sdk = @import("sdk");
const modbus = sdk.modbus;
const utility = sdk.utility;
const bsd = sdk.bsdsocket;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const ModbusBase = @import("../modbus_base.zig").ModbusBase;
const _context = @import("_context.zig");

/// Opens a client on a TCP connection.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenModbusTCP(base: *ModbusBase, socket_base: *SocketBase, tags: ?[*]const utility.TagItem, err: ?*i32) ?*modbus.ModbusContext
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `socket_base`: the program's bsdsocket.library base; the
///   connection's calls are made through it.
/// - `tags`:
///   - MBA_Host (`[*:0]const u8`): the server's name or address, IPv4
///     or IPv6. Either it or MBA_Socket is required.
///   - MBA_Port (u32): its port, 502.
///   - MBA_Socket (i32): a stream socket the program has connected
///     already, used instead of MBA_Host.
///   - MBA_Timeout (u32): how long a question waits for its answer, in
///     milliseconds; 1000.
/// - `err`: where the reason goes when the answer is null, or null.
///
/// RESULT:
/// The context, connected; `err` is then MBERR_OK. Null for no memory
/// (MBERR_NOMEM), a name that was not found (MBERR_HOST), no connection
/// on any of its addresses (MBERR_CONNECT), or neither MBA_Host nor
/// MBA_Socket, or a time-out of 0 (MBERR_ARGS).
///
/// BEHAVIOR:
/// The host's addresses are tried in the order GetAddrInfo gives them,
/// until one connects. The connection carries one question at a time,
/// each with its own transaction number.
///
/// CONTEXT:
/// - Waits: yes, for the name and the connection.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Process, the one `socket_base` belongs to; every call
///   with the context must come from it.
///
/// OWNERSHIP:
/// The context is the caller's until CloseModbus. A socket the library
/// made is closed with it; one the program gave stays the program's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenModbusRTU`, `CloseModbus`, `ModbusTransaction`
///
/// EXAMPLES:
/// ```zig
/// var err: i32 = 0;
/// const plc = mb.OpenModbusTCP(sb, &[_]utility.TagItem{
///     .{ .tag = modbus.MBA_Host, .data = @intFromPtr("192.168.1.20") },
///     .{},
/// }, &err) orelse return err;
/// defer mb.CloseModbus(plc);
/// ```
pub fn OpenModbusTCP(base: *ModbusBase, socket_base: *SocketBase, tags: ?[*]const utility.TagItem, err: ?*i32) ?*modbus.ModbusContext {
    var reason: i32 = modbus.MBERR_OK;
    const context = open(base, socket_base, tags, &reason);
    if (err) |into| into.* = reason;
    return context;
}

fn open(base: *ModbusBase, sb: *SocketBase, tags: ?[*]const utility.TagItem, reason: *i32) ?*modbus.ModbusContext {
    const ub = base.utility_base;
    const host: ?[*:0]const u8 = @ptrFromInt(ub.GetTagData(modbus.MBA_Host, 0, tags));
    const port: u32 = @intCast(ub.GetTagData(modbus.MBA_Port, 502, tags));
    const timeout: u32 = @intCast(ub.GetTagData(modbus.MBA_Timeout, 1000, tags));
    const given: i32 = @bitCast(@as(u32, @truncate(ub.GetTagData(modbus.MBA_Socket, @as(u32, @bitCast(@as(i32, -1))), tags))));
    if (timeout == 0 or port == 0 or port > 0xFFFF or (host == null and given < 0)) {
        reason.* = modbus.MBERR_ARGS;
        return null;
    }
    const context = _context.create(base, .tcp) orelse {
        reason.* = modbus.MBERR_NOMEM;
        return null;
    };
    context.timeout = timeout;
    context.socket_base = sb;
    if (given >= 0) {
        context.socket = given;
        return @ptrCast(context);
    }
    const made = connect(sb, host.?, port);
    if (made < 0) {
        _context.destroy(context);
        reason.* = made;
        return null;
    }
    context.socket = made;
    context.own_socket = true;
    return @ptrCast(context);
}

/// A stream socket connected to `host`'s `port`, or MBERR_HOST or
/// MBERR_CONNECT.
fn connect(sb: *SocketBase, host: [*:0]const u8, port: u32) i32 {
    var digits: [6:0]u8 = @splat(0);
    var at: usize = digits.len;
    var left = port;
    while (true) {
        at -= 1;
        digits[at] = @intCast('0' + left % 10);
        left /= 10;
        if (left == 0) break;
    }
    var service: [6:0]u8 = @splat(0);
    @memcpy(service[0 .. digits.len - at], digits[at..]);
    const hints: bsd.addrinfo = .{ .ai_socktype = bsd.SOCK_STREAM, .ai_flags = bsd.AI_NUMERICSERV };
    var list: ?*bsd.addrinfo = null;
    if (sb.GetAddrInfo(host, &service, &hints, &list) != 0) return modbus.MBERR_HOST;
    defer sb.FreeAddrInfo(list.?);
    var entry = list;
    while (entry) |each| : (entry = each.ai_next) {
        const socket = sb.Socket(each.ai_family, each.ai_socktype, each.ai_protocol);
        if (socket < 0) continue;
        if (sb.Connect(socket, each.ai_addr.?, each.ai_addrlen) == 0) {
            const on: i32 = 1;
            _ = sb.SetSockOpt(socket, bsd.IPPROTO_TCP, bsd.TCP_NODELAY, &on, @sizeOf(i32));
            return socket;
        }
        _ = sb.CloseSocket(socket);
    }
    return modbus.MBERR_CONNECT;
}
