// SPDX-License-Identifier: MIT
//! The connection to the server: one TCP socket, and SMB's messages on it
//! behind the four bytes that frame each ([MS-SMB2] 2.1) - a zero, then
//! the length in 24 bits, most significant byte first.
//!
//! **Finding the server.** GetAddrInfo gives every address the name has,
//! IPv6 and IPv4 as the stack orders them; each is tried in turn until one
//! takes the connection. The port goes into the address as it comes back,
//! where a sockaddr_in and a sockaddr_in6 both keep it.
//!
//! **Time-outs.** A connection that has not stood within
//! `connect_seconds` is given up for the next address; on a connection,
//! a send or a receive that has not moved within `io_seconds` ends it.
//! Both are the socket's own (SO_SNDTIMEO, SO_RCVTIMEO), so every wait is
//! one call. A server that is slow to work - a large directory, a copy on
//! its side - answers STATUS_PENDING first, and each of those starts the
//! receive's time again.
//!
//! **A connection that failed is cut** (`abort`): a send or a receive
//! that failed or ran out of time, a message that cannot be read in
//! step, a session given up - the socket goes with SO_LINGER at no time,
//! a reset, so the server ends the connection at once, and the session
//! with it and the files it had open. A FIN would wait behind what is
//! left to send, up to a whole WRITE, which a server that has stopped
//! taking it never sees: the connection stayed up on both ends, and a
//! file it had open stayed open on the server - a delete of it pending
//! until the server found the connection dead. Only the handler's own
//! end, after LOGOFF, closes with a FIN (`close`).
//!
//! **Something to read is told** with the opener's event signal
//! (SO_EVENTMASK FD_READ; the handler sets the signal), so the handler
//! can take a READ's answer that comes ahead between packets
//! (`readSome`).
//!
//! **Its rings are set before it connects**, so that the SYN already
//! offers the receive ring: the ring is the window the server may send
//! into, and a stream socket's 8 KiB took a 64 KiB READ's answer eight
//! round trips. On the 64-bit boards both rings are 1 MiB
//! (`receive_ring`, `send_ring`); elsewhere 64 KiB and the stack's own.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const smb = sdk.dos.smb;
const timer = sdk.devices.timer;
const SocketBase = sdk.interface.bsdsocket.SocketBase;

pub const connect_seconds: u32 = 10;
pub const io_seconds: u32 = 30;

/// The socket's receive ring, and so the window offered: 1 MiB on the
/// 64-bit boards, where emac.device and the stack hold a window that
/// comes at link speed; 64 KiB elsewhere. With 64 KiB the server waited
/// for the window to open, and reads stayed at 79 MB/s. With 256 KiB the
/// NAS's path lost a burst of its segments some 85 times a 200 MB read,
/// and the NAS repaired a few of them only when its 200 ms timeout ran
/// out - one read in two 0.2-0.8 s slower; with 512 KiB, or 1 MiB, it
/// repaired every one from the SACK blocks at once. A sealed READ's answer
/// of 1 MiB comes into it whole while the one before is opened.
const receive_ring: i32 = if (sdk.hardware.chip == .rv64sbi or sdk.hardware.chip == .a64psci) 1 << 20 else 64 * 1024;
/// Its send ring: on the 64-bit boards the stack's largest, 1 MiB - a
/// whole WRITE of `session.io_max` but its header - so that Send is done
/// once the piece is in the ring and the next is signed while the stack
/// sends this one; the stack's own 8 KiB where memory is short.
const send_ring: ?i32 = if (sdk.hardware.chip == .rv64sbi or sdk.hardware.chip == .a64psci) 1 << 20 else null;

/// What framing takes in front of a message.
pub const frame_header: usize = 4;

/// Why a connection could not be had: SMBSTAGE_RESOLVE with
/// GetAddrInfo's answer, SMBSTAGE_CONNECT with the last address's errno.
pub const Failure = struct {
    stage: u32 = smb.SMBSTAGE_DONE,
    code: i32 = 0,
};

pub const Connection = struct {
    sb: *SocketBase,
    socket: i32 = -1,

    pub fn connected(connection: *const Connection) bool {
        return connection.socket >= 0;
    }

    /// A connection to `server` at `port`, from its first address that
    /// takes one: true, or false with why in `failure`.
    pub fn open(connection: *Connection, server: [*:0]const u8, port: u16, failure: *Failure) bool {
        const sb = connection.sb;
        connection.abort();
        const hints: bsd.addrinfo = .{ .ai_socktype = bsd.SOCK_STREAM };
        var list: ?*bsd.addrinfo = null;
        const found = sb.GetAddrInfo(server, null, &hints, &list);
        if (found != 0 or list == null) {
            failure.* = .{ .stage = smb.SMBSTAGE_RESOLVE, .code = if (found != 0) found else bsd.EAI_NONAME };
            return false;
        }
        defer sb.FreeAddrInfo(list.?);
        failure.* = .{ .stage = smb.SMBSTAGE_CONNECT, .code = bsd.ETIMEDOUT };
        var entry = list;
        while (entry) |address_info| : (entry = address_info.ai_next) {
            const address = address_info.ai_addr orelse continue;
            const port_at: *align(1) u16 = @ptrCast(@as([*]u8, @ptrCast(address)) + 2);
            port_at.* = bsd.htons(port);
            const socket = sb.Socket(address_info.ai_family, bsd.SOCK_STREAM, 0);
            if (socket < 0) {
                failure.code = sb.Errno();
                continue;
            }
            _ = sb.SetSockOpt(socket, bsd.SOL_SOCKET, bsd.SO_RCVBUF, &receive_ring, @sizeOf(i32));
            if (send_ring) |bytes| _ = sb.SetSockOpt(socket, bsd.SOL_SOCKET, bsd.SO_SNDBUF, &bytes, @sizeOf(i32));
            setTime(sb, socket, bsd.SO_SNDTIMEO, connect_seconds);
            if (sb.Connect(socket, address, address_info.ai_addrlen) < 0) {
                failure.code = sb.Errno();
                _ = sb.CloseSocket(socket);
                continue;
            }
            setTime(sb, socket, bsd.SO_SNDTIMEO, io_seconds);
            setTime(sb, socket, bsd.SO_RCVTIMEO, io_seconds);
            const on: i32 = 1;
            _ = sb.SetSockOpt(socket, bsd.IPPROTO_TCP, bsd.TCP_NODELAY, &on, @sizeOf(i32));
            _ = sb.SetSockOpt(socket, bsd.SOL_SOCKET, bsd.SO_KEEPALIVE, &on, @sizeOf(i32));
            const told: u32 = bsd.FD_READ;
            _ = sb.SetSockOpt(socket, bsd.SOL_SOCKET, bsd.SO_EVENTMASK, &told, @sizeOf(u32));
            connection.socket = socket;
            failure.* = .{};
            return true;
        }
        return false;
    }

    /// The connection closed in order: what is left to send goes, then
    /// FIN.
    pub fn close(connection: *Connection) void {
        if (connection.socket < 0) return;
        _ = connection.sb.CloseSocket(connection.socket);
        connection.socket = -1;
    }

    /// The connection cut with a reset, and what was left to send dropped:
    /// the server lets go of the session at once.
    pub fn abort(connection: *Connection) void {
        if (connection.socket < 0) return;
        const cut: bsd.linger = .{ .l_onoff = 1, .l_linger = 0 };
        _ = connection.sb.SetSockOpt(connection.socket, bsd.SOL_SOCKET, bsd.SO_LINGER, &cut, @sizeOf(bsd.linger));
        connection.close();
    }

    /// `frame[frame_header..]` sent as one message, its framing written
    /// into `frame[0..frame_header]`. False when the connection failed,
    /// which cuts it.
    pub fn send(connection: *Connection, frame: []u8) bool {
        if (connection.socket < 0) return false;
        const length = frame.len - frame_header;
        frame[0] = 0;
        frame[1] = @truncate(length >> 16);
        frame[2] = @truncate(length >> 8);
        frame[3] = @truncate(length);
        var at: usize = 0;
        while (at < frame.len) {
            const sent = connection.sb.Send(connection.socket, frame[at..].ptr, @intCast(frame.len - at), 0);
            if (sent <= 0) {
                connection.abort();
                return false;
            }
            at += @intCast(sent);
        }
        return true;
    }

    /// The next message, read whole into `into`: null when the connection
    /// failed, closed or ran out of time, or the message is larger than
    /// `into` - all of which cut it, since nothing after it could be
    /// read in step.
    pub fn receive(connection: *Connection, into: []u8) ?[]u8 {
        const length = connection.frameLength(into.len) orelse return null;
        if (!connection.readAll(into[0..length])) return null;
        return into[0..length];
    }

    /// The next message's framing read, and its length: null when the
    /// connection failed, or the message is longer than `most` - which
    /// cuts it. The message is then the caller's to read, all of it,
    /// with `readAll`.
    pub fn frameLength(connection: *Connection, most: usize) ?usize {
        var framing: [frame_header]u8 = undefined;
        if (!connection.readAll(&framing)) return null;
        const length = @as(usize, framing[1]) << 16 | @as(usize, framing[2]) << 8 | framing[3];
        // Anything but a session message is not SMB's.
        if (framing[0] != 0 or length > most) {
            connection.abort();
            return null;
        }
        return length;
    }

    /// As much of `into` as the stream has: with `wait`, at least a byte,
    /// waiting for it; without, 0 when nothing has come. Null when the
    /// connection failed, closed or ran out of time, which cuts it.
    pub fn readSome(connection: *Connection, into: []u8, wait: bool) ?usize {
        if (connection.socket < 0) return null;
        const got = connection.sb.Recv(connection.socket, into.ptr, @intCast(into.len), if (wait) 0 else bsd.MSG_DONTWAIT);
        if (got > 0) return @intCast(got);
        if (got < 0 and !wait and connection.sb.Errno() == bsd.EWOULDBLOCK) return 0;
        connection.abort();
        return null;
    }

    /// `into` filled from the stream: false when the connection failed,
    /// closed or ran out of time, which cuts it.
    pub fn readAll(connection: *Connection, into: []u8) bool {
        if (connection.socket < 0) return false;
        var at: usize = 0;
        while (at < into.len) {
            const got = connection.sb.Recv(connection.socket, into[at..].ptr, @intCast(into.len - at), 0);
            if (got <= 0) {
                connection.abort();
                return false;
            }
            at += @intCast(got);
        }
        return true;
    }
};

/// A socket's time-out for sending or receiving, in seconds.
///
/// INPUTS:
/// - `sb` - bsdsocket.library.
/// - `socket` - the socket.
/// - `option` - SO_SNDTIMEO or SO_RCVTIMEO.
/// - `seconds` - how long.
fn setTime(sb: *SocketBase, socket: i32, option: i32, seconds: u32) void {
    const time: timer.TimeVal = .{ .secs = seconds };
    _ = sb.SetSockOpt(socket, bsd.SOL_SOCKET, option, &time, @sizeOf(timer.TimeVal));
}
