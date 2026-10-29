// SPDX-License-Identifier: MIT
//! SetDefaultLocale: a locale made the default.

const sdk = @import("sdk");
const locale = sdk.locale;
const _base = @import("../locale_base.zig");
const _dos = @import("../dos/_dos.zig");
const LocaleBase = _base.LocaleBase;

/// Makes a locale the default, which `OpenLocale(null)` answers and dos
/// writes and reads dates and its texts in.
///
/// SYNOPSIS:
/// ```zig
/// fn SetDefaultLocale(lb: *LocaleBase, loc: *locale.Locale) ?*locale.Locale
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `loc` - a locale from OpenLocale; it must not be null.
///
/// RESULT:
/// The default before, with the library's hold on it handed to the
/// caller.
///
/// BEHAVIOR:
/// The library holds `loc` once more for as long as it is the default, so
/// the caller may give its own hold back at once. A program that opens the
/// default locale after this gets `loc`; one that opened it before keeps
/// the one it has.
///
/// From the first call on, dos.library's DateToStr, StrToDate and Fault
/// are the library's, and the library stays in memory. DateToStr writes
/// the default locale's words - the months' short names, the weekdays,
/// "today" and the rest - and dos.FORMAT_DEF is the locale's short date
/// and time. StrToDate reads them, and what it does not read it hands to
/// dos's own, so English words and dos's forms still work. Fault answers
/// a code's text from the catalog `sys/dos.catalog` in the locale's
/// languages, opened here each time; dos's own text where that has none.
///
/// CONTEXT:
/// - Waits: for the library's lock, for a moment, and for the catalog's
///   file.
/// - Interrupts: no.
/// - Locks: takes the library's lock, never across the file read.
/// - Process: a process, for dos's catalog to be read; a Task gets the
///   catalog only when it is loaded already.
///
/// OWNERSHIP:
/// The locale answered is the caller's to give back with CloseLocale; the
/// caller's hold on `loc` stays the caller's.
///
/// NOTES:
/// C:SetPrefs calls this at boot with the locale ENV:Sys/locale.prefs
/// describes; few programs have reason to.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenLocale`, `CloseLocale`, `OpenCatalogA`, dos.library `DateToStr`,
/// `StrToDate`, `Fault`
///
/// EXAMPLES:
/// ```zig
/// const loc = lb.OpenLocale(locale.prefs_file) orelse return error.NoLocale;
/// lb.CloseLocale(lb.SetDefaultLocale(loc));
/// lb.CloseLocale(loc);
/// ```
pub fn SetDefaultLocale(lb: *LocaleBase, loc: *locale.Locale) ?*locale.Locale {
    const ext = _base.extOf(loc);
    const sys = lb.sys_base;
    sys.ObtainSemaphore(&lb.lock);
    ext.usage += 1;
    const before = lb.default_locale;
    lb.default_locale = ext;
    sys.ReleaseSemaphore(&lb.lock);
    _dos.install(lb);
    _dos.useCatalog(lb, loc);
    return &before.public;
}
