// SPDX-License-Identifier: MIT
//! What a Broadcom controller on a UART needs before it is one: its line's
//! rate changed, its patch loaded, its address set - each a vendor command
//! of the chip's own, answered by Command Complete as HCI's are.
//!
//! **The line's rate** is 0xFC18 with two bytes of 0 and the rate in bits
//! a second (32 bits): the controller answers at the old rate and takes
//! the new one after. It starts at 115200 bit/s, and again after a patch.
//!
//! **The patch** - Broadcom's `.hcd` file, by the chip's name - is a run
//! of HCI commands, each its opcode (16 bits), the length of its
//! parameters (8 bits) and the parameters: Write RAM (0xFC4C) over and
//! over, then Launch RAM (0xFC4E). It is sent after Download Minidriver
//! (0xFC2E) and a pause of 50 ms, each command waiting for its answer, and
//! the controller takes 250 ms after the last to start what it was given.
//!
//! **The chip's name** comes from the LMP subversion it answers Read Local
//! Version Information with: the CYW43455's Bluetooth is a BCM4345C0, its
//! patch `BCM4345C0.hcd`.
//!
//! **Its address** is 0xFC01 with the six bytes of the address, the least
//! significant first, as HCI has addresses; it outlasts HCI_Reset. A
//! controller nobody gave one keeps its maker's (43:45:C0:00:1F:AC for
//! every BCM4345C0).
//!
//! Pure: the worker sends what this makes, and the host tests read it.

const sdk = @import("sdk");
const hci = sdk.bluetooth.hci;

/// The vendor commands.
pub const OP_WRITE_BD_ADDR: u16 = 0xFC01;
pub const OP_UPDATE_UART_BAUD_RATE: u16 = 0xFC18;
pub const OP_DOWNLOAD_MINIDRIVER: u16 = 0xFC2E;
pub const OP_WRITE_RAM: u16 = 0xFC4C;
pub const OP_LAUNCH_RAM: u16 = 0xFC4E;

/// The rate every controller starts at, and starts again at after its
/// patch.
pub const START_BAUD: u32 = 115200;

/// The pauses: after Download Minidriver, after the patch's last command,
/// and after a reset, in microseconds.
pub const MINIDRIVER_PAUSE_US: u32 = 50_000;
pub const LAUNCH_PAUSE_US: u32 = 250_000;
pub const RESET_PAUSE_US: u32 = 100_000;

/// The chips by the LMP subversion they answer.
const Chip = struct { subversion: u16, name: []const u8 };
const chips = [_]Chip{
    .{ .subversion = 0x6119, .name = "BCM4345C0" },
    .{ .subversion = 0x6606, .name = "BCM4345C5" },
};

/// The chip's name for an LMP subversion, or null for a chip not known.
pub fn chipName(subversion: u16) ?[]const u8 {
    for (chips) |chip| {
        if (chip.subversion == subversion) return chip.name;
    }
    return null;
}

/// 0xFC18's parameters for `baud` bits a second.
pub fn baudParams(baud: u32) [6]u8 {
    return .{ 0, 0, @truncate(baud), @truncate(baud >> 8), @truncate(baud >> 16), @truncate(baud >> 24) };
}

/// The patch's file for a chip: its name and ".hcd", into `into`; how
/// many bytes it is, 0 when it does not fit.
pub fn fileName(into: []u8, chip: []const u8) usize {
    const suffix = ".hcd";
    if (chip.len + suffix.len > into.len) return 0;
    @memcpy(into[0..chip.len], chip);
    @memcpy(into[chip.len..][0..suffix.len], suffix);
    return chip.len + suffix.len;
}

/// The build a controller's HCI revision names: its low 12 bits.
pub fn build(hci_revision: u16) u16 {
    return hci_revision & 0x0FFF;
}

/// One of the patch's commands.
pub const Record = struct {
    opcode: u16,
    params: []const u8,
};

/// The patch's commands, in their order.
pub const Records = struct {
    file: []const u8,
    at: usize = 0,

    pub const Error = error{
        /// A command runs past the file's end: the file is damaged.
        Truncated,
    };

    /// The next command, or null after the last.
    pub fn next(records: *Records) Error!?Record {
        const rest = records.file[records.at..];
        if (rest.len == 0) return null;
        if (rest.len < hci.HCI_COMMAND_HDR) return error.Truncated;
        const length: usize = rest[2];
        if (rest.len < hci.HCI_COMMAND_HDR + length) return error.Truncated;
        records.at += hci.HCI_COMMAND_HDR + length;
        return .{
            .opcode = @as(u16, rest[0]) | @as(u16, rest[1]) << 8,
            .params = rest[hci.HCI_COMMAND_HDR..][0..length],
        };
    }

    /// How many commands the file holds: an error when one runs past its
    /// end.
    pub fn count(file: []const u8) Error!u32 {
        var records = Records{ .file = file };
        var counted: u32 = 0;
        while (try records.next()) |_| counted += 1;
        return counted;
    }
};

/// `value` written into `into` at `at` in decimal, at least `digits` of
/// them: the place after it, or `at` when it does not fit.
pub fn decimal(into: []u8, at: usize, value: u32, digits: usize) usize {
    var reversed: [10]u8 = undefined;
    var length: usize = 0;
    var rest = value;
    while (rest != 0 or length < @max(digits, 1)) : (length += 1) {
        reversed[length] = '0' + @as(u8, @intCast(rest % 10));
        rest /= 10;
    }
    if (at + length > into.len) return at;
    for (0..length) |index| into[at + index] = reversed[length - 1 - index];
    return at + length;
}

/// `text` written into `into` at `at`: the place after it, or `at` when
/// it does not fit.
pub fn text(into: []u8, at: usize, words: []const u8) usize {
    if (at + words.len > into.len) return at;
    @memcpy(into[at..][0..words.len], words);
    return at + words.len;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "the chip by its LMP subversion, and its patch's name" {
    try testing.expectEqualStrings("BCM4345C0", chipName(0x6119).?);
    try testing.expect(chipName(0x1234) == null);
    var name: [32]u8 = undefined;
    const length = fileName(&name, chipName(0x6119).?);
    try testing.expectEqualStrings("BCM4345C0.hcd", name[0..length]);
    try testing.expectEqual(@as(usize, 0), fileName(name[0..8], "BCM4345C0"));
}

test "the line's rate: two bytes of 0, then the rate, the least significant byte first" {
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0x00, 0x10, 0x0E, 0x00 }, &baudParams(921600));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0x00, 0xC2, 0x01, 0x00 }, &baudParams(115200));
}

test "a patch's commands in order, and a file cut short" {
    // Write RAM with 4 bytes, Write RAM with none, Launch RAM.
    const patch = [_]u8{
        0x4C, 0xFC, 4,    1,    2,    3, 4,
        0x4C, 0xFC, 0,    0x4E, 0xFC, 4, 0xFF,
        0xFF, 0xFF, 0xFF,
    };
    var records = Records{ .file = &patch };
    const first = (try records.next()).?;
    try testing.expectEqual(OP_WRITE_RAM, first.opcode);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, first.params);
    try testing.expectEqual(@as(usize, 0), (try records.next()).?.params.len);
    try testing.expectEqual(OP_LAUNCH_RAM, (try records.next()).?.opcode);
    try testing.expect((try records.next()) == null);
    try testing.expectEqual(@as(u32, 3), try Records.count(&patch));
    try testing.expectError(error.Truncated, Records.count(patch[0..5]));
    try testing.expectError(error.Truncated, Records.count(patch[0..9]));
}

test "a build in four digits and a version in three" {
    var line: [32]u8 = undefined;
    var at = text(&line, 0, "build ");
    at = decimal(&line, at, build(0x0182), 4);
    try testing.expectEqualStrings("build 0386", line[0..at]);
    at = decimal(&line, 0, 25, 3);
    try testing.expectEqualStrings("025", line[0..at]);
    at = decimal(&line, 0, 0, 0);
    try testing.expectEqualStrings("0", line[0..at]);
    try testing.expectEqual(@as(usize, 30), decimal(&line, 30, 12345, 0));
}
