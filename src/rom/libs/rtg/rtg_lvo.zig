// SPDX-License-Identifier: MPL-2.0
//! rtg.library's jump table: every `lvo<Name>` wrapper, the table of them
//! in slot order, and the checks that hold the table to the SDK's contract
//! - at compile time the signatures, and a contract for every call that
//! documents the LVO the call has; the slots and the forwarding in the
//! tests at the end.
//!
//! The one table is two interfaces: the calls for programs
//! (sdk/fd/rtg_lib.fd), then those for drivers (sdk/fd/rtgdriver_lib.fd),
//! whose first slot is the one after the programs' last. Both lists are
//! held to the table by the same checks, so a `##bias` that is off stops
//! the build.
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
const GetRtgDrivers = @import("driver/getrtgdrivers.zig").GetRtgDrivers;
const BindRtgDrivers = @import("device/bindrtgdrivers.zig").BindRtgDrivers;
const GetRtgDevices = @import("device/getrtgdevices.zig").GetRtgDevices;
const AddRtgDevice = @import("device/addrtgdevice.zig").AddRtgDevice;
const RemRtgDevice = @import("device/remrtgdevice.zig").RemRtgDevice;
const CreateBoard = @import("board/createboard.zig").CreateBoard;
const DeleteBoard = @import("board/deleteboard.zig").DeleteBoard;
const NextBoard = @import("board/nextboard.zig").NextBoard;
const FindBoard = @import("board/findboard.zig").FindBoard;
const GetBoardInfo = @import("board/getboardinfo.zig").GetBoardInfo;
const GetBoardStats = @import("board/getboardstats.zig").GetBoardStats;
const BoardControl = @import("board/boardcontrol.zig").BoardControl;
const FindBoardMode = @import("mode/findboardmode.zig").FindBoardMode;
const GetBoardModes = @import("mode/getboardmodes.zig").GetBoardModes;
const BestBoardMode = @import("mode/bestboardmode.zig").BestBoardMode;
const AddBoardMode = @import("mode/addboardmode.zig").AddBoardMode;
const ReadTimingTags = @import("mode/readtimingtags.zig").ReadTimingTags;
const MonitorChanged = @import("monitor/monitorchanged.zig").MonitorChanged;
const FindStandardTimings = @import("monitor/findstandardtimings.zig").FindStandardTimings;
const GetBoardMonitor = @import("monitor/getboardmonitor.zig").GetBoardMonitor;
const ReadBoardEDID = @import("monitor/readboardedid.zig").ReadBoardEDID;
const AddRtgNotify = @import("board/addrtgnotify.zig").AddRtgNotify;
const RemRtgNotify = @import("board/remrtgnotify.zig").RemRtgNotify;
const AllocBitMap = @import("bitmap/allocbitmap.zig").AllocBitMap;
const AttachBitMap = @import("bitmap/attachbitmap.zig").AttachBitMap;
const FreeBitMap = @import("bitmap/freebitmap.zig").FreeBitMap;
const ShowBitMap = @import("display/showbitmap.zig").ShowBitMap;
const ShowBoard = @import("display/showboard.zig").ShowBoard;
const SetBoardOverlay = @import("pointer/setboardoverlay.zig").SetBoardOverlay;
const MoveBoardOverlay = @import("pointer/moveboardoverlay.zig").MoveBoardOverlay;
const BoardDisplayBitMap = @import("display/boarddisplaybitmap.zig").BoardDisplayBitMap;
const RefreshBitMap = @import("bitmap/refreshbitmap.zig").RefreshBitMap;
const RefreshRect = @import("bitmap/refreshrect.zig").RefreshRect;
const WaitVBlank = @import("display/waitvblank.zig").WaitVBlank;
const SetBoardDisplay = @import("display/setboarddisplay.zig").SetBoardDisplay;
const SetBoardBrightness = @import("display/setboardbrightness.zig").SetBoardBrightness;
const BoardBrightness = @import("display/boardbrightness.zig").BoardBrightness;
const FillRect = @import("engine/fillrect.zig").FillRect;
const CopyRect = @import("engine/copyrect.zig").CopyRect;
const CopyRects = @import("engine/copyrects.zig").CopyRects;
const OpenVideoLayer = @import("video/openvideolayer.zig").OpenVideoLayer;
const CloseVideoLayer = @import("video/closevideolayer.zig").CloseVideoLayer;
const ShowVideoFrame = @import("video/showvideoframe.zig").ShowVideoFrame;
const MoveVideoLayer = @import("video/movevideolayer.zig").MoveVideoLayer;
const RtgFormatBits = @import("bitmap/rtgformatbits.zig").RtgFormatBits;
const RtgRowBytes = @import("bitmap/rtgrowbytes.zig").RtgRowBytes;
const RtgCicp = @import("video/rtgcicp.zig").RtgCicp;
const BlitTemplate = @import("engine/blittemplate.zig").BlitTemplate;
const BlitPattern = @import("engine/blitpattern.zig").BlitPattern;
const BlendPixels = @import("engine/blendpixels.zig").BlendPixels;
const BlendRect = @import("engine/blendrect.zig").BlendRect;
const ScalePixels = @import("engine/scalepixels.zig").ScalePixels;
const AddRtgEventServer = @import("event/addrtgeventserver.zig").AddRtgEventServer;
const RemRtgEventServer = @import("event/remrtgeventserver.zig").RemRtgEventServer;
const SignalRtgEvent = @import("event/signalrtgevent.zig").SignalRtgEvent;
const OpenTransport = @import("transport/opentransport.zig").OpenTransport;
const CloseTransport = @import("transport/closetransport.zig").CloseTransport;
const TxParam = @import("transport/txparam.zig").TxParam;
const TxColor = @import("transport/txcolor.zig").TxColor;
const RxParam = @import("transport/rxparam.zig").RxParam;
const GetRtgTagData = @import("tag/getrtgtagdata.zig").GetRtgTagData;
const RtgErrorText = @import("errors/rtgerrortext.zig").RtgErrorText;
const MirrorBoard = @import("display/mirrorboard.zig").MirrorBoard;
const SetBoardPointer = @import("pointer/setboardpointer.zig").SetBoardPointer;
const MoveBoardPointer = @import("pointer/moveboardpointer.zig").MoveBoardPointer;
const ShowBoardPointer = @import("pointer/showboardpointer.zig").ShowBoardPointer;

/// rtg.library's two interfaces, as the SDK generates them: the programs'
/// from sdk/fd/rtg_lib.fd, the drivers' from sdk/fd/rtgdriver_lib.fd.
const interface = sdk.interface.rtg;
const LVO = interface.LVO;
const driver_interface = sdk.interface.rtgdriver;
const DRIVER_LVO = driver_interface.LVO;

/// The two, for the checks that go over both: what each is called in a
/// message, its LVO struct and its function types.
const interfaces = .{
    .{ .who = "rtg.library", .lvo = LVO, .functions = interface.Fn },
    .{ .who = "rtg.library, for drivers", .lvo = DRIVER_LVO, .functions = driver_interface.Fn },
};

// Every function of either LVO is an lvo* function here, with the SDK's
// signature (after the base), in its slot of the one table.
comptime {
    for (interfaces) |one| {
        for (@typeInfo(one.lvo).@"struct".decls) |d| {
            const f = @field(@This(), "lvo" ++ d.name);
            if (!exec.libraries.sameSignature(@TypeOf(&f), @field(one.functions, d.name))) {
                @compileError(one.who ++ ": lvo" ++ d.name ++ " doesn't match the SDK's Fn." ++ d.name);
            }
            const slot = @divExact(-@field(one.lvo, d.name), exec.slot_size) - 1;
            if (slot >= vectors.len) {
                @compileError(one.who ++ ": LVO." ++ d.name ++ " is past the table's end: the .fd's ##bias is off");
            }
            if (vectors[slot] != vec(f)) {
                @compileError(one.who ++ ": lvo" ++ d.name ++ " isn't in the slot of LVO." ++ d.name);
            }
        }
    }
}

// Every call's contract is in the list, once, and documents the LVO its
// .fd gives it. A file holds a call of one interface, and is passed over
// by the other's check.
comptime {
    @setEvalBranchQuota(50_000_000);
    for (interfaces) |one| exec.libraries.checkContractFiles(&contract_files, one.lvo, one.who, "pub fn ");
}

/// The files whose call carries its contract, above `pub fn <Name>`: every
/// call of the table, of either interface, once. A call added gets its
/// file here, or the build stops and names it.
const contract_files = [_][]const u8{
    @embedFile("driver/addrtgdriver.zig"),
    @embedFile("driver/remrtgdriver.zig"),
    @embedFile("driver/getrtgdrivers.zig"),
    @embedFile("device/bindrtgdrivers.zig"),
    @embedFile("device/getrtgdevices.zig"),
    @embedFile("device/addrtgdevice.zig"),
    @embedFile("device/remrtgdevice.zig"),
    @embedFile("board/createboard.zig"),
    @embedFile("board/deleteboard.zig"),
    @embedFile("board/nextboard.zig"),
    @embedFile("board/findboard.zig"),
    @embedFile("board/getboardinfo.zig"),
    @embedFile("board/getboardstats.zig"),
    @embedFile("board/boardcontrol.zig"),
    @embedFile("mode/findboardmode.zig"),
    @embedFile("mode/getboardmodes.zig"),
    @embedFile("mode/bestboardmode.zig"),
    @embedFile("mode/addboardmode.zig"),
    @embedFile("mode/readtimingtags.zig"),
    @embedFile("monitor/monitorchanged.zig"),
    @embedFile("monitor/findstandardtimings.zig"),
    @embedFile("monitor/getboardmonitor.zig"),
    @embedFile("monitor/readboardedid.zig"),
    @embedFile("board/addrtgnotify.zig"),
    @embedFile("board/remrtgnotify.zig"),
    @embedFile("bitmap/allocbitmap.zig"),
    @embedFile("bitmap/attachbitmap.zig"),
    @embedFile("bitmap/freebitmap.zig"),
    @embedFile("display/showbitmap.zig"),
    @embedFile("display/showboard.zig"),
    @embedFile("pointer/setboardoverlay.zig"),
    @embedFile("pointer/moveboardoverlay.zig"),
    @embedFile("display/boarddisplaybitmap.zig"),
    @embedFile("bitmap/refreshbitmap.zig"),
    @embedFile("display/waitvblank.zig"),
    @embedFile("display/setboarddisplay.zig"),
    @embedFile("display/setboardbrightness.zig"),
    @embedFile("display/boardbrightness.zig"),
    @embedFile("engine/fillrect.zig"),
    @embedFile("engine/copyrect.zig"),
    @embedFile("engine/blittemplate.zig"),
    @embedFile("engine/blitpattern.zig"),
    @embedFile("engine/blendpixels.zig"),
    @embedFile("engine/blendrect.zig"),
    @embedFile("engine/scalepixels.zig"),
    @embedFile("event/addrtgeventserver.zig"),
    @embedFile("event/remrtgeventserver.zig"),
    @embedFile("event/signalrtgevent.zig"),
    @embedFile("transport/opentransport.zig"),
    @embedFile("transport/closetransport.zig"),
    @embedFile("transport/txparam.zig"),
    @embedFile("transport/txcolor.zig"),
    @embedFile("transport/rxparam.zig"),
    @embedFile("tag/getrtgtagdata.zig"),
    @embedFile("errors/rtgerrortext.zig"),
    @embedFile("display/mirrorboard.zig"),
    @embedFile("pointer/setboardpointer.zig"),
    @embedFile("pointer/moveboardpointer.zig"),
    @embedFile("pointer/showboardpointer.zig"),
    @embedFile("bitmap/refreshrect.zig"),
    @embedFile("engine/copyrects.zig"),
    @embedFile("video/openvideolayer.zig"),
    @embedFile("video/closevideolayer.zig"),
    @embedFile("video/showvideoframe.zig"),
    @embedFile("video/movevideolayer.zig"),
    @embedFile("bitmap/rtgformatbits.zig"),
    @embedFile("bitmap/rtgrowbytes.zig"),
    @embedFile("video/rtgcicp.zig"),
};

fn lvoAddRtgDriver(rb: *RtgBase, spec: *const rtg.RtgDriverSpec, seg_list: ?*anyopaque) callconv(.c) ?*rtg.RtgDriver {
    return AddRtgDriver(rb, spec, seg_list);
}
fn lvoRemRtgDriver(rb: *RtgBase, driver: *rtg.RtgDriver) callconv(.c) bool {
    return RemRtgDriver(rb, driver);
}
fn lvoBindRtgDrivers(rb: *RtgBase) callconv(.c) u32 {
    return BindRtgDrivers(rb);
}
fn lvoGetRtgDrivers(rb: *RtgBase, into: ?[*]rtg.RtgDriverInfo, count: u32) callconv(.c) u32 {
    return GetRtgDrivers(rb, into, count);
}
fn lvoGetRtgDevices(rb: *RtgBase, into: ?[*]rtg.RtgDeviceInfo, count: u32) callconv(.c) u32 {
    return GetRtgDevices(rb, into, count);
}
fn lvoCreateBoard(rb: *RtgBase, driver: *rtg.RtgDriver, device: *rtg.RtgDevice, spec: *const rtg.RtgBoardSpec) callconv(.c) ?*rtg.RtgBoard {
    return CreateBoard(rb, driver, device, spec);
}
fn lvoAddRtgDevice(rb: *RtgBase, tag_list: ?[*]const TagItem) callconv(.c) ?*rtg.RtgDevice {
    return AddRtgDevice(rb, tag_list);
}
fn lvoRemRtgDevice(rb: *RtgBase, device: ?*rtg.RtgDevice) callconv(.c) void {
    RemRtgDevice(rb, device);
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
fn lvoFindBoardMode(rb: *RtgBase, board: *rtg.RtgBoard, width: u32, height: u32, refresh_mhz: u32, format: u32) callconv(.c) u32 {
    return FindBoardMode(rb, board, width, height, refresh_mhz, format);
}
fn lvoGetBoardModes(rb: *RtgBase, board: *rtg.RtgBoard, into: ?[*]rtg.RtgMode, count: u32) callconv(.c) u32 {
    return GetBoardModes(rb, board, into, count);
}
fn lvoBestBoardMode(rb: *RtgBase, board: *rtg.RtgBoard, width: u32, height: u32, refresh_mhz: u32, format: u32, mode: ?*rtg.RtgMode) callconv(.c) u32 {
    return BestBoardMode(rb, board, width, height, refresh_mhz, format, mode);
}
fn lvoAddBoardMode(rb: *RtgBase, board: *rtg.RtgBoard, timings: *const rtg.RtgTimings, format: u32, flags: u32) callconv(.c) u32 {
    return AddBoardMode(rb, board, timings, format, flags);
}
fn lvoReadTimingTags(rb: *RtgBase, tag_list: ?[*]const TagItem, timings: *rtg.RtgTimings) callconv(.c) bool {
    return ReadTimingTags(rb, tag_list, timings);
}
fn lvoMonitorChanged(rb: *RtgBase, board: *rtg.RtgBoard) callconv(.c) void {
    MonitorChanged(rb, board);
}
fn lvoFindStandardTimings(rb: *RtgBase, width: u32, height: u32, refresh_hz: u32, timings: *rtg.RtgTimings) callconv(.c) bool {
    return FindStandardTimings(rb, width, height, refresh_hz, timings);
}
fn lvoGetBoardMonitor(rb: *RtgBase, board: *rtg.RtgBoard, info: *rtg.RtgMonitorInfo, size: u32) callconv(.c) u32 {
    return GetBoardMonitor(rb, board, info, size);
}
fn lvoReadBoardEDID(rb: *RtgBase, board: *rtg.RtgBoard, buffer: ?[*]u8, size: u32) callconv(.c) u32 {
    return ReadBoardEDID(rb, board, buffer, size);
}
fn lvoAddRtgNotify(rb: *RtgBase, task: *exec.Task, signals: u32) callconv(.c) ?*rtg.RtgNotify {
    return AddRtgNotify(rb, task, signals);
}
fn lvoRemRtgNotify(rb: *RtgBase, notify: ?*rtg.RtgNotify) callconv(.c) void {
    RemRtgNotify(rb, notify);
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
fn lvoShowBitMap(rb: *RtgBase, board: *rtg.RtgBoard, bitmap: ?*rtg.RtgBitMap) callconv(.c) i32 {
    return ShowBitMap(rb, board, bitmap);
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
fn lvoCopyRect(rb: *RtgBase, src: *rtg.RtgBitMap, dest: *rtg.RtgBitMap, copy: *const rtg.RtgCopy) callconv(.c) i32 {
    return CopyRect(rb, src, dest, copy);
}
fn lvoBlitTemplate(rb: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, shape: *const rtg.RtgTemplate) callconv(.c) i32 {
    return BlitTemplate(rb, dest, area, shape);
}
fn lvoBlitPattern(rb: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, tile: *const rtg.RtgPattern) callconv(.c) i32 {
    return BlitPattern(rb, dest, area, tile);
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
fn lvoOpenTransport(rb: *RtgBase, driver: *rtg.RtgDriver, device: *rtg.RtgDevice) callconv(.c) ?*rtg.RtgTransport {
    return OpenTransport(rb, driver, device);
}
fn lvoCloseTransport(rb: *RtgBase, io: ?*rtg.RtgTransport) callconv(.c) void {
    CloseTransport(rb, io);
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
fn lvoRtgErrorText(rb: *RtgBase, error_code: i32) callconv(.c) [*:0]const u8 {
    return RtgErrorText(rb, error_code);
}
fn lvoMirrorBoard(rb: *RtgBase, board: *rtg.RtgBoard, mirror_x: bool, mirror_y: bool) callconv(.c) i32 {
    return MirrorBoard(rb, board, mirror_x, mirror_y);
}
fn lvoSetBoardPointer(rb: *RtgBase, board: *rtg.RtgBoard, image: ?*const rtg.Surface, hot_x: u32, hot_y: u32) callconv(.c) i32 {
    return SetBoardPointer(rb, board, image, hot_x, hot_y);
}
fn lvoMoveBoardPointer(rb: *RtgBase, board: *rtg.RtgBoard, x: i32, y: i32) callconv(.c) void {
    MoveBoardPointer(rb, board, x, y);
}
fn lvoShowBoardPointer(rb: *RtgBase, board: *rtg.RtgBoard, show: bool) callconv(.c) i32 {
    return ShowBoardPointer(rb, board, show);
}
fn lvoShowBoard(rb: *RtgBase, board: *rtg.RtgBoard, mode_id: u32, bands: ?[*]const rtg.RtgBand, count: u32) callconv(.c) i32 {
    return ShowBoard(rb, board, mode_id, bands, count);
}
fn lvoSetBoardOverlay(rb: *RtgBase, board: *rtg.RtgBoard, image: ?*const rtg.Surface, hot_x: u32, hot_y: u32) callconv(.c) i32 {
    return SetBoardOverlay(rb, board, image, hot_x, hot_y);
}
fn lvoMoveBoardOverlay(rb: *RtgBase, board: *rtg.RtgBoard, x: i32, y: i32) callconv(.c) void {
    return MoveBoardOverlay(rb, board, x, y);
}
fn lvoBlendPixels(rb: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, pixels: *const rtg.RtgPixels, alpha: u32) callconv(.c) i32 {
    return BlendPixels(rb, dest, area, pixels, alpha);
}
fn lvoBlendRect(rb: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, color: u32) callconv(.c) i32 {
    return BlendRect(rb, dest, area, color);
}
fn lvoScalePixels(rb: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, pixels: *const rtg.RtgPixels, width: u32, height: u32) callconv(.c) i32 {
    return ScalePixels(rb, dest, area, pixels, width, height);
}
fn lvoRefreshRect(rb: *RtgBase, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect) callconv(.c) i32 {
    return RefreshRect(rb, bitmap, area);
}
fn lvoCopyRects(rb: *RtgBase, src: *rtg.RtgBitMap, dest: *rtg.RtgBitMap, copies: [*]const rtg.RtgCopy, count: u32) callconv(.c) i32 {
    return CopyRects(rb, src, dest, copies, count);
}

fn lvoOpenVideoLayer(rb: *RtgBase, board: *rtg.RtgBoard, tag_list: ?[*]const TagItem) callconv(.c) ?*rtg.RtgVideoLayer {
    return OpenVideoLayer(rb, board, tag_list);
}

fn lvoCloseVideoLayer(rb: *RtgBase, layer: ?*rtg.RtgVideoLayer) callconv(.c) void {
    CloseVideoLayer(rb, layer);
}

fn lvoShowVideoFrame(rb: *RtgBase, layer: *rtg.RtgVideoLayer, picture: ?*const rtg.RtgYuv, src: ?*const rtg.RtgRect) callconv(.c) i32 {
    return ShowVideoFrame(rb, layer, picture, src);
}

fn lvoMoveVideoLayer(rb: *RtgBase, layer: *rtg.RtgVideoLayer, place: *const rtg.RtgRect) callconv(.c) i32 {
    return MoveVideoLayer(rb, layer, place);
}

fn lvoRtgFormatBits(rb: *RtgBase, format: u32) callconv(.c) u32 {
    return RtgFormatBits(rb, format);
}
fn lvoRtgRowBytes(rb: *RtgBase, format: u32, width: u32) callconv(.c) u32 {
    return RtgRowBytes(rb, format, width);
}
fn lvoRtgCicp(rb: *RtgBase, kind: u32, value: u32) callconv(.c) i32 {
    return RtgCicp(rb, kind, value);
}

/// How many slots of the table are kept free.
const reserved_slots = 27;

/// The slots kept free (`##reserve` in the `.fd`), so the slots after them
/// stay where they are: each does nothing.
///
/// INPUTS:
/// - `_` - the library's base, unused.
fn reserved(_: *RtgBase) callconv(.c) void {}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line and a `reserved` per slot kept free - the
/// programs' calls first, the drivers' after them.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(rtg_base.expunge),
    vec(exec.libExtFunc),
    vec(reserved),
    vec(reserved),
    vec(reserved),
    vec(reserved),
    vec(reserved),
    vec(reserved),
    vec(reserved),
    vec(reserved),
    vec(lvoNextBoard),
    vec(lvoFindBoard),
    vec(lvoGetBoardInfo),
    vec(lvoGetBoardStats),
    vec(lvoBoardControl),
    vec(reserved),
    vec(lvoFindBoardMode),
    vec(reserved),
    vec(reserved),
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
    vec(reserved),
    vec(lvoCopyRect),
    vec(lvoBlitTemplate),
    vec(lvoBlitPattern),
    vec(reserved),
    vec(reserved),
    vec(reserved),
    vec(lvoAddRtgEventServer),
    vec(lvoRemRtgEventServer),
    vec(reserved),
    vec(reserved),
    vec(reserved),
    vec(reserved),
    vec(reserved),
    vec(reserved),
    vec(reserved),
    vec(reserved),
    vec(reserved),
    vec(lvoRtgErrorText),
    vec(lvoMirrorBoard),
    vec(reserved),
    vec(reserved),
    vec(lvoSetBoardPointer),
    vec(lvoMoveBoardPointer),
    vec(lvoShowBoardPointer),
    vec(reserved),
    vec(lvoSetBoardOverlay),
    vec(lvoMoveBoardOverlay),
    vec(lvoBlendPixels),
    vec(lvoBlendRect),
    vec(lvoScalePixels),
    vec(lvoRefreshRect),
    vec(lvoCopyRects),
    vec(lvoOpenVideoLayer),
    vec(lvoCloseVideoLayer),
    vec(lvoShowVideoFrame),
    vec(lvoMoveVideoLayer),
    vec(lvoRtgFormatBits),
    vec(lvoRtgRowBytes),
    vec(lvoRtgCicp),
    vec(lvoBindRtgDrivers),
    vec(lvoGetRtgDrivers),
    vec(lvoGetRtgDevices),
    vec(lvoGetBoardModes),
    vec(lvoBestBoardMode),
    vec(lvoGetBoardMonitor),
    vec(lvoReadBoardEDID),
    vec(lvoAddRtgNotify),
    vec(lvoRemRtgNotify),
    vec(lvoShowBoard),
    // The drivers' interface.
    vec(lvoAddRtgDriver),
    vec(lvoRemRtgDriver),
    vec(lvoSignalRtgEvent),
    vec(lvoTxParam),
    vec(lvoTxColor),
    vec(lvoRxParam),
    vec(lvoGetRtgTagData),
    vec(lvoCreateBoard),
    vec(lvoDeleteBoard),
    vec(lvoAddRtgDevice),
    vec(lvoRemRtgDevice),
    vec(lvoOpenTransport),
    vec(lvoCloseTransport),
    vec(lvoAddBoardMode),
    vec(lvoReadTimingTags),
    vec(lvoMonitorChanged),
    vec(lvoFindStandardTimings),
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

/// How many calls the two interfaces have together.
const call_count = @typeInfo(LVO).@"struct".decls.len + @typeInfo(DRIVER_LVO).@"struct".decls.len;

test "the jump table: the ROM's slots, every LVO of both interfaces at its function" {
    // The reserved slots are in the table but not in either LVO.
    try testing.expectEqual(exec.libraries.standard_vectors + call_count + reserved_slots, vectors.len);
    try testing.expectEqual(@as(usize, 99), vectors.len);
    inline for (interfaces) |one| {
        inline for (@typeInfo(one.lvo).@"struct".decls) |d| {
            const index: usize = @intCast(@divExact(-@field(one.lvo, d.name), exec.slot_size) - 1);
            try testing.expectEqual(vec(@field(@This(), "lvo" ++ d.name)), vectors[index]);
        }
    }
}

test "the drivers' calls follow the programs': no slot of one lies among the other's" {
    var last_of_programs: usize = 0;
    inline for (@typeInfo(LVO).@"struct".decls) |d| {
        last_of_programs = @max(last_of_programs, @as(usize, @intCast(@divExact(-@field(LVO, d.name), exec.slot_size) - 1)));
    }
    var first_of_drivers: usize = vectors.len;
    inline for (@typeInfo(DRIVER_LVO).@"struct".decls) |d| {
        first_of_drivers = @min(first_of_drivers, @as(usize, @intCast(@divExact(-@field(DRIVER_LVO, d.name), exec.slot_size) - 1)));
    }
    try testing.expectEqual(last_of_programs + 1, first_of_drivers);
}

test "every wrapper hands its parameters on, in order, to the call it is named after" {
    try exec.libraries.checkForwardingOf(@embedFile("rtg_lvo.zig"), call_count, &.{});
}
