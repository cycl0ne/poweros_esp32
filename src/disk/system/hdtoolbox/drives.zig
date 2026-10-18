// SPDX-License-Identifier: MIT
//! The drives HDToolBox offers, and what dos's list has mounted from each.
//!
//! **The units** (`Units`). expansion.library lists every unit of every
//! block device the board has (ObtainDeviceUnits with DEVIF_BLOCK) - the
//! flash disk, a card slot, a stick's units - and opens none of them to
//! find out. The list is kept while HDToolBox runs. A device is opened
//! only when one of its units is picked, since opening a device in DEVS:
//! loads it for good.
//!
//! **What is mounted from a unit** (`mountedOn`). Every device node on
//! dos's list whose startup message opens the unit: the unit's number,
//! and the device as the node names it, compared by its part past the
//! last `/` or `:`. Each comes with a copy of its name and its
//! environment - a partition's area, or a whole medium's for a node with
//! none - so nothing of the list is held once the lock is let go. The
//! node SYS: is on is marked (`systemNode`, the device node whose handler
//! serves SYS:): the system runs from it, and its partition is not to be
//! moved, removed or retyped.
//!
//! **The names taken** (`Names`). The device nodes' and the assigns'
//! names, which a drive mounted later cannot have, and the table's own
//! partitions: none of them is offered for a new partition.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const rdb = sdk.rdb;
const devices = sdk.expansion.devices;
const DosBase = sdk.interface.dos.DosBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;

/// The expansion.library that lists devices by what they speak.
pub const expansion_version = 1;

/// The most units offered.
pub const max_units = 32;

/// A unit of a block device.
pub const Unit = struct {
    /// What OpenDevice and OpenRDB take: a ROM device's name, or the
    /// path of a file under DEVS:. It is the list's, while it is kept.
    device: [*:0]const u8,
    number: u32,
    /// What the board calls it, or null.
    label: ?[*:0]const u8,
    /// The device is in the ROM.
    rom: bool,
};

/// Every unit of every block device, from expansion.library's list.
pub const Units = struct {
    list: ?*exec.List = null,
    items: [max_units]Unit = undefined,
    count: usize = 0,

    /// The list asked for and kept; false without memory for it.
    pub fn obtain(units: *Units, eb: *ExpansionBase) bool {
        const list = eb.ObtainDeviceUnits(devices.DEVIF_BLOCK, null) orelse return false;
        units.list = list;
        units.count = 0;
        var it = list.iterator();
        while (it.next()) |node| {
            if (units.count == max_units) break;
            const unit: *const devices.DeviceUnit = @ptrCast(@alignCast(node));
            const name = unit.node.name orelse continue;
            units.items[units.count] = .{
                .device = name,
                .number = unit.unit,
                .label = unit.label,
                .rom = unit.flags & devices.DUF_ROM != 0,
            };
            units.count += 1;
        }
        return true;
    }

    /// The list given back; the units' names go with it.
    pub fn release(units: *Units, eb: *ExpansionBase) void {
        eb.ReleaseDeviceUnits(units.list);
        units.list = null;
        units.count = 0;
    }

    pub fn all(units: *const Units) []const Unit {
        return units.items[0..units.count];
    }
};

/// The most drives of one unit shown.
pub const max_mounted = 16;

/// A drive on dos's list that is mounted from a unit, as it was when the
/// list was read.
pub const Mounted = struct {
    name: rdb.MountName = @splat(0),
    /// Its environment; a whole medium's for a node that has none.
    env: dos.DosEnvec = .{},
    /// Its handler has been started.
    started: bool = false,
    /// SYS: is on it.
    system: bool = false,

    pub fn nameText(mounted: *const Mounted) []const u8 {
        return textOf(&mounted.name);
    }
};

fn textOf(name: *const rdb.MountName) []const u8 {
    var length: usize = 0;
    while (length < name.len and name[length] != 0) length += 1;
    return name[0..length];
}

fn copyName(into: *rdb.MountName, text: [*:0]const u8) void {
    into.* = @splat(0);
    var length: usize = 0;
    while (length < into.len and text[length] != 0) : (length += 1) into[length] = text[length];
}

/// The device node SYS: is on, or null: the one whose handler SYS:
/// is served by - SYS: itself is an assign, as a rule. Only compared,
/// never followed: it is on dos's list for the system's life.
pub fn systemNode(dl: *DosBase) ?*const dos.DosList {
    const dp = dl.GetDeviceProc("SYS:", null) orelse return null;
    defer dl.FreeDeviceProc(dp);
    const port = dp.port orelse return null;
    const flags = dos.LDF_DEVICES | dos.LDF_READ;
    const list = dl.LockDosList(flags) orelse return null;
    defer dl.UnLockDosList(flags);
    var entry = dl.NextDosEntry(list, dos.LDF_DEVICES);
    while (entry) |node| : (entry = dl.NextDosEntry(node, dos.LDF_DEVICES)) {
        const task = node.task orelse continue;
        if (task == port) return node;
    }
    return null;
}

/// The drives mounted from unit `unit` of `device`, as many as `into`
/// holds, the one that is `system` marked.
pub fn mountedOn(dl: *DosBase, device: [*:0]const u8, unit: u32, system: ?*const dos.DosList, into: []Mounted) []Mounted {
    const flags = dos.LDF_DEVICES | dos.LDF_READ;
    const list = dl.LockDosList(flags) orelse return into[0..0];
    defer dl.UnLockDosList(flags);
    var count: usize = 0;
    var entry = dl.NextDosEntry(list, dos.LDF_DEVICES);
    while (entry) |node| : (entry = dl.NextDosEntry(node, dos.LDF_DEVICES)) {
        if (count == into.len) break;
        const startup = dos.filehandler.startupOf(node.misc.handler.startup) orelse continue;
        if (!dos.filehandler.opensUnit(startup, device, unit)) continue;
        const mounted = &into[count];
        mounted.* = .{ .started = node.task != null, .system = if (system) |sys_node| node == sys_node else false };
        copyName(&mounted.name, node.name);
        if (startup.environ) |env| mounted.env = env.*;
        count += 1;
    }
    return into[0..count];
}

/// The most names kept.
pub const max_names = 64;

/// Names a new partition is not offered.
pub const Names = struct {
    text: [max_names]rdb.MountName = undefined,
    slices: [max_names][]const u8 = undefined,
    count: usize = 0,

    /// A name kept, as far as there is room.
    pub fn add(names: *Names, name: [*:0]const u8) void {
        if (names.count == max_names) return;
        copyName(&names.text[names.count], name);
        names.slices[names.count] = textOf(&names.text[names.count]);
        names.count += 1;
    }

    pub fn all(names: *const Names) []const []const u8 {
        return names.slices[0..names.count];
    }

    /// The names of every device node and assign on dos's list added.
    pub fn addDosList(names: *Names, dl: *DosBase) void {
        const kinds = dos.LDF_DEVICES | dos.LDF_ASSIGNS;
        const flags = kinds | dos.LDF_READ;
        const list = dl.LockDosList(flags) orelse return;
        defer dl.UnLockDosList(flags);
        var entry = dl.NextDosEntry(list, kinds);
        while (entry) |node| : (entry = dl.NextDosEntry(node, kinds)) names.add(node.name);
    }
};
