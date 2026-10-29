// SPDX-License-Identifier: MIT
//! Making a locale: the library's own, and one from a settings file and
//! the country and the language it names.
//!
//! The library's own is English, with the United States' numbers and
//! money and the dates dos writes when nothing else is set (`29-Oct-2026`,
//! `14:05:09`); its strings are constants of the library's.
//!
//! Any other starts as a copy of it and takes what its files say over:
//!
//! - the settings file, `COUNTRY=<name>` and `LANGUAGES=<name>,<name>,...`
//!   (ten at most, the preferred first). Without LANGUAGES, the country's
//!   LANGUAGE is the list; without either, English.
//! - `LOCALE:Countries/<name>.country`, the country's formats, one key
//!   per field of the Locale (`country_keys`).
//! - `LOCALE:Languages/<name>.language` for the first language in the
//!   list that has one: its words by their names (`DAY_1=Sonntag`), and
//!   the letters it sorts after one of the alphabet's (`AFTER_Z=Å,ÄÆ,ÖØ`,
//!   a comma between letters that sort apart). English is the library's
//!   own and has no file.
//! - the time zone's rule, from the first line of ENVARC:Sys/timezone.
//!
//! Every file is a line of `KEY=value` pairs per line, as utility's
//! NextSetting reads them - a value with blanks in double quotes - with
//! `#` or `;` starting a line that is a comment; a key the library does
//! not know is passed over. A file is UTF-8, a mark at its start allowed,
//! and its text is converted to the locale's code set as it is kept: a
//! character the code set lacks becomes `?`, and a file that is not UTF-8
//! is taken as Latin-1, byte for byte.
//!
//! What a file says is kept in the locale's own text, so the file is
//! given back as soon as it is read; no lock is held while it is, because
//! the locale is the caller's alone until OpenLocale answers it.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const locale = sdk.locale;
const prefs = sdk.prefs;
const style = prefs.style;
const UtilityBase = sdk.interface.utility.UtilityBase;
const DosBase = sdk.interface.dos.DosBase;
const _base = @import("../locale_base.zig");
const _chars = @import("../chars/_chars.zig");
const LocaleBase = _base.LocaleBase;
const ExtLocale = _base.ExtLocale;
const Locale = locale.Locale;

/// The language built in.
pub const english = "english";

/// English's words, by their GetLocaleStr number.
const english_words = [locale.MAXSTRMSG][*:0]const u8{
    "",
    "Sunday",
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
    "Sun",
    "Mon",
    "Tue",
    "Wed",
    "Thu",
    "Fri",
    "Sat",
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec",
    "Yes",
    "No",
    "AM",
    "PM",
    "-",
    "-",
    "\"",
    "\"",
    "Yesterday",
    "Today",
    "Tomorrow",
    "Future",
};

/// Three digits to a group, repeated; the same for the decimals.
const by_three: [*]const u8 = "\x03";

/// The library's own locale, as a program sees it.
const builtin_locale = Locale{
    .locale_name = "default",
    .language_name = english,
    .pref_languages = .{ english, null, null, null, null, null, null, null, null, null },
    .flags = 0,
    .code_set = locale.CODESET_LATIN1,
    .country_code = "US",
    .telephone_code = 1,
    .time_zone = null,
    .measuring_system = locale.MS_AMERICAN,
    .calendar_type = locale.CT_7SUN,
    .date_time_format = "%A, %e %B %Y %H:%M:%S",
    .date_format = "%A, %e %B %Y",
    .time_format = "%H:%M:%S",
    .short_date_time_format = "%d-%b-%Y %H:%M:%S",
    .short_date_format = "%d-%b-%Y",
    .short_time_format = "%H:%M:%S",
    .decimal_point = ".",
    .group_separator = ",",
    .frac_group_separator = ",",
    .grouping = by_three,
    .frac_grouping = by_three,
    .mon_decimal_point = ".",
    .mon_group_separator = ",",
    .mon_frac_group_separator = ",",
    .mon_grouping = by_three,
    .mon_frac_grouping = by_three,
    .mon_frac_digits = 2,
    .mon_int_frac_digits = 2,
    .mon_cs = "$",
    .mon_small_cs = "c",
    .mon_int_cs = "USD",
    .mon_positive_sign = "",
    .mon_positive_space_sep = locale.SS_NOSPACE,
    .mon_positive_sign_pos = locale.SP_PREC_ALL,
    .mon_positive_cs_pos = locale.CSP_PRECEDES,
    .mon_negative_sign = "-",
    .mon_negative_space_sep = locale.SS_NOSPACE,
    .mon_negative_sign_pos = locale.SP_PREC_ALL,
    .mon_negative_cs_pos = locale.CSP_PRECEDES,
};

/// The library's own locale made in `ext`, which the base holds: it is
/// the default until another is made one, and is never freed.
pub fn makeBuiltin(ext: *ExtLocale) void {
    ext.* = .{ .public = builtin_locale, .usage = 1, .builtin = true, .strings = english_words };
    rank(&letter_weights, &ext.primary);
}

/// A locale made from the settings file `name`, held once by the caller;
/// null with IoErr set when a file cannot be read or says what cannot be.
///
/// - `lb` - the base: exec, dos and utility, and the library's own locale
///   every other starts from.
/// - `name` - the settings file's path.
pub fn make(lb: *LocaleBase, name: [*:0]const u8) ?*ExtLocale {
    const sys = lb.sys_base;
    const dl = lb.dos_base;
    const memory = sys.AllocVec(@sizeOf(ExtLocale), exec.MEMF_ANY) orelse {
        _ = dl.SetIoErr(dos.ERROR_NO_FREE_STORE);
        return null;
    };
    const ext: *ExtLocale = @ptrCast(@alignCast(memory));
    ext.* = .{
        .public = lb.builtin.public,
        .usage = 1,
        .strings = lb.builtin.strings,
        .primary = lb.builtin.primary,
    };
    if (!readSettings(lb, ext, name)) {
        sys.FreeVec(memory);
        return null;
    }
    return ext;
}

// --- the files ---------------------------------------------------------------------------

/// A file read whole for `lb`: its text without a UTF-8 mark, and whether
/// it is to be taken as Latin-1. The caller gives `whole` back with FreeVec.
const File = struct {
    whole: []u8,
    text: []u8,
    latin1: bool,

    fn read(lb: *LocaleBase, path: [*:0]const u8) ?File {
        const whole = prefs.loadWhole(lb.sys_base, lb.dos_base, path) orelse return null;
        var text = whole;
        if (text.len >= 3 and text[0] == 0xEF and text[1] == 0xBB and text[2] == 0xBF) text = text[3..];
        return .{ .whole = whole, .text = text, .latin1 = !isUtf8(text) };
    }

    fn free(file: *const File, lb: *LocaleBase) void {
        lb.sys_base.FreeVec(file.whole.ptr);
    }
};

/// The `KEY=value` pairs of a settings text, line by line; a line without
/// words - blank, or a comment - is passed over.
const Settings = struct {
    ub: *UtilityBase,
    lines: prefs.Lines,
    pairs: ?prefs.Pairs = null,

    fn init(ub: *UtilityBase, text: []const u8) Settings {
        return .{ .ub = ub, .lines = .{ .text = text } };
    }

    fn next(settings: *Settings) error{QuoteNotClosed}!?prefs.Pairs.Pair {
        while (true) {
            if (settings.pairs) |*pairs| {
                if (try pairs.next()) |pair| return pair;
                settings.pairs = null;
            }
            const line = settings.lines.next() orelse return null;
            if (style.hasWords(line.text)) settings.pairs = prefs.Pairs.init(settings.ub, line.text);
        }
    }
};

/// False, with `code` as IoErr.
fn fail(dl: *DosBase, code: i32) bool {
    _ = dl.SetIoErr(code);
    return false;
}

fn readSettings(lb: *LocaleBase, ext: *ExtLocale, name: [*:0]const u8) bool {
    const dl = lb.dos_base;
    const file = File.read(lb, name) orelse return false;
    defer file.free(lb);

    var country: ?[]const u8 = null;
    var languages: ?[]const u8 = null;
    var settings = Settings.init(lb.utility_base, file.text);
    while (settings.next() catch return fail(dl, dos.ERROR_UNMATCHED_QUOTES)) |pair| {
        if (style.same(pair.key, "COUNTRY")) country = pair.value;
        if (style.same(pair.key, "LANGUAGES")) languages = pair.value;
    }

    var country_language: ?[]const u8 = null;
    if (country) |country_name| {
        if (!readCountry(lb, ext, country_name, file.latin1, &country_language)) return false;
    }
    const list = languages orelse country_language orelse english;
    if (!keepLanguages(ext, list, file.latin1)) return fail(dl, dos.ERROR_OBJECT_TOO_LARGE);
    if (!pickLanguage(lb, ext)) return false;
    readTimeZone(lb, ext);
    return true;
}

/// The country `name`'s file read into `ext`. Its LANGUAGE, kept in
/// `ext`'s text, is answered in `language`.
fn readCountry(lb: *LocaleBase, ext: *ExtLocale, name: []const u8, latin1: bool, language: *?[]const u8) bool {
    const dl = lb.dos_base;
    var path: [256]u8 = undefined;
    const file_name = pathOf(&path, locale.countries_dir, name, ".country") orelse
        return fail(dl, dos.ERROR_INVALID_COMPONENT_NAME);
    ext.public.locale_name = keep(ext, withoutSuffix(name, ".country"), latin1) orelse
        return fail(dl, dos.ERROR_OBJECT_TOO_LARGE);

    const file = File.read(lb, file_name) orelse return false;
    defer file.free(lb);
    var settings = Settings.init(lb.utility_base, file.text);
    while (settings.next() catch return fail(dl, dos.ERROR_UNMATCHED_QUOTES)) |pair| {
        if (style.same(pair.key, "LANGUAGE")) {
            const kept = keep(ext, pair.value, file.latin1) orelse return fail(dl, dos.ERROR_OBJECT_TOO_LARGE);
            language.* = kept[0..length(kept)];
            continue;
        }
        switch (setCountry(ext, pair.key, pair.value, file.latin1)) {
            .taken, .unknown => {},
            .wrong => return fail(dl, dos.ERROR_OBJECT_WRONG_TYPE),
            .full => return fail(dl, dos.ERROR_OBJECT_TOO_LARGE),
        }
    }
    return true;
}

/// The list of languages, comma by comma, kept as the locale's preferred.
fn keepLanguages(ext: *ExtLocale, list: []const u8, latin1: bool) bool {
    ext.public.pref_languages = @splat(null);
    var count: usize = 0;
    var start: usize = 0;
    var at: usize = 0;
    while (at <= list.len) : (at += 1) {
        if (at < list.len and list[at] != ',') continue;
        const word = trimmed(list[start..at]);
        start = at + 1;
        if (word.len == 0) continue;
        if (count == ext.public.pref_languages.len) break;
        ext.public.pref_languages[count] = keep(ext, withoutSuffix(word, ".language"), latin1) orelse return false;
        count += 1;
    }
    if (count == 0) ext.public.pref_languages[0] = english;
    return true;
}

/// The first of the preferred languages that has a file - or is English -
/// read into `ext`; false, with IoErr from the last one looked for, when
/// none has.
fn pickLanguage(lb: *LocaleBase, ext: *ExtLocale) bool {
    const dl = lb.dos_base;
    for (ext.public.pref_languages) |entry| {
        const language = entry orelse break;
        const name = language[0..length(language)];
        if (style.same(name, "ENGLISH")) {
            ext.public.language_name = english;
            ext.strings = lb.builtin.strings;
            ext.primary = lb.builtin.primary;
            return true;
        }
        var path: [256]u8 = undefined;
        const file_name = pathOf(&path, locale.languages_dir, name, ".language") orelse
            return fail(dl, dos.ERROR_INVALID_COMPONENT_NAME);
        const file = File.read(lb, file_name) orelse continue;
        defer file.free(lb);
        if (!readLanguage(lb, ext, file)) return false;
        ext.public.language_name = language;
        return true;
    }
    return false;
}

/// A language's words and order of letters read into `ext`.
fn readLanguage(lb: *LocaleBase, ext: *ExtLocale, file: File) bool {
    const dl = lb.dos_base;
    var weights = letter_weights;
    var settings = Settings.init(lb.utility_base, file.text);
    next_pair: while (settings.next() catch return fail(dl, dos.ERROR_UNMATCHED_QUOTES)) |pair| {
        for (locale.string_names[1..], 1..) |string_name, string_num| {
            if (!style.same(pair.key, string_name)) continue;
            ext.strings[string_num] = keep(ext, pair.value, file.latin1) orelse return fail(dl, dos.ERROR_OBJECT_TOO_LARGE);
            continue :next_pair;
        }
        const key = pair.key;
        if (key.len == 7 and style.same(key[0..6], "AFTER_")) {
            const letter = style.upper(key[6]);
            if (letter < 'A' or letter > 'Z') continue;
            var letters: [64]u8 = undefined;
            if (pair.value.len > letters.len) return fail(dl, dos.ERROR_OBJECT_WRONG_TYPE);
            @memcpy(letters[0..pair.value.len], pair.value);
            const count = if (file.latin1) pair.value.len else toLatin1(letters[0..pair.value.len]);
            if (!placeAfter(&weights, letter - 'A', letters[0..count])) return fail(dl, dos.ERROR_OBJECT_WRONG_TYPE);
        }
    }
    rank(&weights, &ext.primary);
    return true;
}

/// The time zone's rule kept, when ENVARC:Sys/timezone has one.
fn readTimeZone(lb: *LocaleBase, ext: *ExtLocale) void {
    ext.public.time_zone = null;
    const file = File.read(lb, dos.timezone.zone_file) orelse return;
    defer file.free(lb);
    const line = trimmed(prefs.firstLine(file.text) orelse return);
    if (dos.timezone.parse(line) == null) return;
    ext.public.time_zone = keep(ext, line, true);
}

// --- a country's keys ----------------------------------------------------------------------

const Kind = enum { text, grouping, number, digits, measure, first_day, space, sign_at, currency_at };

const CountryKey = struct { key: []const u8, field: []const u8, kind: Kind };

/// A country file's keys, and the field of the Locale each sets.
const country_keys = [_]CountryKey{
    .{ .key = "CODE", .field = "country_code", .kind = .text },
    .{ .key = "TELEPHONE", .field = "telephone_code", .kind = .number },
    .{ .key = "MEASURE", .field = "measuring_system", .kind = .measure },
    .{ .key = "FIRSTDAY", .field = "calendar_type", .kind = .first_day },
    .{ .key = "DATETIME", .field = "date_time_format", .kind = .text },
    .{ .key = "DATE", .field = "date_format", .kind = .text },
    .{ .key = "TIME", .field = "time_format", .kind = .text },
    .{ .key = "SHORTDATETIME", .field = "short_date_time_format", .kind = .text },
    .{ .key = "SHORTDATE", .field = "short_date_format", .kind = .text },
    .{ .key = "SHORTTIME", .field = "short_time_format", .kind = .text },
    .{ .key = "DECIMAL", .field = "decimal_point", .kind = .text },
    .{ .key = "GROUP", .field = "group_separator", .kind = .text },
    .{ .key = "FRACGROUP", .field = "frac_group_separator", .kind = .text },
    .{ .key = "GROUPING", .field = "grouping", .kind = .grouping },
    .{ .key = "FRACGROUPING", .field = "frac_grouping", .kind = .grouping },
    .{ .key = "MONDECIMAL", .field = "mon_decimal_point", .kind = .text },
    .{ .key = "MONGROUP", .field = "mon_group_separator", .kind = .text },
    .{ .key = "MONFRACGROUP", .field = "mon_frac_group_separator", .kind = .text },
    .{ .key = "MONGROUPING", .field = "mon_grouping", .kind = .grouping },
    .{ .key = "MONFRACGROUPING", .field = "mon_frac_grouping", .kind = .grouping },
    .{ .key = "MONFRACDIGITS", .field = "mon_frac_digits", .kind = .digits },
    .{ .key = "MONINTFRACDIGITS", .field = "mon_int_frac_digits", .kind = .digits },
    .{ .key = "CURRENCY", .field = "mon_cs", .kind = .text },
    .{ .key = "SMALLCURRENCY", .field = "mon_small_cs", .kind = .text },
    .{ .key = "INTCURRENCY", .field = "mon_int_cs", .kind = .text },
    .{ .key = "POSITIVESIGN", .field = "mon_positive_sign", .kind = .text },
    .{ .key = "POSITIVESPACE", .field = "mon_positive_space_sep", .kind = .space },
    .{ .key = "POSITIVESIGNAT", .field = "mon_positive_sign_pos", .kind = .sign_at },
    .{ .key = "POSITIVECURRENCYAT", .field = "mon_positive_cs_pos", .kind = .currency_at },
    .{ .key = "NEGATIVESIGN", .field = "mon_negative_sign", .kind = .text },
    .{ .key = "NEGATIVESPACE", .field = "mon_negative_space_sep", .kind = .space },
    .{ .key = "NEGATIVESIGNAT", .field = "mon_negative_sign_pos", .kind = .sign_at },
    .{ .key = "NEGATIVECURRENCYAT", .field = "mon_negative_cs_pos", .kind = .currency_at },
};

const measures = [_]style.Name{
    .{ .name = "METRIC", .value = locale.MS_ISO },
    .{ .name = "AMERICAN", .value = locale.MS_AMERICAN },
    .{ .name = "IMPERIAL", .value = locale.MS_IMPERIAL },
    .{ .name = "BRITISH", .value = locale.MS_BRITISH },
};

const first_days = [_]style.Name{
    .{ .name = "SUNDAY", .value = locale.CT_7SUN },
    .{ .name = "MONDAY", .value = locale.CT_7MON },
    .{ .name = "TUESDAY", .value = locale.CT_7TUE },
    .{ .name = "WEDNESDAY", .value = locale.CT_7WED },
    .{ .name = "THURSDAY", .value = locale.CT_7THU },
    .{ .name = "FRIDAY", .value = locale.CT_7FRI },
    .{ .name = "SATURDAY", .value = locale.CT_7SAT },
};

const signs_at = [_]style.Name{
    .{ .name = "PARENS", .value = locale.SP_PARENS },
    .{ .name = "BEFORE", .value = locale.SP_PREC_ALL },
    .{ .name = "AFTER", .value = locale.SP_SUCC_ALL },
    .{ .name = "BEFORECURRENCY", .value = locale.SP_PREC_CURR },
    .{ .name = "AFTERCURRENCY", .value = locale.SP_SUCC_CURR },
};

const currencies_at = [_]style.Name{
    .{ .name = "BEFORE", .value = locale.CSP_PRECEDES },
    .{ .name = "AFTER", .value = locale.CSP_SUCCEEDS },
};

const Taken = enum { taken, unknown, wrong, full };

/// A country key's value set in `ext`.
fn setCountry(ext: *ExtLocale, key: []const u8, value: []const u8, latin1: bool) Taken {
    inline for (country_keys) |entry| {
        if (style.same(key, entry.key)) {
            const field = &@field(ext.public, entry.field);
            switch (entry.kind) {
                .text => field.* = keep(ext, value, latin1) orelse return .full,
                .grouping => field.* = keepGrouping(ext, value) orelse return .wrong,
                .number => field.* = number(value) orelse return .wrong,
                .digits => {
                    const digits = number(value) orelse return .wrong;
                    if (digits > 9) return .wrong;
                    field.* = @intCast(digits);
                },
                .measure => field.* = @intCast(style.lookUp(&measures, value) orelse return .wrong),
                .first_day => field.* = @intCast(style.lookUp(&first_days, value) orelse return .wrong),
                .space => field.* = if (prefs.yesOrNo(value) orelse return .wrong) locale.SS_SPACE else locale.SS_NOSPACE,
                .sign_at => field.* = @intCast(style.lookUp(&signs_at, value) orelse return .wrong),
                .currency_at => field.* = @intCast(style.lookUp(&currencies_at, value) orelse return .wrong),
            }
            return .taken;
        }
    }
    return .unknown;
}

/// A grouping (`3`, `3,2`, `3,NONE`, `NONE`) kept as its bytes: each count,
/// then a 0 that repeats the last, or GROUPING_NONE where it stops.
fn keepGrouping(ext: *ExtLocale, value: []const u8) ?[*]const u8 {
    const start = ext.used;
    var at: usize = 0;
    var begin: usize = 0;
    var stopped = false;
    while (at <= value.len) : (at += 1) {
        if (at < value.len and value[at] != ',') continue;
        const word = trimmed(value[begin..at]);
        begin = at + 1;
        if (stopped) return null;
        const count: u8 = if (style.same(word, "NONE")) locale.GROUPING_NONE else blk: {
            const digits = number(word) orelse return null;
            if (digits == 0 or digits >= locale.GROUPING_NONE) return null;
            break :blk @intCast(digits);
        };
        if (count == locale.GROUPING_NONE) stopped = true;
        if (!keepByte(ext, count)) return null;
    }
    if (!stopped and !keepByte(ext, 0)) return null;
    return ext.text[start..].ptr;
}

fn keepByte(ext: *ExtLocale, byte: u8) bool {
    if (ext.used >= ext.text.len) return false;
    ext.text[ext.used] = byte;
    ext.used += 1;
    return true;
}

// --- text ---------------------------------------------------------------------------------

/// `bytes` kept in the locale's text, converted to its code set and ended
/// with a NUL; null when the text is full.
pub fn keep(ext: *ExtLocale, bytes: []const u8, latin1: bool) ?[*:0]const u8 {
    if (ext.text.len - ext.used < bytes.len + 1) return null;
    const into = ext.text[ext.used..][0..bytes.len];
    @memcpy(into, bytes);
    const count = if (latin1) bytes.len else toLatin1(into);
    ext.text[ext.used + count] = 0;
    const kept: [*:0]const u8 = @ptrCast(&ext.text[ext.used]);
    ext.used += @intCast(count + 1);
    return kept;
}

/// Whether `bytes` are well-formed UTF-8.
pub fn isUtf8(bytes: []const u8) bool {
    var at: usize = 0;
    while (at < bytes.len) {
        const lead = bytes[at];
        const count: usize = if (lead < 0x80)
            1
        else if (lead >= 0xC2 and lead <= 0xDF)
            2
        else if (lead >= 0xE0 and lead <= 0xEF)
            3
        else if (lead >= 0xF0 and lead <= 0xF4)
            4
        else
            return false;
        if (at + count > bytes.len) return false;
        for (bytes[at + 1 .. at + count]) |follow| {
            if (follow & 0xC0 != 0x80) return false;
        }
        at += count;
    }
    return true;
}

/// Well-formed UTF-8 turned into Latin-1 where it stands, a character
/// Latin-1 lacks as `?`; how many bytes it is now.
pub fn toLatin1(bytes: []u8) usize {
    var from: usize = 0;
    var to: usize = 0;
    while (from < bytes.len) {
        const lead = bytes[from];
        const count: usize = if (lead < 0x80) 1 else if (lead >= 0xF0) 4 else if (lead >= 0xE0) 3 else 2;
        var code: u32 = switch (count) {
            1 => lead,
            2 => lead & 0x1F,
            3 => lead & 0x0F,
            else => lead & 0x07,
        };
        for (bytes[from + 1 .. @min(from + count, bytes.len)]) |follow| code = code << 6 | (follow & 0x3F);
        from += count;
        bytes[to] = if (code <= 0xFF) @intCast(code) else '?';
        to += 1;
    }
    return to;
}

/// The length of a NUL-ended string.
pub fn length(text: [*:0]const u8) usize {
    var count: usize = 0;
    while (text[count] != 0) count += 1;
    return count;
}

fn trimmed(text: []const u8) []const u8 {
    var start: usize = 0;
    var end = text.len;
    while (start < end and (text[start] == ' ' or text[start] == '\t' or text[start] == '\r')) start += 1;
    while (end > start and (text[end - 1] == ' ' or text[end - 1] == '\t' or text[end - 1] == '\r')) end -= 1;
    return text[start..end];
}

/// A decimal number of digits alone, or null.
fn number(text: []const u8) ?u32 {
    if (text.len == 0 or text.len > 9) return null;
    var value: u32 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
        value = value * 10 + (c - '0');
    }
    return value;
}

fn endsWith(name: []const u8, suffix: []const u8) bool {
    if (name.len < suffix.len) return false;
    for (name[name.len - suffix.len ..], suffix) |a, b| {
        if (style.upper(a) != style.upper(b)) return false;
    }
    return true;
}

fn withoutSuffix(name: []const u8, suffix: []const u8) []const u8 {
    return if (endsWith(name, suffix)) name[0 .. name.len - suffix.len] else name;
}

/// `dir/name` with `suffix` after it, unless the name has it, NUL-ended
/// in `into`; null when it does not fit.
fn pathOf(into: []u8, dir: []const u8, name: []const u8, suffix: []const u8) ?[*:0]const u8 {
    const tail = if (endsWith(name, suffix)) "" else suffix;
    const total = dir.len + 1 + name.len + tail.len;
    if (name.len == 0 or total + 1 > into.len) return null;
    @memcpy(into[0..dir.len], dir);
    into[dir.len] = '/';
    @memcpy(into[dir.len + 1 ..][0..name.len], name);
    @memcpy(into[dir.len + 1 + name.len ..][0..tail.len], tail);
    into[total] = 0;
    return @ptrCast(into.ptr);
}

// --- the order of letters --------------------------------------------------------------------

/// Where a letter's weight starts: below it, every character that is not
/// a letter, by its code.
const letters_from: u16 = 256;
/// The weights a letter may take: itself, and seven after it.
const slots: u16 = 8;
/// The bases past z: þ, then µ.
const thorn: u8 = 26;
const micro: u8 = 27;
/// Every weight there is, one past the last.
const weight_count = letters_from + (micro + 1) * slots;

/// The letter of the alphabet each of À to ß is written on, `-` for ×, `_`
/// for þ.
const accented = "aaaaaaaceeeeiiiidnooooo-ouuuuy_s";

/// The letter (0 for a ... 25 for z, then þ and µ) a letter of Latin-1 is
/// sorted with when its case and accent are left out; null for anything
/// else.
fn baseOf(c: u8) ?u8 {
    if (!_chars.is(c, _chars.alpha)) return null;
    if (c >= 'A' and c <= 'Z') return c - 'A';
    if (c >= 'a' and c <= 'z') return c - 'a';
    if (c == 0xAA) return 'a' - 'a';
    if (c == 0xBA) return 'o' - 'a';
    if (c == 0xB5) return micro;
    if (c == 0xFF) return 'y' - 'a';
    const letter = accented[(c - 0xC0) & 0x1F];
    return if (letter == '_') thorn else letter - 'a';
}

/// Each character's weight in no language's own order: a letter with the
/// letter it is written on, case and accent left out, anything else by
/// its code.
const letter_weights: [256]u16 = blk: {
    @setEvalBranchQuota(50_000);
    var table: [256]u16 = undefined;
    for (0..256) |code| {
        const c: u8 = @intCast(code);
        table[code] = if (baseOf(c)) |base| letters_from + @as(u16, base) * slots else c;
    }
    break :blk table;
};

/// The letters `groups` given the weights after `letter`'s (0 for A), in
/// both cases: those before the first comma right after it, those before
/// the next after them, and so on; false for anything that is not a
/// letter, or more than seven groups.
fn placeAfter(weights: *[256]u16, letter: u8, groups: []const u8) bool {
    var slot: u16 = 1;
    for (groups) |c| {
        if (c == ',') {
            slot += 1;
            if (slot >= slots) return false;
            continue;
        }
        if (c == ' ') continue;
        if (!_chars.is(c, _chars.alpha)) return false;
        const weight = letters_from + @as(u16, letter) * slots + slot;
        weights[c] = weight;
        weights[_chars.toLower(c)] = weight;
        weights[_chars.toUpper(c)] = weight;
    }
    return true;
}

/// The weights turned into a byte each that keeps their order, from 2 up:
/// StrConvert's keys are these bytes, 0 ending a key and 1 parting its
/// halves.
fn rank(weights: *const [256]u16, into: *[256]u8) void {
    const words = (weight_count + 31) / 32;
    var used: [words]u32 = @splat(0);
    for (weights) |weight| used[weight / 32] |= @as(u32, 1) << @intCast(weight % 32);
    for (weights, into) |weight, *byte| {
        var below: u32 = 0;
        for (used[0 .. weight / 32]) |word| below += @popCount(word);
        const part = used[weight / 32] & ((@as(u32, 1) << @intCast(weight % 32)) - 1);
        below += @popCount(part);
        const key: u32 = 2 + below;
        byte.* = if (key > 255) 255 else @intCast(key);
    }
}
