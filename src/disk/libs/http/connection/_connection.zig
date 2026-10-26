// SPDX-License-Identifier: MIT
//! A connection a request goes over: a socket to one of a server's
//! addresses, with a TLS session on it for `https://`, in the program's
//! own bsdsocket.library base.
//!
//! A request speaks to its connection only through the connection's
//! operations - send all of these bytes, receive some, close - so the
//! host tests stand a server of their own behind a connection of their
//! own, and the requests do not know the difference.
//!
//! The address is looked up with GetAddrInfo and each answer tried in
//! the order it gives them, IPv6 and IPv4, until one connects. A client's
//! HTTP_Timeout becomes the socket's SO_RCVTIMEO and SO_SNDTIMEO.

const sdk = @import("sdk");
const exec = sdk.exec;
const http = sdk.http;
const tls = sdk.tls;
const bsd = sdk.bsdsocket;
const utility = sdk.utility;
const TimeVal = sdk.devices.timer.TimeVal;
const _protocol = @import("../protocol/_protocol.zig");
const _client = @import("../client/_client.zig");
const _base = @import("../http_base.zig");
const Client = _client.Client;
const Url = _protocol.Url;

/// The longest host name a connection keeps.
pub const host_most = 255;

/// What a connection does: the socket's, or a test's.
pub const Ops = struct {
    /// Every byte of `data` sent: HTTPERR_OK, or what went wrong.
    send: *const fn (connection: *Connection, data: []const u8) i32,
    /// Bytes into `into`: how many, 0 when the server closed, an
    /// HTTPERR_* below 0.
    receive: *const fn (connection: *Connection, into: []u8) i32,
    /// The connection closed and its memory freed.
    close: *const fn (connection: *Connection) void,
};

pub const Connection = struct {
    ops: *const Ops,
    client: *Client,
    secure: bool,
    port: u16,
    host_length: u16 = 0,
    /// As the URL writes it: an IPv6 address in its brackets.
    host: [host_most]u8 = undefined,
    socket: i32 = -1,
    session: ?*tls.Session = null,
    /// The certificate check's TLSV_*, for a request that goes over the
    /// connection again.
    verdict: u32 = tls.TLSV_TRUSTED,

    /// Whether a request for `url` may go over this connection.
    pub fn serves(connection: *const Connection, url: Url) bool {
        return connection.secure == url.secure and connection.port == url.port and
            _protocol.same(connection.host[0..connection.host_length], url.host);
    }

    pub fn send(connection: *Connection, data: []const u8) i32 {
        return connection.ops.send(connection, data);
    }

    pub fn receive(connection: *Connection, into: []u8) i32 {
        return connection.ops.receive(connection, into);
    }

    pub fn close(connection: *Connection) void {
        connection.ops.close(connection);
    }
};

/// Why a connection could not be made.
pub const Failure = struct {
    code: i32 = http.HTTPERR_OK,
    /// The TLS session's TLSERR_*, its certificate check's TLSV_* and the
    /// alert the server refused with, for HTTPERR_TLS.
    tls_error: i32 = tls.TLSERR_OK,
    verdict: u32 = tls.TLSV_TRUSTED,
    alert: u32 = 0,
};

const socket_ops: Ops = .{ .send = socketSend, .receive = socketReceive, .close = socketClose };

/// A connection to `url`'s server, over TLS for `https://`; null, and why
/// in `failure`, when none could be made.
pub fn connect(client: *Client, url: Url, failure: *Failure) ?*Connection {
    const base = client.base;
    const sys = base.sys_base;
    const sb = client.socket_base;
    const name = url.hostName();
    if (url.host.len > host_most) {
        failure.code = http.HTTPERR_URL;
        return null;
    }
    var tb: ?*sdk.interface.tls.TLSBase = null;
    if (url.secure) {
        tb = _base.tlsOf(base) orelse {
            failure.code = http.HTTPERR_LIBRARY;
            return null;
        };
    }

    var host: [host_most + 1:0]u8 = @splat(0);
    @memcpy(host[0..name.len], name);
    var port_digits: [8]u8 = @splat(0);
    _ = _protocol.portText(url.port, &port_digits);
    var service: [8:0]u8 = @splat(0);
    @memcpy(service[0..7], port_digits[1..8]);
    const hints: bsd.addrinfo = .{ .ai_socktype = bsd.SOCK_STREAM, .ai_flags = bsd.AI_NUMERICSERV };
    var list: ?*bsd.addrinfo = null;
    if (sb.GetAddrInfo(&host, &service, &hints, &list) != 0) {
        failure.code = http.HTTPERR_HOST;
        return null;
    }
    defer sb.FreeAddrInfo(list.?);

    // Each address in turn, in the order they came, until one connects.
    var socket: i32 = -1;
    var entry = list;
    while (entry) |each| : (entry = each.ai_next) {
        socket = sb.Socket(each.ai_family, each.ai_socktype, each.ai_protocol);
        if (socket < 0) continue;
        if (client.timeout != 0) {
            const wait: TimeVal = .{ .secs = client.timeout };
            _ = sb.SetSockOpt(socket, bsd.SOL_SOCKET, bsd.SO_RCVTIMEO, &wait, @sizeOf(TimeVal));
            _ = sb.SetSockOpt(socket, bsd.SOL_SOCKET, bsd.SO_SNDTIMEO, &wait, @sizeOf(TimeVal));
        }
        if (sb.Connect(socket, each.ai_addr.?, each.ai_addrlen) == 0) break;
        _ = sb.CloseSocket(socket);
        socket = -1;
    }
    if (socket < 0) {
        failure.code = http.HTTPERR_IO;
        return null;
    }

    const memory = sys.AllocVec(@sizeOf(Connection), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        _ = sb.CloseSocket(socket);
        failure.code = http.HTTPERR_NOMEM;
        return null;
    };
    const connection: *Connection = @ptrCast(@alignCast(memory));
    connection.* = .{
        .ops = &socket_ops,
        .client = client,
        .secure = url.secure,
        .port = url.port,
        .host_length = @intCast(url.host.len),
        .socket = socket,
    };
    @memcpy(connection.host[0..url.host.len], url.host);

    if (tb) |library| {
        var code: i32 = tls.TLSERR_OK;
        const tags = [_]utility.TagItem{
            .{ .tag = tls.TLS_Host, .data = @intFromPtr(&host) },
            .{ .tag = tls.TLS_Verify, .data = @intFromBool(client.verify) },
            .{ .tag = tls.TLS_Protocol, .data = @intFromPtr("http/1.1") },
            .{ .tag = tls.TLS_GetVerdict, .data = @intFromPtr(&failure.verdict) },
            .{ .tag = tls.TLS_GetAlert, .data = @intFromPtr(&failure.alert) },
            .{},
        };
        connection.session = library.OpenSession(sb, socket, &tags, &code) orelse {
            failure.code = if (code == tls.TLSERR_IO) http.HTTPERR_IO else http.HTTPERR_TLS;
            failure.tls_error = code;
            socketClose(connection);
            return null;
        };
        connection.verdict = failure.verdict;
    }
    return connection;
}

fn socketSend(connection: *Connection, data: []const u8) i32 {
    const client = connection.client;
    if (connection.session) |session| {
        const tb = client.base.tls_base.?;
        const sent = tb.WriteSession(session, data.ptr, @intCast(data.len));
        if (sent == @as(i32, @intCast(data.len))) return http.HTTPERR_OK;
        return if (sent == tls.TLSERR_IO) http.HTTPERR_IO else http.HTTPERR_TLS;
    }
    const sb = client.socket_base;
    var at: usize = 0;
    while (at < data.len) {
        const sent = sb.Send(connection.socket, data.ptr + at, @intCast(data.len - at), 0);
        if (sent <= 0) return http.HTTPERR_IO;
        at += @intCast(sent);
    }
    return http.HTTPERR_OK;
}

fn socketReceive(connection: *Connection, into: []u8) i32 {
    const client = connection.client;
    if (connection.session) |session| {
        const tb = client.base.tls_base.?;
        const got = tb.ReadSession(session, into.ptr, @intCast(into.len));
        if (got >= 0) return got;
        return if (got == tls.TLSERR_IO) http.HTTPERR_IO else http.HTTPERR_TLS;
    }
    const got = client.socket_base.Recv(connection.socket, into.ptr, @intCast(into.len), 0);
    return if (got < 0) http.HTTPERR_IO else got;
}

fn socketClose(connection: *Connection) void {
    const client = connection.client;
    // The session first: it says goodbye over the socket.
    if (connection.session) |session| client.base.tls_base.?.CloseSession(session);
    if (connection.socket >= 0) _ = client.socket_base.CloseSocket(connection.socket);
    client.base.sys_base.FreeVec(connection);
}
