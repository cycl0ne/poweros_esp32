// SPDX-License-Identifier: MIT
//! Recognising a file: what is looked at, and what each descriptor says
//! about it.
//!
//! A source is opened once (`Source.of`) and every descriptor is then
//! tried against the one reading: the file's name, the first bytes of
//! it, and, when it is IFF, the type of its outermost form. A
//! descriptor that names a `RECOGNISE` class is asked last, and only
//! when whatever else it says has already matched, so that opening a
//! class library is the rare case and not the rule.
//!
//! The descriptors are tried in the order `AddDataTypes` sorted them,
//! highest priority first, so a format that says a lot about itself is
//! recognised before the catch-alls at the end.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const datatypes = sdk.datatypes;
const iffparse = sdk.iffparse;
const dtc = datatypes.datatypesclass;
const _base = @import("../datatypes_base.zig");
const DataTypesBase = _base.DataTypesBase;

/// What is known about the thing being recognised.
pub const Source = extern struct {
    kind: u32 = dtc.DTST_FILE,
    /// The lock, for a file; the open IFF handle, for the clipboard.
    lock: ?*dos.FileLock = null,
    file: ?*dos.FileHandle = null,
    iff: ?*iffparse.IFFHandle = null,
    /// Whether this library opened the IFF handle and must close it.
    owns_iff: u8 = 0,
    /// The outermost form's type, 0 when it is not IFF.
    form_type: u32 = 0,
    pad: [3]u8 = @splat(0),
    fib: dos.FileInfoBlock = .{},
    /// The first bytes of it, and how many were read.
    buffer: [_base.sniff_bytes]u8 = @splat(0),
    buffer_length: u32 = 0,
};

/// The name of the file, out of what `Examine` said.
pub fn nameOf(source: *const Source) [*:0]const u8 {
    return @ptrCast(&source.fib.file_name);
}

/// A source opened and looked at: what `ObtainDataTypeA` was handed,
/// made ready for every descriptor to be tried against. False when it
/// cannot be read at all.
pub fn open(db: *DataTypesBase, source: *Source, kind: u32, handle: ?*anyopaque) bool {
    const dl = db.dos_base;
    const ip = db.iffparse_base;
    source.* = .{ .kind = kind };
    switch (kind) {
        dtc.DTST_FILE => {
            source.lock = @ptrCast(@alignCast(handle orelse return false));
            if (!dl.Examine(source.lock, &source.fib)) return false;
            // A directory holds no bytes to look at.
            if (source.fib.dir_entry_type > 0) return true;
            // OpenFromLock takes the lock it is given, so a copy of it
            // is opened and the caller keeps its own.
            const copy = dl.DupLock(source.lock) orelse return true;
            source.file = dl.OpenFromLock(copy) orelse {
                dl.UnLock(copy);
                return true;
            };
            const got = dl.Read(source.file.?, &source.buffer, source.buffer.len);
            source.buffer_length = @intCast(@max(got, 0));
            _ = dl.Seek(source.file.?, 0, dos.OFFSET_BEGINNING);
            source.form_type = formTypeOfFile(db, source);
        },
        dtc.DTST_CLIPBOARD => {
            source.iff = @ptrCast(@alignCast(handle orelse return false));
            const chunk = ip.CurrentChunk(source.iff.?) orelse return false;
            source.form_type = chunk.type;
        },
        else => return false,
    }
    return true;
}

pub fn close(db: *DataTypesBase, source: *Source) void {
    if (source.file) |file| _ = db.dos_base.Close(file);
    source.file = null;
}

/// The outermost form's type, by walking one step into the file; 0 when
/// it is not IFF.
fn formTypeOfFile(db: *DataTypesBase, source: *Source) u32 {
    const ip = db.iffparse_base;
    const file = source.file orelse return 0;
    const iff = ip.AllocIFF() orelse return 0;
    defer ip.FreeIFF(iff);
    iff.stream = @intFromPtr(file);
    ip.InitIFFasDOS(iff);
    if (ip.OpenIFF(iff, iffparse.IFFF_READ) != 0) return 0;
    defer ip.CloseIFF(iff);
    var form_type: u32 = 0;
    if (ip.ParseIFF(iff, iffparse.IFFPARSE_STEP) == 0) {
        if (ip.CurrentChunk(iff)) |chunk| form_type = chunk.type;
    }
    _ = db.dos_base.Seek(file, 0, dos.OFFSET_BEGINNING);
    return form_type;
}

/// The bytes at the start of the file against a descriptor's mask: `?`
/// in the mask stands for any byte.
fn maskMatches(header: *const datatypes.DataTypeHeader, source: *const Source) bool {
    const mask = header.mask orelse return false;
    const any = header.mask_any orelse return false;
    if (source.buffer_length < header.mask_len) return false;
    for (0..header.mask_len) |i| {
        if (any[i] != 0) continue;
        if (mask[i] != source.buffer[i]) return false;
    }
    return true;
}

/// A descriptor tried against what was read.
pub fn matches(db: *DataTypesBase, dt: *datatypes.DataType, source: *Source) bool {
    const header = dt.header;
    const kind = header.flags & datatypes.DTF_TYPE_MASK;

    // A directory matches only a descriptor that says it is for one.
    const is_dir = source.kind == dtc.DTST_FILE and source.fib.dir_entry_type > 0;
    if (is_dir != (header.flags & datatypes.DTF_DIRECTORY != 0)) return false;

    var said_something = false;
    if (kind == datatypes.DTF_IFF) {
        if (source.form_type == 0 or source.form_type != header.id) return false;
        said_something = true;
    } else if (source.kind == dtc.DTST_CLIPBOARD) {
        // Nothing but IFF ever reaches the clipboard.
        return false;
    }
    if (header.mask != null) {
        if (!maskMatches(header, source)) return false;
        said_something = true;
    }
    if (header.pattern) |pattern| {
        if (source.kind != dtc.DTST_FILE) return false;
        const name = nameOf(source);
        const ub = db.utility_base;
        // The pattern was parsed when the descriptor was read, with or
        // without regard to case, and is matched the same way.
        const matched = if (header.flags & datatypes.DTF_CASE != 0)
            ub.MatchPattern(pattern, name)
        else
            ub.MatchPatternNoCase(pattern, name);
        if (!matched) return false;
        said_something = true;
    }
    // A descriptor that says nothing of its own catches whatever is left
    // of its kind: plain text, or plain bytes.
    if (!said_something and kind == datatypes.DTF_ASCII and !looksLikeText(source)) return false;

    if (header.flags & datatypes.DTF_RECOGNISE != 0) return asksTheClass(db, dt, source);
    return true;
}

/// Whether what was read is text: printable characters, tabs and line
/// ends, and nothing else.
pub fn looksLikeText(source: *const Source) bool {
    if (source.buffer_length == 0) return false;
    for (0..source.buffer_length) |i| {
        const c = source.buffer[i];
        if (c == '\n' or c == '\r' or c == '\t' or c == 0x0C) continue;
        if (c < ' ' or c == 0x7F) return false;
    }
    return true;
}

/// The class asked whether the file is one of its own: its library is
/// opened for the question and closed again.
fn asksTheClass(db: *DataTypesBase, dt: *datatypes.DataType, source: *Source) bool {
    const sys = db.sys_base;
    var name: [64]u8 = @splat(0);
    if (!className(dt.header.base_name, &name)) return false;
    const lib = sys.OpenLibrary(@ptrCast(&name), 0) orelse return false;
    defer sys.CloseLibrary(lib);
    const recognise = lib.vector(datatypes.RecogniseFn, datatypes.DTRECOGNISE_LVO);
    var context = datatypes.DTHookContext{
        .sys_base = @ptrCast(sys),
        .dos_base = @ptrCast(db.dos_base),
        .iffparse_base = @ptrCast(db.iffparse_base),
        .utility_base = @ptrCast(db.utility_base),
        .lock = source.lock,
        .fib = &source.fib,
        .file = source.file,
        .iff = source.iff,
        .buffer = &source.buffer,
        .buffer_length = source.buffer_length,
    };
    const answer = recognise(@ptrCast(lib), &context);
    if (source.file) |file| _ = db.dos_base.Seek(file, 0, dos.OFFSET_BEGINNING);
    return answer;
}

/// `datatypes/<base>.datatype` written into `into`. False when it does
/// not fit.
pub fn className(base_name: [*:0]const u8, into: *[64]u8) bool {
    const prefix = datatypes.class_prefix;
    const suffix = datatypes.class_suffix;
    var len: usize = 0;
    while (base_name[len] != 0) len += 1;
    if (prefix.len + len + suffix.len + 1 > into.len) return false;
    @memcpy(into[0..prefix.len], prefix);
    @memcpy(into[prefix.len..][0..len], base_name[0..len]);
    @memcpy(into[prefix.len + len ..][0..suffix.len], suffix);
    into[prefix.len + len + suffix.len] = 0;
    return true;
}
