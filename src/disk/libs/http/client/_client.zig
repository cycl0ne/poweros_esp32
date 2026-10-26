// SPDX-License-Identifier: MIT
//! A client: the program's socket base, its settings, and the
//! connections its requests left open for the next.
//!
//! **The pool** holds up to `pool_most` idle connections. A request takes
//! one that serves its scheme, host and port, and gives it back when its
//! answer has been read to the end and the server keeps it; when the pool
//! is full, the connection idle longest is closed to make room. A server
//! may close an idle connection whenever it likes, and a request finds
//! that out only by trying it, so a request on a kept connection that
//! fails before any of the answer has come is sent again on a fresh one.

const sdk = @import("sdk");
const http = sdk.http;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const HttpBase = @import("../http_base.zig").HttpBase;
const _connection = @import("../connection/_connection.zig");
const _protocol = @import("../protocol/_protocol.zig");
const Connection = _connection.Connection;
const Failure = _connection.Failure;
const Url = _protocol.Url;

/// What a client is checked by when a program hands one back.
const MAGIC: u32 = 0x48545443;

/// How many idle connections a client keeps.
pub const pool_most = 4;

/// The longest User-Agent a client keeps.
pub const agent_most = 95;

pub const Client = struct {
    magic: u32 = MAGIC,
    base: *HttpBase,
    socket_base: *SocketBase,
    /// HTTP_Verify.
    verify: bool = true,
    /// HTTP_Timeout, in seconds; 0 for none.
    timeout: u32 = 0,
    agent_length: u8 = 0,
    agent: [agent_most]u8 = undefined,
    /// The idle connections, the one idle longest first.
    idle: [pool_most]?*Connection = @splat(null),
    /// How a connection is made: the socket's, or a test's.
    connect: *const fn (client: *Client, url: Url, failure: *Failure) ?*Connection = _connection.connect,

    pub fn userAgent(client: *const Client) []const u8 {
        return client.agent[0..client.agent_length];
    }
};

/// The client behind a program's handle; null for one not made here.
pub fn of(handle: *http.Client) ?*Client {
    const client: *Client = @ptrCast(@alignCast(handle));
    return if (client.magic == MAGIC) client else null;
}

pub fn handleOf(client: *Client) *http.Client {
    return @ptrCast(client);
}

/// An idle connection that serves `url`, taken out of the pool; null
/// when there is none.
pub fn take(client: *Client, url: Url) ?*Connection {
    for (&client.idle, 0..) |*slot, index| {
        const connection = slot.* orelse continue;
        if (!connection.serves(url)) continue;
        // The ones after it move up.
        var at = index;
        while (at + 1 < pool_most) : (at += 1) client.idle[at] = client.idle[at + 1];
        client.idle[pool_most - 1] = null;
        return connection;
    }
    return null;
}

/// `connection` into the pool, behind the others; the one idle longest
/// closed when there is no room.
pub fn keep(client: *Client, connection: *Connection) void {
    if (client.idle[pool_most - 1] != null) {
        client.idle[0].?.close();
        var at: usize = 0;
        while (at + 1 < pool_most) : (at += 1) client.idle[at] = client.idle[at + 1];
        client.idle[pool_most - 1] = null;
    }
    for (&client.idle) |*slot| {
        if (slot.* == null) {
            slot.* = connection;
            return;
        }
    }
}

/// Every idle connection closed.
pub fn closeAll(client: *Client) void {
    for (&client.idle) |*slot| {
        if (slot.*) |connection| connection.close();
        slot.* = null;
    }
}
