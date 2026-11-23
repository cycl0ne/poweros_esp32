// SPDX-License-Identifier: MIT
//! A controller's connections: a table in its HCI layer, a record a link
//! - the device's address, the controller's handle for it, who made it
//! and which side is its central, LE's parameters, the device's name -
//! from the moment a link is asked for or offered until the controller
//! says it is down.
//!
//! **Made by the library** (`connect`): a page over BR/EDR - Create
//! Connection, with what the discovery heard of the device, its page
//! scan repetition mode and clock offset, and a role switch allowed - or
//! LE's initiating to the one address (LE Create Connection). A
//! controller pages one device at a time and initiates to one: a second
//! link of the same kind asked for meanwhile is BTERR_BUSY. A discovery
//! that runs is stopped first: a controller that inquires pages slowly,
//! and one that scans may not initiate.
//!
//! **Made by the device**: a page the controller hears (Connection
//! Request) is taken on while the controller is on and the table has
//! room, the controller staying the link's peripheral (Accept
//! Connection Request); a synchronous link - sound - is refused.
//!
//! **Waited for.** A call that waits for the controller - a link up, a
//! link down - has a `Wait` here, which the task looks at after each
//! packet: once it is done, the call is answered with its result. Every
//! link being made or ended has a time by which it is: a page ends by
//! the controller's page timeout, LE's initiating - which waits for the
//! device to advertise as long as it takes - is taken back after
//! LE_CONNECT_TIMEOUT_MS (LE Create Connection Cancel), and a controller
//! that answers nothing by then has the link given up on (BTERR_TIMEOUT).
//!
//! **The device's name**, where the discovery did not hear it, is asked
//! for once a BR/EDR link is up (Remote Name Request): over the link it
//! comes at once.
//!
//! **Made secure.** A BR/EDR link the library makes to a device it has a
//! bond with is authenticated with the bond's key and encrypted before
//! the calls waiting for it are answered (pairing.zig), and a link a
//! pairing waits for begins it once it is up.
//!
//! **Ended** by DisconnectBTDevice, by the device, or by the controller's
//! power going off: Disconnection Complete frees the record and gives
//! back the controller's buffers its packets held (acl.zig).
//!
//! **Noted.** A link up, not made or down - and a pairing over - leaves
//! a Note in the layer - the device, the handle, the controller's reason
//! - which the task says in the log and clears; NOTES of them wait at
//! most, and more are let go.
//!
//! Pure, as the rest of the layer.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const _hci = @import("_hci.zig");
const Hci = _hci.Hci;
const acl = @import("acl.zig");
const devices = @import("devices.zig");
const discovery = @import("discovery.zig");
const pairing = @import("pairing.zig");
const smp = @import("smp.zig");

/// How many links a controller keeps, and how many calls may wait on
/// them at once.
pub const CONNECTIONS = 8;
pub const WAITS = 8;

/// LE's initiating given up on after this long: a device that does not
/// advertise is never reached.
pub const LE_CONNECT_TIMEOUT_MS: u32 = 20_000;
/// How long a page is waited for - past the controller's own page
/// timeout, 5.12 s from its reset - and a page taken on, a link's end,
/// and the answer to a page or initiating taken back.
const PAGE_WAIT_MS: u32 = 15_000;
const ACCEPT_WAIT_MS: u32 = 10_000;
const DISCONNECT_WAIT_MS: u32 = 10_000;
const CANCEL_WAIT_MS: u32 = 3_000;
/// How old what the discovery heard of a device may be for a page to go
/// by it: a device's clock drifts from the offset heard.
const HEARD_FRESH_MS: u64 = 60_000;

pub const State = enum(u8) { free, connecting, up, disconnecting };

pub const Connection = struct {
    state: State = .free,
    handle: u16 = 0,
    address: bluetooth.BTAddress = .{},
    /// Over LE; made by the device; the controller its central.
    le: bool = false,
    incoming: bool = false,
    central: bool = false,
    encrypted: bool = false,
    /// The two have shown each other a link key: an authentication, or
    /// the encryption that follows one.
    authenticated: bool = false,
    /// Its pairing, or its being made secure (pairing.zig).
    pairing: pairing.Pairing = .{},
    /// Over LE, the security manager's part of its pairing (smp.zig).
    smp: smp.Smp = .{},
    /// Its making taken back at its time: it failed by BTERR_TIMEOUT.
    cancelled: bool = false,
    /// Ended as soon as it is up: DisconnectBTDevice, or the power going
    /// off, came while it was being made.
    unwanted: bool = false,
    class_of_device: u32 = 0,
    /// When it came up, and when what it waits for is given up on.
    since: u64 = 0,
    deadline: ?u64 = null,
    /// LE: its interval, latency and supervision time-out.
    interval: u16 = 0,
    latency: u16 = 0,
    supervision: u16 = 0,
    /// Its ACL packets the controller holds (acl.zig).
    outstanding: u16 = 0,
    /// The frame its packets put together, how much of it has come, and
    /// whether it is being let go.
    frame: [acl.FRAME_ROOM]u8 = undefined,
    frame_have: usize = 0,
    frame_dropping: bool = false,
    /// The device's name, UTF-8, ended by a NUL; empty while it is not
    /// known. Whether it has been asked for.
    name: [hci.HCI_MAX_NAME + 1]u8 = @splat(0),
    name_asked: bool = false,
};

pub const WaitKind = enum(u8) { connect, disconnect };

/// A call waiting for a link to `address` to be up, or down.
pub const Wait = struct {
    used: bool = false,
    kind: WaitKind = .connect,
    address: bluetooth.BTAddress = .{},
    done: bool = false,
    /// Once done: 0, BTERR_*, or the controller's status.
    result: i32 = 0,
};

/// What a call that may wait for the controller gets.
pub const Begun = union(enum) {
    /// Answered at once: 0, BTERR_*, or the controller's status.
    done: i32,
    /// Its wait, by its place in `layer.waits`.
    waiting: u8,
};

/// How many notes wait for the log.
pub const NOTES = 8;

pub const NoteKind = enum(u8) { up, not_made, down, paired, not_paired, not_secured };

/// What happened to a link, for the log.
pub const Note = struct {
    kind: NoteKind = .up,
    address: bluetooth.BTAddress = .{},
    handle: u16 = 0,
    le: bool = false,
    incoming: bool = false,
    /// Not made, down, not paired or not made secure: the controller's
    /// reason (hci.HCI_ERR_*), or BTERR_*.
    reason: i32 = 0,
};

/// Whether the controller can page, and initiate over LE.
pub fn canPage(layer: *const Hci) bool {
    return _hci.bredr(layer) and _hci.supports(layer, hci.CMDBIT_CREATE_CONNECTION) and layer.acl_packets != 0;
}

pub fn canInitiate(layer: *const Hci) bool {
    return _hci.le(layer) and _hci.supports(layer, hci.CMDBIT_LE_CREATE_CONNECTION) and layer.le_packets != 0;
}

/// The link to `address`, whatever its state; null for none.
pub fn find(layer: *Hci, address: bluetooth.BTAddress) ?*Connection {
    for (&layer.connections) |*connection| {
        if (connection.state != .free and sameAddress(connection.address, address)) return connection;
    }
    return null;
}

/// The link with this handle, up or being ended; null for none.
pub fn byHandle(layer: *Hci, handle: u16) ?*Connection {
    for (&layer.connections) |*connection| {
        if (connection.state != .up and connection.state != .disconnecting) continue;
        if (connection.handle == handle) return connection;
    }
    return null;
}

fn freeConnection(layer: *Hci) ?*Connection {
    for (&layer.connections) |*connection| {
        if (connection.state == .free) return connection;
    }
    return null;
}

/// The link the library is making over LE, or over BR/EDR.
fn making(layer: *Hci, le: bool) ?*Connection {
    for (&layer.connections) |*connection| {
        if (connection.state == .connecting and !connection.incoming and connection.le == le) return connection;
    }
    return null;
}

/// The oldest link being taken on, and the oldest being ended.
fn accepting(layer: *Hci) ?*Connection {
    for (&layer.connections) |*connection| {
        if (connection.state == .connecting and connection.incoming and !connection.le) return connection;
    }
    return null;
}

fn ending(layer: *Hci) ?*Connection {
    for (&layer.connections) |*connection| {
        if (connection.state == .disconnecting) return connection;
    }
    return null;
}

pub fn sameAddress(one: bluetooth.BTAddress, other: bluetooth.BTAddress) bool {
    if (one.kind != other.kind) return false;
    for (one.bytes, other.bytes) |mine, theirs| {
        if (mine != theirs) return false;
    }
    return true;
}

// --- the calls --------------------------------------------------------------------

/// A link to the device at `address` made: over LE for an LE address,
/// over BR/EDR for a BR/EDR one. One that is up answers 0 at once; one
/// being made is waited for with it.
pub fn connect(layer: *Hci, address: bluetooth.BTAddress) Begun {
    if (layer.state != bluetooth.BTCS_UP) return .{ .done = bluetooth.BTERR_NOTUP };
    if (!layer.powered) return .{ .done = bluetooth.BTERR_OFF };
    if (find(layer, address)) |known| switch (known.state) {
        // Up, unless it is being made secure.
        .up => return if (securing(known)) waitFor(layer, .connect, address) else .{ .done = 0 },
        .connecting => if (!known.unwanted) return waitFor(layer, .connect, address),
        else => {},
    };
    if (find(layer, address) != null) return .{ .done = bluetooth.BTERR_BUSY };
    const wait = freeWait(layer) orelse return .{ .done = bluetooth.BTERR_NOMEM };
    const result = make(layer, address);
    if (result != 0) return .{ .done = result };
    return waitOn(layer, wait, .connect, address);
}

/// A link to the device at `address` begun, none being there, and
/// nobody waiting for it: 0, or why not.
pub fn make(layer: *Hci, address: bluetooth.BTAddress) i32 {
    const le_link = address.kind != bluetooth.BTADDR_BREDR;
    if (find(layer, address) != null) return bluetooth.BTERR_BUSY;
    if (if (le_link) !canInitiate(layer) else !canPage(layer)) return bluetooth.BTERR_UNSUPPORTED;
    if (making(layer, le_link) != null) return bluetooth.BTERR_BUSY;
    const connection = freeConnection(layer) orelse return bluetooth.BTERR_NOMEM;
    // Room for the discovery's end and the link's command.
    if (_hci.QUEUE - layer.queue_count < 3) return bluetooth.BTERR_NOMEM;
    discovery.stop(layer);
    const heard = devices.find(layer, address.bytes, address.kind);
    const sent = if (le_link) initiate(layer, address) else page(layer, address, heard);
    if (!sent) return bluetooth.BTERR_NOMEM;
    connection.* = .{
        .state = .connecting,
        .address = address,
        .le = le_link,
        .central = true,
        .deadline = layer.now + (if (le_link) LE_CONNECT_TIMEOUT_MS else PAGE_WAIT_MS),
    };
    if (heard) |device| {
        connection.class_of_device = device.class_of_device;
        setName(connection, &device.name);
    }
    layer.changed = true;
    return 0;
}

/// Whether a link that is up is being made secure, which ConnectBTDevice
/// waits for.
fn securing(connection: *const Connection) bool {
    return connection.pairing.stage != .idle and connection.pairing.purpose == .secure;
}

/// The link to `address` ended: one being made taken back, or ended as
/// soon as it is up.
pub fn disconnect(layer: *Hci, address: bluetooth.BTAddress) Begun {
    if (layer.state != bluetooth.BTCS_UP) return .{ .done = bluetooth.BTERR_NOTUP };
    const connection = find(layer, address) orelse return .{ .done = bluetooth.BTERR_NOTCONNECTED };
    const wait = freeWait(layer) orelse return .{ .done = bluetooth.BTERR_NOMEM };
    switch (connection.state) {
        .connecting => drop(layer, connection),
        .up => if (!end(layer, connection, hci.HCI_ERR_REMOTE_USER_TERMINATED)) return .{ .done = bluetooth.BTERR_NOMEM },
        .disconnecting, .free => {},
    }
    return waitOn(layer, wait, .disconnect, address);
}

/// Every link ended - the controller's power goes off - those being made
/// taken back.
pub fn dropAll(layer: *Hci) void {
    for (&layer.connections) |*connection| close(layer, connection, hci.HCI_ERR_REMOTE_POWER_OFF);
}

/// A link ended, whatever its state: one up ended for `reason`, one being
/// made taken back.
pub fn close(layer: *Hci, connection: *Connection, reason: u8) void {
    switch (connection.state) {
        .up => _ = end(layer, connection, reason),
        .connecting => drop(layer, connection),
        .disconnecting, .free => {},
    }
}

/// A link being made no longer wanted: taken back if the library is
/// making it, ended once it is up either way.
fn drop(layer: *Hci, connection: *Connection) void {
    connection.unwanted = true;
    if (!connection.incoming and !connection.cancelled) cancel(layer, connection);
}

/// Every link forgotten - the controller is brought up again from its
/// reset, or given up on - and every call waiting answered `result`.
pub fn reset(layer: *Hci, result: i32) void {
    for (&layer.connections) |*connection| {
        pairing.linkGone(layer, connection, result);
        connection.* = .{};
    }
    for (&layer.waits) |*wait| {
        if (!wait.used or wait.done) continue;
        wait.done = true;
        wait.result = result;
    }
    acl.reset(layer);
}

fn freeWait(layer: *Hci) ?*Wait {
    for (&layer.waits) |*wait| {
        if (!wait.used) return wait;
    }
    return null;
}

fn waitOn(layer: *Hci, wait: *Wait, kind: WaitKind, address: bluetooth.BTAddress) Begun {
    wait.* = .{ .used = true, .kind = kind, .address = address };
    const index = (@intFromPtr(wait) - @intFromPtr(&layer.waits)) / @sizeOf(Wait);
    return .{ .waiting = @intCast(index) };
}

fn waitFor(layer: *Hci, kind: WaitKind, address: bluetooth.BTAddress) Begun {
    const wait = freeWait(layer) orelse return .{ .done = bluetooth.BTERR_NOMEM };
    return waitOn(layer, wait, kind, address);
}

/// Every call waiting for the link to `address` to be up - or down -
/// done, with `result`.
fn answer(layer: *Hci, kind: WaitKind, address: bluetooth.BTAddress, result: i32) void {
    for (&layer.waits) |*wait| {
        if (!wait.used or wait.done or wait.kind != kind or !sameAddress(wait.address, address)) continue;
        wait.done = true;
        wait.result = result;
    }
}

/// Every call waiting for the link to `address` to be up answered
/// `result`: the link made secure, or not.
pub fn answerConnect(layer: *Hci, address: bluetooth.BTAddress, result: i32) void {
    answer(layer, .connect, address, result);
}

/// A wait whose call the task has answered given back.
pub fn release(layer: *Hci, index: u8) void {
    layer.waits[index] = .{};
}

// --- the commands ---------------------------------------------------------------

/// Create Connection to `address`, by what the discovery heard of it -
/// recently - or for a device that listens for pages least often.
fn page(layer: *Hci, address: bluetooth.BTAddress, heard: ?*const devices.Device) bool {
    var repetition = hci.PAGE_SCAN_R2;
    var offset: u16 = 0;
    if (heard) |device| {
        if (device.flags & bluetooth.BTDF_BREDR != 0 and layer.now -| device.seen <= HEARD_FRESH_MS) {
            repetition = device.page_scan_repetition;
            offset = device.clock_offset | hci.CLOCK_OFFSET_VALID;
        }
    }
    var params: [13]u8 = undefined;
    params[0..6].* = address.bytes;
    params[6] = @truncate(hci.ACL_PACKET_TYPES);
    params[7] = @truncate(hci.ACL_PACKET_TYPES >> 8);
    params[8] = repetition;
    params[9] = 0;
    params[10] = @truncate(offset);
    params[11] = @truncate(offset >> 8);
    params[12] = if (_hci.feature(layer, 0, hci.LMP_ROLE_SWITCH)) hci.ALLOW_ROLE_SWITCH else 0;
    return _hci.command(layer, hci.HCI_OP_CREATE_CONNECTION, &params, _hci.COMMAND_TIMEOUT_MS);
}

/// LE Create Connection to `address`: scanning for it all the time, the
/// link's parameters this layer's.
fn initiate(layer: *Hci, address: bluetooth.BTAddress) bool {
    var params: [25]u8 = undefined;
    put16(params[0..2], hci.LE_CONNECT_SCAN_INTERVAL);
    put16(params[2..4], hci.LE_CONNECT_SCAN_WINDOW);
    params[4] = 0; // this address, not the filter accept list
    params[5] = if (address.kind == bluetooth.BTADDR_LE_PUBLIC) hci.LE_ADDR_PUBLIC else hci.LE_ADDR_RANDOM;
    params[6..12].* = address.bytes;
    params[12] = hci.LE_ADDR_PUBLIC; // its own address
    put16(params[13..15], hci.LE_CONNECT_INTERVAL_MIN);
    put16(params[15..17], hci.LE_CONNECT_INTERVAL_MAX);
    put16(params[17..19], hci.LE_CONNECT_LATENCY);
    put16(params[19..21], hci.LE_CONNECT_SUPERVISION);
    put16(params[21..23], 0);
    put16(params[23..25], 0);
    return _hci.command(layer, hci.HCI_OP_LE_CREATE_CONNECTION, &params, _hci.COMMAND_TIMEOUT_MS);
}

/// The link's making taken back: LE Create Connection Cancel, or Create
/// Connection Cancel where the controller has it - otherwise its page
/// timeout ends it. Its answer is waited for a while.
fn cancel(layer: *Hci, connection: *Connection) void {
    connection.cancelled = true;
    connection.deadline = layer.now + CANCEL_WAIT_MS;
    if (connection.le) {
        _ = _hci.command(layer, hci.HCI_OP_LE_CREATE_CONNECTION_CANCEL, &.{}, _hci.COMMAND_TIMEOUT_MS);
    } else if (_hci.supports(layer, hci.CMDBIT_CREATE_CONNECTION_CANCEL)) {
        _ = _hci.command(layer, hci.HCI_OP_CREATE_CONNECTION_CANCEL, &connection.address.bytes, _hci.COMMAND_TIMEOUT_MS);
    } else {
        connection.deadline = layer.now + PAGE_WAIT_MS;
    }
}

/// The link's end asked of the controller (Disconnect, `reason`): false
/// when the command could not be queued.
fn end(layer: *Hci, connection: *Connection, reason: u8) bool {
    const params = [_]u8{ @truncate(connection.handle), @truncate(connection.handle >> 8), reason };
    if (!_hci.command(layer, hci.HCI_OP_DISCONNECT, &params, _hci.COMMAND_TIMEOUT_MS)) return false;
    connection.state = .disconnecting;
    connection.deadline = layer.now + DISCONNECT_WAIT_MS;
    layer.changed = true;
    return true;
}

/// LE Connection Update: the link's parameters changed to these, as its
/// peripheral asked - false when the controller does not take it.
pub fn update(layer: *Hci, connection: *const Connection, min: u16, max: u16, latency: u16, timeout: u16) bool {
    if (!_hci.supports(layer, hci.CMDBIT_LE_CONNECTION_UPDATE)) return false;
    var params: [14]u8 = undefined;
    put16(params[0..2], connection.handle);
    put16(params[2..4], min);
    put16(params[4..6], max);
    put16(params[6..8], latency);
    put16(params[8..10], timeout);
    put16(params[10..12], 0);
    put16(params[12..14], 0);
    return _hci.command(layer, hci.HCI_OP_LE_CONNECTION_UPDATE, &params, _hci.COMMAND_TIMEOUT_MS);
}

/// Whether an LE link's parameters are within the specification's
/// bounds: an interval from 7.5 ms to 4 s, the shorter first; a
/// supervision time-out from 100 ms to 32 s, longer than the link may go
/// unheard - twice the longest interval for each event the peripheral
/// may let pass and one more; a latency of 499 events at most.
pub fn validParameters(min: u16, max: u16, latency: u16, timeout: u16) bool {
    if (min > max or min < 6 or max > 3200) return false;
    if (timeout < 10 or timeout > 3200 or latency > 499) return false;
    // timeout * 10 ms > (1 + latency) * max * 1.25 ms * 2
    return @as(u32, timeout) * 4 > (@as(u32, latency) + 1) * max;
}

/// Remote Name Request over the link that has come up, for a device
/// whose name the discovery did not hear.
fn askName(layer: *Hci, connection: *Connection) void {
    if (connection.le or connection.name_asked or connection.name[0] != 0) return;
    if (!_hci.supports(layer, hci.CMDBIT_REMOTE_NAME_REQUEST)) return;
    connection.name_asked = true;
    var params: [10]u8 = @splat(0);
    params[0..6].* = connection.address.bytes;
    params[6] = hci.PAGE_SCAN_R2;
    _ = _hci.command(layer, hci.HCI_OP_REMOTE_NAME_REQUEST, &params, _hci.COMMAND_TIMEOUT_MS);
}

fn setName(connection: *Connection, bytes: []const u8) void {
    var length: usize = 0;
    while (length < bytes.len and length < hci.HCI_MAX_NAME and bytes[length] != 0) length += 1;
    @memcpy(connection.name[0..length], bytes[0..length]);
    connection.name[length] = 0;
}

fn put16(into: *[2]u8, value: u16) void {
    into[0] = @truncate(value);
    into[1] = @truncate(value >> 8);
}

// --- the controller's word ------------------------------------------------------

/// A command's answer - its status alone when it was refused, or empty
/// when it was not answered in its time: a link it was to make or end
/// given up on, or left up.
pub fn answered(layer: *Hci, opcode: u16, returned: []const u8) void {
    const status: i32 = if (returned.len == 0) bluetooth.BTERR_TIMEOUT else returned[0];
    if (status == hci.HCI_SUCCESS) return;
    switch (opcode) {
        hci.HCI_OP_CREATE_CONNECTION => if (making(layer, false)) |connection| failed(layer, connection, status),
        hci.HCI_OP_LE_CREATE_CONNECTION => if (making(layer, true)) |connection| failed(layer, connection, status),
        hci.HCI_OP_ACCEPT_CONNECTION => if (accepting(layer)) |connection| failed(layer, connection, status),
        hci.HCI_OP_DISCONNECT => if (ending(layer)) |connection| {
            if (status == hci.HCI_ERR_UNKNOWN_CONNECTION) return down(layer, connection, 0, status);
            stays(layer, connection, status);
        },
        else => {},
    }
}

/// Connection Request: a device pages the controller. A link to it is
/// taken on - also while the library pages the same device, which the
/// controller sorts out - unless it is one for sound, the controller is
/// off, or the table is full.
pub fn request(layer: *Hci, params: []const u8) void {
    if (params.len < 10) return;
    const address = bluetooth.BTAddress{ .bytes = params[0..6].*, .kind = bluetooth.BTADDR_BREDR };
    const class = @as(u32, params[6]) | @as(u32, params[7]) << 8 | @as(u32, params[8]) << 16;
    const known = find(layer, address);
    const slot = if (known) |connection| (if (connection.state == .connecting) connection else null) else freeConnection(layer);
    if (params[9] != hci.LINK_ACL or !layer.powered or slot == null) {
        var refusal: [7]u8 = undefined;
        refusal[0..6].* = address.bytes;
        refusal[6] = hci.HCI_ERR_REJECTED_LIMITED_RESOURCES;
        _ = _hci.command(layer, hci.HCI_OP_REJECT_CONNECTION, &refusal, _hci.COMMAND_TIMEOUT_MS);
        return;
    }
    var acceptance: [7]u8 = undefined;
    acceptance[0..6].* = address.bytes;
    acceptance[6] = hci.ROLE_PERIPHERAL;
    if (!_hci.command(layer, hci.HCI_OP_ACCEPT_CONNECTION, &acceptance, _hci.COMMAND_TIMEOUT_MS)) return;
    if (known != null) return;
    const connection = slot.?;
    connection.* = .{
        .state = .connecting,
        .address = address,
        .incoming = true,
        .class_of_device = class,
        .deadline = layer.now + ACCEPT_WAIT_MS,
    };
    if (devices.find(layer, address.bytes, address.kind)) |device| setName(connection, &device.name);
    layer.changed = true;
}

/// Connection Complete: a BR/EDR link up, or not made. One the layer did
/// not ask for nor take on is taken all the same while there is room.
pub fn complete(layer: *Hci, params: []const u8) void {
    if (params.len < 11 or params[9] != hci.LINK_ACL) return;
    const status = params[0];
    const handle = _hci.le16(params[1..3]) & hci.ACL_HANDLE_MASK;
    const address = bluetooth.BTAddress{ .bytes = params[3..9].*, .kind = bluetooth.BTADDR_BREDR };
    var connection = find(layer, address);
    if (connection) |known| {
        if (known.state != .connecting) return;
    } else {
        if (status != hci.HCI_SUCCESS) return;
        connection = freeConnection(layer) orelse return refuseLink(layer, handle);
        connection.?.* = .{ .state = .connecting, .address = address, .incoming = true };
    }
    const made = connection.?;
    if (status != hci.HCI_SUCCESS) return failed(layer, made, failure(made, status));
    made.encrypted = params[10] != 0;
    // The pager is the central, until a role change says otherwise.
    made.central = !made.incoming;
    up(layer, made, handle);
    askName(layer, made);
}

/// LE Connection Complete, past its subevent: the LE link up, or not
/// made. A link the device made - to an advertiser, which the controller
/// is not - is taken all the same while there is room.
pub fn leComplete(layer: *Hci, params: []const u8) void {
    if (params.len < 18) return;
    const status = params[0];
    const handle = _hci.le16(params[1..3]) & hci.ACL_HANDLE_MASK;
    const role = params[3];
    const kind = switch (params[4]) {
        hci.LE_ADDR_PUBLIC, hci.LE_ADDR_PUBLIC_IDENTITY => bluetooth.BTADDR_LE_PUBLIC,
        else => bluetooth.BTADDR_LE_RANDOM,
    };
    const address = bluetooth.BTAddress{ .bytes = params[5..11].*, .kind = kind };
    if (status != hci.HCI_SUCCESS) {
        const made = making(layer, true) orelse return;
        return failed(layer, made, failure(made, status));
    }
    var connection = if (role == hci.ROLE_CENTRAL) making(layer, true) else null;
    if (connection == null) {
        connection = freeConnection(layer) orelse return refuseLink(layer, handle);
        connection.?.* = .{ .state = .connecting, .incoming = true };
    }
    const made = connection.?;
    made.address = address;
    made.le = true;
    made.central = role == hci.ROLE_CENTRAL;
    made.interval = _hci.le16(params[11..13]);
    made.latency = _hci.le16(params[13..15]);
    made.supervision = _hci.le16(params[15..17]);
    up(layer, made, handle);
}

/// What a call waiting for a link that was not made is answered: the
/// controller's status - or BTERR_TIMEOUT for one taken back at its
/// time, HCI_ERR_LOCAL_HOST_TERMINATED for one that was no longer wanted.
fn failure(connection: *const Connection, status: u8) i32 {
    if (connection.unwanted) return hci.HCI_ERR_LOCAL_HOST_TERMINATED;
    if (connection.cancelled) return bluetooth.BTERR_TIMEOUT;
    return status;
}

/// A link up that has no room in the table: ended at once.
fn refuseLink(layer: *Hci, handle: u16) void {
    const params = [_]u8{ @truncate(handle), @truncate(handle >> 8), hci.HCI_ERR_REMOTE_LOW_RESOURCES };
    _ = _hci.command(layer, hci.HCI_OP_DISCONNECT, &params, _hci.COMMAND_TIMEOUT_MS);
}

fn up(layer: *Hci, connection: *Connection, handle: u16) void {
    connection.state = .up;
    connection.handle = handle;
    connection.since = layer.now;
    connection.deadline = null;
    connection.frame_have = 0;
    connection.frame_dropping = false;
    connection.outstanding = 0;
    layer.changed = true;
    note(layer, connection, .up, 0);
    if (connection.unwanted) {
        answer(layer, .connect, connection.address, 0);
        if (!end(layer, connection, hci.HCI_ERR_REMOTE_USER_TERMINATED)) {
            connection.unwanted = false;
            answer(layer, .disconnect, connection.address, bluetooth.BTERR_NOMEM);
        }
        return;
    }
    // A pairing that waited for it begun; a bonded device's link made
    // secure before its callers are answered.
    if (!pairing.linkUp(layer, connection)) answer(layer, .connect, connection.address, 0);
}

/// What happened to a link kept for the log, while there is room.
pub fn note(layer: *Hci, connection: *const Connection, kind: NoteKind, reason: i32) void {
    if (layer.note_count == NOTES) return;
    layer.notes[layer.note_count] = .{
        .kind = kind,
        .address = connection.address,
        .handle = connection.handle,
        .le = connection.le,
        .incoming = connection.incoming,
        .reason = reason,
    };
    layer.note_count += 1;
}

/// A link that was not made: its record freed, the calls waiting for it
/// answered - those for its end that it is down.
fn failed(layer: *Hci, connection: *Connection, result: i32) void {
    note(layer, connection, .not_made, result);
    pairing.linkGone(layer, connection, result);
    const address = connection.address;
    connection.* = .{};
    layer.changed = true;
    answer(layer, .connect, address, result);
    answer(layer, .disconnect, address, 0);
}

/// A link that was up and is down, for `reason`: its buffers given back,
/// its record freed, the calls waiting for its end answered `result`.
fn down(layer: *Hci, connection: *Connection, result: i32, reason: i32) void {
    note(layer, connection, .down, reason);
    pairing.linkGone(layer, connection, reason);
    acl.released(layer, connection);
    const address = connection.address;
    connection.* = .{};
    layer.changed = true;
    answer(layer, .disconnect, address, result);
}

/// A link whose end the controller refused: up as it was, the calls
/// waiting for its end answered with why.
fn stays(layer: *Hci, connection: *Connection, status: i32) void {
    connection.state = .up;
    connection.deadline = null;
    connection.unwanted = false;
    layer.changed = true;
    answer(layer, .disconnect, connection.address, status);
}

/// Disconnection Complete: the link down - or, with a status, still up.
pub fn disconnectionComplete(layer: *Hci, params: []const u8) void {
    if (params.len < 4) return;
    const connection = byHandle(layer, _hci.le16(params[1..3]) & hci.ACL_HANDLE_MASK) orelse return;
    if (params[0] != hci.HCI_SUCCESS) return stays(layer, connection, params[0]);
    down(layer, connection, 0, params[3]);
}

/// Role Change: which side of a BR/EDR link is its central.
pub fn roleChange(layer: *Hci, params: []const u8) void {
    if (params.len < 8 or params[0] != hci.HCI_SUCCESS) return;
    const connection = find(layer, .{ .bytes = params[1..7].*, .kind = bluetooth.BTADDR_BREDR }) orelse return;
    connection.central = params[7] == hci.ROLE_CENTRAL;
    layer.changed = true;
}

/// Encryption Change: whether the link is encrypted - which it is only
/// once the two have authenticated - and a pairing waiting for it told.
pub fn encryptionChange(layer: *Hci, params: []const u8) void {
    if (params.len < 4) return;
    const connection = byHandle(layer, _hci.le16(params[1..3]) & hci.ACL_HANDLE_MASK) orelse return;
    if (params[0] == hci.HCI_SUCCESS) {
        connection.encrypted = params[3] != 0;
        if (connection.encrypted) connection.authenticated = true;
        layer.changed = true;
    }
    pairing.encryptionChanged(layer, connection, params[0]);
}

/// LE Connection Update Complete, past its subevent: the link's new
/// parameters.
pub fn leUpdateComplete(layer: *Hci, params: []const u8) void {
    if (params.len < 9 or params[0] != hci.HCI_SUCCESS) return;
    const connection = byHandle(layer, _hci.le16(params[1..3]) & hci.ACL_HANDLE_MASK) orelse return;
    connection.interval = _hci.le16(params[3..5]);
    connection.latency = _hci.le16(params[5..7]);
    connection.supervision = _hci.le16(params[7..9]);
    layer.changed = true;
}

/// LE Remote Connection Parameter Request, past its subevent: the
/// device's controller asks for other parameters - taken within the
/// specification's bounds, refused otherwise.
pub fn leParametersRequest(layer: *Hci, params: []const u8) void {
    if (params.len < 10) return;
    const handle = _hci.le16(params[0..2]) & hci.ACL_HANDLE_MASK;
    const min = _hci.le16(params[2..4]);
    const max = _hci.le16(params[4..6]);
    const latency = _hci.le16(params[6..8]);
    const timeout = _hci.le16(params[8..10]);
    if (!validParameters(min, max, latency, timeout)) {
        var refusal: [3]u8 = undefined;
        put16(refusal[0..2], handle);
        refusal[2] = hci.HCI_ERR_UNACCEPTABLE_PARAMETERS;
        _ = _hci.command(layer, hci.HCI_OP_LE_REMOTE_PARAMETERS_NEGATIVE_REPLY, &refusal, _hci.COMMAND_TIMEOUT_MS);
        return;
    }
    var reply: [14]u8 = undefined;
    put16(reply[0..2], handle);
    put16(reply[2..4], min);
    put16(reply[4..6], max);
    put16(reply[6..8], latency);
    put16(reply[8..10], timeout);
    put16(reply[10..12], 0);
    put16(reply[12..14], 0);
    _ = _hci.command(layer, hci.HCI_OP_LE_REMOTE_PARAMETERS_REPLY, &reply, _hci.COMMAND_TIMEOUT_MS);
}

/// Remote Name Request Complete: the name of a device a link is up to.
pub fn nameComplete(layer: *Hci, params: []const u8) void {
    if (params.len < 7 or params[0] != hci.HCI_SUCCESS) return;
    const connection = find(layer, .{ .bytes = params[1..7].*, .kind = bluetooth.BTADDR_BREDR }) orelse return;
    setName(connection, params[7..]);
    layer.changed = true;
}

// --- the time ---------------------------------------------------------------------

/// Whatever is due at `layer.now`: a link being made taken back, or
/// given up on once that was not answered; a link being ended taken to
/// be down.
pub fn tick(layer: *Hci) void {
    for (&layer.connections) |*connection| {
        const due = connection.deadline orelse continue;
        if (layer.now < due) continue;
        connection.deadline = null;
        switch (connection.state) {
            .connecting => {
                if (connection.incoming or connection.cancelled) {
                    failed(layer, connection, failure(connection, hci.HCI_ERR_CONNECTION_TIMEOUT));
                } else cancel(layer, connection);
            },
            .disconnecting => down(layer, connection, bluetooth.BTERR_TIMEOUT, bluetooth.BTERR_TIMEOUT),
            .up, .free => {},
        }
    }
}

/// The earliest a link's time is due; null for none.
pub fn deadline(layer: *const Hci) ?u64 {
    var earliest: ?u64 = null;
    for (&layer.connections) |*connection| {
        const due = connection.deadline orelse continue;
        if (earliest == null or due < earliest.?) earliest = due;
    }
    return earliest;
}

/// How many links are up.
pub fn count(layer: *const Hci) usize {
    var up_now: usize = 0;
    for (&layer.connections) |*connection| {
        if (connection.state == .up or connection.state == .disconnecting) up_now += 1;
    }
    return up_now;
}
