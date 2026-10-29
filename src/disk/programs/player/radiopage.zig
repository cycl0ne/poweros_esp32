// SPDX-License-Identifier: MIT
//! The Radio page: the stations kept and the stations found, one list at
//! a time - a chooser turns a page.gadget without tabs between the two -
//! under a search line, a field for the words, a chooser of what they are
//! looked for in (name, genre, country) and Search; under the lists Keep
//! and Remove, and a line that says how the search goes.
//!
//! A double-click or Return plays a station: it goes into the playlist -
//! or the row there with its address is taken - under its name. A station
//! found that is played is told to the service (finder.zig). Keep keeps
//! the station found that is selected, or else the station playing; Remove
//! and Del take the kept one selected out. A search turns to the stations
//! found; its answers replace those found before.
//!
//! **The finder** - the process that asks radio-browser.info - is started
//! the first time it is wanted, and asked for the picture of each station
//! played that has one, kept or found, and for the cover a station names
//! for the song it plays: the window shows it as the cover.
//!
//! The window builds the page's gadgets and hands them over; what they
//! do is here. A gadget is drawn when it is set only while the page is
//! shown (`shown`).

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const intuition = sdk.intuition;
const prefs = sdk.prefs;
const lb = sdk.gadgets.listbrowser;
const ch = sdk.gadgets.chooser;
const tx = sdk.gadgets.text;
const pg = sdk.gadgets.page;
const gc = intuition.gadgetclass;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const Object = intuition.Object;
const Window = intuition.Window;
const TagItem = sdk.utility.TagItem;
const stations = @import("stations.zig");
const Station = stations.Station;
const finder_file = @import("finder.zig");
const Finder = finder_file.Finder;

pub const ID_VIEW = 23;
pub const ID_KEPT = 24;
pub const ID_FOUND = 25;
pub const ID_FIND = 26;
pub const ID_BY = 27;
pub const ID_SEARCH = 28;
pub const ID_KEEP = 29;
pub const ID_REMOVE = 30;

/// The two lists, as the chooser names them.
pub const view_kept = 0;
pub const view_found = 1;
pub const view_labels = [_:null]?[*:0]const u8{ "Your stations", "Found" };

/// The station shown in the window, for Keep.
pub const Playing = struct {
    url: [*:0]const u8,
    name: [*:0]const u8,
};

/// A station's picture, fetched: the address of the station it is of,
/// its bytes, the finder's until the next is asked for - none when it
/// could not be fetched - and whether it is the cover of the song playing
/// rather than the station's own.
pub const Logo = struct {
    url: [*:0]const u8,
    bytes: []const u8,
    song: bool = false,
};

pub const Page = struct {
    sys: *ExecBase,
    dl: *DosBase,
    ib: *IntuitionBase,
    /// The name the finder's requests give.
    agent: [*:0]const u8,
    window: ?*Window = null,
    shown: bool = false,

    kept: stations.Stations = .{},
    found: stations.Stations = .{},
    view: u32 = view_kept,
    by: finder_file.By = .name,

    /// The gadgets, the window's builder's.
    book: *Object = undefined,
    pages: [view_labels.len:null]?*Object = @splat(null),
    view_chooser: *Object = undefined,
    kept_list: *Object = undefined,
    found_list: *Object = undefined,
    field: *Object = undefined,
    status: *Object = undefined,
    status_text: [128:0]u8 = @splat(0),

    finder: ?*Finder = null,
    news: finder_file.News = .{},
    /// The search asked last, and the last whose answers were read.
    search_round: u32 = 0,
    search_read: u32 = 0,
    /// The picture asked for last, the station it is of, whether it is a
    /// song's cover, and whether it has been taken.
    logo_round: u32 = 0,
    logo_taken: bool = true,
    logo_for: [dos.path_max + 1:0]u8 = @splat(0),
    logo_song: bool = false,

    /// Made where it is to stay - the lists point at themselves - and the
    /// stations kept read.
    pub fn init(page: *Page) void {
        page.kept.init();
        page.found.init();
        const text = prefs.loadWhole(page.sys, page.dl, stations.KEPT_ENV_FILE) orelse return;
        defer page.sys.FreeVec(text.ptr);
        page.kept.readKept(page.sys, text);
    }

    /// The finder let go of and both lists given back: after the window,
    /// whose gadgets show them, is gone.
    pub fn free(page: *Page) void {
        if (page.finder) |finder| finder.free();
        page.finder = null;
        page.kept.clear(page.sys);
        page.found.clear(page.sys);
    }

    /// The stations kept written to ENV: and ENVARC: when Keep or Remove
    /// changed them, their drawers made first where they are not there.
    pub fn keepFiles(page: *Page) void {
        if (!page.kept.changed) return;
        const text = page.kept.keptText(page.sys) orelse return;
        defer page.sys.FreeVec(text.ptr);
        for ([_][*:0]const u8{ stations.KEPT_ENV_DRAWER, stations.KEPT_ENVARC_DRAWER }) |drawer| {
            if (page.dl.Lock(drawer, dos.SHARED_LOCK)) |lock| {
                page.dl.UnLock(lock);
            } else if (page.dl.CreateDir(drawer)) |made| page.dl.UnLock(made);
        }
        _ = prefs.save(page.dl, stations.KEPT_ENV_FILE, text);
        _ = prefs.save(page.dl, stations.KEPT_ENVARC_FILE, text);
        page.kept.changed = false;
    }

    /// The finder's signal, once it is started.
    pub fn signal(page: *const Page) u32 {
        const finder = page.finder orelse return 0;
        return finder.signal();
    }

    fn set(page: *Page, gadget: *Object, tags: []const TagItem) void {
        _ = page.ib.SetGadgetAttrsTagList(gadget, if (page.shown) page.window else null, tags.ptr);
    }

    fn startFinder(page: *Page) ?*Finder {
        if (page.finder == null) page.finder = Finder.start(page.sys, page.dl, page.agent);
        return page.finder;
    }

    // --- the lists ---------------------------------------------------------------

    fn listOf(page: *Page, view: u32) *Object {
        return if (view == view_found) page.found_list else page.kept_list;
    }

    fn stationsOf(page: *Page, view: u32) *stations.Stations {
        return if (view == view_found) &page.found else &page.kept;
    }

    /// A list taken from its gadget while it changes.
    fn detach(page: *Page, view: u32) void {
        _ = page.ib.SetGadgetAttrsTagList(page.listOf(view), null, &[_]TagItem{ .{ .tag = lb.LISTBROWSER_Rows, .data = lb.LISTBROWSER_DETACH }, .{} });
    }

    /// A list given back to its gadget, `picked` the row selected, and
    /// drawn again at the next chance.
    fn giveBack(page: *Page, view: u32, picked: u32) void {
        const list = page.listOf(view);
        _ = page.ib.SetGadgetAttrsTagList(list, null, &[_]TagItem{
            .{ .tag = lb.LISTBROWSER_Rows, .data = @intFromPtr(&page.stationsOf(view).rows) },
            .{ .tag = lb.LISTBROWSER_Selected, .data = picked },
            .{},
        });
        page.ib.QueueGadgetRefresh(list);
    }

    /// The station selected in the list of `view`, if one is.
    fn selected(page: *Page, view: u32) ?*Station {
        var value: usize = 0;
        _ = page.ib.GetAttr(lb.LISTBROWSER_SelectedRow, page.listOf(view), &value);
        const row: ?*lb.Row = @ptrFromInt(value);
        return Station.of(row orelse return null);
    }

    /// The list of `view` shown, and the chooser saying so.
    pub fn turnTo(page: *Page, view: u32) void {
        page.view = view;
        page.set(page.view_chooser, &.{ .{ .tag = ch.CHOOSER_Active, .data = view }, .{} });
        page.set(page.book, &.{ .{ .tag = pg.PAGE_Current, .data = view }, .{} });
    }

    /// The station to play from the list shown: the one selected.
    pub fn toPlay(page: *Page) ?*Station {
        return page.selected(page.view);
    }

    /// A press let go on a list: the station double-clicked, to be played.
    pub fn pressed(page: *Page, code: u32) ?*Station {
        if (code & lb.LISTBROWSER_DOUBLE == 0) return null;
        return page.toPlay();
    }

    /// `station` played: the service told, when it was found there.
    pub fn listened(page: *Page, station: *const Station) void {
        if (station.uuid[0] == 0) return;
        const finder = page.startFinder() orelse return;
        finder.listened(@ptrCast(&station.uuid));
    }

    /// The name a station kept or found goes by, for a row of the
    /// playlist with its address.
    pub fn nameOf(page: *Page, url: [*:0]const u8) ?[*:0]const u8 {
        const station = page.kept.find(url) orelse page.found.find(url) orelse return null;
        return @ptrCast(&station.name);
    }

    /// Keep: the station found that is selected, or else `playing`, put
    /// at the end of the stations kept and selected there. A station kept
    /// already is only selected.
    pub fn keep(page: *Page, playing: ?Playing) void {
        var made: stations.Made = undefined;
        if (if (page.view == view_found) page.selected(view_found) else null) |station| {
            made = .{ .name = textOf(@ptrCast(&station.name)), .url = textOf(station.url()), .logo = if (station.logo()) |logo| textOf(logo) else "" };
        } else if (playing) |shown| {
            const known = page.found.find(shown.url);
            const logo: []const u8 = if (known) |station| (if (station.logo()) |picture| textOf(picture) else "") else "";
            made = .{ .name = textOf(shown.name), .url = textOf(shown.url), .logo = logo };
        } else return page.ib.DisplayBeep(null);
        var url: [dos.path_max + 1:0]u8 = @splat(0);
        const length = @min(made.url.len, dos.path_max);
        @memcpy(url[0..length], made.url[0..length]);
        if (page.kept.find(&url)) |station| {
            page.say("Kept already: ", @ptrCast(&station.name));
            return page.giveBack(view_kept, @intCast(page.kept.placeOf(station)));
        }
        page.detach(view_kept);
        const station = page.kept.add(page.sys, made, false);
        if (station != null) page.kept.changed = true;
        page.giveBack(view_kept, if (station) |added| @intCast(page.kept.placeOf(added)) else lb.LISTBROWSER_NONE);
        if (station) |added| page.say("Kept: ", @ptrCast(&added.name)) else page.say("No memory to keep the station", null);
    }

    /// Remove: the station kept that is selected taken out, and the one
    /// after it selected.
    pub fn remove(page: *Page) void {
        if (page.view != view_kept) return page.ib.DisplayBeep(null);
        const station = page.selected(view_kept) orelse return;
        const place = page.kept.placeOf(station);
        page.detach(view_kept);
        page.kept.remove(page.sys, station);
        page.kept.changed = true;
        const count = page.kept.count;
        page.giveBack(view_kept, if (count == 0) lb.LISTBROWSER_NONE else @intCast(@min(place, count - 1)));
    }

    // --- the search --------------------------------------------------------------

    /// Search: the words in the field looked for, the list found shown;
    /// a beep for no words.
    pub fn search(page: *Page) void {
        var value: usize = 0;
        _ = page.ib.GetAttr(gc.STRINGA_TextVal, page.field, &value);
        const typed: [*:0]const u8 = if (value != 0) @ptrFromInt(value) else "";
        const words = trimmed(typed);
        if (words.len == 0) return page.ib.DisplayBeep(null);
        const finder = page.startFinder() orelse return page.say("No memory for the search", null);
        page.search_round = finder.search(words, page.by);
        page.turnTo(view_found);
        page.say("Searching", null);
    }

    /// What the finder says: how the search goes, the stations it found -
    /// put into the list found in place of those before - and the picture
    /// asked for last once it has come, or could not be fetched, handed
    /// back.
    pub fn heard(page: *Page) ?Logo {
        const finder = page.finder orelse return null;
        finder.news(&page.news);
        const news = &page.news;
        if (page.search_round != 0 and news.round == page.search_round and page.search_read != page.search_round) {
            switch (news.phase) {
                .idle => {},
                .searching => if (news.server[0] != 0) page.say("Asking ", @ptrCast(&news.server)) else page.say("Searching", null),
                .failed => {
                    page.search_read = page.search_round;
                    page.say(@ptrCast(&news.why), null);
                },
                .done => {
                    page.search_read = page.search_round;
                    page.detach(view_found);
                    page.found.clear(page.sys);
                    for (finder.answers()) |answer| _ = page.found.readFound(page.sys, answer);
                    page.giveBack(view_found, if (page.found.count > 0) 0 else lb.LISTBROWSER_NONE);
                    page.sayCount(page.found.count);
                },
            }
        }
        if (page.logo_taken or news.logo_round != page.logo_round) return null;
        page.logo_taken = true;
        const bytes: []const u8 = if (news.logo_length == 0) &.{} else finder.logoBytes(news.logo_length);
        return .{ .url = &page.logo_for, .bytes = bytes, .song = page.logo_song };
    }

    /// A song's cover still on its way no longer wanted.
    pub fn forgetCover(page: *Page) void {
        if (page.logo_song) page.logo_taken = true;
    }

    /// Whether a station's own picture is on its way.
    pub fn askingLogo(page: *Page) bool {
        return !page.logo_taken and !page.logo_song;
    }

    /// The picture of the station at `url`, when one kept or found has
    /// one, asked of the finder: false when none is.
    pub fn askLogo(page: *Page, url: [*:0]const u8) bool {
        const station = page.kept.find(url) orelse page.found.find(url) orelse return false;
        const logo = station.logo() orelse return false;
        return page.fetch(url, logo, false);
    }

    /// The cover at `picture` - what the station at `url` names, in its
    /// metadata, for the song it plays - asked of the finder: false when
    /// the finder cannot be started.
    pub fn askCover(page: *Page, url: [*:0]const u8, picture: [*:0]const u8) bool {
        return page.fetch(url, picture, true);
    }

    /// The picture at `picture` asked for the station at `url`, the one
    /// asked before given up.
    fn fetch(page: *Page, url: [*:0]const u8, picture: [*:0]const u8, song: bool) bool {
        const finder = page.startFinder() orelse return false;
        page.logo_for = @splat(0);
        const length = @min(lengthOf(url), dos.path_max);
        @memcpy(page.logo_for[0..length], url[0..length]);
        page.logo_round = finder.fetchLogo(picture);
        page.logo_taken = false;
        page.logo_song = song;
        return true;
    }

    /// The line under the lists: `first`, and `then` after it.
    fn say(page: *Page, first: [*:0]const u8, then: ?[*:0]const u8) void {
        page.status_text = @splat(0);
        var length: usize = 0;
        for ([_]?[*:0]const u8{ first, then }) |maybe| {
            const piece = maybe orelse continue;
            var at: usize = 0;
            while (piece[at] != 0 and length < page.status_text.len) : (at += 1) {
                page.status_text[length] = piece[at];
                length += 1;
            }
        }
        page.set(page.status, &.{ .{ .tag = tx.TEXT_Text, .data = @intFromPtr(&page.status_text) }, .{} });
    }

    /// How many stations the search found, said.
    fn sayCount(page: *Page, count: usize) void {
        if (count == 0) return page.say("No station found", null);
        if (count == 1) return page.say("One station found", null);
        var line: [48:0]u8 = @splat(0);
        const stream = exec.fmtStream(.{@as(u32, @intCast(count))});
        comptime exec.checkFormat("%u stations found", @TypeOf(.{@as(u32, 0)}));
        _ = page.sys.RawDoFmt("%u stations found", &stream, null, &line);
        page.say(&line, null);
    }
};

/// `text` without the spaces at either end.
fn trimmed(text: [*:0]const u8) []const u8 {
    var start: usize = 0;
    while (text[start] == ' ') start += 1;
    var end = start + lengthOf(text + start);
    while (end > start and text[end - 1] == ' ') end -= 1;
    return text[start..end];
}

fn textOf(text: [*:0]const u8) []const u8 {
    return text[0..lengthOf(text)];
}

fn lengthOf(text: [*:0]const u8) usize {
    var n: usize = 0;
    while (text[n] != 0) n += 1;
    return n;
}
