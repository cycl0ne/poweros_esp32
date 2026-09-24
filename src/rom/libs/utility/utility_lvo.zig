// SPDX-License-Identifier: MPL-2.0
//! utility.library's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.
//!
//! Each wrapper is the slot a caller reaches through the table. It hands
//! the work to the implementation - a file of its own in the folder for its
//! category - with the library's base first.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const utility_base = @import("utility_base.zig");
const utility_init = @import("utility_init.zig");
const AllocateTagItems = @import("tagitems/allocatetagitems.zig").AllocateTagItems;
const ApplyTagChanges = @import("tagitems/applytagchanges.zig").ApplyTagChanges;
const CloneTagItems = @import("tagitems/clonetagitems.zig").CloneTagItems;
const FilterTagChanges = @import("tagitems/filtertagchanges.zig").FilterTagChanges;
const FilterTagItems = @import("tagitems/filtertagitems.zig").FilterTagItems;
const FindTagItem = @import("tagitems/findtagitem.zig").FindTagItem;
const FreeTagItems = @import("tagitems/freetagitems.zig").FreeTagItems;
const GetTagData = @import("tagitems/gettagdata.zig").GetTagData;
const MapTags = @import("tagitems/maptags.zig").MapTags;
const NextTagItem = @import("tagitems/nexttagitem.zig").NextTagItem;
const PackBoolTags = @import("tagitems/packbooltags.zig").PackBoolTags;
const RefreshTagItemClones = @import("tagitems/refreshtagitemclones.zig").RefreshTagItemClones;
const TagInArray = @import("tagitems/taginarray.zig").TagInArray;
const CallHookPkt = @import("hooks/callhookpkt.zig").CallHookPkt;
const Amiga2Date = @import("date/amiga2date.zig").Amiga2Date;
const CheckDate = @import("date/checkdate.zig").CheckDate;
const Date2Amiga = @import("date/date2amiga.zig").Date2Amiga;
const SDivMod32 = @import("math/sdivmod32.zig").SDivMod32;
const SMult32 = @import("math/smult32.zig").SMult32;
const SMult64 = @import("math/smult64.zig").SMult64;
const UDivMod32 = @import("math/udivmod32.zig").UDivMod32;
const UMult32 = @import("math/umult32.zig").UMult32;
const UMult64 = @import("math/umult64.zig").UMult64;
const Stricmp = @import("strings/stricmp.zig").Stricmp;
const Strnicmp = @import("strings/strnicmp.zig").Strnicmp;
const ToLower = @import("strings/tolower.zig").ToLower;
const ToUpper = @import("strings/toupper.zig").ToUpper;
const Strcmp = @import("strings/strcmp.zig").Strcmp;
const Strlen = @import("strings/strlen.zig").Strlen;
const AlignUp = @import("utils/alignup.zig").AlignUp;
const AlignDown = @import("utils/aligndown.zig").AlignDown;
const Strlcpy = @import("strings/strlcpy.zig").Strlcpy;
const Strchr = @import("strings/strchr.zig").Strchr;
const Strrchr = @import("strings/strrchr.zig").Strrchr;
const DateSplit = @import("date/datesplit.zig").DateSplit;
const DateJoin = @import("date/datejoin.zig").DateJoin;
const PackStructureTags = @import("pack/packstructuretags.zig").PackStructureTags;
const UnpackStructureTags = @import("pack/unpackstructuretags.zig").UnpackStructureTags;
const AddNamedObject = @import("namedobjects/addnamedobject.zig").AddNamedObject;
const AllocNamedObjectA = @import("namedobjects/allocnamedobjecta.zig").AllocNamedObjectA;
const AttemptRemNamedObject = @import("namedobjects/attemptremnamedobject.zig").AttemptRemNamedObject;
const FindNamedObject = @import("namedobjects/findnamedobject.zig").FindNamedObject;
const FreeNamedObject = @import("namedobjects/freenamedobject.zig").FreeNamedObject;
const NamedObjectName = @import("namedobjects/namedobjectname.zig").NamedObjectName;
const ReleaseNamedObject = @import("namedobjects/releasenamedobject.zig").ReleaseNamedObject;
const RemNamedObject = @import("namedobjects/remnamedobject.zig").RemNamedObject;
const MatchPattern = @import("pattern/matchpattern.zig").MatchPattern;
const MatchPatternNoCase = @import("pattern/matchpatternnocase.zig").MatchPatternNoCase;
const ParsePattern = @import("pattern/parsepattern.zig").ParsePattern;
const ParsePatternNoCase = @import("pattern/parsepatternnocase.zig").ParsePatternNoCase;
const SetWildStar = @import("pattern/setwildstar.zig").SetWildStar;
const GetUniqueID = @import("uniqueid/getuniqueid.zig").GetUniqueID;

const vec = exec.vec;
const UtilityBase = utility_base.UtilityBase;
const Tag = sdk.utility.Tag;
const TagItem = sdk.utility.TagItem;
const Hook = sdk.utility.Hook;
const ClockData = sdk.utility.ClockData;
const SDivMod32Result = sdk.utility.SDivMod32Result;
const UDivMod32Result = sdk.utility.UDivMod32Result;
const NamedObject = sdk.utility.NamedObject;

/// utility.library's interface, as the SDK generates it from
/// sdk/fd/utility_lib.fd.
const interface = sdk.interface.utility;
const LVO = interface.LVO;

// The library implements the SDK's interface: every function in LVO is an
// lvo* function here, with the signature the SDK gives it (after the base).
comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        if (!exec.libraries.sameSignature(@TypeOf(&@field(@This(), "lvo" ++ d.name)), @field(interface.Fn, d.name))) {
            @compileError("utility.library's lvo" ++ d.name ++ " doesn't match the SDK's Fn." ++ d.name);
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it. The number in a
// SINCE line is written by hand and read by whoever writes against the
// library, so nothing else would ever compare the two.
comptime {
    // One quota for the whole run: the files' branches add up.
    @setEvalBranchQuota(50_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, utility_init.LIBRARY_NAME, "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`: every
/// call of the table.
const contract_files = [_][]const u8{
    @embedFile("tagitems/findtagitem.zig"),
    @embedFile("tagitems/gettagdata.zig"),
    @embedFile("tagitems/packbooltags.zig"),
    @embedFile("tagitems/nexttagitem.zig"),
    @embedFile("tagitems/filtertagchanges.zig"),
    @embedFile("tagitems/maptags.zig"),
    @embedFile("tagitems/allocatetagitems.zig"),
    @embedFile("tagitems/clonetagitems.zig"),
    @embedFile("tagitems/freetagitems.zig"),
    @embedFile("tagitems/refreshtagitemclones.zig"),
    @embedFile("tagitems/taginarray.zig"),
    @embedFile("tagitems/filtertagitems.zig"),
    @embedFile("hooks/callhookpkt.zig"),
    @embedFile("date/amiga2date.zig"),
    @embedFile("date/date2amiga.zig"),
    @embedFile("date/checkdate.zig"),
    @embedFile("math/smult32.zig"),
    @embedFile("math/umult32.zig"),
    @embedFile("math/sdivmod32.zig"),
    @embedFile("math/udivmod32.zig"),
    @embedFile("strings/stricmp.zig"),
    @embedFile("strings/strnicmp.zig"),
    @embedFile("strings/toupper.zig"),
    @embedFile("strings/tolower.zig"),
    @embedFile("tagitems/applytagchanges.zig"),
    @embedFile("math/smult64.zig"),
    @embedFile("math/umult64.zig"),
    @embedFile("pack/packstructuretags.zig"),
    @embedFile("pack/unpackstructuretags.zig"),
    @embedFile("namedobjects/addnamedobject.zig"),
    @embedFile("namedobjects/allocnamedobjecta.zig"),
    @embedFile("namedobjects/attemptremnamedobject.zig"),
    @embedFile("namedobjects/findnamedobject.zig"),
    @embedFile("namedobjects/freenamedobject.zig"),
    @embedFile("namedobjects/namedobjectname.zig"),
    @embedFile("namedobjects/releasenamedobject.zig"),
    @embedFile("namedobjects/remnamedobject.zig"),
    @embedFile("uniqueid/getuniqueid.zig"),
    @embedFile("pattern/parsepattern.zig"),
    @embedFile("pattern/parsepatternnocase.zig"),
    @embedFile("pattern/matchpattern.zig"),
    @embedFile("pattern/matchpatternnocase.zig"),
    @embedFile("pattern/setwildstar.zig"),
    @embedFile("strings/strcmp.zig"),
    @embedFile("strings/strlen.zig"),
    @embedFile("utils/alignup.zig"),
    @embedFile("utils/aligndown.zig"),
    @embedFile("strings/strlcpy.zig"),
    @embedFile("strings/strchr.zig"),
    @embedFile("strings/strrchr.zig"),
};

/// The empty slots of the table: each returns 0.
///
/// INPUTS:
/// - `_` - the library's base, unused.
fn reserved(_: *UtilityBase) callconv(.c) usize {
    return 0;
}

fn lvoFindTagItem(ub: *UtilityBase, tag_val: Tag, tag_list: ?[*]const TagItem) callconv(.c) ?*const TagItem {
    return FindTagItem(ub, tag_val, tag_list);
}
fn lvoGetTagData(ub: *UtilityBase, tag_val: Tag, default_value: usize, tag_list: ?[*]const TagItem) callconv(.c) usize {
    return GetTagData(ub, tag_val, default_value, tag_list);
}
fn lvoPackBoolTags(ub: *UtilityBase, initial_flags: u32, tag_list: ?[*]const TagItem, bool_map: ?[*]const TagItem) callconv(.c) u32 {
    return PackBoolTags(ub, initial_flags, tag_list, bool_map);
}
fn lvoNextTagItem(ub: *UtilityBase, tag_list_ptr: *?[*]const TagItem) callconv(.c) ?*const TagItem {
    return NextTagItem(ub, tag_list_ptr);
}
fn lvoFilterTagChanges(ub: *UtilityBase, change_list: ?[*]TagItem, original_list: ?[*]TagItem, apply: u32) callconv(.c) void {
    FilterTagChanges(ub, change_list, original_list, apply);
}
fn lvoMapTags(ub: *UtilityBase, tag_list: ?[*]TagItem, map_list: ?[*]const TagItem, map_type: u32) callconv(.c) void {
    MapTags(ub, tag_list, map_list, map_type);
}
fn lvoAllocateTagItems(ub: *UtilityBase, num_tags: u32) callconv(.c) ?[*]TagItem {
    return AllocateTagItems(ub, num_tags);
}
fn lvoCloneTagItems(ub: *UtilityBase, tag_list: ?[*]const TagItem) callconv(.c) ?[*]TagItem {
    return CloneTagItems(ub, tag_list);
}
fn lvoFreeTagItems(ub: *UtilityBase, tag_list: ?[*]TagItem) callconv(.c) void {
    FreeTagItems(ub, tag_list);
}
fn lvoRefreshTagItemClones(ub: *UtilityBase, clone: ?[*]TagItem, original: ?[*]const TagItem) callconv(.c) void {
    RefreshTagItemClones(ub, clone, original);
}
fn lvoTagInArray(ub: *UtilityBase, tag_val: Tag, tag_array: ?[*]const Tag) callconv(.c) bool {
    return TagInArray(ub, tag_val, tag_array);
}
fn lvoFilterTagItems(ub: *UtilityBase, tag_list: ?[*]TagItem, filter_array: ?[*]const Tag, logic: u32) callconv(.c) u32 {
    return FilterTagItems(ub, tag_list, filter_array, logic);
}
fn lvoCallHookPkt(ub: *UtilityBase, hook: *Hook, object: ?*anyopaque, param_packet: ?*anyopaque) callconv(.c) usize {
    return CallHookPkt(ub, hook, object, param_packet);
}
fn lvoAmiga2Date(ub: *UtilityBase, seconds: u32, result: *ClockData) callconv(.c) void {
    Amiga2Date(ub, seconds, result);
}
fn lvoDate2Amiga(ub: *UtilityBase, clock_data: *const ClockData) callconv(.c) u32 {
    return Date2Amiga(ub, clock_data);
}
fn lvoCheckDate(ub: *UtilityBase, clock_data: *const ClockData) callconv(.c) u32 {
    return CheckDate(ub, clock_data);
}
fn lvoSMult32(ub: *UtilityBase, arg1: i32, arg2: i32) callconv(.c) i32 {
    return SMult32(ub, arg1, arg2);
}
fn lvoUMult32(ub: *UtilityBase, arg1: u32, arg2: u32) callconv(.c) u32 {
    return UMult32(ub, arg1, arg2);
}
fn lvoSDivMod32(ub: *UtilityBase, dividend: i32, divisor: i32) callconv(.c) SDivMod32Result {
    return SDivMod32(ub, dividend, divisor);
}
fn lvoUDivMod32(ub: *UtilityBase, dividend: u32, divisor: u32) callconv(.c) UDivMod32Result {
    return UDivMod32(ub, dividend, divisor);
}
fn lvoStricmp(ub: *UtilityBase, string1: [*:0]const u8, string2: [*:0]const u8) callconv(.c) i32 {
    return Stricmp(ub, string1, string2);
}
fn lvoStrnicmp(ub: *UtilityBase, string1: [*:0]const u8, string2: [*:0]const u8, length: i32) callconv(.c) i32 {
    return Strnicmp(ub, string1, string2, length);
}
fn lvoToUpper(ub: *UtilityBase, character: u32) callconv(.c) u8 {
    return ToUpper(ub, character);
}
fn lvoToLower(ub: *UtilityBase, character: u32) callconv(.c) u8 {
    return ToLower(ub, character);
}
fn lvoApplyTagChanges(ub: *UtilityBase, list: ?[*]TagItem, change_list: ?[*]const TagItem) callconv(.c) void {
    ApplyTagChanges(ub, list, change_list);
}
fn lvoSMult64(ub: *UtilityBase, arg1: i32, arg2: i32) callconv(.c) i64 {
    return SMult64(ub, arg1, arg2);
}
fn lvoUMult64(ub: *UtilityBase, arg1: u32, arg2: u32) callconv(.c) u64 {
    return UMult64(ub, arg1, arg2);
}
fn lvoPackStructureTags(ub: *UtilityBase, structure: ?*anyopaque, pack_table: ?[*]const u32, tag_list: ?[*]const TagItem) callconv(.c) u32 {
    return PackStructureTags(ub, structure, pack_table, tag_list);
}
fn lvoUnpackStructureTags(ub: *UtilityBase, structure: ?*const anyopaque, pack_table: ?[*]const u32, tag_list: ?[*]const TagItem) callconv(.c) u32 {
    return UnpackStructureTags(ub, structure, pack_table, tag_list);
}
fn lvoAddNamedObject(ub: *UtilityBase, name_space: ?*NamedObject, object: ?*NamedObject) callconv(.c) bool {
    return AddNamedObject(ub, name_space, object);
}
fn lvoAllocNamedObjectA(ub: *UtilityBase, name: ?[*:0]const u8, tag_list: ?[*]const TagItem) callconv(.c) ?*NamedObject {
    return AllocNamedObjectA(ub, name, tag_list);
}
fn lvoAttemptRemNamedObject(ub: *UtilityBase, object: ?*NamedObject) callconv(.c) i32 {
    return AttemptRemNamedObject(ub, object);
}
fn lvoFindNamedObject(ub: *UtilityBase, name_space: ?*NamedObject, name: ?[*:0]const u8, last_object: ?*NamedObject) callconv(.c) ?*NamedObject {
    return FindNamedObject(ub, name_space, name, last_object);
}
fn lvoFreeNamedObject(ub: *UtilityBase, object: ?*NamedObject) callconv(.c) void {
    FreeNamedObject(ub, object);
}
fn lvoNamedObjectName(ub: *UtilityBase, object: ?*NamedObject) callconv(.c) ?[*:0]const u8 {
    return NamedObjectName(ub, object);
}
fn lvoReleaseNamedObject(ub: *UtilityBase, object: ?*NamedObject) callconv(.c) void {
    ReleaseNamedObject(ub, object);
}
fn lvoRemNamedObject(ub: *UtilityBase, object: ?*NamedObject, message: ?*exec.Message) callconv(.c) void {
    RemNamedObject(ub, object, message);
}
fn lvoParsePattern(ub: *UtilityBase, source: [*:0]const u8, dest: [*]u8, size: usize) callconv(.c) isize {
    return ParsePattern(ub, source, dest, size);
}
fn lvoParsePatternNoCase(ub: *UtilityBase, source: [*:0]const u8, dest: [*]u8, size: usize) callconv(.c) isize {
    return ParsePatternNoCase(ub, source, dest, size);
}
fn lvoMatchPattern(ub: *UtilityBase, pattern: [*:0]const u8, string: [*:0]const u8) callconv(.c) bool {
    return MatchPattern(ub, pattern, string);
}
fn lvoMatchPatternNoCase(ub: *UtilityBase, pattern: [*:0]const u8, string: [*:0]const u8) callconv(.c) bool {
    return MatchPatternNoCase(ub, pattern, string);
}
fn lvoSetWildStar(ub: *UtilityBase, on: bool) callconv(.c) bool {
    return SetWildStar(ub, on);
}
fn lvoStrcmp(ub: *UtilityBase, string1: [*:0]const u8, string2: [*:0]const u8) callconv(.c) i32 {
    return Strcmp(ub, string1, string2);
}
fn lvoStrlen(ub: *UtilityBase, string: [*:0]const u8) callconv(.c) usize {
    return Strlen(ub, string);
}
fn lvoAlignUp(ub: *UtilityBase, offset: usize, alignment: usize) callconv(.c) usize {
    return AlignUp(ub, offset, alignment);
}
fn lvoAlignDown(ub: *UtilityBase, offset: usize, alignment: usize) callconv(.c) usize {
    return AlignDown(ub, offset, alignment);
}
fn lvoStrlcpy(ub: *UtilityBase, dest: [*]u8, size: usize, source: [*:0]const u8) callconv(.c) usize {
    return Strlcpy(ub, dest, size, source);
}
fn lvoStrchr(ub: *UtilityBase, string: [*:0]const u8, character: u8) callconv(.c) ?[*:0]const u8 {
    return Strchr(ub, string, character);
}
fn lvoStrrchr(ub: *UtilityBase, string: [*:0]const u8, character: u8) callconv(.c) ?[*:0]const u8 {
    return Strrchr(ub, string, character);
}

fn lvoDateSplit(ub: *UtilityBase, days: u32, result: *ClockData) callconv(.c) void {
    return DateSplit(ub, days, result);
}
fn lvoDateJoin(ub: *UtilityBase, date: *const ClockData) callconv(.c) i32 {
    return DateJoin(ub, date);
}

fn lvoGetUniqueID(ub: *UtilityBase) callconv(.c) u32 {
    return GetUniqueID(ub);
}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line, and `reserved` in the reserved slots.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(utility_base.expunge),
    vec(exec.libExtFunc),
    vec(lvoFindTagItem),
    vec(lvoGetTagData),
    vec(lvoPackBoolTags),
    vec(lvoNextTagItem),
    vec(lvoFilterTagChanges),
    vec(lvoMapTags),
    vec(lvoAllocateTagItems),
    vec(lvoCloneTagItems),
    vec(lvoFreeTagItems),
    vec(lvoRefreshTagItemClones),
    vec(lvoTagInArray),
    vec(lvoFilterTagItems),
    vec(lvoCallHookPkt),
    vec(reserved),
    vec(reserved),
    vec(lvoAmiga2Date),
    vec(lvoDate2Amiga),
    vec(lvoCheckDate),
    vec(lvoSMult32),
    vec(lvoUMult32),
    vec(lvoSDivMod32),
    vec(lvoUDivMod32),
    vec(lvoStricmp),
    vec(lvoStrnicmp),
    vec(lvoToUpper),
    vec(lvoToLower),
    vec(lvoApplyTagChanges),
    vec(reserved), // for MergeTagItems
    vec(lvoSMult64),
    vec(lvoUMult64),
    vec(lvoPackStructureTags),
    vec(lvoUnpackStructureTags),
    vec(lvoAddNamedObject),
    vec(lvoAllocNamedObjectA),
    vec(lvoAttemptRemNamedObject),
    vec(lvoFindNamedObject),
    vec(lvoFreeNamedObject),
    vec(lvoNamedObjectName),
    vec(lvoReleaseNamedObject),
    vec(lvoRemNamedObject),
    vec(lvoGetUniqueID),
    // "empty functions for setpatch!"
    vec(reserved),
    vec(reserved),
    vec(reserved),
    vec(reserved),
    vec(lvoParsePattern),
    vec(lvoParsePatternNoCase),
    vec(lvoMatchPattern),
    vec(lvoMatchPatternNoCase),
    vec(lvoSetWildStar),
    vec(lvoStrcmp),
    vec(lvoStrlen),
    vec(lvoAlignUp),
    vec(lvoAlignDown),
    vec(lvoStrlcpy),
    vec(lvoStrchr),
    vec(lvoStrrchr),
    vec(lvoDateSplit),
    vec(lvoDateJoin),
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "the jump table: every slot, every LVO at its function" {
    try testing.expectEqual(@as(usize, 63), vectors.len);
    inline for (@typeInfo(LVO).@"struct".decls) |d| {
        const index: usize = @intCast(@divExact(-@field(LVO, d.name), exec.slot_size) - 1);
        try testing.expectEqual(vec(@field(@This(), "lvo" ++ d.name)), vectors[index]);
    }
}

test "every wrapper hands its parameters on, in order, to the call it is named after" {
    try exec.libraries.checkForwarding(@embedFile("utility_lvo.zig"), LVO, &.{});
}
