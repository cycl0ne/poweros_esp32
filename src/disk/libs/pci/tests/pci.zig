// SPDX-License-Identifier: MIT
//! Host tests of pci.library's walk (scan/scan.zig) on buses made up
//! here: functions with configuration space, BARs that keep only the
//! bits their size lets them, and PCI-to-PCI bridges whose buses are
//! reached through the numbers the walk gives them - as QEMU's virt
//! machine has its xHCI, and as the JH7110's root port has its VL805.

const std = @import("std");
const sdk = @import("sdk");
const pci = sdk.pci;
const scan = @import("../scan/scan.zig");
const ecam = @import("../host/ecam.zig");
const _host = @import("../host/_host.zig");
const jh7110 = @import("../host/jh7110.zig");

const testing = std.testing;
const Address = scan.Address;

/// A BAR of a made-up function: its size, and what kind it is.
const Bar = struct {
    size: u64 = 0,
    io: bool = false,
    wide: bool = false,
    prefetch: bool = false,
};

/// A made-up function, and for a bridge the functions behind it.
const Function = struct {
    device: u8,
    function: u8 = 0,
    space: [64]u32 = @splat(0),
    bars: [6]Bar = @splat(.{}),
    children: []Function = &.{},

    fn make(device: u8, vendor: u16, id: u16, class_code: u32, header: u8, pin: u8) Function {
        var f = Function{ .device = device };
        f.space[0] = @as(u32, id) << 16 | vendor;
        f.space[2] = class_code << 8 | 1;
        f.space[3] = @as(u32, header) << 16;
        f.space[15] = @as(u32, pin) << 8;
        return f;
    }

    /// A PCI Express capability of port type `kind`.
    fn express(f: *Function, kind: u8) void {
        f.space[1] |= @as(u32, pci.PCI_STATUS_CAP_LIST) << 16;
        f.space[pci.PCI_CAPABILITY_LIST / 4] = 0x40;
        f.space[0x40 / 4] = (@as(u32, kind) << 4) << 16 | pci.PCI_CAP_ID_EXP;
    }

    fn bytes(f: *Function) *[256]u8 {
        return std.mem.asBytes(&f.space);
    }

    fn get(f: *Function, offset: u32, size: u32) u32 {
        var value: u32 = 0;
        for (0..size) |i| value |= @as(u32, f.bytes()[offset + i]) << @intCast(8 * i);
        return value;
    }

    fn set(f: *Function, offset: u32, size: u32, value: u32) void {
        if (offset >= pci.PCI_BASE_ADDRESS_0 and offset < pci.PCI_BASE_ADDRESS_0 + 24 and size == 4) {
            f.space[offset / 4] = f.barValue((offset - pci.PCI_BASE_ADDRESS_0) / 4, value);
            return;
        }
        for (0..size) |i| f.bytes()[offset + i] = @truncate(value >> @intCast(8 * i));
    }

    /// What a BAR keeps of `value`: the bits its size lets it, and the
    /// bits that say what it is.
    fn barValue(f: *Function, index: u32, value: u32) u32 {
        const bar = f.bars[index];
        if (bar.size == 0) {
            // The upper half of the wide BAR before it.
            if (index > 0 and f.bars[index - 1].wide) {
                const mask = ~(f.bars[index - 1].size - 1);
                return value & @as(u32, @truncate(mask >> 32));
            }
            return 0;
        }
        const mask: u32 = @truncate(~(bar.size - 1));
        if (bar.io) return (value & mask & 0xFFFF_FFFC) | 1;
        var kind: u32 = 0;
        if (bar.wide) kind |= pci.PCI_BASE_ADDRESS_MEM_TYPE_64;
        if (bar.prefetch) kind |= pci.PCI_BASE_ADDRESS_MEM_PREFETCH;
        return (value & mask & 0xFFFF_FFF0) | kind;
    }

    fn command(f: *Function) u32 {
        return f.get(pci.PCI_COMMAND, 2);
    }
};

/// A made-up configuration space: the root bus's functions, the others
/// reached through the bridges' secondary bus numbers.
const Space = struct {
    root: []Function,
    /// Every request that was asked of a function that is not there.
    misses: u32 = 0,

    fn find(space: *Space, at: Address) ?*Function {
        const list = space.busList(space.root, 0, at.bus) orelse return null;
        for (list) |*f| {
            if (f.device == at.device and f.function == at.function) return f;
        }
        return null;
    }

    /// The functions on bus `bus`, looking from `list` on bus `number`.
    fn busList(space: *Space, list: []Function, number: u8, bus: u8) ?[]Function {
        if (number == bus) return list;
        for (list) |*f| {
            if (f.get(pci.PCI_HEADER_TYPE, 1) & 0x7F != pci.PCI_HEADER_BRIDGE) continue;
            const secondary: u8 = @truncate(f.get(pci.PCI_SECONDARY_BUS, 1));
            const subordinate: u8 = @truncate(f.get(pci.PCI_SUBORDINATE_BUS, 1));
            if (secondary == 0 or bus < secondary or bus > subordinate) continue;
            if (space.busList(f.children, secondary, bus)) |found| return found;
        }
        return null;
    }

    pub fn read(space: *Space, at: Address, offset: u32, size: u32) u32 {
        const f = space.find(at) orelse {
            space.misses += 1;
            return if (size == 4) 0xFFFF_FFFF else (@as(u32, 1) << @intCast(8 * size)) - 1;
        };
        if (offset >= 256) return 0;
        return f.get(offset, size);
    }

    pub fn write(space: *Space, at: Address, offset: u32, size: u32, value: u32) void {
        const f = space.find(at) orelse return;
        if (offset >= 256) return;
        f.set(offset, size, value);
    }
};

/// What the walk found, kept in order.
const Found = struct {
    list: [16]struct { at: Address, info: scan.Function } = undefined,
    count: usize = 0,

    pub fn function(found: *Found, at: Address, info: *const scan.Function) bool {
        found.list[found.count] = .{ .at = at, .info = info.* };
        found.count += 1;
        return true;
    }
};

test "QEMU's virt: an xHCI's 64-bit BAR at the window's start, its memory decoded, its INTA rotated by its slot" {
    var root = [_]Function{
        .make(0, 0x1B36, 0x0008, 0x06_00_00, 0, 0),
        .make(1, 0x1B36, 0x000D, pci.PCI_CLASS_SERIAL_USB_XHCI, 0, 1),
    };
    root[1].bars[0] = .{ .size = 0x4000, .wide = true };
    var space = Space{ .root = &root };
    var found = Found{};
    var windows = scan.Windows{ .mem = .of(0x4000_0000, 0x4000_0000), .pref = .of(0x4_0000_0000, 0x4_0000_0000) };
    const last = scan.walk(&space, &found, &windows, .{}, 0);

    try testing.expectEqual(@as(u8, 0), last);
    try testing.expectEqual(@as(usize, 2), found.count);
    const xhci = found.list[1];
    try testing.expectEqual(@as(u8, 1), xhci.at.device);
    try testing.expectEqual(pci.PCI_CLASS_SERIAL_USB_XHCI, xhci.info.class_code);
    try testing.expectEqual(@as(u64, 0x4000_0000), xhci.info.bars[0].address);
    try testing.expectEqual(@as(u64, 0x4000), xhci.info.bars[0].size);
    try testing.expectEqual(pci.PCIBAR_64, xhci.info.bars[0].flags);
    try testing.expectEqual(@as(u32, 0x4000_0004), root[1].space[4]);
    try testing.expectEqual(@as(u32, 0), root[1].space[5]);
    try testing.expect(root[1].command() & pci.PCI_COMMAND_MEMORY != 0);
    try testing.expect(root[1].command() & pci.PCI_COMMAND_MASTER == 0);
    // Slot 1's INTA is the emulator's second source: PLIC 33.
    try testing.expectEqual(@as(u8, 1), xhci.info.root_device);
    try testing.expectEqual(@as(u8, 1), xhci.info.root_pin);
    const host = _host.Host{ .sys = undefined, .chip = .ecam, .segment = 0, .irq = 32 };
    try testing.expectEqual(@as(u32, 33), ecam.interruptOf(&host, xhci.info.root_device, xhci.info.root_pin));
    // The host bridge has no BARs and no line.
    try testing.expectEqual(@as(u8, 0), found.list[0].info.interrupt_pin);
}

test "the JH7110's root port: one device behind it, its bus numbered, its window the VL805's BAR" {
    var below = [_]Function{
        .make(0, 0x1106, 0x3483, pci.PCI_CLASS_SERIAL_USB_XHCI, 0, 1),
        // Never asked: a root port has one device below it.
        .make(1, 0x1234, 0x5678, 0x02_00_00, 0, 1),
    };
    below[0].bars[0] = .{ .size = 0x1000, .wide = true };
    var root = [_]Function{.make(0, 0x1556, 0x1111, pci.PCI_CLASS_BRIDGE_PCI, pci.PCI_HEADER_BRIDGE, 0)};
    root[0].express(pci.PCI_EXP_TYPE_ROOT_PORT);
    root[0].children = &below;
    var space = Space{ .root = &root };
    var found = Found{};
    var windows = scan.Windows{ .mem = .of(0x3000_0000, 0x0800_0000), .pref = .of(0x9_0000_0000, 0x4000_0000) };
    const last = scan.walk(&space, &found, &windows, .{ .root_devices = 1 }, 0);

    try testing.expectEqual(@as(u8, 1), last);
    try testing.expectEqual(@as(usize, 2), found.count);
    const port = &root[0];
    try testing.expectEqual(@as(u32, 0), port.get(pci.PCI_PRIMARY_BUS, 1));
    try testing.expectEqual(@as(u32, 1), port.get(pci.PCI_SECONDARY_BUS, 1));
    try testing.expectEqual(@as(u32, 1), port.get(pci.PCI_SUBORDINATE_BUS, 1));
    try testing.expectEqual(@as(u32, 0x3000), port.get(pci.PCI_MEMORY_BASE, 2));
    try testing.expectEqual(@as(u32, 0x3000), port.get(pci.PCI_MEMORY_LIMIT, 2));
    // No prefetchable memory behind it, no I/O: both windows shut.
    try testing.expectEqual(@as(u32, 0xFFF0), port.get(pci.PCI_PREF_MEMORY_BASE, 2));
    try testing.expectEqual(@as(u32, 0), port.get(pci.PCI_PREF_MEMORY_LIMIT, 2));
    try testing.expectEqual(@as(u32, 0xF0), port.get(pci.PCI_IO_BASE, 1));
    try testing.expectEqual(pci.PCI_COMMAND_MEMORY | pci.PCI_COMMAND_MASTER, @as(u16, @truncate(port.command())));

    const vl805 = found.list[1];
    try testing.expectEqual(@as(u8, 1), vl805.at.bus);
    try testing.expectEqual(@as(u16, 0x3483), vl805.info.device_id);
    try testing.expectEqual(@as(u64, 0x3000_0000), vl805.info.bars[0].address);
    try testing.expect(below[0].command() & pci.PCI_COMMAND_MEMORY != 0);
    try testing.expectEqual(@as(u8, 0), vl805.info.root_device);
    try testing.expectEqual(@as(u8, 1), vl805.info.root_pin);
    // Device 1 below the port was not asked, nor anything past bus 1.
    try testing.expectEqual(@as(u32, 0), below[1].command());
}

test "behind bridges a line is rotated by the device number at each, up to the host bridge's bus" {
    var deep = [_]Function{.make(3, 0x10EC, 0x8168, 0x02_00_00, 0, 1)};
    var middle = [_]Function{.make(1, 0x8086, 0x244E, pci.PCI_CLASS_BRIDGE_PCI, pci.PCI_HEADER_BRIDGE, 0)};
    middle[0].children = &deep;
    var root = [_]Function{.make(2, 0x8086, 0x244E, pci.PCI_CLASS_BRIDGE_PCI, pci.PCI_HEADER_BRIDGE, 0)};
    root[0].children = &middle;
    var space = Space{ .root = &root };
    var found = Found{};
    var windows = scan.Windows{ .mem = .of(0x4000_0000, 0x1000_0000) };
    const last = scan.walk(&space, &found, &windows, .{}, 0);

    try testing.expectEqual(@as(u8, 2), last);
    try testing.expectEqual(@as(usize, 3), found.count);
    // INTA of device 3 is INTD of the bridge it is behind (device 1),
    // and that is INTA again of the one on the root bus (device 2).
    const nic = found.list[2].info;
    try testing.expectEqual(@as(u8, 2), nic.root_device);
    try testing.expectEqual(@as(u8, 1), nic.root_pin);
    try testing.expectEqual(@as(u32, 1), root[0].get(pci.PCI_SECONDARY_BUS, 1));
    try testing.expectEqual(@as(u32, 2), root[0].get(pci.PCI_SUBORDINATE_BUS, 1));
    try testing.expectEqual(@as(u32, 2), middle[0].get(pci.PCI_SECONDARY_BUS, 1));
}

test "a device with more functions has each found, gaps and all" {
    var root = [_]Function{
        .make(4, 0x1AF4, 0x1000, 0x02_00_00, pci.PCI_HEADER_MULTI, 1),
        .make(4, 0x1AF4, 0x1001, 0x01_00_00, 0, 2),
    };
    root[1].function = 2;
    var space = Space{ .root = &root };
    var found = Found{};
    var windows = scan.Windows{ .mem = .of(0x4000_0000, 0x1000_0000) };
    _ = scan.walk(&space, &found, &windows, .{}, 0);
    try testing.expectEqual(@as(usize, 2), found.count);
    try testing.expectEqual(@as(u8, 0), found.list[0].at.function);
    try testing.expectEqual(@as(u8, 2), found.list[1].at.function);
    try testing.expectEqual(@as(u8, 2), found.list[1].info.root_pin);
}

test "BARs: aligned to their size, prefetchable 64-bit ones in their window, too big ones left out, I/O sized only" {
    var root = [_]Function{.make(0, 0x10DE, 0x1234, 0x03_00_00, 0, 1)};
    root[0].bars[0] = .{ .size = 0x100, .io = true };
    root[0].bars[1] = .{ .size = 0x1000 };
    root[0].bars[2] = .{ .size = 0x10_0000, .wide = true, .prefetch = true };
    root[0].bars[4] = .{ .size = 0x2000_0000 };
    var space = Space{ .root = &root };
    var found = Found{};
    var windows = scan.Windows{ .mem = .of(0x4000_0800, 0x0100_0000), .pref = .of(0x4_0000_0000, 0x1000_0000) };
    _ = scan.walk(&space, &found, &windows, .{}, 0);
    const bars = found.list[0].info.bars;
    try testing.expectEqual(pci.PCIBAR_IO, bars[0].flags);
    try testing.expectEqual(@as(u64, 0x100), bars[0].size);
    try testing.expectEqual(@as(u64, 0), bars[0].address);
    try testing.expectEqual(@as(u64, 0x4000_1000), bars[1].address);
    try testing.expectEqual(@as(u64, 0x4_0000_0000), bars[2].address);
    try testing.expectEqual(pci.PCIBAR_64 | pci.PCIBAR_PREFETCH, bars[2].flags);
    try testing.expectEqual(@as(u32, 4), root[0].space[7]);
    // 512 MiB does not fit 16 MiB.
    try testing.expectEqual(@as(u64, 0x2000_0000), bars[4].size);
    try testing.expectEqual(@as(u64, 0), bars[4].address);
    // Memory decoding on, I/O decoding off.
    try testing.expectEqual(pci.PCI_COMMAND_MEMORY, @as(u16, @truncate(root[0].command())));
}

test "a bridge forwards the prefetchable memory behind it, above 4 GiB" {
    var below = [_]Function{.make(0, 0x1002, 0x7340, 0x03_00_00, 0, 1)};
    below[0].bars[0] = .{ .size = 0x1000_0000, .wide = true, .prefetch = true };
    below[0].bars[2] = .{ .size = 0x4_0000 };
    var root = [_]Function{.make(0, 0x1556, 0x1111, pci.PCI_CLASS_BRIDGE_PCI, pci.PCI_HEADER_BRIDGE, 0)};
    root[0].express(pci.PCI_EXP_TYPE_ROOT_PORT);
    root[0].children = &below;
    var space = Space{ .root = &root };
    var found = Found{};
    var windows = scan.Windows{ .mem = .of(0x3000_0000, 0x0800_0000), .pref = .of(0x9_0000_0000, 0x4000_0000) };
    _ = scan.walk(&space, &found, &windows, .{ .root_devices = 1 }, 0);
    const port = &root[0];
    try testing.expectEqual(@as(u64, 0x9_0000_0000), found.list[1].info.bars[0].address);
    try testing.expectEqual(@as(u32, 0x0000), port.get(pci.PCI_PREF_MEMORY_BASE, 2));
    try testing.expectEqual(@as(u32, 0x0FF0), port.get(pci.PCI_PREF_MEMORY_LIMIT, 2));
    try testing.expectEqual(@as(u32, 9), port.get(pci.PCI_PREF_BASE_UPPER32, 4));
    try testing.expectEqual(@as(u32, 9), port.get(pci.PCI_PREF_LIMIT_UPPER32, 4));
    try testing.expectEqual(@as(u32, 0x3000), port.get(pci.PCI_MEMORY_BASE, 2));
    try testing.expectEqual(@as(u32, 0x3000), port.get(pci.PCI_MEMORY_LIMIT, 2));
}

test "the JH7110's root port hides its own BARs from the walk, and nothing else" {
    try testing.expect(jh7110.hidden(.{ .bus = 0, .device = 0, .function = 0 }, 0x10));
    try testing.expect(jh7110.hidden(.{ .bus = 0, .device = 0, .function = 0 }, 0x14));
    try testing.expect(!jh7110.hidden(.{ .bus = 0, .device = 0, .function = 0 }, 0x18));
    try testing.expect(!jh7110.hidden(.{ .bus = 1, .device = 0, .function = 0 }, 0x10));
}

test "a window gives each piece at the next multiple of its size, and none past its end" {
    var window = scan.Window.of(0x1000, 0x3000);
    try testing.expectEqual(@as(?u64, 0x1000), window.take(0x800, 0x800));
    try testing.expectEqual(@as(?u64, 0x2000), window.take(0x1000, 0x1000));
    try testing.expectEqual(@as(?u64, null), window.take(0x2000, 0x2000));
    try testing.expectEqual(@as(?u64, 0x3000), window.take(0x1000, 0x1000));
    try testing.expectEqual(@as(?u64, null), window.take(0x10, 0x10));
    var none = scan.Window{};
    try testing.expectEqual(@as(?u64, null), none.take(0x10, 0x10));
}
