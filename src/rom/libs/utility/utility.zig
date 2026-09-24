// SPDX-License-Identifier: MPL-2.0
//! utility.library: tag lists, hooks, dates, 32- and 64-bit
//! multiplication and division, Latin-1 case, pack tables, named objects,
//! unique IDs and pattern matching.
//!
//! Each call is a file of its own in the folder for its category -
//! tagitems/, hooks/, date/, math/, strings/, utils/, pack/,
//! namedobjects/, uniqueid/ and pattern/ - carrying its contract and its tests. The jump
//! table is utility_lvo.zig, the ROM tag and init utility_init.zig, the
//! base utility_base.zig. This file holds the names the rest of the
//! kernel reaches the library by, and the tests of calls working
//! together, which make the library from its ROM tag on exec's test RAM.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
/// utility.library's base (utility_base.zig).
const utility_base = @import("utility_base.zig");
/// utility.library's ROM tag and init routine (utility_init.zig).
const utility_init = @import("utility_init.zig");

// The tag is an export in .resident, found there by its address; this
// keeps it in whatever is built from utility.library.
comptime {
    _ = &utility_init.utility_library_tag;
}

/// The library's base, for the modules that keep a pointer to it.
pub const UtilityBase = utility_base.UtilityBase;
/// What the library is on exec's list as.
pub const LIBRARY_NAME = utility_init.LIBRARY_NAME;
/// The ROM tag, for the host tests that make the library from it.
pub const utility_library_tag = utility_init.utility_library_tag;

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const TagItem = sdk.utility.TagItem;
const TAG_IGNORE = sdk.utility.TAG_IGNORE;
const TAG_MORE = sdk.utility.TAG_MORE;
const TAG_USER = sdk.utility.TAG_USER;
const Hook = sdk.utility.Hook;
const ClockData = sdk.utility.ClockData;
const SDivMod32Result = sdk.utility.SDivMod32Result;
const UDivMod32Result = sdk.utility.UDivMod32Result;
const NamedObject = sdk.utility.NamedObject;
const ANO_NameSpace = sdk.utility.ANO_NameSpace;
const ANO_UserSpace = sdk.utility.ANO_UserSpace;
const ANO_Priority = sdk.utility.ANO_Priority;
const ANO_Flags = sdk.utility.ANO_Flags;
const NSF_NODUPS = sdk.utility.NSF_NODUPS;
const NSF_CASE = sdk.utility.NSF_CASE;
/// utility.library's interface as the SDK has it, for `call`.
const interface = sdk.interface.utility;
const FreeNamedObject = @import("namedobjects/freenamedobject.zig").FreeNamedObject;
/// The kernel's exec, to set up and tear down around the library.
const kexec = @import("../exec/exec.zig");

test {
    _ = utility_base;
    _ = utility_init;
    _ = @import("utility_lvo.zig");
    _ = @import("tagitems/_tagitems.zig");
    _ = @import("tagitems/allocatetagitems.zig");
    _ = @import("tagitems/applytagchanges.zig");
    _ = @import("tagitems/clonetagitems.zig");
    _ = @import("tagitems/filtertagchanges.zig");
    _ = @import("tagitems/filtertagitems.zig");
    _ = @import("tagitems/findtagitem.zig");
    _ = @import("tagitems/freetagitems.zig");
    _ = @import("tagitems/gettagdata.zig");
    _ = @import("tagitems/maptags.zig");
    _ = @import("tagitems/nexttagitem.zig");
    _ = @import("tagitems/packbooltags.zig");
    _ = @import("tagitems/refreshtagitemclones.zig");
    _ = @import("tagitems/taginarray.zig");
    _ = @import("hooks/callhookpkt.zig");
    _ = @import("date/_date.zig");
    _ = @import("date/amiga2date.zig");
    _ = @import("date/checkdate.zig");
    _ = @import("date/date2amiga.zig");
    _ = @import("math/_math.zig");
    _ = @import("math/sdivmod32.zig");
    _ = @import("math/smult32.zig");
    _ = @import("math/smult64.zig");
    _ = @import("math/udivmod32.zig");
    _ = @import("math/umult32.zig");
    _ = @import("math/umult64.zig");
    _ = @import("strings/stricmp.zig");
    _ = @import("strings/strcmp.zig");
    _ = @import("strings/strlcpy.zig");
    _ = @import("strings/strchr.zig");
    _ = @import("strings/strrchr.zig");
    _ = @import("strings/strlen.zig");
    _ = @import("strings/strnicmp.zig");
    _ = @import("strings/tolower.zig");
    _ = @import("strings/toupper.zig");
    _ = @import("utils/aligndown.zig");
    _ = @import("utils/alignup.zig");
    _ = @import("pack/_pack.zig");
    _ = @import("pack/packstructuretags.zig");
    _ = @import("pack/unpackstructuretags.zig");
    _ = @import("namedobjects/_namedobjects.zig");
    _ = @import("namedobjects/addnamedobject.zig");
    _ = @import("namedobjects/allocnamedobjecta.zig");
    _ = @import("namedobjects/attemptremnamedobject.zig");
    _ = @import("namedobjects/findnamedobject.zig");
    _ = @import("namedobjects/freenamedobject.zig");
    _ = @import("namedobjects/namedobjectname.zig");
    _ = @import("namedobjects/releasenamedobject.zig");
    _ = @import("namedobjects/remnamedobject.zig");
    _ = @import("uniqueid/getuniqueid.zig");
    _ = @import("pattern/_pattern.zig");
    _ = @import("pattern/matchpattern.zig");
    _ = @import("pattern/matchpatternnocase.zig");
    _ = @import("pattern/parsepattern.zig");
    _ = @import("pattern/parsepatternnocase.zig");
    _ = @import("pattern/setwildstar.zig");
}

/// exec on its test RAM, and utility.library made from its ROM tag.
pub fn setUp() !*UtilityBase {
    try kexec.setUp();
    const made = kexec.InitResident(kexec.SysBase, &utility_library_tag, null) orelse return error.NoUtility;
    return @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(made))));
}

/// The library never expunges itself: free the root name space and the
/// library as MakeLibrary allocated it, then check that nothing is left.
pub fn tearDown(ub: *UtilityBase) !void {
    freeForTests(ub);
    try kexec.expectNoLeaks();
}

/// Host tests, also those of the libraries that open it (dos.library):
/// take the library off the list and free it and its root name space.
pub fn freeForTests(ub: *UtilityBase) void {
    FreeNamedObject(ub, ub.master_space);
    kexec.Remove(kexec.SysBase, &ub.lib.node);
    kexec.freeLibraryMemory(kexec.SysBase, &ub.lib);
}

fn ReturnOf(comptime name: []const u8) type {
    return @typeInfo(@typeInfo(@field(interface.Fn, name)).pointer.child).@"fn".return_type.?;
}

/// Function `name` through the SDK's interface, the way a program calls it.
fn call(ub: *UtilityBase, comptime name: []const u8, args: anytype) ReturnOf(name) {
    const base: *interface.UtilityBase = @ptrCast(ub);
    return @call(.auto, @field(interface.UtilityBase, name), .{base} ++ args);
}

test "utility.library: made from its ROM tag, opened by name, never expunged" {
    const ub = try setUp();
    defer kexec.deinit();
    try testing.expectEqual(&ub.lib, kexec.OpenLibrary(kexec.SysBase, LIBRARY_NAME, 1).?);
    try testing.expectEqual(@as(u16, 1), ub.lib.version);
    try testing.expectEqual(@as(u16, 0), ub.lib.revision);
    try testing.expect(kexec.OpenLibrary(kexec.SysBase, LIBRARY_NAME, 2) == null);
    kexec.CloseLibrary(kexec.SysBase, &ub.lib);
    _ = kexec.RemLibrary(kexec.SysBase, &ub.lib);
    try testing.expect(kexec.FindName(kexec.SysBase, &kexec.SysBase.lib_list, LIBRARY_NAME) != null);
    try tearDown(ub);
}

test "tag lists through the jump table: AllocateTagItems, CloneTagItems, FreeTagItems" {
    const ub = try setUp();
    defer kexec.deinit();
    const more = [_]TagItem{ .{ .tag = TAG_USER + 2, .data = 20 }, .{} };
    const list = [_]TagItem{ .{ .tag = TAG_USER + 1, .data = 10 }, .{ .tag = TAG_IGNORE }, .{ .tag = TAG_MORE, .data = @intFromPtr(&more) } };
    const clone = call(ub, "CloneTagItems", .{&list}).?;
    try testing.expectEqualSlices(TagItem, &.{ .{ .tag = TAG_USER + 1, .data = 10 }, .{ .tag = TAG_USER + 2, .data = 20 }, .{} }, clone[0..3]);
    try testing.expectEqual(@as(usize, 20), call(ub, "GetTagData", .{ TAG_USER + 2, 0, clone }));
    try testing.expectEqual(&clone[1], call(ub, "FindTagItem", .{ TAG_USER + 2, clone }).?);
    call(ub, "FreeTagItems", .{clone});

    const empty = call(ub, "CloneTagItems", .{null}).?;
    try testing.expectEqual(TagItem{}, empty[0]);
    call(ub, "FreeTagItems", .{empty});
    const zeroed = call(ub, "AllocateTagItems", .{4}).?;
    for (zeroed[0..4]) |item| try testing.expectEqual(TagItem{}, item);
    call(ub, "FreeTagItems", .{zeroed});
    try testing.expect(call(ub, "AllocateTagItems", .{0}) == null);
    // More than memory can hold is null, not a panic.
    try testing.expect(call(ub, "AllocateTagItems", .{0xFFFF_FFFF}) == null);
    call(ub, "FreeTagItems", .{null});
    try tearDown(ub);
}

fn countHook(hook: *Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = object;
    _ = message;
    return @intFromPtr(hook.data);
}

test "hooks, dates, math, strings and GetUniqueID through the jump table" {
    const ub = try setUp();
    defer kexec.deinit();
    var hook: Hook = .{ .entry = countHook, .data = @ptrFromInt(77) };
    try testing.expectEqual(@as(usize, 77), call(ub, "CallHookPkt", .{ &hook, null, null }));

    var cd: ClockData = .{};
    call(ub, "Amiga2Date", .{ 694_224_000, &cd });
    try testing.expectEqual(ClockData{ .mday = 1, .month = 1, .year = 2000, .wday = 6 }, cd);
    try testing.expectEqual(@as(u32, 694_224_000), call(ub, "CheckDate", .{&cd}));
    try testing.expectEqual(@as(u32, 694_224_000), call(ub, "Date2Amiga", .{&cd}));

    try testing.expectEqual(@as(i32, -21), call(ub, "SMult32", .{ -3, 7 }));
    try testing.expectEqual(@as(u64, 0xFFFF_FFFE_0000_0001), call(ub, "UMult64", .{ 0xFFFF_FFFF, 0xFFFF_FFFF }));
    try testing.expectEqual(SDivMod32Result{ .quotient = -3, .remainder = -1 }, call(ub, "SDivMod32", .{ -7, 2 }));
    try testing.expectEqual(UDivMod32Result{ .quotient = 3, .remainder = 2 }, call(ub, "UDivMod32", .{ 17, 5 }));

    try testing.expectEqual(@as(i32, 0), call(ub, "Stricmp", .{ "utility.LIBRARY", "Utility.library" }));
    try testing.expectEqual(@as(i32, 0), call(ub, "Strnicmp", .{ "abc", "xyz", 0 }));
    try testing.expectEqual(@as(u8, 'Q'), call(ub, "ToUpper", .{'q'}));
    try testing.expectEqual(@as(u8, 0xE9), call(ub, "ToLower", .{0xC9})); // É

    const first = call(ub, "GetUniqueID", .{});
    try testing.expectEqual(@as(u32, 1), first);
    try testing.expectEqual(first + 1, call(ub, "GetUniqueID", .{}));
    try tearDown(ub);
}

test "named objects: allocate, add, find, release; NSF_NODUPS and NSF_CASE" {
    const ub = try setUp();
    defer kexec.deinit();
    const dir_tags = [_]TagItem{ .{ .tag = ANO_NameSpace, .data = 1 }, .{ .tag = ANO_Flags, .data = NSF_NODUPS }, .{} };
    const dir = call(ub, "AllocNamedObjectA", .{ "dir", &dir_tags }).?;
    const alpha_tags = [_]TagItem{ .{ .tag = ANO_UserSpace, .data = 16 }, .{ .tag = ANO_Priority, .data = 5 }, .{} };
    const alpha = call(ub, "AllocNamedObjectA", .{ "Alpha", &alpha_tags }).?;
    const beta = call(ub, "AllocNamedObjectA", .{ "beta", null }).?;
    const dup = call(ub, "AllocNamedObjectA", .{ "ALPHA", null }).?;
    try testing.expect(call(ub, "AllocNamedObjectA", .{ null, null }) == null);

    // The user space: cleared and aligned. Without one no_Object is null.
    const user: [*]const u8 = @ptrCast(alpha.object.?);
    try testing.expect(std.mem.isAligned(@intFromPtr(user), @alignOf(usize)));
    try testing.expect(std.mem.allEqual(u8, user[0..16], 0));
    try testing.expect(beta.object == null);
    try testing.expectEqualStrings("Alpha", std.mem.span(call(ub, "NamedObjectName", .{alpha}).?));
    try testing.expect(call(ub, "NamedObjectName", .{null}) == null);

    // NSF_NODUPS: "ALPHA" is "Alpha" without case. Nothing goes in twice,
    // or into an object without a name space.
    try testing.expect(call(ub, "AddNamedObject", .{ dir, beta }));
    try testing.expect(call(ub, "AddNamedObject", .{ dir, alpha }));
    try testing.expect(!call(ub, "AddNamedObject", .{ dir, dup }));
    try testing.expect(!call(ub, "AddNamedObject", .{ dir, alpha }));
    try testing.expect(!call(ub, "AddNamedObject", .{ beta, dup }));
    try testing.expect(!call(ub, "AddNamedObject", .{ dir, null }));

    // Found without case; by priority with a null name, after lastObject.
    try testing.expectEqual(alpha, call(ub, "FindNamedObject", .{ dir, "alpha", null }).?);
    try testing.expectEqual(alpha, call(ub, "FindNamedObject", .{ dir, null, null }).?);
    try testing.expectEqual(beta, call(ub, "FindNamedObject", .{ dir, null, alpha }).?);
    try testing.expect(call(ub, "FindNamedObject", .{ dir, null, beta }) == null);

    // The root name space.
    try testing.expect(call(ub, "FindNamedObject", .{ null, "alpha", null }) == null);
    try testing.expect(call(ub, "AddNamedObject", .{ null, dup }));
    try testing.expectEqual(dup, call(ub, "FindNamedObject", .{ null, "alpha", null }).?);
    call(ub, "ReleaseNamedObject", .{dup});

    // NSF_CASE: both names fit; only the exact one is found.
    const case_tags = [_]TagItem{ .{ .tag = ANO_NameSpace, .data = 1 }, .{ .tag = ANO_Flags, .data = NSF_CASE | NSF_NODUPS }, .{} };
    const cased = call(ub, "AllocNamedObjectA", .{ "cased", &case_tags }).?;
    const upper = call(ub, "AllocNamedObjectA", .{ "Name", null }).?;
    const lower = call(ub, "AllocNamedObjectA", .{ "name", null }).?;
    try testing.expect(call(ub, "AddNamedObject", .{ cased, upper }));
    try testing.expect(call(ub, "AddNamedObject", .{ cased, lower }));
    try testing.expect(call(ub, "FindNamedObject", .{ cased, "NAME", null }) == null);
    try testing.expectEqual(lower, call(ub, "FindNamedObject", .{ cased, "name", null }).?);
    call(ub, "ReleaseNamedObject", .{lower});

    // A name space that still holds objects is not freed from under them.
    call(ub, "FreeNamedObject", .{dir});
    try testing.expectEqual(alpha, call(ub, "FindNamedObject", .{ dir, "alpha", null }).?);
    call(ub, "ReleaseNamedObject", .{alpha});

    // Back to one use each (the allocation's), so each can go.
    call(ub, "ReleaseNamedObject", .{alpha});
    call(ub, "ReleaseNamedObject", .{alpha});
    call(ub, "ReleaseNamedObject", .{beta});
    for ([_]*NamedObject{ alpha, beta, dup, upper, lower }) |object| {
        try testing.expectEqual(@as(i32, 1), call(ub, "AttemptRemNamedObject", .{object}));
    }
    for ([_]*NamedObject{ alpha, beta, dup, upper, lower, dir, cased }) |object| call(ub, "FreeNamedObject", .{object});
    try tearDown(ub);
}

test "named objects: AttemptRemNamedObject, RemNamedObject replies at the last release" {
    const ub = try setUp();
    defer kexec.deinit();
    const object = call(ub, "AllocNamedObjectA", .{ "obj", null }).?;
    try testing.expect(call(ub, "AddNamedObject", .{ null, object }));
    try testing.expectEqual(object, call(ub, "FindNamedObject", .{ null, "obj", null }).?);

    // Two uses: the allocation's and the find's.
    try testing.expectEqual(@as(i32, 0), call(ub, "AttemptRemNamedObject", .{object}));
    // Still in its name space, so it isn't freed.
    call(ub, "FreeNamedObject", .{object});

    const port = kexec.CreateMsgPort(kexec.SysBase).?;
    var msg: exec.Message = .{ .reply_port = port };
    call(ub, "RemNamedObject", .{ object, &msg });
    try testing.expect(call(ub, "FindNamedObject", .{ null, "obj", null }) == null);
    try testing.expect(kexec.GetMsg(kexec.SysBase, port) == null); // the find's use is still there
    call(ub, "ReleaseNamedObject", .{object});
    try testing.expectEqual(&msg, kexec.GetMsg(kexec.SysBase, port).?);
    try testing.expectEqual(@intFromPtr(object), @intFromPtr(msg.node.name.?));

    // Removed already: the message comes back at once with ln_Name null.
    var again: exec.Message = .{ .reply_port = port };
    call(ub, "RemNamedObject", .{ object, &again });
    try testing.expectEqual(&again, kexec.GetMsg(kexec.SysBase, port).?);
    try testing.expect(again.node.name == null);
    try testing.expectEqual(@as(i32, 0), call(ub, "AttemptRemNamedObject", .{object}));
    call(ub, "FreeNamedObject", .{object});
    kexec.DeleteMsgPort(kexec.SysBase, port);

    // Without a message RemNamedObject is AttemptRemNamedObject.
    const other = call(ub, "AllocNamedObjectA", .{ "other", null }).?;
    try testing.expect(call(ub, "AddNamedObject", .{ null, other }));
    call(ub, "RemNamedObject", .{ other, null });
    try testing.expect(call(ub, "FindNamedObject", .{ null, "other", null }) == null);
    call(ub, "FreeNamedObject", .{other});
    try tearDown(ub);
}

/// A process as the current task, for the tests that read IoErr.
const TestProcess = struct {
    proc: sdk.dos.Process = .{},
    saved: ?*kexec.Task = null,

    fn enter(tp: *TestProcess) void {
        tp.proc.task.node.name = "test process";
        tp.saved = kexec.SysBase.this_task;
        kexec.SysBase.this_task = &tp.proc.task;
    }

    fn leave(tp: *TestProcess) void {
        kexec.SysBase.this_task = tp.saved.?;
    }
};

fn parsed(ub: *UtilityBase, source: [*:0]const u8, buf: []u8, nocase: bool) isize {
    return if (nocase) call(ub, "ParsePatternNoCase", .{ source, buf.ptr, buf.len }) else call(ub, "ParsePattern", .{ source, buf.ptr, buf.len });
}

test "ParsePattern: wildcards or not, the tokens, errors, the buffer, WildStar" {
    const ub = try setUp();
    defer kexec.deinit();
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    var buf: [64]u8 = undefined;
    const Case = struct { source: [:0]const u8, result: isize, tokens: []const u8, nocase: bool = false };
    const cases = [_]Case{
        .{ .source = "abc", .result = 0, .tokens = "abc" },
        .{ .source = "#?.txt", .result = 1, .tokens = "\x80.txt" },
        .{ .source = "a'?", .result = 0, .tokens = "a?" }, // escaped: not a wildcard
        .{ .source = "a'b", .result = 0, .tokens = "a'b" },
        .{ .source = "(a|b)", .result = 1, .tokens = "\x82a\x83b\x84" },
        .{ .source = "#a", .result = 1, .tokens = "\x89a\x8a" },
        .{ .source = "#(ab)c", .result = 1, .tokens = "\x89\x82ab\x84\x8ac" },
        .{ .source = "~a", .result = 1, .tokens = "\x85a\x86" },
        .{ .source = "a~", .result = 0, .tokens = "a~" }, // a trailing ~ is itself
        .{ .source = "[~a-c]", .result = 1, .tokens = "\x87a-c\x88" },
        .{ .source = "a%b", .result = 0, .tokens = "ab" },
        .{ .source = "*", .result = 0, .tokens = "*" }, // WildStar off
        .{ .source = "a#?[b-c]", .result = 1, .tokens = "A\x80\x88B-C\x88", .nocase = true },
        .{ .source = "\xe9t\xe9", .result = 0, .tokens = "\xc9T\xc9", .nocase = true },
    };
    for (cases) |c| {
        tp.proc.result2 = 42;
        try testing.expectEqual(c.result, parsed(ub, c.source, &buf, c.nocase));
        try testing.expectEqualSlices(u8, c.tokens, std.mem.sliceTo(&buf, 0));
        try testing.expectEqual(@as(i32, 42), tp.proc.result2); // IoErr left alone
    }
    for ([_][:0]const u8{ "(a", "a)", "a|b", "#", "#|", "~)", "[ab", "x\x80" }) |bad| {
        try testing.expectEqual(@as(isize, -1), parsed(ub, bad, &buf, false));
        try testing.expectEqual(sdk.dos.ERROR_BAD_TEMPLATE, tp.proc.result2);
        try testing.expectEqual(@as(u8, 0), buf[0]); // an empty pattern
    }

    const nest = "~~~a"; // the most tokens per character
    var exact: [sdk.utility.parsedSize(nest.len)]u8 = undefined;
    try testing.expectEqual(@as(isize, 1), parsed(ub, nest, &exact, false));
    try testing.expectEqual(@as(isize, -1), parsed(ub, "abcdef", buf[0..4], false));
    try testing.expectEqual(sdk.dos.ERROR_LINE_TOO_LONG, tp.proc.result2);
    try testing.expectEqual(@as(u8, 0), buf[0]);
    try testing.expectEqual(@as(isize, -1), parsed(ub, "a", buf[0..0], false));

    try testing.expect(!call(ub, "SetWildStar", .{true}));
    try testing.expectEqual(@as(isize, 1), parsed(ub, "*.c", &buf, false));
    try testing.expect(call(ub, "MatchPattern", .{ @as([*:0]const u8, @ptrCast(&buf)), "x.c" }));
    try testing.expect(call(ub, "SetWildStar", .{false}));
    try tearDown(ub);
}

test "MatchPattern: the syntax, backtracking, NoCase" {
    const ub = try setUp();
    defer kexec.deinit();
    const Case = struct { []const u8, []const u8, bool };
    const cases = [_]Case{
        .{ "abc", "abc", true },       .{ "abc", "abd", false },           .{ "abc", "ab", false },
        .{ "", "", true },             .{ "", "a", false },                .{ "a?c", "abc", true },
        .{ "a?c", "ac", false },       .{ "#?", "", true },                .{ "#?", "anything", true },
        .{ "#?.txt", "a.txt", true },  .{ "#?.txt", "a.txt.bak", false },  .{ "#?.txt", ".txt", true },
        .{ "#?a#?b", "xaybz", false }, .{ "#?a#?b", "xayb", true },        .{ "#a", "", true },
        .{ "#a", "aaa", true },        .{ "#ab", "aab", true },            .{ "#ab", "abb", false },
        .{ "#[0-9]x", "123x", true },  .{ "#[0-9]x", "12a", false },       .{ "#(ab)", "ababab", true },
        .{ "#(ab)", "aba", false },    .{ "#(a|ab)", "abab", true },       .{ "#(a|ab)c", "aabc", true },
        .{ "#(a|ab)", "b", false },    .{ "(a|b|)x", "x", true },          .{ "(a|b|)x", "bx", true },
        .{ "(a|b)x", "cx", false },    .{ "(foo|bar).c", "bar.c", true },  .{ "((a|b)|c)d", "bd", true },
        .{ "~a", "b", true },          .{ "~a", "a", false },              .{ "~(a|b)", "c", true },
        .{ "~(a|b)", "b", false },     .{ "~(#?.info)", "x.info", false }, .{ "~(#?.info)", "x.txt", true },
        .{ "[abc]x", "bx", true },     .{ "[abc]x", "dx", false },         .{ "[a-c]", "b", true },
        .{ "[a-c]", "d", false },      .{ "[~a-c]", "d", true },           .{ "[~a-c]", "b", false },
        .{ "[a-]", "-", true },        .{ "[-a]", "-", true },             .{ "[a-]", "b", false },
        .{ "a'?", "a?", true },        .{ "a'?", "ab", false },            .{ "'#'?", "#?", true },
        .{ "a%b", "ab", true },        .{ "*", "*", true },                .{ "*", "x", false },
        .{ "#(%)x", "x", true },       .{ "#(#?)", "abc", true },          .{ "#(a#?)b", "axxab", true },
        .{ "a~", "a~", true },         .{ "#?[", "x", false },
    };
    var buf: [64]u8 = undefined;
    for (cases) |c| {
        var source: [32:0]u8 = @splat(0);
        var string: [32:0]u8 = @splat(0);
        @memcpy(source[0..c[0].len], c[0]);
        @memcpy(string[0..c[1].len], c[1]);
        if (parsed(ub, &source, &buf, false) < 0) {
            try testing.expect(!c[2]); // "#?[" doesn't parse
            continue;
        }
        const got = call(ub, "MatchPattern", .{ @as([*:0]const u8, @ptrCast(&buf)), &string });
        if (got != c[2]) {
            std.debug.print("MatchPattern(\"{s}\", \"{s}\") = {}\n", .{ c[0], c[1], got });
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqual(@as(isize, 1), parsed(ub, "#?.TXT", &buf, true));
    try testing.expect(call(ub, "MatchPatternNoCase", .{ @as([*:0]const u8, @ptrCast(&buf)), "readme.txt" }));
    try testing.expect(!call(ub, "MatchPattern", .{ @as([*:0]const u8, @ptrCast(&buf)), "readme.txt" }));
    try testing.expectEqual(@as(isize, 1), parsed(ub, "\xe9#?", &buf, true));
    try testing.expect(call(ub, "MatchPatternNoCase", .{ @as([*:0]const u8, @ptrCast(&buf)), "\xc9clair" }));
    try tearDown(ub);
}

test "MatchPattern: long strings take frames from the heap; too many is ERROR_TOO_MANY_LEVELS" {
    const ub = try setUp();
    defer kexec.deinit();
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    var buf: [16]u8 = undefined;
    const string = try testing.allocator.allocSentinel(u8, 2100, 0);
    defer testing.allocator.free(string);

    for (string[0..400], 0..) |*c, i| c.* = if (i % 2 == 0) 'a' else 'b';
    string[400] = 0;
    try testing.expectEqual(@as(isize, 1), parsed(ub, "#(ab)", &buf, false));
    try testing.expect(call(ub, "MatchPattern", .{ @as([*:0]const u8, @ptrCast(&buf)), string.ptr })); // ~600 frames

    @memset(string[0..2100], 'a');
    string[2100] = 0;
    try testing.expectEqual(@as(isize, 1), parsed(ub, "#a", &buf, false));
    try testing.expect(call(ub, "MatchPattern", .{ @as([*:0]const u8, @ptrCast(&buf)), string.ptr })); // one frame
    try testing.expectEqual(@as(isize, 1), parsed(ub, "#(a)", &buf, false));
    tp.proc.result2 = 0;
    try testing.expect(!call(ub, "MatchPattern", .{ @as([*:0]const u8, @ptrCast(&buf)), string.ptr }));
    try testing.expectEqual(sdk.dos.ERROR_TOO_MANY_LEVELS, tp.proc.result2);
    try tearDown(ub); // the chunks went back
}
