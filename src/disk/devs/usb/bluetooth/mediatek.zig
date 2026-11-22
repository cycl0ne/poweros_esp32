// SPDX-License-Identifier: MIT
//! The setup a MediaTek MT79xx controller needs before it is one: which
//! chip it is, its RAM code given it section by section, and its
//! Bluetooth function switched on.
//!
//! **The chip** answers vendor control requests: its registers read with
//! request 0x63, its chip id at 0x70010200, the firmware version it wants
//! at 0x80021004 (whose low byte names the file) and its flavour at
//! 0x70010020, and the endpoint reset option written with request 0x02.
//!
//! **WMT** is the chip's own command set, carried in HCI vendor command
//! 0xFC6F: a header - direction, operation, the length of what follows
//! and a flag - then the operation's data. Its answer is not an event on
//! the interrupt endpoint but one read with a vendor control request
//! (0xC0, 1, 48), which comes back empty until the answer is there: it is
//! asked again every half millisecond, for up to ten seconds.
//!
//! **The firmware file** (`BT_RAM_CODE_MT7922_1_1_hdr.bin`) is a header
//! of 32 bytes - its build time first, as text - a global descriptor of
//! 64 whose fourth word is the number of sections, and a 64-byte map per
//! section: where its bytes are in the file, and the 52 bytes of its
//! download spec, whose second word is how many bytes go to the chip.
//! Each section is first offered with its spec: the chip answers that it
//! has it already (a warm restart: nothing is sent), that it is busy (100
//! ms, and asked again), or that it wants it - and then it gets the bytes
//! in WMT packets of 250, flagged first, middle and last.
//!
//! The sequence runs over a `Port`: the device's control transfers and
//! pauses on the worker, or a script in the host tests.

const sdk = @import("sdk");
const d = sdk.usb.descriptors;
const hcidev = sdk.devices.hci;

/// USB's vendor id for MediaTek's own parts.
pub const VENDOR_MEDIATEK: u16 = 0x0E8D;

/// Modules with a MediaTek MT79xx chip under their maker's vendor id.
pub const modules = [_][2]u16{
    // MT7920
    .{ 0x0489, 0xE134 }, .{ 0x13D3, 0x3620 }, .{ 0x13D3, 0x3621 }, .{ 0x13D3, 0x3622 },
    // MT7921
    .{ 0x0489, 0xE0C8 }, .{ 0x0489, 0xE0CD }, .{ 0x0489, 0xE0E0 }, .{ 0x0489, 0xE0F2 },
    .{ 0x04CA, 0x3802 }, .{ 0x13D3, 0x3563 }, .{ 0x13D3, 0x3564 }, .{ 0x13D3, 0x3567 },
    .{ 0x13D3, 0x3576 }, .{ 0x13D3, 0x3578 }, .{ 0x13D3, 0x3583 }, .{ 0x13D3, 0x3606 },
    // MT7922
    .{ 0x13D3, 0x3585 }, .{ 0x13D3, 0x3610 }, .{ 0x0489, 0xE0D8 }, .{ 0x0489, 0xE0D9 },
    .{ 0x0489, 0xE0E2 }, .{ 0x0489, 0xE0E4 }, .{ 0x0489, 0xE0F1 }, .{ 0x0489, 0xE0F5 },
    .{ 0x0489, 0xE0F6 }, .{ 0x0489, 0xE102 }, .{ 0x0489, 0xE152 }, .{ 0x0489, 0xE153 },
    .{ 0x04CA, 0x3804 }, .{ 0x04CA, 0x38E4 }, .{ 0x13D3, 0x3568 }, .{ 0x13D3, 0x3584 },
    .{ 0x13D3, 0x3605 }, .{ 0x13D3, 0x3607 }, .{ 0x13D3, 0x3614 },
};

/// Whether a USB device of this vendor and product has a MediaTek chip.
pub fn isMediaTek(vendor_id: u16, product_id: u16) bool {
    if (vendor_id == VENDOR_MEDIATEK) return true;
    for (modules) |module| {
        if (module[0] == vendor_id and module[1] == product_id) return true;
    }
    return false;
}

// --- the chip's registers and its WMT ------------------------------------------

pub const REG_CHIP_ID_OLD: u32 = 0x80000008;
pub const REG_CHIP_ID: u32 = 0x70010200;
pub const REG_FW_VERSION: u32 = 0x80021004;
pub const REG_FW_FLAVOR: u32 = 0x70010020;
pub const REG_EP_RST_OPT: u32 = 0x74011890;
pub const EP_RST_IN_OUT_OPT: u32 = 0x00010001;

/// The vendor command WMT is carried in, and the event it answers with.
pub const HCI_OP_WMT: u16 = 0xFC6F;
pub const HCI_EV_WMT: u8 = 0xE4;

pub const WMT_PATCH_DWNLD: u8 = 0x01;
pub const WMT_FUNC_CTRL: u8 = 0x06;

/// The WMT header: direction, operation, length (with the flag), flag.
pub const WMT_HDR = 5;
/// The most data a WMT packet carries: what fits in a command.
pub const WMT_MAX_DATA = 255 - WMT_HDR;
/// The firmware's bytes in one packet.
pub const CHUNK = 250;
/// The answer's room, as asked for.
pub const ANSWER_ROOM = 64;

/// How often an answer is asked for, and the pause between: ten seconds.
pub const POLL_PAUSE_US = 500;
pub const POLLS = 20_000;

/// The firmware file's parts.
pub const HEADER_SIZE = 32;
pub const GLOBAL_SIZE = 64;
pub const MAP_SIZE = 64;
/// Where in a section's map its download spec starts, and how much of it
/// the chip is offered.
pub const MAP_SPEC = 12;
pub const SPEC_SENT = 52;
/// A section offered again while the chip says it is busy, and the pause.
pub const BUSY_TRIES = 20;
pub const BUSY_PAUSE_US = 100_000;
/// After the last section: the firmware's time to start.
pub const START_PAUSE_US = 110_000;

/// What a section's offer is answered.
pub const Offer = enum { wanted, busy, have };

pub const Failure = error{
    /// A control transfer failed: the chip is gone, or does not take it.
    Transfer,
    /// No answer to a WMT command in its time.
    NoAnswer,
    /// An answer to another operation, or too short to be one.
    BadAnswer,
    /// The firmware file is not one.
    BadFile,
    /// A chip of the family the device has no setup for.
    Unsupported,
    /// The controller is being let go.
    Leaving,
};

/// What the setup runs over.
pub const Port = struct {
    context: *anyopaque,
    /// A control transfer on endpoint 0: the bytes moved, or null when it
    /// failed. `data` is what goes out, or the room for what comes in, of
    /// the setup's length.
    control: *const fn (context: *anyopaque, setup: *const d.SetupPacket, data: ?[*]u8) ?usize,
    /// At least this long a pause.
    pause: *const fn (context: *anyopaque, micros: u32) void,
    /// Whether the controller is being let go.
    leaving: *const fn (context: *anyopaque) bool,
};

fn le32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) | @as(u32, bytes[1]) << 8 | @as(u32, bytes[2]) << 16 | @as(u32, bytes[3]) << 24;
}

/// One of the chip's registers, by request 0x63.
pub fn readRegister(port: Port, register: u32) Failure!u32 {
    if (port.leaving(port.context)) return error.Leaving;
    const setup = d.SetupPacket{
        .request_type = d.USB_DIR_IN | d.USB_TYPE_VENDOR | d.USB_RECIP_DEVICE,
        .request = 0x63,
        .value = @truncate(register >> 16),
        .index = @truncate(register),
        .length = 4,
    };
    var value: [4]u8 = @splat(0);
    const moved = port.control(port.context, &setup, &value) orelse return error.Transfer;
    if (moved < 4) return error.Transfer;
    return le32(&value);
}

/// One of the chip's USB registers written, by request 0x02.
pub fn writeUsbRegister(port: Port, register: u32, value: u32) Failure!void {
    if (port.leaving(port.context)) return error.Leaving;
    const setup = d.SetupPacket{
        .request_type = 0x5E,
        .request = 0x02,
        .value = @truncate(register >> 16),
        .index = @truncate(register),
        .length = 4,
    };
    var bytes = [4]u8{ @truncate(value), @truncate(value >> 8), @truncate(value >> 16), @truncate(value >> 24) };
    _ = port.control(port.context, &setup, &bytes) orelse return error.Transfer;
}

/// A WMT command made an HCI command packet in `into`: its length.
pub fn wmtCommand(into: []u8, op: u8, flag: u8, data: []const u8) usize {
    const length = WMT_HDR + data.len;
    into[0] = @truncate(HCI_OP_WMT);
    into[1] = @truncate(HCI_OP_WMT >> 8);
    into[2] = @intCast(length);
    into[3] = 1;
    into[4] = op;
    into[5] = @truncate(data.len + 1);
    into[6] = @truncate((data.len + 1) >> 8);
    into[7] = flag;
    for (data, 0..) |byte, index| into[8 + index] = byte;
    return 3 + length;
}

/// What a WMT answer says: its flag, and for FUNC_CTRL its status word.
pub const Answer = struct {
    flag: u8,
    status: u16,
};

/// The answer to operation `op` read from an event: null when the event
/// is not that.
pub fn wmtAnswer(op: u8, event: []const u8) ?Answer {
    if (event.len < 2 + WMT_HDR or event[0] != HCI_EV_WMT) return null;
    if (event[3] != op) return null;
    const status: u16 = if (event.len >= 2 + WMT_HDR + 2) @as(u16, event[7]) << 8 | event[8] else 0;
    return .{ .flag = event[6], .status = status };
}

/// A section's offer answered: from the flag of PATCH_DWNLD's answer.
pub fn offerOf(answer: Answer) Offer {
    return switch (answer.flag) {
        2 => .have,
        1 => .busy,
        else => .wanted,
    };
}

/// A WMT command sent and its answer waited for.
pub fn wmt(port: Port, op: u8, flag: u8, data: []const u8) Failure!Answer {
    if (port.leaving(port.context)) return error.Leaving;
    if (data.len > WMT_MAX_DATA) return error.BadFile;
    var packet: [3 + 255]u8 = undefined;
    const length = wmtCommand(&packet, op, flag, data);
    const out = d.SetupPacket{
        .request_type = d.USB_DIR_OUT | d.USB_TYPE_CLASS | d.USB_RECIP_DEVICE,
        .request = 0,
        .value = 0,
        .index = 0,
        .length = @intCast(length),
    };
    _ = port.control(port.context, &out, &packet) orelse return error.Transfer;
    const in = d.SetupPacket{
        .request_type = d.USB_DIR_IN | d.USB_TYPE_VENDOR | d.USB_RECIP_DEVICE,
        .request = 1,
        .value = 48,
        .index = 0,
        .length = ANSWER_ROOM,
    };
    var event: [ANSWER_ROOM]u8 = undefined;
    var polls: u32 = 0;
    while (polls < POLLS) : (polls += 1) {
        if (port.leaving(port.context)) return error.Leaving;
        const moved = port.control(port.context, &in, &event) orelse return error.Transfer;
        if (moved > 0) return wmtAnswer(op, event[0..@min(moved, event.len)]) orelse error.BadAnswer;
        port.pause(port.context, POLL_PAUSE_US);
    }
    return error.NoAnswer;
}

// --- which chip, which file ------------------------------------------------------

pub const Chip = struct {
    /// 0x7922, 0x7961, 0x7925, ...
    id: u32,
    /// The firmware version the chip asks for: its low byte names the
    /// file.
    version: u32,
    /// 1 for the 7961's other flavour.
    flavor: u32,
};

/// The chip read from its registers.
pub fn identify(port: Port) Failure!Chip {
    var chip = Chip{ .id = try readRegister(port, REG_CHIP_ID_OLD), .version = 0, .flavor = 0 };
    if (chip.id != 0x7663) {
        chip.id = try readRegister(port, REG_CHIP_ID);
        chip.version = try readRegister(port, REG_FW_VERSION);
        chip.flavor = (try readRegister(port, REG_FW_FLAVOR) & 0x80) >> 7;
    }
    return chip;
}

/// Whether the device has a setup for the chip.
pub fn supported(chip: Chip) bool {
    return switch (chip.id & 0xFFFF) {
        0x7922, 0x7925, 0x7961 => true,
        else => false,
    };
}

/// `value` in lower-case hex: at least `digits` digits, more when it
/// needs them.
fn putHex(into: []u8, at: *usize, value: u32, digits: u32) void {
    var count: u32 = 1;
    while (count < 8 and value >> @intCast(count * 4) != 0) count += 1;
    count = @max(count, digits);
    while (count > 0) {
        count -= 1;
        const nibble: u8 = @truncate(value >> @intCast(count * 4) & 0xF);
        into[at.*] = if (nibble < 10) '0' + nibble else 'a' + nibble - 10;
        at.* += 1;
    }
}

fn putText(into: []u8, at: *usize, text: []const u8) void {
    for (text) |char| {
        into[at.*] = char;
        at.* += 1;
    }
}

/// The chip's name, NUL-ended in `into` (24 bytes are enough): "MediaTek
/// MT7922". The length without the NUL.
pub fn chipName(into: []u8, chip: Chip) usize {
    var at: usize = 0;
    putText(into, &at, "MediaTek MT");
    putHex(into, &at, chip.id & 0xFFFF, 4);
    into[at] = 0;
    return at;
}

/// The firmware file's path under the firmware directory, NUL-ended in
/// `into` (48 bytes are enough): the length without the NUL.
pub fn fileName(into: []u8, chip: Chip) usize {
    const id = chip.id & 0xFFFF;
    const step = (chip.version & 0xFF) + 1;
    var at: usize = 0;
    if (id == 0x7925) {
        putText(into, &at, "mt");
        putHex(into, &at, id, 4);
        putText(into, &at, "/");
    }
    putText(into, &at, "BT_RAM_CODE_MT");
    putHex(into, &at, id, 4);
    putText(into, &at, if (id == 0x7961 and chip.flavor != 0) "_1a_" else "_1_");
    putHex(into, &at, step, 1);
    putText(into, &at, "_hdr.bin");
    into[at] = 0;
    return at;
}

// --- the firmware file -------------------------------------------------------------

/// A section of the firmware file: its spec to offer, and its bytes.
pub const Section = struct {
    spec: *const [SPEC_SENT]u8,
    bytes: []const u8,
};

/// The file's sections, checked to lie inside it.
pub const Sections = struct {
    file: []const u8,
    count: u32,
    next: u32 = 0,

    pub fn of(file: []const u8) Failure!Sections {
        if (file.len < HEADER_SIZE + GLOBAL_SIZE) return error.BadFile;
        const count = le32(file[HEADER_SIZE + 12 ..][0..4]);
        if (count > (file.len - HEADER_SIZE - GLOBAL_SIZE) / MAP_SIZE) return error.BadFile;
        var sections = Sections{ .file = file, .count = count };
        // Every section checked before the first is sent.
        while (try sections.take()) |_| {}
        sections.next = 0;
        return sections;
    }

    /// The next section; null after the last.
    pub fn take(sections: *Sections) Failure!?Section {
        if (sections.next == sections.count) return null;
        const map = sections.file[HEADER_SIZE + GLOBAL_SIZE + MAP_SIZE * @as(usize, sections.next) ..][0..MAP_SIZE];
        sections.next += 1;
        const offset: usize = le32(map[4..8]);
        const size: usize = le32(map[MAP_SPEC + 4 ..][0..4]);
        if (offset > sections.file.len or size > sections.file.len - offset) return error.BadFile;
        return .{ .spec = map[MAP_SPEC..][0..SPEC_SENT], .bytes = sections.file[offset..][0..size] };
    }
};

/// The build time the file's header starts with, as text: up to the
/// first byte that is not a printable one.
pub fn buildTime(file: []const u8) []const u8 {
    if (file.len < 16) return file[0..0];
    var length: usize = 0;
    while (length < 16 and file[length] >= 0x20 and file[length] < 0x7F) : (length += 1) {}
    return file[0..length];
}

/// The flag of the packet that starts at `at` of a section of `size`
/// bytes: 1 the first, 3 the last after it, 2 those between.
pub fn chunkFlag(at: usize, size: usize) u8 {
    if (at == 0) return 1;
    if (size - at <= CHUNK) return 3;
    return 2;
}

/// The firmware given to the chip, then its Bluetooth switched on: how
/// many sections it was sent (0 when it had them all).
pub fn load(port: Port, file: []const u8) Failure!u32 {
    var sections = try Sections.of(file);
    var sent: u32 = 0;
    var offer: [1 + SPEC_SENT]u8 = undefined;
    offer[0] = 0;
    while (try sections.take()) |section| {
        if (section.bytes.len == 0) continue;
        for (section.spec, 0..) |byte, index| offer[1 + index] = byte;
        var tries: u32 = BUSY_TRIES;
        const wanted = while (tries > 0) {
            switch (offerOf(try wmt(port, WMT_PATCH_DWNLD, 0, &offer))) {
                .wanted => break true,
                .have => break false,
                .busy => {
                    port.pause(port.context, BUSY_PAUSE_US);
                    tries -= 1;
                },
            }
        } else true;
        if (!wanted) continue;
        var at: usize = 0;
        while (at < section.bytes.len) {
            const length = @min(CHUNK, section.bytes.len - at);
            _ = try wmt(port, WMT_PATCH_DWNLD, chunkFlag(at, section.bytes.len), section.bytes[at..][0..length]);
            at += length;
        }
        sent += 1;
    }
    port.pause(port.context, START_PAUSE_US);
    try writeUsbRegister(port, REG_EP_RST_OPT, EP_RST_IN_OUT_OPT);
    _ = try wmt(port, WMT_FUNC_CTRL, 0, &.{1});
    return sent;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "the chips: MediaTek's own id, and modules under their maker's" {
    try testing.expect(isMediaTek(0x0E8D, 0xC616));
    try testing.expect(isMediaTek(0x13D3, 0x3585));
    try testing.expect(isMediaTek(0x0489, 0xE0D8));
    try testing.expect(!isMediaTek(0x8087, 0x0029));
    try testing.expect(!isMediaTek(0x13D3, 0x3549));
}

test "a WMT command: HCI vendor command 0xFC6F, its header, its data" {
    var packet: [16]u8 = undefined;
    const length = wmtCommand(&packet, WMT_FUNC_CTRL, 0, &.{1});
    try testing.expectEqualSlices(u8, &.{ 0x6F, 0xFC, 6, 1, WMT_FUNC_CTRL, 2, 0, 0, 1 }, packet[0..length]);
}

test "a WMT answer: the operation's, its flag, FUNC_CTRL's status" {
    const done = [_]u8{ HCI_EV_WMT, 5, 2, WMT_PATCH_DWNLD, 1, 0, 2 };
    try testing.expectEqual(Offer.have, offerOf(wmtAnswer(WMT_PATCH_DWNLD, &done).?));
    const busy = [_]u8{ HCI_EV_WMT, 5, 2, WMT_PATCH_DWNLD, 1, 0, 1 };
    try testing.expectEqual(Offer.busy, offerOf(wmtAnswer(WMT_PATCH_DWNLD, &busy).?));
    const wanted = [_]u8{ HCI_EV_WMT, 5, 2, WMT_PATCH_DWNLD, 1, 0, 0 };
    try testing.expectEqual(Offer.wanted, offerOf(wmtAnswer(WMT_PATCH_DWNLD, &wanted).?));
    const on = [_]u8{ HCI_EV_WMT, 7, 2, WMT_FUNC_CTRL, 3, 0, 0, 0x04, 0x04 };
    try testing.expectEqual(@as(u16, 0x404), wmtAnswer(WMT_FUNC_CTRL, &on).?.status);
    try testing.expect(wmtAnswer(WMT_FUNC_CTRL, &done) == null);
    try testing.expect(wmtAnswer(WMT_PATCH_DWNLD, &.{ 0x0E, 4, 1, 0x6F, 0xFC, 0 }) == null);
}

test "the firmware file each chip asks for, and its name" {
    var into: [48]u8 = undefined;
    var length = fileName(&into, .{ .id = 0x7922, .version = 0x8A00, .flavor = 0 });
    try testing.expectEqualStrings("BT_RAM_CODE_MT7922_1_1_hdr.bin", into[0..length]);
    try testing.expectEqual(@as(u8, 0), into[length]);
    length = fileName(&into, .{ .id = 0x7961, .version = 1, .flavor = 1 });
    try testing.expectEqualStrings("BT_RAM_CODE_MT7961_1a_2_hdr.bin", into[0..length]);
    length = fileName(&into, .{ .id = 0x7925, .version = 0x0F, .flavor = 0 });
    try testing.expectEqualStrings("mt7925/BT_RAM_CODE_MT7925_1_10_hdr.bin", into[0..length]);
    length = chipName(&into, .{ .id = 0x00007922, .version = 0, .flavor = 0 });
    try testing.expectEqualStrings("MediaTek MT7922", into[0..length]);
    try testing.expect(supported(.{ .id = 0x7922, .version = 0, .flavor = 0 }));
    try testing.expect(!supported(.{ .id = 0x7663, .version = 0, .flavor = 0 }));
}

test "the packets of a section: first, middle, last" {
    try testing.expectEqual(@as(u8, 1), chunkFlag(0, 600));
    try testing.expectEqual(@as(u8, 2), chunkFlag(250, 600));
    try testing.expectEqual(@as(u8, 3), chunkFlag(500, 600));
    try testing.expectEqual(@as(u8, 1), chunkFlag(0, 250));
    try testing.expectEqual(@as(u8, 3), chunkFlag(250, 260));
}

/// A firmware file of two sections, of 600 and 100 bytes.
fn testFile() [96 + 2 * 64 + 700]u8 {
    var file: [96 + 2 * 64 + 700]u8 = @splat(0);
    @memcpy(file[0..15], "20241106163512a");
    file[HEADER_SIZE + 12] = 2;
    const sizes = [2]u32{ 600, 100 };
    var offset: u32 = 96 + 2 * 64;
    for (sizes, 0..) |size, index| {
        const map = file[96 + 64 * index ..][0..64];
        map[4..8].* = .{ @truncate(offset), @truncate(offset >> 8), 0, 0 };
        map[16..20].* = .{ @truncate(size), @truncate(size >> 8), 0, 0 };
        for (map[20..64], 0..) |*byte, at| byte.* = @truncate(0x40 + at + index);
        for (file[offset..][0..size], 0..) |*byte, at| byte.* = @truncate(at + index);
        offset += size;
    }
    return file;
}

test "a firmware file's sections, and one that does not hold them" {
    var file = testFile();
    try testing.expectEqualStrings("20241106163512a", buildTime(&file));
    var sections = try Sections.of(&file);
    const first = (try sections.take()).?;
    try testing.expectEqual(@as(usize, 600), first.bytes.len);
    try testing.expectEqual(@as(u8, 0x40), first.spec[8]);
    try testing.expectEqual(@as(usize, 100), (try sections.take()).?.bytes.len);
    try testing.expect((try sections.take()) == null);
    file[96 + 64 + 16] = 0xFF;
    file[96 + 64 + 17] = 0xFF;
    try testing.expectError(error.BadFile, Sections.of(&file));
    file = testFile();
    file[HEADER_SIZE + 12] = 200;
    try testing.expectError(error.BadFile, Sections.of(&file));
    try testing.expectError(error.BadFile, Sections.of(file[0..40]));
}

/// A chip that answers from a script: its registers, its sections, and
/// the packets it was given.
const Scripted = struct {
    /// How the sections' offers are answered, in turn: WMT flags.
    offers: []const u8,
    offer_count: usize = 0,
    /// The offers' data, the packets' flags and lengths.
    offered: [4][1 + SPEC_SENT]u8 = undefined,
    chunks: [8][2]usize = undefined,
    chunk_count: usize = 0,
    /// The answer waiting, and the empty reads before it is there.
    answer: [16]u8 = undefined,
    answer_length: usize = 0,
    empty: u32 = 0,
    reset_option: u32 = 0,
    switched_on: bool = false,
    paused: u64 = 0,

    fn of(context: *anyopaque) *Scripted {
        return @ptrCast(@alignCast(context));
    }

    fn control(context: *anyopaque, setup: *const d.SetupPacket, data: ?[*]u8) ?usize {
        const chip = of(context);
        const bytes = data.?[0..setup.length];
        switch (setup.request_type) {
            0xC0 => if (setup.request == 0x63) {
                const register = @as(u32, setup.value) << 16 | setup.index;
                const value: u32 = switch (register) {
                    REG_CHIP_ID => 0x7922,
                    REG_FW_VERSION => 0x8A00,
                    else => 0,
                };
                bytes[0..4].* = .{ @truncate(value), @truncate(value >> 8), @truncate(value >> 16), @truncate(value >> 24) };
                return 4;
            } else {
                if (chip.empty > 0) {
                    chip.empty -= 1;
                    return 0;
                }
                const length = chip.answer_length;
                @memcpy(bytes[0..length], chip.answer[0..length]);
                chip.answer_length = 0;
                chip.empty = 2;
                return length;
            },
            0x5E => {
                if (@as(u32, setup.value) << 16 | setup.index == REG_EP_RST_OPT) chip.reset_option = le32(bytes);
                return 4;
            },
            0x20 => {
                const op = bytes[4];
                const flag = bytes[7];
                const payload = bytes[8..];
                var answer_flag: u8 = 0;
                if (op == WMT_PATCH_DWNLD and flag == 0) {
                    @memcpy(&chip.offered[chip.offer_count], payload);
                    answer_flag = chip.offers[chip.offer_count];
                    chip.offer_count += 1;
                } else if (op == WMT_PATCH_DWNLD) {
                    chip.chunks[chip.chunk_count] = .{ flag, payload.len };
                    chip.chunk_count += 1;
                } else if (op == WMT_FUNC_CTRL) {
                    chip.switched_on = payload[0] == 1;
                }
                chip.answer[0..7].* = .{ HCI_EV_WMT, 5, 2, op, 1, 0, answer_flag };
                chip.answer_length = 7;
                return setup.length;
            },
            else => return null,
        }
    }

    fn pause(context: *anyopaque, micros: u32) void {
        of(context).paused += micros;
    }

    fn leaving(_: *anyopaque) bool {
        return false;
    }

    fn port(chip: *Scripted) Port {
        return .{ .context = chip, .control = control, .pause = pause, .leaving = leaving };
    }
};

test "the chip read, its firmware given section by section, its Bluetooth on" {
    var chip = Scripted{ .offers = &.{ 1, 0, 0 } };
    const found = try identify(chip.port());
    try testing.expectEqual(@as(u32, 0x7922), found.id);
    try testing.expectEqual(@as(u32, 0x8A00), found.version);
    const file = testFile();
    // The first section offered while the chip is busy, then wanted; the
    // second wanted.
    try testing.expectEqual(@as(u32, 2), try load(chip.port(), &file));
    try testing.expectEqual(@as(usize, 3), chip.offer_count);
    try testing.expectEqual(@as(u8, 0), chip.offered[0][0]);
    try testing.expectEqualSlices(u8, file[96 + MAP_SPEC ..][0..SPEC_SENT], chip.offered[0][1..]);
    try testing.expectEqualSlices(u8, file[96 + 64 + MAP_SPEC ..][0..SPEC_SENT], chip.offered[2][1..]);
    try testing.expectEqual(@as(usize, 4), chip.chunk_count);
    try testing.expectEqualSlices(usize, &.{ 1, 250 }, &chip.chunks[0]);
    try testing.expectEqualSlices(usize, &.{ 2, 250 }, &chip.chunks[1]);
    try testing.expectEqualSlices(usize, &.{ 3, 100 }, &chip.chunks[2]);
    try testing.expectEqualSlices(usize, &.{ 1, 100 }, &chip.chunks[3]);
    try testing.expectEqual(EP_RST_IN_OUT_OPT, chip.reset_option);
    try testing.expect(chip.switched_on);
    try testing.expect(chip.paused >= BUSY_PAUSE_US + START_PAUSE_US);
}

test "a chip that has its firmware already is sent none of it" {
    var chip = Scripted{ .offers = &.{ 2, 2 } };
    const file = testFile();
    try testing.expectEqual(@as(u32, 0), try load(chip.port(), &file));
    try testing.expectEqual(@as(usize, 0), chip.chunk_count);
    try testing.expect(chip.switched_on);
}
