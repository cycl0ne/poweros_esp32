// SPDX-License-Identifier: MIT
//! OpenLocale: a locale from a settings file, or the default one.

const sdk = @import("sdk");
const locale = sdk.locale;
const _base = @import("../locale_base.zig");
const _locale = @import("_locale.zig");
const LocaleBase = _base.LocaleBase;

/// Makes a locale from a settings file, or answers the default one.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenLocale(lb: *LocaleBase, name: ?[*:0]const u8) ?*locale.Locale
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `name` - the path of a settings file, as `ENV:Sys/locale.prefs` is
///   written; null for the default locale.
///
/// RESULT:
/// The locale, or null when the settings file cannot be read, the country
/// it names has no file, none of the languages it names has one, or a
/// file holds a value its key does not take. IoErr says which:
/// ERROR_OBJECT_NOT_FOUND and the rest of dos's for a file that cannot be
/// read, ERROR_OBJECT_WRONG_TYPE for a value, ERROR_UNMATCHED_QUOTES for
/// a quote not closed, ERROR_OBJECT_TOO_LARGE for more text than a locale
/// holds (4 KiB), ERROR_INVALID_COMPONENT_NAME for a name too long for a
/// path, ERROR_NO_FREE_STORE.
///
/// BEHAVIOR:
/// With null, the default locale is answered, held once more: the one
/// SetDefaultLocale last made the default, or the library's own - English,
/// and the dates dos writes - before it has.
///
/// With a name, a locale is made from the file: its COUNTRY's file in
/// LOCALE:Countries, the first of its LANGUAGES that has a file in
/// LOCALE:Languages (English needs none), and the time zone's rule from
/// ENVARC:Sys/timezone. A field no file sets keeps the library's own
/// value. A name may be given with its `.country` or `.language` or
/// without. Every file is UTF-8 text, converted to the locale's code set.
///
/// A settings file:
///
///   # The country, and the languages in the order they are wanted.
///   COUNTRY=deutschland
///   LANGUAGES=deutsch,english
///
/// CONTEXT:
/// - Waits: yes, to read the files; not with null.
/// - Interrupts: no.
/// - Locks: takes the library's lock, for a moment, with null. None may
///   be held that a handler needs.
/// - Process: yes, with a name: the files are read through dos. A Task
///   will do with null.
///
/// OWNERSHIP:
/// The locale is the caller's to give back with CloseLocale. It does not
/// change while it is held, and every string it points at is good until
/// then.
///
/// NOTES:
/// A key a file has and the library does not know is passed over, so a
/// file written for a later library still reads.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CloseLocale`, `SetDefaultLocale`, `GetLocaleStr`
///
/// EXAMPLES:
/// ```zig
/// const loc = lb.OpenLocale(null) orelse return;
/// defer lb.CloseLocale(loc);
/// lb.FormatDate(loc, loc.date_format, &stamp, &out.hook);
/// ```
pub fn OpenLocale(lb: *LocaleBase, name: ?[*:0]const u8) ?*locale.Locale {
    const file_name = name orelse {
        const sys = lb.sys_base;
        sys.ObtainSemaphore(&lb.lock);
        const ext = lb.default_locale;
        ext.usage += 1;
        sys.ReleaseSemaphore(&lb.lock);
        return &ext.public;
    };
    const ext = _locale.make(lb, file_name) orelse return null;
    return &ext.public;
}
