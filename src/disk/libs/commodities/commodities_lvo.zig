// SPDX-License-Identifier: MIT
//! commodities.library's jump table: every `lvo<Name>` wrapper, the table
//! of them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const cx = sdk.commodities;
const keymap = sdk.keymap;
const ie = sdk.devices.inputevent;
const vec = exec.vec;
const CxBase = @import("commodities_base.zig").CxBase;
const commodities_init = @import("commodities_init.zig");

const CreateCxObj = @import("object/createcxobj.zig").CreateCxObj;
const CxBroker = @import("broker/cxbroker.zig").CxBroker;
const ActivateCxObj = @import("object/activatecxobj.zig").ActivateCxObj;
const DeleteCxObj = @import("object/deletecxobj.zig").DeleteCxObj;
const DeleteCxObjAll = @import("object/deletecxobjall.zig").DeleteCxObjAll;
const CxObjType = @import("object/cxobjtype.zig").CxObjType;
const CxObjError = @import("object/cxobjerror.zig").CxObjError;
const ClearCxObjError = @import("object/clearcxobjerror.zig").ClearCxObjError;
const SetCxObjPri = @import("object/setcxobjpri.zig").SetCxObjPri;
const AttachCxObj = @import("attach/attachcxobj.zig").AttachCxObj;
const EnqueueCxObj = @import("attach/enqueuecxobj.zig").EnqueueCxObj;
const InsertCxObj = @import("attach/insertcxobj.zig").InsertCxObj;
const RemoveCxObj = @import("attach/removecxobj.zig").RemoveCxObj;
const SetTranslate = @import("object/settranslate.zig").SetTranslate;
const SetFilter = @import("filter/setfilter.zig").SetFilter;
const SetFilterIX = @import("filter/setfilterix.zig").SetFilterIX;
const ParseIX = @import("filter/parseix.zig").ParseIX;
const CxMsgType = @import("message/cxmsgtype.zig").CxMsgType;
const CxMsgData = @import("message/cxmsgdata.zig").CxMsgData;
const CxMsgID = @import("message/cxmsgid.zig").CxMsgID;
const DivertCxMsg = @import("message/divertcxmsg.zig").DivertCxMsg;
const RouteCxMsg = @import("message/routecxmsg.zig").RouteCxMsg;
const DisposeCxMsg = @import("message/disposecxmsg.zig").DisposeCxMsg;
const InvertKeyMap = @import("input/invertkeymap.zig").InvertKeyMap;
const AddIEvents = @import("input/addievents.zig").AddIEvents;
const CopyBrokerList = @import("broker/copybrokerlist.zig").CopyBrokerList;
const FreeBrokerList = @import("broker/freebrokerlist.zig").FreeBrokerList;
const BrokerCommand = @import("broker/brokercommand.zig").BrokerCommand;
const MatchIX = @import("filter/matchix.zig").MatchIX;

/// commodities.library's interface, as the SDK generates it from
/// sdk/fd/commodities_lib.fd.
const interface = sdk.interface.commodities;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("commodities.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(100_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "commodities.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("object/createcxobj.zig"),
    @embedFile("broker/cxbroker.zig"),
    @embedFile("object/activatecxobj.zig"),
    @embedFile("object/deletecxobj.zig"),
    @embedFile("object/deletecxobjall.zig"),
    @embedFile("object/cxobjtype.zig"),
    @embedFile("object/cxobjerror.zig"),
    @embedFile("object/clearcxobjerror.zig"),
    @embedFile("object/setcxobjpri.zig"),
    @embedFile("attach/attachcxobj.zig"),
    @embedFile("attach/enqueuecxobj.zig"),
    @embedFile("attach/insertcxobj.zig"),
    @embedFile("attach/removecxobj.zig"),
    @embedFile("object/settranslate.zig"),
    @embedFile("filter/setfilter.zig"),
    @embedFile("filter/setfilterix.zig"),
    @embedFile("filter/parseix.zig"),
    @embedFile("message/cxmsgtype.zig"),
    @embedFile("message/cxmsgdata.zig"),
    @embedFile("message/cxmsgid.zig"),
    @embedFile("message/divertcxmsg.zig"),
    @embedFile("message/routecxmsg.zig"),
    @embedFile("message/disposecxmsg.zig"),
    @embedFile("input/invertkeymap.zig"),
    @embedFile("input/addievents.zig"),
    @embedFile("broker/copybrokerlist.zig"),
    @embedFile("broker/freebrokerlist.zig"),
    @embedFile("broker/brokercommand.zig"),
    @embedFile("filter/matchix.zig"),
};

fn lvoCreateCxObj(base: *CxBase, kind: u32, arg1: usize, arg2: usize) callconv(.c) ?*cx.CxObj {
    return CreateCxObj(base, kind, arg1, arg2);
}
fn lvoCxBroker(base: *CxBase, nb: *const cx.NewBroker, err: ?*i32) callconv(.c) ?*cx.CxObj {
    return CxBroker(base, nb, err);
}
fn lvoActivateCxObj(base: *CxBase, co: ?*cx.CxObj, active: bool) callconv(.c) bool {
    return ActivateCxObj(base, co, active);
}
fn lvoDeleteCxObj(base: *CxBase, co: ?*cx.CxObj) callconv(.c) void {
    return DeleteCxObj(base, co);
}
fn lvoDeleteCxObjAll(base: *CxBase, co: ?*cx.CxObj) callconv(.c) void {
    return DeleteCxObjAll(base, co);
}
fn lvoCxObjType(base: *CxBase, co: ?*cx.CxObj) callconv(.c) u32 {
    return CxObjType(base, co);
}
fn lvoCxObjError(base: *CxBase, co: ?*cx.CxObj) callconv(.c) u32 {
    return CxObjError(base, co);
}
fn lvoClearCxObjError(base: *CxBase, co: ?*cx.CxObj) callconv(.c) void {
    return ClearCxObjError(base, co);
}
fn lvoSetCxObjPri(base: *CxBase, co: ?*cx.CxObj, pri: i32) callconv(.c) i32 {
    return SetCxObjPri(base, co, pri);
}
fn lvoAttachCxObj(base: *CxBase, head_obj: ?*cx.CxObj, co: ?*cx.CxObj) callconv(.c) void {
    return AttachCxObj(base, head_obj, co);
}
fn lvoEnqueueCxObj(base: *CxBase, head_obj: ?*cx.CxObj, co: ?*cx.CxObj) callconv(.c) void {
    return EnqueueCxObj(base, head_obj, co);
}
fn lvoInsertCxObj(base: *CxBase, head_obj: ?*cx.CxObj, co: ?*cx.CxObj, pred: ?*cx.CxObj) callconv(.c) void {
    return InsertCxObj(base, head_obj, co, pred);
}
fn lvoRemoveCxObj(base: *CxBase, co: ?*cx.CxObj) callconv(.c) void {
    return RemoveCxObj(base, co);
}
fn lvoSetTranslate(base: *CxBase, translator: ?*cx.CxObj, events: ?*const ie.InputEvent) callconv(.c) void {
    return SetTranslate(base, translator, events);
}
fn lvoSetFilter(base: *CxBase, filter: ?*cx.CxObj, text: ?[*:0]const u8) callconv(.c) void {
    return SetFilter(base, filter, text);
}
fn lvoSetFilterIX(base: *CxBase, filter: ?*cx.CxObj, ix: *const cx.InputXpression) callconv(.c) void {
    return SetFilterIX(base, filter, ix);
}
fn lvoParseIX(base: *CxBase, description: ?[*:0]const u8, ix: *cx.InputXpression) callconv(.c) i32 {
    return ParseIX(base, description, ix);
}
fn lvoCxMsgType(base: *CxBase, cxm: *const cx.CxMsg) callconv(.c) u32 {
    return CxMsgType(base, cxm);
}
fn lvoCxMsgData(base: *CxBase, cxm: ?*cx.CxMsg) callconv(.c) ?*ie.InputEvent {
    return CxMsgData(base, cxm);
}
fn lvoCxMsgID(base: *CxBase, cxm: *const cx.CxMsg) callconv(.c) i32 {
    return CxMsgID(base, cxm);
}
fn lvoDivertCxMsg(base: *CxBase, cxm: *cx.CxMsg, head_obj: *cx.CxObj, return_obj: *cx.CxObj) callconv(.c) void {
    return DivertCxMsg(base, cxm, head_obj, return_obj);
}
fn lvoRouteCxMsg(base: *CxBase, cxm: *cx.CxMsg, co: *cx.CxObj) callconv(.c) void {
    return RouteCxMsg(base, cxm, co);
}
fn lvoDisposeCxMsg(base: *CxBase, cxm: *cx.CxMsg) callconv(.c) void {
    return DisposeCxMsg(base, cxm);
}
fn lvoInvertKeyMap(base: *CxBase, ansi_code: u32, event: *ie.InputEvent, key_map: ?*const keymap.KeyMap) callconv(.c) bool {
    return InvertKeyMap(base, ansi_code, event, key_map);
}
fn lvoAddIEvents(base: *CxBase, events: ?*const ie.InputEvent) callconv(.c) void {
    return AddIEvents(base, events);
}
fn lvoCopyBrokerList(base: *CxBase, list: *exec.List) callconv(.c) i32 {
    return CopyBrokerList(base, list);
}
fn lvoFreeBrokerList(base: *CxBase, list: *exec.List) callconv(.c) void {
    return FreeBrokerList(base, list);
}
fn lvoBrokerCommand(base: *CxBase, name: ?[*:0]const u8, id: i32) callconv(.c) i32 {
    return BrokerCommand(base, name, id);
}
fn lvoMatchIX(base: *CxBase, event: *const ie.InputEvent, ix: *const cx.InputXpression) callconv(.c) bool {
    return MatchIX(base, event, ix);
}

pub const vectors = [_]*const anyopaque{
    vec(commodities_init.openVector),
    vec(commodities_init.closeVector),
    vec(commodities_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoCreateCxObj),
    vec(lvoCxBroker),
    vec(lvoActivateCxObj),
    vec(lvoDeleteCxObj),
    vec(lvoDeleteCxObjAll),
    vec(lvoCxObjType),
    vec(lvoCxObjError),
    vec(lvoClearCxObjError),
    vec(lvoSetCxObjPri),
    vec(lvoAttachCxObj),
    vec(lvoEnqueueCxObj),
    vec(lvoInsertCxObj),
    vec(lvoRemoveCxObj),
    vec(lvoSetTranslate),
    vec(lvoSetFilter),
    vec(lvoSetFilterIX),
    vec(lvoParseIX),
    vec(lvoCxMsgType),
    vec(lvoCxMsgData),
    vec(lvoCxMsgID),
    vec(lvoDivertCxMsg),
    vec(lvoRouteCxMsg),
    vec(lvoDisposeCxMsg),
    vec(lvoInvertKeyMap),
    vec(lvoAddIEvents),
    vec(lvoCopyBrokerList),
    vec(lvoFreeBrokerList),
    vec(lvoBrokerCommand),
    vec(lvoMatchIX),
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
    try exec.libraries.checkForwarding(@embedFile("commodities_lvo.zig"), LVO, &.{});
}
