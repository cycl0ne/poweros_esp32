// SPDX-License-Identifier: MIT
//! Weather: the weather at any place now, for the next 24 hours and for
//! the three days after today, in a window.
//!
//!   Weather [PLACE <words>]
//!
//! **A place** is typed into the field at the top - an address, a street
//! and its number, a postcode or a town - and found with Return or
//! Search: OpenStreetMap's Nominatim finds it (Open-Meteo's search, which
//! knows towns, when Nominatim cannot be reached), and Open-Meteo is
//! asked for its weather (`fetch.zig`). Keep puts the place shown among
//! those kept, which the chooser beside it shows again with one pick;
//! Remove takes the one the chooser shows away. The places kept, the one
//! shown last and the units are in `ENV:Weather.json` and ENVARC: too
//! (`places.zig`), so the window opens on the last place shown. PLACE
//! looks a place up as the window opens.
//!
//! **The last answer** is kept as well, with when it came (`last.zig`):
//! the window opens on the place's picture from it at once, the question
//! asked again going on at the top right, rather than on an empty sky
//! until the answer is there - for the place shown last, in the units
//! asked for, a day at the most after it came.
//!
//! **The picture** (`view.zig`) is drawn anew when an answer comes, when
//! a sizing of the window ends and when a question is asked; while the
//! size gadget is held, the last picture is shown stretched. The weather
//! is asked for again every quarter of an hour, and at once with
//! Project/Refresh. Settings/Celsius and Settings/Fahrenheit say which
//! units are asked for - the wind in km/h or mph with them; without a
//! setting, the locale's measuring system says.
//!
//! The network is the fetcher's process: the window never waits on it,
//! and a question asked while one is answered makes the older one's
//! answer not wanted.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const json = sdk.json;
const locale = sdk.locale;
const motion = sdk.motion;
const utility = sdk.utility;
const vector = sdk.vector;
const diskfont = sdk.diskfont;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const VectorBase = sdk.interface.vector.VectorBase;
const JSONBase = sdk.interface.json.JSONBase;
const MotionBase = sdk.interface.motion.MotionBase;
const DiskfontBase = sdk.interface.diskfont.DiskfontBase;
const TagItem = utility.TagItem;
const Object = intuition.Object;
const rdargs = dos.rdargs;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wn = intuition.windows;
const wc = intuition.windowclass;
const sc = intuition.screens;
const mn = intuition.menus;
const classusr = intuition.classusr;
const ie = sdk.devices.inputevent;
const cv = sdk.gadgets.canvas;
const st = sdk.gadgets.string;
const ch = sdk.gadgets.chooser;
const strings = @import("strings");
const Id = strings.Id;
const Text = locale.Strings(strings);
const forecast = @import("forecast.zig");
const fetch = @import("fetch.zig");
const places = @import("places.zig");
const last = @import("last.zig");
const view_area = @import("view.zig");
const Fetcher = fetch.Fetcher;
const Place = forecast.Place;
const Forecast = forecast.Forecast;
const Settings = places.Settings;
const View = view_area.View;

pub const COMMAND_NAME = "Weather";
const VERSION = "1.1";
const DATE = "25.11.2026";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (" ++ DATE ++ ")\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
const SCREEN_TITLE = COMMAND_NAME ++ " " ++ VERSION;
const ABOUT_VERSION = COMMAND_NAME ++ " " ++ VERSION ++ " (" ++ DATE ++ ")";
/// What the requests give as who asks.
const USER_AGENT = COMMAND_NAME ++ "/" ++ VERSION;

const template = "PLACE/F";
const arg_place = 0;
const arg_count = 1;

/// How often the weather is asked for again: a quarter of an hour, which
/// is how often the service's own numbers change.
const refresh_ms = 15 * 60 * 1000;

/// The picture's size as the window opens, when the screen has room.
const start_width = 760;
const start_height = 520;

const ID_FIELD = 1;
const ID_SEARCH = 2;
const ID_KEPT = 3;
const ID_KEEP = 4;
const ID_REMOVE = 5;
const ID_CANVAS = 6;

/// A field says which key ended it, as the raw key it was: Return and the
/// keypad's Enter search, where Tab and a press elsewhere only leave it.
const raw_return: u32 = 0x44;
const raw_enter: u32 = 0x43;

fn entered(code: u32) bool {
    return code == raw_return or code == raw_enter;
}

// --- the menus ------------------------------------------------------------------------

const MENU_PROJECT = 0;
const ITEM_REFRESH = 0;
const ITEM_ABOUT = 2;
const ITEM_QUIT = 4;
const MENU_SETTINGS = 1;
const ITEM_CELSIUS = 0;
const ITEM_FAHRENHEIT = 1;

const MenuEntry = struct { menu: mn.NewMenu, text: ?Id = null };

fn menuTitle(text: Id) MenuEntry {
    return .{ .menu = .{ .type = mn.NM_TITLE, .label = strings.builtin(text) }, .text = text };
}

fn menuItem(text: Id, key: ?[*:0]const u8, flags: u32, exclude: u32) MenuEntry {
    return .{ .menu = .{ .type = mn.NM_ITEM, .label = strings.builtin(text), .comm_key = key, .flags = flags, .mutual_exclude = exclude }, .text = text };
}

const bar = MenuEntry{ .menu = .{ .type = mn.NM_ITEM, .label = mn.NM_BARLABEL } };

const menu_table = [_]MenuEntry{
    menuTitle(.MSG_MENU_PROJECT),
    menuItem(.MSG_MENU_REFRESH, "R", 0, 0),
    bar,
    menuItem(.MSG_MENU_ABOUT, null, 0, 0),
    bar,
    menuItem(.MSG_MENU_QUIT, "Q", 0, 0),
    menuTitle(.MSG_MENU_SETTINGS),
    menuItem(.MSG_MENU_CELSIUS, null, mn.CHECKIT, 1 << ITEM_FAHRENHEIT),
    menuItem(.MSG_MENU_FAHRENHEIT, null, mn.CHECKIT, 1 << ITEM_CELSIUS),
};
/// Where Celsius and Fahrenheit are in the table.
const celsius_entry = 7;
const fahrenheit_entry = 8;

// --- the program ----------------------------------------------------------------------

const App = struct {
    sys: *ExecBase,
    dl: *DosBase,
    ib: *IntuitionBase,
    jb: ?*JSONBase,
    text: *const Text,
    object: *Object,
    window: *intuition.Window,
    field: *Object,
    kept: *Object,
    remove: *Object,
    view: *View,
    fetcher: *Fetcher,
    menu: ?*intuition.Menu = null,

    settings: Settings = .{},
    /// The chooser's labels: the places kept, or the words that say
    /// there are none.
    labels: [places.max_places + 1]?[*:0]const u8 = @splat(null),
    /// The question the window waits on the answer to; 0 for none.
    round: u32 = 0,
    /// The last answer, kept while another is asked for.
    seen: Forecast = .{},
    seen_place: Place = .{},
    have: bool = false,
    news: fetch.News = .{},
    /// What the picture says of how the last question went.
    status: [160:0]u8 = @splat(0),
    /// The words last looked for, which a place not found is told by.
    asked: [fetch.words_max + 1:0]u8 = @splat(0),

    fn set(app: *App, object: *Object, tags: []const TagItem) void {
        _ = app.ib.SetGadgetAttrsTagList(object, app.window, tags.ptr);
    }

    // --- asking -------------------------------------------------------------

    /// The place the field names looked for, then its weather.
    fn search(app: *App) void {
        var at: usize = 0;
        _ = app.ib.GetAttr(gc.STRINGA_TextVal, app.field, &at);
        const words: [*:0]const u8 = if (at != 0) @ptrFromInt(at) else "";
        var length: usize = 0;
        while (words[length] != 0) length += 1;
        // Blanks either side are not part of it.
        var from: usize = 0;
        while (from < length and words[from] == ' ') from += 1;
        while (length > from and words[length - 1] == ' ') length -= 1;
        if (length == from) return;
        app.round = app.fetcher.find(words[from..length], app.settings.fahrenheit);
        app.asked = @splat(0);
        const kept = @min(length - from, fetch.words_max);
        @memcpy(app.asked[0..kept], words[from..][0..kept]);
        app.say(.MSG_FINDING, &app.asked);
    }

    /// The weather at `place` asked for.
    fn ask(app: *App, place: *const Place) void {
        app.round = app.fetcher.fetch(place, app.settings.fahrenheit);
        app.say(.MSG_FETCHING, &place.name);
    }

    /// The weather at the place shown asked for again, when there is one.
    fn refresh(app: *App) void {
        if (app.have) app.ask(&app.seen_place) else if (app.settings.shown.named()) app.ask(&app.settings.shown);
    }

    /// The answer kept from the last time, when it is the weather at the
    /// place shown last in the units asked for: what the window shows
    /// until the new one comes.
    fn showLast(app: *App) void {
        const jb = app.jb orelse return;
        if (!last.load(jb, app.dl, &app.settings.shown, app.settings.fahrenheit, &app.seen)) return;
        app.seen_place = app.settings.shown;
        app.have = true;
        app.showKept();
    }

    /// The status set to a text of one value, and shown.
    fn say(app: *App, comptime id: Id, value: [*:0]const u8) void {
        _ = app.text.format(&app.status, id, .{value});
        app.draw();
    }

    fn sayPlain(app: *App, id: Id) void {
        copyInto(&app.status, app.text.get(id));
        app.draw();
    }

    /// What the fetcher has come to.
    fn heard(app: *App) void {
        app.fetcher.news(&app.news);
        const news = &app.news;
        if (news.round != app.round or app.round == 0) return;
        switch (news.phase) {
            .idle, .finding => {},
            .fetching => {
                _ = app.text.format(&app.status, .MSG_FETCHING, .{@as([*:0]const u8, &news.place.name)});
                app.draw();
            },
            .done => {
                app.round = 0;
                app.seen = news.forecast;
                app.seen_place = news.place;
                app.have = true;
                if (app.jb) |jb| _ = last.save(jb, app.dl, &news.place, &news.forecast);
                var time: [8:0]u8 = @splat(0);
                clockText(&time, news.forecast.now.at);
                _ = app.text.format(&app.status, .MSG_UPDATED, .{@as([*:0]const u8, &time)});
                if (!app.settings.shown.same(&news.place) or !sameName(&app.settings.shown, &news.place)) {
                    app.settings.shown = news.place;
                    app.save();
                }
                app.showKept();
                app.draw();
            },
            .failed => {
                app.round = 0;
                if (news.why == .MSG_NOT_FOUND) {
                    _ = app.text.format(&app.status, .MSG_NOT_FOUND, .{@as([*:0]const u8, &app.asked)});
                } else {
                    copyInto(&app.status, app.text.get(news.why));
                }
                app.draw();
            },
        }
    }

    fn draw(app: *App) void {
        const shown_place: *const Place = if (app.have) &app.seen_place else &app.settings.shown;
        app.view.show(.{
            .forecast = if (app.have) &app.seen else null,
            .place = shown_place,
            .status = &app.status,
        });
    }

    // --- the places kept --------------------------------------------------

    /// The chooser's labels made again from the places kept, the place
    /// shown picked when it is one of them, and Remove only when there is
    /// something to remove.
    fn showKept(app: *App) void {
        const count = app.settings.count;
        app.labels = @splat(null);
        if (count == 0) {
            app.labels[0] = app.text.get(.MSG_NONE_KEPT);
        } else {
            for (app.settings.places[0..count], 0..) |*place, at| app.labels[at] = &place.name;
        }
        const active: u32 = if (app.have) app.settings.indexOf(&app.seen_place) orelse 0 else 0;
        app.set(app.kept, &.{
            .{ .tag = ch.CHOOSER_Labels, .data = @intFromPtr(&app.labels) },
            .{ .tag = ch.CHOOSER_Active, .data = active },
            .{ .tag = gc.GA_Disabled, .data = @intFromBool(count == 0) },
            .{},
        });
        app.set(app.remove, &.{ .{ .tag = gc.GA_Disabled, .data = @intFromBool(count == 0) }, .{} });
    }

    fn keep(app: *App) void {
        if (!app.have) return;
        if (!app.settings.keep(&app.seen_place)) return;
        app.save();
        app.showKept();
    }

    fn removeKept(app: *App) void {
        if (app.settings.count == 0) return;
        var active: usize = 0;
        _ = app.ib.GetAttr(ch.CHOOSER_Active, app.kept, &active);
        app.settings.remove(@intCast(active));
        app.save();
        app.showKept();
    }

    fn picked(app: *App, index: u32) void {
        if (index >= app.settings.count) return;
        const place = app.settings.places[index];
        // The field names the place shown, so that Return asks for it again.
        app.set(app.field, &.{ .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr(&place.name) }, .{} });
        app.ask(&place);
    }

    fn save(app: *App) void {
        const jb = app.jb orelse return;
        _ = places.save(jb, &app.settings);
    }

    // --- the menus ----------------------------------------------------------

    fn makeMenus(app: *App, screen: *intuition.Screen) void {
        var table: [menu_table.len + 1]mn.NewMenu = undefined;
        for (menu_table, 0..) |entry, at| {
            table[at] = entry.menu;
            if (entry.text) |id| table[at].label = app.text.get(id);
        }
        table[menu_table.len] = .{};
        table[if (app.settings.fahrenheit) fahrenheit_entry else celsius_entry].flags |= mn.CHECKED;
        const made = app.ib.CreateMenusA(&table, null) orelse return;
        if (!app.ib.LayoutMenusA(made, screen, null) or !app.ib.SetMenuStrip(app.window, made)) {
            app.ib.FreeMenus(made);
            return;
        }
        app.menu = made;
    }

    fn dropMenus(app: *App) void {
        const made = app.menu orelse return;
        app.ib.ClearMenuStrip(app.window);
        app.ib.FreeMenus(made);
        app.menu = null;
    }

    /// The items picked, one after another; false for Quit.
    fn chosen(app: *App, first: u32) bool {
        var number = first;
        while (number != mn.MENUNULL) {
            const item = app.ib.ItemAddress(app.menu, number) orelse break;
            switch (mn.MENUNUM(number)) {
                MENU_PROJECT => switch (mn.ITEMNUM(number)) {
                    ITEM_REFRESH => app.refresh(),
                    ITEM_ABOUT => app.about(),
                    ITEM_QUIT => return false,
                    else => {},
                },
                MENU_SETTINGS => switch (mn.ITEMNUM(number)) {
                    ITEM_CELSIUS => app.units(false),
                    ITEM_FAHRENHEIT => app.units(true),
                    else => {},
                },
                else => {},
            }
            number = item.next_select;
        }
        return true;
    }

    fn units(app: *App, fahrenheit: bool) void {
        if (app.settings.fahrenheit == fahrenheit) return;
        app.settings.fahrenheit = fahrenheit;
        app.save();
        app.refresh();
    }

    fn about(app: *App) void {
        const easy = intuition.EasyStruct{
            .title = app.text.get(.MSG_ABOUT_TITLE),
            .text_format = app.text.get(.MSG_ABOUT),
            .gadget_format = app.text.get(.MSG_OK),
        };
        comptime exec.checkFormat(strings.builtin(.MSG_ABOUT), @TypeOf(.{@as([*:0]const u8, ABOUT_VERSION)}));
        const stream = exec.fmtStream(.{@as([*:0]const u8, ABOUT_VERSION)});
        _ = app.ib.EasyRequestArgs(app.window, &easy, null, &stream);
    }
};

/// `words` without the quotes round them - the rest of a line comes as it
/// was typed - copied into `into` when there are some.
fn unquoted(words: [*:0]const u8, into: *[fetch.words_max + 1:0]u8) [*:0]const u8 {
    var length: usize = 0;
    while (words[length] != 0) length += 1;
    var from: usize = 0;
    while (from < length and words[from] == ' ') from += 1;
    while (length > from and words[length - 1] == ' ') length -= 1;
    if (length - from < 2 or words[from] != '"' or words[length - 1] != '"') return words;
    const kept = @min(length - from - 2, fetch.words_max);
    @memcpy(into[0..kept], words[from + 1 ..][0..kept]);
    into[kept] = 0;
    return into;
}

fn sameName(place: *const Place, other: *const Place) bool {
    var at: usize = 0;
    while (place.name[at] == other.name[at]) : (at += 1) {
        if (place.name[at] == 0) return true;
    }
    return false;
}

fn copyInto(into: []u8, text: [*:0]const u8) void {
    var at: usize = 0;
    while (at + 1 < into.len and text[at] != 0) : (at += 1) into[at] = text[at];
    into[at] = 0;
}

fn clockText(into: *[8:0]u8, at: forecast.Clock) void {
    const digits = "0123456789";
    into.* = @splat(0);
    into[0] = digits[at.hour / 10 % 10];
    into[1] = digits[at.hour % 10];
    into[2] = ':';
    into[3] = digits[at.minute / 10 % 10];
    into[4] = digits[at.minute % 10];
}

fn button(ib: *IntuitionBase, label: [*:0]const u8, id: usize) ?*Object {
    return ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr(label) },
        .{ .tag = gc.GA_ID, .data = id },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{},
    });
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);
    var text = Text.open(sys);
    defer text.close();

    var argv: [arg_count]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    // What the window needs; json.library and diskfont.library it does
    // without, keeping nothing and writing in the screen's font.
    var libraries: [8]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    const wanted = [_][*:0]const u8{
        intuition.INTUITIONNAME, graphics.GRAPHICSNAME, utility.UTILITYNAME, vector.VECTORNAME,
        motion.MOTIONNAME,       cv.CANVAS_LIBRARY,     st.STRING_LIBRARY,   ch.CHOOSER_LIBRARY,
    };
    for (wanted, 0..) |name, at| {
        libraries[at] = sys.OpenLibrary(name, 0) orelse {
            _ = text.printf(dl, .MSG_NOLIBRARY, .{ @as([*:0]const u8, COMMAND_NAME), name });
            return dos.RETURN_FAIL;
        };
    }
    const ib: *IntuitionBase = @ptrCast(libraries[0].?);
    const gb: *GraphicsBase = @ptrCast(libraries[1].?);
    const ub: *UtilityBase = @ptrCast(libraries[2].?);
    const vb: *VectorBase = @ptrCast(libraries[3].?);
    const motion_base: *MotionBase = @ptrCast(libraries[4].?);
    const json_lib = sys.OpenLibrary(json.JSONNAME, 1);
    defer if (json_lib) |lib| sys.CloseLibrary(lib);
    const diskfont_lib = sys.OpenLibrary(diskfont.DISKFONTNAME, 0);
    defer if (diskfont_lib) |lib| sys.CloseLibrary(lib);

    const screen = ib.LockPubScreen(null) orelse {
        _ = text.printf(dl, .MSG_NOWINDOW, .{@as([*:0]const u8, COMMAND_NAME)});
        return dos.RETURN_FAIL;
    };
    defer ib.UnlockPubScreen(null, screen);
    const draw_info = ib.GetScreenDrawInfo(screen);
    defer ib.FreeScreenDrawInfo(screen, draw_info);
    var screen_width: usize = 0;
    var screen_height: usize = 0;
    ib.GetScreenAttrs(screen, &[_]TagItem{
        .{ .tag = sc.SA_Width, .data = @intFromPtr(&screen_width) },
        .{ .tag = sc.SA_Height, .data = @intFromPtr(&screen_height) },
        .{},
    });
    // Room for the window's borders, its row of gadgets and the screen's
    // bar.
    const picture_width: usize = @min(start_width, @max(screen_width, 400) - 40);
    const picture_height: usize = @min(start_height, @max(screen_height, 300) - 120);

    // --- the window -------------------------------------------------------
    // The chooser's labels until the places kept are shown: kept as long
    // as it is.
    var first_labels = [_:null]?[*:0]const u8{text.get(.MSG_NONE_KEPT)};
    const field = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_FIELD },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{ .tag = gc.GA_TabCycle, .data = 1 },
        .{ .tag = gc.STRINGA_MaxChars, .data = fetch.words_max },
        .{},
    });
    const search = button(ib, text.get(.MSG_SEARCH), ID_SEARCH);
    const kept = ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_KEPT },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{ .tag = ch.CHOOSER_Labels, .data = @intFromPtr(&first_labels) },
        .{ .tag = ch.CHOOSER_MaxPanelLines, .data = 12 },
        .{},
    });
    const keep_button = button(ib, text.get(.MSG_KEEP), ID_KEEP);
    const remove_button = button(ib, text.get(.MSG_REMOVE), ID_REMOVE);
    const canvas = ib.NewObjectTagList(null, cv.CANVAS_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_CANVAS },
        .{ .tag = cv.CANVAS_Width, .data = picture_width },
        .{ .tag = cv.CANVAS_Height, .data = picture_height },
        .{},
    });
    const parts = [_]?*Object{ field, search, kept, keep_button, remove_button, canvas };
    for (parts) |part| {
        if (part == null) {
            for (parts) |made| if (made) |object| ib.DisposeObject(object);
            _ = text.printf(dl, .MSG_NOMEMORY, .{@as([*:0]const u8, COMMAND_NAME)});
            return dos.RETURN_FAIL;
        }
    }
    const row = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(field.?) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr(text.get(.MSG_PLACE)) },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(search.?) },
        .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(kept.?) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr(text.get(.MSG_KEPT)) },
        .{ .tag = lg.CHILDA_WeightWidth, .data = 60 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(keep_button.?) },
        .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(remove_button.?) },
        .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
        .{},
    }) orelse {
        for (parts) |made| if (made) |object| ib.DisposeObject(object);
        _ = text.printf(dl, .MSG_NOMEMORY, .{@as([*:0]const u8, COMMAND_NAME)});
        return dos.RETURN_FAIL;
    };
    const layout = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_VERT },
        .{ .tag = lg.LAYOUTA_Margin, .data = 6 },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(row) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(canvas.?) },
        .{},
    }) orelse {
        ib.DisposeObject(row);
        ib.DisposeObject(canvas);
        _ = text.printf(dl, .MSG_NOMEMORY, .{@as([*:0]const u8, COMMAND_NAME)});
        return dos.RETURN_FAIL;
    };
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr(text.get(.MSG_WINDOW_TITLE)) },
        .{ .tag = wn.WA_ScreenTitle, .data = @intFromPtr(SCREEN_TITLE) },
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_AutoAdjust, .data = 1 },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_NEWSIZE | wn.IDCMP_MENUPICK },
        .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(layout) },
        .{},
    }) orelse {
        ib.DisposeObject(layout);
        _ = text.printf(dl, .MSG_NOMEMORY, .{@as([*:0]const u8, COMMAND_NAME)});
        return dos.RETURN_FAIL;
    };
    defer ib.DisposeObject(object);

    // The program's state, the picture's and the fetcher.
    const memory = sys.AllocVec(@sizeOf(App) + @sizeOf(View), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        _ = text.printf(dl, .MSG_NOMEMORY, .{@as([*:0]const u8, COMMAND_NAME)});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const language: ?[]const u8 = if (text.locale) |loc| forecast.languageCode(loc.language_name) else null;
    const fetcher = Fetcher.start(sys, dl, ub, USER_AGENT, language) orelse {
        _ = text.printf(dl, .MSG_NOMEMORY, .{@as([*:0]const u8, COMMAND_NAME)});
        return dos.RETURN_FAIL;
    };
    defer fetcher.free();
    const path = vb.CreatePath() orelse {
        _ = text.printf(dl, .MSG_NOMEMORY, .{@as([*:0]const u8, COMMAND_NAME)});
        return dos.RETURN_FAIL;
    };

    var open = wc.WmOpen{};
    if (ib.SendMessage(object, @ptrCast(&open)) == 0) {
        vb.DisposePath(path);
        _ = text.printf(dl, .MSG_NOWINDOW, .{@as([*:0]const u8, COMMAND_NAME)});
        return dos.RETURN_FAIL;
    }
    var window_pointer: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_Window, object, &window_pointer);
    const window: *intuition.Window = @ptrFromInt(window_pointer);

    const bytes: [*]u8 = @ptrCast(memory);
    const view: *View = @ptrCast(@alignCast(bytes + @sizeOf(App)));
    view.* = .{
        .sys = sys,
        .gb = gb,
        .ib = ib,
        .vb = vb,
        .dfb = @ptrCast(diskfont_lib),
        .text = &text,
        .gadget = canvas.?,
        .window = window,
        .screen_font = draw_info.font,
        .path = path,
    };
    defer view.free();
    const app: *App = @ptrCast(@alignCast(memory));
    app.* = .{
        .sys = sys,
        .dl = dl,
        .ib = ib,
        .jb = @ptrCast(json_lib),
        .text = &text,
        .object = object,
        .window = window,
        .field = field.?,
        .kept = kept.?,
        .remove = remove_button.?,
        .view = view,
        .fetcher = fetcher,
    };
    // The settings kept, or the locale's units.
    const loaded = if (app.jb) |jb| places.load(jb, &app.settings) else false;
    if (!loaded) {
        if (text.locale) |loc| app.settings.fahrenheit = loc.measuring_system == locale.MS_AMERICAN;
    }
    app.makeMenus(screen);
    defer app.dropMenus();
    app.showKept();
    if (!view.fit()) {
        _ = text.printf(dl, .MSG_NOMEMORY, .{@as([*:0]const u8, COMMAND_NAME)});
        return dos.RETURN_FAIL;
    }

    // What is shown first: the place asked for, the one shown last - its
    // last answer while it is asked for again - or the words that say what
    // to do.
    if (rdargs.string(argv[arg_place])) |words| {
        var place_words: [fetch.words_max + 1:0]u8 = @splat(0);
        app.set(app.field, &.{ .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr(unquoted(words, &place_words)) }, .{} });
        app.search();
    } else if (app.settings.shown.named()) {
        app.showLast();
        app.ask(&app.settings.shown);
    } else {
        app.sayPlain(.MSG_WELCOME);
    }

    // The weather asked for again every quarter of an hour.
    const bit = sys.AllocSignal(-1);
    if (bit < 0) return dos.RETURN_FAIL;
    defer sys.FreeSignal(bit);
    const tick = motion_base.CreateTimerTagList(&[_]TagItem{
        .{ .tag = motion.TIMER_Period, .data = refresh_ms },
        .{ .tag = motion.TIMER_Repeat, .data = motion.TIMER_FOREVER },
        .{ .tag = motion.TIMER_Signal, .data = @intCast(bit) },
        .{},
    }) orelse return dos.RETURN_FAIL;
    defer motion_base.DeleteTimer(tick);
    motion_base.StartTimer(tick);
    const tick_mask = @as(u32, 1) << @intCast(bit);

    var code_word: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code_word };
    while (true) {
        var window_mask: usize = 0;
        _ = ib.GetAttr(wc.WINDOWA_SigMask, object, &window_mask);
        const got = sys.Wait(@as(u32, @intCast(window_mask)) | tick_mask | fetcher.signal() | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_OK;
        if (got & fetcher.signal() != 0) app.heard();
        if (got & tick_mask != 0 and app.round == 0) app.refresh();
        var sized = false;
        var sizing = false;
        while (true) {
            const word = ib.SendMessage(object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => return dos.RETURN_OK,
                wc.WMHI_NEWSIZE => {
                    sized = true;
                    // The steps of a sizing hold the button; its end not.
                    var qualifier: usize = 0;
                    _ = ib.GetAttr(wc.WINDOWA_Qualifier, object, &qualifier);
                    sizing = qualifier & ie.IEQUALIFIER_LEFTBUTTON != 0;
                },
                wc.WMHI_MENUPICK => {
                    const number: u32 = @truncate(word & wc.WMHI_MENUMASK);
                    if (number != mn.MENUNULL and !app.chosen(number)) return dos.RETURN_OK;
                },
                wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
                    ID_FIELD => if (entered(code_word)) app.search(),
                    ID_SEARCH => app.search(),
                    ID_KEPT => app.picked(code_word),
                    ID_KEEP => app.keep(),
                    ID_REMOVE => app.removeKept(),
                    else => {},
                },
                else => {},
            }
        }
        // A sizing's steps show the last picture stretched; the picture
        // is made again once, at the end.
        if (sized and sizing) {
            view.stretch();
        } else if (sized) {
            if (!view.fit()) return dos.RETURN_FAIL;
            app.draw();
        }
    }
}
