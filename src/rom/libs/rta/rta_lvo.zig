// SPDX-License-Identifier: MPL-2.0
//! rta.library's jump table: every `lvo<Name>` wrapper, the table of them
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
const rta = sdk.rta;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const vec = exec.vec;
const rta_base = @import("rta_base.zig");
const RtaBase = rta_base.RtaBase;

const AddRtaDriver = @import("driver/addrtadriver.zig").AddRtaDriver;
const RemRtaDriver = @import("driver/remrtadriver.zig").RemRtaDriver;
const FindRtaDriver = @import("driver/findrtadriver.zig").FindRtaDriver;
const LockRtaDrivers = @import("driver/lockrtadrivers.zig").LockRtaDrivers;
const UnlockRtaDrivers = @import("driver/unlockrtadrivers.zig").UnlockRtaDrivers;
const NextRtaDriver = @import("driver/nextrtadriver.zig").NextRtaDriver;
const CreateSinkTagList = @import("sink/createsinktaglist.zig").CreateSinkTagList;
const DeleteSink = @import("sink/deletesink.zig").DeleteSink;
const NextSink = @import("sink/nextsink.zig").NextSink;
const FindSink = @import("sink/findsink.zig").FindSink;
const SinkMode = @import("sink/sinkmode.zig").SinkMode;
const StartSink = @import("sink/startsink.zig").StartSink;
const StopSink = @import("sink/stopsink.zig").StopSink;
const SinkBuffer = @import("sink/sinkbuffer.zig").SinkBuffer;
const PlaySinkBuffer = @import("sink/playsinkbuffer.zig").PlaySinkBuffer;
const SinkControl = @import("sink/sinkcontrol.zig").SinkControl;
const CreateAudioTransportTagList = @import("transport/createaudiotransporttaglist.zig").CreateAudioTransportTagList;
const DeleteAudioTransport = @import("transport/deleteaudiotransport.zig").DeleteAudioTransport;
const StartAudioTransport = @import("transport/startaudiotransport.zig").StartAudioTransport;
const StopAudioTransport = @import("transport/stopaudiotransport.zig").StopAudioTransport;
const AudioTransportBuffer = @import("transport/audiotransportbuffer.zig").AudioTransportBuffer;
const PlayAudioTransportBuffer = @import("transport/playaudiotransportbuffer.zig").PlayAudioTransportBuffer;
const RtaLastError = @import("errors/rtalasterror.zig").RtaLastError;
const RtaErrorText = @import("errors/rtaerrortext.zig").RtaErrorText;
const NextSinkMode = @import("sink/nextsinkmode.zig").NextSinkMode;
const FindSinkMode = @import("sink/findsinkmode.zig").FindSinkMode;
const SetSinkMode = @import("sink/setsinkmode.zig").SetSinkMode;
const CreateSourceTagList = @import("source/createsourcetaglist.zig").CreateSourceTagList;
const DeleteSource = @import("source/deletesource.zig").DeleteSource;
const NextSource = @import("source/nextsource.zig").NextSource;
const NextSourceMode = @import("source/nextsourcemode.zig").NextSourceMode;
const StartSource = @import("source/startsource.zig").StartSource;
const StopSource = @import("source/stopsource.zig").StopSource;
const SourceBuffer = @import("source/sourcebuffer.zig").SourceBuffer;
const StartAudioTransportInput = @import("transport/startaudiotransportinput.zig").StartAudioTransportInput;
const StopAudioTransportInput = @import("transport/stopaudiotransportinput.zig").StopAudioTransportInput;
const AudioTransportInput = @import("transport/audiotransportinput.zig").AudioTransportInput;

/// rta.library's interface, as the SDK generates it from sdk/fd/rta_lib.fd.
const interface = sdk.interface.rta;
const LVO = interface.LVO;

// Every function in LVO is an lvo* function here, with the SDK's signature
// (after the base), in its slot.
comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("rta.library's lvo" ++ d.name ++ " doesn't match the SDK's Fn." ++ d.name);
        }
        if (vectors[@divExact(-@field(LVO, d.name), exec.slot_size) - 1] != vec(f)) {
            @compileError("rta.library's lvo" ++ d.name ++ " isn't in the slot of LVO." ++ d.name);
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "rta.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`: every
/// call of the table.
const contract_files = [_][]const u8{
    @embedFile("driver/addrtadriver.zig"),
    @embedFile("driver/remrtadriver.zig"),
    @embedFile("driver/findrtadriver.zig"),
    @embedFile("driver/lockrtadrivers.zig"),
    @embedFile("driver/unlockrtadrivers.zig"),
    @embedFile("driver/nextrtadriver.zig"),
    @embedFile("sink/createsinktaglist.zig"),
    @embedFile("sink/deletesink.zig"),
    @embedFile("sink/nextsink.zig"),
    @embedFile("sink/findsink.zig"),
    @embedFile("sink/sinkmode.zig"),
    @embedFile("sink/startsink.zig"),
    @embedFile("sink/stopsink.zig"),
    @embedFile("sink/sinkbuffer.zig"),
    @embedFile("sink/playsinkbuffer.zig"),
    @embedFile("sink/sinkcontrol.zig"),
    @embedFile("transport/createaudiotransporttaglist.zig"),
    @embedFile("transport/deleteaudiotransport.zig"),
    @embedFile("transport/startaudiotransport.zig"),
    @embedFile("transport/stopaudiotransport.zig"),
    @embedFile("transport/audiotransportbuffer.zig"),
    @embedFile("transport/playaudiotransportbuffer.zig"),
    @embedFile("errors/rtalasterror.zig"),
    @embedFile("errors/rtaerrortext.zig"),
    @embedFile("sink/nextsinkmode.zig"),
    @embedFile("sink/findsinkmode.zig"),
    @embedFile("sink/setsinkmode.zig"),
    @embedFile("source/createsourcetaglist.zig"),
    @embedFile("source/deletesource.zig"),
    @embedFile("source/nextsource.zig"),
    @embedFile("source/nextsourcemode.zig"),
    @embedFile("source/startsource.zig"),
    @embedFile("source/stopsource.zig"),
    @embedFile("source/sourcebuffer.zig"),
    @embedFile("transport/startaudiotransportinput.zig"),
    @embedFile("transport/stopaudiotransportinput.zig"),
    @embedFile("transport/audiotransportinput.zig"),
};

fn lvoAddRtaDriver(rb: *RtaBase, driver: *rta.RtaDriver) callconv(.c) bool {
    return AddRtaDriver(rb, driver);
}
fn lvoRemRtaDriver(rb: *RtaBase, driver: *rta.RtaDriver) callconv(.c) bool {
    return RemRtaDriver(rb, driver);
}
fn lvoFindRtaDriver(rb: *RtaBase, driver_name: [*:0]const u8) callconv(.c) ?*rta.RtaDriver {
    return FindRtaDriver(rb, driver_name);
}
fn lvoLockRtaDrivers(rb: *RtaBase) callconv(.c) void {
    LockRtaDrivers(rb);
}
fn lvoUnlockRtaDrivers(rb: *RtaBase) callconv(.c) void {
    UnlockRtaDrivers(rb);
}
fn lvoNextRtaDriver(rb: *RtaBase, after: ?*rta.RtaDriver) callconv(.c) ?*rta.RtaDriver {
    return NextRtaDriver(rb, after);
}
fn lvoCreateSinkTagList(rb: *RtaBase, driver_name: [*:0]const u8, tag_list: ?[*]const TagItem) callconv(.c) ?*rta.AudioSink {
    return CreateSinkTagList(rb, driver_name, tag_list);
}
fn lvoDeleteSink(rb: *RtaBase, sink: ?*rta.AudioSink) callconv(.c) void {
    DeleteSink(rb, sink);
}
fn lvoNextSink(rb: *RtaBase, after: ?*rta.AudioSink) callconv(.c) ?*rta.AudioSink {
    return NextSink(rb, after);
}
fn lvoFindSink(rb: *RtaBase, sink_name: [*:0]const u8) callconv(.c) ?*rta.AudioSink {
    return FindSink(rb, sink_name);
}
fn lvoSinkMode(rb: *RtaBase, sink: *rta.AudioSink) callconv(.c) ?*rta.AudioMode {
    return SinkMode(rb, sink);
}
fn lvoStartSink(rb: *RtaBase, sink: *rta.AudioSink, task: *exec.Task, signal_mask: u32) callconv(.c) i32 {
    return StartSink(rb, sink, task, signal_mask);
}
fn lvoStopSink(rb: *RtaBase, sink: *rta.AudioSink) callconv(.c) void {
    StopSink(rb, sink);
}
fn lvoSinkBuffer(rb: *RtaBase, sink: *rta.AudioSink) callconv(.c) ?[*]i16 {
    return SinkBuffer(rb, sink);
}
fn lvoPlaySinkBuffer(rb: *RtaBase, sink: *rta.AudioSink, buffer: [*]i16) callconv(.c) i32 {
    return PlaySinkBuffer(rb, sink, buffer);
}
fn lvoSinkControl(rb: *RtaBase, sink: *rta.AudioSink, what: u32, value: isize) callconv(.c) isize {
    return SinkControl(rb, sink, what, value);
}
fn lvoCreateAudioTransportTagList(rb: *RtaBase, driver_name: [*:0]const u8, tag_list: ?[*]const TagItem) callconv(.c) ?*rta.AudioTransport {
    return CreateAudioTransportTagList(rb, driver_name, tag_list);
}
fn lvoDeleteAudioTransport(rb: *RtaBase, io: ?*rta.AudioTransport) callconv(.c) void {
    DeleteAudioTransport(rb, io);
}
fn lvoStartAudioTransport(rb: *RtaBase, io: *rta.AudioTransport, mode: *const rta.AudioMode, task: *exec.Task, signal_mask: u32) callconv(.c) i32 {
    return StartAudioTransport(rb, io, mode, task, signal_mask);
}
fn lvoStopAudioTransport(rb: *RtaBase, io: *rta.AudioTransport) callconv(.c) void {
    StopAudioTransport(rb, io);
}
fn lvoAudioTransportBuffer(rb: *RtaBase, io: *rta.AudioTransport) callconv(.c) ?[*]i16 {
    return AudioTransportBuffer(rb, io);
}
fn lvoPlayAudioTransportBuffer(rb: *RtaBase, io: *rta.AudioTransport, buffer: [*]i16) callconv(.c) i32 {
    return PlayAudioTransportBuffer(rb, io, buffer);
}
fn lvoRtaLastError(rb: *RtaBase) callconv(.c) i32 {
    return RtaLastError(rb);
}
fn lvoRtaErrorText(rb: *RtaBase, error_code: i32) callconv(.c) [*:0]const u8 {
    return RtaErrorText(rb, error_code);
}
fn lvoNextSinkMode(rb: *RtaBase, sink: *rta.AudioSink, after: ?*rta.AudioMode) callconv(.c) ?*rta.AudioMode {
    return NextSinkMode(rb, sink, after);
}
fn lvoFindSinkMode(rb: *RtaBase, sink: *rta.AudioSink, rate: u32, channels: u32) callconv(.c) ?*rta.AudioMode {
    return FindSinkMode(rb, sink, rate, channels);
}
fn lvoSetSinkMode(rb: *RtaBase, sink: *rta.AudioSink, mode: ?*rta.AudioMode) callconv(.c) i32 {
    return SetSinkMode(rb, sink, mode);
}
fn lvoCreateSourceTagList(rb: *RtaBase, driver_name: [*:0]const u8, tag_list: ?[*]const TagItem) callconv(.c) ?*rta.AudioSource {
    return CreateSourceTagList(rb, driver_name, tag_list);
}
fn lvoDeleteSource(rb: *RtaBase, source: ?*rta.AudioSource) callconv(.c) void {
    DeleteSource(rb, source);
}
fn lvoNextSource(rb: *RtaBase, after: ?*rta.AudioSource) callconv(.c) ?*rta.AudioSource {
    return NextSource(rb, after);
}
fn lvoNextSourceMode(rb: *RtaBase, source: *rta.AudioSource, after: ?*rta.AudioMode) callconv(.c) ?*rta.AudioMode {
    return NextSourceMode(rb, source, after);
}
fn lvoStartSource(rb: *RtaBase, source: *rta.AudioSource, mode: ?*rta.AudioMode, task: *exec.Task, signal_mask: u32) callconv(.c) i32 {
    return StartSource(rb, source, mode, task, signal_mask);
}
fn lvoStopSource(rb: *RtaBase, source: *rta.AudioSource) callconv(.c) void {
    StopSource(rb, source);
}
fn lvoSourceBuffer(rb: *RtaBase, source: *rta.AudioSource) callconv(.c) ?[*]const i16 {
    return SourceBuffer(rb, source);
}
fn lvoStartAudioTransportInput(rb: *RtaBase, io: *rta.AudioTransport, mode: *const rta.AudioMode, task: *exec.Task, signal_mask: u32) callconv(.c) i32 {
    return StartAudioTransportInput(rb, io, mode, task, signal_mask);
}
fn lvoStopAudioTransportInput(rb: *RtaBase, io: *rta.AudioTransport) callconv(.c) void {
    StopAudioTransportInput(rb, io);
}
fn lvoAudioTransportInput(rb: *RtaBase, io: *rta.AudioTransport) callconv(.c) ?[*]const i16 {
    return AudioTransportInput(rb, io);
}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(rta_base.expunge),
    vec(exec.libExtFunc),
    vec(lvoAddRtaDriver),
    vec(lvoRemRtaDriver),
    vec(lvoFindRtaDriver),
    vec(lvoLockRtaDrivers),
    vec(lvoUnlockRtaDrivers),
    vec(lvoNextRtaDriver),
    vec(lvoCreateSinkTagList),
    vec(lvoDeleteSink),
    vec(lvoNextSink),
    vec(lvoFindSink),
    vec(lvoSinkMode),
    vec(lvoStartSink),
    vec(lvoStopSink),
    vec(lvoSinkBuffer),
    vec(lvoPlaySinkBuffer),
    vec(lvoSinkControl),
    vec(lvoCreateAudioTransportTagList),
    vec(lvoDeleteAudioTransport),
    vec(lvoStartAudioTransport),
    vec(lvoStopAudioTransport),
    vec(lvoAudioTransportBuffer),
    vec(lvoPlayAudioTransportBuffer),
    vec(lvoRtaLastError),
    vec(lvoRtaErrorText),
    vec(lvoNextSinkMode),
    vec(lvoFindSinkMode),
    vec(lvoSetSinkMode),
    vec(lvoCreateSourceTagList),
    vec(lvoDeleteSource),
    vec(lvoNextSource),
    vec(lvoNextSourceMode),
    vec(lvoStartSource),
    vec(lvoStopSource),
    vec(lvoSourceBuffer),
    vec(lvoStartAudioTransportInput),
    vec(lvoStopAudioTransportInput),
    vec(lvoAudioTransportInput),
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "the jump table: the ROM's slots, every LVO at its function" {
    try testing.expectEqual(@as(usize, 41), vectors.len);
    inline for (@typeInfo(LVO).@"struct".decls) |d| {
        const index: usize = @intCast(@divExact(-@field(LVO, d.name), exec.slot_size) - 1);
        try testing.expectEqual(vec(@field(@This(), "lvo" ++ d.name)), vectors[index]);
    }
}

test "every wrapper hands its parameters on, in order, to the call it is named after" {
    try exec.libraries.checkForwarding(@embedFile("rta_lvo.zig"), LVO, &.{});
}
