// SPDX-License-Identifier: MIT
//! A controller as the task keeps it: the device's unit it opened, the
//! reads kept queued there and the writes that carry its commands, what
//! the device said of it, and its HCI (`hci/_hci.zig`). Made by the task
//! when a driver adds the controller, or when the board has one
//! (`board.zig`), on the base's list until the driver removes it;
//! ObtainBTControllers copies what a lister sees from it. A board's
//! controller whose device is still setting it up is on the list unopened,
//! BTCS_OPENING, until the device offers it.

const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const hcidev = sdk.devices.hci;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _hci = @import("../hci/_hci.zig");
const acl = @import("../hci/acl.zig");
const discovery = @import("../hci/discovery.zig");
const local = @import("../hci/local.zig");

/// How many reads are kept queued on a controller, and how many packets
/// may be on their way to it at once.
pub const READS = 4;
pub const WRITES = 2;
/// A read's room: the longest ACL packet a transport hands over, 1024
/// bytes of data - more than the longest event. A longer packet gets a
/// room of its own (`Read.bigger`).
pub const READ_SIZE = hci.HCI_ACL_HDR + 1024;
/// A write's: the longest ACL packet the HCI layer sends - longer than
/// the longest command.
pub const WRITE_SIZE = @max(hci.HCI_COMMAND_HDR + hci.HCI_MAX_PARAMS, hci.HCI_ACL_HDR + acl.PACKET_MOST);
/// The longest device name kept, and the room for what the device says
/// of its chip and firmware.
pub const DEVICE_NAME_SIZE = 64;
pub const CHIP_SIZE = 48;
pub const FIRMWARE_SIZE = 96;

/// What every request on the task's reply port of a controller starts
/// with: which controller, and whether it is a read or a write.
pub const Request = struct {
    io: hcidev.IOHciReq = .{},
    controller: ?*Controller = null,
    kind: Kind = .read,
    /// Sent, and not back yet.
    out: bool = false,

    pub const Kind = enum(u8) { read, write };
};

pub const Read = struct {
    request: Request = .{ .kind = .read },
    /// A room for a packet longer than `buffer`, made when one came;
    /// freed with the controller.
    bigger: ?[*]u8 = null,
    bigger_size: usize = 0,
    buffer: [READ_SIZE]u8 = undefined,
};

pub const Write = struct {
    request: Request = .{ .kind = .write },
    buffer: [WRITE_SIZE]u8 = undefined,
};

pub const Controller = struct {
    /// On the base's list of controllers.
    node: exec.Node = .{},
    base: *BluetoothBase,
    /// BTController.id.
    id: u32 = 0,
    unit: u32 = 0,
    device_name: [DEVICE_NAME_SIZE:0]u8 = @splat(0),
    /// Whether the device's unit is open; whether the controller is being
    /// taken away - nothing more is sent to it.
    open: bool = false,
    leaving: bool = false,
    /// The state last said in the log.
    reported: u32 = bluetooth.BTCS_OPENING,
    /// Up since the binder was last told: its kept services to be offered
    /// again (profile/binder.zig).
    offer_kept: bool = false,
    /// Whether its name is one it was given (BTCA_Name), kept in its
    /// settings, rather than the machine's.
    own_name: bool = false,
    /// What the device's HCICMD_QUERY said.
    bus: u32 = 0,
    baud: u32 = 0,
    chip: [CHIP_SIZE:0]u8 = @splat(0),
    firmware: [FIRMWARE_SIZE:0]u8 = @splat(0),
    reads: [READS]Read = @splat(.{}),
    writes: [WRITES]Write = @splat(.{}),
    layer: _hci.Hci,
};

/// The controller on the base's list for this device and unit; null for
/// none. Under the base's lock, or on the task.
pub fn find(base: *BluetoothBase, device_name: [*:0]const u8, unit: u32) ?*Controller {
    var it = base.controllers.iterator();
    while (it.next()) |node| {
        const controller = fromNode(node);
        if (controller.unit == unit and sameName(&controller.device_name, device_name)) return controller;
    }
    return null;
}

pub fn fromNode(node: *exec.Node) *Controller {
    return @alignCast(@fieldParentPtr("node", node));
}

fn sameName(kept: [*:0]const u8, name: [*:0]const u8) bool {
    var index: usize = 0;
    while (kept[index] == name[index]) : (index += 1) {
        if (kept[index] == 0) return true;
    }
    return false;
}

/// The lowest number no controller on the list has.
pub fn freeId(base: *BluetoothBase) u32 {
    var id: u32 = 0;
    while (true) : (id += 1) {
        var taken = false;
        var it = base.controllers.iterator();
        while (it.next()) |node| {
            if (fromNode(node).id == id) taken = true;
        }
        if (!taken) return id;
    }
}

/// A NUL-ended string copied into `into`, cut to fit.
pub fn copyString(into: []u8, from: ?[*:0]const u8) void {
    var index: usize = 0;
    if (from) |text| {
        while (index + 1 < into.len and text[index] != 0) : (index += 1) into[index] = text[index];
    }
    if (into.len > 0) into[index] = 0;
}

/// One controller as ObtainBTControllers hands it out: the public record
/// and the strings it points at, in one piece.
pub const Entry = extern struct {
    public: bluetooth.BTController = .{},
    device_name: [DEVICE_NAME_SIZE + 1]u8 = @splat(0),
    name: [hci.HCI_MAX_NAME + 1]u8 = @splat(0),
    chip: [CHIP_SIZE + 1]u8 = @splat(0),
    firmware: [FIRMWARE_SIZE + 1]u8 = @splat(0),
};

/// What it does now: BTCF_*.
pub fn flagsOf(layer: *const _hci.Hci) u32 {
    if (layer.state != bluetooth.BTCS_UP) return 0;
    var flags: u32 = 0;
    if (layer.powered) {
        flags |= bluetooth.BTCF_POWERED;
        if (_hci.bredr(layer) or layer.advertising.on) flags |= bluetooth.BTCF_CONNECTABLE;
        if (layer.visible) flags |= bluetooth.BTCF_VISIBLE;
        if (layer.advertising.on) flags |= bluetooth.BTCF_ADVERTISING;
    }
    if (discovery.running(layer)) flags |= bluetooth.BTCF_DISCOVERING;
    return flags;
}

/// A controller copied into an entry, under the base's lock; `now` the
/// time in milliseconds, which its time left visible is counted from.
pub fn describe(controller: *const Controller, entry: *Entry, now: u64) void {
    const layer = &controller.layer;
    copyString(&entry.device_name, &controller.device_name);
    copyString(&entry.name, @ptrCast(&layer.name));
    copyString(&entry.chip, &controller.chip);
    copyString(&entry.firmware, &controller.firmware);
    const public = &entry.public;
    public.* = .{
        .id = controller.id,
        .unit = controller.unit,
        .state = layer.state,
        .failure = layer.failure,
        .address = .{ .bytes = layer.address, .kind = bluetooth.BTADDR_BREDR },
        .hci_version = layer.hci_version,
        .lmp_version = layer.lmp_version,
        .hci_revision = layer.hci_revision,
        .lmp_subversion = layer.lmp_subversion,
        .manufacturer = layer.manufacturer,
        .class_of_device = layer.class_of_device,
        .flags = flagsOf(layer),
        .visible_left = if (layer.state == bluetooth.BTCS_UP and layer.powered) local.visibleLeft(layer, now) else 0,
        .name = @ptrCast(&entry.name),
        .bus = controller.bus,
        .baud = controller.baud,
        .chip = if (entry.chip[0] != 0) @ptrCast(&entry.chip) else null,
        .firmware = if (entry.firmware[0] != 0) @ptrCast(&entry.firmware) else null,
        .acl_mtu = layer.acl_mtu,
        .acl_packets = layer.acl_packets,
        .le_mtu = layer.le_mtu,
        .le_packets = layer.le_packets,
        .sco_mtu = layer.sco_mtu,
        .sco_packets = layer.sco_packets,
        .features = layer.features,
        .le_features = layer.le_features,
        .commands = layer.commands,
        .le_states = layer.le_states,
    };
    public.node.name = @ptrCast(&entry.device_name);
}
