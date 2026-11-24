// SPDX-License-Identifier: MIT
//! A controller's pairings over BR/EDR - Secure Simple Pairing, and a
//! PIN's for a device without it - begun by the library (PairBTDevice)
//! or by the device; and a bonded device's link authenticated with the
//! bond's key and encrypted. Over LE the security manager pairs and
//! encrypts (smp.zig); the pairing's record, its agent, its questions,
//! its notices and its end are this file's for both.
//!
//! **Begun by the library** (`pair`): Authentication Requested on the
//! link, made first where there is none. The controller asks for a key
//! (Link Key Request: none, as the device has no bond yet), for this
//! side's IO capability and requirements (IO Capability Request: the
//! agent's capability, Dedicated Bonding, protection from a man in the
//! middle where the agent can give it), hears the device's (IO Capability
//! Response), and asks for what the two call for: a number both show to
//! be confirmed (User Confirmation Request), a passkey the device shows
//! to be typed (User Passkey Request) or one to be shown to be typed on
//! it (User Passkey Notification) - or nothing, where neither side can
//! compare (Just Works, accepted at once). Simple Pairing Complete, the
//! new key (Link Key Notification: a bond when both asked for one) and
//! Authentication Complete follow; the link is then encrypted (Set
//! Connection Encryption) and its key's size read, a key shorter than
//! MIN_ENCRYPTION_KEY_SIZE ending the link. A device without Secure
//! Simple Pairing asks for a PIN instead (PIN Code Request). A link the
//! pairing made is ended once it has made no bond, as a link made for
//! channels is (connections.zig); a link there before it stays.
//!
//! **Begun by the device**: an IO Capability Request - or a PIN Code
//! Request - with no pairing of the library's on the link is answered
//! while an agent is there (`layer.agent_current`), and refused otherwise
//! (Pairing Not Allowed). This side asks for a bond where the device
//! does, and for protection from a man in the middle where both sides
//! can give it. A number to compare goes to the agent; where there is
//! nothing to compare, an agent that can answer yes or no is asked
//! whether the device may pair, and one that cannot lets it. It is over
//! with the new key, or with Simple Pairing Complete's failure.
//!
//! **Asked of the agent.** A question - a number to confirm, a passkey, a
//! PIN - waits in the link's record until the task has sent it to the
//! agent and the answer is back (`agentAnswered`), or QUESTION_WAIT_MS
//! have gone: then it is refused. What the agent is only told - a passkey
//! to type on the device, a pairing's end - is a Notice, which the task
//! sends and forgets. The layer knows an agent only by its number,
//! which the task finds it by: one given back meanwhile is not found,
//! and its question is refused.
//!
//! **A bonded device's link** the library made is authenticated with the
//! bond's key and encrypted before ConnectBTDevice's wait is answered: 0,
//! or why not - the device's PIN or Key Missing when it has lost the
//! bond, the link staying up. So is a link a bonded device opens a
//! channel over to a secure listener (`secureLink`), the channel waiting
//! for it (l2cap/channels.zig).
//!
//! **Noted.** A pairing over, and a link not made secure, leave a note
//! for the log (connections.zig).
//!
//! Pure, as the rest of the layer.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const _hci = @import("_hci.zig");
const Hci = _hci.Hci;
const advertising = @import("advertising.zig");
const bonds = @import("bonds.zig");
const connections = @import("connections.zig");
const channels = @import("../l2cap/channels.zig");
const att_client = @import("../att/client.zig");
const Connection = connections.Connection;
const smp = @import("smp.zig");

/// How long a pairing may take, and how long the agent has to answer.
pub const PAIR_WAIT_MS: u32 = 60_000;
pub const QUESTION_WAIT_MS: u32 = 30_000;

/// Where a pairing is: waiting for its link, for the authentication, the
/// encryption, the encryption key's size.
pub const Stage = enum(u8) { idle, linking, authenticating, encrypting, sizing };

/// What it is for: a bond made, or a bonded device's link made secure.
pub const Purpose = enum(u8) { pair, secure };

/// IO Capability Response's capability before it has come.
const UNKNOWN_IO: u8 = 0xFF;

/// A question waiting for the agent.
pub const Question = struct {
    /// bluetooth.BTAK_CONFIRM, BTAK_PASSKEY or BTAK_PIN; 0 for none.
    kind: u32 = 0,
    number: u32 = bluetooth.BT_NO_NUMBER,
    /// Sent by the task, in this message (the task's).
    sent: bool = false,
    message: ?*anyopaque = null,
    deadline: u64 = 0,
};

/// A link's pairing.
pub const Pairing = struct {
    stage: Stage = .idle,
    purpose: Purpose = .pair,
    /// Begun by the library; the agent to ask and tell, by its number -
    /// the one PairBTDevice named, or the one there was when the device
    /// began it; 0 for none.
    ours: bool = false,
    agent: u32 = 0,
    /// This side's IO capability and requirements, and the device's.
    our_io: u8 = hci.IO_NO_INPUT_OUTPUT,
    our_auth: u8 = 0,
    peer_io: u8 = UNKNOWN_IO,
    peer_auth: u8 = 0,
    /// A PIN was asked for; the agent said no; the new key found no room.
    legacy: bool = false,
    refused: bool = false,
    full: bool = false,
    /// PairBTDevice made the link for it: ended as one made for channels
    /// is where the pairing makes no bond.
    made_link: bool = false,
    /// The command sent last, whose refusal ends it.
    command: u16 = 0,
    question: Question = .{},
    deadline: ?u64 = null,
};

/// How many notices wait for the task.
pub const NOTICES = 8;

pub const NoticeKind = enum(u8) { show, done };

/// What an agent is told: a passkey to type on the device (show), a
/// pairing's end (done).
pub const Notice = struct {
    kind: NoticeKind = .done,
    agent: u32 = 0,
    address: bluetooth.BTAddress = .{},
    ours: bool = false,
    number: u32 = bluetooth.BT_NO_NUMBER,
    result: i32 = 0,
};

/// Whether the controller can pair over BR/EDR.
pub fn canPair(layer: *const Hci) bool {
    return connections.canPage(layer) and _hci.supports(layer, hci.CMDBIT_AUTHENTICATION_REQUESTED);
}

/// The IO capability this side answers with for an agent's (BTIO_*), or
/// for none: what the agent's user can do, as BR/EDR names it.
pub fn ioOf(capability: ?u32) u8 {
    const value = capability orelse return hci.IO_NO_INPUT_OUTPUT;
    return switch (value) {
        bluetooth.BTIO_DISPLAYONLY => hci.IO_DISPLAY_ONLY,
        bluetooth.BTIO_DISPLAYYESNO, bluetooth.BTIO_KEYBOARDDISPLAY => hci.IO_DISPLAY_YES_NO,
        bluetooth.BTIO_KEYBOARDONLY => hci.IO_KEYBOARD_ONLY,
        else => hci.IO_NO_INPUT_OUTPUT,
    };
}

// --- the calls ------------------------------------------------------------------

/// PairBTDevice: a pairing with the device at `address` begun - its link
/// made first where there is none, over LE for an LE address - asking
/// and telling `agent`, whose capability is `capability` (null for no
/// agent). 0, or why not.
pub fn pair(layer: *Hci, address: bluetooth.BTAddress, agent: u32, capability: ?u32) i32 {
    if (layer.state != bluetooth.BTCS_UP) return bluetooth.BTERR_NOTUP;
    if (!layer.powered) return bluetooth.BTERR_OFF;
    const able = if (address.kind == bluetooth.BTADDR_BREDR) canPair(layer) else smp.canPair(layer);
    if (!able) return bluetooth.BTERR_UNSUPPORTED;
    if (bonds.find(layer, address) != null) return bluetooth.BTERR_BONDED;
    if (connections.find(layer, address)) |connection| {
        if (connection.pairing.stage != .idle) return bluetooth.BTERR_BUSY;
        switch (connection.state) {
            // Up, but the device has not answered on it yet: begun once
            // it has.
            .up => if (!connection.heard) {
                begin(layer, connection, .pair, true, agent, capability);
                connection.pairing.stage = .linking;
                return 0;
            } else {
                begin(layer, connection, .pair, true, agent, capability);
                if (!startOn(layer, connection)) {
                    connection.pairing = .{};
                    return bluetooth.BTERR_NOMEM;
                }
                return 0;
            },
            .connecting, .listening => {
                if (connection.unwanted) return bluetooth.BTERR_BUSY;
                begin(layer, connection, .pair, true, agent, capability);
                connection.pairing.stage = .linking;
                return 0;
            },
            .disconnecting, .free => return bluetooth.BTERR_BUSY,
        }
    }
    const result = connections.make(layer, address);
    if (result != 0) return result;
    const connection = connections.find(layer, address).?;
    begin(layer, connection, .pair, true, agent, capability);
    connection.pairing.stage = .linking;
    connection.pairing.made_link = true;
    return 0;
}

/// UnpairBTDevice: the bond with the device at `address` ended - to be
/// deleted by the task - a link to it ended, and the advertising while
/// hidden ended with the last bond given the identity. 0, or
/// BTERR_NOTBONDED.
pub fn unpair(layer: *Hci, address: bluetooth.BTAddress) i32 {
    if (!bonds.forget(layer, address)) return bluetooth.BTERR_NOTBONDED;
    if (connections.find(layer, address)) |connection| connections.close(layer, connection, hci.HCI_ERR_REMOTE_USER_TERMINATED);
    // The last bond given the identity gone: no advertising while hidden.
    advertising.update(layer);
    return 0;
}

/// The agent `agent` gone: its pairings refused - the question it was
/// asked, and whatever they would ask next - and nothing more told it.
pub fn agentGone(layer: *Hci, agent: u32) void {
    for (&layer.connections) |*connection| {
        if (connection.pairing.agent != agent) continue;
        connection.pairing.agent = 0;
        connection.pairing.refused = true;
        if (connection.pairing.question.kind != 0) reply(layer, connection, false, 0, &.{});
    }
    var kept: u8 = 0;
    for (layer.notices[0..layer.notice_count]) |item| {
        if (item.agent == agent) continue;
        layer.notices[kept] = item;
        kept += 1;
    }
    layer.notice_count = kept;
}

/// The agent's answer to the question the task sent in `message`: the
/// controller told. False when no question waits for it - it was given up
/// on.
pub fn agentAnswered(layer: *Hci, message: *anyopaque, accept: bool, passkey: u32, pin: []const u8) bool {
    for (&layer.connections) |*connection| {
        const question = &connection.pairing.question;
        if (question.kind == 0 or !question.sent or question.message != message) continue;
        reply(layer, connection, accept, passkey, pin);
        return true;
    }
    return false;
}

/// A question no agent can be asked - there is none, or no message could
/// be made - refused.
pub fn unasked(layer: *Hci, connection: *Connection) void {
    reply(layer, connection, false, 0, &.{});
}

// --- the link ---------------------------------------------------------------------

/// A link up: a pairing that waited for it begun, or a link the library
/// made to a bonded device made secure. Whether ConnectBTDevice's wait
/// waits on for that.
pub fn linkUp(layer: *Hci, connection: *Connection) bool {
    if (connection.pairing.stage == .linking) {
        if (!startOn(layer, connection)) finish(layer, connection, bluetooth.BTERR_NOMEM);
        return false;
    }
    if (connection.incoming) return false;
    if (connection.le) {
        if (!_hci.supports(layer, hci.CMDBIT_LE_ENABLE_ENCRYPTION)) return false;
        const bond = smp.bondOf(layer, connection) orelse return false;
        begin(layer, connection, .secure, true, 0, null);
        if (smp.encryptBond(layer, connection, bond)) return true;
        connection.pairing = .{};
        return false;
    }
    return secureLink(layer, connection);
}

/// A BR/EDR link to a device with a bond made secure with the bond's key:
/// authenticated, then encrypted, its key's size checked - only checked,
/// where the device has encrypted it already. False where that cannot be
/// begun - no bond, a pairing running on it, a controller that cannot.
pub fn secureLink(layer: *Hci, connection: *Connection) bool {
    if (connection.le or connection.pairing.stage != .idle) return false;
    if (bonds.find(layer, connection.address) == null) return false;
    if (connection.encrypted and connection.authenticated) {
        begin(layer, connection, .secure, true, 0, null);
        checkSize(layer, connection);
        return true;
    }
    if (!_hci.supports(layer, hci.CMDBIT_AUTHENTICATION_REQUESTED)) return false;
    begin(layer, connection, .secure, true, 0, null);
    if (authenticate(layer, connection)) return true;
    connection.pairing = .{};
    return false;
}

/// A pairing begun on a link that is up: the security manager's over LE,
/// an authentication over BR/EDR. False when it could not be.
fn startOn(layer: *Hci, connection: *Connection) bool {
    return if (connection.le) smp.start(layer, connection) else authenticate(layer, connection);
}

/// A link not made, or down: its pairing over, `result` why.
pub fn linkGone(layer: *Hci, connection: *Connection, result: i32) void {
    if (connection.pairing.stage == .idle) return;
    finish(layer, connection, if (result == 0) bluetooth.BTERR_NOTCONNECTED else result);
}

/// The link's record set for a pairing, or for its being made secure:
/// whose it is, its agent, and this side's IO capability - LE's own over
/// LE.
pub fn begin(layer: *Hci, connection: *Connection, purpose: Purpose, ours: bool, agent: u32, capability: ?u32) void {
    const peer_io = connection.pairing.peer_io;
    const peer_auth = connection.pairing.peer_auth;
    connection.pairing = .{
        .stage = .authenticating,
        .purpose = purpose,
        .ours = ours,
        .agent = agent,
        .our_io = if (connection.le) smp.ioOf(capability) else ioOf(capability),
        // What the device said, where it spoke first.
        .peer_io = peer_io,
        .peer_auth = peer_auth,
        .deadline = layer.now + PAIR_WAIT_MS,
    };
    layer.changed = true;
}

/// A pairing over: the agent told - or, for a link made secure,
/// ConnectBTDevice's wait answered. What the security manager kept of it
/// is cleared.
pub fn finish(layer: *Hci, connection: *Connection, result: i32) void {
    const was = connection.pairing;
    connection.pairing = .{};
    connection.smp = .{};
    layer.changed = true;
    var outcome = result;
    if (was.refused and result != 0) outcome = bluetooth.BTERR_REFUSED;
    if (was.full and result == 0) outcome = bluetooth.BTERR_NOMEM;
    switch (was.purpose) {
        .secure => {
            if (outcome != 0) connections.note(layer, connection, .not_secured, outcome);
            connections.answerConnect(layer, connection.address, outcome);
            // The channels and GATT's procedures that waited for it,
            // secure or not.
            channels.linkUp(layer, connection);
            att_client.linkUp(layer, connection);
        },
        .pair => {
            connections.note(layer, connection, if (outcome == 0) .paired else .not_paired, outcome);
            notice(layer, .{ .kind = .done, .agent = was.agent, .address = connection.address, .ours = was.ours, .result = outcome });
            // A link made for a pairing that made no bond goes as one made
            // for channels does: unless ConnectBTDevice asks for it, or a
            // channel or a GATT block uses it, meanwhile.
            if (outcome != 0 and was.made_link) {
                connection.for_channels = true;
                connections.idle(layer, connection.address);
            }
            // The bond it made: its device's services for the profile
            // drivers (the task's toBinder).
            if (outcome == 0) {
                const made = if (connection.le) smp.bondOf(layer, connection) else bonds.find(layer, connection.address);
                if (made) |bond| {
                    bond.fresh = true;
                    layer.bonds_fresh = true;
                }
            }
        },
    }
    // The channels a device opened to a secure listener, which waited.
    channels.secured(layer, connection);
}

pub fn notice(layer: *Hci, item: Notice) void {
    if (item.agent == 0 or layer.notice_count == NOTICES) return;
    layer.notices[layer.notice_count] = item;
    layer.notice_count += 1;
}

/// A question for the agent, which the task sends.
pub fn ask(layer: *Hci, connection: *Connection, kind: u32, number: u32) void {
    connection.pairing.question = .{ .kind = kind, .number = number, .deadline = layer.now + QUESTION_WAIT_MS };
}

// --- the commands -------------------------------------------------------------------

/// Authentication Requested on the link: false when it could not be
/// queued.
fn authenticate(layer: *Hci, connection: *Connection) bool {
    var params: [2]u8 = undefined;
    put16(&params, connection.handle);
    if (!_hci.command(layer, hci.HCI_OP_AUTHENTICATION_REQUESTED, &params, _hci.COMMAND_TIMEOUT_MS)) return false;
    connection.pairing.stage = .authenticating;
    connection.pairing.command = hci.HCI_OP_AUTHENTICATION_REQUESTED;
    return true;
}

fn encrypt(layer: *Hci, connection: *Connection) bool {
    var params: [3]u8 = undefined;
    put16(params[0..2], connection.handle);
    params[2] = 0x01;
    if (!_hci.command(layer, hci.HCI_OP_SET_CONNECTION_ENCRYPTION, &params, _hci.COMMAND_TIMEOUT_MS)) return false;
    connection.pairing.stage = .encrypting;
    connection.pairing.command = hci.HCI_OP_SET_CONNECTION_ENCRYPTION;
    return true;
}

/// The encryption key's size read, where the controller can: the pairing
/// is over when it says the key is long enough.
fn checkSize(layer: *Hci, connection: *Connection) void {
    if (!_hci.supports(layer, hci.CMDBIT_READ_ENCRYPTION_KEY_SIZE)) return sized(layer, connection);
    var params: [2]u8 = undefined;
    put16(&params, connection.handle);
    if (!_hci.command(layer, hci.HCI_OP_READ_ENCRYPTION_KEY_SIZE, &params, _hci.COMMAND_TIMEOUT_MS)) return sized(layer, connection);
    connection.pairing.stage = .sizing;
    connection.pairing.command = hci.HCI_OP_READ_ENCRYPTION_KEY_SIZE;
}

/// The key's size long enough, or not to be read: the pairing over.
fn sized(layer: *Hci, connection: *Connection) void {
    connection.key_checked = true;
    finish(layer, connection, 0);
}

/// The controller told the agent's answer to the link's question.
fn reply(layer: *Hci, connection: *Connection, accept: bool, passkey: u32, pin: []const u8) void {
    const question = connection.pairing.question;
    connection.pairing.question = .{};
    if (!accept) connection.pairing.refused = true;
    if (connection.le) return smp.answered(layer, connection, question.kind, accept, passkey);
    const address = connection.address;
    switch (question.kind) {
        bluetooth.BTAK_CONFIRM => confirm(layer, address, accept),
        bluetooth.BTAK_PASSKEY => if (accept) {
            var params: [10]u8 = undefined;
            params[0..6].* = address.bytes;
            put32(params[6..10], passkey);
            _ = _hci.command(layer, hci.HCI_OP_USER_PASSKEY_REPLY, &params, _hci.COMMAND_TIMEOUT_MS);
        } else {
            _ = _hci.command(layer, hci.HCI_OP_USER_PASSKEY_NEGATIVE_REPLY, &address.bytes, _hci.COMMAND_TIMEOUT_MS);
        },
        bluetooth.BTAK_PIN => if (accept and pin.len > 0) {
            var params: [23]u8 = @splat(0);
            params[0..6].* = address.bytes;
            const length = @min(pin.len, bluetooth.BT_PIN_MOST);
            params[6] = @intCast(length);
            @memcpy(params[7..][0..length], pin[0..length]);
            _ = _hci.command(layer, hci.HCI_OP_PIN_CODE_REPLY, &params, _hci.COMMAND_TIMEOUT_MS);
        } else {
            refusePin(layer, address);
        },
        else => {},
    }
}

fn confirm(layer: *Hci, address: bluetooth.BTAddress, accept: bool) void {
    const opcode = if (accept) hci.HCI_OP_USER_CONFIRMATION_REPLY else hci.HCI_OP_USER_CONFIRMATION_NEGATIVE_REPLY;
    _ = _hci.command(layer, opcode, &address.bytes, _hci.COMMAND_TIMEOUT_MS);
}

fn refusePin(layer: *Hci, address: bluetooth.BTAddress) void {
    _ = _hci.command(layer, hci.HCI_OP_PIN_CODE_NEGATIVE_REPLY, &address.bytes, _hci.COMMAND_TIMEOUT_MS);
}

fn refuseCapability(layer: *Hci, address: bluetooth.BTAddress) void {
    var params: [7]u8 = undefined;
    params[0..6].* = address.bytes;
    params[6] = hci.HCI_ERR_PAIRING_NOT_ALLOWED;
    _ = _hci.command(layer, hci.HCI_OP_IO_CAPABILITY_NEGATIVE_REPLY, &params, _hci.COMMAND_TIMEOUT_MS);
}

// --- the controller's word ----------------------------------------------------------

/// A pairing the device begins, where an agent is there to answer it:
/// false when there is none.
fn theirs(layer: *Hci, connection: *Connection) bool {
    const agent = layer.agent_current;
    if (agent == 0) return false;
    if (connection.pairing.stage != .idle) {
        // A bonded link being made secure whose device lost the bond and
        // pairs afresh: ConnectBTDevice's wait has its answer.
        if (connection.pairing.purpose == .secure) finish(layer, connection, hci.HCI_ERR_PIN_OR_KEY_MISSING) else return true;
    }
    begin(layer, connection, .pair, false, agent, layer.agent_capability);
    return true;
}

/// Link Key Request: the bond's key where there is one, otherwise none.
pub fn linkKeyRequest(layer: *Hci, params: []const u8) void {
    if (params.len < 6) return;
    const address = bredr(params[0..6]);
    if (bonds.find(layer, address)) |bond| {
        var reply_params: [22]u8 = undefined;
        reply_params[0..6].* = address.bytes;
        reply_params[6..22].* = bond.key;
        _ = _hci.command(layer, hci.HCI_OP_LINK_KEY_REPLY, &reply_params, _hci.COMMAND_TIMEOUT_MS);
        return;
    }
    _ = _hci.command(layer, hci.HCI_OP_LINK_KEY_NEGATIVE_REPLY, &address.bytes, _hci.COMMAND_TIMEOUT_MS);
}

/// PIN Code Request: a device without Secure Simple Pairing wants a PIN -
/// the agent's, or none.
pub fn pinCodeRequest(layer: *Hci, params: []const u8) void {
    if (params.len < 6) return;
    const address = bredr(params[0..6]);
    const connection = connections.find(layer, address) orelse return refusePin(layer, address);
    if (connection.pairing.stage == .idle or connection.pairing.purpose == .secure) {
        if (!theirs(layer, connection)) return refusePin(layer, address);
    }
    connection.pairing.legacy = true;
    if (connection.pairing.agent == 0 or connection.pairing.refused) {
        connection.pairing.refused = true;
        return refusePin(layer, address);
    }
    ask(layer, connection, bluetooth.BTAK_PIN, bluetooth.BT_NO_NUMBER);
}

/// IO Capability Request: this side's IO capability and requirements -
/// or, for a pairing the device begins with no agent there, a refusal.
pub fn ioCapabilityRequest(layer: *Hci, params: []const u8) void {
    if (params.len < 6) return;
    const address = bredr(params[0..6]);
    const connection = connections.find(layer, address) orelse return refuseCapability(layer, address);
    if (connection.pairing.stage == .idle or connection.pairing.purpose == .secure) {
        if (!theirs(layer, connection)) return refuseCapability(layer, address);
    }
    const pairing = &connection.pairing;
    const no_io = hci.IO_NO_INPUT_OUTPUT;
    if (pairing.ours) {
        pairing.our_auth = hci.AUTH_DEDICATED_BONDING | (if (pairing.our_io != no_io) hci.AUTH_MITM else 0);
    } else if (pairing.peer_io == UNKNOWN_IO) {
        // The device has not said what it wants: a bond.
        pairing.our_auth = hci.AUTH_GENERAL_BONDING;
    } else {
        // Its kind of bonding, and protection where both sides can give it.
        const mitm = pairing.our_io != no_io and pairing.peer_io != no_io;
        pairing.our_auth = (pairing.peer_auth & ~hci.AUTH_MITM) | (if (mitm) hci.AUTH_MITM else 0);
    }
    var reply_params: [9]u8 = undefined;
    reply_params[0..6].* = address.bytes;
    reply_params[6] = pairing.our_io;
    reply_params[7] = 0; // no out-of-band data
    reply_params[8] = pairing.our_auth;
    _ = _hci.command(layer, hci.HCI_OP_IO_CAPABILITY_REPLY, &reply_params, _hci.COMMAND_TIMEOUT_MS);
}

/// IO Capability Response: the device's IO capability and requirements.
pub fn ioCapabilityResponse(layer: *Hci, params: []const u8) void {
    if (params.len < 9) return;
    const connection = connections.find(layer, bredr(params[0..6])) orelse return;
    connection.pairing.peer_io = params[6];
    connection.pairing.peer_auth = params[8];
}

/// User Confirmation Request: the number both sides show, for the agent
/// to confirm where a side asked for protection from a man in the middle
/// and both can compare it. Otherwise there is nothing to compare (Just
/// Works): the library's own pairing is accepted at once, and for the
/// device's an agent that can answer is asked whether it may pair - one
/// that cannot lets it.
pub fn userConfirmationRequest(layer: *Hci, params: []const u8) void {
    if (params.len < 10) return;
    const address = bredr(params[0..6]);
    const connection = connections.find(layer, address) orelse return confirm(layer, address, false);
    const pairing = &connection.pairing;
    if (pairing.stage == .idle or pairing.purpose == .secure or pairing.refused) return confirm(layer, address, false);
    const no_io = hci.IO_NO_INPUT_OUTPUT;
    const ours_mitm = pairing.our_auth & hci.AUTH_MITM != 0;
    const theirs_mitm = pairing.peer_auth & hci.AUTH_MITM != 0;
    const compared = (ours_mitm and pairing.peer_io != no_io) or (theirs_mitm and pairing.our_io != no_io);
    const answers = pairing.agent != 0 and pairing.our_io == hci.IO_DISPLAY_YES_NO;
    if (compared and answers) return ask(layer, connection, bluetooth.BTAK_CONFIRM, le32(params[6..10]));
    if (pairing.ours or !answers) return confirm(layer, address, true);
    ask(layer, connection, bluetooth.BTAK_CONFIRM, bluetooth.BT_NO_NUMBER);
}

/// User Passkey Request: the passkey the device shows, typed by the
/// agent's user; refused without an agent.
pub fn userPasskeyRequest(layer: *Hci, params: []const u8) void {
    if (params.len < 6) return;
    const address = bredr(params[0..6]);
    const connection = connections.find(layer, address);
    if (connection) |known| {
        if (known.pairing.stage != .idle and known.pairing.agent != 0 and !known.pairing.refused) return ask(layer, known, bluetooth.BTAK_PASSKEY, bluetooth.BT_NO_NUMBER);
        known.pairing.refused = true;
    }
    _ = _hci.command(layer, hci.HCI_OP_USER_PASSKEY_NEGATIVE_REPLY, &address.bytes, _hci.COMMAND_TIMEOUT_MS);
}

/// User Passkey Notification: a passkey for the agent's user to type on
/// the device.
pub fn userPasskeyNotification(layer: *Hci, params: []const u8) void {
    if (params.len < 10) return;
    const connection = connections.find(layer, bredr(params[0..6])) orelse return;
    const pairing = &connection.pairing;
    if (pairing.stage == .idle) return;
    notice(layer, .{ .kind = .show, .agent = pairing.agent, .address = connection.address, .ours = pairing.ours, .number = le32(params[6..10]) });
}

/// Simple Pairing Complete: a pairing that failed is over - the device's
/// now, the library's at Authentication Complete, which follows.
pub fn simplePairingComplete(layer: *Hci, params: []const u8) void {
    if (params.len < 7 or params[0] == hci.HCI_SUCCESS) return;
    const connection = connections.find(layer, bredr(params[1..7])) orelse return;
    if (connection.pairing.stage == .idle or connection.pairing.ours) return;
    finish(layer, connection, params[0]);
}

/// Link Key Notification: a pairing's new key, kept as a bond when both
/// sides asked for one, or with a PIN; a debug key never. A key the
/// controller changed replaces the bond's. The device's pairing is over.
pub fn linkKeyNotification(layer: *Hci, params: []const u8) void {
    if (params.len < 23) return;
    const address = bredr(params[0..6]);
    const key: *const [hci.LINK_KEY_SIZE]u8 = params[6..22];
    const key_type = params[22];
    const connection = connections.find(layer, address) orelse return;
    const pairing = &connection.pairing;
    if (key_type == hci.LINK_KEY_CHANGED_COMBINATION) {
        if (bonds.find(layer, address)) |bond| {
            bond.key = key.*;
            bond.dirty = true;
            layer.bonds_changed = true;
        }
        return;
    }
    if (pairing.stage == .idle) return;
    const bonding = hci.AUTH_DEDICATED_BONDING | hci.AUTH_GENERAL_BONDING;
    const both = pairing.legacy or (pairing.our_auth & bonding != 0 and pairing.peer_auth & bonding != 0);
    if (key_type != hci.LINK_KEY_DEBUG and both) {
        if (bonds.keep(layer, address, key, key_type, pairing.legacy, connection.class_of_device, &connection.name) == null) pairing.full = true;
    }
    if (!pairing.ours) finish(layer, connection, 0);
}

/// Authentication Complete: the link authenticated, and then encrypted -
/// or the pairing over with the controller's status.
pub fn authenticationComplete(layer: *Hci, params: []const u8) void {
    if (params.len < 3) return;
    const connection = connections.byHandle(layer, _hci.le16(params[1..3]) & hci.ACL_HANDLE_MASK) orelse return;
    const status = params[0];
    if (status != hci.HCI_SUCCESS) {
        if (connection.pairing.stage != .idle) finish(layer, connection, status);
        return;
    }
    connection.authenticated = true;
    layer.changed = true;
    if (connection.pairing.stage == .idle) return;
    if (connection.encrypted) return checkSize(layer, connection);
    if (!encrypt(layer, connection)) finish(layer, connection, bluetooth.BTERR_NOMEM);
}

/// Encryption Change on a link being paired or made secure: its key's
/// size checked next - or the pairing over, unencrypted. An LE link's is
/// the security manager's.
pub fn encryptionChanged(layer: *Hci, connection: *Connection, status: u8) void {
    if (connection.le) return smp.encryptionChanged(layer, connection, status);
    if (connection.pairing.stage != .encrypting) return;
    if (status != hci.HCI_SUCCESS) return finish(layer, connection, status);
    if (!connection.encrypted) return finish(layer, connection, hci.HCI_ERR_INSUFFICIENT_SECURITY);
    checkSize(layer, connection);
}

/// A command's answer: Read Encryption Key Size's size, too short a key
/// ending the link; a pairing's command refused - or not answered in its
/// time - ending the pairing.
pub fn answered(layer: *Hci, opcode: u16, returned: []const u8) void {
    switch (opcode) {
        hci.HCI_OP_READ_ENCRYPTION_KEY_SIZE => {
            const connection = sentBy(layer, opcode) orelse return;
            if (returned.len < 4 or returned[0] != hci.HCI_SUCCESS) return sized(layer, connection);
            if (returned[3] < hci.MIN_ENCRYPTION_KEY_SIZE) {
                connections.close(layer, connection, hci.HCI_ERR_AUTHENTICATION_FAILURE);
                return finish(layer, connection, hci.HCI_ERR_INSUFFICIENT_SECURITY);
            }
            sized(layer, connection);
        },
        hci.HCI_OP_AUTHENTICATION_REQUESTED, hci.HCI_OP_SET_CONNECTION_ENCRYPTION, hci.HCI_OP_LE_ENABLE_ENCRYPTION, hci.HCI_OP_LE_LONG_TERM_KEY_REPLY => {
            const status: i32 = if (returned.len == 0) bluetooth.BTERR_TIMEOUT else returned[0];
            if (status == hci.HCI_SUCCESS) return;
            const connection = sentBy(layer, opcode) orelse return;
            if (connection.le) return smp.abandon(layer, connection, status);
            finish(layer, connection, status);
        },
        else => {},
    }
}

/// The link whose pairing sent `opcode` last.
fn sentBy(layer: *Hci, opcode: u16) ?*Connection {
    for (&layer.connections) |*connection| {
        if (connection.pairing.stage != .idle and connection.pairing.command == opcode) return connection;
    }
    return null;
}

// --- the time ---------------------------------------------------------------------

/// Whatever is due at `layer.now`: a question not answered refused, a
/// pairing that took too long given up on.
pub fn tick(layer: *Hci) void {
    for (&layer.connections) |*connection| {
        const pairing = &connection.pairing;
        if (pairing.stage == .idle) continue;
        if (pairing.question.kind != 0 and layer.now >= pairing.question.deadline) unasked(layer, connection);
        if (pairing.deadline) |due| {
            if (layer.now >= due) {
                if (connection.le) smp.abandon(layer, connection, bluetooth.BTERR_TIMEOUT) else finish(layer, connection, bluetooth.BTERR_TIMEOUT);
            }
        }
    }
}

/// The earliest a pairing's time is due; null for none.
pub fn deadline(layer: *const Hci) ?u64 {
    var earliest: ?u64 = null;
    for (&layer.connections) |*connection| {
        const pairing = &connection.pairing;
        if (pairing.stage == .idle) continue;
        for ([_]?u64{ pairing.deadline, if (pairing.question.kind != 0) pairing.question.deadline else null }) |due_or_none| {
            const due = due_or_none orelse continue;
            if (earliest == null or due < earliest.?) earliest = due;
        }
    }
    return earliest;
}

// --- the bytes ----------------------------------------------------------------------

fn bredr(bytes: *const [6]u8) bluetooth.BTAddress {
    return .{ .bytes = bytes.*, .kind = bluetooth.BTADDR_BREDR };
}

fn le32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) | @as(u32, bytes[1]) << 8 | @as(u32, bytes[2]) << 16 | @as(u32, bytes[3]) << 24;
}

fn put16(into: *[2]u8, value: u16) void {
    into[0] = @truncate(value);
    into[1] = @truncate(value >> 8);
}

fn put32(into: *[4]u8, value: u32) void {
    into[0] = @truncate(value);
    into[1] = @truncate(value >> 8);
    into[2] = @truncate(value >> 16);
    into[3] = @truncate(value >> 24);
}
