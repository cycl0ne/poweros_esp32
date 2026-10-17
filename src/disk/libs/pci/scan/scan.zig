// SPDX-License-Identifier: MIT
//! The buses behind a host bridge walked, as the library is first opened:
//! every function found, the buses behind each PCI-to-PCI bridge
//! numbered, every memory BAR put in a window, and memory decoding
//! switched on where a function got its memory.
//!
//! The walk goes deep first. A bridge's buses take the numbers after its
//! own bus, and what is behind it takes its memory from where the windows
//! are filled to as the walk reaches it; the bridge forwards from there,
//! aligned to its 1 MiB, to where its last function's BAR ends. A BAR is
//! put at the next address its size is a multiple of: the windows fill
//! in the order the functions come, which is enough for the few a board
//! has.
//!
//! Which window: a prefetchable 64-bit BAR goes in the prefetchable
//! window where there is one and it has room, everything else - and one
//! the prefetchable window has no room for - below 4 GiB. I/O BARs are
//! sized, and left where they are with I/O decoding off: no bridge here
//! forwards I/O space, and the functions a board has want none.
//!
//! A PCI Express root port and a switch's downstream port have one device
//! below them, device 0: the others on their bus are not asked, which
//! some links would answer with an error rather than with nothing.
//!
//! **A function's INTx line** at the host bridge is its own pin, rotated
//! by its device number at each bridge between it and the bridge's bus
//! (PCI-to-PCI bridge architecture, 9.1): `Function.root_device` and
//! `root_pin` are what the host bridge's interrupt map is looked up with.
//!
//! The configuration space is `space`'s, which has
//!
//!     read(at: Address, offset: u32, size: u32) u32
//!     write(at: Address, offset: u32, size: u32, value: u32) void
//!
//! for 1, 2 and 4 bytes, and what is found goes to `found`'s
//! `function(at: Address, info: *const Function) bool`, false when it
//! cannot keep it - then the walk stops.

const sdk = @import("sdk");
const pci = sdk.pci;

/// Where a function is.
pub const Address = struct {
    bus: u8,
    device: u8,
    function: u8,
};

/// What the walk found of a function.
pub const Function = struct {
    vendor_id: u16,
    device_id: u16,
    class_code: u32,
    revision: u8,
    header_type: u8,
    interrupt_pin: u8,
    subsystem_vendor: u16 = 0,
    subsystem_id: u16 = 0,
    bars: [6]pci.PCIBar = @splat(.{}),
    /// The device on the host bridge's bus the function is behind (or is),
    /// and its INTx line there, 1 to 4 (0: it has none).
    root_device: u8 = 0,
    root_pin: u8 = 0,
};

/// A window of bus memory, and how far it is filled.
pub const Window = struct {
    base: u64 = 0,
    size: u64 = 0,
    next: u64 = 0,

    pub fn of(base: u64, size: u64) Window {
        return .{ .base = base, .size = size, .next = base };
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

    fn alignTo(window: *Window, alignment: u64) void {
        if (window.size == 0) return;
        window.next = @min(alignUp(window.next, alignment), window.base + window.size);
    }
};

pub const Windows = struct {
    /// Below 4 GiB, which any BAR may be put in.
    mem: Window = .{},
    /// Prefetchable, for 64-bit BARs that may be read ahead.
    pref: Window = .{},
};

pub const Limits = struct {
    /// The devices asked on the host bridge's own bus: 32, or 1 where it
    /// is a root port and nothing else.
    root_devices: u8 = 32,
};

/// How deep bridges are followed.
const max_depth = 8;
/// What a bridge forwards is aligned to this.
const bridge_align: u64 = 1 << 20;

/// The walk, from `root_bus`. The last bus number it gave a bridge.
pub fn walk(space: anytype, found: anytype, windows: *Windows, limits: Limits, root_bus: u8) u8 {
    var walker: Walker(@TypeOf(space), @TypeOf(found)) = .{
        .space = space,
        .found = found,
        .windows = windows,
        .last_bus = root_bus,
    };
    _ = walker.bus(root_bus, limits.root_devices);
    return walker.last_bus;
}

fn Walker(comptime Space: type, comptime Found: type) type {
    return struct {
        const Self = @This();

        space: Space,
        found: Found,
        windows: *Windows,
        last_bus: u8,
        /// The device numbers of the bridges between the host bridge's bus
        /// and the one being walked.
        path: [max_depth]u8 = undefined,
        depth: u8 = 0,
        stopped: bool = false,

        fn read(self: *Self, at: Address, offset: u32, size: u32) u32 {
            return self.space.read(at, offset, size);
        }

        fn write(self: *Self, at: Address, offset: u32, size: u32, value: u32) void {
            self.space.write(at, offset, size, value);
        }

        /// Every device on `number` up to `devices`. The last bus number
        /// used at or below it.
        fn bus(self: *Self, number: u8, devices: u8) void {
            var device: u8 = 0;
            while (device < devices and !self.stopped) : (device += 1) {
                const first = Address{ .bus = number, .device = device, .function = 0 };
                if (self.read(first, pci.PCI_VENDOR_ID, 2) == 0xFFFF) continue;
                const multi = self.read(first, pci.PCI_HEADER_TYPE, 1) & pci.PCI_HEADER_MULTI != 0;
                const functions: u8 = if (multi) 8 else 1;
                var function: u8 = 0;
                while (function < functions and !self.stopped) : (function += 1) {
                    const at = Address{ .bus = number, .device = device, .function = function };
                    if (self.read(at, pci.PCI_VENDOR_ID, 2) == 0xFFFF) continue;
                    self.one(at);
                }
            }
        }

        /// One function: what it is, its BARs placed, and the buses behind
        /// it if it is a bridge.
        fn one(self: *Self, at: Address) void {
            const class_word = self.read(at, pci.PCI_REVISION_ID, 4);
            const header = @as(u8, @truncate(self.read(at, pci.PCI_HEADER_TYPE, 1))) & ~pci.PCI_HEADER_MULTI;
            const pin: u8 = @truncate(self.read(at, pci.PCI_INTERRUPT_PIN, 1));
            var info = Function{
                .vendor_id = @truncate(self.read(at, pci.PCI_VENDOR_ID, 2)),
                .device_id = @truncate(self.read(at, pci.PCI_DEVICE_ID, 2)),
                .class_code = class_word >> 8,
                .revision = @truncate(class_word),
                .header_type = header,
                .interrupt_pin = if (pin >= 1 and pin <= 4) pin else 0,
            };
            if (info.interrupt_pin != 0) {
                const line = self.rootLine(at.device, info.interrupt_pin);
                info.root_device = line.device;
                info.root_pin = line.pin;
            } else {
                info.root_device = if (self.depth == 0) at.device else self.path[0];
            }
            // Nothing decoded while its BARs are sized and moved.
            const command: u16 = @truncate(self.read(at, pci.PCI_COMMAND, 2));
            self.write(at, pci.PCI_COMMAND, 2, command & ~(pci.PCI_COMMAND_IO | pci.PCI_COMMAND_MEMORY | pci.PCI_COMMAND_MASTER));
            const bar_count: u32 = switch (header) {
                pci.PCI_HEADER_NORMAL => 6,
                pci.PCI_HEADER_BRIDGE => 2,
                else => 0,
            };
            const placed = self.bars(at, bar_count, &info.bars);
            if (header == pci.PCI_HEADER_NORMAL) {
                info.subsystem_vendor = @truncate(self.read(at, pci.PCI_SUBSYSTEM_VENDOR_ID, 2));
                info.subsystem_id = @truncate(self.read(at, pci.PCI_SUBSYSTEM_ID, 2));
            }
            // A cache line of 64 bytes, in words.
            self.write(at, pci.PCI_CACHE_LINE_SIZE, 1, 64 / 4);
            if (!self.found.function(at, &info)) {
                self.stopped = true;
                return;
            }
            if (header == pci.PCI_HEADER_BRIDGE) {
                self.bridge(at);
            } else if (placed) {
                self.write(at, pci.PCI_COMMAND, 2, (command & ~(pci.PCI_COMMAND_IO | pci.PCI_COMMAND_MASTER)) | pci.PCI_COMMAND_MEMORY);
            }
        }

        /// The device and INTx line at the host bridge's bus of pin `pin`
        /// of device `device` on the bus being walked.
        fn rootLine(self: *Self, device: u8, pin: u8) struct { device: u8, pin: u8 } {
            var d = device;
            var p = pin;
            var i = self.depth;
            while (i > 0) {
                i -= 1;
                p = @intCast((p - 1 + d) % 4 + 1);
                d = self.path[i];
            }
            return .{ .device = d, .pin = p };
        }

        /// The function's `count` BARs sized, and its memory ones placed.
        /// Whether one was.
        fn bars(self: *Self, at: Address, count: u32, into: *[6]pci.PCIBar) bool {
            var placed = false;
            var i: u32 = 0;
            while (i < count) {
                const offset = pci.PCI_BASE_ADDRESS_0 + 4 * i;
                const was = self.read(at, offset, 4);
                self.write(at, offset, 4, 0xFFFF_FFFF);
                const mask = self.read(at, offset, 4);
                self.write(at, offset, 4, was);
                if (mask == 0 or mask == 0xFFFF_FFFF) {
                    i += 1;
                    continue;
                }
                if (mask & pci.PCI_BASE_ADDRESS_SPACE_IO != 0) {
                    const io_mask = mask & 0xFFFF_FFFC;
                    into[i] = .{ .size = (~io_mask +% 1) & 0xFFFF, .flags = pci.PCIBAR_IO };
                    i += 1;
                    continue;
                }
                const wide = mask & 0x6 == pci.PCI_BASE_ADDRESS_MEM_TYPE_64 and i + 1 < count;
                var full: u64 = 0xFFFF_FFFF_0000_0000 | @as(u64, mask & 0xFFFF_FFF0);
                if (wide) {
                    const high_was = self.read(at, offset + 4, 4);
                    self.write(at, offset + 4, 4, 0xFFFF_FFFF);
                    const high = self.read(at, offset + 4, 4);
                    self.write(at, offset + 4, 4, high_was);
                    full = (@as(u64, high) << 32) | @as(u64, mask & 0xFFFF_FFF0);
                }
                const size = ~full +% 1;
                var flags: u32 = 0;
                if (wide) flags |= pci.PCIBAR_64;
                if (mask & pci.PCI_BASE_ADDRESS_MEM_PREFETCH != 0) flags |= pci.PCIBAR_PREFETCH;
                into[i] = .{ .size = size, .flags = flags };
                if (size != 0) {
                    if (self.place(size, flags)) |address| {
                        into[i].address = address;
                        self.write(at, offset, 4, @truncate(address));
                        if (wide) self.write(at, offset + 4, 4, @truncate(address >> 32));
                        placed = true;
                    }
                }
                i += if (wide) 2 else 1;
            }
            return placed;
        }

        /// Room for a BAR of `size`, aligned to it, in the window it
        /// belongs in.
        fn place(self: *Self, size: u64, flags: u32) ?u64 {
            const prefetchable_wide = flags & pci.PCIBAR_PREFETCH != 0 and flags & pci.PCIBAR_64 != 0;
            if (prefetchable_wide) {
                if (self.windows.pref.take(size, size)) |at| return at;
            }
            if (size > 0xFFFF_FFFF) return null;
            return self.windows.mem.take(size, size);
        }

        /// A PCI-to-PCI bridge: its buses numbered, the walk behind it, and
        /// its windows set to what the walk put there.
        fn bridge(self: *Self, at: Address) void {
            if (self.depth == max_depth or self.last_bus == 0xFF) return;
            self.last_bus += 1;
            const secondary = self.last_bus;
            self.write(at, pci.PCI_PRIMARY_BUS, 1, at.bus);
            self.write(at, pci.PCI_SECONDARY_BUS, 1, secondary);
            // Everything below reached while the walk is there.
            self.write(at, pci.PCI_SUBORDINATE_BUS, 1, 0xFF);
            // No I/O forwarded: its base above its limit.
            self.write(at, pci.PCI_IO_BASE, 1, 0xF0);
            self.write(at, pci.PCI_IO_LIMIT, 1, 0x00);

            self.windows.mem.alignTo(bridge_align);
            self.windows.pref.alignTo(bridge_align);
            const mem_from = self.windows.mem.next;
            const pref_from = self.windows.pref.next;
            // Forwarding on while the walk asks what is behind it.
            self.write(at, pci.PCI_MEMORY_BASE, 2, 0xFFF0);
            self.write(at, pci.PCI_MEMORY_LIMIT, 2, 0x0000);
            self.write(at, pci.PCI_PREF_MEMORY_BASE, 2, 0xFFF0);
            self.write(at, pci.PCI_PREF_MEMORY_LIMIT, 2, 0x0000);
            self.write(at, pci.PCI_PREF_BASE_UPPER32, 4, 0);
            self.write(at, pci.PCI_PREF_LIMIT_UPPER32, 4, 0);

            self.path[self.depth] = at.device;
            self.depth += 1;
            self.bus(secondary, if (self.oneBelow(at)) 1 else 32);
            self.depth -= 1;
            self.write(at, pci.PCI_SUBORDINATE_BUS, 1, self.last_bus);

            self.windows.mem.alignTo(bridge_align);
            self.windows.pref.alignTo(bridge_align);
            if (self.windows.mem.next != mem_from) {
                self.write(at, pci.PCI_MEMORY_BASE, 2, @as(u32, @truncate(mem_from >> 16)) & 0xFFF0);
                self.write(at, pci.PCI_MEMORY_LIMIT, 2, @as(u32, @truncate((self.windows.mem.next - 1) >> 16)) & 0xFFF0);
            }
            if (self.windows.pref.next != pref_from) {
                const limit = self.windows.pref.next - 1;
                self.write(at, pci.PCI_PREF_MEMORY_BASE, 2, @as(u32, @truncate(pref_from >> 16)) & 0xFFF0);
                self.write(at, pci.PCI_PREF_MEMORY_LIMIT, 2, @as(u32, @truncate(limit >> 16)) & 0xFFF0);
                self.write(at, pci.PCI_PREF_BASE_UPPER32, 4, @truncate(pref_from >> 32));
                self.write(at, pci.PCI_PREF_LIMIT_UPPER32, 4, @truncate(limit >> 32));
            }
            // Forwarding memory both ways: what is behind it reads and
            // writes RAM through it.
            const command: u16 = @truncate(self.read(at, pci.PCI_COMMAND, 2));
            self.write(at, pci.PCI_COMMAND, 2, (command & ~pci.PCI_COMMAND_IO) | pci.PCI_COMMAND_MEMORY | pci.PCI_COMMAND_MASTER);
        }

        /// Whether the bridge is a PCI Express port with one device below
        /// it: a root port or a switch's downstream port.
        fn oneBelow(self: *Self, at: Address) bool {
            const kind = expressPortType(self.space, at) orelse return false;
            return kind == pci.PCI_EXP_TYPE_ROOT_PORT or kind == pci.PCI_EXP_TYPE_DOWNSTREAM;
        }
    };
}

/// A function's PCI Express port type, or null if it has no PCI Express
/// capability.
pub fn expressPortType(space: anytype, at: Address) ?u8 {
    const at_cap = findCapability(space, at, pci.PCI_CAP_ID_EXP) orelse return null;
    const flags = space.read(at, at_cap + 2, 2);
    return @truncate((flags >> 4) & 0xF);
}

/// Where capability `id` is in a function's configuration space, or null.
pub fn findCapability(space: anytype, at: Address, id: u8) ?u32 {
    if (space.read(at, pci.PCI_STATUS, 2) & pci.PCI_STATUS_CAP_LIST == 0) return null;
    var pointer = space.read(at, pci.PCI_CAPABILITY_LIST, 1) & 0xFC;
    // A list that runs in a circle ends: there is room for 48.
    var left: u32 = 48;
    while (pointer >= 0x40 and left > 0) : (left -= 1) {
        if (space.read(at, pointer, 1) == id) return pointer;
        pointer = space.read(at, pointer + 1, 1) & 0xFC;
    }
    return null;
}

fn alignUp(value: u64, alignment: u64) u64 {
    if (alignment <= 1) return value;
    return (value + alignment - 1) & ~(alignment - 1);
}
