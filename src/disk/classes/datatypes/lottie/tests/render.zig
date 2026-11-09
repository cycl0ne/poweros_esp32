// SPDX-License-Identifier: MIT
//! Host tests of lottie.datatype's drawing: frames drawn through
//! vector.library - made from its ROM tag on the ROM's exec, as the
//! datatype's init opens it - and their pens checked.
//!
//! The hashes are of every frame of a file as raster.zig, Lottie's own
//! rasterizer before vector.library 1.0, drew it: the library draws them
//! the same to the bit.

const std = @import("std");
const sdk = @import("sdk");
const vector = sdk.vector;
const utility = sdk.utility;
const exec = sdk.exec;
const Pen = sdk.graphics.Pen;
const host = @import("host_rom");
const kexec = host.exec;
const vector_init = @import("../../../../libs/vector/vector_init.zig");
const json = @import("../json.zig");
const render = @import("../render.zig");

const testing = std.testing;
const VectorBase = sdk.interface.vector.VectorBase;

/// Memory lent to exec: a canvas of 360 by 360, the largest a frame is
/// drawn, wants 512 KiB.
var lent: [1024 * 1024]u8 align(16) = undefined;

/// vector.library made and opened, and a path and a canvas from it.
const Rig = struct {
    region: *exec.MemHeader,
    library: *exec.Library,
    vb: *VectorBase,
    path: *vector.Path,
    canvas: *vector.Canvas,
    width: u32,
    height: u32,

    pub fn open(width: u32, height: u32) !Rig {
        try kexec.setUp();
        const sys = kexec.SysBase.iface();
        const region = sys.AddMemList(lent.len, exec.MEMF_ANY, 0, &lent, "lent").?;
        const made = kexec.InitResident(kexec.SysBase, &vector_init.vector_library_tag, null) orelse return error.NoLibrary;
        const vb: *VectorBase = @ptrCast(sys.OpenLibrary(vector.VECTORNAME, vector.VECTOR_VERSION) orelse return error.NoBase);
        const tags = [_]utility.TagItem{
            .{ .tag = vector.VCA_Width, .data = width },
            .{ .tag = vector.VCA_Height, .data = height },
            .{},
        };
        return .{
            .region = region,
            .library = @ptrCast(@alignCast(made)),
            .vb = vb,
            .path = vb.CreatePath() orelse return error.NoPath,
            .canvas = vb.CreateCanvasTagList(&tags) orelse return error.NoCanvas,
            .width = width,
            .height = height,
        };
    }

    pub fn close(rig: Rig) !void {
        const sys = kexec.SysBase.iface();
        rig.vb.DisposePath(rig.path);
        rig.vb.DisposeCanvas(rig.canvas);
        sys.CloseLibrary(rig.vb.lib());
        _ = sys.RemLibrary(rig.library);
        try kexec.expectNoLeaks();
        try testing.expectEqual(@intFromPtr(rig.region.upper) - @intFromPtr(rig.region.lower), rig.region.free);
        sys.Remove(&rig.region.node);
        kexec.deinit();
    }

    /// The file at `time`, `scale` pixels a unit, onto `pens`.
    pub fn draw(rig: Rig, tape: json.Tape, time: f32, scale: f32, pens: []Pen) void {
        rig.vb.SetCanvasPens(rig.canvas, pens.ptr, rig.width * 4);
        var renderer = render.Renderer{
            .tape = tape,
            .vb = rig.vb,
            .path = rig.path,
            .canvas = rig.canvas,
            .assets = tape.get(0, "assets"),
        };
        renderer.frame(0, time, scale);
    }
};

/// A file read onto a tape, its nodes from the test allocator.
const File = struct {
    nodes: []json.Node,
    tape: json.Tape,

    pub fn parse(text: []const u8) !File {
        const count = json.parse(text, null) orelse return error.NotJson;
        const nodes = try testing.allocator.alloc(json.Node, count);
        _ = json.parse(text, nodes);
        return .{ .nodes = nodes, .tape = .{ .text = text, .nodes = nodes } };
    }

    pub fn deinit(file: File) void {
        testing.allocator.free(file.nodes);
    }
};

/// Every frame from `first` to `last`, `step` apart, `scale` pixels a
/// unit, onto cleared pens: an FNV-1a hash of them all.
fn hashFrames(rig: Rig, file: File, first: f32, last: f32, step: f32, scale: f32, pens: []Pen) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    var time = first;
    while (time <= last) : (time += step) {
        @memset(pens, 0);
        rig.draw(file.tape, time, scale, pens);
        for (std.mem.sliceAsBytes(pens)) |byte| {
            hash ^= byte;
            hash *%= 0x100000001b3;
        }
    }
    return hash;
}

const spinner = @embedFile("../../../../tests/datatypes/Spinner.json");

/// Strokes: every join and cap, a miter past its limit, a curve, a dot,
/// a width of nothing and one that grows, through a layer that turns and
/// stretches.
const strokes =
    \\{"w":120,"h":90,"fr":30,"ip":0,"op":30,"layers":[
    \\ {"ty":4,"ind":1,"ip":0,"op":30,"st":0,
    \\  "ks":{"a":{"a":0,"k":[60,45]},"p":{"a":0,"k":[60,45]},"s":{"a":0,"k":[120,80]},
    \\        "r":{"a":1,"k":[{"t":0,"s":[0],"o":{"x":0.3,"y":0},"i":{"x":0.7,"y":1}},{"t":30,"s":[30]}]},"o":{"a":0,"k":100}},
    \\  "shapes":[
    \\   {"ty":"gr","it":[
    \\    {"ty":"sh","ks":{"a":0,"k":{"v":[[10,10],[40,60],[60,15],[90,70],[110,20]],"i":[[0,0],[0,0],[0,0],[0,0],[0,0]],"o":[[0,0],[0,0],[0,0],[0,0],[0,0]],"c":false}}},
    \\    {"ty":"st","c":{"a":0,"k":[0.9,0.2,0.1,1]},"o":{"a":0,"k":100},"lj":1,"ml":4,"lc":1,
    \\     "w":{"a":1,"k":[{"t":0,"s":[2],"o":{"x":0,"y":0},"i":{"x":1,"y":1}},{"t":30,"s":[9]}]}},
    \\    {"ty":"tr","p":{"a":0,"k":[0,0]},"a":{"a":0,"k":[0,0]},"s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}}]},
    \\   {"ty":"gr","it":[
    \\    {"ty":"sh","ks":{"a":0,"k":{"v":[[5,80],[30,40],[55,85],[80,35]],"i":[[0,0],[0,0],[0,0],[0,0]],"o":[[0,0],[0,0],[0,0],[0,0]],"c":false}}},
    \\    {"ty":"st","c":{"a":0,"k":[0.1,0.6,0.2,1]},"o":{"a":0,"k":80},"lj":1,"ml":1.2,"lc":3,"w":{"a":0,"k":6}},
    \\    {"ty":"tr","p":{"a":0,"k":[3,-4]},"a":{"a":0,"k":[0,0]},"s":{"a":0,"k":[100,100]},"r":{"a":0,"k":5},"o":{"a":0,"k":90}}]},
    \\   {"ty":"gr","it":[
    \\    {"ty":"sh","ks":{"a":0,"k":{"v":[[15,50],[60,50],[105,45]],"i":[[0,0],[-20,30],[-10,-25]],"o":[[20,-30],[15,25],[0,0]],"c":false}}},
    \\    {"ty":"st","c":{"a":1,"k":[{"t":0,"s":[0,0,1,1],"o":{"x":0,"y":0},"i":{"x":1,"y":1}},{"t":30,"s":[1,1,0,1]}]},"o":{"a":0,"k":100},"lj":2,"lc":2,"w":{"a":0,"k":5}},
    \\    {"ty":"tr","p":{"a":0,"k":[0,0]},"a":{"a":0,"k":[0,0]},"s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}}]},
    \\   {"ty":"gr","it":[
    \\    {"ty":"sh","ks":{"a":0,"k":{"v":[[70,10],[100,30],[75,40]],"i":[[0,0],[0,0],[0,0]],"o":[[0,0],[0,0],[0,0]],"c":true}}},
    \\    {"ty":"st","c":{"a":0,"k":[0.2,0.2,0.2,1]},"o":{"a":0,"k":100},"lj":3,"lc":1,"w":{"a":0,"k":4}},
    \\    {"ty":"fl","c":{"a":0,"k":[1,0.8,0.1,1]},"o":{"a":0,"k":70},"r":1},
    \\    {"ty":"tr","p":{"a":0,"k":[0,0]},"a":{"a":0,"k":[0,0]},"s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}}]},
    \\   {"ty":"gr","it":[
    \\    {"ty":"sh","ks":{"a":0,"k":{"v":[[60,80]],"i":[[0,0]],"o":[[0,0]],"c":false}}},
    \\    {"ty":"st","c":{"a":0,"k":[0.5,0,0.5,1]},"o":{"a":0,"k":100},"lj":1,"lc":2,"w":{"a":0,"k":8}},
    \\    {"ty":"sh","ks":{"a":0,"k":{"v":[[20,20],[50,25]],"i":[[0,0],[0,0]],"o":[[0,0],[0,0]],"c":false}}},
    \\    {"ty":"st","c":{"a":0,"k":[0,0,0,1]},"o":{"a":0,"k":100},"lj":1,"lc":1,"w":{"a":0,"k":0}},
    \\    {"ty":"tr","p":{"a":0,"k":[0,0]},"a":{"a":0,"k":[0,0]},"s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}}]}]}]}
;

test "a shape layer: a red square in a group, moved by its layer" {
    const text =
        \\{"w":20,"h":20,"fr":10,"ip":0,"op":10,"layers":[
        \\ {"ty":4,"ip":0,"op":10,"st":0,
        \\  "ks":{"p":{"a":1,"k":[{"t":0,"s":[0,0],"o":{"x":0,"y":0},"i":{"x":1,"y":1}},{"t":10,"s":[10,0]}]},"a":{"a":0,"k":[0,0]}},
        \\  "shapes":[{"ty":"gr","it":[
        \\    {"ty":"rc","p":{"a":0,"k":[5,5]},"s":{"a":0,"k":[6,6]},"r":{"a":0,"k":0}},
        \\    {"ty":"fl","c":{"a":0,"k":[1,0,0,1]},"o":{"a":0,"k":100}},
        \\    {"ty":"tr","p":{"a":0,"k":[0,0]}}]}]}]}
    ;
    const file = try File.parse(text);
    defer file.deinit();
    const rig = try Rig.open(20, 20);
    var pens: [400]Pen = @splat(0);
    rig.draw(file.tape, 0, 1, &pens);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[5 * 20 + 5]);
    try testing.expectEqual(@as(Pen, 0), pens[5 * 20 + 12]);
    @memset(&pens, 0);
    // Half way, the layer has moved five units right.
    rig.draw(file.tape, 5, 1, &pens);
    try testing.expectEqual(@as(Pen, 0), pens[5 * 20 + 3]);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[5 * 20 + 10]);
    try rig.close();
}

test "Spinner.json's sixty frames come out as raster.zig drew them" {
    const file = try File.parse(spinner);
    defer file.deinit();
    const rig = try Rig.open(200, 200);
    const pens = try testing.allocator.alloc(Pen, 200 * 200);
    defer testing.allocator.free(pens);
    try testing.expectEqual(@as(u64, spinner_hash), hashFrames(rig, file, 0, 59, 1, 1, pens));
    try rig.close();
}

test "every join and cap, through a matrix that turns and stretches, as raster.zig drew them" {
    const file = try File.parse(strokes);
    defer file.deinit();
    const rig = try Rig.open(240, 180);
    const pens = try testing.allocator.alloc(Pen, 240 * 180);
    defer testing.allocator.free(pens);
    try testing.expectEqual(@as(u64, strokes_hash), hashFrames(rig, file, 0, 30, 1.5, 2, pens));
    try rig.close();
}

const spinner_hash = 0xf520902e707de506;
const strokes_hash = 0x9000feb96c950c2a;
