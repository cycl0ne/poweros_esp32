// SPDX-License-Identifier: MIT
//! Player: sound files played in a window - WAV, MP3, FLAC and Ogg Vorbis
//! - and stations heard over the network, with a picture of the sound
//! under the controls. Built against the SDK only.
//!
//!   Player FILES/M,ADD/S,VOLUME/K/N,LOOK/K
//!
//! FILES make the playlist - a drawer its sound files, an address that
//! starts `http://` or `https://` a station - and the first is played; with ADD they are added to the list kept and nothing more.
//! VOLUME is in percent of as recorded, LOOK the picture to start with:
//! PLASMA, WAVE or BARS. Each left out is as the Player was left.
//!
//! **One Player** (one.zig). The Player keeps the public port `Player`;
//! a start while it runs hands its files over by their full names, with
//! ADD, VOLUME and LOOK, and ends. The Player running adds them and plays
//! the first, or only adds them with ADD; without ADD its window comes to
//! the front, which is all a start with nothing given asks.
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
//! the cover at its own size in a window of its own (big.zig), which
//! follows the songs from then on. Then a slider
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
//! be, two pages under tabs (page.gadget with a clicktab.gadget): Now
//! playing, the picture sunk in a frame, and Playlist, the list.
//!
//! The picture:
//!
//! - **Plasma** - waves of colour, driven faster by the bass, turned by
//!   the treble, lit by the loudness.
//! - **Wave** - the sound itself, a hundredth of a second of it.
//! - **Bars** - the spectrum, from 40 Hz at the left to 16 kHz.
//!
//! The plasma and the bars are drawn in the cover's two leading colours
//! when it has some (colours.zig), and in their own otherwise.
//!
//! A press on the picture goes to the next; the Picture menu picks one.
//!
//! **Menus and keys.** Project: Open..., Open drawer... (a drawer's songs,
//! asked with `ASLFR_DrawersOnly`), Open URL... (a station's address, in
//! a small window of the Player's own: Return or Open adds it and plays
//! it - an address without `://` taken as `http://` - Esc or Cancel
//! closes it), About and Quit. About is a requester
//! put up without waiting (`BuildEasyRequestArgs`, `SysReqHandler`), so
//! the sound and the picture go on behind it. Playlist: Add..., Remove,
//! Clear, Shuffle and Repeat (Off, All, One), whose ticks follow the
//! toolbuttons as the toolbuttons follow them. The space bar pauses and
//! goes on, N and P are the song after and the song before, the cursor
//! keys left and right jump ten seconds and up and down turn the volume
//! five points; Return and Del work the list.
//!
//! **The playlist** (playlist.zig) is a listbrowser.gadget: each song's
//! place, title, artist and length, the song shown bold and marked
//! (`ROW_MARKED`). A double-click or Return plays a song; Del or Remove
//! takes the one selected out, and Clear every one. A row dragged moves
//! (`LISTBROWSER_Reorder`); a press on a heading sorts the list by it,
//! and it stays sorted as songs come and their tags are read. A song
//! added shows its file's name until its tags are read, a few songs at
//! each look of the picture. Add... picks songs to add, several at once -
//! a drawer named adds its sound files; Open... adds them too and plays
//! the first. Files dropped on the window from the desktop are added - a
//! drawer its sound files - and the first played when nothing plays.
//!
//! **The order.** The list is played in an order of its own - its own
//! order, or shuffled from the song playing on, with the chip's random
//! number generator (`sdk.hardware.rng`); the list as shown stays. A song
//! added to a shuffled list goes to a random place among those still to
//! come, and a song picked to play starts a new shuffle. At the end of
//! the order the sound stops; with repeat it starts again, shuffled anew,
//! and repeat one plays the song again. The song after and the song
//! before follow the deck: they play when it played, wait paused at their
//! start when it was paused, and are only shown when it was stopped. The
//! song shown taken out of the list makes way for the one after it in the
//! order, started as the deck was.
//!
//! **One song into the next.** A few seconds before a song ends the sound
//! asks for the song that follows in the order; the window opens it - its
//! tags and cover read here - and hands it over, and the sound goes on into
//! it without a gap (engine.zig). A change to what follows - the list, the
//! order, repeat - hands over the new one instead while the old is not yet
//! heard. Once it is heard the window shows it as the song, as `ended`
//! would have gone on to it, without loading it again.
//!
//! **Open..., Open drawer... and Add...** put up asl.library's file requester without
//! waiting for it (`ASLFR_ReplyPort`): it runs on a process of its own,
//! the window and the sound go on meanwhile, and its answer arrives as a
//! message on a port the window's loop waits on with everything else.
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
//! a buffer of 32-bit pixels as large as the canvas, whatever its size - a
//! window as large as its screen too (visual.zig) - put into a
//! canvas.gadget with WritePixelArray, which converts it to the display's
//! form, and shown with QueueGadgetRefresh. While nothing plays it settles for two seconds
//! and then rests.
//!
//! **The sound has a process of its own** (engine.zig), above every
//! program: the window gives it orders and is told when a song has ended,
//! and whatever the window does meanwhile - reading a cover, the large
//! one too, putting up a requester, following a sizing - the sound goes
//! on. A sizing goes a step at a time, each said with `IDCMP_NEWSIZE`, and
//! intuition takes the next step - and shows this one - once the program
//! has replied it, which windowclass does when the loop asks for its next
//! message. So the canvases are fitted and drawn on `WMHI_NEWSIZE`, before
//! that: the step is shown with them in it, never a step behind. What
//! fits of the picture is kept across a step, the wave's trail with it.
//!
//! **A song is shown as it starts**: its names and its cover first, then
//! its sound, so the window says what is playing from its first moment.
//!
//! **A station** (radio.zig, icy.zig) is an address in the list, called
//! when it is played. A process of its own reads what the station sends
//! into a ring - the sound, with the titles it puts in every so many bytes
//! taken out (`Icy-MetaData`) - and the sound's process decodes from that
//! ring as from a file (`ACA_ReadFunc`). The window shows the station's
//! name where an album's goes and as its row's title, its genre, the
//! title it sends as the song's - `Artist - Title` taken apart - its
//! address in the chapter's line, and `live` for the times; the slider
//! stays still. The sound starts once the ring holds two seconds of it,
//! and waits again - "buffering" - when it runs short. A connection lost
//! is called again, three times in a row, after a second, a second and
//! five seconds; a station that never sent sound, or sends no more, says
//! why, and one that sends AAC is refused. Stop ends the call and play
//! calls it again; a station kept in Player.list is shown at a start, not
//! called.
//!
//! **Remembered** (remembered.zig). As it ends the Player writes how it
//! was left to `ENV:` and `ENVARC:`: the window's box, the page, the look,
//! the volume, shuffle and repeat, and the drawer last opened
//! (Player.prefs), and the list with the song shown and the second it was
//! at (Player.list). Started without files it opens that list again and
//! shows the song where it was, paused - the sound moved there without
//! being started (`place`). Started with files, they are the list, and
//! VOLUME and LOOK given win over what was kept. Settings > Remember where
//! it was, turned off, keeps no list. The files are written once, as the
//! Player ends, so the disk is not written while songs play; a box kept
//! on a larger screen is squeezed onto a smaller one (`WA_AutoAdjust`).
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
const UtilityBase = sdk.interface.utility.UtilityBase;
const prefs = sdk.prefs;
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
const lb = sdk.gadgets.listbrowser;
const ct = sdk.gadgets.clicktab;
const pg = sdk.gadgets.page;
const sc = intuition.screens;
const diskfont = sdk.diskfont;
const DiskfontBase = sdk.interface.diskfont.DiskfontBase;
const audiocontrol = sdk.devices.audiocontrol;
const keyboard = sdk.devices.keyboard;

const engine_file = @import("engine.zig");
const Engine = engine_file.Engine;
const visual = @import("visual.zig");
const Visual = visual.Visual;
const cover = @import("cover.zig");
const big_window = @import("big.zig");
const playlist = @import("playlist.zig");
const Entry = playlist.Entry;
const remembered = @import("remembered.zig");
const one = @import("one.zig");
const radio = @import("radio.zig");
const icy = @import("icy.zig");
const st = sdk.gadgets.string;

pub const COMMAND_NAME = "Player";
const VERSION = "1.17";
const DATE = "29.10.2026";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (" ++ DATE ++ ")\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
/// What the screen's bar says while the window is active.
const SCREEN_TITLE = COMMAND_NAME ++ " " ++ VERSION;
/// How the Player names itself to a station.
const USER_AGENT = COMMAND_NAME ++ "/" ++ VERSION;

const template = "FILES/M,ADD/S,VOLUME/K/N,LOOK/K";
const arg_files = 0;
const arg_add = 1;
const arg_volume = 2;
const arg_look = 3;

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
const ID_TABS = 13;
const ID_LIST = 14;
const ID_ADD = 15;
const ID_REMOVE = 16;
const ID_CLEAR = 17;
/// Open URL...'s window: the address, Open and Cancel.
const ID_URL_TEXT = 20;
const ID_URL_OPEN = 21;
const ID_URL_CANCEL = 22;

/// The pages under the tabs.
const page_picture = 0;
const page_list = 1;
const page_names = [_:null]?[*:0]const u8{ "Now playing", "Playlist" };

/// A look every 40 ms; the time beside the slider every sixth.
const look_period = 40;
const looks_per_time = 6;
/// Looks drawn after the sound stops, so the bars fall and the trail
/// fades before the picture rests.
const settle_looks = 50;
/// How far rewind and fast forward jump, in seconds.
const jump_seconds = 10;
/// The volume slider's top, in percent of as recorded, and how far a
/// press of up or down moves it.
const volume_most = 200;
const volume_step = 5;
/// Within this many seconds of a song's start, the song before is the one
/// before; later, it is the start of this one.
const back_seconds = 3;
/// The volume slider's width, with its level beside it.
const volume_width = 120;
/// The least width of Open URL...'s field.
const url_width = 360;
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
/// Songs whose tags are read at each look, while some are not.
const reads_per_look = 2;

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

/// The menus: Project's songs and stations, About and Quit; the Playlist's, with
/// shuffle ticked and repeat's three ways, one ticked; the Picture's looks
/// in `visual.Mode`'s order, one ticked; Settings, whether the list and
/// where it was are kept for the next start. The ticks follow the buttons
/// and keys (`showMenuTicks`).
const MENU_PROJECT = 0;
const ITEM_OPEN = 0;
const ITEM_OPEN_DRAWER = 1;
const ITEM_OPEN_URL = 2;
const ITEM_ABOUT = 4;
const ITEM_QUIT = 5;
const MENU_PLAYLIST = 1;
const ITEM_ADD = 0;
const ITEM_REMOVE = 1;
const ITEM_CLEAR = 2;
const ITEM_SHUFFLE = 4;
const ITEM_REPEAT = 5;
const MENU_PICTURE = 2;
const MENU_SETTINGS = 3;
const ITEM_REMEMBER = 0;

fn menuItem(label: [*:0]const u8, key: ?[*:0]const u8) mn.NewMenu {
    return .{ .type = mn.NM_ITEM, .label = label, .comm_key = key };
}

const bar = mn.NewMenu{ .type = mn.NM_ITEM, .label = mn.NM_BARLABEL };

/// One of `count` items that exclude each other, the `at`th.
fn oneOf(kind: u8, label: [*:0]const u8, at: u5, count: u5) mn.NewMenu {
    const all = (@as(u32, 1) << count) - 1;
    return .{ .type = kind, .label = label, .flags = mn.CHECKIT, .mutual_exclude = all & ~(@as(u32, 1) << at) };
}

const menus = [_]mn.NewMenu{
    .{ .type = mn.NM_TITLE, .label = "Project" },
    menuItem("Open...", "O"),
    menuItem("Open drawer...", "D"),
    menuItem("Open URL...", "U"),
    bar,
    menuItem("About", null),
    menuItem("Quit", "Q"),
    .{ .type = mn.NM_TITLE, .label = "Playlist" },
    menuItem("Add...", "A"),
    menuItem("Remove", null),
    menuItem("Clear", null),
    bar,
    .{ .type = mn.NM_ITEM, .label = "Shuffle", .flags = mn.CHECKIT | mn.MENUTOGGLE },
    menuItem("Repeat", null),
    oneOf(mn.NM_SUB, "Off", @intFromEnum(Repeat.off), 3),
    oneOf(mn.NM_SUB, "All", @intFromEnum(Repeat.all), 3),
    oneOf(mn.NM_SUB, "One", @intFromEnum(Repeat.one), 3),
    .{ .type = mn.NM_TITLE, .label = "Picture" },
    oneOf(mn.NM_ITEM, "Plasma", @intFromEnum(visual.Mode.plasma), visual.mode_count),
    oneOf(mn.NM_ITEM, "Wave", @intFromEnum(visual.Mode.wave), visual.mode_count),
    oneOf(mn.NM_ITEM, "Bars", @intFromEnum(visual.Mode.bars), visual.mode_count),
    .{ .type = mn.NM_TITLE, .label = "Settings" },
    .{ .type = mn.NM_ITEM, .label = "Remember where it was", .flags = mn.CHECKIT | mn.MENUTOGGLE },
    .{},
};

/// The song shown when the Player last ended, and the second it was at.
const Resume = struct { entry: *Entry, second: u32 };

/// What the file requester is up for: songs to play, songs to add, or a
/// drawer's songs to play.
const Ask = enum { play, add, drawer };

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

        fn addBytes(line: *Self, piece: []const u8) void {
            for (piece) |byte| {
                if (line.len == size) break;
                line.text[line.len] = byte;
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

        fn same(line: *const Self, other: *const Self) bool {
            if (line.len != other.len) return false;
            for (line.text[0..line.len], other.text[0..other.len]) |mine, theirs| {
                if (mine != theirs) return false;
            }
            return true;
        }
    };
}

/// Open URL...'s window, while it is open.
const UrlWindow = struct {
    object: *Object,
    window: *Window,
    field: *Object,
};

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
    /// The pages and their tabs, the page shown, and the list.
    book: *Object = undefined,
    pages: [page_names.len:null]?*Object = @splat(null),
    page: u32 = page_picture,
    browser: *Object = undefined,
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

    /// The songs, and the one shown - playing, paused or stopped.
    songs: playlist.Playlist = .{},
    playing: ?*Entry = null,
    /// The order they are played in - the list's own, or shuffled - every
    /// song once, `ordered` of them; `step` is where in it the song shown
    /// is, or with none the song to start at. Without the memory for it,
    /// the list's own.
    order: ?[*]*Entry = null,
    ordered: usize = 0,
    order_room: usize = 0,
    step: usize = 0,
    /// The song handed to the sound to follow the one shown without a
    /// gap, and the one last tried - opened or not - so it is not tried
    /// again; as of the sound's `follow_round`.
    following: ?*Entry = null,
    follow_tried: ?*Entry = null,
    follow_round: u32 = 0,
    shuffled: bool = false,
    repeat: Repeat = .off,
    /// The sound off, and the volume it comes back at.
    muted: bool = false,
    level: u32 = 100,
    /// The length after the slider says what is left instead.
    show_left: bool = false,
    /// The song is an hour or more: its times with hours.
    long: bool = false,
    /// The file requester of Open..., Open drawer... and Add..., made the
    /// first time, and the port its answer comes to; `asking` while it is
    /// up, for what `asked`. None without asl.library.
    al: ?*AslBase = null,
    request: ?*anyopaque = null,
    asl_port: ?*exec.MsgPort = null,
    asking: bool = false,
    asked: Ask = .play,
    /// About's requester while it is up.
    about_window: ?*intuition.Window = null,
    /// The public port a second start hands its files to (one.zig).
    public: ?*exec.MsgPort = null,
    /// The station listened to, while it is (radio.zig): connecting,
    /// filling its ring, or played - `station_loaded` once the sound reads
    /// it, how it is to start until then - and what it said last.
    station: ?*radio.Radio = null,
    station_loaded: bool = false,
    station_how: Start = .play,
    station_facts: radio.Facts = .{},
    /// How far the ring was to a start when it was last shown, and why the
    /// station shown could not be listened to.
    station_percent: u32 = 0,
    station_why: [128:0]u8 = @splat(0),
    /// Open URL...'s window while it is up, the address last opened in
    /// it, and string.gadget for its field - opened the first time.
    url_window: ?UrlWindow = null,
    url_text: [dos.path_max + 1:0]u8 = @splat(0),
    string_lib: ?*exec.Library = null,
    /// Whether the list and where it was are kept for the next start
    /// (Settings > Remember where it was), and the drawer the file
    /// requester was last answered in - both from the run before, too.
    remember: bool = true,
    drawer: [dos.path_max + 1:0]u8 = @splat(0),

    /// The position slider held: the time shows where it would go.
    dragging: bool = false,
    shown_second: u32 = ~@as(u32, 0),
    line_text: [line_count]Line(160) = [_]Line(160){.{}} ** line_count,
    /// The kind of file the song is, which the kind line starts with, and
    /// whether the machine cannot play it.
    kind_text: Line(64) = .{},
    silent: bool = false,
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

    /// A gadget on page `page` set: drawn when the page is shown, and
    /// only changed when it is not, where drawing it would cover the page
    /// that is.
    fn setOn(app: *App, page: u32, gadget: *Object, tags: []const TagItem) void {
        _ = app.ib.SetGadgetAttrsTagList(gadget, if (app.page == page) app.window else null, tags.ptr);
    }

    // --- the song --------------------------------------------------------------

    /// `entry` shown, its row marked, then started as `how` says - a
    /// station listened to (`playStation`).
    fn playAt(app: *App, entry: *Entry, how: Start) void {
        const name = entry.path();
        if (playlist.isUrl(name)) return app.playStation(entry, how);
        app.stopStation();
        const err = app.engine.load(name);
        app.kind_text.clear();
        app.silent = err == engine_file.no_sound;
        // What the sound read of it is its row's too.
        if (err == 0 or err == engine_file.no_sound) app.songs.filled(app.sys, entry, &app.engine.info);
        app.markPlaying(entry);
        app.visual.quiet();
        app.shown_second = ~@as(u32, 0);
        if (err != 0 and err != engine_file.no_sound) {
            const shown = playlist.fileName(name);
            for (&app.line_text) |*line| line.clear();
            const title = &app.line_text[line_title];
            title.add(shown);
            title.add(": ");
            title.add(app.acb.AudioErrorText(err));
            app.showTitle(shown);
            app.chapters = null;
            app.chapter_count = 0;
            app.showLines();
            app.showCover(null, name, shown);
            app.showRange(0);
            app.showTime();
            app.showDeck(td.BUT_STOP, false);
            app.wake();
            return;
        }
        app.showSong(name);
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

    // --- a station -----------------------------------------------------------

    /// The song shown is a station.
    fn showsStation(app: *const App) bool {
        const entry = app.playing orelse return false;
        return playlist.isUrl(entry.path());
    }

    /// A station is being called, or its ring filled, and the sound does
    /// not read it yet.
    fn connecting(app: *const App) bool {
        return app.station != null and !app.station_loaded;
    }

    /// `entry`, a station, shown and - unless `how` is to stop - called;
    /// played as `how` says once enough of it has come (`stationNews`).
    fn playStation(app: *App, entry: *Entry, how: Start) void {
        app.stopStation();
        app.engine.unload();
        app.markPlaying(entry);
        app.visual.quiet();
        app.shown_second = ~@as(u32, 0);
        app.kind_text.clear();
        app.silent = false;
        app.chapters = null;
        app.chapter_count = 0;
        app.station_facts = .{};
        app.station_why = @splat(0);
        app.station_how = how;
        app.station_percent = 0;
        if (how != .stop) {
            app.station = radio.Radio.start(app.sys, app.dl, entry.path(), USER_AGENT);
            if (app.station == null) app.tellWhy("No memory for the station");
        }
        app.showStation();
        app.showCover(null, "", &app.line_text[line_title].text);
        app.showRange(0);
        app.keepRoom(false);
        app.showTime();
        app.showDeck(if (app.station != null) td.BUT_PLAY else td.BUT_STOP, how == .pause);
        app.wake();
    }

    /// The station listened to let go of: its reader told to end - which
    /// ends the sound's reading of its ring too - the sound given back,
    /// and the reader waited for.
    fn stopStation(app: *App) void {
        const station = app.station orelse return;
        station.halt();
        app.engine.unload();
        station.free();
        app.station = null;
        app.station_loaded = false;
    }

    /// The station says something: how it goes, what it is, what plays,
    /// or - before the sound reads it - that its ring has filled. Once it
    /// holds what a start wants, the sound opens on it.
    fn stationNews(app: *App) void {
        const station = app.station orelse return;
        const phase = app.station_facts.phase;
        const titles = app.station_facts.titles;
        station.facts(&app.station_facts);
        const facts = &app.station_facts;
        const changed = facts.phase != phase or facts.titles != titles;
        if (app.station_loaded) {
            if (changed) app.showStation();
            return;
        }
        switch (facts.phase) {
            .failed => return app.stationFailed(&facts.why),
            .streaming => if (station.holds(station.startBytes())) return app.listenNow(),
            .connecting, .halted => {},
        }
        // How far the ring is, in tens.
        const percent = station.percent();
        if (!changed and percent / 10 == app.station_percent / 10) return;
        app.station_percent = percent;
        app.showStation();
    }

    /// Enough of the station has come: the sound opened on its ring and
    /// started as the deck says - or why not said.
    fn listenNow(app: *App) void {
        const station = app.station orelse return;
        const err = app.engine.listen(station);
        app.station_loaded = true;
        station.begun();
        if (err == engine_file.no_sound) return app.stationFailed(soundTrouble(app.engine));
        if (err != 0) return app.stationFailed(app.acb.AudioErrorText(err));
        app.describeSound();
        app.showStation();
        app.engine.start();
        if (app.station_how == .pause) app.engine.pause(true);
        app.showDeck(td.BUT_PLAY, app.station_how == .pause);
        app.showTime();
        app.wake();
    }

    /// The station could not be listened to, or stopped sending: why is
    /// said where its sound's kind goes, and it is let go of. Play calls
    /// it again.
    fn stationFailed(app: *App, why: [*:0]const u8) void {
        var told: [128:0]u8 = @splat(0);
        const length = @min(lengthOf(why), told.len);
        @memcpy(told[0..length], why[0..length]);
        app.stopStation();
        app.tellWhy(&told);
        app.visual.quiet();
        app.showStation();
        app.showDeck(td.BUT_STOP, false);
        app.showTime();
    }

    /// The station's sound played out: it stopped sending, and its ring
    /// is empty.
    fn stationEnded(app: *App) void {
        if (app.station) |station| station.facts(&app.station_facts);
        const why = &app.station_facts.why;
        app.stationFailed(if (why[0] != 0) why else "The station stopped sending");
    }

    fn tellWhy(app: *App, why: [*:0]const u8) void {
        app.station_why = @splat(0);
        const length = @min(lengthOf(why), app.station_why.len);
        @memcpy(app.station_why[0..length], why[0..length]);
    }

    /// The station's lines: what plays - the title its metadata names, its
    /// artist apart - or else its name; its name and its genre under that;
    /// its address; and how it goes. The window's title is the first line,
    /// and the station's row takes its name once it says it.
    fn showStation(app: *App) void {
        const entry = app.playing orelse return;
        const facts = &app.station_facts;
        for (&app.line_text) |*line| line.clear();
        const named = icy.split(facts.title[0..lengthOf(&facts.title)]);
        const title = &app.line_text[line_title];
        if (named.title.len > 0) {
            title.addBytes(named.title);
            app.line_text[line_artist].addBytes(named.artist);
            app.line_text[line_album].add(&facts.name);
        } else if (facts.name[0] != 0) {
            title.add(&facts.name);
        } else {
            title.add(@ptrCast(&entry.title));
        }
        app.line_text[line_more].add(&facts.genre);
        app.line_text[line_chapter].add(entry.path());
        app.composeKind();
        app.showTitle(&title.text);
        app.showLines();
        if (facts.name[0] != 0 and !sameText(@ptrCast(&entry.title), &facts.name)) {
            entry.retitle(&facts.name);
            app.rowsChanged();
        }
    }

    /// A station's kind line: why it could not be listened to; that it is
    /// being called, or how far its ring is to a start; the kind of its
    /// sound, live - and holding while its ring fills again; or, let go
    /// of, that play listens to it.
    fn composeStation(app: *App, line: *Line(160)) void {
        if (app.station_why[0] != 0) return line.add(&app.station_why);
        const station = app.station orelse return line.add("A station: play listens to it");
        if (!app.station_loaded) {
            if (app.station_facts.phase != .streaming) return line.add("Calling the station");
            var progress: [32:0]u8 = @splat(0);
            app.formatNumber(&progress, "Buffering %u%%", station.percent());
            return line.add(&progress);
        }
        line.add(&app.kind_text.text);
        line.add(" - live");
        if (app.engine.starved) line.add(", buffering");
    }

    // --- Open URL... ------------------------------------------------------------

    /// Open URL...: a small window for a station's address - the one last
    /// opened in it - with Open and Cancel, which does not hold the Player
    /// up; brought to the front when it is open already.
    fn askUrl(app: *App) void {
        const ib = app.ib;
        if (app.url_window) |shown| {
            ib.WindowToFront(shown.window);
            ib.ActivateWindow(shown.window);
            _ = ib.ActivateGadget(shown.field, shown.window, null);
            return;
        }
        if (app.string_lib == null) app.string_lib = app.sys.OpenLibrary(st.STRING_LIBRARY, 0);
        if (app.string_lib == null) return ib.DisplayBeep(app.screen);
        var loose: Loose = .{};
        defer loose.dispose(ib);
        const field = loose.add(ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
            pair(gc.GA_ID, ID_URL_TEXT),
            pair(gc.GA_RelVerify, 1),
            pair(gc.STRINGA_MaxChars, dos.path_max),
            pair(gc.STRINGA_TextVal, @intFromPtr(&app.url_text)),
            .{},
        })) orelse return ib.DisplayBeep(app.screen);
        const open_button = loose.add(button(ib, "_Open", ID_URL_OPEN)) orelse return ib.DisplayBeep(app.screen);
        const cancel_button = loose.add(button(ib, "_Cancel", ID_URL_CANCEL)) orelse return ib.DisplayBeep(app.screen);
        const buttons = group(ib, &loose, &.{ pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ), pair(lg.LAYOUTA_Spacing, 6) }, &.{
            .{ .object = open_button, .weight_width = 0 },
            .{},
            .{ .object = cancel_button, .weight_width = 0 },
        }) orelse return ib.DisplayBeep(app.screen);
        const layout = group(ib, &loose, &.{ pair(lg.LAYOUTA_Margin, 8), pair(lg.LAYOUTA_Spacing, 6) }, &.{
            .{ .object = field, .min_width = url_width, .label = "A_ddress" },
            .{ .object = buttons, .weight_height = 0 },
        }) orelse return ib.DisplayBeep(app.screen);
        const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
            pair(wn.WA_Title, @intFromPtr("Open URL")),
            pair(wn.WA_ScreenTitle, @intFromPtr(SCREEN_TITLE)),
            pair(wn.WA_PubScreen, @intFromPtr(app.screen)),
            pair(wn.WA_AutoAdjust, 1),
            pair(wn.WA_CloseGadget, 1),
            pair(wn.WA_DragBar, 1),
            pair(wn.WA_DepthGadget, 1),
            pair(wn.WA_SizeGadget, 1),
            pair(wn.WA_Activate, 1),
            pair(wc.WINDOWA_Layout, @intFromPtr(layout)),
            .{},
        }) orelse return ib.DisplayBeep(app.screen);
        loose.take(layout);
        var open = wc.WmOpen{};
        const opened = ib.SendMessage(object, @ptrCast(&open));
        if (opened == 0) {
            ib.DisposeObject(object);
            return ib.DisplayBeep(app.screen);
        }
        const window: *Window = @ptrFromInt(opened);
        app.url_window = .{ .object = object, .window = window, .field = field };
        _ = ib.ActivateGadget(field, window, null);
    }

    /// The signal of Open URL...'s window, while it is open.
    fn urlSignal(app: *App) u32 {
        const shown = app.url_window orelse return 0;
        var mask: usize = 0;
        _ = app.ib.GetAttr(wc.WINDOWA_SigMask, shown.object, &mask);
        return @truncate(mask);
    }

    /// What Open URL...'s window says: Open, or Return in its field,
    /// listens to the address and closes it; Cancel, Escape and its close
    /// gadget only close it.
    fn urlMessages(app: *App) void {
        const shown = app.url_window orelse return;
        var code: u32 = 0;
        var handle = wc.WmHandleInput{ .code = &code };
        while (true) {
            const word = app.ib.SendMessage(shown.object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) return;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => return app.closeUrl(),
                wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
                    ID_URL_TEXT => {
                        if (code == keyboard.RAWKEY_ESC) return app.closeUrl();
                        if (app.openUrl()) return app.closeUrl();
                    },
                    ID_URL_OPEN => if (app.openUrl()) return app.closeUrl(),
                    ID_URL_CANCEL => return app.closeUrl(),
                    else => {},
                },
                else => {},
            }
        }
    }

    /// The address in Open URL...'s field added to the list and listened
    /// to - `http://` put before one that names no way to be reached:
    /// false, with a beep, when there is none, or one the Player cannot
    /// listen to.
    fn openUrl(app: *App) bool {
        const shown = app.url_window orelse return false;
        var value: usize = 0;
        _ = app.ib.GetAttr(gc.STRINGA_TextVal, shown.field, &value);
        const typed: [*:0]const u8 = if (value != 0) @ptrFromInt(value) else "";
        var start: usize = 0;
        while (typed[start] == ' ') start += 1;
        var end = start + lengthOf(typed + start);
        while (end > start and typed[end - 1] == ' ') end -= 1;
        const text = typed[start..end];
        if (text.len == 0) {
            app.ib.DisplayBeep(app.screen);
            return false;
        }
        var address: [dos.path_max + 1:0]u8 = @splat(0);
        const plain = "http://";
        const bare = indexOf(text, "://") == null;
        const lead: []const u8 = if (bare) plain else "";
        const length = @min(lead.len + text.len, dos.path_max);
        @memcpy(address[0..lead.len], lead);
        @memcpy(address[lead.len..length], text[0 .. length - lead.len]);
        if (!playlist.isUrl(&address)) {
            app.ib.DisplayBeep(app.screen);
            return false;
        }
        app.url_text = address;
        const before = app.beginAdding();
        _ = app.songs.addPath(app.sys, app.dl, &address);
        if (app.endAdding(before)) |first| app.playNow(first);
        return true;
    }

    /// Open URL...'s window closed, what its field said kept for the next
    /// time.
    fn closeUrl(app: *App) void {
        const shown = app.url_window orelse return;
        app.ib.DisposeObject(shown.object);
        app.url_window = null;
    }

    // --- the order -----------------------------------------------------------

    /// The song at `step` of the order; null past its end.
    fn entryAt(app: *App, step: usize) ?*Entry {
        if (step >= app.songs.count) return null;
        const order = app.order orelse return app.songs.at(step);
        return order[step];
    }

    /// The song at `step` of the order shown, and started as `how` says.
    fn goTo(app: *App, step: usize, how: Start) void {
        app.step = step;
        app.playAt(app.entryAt(step) orelse return, how);
    }

    /// Play with no song loaded: the song shown, or the one the order
    /// stands at, or its first.
    fn playShown(app: *App) void {
        if (app.playing) |entry| return app.playAt(entry, .play);
        if (app.songs.count == 0) return;
        app.goTo(if (app.step < app.songs.count) app.step else 0, .play);
    }

    /// How the song after or before is started: as the one playing is.
    fn startNow(app: *const App) Start {
        return switch (app.engine.state) {
            .playing => .play,
            .paused => .pause,
            .idle, .ended => .stop,
        };
    }

    /// Room in the order for every song, what it holds kept; false
    /// without the memory, and the order is then the list's own.
    fn orderRoom(app: *App) bool {
        const wanted = app.songs.count;
        if (app.order != null and wanted <= app.order_room) return true;
        const room = @max(wanted, app.order_room * 2, 16);
        const memory = app.sys.AllocVec(room * @sizeOf(*Entry), exec.MEMF_ANY);
        const old = app.order;
        app.order = if (memory) |made| @ptrCast(@alignCast(made)) else null;
        app.order_room = if (memory != null) room else 0;
        if (old) |kept| {
            if (app.order) |order| {
                for (0..app.ordered) |i| order[i] = kept[i];
            }
            app.sys.FreeVec(@ptrCast(kept));
        }
        if (app.order == null) app.ordered = 0;
        return app.order != null;
    }

    /// The list's own order, the step on the song shown.
    fn listOrder(app: *App) void {
        const order = if (app.orderRoom()) app.order else null;
        var entry = app.songs.first();
        var at: usize = 0;
        while (entry) |song| : (entry = song.next()) {
            if (song == app.playing) app.step = at;
            if (order) |into| into[at] = song;
            at += 1;
        }
        if (order != null) app.ordered = at;
    }

    /// A number from 0 to `below` less one, from the chip's generator.
    fn random(below: usize) usize {
        return sdk.hardware.rng.read() % below;
    }

    /// The order shuffled: with `first` at its start and the rest after
    /// it, or - with none - all of it, the song shown not first.
    fn shuffleOrder(app: *App, first: ?*Entry) void {
        app.listOrder();
        app.step = 0;
        const order = app.order orelse return;
        const n = app.ordered;
        if (n < 2) return;
        var from: usize = 0;
        if (first) |song| {
            for (order[0..n]) |*slot| {
                if (slot.* != song) continue;
                slot.* = order[0];
                break;
            }
            order[0] = song;
            from = 1;
        }
        var at = n - 1;
        while (at > from) : (at -= 1) {
            const other = from + random(at - from + 1);
            const held = order[at];
            order[at] = order[other];
            order[other] = held;
        }
        if (first == null and order[0] == app.playing) {
            const other = 1 + random(n - 1);
            order[0] = order[other];
            order[other] = app.playing.?;
        }
    }

    /// Songs added at the end of the list, from place `before` on, put in
    /// a shuffled order each at a random place among the songs still to
    /// come. The list's own order follows the list (`listMoved`).
    fn orderAdded(app: *App, before: usize) void {
        if (!app.shuffled or !app.orderRoom()) return;
        const order = app.order.?;
        var entry = app.songs.at(before);
        while (entry) |song| : (entry = song.next()) {
            const lowest = @min(if (app.playing != null) app.step + 1 else app.step, app.ordered);
            const at = lowest + random(app.ordered - lowest + 1);
            var shift = app.ordered;
            while (shift > at) : (shift -= 1) order[shift] = order[shift - 1];
            order[at] = song;
            app.ordered += 1;
        }
    }

    /// `entry` taken out of the order, the step kept on the song it is on
    /// - or, when that is this one, on the one after it - and no longer
    /// the song that follows. Where it stood.
    fn forget(app: *App, entry: *Entry) usize {
        if (app.following == entry) app.following = null;
        if (app.follow_tried == entry) app.follow_tried = null;
        var at: usize = 0;
        if (app.order) |order| {
            while (at < app.ordered and order[at] != entry) at += 1;
            if (at == app.ordered) return at;
            for (at..app.ordered - 1) |i| order[i] = order[i + 1];
            app.ordered -= 1;
        } else {
            at = app.songs.placeOf(entry);
        }
        if (at < app.step) app.step -= 1;
        return at;
    }

    /// Where `entry` stands in the order.
    fn stepOf(app: *App, entry: *Entry) usize {
        const order = app.order orelse return app.songs.placeOf(entry);
        for (order[0..app.ordered], 0..) |song, at| {
            if (song == entry) return at;
        }
        return 0;
    }

    /// The song that plays when the one shown ends, as `ended` goes on: the
    /// same again with repeat one, the next of the order, or round to the
    /// first with repeat - shuffled anew, so one at random then, and the
    /// one picked before while it still may be. Null at the end.
    fn followingEntry(app: *App) ?*Entry {
        const shown = app.playing orelse return null;
        const count = app.songs.count;
        if (app.repeat == .one) return shown;
        if (app.step + 1 < count) return app.entryAt(app.step + 1);
        if (app.repeat == .off) return null;
        if (!app.shuffled) return app.entryAt(0);
        if (app.follow_tried) |kept| {
            if (kept != shown) return kept;
        }
        if (count < 2) return shown;
        const picked = app.songs.at(random(count - 1)) orelse return null;
        return if (picked == shown) app.songs.at(count - 1) else picked;
    }

    /// What the sound let go of - the song handed to follow, at a load, a
    /// stop or a seek - forgotten here too.
    fn followUp(app: *App) void {
        if (app.follow_round == app.engine.follow_round) return;
        app.follow_round = app.engine.follow_round;
        app.following = null;
        app.follow_tried = null;
    }

    /// While the sound asks for it, the song that follows the one shown
    /// handed to it: opened here - its tags and cover read on the window's
    /// task - so the sound goes on into it without a gap. Handed again
    /// when the order, repeat or the list changed what follows.
    fn keepFollowing(app: *App) void {
        const engine = app.engine;
        app.followUp();
        if (!engine.wantsFollowing()) return;
        const wanted = app.followingEntry();
        if (wanted == app.follow_tried) return;
        var stream: ?*ac.AudioStream = null;
        // A station is listened to when the order comes to it, not gone on
        // into.
        if (wanted) |entry| {
            if (!playlist.isUrl(entry.path())) stream = app.acb.OpenAudioStream(&[_]TagItem{
                pair(ac.ACA_Name, @intFromPtr(entry.path())),
                pair(ac.ACA_KeepPicture, 1),
                .{},
            }, null);
        }
        const taken = engine.follow(stream);
        app.follow_round = engine.follow_round;
        app.follow_tried = wanted;
        if (taken) {
            app.following = if (stream != null) wanted else null;
        } else if (stream) |late| {
            app.acb.CloseAudioStream(late);
        }
    }

    /// The song handed to follow is being heard: the song shown from now
    /// on, the order gone on to it - without loading it, the picture going
    /// on. Taken out of the list as it began, the order goes on after it.
    fn advance(app: *App) void {
        app.followUp();
        const song = app.following orelse return app.goOn();
        if (!app.engine.advance()) return;
        app.followUp();
        if (song != app.playing) {
            if (app.entryAt(app.step + 1) == song) {
                app.step += 1;
            } else if (app.shuffled) {
                app.shuffleOrder(song);
            } else {
                app.step = app.stepOf(song);
            }
        }
        app.songs.filled(app.sys, song, &app.engine.info);
        app.kind_text.clear();
        app.silent = false;
        app.markPlaying(song);
        app.shown_second = ~@as(u32, 0);
        app.showSong(song.path());
        app.wake();
    }

    /// The song after: the next of the order, round to the first with
    /// repeat - with no song shown, the one the order stands at.
    fn next(app: *App) void {
        const count = app.songs.count;
        if (count == 0) return;
        const how = app.startNow();
        const after = if (app.playing != null) app.step + 1 else app.step;
        if (after < count) return app.goTo(after, how);
        if (app.repeat == .off) return;
        if (app.shuffled) app.shuffleOrder(null);
        app.goTo(0, how);
    }

    /// The song before - or, a few seconds into this one, its start.
    fn previous(app: *App) void {
        const count = app.songs.count;
        if (count == 0) return;
        const engine = app.engine;
        const going = engine.state == .playing or engine.state == .paused;
        const rate = @max(engine.info.rate, 1);
        const late = going and engine.live == null and engine.songFrame() >= back_seconds * rate;
        if (!late) {
            const how = app.startNow();
            if (app.playing == null) return app.goTo(@min(app.step, count - 1), how);
            if (app.step > 0) return app.goTo(app.step - 1, how);
            if (app.repeat != .off) return app.goTo(count - 1, how);
        }
        if (!going) return;
        engine.seek(0);
        app.visual.quiet();
        app.showTime();
    }

    /// Shuffle turned on or off - by its button, the menu or its key: an
    /// order from the song playing on, or the list's own; the button and
    /// the menu's tick with it.
    fn shuffleTurned(app: *App, on: bool) void {
        app.shuffled = on;
        if (on) app.shuffleOrder(app.playing) else app.listOrder();
        app.set(app.shuffle_button, &.{ pair(tb.TOOLBUTTON_Checked, @intFromBool(on)), .{} });
        app.showMenuTicks();
    }

    /// Repeat pressed: off, the whole list, the one song, and round.
    fn repeatTurned(app: *App) void {
        app.repeatTo(switch (app.repeat) {
            .off => .all,
            .all => .one,
            .one => .off,
        });
    }

    /// Repeat as `how`: the button on for the whole list and the one song,
    /// its picture with a 1 for the one song; the menu's tick with it.
    fn repeatTo(app: *App, how: Repeat) void {
        app.repeat = how;
        const picture = if (how == .one) media.MEDIA_REPEAT_ONE else media.MEDIA_REPEAT;
        _ = app.ib.SetAttrsTagList(app.repeat_picture, &[_]TagItem{ pair(media.MEDIA_Glyph, picture), .{} });
        app.set(app.repeat_button, &.{ pair(tb.TOOLBUTTON_Checked, @intFromBool(how != .off)), .{} });
        app.showMenuTicks();
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

    /// The volume `by` percent up or down.
    fn volumeBy(app: *App, by: i32) void {
        app.volumeAt(@as(i32, @intCast(app.level)) + by);
    }

    /// The volume at `wanted` percent, within the slider's range, and the
    /// slider with it.
    fn volumeAt(app: *App, wanted: i32) void {
        const level: u32 = @intCast(@min(@max(wanted, 0), volume_most));
        app.set(app.volume, &.{ pair(sl.SLIDER_Level, level), .{} });
        app.volumeTo(level);
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

    /// The song's names, cover and kind, and the slider as long as it is.
    fn showSong(app: *App, name: [*:0]const u8) void {
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

        app.describeSound();
        app.composeKind();
        app.showLines();
        app.showCover(tags.picture, name, if (tags.album[0] != 0) tags.album else tags.title);
        app.showRange(app.seconds(info.frames));
        app.keepRoom(app.seconds(info.frames) >= hour);
        app.showTime();
    }

    /// What the sound is - its kind, rate, sides and bit rate - as the
    /// kind line starts.
    fn describeSound(app: *App) void {
        const info = &app.engine.info;
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
        app.kind_text.clear();
        app.kind_text.add(&about);
    }

    /// The kind line made: the kind of file, the song's place in the list
    /// when it holds more, and why it is silent when it is; for a station
    /// how it goes.
    fn composeKind(app: *App) void {
        const line = &app.line_text[line_format];
        line.clear();
        if (app.showsStation()) return app.composeStation(line);
        line.add(&app.kind_text.text);
        if (app.songs.count > 1) {
            if (app.playing) |entry| {
                var place: [32:0]u8 = @splat(0);
                const counted = exec.fmtStream(.{ entry.place, @as(u32, @intCast(app.songs.count)) });
                comptime exec.checkFormat(" - song %u of %u", @TypeOf(.{ @as(u32, 0), @as(u32, 0) }));
                _ = app.sys.RawDoFmt(" - song %u of %u", &counted, null, &place);
                line.add(&place);
            }
        }
        if (app.silent) line.add(if (app.engine.open_error == exec.IOERR_OPENFAIL) " - no sound" else " - no stream free");
    }

    /// The kind line made again after the list changed, and shown when it
    /// says something else now.
    fn showKind(app: *App) void {
        if (app.kind_text.empty() and !app.showsStation()) return;
        const before = app.line_text[line_format];
        app.composeKind();
        if (!app.line_text[line_format].same(&before)) app.showLines();
    }

    /// No song shown: the sound given back, and the window as it opens.
    fn showNoSong(app: *App) void {
        app.stopStation();
        app.engine.unload();
        app.visual.quiet();
        app.shown_second = ~@as(u32, 0);
        for (&app.line_text) |*line| line.clear();
        app.kind_text.clear();
        app.silent = false;
        app.line_text[line_title].add("No song");
        if (!app.engine.opened) app.line_text[line_format].add(soundTrouble(app.engine));
        app.chapters = null;
        app.chapter_count = 0;
        _ = app.ib.SetAttrsTagList(app.object, &[_]TagItem{ pair(wn.WA_Title, @intFromPtr(COMMAND_NAME)), .{} });
        app.showLines();
        app.showCover(null, "", COMMAND_NAME);
        app.showRange(0);
        app.keepRoom(false);
        app.showTime();
        app.showDeck(td.BUT_STOP, false);
    }

    /// The position slider across a song `length` seconds long, at its
    /// start; with no length to go through, still and empty - over an
    /// hour's range, so its knob is as small as a song's.
    fn showRange(app: *App, length: u32) void {
        app.set(app.position, &.{
            pair(sl.SLIDER_Max, if (length > 0) length else hour),
            pair(sl.SLIDER_Level, 0),
            pair(gc.GA_Disabled, @intFromBool(length == 0)),
            .{},
        });
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
    /// the song, or the note; the pictures take its colours. The large
    /// cover's window, when it is open, shows it too, `title` its title,
    /// or closes when there is none.
    fn showCover(app: *App, picture: ?*const ac.AudioPicture, name: [*:0]const u8, title: [*:0]const u8) void {
        app.covers +%= 1;
        var value: usize = 0;
        _ = app.ib.GetAttr(cv.CANVAS_RastPort, app.cover, &value);
        if (value == 0) return;
        _ = app.kept.read(.{ .sys = app.sys, .dl = app.dl, .gb = app.gb, .dt = app.dt }, @ptrFromInt(value), picture, name);
        app.visual.tint = app.kept.lead;
        app.drawCover();
        const dt = app.dt orelse return;
        _ = app.big.follow(.{ .ib = app.ib, .dt = dt, .screen = app.screen }, app.covers, app.coverSource(picture), title);
    }

    /// Where the kept cover came from, for the large window to read it
    /// again at its own size; null for the note.
    fn coverSource(app: *const App, picture: ?*const ac.AudioPicture) ?cover.Source {
        return switch (app.kept.from) {
            .none => null,
            .tags => .{ .held = picture orelse return null },
            .beside => .{ .file = app.kept.file() orelse return null },
        };
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
        const name = (app.playing orelse return).path();
        if (playlist.isUrl(name)) return;
        const tags = app.tagsOf(name);
        const source = app.coverSource(tags.picture) orelse return;
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
        if (app.showsStation()) {
            // Listened to for `at`, with no end.
            app.length_text = @splat(0);
            @memcpy(app.length_text[0.."live".len], "live");
            return;
        }
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
        if (!app.showsStation()) app.set(app.position, &.{ pair(sl.SLIDER_Level, at), .{} });
        app.writeClock(at);
    }

    /// The end of a song: the same again with repeat one, or the order
    /// gone on.
    fn ended(app: *App) void {
        if (app.station != null and app.engine.live != null) return app.stationEnded();
        if (app.repeat == .one) {
            app.engine.start();
            app.visual.quiet();
            app.showTime();
            return;
        }
        app.goOn();
    }

    /// Past the song shown: the next of the order, round to the first with
    /// repeat; or back to the start and still.
    fn goOn(app: *App) void {
        if (app.step + 1 < app.songs.count) return app.goTo(app.step + 1, .play);
        if (app.repeat == .all and app.songs.count > 0) {
            if (app.shuffled) app.shuffleOrder(null);
            return app.goTo(0, .play);
        }
        app.engine.stop();
        app.visual.quiet();
        app.showDeck(td.BUT_STOP, false);
        app.showTime();
    }

    fn jump(app: *App, by: i32) void {
        const engine = app.engine;
        if (engine.stream == null or engine.live != null or (engine.state != .playing and engine.state != .paused)) return;
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
                // A station still to come starts as the deck says once it
                // is there.
                if (app.connecting()) {
                    app.station_how = if (paused) .pause else .play;
                    return;
                }
                if (engine.stream == null) app.playShown() else engine.start();
                engine.pause(paused);
                if (app.connecting() and paused) app.station_how = .pause;
                // Nothing to play: the deck stays stopped.
                if (engine.stream == null and app.station == null) app.showDeck(td.BUT_STOP, false);
                app.wake();
            },
            td.BUT_STOP => {
                // A station stopped is let go of; play calls it again.
                if (app.showsStation()) {
                    app.stopStation();
                    app.showStation();
                } else engine.stop();
                app.visual.quiet();
                app.showTime();
            },
            td.BUT_REWIND, td.BUT_FORWARD => {
                app.jump(if (mode == td.BUT_REWIND) -jump_seconds else jump_seconds);
                // A jump, not a mode: the deck goes back to what it was.
                const playing = engine.state == .playing or engine.state == .paused or app.connecting();
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
                if (app.connecting()) {
                    app.station_how = if (app.station_how == .pause) .play else .pause;
                    return app.showDeck(td.BUT_PLAY, app.station_how == .pause);
                }
                if (engine.stream == null) return app.playShown();
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
        app.showMenuTicks();
        app.wake();
    }

    /// The picture `mode`, ticked in the menu.
    fn lookTo(app: *App, mode: visual.Mode) void {
        app.visual.mode = mode;
        app.visual.width = 0;
        app.showMenuTicks();
        app.wake();
    }

    /// The menus' ticks on what is so: shuffle, the way repeat goes, the
    /// look shown, and whether where it was is remembered.
    fn showMenuTicks(app: *App) void {
        const strip = app.strip orelse return;
        app.ib.ClearMenuStrip(app.window);
        app.tickItem(strip, mn.FULLMENUNUM(MENU_PLAYLIST, ITEM_SHUFFLE, mn.NOSUB), app.shuffled);
        for (0..3) |at| {
            app.tickItem(strip, mn.FULLMENUNUM(MENU_PLAYLIST, ITEM_REPEAT, @intCast(at)), at == @intFromEnum(app.repeat));
        }
        for (0..visual.mode_count) |at| {
            app.tickItem(strip, mn.FULLMENUNUM(MENU_PICTURE, @intCast(at), mn.NOSUB), at == @intFromEnum(app.visual.mode));
        }
        app.tickItem(strip, mn.FULLMENUNUM(MENU_SETTINGS, ITEM_REMEMBER, mn.NOSUB), app.remember);
        _ = app.ib.ResetMenuStrip(app.window, strip);
    }

    fn tickItem(app: *App, strip: *intuition.Menu, number: u32, on: bool) void {
        const entry = app.ib.ItemAddress(strip, number) orelse return;
        if (on) entry.flags |= mn.CHECKED else entry.flags &= ~mn.CHECKED;
    }

    /// A menu item picked: false when it is Quit.
    fn menuPicked(app: *App, number: u32) bool {
        switch (mn.MENUNUM(number)) {
            MENU_PROJECT => switch (mn.ITEMNUM(number)) {
                ITEM_OPEN => app.askFiles(.play),
                ITEM_OPEN_DRAWER => app.askFiles(.drawer),
                ITEM_OPEN_URL => app.askUrl(),
                ITEM_ABOUT => app.showAbout(),
                ITEM_QUIT => return false,
                else => {},
            },
            MENU_PLAYLIST => switch (mn.ITEMNUM(number)) {
                ITEM_ADD => app.askFiles(.add),
                ITEM_REMOVE => app.removeSelected(),
                ITEM_CLEAR => app.clearList(),
                ITEM_SHUFFLE => app.shuffleTurned(!app.shuffled),
                ITEM_REPEAT => {
                    const how = mn.SUBNUM(number);
                    if (how < 3) app.repeatTo(@enumFromInt(how));
                },
                else => {},
            },
            MENU_PICTURE => {
                const which = mn.ITEMNUM(number);
                if (which < visual.mode_count) app.lookTo(@enumFromInt(which));
            },
            MENU_SETTINGS => if (mn.ITEMNUM(number) == ITEM_REMEMBER) {
                app.remember = !app.remember;
                app.showMenuTicks();
            },
            else => {},
        }
        return true;
    }

    /// The file requester put up, without waiting for it: for songs to
    /// play or only to add, several at once, or for a drawer whose songs
    /// are played. The first time it starts in the drawer last answered
    /// in - kept from the run before - or else the drawer of the song
    /// shown, and where it was left after that. Nothing while it is up
    /// already.
    fn askFiles(app: *App, what: Ask) void {
        const al = app.al orelse return;
        const port = app.asl_port orelse return;
        if (app.asking) return;
        const request = app.request orelse made: {
            var drawer: [dos.path_max + 1:0]u8 = @splat(0);
            if (app.drawer[0] != 0) drawer = app.drawer else app.songDrawer(&drawer);
            app.request = al.AllocAslRequest(asl.ASL_FileRequest, &[_]TagItem{
                pair(asl.ASLFR_InitialDrawer, @intFromPtr(&drawer)),
                pair(asl.ASLFR_InitialPattern, @intFromPtr(playlist.pattern)),
                pair(asl.ASLFR_DoPatterns, 1),
                pair(asl.ASLFR_DoMultiSelect, 1),
                pair(asl.ASLFR_ReplyPort, @intFromPtr(port)),
                .{},
            });
            break :made app.request orelse return;
        };
        const title: [*:0]const u8 = switch (what) {
            .play => "Which songs?",
            .add => "Add which songs?",
            .drawer => "Which drawer?",
        };
        app.asked = what;
        app.asking = al.AslRequest(request, &[_]TagItem{
            pair(asl.ASLFR_Window, @intFromPtr(app.window)),
            pair(asl.ASLFR_TitleText, @intFromPtr(title)),
            pair(asl.ASLFR_DrawersOnly, @intFromBool(what == .drawer)),
            pair(asl.ASLFR_DoMultiSelect, @intFromBool(what != .drawer)),
            .{},
        });
    }

    /// About: what the Player is, in a requester that does not hold the
    /// window up - the picture goes on, and the next song follows. Brought
    /// to the front when it is up already.
    fn showAbout(app: *App) void {
        if (app.about_window) |shown| {
            app.ib.WindowToFront(shown);
            app.ib.ActivateWindow(shown);
            return;
        }
        const easy = intuition.requesters.EasyStruct{
            .title = "About " ++ COMMAND_NAME,
            .text_format = COMMAND_NAME ++ " " ++ VERSION ++ " (" ++ DATE ++ ")\n\n" ++
                "Songs from WAV, MP3, FLAC and Ogg Vorbis files,\n" ++
                "one into the next, with their covers,\n" ++
                "stations from the network\n" ++
                "and a picture of the sound.",
            .gadget_format = "OK",
        };
        app.about_window = app.ib.BuildEasyRequestArgs(app.window, &easy, 0, null);
    }

    /// The signal of About's requester, while it is up.
    fn aboutSignal(app: *App) u32 {
        const shown = app.about_window orelse return 0;
        var port: usize = 0;
        app.ib.GetWindowAttrs(shown, &[_]TagItem{ pair(wn.WA_UserPort, @intFromPtr(&port)), .{} });
        const user_port: *exec.MsgPort = @ptrFromInt(port);
        return user_port.sigMask();
    }

    /// About's requester answered - or asked to go, as the window ends:
    /// taken down.
    fn aboutAnswered(app: *App, going: bool) void {
        const shown = app.about_window orelse return;
        if (!going and app.ib.SysReqHandler(shown, null, false) == intuition.requesters.SYSREQ_PENDING) return;
        app.ib.FreeSysRequest(shown);
        app.about_window = null;
    }

    /// The drawer the song shown is in, or `SYS:` with none.
    fn songDrawer(app: *App, into: *[dos.path_max + 1:0]u8) void {
        const fallback = "SYS:";
        const shown: [*:0]const u8 = if (app.playing) |entry| entry.path() else fallback;
        const song: [*:0]const u8 = if (playlist.isUrl(shown)) fallback else shown;
        var length: usize = 0;
        while (song[length] != 0 and length < dos.path_max) : (length += 1) into[length] = song[length];
        into[length] = 0;
        if (song != @as([*:0]const u8, fallback)) {
            const end = @intFromPtr(app.dl.PathPart(into)) - @intFromPtr(into);
            into[end] = 0;
        }
    }

    /// The file requester's answer: the songs picked - a drawer named
    /// its sound files - added, and for Open... the first played.
    fn answered(app: *App) void {
        const port = app.asl_port orelse return;
        while (app.sys.GetMsg(port)) |message| {
            const reply: *asl.AslMessage = @ptrCast(@alignCast(message));
            app.asking = false;
            if (reply.answered == 0) continue;
            const answer: *asl.FileRequester = @ptrCast(@alignCast(reply.requester orelse continue));
            const drawer = answer.drawer orelse continue;
            app.keepDrawer(drawer);
            const before = app.beginAdding();
            const picks = if (answer.arg_list) |list| list[0..@intCast(@max(answer.num_args, 0))] else &[_]asl.WBArg{};
            if (picks.len > 0) {
                for (picks) |pick| app.addIn(drawer, pick.name orelse continue);
            } else {
                app.addIn(drawer, answer.file orelse "");
            }
            const first = app.endAdding(before) orelse continue;
            if (app.asked != .add) app.playNow(first);
        }
    }

    /// The drawer the requester was answered in, kept for the next
    /// start.
    fn keepDrawer(app: *App, drawer: [*:0]const u8) void {
        const length = @min(lengthOf(drawer), dos.path_max);
        @memcpy(app.drawer[0..length], drawer[0..length]);
        app.drawer[length] = 0;
    }

    // --- one Player -------------------------------------------------------------

    /// What a second start handed over (one.zig): its volume and its
    /// picture, its files added and the first played - only added with
    /// ADD - and, without ADD, the window brought to the front. Each
    /// answered once it is dealt with, as the names are the sender's.
    fn handedOver(app: *App) void {
        const port = app.public orelse return;
        while (app.sys.GetMsg(port)) |message| {
            defer app.sys.ReplyMsg(message);
            const handed: *const one.Handed = @ptrCast(@alignCast(message));
            if (handed.volume >= 0) app.volumeAt(handed.volume);
            if (handed.lookAsked()) |mode| app.lookTo(mode);
            const names = handed.nameList();
            if (names.len > 0) {
                const before = app.beginAdding();
                for (names) |name| _ = app.songs.addPath(app.sys, app.dl, name);
                if (app.endAdding(before)) |first| {
                    if (handed.add == 0) app.playNow(first);
                }
            }
            if (handed.add == 0) app.toFront();
        }
    }

    /// The window in front, its screen in front of the others, and active.
    fn toFront(app: *App) void {
        app.ib.ScreenToFront(app.screen);
        app.ib.WindowToFront(app.window);
        app.ib.ActivateWindow(app.window);
    }

    // --- remembered -----------------------------------------------------------

    /// The list the last run left (Player.list), and the song it showed
    /// with the second it was at; null when it showed none.
    fn readList(app: *App, ub: *UtilityBase) ?Resume {
        const text = prefs.loadWhole(app.sys, app.dl, remembered.LIST_ENV_FILE) orelse return null;
        defer app.sys.FreeVec(text.ptr);
        var found: ?Resume = null;
        var songs = remembered.Songs.init(ub, text);
        var name: [dos.path_max + 1:0]u8 = @splat(0);
        while (songs.next()) |song| {
            @memcpy(name[0..song.path.len], song.path);
            name[song.path.len] = 0;
            const entry = app.songs.add(app.sys, &name) orelse continue;
            if (song.at) |second| found = .{ .entry = entry, .second = second };
        }
        return found;
    }

    /// The song shown when the Player last ended shown again where it
    /// was, paused: play or the space bar goes on from there.
    fn resumeAt(app: *App, where: Resume) void {
        if (app.shuffled) app.shuffleOrder(where.entry);
        app.step = app.stepOf(where.entry);
        // A station waits to be played: nothing is called as the Player
        // starts.
        if (playlist.isUrl(where.entry.path())) return app.playAt(where.entry, .stop);
        app.playAt(where.entry, .pause);
        if (app.engine.stream == null) return;
        app.engine.place(where.second *| @max(app.engine.info.rate, 1));
        app.showTime();
    }

    /// One of the window's numbers, which is opaque to a program.
    fn windowAttr(app: *App, tag: sdk.utility.Tag) i32 {
        var value: usize = 0;
        app.ib.GetWindowAttrs(app.window, &[_]TagItem{ pair(tag, @intFromPtr(&value)), .{} });
        return @bitCast(@as(u32, @truncate(value)));
    }

    /// How the Player was left, written to ENV: and ENVARC: for the next
    /// start: once, as it ends, so the disk is not written while songs
    /// play.
    fn keep(app: *App) void {
        var settings = remembered.Settings{
            .box = .{
                .left = app.windowAttr(wn.WA_Left),
                .top = app.windowAttr(wn.WA_Top),
                .width = app.windowAttr(wn.WA_Width),
                .height = app.windowAttr(wn.WA_Height),
            },
            .page = @intCast(app.page),
            .look = app.visual.mode,
            .volume = app.level,
            .shuffle = app.shuffled,
            .repeat = @intFromEnum(app.repeat),
            .remember = app.remember,
        };
        _ = settings.setDrawer(app.drawer[0..lengthOf(&app.drawer)]);
        const room = remembered.header.len + remembered.line_max + 1;
        const memory = app.sys.AllocVec(room, exec.MEMF_ANY) orelse return;
        defer app.sys.FreeVec(memory);
        const text: [*]u8 = @ptrCast(memory);
        @memcpy(text[0..remembered.header.len], remembered.header);
        var n: usize = remembered.header.len;
        n += remembered.write(&settings, text[n..room]);
        text[n] = '\n';
        n += 1;
        _ = prefs.save(app.dl, remembered.ENV_FILE, text[0..n]);
        _ = prefs.save(app.dl, remembered.ENVARC_FILE, text[0..n]);
        app.keepList();
    }

    /// The list and the song shown, with the second it is at, written for
    /// the next start; with Remember where it was off, the list kept
    /// before is taken away instead.
    fn keepList(app: *App) void {
        if (!app.remember) {
            _ = app.dl.DeleteFile(remembered.LIST_ENV_FILE);
            _ = app.dl.DeleteFile(remembered.LIST_ENVARC_FILE);
            return;
        }
        // A song played to its end starts again from its start.
        const engine = app.engine;
        const second: u32 = if (engine.stream != null and engine.live == null and engine.state != .ended) app.seconds(engine.songFrame()) else 0;
        var length: usize = remembered.list_header.len;
        var entry = app.songs.first();
        while (entry) |song| : (entry = song.next()) length += remembered.songLength(.{ .path = pathOf(song) });
        const memory = app.sys.AllocVec(length, exec.MEMF_ANY) orelse return;
        defer app.sys.FreeVec(memory);
        const text: [*]u8 = @ptrCast(memory);
        @memcpy(text[0..remembered.list_header.len], remembered.list_header);
        var n: usize = remembered.list_header.len;
        entry = app.songs.first();
        while (entry) |song| : (entry = song.next()) {
            const line: remembered.Song = .{ .path = pathOf(song), .at = if (song == app.playing) second else null };
            n += remembered.songLine(line, text[n..length]) orelse 0;
        }
        _ = prefs.save(app.dl, remembered.LIST_ENV_FILE, text[0..n]);
        _ = prefs.save(app.dl, remembered.LIST_ENVARC_FILE, text[0..n]);
    }

    /// `name` in `drawer` added to the list: a song, or a drawer's songs.
    fn addIn(app: *App, drawer: [*:0]const u8, name: [*:0]const u8) void {
        var path: [dos.path_max + 1:0]u8 = @splat(0);
        _ = app.dl.AddPart(&path, drawer, path.len);
        if (!app.dl.AddPart(&path, name, path.len)) return;
        _ = app.songs.addPath(app.sys, app.dl, &path);
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

    // --- the playlist -----------------------------------------------------------

    /// The list's gadget set and drawn again at the next chance, on
    /// whichever page it is.
    fn setList(app: *App, tags: []const TagItem) void {
        _ = app.ib.SetGadgetAttrsTagList(app.browser, null, tags.ptr);
        app.ib.QueueGadgetRefresh(app.browser);
    }

    /// The list taken from its gadget while songs are added or taken out.
    fn detachList(app: *App) void {
        _ = app.ib.SetGadgetAttrsTagList(app.browser, null, &[_]TagItem{ pair(lb.LISTBROWSER_Rows, lb.LISTBROWSER_DETACH), .{} });
    }

    /// The list given back to its gadget, which sorts it again when it is
    /// sorted by a column, and what follows from the list followed.
    fn giveBack(app: *App) void {
        app.setList(&.{ pair(lb.LISTBROWSER_Rows, @intFromPtr(&app.songs.rows)), .{} });
        app.listMoved();
    }

    /// The list stands in another order or holds other songs: the places
    /// in its first column, the order they play in when it is the list's
    /// own, and the song's place in the kind line.
    fn listMoved(app: *App) void {
        if (app.songs.renumber(app.sys)) app.ib.QueueGadgetRefresh(app.browser);
        if (!app.shuffled) app.listOrder();
        app.showKind();
    }

    /// Rows' texts changed: the list drawn again - sorted again first,
    /// when it is sorted by a column.
    fn rowsChanged(app: *App) void {
        var column: usize = lb.LISTBROWSER_NONE;
        _ = app.ib.GetAttr(lb.LISTBROWSER_SortColumn, app.browser, &column);
        if (column != lb.LISTBROWSER_NONE) app.giveBack() else app.ib.QueueGadgetRefresh(app.browser);
    }

    /// `entry` the song shown: its row marked, the last one's not.
    fn markPlaying(app: *App, entry: *Entry) void {
        if (app.playing) |last| last.row.flags &= ~lb.ROW_MARKED;
        app.playing = entry;
        entry.row.flags |= lb.ROW_MARKED;
        app.giveBack();
    }

    /// The song whose row is selected, if one is.
    fn selectedEntry(app: *App) ?*Entry {
        var value: usize = 0;
        _ = app.ib.GetAttr(lb.LISTBROWSER_SelectedRow, app.browser, &value);
        const row: ?*lb.Row = @ptrFromInt(value);
        return Entry.of(row orelse return null);
    }

    /// Songs about to be added: the list taken from its gadget, and where
    /// the first of them will stand.
    fn beginAdding(app: *App) usize {
        app.detachList();
        return app.songs.count;
    }

    /// Songs added from place `before` on: put in the order, the list
    /// given back, and their tags read as the picture goes. The first of
    /// them; null when none was.
    fn endAdding(app: *App, before: usize) ?*Entry {
        const first = app.songs.at(before);
        if (first != null) app.orderAdded(before);
        app.giveBack();
        if (first != null) app.wake();
        return first;
    }

    /// `entry` played now, as a song picked is: with shuffle, from a new
    /// order that starts with it.
    fn playNow(app: *App, entry: *Entry) void {
        if (app.shuffled) app.shuffleOrder(entry);
        app.playAt(entry, .play);
    }

    fn playSelected(app: *App) void {
        app.playNow(app.selectedEntry() orelse return);
    }

    /// The song selected taken out of the list, and the one after it
    /// selected. When it is the song shown, the one after it in the order
    /// is shown instead, started as the deck was; after the last, none.
    fn removeSelected(app: *App) void {
        const entry = app.selectedEntry() orelse return;
        const place = app.songs.placeOf(entry);
        const shown = app.playing == entry;
        const how = app.startNow();
        app.detachList();
        if (shown) app.playing = null;
        _ = app.forget(entry);
        app.songs.remove(app.sys, entry);
        app.giveBack();
        if (app.songs.count > 0) app.setList(&.{ pair(lb.LISTBROWSER_Selected, @min(place, app.songs.count - 1)), .{} });
        if (!shown) return;
        if (app.step < app.songs.count) app.goTo(app.step, how) else app.showNoSong();
    }

    /// Every song taken out of the list, and none shown.
    fn clearList(app: *App) void {
        if (app.songs.count == 0) return;
        app.detachList();
        app.playing = null;
        app.following = null;
        app.follow_tried = null;
        app.songs.clear(app.sys);
        app.ordered = 0;
        app.step = 0;
        app.giveBack();
        app.showNoSong();
    }

    /// A few songs' tags read, while some are not, into their rows.
    fn readTags(app: *App) void {
        var read: usize = 0;
        while (read < reads_per_look and app.songs.readNext(app.sys, app.acb) != null) read += 1;
        if (read > 0) app.rowsChanged();
    }

    /// A press let go on the list: a row moved, or one double-clicked.
    fn listPressed(app: *App, code: u32) void {
        if (code & lb.LISTBROWSER_MOVED != 0) return app.listMoved();
        if (code & lb.LISTBROWSER_DOUBLE != 0) app.playSelected();
    }

    /// A tab pressed: its page shown, and the picture going again on its
    /// own.
    fn turned(app: *App, page: u32) void {
        app.page = page;
        if (page == page_picture) app.wake();
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
            ID_TABS => app.turned(code),
            ID_LIST => app.listPressed(code),
            ID_ADD => app.askFiles(.add),
            ID_REMOVE => app.removeSelected(),
            ID_CLEAR => app.clearList(),
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
            // A press on a heading sorted the list.
            ID_LIST => app.listMoved(),
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
                wc.WMHI_VANILLAKEY => app.key(word & wc.WMHI_KEYMASK),
                wc.WMHI_RAWKEY => app.rawKey(word & wc.WMHI_KEYMASK),
                wc.WMHI_NEWSIZE => app.sized(),
                wc.WMHI_ACTIVE => app.readOutputs(),
                // The pens changed: the cover's ground and its note are
                // drawn in them. The fonts stay: an open window keeps the
                // ones it was made with, and the title keeps its own with
                // them.
                wc.WMHI_NEWPREFS => app.drawCover(),
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
        if (app.page == page_picture) app.drawPicture();
        app.wake();
    }

    /// A key no gadget took: the space bar pauses and goes on; N and P
    /// the song after and before; Return plays the song selected where the
    /// list is shown.
    fn key(app: *App, code: usize) void {
        switch (code) {
            ' ' => app.togglePause(),
            'n', 'N' => app.next(),
            'p', 'P' => app.previous(),
            13 => if (app.page == page_list) app.playSelected(),
            else => {},
        }
    }

    /// A key that is no character: left and right ten seconds back and on,
    /// up and down the volume; Del takes the song selected out where the
    /// list is shown.
    fn rawKey(app: *App, code: usize) void {
        switch (code) {
            keyboard.RAWKEY_LEFT => app.jump(-jump_seconds),
            keyboard.RAWKEY_RIGHT => app.jump(jump_seconds),
            keyboard.RAWKEY_UP => app.volumeBy(volume_step),
            keyboard.RAWKEY_DOWN => app.volumeBy(-volume_step),
            keyboard.RAWKEY_DEL => if (app.page == page_list) app.removeSelected(),
            else => {},
        }
    }

    /// Files dropped on the window, every one of each drop: added - a
    /// drawer its songs - and the first played when nothing plays.
    fn dropped(app: *App) void {
        var name: [dos.path_max + 1]u8 = undefined;
        const before = app.beginAdding();
        while (app.drop.next(app.dl, &name)) |file| _ = app.songs.addPath(app.sys, app.dl, file.name);
        const first = app.endAdding(before) orelse return;
        app.ib.ActivateWindow(app.window);
        const state = app.engine.state;
        if (state != .playing and state != .paused) app.playNow(first);
    }

    // --- the picture ----------------------------------------------------------

    /// The canvas made as big as its box, and the pixels with it.
    fn fitPicture(app: *App) void {
        app.setOn(page_picture, app.picture, &.{ pair(cv.CANVAS_Width, 0), pair(cv.CANVAS_Height, 0), .{} });
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
        const w: u32 = @intCast(width);
        const h: u32 = @intCast(height);
        if (w == app.width and h == app.height and app.pixels != null) return;
        const old = app.pixels;
        defer if (old) |pixels| app.sys.FreeVec(pixels);
        app.pixels = null;
        // The pixels, and after them the plasma's rows and columns for
        // their size.
        const count = @as(usize, w) * h;
        const lines = visual.linesSize(w, h);
        const memory = app.sys.AllocVec(count * 4 + lines, exec.MEMF_ANY) orelse {
            app.visual.lay(&.{}, 0, 0);
            app.width = 0;
            app.height = 0;
            return;
        };
        const pixels: [*]u32 = @ptrCast(@alignCast(memory));
        visual.carry(pixels, w, h, old, app.width, app.height);
        app.visual.lay(@as([*]align(4) u8, @ptrCast(pixels + count))[0..lines], w, h);
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

    /// One look: the picture drawn from what is being heard while its
    /// page is shown, the time now and then, a few songs' tags; the clock
    /// let rest once the sound has stopped, the picture settled and every
    /// song read.
    fn tick(app: *App) void {
        const engine = app.engine;
        if (app.page == page_picture) app.drawPicture();
        app.looks +%= 1;
        if (app.looks % looks_per_time == 0) app.showTime();
        if (app.looks % looks_per_outputs == 0) app.readOutputs();
        app.readTags();
        if (engine.state == .playing) {
            app.settle = settle_looks;
        } else if (app.settle > 0) {
            app.settle -= 1;
        } else if (app.songs.unread == 0) {
            app.mb.StopTimer(app.timer);
            app.ticking = false;
        }
    }

    /// The picture drawn from what is being heard, and shown.
    fn drawPicture(app: *App) void {
        const pixels = app.pixels orelse return;
        const rp = app.rast_port orelse return;
        const engine = app.engine;
        engine.heard(&app.samples);
        app.visual.draw(pixels, app.width, app.height, app.width, &app.samples, @max(engine.info.rate, 8000));
        app.gb.WritePixelArray(rp, @ptrCast(pixels), app.width * 4, @intFromEnum(PixelFormat.bgra32), 0, 0, &.{
            .max_x = @intCast(app.width),
            .max_y = @intCast(app.height),
        });
        app.ib.QueueGadgetRefresh(app.picture);
    }

    /// The sound's process says something: the song that follows is heard
    /// - the song shown now - or a song has ended - the next one, as the
    /// order and repeat say; a song started again meanwhile has not. That
    /// it asks for the song that follows is read at the round's end.
    fn soundNews(app: *App) void {
        if (app.engine.switched) app.advance();
        if (app.engine.state == .ended) return app.ended();
        // A station's sound holding for its ring, or going on.
        if (app.station_loaded) app.showKind();
    }

    fn run(app: *App) void {
        while (true) {
            var window_mask: usize = 0;
            _ = app.ib.GetAttr(wc.WINDOWA_SigMask, app.object, &window_mask);
            const sound_mask = app.engine.signal();
            const drop_mask = app.drop.signal();
            const asl_mask: u32 = if (app.asl_port) |port| port.sigMask() else 0;
            const big_mask = app.big.signal(app.ib);
            const about_mask = app.aboutSignal();
            const public_mask: u32 = if (app.public) |port| port.sigMask() else 0;
            const station_mask: u32 = if (app.station) |station| station.signal() else 0;
            const url_mask = app.urlSignal();
            const got = app.sys.Wait(@as(u32, @truncate(window_mask)) | sound_mask | app.tick_mask | drop_mask | asl_mask | big_mask | about_mask | public_mask | station_mask | url_mask | exec.SIGBREAKF_CTRL_C);
            if (got & exec.SIGBREAKF_CTRL_C != 0) return;
            if (got & sound_mask != 0) app.soundNews();
            if (got & drop_mask != 0) app.dropped();
            if (got & asl_mask != 0) app.answered();
            if (got & big_mask != 0) app.bigMessages();
            if (got & about_mask != 0) app.aboutAnswered(false);
            if (got & public_mask != 0) app.handedOver();
            if (got & station_mask != 0) app.stationNews();
            if (got & url_mask != 0) app.urlMessages();
            if (!app.windowMessages()) return;
            if (got & app.tick_mask != 0) app.tick();
            app.keepFollowing();
        }
    }
};

fn lengthOf(text: [*:0]const u8) usize {
    var length: usize = 0;
    while (text[length] != 0) length += 1;
    return length;
}

fn sameText(a: [*:0]const u8, b: [*:0]const u8) bool {
    var at: usize = 0;
    while (a[at] == b[at]) : (at += 1) {
        if (a[at] == 0) return true;
    }
    return false;
}

fn indexOf(text: []const u8, wanted: []const u8) ?usize {
    if (wanted.len > text.len) return null;
    for (0..text.len - wanted.len + 1) |at| {
        for (text[at..][0..wanted.len], wanted) |got, want| {
            if (got != want) break;
        } else return at;
    }
    return null;
}

/// A song's file name, as the files write it.
fn pathOf(entry: *const Entry) []const u8 {
    const path = entry.path();
    return path[0..lengthOf(path)];
}

/// ENV:Player.prefs read into `kept`: a file that is not there, or a
/// line that does not make sense, leaves the Player's own.
fn readKept(sys: *ExecBase, dl: *DosBase, ub: *UtilityBase, kept: *remembered.Settings) void {
    const text = prefs.loadWhole(sys, dl, remembered.ENV_FILE) orelse return;
    defer sys.FreeVec(text.ptr);
    const line = prefs.firstLine(text) orelse return;
    var read = kept.*;
    if (remembered.parse(ub, line, &read) == null) kept.* = read;
}

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
    items: [32]?*Object = @splat(null),
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

/// The window's font at half again its height and bold - its family's
/// bold face where it has one - from diskfont.library; null without it,
/// and then the title is in the window's font.
fn titleFont(ib: *IntuitionBase, gb: *GraphicsBase, dfb: ?*DiskfontBase) ?*graphics.TextFont {
    const fonts = dfb orelse return null;
    const font = ib.OpenSystemFont(sc.SYSFONT_DEFAULT) orelse return null;
    defer gb.CloseFont(font);
    const name = font.node.name orelse return null;
    const rows: u32 = font.image.height;
    return fonts.OpenDiskFont(&.{ .name = name, .y_size = @intCast(rows * 3 / 2), .style = graphics.FSF_BOLD });
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

/// A button of the playlist's: its text, with its key, and its ID.
fn button(ib: *IntuitionBase, label: [*:0]const u8, id: u32) ?*Object {
    return ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        pair(gc.GA_ID, id),
        pair(gc.GA_Text, @intFromPtr(label)),
        pair(gc.GA_RelVerify, 1),
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

    var argv: [4]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const only_add = argv[arg_add] != 0;
    const look_given = rdargs.string(argv[arg_look]);
    // The files by their full names: the shell's drawer is not the
    // Player's, nor the next start's that reads them back.
    var given = one.names(sys, dl, @ptrFromInt(argv[arg_files])) orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer given.free(sys);

    // A Player running already is handed what this start was given, and
    // this start ends; else this one's port is the public one, made before
    // anything slow so that a second start soon after finds it.
    switch (one.handOver(sys, &given, only_add, rdargs.number(argv[arg_volume]), if (look_given != null) lookNamed(look_given) else null)) {
        .handed => return dos.RETURN_OK,
        .no_memory => {
            _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
            return dos.RETURN_FAIL;
        },
        .alone => {},
    }
    const public = sys.CreateMsgPort() orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    public.node.name = one.PORT_NAME;
    sys.AddPort(public);
    // Taken off first, so that nothing more comes; what came meanwhile is
    // answered.
    defer {
        sys.RemPort(public);
        while (sys.GetMsg(public)) |message| sys.ReplyMsg(message);
        sys.DeleteMsgPort(public);
    }

    // How the last run left it: the settings, and the list read below.
    const utility_lib = sys.OpenLibrary(sdk.utility.UTILITYNAME, 0);
    defer if (utility_lib) |lib| sys.CloseLibrary(lib);
    const ub: ?*UtilityBase = @ptrCast(utility_lib);
    var kept = remembered.Settings{};
    if (ub) |utility_base| readKept(sys, dl, utility_base, &kept);
    const kept_volume: i32 = @intCast(kept.volume);
    const percent: u32 = @intCast(@min(@max(rdargs.number(argv[arg_volume]) orelse kept_volume, 0), 200));

    var libraries: [14]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    const wanted = [_][*:0]const u8{
        intuition.INTUITIONNAME, graphics.GRAPHICSNAME,  motion.MOTIONNAME,   ac.AUDIOCODECNAME,
        tx.TEXT_LIBRARY,         sl.SLIDER_LIBRARY,      td.TDECK_LIBRARY,    cv.CANVAS_LIBRARY,
        ch.CHOOSER_LIBRARY,      tb.TOOLBUTTON_LIBRARY,  media.MEDIA_LIBRARY, ct.CLICKTAB_LIBRARY,
        pg.PAGE_LIBRARY,         lb.LISTBROWSER_LIBRARY,
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
    // Wanted for Open... only, and opened now rather than then, so the
    // requester comes up at once rather than after the library is read.
    const asl_lib = sys.OpenLibrary(asl.ASLNAME, 1);
    defer if (asl_lib) |lib| sys.CloseLibrary(lib);

    const engine = Engine.create(sys, dl, acb) orelse {
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
    look.* = .{ .mode = if (look_given != null) lookNamed(look_given) else kept.look };
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
        .page = kept.page,
        .remember = kept.remember,
        .public = public,
    };
    if (kept.drawerName()) |name| app.keepDrawer(name.ptr);
    // Open URL...'s field's class, given back after the window that has it.
    defer if (app.string_lib) |lib| sys.CloseLibrary(lib);
    // A station let go of before the sound's process ends.
    defer app.stopStation();
    defer if (app.pixels) |pixels| sys.FreeVec(pixels);
    defer if (app.order) |order| sys.FreeVec(@ptrCast(order));
    defer app.kept.free(app.gb);
    // The songs, given back after the gadget that shows them.
    app.songs.init();
    defer app.songs.clear(sys);
    // Files named make the list - or, with ADD, go after the one kept.
    var resume_at: ?Resume = null;
    if (given.count == 0 or only_add) {
        if (kept.remember) {
            if (ub) |utility_base| resume_at = app.readList(utility_base);
        }
    }
    for (given.slice()) |name| _ = app.songs.addPath(sys, dl, name);
    app.listOrder();
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
        pair(sl.SLIDER_Max, hour),
        pair(sl.SLIDER_Level, 0),
        pair(gc.GA_Disabled, 1),
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
        pair(sl.SLIDER_Max, volume_most),
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
    app.browser = loose.add(ib.NewObjectTagList(null, lb.LISTBROWSER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_LIST),
        pair(lb.LISTBROWSER_Columns, @intFromPtr(&playlist.columns)),
        pair(lb.LISTBROWSER_Rows, @intFromPtr(&app.songs.rows)),
        pair(lb.LISTBROWSER_Reorder, 1),
        pair(icc.ICA_TARGET, icc.ICTARGET_IDCMP),
        .{},
    })) orelse return noWindow(dl);
    const add_button = loose.add(button(ib, "_Add...", ID_ADD)) orelse return noWindow(dl);
    const remove_button = loose.add(button(ib, "R_emove", ID_REMOVE)) orelse return noWindow(dl);
    const clear_button = loose.add(button(ib, "C_lear", ID_CLEAR)) orelse return noWindow(dl);

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
    // The list over its buttons, which keep their size at its left.
    const list_buttons = group(ib, &loose, &.{ pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ), pair(lg.LAYOUTA_Spacing, 6) }, &.{
        .{ .object = add_button, .weight_width = 0 },
        .{ .object = remove_button, .weight_width = 0 },
        .{ .object = clear_button, .weight_width = 0 },
        .{},
    }) orelse return noWindow(dl);
    const list_page = group(ib, &loose, &.{pair(lg.LAYOUTA_Spacing, 6)}, &.{
        .{ .object = app.browser },
        .{ .object = list_buttons, .weight_height = 0 },
    }) orelse return noWindow(dl);
    // The picture and the list on pages under tabs, which go with the
    // page gadget: no longer loose once it is made.
    const tabs = loose.add(ib.NewObjectTagList(null, ct.CLICKTAB_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_TABS),
        pair(ct.CLICKTAB_Labels, @intFromPtr(&page_names)),
        .{},
    })) orelse return noWindow(dl);
    app.pages = .{ framed, list_page };
    app.book = loose.add(ib.NewObjectTagList(null, pg.PAGE_CLASS, &[_]TagItem{
        pair(pg.PAGE_Pages, @intFromPtr(&app.pages)),
        pair(pg.PAGE_Tabs, @intFromPtr(tabs)),
        pair(pg.PAGE_Current, app.page),
        .{},
    })) orelse return noWindow(dl);
    for ([_]*Object{ framed, list_page, tabs }) |taken| loose.take(taken);
    // The tags' row grows half as fast as the pages, until the cover is
    // as large as it is kept.
    const layout = group(ib, &loose, &.{ pair(lg.LAYOUTA_Margin, 6), pair(lg.LAYOUTA_Spacing, 6) }, &.{
        .{ .object = info_row, .weight_height = 50, .max_height = cover.kept_size },
        .{ .object = seek_row, .weight_height = 0 },
        .{ .object = control_row, .weight_height = 0 },
        .{ .object = app.book },
    }) orelse return noWindow(dl);
    // The screen the window opens on, which the menus are laid out for.
    const screen = ib.LockPubScreen(null) orelse return noWindow(dl);
    defer ib.UnlockPubScreen(null, screen);
    app.screen = screen;
    app.dri = ib.GetScreenDrawInfo(screen);
    defer ib.FreeScreenDrawInfo(screen, app.dri);
    // Where it was left, and that big: a box kept on a larger screen
    // squeezed onto this one.
    const box = kept.box orelse remembered.Box{ .left = 0, .top = 0, .width = 0, .height = 0 };
    const placed = kept.box != null;
    const ignore = sdk.utility.TAG_IGNORE;
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        pair(wn.WA_PubScreen, @intFromPtr(screen)),
        pair(if (placed) wn.WA_Left else ignore, @intCast(box.left)),
        pair(if (placed) wn.WA_Top else ignore, @intCast(box.top)),
        pair(if (placed) wn.WA_Width else ignore, @intCast(box.width)),
        pair(if (placed) wn.WA_Height else ignore, @intCast(box.height)),
        pair(if (placed) wn.WA_AutoAdjust else ignore, 1),
        pair(wn.WA_Title, @intFromPtr(COMMAND_NAME)),
        pair(wn.WA_ScreenTitle, @intFromPtr(SCREEN_TITLE)),
        pair(wn.WA_CloseGadget, 1),
        pair(wn.WA_DragBar, 1),
        pair(wn.WA_DepthGadget, 1),
        pair(wn.WA_SizeGadget, 1),
        pair(wn.WA_Activate, 1),
        pair(wn.WA_IDCMP, wn.IDCMP_IDCMPUPDATE | wn.IDCMP_NEWSIZE | wn.IDCMP_ACTIVEWINDOW | wn.IDCMP_NEWPREFS | wn.IDCMP_RAWKEY),
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
    // The large cover's window and Open URL...'s, closed before this one.
    defer app.big.close(ib);
    defer app.closeUrl();
    app.fitPicture();
    app.set(app.cover, &.{ pair(cv.CANVAS_Width, 0), pair(cv.CANVAS_Height, 0), .{} });
    app.showCover(null, "", COMMAND_NAME);

    // The menus, ticked as things are; the window plays without them when
    // they will not go on.
    app.strip = blk: {
        const made = ib.CreateMenusA(&menus, null) orelse break :blk null;
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
    app.showMenuTicks();
    defer app.aboutAnswered(true);
    // Shuffle and repeat as they were left.
    app.repeatTo(@enumFromInt(kept.repeat));
    if (kept.shuffle) app.shuffleTurned(true);

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

    // Every file of a drop is the list's.
    app.drop.all = true;
    app.drop.add(sys, app.window);
    defer app.drop.remove();

    // Open...'s port; the requester is made the first time it is asked
    // for, and taken down before the window closes.
    if (app.al != null) app.asl_port = sys.CreateMsgPort();
    defer app.dropRequest();

    _ = sys.SetSignal(0, exec.SIGBREAKF_CTRL_C);
    if (resume_at) |where| {
        app.resumeAt(where);
    } else if (app.songs.count > 0 and !only_add) app.goTo(0, .play) else app.wake();
    app.run();
    app.keep();
    return dos.RETURN_OK;
}
