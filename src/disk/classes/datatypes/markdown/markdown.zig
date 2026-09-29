// SPDX-License-Identifier: MIT
//! markdown.datatype: a Markdown document as text.
//!
//! A text.datatype subclass. It reads the file in `OM_NEW`, turns it
//! into the text a reader sees and the runs it is drawn as, and hands
//! both over with `TDTM_SETTEXT`; laying it out, drawing it, scrolling
//! it, marking it and copying it are the superclass's.
//!
//! What the marks become: a heading in a larger font where the family
//! has one and in bold where it has not, emphasis in italic and strong
//! emphasis in bold, a listing in the fixed font, a list item under its
//! mark and indented, a quoted line indented and set back in the shadow
//! pen, a rule a line of its own, and a link underlined in the fill pen
//! with the name it leads to kept for the program to follow.
//!
//! **A picture is not fetched.** What its text says it is stands in its
//! place, in italic. A document that reads one picture out of a drawer
//! beside it would have to open a second file, and what is being shown
//! is the document.
//!
//! The file is read in two passes: the first counts how much text and
//! how many runs there will be, the second writes them. That is how the
//! two blocks are allocated exactly once and exactly large enough.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gadgets = sdk.gadgets;
const datatypes = sdk.datatypes;
const subclass = datatypes.subclass;
const dtc = datatypes.datatypesclass;
const tdc = datatypes.textclass;
const parse = @import("parse.zig");
const DosBase = sdk.interface.dos.DosBase;
const Class = classes.Class;
const Object = classes.Object;
const Base = gadgets.Base;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = "markdown.datatype",
    .version = 1,
    .date = "29.09.2026",
    .super = tdc.TEXTDTCLASS,
    .opens = &.{tdc.TEXT_LIBRARY},
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// markdown.datatype's part of an object: nothing. The text is the
/// superclass's the moment it has been read.
pub const Data = extern struct {
    unused: u32 = 0,
};

/// The document read and given to the superclass. What went wrong, or 0.
fn takeText(base: *Base, cl: *Class, o: *Object, from: []const u8) i32 {
    const sys = base.sys_base;

    var counting = parse.Build{};
    parse.build(from, &counting);
    if (counting.text_len == 0 or counting.piece_count == 0) return datatypes.DTERROR_NOT_ENOUGH_DATA;

    // The text, and the link targets after it: they are in the same
    // block because a run says where its target is as an offset into
    // it, and past the end is where nothing draws them.
    const whole = counting.text_len + counting.link_len;
    const text = sys.AllocVec(whole, exec.MEMF_ANY) orelse
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    const runs = sys.AllocVec(counting.piece_count * @sizeOf(tdc.Piece), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        sys.FreeVec(text);
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    };

    var writing = parse.Build{
        .text = @ptrCast(text),
        .pieces = @ptrCast(@alignCast(runs)),
        .link_base = counting.text_len,
    };
    parse.build(from, &writing);

    var msg = tdc.TdtSetText{
        .buffer = @ptrCast(text),
        .buffer_len = writing.text_len,
        .pieces = @ptrCast(@alignCast(runs)),
        .piece_count = writing.piece_count,
    };
    if (base.intuition_base.SendSuperMessage(cl, o, @ptrCast(&msg)) == 0) {
        sys.FreeVec(text);
        sys.FreeVec(runs);
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    }
    return 0;
}

fn dispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *Class = @ptrCast(hook);
    const base = gadgets.baseOf(cl);
    const ib = base.intuition_base;
    const msg: *classusr.Msg = @ptrCast(@alignCast(message orelse return 0));
    const o: ?*Object = @ptrCast(object);

    switch (msg.method_id) {
        classusr.OM_NEW => {
            const made = ib.SendSuperMessage(cl, o, msg);
            if (made == 0) return 0;
            const obj: *Object = @ptrFromInt(made);
            const dos_lib = base.sys_base.OpenLibrary(dos.DOSNAME, 0) orelse {
                ib.DisposeObject(obj);
                return 0;
            };
            const dl: *DosBase = @ptrCast(dos_lib);
            defer base.sys_base.CloseLibrary(dos_lib);

            const lock: ?*dos.FileLock = @ptrFromInt(subclass.superAsk(ib, cl, obj, dtc.DTA_Handle));
            const bytes = subclass.readWhole(base.sys_base, dl, lock) orelse {
                _ = dl.SetIoErr(datatypes.DTERROR_COULDNT_OPEN);
                ib.DisposeObject(obj);
                return 0;
            };
            const failure = takeText(base, cl, obj, bytes);
            base.sys_base.FreeVec(bytes.ptr);
            if (failure != 0) {
                _ = dl.SetIoErr(failure);
                ib.DisposeObject(obj);
                return 0;
            }
            return made;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
