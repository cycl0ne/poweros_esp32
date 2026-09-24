// SPDX-License-Identifier: MPL-2.0
//! expansion.library's ROM tag, and the init routine it names: the system
//! tag list found, and a BoardPart made for each of its parts.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const expansion = sdk.expansion;
const st = expansion.systemtags;
const BoardPart = expansion.BoardPart;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const expansion_lvo = @import("expansion_lvo.zig");
const expansion_base = @import("expansion_base.zig");
const ExpansionBase = expansion_base.ExpansionBase;

/// The name it is opened by. The SDK's.
pub const LIBRARY_NAME = expansion.EXPANSIONNAME;
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 0;
const BUILD_DATE = "24.09.2026";
const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const UTILITY_VERSION = 1;

fn expansionBase(lib: *exec.Library) *ExpansionBase {
    return @alignCast(@fieldParentPtr("lib", lib));
}

/// The name a part goes by when the board gives it none: its kind's.
fn kindName(kind: u32) [*:0]const u8 {
    return switch (kind) {
        st.PARTKIND_I2CBUS => "i2cbus",
        st.PARTKIND_SDSLOT => "sdslot",
        st.PARTKIND_TOUCH => "touch",
        st.PARTKIND_CODEC => "codec",
        st.PARTKIND_AMPLIFIER => "amplifier",
        st.PARTKIND_EXPANDER => "expander",
        st.PARTKIND_PANEL => "panel",
        st.PARTKIND_LED => "led",
        st.PARTKIND_BATTERY => "battery",
        st.PARTKIND_KEYBOARD => "keyboard",
        st.PARTKIND_MOUSE => "mouse",
        else => "part",
    };
}

/// The system tag list the board's ROM carries, if it carries one: the
/// "system" ROM tag's rt_Init.
fn findSystem(sys: *ExecBase) ?[*]const utility.TagItem {
    const tag = sys.FindResident(expansion.SYSTEM_RESIDENT) orelse return null;
    if (tag.type != .board) return null;
    return @ptrCast(@alignCast(tag.init orelse return null));
}

/// LibInit: the system tag list found and each of its parts made a
/// BoardPart, in the board's order.
///
/// INPUTS:
/// - `lib` - the base exec made from the init table.
/// - `seg_list` - null: a module in the ROM has no segments.
/// - `sys_base` - SysBase, kept in the base.
///
/// RESULT:
/// The base, or null when utility.library or the memory for the parts is
/// not to be had. A ROM without a system tag list is not an error: the
/// board then has no parts, and SystemTags answers an empty list.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: no; it runs on the exec task at cold start.
/// - Forbid: not held. - Process: a Task will do.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const eb = expansionBase(lib);
    lib.revision = LIBRARY_REVISION;
    eb.sys_base = sys_base;
    eb.utility_base = @ptrCast(sys_base.OpenLibrary(sdk.interface.utility.NAME, UTILITY_VERSION) orelse return null);
    eb.system = findSystem(sys_base) orelse &expansion_base.empty_list;
    eb.parts = null;
    eb.part_count = 0;
    const ub = eb.utility_base;

    // How many parts, then all of them in one allocation.
    var count: u32 = 0;
    var walk: ?[*]const utility.TagItem = eb.system;
    while (ub.NextTagItem(&walk)) |item| {
        if (item.tag == st.SYSTAG_Part) count += 1;
    }
    if (count == 0) return lib;
    const memory = sys_base.AllocMem(count * @sizeOf(BoardPart), exec.MEMF_CLEAR) orelse {
        sys_base.CloseLibrary(ub.lib());
        return null;
    };
    const parts: [*]BoardPart = @ptrCast(@alignCast(memory));

    var made: u32 = 0;
    walk = eb.system;
    while (ub.NextTagItem(&walk)) |item| {
        if (item.tag != st.SYSTAG_Part) continue;
        const tags: [*]const utility.TagItem = @ptrFromInt(item.data);
        const kind: u32 = @truncate(ub.GetTagData(st.PART_Kind, 0, tags));
        // The nth of its kind, counting the parts made before it.
        var unit: u32 = 0;
        for (parts[0..made]) |*earlier| {
            if (earlier.kind == kind) unit += 1;
        }
        const name: [*:0]const u8 = @ptrFromInt(ub.GetTagData(st.PART_ChipName, @intFromPtr(kindName(kind)), tags));
        parts[made] = .{
            .node = .{ .type = .board, .name = name },
            .kind = kind,
            .chip = @truncate(ub.GetTagData(st.PART_Chip, st.CHIP_NONE, tags)),
            .unit = unit,
            .tags = tags,
        };
        made += 1;
    }
    eb.parts = parts;
    eb.part_count = made;
    return lib;
}

const init_table = exec.InitTable{
    .data_size = @sizeOf(ExpansionBase),
    .vectors = &expansion_lvo.vectors,
    .vector_count = expansion_lvo.vectors.len,
    .init = &init,
};

/// Cold start, right after utility.library (103), whose tag calls it
/// reads the list with, and before every module that asks it for a part.
pub export const expansion_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &expansion_library_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .pri = 102,
    .type = .library,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..],
    .init = &init_table,
};
