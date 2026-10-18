// SPDX-License-Identifier: MIT
//! ResetPCIDevice: a function reset on its own, and what it was set up
//! with put back.

const sdk = @import("sdk");
const pci = sdk.pci;
const PCIBase = @import("../pci_base.zig").PCIBase;
const _host = @import("../host/_host.zig");
const Entry = _host.Entry;
const scan = @import("../scan/scan.zig");
const _state = @import("../host/_state.zig");
const Delay = @import("../delay.zig").Delay;

/// A function reset on its own, and what the library and its driver set
/// up in it put back.
///
/// SYNOPSIS:
/// ```zig
/// fn ResetPCIDevice(base: *PCIBase, device: *pci.PCIDevice) bool
/// ```
///
/// SINCE: 2.0. LVO -76.
///
/// INPUTS:
/// - `device` - a function the caller has claimed.
///
/// RESULT:
/// True when the function was reset and answers again; false when it
/// cannot be reset on its own, or did not answer within a second of its
/// reset.
///
/// BEHAVIOR:
/// The first way the function has is taken, as Linux takes them:
///
/// 1. its function level reset (PCI Express, PCI_EXP_DEVCAP_FLR);
/// 2. the same through the Advanced Features capability (PCI);
/// 3. a trip to D3hot and back, for a function that resets itself
///    there (power management, no PCI_PM_CTRL_NO_SOFT_RESET);
/// 4. a reset of the bus it is on, through the bridge above it - only
///    where it is the one function on that bus.
///
/// Before it, its configuration is kept - its command, BARs, expansion
/// ROM, cache line, interrupt line, and its PCI Express control - and
/// its decoding and bus mastering switched off. A function that has
/// lost it already, reset behind the library's back, is given what the
/// library set up in it instead. A function level reset
/// waits up to 700 ms for the transactions the function has out to be
/// done. The reset is given 100 ms (a bus reset its link's training
/// first, and 1 s on conventional PCI), and the function up to a second
/// more to answer its configuration; then all that was kept is written
/// back, the command last, and its MSI or MSI-X as AllocPCIVectors set
/// it up, each vector let through that has a server.
///
/// CONTEXT:
/// - Waits: yes, up to two seconds, on timer.device.
/// - Interrupts: no.
/// - Locks: none taken.
/// - Process: a Task: it waits on a message port of its own.
///
/// OWNERSHIP:
/// The function stays the caller's.
///
/// NOTES:
/// What a reset clears of the function's own - its registers behind the
/// BARs, its queues - is its driver's to set up again; so is its bus
/// mastering, where the function had lost its configuration before. Its servers stay
/// on their lines and vectors: what the function signals before its
/// driver has set it up again, they answer.
///
/// BUGS:
/// A PCI-to-PCI bridge is not reset: what is behind it would lose what
/// the library set up in it.
///
/// SEE ALSO:
/// `ClaimPCIDevice`, `AllocPCIVectors`
///
/// EXAMPLES:
/// ```zig
/// if (!pb.ResetPCIDevice(function)) return error.NoReset;
/// try unit.start();
/// ```
pub fn ResetPCIDevice(base: *PCIBase, device: *pci.PCIDevice) bool {
    if (device.header_type != pci.PCI_HEADER_NORMAL) return false;
    const entry = _host.entryOf(device);
    const method = methodOf(base, entry) orelse return false;
    var delay = Delay.open(base.sys_base) orelse return false;
    defer delay.close();

    const saved = if (_state.lost(entry, &entry.kept)) entry.kept else _state.save(entry);
    write(entry, pci.PCI_COMMAND, 2, pci.PCI_COMMAND_INTX_DISABLE);
    const reset = switch (method) {
        .flr => flr(entry, &delay),
        .af => |cap| af(entry, &delay, cap),
        .pm => pm(entry, &delay),
        .bus => bus(entry, &delay),
    };
    const back = reset and ready(entry, &delay);
    if (back) _state.restore(entry, &saved);
    return back;
}

const Method = union(enum) {
    flr,
    /// Where the Advanced Features capability is.
    af: u32,
    pm,
    bus,
};

/// How the function can be reset on its own, or null.
fn methodOf(base: *PCIBase, entry: *Entry) ?Method {
    const exp = entry.cap_express;
    if (exp != 0 and read(entry, exp + pci.PCI_EXP_DEVCAP, 4) & pci.PCI_EXP_DEVCAP_FLR != 0) return .flr;
    const space = _host.Space{ .host = entry.host };
    if (scan.findCapability(space, _host.addressOf(&entry.device), pci.PCI_CAP_ID_AF, 0)) |cap| {
        const has = read(entry, cap + pci.PCI_AF_CAP, 1);
        if (has & pci.PCI_AF_CAP_TP != 0 and has & pci.PCI_AF_CAP_FLR != 0) return .{ .af = cap };
    }
    const power = entry.cap_pm;
    if (power != 0 and read(entry, power + pci.PCI_PM_CTRL, 2) & pci.PCI_PM_CTRL_NO_SOFT_RESET == 0) return .pm;
    if (aloneBelow(base, &entry.device)) return .bus;
    return null;
}

/// Whether the function is the one on the bus behind the bridge above
/// it.
fn aloneBelow(base: *PCIBase, device: *pci.PCIDevice) bool {
    const parent = device.parent orelse return false;
    var it = base.first;
    while (it) |other| : (it = other.next) {
        if (other != device and other.parent == parent) return false;
    }
    return true;
}

/// What a waiting for transactions gives a function: the register is
/// asked at once, then after 100, 200 and 400 ms.
fn waitPending(entry: *Entry, delay: *Delay, offset: u32, bit: u32) void {
    var i: u5 = 0;
    while (i < 4) : (i += 1) {
        if (i > 0) delay.wait((@as(u32, 1) << (i - 1)) * 100_000);
        if (read(entry, offset, 2) & bit == 0) return;
    }
}

fn flr(entry: *Entry, delay: *Delay) bool {
    const exp = entry.cap_express;
    waitPending(entry, delay, exp + pci.PCI_EXP_DEVSTA, pci.PCI_EXP_DEVSTA_TRPND);
    const control = read(entry, exp + pci.PCI_EXP_DEVCTL, 2);
    write(entry, exp + pci.PCI_EXP_DEVCTL, 2, control | pci.PCI_EXP_DEVCTL_BCR_FLR);
    delay.wait(reset_us);
    return true;
}

fn af(entry: *Entry, delay: *Delay, cap: u32) bool {
    // The status is the byte after the control.
    waitPending(entry, delay, cap + pci.PCI_AF_CTRL, @as(u32, pci.PCI_AF_STATUS_TP) << 8);
    write(entry, cap + pci.PCI_AF_CTRL, 1, pci.PCI_AF_CTRL_FLR);
    delay.wait(reset_us);
    return true;
}

fn pm(entry: *Entry, delay: *Delay) bool {
    const offset = entry.cap_pm + pci.PCI_PM_CTRL;
    const control = read(entry, offset, 2) & ~@as(u32, pci.PCI_PM_CTRL_STATE_MASK);
    write(entry, offset, 2, control | 3);
    delay.wait(d3_us);
    write(entry, offset, 2, control);
    delay.wait(d3_us);
    return true;
}

fn bus(entry: *Entry, delay: *Delay) bool {
    const parent = _host.entryOf(entry.device.parent.?);
    const control = read(parent, pci.PCI_BRIDGE_CONTROL, 2);
    write(parent, pci.PCI_BRIDGE_CONTROL, 2, control | pci.PCI_BRIDGE_CTL_BUS_RESET);
    delay.wait(bus_reset_us);
    write(parent, pci.PCI_BRIDGE_CONTROL, 2, control & ~@as(u32, pci.PCI_BRIDGE_CTL_BUS_RESET));
    if (parent.cap_express == 0) {
        delay.wait(conventional_us);
        return true;
    }
    if (!linkBack(parent, delay)) return false;
    delay.wait(reset_us);
    return true;
}

/// Whether the link below a PCI Express port trained again after its
/// bus was reset, where it can say; a port that cannot is given 100 ms.
fn linkBack(port: *Entry, delay: *Delay) bool {
    const host = port.host;
    const own = port.device.parent == null and _host.hasLink(host);
    const exp = port.cap_express;
    const reports = read(port, exp + pci.PCI_EXP_LNKCAP, 4) & pci.PCI_EXP_LNKCAP_DLLLARC != 0;
    if (!own and !reports) {
        delay.wait(reset_us);
        return true;
    }
    // The link is down at once; what the port says before it is, is
    // what it said before the reset.
    delay.wait(retrain_us);
    var waited: u32 = retrain_us;
    while (true) {
        const up = if (own) _host.linkUp(host) else read(port, exp + pci.PCI_EXP_LNKSTA, 2) & pci.PCI_EXP_LNKSTA_DLLLA != 0;
        if (up) return true;
        if (waited >= ready_us) return false;
        delay.wait(step_us);
        waited += step_us;
    }
}

/// Whether the function answers its configuration again, within a
/// second: not all ones, nor asking to be asked again.
fn ready(entry: *Entry, delay: *Delay) bool {
    var waited: u32 = 0;
    while (true) {
        const vendor = read(entry, pci.PCI_VENDOR_ID, 2);
        if (vendor != 0xFFFF and vendor != 0x0001) return true;
        if (waited >= ready_us) return false;
        delay.wait(step_us);
        waited += step_us;
    }
}

const reset_us: u32 = 100_000;
const d3_us: u32 = 10_000;
const bus_reset_us: u32 = 2_000;
const retrain_us: u32 = 20_000;
const conventional_us: u32 = 1_000_000;
const ready_us: u32 = 1_000_000;
const step_us: u32 = 10_000;

fn read(entry: *Entry, offset: u32, size: u32) u32 {
    return _host.read(entry.host, _host.addressOf(&entry.device), offset, size);
}

fn write(entry: *Entry, offset: u32, size: u32, value: u32) void {
    _host.write(entry.host, _host.addressOf(&entry.device), offset, size, value);
}
