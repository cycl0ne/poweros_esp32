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
//! **A function** is an `Entry`: the `PCIDevice` programs read, the host
//! it is behind, and its INTx line at the host bridge.

const sdk = @import("sdk");
const exec = sdk.exec;
const pci = sdk.pci;
const st = sdk.expansion.systemtags;
const ExecBase = sdk.interface.exec.ExecBase;
const scan = @import("../scan/scan.zig");
const ecam = @import("ecam.zig");
const jh7110 = @import("jh7110.zig");
const host_module = @This();

pub const Address = scan.Address;

/// How many host bridges the library keeps.
pub const max_hosts = 4;

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
    windows: scan.Windows = .{},
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
};

/// A function, as the library keeps it.
pub const Entry = struct {
    device: pci.PCIDevice,
    host: *Host,
    /// Its INTx line at the host bridge, 1 to 4; 0 for none.
    root_pin: u8 = 0,
};

pub fn entryOf(device: *pci.PCIDevice) *Entry {
    return @fieldParentPtr("device", device);
}

pub fn addressOf(device: *const pci.PCIDevice) Address {
    return .{ .bus = device.bus, .device = device.device, .function = device.function };
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

/// The bridge brought up, as its chip needs: false if it cannot be used.
/// `delay` waits out `us` microseconds.
pub fn bringUp(host: *Host, delay: anytype) bool {
    for (&host.lines) |*line| line.init(.interrupt);
    return switch (host.chip) {
        .ecam => true,
        .jh7110 => jh7110.bringUp(host, delay),
    };
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
