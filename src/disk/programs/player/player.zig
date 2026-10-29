// SPDX-License-Identifier: MIT
//! Player: sound files played in a window - WAV, MP3, FLAC and Ogg Vorbis
//! - with a picture of the sound under the controls. Built against the
//! SDK only.
//!
//!   Player FILES/M,VOLUME/K/N,LOOK/K
//!
//! FILES are played one after another; VOLUME is in percent of as
//! recorded (100), LOOK the picture to start with: PLASMA, WAVE or BARS.
//! A file picked with Project > Open... or dropped on the window from the
//! desktop is played at once instead.
//!
//! The window's title is the song's. At its top, the song's cover beside
//! what its tags say, one block of lines in the middle of the room: the
//! title, half again as large as the window's font and bold, the artist,
//! and dimmer (the screen's `DIMTEXTPEN`) the album and its year, the
//! genre, the track and the composer, the chapter of a mix or a book that
//! is playing - or a comment - and what kind of file it is. A line with
//! nothing to say takes no room; when a song has more lines or fewer than
//! the one before, the window measures its layout again (`WM_RETHINK`),
//! and grows when the block needs more height. A line too long for the
//! room ends in three dots. The cover is the picture the
//! tags hold, or one lying beside the file (cover.zig), kept square and
//! as tall as the room beside it, from 64 to 160 pixels: it grows with the
//! window, read once for each song and scaled again when a sizing gives it
//! another size, with round corners in a sunk edge - and where a song has none,
//! a note on the ground (media.image's `MEDIA_NOTE`). A press on it shows
//! the cover at its own size in a window of its own (big.zig). Then a slider
//! across that is where the song is, which a drag moves, the time heard
//! before it and the song's length after it - a press on the length shows
//! what is left instead (`-3:16`); both keep the room their widest text
//! needs (`TEXT_RoomFor`, `TOOLBUTTON_RoomFor`), with hours for a song of
//! an hour or more. Under it one row, which breaks where the window is too
//! narrow for it: the buttons of a tape deck - the song before (within
//! three seconds of a song's start; later, the start of this one), rewind
//! and fast forward ten seconds, play, stop back to the start, pause, the
//! song after - then shuffle and repeat; a space (`LAYOUTA_AddSpace`);
//! then the sound off, the volume and the output the sound comes out of.
//! Shuffle, repeat and the sound off are toolbuttons with media.image's
//! pictures: repeat goes round off, the whole list, the one song, its
//! picture with a 1 for the last. Under them, as big as the window lets it
//! be and sunk in a frame, the picture:
//!
//! - **Plasma** - waves of colour, driven faster by the bass, turned by
//!   the treble, lit by the loudness.
//! - **Wave** - the sound itself, a hundredth of a second of it.
//! - **Bars** - the spectrum, from 40 Hz at the left to 16 kHz.
//!
//! A press on the picture goes to the next; the Picture menu picks one.
//! The space bar pauses and goes on; the Project menu's Quit ends.
//!
//! **The order.** The list is played in an order of its own - its own
//! order, or shuffled from the song playing on, with the chip's random
//! number generator (`sdk.hardware.rng`); the list as given stays. At the
//! end of it the sound stops; with repeat it starts again, shuffled anew,
//! and repeat one plays the song again. The song after, the song before
//! and a file picked follow the deck: they play when it played, wait
//! paused at their start when it was paused, and are only shown when it
//! was stopped.
//!
//! **Open...** puts up asl.library's file requester without waiting for
//! it (`ASLFR_ReplyPort`): it runs on a process of its own, the window and
//! the sound go on meanwhile, and its answer arrives as a message on a
//! port the window's loop waits on with everything else.
//!
//! **The output** is audio.device's, for every sound of the machine: one
//! picked moves them all over as they play. The list follows the device -
//! read again every second while the picture moves and whenever the
//! window is made active - so headphones plugged in show up, and when
//! they are the preferred output and take the sound over, the chooser
//! says so.
//!
//! **In step with the sound.** The picture is drawn 25 times a second
//! from the samples being heard at that moment - audio.device says how far
//! its stream has played and how far behind that the sound comes out, and
//! engine.zig keeps the last of what it decoded. The picture is drawn into
//! a buffer of 32-bit pixels (visual.zig), put into a canvas.gadget with
//! WritePixelArray, which converts it to the display's form, and shown
//! with QueueGadgetRefresh. While nothing plays it settles for two seconds
//! and then rests.
//!
//! **The sound is the window's to keep going**: its buffers are refilled
//! by the window's loop, so nothing the loop does may take long. A sizing
//! goes a step at a time, each said with `IDCMP_NEWSIZE`, and intuition
//! takes the next step - and shows this one - once the program has
//! replied it, which windowclass does when the loop asks for its next
//! message. So the canvases are fitted and drawn on `WMHI_NEWSIZE`, before
//! that: the step is shown with them in it, never a step behind, and the
//! loop is back at the sound between one step and the next. What fits of
//! the picture is kept across a step, the wave's trail with it.
//!
//! **A song is shown before it is heard**: its names and its cover first,
//! then its sound - reading a large cover takes the S3 a moment, which
//! would otherwise starve the sound.
//!
//! The close gadget or Ctrl-C end it.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const motion = sdk.motion;
const ac = sdk.audiocodec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const MotionBase = sdk.interface.motion.MotionBase;
const AudioCodecBase = sdk.interface.audiocodec.AudioCodecBase;
const DataTypesBase = sdk.interface.datatypes.DataTypesBase;
const AslBase = sdk.interface.asl.AslBase;
const Object = intuition.Object;
const Window = intuition.Window;
const TagItem = sdk.utility.TagItem;
const PixelFormat = sdk.rtg.bitmaps.PixelFormat;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wn = intuition.windows;
const wc = intuition.windowclass;
const icc = intuition.icclass;
const ic = intuition.imageclass;
const classusr = intuition.classusr;
const ie = sdk.devices.inputevent;
const tx = sdk.gadgets.text;
const sl = sdk.gadgets.slider;
const td = sdk.gadgets.tapedeck;
const tb = sdk.gadgets.toolbutton;
const media = sdk.images.media;
const asl = sdk.asl;
const mn = intuition.menus;
const cv = sdk.gadgets.canvas;
const ch = sdk.gadgets.chooser;
const sc = intuition.screens;
const diskfont = sdk.diskfont;
const DiskfontBase = sdk.interface.diskfont.DiskfontBase;
const audiocontrol = sdk.devices.audiocontrol;

const engine_file = @import("engine.zig");
const Engine = engine_file.Engine;
const visual = @import("visual.zig");
const Visual = visual.Visual;
const cover = @import("cover.zig");
const big_window = @import("big.zig");

pub const COMMAND_NAME = "Player";
const VERSION = "1.10";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (29.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
/// What the screen's bar says while the window is active.
const SCREEN_TITLE = COMMAND_NAME ++ " " ++ VERSION;

const template = "FILES/M,VOLUME/K/N,LOOK/K";
const arg_files = 0;
const arg_volume = 1;
const arg_look = 2;

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_NOMEMORY = "%s: no memory for the window\n";
const MSG_NOBUFFERS = "%s: no memory for the sound\n";
const MSG_NOWINDOW = "%s: no window\n";

const ID_DECK = 1;
const ID_POSITION = 2;
const ID_VOLUME = 3;
const ID_PICTURE = 6;
const ID_OUTPUT = 7;
const ID_SHUFFLE = 8;
const ID_REPEAT = 9;
const ID_MUTE = 10;
const ID_LENGTH = 11;
const ID_COVER = 12;

/// A look every 40 ms; the time beside the slider every sixth.
const look_period = 40;
const looks_per_time = 6;
/// Looks drawn after the sound stops, so the bars fall and the trail
/// fades before the picture rests.
const settle_looks = 50;
/// How far rewind and fast forward jump, in seconds.
const jump_seconds = 10;
/// Within this many seconds of a song's start, the song before is the one
/// before; later, it is the start of this one.
const back_seconds = 3;
/// The volume slider's width, with its level beside it.
const volume_width = 120;
/// The room the times beside the slider keep: minutes, or hours for a
/// song of an hour or more.
const room_short = "-00:00";
const room_long = "-0:00:00";
const hour = 3600;

/// What repeat does: nothing, the whole list, the one song.
const Repeat = enum { off, all, one };

/// How a song shown is started: played, held paused at its start, or not
/// at all.
const Start = enum { play, pause, stop };
/// Looks between two readings of the outputs: a second.
const looks_per_outputs = 25;

/// The lines beside the cover, in the order they are shown; the cover's
/// size at first, and the least it is shown at - the most is what
/// cover.zig keeps.
const line_title = 0;
const line_artist = 1;
const line_album = 2;
const line_more = 3;
const line_chapter = 4;
const line_format = 5;
const line_count = 6;
const cover_size = 112;
const cover_least = 64;
/// No chapter shown yet.
const no_chapter = ~@as(u32, 0);

/// What a song's tags say, as GetAudioStreamAttrs hands it out.
const Tags = struct {
    title: [*:0]const u8 = "",
    artist: [*:0]const u8 = "",
    album: [*:0]const u8 = "",
    album_artist: [*:0]const u8 = "",
    composer: [*:0]const u8 = "",
    genre: [*:0]const u8 = "",
    comment: [*:0]const u8 = "",
    year: u32 = 0,
    track: u32 = 0,
    tracks: u32 = 0,
    chapters: u32 = 0,
    chapter_list: ?[*]const ac.AudioChapter = null,
    picture: ?*const ac.AudioPicture = null,
};

/// What the window says when audio.device cannot be opened, by why.
fn soundTrouble(engine: *const Engine) [*:0]const u8 {
    return switch (engine.open_error) {
        sdk.devices.audio.AUDIOERR_NOSTREAM => "Every sound stream is in use",
        exec.IOERR_OPENFAIL => "This machine has no sound",
        else => "audio.device would not open a stream",
    };
}

/// The menus: the Project's Open... and Quit, and the Picture's looks in
/// `visual.Mode`'s order, one ticked at a time.
const MENU_PROJECT = 0;
const ITEM_OPEN = 0;
const ITEM_QUIT = 2;
const MENU_PICTURE = 1;

fn lookItem(label: [*:0]const u8, which: visual.Mode) mn.NewMenu {
    const self_bit = @as(u32, 1) << @intFromEnum(which);
    return .{ .type = mn.NM_ITEM, .label = label, .flags = mn.CHECKIT, .mutual_exclude = ((@as(u32, 1) << visual.mode_count) - 1) & ~self_bit };
}

const menus = [_]mn.NewMenu{
    .{ .type = mn.NM_TITLE, .label = "Project" },
    .{ .type = mn.NM_ITEM, .label = "Open...", .comm_key = "O" },
    .{ .type = mn.NM_ITEM, .label = mn.NM_BARLABEL },
    .{ .type = mn.NM_ITEM, .label = "Quit", .comm_key = "Q" },
    .{ .type = mn.NM_TITLE, .label = "Picture" },
    lookItem("Plasma", .plasma),
    lookItem("Wave", .wave),
    lookItem("Bars", .bars),
    .{},
};
/// Where the looks start in `menus`.
const first_look = 5;

fn pair(t: sdk.utility.Tag, data: usize) TagItem {
    return .{ .tag = t, .data = data };
}

/// A line of text built in pieces, cut where it is full.
fn Line(comptime size: usize) type {
    return struct {
        text: [size:0]u8 = @splat(0),
        len: usize = 0,

        const Self = @This();

        fn clear(line: *Self) void {
            line.len = 0;
            line.text[0] = 0;
        }

        fn add(line: *Self, piece: [*:0]const u8) void {
            var i: usize = 0;
            while (piece[i] != 0 and line.len < size) : (i += 1) {
                line.text[line.len] = piece[i];
                line.len += 1;
            }
            line.text[line.len] = 0;
        }

        /// A separator before what follows, when something came before.
        fn between(line: *Self, separator: [*:0]const u8) void {
            if (line.len != 0) line.add(separator);
        }

        fn empty(line: *const Self) bool {
            return line.len == 0;
        }
    };
}

const App = struct {
    sys: *ExecBase,
    dl: *DosBase,
    ib: *IntuitionBase,
    gb: *GraphicsBase,
    mb: *MotionBase,
    acb: *AudioCodecBase,
    engine: *Engine,
    visual: *Visual,
    object: *Object = undefined,
    window: *Window = undefined,
    dt: ?*DataTypesBase = null,
    /// Whether audiocodec.library hands out the whole of the tags (1.1).
    has_attrs: bool = false,
    /// The lines beside the cover: one text gadget of runs.
    block: *Object = undefined,
    cover: *Object = undefined,
    /// The song's cover as read, shown from there at the cover's size.
    kept: cover.Kept = .{},
    /// How many covers have been read: which one the large window shows.
    covers: usize = 0,
    /// The cover large, while its window is open.
    big: big_window.Big = .{},
    /// The note where a song has no cover, if it could be made.
    note: ?*Object = null,
    /// The screen the window is on, and its pens.
    screen: *intuition.Screen = undefined,
    dri: ?*sc.DrawInfo = null,
    position: *Object = undefined,
    /// The time heard, before the slider, and the length after it.
    time: *Object = undefined,
    length: *Object = undefined,
    deck: *Object = undefined,
    shuffle_button: *Object = undefined,
    repeat_button: *Object = undefined,
    mute_button: *Object = undefined,
    /// The pictures on repeat and the sound off, which change with them.
    repeat_picture: *Object = undefined,
    mute_picture: *Object = undefined,
    volume: *Object = undefined,
    picture: *Object = undefined,
    /// audio.device's outputs, the chooser that shows them, and the
    /// device opened to ask - none without sound.
    output: *Object = undefined,
    control: ?audiocontrol.Control = null,
    outputs: audiocontrol.Outputs = .{},

    /// The picture as drawn, and the canvas it is put into.
    rast_port: ?*graphics.RastPort = null,
    pixels: ?[*]u32 = null,
    width: u32 = 0,
    height: u32 = 0,
    samples: [visual.take]f32 = @splat(0),

    timer: *motion.Timer = undefined,
    tick_mask: u32 = 0,
    ticking: bool = false,
    settle: u32 = 0,
    looks: u32 = 0,

    /// The files to play, and which is playing.
    list: [*]const ?[*:0]const u8 = undefined,
    count: usize = 0,
    current: usize = 0,
    /// The order they are played in, a file's index each - the list's
    /// own, or shuffled; `step` is where in it the song is. Without the
    /// memory for it, the list's own.
    order: ?[*]u32 = null,
    order_room: usize = 0,
    step: usize = 0,
    shuffled: bool = false,
    repeat: Repeat = .off,
    /// The sound off, and the volume it comes back at.
    muted: bool = false,
    level: u32 = 100,
    /// The length after the slider says what is left instead.
    show_left: bool = false,
    /// The song is an hour or more: its times with hours.
    long: bool = false,
    /// A file picked or dropped: the list is then this one.
    picked: [dos.path_max + 1]u8 = @splat(0),
    picked_list: [1]?[*:0]const u8 = .{null},
    /// Open...'s file requester, made the first time, and the port its
    /// answer comes to; `asking` while it is up. None without asl.library.
    al: ?*AslBase = null,
    request: ?*anyopaque = null,
    asl_port: ?*exec.MsgPort = null,
    asking: bool = false,

    /// The position slider held: the time shows where it would go.
    dragging: bool = false,
    shown_second: u32 = ~@as(u32, 0),
    line_text: [line_count]Line(160) = [_]Line(160){.{}} ** line_count,
    /// The lines that say something as runs: each line's, and a line
    /// break between two; and the null run that ends them.
    runs: [2 * line_count]tx.TextRun = @splat(.{}),
    /// How many lines the runs hold, which the layout was measured for.
    shown_lines: u32 = 0,
    /// The title's font, or null for the window's.
    title_font: ?*graphics.TextFont = null,
    /// The song's chapters, and the one shown.
    chapters: ?[*]const ac.AudioChapter = null,
    chapter_count: u32 = 0,
    chapter_shown: u32 = no_chapter,
    time_text: [16:0]u8 = @splat(0),
    length_text: [16:0]u8 = @splat(0),
    /// The window's title: the song's, and the program's name.
    window_title: [96:0]u8 = @splat(0),
    /// The menus while they are on the window.
    strip: ?*intuition.Menu = null,
    drop: sdk.anvil.DropTarget = .{},

    fn set(app: *App, gadget: *Object, tags: []const TagItem) void {
        _ = app.ib.SetGadgetAttrsTagList(gadget, app.window, tags.ptr);
    }

    // --- the song --------------------------------------------------------------

    /// File `index` of the list shown, then started as `how` says.
    fn playAt(app: *App, index: usize, how: Start) void {
        app.current = index;
        const name = app.list[index] orelse return;
        const err = app.engine.load(name);
        app.visual.quiet();
        app.shown_second = ~@as(u32, 0);
        if (err != 0 and err != engine_file.no_sound) {
            for (&app.line_text) |*line| line.clear();
            const title = &app.line_text[line_title];
            title.add(app.dl.FilePart(name));
            title.add(": ");
            title.add(app.acb.AudioErrorText(err));
            app.showTitle(app.dl.FilePart(name));
            app.chapters = null;
            app.chapter_count = 0;
            app.showLines();
            app.showCover(null, name);
            app.showDeck(td.BUT_STOP, false);
            app.wake();
            return;
        }
        app.showSong(name, err == engine_file.no_sound);
        if (err == engine_file.no_sound or how == .stop) {
            app.showDeck(td.BUT_STOP, false);
        } else if (how == .pause) {
            // Started by the deck's pause let go, or the space bar.
            app.showDeck(td.BUT_PLAY, true);
        } else {
            app.engine.start();
            app.showDeck(td.BUT_PLAY, false);
        }
        app.wake();
    }

    // --- the order -----------------------------------------------------------

    /// The file at `step` of the order.
    fn indexAt(app: *const App, step: usize) usize {
        const order = app.order orelse return step;
        return order[step];
    }

    /// The song at `step` of the order shown, and started as `how` says.
    fn goTo(app: *App, step: usize, how: Start) void {
        app.step = step;
        app.playAt(app.indexAt(step), how);
    }

    /// How the song after or before is started: as the one playing is.
    fn startNow(app: *const App) Start {
        return switch (app.engine.state) {
            .playing => .play,
            .paused => .pause,
            .idle, .ended => .stop,
        };
    }

    /// The order made for a new list: room for it, and the list's own
    /// order or a shuffled one with the first song first.
    fn newOrder(app: *App) void {
        if (app.count > app.order_room) {
            if (app.order) |old| app.sys.FreeVec(old);
            app.order = null;
            app.order_room = 0;
            const memory = app.sys.AllocVec(app.count * @sizeOf(u32), exec.MEMF_ANY) orelse return;
            app.order = @ptrCast(@alignCast(memory));
            app.order_room = app.count;
        }
        app.step = 0;
        if (app.shuffled) app.shuffleOrder(0) else app.listOrder();
    }

    /// The list's own order, the song at the step it has there.
    fn listOrder(app: *App) void {
        const order = app.order orelse return;
        for (0..app.count) |i| order[i] = @intCast(i);
        app.step = app.current;
    }

    /// A number from 0 to `below` less one, from the chip's generator.
    fn random(below: usize) usize {
        return sdk.hardware.rng.read() % below;
    }

    /// The order shuffled: with `first` at its start and the rest after
    /// it, or - with none - all of it, the song just played not first.
    fn shuffleOrder(app: *App, first: ?usize) void {
        const order = app.order orelse return;
        const n = app.count;
        for (0..n) |i| order[i] = @intCast(i);
        app.step = 0;
        if (n < 2) return;
        var from: usize = 0;
        if (first) |song| {
            order[0] = @intCast(song);
            order[song] = 0;
            from = 1;
        }
        var at = n - 1;
        while (at > from) : (at -= 1) {
            const other = from + random(at - from + 1);
            const held = order[at];
            order[at] = order[other];
            order[other] = held;
        }
        if (first == null and order[0] == app.current) {
            const other = 1 + random(n - 1);
            order[0] = order[other];
            order[other] = @intCast(app.current);
        }
    }

    /// The song after: the next of the order, round to the first with
    /// repeat.
    fn next(app: *App) void {
        if (app.count == 0) return;
        const how = app.startNow();
        if (app.step + 1 < app.count) return app.goTo(app.step + 1, how);
        if (app.repeat == .off) return;
        if (app.shuffled) app.shuffleOrder(null);
        app.goTo(0, how);
    }

    /// The song before - or, a few seconds into this one, its start.
    fn previous(app: *App) void {
        if (app.count == 0) return;
        const engine = app.engine;
        const going = engine.state == .playing or engine.state == .paused;
        const rate = @max(engine.info.rate, 1);
        const late = going and engine.songFrame() >= back_seconds * rate;
        if (!late) {
            const how = app.startNow();
            if (app.step > 0) return app.goTo(app.step - 1, how);
            if (app.repeat != .off) return app.goTo(app.count - 1, how);
        }
        if (!going) return;
        engine.seek(0);
        app.visual.quiet();
        app.showTime();
    }

    /// Shuffle turned on or off: an order from the song playing on, or
    /// the list's own.
    fn shuffleTurned(app: *App, on: bool) void {
        app.shuffled = on;
        if (on) app.shuffleOrder(app.current) else app.listOrder();
    }

    /// Repeat pressed: off, the whole list, the one song, and round; the
    /// button on for the two, its picture with a 1 for the one song.
    fn repeatTurned(app: *App) void {
        app.repeat = switch (app.repeat) {
            .off => .all,
            .all => .one,
            .one => .off,
        };
        const picture = if (app.repeat == .one) media.MEDIA_REPEAT_ONE else media.MEDIA_REPEAT;
        _ = app.ib.SetAttrsTagList(app.repeat_picture, &[_]TagItem{ pair(media.MEDIA_Glyph, picture), .{} });
        app.set(app.repeat_button, &.{ pair(tb.TOOLBUTTON_Checked, @intFromBool(app.repeat != .off)), .{} });
    }

    /// The sound off or on again, at the volume the slider says; the
    /// button and its picture with it.
    fn mute(app: *App, off: bool) void {
        app.muted = off;
        const picture = if (off) media.MEDIA_MUTE else media.MEDIA_SPEAKER;
        _ = app.ib.SetAttrsTagList(app.mute_picture, &[_]TagItem{ pair(media.MEDIA_Glyph, picture), .{} });
        app.set(app.mute_button, &.{ pair(tb.TOOLBUTTON_Checked, @intFromBool(off)), .{} });
        app.engine.setVolume(if (off) 0 else app.level);
    }

    /// The volume slider moved: the sound at that level, and on again
    /// when it was off.
    fn volumeTo(app: *App, value: usize) void {
        app.level = @intCast(@max(@as(i32, @bitCast(@as(u32, @truncate(value)))), 0));
        if (app.muted) app.mute(false) else app.engine.setVolume(app.level);
    }

    /// What the song's tags say, as far as the library hands it out.
    fn tagsOf(app: *App, name: [*:0]const u8) Tags {
        const info = &app.engine.info;
        var tags: Tags = .{
            .title = if (info.title[0] != 0) @ptrCast(&info.title) else app.dl.FilePart(name),
            .artist = @ptrCast(&info.artist),
            .album = @ptrCast(&info.album),
        };
        const stream = app.engine.stream orelse return tags;
        if (!app.has_attrs) return tags;
        _ = app.acb.GetAudioStreamAttrs(stream, &[_]TagItem{
            pair(ac.ACA_Title, @intFromPtr(&tags.title)),
            pair(ac.ACA_Artist, @intFromPtr(&tags.artist)),
            pair(ac.ACA_Album, @intFromPtr(&tags.album)),
            pair(ac.ACA_AlbumArtist, @intFromPtr(&tags.album_artist)),
            pair(ac.ACA_Composer, @intFromPtr(&tags.composer)),
            pair(ac.ACA_Genre, @intFromPtr(&tags.genre)),
            pair(ac.ACA_Comment, @intFromPtr(&tags.comment)),
            pair(ac.ACA_Year, @intFromPtr(&tags.year)),
            pair(ac.ACA_Track, @intFromPtr(&tags.track)),
            pair(ac.ACA_Tracks, @intFromPtr(&tags.tracks)),
            pair(ac.ACA_Chapters, @intFromPtr(&tags.chapters)),
            pair(ac.ACA_ChapterList, @intFromPtr(&tags.chapter_list)),
            pair(ac.ACA_Picture, @intFromPtr(&tags.picture)),
            .{},
        });
        if (tags.title[0] == 0) tags.title = app.dl.FilePart(name);
        return tags;
    }

    /// The song's names, cover and kind, and the slider as long as it is;
    /// `silent` when the machine cannot play it.
    fn showSong(app: *App, name: [*:0]const u8, silent: bool) void {
        const info = &app.engine.info;
        const tags = app.tagsOf(name);
        for (&app.line_text) |*line| line.clear();

        app.line_text[line_title].add(tags.title);
        app.showTitle(tags.title);
        app.line_text[line_artist].add(if (tags.artist[0] != 0) tags.artist else tags.album_artist);
        const album = &app.line_text[line_album];
        album.add(tags.album);
        if (tags.year != 0) {
            var year: [16:0]u8 = @splat(0);
            if (album.empty()) app.formatNumber(&year, "%u", tags.year) else app.formatNumber(&year, " (%u)", tags.year);
            album.add(&year);
        }
        const more = &app.line_text[line_more];
        more.add(tags.genre);
        if (tags.track != 0) {
            more.between(", ");
            var track: [32:0]u8 = @splat(0);
            if (tags.tracks != 0) {
                const stream = exec.fmtStream(.{ tags.track, tags.tracks });
                comptime exec.checkFormat("track %u of %u", @TypeOf(.{ @as(u32, 0), @as(u32, 0) }));
                _ = app.sys.RawDoFmt("track %u of %u", &stream, null, &track);
            } else {
                app.formatNumber(&track, "track %u", tags.track);
            }
            more.add(&track);
        }
        if (tags.composer[0] != 0) {
            more.between(", ");
            more.add("composed by ");
            more.add(tags.composer);
        }
        app.chapters = tags.chapter_list;
        app.chapter_count = if (tags.chapter_list != null) tags.chapters else 0;
        app.chapter_shown = no_chapter;
        if (app.chapter_count == 0) app.line_text[line_chapter].add(tags.comment);

        const kind: [*:0]const u8 = switch (info.codec) {
            ac.ACODEC_WAV => "WAV",
            ac.ACODEC_MP3 => "MP3",
            ac.ACODEC_FLAC => "FLAC",
            ac.ACODEC_VORBIS => "Vorbis",
            else => "Sound",
        };
        const sides: [*:0]const u8 = if (info.channels == 1) "mono" else "stereo";
        var about: [64:0]u8 = @splat(0);
        const stream = exec.fmtStream(.{ kind, info.rate, sides, info.bitrate / 1000 });
        comptime exec.checkFormat("%s, %u Hz, %s, %u kbit/s", @TypeOf(.{ kind, @as(u32, 0), sides, @as(u32, 0) }));
        _ = app.sys.RawDoFmt("%s, %u Hz, %s, %u kbit/s", &stream, null, &about);
        const kind_line = &app.line_text[line_format];
        kind_line.add(&about);
        if (app.count > 1) {
            var place: [32:0]u8 = @splat(0);
            const counted = exec.fmtStream(.{ @as(u32, @intCast(app.current + 1)), @as(u32, @intCast(app.count)) });
            comptime exec.checkFormat(" - song %u of %u", @TypeOf(.{ @as(u32, 0), @as(u32, 0) }));
            _ = app.sys.RawDoFmt(" - song %u of %u", &counted, null, &place);
            kind_line.add(&place);
        }
        if (silent) kind_line.add(if (app.engine.open_error == exec.IOERR_OPENFAIL) " - no sound" else " - no stream free");
        app.showLines();
        app.showCover(tags.picture, name);
        app.set(app.position, &.{ pair(sl.SLIDER_Max, @max(app.seconds(info.frames), 1)), pair(sl.SLIDER_Level, 0), .{} });
        app.keepRoom(app.seconds(info.frames) >= hour);
        app.showTime();
    }

    /// The times keep the room for hours when `long`, or for minutes; the
    /// layout measured again when that changed.
    fn keepRoom(app: *App, long: bool) void {
        if (long == app.long) return;
        app.long = long;
        const room: [*:0]const u8 = if (long) room_long else room_short;
        app.set(app.time, &.{ pair(tx.TEXT_RoomFor, @intFromPtr(room)), .{} });
        app.set(app.length, &.{ pair(tb.TOOLBUTTON_RoomFor, @intFromPtr(room)), .{} });
        app.rethink();
    }

    /// The layout measured again, and the cover and the picture fitted to
    /// where it put them.
    fn rethink(app: *App) void {
        var rethink_message = wc.WmRethink{};
        _ = app.ib.SendMessage(app.object, @ptrCast(&rethink_message));
        app.fitCover();
        app.fitPicture();
    }

    /// One number through a RawDoFmt format into `into`.
    fn formatNumber(app: *App, into: [*:0]u8, comptime pattern: [:0]const u8, number: u32) void {
        const stream = exec.fmtStream(.{number});
        comptime exec.checkFormat(pattern, @TypeOf(.{@as(u32, 0)}));
        _ = app.sys.RawDoFmt(pattern, &stream, null, into);
    }

    /// The window's title: `song` and the program's name after it.
    fn showTitle(app: *App, song: [*:0]const u8) void {
        const after = " - " ++ COMMAND_NAME;
        var used: usize = 0;
        while (song[used] != 0 and used < app.window_title.len - after.len) : (used += 1) app.window_title[used] = song[used];
        for (after) |byte| {
            app.window_title[used] = byte;
            used += 1;
        }
        app.window_title[used] = 0;
        _ = app.ib.SetAttrsTagList(app.object, &[_]TagItem{ pair(wn.WA_Title, @intFromPtr(&app.window_title)), .{} });
    }

    /// The lines beside the cover drawn as they now read; the layout
    /// measured again, and the cover and the picture fitted to where it
    /// put them, when there are more of them or fewer than before.
    fn showLines(app: *App) void {
        const count = app.makeRuns();
        app.set(app.block, &.{ pair(tx.TEXT_Runs, @intFromPtr(&app.runs)), .{} });
        if (count == app.shown_lines) return;
        app.shown_lines = count;
        app.rethink();
    }

    /// The runs of the lines that say something: the title large and
    /// bold, the artist in the front pen, the rest dim. The answer is how
    /// many lines that is.
    fn makeRuns(app: *App) u32 {
        var n: usize = 0;
        var count: u32 = 0;
        for (&app.line_text, 0..) |*line, which| {
            if (line.empty()) continue;
            if (n != 0) {
                // The break in the look of the line it ends, so it is no
                // taller than that line.
                app.runs[n] = app.runs[n - 1];
                app.runs[n].text = "\n";
                n += 1;
            }
            app.runs[n] = switch (which) {
                line_title => .{ .text = &line.text, .font = app.title_font, .style = graphics.FSF_BOLD },
                line_artist => .{ .text = &line.text },
                else => .{ .text = &line.text, .colour = tx.screenPen(sc.DIMTEXTPEN) },
            };
            n += 1;
            count += 1;
        }
        app.runs[n] = .{};
        return count;
    }

    /// The cover read and drawn: the picture the tags hold, one beside
    /// the song, or the note.
    fn showCover(app: *App, picture: ?*const ac.AudioPicture, name: [*:0]const u8) void {
        app.covers +%= 1;
        var value: usize = 0;
        _ = app.ib.GetAttr(cv.CANVAS_RastPort, app.cover, &value);
        if (value == 0) return;
        _ = app.kept.read(.{ .sys = app.sys, .dl = app.dl, .gb = app.gb, .dt = app.dt }, @ptrFromInt(value), picture, name);
        app.drawCover();
    }

    /// The canvas made as big as the cover's box, and the cover drawn into
    /// it again when that changed its size: the canvas keeps its picture
    /// otherwise.
    fn fitCover(app: *App) void {
        const before = app.canvasSize(app.cover);
        app.set(app.cover, &.{ pair(cv.CANVAS_Width, 0), pair(cv.CANVAS_Height, 0), .{} });
        const after = app.canvasSize(app.cover);
        if (after.width == before.width and after.height == before.height) return;
        app.drawCover();
    }

    /// How large a canvas's picture is.
    fn canvasSize(app: *App, canvas: *Object) struct { width: usize, height: usize } {
        var width: usize = 0;
        var height: usize = 0;
        _ = app.ib.GetAttr(cv.CANVAS_Width, canvas, &width);
        _ = app.ib.GetAttr(cv.CANVAS_Height, canvas, &height);
        return .{ .width = width, .height = height };
    }

    /// The kept cover scaled into the canvas, as large as its box.
    fn drawCover(app: *App) void {
        var value: usize = 0;
        var width: usize = 0;
        var height: usize = 0;
        _ = app.ib.GetAttr(cv.CANVAS_RastPort, app.cover, &value);
        _ = app.ib.GetAttr(cv.CANVAS_Width, app.cover, &width);
        _ = app.ib.GetAttr(cv.CANVAS_Height, app.cover, &height);
        if (value == 0) return;
        const side: i32 = @intCast(@min(width, height, cover.kept_size));
        if (side == 0) return;
        app.kept.show(app.gb, @ptrFromInt(value), side, .{ .ib = app.ib, .dri = app.dri, .note = app.note });
        app.ib.QueueGadgetRefresh(app.cover);
    }

    /// The cover let go of: shown at its own size in a window of its own,
    /// when there is one to show and the press ended on it.
    fn coverPressed(app: *App) void {
        const dt = app.dt orelse return;
        var x: usize = 0;
        var y: usize = 0;
        var width: usize = 0;
        var height: usize = 0;
        _ = app.ib.GetAttr(cv.CANVAS_X, app.cover, &x);
        _ = app.ib.GetAttr(cv.CANVAS_Y, app.cover, &y);
        _ = app.ib.GetAttr(cv.CANVAS_Width, app.cover, &width);
        _ = app.ib.GetAttr(cv.CANVAS_Height, app.cover, &height);
        const side: isize = @intCast(@min(width, height, cover.kept_size));
        const at_x: isize = @bitCast(x);
        const at_y: isize = @bitCast(y);
        if (at_x < 0 or at_y < 0 or at_x >= side or at_y >= side) return;
        if (app.count == 0) return;
        const name = app.list[app.current] orelse return;
        const tags = app.tagsOf(name);
        const source: cover.Source = switch (app.kept.from) {
            .none => return,
            .tags => .{ .held = tags.picture orelse return },
            .beside => .{ .file = app.kept.file() orelse return },
        };
        const title = if (tags.album[0] != 0) tags.album else tags.title;
        if (!app.big.show(.{ .ib = app.ib, .dt = dt, .screen = app.screen }, app.covers, source, title)) app.ib.DisplayBeep(app.screen);
    }

    /// What the large cover's window says; it is closed when it asks.
    fn bigMessages(app: *App) void {
        const dt = app.dt orelse return;
        if (!app.big.messages(.{ .ib = app.ib, .dt = dt, .screen = app.screen })) app.big.close(app.ib);
    }

    /// The chapter being heard, when the song has chapters and it is
    /// another than the one shown.
    fn showChapter(app: *App) void {
        const list = app.chapters orelse return;
        const rate: u64 = @max(app.engine.info.rate, 1);
        const at: u32 = @intCast(@min(@as(u64, app.engine.songFrame()) * 1000 / rate, 0xFFFF_FFFF));
        var which: u32 = 0;
        for (list[0..app.chapter_count], 0..) |chapter, i| {
            if (chapter.start <= at) which = @intCast(i);
        }
        if (which == app.chapter_shown) return;
        app.chapter_shown = which;
        const line = &app.line_text[line_chapter];
        line.clear();
        var place: [32:0]u8 = @splat(0);
        const stream = exec.fmtStream(.{ which + 1, app.chapter_count });
        comptime exec.checkFormat("Chapter %u of %u: ", @TypeOf(.{ @as(u32, 0), @as(u32, 0) }));
        _ = app.sys.RawDoFmt("Chapter %u of %u: ", &stream, null, &place);
        line.add(&place);
        line.add(@ptrCast(&list[which].title));
        app.showLines();
    }

    fn showDeck(app: *App, mode: u32, paused: bool) void {
        app.set(app.deck, &.{ pair(td.TDECK_Mode, mode), pair(td.TDECK_Paused, @intFromBool(paused)), .{} });
    }

    /// Frames of the song as whole seconds.
    fn seconds(app: *App, frames: u32) u32 {
        return frames / @max(app.engine.info.rate, 1);
    }

    /// `seconds` as a time into `into`: minutes and seconds, hours before
    /// them for a long song, after a `-` for what is `left`.
    fn formatTime(app: *App, into: *[16:0]u8, seconds_in: u32, left: bool) void {
        const sign: [*:0]const u8 = if (left) "-" else "";
        if (app.long) {
            const stream = exec.fmtStream(.{ sign, seconds_in / hour, seconds_in / 60 % 60, seconds_in % 60 });
            comptime exec.checkFormat("%s%u:%02u:%02u", @TypeOf(.{ sign, @as(u32, 0), @as(u32, 0), @as(u32, 0) }));
            _ = app.sys.RawDoFmt("%s%u:%02u:%02u", &stream, null, into);
        } else {
            const stream = exec.fmtStream(.{ sign, seconds_in / 60, seconds_in % 60 });
            comptime exec.checkFormat("%s%u:%02u", @TypeOf(.{ sign, @as(u32, 0), @as(u32, 0) }));
            _ = app.sys.RawDoFmt("%s%u:%02u", &stream, null, into);
        }
    }

    /// The times' texts: `at` before the slider; after it the song's
    /// length, or what is left after `at`.
    fn clockTexts(app: *App, at: u32) void {
        const total = app.seconds(app.engine.info.frames);
        app.formatTime(&app.time_text, at, false);
        if (app.show_left) app.formatTime(&app.length_text, total -| at, true) else app.formatTime(&app.length_text, total, false);
    }

    /// The times beside the slider written and shown.
    fn writeClock(app: *App, at: u32) void {
        app.clockTexts(at);
        app.set(app.time, &.{ pair(tx.TEXT_Text, @intFromPtr(&app.time_text)), .{} });
        app.set(app.length, &.{ pair(gc.GA_Text, @intFromPtr(&app.length_text)), .{} });
    }

    /// The slider and the time brought to where the sound is, when it has
    /// moved on a second - and not while the slider is held.
    fn showTime(app: *App) void {
        if (app.dragging) return;
        app.showChapter();
        const at = app.seconds(app.engine.songFrame());
        if (at == app.shown_second) return;
        app.shown_second = at;
        app.set(app.position, &.{ pair(sl.SLIDER_Level, at), .{} });
        app.writeClock(at);
    }

    /// The end of a song: the same again with repeat one; the next of the
    /// order, round to the first with repeat; or back to the start and
    /// still.
    fn ended(app: *App) void {
        if (app.repeat == .one) {
            app.engine.start();
            app.visual.quiet();
            app.showTime();
            return;
        }
        if (app.step + 1 < app.count) return app.goTo(app.step + 1, .play);
        if (app.repeat == .all and app.count > 0) {
            if (app.shuffled) app.shuffleOrder(null);
            return app.goTo(0, .play);
        }
        app.engine.stop();
        app.showDeck(td.BUT_STOP, false);
        app.showTime();
    }

    fn jump(app: *App, by: i32) void {
        const engine = app.engine;
        if (engine.stream == null or (engine.state != .playing and engine.state != .paused)) return;
        const rate: i64 = @max(engine.info.rate, 1);
        const target = @max(@as(i64, engine.songFrame()) + by * rate, 0);
        engine.seek(@intCast(target));
        app.visual.quiet();
        app.showTime();
    }

    // --- what the window says ---------------------------------------------------

    /// A press let go on the tape deck: its mode, and whether it is paused.
    fn decked(app: *App, code: u32) void {
        const engine = app.engine;
        const mode = code & 0xFF;
        const paused = code & td.TDECK_PAUSED_CODE != 0;
        switch (mode) {
            td.BUT_PLAY => {
                if (engine.stream == null) {
                    if (app.count > 0) app.playAt(app.current, .play);
                } else {
                    engine.start();
                }
                engine.pause(paused);
                // Nothing to play: the deck stays stopped.
                if (engine.stream == null) app.showDeck(td.BUT_STOP, false);
                app.wake();
            },
            td.BUT_STOP => {
                engine.stop();
                app.visual.quiet();
                app.showTime();
            },
            td.BUT_REWIND, td.BUT_FORWARD => {
                app.jump(if (mode == td.BUT_REWIND) -jump_seconds else jump_seconds);
                // A jump, not a mode: the deck goes back to what it was.
                const playing = engine.state == .playing or engine.state == .paused;
                app.showDeck(if (playing) td.BUT_PLAY else td.BUT_STOP, engine.state == .paused);
            },
            // The deck's mode stays as it was; the song follows it.
            td.BUT_PREVIOUS => app.previous(),
            td.BUT_NEXT => app.next(),
            else => {},
        }
    }

    /// The space bar: pause, go on, or start.
    fn togglePause(app: *App) void {
        const engine = app.engine;
        switch (engine.state) {
            .playing => engine.pause(true),
            .paused => engine.pause(false),
            .idle, .ended => {
                if (engine.stream == null) {
                    if (app.count > 0) app.playAt(app.current, .play);
                    return;
                }
                engine.start();
            },
        }
        app.showDeck(td.BUT_PLAY, engine.state == .paused);
        app.wake();
    }

    // --- the output -----------------------------------------------------------

    /// The outputs read again: the chooser shown anew when they, or the
    /// one played through, changed.
    fn readOutputs(app: *App) void {
        const control = if (app.control) |*opened| opened else return;
        var now: audiocontrol.Outputs = .{};
        now.read(control);
        if (now.same(&app.outputs)) return;
        app.outputs = now;
        for (app.outputs.labels[0..app.outputs.count], 0..) |*label, at| label.* = @ptrCast(&app.outputs.infos[at].name);
        app.showOutputs();
        app.engine.readOutput();
    }

    fn showOutputs(app: *App) void {
        app.set(app.output, &.{
            pair(ch.CHOOSER_Labels, @intFromPtr(&app.outputs.labels)),
            pair(ch.CHOOSER_Active, app.outputs.currentIndex() orelse 0),
            pair(gc.GA_Disabled, @intFromBool(app.outputs.count == 0)),
            .{},
        });
    }

    /// The output picked: every sound of the machine played through it.
    fn pickOutput(app: *App, index: usize) void {
        const control = if (app.control) |*opened| opened else return;
        if (index < app.outputs.count) _ = control.play(app.outputs.infos[index].id);
        app.outputs.count = 0;
        app.readOutputs();
    }

    fn cycleLook(app: *App) void {
        app.visual.cycle();
        app.showLookMenu();
        app.wake();
    }

    /// The Picture menu's tick on the look shown.
    fn showLookMenu(app: *App) void {
        const strip = app.strip orelse return;
        app.ib.ClearMenuStrip(app.window);
        for (0..visual.mode_count) |at| {
            const entry = app.ib.ItemAddress(strip, mn.FULLMENUNUM(MENU_PICTURE, @intCast(at), mn.NOSUB)) orelse continue;
            if (at == @intFromEnum(app.visual.mode)) entry.flags |= mn.CHECKED else entry.flags &= ~mn.CHECKED;
        }
        _ = app.ib.ResetMenuStrip(app.window, strip);
    }

    /// A menu item picked: false when it is Quit.
    fn menuPicked(app: *App, number: u32) bool {
        switch (mn.MENUNUM(number)) {
            MENU_PROJECT => switch (mn.ITEMNUM(number)) {
                ITEM_OPEN => app.askFile(),
                ITEM_QUIT => return false,
                else => {},
            },
            MENU_PICTURE => {
                const which = mn.ITEMNUM(number);
                if (which < visual.mode_count) {
                    app.visual.mode = @enumFromInt(which);
                    app.visual.width = 0;
                    app.wake();
                }
            },
            else => {},
        }
        return true;
    }

    /// The file requester put up, without waiting for it: it starts in
    /// the drawer of the song playing the first time, and where it was
    /// left after that. Nothing while it is up already.
    fn askFile(app: *App) void {
        const al = app.al orelse return;
        const port = app.asl_port orelse return;
        if (app.asking) return;
        const request = app.request orelse made: {
            var drawer: [dos.path_max + 1:0]u8 = @splat(0);
            app.songDrawer(&drawer);
            app.request = al.AllocAslRequest(asl.ASL_FileRequest, &[_]TagItem{
                pair(asl.ASLFR_TitleText, @intFromPtr("Which song?")),
                pair(asl.ASLFR_InitialDrawer, @intFromPtr(&drawer)),
                pair(asl.ASLFR_InitialPattern, @intFromPtr("#?.(mp3|wav|flac|ogg|oga)")),
                pair(asl.ASLFR_DoPatterns, 1),
                pair(asl.ASLFR_ReplyPort, @intFromPtr(port)),
                .{},
            });
            break :made app.request orelse return;
        };
        app.asking = al.AslRequest(request, &[_]TagItem{ pair(asl.ASLFR_Window, @intFromPtr(app.window)), .{} });
    }

    /// The drawer the song playing is in, or `SYS:` with none.
    fn songDrawer(app: *App, into: *[dos.path_max + 1:0]u8) void {
        const fallback = "SYS:";
        const song: [*:0]const u8 = if (app.count > 0) app.list[app.current] orelse fallback else fallback;
        var length: usize = 0;
        while (song[length] != 0 and length < dos.path_max) : (length += 1) into[length] = song[length];
        into[length] = 0;
        if (song != @as([*:0]const u8, fallback)) {
            const end = @intFromPtr(app.dl.PathPart(into)) - @intFromPtr(into);
            into[end] = 0;
        }
    }

    /// The file requester's answer: the song picked played, as a file
    /// dropped is.
    fn answered(app: *App) void {
        const port = app.asl_port orelse return;
        while (app.sys.GetMsg(port)) |message| {
            const reply: *asl.AslMessage = @ptrCast(@alignCast(message));
            app.asking = false;
            if (reply.answered == 0) continue;
            const answer: *asl.FileRequester = @ptrCast(@alignCast(reply.requester orelse continue));
            var path: [dos.path_max + 1:0]u8 = @splat(0);
            _ = app.dl.AddPart(&path, answer.drawer orelse continue, path.len);
            if (!app.dl.AddPart(&path, answer.file orelse continue, path.len)) continue;
            app.pickedFile(&path);
        }
    }

    /// A requester still up taken down, its message waited for, and it
    /// and its port given back.
    fn dropRequest(app: *App) void {
        const al = app.al orelse return;
        if (app.request) |request| {
            if (app.asking) {
                al.AbortAslRequest(request);
                if (app.asl_port) |port| {
                    while (app.asking) {
                        _ = app.sys.WaitPort(port);
                        if (app.sys.GetMsg(port) != null) app.asking = false;
                    }
                }
            }
            al.FreeAslRequest(request);
            app.request = null;
        }
        app.sys.DeleteMsgPort(app.asl_port);
        app.asl_port = null;
    }

    /// A file picked or dropped: the list is that one now.
    fn pickedFile(app: *App, name: [*:0]const u8) void {
        var i: usize = 0;
        while (name[i] != 0 and i < dos.path_max) : (i += 1) app.picked[i] = name[i];
        app.picked[i] = 0;
        if (i == 0) return;
        app.picked_list[0] = @ptrCast(&app.picked);
        app.list = &app.picked_list;
        app.count = 1;
        app.current = 0;
        app.newOrder();
        app.goTo(0, .play);
    }

    fn gadgetUp(app: *App, id: usize, code: u32) void {
        switch (id) {
            ID_DECK => app.decked(code),
            ID_POSITION => {
                app.dragging = false;
                const level: i32 = @bitCast(code);
                const rate = @max(app.engine.info.rate, 1);
                if (app.engine.stream != null) {
                    app.engine.seek(@as(u32, @intCast(@max(level, 0))) *| rate);
                    app.visual.quiet();
                    app.showDeck(td.BUT_PLAY, app.engine.state == .paused);
                    app.wake();
                }
                app.shown_second = ~@as(u32, 0);
                app.showTime();
            },
            ID_VOLUME => app.volumeTo(code),
            ID_PICTURE => app.cycleLook(),
            ID_OUTPUT => app.pickOutput(code),
            ID_SHUFFLE => app.shuffleTurned(code != 0),
            ID_REPEAT => app.repeatTurned(),
            ID_MUTE => app.mute(code != 0),
            ID_LENGTH => {
                app.show_left = !app.show_left;
                app.shown_second = ~@as(u32, 0);
                app.showTime();
            },
            ID_COVER => app.coverPressed(),
            else => {},
        }
    }

    /// What a gadget told while it is being worked, or as it is done.
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
                app.volumeTo(value);
            },
            else => {},
        }
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
                wc.WMHI_VANILLAKEY => if (word & wc.WMHI_KEYMASK == ' ') app.togglePause(),
                wc.WMHI_NEWSIZE => app.sized(),
                wc.WMHI_ACTIVE => app.readOutputs(),
                else => {},
            }
        }
        return true;
    }

    /// A step of a sizing: the cover and the picture fitted to their new
    /// boxes and drawn there now, before the next message is asked for -
    /// which replies the step's IDCMP_NEWSIZE, and intuition shows the
    /// step once it is replied.
    fn sized(app: *App) void {
        app.fitCover();
        app.fitPicture();
        app.look();
        app.wake();
    }

    fn dropped(app: *App) void {
        var name: [dos.path_max + 1]u8 = undefined;
        while (app.drop.next(app.dl, &name)) |file| {
            if (file.is_drawer) continue;
            app.ib.ActivateWindow(app.window);
            app.pickedFile(file.name);
        }
    }

    // --- the picture ----------------------------------------------------------

    /// The canvas made as big as its box, and the pixels with it.
    fn fitPicture(app: *App) void {
        app.set(app.picture, &.{ pair(cv.CANVAS_Width, 0), pair(cv.CANVAS_Height, 0), .{} });
        app.takePicture();
    }

    /// The canvas's RastPort and size read, and pixels for that size with
    /// what fits of the last picture carried into them.
    fn takePicture(app: *App) void {
        var value: usize = 0;
        _ = app.ib.GetAttr(cv.CANVAS_RastPort, app.picture, &value);
        app.rast_port = @ptrFromInt(value);
        var width: usize = 0;
        var height: usize = 0;
        _ = app.ib.GetAttr(cv.CANVAS_Width, app.picture, &width);
        _ = app.ib.GetAttr(cv.CANVAS_Height, app.picture, &height);
        const w: u32 = @intCast(@min(width, visual.max_width));
        const h: u32 = @intCast(@min(height, visual.max_height));
        if (w == app.width and h == app.height and app.pixels != null) return;
        const old = app.pixels;
        defer if (old) |pixels| app.sys.FreeVec(pixels);
        app.pixels = null;
        const memory = app.sys.AllocVec(@as(usize, w) * h * 4, exec.MEMF_ANY) orelse {
            app.width = 0;
            app.height = 0;
            return;
        };
        const pixels: [*]u32 = @ptrCast(@alignCast(memory));
        visual.carry(pixels, w, h, old, app.width, app.height);
        app.pixels = pixels;
        app.width = w;
        app.height = h;
        app.visual.follow(w, h);
    }

    /// The pictures going again, after a change or with the sound.
    fn wake(app: *App) void {
        app.settle = settle_looks;
        if (app.ticking) return;
        app.mb.StartTimer(app.timer);
        app.ticking = true;
    }

    /// One look: the picture drawn from what is being heard, the time
    /// now and then; the clock let rest once the sound has stopped and the
    /// picture settled.
    fn tick(app: *App) void {
        const engine = app.engine;
        app.serviceSound();
        app.look();
        app.looks +%= 1;
        if (app.looks % looks_per_time == 0) app.showTime();
        if (app.looks % looks_per_outputs == 0) app.readOutputs();
        if (engine.state == .playing) {
            app.settle = settle_looks;
        } else if (app.settle > 0) {
            app.settle -= 1;
        } else {
            app.mb.StopTimer(app.timer);
            app.ticking = false;
        }
    }

    /// The picture drawn from what is being heard, put into its canvas
    /// and the canvas shown.
    fn look(app: *App) void {
        const pixels = app.pixels orelse return;
        const rp = app.rast_port orelse return;
        app.engine.heard(&app.samples);
        app.visual.draw(pixels, app.width, app.height, app.width, &app.samples, @max(app.engine.info.rate, 8000));
        app.gb.WritePixelArray(rp, @ptrCast(pixels), app.width * 4, @intFromEnum(PixelFormat.bgra32), 0, 0, &.{
            .max_x = @intCast(app.width),
            .max_y = @intCast(app.height),
        });
        app.ib.QueueGadgetRefresh(app.picture);
    }

    /// The buffers that came back filled and sent again; the next song
    /// when this one has ended.
    fn serviceSound(app: *App) void {
        app.engine.service();
        if (app.engine.state == .ended) app.ended();
    }

    fn run(app: *App) void {
        while (true) {
            var window_mask: usize = 0;
            _ = app.ib.GetAttr(wc.WINDOWA_SigMask, app.object, &window_mask);
            const sound_mask = app.engine.signal();
            const drop_mask = app.drop.signal();
            const asl_mask: u32 = if (app.asl_port) |port| port.sigMask() else 0;
            const big_mask = app.big.signal(app.ib);
            const got = app.sys.Wait(@as(u32, @truncate(window_mask)) | sound_mask | app.tick_mask | drop_mask | asl_mask | big_mask | exec.SIGBREAKF_CTRL_C);
            if (got & exec.SIGBREAKF_CTRL_C != 0) return;
            if (got & sound_mask != 0) app.serviceSound();
            if (got & drop_mask != 0) app.dropped();
            if (got & asl_mask != 0) app.answered();
            if (got & big_mask != 0) app.bigMessages();
            if (!app.windowMessages()) return;
            if (got & app.tick_mask != 0) app.tick();
        }
    }
};

fn lookNamed(name: ?[*:0]const u8) visual.Mode {
    const given = name orelse return .plasma;
    return switch (given[0] | 0x20) {
        'w' => .wave,
        'b' => .bars,
        else => .plasma,
    };
}

/// Gadgets made and not yet taken by a layout: given back together when
/// the window cannot be made.
const Loose = struct {
    items: [28]?*Object = @splat(null),
    count: usize = 0,

    /// What was made, kept loose; null when it was not.
    fn add(loose: *Loose, made: ?*Object) ?*Object {
        const object = made orelse return null;
        loose.items[loose.count] = object;
        loose.count += 1;
        return object;
    }

    /// Taken by a layout, or the window: no longer loose.
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

/// A child of a layout, with what it is told about its room; with no
/// object, a space that takes the spare room (`LAYOUTA_AddSpace`).
const Child = struct {
    object: ?*Object = null,
    weight_width: ?u32 = null,
    weight_height: ?u32 = null,
    /// Never smaller than this, whatever the window's size.
    min_width: ?u32 = null,
    min_height: ?u32 = null,
    /// Never taller than this.
    max_height: ?u32 = null,
    /// Its shape kept as it grows: `lg.aspect`.
    aspect: ?u32 = null,
    label: ?[*:0]const u8 = null,
};

/// A layout with `tags` of its own and `children`, which it takes; it is
/// loose itself. Null when it could not be made: the children are still
/// loose then.
fn group(ib: *IntuitionBase, loose: *Loose, tags: []const TagItem, children: []const Child) ?*Object {
    var list: [48]TagItem = undefined;
    var n: usize = 0;
    for (tags) |item| {
        list[n] = item;
        n += 1;
    }
    for (children) |child| {
        list[n] = if (child.object) |object| pair(lg.LAYOUTA_AddChild, @intFromPtr(object)) else pair(lg.LAYOUTA_AddSpace, 0);
        n += 1;
        if (child.weight_width) |weight| {
            list[n] = pair(lg.CHILDA_WeightWidth, weight);
            n += 1;
        }
        if (child.weight_height) |weight| {
            list[n] = pair(lg.CHILDA_WeightHeight, weight);
            n += 1;
        }
        if (child.min_width) |size| {
            list[n] = pair(lg.CHILDA_MinWidth, size);
            n += 1;
        }
        if (child.min_height) |size| {
            list[n] = pair(lg.CHILDA_MinHeight, size);
            n += 1;
        }
        if (child.max_height) |size| {
            list[n] = pair(lg.CHILDA_MaxHeight, size);
            n += 1;
        }
        if (child.aspect) |shape| {
            list[n] = pair(lg.CHILDA_Aspect, shape);
            n += 1;
        }
        if (child.label) |label| {
            list[n] = pair(lg.CHILDA_Label, @intFromPtr(label));
            n += 1;
        }
    }
    list[n] = .{};
    const made = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &list) orelse return null;
    for (children) |child| if (child.object) |object| loose.take(object);
    return loose.add(made);
}

/// The window's font at half again its height, rendered by
/// diskfont.library; null without it, and then the title is in the
/// window's font.
fn titleFont(ib: *IntuitionBase, gb: *GraphicsBase, dfb: ?*DiskfontBase) ?*graphics.TextFont {
    const fonts = dfb orelse return null;
    const font = ib.OpenSystemFont(sc.SYSFONT_DEFAULT) orelse return null;
    defer gb.CloseFont(font);
    const name = font.node.name orelse return null;
    const rows: u32 = font.image.height;
    return fonts.OpenDiskFont(&.{ .name = name, .y_size = @intCast(rows * 3 / 2) });
}

fn noWindow(dl: *DosBase) i32 {
    _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
    return dos.RETURN_FAIL;
}

/// A small toggle of the transport row: its picture, its key in `label`
/// and what it does in `hint`.
fn toggle(ib: *IntuitionBase, id: u32, label: [*:0]const u8, hint: [*:0]const u8, image: *Object) ?*Object {
    return ib.NewObjectTagList(null, tb.TOOLBUTTON_CLASS, &[_]TagItem{
        pair(gc.GA_ID, id),
        pair(gc.GA_Text, @intFromPtr(label)),
        pair(tb.TOOLBUTTON_Image, @intFromPtr(image)),
        pair(tb.TOOLBUTTON_Size, tb.TBSIZE_SMALL),
        pair(tb.TOOLBUTTON_Kind, tb.TBKIND_TOGGLE),
        pair(tb.TOOLBUTTON_Hint, @intFromPtr(hint)),
        .{},
    });
}

/// One of media.image's pictures; the program's, disposed of after the
/// button it is on.
fn mediaPicture(ib: *IntuitionBase, glyph: u32) ?*Object {
    return ib.NewObjectTagList(null, media.MEDIA_CLASS, &[_]TagItem{ pair(media.MEDIA_Glyph, glyph), .{} });
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
    const percent: u32 = @intCast(@min(@max(rdargs.number(argv[arg_volume]) orelse 100, 0), 200));

    var libraries: [11]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    const wanted = [_][*:0]const u8{
        intuition.INTUITIONNAME, graphics.GRAPHICSNAME, motion.MOTIONNAME,   ac.AUDIOCODECNAME,
        tx.TEXT_LIBRARY,         sl.SLIDER_LIBRARY,     td.TDECK_LIBRARY,    cv.CANVAS_LIBRARY,
        ch.CHOOSER_LIBRARY,      tb.TOOLBUTTON_LIBRARY, media.MEDIA_LIBRARY,
    };
    for (wanted, 0..) |name, i| {
        libraries[i] = sys.OpenLibrary(name, 0) orelse {
            _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, name });
            return dos.RETURN_FAIL;
        };
    }
    const ib: *IntuitionBase = @ptrCast(libraries[0].?);
    const acb: *AudioCodecBase = @ptrCast(libraries[3].?);
    // Wanted for the covers only: without it there are none.
    const dt_lib = sys.OpenLibrary(sdk.datatypes.DATATYPESNAME, 0);
    defer if (dt_lib) |lib| sys.CloseLibrary(lib);
    // Wanted for Open... only, and opened now rather than then: loading
    // it from the disk while the sound plays would starve the sound.
    const asl_lib = sys.OpenLibrary(asl.ASLNAME, 1);
    defer if (asl_lib) |lib| sys.CloseLibrary(lib);

    const engine = Engine.create(sys, acb) orelse {
        _ = Printf(dl, MSG_NOBUFFERS, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    defer engine.destroy();
    engine.setVolume(percent);

    // The state and the pictures' tables: more than the stack is for.
    const app_memory = sys.AllocVec(@sizeOf(App), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return dos.RETURN_FAIL;
    defer sys.FreeVec(app_memory);
    const visual_memory = sys.AllocVec(@sizeOf(Visual), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return dos.RETURN_FAIL;
    defer sys.FreeVec(visual_memory);
    const look: *Visual = @ptrCast(@alignCast(visual_memory));
    look.* = .{ .mode = lookNamed(rdargs.string(argv[arg_look])) };
    look.init();
    const app: *App = @ptrCast(@alignCast(app_memory));
    app.* = .{
        .sys = sys,
        .dl = dl,
        .ib = ib,
        .gb = @ptrCast(libraries[1].?),
        .mb = @ptrCast(libraries[2].?),
        .acb = acb,
        .dt = @ptrCast(dt_lib),
        .al = @ptrCast(asl_lib),
        .has_attrs = acb.lib().revision >= 1,
        .engine = engine,
        .visual = look,
        .level = percent,
    };
    defer if (app.pixels) |pixels| sys.FreeVec(pixels);
    defer if (app.order) |order| sys.FreeVec(order);
    defer app.kept.free(app.gb);
    if (argv[arg_files] != 0) {
        app.list = @ptrFromInt(argv[arg_files]);
        while (app.list[app.count] != null) app.count += 1;
    }
    app.newOrder();
    app.clockTexts(0);
    app.line_text[line_title].add("No song");
    if (!engine.opened) app.line_text[line_format].add(soundTrouble(engine));
    // The title's font, kept open - and the library that made it - until
    // the gadgets that draw in it are gone.
    const diskfont_lib = sys.OpenLibrary(diskfont.DISKFONTNAME, 0);
    defer if (diskfont_lib) |lib| sys.CloseLibrary(lib);
    app.title_font = titleFont(ib, app.gb, @ptrCast(diskfont_lib));
    defer if (app.title_font) |font| app.gb.CloseFont(font);
    app.shown_lines = app.makeRuns();

    // The toggles' pictures, the program's: made before the gadgets, so
    // they are disposed of after them.
    const shuffle_picture = mediaPicture(ib, media.MEDIA_SHUFFLE) orelse return noWindow(dl);
    defer ib.DisposeObject(shuffle_picture);
    app.repeat_picture = mediaPicture(ib, media.MEDIA_REPEAT) orelse return noWindow(dl);
    defer ib.DisposeObject(app.repeat_picture);
    app.mute_picture = mediaPicture(ib, media.MEDIA_SPEAKER) orelse return noWindow(dl);
    defer ib.DisposeObject(app.mute_picture);
    // Drawn into the cover where there is none; the ground alone without.
    app.note = mediaPicture(ib, media.MEDIA_NOTE);
    defer if (app.note) |note| ib.DisposeObject(note);

    // The gadgets: each loose until a layout takes it, and whatever is
    // still loose given back when the window cannot be made.
    var loose: Loose = .{};
    defer loose.dispose(ib);
    app.block = loose.add(ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        pair(tx.TEXT_Runs, @intFromPtr(&app.runs)),
        pair(tx.TEXT_Clipped, 1),
        pair(gc.GA_Width, 240),
        .{},
    })) orelse return noWindow(dl);
    app.cover = loose.add(ib.NewObjectTagList(null, cv.CANVAS_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_COVER),
        pair(gc.GA_RelVerify, 1),
        pair(cv.CANVAS_Width, cover_size),
        pair(cv.CANVAS_Height, cover_size),
        .{},
    })) orelse return noWindow(dl);
    app.position = loose.add(ib.NewObjectTagList(null, sl.SLIDER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_POSITION),
        pair(sl.SLIDER_Max, 1),
        pair(sl.SLIDER_Level, 0),
        pair(icc.ICA_TARGET, icc.ICTARGET_IDCMP),
        .{},
    })) orelse return noWindow(dl);
    app.time = loose.add(ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        pair(tx.TEXT_Text, @intFromPtr(&app.time_text)),
        pair(tx.TEXT_RoomFor, @intFromPtr(room_short)),
        pair(tx.TEXT_Justification, tx.TEXT_JUSTIFY_RIGHT),
        .{},
    })) orelse return noWindow(dl);
    app.length = loose.add(ib.NewObjectTagList(null, tb.TOOLBUTTON_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_LENGTH),
        pair(gc.GA_Text, @intFromPtr(&app.length_text)),
        pair(tb.TOOLBUTTON_RoomFor, @intFromPtr(room_short)),
        pair(tb.TOOLBUTTON_Size, tb.TBSIZE_SMALL),
        pair(tb.TOOLBUTTON_Hint, @intFromPtr("The song's length, or what is left of it")),
        .{},
    })) orelse return noWindow(dl);
    app.deck = loose.add(ib.NewObjectTagList(null, td.TDECK_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_DECK),
        pair(td.TDECK_Tape, 1),
        pair(td.TDECK_Tracks, 1),
        pair(td.TDECK_Mode, td.BUT_STOP),
        .{},
    })) orelse return noWindow(dl);
    app.shuffle_button = loose.add(toggle(ib, ID_SHUFFLE, "_Shuffle", "Play the songs in an order of their own", shuffle_picture)) orelse return noWindow(dl);
    app.repeat_button = loose.add(toggle(ib, ID_REPEAT, "_Repeat", "Play the list again, or the one song", app.repeat_picture)) orelse return noWindow(dl);
    app.mute_button = loose.add(toggle(ib, ID_MUTE, "_Mute", "The sound off, and on again", app.mute_picture)) orelse return noWindow(dl);
    app.volume = loose.add(ib.NewObjectTagList(null, sl.SLIDER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_VOLUME),
        pair(sl.SLIDER_Max, 200),
        pair(sl.SLIDER_Level, percent),
        pair(sl.SLIDER_LevelFormat, @intFromPtr("%ld%%")),
        pair(sl.SLIDER_MaxLevelLen, 4),
        pair(icc.ICA_TARGET, icc.ICTARGET_IDCMP),
        pair(gc.GA_Width, volume_width),
        .{},
    })) orelse return noWindow(dl);
    app.control = audiocontrol.Control.open(sys);
    defer if (app.control) |*control| control.close();
    if (app.control) |*control| app.outputs.read(control);
    app.output = loose.add(ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_OUTPUT),
        pair(gc.GA_RelVerify, 1),
        pair(ch.CHOOSER_Labels, @intFromPtr(&app.outputs.labels)),
        pair(ch.CHOOSER_Active, app.outputs.currentIndex() orelse 0),
        pair(gc.GA_Disabled, @intFromBool(app.outputs.count == 0)),
        .{},
    })) orelse return noWindow(dl);
    app.picture = loose.add(ib.NewObjectTagList(null, cv.CANVAS_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_PICTURE),
        pair(gc.GA_RelVerify, 1),
        pair(cv.CANVAS_Width, 400),
        pair(cv.CANVAS_Height, 180),
        .{},
    })) orelse return noWindow(dl);

    // The cover beside its lines, square and as tall as the row; the
    // slider between the time and the length; the deck, shuffle and
    // repeat, and after the space the sound off, the volume and the
    // output, in a row that breaks where the window is narrow; the picture
    // in a sunk frame, taking what is left.
    const info_row = group(ib, &loose, &.{ pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ), pair(lg.LAYOUTA_Spacing, 8) }, &.{
        .{ .object = app.cover, .aspect = lg.aspect(1, 1), .min_height = cover_least, .max_height = cover.kept_size },
        .{ .object = app.block },
    }) orelse return noWindow(dl);
    const seek_row = group(ib, &loose, &.{ pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ), pair(lg.LAYOUTA_Spacing, 6) }, &.{
        .{ .object = app.time, .weight_width = 0 },
        .{ .object = app.position },
        .{ .object = app.length, .weight_width = 0 },
    }) orelse return noWindow(dl);
    const control_row = group(ib, &loose, &.{ pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ), pair(lg.LAYOUTA_Spacing, 8), pair(lg.LAYOUTA_Wrap, 1) }, &.{
        .{ .object = app.deck, .weight_width = 0 },
        .{ .object = app.shuffle_button, .weight_width = 0 },
        .{ .object = app.repeat_button, .weight_width = 0 },
        .{},
        .{ .object = app.mute_button, .weight_width = 0 },
        .{ .object = app.volume, .weight_width = 0 },
        .{ .object = app.output, .weight_width = 0, .label = "_Output" },
    }) orelse return noWindow(dl);
    const framed = group(ib, &loose, &.{ pair(lg.LAYOUTA_FrameType, ic.FRAME_BUTTON), pair(lg.LAYOUTA_FrameRecessed, 1) }, &.{
        .{ .object = app.picture },
    }) orelse return noWindow(dl);
    // The tags' row grows half as fast as the picture, until the cover
    // is as large as it is kept.
    const layout = group(ib, &loose, &.{ pair(lg.LAYOUTA_Margin, 6), pair(lg.LAYOUTA_Spacing, 6) }, &.{
        .{ .object = info_row, .weight_height = 50, .max_height = cover.kept_size },
        .{ .object = seek_row, .weight_height = 0 },
        .{ .object = control_row, .weight_height = 0 },
        .{ .object = framed },
    }) orelse return noWindow(dl);
    // The screen the window opens on, which the menus are laid out for.
    const screen = ib.LockPubScreen(null) orelse return noWindow(dl);
    defer ib.UnlockPubScreen(null, screen);
    app.screen = screen;
    app.dri = ib.GetScreenDrawInfo(screen);
    defer ib.FreeScreenDrawInfo(screen, app.dri);
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        pair(wn.WA_PubScreen, @intFromPtr(screen)),
        pair(wn.WA_Title, @intFromPtr(COMMAND_NAME)),
        pair(wn.WA_ScreenTitle, @intFromPtr(SCREEN_TITLE)),
        pair(wn.WA_CloseGadget, 1),
        pair(wn.WA_DragBar, 1),
        pair(wn.WA_DepthGadget, 1),
        pair(wn.WA_SizeGadget, 1),
        pair(wn.WA_Activate, 1),
        pair(wn.WA_IDCMP, wn.IDCMP_IDCMPUPDATE | wn.IDCMP_NEWSIZE | wn.IDCMP_ACTIVEWINDOW),
        pair(wc.WINDOWA_Layout, @intFromPtr(layout)),
        .{},
    }) orelse return noWindow(dl);
    loose.take(layout);
    defer ib.DisposeObject(object);
    app.object = object;

    var open = wc.WmOpen{};
    const opened = ib.SendMessage(object, @ptrCast(&open));
    if (opened == 0) {
        _ = Printf(dl, MSG_NOWINDOW, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    }
    app.window = @ptrFromInt(opened);
    // The large cover's window, closed before this one.
    defer app.big.close(ib);
    app.fitPicture();
    app.set(app.cover, &.{ pair(cv.CANVAS_Width, 0), pair(cv.CANVAS_Height, 0), .{} });
    app.showCover(null, "");

    // The menus, the look started with ticked; the window plays without
    // them when they will not go on.
    var table = menus;
    table[first_look + @intFromEnum(look.mode)].flags |= mn.CHECKED;
    app.strip = blk: {
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

    // The clock the pictures are drawn by.
    const bit = sys.AllocSignal(-1);
    if (bit < 0) return dos.RETURN_FAIL;
    defer sys.FreeSignal(bit);
    app.timer = app.mb.CreateTimerTagList(&[_]TagItem{
        pair(motion.TIMER_Period, look_period),
        pair(motion.TIMER_Repeat, motion.TIMER_FOREVER),
        pair(motion.TIMER_Signal, @intCast(bit)),
        .{},
    }) orelse return dos.RETURN_FAIL;
    defer app.mb.DeleteTimer(app.timer);
    app.tick_mask = @as(u32, 1) << @intCast(bit);

    app.drop.add(sys, app.window);
    defer app.drop.remove();

    // Open...'s port; the requester is made the first time it is asked
    // for, and taken down before the window closes.
    if (app.al != null) app.asl_port = sys.CreateMsgPort();
    defer app.dropRequest();

    _ = sys.SetSignal(0, exec.SIGBREAKF_CTRL_C);
    if (app.count > 0) app.goTo(0, .play) else app.wake();
    app.run();
    return dos.RETURN_OK;
}
