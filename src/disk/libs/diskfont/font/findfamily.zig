// SPDX-License-Identifier: MIT
//! FindFamily: the family of FONTS: a name stands for, by the name its
//! fonts give themselves or by its contents file's.
//!
//! Every directory of FONTS: is walked, as AvailFonts walks them, and
//! each `.font` file's header read - the name is in the first bytes, so
//! the entries are not. A family whose fonts give the name is the one;
//! of several, one that is no face of another (`sans.font`, not
//! `sans-bold.font`, whose fonts call themselves the same), else the
//! first found. Failing a family by that name, the contents file whose
//! name is `name` and ".font".

const sdk = @import("sdk");
const dos = sdk.dos;
const diskfont = sdk.diskfont;
const fontfile = sdk.diskfont.fontfile;
const _base = @import("../diskfont_base.zig");
const DiskfontBase = _base.DiskfontBase;
const opendiskfont = @import("opendiskfont.zig");

/// The family a name stands for: what its fonts call themselves, or its
/// contents file's name.
///
/// SYNOPSIS:
/// ```zig
/// fn FindFamily(dfb: *DiskfontBase, name: [*:0]const u8, into: [*]u8, size: u32) bool
/// ```
///
/// SINCE: 1.16. LVO -52.
///
/// INPUTS:
/// - `name` - the family as a document names it: "Noto Sans", "noto
///   sans", or a contents file's name without ".font", "sans". UTF-8.
/// - `into` - where the family's contents file's name goes:
///   "noto-sans.font", a NUL after it.
/// - `size` - how many bytes `into` holds.
///
/// RESULT:
/// True, the name in `into`. False when FONTS: has no such family, or
/// for a name and its NUL that `size` cannot hold; `into` is then left
/// as it was.
///
/// BEHAVIOR:
/// A family is found by the name its contents file says its fonts give
/// themselves - a TrueType or OpenType file's typographic family, as
/// `NewFontContents` reads it - compared without regard to the case of
/// ASCII letters. The faces of a family give the same name: of
/// several, the family that is no face of another one (`sans.font`
/// before `sans-bold.font`) is the answer, else the first found. Failing
/// that, a contents file of the name and ".font", in any case. Every
/// directory FONTS: is assigned to is looked in, in the assign's order.
///
/// The name answered is what `OpenOutlineFont`,
/// `OpenOutlineFontTagList` and `OpenDiskFont` take.
///
/// CONTEXT:
/// - Waits: yes: for the disk.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Process, since it reads files.
///
/// OWNERSHIP:
/// `name` and `into` are the caller's.
///
/// NOTES:
/// It reads the header of every contents file in FONTS: each time; a
/// program that looks up the same names often keeps the answers.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// GenericFamily, OpenOutlineFontTagList, NewFontContents, AvailFonts
///
/// EXAMPLES:
/// ```zig
/// var family: [64]u8 = undefined;
/// if (dfb.FindFamily("Noto Sans", &family, family.len)) {
///     const font = dfb.OpenOutlineFontTagList(@ptrCast(&family), null);
///     defer dfb.CloseOutlineFont(font);
/// }
/// ```
pub fn FindFamily(dfb: *DiskfontBase, name: [*:0]const u8, into: [*]u8, size: u32) bool {
    var len: usize = 0;
    while (name[len] != 0) len += 1;
    if (len == 0) return false;
    var found = Found{};
    walk(dfb, name[0..len], &found);
    const answer = if (found.family_len != 0) found.family[0..found.family_len] else if (found.file_len != 0) found.file[0..found.file_len] else return false;
    if (answer.len + 1 > size) return false;
    @memcpy(into[0..answer.len], answer);
    into[answer.len] = 0;
    return true;
}

/// What the walk has found so far: the family by its fonts' name, and
/// whether that one is a face of another; the contents file by its own.
const Found = struct {
    family: [dos.name_max]u8 = undefined,
    family_len: usize = 0,
    family_is_face: bool = false,
    file: [dos.name_max]u8 = undefined,
    file_len: usize = 0,
};

/// Every directory of FONTS:, each looked through.
fn walk(dfb: *DiskfontBase, name: []const u8, found: *Found) void {
    const dl = dfb.dos_base;
    // An assign of several directories is walked in the one DevProc,
    // which moves on to the next each time and is still to be freed when
    // there is no next.
    const place = dl.GetDeviceProc(diskfont.FONTSNAME, null) orelse return;
    defer dl.FreeDeviceProc(place);
    while (true) {
        const dir = if (place.lock) |lock| dl.DupLock(lock) else dl.Lock(diskfont.FONTSNAME, dos.SHARED_LOCK);
        if (dir) |lock| {
            lookThrough(dfb, lock, name, found);
            dl.UnLock(lock);
        }
        if (found.family_len != 0 and !found.family_is_face) return;
        if (place.flags & dos.DVPF_ASSIGN == 0) break;
        if (dl.GetDeviceProc(diskfont.FONTSNAME, place) == null) break;
    }
}

/// The `.font` files of one directory, each header read.
fn lookThrough(dfb: *DiskfontBase, dir: *dos.FileLock, name: []const u8, found: *Found) void {
    const dl = dfb.dos_base;
    var fib: dos.FileInfoBlock = .{};
    if (!dl.Examine(dir, &fib)) return;
    const was = dl.CurrentDir(dir);
    defer _ = dl.CurrentDir(was);
    while (dl.ExNext(dir, &fib)) {
        if (dos.isDirectory(fib.dir_entry_type)) continue;
        const file: [*:0]const u8 = @ptrCast(&fib.file_name);
        var file_len: usize = 0;
        while (file[file_len] != 0) file_len += 1;
        const suffix = ".font";
        if (file_len <= suffix.len or !same(file[file_len - suffix.len .. file_len], suffix)) continue;
        const stem = file[0 .. file_len - suffix.len];
        if (found.file_len == 0 and same(stem, name)) {
            @memcpy(found.file[0..file_len], file[0..file_len]);
            found.file_len = file_len;
        }
        if (found.family_len != 0 and !found.family_is_face) continue;
        var header: fontfile.ContentsHeader = .{};
        if (!readHeader(dfb, file, &header)) continue;
        if (!same(fontfile.familyOf(&header), name)) continue;
        const is_face = isFace(stem);
        if (found.family_len != 0 and is_face) continue;
        @memcpy(found.family[0..file_len], file[0..file_len]);
        found.family_len = file_len;
        found.family_is_face = is_face;
    }
}

/// The header of the contents file `file`, in the current directory;
/// false for a file too short or of another layout.
fn readHeader(dfb: *DiskfontBase, file: [*:0]const u8, header: *fontfile.ContentsHeader) bool {
    const dl = dfb.dos_base;
    const fh = dl.Open(file, dos.MODE_OLDFILE) orelse return false;
    defer _ = dl.Close(fh);
    const size = @sizeOf(fontfile.ContentsHeader);
    if (dl.Read(fh, @ptrCast(header), size) != size) return false;
    return header.magic == fontfile.MAGIC and header.version == fontfile.VERSION and header.family[fontfile.MAXFONTFAMILY - 1] == 0;
}

/// Whether a contents file's name, ".font" off, is a face of another
/// family's: it ends in one of the faces' suffixes.
fn isFace(stem: []const u8) bool {
    for (opendiskfont.faces) |face| {
        if (stem.len > face.suffix.len and same(stem[stem.len - face.suffix.len ..], face.suffix)) return true;
    }
    return false;
}

/// Two names the same but for the case of ASCII letters.
fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (lower(x) != lower(y)) return false;
    }
    return true;
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}
