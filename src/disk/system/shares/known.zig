// SPDX-License-Identifier: MIT
//! The shares this machine knows: a file per share in `DEVS:Shares/`
//! saying where it is and who logs on to it, the password's hash beside it
//! in `ENVARC:`, and the device list saying which of them are mounted.
//!
//! **A share is known once its file is written**, whether or not it is
//! mounted: `C:net/MountShare ALL` at every start mounts what the files
//! say, so a share added here comes back by itself. Forgetting one is
//! deleting its two files.
//!
//! **A device name** is made from the share's name
//! (`deviceNameOf`): in capitals, with anything a name may not hold - a
//! colon, a slash, a space, the `$` of a server's own share - made an
//! underscore, and cut to `device_max`. It is a file name as well as a
//! device name, since the share file is called after it.

const sdk = @import("sdk");
const dos = sdk.dos;
const smb = dos.smb;
const client = @import("smbclient");
const sharefile = client.sharefile;
const words = @import("words.zig");
const DosBase = sdk.interface.dos.DosBase;

/// The longest device name, without its colon: what MountShare takes.
pub const device_max: usize = 30;

/// The most shares this holds at once.
pub const max_known: usize = 32;

/// A share file's or a password file's path.
pub const Path = [96:0]u8;

/// One share the machine knows.
pub const Known = struct {
    /// The device it is mounted as, in capitals, without its colon.
    device: [device_max + 1:0]u8 = @splat(0),
    /// What its file says. Meaningless while `wrong` is set.
    file: sharefile.ShareFile = .{},
    /// Its file could not be read, or says something that is not a share.
    wrong: bool = false,
    /// Its device stands on the list with a handler behind it.
    mounted: bool = false,
    /// There is a password file for it.
    password: bool = false,

    pub fn name(k: *const Known) []const u8 {
        return words.untilNul(&k.device);
    }

    pub fn share(k: *const Known) []const u8 {
        return words.untilNul(&k.file.share);
    }

    pub fn user(k: *const Known) []const u8 {
        return words.untilNul(&k.file.user);
    }
};

/// Every share the machine knows, read from the files and the device
/// list.
pub const List = struct {
    items: [max_known]Known = @splat(.{}),
    count: usize = 0,

    /// The files in `DEVS:Shares/` read, each marked with whether its
    /// device is mounted and whether a password is kept for it. Shares
    /// past `max_known` are left out.
    pub fn read(list: *List, dl: *DosBase) void {
        list.count = 0;
        readFiles(list, dl);
        markMounted(list, dl);
    }

    pub fn find(list: *List, device: []const u8) ?*Known {
        for (list.items[0..list.count]) |*item| {
            if (sameName(item.name(), device)) return item;
        }
        return null;
    }

    fn readFiles(list: *List, dl: *DosBase) void {
        const lock = dl.Lock(sharefile.directory, dos.ACCESS_READ) orelse return;
        defer dl.UnLock(lock);
        const fib: *dos.FileInfoBlock = @ptrCast(@alignCast(dl.AllocDosObject(dos.DOS_FIB, null) orelse return));
        defer dl.FreeDosObject(dos.DOS_FIB, fib);
        if (!dl.Examine(lock, fib)) return;
        while (dl.ExNext(lock, fib) and list.count < max_known) {
            if (dos.isDirectory(fib.dir_entry_type)) continue;
            const found = words.untilNul(&fib.file_name);
            if (found.len == 0 or found.len > device_max) continue;
            const item = &list.items[list.count];
            item.* = .{};
            for (found, 0..) |char, at| item.device[at] = upper(char);
            item.device[found.len] = 0;
            item.wrong = !readOne(dl, item.name(), &item.file);
            item.password = passwordKept(dl, item.name());
            list.count += 1;
        }
    }

    fn markMounted(list: *List, dl: *DosBase) void {
        const flags = dos.LDF_DEVICES | dos.LDF_READ;
        const first = dl.LockDosList(flags) orelse return;
        defer dl.UnLockDosList(flags);
        var node = first;
        while (dl.NextDosEntry(node, dos.LDF_DEVICES)) |entry| {
            node = entry;
            if (smb.SmbStartup.of(entry.misc.handler.startup) == null) continue;
            if (list.find(words.spanOf(entry.name))) |item| item.mounted = true;
        }
    }
};

/// A share file read: false when it is not there or says something that is
/// not a share.
pub fn readOne(dl: *DosBase, device: []const u8, into: *sharefile.ShareFile) bool {
    var path: Path = undefined;
    const handle = dl.Open(pathOf(&path, sharefile.directory, device), dos.MODE_OLDFILE) orelse return false;
    var scanner = dos.keywords.Scanner.ofFile(dl, handle);
    const found = sharefile.read(&scanner, into);
    _ = dl.Close(handle);
    return found.kind == .none;
}

/// Whether a password file is kept for a device.
pub fn passwordKept(dl: *DosBase, device: []const u8) bool {
    var path: Path = undefined;
    const lock = dl.Lock(pathOf(&path, sharefile.password_directory, device), dos.ACCESS_READ) orelse return false;
    dl.UnLock(lock);
    return true;
}

/// How a device by a name stands on the list: a share's, something else's,
/// or no device at all.
pub const Standing = enum { none, share, other };

pub fn standingOf(dl: *DosBase, device: []const u8) Standing {
    var name: [device_max + 1:0]u8 = @splat(0);
    _ = words.copyInto(&name, device);
    const flags = dos.LDF_DEVICES | dos.LDF_READ;
    const list = dl.LockDosList(flags) orelse return .none;
    defer dl.UnLockDosList(flags);
    const node = dl.FindDosEntry(list, &name, dos.LDF_DEVICES) orelse return .none;
    return if (smb.SmbStartup.of(node.misc.handler.startup) != null) .share else .other;
}

/// The share file and the password file of a device deleted: what it was
/// is forgotten, and the next start does not mount it.
pub fn forget(dl: *DosBase, device: []const u8) void {
    var path: Path = undefined;
    _ = dl.DeleteFile(pathOf(&path, sharefile.directory, device));
    _ = dl.DeleteFile(pathOf(&path, sharefile.password_directory, device));
}

/// The share file of a device deleted, its password file left alone: what
/// a mount that failed takes back.
pub fn unwrite(dl: *DosBase, device: []const u8, password_too: bool) void {
    var path: Path = undefined;
    _ = dl.DeleteFile(pathOf(&path, sharefile.directory, device));
    if (password_too) _ = dl.DeleteFile(pathOf(&path, sharefile.password_directory, device));
}

/// `directory` and `name` joined, with a NUL.
pub fn pathOf(into: *Path, directory: []const u8, name: []const u8) [*:0]const u8 {
    var at: usize = 0;
    for (directory) |char| {
        if (at + 1 >= into.len) break;
        into[at] = char;
        at += 1;
    }
    for (name) |char| {
        if (at + 1 >= into.len) break;
        into[at] = char;
        at += 1;
    }
    into[at] = 0;
    return @ptrCast(into);
}

/// The device name a share's name suggests: see the file's header. Empty
/// only when the share's name holds nothing a name may keep.
pub fn deviceNameOf(share: []const u8, into: *[device_max + 1:0]u8) []const u8 {
    @memset(into, 0);
    var length: usize = 0;
    for (share) |char| {
        if (length == device_max) break;
        const kept = upper(char);
        into[length] = switch (kept) {
            'A'...'Z', '0'...'9', '_', '-', '.' => kept,
            else => '_',
        };
        length += 1;
    }
    // Trailing underscores say nothing: a server's own `IPC$` would be
    // `IPC_`, and a share ending in a space `MY_FILES_`.
    while (length > 0 and into[length - 1] == '_') {
        length -= 1;
        into[length] = 0;
    }
    return into[0..length];
}

/// Whether a device name may be used for a share: it has something in it,
/// and nothing a file name or a device name may not hold.
pub fn nameAllowed(device: []const u8) bool {
    if (device.len == 0 or device.len > device_max) return false;
    for (device) |char| switch (char) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '-', '.' => {},
        else => return false,
    };
    return true;
}

fn upper(char: u8) u8 {
    return if (char >= 'a' and char <= 'z') char - 0x20 else char;
}

/// Two device names compared, which are in capitals either way.
pub fn sameName(one: []const u8, other: []const u8) bool {
    if (one.len != other.len) return false;
    for (one, other) |a, b| {
        if (upper(a) != upper(b)) return false;
    }
    return true;
}

// --- tests (host) ------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "a device name made from a share's" {
    var into: [device_max + 1:0]u8 = @splat(0);
    try testing.expectEqualStrings("PUBLIC", deviceNameOf("public", &into));
    try testing.expectEqualStrings("MY_FILES", deviceNameOf("My Files", &into));
    try testing.expectEqualStrings("IPC", deviceNameOf("IPC$", &into));
    try testing.expectEqualStrings("A.B-C_D", deviceNameOf("a.b-c_d", &into));
    try testing.expectEqualStrings("X", deviceNameOf("x:/\\", &into));
    try testing.expectEqualStrings("", deviceNameOf("$$$", &into));
    try testing.expectEqualStrings("", deviceNameOf("", &into));
    // Cut to the longest a device name may be.
    const long = deviceNameOf("a" ** 40, &into);
    try testing.expectEqual(device_max, long.len);
}

test "which device names may be used" {
    try testing.expect(nameAllowed("NAS"));
    try testing.expect(nameAllowed("My-Share.1"));
    try testing.expect(!nameAllowed(""));
    try testing.expect(!nameAllowed("NAS:"));
    try testing.expect(!nameAllowed("a/b"));
    try testing.expect(!nameAllowed("a b"));
    try testing.expect(!nameAllowed("a" ** (device_max + 1)));
}

test "a path joined, and names compared in either case" {
    var path: Path = undefined;
    try testing.expectEqualStrings("DEVS:Shares/NAS", words.spanOf(pathOf(&path, sharefile.directory, "NAS")));
    try testing.expectEqualStrings("ENVARC:Sys/net/shares/NAS", words.spanOf(pathOf(&path, sharefile.password_directory, "NAS")));
    try testing.expect(sameName("nas", "NAS"));
    try testing.expect(!sameName("nas", "nas1"));
}
