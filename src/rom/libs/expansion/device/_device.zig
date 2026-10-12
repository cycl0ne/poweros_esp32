// SPDX-License-Identifier: MPL-2.0
//! What ObtainDeviceUnits gathers. Every device that says what it speaks
//! (`ResidentDevice`, RTF_DEVICEINFO) is first a `Record`: the ROM's tags
//! read where they are (ResModules), and the files in DEVS: and its
//! drawers but `handlers` read for theirs (loadfile.readDevice) - nothing
//! opened, loaded or started. A device both in the ROM and on the disk is
//! one record, the higher version's. The records, sorted by name, then
//! become a node per unit: one per board part of the device's part kind,
//! or as many as it counts.
//!
//! The records are gathered in one block of their own, freed before the
//! list is answered; each node is one allocation with its command sets,
//! its name and its label behind it, so ReleaseDeviceUnits frees a node
//! with one FreeVec.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const loadfile = dos.loadfile;
const expansion = sdk.expansion;
const st = expansion.systemtags;
const devices = expansion.devices;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const ExpansionBase = @import("../expansion_base.zig").ExpansionBase;

/// The most devices one call lists, and labels and units one device has.
pub const max_devices = 48;
pub const max_labels = 8;
pub const max_units = 32;
const label_bytes = 32;

/// Where the devices on the disk are, and the drawer of it that holds
/// none.
const DEVS = "DEVS:";
const handlers_drawer = "handlers";

/// A device that says what it speaks, as gathered.
pub const Record = struct {
    /// What OpenDevice takes.
    name: [48:0]u8 = @splat(0),
    /// The tag's own name: one device in two places has it twice.
    tag_name: [32:0]u8 = @splat(0),
    version: u16 = 0,
    revision: u16 = 0,
    flags: u32 = 0,
    /// DEVIF_*, ended by 0.
    speaks: [loadfile.max_speaks + 1]u32 = @splat(0),
    unit_part: u32 = 0,
    units: u32 = 0,
    /// Each counted unit's label; empty for none.
    labels: [max_labels][label_bytes:0]u8 = @splat(@splat(0)),
};

/// The records of one call, and the room it reads directories with.
pub const Gathered = struct {
    count: u32 = 0,
    list: [max_devices]Record = undefined,
    fib: dos.FileInfoBlock = .{},
    drawer_fib: dos.FileInfoBlock = .{},
};

/// Whether a device that speaks `speaks` (ended by 0) is one asked for:
/// `wanted` among them, or `wanted` 0.
pub fn speaksAny(speaks: []const u32, wanted: u32) bool {
    if (wanted == 0) return true;
    for (speaks) |set| {
        if (set == 0) return false;
        if (set == wanted) return true;
    }
    return false;
}

/// `record` added, unless a device of its tag name is already there: then
/// whichever has the higher version and revision is kept. Past
/// `max_devices`, the rest are left out.
pub fn add(gathered: *Gathered, record: *const Record) void {
    for (gathered.list[0..gathered.count]) |*kept| {
        if (!sameName(&kept.tag_name, &record.tag_name)) continue;
        if (newer(record, kept)) kept.* = record.*;
        return;
    }
    if (gathered.count == max_devices) return;
    gathered.list[gathered.count] = record.*;
    gathered.count += 1;
}

/// Whether `a` is a later version than `b`.
pub fn newer(a: *const Record, b: *const Record) bool {
    if (a.version != b.version) return a.version > b.version;
    return a.revision > b.revision;
}

/// The records in order of their names, for a listing that does not
/// change from one call to the next.
pub fn sortByName(gathered: *Gathered) void {
    const list = gathered.list[0..gathered.count];
    var index: usize = 1;
    while (index < list.len) : (index += 1) {
        const moving = list[index];
        var at = index;
        while (at > 0 and before(&moving.name, &list[at - 1].name)) : (at -= 1) list[at] = list[at - 1];
        list[at] = moving;
    }
}

// --- the ROM ---------------------------------------------------------------------

/// Every device of the ROM's that speaks `wanted`, added.
pub fn fromRom(sys: *ExecBase, gathered: *Gathered, wanted: u32) void {
    const table = sys.ResModules() orelse return;
    var index: usize = 0;
    while (table[index]) |tag| : (index += 1) {
        if (tag.flags & exec.RTF_DEVICEINFO == 0 or tag.type != .device) continue;
        const device: *const exec.ResidentDevice = @ptrCast(tag);
        var record: Record = .{ .flags = devices.DUF_ROM, .version = tag.version };
        copyString(&record.name, tag.name);
        copyString(&record.tag_name, tag.name);
        if (tag.id_string) |id| record.revision = exec.resident.revisionOf(id[0..length(id)]);
        var count: usize = 0;
        while (count < loadfile.max_speaks and device.speaks[count] != 0) : (count += 1) record.speaks[count] = device.speaks[count];
        if (!speaksAny(&record.speaks, wanted)) continue;
        record.unit_part = device.unit_part;
        record.units = @min(device.units, max_units);
        if (device.unit_labels) |labels| {
            for (record.labels[0..@min(record.units, max_labels)], 0..) |*into, unit| copyString(into, labels[unit]);
        }
        add(gathered, &record);
    }
}

// --- the disk --------------------------------------------------------------------

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

/// Every device in DEVS: and its drawers but `handlers` that speaks
/// `wanted`, added. On a process; nothing at all without dos.library or
/// DEVS:.
pub fn fromDisk(sys: *ExecBase, gathered: *Gathered, wanted: u32) void {
    const library = sys.OpenLibrary(dos.DOSNAME, 0) orelse return;
    defer sys.CloseLibrary(library);
    const dl: *DosBase = @ptrCast(library);
    const top = dl.Lock(DEVS, dos.ACCESS_READ) orelse return;
    defer dl.UnLock(top);
    if (!dl.Examine(top, &gathered.fib)) return;
    while (dl.ExNext(top, &gathered.fib)) {
        const entry = nameOf(&gathered.fib);
        if (gathered.fib.dir_entry_type < 0) {
            readFile(dl, gathered, "", entry, wanted);
        } else if (!equalFolded(entry, handlers_drawer)) {
            fromDrawer(dl, gathered, entry, wanted);
        }
    }
}

/// The files of the drawer DEVS:`drawer`.
fn fromDrawer(dl: *DosBase, gathered: *Gathered, drawer: []const u8, wanted: u32) void {
    var path: [64:0]u8 = @splat(0);
    if (!join(&path, &.{ DEVS, drawer })) return;
    const lock = dl.Lock(&path, dos.ACCESS_READ) orelse return;
    defer dl.UnLock(lock);
    const fib = &gathered.drawer_fib;
    if (!dl.Examine(lock, fib)) return;
    while (dl.ExNext(lock, fib)) {
        if (fib.dir_entry_type >= 0) continue;
        readFile(dl, gathered, drawer, nameOf(fib), wanted);
    }
}

/// The file `file` of DEVS:`drawer` read for its device tag, and added
/// if it is a device that speaks `wanted`.
fn readFile(dl: *DosBase, gathered: *Gathered, drawer: []const u8, file: []const u8, wanted: u32) void {
    var record: Record = .{};
    const slash: []const u8 = if (drawer.len != 0) "/" else "";
    if (!join(&record.name, &.{ drawer, slash, file })) return;
    var path: [80:0]u8 = @splat(0);
    if (!join(&path, &.{ DEVS, &record.name })) return;
    const handle = dl.Open(&path, dos.MODE_OLDFILE) orelse return;
    defer _ = dl.Close(handle);
    var reader = DosFile{ .dl = dl, .file = handle };
    const source = loadfile.Source{ .context = &reader, .readAt = DosFile.readAt };
    const found = loadfile.findResident(source) orelse return;
    var tag: loadfile.DeviceTag = .{};
    if (!loadfile.readDevice(source, found, &tag)) return;
    if (!speaksAny(&tag.speaks, wanted)) return;
    copyString(&record.tag_name, &tag.name);
    record.version = tag.version;
    record.revision = tag.revision;
    record.speaks = tag.speaks;
    record.unit_part = tag.unit_part;
    record.units = @min(tag.units, max_units);
    for (record.labels[0..@min(record.units, max_labels)], 0..) |*into, unit| {
        _ = loadfile.readUnitLabel(source, found, &tag, @intCast(unit), into[0..into.len]);
    }
    add(gathered, &record);
}

// --- the nodes -------------------------------------------------------------------

/// A node for each unit of each record onto `list`: false without the
/// memory for one, the nodes made so far left on the list for the caller
/// to give back.
pub fn makeUnits(eb: *ExpansionBase, gathered: *Gathered, list: *exec.List) bool {
    const self: *sdk.interface.expansion.ExpansionBase = @ptrCast(eb);
    const ub = eb.utility_base;
    for (gathered.list[0..gathered.count]) |*record| {
        if (record.unit_part == 0) {
            var unit: u32 = 0;
            while (unit < record.units) : (unit += 1) {
                const label: ?[*:0]const u8 = if (unit < max_labels and record.labels[unit][0] != 0) &record.labels[unit] else null;
                if (!addUnit(eb.sys_base, list, record, unit, label)) return false;
            }
            continue;
        }
        var part = self.FindBoardPart(null, record.unit_part, st.CHIP_ANY);
        while (part) |it| : (part = self.FindBoardPart(it, record.unit_part, st.CHIP_ANY)) {
            const unit: u32 = @intCast(ub.GetTagData(st.PART_BusUnit, it.unit, it.tags));
            const label: ?[*:0]const u8 = @ptrFromInt(ub.GetTagData(st.PART_Label, 0, it.tags));
            if (!addUnit(eb.sys_base, list, record, unit, label)) return false;
        }
    }
    return true;
}

/// One unit's node, its command sets, name and label behind it in the
/// same allocation, onto the end of `list`.
fn addUnit(sys: *ExecBase, list: *exec.List, record: *const Record, unit: u32, label: ?[*:0]const u8) bool {
    var sets: usize = 0;
    while (record.speaks[sets] != 0) sets += 1;
    const name_length = length(&record.name);
    const label_length = if (label) |text| length(text) else 0;
    const speaks_bytes = (sets + 1) * @sizeOf(u32);
    const size = @sizeOf(devices.DeviceUnit) + speaks_bytes + name_length + 1 + label_length + 1;
    const memory = sys.AllocVec(size, exec.MEMF_CLEAR) orelse return false;
    const bytes: [*]u8 = @ptrCast(memory);
    const node: *devices.DeviceUnit = @ptrCast(@alignCast(memory));
    const speaks: [*]u32 = @ptrCast(@alignCast(bytes + @sizeOf(devices.DeviceUnit)));
    for (record.speaks[0 .. sets + 1], 0..) |set, index| speaks[index] = set;
    const name = bytes + @sizeOf(devices.DeviceUnit) + speaks_bytes;
    for (record.name[0..name_length], 0..) |char, index| name[index] = char;
    const label_copy = name + name_length + 1;
    if (label) |text| {
        for (text[0..label_length], 0..) |char, index| label_copy[index] = char;
    }
    node.* = .{
        .node = .{ .name = @ptrCast(name) },
        .unit = unit,
        .label = if (label != null) @ptrCast(label_copy) else null,
        .version = record.version,
        .revision = record.revision,
        .speaks = speaks,
        .flags = record.flags,
    };
    sys.AddTail(list, &node.node);
    return true;
}

// --- names -----------------------------------------------------------------------

fn length(text: [*:0]const u8) usize {
    var count: usize = 0;
    while (text[count] != 0) count += 1;
    return count;
}

/// `from` into `into`, cut to fit, NUL-ended within it.
fn copyString(into: anytype, from: [*:0]const u8) void {
    var count: usize = 0;
    while (count + 1 < into.len and from[count] != 0) : (count += 1) into[count] = from[count];
    into[count] = 0;
}

/// `parts` one after another into `into`, NUL-ended; false if they do not
/// fit.
fn join(into: anytype, parts: []const []const u8) bool {
    var at: usize = 0;
    for (parts) |part| {
        for (part) |char| {
            if (char == 0) break;
            if (at + 1 >= into.len) return false;
            into[at] = char;
            at += 1;
        }
    }
    into[at] = 0;
    return true;
}

fn nameOf(fib: *const dos.FileInfoBlock) []const u8 {
    var count: usize = 0;
    while (count < fib.file_name.len and fib.file_name[count] != 0) count += 1;
    return fib.file_name[0..count];
}

fn sameName(a: [*:0]const u8, b: [*:0]const u8) bool {
    var index: usize = 0;
    while (a[index] == b[index]) : (index += 1) {
        if (a[index] == 0) return true;
    }
    return false;
}

/// Whether `a` sorts before `b`, letter case aside.
fn before(a: [*:0]const u8, b: [*:0]const u8) bool {
    var index: usize = 0;
    while (true) : (index += 1) {
        const x = lower(a[index]);
        const y = lower(b[index]);
        if (x != y) return x < y;
        if (x == 0) return false;
    }
}

fn equalFolded(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (lower(x) != lower(y)) return false;
    }
    return true;
}

fn lower(char: u8) u8 {
    return if (char >= 'A' and char <= 'Z') char + ('a' - 'A') else char;
}
