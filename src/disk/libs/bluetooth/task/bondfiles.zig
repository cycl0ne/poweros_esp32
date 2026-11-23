// SPDX-License-Identifier: MIT
//! A controller's bonds as they are kept from one start to the next: a
//! keyword file per device in the controller's directory,
//! `ENVARC:Sys/bluetooth/<controller>/<device>` - each address its twelve
//! hex digits, the most significant first (`00005EEF1042`), an LE
//! device's followed by `.le` for a public address and `.random` for a
//! static random one.
//!
//! A BR/EDR bond:
//!
//!   Name = "Phone"     the device's name at the pairing, UTF-8; a `"` in
//!                      it is kept as `'`, a control character as a space
//!   Class = 0x5A020C   its class of device
//!   LinkKey = 00112233445566778899AABBCCDDEEFF
//!                      the link key, its 16 bytes in the controller's order
//!   KeyType = 4        the key's kind (hci.LINK_KEY_*)
//!   Legacy = YES       made with a PIN
//!
//! An LE bond, beside its Name:
//!
//!   LTK = 00112233445566778899AABBCCDDEEFF
//!                      the long term key, in the controller's order
//!   EDIV = 0x1234      what the key goes by: 0 and zeros for one Secure
//!   Rand = 0011223344556677   Connections made
//!   KeySize = 16       its size in bytes
//!   Authenticated = YES   protected from a man in the middle
//!   SecureConnections = YES
//!   IRK = 00112233445566778899AABBCCDDEEFF
//!                      the device's identity resolving key, where it gave one
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
const le_suffix = ".le";
const random_suffix = ".random";

/// A path: the directory, the controller's address, and the device's with
/// the longest suffix, ended by a NUL.
pub const Path = [directory.len + 12 + 1 + 12 + random_suffix.len + 1]u8;

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

/// The suffix an address's kind gives its file's name.
fn suffixOf(kind: u8) []const u8 {
    return switch (kind) {
        bluetooth.BTADDR_LE_PUBLIC => le_suffix,
        bluetooth.BTADDR_LE_RANDOM => random_suffix,
        else => "",
    };
}

/// The controller's directory, or - with `device` - the device's file in
/// it.
pub fn pathOf(controller: *const [6]u8, device: ?*const bluetooth.BTAddress) Path {
    var path: Path = @splat(0);
    @memcpy(path[0..directory.len], directory);
    putAddress(path[directory.len..][0..12], controller);
    if (device) |address| {
        path[directory.len + 12] = '/';
        putAddress(path[directory.len + 13 ..][0..12], &address.bytes);
        const suffix = suffixOf(address.kind);
        @memcpy(path[directory.len + 25 ..][0..suffix.len], suffix);
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

fn sameText(text: []const u8, wanted: []const u8) bool {
    if (text.len != wanted.len) return false;
    for (text, wanted) |char, other| {
        if (char != other) return false;
    }
    return true;
}

/// The device a file's name is - twelve hex digits, the most significant
/// first, and an LE address's suffix; null for any other name.
pub fn addressOf(name: []const u8) ?bluetooth.BTAddress {
    if (name.len < 12) return null;
    var bytes: [6]u8 = undefined;
    for (0..6) |index| {
        const high = digitOf(name[index * 2]) orelse return null;
        const low = digitOf(name[index * 2 + 1]) orelse return null;
        bytes[5 - index] = high << 4 | low;
    }
    const suffix = name[12..];
    const kind: u8 = if (suffix.len == 0) bluetooth.BTADDR_BREDR else if (sameText(suffix, le_suffix)) bluetooth.BTADDR_LE_PUBLIC else if (sameText(suffix, random_suffix)) bluetooth.BTADDR_LE_RANDOM else return null;
    return .{ .bytes = bytes, .kind = kind };
}

/// `into.len` bytes as hex digits in `text`; false for anything else.
fn bytesOf(text: []const u8, into: []u8) bool {
    if (text.len != into.len * 2) return false;
    for (into, 0..) |*byte, index| {
        const high = digitOf(text[index * 2]) orelse return false;
        const low = digitOf(text[index * 2 + 1]) orelse return false;
        byte.* = high << 4 | low;
    }
    return true;
}

const Keyword = enum { name, class, link_key, key_type, legacy, ltk, ediv, rand, key_size, authenticated, secure_connections, irk, other };

fn keywordOf(word: []const u8) Keyword {
    const names = .{
        .{ "Name", Keyword.name },                            .{ "Class", Keyword.class },
        .{ "LinkKey", Keyword.link_key },                     .{ "KeyType", Keyword.key_type },
        .{ "Legacy", Keyword.legacy },                        .{ "LTK", Keyword.ltk },
        .{ "EDIV", Keyword.ediv },                            .{ "Rand", Keyword.rand },
        .{ "KeySize", Keyword.key_size },                     .{ "Authenticated", Keyword.authenticated },
        .{ "SecureConnections", Keyword.secure_connections }, .{ "IRK", Keyword.irk },
    };
    inline for (names) |pair| {
        if (settings.same(word, pair[0])) return pair[1];
    }
    return .other;
}

/// A bond file's `Keyword = value` pairs into `into`, whose address is
/// set already, the ones it does not know passed over: whether it held a
/// whole key - a link key, or an LE bond's long term key.
pub fn parse(scanner: *Scanner, into: *bonds.Bond) bool {
    var keyed = false;
    const le = bonds.le(into);
    while (scanner.next()) {
        // Known before the scanner moves on, which overwrites its token.
        const keyword = keywordOf(scanner.token[0..scanner.len]);
        if (!scanner.next() or scanner.len != 1 or scanner.token[0] != '=') return false;
        if (!scanner.next()) return false;
        const value = scanner.token[0..scanner.len];
        const number = scanner.kind == .number;
        switch (keyword) {
            .name => {
                const length = @min(value.len, bluetooth.BT_BOND_NAME_MOST);
                @memcpy(into.name[0..length], value[0..length]);
                into.name[length] = 0;
            },
            .class => if (number) {
                into.class_of_device = @as(u32, @bitCast(scanner.number)) & 0xFF_FFFF;
            },
            .link_key => if (!le) {
                keyed = bytesOf(value, &into.key);
            },
            .key_type => if (number and scanner.number >= 0 and scanner.number <= hci.LINK_KEY_AUTHENTICATED_P256) {
                into.key_type = @intCast(scanner.number);
            },
            .legacy => into.legacy = settings.yesOf(scanner) orelse into.legacy,
            .ltk => if (le) {
                keyed = bytesOf(value, &into.key);
            },
            .ediv => if (number and scanner.number >= 0 and scanner.number <= 0xFFFF) {
                into.ediv = @intCast(scanner.number);
            },
            .rand => {
                if (!bytesOf(value, &into.rand)) into.rand = @splat(0);
            },
            .key_size => if (number and scanner.number >= hci.MIN_ENCRYPTION_KEY_SIZE and scanner.number <= hci.LINK_KEY_SIZE) {
                into.key_size = @intCast(scanner.number);
            },
            .authenticated => into.le_authenticated = settings.yesOf(scanner) orelse into.le_authenticated,
            .secure_connections => into.le_secure = settings.yesOf(scanner) orelse into.le_secure,
            .irk => into.has_irk = bytesOf(value, &into.irk),
            .other => {},
        }
    }
    return keyed;
}

/// The longest bond file: an LE one's keywords with the longest name.
pub const TEXT_MOST = 400;

const Writer = struct {
    room: *[TEXT_MOST]u8,
    at: usize = 0,

    fn text(writer: *Writer, part: []const u8) void {
        @memcpy(writer.room[writer.at..][0..part.len], part);
        writer.at += part.len;
    }

    fn hex(writer: *Writer, bytes: []const u8) void {
        for (bytes) |byte| {
            writer.room[writer.at] = digits[byte >> 4];
            writer.room[writer.at + 1] = digits[byte & 15];
            writer.at += 2;
        }
    }

    fn decimal(writer: *Writer, value: u8) void {
        if (value >= 10) writer.text(&.{'0' + value / 10});
        writer.text(&.{'0' + value % 10});
    }

    fn yes(writer: *Writer, keyword: []const u8, value: bool) void {
        writer.text(keyword);
        writer.text(if (value) " = YES\n" else " = NO\n");
    }
};

/// A bond's file as text into `into`: its length.
pub fn format(bond: *const bonds.Bond, into: *[TEXT_MOST]u8) usize {
    var writer = Writer{ .room = into };
    writer.text("/* bluetooth.library's bond with the device of this name */\nName = \"");
    for (bond.name) |char| {
        if (char == 0) break;
        writer.text(&.{if (char == '"') '\'' else if (char < 0x20 or char == 0x7F) ' ' else char});
    }
    writer.text("\"\n");
    if (bonds.le(bond)) {
        writer.text("LTK = ");
        writer.hex(&bond.key);
        writer.text("\nEDIV = 0x");
        writer.hex(&.{ @truncate(bond.ediv >> 8), @truncate(bond.ediv) });
        writer.text("\nRand = ");
        writer.hex(&bond.rand);
        writer.text("\nKeySize = ");
        writer.decimal(bond.key_size);
        writer.text("\n");
        writer.yes("Authenticated", bond.le_authenticated);
        writer.yes("SecureConnections", bond.le_secure);
        if (bond.has_irk) {
            writer.text("IRK = ");
            writer.hex(&bond.irk);
            writer.text("\n");
        }
        return writer.at;
    }
    writer.text("Class = 0x");
    writer.hex(&.{ @truncate(bond.class_of_device >> 16), @truncate(bond.class_of_device >> 8), @truncate(bond.class_of_device) });
    writer.text("\nLinkKey = ");
    writer.hex(&bond.key);
    writer.text("\nKeyType = ");
    writer.decimal(bond.key_type);
    writer.text("\n");
    writer.yes("Legacy", bond.legacy);
    return writer.at;
}

/// The bond's file written - in `room` - the directories it needs made:
/// false when it could not be.
pub fn write(dl: *DosBase, controller: *const [6]u8, bond: *const bonds.Bond, room: *[TEXT_MOST]u8) bool {
    const length = format(bond, room);
    var path = pathOf(controller, &bond.address);
    return settings.putFile(dl, @ptrCast(&path), room[0..length]);
}

/// The file of the bond with `device` deleted: false when it is there
/// still.
pub fn delete(dl: *DosBase, controller: *const [6]u8, device: *const bluetooth.BTAddress) bool {
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
            into.* = .{ .address = device };
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
