// SPDX-License-Identifier: MIT
//! The profile drivers: which there are, and offering them services.
//!
//! **Finding them.** The first time the binder needs them, every file in
//! `DEVS:bluetooth/` is read for its ROM tag (sdk/libs/dos/loadfile.zig,
//! `findResident`): a `ResidentDevice` that speaks `DEVIF_BTPROFILE` is a
//! profile driver, and its match table is copied out - the controllers'
//! drivers there speak DEVIF_HCI and are passed over. Nothing is loaded
//! and nothing runs. The profile drivers the ROM carries are taken first,
//! from its own tags, and a file of a name the ROM has is passed over.
//! While `DEVS:bluetooth/` cannot be read, the table is the ROM's alone
//! and the drawer is looked for again each time the table is asked for.
//!
//! **Offering a service.** Every driver with an entry the service
//! matches - BTMATCH_BREDR for an SDP record's, BTMATCH_LE for a GATT
//! service, and its class, in 16 bits or 128 - is a candidate, the
//! higher priority first. Each in turn is opened - which loads it - on
//! `BTPROFILE_UNIT_BIND` and called with BTProfileBind; the first that
//! takes the service keeps it, and one that drives nothing is closed
//! again so it can be expunged.
//!
//! The table is the binder's: only its process reads and changes it, the
//! names of its drivers fixed once read.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const bluetooth = sdk.bluetooth;
const btprofile = sdk.devices.btprofile;
const loadfile = dos.loadfile;
const devices = sdk.expansion.devices;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const BTProfileBase = sdk.interface.btprofile.BTProfileBase;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;

/// Where the profile drivers are.
pub const DRIVERS_DIR = "DEVS:bluetooth";
/// The most drivers, and entries in a driver's table, kept.
pub const max_drivers = 16;
pub const max_matches = 8;

/// A profile driver found in DEVS:bluetooth/.
pub const Driver = struct {
    /// "bluetooth/<file>", what it is opened by.
    name: [48]u8 = @splat(0),
    matches: [max_matches]btprofile.BTMatch = @splat(.{}),
    match_count: u32 = 0,
    /// Open while it drives something: the request it was opened with,
    /// and how many services it drives.
    io: exec.IORequest = .{},
    binds: u32 = 0,
};

/// The table of drivers, in the base's `profile_drivers`.
pub const Drivers = struct {
    /// `DEVS:bluetooth/` was read: the table is whole.
    disk_read: bool = false,
    count: u32 = 0,
    list: [max_drivers]Driver = @splat(.{}),
};

/// What a driver is opened by: its file's name after this.
const driver_prefix = "bluetooth/";

/// A driver's name as it is shown: its file's.
pub fn nameOf(driver: *const Driver) []const u8 {
    const name = driver.name[driver_prefix.len..];
    var length: usize = 0;
    while (length < name.len and name[length] != 0) length += 1;
    return name[0..length];
}

/// A file read through dos for `loadfile`'s reader.
const DosFile = struct {
    dl: *DosBase,
    file: *dos.FileHandle,

    fn readAt(context: *anyopaque, offset: u32, into: []u8) bool {
        const self: *DosFile = @ptrCast(@alignCast(context));
        if (self.dl.Seek(self.file, @intCast(offset), dos.OFFSET_BEGINNING) < 0) return false;
        const got = self.dl.Read(self.file, into.ptr, @intCast(into.len));
        return got == @as(isize, @intCast(into.len));
    }
};

/// The table, read from DEVS:bluetooth/ if it has not been. On the binder.
pub fn table(base: *BluetoothBase) ?*Drivers {
    if (base.profile_drivers) |found| {
        const kept: *Drivers = @ptrCast(@alignCast(found));
        readDisk(base, kept);
        return kept;
    }
    const sys = base.sys_base;
    // Kept in the library's base: the system's.
    const memory = sys.AllocMem(@sizeOf(Drivers), exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return null;
    const made: *Drivers = @ptrCast(@alignCast(memory));
    made.* = .{};
    base.profile_drivers = made;
    fromRom(sys, made);
    readDisk(base, made);
    return made;
}

/// The table let go of: at the expunge, when the binder has ended - no
/// driver is open then.
pub fn release(base: *BluetoothBase) void {
    const found = base.profile_drivers orelse return;
    base.sys_base.FreeMem(found, @sizeOf(Drivers));
    base.profile_drivers = null;
}

/// Whether any driver takes a service over this kind of link
/// (BTMATCH_*).
pub fn wants(kept: *const Drivers, over: u8) bool {
    for (kept.list[0..kept.count]) |*driver| {
        for (driver.matches[0..driver.match_count]) |entry| {
            if (entry.over == over) return true;
        }
    }
    return false;
}

/// The ROM's profile drivers into the table: every tag of a device that
/// speaks `DEVIF_BTPROFILE`, under the name it is opened by.
fn fromRom(sys: *ExecBase, kept: *Drivers) void {
    const tags = sys.ResModules() orelse return;
    var index: usize = 0;
    while (tags[index]) |tag| : (index += 1) {
        if (tag.flags & exec.RTF_DEVICEINFO == 0 or tag.type != .device) continue;
        const device: *const exec.ResidentDevice = @ptrCast(tag);
        var is_profile = false;
        var at: usize = 0;
        while (at < 16 and device.speaks[at] != 0) : (at += 1) {
            if (device.speaks[at] == devices.DEVIF_BTPROFILE) is_profile = true;
        }
        if (!is_profile or kept.count >= max_drivers) continue;
        const profile: *const btprofile.ResidentBTProfile = @ptrCast(tag);
        const driver = &kept.list[kept.count];
        driver.* = .{};
        var length: usize = 0;
        while (tag.name[length] != 0) length += 1;
        if (driver_prefix.len + length + 1 > driver.name.len) continue;
        @memcpy(driver.name[0..driver_prefix.len], driver_prefix);
        @memcpy(driver.name[driver_prefix.len..][0..length], tag.name[0..length]);
        var count: u32 = 0;
        while (count < max_matches and profile.matches[count].over != 0) : (count += 1) driver.matches[count] = profile.matches[count];
        driver.match_count = count;
        if (count != 0) kept.count += 1;
    }
}

/// The drivers in `DEVS:bluetooth/` added to the table, once the drawer
/// can be read. Asked without a requester for a volume that is not there.
fn readDisk(base: *BluetoothBase, kept: *Drivers) void {
    if (kept.disk_read) return;
    const sys = base.sys_base;
    const dl = base.dos orelse return;
    const me = sys.FindTask(null).?;
    const process: ?*dos.Process = if (me.node.type == .process) @ptrCast(@alignCast(me)) else null;
    const asked = if (process) |own| own.window_ptr else null;
    if (process) |own| own.window_ptr = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
    defer if (process) |own| {
        own.window_ptr = asked;
    };
    const dir = dl.Lock(DRIVERS_DIR, dos.ACCESS_READ) orelse return;
    defer dl.UnLock(dir);
    kept.disk_read = true;
    var fib: dos.FileInfoBlock = .{};
    if (!dl.Examine(dir, &fib)) return;
    while (dl.ExNext(dir, &fib)) {
        if (dos.isDirectory(fib.dir_entry_type)) continue;
        if (kept.count >= max_drivers) break;
        if (known(kept, fileName(&fib))) continue;
        readDriver(dl, &kept.list[kept.count], fileName(&fib)) catch continue;
        kept.count += 1;
    }
}

/// Whether the table has a driver of this file's name already: the ROM's.
fn known(kept: *const Drivers, file_name: []const u8) bool {
    for (kept.list[0..kept.count]) |*driver| {
        const name = nameOf(driver);
        if (name.len != file_name.len) continue;
        var same = true;
        for (name, file_name) |have, want| {
            if (have != want) same = false;
        }
        if (same) return true;
    }
    return false;
}

fn fileName(fib: *const dos.FileInfoBlock) []const u8 {
    var length: usize = 0;
    while (length < fib.file_name.len and fib.file_name[length] != 0) length += 1;
    return fib.file_name[0..length];
}

/// One file's tag into `driver`, if it is a profile driver's.
fn readDriver(dl: *DosBase, driver: *Driver, file_name: []const u8) !void {
    driver.* = .{};
    if (driver_prefix.len + file_name.len + 1 > driver.name.len) return error.Name;
    @memcpy(driver.name[0..driver_prefix.len], driver_prefix);
    @memcpy(driver.name[driver_prefix.len..][0..file_name.len], file_name);

    var path: [96]u8 = @splat(0);
    const dir_part = DRIVERS_DIR ++ "/";
    if (dir_part.len + file_name.len + 1 > path.len) return error.Name;
    @memcpy(path[0..dir_part.len], dir_part);
    @memcpy(path[dir_part.len..][0..file_name.len], file_name);
    const file = dl.Open(@ptrCast(&path), dos.MODE_OLDFILE) orelse return error.Open;
    defer _ = dl.Close(file);
    var reader = DosFile{ .dl = dl, .file = file };
    const source = loadfile.Source{ .context = &reader, .readAt = DosFile.readAt };
    const found = loadfile.findResident(source) orelse return error.NoTag;

    var flags_byte: [1]u8 = undefined;
    if (!loadfile.readBytes(source, found, found.tag + @offsetOf(exec.Resident, "flags"), &flags_byte)) return error.Tag;
    if (flags_byte[0] & exec.RTF_DEVICEINFO == 0) return error.NotDevice;
    const speaks_at = loadfile.readWord(source, found, found.tag + @offsetOf(exec.ResidentDevice, "speaks")) orelse return error.Tag;
    var is_profile = false;
    var index: u32 = 0;
    while (index < 16) : (index += 1) {
        const set = loadfile.readWord(source, found, speaks_at + index * 4) orelse return error.Tag;
        if (set == 0) break;
        if (set == devices.DEVIF_BTPROFILE) is_profile = true;
    }
    if (!is_profile) return error.NotProfile;
    const matches_at = loadfile.readWord(source, found, found.tag + @offsetOf(btprofile.ResidentBTProfile, "matches")) orelse return error.Tag;
    var count: u32 = 0;
    while (count < max_matches) : (count += 1) {
        var entry: btprofile.BTMatch = .{};
        const bytes: *[@sizeOf(btprofile.BTMatch)]u8 = @ptrCast(&entry);
        if (!loadfile.readBytes(source, found, matches_at + count * @sizeOf(btprofile.BTMatch), bytes)) return error.Tag;
        if (entry.over == 0) break;
        driver.matches[count] = entry;
    }
    driver.match_count = count;
    if (count == 0) return error.NoMatches;
}

/// Whether `entry` takes `service`: its kind of link, and its class.
pub fn takes(entry: btprofile.BTMatch, service: *const bluetooth.BTService) bool {
    const over: u8 = if (service.flags & bluetooth.BTSF_GATT != 0) btprofile.BTMATCH_LE else btprofile.BTMATCH_BREDR;
    if (entry.over != over) return false;
    if (entry.class16 != 0) return service.class16 == entry.class16;
    for (entry.class.bytes, service.class.bytes) |want, have| {
        if (want != have) return false;
    }
    return true;
}

/// A candidate: a driver and its best entry's priority for the service.
const Candidate = struct { driver: *Driver, priority: i8 };

/// `binding`'s service offered to the drivers, the higher priority first:
/// the driver that took it, or null where none did. On the binder.
pub fn offer(base: *BluetoothBase, binding: *bluetooth.BTBinding) ?*Driver {
    const kept = table(base) orelse return null;
    const service = binding.service.?;
    var candidates: [max_drivers]Candidate = undefined;
    var count: usize = 0;
    for (kept.list[0..kept.count]) |*driver| {
        var best: ?i8 = null;
        for (driver.matches[0..driver.match_count]) |entry| {
            if (!takes(entry, service)) continue;
            if (best == null or entry.priority > best.?) best = entry.priority;
        }
        if (best) |priority| {
            candidates[count] = .{ .driver = driver, .priority = priority };
            count += 1;
        }
    }
    // The higher first: few candidates, so a plain insertion sort.
    var i: usize = 1;
    while (i < count) : (i += 1) {
        const item = candidates[i];
        var j = i;
        while (j > 0 and item.priority > candidates[j - 1].priority) : (j -= 1) candidates[j] = candidates[j - 1];
        candidates[j] = item;
    }
    for (candidates[0..count]) |candidate| {
        const driver = candidate.driver;
        if (!openDriver(base, driver)) continue;
        const profile_base: *BTProfileBase = @ptrCast(driver.io.device.?);
        if (profile_base.BTProfileBind(binding)) {
            driver.binds += 1;
            return driver;
        }
        closeIfIdle(base, driver);
    }
    return null;
}

/// The driver opened - loaded, if it is not - on its binding unit.
fn openDriver(base: *BluetoothBase, driver: *Driver) bool {
    if (driver.io.device != null) return true;
    driver.io = .{};
    driver.io.message.length = @sizeOf(exec.IORequest);
    if (base.sys_base.OpenDevice(@ptrCast(&driver.name), btprofile.BTPROFILE_UNIT_BIND, &driver.io, 0) != 0) {
        driver.io.device = null;
        return false;
    }
    return true;
}

/// A driver that drives nothing closed, so it can be expunged.
fn closeIfIdle(base: *BluetoothBase, driver: *Driver) void {
    if (driver.binds != 0 or driver.io.device == null) return;
    base.sys_base.CloseDevice(&driver.io);
    driver.io.device = null;
}

/// A binding ended: the driver told, with `flags` (BTPU_*), and closed if
/// it drives nothing more. On the binder.
pub fn unbind(base: *BluetoothBase, driver: *Driver, binding: *bluetooth.BTBinding, flags: u32) void {
    if (driver.io.device) |device| {
        const profile_base: *BTProfileBase = @ptrCast(device);
        profile_base.BTProfileUnbind(binding, flags);
    }
    if (driver.binds != 0) driver.binds -= 1;
    closeIfIdle(base, driver);
}
