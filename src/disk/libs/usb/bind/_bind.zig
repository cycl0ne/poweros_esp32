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
    if (base.drivers) |found| return @ptrCast(@alignCast(found));
    const sys = base.sys_base;
    const dl = base.dos orelse return null;
    // Kept in the library's base: the system's.
    const memory = sys.AllocMem(@sizeOf(Drivers), exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return null;
    const drivers: *Drivers = @ptrCast(@alignCast(memory));
    drivers.* = .{};
    base.drivers = drivers;

    const dir = dl.Lock(DRIVERS_DIR, dos.ACCESS_READ) orelse return drivers;
    defer dl.UnLock(dir);
    var fib: dos.FileInfoBlock = .{};
    if (!dl.Examine(dir, &fib)) return drivers;
    while (dl.ExNext(dir, &fib)) {
        if (fib.dir_entry_type >= 0) continue;
        if (drivers.count >= max_drivers) break;
        readDriver(base, &drivers.list[drivers.count], fileName(&fib)) catch continue;
        drivers.count += 1;
    }
    return drivers;
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
    const prefix = "usb/";
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
