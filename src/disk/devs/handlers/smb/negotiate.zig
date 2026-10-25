// SPDX-License-Identifier: MIT
//! NEGOTIATE ([MS-SMB2] 2.2.3, 2.2.4): the first request on a connection,
//! which settles the dialect and what the server can do.
//!
//! **One request offers every dialect** from 2.0.2 to 3.1.1, and the
//! server answers with the one it takes. Signing is offered, not
//! required, so a server may still give a guest's session; an
//! authenticated session is signed whatever was offered.
//!
//! **3.1.1's contexts** go with it: preauth integrity (SHA-512 over this
//! request, its answer and the logon's messages, with 32 random bytes of
//! salt), the ciphers - AES-128-GCM, then AES-256-GCM - and the signing
//! algorithms, AES-GMAC, then AES-CMAC. A server that answers with
//! another dialect ignores them; one that answers 3.1.1 says which of
//! each it took, and no cipher when it would rather not encrypt.
//!
//! **The ENCRYPTION capability goes with them**, as a client that can
//! encrypt says: a server may pick a cipher from the context only for a
//! client that has it. On 3.0 and 3.0.2 it stands for AES-128-CCM, which
//! is not here, so no keys are made there, and a session or share that
//! must be encrypted is reached on 3.1.1 or not at all.

const sdk = @import("sdk");
const smb = sdk.dos.smb;
const wire = @import("wire.zig");
const session_area = @import("session.zig");
const Session = session_area.Session;

/// The dialects offered, oldest first.
pub const dialects = [_]u16{
    smb.SMB2_DIALECT_0202,
    smb.SMB2_DIALECT_0210,
    smb.SMB2_DIALECT_0300,
    smb.SMB2_DIALECT_0302,
    smb.SMB2_DIALECT_0311,
};

/// SecurityMode's bits.
pub const SIGNING_ENABLED: u16 = 0x0001;
pub const SIGNING_REQUIRED: u16 = 0x0002;

/// The capabilities said: credits that cover more than 64 KiB, which 2.1
/// and up count charges by, and encryption.
pub const CAP_LARGE_MTU: u32 = 0x0000_0004;
pub const CAP_ENCRYPTION: u32 = 0x0000_0040;
pub const capabilities: u32 = CAP_LARGE_MTU | CAP_ENCRYPTION;

/// The contexts' types.
const PREAUTH_INTEGRITY_CAPABILITIES: u16 = 0x0001;
const ENCRYPTION_CAPABILITIES: u16 = 0x0002;
const SIGNING_CAPABILITIES: u16 = 0x0008;
const HASH_SHA512: u16 = 0x0001;

/// The ciphers and the signing algorithms offered, the one wanted first.
const ciphers = [_]u16{ smb.SMB2_CIPHER_AES_128_GCM, smb.SMB2_CIPHER_AES_256_GCM };
const signing_algorithms = [_]u16{ smb.SMB2_SIGNING_AES_GMAC, smb.SMB2_SIGNING_AES_CMAC };

/// The negotiation made: the session's dialect and what the server said
/// about itself. A status other than success is in the answer; a server
/// that answers with nothing this side offered, or with a 3.1.1 answer
/// that leaves out preauth integrity, is a protocol error.
///
/// INPUTS:
/// - `session` - connected, nothing negotiated yet.
/// - `salt` - 32 random bytes for preauth integrity.
pub fn negotiate(session: *Session, salt: *const [32]u8) session_area.Error!u32 {
    var request = session.begin(.negotiate);
    request.on_tree = false;
    const writer = &request.writer;
    const start = request.starts[0];
    writer.uint16(36);
    writer.uint16(dialects.len);
    writer.uint16(SIGNING_ENABLED);
    writer.uint16(0);
    writer.uint32(capabilities);
    writer.raw(&session.client_guid);
    const context_offset_at = writer.at;
    writer.uint32(0); // NegotiateContextOffset, filled in below
    writer.uint16(3); // NegotiateContextCount
    writer.uint16(0);
    for (dialects) |dialect| writer.uint16(dialect);

    // The contexts, each at an 8-byte boundary.
    writer.alignTo(8);
    writer.patch32(context_offset_at, @intCast(writer.at - start));
    context(writer, PREAUTH_INTEGRITY_CAPABILITIES, 4 + 2 + 32);
    writer.uint16(1);
    writer.uint16(32);
    writer.uint16(HASH_SHA512);
    writer.raw(salt);
    writer.alignTo(8);
    context(writer, ENCRYPTION_CAPABILITIES, 2 + 2 * ciphers.len);
    writer.uint16(ciphers.len);
    for (ciphers) |cipher| writer.uint16(cipher);
    writer.alignTo(8);
    context(writer, SIGNING_CAPABILITIES, 2 + 2 * signing_algorithms.len);
    writer.uint16(signing_algorithms.len);
    for (signing_algorithms) |algorithm| writer.uint16(algorithm);

    var replies = session_area.noReplies();
    try session.exchange(&request, &replies);
    const reply = &replies[0];
    if (reply.failed()) return reply.status();

    var reader = reply.body();
    const fields = reader.take(64) orelse return error.Protocol;
    if (wire.u16At(fields, 0) != 65) return error.Protocol;
    const dialect = wire.u16At(fields, 4);
    for (dialects) |offered| {
        if (offered == dialect) break;
    } else return error.Protocol;
    session.dialect = dialect;
    session.server_security = wire.u16At(fields, 2);
    @memcpy(&session.server_guid, fields[8..24]);
    session.server_capabilities = wire.u32At(fields, 24);
    session.max_transact = wire.u32At(fields, 28);
    session.max_read = wire.u32At(fields, 32);
    session.max_write = wire.u32At(fields, 36);
    session.server_time = wire.u64At(fields, 40);
    if (dialect != smb.SMB2_DIALECT_0311) return smb.STATUS_SUCCESS;

    // 3.1.1: the contexts the server took, and the hash of both messages.
    const count = wire.u16At(fields, 6);
    var at: usize = wire.u32At(fields, 60);
    var preauth = false;
    for (0..count) |_| {
        at = (at + 7) & ~@as(usize, 7);
        const head = reader.bufferAt(at, 8) orelse return error.Protocol;
        const kind = wire.u16At(head, 0);
        const length = wire.u16At(head, 2);
        const data = reader.bufferAt(at + 8, length) orelse return error.Protocol;
        at += 8 + length;
        switch (kind) {
            PREAUTH_INTEGRITY_CAPABILITIES => {
                if (data.len < 6 or wire.u16At(data, 0) != 1 or wire.u16At(data, 4) != HASH_SHA512) return error.Protocol;
                preauth = true;
            },
            ENCRYPTION_CAPABILITIES => {
                if (data.len < 4 or wire.u16At(data, 0) != 1) return error.Protocol;
                const cipher = wire.u16At(data, 2);
                for (ciphers) |offered| {
                    if (offered == cipher) session.cipher = cipher;
                }
            },
            SIGNING_CAPABILITIES => {
                if (data.len < 4 or wire.u16At(data, 0) != 1) return error.Protocol;
                const algorithm = wire.u16At(data, 2);
                for (signing_algorithms) |offered| {
                    if (offered == algorithm) session.signing_algorithm = algorithm;
                }
            },
            else => {},
        }
    }
    if (!preauth) return error.Protocol;
    session.preauth = .{};
    session.preauth.add(session.cb, request.message(0));
    session.preauth.add(session.cb, reply.message);
    return smb.STATUS_SUCCESS;
}

/// A context's head: its type and its data's length.
fn context(writer: *wire.Writer, kind: u16, length: usize) void {
    writer.uint16(kind);
    writer.uint16(@intCast(length));
    writer.uint32(0);
}
