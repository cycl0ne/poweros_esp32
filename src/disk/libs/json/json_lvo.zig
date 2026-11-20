// SPDX-License-Identifier: MIT
//! json.library's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const json = sdk.json;
const vec = exec.vec;
const JSONBase = @import("json_base.zig").JSONBase;
const json_init = @import("json_init.zig");

const ParseJSON = @import("read/parsejson.zig").ParseJSON;
const ReadJSONFile = @import("read/readjsonfile.zig").ReadJSONFile;
const DisposeJSONDocument = @import("document/disposejsondocument.zig").DisposeJSONDocument;
const FindJSONMember = @import("find/findjsonmember.zig").FindJSONMember;
const GetJSONItem = @import("find/getjsonitem.zig").GetJSONItem;
const FindJSONPointer = @import("find/findjsonpointer.zig").FindJSONPointer;
const CountJSONValues = @import("find/countjsonvalues.zig").CountJSONValues;
const GetJSONNumber = @import("value/getjsonnumber.zig").GetJSONNumber;
const GetJSONInteger = @import("value/getjsoninteger.zig").GetJSONInteger;
const GetJSONString = @import("value/getjsonstring.zig").GetJSONString;
const GetJSONBool = @import("value/getjsonbool.zig").GetJSONBool;
const CreateJSONDocument = @import("document/createjsondocument.zig").CreateJSONDocument;
const CreateJSONValue = @import("build/createjsonvalue.zig").CreateJSONValue;
const CreateJSONNumber = @import("build/createjsonnumber.zig").CreateJSONNumber;
const CreateJSONInteger = @import("build/createjsoninteger.zig").CreateJSONInteger;
const CreateJSONString = @import("build/createjsonstring.zig").CreateJSONString;
const CreateJSONBool = @import("build/createjsonbool.zig").CreateJSONBool;
const CopyJSONValue = @import("build/copyjsonvalue.zig").CopyJSONValue;
const SetJSONMember = @import("build/setjsonmember.zig").SetJSONMember;
const InsertJSONItem = @import("build/insertjsonitem.zig").InsertJSONItem;
const RemoveJSONValue = @import("build/removejsonvalue.zig").RemoveJSONValue;
const SetJSONRoot = @import("document/setjsonroot.zig").SetJSONRoot;
const FormatJSON = @import("write/formatjson.zig").FormatJSON;
const WriteJSONFile = @import("write/writejsonfile.zig").WriteJSONFile;

/// json.library's interface, as the SDK generates it from
/// sdk/fd/json_lib.fd.
const interface = sdk.interface.json;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("json.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every call's contract is in the list, once, and documents the LVO the
// .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    exec.libraries.checkContractFiles(&contract_files, LVO, "json.library", "pub fn ");
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("read/parsejson.zig"),
    @embedFile("read/readjsonfile.zig"),
    @embedFile("document/disposejsondocument.zig"),
    @embedFile("find/findjsonmember.zig"),
    @embedFile("find/getjsonitem.zig"),
    @embedFile("find/findjsonpointer.zig"),
    @embedFile("find/countjsonvalues.zig"),
    @embedFile("value/getjsonnumber.zig"),
    @embedFile("value/getjsoninteger.zig"),
    @embedFile("value/getjsonstring.zig"),
    @embedFile("value/getjsonbool.zig"),
    @embedFile("document/createjsondocument.zig"),
    @embedFile("build/createjsonvalue.zig"),
    @embedFile("build/createjsonnumber.zig"),
    @embedFile("build/createjsoninteger.zig"),
    @embedFile("build/createjsonstring.zig"),
    @embedFile("build/createjsonbool.zig"),
    @embedFile("build/copyjsonvalue.zig"),
    @embedFile("build/setjsonmember.zig"),
    @embedFile("build/insertjsonitem.zig"),
    @embedFile("build/removejsonvalue.zig"),
    @embedFile("document/setjsonroot.zig"),
    @embedFile("write/formatjson.zig"),
    @embedFile("write/writejsonfile.zig"),
};

fn lvoParseJSON(base: *JSONBase, text: [*]const u8, length: usize, flags: u32, report: ?*json.Error) callconv(.c) ?*json.Document {
    return ParseJSON(base, text, length, flags, report);
}
fn lvoReadJSONFile(base: *JSONBase, name: [*:0]const u8, flags: u32, report: ?*json.Error) callconv(.c) ?*json.Document {
    return ReadJSONFile(base, name, flags, report);
}
fn lvoDisposeJSONDocument(base: *JSONBase, document: ?*json.Document) callconv(.c) void {
    return DisposeJSONDocument(base, document);
}
fn lvoFindJSONMember(base: *JSONBase, object: ?*const json.Value, name: [*:0]const u8) callconv(.c) ?*json.Value {
    return FindJSONMember(base, object, name);
}
fn lvoGetJSONItem(base: *JSONBase, container: ?*const json.Value, index: u32) callconv(.c) ?*json.Value {
    return GetJSONItem(base, container, index);
}
fn lvoFindJSONPointer(base: *JSONBase, from: ?*const json.Value, pointer: [*:0]const u8) callconv(.c) ?*json.Value {
    return FindJSONPointer(base, from, pointer);
}
fn lvoCountJSONValues(base: *JSONBase, container: ?*const json.Value) callconv(.c) u32 {
    return CountJSONValues(base, container);
}
fn lvoGetJSONNumber(base: *JSONBase, value: ?*const json.Value, number: *f64) callconv(.c) bool {
    return GetJSONNumber(base, value, number);
}
fn lvoGetJSONInteger(base: *JSONBase, value: ?*const json.Value, integer: *i64) callconv(.c) bool {
    return GetJSONInteger(base, value, integer);
}
fn lvoGetJSONString(base: *JSONBase, value: ?*const json.Value, length: ?*u32) callconv(.c) ?[*:0]const u8 {
    return GetJSONString(base, value, length);
}
fn lvoGetJSONBool(base: *JSONBase, value: ?*const json.Value, truth: *bool) callconv(.c) bool {
    return GetJSONBool(base, value, truth);
}
fn lvoCreateJSONDocument(base: *JSONBase) callconv(.c) ?*json.Document {
    return CreateJSONDocument(base);
}
fn lvoCreateJSONValue(base: *JSONBase, document: *json.Document, kind: u32) callconv(.c) ?*json.Value {
    return CreateJSONValue(base, document, kind);
}
fn lvoCreateJSONNumber(base: *JSONBase, document: *json.Document, number: f64) callconv(.c) ?*json.Value {
    return CreateJSONNumber(base, document, number);
}
fn lvoCreateJSONInteger(base: *JSONBase, document: *json.Document, integer: i64) callconv(.c) ?*json.Value {
    return CreateJSONInteger(base, document, integer);
}
fn lvoCreateJSONString(base: *JSONBase, document: *json.Document, text: [*]const u8, length: u32) callconv(.c) ?*json.Value {
    return CreateJSONString(base, document, text, length);
}
fn lvoCreateJSONBool(base: *JSONBase, document: *json.Document, truth: bool) callconv(.c) ?*json.Value {
    return CreateJSONBool(base, document, truth);
}
fn lvoCopyJSONValue(base: *JSONBase, document: *json.Document, value: *const json.Value) callconv(.c) ?*json.Value {
    return CopyJSONValue(base, document, value);
}
fn lvoSetJSONMember(base: *JSONBase, object: *json.Value, name: [*:0]const u8, value: *json.Value) callconv(.c) bool {
    return SetJSONMember(base, object, name, value);
}
fn lvoInsertJSONItem(base: *JSONBase, array: *json.Value, value: *json.Value, index: u32) callconv(.c) bool {
    return InsertJSONItem(base, array, value, index);
}
fn lvoRemoveJSONValue(base: *JSONBase, value: *json.Value) callconv(.c) void {
    return RemoveJSONValue(base, value);
}
fn lvoSetJSONRoot(base: *JSONBase, document: *json.Document, value: ?*json.Value) callconv(.c) bool {
    return SetJSONRoot(base, document, value);
}
fn lvoFormatJSON(base: *JSONBase, value: ?*const json.Value, buffer: ?[*]u8, size: usize, flags: u32) callconv(.c) usize {
    return FormatJSON(base, value, buffer, size, flags);
}
fn lvoWriteJSONFile(base: *JSONBase, value: ?*const json.Value, name: [*:0]const u8, flags: u32) callconv(.c) bool {
    return WriteJSONFile(base, value, name, flags);
}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(json_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoParseJSON),
    vec(lvoReadJSONFile),
    vec(lvoDisposeJSONDocument),
    vec(lvoFindJSONMember),
    vec(lvoGetJSONItem),
    vec(lvoFindJSONPointer),
    vec(lvoCountJSONValues),
    vec(lvoGetJSONNumber),
    vec(lvoGetJSONInteger),
    vec(lvoGetJSONString),
    vec(lvoGetJSONBool),
    vec(lvoCreateJSONDocument),
    vec(lvoCreateJSONValue),
    vec(lvoCreateJSONNumber),
    vec(lvoCreateJSONInteger),
    vec(lvoCreateJSONString),
    vec(lvoCreateJSONBool),
    vec(lvoCopyJSONValue),
    vec(lvoSetJSONMember),
    vec(lvoInsertJSONItem),
    vec(lvoRemoveJSONValue),
    vec(lvoSetJSONRoot),
    vec(lvoFormatJSON),
    vec(lvoWriteJSONFile),
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
    try exec.libraries.checkForwarding(@embedFile("json_lvo.zig"), LVO, &.{});
}
