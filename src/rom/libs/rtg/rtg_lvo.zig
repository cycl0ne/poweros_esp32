// SPDX-License-Identifier: MPL-2.0
//! rtg.library's jump table: every `lvo<Name>` wrapper, the table of them
//! in slot order, and the checks that hold the table to the SDK's contract
//! - the signatures and the documented LVOs at compile time, the slots and
//! the forwarding in the tests at the end.
//!
//! Each wrapper is the slot a caller reaches through the table. It hands
//! the work to the call - a file of its own in the folder for its
//! category - with the library's base first.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const vec = exec.vec;
const rtg_base = @import("rtg_base.zig");
const RtgBase = rtg_base.RtgBase;

const AddRtgDriver = @import("driver/addrtgdriver.zig").AddRtgDriver;
const RemRtgDriver = @import("driver/remrtgdriver.zig").RemRtgDriver;
const FindRtgDriver = @import("driver/findrtgdriver.zig").FindRtgDriver;
const LockRtgDrivers = @import("driver/lockrtgdrivers.zig").LockRtgDrivers;
const UnlockRtgDrivers = @import("driver/unlockrtgdrivers.zig").UnlockRtgDrivers;
const NextRtgDriver = @import("driver/nextrtgdriver.zig").NextRtgDriver;
const CreateBoardTagList = @import("board/createboardtaglist.zig").CreateBoardTagList;
const DeleteBoard = @import("board/deleteboard.zig").DeleteBoard;
const NextBoard = @import("board/nextboard.zig").NextBoard;
const FindBoard = @import("board/findboard.zig").FindBoard;
const GetBoardInfo = @import("board/getboardinfo.zig").GetBoardInfo;
const GetBoardStats = @import("board/getboardstats.zig").GetBoardStats;
const BoardControl = @import("board/boardcontrol.zig").BoardControl;
const NextBoardMode = @import("board/nextboardmode.zig").NextBoardMode;
const FindBoardMode = @import("board/findboardmode.zig").FindBoardMode;
const SetBoardMode = @import("board/setboardmode.zig").SetBoardMode;
const BoardMode = @import("board/boardmode.zig").BoardMode;
const AllocBitMap = @import("bitmap/allocbitmap.zig").AllocBitMap;
const AttachBitMap = @import("bitmap/attachbitmap.zig").AttachBitMap;
const FreeBitMap = @import("bitmap/freebitmap.zig").FreeBitMap;
const ShowBitMap = @import("display/showbitmap.zig").ShowBitMap;
const BoardDisplayBitMap = @import("display/boarddisplaybitmap.zig").BoardDisplayBitMap;
const RefreshBitMap = @import("bitmap/refreshbitmap.zig").RefreshBitMap;
const WaitVBlank = @import("display/waitvblank.zig").WaitVBlank;
const SetBoardDisplay = @import("display/setboarddisplay.zig").SetBoardDisplay;
const SetBoardBrightness = @import("display/setboardbrightness.zig").SetBoardBrightness;
const BoardBrightness = @import("display/boardbrightness.zig").BoardBrightness;
const FillRect = @import("engine/fillrect.zig").FillRect;
const InvertRect = @import("engine/invertrect.zig").InvertRect;
const CopyRect = @import("engine/copyrect.zig").CopyRect;
const BlitTemplate = @import("engine/blittemplate.zig").BlitTemplate;
const BlitPattern = @import("engine/blitpattern.zig").BlitPattern;
const WaitBlit = @import("engine/waitblit.zig").WaitBlit;
const PackRtgColor = @import("engine/packrtgcolor.zig").PackRtgColor;
const UnpackRtgColor = @import("engine/unpackrtgcolor.zig").UnpackRtgColor;
const AddRtgEventServer = @import("event/addrtgeventserver.zig").AddRtgEventServer;
const RemRtgEventServer = @import("event/remrtgeventserver.zig").RemRtgEventServer;
const SignalRtgEvent = @import("event/signalrtgevent.zig").SignalRtgEvent;
const CreateTransportTagList = @import("transport/createtransporttaglist.zig").CreateTransportTagList;
const DeleteTransport = @import("transport/deletetransport.zig").DeleteTransport;
const TxParam = @import("transport/txparam.zig").TxParam;
const TxColor = @import("transport/txcolor.zig").TxColor;
const RxParam = @import("transport/rxparam.zig").RxParam;
const GetRtgTagData = @import("tag/getrtgtagdata.zig").GetRtgTagData;
const FindRtgTagItem = @import("tag/findrtgtagitem.zig").FindRtgTagItem;
const RtgLastError = @import("errors/rtglasterror.zig").RtgLastError;
const RtgErrorText = @import("errors/rtgerrortext.zig").RtgErrorText;
const MirrorBoard = @import("display/mirrorboard.zig").MirrorBoard;
const SwapBoardAxes = @import("display/swapboardaxes.zig").SwapBoardAxes;
const SetBoardGap = @import("display/setboardgap.zig").SetBoardGap;

/// rtg.library's interface, as the SDK generates it from sdk/fd/rtg_lib.fd.
const interface = sdk.interface.rtg;
const LVO = interface.LVO;

// Every function in LVO is an lvo* function here, with the SDK's signature
// (after the base), in its slot.
comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("rtg.library's lvo" ++ d.name ++ " doesn't match the SDK's Fn." ++ d.name);
        }
        if (vectors[@divExact(-@field(LVO, d.name), exec.slot_size) - 1] != vec(f)) {
            @compileError("rtg.library's lvo" ++ d.name ++ " isn't in the slot of LVO." ++ d.name);
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(50_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "rtg.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`: every
/// call of the table.
const contract_files = [_][]const u8{
    @embedFile("driver/addrtgdriver.zig"),
    @embedFile("driver/remrtgdriver.zig"),
    @embedFile("driver/findrtgdriver.zig"),
    @embedFile("driver/lockrtgdrivers.zig"),
    @embedFile("driver/unlockrtgdrivers.zig"),
    @embedFile("driver/nextrtgdriver.zig"),
    @embedFile("board/createboardtaglist.zig"),
    @embedFile("board/deleteboard.zig"),
    @embedFile("board/nextboard.zig"),
    @embedFile("board/findboard.zig"),
    @embedFile("board/getboardinfo.zig"),
    @embedFile("board/getboardstats.zig"),
    @embedFile("board/boardcontrol.zig"),
    @embedFile("board/nextboardmode.zig"),
    @embedFile("board/findboardmode.zig"),
    @embedFile("board/setboardmode.zig"),
    @embedFile("board/boardmode.zig"),
    @embedFile("bitmap/allocbitmap.zig"),
    @embedFile("bitmap/attachbitmap.zig"),
    @embedFile("bitmap/freebitmap.zig"),
    @embedFile("display/showbitmap.zig"),
    @embedFile("display/boarddisplaybitmap.zig"),
    @embedFile("bitmap/refreshbitmap.zig"),
    @embedFile("display/waitvblank.zig"),
    @embedFile("display/setboarddisplay.zig"),
    @embedFile("display/setboardbrightness.zig"),
    @embedFile("display/boardbrightness.zig"),
    @embedFile("engine/fillrect.zig"),
    @embedFile("engine/invertrect.zig"),
    @embedFile("engine/copyrect.zig"),
    @embedFile("engine/blittemplate.zig"),
    @embedFile("engine/blitpattern.zig"),
    @embedFile("engine/waitblit.zig"),
    @embedFile("engine/packrtgcolor.zig"),
    @embedFile("engine/unpackrtgcolor.zig"),
    @embedFile("event/addrtgeventserver.zig"),
    @embedFile("event/remrtgeventserver.zig"),
    @embedFile("event/signalrtgevent.zig"),
    @embedFile("transport/createtransporttaglist.zig"),
    @embedFile("transport/deletetransport.zig"),
    @embedFile("transport/txparam.zig"),
    @embedFile("transport/txcolor.zig"),
    @embedFile("transport/rxparam.zig"),
    @embedFile("tag/getrtgtagdata.zig"),
    @embedFile("tag/findrtgtagitem.zig"),
    @embedFile("errors/rtglasterror.zig"),
    @embedFile("errors/rtgerrortext.zig"),
    @embedFile("display/mirrorboard.zig"),
    @embedFile("display/swapboardaxes.zig"),
    @embedFile("display/setboardgap.zig"),
};

fn lvoAddRtgDriver(rb: *RtgBase, driver: *rtg.RtgDriver) callconv(.c) bool {
    return AddRtgDriver(rb, driver);
}
fn lvoRemRtgDriver(rb: *RtgBase, driver: *rtg.RtgDriver) callconv(.c) bool {
    return RemRtgDriver(rb, driver);
}
fn lvoFindRtgDriver(rb: *RtgBase, driver_name: [*:0]const u8) callconv(.c) ?*rtg.RtgDriver {
    return FindRtgDriver(rb, driver_name);
}
fn lvoLockRtgDrivers(rb: *RtgBase) callconv(.c) void {
    LockRtgDrivers(rb);
}
fn lvoUnlockRtgDrivers(rb: *RtgBase) callconv(.c) void {
    UnlockRtgDrivers(rb);
}
fn lvoNextRtgDriver(rb: *RtgBase, after: ?*rtg.RtgDriver) callconv(.c) ?*rtg.RtgDriver {
    return NextRtgDriver(rb, after);
}
fn lvoCreateBoardTagList(rb: *RtgBase, driver_name: [*:0]const u8, tag_list: ?[*]const TagItem) callconv(.c) ?*rtg.RtgBoard {
    return CreateBoardTagList(rb, driver_name, tag_list);
}
fn lvoDeleteBoard(rb: *RtgBase, board: ?*rtg.RtgBoard) callconv(.c) void {
    DeleteBoard(rb, board);
}
fn lvoNextBoard(rb: *RtgBase, after: ?*rtg.RtgBoard) callconv(.c) ?*rtg.RtgBoard {
    return NextBoard(rb, after);
}
fn lvoFindBoard(rb: *RtgBase, board_name: [*:0]const u8) callconv(.c) ?*rtg.RtgBoard {
    return FindBoard(rb, board_name);
}
fn lvoGetBoardInfo(rb: *RtgBase, board: *rtg.RtgBoard, info: *rtg.RtgBoardInfo, size: u32) callconv(.c) u32 {
    return GetBoardInfo(rb, board, info, size);
}
fn lvoGetBoardStats(rb: *RtgBase, board: *rtg.RtgBoard, stats: *rtg.RtgBoardStats, size: u32) callconv(.c) u32 {
    return GetBoardStats(rb, board, stats, size);
}
fn lvoBoardControl(rb: *RtgBase, board: *rtg.RtgBoard, what: u32, value: isize) callconv(.c) isize {
    return BoardControl(rb, board, what, value);
}
fn lvoNextBoardMode(rb: *RtgBase, board: *rtg.RtgBoard, after: ?*rtg.RtgMode) callconv(.c) ?*rtg.RtgMode {
    return NextBoardMode(rb, board, after);
}
fn lvoFindBoardMode(rb: *RtgBase, board: *rtg.RtgBoard, width: u32, height: u32, format: u32) callconv(.c) ?*rtg.RtgMode {
    return FindBoardMode(rb, board, width, height, format);
}
fn lvoSetBoardMode(rb: *RtgBase, board: *rtg.RtgBoard, mode: ?*rtg.RtgMode) callconv(.c) i32 {
    return SetBoardMode(rb, board, mode);
}
fn lvoBoardMode(rb: *RtgBase, board: *rtg.RtgBoard) callconv(.c) ?*rtg.RtgMode {
    return BoardMode(rb, board);
}
fn lvoAllocBitMap(rb: *RtgBase, board: *rtg.RtgBoard, width: u32, height: u32, format: u32, flags: u32) callconv(.c) ?*rtg.RtgBitMap {
    return AllocBitMap(rb, board, width, height, format, flags);
}
fn lvoAttachBitMap(rb: *RtgBase, board: *rtg.RtgBoard, described: *const rtg.RtgBitMap) callconv(.c) ?*rtg.RtgBitMap {
    return AttachBitMap(rb, board, described);
}
fn lvoFreeBitMap(rb: *RtgBase, bitmap: ?*rtg.RtgBitMap) callconv(.c) void {
    FreeBitMap(rb, bitmap);
}
fn lvoShowBitMap(rb: *RtgBase, board: *rtg.RtgBoard, bitmap: ?*rtg.RtgBitMap, x: u32, y: u32) callconv(.c) i32 {
    return ShowBitMap(rb, board, bitmap, x, y);
}
fn lvoBoardDisplayBitMap(rb: *RtgBase, board: *rtg.RtgBoard) callconv(.c) ?*rtg.RtgBitMap {
    return BoardDisplayBitMap(rb, board);
}
fn lvoRefreshBitMap(rb: *RtgBase, bitmap: *rtg.RtgBitMap, y: u32, rows: u32) callconv(.c) i32 {
    return RefreshBitMap(rb, bitmap, y, rows);
}
fn lvoWaitVBlank(rb: *RtgBase, board: *rtg.RtgBoard, frames: u32) callconv(.c) i32 {
    return WaitVBlank(rb, board, frames);
}
fn lvoSetBoardDisplay(rb: *RtgBase, board: *rtg.RtgBoard, on: bool) callconv(.c) i32 {
    return SetBoardDisplay(rb, board, on);
}
fn lvoSetBoardBrightness(rb: *RtgBase, board: *rtg.RtgBoard, percent: u32) callconv(.c) i32 {
    return SetBoardBrightness(rb, board, percent);
}
fn lvoBoardBrightness(rb: *RtgBase, board: *rtg.RtgBoard) callconv(.c) u32 {
    return BoardBrightness(rb, board);
}
fn lvoFillRect(rb: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, color: u32) callconv(.c) i32 {
    return FillRect(rb, dest, area, color);
}
fn lvoInvertRect(rb: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect) callconv(.c) i32 {
    return InvertRect(rb, dest, area);
}
fn lvoCopyRect(rb: *RtgBase, src: *rtg.RtgBitMap, dest: *rtg.RtgBitMap, copy: *const rtg.RtgCopy) callconv(.c) i32 {
    return CopyRect(rb, src, dest, copy);
}
fn lvoBlitTemplate(rb: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, shape: *const rtg.RtgTemplate) callconv(.c) i32 {
    return BlitTemplate(rb, dest, area, shape);
}
fn lvoBlitPattern(rb: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, tile: *const rtg.RtgPattern) callconv(.c) i32 {
    return BlitPattern(rb, dest, area, tile);
}
fn lvoWaitBlit(rb: *RtgBase, board: *rtg.RtgBoard) callconv(.c) void {
    WaitBlit(rb, board);
}
fn lvoPackRtgColor(rb: *RtgBase, format: u32, red: u32, green: u32, blue: u32) callconv(.c) u32 {
    return PackRtgColor(rb, format, red, green, blue);
}
fn lvoUnpackRtgColor(rb: *RtgBase, format: u32, color: u32, out: *rtg.RtgRGB) callconv(.c) void {
    UnpackRtgColor(rb, format, color, out);
}
fn lvoAddRtgEventServer(rb: *RtgBase, board: *rtg.RtgBoard, event: u32, server: *exec.Interrupt) callconv(.c) bool {
    return AddRtgEventServer(rb, board, event, server);
}
fn lvoRemRtgEventServer(rb: *RtgBase, board: *rtg.RtgBoard, event: u32, server: *exec.Interrupt) callconv(.c) void {
    RemRtgEventServer(rb, board, event, server);
}
fn lvoSignalRtgEvent(rb: *RtgBase, board: *rtg.RtgBoard, event: u32) callconv(.c) i32 {
    return SignalRtgEvent(rb, board, event);
}
fn lvoCreateTransportTagList(rb: *RtgBase, driver_name: [*:0]const u8, tag_list: ?[*]const TagItem) callconv(.c) ?*rtg.RtgTransport {
    return CreateTransportTagList(rb, driver_name, tag_list);
}
fn lvoDeleteTransport(rb: *RtgBase, io: ?*rtg.RtgTransport) callconv(.c) void {
    DeleteTransport(rb, io);
}
fn lvoTxParam(rb: *RtgBase, io: *rtg.RtgTransport, cmd: i32, param: ?*const anyopaque, size: u32) callconv(.c) i32 {
    return TxParam(rb, io, cmd, param, size);
}
fn lvoTxColor(rb: *RtgBase, io: *rtg.RtgTransport, cmd: i32, color: ?*const anyopaque, size: u32) callconv(.c) i32 {
    return TxColor(rb, io, cmd, color, size);
}
fn lvoRxParam(rb: *RtgBase, io: *rtg.RtgTransport, cmd: i32, buffer: ?*anyopaque, size: u32) callconv(.c) i32 {
    return RxParam(rb, io, cmd, buffer, size);
}
fn lvoGetRtgTagData(rb: *RtgBase, tag_value: Tag, default_value: usize, tag_list: ?[*]const TagItem) callconv(.c) usize {
    return GetRtgTagData(rb, tag_value, default_value, tag_list);
}
fn lvoFindRtgTagItem(rb: *RtgBase, tag_value: Tag, tag_list: ?[*]const TagItem) callconv(.c) ?*const TagItem {
    return FindRtgTagItem(rb, tag_value, tag_list);
}
fn lvoRtgLastError(rb: *RtgBase) callconv(.c) i32 {
    return RtgLastError(rb);
}
fn lvoRtgErrorText(rb: *RtgBase, error_code: i32) callconv(.c) [*:0]const u8 {
    return RtgErrorText(rb, error_code);
}
fn lvoMirrorBoard(rb: *RtgBase, board: *rtg.RtgBoard, mirror_x: bool, mirror_y: bool) callconv(.c) i32 {
    return MirrorBoard(rb, board, mirror_x, mirror_y);
}
fn lvoSwapBoardAxes(rb: *RtgBase, board: *rtg.RtgBoard, swap: bool) callconv(.c) i32 {
    return SwapBoardAxes(rb, board, swap);
}
fn lvoSetBoardGap(rb: *RtgBase, board: *rtg.RtgBoard, gap_x: u32, gap_y: u32) callconv(.c) i32 {
    return SetBoardGap(rb, board, gap_x, gap_y);
}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(rtg_base.expunge),
    vec(exec.libExtFunc),
    vec(lvoAddRtgDriver),
    vec(lvoRemRtgDriver),
    vec(lvoFindRtgDriver),
    vec(lvoLockRtgDrivers),
    vec(lvoUnlockRtgDrivers),
    vec(lvoNextRtgDriver),
    vec(lvoCreateBoardTagList),
    vec(lvoDeleteBoard),
    vec(lvoNextBoard),
    vec(lvoFindBoard),
    vec(lvoGetBoardInfo),
    vec(lvoGetBoardStats),
    vec(lvoBoardControl),
    vec(lvoNextBoardMode),
    vec(lvoFindBoardMode),
    vec(lvoSetBoardMode),
    vec(lvoBoardMode),
    vec(lvoAllocBitMap),
    vec(lvoAttachBitMap),
    vec(lvoFreeBitMap),
    vec(lvoShowBitMap),
    vec(lvoBoardDisplayBitMap),
    vec(lvoRefreshBitMap),
    vec(lvoWaitVBlank),
    vec(lvoSetBoardDisplay),
    vec(lvoSetBoardBrightness),
    vec(lvoBoardBrightness),
    vec(lvoFillRect),
    vec(lvoInvertRect),
    vec(lvoCopyRect),
    vec(lvoBlitTemplate),
    vec(lvoBlitPattern),
    vec(lvoWaitBlit),
    vec(lvoPackRtgColor),
    vec(lvoUnpackRtgColor),
    vec(lvoAddRtgEventServer),
    vec(lvoRemRtgEventServer),
    vec(lvoSignalRtgEvent),
    vec(lvoCreateTransportTagList),
    vec(lvoDeleteTransport),
    vec(lvoTxParam),
    vec(lvoTxColor),
    vec(lvoRxParam),
    vec(lvoGetRtgTagData),
    vec(lvoFindRtgTagItem),
    vec(lvoRtgLastError),
    vec(lvoRtgErrorText),
    vec(lvoMirrorBoard),
    vec(lvoSwapBoardAxes),
    vec(lvoSetBoardGap),
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "the jump table: the ROM's slots, every LVO at its function" {
    try testing.expectEqual(@as(usize, 54), vectors.len);
    inline for (@typeInfo(LVO).@"struct".decls) |d| {
        const index: usize = @intCast(@divExact(-@field(LVO, d.name), exec.slot_size) - 1);
        try testing.expectEqual(vec(@field(@This(), "lvo" ++ d.name)), vectors[index]);
    }
}

test "every wrapper hands its parameters on, in order, to the call it is named after" {
    try exec.libraries.checkForwarding(@embedFile("rtg_lvo.zig"), LVO, &.{});
}
