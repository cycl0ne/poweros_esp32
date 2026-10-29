// SPDX-License-Identifier: MIT
//! Host tests of locale.library as a whole: the library made from its
//! ROM tag on the ROM's exec, utility and dos, with a RAM disk mounted as
//! both LOCALE: and ENVARC: for the test to write the settings, a
//! country, languages and catalogs onto, and spoken to through its jump
//! table.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const locale = sdk.locale;
const host = @import("host_rom");
const kexec = host.exec;
const locale_init = @import("../locale_init.zig");
const _base = @import("../locale_base.zig");
const _dos = @import("../dos/_dos.zig");
const _datetostr = @import("../dos/datetostr.zig");
const _strtodate = @import("../dos/strtodate.zig");
const _fault = @import("../dos/fault.zig");

const testing = std.testing;
const LocaleBase = sdk.interface.locale.LocaleBase;
const DosBase = sdk.interface.dos.DosBase;

test {
    _ = @import("../locale_lvo.zig");
}

/// The RAM disk behind LOCALE: and ENVARC:, answering the test process's
/// packets.
const Disk = struct {
    var port: exec.MsgPort = undefined;
    var disk: host.ram.RamDisk = undefined;
    var dl: *DosBase = undefined;

    fn wait(proc: *dos.Process, sys: *sdk.interface.exec.ExecBase) callconv(.c) *exec.Message {
        const pkt = dos.DosPacket.fromMessage(sys.GetMsg(&port).?);
        const reply = disk.answer(pkt);
        dl.ReplyPkt(pkt, reply.res1, reply.res2);
        return sys.GetMsg(&proc.msg_port).?;
    }
};

/// exec, utility and dos; a process with the disk behind it;
/// locale.library opened.
const Rig = struct {
    db: *host.dos.DosBase,
    proc: dos.Process = .{},
    saved: ?*kexec.Task = null,
    library: *exec.Library = undefined,
    lb: *LocaleBase = undefined,

    fn init(rig: *Rig) !void {
        rig.* = .{ .db = try host.dos.testSetUp() };
        rig.proc.task.node.name = "test process";
        host.dos_process.initMsgPort(&rig.proc);
        rig.saved = kexec.SysBase.cpu().this_task;
        kexec.SysBase.cpu().this_task = &rig.proc.task;

        const dl = rig.dosLib();
        Disk.dl = dl;
        Disk.port = .{ .flags = exec.PA_IGNORE };
        Disk.port.msg_list.init(.message);
        Disk.disk = try host.ram.RamDisk.init(rig.db.sys_base, dl, rig.db.utility_base, &Disk.port);
        for ([_][*:0]const u8{ "LOCALE", "ENVARC" }) |name| {
            const node = dl.MakeDosEntry(name, dos.DLT_DEVICE).?;
            node.task = &Disk.port;
            try testing.expect(dl.AddDosEntry(node));
        }
        rig.proc.pkt_wait = &Disk.wait;
        for ([_][*:0]const u8{ "LOCALE:Countries", "LOCALE:Languages", "ENVARC:Sys" }) |dir| {
            dl.UnLock(dl.CreateDir(dir) orelse return error.NoDir);
        }

        const lib = kexec.InitResident(kexec.SysBase, &locale_init.locale_library_tag, null) orelse return error.NoLocale;
        rig.library = @ptrCast(@alignCast(lib));
        rig.lb = @ptrCast(rig.sysLib().OpenLibrary(locale.LOCALENAME, 1) orelse return error.NoBase);
    }

    fn sysLib(_: *Rig) *sdk.interface.exec.ExecBase {
        return kexec.SysBase.iface();
    }

    fn dosLib(rig: *Rig) *DosBase {
        return host.dos.testBase(rig.db);
    }

    /// The library as it is inside.
    fn real(rig: *Rig) *_base.LocaleBase {
        return @ptrCast(@alignCast(rig.lb));
    }

    /// dos's own functions put back, the library closed and expunged, the
    /// disk taken down, and nothing left behind.
    fn deinit(rig: *Rig) !void {
        _ = _dos.remove(rig.real());
        rig.sysLib().CloseLibrary(rig.lb.lib());
        _ = rig.sysLib().RemLibrary(rig.library);
        try testing.expect(kexec.FindName(kexec.SysBase, &kexec.SysBase.lib_list, locale.LOCALENAME) == null);
        Disk.disk.deinit();
        kexec.SysBase.cpu().this_task = rig.saved.?;
        try host.dos.testTearDown(rig.db);
        kexec.deinit();
    }

    /// A file on the disk.
    fn write(rig: *Rig, name: [*:0]const u8, bytes: []const u8) !void {
        const dl = rig.dosLib();
        const fh = dl.Open(name, dos.MODE_NEWFILE) orelse return error.NoFile;
        try testing.expectEqual(@as(isize, @intCast(bytes.len)), dl.Write(fh, bytes.ptr, @intCast(bytes.len)));
        try testing.expect(dl.Close(fh));
    }
};

fn span(text: ?[*:0]const u8) []const u8 {
    return std.mem.span(text orelse return "(null)");
}

const sverige_country =
    \\# Sweden.
    \\CODE=SE
    \\TELEPHONE=46
    \\MEASURE=METRIC
    \\FIRSTDAY=MONDAY
    \\LANGUAGE=svenska
    \\DATE="%A %e %B %Y"
    \\SHORTDATE=%Y-%m-%d
    \\DECIMAL=,
    \\GROUP=" "
    \\GROUPING=3
    \\FRACGROUPING=NONE
    \\CURRENCY=kr
    \\SMALLCURRENCY=öre
    \\INTCURRENCY=SEK
    \\NEGATIVESIGNAT=BEFORE
    \\NEGATIVECURRENCYAT=AFTER
    \\POSITIVESPACE=YES
    \\SOMETHINGLATER=whatever
    \\
;

const svenska_language =
    "\xEF\xBB\xBF# Swedish, with a mark at the start.\n" ++
    "DAY_1=söndag DAY_2=måndag\n" ++
    "MON_1=januari\n" ++
    "OPENQUOTE=\xE2\x80\x9D\n" ++
    "AFTER_Z=Å,ÄÆ,ÖØ\n";

test "the library's own locale: English, the dates dos writes, and its words" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    const lb = rig.lb;

    const loc = lb.OpenLocale(null) orelse return error.NoLocale;
    try testing.expectEqualStrings("english", span(loc.language_name));
    try testing.expectEqualStrings("english", span(loc.pref_languages[0]));
    try testing.expectEqual(@as(?[*:0]const u8, null), loc.pref_languages[1]);
    try testing.expectEqualStrings("%d-%b-%Y", span(loc.short_date_format));
    try testing.expectEqualStrings("%H:%M:%S", span(loc.short_time_format));
    try testing.expectEqual(locale.CODESET_LATIN1, loc.code_set);
    try testing.expectEqualStrings("Sunday", span(lb.GetLocaleStr(loc, locale.DAY_1)));
    try testing.expectEqualStrings("Dec", span(lb.GetLocaleStr(loc, locale.ABMON_12)));
    try testing.expectEqualStrings("Future", span(lb.GetLocaleStr(loc, locale.FUTURESTR)));
    try testing.expectEqual(@as(?[*:0]const u8, null), lb.GetLocaleStr(loc, 0));
    try testing.expectEqual(@as(?[*:0]const u8, null), lb.GetLocaleStr(loc, locale.MAXSTRMSG));
    // The same one again: the default is shared.
    const again = lb.OpenLocale(null).?;
    try testing.expectEqual(loc, again);
    lb.CloseLocale(again);
    lb.CloseLocale(loc);
    lb.CloseLocale(null);
}

test "characters: Latin-1's classes and cases, in any locale" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    const lb = rig.lb;
    const loc = lb.OpenLocale(null).?;
    defer lb.CloseLocale(loc);

    try testing.expect(lb.IsAlpha(loc, 'q') and lb.IsAlpha(loc, 0xC4) and lb.IsAlpha(loc, 0xDF) and lb.IsAlpha(loc, 0xAA));
    try testing.expect(!lb.IsAlpha(loc, 0xD7) and !lb.IsAlpha(loc, '1') and !lb.IsAlpha(loc, 0x100));
    try testing.expect(lb.IsUpper(loc, 0xC4) and !lb.IsUpper(loc, 0xE4) and lb.IsLower(loc, 0xE4) and lb.IsLower(loc, 0xB5));
    try testing.expect(!lb.IsUpper(loc, 0xAA) and !lb.IsLower(loc, 0xAA));
    try testing.expect(lb.IsDigit(loc, '7') and !lb.IsDigit(loc, 0xB2) and lb.IsXDigit(loc, 'f') and !lb.IsXDigit(loc, 'g'));
    try testing.expect(lb.IsAlNum(loc, '0') and lb.IsAlNum(loc, 0xF1) and !lb.IsAlNum(loc, '_'));
    try testing.expect(lb.IsSpace(loc, ' ') and lb.IsSpace(loc, '\t') and lb.IsSpace(loc, 0xA0) and !lb.IsSpace(loc, 0x85));
    try testing.expect(lb.IsCntrl(loc, 0) and lb.IsCntrl(loc, 0x7F) and lb.IsCntrl(loc, 0x9F) and !lb.IsCntrl(loc, 0xA0));
    try testing.expect(lb.IsPrint(loc, ' ') and lb.IsPrint(loc, 0xA0) and !lb.IsGraph(loc, ' ') and !lb.IsGraph(loc, 0xA0));
    try testing.expect(lb.IsGraph(loc, 0xA1) and lb.IsPunct(loc, 0xA1) and lb.IsPunct(loc, 0xD7) and !lb.IsPunct(loc, 0xBA));
    try testing.expect(lb.IsPunct(loc, '!') and lb.IsPunct(loc, '~') and !lb.IsPunct(loc, 'a') and !lb.IsPrint(loc, 0x80));
    try testing.expectEqual(@as(u32, 'a'), lb.ConvToLower(loc, 'A'));
    try testing.expectEqual(@as(u32, 0xE4), lb.ConvToLower(loc, 0xC4));
    try testing.expectEqual(@as(u32, 0xD7), lb.ConvToLower(loc, 0xD7));
    try testing.expectEqual(@as(u32, 0xDE), lb.ConvToUpper(loc, 0xFE));
    try testing.expectEqual(@as(u32, 0xDF), lb.ConvToUpper(loc, 0xDF));
    try testing.expectEqual(@as(u32, 0xFF), lb.ConvToUpper(loc, 0xFF));
    try testing.expectEqual(@as(u32, 0x263A), lb.ConvToUpper(loc, 0x263A));
}

/// `order` sorted by `compare_type` in `loc`, StrnCmp's answer and the
/// keys' byte order the same for every pair.
fn expectOrder(lb: *LocaleBase, loc: *locale.Locale, compare_type: u32, order: []const [*:0]const u8) !void {
    for (order, 0..) |one, i| {
        var key_one: [64]u8 = undefined;
        _ = lb.StrConvert(loc, one, &key_one, key_one.len, compare_type);
        for (order, 0..) |two, j| {
            var key_two: [64]u8 = undefined;
            _ = lb.StrConvert(loc, two, &key_two, key_two.len, compare_type);
            const want: i32 = if (i < j) -1 else if (i > j) 1 else 0;
            const got = lb.StrnCmp(loc, one, two, -1, compare_type);
            if (got != want) {
                std.debug.print("StrnCmp({s}, {s}, {d}) = {d}, not {d}\n", .{ one, two, compare_type, got, want });
                return error.WrongOrder;
            }
            const by_key: i32 = switch (std.mem.order(u8, std.mem.sliceTo(&key_one, 0), std.mem.sliceTo(&key_two, 0))) {
                .lt => -1,
                .eq => 0,
                .gt => 1,
            };
            if (by_key != want) {
                std.debug.print("keys of {s} and {s} ({d}) order {d}, not {d}\n", .{ one, two, compare_type, by_key, want });
                return error.WrongKeyOrder;
            }
        }
    }
}

test "StrnCmp and StrConvert: case left out, accents left out, then case and accent deciding" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    const lb = rig.lb;
    const loc = lb.OpenLocale(null).?;
    defer lb.CloseLocale(loc);

    // SC_ASCII: the capitals, by their codes.
    try testing.expectEqual(@as(i32, 0), lb.StrnCmp(loc, "Hello", "hELLO", -1, locale.SC_ASCII));
    try testing.expectEqual(@as(i32, -1), lb.StrnCmp(loc, "abc", "abd", -1, locale.SC_ASCII));
    try testing.expectEqual(@as(i32, -1), lb.StrnCmp(loc, "ab", "abc", -1, locale.SC_ASCII));
    try testing.expectEqual(@as(i32, 0), lb.StrnCmp(loc, "abcX", "abcY", 3, locale.SC_ASCII));
    try testing.expectEqual(@as(i32, 0), lb.StrnCmp(loc, "x", "y", 0, locale.SC_ASCII));
    try testing.expectEqual(@as(i32, 0), lb.StrnCmp(loc, "same", "SAME", -1, 99));
    // SC_COLLATE1: ä is an a, and a digit or a mark comes before a letter.
    try testing.expectEqual(@as(i32, 0), lb.StrnCmp(loc, "B\xE4r", "bar", -1, locale.SC_COLLATE1));
    try expectOrder(lb, loc, locale.SC_COLLATE1, &.{ "1", "_x", "a", "b\xE4r", "bas", "z" });
    // SC_COLLATE2: the same, then the first byte that differs.
    try expectOrder(lb, loc, locale.SC_COLLATE2, &.{ "Apple", "apple", "\xE4pple", "applf", "Zebra" });
    try expectOrder(lb, loc, locale.SC_ASCII, &.{ "a", "B", "c", "_" });

    // A key cut short still ends with a NUL, and says how long it is.
    var short: [4]u8 = undefined;
    try testing.expectEqual(@as(u32, 3), lb.StrConvert(loc, "abcdef", &short, short.len, locale.SC_COLLATE2));
    try testing.expectEqual(@as(u8, 0), short[3]);
    try testing.expectEqual(@as(u32, 0), lb.StrConvert(loc, "abc", &short, 0, locale.SC_ASCII));
}

test "OpenLocale from files: the country's formats, the language's words and order, UTF-8 made Latin-1" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    const lb = rig.lb;
    try rig.write("LOCALE:Countries/sverige.country", sverige_country);
    try rig.write("LOCALE:Languages/svenska.language", svenska_language);
    try rig.write("ENVARC:Sys/timezone", "# Stockholm\nCET-1CEST,M3.5.0,M10.5.0/3\n");
    // The country names its language; the settings name none.
    try rig.write("LOCALE:sverige.prefs", "# Sweden\nCOUNTRY=sverige.country\n");

    const loc = lb.OpenLocale("LOCALE:sverige.prefs") orelse return error.NoLocale;
    defer lb.CloseLocale(loc);
    try testing.expectEqualStrings("sverige", span(loc.locale_name));
    try testing.expectEqualStrings("svenska", span(loc.language_name));
    try testing.expectEqualStrings("svenska", span(loc.pref_languages[0]));
    try testing.expectEqualStrings("SE", span(loc.country_code));
    try testing.expectEqual(@as(u32, 46), loc.telephone_code);
    try testing.expectEqual(locale.MS_ISO, loc.measuring_system);
    try testing.expectEqual(locale.CT_7MON, loc.calendar_type);
    try testing.expectEqualStrings("%A %e %B %Y", span(loc.date_format));
    try testing.expectEqualStrings("%Y-%m-%d", span(loc.short_date_format));
    // Not in the file: the library's own.
    try testing.expectEqualStrings("%H:%M:%S", span(loc.short_time_format));
    try testing.expectEqualStrings(",", span(loc.decimal_point));
    try testing.expectEqualStrings(" ", span(loc.group_separator));
    try testing.expectEqualSlices(u8, &.{ 3, 0 }, loc.grouping[0..2]);
    try testing.expectEqual(locale.GROUPING_NONE, loc.frac_grouping[0]);
    try testing.expectEqualStrings("\xF6re", span(loc.mon_small_cs));
    try testing.expectEqual(locale.SP_PREC_ALL, loc.mon_negative_sign_pos);
    try testing.expectEqual(locale.CSP_SUCCEEDS, loc.mon_negative_cs_pos);
    try testing.expectEqual(locale.SS_SPACE, loc.mon_positive_space_sep);
    try testing.expectEqualStrings("CET-1CEST,M3.5.0,M10.5.0/3", span(loc.time_zone));

    // The words: söndag in Latin-1, a quote Latin-1 lacks as ?, English
    // for what the file leaves out.
    try testing.expectEqualStrings("s\xF6ndag", span(lb.GetLocaleStr(loc, locale.DAY_1)));
    try testing.expectEqualStrings("m\xE5ndag", span(lb.GetLocaleStr(loc, locale.DAY_2)));
    try testing.expectEqualStrings("?", span(lb.GetLocaleStr(loc, locale.OPENQUOTE)));
    try testing.expectEqualStrings("Saturday", span(lb.GetLocaleStr(loc, locale.DAY_7)));

    // Swedish order: Å, then Ä and Æ, then Ö and Ø, all after Z.
    try expectOrder(lb, loc, locale.SC_COLLATE1, &.{ "a", "o", "z", "\xC5", "\xE4", "\xF6" });
    try testing.expectEqual(@as(i32, 0), lb.StrnCmp(loc, "\xC4", "\xC6", -1, locale.SC_COLLATE1));
    try testing.expectEqual(@as(i32, 0), lb.StrnCmp(loc, "\xF6", "\xD8", -1, locale.SC_COLLATE1));
    try expectOrder(lb, loc, locale.SC_COLLATE2, &.{ "Zorn", "zorn", "\xC5sa", "\xE5sa", "\xC4ra", "\xE4ra", "\xD6l" });
    // English, beside it, keeps å with a.
    const english = lb.OpenLocale(null).?;
    defer lb.CloseLocale(english);
    try expectOrder(lb, english, locale.SC_COLLATE1, &.{ "a", "\xC5sa", "o", "z" });
}

test "OpenLocale: the settings' languages in order, the first with a file taken, English needing none" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    const lb = rig.lb;
    try rig.write("LOCALE:Countries/sverige.country", sverige_country);
    try rig.write("LOCALE:both.prefs", "COUNTRY=sverige\nLANGUAGES=\"klingon, english\"\n");
    try rig.write("LOCALE:none.prefs", "LANGUAGES=klingon\n");
    try rig.write("LOCALE:nocountry.prefs", "COUNTRY=atlantis\n");
    try rig.write("LOCALE:Countries/broken.country", "MEASURE=FURLONGS\n");
    try rig.write("LOCALE:broken.prefs", "COUNTRY=broken\n");
    try rig.write("LOCALE:quote.prefs", "COUNTRY=\"sverige\n");
    const dl = rig.dosLib();

    const both = lb.OpenLocale("LOCALE:both.prefs") orelse return error.NoLocale;
    try testing.expectEqualStrings("english", span(both.language_name));
    try testing.expectEqualStrings("klingon", span(both.pref_languages[0]));
    try testing.expectEqualStrings("english", span(both.pref_languages[1]));
    try testing.expectEqual(@as(?[*:0]const u8, null), both.pref_languages[2]);
    try testing.expectEqualStrings("Sunday", span(lb.GetLocaleStr(both, locale.DAY_1)));
    try testing.expectEqualStrings("SE", span(both.country_code));
    // No time zone written: none.
    try testing.expectEqual(@as(?[*:0]const u8, null), both.time_zone);
    lb.CloseLocale(both);

    try testing.expectEqual(@as(?*locale.Locale, null), lb.OpenLocale("LOCALE:none.prefs"));
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, dl.IoErr());
    try testing.expectEqual(@as(?*locale.Locale, null), lb.OpenLocale("LOCALE:nocountry.prefs"));
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, dl.IoErr());
    try testing.expectEqual(@as(?*locale.Locale, null), lb.OpenLocale("LOCALE:broken.prefs"));
    try testing.expectEqual(dos.ERROR_OBJECT_WRONG_TYPE, dl.IoErr());
    try testing.expectEqual(@as(?*locale.Locale, null), lb.OpenLocale("LOCALE:quote.prefs"));
    try testing.expectEqual(dos.ERROR_UNMATCHED_QUOTES, dl.IoErr());
    try testing.expectEqual(@as(?*locale.Locale, null), lb.OpenLocale("LOCALE:missing.prefs"));
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, dl.IoErr());
}

test "SetDefaultLocale: the new default answered by OpenLocale(null), the one before handed back" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    const lb = rig.lb;
    try rig.write("LOCALE:Countries/sverige.country", sverige_country);
    try rig.write("LOCALE:Languages/svenska.language", svenska_language);
    try rig.write("LOCALE:sverige.prefs", "COUNTRY=sverige\n");

    const held = lb.OpenLocale(null).?;
    const swedish = lb.OpenLocale("LOCALE:sverige.prefs").?;
    const before = lb.SetDefaultLocale(swedish).?;
    try testing.expectEqualStrings("english", span(before.language_name));
    lb.CloseLocale(before);
    lb.CloseLocale(swedish);
    // Still there: the library holds it as the default.
    const now = lb.OpenLocale(null).?;
    try testing.expectEqual(swedish, now);
    try testing.expectEqualStrings("svenska", span(now.language_name));
    lb.CloseLocale(now);
    // The one opened before is the one it had.
    try testing.expectEqualStrings("english", span(held.language_name));
    lb.CloseLocale(held);
    // Back to the library's own, and the Swedish one freed with its hold.
    const real: *_base.LocaleBase = @ptrCast(@alignCast(lb));
    lb.CloseLocale(lb.SetDefaultLocale(&real.builtin.public));
    try testing.expectEqual(@as(u32, 1), real.builtin.usage);
}

/// The DateStamp of a day and a time.
fn stampOf(year: i32, month: u8, day: u8, hour: i32, minute: i32, second: i32) dos.DateStamp {
    const days = dos.timezone.daysFromCivil(year, month, day) - dos.timezone.daysFromCivil(1978, 1, 1);
    return .{ .days = @intCast(days), .minute = hour * 60 + minute, .tick = second * 50 };
}

/// What FormatDate writes.
fn formatted(lb: *LocaleBase, loc: *locale.Locale, into: []u8, template: [*:0]const u8, date: dos.DateStamp) []const u8 {
    var out = locale.BufferHook.init(into);
    lb.FormatDate(loc, template, &date, &out.hook);
    return out.text();
}

/// What ParseDate reads, or null.
fn parsed(lb: *LocaleBase, loc: *locale.Locale, template: [*:0]const u8, text: [*:0]const u8) ?dos.DateStamp {
    var in = locale.StringHook.init(text);
    var date: dos.DateStamp = .{ .days = -1 };
    if (!lb.ParseDate(loc, &date, template, &in.hook)) return null;
    return date;
}

test "FormatDate: every conversion, the language's words and the time zone's name" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    const lb = rig.lb;
    const loc = lb.OpenLocale(null).?;
    defer lb.CloseLocale(loc);
    var text: [128]u8 = undefined;

    // Thursday 29 October 2026, the 302nd day.
    const date = stampOf(2026, 10, 29, 14, 5, 9);
    try testing.expectEqualStrings("29-Oct-2026 14:05:09", formatted(lb, loc, &text, "%d-%b-%Y %H:%M:%S", date));
    try testing.expectEqualStrings("Thursday 29 October 26 02:05 PM 302 4 43 43 %", formatted(lb, loc, &text, "%A %e %B %y %I:%M %p %j %w %U %W %%", date));
    try testing.expectEqualStrings("Thu Oct 29 14:05:09 2026", formatted(lb, loc, &text, "%c", date));
    try testing.expectEqualStrings("10/29/26|14:05:09|14:05|02:05:09 PM|2|14", formatted(lb, loc, &text, "%x|%X|%R|%r|%Q|%q", date));
    try testing.expectEqualStrings("Thursday, 29 October 2026", formatted(lb, loc, &text, loc.date_format, date));
    // Small numbers: a blank before the day for %e, none for %q and %Q.
    const early = stampOf(2026, 3, 5, 0, 7, 0);
    try testing.expectEqualStrings(" 5|05|0|12|AM|064", formatted(lb, loc, &text, "%e|%d|%q|%I|%p|%j", early));
    // No zone: %Z writes nothing.
    try testing.expectEqualStrings("[]", formatted(lb, loc, &text, "[%Z]", date));
    // A buffer too short keeps what fits, and its NUL.
    var small: [6]u8 = undefined;
    try testing.expectEqualStrings("29-Oc", formatted(lb, loc, &small, "%d-%b-%Y", date));
    try testing.expectEqual(@as(u8, 0), small[5]);

    try rig.write("LOCALE:Countries/sverige.country", sverige_country);
    try rig.write("LOCALE:Languages/svenska.language", svenska_language);
    try rig.write("ENVARC:Sys/timezone", "CET-1CEST,M3.5.0,M10.5.0/3\n");
    try rig.write("LOCALE:sverige.prefs", "COUNTRY=sverige\n");
    const swedish = lb.OpenLocale("LOCALE:sverige.prefs").?;
    defer lb.CloseLocale(swedish);
    // A Sunday in winter time, and a day in summer time.
    try testing.expectEqualStrings("s\xF6ndag  1 November 2026 CET", formatted(lb, swedish, &text, "%A %e %B %Y %Z", stampOf(2026, 11, 1, 12, 0, 0)));
    try testing.expectEqualStrings("2026-07-01 CEST", formatted(lb, swedish, &text, "%Y-%m-%d %Z", stampOf(2026, 7, 1, 12, 0, 0)));
    try testing.expectEqualStrings("januari", formatted(lb, swedish, &text, "%B", stampOf(2026, 1, 1, 0, 0, 0)));
}

test "ParseDate: what FormatDate writes read back, names and numbers, and what is no date" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    const lb = rig.lb;
    const loc = lb.OpenLocale(null).?;
    defer lb.CloseLocale(loc);

    const date = stampOf(2026, 10, 29, 14, 5, 9);
    try testing.expectEqual(date, parsed(lb, loc, "%d-%b-%Y %H:%M:%S", "29-Oct-2026 14:05:09").?);
    try testing.expectEqual(date, parsed(lb, loc, "%A %e %B %Y %I:%M:%S %p", "thursday 29 OCTOBER 2026 2:05:09 pm").?);
    try testing.expectEqual(date, parsed(lb, loc, "%c", "Thu Oct 29 14:05:09 2026").?);
    // Short names, numbers for months, two-digit years either side of 78.
    try testing.expectEqual(stampOf(2026, 10, 29, 0, 0, 0), parsed(lb, loc, "%d.%m.%y", "29.10.26").?);
    try testing.expectEqual(stampOf(1985, 3, 1, 0, 0, 0), parsed(lb, loc, "%x", "03/01/85").?);
    try testing.expectEqual(stampOf(2026, 10, 1, 0, 0, 0), parsed(lb, loc, "%b %Y", "  10   2026  ").?);
    // A time alone is on the first day.
    try testing.expectEqual(dos.DateStamp{ .days = 0, .minute = 12 * 60, .tick = 0 }, parsed(lb, loc, "%I:%M %p", "12:00 PM").?);
    try testing.expectEqual(dos.DateStamp{ .days = 0, .minute = 30, .tick = 0 }, parsed(lb, loc, "%I:%M %p", "12:30 am").?);
    // No date: no such day, a field out of range, text left over or
    // missing, a conversion it does not read.
    try testing.expectEqual(@as(?dos.DateStamp, null), parsed(lb, loc, "%d-%b-%Y", "31-Feb-2026"));
    try testing.expectEqual(@as(?dos.DateStamp, null), parsed(lb, loc, "%H:%M", "24:00"));
    try testing.expectEqual(@as(?dos.DateStamp, null), parsed(lb, loc, "%H:%M", "12:00 extra"));
    try testing.expectEqual(@as(?dos.DateStamp, null), parsed(lb, loc, "%H:%M:%S", "12:00"));
    try testing.expectEqual(@as(?dos.DateStamp, null), parsed(lb, loc, "%Y", "1977"));
    try testing.expectEqual(@as(?dos.DateStamp, null), parsed(lb, loc, "%b", "Smarch"));
    try testing.expectEqual(@as(?dos.DateStamp, null), parsed(lb, loc, "%k", "1"));
}

/// What FormatString writes for `args`, and how far it read the stream.
fn formattedString(lb: *LocaleBase, loc: *locale.Locale, into: []u8, template: [*:0]const u8, args: anytype) struct { text: []const u8, used: usize } {
    var out = locale.BufferHook.init(into);
    const stream = exec.fmtStream(args);
    const past = lb.FormatString(loc, template, &stream, &out.hook);
    return .{ .text = out.text(), .used = @intFromPtr(past) - @intFromPtr(&stream) };
}

test "FormatString: RawDoFmt's conversions, values by their place, digits grouped" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    const lb = rig.lb;
    const loc = lb.OpenLocale(null).?;
    defer lb.CloseLocale(loc);
    var text: [128]u8 = undefined;

    const plain = formattedString(lb, loc, &text, "%s has %ld bytes, %u%% %x %c", .{ "disk", @as(i64, -5), @as(u32, 50), @as(u32, 255), @as(u32, 'Q') });
    try testing.expectEqualStrings("disk has -5 bytes, 50% FF Q", plain.text);
    try testing.expectEqual(@as(usize, @sizeOf(usize) + 8 + 4 + 4 + 4), plain.used);
    try testing.expectEqualStrings("   42|42   |-0042|abc|", formattedString(lb, loc, &text, "%5d|%-5d|%05d|%.3s|%s", .{ @as(i32, 42), @as(i32, 42), @as(i32, -42), "abcdef", @as(?[*:0]const u8, null) }).text);
    // By place: the second value first, then the first.
    const placed = formattedString(lb, loc, &text, "%2$s, %1$s!", .{ "world", "hello" });
    try testing.expectEqualStrings("hello, world!", placed.text);
    try testing.expectEqual(@as(usize, 2 * @sizeOf(usize)), placed.used);
    try testing.expectEqualStrings("7 files in work", formattedString(lb, loc, &text, "%2$ld files in %1$s", .{ "work", @as(i64, 7) }).text);
    // Grouped by threes with the locale's separator; %d does not group.
    try testing.expectEqualStrings("1,234,567|-1,234|999|0|1234567|4,294,967,295", formattedString(lb, loc, &text, "%D|%D|%D|%U|%d|%U", .{ @as(i32, 1234567), @as(i32, -1234), @as(i32, 999), @as(u32, 0), @as(i32, 1234567), @as(u32, 4294967295) }).text);
    try testing.expectEqualStrings("  -1,234", formattedString(lb, loc, &text, "%8D", .{@as(i32, -1234)}).text);

    try rig.write("LOCALE:Countries/sverige.country", sverige_country);
    try rig.write("LOCALE:Countries/indien.country", "GROUP=, GROUPING=3,2\n");
    try rig.write("LOCALE:sverige.prefs", "COUNTRY=sverige\nLANGUAGES=english\n");
    try rig.write("LOCALE:indien.prefs", "COUNTRY=indien\n");
    const swedish = lb.OpenLocale("LOCALE:sverige.prefs").?;
    defer lb.CloseLocale(swedish);
    try testing.expectEqualStrings("1 234 567", formattedString(lb, swedish, &text, "%D", .{@as(i32, 1234567)}).text);
    const indian = lb.OpenLocale("LOCALE:indien.prefs").?;
    defer lb.CloseLocale(indian);
    try testing.expectEqualStrings("12,34,56,789", formattedString(lb, indian, &text, "%lU", .{@as(u64, 123456789)}).text);
}

/// A string of a catalog file.
const CatalogString = struct { id: i32, text: []const u8 };

/// A CTLG file of `strings` in `language`, its version from `ver`.
fn catalogFile(into: []u8, ver: []const u8, language: []const u8, code_set: u32, strings: []const CatalogString) []const u8 {
    var at: usize = 12;
    const put = struct {
        fn bytes(buffer: []u8, place: *usize, data: []const u8) void {
            @memcpy(buffer[place.*..][0..data.len], data);
            place.* += data.len;
        }
        fn be(buffer: []u8, place: *usize, value: u32) void {
            std.mem.writeInt(u32, buffer[place.*..][0..4], value, .big);
            place.* += 4;
        }
        fn chunk(buffer: []u8, place: *usize, id: *const [4]u8, parts: []const []const u8) void {
            bytes(buffer, place, id);
            var length: usize = 0;
            for (parts) |part| length += part.len;
            be(buffer, place, @intCast(length));
            for (parts) |part| bytes(buffer, place, part);
            if (length & 1 != 0) bytes(buffer, place, "\x00");
        }
    };
    put.chunk(into, &at, "FVER", &.{ ver, "\x00" });
    put.chunk(into, &at, "LANG", &.{ language, "\x00" });
    var cset: [32]u8 = @splat(0);
    std.mem.writeInt(u32, cset[0..4], code_set, .big);
    put.chunk(into, &at, "CSET", &.{&cset});
    put.bytes(into, &at, "STRS");
    const length_at = at;
    at += 4;
    for (strings) |string| {
        put.be(into, &at, @bitCast(string.id));
        put.be(into, &at, @intCast(string.text.len + 1));
        put.bytes(into, &at, string.text);
        into[at] = 0;
        at += 1;
        while (at & 3 != 0) : (at += 1) into[at] = 0;
    }
    std.mem.writeInt(u32, into[length_at..][0..4], @intCast(at - length_at - 4), .big);
    @memcpy(into[0..4], "FORM");
    std.mem.writeInt(u32, into[4..8], @intCast(at - 8), .big);
    @memcpy(into[8..12], "CTLG");
    return into[0..at];
}

test "OpenCatalogA, GetCatalogStr, CloseCatalog: a language's strings, loaded once, by id, and the version asked for" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    const lb = rig.lb;
    const dl = rig.dosLib();
    for ([_][*:0]const u8{ "LOCALE:Catalogs", "LOCALE:Catalogs/deutsch", "LOCALE:Catalogs/deutsch/sys", "LOCALE:Catalogs/svenska" }) |dir| {
        dl.UnLock(dl.CreateDir(dir) orelse return error.NoDir);
    }
    var file: [512]u8 = undefined;
    // Out of order, and in UTF-8: read sorted and in Latin-1.
    try rig.write("LOCALE:Catalogs/deutsch/sys/test.catalog", catalogFile(&file, "$VER: sys/test.catalog 2.3 (29.10.2026)", "deutsch", locale.CODESET_UTF8, &.{
        .{ .id = 7, .text = "Grüße" },
        .{ .id = -100, .text = "Datenträger" },
        .{ .id = 1, .text = "eins" },
    }));
    try rig.write("LOCALE:Catalogs/svenska/test.catalog", "FORM\x00\x00\x00\x04ILBM");

    const loc = lb.OpenLocale(null).?;
    defer lb.CloseLocale(loc);
    const by_name = [_]utility.TagItem{ .{ .tag = locale.OC_Language, .data = @intFromPtr("deutsch") }, .{} };
    const catalog = lb.OpenCatalogA(loc, "sys/test.catalog", &by_name) orelse return error.NoCatalog;
    try testing.expectEqualStrings("sys/test.catalog", span(catalog.link.name));
    try testing.expectEqualStrings("deutsch", span(catalog.language));
    try testing.expectEqual(@as(u32, 2), catalog.version);
    try testing.expectEqual(@as(u32, 3), catalog.revision);
    try testing.expectEqual(locale.CODESET_LATIN1, catalog.code_set);
    try testing.expectEqualStrings("Gr\xfc\xdfe", span(lb.GetCatalogStr(catalog, 7, "Greetings")));
    try testing.expectEqualStrings("Datentr\xe4ger", span(lb.GetCatalogStr(catalog, -100, "Volume")));
    try testing.expectEqualStrings("eins", span(lb.GetCatalogStr(catalog, 1, "one")));
    try testing.expectEqualStrings("two", span(lb.GetCatalogStr(catalog, 2, "two")));
    try testing.expectEqualStrings("none", span(lb.GetCatalogStr(null, 1, "none")));

    // Loaded once: the file gone, it is still there, the same catalog.
    try testing.expect(dl.DeleteFile("LOCALE:Catalogs/deutsch/sys/test.catalog"));
    const again = lb.OpenCatalogA(null, "SYS/Test.Catalog", &by_name) orelse return error.NoCatalog;
    try testing.expectEqual(catalog, again);
    // Of the version asked for, or none.
    const version_2 = [_]utility.TagItem{ .{ .tag = locale.OC_Language, .data = @intFromPtr("deutsch") }, .{ .tag = locale.OC_Version, .data = 2 }, .{} };
    const version_3 = [_]utility.TagItem{ .{ .tag = locale.OC_Language, .data = @intFromPtr("deutsch") }, .{ .tag = locale.OC_Version, .data = 3 }, .{} };
    const exact = lb.OpenCatalogA(loc, "sys/test.catalog", &version_2) orelse return error.NoCatalog;
    try testing.expectEqual(catalog, exact);
    try testing.expectEqual(@as(?*locale.Catalog, null), lb.OpenCatalogA(loc, "sys/test.catalog", &version_3));
    lb.CloseCatalog(exact);
    lb.CloseCatalog(again);
    lb.CloseCatalog(catalog);
    lb.CloseCatalog(null);

    // The strings built in are in the language asked for: no catalog.
    const built_in = [_]utility.TagItem{ .{ .tag = locale.OC_Language, .data = @intFromPtr("deutsch") }, .{ .tag = locale.OC_BuiltInLanguage, .data = @intFromPtr("deutsch") }, .{} };
    try testing.expectEqual(@as(?*locale.Catalog, null), lb.OpenCatalogA(loc, "sys/test.catalog", &built_in));
    // The locale's own languages: English is built in, and there is no
    // catalog of it.
    try testing.expectEqual(@as(?*locale.Catalog, null), lb.OpenCatalogA(loc, "sys/test.catalog", null));
    // A file that is no catalog, and none at all.
    const swedish = [_]utility.TagItem{ .{ .tag = locale.OC_Language, .data = @intFromPtr("svenska") }, .{} };
    try testing.expectEqual(@as(?*locale.Catalog, null), lb.OpenCatalogA(loc, "test.catalog", &swedish));
    try testing.expectEqual(@as(?*locale.Catalog, null), lb.OpenCatalogA(loc, "missing.catalog", &by_name));
}

test "OpenCatalogA: the locale's languages in order, the first with a catalog taken" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    const lb = rig.lb;
    const dl = rig.dosLib();
    for ([_][*:0]const u8{ "LOCALE:Catalogs", "LOCALE:Catalogs/deutsch" }) |dir| {
        dl.UnLock(dl.CreateDir(dir) orelse return error.NoDir);
    }
    var file: [256]u8 = undefined;
    try rig.write("LOCALE:Catalogs/deutsch/c.catalog", catalogFile(&file, "$VER: c.catalog 1.0 (29.10.2026)", "deutsch", 0, &.{.{ .id = 0, .text = "Hallo" }}));
    try rig.write("LOCALE:both.prefs", "LANGUAGES=\"svenska, deutsch, english\"\n");
    try rig.write("LOCALE:english.prefs", "LANGUAGES=\"english, deutsch\"\n");

    const both = lb.OpenLocale("LOCALE:both.prefs").?;
    defer lb.CloseLocale(both);
    const catalog = lb.OpenCatalogA(both, "c.catalog", null) orelse return error.NoCatalog;
    try testing.expectEqualStrings("Hallo", span(lb.GetCatalogStr(catalog, 0, "Hello")));
    lb.CloseCatalog(catalog);
    // English, the language built in, comes first: the strings built in.
    const english = lb.OpenLocale("LOCALE:english.prefs").?;
    defer lb.CloseLocale(english);
    try testing.expectEqual(@as(?*locale.Catalog, null), lb.OpenCatalogA(english, "c.catalog", null));
}

const deutschland_country = "CODE=DE\nLANGUAGE=deutsch\nSHORTDATE=%d.%m.%Y\nSHORTTIME=%H:%M\n";
const deutsch_language =
    "DAY_1=Sonntag DAY_5=Donnerstag ABDAY_5=Do\n" ++
    "MON_10=Oktober ABMON_10=Okt\n" ++
    "YESTERDAYSTR=Gestern TODAYSTR=Heute TOMORROWSTR=Morgen FUTURESTR=Zukunft\n";

/// A German default locale, with a catalog of dos's texts.
fn germanDefault(rig: *Rig) !void {
    const lb = rig.lb;
    const dl = rig.dosLib();
    for ([_][*:0]const u8{ "LOCALE:Catalogs", "LOCALE:Catalogs/deutsch", "LOCALE:Catalogs/deutsch/sys" }) |dir| {
        dl.UnLock(dl.CreateDir(dir) orelse return error.NoDir);
    }
    var file: [256]u8 = undefined;
    try rig.write("LOCALE:Catalogs/deutsch/sys/dos.catalog", catalogFile(&file, "$VER: sys/dos.catalog 1.0 (29.10.2026)", "deutsch", locale.CODESET_UTF8, &.{
        .{ .id = -121, .text = "Unbekannter Befehl" },
        .{ .id = 205, .text = "Objekt nicht gefunden" },
    }));
    try rig.write("LOCALE:Countries/deutschland.country", deutschland_country);
    try rig.write("LOCALE:Languages/deutsch.language", deutsch_language);
    try rig.write("LOCALE:deutschland.prefs", "COUNTRY=deutschland\n");
    const german = lb.OpenLocale("LOCALE:deutschland.prefs") orelse return error.NoLocale;
    lb.CloseLocale(lb.SetDefaultLocale(german));
    lb.CloseLocale(german);
}

test "SetDefaultLocale: the library in front of dos's DateToStr, StrToDate and Fault, and holding itself" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    const real = rig.real();
    try testing.expectEqual(@as(?*const anyopaque, null), real.dos_fault);
    const held = real.lib.open_cnt;
    try germanDefault(&rig);
    try testing.expectEqual(held + 1, real.lib.open_cnt);
    // What stands in dos's table is the library's.
    const sys = rig.sysLib();
    const dos_lib = rig.dosLib().lib();
    const LVO = sdk.interface.dos.LVO;
    const standing = [_]struct { offset: isize, own: *const anyopaque }{
        .{ .offset = LVO.DateToStr, .own = exec.vec(_datetostr.dosDateToStr) },
        .{ .offset = LVO.StrToDate, .own = exec.vec(_strtodate.dosStrToDate) },
        .{ .offset = LVO.Fault, .own = exec.vec(_fault.dosFault) },
    };
    for (standing) |entry| {
        const now = sys.SetFunction(dos_lib, entry.offset, entry.own);
        try testing.expectEqual(entry.own, now);
    }
    // Once: a second default puts nothing more in front.
    const kept = real.dos_fault;
    lb_default: {
        const again = rig.lb.OpenLocale("LOCALE:deutschland.prefs") orelse break :lb_default;
        rig.lb.CloseLocale(rig.lb.SetDefaultLocale(again));
        rig.lb.CloseLocale(again);
    }
    try testing.expectEqual(kept, real.dos_fault);
    try testing.expectEqual(held + 1, real.lib.open_cnt);
    // Taken out again, dos's own are back.
    try testing.expect(_dos.remove(real));
    try testing.expectEqual(held, real.lib.open_cnt);
    try testing.expect(sys.SetFunction(dos_lib, LVO.Fault, kept.?) == kept.?);
    try testing.expect(!_dos.remove(real));
}

test "Fault in the default locale: the catalog's text, cut to the buffer; none for what it lacks" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    try germanDefault(&rig);
    const real = rig.real();
    var buffer: [64]u8 = undefined;
    try testing.expectEqual(@as(?i32, 27), _fault.fault(real, 205, "open", &buffer, buffer.len));
    try testing.expectEqualStrings("open: Objekt nicht gefunden", std.mem.sliceTo(&buffer, 0));
    _ = _fault.fault(real, -121, null, &buffer, buffer.len);
    try testing.expectEqualStrings("Unbekannter Befehl", std.mem.sliceTo(&buffer, 0));
    try testing.expectEqual(@as(?i32, 6), _fault.fault(real, 205, null, &buffer, 7));
    try testing.expectEqualStrings("Objekt", std.mem.sliceTo(&buffer, 0));
    // dos's own answers these.
    try testing.expectEqual(@as(?i32, null), _fault.fault(real, 103, null, &buffer, buffer.len));
    try testing.expectEqual(@as(?i32, null), _fault.fault(real, 0, "x", &buffer, buffer.len));
    try testing.expectEqual(@as(?i32, null), _fault.fault(real, 205, null, &buffer, 0));
    // Back to English, which is built in: no catalog.
    rig.lb.CloseLocale(rig.lb.SetDefaultLocale(&real.builtin.public));
    try testing.expectEqual(@as(?*locale.Catalog, null), real.dos_catalog);
    try testing.expectEqual(@as(?i32, null), _fault.fault(real, 205, null, &buffer, buffer.len));
}

test "DateToStr and StrToDate in the default locale: its words and FORMAT_DEF, dos's own for the rest" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    try germanDefault(&rig);
    const real = rig.real();
    var day: [dos.LEN_DATSTRING]u8 = undefined;
    var date: [dos.LEN_DATSTRING]u8 = undefined;
    var time: [dos.LEN_DATSTRING]u8 = undefined;
    var datetime = dos.DateTime{ .stamp = stampOf(2026, 10, 29, 14, 5, 9), .str_day = @ptrCast(&day), .str_date = @ptrCast(&date), .str_time = @ptrCast(&time) };
    try testing.expect(_datetostr.dateToStr(real, &datetime));
    try testing.expectEqualStrings("Donnerstag", std.mem.sliceTo(&day, 0));
    try testing.expectEqualStrings("29-Okt-2026", std.mem.sliceTo(&date, 0));
    try testing.expectEqualStrings("14:05:09", std.mem.sliceTo(&time, 0));
    datetime.format = dos.FORMAT_DEF;
    try testing.expect(_datetostr.dateToStr(real, &datetime));
    try testing.expectEqualStrings("29.10.2026", std.mem.sliceTo(&date, 0));
    try testing.expectEqualStrings("14:05", std.mem.sliceTo(&time, 0));
    datetime.format = dos.FORMAT_INT;
    try testing.expect(_datetostr.dateToStr(real, &datetime));
    try testing.expectEqualStrings("2026-10-29", std.mem.sliceTo(&date, 0));
    // Words near today, which is day 0 without timer.device; none for
    // the formats of numbers alone.
    datetime.flags = dos.DTF_SUBST;
    const words = [_]struct { days: i32, word: []const u8 }{
        .{ .days = 0, .word = "Heute" },
        .{ .days = 1, .word = "Morgen" },
        .{ .days = 40, .word = "Zukunft" },
    };
    for (words) |near| {
        datetime.stamp = .{ .days = near.days };
        datetime.format = dos.FORMAT_DOS;
        try testing.expect(_datetostr.dateToStr(real, &datetime));
        try testing.expectEqualStrings(near.word, std.mem.sliceTo(&date, 0));
        datetime.format = dos.FORMAT_DEF;
        try testing.expect(_datetostr.dateToStr(real, &datetime));
        try testing.expectEqualStrings(near.word, std.mem.sliceTo(&date, 0));
    }
    datetime.format = dos.FORMAT_CDN;
    try testing.expect(_datetostr.dateToStr(real, &datetime));
    try testing.expectEqualStrings("10-02-1978", std.mem.sliceTo(&date, 0));
    datetime.stamp = .{ .days = 0, .minute = 24 * 60 };
    try testing.expect(!_datetostr.dateToStr(real, &datetime));

    // Read back: the locale's words and forms, two digits for the year.
    const reads = [_]struct { format: u8, flags: u8 = 0, date: [*:0]const u8, time: ?[*:0]const u8 = null, stamp: dos.DateStamp }{
        .{ .format = dos.FORMAT_DOS, .date = "29-Okt-2026", .time = "14:05:09", .stamp = stampOf(2026, 10, 29, 14, 5, 9) },
        .{ .format = dos.FORMAT_DOS, .date = "29-okt-26", .time = "14:05", .stamp = stampOf(2026, 10, 29, 14, 5, 0) },
        .{ .format = dos.FORMAT_DEF, .date = "29.10.2026", .time = "14:05", .stamp = stampOf(2026, 10, 29, 14, 5, 0) },
        .{ .format = dos.FORMAT_USA, .date = "10-29-2026", .stamp = stampOf(2026, 10, 29, 0, 0, 0) },
        .{ .format = dos.FORMAT_DOS, .date = "heute", .stamp = .{ .days = 0 } },
        .{ .format = dos.FORMAT_DOS, .date = "Morgen", .stamp = .{ .days = 1 } },
        .{ .format = dos.FORMAT_DOS, .date = "Gestern", .stamp = .{ .days = -1 } },
        // Day 0 was a Sunday: the Thursday before it, and with DTF_FUTURE
        // the one after.
        .{ .format = dos.FORMAT_DOS, .date = "Donnerstag", .stamp = .{ .days = -3 } },
        .{ .format = dos.FORMAT_DOS, .flags = dos.DTF_FUTURE, .date = "DO", .stamp = .{ .days = 4 } },
    };
    for (reads) |read| {
        var into = dos.DateTime{ .format = read.format, .flags = read.flags, .str_date = @constCast(read.date), .str_time = @constCast(read.time) };
        try testing.expect(_strtodate.strToDate(real, &into));
        try testing.expectEqual(read.stamp.days, into.stamp.days);
        try testing.expectEqual(read.stamp.minute, into.stamp.minute);
        try testing.expectEqual(read.stamp.tick, into.stamp.tick);
    }
    // English, and anything else, is dos's own to read: nothing changed.
    var english = dos.DateTime{ .stamp = .{ .days = 99 }, .str_date = @constCast("29-Oct-2026") };
    try testing.expect(!_strtodate.strToDate(real, &english));
    try testing.expectEqual(@as(i32, 99), english.stamp.days);
    english.str_date = @constCast("29-Okt-2026");
    english.str_time = @constCast("25:00");
    try testing.expect(!_strtodate.strToDate(real, &english));
    try testing.expectEqual(@as(i32, 99), english.stamp.days);
}

/// The countries and languages LOCALE: ships with.
const shipped_countries = [_][]const u8{
    "australia",
    "belgie",
    "belgique",
    "canada",
    "canada_francais",
    "danmark",
    "deutschland",
    "espana",
    "france",
    "great_britain",
    "italia",
    "nederland",
    "norge",
    "osterreich",
    "portugal",
    "schweiz",
    "suisse",
    "sverige",
    "svizzera",
    "united_kingdom",
    "united_states",
};
const shipped_languages = [_][]const u8{
    "dansk",
    "deutsch",
    "espanol",
    "francais",
    "italiano",
    "nederlands",
    "norsk",
    "portugues",
    "svenska",
};

test "the countries and languages shipped: each read whole, in a language shipped, its short forms fitting dos's strings" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    const lb = rig.lb;
    var path: [80]u8 = undefined;
    inline for (shipped_languages) |name| {
        try rig.write(try std.fmt.bufPrintZ(&path, "LOCALE:Languages/{s}.language", .{name}), @embedFile("../../../locale/languages/" ++ name ++ ".language"));
    }
    // One country at a time: the test's memory holds the languages and one.
    inline for (shipped_countries) |name| {
        const country = try std.fmt.bufPrintZ(&path, "LOCALE:Countries/{s}.country", .{name});
        try rig.write(country, @embedFile("../../../locale/countries/" ++ name ++ ".country"));
        defer _ = rig.dosLib().DeleteFile(country);
        try rig.write("LOCALE:shipped.prefs", "COUNTRY=" ++ name ++ "\n");
        const loc = lb.OpenLocale("LOCALE:shipped.prefs") orelse {
            std.debug.print("{s}: IoErr {d}\n", .{ name, rig.dosLib().IoErr() });
            return error.NoLocale;
        };
        defer lb.CloseLocale(loc);
        try testing.expectEqual(@as(usize, 2), span(loc.country_code).len);
        // Each country's language is one shipped, or English.
        const language = span(loc.language_name);
        var known = std.mem.eql(u8, language, "english");
        for (shipped_languages) |shipped| known = known or std.mem.eql(u8, language, shipped);
        try testing.expect(known);
        // Its formats fit the strings dos writes them into.
        var text: [64]u8 = undefined;
        const date = stampOf(2026, 9, 30, 23, 59, 58);
        try testing.expect(formatted(lb, loc, &text, loc.short_date_format, date).len < dos.LEN_DATSTRING);
        try testing.expect(formatted(lb, loc, &text, loc.short_time_format, date).len < dos.LEN_DATSTRING);
    }
}
