// SPDX-License-Identifier: MIT
//! lottie.datatype: a Lottie file, the JSON form of a vector animation,
//! as an animation.
//!
//! An animation.datatype subclass. The file is read once onto a tape of
//! its values (`json.zig`); every frame is drawn from that tape anew,
//! on the loader process, into the frame buffer the superclass hands
//! over: layers and shapes walked (`render.zig`), their properties taken
//! at the frame's time (`property.zig`), paths flattened and filled or
//! stroked with smooth edges (`raster.zig`). What the frame does not
//! cover is left clear, so the ground the object is drawn on shows.
//!
//! **Size and rate.** The animation is drawn at the size the file gives,
//! made smaller to fit in `max_side` pixels each way: a frame's pixels
//! are all worked out in software, and the superclass holds three of
//! them. It plays at the file's frame rate up to `max_rate`; a faster
//! file has its frames taken at that rate, each at its own moment of
//! the animation.
//!
//! The library's recognise call accepts a JSON file whose outermost
//! object has a width, a height, a frame rate, an out point and layers.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gadgets = sdk.gadgets;
const datatypes = sdk.datatypes;
const subclass = datatypes.subclass;
const dtc = datatypes.datatypesclass;
const adt = datatypes.animationclass;
const json = @import("json.zig");
const raster = @import("raster.zig");
const render = @import("render.zig");
const DosBase = sdk.interface.dos.DosBase;
const ExecBase = sdk.interface.exec.ExecBase;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Base = gadgets.Base;
const Pen = graphics.Pen;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
/// Its one call, after the standard four, is the recognise function
/// datatypes.library asks.
pub const Library = gadgets.ClassLibrary(.{
    .name = "lottie.datatype",
    .version = 1,
    .date = "03.10.2026",
    .super = adt.ANIMATIONDTCLASS,
    .opens = &.{adt.ANIMATION_LIBRARY},
    .Instance = Data,
    .dispatch = dispatch,
    .functions = &.{exec.libraries.vec(recognise)},
});
comptime {
    _ = Library;
}

/// The largest a frame is drawn, either way, in pixels.
const max_side = 360;
/// The most frames a second played.
const max_rate = 30;
/// A recognise reads the whole file; one larger than this is not looked
/// into.
const recognise_most = 4 << 20;
/// Room for the points and contours of the paths one fill or stroke
/// paints.
const max_points = 16384;
const max_contours = 1024;

/// lottie.datatype's part of an object: the file, its tape, and what a
/// frame is drawn with - used by the loader process only, once made.
pub const Data = extern struct {
    file: ?[*]u8 = null,
    file_length: u32 = 0,
    nodes: ?[*]json.Node = null,
    node_count: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    frames: u32 = 0,
    /// Pixels a unit of the file.
    scale: f32 = 1,
    /// The file's first frame, and its frames a frame played.
    in_point: f32 = 0,
    step: f32 = 1,
    rate: u32 = 0,
    acc: ?[*]f32 = null,
    points: ?[*]raster.P = null,
    ends: ?[*]u32 = null,
    closed: ?[*]bool = null,
};

fn tapeOf(own: *const Data) json.Tape {
    return .{ .text = own.file.?[0..own.file_length], .nodes = own.nodes.?[0..own.node_count] };
}

/// Frame `frame` into the buffer animation.datatype handed over.
fn loadFrame(own: *Data, msg: *adt.AdtFrame) void {
    msg.duration = 1000 / @max(own.rate, 1);
    if (own.acc == null) return;
    const tape = tapeOf(own);
    var area = raster.Raster{ .acc = own.acc.?, .width = own.width, .height = own.height };
    var outline = raster.Outline{
        .points = own.points.?[0..max_points],
        .ends = own.ends.?[0..max_contours],
        .closed = own.closed.?[0..max_contours],
    };
    var renderer = render.Renderer{
        .tape = tape,
        .raster = &area,
        .outline = &outline,
        .canvas = .{ .pens = msg.pens, .bytes_per_row = msg.bytes_per_row, .width = own.width, .height = own.height },
        .assets = tape.get(0, "assets"),
    };
    renderer.frame(0, own.in_point + @as(f32, @floatFromInt(msg.frame)) * own.step, own.scale);
}

/// The numbers an animation needs from the outermost object, or null
/// when it is not a Lottie file.
const Header = struct { width: f32, height: f32, rate: f32, in_point: f32, out_point: f32 };

fn headerOf(tape: json.Tape) ?Header {
    if (tape.kind(0) != .object) return null;
    if (tape.count(tape.get(0, "layers")) == 0) return null;
    const header = Header{
        .width = tape.number(tape.get(0, "w")) orelse return null,
        .height = tape.number(tape.get(0, "h")) orelse return null,
        .rate = tape.number(tape.get(0, "fr")) orelse return null,
        .in_point = tape.number(tape.get(0, "ip")) orelse 0,
        .out_point = tape.number(tape.get(0, "op")) orelse return null,
    };
    if (header.width < 1 or header.height < 1 or header.rate <= 0 or header.out_point <= header.in_point) return null;
    if (header.width > 100_000 or header.height > 100_000) return null;
    return header;
}

/// The file's text read onto a tape of nodes allocated for it, or null.
fn tapeFor(sys: *ExecBase, text: []const u8) ?struct { nodes: [*]json.Node, count: u32 } {
    const count = json.parse(text, null) orelse return null;
    const memory = sys.AllocVec(count * @sizeOf(json.Node), exec.MEMF_ANY) orelse return null;
    const nodes: [*]json.Node = @ptrCast(@alignCast(memory));
    _ = json.parse(text, nodes[0..count]);
    return .{ .nodes = nodes, .count = count };
}

/// The file read, its size and frames worked out and what drawing needs
/// made. What went wrong, or 0.
fn readFile(base: *Base, cl: *Class, o: *Object, own: *Data, bytes: []u8) i32 {
    const sys = base.sys_base;
    own.file = bytes.ptr;
    own.file_length = @intCast(bytes.len);
    const tape = tapeFor(sys, bytes) orelse return datatypes.DTERROR_INVALID_DATA;
    own.nodes = tape.nodes;
    own.node_count = tape.count;
    const header = headerOf(tapeOf(own)) orelse return datatypes.DTERROR_INVALID_DATA;

    const side = @max(header.width, header.height);
    own.scale = if (side > max_side) max_side / side else 1;
    own.width = @max(1, @as(u32, @intFromFloat(@ceil(header.width * own.scale))));
    own.height = @max(1, @as(u32, @intFromFloat(@ceil(header.height * own.scale))));
    const rate = @min(header.rate, max_rate);
    own.rate = @max(1, @as(u32, @intFromFloat(@round(rate))));
    own.step = header.rate / @as(f32, @floatFromInt(own.rate));
    own.in_point = header.in_point;
    own.frames = @max(1, @as(u32, @intFromFloat(@floor((header.out_point - header.in_point) / own.step))));

    const pixels: usize = @as(usize, own.width) * own.height;
    // The accumulation buffer, the outline, and the three frames
    // animation.datatype holds.
    const acc_bytes = raster.Raster.floats(own.width, own.height) * @sizeOf(f32);
    if (!subclass.roomFor(sys, acc_bytes + max_points * @sizeOf(raster.P) + 3 * pixels * 4)) return datatypes.DTERROR_TOO_LARGE;
    own.acc = @ptrCast(@alignCast(sys.AllocVec(@intCast(acc_bytes), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return datatypes.DTERROR_NOT_ENOUGH_DATA));
    own.points = @ptrCast(@alignCast(sys.AllocVec(max_points * @sizeOf(raster.P), exec.MEMF_ANY) orelse return datatypes.DTERROR_NOT_ENOUGH_DATA));
    own.ends = @ptrCast(@alignCast(sys.AllocVec(max_contours * @sizeOf(u32), exec.MEMF_ANY) orelse return datatypes.DTERROR_NOT_ENOUGH_DATA));
    own.closed = @ptrCast(sys.AllocVec(max_contours, exec.MEMF_ANY) orelse return datatypes.DTERROR_NOT_ENOUGH_DATA);

    const tags = [_]TagItem{
        .{ .tag = adt.ADTA_Width, .data = own.width },
        .{ .tag = adt.ADTA_Height, .data = own.height },
        .{ .tag = adt.ADTA_Frames, .data = own.frames },
        .{ .tag = adt.ADTA_FramesPerSecond, .data = own.rate },
        .{},
    };
    subclass.superTell(base.intuition_base, cl, o, &tags);
    return 0;
}

fn freeAll(sys: *ExecBase, own: *const Data) void {
    sys.FreeVec(own.file);
    sys.FreeVec(own.nodes);
    sys.FreeVec(own.acc);
    sys.FreeVec(own.points);
    sys.FreeVec(own.ends);
    sys.FreeVec(own.closed);
}

/// datatypes.library's question: whether the file is JSON with what a
/// Lottie animation has at its top.
fn recognise(base: *Base, context: *datatypes.DTHookContext) callconv(.c) bool {
    const sys = base.sys_base;
    const dl: *DosBase = @ptrCast(@alignCast(context.dos_base));
    const file = context.file orelse return false;
    const fib = context.fib orelse return false;
    if (fib.size == 0 or fib.size > recognise_most) return false;
    const length: usize = @intCast(fib.size);
    const memory = sys.AllocVec(length, exec.MEMF_ANY) orelse return false;
    defer sys.FreeVec(memory);
    const text: [*]u8 = @ptrCast(memory);
    if (dl.Read(file, text, @intCast(length)) != @as(isize, @intCast(length))) return false;
    const tape = tapeFor(sys, text[0..length]) orelse return false;
    defer sys.FreeVec(tape.nodes);
    return headerOf(.{ .text = text[0..length], .nodes = tape.nodes[0..tape.count] }) != null;
}

fn dispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *Class = @ptrCast(hook);
    const base = gadgets.baseOf(cl);
    const ib = base.intuition_base;
    const sys = base.sys_base;
    const msg: *classusr.Msg = @ptrCast(@alignCast(message orelse return 0));
    const o: ?*Object = @ptrCast(object);

    switch (msg.method_id) {
        classusr.OM_NEW => {
            const made = ib.SendSuperMessage(cl, o, msg);
            if (made == 0) return 0;
            const obj: *Object = @ptrFromInt(made);
            const own = classes.instData(Data, cl, obj);
            own.* = .{};
            const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse {
                ib.DisposeObject(obj);
                return 0;
            };
            const dl: *DosBase = @ptrCast(dos_lib);
            defer sys.CloseLibrary(dos_lib);
            const lock: ?*dos.FileLock = @ptrFromInt(subclass.superAsk(ib, cl, obj, dtc.DTA_Handle));
            const bytes = switch (subclass.readWhole(sys, dl, lock)) {
                .got => |read| read,
                .too_large => {
                    _ = dl.SetIoErr(datatypes.DTERROR_TOO_LARGE);
                    ib.DisposeObject(obj);
                    return 0;
                },
                .no_file => {
                    _ = dl.SetIoErr(datatypes.DTERROR_COULDNT_OPEN);
                    ib.DisposeObject(obj);
                    return 0;
                },
            };
            const failure = readFile(base, cl, obj, own, bytes);
            if (failure != 0) {
                _ = dl.SetIoErr(failure);
                ib.DisposeObject(obj);
                return 0;
            }
            return made;
        },
        classusr.OM_DISPOSE => {
            // The loader may be in the middle of a frame: the superclass
            // stops it first, and only then may what it draws with go.
            // The object is gone after that, so its numbers are kept here.
            const kept = classes.instData(Data, cl, o.?).*;
            const result = ib.SendSuperMessage(cl, o, msg);
            freeAll(sys, &kept);
            return result;
        },
        adt.ADTM_LOADFRAME => {
            loadFrame(classes.instData(Data, cl, o.?), @ptrCast(@alignCast(msg)));
            return 1;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
