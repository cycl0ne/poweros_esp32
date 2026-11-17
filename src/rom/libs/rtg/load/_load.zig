// SPDX-License-Identifier: MPL-2.0
//! Drivers from the disk: which file of `DEVS:gfxdrv/` is a driver's,
//! what it takes, and whether it is worth loading.
//!
//! A driver's file is a load file with the driver's ROM tag in it - one
//! of type `.rtg_driver`, the description behind it. The tag is read out
//! of the file (`describe`): its name, and its table of what it takes,
//! through the tag's pointers, which in a file are offsets into the
//! tag's own segment. Nothing is loaded for that and no code runs.
//!
//! A file is loaded only where it is a driver for a device of this
//! machine that no driver has (`wanted`): one whose table names such a
//! device, whose name no driver on the list has - the ROM's is the one
//! used - and whose device's settings line does not say `DRIVER=OFF`.
//!
//! **A driver that hangs** would hang every start. Before a file is
//! loaded its name is put in `ENVARC:Sys/display.trying` (`noteTrying`),
//! a name a line; `C:Rtg TRIED` takes the names of the drivers that came
//! back out of it once the desktop is up. A name found there when
//! drivers are loaded is a driver that did not come back from its last
//! try: it is passed over (`tried`).

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const dos = sdk.dos;
const loadfile = dos.loadfile;
const DosBase = sdk.interface.dos.DosBase;

const RtgBase = @import("../rtg.zig").RtgBase;
const devices = @import("../device/_device.zig");
const settings = @import("../settings/_settings.zig");

/// Where the drivers are, and the file that names those being tried.
pub const directory = "DEVS:gfxdrv";
pub const trying_file = "ENVARC:Sys/display.trying";

/// The most entries of a driver's table that are read, and the most
/// bytes of the file of names.
pub const matches_most = 16;
pub const trying_most = 1024;

/// What a driver's file says of itself.
pub const Described = struct {
    /// The driver's name, NUL-terminated.
    name: [rtg.drivers.RTG_NAME_MAX]u8 = @splat(0),
    /// RTGDT_*
    kind: u32 = 0,
    /// What it takes, and how many entries.
    matches: [matches_most]rtg.RtgMatch = @splat(.{}),
    count: u32 = 0,

    /// The name's characters.
    pub fn nameText(described: *const Described) []const u8 {
        var length: usize = 0;
        while (length < described.name.len and described.name[length] != 0) length += 1;
        return described.name[0..length];
    }
};

/// Every bit an entry's `fields` may have.
const match_fields = rtg.drivers.RTGMATCH_CHIP | rtg.drivers.RTGMATCH_BUS | rtg.drivers.RTGMATCH_VENDOR |
    rtg.drivers.RTGMATCH_DEVICE | rtg.drivers.RTGMATCH_CLASS;

/// A driver's description read out of its load file.
///
/// INPUTS:
/// - `source` - the file's bytes, by offset.
/// - `into` - takes the name, the kind and the table.
///
/// RESULT:
/// False for a file that is no load file for this machine, one with no
/// ROM tag or a tag of another type, a name that does not fit, and a
/// table that cannot be read whole or holds an entry no driver's has.
pub fn describe(source: loadfile.Source, into: *Described) bool {
    into.* = .{};
    const found = loadfile.findResident(source) orelse return false;
    var kind: [1]u8 = undefined;
    if (!loadfile.readBytes(source, found, found.tag + @offsetOf(exec.Resident, "type"), &kind)) return false;
    if (kind[0] != @intFromEnum(exec.NodeType.rtg_driver)) return false;

    const spec = found.tag + @offsetOf(rtg.ResidentRtgDriver, "spec");
    const name_at = loadfile.readWord(source, found, spec + @offsetOf(rtg.RtgDriverSpec, "name")) orelse return false;
    const name = loadfile.readString(source, found, name_at, &into.name) orelse return false;
    if (name.len == 0) return false;
    into.kind = loadfile.readWord(source, found, spec + @offsetOf(rtg.RtgDriverSpec, "kind")) orelse return false;

    const table_at = loadfile.readWord(source, found, spec + @offsetOf(rtg.RtgDriverSpec, "matches")) orelse return false;
    // A driver with no table takes nothing by itself.
    if (table_at == 0) return true;
    while (into.count < matches_most) : (into.count += 1) {
        const entry = &into.matches[into.count];
        const bytes: [*]u8 = @ptrCast(entry);
        if (!loadfile.readBytes(source, found, table_at + into.count * @sizeOf(rtg.RtgMatch), bytes[0..@sizeOf(rtg.RtgMatch)])) return false;
        if (entry.fields == 0) return true;
        if (entry.fields & ~@as(u32, match_fields) != 0) return false;
    }
    // A table longer than is read: what was read counts.
    return true;
}

/// Whether a driver so described is worth loading: no driver of its name
/// is on the list, and a device no driver has is one its table names and
/// its settings do not keep a driver from.
///
/// INPUTS:
/// - `rb` - the library; the device list's lock is held.
/// - `described` - the driver, as its file says it.
pub fn wanted(rb: *RtgBase, described: *const Described) bool {
    const sys = rb.sys_base;
    if (described.kind & rtg.drivers.RTGDT_BOARD == 0) return false;
    sys.ObtainSemaphore(&rb.driver_lock);
    const there = sys.FindName(&rb.drivers, @ptrCast(&described.name)) != null;
    sys.ReleaseSemaphore(&rb.driver_lock);
    if (there) return false;
    var node = rb.devices.first();
    while (node) |n| : (node = n.next()) {
        const device = devices.deviceOf(n);
        if (device.driver != null) continue;
        if (settings.driverOff(rb, device)) continue;
        for (described.matches[0..described.count]) |*entry| {
            if (devices.closeness(entry, device) != null) return true;
        }
    }
    return false;
}

/// Whether a name is one of those in the file of drivers being tried.
///
/// INPUTS:
/// - `names` - the file's text: a name a line.
/// - `name` - the driver's name.
pub fn tried(names: []const u8, name: []const u8) bool {
    var at: usize = 0;
    while (at < names.len) {
        var end = at;
        while (end < names.len and names[end] != '\n') end += 1;
        var line = names[at..end];
        if (line.len != 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        at = end + 1;
        if (line.len != name.len) continue;
        var same = true;
        for (line, name) |one, other| {
            if (one != other) same = false;
        }
        if (same) return true;
    }
    return false;
}

/// The file of drivers being tried, read into `into`; what it holds, and
/// nothing where there is no file.
///
/// INPUTS:
/// - `dl` - dos.library.
/// - `into` - takes the text.
pub fn readTrying(dl: *DosBase, into: []u8) []const u8 {
    const file = dl.Open(trying_file, dos.MODE_OLDFILE) orelse return into[0..0];
    defer _ = dl.Close(file);
    const got = dl.Read(file, into.ptr, @intCast(into.len));
    return into[0..if (got > 0) @intCast(got) else 0];
}

/// A driver's name put at the end of the file of drivers being tried,
/// before its file is loaded.
///
/// INPUTS:
/// - `dl` - dos.library.
/// - `before` - what the file held.
/// - `name` - the driver's name.
///
/// RESULT:
/// False where the file could not be written: the driver is then loaded
/// without the note, as on a disk that takes no writes.
pub fn noteTrying(dl: *DosBase, before: []const u8, name: []const u8) bool {
    const file = dl.Open(trying_file, dos.MODE_NEWFILE) orelse return false;
    var good = true;
    if (before.len != 0) good = dl.Write(file, before.ptr, @intCast(before.len)) == @as(isize, @intCast(before.len));
    if (before.len != 0 and before[before.len - 1] != '\n') good = dl.Write(file, "\n", 1) == 1 and good;
    good = dl.Write(file, name.ptr, @intCast(name.len)) == @as(isize, @intCast(name.len)) and good;
    good = dl.Write(file, "\n", 1) == 1 and good;
    return dl.Close(file) and good;
}

/// A file read through dos, by offset: what `describe` reads a driver's
/// tag out of.
pub const DosFile = struct {
    dl: *DosBase,
    file: *dos.FileHandle,

    /// The file as `loadfile` reads one.
    ///
    /// INPUTS:
    /// - `opened` - the file.
    pub fn source(opened: *DosFile) loadfile.Source {
        return .{ .context = opened, .readAt = readAt };
    }

    fn readAt(context: *anyopaque, offset: u32, into: []u8) bool {
        const opened: *DosFile = @ptrCast(@alignCast(context));
        if (opened.dl.Seek(opened.file, @intCast(offset), dos.OFFSET_BEGINNING) < 0) return false;
        return opened.dl.Read(opened.file, into.ptr, @intCast(into.len)) == @as(isize, @intCast(into.len));
    }
};

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const testing = fixture.testing;

test "a driver's file: its name and what it takes read out of it, nothing loaded" {
    const entries = [_]rtg.RtgMatch{
        .{ .fields = rtg.drivers.RTGMATCH_VENDOR | rtg.drivers.RTGMATCH_CLASS, .vendor = 0x1AF4, .class_code = 0x03_0000, .class_mask = 0xFF_0000, .priority = 3 },
        .{ .fields = rtg.drivers.RTGMATCH_CHIP, .chip = fixture.fake.chip },
    };
    var room: [1024]u8 = undefined;
    var file = loadfile.Bytes{ .data = fixture.driverFile(&room, "virtio", .rtg_driver, &entries) };
    var described: fixture.load.Described = .{};
    try testing.expect(fixture.load.describe(file.source(), &described));
    try testing.expectEqualStrings("virtio", described.nameText());
    try testing.expectEqual(rtg.drivers.RTGDT_BOARD, described.kind);
    try testing.expectEqual(@as(u32, 2), described.count);
    try testing.expectEqual(@as(u32, 0x1AF4), described.matches[0].vendor);
    try testing.expectEqual(@as(i32, 3), described.matches[0].priority);
    try testing.expectEqual(fixture.fake.chip, described.matches[1].chip);

    // A library's file is no driver's, nor is a file cut short, nor one
    // that is no load file.
    file.data = fixture.driverFile(&room, "some.library", .library, &entries);
    try testing.expect(!fixture.load.describe(file.source(), &described));
    const whole = fixture.driverFile(&room, "virtio", .rtg_driver, &entries);
    file.data = whole[0 .. whole.len - @sizeOf(rtg.RtgMatch) - 4];
    try testing.expect(!fixture.load.describe(file.source(), &described));
    file.data = "not a load file at all, whatever its name";
    try testing.expect(!fixture.load.describe(file.source(), &described));
    // An entry with a bit no driver's table has: bytes that are no table.
    const odd = [_]rtg.RtgMatch{.{ .fields = 1 << 20 }};
    file.data = fixture.driverFile(&room, "odd", .rtg_driver, &odd);
    try testing.expect(!fixture.load.describe(file.source(), &described));
}

test "a driver on the disk is wanted for a device no driver has, unless its name is taken or the device's line says no" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const sys = rb.sys_base;
    const takes = [_]rtg.RtgMatch{.{ .fields = rtg.drivers.RTGMATCH_CHIP, .chip = fixture.fake.chip }};
    var room: [1024]u8 = undefined;
    var file = sdk.dos.loadfile.Bytes{ .data = fixture.driverFile(&room, "other", .rtg_driver, &takes) };
    var described: fixture.load.Described = .{};
    try testing.expect(fixture.load.describe(file.source(), &described));

    // No device at all: nothing to load it for.
    sys.ObtainSemaphore(&rb.device_lock);
    try testing.expect(!fixture.load.wanted(rb, &described));
    sys.ReleaseSemaphore(&rb.device_lock);

    // A device the driver on the list declined.
    fk.create_answer = rtg.errors.RTGERR_NO_DISPLAY;
    const device = fixture.fake.addDevice(fk, null).?;
    try testing.expect(device.driver == null);
    sys.ObtainSemaphore(&rb.device_lock);
    try testing.expect(fixture.load.wanted(rb, &described));
    sys.ReleaseSemaphore(&rb.device_lock);

    // The name of a driver that is on the list: the one there is used.
    var named: fixture.load.Described = .{};
    file.data = fixture.driverFile(&room, fixture.fake.DRIVER_NAME, .rtg_driver, &takes);
    try testing.expect(fixture.load.describe(file.source(), &named));
    sys.ObtainSemaphore(&rb.device_lock);
    try testing.expect(!fixture.load.wanted(rb, &named));
    sys.ReleaseSemaphore(&rb.device_lock);

    // A table that names another chip.
    const elsewhere = [_]rtg.RtgMatch{.{ .fields = rtg.drivers.RTGMATCH_CHIP, .chip = fixture.fake.chip + 1 }};
    var stranger: fixture.load.Described = .{};
    file.data = fixture.driverFile(&room, "stranger", .rtg_driver, &elsewhere);
    try testing.expect(fixture.load.describe(file.source(), &stranger));
    sys.ObtainSemaphore(&rb.device_lock);
    try testing.expect(!fixture.load.wanted(rb, &stranger));
    sys.ReleaseSemaphore(&rb.device_lock);

    // The device's line keeps drivers from the disk off it.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetRtgDeviceDriver("panel.0", false));
    sys.ObtainSemaphore(&rb.device_lock);
    try testing.expect(!fixture.load.wanted(rb, &described));
    sys.ReleaseSemaphore(&rb.device_lock);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetRtgDeviceDriver("panel.0", true));

    // A device a driver has is nobody else's.
    fk.create_answer = rtg.errors.RTGERR_OK;
    try testing.expectEqual(@as(u32, 1), fixture.base(rb).BindRtgDrivers());
    sys.ObtainSemaphore(&rb.device_lock);
    try testing.expect(!fixture.load.wanted(rb, &described));
    sys.ReleaseSemaphore(&rb.device_lock);

    // The file of drivers being tried: a name a line.
    try testing.expect(fixture.load.tried("virtio\namd\r\n", "amd"));
    try testing.expect(fixture.load.tried("virtio\namd", "virtio"));
    try testing.expect(!fixture.load.tried("virtio\namd\n", "am"));
    try testing.expect(!fixture.load.tried("", "amd"));
    try fixture.tearDown(rb);
}
