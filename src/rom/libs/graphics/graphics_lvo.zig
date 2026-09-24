// SPDX-License-Identifier: MPL-2.0
//! graphics.library's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.
//!
//! Each wrapper is the slot a caller reaches through the table. It hands
//! the work to the call - a file of its own in the folder for its
//! category - with the library's base first.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const vec = exec.vec;
const graphics_base = @import("graphics_base.zig");
const GraphicsBase = graphics_base.GraphicsBase;

const CreateRastPortTagList = @import("rastport/createrastporttaglist.zig").CreateRastPortTagList;
const FreeRastPort = @import("rastport/freerastport.zig").FreeRastPort;
const RectFill = @import("draw/rectfill.zig").RectFill;
const SetRPAttrs = @import("rastport/setrpattrs.zig").SetRPAttrs;
const GetRPAttrs = @import("rastport/getrpattrs.zig").GetRPAttrs;
const AllocBitMapTagList = @import("bitmap/allocbitmaptaglist.zig").AllocBitMapTagList;
const FreeBitMap = @import("bitmap/freebitmap.zig").FreeBitMap;
const BltRastPort = @import("blit/bltrastport.zig").BltRastPort;
const Move = @import("draw/move.zig").Move;
const Draw = @import("draw/draw.zig").Draw;
const WritePixel = @import("draw/writepixel.zig").WritePixel;
const ReadPixel = @import("draw/readpixel.zig").ReadPixel;
const DrawHLine = @import("draw/drawhline.zig").DrawHLine;
const DrawVLine = @import("draw/drawvline.zig").DrawVLine;
const DrawRect = @import("draw/drawrect.zig").DrawRect;
const DrawCircle = @import("draw/drawcircle.zig").DrawCircle;
const DrawEllipse = @import("draw/drawellipse.zig").DrawEllipse;
const DrawArc = @import("draw/drawarc.zig").DrawArc;
const DrawPoly = @import("draw/drawpoly.zig").DrawPoly;
const InitArea = @import("area/initarea.zig").InitArea;
const AreaMove = @import("area/areamove.zig").AreaMove;
const AreaDraw = @import("area/areadraw.zig").AreaDraw;
const AreaEllipse = @import("area/areaellipse.zig").AreaEllipse;
const AreaCircle = @import("area/areacircle.zig").AreaCircle;
const AreaArc = @import("area/areaarc.zig").AreaArc;
const AreaEnd = @import("area/areaend.zig").AreaEnd;
const OpenFont = @import("text/openfont.zig").OpenFont;
const CloseFont = @import("text/closefont.zig").CloseFont;
const Text = @import("text/text.zig").Text;
const TextLength = @import("text/textlength.zig").TextLength;
const BltTemplate = @import("blit/blttemplate.zig").BltTemplate;
const BltPattern = @import("blit/bltpattern.zig").BltPattern;
const BltMaskRastPort = @import("blit/bltmaskrastport.zig").BltMaskRastPort;
const BltBitMap = @import("blit/bltbitmap.zig").BltBitMap;
const BltBitMapRastPort = @import("blit/bltbitmaprastport.zig").BltBitMapRastPort;
const BltMaskBitMapRastPort = @import("blit/bltmaskbitmaprastport.zig").BltMaskBitMapRastPort;
const BitMapScale = @import("blit/bitmapscale.zig").BitMapScale;
const TextExtent = @import("text/textextent.zig").TextExtent;
const TextFit = @import("text/textfit.zig").TextFit;
const AddFont = @import("text/addfont.zig").AddFont;
const RemFont = @import("text/remfont.zig").RemFont;
const FontExtent = @import("text/fontextent.zig").FontExtent;
const AskSoftStyle = @import("text/asksoftstyle.zig").AskSoftStyle;
const SetSoftStyle = @import("text/setsoftstyle.zig").SetSoftStyle;
const GraphicsErrorText = @import("errors/graphicserrortext.zig").GraphicsErrorText;
const NewRegion = @import("region/newregion.zig").NewRegion;
const DisposeRegion = @import("region/disposeregion.zig").DisposeRegion;
const ClearRegion = @import("region/clearregion.zig").ClearRegion;
const PointInRegion = @import("region/pointinregion.zig").PointInRegion;
const OffsetRegion = @import("region/offsetregion.zig").OffsetRegion;
const OrRectRegion = @import("region/orrectregion.zig").OrRectRegion;
const AndRectRegion = @import("region/andrectregion.zig").AndRectRegion;
const ClearRectRegion = @import("region/clearrectregion.zig").ClearRectRegion;
const XorRectRegion = @import("region/xorrectregion.zig").XorRectRegion;
const OrRegionRegion = @import("region/orregionregion.zig").OrRegionRegion;
const AndRegionRegion = @import("region/andregionregion.zig").AndRegionRegion;
const SubRegionRegion = @import("region/subregionregion.zig").SubRegionRegion;
const XorRegionRegion = @import("region/xorregionregion.zig").XorRegionRegion;
const RegionRectangles = @import("region/regionrectangles.zig").RegionRectangles;
const ScrollRaster = @import("blit/scrollraster.zig").ScrollRaster;
const EraseRect = @import("rastport/eraserect.zig").EraseRect;
const WritePixelArray = @import("blit/writepixelarray.zig").WritePixelArray;
const WriteLUTPixelArray = @import("blit/writelutpixelarray.zig").WriteLUTPixelArray;
const BeginDraw = @import("draw/begindraw.zig").BeginDraw;
const EndDraw = @import("draw/enddraw.zig").EndDraw;

/// graphics.library's interface, as the SDK generates it from
/// sdk/fd/graphics_lib.fd.
const interface = sdk.interface.graphics;
const LVO = interface.LVO;

// Every function in LVO is an lvo* function here, with the SDK's signature
// (after the base), in its slot.
comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("graphics.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(50_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "graphics.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`: every
/// call of the table.
const contract_files = [_][]const u8{
    @embedFile("rastport/createrastporttaglist.zig"),
    @embedFile("rastport/freerastport.zig"),
    @embedFile("draw/rectfill.zig"),
    @embedFile("rastport/setrpattrs.zig"),
    @embedFile("rastport/getrpattrs.zig"),
    @embedFile("bitmap/allocbitmaptaglist.zig"),
    @embedFile("bitmap/freebitmap.zig"),
    @embedFile("blit/bltrastport.zig"),
    @embedFile("draw/move.zig"),
    @embedFile("draw/draw.zig"),
    @embedFile("draw/writepixel.zig"),
    @embedFile("draw/readpixel.zig"),
    @embedFile("draw/drawhline.zig"),
    @embedFile("draw/drawvline.zig"),
    @embedFile("draw/drawrect.zig"),
    @embedFile("draw/drawcircle.zig"),
    @embedFile("draw/drawellipse.zig"),
    @embedFile("draw/drawarc.zig"),
    @embedFile("draw/drawpoly.zig"),
    @embedFile("area/initarea.zig"),
    @embedFile("area/areamove.zig"),
    @embedFile("area/areadraw.zig"),
    @embedFile("area/areaellipse.zig"),
    @embedFile("area/areacircle.zig"),
    @embedFile("area/areaarc.zig"),
    @embedFile("area/areaend.zig"),
    @embedFile("text/openfont.zig"),
    @embedFile("text/closefont.zig"),
    @embedFile("text/text.zig"),
    @embedFile("text/textlength.zig"),
    @embedFile("blit/blttemplate.zig"),
    @embedFile("blit/writepixelarray.zig"),
    @embedFile("blit/writelutpixelarray.zig"),
    @embedFile("blit/bltpattern.zig"),
    @embedFile("blit/bltmaskrastport.zig"),
    @embedFile("blit/bltbitmap.zig"),
    @embedFile("blit/bltbitmaprastport.zig"),
    @embedFile("blit/bltmaskbitmaprastport.zig"),
    @embedFile("blit/bitmapscale.zig"),
    @embedFile("text/textextent.zig"),
    @embedFile("text/textfit.zig"),
    @embedFile("text/addfont.zig"),
    @embedFile("text/remfont.zig"),
    @embedFile("text/fontextent.zig"),
    @embedFile("text/asksoftstyle.zig"),
    @embedFile("text/setsoftstyle.zig"),
    @embedFile("errors/graphicserrortext.zig"),
    @embedFile("region/newregion.zig"),
    @embedFile("region/disposeregion.zig"),
    @embedFile("region/clearregion.zig"),
    @embedFile("region/pointinregion.zig"),
    @embedFile("region/offsetregion.zig"),
    @embedFile("region/orrectregion.zig"),
    @embedFile("region/andrectregion.zig"),
    @embedFile("region/clearrectregion.zig"),
    @embedFile("region/xorrectregion.zig"),
    @embedFile("region/orregionregion.zig"),
    @embedFile("region/andregionregion.zig"),
    @embedFile("region/subregionregion.zig"),
    @embedFile("region/xorregionregion.zig"),
    @embedFile("region/regionrectangles.zig"),
    @embedFile("blit/scrollraster.zig"),
    @embedFile("rastport/eraserect.zig"),
};

fn lvoCreateRastPortTagList(gb: *GraphicsBase, tags: ?[*]const TagItem) callconv(.c) ?*graphics.RastPort {
    return @ptrCast(CreateRastPortTagList(gb, tags));
}
fn lvoFreeRastPort(gb: *GraphicsBase, rp: ?*graphics.RastPort) callconv(.c) void {
    FreeRastPort(gb, @ptrCast(@alignCast(rp)));
}
fn lvoRectFill(gb: *GraphicsBase, rp: *graphics.RastPort, area: *const graphics.Rect) callconv(.c) void {
    RectFill(gb, @ptrCast(@alignCast(rp)), area);
}
fn lvoSetRPAttrs(gb: *GraphicsBase, rp: *graphics.RastPort, tags: ?[*]const TagItem) callconv(.c) void {
    SetRPAttrs(gb, @ptrCast(@alignCast(rp)), tags);
}
fn lvoGetRPAttrs(gb: *GraphicsBase, rp: *graphics.RastPort, tags: ?[*]const TagItem) callconv(.c) void {
    GetRPAttrs(gb, @ptrCast(@alignCast(rp)), tags);
}
fn lvoAllocBitMapTagList(gb: *GraphicsBase, tags: ?[*]const TagItem) callconv(.c) ?*rtg.Surface {
    return @ptrCast(AllocBitMapTagList(gb, tags));
}
fn lvoFreeBitMap(gb: *GraphicsBase, bitmap: ?*rtg.Surface) callconv(.c) void {
    FreeBitMap(gb, @ptrCast(@alignCast(bitmap)));
}
fn lvoBltRastPort(gb: *GraphicsBase, src: *graphics.RastPort, dest: *graphics.RastPort, area: *const graphics.Rect, dest_x: i32, dest_y: i32) callconv(.c) void {
    BltRastPort(gb, @ptrCast(@alignCast(src)), @ptrCast(@alignCast(dest)), area, dest_x, dest_y);
}
fn lvoMove(gb: *GraphicsBase, rp: *graphics.RastPort, x: i32, y: i32) callconv(.c) void {
    Move(gb, @ptrCast(@alignCast(rp)), x, y);
}
fn lvoDraw(gb: *GraphicsBase, rp: *graphics.RastPort, x: i32, y: i32) callconv(.c) void {
    Draw(gb, @ptrCast(@alignCast(rp)), x, y);
}
fn lvoWritePixel(gb: *GraphicsBase, rp: *graphics.RastPort, x: i32, y: i32) callconv(.c) void {
    WritePixel(gb, @ptrCast(@alignCast(rp)), x, y);
}
fn lvoReadPixel(gb: *GraphicsBase, rp: *graphics.RastPort, x: i32, y: i32, out: *graphics.Pen) callconv(.c) bool {
    return ReadPixel(gb, @ptrCast(@alignCast(rp)), x, y, out);
}
fn lvoDrawHLine(gb: *GraphicsBase, rp: *graphics.RastPort, x: i32, y: i32, length: i32) callconv(.c) void {
    DrawHLine(gb, @ptrCast(@alignCast(rp)), x, y, length);
}
fn lvoDrawVLine(gb: *GraphicsBase, rp: *graphics.RastPort, x: i32, y: i32, length: i32) callconv(.c) void {
    DrawVLine(gb, @ptrCast(@alignCast(rp)), x, y, length);
}
fn lvoDrawRect(gb: *GraphicsBase, rp: *graphics.RastPort, area: *const graphics.Rect) callconv(.c) void {
    DrawRect(gb, @ptrCast(@alignCast(rp)), area);
}
fn lvoDrawCircle(gb: *GraphicsBase, rp: *graphics.RastPort, cx: i32, cy: i32, radius: i32) callconv(.c) void {
    DrawCircle(gb, @ptrCast(@alignCast(rp)), cx, cy, radius);
}
fn lvoDrawEllipse(gb: *GraphicsBase, rp: *graphics.RastPort, cx: i32, cy: i32, rx: i32, ry: i32) callconv(.c) void {
    DrawEllipse(gb, @ptrCast(@alignCast(rp)), cx, cy, rx, ry);
}
fn lvoDrawArc(gb: *GraphicsBase, rp: *graphics.RastPort, cx: i32, cy: i32, radius: i32, from: i32, to: i32) callconv(.c) void {
    DrawArc(gb, @ptrCast(@alignCast(rp)), cx, cy, radius, from, to);
}
fn lvoDrawPoly(gb: *GraphicsBase, rp: *graphics.RastPort, count: u32, points: [*]const graphics.Point) callconv(.c) void {
    DrawPoly(gb, @ptrCast(@alignCast(rp)), count, points);
}
fn lvoInitArea(gb: *GraphicsBase, rp: *graphics.RastPort, max_points: u32) callconv(.c) bool {
    return InitArea(gb, @ptrCast(@alignCast(rp)), max_points);
}
fn lvoAreaMove(gb: *GraphicsBase, rp: *graphics.RastPort, x: i32, y: i32) callconv(.c) bool {
    return AreaMove(gb, @ptrCast(@alignCast(rp)), x, y);
}
fn lvoAreaDraw(gb: *GraphicsBase, rp: *graphics.RastPort, x: i32, y: i32) callconv(.c) bool {
    return AreaDraw(gb, @ptrCast(@alignCast(rp)), x, y);
}
fn lvoAreaEllipse(gb: *GraphicsBase, rp: *graphics.RastPort, cx: i32, cy: i32, rx: i32, ry: i32) callconv(.c) bool {
    return AreaEllipse(gb, @ptrCast(@alignCast(rp)), cx, cy, rx, ry);
}
fn lvoAreaCircle(gb: *GraphicsBase, rp: *graphics.RastPort, cx: i32, cy: i32, radius: i32) callconv(.c) bool {
    return AreaCircle(gb, @ptrCast(@alignCast(rp)), cx, cy, radius);
}
fn lvoAreaArc(gb: *GraphicsBase, rp: *graphics.RastPort, cx: i32, cy: i32, radius: i32, from: i32, to: i32) callconv(.c) bool {
    return AreaArc(gb, @ptrCast(@alignCast(rp)), cx, cy, radius, from, to);
}
fn lvoAreaEnd(gb: *GraphicsBase, rp: *graphics.RastPort) callconv(.c) bool {
    return AreaEnd(gb, @ptrCast(@alignCast(rp)));
}
fn lvoOpenFont(gb: *GraphicsBase, name: [*:0]const u8, height: u32) callconv(.c) ?*graphics.TextFont {
    return @ptrCast(OpenFont(gb, name, height));
}
fn lvoCloseFont(gb: *GraphicsBase, font: ?*graphics.TextFont) callconv(.c) void {
    CloseFont(gb, @ptrCast(@alignCast(font)));
}
fn lvoText(gb: *GraphicsBase, rp: *graphics.RastPort, string: [*]const u8, count: u32) callconv(.c) void {
    Text(gb, @ptrCast(@alignCast(rp)), string, count);
}
fn lvoTextLength(gb: *GraphicsBase, rp: *graphics.RastPort, string: [*]const u8, count: u32) callconv(.c) i32 {
    return TextLength(gb, @ptrCast(@alignCast(rp)), string, count);
}
fn lvoBltTemplate(gb: *GraphicsBase, rp: *graphics.RastPort, bits: [*]const u8, pitch: u32, src_x: i32, src_y: i32, area: *const graphics.Rect) callconv(.c) void {
    BltTemplate(gb, @ptrCast(@alignCast(rp)), bits, pitch, src_x, src_y, area);
}
fn lvoBltPattern(gb: *GraphicsBase, rp: *graphics.RastPort, bits: [*]const u8, pitch: u32, width: u32, height: u32, area: *const graphics.Rect) callconv(.c) void {
    BltPattern(gb, @ptrCast(@alignCast(rp)), bits, pitch, width, height, area);
}
fn lvoBltMaskRastPort(gb: *GraphicsBase, src: *graphics.RastPort, dest: *graphics.RastPort, area: *const graphics.Rect, dest_x: i32, dest_y: i32, mask: [*]const u8, mask_pitch: u32) callconv(.c) void {
    BltMaskRastPort(gb, @ptrCast(@alignCast(src)), @ptrCast(@alignCast(dest)), area, dest_x, dest_y, mask, mask_pitch);
}
fn lvoBltBitMap(gb: *GraphicsBase, src: *const rtg.Surface, src_x: i32, src_y: i32, dest: *rtg.Surface, dest_x: i32, dest_y: i32, width: i32, height: i32) callconv(.c) i32 {
    return BltBitMap(gb, src, src_x, src_y, dest, dest_x, dest_y, width, height);
}
fn lvoBltBitMapRastPort(gb: *GraphicsBase, src: *const rtg.Surface, src_x: i32, src_y: i32, dest: *graphics.RastPort, dest_x: i32, dest_y: i32, width: i32, height: i32) callconv(.c) void {
    BltBitMapRastPort(gb, src, src_x, src_y, @ptrCast(@alignCast(dest)), dest_x, dest_y, width, height);
}
fn lvoBltMaskBitMapRastPort(gb: *GraphicsBase, src: *const rtg.Surface, src_x: i32, src_y: i32, dest: *graphics.RastPort, dest_x: i32, dest_y: i32, width: i32, height: i32, mask: [*]const u8, mask_pitch: u32) callconv(.c) void {
    BltMaskBitMapRastPort(gb, src, src_x, src_y, @ptrCast(@alignCast(dest)), dest_x, dest_y, width, height, mask, mask_pitch);
}
fn lvoBitMapScale(gb: *GraphicsBase, src: *const rtg.Surface, src_area: *const graphics.Rect, dest: *graphics.RastPort, dest_area: *const graphics.Rect) callconv(.c) void {
    BitMapScale(gb, src, src_area, @ptrCast(@alignCast(dest)), dest_area);
}
fn lvoTextExtent(gb: *GraphicsBase, rp: *graphics.RastPort, string: [*]const u8, count: u32, out: *graphics.TextExtent) callconv(.c) void {
    TextExtent(gb, @ptrCast(@alignCast(rp)), string, count, out);
}
fn lvoTextFit(gb: *GraphicsBase, rp: *graphics.RastPort, string: [*]const u8, count: u32, out: *graphics.TextExtent, constraining: ?*const graphics.TextExtent, direction: i32, width: i32, height: i32) callconv(.c) u32 {
    return TextFit(gb, @ptrCast(@alignCast(rp)), string, count, out, constraining, direction, width, height);
}
fn lvoAddFont(gb: *GraphicsBase, font: *graphics.TextFont) callconv(.c) bool {
    return AddFont(gb, @ptrCast(@alignCast(font)));
}
fn lvoRemFont(gb: *GraphicsBase, font: *graphics.TextFont) callconv(.c) bool {
    return RemFont(gb, @ptrCast(@alignCast(font)));
}
fn lvoFontExtent(gb: *GraphicsBase, font: *graphics.TextFont, out: *graphics.FontExtent) callconv(.c) void {
    FontExtent(gb, @ptrCast(@alignCast(font)), out);
}
fn lvoAskSoftStyle(gb: *GraphicsBase, rp: *graphics.RastPort) callconv(.c) u32 {
    return AskSoftStyle(gb, @ptrCast(@alignCast(rp)));
}
fn lvoSetSoftStyle(gb: *GraphicsBase, rp: *graphics.RastPort, style: u32, enable: u32) callconv(.c) u32 {
    return SetSoftStyle(gb, @ptrCast(@alignCast(rp)), style, enable);
}
fn lvoGraphicsErrorText(gb: *GraphicsBase, code: i32) callconv(.c) [*:0]const u8 {
    return GraphicsErrorText(gb, code);
}
fn lvoNewRegion(gb: *GraphicsBase) callconv(.c) ?*graphics.Region {
    return @ptrCast(NewRegion(gb));
}
fn lvoDisposeRegion(gb: *GraphicsBase, region: ?*graphics.Region) callconv(.c) void {
    DisposeRegion(gb, @ptrCast(@alignCast(region)));
}
fn lvoClearRegion(gb: *GraphicsBase, region: *graphics.Region) callconv(.c) void {
    ClearRegion(gb, @ptrCast(@alignCast(region)));
}
fn lvoPointInRegion(gb: *GraphicsBase, region: *graphics.Region, x: i32, y: i32) callconv(.c) bool {
    return PointInRegion(gb, @ptrCast(@alignCast(region)), x, y);
}
fn lvoOffsetRegion(gb: *GraphicsBase, region: *graphics.Region, dx: i32, dy: i32) callconv(.c) void {
    OffsetRegion(gb, @ptrCast(@alignCast(region)), dx, dy);
}
fn lvoOrRectRegion(gb: *GraphicsBase, region: *graphics.Region, rect: *const graphics.Rect) callconv(.c) bool {
    return OrRectRegion(gb, @ptrCast(@alignCast(region)), rect);
}
fn lvoAndRectRegion(gb: *GraphicsBase, region: *graphics.Region, rect: *const graphics.Rect) callconv(.c) bool {
    return AndRectRegion(gb, @ptrCast(@alignCast(region)), rect);
}
fn lvoClearRectRegion(gb: *GraphicsBase, region: *graphics.Region, rect: *const graphics.Rect) callconv(.c) bool {
    return ClearRectRegion(gb, @ptrCast(@alignCast(region)), rect);
}
fn lvoXorRectRegion(gb: *GraphicsBase, region: *graphics.Region, rect: *const graphics.Rect) callconv(.c) bool {
    return XorRectRegion(gb, @ptrCast(@alignCast(region)), rect);
}
fn lvoOrRegionRegion(gb: *GraphicsBase, source: *const graphics.Region, dest: *graphics.Region) callconv(.c) bool {
    return OrRegionRegion(gb, @ptrCast(@alignCast(source)), @ptrCast(@alignCast(dest)));
}
fn lvoAndRegionRegion(gb: *GraphicsBase, source: *const graphics.Region, dest: *graphics.Region) callconv(.c) bool {
    return AndRegionRegion(gb, @ptrCast(@alignCast(source)), @ptrCast(@alignCast(dest)));
}
fn lvoSubRegionRegion(gb: *GraphicsBase, source: *const graphics.Region, dest: *graphics.Region) callconv(.c) bool {
    return SubRegionRegion(gb, @ptrCast(@alignCast(source)), @ptrCast(@alignCast(dest)));
}
fn lvoXorRegionRegion(gb: *GraphicsBase, source: *const graphics.Region, dest: *graphics.Region) callconv(.c) bool {
    return XorRegionRegion(gb, @ptrCast(@alignCast(source)), @ptrCast(@alignCast(dest)));
}
fn lvoRegionRectangles(gb: *GraphicsBase, region: *const graphics.Region, into: ?[*]graphics.Rect, max: u32) callconv(.c) u32 {
    return RegionRectangles(gb, @ptrCast(@alignCast(region)), into, max);
}
fn lvoScrollRaster(gb: *GraphicsBase, rp: *graphics.RastPort, dx: i32, dy: i32, area: *const graphics.Rect) callconv(.c) bool {
    return ScrollRaster(gb, @ptrCast(@alignCast(rp)), dx, dy, area);
}
fn lvoEraseRect(gb: *GraphicsBase, rp: *graphics.RastPort, area: *const graphics.Rect) callconv(.c) void {
    EraseRect(gb, @ptrCast(@alignCast(rp)), area);
}
fn lvoWritePixelArray(gb: *GraphicsBase, rp: *graphics.RastPort, pixels: [*]const u8, pitch: u32, format: u32, src_x: i32, src_y: i32, area: *const graphics.Rect) callconv(.c) void {
    WritePixelArray(gb, @ptrCast(@alignCast(rp)), pixels, pitch, format, src_x, src_y, area);
}
fn lvoWriteLUTPixelArray(gb: *GraphicsBase, rp: *graphics.RastPort, pixels: [*]const u8, pitch: u32, table: [*]const graphics.Pen, src_x: i32, src_y: i32, area: *const graphics.Rect) callconv(.c) void {
    WriteLUTPixelArray(gb, @ptrCast(@alignCast(rp)), pixels, pitch, table, src_x, src_y, area);
}
fn lvoBeginDraw(gb: *GraphicsBase, rp: *graphics.RastPort) callconv(.c) void {
    return BeginDraw(gb, @ptrCast(@alignCast(rp)));
}
fn lvoEndDraw(gb: *GraphicsBase, rp: *graphics.RastPort) callconv(.c) void {
    return EndDraw(gb, @ptrCast(@alignCast(rp)));
}

/// The jump table, built from the end backwards: vector i sits at
/// `base - (i + 1) * slot_size`, so Open is LVO -4 and Expunge LVO -12.
/// Open, Close and ExtFunc are exec's standard ones; only Expunge is this
/// library's. The library's own calls are appended after these four.
/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(graphics_base.expunge),
    vec(exec.libExtFunc),
    vec(lvoCreateRastPortTagList),
    vec(lvoFreeRastPort),
    vec(lvoRectFill),
    vec(lvoSetRPAttrs),
    vec(lvoGetRPAttrs),
    vec(lvoAllocBitMapTagList),
    vec(lvoFreeBitMap),
    vec(lvoBltRastPort),
    vec(lvoMove),
    vec(lvoDraw),
    vec(lvoWritePixel),
    vec(lvoReadPixel),
    vec(lvoDrawHLine),
    vec(lvoDrawVLine),
    vec(lvoDrawRect),
    vec(lvoDrawCircle),
    vec(lvoDrawEllipse),
    vec(lvoDrawArc),
    vec(lvoDrawPoly),
    vec(lvoInitArea),
    vec(lvoAreaMove),
    vec(lvoAreaDraw),
    vec(lvoAreaEllipse),
    vec(lvoAreaCircle),
    vec(lvoAreaArc),
    vec(lvoAreaEnd),
    vec(lvoOpenFont),
    vec(lvoCloseFont),
    vec(lvoText),
    vec(lvoTextLength),
    vec(lvoBltTemplate),
    vec(lvoBltPattern),
    vec(lvoBltMaskRastPort),
    vec(lvoBltBitMap),
    vec(lvoBltBitMapRastPort),
    vec(lvoBltMaskBitMapRastPort),
    vec(lvoBitMapScale),
    vec(lvoTextExtent),
    vec(lvoTextFit),
    vec(lvoAddFont),
    vec(lvoRemFont),
    vec(lvoFontExtent),
    vec(lvoAskSoftStyle),
    vec(lvoSetSoftStyle),
    vec(lvoGraphicsErrorText),
    vec(lvoNewRegion),
    vec(lvoDisposeRegion),
    vec(lvoClearRegion),
    vec(lvoPointInRegion),
    vec(lvoOffsetRegion),
    vec(lvoOrRectRegion),
    vec(lvoAndRectRegion),
    vec(lvoClearRectRegion),
    vec(lvoXorRectRegion),
    vec(lvoOrRegionRegion),
    vec(lvoAndRegionRegion),
    vec(lvoSubRegionRegion),
    vec(lvoXorRegionRegion),
    vec(lvoRegionRectangles),
    vec(lvoScrollRaster),
    vec(lvoEraseRect),
    vec(lvoWritePixelArray),
    vec(lvoWriteLUTPixelArray),
    vec(lvoBeginDraw),
    vec(lvoEndDraw),
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
    try exec.libraries.checkForwarding(@embedFile("graphics_lvo.zig"), LVO, &.{});
}
