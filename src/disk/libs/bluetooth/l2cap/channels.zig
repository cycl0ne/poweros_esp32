// SPDX-License-Identifier: MIT
//! L2CAP's dynamic channels over a controller's BR/EDR links: each to one
//! protocol of the device, named by its PSM, opened by this machine or by
//! the device, configured both ways, carrying frames each way in basic
//! mode, and closed by either side or with its link.
//!
//! **Opened by this machine** (`open`): a Connection Request over the
//! link to the device - made first where there is none, which then ends
//! once its channels have (connections.zig). A device that answers
//! pending is waited for longer; one that refuses is answered as it says.
//! **Opened by the device**: a Connection Request to the SDP server's
//! PSM, or to a PSM a listener has (the port's `listener`), is taken on;
//! any other is answered that there is no such protocol.
//!
//! **Configured** by each side's Configure Request, each answered. Ours
//! says this machine's MTU, MTU_IN. The device's is taken: its MTU as the
//! most a frame to it carries - at least 48, 672 where it says none -
//! basic mode alone, another mode answered as unacceptable, a flush
//! timeout, a quality of service and the hints passed over, an option it
//! does not know answered as such. The channel is open once both are
//! answered success; a request that comes in parts is answered part by
//! part.
//!
//! **Its user** is the task's - a call's, or a listener's: its `owner` is
//! the task's record of it, and the task is told what happens through the
//! port's `channel` - or the layer's own: the SDP server's or the SDP
//! client's (sdp/). A user is told of a channel's end once, with why; a
//! call waiting for one to open or close is known by its serial.
//!
//! **Closed** by a Disconnection Request either way, each answered; with
//! its link; or when a request of ours is not answered in its time.
//!
//! Pure, as the rest of the layer.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const l2cap = bluetooth.l2cap;
const _hci = @import("../hci/_hci.zig");
const Hci = _hci.Hci;
const acl = @import("../hci/acl.zig");
const connections = @import("../hci/connections.zig");
const Connection = connections.Connection;
const signalling = @import("signalling.zig");
const sdp_server = @import("../sdp/server.zig");
const sdp_client = @import("../sdp/client.zig");

/// How many channels a controller keeps.
pub const CHANNELS = 16;
/// The most frames of a channel out with the task unreplied.
pub const OUT_MOST = 32;
/// This machine's MTU: the most a frame it takes carries.
pub const MTU_IN: u16 = acl.FRAME_MOST;
/// How long a request of ours is waited for, and a connection the device
/// said is pending.
pub const REQUEST_WAIT_MS: u32 = 10_000;
pub const PENDING_WAIT_MS: u32 = 60_000;
/// How long a channel's close is waited for.
pub const CLOSE_WAIT_MS: u32 = 5_000;

pub const State = enum(u8) { free, linking, connecting, configuring, open, disconnecting };

/// Whose a channel is.
pub const User = enum(u8) { task, sdp_server, sdp_client };

pub const Channel = struct {
    state: State = .free,
    user: User = .task,
    /// Opened by the device.
    incoming: bool = false,
    /// The task was told it is open - its call answered, or its listener
    /// told - and is told when it ends.
    told: bool = false,
    /// Its making no longer wanted: closed once the device has answered.
    unwanted: bool = false,
    /// Its configuration: ours answered success by the device, the
    /// device's answered success here.
    ours_done: bool = false,
    theirs_done: bool = false,
    /// The device, and the handle of its link once there is one.
    address: bluetooth.BTAddress = .{},
    handle: u16 = 0,
    psm: u16 = 0,
    local_cid: u16 = 0,
    remote_cid: u16 = 0,
    /// The most a frame to the device carries: its MTU.
    mtu_out: u16 = l2cap.MTU_DEFAULT,
    /// The request of ours it waits for, by its identifier, and until
    /// when.
    ident: u8 = 0,
    deadline: ?u64 = null,
    /// What its user is told once it is closed, while it is closed by a
    /// request of ours.
    result: i32 = 0,
    /// Its number, never 0, which the calls waiting for it know it by;
    /// the listener's for one a device opened to a listener.
    serial: u32 = 0,
    listener: u32 = 0,
    /// The task's: its record of the channel, and how many of its
    /// messages are out unreplied.
    owner: ?*anyopaque = null,
    out: u8 = 0,
};

/// What the task is told of its channels: one open - a device's to a
/// listener, or its own call's - a frame, one closed.
pub const EventKind = enum(u8) { opened, data, closed };

pub const Event = struct {
    kind: EventKind,
    channel: *Channel,
    /// data: the frame.
    data: []const u8 = &.{},
    /// closed: why - 0 for the device's close, else BTERR_* or the link's
    /// reason.
    result: i32 = 0,
};

/// The channel whose owner is `owner`, the task's record; null for none.
pub fn byOwner(layer: *Hci, owner: *const anyopaque) ?*Channel {
    for (&layer.channels) |*channel| {
        if (channel.state != .free and channel.owner == owner) return channel;
    }
    return null;
}

/// The channel numbered `serial`; null for none.
pub fn bySerial(layer: *Hci, serial: u32) ?*Channel {
    if (serial == 0) return null;
    for (&layer.channels) |*channel| {
        if (channel.state != .free and channel.serial == serial) return channel;
    }
    return null;
}

/// The channel of the link whose end here is `cid`; null for none.
fn byLocal(layer: *Hci, connection: *const Connection, cid: u16) ?*Channel {
    for (&layer.channels) |*channel| {
        if (channel.state == .free or channel.state == .linking) continue;
        if (channel.handle == connection.handle and channel.local_cid == cid) return channel;
    }
    return null;
}

/// Whether any channel is on, or waits for, the link to `address`.
pub fn uses(layer: *const Hci, address: bluetooth.BTAddress) bool {
    for (&layer.channels) |*channel| {
        if (channel.state != .free and connections.sameAddress(channel.address, address)) return true;
    }
    return false;
}

/// How many channels are in use.
pub fn count(layer: *const Hci) usize {
    var in_use: usize = 0;
    for (&layer.channels) |*channel| {
        if (channel.state != .free) in_use += 1;
    }
    return in_use;
}

fn freeChannel(layer: *Hci) ?*Channel {
    for (&layer.channels) |*channel| {
        if (channel.state == .free) return channel;
    }
    return null;
}

fn newSerial(layer: *Hci) u32 {
    layer.channel_serial +%= 1;
    if (layer.channel_serial == 0) layer.channel_serial = 1;
    return layer.channel_serial;
}

fn newIdent(layer: *Hci) u8 {
    layer.signal_ident +%= 1;
    if (layer.signal_ident == 0) layer.signal_ident = 1;
    return layer.signal_ident;
}

/// A CID no channel of the controller has.
fn newCid(layer: *Hci) u16 {
    while (true) {
        const cid = layer.next_cid;
        layer.next_cid = if (cid == 0xFFFF) l2cap.CID_DYNAMIC_FIRST else cid + 1;
        var taken = false;
        for (&layer.channels) |*channel| {
            if (channel.state != .free and channel.local_cid == cid) taken = true;
        }
        if (!taken) return cid;
    }
}

/// Whether `psm` is one a channel can name: odd, the low bit of its upper
/// byte clear.
pub fn validPsm(psm: u32) bool {
    return psm <= 0xFFFF and psm & 0x0001 != 0 and psm & 0x0100 == 0;
}

// --- opened by this machine -------------------------------------------------------

/// What `begin` made: the channel, or why not.
pub const Began = union(enum) { channel: *Channel, failed: i32 };

/// OpenBTChannel: a channel to `psm` of the device at `address` begun for
/// the task, the link made first where there is none - the call's wait,
/// or why not at once.
pub fn open(layer: *Hci, address: bluetooth.BTAddress, psm: u16) connections.Begun {
    if (!connections.canWait(layer)) return .{ .done = bluetooth.BTERR_NOMEM };
    const channel = switch (begin(layer, address, psm, .task)) {
        .channel => |made| made,
        .failed => |result| return .{ .done = result },
    };
    return connections.waitForSerial(layer, .open, channel.serial);
}

/// A channel to `psm` of the device at `address` begun for `user`: asked
/// for over the link, or waiting for it to be up - made where there is
/// none, as a link for channels.
pub fn begin(layer: *Hci, address: bluetooth.BTAddress, psm: u16, user: User) Began {
    if (layer.state != bluetooth.BTCS_UP) return .{ .failed = bluetooth.BTERR_NOTUP };
    if (!layer.powered) return .{ .failed = bluetooth.BTERR_OFF };
    if (address.kind != bluetooth.BTADDR_BREDR or !validPsm(psm)) return .{ .failed = bluetooth.BTERR_UNSUPPORTED };
    const channel = freeChannel(layer) orelse return .{ .failed = bluetooth.BTERR_NOMEM };
    const made: Channel = .{ .state = .linking, .user = user, .address = address, .psm = psm, .local_cid = newCid(layer), .serial = newSerial(layer) };
    if (connections.find(layer, address)) |connection| {
        switch (connection.state) {
            .up => {
                channel.* = made;
                if (connection.heard and !connections.securing(connection) and !request(layer, channel, connection)) {
                    channel.* = .{};
                    return .{ .failed = bluetooth.BTERR_NOMEM };
                }
            },
            // Asked for once it is up.
            .connecting => channel.* = made,
            .disconnecting, .free => return .{ .failed = bluetooth.BTERR_BUSY },
        }
        return .{ .channel = channel };
    }
    const result = connections.make(layer, address);
    if (result != 0) return .{ .failed = result };
    connections.find(layer, address).?.for_channels = true;
    channel.* = made;
    return .{ .channel = channel };
}

/// Connection Request for the channel, over its link that is up.
fn request(layer: *Hci, channel: *Channel, connection: *const Connection) bool {
    var data: [4]u8 = undefined;
    put16(data[0..2], channel.psm);
    put16(data[2..4], channel.local_cid);
    const ident = newIdent(layer);
    if (!signalling.signal(layer, connection, l2cap.CID_SIGNALING, l2cap.CONNECTION_REQUEST, ident, &data)) return false;
    channel.state = .connecting;
    channel.handle = connection.handle;
    channel.ident = ident;
    channel.deadline = layer.now + REQUEST_WAIT_MS;
    return true;
}

/// A BR/EDR link up and heard, or made secure with its bond - or not:
/// the channels waiting for it asked for.
pub fn linkUp(layer: *Hci, connection: *const Connection) void {
    if (connection.le or connection.state != .up or !connection.heard or connections.securing(connection)) return;
    for (&layer.channels) |*channel| {
        if (channel.state != .linking or !connections.sameAddress(channel.address, connection.address)) continue;
        if (!request(layer, channel, connection)) gone(layer, channel, bluetooth.BTERR_NOMEM);
    }
}

/// Connection Response to a request of ours, by its identifier: the
/// channel configured, or waited for longer, or refused.
pub fn connectionResponse(layer: *Hci, connection: *const Connection, ident: u8, data: []const u8) void {
    if (data.len < 8) return;
    const their_cid = _hci.le16(data[0..2]);
    const result = _hci.le16(data[4..6]);
    const channel = byIdent(layer, connection, .connecting, ident) orelse return;
    switch (result) {
        l2cap.CONNECTION_SUCCESS => {
            if (their_cid < l2cap.CID_DYNAMIC_FIRST) return gone(layer, channel, bluetooth.BTERR_PROTOCOL);
            channel.remote_cid = their_cid;
            if (channel.unwanted) return close(layer, channel, bluetooth.BTERR_REFUSED);
            if (!configure(layer, channel, connection)) close(layer, channel, bluetooth.BTERR_NOMEM);
        },
        l2cap.CONNECTION_PENDING => channel.deadline = layer.now + PENDING_WAIT_MS,
        else => gone(layer, channel, refusal(result)),
    }
}

/// What a call is answered for a device's refusal.
fn refusal(result: u16) i32 {
    return switch (result) {
        l2cap.CONNECTION_PSM_NOT_SUPPORTED => bluetooth.BTERR_UNSUPPORTED,
        l2cap.CONNECTION_NO_RESOURCES => bluetooth.BTERR_BUSY,
        else => bluetooth.BTERR_REFUSED,
    };
}

// --- opened by the device ---------------------------------------------------------

/// Connection Request: a channel the device opens - to the SDP server's
/// PSM, or a listener's - taken on and configured; any other answered.
pub fn connectionRequest(layer: *Hci, connection: *const Connection, ident: u8, data: []const u8) void {
    const cid = l2cap.CID_SIGNALING;
    if (data.len < 4) return signalling.reject(layer, connection, cid, ident, l2cap.REJECT_NOT_UNDERSTOOD, &.{});
    const psm = _hci.le16(data[0..2]);
    const their_cid = _hci.le16(data[2..4]);
    var answer: [8]u8 = @splat(0);
    put16(answer[2..4], their_cid);
    var user: User = .task;
    var listener: u32 = 0;
    if (psm == l2cap.PSM_SDP) {
        user = .sdp_server;
    } else {
        listener = if (layer.port.listener) |find| find(layer.port.context, psm) else 0;
        if (listener == 0) {
            put16(answer[4..6], l2cap.CONNECTION_PSM_NOT_SUPPORTED);
            return signalling.respond(layer, connection, cid, l2cap.CONNECTION_RESPONSE, ident, &answer);
        }
    }
    const refused: ?u16 = if (their_cid < l2cap.CID_DYNAMIC_FIRST)
        l2cap.CONNECTION_INVALID_SOURCE_CID
    else if (byRemote(layer, connection, their_cid) != null)
        l2cap.CONNECTION_SOURCE_CID_TAKEN
    else
        null;
    const channel = if (refused == null) freeChannel(layer) else null;
    if (channel == null) {
        put16(answer[4..6], refused orelse l2cap.CONNECTION_NO_RESOURCES);
        return signalling.respond(layer, connection, cid, l2cap.CONNECTION_RESPONSE, ident, &answer);
    }
    channel.?.* = .{
        .state = .configuring,
        .user = user,
        .incoming = true,
        .address = connection.address,
        .handle = connection.handle,
        .psm = psm,
        .local_cid = newCid(layer),
        .remote_cid = their_cid,
        .serial = if (user == .task) newSerial(layer) else 0,
        .listener = listener,
    };
    put16(answer[0..2], channel.?.local_cid);
    put16(answer[4..6], l2cap.CONNECTION_SUCCESS);
    signalling.respond(layer, connection, cid, l2cap.CONNECTION_RESPONSE, ident, &answer);
    if (!configure(layer, channel.?, connection)) close(layer, channel.?, bluetooth.BTERR_NOMEM);
}

/// The channel of the link in `state` whose request of ours was `ident`.
fn byIdent(layer: *Hci, connection: *const Connection, state: State, ident: u8) ?*Channel {
    for (&layer.channels) |*channel| {
        if (channel.state == state and channel.handle == connection.handle and channel.ident == ident) return channel;
    }
    return null;
}

fn byRemote(layer: *Hci, connection: *const Connection, cid: u16) ?*Channel {
    for (&layer.channels) |*channel| {
        if (channel.state == .free or channel.state == .linking) continue;
        if (channel.handle == connection.handle and channel.remote_cid == cid) return channel;
    }
    return null;
}

// --- configured -------------------------------------------------------------------

/// Our Configure Request: this machine's MTU.
fn configure(layer: *Hci, channel: *Channel, connection: *const Connection) bool {
    var data: [8]u8 = undefined;
    put16(data[0..2], channel.remote_cid);
    put16(data[2..4], 0);
    data[4] = l2cap.OPTION_MTU;
    data[5] = 2;
    put16(data[6..8], MTU_IN);
    const ident = newIdent(layer);
    if (!signalling.signal(layer, connection, l2cap.CID_SIGNALING, l2cap.CONFIGURE_REQUEST, ident, &data)) return false;
    channel.state = .configuring;
    channel.ident = ident;
    channel.deadline = layer.now + REQUEST_WAIT_MS;
    return true;
}

/// Configure Request: the device's configuration of the channel taken,
/// or answered with what is wrong with it.
pub fn configureRequest(layer: *Hci, connection: *const Connection, ident: u8, data: []const u8) void {
    const cid = l2cap.CID_SIGNALING;
    if (data.len < 4) return signalling.reject(layer, connection, cid, ident, l2cap.REJECT_NOT_UNDERSTOOD, &.{});
    const our_cid = _hci.le16(data[0..2]);
    const flags = _hci.le16(data[2..4]);
    const channel = byLocal(layer, connection, our_cid) orelse return signalling.noChannel(layer, connection, cid, ident, data, 2);
    if (channel.state != .configuring and channel.state != .open) return signalling.noChannel(layer, connection, cid, ident, data, 2);
    // Where it says no MTU, the one it had - 672 to begin with.
    var mtu = channel.mtu_out;
    var small_mtu = false;
    var other_mode = false;
    var unknown: [MOST_UNKNOWN]u8 = undefined;
    var unknown_count: usize = 0;
    var at: usize = 4;
    while (at < data.len) {
        if (data.len - at < 2 or data.len - at - 2 < data[at + 1]) return signalling.reject(layer, connection, cid, ident, l2cap.REJECT_NOT_UNDERSTOOD, &.{});
        const kind = data[at];
        const value = data[at + 2 ..][0..data[at + 1]];
        at += 2 + value.len;
        switch (kind & ~l2cap.OPTION_HINT) {
            l2cap.OPTION_MTU => if (value.len == 2) {
                const asked = _hci.le16(value[0..2]);
                if (asked < l2cap.MTU_LEAST_BREDR) small_mtu = true else mtu = asked;
            },
            l2cap.OPTION_RETRANSMISSION => if (value.len >= 1 and value[0] != l2cap.MODE_BASIC) {
                other_mode = true;
            },
            l2cap.OPTION_FLUSH_TIMEOUT, l2cap.OPTION_QOS, l2cap.OPTION_FCS, l2cap.OPTION_FLOW_SPEC, l2cap.OPTION_WINDOW => {},
            else => if (kind & l2cap.OPTION_HINT == 0 and unknown_count < unknown.len) {
                unknown[unknown_count] = kind;
                unknown_count += 1;
            },
        }
    }
    var answer: [6 + 4 + 2 + l2cap.OPTION_RETRANSMISSION_LENGTH]u8 = undefined;
    put16(answer[0..2], channel.remote_cid);
    put16(answer[2..4], flags & l2cap.CONFIGURE_CONTINUATION);
    var length: usize = 6;
    var result = l2cap.CONFIGURE_SUCCESS;
    if (unknown_count > 0) {
        // The options it does not know, each by its type alone.
        result = l2cap.CONFIGURE_UNKNOWN_OPTIONS;
        for (unknown[0..unknown_count]) |kind| {
            answer[length] = kind;
            answer[length + 1] = 0;
            length += 2;
        }
    } else if (small_mtu or other_mode) {
        // What would be taken instead.
        result = l2cap.CONFIGURE_UNACCEPTABLE;
        if (small_mtu) {
            answer[length] = l2cap.OPTION_MTU;
            answer[length + 1] = 2;
            put16(answer[length + 2 ..][0..2], l2cap.MTU_LEAST_BREDR);
            length += 4;
        }
        if (other_mode) {
            answer[length] = l2cap.OPTION_RETRANSMISSION;
            answer[length + 1] = l2cap.OPTION_RETRANSMISSION_LENGTH;
            @memset(answer[length + 2 ..][0..l2cap.OPTION_RETRANSMISSION_LENGTH], 0);
            length += 2 + l2cap.OPTION_RETRANSMISSION_LENGTH;
        }
    }
    put16(answer[4..6], result);
    signalling.respond(layer, connection, cid, l2cap.CONFIGURE_RESPONSE, ident, answer[0..length]);
    if (result != l2cap.CONFIGURE_SUCCESS) return;
    channel.mtu_out = mtu;
    // A part: answered, the rest to come.
    if (flags & l2cap.CONFIGURE_CONTINUATION != 0) return;
    channel.theirs_done = true;
    if (channel.state == .configuring and channel.ours_done) opened(layer, channel);
}

/// The most unknown options a Configure Response names.
const MOST_UNKNOWN = 4;

/// Configure Response to ours: the channel open once the device's is
/// answered too, or closed for a configuration the device does not take.
pub fn configureResponse(layer: *Hci, connection: *const Connection, ident: u8, data: []const u8) void {
    if (data.len < 6) return;
    const our_cid = _hci.le16(data[0..2]);
    const flags = _hci.le16(data[2..4]);
    const result = _hci.le16(data[4..6]);
    const channel = byLocal(layer, connection, our_cid) orelse return;
    if (channel.state != .configuring or channel.ident != ident) return;
    switch (result) {
        l2cap.CONFIGURE_SUCCESS => {
            if (flags & l2cap.CONFIGURE_CONTINUATION != 0) return;
            channel.ours_done = true;
            // The device's own still to come.
            channel.deadline = layer.now + REQUEST_WAIT_MS;
            if (channel.theirs_done) opened(layer, channel);
        },
        l2cap.CONFIGURE_PENDING => channel.deadline = layer.now + PENDING_WAIT_MS,
        else => close(layer, channel, bluetooth.BTERR_REFUSED),
    }
}

/// Both configurations taken: the channel open, and its user told - one
/// a device opened that the task does not take, its listener gone or no
/// room for it, closed again.
fn opened(layer: *Hci, channel: *Channel) void {
    channel.state = .open;
    channel.deadline = null;
    switch (channel.user) {
        .task => {
            const taken = if (layer.port.channel) |tell| tell(layer.port.context, &.{ .kind = .opened, .channel = channel }) else !channel.incoming;
            if (!taken) return close(layer, channel, bluetooth.BTERR_NOMEM);
            channel.told = true;
            if (!channel.incoming) connections.answerSerial(layer, .open, channel.serial, 0);
        },
        .sdp_server => {},
        .sdp_client => sdp_client.opened(layer, channel),
    }
}

// --- frames -----------------------------------------------------------------------

/// A frame of the link on a dynamic channel: to the channel's user.
pub fn received(layer: *Hci, connection: *const Connection, cid: u16, payload: []const u8) void {
    const channel = byLocal(layer, connection, cid) orelse return;
    if (channel.state != .open) return;
    switch (channel.user) {
        .task => if (channel.told) {
            if (layer.port.channel) |tell| _ = tell(layer.port.context, &.{ .kind = .data, .channel = channel, .data = payload });
        },
        .sdp_server => sdp_server.received(layer, channel, payload),
        .sdp_client => sdp_client.received(layer, channel, payload),
    }
}

/// SendBTChannel: a frame on the task's channel - 0 once it is queued,
/// BTERR_BUSY while the queue is full, or why not.
pub fn send(layer: *Hci, channel: *const Channel, data: []const u8) i32 {
    if (channel.state != .open) return bluetooth.BTERR_NOTCONNECTED;
    if (data.len > channel.mtu_out or data.len > acl.FRAME_MOST) return bluetooth.BTERR_TOOLONG;
    return if (frame(layer, channel, data)) 0 else bluetooth.BTERR_BUSY;
}

/// A frame to the device on the channel: false where it cannot be queued.
pub fn frame(layer: *Hci, channel: *const Channel, data: []const u8) bool {
    const connection = connections.byHandle(layer, channel.handle) orelse return false;
    return acl.send(layer, connection, channel.remote_cid, data);
}

// --- closed -----------------------------------------------------------------------

/// CloseBTChannel: the task's channel closed - the call's wait for the
/// device's answer, or done at once. Its user is told nothing more, and
/// its owner is no longer known.
pub fn closeFor(layer: *Hci, channel: *Channel) connections.Begun {
    const serial = channel.serial;
    channel.told = false;
    channel.owner = null;
    switch (channel.state) {
        .open, .configuring => close(layer, channel, 0),
        .connecting => {
            channel.unwanted = true;
            return .{ .done = 0 };
        },
        .linking => {
            gone(layer, channel, 0);
            return .{ .done = 0 };
        },
        .disconnecting => {},
        .free => return .{ .done = 0 },
    }
    // Closed at once, its record another's by now, or waited for.
    if (channel.state != .disconnecting or channel.serial != serial) return .{ .done = 0 };
    if (!connections.canWait(layer)) return .{ .done = 0 };
    return connections.waitForSerial(layer, .close, serial);
}

/// The channel closed by a request of ours - its user told `result` once
/// the device has answered - or at once where none can be sent.
pub fn close(layer: *Hci, channel: *Channel, result: i32) void {
    channel.result = result;
    const connection = connections.byHandle(layer, channel.handle) orelse return gone(layer, channel, result);
    var data: [4]u8 = undefined;
    put16(data[0..2], channel.remote_cid);
    put16(data[2..4], channel.local_cid);
    const ident = newIdent(layer);
    if (!signalling.signal(layer, connection, l2cap.CID_SIGNALING, l2cap.DISCONNECTION_REQUEST, ident, &data)) return gone(layer, channel, result);
    channel.state = .disconnecting;
    channel.ident = ident;
    channel.deadline = layer.now + CLOSE_WAIT_MS;
}

/// Disconnection Request: the device closes the channel - answered, and
/// its user told.
pub fn disconnectionRequest(layer: *Hci, connection: *const Connection, ident: u8, data: []const u8) void {
    const cid = l2cap.CID_SIGNALING;
    if (data.len < 4) return signalling.reject(layer, connection, cid, ident, l2cap.REJECT_NOT_UNDERSTOOD, &.{});
    const our_cid = _hci.le16(data[0..2]);
    const their_cid = _hci.le16(data[2..4]);
    const channel = byLocal(layer, connection, our_cid) orelse return signalling.noChannel(layer, connection, cid, ident, data, 4);
    if (channel.remote_cid != their_cid) return signalling.noChannel(layer, connection, cid, ident, data, 4);
    signalling.respond(layer, connection, cid, l2cap.DISCONNECTION_RESPONSE, ident, data[0..4]);
    gone(layer, channel, if (channel.state == .disconnecting) channel.result else 0);
}

/// Disconnection Response to ours: the channel closed.
pub fn disconnectionResponse(layer: *Hci, connection: *const Connection, ident: u8, data: []const u8) void {
    if (data.len < 4) return;
    const our_cid = _hci.le16(data[2..4]);
    const channel = byLocal(layer, connection, our_cid) orelse return;
    if (channel.state != .disconnecting or channel.ident != ident) return;
    gone(layer, channel, channel.result);
}

/// Command Reject for a request of ours: what it asked for given up.
pub fn rejected(layer: *Hci, connection: *const Connection, ident: u8) void {
    for (&layer.channels) |*channel| {
        if (channel.state == .free or channel.state == .linking) continue;
        if (channel.handle != connection.handle or channel.ident != ident) continue;
        switch (channel.state) {
            .connecting => gone(layer, channel, bluetooth.BTERR_REFUSED),
            .configuring => close(layer, channel, bluetooth.BTERR_REFUSED),
            .disconnecting => gone(layer, channel, channel.result),
            .open, .linking, .free => {},
        }
    }
}

/// A link down, or not made, for `reason`: its channels closed with it.
pub fn linkGone(layer: *Hci, connection: *const Connection, reason: i32) void {
    for (&layer.channels) |*channel| {
        if (channel.state == .free or !connections.sameAddress(channel.address, connection.address)) continue;
        gone(layer, channel, if (channel.state == .disconnecting) channel.result else reason);
    }
}

/// Every channel forgotten with its controller's links, its user told
/// `result`.
pub fn reset(layer: *Hci, result: i32) void {
    for (&layer.channels) |*channel| {
        if (channel.state != .free) gone(layer, channel, result);
    }
}

/// The channel ended for `result`: its user told once - a call opening it
/// answered, the task told of one it knew, the SDP client - its record
/// freed, and its link ended later where it was made for channels and
/// none is left on it.
fn gone(layer: *Hci, channel: *Channel, result: i32) void {
    const address = channel.address;
    switch (channel.user) {
        .task => {
            if (channel.told) {
                if (layer.port.channel) |tell| _ = tell(layer.port.context, &.{ .kind = .closed, .channel = channel, .result = result });
            } else if (!channel.incoming) {
                // Ended before it was open: never success.
                connections.answerSerial(layer, .open, channel.serial, if (result == 0) bluetooth.BTERR_REFUSED else result);
            }
            connections.answerSerial(layer, .close, channel.serial, 0);
        },
        .sdp_server => {},
        .sdp_client => sdp_client.channelGone(layer, channel, result),
    }
    channel.* = .{};
    if (!uses(layer, address)) connections.idle(layer, address);
}

// --- the time ---------------------------------------------------------------------

/// The channels whose requests were not answered in their time given up.
pub fn tick(layer: *Hci) void {
    for (&layer.channels) |*channel| {
        const due = channel.deadline orelse continue;
        if (layer.now < due) continue;
        channel.deadline = null;
        switch (channel.state) {
            .connecting => gone(layer, channel, bluetooth.BTERR_TIMEOUT),
            .configuring => close(layer, channel, bluetooth.BTERR_TIMEOUT),
            .disconnecting => gone(layer, channel, channel.result),
            .open, .linking, .free => {},
        }
    }
}

/// The earliest of the channels' times; null for none.
pub fn deadline(layer: *const Hci) ?u64 {
    var earliest: ?u64 = null;
    for (&layer.channels) |*channel| {
        const due = channel.deadline orelse continue;
        if (earliest == null or due < earliest.?) earliest = due;
    }
    return earliest;
}

fn put16(into: *[2]u8, value: u16) void {
    into[0] = @truncate(value);
    into[1] = @truncate(value >> 8);
}
