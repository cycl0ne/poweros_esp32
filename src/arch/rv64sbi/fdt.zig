// SPDX-License-Identifier: MPL-2.0
//! What the kernel reads from the device tree the firmware passes in a1:
//! RAM (the first `/memory` node's first range) and the disk image the
//! loader put in RAM beside the kernel (`/chosen`'s `linux,initrd-start`
//! and `linux,initrd-end`, which QEMU's -initrd and U-Boot's booti write).
//! Read once in kmain, before exec's memory exists: the tree sits in RAM
//! exec is given, and is gone after.
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

pub const Facts = struct {
    ram_base: ?usize = null,
    ram_size: ?usize = null,
    initrd_start: ?usize = null,
    initrd_end: ?usize = null,
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

/// A property's value as a number of `cells` 32-bit cells (1 or 2).
fn cellsAt(bytes: []const u8, cells: u32) usize {
    var value: u64 = 0;
    for (0..cells) |i| value = value << 32 | be32(bytes[i * 4 ..]);
    return @intCast(value);
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
    var at: usize = std.mem.bigToNative(u32, header.off_dt_struct);

    // The root's cell sizes, which /memory's reg is written in.
    var address_cells: u32 = 2;
    var size_cells: u32 = 1;
    var depth: u32 = 0;
    // What the node at depth 1 is.
    const Node = enum { other, memory, chosen };
    var node: Node = .other;
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
                    else if (std.mem.startsWith(u8, name, "memory") and facts.ram_size == null)
                        .memory
                    else
                        .other;
                }
            },
            END_NODE => {
                depth -|= 1;
                if (depth < 2) node = .other;
            },
            PROP => {
                const len = be32(tree[at..]);
                const name = std.mem.sliceTo(strings[be32(tree[at + 4 ..])..], 0);
                const value = tree[at + 8 ..][0..len];
                at = std.mem.alignForward(usize, at + 8 + len, 4);
                if (depth == 1) {
                    if (std.mem.eql(u8, name, "#address-cells")) address_cells = be32(value);
                    if (std.mem.eql(u8, name, "#size-cells")) size_cells = be32(value);
                } else if (depth == 2 and node == .memory and std.mem.eql(u8, name, "reg")) {
                    if (len >= (address_cells + size_cells) * 4 and address_cells <= 2 and size_cells <= 2) {
                        facts.ram_base = cellsAt(value, address_cells);
                        facts.ram_size = cellsAt(value[address_cells * 4 ..], size_cells);
                    }
                } else if (depth == 2 and node == .chosen) {
                    if (std.mem.eql(u8, name, "linux,initrd-start")) facts.initrd_start = number(value);
                    if (std.mem.eql(u8, name, "linux,initrd-end")) facts.initrd_end = number(value);
                }
            },
            NOP => {},
            else => break, // END, or a tree this does not understand
        }
    }
    return facts;
}
