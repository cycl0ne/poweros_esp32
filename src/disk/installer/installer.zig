// SPDX-License-Identifier: MIT
//! Installer: the running system onto a disk of the machine, in a window
//! that asks one thing a page - the system started from a stick, say, put
//! on the SSD beside it. Built against the SDK only.
//!
//!   Installer
//!
//! **Language.** The languages and countries `LOCALE:` has files for, each
//! in its own words ("Français (Belgique)"). Next makes the one chosen the
//! running system's - `ENV:Sys/locale.prefs` written and `C:SetPrefs` run
//! - and the window is made again in it.
//!
//! **Keyboard.** The keymaps keymap.library knows and the files of
//! `DEVS:Keymaps`, the language's own chosen to start with. The one
//! chosen is the running system's at once, and the field under the list
//! is there to try it.
//!
//! **Disk.** Every unit of every block device with a medium in it, its
//! size and what it holds. The unit the running system is on is listed
//! and cannot be chosen, nor one too small for the board's layout - its
//! boot partitions and a container worth having. Look again lists them
//! once more, for a card or a stick put in since.
//!
//! **Ready** says what is about to happen; **Install** does it. The install
//! is C:Install's own (its parts are shared, `src/disk/c/install/parts.zig`),
//! with its defaults - the running system as the source, a GPT with the
//! firmware's partitions, `DH0:` "System" and `DH1:` "Work" in a
//! container - run on a process of its own (`worker.zig`) while the gauge
//! fills by the bytes written. The language, the country and the keymap
//! chosen go into the new system's `ENVARC:Sys/locale.prefs`, so it starts
//! as this one was left. **Stop** ends it between two files, with a disk
//! that holds no system that starts.
//!
//! **Done** says what was written, and **Restart** starts the machine again
//! through `C:Reboot`: without the stick, it starts from the disk.
//!
//! The window's words come from `Installer.catalog` in the language
//! chosen; what C:Install says of a reason it stopped is its own, in
//! English.

const sdk = @import("sdk");
const strings = @import("strings");
const install = @import("install");
const worker = @import("worker.zig");
const dos = sdk.dos;
const exec = sdk.exec;
const prefs = sdk.prefs;
const intuition = sdk.intuition;
const graphics = sdk.graphics;
const keymap = sdk.keymap;
const rdb = sdk.rdb;
const devices = sdk.expansion.devices;
const shared = install.shared;
const Job = worker.Job;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const RDBBase = sdk.interface.rdb.RDBBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const KeymapBase = sdk.interface.keymap.KeymapBase;
const TagItem = sdk.utility.TagItem;
const Object = intuition.Object;
const Printf = dos.stdio.Printf;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wn = intuition.windows;
const wc = intuition.windowclass;
const classusr = intuition.classusr;
const lb = sdk.gadgets.listbrowser;
const tx = sdk.gadgets.text;
const fg = sdk.gadgets.fuelgauge;
const st = sdk.gadgets.string;
const pg = sdk.gadgets.page;
const locale_file = prefs.locale;
const Text = sdk.locale.Strings(strings);
const Id = strings.Id;

pub const COMMAND_NAME = "Installer";
const VERSION = "1.0";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (18.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
const SCREEN_TITLE = COMMAND_NAME ++ " " ++ VERSION;

/// rdb.library makes a boot partition of a GPT from 1.7 on, as C:Install
/// asks.
const rdb_version = 1;
const fat_revision = 7;

/// The pages, in order.
const Page = enum(u32) { language, keyboard, target, confirm, progress, done };
const page_count = @typeInfo(Page).@"enum".fields.len;

/// The gadgets.
const ID_LANGUAGE_LIST = 1;
const ID_LANGUAGE_NEXT = 2;
const ID_KEYMAP_LIST = 3;
const ID_KEYMAP_BACK = 4;
const ID_KEYMAP_NEXT = 5;
const ID_TRY = 6;
const ID_TARGET_LIST = 7;
const ID_TARGET_AGAIN = 8;
const ID_TARGET_BACK = 9;
const ID_TARGET_NEXT = 10;
const ID_CONFIRM_BACK = 11;
const ID_INSTALL = 12;
const ID_STOP = 13;
const ID_DONE_BACK = 14;
const ID_RESTART = 15;

/// How many rows a list shows without the window being made taller.
const rows_shown = 10;
/// How wide a page's text is made, which its lines are broken to.
const text_width = 560;

/// The gauge counts KiB, which a whole system's worth fits in.
const gauge_unit = 1024;
const gauge_most: u64 = 0x7FFF_FFFF;

/// One language and country to choose: how it calls itself, the language
/// file it needs (none for English, which is built in), the languages
/// locale.prefs names - the preferred first, none for the country's own -
/// the country, and the keymap its keyboards have.
const Choice = struct {
    label: [*:0]const u8,
    language: []const u8,
    languages: []const []const u8,
    country: []const u8,
    keymap: []const u8,
};

fn choice(label: [*:0]const u8, language: []const u8, country: []const u8, keymap_name: []const u8) Choice {
    return .{ .label = label, .language = language, .languages = &.{language}, .country = country, .keymap = keymap_name };
}

fn english(label: [*:0]const u8, country: []const u8, keymap_name: []const u8) Choice {
    return .{ .label = label, .language = "", .languages = &.{}, .country = country, .keymap = keymap_name };
}

const choices = [_]Choice{
    english("English (United States)", "united_states", "usa"),
    english("English (United Kingdom)", "great_britain", "gb"),
    english("English (Ireland)", "eire", "ie"),
    english("English (Australia)", "australia", "usa"),
    english("English (Canada)", "canada", "usa"),
    choice("Gaeilge (Éire)", "gaeilge", "eire", "ie"),
    choice("Deutsch (Deutschland)", "deutsch", "deutschland", "deutsch"),
    choice("Deutsch (Österreich)", "deutsch", "osterreich", "deutsch"),
    choice("Deutsch (Schweiz)", "deutsch", "schweiz", "ch-de"),
    choice("Français (France)", "francais", "france", "fr"),
    choice("Français (Belgique)", "francais", "belgique", "be"),
    choice("Français (Suisse)", "francais", "suisse", "ch-fr"),
    choice("Français (Luxembourg)", "francais", "luxembourg", "ch-fr"),
    choice("Français (Canada)", "francais", "canada_francais", "usa"),
    choice("Nederlands (Nederland)", "nederlands", "nederland", "nl"),
    choice("Nederlands (België)", "nederlands", "belgie", "be"),
    choice("Italiano (Italia)", "italiano", "italia", "it"),
    choice("Italiano (Svizzera)", "italiano", "svizzera", "ch-de"),
    choice("Español (España)", "espanol", "espana", "es"),
    choice("Português (Portugal)", "portugues", "portugal", "pt"),
    choice("Dansk (Danmark)", "dansk", "danmark", "dk"),
    choice("Svenska (Sverige)", "svenska", "sverige", "se"),
    choice("Norsk (Norge)", "norsk", "norge", "no"),
    choice("Suomi (Suomi)", "suomi", "suomi", "fi"),
    choice("Íslenska (Ísland)", "islenska", "island", "is"),
    choice("Eesti (Eesti)", "eesti", "eesti", "ee"),
    choice("Latviešu (Latvija)", "latviesu", "latvija", "lv"),
    choice("Lietuvių (Lietuva)", "lietuviu", "lietuva", "lt"),
    choice("Polski (Polska)", "polski", "polska", "pl"),
    choice("Čeština (Česko)", "cestina", "cesko", "cz"),
    choice("Slovenčina (Slovensko)", "slovencina", "slovensko", "sk"),
    choice("Slovenščina (Slovenija)", "slovenscina", "slovenija", "si"),
    choice("Hrvatski (Hrvatska)", "hrvatski", "hrvatska", "hr"),
    choice("Magyar (Magyarország)", "magyar", "magyarorszag", "hu"),
    choice("Română (România)", "romana", "romania", "ro"),
    choice("Malti (Malta)", "malti", "malta", "mt"),
    choice("Türkçe (Türkiye)", "turkce", "turkiye", "tr"),
    choice("Ελληνικά (Ελλάδα)", "ellinika", "ellada", "gr"),
    choice("Ελληνικά (Κύπρος)", "ellinika", "kypros", "gr"),
    choice("Български (България)", "bulgarski", "bulgaria", "bg"),
    choice("Русский (Россия)", "russkij", "rossija", "ru"),
    choice("Українська (Україна)", "ukrainska", "ukrajina", "ua"),
    choice("हिन्दी (भारत)", "hindi", "india", "inscript"),
    choice("日本語 (日本)", "nihongo", "nihon", "usa"),
    choice("한국어 (대한민국)", "hangugeo", "hanguk", "usa"),
    choice("中文 (中国)", "zhongwen", "zhongguo", "usa"),
    .{ .label = "中文 (台灣)", .language = "zhongwen-fanti", .languages = &.{ "zhongwen-fanti", "zhongwen" }, .country = "taiwan", .keymap = "usa" },
};

/// What a keymap is for, in the words of those who type on it.
const keymap_labels = [_]struct { name: []const u8, label: [*:0]const u8 }{
    .{ .name = "usa", .label = "English (USA)" },
    .{ .name = "deutsch", .label = "Deutsch" },
    .{ .name = "gb", .label = "English (UK)" },
    .{ .name = "ie", .label = "Gaeilge / English (Éire)" },
    .{ .name = "fr", .label = "Français (France)" },
    .{ .name = "be", .label = "Belgique / België" },
    .{ .name = "ch-de", .label = "Deutsch (Schweiz)" },
    .{ .name = "ch-fr", .label = "Français (Suisse)" },
    .{ .name = "es", .label = "Español" },
    .{ .name = "pt", .label = "Português" },
    .{ .name = "it", .label = "Italiano" },
    .{ .name = "nl", .label = "Nederlands (US-International)" },
    .{ .name = "dk", .label = "Dansk" },
    .{ .name = "no", .label = "Norsk" },
    .{ .name = "se", .label = "Svenska" },
    .{ .name = "fi", .label = "Suomi" },
    .{ .name = "is", .label = "Íslenska" },
    .{ .name = "pl", .label = "Polski" },
    .{ .name = "cz", .label = "Čeština" },
    .{ .name = "sk", .label = "Slovenčina" },
    .{ .name = "hu", .label = "Magyar" },
    .{ .name = "si", .label = "Slovenščina" },
    .{ .name = "hr", .label = "Hrvatski" },
    .{ .name = "ro", .label = "Română" },
    .{ .name = "ee", .label = "Eesti" },
    .{ .name = "lv", .label = "Latviešu" },
    .{ .name = "lt", .label = "Lietuvių" },
    .{ .name = "mt", .label = "Malti" },
    .{ .name = "tr", .label = "Türkçe" },
    .{ .name = "gr", .label = "Ελληνικά" },
    .{ .name = "bg", .label = "Български" },
    .{ .name = "ru", .label = "Русский" },
    .{ .name = "ua", .label = "Українська" },
    .{ .name = "rs", .label = "Српски" },
    .{ .name = "mk", .label = "Македонски" },
    .{ .name = "inscript", .label = "हिन्दी (InScript)" },
};

/// The most keymaps and disks listed.
const max_keymaps = 64;
const max_targets = 32;

/// A disk an install could go onto.
const Target = struct {
    device: [worker.device_max:0]u8 = @splat(0),
    unit: u32 = 0,
    bytes: u64 = 0,
    state: State = .fits,

    const State = enum { fits, small, running, unreadable };
};

fn pair(tag: sdk.utility.Tag, data: usize) TagItem {
    return .{ .tag = tag, .data = data };
}

/// A line a text gadget shows, which it points at rather than copies: it
/// stays where it is and is only ever written over.
const Line = struct {
    text: [worker.line_max:0]u8 = @splat(0),
    length: usize = 0,
    /// It says something else than its gadget was last told.
    changed: bool = false,

    fn ptr(line: *const Line) [*:0]const u8 {
        return @ptrCast(&line.text);
    }

    /// The line set to the string `id` with `args`.
    fn put(line: *Line, text: *const Text, comptime id: Id, args: anytype) void {
        var next: Line = .{};
        next.length = text.format(&next.text, id, args).len;
        line.take(&next);
    }

    /// The line set to `from`.
    fn plain(line: *Line, from: [*:0]const u8) void {
        var next: Line = .{};
        worker.copyText(&next.text, from);
        next.length = shared.length(next.ptr());
        line.take(&next);
    }

    /// The line made to say what `next` says.
    fn take(line: *Line, next: *const Line) void {
        if (line.length == next.length and std_eql(line.text[0..line.length], next.text[0..next.length])) return;
        line.text = next.text;
        line.length = next.length;
        line.changed = true;
    }
};

fn std_eql(one: []const u8, other: []const u8) bool {
    if (one.len != other.len) return false;
    for (one, other) |a, b| {
        if (a != b) return false;
    }
    return true;
}

/// A NUL-ended name as a slice.
fn span(text: [*:0]const u8) []const u8 {
    return text[0..shared.length(text)];
}

const App = struct {
    sys: *ExecBase,
    dl: *DosBase,
    ib: *IntuitionBase,
    gb: *GraphicsBase,
    ub: *UtilityBase,
    rb: *RDBBase,
    eb: *ExpansionBase,
    text: Text,

    object: ?*Object = null,
    window: ?*intuition.Window = null,
    book: ?*Object = null,
    pages: [page_count:null]?*Object = @splat(null),
    page: Page = .language,

    language_list: ?*Object = null,
    language_next: ?*Object = null,
    keymap_list: ?*Object = null,
    keymap_next: ?*Object = null,
    target_list: ?*Object = null,
    target_line: ?*Object = null,
    target_next: ?*Object = null,
    confirm_lines: [4]?*Object = @splat(null),
    phase_line: ?*Object = null,
    detail_line: ?*Object = null,
    gauge: ?*Object = null,
    stop_button: ?*Object = null,
    done_lines: [2]?*Object = @splat(null),
    done_back: ?*Object = null,
    restart_button: ?*Object = null,

    language_columns: [2]lb.Column = @splat(.{}),
    keymap_columns: [3]lb.Column = @splat(.{}),
    target_columns: [5]lb.Column = @splat(.{}),
    language_rows: exec.List = .{},
    keymap_rows: exec.List = .{},
    target_rows: exec.List = .{},

    /// The choice the language list has, and the one the running system
    /// was last given (none: not this program's).
    chosen: usize = 0,
    applied: ?usize = null,
    /// The keymaps listed, the one chosen, and whether it was chosen on
    /// the page rather than for the language.
    keymap_names: [max_keymaps][locale_file.name_len:0]u8 = @splat(@splat(0)),
    keymap_count: usize = 0,
    keymap_chosen: ?usize = null,
    keymap_picked: bool = false,
    /// The disks listed, and the one chosen.
    targets: [max_targets]Target = @splat(.{}),
    target_count: usize = 0,
    target_chosen: ?usize = null,
    /// How many boot partitions this board starts from.
    slots: u32 = 1,

    target_text: Line = .{},
    confirm_texts: [4]Line = @splat(.{}),
    phase_text: Line = .{},
    detail_text: Line = .{},
    done_texts: [2]Line = @splat(.{}),

    /// The install on its process, and what it said last.
    job: Job = undefined,
    phase: worker.Phase = .looking,
    heard_line: [worker.line_max:0]u8 = @splat(0),
    heard_failure: bool = false,
    wrote_bytes: u64 = 0,
    wrote_files: u32 = 0,
    stop_asked: bool = false,
    /// What the gauge goes up to, and what it was last told.
    to_write: u64 = 0,
    gauge_max: u64 = 0,
    gauge_level: u64 = 0,

    // --- the gadgets ---------------------------------------------------------------

    /// `tags` set on a gadget of `page`: drawn at once on the page shown,
    /// and as the page is turned to on another.
    fn set(app: *App, page: Page, object: ?*Object, tags: []const TagItem) void {
        const window = if (page == app.page) app.window else null;
        _ = app.ib.SetGadgetAttrsTagList(object orelse return, window, tags.ptr);
    }

    /// A gadget made usable or not, told only where that changes it.
    fn enable(app: *App, page: Page, object: ?*Object, on: bool) void {
        const gadget = object orelse return;
        const off = gc.gadget(gadget).flags & gc.GFLG_DISABLED != 0;
        if (off != on) return;
        app.set(page, gadget, &.{ pair(gc.GA_Disabled, @intFromBool(!on)), .{} });
    }

    fn showLine(app: *App, page: Page, object: ?*Object, line: *Line) void {
        if (!line.changed) return;
        line.changed = false;
        app.set(page, object, &.{ pair(tx.TEXT_Text, @intFromPtr(line.ptr())), .{} });
    }

    /// The page shown.
    fn turn(app: *App, page: Page) void {
        app.page = page;
        _ = app.ib.SetGadgetAttrsTagList(app.book orelse return, app.window, &[_]TagItem{ pair(pg.PAGE_Current, @intFromEnum(page)), .{} });
    }

    /// A list's rows taken away from it and given back, so that what it
    /// shows next is drawn once.
    fn detach(app: *App, list: ?*Object) void {
        _ = app.ib.SetGadgetAttrsTagList(list orelse return, null, &[_]TagItem{ pair(lb.LISTBROWSER_Rows, lb.LISTBROWSER_DETACH), .{} });
    }

    fn attach(app: *App, page: Page, list: ?*Object, rows: *exec.List, place: ?usize) void {
        app.set(page, list, &.{
            pair(lb.LISTBROWSER_Rows, @intFromPtr(rows)),
            pair(lb.LISTBROWSER_Selected, if (place) |at| at else lb.LISTBROWSER_NONE),
            .{},
        });
    }

    /// The place of the row a list has selected, if any.
    fn selected(app: *App, list: ?*Object) ?usize {
        var value: usize = lb.LISTBROWSER_NONE;
        _ = app.ib.GetAttr(lb.LISTBROWSER_Selected, list orelse return null, &value);
        if (value == lb.LISTBROWSER_NONE) return null;
        return value;
    }

    // --- the language ---------------------------------------------------------------

    /// Whether `one`'s files are on this system: its country's, and its
    /// language's unless that is English.
    fn there(app: *App, one: *const Choice) bool {
        var path: [80:0]u8 = @splat(0);
        if (!app.exists(&path, &.{ "LOCALE:Countries/", one.country, ".country" })) return false;
        if (one.language.len == 0) return true;
        return app.exists(&path, &.{ "LOCALE:Languages/", one.language, ".language" });
    }

    fn exists(app: *App, path: *[80:0]u8, pieces: []const []const u8) bool {
        path.* = @splat(0);
        var at: usize = 0;
        for (pieces) |piece| at += shared.copy(path[at..], piece);
        const lock = app.dl.Lock(@ptrCast(path), dos.SHARED_LOCK) orelse return false;
        app.dl.UnLock(lock);
        return true;
    }

    /// The language list's rows: each choice whose files are here, its
    /// place in `choices` kept with it.
    fn makeLanguageRows(app: *App) void {
        lb.freeRows(app.sys, &app.language_rows);
        for (&choices, 0..) |*one, index| {
            if (!app.there(one)) continue;
            const row = lb.allocRow(app.sys, &.{one.label}, 0) orelse return;
            row.user_data = index;
            app.sys.AddTail(&app.language_rows, &row.node);
        }
    }

    /// The place of the row whose choice is `index`.
    fn placeOf(list: *exec.List, index: usize) ?usize {
        var place: usize = 0;
        var node = list.first();
        while (node) |it| : (node = it.next()) {
            const row: *lb.Row = @fieldParentPtr("node", it);
            if (row.user_data == index) return place;
            place += 1;
        }
        return null;
    }

    /// The row at `place`'s own number.
    fn dataAt(list: *exec.List, place: usize) ?usize {
        var at: usize = 0;
        var node = list.first();
        while (node) |it| : (node = it.next()) {
            if (at == place) {
                const row: *lb.Row = @fieldParentPtr("node", it);
                return row.user_data;
            }
            at += 1;
        }
        return null;
    }

    /// The choice that matches the settings the system has: its country,
    /// and its first language or none.
    fn matching(settings: *const locale_file.Settings) ?usize {
        const country = settings.countryName();
        if (country.len == 0) return null;
        const first: []const u8 = if (settings.language_count != 0) settings.language(0) else "";
        for (&choices, 0..) |*one, index| {
            if (!std_eql(one.country, country)) continue;
            const wanted: []const u8 = if (one.languages.len != 0) one.languages[0] else "";
            if (std_eql(wanted, first)) return index;
        }
        return null;
    }

    /// The language a press on the list chose; the keymap goes with it
    /// until one is chosen on its own page.
    fn chooseLanguage(app: *App, place: usize) void {
        const index = dataAt(&app.language_rows, place) orelse return;
        app.chosen = index;
        if (!app.keymap_picked) {
            if (app.keymapIndex(choices[index].keymap)) |at| app.keymap_chosen = at;
        }
    }

    /// The settings chosen, as `Sys/locale.prefs` holds them; its length.
    fn settingsText(app: *const App, into: []u8) usize {
        var settings: locale_file.Settings = .{};
        const one = &choices[app.chosen];
        _ = settings.setCountry(one.country);
        for (one.languages) |name| _ = settings.addLanguage(name);
        if (app.keymap_chosen) |at| _ = settings.setKeymap(span(@ptrCast(&app.keymap_names[at])));
        var length = locale_file.header.len;
        @memcpy(into[0..length], locale_file.header);
        length += locale_file.write(&settings, into[length..]);
        into[length] = '\n';
        return length + 1;
    }

    /// The settings chosen made the running system's: `ENV:` written and
    /// C:SetPrefs run, as Prefs does.
    fn apply(app: *App) void {
        var text: [worker.settings_max]u8 = undefined;
        const length = app.settingsText(&text);
        _ = prefs.save(app.dl, locale_file.ENV_FILE, text[0..length]);
        _ = app.dl.SystemTagList("C:SetPrefs >NIL:", null);
    }

    // --- the keymaps -----------------------------------------------------------------

    fn keymapIndex(app: *const App, name: []const u8) ?usize {
        for (app.keymap_names[0..app.keymap_count], 0..) |*have, index| {
            if (std_eql(span(@ptrCast(have)), name)) return index;
        }
        return null;
    }

    fn addKeymap(app: *App, name: []const u8) void {
        if (name.len == 0 or name.len > locale_file.name_len or app.keymap_count == max_keymaps) return;
        if (app.keymapIndex(name) != null) return;
        const into = &app.keymap_names[app.keymap_count];
        into.* = @splat(0);
        @memcpy(into[0..name.len], name);
        app.keymap_count += 1;
    }

    /// The keymaps there are: keymap.library's and the files of
    /// DEVS:Keymaps, sorted by name.
    fn readKeymaps(app: *App) void {
        if (app.sys.OpenLibrary(keymap.KEYMAPNAME, keymap.KEYMAP_VERSION)) |library| {
            defer app.sys.CloseLibrary(library);
            const kb: *KeymapBase = @ptrCast(library);
            var map = kb.NextKeyMap(null);
            while (map) |one| : (map = kb.NextKeyMap(one)) {
                if (kb.KeyMapName(one)) |name| app.addKeymap(span(name));
            }
        }
        const dl = app.dl;
        if (dl.Lock(keymap.KEYMAP_DRAWER, dos.SHARED_LOCK)) |lock| {
            defer dl.UnLock(lock);
            var fib: dos.FileInfoBlock = .{};
            if (dl.Examine(lock, &fib)) {
                while (dl.ExNext(lock, &fib)) {
                    if (dos.isDirectory(fib.dir_entry_type)) continue;
                    const name = span(@ptrCast(&fib.file_name));
                    if (name.len > 5 and std_eql(name[name.len - 5 ..], ".info")) continue;
                    app.addKeymap(name);
                }
            }
        }
        const all = app.keymap_names[0..app.keymap_count];
        var i: usize = 1;
        while (i < all.len) : (i += 1) {
            var j = i;
            while (j > 0 and before(&all[j], &all[j - 1])) : (j -= 1) {
                const swap = all[j];
                all[j] = all[j - 1];
                all[j - 1] = swap;
            }
        }
    }

    fn before(one: *const [locale_file.name_len:0]u8, other: *const [locale_file.name_len:0]u8) bool {
        for (one, other) |a, b| {
            if (a != b) return a < b;
        }
        return false;
    }

    fn makeKeymapRows(app: *App) void {
        lb.freeRows(app.sys, &app.keymap_rows);
        for (app.keymap_names[0..app.keymap_count], 0..) |*name, index| {
            const text: [*:0]const u8 = @ptrCast(name);
            const row = lb.allocRow(app.sys, &.{ text, labelOf(span(text)) }, 0) orelse return;
            row.user_data = index;
            app.sys.AddTail(&app.keymap_rows, &row.node);
        }
    }

    /// What a keymap is for, empty where the table does not say.
    fn labelOf(name: []const u8) [*:0]const u8 {
        for (keymap_labels) |one| {
            if (std_eql(one.name, name)) return one.label;
        }
        return "";
    }

    /// The keymap a press on the list chose, the running system's at once.
    fn chooseKeymap(app: *App, place: usize) void {
        const index = dataAt(&app.keymap_rows, place) orelse return;
        app.keymap_chosen = index;
        app.keymap_picked = true;
        app.apply();
    }

    // --- the disks -------------------------------------------------------------------

    /// A run that only asks: which unit the running system is on, the
    /// board's facts.
    fn probe(app: *App) shared.Run {
        return .{ .sys = app.sys, .dl = app.dl, .rb = app.rb, .eb = app.eb, .ub = app.ub };
    }

    /// Every unit of every block device with a medium in it, listed with
    /// what it holds.
    fn lookAtTargets(app: *App) void {
        app.detach(app.target_list);
        lb.freeRows(app.sys, &app.target_rows);
        app.target_count = 0;
        app.target_chosen = null;
        var run = app.probe();
        if (app.eb.ObtainDeviceUnits(devices.DEVIF_BLOCK, null)) |units| {
            defer app.eb.ReleaseDeviceUnits(units);
            var walk = units.iterator();
            while (walk.next()) |node| {
                if (app.target_count == max_targets) break;
                const unit: *const devices.DeviceUnit = @ptrCast(@alignCast(node));
                const name = unit.node.name orelse continue;
                app.lookAt(&run, name, unit.unit);
            }
        }
        app.attach(.target, app.target_list, &app.target_rows, null);
        app.sayTarget();
    }

    /// One unit: listed unless it has no medium in it.
    fn lookAt(app: *App, run: *shared.Run, name: [*:0]const u8, unit: u32) void {
        var err: i32 = rdb.RDBERR_OK;
        const target = &app.targets[app.target_count];
        target.* = .{ .unit = unit };
        worker.copyText(&target.device, name);
        var holds: [*:0]const u8 = app.text.get(.MSG_HOLDS_UNREADABLE);
        if (app.rb.OpenRDB(name, unit, &err)) |handle| {
            defer app.rb.CloseRDB(handle);
            target.bytes = handle.disk_blocks * handle.geometry.sector_size;
            holds = app.text.get(if (handle.flags & rdb.RDBF_GPT != 0)
                (if (handle.flags & rdb.RDBF_CONTAINER != 0) Id.MSG_HOLDS_CONTAINER else Id.MSG_HOLDS_GPT)
            else if (handle.flags & rdb.RDBF_FOREIGN != 0)
                Id.MSG_HOLDS_FOREIGN
            else if (handle.flags & rdb.RDBF_FOUND != 0)
                Id.MSG_HOLDS_TABLE
            else
                Id.MSG_HOLDS_NOTHING);
            target.state = if (target.bytes < worker.leastBytes(app.slots)) .small else .fits;
        } else {
            if (err == rdb.RDBERR_DEVICE) return;
            target.state = .unreadable;
        }
        var running: [worker.line_max:0]u8 = @splat(0);
        if (install.units.onIt(run, name, unit)) {
            target.state = .running;
            holds = app.text.format(&running, .MSG_HOLDS_RUNNING, .{holds}).ptr;
        }
        var number: [12:0]u8 = @splat(0);
        number[shared.decimal(&number, unit)] = 0;
        var size: [16:0]u8 = @splat(0);
        if (target.bytes != 0) shared.bytesAsText(&size, target.bytes) else size[0] = '-';
        const row = lb.allocRow(app.sys, &.{ name, @ptrCast(&number), @ptrCast(&size), holds }, 0) orelse return;
        row.user_data = app.target_count;
        app.sys.AddTail(&app.target_rows, &row.node);
        app.target_count += 1;
    }

    /// The line under the disks: what the one chosen is, or why none can
    /// be; Next only for one that fits.
    fn sayTarget(app: *App) void {
        const line = &app.target_text;
        var fits = false;
        if (app.target_count == 0) {
            line.put(&app.text, .MSG_TARGET_NONE, .{});
        } else if (app.target_chosen) |index| {
            const target = &app.targets[index];
            var size: [16:0]u8 = @splat(0);
            shared.bytesAsText(&size, target.bytes);
            switch (target.state) {
                .running => line.put(&app.text, .MSG_TARGET_RUNNING, .{}),
                .unreadable => line.put(&app.text, .MSG_TARGET_UNREADABLE, .{}),
                .small => {
                    var least: [16:0]u8 = @splat(0);
                    shared.bytesAsText(&least, worker.leastBytes(app.slots));
                    line.put(&app.text, .MSG_TARGET_SMALL, .{ @as([*:0]const u8, @ptrCast(&size)), @as([*:0]const u8, @ptrCast(&least)) });
                },
                .fits => {
                    fits = true;
                    line.put(&app.text, .MSG_TARGET_FITS, .{ @as([*:0]const u8, @ptrCast(&size)), @as([*:0]const u8, @ptrCast(&target.device)), target.unit });
                },
            }
        } else {
            line.put(&app.text, .MSG_TARGET_CHOOSE, .{});
        }
        app.showLine(.target, app.target_line, line);
        app.enable(.target, app.target_next, fits);
    }

    fn chooseTarget(app: *App, place: usize) void {
        app.target_chosen = dataAt(&app.target_rows, place);
        app.sayTarget();
    }

    fn targetFits(app: *const App) bool {
        const index = app.target_chosen orelse return false;
        return app.targets[index].state == .fits;
    }

    // --- the last look -------------------------------------------------------------

    fn sayConfirm(app: *App) void {
        const target = &app.targets[app.target_chosen orelse return];
        var size: [16:0]u8 = @splat(0);
        shared.bytesAsText(&size, target.bytes);
        app.confirm_texts[0].put(&app.text, .MSG_CONFIRM_DISK, .{ @as([*:0]const u8, @ptrCast(&target.device)), target.unit, @as([*:0]const u8, @ptrCast(&size)) });
        app.confirm_texts[1].put(&app.text, .MSG_CONFIRM_LANGUAGE, .{choices[app.chosen].label});
        var keys: [worker.line_max:0]u8 = @splat(0);
        if (app.keymap_chosen) |at| {
            const name: [*:0]const u8 = @ptrCast(&app.keymap_names[at]);
            var length = shared.copy(&keys, span(name));
            const label = labelOf(span(name));
            if (label[0] != 0) {
                length += shared.copy(keys[length..], " - ");
                length += shared.copy(keys[length..], span(label));
            }
        }
        app.confirm_texts[2].put(&app.text, .MSG_CONFIRM_KEYMAP, .{@as([*:0]const u8, @ptrCast(&keys))});
        app.confirm_texts[3].put(&app.text, .MSG_CONFIRM_LOST, .{});
        for (&app.confirm_texts, app.confirm_lines) |*line, object| app.showLine(.confirm, object, line);
    }

    // --- the install -----------------------------------------------------------------

    /// The install started on the disk chosen, the page turned to it.
    fn begin(app: *App) void {
        if (app.job.running() or !app.targetFits()) return;
        const target = &app.targets[app.target_chosen.?];
        const job = &app.job;
        worker.copyText(&job.device, @ptrCast(&target.device));
        job.unit = target.unit;
        job.settings_length = app.settingsText(&job.settings);
        app.stop_asked = false;
        app.phase = .looking;
        app.heard_line = @splat(0);
        app.heard_failure = false;
        app.wrote_bytes = 0;
        app.wrote_files = 0;
        app.to_write = app.systemBytes();
        app.showGauge(0);
        app.phase_text.put(&app.text, .MSG_PHASE_LOOKING, .{});
        app.detail_text.plain("");
        app.turn(.progress);
        if (!job.start()) {
            app.phase_text.put(&app.text, .MSG_NO_PROCESS, .{});
            app.showProgress();
            return;
        }
        app.enable(.progress, app.stop_button, true);
        app.showProgress();
    }

    /// How many bytes the running system's volume holds: what the gauge
    /// goes up to.
    fn systemBytes(app: *App) u64 {
        const lock = app.dl.Lock("SYS:", dos.SHARED_LOCK) orelse return 0;
        defer app.dl.UnLock(lock);
        var data: dos.InfoData = .{};
        if (!app.dl.Info(lock, &data)) return 0;
        return data.num_blocks_used * data.bytes_per_block;
    }

    fn showGauge(app: *App, level: u64) void {
        const most = app.to_write;
        const top: u64 = @max(1, (most + gauge_unit - 1) / gauge_unit);
        const max: u64 = @min(top, gauge_most);
        const done: u64 = if (most != 0 and level >= most) max else @min(level / gauge_unit, max);
        if (max == app.gauge_max and done == app.gauge_level) return;
        app.gauge_max = max;
        app.gauge_level = done;
        app.set(.progress, app.gauge, &.{
            pair(fg.GAUGE_Max, @intCast(max)),
            pair(fg.GAUGE_Level, @intCast(done)),
            .{},
        });
    }

    fn showProgress(app: *App) void {
        app.showLine(.progress, app.phase_line, &app.phase_text);
        app.showLine(.progress, app.detail_line, &app.detail_text);
    }

    /// What the install has said since the last look: where it is on the
    /// first line, the files or its last word on the second, the gauge.
    fn heard(app: *App) void {
        app.job.take(&app.phase, &app.heard_line, &app.heard_failure, &app.wrote_bytes, &app.wrote_files);
        if (app.stop_asked) {
            app.phase_text.put(&app.text, .MSG_STOPPING, .{});
        } else switch (app.phase) {
            .looking => app.phase_text.put(&app.text, .MSG_PHASE_LOOKING, .{}),
            .preparing => app.phase_text.put(&app.text, .MSG_PHASE_PREPARING, .{}),
            .copying => app.phase_text.put(&app.text, .MSG_PHASE_COPYING, .{}),
            .settings => app.phase_text.put(&app.text, .MSG_PHASE_SETTINGS, .{}),
        }
        if (app.phase == .copying or app.phase == .settings) {
            var size: [16:0]u8 = @splat(0);
            shared.bytesAsText(&size, app.wrote_bytes);
            app.detail_text.put(&app.text, .MSG_COPIED, .{ app.wrote_files, @as([*:0]const u8, @ptrCast(&size)) });
        } else {
            app.detail_text.plain(@ptrCast(&app.heard_line));
        }
        app.showProgress();
        app.showGauge(app.wrote_bytes);
    }

    /// The install has ended: what it came to on the last page.
    fn ended(app: *App) void {
        app.heard();
        const code = app.job.code;
        var size: [16:0]u8 = @splat(0);
        shared.bytesAsText(&size, app.wrote_bytes);
        const ok = code == dos.RETURN_OK;
        if (ok) {
            app.showGauge(app.to_write);
            app.done_texts[0].put(&app.text, .MSG_DONE, .{ app.wrote_files, @as([*:0]const u8, @ptrCast(&size)) });
            app.done_texts[1].put(&app.text, .MSG_DONE_NEXT, .{});
        } else {
            if (app.stop_asked) {
                app.done_texts[0].put(&app.text, .MSG_STOPPED, .{});
            } else {
                app.done_texts[0].put(&app.text, .MSG_FAILED, .{});
            }
            if (!app.stop_asked and app.heard_failure) {
                app.done_texts[1].plain(@ptrCast(&app.heard_line));
            } else {
                app.done_texts[1].put(&app.text, .MSG_NOT_BOOTABLE, .{});
            }
        }
        app.enable(.progress, app.stop_button, false);
        app.enable(.done, app.done_back, !ok);
        app.enable(.done, app.restart_button, ok);
        for (&app.done_texts, app.done_lines) |*line, object| app.showLine(.done, object, line);
        app.turn(.done);
    }

    /// The machine started again through C:Reboot. What comes back is a
    /// restart that did not happen.
    fn restart(app: *App) void {
        const dl = app.dl;
        const nil_in = dl.Open("NIL:", dos.MODE_OLDFILE);
        defer if (nil_in) |file| {
            _ = dl.Close(file);
        };
        const nil_out = dl.Open("NIL:", dos.MODE_NEWFILE);
        defer if (nil_out) |file| {
            _ = dl.Close(file);
        };
        _ = dl.SystemTagList("C:Reboot FORCE", &[_]TagItem{
            pair(if (nil_in != null) dos.SYS_Input else sdk.utility.TAG_IGNORE, @intFromPtr(nil_in)),
            pair(if (nil_out != null) dos.SYS_Output else sdk.utility.TAG_IGNORE, @intFromPtr(nil_out)),
            .{},
        });
        app.done_texts[1].put(&app.text, .MSG_RESTART_FAILED, .{});
        app.showLine(.done, app.done_lines[1], &app.done_texts[1]);
    }

    // --- the window -----------------------------------------------------------------

    /// The window opened on `page`, in the language the catalog is in.
    fn openWindow(app: *App, page: Page) bool {
        app.page = page;
        app.makeLanguageRows();
        app.makeKeymapRows();
        const layout = buildLayout(app) orelse return false;
        const ib = app.ib;
        app.object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
            pair(wn.WA_Title, @intFromPtr(app.text.get(.MSG_WINDOW_TITLE))),
            pair(wn.WA_ScreenTitle, @intFromPtr(SCREEN_TITLE)),
            pair(wn.WA_CloseGadget, 1),
            pair(wn.WA_DragBar, 1),
            pair(wn.WA_DepthGadget, 1),
            pair(wn.WA_SizeGadget, 1),
            pair(wn.WA_Activate, 1),
            pair(wc.WINDOWA_Layout, @intFromPtr(layout)),
            .{},
        }) orelse {
            ib.DisposeObject(layout);
            return false;
        };
        var open = wc.WmOpen{};
        if (ib.SendMessage(app.object.?, @ptrCast(&open)) == 0) return false;
        var at: usize = 0;
        _ = ib.GetAttr(wc.WINDOWA_Window, app.object.?, &at);
        app.window = @ptrFromInt(at);
        return true;
    }

    /// The window closed and its gadgets let go; the rows stay the
    /// program's.
    fn closeWindow(app: *App) void {
        app.ib.DisposeObject(app.object);
        app.object = null;
        app.window = null;
        app.book = null;
        app.pages = @splat(null);
    }

    /// The language chosen made the running system's, and the window
    /// made again in it, on the keyboard's page.
    fn changeLanguage(app: *App) bool {
        app.closeWindow();
        app.text.close();
        app.apply();
        app.applied = app.chosen;
        app.text = Text.open(app.sys);
        return app.openWindow(.keyboard);
    }
};

fn button(ib: *IntuitionBase, text: [*:0]const u8, id: usize) ?*Object {
    return ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        pair(gc.GA_Text, @intFromPtr(text)),
        pair(gc.GA_ID, id),
        pair(gc.GA_RelVerify, 1),
        .{},
    });
}

/// A page's words: broken into lines as wide as the page.
fn prose(ib: *IntuitionBase, text: [*:0]const u8) ?*Object {
    return ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        pair(tx.TEXT_Text, @intFromPtr(text)),
        pair(tx.TEXT_Wrap, 1),
        pair(gc.GA_Width, text_width),
        .{},
    });
}

/// A line that changes: one too wide goes along inside it, so a long
/// reason is read whole.
fn textLine(ib: *IntuitionBase, text: [*:0]const u8) ?*Object {
    return ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        pair(tx.TEXT_Text, @intFromPtr(text)),
        pair(tx.TEXT_Scroll, 1),
        pair(gc.GA_Width, text_width),
        .{},
    });
}

fn listbrowser(ib: *IntuitionBase, id: usize, columns: [*]const lb.Column, rows: *exec.List, place: ?usize) ?*Object {
    return ib.NewObjectTagList(null, lb.LISTBROWSER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, id),
        pair(gc.GA_RelVerify, 1),
        pair(lb.LISTBROWSER_Columns, @intFromPtr(columns)),
        pair(lb.LISTBROWSER_Rows, @intFromPtr(rows)),
        pair(lb.LISTBROWSER_Selected, if (place) |at| at else lb.LISTBROWSER_NONE),
        .{},
    });
}

/// One child of a page's layout: the gadget, its label, the least height
/// it is given, and whether it takes the height left over.
const Child = struct {
    object: ?*Object,
    label: ?[*:0]const u8 = null,
    min_height: usize = 0,
    grows: bool = false,
};

/// A layout of `children`, one under the other, framed with `title` when
/// it has one - or side by side, the buttons of a page.
fn group(ib: *IntuitionBase, title: ?[*:0]const u8, across: bool, children: []const Child) ?*Object {
    var tags: [48]TagItem = undefined;
    var count: usize = 0;
    const add = struct {
        fn one(list: *[48]TagItem, at: *usize, tag: sdk.utility.Tag, data: usize) void {
            list[at.*] = pair(tag, data);
            at.* += 1;
        }
    }.one;
    add(&tags, &count, lg.LAYOUTA_Orientation, if (across) lg.LORIENT_HORIZ else lg.LORIENT_VERT);
    add(&tags, &count, lg.LAYOUTA_Spacing, if (across) 8 else 6);
    if (title) |text| {
        add(&tags, &count, lg.LAYOUTA_FrameTitle, @intFromPtr(text));
        add(&tags, &count, lg.LAYOUTA_Margin, 8);
    }
    for (children) |child| {
        add(&tags, &count, lg.LAYOUTA_AddChild, @intFromPtr(child.object orelse return null));
        if (child.label) |label| add(&tags, &count, lg.CHILDA_Label, @intFromPtr(label));
        if (child.min_height != 0) add(&tags, &count, lg.CHILDA_MinHeight, child.min_height);
        if (!child.grows) add(&tags, &count, if (across) lg.CHILDA_WeightWidth else lg.CHILDA_WeightHeight, 0);
    }
    tags[count] = .{};
    return ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &tags);
}

/// The window's whole layout - a page for each step, the one shown
/// `app.page` - or null when something could not be made.
fn buildLayout(app: *App) ?*Object {
    const ib = app.ib;
    const text = &app.text;
    const list_height = rows_shown * fontHeight(app) + 24;

    app.language_columns = .{ .{ .title = text.get(.MSG_COLUMN_LANGUAGE), .flags = lb.COLUMN_NOSORT }, .{} };
    app.keymap_columns = .{
        .{ .title = text.get(.MSG_COLUMN_KEYMAP), .weight = 1, .flags = lb.COLUMN_NOSORT },
        .{ .title = text.get(.MSG_COLUMN_LAYOUT), .weight = 3, .flags = lb.COLUMN_NOSORT },
        .{},
    };
    app.target_columns = .{
        .{ .title = text.get(.MSG_COLUMN_DEVICE), .weight = 3, .flags = lb.COLUMN_NOSORT },
        .{ .title = text.get(.MSG_COLUMN_UNIT), .weight = 1, .flags = lb.COLUMN_NOSORT | lb.COLUMN_RIGHT },
        .{ .title = text.get(.MSG_COLUMN_SIZE), .weight = 1, .flags = lb.COLUMN_NOSORT | lb.COLUMN_RIGHT },
        .{ .title = text.get(.MSG_COLUMN_HOLDS), .weight = 5, .flags = lb.COLUMN_NOSORT },
        .{},
    };

    // The language.
    app.language_list = listbrowser(ib, ID_LANGUAGE_LIST, &app.language_columns, &app.language_rows, App.placeOf(&app.language_rows, app.chosen));
    app.language_next = button(ib, text.get(.MSG_NEXT), ID_LANGUAGE_NEXT);
    const language_page = group(ib, text.get(.MSG_LANGUAGE_TITLE), false, &.{
        .{ .object = prose(ib, text.get(.MSG_LANGUAGE_INTRO)) },
        .{ .object = app.language_list, .min_height = list_height, .grows = true },
        .{ .object = group(ib, null, true, &.{.{ .object = app.language_next }}) },
    });

    // The keyboard.
    app.keymap_list = listbrowser(ib, ID_KEYMAP_LIST, &app.keymap_columns, &app.keymap_rows, if (app.keymap_chosen) |at| App.placeOf(&app.keymap_rows, at) else null);
    app.keymap_next = button(ib, text.get(.MSG_NEXT), ID_KEYMAP_NEXT);
    const try_field = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_TRY),
        pair(gc.GA_TabCycle, 1),
        pair(gc.STRINGA_MaxChars, 80),
        .{},
    });
    const keyboard_page = group(ib, text.get(.MSG_KEYBOARD_TITLE), false, &.{
        .{ .object = prose(ib, text.get(.MSG_KEYBOARD_INTRO)) },
        .{ .object = app.keymap_list, .min_height = list_height, .grows = true },
        .{ .object = try_field, .label = text.get(.MSG_TRY) },
        .{ .object = group(ib, null, true, &.{
            .{ .object = button(ib, text.get(.MSG_BACK), ID_KEYMAP_BACK) },
            .{ .object = app.keymap_next },
        }) },
    });

    // The disk.
    app.target_list = listbrowser(ib, ID_TARGET_LIST, &app.target_columns, &app.target_rows, if (app.target_chosen) |at| App.placeOf(&app.target_rows, at) else null);
    app.target_line = textLine(ib, app.target_text.ptr());
    app.target_text.changed = false;
    app.target_next = button(ib, text.get(.MSG_NEXT), ID_TARGET_NEXT);
    const target_page = group(ib, text.get(.MSG_TARGET_TITLE), false, &.{
        .{ .object = prose(ib, text.get(.MSG_TARGET_INTRO)) },
        .{ .object = app.target_list, .min_height = list_height, .grows = true },
        .{ .object = app.target_line },
        .{ .object = group(ib, null, true, &.{
            .{ .object = button(ib, text.get(.MSG_BACK), ID_TARGET_BACK) },
            .{ .object = button(ib, text.get(.MSG_LOOK_AGAIN), ID_TARGET_AGAIN) },
            .{ .object = app.target_next },
        }) },
    });

    // The last look.
    for (&app.confirm_lines, &app.confirm_texts) |*object, *line| {
        object.* = textLine(ib, line.ptr());
        line.changed = false;
    }
    const confirm_page = group(ib, text.get(.MSG_CONFIRM_TITLE), false, &.{
        .{ .object = app.confirm_lines[0] },
        .{ .object = app.confirm_lines[1] },
        .{ .object = app.confirm_lines[2] },
        .{ .object = app.confirm_lines[3], .grows = true },
        .{ .object = group(ib, null, true, &.{
            .{ .object = button(ib, text.get(.MSG_BACK), ID_CONFIRM_BACK) },
            .{ .object = button(ib, text.get(.MSG_INSTALL), ID_INSTALL) },
        }) },
    });

    // The install going.
    app.phase_line = textLine(ib, app.phase_text.ptr());
    app.detail_line = textLine(ib, app.detail_text.ptr());
    app.phase_text.changed = false;
    app.detail_text.changed = false;
    app.gauge = ib.NewObjectTagList(null, fg.GAUGE_CLASS, &[_]TagItem{
        pair(fg.GAUGE_Level, 0),
        pair(fg.GAUGE_Percent, 1),
        pair(fg.GAUGE_Format, @intFromPtr("%ld%%")),
        .{},
    });
    app.gauge_max = 0;
    app.gauge_level = 0;
    app.stop_button = button(ib, text.get(.MSG_STOP), ID_STOP);
    const progress_page = group(ib, text.get(.MSG_PROGRESS_TITLE), false, &.{
        .{ .object = app.phase_line },
        .{ .object = app.detail_line },
        .{ .object = app.gauge, .grows = true },
        .{ .object = group(ib, null, true, &.{.{ .object = app.stop_button }}) },
    });

    // What it came to.
    for (&app.done_lines, &app.done_texts) |*object, *line| {
        object.* = textLine(ib, line.ptr());
        line.changed = false;
    }
    app.done_back = button(ib, text.get(.MSG_BACK), ID_DONE_BACK);
    app.restart_button = button(ib, text.get(.MSG_RESTART), ID_RESTART);
    const done_page = group(ib, text.get(.MSG_DONE_TITLE), false, &.{
        .{ .object = app.done_lines[0] },
        .{ .object = app.done_lines[1], .grows = true },
        .{ .object = group(ib, null, true, &.{
            .{ .object = app.done_back },
            .{ .object = app.restart_button },
        }) },
    });

    app.pages = .{ language_page, keyboard_page, target_page, confirm_page, progress_page, done_page };
    for (app.pages) |one| _ = one orelse return null;
    app.book = ib.NewObjectTagList(null, pg.PAGE_CLASS, &[_]TagItem{
        pair(pg.PAGE_Pages, @intFromPtr(&app.pages)),
        pair(pg.PAGE_Current, @intFromEnum(app.page)),
        .{},
    }) orelse return null;
    const layout = group(ib, null, false, &.{.{ .object = app.book, .grows = true }}) orelse return null;
    // The buttons as the install allows.
    app.enable(.target, app.target_next, app.targetFits());
    app.enable(.progress, app.stop_button, app.job.running());
    return layout;
}

/// How tall a row of the screen's font is, which a list's least height
/// is measured in.
fn fontHeight(app: *App) usize {
    const screen = app.ib.LockPubScreen(null) orelse return 16;
    defer app.ib.UnlockPubScreen(null, screen);
    const info = app.ib.GetScreenDrawInfo(screen);
    defer app.ib.FreeScreenDrawInfo(screen, info);
    const font = info.font orelse return 16;
    var extent = graphics.FontExtent{};
    app.gb.FontExtent(font, &extent);
    return @max(@as(usize, @intCast(@max(extent.height, 8))), 8);
}

/// What `locale.prefs` says now: ENV:'s copy, or ENVARC:'s.
fn currentSettings(sys: *ExecBase, dl: *DosBase, ub: *UtilityBase) locale_file.Settings {
    var settings: locale_file.Settings = .{};
    const text = prefs.loadWhole(sys, dl, locale_file.ENV_FILE) orelse
        prefs.loadWhole(sys, dl, locale_file.ENVARC_FILE) orelse return settings;
    defer sys.FreeVec(@ptrCast(text.ptr));
    if (locale_file.parse(ub, text, &settings) != null) return .{};
    return settings;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var text = Text.open(sys);
    var libraries: [10]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    const wanted = [_]struct { [*:0]const u8, u32 }{
        .{ intuition.INTUITIONNAME, 0 },     .{ graphics.GRAPHICSNAME, 0 },     .{ sdk.utility.UTILITYNAME, 0 },
        .{ sdk.expansion.EXPANSIONNAME, 0 }, .{ sdk.rdb.RDBNAME, rdb_version }, .{ lb.LISTBROWSER_LIBRARY, 0 },
        .{ tx.TEXT_LIBRARY, 0 },             .{ fg.GAUGE_LIBRARY, 0 },          .{ st.STRING_LIBRARY, 0 },
        .{ pg.PAGE_LIBRARY, 0 },
    };
    for (wanted, 0..) |one, index| {
        libraries[index] = sys.OpenLibrary(one[0], one[1]) orelse {
            _ = text.printf(dl, .MSG_NOLIBRARY, .{ @as([*:0]const u8, COMMAND_NAME), one[0] });
            text.close();
            return dos.RETURN_FAIL;
        };
    }
    const rdb_lib = libraries[4].?;
    if (rdb_lib.version == rdb_version and rdb_lib.revision < fat_revision) {
        _ = text.printf(dl, .MSG_NOLIBRARY, .{ @as([*:0]const u8, COMMAND_NAME), @as([*:0]const u8, sdk.rdb.RDBNAME ++ " 1.7") });
        text.close();
        return dos.RETURN_FAIL;
    }

    const memory = sys.AllocVec(@sizeOf(App), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        _ = text.printf(dl, .MSG_NOMEMORY, .{@as([*:0]const u8, COMMAND_NAME)});
        text.close();
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const app: *App = @ptrCast(@alignCast(memory));
    app.* = .{
        .sys = sys,
        .dl = dl,
        .ib = @ptrCast(libraries[0].?),
        .gb = @ptrCast(libraries[1].?),
        .ub = @ptrCast(libraries[2].?),
        .eb = @ptrCast(libraries[3].?),
        .rb = @ptrCast(rdb_lib),
        .text = text,
    };
    defer app.text.close();
    app.language_rows.init(.unknown);
    defer lb.freeRows(sys, &app.language_rows);
    app.keymap_rows.init(.unknown);
    defer lb.freeRows(sys, &app.keymap_rows);
    app.target_rows.init(.unknown);
    defer lb.freeRows(sys, &app.target_rows);
    if (!app.job.init(sys, dl, app.rb, app.eb, app.ub)) {
        _ = app.text.printf(dl, .MSG_NOMEMORY, .{@as([*:0]const u8, COMMAND_NAME)});
        return dos.RETURN_FAIL;
    }
    defer app.job.free();

    var probe = app.probe();
    app.slots = worker.slotsOf(&probe);
    app.readKeymaps();
    // The choices start as the system is: its language and country, its
    // keymap.
    const settings = currentSettings(sys, dl, app.ub);
    if (App.matching(&settings)) |index| {
        app.chosen = index;
        app.applied = index;
    }
    app.keymap_chosen = app.keymapIndex(settings.keymapName()) orelse app.keymapIndex(choices[app.chosen].keymap);

    if (!app.openWindow(.language)) {
        _ = app.text.printf(dl, .MSG_NOWINDOW, .{@as([*:0]const u8, COMMAND_NAME)});
        app.closeWindow();
        return dos.RETURN_FAIL;
    }
    defer app.closeWindow();

    const news = app.job.signal();
    const ends = app.job.endSignal();
    var code_word: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code_word };
    while (true) {
        var mask: usize = 0;
        _ = app.ib.GetAttr(wc.WINDOWA_SigMask, app.object.?, &mask);
        const got = sys.Wait(@as(u32, @intCast(mask)) | news | ends | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_OK;
        if (got & news != 0 and app.job.running()) app.heard();
        if (got & ends != 0 and app.job.finished()) app.ended();

        while (true) {
            const word = app.ib.SendMessage(app.object.?, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => return dos.RETURN_OK,
                wc.WMHI_GADGETUP => {
                    const double = code_word & lb.LISTBROWSER_DOUBLE != 0;
                    switch (word & wc.WMHI_GADGETMASK) {
                        ID_LANGUAGE_LIST => {
                            if (app.selected(app.language_list)) |place| app.chooseLanguage(place);
                            if (double and !nextFromLanguage(app)) return dos.RETURN_FAIL;
                        },
                        ID_LANGUAGE_NEXT => if (!nextFromLanguage(app)) return dos.RETURN_FAIL,
                        ID_KEYMAP_LIST => {
                            if (app.selected(app.keymap_list)) |place| app.chooseKeymap(place);
                            if (double) nextFromKeyboard(app);
                        },
                        ID_KEYMAP_BACK => app.turn(.language),
                        ID_KEYMAP_NEXT => nextFromKeyboard(app),
                        ID_TARGET_LIST => {
                            if (app.selected(app.target_list)) |place| app.chooseTarget(place);
                            if (double and app.targetFits()) nextFromTarget(app);
                        },
                        ID_TARGET_AGAIN => app.lookAtTargets(),
                        ID_TARGET_BACK => app.turn(.keyboard),
                        ID_TARGET_NEXT => if (app.targetFits()) nextFromTarget(app),
                        ID_CONFIRM_BACK => app.turn(.target),
                        ID_INSTALL => app.begin(),
                        ID_STOP => if (app.job.running()) {
                            app.stop_asked = true;
                            app.job.stop();
                            app.phase_text.put(&app.text, .MSG_STOPPING, .{});
                            app.showProgress();
                        },
                        ID_DONE_BACK => if (!app.job.running()) {
                            app.turn(.target);
                            app.lookAtTargets();
                        },
                        ID_RESTART => if (!app.job.running()) app.restart(),
                        else => {},
                    }
                },
                else => {},
            }
        }
    }
}

/// Next on the language's page: the language made the system's where it
/// changed - the window made again in it - and the keyboard's page shown.
/// False when the window could not be made again.
fn nextFromLanguage(app: *App) bool {
    if (app.applied != null and app.applied.? == app.chosen) {
        app.turn(.keyboard);
        return true;
    }
    return app.changeLanguage();
}

fn nextFromKeyboard(app: *App) void {
    app.turn(.target);
    app.lookAtTargets();
}

fn nextFromTarget(app: *App) void {
    app.sayConfirm();
    app.turn(.confirm);
}
