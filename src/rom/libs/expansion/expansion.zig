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
//! Each call is a file of its own under `part/`. The jump table is
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
const FindBoardPart = @import("part/findboardpart.zig").FindBoardPart;
const SystemTags = @import("part/systemtags.zig").SystemTags;

test {
    _ = expansion_base;
    _ = expansion_init;
    _ = @import("expansion_lvo.zig");
    _ = @import("part/findboardpart.zig");
    _ = @import("part/systemtags.zig");
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

fn tearDown(eb: *ExpansionBase) !void {
    kexec.SysBase.res_modules = null;
    if (eb.parts) |parts| kexec.FreeMem(kexec.SysBase, @ptrCast(parts), eb.part_count * @sizeOf(expansion.BoardPart));
    const ub: *kutility.UtilityBase = @ptrCast(@alignCast(eb.utility_base));
    _ = kexec.CloseLibrary(kexec.SysBase, &ub.lib);
    kexec.Remove(kexec.SysBase, &eb.lib.node);
    kexec.freeLibraryMemory(kexec.SysBase, &eb.lib);
    kutility.freeForTests(ub);
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
