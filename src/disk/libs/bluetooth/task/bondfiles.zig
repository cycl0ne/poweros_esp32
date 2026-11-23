// SPDX-License-Identifier: MIT
//! A controller's bonds as they are kept from one start to the next: a
//! keyword file per device in the controller's directory,
//! `ENVARC:Sys/bluetooth/<controller>/<device>` - each address its twelve
//! hex digits, the most significant first (`00005EEF1042`):
//!
//!   Name = "Phone"     the device's name at the pairing, UTF-8; a `"` in
//!                      it is kept as `'`, a control character as a space
//!   Class = 0x5A020C   its class of device
//!   LinkKey = 00112233445566778899AABBCCDDEEFF
//!                      the link key, its 16 bytes in the controller's order
//!   KeyType = 4        the key's kind (hci.LINK_KEY_*)
//!   Legacy = YES       made with a PIN
//!
//! Read by the task with the controller's settings, while its bring-up
//! waits: a file whose name is not an address, or that holds no whole
//! key, is passed over. Written when a pairing makes a bond or the
//! controller changes its key, deleted when UnpairBTDevice ends it.

const sdk = @import("sdk");
const dos = sdk.dos;
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const DosBase = sdk.interface.dos.DosBase;
const Scanner = dos.keywords.Scanner;
const bonds = @import("../hci/bonds.zig");
const settings = @import("settings.zig");

const directory = "ENVARC:Sys/bluetooth/";
const digits = "0123456789ABCDEF";

/// A path: the directory, the controller's address, and the device's,
/// ended by a NUL.
const Path = [directory.len + 12 + 1 + 12 + 1]u8;

/// An address's twelve hex digits, the most significant first.
fn putAddress(into: *[12]u8, address: *const [6]u8) void {
    var index: usize = 6;
    var at: usize = 0;
    while (index > 0) {
        index -= 1;
        into[at] = digits[address[index] >> 4];
        into[at + 1] = digits[address[index] & 15];
        at += 2;
    }
}

/// The controller's directory, or - with `device` - the device's file in
/// it.
fn pathOf(controller: *const [6]u8, device: ?*const [6]u8) Path {
    var path: Path = @splat(0);
    @memcpy(path[0..directory.len], directory);
    putAddress(path[directory.len..][0..12], controller);
    if (device) |bytes| {
        path[directory.len + 12] = '/';
        putAddress(path[directory.len + 13 ..][0..12], bytes);
    }
    return path;
}

fn digitOf(char: u8) ?u8 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => null,
    };
}

/// The address a file's name is - twelve hex digits, the most
/// significant first; null for any other name.
pub fn addressOf(name: []const u8) ?[6]u8 {
    if (name.len != 12) return null;
    var bytes: [6]u8 = undefined;
    for (0..6) |index| {
        const high = digitOf(name[index * 2]) orelse return null;
        const low = digitOf(name[index * 2 + 1]) orelse return null;
        bytes[5 - index] = high << 4 | low;
    }
    return bytes;
}

/// A key's 32 hex digits into `into`; false for anything else.
fn keyOf(text: []const u8, into: *[hci.LINK_KEY_SIZE]u8) bool {
    if (text.len != hci.LINK_KEY_SIZE * 2) return false;
    for (into, 0..) |*byte, index| {
        const high = digitOf(text[index * 2]) orelse return false;
        const low = digitOf(text[index * 2 + 1]) orelse return false;
        byte.* = high << 4 | low;
    }
    return true;
}

const Keyword = enum { name, class, link_key, key_type, legacy, other };

fn keywordOf(word: []const u8) Keyword {
    if (settings.same(word, "Name")) return .name;
    if (settings.same(word, "Class")) return .class;
    if (settings.same(word, "LinkKey")) return .link_key;
    if (settings.same(word, "KeyType")) return .key_type;
    if (settings.same(word, "Legacy")) return .legacy;
    return .other;
}

/// A bond file's `Keyword = value` pairs into `into`, the ones it does not
/// know passed over: whether it held a whole key.
pub fn parse(scanner: *Scanner, into: *bonds.Bond) bool {
    var keyed = false;
    while (scanner.next()) {
        // Known before the scanner moves on, which overwrites its token.
        const keyword = keywordOf(scanner.token[0..scanner.len]);
        if (!scanner.next() or scanner.len != 1 or scanner.token[0] != '=') return false;
        if (!scanner.next()) return false;
        const value = scanner.token[0..scanner.len];
        switch (keyword) {
            .name => {
                const length = @min(value.len, bluetooth.BT_BOND_NAME_MOST);
                @memcpy(into.name[0..length], value[0..length]);
                into.name[length] = 0;
            },
            .class => if (scanner.kind == .number) {
                into.class_of_device = @as(u32, @bitCast(scanner.number)) & 0xFF_FFFF;
            },
            .link_key => keyed = keyOf(value, &into.key),
            .key_type => if (scanner.kind == .number and scanner.number >= 0 and scanner.number <= hci.LINK_KEY_AUTHENTICATED_P256) {
                into.key_type = @intCast(scanner.number);
            },
            .legacy => into.legacy = settings.yesOf(scanner) orelse into.legacy,
            .other => {},
        }
    }
    return keyed;
}

/// The longest bond file: its keywords, the longest name, the key.
pub const TEXT_MOST = 96 + bluetooth.BT_BOND_NAME_MOST + hci.LINK_KEY_SIZE * 2;

/// A bond's file as text into `into`: its length.
pub fn format(bond: *const bonds.Bond, into: *[TEXT_MOST]u8) usize {
    var length: usize = 0;
    const put = struct {
        fn text(room: *[TEXT_MOST]u8, at: *usize, part: []const u8) void {
            @memcpy(room[at.*..][0..part.len], part);
            at.* += part.len;
        }
        fn hex(room: *[TEXT_MOST]u8, at: *usize, byte: u8) void {
            room[at.*] = digits[byte >> 4];
            room[at.* + 1] = digits[byte & 15];
            at.* += 2;
        }
    };
    put.text(into, &length, "/* bluetooth.library's bond with the device of this name */\nName = \"");
    for (bond.name) |char| {
        if (char == 0) break;
        into[length] = if (char == '"') '\'' else if (char < 0x20 or char == 0x7F) ' ' else char;
        length += 1;
    }
    put.text(into, &length, "\"\nClass = 0x");
    put.hex(into, &length, @truncate(bond.class_of_device >> 16));
    put.hex(into, &length, @truncate(bond.class_of_device >> 8));
    put.hex(into, &length, @truncate(bond.class_of_device));
    put.text(into, &length, "\nLinkKey = ");
    for (bond.key) |byte| put.hex(into, &length, byte);
    put.text(into, &length, "\nKeyType = ");
    if (bond.key_type >= 10) {
        into[length] = '0' + bond.key_type / 10;
        length += 1;
    }
    into[length] = '0' + bond.key_type % 10;
    length += 1;
    put.text(into, &length, if (bond.legacy) "\nLegacy = YES\n" else "\nLegacy = NO\n");
    return length;
}

/// The bond's file written - in `room` - the directories it needs made:
/// false when it could not be.
pub fn write(dl: *DosBase, controller: *const [6]u8, bond: *const bonds.Bond, room: *[TEXT_MOST]u8) bool {
    const length = format(bond, room);
    var path = pathOf(controller, &bond.address.bytes);
    return settings.putFile(dl, @ptrCast(&path), room[0..length]);
}

/// The file of the bond with `device` deleted: false when it is there
/// still.
pub fn delete(dl: *DosBase, controller: *const [6]u8, device: *const [6]u8) bool {
    var path = pathOf(controller, device);
    if (dl.DeleteFile(@ptrCast(&path))) return true;
    return dl.IoErr() == dos.ERROR_OBJECT_NOT_FOUND;
}

/// The bond files of a controller, one at a time.
pub const Reader = struct {
    dl: *DosBase,
    controller: [6]u8,
    lock: ?*dos.FileLock = null,

    /// The controller's directory looked at with `info`, which `next`
    /// goes on with: none there, and `next` finds nothing.
    pub fn open(dl: *DosBase, controller: *const [6]u8, info: *dos.FileInfoBlock) Reader {
        var reader = Reader{ .dl = dl, .controller = controller.* };
        var path = pathOf(controller, null);
        const lock = dl.Lock(@ptrCast(&path), dos.SHARED_LOCK) orelse return reader;
        if (!dl.Examine(lock, info)) {
            dl.UnLock(lock);
            return reader;
        }
        reader.lock = lock;
        return reader;
    }

    /// The next bond read into `into`: false when there is none.
    pub fn next(reader: *Reader, info: *dos.FileInfoBlock, into: *bonds.Bond) bool {
        const lock = reader.lock orelse return false;
        while (reader.dl.ExNext(lock, info)) {
            if (info.dir_entry_type >= 0) continue;
            const name: [*:0]const u8 = @ptrCast(&info.file_name);
            var length: usize = 0;
            while (name[length] != 0) length += 1;
            const device = addressOf(name[0..length]) orelse continue;
            var path = pathOf(&reader.controller, &device);
            const file = reader.dl.Open(@ptrCast(&path), dos.MODE_OLDFILE) orelse continue;
            into.* = .{ .address = .{ .bytes = device, .kind = bluetooth.BTADDR_BREDR } };
            var scanner = Scanner.ofFile(reader.dl, file);
            const whole = parse(&scanner, into);
            _ = reader.dl.Close(file);
            if (whole) return true;
        }
        return false;
    }

    pub fn close(reader: *Reader) void {
        if (reader.lock) |lock| reader.dl.UnLock(lock);
        reader.lock = null;
    }
};
