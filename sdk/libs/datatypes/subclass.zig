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

/// The whole of the file a lock names, read into memory of its own.
///
/// The lock is the object's and is left as it was: a copy of it is what
/// the file handle takes over, and closing the handle gives that copy
/// back. Null when there is no file, no memory, or the file is empty.
/// What comes back is the caller's to `FreeVec`.
pub fn readWhole(sys: *ExecBase, dl: *DosBase, lock: ?*dos.FileLock) ?[]u8 {
    const copy = dl.DupLock(lock orelse return null) orelse return null;
    const file = dl.OpenFromLock(copy) orelse {
        dl.UnLock(copy);
        return null;
    };
    defer _ = dl.Close(file);

    // A seek answers where the file was, not where it now is, so the
    // size is what the seek back to the beginning hands over.
    if (dl.Seek(file, 0, dos.OFFSET_END) < 0) return null;
    const size = dl.Seek(file, 0, dos.OFFSET_BEGINNING);
    if (size <= 0) return null;
    const length: usize = @intCast(size);
    const memory = sys.AllocVec(length, exec.MEMF_ANY) orelse return null;
    const bytes: [*]u8 = @ptrCast(memory);
    if (dl.Read(file, bytes, @intCast(length)) != @as(isize, @intCast(length))) {
        sys.FreeVec(memory);
        return null;
    }
    return bytes[0..length];
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
