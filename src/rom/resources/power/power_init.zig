// SPDX-License-Identifier: MPL-2.0
//! power.resource's ROM tag, and the init routine it names: what the
//! machine can do about its own power worked out once, the power
//! management the board describes started, and the task that answers a
//! press of the button started with it.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const power = sdk.resources.power;
const st = sdk.expansion.systemtags;
const BoardPart = sdk.expansion.BoardPart;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const power_lvo = @import("power_lvo.zig");
const PowerBase = @import("power_base.zig").PowerBase;
const acpipm = @import("source/acpipm.zig");
const _machine = @import("machine/_machine.zig");
const _button = @import("button/_button.zig");

/// The name it is opened by. The SDK's.
pub const RESOURCE_NAME = power.POWERNAME;
pub const RESOURCE_VERSION = 1;
pub const RESOURCE_REVISION = 0;
const BUILD_DATE = "04.11.2026";
const RESOURCE_VERSION_STRING =
    "\x00$VER: " ++ RESOURCE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ RESOURCE_VERSION, RESOURCE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

fn powerBase(lib: *exec.Library) *PowerBase {
    return @alignCast(@fieldParentPtr("lib", lib));
}

/// The board's power management into the base: where its registers are,
/// which line it raises, and whether its power button is one of the
/// things it reports. False where the board describes none, and the
/// machine then has no button as far as this system is concerned.
fn findHardware(pb: *PowerBase) bool {
    const sys = pb.sys_base;
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return false;
    defer sys.CloseLibrary(utility_lib);
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return false;
    defer sys.CloseLibrary(expansion_lib);
    const ub: *UtilityBase = @ptrCast(utility_lib);
    const eb: *ExpansionBase = @ptrCast(expansion_lib);
    const part: *const BoardPart = eb.FindBoardPart(null, st.PARTKIND_POWER, st.CHIP_ACPI_PM) orelse return false;
    const tags = part.tags;
    if (ub.GetTagData(st.PART_Bus, st.BUS_PORT, tags) != st.BUS_PORT) return false;
    pb.hardware = .{
        .event = @truncate(ub.GetTagData(st.PART_Address, 0, tags)),
        .event2 = @truncate(ub.GetTagData(st.PART_PowerEvent2, 0, tags)),
        .control = @truncate(ub.GetTagData(st.PART_PowerControl, 0, tags)),
        .control2 = @truncate(ub.GetTagData(st.PART_PowerControl2, 0, tags)),
        .event_bytes = @truncate(ub.GetTagData(st.PART_PowerEventBytes, 0, tags)),
        .mode_port = @truncate(ub.GetTagData(st.PART_PowerMode, 0, tags)),
        .mode_value = @truncate(ub.GetTagData(st.PART_PowerModeValue, 0, tags)),
        .button = ub.GetTagData(st.PART_PowerButton, 0, tags) != 0,
    };
    pb.source = @truncate(ub.GetTagData(st.PART_Irq, 0, tags));
    return acpipm.usable(pb.hardware);
}

/// ResInit: what the machine can do about its own power, and the power
/// button taken where there is one. The button wants three things of the
/// machine, and all three or nothing: hardware the board describes, a
/// line it raises, and the mode it reports in. Where any is missing the
/// resource is made all the same and says the machine has no button; it
/// may still be able to turn itself off, which is the firmware's doing
/// and wants nothing of the board's.
///
/// CONTEXT:
/// - Waits: for memory, and for its own task to come up. - Interrupts:
///   no; it runs on the exec task at cold start.
/// - Locks: none needed. - Process: a Task will do.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const pb = powerBase(lib);
    lib.revision = RESOURCE_REVISION;
    pb.sys_base = sys_base;
    pb.abilities = 0;
    pb.hardware = .{};
    pb.started = false;
    pb.hooked = false;
    pb.source = 0;
    pb.stack = null;
    pb.press_signal = 0;
    pb.starter = null;
    sys_base.NewList(&pb.notify);
    sys_base.InitSemaphore(&pb.lock);
    if (_machine.canOff()) pb.abilities |= power.POWERF_OFF;
    if (findHardware(pb) and _button.start(pb)) pb.abilities |= power.POWERF_BUTTON;
    return lib;
}

const init_table = exec.InitTable{
    .data_size = @sizeOf(PowerBase),
    .vectors = &power_lvo.vectors,
    .vector_count = power_lvo.vectors.len,
    .init = &init,
};

/// Cold start at 28: after expansion.library, which it finds the board's
/// power management through, and before anything that may want to hear
/// about the button.
pub export const power_resource_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &power_resource_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = RESOURCE_VERSION,
    .type = .resource,
    .pri = 28,
    .name = RESOURCE_NAME,
    .id_string = RESOURCE_VERSION_STRING[1..],
    .init = &init_table,
};
