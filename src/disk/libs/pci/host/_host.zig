// SPDX-License-Identifier: MIT
//! A host bridge as the library keeps it: the board's PCI part it is,
//! its configuration space and its windows, and the functions behind it.
//!
//! **Configuration space** is reached the same way behind both bridges
//! the library knows, ECAM: a function's 4 KiB at bus << 20 | device <<
//! 15 | function << 12 in the bridge's window, read and written 1, 2 or
//! 4 bytes at a time. What differs is the chip's (`ecam.zig`,
//! `jh7110.zig`): how the bridge is brought up, what of its own space is
//! hidden, and where a function's INTx line ends up.
//!
//! **Bringing the bridges up** goes in steps, which the library takes
//! for every bridge at once - so that the waits PCI Express asks for are
//! waited once, not once for each: `start` (everything up to PERST#,
//! which is held), `release` (PERST# let go, 100 ms after `start`), and
//! `linkUp`, asked from 100 ms after that for up to a second.
//!
//! **Message-signalled interrupts** are the host bridge's: it takes the
//! functions' messages at one address on the bus (`msi_address`, 0 for a
//! bridge that takes none) and tells `msi_count` vectors apart by the
//! data they carry. AllocPCIVectors gives a function a run of them; each
//! has its chain of servers, which the bridge's interrupt runs.
//!
//! **A function** is an `Entry`: the `PCIDevice` programs read, the host
//! it is behind, its INTx line at the host bridge, where its capabilities
//! are, and the vectors it was given.

const sdk = @import("sdk");
const exec = sdk.exec;
const pci = sdk.pci;
const st = sdk.expansion.systemtags;
const ExecBase = sdk.interface.exec.ExecBase;
const scan = @import("../scan/scan.zig");
const place = @import("../scan/place.zig");
const _state = @import("_state.zig");
const ecam = @import("ecam.zig");
const jh7110 = @import("jh7110.zig");
const host_module = @This();

pub const Address = scan.Address;

/// How many host bridges the library keeps.
pub const max_hosts = 4;
/// The most vectors a host bridge tells apart.
pub const max_vectors = 32;

pub const Chip = enum { ecam, jh7110 };

pub const Host = struct {
    sys: *ExecBase,
    chip: Chip,
    /// Its place among the board's PCI parts (PCIDevice.segment).
    segment: u8,
    /// Which of the chip's bridges (PART_BusUnit).
    unit: u32 = 0,
    /// The bridge's own registers (PART_Address), its configuration space
    /// (PART_PciConfig).
    registers: usize = 0,
    config: usize = 0,
    windows: place.Windows = .{},
    /// PART_Irq.
    irq: u32 = 0,
    /// The line that holds what is plugged in in reset (a BoardPin).
    perst: usize = 0,
    /// Whether the link below a root port came up: past the root port's
    /// own bus nothing is asked until it has.
    link_up: bool = true,
    /// The servers on each of INTA to INTD, where the bridge gathers them
    /// on one interrupt (JH7110), and the server of its own on it that
    /// runs them.
    lines: [4]exec.List = undefined,
    gather: exec.Interrupt = .{},
    gathering: bool = false,
    /// Message-signalled interrupts (see the top of the file): where on
    /// the bus they go, how many vectors there are, which are given to a
    /// function (a bit each, under the claim lock), and each one's
    /// servers.
    msi_address: u64 = 0,
    msi_count: u8 = 0,
    msi_used: u32 = 0,
    vectors: [max_vectors]exec.List = undefined,
};

/// A function, as the library keeps it.
pub const Entry = struct {
    device: pci.PCIDevice,
    host: *Host,
    /// Its INTx line at the host bridge, 1 to 4; 0 for none.
    root_pin: u8 = 0,
    /// Where its capabilities are; 0 for one it has not.
    cap_pm: u8 = 0,
    cap_msi: u8 = 0,
    cap_msix: u8 = 0,
    cap_express: u8 = 0,
    /// The first of the host's vectors it was given (`device.vectors` of
    /// them, from AllocPCIVectors), and where the processor reaches its
    /// MSI-X table while it has MSI-X.
    vector_base: u8 = 0,
    msix_table: usize = 0,
    /// What the walk set up in it, for a function with a PCI_HEADER_NORMAL
    /// header: ClaimPCIDevice puts it back should the function have been
    /// reset since (`_state.zig`).
    kept: _state.Saved = .{},
};

pub fn entryOf(device: *pci.PCIDevice) *Entry {
    return @fieldParentPtr("device", device);
}

pub fn addressOf(device: *const pci.PCIDevice) Address {
    return .{ .bus = device.bus, .device = device.device, .function = device.function };
}

/// Whether what a function behind the chip's bridge reads and writes in
/// RAM sees the processors' caches. QEMU's devices reach the guest's
/// memory as its processors do. The JH7110's do too, measured on a
/// VisionFive 2 with an NVMe SSD: what it wrote was read through dirty
/// lines and through stale clean ones, and it took a command the
/// processor had not written back; Linux's device tree marks none of the
/// chip's devices dma-noncoherent either.
pub fn coherent(chip: Chip) bool {
    return switch (chip) {
        .ecam, .jh7110 => true,
    };
}

/// The chip a board part names, or null for one the library does not
/// know.
pub fn chipOf(chip: u32) ?Chip {
    return switch (chip) {
        st.CHIP_PCI_ECAM => .ecam,
        st.CHIP_JH7110_PCIE => .jh7110,
        else => null,
    };
}

/// The bridge brought up as far as PERST#, which is held: false if it
/// cannot be used.
pub fn start(host: *Host) bool {
    for (&host.lines) |*line| line.init(.interrupt);
    for (&host.vectors) |*list| list.init(.interrupt);
    return switch (host.chip) {
        .ecam => true,
        .jh7110 => jh7110.start(host),
    };
}

/// Whether the bridge holds PERST#, and its link is to be waited for.
pub fn hasLink(host: *const Host) bool {
    return switch (host.chip) {
        .ecam => false,
        .jh7110 => true,
    };
}

/// PERST# let go.
pub fn release(host: *Host) void {
    switch (host.chip) {
        .ecam => {},
        .jh7110 => jh7110.release(host),
    }
}

/// Whether the link below the bridge is up (`host.link_up` set to it).
pub fn linkUp(host: *Host) bool {
    host.link_up = switch (host.chip) {
        .ecam => true,
        .jh7110 => jh7110.linkUp(host),
    };
    return host.link_up;
}

/// What PCI Express gives a link: PERST# held 100 ms (T_PVPERL), 100 ms
/// more before the first configuration request, and a second to train.
pub const perst_us: u32 = 100_000;
pub const settle_us: u32 = 100_000;
pub const train_us: u32 = 1_000_000;
pub const train_step_us: u32 = 100_000;

/// The bridges brought up side by side, from `start` on: every one's
/// waits waited once. `delay` waits out `us` microseconds.
pub fn bringUp(hosts: []const *Host, delay: anytype) void {
    var links = false;
    for (hosts) |host| links = links or hasLink(host);
    if (!links) return;
    delay.wait(perst_us);
    for (hosts) |host| release(host);
    delay.wait(settle_us);
    var waited: u32 = 0;
    while (true) {
        var all = true;
        for (hosts) |host| {
            if (!linkUp(host)) all = false;
        }
        if (all or waited >= train_us) return;
        delay.wait(train_step_us);
        waited += train_step_us;
    }
}

/// The devices asked on the bridge's own bus.
pub fn rootDevices(host: *const Host) u8 {
    return switch (host.chip) {
        .ecam => 32,
        .jh7110 => 1,
    };
}

/// `size` bytes of a function's configuration space at `offset`.
pub fn read(host: *Host, at: Address, offset: u32, size: u32) u32 {
    if (!reachable(host, at)) return all_ones[sizeIndex(size)];
    if (hidden(host, at, offset)) return 0;
    const address = host.config + ecamOffset(at, offset);
    return switch (size) {
        1 => @as(*volatile u8, @ptrFromInt(address)).*,
        2 => @as(*volatile u16, @ptrFromInt(address)).*,
        else => @as(*volatile u32, @ptrFromInt(address)).*,
    };
}

/// `size` bytes of `value` into a function's configuration space at
/// `offset`.
pub fn write(host: *Host, at: Address, offset: u32, size: u32, value: u32) void {
    if (!reachable(host, at) or hidden(host, at, offset)) return;
    const address = host.config + ecamOffset(at, offset);
    switch (size) {
        1 => @as(*volatile u8, @ptrFromInt(address)).* = @truncate(value),
        2 => @as(*volatile u16, @ptrFromInt(address)).* = @truncate(value),
        else => @as(*volatile u32, @ptrFromInt(address)).* = value,
    }
}

const all_ones = [3]u32{ 0xFF, 0xFFFF, 0xFFFF_FFFF };

fn sizeIndex(size: u32) usize {
    return switch (size) {
        1 => 0,
        2 => 1,
        else => 2,
    };
}

fn ecamOffset(at: Address, offset: u32) usize {
    return (@as(usize, at.bus) << 20) | (@as(usize, at.device) << 15) | (@as(usize, at.function) << 12) | (offset & 0xFFF);
}

/// Whether a function can be asked: below a root port whose link is
/// down nothing is.
fn reachable(host: *const Host, at: Address) bool {
    return host.link_up or at.bus == 0;
}

/// Registers of the bridge's own that the walk is not to see.
fn hidden(host: *const Host, at: Address, offset: u32) bool {
    return switch (host.chip) {
        .ecam => false,
        .jh7110 => jh7110.hidden(at, offset),
    };
}

/// The exec interrupt number a function's INTx line ends up on, given
/// the device on the bridge's bus it is behind and its line there.
pub fn interruptOf(host: *const Host, root_device: u8, root_pin: u8) u32 {
    if (root_pin == 0) return 0;
    return switch (host.chip) {
        .ecam => ecam.interruptOf(host, root_device, root_pin),
        .jh7110 => host.irq,
    };
}

/// `server` on a function's line.
pub fn addServer(entry: *Entry, server: *exec.Interrupt) void {
    const host = entry.host;
    switch (host.chip) {
        .ecam => host.sys.AddIntServer(entry.device.interrupt, server),
        .jh7110 => jh7110.addServer(host, entry.root_pin, server),
    }
}

/// `server` off a function's line.
pub fn remServer(entry: *Entry, server: *exec.Interrupt) void {
    const host = entry.host;
    switch (host.chip) {
        .ecam => host.sys.RemIntServer(entry.device.interrupt, server),
        .jh7110 => jh7110.remServer(host, entry.root_pin, server),
    }
}

/// `server` on the host's vector `vector`.
pub fn addVectorServer(host: *Host, vector: u8, server: *exec.Interrupt) void {
    switch (host.chip) {
        .ecam => {},
        .jh7110 => jh7110.addVectorServer(host, vector, server),
    }
}

/// `server` off the host's vector `vector`.
pub fn remVectorServer(host: *Host, vector: u8, server: *exec.Interrupt) void {
    switch (host.chip) {
        .ecam => {},
        .jh7110 => {
            // The server's node knows its chain.
            _ = vector;
            jh7110.remVectorServer(host, server);
        },
    }
}

/// Every server off the host's vectors `first` to `first + count - 1`.
pub fn clearVectors(host: *Host, first: u8, count: u16) void {
    switch (host.chip) {
        .ecam => {},
        .jh7110 => jh7110.clearVectors(host, first, count),
    }
}

/// A run of `count` of the host's vectors that are free, its first a
/// multiple of `alignment`, taken; its first, or null. Under the claim
/// lock.
pub fn takeVectors(host: *Host, count: u32, alignment: u32) ?u8 {
    if (count == 0 or count > host.msi_count) return null;
    const run: u32 = if (count == 32) 0xFFFF_FFFF else (@as(u32, 1) << @intCast(count)) - 1;
    var first: u32 = 0;
    while (first + count <= host.msi_count) : (first += alignment) {
        const bits = run << @intCast(first);
        if (host.msi_used & bits != 0) continue;
        host.msi_used |= bits;
        return @intCast(first);
    }
    return null;
}

/// The host's vectors `first` to `first + count - 1` free again. Under
/// the claim lock.
pub fn giveVectors(host: *Host, first: u8, count: u16) void {
    if (count == 0) return;
    const run: u32 = if (count >= 32) 0xFFFF_FFFF else (@as(u32, 1) << @intCast(count)) - 1;
    host.msi_used &= ~(run << @intCast(first));
}

/// The configuration space, as the walk asks it (scan.zig).
pub const Space = struct {
    host: *Host,

    pub fn read(space: Space, at: Address, offset: u32, size: u32) u32 {
        return host_module.read(space.host, at, offset, size);
    }

    pub fn write(space: Space, at: Address, offset: u32, size: u32, value: u32) void {
        host_module.write(space.host, at, offset, size, value);
    }
};
