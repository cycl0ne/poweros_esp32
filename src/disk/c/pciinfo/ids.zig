// SPDX-License-Identifier: MIT
//! The PCI ID Repository's list (pci.ids): the names of vendors, their
//! devices, and the subsystems built with them, looked up in the file's
//! text as it is.
//!
//! A vendor is a line of its own - its ID in four hex digits, two spaces,
//! its name - and its devices follow it, a tab before each; a device's
//! subsystems follow it, two tabs before each, the subsystem's vendor
//! and device apart by a space. The classes come last, from a line that
//! starts with "C ": no vendor is looked for past it. Comments start
//! with '#'.

const std = @import("std");

pub const Ids = struct {
    text: []const u8,

    /// Vendor `vendor`'s name.
    pub fn vendor(ids: Ids, id: u16) ?[]const u8 {
        const block = ids.vendorBlock(id) orelse return null;
        return block.name;
    }

    /// Device `device` of vendor `vendor`'s name.
    pub fn device(ids: Ids, vendor_id: u16, device_id: u16) ?[]const u8 {
        const found = ids.deviceBlock(vendor_id, device_id) orelse return null;
        return found.name;
    }

    /// The name of subsystem `sub_vendor`:`sub_device` built with device
    /// `device` of vendor `vendor`.
    pub fn subsystem(ids: Ids, vendor_id: u16, device_id: u16, sub_vendor: u16, sub_device: u16) ?[]const u8 {
        const found = ids.deviceBlock(vendor_id, device_id) orelse return null;
        var lines = std.mem.splitScalar(u8, found.rest, '\n');
        while (lines.next()) |line| {
            if (comment(line)) continue;
            if (!std.mem.startsWith(u8, line, "\t\t")) return null;
            if (line.len < 13 or line[6] != ' ') continue;
            if (hex4(line[2..6]) == sub_vendor and hex4(line[7..11]) == sub_device) return name(line[11..]);
        }
        return null;
    }

    /// A vendor's or a device's line: its name, and the text after the
    /// line.
    const Block = struct {
        name: []const u8,
        rest: []const u8,
    };

    fn vendorBlock(ids: Ids, id: u16) ?Block {
        var at: usize = 0;
        while (at < ids.text.len) {
            const end = std.mem.indexOfScalarPos(u8, ids.text, at, '\n') orelse ids.text.len;
            const line = ids.text[at..end];
            at = end + 1;
            if (std.mem.startsWith(u8, line, "C ")) return null;
            if (line.len < 7 or comment(line) or line[0] == '\t') continue;
            if (hex4(line[0..4]) == id and line[4] == ' ') return .{ .name = name(line[4..]), .rest = ids.text[@min(at, ids.text.len)..] };
        }
        return null;
    }

    fn deviceBlock(ids: Ids, vendor_id: u16, device_id: u16) ?Block {
        const block = ids.vendorBlock(vendor_id) orelse return null;
        var at: usize = 0;
        const text = block.rest;
        while (at < text.len) {
            const end = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
            const line = text[at..end];
            at = end + 1;
            if (comment(line) or line.len == 0) continue;
            if (line[0] != '\t') return null;
            if (line.len < 8 or line[1] == '\t') continue;
            if (hex4(line[1..5]) == device_id and line[5] == ' ') return .{ .name = name(line[5..]), .rest = text[@min(at, text.len)..] };
        }
        return null;
    }
};

fn comment(line: []const u8) bool {
    return line.len > 0 and line[0] == '#';
}

/// The name after an ID: past the spaces, without a carriage return.
fn name(after: []const u8) []const u8 {
    return std.mem.trim(u8, after, " \t\r");
}

fn hex4(digits: []const u8) ?u16 {
    return std.fmt.parseInt(u16, digits, 16) catch null;
}
