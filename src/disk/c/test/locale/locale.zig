// SPDX-License-Identifier: MIT
//! Locale: the default locale shown, and its catalog's strings used.
//! Built against the SDK only.
//!
//!   Locale [DATE/K] [WORDS/M]
//!
//! It prints the country and the language of the default locale, the
//! languages it prefers, its time zone, and now in each of the country's
//! formats; a number with its digits grouped, and the currency's symbols.
//! With DATE, the text read by the country's short date. With WORDS, the
//! words in the language's order (SC_COLLATE2).
//!
//! Every line it prints is a string of its catalog (locale.cd): with
//! LOCALE:Catalogs/deutsch/c/test/locale.catalog and German preferred,
//! the lines are German; without, English. Its translations take their
//! values in another order where the sentence wants it (`%2$s`).

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const locale = sdk.locale;
const rdargs = dos.rdargs;
const strings = @import("strings");
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const Text = locale.Strings(strings);

pub const COMMAND_NAME = "Locale";
const VERSION_STRING = "\x00$VER: Locale 1.0 (29.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "DATE/K,WORDS/M";
const arg_date = 0;
const arg_words = 1;

/// The most words sorted.
const max_words = 64;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [2]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    var text = Text.open(sys);
    defer text.close();
    const lb = text.library orelse {
        _ = text.printf(dl, .MSG_NOLIBRARY, .{locale.LOCALENAME});
        return dos.RETURN_FAIL;
    };
    const loc = text.locale orelse return dos.RETURN_FAIL;

    _ = text.printf(dl, .MSG_COUNTRY, .{ loc.locale_name, loc.country_code });
    _ = text.printf(dl, .MSG_LANGUAGE, .{loc.language_name});
    _ = dl.PutStr(text.get(.MSG_PREFERRED));
    for (loc.pref_languages) |entry| {
        const language = entry orelse break;
        _ = dl.PutStr(" ");
        _ = dl.PutStr(language);
    }
    _ = dl.PutStr("\n");
    if (loc.time_zone) |zone| {
        _ = text.printf(dl, .MSG_ZONE, .{zone});
    } else {
        _ = text.printf(dl, .MSG_NOZONE, .{});
    }
    if (text.catalog) |catalog| {
        _ = text.printf(dl, .MSG_CATALOG, .{ catalog.language orelse "?", @as(u64, catalog.version), @as(u64, catalog.revision) });
    } else {
        _ = text.printf(dl, .MSG_NOCATALOG, .{});
    }

    var now: dos.DateStamp = undefined;
    _ = dl.DateStamp(&now);
    const labels = [_]strings.Id{ .MSG_DATETIME, .MSG_DATE, .MSG_TIME, .MSG_SHORTDATETIME, .MSG_SHORTDATE, .MSG_SHORTTIME };
    const formats = [labels.len][*:0]const u8{
        loc.date_time_format,       loc.date_format,       loc.time_format,
        loc.short_date_time_format, loc.short_date_format, loc.short_time_format,
    };
    inline for (labels, 0..) |label, at| {
        var written: [96]u8 = undefined;
        var out = locale.BufferHook.init(&written);
        lb.FormatDate(loc, formats[at], &now, &out.hook);
        _ = text.printf(dl, .MSG_FORMAT, .{ text.get(label), @as([*:0]const u8, @ptrCast(&written)) });
    }

    _ = text.printf(dl, .MSG_NUMBER, .{ @as(i32, 1234567), @as(i32, 1234567) });
    _ = text.printf(dl, .MSG_MONEY, .{ loc.mon_cs, loc.mon_small_cs, loc.mon_int_cs });

    if (argv[arg_date] != 0) {
        const given: [*:0]const u8 = @ptrFromInt(argv[arg_date]);
        var in = locale.StringHook.init(given);
        var date: dos.DateStamp = undefined;
        if (lb.ParseDate(loc, &date, loc.short_date_format, &in.hook)) {
            var written: [96]u8 = undefined;
            var out = locale.BufferHook.init(&written);
            lb.FormatDate(loc, loc.date_format, &date, &out.hook);
            _ = text.printf(dl, .MSG_PARSED, .{ given, @as([*:0]const u8, @ptrCast(&written)) });
        } else {
            _ = text.printf(dl, .MSG_NODATE, .{ given, loc.short_date_format });
        }
    }

    const words = rdargs.multi(argv[arg_words]);
    if (words.len > 0) {
        var order: [max_words][*:0]const u8 = undefined;
        const count = @min(words.len, max_words);
        for (words[0..count], 0..) |word, at| {
            var place = at;
            while (place > 0 and lb.StrnCmp(loc, order[place - 1], word, -1, locale.SC_COLLATE2) > 0) : (place -= 1) order[place] = order[place - 1];
            order[place] = word;
        }
        _ = dl.PutStr(text.get(.MSG_SORTED));
        for (order[0..count]) |word| {
            _ = dl.PutStr(" ");
            _ = dl.PutStr(word);
        }
        _ = dl.PutStr("\n");
    }
    return dos.RETURN_OK;
}
