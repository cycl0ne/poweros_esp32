// SPDX-License-Identifier: MPL-2.0
//! The device list, and who gets a device.
//!
//! A device is hardware a driver can drive. The machine's own are put on
//! the list once, the first time drivers are bound (`listMachine`): every
//! panel part of the board's list, in the list's order, then every
//! function on PCI whose class is a display, in the order pci.library
//! found them. A device nothing here can find - the tests' - is put on
//! the list by whoever found it (`AddRtgDevice`).
//!
//! A device has a name: a part's is `panel.` and its number among the
//! panels ("panel.0"), a function's its place on PCI ("pci.01:00.0").
//! The firmware's framebuffer is a device like the others, marked
//! `RTGDVF_FIRMWARE`; where its memory lies inside a function on PCI,
//! that function is the device it lies behind.
//!
//! **Offering** (`offer`) hands a device no driver has to the drivers
//! whose table names it, the closest first: an entry that names a chip,
//! or a vendor and a device, above one that names a bus, a vendor alone
//! or a class; among entries as close the entry's own priority, then the
//! driver's place on the list. A driver is asked through its `attach`,
//! inside which it makes its boards (`CreateBoard`). On RTGERR_OK it has
//! the device and its boards join the library's list (`boards.list`);
//! on anything else the boards it left are freed and the next driver is
//! asked.
//!
//! The device list's semaphore is held through all of it, and the driver
//! list's through an offer: a driver is not taken off the list while its
//! `attach` runs.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const pci = sdk.pci;
const st = sdk.expansion.systemtags;
const TagItem = sdk.utility.TagItem;
const err = rtg.errors;

const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");
const drivers = @import("../driver/_driver.zig");
const settings = @import("../settings/_settings.zig");

/// What the library keeps for a device, beside the handle a driver sees.
pub const Private = struct {
    device: rtg.RtgDevice = .{},
    /// The device's name, which the handle's node points at.
    name_buf: [rtg.drivers.RTG_NAME_MAX]u8 = @splat(0),
    /// What the hardware is called, for people: a part's chip name, or
    /// null.
    chip_name: ?[*:0]const u8 = null,
    /// The boards its driver made of it, by their `device_link`.
    boards: exec.List = .{},
    /// The driver whose `attach` is running for it, or null: the one
    /// driver that may make a board of it or open its bus meanwhile.
    offered_to: ?*rtg.RtgDriver = null,
    /// It was made by `AddRtgDevice`, and may be taken away again.
    added: bool = false,
    /// What its settings line says, as tags in front of its own
    /// (`settings/_settings.zig`): the handle's `tags` point here while
    /// `dressed`, and `own_tags` are the ones it was made with.
    dress: [4]TagItem = @splat(.{}),
    own_tags: ?[*]const TagItem = null,
    dressed: bool = false,
};

/// The library's own record around a device's handle.
///
/// INPUTS:
/// - `device` - the device.
pub fn privateOf(device: *rtg.RtgDevice) *Private {
    return @fieldParentPtr("device", device);
}

/// The device a node of the device list belongs to.
///
/// INPUTS:
/// - `node` - the device's node.
pub fn deviceOf(node: *exec.Node) *rtg.RtgDevice {
    return @fieldParentPtr("node", node);
}

/// PCI's class of a display, and the mask that leaves the class alone.
const display_class: u32 = 0x03_0000;
const class_mask: u32 = 0xFF_0000;

// --- the list ---------------------------------------------------------------

/// A device of the part kind, made and put at the end of the list: a
/// panel part of the board's, or what tags say of one. Null without
/// memory.
///
/// INPUTS:
/// - `rb` - the library; the device list's lock is held.
/// - `part` - the part of the board's list, or null for a device made
///   from tags alone.
/// - `tag_list` - the device's tags: the part's own.
pub fn addPart(rb: *RtgBase, part: ?*const sdk.expansion.BoardPart, tag_list: ?[*]const TagItem) ?*Private {
    const sys = rb.sys_base;
    const ub = rb.utility_base;
    const private = allocate(rb) orelse return null;
    const device = &private.device;
    device.kind = rtg.drivers.RTGDEV_PART;
    device.part = part;
    device.tags = tag_list;
    device.chip = @truncate(ub.GetTagData(st.PART_Chip, st.CHIP_NONE, tag_list));
    device.bus = @truncate(ub.GetTagData(st.PART_Bus, st.BUS_NONE, tag_list));
    private.chip_name = @ptrFromInt(ub.GetTagData(st.PART_ChipName, 0, tag_list));
    // The picture the firmware left: what a UEFI firmware lit, and the
    // emulator's framebuffer that is configured before the system starts.
    if (device.chip == st.CHIP_UEFI_FB or device.chip == st.CHIP_QEMU_RAMFB) device.flags |= rtg.drivers.RTGDVF_FIRMWARE;
    var at = copyText(&private.name_buf, 0, "panel.");
    at = copyNumber(&private.name_buf, at, rb.panel_serial, 1, 10);
    private.name_buf[at] = 0;
    rb.panel_serial += 1;
    sys.AddTail(&rb.devices, &device.node);
    return private;
}

/// A device for a function on PCI, made and put at the end of the list.
/// Null without memory.
///
/// INPUTS:
/// - `rb` - the library; the device list's lock is held.
/// - `function` - the function, as pci.library keeps it.
fn addFunction(rb: *RtgBase, function: *pci.PCIDevice) ?*Private {
    const private = allocate(rb) orelse return null;
    const device = &private.device;
    device.kind = rtg.drivers.RTGDEV_PCI;
    device.pci = function;
    device.chip = st.CHIP_NONE;
    device.bus = st.BUS_PCI;
    // "pci.01:00.0", and the host bridge in front where it is not the
    // first: "pci.1:01:00.0".
    var at = copyText(&private.name_buf, 0, "pci.");
    if (function.segment != 0) {
        at = copyNumber(&private.name_buf, at, function.segment, 1, 16);
        at = copyText(&private.name_buf, at, ":");
    }
    at = copyNumber(&private.name_buf, at, function.bus, 2, 16);
    at = copyText(&private.name_buf, at, ":");
    at = copyNumber(&private.name_buf, at, function.device, 2, 16);
    at = copyText(&private.name_buf, at, ".");
    at = copyNumber(&private.name_buf, at, function.function, 1, 16);
    private.name_buf[at] = 0;
    rb.sys_base.AddTail(&rb.devices, &device.node);
    return private;
}

/// A device's record, cleared, its node named by its own buffer. Null
/// without memory.
fn allocate(rb: *RtgBase) ?*Private {
    const sys = rb.sys_base;
    const memory = sys.AllocVec(@sizeOf(Private), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const private: *Private = @ptrCast(@alignCast(memory));
    private.* = .{};
    private.device.node.name = @ptrCast(&private.name_buf);
    sys.NewList(&private.boards);
    return private;
}

/// `text` into `buffer` from `at` on, as far as it fits with a NUL to
/// follow; where the next character goes.
fn copyText(buffer: []u8, at: usize, text: []const u8) usize {
    var index = at;
    for (text) |char| {
        if (index + 1 >= buffer.len) break;
        buffer[index] = char;
        index += 1;
    }
    return index;
}

/// `value` into `buffer` from `at` on in `radix`, at least `digits` wide
/// with zeroes in front, as far as it fits with a NUL to follow; where
/// the next character goes.
fn copyNumber(buffer: []u8, at: usize, value: u32, digits: usize, radix: u32) usize {
    var text: [10]u8 = undefined;
    var count: usize = 0;
    var left = value;
    while (left != 0 or count < digits) {
        text[count] = "0123456789abcdef"[left % radix];
        count += 1;
        left /= radix;
    }
    var index = at;
    while (count > 0 and index + 1 < buffer.len) {
        count -= 1;
        buffer[index] = text[count];
        index += 1;
    }
    return index;
}

/// The machine's own devices put on the list, once: the board's panel
/// parts in the list's order, then the display functions on PCI where the
/// machine has pci.library, and for each device the firmware lit the
/// function its memory lies in.
///
/// INPUTS:
/// - `rb` - the library; the device list's lock is held.
pub fn listMachine(rb: *RtgBase) void {
    if (rb.devices_listed) return;
    rb.devices_listed = true;
    const sys = rb.sys_base;
    if (rb.expansion_base) |eb| {
        var found = eb.FindBoardPart(null, st.PARTKIND_PANEL, st.CHIP_ANY);
        while (found) |part| : (found = eb.FindBoardPart(part, st.PARTKIND_PANEL, st.CHIP_ANY)) {
            _ = addPart(rb, part, part.tags);
        }
    }
    // The library stays open: the devices on PCI are its functions.
    if (rb.pci_base == null) rb.pci_base = @ptrCast(sys.OpenLibrary(pci.PCINAME, 1));
    if (rb.pci_base) |pb| {
        var found = pb.FindPCIClass(null, display_class, class_mask);
        while (found) |function| : (found = pb.FindPCIClass(function, display_class, class_mask)) {
            _ = addFunction(rb, function);
        }
    }
    var node = rb.devices.first();
    while (node) |one| : (node = one.next()) {
        const device = deviceOf(one);
        if (device.flags & rtg.drivers.RTGDVF_FIRMWARE != 0) device.behind = functionAround(rb, device);
    }
}

/// The device on PCI whose memory holds a firmware framebuffer's address
/// (its `PART_Address`), or null where none does.
fn functionAround(rb: *RtgBase, lit: *rtg.RtgDevice) ?*rtg.RtgDevice {
    const address: u64 = rb.utility_base.GetTagData(st.PART_Address, 0, lit.tags);
    if (address == 0) return null;
    var node = rb.devices.first();
    while (node) |one| : (node = one.next()) {
        const device = deviceOf(one);
        const function = device.pci orelse continue;
        for (function.bars) |bar| {
            if (bar.size == 0 or bar.flags & pci.PCIBAR_IO != 0) continue;
            if (address >= bar.address and address - bar.address < bar.size) return device;
        }
    }
    return null;
}

// --- who takes a device -----------------------------------------------------

/// The firmware's picture handed over: a driver has made a board of a
/// device, and every board of a firmware device that lies behind it is
/// retired - it says it is gone, shows nothing and leaves the walk; its
/// handle stays good.
///
/// INPUTS:
/// - `rb` - the library; the device list's lock is held.
/// - `taken` - the device a driver just took.
fn handOver(rb: *RtgBase, taken: *rtg.RtgDevice) void {
    var node = rb.devices.first();
    while (node) |one| : (node = one.next()) {
        const lit = deviceOf(one);
        if (lit.flags & rtg.drivers.RTGDVF_FIRMWARE == 0 or lit.behind != taken) continue;
        // A retired board leaves its device's list.
        while (privateOf(lit).boards.first()) |link| boards.retire(rb, boards.ofDeviceLink(link));
    }
}

/// Whether a firmware's framebuffer lies behind a device.
///
/// INPUTS:
/// - `rb` - the library; the device list's lock is held.
/// - `device` - the device.
pub fn hasFirmwareBehind(rb: *RtgBase, device: *const rtg.RtgDevice) bool {
    var node = rb.devices.first();
    while (node) |one| : (node = one.next()) {
        const lit = deviceOf(one);
        if (lit.flags & rtg.drivers.RTGDVF_FIRMWARE != 0 and lit.behind == device) return true;
    }
    return false;
}

/// How closely an entry names a device: 2 for a chip, or a vendor with a
/// device; 1 for a bus, a vendor alone or a class; null when a field it
/// counts is not the device's.
///
/// INPUTS:
/// - `match` - one entry of a driver's table; not its end.
/// - `device` - the device.
pub fn closeness(match: *const rtg.RtgMatch, device: *const rtg.RtgDevice) ?u32 {
    const m = rtg.drivers;
    const fields = match.fields;
    if (fields & m.RTGMATCH_CHIP != 0 and (device.kind != m.RTGDEV_PART or device.chip != match.chip)) return null;
    if (fields & m.RTGMATCH_BUS != 0 and device.bus != match.bus) return null;
    const on_pci = fields & (m.RTGMATCH_VENDOR | m.RTGMATCH_DEVICE | m.RTGMATCH_CLASS) != 0;
    if (on_pci) {
        const function = device.pci orelse return null;
        if (fields & m.RTGMATCH_VENDOR != 0 and function.vendor_id != match.vendor) return null;
        if (fields & m.RTGMATCH_DEVICE != 0 and function.device_id != match.device) return null;
        if (fields & m.RTGMATCH_CLASS != 0 and (function.class_code & match.class_mask) != (match.class_code & match.class_mask)) return null;
    }
    const exact = fields & m.RTGMATCH_CHIP != 0 or
        (fields & m.RTGMATCH_VENDOR != 0 and fields & m.RTGMATCH_DEVICE != 0);
    return if (exact) 2 else 1;
}

/// A driver that may take a device, and how well its table names it.
pub const Candidate = struct {
    driver: *rtg.RtgDriver,
    closeness: u32,
    priority: i32,

    /// Whether `one` is asked before `other`: the closer, then the entry's
    /// higher priority. Two that are equal stay in the list's order.
    fn before(one: Candidate, other: Candidate) bool {
        if (one.closeness != other.closeness) return one.closeness > other.closeness;
        return one.priority > other.priority;
    }
};

/// The most drivers one device is offered to.
pub const max_candidates = 8;

/// The best entry of a driver's table for a device, or null when no entry
/// names it.
///
/// INPUTS:
/// - `driver` - the driver.
/// - `device` - the device.
pub fn bestEntry(driver: *rtg.RtgDriver, device: *const rtg.RtgDevice) ?Candidate {
    const table = driver.spec.matches orelse return null;
    var best: ?Candidate = null;
    var index: usize = 0;
    while (table[index].fields != 0) : (index += 1) {
        const close = closeness(&table[index], device) orelse continue;
        const found = Candidate{ .driver = driver, .closeness = close, .priority = table[index].priority };
        if (best == null or found.before(best.?)) best = found;
    }
    return best;
}

/// The drivers of one kind whose table names a device, the one to ask
/// first in front; how many there are.
///
/// INPUTS:
/// - `rb` - the library; the driver list's lock is held.
/// - `device` - the device.
/// - `kind` - `RTGDT_BOARD` for the drivers that take it, `RTGDT_TRANSPORT`
///   for the ones that make the bus it is reached over.
/// - `into` - where they go.
pub fn candidates(rb: *RtgBase, device: *const rtg.RtgDevice, kind: u32, into: *[max_candidates]Candidate) usize {
    var count: usize = 0;
    var node = rb.drivers.first();
    while (node) |one| : (node = one.next()) {
        const driver = drivers.driverOf(one);
        if (driver.spec.kind & kind == 0) continue;
        const found = bestEntry(driver, device) orelse continue;
        if (count == max_candidates) break;
        // In its place among the ones before it: the list's order is the
        // drivers' priority, and holds among equals.
        var at = count;
        while (at > 0 and found.before(into[at - 1])) : (at -= 1) into[at] = into[at - 1];
        into[at] = found;
        count += 1;
    }
    return count;
}

/// Offers a device no driver has to the drivers whose table names it, the
/// closest first, until one takes it.
///
/// INPUTS:
/// - `rb` - the library; the device list's lock is held.
/// - `device` - the device.
///
/// RESULT:
/// How many boards the driver that took it made; 0 when none took it.
pub fn offer(rb: *RtgBase, device: *rtg.RtgDevice) u32 {
    const sys = rb.sys_base;
    const private = privateOf(device);
    if (device.driver != null) return 0;
    // What its settings line says, and whether a firmware's picture lies
    // behind it, in front of its tags.
    settings.dress(rb, device);
    // Held through the drivers' attach: none leaves the list meanwhile.
    sys.ObtainSemaphore(&rb.driver_lock);
    defer sys.ReleaseSemaphore(&rb.driver_lock);
    var asked: [max_candidates]Candidate = undefined;
    const count = candidates(rb, device, rtg.drivers.RTGDT_BOARD, &asked);
    for (asked[0..count]) |candidate| {
        const driver = candidate.driver;
        const attach = driver.spec.ops.attach orelse continue;
        private.offered_to = driver;
        const code = attach(driver, device, device.tags);
        private.offered_to = null;
        if (code != err.RTGERR_OK) {
            // What it made and did not delete goes: it has declined.
            while (private.boards.first()) |link| boards.free(rb, boards.ofDeviceLink(link));
            device.driver_data = null;
            continue;
        }
        device.driver = driver;
        driver.devices += 1;
        var made: u32 = 0;
        var link = private.boards.first();
        while (link) |one| : (link = one.next()) {
            boards.list(rb, boards.ofDeviceLink(one));
            made += 1;
        }
        if (made != 0) handOver(rb, device);
        return made;
    }
    return 0;
}
