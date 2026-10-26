// SPDX-License-Identifier: MIT
//! Volume: the output the machine plays through, how loud it is and what
//! its equalizer does, in a small window. Built against the SDK only.
//!
//!   Volume
//!
//! The chooser lists audio.device's outputs and shows the one played
//! through; picking another plays every sound going on through it from
//! then on. The slider is that output's volume, in percent of as
//! recorded, and changes it while it is dragged.
//!
//! Under them is that output's equalizer: a slider for each of its ten
//! bands, 31 Hz to 16 kHz, from -12 dB at the bottom to +12 at the top,
//! with its dB above it and its frequency below. A band changes what is
//! heard while it is dragged. Under them Preset picks a curve by name -
//! Classical, Rock, Techno, Speech, ... (`audiocontrol.presets`) - and
//! shows the one the bands are, or Custom; Flat puts every band back to
//! 0. With a device that has no equalizer the bands are ghosted.
//!
//! All of it is read again every second and whenever the window is made
//! active, so an output plugged in or out, or a volume or equalizer set
//! elsewhere, shows.
//!
//! The window closes with its close gadget or Ctrl-C. When anything was
//! changed, what the device has then - each output's volume and
//! equalizer, and the one preferred - is kept in ENV:Sys/audio.prefs and
//! ENVARC:Sys/audio.prefs, so C:SetPrefs gives it back at the next boot;
//! outputs the file names that are not plugged in keep their lines.

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
const pg = intuition.propgclass;
const sl = sdk.gadgets.slider;
const ch = sdk.gadgets.chooser;
const tx = sdk.gadgets.text;

pub const COMMAND_NAME = "Volume";
const VERSION = "1.2";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (26.10.2026)\r\n";
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
const ID_FLAT = 3;
const ID_PRESET = 4;
/// A band's slider's ID: this and the band.
const ID_BAND = 16;

const band_count = audio.AUDIO_EQ_BANDS;

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
    /// The equalizer shown - the output played through's - whether the
    /// device has one, and its gadgets: a slider and a value for each
    /// band, the value's text, the presets' chooser and the one it shows,
    /// and Flat.
    bands: audiocontrol.Bands = @splat(0),
    equalizes: bool = false,
    band_sliders: [band_count]*Object = undefined,
    band_values: [band_count]*Object = undefined,
    value_texts: [band_count][4:0]u8 = @splat(@splat(0)),
    preset: *Object = undefined,
    preset_shown: usize = 0,
    flat: *Object = undefined,
    /// Whether an output was picked, a volume or a band set here.
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
            const no_bands = app.outputs.count == 0 or !app.equalizes;
            for (app.band_sliders) |slider| app.set(slider, &.{ pair(gc.GA_Disabled, @intFromBool(no_bands)), .{} });
            app.set(app.preset, &.{ pair(gc.GA_Disabled, @intFromBool(no_bands)), .{} });
            app.set(app.flat, &.{ pair(gc.GA_Disabled, @intFromBool(no_bands)), .{} });
        }
        app.lookBands();
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

    /// The equalizer of the output played through read again: the bands
    /// shown anew when it changed.
    fn lookBands(app: *App) void {
        if (!app.equalizes) return;
        var info: audio.AudioOutputInfo = .{};
        const now: audiocontrol.Bands = if (app.control.current(&info)) info.equalizer else @splat(0);
        for (now, app.bands) |band, shown| {
            if (band != shown) break;
        } else return;
        app.bands = now;
        app.showBands();
    }

    /// Every band's slider and value as `bands` has them, and the preset
    /// they are.
    fn showBands(app: *App) void {
        for (0..band_count) |band| {
            app.set(app.band_sliders[band], &.{ pair(sl.SLIDER_Level, @bitCast(@as(isize, app.bands[band]))), .{} });
            app.showValue(band);
        }
        app.showPreset();
    }

    /// The preset the bands are, or Custom, on its chooser.
    fn showPreset(app: *App) void {
        const shown = audiocontrol.presetOf(&app.bands);
        if (shown == app.preset_shown) return;
        app.preset_shown = shown;
        app.set(app.preset, &.{ pair(ch.CHOOSER_Active, shown), .{} });
    }

    /// A band's dB, above its slider.
    fn showValue(app: *App, band: usize) void {
        dbText(&app.value_texts[band], app.bands[band]);
        app.set(app.band_values[band], &.{ pair(tx.TEXT_Text, @intFromPtr(&app.value_texts[band])), .{} });
    }

    /// A band's slider at `level`: the output played through heard with
    /// it at once.
    fn takeBand(app: *App, band: usize, level: isize) void {
        const db: i8 = @intCast(@max(@min(level, audio.AUDIO_EQ_RANGE), -audio.AUDIO_EQ_RANGE));
        if (db == app.bands[band]) return;
        app.bands[band] = db;
        _ = app.control.setEqualizer(0, &app.bands);
        app.showValue(band);
        app.showPreset();
        app.changed = true;
    }

    /// A band's slider as it stands now.
    fn readBand(app: *App, band: usize) void {
        var level: usize = 0;
        _ = app.ib.GetAttr(sl.SLIDER_Level, app.band_sliders[band], &level);
        app.takeBand(band, @bitCast(level));
    }

    /// Flat: every band at 0.
    fn flatten(app: *App) void {
        app.bands = @splat(0);
        _ = app.control.setEqualizer(0, &app.bands);
        app.showBands();
        app.changed = true;
    }

    /// A preset picked: its bands heard at once. Custom changes nothing
    /// and goes back to what the bands are.
    fn takePreset(app: *App, choice: usize) void {
        app.preset_shown = choice;
        if (choice < audiocontrol.presets.len) {
            app.bands = audiocontrol.presets[choice].bands;
            _ = app.control.setEqualizer(0, &app.bands);
            app.changed = true;
        }
        app.showBands();
    }

    /// What a slider says while it is dragged.
    fn updated(app: *App, object: *Object) void {
        var id: usize = 0;
        _ = app.ib.GetAttr(wc.WINDOWA_GadgetID, object, &id);
        if (id >= ID_BAND and id < ID_BAND + band_count) return app.readBand(id - ID_BAND);
        if (id != ID_VOLUME) return;
        var level: usize = 0;
        _ = app.ib.GetAttr(sl.SLIDER_Level, app.volume, &level);
        app.takeVolume(level);
    }

    /// The equalizer's group: for each band its dB, its slider and its
    /// frequency, a column each in a grid, and the presets and Flat under
    /// them; null, with nothing of it left made, when something could not
    /// be.
    fn makeEqualizer(app: *App, ghosted: bool) ?*Object {
        const ib = app.ib;
        // The grid's cells in reading order: the values, the sliders, the
        // frequencies.
        var cells: [3 * band_count]?*Object = @splat(null);
        for (0..band_count) |band| {
            dbText(&app.value_texts[band], app.bands[band]);
            cells[band] = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
                pair(tx.TEXT_Text, @intFromPtr(&app.value_texts[band])),
                pair(tx.TEXT_Justification, tx.TEXT_JUSTIFY_CENTER),
                .{},
            });
            cells[band_count + band] = ib.NewObjectTagList(null, sl.SLIDER_CLASS, &[_]TagItem{
                pair(gc.GA_ID, ID_BAND + band),
                pair(gc.GA_RelVerify, 1),
                pair(gc.GA_Disabled, @intFromBool(ghosted)),
                pair(pg.PGA_Freedom, pg.FREEVERT),
                pair(sl.SLIDER_Min, @bitCast(@as(isize, -audio.AUDIO_EQ_RANGE))),
                pair(sl.SLIDER_Max, audio.AUDIO_EQ_RANGE),
                pair(sl.SLIDER_Level, @bitCast(@as(isize, app.bands[band]))),
                pair(icc.ICA_TARGET, icc.ICTARGET_IDCMP),
                .{},
            });
            cells[2 * band_count + band] = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
                pair(tx.TEXT_Text, @intFromPtr(audiocontrol.band_labels[band])),
                pair(tx.TEXT_Justification, tx.TEXT_JUSTIFY_CENTER),
                .{},
            });
        }
        const preset = ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
            pair(gc.GA_ID, ID_PRESET),
            pair(gc.GA_RelVerify, 1),
            pair(gc.GA_Disabled, @intFromBool(ghosted)),
            pair(ch.CHOOSER_Labels, @intFromPtr(&audiocontrol.preset_labels)),
            pair(ch.CHOOSER_Active, audiocontrol.presetOf(&app.bands)),
            .{},
        });
        const flat = ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
            pair(gc.GA_Text, @intFromPtr("Flat")),
            pair(gc.GA_ID, ID_FLAT),
            pair(gc.GA_RelVerify, 1),
            pair(gc.GA_Disabled, @intFromBool(ghosted)),
            .{},
        });
        const whole = for (cells) |cell| {
            if (cell == null) break false;
        } else preset != null and flat != null;
        if (!whole) {
            for (cells) |cell| if (cell) |made| ib.DisposeObject(made);
            if (preset) |made| ib.DisposeObject(made);
            if (flat) |made| ib.DisposeObject(made);
            return null;
        }
        // The presets and Flat in a row under the bands.
        const bottom = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
            pair(lg.LAYOUTA_Spacing, 6),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(preset.?)),
            pair(lg.CHILDA_Label, @intFromPtr("Preset")),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(flat.?)),
            pair(lg.CHILDA_WeightWidth, 0),
            pair(lg.CHILDA_MinWidth, 64),
            .{},
        }) orelse {
            for (cells) |cell| ib.DisposeObject(cell.?);
            ib.DisposeObject(preset.?);
            ib.DisposeObject(flat.?);
            return null;
        };
        var tags: [3 * band_count + 4]TagItem = undefined;
        tags[0] = pair(lg.LAYOUTA_Orientation, lg.LORIENT_GRID);
        tags[1] = pair(lg.LAYOUTA_Columns, band_count);
        tags[2] = pair(lg.LAYOUTA_Spacing, 4);
        for (cells, 3..) |cell, at| tags[at] = pair(lg.LAYOUTA_AddChild, @intFromPtr(cell.?));
        tags[tags.len - 1] = .{};
        const grid = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &tags) orelse {
            for (cells) |cell| ib.DisposeObject(cell.?);
            ib.DisposeObject(bottom);
            return null;
        };
        const group = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            pair(lg.LAYOUTA_FrameTitle, @intFromPtr("Equalizer")),
            pair(lg.LAYOUTA_Margin, 6),
            pair(lg.LAYOUTA_Spacing, 6),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(grid)),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(bottom)),
            pair(lg.CHILDA_WeightHeight, 0),
            .{},
        }) orelse {
            ib.DisposeObject(grid);
            ib.DisposeObject(bottom);
            return null;
        };
        for (0..band_count) |band| {
            app.band_values[band] = cells[band].?;
            app.band_sliders[band] = cells[band_count + band].?;
        }
        app.preset = preset.?;
        app.preset_shown = audiocontrol.presetOf(&app.bands);
        app.flat = flat.?;
        return group;
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

/// A band's dB as its value shows it: +4, 0, -12.
fn dbText(into: *[4:0]u8, db: i8) void {
    var n: usize = 0;
    if (db != 0) {
        into[0] = if (db > 0) '+' else '-';
        n = 1;
    }
    const size: u8 = @abs(db);
    if (size >= 10) {
        into[n] = '0' + size / 10;
        n += 1;
    }
    into[n] = '0' + size % 10;
    into[n + 1] = 0;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var libraries: [5]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    const wanted = [_][*:0]const u8{ intuition.INTUITIONNAME, motion.MOTIONNAME, sl.SLIDER_LIBRARY, ch.CHOOSER_LIBRARY, tx.TEXT_LIBRARY };
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
    app.equalizes = app.control.hasEqualizer();
    if (app.equalizes) {
        var info: audio.AudioOutputInfo = .{};
        if (app.control.current(&info)) app.bands = info.equalizer;
    }

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
    const equalizer = app.makeEqualizer(none or !app.equalizes) orelse {
        ib.DisposeObject(app.output);
        ib.DisposeObject(app.volume);
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
        pair(lg.LAYOUTA_AddChild, @intFromPtr(equalizer)),
        .{},
    }) orelse {
        ib.DisposeObject(app.output);
        ib.DisposeObject(app.volume);
        ib.DisposeObject(equalizer);
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
                    ID_FLAT => app.flatten(),
                    ID_PRESET => app.takePreset(code),
                    ID_BAND...ID_BAND + band_count - 1 => |id| app.readBand(id - ID_BAND),
                    else => {},
                },
                wc.WMHI_IDCMPUPDATE => app.updated(object),
                wc.WMHI_ACTIVE => app.look(),
                else => {},
            }
        }
    }
}
