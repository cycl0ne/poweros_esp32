// SPDX-License-Identifier: MIT
//! The services the profile drivers took, kept with their device's bond:
//! a file beside the bond's (task/bondfiles.zig), its name the bond
//! file's with `.services` after it -
//! `ENVARC:Sys/bluetooth/<controller>/<device>.services`, an LE device's
//! `<device>.le.services` or `<device>.random.services` - a line a
//! service:
//!
//!   Record 35500900000A00010000...
//!                      its SDP record as the device sent it, in hex
//!   Gatt 0010 001F 0000181200001000800000805F9B34FB
//!                      a GATT service: its first and last handle and
//!                      its UUID, in hex
//!
//! Written by the binder once a new bond's services are bound, read each
//! time the controller comes up, deleted with the bond (task/_task.zig's
//! `keepBonds`). A line that is not a whole record or service is passed
//! over. The bond files' reader passes the file over: its name is no
//! address.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const bluetooth = sdk.bluetooth;
const DosBase = sdk.interface.dos.DosBase;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const bondfiles = @import("../task/bondfiles.zig");
const settings = @import("../task/settings.zig");
const att_client = @import("../att/client.zig");

const suffix = ".services";
const keyword = "Record ";
const gatt_keyword = "Gatt ";
/// A GATT service's line past its keyword: two handles and a UUID, a
/// space after each handle.
const gatt_length = 4 + 1 + 4 + 1 + 32;
const header = "/* the services of this device that bluetooth.library's profile drivers took */\n";
const digits = "0123456789ABCDEF";
/// The most a file is read of.
const FILE_MOST = 64 * 1024;

/// A service the file keeps: an SDP record, or a GATT service's handles
/// and UUID.
pub const Kept = union(enum) {
    record: []const u8,
    gatt: att_client.ServiceRecord,
};

/// A path: a bond file's, then the suffix, ended by a NUL.
pub const Path = [@sizeOf(bondfiles.Path) + suffix.len]u8;

/// The file of the services kept with the bond with `device`.
pub fn pathOf(controller: *const [6]u8, device: *const bluetooth.BTAddress) Path {
    const bond = bondfiles.pathOf(controller, device);
    var path: Path = @splat(0);
    var length: usize = 0;
    while (bond[length] != 0) length += 1;
    @memcpy(path[0..length], bond[0..length]);
    @memcpy(path[length..][0..suffix.len], suffix);
    return path;
}

/// The services written, a line each - a GATT service's handles and UUID,
/// another's record: false when the file could not be.
pub fn write(base: *BluetoothBase, dl: *DosBase, controller: *const [6]u8, device: *const bluetooth.BTAddress, services: []const *const bluetooth.BTService) bool {
    const sys = base.sys_base;
    const size = textSize(services);
    const memory = sys.AllocVec(size, 0) orelse return false;
    defer sys.FreeVec(memory);
    const text: [*]u8 = @ptrCast(memory);
    const length = format(services, text[0..size]);
    var path = pathOf(controller, device);
    return settings.putFile(dl, @ptrCast(&path), text[0..length]);
}

/// The bytes the file of these services takes.
pub fn textSize(services: []const *const bluetooth.BTService) usize {
    var size: usize = header.len;
    for (services) |service| {
        size += if (service.flags & bluetooth.BTSF_GATT != 0) gatt_keyword.len + gatt_length + 1 else keyword.len + 2 * service.record_length + 1;
    }
    return size;
}

/// The file's text into `into`, textSize's bytes: its length.
pub fn format(services: []const *const bluetooth.BTService, into: []u8) usize {
    @memcpy(into[0..header.len], header);
    var at: usize = header.len;
    for (services) |service| {
        if (service.flags & bluetooth.BTSF_GATT != 0) {
            @memcpy(into[at..][0..gatt_keyword.len], gatt_keyword);
            at += gatt_keyword.len;
            at += hex(into[at..], &.{ @truncate(service.handle >> 8), @truncate(service.handle) });
            into[at] = ' ';
            at += 1;
            at += hex(into[at..], &.{ @truncate(service.end_handle >> 8), @truncate(service.end_handle) });
            into[at] = ' ';
            at += 1;
            at += hex(into[at..], &service.class.bytes);
        } else {
            @memcpy(into[at..][0..keyword.len], keyword);
            at += keyword.len;
            at += hex(into[at..], service.record.?[0..service.record_length]);
        }
        into[at] = '\n';
        at += 1;
    }
    return at;
}

/// `bytes` as hex digits into `into`: how many.
fn hex(into: []u8, bytes: []const u8) usize {
    for (bytes, 0..) |byte, index| {
        into[2 * index] = digits[byte >> 4];
        into[2 * index + 1] = digits[byte & 15];
    }
    return 2 * bytes.len;
}

/// Each service the file keeps handed to `each`, in its order; nothing
/// where there is no file, or no memory to read it.
pub fn read(base: *BluetoothBase, dl: *DosBase, controller: *const [6]u8, device: *const bluetooth.BTAddress, context: anytype, comptime each: fn (@TypeOf(context), Kept) void) void {
    const sys = base.sys_base;
    var path = pathOf(controller, device);
    const file = dl.Open(@ptrCast(&path), dos.MODE_OLDFILE) orelse return;
    defer _ = dl.Close(file);
    const memory = sys.AllocVec(FILE_MOST, 0) orelse return;
    defer sys.FreeVec(memory);
    const room: [*]u8 = @ptrCast(memory);
    var length: usize = 0;
    while (length < FILE_MOST) {
        const got = dl.Read(file, room + length, @intCast(FILE_MOST - length));
        if (got <= 0) break;
        length += @intCast(got);
    }
    parse(room[0..length], context, each);
}

/// Each service of the file's text handed to `each`, in its order: the
/// text made a record's bytes where their digits were.
pub fn parse(text: []u8, context: anytype, comptime each: fn (@TypeOf(context), Kept) void) void {
    const length = text.len;
    var start: usize = 0;
    while (start < length) {
        var end = start;
        while (end < length and text[end] != '\n') end += 1;
        const line = text[start..end];
        start = end + 1;
        var trimmed = line.len;
        while (trimmed > 0 and (line[trimmed - 1] == ' ' or line[trimmed - 1] == '\r')) trimmed -= 1;
        if (trimmed > gatt_keyword.len and same(line[0..gatt_keyword.len], gatt_keyword)) {
            if (gattOf(line[gatt_keyword.len..trimmed])) |service| each(context, .{ .gatt = service });
            continue;
        }
        if (trimmed <= keyword.len or !same(line[0..keyword.len], keyword)) continue;
        if (bytesOf(line[keyword.len..trimmed])) |bytes| each(context, .{ .record = bytes });
    }
}

/// The hex digits of `digits_text` made bytes where they are - each byte
/// before the digits it is read from; null where they are not whole
/// bytes.
fn bytesOf(digits_text: []u8) ?[]u8 {
    if (digits_text.len % 2 != 0) return null;
    const bytes = digits_text[0 .. digits_text.len / 2];
    for (0..bytes.len) |index| {
        const high = digitOf(digits_text[index * 2]) orelse return null;
        const low = digitOf(digits_text[index * 2 + 1]) orelse return null;
        bytes[index] = high << 4 | low;
    }
    return bytes;
}

/// A GATT service's line past its keyword: `0010 001F <32 digits>`.
fn gattOf(text: []u8) ?att_client.ServiceRecord {
    if (text.len != gatt_length or text[4] != ' ' or text[9] != ' ') return null;
    const first = bytesOf(text[0..4]) orelse return null;
    const last = bytesOf(text[5..9]) orelse return null;
    const uuid = bytesOf(text[10..]) orelse return null;
    return .{
        .start = @as(u16, first[0]) << 8 | first[1],
        .end = @as(u16, last[0]) << 8 | last[1],
        .uuid = uuid[0..16].*,
    };
}

/// The file kept with the bond with `device` deleted: false when it is
/// there still.
pub fn delete(dl: *DosBase, controller: *const [6]u8, device: *const bluetooth.BTAddress) bool {
    var path = pathOf(controller, device);
    if (dl.DeleteFile(@ptrCast(&path))) return true;
    return dl.IoErr() == dos.ERROR_OBJECT_NOT_FOUND;
}

fn digitOf(char: u8) ?u8 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => null,
    };
}

fn same(text: []const u8, wanted: []const u8) bool {
    if (text.len != wanted.len) return false;
    for (text, wanted) |char, other| {
        if (char != other) return false;
    }
    return true;
}
