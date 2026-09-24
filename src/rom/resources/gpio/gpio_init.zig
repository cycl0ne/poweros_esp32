// SPDX-License-Identifier: MPL-2.0
//! gpio.resource's ROM tag, and the init routine it names: every pad free
//! but the ones the system itself uses.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const types = sdk.resources.gpio;
const st = sdk.expansion.systemtags;
const ExecBase = sdk.interface.exec.ExecBase;
const gpio_lvo = @import("gpio_lvo.zig");
const GpioBase = @import("gpio_base.zig").GpioBase;

/// The name it is opened by. The SDK's.
pub const RESOURCE_NAME = types.GPIONAME;
pub const RESOURCE_VERSION = 1;
pub const RESOURCE_REVISION = 0;
const BUILD_DATE = "24.09.2026";
const RESOURCE_VERSION_STRING =
    "\x00$VER: " ++ RESOURCE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ RESOURCE_VERSION, RESOURCE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The pads the flash sits on: its clock, data and chip select.
const flash_pads = [_]u32{ 27, 28, 29, 30, 31, 32 };
/// PSRAM's chip select, and the four more data lines and the strobe an
/// octal PSRAM takes.
const psram_select: u32 = 26;
const octal_psram_pads = [_]u32{ 33, 34, 35, 36, 37 };
/// The USB port's D- and D+, which the USB-Serial-JTAG port is on.
const usb_pads = [_]u32{ 19, 20 };
/// UART0's TX and RX: exec's raw output, and the boot ROM's.
const uart0_pads = [_]u32{ 43, 44 };

fn gpioBase(lib: *exec.Library) *GpioBase {
    return @alignCast(@fieldParentPtr("lib", lib));
}

fn hold(gb: *GpioBase, pads: []const u32, name: [*:0]const u8) void {
    for (pads) |pad| gb.owner[pad] = name;
}

/// The PSRAM a board has: how many bytes, and how it is wired.
const Psram = struct { size: usize = 0, mode: usize = st.PSRAM_NONE };

/// The board's PSRAM, from its system tag list. None when the list cannot
/// be read.
fn psramOf(sys: *ExecBase) Psram {
    const none: Psram = .{};
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return none;
    defer sys.CloseLibrary(utility_lib);
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return none;
    defer sys.CloseLibrary(expansion_lib);
    const ub: *sdk.interface.utility.UtilityBase = @ptrCast(utility_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    const root = eb.SystemTags();
    return .{
        .size = ub.GetTagData(st.SYSTAG_PsramSize, 0, root),
        .mode = ub.GetTagData(st.SYSTAG_PsramMode, st.PSRAM_NONE, root),
    };
}

/// ResInit: every pad free, then the system's own taken - the flash's,
/// the PSRAM's as the board has it, the USB port's and UART0's - so no
/// driver is handed a pad the machine is running on.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: no; it runs on the exec task at cold start.
/// - Forbid: not held. - Process: a Task will do.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const gb = gpioBase(lib);
    lib.revision = RESOURCE_REVISION;
    gb.sys_base = sys_base;
    gb.owner = @splat(null);
    hold(gb, &flash_pads, "flash");
    const psram = psramOf(sys_base);
    if (psram.size != 0) {
        hold(gb, &.{psram_select}, "psram");
        if (psram.mode == st.PSRAM_OCTAL) hold(gb, &octal_psram_pads, "psram");
    }
    hold(gb, &usb_pads, "usb");
    hold(gb, &uart0_pads, "uart0");
    return lib;
}

const init_table = exec.InitTable{
    .data_size = @sizeOf(GpioBase),
    .vectors = &gpio_lvo.vectors,
    .vector_count = gpio_lvo.vectors.len,
    .init = &init,
};

/// Cold start at 90: after expansion.library (102), whose board it reads
/// the PSRAM from, and before every driver that takes a pad.
pub export const gpio_resource_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &gpio_resource_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = RESOURCE_VERSION,
    .type = .resource,
    .pri = 90,
    .name = RESOURCE_NAME,
    .id_string = RESOURCE_VERSION_STRING[1..],
    .init = &init_table,
};
