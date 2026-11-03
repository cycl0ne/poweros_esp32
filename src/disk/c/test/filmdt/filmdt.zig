// SPDX-License-Identifier: MIT
//! FilmDT: a film played in a window through datatypes.library, and what
//! it says about itself while it plays. Built against the SDK only.
//!
//!   FilmDT FILE/A,SECONDS/K/N,PUBSCREEN/K
//!
//! The file is opened as a `videocodec.datatype` object - whatever kind
//! of film it is, MP4, MOV, MKV or WebM - put in a window of its own and
//! played, and this prints what the object answers as it goes: what the
//! film is, where it is every second, that a pause holds it where it is,
//! that a move lands near where it was asked for and that playing on from
//! there goes on from there. `SECONDS` is how long it plays before the
//! pause (5).
//!
//! **The program does nothing while the film plays.** The object decodes
//! on a process of its own and asks intuition to draw it, so this one
//! only waits and asks it questions - which is the point of the test: a
//! film in a window costs the program that opened it nothing.
//!
//! Ctrl-C ends it at once. What it prints is meant to be read beside
//! `C:test/film`, which plays the same file through videocodec.library
//! without a window.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const utility = sdk.utility;
const intuition = sdk.intuition;
const datatypes = sdk.datatypes;
const vc = sdk.videocodec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const DataTypesBase = sdk.interface.datatypes.DataTypesBase;
const dtc = datatypes.datatypesclass;
const vdt = datatypes.movieclass;
const wn = intuition.windows;
const wc = intuition.windowclass;
const lg = intuition.layoutgclass;
const gc = intuition.gadgetclass;
const classusr = intuition.classusr;
const Object = intuition.Object;
const TagItem = utility.TagItem;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "FilmDT";
const VERSION_STRING = "\x00$VER: FilmDT 1.0 (04.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FILE/A,SECONDS/K/N,PUBSCREEN/K";
const arg_file = 0;
const arg_seconds = 1;
const arg_pubscreen = 2;

const MSG_NOLIBRARY = "%s: no %s\n";
const MSG_CANNOT = "%s: %s\n";
const MSG_NOSCREEN = "%s: no screen\n";
const MSG_NOWINDOW = "%s: no window\n";
const MSG_WHAT = "%s: %u x %u, %u pictures a second, %u ms, %s\n";
const MSG_SOUND = "  sound: codec %u, %u Hz, %u channels, volume %u%%\n";
const MSG_NOSOUND = "  no sound this machine decodes\n";
const MSG_AT = "  %s: %u ms%s\n";
const MSG_HELD = "  paused at %u ms, and %u ms a second later%s\n";
const MSG_MOVED = "  moved to %u ms, landed at %u ms%s\n";
const MSG_WENT_ON = "  played on from there to %u ms%s\n";
const MSG_STOPPED = "  stopped: %u ms after %u ms of waiting, playing %u%s\n";
const MSG_GONE = "%s: the window closed and the object disposed of\n";

/// A second of the system's clock.
const a_second = 50;

fn ask(dt: *DataTypesBase, object: *Object, attr: utility.Tag) u32 {
    var value: usize = 0;
    _ = dt.GetDTAttrsA(object, &[_]TagItem{ .{ .tag = attr, .data = @intFromPtr(&value) }, .{} });
    return @truncate(value);
}

fn tell(dt: *DataTypesBase, object: *Object, what: u32) void {
    var trigger = dtc.DtTrigger{ .function = what };
    _ = dt.DoDTMethodA(object, null, null, @ptrCast(&trigger));
}

/// "yes" where a number is as it should be, and "NO" where it is not, so
/// that a run can be read without the numbers being worked out.
fn verdict(right: bool) [*:0]const u8 {
    return if (right) "" else "  <- not as it should be";
}

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
    const seconds: u32 = @intCast(@min(@max(rdargs.number(argv[arg_seconds]) orelse 5, 1), 600));

    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, intuition.INTUITIONNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);

    const dt_lib = sys.OpenLibrary(datatypes.DATATYPESNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, datatypes.DATATYPESNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(dt_lib);
    const dt: *DataTypesBase = @ptrCast(dt_lib);

    const screen_name: ?[*:0]const u8 = @ptrFromInt(argv[arg_pubscreen]);
    const screen = ib.LockPubScreen(screen_name) orelse {
        _ = Printf(dl, MSG_NOSCREEN, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    defer ib.UnlockPubScreen(null, screen);

    // The group refuses anything that is not a film, so a sound file
    // named by mistake is said to be the wrong kind rather than played.
    const object = dt.NewDTObjectA(file, &[_]TagItem{
        .{ .tag = dtc.DTA_GroupID, .data = datatypes.GID_MOVIE },
        .{ .tag = dtc.DTA_Title, .data = @intFromPtr(dl.FilePart(file)) },
        .{},
    }) orelse {
        const failure = dl.IoErr();
        if (failure >= datatypes.DTERROR_UNKNOWN_DATATYPE) {
            _ = Printf(dl, MSG_CANNOT, .{ file, dt.GetDTString(@intCast(failure)) });
        } else {
            _ = dl.PrintFault(failure, file);
        }
        return dos.RETURN_ERROR;
    };

    // What the film is, before it is in a window: the object knew it as
    // it was made.
    const width = ask(dt, object, vdt.VDTA_Width);
    const height = ask(dt, object, vdt.VDTA_Height);
    const duration = ask(dt, object, vdt.VDTA_Duration);
    const seekable = ask(dt, object, vdt.VDTA_Seekable);
    _ = Printf(dl, MSG_WHAT, .{
        dl.FilePart(file),
        width,
        height,
        ask(dt, object, vdt.VDTA_FramesPerSecond),
        duration,
        @as([*:0]const u8, if (seekable != 0) "can be moved" else "cannot be moved"),
    });
    if (ask(dt, object, vdt.VDTA_SoundCodec) != 0) {
        _ = Printf(dl, MSG_SOUND, .{
            ask(dt, object, vdt.VDTA_SoundCodec),
            ask(dt, object, vdt.VDTA_SoundRate),
            ask(dt, object, vdt.VDTA_SoundChannels),
            ask(dt, object, vdt.VDTA_Volume),
        });
    } else _ = Printf(dl, MSG_NOSOUND, .{});

    // From here on the object is the layout's child, and the layout the
    // window's: the window disposes of both.
    const layout = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(object) },
        .{},
    }) orelse {
        dt.DisposeDTObject(object);
        _ = Printf(dl, MSG_NOWINDOW, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    const window_object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr(dl.FilePart(file)) },
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_AutoAdjust, .data = 1 },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_CLOSEWINDOW },
        .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(layout) },
        .{},
    }) orelse {
        ib.DisposeObject(layout); // and the object in it
        _ = Printf(dl, MSG_NOWINDOW, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    var open = wc.WmOpen{};
    if (ib.SendMessage(window_object, @ptrCast(&open)) == 0) {
        ib.DisposeObject(window_object);
        _ = Printf(dl, MSG_NOWINDOW, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    }

    // The film is laid out by now - the window object did that as it
    // opened - so the player's process is there and the first picture is
    // up. Playing, pausing and moving are all the object's own work.
    _ = Printf(dl, MSG_AT, .{ @as([*:0]const u8, "the first picture"), ask(dt, object, vdt.VDTA_Position), verdict(true) });
    tell(dt, object, dtc.STM_PLAY);
    // A second of the clock, a second of film - as far as the machine
    // keeps up with it: an AV1 film in software is slower than it is
    // long, and then the pictures, which is what the position counts,
    // come a few a second. What is asked of the numbers here is only
    // that they move.
    for (0..seconds) |_| {
        _ = dl.Delay(a_second);
        _ = Printf(dl, MSG_AT, .{ @as([*:0]const u8, "playing"), ask(dt, object, vdt.VDTA_Position), verdict(true) });
    }
    const playing = ask(dt, object, vdt.VDTA_Playing);
    const went_on = ask(dt, object, vdt.VDTA_Position) > 0;

    // A pause holds it where it is.
    tell(dt, object, dtc.STM_PAUSE);
    const held = ask(dt, object, vdt.VDTA_Position);
    _ = dl.Delay(a_second);
    const still = ask(dt, object, vdt.VDTA_Position);
    _ = Printf(dl, MSG_HELD, .{ held, still, verdict(still == held) });

    // A move lands at the key frame at or before the time asked for.
    if (seekable != 0 and duration > 4000) {
        const asked = duration / 2;
        var locate = dtc.DtTrigger{ .function = dtc.STM_LOCATE, .data = @ptrFromInt(asked) };
        _ = dt.DoDTMethodA(object, null, null, @ptrCast(&locate));
        _ = dl.Delay(a_second);
        const landed = ask(dt, object, vdt.VDTA_Position);
        // At or before where it was asked for, and not more than ten
        // seconds before it: a film's key frames are seconds apart.
        _ = Printf(dl, MSG_MOVED, .{ asked, landed, verdict(landed <= asked + 1000 and landed + 10_000 >= asked) });
        tell(dt, object, dtc.STM_PLAY);
        _ = dl.Delay(2 * a_second);
        const after = ask(dt, object, vdt.VDTA_Position);
        _ = Printf(dl, MSG_WENT_ON, .{ after, verdict(after > landed) });
    }

    // Stopped: back to the start, standing. The order is done between
    // one picture and the next, and halting the sound and moving the
    // film take what they take, so this waits for it rather than looking
    // once: how long it took is worth seeing.
    tell(dt, object, dtc.STM_STOP);
    var waited: u32 = 0;
    var at_stop = ask(dt, object, vdt.VDTA_Position);
    while (at_stop != 0 and waited < 5000) {
        _ = dl.Delay(a_second / 10);
        waited += 100;
        at_stop = ask(dt, object, vdt.VDTA_Position);
    }
    _ = Printf(dl, MSG_STOPPED, .{ at_stop, waited, ask(dt, object, vdt.VDTA_Playing), verdict(at_stop == 0) });

    // The window, the layout and the object together - while the film is
    // still open, which is the way a program ends with one.
    tell(dt, object, dtc.STM_PLAY);
    _ = dl.Delay(a_second / 2);
    ib.DisposeObject(window_object);
    _ = Printf(dl, MSG_GONE, .{COMMAND_NAME});
    return if (playing != 0 and went_on) dos.RETURN_OK else dos.RETURN_WARN;
}
