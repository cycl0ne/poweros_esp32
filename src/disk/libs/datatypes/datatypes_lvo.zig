// SPDX-License-Identifier: MIT
//! datatypes.library's jump table: every `lvo<Name>` wrapper, the table
//! of them in slot order, and the checks that hold the table to the
//! SDK's contract - the signatures and the documented LVOs at compile
//! time, the slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classusr = intuition.classusr;
const gadgetclass = intuition.gadgetclass;
const datatypes = sdk.datatypes;
const vec = exec.vec;
const DataTypesBase = @import("datatypes_base.zig").DataTypesBase;
const datatypes_init = @import("datatypes_init.zig");

const ObtainDataTypeA = @import("type/obtaindatatypea.zig").ObtainDataTypeA;
const ReleaseDataType = @import("type/releasedatatype.zig").ReleaseDataType;
const NewDTObjectA = @import("object/newdtobjecta.zig").NewDTObjectA;
const DisposeDTObject = @import("object/disposedtobject.zig").DisposeDTObject;
const SetDTAttrsA = @import("attrs/setdtattrsa.zig").SetDTAttrsA;
const GetDTAttrsA = @import("attrs/getdtattrsa.zig").GetDTAttrsA;
const AddDTObject = @import("object/adddtobject.zig").AddDTObject;
const RemoveDTObject = @import("object/removedtobject.zig").RemoveDTObject;
const RefreshDTObjectA = @import("object/refreshdtobjecta.zig").RefreshDTObjectA;
const DoAsyncLayout = @import("layout/doasynclayout.zig").DoAsyncLayout;
const DoDTMethodA = @import("attrs/dodtmethoda.zig").DoDTMethodA;
const GetDTMethods = @import("attrs/getdtmethods.zig").GetDTMethods;
const GetDTTriggerMethods = @import("attrs/getdttriggermethods.zig").GetDTTriggerMethods;
const ObtainDTDrawInfoA = @import("draw/obtaindtdrawinfoa.zig").ObtainDTDrawInfoA;
const DrawDTObjectA = @import("draw/drawdtobjecta.zig").DrawDTObjectA;
const ReleaseDTDrawInfo = @import("draw/releasedtdrawinfo.zig").ReleaseDTDrawInfo;
const GetDTString = @import("text/getdtstring.zig").GetDTString;

/// datatypes.library's interface, as the SDK generates it from
/// sdk/fd/datatypes_lib.fd.
const interface = sdk.interface.datatypes;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("datatypes.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(100_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "datatypes.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("type/obtaindatatypea.zig"),
    @embedFile("type/releasedatatype.zig"),
    @embedFile("object/newdtobjecta.zig"),
    @embedFile("object/disposedtobject.zig"),
    @embedFile("attrs/setdtattrsa.zig"),
    @embedFile("attrs/getdtattrsa.zig"),
    @embedFile("object/adddtobject.zig"),
    @embedFile("object/removedtobject.zig"),
    @embedFile("object/refreshdtobjecta.zig"),
    @embedFile("layout/doasynclayout.zig"),
    @embedFile("attrs/dodtmethoda.zig"),
    @embedFile("attrs/getdtmethods.zig"),
    @embedFile("attrs/getdttriggermethods.zig"),
    @embedFile("draw/obtaindtdrawinfoa.zig"),
    @embedFile("draw/drawdtobjecta.zig"),
    @embedFile("draw/releasedtdrawinfo.zig"),
    @embedFile("text/getdtstring.zig"),
};

// --- the wrappers -----------------------------------------------------------

fn lvoObtainDataTypeA(db: *DataTypesBase, source_type: u32, handle: ?*anyopaque, attrs: ?[*]const utility.TagItem) callconv(.c) ?*datatypes.DataType {
    return ObtainDataTypeA(db, source_type, handle, attrs);
}
fn lvoReleaseDataType(db: *DataTypesBase, dt: ?*datatypes.DataType) callconv(.c) void {
    return ReleaseDataType(db, dt);
}
fn lvoNewDTObjectA(db: *DataTypesBase, name: ?[*:0]const u8, attrs: ?[*]const utility.TagItem) callconv(.c) ?*classusr.Object {
    return NewDTObjectA(db, name, attrs);
}
fn lvoDisposeDTObject(db: *DataTypesBase, object: ?*classusr.Object) callconv(.c) void {
    return DisposeDTObject(db, object);
}
fn lvoSetDTAttrsA(db: *DataTypesBase, object: ?*classusr.Object, window: ?*intuition.Window, requester: ?*intuition.Requester, attrs: ?[*]const utility.TagItem) callconv(.c) u32 {
    return SetDTAttrsA(db, object, window, requester, attrs);
}
fn lvoGetDTAttrsA(db: *DataTypesBase, object: ?*classusr.Object, attrs: ?[*]const utility.TagItem) callconv(.c) u32 {
    return GetDTAttrsA(db, object, attrs);
}
fn lvoAddDTObject(db: *DataTypesBase, window: ?*intuition.Window, requester: ?*intuition.Requester, object: ?*classusr.Object, position: i32) callconv(.c) i32 {
    return AddDTObject(db, window, requester, object, position);
}
fn lvoRemoveDTObject(db: *DataTypesBase, window: ?*intuition.Window, object: ?*classusr.Object) callconv(.c) i32 {
    return RemoveDTObject(db, window, object);
}
fn lvoRefreshDTObjectA(db: *DataTypesBase, object: ?*classusr.Object, window: ?*intuition.Window, requester: ?*intuition.Requester, attrs: ?[*]const utility.TagItem) callconv(.c) void {
    return RefreshDTObjectA(db, object, window, requester, attrs);
}
fn lvoDoAsyncLayout(db: *DataTypesBase, object: *classusr.Object, layout: *gadgetclass.GpLayout) callconv(.c) u32 {
    return DoAsyncLayout(db, object, layout);
}
fn lvoDoDTMethodA(db: *DataTypesBase, object: *classusr.Object, window: ?*intuition.Window, requester: ?*intuition.Requester, msg: *classusr.Msg) callconv(.c) u32 {
    return DoDTMethodA(db, object, window, requester, msg);
}
fn lvoGetDTMethods(db: *DataTypesBase, object: *classusr.Object) callconv(.c) ?[*]const u32 {
    return GetDTMethods(db, object);
}
fn lvoGetDTTriggerMethods(db: *DataTypesBase, object: *classusr.Object) callconv(.c) ?[*]const datatypes.datatypesclass.DTMethod {
    return GetDTTriggerMethods(db, object);
}
fn lvoObtainDTDrawInfoA(db: *DataTypesBase, object: *classusr.Object, attrs: ?[*]const utility.TagItem) callconv(.c) ?*anyopaque {
    return ObtainDTDrawInfoA(db, object, attrs);
}
fn lvoDrawDTObjectA(db: *DataTypesBase, rast_port: *graphics.RastPort, object: *classusr.Object, left: i32, top: i32, width: i32, height: i32, top_horiz: i32, top_vert: i32, attrs: ?[*]const utility.TagItem) callconv(.c) bool {
    return DrawDTObjectA(db, rast_port, object, left, top, width, height, top_horiz, top_vert, attrs);
}
fn lvoReleaseDTDrawInfo(db: *DataTypesBase, object: *classusr.Object, handle: ?*anyopaque) callconv(.c) void {
    return ReleaseDTDrawInfo(db, object, handle);
}
fn lvoGetDTString(db: *DataTypesBase, id: u32) callconv(.c) [*:0]const u8 {
    return GetDTString(db, id);
}

pub const vectors = [_]*const anyopaque{
    vec(datatypes_init.openVector),
    vec(datatypes_init.closeVector),
    vec(datatypes_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoObtainDataTypeA),
    vec(lvoReleaseDataType),
    vec(lvoNewDTObjectA),
    vec(lvoDisposeDTObject),
    vec(lvoSetDTAttrsA),
    vec(lvoGetDTAttrsA),
    vec(lvoAddDTObject),
    vec(lvoRemoveDTObject),
    vec(lvoRefreshDTObjectA),
    vec(lvoDoAsyncLayout),
    vec(lvoDoDTMethodA),
    vec(lvoGetDTMethods),
    vec(lvoGetDTTriggerMethods),
    vec(lvoObtainDTDrawInfoA),
    vec(lvoDrawDTObjectA),
    vec(lvoReleaseDTDrawInfo),
    vec(lvoGetDTString),
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
    try exec.libraries.checkForwarding(@embedFile("datatypes_lvo.zig"), LVO, &.{});
}
