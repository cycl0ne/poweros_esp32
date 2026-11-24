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
//! LE's initiating to the one address (LE Create Connection), from the
//! controller's private address where the device's bond says it was given
//! the machine's identity, from its public one otherwise (privacy.zig).
//! A controller pages one device at a time and initiates to one: a second
//! link of the same kind asked for meanwhile is BTERR_BUSY. A discovery
//! that runs is stopped first: a controller that inquires pages slowly,
//! and one that scans may not initiate.
//!
//! **Listened for.** An LE link to a device whose bond keeps its identity
//! resolving key - which may advertise from a private address, a new one
//! now and then - is not initiated to the address it is asked for at: it
//! listens for the device's advertising first (`.listening`), by the
//! background scan (scan.zig), begun afresh so that a device it reported
//! already is reported again, and is initiated to the address the device
//! is heard at - the one asked for, or a private address the key made -
//! keeping the one asked for as its `identity`, the calls waiting for it
//! waiting at the address heard (`reached`). A link that listens
//! initiates nothing, so other links are made meanwhile, the scan pausing
//! for them; one whose device is not heard in LE_CONNECT_TIMEOUT_MS is
//! not made (BTERR_TIMEOUT), and one no longer wanted is let go of at
//! once.
//!
//! **Made by the device**: a page the controller hears (Connection
//! Request) is taken on while the controller is on and the table has
//! room, the controller staying the link's peripheral (Accept
//! Connection Request); a synchronous link - sound - is refused. Over
//! LE a device links to the controller while it advertises
//! (advertising.zig), the controller the link's peripheral; that ends
//! the advertising, which goes on beside the link where the controller
//! can.
//!
//! **Waited for.** A call that waits for the controller - a link up, a
//! link down - has a `Wait` here, which the task looks at after each
//! packet: once it is done, the call is answered with its result. Every
//! link being made or ended has a time by which it is: a page ends by
//! the controller's page timeout, LE's initiating - which waits for the
//! device to advertise as long as it takes - is taken back after
//! LE_CONNECT_TIMEOUT_MS (LE Create Connection Cancel), and a controller
//! that answers nothing by then has the link given up on (BTERR_TIMEOUT).
//! LE's advertising makes way for the initiating where the controller
//! cannot do both.
//!
//! **Made once the device has answered on it.** Over BR/EDR that is
//! Connection Complete. LE Connection Complete says only that the
//! controller has sent its request, so an LE link is up once the device
//! has answered on it: its features read (LE Read Remote Features), or
//! a frame of its come. One that goes down before then was not made, its
//! calls answered with the controller's reason -
//! HCI_ERR_FAILED_TO_ESTABLISH for a device never heard on it; a
//! controller that refuses the command, or a device that does not answer
//! it within FEATURES_WAIT_MS, has the link taken as made.
//!
//! **A link made for channels** - by a channel this machine opens, a
//! service query, or GATT's client (l2cap/channels.zig, sdp/client.zig,
//! att/client.zig), by the scan for a device a GATT block waits for
//! (scan.zig), or by a pairing that made no bond (pairing.zig) - ends
//! IDLE_MS after the last of its channels, GATT blocks and procedures
//! has ended, unless ConnectBTDevice asked for it meanwhile; a link
//! ConnectBTDevice made, or the device, stays. The background scan is
//! turned off before an LE link is initiated.
//!
//! **A device's identity.** An LE link to a resolvable private address
//! that a bond's identity resolving key made keeps the bond's address as
//! its `identity` - found by the scan, or by the link that listened, when
//! the link is up, or given by the pairing that made the bond - and `find`
//! takes the link for the device at either address. **This side's address** on an LE link, the
//! one the controller made it from, is the link's `own` once it is up,
//! for the security manager's checks: the private address the controller
//! had then where it was asked for from it, the public one otherwise - a
//! device's link to the advertising among them.
//!
//! **The device's name**, where the discovery did not hear it, is asked
//! for once a BR/EDR link is up (Remote Name Request): over the link it
//! comes at once. Over LE a link takes the name its bond keeps where the
//! discovery heard none, and a device that links to the controller with
//! neither is asked by GATT's client, its server's Device Name read
//! (att/client.zig). A name that comes after a pairing that knew none is
//! its bond's too (`named`).
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
const advertising = @import("advertising.zig");
const bonds = @import("bonds.zig");
const devices = @import("devices.zig");
const discovery = @import("discovery.zig");
const pairing = @import("pairing.zig");
const privacy = @import("privacy.zig");
const channels = @import("../l2cap/channels.zig");
const _att = @import("../att/_att.zig");
const att_client = @import("../att/client.zig");
const scan = @import("scan.zig");
const smp = @import("smp.zig");

/// How many links a controller keeps, and how many calls may wait on
/// them at once.
pub const CONNECTIONS = 8;
pub const WAITS = 16;

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
/// How long an LE link that is up waits for the device's features before
/// it is taken as made without them.
pub const FEATURES_WAIT_MS: u32 = 5_000;
/// How long a link made for channels stays once its last has closed.
pub const IDLE_MS: u32 = 2_000;
/// How old what the discovery heard of a device may be for a page to go
/// by it: a device's clock drifts from the offset heard.
const HEARD_FRESH_MS: u64 = 60_000;

/// A link's state: being made - listening for its device's advertising
/// first, over LE - up, or being ended.
pub const State = enum(u8) { free, connecting, up, disconnecting, listening };

pub const Connection = struct {
    state: State = .free,
    handle: u16 = 0,
    address: bluetooth.BTAddress = .{},
    /// Over LE; made by the device; the controller its central.
    le: bool = false,
    /// The device has answered on it - at once over BR/EDR, over LE once
    /// its features are read or a frame of its has come. Until then a
    /// link that is up is still being made.
    heard: bool = false,
    /// LE: the device's link layer features, as it gave them; zeros
    /// while they are not known.
    le_features: [8]u8 = @splat(0),
    /// LE: the address of the device's bond, where `address` is a
    /// private one its identity resolving key made; null where the two
    /// are the same, or it is not known.
    identity: ?bluetooth.BTAddress = null,
    /// LE: the address this side made the link from (privacy.zig) - while
    /// it is being made, only whether it is the private one
    /// (BTADDR_LE_RANDOM); once it is up, the address.
    own: bluetooth.BTAddress = .{},
    /// Made for channels or GATT, not asked for by ConnectBTDevice:
    /// ended at `idle_until`, once its last channel and block have closed
    /// and its last request has been answered.
    for_channels: bool = false,
    idle_until: ?u64 = null,
    incoming: bool = false,
    central: bool = false,
    encrypted: bool = false,
    /// The two have shown each other a link key: an authentication, or
    /// the encryption that follows one.
    authenticated: bool = false,
    /// BR/EDR: its encryption key's size checked since it was last
    /// encrypted - read and long enough, or the controller cannot say -
    /// by its pairing, or its being made secure.
    key_checked: bool = false,
    /// Its pairing, or its being made secure (pairing.zig).
    pairing: pairing.Pairing = .{},
    /// Over LE, the security manager's part of its pairing (smp.zig),
    /// and its attribute protocol's bearer (att/).
    smp: smp.Smp = .{},
    att: _att.Bearer = .{},
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

pub const WaitKind = enum(u8) { connect, disconnect, open, services, gatt };

/// A call waiting for a link to `address` to be up, or down - or for the
/// channel the task knows as `serial` to be open, for the
/// services of the device at `address`, or for the GATT procedure
/// numbered `serial` (att/client.zig).
pub const Wait = struct {
    used: bool = false,
    kind: WaitKind = .connect,
    address: bluetooth.BTAddress = .{},
    serial: u32 = 0,
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

/// The link to `address` - its own, or its identity - whatever its
/// state; null for none.
pub fn find(layer: *Hci, address: bluetooth.BTAddress) ?*Connection {
    for (&layer.connections) |*connection| {
        if (connection.state != .free and reaches(connection, address)) return connection;
    }
    return null;
}

/// Whether the link is to the device at `address`: its own address, or
/// the identity its private one resolved to.
pub fn reaches(connection: *const Connection, address: bluetooth.BTAddress) bool {
    if (sameAddress(connection.address, address)) return true;
    const identity = connection.identity orelse return false;
    return sameAddress(identity, address);
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

/// Whether the table has no room for another link.
pub fn full(layer: *const Hci) bool {
    for (&layer.connections) |*connection| {
        if (connection.state == .free) return false;
    }
    return true;
}

/// Whether an LE link is up, or being ended, with the controller its
/// central - or, `central` false, its peripheral.
pub fn leRole(layer: *const Hci, central: bool) bool {
    for (&layer.connections) |*connection| {
        if (connection.state != .up and connection.state != .disconnecting) continue;
        if (connection.le and connection.central == central) return true;
    }
    return false;
}

/// Whether the library is making an LE link: initiating, which the
/// background scan waits for.
pub fn makingLe(layer: *Hci) bool {
    return making(layer, true) != null;
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
        // Up, unless the device has not answered on it yet or it is
        // being made secure - and asked for, so kept.
        // Waited for at the link's own address, which its end answers.
        .up => {
            known.for_channels = false;
            known.idle_until = null;
            return if (!known.heard or securing(known)) waitFor(layer, .connect, known.address) else .{ .done = 0 };
        },
        .connecting, .listening => if (!known.unwanted) {
            known.for_channels = false;
            return waitFor(layer, .connect, known.address);
        },
        else => {},
    };
    if (find(layer, address) != null) return .{ .done = bluetooth.BTERR_BUSY };
    const wait = freeWait(layer) orelse return .{ .done = bluetooth.BTERR_NOMEM };
    const result = make(layer, address);
    if (result != 0) return .{ .done = result };
    return waitOn(layer, wait, .connect, address);
}

/// A link to the device at `address` begun, none being there, and
/// nobody waiting for it: 0, or why not. Over LE to a device whose bond
/// keeps its identity resolving key, the device listened for first
/// (`listen`); made at once otherwise (`makeNow`).
pub fn make(layer: *Hci, address: bluetooth.BTAddress) i32 {
    if (address.kind == bluetooth.BTADDR_BREDR or !listens(layer, address)) return makeNow(layer, address);
    if (find(layer, address) != null) return bluetooth.BTERR_BUSY;
    if (!canInitiate(layer)) return bluetooth.BTERR_UNSUPPORTED;
    return listen(layer, address);
}

/// Whether a link to `address`, over LE, listens for the device first:
/// its bond, kept at that address, has its identity resolving key - it
/// may advertise from a private address - and the controller can scan,
/// and resolve one.
fn listens(layer: *Hci, address: bluetooth.BTAddress) bool {
    if (layer.crypto == null or !discovery.canScan(layer)) return false;
    const bond = bonds.find(layer, address) orelse return false;
    return bond.has_irk;
}

/// A link that listens for its device begun: its record at the address
/// asked for, LE_CONNECT_TIMEOUT_MS to be heard in; a discovery that runs
/// stopped, as for any link, and the background scan begun afresh, so
/// that a device it reported already is reported again. 0, or why not.
fn listen(layer: *Hci, address: bluetooth.BTAddress) i32 {
    const connection = freeConnection(layer) orelse return bluetooth.BTERR_NOMEM;
    // Room for the discovery's end, the scan's, the advertising's, and the
    // scan begun again.
    if (_hci.QUEUE - layer.queue_count < 5) return bluetooth.BTERR_NOMEM;
    discovery.stop(layer);
    scan.stop(layer);
    connection.* = .{
        .state = .listening,
        .address = address,
        .le = true,
        .central = true,
        .deadline = layer.now + LE_CONNECT_TIMEOUT_MS,
    };
    if (devices.find(layer, address.bytes, address.kind)) |device| {
        connection.class_of_device = device.class_of_device;
        setName(connection, &device.name);
    }
    scan.update(layer);
    layer.changed = true;
    return 0;
}

/// The device a link listens for heard at `heard` - the address the link
/// was asked for at, or a private address the bond's key made: the link
/// initiated to it, the address asked for kept as its identity where the
/// two differ, the calls waiting for it waiting at the address heard. 0,
/// or why not - the link listening on.
pub fn reached(layer: *Hci, connection: *Connection, heard: bluetooth.BTAddress) i32 {
    if (making(layer, true) != null) return bluetooth.BTERR_BUSY;
    // Room for the scan's end, the advertising's and the link's command.
    if (_hci.QUEUE - layer.queue_count < 3) return bluetooth.BTERR_NOMEM;
    scan.stop(layer);
    advertising.makeWay(layer, hci.LE_STATE_ADV_INITIATING);
    const identity = connection.address;
    const private = privacy.towards(layer, identity);
    if (!initiate(layer, heard, private)) return bluetooth.BTERR_NOMEM;
    connection.state = .connecting;
    connection.address = heard;
    if (!sameAddress(heard, identity)) connection.identity = identity;
    connection.own = .{ .kind = if (private) bluetooth.BTADDR_LE_RANDOM else bluetooth.BTADDR_LE_PUBLIC };
    connection.deadline = layer.now + LE_CONNECT_TIMEOUT_MS;
    rewait(layer, identity, heard);
    layer.changed = true;
    return 0;
}

/// The calls waiting for the link at `from` to be up, waiting for it at
/// `to`: the address it is made to.
fn rewait(layer: *Hci, from: bluetooth.BTAddress, to: bluetooth.BTAddress) void {
    for (&layer.waits) |*wait| {
        if (wait.used and !wait.done and wait.kind == .connect and sameAddress(wait.address, from)) wait.address = to;
    }
}

/// Whether a link listens for its device, which the background scan is on
/// for.
pub fn listening(layer: *const Hci) bool {
    for (&layer.connections) |*connection| {
        if (connection.state == .listening) return true;
    }
    return false;
}

/// A link to the device at `address` begun at once - paged, or initiated
/// to that address - none being there, and nobody waiting for it: 0, or
/// why not.
pub fn makeNow(layer: *Hci, address: bluetooth.BTAddress) i32 {
    const le_link = address.kind != bluetooth.BTADDR_BREDR;
    if (find(layer, address) != null) return bluetooth.BTERR_BUSY;
    if (if (le_link) !canInitiate(layer) else !canPage(layer)) return bluetooth.BTERR_UNSUPPORTED;
    if (making(layer, le_link) != null) return bluetooth.BTERR_BUSY;
    const connection = freeConnection(layer) orelse return bluetooth.BTERR_NOMEM;
    // Room for the discovery's end, the background scan's, the
    // advertising's and the link's command.
    if (_hci.QUEUE - layer.queue_count < 5) return bluetooth.BTERR_NOMEM;
    discovery.stop(layer);
    if (le_link) {
        scan.stop(layer);
        advertising.makeWay(layer, hci.LE_STATE_ADV_INITIATING);
    }
    const heard = devices.find(layer, address.bytes, address.kind);
    const private = le_link and privacy.towards(layer, address);
    const sent = if (le_link) initiate(layer, address, private) else page(layer, address, heard);
    if (!sent) return bluetooth.BTERR_NOMEM;
    connection.* = .{
        .state = .connecting,
        .address = address,
        .le = le_link,
        .central = true,
        .own = .{ .kind = if (private) bluetooth.BTADDR_LE_RANDOM else bluetooth.BTADDR_LE_PUBLIC },
        .deadline = layer.now + (if (le_link) LE_CONNECT_TIMEOUT_MS else PAGE_WAIT_MS),
    };
    if (heard) |device| {
        connection.class_of_device = device.class_of_device;
        setName(connection, &device.name);
    }
    layer.changed = true;
    return 0;
}

/// Whether a link that is up is being made secure with its bond, which
/// ConnectBTDevice waits for.
pub fn securing(connection: *const Connection) bool {
    return connection.pairing.stage != .idle and connection.pairing.purpose == .secure;
}

/// The link to `address` ended: one being made taken back, or ended as
/// soon as it is up.
pub fn disconnect(layer: *Hci, address: bluetooth.BTAddress) Begun {
    if (layer.state != bluetooth.BTCS_UP) return .{ .done = bluetooth.BTERR_NOTUP };
    const connection = find(layer, address) orelse return .{ .done = bluetooth.BTERR_NOTCONNECTED };
    // Listening, nothing asked of the controller yet: let go of at once.
    if (connection.state == .listening) {
        letGo(layer, connection);
        return .{ .done = 0 };
    }
    const wait = freeWait(layer) orelse return .{ .done = bluetooth.BTERR_NOMEM };
    // Waited for at the link's own address, which its end answers.
    const own = connection.address;
    switch (connection.state) {
        .connecting => drop(layer, connection),
        .up => {
            if (!end(layer, connection, hci.HCI_ERR_REMOTE_USER_TERMINATED)) return .{ .done = bluetooth.BTERR_NOMEM };
            // Its making taken back, if the device has not answered yet.
            if (!connection.heard) connection.unwanted = true;
        },
        .disconnecting, .free, .listening => {},
    }
    return waitOn(layer, wait, .disconnect, own);
}

/// Every link ended - the controller's power goes off - those being made
/// taken back.
pub fn dropAll(layer: *Hci) void {
    for (&layer.connections) |*connection| close(layer, connection, hci.HCI_ERR_REMOTE_POWER_OFF);
}

/// A link ended, whatever its state: one up ended for `reason`, one being
/// made taken back, one listening let go of.
pub fn close(layer: *Hci, connection: *Connection, reason: u8) void {
    switch (connection.state) {
        .up => _ = end(layer, connection, reason),
        .connecting => drop(layer, connection),
        .listening => letGo(layer, connection),
        .disconnecting, .free => {},
    }
}

/// A link that listens let go of: not made, its calls answered
/// HCI_ERR_LOCAL_HOST_TERMINATED, and the background scan off where
/// nothing else wants it.
fn letGo(layer: *Hci, connection: *Connection) void {
    failed(layer, connection, hci.HCI_ERR_LOCAL_HOST_TERMINATED);
    scan.update(layer);
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
    channels.reset(layer, result);
    att_client.reset(layer, result);
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

pub fn waitFor(layer: *Hci, kind: WaitKind, address: bluetooth.BTAddress) Begun {
    const wait = freeWait(layer) orelse return .{ .done = bluetooth.BTERR_NOMEM };
    return waitOn(layer, wait, kind, address);
}

/// Whether a call can wait: a wait is free.
pub fn canWait(layer: *Hci) bool {
    return freeWait(layer) != null;
}

/// A call waiting for the channel the task knows as `serial`.
pub fn waitForSerial(layer: *Hci, kind: WaitKind, serial: u32) Begun {
    const wait = freeWait(layer) orelse return .{ .done = bluetooth.BTERR_NOMEM };
    wait.* = .{ .used = true, .kind = kind, .serial = serial };
    const index = (@intFromPtr(wait) - @intFromPtr(&layer.waits)) / @sizeOf(Wait);
    return .{ .waiting = @intCast(index) };
}

/// Every call waiting for the channel the task knows as `serial` - to be
/// open, or closed - done, with `result`.
pub fn answerSerial(layer: *Hci, kind: WaitKind, serial: u32, result: i32) void {
    if (serial == 0) return;
    for (&layer.waits) |*wait| {
        if (!wait.used or wait.done or wait.kind != kind or wait.serial != serial) continue;
        wait.done = true;
        wait.result = result;
    }
}

/// Every call waiting for the services of the device at `address` done,
/// with `result`.
pub fn answerServices(layer: *Hci, address: bluetooth.BTAddress, result: i32) void {
    answer(layer, .services, address, result);
}

/// The link to `address` has no channel left: one made for channels ends
/// IDLE_MS from now.
pub fn idle(layer: *Hci, address: bluetooth.BTAddress) void {
    const connection = find(layer, address) orelse return;
    if (connection.state != .up or !connection.for_channels) return;
    connection.idle_until = layer.now + IDLE_MS;
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

/// LE Create Connection to `address`, from the controller's private
/// address where `private`: scanning for it all the time, the link's
/// parameters this layer's.
fn initiate(layer: *Hci, address: bluetooth.BTAddress, private: bool) bool {
    var params: [25]u8 = undefined;
    put16(params[0..2], hci.LE_CONNECT_SCAN_INTERVAL);
    put16(params[2..4], hci.LE_CONNECT_SCAN_WINDOW);
    params[4] = 0; // this address, not the filter accept list
    params[5] = if (address.kind == bluetooth.BTADDR_LE_PUBLIC) hci.LE_ADDR_PUBLIC else hci.LE_ADDR_RANDOM;
    params[6..12].* = address.bytes;
    params[12] = if (private) hci.LE_ADDR_RANDOM else hci.LE_ADDR_PUBLIC; // its own address
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
        // Refused: the LE links waiting for the device's features taken
        // as made without them.
        hci.HCI_OP_LE_READ_REMOTE_FEATURES => for (&layer.connections) |*connection| {
            if (connection.le and connection.state == .up and !connection.heard) established(layer, connection);
        },
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
/// made. A link the device made - to the controller's advertising, which
/// it ends - is taken while there is room.
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
    if (role == hci.ROLE_PERIPHERAL) advertising.linkMade(layer);
    var connection = if (role == hci.ROLE_CENTRAL) making(layer, true) else null;
    if (connection == null) {
        connection = freeConnection(layer) orelse return refuseLink(layer, handle);
        connection.?.* = .{ .state = .connecting, .incoming = true };
    }
    const made = connection.?;
    made.address = address;
    made.le = true;
    made.central = role == hci.ROLE_CENTRAL;
    made.own = privacy.own(layer, made.central and made.own.kind == bluetooth.BTADDR_LE_RANDOM);
    if (made.incoming) {
        if (devices.find(layer, address.bytes, address.kind)) |device| setName(made, &device.name);
    }
    made.interval = _hci.le16(params[11..13]);
    made.latency = _hci.le16(params[13..15]);
    made.supervision = _hci.le16(params[15..17]);
    up(layer, made, handle);
}

/// What a call waiting for a link that was not made is answered: the
/// controller's status - or BTERR_TIMEOUT for one taken back at its
/// time, HCI_ERR_LOCAL_HOST_TERMINATED for one that was no longer wanted.
fn failure(connection: *const Connection, status: i32) i32 {
    if (connection.unwanted) return hci.HCI_ERR_LOCAL_HOST_TERMINATED;
    if (connection.cancelled) return bluetooth.BTERR_TIMEOUT;
    return status;
}

/// A link up that has no room in the table: ended at once.
fn refuseLink(layer: *Hci, handle: u16) void {
    const params = [_]u8{ @truncate(handle), @truncate(handle >> 8), hci.HCI_ERR_REMOTE_LOW_RESOURCES };
    _ = _hci.command(layer, hci.HCI_OP_DISCONNECT, &params, _hci.COMMAND_TIMEOUT_MS);
}

/// The controller's link up: over LE the device asked for its features
/// first, the link made once it answers.
fn up(layer: *Hci, connection: *Connection, handle: u16) void {
    connection.state = .up;
    connection.handle = handle;
    connection.since = layer.now;
    connection.deadline = null;
    connection.frame_have = 0;
    connection.frame_dropping = false;
    connection.outstanding = 0;
    layer.changed = true;
    if (connection.unwanted) {
        connection.heard = true;
        note(layer, connection, .up, 0);
        answer(layer, .connect, connection.address, 0);
        if (!end(layer, connection, hci.HCI_ERR_REMOTE_USER_TERMINATED)) {
            connection.unwanted = false;
            answer(layer, .disconnect, connection.address, bluetooth.BTERR_NOMEM);
        }
        return;
    }
    if (connection.le and askFeatures(layer, connection)) {
        connection.deadline = layer.now + FEATURES_WAIT_MS;
        return;
    }
    established(layer, connection);
}

/// LE Read Remote Features on a link that is up - the device's answer the
/// first word heard on it. False where the controller does not take it.
fn askFeatures(layer: *Hci, connection: *const Connection) bool {
    if (!_hci.supports(layer, hci.CMDBIT_LE_READ_REMOTE_FEATURES)) return false;
    var params: [2]u8 = undefined;
    put16(&params, connection.handle);
    return _hci.command(layer, hci.HCI_OP_LE_READ_REMOTE_FEATURES, &params, _hci.COMMAND_TIMEOUT_MS);
}

/// The device has answered on a link that is up: the link made - over
/// LE, a bonded device's identity and name taken from its bond; a
/// pairing that waited for it begun, a bonded device's link made secure
/// before its callers are answered. Nothing for one being ended, whose
/// callers its end answers.
pub fn established(layer: *Hci, connection: *Connection) void {
    if (connection.heard or connection.state != .up) return;
    connection.heard = true;
    connection.deadline = null;
    layer.changed = true;
    if (connection.le) {
        if (smp.bondOf(layer, connection)) |bond| {
            if (connection.identity == null and !sameAddress(bond.address, connection.address)) connection.identity = bond.address;
            if (connection.name[0] == 0) setName(connection, &bond.name);
        }
    }
    note(layer, connection, .up, 0);
    if (!pairing.linkUp(layer, connection)) answer(layer, .connect, connection.address, 0);
    channels.linkUp(layer, connection);
    att_client.linkUp(layer, connection);
}

/// LE Read Remote Features Complete, past its subevent: the device has
/// answered on the link, its features kept - unless the link failed,
/// whose end follows with the reason.
pub fn leFeatures(layer: *Hci, params: []const u8) void {
    if (params.len < 3) return;
    const connection = byHandle(layer, _hci.le16(params[1..3]) & hci.ACL_HANDLE_MASK) orelse return;
    switch (params[0]) {
        hci.HCI_SUCCESS => {
            if (params.len >= 11) connection.le_features = params[3..11].*;
        },
        hci.HCI_ERR_CONNECTION_TIMEOUT, hci.HCI_ERR_LMP_RESPONSE_TIMEOUT, hci.HCI_ERR_FAILED_TO_ESTABLISH => return,
        else => {},
    }
    established(layer, connection);
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
    channels.linkGone(layer, connection, result);
    att_client.linkGone(layer, connection, result);
    pairing.linkGone(layer, connection, result);
    const address = connection.address;
    connection.* = .{};
    layer.changed = true;
    answer(layer, .connect, address, result);
    answer(layer, .disconnect, address, 0);
}

/// A link that was up and is down, for `reason`: its buffers given back,
/// its record freed, the calls waiting for its end answered `result` -
/// and, where the device never answered on it, which was then not made,
/// those waiting for it to be up answered why.
fn down(layer: *Hci, connection: *Connection, result: i32, reason: i32) void {
    const made = connection.heard;
    const why = if (made) reason else failure(connection, reason);
    note(layer, connection, if (made) .down else .not_made, why);
    channels.linkGone(layer, connection, why);
    att_client.linkGone(layer, connection, why);
    pairing.linkGone(layer, connection, why);
    acl.released(layer, connection);
    const address = connection.address;
    connection.* = .{};
    layer.changed = true;
    // The buffers it held, and its places in the queue, go to the others.
    if (layer.state == bluetooth.BTCS_UP) acl.pump(layer);
    if (!made) answer(layer, .connect, address, why);
    answer(layer, .disconnect, address, result);
}

/// A link whose end the controller refused: up as it was, the calls
/// waiting for its end answered with why - one the device has not
/// answered on yet waiting for it again.
fn stays(layer: *Hci, connection: *Connection, status: i32) void {
    connection.state = .up;
    connection.deadline = if (connection.heard) null else layer.now + FEATURES_WAIT_MS;
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
        // A key not read yet.
        connection.key_checked = false;
        layer.changed = true;
    }
    pairing.encryptionChanged(layer, connection, params[0]);
    // The device's own encryption: what waited for the link's security.
    channels.secured(layer, connection);
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
    named(layer, connection);
}

/// The link's name come from its device - its Remote Name Request
/// answered, its GATT server's Device Name read: the bond's too where
/// that was kept without one.
pub fn named(layer: *Hci, connection: *const Connection) void {
    layer.changed = true;
    const bond = smp.bondOf(layer, connection) orelse return;
    bonds.named(layer, bond, &connection.name);
}

// --- the time ---------------------------------------------------------------------

/// Whatever is due at `layer.now`: a link being made taken back, or
/// given up on once that was not answered - one listening for a device
/// not heard given up on at once; a link being ended taken to be down; a
/// link made for channels ended once nothing is left on it.
pub fn tick(layer: *Hci) void {
    for (&layer.connections) |*connection| {
        if (connection.idle_until) |idle_due| {
            // Made for channels, nothing left on it: ended.
            if (layer.now >= idle_due) {
                connection.idle_until = null;
                if (connection.state == .up and connection.for_channels and !channels.uses(layer, connection.address) and !att_client.uses(layer, connection)) {
                    _ = end(layer, connection, hci.HCI_ERR_REMOTE_USER_TERMINATED);
                }
            }
        }
        const due = connection.deadline orelse continue;
        if (layer.now < due) continue;
        connection.deadline = null;
        switch (connection.state) {
            .connecting => {
                if (connection.incoming or connection.cancelled) {
                    failed(layer, connection, failure(connection, hci.HCI_ERR_CONNECTION_TIMEOUT));
                } else cancel(layer, connection);
            },
            .listening => failed(layer, connection, bluetooth.BTERR_TIMEOUT),
            .disconnecting => down(layer, connection, bluetooth.BTERR_TIMEOUT, bluetooth.BTERR_TIMEOUT),
            // The device's features not given in time: made without them.
            .up => established(layer, connection),
            .free => {},
        }
    }
}

/// The earliest a link's time is due; null for none.
pub fn deadline(layer: *const Hci) ?u64 {
    var earliest: ?u64 = null;
    for (&layer.connections) |*connection| {
        for ([_]?u64{ connection.deadline, connection.idle_until }) |due_or_none| {
            const due = due_or_none orelse continue;
            if (earliest == null or due < earliest.?) earliest = due;
        }
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
