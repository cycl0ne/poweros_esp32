// SPDX-License-Identifier: MPL-2.0
//! The device's video BIOS image, found in the firmware's table of them.
//!
//! A machine started by UEFI firmware keeps a copy of each display
//! device's own BIOS in one of its tables (VFCT), and the kernel names
//! that table as a board part (PARTKIND_VIDEO_BIOS). The table is its
//! header, a header of its own that says where the first image is, and
//! then the images, each behind a header that says which PCI function it
//! is for and how many bytes follow. The device's is the one whose vendor
//! and device ids, slot and function are its own - and its bus where the
//! numbering agrees, though a bus numbered differently from the
//! firmware's does not keep an image from being the device's, since its
//! ids and slot already say it is.
//!
//! An image is kept where it lies - the firmware's memory, which the
//! kernel keeps for as long as the machine runs - once its first bytes
//! say it is an image of the kind the device's controllers run: the two
//! marks every PCI ROM image starts with, and the ATOM tables' header
//! where the image says it is. That header is what a driver reads the
//! image's tables out of; one that is not there means an image of some
//! other kind, which nothing here would read correctly.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const st = sdk.expansion.systemtags;
const PCIDevice = sdk.pci.PCIDevice;
const AMDGPUBase = @import("../amdgpu_base.zig").AMDGPUBase;

const owner = amdgpu.AMDGPUNAME;

/// The table's own header, after the 36 bytes every firmware table starts
/// with: where the first image is, counted from the table's start.
const table_length_at = 4;
const table_first_image_at = 0x34;
const table_header_bytes = 0x4C;

/// An image's header: the function it is for, its ids, and how many bytes
/// of image follow the header.
const image_bus_at = 0;
const image_device_at = 4;
const image_function_at = 8;
const image_vendor_at = 12;
const image_device_id_at = 14;
const image_length_at = 24;
const image_header_bytes = 28;

/// The marks a PCI ROM image starts with, where the ATOM tables' header's
/// offset is, and that header's mark, four bytes into it.
const rom_mark_0 = 0x55;
const rom_mark_1 = 0xAA;
const atom_header_offset_at = 0x48;
const atom_mark = "ATOM";
const atom_mark_at = 4;

/// The device's image into the base, where the board has a table of them
/// and one in it is the device's; said on the boot's lines either way.
pub fn take(ab: *AMDGPUBase) void {
    const sys = ab.sys_base;
    const device = ab.device orelse return;
    const table = tableAddress(sys) orelse {
        exec.kprintf(sys, "%s: the firmware keeps no video BIOS images\n", .{owner});
        return;
    };
    const found = imageIn(table, device) orelse {
        exec.kprintf(sys, "%s: none of the firmware's video BIOS images is this device's\n", .{owner});
        return;
    };
    ab.bios = found;
    exec.kprintf(sys, "%s: the video BIOS image is %d bytes at 0x%lx\n", .{
        owner, found.bytes, @as(u64, @intFromPtr(found.image.?)),
    });
}

/// Where the board says the table of images is, or null.
fn tableAddress(sys: *sdk.interface.exec.ExecBase) ?usize {
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return null;
    defer sys.CloseLibrary(expansion_lib);
    const utility_lib = sys.OpenLibrary(sdk.utility.UTILITYNAME, 1) orelse return null;
    defer sys.CloseLibrary(utility_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    const ub: *sdk.interface.utility.UtilityBase = @ptrCast(utility_lib);
    const part = eb.FindBoardPart(null, st.PARTKIND_VIDEO_BIOS, st.CHIP_ACPI_VFCT) orelse return null;
    const at: usize = @intCast(ub.GetTagData(st.PART_Address, 0, part.tags));
    return if (at == 0) null else at;
}

/// The image in the table at `table` that is `device`'s and is one the
/// device's controllers run, or null. Every header is checked to lie
/// wholly inside the table before it is read, and every image before it
/// is taken.
pub fn imageIn(table: usize, device: *const PCIDevice) ?amdgpu.GPUBios {
    const length = long(table + table_length_at);
    if (length < table_header_bytes) return null;
    var offset: u64 = long(table + table_first_image_at);
    var by_ids: ?amdgpu.GPUBios = null;
    while (offset + image_header_bytes <= length) {
        const header = table + @as(usize, @intCast(offset));
        const bytes = long(header + image_length_at);
        const end = offset + image_header_bytes + bytes;
        if (end > length) return by_ids;
        offset = end;
        if (bytes == 0) continue;
        if (half(header + image_vendor_at) != device.vendor_id) continue;
        if (half(header + image_device_id_at) != device.device_id) continue;
        if (long(header + image_device_at) != device.device) continue;
        if (long(header + image_function_at) != device.function) continue;
        const image: [*]const u8 = @ptrFromInt(header + image_header_bytes);
        if (!isAtom(image, bytes)) continue;
        const found: amdgpu.GPUBios = .{ .image = image, .bytes = bytes };
        if (long(header + image_bus_at) == device.bus) return found;
        if (by_ids == null) by_ids = found;
    }
    return by_ids;
}

/// Whether `bytes` at `image` are an image whose tables a driver can
/// read: a PCI ROM's marks, and the ATOM tables' header inside it.
pub fn isAtom(image: [*]const u8, bytes: u32) bool {
    if (bytes < atom_header_offset_at + 2) return false;
    if (image[0] != rom_mark_0 or image[1] != rom_mark_1) return false;
    const header: u32 = @as(u32, image[atom_header_offset_at]) | @as(u32, image[atom_header_offset_at + 1]) << 8;
    if (header == 0 or header + atom_mark_at + atom_mark.len > bytes) return false;
    for (atom_mark, 0..) |char, index| {
        if (image[header + atom_mark_at + index] != char) return false;
    }
    return true;
}

fn byteAt(at: usize) u8 {
    return @as(*const u8, @ptrFromInt(at)).*;
}

fn half(at: usize) u16 {
    return @as(u16, byteAt(at)) | @as(u16, byteAt(at + 1)) << 8;
}

fn long(at: usize) u32 {
    return @as(u32, half(at)) | @as(u32, half(at + 2)) << 16;
}

// --- tests ------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

/// An image of `bytes` bytes whose marks say it is one a driver reads.
fn makeImage(room: []u8) void {
    @memset(room, 0);
    room[0] = rom_mark_0;
    room[1] = rom_mark_1;
    room[atom_header_offset_at] = 0x80;
    @memcpy(room[0x80 + atom_mark_at ..][0..4], atom_mark);
}

/// A table holding `images`, each for the function and ids given.
const Entry = struct { bus: u32, device: u32, function: u32, vendor: u16, id: u16, bytes: u32, atom: bool = true };

fn makeTable(room: []align(4) u8, entries: []const Entry) usize {
    @memset(room, 0);
    @memcpy(room[0..4], "VFCT");
    std.mem.writeInt(u32, room[table_first_image_at..][0..4], table_header_bytes, .little);
    var at: usize = table_header_bytes;
    for (entries) |entry| {
        std.mem.writeInt(u32, room[at + image_bus_at ..][0..4], entry.bus, .little);
        std.mem.writeInt(u32, room[at + image_device_at ..][0..4], entry.device, .little);
        std.mem.writeInt(u32, room[at + image_function_at ..][0..4], entry.function, .little);
        std.mem.writeInt(u16, room[at + image_vendor_at ..][0..2], entry.vendor, .little);
        std.mem.writeInt(u16, room[at + image_device_id_at ..][0..2], entry.id, .little);
        std.mem.writeInt(u32, room[at + image_length_at ..][0..4], entry.bytes, .little);
        if (entry.atom) makeImage(room[at + image_header_bytes ..][0..entry.bytes]);
        at += image_header_bytes + entry.bytes;
    }
    std.mem.writeInt(u32, room[table_length_at..][0..4], @intCast(at), .little);
    return at;
}

test "the device's image is the one with its ids, slot, function and bus" {
    var room: [4096]u8 align(4) = undefined;
    _ = makeTable(&room, &.{
        .{ .bus = 3, .device = 0, .function = 0, .vendor = 0x1002, .id = 0x7480, .bytes = 512 },
        .{ .bus = 0x65, .device = 0, .function = 0, .vendor = 0x1002, .id = 0x15bf, .bytes = 1024 },
    });
    const device: PCIDevice = .{ .bus = 0x65, .vendor_id = 0x1002, .device_id = 0x15bf };
    const found = imageIn(@intFromPtr(&room), &device) orelse return error.NotFound;
    try testing.expectEqual(@as(u32, 1024), found.bytes);
    try testing.expectEqual(@intFromPtr(&room) + table_header_bytes + 2 * image_header_bytes + 512, @intFromPtr(found.image.?));
}

test "an image for the same ids on another bus is taken where none is on its own" {
    var room: [4096]u8 align(4) = undefined;
    _ = makeTable(&room, &.{
        .{ .bus = 1, .device = 0, .function = 0, .vendor = 0x1002, .id = 0x15bf, .bytes = 256 },
    });
    const device: PCIDevice = .{ .bus = 0x65, .vendor_id = 0x1002, .device_id = 0x15bf };
    const found = imageIn(@intFromPtr(&room), &device) orelse return error.NotFound;
    try testing.expectEqual(@as(u32, 256), found.bytes);
}

test "no image is taken for another function, without its marks, or past the table's end" {
    var room: [4096]u8 align(4) = undefined;
    const device: PCIDevice = .{ .bus = 0x65, .vendor_id = 0x1002, .device_id = 0x15bf };
    _ = makeTable(&room, &.{
        .{ .bus = 0x65, .device = 0, .function = 1, .vendor = 0x1002, .id = 0x15bf, .bytes = 256 },
        .{ .bus = 0x65, .device = 0, .function = 0, .vendor = 0x1002, .id = 0x15bf, .bytes = 256, .atom = false },
    });
    try testing.expect(imageIn(@intFromPtr(&room), &device) == null);

    const length = makeTable(&room, &.{
        .{ .bus = 0x65, .device = 0, .function = 0, .vendor = 0x1002, .id = 0x15bf, .bytes = 256 },
    });
    // The table says it ends before the image does.
    std.mem.writeInt(u32, room[table_length_at..][0..4], @intCast(length - 1), .little);
    try testing.expect(imageIn(@intFromPtr(&room), &device) == null);
    // And a table too short for its own header holds nothing.
    std.mem.writeInt(u32, room[table_length_at..][0..4], 40, .little);
    try testing.expect(imageIn(@intFromPtr(&room), &device) == null);
}
