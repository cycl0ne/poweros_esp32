// SPDX-License-Identifier: MIT
//! Host tests of vector.library: the library made from its ROM tag on the
//! ROM's exec, every call made through its jump table, and the pens it
//! drew checked. The drawing itself is tested in its module (draw/).

const std = @import("std");
const sdk = @import("sdk");
const vector = sdk.vector;
const utility = sdk.utility;
const Pen = sdk.graphics.Pen;
const host = @import("host_rom");
const kexec = host.exec;
const vector_init = @import("../vector_init.zig");

const testing = std.testing;
const VectorBase = sdk.interface.vector.VectorBase;

test {
    _ = @import("../vector_lvo.zig");
}

/// The library made and opened; given back by `close`.
const Rig = struct {
    library: *sdk.exec.Library,
    vb: *VectorBase,

    fn open() !Rig {
        try kexec.setUp();
        const sys = kexec.SysBase.iface();
        const made = kexec.InitResident(kexec.SysBase, &vector_init.vector_library_tag, null) orelse return error.NoLibrary;
        const vb: *VectorBase = @ptrCast(sys.OpenLibrary(vector.VECTORNAME, vector.VECTOR_VERSION) orelse return error.NoBase);
        return .{ .library = @ptrCast(@alignCast(made)), .vb = vb };
    }

    fn close(rig: Rig) !void {
        const sys = kexec.SysBase.iface();
        sys.CloseLibrary(rig.vb.lib());
        _ = sys.RemLibrary(rig.library);
        try kexec.expectNoLeaks();
        kexec.deinit();
    }
};

test "a triangle filled and a line stroked through the jump table, onto the caller's pens" {
    const rig = try Rig.open();
    const vb = rig.vb;
    var pens: [16 * 16]Pen = @splat(0);
    const tags = [_]utility.TagItem{
        .{ .tag = vector.VCA_Width, .data = 16 },
        .{ .tag = vector.VCA_Height, .data = 16 },
        .{ .tag = vector.VCA_Pens, .data = @intFromPtr(&pens) },
        .{},
    };
    const canvas = vb.CreateCanvasTagList(&tags) orelse return error.NoCanvas;
    const path = vb.CreatePath() orelse return error.NoPath;

    // A triangle in quarter pixels: ten pixels along each side.
    vb.MoveTo(path, 0, 0);
    vb.LineTo(path, 40, 0);
    vb.LineTo(path, 0, 40);
    vb.ClosePath(path);
    const quarter = vector.Matrix.scale(0.25, 0.25);
    const red = vector.Paint{ .colour = .{ .r = 1 } };
    try testing.expectEqual(vector.VECTOR_OK, vb.FillPath(canvas, path, &quarter, &red, vector.RULE_NONZERO));
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[1 * 16 + 1]);
    try testing.expectEqual(@as(Pen, 0), pens[14 * 16 + 14]);
    // On the diagonal, half covered: some red, not all of it.
    const edge = pens[5 * 16 + 4];
    try testing.expect(edge >> 24 != 0 and edge >> 24 != 0xFF);

    // A curve and a line stroked in white, two pixels wide, with round caps.
    vb.ClearPath(path);
    vb.MoveTo(path, 2, 14);
    vb.QuadTo(path, 8, 8, 14, 14);
    vb.CubicTo(path, 14, 15, 15, 15, 15, 15);
    const white = vector.Paint{ .colour = .{ .r = 1, .g = 1, .b = 1 } };
    const line = vector.Stroke{ .width = 2, .cap = vector.CAP_ROUND };
    try testing.expectEqual(vector.VECTOR_OK, vb.StrokePath(canvas, path, null, &white, &line));
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), pens[11 * 16 + 8]);

    // Without pens nothing is drawn.
    vb.SetCanvasPens(canvas, null, 0);
    try testing.expectEqual(vector.VECTOR_OK, vb.FillPath(canvas, path, null, &red, vector.RULE_NONZERO));
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), pens[11 * 16 + 8]);

    vb.DisposePath(path);
    vb.DisposeCanvas(canvas);
    vb.DisposePath(null);
    vb.DisposeCanvas(null);
    try rig.close();
}

test "a canvas's tags: followed through TAG_MORE and TAG_SKIP, and none without a size" {
    const rig = try Rig.open();
    const vb = rig.vb;
    try testing.expect(vb.CreateCanvasTagList(null) == null);
    const no_height = [_]utility.TagItem{ .{ .tag = vector.VCA_Width, .data = 4 }, .{} };
    try testing.expect(vb.CreateCanvasTagList(&no_height) == null);

    var pens: [4 * 3]Pen = @splat(0);
    const rest = [_]utility.TagItem{
        .{ .tag = vector.VCA_Height, .data = 3 },
        .{ .tag = vector.VCA_Pens, .data = @intFromPtr(&pens) },
        .{},
    };
    const tags = [_]utility.TagItem{
        .{ .tag = vector.VCA_Width, .data = 4 },
        .{ .tag = utility.TAG_SKIP, .data = 1 },
        .{ .tag = vector.VCA_Width, .data = 4000 },
        .{ .tag = utility.TAG_IGNORE, .data = 0 },
        .{ .tag = utility.TAG_MORE, .data = @intFromPtr(&rest) },
    };
    const canvas = vb.CreateCanvasTagList(&tags) orelse return error.NoCanvas;
    const path = vb.CreatePath() orelse return error.NoPath;
    vb.MoveTo(path, 0, 0);
    vb.LineTo(path, 4, 0);
    vb.LineTo(path, 4, 3);
    vb.LineTo(path, 0, 3);
    const blue = vector.Paint{ .colour = .{ .b = 1 } };
    _ = vb.FillPath(canvas, path, null, &blue, vector.RULE_NONZERO);
    for (pens) |pen| try testing.expectEqual(@as(Pen, 0xFF0000FF), pen);
    vb.DisposePath(path);
    vb.DisposeCanvas(canvas);
    try rig.close();
}

// --- since 1.1 ---------------------------------------------------------------------

fn canvasOver(vb: *VectorBase, pens: []Pen, width: u32, height: u32) !*vector.Canvas {
    const tags = [_]utility.TagItem{
        .{ .tag = vector.VCA_Width, .data = width },
        .{ .tag = vector.VCA_Height, .data = height },
        .{ .tag = vector.VCA_Pens, .data = @intFromPtr(pens.ptr) },
        .{},
    };
    return vb.CreateCanvasTagList(&tags) orelse error.NoCanvas;
}

test "revision 1: arcs, rectangles, ellipses and path data, measured by their bounds" {
    const rig = try Rig.open();
    const vb = rig.vb;
    try testing.expect(rig.library.revision >= 1);
    const path = vb.CreatePath() orelse return error.NoPath;
    var box: vector.Rect = undefined;
    try testing.expect(!vb.PathBounds(path, null, &box));

    vb.MoveTo(path, 0, 10);
    vb.ArcTo(path, 10, 10, 0, vector.ARC_SWEEP, 20, 10);
    try testing.expect(vb.PathBounds(path, null, &box));
    try testing.expectApproxEqAbs(@as(f32, 0), box.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 20), box.width, 0.01);

    vb.ClearPath(path);
    vb.AddRect(path, &.{ .x = 1, .y = 2, .width = 30, .height = 20 }, 5, 5);
    vb.AddEllipse(path, 50, 10, 5, 8);
    const twice = vector.Matrix.scale(2, 2);
    try testing.expect(vb.PathBounds(path, &twice, &box));
    try testing.expectApproxEqAbs(@as(f32, 2), box.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 4), box.y, 0.01);
    // The ellipse's right, 55, twice.
    try testing.expectApproxEqAbs(@as(f32, 110), box.x + box.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 44), box.y + box.height, 0.01);

    vb.ClearPath(path);
    const d = "M10 10h20v-5a5 5 0 0 1 5 5 z m0 0 L 1 1 x";
    try testing.expectEqual(vector.VECTORERR_SYNTAX, vb.AddPathData(path, d, d.len));
    try testing.expect(vb.PathBounds(path, null, &box));
    try testing.expectApproxEqAbs(@as(f32, 1), box.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 35), box.x + box.width, 0.01);
    vb.DisposePath(path);
    try rig.close();
}

test "a radial gradient filled and a dashed stroke drawn through the jump table" {
    const rig = try Rig.open();
    const vb = rig.vb;
    var pens: [20 * 20]Pen = @splat(0);
    const canvas = try canvasOver(vb, &pens, 20, 20);
    const path = vb.CreatePath() orelse return error.NoPath;
    vb.AddRect(path, &.{ .width = 20, .height = 20 }, 0, 0);
    const stops = [_]vector.Stop{
        .{ .offset = 0, .colour = .{ .r = 1, .g = 1, .b = 1 } },
        .{ .offset = 1, .colour = .{ .a = 1 } },
    };
    const glow = vector.Paint{ .kind = vector.PAINT_RADIAL, .stops = &stops, .stop_count = 2, .cx = 10, .cy = 10, .r = 10, .fx = 10, .fy = 10 };
    try testing.expectEqual(vector.VECTOR_OK, vb.FillPath(canvas, path, null, &glow, vector.RULE_NONZERO));
    // White at the middle, black at the corners, between half way.
    try testing.expect(pens[10 * 20 + 10] & 0xFF > 0xE0);
    try testing.expectEqual(@as(Pen, 0xFF000000), pens[0]);
    const half = pens[10 * 20 + 15] & 0xFF;
    try testing.expect(half > 0x60 and half < 0xA0);

    @memset(&pens, 0);
    vb.ClearPath(path);
    const d = "M0 10 H20";
    _ = vb.AddPathData(path, d, d.len);
    const dashes = [_]f32{ 3, 2 };
    const line = vector.Stroke{ .width = 2, .dashes = &dashes, .dash_count = 2, .dash_offset = 1 };
    const white = vector.Paint{ .colour = .{ .r = 1, .g = 1, .b = 1 } };
    try testing.expectEqual(vector.VECTOR_OK, vb.StrokePath(canvas, path, null, &white, &line));
    // From 1 in: 0-2 on, 2-4 off, 4-7 on, 7-9 off.
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), pens[10 * 20 + 1]);
    try testing.expectEqual(@as(Pen, 0), pens[10 * 20 + 3]);
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), pens[10 * 20 + 5]);
    try testing.expectEqual(@as(Pen, 0), pens[10 * 20 + 8]);
    vb.DisposePath(path);
    vb.DisposeCanvas(canvas);
    try rig.close();
}

test "shapes on a layer overlap once at its opacity, and one left pushed goes with the canvas" {
    const rig = try Rig.open();
    const vb = rig.vb;
    var pens: [10 * 10]Pen = @splat(0);
    const canvas = try canvasOver(vb, &pens, 10, 10);
    const a = vb.CreatePath() orelse return error.NoPath;
    const b = vb.CreatePath() orelse return error.NoPath;
    vb.AddRect(a, &.{ .width = 6, .height = 6 }, 0, 0);
    vb.AddRect(b, &.{ .x = 4, .y = 4, .width = 6, .height = 6 }, 0, 0);
    const blue = vector.Paint{ .colour = .{ .b = 1 } };
    try testing.expectEqual(vector.VECTOR_OK, vb.PushLayer(canvas, 0.5));
    _ = vb.FillPath(canvas, a, null, &blue, vector.RULE_NONZERO);
    _ = vb.FillPath(canvas, b, null, &blue, vector.RULE_NONZERO);
    try testing.expectEqual(@as(Pen, 0), pens[5 * 10 + 5]);
    vb.PopLayer(canvas);
    try testing.expectEqual(@as(Pen, 0x800000FF), pens[1 * 10 + 1]);
    try testing.expectEqual(@as(Pen, 0x800000FF), pens[5 * 10 + 5]);
    vb.PopLayer(canvas);
    _ = vb.PushLayer(canvas, 1);
    vb.DisposePath(a);
    vb.DisposePath(b);
    vb.DisposeCanvas(canvas);
    try rig.close();
}

// --- since 1.2 ---------------------------------------------------------------------

test "revision 2: a path handed over whole fills as the same path built a segment at a time" {
    const rig = try Rig.open();
    const vb = rig.vb;
    try testing.expect(rig.library.revision >= 2);
    var whole_pens: [12 * 12]Pen = @splat(0);
    var one_pens: [12 * 12]Pen = @splat(0);
    const whole_canvas = try canvasOver(vb, &whole_pens, 12, 12);
    const one_canvas = try canvasOver(vb, &one_pens, 12, 12);
    const whole = vb.CreatePath() orelse return error.NoPath;
    const one = vb.CreatePath() orelse return error.NoPath;

    const verbs = [_]u8{ vector.SEG_MOVE, vector.SEG_LINE, vector.SEG_CUBIC, vector.SEG_QUAD, vector.SEG_CLOSE };
    const points = [_]vector.Point{
        .{ .x = 1, .y = 1 },  .{ .x = 10, .y = 1 },
        .{ .x = 12, .y = 5 }, .{ .x = 8, .y = 11 },
        .{ .x = 5, .y = 10 }, .{ .x = 0, .y = 9 },
        .{ .x = 2, .y = 5 },
    };
    try testing.expectEqual(vector.VECTOR_OK, vb.AddSegments(whole, &verbs, verbs.len, &points, points.len));
    vb.MoveTo(one, 1, 1);
    vb.LineTo(one, 10, 1);
    vb.CubicTo(one, 12, 5, 8, 11, 5, 10);
    vb.QuadTo(one, 0, 9, 2, 5);
    vb.ClosePath(one);
    const green = vector.Paint{ .colour = .{ .g = 1 } };
    try testing.expectEqual(vector.VECTOR_OK, vb.FillPath(whole_canvas, whole, null, &green, vector.RULE_NONZERO));
    _ = vb.FillPath(one_canvas, one, null, &green, vector.RULE_NONZERO);
    try testing.expectEqualSlices(Pen, &one_pens, &whole_pens);
    try testing.expectEqual(@as(Pen, 0xFF00FF00), whole_pens[5 * 12 + 5]);

    // A quadratic curve one point short: what came before it is kept.
    vb.ClearPath(whole);
    try testing.expectEqual(vector.VECTORERR_SYNTAX, vb.AddSegments(whole, &verbs, 4, &points, 6));
    vb.ClearPath(one);
    vb.MoveTo(one, 1, 1);
    vb.LineTo(one, 10, 1);
    vb.CubicTo(one, 12, 5, 8, 11, 5, 10);
    var box: vector.Rect = undefined;
    var want: vector.Rect = undefined;
    try testing.expect(vb.PathBounds(whole, null, &box));
    try testing.expect(vb.PathBounds(one, null, &want));
    try testing.expectEqual(want, box);
    // Nothing at all.
    vb.ClearPath(whole);
    try testing.expectEqual(vector.VECTOR_OK, vb.AddSegments(whole, &verbs, 0, &points, 0));
    try testing.expect(!vb.PathBounds(whole, null, &box));

    vb.DisposePath(whole);
    vb.DisposePath(one);
    vb.DisposeCanvas(whole_canvas);
    vb.DisposeCanvas(one_canvas);
    try rig.close();
}

// --- since 1.3 ---------------------------------------------------------------------

test "revision 3: a clip and a mask through the jump table, and both left pushed go with the canvas" {
    const rig = try Rig.open();
    const vb = rig.vb;
    try testing.expect(rig.library.revision >= 3);
    var pens: [10 * 10]Pen = @splat(0);
    const canvas = try canvasOver(vb, &pens, 10, 10);
    const all = vb.CreatePath() orelse return error.NoPath;
    const round = vb.CreatePath() orelse return error.NoPath;
    vb.AddRect(all, &.{ .width = 10, .height = 10 }, 0, 0);
    vb.AddEllipse(round, 0.5, 0.5, 0.4, 0.4);
    const twice = vector.Matrix.scale(10, 10);
    const red = vector.Paint{ .colour = .{ .r = 1 } };
    try testing.expectEqual(vector.VECTOR_OK, vb.PushClip(canvas, round, &twice, vector.RULE_NONZERO));
    _ = vb.FillPath(canvas, all, null, &red, vector.RULE_NONZERO);
    vb.PopClip(canvas);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[5 * 10 + 5]);
    try testing.expectEqual(@as(Pen, 0), pens[0]);

    // Half a grey: a mask by luminance lets half through.
    @memset(&pens, 0);
    const grey = vector.Paint{ .colour = .{ .r = 0.5, .g = 0.5, .b = 0.5 } };
    try testing.expectEqual(vector.VECTOR_OK, vb.BeginMask(canvas));
    _ = vb.FillPath(canvas, all, null, &grey, vector.RULE_NONZERO);
    try testing.expectEqual(vector.VECTOR_OK, vb.EndMask(canvas, vector.MASK_LUMINANCE));
    _ = vb.FillPath(canvas, all, null, &red, vector.RULE_NONZERO);
    vb.PopClip(canvas);
    try testing.expectEqual(@as(Pen, 0x80FF0000), pens[5 * 10 + 5]);

    _ = vb.PushClip(canvas, round, &twice, vector.RULE_NONZERO);
    _ = vb.BeginMask(canvas);
    vb.DisposePath(all);
    vb.DisposePath(round);
    vb.DisposeCanvas(canvas);
    try rig.close();
}

// --- since 1.4 ---------------------------------------------------------------------

test "revision 4: an image painted, placed by its matrix; a layer blurred; neither without what it needs" {
    const rig = try Rig.open();
    const vb = rig.vb;
    try testing.expectEqual(@as(u16, 4), rig.library.revision);
    var pens: [16 * 16]Pen = @splat(0);
    const canvas = try canvasOver(vb, &pens, 16, 16);
    const square = vb.CreatePath() orelse return error.NoPath;
    vb.AddRect(square, &.{ .x = 4, .y = 4, .width = 8, .height = 8 }, 0, 0);

    // Two by two pixels spread over the square: each a quarter of it.
    const image = [_]Pen{ 0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFFFF };
    const paint = vector.Paint{
        .kind = vector.PAINT_IMAGE,
        .image = &image,
        .image_width = 2,
        .image_height = 2,
        .image_bytes_per_row = 8,
        .matrix = (vector.Matrix.translate(4, 4)).then(vector.Matrix.scale(4, 4)),
    };
    try testing.expectEqual(vector.VECTOR_OK, vb.FillPath(canvas, square, null, &paint, vector.RULE_NONZERO));
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[4 * 16 + 4]);
    try testing.expectEqual(@as(Pen, 0xFF00FF00), pens[4 * 16 + 11]);
    try testing.expectEqual(@as(Pen, 0xFF0000FF), pens[11 * 16 + 4]);
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), pens[11 * 16 + 11]);
    // Between them, a mix; outside the square, nothing.
    const between = pens[4 * 16 + 8];
    try testing.expect((between >> 16) & 0xFF > 0 and (between >> 8) & 0xFF > 0);
    try testing.expectEqual(@as(Pen, 0), pens[2 * 16 + 2]);

    // A layer blurred: the square spreads past its edge, softer inside.
    @memset(&pens, 0);
    try testing.expectEqual(vector.VECTORERR_DEPTH, vb.BlurLayer(canvas, 1, 1));
    const red = vector.Paint{ .colour = .{ .r = 1 } };
    _ = vb.PushLayer(canvas, 1);
    _ = vb.FillPath(canvas, square, null, &red, vector.RULE_NONZERO);
    try testing.expectEqual(vector.VECTOR_OK, vb.BlurLayer(canvas, 1.5, 1.5));
    vb.PopLayer(canvas);
    try testing.expect(pens[8 * 16 + 2] >> 24 > 0);
    try testing.expect(pens[4 * 16 + 4] >> 24 < 0xFF);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[8 * 16 + 8]);
    try testing.expectEqual(@as(u32, 0xFF0000), pens[8 * 16 + 2] & 0xFFFFFF);

    vb.DisposePath(square);
    vb.DisposeCanvas(canvas);
    try rig.close();
}
