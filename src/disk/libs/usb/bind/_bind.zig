// SPDX-License-Identifier: MIT
//! The class drivers: which there are, and offering them interfaces.
//!
//! **Finding them.** When the first bus starts, every file in `DEVS:usb/`
//! is read for its ROM tag (sdk/libs/dos/loadfile.zig, `findResident`):
//! a `ResidentDevice` that speaks `DEVIF_USBCLASS` is a class driver, and
//! its match table is copied out. Nothing is loaded and nothing runs: a
//! driver is a few hundred bytes read once, until something it drives is
//! plugged in.
//!
//! The class drivers the ROM carries are taken first, from its own tags
//! (`fromRom`): a machine that starts from a USB disk has that disk's
//! driver in its ROM, and its bus runs before there is a `DEVS:` to read.
//! A file of a name the ROM has is passed over. While `DEVS:usb/` cannot
//! be read, the table is the ROM's alone and the drawer is looked for
//! again each time the table is asked for (`readDisk`); a bus told to
//! look again (`StartUSB` on one that runs) offers every interface no
//! driver has to the drivers there are then.
//!
//! **Offering an interface.** Every driver whose table has an entry the
//! interface matches is a candidate, the most specific entry first (a
//! vendor and product above a class), the higher priority among equals.
//! Each in turn is opened - which loads it - on `USBCLASS_UNIT_BIND` and
//! called with USBClassBind; the first that takes the interface keeps it,
//! and one that took nothing is closed again so it can be expunged.
//!
//! The table and the drivers' opens are under the base's
//! `drivers_lock`: two buses' processes bind at once.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const usb = sdk.usb;
const usbclass = sdk.devices.usbclass;
const loadfile = dos.loadfile;
const devices = sdk.expansion.devices;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UsbClassBase = sdk.interface.usbclass.UsbClassBase;
const UsbBase = @import("../usb_base.zig").UsbBase;

/// Where the class drivers are.
pub const DRIVERS_DIR = "DEVS:usb";
/// The most drivers, and entries in a driver's table, kept.
pub const max_drivers = 16;
pub const max_matches = 16;

/// A class driver found in DEVS:usb/.
pub const Driver = struct {
    /// "usb/<file>", what it is opened by.
    name: [48]u8 = @splat(0),
    matches: [max_matches]usbclass.USBMatch = @splat(.{}),
    match_count: u32 = 0,
    /// Open while it drives something: the request it was opened with,
    /// and how many interfaces it drives.
    io: exec.IORequest = .{},
    binds: u32 = 0,
};

/// The table of drivers, in the base's `drivers`.
pub const Drivers = struct {
    /// `DEVS:usb/` was read: the table is whole.
    disk_read: bool = false,
    count: u32 = 0,
    list: [max_drivers]Driver = @splat(.{}),
};

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

/// The table, read from DEVS:usb/ if it has not been. Under
/// `drivers_lock`. On a process: it reads files.
pub fn table(base: *UsbBase) ?*Drivers {
    if (base.drivers) |found| {
        const drivers: *Drivers = @ptrCast(@alignCast(found));
        readDisk(base, drivers);
        return drivers;
    }
    const sys = base.sys_base;
    const dl = base.dos orelse return null;
    // Kept in the library's base: the system's.
    const memory = sys.AllocMem(@sizeOf(Drivers), exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return null;
    const drivers: *Drivers = @ptrCast(@alignCast(memory));
    drivers.* = .{};
    base.drivers = drivers;
    fromRom(sys, drivers);
    readDisk(base, drivers);
    _ = dl;
    return drivers;
}

/// The ROM's class drivers into the table: every tag of a device that
/// speaks `DEVIF_USBCLASS`, under the name it is opened by.
fn fromRom(sys: *ExecBase, drivers: *Drivers) void {
    const tags = sys.ResModules() orelse return;
    var index: usize = 0;
    while (tags[index]) |tag| : (index += 1) {
        if (tag.flags & exec.RTF_DEVICEINFO == 0 or tag.type != .device) continue;
        const device: *const exec.ResidentDevice = @ptrCast(tag);
        var is_class = false;
        var at: usize = 0;
        while (at < 16 and device.speaks[at] != 0) : (at += 1) {
            if (device.speaks[at] == devices.DEVIF_USBCLASS) is_class = true;
        }
        if (!is_class or drivers.count >= max_drivers) continue;
        const class: *const usbclass.ResidentUSBClass = @ptrCast(tag);
        const driver = &drivers.list[drivers.count];
        driver.* = .{};
        var length: usize = 0;
        while (tag.name[length] != 0) length += 1;
        if (driver_prefix.len + length + 1 > driver.name.len) continue;
        @memcpy(driver.name[0..driver_prefix.len], driver_prefix);
        @memcpy(driver.name[driver_prefix.len..][0..length], tag.name[0..length]);
        var count: u32 = 0;
        while (count < max_matches and class.matches[count].fields != 0) : (count += 1) driver.matches[count] = class.matches[count];
        driver.match_count = count;
        if (count != 0) drivers.count += 1;
    }
}

/// What a driver is opened by: its file's name after this.
const driver_prefix = "usb/";

/// The drivers in `DEVS:usb/` added to the table, once the drawer can be
/// read - which it cannot before the system's disk is known. Asked
/// without a requester for a volume that is not there. Under
/// `drivers_lock`, on a process.
pub fn readDisk(base: *UsbBase, drivers: *Drivers) void {
    if (drivers.disk_read) return;
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
    drivers.disk_read = true;
    var fib: dos.FileInfoBlock = .{};
    if (!dl.Examine(dir, &fib)) return;
    while (dl.ExNext(dir, &fib)) {
        if (dos.isDirectory(fib.dir_entry_type)) continue;
        if (drivers.count >= max_drivers) break;
        if (known(drivers, fileName(&fib))) continue;
        readDriver(base, &drivers.list[drivers.count], fileName(&fib)) catch continue;
        drivers.count += 1;
    }
}

/// Whether the table has a driver of this file's name already: the
/// ROM's.
fn known(drivers: *const Drivers, file_name: []const u8) bool {
    for (drivers.list[0..drivers.count]) |*driver| {
        const name = driver.name[driver_prefix.len..];
        var length: usize = 0;
        while (length < name.len and name[length] != 0) length += 1;
        if (length != file_name.len) continue;
        var same = true;
        for (name[0..length], file_name) |have, want| {
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

/// One file's tag into `driver`, if it is a class driver's.
fn readDriver(base: *UsbBase, driver: *Driver, file_name: []const u8) !void {
    const dl = base.dos.?;
    driver.* = .{};
    const prefix = driver_prefix;
    if (prefix.len + file_name.len + 1 > driver.name.len) return error.Name;
    @memcpy(driver.name[0..prefix.len], prefix);
    @memcpy(driver.name[prefix.len..][0..file_name.len], file_name);

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
    var is_class = false;
    var index: u32 = 0;
    while (index < 16) : (index += 1) {
        const set = loadfile.readWord(source, found, speaks_at + index * 4) orelse return error.Tag;
        if (set == 0) break;
        if (set == devices.DEVIF_USBCLASS) is_class = true;
    }
    if (!is_class) return error.NotClass;
    const matches_at = loadfile.readWord(source, found, found.tag + @offsetOf(usbclass.ResidentUSBClass, "matches")) orelse return error.Tag;
    var count: u32 = 0;
    while (count < max_matches) : (count += 1) {
        var entry: usbclass.USBMatch = .{};
        const bytes: *[@sizeOf(usbclass.USBMatch)]u8 = @ptrCast(&entry);
        if (!loadfile.readBytes(source, found, matches_at + count * @sizeOf(usbclass.USBMatch), bytes)) return error.Tag;
        if (entry.fields == 0) break;
        driver.matches[count] = entry;
    }
    driver.match_count = count;
    if (count == 0) return error.NoMatches;
}

/// The table let go of: at the expunge, when no bus runs and no driver is
/// open.
pub fn forget(base: *UsbBase) void {
    const found = base.drivers orelse return;
    base.sys_base.FreeMem(found, @sizeOf(Drivers));
    base.drivers = null;
}

/// Whether some driver's table has an entry an interface of this class,
/// subclass and protocol, on a device of this vendor and product,
/// matches: how a device's configuration is chosen. On a process.
pub fn anyTakes(base: *UsbBase, vendor_id: u16, product_id: u16, class: u8, subclass: u8, protocol: u8) bool {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.drivers_lock);
    defer sys.ReleaseSemaphore(&base.drivers_lock);
    const drivers = table(base) orelse return false;
    for (drivers.list[0..drivers.count]) |*driver| {
        for (driver.matches[0..driver.match_count]) |entry| {
            if (usbclass.matches(entry, vendor_id, product_id, class, subclass, protocol)) return true;
        }
    }
    return false;
}

/// A candidate: a driver and how specific its best entry for the
/// interface is.
const Candidate = struct { driver: *Driver, score: u32, priority: i8 };

/// `binding`'s interface offered to the drivers, most specific first:
/// the driver that took it, or null if none did. On the bus's process.
pub fn offer(base: *UsbBase, binding: *usb.USBBinding) ?*Driver {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.drivers_lock);
    defer sys.ReleaseSemaphore(&base.drivers_lock);
    const drivers = table(base) orelse return null;
    const device = binding.device.?;
    const interface = binding.interface.?;

    var candidates: [max_drivers]Candidate = undefined;
    var count: usize = 0;
    for (drivers.list[0..drivers.count]) |*driver| {
        var best: ?Candidate = null;
        for (driver.matches[0..driver.match_count]) |entry| {
            if (!usbclass.matches(entry, device.descriptor.vendor_id, device.descriptor.product_id, interface.interface_class, interface.interface_subclass, interface.interface_protocol)) continue;
            const candidate = Candidate{ .driver = driver, .score = usbclass.specificity(entry), .priority = entry.priority };
            if (best == null or better(candidate, best.?)) best = candidate;
        }
        if (best) |found| {
            candidates[count] = found;
            count += 1;
        }
    }
    // Most specific first: few candidates, so a plain insertion sort.
    var i: usize = 1;
    while (i < count) : (i += 1) {
        const item = candidates[i];
        var j = i;
        while (j > 0 and better(item, candidates[j - 1])) : (j -= 1) candidates[j] = candidates[j - 1];
        candidates[j] = item;
    }
    for (candidates[0..count]) |candidate| {
        const driver = candidate.driver;
        if (!openDriver(base, driver)) continue;
        const class_base: *UsbClassBase = @ptrCast(driver.io.device.?);
        if (class_base.USBClassBind(binding)) {
            driver.binds += 1;
            return driver;
        }
        closeIfIdle(base, driver);
    }
    return null;
}

fn better(a: Candidate, b: Candidate) bool {
    if (a.score != b.score) return a.score > b.score;
    return a.priority > b.priority;
}

/// The driver opened - loaded, if it is not - on its binding unit.
fn openDriver(base: *UsbBase, driver: *Driver) bool {
    if (driver.io.device != null) return true;
    driver.io = .{};
    driver.io.message.length = @sizeOf(exec.IORequest);
    if (base.sys_base.OpenDevice(@ptrCast(&driver.name), usbclass.USBCLASS_UNIT_BIND, &driver.io, 0) != 0) {
        driver.io.device = null;
        return false;
    }
    return true;
}

/// A driver that drives nothing closed, so it can be expunged.
fn closeIfIdle(base: *UsbBase, driver: *Driver) void {
    if (driver.binds != 0 or driver.io.device == null) return;
    base.sys_base.CloseDevice(&driver.io);
    driver.io.device = null;
}

/// A binding ended: the driver told, and closed if it drives nothing
/// more. On the bus's process.
pub fn unbind(base: *UsbBase, driver: *Driver, binding: *usb.USBBinding) void {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.drivers_lock);
    defer sys.ReleaseSemaphore(&base.drivers_lock);
    if (driver.io.device) |dev| {
        const class_base: *UsbClassBase = @ptrCast(dev);
        class_base.USBClassUnbind(binding);
    }
    if (driver.binds != 0) driver.binds -= 1;
    closeIfIdle(base, driver);
}
