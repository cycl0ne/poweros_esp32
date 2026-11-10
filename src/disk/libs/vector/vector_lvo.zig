// SPDX-License-Identifier: MIT
//! vector.library's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const utility = sdk.utility;
const vector = sdk.vector;
const vec = exec.vec;
const VectorBase = @import("vector_base.zig").VectorBase;
const vector_init = @import("vector_init.zig");

const CreatePath = @import("path/createpath.zig").CreatePath;
const DisposePath = @import("path/disposepath.zig").DisposePath;
const ClearPath = @import("path/clearpath.zig").ClearPath;
const MoveTo = @import("path/moveto.zig").MoveTo;
const LineTo = @import("path/lineto.zig").LineTo;
const QuadTo = @import("path/quadto.zig").QuadTo;
const CubicTo = @import("path/cubicto.zig").CubicTo;
const ClosePath = @import("path/closepath.zig").ClosePath;
const CreateCanvasTagList = @import("canvas/createcanvastaglist.zig").CreateCanvasTagList;
const DisposeCanvas = @import("canvas/disposecanvas.zig").DisposeCanvas;
const SetCanvasPens = @import("canvas/setcanvaspens.zig").SetCanvasPens;
const FillPath = @import("canvas/fillpath.zig").FillPath;
const StrokePath = @import("canvas/strokepath.zig").StrokePath;
const ArcTo = @import("path/arcto.zig").ArcTo;
const AddRect = @import("path/addrect.zig").AddRect;
const AddEllipse = @import("path/addellipse.zig").AddEllipse;
const AddPathData = @import("path/addpathdata.zig").AddPathData;
const PathBounds = @import("path/pathbounds.zig").PathBounds;
const PushLayer = @import("canvas/pushlayer.zig").PushLayer;
const PopLayer = @import("canvas/poplayer.zig").PopLayer;
const AddSegments = @import("path/addsegments.zig").AddSegments;
const PushClip = @import("canvas/pushclip.zig").PushClip;
const PopClip = @import("canvas/popclip.zig").PopClip;
const BeginMask = @import("canvas/beginmask.zig").BeginMask;
const EndMask = @import("canvas/endmask.zig").EndMask;

/// vector.library's interface, as the SDK generates it from
/// sdk/fd/vector_lib.fd.
const interface = sdk.interface.vector;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("vector.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "vector.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("path/createpath.zig"),
    @embedFile("path/disposepath.zig"),
    @embedFile("path/clearpath.zig"),
    @embedFile("path/moveto.zig"),
    @embedFile("path/lineto.zig"),
    @embedFile("path/quadto.zig"),
    @embedFile("path/cubicto.zig"),
    @embedFile("path/closepath.zig"),
    @embedFile("canvas/createcanvastaglist.zig"),
    @embedFile("canvas/disposecanvas.zig"),
    @embedFile("canvas/setcanvaspens.zig"),
    @embedFile("canvas/fillpath.zig"),
    @embedFile("canvas/strokepath.zig"),
    @embedFile("path/arcto.zig"),
    @embedFile("path/addrect.zig"),
    @embedFile("path/addellipse.zig"),
    @embedFile("path/addpathdata.zig"),
    @embedFile("path/pathbounds.zig"),
    @embedFile("canvas/pushlayer.zig"),
    @embedFile("canvas/poplayer.zig"),
    @embedFile("path/addsegments.zig"),
    @embedFile("canvas/pushclip.zig"),
    @embedFile("canvas/popclip.zig"),
    @embedFile("canvas/beginmask.zig"),
    @embedFile("canvas/endmask.zig"),
};

fn lvoCreatePath(vb: *VectorBase) callconv(.c) ?*vector.Path {
    return CreatePath(vb);
}
fn lvoDisposePath(vb: *VectorBase, path: ?*vector.Path) callconv(.c) void {
    return DisposePath(vb, path);
}
fn lvoClearPath(vb: *VectorBase, path: *vector.Path) callconv(.c) void {
    return ClearPath(vb, path);
}
fn lvoMoveTo(vb: *VectorBase, path: *vector.Path, x: f32, y: f32) callconv(.c) void {
    return MoveTo(vb, path, x, y);
}
fn lvoLineTo(vb: *VectorBase, path: *vector.Path, x: f32, y: f32) callconv(.c) void {
    return LineTo(vb, path, x, y);
}
fn lvoQuadTo(vb: *VectorBase, path: *vector.Path, x1: f32, y1: f32, x: f32, y: f32) callconv(.c) void {
    return QuadTo(vb, path, x1, y1, x, y);
}
fn lvoCubicTo(vb: *VectorBase, path: *vector.Path, x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32) callconv(.c) void {
    return CubicTo(vb, path, x1, y1, x2, y2, x, y);
}
fn lvoClosePath(vb: *VectorBase, path: *vector.Path) callconv(.c) void {
    return ClosePath(vb, path);
}
fn lvoCreateCanvasTagList(vb: *VectorBase, tags: ?[*]const utility.TagItem) callconv(.c) ?*vector.Canvas {
    return CreateCanvasTagList(vb, tags);
}
fn lvoDisposeCanvas(vb: *VectorBase, canvas: ?*vector.Canvas) callconv(.c) void {
    return DisposeCanvas(vb, canvas);
}
fn lvoSetCanvasPens(vb: *VectorBase, canvas: *vector.Canvas, pens: ?[*]graphics.Pen, bytes_per_row: u32) callconv(.c) void {
    return SetCanvasPens(vb, canvas, pens, bytes_per_row);
}
fn lvoFillPath(vb: *VectorBase, canvas: *vector.Canvas, path: *const vector.Path, matrix: ?*const vector.Matrix, paint: *const vector.Paint, rule: u32) callconv(.c) i32 {
    return FillPath(vb, canvas, path, matrix, paint, rule);
}
fn lvoStrokePath(vb: *VectorBase, canvas: *vector.Canvas, path: *const vector.Path, matrix: ?*const vector.Matrix, paint: *const vector.Paint, stroke: *const vector.Stroke) callconv(.c) i32 {
    return StrokePath(vb, canvas, path, matrix, paint, stroke);
}
fn lvoArcTo(vb: *VectorBase, path: *vector.Path, rx: f32, ry: f32, angle: f32, flags: u32, x: f32, y: f32) callconv(.c) void {
    return ArcTo(vb, path, rx, ry, angle, flags, x, y);
}
fn lvoAddRect(vb: *VectorBase, path: *vector.Path, rect: *const vector.Rect, rx: f32, ry: f32) callconv(.c) void {
    return AddRect(vb, path, rect, rx, ry);
}
fn lvoAddEllipse(vb: *VectorBase, path: *vector.Path, cx: f32, cy: f32, rx: f32, ry: f32) callconv(.c) void {
    return AddEllipse(vb, path, cx, cy, rx, ry);
}
fn lvoAddPathData(vb: *VectorBase, path: *vector.Path, text: [*]const u8, length: u32) callconv(.c) i32 {
    return AddPathData(vb, path, text, length);
}
fn lvoPathBounds(vb: *VectorBase, path: *const vector.Path, matrix: ?*const vector.Matrix, bounds: *vector.Rect) callconv(.c) bool {
    return PathBounds(vb, path, matrix, bounds);
}
fn lvoPushLayer(vb: *VectorBase, canvas: *vector.Canvas, opacity: f32) callconv(.c) i32 {
    return PushLayer(vb, canvas, opacity);
}
fn lvoPopLayer(vb: *VectorBase, canvas: *vector.Canvas) callconv(.c) void {
    return PopLayer(vb, canvas);
}
fn lvoAddSegments(vb: *VectorBase, path: *vector.Path, verbs: [*]const u8, verb_count: u32, points: [*]const vector.Point, point_count: u32) callconv(.c) i32 {
    return AddSegments(vb, path, verbs, verb_count, points, point_count);
}
fn lvoPushClip(vb: *VectorBase, canvas: *vector.Canvas, path: *const vector.Path, matrix: ?*const vector.Matrix, rule: u32) callconv(.c) i32 {
    return PushClip(vb, canvas, path, matrix, rule);
}
fn lvoPopClip(vb: *VectorBase, canvas: *vector.Canvas) callconv(.c) void {
    return PopClip(vb, canvas);
}
fn lvoBeginMask(vb: *VectorBase, canvas: *vector.Canvas) callconv(.c) i32 {
    return BeginMask(vb, canvas);
}
fn lvoEndMask(vb: *VectorBase, canvas: *vector.Canvas, kind: u32) callconv(.c) i32 {
    return EndMask(vb, canvas, kind);
}

pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(vector_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoCreatePath),
    vec(lvoDisposePath),
    vec(lvoClearPath),
    vec(lvoMoveTo),
    vec(lvoLineTo),
    vec(lvoQuadTo),
    vec(lvoCubicTo),
    vec(lvoClosePath),
    vec(lvoCreateCanvasTagList),
    vec(lvoDisposeCanvas),
    vec(lvoSetCanvasPens),
    vec(lvoFillPath),
    vec(lvoStrokePath),
    vec(lvoArcTo),
    vec(lvoAddRect),
    vec(lvoAddEllipse),
    vec(lvoAddPathData),
    vec(lvoPathBounds),
    vec(lvoPushLayer),
    vec(lvoPopLayer),
    vec(lvoAddSegments),
    vec(lvoPushClip),
    vec(lvoPopClip),
    vec(lvoBeginMask),
    vec(lvoEndMask),
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
    try exec.libraries.checkForwarding(@embedFile("vector_lvo.zig"), LVO, &.{});
}
