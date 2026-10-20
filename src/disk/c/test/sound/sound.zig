// SPDX-License-Identifier: MIT
//! Sound: a sound file played through datatypes.library, with no window.
//! Built against the SDK only.
//!
//!   Sound FILE/A,VOLUME/K/N,CYCLES/K/N
//!
//! The file is opened as a `sound.datatype` object - whatever kind it is,
//! WAV, MP3, 8SVX - and played with `STM_PLAY`; the object says
//! when it has played out, by the signal `SDTA_SignalTask` and
//! `SDTA_SignalBit` name, and the command ends. VOLUME is in percent of
//! as recorded (100), CYCLES how many times it plays (1). Ctrl-C stops
//! it. What it prints first is what the object says the sound is.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const datatypes = sdk.datatypes;
const audio = sdk.devices.audio;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const DataTypesBase = sdk.interface.datatypes.DataTypesBase;
const dtc = datatypes.datatypesclass;
const sdt = datatypes.soundclass;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;
const TagItem = utility.TagItem;

pub const COMMAND_NAME = "Sound";
const VERSION_STRING = "\x00$VER: Sound 1.0 (13.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FILE/A,VOLUME/K/N,CYCLES/K/N";
const arg_file = 0;
const arg_volume = 1;
const arg_cycles = 2;

const MSG_NOLIBRARY = "%s: no %s\n";
const MSG_WHAT = "%s: %u Hz, %u channels, %u:%02u\n";
const MSG_DONE = "%s: played out\n";
const MSG_CANNOT = "%s: %s\n";

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [3]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const file: [*:0]const u8 = @ptrFromInt(argv[arg_file]);
    const percent: u32 = @intCast(@min(@max(rdargs.number(argv[arg_volume]) orelse 100, 0), 400));
    const cycles: u32 = @intCast(@max(rdargs.number(argv[arg_cycles]) orelse 1, 0));

    const dt_lib = sys.OpenLibrary(datatypes.DATATYPESNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, datatypes.DATATYPESNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(dt_lib);
    const dt: *DataTypesBase = @ptrCast(dt_lib);

    const bit = sys.AllocSignal(-1);
    if (bit < 0) return dos.RETURN_FAIL;
    defer sys.FreeSignal(bit);
    const done_mask = @as(u32, 1) << @intCast(bit);

    const sound = dt.NewDTObjectA(file, &[_]TagItem{
        .{ .tag = dtc.DTA_GroupID, .data = datatypes.GID_SOUND },
        .{ .tag = sdt.SDTA_Volume, .data = audio.AUDIO_VOLUME_UNITY / 100 * percent },
        .{ .tag = sdt.SDTA_Cycles, .data = cycles },
        .{ .tag = sdt.SDTA_SignalTask, .data = @intFromPtr(sys.FindTask(null)) },
        .{ .tag = sdt.SDTA_SignalBit, .data = @as(u32, @intCast(bit)) },
        .{},
    }) orelse {
        // datatypes.library's own errors are its words; the rest dos's.
        const failure = dl.IoErr();
        if (failure >= datatypes.DTERROR_UNKNOWN_DATATYPE) {
            _ = Printf(dl, MSG_CANNOT, .{ file, dt.GetDTString(@intCast(failure)) });
        } else {
            _ = dl.PrintFault(failure, file);
        }
        return dos.RETURN_ERROR;
    };
    defer dt.DisposeDTObject(sound);

    var rate: usize = 0;
    var channels: usize = 0;
    var frames: usize = 0;
    _ = dt.GetDTAttrsA(sound, &[_]TagItem{
        .{ .tag = sdt.SDTA_SampleRate, .data = @intFromPtr(&rate) },
        .{ .tag = sdt.SDTA_Channels, .data = @intFromPtr(&channels) },
        .{ .tag = sdt.SDTA_Frames, .data = @intFromPtr(&frames) },
        .{},
    });
    const seconds: u32 = @intCast(frames / @max(rate, 1));
    _ = Printf(dl, MSG_WHAT, .{ dl.FilePart(file), @as(u32, @intCast(rate)), @as(u32, @intCast(channels)), seconds / 60, seconds % 60 });

    _ = sys.SetSignal(0, done_mask | exec.SIGBREAKF_CTRL_C);
    var play = dtc.DtTrigger{ .function = dtc.STM_PLAY };
    _ = dt.DoDTMethodA(sound, null, null, @ptrCast(&play));
    const got = sys.Wait(done_mask | exec.SIGBREAKF_CTRL_C);
    if (got & exec.SIGBREAKF_CTRL_C != 0) {
        var stop = dtc.DtTrigger{ .function = dtc.STM_STOP };
        _ = dt.DoDTMethodA(sound, null, null, @ptrCast(&stop));
        _ = dl.PrintFault(dos.ERROR_BREAK, COMMAND_NAME);
        return dos.RETURN_WARN;
    }
    _ = Printf(dl, MSG_DONE, .{COMMAND_NAME});
    return dos.RETURN_OK;
}
