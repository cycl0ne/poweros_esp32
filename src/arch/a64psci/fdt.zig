// SPDX-License-Identifier: MPL-2.0
//! What the kernel reads from the device tree the firmware passes in x0:
//! RAM - every range of every `/memory` node, as the Pi's firmware lists
//! its RAM in pieces - the disk image the loader put in RAM beside the
//! kernel (`/chosen`'s `linux,initrd-start` and `linux,initrd-end`,
//! which QEMU's -initrd and the Pi's firmware write), and the RAM that is
//! not the kernel's: the header's reservation block and every
//! `/reserved-memory` node with a `reg` (where the firmware keeps
//! itself); how PSCI is called (`/psci`'s `method`, `smc` or `hvc`); and
//! the cores that can run the kernel - every `/cpus/cpu@` node of
//! `device_type` "cpu" that is not disabled, by its MPIDR affinity
//! (`reg`). And each network port's station address: the
//! `local-mac-address` of every `ethernet@<address>` node, and of every
//! radio on an SD host - a `wifi@` node in an `mmc@<address>` one, which
//! the Pi's firmware writes - by its host's address. Read once in
//! kmain, before exec's memory exists: the tree sits in RAM exec is
//! given, and is gone after.
//!
//! The flattened tree is big-endian: a header, then a structure block of
//! tokens - a node begins with its name, a property is its length, the
//! offset of its name in the strings block, and its value, each padded to
//! four bytes - and the strings block.

const std = @import("std");

const magic: u32 = 0xD00D_FEED;
const BEGIN_NODE = 1;
const END_NODE = 2;
const PROP = 3;
const NOP = 4;
const END = 9;

/// A range of memory, `start` up to `end`.
pub const Range = struct { start: usize, end: usize };

/// The most reserved ranges kept apart. One more is folded into the last,
/// which then reserves all between them: more is kept from exec, never
/// less.
pub const max_reserved = 8;

/// The most cores kept; more are left out.
pub const max_cores = 8;

/// The most ranges of RAM kept; more are left out.
pub const max_memory = 8;

/// The most network ports whose station address is kept.
pub const max_stations = 4;

/// A network port's station address, and where the port's registers
/// are: the address in its node's name - an SD host's, for a radio on
/// one.
pub const Station = struct { address: usize, bytes: [6]u8 };

/// How the PSCI firmware is reached, as `/psci` says.
pub const Conduit = enum { unknown, hvc, smc };

pub const Facts = struct {
    /// RAM's ranges, in the tree's order.
    memory: [max_memory]Range = undefined,
    memory_count: usize = 0,
    psci: Conduit = .unknown,
    initrd_start: ?usize = null,
    initrd_end: ?usize = null,
    reserved: [max_reserved]Range = undefined,
    reserved_count: usize = 0,
    /// The cores' MPIDR affinities, in the tree's order.
    cores: [max_cores]u64 = undefined,
    core_count: usize = 0,
    stations: [max_stations]Station = undefined,
    station_count: usize = 0,

    /// The station address the tree gives the port whose registers are at
    /// `address`, or null.
    pub fn stationAt(facts: *const Facts, address: usize) ?[6]u8 {
        for (facts.stations[0..facts.station_count]) |station| {
            if (station.address == address) return station.bytes;
        }
        return null;
    }

    /// The cores that can run the kernel.
    pub fn coreIds(facts: *const Facts) []const u64 {
        return facts.cores[0..facts.core_count];
    }

    /// RAM's ranges.
    pub fn memoryRanges(facts: *const Facts) []const Range {
        return facts.memory[0..facts.memory_count];
    }

    fn addMemory(facts: *Facts, start: usize, size: usize) void {
        if (size == 0 or facts.memory_count == max_memory) return;
        facts.memory[facts.memory_count] = .{ .start = start, .end = start +| size };
        facts.memory_count += 1;
    }

    /// The reserved ranges.
    pub fn reservedRanges(facts: *const Facts) []const Range {
        return facts.reserved[0..facts.reserved_count];
    }

    fn reserve(facts: *Facts, start: usize, size: usize) void {
        if (size == 0) return;
        const range: Range = .{ .start = start, .end = start +| size };
        if (facts.reserved_count < max_reserved) {
            facts.reserved[facts.reserved_count] = range;
            facts.reserved_count += 1;
        } else {
            const last = &facts.reserved[max_reserved - 1];
            last.* = .{ .start = @min(last.start, range.start), .end = @max(last.end, range.end) };
        }
    }
};

const Header = extern struct {
    magic: u32,
    totalsize: u32,
    off_dt_struct: u32,
    off_dt_strings: u32,
    off_mem_rsvmap: u32,
    version: u32,
    last_comp_version: u32,
    boot_cpuid_phys: u32,
    size_dt_strings: u32,
    size_dt_struct: u32,
};

fn be32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}

fn be64(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], .big);
}

/// A property's value as a number of `cells` 32-bit cells (1 or 2).
fn cellsAt(bytes: []const u8, cells: u32) usize {
    var value: u64 = 0;
    for (0..cells) |i| value = value << 32 | be32(bytes[i * 4 ..]);
    return @intCast(value);
}

/// Whether a string property - NUL-terminated - is `wanted`.
fn isString(value: []const u8, wanted: []const u8) bool {
    return std.mem.eql(u8, std.mem.sliceTo(value, 0), wanted);
}

/// A property that holds one number, of whichever width it was written.
fn number(bytes: []const u8) ?usize {
    return switch (bytes.len) {
        4 => cellsAt(bytes, 1),
        8 => cellsAt(bytes, 2),
        else => null,
    };
}

/// The facts the tree at `address` has; none if there is no tree there.
pub fn read(address: usize) Facts {
    var facts: Facts = .{};
    if (address == 0 or address % 4 != 0) return facts;
    const header: *const Header = @ptrFromInt(address);
    if (std.mem.bigToNative(u32, header.magic) != magic) return facts;
    const total = std.mem.bigToNative(u32, header.totalsize);
    const tree: []const u8 = @as([*]const u8, @ptrFromInt(address))[0..total];
    const strings = tree[std.mem.bigToNative(u32, header.off_dt_strings)..];

    // The reservation block: an address and a size, 64 bits each, until
    // both are 0.
    var entry: usize = std.mem.bigToNative(u32, header.off_mem_rsvmap);
    while (entry + 16 <= tree.len) : (entry += 16) {
        const start = be64(tree[entry..]);
        const size = be64(tree[entry + 8 ..]);
        if (start == 0 and size == 0) break;
        facts.reserve(@intCast(start), @intCast(size));
    }

    var at: usize = std.mem.bigToNative(u32, header.off_dt_struct);

    // The root's cell sizes, which /memory's reg is written in.
    var address_cells: u32 = 2;
    var size_cells: u32 = 1;
    // /reserved-memory's, which its nodes' reg is written in.
    var reserved_address_cells: u32 = 2;
    var reserved_size_cells: u32 = 1;
    var depth: u32 = 0;
    // What the root's child being read is.
    const Node = enum { other, memory, chosen, reserved_memory, cpus, psci };
    var node: Node = .other;
    // /cpus's cell size, which a cpu node's reg is written in; and the cpu
    // node being read, if one is: its id, and whether it can run us.
    var cpus_address_cells: u32 = 1;
    var in_cpu = false;
    var cpu_id: ?u64 = null;
    var cpu_okay = true;
    var cpu_kind = false;
    // The network port being read, by the address in its name - or its
    // SD host's, for a radio; and the SD host being read.
    var station: ?usize = null;
    var station_depth: u32 = 0;
    var sd_host: ?usize = null;
    var sd_host_depth: u32 = 0;
    while (at + 4 <= tree.len) {
        const token = be32(tree[at..]);
        at += 4;
        switch (token) {
            BEGIN_NODE => {
                const name = std.mem.sliceTo(tree[at..], 0);
                at = std.mem.alignForward(usize, at + name.len + 1, 4);
                depth += 1;
                if (depth == 2) {
                    node = if (std.mem.eql(u8, name, "chosen"))
                        .chosen
                    else if (std.mem.eql(u8, name, "reserved-memory")) reserved: {
                        reserved_address_cells = address_cells;
                        reserved_size_cells = size_cells;
                        break :reserved .reserved_memory;
                    } else if (std.mem.startsWith(u8, name, "memory"))
                        .memory
                    else if (std.mem.eql(u8, name, "cpus"))
                        .cpus
                    else if (std.mem.eql(u8, name, "psci"))
                        .psci
                    else
                        .other;
                }
                if (std.mem.startsWith(u8, name, "ethernet@")) {
                    station = std.fmt.parseInt(usize, name["ethernet@".len..], 16) catch null;
                    station_depth = depth;
                }
                if (std.mem.startsWith(u8, name, "mmc@")) {
                    sd_host = std.fmt.parseInt(usize, name["mmc@".len..], 16) catch null;
                    sd_host_depth = depth;
                }
                if (std.mem.startsWith(u8, name, "wifi@") and sd_host != null and depth == sd_host_depth + 1) {
                    station = sd_host;
                    station_depth = depth;
                }
                if (depth == 3 and node == .cpus and std.mem.startsWith(u8, name, "cpu@")) {
                    in_cpu = true;
                    cpu_id = null;
                    cpu_okay = true;
                    cpu_kind = false;
                }
            },
            END_NODE => {
                if (depth == 3 and in_cpu) {
                    in_cpu = false;
                    if (cpu_id != null and cpu_okay and cpu_kind and facts.core_count < max_cores) {
                        facts.cores[facts.core_count] = cpu_id.?;
                        facts.core_count += 1;
                    }
                }
                if (station != null and depth == station_depth) station = null;
                if (sd_host != null and depth == sd_host_depth) sd_host = null;
                depth -|= 1;
                if (depth < 2) node = .other;
            },
            PROP => {
                const len = be32(tree[at..]);
                const name = std.mem.sliceTo(strings[be32(tree[at + 4 ..])..], 0);
                const value = tree[at + 8 ..][0..len];
                at = std.mem.alignForward(usize, at + 8 + len, 4);
                if (station != null and depth == station_depth and len == 6 and
                    std.mem.eql(u8, name, "local-mac-address") and facts.station_count < max_stations)
                {
                    facts.stations[facts.station_count] = .{ .address = station.?, .bytes = value[0..6].* };
                    facts.station_count += 1;
                }
                if (depth == 1) {
                    if (std.mem.eql(u8, name, "#address-cells")) address_cells = be32(value);
                    if (std.mem.eql(u8, name, "#size-cells")) size_cells = be32(value);
                } else if (depth == 2 and node == .memory and std.mem.eql(u8, name, "reg")) {
                    // Every range of it.
                    const ac = address_cells;
                    const sc = size_cells;
                    if (ac >= 1 and ac <= 2 and sc >= 1 and sc <= 2) {
                        var range: usize = 0;
                        while (range + (ac + sc) * 4 <= len) : (range += (ac + sc) * 4) {
                            facts.addMemory(cellsAt(value[range..], ac), cellsAt(value[range + ac * 4 ..], sc));
                        }
                    }
                } else if (depth == 2 and node == .psci and std.mem.eql(u8, name, "method")) {
                    if (isString(value, "smc")) facts.psci = .smc;
                    if (isString(value, "hvc")) facts.psci = .hvc;
                } else if (depth == 2 and node == .chosen) {
                    if (std.mem.eql(u8, name, "linux,initrd-start")) facts.initrd_start = number(value);
                    if (std.mem.eql(u8, name, "linux,initrd-end")) facts.initrd_end = number(value);
                } else if (depth == 2 and node == .cpus) {
                    if (std.mem.eql(u8, name, "#address-cells")) cpus_address_cells = be32(value);
                } else if (depth == 3 and in_cpu) {
                    if (std.mem.eql(u8, name, "reg") and cpus_address_cells >= 1 and cpus_address_cells <= 2 and len >= cpus_address_cells * 4) {
                        cpu_id = cellsAt(value, cpus_address_cells);
                    }
                    if (std.mem.eql(u8, name, "status")) cpu_okay = std.mem.startsWith(u8, value, "okay") or std.mem.startsWith(u8, value, "ok");
                    if (std.mem.eql(u8, name, "device_type")) cpu_kind = isString(value, "cpu");
                } else if (depth == 2 and node == .reserved_memory) {
                    if (std.mem.eql(u8, name, "#address-cells")) reserved_address_cells = be32(value);
                    if (std.mem.eql(u8, name, "#size-cells")) reserved_size_cells = be32(value);
                } else if (depth == 3 and node == .reserved_memory and std.mem.eql(u8, name, "reg")) {
                    // Every range of it: a node without reg is memory a
                    // system allocates for itself, which is not this one.
                    const ac = reserved_address_cells;
                    const sc = reserved_size_cells;
                    if (ac >= 1 and ac <= 2 and sc >= 1 and sc <= 2) {
                        var range: usize = 0;
                        while (range + (ac + sc) * 4 <= len) : (range += (ac + sc) * 4) {
                            facts.reserve(cellsAt(value[range..], ac), cellsAt(value[range + ac * 4 ..], sc));
                        }
                    }
                }
            },
            NOP => {},
            else => break, // END, or a tree this does not understand
        }
    }
    return facts;
}
