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
const truetype_init = @import("../../../../libs/truetype/truetype_init.zig");
const truetype_tests = @import("../../../../libs/truetype/tests/truetype.zig");
const shaping_init = @import("../../../../libs/truetypeshaping/truetypeshaping_init.zig");
const document = @import("../document.zig");
const drawing = @import("../draw.zig");
const data = @import("../data.zig");
const truetype = sdk.truetype;
const tts = sdk.truetypeshaping;
const diskfont = sdk.diskfont;

const testing = std.testing;
const VectorBase = sdk.interface.vector.VectorBase;
const TrueTypeBase = sdk.interface.truetype.TrueTypeBase;
const TrueTypeShapingBase = sdk.interface.truetypeshaping.TrueTypeShapingBase;

test {
    _ = @import("../xml.zig");
    _ = @import("../values.zig");
    _ = @import("../css.zig");
    _ = @import("../filter.zig");
    _ = @import("../text.zig");
    _ = data;
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

    /// `text` drawn `width` by `height` onto `pens`, cleared first, with
    /// no fonts and no pictures.
    fn draw(rig: Rig, text: []const u8, width: u32, height: u32, pens: []Pen) !void {
        var without = drawing.Without{};
        try rig.drawWith(&without, text, width, height, pens);
    }

    fn drawWith(rig: Rig, ext: anytype, text: []const u8, width: u32, height: u32, pens: []Pen) !void {
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
        drawing.draw(rig.vb, ext, &doc, canvas, rig.path, work, drawing.baseMatrix(size, width, height), size.viewport);
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

test "a group's opacity on a layer, a shape's in its paint, one of a filter not there drawn as it is" {
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
    try testing.expectEqual(@as(Pen, 0x80FF0000), pens[1 * 10 + 9]);
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

/// Fonts and pictures for the tests: truetype.library and
/// truetypeshaping.library made from their ROM tags, with
/// utility.library, which truetype's init opens; truetype's test font
/// as "sans.font" - every other family missing - and a picture's bytes
/// taken as its pens, two by two, A, R, G, B.
const Sources = struct {
    library: *exec.Library,
    tb: *TrueTypeBase,
    shaping_library: *exec.Library = undefined,
    sb: *TrueTypeShapingBase = undefined,
    utility_library: *exec.Library = undefined,
    font: truetype_tests.Out = .{},
    face: diskfont.OutlineFont = undefined,
    opened: u32 = 0,
    asked: [8][32]u8 = undefined,
    asked_count: u32 = 0,
    pens: [4]Pen = undefined,
    /// For a glyph the work block is too short for: `tight` says every
    /// outline is one, `no_room` that there is no memory for it; how
    /// often room was given, and how much of it is still out.
    tight: bool = false,
    no_room: bool = false,
    rooms: u32 = 0,
    rooms_out: u32 = 0,

    fn open(s: *Sources) !void {
        const sys = kexec.SysBase.iface();
        const utility_made = kexec.InitResident(kexec.SysBase, &host.utility.utility_library_tag, null) orelse return error.NoUtility;
        s.utility_library = @ptrCast(@alignCast(utility_made));
        const made = kexec.InitResident(kexec.SysBase, &truetype_init.truetype_library_tag, null) orelse return error.NoLibrary;
        s.library = @ptrCast(@alignCast(made));
        s.tb = @ptrCast(sys.OpenLibrary(truetype.TRUETYPENAME, 1) orelse return error.NoBase);
        const shaping_made = kexec.InitResident(kexec.SysBase, &shaping_init.truetypeshaping_library_tag, null) orelse return error.NoLibrary;
        s.shaping_library = @ptrCast(@alignCast(shaping_made));
        s.sb = @ptrCast(sys.OpenLibrary(tts.TRUETYPESHAPINGNAME, 1) orelse return error.NoBase);
        truetype_tests.buildFont(&s.font);
        s.face = .{ .outline = s.tb.OpenOutline(&s.font.bytes, s.font.len, null) orelse return error.NotRead, .style = sdk.graphics.FS_NORMAL };
    }

    fn close(s: *Sources) void {
        const sys = kexec.SysBase.iface();
        s.tb.CloseOutline(s.face.outline);
        sys.CloseLibrary(s.sb.lib());
        _ = sys.RemLibrary(s.shaping_library);
        sys.CloseLibrary(s.tb.lib());
        _ = sys.RemLibrary(s.library);
        host.utility.freeForTests(@ptrCast(@alignCast(s.utility_library)));
    }

    fn wasAsked(s: *const Sources, name: []const u8) bool {
        for (s.asked[0..s.asked_count]) |*a| if (std.mem.eql(u8, std.mem.sliceTo(a, 0), name)) return true;
        return false;
    }

    pub fn OpenFace(s: *Sources, name: [*:0]const u8, _: sdk.graphics.FontStyle) ?*diskfont.OutlineFont {
        const n = std.mem.span(name);
        if (s.asked_count < s.asked.len and n.len < 32) {
            @memset(&s.asked[s.asked_count], 0);
            @memcpy(s.asked[s.asked_count][0..n.len], n);
            s.asked_count += 1;
        }
        if (!std.mem.eql(u8, n, "sans.font")) return null;
        s.opened += 1;
        return &s.face;
    }
    pub fn CloseFace(s: *Sources, _: *diskfont.OutlineFont) void {
        s.opened -= 1;
    }
    pub fn ShapeText(s: *Sources, outline: *truetype.Outline, text: []const u8, features: ?[*]const tts.Feature, run: *tts.ShapedRun) i32 {
        return s.sb.ShapeText(outline, text.ptr, @intCast(text.len), tts.TTS_LEFT_TO_RIGHT, tts.TTS_LANGUAGE_DEFAULT, features, run);
    }
    pub fn GlyphMetrics(s: *Sources, outline: *truetype.Outline, glyph: u32, metrics: *truetype.GlyphMetrics) bool {
        return s.tb.GlyphMetrics(outline, glyph, metrics);
    }
    pub fn GlyphSegments(s: *Sources, outline: *truetype.Outline, glyph: u32, segments: *truetype.Segments) i32 {
        if (s.tight and segments.verb_room == drawing.glyph_verbs and segments.point_room == drawing.glyph_points) {
            // The work block, taken as too short for any outline: the
            // library is asked with no room, and says what it needs.
            var none = truetype.Segments{ .verbs = segments.verbs, .points = segments.points, .verb_room = 0, .point_room = 0 };
            const result = s.tb.GlyphSegments(outline, glyph, &none);
            segments.verb_count = none.verb_count;
            segments.point_count = none.point_count;
            return result;
        }
        return s.tb.GlyphSegments(outline, glyph, segments);
    }
    pub fn AllocRoom(s: *Sources, bytes: usize) ?drawing.Room {
        if (s.no_room) return null;
        const memory = kexec.SysBase.iface().AllocVec(bytes, exec.MEMF_ANY) orelse return null;
        s.rooms += 1;
        s.rooms_out += 1;
        const room: [*]align(@alignOf(vector.Point)) u8 = @ptrCast(@alignCast(memory));
        return room[0..bytes];
    }
    pub fn FreeRoom(s: *Sources, room: drawing.Room) void {
        s.rooms_out -= 1;
        kexec.SysBase.iface().FreeVec(room.ptr);
    }
    pub fn FontMetrics(s: *Sources, outline: *truetype.Outline, metrics: *truetype.FontMetrics) void {
        s.tb.FontMetrics(outline, metrics);
    }
    pub fn OpenImage(s: *Sources, href: []const u8) ?drawing.Image {
        const text = data.base64Of(href) orelse return null;
        var bytes: [32]u8 = undefined;
        if (data.decodedMost(text) > bytes.len) return null;
        const got = data.decode(text, bytes[0..data.decodedMost(text)]) orelse return null;
        if (got.len != 16) return null;
        for (&s.pens, 0..) |*pen, i| pen.* = std.mem.readInt(u32, got[i * 4 ..][0..4], .big);
        return .{ .pens = &s.pens, .width = 2, .height = 2, .bytes_per_row = 8 };
    }
    pub fn CloseImage(_: *Sources, _: drawing.Image) void {}
};

fn alphaOf(pen: Pen) u32 {
    return pen >> 24;
}

test "text: laid out in its font, kerned, a span moved and coloured, anchored, underlined; a family not there in sans" {
    const rig = try Rig.open();
    var sources: Sources = .{ .library = undefined, .tb = undefined };
    try sources.open();
    var pens: [40 * 40]Pen = undefined;
    // The test font is 1000 units: at 10 pixels, 'A' a square 5 wide and
    // 7 high on the baseline, 'B' 0.5 closer, 'C' the square 1 right.
    try rig.drawWith(&sources,
        \\<svg width="40" height="40">
        \\  <text x="2" y="15" font-family="Helvetica, sans-serif" font-size="10" fill="#f00">AB<tspan dx="1" fill="#00f">C</tspan></text>
        \\  <text x="20" y="35" font-size="10px" text-anchor="middle" style="text-decoration: underline" fill="#0f0">A</text>
        \\</svg>
    , 40, 40, &pens);
    // 'A' from 2 to 7, 8 to 15; nothing above it.
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[12 * 40 + 4]);
    try testing.expectEqual(@as(Pen, 0), pens[6 * 40 + 4]);
    // 'B' kerned: from 7.5, so the pixel at 7 is half covered.
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[12 * 40 + 10]);
    try testing.expect(alphaOf(pens[12 * 40 + 7]) > 0x60 and alphaOf(pens[12 * 40 + 7]) < 0xA0);
    // 'C' after 'B''s advance and 1 more: its square from 15.5.
    try testing.expectEqual(@as(Pen, 0xFF0000FF), pens[12 * 40 + 17]);
    try testing.expectEqual(@as(Pen, 0), pens[12 * 40 + 14]);
    // Anchored in the middle: an advance of 6 round 20, the square 17 to 22.
    try testing.expectEqual(@as(Pen, 0xFF00FF00), pens[32 * 40 + 18]);
    try testing.expectEqual(@as(Pen, 0), pens[32 * 40 + 16]);
    try testing.expectEqual(@as(Pen, 0), pens[32 * 40 + 23]);
    // Underlined a tenth of the size down, as most fonts are.
    try testing.expect(alphaOf(pens[36 * 40 + 18]) > 0);
    try testing.expectEqual(@as(Pen, 0), pens[38 * 40 + 18]);
    // Struck through 0.3 of the size up, over the glyph: no hole where
    // the two cross, whichever way each is wound.
    try rig.drawWith(&sources,
        \\<svg width="20" height="20"><text x="2" y="15" font-size="10" fill="#f00" text-decoration="line-through">A</text></svg>
    , 20, 20, pens[0 .. 20 * 20]);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[12 * 20 + 4]);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[11 * 20 + 4]);
    // Helvetica is not on the disk, nor is the serif text without a
    // family is in: both drawn in sans.
    try testing.expect(sources.wasAsked("serif.font"));
    try testing.expect(!sources.wasAsked("go.font"));
    try testing.expectEqual(@as(u32, 0), sources.opened);
    sources.close();
    try rig.close();
}

test "text: a glyph the work block is too short for is read into room of its own, and left out without it" {
    const rig = try Rig.open();
    var sources: Sources = .{ .library = undefined, .tb = undefined };
    try sources.open();
    const picture =
        \\<svg width="40" height="40">
        \\  <rect x="30" y="30" width="10" height="10" fill="#0f0"/>
        \\  <text x="2" y="15" font-size="10" fill="#f00" stroke="#00f" stroke-width="0.5">AB<tspan dx="1" fill="#00f">C</tspan> A</text>
        \\</svg>
    ;
    var fits: [40 * 40]Pen = undefined;
    try rig.drawWith(&sources, picture, 40, 40, &fits);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), fits[12 * 40 + 4]);
    try testing.expectEqual(@as(u32, 0), sources.rooms);
    // Every outline too long for the block: the same picture, each of
    // the four glyphs with an outline in room of its own, the space in
    // none, and all of it given back.
    sources.tight = true;
    var pens: [40 * 40]Pen = undefined;
    try rig.drawWith(&sources, picture, 40, 40, &pens);
    try testing.expectEqualSlices(Pen, &fits, &pens);
    try testing.expectEqual(@as(u32, 4), sources.rooms);
    try testing.expectEqual(@as(u32, 0), sources.rooms_out);
    // No memory for it: the glyphs are left out, the rest is drawn.
    sources.no_room = true;
    try rig.drawWith(&sources, picture, 40, 40, &pens);
    try testing.expectEqual(@as(Pen, 0xFF00FF00), pens[35 * 40 + 35]);
    for (pens[0 .. 30 * 40]) |pen| try testing.expectEqual(@as(Pen, 0), pen);
    try testing.expectEqual(@as(u32, 4), sources.rooms);
    try testing.expectEqual(@as(u32, 0), sources.opened);
    sources.close();
    try rig.close();
}

test "text: shaped across its spans, each glyph in its span's colour; letter spacing behind each" {
    const rig = try Rig.open();
    var sources: Sources = .{ .library = undefined, .tb = undefined };
    try sources.open();
    var pens: [40 * 40]Pen = undefined;
    try rig.drawWith(&sources,
        \\<svg width="40" height="40">
        \\  <text x="2" y="15" font-size="10" fill="#f00">A<tspan fill="#00f">B</tspan></text>
        \\  <text x="2" y="35" font-size="10" fill="#f00" letter-spacing="2">AB</text>
        \\</svg>
    , 40, 40, &pens);
    // 'A' from 2 to 7 in red; 'B' in the span's blue and kerned to the
    // 'A' before the span: from 7.5, the pixel at 7 half covered.
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[12 * 40 + 4]);
    try testing.expectEqual(@as(Pen, 0xFF0000FF), pens[12 * 40 + 10]);
    try testing.expect(alphaOf(pens[12 * 40 + 7]) > 0x60 and alphaOf(pens[12 * 40 + 7]) < 0xA0);
    try testing.expectEqual(@as(u32, 0xFF), pens[12 * 40 + 7] & 0xFF);
    // Spaced by 2: 'B' kerned still, from 9.5.
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[32 * 40 + 4]);
    try testing.expectEqual(@as(Pen, 0), pens[32 * 40 + 8]);
    try testing.expect(alphaOf(pens[32 * 40 + 9]) > 0x60 and alphaOf(pens[32 * 40 + 9]) < 0xA0);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[32 * 40 + 11]);
    sources.close();
    try rig.close();
}

test "text without fonts is left out, and the rest drawn" {
    const rig = try Rig.open();
    var pens: [10 * 10]Pen = undefined;
    try rig.draw("<svg width='10' height='10'><text x='0' y='8'>AB</text><rect width='2' height='2' fill='#f00'/></svg>", 10, 10, &pens);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[0]);
    try testing.expectEqual(@as(Pen, 0), pens[5 * 10 + 5]);
    try rig.close();
}

test "filters: a blur spread round, held to its region; one of nothing not drawn; one it cannot make drawn as it is" {
    const rig = try Rig.open();
    var pens: [20 * 20]Pen = undefined;
    try rig.draw(
        \\<svg width="20" height="20">
        \\  <filter id="b"><feGaussianBlur stdDeviation="2"/></filter>
        \\  <filter id="nothing"/>
        \\  <filter id="shadow"><feOffset dx="1"/></filter>
        \\  <rect x="8" y="8" width="4" height="4" fill="#f00" filter="url(#b)"/>
        \\  <rect width="2" height="2" fill="#0f0" filter="url(#nothing)"/>
        \\  <rect x="18" width="2" height="2" fill="#00f" filter="url(#shadow)"/>
        \\</svg>
    , 20, 20, &pens);
    // Blurred: the middle about a half, as a Gaussian has it, the
    // pixel past its edge touched, its colour kept.
    try testing.expect(alphaOf(pens[10 * 20 + 10]) < 0xC0 and alphaOf(pens[10 * 20 + 10]) > 0x40);
    try testing.expect(alphaOf(pens[10 * 20 + 7]) > 0);
    try testing.expectEqual(@as(u32, 0xFF0000), pens[10 * 20 + 7] & 0xFFFFFF);
    // The region, a tenth of its box more each way, 7.6 to 12.4: what the
    // blur would reach past it is cut.
    try testing.expectEqual(@as(Pen, 0), pens[10 * 20 + 6]);
    try testing.expectEqual(@as(Pen, 0), pens[10 * 20 + 13]);
    try testing.expectEqual(@as(Pen, 0), pens[0]);
    try testing.expectEqual(@as(Pen, 0xFF0000FF), pens[19]);
    try rig.close();
}

test "image: a data: picture in its place, scaled, its shape kept in a place of another" {
    const rig = try Rig.open();
    var sources: Sources = .{ .library = undefined, .tb = undefined };
    try sources.open();
    var pens: [20 * 20]Pen = undefined;
    // Red, green; blue, white.
    try rig.drawWith(&sources,
        \\<svg width="20" height="20">
        \\  <image x="2" y="2" width="4" height="4" href="data:image/x-pens;base64,//8AAP8A/wD/AAD//////w=="/>
        \\  <image x="0" y="10" width="8" height="4" xlink:href="data:;base64, //8AAP8A/wD/AA
        \\       D//////w=="/>
        \\  <image x="10" y="2" width="4" height="4" href="picture.png"/>
        \\</svg>
    , 20, 20, &pens);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[2 * 20 + 2]);
    try testing.expectEqual(@as(Pen, 0xFF00FF00), pens[2 * 20 + 5]);
    try testing.expectEqual(@as(Pen, 0xFF0000FF), pens[5 * 20 + 2]);
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), pens[5 * 20 + 5]);
    try testing.expectEqual(@as(Pen, 0), pens[2 * 20 + 7]);
    // Twice as wide as high: drawn 4 by 4 in the middle, 2 to 6.
    try testing.expectEqual(@as(Pen, 0), pens[12 * 20 + 1]);
    try testing.expect(alphaOf(pens[12 * 20 + 3]) == 255);
    try testing.expectEqual(@as(Pen, 0), pens[12 * 20 + 6]);
    // An address of a file: not followed.
    try testing.expectEqual(@as(Pen, 0), pens[3 * 20 + 11]);
    sources.close();
    try rig.close();
}

test "paint-order: the stroke under the fill, as it names it; the fill first otherwise" {
    const rig = try Rig.open();
    var pens: [20 * 10]Pen = undefined;
    try rig.draw(
        \\<svg width="20" height="10">
        \\  <g paint-order="stroke fill markers"><rect x="2" y="2" width="6" height="6" fill="#0f0" stroke="#f00" stroke-width="2"/></g>
        \\  <rect x="12" y="2" width="6" height="6" fill="#0f0" stroke="#f00" stroke-width="2" style="paint-order: markers"/>
        \\</svg>
    , 20, 10, &pens);
    // Just inside the edge: the fill over the stroke, then the stroke
    // over the fill; just outside, the stroke both times.
    try testing.expectEqual(@as(Pen, 0xFF00FF00), pens[5 * 20 + 2]);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[5 * 20 + 12]);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[5 * 20 + 1]);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[5 * 20 + 11]);
    try rig.close();
}
