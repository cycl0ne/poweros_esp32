// SPDX-License-Identifier: MIT
//! OpenCatalogA: a program's strings in the first language the locale
//! prefers that has them.

const sdk = @import("sdk");
const utility = sdk.utility;
const locale = sdk.locale;
const _base = @import("../locale_base.zig");
const _catalog = @import("_catalog.zig");
const _locale = @import("../locale/_locale.zig");
const LocaleBase = _base.LocaleBase;

/// Opens a program's catalog in the first of the locale's languages that
/// has one.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenCatalogA(lb: *LocaleBase, loc: ?*const locale.Locale, name: [*:0]const u8, tag_list: ?[*]const utility.TagItem) ?*locale.Catalog
/// ```
///
/// SINCE: 1.0. LVO -108.
///
/// INPUTS:
/// - `loc` - the locale whose languages are tried; null for the default.
/// - `name` - the catalog's name: a program's place on the disk and
///   `.catalog` (`c/test/locale.catalog`), `sys/<module>.catalog` for the
///   system's own.
/// - `tag_list` - OC_BuiltInLanguage, the language of the strings built
///   into the program (`english` if not given); OC_Version, the version
///   the catalog must have (any if 0 or not given); OC_Language, a
///   language to try before the locale's; OC_BuiltInCodeSet, taken and
///   not used. Null for none.
///
/// RESULT:
/// The catalog, or null when the strings built in are the ones to use:
/// the language they are in comes before any with a catalog, or none of
/// the languages has one of that version.
///
/// BEHAVIOR:
/// OC_Language and then each of the locale's preferred languages is
/// tried in turn. The language built in ends the search - its strings
/// need no catalog. For any other, a catalog already loaded is taken;
/// else `PROGDIR:Catalogs/<language>/<name>` is read, when the caller has
/// a program directory, and then `LOCALE:Catalogs/<language>/<name>`.
/// The strings are converted to the locale's code set as they are read.
///
/// No requester asks for PROGDIR: or LOCALE: when either is missing.
///
/// CONTEXT:
/// - Waits: yes, to read a file; not for a catalog already loaded.
/// - Interrupts: no.
/// - Locks: takes the library's lock, never across a read. None may be
///   held that a handler needs.
/// - Process: yes, for the files; a Task gets only catalogs already
///   loaded.
///
/// OWNERSHIP:
/// The catalog is the caller's to give back with CloseCatalog. It stays
/// loaded after that until the library is asked to give memory back, so
/// the next program to open it has it at once.
///
/// NOTES:
/// sdk.locale's `Strings` opens a program's catalog with the name and the
/// version tools/catcomp put into its strings.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CloseCatalog`, `GetCatalogStr`, `OpenLocale`
///
/// EXAMPLES:
/// ```zig
/// const tags = [_]utility.TagItem{ .{ .tag = locale.OC_Version, .data = 1 }, .{} };
/// const catalog = lb.OpenCatalogA(null, "c/test/locale.catalog", &tags);
/// defer lb.CloseCatalog(catalog);
/// const hello = lb.GetCatalogStr(catalog, 1, "Hello");
/// ```
pub fn OpenCatalogA(lb: *LocaleBase, loc: ?*const locale.Locale, name: [*:0]const u8, tag_list: ?[*]const utility.TagItem) ?*locale.Catalog {
    const library = lb.iface();
    const ub = lb.utility_base;
    const default = if (loc == null) library.OpenLocale(null) else null;
    defer if (default) |held| library.CloseLocale(held);
    const languages = loc orelse default orelse return null;

    const builtin_tag = ub.GetTagData(locale.OC_BuiltInLanguage, @intFromPtr(_locale.english), tag_list);
    const builtin_language: [*:0]const u8 = @ptrFromInt(builtin_tag);
    const version: u32 = @truncate(ub.GetTagData(locale.OC_Version, 0, tag_list));
    const first: ?[*:0]const u8 = @ptrFromInt(ub.GetTagData(locale.OC_Language, 0, tag_list));
    const catalog_name = name[0.._locale.length(name)];

    var tried: usize = 0;
    while (tried <= languages.pref_languages.len) : (tried += 1) {
        const entry = if (tried == 0) first else languages.pref_languages[tried - 1];
        const language = entry orelse {
            if (tried == 0) continue;
            break;
        };
        const language_name = language[0.._locale.length(language)];
        if (_catalog.sameName(builtin_language, language_name)) return null;
        if (find(lb, catalog_name, language_name, version)) |catalog| return catalog;
    }
    return null;
}

/// The catalog in one language, loaded or read.
fn find(lb: *LocaleBase, name: []const u8, language: []const u8, version: u32) ?*locale.Catalog {
    const sys = lb.sys_base;
    sys.ObtainSemaphore(&lb.lock);
    if (_catalog.findLoaded(lb, name, language, version)) |ext| {
        ext.usage += 1;
        sys.ReleaseSemaphore(&lb.lock);
        return &ext.public;
    }
    sys.ReleaseSemaphore(&lb.lock);

    // Only a process reads files.
    const task = sys.FindTask(null) orelse return null;
    if (task.node.type != .process) return null;
    const dl = lb.dos_base;
    const old = _catalog.quiet(lb);
    defer _catalog.loud(lb, old);
    var path: [256]u8 = undefined;
    const dirs = [_][]const u8{ locale.program_catalogs_dir, locale.catalogs_dir };
    const read = for (dirs, 0..) |dir, index| {
        if (index == 0 and dl.GetProgramDir() == null) continue;
        const file_name = _catalog.pathOf(&path, dir, language, name) orelse continue;
        if (_catalog.load(lb, file_name, name, language, version)) |ext| break ext;
    } else return null;

    // Another task may have loaded it meanwhile: the one on the list wins.
    sys.ObtainSemaphore(&lb.lock);
    defer sys.ReleaseSemaphore(&lb.lock);
    if (_catalog.findLoaded(lb, name, language, version)) |ext| {
        ext.usage += 1;
        sys.FreeVec(read);
        return &ext.public;
    }
    sys.AddHead(&lb.catalogs, &read.public.link);
    return &read.public;
}
