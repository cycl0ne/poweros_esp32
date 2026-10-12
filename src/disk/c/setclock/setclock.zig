// SPDX-License-Identifier: MIT
//! SetClock: the system time loaded from the clock that keeps the date
//! while the system is off (battclock.resource), saved to it, or the
//! clock reset. Built against the SDK only.
//!
//!   SetClock LOAD/S,SAVE/S,RESET/S
//!
//!   SetClock LOAD     the system time set from the clock
//!   SetClock SAVE     the clock set to the system time
//!   SetClock RESET    the clock put in working order, its date 1-Jan-1978
//!
//! The resource sets the system time from the clock as the system starts,
//! so LOAD is for a clock that was changed since; SAVE after `Date` or
//! `C:net/TimeSync` keeps the date over the next reset or power cut. One
//! of the three is done, the first given; with none, nothing. Nothing is
//! printed unless there is no clock.

const sdk = @import("sdk");
const dos = sdk.dos;
const timer = sdk.devices.timer;
const battclock = sdk.resources.battclock;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;

pub const COMMAND_NAME = "SetClock";
const VERSION_STRING = "\x00$VER: SetClock 1.0 (12.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "LOAD/S,SAVE/S,RESET/S";
const arg_load = 0;
const arg_save = 1;
const arg_reset = 2;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [3]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const cb: *battclock.BattClockBase = @ptrCast(sys.OpenResource(battclock.BATTCLOCKNAME) orelse {
        _ = dl.PutStr("Can't find a clock that keeps the date\n");
        return dos.RETURN_FAIL;
    });
    var request: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &request.node, 0) != 0) {
        _ = dl.PutStr("Can't open timer.device\n");
        return dos.RETURN_FAIL;
    }
    defer sys.CloseDevice(&request.node);

    if (argv[arg_load] != 0) {
        request.node.command = timer.TR_SETSYSTIME;
        request.time = .{ .secs = cb.ReadBattClock(), .micro = 0 };
        if (sys.DoIO(&request.node) != 0) return dos.RETURN_FAIL;
    } else if (argv[arg_save] != 0) {
        request.node.command = timer.TR_GETSYSTIME;
        if (sys.DoIO(&request.node) != 0) return dos.RETURN_FAIL;
        cb.WriteBattClock(request.time.secs);
    } else if (argv[arg_reset] != 0) {
        cb.ResetBattClock();
    }
    return dos.RETURN_OK;
}
