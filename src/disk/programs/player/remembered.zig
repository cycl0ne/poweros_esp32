// SPDX-License-Identifier: MIT
//! What the Player keeps from one run to the next, and the two files it
//! is kept in - each in `ENV:` and in `ENVARC:`, written as the Player
//! ends and read from `ENV:` as it starts.
//!
//! Player.prefs, one line:
//!
//!     WINDOW=40,30,560,420 PAGE=PLAYLIST LOOK=BARS VOLUME=100 SHUFFLE=NO REPEAT=ALL REMEMBER=YES DRAWER="SYS:Music"
//!
//! - WINDOW: the window's left, top, width and height.
//! - PAGE: the page shown, PLAYING or PLAYLIST.
//! - LOOK: the picture, PLASMA, WAVE or BARS.
//! - VOLUME: in percent of as recorded, 0 to 200.
//! - SHUFFLE: YES or NO. REPEAT: OFF, ALL or ONE.
//! - REMEMBER: YES to keep the list and where it was in Player.list, NO
//!   to start with an empty list.
//! - DRAWER: where the file requester was last answered.
//!
//! A word left out keeps the value it has. `parse` reads the line into
//! `Settings`, `write` writes them as the line, and `header` is the
//! explanation put before it.
//!
//! Player.list, a line for each song in the list's order; the song shown
//! carries the second it was at:
//!
//!     SONG="SYS:Music/Fire.mp3"
//!     SONG="SYS:Music/More/Demo.mp3" AT=83
//!
//! `Songs` reads them a line at a time - a line that is not a song is
//! passed over, so one gone wrong costs that song and no other -
//! `songLine` writes one, and `list_header` is the file's explanation.
//! Nothing here opens or draws: the host tests hold all of it.

const sdk = @import("sdk");
const prefs = sdk.prefs;
const style = prefs.style;
const UtilityBase = sdk.interface.utility.UtilityBase;
const visual = @import("visual.zig");

pub const ENV_FILE = "ENV:Player.prefs";
pub const ENVARC_FILE = "ENVARC:Player.prefs";
pub const LIST_ENV_FILE = "ENV:Player.list";
pub const LIST_ENVARC_FILE = "ENVARC:Player.list";

/// PAGE's words, by the page's number.
pub const page_names = [2][]const u8{ "PLAYING", "PLAYLIST" };
/// LOOK's words, by `visual.Mode`.
pub const look_names = [visual.mode_count][]const u8{ "PLASMA", "WAVE", "BARS" };
/// REPEAT's words: off, the whole list, the one song.
pub const repeat_names = [3][]const u8{ "OFF", "ALL", "ONE" };
/// The loudest VOLUME, twice as loud as recorded.
pub const volume_most = 200;
/// The longest DRAWER kept, its NUL aside.
pub const drawer_max = sdk.dos.path_max;
/// What `write` needs at most: the words and the longest drawer.
pub const line_max = 160 + drawer_max;

/// A window's place and size.
pub const Box = struct {
    left: i32,
    top: i32,
    width: i32,
    height: i32,
};

pub const Settings = struct {
    /// The window as it was left; null before one was kept.
    box: ?Box = null,
    /// An index into `page_names`.
    page: u8 = 0,
    look: visual.Mode = .plasma,
    volume: u32 = 100,
    shuffle: bool = false,
    /// An index into `repeat_names`.
    repeat: u8 = 0,
    remember: bool = true,
    /// NUL-terminated; empty for none.
    drawer: [drawer_max + 1]u8 = @splat(0),

    /// The drawer last answered in, or null for none.
    pub fn drawerName(settings: *const Settings) ?[:0]const u8 {
        var len: usize = 0;
        while (settings.drawer[len] != 0) len += 1;
        if (len == 0) return null;
        return settings.drawer[0..len :0];
    }

    /// The drawer kept; false when the name is too long to keep, which
    /// leaves the one kept before.
    pub fn setDrawer(settings: *Settings, name: []const u8) bool {
        if (name.len > drawer_max) return false;
        @memset(&settings.drawer, 0);
        @memcpy(settings.drawer[0..name.len], name);
        return true;
    }
};

fn indexOf(names: []const []const u8, text: []const u8) ?usize {
    for (names, 0..) |name, i| if (style.same(text, name)) return i;
    return null;
}

/// The line read into `settings`, which keeps what it leaves out: null
/// when it is taken, else what is wrong with the first word that is not,
/// which leaves the words after it unread.
pub fn parse(ub: *UtilityBase, text: []const u8, settings: *Settings) ?[*:0]const u8 {
    var pairs = prefs.Pairs.init(ub, text);
    while (pairs.next() catch return prefs.Pairs.quote_not_closed) |pair| {
        const word = pair.key;
        const value = pair.value;
        if (style.same(word, "WINDOW")) {
            const box = sdk.icon.file.numbers(4, value) orelse return "WINDOW is left,top,width,height";
            if (box[0] < 0 or box[1] < 0 or box[2] <= 0 or box[3] <= 0) return "WINDOW is left,top,width,height";
            settings.box = .{ .left = box[0], .top = box[1], .width = box[2], .height = box[3] };
        } else if (style.same(word, "PAGE")) {
            const k = indexOf(&page_names, value) orelse return "PAGE is PLAYING or PLAYLIST";
            settings.page = @intCast(k);
        } else if (style.same(word, "LOOK")) {
            const k = indexOf(&look_names, value) orelse return "LOOK is PLASMA, WAVE or BARS";
            settings.look = @enumFromInt(k);
        } else if (style.same(word, "VOLUME")) {
            const percent = style.decimal(value) orelse return "VOLUME is a percentage, 0 to 200";
            if (percent > volume_most) return "VOLUME is a percentage, 0 to 200";
            settings.volume = percent;
        } else if (style.same(word, "SHUFFLE")) {
            settings.shuffle = prefs.yesOrNo(value) orelse return "SHUFFLE is YES or NO";
        } else if (style.same(word, "REPEAT")) {
            const k = indexOf(&repeat_names, value) orelse return "REPEAT is OFF, ALL or ONE";
            settings.repeat = @intCast(k);
        } else if (style.same(word, "REMEMBER")) {
            settings.remember = prefs.yesOrNo(value) orelse return "REMEMBER is YES or NO";
        } else if (style.same(word, "DRAWER")) {
            if (!settings.setDrawer(value)) return "DRAWER's name is too long";
        } else {
            return "a word that is not WINDOW, PAGE, LOOK, VOLUME, SHUFFLE, REPEAT, REMEMBER or DRAWER";
        }
    }
    return null;
}

/// Text put into `into` from `at`; where it ends. `into` is `line_max`
/// bytes or more, which holds every line.
fn put(into: []u8, at: usize, text: []const u8) usize {
    @memcpy(into[at..][0..text.len], text);
    return at + text.len;
}

fn putNumber(into: []u8, at: usize, value: i32) usize {
    return at + prefs.number(@intCast(@max(value, 0)), into[at..]);
}

/// `settings` written as the line into `into` (`line_max` bytes will do):
/// how many bytes, no newline. A drawer with a double quote in it is left
/// out, since the form has no way to write it.
pub fn write(settings: *const Settings, into: []u8) usize {
    var at: usize = 0;
    if (settings.box) |box| {
        at = put(into, at, "WINDOW=");
        at = putNumber(into, at, box.left);
        at = put(into, at, ",");
        at = putNumber(into, at, box.top);
        at = put(into, at, ",");
        at = putNumber(into, at, box.width);
        at = put(into, at, ",");
        at = putNumber(into, at, box.height);
        at = put(into, at, " ");
    }
    at = put(into, at, "PAGE=");
    at = put(into, at, page_names[@min(settings.page, page_names.len - 1)]);
    at = put(into, at, " LOOK=");
    at = put(into, at, look_names[@intFromEnum(settings.look)]);
    at = put(into, at, " VOLUME=");
    at = putNumber(into, at, @intCast(@min(settings.volume, volume_most)));
    at = put(into, at, " SHUFFLE=");
    at = put(into, at, prefs.yes_no[@intFromBool(settings.shuffle)]);
    at = put(into, at, " REPEAT=");
    at = put(into, at, repeat_names[@min(settings.repeat, repeat_names.len - 1)]);
    at = put(into, at, " REMEMBER=");
    at = put(into, at, prefs.yes_no[@intFromBool(settings.remember)]);
    if (settings.drawerName()) |drawer| {
        if (!hasQuote(drawer)) {
            at = put(into, at, " DRAWER=\"");
            at = put(into, at, drawer);
            at = put(into, at, "\"");
        }
    }
    return at;
}

fn hasQuote(text: []const u8) bool {
    for (text) |c| if (c == '"') return true;
    return false;
}

/// Player.prefs' explanation, every line a comment.
pub const header =
    \\# ENVARC:Player.prefs - how the Player was left, which it opens with:
    \\# written as it ends. One line:
    \\#
    \\# WINDOW    its window's left, top, width and height.
    \\# PAGE      the page shown: PLAYING or PLAYLIST.
    \\# LOOK      the picture: PLASMA, WAVE or BARS.
    \\# VOLUME    in percent of as recorded, 0 to 200.
    \\# SHUFFLE   YES or NO.
    \\# REPEAT    OFF, the whole list (ALL) or the one song (ONE).
    \\# REMEMBER  YES to keep the list and where it was in Player.list,
    \\#           NO to start with an empty list.
    \\# DRAWER    where the file requester was last answered.
    \\#
    \\# One left out keeps the Player's own: PAGE=PLAYING LOOK=PLASMA
    \\# VOLUME=100 SHUFFLE=NO REPEAT=OFF REMEMBER=YES.
    \\
;

/// A song of Player.list: its file, and for the song shown the second it
/// was at.
pub const Song = struct {
    path: []const u8,
    at: ?u32 = null,
};

/// Player.list's songs, a line at a time. Blank lines and comments are
/// passed over, and so is a line that is not a song - the last of them
/// told by `bad_line` and `problem`.
pub const Songs = struct {
    ub: *UtilityBase,
    lines: prefs.Lines,
    /// The number of the last line passed over as not a song, and what
    /// is wrong with it; 0 and null while there is none.
    bad_line: u32 = 0,
    problem: ?[*:0]const u8 = null,

    pub fn init(ub: *UtilityBase, text: []const u8) Songs {
        return .{ .ub = ub, .lines = .{ .text = text } };
    }

    /// The next song, null at the end of the file. Its path is in the
    /// text, which the caller keeps while it uses it.
    pub fn next(songs: *Songs) ?Song {
        while (songs.lines.next()) |line| {
            if (!style.hasWords(line.text)) continue;
            var problem: [*:0]const u8 = undefined;
            if (parseSong(songs.ub, line.text, &problem)) |song| return song;
            songs.bad_line = line.number;
            songs.problem = problem;
        }
        return null;
    }
};

/// One line as a song; null, with `problem` saying why, when it is not
/// one.
fn parseSong(ub: *UtilityBase, text: []const u8, problem: *[*:0]const u8) ?Song {
    const form = "not in the form SONG=\"SYS:Music/Fire.mp3\" AT=83";
    var pairs = prefs.Pairs.init(ub, text);
    var song: ?Song = null;
    while (pairs.next() catch {
        problem.* = prefs.Pairs.quote_not_closed;
        return null;
    }) |pair| {
        if (style.same(pair.key, "SONG") and song == null) {
            if (pair.value.len == 0 or pair.value.len > drawer_max) {
                problem.* = "SONG is a file's full name, \"SYS:Music/Fire.mp3\"";
                return null;
            }
            song = .{ .path = pair.value };
        } else if (style.same(pair.key, "AT") and song != null and song.?.at == null) {
            song.?.at = style.decimal(pair.value) orelse {
                problem.* = "AT is the second the song was at";
                return null;
            };
        } else {
            problem.* = form;
            return null;
        }
    }
    if (song == null) problem.* = form;
    return song;
}

/// The bytes `songLine` writes for `song` at most, newline included.
pub fn songLength(song: Song) usize {
    return "SONG=\"\" AT=4294967295\n".len + song.path.len;
}

/// `song` written as its line into `into` (`songLength` bytes will do):
/// how many bytes, newline included; null for a name with a double quote
/// in it, which the form has no way to write.
pub fn songLine(song: Song, into: []u8) ?usize {
    if (hasQuote(song.path)) return null;
    var at = put(into, 0, "SONG=\"");
    at = put(into, at, song.path);
    at = put(into, at, "\"");
    if (song.at) |second| {
        at = put(into, at, " AT=");
        at += prefs.number(second, into[at..]);
    }
    return put(into, at, "\n");
}

/// Player.list's explanation, every line a comment.
pub const list_header =
    \\# ENVARC:Player.list - the songs the Player had, in the list's order,
    \\# which it opens with when it is started without files and
    \\# Player.prefs says REMEMBER=YES: written as it ends. A line for each:
    \\#
    \\# SONG="SYS:Music/Fire.mp3"           a file, by its full name.
    \\# SONG="SYS:Music/Rise.mp3" AT=83     the song shown, and the second
    \\#                                     it was at.
    \\
;
