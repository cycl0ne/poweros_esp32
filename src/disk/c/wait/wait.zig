// SPDX-License-Identifier: MIT
//! Wait: waits, in a script. Built against the SDK only.
//!
//!   Wait /N,SEC=SECS/S,MIN=MINS/S,UNTIL/K
//!
//!   Wait              a second
//!   Wait 5            five seconds (the default unit)
//!   Wait 5 MINS       five minutes
//!   Wait UNTIL 21:30  until half past nine tonight, or tomorrow night if
//!                     it is already past
//!
//! Ctrl-C stops it: "***Break" and RETURN_WARN.
//!
//! It waits a second at a time and reads the clock again each time round:
//! a Delay of the whole span would run late on a machine that
//! is busy, and would not notice a Ctrl-C until it was over.
//!
//! UNTIL takes hh:mm through dos's StrToDate, so "9:30" is read as well as
//! "09:30" and "21:30:15" is read too.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const rdargs = dos.rdargs;

pub const COMMAND_NAME = "Wait";
const VERSION_STRING = "\x00$VER: Wait 1.0 (16.9.2026)\r\n";

const template = "/N,SEC=SECS/S,MIN=MINS/S,UNTIL/K";
const arg_n = 0;
const arg_secs = 1;
const arg_mins = 2;
const arg_until = 3;

const MSG_BADHHMM = "Time should be HH:MM\n";
const MSG_BADNUM = "Error in number\n";

/// Ticks of a fiftieth of a second, as a DateStamp counts them.
const ticks_per_second: i64 = 50;
const ticks_per_minute: i64 = 60 * ticks_per_second;
const ticks_per_day: i64 = 24 * 60 * ticks_per_minute;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [4]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    var now: dos.DateStamp = .{};
    _ = dl.DateStamp(&now);
    var now_day: i64 = now.days;
    var now_time: i64 = timeOf(now);

    var until_day: i64 = undefined;
    var until_time: i64 = undefined;

    if (rdargs.string(argv[arg_until])) |text| {
        // /K does not strip the blanks in front of the value.
        var at = text;
        while (at[0] == ' ') at += 1;

        var when: dos.DateTime = .{ .str_time = @constCast(at) };
        if (!dl.StrToDate(&when)) {
            _ = dl.PutStr(MSG_BADHHMM);
            return dos.RETURN_FAIL;
        }
        until_day = now_day;
        until_time = when.stamp.minute * ticks_per_minute + when.stamp.tick;
        // Gone already: the same time tomorrow.
        if (now_time > until_time) until_day += 1;
    } else {
        // A count with no unit is seconds, which is the unit a script
        // means when it says nothing.
        var ticks: i64 = if (rdargs.number(argv[arg_n])) |n| n else 1;
        if (ticks < 0) {
            _ = dl.PutStr(MSG_BADNUM);
            return dos.RETURN_FAIL;
        }
        ticks *= if (argv[arg_mins] != 0) ticks_per_minute else ticks_per_second;
        until_day = now_day;
        until_time = now_time + ticks;
        while (until_time >= ticks_per_day) {
            until_time -= ticks_per_day;
            until_day += 1;
        }
    }

    while (now_day < until_day or (now_day == until_day and now_time < until_time)) {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
            _ = dl.PrintFault(dos.ERROR_BREAK, null);
            return dos.RETURN_WARN;
        }
        // A second at a time, and the clock read again each time round: a
        // process at a low priority would otherwise run past its time.
        dl.Delay(@intCast(ticks_per_second));
        _ = dl.DateStamp(&now);
        now_day = now.days;
        now_time = timeOf(now);
    }
    return dos.RETURN_OK;
}

/// The ticks past midnight a DateStamp names.
fn timeOf(ds: dos.DateStamp) i64 {
    return @as(i64, ds.minute) * ticks_per_minute + ds.tick;
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
