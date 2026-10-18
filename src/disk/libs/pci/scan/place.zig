// SPDX-License-Identifier: MIT
//! Where everything the walk found goes (`scan.zig`), once the whole tree
//! behind a host bridge is known; then the functions and the bridges are
//! told, and their decoding switched on.
//!
//! **Which window.** An I/O BAR goes in I/O space, where the host bridge
//! has a window for it and every bridge above the function forwards I/O.
//! A prefetchable BAR goes in the prefetchable window where there is one,
//! every bridge above has one too, and the BAR can be put where the
//! window is: a 32-bit one only below 4 GiB, and above 4 GiB only through
//! bridges whose window is 64 bits. Everything else - and a prefetchable
//! BAR that cannot go there - is memory below 4 GiB, which every bridge
//! forwards. An expansion ROM is memory below 4 GiB too, and the first to
//! be left out when that is short: the walk is placed once more without
//! the ROMs if not everything fit.
//!
//! **How large a bridge's windows are** is what is behind it, worked out
//! from the bottom up: on each bus the pieces of a kind - BARs, ROMs and
//! the windows of the bridges on it - are laid out the largest alignment
//! first, each at the next multiple of its own, and the bridge's window
//! is that run rounded up to what a bridge's window counts in (4 KiB of
//! I/O, 1 MiB of memory), aligned as its most aligned piece is. Laid out
//! in that order, power-of-two pieces leave no gaps.
//!
//! **Where it goes** is worked out from the top down: the pieces on the
//! host bridge's bus are taken from its windows in the same order, each
//! bridge's window as one piece, and then each bridge's pieces laid out in
//! its window as they were sized - which they always fit. A piece the
//! host's window has no room for has no place, nor has anything in a
//! bridge's window that has none.
//!
//! **What is switched on**: a function's memory decoding if it has memory
//! BARs and every one of them has its place, and likewise its I/O
//! decoding; never its bus mastering, which is its driver's to switch on.
//! A bridge forwards the windows that have their place, and masters the
//! bus: what is behind it reads and writes memory through it.
//!
//! **The payload.** A PCI Express function sends and takes transactions
//! of up to its maximum payload, and one larger than what a link partner
//! takes is a malformed packet: every PCI Express function behind the host
//! bridge is set to the smallest that all of them take.

const sdk = @import("sdk");
const pci = sdk.pci;
const scan = @import("scan.zig");
const Node = scan.Node;
const Kind = scan.Kind;
const kinds = scan.kinds;
const Address = scan.Address;

/// One of the host bridge's windows: where it starts on the bus and for
/// the processor, its size, and how far it is filled.
pub const Window = struct {
    base: u64 = 0,
    cpu: u64 = 0,
    size: u64 = 0,
    next: u64 = 0,

    /// `size` bytes at `bus` on the bus, which the processor reaches at
    /// `cpu`.
    pub fn of(cpu: u64, bus: u64, size: u64) Window {
        return .{ .base = bus, .cpu = cpu, .size = size, .next = bus };
    }

    /// An I/O window: its first 4 KiB of ports left alone, which is where
    /// a PC's own devices are and what some functions take a BAR there
    /// to be.
    pub fn ofIo(cpu: u64, bus: u64, size: u64) Window {
        var window = of(cpu, bus, size);
        if (size > io_floor and bus < io_floor) window.next = io_floor;
        return window;
    }

    /// `bytes` at the next multiple of `alignment` with room; null if the
    /// window has none.
    pub fn take(window: *Window, bytes: u64, alignment: u64) ?u64 {
        if (window.size == 0 or bytes == 0) return null;
        const at = alignUp(window.next, alignment);
        if (at < window.next or at - window.base > window.size or bytes > window.size - (at - window.base)) return null;
        window.next = at + bytes;
        return at;
    }

    /// Where the processor reaches bus address `bus` in the window.
    pub fn cpuOf(window: *const Window, bus: u64) u64 {
        return window.cpu +% (bus -% window.base);
    }

    /// Whether all of the window is below 64 KiB on the bus: where a
    /// bridge with a 16-bit I/O window can forward it.
    pub fn below64k(window: *const Window) bool {
        return window.size != 0 and window.base + window.size <= 0x1_0000;
    }

    /// Whether all of the window is below 4 GiB on the bus.
    pub fn low(window: *const Window) bool {
        return window.size != 0 and window.base + window.size <= four_gib;
    }
};

pub const Windows = struct {
    io: Window = .{},
    /// Below 4 GiB, which any BAR may be put in.
    mem: Window = .{},
    /// Prefetchable, which may be above 4 GiB.
    pref: Window = .{},

    pub fn of(windows: *Windows, kind: Kind) *Window {
        return switch (kind) {
            .io => &windows.io,
            .mem => &windows.mem,
            .pref => &windows.pref,
        };
    }
};

const four_gib: u64 = 1 << 32;
const io_floor: u64 = 0x1000;
/// What a bridge's windows count in: 4 KiB of I/O, 1 MiB of memory.
const granularity = [3]u64{ 0x1000, 1 << 20, 1 << 20 };

/// Everything the walk found placed, the functions and bridges told, and
/// the payload set. `windows` are filled to where the placing left them.
pub fn place(space: anytype, nodes: []Node, windows: *Windows) void {
    const start = windows.*;
    if (!assign(nodes, windows, true)) {
        windows.* = start;
        _ = assign(nodes, windows, false);
    }
    for (nodes) |*node| addresses(node, windows);
    for (nodes) |*node| program(space, node);
    payload(space, nodes);
}

/// Every piece's kind, every bridge's windows sized, and the pieces given
/// their places. Whether every piece of memory below 4 GiB got one - what
/// the ROMs take room from.
fn assign(nodes: []Node, windows: *Windows, roms: bool) bool {
    for (nodes) |*node| classify(nodes, node, windows, roms);
    var i = nodes.len;
    while (i > 0) {
        i -= 1;
        if (nodes[i].bridge) sizeWindows(nodes, @intCast(i));
    }
    var all = true;
    for (kinds) |kind| {
        if (!fill(nodes, null, kind, windows.of(kind)) and kind == .mem) all = false;
    }
    for (nodes, 0..) |*node, n| {
        if (!node.bridge) continue;
        for (kinds) |kind| {
            const span = &node.windows[@intFromEnum(kind)];
            if (span.size == 0) continue;
            var inside: Window = if (span.placed) .of(0, span.base, span.size) else .{};
            if (!fill(nodes, @intCast(n), kind, &inside) and kind == .mem) all = false;
        }
    }
    return all;
}

/// Which window each of a function's pieces goes in.
fn classify(nodes: []const Node, node: *Node, windows: *const Windows, roms: bool) void {
    node.kind = @splat(null);
    node.bus = @splat(0);
    for (&node.windows) |*span| span.* = .{};
    for (node.info.bars, 0..) |bar, s| {
        if (bar.size == 0) continue;
        node.kind[s] = kindOf(nodes, node.parent, bar, windows);
    }
    if (roms and node.info.rom.size != 0 and windows.mem.size != 0) node.kind[scan.rom_slot] = .mem;
}

fn kindOf(nodes: []const Node, parent: ?u16, bar: pci.PCIBar, windows: *const Windows) ?Kind {
    if (bar.flags & pci.PCIBAR_IO != 0) {
        return if (carries(nodes, parent, .io, windows)) .io else null;
    }
    if (bar.flags & pci.PCIBAR_PREFETCH != 0 and carries(nodes, parent, .pref, windows)) {
        if (bar.flags & pci.PCIBAR_64 != 0 or windows.pref.low()) return .pref;
    }
    if (windows.mem.size == 0 or bar.size >= four_gib) return null;
    return .mem;
}

/// Whether the bus behind `parent` (null: the host bridge's) is reached
/// through windows of `kind` all the way up.
fn carries(nodes: []const Node, parent: ?u16, kind: Kind, windows: *const Windows) bool {
    var at = parent;
    while (at) |index| {
        const bridge = &nodes[index];
        switch (kind) {
            .io => if (!bridge.has_io or (!bridge.io32 and !windows.io.below64k())) return false,
            .mem => {},
            .pref => if (!bridge.has_pref or (!bridge.pref64 and !windows.pref.low())) return false,
        }
        at = bridge.parent;
    }
    return switch (kind) {
        .io => windows.io.size != 0,
        .mem => windows.mem.size != 0,
        .pref => windows.pref.size != 0,
    };
}

/// Bridge `index`'s windows: what is behind it, laid out as `fill` lays
/// it out.
fn sizeWindows(nodes: []Node, index: u16) void {
    for (kinds) |kind| {
        const k = @intFromEnum(kind);
        var end: u64 = 0;
        var most: u64 = 0;
        var it = Pieces.of(nodes, index, kind);
        while (it.next()) |piece| {
            end = alignUp(end, piece.alignment) + piece.size;
            most = @max(most, piece.alignment);
        }
        const span = &nodes[index].windows[k];
        if (end == 0) continue;
        span.size = alignUp(end, granularity[k]);
        span.alignment = @max(most, granularity[k]);
    }
}

/// The pieces of `kind` on the bus behind `parent` (null: the host
/// bridge's) given their places in `window`. Whether every one got one.
fn fill(nodes: []Node, parent: ?u16, kind: Kind, window: *Window) bool {
    var all = true;
    var it = Pieces.of(nodes, parent, kind);
    while (it.next()) |piece| {
        const node = &nodes[piece.node];
        const at = window.take(piece.size, piece.alignment);
        if (piece.slot) |s| {
            if (at) |bus| node.bus[s] = bus else node.kind[s] = null;
        } else {
            const span = &node.windows[@intFromEnum(kind)];
            if (at) |bus| {
                span.base = bus;
                span.placed = true;
            }
        }
        if (at == null) all = false;
    }
    return all;
}

/// One piece of a bus's: a function's slot, or a bridge's window.
const Piece = struct {
    node: u16,
    /// The slot (scan.Node.kind); null for a bridge's window.
    slot: ?u8,
    size: u64,
    alignment: u64,
};

/// The pieces of one kind on one bus, the largest alignment first, and
/// in the walk's order among those of the same.
const Pieces = struct {
    nodes: []const Node,
    parent: ?u16,
    kind: Kind,
    /// The alignment being gone through - 0 before the first - and where
    /// in it the iteration is.
    alignment: u64 = 0,
    node: usize = 0,
    slot: u8 = 0,

    fn of(nodes: []const Node, parent: ?u16, kind: Kind) Pieces {
        return .{ .nodes = nodes, .parent = parent, .kind = kind };
    }

    fn next(it: *Pieces) ?Piece {
        while (true) {
            if (it.alignment == 0 or it.node == it.nodes.len) {
                it.alignment = it.largestBelow(it.alignment) orelse return null;
                it.node = 0;
                it.slot = 0;
            }
            while (it.node < it.nodes.len) {
                const node = &it.nodes[it.node];
                if (node.parent == it.parent) {
                    // The slots 0 to 6, then the bridge's window (7).
                    while (it.slot <= scan.slots) {
                        const s = it.slot;
                        it.slot += 1;
                        const piece = it.pieceAt(it.node, s) orelse continue;
                        if (piece.alignment == it.alignment) return piece;
                    }
                }
                it.node += 1;
                it.slot = 0;
            }
        }
    }

    /// The largest alignment of a piece below `than` (0: of any piece).
    fn largestBelow(it: *const Pieces, than: u64) ?u64 {
        var largest: ?u64 = null;
        for (it.nodes, 0..) |*node, n| {
            if (node.parent != it.parent) continue;
            var s: u8 = 0;
            while (s <= scan.slots) : (s += 1) {
                const piece = it.pieceAt(n, s) orelse continue;
                if (than != 0 and piece.alignment >= than) continue;
                if (largest == null or piece.alignment > largest.?) largest = piece.alignment;
            }
        }
        return largest;
    }

    fn pieceAt(it: *const Pieces, n: usize, s: u8) ?Piece {
        const node = &it.nodes[n];
        const index: u16 = @intCast(n);
        if (s == scan.slots) {
            if (!node.bridge) return null;
            const span = node.windows[@intFromEnum(it.kind)];
            if (span.size == 0) return null;
            return .{ .node = index, .slot = null, .size = span.size, .alignment = span.alignment };
        }
        if (node.kind[s] != it.kind) return null;
        const bytes = if (s == scan.rom_slot) node.info.rom.size else node.info.bars[s].size;
        return .{ .node = index, .slot = s, .size = bytes, .alignment = powerAbove(bytes) };
    }
};

/// Where the processor reaches each placed piece of the function.
fn addresses(node: *Node, windows: *Windows) void {
    for (0..scan.slots) |s| {
        const bar = if (s == scan.rom_slot) &node.info.rom else &node.info.bars[s];
        bar.address = if (node.kind[s]) |kind| windows.of(kind).cpuOf(node.bus[s]) else 0;
    }
}

/// The function's BARs and ROM, a bridge's windows, and the decoding,
/// written.
fn program(space: anytype, node: *const Node) void {
    const at = node.at;
    const info = &node.info;
    var has_io = false;
    var has_mem = false;
    var io_placed = true;
    var mem_placed = true;
    var i: u32 = 0;
    while (i < 6) : (i += 1) {
        const bar = info.bars[i];
        if (bar.size == 0) continue;
        const placed = node.kind[i] != null;
        if (bar.flags & pci.PCIBAR_IO != 0) {
            has_io = true;
            io_placed = io_placed and placed;
        } else {
            has_mem = true;
            mem_placed = mem_placed and placed;
        }
        if (!placed) continue;
        const offset = pci.PCI_BASE_ADDRESS_0 + 4 * i;
        const bus = node.bus[i];
        space.write(at, offset, 4, @truncate(bus));
        if (bar.flags & pci.PCIBAR_64 != 0) space.write(at, offset + 4, 4, @truncate(bus >> 32));
    }
    if (node.kind[scan.rom_slot] != null) {
        const offset: u32 = if (info.header_type == pci.PCI_HEADER_BRIDGE) pci.PCI_ROM_ADDRESS1 else pci.PCI_ROM_ADDRESS;
        space.write(at, offset, 4, @as(u32, @truncate(node.bus[scan.rom_slot])) & pci.PCI_ROM_ADDRESS_MASK);
    }

    var command: u16 = @truncate(space.read(at, pci.PCI_COMMAND, 2));
    command &= ~(pci.PCI_COMMAND_IO | pci.PCI_COMMAND_MEMORY | pci.PCI_COMMAND_MASTER);
    if (node.bridge) {
        bridgeWindows(space, node);
        if (node.windows[@intFromEnum(Kind.io)].placed) command |= pci.PCI_COMMAND_IO;
        if (node.windows[@intFromEnum(Kind.mem)].placed or node.windows[@intFromEnum(Kind.pref)].placed) command |= pci.PCI_COMMAND_MEMORY;
        command |= pci.PCI_COMMAND_MASTER;
    }
    if (has_io and io_placed) command |= pci.PCI_COMMAND_IO;
    if (has_mem and mem_placed) command |= pci.PCI_COMMAND_MEMORY;
    space.write(at, pci.PCI_COMMAND, 2, command);
}

/// A bridge's windows written: each that has its place, and the others
/// shut.
fn bridgeWindows(space: anytype, node: *const Node) void {
    const at = node.at;
    scan.closeWindows(space, at);
    const io = node.windows[@intFromEnum(Kind.io)];
    if (io.placed) {
        const limit = io.base + io.size - 1;
        space.write(at, pci.PCI_IO_BASE, 1, @as(u32, @truncate(io.base >> 8)) & 0xF0);
        space.write(at, pci.PCI_IO_LIMIT, 1, @as(u32, @truncate(limit >> 8)) & 0xF0);
        if (node.io32) {
            space.write(at, pci.PCI_IO_BASE_UPPER16, 2, @truncate(io.base >> 16));
            space.write(at, pci.PCI_IO_LIMIT_UPPER16, 2, @truncate(limit >> 16));
        }
    }
    const mem = node.windows[@intFromEnum(Kind.mem)];
    if (mem.placed) {
        const limit = mem.base + mem.size - 1;
        space.write(at, pci.PCI_MEMORY_BASE, 2, @as(u32, @truncate(mem.base >> 16)) & 0xFFF0);
        space.write(at, pci.PCI_MEMORY_LIMIT, 2, @as(u32, @truncate(limit >> 16)) & 0xFFF0);
    }
    const pref = node.windows[@intFromEnum(Kind.pref)];
    if (pref.placed) {
        const limit = pref.base + pref.size - 1;
        // The upper halves first: with the lower ones written the window
        // would otherwise be open, for a moment, where it does not belong.
        if (node.pref64) {
            space.write(at, pci.PCI_PREF_BASE_UPPER32, 4, @truncate(pref.base >> 32));
            space.write(at, pci.PCI_PREF_LIMIT_UPPER32, 4, @truncate(limit >> 32));
        }
        space.write(at, pci.PCI_PREF_MEMORY_BASE, 2, @as(u32, @truncate(pref.base >> 16)) & 0xFFF0);
        space.write(at, pci.PCI_PREF_MEMORY_LIMIT, 2, @as(u32, @truncate(limit >> 16)) & 0xFFF0);
    }
}

/// Every PCI Express function's payload the smallest all of them take.
fn payload(space: anytype, nodes: []Node) void {
    var least: ?u3 = null;
    for (nodes) |*node| {
        const exp = node.info.cap_express;
        if (exp == 0) continue;
        const code = scan.payloadCode(space, node.at, exp);
        least = if (least) |so_far| @min(so_far, code) else code;
    }
    const code = least orelse return;
    for (nodes) |*node| {
        const exp = node.info.cap_express;
        if (exp == 0) continue;
        const control = space.read(node.at, exp + pci.PCI_EXP_DEVCTL, 2);
        space.write(node.at, exp + pci.PCI_EXP_DEVCTL, 2, (control & ~@as(u32, pci.PCI_EXP_DEVCTL_PAYLOAD)) | (@as(u32, code) << 5));
        node.info.max_payload = @as(u16, 128) << code;
    }
}

/// The power of two at or above `value`: what a piece is aligned to. A
/// BAR's size is one; anything else is rounded up to it.
fn powerAbove(value: u64) u64 {
    if (value <= 1) return 1;
    return @as(u64, 1) << @intCast(64 - @clz(value - 1));
}

fn alignUp(value: u64, alignment: u64) u64 {
    if (alignment <= 1) return value;
    return (value + alignment - 1) & ~(alignment - 1);
}
