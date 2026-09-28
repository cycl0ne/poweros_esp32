// SPDX-License-Identifier: MIT
//! FixFonts: every family's contents file in FONTS: made again from its
//! directory. Built against the SDK only.
//!
//!   FixFonts
//!
//! In every directory FONTS: stands for, each subdirectory is a family:
//! its contents file `<name>.font` is written anew from the sizes in it
//! (diskfont.library's NewFontContents), or deleted when it holds none.
//! A `<name>.font` with no directory beside it is deleted too: it lists
//! sizes that are gone. A font dropped into a family's directory is found
//! only once this has run. Ctrl-C stops it between families.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const diskfont = sdk.diskfont;
const fontfile = diskfont.fontfile;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const DiskfontBase = sdk.interface.diskfont.DiskfontBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "FixFonts";
const VERSION_STRING = "\x00$VER: FixFonts 1.0 (28.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "";

const MSG_NOLIBRARY = "No %s\n";
const MSG_FAMILY = "%s: %d sizes\n";
const MSG_EMPTY = "%s: no sizes, removed\n";
const MSG_STALE = "%s: no directory, removed\n";
const MSG_NOWRITE = "%s: cannot be written\n";
const MSG_BREAK = "***Break\n";

/// A name as ExNext gave it.
const Name = [32:0]u8;

/// How many names of one directory are taken in: its families and its
/// contents files.
const max_names = 64;

/// A directory's families and contents files, read before any is
/// changed, since writing and deleting while ExNext walks it would move
/// the walk.
const Listing = struct {
    dirs: [max_names]Name = undefined,
    dir_count: usize = 0,
    files: [max_names]Name = undefined,
    file_count: usize = 0,
};

fn copyName(to: *Name, from: [*:0]const u8) bool {
    var i: usize = 0;
    while (from[i] != 0) : (i += 1) {
        if (i == to.len) return false;
        to[i] = from[i];
    }
    to[i] = 0;
    return true;
}

fn lengthOf(name: [*:0]const u8) usize {
    var len: usize = 0;
    while (name[len] != 0) len += 1;
    return len;
}

/// Whether a name ends in ".font", in any case; the length before it.
fn stemOf(name: [*:0]const u8) ?usize {
    const len = lengthOf(name);
    const suffix = ".font";
    if (len <= suffix.len) return null;
    for (suffix, 0..) |c, i| {
        const got = name[len - suffix.len + i];
        if ((if (got >= 'A' and got <= 'Z') got + 32 else got) != c) return null;
    }
    return len - suffix.len;
}

fn list(dl: *DosBase, dir: *dos.FileLock, into: *Listing) void {
    var fib: dos.FileInfoBlock = .{};
    if (!dl.Examine(dir, &fib)) return;
    while (dl.ExNext(dir, &fib)) {
        const name: [*:0]const u8 = @ptrCast(&fib.file_name);
        if (fib.dir_entry_type > 0) {
            if (into.dir_count < max_names and copyName(&into.dirs[into.dir_count], name)) into.dir_count += 1;
        } else if (stemOf(name) != null) {
            if (into.file_count < max_names and copyName(&into.files[into.file_count], name)) into.file_count += 1;
        }
    }
}

/// The families of one FONTS: directory, fixed. Its result code.
fn fixDirectory(sys: *ExecBase, dl: *DosBase, dfb: *DiskfontBase, dir: *dos.FileLock) i32 {
    var listing: Listing = .{};
    list(dl, dir, &listing);
    const was = dl.CurrentDir(dir);
    defer _ = dl.CurrentDir(was);
    var result: i32 = dos.RETURN_OK;

    for (listing.dirs[0..listing.dir_count]) |*family| {
        if (sys.SetSignal(0, 0) & exec.SIGBREAKF_CTRL_C != 0) {
            _ = Printf(dl, MSG_BREAK, .{});
            return dos.RETURN_WARN;
        }
        var font_name: [40:0]u8 = @splat(0);
        const len = lengthOf(family);
        for (0..len) |i| font_name[i] = family[i];
        for (".font", 0..) |c, i| font_name[len + i] = c;
        const made = dfb.NewFontContents(dir, &font_name) orelse {
            // A directory of no sizes has no contents file; one there was
            // goes, and not finding one is no failure.
            if (dl.DeleteFile(&font_name)) _ = Printf(dl, MSG_EMPTY, .{@as([*:0]const u8, &font_name)});
            continue;
        };
        defer dfb.DisposeFontContents(made);
        const size = fontfile.contentsSize(made.count);
        const fh = dl.Open(&font_name, dos.MODE_NEWFILE) orelse {
            _ = Printf(dl, MSG_NOWRITE, .{@as([*:0]const u8, &font_name)});
            result = dos.RETURN_ERROR;
            continue;
        };
        const bytes: [*]const u8 = @ptrCast(made);
        const wrote = dl.Write(fh, bytes, @intCast(size));
        _ = dl.Close(fh);
        if (wrote != size) {
            _ = Printf(dl, MSG_NOWRITE, .{@as([*:0]const u8, &font_name)});
            result = dos.RETURN_ERROR;
            continue;
        }
        _ = Printf(dl, MSG_FAMILY, .{ @as([*:0]const u8, &font_name), @as(u32, made.count) });
    }

    // Contents files whose directory is gone.
    for (listing.files[0..listing.file_count]) |*file| {
        const stem = stemOf(file).?;
        var found = false;
        for (listing.dirs[0..listing.dir_count]) |*family| {
            if (lengthOf(family) != stem) continue;
            var same = true;
            for (0..stem) |i| {
                const a = file[i];
                const b = family[i];
                const la = if (a >= 'A' and a <= 'Z') a + 32 else a;
                const lb = if (b >= 'A' and b <= 'Z') b + 32 else b;
                if (la != lb) same = false;
            }
            if (same) found = true;
        }
        if (found) continue;
        if (dl.DeleteFile(file)) {
            _ = Printf(dl, MSG_STALE, .{@as([*:0]const u8, file)});
        } else {
            result = dos.RETURN_ERROR;
        }
    }
    return result;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [1]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const df_lib = sys.OpenLibrary(diskfont.DISKFONTNAME, diskfont.DISKFONT_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{diskfont.DISKFONTNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(df_lib);
    const dfb: *DiskfontBase = @ptrCast(df_lib);

    const place = dl.GetDeviceProc(diskfont.FONTSNAME, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), diskfont.FONTSNAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeDeviceProc(place);
    var result: i32 = dos.RETURN_OK;
    while (true) {
        const dir = if (place.lock) |lock| dl.DupLock(lock) else dl.Lock(diskfont.FONTSNAME, dos.SHARED_LOCK);
        if (dir) |lock| {
            result = @max(result, fixDirectory(sys, dl, dfb, lock));
            dl.UnLock(lock);
        }
        if (result == dos.RETURN_WARN) break;
        if (place.flags & dos.DVPF_ASSIGN == 0) break;
        if (dl.GetDeviceProc(diskfont.FONTSNAME, place) == null) break;
    }
    return result;
}
