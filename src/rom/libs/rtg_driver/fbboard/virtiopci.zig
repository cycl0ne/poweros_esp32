// SPDX-License-Identifier: MPL-2.0
//! The virtio GPU on PCI Express, which is how a machine with no
//! memory-mapped virtio transports has one: `-device virtio-gpu-pci`.
//!
//! **The device is the same; only the way to its registers differs.** A
//! memory-mapped transport is one block of registers at an address the
//! board names (`virtio.zig`). On PCI the same registers are spread over
//! windows of the function's own memory, and where each window is, is in
//! the function's configuration space: a chain of vendor capabilities,
//! each naming the kind of window it describes, which BAR it is in, and
//! how far into that BAR it lies. This reads that chain and gives the
//! addresses; everything the device is then told is `virtio.zig`'s, and
//! identical for both.
//!
//! Three of those windows matter here. The common configuration holds
//! what the memory-mapped transport's registers held - the status, the
//! features, and a queue's size and its three addresses - in fields of
//! their own widths. The notify window is where a queue is told to look,
//! at a place the device gives per queue. The interrupt status window is
//! read to end an interrupt; nothing here uses the device's interrupts,
//! since the rings are looked at instead, and it is found for the sake of
//! the one case where that changes.
//!
//! **What this does to the function** is what any driver does: it claims
//! it, so that nothing else drives it, and turns on its memory decoding
//! and its bus mastering, because the device reads the queues and the
//! pictures out of RAM itself.
//!
//! Only the modern layout is taken. A device that offers no such
//! capability chain is one that speaks the arrangement of before the
//! standard was written, and is left alone rather than driven half-way.

const sdk = @import("sdk");
const exec = sdk.exec;
const pci = sdk.pci;
const ExecBase = sdk.interface.exec.ExecBase;
const PCIBase = sdk.interface.pci.PCIBase;
const PCIDevice = pci.PCIDevice;

/// Who the function is claimed by, for a listing.
const owner = "rtg-fb";

/// The vendor every virtio device has, and the two device numbers a GPU
/// may carry: the one every modern device of its kind has, and the one a
/// device that also speaks the older arrangement keeps.
const VENDOR: u32 = 0x1AF4;
const DEVICE_GPU: u32 = 0x1050;
const DEVICE_GPU_OLD: u32 = 0x1010;

/// A virtio capability, past the two bytes every capability starts with:
/// which kind of window it describes, which BAR it is in, where in that
/// BAR it begins and how long it is - and, for the notify window alone,
/// what a queue's place in it is counted in.
const CAP_TYPE = 3;
const CAP_BAR = 4;
const CAP_OFFSET = 8;
const CAP_LENGTH = 12;
const CAP_NOTIFY_MULTIPLIER = 16;

const TYPE_COMMON = 1;
const TYPE_NOTIFY = 2;
const TYPE_ISR = 3;
const TYPE_DEVICE = 4;

/// How long each window must be for what is read and written in it: the
/// common configuration's last field is a queue's device ring at 0x30.
const common_bytes = 0x38;

/// The windows a virtio function's capabilities name, and the function
/// they belong to.
pub const Windows = struct {
    /// The function, for giving it back, and pci.library as it was
    /// opened and as it is called.
    device: *PCIDevice,
    library: *exec.Library,
    base: *PCIBase,
    sys: *ExecBase,
    /// Where the registers that bring the device up are.
    common: usize = 0,
    /// Where a queue is told to look, and what a queue's place in that
    /// window is counted in.
    notify: usize = 0,
    notify_multiplier: u32 = 0,
    /// Where the interrupt status is read, and where the device's own
    /// configuration - the GPU's number of screens - is.
    isr: usize = 0,
    config: usize = 0,
};

/// The machine's first virtio GPU on PCI, claimed and switched on, with
/// its windows read out of its configuration space. Null where the
/// machine has no pci.library, no such function, one somebody else has
/// claimed, or one whose capabilities do not describe the windows this
/// drives.
pub fn find(sys: *ExecBase) ?Windows {
    const lib = sys.OpenLibrary(pci.PCINAME, 1) orelse return null;
    const base: *PCIBase = @ptrCast(lib);
    var found: ?*PCIDevice = null;
    while (base.FindPCIDevice(found, VENDOR, pci.PCI_ANY)) |device| {
        found = device;
        if (device.device_id != DEVICE_GPU and device.device_id != DEVICE_GPU_OLD) continue;
        if (base.ClaimPCIDevice(device, owner) != null) continue;
        if (windowsOf(sys, lib, base, device)) |windows| {
            switchOn(base, device);
            return windows;
        }
        base.ReleasePCIDevice(device);
    }
    sys.CloseLibrary(lib);
    return null;
}

/// The function given back and pci.library closed.
pub fn forget(windows: *Windows) void {
    windows.base.ReleasePCIDevice(windows.device);
    windows.sys.CloseLibrary(windows.library);
}

/// The function's windows, from its capability chain. Null where the
/// common configuration or the notify window is missing, which is a
/// device of the arrangement from before the standard.
fn windowsOf(sys: *ExecBase, lib: *exec.Library, base: *PCIBase, device: *PCIDevice) ?Windows {
    var windows: Windows = .{ .device = device, .library = lib, .base = base, .sys = sys };
    var at = base.FindPCICapability(device, pci.PCI_CAP_ID_VNDR, 0);
    while (at != 0) : (at = base.FindPCICapability(device, pci.PCI_CAP_ID_VNDR, at)) {
        const kind = base.ReadPCIConfig(device, at + CAP_TYPE, 1);
        const which = base.ReadPCIConfig(device, at + CAP_BAR, 1);
        const offset = base.ReadPCIConfig(device, at + CAP_OFFSET, 4);
        const length = base.ReadPCIConfig(device, at + CAP_LENGTH, 4);
        const window = windowAt(device, which, offset, length) orelse continue;
        switch (kind) {
            TYPE_COMMON => if (length >= common_bytes) {
                windows.common = window;
            },
            TYPE_NOTIFY => {
                windows.notify = window;
                windows.notify_multiplier = base.ReadPCIConfig(device, at + CAP_NOTIFY_MULTIPLIER, 4);
            },
            TYPE_ISR => windows.isr = window,
            TYPE_DEVICE => windows.config = window,
            else => {},
        }
    }
    if (windows.common == 0 or windows.notify == 0) return null;
    return windows;
}

/// Where a window lies: as far into the BAR it names as it says, if that
/// BAR is memory the firmware or the library placed and the whole window
/// is inside it.
fn windowAt(device: *PCIDevice, which: u32, offset: u32, length: u32) ?usize {
    if (which >= device.bars.len) return null;
    const bar = device.bars[which];
    if (bar.address == 0 or bar.size == 0) return null;
    if (bar.flags & pci.PCIBAR_IO != 0) return null;
    if (@as(u64, offset) + length > bar.size) return null;
    return @intCast(bar.address + offset);
}

/// The function's memory decoding and its bus mastering on: it is read
/// through its windows, and it reads the queues and the pictures out of
/// RAM itself.
fn switchOn(base: *PCIBase, device: *PCIDevice) void {
    const command = base.ReadPCIConfig(device, pci.PCI_COMMAND, 2);
    base.WritePCIConfig(device, pci.PCI_COMMAND, 2, command | pci.PCI_COMMAND_MEMORY | pci.PCI_COMMAND_MASTER);
}
