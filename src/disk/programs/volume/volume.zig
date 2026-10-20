// SPDX-License-Identifier: MIT
//! Volume: the output the machine plays through and how loud it is, in a
//! small window. Built against the SDK only.
//!
//!   Volume
//!
//! The chooser lists audio.device's outputs and shows the one played
//! through; picking another plays every sound going on through it from
//! then on. The slider is that output's volume, in percent of as
//! recorded, and changes it while it is dragged. Both are read again
//! every second and whenever the window is made active, so an output
//! plugged in or out, or a volume set elsewhere, shows.
//!
//! The window closes with its close gadget or Ctrl-C. When anything was
//! changed, what the device has then - each output's volume and the one
//! preferred - is kept in ENV:Sys/audio.prefs and ENVARC:Sys/audio.prefs,
//! so C:SetPrefs gives it back at the next boot; outputs the file names
//! that are not plugged in keep their lines.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const intuition = sdk.intuition;
const motion = sdk.motion;
const audio = sdk.devices.audio;
const audiocontrol = sdk.devices.audiocontrol;
const prefs = sdk.prefs;
const audio_file = prefs.audio;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const MotionBase = sdk.interface.motion.MotionBase;
const Object = intuition.Object;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wn = intuition.windows;
const wc = intuition.windowclass;
const icc = intuition.icclass;
const classusr = intuition.classusr;
const sl = sdk.gadgets.slider;
const ch = sdk.gadgets.chooser;

pub const COMMAND_NAME = "Volume";
const VERSION = "1.0";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (20.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
/// What the screen's bar says while the window is active.
const SCREEN_TITLE = COMMAND_NAME ++ " " ++ VERSION;

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_NODEVICE = "%s: no %s - this machine has no sound\n";
const MSG_NOMEMORY = "%s: no memory for the gadgets\n";
const MSG_NOWINDOW = "%s: no window\n";
const MSG_NOTSAVED = "%s: %s could not be written\n";

const ID_OUTPUT = 1;
const ID_VOLUME = 2;

/// How often the outputs are read again, in milliseconds.
const look_every = 1000;

fn pair(t: sdk.utility.Tag, data: usize) TagItem {
    return .{ .tag = t, .data = data };
}

const App = struct {
    dl: *DosBase,
    ib: *IntuitionBase,
    control: audiocontrol.Control,
    outputs: audiocontrol.Outputs = .{},
    /// The volume shown, in percent.
    percent: u32 = 0,
    window: ?*intuition.Window = null,
    output: *Object = undefined,
    volume: *Object = undefined,
    /// Whether an output was picked or a volume set here.
    changed: bool = false,

    fn set(app: *App, gadget: *Object, tags: []const TagItem) void {
        _ = app.ib.SetGadgetAttrsTagList(gadget, app.window, tags.ptr);
    }

    /// The volume of the output played through, in percent; 100 with
    /// none.
    fn currentPercent(app: *App) u32 {
        var device: audio.AudioInfo = .{};
        if (!app.control.query(&device)) return 100;
        return audiocontrol.percentOf(device.master);
    }

    /// The outputs and the volume read again: the gadgets shown anew when
    /// they changed.
    fn look(app: *App) void {
        var now: audiocontrol.Outputs = .{};
        now.read(&app.control);
        if (!now.same(&app.outputs)) {
            app.outputs = now;
            for (app.outputs.labels[0..app.outputs.count], 0..) |*label, at| label.* = @ptrCast(&app.outputs.infos[at].name);
            app.set(app.output, &.{
                pair(ch.CHOOSER_Labels, @intFromPtr(&app.outputs.labels)),
                pair(ch.CHOOSER_Active, app.outputs.currentIndex() orelse 0),
                pair(gc.GA_Disabled, @intFromBool(app.outputs.count == 0)),
                .{},
            });
            app.set(app.volume, &.{ pair(gc.GA_Disabled, @intFromBool(app.outputs.count == 0)), .{} });
        }
        const percent = app.currentPercent();
        if (percent == app.percent) return;
        app.percent = percent;
        app.set(app.volume, &.{ pair(sl.SLIDER_Level, percent), .{} });
    }

    /// The output picked: every sound of the machine played through it.
    fn pickOutput(app: *App, index: usize) void {
        if (index < app.outputs.count) {
            _ = app.control.play(app.outputs.infos[index].id);
            app.changed = true;
        }
        app.outputs.count = 0;
        app.look();
    }

    /// The slider moved: the output played through that loud.
    fn takeVolume(app: *App, level: usize) void {
        const percent: u32 = @intCast(@min(level, 100));
        if (percent == app.percent) return;
        app.percent = percent;
        app.control.setVolume(0, percent);
        app.changed = true;
    }

    /// What the slider says while it is dragged.
    fn updated(app: *App, object: *Object) void {
        var id: usize = 0;
        _ = app.ib.GetAttr(wc.WINDOWA_GadgetID, object, &id);
        if (id != ID_VOLUME) return;
        var level: usize = 0;
        _ = app.ib.GetAttr(sl.SLIDER_Level, app.volume, &level);
        app.takeVolume(level);
    }

    /// What the device has now, over the file's outputs, written to ENV:
    /// and ENVARC:.
    fn save(app: *App) void {
        var text: [audio_file.max_file]u8 = undefined;
        var settings: audio_file.Settings = .{};
        if (prefs.load(app.dl, audio_file.ENV_FILE, &text)) |read| _ = settings.load(read);
        audio_file.gather(&app.control, &settings);
        const length = audio_file.write(&settings, &text);
        for ([_][*:0]const u8{ audio_file.ENV_FILE, audio_file.ENVARC_FILE }) |path| {
            if (!prefs.save(app.dl, path, text[0..length])) _ = Printf(app.dl, MSG_NOTSAVED, .{ COMMAND_NAME, path });
        }
    }
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var libraries: [4]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    const wanted = [_][*:0]const u8{ intuition.INTUITIONNAME, motion.MOTIONNAME, sl.SLIDER_LIBRARY, ch.CHOOSER_LIBRARY };
    for (wanted, 0..) |name, i| {
        libraries[i] = sys.OpenLibrary(name, 0) orelse {
            _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, name });
            return dos.RETURN_FAIL;
        };
    }
    const ib: *IntuitionBase = @ptrCast(libraries[0].?);
    const motion_base: *MotionBase = @ptrCast(libraries[1].?);

    var app = App{
        .dl = dl,
        .ib = ib,
        .control = audiocontrol.Control.open(sys) orelse {
            _ = Printf(dl, MSG_NODEVICE, .{ COMMAND_NAME, @as([*:0]const u8, audio.AUDIONAME) });
            return dos.RETURN_WARN;
        },
    };
    defer app.control.close();
    app.outputs.read(&app.control);
    app.percent = app.currentPercent();

    const none = app.outputs.count == 0;
    app.output = ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_OUTPUT),
        pair(gc.GA_RelVerify, 1),
        pair(ch.CHOOSER_Labels, @intFromPtr(&app.outputs.labels)),
        pair(ch.CHOOSER_Active, app.outputs.currentIndex() orelse 0),
        pair(gc.GA_Disabled, @intFromBool(none)),
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    app.volume = ib.NewObjectTagList(null, sl.SLIDER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_VOLUME),
        pair(gc.GA_RelVerify, 1),
        pair(gc.GA_Disabled, @intFromBool(none)),
        pair(sl.SLIDER_Max, 100),
        pair(sl.SLIDER_Level, app.percent),
        pair(sl.SLIDER_LevelFormat, @intFromPtr("%ld%%")),
        pair(sl.SLIDER_MaxLevelLen, 4),
        pair(icc.ICA_TARGET, icc.ICTARGET_IDCMP),
        pair(gc.GA_Width, 160),
        .{},
    }) orelse {
        ib.DisposeObject(app.output);
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    const layout = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Margin, 8),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.output)),
        pair(lg.CHILDA_Label, @intFromPtr("_Output")),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.volume)),
        pair(lg.CHILDA_Label, @intFromPtr("_Volume")),
        pair(lg.CHILDA_WeightHeight, 0),
        .{},
    }) orelse {
        ib.DisposeObject(app.output);
        ib.DisposeObject(app.volume);
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        pair(wn.WA_Title, @intFromPtr(COMMAND_NAME)),
        pair(wn.WA_ScreenTitle, @intFromPtr(SCREEN_TITLE)),
        pair(wn.WA_CloseGadget, 1),
        pair(wn.WA_DragBar, 1),
        pair(wn.WA_DepthGadget, 1),
        pair(wn.WA_Activate, 1),
        pair(wn.WA_IDCMP, wn.IDCMP_IDCMPUPDATE | wn.IDCMP_ACTIVEWINDOW),
        pair(wc.WINDOWA_Layout, @intFromPtr(layout)),
        .{},
    }) orelse {
        ib.DisposeObject(layout);
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    defer ib.DisposeObject(object);
    defer if (app.changed) app.save();

    var open = wc.WmOpen{};
    if (ib.SendMessage(object, @ptrCast(&open)) == 0) {
        _ = Printf(dl, MSG_NOWINDOW, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    }
    var window_pointer: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_Window, object, &window_pointer);
    const window: *intuition.Window = @ptrFromInt(window_pointer);
    app.window = window;

    const bit = sys.AllocSignal(-1);
    if (bit < 0) return dos.RETURN_FAIL;
    defer sys.FreeSignal(bit);
    const tick = motion_base.CreateTimerTagList(&[_]TagItem{
        pair(motion.TIMER_Period, look_every),
        pair(motion.TIMER_Repeat, motion.TIMER_FOREVER),
        pair(motion.TIMER_Signal, @intCast(bit)),
        .{},
    }) orelse return dos.RETURN_FAIL;
    defer motion_base.DeleteTimer(tick);
    motion_base.StartTimer(tick);
    const tick_mask = @as(u32, 1) << @intCast(bit);

    var code: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code };
    while (true) {
        const got = ib.WaitIMsg(window, tick_mask | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_OK;
        if (got & tick_mask != 0) app.look();
        while (true) {
            const word = ib.SendMessage(object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => return dos.RETURN_OK,
                wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
                    ID_OUTPUT => app.pickOutput(code),
                    ID_VOLUME => app.takeVolume(code),
                    else => {},
                },
                wc.WMHI_IDCMPUPDATE => app.updated(object),
                wc.WMHI_ACTIVE => app.look(),
                else => {},
            }
        }
    }
}
