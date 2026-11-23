// SPDX-License-Identifier: MIT
//! A controller's settings as they are kept from one start to the next,
//! in `ENVARC:Sys/bluetooth/<address>/` - the address its twelve hex
//! digits, the most significant first (`00005EEF1042`):
//!
//!   settings   a keyword file: `Powered = YES` or `NO`, and `Visible =
//!              YES` - found by others until told otherwise - or `NO`;
//!   name       the name it shows others, its first line, cut to the 247
//!              bytes its name has at most; without the file, the
//!              machine's.
//!
//! Read by the task once the controller's address is known, while its
//! bring-up waits (bringup.zig), and written whenever SetBTControllerAttrs
//! changes them. What a file does not say, or a controller without files,
//! is as a new controller has it: on, not visible. Visible for a time is
//! not kept: a start ends it.
//!
//! The name has a file of its own, so that a name of any length is kept
//! whole.

const sdk = @import("sdk");
const dos = sdk.dos;
const hci = sdk.bluetooth.hci;
const DosBase = sdk.interface.dos.DosBase;
const Scanner = dos.keywords.Scanner;
const local = @import("../hci/local.zig");

const directory = "ENVARC:Sys/bluetooth/";

/// What the files say.
pub const Kept = struct {
    powered: bool = true,
    visible: bool = false,
    /// The name, ended by a NUL; empty for the machine's.
    name: [hci.HCI_MAX_NAME + 1]u8 = @splat(0),
};

/// A path: the directory, the address, and `leaf`, ended by a NUL.
const Path = [directory.len + 12 + 1 + 8 + 1]u8;

fn pathOf(address: *const [6]u8, leaf: []const u8) Path {
    const digits = "0123456789ABCDEF";
    var path: Path = @splat(0);
    @memcpy(path[0..directory.len], directory);
    var at: usize = directory.len;
    var index: usize = 6;
    while (index > 0) {
        index -= 1;
        path[at] = digits[address[index] >> 4];
        path[at + 1] = digits[address[index] & 15];
        at += 2;
    }
    path[at] = '/';
    at += 1;
    @memcpy(path[at..][0..leaf.len], leaf);
    return path;
}

/// The settings kept for the controller at `address` read into `into`;
/// what is not there left as it is.
pub fn read(dl: *DosBase, address: *const [6]u8, into: *Kept) void {
    var path = pathOf(address, "settings");
    if (dl.Open(@ptrCast(&path), dos.MODE_OLDFILE)) |file| {
        var scanner = Scanner.ofFile(dl, file);
        readKeywords(&scanner, into);
        _ = dl.Close(file);
    }
    path = pathOf(address, "name");
    _ = readName(dl, @ptrCast(&path), &into.name);
}

/// The first line of the file at `path` into `into` as a controller's
/// name, ended by a NUL: its length, 0 for an empty one; `into` left as
/// it is when there is no such file.
fn readName(dl: *DosBase, path: [*:0]const u8, into: *[hci.HCI_MAX_NAME + 1]u8) usize {
    // The file's start alone: past the most a name has, nothing is the
    // name's.
    const file = dl.Open(path, dos.MODE_OLDFILE) orelse return 0;
    const got = dl.Read(file, into, into.len);
    _ = dl.Close(file);
    const length = nameLength(into[0..if (got > 0) @intCast(got) else 0]);
    into[length] = 0;
    return length;
}

/// The machine's name in a hostname file's `text`: its first line that is
/// neither blank nor a comment (`#`), without the spaces and tabs around
/// it; null for none.
pub fn hostNameIn(text: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (start < text.len) {
        var end = start;
        while (end < text.len and text[end] != '\n' and text[end] != '\r') end += 1;
        var line = text[start..end];
        while (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) line = line[1..];
        while (line.len > 0 and (line[line.len - 1] == ' ' or line[line.len - 1] == '\t')) line = line[0 .. line.len - 1];
        if (line.len != 0 and line[0] != '#') return line;
        start = end + 1;
    }
    return null;
}

/// How much of a name file's `bytes` is the name: its first line, cut as
/// the controller's name is (local.fitName).
pub fn nameLength(bytes: []const u8) usize {
    var end: usize = 0;
    while (end < bytes.len and bytes[end] != '\n' and bytes[end] != '\r' and bytes[end] != 0) : (end += 1) {}
    return local.fitName(bytes[0..end]);
}

/// `Keyword = value` pairs: the ones it knows taken, the rest passed over.
pub fn readKeywords(scanner: *Scanner, into: *Kept) void {
    while (scanner.next()) {
        // Known before the scanner moves on, which overwrites its token.
        const keyword = scanner.token[0..scanner.len];
        const setting: ?*bool = if (same(keyword, "Powered")) &into.powered else if (same(keyword, "Visible")) &into.visible else null;
        if (!scanner.next() or scanner.len != 1 or scanner.token[0] != '=') return;
        if (!scanner.next()) return;
        const yes = yesOf(scanner) orelse continue;
        if (setting) |kept| kept.* = yes;
    }
}

fn yesOf(scanner: *const Scanner) ?bool {
    const value = scanner.token[0..scanner.len];
    if (same(value, "YES")) return true;
    if (same(value, "NO")) return false;
    if (scanner.kind == .number) return scanner.number != 0;
    return null;
}

/// Whether two words are the same, in any case.
fn same(word: []const u8, keyword: []const u8) bool {
    if (word.len != keyword.len) return false;
    for (word, keyword) |char, wanted| {
        if (lower(char) != lower(wanted)) return false;
    }
    return true;
}

fn lower(char: u8) u8 {
    return if (char >= 'A' and char <= 'Z') char + 32 else char;
}

/// The settings file for the controller at `address` written, the
/// directories it needs made: false when it could not be.
pub fn writeSettings(dl: *DosBase, address: *const [6]u8, powered: bool, visible: bool) bool {
    var text: [160]u8 = undefined;
    var length: usize = 0;
    for ([_][]const u8{
        "/* bluetooth.library's settings for its controller at this address */\n",
        "Powered = ",
        if (powered) "YES" else "NO",
        "\nVisible = ",
        if (visible) "YES" else "NO",
        "\n",
    }) |part| {
        @memcpy(text[length..][0..part.len], part);
        length += part.len;
    }
    var path = pathOf(address, "settings");
    return putFile(dl, @ptrCast(&path), text[0..length]);
}

/// The name file written with `name` (up to its NUL), or deleted for an
/// empty one - the machine's name: false when that could not be.
pub fn writeName(dl: *DosBase, address: *const [6]u8, name: [*:0]const u8) bool {
    var path = pathOf(address, "name");
    var length: usize = 0;
    while (name[length] != 0) length += 1;
    if (length == 0) {
        // Not there is as good as deleted.
        _ = dl.DeleteFile(@ptrCast(&path));
        return true;
    }
    if (!dl.CreateDirs(@ptrCast(&path), false)) return false;
    const file = dl.Open(@ptrCast(&path), dos.MODE_NEWFILE) orelse return false;
    const written = dl.Write(file, name, @intCast(length));
    const ended = dl.Write(file, "\n", 1);
    const closed = dl.Close(file);
    return written == length and ended == 1 and closed;
}

fn putFile(dl: *DosBase, path: [*:0]const u8, bytes: []const u8) bool {
    if (!dl.CreateDirs(path, false)) return false;
    const file = dl.Open(path, dos.MODE_NEWFILE) orelse return false;
    const written = dl.Write(file, bytes.ptr, @intCast(bytes.len));
    const closed = dl.Close(file);
    return written == bytes.len and closed;
}
