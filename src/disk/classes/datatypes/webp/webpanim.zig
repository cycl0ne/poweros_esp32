// SPDX-License-Identifier: MIT
//! webpanim.datatype: a WebP file that holds an animation, as an
//! animation.
//!
//! An animation.datatype subclass. A WebP whose `VP8X` says it is an
//! animation is recognised here (the library's recognise call, from the
//! file's first bytes) and goes to this class; any other WebP is a
//! picture and goes to webp.datatype. Both read the file with the same
//! decoder (`decode.zig`).
//!
//! **The frames are built one on the other, on a canvas the class
//! keeps** (`decode.Canvas`): frame n is the canvas after frames 0 to n,
//! each laid where the file puts it - over what is there by its
//! coverage, or in its place - and each one's area cleared after it when
//! it says so. The canvas goes forward one frame at a time; a frame asked
//! for that lies behind it starts the canvas again from the first.
//!
//! A frame stays up for the time the file gives it, in thousandths of a
//! second; one of ten or less gets a tenth of a second, as the web
//! treats it. The canvas starts clear, so what no frame has covered yet
//! shows the ground the object is drawn on.

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
const adt = datatypes.animationclass;
const decode = @import("decode.zig");
const memory = @import("memory.zig");
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
    .name = "webpanim.datatype",
    .version = 1,
    .revision = 0,
    .date = "21.11.2026",
    .super = adt.ANIMATIONDTCLASS,
    .opens = &.{adt.ANIMATION_LIBRARY},
    .Instance = Data,
    .dispatch = dispatch,
    .functions = &.{exec.libraries.vec(recognise)},
});
comptime {
    _ = Library;
}

/// The most frames counted: a file with more plays the first ones.
const max_frames = 100_000;

/// What the loader process draws with, once made: the file, what it is,
/// the canvas and the frame being unpacked.
const State = struct {
    file: []u8,
    info: decode.Info,
    canvas: decode.Canvas,
    /// A frame's pixels as they unpack, room for the largest there can
    /// be: the canvas's size.
    unpacked: []u32,
    /// The frame the canvas is ready for, and where its chunk is.
    next_frame: u32 = 0,
    next_at: usize = 0,
    /// How long the last frame laid on stays.
    last_duration: u32 = 0,
};

/// webpanim.datatype's part of an object: its state.
pub const Data = extern struct {
    state: ?*State = null,
};

/// The canvas cleared and the file walked back to its first frame.
fn rewind(state: *State) void {
    state.canvas.reset();
    state.next_frame = 0;
    state.next_at = state.info.frames_at;
}

/// The next frame laid on the canvas. False when the file has no more,
/// or is broken.
fn step(sys: *ExecBase, state: *State) bool {
    const frame = (decode.readFrame(state.file, &state.info, state.next_at) catch return false) orelse return false;
    state.next_at = frame.next_at;
    state.next_frame += 1;
    state.last_duration = frame.duration;
    const pixels = state.unpacked[0 .. @as(usize, frame.width) * frame.height];
    // A frame that will not unpack is left out, and the canvas stays as
    // the frame before left it.
    decode.decodeImage(memory.envOf(sys), frame.image, frame.width, frame.height, pixels) catch return true;
    state.canvas.add(&frame, pixels);
    return true;
}

/// Frame `frame` into the buffer animation.datatype handed over.
fn loadFrame(sys: *ExecBase, own: *Data, msg: *adt.AdtFrame) void {
    const state = own.state orelse return;
    if (msg.frame < state.next_frame or state.next_frame == 0) rewind(state);
    while (state.next_frame <= msg.frame) {
        if (!step(sys, state)) break;
    }
    const width = state.info.width;
    var y: u32 = 0;
    while (y < state.info.height) : (y += 1) {
        const row: [*]Pen = @ptrCast(@alignCast(@as([*]u8, @ptrCast(msg.pens)) + y * msg.bytes_per_row));
        @memcpy(row[0..width], state.canvas.pixels[@as(usize, y) * width ..][0..width]);
    }
    msg.duration = if (state.last_duration <= 10) 100 else state.last_duration;
}

/// The file read, its frames counted and the canvas made. What went
/// wrong, or 0.
fn readFile(base: *Base, cl: *Class, o: *Object, own: *Data, bytes: []u8) i32 {
    const sys = base.sys_base;
    const info = decode.readInfo(bytes) catch return datatypes.DTERROR_INVALID_DATA;
    if (!info.animated) return datatypes.DTERROR_INVALID_DATA;
    const frames = decode.countFrames(bytes, &info, max_frames) catch return datatypes.DTERROR_INVALID_DATA;
    if (frames == 0) return datatypes.DTERROR_NOT_ENOUGH_DATA;

    const pixels = @as(usize, info.width) * info.height;
    // The canvas, a frame as it unpacks, and the three frames
    // animation.datatype holds.
    if (!subclass.roomFor(sys, pixels * (4 + 4 + 3 * 4))) return datatypes.DTERROR_TOO_LARGE;
    const env = memory.envOf(sys);
    const state_memory = sys.AllocVec(@sizeOf(State), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return datatypes.DTERROR_NOT_ENOUGH_DATA;
    const state: *State = @ptrCast(@alignCast(state_memory));
    const canvas = env.slice(u32, pixels) orelse {
        sys.FreeVec(state_memory);
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    };
    const unpacked = env.slice(u32, pixels) orelse {
        env.freeSlice(u32, canvas);
        sys.FreeVec(state_memory);
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    };
    state.* = .{
        .file = bytes,
        .info = info,
        .canvas = .{ .pixels = canvas, .width = info.width, .height = info.height },
        .unpacked = unpacked,
        .next_at = info.frames_at,
    };
    own.state = state;

    const tags = [_]TagItem{
        .{ .tag = adt.ADTA_Width, .data = info.width },
        .{ .tag = adt.ADTA_Height, .data = info.height },
        .{ .tag = adt.ADTA_Frames, .data = frames },
        .{ .tag = adt.ADTA_FramesPerSecond, .data = 10 },
        .{},
    };
    subclass.superTell(base.intuition_base, cl, o, &tags);
    return 0;
}

fn freeAll(sys: *ExecBase, state: ?*State) void {
    const held = state orelse return;
    const env = memory.envOf(sys);
    sys.FreeVec(held.file.ptr);
    env.freeSlice(u32, held.canvas.pixels);
    env.freeSlice(u32, held.unpacked);
    sys.FreeVec(held);
}

/// datatypes.library's question: whether the file is a WebP that says it
/// is an animation. Any other WebP is webp.datatype's.
fn recognise(_: *Base, context: *datatypes.DTHookContext) callconv(.c) bool {
    // The first bytes are in the buffer, a file's and memory's alike, and
    // the few that say it are among them.
    const start = context.buffer orelse return false;
    return decode.isAnimation(start[0..context.buffer_length]);
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
            const bytes = switch (subclass.readSource(sys, dl, ib, cl, obj)) {
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
                // The file is the state's once there is one; until then
                // it is given back here.
                if (own.state == null) sys.FreeVec(bytes.ptr);
                _ = dl.SetIoErr(failure);
                ib.DisposeObject(obj);
                return 0;
            }
            return made;
        },
        classusr.OM_DISPOSE => {
            // The loader may be in the middle of a frame: the superclass
            // stops it first, and only then may what it draws with go.
            // The object is gone after that, so its state is kept here.
            const kept = classes.instData(Data, cl, o.?).state;
            const result = ib.SendSuperMessage(cl, o, msg);
            freeAll(sys, kept);
            return result;
        },
        adt.ADTM_LOADFRAME => {
            loadFrame(sys, classes.instData(Data, cl, o.?), @ptrCast(@alignCast(msg)));
            return 1;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
