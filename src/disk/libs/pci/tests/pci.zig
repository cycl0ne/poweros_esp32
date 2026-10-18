// SPDX-License-Identifier: MIT
//! Host tests of pci.library's walk and placing (scan/scan.zig,
//! scan/place.zig) on buses made up here: functions with 4 KiB of
//! configuration space and capabilities, BARs and expansion ROMs that
//! keep only the bits their size lets them, PCI-to-PCI bridges whose
//! windows keep the bits they have and whose buses are reached through
//! the numbers the walk gives them - as QEMU's virt machine has its
//! functions, the JH7110's root ports theirs, and a PCI Express switch
//! its ports - and of MSI and MSI-X set up in a function's registers
//! (interrupt/_vectors.zig).

const std = @import("std");
const sdk = @import("sdk");
const pci = sdk.pci;
const scan = @import("../scan/scan.zig");
const place = @import("../scan/place.zig");
const ecam = @import("../host/ecam.zig");
const _host = @import("../host/_host.zig");
const jh7110 = @import("../host/jh7110.zig");
const _vectors = @import("../interrupt/_vectors.zig");
const _state = @import("../host/_state.zig");

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
    space: [1024]u32 = @splat(0),
    bars: [6]Bar = @splat(.{}),
    rom: u64 = 0,
    children: []Function = &.{},
    /// A bridge's windows: whether it has an I/O one and how wide, and a
    /// prefetchable one and how wide.
    io: enum { none, b16, b32 } = .b16,
    pref: enum { none, b32, b64 } = .b64,
    /// Reads of its vendor that ask to be asked again (configuration
    /// request retry), and that answer nothing yet.
    retries: u32 = 0,
    late: u32 = 0,
    /// Where its next capability goes, and where its last one is.
    next_cap: u32 = 0x40,
    last_cap: u32 = 0,
    next_ext: u32 = 0x100,
    last_ext: u32 = 0,
    exp: u32 = 0,

    fn make(device: u8, vendor: u16, id: u16, class_code: u32, header: u8, pin: u8) Function {
        var f = Function{ .device = device };
        f.space[0] = @as(u32, id) << 16 | vendor;
        f.space[2] = class_code << 8 | 1;
        f.space[3] = @as(u32, header) << 16;
        f.space[15] = @as(u32, pin) << 8;
        return f;
    }

    fn bridge(device: u8, kind: ?u8) Function {
        var f = make(device, 0x1B36, 0x000C, pci.PCI_CLASS_BRIDGE_PCI, pci.PCI_HEADER_BRIDGE, 0);
        if (kind) |k| f.express(k, 0);
        return f;
    }

    fn isBridge(f: *Function) bool {
        return f.get(pci.PCI_HEADER_TYPE, 1) & 0x7F == pci.PCI_HEADER_BRIDGE;
    }

    /// A capability of `len` bytes on its list: where it is.
    fn cap(f: *Function, id: u8, len: u32) u32 {
        const at = f.next_cap;
        f.next_cap += (len + 3) & ~@as(u32, 3);
        f.put(at, 1, id);
        if (f.last_cap == 0) {
            f.put(pci.PCI_STATUS, 2, pci.PCI_STATUS_CAP_LIST);
            f.put(pci.PCI_CAPABILITY_LIST, 1, at);
        } else f.put(f.last_cap + 1, 1, at);
        f.last_cap = at;
        return at;
    }

    /// An extended capability of `len` bytes on its list.
    fn extCap(f: *Function, id: u16, len: u32) u32 {
        const at = f.next_ext;
        f.next_ext += (len + 3) & ~@as(u32, 3);
        f.put(at, 4, @as(u32, id) | 1 << 16);
        if (f.last_ext != 0) f.put(f.last_ext, 4, f.get(f.last_ext, 4) | at << 20);
        f.last_ext = at;
        return at;
    }

    /// A PCI Express capability of port type `kind`, which takes payloads
    /// of up to 128 << `payload`.
    fn express(f: *Function, kind: u8, payload: u3) void {
        f.exp = f.cap(pci.PCI_CAP_ID_EXP, 0x3C);
        f.put(f.exp + pci.PCI_EXP_FLAGS, 2, 2 | @as(u32, kind) << 4);
        f.put(f.exp + pci.PCI_EXP_DEVCAP, 4, payload);
        // Gen 2, one lane, trained.
        f.put(f.exp + pci.PCI_EXP_LNKCAP, 4, 2 | 1 << 4);
        f.put(f.exp + pci.PCI_EXP_LNKSTA, 2, 1 | 1 << 4);
    }

    /// A port that says whether its link is up.
    fn reportLink(f: *Function, up: bool) void {
        f.put(f.exp + pci.PCI_EXP_LNKCAP, 4, f.get(f.exp + pci.PCI_EXP_LNKCAP, 4) | pci.PCI_EXP_LNKCAP_DLLLARC);
        if (up) f.put(f.exp + pci.PCI_EXP_LNKSTA, 2, f.get(f.exp + pci.PCI_EXP_LNKSTA, 2) | pci.PCI_EXP_LNKSTA_DLLLA);
    }

    fn bytes(f: *Function) *[4096]u8 {
        return std.mem.asBytes(&f.space);
    }

    fn get(f: *Function, offset: u32, size: u32) u32 {
        var value: u32 = 0;
        for (0..size) |i| value |= @as(u32, f.bytes()[offset + i]) << @intCast(8 * i);
        return value;
    }

    /// `value` stored as it is: what the made-up function is.
    fn put(f: *Function, offset: u32, size: u32, value: u32) void {
        for (0..size) |i| f.bytes()[offset + i] = @truncate(value >> @intCast(8 * i));
    }

    /// `value` written, as the function keeps it.
    fn set(f: *Function, offset: u32, size: u32, value: u32) void {
        f.put(offset, size, value);
        f.keep();
    }

    /// What the function's registers keep: a BAR the bits its size lets
    /// it and the bits that say what it is, the ROM likewise, a bridge's
    /// windows what it has of them.
    fn keep(f: *Function) void {
        const is_bridge = f.isBridge();
        const count: usize = if (is_bridge) 2 else 6;
        for (0..count) |i| f.space[4 + i] = f.barValue(@intCast(i), f.space[4 + i]);
        const rom_word: usize = (if (is_bridge) pci.PCI_ROM_ADDRESS1 else pci.PCI_ROM_ADDRESS) / 4;
        f.space[rom_word] = if (f.rom == 0) 0 else f.space[rom_word] & ((@as(u32, @truncate(~(f.rom - 1))) & pci.PCI_ROM_ADDRESS_MASK) | 1);
        if (!is_bridge) return;
        const b = f.bytes();
        switch (f.io) {
            .none => {
                b[0x1C] = 0;
                b[0x1D] = 0;
                f.put(pci.PCI_IO_BASE_UPPER16, 4, 0);
            },
            .b16 => {
                b[0x1C] &= 0xF0;
                b[0x1D] &= 0xF0;
                f.put(pci.PCI_IO_BASE_UPPER16, 4, 0);
            },
            .b32 => {
                b[0x1C] = (b[0x1C] & 0xF0) | 1;
                b[0x1D] = (b[0x1D] & 0xF0) | 1;
            },
        }
        switch (f.pref) {
            .none => {
                f.put(pci.PCI_PREF_MEMORY_BASE, 4, 0);
                f.put(pci.PCI_PREF_BASE_UPPER32, 4, 0);
                f.put(pci.PCI_PREF_LIMIT_UPPER32, 4, 0);
            },
            .b32 => {
                b[0x24] &= 0xF0;
                b[0x26] &= 0xF0;
                f.put(pci.PCI_PREF_BASE_UPPER32, 4, 0);
                f.put(pci.PCI_PREF_LIMIT_UPPER32, 4, 0);
            },
            .b64 => {
                b[0x24] = (b[0x24] & 0xF0) | 1;
                b[0x26] = (b[0x26] & 0xF0) | 1;
            },
        }
    }

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

    fn command(f: *Function) u16 {
        return @truncate(f.get(pci.PCI_COMMAND, 2));
    }

    /// Where its BAR `index` is on the bus, both halves of a wide one.
    fn barAt(f: *Function, index: usize) u64 {
        var at: u64 = f.space[4 + index] & 0xFFFF_FFF0;
        if (f.bars[index].wide) at |= @as(u64, f.space[5 + index]) << 32;
        return at;
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

    fn busList(space: *Space, list: []Function, number: u8, bus: u8) ?[]Function {
        if (number == bus) return list;
        for (list) |*f| {
            if (!f.isBridge()) continue;
            const secondary: u8 = @truncate(f.get(pci.PCI_SECONDARY_BUS, 1));
            const subordinate: u8 = @truncate(f.get(pci.PCI_SUBORDINATE_BUS, 1));
            if (secondary == 0 or bus < secondary or bus > subordinate) continue;
            if (space.busList(f.children, secondary, bus)) |found| return found;
        }
        return null;
    }

    pub fn read(space: *Space, at: Address, offset: u32, size: u32) u32 {
        const none: u32 = if (size == 4) 0xFFFF_FFFF else (@as(u32, 1) << @intCast(8 * size)) - 1;
        const f = space.find(at) orelse {
            space.misses += 1;
            return none;
        };
        if (offset == pci.PCI_VENDOR_ID) {
            if (f.late > 0) {
                f.late -= 1;
                return none;
            }
            if (f.retries > 0) {
                f.retries -= 1;
                return if (size == 4) 0xFFFF_0001 else 0x0001;
            }
        }
        if (offset >= 4096) return 0;
        return f.get(offset, size);
    }

    pub fn write(space: *Space, at: Address, offset: u32, size: u32, value: u32) void {
        const f = space.find(at) orelse return;
        if (offset >= 4096) return;
        f.set(offset, size, value);
    }
};

/// The waits the walk asks for, added up.
const Clock = struct {
    us: u64 = 0,

    pub fn wait(clock: *Clock, us: u32) void {
        clock.us += us;
    }
};

/// A walk, and what it found placed.
const Run = struct {
    nodes: [32]scan.Node = undefined,
    walk: scan.Walk = .{},
    clock: Clock = .{},
    windows: place.Windows,

    fn of(space: *Space, windows: place.Windows, limits: scan.Limits) Run {
        var run = Run{ .windows = windows };
        run.walk = scan.walk(space, &run.clock, &run.nodes, limits, 0);
        place.place(space, run.found(), &run.windows);
        return run;
    }

    fn found(run: *Run) []scan.Node {
        return run.nodes[0..run.walk.count];
    }

    fn node(run: *Run, bus: u8, device: u8) *scan.Node {
        for (run.found()) |*n| {
            if (n.at.bus == bus and n.at.device == device) return n;
        }
        unreachable;
    }
};

const qemu_windows = place.Windows{
    .io = .ofIo(0x0300_0000, 0, 0x1_0000),
    .mem = .of(0x4000_0000, 0x4000_0000, 0x4000_0000),
    .pref = .of(0x4_0000_0000, 0x4_0000_0000, 0x4_0000_0000),
};
const jh7110_windows = place.Windows{
    .mem = .of(0x3000_0000, 0x3000_0000, 0x0800_0000),
    .pref = .of(0x9_0000_0000, 0x9_0000_0000, 0x4000_0000),
};

/// Every placed BAR and window inside the window of its kind of the
/// bridge it is behind, and none on a bus overlapping another of its
/// kind.
fn expectNested(nodes: []const scan.Node) !void {
    for (nodes, 0..) |*a, i| {
        for (0..scan.slots) |s| {
            const kind = a.kind[s] orelse continue;
            const bytes = if (s == scan.rom_slot) a.info.rom.size else a.info.bars[s].size;
            try testing.expectEqual(@as(u64, 0), a.bus[s] % bytes);
            if (a.parent) |p| try expectInside(nodes[p].windows[@intFromEnum(kind)], a.bus[s], bytes);
        }
        for (a.windows, 0..) |span, k| {
            if (!span.placed) continue;
            if (a.parent) |p| try expectInside(nodes[p].windows[k], span.base, span.size);
        }
        // Pieces on the same bus do not overlap.
        for (nodes[i + 1 ..]) |*b| {
            if (b.parent != a.parent) continue;
            for (scan.kinds) |kind| {
                var ra: [8][2]u64 = undefined;
                var rb: [8][2]u64 = undefined;
                const na = ranges(a, kind, &ra);
                const nb = ranges(b, kind, &rb);
                for (ra[0..na]) |x| for (rb[0..nb]) |y| {
                    try testing.expect(x[0] + x[1] <= y[0] or y[0] + y[1] <= x[0]);
                };
            }
        }
    }
}

fn ranges(n: *const scan.Node, kind: scan.Kind, into: *[8][2]u64) usize {
    var count: usize = 0;
    for (0..scan.slots) |s| {
        if (n.kind[s] != kind) continue;
        into[count] = .{ n.bus[s], if (s == scan.rom_slot) n.info.rom.size else n.info.bars[s].size };
        count += 1;
    }
    const span = n.windows[@intFromEnum(kind)];
    if (span.placed) {
        into[count] = .{ span.base, span.size };
        count += 1;
    }
    return count;
}

fn expectInside(window: scan.Span, at: u64, bytes: u64) !void {
    try testing.expect(window.placed);
    try testing.expect(at >= window.base and at + bytes <= window.base + window.size);
}

// --- the walk -------------------------------------------------------------------------

test "QEMU's virt: an xHCI's 64-bit BAR at the window's start, its memory decoded, its INTA rotated by its slot" {
    var root = [_]Function{
        .make(0, 0x1B36, 0x0008, 0x06_00_00, 0, 0),
        .make(1, 0x1B36, 0x000D, pci.PCI_CLASS_SERIAL_USB_XHCI, 0, 1),
    };
    root[1].bars[0] = .{ .size = 0x4000, .wide = true };
    var space = Space{ .root = &root };
    var run = Run.of(&space, qemu_windows, .{});

    try testing.expectEqual(@as(u8, 0), run.walk.last_bus);
    try testing.expectEqual(@as(u16, 2), run.walk.count);
    const xhci = run.node(0, 1).info;
    try testing.expectEqual(pci.PCI_CLASS_SERIAL_USB_XHCI, xhci.class_code);
    try testing.expectEqual(@as(u64, 0x4000_0000), xhci.bars[0].address);
    try testing.expectEqual(@as(u64, 0x4000), xhci.bars[0].size);
    try testing.expectEqual(pci.PCIBAR_64, xhci.bars[0].flags);
    try testing.expectEqual(@as(u32, 0x4000_0004), root[1].space[4]);
    try testing.expectEqual(@as(u32, 0), root[1].space[5]);
    try testing.expect(root[1].command() & pci.PCI_COMMAND_MEMORY != 0);
    try testing.expect(root[1].command() & pci.PCI_COMMAND_MASTER == 0);
    // Slot 1's INTA is the emulator's second source: PLIC 33.
    try testing.expectEqual(@as(u8, 1), xhci.root_device);
    try testing.expectEqual(@as(u8, 1), xhci.root_pin);
    const host = _host.Host{ .sys = undefined, .chip = .ecam, .segment = 0, .irq = 32 };
    try testing.expectEqual(@as(u32, 33), ecam.interruptOf(&host, xhci.root_device, xhci.root_pin));
    // The host bridge has no BARs and no line, and a function without
    // PCI Express no payload.
    try testing.expectEqual(@as(u8, 0), run.node(0, 0).info.interrupt_pin);
    try testing.expectEqual(pci.PCI_EXP_TYPE_NONE, xhci.express_type);
    try testing.expectEqual(@as(u16, 0), xhci.max_payload);
    try testing.expectEqual(@as(u64, 0), run.clock.us);
}

test "the JH7110's root port: one device behind it, its bus numbered, its window the VL805's BAR, the payload both take" {
    var below = [_]Function{
        .make(0, 0x1106, 0x3483, pci.PCI_CLASS_SERIAL_USB_XHCI, 0, 1),
        // Never asked: a root port has one device below it.
        .make(1, 0x1234, 0x5678, 0x02_00_00, 0, 1),
    };
    below[0].bars[0] = .{ .size = 0x1000, .wide = true };
    below[0].express(pci.PCI_EXP_TYPE_ENDPOINT, 2);
    var root = [_]Function{.bridge(0, null)};
    root[0].io = .none;
    root[0].express(pci.PCI_EXP_TYPE_ROOT_PORT, 1);
    root[0].children = &below;
    var space = Space{ .root = &root };
    var run = Run.of(&space, jh7110_windows, .{ .root_devices = 1 });

    try testing.expectEqual(@as(u8, 1), run.walk.last_bus);
    try testing.expectEqual(@as(u16, 2), run.walk.count);
    const port = &root[0];
    try testing.expectEqual(@as(u32, 0), port.get(pci.PCI_PRIMARY_BUS, 1));
    try testing.expectEqual(@as(u32, 1), port.get(pci.PCI_SECONDARY_BUS, 1));
    try testing.expectEqual(@as(u32, 1), port.get(pci.PCI_SUBORDINATE_BUS, 1));
    try testing.expectEqual(@as(u32, 0x3000), port.get(pci.PCI_MEMORY_BASE, 2));
    try testing.expectEqual(@as(u32, 0x3000), port.get(pci.PCI_MEMORY_LIMIT, 2));
    // No prefetchable memory behind it, no I/O: both windows shut.
    try testing.expectEqual(@as(u32, 0xFFF1), port.get(pci.PCI_PREF_MEMORY_BASE, 2));
    try testing.expectEqual(@as(u32, 0x0001), port.get(pci.PCI_PREF_MEMORY_LIMIT, 2));
    try testing.expectEqual(@as(u32, 0), port.get(pci.PCI_IO_BASE, 1));
    try testing.expectEqual(pci.PCI_COMMAND_MEMORY | pci.PCI_COMMAND_MASTER, port.command());

    const vl805 = run.node(1, 0);
    try testing.expectEqual(@as(u16, 0x3483), vl805.info.device_id);
    try testing.expectEqual(@as(?u16, 0), vl805.parent);
    try testing.expectEqual(@as(u64, 0x3000_0000), vl805.info.bars[0].address);
    try testing.expect(below[0].command() & pci.PCI_COMMAND_MEMORY != 0);
    try testing.expectEqual(@as(u8, 0), vl805.info.root_device);
    try testing.expectEqual(@as(u8, 1), vl805.info.root_pin);
    try testing.expectEqual(pci.PCI_EXP_TYPE_ENDPOINT, vl805.info.express_type);
    try testing.expectEqual(@as(u8, 1), vl805.info.link_speed);
    try testing.expectEqual(@as(u8, 2), vl805.info.link_max_speed);
    try testing.expectEqual(@as(u8, 1), vl805.info.link_width);
    try testing.expectEqual(@as(u8, 1), vl805.info.link_max_width);
    // The root port takes 256 bytes, the VL805 512: both send 256.
    try testing.expectEqual(@as(u16, 256), vl805.info.max_payload);
    try testing.expectEqual(@as(u32, 1 << 5), below[0].get(below[0].exp + pci.PCI_EXP_DEVCTL, 2));
    try testing.expectEqual(@as(u32, 1 << 5), port.get(port.exp + pci.PCI_EXP_DEVCTL, 2));
    // Device 1 below the port was not asked, nor anything past bus 1.
    try testing.expectEqual(@as(u16, 0), below[1].command());
    try testing.expectEqual(@as(u32, 0), space.misses);
}

test "behind bridges a line is rotated by the device number at each, up to the host bridge's bus" {
    var deep = [_]Function{.make(3, 0x10EC, 0x8168, 0x02_00_00, 0, 1)};
    var middle = [_]Function{.bridge(1, null)};
    middle[0].children = &deep;
    var root = [_]Function{.bridge(2, null)};
    root[0].children = &middle;
    var space = Space{ .root = &root };
    var run = Run.of(&space, qemu_windows, .{});

    try testing.expectEqual(@as(u8, 2), run.walk.last_bus);
    try testing.expectEqual(@as(u16, 3), run.walk.count);
    // INTA of device 3 is INTD of the bridge it is behind (device 1),
    // and that is INTA again of the one on the root bus (device 2).
    const nic = run.node(2, 3);
    try testing.expectEqual(@as(u8, 2), nic.info.root_device);
    try testing.expectEqual(@as(u8, 1), nic.info.root_pin);
    try testing.expectEqual(@as(?u16, 1), nic.parent);
    try testing.expectEqual(@as(?u16, 0), run.node(1, 1).parent);
    try testing.expectEqual(@as(u32, 1), root[0].get(pci.PCI_SECONDARY_BUS, 1));
    try testing.expectEqual(@as(u32, 2), root[0].get(pci.PCI_SUBORDINATE_BUS, 1));
    try testing.expectEqual(@as(u32, 2), middle[0].get(pci.PCI_SECONDARY_BUS, 1));
    try testing.expectEqual(@as(u32, 1), middle[0].get(pci.PCI_PRIMARY_BUS, 1));
}

test "a device with more functions has each found, gaps and all" {
    var root = [_]Function{
        .make(4, 0x1AF4, 0x1000, 0x02_00_00, pci.PCI_HEADER_MULTI, 1),
        .make(4, 0x1AF4, 0x1001, 0x01_00_00, 0, 2),
    };
    root[1].function = 2;
    var space = Space{ .root = &root };
    const run = Run.of(&space, qemu_windows, .{});
    try testing.expectEqual(@as(u16, 2), run.walk.count);
    try testing.expectEqual(@as(u8, 0), run.nodes[0].at.function);
    try testing.expectEqual(@as(u8, 2), run.nodes[1].at.function);
    try testing.expectEqual(@as(u8, 2), run.nodes[1].info.root_pin);
}

test "a PCI Express switch: every port's buses numbered, each window inside the one above, the payload all of them take" {
    var nvme = [_]Function{.make(0, 0x1344, 0x5416, pci.PCI_CLASS_STORAGE_NVME, 0, 1)};
    nvme[0].bars[0] = .{ .size = 0x4000, .wide = true };
    nvme[0].express(pci.PCI_EXP_TYPE_ENDPOINT, 1);
    var nic = [_]Function{.make(0, 0x8086, 0x10D3, 0x02_00_00, 0, 1)};
    nic[0].bars[0] = .{ .size = 0x2_0000 };
    nic[0].bars[1] = .{ .size = 0x2_0000 };
    nic[0].bars[2] = .{ .size = 0x20, .io = true };
    nic[0].bars[3] = .{ .size = 0x4000 };
    nic[0].rom = 0x4_0000;
    nic[0].express(pci.PCI_EXP_TYPE_ENDPOINT, 0);
    var downstream = [_]Function{ .bridge(0, pci.PCI_EXP_TYPE_DOWNSTREAM), .bridge(1, pci.PCI_EXP_TYPE_DOWNSTREAM) };
    downstream[0].children = &nvme;
    downstream[1].children = &nic;
    var upstream = [_]Function{.bridge(0, pci.PCI_EXP_TYPE_UPSTREAM)};
    upstream[0].children = &downstream;
    var root = [_]Function{.bridge(1, pci.PCI_EXP_TYPE_ROOT_PORT)};
    root[0].children = &upstream;
    var space = Space{ .root = &root };
    var run = Run.of(&space, qemu_windows, .{});

    try testing.expectEqual(@as(u16, 6), run.walk.count);
    try testing.expectEqual(@as(u8, 4), run.walk.last_bus);
    const numbers = [_][2]u32{
        .{ root[0].get(pci.PCI_SECONDARY_BUS, 1), root[0].get(pci.PCI_SUBORDINATE_BUS, 1) },
        .{ upstream[0].get(pci.PCI_SECONDARY_BUS, 1), upstream[0].get(pci.PCI_SUBORDINATE_BUS, 1) },
        .{ downstream[0].get(pci.PCI_SECONDARY_BUS, 1), downstream[0].get(pci.PCI_SUBORDINATE_BUS, 1) },
        .{ downstream[1].get(pci.PCI_SECONDARY_BUS, 1), downstream[1].get(pci.PCI_SUBORDINATE_BUS, 1) },
    };
    try testing.expectEqualSlices([2]u32, &.{ .{ 1, 4 }, .{ 2, 4 }, .{ 3, 3 }, .{ 4, 4 } }, &numbers);
    try expectNested(run.found());

    // Everything placed and decoded, the ROM's decoding off.
    const nic_node = run.node(4, 0);
    for (0..4) |i| try testing.expect(nic_node.info.bars[i].address != 0);
    try testing.expect(nic_node.info.rom.address != 0);
    try testing.expectEqual(@as(u32, 0), nic[0].get(pci.PCI_ROM_ADDRESS, 4) & pci.PCI_ROM_ADDRESS_ENABLE);
    try testing.expectEqual(pci.PCI_COMMAND_IO | pci.PCI_COMMAND_MEMORY, nic[0].command());
    // The I/O BAR is past the first 4 KiB, where each bridge's I/O
    // window is.
    try testing.expectEqual(@as(u64, 0x0300_1000), nic_node.info.bars[2].address);
    for ([_]*Function{ &root[0], &upstream[0], &downstream[1] }) |b| {
        try testing.expectEqual(@as(u32, 0x10), b.get(pci.PCI_IO_BASE, 1));
        try testing.expectEqual(@as(u32, 0x10), b.get(pci.PCI_IO_LIMIT, 1));
        try testing.expect(b.command() & pci.PCI_COMMAND_IO != 0);
    }
    // The NVMe's port forwards no I/O.
    try testing.expectEqual(@as(u32, 0xF0), downstream[0].get(pci.PCI_IO_BASE, 1));
    try testing.expect(downstream[0].command() & pci.PCI_COMMAND_IO == 0);
    // The NIC takes no more than 128 bytes: everything sends 128.
    for (run.found()) |*n| try testing.expectEqual(@as(u16, 128), n.info.max_payload);
    try testing.expectEqual(@as(u32, 0), nvme[0].get(nvme[0].exp + pci.PCI_EXP_DEVCTL, 2));
}

test "a large BAR behind a bridge: the bridge's window aligned as it, the smaller pieces after" {
    var below = [_]Function{.make(0, 0x10DE, 0x2204, 0x03_00_00, 0, 1)};
    below[0].bars[0] = .{ .size = 0x1000_0000 };
    below[0].bars[1] = .{ .size = 0x1000 };
    var root = [_]Function{ .bridge(1, null), .make(2, 0x1B36, 0x0010, 0x01_08_02, 0, 1) };
    root[0].children = &below;
    root[1].bars[0] = .{ .size = 0x10_0000 };
    var space = Space{ .root = &root };
    var run = Run.of(&space, .{ .mem = .of(0x4000_0000, 0x4000_0000, 0x4000_0000) }, .{});

    const window = run.node(0, 1).windows[@intFromEnum(scan.Kind.mem)];
    try testing.expectEqual(@as(u64, 0x4000_0000), window.base);
    try testing.expectEqual(@as(u64, 0x1010_0000), window.size);
    try testing.expectEqual(@as(u64, 0x4000_0000), run.node(1, 0).info.bars[0].address);
    try testing.expectEqual(@as(u64, 0x5000_0000), run.node(1, 0).info.bars[1].address);
    try testing.expectEqual(@as(u64, 0x5010_0000), run.node(0, 2).info.bars[0].address);
    try testing.expectEqual(@as(u32, 0x4000), root[0].get(pci.PCI_MEMORY_BASE, 2));
    try testing.expectEqual(@as(u32, 0x5000), root[0].get(pci.PCI_MEMORY_LIMIT, 2));
    try expectNested(run.found());
}

test "BARs: aligned to their size, prefetchable 64-bit ones in their window, too big ones left out" {
    var root = [_]Function{.make(0, 0x10DE, 0x1234, 0x03_00_00, 0, 1)};
    root[0].bars[0] = .{ .size = 0x100, .io = true };
    root[0].bars[1] = .{ .size = 0x1000 };
    root[0].bars[2] = .{ .size = 0x10_0000, .wide = true, .prefetch = true };
    root[0].bars[4] = .{ .size = 0x2000_0000 };
    var space = Space{ .root = &root };
    const run = Run.of(&space, .{
        .mem = .of(0x4000_0800, 0x4000_0800, 0x0100_0000),
        .pref = .of(0x4_0000_0000, 0x4_0000_0000, 0x1000_0000),
    }, .{});
    const bars = run.nodes[0].info.bars;
    try testing.expectEqual(pci.PCIBAR_IO, bars[0].flags);
    try testing.expectEqual(@as(u64, 0x100), bars[0].size);
    // No I/O window: the I/O BAR has no place, and I/O is not decoded.
    try testing.expectEqual(@as(u64, 0), bars[0].address);
    try testing.expectEqual(@as(u64, 0x4000_1000), bars[1].address);
    try testing.expectEqual(@as(u64, 0x4_0000_0000), bars[2].address);
    try testing.expectEqual(pci.PCIBAR_64 | pci.PCIBAR_PREFETCH, bars[2].flags);
    try testing.expectEqual(@as(u32, 4), root[0].space[7]);
    // 512 MiB does not fit 16 MiB: the memory BARs are not all placed,
    // so their decoding stays off.
    try testing.expectEqual(@as(u64, 0x2000_0000), bars[4].size);
    try testing.expectEqual(@as(u64, 0), bars[4].address);
    try testing.expectEqual(@as(u16, 0), root[0].command());
}

test "an I/O BAR in the host bridge's I/O window, the processor's address and the bus's apart" {
    var root = [_]Function{.make(3, 0x10EC, 0x8139, 0x02_00_00, 0, 1)};
    root[0].bars[0] = .{ .size = 0x100, .io = true };
    root[0].bars[1] = .{ .size = 0x100 };
    var space = Space{ .root = &root };
    const run = Run.of(&space, qemu_windows, .{});
    const bars = run.nodes[0].info.bars;
    try testing.expectEqual(@as(u64, 0x0300_1000), bars[0].address);
    try testing.expectEqual(@as(u32, 0x1001), root[0].space[4]);
    try testing.expectEqual(pci.PCI_COMMAND_IO | pci.PCI_COMMAND_MEMORY, root[0].command());
}

test "a window elsewhere on the bus than for the processor: the BAR has the bus's address, PCIBar the processor's" {
    var root = [_]Function{.make(0, 0x14E4, 0x1711, 0x02_00_00, 0, 1)};
    root[0].bars[0] = .{ .size = 0x1_0000, .wide = true };
    var space = Space{ .root = &root };
    const run = Run.of(&space, .{ .mem = .of(0x6_0000_0000, 0xC000_0000, 0x4000_0000) }, .{});
    try testing.expectEqual(@as(u64, 0x6_0000_0000), run.nodes[0].info.bars[0].address);
    try testing.expectEqual(@as(u64, 0xC000_0000), root[0].barAt(0));
}

test "an I/O window above 64 KiB on the bus: a 16-bit bridge cannot forward it, a 32-bit one can" {
    const windows = place.Windows{ .io = .ofIo(0x0300_0000, 0x1_0000, 0x1_0000), .mem = qemu_windows.mem };
    for ([_]bool{ false, true }) |wide| {
        var below = [_]Function{.make(0, 0x10EC, 0x8139, 0x02_00_00, 0, 1)};
        below[0].bars[0] = .{ .size = 0x100, .io = true };
        var root = [_]Function{.bridge(0, null)};
        root[0].io = if (wide) .b32 else .b16;
        root[0].children = &below;
        var space = Space{ .root = &root };
        var run = Run.of(&space, windows, .{});
        const bar = run.node(1, 0).info.bars[0];
        if (wide) {
            try testing.expectEqual(@as(u64, 0x0300_0000), bar.address);
            try testing.expectEqual(@as(u32, 0x01), root[0].get(pci.PCI_IO_BASE, 1));
            try testing.expectEqual(@as(u32, 0x01), root[0].get(pci.PCI_IO_LIMIT, 1));
            try testing.expectEqual(@as(u32, 1), root[0].get(pci.PCI_IO_BASE_UPPER16, 2));
            try testing.expectEqual(@as(u32, 1), root[0].get(pci.PCI_IO_LIMIT_UPPER16, 2));
        } else {
            try testing.expectEqual(@as(u64, 0), bar.address);
            try testing.expectEqual(@as(u32, 0xF0), root[0].get(pci.PCI_IO_BASE, 1));
            try testing.expect(root[0].command() & pci.PCI_COMMAND_IO == 0);
        }
    }
}

test "a bridge forwards the prefetchable memory behind it, above 4 GiB" {
    var below = [_]Function{.make(0, 0x1002, 0x7340, 0x03_00_00, 0, 1)};
    below[0].bars[0] = .{ .size = 0x1000_0000, .wide = true, .prefetch = true };
    below[0].bars[2] = .{ .size = 0x4_0000 };
    var root = [_]Function{.bridge(0, pci.PCI_EXP_TYPE_ROOT_PORT)};
    root[0].children = &below;
    var space = Space{ .root = &root };
    var run = Run.of(&space, jh7110_windows, .{ .root_devices = 1 });
    const port = &root[0];
    try testing.expectEqual(@as(u64, 0x9_0000_0000), run.node(1, 0).info.bars[0].address);
    try testing.expectEqual(@as(u32, 0x0001), port.get(pci.PCI_PREF_MEMORY_BASE, 2));
    try testing.expectEqual(@as(u32, 0x0FF1), port.get(pci.PCI_PREF_MEMORY_LIMIT, 2));
    try testing.expectEqual(@as(u32, 9), port.get(pci.PCI_PREF_BASE_UPPER32, 4));
    try testing.expectEqual(@as(u32, 9), port.get(pci.PCI_PREF_LIMIT_UPPER32, 4));
    try testing.expectEqual(@as(u32, 0x3000), port.get(pci.PCI_MEMORY_BASE, 2));
    try testing.expectEqual(@as(u32, 0x3000), port.get(pci.PCI_MEMORY_LIMIT, 2));
}

test "behind a bridge with a 32-bit prefetchable window, or none, prefetchable BARs go below 4 GiB" {
    for ([_]@FieldType(Function, "pref"){ .b32, .none }) |kind| {
        var below = [_]Function{.make(0, 0x1002, 0x7340, 0x03_00_00, 0, 1)};
        below[0].bars[0] = .{ .size = 0x100_0000, .wide = true, .prefetch = true };
        var root = [_]Function{.bridge(0, pci.PCI_EXP_TYPE_ROOT_PORT)};
        root[0].pref = kind;
        root[0].children = &below;
        var space = Space{ .root = &root };
        var run = Run.of(&space, jh7110_windows, .{ .root_devices = 1 });
        try testing.expectEqual(@as(u64, 0x3000_0000), run.node(1, 0).info.bars[0].address);
        try testing.expectEqual(@as(u32, 0x3000), root[0].get(pci.PCI_MEMORY_BASE, 2));
        try testing.expectEqual(@as(u32, 0x30F0), root[0].get(pci.PCI_MEMORY_LIMIT, 2));
        try testing.expect(!run.nodes[0].windows[@intFromEnum(scan.Kind.pref)].placed);
    }
}

test "an expansion ROM is placed where there is room, and left out where it would crowd out a BAR" {
    for ([_]u64{ 0x40_0000, 0x10_0000 }) |room| {
        var root = [_]Function{.make(0, 0x1AF4, 0x1050, 0x03_00_00, 0, 1)};
        root[0].bars[0] = .{ .size = 0x8_0000 };
        root[0].rom = 0x10_0000;
        var space = Space{ .root = &root };
        const run = Run.of(&space, .{ .mem = .of(0x4000_0000, 0x4000_0000, room) }, .{});
        const info = run.nodes[0].info;
        try testing.expect(info.bars[0].address != 0);
        try testing.expectEqual(pci.PCI_COMMAND_MEMORY, root[0].command());
        try testing.expectEqual(pci.PCIBAR_ROM, info.rom.flags);
        try testing.expectEqual(@as(u64, 0x10_0000), info.rom.size);
        if (room > 0x10_0000) {
            try testing.expectEqual(@as(u64, 0x4000_0000), info.rom.address);
            try testing.expectEqual(@as(u32, 0x4000_0000), root[0].get(pci.PCI_ROM_ADDRESS, 4));
        } else {
            try testing.expectEqual(@as(u64, 0x4000_0000), info.bars[0].address);
            try testing.expectEqual(@as(u64, 0), info.rom.address);
        }
    }
}

test "a function found saving power is woken to D0, and given its 10 ms" {
    var root = [_]Function{.make(0, 0x8086, 0x1533, 0x02_00_00, 0, 1)};
    const pm = root[0].cap(pci.PCI_CAP_ID_PM, 8);
    root[0].put(pm + pci.PCI_PM_CTRL, 2, 3);
    var space = Space{ .root = &root };
    const run = Run.of(&space, qemu_windows, .{});
    try testing.expectEqual(@as(u8, 3), run.nodes[0].info.found_power);
    try testing.expectEqual(@as(u8, @intCast(pm)), run.nodes[0].info.cap_pm);
    try testing.expectEqual(@as(u32, 0), root[0].get(pm + pci.PCI_PM_CTRL, 2) & 3);
    try testing.expectEqual(@as(u64, 10_000), run.clock.us);
}

test "a function asking to be asked again is, for up to a second" {
    var root = [_]Function{.make(0, 0x144D, 0xA808, pci.PCI_CLASS_STORAGE_NVME, 0, 1)};
    root[0].retries = 3;
    var space = Space{ .root = &root };
    var run = Run.of(&space, qemu_windows, .{ .root_devices = 1 });
    try testing.expectEqual(@as(u16, 1), run.walk.count);
    try testing.expectEqual(@as(u64, 30_000), run.clock.us);

    root[0].retries = 1000;
    run = Run.of(&space, qemu_windows, .{ .root_devices = 1 });
    try testing.expectEqual(@as(u16, 0), run.walk.count);
    try testing.expectEqual(@as(u64, 1_000_000), run.clock.us);
}

test "below a port whose link is down nothing is asked; below one that is up, device 0 is waited for" {
    var below = [_]Function{.make(0, 0x1344, 0x5416, pci.PCI_CLASS_STORAGE_NVME, 0, 1)};
    var root = [_]Function{.bridge(0, pci.PCI_EXP_TYPE_ROOT_PORT)};
    root[0].reportLink(false);
    root[0].children = &below;
    var space = Space{ .root = &root };
    var run = Run.of(&space, jh7110_windows, .{ .root_devices = 1 });
    try testing.expectEqual(@as(u16, 1), run.walk.count);
    try testing.expectEqual(@as(u32, 0), space.misses);
    try testing.expectEqual(@as(u64, 0), run.clock.us);
    try testing.expectEqual(@as(u32, 1), root[0].get(pci.PCI_SECONDARY_BUS, 1));

    var up = [_]Function{.bridge(0, pci.PCI_EXP_TYPE_ROOT_PORT)};
    up[0].reportLink(true);
    up[0].children = &below;
    below[0].late = 5;
    space = .{ .root = &up };
    run = Run.of(&space, jh7110_windows, .{ .root_devices = 1 });
    try testing.expectEqual(@as(u16, 2), run.walk.count);
    try testing.expectEqual(@as(u64, 50_000), run.clock.us);
}

test "a root port that tells retries apart is told to" {
    var root = [_]Function{.bridge(0, pci.PCI_EXP_TYPE_ROOT_PORT)};
    root[0].put(root[0].exp + pci.PCI_EXP_RTCAP, 2, pci.PCI_EXP_RTCAP_CRSVIS);
    var space = Space{ .root = &root };
    _ = Run.of(&space, jh7110_windows, .{ .root_devices = 1 });
    try testing.expectEqual(@as(u32, pci.PCI_EXP_RTCTL_CRSSVE), root[0].get(root[0].exp + pci.PCI_EXP_RTCTL, 2));
}

test "more functions than the walk has room for: the rest left out, and said so" {
    var root = [_]Function{
        .make(0, 0x1AF4, 0x1000, 0x02_00_00, 0, 1),
        .make(1, 0x1AF4, 0x1001, 0x01_00_00, 0, 1),
        .make(2, 0x1AF4, 0x1002, 0x05_00_00, 0, 1),
    };
    var space = Space{ .root = &root };
    var nodes: [2]scan.Node = undefined;
    var clock = Clock{};
    const walk = scan.walk(&space, &clock, &nodes, .{}, 0);
    try testing.expect(walk.full);
    try testing.expectEqual(@as(u16, 2), walk.count);
}

test "capabilities: each found on the list, the next after one, a list that runs in a circle ended" {
    var root = [_]Function{.make(0, 0x8086, 0x1533, 0x02_00_00, 0, 1)};
    const f = &root[0];
    const pm = f.cap(pci.PCI_CAP_ID_PM, 8);
    const msi = f.cap(pci.PCI_CAP_ID_MSI, 24);
    const v1 = f.cap(pci.PCI_CAP_ID_VNDR, 8);
    f.express(pci.PCI_EXP_TYPE_ENDPOINT, 0);
    const v2 = f.cap(pci.PCI_CAP_ID_VNDR, 8);
    f.put(msi + pci.PCI_MSI_FLAGS, 2, 3 << 1);
    const aer = f.extCap(pci.PCI_EXT_CAP_ID_ERR, 0x48);
    const dsn = f.extCap(pci.PCI_EXT_CAP_ID_DSN, 12);
    var space = Space{ .root = &root };
    const at = Address{ .bus = 0, .device = 0, .function = 0 };
    try testing.expectEqual(@as(?u32, pm), scan.findCapability(&space, at, pci.PCI_CAP_ID_PM, 0));
    try testing.expectEqual(@as(?u32, v1), scan.findCapability(&space, at, pci.PCI_CAP_ID_VNDR, 0));
    try testing.expectEqual(@as(?u32, v2), scan.findCapability(&space, at, pci.PCI_CAP_ID_VNDR, v1));
    try testing.expectEqual(@as(?u32, null), scan.findCapability(&space, at, pci.PCI_CAP_ID_VNDR, v2));
    try testing.expectEqual(@as(?u32, null), scan.findCapability(&space, at, pci.PCI_CAP_ID_MSIX, 0));
    try testing.expectEqual(@as(?u32, aer), scan.findExtCapability(&space, at, pci.PCI_EXT_CAP_ID_ERR, 0));
    try testing.expectEqual(@as(?u32, dsn), scan.findExtCapability(&space, at, pci.PCI_EXT_CAP_ID_DSN, 0));
    try testing.expectEqual(@as(?u32, null), scan.findExtCapability(&space, at, pci.PCI_EXT_CAP_ID_DSN, dsn));
    try testing.expectEqual(@as(?u32, null), scan.findExtCapability(&space, at, pci.PCI_EXT_CAP_ID_ACS, 0));

    const run = Run.of(&space, qemu_windows, .{});
    try testing.expectEqual(@as(u8, 8), run.nodes[0].info.msi_vectors);
    try testing.expectEqual(@as(u8, @intCast(msi)), run.nodes[0].info.cap_msi);

    // The last one points back at the first.
    f.put(v2 + 1, 1, pm);
    try testing.expectEqual(@as(?u32, null), scan.findCapability(&space, at, pci.PCI_CAP_ID_MSIX, 0));
    // A function without the extended space reads all ones there.
    f.put(0x100, 4, 0xFFFF_FFFF);
    try testing.expectEqual(@as(?u32, null), scan.findExtCapability(&space, at, pci.PCI_EXT_CAP_ID_DSN, 0));
}

test "the JH7110's root port hides its own BARs from the walk, and nothing else" {
    try testing.expect(jh7110.hidden(.{ .bus = 0, .device = 0, .function = 0 }, 0x10));
    try testing.expect(jh7110.hidden(.{ .bus = 0, .device = 0, .function = 0 }, 0x14));
    try testing.expect(!jh7110.hidden(.{ .bus = 0, .device = 0, .function = 0 }, 0x18));
    try testing.expect(!jh7110.hidden(.{ .bus = 1, .device = 0, .function = 0 }, 0x10));
}

test "a window gives each piece at the next multiple of its size, and none past its end" {
    var window = place.Window.of(0x1000, 0x1000, 0x3000);
    try testing.expectEqual(@as(?u64, 0x1000), window.take(0x800, 0x800));
    try testing.expectEqual(@as(?u64, 0x2000), window.take(0x1000, 0x1000));
    try testing.expectEqual(@as(?u64, null), window.take(0x2000, 0x2000));
    try testing.expectEqual(@as(?u64, 0x3000), window.take(0x1000, 0x1000));
    try testing.expectEqual(@as(?u64, null), window.take(0x10, 0x10));
    var none = place.Window{};
    try testing.expectEqual(@as(?u64, null), none.take(0x10, 0x10));
    const io = place.Window.ofIo(0x0300_0000, 0, 0x1_0000);
    try testing.expectEqual(@as(u64, 0x1000), io.next);
    try testing.expectEqual(@as(u64, 0x0300_1000), io.cpuOf(0x1000));
}

// --- message-signalled interrupts --------------------------------------------------------

/// A function at 0:0.0 of a host bridge whose configuration space is
/// memory here, with an MSI-X table in its BAR 0.
const Vectored = struct {
    config: [1024]u32 align(4096) = @splat(0),
    table: [8][4]u32 = @splat(@splat(0)),
    host: _host.Host = .{ .sys = undefined, .chip = .ecam, .segment = 0, .msi_address = 0xFE00_0040, .msi_count = 32 },
    entry: _host.Entry = undefined,

    fn init(v: *Vectored) void {
        v.host.config = @intFromPtr(&v.config);
        _ = _host.start(&v.host);
        v.entry = .{ .device = .{}, .host = &v.host };
        v.word(pci.PCI_COMMAND).* = pci.PCI_COMMAND_MEMORY;
    }

    fn word(v: *Vectored, offset: u32) *u32 {
        return &v.config[offset / 4];
    }

    /// MSI-X with 8 entries, its table at the start of BAR 0.
    fn msix(v: *Vectored) void {
        v.entry.cap_msix = 0x50;
        v.entry.device.msix_vectors = 8;
        v.entry.device.bars[0] = .{ .address = @intFromPtr(&v.table), .size = 0x1000 };
        v.word(0x50).* = @as(u32, pci.PCI_CAP_ID_MSIX) | 7 << 16;
    }

    /// 64-bit MSI that masks its vectors one by one, with 8 of them.
    fn msi(v: *Vectored) void {
        v.entry.cap_msi = 0x60;
        v.entry.device.msi_vectors = 8;
        v.word(0x60).* = @as(u32, pci.PCI_CAP_ID_MSI) | @as(u32, pci.PCI_MSI_FLAGS_64BIT | pci.PCI_MSI_FLAGS_MASKBIT | 3 << 1) << 16;
    }
};

test "MSI-X: as many vectors as asked for, each entry the bridge's address and its vector, masked until it has a server" {
    var v = Vectored{};
    v.init();
    v.msix();
    v.host.msi_used = 0b1;
    try testing.expectEqual(@as(u32, 4), _vectors.allocate(&v.entry, 4));
    try testing.expectEqual(pci.PCI_VECTORS_MSIX, v.entry.device.vector_kind);
    try testing.expectEqual(@as(u16, 4), v.entry.device.vectors);
    try testing.expectEqual(@as(u8, 1), v.entry.vector_base);
    for (0..4) |i| {
        try testing.expectEqual(@as(u32, 0xFE00_0040), v.table[i][0]);
        try testing.expectEqual(@as(u32, 0), v.table[i][1]);
        try testing.expectEqual(@as(u32, @intCast(1 + i)), v.table[i][2]);
        try testing.expectEqual(@as(u32, 1), v.table[i][3]);
    }
    try testing.expectEqual(@as(u32, 1), v.table[7][3]);
    const flags = v.word(0x50).* >> 16;
    try testing.expect(flags & pci.PCI_MSIX_FLAGS_ENABLE != 0);
    try testing.expect(flags & pci.PCI_MSIX_FLAGS_MASKALL == 0);
    try testing.expect(v.word(pci.PCI_COMMAND).* & pci.PCI_COMMAND_INTX_DISABLE != 0);
    try testing.expectEqual(@as(u32, 0b11111), v.host.msi_used);
    // A second call gives what it has.
    try testing.expectEqual(@as(u32, 4), _vectors.allocate(&v.entry, 2));

    _vectors.mask(&v.entry, 2, false);
    try testing.expectEqual(@as(u32, 0), v.table[2][3]);

    _vectors.free(&v.entry);
    try testing.expectEqual(@as(u32, 0b1), v.host.msi_used);
    try testing.expectEqual(@as(u16, 0), v.entry.device.vectors);
    try testing.expect((v.word(0x50).* >> 16) & pci.PCI_MSIX_FLAGS_ENABLE == 0);
    try testing.expect(v.word(pci.PCI_COMMAND).* & pci.PCI_COMMAND_INTX_DISABLE == 0);
}

test "MSI where there is no MSI-X: a power of two of vectors, aligned to it, each masked" {
    var v = Vectored{};
    v.init();
    v.msi();
    v.host.msi_used = 0b1;
    try testing.expectEqual(@as(u32, 2), _vectors.allocate(&v.entry, 3));
    try testing.expectEqual(pci.PCI_VECTORS_MSI, v.entry.device.vector_kind);
    try testing.expectEqual(@as(u8, 2), v.entry.vector_base);
    try testing.expectEqual(@as(u32, 0xFE00_0040), v.word(0x60 + pci.PCI_MSI_ADDRESS_LO).*);
    try testing.expectEqual(@as(u32, 0), v.word(0x60 + pci.PCI_MSI_ADDRESS_HI).*);
    try testing.expectEqual(@as(u32, 2), v.word(0x60 + pci.PCI_MSI_DATA_64).* & 0xFFFF);
    try testing.expectEqual(@as(u32, 0b11), v.word(0x60 + pci.PCI_MSI_MASK_64).*);
    const flags = v.word(0x60).* >> 16;
    try testing.expect(flags & pci.PCI_MSI_FLAGS_ENABLE != 0);
    try testing.expectEqual(@as(u32, 1 << 4), flags & pci.PCI_MSI_FLAGS_QSIZE);
    _vectors.mask(&v.entry, 1, false);
    try testing.expectEqual(@as(u32, 0b01), v.word(0x60 + pci.PCI_MSI_MASK_64).*);
    _vectors.free(&v.entry);
    try testing.expect((v.word(0x60).* >> 16) & pci.PCI_MSI_FLAGS_ENABLE == 0);
    try testing.expectEqual(@as(u32, 0b1), v.host.msi_used);
}

test "no vectors where the bridge takes no messages, nor where a 32-bit MSI cannot reach its address" {
    var v = Vectored{};
    v.init();
    v.msi();
    v.host.msi_count = 0;
    try testing.expectEqual(@as(u32, 0), _vectors.allocate(&v.entry, 1));
    v.host.msi_count = 32;
    v.host.msi_address = 0x1_0000_0000;
    v.word(0x60).* &= ~(@as(u32, pci.PCI_MSI_FLAGS_64BIT) << 16);
    try testing.expectEqual(@as(u32, 0), _vectors.allocate(&v.entry, 1));
    try testing.expectEqual(pci.PCI_VECTORS_NONE, v.entry.device.vector_kind);
    // An MSI-X table whose BAR has no place: MSI is tried, and fails.
    v.msix();
    v.entry.device.bars[0].address = 0;
    try testing.expectEqual(@as(u32, 0), _vectors.allocate(&v.entry, 1));
}

test "the host bridge's vectors are given out in runs, aligned as asked" {
    var host = _host.Host{ .sys = undefined, .chip = .ecam, .segment = 0, .msi_count = 32 };
    try testing.expectEqual(@as(?u8, 0), _host.takeVectors(&host, 1, 1));
    try testing.expectEqual(@as(?u8, 4), _host.takeVectors(&host, 4, 4));
    try testing.expectEqual(@as(?u8, 1), _host.takeVectors(&host, 3, 1));
    try testing.expectEqual(@as(?u8, 16), _host.takeVectors(&host, 16, 16));
    try testing.expectEqual(@as(?u8, null), _host.takeVectors(&host, 16, 16));
    try testing.expectEqual(@as(?u8, 8), _host.takeVectors(&host, 8, 8));
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), host.msi_used);
    _host.giveVectors(&host, 4, 4);
    try testing.expectEqual(@as(u32, 0xFFFF_FF0F), host.msi_used);
    try testing.expectEqual(@as(?u8, null), _host.takeVectors(&host, 33, 1));
}

test "DMA: what a function behind either host bridge moves sees the caches" {
    // QEMU's devices reach memory as its processors do; the JH7110's were
    // measured to on the board.
    try testing.expect(_host.coherent(.ecam));
    try testing.expect(_host.coherent(.jh7110));
}

// --- a function reset behind the library's back ------------------------------------------

test "a function reset since the walk: seen to have lost its BARs or its decoding, and given them back" {
    var v = Vectored{};
    v.init();
    v.msi();
    v.word(pci.PCI_BASE_ADDRESS_0).* = 0x3800_0004;
    v.word(pci.PCI_BASE_ADDRESS_0 + 4).* = 0;
    v.word(pci.PCI_INTERRUPT_LINE).* = 0x0139;
    v.word(pci.PCI_CACHE_LINE_SIZE).* = 0x10;
    v.entry.kept = _state.save(&v.entry);
    try testing.expect(!_state.lost(&v.entry, &v.entry.kept));
    // Its driver's bus mastering is no loss.
    v.word(pci.PCI_COMMAND).* |= pci.PCI_COMMAND_MASTER;
    try testing.expect(!_state.lost(&v.entry, &v.entry.kept));

    // What its reset leaves.
    v.word(pci.PCI_COMMAND).* = 0;
    v.word(pci.PCI_BASE_ADDRESS_0).* = 0x0000_0004;
    v.word(pci.PCI_INTERRUPT_LINE).* = 0x0100;
    v.word(pci.PCI_CACHE_LINE_SIZE).* = 0;
    try testing.expect(_state.lost(&v.entry, &v.entry.kept));
    _state.restore(&v.entry, &v.entry.kept);
    try testing.expectEqual(@as(u32, 0x3800_0004), v.word(pci.PCI_BASE_ADDRESS_0).*);
    try testing.expectEqual(@as(u32, pci.PCI_COMMAND_MEMORY), v.word(pci.PCI_COMMAND).* & 0xFFFF);
    try testing.expectEqual(@as(u32, 0x0139), v.word(pci.PCI_INTERRUPT_LINE).* & 0xFFFF);
    try testing.expectEqual(@as(u32, 0x10), v.word(pci.PCI_CACHE_LINE_SIZE).* & 0xFFFF);
    try testing.expect(!_state.lost(&v.entry, &v.entry.kept));

    // Its decoding alone gone is a loss too.
    v.word(pci.PCI_COMMAND).* = 0;
    try testing.expect(_state.lost(&v.entry, &v.entry.kept));
    // A function that does not answer has nothing to be given yet.
    v.word(pci.PCI_VENDOR_ID).* = 0xFFFF_FFFF;
    try testing.expect(!_state.lost(&v.entry, &v.entry.kept));
}
