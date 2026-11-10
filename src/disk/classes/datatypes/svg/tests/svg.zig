// SPDX-License-Identifier: MIT
//! Host tests of svg.datatype's reading and drawing: files read into a
//! document and drawn through vector.library - made from its ROM tag on
//! the ROM's exec, as the datatype's init opens it - and their pens
//! looked at.

const std = @import("std");
const sdk = @import("sdk");
const vector = sdk.vector;
const utility = sdk.utility;
const exec = sdk.exec;
const Pen = sdk.graphics.Pen;
const host = @import("host_rom");
const kexec = host.exec;
const vector_init = @import("../../../../libs/vector/vector_init.zig");
const document = @import("../document.zig");
const drawing = @import("../draw.zig");

const testing = std.testing;
const VectorBase = sdk.interface.vector.VectorBase;

test {
    _ = @import("../xml.zig");
    _ = @import("../values.zig");
    _ = @import("../css.zig");
    _ = document;
    _ = drawing;
}

/// Memory lent to exec, for the canvases and their layers.
var lent: [1024 * 1024]u8 align(16) = undefined;

/// vector.library made and opened, and a path from it.
const Rig = struct {
    region: *exec.MemHeader,
    library: *exec.Library,
    vb: *VectorBase,
    path: *vector.Path,

    fn open() !Rig {
        try kexec.setUp();
        const sys = kexec.SysBase.iface();
        const region = sys.AddMemList(lent.len, exec.MEMF_ANY, 0, &lent, "lent").?;
        const made = kexec.InitResident(kexec.SysBase, &vector_init.vector_library_tag, null) orelse return error.NoLibrary;
        const vb: *VectorBase = @ptrCast(sys.OpenLibrary(vector.VECTORNAME, vector.VECTOR_VERSION) orelse return error.NoBase);
        return .{
            .region = region,
            .library = @ptrCast(@alignCast(made)),
            .vb = vb,
            .path = vb.CreatePath() orelse return error.NoPath,
        };
    }

    fn close(rig: Rig) !void {
        const sys = kexec.SysBase.iface();
        rig.vb.DisposePath(rig.path);
        sys.CloseLibrary(rig.vb.lib());
        _ = sys.RemLibrary(rig.library);
        try kexec.expectNoLeaks();
        try testing.expectEqual(@intFromPtr(rig.region.upper) - @intFromPtr(rig.region.lower), rig.region.free);
        sys.Remove(&rig.region.node);
        kexec.deinit();
    }

    /// `text` drawn `width` by `height` onto `pens`, cleared first.
    fn draw(rig: Rig, text: []const u8, width: u32, height: u32, pens: []Pen) !void {
        @memset(pens, 0);
        const copy = try testing.allocator.dupe(u8, text);
        defer testing.allocator.free(copy);
        const counts = document.count(copy) orelse return error.NotSvg;
        const bytes = document.bytesFor(counts);
        const block = try testing.allocator.alignedAlloc(u8, .@"8", @max(bytes, 8));
        defer testing.allocator.free(block);
        const doc = document.build(copy, counts, block[0..bytes]);
        const work = try testing.allocator.create(drawing.Work);
        defer testing.allocator.destroy(work);
        const tags = [_]utility.TagItem{
            .{ .tag = vector.VCA_Width, .data = width },
            .{ .tag = vector.VCA_Height, .data = height },
            .{ .tag = vector.VCA_Pens, .data = @intFromPtr(pens.ptr) },
            .{},
        };
        const canvas = rig.vb.CreateCanvasTagList(&tags) orelse return error.NoCanvas;
        defer rig.vb.DisposeCanvas(canvas);
        const size = drawing.intrinsic(&doc);
        drawing.draw(rig.vb, &doc, canvas, rig.path, work, drawing.baseMatrix(size, width, height), size.viewport);
    }
};

fn intrinsicOf(text: []const u8) !drawing.Intrinsic {
    const copy = try testing.allocator.dupe(u8, text);
    defer testing.allocator.free(copy);
    const counts = document.count(copy) orelse return error.NotSvg;
    var block: [4096]u8 align(8) = undefined;
    const doc = document.build(copy, counts, block[0..document.bytesFor(counts)]);
    return drawing.intrinsic(&doc);
}

test "a picture's size: its width and height, from its viewBox, or CSS's" {
    var size = try intrinsicOf("<svg width='48.000000px' height='3cm'/>");
    try testing.expectEqual(@as(f32, 48), size.width);
    try testing.expectApproxEqAbs(@as(f32, 113.39), size.height, 0.01);
    size = try intrinsicOf("<svg viewBox='0 0 160 120' width='320'/>");
    try testing.expectEqual(@as(f32, 240), size.height);
    try testing.expectEqual([2]f32{ 160, 120 }, size.viewport);
    try testing.expectEqual(vector.Point{ .x = 320, .y = 240 }, size.view.apply(.{ .x = 160, .y = 120 }));
    size = try intrinsicOf("<svg width='100%'/>");
    try testing.expectEqual(@as(f32, 300), size.width);
    try testing.expectEqual(@as(f32, 150), size.height);
    try testing.expectEqual([2]u32{ 16384, 8192 }, drawing.fullSize(.{ .width = 40000, .height = 20000, .view = .{}, .viewport = .{ 1, 1 } }));
    // xMidYMid meet: a wide box in a square, in the middle.
    size = try intrinsicOf("<svg viewBox='0 0 20 10' width='20' height='20'/>");
    try testing.expectEqual(vector.Point{ .x = 0, .y = 5 }, size.view.apply(.{}));
}

test "the size a program wants: the shape fitted inside it, one side alone, the file's own without" {
    const icon = try intrinsicOf("<svg width='48px' height='48px'/>");
    try testing.expectEqual([2]u32{ 40, 40 }, drawing.wantedSize(icon, 40, 40));
    try testing.expectEqual([2]u32{ 256, 256 }, drawing.wantedSize(icon, 256, 0));
    try testing.expectEqual([2]u32{ 48, 48 }, drawing.wantedSize(icon, 0, 0));
    try testing.expectEqual([2]u32{ 16384, 16384 }, drawing.wantedSize(icon, 100000, 100000));
    const wide = try intrinsicOf("<svg viewBox='0 0 300 150'/>");
    try testing.expectEqual([2]u32{ 100, 50 }, drawing.wantedSize(wide, 100, 100));
    try testing.expectEqual([2]u32{ 600, 300 }, drawing.wantedSize(wide, 600, 0));
    try testing.expectEqual([2]u32{ 60, 30 }, drawing.wantedSize(wide, 0, 30));
    // Never less than a pixel.
    try testing.expectEqual([2]u32{ 2, 1 }, drawing.wantedSize(wide, 2, 2));
}

test "shapes filled and stroked: a style over its attributes, inherited from a group, scaled by a viewBox" {
    const rig = try Rig.open();
    var pens: [20 * 20]Pen = undefined;
    try rig.draw(
        \\<svg width="20" height="20" viewBox="0 0 10 10">
        \\  <g fill="red" style="fill:#00f">
        \\    <rect width="5" height="5"/>
        \\    <circle cx="7.5" cy="2.5" r="2" fill="lime"/>
        \\    <rect y="5" width="5" height="5" style="fill:yellow" fill="black"/>
        \\    <rect x="5" y="5" width="5" height="5" display="none"/>
        \\    <polygon points="5,10 10,10 10,5" visibility="hidden"/>
        \\  </g>
        \\</svg>
    , 20, 20, &pens);
    try testing.expectEqual(@as(Pen, 0xFF0000FF), pens[5 * 20 + 5]);
    try testing.expectEqual(@as(Pen, 0xFF00FF00), pens[5 * 20 + 15]);
    try testing.expectEqual(@as(Pen, 0xFFFFFF00), pens[15 * 20 + 5]);
    try testing.expectEqual(@as(Pen, 0), pens[15 * 20 + 15]);

    // Polygons and polylines through AddSegments; a line stroked, not
    // filled.
    try rig.draw(
        \\<svg width="20" height="20">
        \\  <polygon points="0,0 20,0 0,20" fill="#ffffff"/>
        \\  <polyline points="20 20, 20 10 10 20" fill="#000"/>
        \\  <line x1="0" y1="19" x2="8" y2="19" stroke="#f00" stroke-width="2" fill="#0f0"/>
        \\</svg>
    , 20, 20, &pens);
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), pens[2 * 20 + 2]);
    try testing.expectEqual(@as(Pen, 0xFF000000), pens[18 * 20 + 18]);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[19 * 20 + 3]);
    try testing.expectEqual(@as(Pen, 0), pens[17 * 20 + 3]);
    try rig.close();
}

test "a group's opacity on a layer, a shape's in its paint, a filtered one not drawn" {
    const rig = try Rig.open();
    var pens: [10 * 10]Pen = undefined;
    try rig.draw(
        \\<svg width="10" height="10">
        \\  <g opacity="0.5" fill="#00f">
        \\    <rect width="6" height="6"/>
        \\    <rect x="4" y="4" width="6" height="6"/>
        \\  </g>
        \\  <rect x="8" width="2" height="2" fill="#f00" fill-opacity="0.5" filter="url(#blur)"/>
        \\</svg>
    , 10, 10, &pens);
    // Where the two overlap, no darker than where they do not.
    try testing.expectEqual(@as(Pen, 0x800000FF), pens[1 * 10 + 1]);
    try testing.expectEqual(@as(Pen, 0x800000FF), pens[5 * 10 + 5]);
    try testing.expectEqual(@as(Pen, 0), pens[1 * 10 + 9]);
    try rig.close();
}

test "gradients: chained by href, in the box's units and the user's, a missing one's fallback" {
    const rig = try Rig.open();
    var pens: [16 * 4]Pen = undefined;
    try rig.draw(
        \\<svg width="16" height="4" xmlns:xlink="http://www.w3.org/1999/xlink">
        \\  <defs>
        \\    <linearGradient id="stops"><stop offset="0" stop-color="#000"/><stop offset="1" style="stop-color:#fff"/></linearGradient>
        \\    <linearGradient id="across" xlink:href="#stops"/>
        \\    <linearGradient id="user" href="#across" gradientUnits="userSpaceOnUse" x1="8" x2="16"/>
        \\  </defs>
        \\  <rect width="8" height="2" fill="url(#across)"/>
        \\  <rect x="8" width="8" height="2" fill="url(#user)"/>
        \\  <rect y="2" width="8" height="2" fill="url(#gone) #f00"/>
        \\  <rect x="8" y="2" width="8" height="2" fill="url(#gone)"/>
        \\</svg>
    , 16, 4, &pens);
    // The box's 8 pixels black to white: the first nearly black, the last
    // nearly white; the user's the same over x 8 to 16.
    const first = pens[0] & 0xFF;
    const last = pens[7] & 0xFF;
    try testing.expect(first < 0x20 and last > 0xE0);
    try testing.expectEqual(pens[0], pens[8]);
    try testing.expectEqual(pens[7], pens[15]);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[2 * 16 + 3]);
    try testing.expectEqual(@as(Pen, 0), pens[2 * 16 + 12]);
    try rig.close();
}

test "the disk's test picture draws, its sky blue at the top and the house's wall light" {
    const rig = try Rig.open();
    const text = @embedFile("../../../../tests/datatypes/Drawing.svg");
    const size = try intrinsicOf(text);
    try testing.expectEqual([2]u32{ 320, 240 }, drawing.fullSize(size));
    // Drawn at half its size, which is the viewBox's.
    var pens: [160 * 120]Pen = undefined;
    try rig.draw(text, 160, 120, &pens);
    const sky = pens[2 * 160 + 2];
    try testing.expect(sky >> 24 == 0xFF and (sky & 0xFF) > ((sky >> 16) & 0xFF));
    const wall = pens[(52 + 20) * 160 + 24];
    try testing.expect((wall & 0xFF) > 0xD0 and ((wall >> 16) & 0xFF) > 0xD0);
    // A window, the wall's even-odd hole: the sky behind it shows.
    const window = pens[(52 + 28) * 160 + 32];
    try testing.expect((window & 0xFF) > ((window >> 16) & 0xFF));
    try rig.close();
}

// --- since 1.2 -------------------------------------------------------------------

test "clipPath: one shape, its clip-rule, two shapes as one, the box's units, a missing one" {
    const rig = try Rig.open();
    var pens: [20 * 20]Pen = undefined;
    try rig.draw(
        \\<svg width="20" height="20">
        \\  <clipPath id="left"><rect width="10" height="20"/></clipPath>
        \\  <clipPath id="ring" clip-rule="evenodd"><path d="M0 0H20V20H0Z M5 5H15V15H5Z"/></clipPath>
        \\  <clipPath id="two"><rect width="5" height="5"/><rect x="15" y="15" width="5" height="5"/></clipPath>
        \\  <clipPath id="half" clipPathUnits="objectBoundingBox"><rect width="1" height="0.5"/></clipPath>
        \\  <rect width="20" height="10" fill="#f00" clip-path="url(#left)"/>
        \\  <g clip-path="url(#ring)"><rect y="10" width="20" height="10" fill="#00f"/></g>
        \\</svg>
    , 20, 20, &pens);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[5 * 20 + 2]);
    try testing.expectEqual(@as(Pen, 0), pens[5 * 20 + 15]);
    try testing.expectEqual(@as(Pen, 0xFF0000FF), pens[18 * 20 + 10]);
    try testing.expectEqual(@as(Pen, 0), pens[12 * 20 + 10]);
    try rig.draw(
        \\<svg width="20" height="20">
        \\  <clipPath id="two"><rect width="5" height="5"/><rect x="15" y="15" width="5" height="5"/></clipPath>
        \\  <clipPath id="half" clipPathUnits="objectBoundingBox"><rect width="1" height="0.5"/></clipPath>
        \\  <g clip-path="url(#two)"><rect width="20" height="20" fill="#0f0"/></g>
        \\  <circle cx="10" cy="10" r="4" fill="#fff" clip-path="url(#half)"/>
        \\  <rect x="8" y="17" width="2" height="2" fill="#fff" clip-path="url(#gone)"/>
        \\</svg>
    , 20, 20, &pens);
    try testing.expectEqual(@as(Pen, 0xFF00FF00), pens[2 * 20 + 2]);
    try testing.expectEqual(@as(Pen, 0xFF00FF00), pens[17 * 20 + 17]);
    try testing.expectEqual(@as(Pen, 0), pens[2 * 20 + 17]);
    // The circle's top half, from 6 to 10.
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), pens[8 * 20 + 10]);
    try testing.expectEqual(@as(Pen, 0), pens[12 * 20 + 10]);
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), pens[18 * 20 + 9]);
    try rig.close();
}

test "mask: its luminance, mask-type alpha, its region, a group under it whole" {
    const rig = try Rig.open();
    var pens: [20 * 20]Pen = undefined;
    try rig.draw(
        \\<svg width="20" height="20">
        \\  <mask id="m" maskUnits="userSpaceOnUse" x="0" y="0" width="20" height="20">
        \\    <rect width="10" height="20" fill="#fff"/><rect x="10" width="10" height="20" fill="#808080"/>
        \\  </mask>
        \\  <mask id="a" style="mask-type:alpha"><rect width="20" height="20" fill="#000"/></mask>
        \\  <g mask="url(#m)">
        \\    <rect width="20" height="10" fill="#f00"/>
        \\    <rect y="5" width="20" height="5" fill="#00f"/>
        \\  </g>
        \\  <rect y="10" width="20" height="10" fill="#0f0" mask="url(#a)"/>
        \\</svg>
    , 20, 20, &pens);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[2 * 20 + 5]);
    try testing.expectEqual(@as(Pen, 0x80FF0000), pens[2 * 20 + 15]);
    // The blue over the red, the group put down whole: no red under it.
    try testing.expectEqual(@as(Pen, 0x800000FF), pens[7 * 20 + 15]);
    // By its coverage, black is all of it.
    try testing.expectEqual(@as(Pen, 0xFF00FF00), pens[15 * 20 + 5]);
    // The region by default: the box - of the shape, not its stroke - a
    // tenth more each way, 4 to 16 here; the stroke reaches 2 to 18 and
    // is cut at it.
    try rig.draw(
        \\<svg width="20" height="20">
        \\  <mask id="r"><rect x="-10" y="-10" width="40" height="40" fill="#fff"/></mask>
        \\  <rect x="5" y="5" width="10" height="10" fill="#fff" stroke="#00f" stroke-width="6" mask="url(#r)"/>
        \\</svg>
    , 20, 20, &pens);
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), pens[10 * 20 + 10]);
    try testing.expectEqual(@as(Pen, 0xFF0000FF), pens[10 * 20 + 4]);
    try testing.expectEqual(@as(Pen, 0), pens[10 * 20 + 3]);
    try testing.expectEqual(@as(Pen, 0), pens[10 * 20 + 17]);
    try rig.close();
}

test "use: moved by x and y, styled from the use, a symbol in its viewBox, one naming itself not drawn" {
    const rig = try Rig.open();
    var pens: [20 * 20]Pen = undefined;
    try rig.draw(
        \\<svg width="20" height="20" xmlns:xlink="http://www.w3.org/1999/xlink">
        \\  <defs>
        \\    <rect id="r" width="5" height="5"/>
        \\    <symbol id="s" viewBox="0 0 2 2"><rect width="1" height="1" fill="#0f0"/><rect x="1" y="1" width="3" height="3" fill="#f0f"/></symbol>
        \\    <g id="loop"><rect x="18" width="2" height="2" fill="#fff"/><use href="#loop" x="-4"/></g>
        \\  </defs>
        \\  <use xlink:href="#r" x="2" y="2" fill="#f00"/>
        \\  <use href="#s" x="10" y="10" width="10" height="10"/>
        \\  <use href="#loop"/>
        \\</svg>
    , 20, 20, &pens);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[4 * 20 + 4]);
    try testing.expectEqual(@as(Pen, 0), pens[1 * 20 + 1]);
    // The symbol's 2 by 2 drawn 10 by 10 at (10, 10): its first quarter
    // green, the rest of it magenta and cut at its edge.
    try testing.expectEqual(@as(Pen, 0xFF00FF00), pens[12 * 20 + 12]);
    try testing.expectEqual(@as(Pen, 0xFFFF00FF), pens[18 * 20 + 18]);
    // The group drawn once, the use inside it naming it not at all.
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), pens[1 * 20 + 19]);
    try testing.expectEqual(@as(Pen, 0), pens[1 * 20 + 15]);
    try rig.close();
}

test "a style element's rules: over the attributes, under the style attribute, the more specific last" {
    const rig = try Rig.open();
    var pens: [20 * 20]Pen = undefined;
    try rig.draw(
        \\<svg width="20" height="20">
        \\  <style><![CDATA[ .st0{fill:#00f} rect.st0.big{fill:#0f0} #me{fill:#fff} .gone{display:none} ]]></style>
        \\  <rect width="10" height="10" class="st0" fill="#f00"/>
        \\  <rect x="10" width="10" height="10" class="big st0"/>
        \\  <rect y="10" width="10" height="10" class="big st0" id="me" style="fill:#ff0"/>
        \\  <rect x="10" y="10" width="10" height="10" id="me" class="st0"/>
        \\  <rect width="20" height="20" class="gone"/>
        \\</svg>
    , 20, 20, &pens);
    try testing.expectEqual(@as(Pen, 0xFF0000FF), pens[5 * 20 + 5]);
    try testing.expectEqual(@as(Pen, 0xFF00FF00), pens[5 * 20 + 15]);
    try testing.expectEqual(@as(Pen, 0xFFFFFF00), pens[15 * 20 + 5]);
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), pens[15 * 20 + 15]);
    try rig.close();
}

test "a nested svg clips what it draws to its viewport, unless its overflow is visible" {
    const rig = try Rig.open();
    var pens: [20 * 20]Pen = undefined;
    try rig.draw(
        \\<svg width="20" height="20">
        \\  <svg x="0" y="0" width="10" height="10"><rect width="20" height="10" fill="#f00"/></svg>
        \\  <svg x="0" y="10" width="10" height="10" overflow="visible"><rect width="20" height="10" fill="#00f"/></svg>
        \\</svg>
    , 20, 20, &pens);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[5 * 20 + 5]);
    try testing.expectEqual(@as(Pen, 0), pens[5 * 20 + 15]);
    try testing.expectEqual(@as(Pen, 0xFF0000FF), pens[15 * 20 + 15]);
    try rig.close();
}
