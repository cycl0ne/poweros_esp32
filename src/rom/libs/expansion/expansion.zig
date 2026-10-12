// SPDX-License-Identifier: MPL-2.0
//! expansion.library: the board this machine is, and the parts soldered on
//! it.
//!
//! The board is described, not discovered - a pad cannot say what it is
//! wired to - so each board's ROM carries a description: the system tag
//! list (sdk/libs/expansion/systemtags.zig), in a ROM tag named "system"
//! of type `.board`. At start this library finds that tag, and for each
//! SYSTAG_Part in the list makes a BoardPart: its kind, its chip, which
//! one of its kind it is, and the part's own tags. A module asks for its
//! part with FindBoardPart and reads the rest from the tags; it carries no
//! board facts of its own.
//!
//! A program finds the devices of a kind - every serial line, every block
//! device - with ObtainDeviceUnits: the devices whose ROM tag says they
//! speak that command set, in the ROM and in DEVS:, each with its units on
//! this board, none of them opened or loaded (`device/`).
//!
//! A disk's driver starts before dos.library, so it cannot put its
//! partitions on dos's list itself: it makes a device node for each with
//! MakeDosNode and hands it over with AddBootNode, and this library keeps
//! the nodes until dos's init takes them with EnterBootNodes. From then on
//! a node goes straight onto dos's list.
//!
//! Each call is a file of its own, under `part/` for the board, `boot/`
//! for the disks and `device/` for the devices. The jump table is
//! expansion_lvo.zig, the ROM tag and init expansion_init.zig, the base
//! expansion_base.zig. This file holds the names the rest of the kernel
//! reaches the library by, and the tests of it working as a whole.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const expansion = sdk.expansion;
const st = expansion.systemtags;
const pins = expansion.boardpin;

const expansion_base = @import("expansion_base.zig");
const expansion_init = @import("expansion_init.zig");

// The tag is an export in .resident, found there by its address; this
// keeps it in whatever is built from expansion.library.
comptime {
    _ = &expansion_init.expansion_library_tag;
}

/// The library's base.
pub const ExpansionBase = expansion_base.ExpansionBase;
/// What the library is on exec's list as.
pub const LIBRARY_NAME = expansion_init.LIBRARY_NAME;
/// The ROM tag, for the host tests that make the library from it.
pub const expansion_library_tag = expansion_init.expansion_library_tag;

// --- tests ------------------------------------------------------------------------

const testing = std.testing;
const kexec = @import("../exec/exec.zig");
const kutility = @import("../utility/utility.zig");
const kdos = @import("../dos/dos.zig");
const FindBoardPart = @import("part/findboardpart.zig").FindBoardPart;
const SystemTags = @import("part/systemtags.zig").SystemTags;
const MakeDosNode = @import("boot/makedosnode.zig").MakeDosNode;
const AddBootNode = @import("boot/addbootnode.zig").AddBootNode;
const EnterBootNodes = @import("boot/enterbootnodes.zig").EnterBootNodes;
const BootNode = @import("boot/_boot.zig").BootNode;
const ObtainDeviceUnits = @import("device/obtaindeviceunits.zig").ObtainDeviceUnits;
const ReleaseDeviceUnits = @import("device/releasedeviceunits.zig").ReleaseDeviceUnits;
const _device = @import("device/_device.zig");
const dos = sdk.dos;
const loadfile = dos.loadfile;
const devices = expansion.devices;

test {
    _ = expansion_base;
    _ = expansion_init;
    _ = @import("expansion_lvo.zig");
    _ = @import("part/findboardpart.zig");
    _ = @import("part/systemtags.zig");
    _ = @import("boot/_boot.zig");
    _ = @import("boot/makedosnode.zig");
    _ = @import("boot/addbootnode.zig");
    _ = @import("boot/enterbootnodes.zig");
    _ = @import("device/obtaindeviceunits.zig");
    _ = @import("device/releasedeviceunits.zig");
}

const TagItem = utility.TagItem;

// A board to test against: two I2C buses, a touch chip on the first, a
// card slot, and a part with no chip name of its own.
const bus0 = [_]TagItem{
    .{ .tag = st.PART_Kind, .data = st.PARTKIND_I2CBUS },
    .{ .tag = st.PART_PinSCL, .data = pins.gpio(9) },
    .{ .tag = st.PART_PinSDA, .data = pins.gpio(8) },
    .{ .tag = st.PART_Label, .data = 0 }, // replaced below
    .{ .tag = utility.TAG_DONE, .data = 0 },
};
const bus1 = [_]TagItem{
    .{ .tag = st.PART_Kind, .data = st.PARTKIND_I2CBUS },
    .{ .tag = st.PART_BusUnit, .data = 2 },
    .{ .tag = utility.TAG_DONE, .data = 0 },
};

// Devices in the test ROM: one whose units are the board's I2C buses, one
// that counts its units and names them, one that says nothing of what it
// speaks.
const bus_speaks = [_]u32{ devices.DEVIF_STREAM, devices.DEVIF_I2C, 0 };
const test_bus_device: exec.ResidentDevice = .{
    .resident = .{
        .match_tag = @ptrCast(&test_bus_device),
        .flags = exec.RTF_DEVICEINFO,
        .version = 3,
        .type = .device,
        .name = "test-bus.device",
        .id_string = "test-bus.device 3.4 (12.10.2026)\r\n",
    },
    .speaks = &bus_speaks,
    .unit_part = st.PARTKIND_I2CBUS,
};
const clock_speaks = [_]u32{ devices.DEVIF_TIMER, 0 };
const clock_labels = [_][*:0]const u8{ "fast", "slow", "wall" };
const test_clock_device: exec.ResidentDevice = .{
    .resident = .{
        .match_tag = @ptrCast(&test_clock_device),
        .flags = exec.RTF_DEVICEINFO,
        .version = 1,
        .type = .device,
        .name = "test-clock.device",
    },
    .speaks = &clock_speaks,
    .units = 3,
    .unit_labels = &clock_labels,
};
const touch_speaks = [_]u32{ devices.DEVIF_TOUCH, 0 };
const test_touch_device: exec.ResidentDevice = .{
    .resident = .{
        .match_tag = @ptrCast(&test_touch_device),
        .flags = exec.RTF_DEVICEINFO,
        .version = 1,
        .type = .device,
        .name = "test-touch.device",
    },
    .speaks = &touch_speaks,
    .unit_part = st.PARTKIND_TOUCH,
    .unit_chip = st.CHIP_GT911,
};
const other_touch_device: exec.ResidentDevice = .{
    .resident = .{
        .match_tag = @ptrCast(&other_touch_device),
        .flags = exec.RTF_DEVICEINFO,
        .version = 1,
        .type = .device,
        .name = "other-touch.device",
    },
    .speaks = &touch_speaks,
    .unit_part = st.PARTKIND_TOUCH,
    .unit_chip = st.CHIP_ST7123,
};
const test_plain_device: exec.Resident = .{
    .match_tag = &test_plain_device,
    .version = 1,
    .type = .device,
    .name = "test-plain.device",
};
const touch = [_]TagItem{
    .{ .tag = st.PART_Kind, .data = st.PARTKIND_TOUCH },
    .{ .tag = st.PART_Chip, .data = st.CHIP_GT911 },
    .{ .tag = st.PART_ChipName, .data = 0 }, // replaced below: a pointer is not comptime data here
    .{ .tag = st.PART_Address, .data = 0x5D },
    .{ .tag = st.PART_PinReset, .data = pins.expander(1) },
    .{ .tag = utility.TAG_DONE, .data = 0 },
};
const slot = [_]TagItem{
    .{ .tag = st.PART_Kind, .data = st.PARTKIND_SDSLOT },
    .{ .tag = st.PART_PinClock, .data = pins.gpio(5) },
    .{ .tag = utility.TAG_DONE, .data = 0 },
};

/// The system tag list and the ROM tag carrying it, made at run time so
/// they can hold pointers.
const Board = struct {
    touch: [touch.len]TagItem = touch,
    root: [8]TagItem = undefined,
    resident: exec.Resident = undefined,
    bus0: [bus0.len]TagItem = bus0,
    table: [7]?*const exec.Resident = undefined,

    fn build(board: *Board) void {
        board.touch[2].data = @intFromPtr("gt911");
        board.root = .{
            .{ .tag = st.SYSTAG_Name, .data = @intFromPtr("Test board") },
            .{ .tag = st.SYSTAG_Console, .data = st.CONSOLE_USBJTAG },
            .{ .tag = st.SYSTAG_Part, .data = @intFromPtr(&board.bus0) },
            .{ .tag = st.SYSTAG_Part, .data = @intFromPtr(&board.touch) },
            .{ .tag = st.SYSTAG_Part, .data = @intFromPtr(&bus1) },
            .{ .tag = st.SYSTAG_Part, .data = @intFromPtr(&slot) },
            .{ .tag = utility.TAG_DONE, .data = 0 },
            .{ .tag = utility.TAG_DONE, .data = 0 },
        };
        board.resident = .{
            .match_tag = &board.resident,
            .type = .board,
            .name = expansion.SYSTEM_RESIDENT,
            .init = &board.root,
        };
        board.bus0[3].data = @intFromPtr("header P3");
        board.table = .{ &board.resident, &test_bus_device.resident, &test_clock_device.resident, &test_touch_device.resident, &other_touch_device.resident, &test_plain_device, null };
    }
};

/// exec, utility.library and expansion.library, the latter started on
/// `board` - or on no board at all.
fn setUp(board: ?*Board) !*ExpansionBase {
    try kexec.setUp();
    _ = kexec.InitResident(kexec.SysBase, &kutility.utility_library_tag, null) orelse return error.NoUtility;
    if (board) |it| {
        it.build();
        kexec.SysBase.res_modules = &it.table;
    }
    const made = kexec.InitResident(kexec.SysBase, &expansion_library_tag, null) orelse return error.NoExpansion;
    return @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(made))));
}

/// expansion.library's own share taken down - its utility.library opening
/// closed, its parts and its base freed - leaving utility.library and the
/// leak check to whoever takes down the rest.
fn takeDown(eb: *ExpansionBase) *kutility.UtilityBase {
    kexec.SysBase.res_modules = null;
    if (eb.parts) |parts| kexec.FreeMem(kexec.SysBase, @ptrCast(parts), eb.part_count * @sizeOf(expansion.BoardPart));
    const ub: *kutility.UtilityBase = @ptrCast(@alignCast(eb.utility_base));
    _ = kexec.CloseLibrary(kexec.SysBase, &ub.lib);
    kexec.Remove(kexec.SysBase, &eb.lib.node);
    kexec.freeLibraryMemory(kexec.SysBase, &eb.lib);
    return ub;
}

fn tearDown(eb: *ExpansionBase) !void {
    kutility.freeForTests(takeDown(eb));
    try kexec.expectNoLeaks();
}

test "every part of the board, in the board's order" {
    var board: Board = .{};
    const eb = try setUp(&board);
    defer kexec.deinit();

    try testing.expectEqual(@as(u32, 4), eb.part_count);
    var names: [4][]const u8 = undefined;
    var count: usize = 0;
    var part = FindBoardPart(eb, null, st.PARTKIND_ANY, st.CHIP_ANY);
    while (part) |it| : (part = FindBoardPart(eb, it, st.PARTKIND_ANY, st.CHIP_ANY)) {
        names[count] = std.mem.span(it.node.name.?);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 4), count);
    // A part without a chip name goes by its kind's.
    try testing.expectEqualStrings("i2cbus", names[0]);
    try testing.expectEqualStrings("gt911", names[1]);
    try testing.expectEqualStrings("i2cbus", names[2]);
    try testing.expectEqualStrings("sdslot", names[3]);
    try tearDown(eb);
}

test "parts of one kind are numbered in order, and found one after another" {
    var board: Board = .{};
    const eb = try setUp(&board);
    defer kexec.deinit();

    const first = FindBoardPart(eb, null, st.PARTKIND_I2CBUS, st.CHIP_ANY).?;
    const second = FindBoardPart(eb, first, st.PARTKIND_I2CBUS, st.CHIP_ANY).?;
    try testing.expectEqual(@as(u32, 0), first.unit);
    try testing.expectEqual(@as(u32, 1), second.unit);
    try testing.expectEqual(@as(?*const expansion.BoardPart, null), FindBoardPart(eb, second, st.PARTKIND_I2CBUS, st.CHIP_ANY));
    try tearDown(eb);
}

test "a part is found by its chip, and its facts are in its tags" {
    var board: Board = .{};
    const eb = try setUp(&board);
    defer kexec.deinit();
    const ub: *sdk.interface.utility.UtilityBase = eb.utility_base;

    const found = FindBoardPart(eb, null, st.PARTKIND_ANY, st.CHIP_GT911).?;
    try testing.expectEqual(st.PARTKIND_TOUCH, found.kind);
    try testing.expectEqual(@as(usize, 0x5D), ub.GetTagData(st.PART_Address, 0, found.tags));
    const reset = expansion.BoardPin.of(ub.GetTagData(st.PART_PinReset, 0, found.tags));
    try testing.expectEqual(pins.BPIN_EXPANDER, reset.kind);
    try testing.expectEqual(@as(u8, 1), reset.number);
    // A line the part does not have is no line.
    try testing.expect(!expansion.BoardPin.of(ub.GetTagData(st.PART_PinInt, 0, found.tags)).wired());
    // A kind the board has none of, and a chip it has none of.
    try testing.expectEqual(@as(?*const expansion.BoardPart, null), FindBoardPart(eb, null, st.PARTKIND_CODEC, st.CHIP_ANY));
    try testing.expectEqual(@as(?*const expansion.BoardPart, null), FindBoardPart(eb, null, st.PARTKIND_TOUCH, st.CHIP_ST7123));
    try tearDown(eb);
}

test "the board's own facts come from the root list" {
    var board: Board = .{};
    const eb = try setUp(&board);
    defer kexec.deinit();
    const ub: *sdk.interface.utility.UtilityBase = eb.utility_base;
    const root = SystemTags(eb);
    const name: [*:0]const u8 = @ptrFromInt(ub.GetTagData(st.SYSTAG_Name, 0, root));
    try testing.expectEqualStrings("Test board", std.mem.span(name));
    try testing.expectEqual(st.CONSOLE_USBJTAG, ub.GetTagData(st.SYSTAG_Console, st.CONSOLE_UART0, root));
    try tearDown(eb);
}

test "a ROM without a system tag list is a board with no parts" {
    const eb = try setUp(null);
    defer kexec.deinit();
    try testing.expectEqual(@as(u32, 0), eb.part_count);
    try testing.expectEqual(@as(?*const expansion.BoardPart, null), FindBoardPart(eb, null, st.PARTKIND_ANY, st.CHIP_ANY));
    try testing.expectEqual(utility.TAG_DONE, SystemTags(eb)[0].tag);
    try tearDown(eb);
}

/// A partition's environment as the tests hand it over.
const test_environ: dos.DosEnvec = .{ .size_block = 4096, .low_cyl = 16, .high_cyl = 3583, .boot_pri = 2 };

/// The node of `name` on dos's device list, or null.
fn findDevice(db: *kdos.DosBase, name: [*:0]const u8) ?*dos.DosList {
    const dl = kdos.testBase(db);
    const list = dl.LockDosList(dos.LDF_DEVICES | dos.LDF_ASSIGNS | dos.LDF_READ) orelse return null;
    defer dl.UnLockDosList(dos.LDF_DEVICES | dos.LDF_ASSIGNS | dos.LDF_READ);
    return dl.FindDosEntry(list, name, dos.LDF_DEVICES | dos.LDF_ASSIGNS);
}

test "MakeDosNode: the node, its startup message and its environment in one allocation" {
    const eb = try setUp(null);
    defer kexec.deinit();
    const node = MakeDosNode(eb, "DH0", "flash.device", 0, 7, &test_environ).?;
    try testing.expect(node.type == .device);
    try testing.expectEqualStrings("DH0", std.mem.span(node.name));
    const startup: *const dos.FileSysStartupMsg = @ptrFromInt(node.misc.handler.startup);
    try testing.expectEqualStrings("flash.device", std.mem.span(startup.device.?));
    try testing.expectEqual(@as(u32, 0), startup.unit);
    try testing.expectEqual(@as(u32, 7), startup.flags);
    // A copy, inside the node's allocation: the caller's may go.
    try testing.expect(startup.environ.? != &test_environ);
    try testing.expectEqual(@as(u32, 3583), startup.environ.?.high_cyl);
    // No handler named yet; the stack and priority a file system gets.
    try testing.expectEqual(@as(?[*:0]const u8, null), node.misc.handler.handler);
    try testing.expectEqual(@as(u32, 16 * 1024), node.misc.handler.stack_size);
    // One allocation: FreeVec takes all of it, as FreeDosEntry would.
    kexec.FreeVec(kexec.SysBase, node);
    try tearDown(eb);
}

test "AddBootNode before dos.library: the nodes are kept, highest boot priority first" {
    const eb = try setUp(null);
    defer kexec.deinit();
    const names = [_][*:0]const u8{ "DH0", "DH1", "DH2" };
    const priorities = [_]i32{ -128, 0, 3 };
    for (names, priorities) |name, pri| {
        try testing.expect(AddBootNode(eb, pri, MakeDosNode(eb, name, "flash.device", 0, 0, &test_environ).?));
    }
    const expected = [_][]const u8{ "DH2", "DH1", "DH0" };
    var count: usize = 0;
    var it = eb.boot_nodes.iterator();
    while (it.next()) |node| : (count += 1) try testing.expectEqualStrings(expected[count], std.mem.span(node.name.?));
    try testing.expectEqual(expected.len, count);
    // Without dos nothing takes them: EnterBootNodes leaves them kept.
    try testing.expectEqual(@as(?*dos.DosList, null), EnterBootNodes(eb));
    try testing.expect(!eb.boot_nodes.isEmpty());
    while (kexec.RemHead(kexec.SysBase, &eb.boot_nodes)) |head| {
        const waiting: *BootNode = @fieldParentPtr("node", head);
        kexec.FreeVec(kexec.SysBase, waiting.device_node);
        kexec.FreeVec(kexec.SysBase, waiting);
    }
    try tearDown(eb);
}

test "dos.library takes the kept nodes in at its start, and boots from the highest bootable" {
    const eb = try setUp(null);
    defer kexec.deinit();
    // DH1 twice: dos takes the first, and the second is freed. No handler
    // is named, so nothing is started when the boot shell looks at SYS:.
    const kept = [_]struct { name: [*:0]const u8, pri: i32 }{
        .{ .name = "DH0", .pri = -128 },
        .{ .name = "DH1", .pri = 0 },
        .{ .name = "DH2", .pri = 3 },
        .{ .name = "DH1", .pri = -5 },
    };
    for (kept) |entry| try testing.expect(AddBootNode(eb, entry.pri, MakeDosNode(eb, entry.name, "flash.device", 0, 0, &test_environ).?));

    const made = kexec.InitResident(kexec.SysBase, &kdos.dos_library_tag, null) orelse return error.NoDos;
    const db: *kdos.DosBase = @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(made))));
    try testing.expect(eb.boot_nodes.isEmpty());
    for ([_][*:0]const u8{ "DH0", "DH1", "DH2" }) |name| try testing.expect(findDevice(db, name) != null);
    // SYS: is the bootable one with the highest priority.
    const system = findDevice(db, "SYS").?;
    try testing.expectEqualStrings("DH2:", std.mem.span(system.misc.assign.assign_name.?));

    // dos is up: a node goes straight onto its list, and one whose name it
    // has already is refused and the caller's again.
    try testing.expect(AddBootNode(eb, 0, MakeDosNode(eb, "DH3", "flash.device", 0, 0, &test_environ).?));
    try testing.expect(eb.boot_nodes.isEmpty());
    try testing.expect(findDevice(db, "DH3") != null);
    const again = MakeDosNode(eb, "DH3", "flash.device", 0, 0, &test_environ).?;
    try testing.expect(!AddBootNode(eb, 0, again));
    kexec.FreeVec(kexec.SysBase, again);

    // expansion first, then dos, which frees utility.library and checks
    // for leaks.
    _ = takeDown(eb);
    try kdos.testTearDown(db);
}

/// The nodes of a list ObtainDeviceUnits answered, as an array.
fn unitsOf(list: *exec.List, into: []*const devices.DeviceUnit) usize {
    var count: usize = 0;
    var it = list.iterator();
    while (it.next()) |node| : (count += 1) into[count] = @ptrCast(@alignCast(node));
    return count;
}

test "devices by what they speak: units from the board's parts, labelled" {
    var board: Board = .{};
    const eb = try setUp(&board);
    defer kexec.deinit();
    const list = ObtainDeviceUnits(eb, devices.DEVIF_I2C, null).?;
    var units: [8]*const devices.DeviceUnit = undefined;
    try testing.expectEqual(@as(usize, 2), unitsOf(list, &units));
    // The first bus by its place among its kind, labelled; the second by
    // its PART_BusUnit.
    try testing.expectEqualStrings("test-bus.device", std.mem.span(units[0].node.name.?));
    try testing.expectEqual(@as(u32, 0), units[0].unit);
    try testing.expectEqualStrings("header P3", std.mem.span(units[0].label.?));
    try testing.expectEqual(@as(u32, 2), units[1].unit);
    try testing.expect(units[1].label == null);
    try testing.expectEqual(@as(u16, 3), units[0].version);
    try testing.expectEqual(@as(u16, 4), units[0].revision);
    try testing.expectEqual(devices.DUF_ROM, units[0].flags);
    try testing.expectEqual(devices.DEVIF_STREAM, units[0].speaks[0]);
    try testing.expectEqual(devices.DEVIF_I2C, units[0].speaks[1]);
    try testing.expectEqual(@as(u32, 0), units[0].speaks[2]);
    ReleaseDeviceUnits(eb, list);
    try tearDown(eb);
}

test "counted units with the device's labels; 0 asks for every device that says" {
    var board: Board = .{};
    const eb = try setUp(&board);
    defer kexec.deinit();
    const clocks = ObtainDeviceUnits(eb, devices.DEVIF_TIMER, null).?;
    var units: [8]*const devices.DeviceUnit = undefined;
    try testing.expectEqual(@as(usize, 3), unitsOf(clocks, &units));
    try testing.expectEqualStrings("slow", std.mem.span(units[1].label.?));
    try testing.expectEqual(@as(u32, 2), units[2].unit);
    ReleaseDeviceUnits(eb, clocks);
    // Every device that says what it speaks, by name: the bus device's
    // two, the clock's three, the touch device's one. The plain device
    // says nothing, and the other touch device's chip is not on the board.
    const all = ObtainDeviceUnits(eb, 0, null).?;
    try testing.expectEqual(@as(usize, 6), unitsOf(all, &units));
    try testing.expectEqualStrings("test-bus.device", std.mem.span(units[0].node.name.?));
    try testing.expectEqualStrings("test-clock.device", std.mem.span(units[4].node.name.?));
    try testing.expectEqualStrings("test-touch.device", std.mem.span(units[5].node.name.?));
    ReleaseDeviceUnits(eb, all);
    // A command set nobody speaks: an empty list, not null.
    const none = ObtainDeviceUnits(eb, devices.DEVIF_SANA2, null).?;
    try testing.expect(none.isEmpty());
    ReleaseDeviceUnits(eb, none);
    ReleaseDeviceUnits(eb, null);
    try tearDown(eb);
}

test "one device in two places is listed once, the higher version's" {
    var gathered: _device.Gathered = .{};
    var older: _device.Record = .{ .version = 1, .revision = 9 };
    @memcpy(older.tag_name[0..11], "foo.device\x00");
    @memcpy(older.name[0..11], "foo.device\x00");
    var newer = older;
    newer.version = 2;
    newer.revision = 0;
    @memcpy(newer.name[0..15], "usb/foo.device\x00");
    _device.add(&gathered, &older);
    _device.add(&gathered, &newer);
    try testing.expectEqual(@as(u32, 1), gathered.count);
    try testing.expectEqualStrings("usb/foo.device", std.mem.span(@as([*:0]const u8, &gathered.list[0].name)));
    // An older one after it changes nothing.
    _device.add(&gathered, &older);
    try testing.expectEqual(@as(u16, 2), gathered.list[0].version);
    try testing.expect(_device.speaksAny(&.{ 1, 2, 0 }, 2));
    try testing.expect(!_device.speaksAny(&.{ 1, 0, 2 }, 2));
    try testing.expect(_device.speaksAny(&.{0}, 0));
}

test "an ID string's revision" {
    try testing.expectEqual(@as(u16, 2), exec.resident.revisionOf("acm.device 1.2 (12.10.2026)\r\n"));
    try testing.expectEqual(@as(u16, 42), exec.resident.revisionOf("intuition.library 1.42 (12.10.2026)"));
    try testing.expectEqual(@as(u16, 0), exec.resident.revisionOf("timer.device"));
    try testing.expectEqual(@as(u16, 0), exec.resident.revisionOf("a 1. b"));
}

/// A load file in memory, for `loadfile`'s reader.
const Bytes = struct {
    data: []const u8,
    fn readAt(context: *anyopaque, offset: u32, into: []u8) bool {
        const self: *Bytes = @ptrCast(@alignCast(context));
        if (offset > self.data.len or self.data.len - offset < into.len) return false;
        @memcpy(into, self.data[offset..][0..into.len]);
        return true;
    }
};

fn put32(into: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, into[at..][0..4], value, .little);
}

test "a device's tag read from a load file's bytes" {
    // The header, then a data segment of 128 bytes: the tag at 0x10 as a
    // file has it, four-byte words, every pointer an offset in the
    // segment - its name at 0x40, its ID string at 0x50, its command sets
    // at 0x60, its labels' pointers at 0x70 and the labels at 0x78.
    var file: [20 + 16 + 128]u8 = @splat(0);
    @memcpy(file[0..4], &loadfile.MAGIC);
    std.mem.writeInt(u16, file[4..6], loadfile.VERSION, .little);
    std.mem.writeInt(u16, file[6..8], 1, .little);
    std.mem.writeInt(u16, file[10..12], loadfile.native_machine, .little);
    file[16] = 4;
    file[20] = @intFromEnum(loadfile.SegmentKind.data);
    put32(&file, 24, 128);
    put32(&file, 28, 128);
    const seg = 36;
    const tag = seg + 0x10;
    std.mem.writeInt(u16, file[tag..][0..2], 0x4AFC, .little);
    put32(&file, tag + 4, 0x10);
    file[tag + 12] = exec.RTF_DEVICEINFO;
    file[tag + 13] = 1;
    file[tag + 14] = @intFromEnum(exec.NodeType.device);
    put32(&file, tag + 16, 0x40);
    put32(&file, tag + 20, 0x50);
    put32(&file, tag + 28, 0x60);
    put32(&file, tag + 32, 0);
    put32(&file, tag + 36, 2);
    put32(&file, tag + 40, 0x70);
    put32(&file, tag + 44, st.CHIP_ANY);
    @memcpy(file[seg + 0x40 ..][0..11], "acm.device\x00");
    @memcpy(file[seg + 0x50 ..][0..15], "acm.device 1.3\x00");
    put32(&file, seg + 0x60, devices.DEVIF_STREAM);
    put32(&file, seg + 0x64, devices.DEVIF_SERIAL);
    put32(&file, seg + 0x6C, 0);
    put32(&file, seg + 0x68, 0);
    put32(&file, seg + 0x70, 0x78);
    put32(&file, seg + 0x74, 0);
    @memcpy(file[seg + 0x78 ..][0..4], "one\x00");

    var bytes = Bytes{ .data = &file };
    const source = loadfile.Source{ .context = &bytes, .readAt = Bytes.readAt };
    const found = loadfile.findResident(source).?;
    var device: loadfile.DeviceTag = .{};
    try testing.expect(loadfile.readDevice(source, found, &device));
    try testing.expectEqualStrings("acm.device", std.mem.span(@as([*:0]const u8, &device.name)));
    try testing.expectEqual(@as(u8, 1), device.version);
    try testing.expectEqual(@as(u16, 3), device.revision);
    try testing.expectEqual(devices.DEVIF_SERIAL, device.speaks[1]);
    try testing.expectEqual(@as(u32, 0), device.speaks[2]);
    try testing.expectEqual(@as(u32, 2), device.units);
    try testing.expectEqual(st.CHIP_ANY, device.unit_chip);
    var label: [8]u8 = undefined;
    try testing.expectEqualStrings("one", loadfile.readUnitLabel(source, found, &device, 0, &label).?);
    try testing.expect(loadfile.readUnitLabel(source, found, &device, 1, &label) == null);
    try testing.expect(loadfile.readUnitLabel(source, found, &device, 2, &label) == null);

    // A tag that does not say what it speaks is no device's here.
    file[tag + 12] = 0;
    try testing.expect(!loadfile.readDevice(source, found, &device));
    file[tag + 12] = exec.RTF_DEVICEINFO;
    // Command sets that run past the segment's end: refused.
    put32(&file, tag + 28, 0x7C);
    put32(&file, seg + 0x7C, devices.DEVIF_STREAM);
    try testing.expect(!loadfile.readDevice(source, found, &device));
}
