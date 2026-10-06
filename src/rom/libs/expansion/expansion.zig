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
//! A disk's driver starts before dos.library, so it cannot put its
//! partitions on dos's list itself: it makes a device node for each with
//! MakeDosNode and hands it over with AddBootNode, and this library keeps
//! the nodes until dos's init takes them with EnterBootNodes. From then on
//! a node goes straight onto dos's list.
//!
//! Each call is a file of its own, under `part/` for the board and `boot/`
//! for the disks. The jump table is
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
const dos = sdk.dos;

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
}

const TagItem = utility.TagItem;

// A board to test against: two I2C buses, a touch chip on the first, a
// card slot, and a part with no chip name of its own.
const bus0 = [_]TagItem{
    .{ .tag = st.PART_Kind, .data = st.PARTKIND_I2CBUS },
    .{ .tag = st.PART_PinSCL, .data = pins.gpio(9) },
    .{ .tag = st.PART_PinSDA, .data = pins.gpio(8) },
    .{ .tag = utility.TAG_DONE, .data = 0 },
};
const bus1 = [_]TagItem{
    .{ .tag = st.PART_Kind, .data = st.PARTKIND_I2CBUS },
    .{ .tag = utility.TAG_DONE, .data = 0 },
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
    table: [2]?*const exec.Resident = undefined,

    fn build(board: *Board) void {
        board.touch[2].data = @intFromPtr("gt911");
        board.root = .{
            .{ .tag = st.SYSTAG_Name, .data = @intFromPtr("Test board") },
            .{ .tag = st.SYSTAG_Console, .data = st.CONSOLE_USBJTAG },
            .{ .tag = st.SYSTAG_Part, .data = @intFromPtr(&bus0) },
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
        board.table = .{ &board.resident, null };
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
