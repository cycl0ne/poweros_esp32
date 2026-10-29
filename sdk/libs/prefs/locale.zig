// SPDX-License-Identifier: MIT
//! locale.prefs: the country and the languages the system writes in, as a
//! file - a line, which locale.library makes the default locale of when
//! C:SetPrefs hands it over:
//!
//!     COUNTRY=schweiz LANGUAGES="francais, deutsch, english"
//!
//! - COUNTRY: a file in LOCALE:Countries, without its `.country`.
//! - LANGUAGES: the languages wanted, the preferred first, ten at most,
//!   parted by commas, in quotes when there are several: each a file in
//!   LOCALE:Languages, English built in. Without it the country's own
//!   language is used.
//!
//! Without either the system's own locale is the default: English, with
//! the United States' formats. `parse` reads a file's lines into
//! `Settings` - every line, as locale.library reads them, a key it does
//! not know passed over as the library passes it - `write` writes them as
//! the line, and `header` is the explanation a program that writes the
//! file puts before it.

const style = @import("style.zig");
const prefs = @import("prefs.zig");
const UtilityBase = @import("../../interface/utility.zig").UtilityBase;

pub const ENV_FILE = "ENV:Sys/locale.prefs";
pub const ENVARC_FILE = "ENVARC:Sys/locale.prefs";

/// The most bytes of a country's or a language's name.
pub const name_len = 31;
/// The most languages LANGUAGES holds.
pub const max_languages = 10;

/// The file's settings.
pub const Settings = struct {
    country: [name_len:0]u8 = @splat(0),
    languages: [max_languages][name_len:0]u8 = @splat(@splat(0)),
    language_count: usize = 0,

    /// The country's name; empty for none.
    pub fn countryName(settings: *const Settings) []const u8 {
        return span(&settings.country);
    }

    /// The country named `name`, empty for none; false, with nothing
    /// changed, for a name too long.
    pub fn setCountry(settings: *Settings, name: []const u8) bool {
        if (name.len > name_len) return false;
        settings.country = @splat(0);
        @memcpy(settings.country[0..name.len], name);
        return true;
    }

    /// The language at `index`, the preferred at 0.
    pub fn language(settings: *const Settings, index: usize) []const u8 {
        return span(&settings.languages[index]);
    }

    /// `name` added after the languages there are; false, with nothing
    /// changed, when it is there already, is too long or empty, or the
    /// list is full.
    pub fn addLanguage(settings: *Settings, name: []const u8) bool {
        if (name.len == 0 or name.len > name_len) return false;
        if (settings.language_count == max_languages) return false;
        for (0..settings.language_count) |i| {
            if (sameName(settings.language(i), name)) return false;
        }
        const into = &settings.languages[settings.language_count];
        into.* = @splat(0);
        @memcpy(into[0..name.len], name);
        settings.language_count += 1;
        return true;
    }

    /// No language wanted: the country's own is used.
    pub fn clearLanguages(settings: *Settings) void {
        settings.languages = @splat(@splat(0));
        settings.language_count = 0;
    }
};

/// The file's lines read into `settings`, which keeps what they leave out:
/// null when they are taken, else what is wrong with them.
pub fn parse(ub: *UtilityBase, text: []const u8, settings: *Settings) ?[*:0]const u8 {
    var lines = prefs.Lines{ .text = text };
    while (lines.next()) |line| {
        if (!style.hasWords(line.text)) continue;
        var pairs = prefs.Pairs.init(ub, line.text);
        while (pairs.next() catch return prefs.Pairs.quote_not_closed) |pair| {
            if (style.same(pair.key, "COUNTRY")) {
                if (!settings.setCountry(pair.value)) return "COUNTRY names a file in LOCALE:Countries";
            } else if (style.same(pair.key, "LANGUAGES")) {
                settings.clearLanguages();
                var start: usize = 0;
                var at: usize = 0;
                while (at <= pair.value.len) : (at += 1) {
                    if (at < pair.value.len and pair.value[at] != ',') continue;
                    const word = trimmed(pair.value[start..at]);
                    start = at + 1;
                    if (word.len == 0) continue;
                    if (word.len > name_len) return "LANGUAGES names files in LOCALE:Languages";
                    // Past the tenth, passed over, as the library does.
                    _ = settings.addLanguage(word);
                }
            }
        }
    }
    return null;
}

/// `settings` written as the line, into `into` (360 bytes will do); how
/// many bytes, no newline - none for a country and languages not set.
pub fn write(settings: *const Settings, into: []u8) usize {
    var n: usize = 0;
    const put = struct {
        fn text(dst: []u8, at: *usize, s: []const u8) void {
            @memcpy(dst[at.*..][0..s.len], s);
            at.* += s.len;
        }
    }.text;
    const country = settings.countryName();
    if (country.len != 0) {
        put(into, &n, "COUNTRY=");
        put(into, &n, country);
    }
    if (settings.language_count != 0) {
        if (n != 0) put(into, &n, " ");
        put(into, &n, "LANGUAGES=");
        const quoted = settings.language_count > 1;
        if (quoted) put(into, &n, "\"");
        for (0..settings.language_count) |i| {
            if (i != 0) put(into, &n, ", ");
            put(into, &n, settings.language(i));
        }
        if (quoted) put(into, &n, "\"");
    }
    return n;
}

/// The file's explanation, every line a comment.
pub const header =
    \\# ENVARC:Sys/locale.prefs - the country and the languages the system
    \\# writes dates, numbers and its messages in, which C:SetPrefs makes the
    \\# default locale at boot. COUNTRY names a file in LOCALE:Countries;
    \\# LANGUAGES the languages wanted, the preferred first, each a file in
    \\# LOCALE:Languages and the catalogs in LOCALE:Catalogs/<language>, in
    \\# quotes when there are several. Without LANGUAGES the country's own
    \\# language is used; without either, or without a line, English and the
    \\# United States' formats. Prefs' Region page writes the line; to write
    \\# it by hand, take the # off one below.
    \\#
    \\# COUNTRY=deutschland
    \\# COUNTRY=schweiz LANGUAGES="deutsch, francais, english"
    \\# COUNTRY=united_kingdom
    \\
;

fn span(text: [*:0]const u8) []const u8 {
    var n: usize = 0;
    while (text[n] != 0) n += 1;
    return text[0..n];
}

/// Whether two names are one, whatever the case of their letters.
fn sameName(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (style.upper(x) != style.upper(y)) return false;
    }
    return true;
}

fn trimmed(text: []const u8) []const u8 {
    var from: usize = 0;
    var to = text.len;
    while (from < to and (text[from] == ' ' or text[from] == '\t')) from += 1;
    while (to > from and (text[to - 1] == ' ' or text[to - 1] == '\t')) to -= 1;
    return text[from..to];
}
