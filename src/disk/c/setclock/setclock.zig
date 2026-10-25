// SPDX-License-Identifier: MIT
//! SetClock: the system time loaded from the clock that keeps the date
//! while the system is off (battclock.resource), saved to it, or the
//! clock reset; and the time zone kept where the file systems read it
//! (battmem.resource). Built against the SDK only.
//!
//!   SetClock LOAD/S,SAVE/S,RESET/S,ZONE/S
//!
//!   SetClock LOAD     the system time set from the clock - or from the
//!                     date SAVE last kept, where that is later
//!   SetClock SAVE     the clock set to the system time, and the date
//!                     kept in ENVARC:Sys/clock
//!   SetClock RESET    the clock put in working order, its date 1-Jan-1978
//!   SetClock ZONE     the rule in ENVARC:Sys/timezone kept in battmem
//!
//! The resource sets the system time from the clock as the system starts,
//! so LOAD is for a clock that was changed since; SAVE after `Date` or
//! `C:net/TimeSync` keeps the date over the next reset or power cut. Of
//! those three one is done, the first given; with none, nothing. Nothing
//! is printed unless RESET finds no clock, or SAVE cannot write the file.
//!
//! **The date last kept.** A clock that loses the date - the VisionFive
//! 2's RTC over a power cut - or no clock at all would start the system
//! in 1978. SAVE writes the system time to ENVARC:Sys/clock as well, in
//! seconds since 1 January 1978, and LOAD takes that date where the
//! clock's - or, with no clock, the system time - is earlier: never
//! before the last SAVE, though behind by as long as the board was off,
//! until TimeSync puts it right. The startup sequence LOADs before it
//! writes a file, so that every file is stamped by the clock this start
//! keeps from then on.
//!
//! ZONE is done as well, first: the zone file's first line that is not a
//! `#` comment (sdk.dos.timezone), or UTC with none. The startup sequence
//! does it once ENVARC: is there, so a file system that writes moments
//! with their offset from UTC (exFAT) has the zone without reading the
//! file - which it could not do on the volume that holds it. A rule whose
//! offsets or times of change are not whole quarter hours cannot be kept,
//! and is refused.

const std = @import("std");
const sdk = @import("sdk");
const dos = sdk.dos;
const timer = sdk.devices.timer;
const battclock = sdk.resources.battclock;
const battmem = sdk.resources.battmem;
const battmembits = sdk.resources.battmembits;
const timezone = dos.timezone;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "SetClock";
const VERSION_STRING = "\x00$VER: SetClock 1.2 (25.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "LOAD/S,SAVE/S,RESET/S,ZONE/S";
const arg_load = 0;
const arg_save = 1;
const arg_reset = 2;
const arg_zone = 3;

/// Where SAVE keeps the date, and LOAD finds it.
const KEPT_FILE = "ENVARC:Sys/clock";
const KEPT_HEADER =
    "# ENVARC:Sys/clock - the date C:SetClock SAVE last kept, in seconds\n" ++
    "# since 1 January 1978: SetClock LOAD starts the system time there\n" ++
    "# when the clock that keeps the date has none, or an earlier one.\n";

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

    if (argv[arg_zone] != 0) {
        const result = keepZone(sys, dl);
        if (result != dos.RETURN_OK) return result;
    }
    if (argv[arg_load] == 0 and argv[arg_save] == 0 and argv[arg_reset] == 0) return dos.RETURN_OK;

    const cb: ?*battclock.BattClockBase = @ptrCast(sys.OpenResource(battclock.BATTCLOCKNAME));
    var request: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &request.node, 0) != 0) {
        _ = dl.PutStr("Can't open timer.device\n");
        return dos.RETURN_FAIL;
    }
    defer sys.CloseDevice(&request.node);

    if (argv[arg_load] != 0) {
        var seconds: u32 = 0;
        if (cb) |clock| {
            seconds = clock.ReadBattClock();
        } else {
            request.node.command = timer.TR_GETSYSTIME;
            if (sys.DoIO(&request.node) != 0) return dos.RETURN_FAIL;
            seconds = request.time.secs;
        }
        if (keptDate(dl)) |kept| seconds = @max(seconds, kept);
        request.node.command = timer.TR_SETSYSTIME;
        request.time = .{ .secs = seconds, .micro = 0 };
        if (sys.DoIO(&request.node) != 0) return dos.RETURN_FAIL;
    } else if (argv[arg_save] != 0) {
        request.node.command = timer.TR_GETSYSTIME;
        if (sys.DoIO(&request.node) != 0) return dos.RETURN_FAIL;
        if (cb) |clock| clock.WriteBattClock(request.time.secs);
        if (!keepDate(dl, request.time.secs)) {
            _ = Printf(dl, "%s: %s could not be written\n", .{ COMMAND_NAME, KEPT_FILE });
            return dos.RETURN_WARN;
        }
    } else if (argv[arg_reset] != 0) {
        const clock = cb orelse {
            _ = dl.PutStr("Can't find a clock that keeps the date\n");
            return dos.RETURN_FAIL;
        };
        clock.ResetBattClock();
    }
    return dos.RETURN_OK;
}

/// The date SAVE last kept, in seconds since 1 January 1978: null when
/// there is no file, or its first line is no number.
fn keptDate(dl: *DosBase) ?u32 {
    var text: [16]u8 = @splat(0);
    const line = firstLine(dl, KEPT_FILE, &text) orelse return null;
    var seconds: u32 = 0;
    for (line) |digit| {
        if (digit < '0' or digit > '9') return null;
        seconds = std.math.mul(u32, seconds, 10) catch return null;
        seconds = std.math.add(u32, seconds, digit - '0') catch return null;
    }
    return seconds;
}

/// `seconds` written to the file LOAD reads: false when it could not be.
fn keepDate(dl: *DosBase, seconds: u32) bool {
    const file = dl.Open(KEPT_FILE, dos.MODE_NEWFILE) orelse return false;
    const written = sdk.dos.stdio.FPrintf(dl, file, KEPT_HEADER ++ "%u\n", .{seconds});
    return dl.Close(file) and written > 0;
}

/// The zone file's rule into battmem.resource's BATTMEM_ZONE.
fn keepZone(sys: *ExecBase, dl: *DosBase) i32 {
    const mb: *battmem.BattMemBase = @ptrCast(sys.OpenResource(battmem.BATTMEMNAME) orelse {
        _ = dl.PutStr("Can't find battmem.resource\n");
        return dos.RETURN_FAIL;
    });
    var text: [128]u8 = @splat(0);
    var zone: timezone.Zone = .{};
    if (firstLine(dl, timezone.zone_file, &text)) |rule| {
        zone = timezone.parse(rule) orelse {
            _ = Printf(dl, "%s: %s is no time zone rule\n", .{ COMMAND_NAME, timezone.zone_file });
            return dos.RETURN_ERROR;
        };
    }
    const bits = timezone.pack(&zone) orelse {
        _ = Printf(dl, "%s: the rule in %s can't be kept: its offsets are not whole quarter hours\n", .{ COMMAND_NAME, timezone.zone_file });
        return dos.RETURN_ERROR;
    };
    if (mb.WriteBattMem(@ptrCast(&bits), battmembits.BATTMEM_ZONE_ADDR, battmembits.BATTMEM_ZONE_LEN) != 0) return dos.RETURN_FAIL;
    return dos.RETURN_OK;
}

/// The first line of the file `name` that is not blank or a `#` comment,
/// without the blanks around it, kept in `text`; null when there is none.
fn firstLine(dl: *DosBase, name: [*:0]const u8, text: []u8) ?[]const u8 {
    const file = dl.Open(name, dos.MODE_OLDFILE) orelse return null;
    defer _ = dl.Close(file);
    var whole: [1024]u8 = undefined;
    const got = dl.Read(file, &whole, whole.len);
    if (got <= 0) return null;
    const length: usize = @intCast(got);
    var line_start: usize = 0;
    while (line_start < length) {
        var end = line_start;
        while (end < length and whole[end] != '\n' and whole[end] != '\r') end += 1;
        const next = end + 1;
        var start = line_start;
        while (start < end and (whole[start] == ' ' or whole[start] == '\t')) start += 1;
        while (end > start and (whole[end - 1] == ' ' or whole[end - 1] == '\t')) end -= 1;
        if (end > start and whole[start] != '#') {
            const kept = @min(end - start, text.len);
            @memcpy(text[0..kept], whole[start..][0..kept]);
            return text[0..kept];
        }
        line_start = next;
    }
    return null;
}
