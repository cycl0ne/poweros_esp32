// SPDX-License-Identifier: MIT
//! The logon and the share ([MS-SMB2] 2.2.5 to 2.2.10, 3.2.5.3):
//! SESSION_SETUP with NTLMv2 in SPNEGO, the keys made from it, then
//! TREE_CONNECT to the share - and LOGOFF and TREE_DISCONNECT, which undo
//! them.
//!
//! **Two rounds.** The first SESSION_SETUP carries NTLMSSP's NEGOTIATE;
//! the server answers STATUS_MORE_PROCESSING_REQUIRED with the session's
//! id and its CHALLENGE; the second carries AUTHENTICATE, and the answer
//! is the logon's outcome. On 3.1.1 each message but that last answer
//! goes into the preauth hash the keys are made over.
//!
//! **A connection made again** names the session the lost one had
//! (PreviousSessionId, 3.3.5.5.3): once the user is the same, the server
//! ends that session and closes the files it had open - which would
//! otherwise stay open, and a delete of one pending, while the old
//! connection still stands on the server's side.
//!
//! **What is signed.** A session the server took as a guest's or an
//! anonymous one (SESSION_FLAG_IS_GUEST, IS_NULL) has no key both sides
//! know, so it is neither signed nor encrypted, and a share that asks for
//! either is refused it. Any other session signs every request from here
//! on and takes only signed answers - the last SESSION_SETUP answer
//! already, where the server signed it.
//!
//! **Encryption** covers every message when the session asks for it
//! (SESSION_FLAG_ENCRYPT_DATA) or the mount does (SMBF_ENCRYPT), and the
//! share's when the share asks for it (SHAREFLAG_ENCRYPT_DATA). It needs
//! 3.1.1 and a cipher the negotiation settled on; without them such a
//! mount stops with SMBSTAGE_SECURITY.
//!
//! **VALIDATE_NEGOTIATE** follows the tree's connection on 3.0 and 3.0.2
//! in a signed session: the server says again, signed, what it negotiated,
//! so a negotiation that was tampered with to a weaker dialect shows. A
//! server that does not answer it is let be; one that answers otherwise
//! than it negotiated is not.

const sdk = @import("sdk");
const smb = sdk.dos.smb;
const wire = @import("wire.zig");
const ntlm = @import("ntlm.zig");
const spnego = @import("spnego.zig");
const signing = @import("signing.zig");
const negotiate_area = @import("negotiate.zig");
const session_area = @import("session.zig");
const Session = session_area.Session;
const Reply = session_area.Reply;

/// The share's flag that says its messages must be encrypted.
pub const SHAREFLAG_ENCRYPT_DATA: u32 = 0x0000_8000;

/// The outcome of a logon or a tree connection that the server answered:
/// its status, or a security failure this side found.
pub const Outcome = union(enum) {
    status: u32,
    /// Signing or encryption that failed or cannot be had: SMBSECURITY_*.
    security: i32,
};

/// A logon as `identity`: the session's id, its flags and its keys.
///
/// INPUTS:
/// - `session` - negotiated.
/// - `identity` - who logs on.
/// - `inventions` - the client's random bytes for NTLMv2 and the time.
/// - `salt` - 4 random bytes for the cipher's nonces.
/// - `encrypt` - whether the mount asks for every message encrypted.
pub fn logon(session: *Session, identity: *const ntlm.Identity, inventions: *const ntlm.Inventions, salt: *const [4]u8, encrypt: bool) session_area.Error!Outcome {
    const cb = session.cb;
    var preauth = session.preauth;
    const hashed = session.dialect == smb.SMB2_DIALECT_0311;

    // NEGOTIATE.
    var request = session.begin(.session_setup);
    request.on_tree = false;
    const blob_at = setupFields(&request, session.previous_id);
    spnego.writeInit(&request.writer, &ntlm.negotiate);
    finishSetup(&request, blob_at);
    var replies = session_area.noReplies();
    try session.exchange(&request, &replies);
    if (hashed) preauth.add(cb, request.message(0));
    var reply = &replies[0];
    if (reply.status() != smb.STATUS_MORE_PROCESSING_REQUIRED) return .{ .status = failure(reply) };
    session.session_id = reply.header.session_id;
    if (hashed) preauth.add(cb, reply.message);
    const challenge_token = securityBuffer(reply) orelse return error.Protocol;
    const answer = spnego.parseResponse(challenge_token) orelse return error.Protocol;
    if (answer.state == spnego.reject) return .{ .status = smb.STATUS_LOGON_FAILURE };
    const challenge = ntlm.Challenge.parse(answer.token) orelse return error.Protocol;

    // AUTHENTICATE.
    request = session.begin(.session_setup);
    request.on_tree = false;
    const second_blob_at = setupFields(&request, session.previous_id);
    const response = spnego.beginResponse(&request.writer);
    const session_key = ntlm.authenticate(cb, &request.writer, identity, &challenge, inventions);
    spnego.endResponse(&request.writer, response);
    finishSetup(&request, second_blob_at);
    replies = session_area.noReplies();
    try session.exchange(&request, &replies);
    if (hashed) preauth.add(cb, request.message(0));
    reply = &replies[0];
    if (reply.status() != smb.STATUS_SUCCESS) return .{ .status = failure(reply) };
    session.previous_id = 0;

    var fields = reply.body();
    if (fields.uint16() != 9) return error.Protocol;
    session.session_flags = fields.uint16();
    const unkeyed = session.session_flags & (smb.SMB2_SESSION_FLAG_IS_GUEST | smb.SMB2_SESSION_FLAG_IS_NULL) != 0;
    if (unkeyed or session_key == null) {
        if (encrypt or session.session_flags & smb.SMB2_SESSION_FLAG_ENCRYPT_DATA != 0) return .{ .security = smb.SMBSECURITY_ENCRYPTION };
        return .{ .status = smb.STATUS_SUCCESS };
    }
    makeKeys(session, &session_key.?, &preauth.value, salt);

    // The answer was signed with the key just made, if it was signed.
    if (reply.header.flags & wire.FLAGS_SIGNED != 0) {
        if (!session.signer.verify(cb, reply.message)) return error.Security;
    } else if (hashed) {
        return error.Security;
    }
    session.signed = true;
    if (encrypt or session.session_flags & smb.SMB2_SESSION_FLAG_ENCRYPT_DATA != 0) {
        if (!session.keys.encrypts()) return .{ .security = smb.SMBSECURITY_ENCRYPTION };
        session.encrypt_all = true;
    }
    return .{ .status = smb.STATUS_SUCCESS };
}

/// SESSION_SETUP's own fields, naming the session `previous` (0 for
/// none): where its security buffer begins.
fn setupFields(request: *session_area.Request, previous: u64) usize {
    const writer = &request.writer;
    writer.uint16(25);
    writer.byte(0); // Flags
    writer.byte(@intCast(negotiate_area.SIGNING_ENABLED));
    writer.uint32(0); // Capabilities
    writer.uint32(0); // Channel
    writer.uint16(@intCast(wire.header_size + 24)); // SecurityBufferOffset
    writer.uint16(0); // SecurityBufferLength, filled in below
    writer.uint64(previous); // PreviousSessionId
    return writer.at;
}

/// The security buffer's length, now it is written.
fn finishSetup(request: *session_area.Request, blob_at: usize) void {
    const length = request.writer.at - blob_at;
    request.writer.patch16(request.starts[0] + wire.header_size + 14, @intCast(length));
}

/// The security buffer of a SESSION_SETUP answer.
fn securityBuffer(reply: *const Reply) ?[]const u8 {
    var fields = reply.body();
    const head = fields.take(8) orelse return null;
    if (wire.u16At(head, 0) != 9) return null;
    return fields.bufferAt(wire.u16At(head, 4), wire.u16At(head, 6));
}

/// A failed answer's status; a success where it should not be is a
/// logon failure.
fn failure(reply: *const Reply) u32 {
    return if (reply.failed()) reply.status() else smb.STATUS_LOGON_FAILURE;
}

/// The signing key and the cipher keys, from the session key as the
/// dialect makes them.
///
/// INPUTS:
/// - `session` - logged on.
/// - `session_key` - the logon's.
/// - `preauth` - 3.1.1's hash of the negotiation and the logon.
/// - `salt` - 4 random bytes for the nonces.
fn makeKeys(session: *Session, session_key: *const [16]u8, preauth: *const [64]u8, salt: *const [4]u8) void {
    const cb = session.cb;
    switch (session.dialect) {
        smb.SMB2_DIALECT_0202, smb.SMB2_DIALECT_0210 => {
            session.signer = .{ .algorithm = smb.SMB2_SIGNING_HMAC_SHA256, .key = session_key.* };
        },
        smb.SMB2_DIALECT_0300, smb.SMB2_DIALECT_0302 => {
            session.signer.algorithm = smb.SMB2_SIGNING_AES_CMAC;
            signing.derive(cb, session_key, signing.label_cmac_30, signing.context_sign_30, &session.signer.key);
        },
        else => {
            session.signer.algorithm = session.signing_algorithm;
            signing.derive(cb, session_key, signing.label_sign_311, preauth, &session.signer.key);
            if (session.cipher == smb.SMB2_CIPHER_NONE) return;
            const length: u32 = if (session.cipher == smb.SMB2_CIPHER_AES_256_GCM) 32 else 16;
            session.keys = .{ .cipher = session.cipher, .length = length, .salt = salt.* };
            signing.derive(cb, session_key, signing.label_c2s_311, preauth, session.keys.seal[0..length]);
            signing.derive(cb, session_key, signing.label_s2c_311, preauth, session.keys.open[0..length]);
        },
    }
}

/// TREE_CONNECT to `\\server\share`: the tree's id and flags. A share
/// that must be encrypted gets its messages encrypted, or `.security`
/// when the session cannot; one that is not a disk is refused as a share
/// not found.
///
/// INPUTS:
/// - `session` - logged on.
/// - `server` - the server's name as the mount gives it, Latin-1.
/// - `share` - the share's, Latin-1.
pub fn connectTree(session: *Session, server: []const u8, share: []const u8) session_area.Error!Outcome {
    var request = session.begin(.tree_connect);
    request.on_tree = false;
    const writer = &request.writer;
    writer.uint16(9);
    writer.uint16(0); // Flags
    writer.uint16(@intCast(wire.header_size + 8)); // PathOffset
    writer.uint16(@intCast(2 * (3 + server.len + share.len)));
    wire.latin1(writer, "\\\\");
    wire.latin1(writer, server);
    wire.latin1(writer, "\\");
    wire.latin1(writer, share);
    var replies = session_area.noReplies();
    try session.exchange(&request, &replies);
    const reply = &replies[0];
    if (reply.failed()) return .{ .status = reply.status() };
    var fields = reply.body();
    if (fields.uint16() != 16) return error.Protocol;
    const share_type = fields.byte();
    _ = fields.byte();
    session.share_flags = fields.uint32();
    _ = fields.uint32(); // Capabilities
    session.maximal_access = fields.uint32();
    session.tree_id = reply.header.tree_id;
    // A disk: not a pipe, not a printer.
    if (share_type != 1) return .{ .status = smb.STATUS_BAD_NETWORK_NAME };
    if (session.share_flags & SHAREFLAG_ENCRYPT_DATA != 0) {
        if (!session.keys.encrypts()) return .{ .security = smb.SMBSECURITY_ENCRYPTION };
        session.encrypt_tree = true;
    }
    if (session.signed and (session.dialect == smb.SMB2_DIALECT_0300 or session.dialect == smb.SMB2_DIALECT_0302)) {
        if (!try validateNegotiate(session)) return .{ .security = smb.SMBSECURITY_SIGNATURE };
    }
    return .{ .status = smb.STATUS_SUCCESS };
}

/// FSCTL_VALIDATE_NEGOTIATE_INFO: false when the server's signed answer
/// says it negotiated otherwise than it did.
fn validateNegotiate(session: *Session) session_area.Error!bool {
    var request = session.begin(.ioctl);
    const writer = &request.writer;
    const dialects = negotiate_area.dialects;
    const input_length: u32 = 4 + 16 + 2 + 2 + 2 * dialects.len;
    writer.uint16(57);
    writer.uint16(0);
    writer.uint32(0x0014_0204); // FSCTL_VALIDATE_NEGOTIATE_INFO
    writer.raw(&session_area.related_file);
    writer.uint32(wire.header_size + 56); // InputOffset
    writer.uint32(input_length);
    writer.uint32(0); // MaxInputResponse
    writer.uint32(0); // OutputOffset
    writer.uint32(0); // OutputCount
    writer.uint32(24); // MaxOutputResponse
    writer.uint32(1); // Flags: an FSCTL
    writer.uint32(0);
    writer.uint32(negotiate_area.capabilities);
    writer.raw(&session.client_guid);
    writer.uint16(negotiate_area.SIGNING_ENABLED);
    writer.uint16(dialects.len);
    for (dialects) |dialect| writer.uint16(dialect);
    var replies = session_area.noReplies();
    try session.exchange(&request, &replies);
    const reply = &replies[0];
    if (reply.failed()) return true;
    var fields = reply.body();
    const head = fields.take(48) orelse return error.Protocol;
    if (wire.u16At(head, 0) != 49) return error.Protocol;
    const out = fields.bufferAt(wire.u32At(head, 32), wire.u32At(head, 36)) orelse return error.Protocol;
    if (out.len < 24) return false;
    return wire.u32At(out, 0) == session.server_capabilities and
        wire.same(out[4..20], &session.server_guid) and
        wire.u16At(out, 20) == session.server_security and
        wire.u16At(out, 22) == session.dialect;
}

/// TREE_DISCONNECT and LOGOFF, answered or not: the server forgets the
/// session either way once the connection closes.
pub fn logoff(session: *Session) void {
    var replies = session_area.noReplies();
    if (session.tree_id != 0) {
        var request = session.begin(.tree_disconnect);
        request.writer.uint16(4);
        request.writer.uint16(0);
        session.exchange(&request, &replies) catch return;
        session.tree_id = 0;
    }
    if (session.session_id != 0) {
        var request = session.begin(.logoff);
        request.on_tree = false;
        request.writer.uint16(4);
        request.writer.uint16(0);
        replies = session_area.noReplies();
        session.exchange(&request, &replies) catch return;
        session.session_id = 0;
    }
}
