// SPDX-License-Identifier: MIT
//! A session brought up from nothing, for a program that has a server's
//! name and nothing else: the connection, the negotiation and the logon,
//! each stage's outcome written into an `SmbResult` - the same account of
//! how far it got that a mounted share's handler writes, so one set of
//! words says what happened whichever of them tried.
//!
//! **Why it is here and not in the handler.** The handler brings its
//! session up for the share its startup names and keeps it for as long as
//! the share is mounted. A tool that is looking at a server has no share
//! yet - that is what it is asking about - so it brings a session up, asks
//! `srvsvc` what shares there are (`shares.zig`), and takes it down again.
//!
//! **Anonymous first.** An account with no user and no password logs on
//! anonymously, which a server may take, may take as a guest, or may
//! refuse. `refusedCredentials` says whether a refusal is one that a user
//! and a password would answer, so a tool knows when to ask for them
//! rather than give up.

const sdk = @import("sdk");
const dos = sdk.dos;
const smb = dos.smb;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const connection_area = @import("connection.zig");
const session_area = @import("session.zig");
const negotiate_area = @import("negotiate.zig");
const logon_area = @import("logon.zig");
const shares_area = @import("shares.zig");
const ntlm = @import("ntlm.zig");
const names = @import("names.zig");
const Session = session_area.Session;
const Error = session_area.Error;

/// Who logs on: nothing in it is an anonymous logon.
pub const Account = struct {
    /// Latin-1, as the share file and the startup hold them.
    user: []const u8 = &.{},
    domain: []const u8 = &.{},
    /// The password's NT hash - MD4 over its UTF-16 - which is all the
    /// logon needs. Null with no user is anonymous; null with one is the
    /// empty password.
    nt_hash: ?[16]u8 = null,
};

/// The buffers a session needs, which the caller allocates: a session is
/// too large to stand in a program's own memory.
pub const Buffers = struct {
    send: []u8,
    receive: []u8,
};

/// How much a session's two buffers must hold.
pub const send_size = session_area.send_size;
pub const receive_size = session_area.receive_size;

/// A session set up on `buffers`, connected to nothing yet.
pub fn sessionOn(sb: *SocketBase, cb: *CryptoBase, buffers: Buffers) Session {
    return .{
        .cb = cb,
        .connection = .{ .sb = sb },
        .send_buffer = buffers.send,
        .receive_buffer = buffers.receive,
    };
}

/// The connection, the negotiation and the logon, no share connected:
/// true when the session is logged on, or false with the stage it stopped
/// at in `result`.
///
/// INPUTS:
/// - `session` - made by `sessionOn`, and reset if it was used before.
/// - `server` - the server by name or address, NUL-terminated.
/// - `port` - its port; 0 is SMB's own.
/// - `account` - who logs on.
/// - `result` - written at every stage.
pub fn open(session: *Session, server: [*:0]const u8, port: u16, account: *const Account, result: *smb.SmbResult) bool {
    const cb = session.cb;
    result.* = .{};
    if (allZero(&session.client_guid)) cb.RandomBytes(&session.client_guid, 16);

    var failure: connection_area.Failure = .{};
    if (!session.connection.open(server, if (port == 0) smb.SMB_PORT else port, &failure)) {
        result.stage = failure.stage;
        result.@"error" = failure.code;
        return false;
    }

    var salt: [32]u8 = undefined;
    cb.RandomBytes(&salt, salt.len);
    const negotiated = negotiate_area.negotiate(session, &salt) catch |err| return stopped(result, smb.SMBSTAGE_NEGOTIATE, err);
    if (negotiated != smb.STATUS_SUCCESS) {
        result.stage = smb.SMBSTAGE_NEGOTIATE;
        result.status = negotiated;
        return false;
    }
    result.dialect = session.dialect;

    // The user in capitals as NTLMv2 hashes it, and this machine's name
    // for the server's logs.
    var user_upper: [smb.SMB_USER_MAX + 1]u8 = undefined;
    const user = account.user[0..@min(account.user.len, smb.SMB_USER_MAX)];
    for (user, 0..) |char, at| user_upper[at] = names.upper(char);
    var host: [64]u8 = @splat(0);
    _ = session.connection.sb.GetHostName(&host, host.len - 1);
    const identity: ntlm.Identity = .{
        .user = user,
        .user_upper = user_upper[0..user.len],
        .domain = account.domain,
        .workstation = untilNul(&host),
        .nt_hash = account.nt_hash,
    };
    var inventions: ntlm.Inventions = .{ .client_challenge = undefined, .random_session_key = undefined, .time = session.server_time };
    cb.RandomBytes(&inventions.client_challenge, 8);
    cb.RandomBytes(&inventions.random_session_key, 16);
    var nonce_salt: [4]u8 = undefined;
    cb.RandomBytes(&nonce_salt, 4);
    const logged_on = logon_area.logon(session, &identity, &inventions, &nonce_salt, false) catch |err| return stopped(result, smb.SMBSTAGE_LOGON, err);
    switch (logged_on) {
        .security => |reason| {
            result.stage = smb.SMBSTAGE_SECURITY;
            result.@"error" = reason;
            return false;
        },
        .status => |status| if (status != smb.STATUS_SUCCESS) {
            result.stage = smb.SMBSTAGE_LOGON;
            result.status = status;
            return false;
        },
    }
    result.session_flags = session.session_flags;
    result.signing = if (session.signed) session.signer.algorithm else smb.SMB2_SIGNING_NONE;
    if (session.encrypt_all) result.cipher = session.keys.cipher;
    return true;
}

/// Every share the server has, as `srvsvc` says: see `shares.listOf`.
pub fn list(session: *Session, server: []const u8, into: []shares_area.Share, gather: []u8) Error!shares_area.Listing {
    return shares_area.listOf(session, server, into, gather);
}

/// One share connected to, to see whether it can be: the tree's outcome,
/// the session left with no tree afterwards. A mount is the handler's
/// work, not a tool's; this only answers whether the share is there and
/// the user may have it.
pub fn reach(session: *Session, server: []const u8, share: []const u8) Error!u32 {
    const tree = try logon_area.connectTree(session, server, share);
    const status = switch (tree) {
        .security => smb.STATUS_ACCESS_DENIED,
        .status => |value| value,
    };
    if (session.tree_id != 0) {
        var request = session.begin(.tree_disconnect);
        request.writer.uint16(4);
        request.writer.uint16(0);
        var replies = session_area.noReplies();
        session.exchange(&request, &replies) catch {};
        session.tree_id = 0;
        session.encrypt_tree = false;
    }
    return status;
}

/// The session logged off and the connection closed: what it had is
/// forgotten, so the same session may be opened again.
pub fn close(session: *Session) void {
    if (session.connection.connected()) logon_area.logoff(session);
    session.reset();
    session.previous_id = 0;
}

/// Whether a result that stopped at the logon would be answered by a user
/// and a password: the server knows no such user, the password was wrong,
/// or it will not have an anonymous logon at all.
pub fn refusedCredentials(result: *const smb.SmbResult) bool {
    if (result.stage != smb.SMBSTAGE_LOGON) return false;
    return switch (result.status) {
        smb.STATUS_LOGON_FAILURE,
        smb.STATUS_WRONG_PASSWORD,
        smb.STATUS_NO_SUCH_USER,
        smb.STATUS_ACCESS_DENIED,
        smb.STATUS_NETWORK_ACCESS_DENIED,
        => true,
        else => false,
    };
}

/// Whether the server would not say what shares it has without a user:
/// the logon worked, as a guest or anonymously, and `srvsvc` then refused
/// the question.
pub fn refusedQuestion(listing: *const shares_area.Listing) bool {
    if (listing.status == shares_area.ERROR_ACCESS_DENIED) return true;
    return switch (listing.pipe_status) {
        smb.STATUS_ACCESS_DENIED, smb.STATUS_NETWORK_ACCESS_DENIED, smb.STATUS_LOGON_FAILURE => true,
        else => false,
    };
}

/// A stage that broke off: a signature or seal that was wrong is a
/// security failure, anything else a failure at the stage itself.
fn stopped(result: *smb.SmbResult, stage: u32, err: Error) bool {
    result.stage = stage;
    if (err == error.Security) {
        result.stage = smb.SMBSTAGE_SECURITY;
        result.@"error" = smb.SMBSECURITY_SIGNATURE;
    }
    return false;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

/// The bytes of a NUL-terminated array up to its NUL.
pub fn untilNul(bytes: []const u8) []const u8 {
    for (bytes, 0..) |byte, at| if (byte == 0) return bytes[0..at];
    return bytes;
}
