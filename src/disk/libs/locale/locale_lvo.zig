// SPDX-License-Identifier: MIT
//! locale.library's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const locale = sdk.locale;
const vec = exec.vec;
const LocaleBase = @import("locale_base.zig").LocaleBase;
const locale_init = @import("locale_init.zig");

const OpenLocale = @import("locale/openlocale.zig").OpenLocale;
const CloseLocale = @import("locale/closelocale.zig").CloseLocale;
const SetDefaultLocale = @import("locale/setdefaultlocale.zig").SetDefaultLocale;
const GetLocaleStr = @import("strings/getlocalestr.zig").GetLocaleStr;
const IsAlNum = @import("chars/isalnum.zig").IsAlNum;
const IsAlpha = @import("chars/isalpha.zig").IsAlpha;
const IsCntrl = @import("chars/iscntrl.zig").IsCntrl;
const IsDigit = @import("chars/isdigit.zig").IsDigit;
const IsGraph = @import("chars/isgraph.zig").IsGraph;
const IsLower = @import("chars/islower.zig").IsLower;
const IsPrint = @import("chars/isprint.zig").IsPrint;
const IsPunct = @import("chars/ispunct.zig").IsPunct;
const IsSpace = @import("chars/isspace.zig").IsSpace;
const IsUpper = @import("chars/isupper.zig").IsUpper;
const IsXDigit = @import("chars/isxdigit.zig").IsXDigit;
const ConvToLower = @import("chars/convtolower.zig").ConvToLower;
const ConvToUpper = @import("chars/convtoupper.zig").ConvToUpper;
const StrnCmp = @import("compare/strncmp.zig").StrnCmp;
const StrConvert = @import("compare/strconvert.zig").StrConvert;
const FormatDate = @import("format/formatdate.zig").FormatDate;
const ParseDate = @import("format/parsedate.zig").ParseDate;
const FormatString = @import("format/formatstring.zig").FormatString;
const OpenCatalogA = @import("catalog/opencataloga.zig").OpenCatalogA;
const CloseCatalog = @import("catalog/closecatalog.zig").CloseCatalog;
const GetCatalogStr = @import("catalog/getcatalogstr.zig").GetCatalogStr;

/// locale.library's interface, as the SDK generates it from
/// sdk/fd/locale_lib.fd.
const interface = sdk.interface.locale;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("locale.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(100_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "locale.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("locale/openlocale.zig"),
    @embedFile("locale/closelocale.zig"),
    @embedFile("locale/setdefaultlocale.zig"),
    @embedFile("strings/getlocalestr.zig"),
    @embedFile("chars/isalnum.zig"),
    @embedFile("chars/isalpha.zig"),
    @embedFile("chars/iscntrl.zig"),
    @embedFile("chars/isdigit.zig"),
    @embedFile("chars/isgraph.zig"),
    @embedFile("chars/islower.zig"),
    @embedFile("chars/isprint.zig"),
    @embedFile("chars/ispunct.zig"),
    @embedFile("chars/isspace.zig"),
    @embedFile("chars/isupper.zig"),
    @embedFile("chars/isxdigit.zig"),
    @embedFile("chars/convtolower.zig"),
    @embedFile("chars/convtoupper.zig"),
    @embedFile("compare/strncmp.zig"),
    @embedFile("compare/strconvert.zig"),
    @embedFile("format/formatdate.zig"),
    @embedFile("format/parsedate.zig"),
    @embedFile("format/formatstring.zig"),
    @embedFile("catalog/opencataloga.zig"),
    @embedFile("catalog/closecatalog.zig"),
    @embedFile("catalog/getcatalogstr.zig"),
};

// --- the locale ---------------------------------------------------------------

fn lvoOpenLocale(lb: *LocaleBase, name: ?[*:0]const u8) callconv(.c) ?*locale.Locale {
    return OpenLocale(lb, name);
}
fn lvoCloseLocale(lb: *LocaleBase, loc: ?*locale.Locale) callconv(.c) void {
    return CloseLocale(lb, loc);
}
fn lvoSetDefaultLocale(lb: *LocaleBase, loc: *locale.Locale) callconv(.c) ?*locale.Locale {
    return SetDefaultLocale(lb, loc);
}

// --- the language's words -----------------------------------------------------

fn lvoGetLocaleStr(lb: *LocaleBase, loc: *const locale.Locale, string_num: u32) callconv(.c) ?[*:0]const u8 {
    return GetLocaleStr(lb, loc, string_num);
}

// --- characters ---------------------------------------------------------------

fn lvoIsAlNum(lb: *LocaleBase, loc: *const locale.Locale, character: u32) callconv(.c) bool {
    return IsAlNum(lb, loc, character);
}
fn lvoIsAlpha(lb: *LocaleBase, loc: *const locale.Locale, character: u32) callconv(.c) bool {
    return IsAlpha(lb, loc, character);
}
fn lvoIsCntrl(lb: *LocaleBase, loc: *const locale.Locale, character: u32) callconv(.c) bool {
    return IsCntrl(lb, loc, character);
}
fn lvoIsDigit(lb: *LocaleBase, loc: *const locale.Locale, character: u32) callconv(.c) bool {
    return IsDigit(lb, loc, character);
}
fn lvoIsGraph(lb: *LocaleBase, loc: *const locale.Locale, character: u32) callconv(.c) bool {
    return IsGraph(lb, loc, character);
}
fn lvoIsLower(lb: *LocaleBase, loc: *const locale.Locale, character: u32) callconv(.c) bool {
    return IsLower(lb, loc, character);
}
fn lvoIsPrint(lb: *LocaleBase, loc: *const locale.Locale, character: u32) callconv(.c) bool {
    return IsPrint(lb, loc, character);
}
fn lvoIsPunct(lb: *LocaleBase, loc: *const locale.Locale, character: u32) callconv(.c) bool {
    return IsPunct(lb, loc, character);
}
fn lvoIsSpace(lb: *LocaleBase, loc: *const locale.Locale, character: u32) callconv(.c) bool {
    return IsSpace(lb, loc, character);
}
fn lvoIsUpper(lb: *LocaleBase, loc: *const locale.Locale, character: u32) callconv(.c) bool {
    return IsUpper(lb, loc, character);
}
fn lvoIsXDigit(lb: *LocaleBase, loc: *const locale.Locale, character: u32) callconv(.c) bool {
    return IsXDigit(lb, loc, character);
}
fn lvoConvToLower(lb: *LocaleBase, loc: *const locale.Locale, character: u32) callconv(.c) u32 {
    return ConvToLower(lb, loc, character);
}
fn lvoConvToUpper(lb: *LocaleBase, loc: *const locale.Locale, character: u32) callconv(.c) u32 {
    return ConvToUpper(lb, loc, character);
}

// --- comparing ----------------------------------------------------------------

fn lvoStrnCmp(lb: *LocaleBase, loc: *const locale.Locale, string1: [*:0]const u8, string2: [*:0]const u8, length: i32, compare_type: u32) callconv(.c) i32 {
    return StrnCmp(lb, loc, string1, string2, length, compare_type);
}
fn lvoStrConvert(lb: *LocaleBase, loc: *const locale.Locale, string: [*:0]const u8, buffer: [*]u8, buffer_size: u32, compare_type: u32) callconv(.c) u32 {
    return StrConvert(lb, loc, string, buffer, buffer_size, compare_type);
}

// --- dates and numbers --------------------------------------------------------

fn lvoFormatDate(lb: *LocaleBase, loc: *const locale.Locale, template: [*:0]const u8, date: *const dos.DateStamp, put_char_func: *utility.Hook) callconv(.c) void {
    return FormatDate(lb, loc, template, date, put_char_func);
}
fn lvoParseDate(lb: *LocaleBase, loc: *const locale.Locale, date: *dos.DateStamp, template: [*:0]const u8, get_char_func: *utility.Hook) callconv(.c) bool {
    return ParseDate(lb, loc, date, template, get_char_func);
}
fn lvoFormatString(lb: *LocaleBase, loc: *const locale.Locale, template: [*:0]const u8, data_stream: ?*const anyopaque, put_char_func: *utility.Hook) callconv(.c) ?*const anyopaque {
    return FormatString(lb, loc, template, data_stream, put_char_func);
}

// --- catalogs -----------------------------------------------------------------

fn lvoOpenCatalogA(lb: *LocaleBase, loc: ?*const locale.Locale, name: [*:0]const u8, tag_list: ?[*]const utility.TagItem) callconv(.c) ?*locale.Catalog {
    return OpenCatalogA(lb, loc, name, tag_list);
}
fn lvoCloseCatalog(lb: *LocaleBase, catalog: ?*locale.Catalog) callconv(.c) void {
    return CloseCatalog(lb, catalog);
}
fn lvoGetCatalogStr(lb: *LocaleBase, catalog: ?*const locale.Catalog, string_num: i32, default_string: [*:0]const u8) callconv(.c) [*:0]const u8 {
    return GetCatalogStr(lb, catalog, string_num, default_string);
}

pub const vectors = [_]*const anyopaque{
    vec(locale_init.openVector),
    vec(locale_init.closeVector),
    vec(locale_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoOpenLocale),
    vec(lvoCloseLocale),
    vec(lvoSetDefaultLocale),
    vec(lvoGetLocaleStr),
    vec(lvoIsAlNum),
    vec(lvoIsAlpha),
    vec(lvoIsCntrl),
    vec(lvoIsDigit),
    vec(lvoIsGraph),
    vec(lvoIsLower),
    vec(lvoIsPrint),
    vec(lvoIsPunct),
    vec(lvoIsSpace),
    vec(lvoIsUpper),
    vec(lvoIsXDigit),
    vec(lvoConvToLower),
    vec(lvoConvToUpper),
    vec(lvoStrnCmp),
    vec(lvoStrConvert),
    vec(lvoFormatDate),
    vec(lvoParseDate),
    vec(lvoFormatString),
    vec(lvoOpenCatalogA),
    vec(lvoCloseCatalog),
    vec(lvoGetCatalogStr),
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "the jump table: the standard four, then this library's own" {
    try testing.expectEqual(@as(usize, 4 + @typeInfo(LVO).@"struct".decls.len), vectors.len);
    inline for (@typeInfo(LVO).@"struct".decls) |d| {
        const index: usize = @intCast(@divExact(-@field(LVO, d.name), exec.slot_size) - 1);
        try testing.expectEqual(vec(@field(@This(), "lvo" ++ d.name)), vectors[index]);
    }
}

test "every wrapper hands its parameters on, in order, to the call it is named after" {
    try exec.libraries.checkForwarding(@embedFile("locale_lvo.zig"), LVO, &.{});
}
