// SPDX-License-Identifier: MIT
//! locale.library's base, and the shapes behind the public ones.
//!
//! A Locale a program sees is the head of an `ExtLocale`: its count of
//! holders, the language's words by number, the weight each character
//! sorts by, and the memory every string of the locale is kept in. The
//! library's own locale - English, and the formats dos writes - is an
//! ExtLocale inside the base, made at init and never freed; any other is
//! one allocation, made by OpenLocale and freed by the CloseLocale that
//! lets go of it last.
//!
//! A Catalog is the head of an `ExtCatalog`: its holders, and its strings
//! sorted by number with the text after them, all in one allocation. A
//! catalog stays on the base's list when the last holder lets go, so the
//! next program to ask finds it at once, and goes when the library is
//! asked to expunge.
//!
//! The lock guards the counts, the default and the list; it is never held
//! over a file read, because a handler that is reading for the library
//! may itself write a date through it (the dos calls in dos/).

const sdk = @import("sdk");
const exec = sdk.exec;
const locale = sdk.locale;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;

/// The bytes a locale keeps its strings in: a country's formats and a
/// language's 50 words, with room to spare.
pub const text_size = 4096;

/// A locale, with what the library keeps behind the public part.
pub const ExtLocale = extern struct {
    public: locale.Locale,
    /// How many hold it: each OpenLocale that answered it, and the library
    /// while it is the default.
    usage: u32 = 0,
    /// Whether it is the base's own, which is never freed.
    builtin: bool = false,
    /// The language's words, by their GetLocaleStr number; 0 is unused.
    strings: [locale.MAXSTRMSG][*:0]const u8 = undefined,
    /// What each Latin-1 character sorts by when case and accents are
    /// left out (SC_COLLATE1), as a byte from 2 up: anything that is not a
    /// letter below every letter, in the order of its code, the letters
    /// in the language's order.
    primary: [256]u8 = undefined,
    /// The strings, filled from the front.
    used: u32 = 0,
    text: [text_size]u8 = undefined,
};

/// A catalog, with what the library keeps behind the public part. Its
/// `count` entries follow it, then the strings they point at, then its
/// name.
pub const ExtCatalog = extern struct {
    public: locale.Catalog = .{},
    /// How many hold it.
    usage: u32 = 0,
    /// The strings, sorted by number.
    count: u32 = 0,
    entries: [*]Entry = undefined,
    /// The allocation it is the head of, and its size.
    size: usize = 0,
    /// The language, as the file names it.
    language: [32]u8 = @splat(0),
};

/// One of a catalog's strings.
pub const Entry = extern struct {
    id: i32,
    text: [*:0]const u8,
};

pub const LocaleBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    seg_list: ?*anyopaque = null,
    /// dos.library, which every file is read through.
    dos_base: *DosBase,
    /// utility.library: the hooks, the calendar, the settings' pairs.
    utility_base: *UtilityBase,
    /// Taken while a count, the default or the catalog list changes.
    lock: exec.SignalSemaphore = .{},
    /// The default locale, which OpenLocale(null) answers.
    default_locale: *ExtLocale,
    /// The catalogs loaded, held or not.
    catalogs: exec.List = .{},
    /// dos's own DateToStr, StrToDate and Fault, kept when the library
    /// stood in front of them (dos/); null before.
    dos_date_to_str: ?*const anyopaque = null,
    dos_str_to_date: ?*const anyopaque = null,
    dos_fault: ?*const anyopaque = null,
    /// The catalog dos's faults are taken from, in the default locale's
    /// languages; null when there is none.
    dos_catalog: ?*locale.Catalog = null,
    /// The library's own locale.
    builtin: ExtLocale,

    /// This library as a caller sees it, to call its own functions through
    /// the jump table.
    pub fn iface(lb: *LocaleBase) *sdk.interface.locale.LocaleBase {
        return @ptrCast(lb);
    }
};

/// The base from exec's Library header.
pub fn localeBase(lib: *exec.Library) *LocaleBase {
    return @fieldParentPtr("lib", lib);
}

/// The base from the interface's handle.
pub fn fromInterface(lib: *sdk.interface.locale.LocaleBase) *LocaleBase {
    return @ptrCast(@alignCast(lib));
}

/// The locale behind the public part.
pub fn extOf(loc: *const locale.Locale) *ExtLocale {
    return @fieldParentPtr("public", @constCast(loc));
}

/// The catalog behind the public part.
pub fn catalogOf(catalog: *const locale.Catalog) *ExtCatalog {
    return @fieldParentPtr("public", @constCast(catalog));
}
