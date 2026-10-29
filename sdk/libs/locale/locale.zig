// SPDX-License-Identifier: MIT
//! locale.library's structures and constants: a locale - a country's way
//! of writing dates, times, numbers and money, and the language its words
//! are in - and a catalog, a program's strings in a language. The calls
//! are in `sdk.interface.locale`.
//!
//! **Both are the library's, and read only.** OpenLocale and OpenCatalogA
//! make them; a program reads their fields and hands them back with
//! CloseLocale and CloseCatalog. A field that is a string points into the
//! library's memory and is good until the locale is closed.
//!
//! **The text is in the locale's code set** (`Locale.code_set`): Latin-1
//! while the system shows Latin-1, UTF-8 once it shows UTF-8. The files a
//! locale is made from - the settings, the countries, the languages, the
//! catalogs - are written in UTF-8, and the library converts what it reads
//! to the code set; a character the code set lacks becomes `?`. A
//! character handed to a call is a code point (`u32`), and lengths are
//! counted in bytes.
//!
//! The files:
//!
//! - `ENV:Sys/locale.prefs` - the setting: the country, and the languages
//!   in the order they are preferred. `OpenLocale(null)` is the locale
//!   `SetDefaultLocale` last made the default, which C:SetPrefs makes from
//!   this file at boot.
//! - `LOCALE:Countries/<name>.country` - a country's formats.
//! - `LOCALE:Languages/<name>.language` - a language's words and the
//!   order its letters sort in. English is the library's own.
//! - `LOCALE:Catalogs/<language>/<name>` - a program's strings in a
//!   language; `PROGDIR:Catalogs/<language>/<name>` is looked in first.
//!
//! `Strings`, at the end, is what a program uses its catalog through:
//! tools/catcomp makes its strings and their numbers from a `.cd` file,
//! and this hands out the catalog's version of each, or the one built in.

const exec = @import("../exec/exec.zig");
const dos = @import("../dos/dos.zig");
const utility = @import("../utility/utility.zig");
const LocaleBase = @import("../../interface/locale.zig").LocaleBase;
const DosBase = @import("../../interface/dos.zig").DosBase;

/// The library's name, for OpenLibrary.
pub const LOCALENAME = "locale.library";

// --- GetLocaleStr ------------------------------------------------------------------

/// The weekdays, Sunday first.
pub const DAY_1: u32 = 1;
pub const DAY_2: u32 = 2;
pub const DAY_3: u32 = 3;
pub const DAY_4: u32 = 4;
pub const DAY_5: u32 = 5;
pub const DAY_6: u32 = 6;
pub const DAY_7: u32 = 7;
/// The weekdays, short, Sunday first.
pub const ABDAY_1: u32 = 8;
pub const ABDAY_2: u32 = 9;
pub const ABDAY_3: u32 = 10;
pub const ABDAY_4: u32 = 11;
pub const ABDAY_5: u32 = 12;
pub const ABDAY_6: u32 = 13;
pub const ABDAY_7: u32 = 14;
/// The months, January first.
pub const MON_1: u32 = 15;
pub const MON_2: u32 = 16;
pub const MON_3: u32 = 17;
pub const MON_4: u32 = 18;
pub const MON_5: u32 = 19;
pub const MON_6: u32 = 20;
pub const MON_7: u32 = 21;
pub const MON_8: u32 = 22;
pub const MON_9: u32 = 23;
pub const MON_10: u32 = 24;
pub const MON_11: u32 = 25;
pub const MON_12: u32 = 26;
/// The months, short, January first.
pub const ABMON_1: u32 = 27;
pub const ABMON_2: u32 = 28;
pub const ABMON_3: u32 = 29;
pub const ABMON_4: u32 = 30;
pub const ABMON_5: u32 = 31;
pub const ABMON_6: u32 = 32;
pub const ABMON_7: u32 = 33;
pub const ABMON_8: u32 = 34;
pub const ABMON_9: u32 = 35;
pub const ABMON_10: u32 = 36;
pub const ABMON_11: u32 = 37;
pub const ABMON_12: u32 = 38;
/// The answers to a question of yes or no.
pub const YESSTR: u32 = 39;
pub const NOSTR: u32 = 40;
/// Before and after noon.
pub const AM_STR: u32 = 41;
pub const PM_STR: u32 = 42;
/// The hyphen a word may be broken at, and the one that is always there.
pub const SOFTHYPHEN: u32 = 43;
pub const HARDHYPHEN: u32 = 44;
/// What a quotation opens and closes with.
pub const OPENQUOTE: u32 = 45;
pub const CLOSEQUOTE: u32 = 46;
/// A day said as a word: the one before today, today, the one after, and
/// any later.
pub const YESTERDAYSTR: u32 = 47;
pub const TODAYSTR: u32 = 48;
pub const TOMORROWSTR: u32 = 49;
pub const FUTURESTR: u32 = 50;
/// How many there are, the unused 0 counted: one past the last.
pub const MAXSTRMSG: u32 = 51;

/// Each string's name, as a language file gives it, by its number; 0 has
/// none.
pub const string_names = [MAXSTRMSG][]const u8{
    "",          "DAY_1",      "DAY_2",        "DAY_3",      "DAY_4",
    "DAY_5",     "DAY_6",      "DAY_7",        "ABDAY_1",    "ABDAY_2",
    "ABDAY_3",   "ABDAY_4",    "ABDAY_5",      "ABDAY_6",    "ABDAY_7",
    "MON_1",     "MON_2",      "MON_3",        "MON_4",      "MON_5",
    "MON_6",     "MON_7",      "MON_8",        "MON_9",      "MON_10",
    "MON_11",    "MON_12",     "ABMON_1",      "ABMON_2",    "ABMON_3",
    "ABMON_4",   "ABMON_5",    "ABMON_6",      "ABMON_7",    "ABMON_8",
    "ABMON_9",   "ABMON_10",   "ABMON_11",     "ABMON_12",   "YESSTR",
    "NOSTR",     "AM_STR",     "PM_STR",       "SOFTHYPHEN", "HARDHYPHEN",
    "OPENQUOTE", "CLOSEQUOTE", "YESTERDAYSTR", "TODAYSTR",   "TOMORROWSTR",
    "FUTURESTR",
};

// --- code sets -----------------------------------------------------------------------

/// A code set by its number in IANA's list of character sets (its
/// MIBenum), which is what a catalog names its own by.
pub const CODESET_LATIN1: u32 = 4;
pub const CODESET_UTF8: u32 = 106;

// --- the locale ------------------------------------------------------------------------

/// struct Locale: a country's formats and a language, made by OpenLocale
/// and read only.
///
/// A format is a template for FormatDate (`%d.%m.%Y`). A grouping is a
/// list of byte counts, the digits in each group from the decimal point
/// outwards: a 0 repeats the count before it for the rest of the digits,
/// GROUPING_NONE (255) ends the grouping there.
pub const Locale = extern struct {
    /// loc_LocaleName: the country's name, as its file is called
    /// (`deutschland`), or `default` for the library's own.
    locale_name: [*:0]const u8,
    /// loc_LanguageName: the language its words are in (`deutsch`),
    /// `english` for the library's own.
    language_name: [*:0]const u8,
    /// loc_PrefLanguages: the languages in the order they are preferred,
    /// the first null ending the list. A catalog is looked for in each in
    /// turn.
    pref_languages: [10]?[*:0]const u8,
    /// loc_Flags: none yet, always 0.
    flags: u32,
    /// loc_CodeSet: the code set of every string here and of every
    /// catalog opened with this locale (CODESET_*).
    code_set: u32,
    /// loc_CountryCode: the country's code (ISO 3166, `DE`).
    country_code: [*:0]const u8,
    /// loc_TelephoneCode: what a call into the country is dialled with.
    telephone_code: u32,
    /// The time zone, as the POSIX TZ rule in `ENV:Sys/timezone` (see
    /// `sdk.dos.timezone`); null when that names none. A rule, and not an
    /// offset, because the offset changes with summer time.
    time_zone: ?[*:0]const u8,
    /// loc_MeasuringSystem: MS_*.
    measuring_system: u8,
    /// loc_CalendarType: CT_*, the day a week starts on.
    calendar_type: u8,

    /// loc_DateTimeFormat, loc_DateFormat, loc_TimeFormat: a moment, a
    /// date and a time written out in full.
    date_time_format: [*:0]const u8,
    date_format: [*:0]const u8,
    time_format: [*:0]const u8,
    /// loc_ShortDateTimeFormat, loc_ShortDateFormat, loc_ShortTimeFormat:
    /// the same, short. DateToStr's FORMAT_DEF is the short date and time.
    short_date_time_format: [*:0]const u8,
    short_date_format: [*:0]const u8,
    short_time_format: [*:0]const u8,

    /// loc_DecimalPoint: what comes before the decimals.
    decimal_point: [*:0]const u8,
    /// loc_GroupSeparator: what parts groups of digits.
    group_separator: [*:0]const u8,
    /// loc_FracGroupSeparator: the same in the decimals.
    frac_group_separator: [*:0]const u8,
    /// loc_Grouping, loc_FracGrouping: the size of each group.
    grouping: [*]const u8,
    frac_grouping: [*]const u8,

    /// loc_MonDecimalPoint and the rest: the same, for money.
    mon_decimal_point: [*:0]const u8,
    mon_group_separator: [*:0]const u8,
    mon_frac_group_separator: [*:0]const u8,
    mon_grouping: [*]const u8,
    mon_frac_grouping: [*]const u8,
    /// loc_MonFracDigits: the digits after the decimal point.
    mon_frac_digits: u8,
    /// loc_MonIntFracDigits: the same, written with the international
    /// symbol.
    mon_int_frac_digits: u8,

    /// loc_MonCS: the currency's symbol.
    mon_cs: [*:0]const u8,
    /// loc_MonSmallCS: the symbol of its smaller unit.
    mon_small_cs: [*:0]const u8,
    /// loc_MonIntCS: its international code (ISO 4217, `EUR`).
    mon_int_cs: [*:0]const u8,

    /// loc_MonPositiveSign and the rest: how an amount of money above
    /// zero is written - its sign, SS_* whether the symbol is parted from
    /// the amount by a space, SP_* where the sign goes, CSP_* where the
    /// symbol goes.
    mon_positive_sign: [*:0]const u8,
    mon_positive_space_sep: u8,
    mon_positive_sign_pos: u8,
    mon_positive_cs_pos: u8,

    /// loc_MonNegativeSign and the rest: the same below zero.
    mon_negative_sign: [*:0]const u8,
    mon_negative_space_sep: u8,
    mon_negative_sign_pos: u8,
    mon_negative_cs_pos: u8,
};

/// Locale.measuring_system: metric, US customary, imperial, British.
pub const MS_ISO: u8 = 0;
pub const MS_AMERICAN: u8 = 1;
pub const MS_IMPERIAL: u8 = 2;
pub const MS_BRITISH: u8 = 3;

/// Locale.calendar_type: seven days a week, starting on Sunday ... on
/// Saturday.
pub const CT_7SUN: u8 = 0;
pub const CT_7MON: u8 = 1;
pub const CT_7TUE: u8 = 2;
pub const CT_7WED: u8 = 3;
pub const CT_7THU: u8 = 4;
pub const CT_7FRI: u8 = 5;
pub const CT_7SAT: u8 = 6;

/// The money fields' `*_space_sep`: whether a space parts the symbol from
/// the amount.
pub const SS_NOSPACE: u8 = 0;
pub const SS_SPACE: u8 = 1;

/// The money fields' `*_sign_pos`: parentheses round the amount and the
/// symbol; the sign before both; after both; right before the symbol;
/// right after it.
pub const SP_PARENS: u8 = 0;
pub const SP_PREC_ALL: u8 = 1;
pub const SP_SUCC_ALL: u8 = 2;
pub const SP_PREC_CURR: u8 = 3;
pub const SP_SUCC_CURR: u8 = 4;

/// The money fields' `*_cs_pos`: the symbol before the amount, or after.
pub const CSP_PRECEDES: u8 = 0;
pub const CSP_SUCCEEDS: u8 = 1;

/// A grouping's end: no more groups from here on.
pub const GROUPING_NONE: u8 = 255;

// --- comparing ---------------------------------------------------------------------------

/// StrnCmp's and StrConvert's types: case left out (SC_ASCII); case and
/// accents left out, the language's order of letters (SC_COLLATE1); that
/// order, and where it finds two strings the same, case and accents
/// deciding (SC_COLLATE2) - the order a sorted list is shown in.
pub const SC_ASCII: u32 = 0;
pub const SC_COLLATE1: u32 = 1;
pub const SC_COLLATE2: u32 = 2;

// --- catalogs ----------------------------------------------------------------------------

/// OpenCatalogA's tags.
pub const OC_TagBase: utility.Tag = utility.TAG_USER + 0x90000;
/// The language of the strings built into the program, `english` unless
/// given: a catalog in it is never looked for.
pub const OC_BuiltInLanguage: utility.Tag = OC_TagBase + 1;
/// The code set of those strings (CODESET_*). Taken and not used yet.
pub const OC_BuiltInCodeSet: utility.Tag = OC_TagBase + 2;
/// The version a catalog must have; any when 0 or not given.
pub const OC_Version: utility.Tag = OC_TagBase + 3;
/// A language to look in before the locale's own.
pub const OC_Language: utility.Tag = OC_TagBase + 4;

/// struct Catalog: a program's strings in one language, made by
/// OpenCatalogA and read only.
pub const Catalog = extern struct {
    /// cat_Link: its name is the catalog's (`sys/dos.catalog`).
    link: exec.Node = .{},
    /// cat_Language: the language the strings are in.
    language: ?[*:0]const u8 = null,
    /// cat_CodeSet: the code set they are in now (CODESET_*): the
    /// locale's, whatever the file had.
    code_set: u32 = 0,
    /// cat_Version, cat_Revision: from the version string the file
    /// carries.
    version: u32 = 0,
    revision: u32 = 0,
};

/// The name of a catalog file's chunks: an IFF FORM of type CTLG holding
/// FVER (the `$VER:` string), LANG (the language), CSET (the code set, a
/// big-endian u32 and seven reserved), and STRS: each string as a
/// big-endian id and length - its bytes and the NUL after them - then
/// those bytes, padded to a multiple of four.
pub const ID_CTLG: u32 = makeID("CTLG");
pub const ID_FVER: u32 = makeID("FVER");
pub const ID_LANG: u32 = makeID("LANG");
pub const ID_CSET: u32 = makeID("CSET");
pub const ID_STRS: u32 = makeID("STRS");

fn makeID(comptime four: *const [4]u8) u32 {
    return @as(u32, four[0]) << 24 | @as(u32, four[1]) << 16 | @as(u32, four[2]) << 8 | four[3];
}

// --- the settings -----------------------------------------------------------------------

/// Where the setting is read from: C:SetPrefs makes the default locale
/// of it.
pub const prefs_file = "ENV:Sys/locale.prefs";
/// Where the countries, the languages and the catalogs are.
pub const countries_dir = "LOCALE:Countries";
pub const languages_dir = "LOCALE:Languages";
pub const catalogs_dir = "LOCALE:Catalogs";
pub const program_catalogs_dir = "PROGDIR:Catalogs";

// --- output into a buffer ------------------------------------------------------------------

/// A hook for FormatDate and FormatString that writes into a buffer: each
/// byte while there is room, the NUL that ends the text always.
///
///   var into: [64]u8 = undefined;
///   var out = locale.BufferHook.init(&into);
///   lb.FormatDate(loc, "%A %e %B %Y", &stamp, &out.hook);
///   // out.text() is the date
pub const BufferHook = extern struct {
    hook: utility.Hook = .{},
    buffer: [*]u8,
    size: usize,
    length: usize = 0,

    pub fn init(into: []u8) BufferHook {
        return .{ .hook = .{ .entry = &put }, .buffer = into.ptr, .size = into.len };
    }

    /// What was written, without the NUL.
    pub fn text(out: *const BufferHook) []const u8 {
        return out.buffer[0..out.length];
    }

    fn put(hook: *utility.Hook, _: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
        const out: *BufferHook = @fieldParentPtr("hook", hook);
        const byte: u8 = @truncate(@intFromPtr(message));
        if (out.size == 0) return 0;
        if (byte == 0) {
            out.buffer[out.length] = 0;
        } else if (out.length + 1 < out.size) {
            out.buffer[out.length] = byte;
            out.length += 1;
            out.buffer[out.length] = 0;
        }
        return 0;
    }
};

/// A hook for ParseDate that reads a string, a byte at a time, and 0 at
/// its end.
pub const StringHook = extern struct {
    hook: utility.Hook = .{},
    text: [*:0]const u8,
    at: usize = 0,

    pub fn init(text: [*:0]const u8) StringHook {
        return .{ .hook = .{ .entry = &get }, .text = text };
    }

    fn get(hook: *utility.Hook, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) usize {
        const in: *StringHook = @fieldParentPtr("hook", hook);
        const byte = in.text[in.at];
        if (byte != 0) in.at += 1;
        return byte;
    }
};

// --- a program's strings --------------------------------------------------------------------

/// A program's strings, from the module tools/catcomp makes of its `.cd`
/// file (the SDK build's `addStrings`): `Id`, the strings' numbers by
/// name; `builtin`, each one's text in the language built in;
/// `catalog_name` and `catalog_version`, what OpenCatalogA is given.
///
///   const strings = @import("strings"); // made from the program's .cd
///   var text = locale.Strings(strings).open(sys);
///   defer text.close();
///   _ = text.printf(dl, .MSG_FILES, .{count});
///
/// Without locale.library, or without a catalog in any of the languages
/// the locale prefers, every string is the one built in.
pub fn Strings(comptime Module: type) type {
    return struct {
        const Self = @This();
        pub const Id = Module.Id;

        sys: *exec.ExecBase,
        library: ?*LocaleBase = null,
        /// The default locale, which the catalog is in.
        locale: ?*Locale = null,
        catalog: ?*Catalog = null,

        /// locale.library opened, the default locale and the catalog with
        /// it, as far as they are there.
        pub fn open(sys: *exec.ExecBase) Self {
            var self: Self = .{ .sys = sys };
            const library = sys.OpenLibrary(LOCALENAME, 1) orelse return self;
            self.library = @ptrCast(library);
            self.locale = self.library.?.OpenLocale(null);
            const tags = [_]utility.TagItem{
                .{ .tag = OC_BuiltInLanguage, .data = @intFromPtr(Module.builtin_language.ptr) },
                .{ .tag = OC_Version, .data = Module.catalog_version },
                .{},
            };
            self.catalog = self.library.?.OpenCatalogA(self.locale, Module.catalog_name, &tags);
            return self;
        }

        /// The catalog, the locale and the library given back.
        pub fn close(self: *Self) void {
            const library = self.library orelse return;
            library.CloseCatalog(self.catalog);
            library.CloseLocale(self.locale);
            self.sys.CloseLibrary(library.lib());
            self.library = null;
            self.locale = null;
            self.catalog = null;
        }

        /// The string `id` in the catalog's language, or the one built in.
        pub fn get(self: *const Self, comptime id: Id) [*:0]const u8 {
            const builtin = Module.builtin(id);
            const library = self.library orelse return builtin;
            return library.GetCatalogStr(self.catalog, @intFromEnum(id), builtin);
        }

        /// The string `id` as a format, `args` checked against the one
        /// built in - tools/catcomp has checked every translation against
        /// it too - and written to Output(): by FormatString, so a
        /// translation may take the values in another order (`%2$s`) and
        /// `%D` groups digits as the locale does; by VPrintf without the
        /// library. The bytes written, or -1 when the output failed.
        pub fn printf(self: *const Self, dl: *DosBase, comptime id: Id, args: anytype) i32 {
            comptime exec.checkFormat(Module.builtin(id), @TypeOf(args));
            const stream = exec.fmtStream(args);
            const library = self.library orelse return dl.VPrintf(Module.builtin(id), &stream);
            const loc = self.locale orelse return dl.VPrintf(self.get(id), &stream);
            var out = OutputHook{ .dl = dl, .file = dl.Output() };
            _ = library.FormatString(loc, self.get(id), &stream, &out.hook);
            return if (out.failed) -1 else out.count;
        }
    };
}

/// A hook for FormatString and FormatDate that writes to a file through
/// dos's FPutC: each byte, the NUL that ends the text left out.
pub const OutputHook = extern struct {
    hook: utility.Hook = .{ .entry = &put },
    dl: *DosBase,
    file: ?*dos.FileHandle,
    count: i32 = 0,
    failed: bool = false,

    fn put(hook: *utility.Hook, _: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
        const out: *OutputHook = @fieldParentPtr("hook", hook);
        const byte: u8 = @truncate(@intFromPtr(message));
        if (byte == 0 or out.failed) return 0;
        if (out.dl.FPutC(out.file, byte) < 0) {
            out.failed = true;
            return 0;
        }
        out.count += 1;
        return 0;
    }
};
