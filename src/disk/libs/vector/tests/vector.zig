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
    try testing.expectEqual(@as(u16, 1), rig.library.revision);
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
