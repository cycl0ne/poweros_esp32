// SPDX-License-Identifier: MPL-2.0
//! The display's connectors, as the device's video BIOS lists them.
//!
//! The image (`_bios.zig`) starts with the ATOM tables' header, whose
//! place the image holds at 0x48; that header names the list of data
//! tables, and one of those is the display object table: a path per
//! connector the board has, each naming the connector's kind and number,
//! the encoder that drives it - which of the engine's PHYs - and a list
//! of records about it, among them the I2C line its monitor's DDC is on
//! and the pin its hot-plug line comes in on. Those two are ids, which
//! the table of GPIO pins - another data table - turns into where the
//! pins are: the register of the DDC's pin pair, and the hot-plug pin's
//! register and bit. Read once, as the resource starts, into the base;
//! GetGPUConnector answers from there. Nothing is written to the device.
//!
//! Every offset is checked against the image's length before it is read,
//! and a table of a version this does not know is passed over: the
//! connectors are then unknown, which a driver can live with, where a
//! table read at the wrong places would name connectors that are not
//! there.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu_base.zig").AMDGPUBase;

const owner = amdgpu.AMDGPUNAME;

/// What a table holds: its connectors, how many, and the display object
/// table's version - 0.0 where none was read.
pub const Read = struct {
    list: [amdgpu.GPUCONNECTORS_MAX]amdgpu.GPUConnector = @splat(.{}),
    count: u32 = 0,
    major: u8 = 0,
    minor: u8 = 0,
};

/// Where the ATOM tables' header's offset is, its mark, and where in it
/// the list of data tables is named.
const atom_header_offset_at = 0x48;
const atom_mark_at = 4;
const atom_data_tables_at = 0x20;

/// In the list of data tables, after its own four bytes: which of its
/// 16-bit offsets is the display object table.
const data_tables_first = 4;
const gpio_pins_index = 12;
const display_objects_index = 22;

/// The table of GPIO pins: its size and version, then a pin per 8 bytes -
/// its register (of which the low 16 bits are taken), its bit, and its
/// id, which the records name.
const pins_size_at = 0;
const pins_content_at = 3;
const pins_first = 4;
const pin_bytes = 8;
const pin_register_at = 0;
const pin_bit_at = 4;
const pin_id_at = 6;

/// The display object table: its version, how many paths, the paths, and
/// each path's size in either version this reads (1.4 and 1.5), which
/// lay the parts read here at the same places.
const objects_format_at = 2;
const objects_content_at = 3;
const objects_paths_at = 6;
const objects_first_path = 8;
const path_bytes = 16;
const path_object_at = 0;
const path_records_at = 2;
const path_encoder_at = 4;

/// An object id: its number, its enumeration (which of several alike),
/// and its type.
const object_number_mask = 0x00FF;
const object_enum_shift = 8;
const object_enum_mask = 0x7;
const object_type_shift = 12;
const object_type_mask = 0x7;
const object_type_encoder = 2;
const object_type_connector = 3;

/// The connectors' and encoders' numbers this names.
const connector_dvi_single = 0x03;
const connector_dvi_dual = 0x04;
const connector_hdmi = 0x0C;
const connector_displayport = 0x13;
const connector_edp = 0x14;
const connector_usbc = 0x18;
const encoder_uniphy = 0x1E;
const encoder_uniphy1 = 0x20;
const encoder_uniphy2 = 0x21;
const encoder_uniphy3 = 0x25;

/// A record's kind, the two kinds read, and the end of a list.
const record_i2c = 1;
const record_hpd = 2;
const record_end = 0xFF;

/// The connectors of the device's image into the base, and on the boot's
/// lines; nothing where there is no image.
pub fn take(ab: *AMDGPUBase) void {
    const image = ab.bios.image orelse return;
    const found = read(image[0..ab.bios.bytes]);
    ab.connectors = found.list;
    ab.connector_count = found.count;
    tell(ab.sys_base, &found);
}

/// The connectors the image `image` lists.
pub fn read(image: []const u8) Read {
    var found: Read = .{};
    const header = half(image, atom_header_offset_at) orelse return found;
    if (image.len < @as(usize, header) + atom_mark_at + 4) return found;
    for ("ATOM", 0..) |char, index| {
        if (image[header + atom_mark_at + index] != char) return found;
    }
    const data_tables = half(image, @as(usize, header) + atom_data_tables_at) orelse return found;
    const table: usize = half(image, @as(usize, data_tables) + data_tables_first + display_objects_index * 2) orelse return found;
    if (table == 0) return found;
    const format = byte(image, table + objects_format_at) orelse return found;
    const content = byte(image, table + objects_content_at) orelse return found;
    found.major = format;
    found.minor = content;
    if (format != 1 or (content != 4 and content != 5)) return found;
    const paths = byte(image, table + objects_paths_at) orelse return found;
    var index: usize = 0;
    while (index < paths and found.count < amdgpu.GPUCONNECTORS_MAX) : (index += 1) {
        const path = table + objects_first_path + index * path_bytes;
        const object = half(image, path + path_object_at) orelse break;
        const records = half(image, path + path_records_at) orelse break;
        const encoder = half(image, path + path_encoder_at) orelse break;
        if (object >> object_type_shift & object_type_mask != object_type_connector) continue;
        if (encoder == 0) continue;
        var connector: amdgpu.GPUConnector = .{
            .kind = kindOf(object & object_number_mask),
            .number = object >> object_enum_shift & object_enum_mask,
            .phy = phyOf(encoder),
            .object = object,
            .encoder = encoder,
        };
        if (records != 0) readRecords(image, table + records, &connector);
        found.list[found.count] = connector;
        found.count += 1;
    }
    const pins: usize = half(image, @as(usize, data_tables) + data_tables_first + gpio_pins_index * 2) orelse return found;
    if (pins != 0) {
        for (found.list[0..found.count]) |*connector| findPins(image, pins, connector);
    }
    return found;
}

/// The pins of a connector's DDC and hot-plug ids, from the table of
/// GPIO pins at `table`: the pin whose id is the record's. A table of
/// another version, or one too short for a single pin, names none.
fn findPins(image: []const u8, table: usize, connector: *amdgpu.GPUConnector) void {
    const size = half(image, table + pins_size_at) orelse return;
    const content = byte(image, table + pins_content_at) orelse return;
    if (content != 1 or size < pins_first + pin_bytes) return;
    if (table + size > image.len) return;
    const count = (size - pins_first) / pin_bytes;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const pin = table + pins_first + index * pin_bytes;
        const id = image[pin + pin_id_at];
        const register: u32 = half(image, pin + pin_register_at).?;
        if (id == connector.ddc) connector.ddc_pin = register;
        if (id == connector.hpd) {
            connector.hpd_pin = register;
            connector.hpd_pin_bit = image[pin + pin_bit_at];
        }
    }
}

/// What the records from `at` name: the DDC's I2C line and the hot-plug
/// pin. A record that claims less than its own header, or runs past the
/// image, ends the list, and so does a list that never ends.
fn readRecords(image: []const u8, at: usize, connector: *amdgpu.GPUConnector) void {
    var place = at;
    var guard: u32 = 0;
    while (guard < 64) : (guard += 1) {
        const kind = byte(image, place) orelse return;
        if (kind == record_end) return;
        const size = byte(image, place + 1) orelse return;
        if (size < 2 or place + size > image.len) return;
        switch (kind) {
            record_i2c => if (size >= 4) {
                connector.ddc = image[place + 2];
            },
            record_hpd => if (size >= 4) {
                connector.hpd = image[place + 2];
            },
            else => {},
        }
        place += size;
    }
}

fn kindOf(number: u16) u32 {
    return switch (number) {
        connector_dvi_single, connector_dvi_dual => amdgpu.GPUCONNECTOR_DVI,
        connector_hdmi => amdgpu.GPUCONNECTOR_HDMI,
        connector_displayport => amdgpu.GPUCONNECTOR_DISPLAYPORT,
        connector_edp => amdgpu.GPUCONNECTOR_EDP,
        connector_usbc => amdgpu.GPUCONNECTOR_USBC,
        else => amdgpu.GPUCONNECTOR_OTHER,
    };
}

/// The PHY an encoder id names: each of the engine's own encoders drives
/// two PHYs, told apart by the id's enumeration - the last one only one.
fn phyOf(encoder: u16) u32 {
    if (encoder >> object_type_shift & object_type_mask != object_type_encoder) return amdgpu.GPULINE_NONE;
    const which: u32 = encoder >> object_enum_shift & object_enum_mask;
    if (which == 0 or which > 2) return amdgpu.GPULINE_NONE;
    const first: u32 = switch (encoder & object_number_mask) {
        encoder_uniphy => 0,
        encoder_uniphy1 => 2,
        encoder_uniphy2 => 4,
        encoder_uniphy3 => 6,
        else => return amdgpu.GPULINE_NONE,
    };
    if (first == 6 and which == 2) return amdgpu.GPULINE_NONE;
    return first + which - 1;
}

/// What a connector's kind is called on the boot's lines.
pub fn kindName(kind: u32) [*:0]const u8 {
    return switch (kind) {
        amdgpu.GPUCONNECTOR_DVI => "DVI",
        amdgpu.GPUCONNECTOR_HDMI => "HDMI",
        amdgpu.GPUCONNECTOR_DISPLAYPORT => "DP",
        amdgpu.GPUCONNECTOR_EDP => "eDP",
        amdgpu.GPUCONNECTOR_USBC => "USB-C",
        else => "other",
    };
}

/// The connectors on the boot's lines.
fn tell(sys: *sdk.interface.exec.ExecBase, found: *const Read) void {
    if (found.major == 0) {
        exec.kprintf(sys, "%s: the video BIOS has no display object table\n", .{owner});
        return;
    }
    exec.kprintf(sys, "%s: the video BIOS's display objects %d.%d name %d connector(s)\n", .{
        owner, @as(u32, found.major), @as(u32, found.minor), found.count,
    });
    for (found.list[0..found.count]) |connector| {
        exec.kprintf(sys, "%s:   %s %d on PHY %c, DDC line %x (pins at %x), hot plug %x (pin %x bit %d) (object %x, encoder %x)\n", .{
            owner,
            kindName(connector.kind),
            connector.number,
            if (connector.phy == amdgpu.GPULINE_NONE) @as(u32, '?') else 'A' + connector.phy,
            connector.ddc,
            connector.ddc_pin,
            connector.hpd,
            connector.hpd_pin,
            connector.hpd_pin_bit,
            connector.object,
            connector.encoder,
        });
    }
}

fn byte(image: []const u8, at: usize) ?u8 {
    if (at >= image.len) return null;
    return image[at];
}

fn half(image: []const u8, at: usize) ?u16 {
    if (at + 2 > image.len) return null;
    return @as(u16, image[at]) | @as(u16, image[at + 1]) << 8;
}

// --- tests ------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

fn put16(room: []u8, at: usize, value: u16) void {
    room[at] = @truncate(value);
    room[at + 1] = @truncate(value >> 8);
}

/// An image with a display object table of two paths, an HDMI connector
/// on PHY B with its DDC and hot-plug records, and a DP connector on PHY C.
fn makeImage(room: []u8) void {
    @memset(room, 0);
    room[0] = 0x55;
    room[1] = 0xAA;
    const header = 0x100;
    put16(room, atom_header_offset_at, header);
    @memcpy(room[header + atom_mark_at ..][0..4], "ATOM");
    const data_tables = 0x200;
    put16(room, header + atom_data_tables_at, data_tables);
    const table = 0x300;
    put16(room, data_tables + data_tables_first + display_objects_index * 2, table);
    room[table + objects_format_at] = 1;
    room[table + objects_content_at] = 5;
    room[table + objects_paths_at] = 2;
    const first = table + objects_first_path;
    put16(room, first + path_object_at, 0x3000 | 0x100 | connector_hdmi);
    put16(room, first + path_records_at, 0x40);
    put16(room, first + path_encoder_at, 0x2000 | 0x200 | encoder_uniphy);
    const second = first + path_bytes;
    put16(room, second + path_object_at, 0x3000 | 0x100 | connector_displayport);
    put16(room, second + path_encoder_at, 0x2000 | 0x100 | encoder_uniphy1);
    const records = table + 0x40;
    room[records] = record_i2c;
    room[records + 1] = 4;
    room[records + 2] = 0x92;
    room[records + 4] = record_hpd;
    room[records + 5] = 4;
    room[records + 6] = 3;
    room[records + 8] = record_end;
    // The pins: a generic one, the hot-plug pin 3, the DDC pair 0x92.
    const pins = 0x380;
    put16(room, data_tables + data_tables_first + gpio_pins_index * 2, pins);
    put16(room, pins + pins_size_at, pins_first + 3 * pin_bytes);
    room[pins + pins_content_at] = 1;
    const pin = pins + pins_first;
    put16(room, pin + pin_register_at, 0x5DB0);
    room[pin + pin_id_at] = 7;
    put16(room, pin + pin_bytes + pin_register_at, 0x5DB5);
    room[pin + pin_bytes + pin_bit_at] = 16;
    room[pin + pin_bytes + pin_id_at] = 3;
    put16(room, pin + 2 * pin_bytes + pin_register_at, 0x5D99);
    room[pin + 2 * pin_bytes + pin_id_at] = 0x92;
}

test "the connectors are read with their PHYs, DDC lines and hot-plug pins" {
    var room: [1024]u8 = undefined;
    makeImage(&room);
    const found = read(&room);
    try testing.expectEqual(@as(u32, 2), found.count);
    try testing.expectEqual(@as(u8, 5), found.minor);
    try testing.expectEqual(amdgpu.GPUCONNECTOR_HDMI, found.list[0].kind);
    try testing.expectEqual(@as(u32, 1), found.list[0].number);
    try testing.expectEqual(@as(u32, 1), found.list[0].phy);
    try testing.expectEqual(@as(u32, 0x92), found.list[0].ddc);
    try testing.expectEqual(@as(u32, 3), found.list[0].hpd);
    try testing.expectEqual(amdgpu.GPUCONNECTOR_DISPLAYPORT, found.list[1].kind);
    try testing.expectEqual(@as(u32, 2), found.list[1].phy);
    try testing.expectEqual(amdgpu.GPULINE_NONE, found.list[1].ddc);
}

test "a connector's lines are found in the table of GPIO pins" {
    var room: [1024]u8 = undefined;
    makeImage(&room);
    const found = read(&room);
    try testing.expectEqual(@as(u32, 0x5D99), found.list[0].ddc_pin);
    try testing.expectEqual(@as(u32, 0x5DB5), found.list[0].hpd_pin);
    try testing.expectEqual(@as(u32, 16), found.list[0].hpd_pin_bit);
    // No lines, no pins.
    try testing.expectEqual(@as(u32, 0), found.list[1].ddc_pin);
    try testing.expectEqual(@as(u32, 0), found.list[1].hpd_pin);
    // A table of another version names none.
    room[0x380 + pins_content_at] = 2;
    try testing.expectEqual(@as(u32, 0), read(&room).list[0].ddc_pin);
}

test "an image without the tables' mark, or a table of another version, names no connectors" {
    var room: [1024]u8 = undefined;
    makeImage(&room);
    room[0x100 + atom_mark_at] = 'X';
    try testing.expectEqual(@as(u32, 0), read(&room).count);
    makeImage(&room);
    room[0x300 + objects_content_at] = 3;
    const other = read(&room);
    try testing.expectEqual(@as(u32, 0), other.count);
    try testing.expectEqual(@as(u8, 3), other.minor);
    // An image cut short in the middle of its paths names what it holds.
    makeImage(&room);
    try testing.expectEqual(@as(u32, 1), read(room[0 .. 0x300 + objects_first_path + path_bytes]).count);
}
