// SPDX-License-Identifier: MIT
//! ResetPCIPort: what is plugged into a PCI Express port given its
//! fundamental reset, and set up again.

const sdk = @import("sdk");
const pci = sdk.pci;
const PCIBase = @import("../pci_base.zig").PCIBase;
const _host = @import("../host/_host.zig");
const Entry = _host.Entry;
const _state = @import("../host/_state.zig");
const Delay = @import("../delay.zig").Delay;
const ready = @import("resetpcidevice.zig").ready;

/// What is plugged into the port above a function given its fundamental
/// reset, the link trained again, and what the library set up put back.
///
/// SYNOPSIS:
/// ```zig
/// fn ResetPCIPort(base: *PCIBase, device: *pci.PCIDevice) bool
/// ```
///
/// SINCE: 2.5. LVO -80.
///
/// INPUTS:
/// - `device` - a function the caller has claimed, behind the port.
///
/// RESULT:
/// True when the port was reset and the function answers again; false
/// when it was not reset, or the link or a function did not come back.
///
/// BEHAVIOR:
/// PERST# is held for 100 ms and let go, as when the library brought the
/// port up; 100 ms later the link is waited for, up to a second, and then
/// each function behind the port, up to a minute. Each function's
/// configuration is kept before - its command, BARs, expansion ROM, cache
/// line, interrupt line, and its PCI Express control - and written back,
/// with its MSI or MSI-X as AllocPCIVectors set it up.
///
/// This is the strongest reset a function can have short of the power,
/// for one that no longer answers its driver and that ResetPCIDevice's
/// ways do not reach - a function that is stuck may not take them, or
/// take them and stay stuck.
///
/// **It is not reset, and false is the answer,** where the bridge holds
/// no PERST# (a board whose PCI is only configuration space, as QEMU's
/// virt machine); for a function that is not claimed; where another
/// driver has a function behind the same port; and where a bridge is
/// behind the port, a switch whose functions the library does not keep
/// the configuration of.
///
/// The bridge's other ports, and what is behind them, see nothing of it.
///
/// CONTEXT:
/// - Waits: yes, on timer.device: 200 ms at the least, a second more for
///   the link, a minute more for each function.
/// - Interrupts: no.
/// - Locks: none taken.
/// - Process: a Task: it waits on a message port of its own.
///
/// OWNERSHIP:
/// The function stays the caller's.
///
/// NOTES:
/// The caller stops using the function first: a read of its registers
/// while the link is down holds the processor up until the bridge gives
/// up on it. Everything behind the BARs is lost, and is the driver's to
/// set up again; it does best to have given its vectors back first, and
/// to allocate them afresh.
///
/// A link that did not come back leaves the functions behind the port
/// reading all ones through ReadPCIConfig: a driver can tell it so.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ResetPCIDevice`, `ClaimPCIDevice`
///
/// EXAMPLES:
/// ```zig
/// stopController();
/// _ = pb.ResetPCIPort(function);
/// if (pb.ReadPCIConfig(function, pci.PCI_VENDOR_ID, 2) != 0xFFFF) startController();
/// ```
pub fn ResetPCIPort(base: *PCIBase, device: *pci.PCIDevice) bool {
    const entry = _host.entryOf(device);
    const host = entry.host;
    if (!_host.hasLink(host) or !mayReset(base.first, device)) return false;
    var delay = Delay.open(base.sys_base) orelse return false;
    defer delay.close();

    // What each has now is what goes back; one that no longer answers
    // has what it was last given.
    var it = base.first;
    while (it) |other| : (it = other.next) {
        if (!behindPort(other, device)) continue;
        const kept = _host.entryOf(other);
        if (answers(kept)) kept.kept = _state.save(kept);
    }

    _host.hold(host);
    delay.wait(_host.perst_us);
    _host.release(host);
    delay.wait(_host.settle_us);
    var waited: u32 = 0;
    while (!_host.linkUp(host)) : (waited += _host.train_step_us) {
        if (waited >= _host.train_us) return false;
        delay.wait(_host.train_step_us);
    }

    it = base.first;
    while (it) |other| : (it = other.next) {
        if (!behindPort(other, device)) continue;
        const kept = _host.entryOf(other);
        if (!ready(kept, &delay)) return false;
        _state.restore(kept, &kept.kept);
    }
    return true;
}

/// Whether the port above `device` may be reset for it: it is claimed
/// and no bridge's, and everything else behind the port - from `first`
/// on - is a plain function, no other driver's.
pub fn mayReset(first: ?*pci.PCIDevice, device: *const pci.PCIDevice) bool {
    if (device.header_type != pci.PCI_HEADER_NORMAL) return false;
    const owner = device.owner orelse return false;
    var it = first;
    while (it) |other| : (it = other.next) {
        if (!behindPort(other, device)) continue;
        if (other.header_type != pci.PCI_HEADER_NORMAL) return false;
        if (other.owner) |holder| {
            if (holder != owner) return false;
        }
    }
    return true;
}

/// Whether `other` is behind the same port as `device`: a host bridge
/// with a link has one, and its root port - what has no parent - is not
/// behind it.
fn behindPort(other: *const pci.PCIDevice, device: *const pci.PCIDevice) bool {
    return other.segment == device.segment and other.parent != null;
}

fn answers(entry: *Entry) bool {
    const vendor = _host.read(entry.host, _host.addressOf(&entry.device), pci.PCI_VENDOR_ID, 2);
    return vendor != 0xFFFF and vendor != 0x0001;
}
