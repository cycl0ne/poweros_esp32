// SPDX-License-Identifier: MIT
//! gifanim.datatype: a GIF file that holds an animation, as an
//! animation.
//!
//! An animation.datatype subclass. A GIF with one picture is a picture
//! and goes to gif.datatype; one with more is recognised here (the
//! library's recognise call: two pictures or more) and goes to this
//! class. Both read the file with the same decoder (`decode.zig`,
//! `lzw.zig`).
//!
//! **The frames are built one on the other, on a canvas the class
//! keeps.** A GIF's picture covers only part of the screen it names,
//! and what it leaves is the frame before: so frame n is the canvas
//! after pictures 0 to n, each drawn where the file puts it, its
//! see-through colour leaving the canvas as it was. Before the next
//! picture its area is disposed of as it says - left, cleared to
//! nothing, or put back to what it was before it was drawn. The canvas
//! goes forward one picture at a time; a frame asked for that lies
//! behind it starts the canvas again from the first.
//!
//! A frame stays up for the delay its graphic control block gives, in
//! hundredths of a second; one of none or one hundredth gets a tenth of
//! a second, as the web treats it. The canvas starts clear, so what no
//! picture has covered yet shows the ground the object is drawn on.

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
const lzw = @import("lzw.zig");
const decode = @import("decode.zig");
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
    .name = "gifanim.datatype",
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

/// The most pictures counted: a file with more plays the first ones.
const max_frames = 100_000;
/// A recognise reads the whole file; one larger than this is not looked
/// into.
const recognise_most = 4 << 20;

/// gifanim.datatype's part of an object: the file, and the canvas the
/// frames are built on - used by the loader process only, once made.
pub const Data = extern struct {
    file: ?[*]u8 = null,
    file_length: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    frames: u32 = 0,
    background: u8 = 0,
    pad: [3]u8 = @splat(0),
    palette_at: u32 = 0,
    palette_length: u32 = 0,
    blocks_at: u32 = 0,

    /// The canvas, and what a picture covered before it was drawn.
    canvas: ?[*]Pen = null,
    saved: ?[*]Pen = null,
    /// One pixel number a pixel, as a picture unpacks.
    indexes: ?[*]u8 = null,
    work: ?*lzw.Work = null,

    /// The picture the canvas is ready for, and where it starts.
    next_frame: u32 = 0,
    next_at: u32 = 0,
    /// The last picture drawn, and what becomes of its area.
    last_left: u32 = 0,
    last_top: u32 = 0,
    last_width: u32 = 0,
    last_height: u32 = 0,
    last_disposal: u8 = 0,
    pad2: [3]u8 = @splat(0),
    last_delay: u32 = 0,
};

fn screenOf(own: *const Data) decode.Screen {
    const file = own.file.?[0..own.file_length];
    return .{
        .width = own.width,
        .height = own.height,
        .background = own.background,
        .palette = file[own.palette_at..][0..own.palette_length],
        .at = own.blocks_at,
    };
}

fn penOf(palette: []const u8, index: u8) Pen {
    const at = @as(usize, index) * 3;
    if (at + 3 > palette.len) return 0xFF000000;
    return 0xFF000000 | @as(Pen, palette[at]) << 16 | @as(Pen, palette[at + 1]) << 8 | palette[at + 2];
}

/// The canvas cleared and the file walked back to its first picture.
fn rewind(own: *Data) void {
    @memset(own.canvas.?[0 .. own.width * own.height], 0);
    own.next_frame = 0;
    own.next_at = own.blocks_at;
    own.last_disposal = 0;
    own.last_width = 0;
}

/// A rectangle of the canvas, held to its bounds, copied from or to
/// `saved`.
fn area(own: *Data, into_saved: bool) void {
    const canvas = own.canvas.?;
    const saved = own.saved.?;
    const right = @min(own.last_left + own.last_width, own.width);
    const bottom = @min(own.last_top + own.last_height, own.height);
    var y = own.last_top;
    while (y < bottom) : (y += 1) {
        var x = own.last_left;
        while (x < right) : (x += 1) {
            const at = y * own.width + x;
            if (into_saved) saved[at] = canvas[at] else canvas[at] = saved[at];
        }
    }
}

/// The next picture drawn onto the canvas, after the last one's area
/// was disposed of. False when the file has no more, or is broken.
fn step(base: *Base, own: *Data) bool {
    const sys = base.sys_base;
    const canvas = own.canvas.?;
    // The last picture's area, as it asked.
    switch (own.last_disposal) {
        decode.dispose_background => {
            const right = @min(own.last_left + own.last_width, own.width);
            const bottom = @min(own.last_top + own.last_height, own.height);
            var y = own.last_top;
            while (y < bottom) : (y += 1) @memset(canvas[y * own.width + own.last_left .. y * own.width + right], 0);
        },
        decode.dispose_previous => area(own, false),
        else => {},
    }

    const file = own.file.?[0..own.file_length];
    const frame = (decode.readNext(file, screenOf(own), own.next_at) catch return false) orelse return false;
    const picture = frame.picture;
    own.last_left = picture.left;
    own.last_top = picture.top;
    own.last_width = picture.width;
    own.last_height = picture.height;
    own.last_disposal = frame.disposal;
    own.last_delay = frame.delay;
    own.next_at = @intCast(frame.next_at);
    own.next_frame += 1;
    if (frame.disposal == decode.dispose_previous) area(own, true);

    // The compressed pixels gathered and unpacked; a picture that will not
    // fit the screen it is on is drawn as far as it does.
    const count = picture.width * picture.height;
    if (count > own.width * own.height) return true;
    const compressed_length = decode.blockBytes(file, picture.data_at) catch return true;
    if (compressed_length == 0) return true;
    const compressed_memory = sys.AllocVec(compressed_length, exec.MEMF_ANY) orelse return true;
    defer sys.FreeVec(compressed_memory);
    const compressed: [*]u8 = @ptrCast(compressed_memory);
    const got = decode.gatherBlocks(file, picture.data_at, compressed[0..compressed_length]);
    const indexes = own.indexes.?;
    own.work.?.* = .{};
    const written = lzw.decode(own.work.?, picture.min_code_size, compressed[0..got], indexes[0..count]) catch |failure| switch (failure) {
        lzw.Error.Corrupt => 0,
        else => count,
    };
    const rows = written / picture.width;
    var n: u32 = 0;
    while (n < rows) : (n += 1) {
        const y = picture.top + decode.rowOf(picture, n);
        if (y >= own.height) continue;
        const row = indexes + n * picture.width;
        var x: u32 = 0;
        while (x < picture.width) : (x += 1) {
            const at_x = picture.left + x;
            if (at_x >= own.width) break;
            const index = row[x];
            if (picture.transparent) |nothing| if (index == nothing) continue;
            canvas[y * own.width + at_x] = penOf(picture.palette, index);
        }
    }
    return true;
}

/// Frame `frame` into the buffer animation.datatype handed over.
fn loadFrame(base: *Base, own: *Data, msg: *adt.AdtFrame) void {
    if (own.canvas == null) return;
    if (msg.frame < own.next_frame or own.next_frame == 0) rewind(own);
    while (own.next_frame <= msg.frame) {
        if (!step(base, own)) break;
    }
    const canvas = own.canvas.?;
    var y: u32 = 0;
    while (y < own.height) : (y += 1) {
        const row: [*]Pen = @ptrCast(@alignCast(@as([*]u8, @ptrCast(msg.pens)) + y * msg.bytes_per_row));
        @memcpy(row[0..own.width], canvas[y * own.width ..][0..own.width]);
    }
    msg.duration = if (own.last_delay <= 1) 100 else own.last_delay * 10;
}

/// The file read, its frames counted and the canvas made. What went
/// wrong, or 0.
fn readFile(base: *Base, cl: *Class, o: *Object, own: *Data, bytes: []u8) i32 {
    const sys = base.sys_base;
    own.file = bytes.ptr;
    own.file_length = @intCast(bytes.len);
    const screen = decode.readScreen(bytes) catch return datatypes.DTERROR_INVALID_DATA;
    own.width = screen.width;
    own.height = screen.height;
    own.background = screen.background;
    own.palette_at = if (screen.palette.len != 0) @intCast(@intFromPtr(screen.palette.ptr) - @intFromPtr(bytes.ptr)) else 0;
    own.palette_length = @intCast(screen.palette.len);
    own.blocks_at = @intCast(screen.at);
    own.frames = decode.countPictures(bytes, screen, max_frames) catch return datatypes.DTERROR_INVALID_DATA;
    if (own.frames == 0) return datatypes.DTERROR_NOT_ENOUGH_DATA;

    const pixels = own.width * own.height;
    // The canvas, what it saves, the unpacked pixels, and the three
    // frames animation.datatype holds.
    if (!subclass.roomFor(sys, @as(usize, pixels) * (4 + 4 + 1 + 3 * 4))) return datatypes.DTERROR_TOO_LARGE;
    own.canvas = @ptrCast(@alignCast(sys.AllocVec(pixels * 4, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return datatypes.DTERROR_NOT_ENOUGH_DATA));
    own.saved = @ptrCast(@alignCast(sys.AllocVec(pixels * 4, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return datatypes.DTERROR_NOT_ENOUGH_DATA));
    own.indexes = @ptrCast(sys.AllocVec(pixels, exec.MEMF_ANY) orelse return datatypes.DTERROR_NOT_ENOUGH_DATA);
    own.work = @ptrCast(@alignCast(sys.AllocVec(@sizeOf(lzw.Work), exec.MEMF_ANY) orelse return datatypes.DTERROR_NOT_ENOUGH_DATA));
    own.next_at = own.blocks_at;

    const tags = [_]TagItem{
        .{ .tag = adt.ADTA_Width, .data = own.width },
        .{ .tag = adt.ADTA_Height, .data = own.height },
        .{ .tag = adt.ADTA_Frames, .data = own.frames },
        .{ .tag = adt.ADTA_FramesPerSecond, .data = 10 },
        .{},
    };
    subclass.superTell(base.intuition_base, cl, o, &tags);
    return 0;
}

fn freeAll(sys: *ExecBase, own: *const Data) void {
    sys.FreeVec(own.file);
    sys.FreeVec(own.canvas);
    sys.FreeVec(own.saved);
    sys.FreeVec(own.indexes);
    sys.FreeVec(own.work);
}

/// datatypes.library's question: whether the file is a GIF with more
/// than one picture. A GIF with one is gif.datatype's.
fn recognise(base: *Base, context: *datatypes.DTHookContext) callconv(.c) bool {
    const sys = base.sys_base;
    const dl: *DosBase = @ptrCast(@alignCast(context.dos_base));
    const file = context.file orelse return false;
    const fib = context.fib orelse return false;
    if (fib.size == 0 or fib.size > recognise_most) return false;
    const length: usize = @intCast(fib.size);
    const memory = sys.AllocVec(length, exec.MEMF_ANY) orelse return false;
    defer sys.FreeVec(memory);
    const bytes: [*]u8 = @ptrCast(memory);
    if (dl.Read(file, bytes, @intCast(length)) != @as(isize, @intCast(length))) return false;
    const screen = decode.readScreen(bytes[0..length]) catch return false;
    const count = decode.countPictures(bytes[0..length], screen, 2) catch return false;
    return count >= 2;
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
            loadFrame(base, classes.instData(Data, cl, o.?), @ptrCast(@alignCast(msg)));
            return 1;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
