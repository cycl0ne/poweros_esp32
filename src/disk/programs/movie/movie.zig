// SPDX-License-Identifier: MIT
//! Movie: films played in a window - MP4, QuickTime's MOV and Matroska's
//! MKV, their pictures in H.264, H.265 or Motion JPEG and their sound in
//! AAC, or in an MKV MP3, FLAC or Vorbis too - by videocodec.library.
//!
//!   Movie FILE,VOLUME/K/N,FULL/S
//!
//! `FILE` is the film; without one a file requester asks for it. `VOLUME`
//! is in percent of as recorded, 100 the default; `FULL` starts over the
//! whole screen.
//!
//! **The window** is the picture over a row of controls: the tape deck -
//! back ten seconds, play and pause, on ten seconds, stop - the place in
//! the film, which can be dragged, the time and the film's length, and
//! the volume. The picture keeps its shape in whatever size the window
//! is given, black where it does not reach. The space bar pauses and goes
//! on, left and right go back and on ten seconds, up and down are the
//! volume, F - or a double-click on the picture - shows the film over the
//! whole screen, which F, Esc or a click leaves again.
//!
//! **The sound sets the time.** It plays on a process of its own
//! (sound.zig), which keeps audio.device fed; the window decodes the
//! pictures and shows each when what is heard has come to its time -
//! audio.device's position, less the output's latency. A picture whose
//! time is past by more than a frame is given back unshown, up to a few
//! in a row, so a machine too slow for the film still shows some of it;
//! one not yet due is waited for by timer.device, with the window's
//! messages answered meanwhile. A film without sound - or whose sound has
//! played out before its pictures - keeps time by the timer instead.
//!
//! **Moving** - the slider let go, the keys, the deck - goes to the key
//! frame at or before the time asked for, where a decoder can start, and
//! the clock starts there: the sound is halted, the film moved and the
//! sound started again from the same place.
//!
//! **The picture** is handed as it is to a video layer where the
//! screen's display has one (rtg's `OpenVideoLayer`): the display's
//! controller reads the frame, turns it into colours and scales it
//! itself, under the screen's picture, seen where its place is filled
//! with the layer's key colour - so a window in front hides the film as
//! it hides anything. The place follows the window, the canvas in it and
//! the screen's top edge. Elsewhere - no layer, none free, a frame it
//! cannot take - the picture is put down by graphics.library:
//! `WriteYUVPixelArray` when it is shown at its own size,
//! `ScaleYUVPixelArray` - the nearest pixel - when not. Either way it is
//! drawn into a canvas gadget, which keeps it - or the key colour - for
//! when the window is uncovered, or straight into the whole screen's
//! window.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const rtg = sdk.rtg;
const vc = sdk.videocodec;
const timer = sdk.devices.timer;
const keyboard = sdk.devices.keyboard;
const ie = sdk.devices.inputevent;
const asl = sdk.asl;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const RtgBase = sdk.interface.rtg.RtgBase;
const VideoCodecBase = sdk.interface.videocodec.VideoCodecBase;
const AslBase = sdk.interface.asl.AslBase;
const TimerBase = timer.TimerBase;
const Object = intuition.Object;
const Window = intuition.Window;
const TagItem = sdk.utility.TagItem;
const Rect = graphics.Rect;
const rdargs = dos.rdargs;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wn = intuition.windows;
const wc = intuition.windowclass;
const icc = intuition.icclass;
const classusr = intuition.classusr;
const mn = intuition.menus;
const sc = intuition.screens;
const tx = sdk.gadgets.text;
const sl = sdk.gadgets.slider;
const td = sdk.gadgets.tapedeck;
const cv = sdk.gadgets.canvas;
const strings = @import("strings");
const Text = sdk.locale.Strings(strings);
const Id = strings.Id;
const Sound = @import("sound.zig").Sound;
const Whole = @import("whole.zig").Whole;

pub const COMMAND_NAME = "Movie";
const VERSION = "1.0";
const DATE = "30.10.2026";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (" ++ DATE ++ ")\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
/// What the screen's bar says while the window is active.
const SCREEN_TITLE = COMMAND_NAME ++ " " ++ VERSION;
/// What About says first.
const ABOUT_VERSION = COMMAND_NAME ++ " " ++ VERSION ++ " (" ++ DATE ++ ")";

const template = "FILE,VOLUME/K/N,FULL/S";
const arg_file = 0;
const arg_volume = 1;
const arg_full = 2;

const ID_DECK = 1;
const ID_POSITION = 2;
const ID_VOLUME = 3;
const ID_PICTURE = 4;

const MENU_PROJECT = 0;
const ITEM_OPEN = 0;
const ITEM_WHOLE = 1;
const ITEM_ABOUT = 3;
const ITEM_QUIT = 4;

/// The files the requester shows.
const open_pattern = "#?.(mp4|m4v|mov|mkv)";
/// How far the keys and the deck's wind buttons move.
const jump_seconds = 10;
/// The volume's steps on the keys, and most.
const volume_step = 5;
const volume_most = 100;
const volume_width = 100;
/// Pictures late by more than a frame given back unshown in a row, at
/// most: then one is shown however late, so a film too much for the
/// machine still moves.
const most_dropped = 4;
/// Pictures the decoder may stop on in a row before the film is taken to
/// have ended.
const most_corrupt = 16;
/// The window's picture at most this part of the screen, at the start.
const start_part_num = 2;
const start_part_den = 3;
/// What the time beside the slider needs room for.
const room_short: [*:0]const u8 = "00:00 / 00:00";
const room_long: [*:0]const u8 = "0:00:00 / 0:00:00";
const hour = 3600;

const State = enum { paused, playing, ended };

/// A menu's entry, and the string its label is.
const MenuEntry = struct { menu: mn.NewMenu, text: ?Id = null };

fn menuTitle(text: Id) MenuEntry {
    return .{ .menu = .{ .type = mn.NM_TITLE, .label = strings.builtin(text) }, .text = text };
}

fn menuItem(text: Id, key: ?[*:0]const u8) MenuEntry {
    return .{ .menu = .{ .type = mn.NM_ITEM, .label = strings.builtin(text), .comm_key = key }, .text = text };
}

const bar = MenuEntry{ .menu = .{ .type = mn.NM_ITEM, .label = mn.NM_BARLABEL } };

const menus = [_]MenuEntry{
    menuTitle(.MSG_MENU_PROJECT),
    menuItem(.MSG_MENU_OPEN, "O"),
    menuItem(.MSG_MENU_WHOLE_SCREEN, "F"),
    bar,
    menuItem(.MSG_MENU_ABOUT, null),
    menuItem(.MSG_MENU_QUIT, "Q"),
    .{ .menu = .{} },
};

fn pair(t: sdk.utility.Tag, data: usize) TagItem {
    return .{ .tag = t, .data = data };
}

/// Where a picture `width` by `height` goes in `area`, as large as fits
/// and its shape kept, in the middle.
fn fit(area: Rect, width: u32, height: u32) Rect {
    const room_w: i64 = area.width();
    const room_h: i64 = area.height();
    if (width == 0 or height == 0 or room_w <= 0 or room_h <= 0) return .{ .min_x = area.min_x, .min_y = area.min_y, .max_x = area.min_x, .max_y = area.min_y };
    var w: i64 = room_w;
    var h: i64 = @divTrunc(w * height, width);
    if (h > room_h) {
        h = room_h;
        w = @max(@divTrunc(h * width, height), 1);
    }
    h = @max(h, 1);
    const x = area.min_x + @as(i32, @intCast(@divTrunc(room_w - w, 2)));
    const y = area.min_y + @as(i32, @intCast(@divTrunc(room_h - h, 2)));
    return .{ .min_x = x, .min_y = y, .max_x = x + @as(i32, @intCast(w)), .max_y = y + @as(i32, @intCast(h)) };
}

const App = struct {
    sys: *ExecBase,
    dl: *DosBase,
    text: *const Text,
    ib: *IntuitionBase,
    gb: *GraphicsBase,
    vcb: *VideoCodecBase,
    tb: *TimerBase,
    al: ?*AslBase,

    // --- the film -------------------------------------------------------------
    film: ?*vc.VideoStream = null,
    info: vc.VideoStreamInfo = .{},
    sound: ?*Sound = null,
    state: State = .paused,
    /// The name it was opened by, and the window's title made of it.
    name: [dos.path_max + 1:0]u8 = @splat(0),
    window_title: [160:0]u8 = @splat(0),
    /// A frame's time, in microseconds, as the film's rate says.
    frame_us: i64 = 40_000,
    /// The volume, in percent.
    level: u32 = 100,

    // --- the pictures -----------------------------------------------------------
    /// The frame shown - lent, kept until the next is shown - and the one
    /// decoded that waits its turn.
    shown: ?vc.VideoFrame = null,
    waiting: ?vc.VideoFrame = null,
    /// The decoder has handed out the last picture.
    pictures_ended: bool = false,
    /// The next picture shown whatever its time: the first after a start
    /// or a move.
    fresh: bool = true,
    dropped_in_row: u32 = 0,
    /// The timer keeps the time - no sound, or it has played out - from
    /// `clock_time` at the uptime `clock_at`; still, while paused.
    timer_clock: bool = true,
    clock_time: i64 = 0,
    clock_at: u64 = 0,
    /// The request a picture not yet due is waited for by.
    due: timer.TimeRequest = .{},
    due_port: ?*exec.MsgPort = null,
    due_pending: bool = false,

    // --- the video layer --------------------------------------------------------
    /// rtg.library and the screen's display, where it can be asked for a
    /// layer; the layer the pictures are handed to while there is one, and
    /// its place on the display as last told.
    rb: ?*RtgBase = null,
    board: ?*rtg.RtgBoard = null,
    layer: ?*rtg.RtgVideoLayer = null,
    layer_place: rtg.RtgRect = .{},

    // --- the window -------------------------------------------------------------
    object: *Object = undefined,
    window: *Window = undefined,
    screen: *intuition.Screen = undefined,
    canvas: *Object = undefined,
    deck: *Object = undefined,
    position: *Object = undefined,
    time: *Object = undefined,
    volume: *Object = undefined,
    strip: ?*intuition.Menu = null,
    /// The canvas's RastPort and size, and where in it the picture went
    /// last: the bars around it are filled again when that changes.
    rast_port: ?*graphics.RastPort = null,
    canvas_area: Rect = .{},
    canvas_box: Rect = .{},
    /// The film over the whole screen, while it is, and where in it the
    /// picture went last.
    whole: ?Whole = null,
    whole_box: Rect = .{},
    /// The time beside the slider, the second it shows, and whether the
    /// film is long enough for hours.
    time_text: [32:0]u8 = @splat(0),
    shown_second: u32 = ~@as(u32, 0),
    long: bool = false,
    /// The slider is being dragged: the time follows it, not the film.
    dragging: bool = false,
    /// The first press of a double-click on the picture.
    pressed: bool = false,
    pressed_seconds: u32 = 0,
    pressed_micros: u32 = 0,

    fn set(app: *App, gadget: *Object, tags: []const TagItem) void {
        _ = app.ib.SetGadgetAttrsTagList(gadget, app.window, tags.ptr);
    }

    // --- the clock --------------------------------------------------------------

    /// Microseconds since the machine started.
    fn uptime(app: *App) u64 {
        var ev: timer.EClockVal = .{};
        const rate: u64 = @max(app.tb.ReadEClock(&ev), 1);
        const ticks = ev.toTicks();
        return ticks / rate * 1_000_000 + ticks % rate * 1_000_000 / rate;
    }

    /// The film's time now: what is heard, or the timer's.
    fn now(app: *App) i64 {
        if (!app.timer_clock) {
            if (app.sound) |sound| {
                if (sound.heard()) |heard| return heard;
            }
        }
        if (app.state != .playing) return app.clock_time;
        return app.clock_time + @as(i64, @intCast(app.uptime() - app.clock_at));
    }

    /// The timer's time set to `time` from now.
    fn setClock(app: *App, time: i64) void {
        app.clock_time = time;
        app.clock_at = app.uptime();
    }

    /// The pictures' turn again after `us` microseconds - at once for 0.
    fn arm(app: *App, us: i64) void {
        app.disarm();
        if (app.due_port == null) return;
        app.due.node.command = timer.TR_ADDREQUEST;
        app.due.time = timer.TimeVal.fromMicros(@intCast(@max(us, 0)));
        app.sys.SendIO(&app.due.node);
        app.due_pending = true;
    }

    fn disarm(app: *App) void {
        if (!app.due_pending) return;
        _ = app.sys.AbortIO(&app.due.node);
        _ = app.sys.WaitIO(&app.due.node);
        app.due_pending = false;
    }

    fn dueSignal(app: *const App) u32 {
        return if (app.due_port) |port| port.sigMask() else 0;
    }

    // --- the film ---------------------------------------------------------------

    /// `path` opened: the film the window plays, from its start, the one
    /// before let go of. Null, or why it cannot be - VCERR_* - with the one
    /// before still playing.
    fn openFilm(app: *App, path: [*:0]const u8) i32 {
        var err: i32 = 0;
        const film = app.vcb.OpenVideoStream(&[_]TagItem{ pair(vc.VCA_Name, @intFromPtr(path)), .{} }, &err) orelse return if (err != 0) err else vc.VCERR_OPEN;
        app.closeFilm();
        app.film = film;
        app.info = .{};
        app.vcb.GetVideoStreamInfo(film, &app.info);
        app.frame_us = if (app.info.rate_num != 0) @intCast(@as(u64, 1_000_000) * @max(app.info.rate_den, 1) / app.info.rate_num) else 40_000;
        app.long = app.info.duration >= @as(u64, hour) * 1_000_000;
        var length: usize = 0;
        while (path[length] != 0 and length < app.name.len) : (length += 1) app.name[length] = path[length];
        app.name[length] = 0;
        if (app.info.sound_codec != 0) app.sound = Sound.create(app.sys, app.dl, app.vcb, film, &app.info, app.level);
        app.pictures_ended = false;
        app.fresh = true;
        app.dropped_in_row = 0;
        app.state = .paused;
        app.timer_clock = true;
        app.setClock(0);
        return vc.VCERR_OK;
    }

    /// The film let go of: the sound ended, the layer given back before
    /// the frame it shows, the frames given back.
    fn closeFilm(app: *App) void {
        app.disarm();
        app.closeLayer();
        if (app.sound) |sound| sound.destroy();
        app.sound = null;
        const film = app.film orelse return;
        if (app.waiting) |*frame| app.vcb.ReleaseVideoFrame(film, frame);
        if (app.shown) |*frame| app.vcb.ReleaseVideoFrame(film, frame);
        app.waiting = null;
        app.shown = null;
        app.vcb.CloseVideoStream(film);
        app.film = null;
    }

    /// Whether the time is heard rather than counted: a sound that plays.
    fn soundKeepsTime(app: *const App) bool {
        const sound = app.sound orelse return false;
        return sound.opened and sound.state != .ended;
    }

    fn play(app: *App) void {
        if (app.film == null) return;
        switch (app.state) {
            .playing => {},
            .paused => {
                if (app.sound) |sound| sound.pause(false);
                app.timer_clock = !app.soundKeepsTime();
                app.state = .playing;
                app.setClock(app.clock_time);
            },
            .ended => {
                app.moveTo(0);
                return app.play();
            },
        }
        app.showDeck();
        app.arm(0);
    }

    fn pause(app: *App) void {
        if (app.state != .playing) return;
        app.clock_time = app.now();
        if (app.sound) |sound| sound.pause(true);
        app.state = .paused;
        app.disarm();
        app.showDeck();
    }

    fn togglePause(app: *App) void {
        if (app.state == .playing) app.pause() else app.play();
    }

    /// Back to the start, paused.
    fn stop(app: *App) void {
        if (app.state == .playing) app.pause();
        app.moveTo(0);
        app.showDeck();
    }

    /// The film moved to the key frame at or before `time`, playing or
    /// paused as it was - paused after its end - and the key frame shown
    /// at once when paused.
    fn moveTo(app: *App, time: i64) void {
        const film = app.film orelse return;
        if (app.info.seekable == 0) return;
        if (app.sound) |sound| sound.halt();
        app.disarm();
        if (app.waiting) |*frame| app.vcb.ReleaseVideoFrame(film, frame);
        app.waiting = null;
        const most: i64 = @intCast(@min(app.info.duration, @as(u64, 1) << 62));
        const asked = @max(@min(time, most), 0);
        var landed = app.vcb.SeekVideo(film, asked);
        if (landed < 0) landed = 0;
        app.pictures_ended = false;
        app.fresh = true;
        app.dropped_in_row = 0;
        if (app.state == .ended) app.state = .paused;
        const held = app.state == .paused;
        if (app.sound) |sound| sound.start(landed, held);
        app.timer_clock = !app.soundKeepsTime();
        app.setClock(landed);
        app.shown_second = ~@as(u32, 0);
        app.showTime(landed);
        if (held) {
            // The picture follows the slider while the film stands.
            if (app.decodeNext()) app.showWaiting();
        } else app.arm(0);
    }

    /// `by` seconds back or on from what is heard now.
    fn jump(app: *App, by: i32) void {
        if (app.film == null) return;
        app.moveTo(app.now() + @as(i64, by) * 1_000_000);
    }

    fn volumeTo(app: *App, percent: u32) void {
        app.level = @min(percent, volume_most);
        if (app.sound) |sound| sound.setVolume(app.level);
    }

    fn volumeBy(app: *App, by: i32) void {
        const level: i32 = @intCast(app.level);
        app.volumeTo(@intCast(@max(level + by, 0)));
        app.set(app.volume, &.{ pair(sl.SLIDER_Level, app.level), .{} });
    }

    // --- the pictures -----------------------------------------------------------

    /// The next picture decoded into `waiting`: false when there is none
    /// - the pictures have ended.
    fn decodeNext(app: *App) bool {
        if (app.waiting != null) return true;
        const film = app.film orelse return false;
        if (app.pictures_ended) return false;
        var corrupt: u32 = 0;
        while (true) {
            var frame: vc.VideoFrame = .{};
            const got = app.vcb.DecodeVideoFrame(film, &frame);
            if (got == vc.VCERR_OK) {
                app.waiting = frame;
                return true;
            }
            if (got == vc.VCERR_CORRUPT) {
                corrupt += 1;
                if (corrupt < most_corrupt) continue;
            }
            app.pictures_ended = true;
            return false;
        }
    }

    /// The pictures' turn: the waiting one shown once it is due - given
    /// back unshown when it is too late - the next decoded, and the timer
    /// set for it. One picture a turn, so the window's messages are
    /// answered between them.
    fn pictures(app: *App) void {
        if (app.state != .playing) return;
        while (true) {
            if (!app.decodeNext()) return app.picturesOver();
            const frame = app.waiting.?;
            const at = app.now();
            if (!app.fresh and frame.time > at) return app.arm(frame.time - at);
            if (!app.fresh and at - frame.time > app.frame_us and app.dropped_in_row < most_dropped) {
                app.vcb.ReleaseVideoFrame(app.film.?, &app.waiting.?);
                app.waiting = null;
                app.dropped_in_row += 1;
                continue;
            }
            app.showWaiting();
            app.showTime(at);
            if (!app.decodeNext()) return app.picturesOver();
            return app.arm(app.waiting.?.time - app.now());
        }
    }

    /// No picture left: the film has ended once its sound has too.
    fn picturesOver(app: *App) void {
        if (app.soundKeepsTime()) return;
        app.state = .ended;
        app.disarm();
        app.showDeck();
        app.showTime(@intCast(@min(app.info.duration, @as(u64, 1) << 62)));
    }

    /// The sound's process says the sound has played out: the timer keeps
    /// the time from there, for pictures that go on after it.
    fn soundNews(app: *App) void {
        const sound = app.sound orelse return;
        if (sound.state != .ended or app.timer_clock) return;
        app.setClock(sound.heard() orelse app.clock_time);
        app.timer_clock = true;
        if (app.state == .playing) app.arm(0);
    }

    /// The waiting picture shown, and the one before given back.
    fn showWaiting(app: *App) void {
        const film = app.film orelse return;
        const frame = &(app.waiting orelse return);
        app.put(frame);
        if (app.shown) |*old| app.vcb.ReleaseVideoFrame(film, old);
        app.shown = app.waiting;
        app.waiting = null;
        app.fresh = false;
        app.dropped_in_row = 0;
    }

    /// The picture shown again - the window sized, the whole screen left.
    fn showAgain(app: *App) void {
        if (app.shown) |*frame| app.put(frame);
    }

    /// A picture shown where the film is: the whole screen, or the canvas
    /// - the bars beside it filled when it lands elsewhere, and its box
    /// with the key colour while there is a layer. Handed to the layer, or
    /// put down by graphics.
    fn put(app: *App, frame: *const vc.VideoFrame) void {
        const rp = if (app.whole) |*shown| shown.rast_port else app.rast_port orelse return;
        const area = if (app.whole) |*shown| Rect{ .max_x = shown.width, .max_y = shown.height } else app.canvas_area;
        const last = if (app.whole != null) &app.whole_box else &app.canvas_box;
        const box = fit(area, frame.width, frame.height);
        if (box.width() <= 0 or box.height() <= 0) return;
        const moved = !same(box, last.*);
        if (moved) {
            app.gb.SetRPAttrs(rp, &[_]TagItem{ pair(graphics.RPTAG_APen, graphics.penRGB(0, 0, 0)), .{} });
            app.gb.RectFill(rp, &area);
            if (app.layer) |layer| {
                const colour = layer.key;
                app.gb.SetRPAttrs(rp, &[_]TagItem{ pair(graphics.RPTAG_APen, graphics.penRGB(@truncate(colour >> 16), @truncate(colour >> 8), @truncate(colour))), .{} });
                app.gb.RectFill(rp, &box);
            }
            last.* = box;
        }
        if (app.handOver(frame, box)) {
            if (moved and app.whole == null) app.ib.QueueGadgetRefresh(app.canvas);
            return;
        }
        if (box.width() == frame.width and box.height() == frame.height) {
            app.gb.WriteYUVPixelArray(rp, &frame.picture, 0, 0, &box);
        } else {
            const whole = Rect{ .max_x = @intCast(frame.width), .max_y = @intCast(frame.height) };
            app.gb.ScaleYUVPixelArray(rp, &frame.picture, &whole, &box);
        }
        if (app.whole == null) app.ib.QueueGadgetRefresh(app.canvas);
    }

    // --- the video layer --------------------------------------------------------

    /// A layer for the film, where the screen's display has one free -
    /// under the screen's picture only: one over it would cover the
    /// windows in front of the film's.
    fn openLayer(app: *App) void {
        if (app.layer != null) return;
        const rb = app.rb orelse return;
        const layer = rb.OpenVideoLayer(app.board orelse return, null) orelse return;
        if (layer.flags & rtg.RTGVLF_UNDER == 0) return rb.CloseVideoLayer(layer);
        app.layer = layer;
        app.layer_place = .{};
        app.canvas_box = .{};
        app.whole_box = .{};
    }

    /// The layer given back - before the frame it shows is - and the
    /// boxes filled anew for graphics.
    fn closeLayer(app: *App) void {
        const layer = app.layer orelse return;
        app.rb.?.CloseVideoLayer(layer);
        app.layer = null;
        app.canvas_box = .{};
        app.whole_box = .{};
    }

    /// The frame handed to the layer, shown in `box` of where the film is
    /// shown: false without a layer, and when it cannot take the frame -
    /// then it is given up, and graphics puts the film down until a size
    /// or a film asks for one again.
    fn handOver(app: *App, frame: *const vc.VideoFrame, box: Rect) bool {
        const layer = app.layer orelse return false;
        app.placeLayer(box);
        const all = rtg.RtgRect{ .width = @intCast(frame.width), .height = @intCast(frame.height) };
        if (app.rb.?.ShowVideoFrame(layer, &frame.picture, &all) == rtg.errors.RTGERR_OK) return true;
        app.closeLayer();
        return false;
    }

    /// The layer's place: `box` of the canvas, or of the whole screen's
    /// window, on the display - told the layer when it has changed.
    fn placeLayer(app: *App, box: Rect) void {
        const layer = app.layer orelse return;
        const at = app.origin();
        const place = rtg.RtgRect{ .x = at.x + box.min_x, .y = at.y + box.min_y, .width = box.width(), .height = box.height() };
        if (place.x == app.layer_place.x and place.y == app.layer_place.y and
            place.width == app.layer_place.width and place.height == app.layer_place.height) return;
        app.layer_place = place;
        _ = app.rb.?.MoveVideoLayer(layer, &place);
    }

    /// The window moved: the layer with it.
    fn followWindow(app: *App) void {
        const box = if (app.whole != null) app.whole_box else app.canvas_box;
        if (box.width() > 0 and box.height() > 0) app.placeLayer(box);
    }

    /// Where the top left of what the film is shown in is on the display:
    /// the whole screen's window's, or the canvas's in the window, the
    /// screen's top edge added - which a screen pulled down moves.
    fn origin(app: *App) struct { x: i32, y: i32 } {
        var screen_top: usize = 0;
        app.ib.GetScreenAttrs(app.screen, &[_]TagItem{ pair(sc.SA_Top, @intFromPtr(&screen_top)), .{} });
        const top: i32 = @truncate(@as(isize, @bitCast(screen_top)));
        if (app.whole != null) return .{ .x = 0, .y = top };
        var left: usize = 0;
        var window_top: usize = 0;
        var width: usize = 0;
        var height: usize = 0;
        app.ib.GetWindowAttrs(app.window, &[_]TagItem{
            pair(wn.WA_Left, @intFromPtr(&left)),
            pair(wn.WA_Top, @intFromPtr(&window_top)),
            pair(wn.WA_Width, @intFromPtr(&width)),
            pair(wn.WA_Height, @intFromPtr(&height)),
            .{},
        });
        const canvas = gc.boxIn(gc.gadget(app.canvas), @intCast(width), @intCast(height));
        return .{
            .x = @as(i32, @truncate(@as(isize, @bitCast(left)))) + canvas.left,
            .y = top + @as(i32, @truncate(@as(isize, @bitCast(window_top)))) + canvas.top,
        };
    }

    // --- the window -------------------------------------------------------------

    /// The canvas made as big as its box: its RastPort read again, and the
    /// picture shown in it anew.
    fn fitCanvas(app: *App) void {
        app.set(app.canvas, &.{ pair(cv.CANVAS_Width, 0), pair(cv.CANVAS_Height, 0), .{} });
        var value: usize = 0;
        _ = app.ib.GetAttr(cv.CANVAS_RastPort, app.canvas, &value);
        app.rast_port = @ptrFromInt(value);
        var width: usize = 0;
        var height: usize = 0;
        _ = app.ib.GetAttr(cv.CANVAS_Width, app.canvas, &width);
        _ = app.ib.GetAttr(cv.CANVAS_Height, app.canvas, &height);
        app.canvas_area = .{ .max_x = @intCast(width), .max_y = @intCast(height) };
        app.canvas_box = .{};
        // A size the layer may take again, if it gave up on the last.
        if (app.film != null) app.openLayer();
        const rp = app.rast_port orelse return;
        app.gb.SetRPAttrs(rp, &[_]TagItem{ pair(graphics.RPTAG_APen, graphics.penRGB(0, 0, 0)), .{} });
        app.gb.RectFill(rp, &app.canvas_area);
        if (app.whole == null) {
            app.showAgain();
            app.ib.QueueGadgetRefresh(app.canvas);
        }
    }

    /// The window's title, the deck, the slider's range and the time, for
    /// the film just opened.
    fn showFilm(app: *App) void {
        const after = " - " ++ COMMAND_NAME;
        const name = app.dl.FilePart(&app.name);
        var used: usize = 0;
        while (name[used] != 0 and used < app.window_title.len - after.len) : (used += 1) app.window_title[used] = name[used];
        for (after) |byte| {
            app.window_title[used] = byte;
            used += 1;
        }
        app.window_title[used] = 0;
        _ = app.ib.SetAttrsTagList(app.object, &[_]TagItem{ pair(wn.WA_Title, @intFromPtr(&app.window_title)), .{} });
        const seconds: u32 = @intCast(@min(app.info.duration / 1_000_000, 0xFFFF_FFFF));
        app.set(app.position, &.{
            pair(sl.SLIDER_Max, @max(seconds, 1)),
            pair(sl.SLIDER_Level, 0),
            pair(gc.GA_Disabled, @intFromBool(app.info.seekable == 0)),
            .{},
        });
        app.set(app.time, &.{ pair(tx.TEXT_RoomFor, @intFromPtr(if (app.long) room_long else room_short)), .{} });
        app.shown_second = ~@as(u32, 0);
        app.showTime(0);
        app.showDeck();
    }

    fn showDeck(app: *App) void {
        const mode = if (app.state == .ended) td.BUT_STOP else td.BUT_PLAY;
        app.set(app.deck, &.{ pair(td.TDECK_Mode, mode), pair(td.TDECK_Paused, @intFromBool(app.state == .paused)), .{} });
    }

    /// `seconds` as a time into `into`: minutes and seconds, hours before
    /// them for a long film.
    fn formatTime(app: *App, into: []u8, seconds: u32) usize {
        var made: [16:0]u8 = @splat(0);
        if (app.long) {
            const stream = exec.fmtStream(.{ seconds / hour, seconds / 60 % 60, seconds % 60 });
            comptime exec.checkFormat("%u:%02u:%02u", @TypeOf(.{ @as(u32, 0), @as(u32, 0), @as(u32, 0) }));
            _ = app.sys.RawDoFmt("%u:%02u:%02u", &stream, null, &made);
        } else {
            const stream = exec.fmtStream(.{ seconds / 60, seconds % 60 });
            comptime exec.checkFormat("%u:%02u", @TypeOf(.{ @as(u32, 0), @as(u32, 0) }));
            _ = app.sys.RawDoFmt("%u:%02u", &stream, null, &made);
        }
        var length: usize = 0;
        while (made[length] != 0 and length < into.len) : (length += 1) into[length] = made[length];
        return length;
    }

    /// The time beside the slider: `seconds` and the film's length.
    fn writeClock(app: *App, seconds: u32) void {
        var used = app.formatTime(app.time_text[0 .. app.time_text.len - 4], seconds);
        for (" / ") |byte| {
            app.time_text[used] = byte;
            used += 1;
        }
        const total: u32 = @intCast(@min(app.info.duration / 1_000_000, 0xFFFF_FFFF));
        used += app.formatTime(app.time_text[used..app.time_text.len], total);
        app.time_text[@min(used, app.time_text.len)] = 0;
        app.set(app.time, &.{ pair(tx.TEXT_Text, @intFromPtr(&app.time_text)), .{} });
    }

    /// The slider and the time brought to `time`, when it has moved on a
    /// second - and not while the slider is held.
    fn showTime(app: *App, time: i64) void {
        if (app.dragging) return;
        const seconds: u32 = @intCast(@min(@divTrunc(@max(time, 0), 1_000_000), 0xFFFF_FFFF));
        if (seconds == app.shown_second) return;
        app.shown_second = seconds;
        app.set(app.position, &.{ pair(sl.SLIDER_Level, seconds), .{} });
        app.writeClock(seconds);
    }

    /// The film over the whole screen; a beep when the window will not
    /// open.
    fn openWhole(app: *App) void {
        if (app.whole != null) return;
        app.whole = Whole.open(app.ib, app.gb, app.screen) orelse return app.ib.DisplayBeep(app.screen);
        app.whole_box = .{};
        app.showAgain();
    }

    /// The whole screen given up: the picture back in the window, which is
    /// made active again.
    fn closeWhole(app: *App) void {
        var shown = app.whole orelse return;
        app.whole = null;
        shown.close(app.ib);
        app.canvas_box = .{};
        app.showAgain();
        app.ib.ActivateWindow(app.window);
    }

    /// A press on the picture: a second one soon after the first shows the
    /// film over the whole screen.
    fn picturePressed(app: *App) void {
        var now_seconds: u32 = 0;
        var now_micros: u32 = 0;
        app.ib.CurrentTime(&now_seconds, &now_micros);
        if (app.pressed and app.ib.DoubleClick(app.pressed_seconds, app.pressed_micros, now_seconds, now_micros)) {
            app.pressed = false;
            return app.openWhole();
        }
        app.pressed = true;
        app.pressed_seconds = now_seconds;
        app.pressed_micros = now_micros;
    }

    /// A press let go on the tape deck: its mode, and whether it is paused.
    fn decked(app: *App, code: u32) void {
        const mode = code & 0xFF;
        const paused = code & td.TDECK_PAUSED_CODE != 0;
        switch (mode) {
            td.BUT_PLAY => if (paused) app.pause() else app.play(),
            td.BUT_STOP => app.stop(),
            td.BUT_REWIND, td.BUT_FORWARD => {
                app.jump(if (mode == td.BUT_REWIND) -jump_seconds else jump_seconds);
                // A jump, not a mode: the deck goes back to what it was.
                app.showDeck();
            },
            else => app.showDeck(),
        }
    }

    fn gadgetUp(app: *App, id: usize, code: u32) void {
        switch (id) {
            ID_DECK => app.decked(code),
            ID_POSITION => {
                app.dragging = false;
                const level: i32 = @bitCast(code);
                app.moveTo(@as(i64, @max(level, 0)) * 1_000_000);
            },
            ID_VOLUME => app.volumeTo(code),
            ID_PICTURE => app.picturePressed(),
            else => {},
        }
    }

    /// What a gadget told while it is being worked.
    fn updated(app: *App) void {
        var id: usize = 0;
        _ = app.ib.GetAttr(wc.WINDOWA_GadgetID, app.object, &id);
        var qualifier: usize = 0;
        _ = app.ib.GetAttr(wc.WINDOWA_Qualifier, app.object, &qualifier);
        var value: usize = 0;
        switch (id) {
            ID_POSITION => {
                if (qualifier & ie.IEQUALIFIER_REPEAT == 0) return;
                app.dragging = true;
                _ = app.ib.GetAttr(sl.SLIDER_Level, app.position, &value);
                app.writeClock(@intCast(@max(@as(i32, @bitCast(@as(u32, @truncate(value)))), 0)));
            },
            ID_VOLUME => {
                _ = app.ib.GetAttr(sl.SLIDER_Level, app.volume, &value);
                app.volumeTo(@intCast(value));
            },
            else => {},
        }
    }

    /// A key no gadget took: the space bar pauses and goes on, F the whole
    /// screen.
    fn key(app: *App, code: usize) void {
        switch (code) {
            ' ' => app.togglePause(),
            'f', 'F' => app.openWhole(),
            else => {},
        }
    }

    /// A key that is no character: left and right ten seconds back and
    /// on, up and down the volume.
    fn rawKey(app: *App, code: usize) void {
        switch (code) {
            keyboard.RAWKEY_LEFT => app.jump(-jump_seconds),
            keyboard.RAWKEY_RIGHT => app.jump(jump_seconds),
            keyboard.RAWKEY_UP => app.volumeBy(volume_step),
            keyboard.RAWKEY_DOWN => app.volumeBy(-volume_step),
            else => {},
        }
    }

    fn menuPicked(app: *App, number: u32) bool {
        if (mn.MENUNUM(number) != MENU_PROJECT) return true;
        switch (mn.ITEMNUM(number)) {
            ITEM_OPEN => app.askFilm(),
            ITEM_WHOLE => app.openWhole(),
            ITEM_ABOUT => app.showAbout(),
            ITEM_QUIT => return false,
            else => {},
        }
        return true;
    }

    /// Open...: a film asked for and played, the one before let go of; it
    /// stands while the requester is up, and goes on when nothing is
    /// picked.
    fn askFilm(app: *App) void {
        const was_playing = app.state == .playing;
        app.pause();
        var path: [dos.path_max + 1:0]u8 = @splat(0);
        if (!askName(app.dl, app.al, app.text, app.window, &app.name, &path)) {
            if (was_playing) app.play();
            return;
        }
        const opened = app.openFilm(&path);
        if (opened != vc.VCERR_OK) {
            app.cannotPlay(&path, opened);
            if (was_playing) app.play();
            return;
        }
        app.startFilm();
    }

    /// The film just opened shown and played from its start, on a layer
    /// where there is one.
    fn startFilm(app: *App) void {
        app.openLayer();
        app.canvas_box = .{};
        app.whole_box = .{};
        if (app.rast_port) |rp| {
            app.gb.SetRPAttrs(rp, &[_]TagItem{ pair(graphics.RPTAG_APen, graphics.penRGB(0, 0, 0)), .{} });
            app.gb.RectFill(rp, &app.canvas_area);
            app.ib.QueueGadgetRefresh(app.canvas);
        }
        app.showFilm();
        app.moveTo(0);
        if (app.info.seekable == 0) {
            if (app.sound) |sound| sound.start(0, false);
            app.timer_clock = !app.soundKeepsTime();
        }
        app.play();
    }

    /// Why a film cannot be played, in a requester.
    fn cannotPlay(app: *App, path: [*:0]const u8, why: i32) void {
        const easy = intuition.requesters.EasyStruct{
            .title = app.text.get(.MSG_CANNOT_PLAY_TITLE),
            .text_format = app.text.get(.MSG_CANNOT_PLAY),
            .gadget_format = app.text.get(.MSG_OK),
        };
        const reason = app.vcb.VideoErrorText(why);
        comptime exec.checkFormat(strings.builtin(.MSG_CANNOT_PLAY), @TypeOf(.{ @as([*:0]const u8, ""), @as([*:0]const u8, "") }));
        const stream = exec.fmtStream(.{ path, reason });
        _ = app.ib.EasyRequestArgs(app.window, &easy, null, &stream);
    }

    fn showAbout(app: *App) void {
        const easy = intuition.requesters.EasyStruct{
            .title = app.text.get(.MSG_ABOUT_TITLE),
            .text_format = app.text.get(.MSG_ABOUT),
            .gadget_format = app.text.get(.MSG_OK),
        };
        comptime exec.checkFormat(strings.builtin(.MSG_ABOUT), @TypeOf(.{@as([*:0]const u8, ABOUT_VERSION)}));
        const stream = exec.fmtStream(.{@as([*:0]const u8, ABOUT_VERSION)});
        // The film stands while it is up.
        const was_playing = app.state == .playing;
        app.pause();
        _ = app.ib.EasyRequestArgs(app.window, &easy, null, &stream);
        if (was_playing) app.play();
    }

    /// Every message the window has: false when it is to close.
    fn windowMessages(app: *App) bool {
        var code: u32 = 0;
        var handle = wc.WmHandleInput{ .code = &code };
        while (true) {
            const word = app.ib.SendMessage(app.object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => return false,
                wc.WMHI_GADGETUP => app.gadgetUp(word & wc.WMHI_GADGETMASK, code),
                wc.WMHI_MENUPICK => {
                    const number: u32 = @truncate(word & wc.WMHI_MENUMASK);
                    if (number != mn.MENUNULL and !app.menuPicked(number)) return false;
                },
                wc.WMHI_IDCMPUPDATE => app.updated(),
                wc.WMHI_VANILLAKEY => app.key(word & wc.WMHI_KEYMASK),
                wc.WMHI_RAWKEY => app.rawKey(word & wc.WMHI_KEYMASK),
                wc.WMHI_NEWSIZE => app.fitCanvas(),
                wc.WMHI_CHANGEWINDOW => app.followWindow(),
                else => {},
            }
        }
        return true;
    }

    /// The whole screen's messages: its keys work the film as the
    /// window's do.
    fn wholeMessages(app: *App) void {
        while (app.whole) |*shown| {
            switch (shown.next(app.ib)) {
                .nothing => return,
                .close => return app.closeWhole(),
                .key => |code| app.key(code),
                .raw_key => |code| app.rawKey(code),
            }
        }
    }

    fn run(app: *App) void {
        while (true) {
            var window_mask: usize = 0;
            _ = app.ib.GetAttr(wc.WINDOWA_SigMask, app.object, &window_mask);
            const sound_mask: u32 = if (app.sound) |sound| sound.signal() else 0;
            const whole_mask: u32 = if (app.whole) |*shown| shown.signal() else 0;
            const due_mask = app.dueSignal();
            const got = app.sys.Wait(@as(u32, @truncate(window_mask)) | sound_mask | whole_mask | due_mask | exec.SIGBREAKF_CTRL_C);
            if (got & exec.SIGBREAKF_CTRL_C != 0) return;
            if (got & due_mask != 0) {
                if (app.due_pending and app.sys.CheckIO(&app.due.node) != null) {
                    _ = app.sys.WaitIO(&app.due.node);
                    app.due_pending = false;
                }
            }
            if (got & sound_mask != 0) app.soundNews();
            if (got & whole_mask != 0) app.wholeMessages();
            if (!app.windowMessages()) return;
            if (!app.due_pending) app.pictures();
        }
    }
};

fn same(a: Rect, b: Rect) bool {
    return a.min_x == b.min_x and a.min_y == b.min_y and a.max_x == b.max_x and a.max_y == b.max_y;
}

/// A film asked for in a file requester, its full name into `into`;
/// started in the drawer of `current` when there is one. False when none
/// was picked.
fn askName(dl: *DosBase, al: ?*AslBase, text: *const Text, window: ?*Window, current: [*:0]const u8, into: *[dos.path_max + 1:0]u8) bool {
    const ab = al orelse return false;
    var drawer: [dos.path_max + 1:0]u8 = @splat(0);
    var length: usize = 0;
    while (current[length] != 0 and length < drawer.len) : (length += 1) drawer[length] = current[length];
    // The drawer: up to the last `/` or `:`.
    var cut = length;
    while (cut > 0 and drawer[cut - 1] != '/' and drawer[cut - 1] != ':') cut -= 1;
    if (cut > 0 and drawer[cut - 1] == '/') cut -= 1;
    drawer[cut] = 0;
    const handle = ab.AllocAslRequest(asl.ASL_FileRequest, &[_]TagItem{
        pair(asl.ASLFR_TitleText, @intFromPtr(text.get(.MSG_ASK_OPEN))),
        pair(asl.ASLFR_InitialDrawer, @intFromPtr(&drawer)),
        pair(asl.ASLFR_InitialPattern, @intFromPtr(open_pattern)),
        pair(asl.ASLFR_DoPatterns, 1),
        pair(if (window != null) asl.ASLFR_Window else sdk.utility.TAG_IGNORE, @intFromPtr(window)),
        pair(if (window != null) asl.ASLFR_SleepWindow else sdk.utility.TAG_IGNORE, 1),
        .{},
    }) orelse return false;
    defer ab.FreeAslRequest(handle);
    if (!ab.AslRequest(handle, null)) return false;
    const answer: *asl.FileRequester = @ptrCast(@alignCast(handle));
    const chosen = answer.file orelse return false;
    if (chosen[0] == 0) return false;
    into.* = @splat(0);
    if (answer.drawer) |dir| {
        var at: usize = 0;
        while (dir[at] != 0 and at < into.len) : (at += 1) into[at] = dir[at];
    }
    return dl.AddPart(into, chosen, into.len);
}

/// Gadgets made and not yet taken by a layout: given back together when
/// the window cannot be made.
const Loose = struct {
    items: [16]?*Object = @splat(null),
    count: usize = 0,

    fn add(loose: *Loose, made: ?*Object) ?*Object {
        const object = made orelse return null;
        loose.items[loose.count] = object;
        loose.count += 1;
        return object;
    }

    fn take(loose: *Loose, object: *Object) void {
        for (loose.items[0..loose.count]) |*slot| {
            if (slot.* == object) slot.* = null;
        }
    }

    fn dispose(loose: *Loose, ib: *IntuitionBase) void {
        for (loose.items[0..loose.count]) |item| ib.DisposeObject(item);
        loose.* = .{};
    }
};

fn noWindow(text: *const Text, dl: *DosBase) i32 {
    _ = text.printf(dl, .MSG_NOMEMORY, .{@as([*:0]const u8, COMMAND_NAME)});
    return dos.RETURN_FAIL;
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

    var text = Text.open(sys);
    defer text.close();

    var libraries: [8]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    const wanted = [_]struct { name: [*:0]const u8, version: u32 }{
        .{ .name = intuition.INTUITIONNAME, .version = 0 },
        .{ .name = graphics.GRAPHICSNAME, .version = 0 },
        .{ .name = vc.VIDEOCODECNAME, .version = 1 },
        .{ .name = tx.TEXT_LIBRARY, .version = 0 },
        .{ .name = sl.SLIDER_LIBRARY, .version = 0 },
        .{ .name = td.TDECK_LIBRARY, .version = 0 },
        .{ .name = cv.CANVAS_LIBRARY, .version = 0 },
    };
    for (wanted, 0..) |library, i| {
        libraries[i] = sys.OpenLibrary(library.name, library.version) orelse {
            _ = text.printf(dl, .MSG_NOLIBRARY, .{ @as([*:0]const u8, COMMAND_NAME), library.name });
            return dos.RETURN_FAIL;
        };
    }
    const ib: *IntuitionBase = @ptrCast(libraries[0].?);
    const gb: *GraphicsBase = @ptrCast(libraries[1].?);
    const vcb: *VideoCodecBase = @ptrCast(libraries[2].?);
    // Wanted for Open... - and for the film, when none is named.
    const asl_lib = sys.OpenLibrary(asl.ASLNAME, 1);
    defer if (asl_lib) |lib| sys.CloseLibrary(lib);
    const al: ?*AslBase = @ptrCast(asl_lib);

    // The clock: one request for the time - and timer.device's base - and
    // one the pictures wait by.
    var clock: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &clock.node, 0) != 0) {
        _ = text.printf(dl, .MSG_NOLIBRARY, .{ @as([*:0]const u8, COMMAND_NAME), @as([*:0]const u8, sdk.interface.timer.NAME) });
        return dos.RETURN_FAIL;
    }
    defer sys.CloseDevice(&clock.node);
    const tb: *TimerBase = @ptrCast(clock.node.device.?);

    const app_memory = sys.AllocVec(@sizeOf(App), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return noWindow(&text, dl);
    defer sys.FreeVec(app_memory);
    const app: *App = @ptrCast(@alignCast(app_memory));
    const percent: u32 = @intCast(@min(@max(rdargs.number(argv[arg_volume]) orelse 100, 0), volume_most));
    app.* = .{ .sys = sys, .dl = dl, .text = &text, .ib = ib, .gb = gb, .vcb = vcb, .tb = tb, .al = al, .level = percent };

    // The film: named, or asked for.
    var asked: [dos.path_max + 1:0]u8 = @splat(0);
    const path: [*:0]const u8 = rdargs.string(argv[arg_file]) orelse name: {
        if (!askName(dl, al, &text, null, "", &asked)) return dos.RETURN_OK;
        break :name &asked;
    };
    const opened = app.openFilm(path);
    if (opened != vc.VCERR_OK) {
        _ = text.printf(dl, .MSG_CANNOT_OPEN, .{ @as([*:0]const u8, COMMAND_NAME), path, vcb.VideoErrorText(opened) });
        return dos.RETURN_FAIL;
    }
    defer app.closeFilm();

    const due_port = sys.CreateMsgPort() orelse return noWindow(&text, dl);
    defer sys.DeleteMsgPort(due_port);
    app.due = clock;
    app.due.node.message.reply_port = due_port;
    app.due_port = due_port;
    defer app.disarm();

    const screen = ib.LockPubScreen(null) orelse return noWindow(&text, dl);
    defer ib.UnlockPubScreen(null, screen);
    app.screen = screen;
    // A video layer where the screen's display has one: rtg.library 1.10's
    // calls, intuition 0.75's SA_Board. Given back before the library.
    const rtg_lib = sys.OpenLibrary(rtg.RTGNAME, 1);
    defer if (rtg_lib) |lib| sys.CloseLibrary(lib);
    defer app.closeLayer();
    if (rtg_lib) |lib| {
        if (lib.version > 1 or lib.revision >= 10) {
            var board: usize = 0;
            ib.GetScreenAttrs(screen, &[_]TagItem{ pair(sc.SA_Board, @intFromPtr(&board)), .{} });
            app.rb = @ptrCast(lib);
            app.board = @ptrFromInt(board);
        }
    }
    // The picture at its own size, or as much of the screen as starts it.
    var screen_width: usize = 0;
    var screen_height: usize = 0;
    ib.GetScreenAttrs(screen, &[_]TagItem{ pair(sc.SA_Width, @intFromPtr(&screen_width)), pair(sc.SA_Height, @intFromPtr(&screen_height)), .{} });
    const start_box = fit(.{
        .max_x = @intCast(@min(app.info.width, screen_width * start_part_num / start_part_den)),
        .max_y = @intCast(@min(app.info.height, screen_height * start_part_num / start_part_den)),
    }, app.info.width, app.info.height);

    var loose: Loose = .{};
    defer loose.dispose(ib);
    app.canvas = loose.add(ib.NewObjectTagList(null, cv.CANVAS_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_PICTURE),
        pair(gc.GA_RelVerify, 1),
        pair(cv.CANVAS_Width, @intCast(@max(start_box.width(), 160))),
        pair(cv.CANVAS_Height, @intCast(@max(start_box.height(), 90))),
        .{},
    })) orelse return noWindow(&text, dl);
    app.deck = loose.add(ib.NewObjectTagList(null, td.TDECK_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_DECK),
        pair(td.TDECK_Tape, 1),
        pair(td.TDECK_Mode, td.BUT_PLAY),
        pair(td.TDECK_Paused, 1),
        .{},
    })) orelse return noWindow(&text, dl);
    app.position = loose.add(ib.NewObjectTagList(null, sl.SLIDER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_POSITION),
        pair(sl.SLIDER_Max, 1),
        pair(sl.SLIDER_Level, 0),
        pair(icc.ICA_TARGET, icc.ICTARGET_IDCMP),
        .{},
    })) orelse return noWindow(&text, dl);
    app.time = loose.add(ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        pair(tx.TEXT_Text, @intFromPtr(&app.time_text)),
        pair(tx.TEXT_RoomFor, @intFromPtr(room_long)),
        pair(tx.TEXT_Justification, tx.TEXT_JUSTIFY_RIGHT),
        .{},
    })) orelse return noWindow(&text, dl);
    app.volume = loose.add(ib.NewObjectTagList(null, sl.SLIDER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_VOLUME),
        pair(sl.SLIDER_Max, volume_most),
        pair(sl.SLIDER_Level, app.level),
        pair(sl.SLIDER_LevelFormat, @intFromPtr("%ld%%")),
        pair(sl.SLIDER_MaxLevelLen, 4),
        pair(icc.ICA_TARGET, icc.ICTARGET_IDCMP),
        pair(gc.GA_Width, volume_width),
        .{},
    })) orelse return noWindow(&text, dl);

    // The picture over the controls: the deck, the place in the film, the
    // time, and the volume, in a row with a margin of its own.
    const controls = loose.add(ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
        pair(lg.LAYOUTA_Margin, 6),
        pair(lg.LAYOUTA_Spacing, 8),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.deck)),
        pair(lg.CHILDA_WeightWidth, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.position)),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.time)),
        pair(lg.CHILDA_WeightWidth, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.volume)),
        pair(lg.CHILDA_WeightWidth, 0),
        .{},
    })) orelse return noWindow(&text, dl);
    for ([_]*Object{ app.deck, app.position, app.time, app.volume }) |taken| loose.take(taken);
    const layout = loose.add(ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.canvas)),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(controls)),
        pair(lg.CHILDA_WeightHeight, 0),
        .{},
    })) orelse return noWindow(&text, dl);
    loose.take(app.canvas);
    loose.take(controls);

    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        pair(wn.WA_PubScreen, @intFromPtr(screen)),
        pair(wn.WA_Title, @intFromPtr(COMMAND_NAME)),
        pair(wn.WA_ScreenTitle, @intFromPtr(SCREEN_TITLE)),
        pair(wn.WA_CloseGadget, 1),
        pair(wn.WA_DragBar, 1),
        pair(wn.WA_DepthGadget, 1),
        pair(wn.WA_SizeGadget, 1),
        pair(wn.WA_Activate, 1),
        pair(wn.WA_IDCMP, wn.IDCMP_IDCMPUPDATE | wn.IDCMP_NEWSIZE | wn.IDCMP_RAWKEY | wn.IDCMP_CHANGEWINDOW),
        pair(wc.WINDOWA_Layout, @intFromPtr(layout)),
        .{},
    }) orelse return noWindow(&text, dl);
    loose.take(layout);
    defer ib.DisposeObject(object);
    app.object = object;

    var open = wc.WmOpen{};
    const window_word = ib.SendMessage(object, @ptrCast(&open));
    if (window_word == 0) {
        _ = text.printf(dl, .MSG_NOWINDOW, .{@as([*:0]const u8, COMMAND_NAME)});
        return dos.RETURN_FAIL;
    }
    app.window = @ptrFromInt(window_word);
    defer if (app.whole) |*shown| {
        shown.close(ib);
        app.whole = null;
    };

    // The menus; the window plays without them when they will not go on.
    app.strip = blk: {
        var table: [menus.len]mn.NewMenu = undefined;
        for (menus, &table) |entry, *made| {
            made.* = entry.menu;
            if (entry.text) |id| made.label = text.get(id);
        }
        const made = ib.CreateMenusA(&table, null) orelse break :blk null;
        if (!ib.LayoutMenusA(made, screen, null) or !ib.SetMenuStrip(app.window, made)) {
            ib.FreeMenus(made);
            break :blk null;
        }
        break :blk made;
    };
    defer if (app.strip) |made| {
        ib.ClearMenuStrip(app.window);
        ib.FreeMenus(made);
    };

    app.fitCanvas();
    _ = sys.SetSignal(0, exec.SIGBREAKF_CTRL_C);
    app.startFilm();
    if (argv[arg_full] != 0) app.openWhole();
    app.run();
    return dos.RETURN_OK;
}
