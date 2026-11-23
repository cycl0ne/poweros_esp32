// SPDX-License-Identifier: MIT
//! GATT's client over a controller's LE links: the blocks OpenBTGatt
//! opens and what they subscribe to, and the procedures the calls ask
//! for - a request of the attribute protocol, or a run of them - one at a
//! time on a link, in the order they were asked for.
//!
//! **A procedure** waits until its link is up and heard, made secure
//! where there is a bond (hci/pairing.zig), and this machine's MTU
//! exchanged; a link is made for it where there is none, as a link for
//! channels, which ends two seconds after the last of its blocks and
//! procedures (hci/connections.zig). Its call's wait knows it by its
//! serial; one without a call - a configuration written as a block closes
//! - has none, and is freed at its end. Otherwise its end is kept for the
//! task: its result, and how much of the caller's room it filled.
//!
//! - **open** (OpenBTGatt): its block open as soon as it runs.
//! - **services** (ObtainBTServices over LE): Read By Group Type of the
//!   primary services, from the first handle to the last, into the room
//!   as a ServiceRecord each.
//! - **characteristics** (ObtainBTCharacteristics): Read By Type of the
//!   characteristic declarations within the service, then Find
//!   Information of the handles between each value and the next
//!   declaration; into the room the count, a CharacteristicRecord each,
//!   then a DescriptorRecord each.
//! - **read**: a Read Request, then Read Blob from where it ended while an
//!   answer fills its PDU and the room has more.
//! - **write**: a Write Request; **write_command**: a Write Command, over
//!   once it is sent. Neither longer than the MTU carries (BTERR_TOOLONG).
//! - **configure**: a characteristic's Client Characteristic
//!   Configuration written with what the link's open blocks want of it as
//!   the procedure runs - so writes asked for one after the other each
//!   leave what is wanted then - and a subscription the device refuses
//!   taken back.
//!
//! A request the device refuses ends its procedure with BTERR_ATT less
//! the device's reason - except where the refusal is how its answer ends:
//! no attribute past the last one found, no more of a value.
//!
//! **A block** is the task's BTGatt, its `owner`: open once its open
//! procedure has run, closed with its link - the task told, with why -
//! and freed by `close`. Each notification or indication of a value goes
//! to every block on the link subscribed to it; the task lets go of a
//! block's past OUT_MOST unreplied.
//!
//! Pure, as the rest of the layer.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const att = bluetooth.att;
const _hci = @import("../hci/_hci.zig");
const Hci = _hci.Hci;
const connections = @import("../hci/connections.zig");
const Connection = connections.Connection;
const sameAddress = connections.sameAddress;
const _att = @import("_att.zig");
const le16 = _att.le16;
const put16 = _att.put16;

/// How many procedures a controller keeps, blocks it serves, and values a
/// block subscribes to.
pub const PROCEDURES = 24;
pub const CLIENTS = 16;
pub const SUBSCRIPTIONS = 16;
/// The most messages of a block's values out unreplied.
pub const OUT_MOST = 32;

pub const Kind = enum(u8) { open, services, characteristics, read, write, write_command, configure };
pub const Stage = enum(u8) { free, queued, running, done };

pub const Procedure = struct {
    stage: Stage = .free,
    kind: Kind = .open,
    /// characteristics: the descriptors are being found.
    finding: bool = false,
    address: bluetooth.BTAddress = .{},
    /// Its call's wait knows it by this; 0 for none. An open's is its
    /// block's.
    serial: u32 = 0,
    /// When it was asked for: a link's run in this order.
    order: u64 = 0,
    /// The attribute - read, write; configure: the value whose
    /// configuration it writes - or the handles from `start` to `end`;
    /// where its next request starts, 0 for a characteristic whose
    /// descriptors are not asked for yet.
    start: u16 = 0,
    end: u16 = 0,
    next: u32 = 0,
    /// characteristics, finding: the characteristic whose descriptors are
    /// asked for, and how many descriptors are in the room.
    at: u16 = 0,
    descriptors: u16 = 0,
    /// configure: the configuration's handle, and the block whose
    /// subscription it writes - taken back where the device refuses it;
    /// 0 for none.
    configuration: u16 = 0,
    client: u32 = 0,
    /// write, write_command: the caller's value.
    value: []const u8 = &.{},
    /// services, characteristics, read: the caller's room, and how much of
    /// it is filled.
    into: []u8 = &.{},
    have: usize = 0,
    /// Once done.
    result: i32 = 0,
};

/// A service, as the services procedure puts it in its room.
pub const ServiceRecord = extern struct {
    start: u16,
    end: u16,
    /// Big-endian, as written.
    uuid: [16]u8,
};

/// A characteristic, as the characteristics procedure puts it in its room
/// - its first descriptor by its place among the descriptors.
pub const CharacteristicRecord = extern struct {
    handle: u16,
    value: u16,
    end: u16,
    properties: u8,
    pad: u8 = 0,
    first_descriptor: u16,
    descriptor_count: u16,
    uuid: [16]u8,
};

pub const DescriptorRecord = extern struct {
    handle: u16,
    uuid: [16]u8,
};

/// The characteristics procedure's room: the count of characteristics (2
/// bytes, then 2 spare) before their records.
pub const CHARACTERISTICS_HEAD: usize = 4;

/// A value a block is sent: its handle (0 for a free one), its
/// configuration's, and what it wants (att.GATT_CCC_*).
pub const Subscription = struct {
    value: u16 = 0,
    configuration: u16 = 0,
    bits: u16 = 0,
};

pub const ClientState = enum(u8) { free, opening, open, closed };

pub const Client = struct {
    state: ClientState = .free,
    address: bluetooth.BTAddress = .{},
    /// Its number, never 0; its open procedure's too.
    serial: u32 = 0,
    /// The task's: its block, and how many messages of its values are out.
    owner: ?*anyopaque = null,
    out: u8 = 0,
    subscriptions: [SUBSCRIPTIONS]Subscription = @splat(.{}),
};

/// What the task is told of a block: a value, its close.
pub const EventKind = enum(u8) { value, closed };

pub const Event = struct {
    kind: EventKind,
    client: *Client,
    /// value: the attribute, and its value.
    handle: u16 = 0,
    data: []const u8 = &.{},
    /// closed: why - BTERR_* or the link's reason.
    result: i32 = 0,
};

// --- the records ------------------------------------------------------------------

pub fn byOwner(layer: *Hci, owner: *const anyopaque) ?*Client {
    for (&layer.att_clients) |*one| {
        if (one.state != .free and one.owner == owner) return one;
    }
    return null;
}

pub fn bySerial(layer: *Hci, serial: u32) ?*Client {
    if (serial == 0) return null;
    for (&layer.att_clients) |*one| {
        if (one.state != .free and one.serial == serial) return one;
    }
    return null;
}

/// The procedure numbered `serial`; null for none.
pub fn procedureOf(layer: *Hci, serial: u32) ?*Procedure {
    if (serial == 0) return null;
    for (&layer.att_procedures) |*one| {
        if (one.stage != .free and one.serial == serial) return one;
    }
    return null;
}

/// The task has read the procedure's end: its record freed.
pub fn release(layer: *Hci, serial: u32) void {
    const one = procedureOf(layer, serial) orelse return;
    if (one.stage == .done) one.* = .{};
}

/// Whether a block, or a procedure, is on or waits for the link to
/// `address`.
pub fn uses(layer: *const Hci, address: bluetooth.BTAddress) bool {
    for (&layer.att_clients) |*one| {
        if ((one.state == .opening or one.state == .open) and sameAddress(one.address, address)) return true;
    }
    for (&layer.att_procedures) |*one| {
        if ((one.stage == .queued or one.stage == .running) and sameAddress(one.address, address)) return true;
    }
    return false;
}

fn freeProcedure(layer: *Hci) ?*Procedure {
    for (&layer.att_procedures) |*one| {
        if (one.stage == .free) return one;
    }
    return null;
}

fn freeClient(layer: *Hci) ?*Client {
    for (&layer.att_clients) |*one| {
        if (one.state == .free) return one;
    }
    return null;
}

fn placeOf(layer: *const Hci, procedure: *const Procedure) u8 {
    return @intCast((@intFromPtr(procedure) - @intFromPtr(&layer.att_procedures)) / @sizeOf(Procedure));
}

fn newSerial(layer: *Hci) u32 {
    layer.att_serial +%= 1;
    if (layer.att_serial == 0) layer.att_serial = 1;
    return layer.att_serial;
}

/// Whether a procedure with a call can be asked for: one is free, and a
/// wait.
fn canQueue(layer: *Hci) bool {
    return freeProcedure(layer) != null and connections.canWait(layer);
}

// --- the calls ----------------------------------------------------------------------

/// OpenBTGatt: a block begun for the device at `address`, an LE address -
/// the call's wait, or why not at once.
pub fn open(layer: *Hci, address: bluetooth.BTAddress) connections.Begun {
    if (address.kind == bluetooth.BTADDR_BREDR) return .{ .done = bluetooth.BTERR_UNSUPPORTED };
    if (!canQueue(layer)) return .{ .done = bluetooth.BTERR_NOMEM };
    const slot = freeClient(layer) orelse return .{ .done = bluetooth.BTERR_NOMEM };
    const linked = linkFor(layer, address);
    if (linked != 0) return .{ .done = linked };
    const serial = newSerial(layer);
    slot.* = .{ .state = .opening, .address = address, .serial = serial };
    return queue(layer, .{ .kind = .open, .address = address, .serial = serial });
}

/// ObtainBTServices over LE: the primary services of the device at
/// `address` into `into` - the call's wait, or why not at once.
pub fn services(layer: *Hci, address: bluetooth.BTAddress, into: []u8) connections.Begun {
    if (!canQueue(layer)) return .{ .done = bluetooth.BTERR_NOMEM };
    const linked = linkFor(layer, address);
    if (linked != 0) return .{ .done = linked };
    return queue(layer, .{ .kind = .services, .address = address, .serial = newSerial(layer), .start = 1, .end = 0xFFFF, .next = 1, .into = into });
}

/// ObtainBTCharacteristics: the characteristics of the service from
/// `start` to `end` on the block's link, into `into`.
pub fn characteristics(layer: *Hci, one: *const Client, start: u16, end: u16, into: []u8) connections.Begun {
    if (one.state != .open) return .{ .done = bluetooth.BTERR_NOTCONNECTED };
    if (start == 0 or start > end or into.len < CHARACTERISTICS_HEAD) return .{ .done = bluetooth.BTERR_UNSUPPORTED };
    if (!canQueue(layer)) return .{ .done = bluetooth.BTERR_NOMEM };
    @memset(into[0..CHARACTERISTICS_HEAD], 0);
    return queue(layer, .{ .kind = .characteristics, .address = one.address, .serial = newSerial(layer), .start = start, .end = end, .next = start, .into = into, .have = CHARACTERISTICS_HEAD });
}

/// ReadBTAttribute: the value of the attribute `handle` into `into`.
pub fn read(layer: *Hci, one: *const Client, handle: u16, into: []u8) connections.Begun {
    if (one.state != .open) return .{ .done = bluetooth.BTERR_NOTCONNECTED };
    if (!canQueue(layer)) return .{ .done = bluetooth.BTERR_NOMEM };
    return queue(layer, .{ .kind = .read, .address = one.address, .serial = newSerial(layer), .start = handle, .into = into });
}

/// WriteBTAttribute: `value` written to the attribute `handle` - by a
/// Write Command, `command`, else by a Write Request.
pub fn write(layer: *Hci, one: *const Client, handle: u16, value: []const u8, command: bool) connections.Begun {
    if (one.state != .open) return .{ .done = bluetooth.BTERR_NOTCONNECTED };
    if (value.len > att.ATT_VALUE_MOST) return .{ .done = bluetooth.BTERR_TOOLONG };
    if (!canQueue(layer)) return .{ .done = bluetooth.BTERR_NOMEM };
    return queue(layer, .{ .kind = if (command) .write_command else .write, .address = one.address, .serial = newSerial(layer), .start = handle, .value = value });
}

/// SubscribeBTAttribute: the value at `value` sent to the block - notified,
/// or indicated - its configuration at `configuration` written.
pub fn subscribe(layer: *Hci, one: *Client, value: u16, configuration: u16, indicate: bool) connections.Begun {
    if (one.state != .open) return .{ .done = bluetooth.BTERR_NOTCONNECTED };
    if (value == 0 or configuration == 0) return .{ .done = bluetooth.BTERR_UNSUPPORTED };
    if (!canQueue(layer)) return .{ .done = bluetooth.BTERR_NOMEM };
    const slot = subscriptionOf(one, value) orelse subscriptionOf(one, 0) orelse return .{ .done = bluetooth.BTERR_NOMEM };
    slot.* = .{ .value = value, .configuration = configuration, .bits = if (indicate) att.GATT_CCC_INDICATE else att.GATT_CCC_NOTIFY };
    return queue(layer, .{ .kind = .configure, .address = one.address, .serial = newSerial(layer), .start = value, .configuration = configuration, .client = one.serial });
}

/// UnsubscribeBTAttribute: the value at `value` no longer sent to the
/// block, its configuration written with what the others want.
pub fn unsubscribe(layer: *Hci, one: *Client, value: u16) connections.Begun {
    if (one.state != .open) return .{ .done = bluetooth.BTERR_NOTCONNECTED };
    const slot = subscriptionOf(one, value) orelse return .{ .done = 0 };
    if (!canQueue(layer)) return .{ .done = bluetooth.BTERR_NOMEM };
    const configuration = slot.configuration;
    slot.* = .{};
    return queue(layer, .{ .kind = .configure, .address = one.address, .serial = newSerial(layer), .start = value, .configuration = configuration });
}

/// CloseBTGatt: the block freed, the device told of each value only this
/// block wanted - written without a call, while the link is up - and the
/// link, where it was made for it, ended once nothing else is on it.
pub fn close(layer: *Hci, one: *Client) void {
    const address = one.address;
    const was_open = one.state == .open;
    const kept = one.subscriptions;
    one.* = .{};
    if (was_open) {
        for (kept) |subscription| {
            if (subscription.value == 0) continue;
            if (subscription.bits & ~wanted(layer, address, subscription.value) == 0) continue;
            _ = queue(layer, .{ .kind = .configure, .address = address, .start = subscription.value, .configuration = subscription.configuration });
        }
    }
    if (!uses(layer, address)) connections.idle(layer, address);
}

fn subscriptionOf(one: *Client, value: u16) ?*Subscription {
    for (&one.subscriptions) |*subscription| {
        if (subscription.value == value) return subscription;
    }
    return null;
}

/// What the open blocks on the link to `address` want of the value at
/// `value`: their att.GATT_CCC_* together.
fn wanted(layer: *const Hci, address: bluetooth.BTAddress, value: u16) u16 {
    var bits: u16 = 0;
    for (&layer.att_clients) |*one| {
        if (one.state != .open or !sameAddress(one.address, address)) continue;
        for (&one.subscriptions) |*subscription| {
            if (subscription.value == value) bits |= subscription.bits;
        }
    }
    return bits;
}

/// The link to `address` there for procedures - one up or being made, or
/// one made for them, as a link for channels: 0, or why not.
fn linkFor(layer: *Hci, address: bluetooth.BTAddress) i32 {
    if (layer.state != bluetooth.BTCS_UP) return bluetooth.BTERR_NOTUP;
    if (!layer.powered) return bluetooth.BTERR_OFF;
    if (connections.find(layer, address)) |connection| {
        return switch (connection.state) {
            .up, .connecting => if (connection.att.dead) bluetooth.BTERR_TIMEOUT else 0,
            .disconnecting, .free => bluetooth.BTERR_BUSY,
        };
    }
    const result = connections.make(layer, address);
    if (result != 0) return result;
    connections.find(layer, address).?.for_channels = true;
    return 0;
}

/// A procedure put on its link's queue, run at once where the link is
/// ready: its call's wait - or, without one, done.
fn queue(layer: *Hci, made: Procedure) connections.Begun {
    const slot = freeProcedure(layer) orelse return .{ .done = bluetooth.BTERR_NOMEM };
    var begun: connections.Begun = .{ .done = 0 };
    if (made.serial != 0) {
        begun = connections.waitForSerial(layer, .gatt, made.serial);
        if (begun == .done) return begun;
    }
    layer.att_order += 1;
    slot.* = made;
    slot.stage = .queued;
    slot.order = layer.att_order;
    if (connections.find(layer, made.address)) |connection| pump(layer, connection);
    return begun;
}

// --- running them ---------------------------------------------------------------------

/// A link up and heard, or made secure with its bond - or not: its
/// procedures run.
pub fn linkUp(layer: *Hci, connection: *Connection) void {
    pump(layer, connection);
}

/// The link's next procedure run - its MTU exchanged first - while it is
/// ready and nothing is asked on it.
pub fn pump(layer: *Hci, connection: *Connection) void {
    if (!connection.le or connection.state != .up or !connection.heard or connections.securing(connection)) return;
    const bearer = &connection.att;
    while (!bearer.dead and bearer.asked == 0 and bearer.running == null) {
        const procedure = nextQueued(layer, connection.address) orelse return;
        if (!bearer.exchanged) return exchange(layer, connection);
        procedure.stage = .running;
        bearer.running = placeOf(layer, procedure);
        begin(layer, connection, procedure);
    }
}

/// The link's procedure asked for first that waits.
fn nextQueued(layer: *Hci, address: bluetooth.BTAddress) ?*Procedure {
    var first: ?*Procedure = null;
    for (&layer.att_procedures) |*one| {
        if (one.stage != .queued or !sameAddress(one.address, address)) continue;
        if (first == null or one.order < first.?.order) first = one;
    }
    return first;
}

/// This machine's Exchange MTU sent - or, with no room for it, the
/// procedures run at the default.
fn exchange(layer: *Hci, connection: *Connection) void {
    var request: [3]u8 = .{ att.ATT_EXCHANGE_MTU_REQ, 0, 0 };
    put16(request[1..3], _att.MTU_OURS);
    if (!_att.send(layer, connection, &request)) {
        connection.att.exchanged = true;
        return pump(layer, connection);
    }
    connection.att.asked = att.ATT_EXCHANGE_MTU_REQ;
    connection.att.deadline = layer.now + _att.TRANSACTION_MS;
}

/// A procedure's first request sent - or, for one that asks nothing,
/// its end.
fn begin(layer: *Hci, connection: *Connection, procedure: *Procedure) void {
    switch (procedure.kind) {
        .open => finish(layer, procedure, 0),
        .services => askRange(layer, connection, procedure, att.ATT_READ_BY_GROUP_TYPE_REQ, procedure.start, procedure.end, att.GATT_PRIMARY_SERVICE),
        .characteristics => askRange(layer, connection, procedure, att.ATT_READ_BY_TYPE_REQ, procedure.start, procedure.end, att.GATT_CHARACTERISTIC),
        .read => {
            var request: [3]u8 = .{ att.ATT_READ_REQ, 0, 0 };
            put16(request[1..3], procedure.start);
            ask(layer, connection, procedure, &request);
        },
        .write, .write_command => {
            if (procedure.value.len > connection.att.mtu - 3) return finish(layer, procedure, bluetooth.BTERR_TOOLONG);
            const request = layer.att_pdu[0 .. 3 + procedure.value.len];
            request[0] = if (procedure.kind == .write) att.ATT_WRITE_REQ else att.ATT_WRITE_CMD;
            put16(request[1..3], procedure.start);
            @memcpy(request[3..], procedure.value);
            if (procedure.kind == .write) return ask(layer, connection, procedure, request);
            finish(layer, procedure, if (_att.send(layer, connection, request)) 0 else bluetooth.BTERR_NOMEM);
        },
        .configure => {
            var request: [5]u8 = .{ att.ATT_WRITE_REQ, 0, 0, 0, 0 };
            put16(request[1..3], procedure.configuration);
            put16(request[3..5], wanted(layer, procedure.address, procedure.start));
            ask(layer, connection, procedure, &request);
        },
    }
}

/// A request of the running procedure sent, its answer waited for - or,
/// with no room for it, the procedure over.
fn ask(layer: *Hci, connection: *Connection, procedure: *Procedure, request: []const u8) void {
    if (!_att.send(layer, connection, request)) return finish(layer, procedure, bluetooth.BTERR_NOMEM);
    connection.att.asked = request[0];
    connection.att.deadline = layer.now + _att.TRANSACTION_MS;
}

/// A request over the handles from `from` to `to`, of `type16` where it
/// names one.
fn askRange(layer: *Hci, connection: *Connection, procedure: *Procedure, opcode: u8, from: u16, to: u16, type16: ?u16) void {
    var request: [7]u8 = undefined;
    request[0] = opcode;
    put16(request[1..3], from);
    put16(request[3..5], to);
    var length: usize = 5;
    if (type16) |named| {
        put16(request[5..7], named);
        length = 7;
    }
    ask(layer, connection, procedure, request[0..length]);
}

/// An answer of the device's server, to the request out on the link -
/// anything else let go: the request's procedure taken on, and the next
/// run.
pub fn answered(layer: *Hci, connection: *Connection, pdu: []const u8) void {
    const bearer = &connection.att;
    const asked = bearer.asked;
    if (asked == 0) return;
    const refused = pdu[0] == att.ATT_ERROR_RSP;
    if (refused) {
        if (pdu.len != 5 or pdu[1] != asked) return;
    } else if (pdu[0] != asked + 1) return;
    bearer.asked = 0;
    bearer.deadline = null;
    if (asked == att.ATT_EXCHANGE_MTU_REQ) {
        bearer.exchanged = true;
        if (!refused and pdu.len == 3) bearer.mtu = _att.agreed(le16(pdu[1..3]));
    } else if (bearer.running) |place| {
        const procedure = &layer.att_procedures[place];
        if (refused) refusal(layer, connection, procedure, asked, pdu[4]) else step(layer, connection, procedure, pdu);
    }
    pump(layer, connection);
}

/// The device refused the procedure's request `asked` for `code`: its end
/// - or where the refusal ends what was asked for, what follows it.
fn refusal(layer: *Hci, connection: *Connection, procedure: *Procedure, asked: u8, code: u8) void {
    const not_found = code == att.ATT_ERR_ATTRIBUTE_NOT_FOUND;
    switch (procedure.kind) {
        .services => if (not_found) return finish(layer, procedure, 0),
        .characteristics => if (not_found) {
            if (!procedure.finding) return startDescriptors(layer, connection, procedure);
            nextCharacteristic(procedure);
            return askDescriptors(layer, connection, procedure);
        },
        .read => if (asked == att.ATT_READ_BLOB_REQ and (code == att.ATT_ERR_ATTRIBUTE_NOT_LONG or code == att.ATT_ERR_INVALID_OFFSET)) {
            return finish(layer, procedure, 0);
        },
        else => {},
    }
    finish(layer, procedure, bluetooth.BTERR_ATT - @as(i32, code));
}

/// The answer to the running procedure's request taken on.
fn step(layer: *Hci, connection: *Connection, procedure: *Procedure, pdu: []const u8) void {
    switch (procedure.kind) {
        .services => groupsAnswered(layer, connection, procedure, pdu),
        .characteristics => if (procedure.finding) descriptorsAnswered(layer, connection, procedure, pdu) else declarationsAnswered(layer, connection, procedure, pdu),
        .read => partAnswered(layer, connection, procedure, pdu),
        .write, .configure => finish(layer, procedure, 0),
        .open, .write_command => {},
    }
}

/// The entries of an answer that lists them, `each` bytes long: null for
/// an answer that is not well made.
fn entriesOf(pdu: []const u8, each: usize) ?[]const u8 {
    const entries = pdu[2..];
    if (entries.len == 0 or entries.len % each != 0) return null;
    return entries;
}

/// Read By Group Type's answer: its services in the room, the rest of the
/// handles asked for.
fn groupsAnswered(layer: *Hci, connection: *Connection, procedure: *Procedure, pdu: []const u8) void {
    if (pdu.len < 2 or (pdu[1] != 6 and pdu[1] != 20)) return finish(layer, procedure, bluetooth.BTERR_PROTOCOL);
    const each: usize = pdu[1];
    const entries = entriesOf(pdu, each) orelse return finish(layer, procedure, bluetooth.BTERR_PROTOCOL);
    var floor: u32 = procedure.next;
    var at: usize = 0;
    while (at < entries.len) : (at += each) {
        const entry = entries[at..][0..each];
        const start = le16(entry[0..2]);
        const end = le16(entry[2..4]);
        // Rising, so that the next request starts past them.
        if (start < floor or end < start) return finish(layer, procedure, bluetooth.BTERR_PROTOCOL);
        if (procedure.into.len - procedure.have < @sizeOf(ServiceRecord)) return finish(layer, procedure, bluetooth.BTERR_NOMEM);
        const record: *align(1) ServiceRecord = @ptrCast(procedure.into[procedure.have..].ptr);
        record.* = .{ .start = start, .end = end, .uuid = _att.uuidOf(entry[4..]) };
        procedure.have += @sizeOf(ServiceRecord);
        floor = @as(u32, end) + 1;
    }
    if (floor > procedure.end) return finish(layer, procedure, 0);
    procedure.next = floor;
    askRange(layer, connection, procedure, att.ATT_READ_BY_GROUP_TYPE_REQ, @intCast(floor), procedure.end, att.GATT_PRIMARY_SERVICE);
}

fn countOf(procedure: *const Procedure) *align(1) u16 {
    return @ptrCast(procedure.into.ptr);
}

fn characteristicAt(procedure: *const Procedure, index: usize) *align(1) CharacteristicRecord {
    return @ptrCast(procedure.into[CHARACTERISTICS_HEAD + index * @sizeOf(CharacteristicRecord) ..].ptr);
}

/// Read By Type's answer of characteristic declarations: each in the
/// room, the rest of the service asked for - or its descriptors, once its
/// last is in.
fn declarationsAnswered(layer: *Hci, connection: *Connection, procedure: *Procedure, pdu: []const u8) void {
    if (pdu.len < 2 or (pdu[1] != 7 and pdu[1] != 21)) return finish(layer, procedure, bluetooth.BTERR_PROTOCOL);
    const each: usize = pdu[1];
    const entries = entriesOf(pdu, each) orelse return finish(layer, procedure, bluetooth.BTERR_PROTOCOL);
    var floor: u32 = procedure.next;
    var at: usize = 0;
    while (at < entries.len) : (at += each) {
        const entry = entries[at..][0..each];
        const handle = le16(entry[0..2]);
        const value = le16(entry[3..5]);
        if (handle < floor or handle > procedure.end or value <= handle or value > procedure.end) return finish(layer, procedure, bluetooth.BTERR_PROTOCOL);
        if (procedure.into.len - procedure.have < @sizeOf(CharacteristicRecord)) return finish(layer, procedure, bluetooth.BTERR_NOMEM);
        const record: *align(1) CharacteristicRecord = @ptrCast(procedure.into[procedure.have..].ptr);
        record.* = .{
            .handle = handle,
            .value = value,
            .end = procedure.end,
            .properties = entry[2],
            .first_descriptor = 0,
            .descriptor_count = 0,
            .uuid = _att.uuidOf(entry[5..]),
        };
        procedure.have += @sizeOf(CharacteristicRecord);
        countOf(procedure).* += 1;
        // A value is no declaration: the next one is past it.
        floor = @as(u32, value) + 1;
    }
    if (floor > procedure.end) return startDescriptors(layer, connection, procedure);
    procedure.next = floor;
    askRange(layer, connection, procedure, att.ATT_READ_BY_TYPE_REQ, @intCast(floor), procedure.end, att.GATT_CHARACTERISTIC);
}

/// The characteristics all in: each one's last handle - the next one's
/// declaration less one, the service's last for the last - and the
/// descriptors of the first asked for.
fn startDescriptors(layer: *Hci, connection: *Connection, procedure: *Procedure) void {
    const count = countOf(procedure).*;
    for (0..count) |index| {
        const record = characteristicAt(procedure, index);
        record.end = if (index + 1 < count) characteristicAt(procedure, index + 1).handle - 1 else procedure.end;
    }
    procedure.finding = true;
    procedure.at = 0;
    procedure.next = 0;
    askDescriptors(layer, connection, procedure);
}

/// Find Information over the handles of the characteristic at
/// `procedure.at` not yet asked for - past its value, then past the last
/// found - those of the next where it has none left; the procedure over
/// after the last.
fn askDescriptors(layer: *Hci, connection: *Connection, procedure: *Procedure) void {
    const count = countOf(procedure).*;
    while (procedure.at < count) : (nextCharacteristic(procedure)) {
        const record = characteristicAt(procedure, procedure.at);
        if (procedure.next == 0) {
            record.first_descriptor = procedure.descriptors;
            procedure.next = @as(u32, record.value) + 1;
        }
        if (procedure.next <= record.end) {
            return askRange(layer, connection, procedure, att.ATT_FIND_INFORMATION_REQ, @intCast(procedure.next), record.end, null);
        }
    }
    finish(layer, procedure, 0);
}

fn nextCharacteristic(procedure: *Procedure) void {
    procedure.at += 1;
    procedure.next = 0;
}

/// Find Information's answer: the descriptors in the room, the rest of
/// the characteristic's handles asked for.
fn descriptorsAnswered(layer: *Hci, connection: *Connection, procedure: *Procedure, pdu: []const u8) void {
    if (pdu.len < 2) return finish(layer, procedure, bluetooth.BTERR_PROTOCOL);
    const each: usize = switch (pdu[1]) {
        att.ATT_FORMAT_UUID16 => 4,
        att.ATT_FORMAT_UUID128 => 18,
        else => return finish(layer, procedure, bluetooth.BTERR_PROTOCOL),
    };
    const entries = entriesOf(pdu, each) orelse return finish(layer, procedure, bluetooth.BTERR_PROTOCOL);
    const record = characteristicAt(procedure, procedure.at);
    var floor: u32 = procedure.next;
    var at: usize = 0;
    while (at < entries.len) : (at += each) {
        const entry = entries[at..][0..each];
        const handle = le16(entry[0..2]);
        if (handle < floor or handle > record.end) return finish(layer, procedure, bluetooth.BTERR_PROTOCOL);
        if (procedure.into.len - procedure.have < @sizeOf(DescriptorRecord)) return finish(layer, procedure, bluetooth.BTERR_NOMEM);
        const descriptor: *align(1) DescriptorRecord = @ptrCast(procedure.into[procedure.have..].ptr);
        descriptor.* = .{ .handle = handle, .uuid = _att.uuidOf(entry[2..]) };
        procedure.have += @sizeOf(DescriptorRecord);
        procedure.descriptors += 1;
        record.descriptor_count += 1;
        floor = @as(u32, handle) + 1;
    }
    procedure.next = floor;
    if (floor > record.end) nextCharacteristic(procedure);
    askDescriptors(layer, connection, procedure);
}

/// Read's or Read Blob's answer: its part of the value in the room - and,
/// where it filled its PDU and the room has more, the next part asked
/// for.
fn partAnswered(layer: *Hci, connection: *Connection, procedure: *Procedure, pdu: []const u8) void {
    const part = pdu[1..];
    const taken = @min(part.len, procedure.into.len - procedure.have);
    @memcpy(procedure.into[procedure.have..][0..taken], part[0..taken]);
    procedure.have += taken;
    if (part.len == connection.att.mtu - 1 and procedure.have < procedure.into.len and procedure.have <= 0xFFFF) {
        var request: [5]u8 = .{ att.ATT_READ_BLOB_REQ, 0, 0, 0, 0 };
        put16(request[1..3], procedure.start);
        put16(request[3..5], @intCast(procedure.have));
        return ask(layer, connection, procedure, &request);
    }
    finish(layer, procedure, 0);
}

/// The procedure over with `result`: its link free for the next; its
/// call answered and its end kept for the task - or, without a call, its
/// record freed; an open's block open, or gone; a refused subscription
/// taken back; the link, made for procedures, ended once nothing is on
/// it.
fn finish(layer: *Hci, procedure: *Procedure, result: i32) void {
    const place = placeOf(layer, procedure);
    if (connections.find(layer, procedure.address)) |connection| {
        if (connection.att.running == place) connection.att.running = null;
    }
    switch (procedure.kind) {
        .open => if (bySerial(layer, procedure.serial)) |opening| {
            if (result == 0) opening.state = .open else opening.* = .{};
        },
        .configure => if (result != 0 and procedure.client != 0) {
            if (bySerial(layer, procedure.client)) |asking| {
                if (subscriptionOf(asking, procedure.start)) |subscription| subscription.* = .{};
            }
        },
        else => {},
    }
    const address = procedure.address;
    if (procedure.serial == 0) {
        procedure.* = .{};
    } else {
        procedure.stage = .done;
        procedure.result = result;
        connections.answerSerial(layer, .gatt, procedure.serial, result);
    }
    if (!uses(layer, address)) connections.idle(layer, address);
}

// --- what comes, and the ends -----------------------------------------------------------

/// A notification or an indication of the device's: its value to every
/// open block on the link subscribed to it.
pub fn notified(layer: *Hci, connection: *const Connection, pdu: []const u8) void {
    if (pdu.len < 3) return;
    const handle = le16(pdu[1..3]);
    const tell = layer.port.gatt orelse return;
    for (&layer.att_clients) |*one| {
        if (one.state != .open or !sameAddress(one.address, connection.address)) continue;
        if (subscriptionOf(one, handle) == null) continue;
        tell(layer.port.context, &.{ .kind = .value, .client = one, .handle = handle, .data = pdu[3..] });
    }
}

/// A link not made, or down: its procedures over, its blocks closed,
/// `reason` why.
pub fn linkGone(layer: *Hci, connection: *const Connection, reason: i32) void {
    if (!connection.le) return;
    endOn(layer, connection.address, if (reason == 0) bluetooth.BTERR_NOTCONNECTED else reason);
}

/// Every link forgotten - the controller brought up again, or gone: every
/// procedure over and every block closed, `result` why.
pub fn reset(layer: *Hci, result: i32) void {
    for (&layer.att_procedures) |*one| {
        if (one.stage == .queued or one.stage == .running) finish(layer, one, result);
    }
    for (&layer.att_clients) |*one| {
        if (one.state == .open) closeClient(layer, one, result);
    }
}

/// The procedures on the link to `address` over, and its blocks closed,
/// for `result`.
fn endOn(layer: *Hci, address: bluetooth.BTAddress, result: i32) void {
    for (&layer.att_procedures) |*one| {
        if ((one.stage == .queued or one.stage == .running) and sameAddress(one.address, address)) finish(layer, one, result);
    }
    for (&layer.att_clients) |*one| {
        if (one.state == .open and sameAddress(one.address, address)) closeClient(layer, one, result);
    }
}

/// A block closed, and the task told why.
fn closeClient(layer: *Hci, one: *Client, result: i32) void {
    one.state = .closed;
    if (layer.port.gatt) |tell| tell(layer.port.context, &.{ .kind = .closed, .client = one, .result = result });
}

/// A request not answered in its time: its bearer dead - nothing more
/// sent on it or taken from it - its procedures over and its blocks
/// closed, BTERR_TIMEOUT.
pub fn tick(layer: *Hci) void {
    for (&layer.connections) |*connection| {
        const due = connection.att.deadline orelse continue;
        if (layer.now < due) continue;
        connection.att.deadline = null;
        connection.att.asked = 0;
        connection.att.dead = true;
        endOn(layer, connection.address, bluetooth.BTERR_TIMEOUT);
    }
}

/// The earliest a request out is given up; null for none.
pub fn deadline(layer: *const Hci) ?u64 {
    var earliest: ?u64 = null;
    for (&layer.connections) |*connection| {
        const due = connection.att.deadline orelse continue;
        if (earliest == null or due < earliest.?) earliest = due;
    }
    return earliest;
}
