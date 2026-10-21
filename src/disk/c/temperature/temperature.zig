// SPDX-License-Identifier: MIT
//! Temperature: the board's temperatures, as thermal.resource reads them.
//! Built against the SDK only.
//!
//!   Temperature [WATCH/S]
//!
//!   Temperature         each sensor's reading, and its hot and critical
//!                       temperatures
//!   Temperature WATCH   the same again whenever a sensor passes one of
//!                       them, until Ctrl-C
//!
//! On a board without a sensor it says so, and returns WARN, so a script
//! can ask `If WARN`.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const thermal = sdk.resources.thermal;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const ThermalBase = sdk.interface.thermal.ThermalBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Temperature";
const VERSION_STRING = "\x00$VER: Temperature 1.0 (21.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "WATCH/S";
const arg_watch = 0;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [1]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    // A resource is never closed: OpenResource only finds it.
    const tb: *ThermalBase = @ptrCast(@alignCast(sys.OpenResource(thermal.THERMALNAME) orelse {
        _ = Printf(dl, "No %s\n", .{thermal.THERMALNAME});
        return dos.RETURN_WARN;
    }));
    var first: thermal.ThermalState = .{};
    if (!tb.ReadTemperature(0, &first) and first.name == null and first.hot_millicelsius == 0) {
        _ = Printf(dl, "This board has no temperature sensor\n", .{});
        return dos.RETURN_WARN;
    }
    if (argv[arg_watch] == 0) {
        showAll(dl, tb);
        return dos.RETURN_OK;
    }

    const bit = sys.AllocSignal(-1);
    if (bit < 0) return dos.RETURN_FAIL;
    defer sys.FreeSignal(bit);
    const changed = @as(u32, 1) << @intCast(bit);
    const notify = tb.AddThermalNotify(sys.FindTask(null).?, changed) orelse return dos.RETURN_FAIL;
    defer tb.RemThermalNotify(notify);
    showAll(dl, tb);
    while (true) {
        const got = sys.Wait(changed | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) break;
        showAll(dl, tb);
    }
    return dos.RETURN_OK;
}

/// A line a sensor, unit 0 on, until the resource has no more.
fn showAll(dl: *DosBase, tb: *ThermalBase) void {
    var unit: u32 = 0;
    while (true) : (unit += 1) {
        var state: thermal.ThermalState = .{};
        const measured = tb.ReadTemperature(unit, &state);
        if (!measured and state.name == null and state.hot_millicelsius == 0) break;
        show(dl, &state, measured);
    }
}

/// One line: the sensor's name, its reading and how it stands to its
/// limits.
fn show(dl: *DosBase, state: *const thermal.ThermalState, measured: bool) void {
    const name: [*:0]const u8 = state.name orelse "Sensor";
    _ = Printf(dl, "%-12s", .{name});
    if (!measured) {
        _ = Printf(dl, "no reading", .{});
    } else {
        printDegrees(dl, state.millicelsius);
        if (state.flags & thermal.THERMF_CRITICAL != 0) {
            _ = Printf(dl, "  CRITICAL", .{});
        } else if (state.flags & thermal.THERMF_HOT != 0) {
            _ = Printf(dl, "  hot", .{});
        }
    }
    if (state.hot_millicelsius != 0) {
        _ = Printf(dl, "   (hot at ", .{});
        printDegrees(dl, state.hot_millicelsius);
        _ = Printf(dl, ", critical at ", .{});
        printDegrees(dl, state.critical_millicelsius);
        _ = Printf(dl, ")", .{});
    }
    _ = Printf(dl, "\n", .{});
}

/// Thousandths of a degree as degrees with one decimal, rounded.
fn printDegrees(dl: *DosBase, millicelsius: i32) void {
    const negative = millicelsius < 0;
    const tenths: u32 = (@abs(millicelsius) + 50) / 100;
    const sign: [*:0]const u8 = if (negative and tenths != 0) "-" else "";
    _ = Printf(dl, "%s%lu.%lu \xB0C", .{ sign, @as(u64, tenths / 10), @as(u64, tenths % 10) });
}
