// SPDX-License-Identifier: MIT
//! LanguageCode: the ISO 639-1 code of a language, by the name the
//! library gives it.

const _base = @import("../locale_base.zig");
const LocaleBase = _base.LocaleBase;

/// Every language the library has a file for, and English, its own: the
/// name, as a locale's `language_name` and `pref_languages` give it, and
/// its code.
const codes = [_]struct { name: []const u8, code: [*:0]const u8 }{
    .{ .name = "bulgarski", .code = "bg" },      .{ .name = "cestina", .code = "cs" },    .{ .name = "dansk", .code = "da" },
    .{ .name = "deutsch", .code = "de" },        .{ .name = "eesti", .code = "et" },      .{ .name = "ellinika", .code = "el" },
    .{ .name = "english", .code = "en" },        .{ .name = "espanol", .code = "es" },    .{ .name = "francais", .code = "fr" },
    .{ .name = "gaeilge", .code = "ga" },        .{ .name = "hangugeo", .code = "ko" },   .{ .name = "hindi", .code = "hi" },
    .{ .name = "hrvatski", .code = "hr" },       .{ .name = "islenska", .code = "is" },   .{ .name = "italiano", .code = "it" },
    .{ .name = "latviesu", .code = "lv" },       .{ .name = "lietuviu", .code = "lt" },   .{ .name = "magyar", .code = "hu" },
    .{ .name = "malti", .code = "mt" },          .{ .name = "nederlands", .code = "nl" }, .{ .name = "nihongo", .code = "ja" },
    .{ .name = "norsk", .code = "nb" },          .{ .name = "polski", .code = "pl" },     .{ .name = "portugues", .code = "pt" },
    .{ .name = "romana", .code = "ro" },         .{ .name = "russkij", .code = "ru" },    .{ .name = "slovencina", .code = "sk" },
    .{ .name = "slovenscina", .code = "sl" },    .{ .name = "suomi", .code = "fi" },      .{ .name = "svenska", .code = "sv" },
    .{ .name = "turkce", .code = "tr" },         .{ .name = "ukrainska", .code = "uk" },  .{ .name = "zhongwen", .code = "zh" },
    .{ .name = "zhongwen-fanti", .code = "zh" },
};

/// The ISO 639-1 code of a language, by its name.
///
/// SYNOPSIS:
/// ```zig
/// fn LanguageCode(_: *LocaleBase, language: [*:0]const u8) ?[*:0]const u8
/// ```
///
/// SINCE: 1.7. LVO -120.
///
/// INPUTS:
/// - `language` - a language's name as the library gives it: a locale's
///   `language_name` or one of its `pref_languages` (`deutsch`). Case
///   does not count.
///
/// RESULT:
/// Its two letters, lower case (`de`); null for a language the library
/// has no file for and that is not English. Chinese in either of its
/// scripts is `zh`.
///
/// BEHAVIOR:
/// A program that speaks to the world in its codes - a document's
/// language, a service asked for its answers in one - takes the user's
/// language from the locale and its code from here.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The code is the library's, good while it is open.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenLocale`
///
/// EXAMPLES:
/// ```zig
/// const loc = lb.OpenLocale(null) orelse return;
/// defer lb.CloseLocale(loc);
/// const code = lb.LanguageCode(loc.language_name) orelse "en";
/// ```
pub fn LanguageCode(_: *LocaleBase, language: [*:0]const u8) ?[*:0]const u8 {
    for (codes) |pair| {
        var at: usize = 0;
        while (at < pair.name.len and lower(language[at]) == pair.name[at]) at += 1;
        if (at == pair.name.len and language[at] == 0) return pair.code;
    }
    return null;
}

fn lower(char: u8) u8 {
    return if (char >= 'A' and char <= 'Z') char + ('a' - 'A') else char;
}
