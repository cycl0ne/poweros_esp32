// SPDX-License-Identifier: MIT
//! The security manager over LE: a controller's LE pairings, on the
//! security manager's channel (CID 6), and an LE bond's link encrypted.
//! The library is the central of its LE links and begins each pairing as
//! the specification's initiator - for PairBTDevice, or for a device's
//! Security Request; pairing.zig keeps the pairing's agent, questions,
//! notices and end, as it does over BR/EDR.
//!
//! **The pairing.** A Pairing Request with the agent's IO capability, no
//! out-of-band data, bonding, protection from a man in the middle where
//! the agent's user can give it, Secure Connections, a key of up to 16
//! bytes, and the device's keys asked for: its long term key (where
//! Secure Connections does not make one) and its identity; this side
//! gives none. The device's Pairing Response settles the rest: a key of
//! fewer than MIN_ENCRYPTION_KEY_SIZE bytes ends it; Secure Connections
//! where both set it; the method by the two IO capabilities, Just Works
//! where neither asks for the protection.
//!
//! **Secure Connections**: a P-256 key pair for the pairing, the public
//! keys exchanged - the device's checked on the curve and against this
//! side's own - and the shared secret; then by the method: Just Works or
//! Numeric Comparison (the device's confirm, the nonces exchanged and the
//! confirm checked, the six digits both show for the agent to compare),
//! or Passkey Entry (twenty rounds of confirms and nonces, a bit of the
//! passkey each). f5 makes the MacKey and the long term key, f6 the two
//! DHKey checks; the link is encrypted with the long term key.
//! **Legacy pairing**: the temporary key - 0 for Just Works, the passkey
//! otherwise - c1's confirms, the randoms exchanged and checked, s1's
//! short-term key, the link encrypted with it, and the long term key the
//! device gives then.
//!
//! **The agent.** A number to compare is asked of it (BTAK_CONFIRM), a
//! passkey the device shows to be typed (BTAK_PASSKEY), or one shown it
//! to be typed on the device (a notice); Just Works is accepted at once
//! for the library's own pairing, and for the device's an agent that can
//! answer yes or no is asked whether it may pair.
//!
//! **Kept**: a bond where both asked for bonding and a long term key was
//! made or given, by the device's identity address where it gave one,
//! with its identity resolving key; never with the specification's debug
//! key.
//!
//! **A bonded device's link** - one the library made, or one whose device
//! asks for security - is encrypted with the bond's key. A link from a
//! resolvable private address is the bond's whose identity resolving key
//! made it.
//!
//! Pure, as the rest of the layer: the cipher, the random bytes and the
//! curve come through the layer's port (smpcrypto.zig).

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const l2cap = bluetooth.l2cap;
const _hci = @import("_hci.zig");
const Hci = _hci.Hci;
const acl = @import("acl.zig");
const bonds = @import("bonds.zig");
const connections = @import("connections.zig");
const Connection = connections.Connection;
const pairing = @import("pairing.zig");
const smpcrypto = @import("smpcrypto.zig");
const Crypto = smpcrypto.Crypto;

// --- the protocol -----------------------------------------------------------------

/// The security manager's commands.
pub const PAIRING_REQUEST: u8 = 0x01;
pub const PAIRING_RESPONSE: u8 = 0x02;
pub const PAIRING_CONFIRM: u8 = 0x03;
pub const PAIRING_RANDOM: u8 = 0x04;
pub const PAIRING_FAILED: u8 = 0x05;
pub const ENCRYPTION_INFORMATION: u8 = 0x06;
pub const CENTRAL_IDENTIFICATION: u8 = 0x07;
pub const IDENTITY_INFORMATION: u8 = 0x08;
pub const IDENTITY_ADDRESS_INFORMATION: u8 = 0x09;
pub const SIGNING_INFORMATION: u8 = 0x0A;
pub const SECURITY_REQUEST: u8 = 0x0B;
pub const PAIRING_PUBLIC_KEY: u8 = 0x0C;
pub const PAIRING_DHKEY_CHECK: u8 = 0x0D;
pub const KEYPRESS_NOTIFICATION: u8 = 0x0E;

/// IO capabilities: BTIO_*'s values.
pub const IO_DISPLAY_ONLY: u8 = 0x00;
pub const IO_DISPLAY_YES_NO: u8 = 0x01;
pub const IO_KEYBOARD_ONLY: u8 = 0x02;
pub const IO_NO_INPUT_OUTPUT: u8 = 0x03;
pub const IO_KEYBOARD_DISPLAY: u8 = 0x04;

/// AuthReq: bonding, protection from a man in the middle, Secure
/// Connections.
pub const AUTH_BONDING: u8 = 0x01;
pub const AUTH_BONDING_MASK: u8 = 0x03;
pub const AUTH_MITM: u8 = 0x04;
pub const AUTH_SC: u8 = 0x08;

/// The keys a side gives: its long term key with EDIV and Rand, its
/// identity, its signing key.
pub const KEYDIST_ENC: u8 = 0x01;
pub const KEYDIST_ID: u8 = 0x02;
pub const KEYDIST_SIGN: u8 = 0x04;

/// Pairing Failed's reasons.
pub const REASON_PASSKEY_ENTRY_FAILED: u8 = 0x01;
pub const REASON_OOB_NOT_AVAILABLE: u8 = 0x02;
pub const REASON_AUTHENTICATION_REQUIREMENTS: u8 = 0x03;
pub const REASON_CONFIRM_VALUE_FAILED: u8 = 0x04;
pub const REASON_PAIRING_NOT_SUPPORTED: u8 = 0x05;
pub const REASON_ENCRYPTION_KEY_SIZE: u8 = 0x06;
pub const REASON_COMMAND_NOT_SUPPORTED: u8 = 0x07;
pub const REASON_UNSPECIFIED: u8 = 0x08;
pub const REASON_REPEATED_ATTEMPTS: u8 = 0x09;
pub const REASON_INVALID_PARAMETERS: u8 = 0x0A;
pub const REASON_DHKEY_CHECK_FAILED: u8 = 0x0B;
pub const REASON_NUMERIC_COMPARISON_FAILED: u8 = 0x0C;
pub const REASON_KEY_REJECTED: u8 = 0x0F;

/// The longest key: a key's size is agreed from 7 to this.
pub const MAX_KEY_SIZE: u8 = 16;

/// Passkey Entry's rounds: a bit of the passkey each.
const PASSKEY_ROUNDS: u8 = 20;

// --- a link's pairing -------------------------------------------------------------

/// What a pairing waits for.
pub const Phase = enum(u8) {
    idle,
    /// The device's Pairing Response.
    response,
    /// The agent's answer; what follows it in `then`.
    user,
    /// The device's public key, this side's sent.
    public_key,
    /// The device's Pairing Confirm.
    confirm,
    /// The device's Pairing Random, this side's sent.
    random,
    /// The device's DHKey Check, this side's sent.
    check,
    /// The link encrypted (Encryption Change); the device's keys may come
    /// meanwhile.
    encryption,
    /// The device's keys.
    keys,
};

/// How the two sides authenticate each other: nothing to compare, a
/// number both show, a passkey the device shows and the agent's user
/// types, or one shown to the agent's user to type on the device.
pub const Method = enum(u8) { just_works, compare, type_passkey, show_passkey };

/// What follows the agent's answer: legacy's confirm, Passkey Entry's
/// rounds, or the DHKey check.
const Then = enum(u8) { legacy_confirm, passkey_rounds, check };

/// A link's pairing, while it is under way; cleared at its end.
pub const Smp = struct {
    phase: Phase = .idle,
    method: Method = .just_works,
    then: Then = .legacy_confirm,
    /// Both sides set Secure Connections.
    secure: bool = false,
    /// The device's public key is the specification's debug key.
    debug: bool = false,
    /// The Pairing Request and Response, as sent.
    request: [7]u8 = @splat(0),
    response: [7]u8 = @splat(0),
    /// The key's size agreed, in bytes.
    key_size: u8 = MAX_KEY_SIZE,
    /// The keys the device is still to give (KEYDIST_*).
    expected: u8 = 0,
    /// Passkey Entry's passkey, and the round it is in.
    passkey: u32 = 0,
    round: u8 = 0,
    /// Legacy pairing's temporary key.
    tk: [16]u8 = @splat(0),
    /// This side's random or nonce, the device's, and the device's
    /// confirm.
    ours: [16]u8 = @splat(0),
    theirs: [16]u8 = @splat(0),
    confirm: [16]u8 = @splat(0),
    /// This side's key pair - the private key the most significant byte
    /// first, the public key in SMP's order - the device's public key,
    /// and the secret they share, in SMP's order.
    private_key: [32]u8 = @splat(0),
    public_key: [64]u8 = @splat(0),
    peer_key: [64]u8 = @splat(0),
    dhkey: [32]u8 = @splat(0),
    mac_key: [16]u8 = @splat(0),
    /// The long term key: f5's, or the device's.
    ltk: [16]u8 = @splat(0),
    /// What the device gave: its long term key's EDIV and Rand, its
    /// identity resolving key and address. Half a key given marks it in.
    ltk_in: bool = false,
    has_ltk: bool = false,
    ediv: u16 = 0,
    rand: [8]u8 = @splat(0),
    irk_in: bool = false,
    irk: [16]u8 = @splat(0),
    has_irk: bool = false,
    identity: bluetooth.BTAddress = .{},
    has_identity: bool = false,
};

/// Whether the controller can pair over LE: links as their central, LE's
/// encryption, and the port's cryptography.
pub fn canPair(layer: *const Hci) bool {
    return connections.canInitiate(layer) and _hci.supports(layer, hci.CMDBIT_LE_ENABLE_ENCRYPTION) and layer.crypto != null;
}

/// The IO capability this side pairs with over LE for an agent's
/// (BTIO_*, which are LE's own values), or for none.
pub fn ioOf(capability: ?u32) u8 {
    const value = capability orelse return IO_NO_INPUT_OUTPUT;
    return if (value <= IO_KEYBOARD_DISPLAY) @intCast(value) else IO_NO_INPUT_OUTPUT;
}

/// The method for an initiator's and a responder's IO capability, as the
/// specification's table gives it where a side asks for protection from a
/// man in the middle: rows the responder's, columns the initiator's.
pub fn methodOf(initiator: u8, responder: u8, secure_connections: bool) Method {
    if (initiator > IO_KEYBOARD_DISPLAY or responder > IO_KEYBOARD_DISPLAY) return .just_works;
    const JW = Method.just_works;
    const NC = Method.compare;
    const IN = Method.type_passkey;
    const OUT = Method.show_passkey;
    const legacy = [5][5]Method{
        .{ JW, JW, IN, JW, IN },
        .{ JW, JW, IN, JW, IN },
        .{ OUT, OUT, IN, JW, OUT },
        .{ JW, JW, JW, JW, JW },
        .{ OUT, OUT, IN, JW, OUT },
    };
    const sc = [5][5]Method{
        .{ JW, JW, IN, JW, IN },
        .{ JW, NC, IN, JW, NC },
        .{ OUT, OUT, IN, JW, OUT },
        .{ JW, JW, JW, JW, JW },
        .{ OUT, NC, IN, JW, NC },
    };
    return if (secure_connections) sc[responder][initiator] else legacy[responder][initiator];
}

/// What a pairing that ended with Pairing Failed's `reason` answers: an
/// HCI status, as a BR/EDR pairing's.
pub fn resultOf(reason: u8) i32 {
    return switch (reason) {
        REASON_AUTHENTICATION_REQUIREMENTS, REASON_PAIRING_NOT_SUPPORTED, REASON_COMMAND_NOT_SUPPORTED, REASON_KEY_REJECTED, 0x0D, 0x0E => hci.HCI_ERR_PAIRING_NOT_ALLOWED,
        REASON_ENCRYPTION_KEY_SIZE => hci.HCI_ERR_INSUFFICIENT_SECURITY,
        REASON_REPEATED_ATTEMPTS => hci.HCI_ERR_REPEATED_ATTEMPTS,
        else => hci.HCI_ERR_AUTHENTICATION_FAILURE,
    };
}

/// The bond of the device on the link: by its address, or - a resolvable
/// private one - by the identity resolving key that made it.
pub fn bondOf(layer: *Hci, connection: *const Connection) ?*bonds.Bond {
    if (bonds.find(layer, connection.address)) |bond| return bond;
    const address = connection.address;
    if (address.kind != bluetooth.BTADDR_LE_RANDOM or !smpcrypto.resolvable(&address.bytes)) return null;
    const port = portOf(layer) orelse return null;
    for (&layer.bonds) |*bond| {
        if (!bond.used or bond.gone or !bond.has_irk) continue;
        if (smpcrypto.resolves(port, &bond.irk, &address.bytes)) return bond;
    }
    return null;
}

fn portOf(layer: *Hci) ?*const Crypto {
    if (layer.crypto) |*port| return port;
    return null;
}

// --- begun ------------------------------------------------------------------------

/// The link's pairing begun - pairing.zig's record set for it: the
/// Pairing Request sent. False when it could not be.
pub fn start(layer: *Hci, connection: *Connection) bool {
    if (portOf(layer) == null) return false;
    const record = &connection.pairing;
    const io = record.our_io;
    const auth = AUTH_BONDING | AUTH_SC | (if (io != IO_NO_INPUT_OUTPUT) AUTH_MITM else 0);
    record.our_auth = auth;
    record.stage = .authenticating;
    connection.smp = .{ .phase = .response };
    connection.smp.request = .{ PAIRING_REQUEST, io, 0, auth, MAX_KEY_SIZE, 0, KEYDIST_ENC | KEYDIST_ID };
    return send(layer, connection, &connection.smp.request);
}

/// The link of a bonded device encrypted with the bond's key: false when
/// the command could not be queued.
pub fn encryptBond(layer: *Hci, connection: *Connection, bond: *const bonds.Bond) bool {
    return encrypt(layer, connection, &bond.key, bond.ediv, &bond.rand, bond.key_size);
}

/// LE Enable Encryption on the link with `key`, cut to `key_size` bytes.
fn encrypt(layer: *Hci, connection: *Connection, key: *const [16]u8, ediv: u16, rand: *const [8]u8, key_size: u8) bool {
    var params: [28]u8 = undefined;
    put16(params[0..2], connection.handle);
    params[2..10].* = rand.*;
    put16(params[10..12], ediv);
    params[12..28].* = key.*;
    const kept = @min(key_size, MAX_KEY_SIZE);
    @memset(params[12 + kept .. 28], 0);
    if (!_hci.command(layer, hci.HCI_OP_LE_ENABLE_ENCRYPTION, &params, _hci.COMMAND_TIMEOUT_MS)) return false;
    connection.pairing.stage = .encrypting;
    connection.pairing.command = hci.HCI_OP_LE_ENABLE_ENCRYPTION;
    return true;
}

// --- the device's word ------------------------------------------------------------

/// A frame on the security manager's channel of an LE link.
pub fn received(layer: *Hci, connection: *Connection, payload: []const u8) void {
    if (payload.len == 0) return;
    const code = payload[0];
    if (!connection.central) {
        // This side is the device's peripheral, and pairs with nobody.
        if (code == PAIRING_REQUEST) _ = send(layer, connection, &.{ PAIRING_FAILED, REASON_PAIRING_NOT_SUPPORTED });
        return;
    }
    switch (code) {
        SECURITY_REQUEST => return securityRequest(layer, connection, payload),
        PAIRING_FAILED => return failedThere(layer, connection, payload),
        PAIRING_REQUEST => {
            _ = send(layer, connection, &.{ PAIRING_FAILED, REASON_COMMAND_NOT_SUPPORTED });
            return;
        },
        PAIRING_RESPONSE, PAIRING_CONFIRM, PAIRING_RANDOM, PAIRING_PUBLIC_KEY, PAIRING_DHKEY_CHECK, ENCRYPTION_INFORMATION, CENTRAL_IDENTIFICATION, IDENTITY_INFORMATION, IDENTITY_ADDRESS_INFORMATION, SIGNING_INFORMATION, KEYPRESS_NOTIFICATION => {},
        else => {
            _ = send(layer, connection, &.{ PAIRING_FAILED, REASON_COMMAND_NOT_SUPPORTED });
            return;
        },
    }
    const smp = &connection.smp;
    if (smp.phase == .idle or connection.pairing.stage == .idle) return;
    // What comes out of turn is let go.
    switch (code) {
        PAIRING_RESPONSE => if (smp.phase == .response) pairingResponse(layer, connection, payload),
        PAIRING_PUBLIC_KEY => if (smp.phase == .public_key) publicKey(layer, connection, payload),
        PAIRING_CONFIRM => if (smp.phase == .confirm) confirmed(layer, connection, payload),
        PAIRING_RANDOM => if (smp.phase == .random) randomed(layer, connection, payload),
        PAIRING_DHKEY_CHECK => if (smp.phase == .check) checked(layer, connection, payload),
        ENCRYPTION_INFORMATION, CENTRAL_IDENTIFICATION, IDENTITY_INFORMATION, IDENTITY_ADDRESS_INFORMATION, SIGNING_INFORMATION => if (smp.phase == .encryption or smp.phase == .keys) given(layer, connection, payload),
        else => {},
    }
}

/// Security Request: a bonded device's link encrypted with the bond's
/// key; an unbonded device's pairing begun while an agent is there, and
/// refused otherwise.
fn securityRequest(layer: *Hci, connection: *Connection, payload: []const u8) void {
    if (payload.len < 2) return;
    if (connection.pairing.stage != .idle or connection.encrypted) return;
    if (bondOf(layer, connection)) |bond| {
        pairing.begin(layer, connection, .secure, false, 0, null);
        if (!encryptBond(layer, connection, bond)) connection.pairing = .{};
        return;
    }
    const agent = layer.agent_current;
    if (agent == 0 or !canPair(layer)) {
        _ = send(layer, connection, &.{ PAIRING_FAILED, REASON_PAIRING_NOT_SUPPORTED });
        return;
    }
    pairing.begin(layer, connection, .pair, false, agent, layer.agent_capability);
    if (!start(layer, connection)) pairing.finish(layer, connection, bluetooth.BTERR_NOMEM);
}

/// Pairing Failed: the pairing over with the device's reason.
fn failedThere(layer: *Hci, connection: *Connection, payload: []const u8) void {
    if (connection.smp.phase == .idle or connection.pairing.stage == .idle) return;
    const reason = if (payload.len >= 2) payload[1] else REASON_UNSPECIFIED;
    pairing.finish(layer, connection, resultOf(reason));
}

fn pairingResponse(layer: *Hci, connection: *Connection, payload: []const u8) void {
    if (payload.len < 7) return fail(layer, connection, REASON_INVALID_PARAMETERS);
    const smp = &connection.smp;
    smp.response = payload[0..7].*;
    const peer_io = payload[1];
    const peer_auth = payload[3];
    connection.pairing.peer_io = peer_io;
    connection.pairing.peer_auth = peer_auth;
    if (payload[4] < hci.MIN_ENCRYPTION_KEY_SIZE) return fail(layer, connection, REASON_ENCRYPTION_KEY_SIZE);
    smp.key_size = @min(payload[4], MAX_KEY_SIZE);
    smp.secure = smp.request[3] & AUTH_SC != 0 and peer_auth & AUTH_SC != 0;
    // The keys it gives of those asked for; Secure Connections makes the
    // long term key instead.
    smp.expected = payload[6] & smp.request[6];
    if (smp.secure) smp.expected &= ~KEYDIST_ENC;
    const mitm = (smp.request[3] | peer_auth) & AUTH_MITM != 0;
    smp.method = if (mitm) methodOf(smp.request[1], peer_io, smp.secure) else .just_works;
    if (smp.secure) return sendPublicKey(layer, connection);
    // Legacy: the temporary key, from the agent where it takes one.
    switch (smp.method) {
        .type_passkey => askAgent(layer, connection, bluetooth.BTAK_PASSKEY, bluetooth.BT_NO_NUMBER, .legacy_confirm),
        .show_passkey => {
            showPasskey(layer, connection);
            legacyConfirm(layer, connection);
        },
        .just_works, .compare => if (consenting(connection)) {
            askAgent(layer, connection, bluetooth.BTAK_CONFIRM, bluetooth.BT_NO_NUMBER, .legacy_confirm);
        } else {
            legacyConfirm(layer, connection);
        },
    }
}

/// This side's public key sent: a key pair made for the pairing.
fn sendPublicKey(layer: *Hci, connection: *Connection) void {
    const port = portOf(layer) orelse return fail(layer, connection, REASON_UNSPECIFIED);
    const smp = &connection.smp;
    var public_key: [64]u8 = undefined;
    if (!port.keyPair(port.context, &smp.private_key, &public_key)) return fail(layer, connection, REASON_UNSPECIFIED);
    smp.public_key[0..32].* = smpcrypto.reversed(32, public_key[0..32]);
    smp.public_key[32..64].* = smpcrypto.reversed(32, public_key[32..64]);
    smp.phase = .public_key;
    var packet: [65]u8 = undefined;
    packet[0] = PAIRING_PUBLIC_KEY;
    packet[1..65].* = smp.public_key;
    if (!send(layer, connection, &packet)) fail(layer, connection, REASON_UNSPECIFIED);
}

/// The device's public key: on the curve, not this side's own, the secret
/// shared - then by the method.
fn publicKey(layer: *Hci, connection: *Connection, payload: []const u8) void {
    if (payload.len < 65) return fail(layer, connection, REASON_INVALID_PARAMETERS);
    const port = portOf(layer) orelse return fail(layer, connection, REASON_UNSPECIFIED);
    const smp = &connection.smp;
    smp.peer_key = payload[1..65].*;
    if (same(&smp.peer_key, &smp.public_key)) return fail(layer, connection, REASON_UNSPECIFIED);
    smp.debug = same(&smp.peer_key, &smpcrypto.DEBUG_PUBLIC_KEY);
    var peer: [64]u8 = undefined;
    peer[0..32].* = smpcrypto.reversed(32, smp.peer_key[0..32]);
    peer[32..64].* = smpcrypto.reversed(32, smp.peer_key[32..64]);
    var secret: [32]u8 = undefined;
    if (!port.shared(port.context, &smp.private_key, &peer, &secret)) return fail(layer, connection, REASON_DHKEY_CHECK_FAILED);
    smp.dhkey = smpcrypto.reversed(32, &secret);
    switch (smp.method) {
        .just_works, .compare => {
            // The device's confirm comes first.
            port.random(port.context, &smp.ours);
            smp.phase = .confirm;
        },
        .type_passkey => askAgent(layer, connection, bluetooth.BTAK_PASSKEY, bluetooth.BT_NO_NUMBER, .passkey_rounds),
        .show_passkey => {
            showPasskey(layer, connection);
            passkeyRound(layer, connection);
        },
    }
}

/// The device's Pairing Confirm: this side's random or nonce sent.
fn confirmed(layer: *Hci, connection: *Connection, payload: []const u8) void {
    if (payload.len < 17) return fail(layer, connection, REASON_INVALID_PARAMETERS);
    const smp = &connection.smp;
    smp.confirm = payload[1..17].*;
    smp.phase = .random;
    var packet: [17]u8 = undefined;
    packet[0] = PAIRING_RANDOM;
    packet[1..17].* = smp.ours;
    if (!send(layer, connection, &packet)) fail(layer, connection, REASON_UNSPECIFIED);
}

/// The device's Pairing Random: its confirm checked against it - then
/// legacy's short-term key, the number to compare, Passkey Entry's next
/// round, or the DHKey check.
fn randomed(layer: *Hci, connection: *Connection, payload: []const u8) void {
    if (payload.len < 17) return fail(layer, connection, REASON_INVALID_PARAMETERS);
    const port = portOf(layer) orelse return fail(layer, connection, REASON_UNSPECIFIED);
    const smp = &connection.smp;
    smp.theirs = payload[1..17].*;
    if (!smp.secure) {
        const ours_address = layer.address;
        const expected = smpcrypto.c1(port, &smp.tk, &smp.theirs, &smp.request, &smp.response, 0, &ours_address, peerType(connection), &connection.address.bytes);
        if (!same(&expected, &smp.confirm)) return fail(layer, connection, REASON_CONFIRM_VALUE_FAILED);
        const stk = smpcrypto.s1(port, &smp.tk, &smp.theirs, &smp.ours);
        const zero: [8]u8 = @splat(0);
        smp.phase = .encryption;
        if (!encrypt(layer, connection, &stk, 0, &zero, smp.key_size)) fail(layer, connection, REASON_UNSPECIFIED);
        return;
    }
    switch (smp.method) {
        .type_passkey, .show_passkey => {
            const z = 0x80 | @as(u8, @intCast(smp.passkey >> @intCast(smp.round) & 1));
            const expected = smpcrypto.f4(port, smp.peer_key[0..32], smp.public_key[0..32], &smp.theirs, z);
            if (!same(&expected, &smp.confirm)) return fail(layer, connection, REASON_CONFIRM_VALUE_FAILED);
            smp.round += 1;
            if (smp.round < PASSKEY_ROUNDS) return passkeyRound(layer, connection);
            sendCheck(layer, connection);
        },
        .just_works, .compare => {
            const expected = smpcrypto.f4(port, smp.peer_key[0..32], smp.public_key[0..32], &smp.theirs, 0);
            if (!same(&expected, &smp.confirm)) return fail(layer, connection, REASON_CONFIRM_VALUE_FAILED);
            if (smp.method == .compare) {
                const number = smpcrypto.g2(port, smp.public_key[0..32], smp.peer_key[0..32], &smp.ours, &smp.theirs);
                return askAgent(layer, connection, bluetooth.BTAK_CONFIRM, number, .check);
            }
            if (consenting(connection)) return askAgent(layer, connection, bluetooth.BTAK_CONFIRM, bluetooth.BT_NO_NUMBER, .check);
            sendCheck(layer, connection);
        },
    }
}

/// The device's DHKey Check checked, and the link encrypted with the long
/// term key.
fn checked(layer: *Hci, connection: *Connection, payload: []const u8) void {
    if (payload.len < 17) return fail(layer, connection, REASON_INVALID_PARAMETERS);
    const port = portOf(layer) orelse return fail(layer, connection, REASON_UNSPECIFIED);
    const smp = &connection.smp;
    const ours_address = addressOf(&layer.address, 0);
    const theirs_address = addressOf(&connection.address.bytes, peerType(connection));
    const r = passkeyValue(smp);
    const io_cap = [3]u8{ smp.response[1], smp.response[2], smp.response[3] };
    const expected = smpcrypto.f6(port, &smp.mac_key, &smp.theirs, &smp.ours, &r, &io_cap, &theirs_address, &ours_address);
    if (!same(&expected, payload[1..17])) return fail(layer, connection, REASON_DHKEY_CHECK_FAILED);
    const zero: [8]u8 = @splat(0);
    smp.phase = .encryption;
    if (!encrypt(layer, connection, &smp.ltk, 0, &zero, smp.key_size)) fail(layer, connection, REASON_UNSPECIFIED);
}

/// A key the device gives, after the link is encrypted: its long term
/// key, EDIV and Rand, its identity resolving key and address. The
/// pairing is over once it has given what it said it would.
fn given(layer: *Hci, connection: *Connection, payload: []const u8) void {
    const smp = &connection.smp;
    switch (payload[0]) {
        ENCRYPTION_INFORMATION => if (payload.len >= 17 and smp.expected & KEYDIST_ENC != 0) {
            smp.ltk = payload[1..17].*;
            smp.ltk_in = true;
        },
        CENTRAL_IDENTIFICATION => if (payload.len >= 11 and smp.expected & KEYDIST_ENC != 0 and smp.ltk_in) {
            smp.ediv = _hci.le16(payload[1..3]);
            smp.rand = payload[3..11].*;
            smp.has_ltk = true;
            smp.expected &= ~KEYDIST_ENC;
        },
        IDENTITY_INFORMATION => if (payload.len >= 17 and smp.expected & KEYDIST_ID != 0) {
            smp.irk = payload[1..17].*;
            smp.irk_in = true;
        },
        IDENTITY_ADDRESS_INFORMATION => if (payload.len >= 8 and smp.expected & KEYDIST_ID != 0 and smp.irk_in) {
            const bytes = payload[2..8].*;
            // A public address, or a static random one.
            const valid = payload[1] == hci.LE_ADDR_PUBLIC or (payload[1] == hci.LE_ADDR_RANDOM and bytes[5] & 0xC0 == 0xC0);
            if (valid) {
                smp.identity = .{ .bytes = bytes, .kind = if (payload[1] == hci.LE_ADDR_PUBLIC) bluetooth.BTADDR_LE_PUBLIC else bluetooth.BTADDR_LE_RANDOM };
                smp.has_identity = true;
            }
            smp.has_irk = !allZero(&smp.irk);
            smp.expected &= ~KEYDIST_ID;
        },
        else => {},
    }
    if (smp.phase == .keys and smp.expected == 0) complete(layer, connection);
}

/// Encryption Change on an LE link being paired or made secure: a bonded
/// link's end, or the pairing on to the device's keys.
pub fn encryptionChanged(layer: *Hci, connection: *Connection, status: u8) void {
    const record = &connection.pairing;
    if (record.stage != .encrypting) return;
    record.command = 0;
    if (record.purpose == .secure) {
        if (status != hci.HCI_SUCCESS) return pairing.finish(layer, connection, status);
        if (!connection.encrypted) return pairing.finish(layer, connection, hci.HCI_ERR_INSUFFICIENT_SECURITY);
        return pairing.finish(layer, connection, 0);
    }
    const smp = &connection.smp;
    if (smp.phase != .encryption) return;
    if (status != hci.HCI_SUCCESS) return abandon(layer, connection, status);
    if (!connection.encrypted) return abandon(layer, connection, hci.HCI_ERR_INSUFFICIENT_SECURITY);
    record.stage = .authenticating;
    smp.phase = .keys;
    if (smp.expected == 0) complete(layer, connection);
}

/// The agent's answer to the link's question: refused, the pairing
/// fails; given, it goes on.
pub fn answered(layer: *Hci, connection: *Connection, kind: u32, accept: bool, passkey: u32) void {
    const smp = &connection.smp;
    if (smp.phase != .user) return;
    if (!accept or (kind == bluetooth.BTAK_PASSKEY and passkey > 999_999)) {
        const reason: u8 = switch (kind) {
            bluetooth.BTAK_PASSKEY => REASON_PASSKEY_ENTRY_FAILED,
            else => if (smp.method == .compare) REASON_NUMERIC_COMPARISON_FAILED else REASON_PAIRING_NOT_SUPPORTED,
        };
        return fail(layer, connection, reason);
    }
    if (kind == bluetooth.BTAK_PASSKEY) smp.passkey = passkey;
    switch (smp.then) {
        .legacy_confirm => legacyConfirm(layer, connection),
        .passkey_rounds => passkeyRound(layer, connection),
        .check => sendCheck(layer, connection),
    }
}

/// A pairing given up on - at its time, or its encryption refused by the
/// controller - `result` why: the device told, where the security
/// manager's exchange is under way.
pub fn abandon(layer: *Hci, connection: *Connection, result: i32) void {
    if (connection.smp.phase != .idle) _ = send(layer, connection, &.{ PAIRING_FAILED, REASON_UNSPECIFIED });
    pairing.finish(layer, connection, result);
}

// --- this side's word -------------------------------------------------------------

/// Whether the device's pairing, with nothing to compare, is asked of the
/// agent: one that can answer yes or no.
fn consenting(connection: *const Connection) bool {
    const record = &connection.pairing;
    if (record.ours or record.agent == 0) return false;
    return record.our_io == IO_DISPLAY_YES_NO or record.our_io == IO_KEYBOARD_DISPLAY;
}

/// A question for the agent - refused at once where there is none to ask.
fn askAgent(layer: *Hci, connection: *Connection, kind: u32, number: u32, then: Then) void {
    const smp = &connection.smp;
    smp.phase = .user;
    smp.then = then;
    if (connection.pairing.agent == 0 or connection.pairing.refused) return answered(layer, connection, kind, false, 0);
    pairing.ask(layer, connection, kind, number);
}

/// A passkey made, and shown to the agent's user to type on the device.
fn showPasskey(layer: *Hci, connection: *Connection) void {
    const smp = &connection.smp;
    if (portOf(layer)) |port| {
        var bytes: [4]u8 = undefined;
        port.random(port.context, &bytes);
        smp.passkey = (@as(u32, bytes[0]) | @as(u32, bytes[1]) << 8 | @as(u32, bytes[2]) << 16 | @as(u32, bytes[3]) << 24) % 1_000_000;
    }
    const record = &connection.pairing;
    pairing.notice(layer, .{ .kind = .show, .agent = record.agent, .address = connection.address, .ours = record.ours, .number = smp.passkey });
}

/// Legacy pairing's confirm sent: the temporary key from the passkey (0
/// for Just Works), a random of this side's, c1.
fn legacyConfirm(layer: *Hci, connection: *Connection) void {
    const port = portOf(layer) orelse return fail(layer, connection, REASON_UNSPECIFIED);
    const smp = &connection.smp;
    smp.tk = passkeyValue(smp);
    port.random(port.context, &smp.ours);
    const ours_address = layer.address;
    const value = smpcrypto.c1(port, &smp.tk, &smp.ours, &smp.request, &smp.response, 0, &ours_address, peerType(connection), &connection.address.bytes);
    sendConfirm(layer, connection, &value);
}

/// Passkey Entry's round `smp.round`: this side's nonce and confirm of the
/// round's bit.
fn passkeyRound(layer: *Hci, connection: *Connection) void {
    const port = portOf(layer) orelse return fail(layer, connection, REASON_UNSPECIFIED);
    const smp = &connection.smp;
    port.random(port.context, &smp.ours);
    const z = 0x80 | @as(u8, @intCast(smp.passkey >> @intCast(smp.round) & 1));
    const value = smpcrypto.f4(port, smp.public_key[0..32], smp.peer_key[0..32], &smp.ours, z);
    sendConfirm(layer, connection, &value);
}

fn sendConfirm(layer: *Hci, connection: *Connection, value: *const [16]u8) void {
    connection.smp.phase = .confirm;
    var packet: [17]u8 = undefined;
    packet[0] = PAIRING_CONFIRM;
    packet[1..17].* = value.*;
    if (!send(layer, connection, &packet)) fail(layer, connection, REASON_UNSPECIFIED);
}

/// Secure Connections' MacKey and long term key made, and this side's
/// DHKey check sent.
fn sendCheck(layer: *Hci, connection: *Connection) void {
    const port = portOf(layer) orelse return fail(layer, connection, REASON_UNSPECIFIED);
    const smp = &connection.smp;
    const ours_address = addressOf(&layer.address, 0);
    const theirs_address = addressOf(&connection.address.bytes, peerType(connection));
    const keys = smpcrypto.f5(port, &smp.dhkey, &smp.ours, &smp.theirs, &ours_address, &theirs_address);
    smp.mac_key = keys.mac_key;
    smp.ltk = keys.ltk;
    const r = passkeyValue(smp);
    const io_cap = [3]u8{ smp.request[1], smp.request[2], smp.request[3] };
    const value = smpcrypto.f6(port, &smp.mac_key, &smp.ours, &smp.theirs, &r, &io_cap, &ours_address, &theirs_address);
    smp.phase = .check;
    var packet: [17]u8 = undefined;
    packet[0] = PAIRING_DHKEY_CHECK;
    packet[1..17].* = value;
    if (!send(layer, connection, &packet)) fail(layer, connection, REASON_UNSPECIFIED);
}

/// The pairing over: a bond kept where both asked for one and a long term
/// key was made or given - never the debug key's.
fn complete(layer: *Hci, connection: *Connection) void {
    const smp = &connection.smp;
    const both = smp.request[3] & AUTH_BONDING_MASK == AUTH_BONDING and smp.response[3] & AUTH_BONDING_MASK == AUTH_BONDING;
    const keyed = smp.secure or smp.has_ltk;
    if (both and keyed and !smp.debug) {
        const zero: [8]u8 = @splat(0);
        const keys = bonds.LeKeys{
            .ltk = smp.ltk,
            .ediv = if (smp.secure) 0 else smp.ediv,
            .rand = if (smp.secure) zero else smp.rand,
            .key_size = smp.key_size,
            .authenticated = smp.method != .just_works,
            .secure = smp.secure,
            .irk = if (smp.has_irk) smp.irk else null,
        };
        const address = if (smp.has_identity) smp.identity else connection.address;
        if (bonds.keepLe(layer, address, &keys, &connection.name) == null) connection.pairing.full = true;
    }
    pairing.finish(layer, connection, 0);
}

/// The pairing failed on this side: the device told why.
fn fail(layer: *Hci, connection: *Connection, reason: u8) void {
    _ = send(layer, connection, &.{ PAIRING_FAILED, reason });
    pairing.finish(layer, connection, resultOf(reason));
}

fn send(layer: *Hci, connection: *const Connection, payload: []const u8) bool {
    return acl.send(layer, connection, l2cap.CID_SMP, payload);
}

// --- the bytes --------------------------------------------------------------------

/// The device's address type as the functions take it: 0 public, 1
/// random.
fn peerType(connection: *const Connection) u8 {
    return if (connection.address.kind == bluetooth.BTADDR_LE_RANDOM) 1 else 0;
}

/// An address and its type, as f5 and f6 take them.
fn addressOf(bytes: *const [6]u8, kind: u8) [7]u8 {
    var out: [7]u8 = undefined;
    out[0..6].* = bytes.*;
    out[6] = kind;
    return out;
}

/// The passkey as a 128-bit value; 0 for the other methods.
fn passkeyValue(smp: *const Smp) [16]u8 {
    var value: [16]u8 = @splat(0);
    if (smp.method == .type_passkey or smp.method == .show_passkey) {
        value[0] = @truncate(smp.passkey);
        value[1] = @truncate(smp.passkey >> 8);
        value[2] = @truncate(smp.passkey >> 16);
        value[3] = @truncate(smp.passkey >> 24);
    }
    return value;
}

fn same(one: []const u8, other: []const u8) bool {
    if (one.len != other.len) return false;
    var differ: u8 = 0;
    for (one, other) |mine, theirs| differ |= mine ^ theirs;
    return differ == 0;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

fn put16(into: *[2]u8, value: u16) void {
    into[0] = @truncate(value);
    into[1] = @truncate(value >> 8);
}
