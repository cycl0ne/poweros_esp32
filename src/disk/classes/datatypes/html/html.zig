// SPDX-License-Identifier: MIT
//! html.datatype: an HTML page as text.
//!
//! A text.datatype subclass. It reads the file in `OM_NEW`, turns it
//! into the text a reader sees, the runs it is drawn as and the blocks
//! they are in, and hands all three over with `TDTM_SETTEXT`; laying it
//! out, drawing it, scrolling it, marking it and copying it are the
//! superclass's. The page's `<title>` is the object's name.
//!
//! It is drawn as text.datatype draws a document: headings in steps of
//! size and in bold; paragraphs a line apart; lists under discs, circles
//! and squares, numbers, Roman numerals and letters; a quote behind a
//! bar; `<pre>` in the fixed font on a ground of its own; a table of rows
//! and columns in lines, its head in bold and every other row shaded;
//! code in a sentence on a ground of its own; a link in its own colour,
//! underlined, with the address it leads to kept for the program to
//! follow. How the page is read is parse.zig's.
//!
//! **What is drawn is the markup's.** A style sheet is not read, a
//! script is not run, and a picture is not fetched: what its `alt` text
//! says it is stands in its place, in italic. A page that lays itself out
//! by its style sheet reads top to bottom, its parts one under another.
//!
//! **Its characters are Latin-1**: a page in UTF-8 is made Latin-1 before
//! it is read, and a character Latin-1 has not - one of typesetting's
//! aside, which come out plain - is a `?`.
//!
//! The file is read in two passes: the first counts how much text, how
//! many runs and how many blocks there will be, the second writes them.
//! That is how the three are allocated exactly once and exactly large
//! enough.

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
const TagItem = utility.TagItem;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = "html.datatype",
    .version = 1,
    .revision = 0,
    .date = "09.11.2026",
    .super = tdc.TEXTDTCLASS,
    .opens = &.{tdc.TEXT_LIBRARY},
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// html.datatype's part of an object: the page's title, which the
/// object's name points at. The text is the superclass's the moment it
/// has been read.
pub const Data = extern struct {
    title: [parse.title_most + 1]u8 = @splat(0),
};

/// The page read and given to the superclass. What went wrong, or 0.
fn takeText(base: *Base, cl: *Class, o: *Object, document: []u8) i32 {
    const sys = base.sys_base;
    const ub = base.utility_base;
    const from = document[0..parse.toLatin1(ub, document)];

    var counting = parse.Build{ .ub = ub };
    parse.build(from, &counting);
    if (counting.text_len == 0 or counting.piece_count == 0 or counting.block_count == 0)
        return datatypes.DTERROR_NOT_ENOUGH_DATA;

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
    const blocks = sys.AllocVec(counting.block_count * @sizeOf(tdc.Block), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        sys.FreeVec(text);
        sys.FreeVec(runs);
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    };

    var writing = parse.Build{
        .ub = ub,
        .text = @ptrCast(text),
        .pieces = @ptrCast(@alignCast(runs)),
        .blocks = @ptrCast(@alignCast(blocks)),
        .link_base = counting.text_len,
    };
    parse.build(from, &writing);

    const own = classes.instData(Data, cl, o);
    own.title = writing.title;
    if (writing.title_len > 0) {
        subclass.superTell(base.intuition_base, cl, o, &[_]TagItem{
            .{ .tag = dtc.DTA_ObjName, .data = @intFromPtr(&own.title) },
            .{},
        });
    }

    var msg = tdc.TdtSetText{
        .buffer = @ptrCast(text),
        .buffer_len = writing.text_len,
        .pieces = @ptrCast(@alignCast(runs)),
        .piece_count = writing.piece_count,
        .blocks = @ptrCast(@alignCast(blocks)),
        .block_count = writing.block_count,
    };
    if (base.intuition_base.SendSuperMessage(cl, o, @ptrCast(&msg)) == 0) {
        sys.FreeVec(text);
        sys.FreeVec(runs);
        sys.FreeVec(blocks);
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

            const bytes = switch (subclass.readSource(base.sys_base, dl, ib, cl, obj)) {
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
