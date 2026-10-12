// SPDX-License-Identifier: MIT
//! Battery: the board's battery, as battery.resource measures it. Built
//! against the SDK only.
//!
//!   Battery [WATCH/S]
//!
//!   Battery         the cell's voltage and charge, and the supply and
//!                   charging where the board can tell
//!   Battery WATCH   the same again at every change, until Ctrl-C
//!
//! On a board that cannot measure its battery it says so, and returns
//! WARN, so a script can ask `If WARN`.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const battery = sdk.resources.battery;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const BatteryBase = sdk.interface.battery.BatteryBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Battery";
const VERSION_STRING = "\x00$VER: Battery 1.0 (11.10.2026)\r\n";
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
    const bb: *BatteryBase = @ptrCast(@alignCast(sys.OpenResource(battery.BATTERYNAME) orelse {
        _ = Printf(dl, "No %s\n", .{battery.BATTERYNAME});
        return dos.RETURN_WARN;
    }));

    var state: battery.BatteryState = .{};
    if (!bb.ReadBattery(&state) and state.flags & battery.BATTF_KNOWS_EXTERNAL == 0) {
        _ = Printf(dl, "This board does not measure a battery\n", .{});
        return dos.RETURN_WARN;
    }
    if (argv[arg_watch] == 0) {
        show(dl, &state);
        return dos.RETURN_OK;
    }

    const bit = sys.AllocSignal(-1);
    if (bit < 0) return dos.RETURN_FAIL;
    defer sys.FreeSignal(bit);
    const changed = @as(u32, 1) << @intCast(bit);
    const notify = bb.AddBatteryNotify(sys.FindTask(null).?, changed) orelse return dos.RETURN_FAIL;
    defer bb.RemBatteryNotify(notify);
    show(dl, &state);
    while (true) {
        const got = sys.Wait(changed | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) break;
        _ = bb.ReadBattery(&state);
        show(dl, &state);
    }
    return dos.RETURN_OK;
}

/// One line: the cell, then what the board can tell of the supply.
fn show(dl: *DosBase, state: *const battery.BatteryState) void {
    const flags = state.flags;
    if (flags & battery.BATTF_MEASURED == 0) {
        _ = Printf(dl, "Battery   not measured", .{});
    } else if (flags & battery.BATTF_PRESENT == 0) {
        _ = Printf(dl, "Battery   none", .{});
    } else {
        const level: [*:0]const u8 = if (flags & battery.BATTF_CRITICAL != 0)
            ", critical"
        else if (flags & battery.BATTF_LOW != 0)
            ", low"
        else
            "";
        _ = Printf(dl, "Battery   %u.%02u V, %u%%%s", .{ state.millivolts / 1000, (state.millivolts % 1000) / 10, state.percent, level });
    }
    if (flags & battery.BATTF_KNOWS_EXTERNAL != 0) {
        const supply: [*:0]const u8 = if (flags & battery.BATTF_EXTERNAL != 0) "external power" else "on the battery";
        _ = Printf(dl, "   %s", .{supply});
    }
    if (flags & battery.BATTF_KNOWS_CHARGING != 0 and flags & battery.BATTF_CHARGING != 0) _ = Printf(dl, ", charging", .{});
    _ = Printf(dl, "\n", .{});
}
