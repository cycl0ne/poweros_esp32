// SPDX-License-Identifier: MIT
//! What every format's class does, in one place.
//!
//! A class that reads a format has the same three jobs whatever the
//! format is: reach the attributes its superclass holds, read the file
//! the object was given, and hand what it found over. None of that is
//! format work, and none of it belongs in each class again.
//!
//! **The object's source is a lock, not an open file.** The lock stays
//! the object's - datatypesclass closes it when the object goes - so
//! `readWhole` opens a copy of it and closes that, and the object is
//! left as it was found.

const exec = @import("../exec/exec.zig");
const dos = @import("../dos/dos.zig");
const utility = @import("../utility/utility.zig");
const intuition = @import("../intuition/intuition.zig");
const classes = intuition.classes;
const classusr = intuition.classusr;
const pictureclass = @import("pictureclass.zig");
const ExecBase = @import("../../interface/exec.zig").ExecBase;
const DosBase = @import("../../interface/dos.zig").DosBase;
const IntuitionBase = @import("../../interface/intuition.zig").IntuitionBase;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;

/// Attributes set on the superclass, which is where everything a format
/// class finds out about the contents belongs.
pub fn superTell(ib: *IntuitionBase, cl: *Class, o: *Object, tags: [*]const TagItem) void {
    var set = classusr.OpSet{
        .method_id = classusr.OM_SET,
        .attr_list = tags,
        .gadget_info = null,
    };
    _ = ib.SendSuperMessage(cl, o, @ptrCast(&set));
}

/// One of the superclass's attributes read back.
pub fn superAsk(ib: *IntuitionBase, cl: *Class, o: *Object, attr: utility.Tag) usize {
    var storage: usize = 0;
    var get = classusr.OpGet{
        .method_id = classusr.OM_GET,
        .attr_id = attr,
        .storage = &storage,
    };
    if (ib.SendSuperMessage(cl, o, @ptrCast(&get)) == 0) return 0;
    return storage;
}

/// What `readWhole` found.
pub const Read = union(enum) {
    /// The file, the caller's to `FreeVec`.
    got: []u8,
    /// There was no file, or it is empty, or it could not be read.
    no_file,
    /// There is one, and it is larger than the machine can hold. It is
    /// worth telling apart: a file that will not fit is not a file that
    /// will not open, and a person reading the one message would go
    /// looking for the wrong thing.
    too_large,
};

/// The whole of the file a lock names, read into memory of its own.
///
/// The lock is the object's and is left as it was: a copy of it is what
/// the file handle takes over, and closing the handle gives that copy
/// back.
pub fn readWhole(sys: *ExecBase, dl: *DosBase, lock: ?*dos.FileLock) Read {
    const copy = dl.DupLock(lock orelse return .no_file) orelse return .no_file;
    const file = dl.OpenFromLock(copy) orelse {
        dl.UnLock(copy);
        return .no_file;
    };
    defer _ = dl.Close(file);

    // A seek answers where the file was, not where it now is, so the
    // size is what the seek back to the beginning hands over.
    if (dl.Seek(file, 0, dos.OFFSET_END) < 0) return .no_file;
    const size = dl.Seek(file, 0, dos.OFFSET_BEGINNING);
    if (size <= 0) return .no_file;
    const length: usize = @intCast(size);
    if (!roomFor(sys, length)) return .too_large;
    const memory = sys.AllocVec(length, exec.MEMF_ANY) orelse return .too_large;
    const bytes: [*]u8 = @ptrCast(memory);
    if (dl.Read(file, bytes, @intCast(length)) != @as(isize, @intCast(length))) {
        sys.FreeVec(memory);
        return .no_file;
    }
    return .{ .got = bytes[0..length] };
}

/// Whether a block of `bytes` could be had, with a little room to
/// spare.
///
/// A class asks this as soon as it knows how big the picture is, before
/// it reads anything: a file larger than the machine can hold is
/// refused with `DTERROR_TOO_LARGE`, which says what happened, rather
/// than failing at whichever allocation happened to be the one that
/// did not fit.
///
/// It answers against the largest free block rather than the total,
/// because what a picture needs is one block.
pub fn roomFor(sys: *ExecBase, bytes: usize) bool {
    // A tenth over, so that the row buffers and the object itself are
    // not what tips it.
    const wanted = bytes + bytes / 10;
    if (wanted < bytes) return false; // more than an address can say
    return sys.AvailMem(exec.MEMF_ANY | exec.MEMF_LARGEST) >= wanted;
}

/// How many bytes a picture of this size is once it is kept as pens.
/// `~0` when the size itself is past what an address can say.
pub fn pictureBytes(width: u32, height: u32) usize {
    if (width == 0 or height == 0) return 0;
    const pixels = @as(usize, width) * height;
    if (pixels / width != height) return ~@as(usize, 0);
    return pixels * 4;
}

/// How much a picture of this size must be shrunk to fit: 1, 2, 4 or 8,
/// and 0 when not even an eighth of each side will fit.
///
/// `working` is what the class holds beside the picture while it reads
/// it - a JPEG's planes, a PNG's unpacked rows - which does not shrink
/// with the picture and so sets the floor.
pub fn shrinkFor(sys: *ExecBase, width: u32, height: u32, working: usize) u32 {
    var by: u32 = 1;
    while (by <= 8) : (by *= 2) {
        const bytes = pictureBytes(shrunk(width, by), shrunk(height, by));
        if (bytes == ~@as(usize, 0)) continue;
        if (roomFor(sys, bytes + working)) return by;
    }
    return 0;
}

/// A length shrunk by `by`, never to nothing.
pub fn shrunk(value: u32, by: u32) u32 {
    return @max(value / by, 1);
}

/// Every `by`-th pixel of a row of colour, moved down to the front of
/// it. How many are left.
///
/// The nearest pixel is taken rather than the average of the ones
/// between: a picture shrunk to be looked at is shrunk again by the
/// drawing when the window is smaller still, and two smoothings of a
/// photograph cost more than they give.
pub fn thinRow(rgba: [*]u8, count: u32, by: u32) u32 {
    if (by <= 1) return count;
    var out: u32 = 0;
    var x: u32 = 0;
    while (x < count) : (x += by) {
        // The first pixel is already where it belongs, and a copy onto
        // itself is two names for one block of memory.
        if (out != x) @memcpy((rgba + out * 4)[0..4], (rgba + x * 4)[0..4]);
        out += 1;
    }
    return out;
}

/// What the file said the picture was, told to picture.datatype beside
/// the size that is being kept.
pub fn setSource(ib: *IntuitionBase, cl: *Class, o: *Object, width: u32, height: u32, by: u32) void {
    const tags = [_]TagItem{
        .{ .tag = pictureclass.PDTA_SourceWidth, .data = width },
        .{ .tag = pictureclass.PDTA_SourceHeight, .data = height },
        .{ .tag = pictureclass.PDTA_ShrunkBy, .data = by },
        .{},
    };
    superTell(ib, cl, o, &tags);
}

/// The picture's shape told to picture.datatype, which is what gives the
/// object its size and the memory to hold the pixels. False when there
/// was no memory for it.
pub fn setPicture(ib: *IntuitionBase, cl: *Class, o: *Object, header: *const pictureclass.BitMapHeader, source_mode: u32) bool {
    const tags = [_]TagItem{
        .{ .tag = pictureclass.PDTA_BitMapHeader, .data = @intFromPtr(header) },
        .{ .tag = pictureclass.PDTA_SourceMode, .data = source_mode },
        .{},
    };
    superTell(ib, cl, o, &tags);
    return superAsk(ib, cl, o, pictureclass.PDTA_Pixels) != 0;
}

/// A rectangle of pixels handed to picture.datatype in the shape the
/// caller has them.
pub fn putPixels(ib: *IntuitionBase, cl: *Class, o: *Object, left: u32, top: u32, width: u32, height: u32, format: u32, bytes_per_row: u32, data: [*]u8) void {
    var msg = pictureclass.PdtBlitPixelArray{
        .method_id = pictureclass.PDTM_WRITEPIXELARRAY,
        .pixel_data = data,
        .format = format,
        .bytes_per_row = bytes_per_row,
        .left = left,
        .top = top,
        .width = width,
        .height = height,
    };
    _ = ib.SendSuperMessage(cl, o, @ptrCast(&msg));
}

/// One row of colour handed over, `count` pixels wide.
pub fn putRow(ib: *IntuitionBase, cl: *Class, o: *Object, left: u32, top: u32, count: u32, rgba: [*]u8) void {
    putPixels(ib, cl, o, left, top, count, 1, pictureclass.PBPAFMT_RGBA, count * 4, rgba);
}
