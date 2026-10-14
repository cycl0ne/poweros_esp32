// SPDX-License-Identifier: MIT
//! Player: sound files played in a window - WAV, MP3, FLAC and Ogg Vorbis
//! - with a picture of the sound under the controls. Built against the
//! SDK only.
//!
//!   Player FILES/M,VOLUME/K/N,LOOK/K
//!
//! FILES are played one after another; VOLUME is in percent of as
//! recorded (100), LOOK the picture to start with: PLASMA, WAVE or BARS.
//! A file picked in the window, typed into its line or dropped on it from
//! the desktop is played at once instead.
//!
//! At the top of the window, the song's cover beside what its tags say:
//! the title, the artist, the album and its year, the genre, the track and
//! the composer, the chapter of a mix or a book that is playing - or a
//! comment - and what kind of file it is. The cover is the picture the
//! tags hold, or one lying beside the file (cover.zig). Then a slider
//! across that is where the song is, with the time beside it, which a drag
//! moves; the buttons of a tape deck - rewind and fast forward jump ten
//! seconds, pause holds the sound where it is, stop goes back to the
//! start; the volume; which picture; the file. Under them, as big as the
//! window lets it be, the picture:
//!
//! - **Plasma** - waves of colour, driven faster by the bass, turned by
//!   the treble, lit by the loudness.
//! - **Wave** - the sound itself, a hundredth of a second of it.
//! - **Bars** - the spectrum, from 40 Hz at the left to 16 kHz.
//!
//! A press on the picture, or the gadget above it, goes to the next. The
//! space bar pauses and goes on.
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
const classusr = intuition.classusr;
const ie = sdk.devices.inputevent;
const tx = sdk.gadgets.text;
const sl = sdk.gadgets.slider;
const td = sdk.gadgets.tapedeck;
const cy = sdk.gadgets.cycle;
const gf = sdk.gadgets.getfile;
const cv = sdk.gadgets.canvas;

const engine_file = @import("engine.zig");
const Engine = engine_file.Engine;
const visual = @import("visual.zig");
const Visual = visual.Visual;
const cover = @import("cover.zig");

pub const COMMAND_NAME = "Player";
const VERSION = "1.2";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (14.10.2026)\r\n";
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
const ID_LOOK = 4;
const ID_FILE = 5;
const ID_PICTURE = 6;

/// A look every 40 ms; the time beside the slider every sixth.
const look_period = 40;
const looks_per_time = 6;
/// Looks drawn after the sound stops, so the bars fall and the trail
/// fades before the picture rests.
const settle_looks = 50;
/// How far rewind and fast forward jump, in seconds.
const jump_seconds = 10;

/// The lines beside the cover, and the cover's size.
const line_title = 0;
const line_artist = 1;
const line_album = 2;
const line_more = 3;
const line_chapter = 4;
const line_format = 5;
const line_count = 6;
const cover_size = 112;
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

/// The pictures' names, in `visual.Mode`'s order.
const look_labels = [_:null]?[*:0]const u8{ "Plasma", "Wave", "Bars" };

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
    lines: [line_count]*Object = undefined,
    cover: *Object = undefined,
    position: *Object = undefined,
    clock: *Object = undefined,
    deck: *Object = undefined,
    volume: *Object = undefined,
    look: *Object = undefined,
    file: *Object = undefined,
    picture: *Object = undefined,

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
    /// A file picked or dropped: the list is then this one.
    picked: [dos.path_max + 1]u8 = @splat(0),
    picked_list: [1]?[*:0]const u8 = .{null},

    /// The position slider held: the time shows where it would go.
    dragging: bool = false,
    shown_second: u32 = ~@as(u32, 0),
    line_text: [line_count]Line(160) = [_]Line(160){.{}} ** line_count,
    /// The title in bold: a run of the first line's text.
    title_runs: [2]tx.TextRun = .{ .{}, .{} },
    /// The song's chapters, and the one shown.
    chapters: ?[*]const ac.AudioChapter = null,
    chapter_count: u32 = 0,
    chapter_shown: u32 = no_chapter,
    clock_text: [32:0]u8 = @splat(0),
    drop: sdk.anvil.DropTarget = .{},

    fn set(app: *App, gadget: *Object, tags: []const TagItem) void {
        _ = app.ib.SetGadgetAttrsTagList(gadget, app.window, tags.ptr);
    }

    // --- the song --------------------------------------------------------------

    /// File `index` of the list: shown, then played from its start.
    fn playAt(app: *App, index: usize) void {
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
            app.chapters = null;
            app.chapter_count = 0;
            app.showLines();
            app.showCover(null, name);
            app.showDeck(td.BUT_STOP, false);
            app.wake();
            return;
        }
        app.showSong(name, err == engine_file.no_sound);
        if (err == engine_file.no_sound) {
            app.showDeck(td.BUT_STOP, false);
        } else {
            app.engine.start();
            app.showDeck(td.BUT_PLAY, false);
        }
        app.wake();
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
        app.showTime();
    }

    /// One number through a RawDoFmt format into `into`.
    fn formatNumber(app: *App, into: [*:0]u8, comptime pattern: [:0]const u8, number: u32) void {
        const stream = exec.fmtStream(.{number});
        comptime exec.checkFormat(pattern, @TypeOf(.{@as(u32, 0)}));
        _ = app.sys.RawDoFmt(pattern, &stream, null, into);
    }

    /// Every line beside the cover drawn as it now reads.
    fn showLines(app: *App) void {
        app.title_runs[0] = .{ .text = &app.line_text[line_title].text, .style = graphics.FSF_BOLD };
        app.set(app.lines[line_title], &.{ pair(tx.TEXT_Runs, @intFromPtr(&app.title_runs)), .{} });
        for (app.lines[1..], app.line_text[1..]) |line, *text| {
            app.set(line, &.{ pair(tx.TEXT_Text, @intFromPtr(&text.text)), .{} });
        }
    }

    /// The cover drawn: the picture the tags hold, one beside the song, or
    /// the dark ground.
    fn showCover(app: *App, picture: ?*const ac.AudioPicture, name: [*:0]const u8) void {
        var value: usize = 0;
        _ = app.ib.GetAttr(cv.CANVAS_RastPort, app.cover, &value);
        if (value == 0) return;
        const rp: *graphics.RastPort = @ptrFromInt(value);
        _ = cover.draw(.{ .sys = app.sys, .dl = app.dl, .gb = app.gb, .dt = app.dt }, rp, cover_size, picture, name);
        app.ib.QueueGadgetRefresh(app.cover);
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
        app.set(app.lines[line_chapter], &.{ pair(tx.TEXT_Text, @intFromPtr(&line.text)), .{} });
    }

    fn showDeck(app: *App, mode: u32, paused: bool) void {
        app.set(app.deck, &.{ pair(td.TDECK_Mode, mode), pair(td.TDECK_Paused, @intFromBool(paused)), .{} });
    }

    /// Frames of the song as whole seconds.
    fn seconds(app: *App, frames: u32) u32 {
        return frames / @max(app.engine.info.rate, 1);
    }

    /// The time beside the slider: `at` of the song's length.
    fn writeClock(app: *App, at: u32) void {
        const total = app.seconds(app.engine.info.frames);
        const stream = exec.fmtStream(.{ at / 60, at % 60, total / 60, total % 60 });
        comptime exec.checkFormat("%u:%02u / %u:%02u", @TypeOf(.{ @as(u32, 0), @as(u32, 0), @as(u32, 0), @as(u32, 0) }));
        _ = app.sys.RawDoFmt("%u:%02u / %u:%02u", &stream, null, &app.clock_text);
        app.set(app.clock, &.{ pair(tx.TEXT_Text, @intFromPtr(&app.clock_text)), .{} });
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

    /// The end of a song: the next one, or back to the start and still.
    fn ended(app: *App) void {
        if (app.current + 1 < app.count) {
            app.playAt(app.current + 1);
            return;
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
                    if (app.count > 0) app.playAt(app.current);
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
                    if (app.count > 0) app.playAt(app.current);
                    return;
                }
                engine.start();
            },
        }
        app.showDeck(td.BUT_PLAY, engine.state == .paused);
        app.wake();
    }

    fn cycleLook(app: *App) void {
        app.visual.cycle();
        app.set(app.look, &.{ pair(cy.CYCLE_Active, @intFromEnum(app.visual.mode)), .{} });
        app.wake();
    }

    /// A file picked in the getfile line: the list is that one now.
    fn pickedFile(app: *App, name: [*:0]const u8) void {
        var i: usize = 0;
        while (name[i] != 0 and i < dos.path_max) : (i += 1) app.picked[i] = name[i];
        app.picked[i] = 0;
        if (i == 0) return;
        app.picked_list[0] = @ptrCast(&app.picked);
        app.list = &app.picked_list;
        app.count = 1;
        app.playAt(0);
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
            ID_VOLUME => {
                const level: i32 = @bitCast(code);
                app.engine.setVolume(@intCast(@max(level, 0)));
            },
            ID_LOOK => {
                app.visual.mode = @enumFromInt(@min(code, visual.mode_count - 1));
                app.visual.width = 0;
                app.wake();
            },
            ID_PICTURE => app.cycleLook(),
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
                app.engine.setVolume(@intCast(@max(@as(i32, @bitCast(@as(u32, @truncate(value)))), 0)));
            },
            ID_FILE => {
                _ = app.ib.GetAttr(gf.GETFILE_FullFile, app.file, &value);
                if (value != 0) app.pickedFile(@ptrFromInt(value));
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
            if (word == wc.WMHI_LASTMSG) return true;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => return false,
                wc.WMHI_GADGETUP => app.gadgetUp(word & wc.WMHI_GADGETMASK, code),
                wc.WMHI_IDCMPUPDATE => app.updated(),
                wc.WMHI_VANILLAKEY => if (word & wc.WMHI_KEYMASK == ' ') app.togglePause(),
                wc.WMHI_NEWSIZE => {
                    app.fitPicture();
                    app.wake();
                },
                else => {},
            }
        }
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

    /// The canvas's RastPort and size read, and pixels for that size.
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
        if (app.pixels) |old| app.sys.FreeVec(old);
        app.pixels = null;
        app.width = 0;
        app.height = 0;
        const memory = app.sys.AllocVec(@as(usize, w) * h * 4, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return;
        app.pixels = @ptrCast(@alignCast(memory));
        app.width = w;
        app.height = h;
        app.visual.width = 0;
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
        if (app.pixels) |pixels| {
            if (app.rast_port) |rp| {
                engine.heard(&app.samples);
                app.visual.draw(pixels, app.width, app.height, app.width, &app.samples, @max(engine.info.rate, 8000));
                app.gb.WritePixelArray(rp, @ptrCast(pixels), app.width * 4, @intFromEnum(PixelFormat.bgra32), 0, 0, &.{
                    .max_x = @intCast(app.width),
                    .max_y = @intCast(app.height),
                });
                app.ib.QueueGadgetRefresh(app.picture);
            }
        }
        app.looks +%= 1;
        if (app.looks % looks_per_time == 0) app.showTime();
        if (engine.state == .playing) {
            app.settle = settle_looks;
        } else if (app.settle > 0) {
            app.settle -= 1;
        } else {
            app.mb.StopTimer(app.timer);
            app.ticking = false;
        }
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
            const got = app.sys.Wait(@as(u32, @truncate(window_mask)) | sound_mask | app.tick_mask | drop_mask | exec.SIGBREAKF_CTRL_C);
            if (got & exec.SIGBREAKF_CTRL_C != 0) return;
            if (got & sound_mask != 0) app.serviceSound();
            if (got & drop_mask != 0) app.dropped();
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
    items: [24]?*Object = @splat(null),
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

/// A child of a layout, with what it is told about its room.
const Child = struct {
    object: *Object,
    weight_width: ?u32 = null,
    weight_height: ?u32 = null,
    /// Never smaller than this, whatever the window's size.
    min_width: ?u32 = null,
    min_height: ?u32 = null,
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
        list[n] = pair(lg.LAYOUTA_AddChild, @intFromPtr(child.object));
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
        if (child.label) |label| {
            list[n] = pair(lg.CHILDA_Label, @intFromPtr(label));
            n += 1;
        }
    }
    list[n] = .{};
    const made = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &list) orelse return null;
    for (children) |child| loose.take(child.object);
    return loose.add(made);
}

fn noWindow(dl: *DosBase) i32 {
    _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
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
    const percent: u32 = @intCast(@min(@max(rdargs.number(argv[arg_volume]) orelse 100, 0), 200));

    var libraries: [10]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    const wanted = [_][*:0]const u8{
        intuition.INTUITIONNAME, graphics.GRAPHICSNAME, motion.MOTIONNAME, ac.AUDIOCODECNAME,
        tx.TEXT_LIBRARY,         sl.SLIDER_LIBRARY,     td.TDECK_LIBRARY,  cy.CYCLE_LIBRARY,
        gf.GETFILE_LIBRARY,      cv.CANVAS_LIBRARY,
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
        .has_attrs = acb.lib().revision >= 1,
        .engine = engine,
        .visual = look,
    };
    defer if (app.pixels) |pixels| sys.FreeVec(pixels);
    if (argv[arg_files] != 0) {
        app.list = @ptrFromInt(argv[arg_files]);
        while (app.list[app.count] != null) app.count += 1;
    }
    app.line_text[line_title].add("No song");
    if (!engine.opened) app.line_text[line_format].add(soundTrouble(engine));
    app.title_runs[0] = .{ .text = &app.line_text[line_title].text, .style = graphics.FSF_BOLD };

    // The gadgets: each loose until a layout takes it, and whatever is
    // still loose given back when the window cannot be made.
    var loose: Loose = .{};
    defer loose.dispose(ib);
    for (&app.lines, &app.line_text, 0..) |*line, *text, i| {
        line.* = loose.add(ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
            if (i == line_title) pair(tx.TEXT_Runs, @intFromPtr(&app.title_runs)) else pair(tx.TEXT_Text, @intFromPtr(&text.text)),
            pair(tx.TEXT_Clipped, 1),
            pair(gc.GA_Width, 240),
            .{},
        })) orelse return noWindow(dl);
    }
    app.cover = loose.add(ib.NewObjectTagList(null, cv.CANVAS_CLASS, &[_]TagItem{
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
    app.clock = loose.add(ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        pair(tx.TEXT_Text, @intFromPtr("0:00 / 0:00")),
        pair(tx.TEXT_Justification, tx.TEXT_JUSTIFY_RIGHT),
        pair(gc.GA_Width, 110),
        .{},
    })) orelse return noWindow(dl);
    app.deck = loose.add(ib.NewObjectTagList(null, td.TDECK_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_DECK),
        pair(td.TDECK_Tape, 1),
        pair(td.TDECK_Mode, td.BUT_STOP),
        .{},
    })) orelse return noWindow(dl);
    app.volume = loose.add(ib.NewObjectTagList(null, sl.SLIDER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_VOLUME),
        pair(sl.SLIDER_Max, 200),
        pair(sl.SLIDER_Level, percent),
        pair(sl.SLIDER_LevelFormat, @intFromPtr("%ld%%")),
        pair(sl.SLIDER_MaxLevelLen, 4),
        pair(icc.ICA_TARGET, icc.ICTARGET_IDCMP),
        pair(gc.GA_Width, 80),
        .{},
    })) orelse return noWindow(dl);
    app.look = loose.add(ib.NewObjectTagList(null, cy.CYCLE_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_LOOK),
        pair(cy.CYCLE_Labels, @intFromPtr(&look_labels)),
        pair(cy.CYCLE_Active, @intFromEnum(look.mode)),
        .{},
    })) orelse return noWindow(dl);
    app.file = loose.add(ib.NewObjectTagList(null, gf.GETFILE_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_FILE),
        pair(gf.GETFILE_TitleText, @intFromPtr("Which song?")),
        pair(gf.GETFILE_Drawer, @intFromPtr("SYS:")),
        pair(gf.GETFILE_Pattern, @intFromPtr("#?.(mp3|wav|flac|ogg|oga)")),
        pair(icc.ICA_TARGET, icc.ICTARGET_IDCMP),
        .{},
    })) orelse return noWindow(dl);
    app.picture = loose.add(ib.NewObjectTagList(null, cv.CANVAS_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_PICTURE),
        pair(gc.GA_RelVerify, 1),
        pair(cv.CANVAS_Width, 400),
        pair(cv.CANVAS_Height, 180),
        .{},
    })) orelse return noWindow(dl);

    // The cover beside its lines; the slider with the time beside it; the
    // deck, the volume and the picture's name in a row; the file; the
    // picture taking what is left.
    var line_children: [line_count]Child = undefined;
    for (&line_children, app.lines) |*child, line| child.* = .{ .object = line, .weight_height = 0 };
    const lines = group(ib, &loose, &.{pair(lg.LAYOUTA_Spacing, 1)}, &line_children) orelse return noWindow(dl);
    const info_row = group(ib, &loose, &.{ pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ), pair(lg.LAYOUTA_Spacing, 8) }, &.{
        .{ .object = app.cover, .weight_width = 0, .weight_height = 0, .min_width = cover_size, .min_height = cover_size },
        .{ .object = lines },
    }) orelse return noWindow(dl);
    const seek_row = group(ib, &loose, &.{ pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ), pair(lg.LAYOUTA_Spacing, 6) }, &.{
        .{ .object = app.position },
        .{ .object = app.clock, .weight_width = 0 },
    }) orelse return noWindow(dl);
    const control_row = group(ib, &loose, &.{ pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ), pair(lg.LAYOUTA_Spacing, 8) }, &.{
        .{ .object = app.deck, .weight_width = 0 },
        .{ .object = app.volume, .label = "_Volume" },
        .{ .object = app.look, .weight_width = 0 },
    }) orelse return noWindow(dl);
    const layout = group(ib, &loose, &.{ pair(lg.LAYOUTA_Margin, 6), pair(lg.LAYOUTA_Spacing, 6) }, &.{
        .{ .object = info_row, .weight_height = 0 },
        .{ .object = seek_row, .weight_height = 0 },
        .{ .object = control_row, .weight_height = 0 },
        .{ .object = app.file, .weight_height = 0 },
        .{ .object = app.picture },
    }) orelse return noWindow(dl);
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        pair(wn.WA_Title, @intFromPtr(COMMAND_NAME)),
        pair(wn.WA_ScreenTitle, @intFromPtr(SCREEN_TITLE)),
        pair(wn.WA_CloseGadget, 1),
        pair(wn.WA_DragBar, 1),
        pair(wn.WA_DepthGadget, 1),
        pair(wn.WA_SizeGadget, 1),
        pair(wn.WA_Activate, 1),
        pair(wn.WA_IDCMP, wn.IDCMP_IDCMPUPDATE | wn.IDCMP_NEWSIZE),
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
    app.fitPicture();
    app.showCover(null, "");

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

    _ = sys.SetSignal(0, exec.SIGBREAKF_CTRL_C);
    if (app.count > 0) app.playAt(0) else app.wake();
    app.run();
    return dos.RETURN_OK;
}
