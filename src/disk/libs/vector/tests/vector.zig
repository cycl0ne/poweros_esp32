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
