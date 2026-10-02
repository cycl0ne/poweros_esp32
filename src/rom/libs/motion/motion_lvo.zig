// SPDX-License-Identifier: MPL-2.0
//! motion.library's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const motion = sdk.motion;
const vec = exec.vec;
const motion_base = @import("motion_base.zig");
const MotionBase = motion_base.MotionBase;
const Ease = @import("ease/ease.zig").Ease;
const EaseBezier = @import("ease/easebezier.zig").EaseBezier;
const CreateAnimationTagList = @import("anim/createanimationtaglist.zig").CreateAnimationTagList;
const DeleteAnimation = @import("anim/deleteanimation.zig").DeleteAnimation;
const StartAnimation = @import("anim/startanimation.zig").StartAnimation;
const StopAnimation = @import("anim/stopanimation.zig").StopAnimation;
const SetAnimationAttrsTagList = @import("anim/setanimationattrstaglist.zig").SetAnimationAttrsTagList;
const GetAnimationAttr = @import("anim/getanimationattr.zig").GetAnimationAttr;
const MixColour = @import("mix/mixcolour.zig").MixColour;
const MixRect = @import("mix/mixrect.zig").MixRect;
const CreateTimerTagList = @import("timer/createtimertaglist.zig").CreateTimerTagList;
const DeleteTimer = @import("timer/deletetimer.zig").DeleteTimer;
const StartTimer = @import("timer/starttimer.zig").StartTimer;
const StopTimer = @import("timer/stoptimer.zig").StopTimer;
const CreateTimelineTagList = @import("timeline/createtimelinetaglist.zig").CreateTimelineTagList;
const DeleteTimeline = @import("timeline/deletetimeline.zig").DeleteTimeline;
const AddTimelineAnimation = @import("timeline/addtimelineanimation.zig").AddTimelineAnimation;
const StartTimeline = @import("timeline/starttimeline.zig").StartTimeline;
const StopTimeline = @import("timeline/stoptimeline.zig").StopTimeline;
const SetTimelineProgress = @import("timeline/settimelineprogress.zig").SetTimelineProgress;
const SetTimelineAttrsTagList = @import("timeline/settimelineattrstaglist.zig").SetTimelineAttrsTagList;

/// motion.library's interface, as the SDK generates it from
/// sdk/fd/motion_lib.fd.
const interface = sdk.interface.motion;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("motion.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "motion.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("ease/ease.zig"),
    @embedFile("ease/easebezier.zig"),
    @embedFile("anim/createanimationtaglist.zig"),
    @embedFile("anim/deleteanimation.zig"),
    @embedFile("anim/startanimation.zig"),
    @embedFile("anim/stopanimation.zig"),
    @embedFile("anim/setanimationattrstaglist.zig"),
    @embedFile("anim/getanimationattr.zig"),
    @embedFile("mix/mixcolour.zig"),
    @embedFile("mix/mixrect.zig"),
    @embedFile("timer/createtimertaglist.zig"),
    @embedFile("timer/deletetimer.zig"),
    @embedFile("timer/starttimer.zig"),
    @embedFile("timer/stoptimer.zig"),
    @embedFile("timeline/createtimelinetaglist.zig"),
    @embedFile("timeline/deletetimeline.zig"),
    @embedFile("timeline/addtimelineanimation.zig"),
    @embedFile("timeline/starttimeline.zig"),
    @embedFile("timeline/stoptimeline.zig"),
    @embedFile("timeline/settimelineprogress.zig"),
    @embedFile("timeline/settimelineattrstaglist.zig"),
};

fn lvoEase(mb: *MotionBase, curve: u32, progress: u32) callconv(.c) i32 {
    return Ease(mb, curve, progress);
}
fn lvoEaseBezier(mb: *MotionBase, x1: i32, y1: i32, x2: i32, y2: i32, progress: u32) callconv(.c) i32 {
    return EaseBezier(mb, x1, y1, x2, y2, progress);
}
fn lvoCreateAnimationTagList(mb: *MotionBase, tags: ?[*]const utility.TagItem) callconv(.c) ?*motion.Animation {
    return CreateAnimationTagList(mb, tags);
}
fn lvoDeleteAnimation(mb: *MotionBase, animation: ?*motion.Animation) callconv(.c) void {
    DeleteAnimation(mb, animation);
}
fn lvoStartAnimation(mb: *MotionBase, animation: *motion.Animation) callconv(.c) void {
    StartAnimation(mb, animation);
}
fn lvoStopAnimation(mb: *MotionBase, animation: *motion.Animation, where: u32) callconv(.c) void {
    StopAnimation(mb, animation, where);
}
fn lvoSetAnimationAttrsTagList(mb: *MotionBase, animation: *motion.Animation, tags: ?[*]const utility.TagItem) callconv(.c) u32 {
    return SetAnimationAttrsTagList(mb, animation, tags);
}
fn lvoGetAnimationAttr(mb: *MotionBase, animation: *motion.Animation, attr: utility.Tag) callconv(.c) usize {
    return GetAnimationAttr(mb, animation, attr);
}
fn lvoMixColour(mb: *MotionBase, from: u32, to: u32, amount: u32) callconv(.c) u32 {
    return MixColour(mb, from, to, amount);
}
fn lvoMixRect(mb: *MotionBase, from: *const graphics.Rect, to: *const graphics.Rect, amount: u32, result: *graphics.Rect) callconv(.c) void {
    MixRect(mb, from, to, amount, result);
}
fn lvoCreateTimerTagList(mb: *MotionBase, tags: ?[*]const utility.TagItem) callconv(.c) ?*motion.Timer {
    return CreateTimerTagList(mb, tags);
}
fn lvoDeleteTimer(mb: *MotionBase, timer: ?*motion.Timer) callconv(.c) void {
    DeleteTimer(mb, timer);
}
fn lvoStartTimer(mb: *MotionBase, timer: *motion.Timer) callconv(.c) void {
    StartTimer(mb, timer);
}
fn lvoStopTimer(mb: *MotionBase, timer: *motion.Timer) callconv(.c) void {
    StopTimer(mb, timer);
}
fn lvoCreateTimelineTagList(mb: *MotionBase, tags: ?[*]const utility.TagItem) callconv(.c) ?*motion.Timeline {
    return CreateTimelineTagList(mb, tags);
}
fn lvoDeleteTimeline(mb: *MotionBase, timeline: ?*motion.Timeline) callconv(.c) void {
    DeleteTimeline(mb, timeline);
}
fn lvoAddTimelineAnimation(mb: *MotionBase, timeline: *motion.Timeline, animation: *motion.Animation, offset: u32) callconv(.c) bool {
    return AddTimelineAnimation(mb, timeline, animation, offset);
}
fn lvoStartTimeline(mb: *MotionBase, timeline: *motion.Timeline) callconv(.c) void {
    StartTimeline(mb, timeline);
}
fn lvoStopTimeline(mb: *MotionBase, timeline: *motion.Timeline, where: u32) callconv(.c) void {
    StopTimeline(mb, timeline, where);
}
fn lvoSetTimelineProgress(mb: *MotionBase, timeline: *motion.Timeline, at: u32) callconv(.c) void {
    SetTimelineProgress(mb, timeline, at);
}
fn lvoSetTimelineAttrsTagList(mb: *MotionBase, timeline: *motion.Timeline, tags: ?[*]const utility.TagItem) callconv(.c) u32 {
    return SetTimelineAttrsTagList(mb, timeline, tags);
}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(motion_base.expunge),
    vec(exec.libExtFunc),
    vec(lvoEase),
    vec(lvoEaseBezier),
    vec(lvoCreateAnimationTagList),
    vec(lvoDeleteAnimation),
    vec(lvoStartAnimation),
    vec(lvoStopAnimation),
    vec(lvoSetAnimationAttrsTagList),
    vec(lvoGetAnimationAttr),
    vec(lvoMixColour),
    vec(lvoMixRect),
    vec(lvoCreateTimerTagList),
    vec(lvoDeleteTimer),
    vec(lvoStartTimer),
    vec(lvoStopTimer),
    vec(lvoCreateTimelineTagList),
    vec(lvoDeleteTimeline),
    vec(lvoAddTimelineAnimation),
    vec(lvoStartTimeline),
    vec(lvoStopTimeline),
    vec(lvoSetTimelineProgress),
    vec(lvoSetTimelineAttrsTagList),
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
    try exec.libraries.checkForwarding(@embedFile("motion_lvo.zig"), LVO, &.{});
}
