// SPDX-License-Identifier: MIT
//! ascii.datatype: a plain text file, and an IFF `FTXT`, as text.
//!
//! A text.datatype subclass. It reads the source in `OM_NEW` and hands
//! the text over with `TDTM_SETTEXT`; laying it out, drawing it,
//! scrolling it, marking it and copying it are the superclass's.
//!
//! **Both kinds come out as one stretch of text.** A plain file is its
//! bytes; an `FTXT` is its `CHRS` chunks one after another, which is
//! what that form means. Neither says anything about how it is drawn, so
//! the whole of it is one run in the screen's own font, and a document
//! whose looks matter is a format of its own.
//!
//! What the file holds is tidied as it is read: a carriage return before
//! a newline is dropped, so that a file written on another machine does
//! not show a stray character at the end of every line, and a tab is
//! spread to the next multiple of eight, because the text is laid out in
//! a proportional font where a tab has nowhere to stop.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gadgets = sdk.gadgets;
const iffparse = sdk.iffparse;
const datatypes = sdk.datatypes;
const subclass = datatypes.subclass;
const dtc = datatypes.datatypesclass;
const tdc = datatypes.textclass;
const IFFParseBase = sdk.interface.iffparse.IFFParseBase;
const DosBase = sdk.interface.dos.DosBase;
const Class = classes.Class;
const Object = classes.Object;
const Base = gadgets.Base;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = "ascii.datatype",
    .version = 1,
    .date = "29.09.2026",
    .super = tdc.TEXTDTCLASS,
    .opens = &.{ tdc.TEXT_LIBRARY, iffparse.IFFPARSENAME },
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// ascii.datatype's part of an object: nothing. The text is the
/// superclass's the moment it has been read.
pub const Data = extern struct {
    unused: u32 = 0,
};

/// How far apart a tab's stops are.
const tab_stop = 8;

/// The four characters an IFF text form is called, and the chunk its
/// text is in.
const ID_FTXT = iffparse.MakeID("FTXT");
const ID_CHRS = iffparse.MakeID("CHRS");

/// What the file holds, tidied: how many bytes it comes to, and, when
/// `into` is given, written there.
fn tidy(from: []const u8, into: ?[*]u8) u32 {
    var out: u32 = 0;
    var column: u32 = 0;
    for (from) |byte| {
        switch (byte) {
            '\r' => {},
            '\t' => {
                const stop = (column / tab_stop + 1) * tab_stop;
                while (column < stop) : (column += 1) {
                    if (into) |it| it[out] = ' ';
                    out += 1;
                }
            },
            '\n' => {
                if (into) |it| it[out] = '\n';
                out += 1;
                column = 0;
            },
            else => {
                if (into) |it| it[out] = byte;
                out += 1;
                column += 1;
            },
        }
    }
    return out;
}

/// Whether what was read is an IFF text form rather than plain bytes.
fn isForm(from: []const u8) bool {
    if (from.len < 12) return false;
    return iffparse.MakeID("FORM") == word(from[0..]) and ID_FTXT == word(from[8..]);
}

fn word(from: []const u8) u32 {
    return @as(u32, from[0]) << 24 | @as(u32, from[1]) << 16 |
        @as(u32, from[2]) << 8 | from[3];
}

/// The `CHRS` chunks of a form joined: how many bytes they come to, and,
/// when `into` is given, written there.
///
/// The chunks are walked by hand rather than through iffparse's
/// collection handler, because what is wanted is one stretch of text and
/// not a list of pieces, and the walk is four lines either way.
fn gatherChrs(from: []const u8, into: ?[*]u8) u32 {
    var at: usize = 12; // past FORM, its length and the form's type
    var out: u32 = 0;
    while (at + 8 <= from.len) {
        const id = word(from[at..]);
        const length = word(from[at + 4 ..]);
        if (at + 8 + length > from.len) break;
        if (id == ID_CHRS) {
            const body = from[at + 8 ..][0..length];
            out += tidy(body, if (into) |it| it + out else null);
        }
        // A chunk's length is rounded up to an even number of bytes.
        at += 8 + length + (length & 1);
    }
    return out;
}

/// The text read and given to the superclass. What went wrong, or 0.
fn takeText(base: *Base, cl: *Class, o: *Object, from: []const u8) i32 {
    const sys = base.sys_base;
    const form = isForm(from);
    const length = if (form) gatherChrs(from, null) else tidy(from, null);
    if (length == 0) return datatypes.DTERROR_NOT_ENOUGH_DATA;

    const text = sys.AllocVec(length, exec.MEMF_ANY) orelse
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    const buffer: [*]u8 = @ptrCast(text);
    _ = if (form) gatherChrs(from, buffer) else tidy(from, buffer);

    const runs = sys.AllocVec(@sizeOf(tdc.Piece), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        sys.FreeVec(text);
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    };
    const pieces: [*]tdc.Piece = @ptrCast(@alignCast(runs));
    pieces[0] = .{ .offset = 0, .length = length };

    var msg = tdc.TdtSetText{
        .buffer = buffer,
        .buffer_len = length,
        .pieces = pieces,
        .piece_count = 1,
    };
    if (base.intuition_base.SendSuperMessage(cl, o, @ptrCast(&msg)) == 0) {
        sys.FreeVec(text);
        sys.FreeVec(runs);
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    }
    return 0;
}

/// What is on a clipboard unit, read into memory of its own.
fn readClip(base: *Base, ip: *IFFParseBase, handle: ?*anyopaque) ?[]u8 {
    const sys = base.sys_base;
    const iff: *iffparse.IFFHandle = @ptrCast(@alignCast(handle orelse return null));
    // The library opened the clip and walked as far as its first form.
    if (ip.StopChunk(iff, ID_FTXT, ID_CHRS) != 0) return null;
    var length: usize = 0;
    var gathered: ?[*]u8 = null;
    // Two walks are not possible on a clip that is read once, so the
    // text grows as the chunks come.
    while (ip.ParseIFF(iff, iffparse.IFFPARSE_SCAN) == 0) {
        const chunk = ip.CurrentChunk(iff) orelse continue;
        if (chunk.id != ID_CHRS or chunk.size <= 0) continue;
        const size: usize = @intCast(chunk.size);
        const bigger = sys.AllocVec(length + size, exec.MEMF_ANY) orelse break;
        const into: [*]u8 = @ptrCast(bigger);
        if (gathered) |old| {
            @memcpy(into[0..length], old[0..length]);
            sys.FreeVec(old);
        }
        if (ip.ReadChunkBytes(iff, into + length, chunk.size) != chunk.size) {
            sys.FreeVec(bigger);
            break;
        }
        gathered = into;
        length += size;
    }
    const text = gathered orelse return null;
    return text[0..length];
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

            const source = subclass.superAsk(ib, cl, obj, dtc.DTA_SourceType);
            const handle: ?*anyopaque = @ptrFromInt(subclass.superAsk(ib, cl, obj, dtc.DTA_Handle));
            const found: subclass.Read = if (source == dtc.DTST_CLIPBOARD)
                (if (readClip(base, @ptrCast(base.opened[1] orelse return 0), handle)) |clip|
                    .{ .got = clip }
                else
                    .no_file)
            else
                subclass.readWhole(base.sys_base, dl, @ptrCast(@alignCast(handle)));
            const read = switch (found) {
                .got => |bytes| bytes,
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
            const failure = takeText(base, cl, obj, read);
            base.sys_base.FreeVec(read.ptr);
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
