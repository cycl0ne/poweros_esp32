// SPDX-License-Identifier: MIT
//! GetLocaleStr: one of a language's words.

const sdk = @import("sdk");
const locale = sdk.locale;
const _base = @import("../locale_base.zig");
const LocaleBase = _base.LocaleBase;

/// Answers one of the words of the locale's language.
///
/// SYNOPSIS:
/// ```zig
/// fn GetLocaleStr(_: *LocaleBase, loc: *const locale.Locale, string_num: u32) ?[*:0]const u8
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `loc` - a locale, from OpenLocale.
/// - `string_num` - which word: DAY_1 (Sunday) to DAY_7, ABDAY_1 to
///   ABDAY_7, MON_1 (January) to MON_12, ABMON_1 to ABMON_12, YESSTR,
///   NOSTR, AM_STR, PM_STR, SOFTHYPHEN, HARDHYPHEN, OPENQUOTE, CLOSEQUOTE,
///   YESTERDAYSTR, TODAYSTR, TOMORROWSTR, FUTURESTR.
///
/// RESULT:
/// The word, in the locale's code set; null for 0 or a number past
/// FUTURESTR.
///
/// BEHAVIOR:
/// The words are the language file's; one it leaves out is English.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe; it reads the locale, which does not change.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The word is the locale's, good until it is closed.
///
/// NOTES:
/// FormatDate writes the day and month names with these; a program that
/// writes its own dates asks here for the same words.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenLocale`, `FormatDate`
///
/// EXAMPLES:
/// ```zig
/// const yes = lb.GetLocaleStr(loc, locale.YESSTR) orelse "Yes";
/// ```
pub fn GetLocaleStr(_: *LocaleBase, loc: *const locale.Locale, string_num: u32) ?[*:0]const u8 {
    if (string_num == 0 or string_num >= locale.MAXSTRMSG) return null;
    return _base.extOf(loc).strings[string_num];
}
