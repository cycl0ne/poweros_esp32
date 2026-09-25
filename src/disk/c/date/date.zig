// SPDX-License-Identifier: MIT
//! Date: the system's date and time shown, or set. Built against the SDK
//! only.
//!
//!   Date DAY,DATE,TIME,TO=VER/K
//!
//!   Date                       Friday 25-Sep-2026 22:43:11
//!   Date 25-Sep-2026 22:43     both set, then nothing printed
//!   Date tomorrow              a day on, the time of day kept
//!   Date 12:00 TO=RAM:now      set, and the new date written to a file
//!
//! Each of DAY, DATE and TIME is read as a date - dd-mmm-yyyy, a weekday
//! (the coming one), today, tomorrow, yesterday - and else as a time,
//! hh:mm or hh:mm:ss, so they may come in any order; what is not given
//! stays as it is. Setting prints nothing, unless TO names where the new
//! date goes. Without anything to set, the date is printed, to TO if
//! given. A string that is neither sets nothing: in TIME it is a warning,
//! elsewhere an error.
//!
//! The date is the system time timer.device keeps (TR_SETSYSTIME), which
//! has no battery behind it; C:net/TimeSync sets it from a time server.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;
const FPrintf = dos.stdio.FPrintf;

pub const COMMAND_NAME = "Date";
const VERSION_STRING = "\x00$VER: Date 1.0 (25.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "DAY,DATE,TIME,TO=VER/K";
const arg_day = 0;
const arg_date = 1;
const arg_time = 2;
const arg_to = 3;

const MSG_USE = "- use DD-MMM-YYYY or <dayname> or yesterday etc. to set date\n" ++
    "      HH:MM:SS or HH:MM to set time\n";
const MSG_BADARGS = "***Bad args\n" ++ MSG_USE;
const MSG_DATE = "%s %s %s\n";

const ticks_per_second = 50;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [4]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        _ = dl.PutStr(MSG_USE);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const to = rdargs.string(argv[arg_to]);

    const setting = argv[arg_day] != 0 or argv[arg_date] != 0 or argv[arg_time] != 0;
    if (setting) {
        var datetime: dos.DateTime = .{ .format = dos.datetime.FORMAT_DOS, .flags = dos.datetime.DTF_FUTURE };
        _ = dl.DateStamp(&datetime.stamp);
        // Each string as a date, and failing that as a time.
        for ([_]usize{ arg_day, arg_date, arg_time }) |slot| {
            const text = rdargs.string(argv[slot]) orelse continue;
            datetime.str_date = @constCast(text);
            datetime.str_time = null;
            if (dl.StrToDate(&datetime)) continue;
            datetime.str_date = null;
            datetime.str_time = @constCast(text);
            if (dl.StrToDate(&datetime)) continue;
            _ = dl.PutStr(MSG_BADARGS);
            return if (slot == arg_time) dos.RETURN_WARN else dos.RETURN_FAIL;
        }

        var request: timer.TimeRequest = .{};
        if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &request.node, 0) != 0) return dos.RETURN_FAIL;
        defer sys.CloseDevice(&request.node);
        const stamp = datetime.stamp;
        request.node.command = timer.TR_SETSYSTIME;
        request.time = .{
            .secs = @intCast(@as(i64, stamp.days) * 86400 + @as(i64, stamp.minute) * 60 + @divTrunc(stamp.tick, ticks_per_second)),
            .micro = @intCast(@mod(stamp.tick, ticks_per_second) * (1_000_000 / ticks_per_second)),
        };
        if (sys.DoIO(&request.node) != 0) return dos.RETURN_FAIL;
        // Set, and nowhere to say it: done.
        if (to == null) return dos.RETURN_OK;
    }

    var day: [dos.datetime.LEN_DATSTRING]u8 = @splat(0);
    var date: [dos.datetime.LEN_DATSTRING]u8 = @splat(0);
    var time: [dos.datetime.LEN_DATSTRING]u8 = @splat(0);
    var now: dos.DateTime = .{
        .format = dos.datetime.FORMAT_DOS,
        .str_day = @ptrCast(&day),
        .str_date = @ptrCast(&date),
        .str_time = @ptrCast(&time),
    };
    _ = dl.DateStamp(&now.stamp);
    if (!dl.DateToStr(&now)) return dos.RETURN_FAIL;
    const values = .{ @as([*:0]const u8, @ptrCast(&day)), @as([*:0]const u8, @ptrCast(&date)), @as([*:0]const u8, @ptrCast(&time)) };

    if (to) |name| {
        const file = dl.Open(name, dos.MODE_NEWFILE) orelse {
            _ = dl.PrintFault(dl.IoErr(), name);
            // The date may have been set all the same.
            return if (setting) dos.RETURN_WARN else dos.RETURN_FAIL;
        };
        defer _ = dl.Close(file);
        _ = FPrintf(dl, file, MSG_DATE, values);
        return dos.RETURN_OK;
    }
    _ = Printf(dl, MSG_DATE, values);
    return dos.RETURN_OK;
}
