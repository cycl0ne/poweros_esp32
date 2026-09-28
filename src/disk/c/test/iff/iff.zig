// SPDX-License-Identifier: MIT
//! IFF: what is in an IFF file, and a file written and read back. Built
//! against the SDK only.
//!
//!   IFF [FILE] [CLIP]
//!
//! With a file, it walks it one chunk at a time and prints each: how
//! deep it is, its four characters, the kind of the form it is in, and
//! its size. That is `iffparse.library`'s `ParseIFF` with
//! `IFFPARSE_STEP`, which stops at every chunk on the way in and at the
//! end of every chunk on the way out.
//!
//! Without one, it writes `RAM:Test.iff` - a `FORM FTXT` holding a
//! `FVER` and two `CHRS` chunks - and reads it back, keeping the `FVER`
//! as a property and gathering the `CHRS` chunks as a collection, and
//! prints what it found. That is the whole of reading a format: name
//! what is wanted, walk, and take it out of the context.
//!
//! With `CLIP` it does the same to the clipboard rather than to a file:
//! the form is written to `PRIMARY_CLIP` through `InitIFFasClip` and
//! read back from it, which is what one program cutting and another
//! pasting comes to.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const iffparse = sdk.iffparse;
const clipboard = sdk.devices.clipboard;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IFFParseBase = sdk.interface.iffparse.IFFParseBase;
const Printf = dos.stdio.Printf;
const ID = iffparse.MakeID;

pub const COMMAND_NAME = "IFF";
const VERSION_STRING = "\x00$VER: IFF 1.0 (29.09.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FILE,CLIP/S";
const arg_file = 0;
const arg_clip = 1;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOHANDLE = "No IFF handle\n";
const MSG_NOFILE = "Cannot open %s\n";
const MSG_NOTIFF = "%s: not an IFF file (%ld)\n";
const MSG_CHUNK = "%s%s.%s %ld bytes\n";
const MSG_WROTE = "Wrote %s, %ld bytes\n";
const MSG_VERSION = "FVER: %s\n";
const MSG_TEXT = "CHRS: %s\n";
const MSG_DONE = "Read back %ld text chunks\n";
const MSG_NOCLIP = "No clipboard\n";
const MSG_CLIPPED = "Wrote the form to the clipboard, unit %ld\n";

const test_file = "RAM:Test.iff";
const lines = [_][]const u8{ "The first line.", "And the second." };

/// How deep a chunk is, as spaces, so the file's shape can be seen.
fn indentOf(depth: i32, into: *[32]u8) [*:0]const u8 {
    const room: usize = @intCast(@max(@min(depth - 1, 15), 0));
    for (0..room * 2) |i| into[i] = ' ';
    into[room * 2] = 0;
    return @ptrCast(into);
}

/// Every chunk of `name` printed, on the way in and on the way out.
fn walk(dl: *DosBase, ip: *IFFParseBase, name: [*:0]const u8) i32 {
    const file = dl.Open(name, dos.MODE_OLDFILE) orelse {
        _ = Printf(dl, MSG_NOFILE, .{name});
        return dos.RETURN_FAIL;
    };
    defer _ = dl.Close(file);
    const iff = ip.AllocIFF() orelse {
        _ = Printf(dl, MSG_NOHANDLE, .{});
        return dos.RETURN_FAIL;
    };
    defer ip.FreeIFF(iff);
    iff.stream = @intFromPtr(file);
    ip.InitIFFasDOS(iff);
    if (ip.OpenIFF(iff, iffparse.IFFF_READ) != 0) return dos.RETURN_FAIL;
    defer ip.CloseIFF(iff);

    var id_text: [5]u8 = undefined;
    var type_text: [5]u8 = undefined;
    var spaces: [32]u8 = undefined;
    while (true) {
        const answer = ip.ParseIFF(iff, iffparse.IFFPARSE_STEP);
        if (answer == iffparse.IFFERR_EOF) return dos.RETURN_OK;
        // The end of a chunk: nothing to print, the way in already did.
        if (answer == iffparse.IFFERR_EOC) continue;
        if (answer != 0) {
            _ = Printf(dl, MSG_NOTIFF, .{ name, @as(i64, answer) });
            return dos.RETURN_FAIL;
        }
        const chunk = ip.CurrentChunk(iff) orelse continue;
        _ = Printf(dl, MSG_CHUNK, .{
            indentOf(iff.depth, &spaces),
            ip.IDtoStr(chunk.id, &id_text),
            ip.IDtoStr(chunk.type, &type_text),
            @as(i64, chunk.size),
        });
    }
}

/// A form written to `test_file`, and how long it came out.
fn writeOne(dl: *DosBase, ip: *IFFParseBase) i32 {
    const file = dl.Open(test_file, dos.MODE_NEWFILE) orelse {
        _ = Printf(dl, MSG_NOFILE, .{test_file});
        return -1;
    };
    const iff = ip.AllocIFF() orelse {
        _ = dl.Close(file);
        return -1;
    };
    defer ip.FreeIFF(iff);
    iff.stream = @intFromPtr(file);
    ip.InitIFFasDOS(iff);
    if (ip.OpenIFF(iff, iffparse.IFFF_WRITE) != 0) {
        _ = dl.Close(file);
        return -1;
    }
    _ = ip.PushChunk(iff, ID("FTXT"), iffparse.ID_FORM, iffparse.IFFSIZE_UNKNOWN);
    _ = ip.PushChunk(iff, 0, ID("FVER"), 5);
    _ = ip.WriteChunkBytes(iff, "IFF 1", 5);
    _ = ip.PopChunk(iff);
    for (lines) |line| {
        _ = ip.PushChunk(iff, 0, ID("CHRS"), @intCast(line.len));
        _ = ip.WriteChunkBytes(iff, line.ptr, @intCast(line.len));
        _ = ip.PopChunk(iff);
    }
    _ = ip.PopChunk(iff);
    ip.CloseIFF(iff);
    const size = dl.Seek(file, 0, dos.OFFSET_END);
    _ = dl.Close(file);
    return @intCast(size);
}

/// What was written, read back through the context.
fn readOne(dl: *DosBase, ip: *IFFParseBase) i32 {
    const file = dl.Open(test_file, dos.MODE_OLDFILE) orelse {
        _ = Printf(dl, MSG_NOFILE, .{test_file});
        return dos.RETURN_FAIL;
    };
    defer _ = dl.Close(file);
    const iff = ip.AllocIFF() orelse return dos.RETURN_FAIL;
    defer ip.FreeIFF(iff);
    iff.stream = @intFromPtr(file);
    ip.InitIFFasDOS(iff);
    if (ip.OpenIFF(iff, iffparse.IFFF_READ) != 0) return dos.RETURN_FAIL;
    defer ip.CloseIFF(iff);

    _ = ip.PropChunk(iff, ID("FTXT"), ID("FVER"));
    _ = ip.CollectionChunk(iff, ID("FTXT"), ID("CHRS"));
    // The end of the form is where everything it held has been seen.
    _ = ip.StopOnExit(iff, ID("FTXT"), iffparse.ID_FORM);
    const answer = ip.ParseIFF(iff, iffparse.IFFPARSE_SCAN);
    if (answer != iffparse.IFFERR_EOC) {
        _ = Printf(dl, MSG_NOTIFF, .{ test_file, @as(i64, answer) });
        return dos.RETURN_FAIL;
    }

    // A chunk's bytes are not a string: they are copied out and ended.
    var text: [64]u8 = undefined;
    if (ip.FindProp(iff, ID("FTXT"), ID("FVER"))) |version| {
        const size: usize = @intCast(@min(version.size, text.len - 1));
        @memcpy(text[0..size], version.data.?[0..size]);
        text[size] = 0;
        _ = Printf(dl, MSG_VERSION, .{@as([*:0]const u8, @ptrCast(&text))});
    }
    var found: i64 = 0;
    var at = ip.FindCollection(iff, ID("FTXT"), ID("CHRS"));
    while (at) |chunk| : (at = chunk.next) {
        const size: usize = @intCast(@min(chunk.size, text.len - 1));
        @memcpy(text[0..size], chunk.data.?[0..size]);
        text[size] = 0;
        _ = Printf(dl, MSG_TEXT, .{@as([*:0]const u8, @ptrCast(&text))});
        found += 1;
    }
    _ = Printf(dl, MSG_DONE, .{found});
    return dos.RETURN_OK;
}

/// The same form written to the clipboard and read back from it.
fn throughClipboard(dl: *DosBase, ip: *IFFParseBase) i32 {
    const clip = ip.OpenClipboard(clipboard.PRIMARY_CLIP) orelse {
        _ = Printf(dl, MSG_NOCLIP, .{});
        return dos.RETURN_FAIL;
    };
    defer ip.CloseClipboard(clip);

    {
        const iff = ip.AllocIFF() orelse return dos.RETURN_FAIL;
        defer ip.FreeIFF(iff);
        iff.stream = @intFromPtr(clip);
        ip.InitIFFasClip(iff);
        if (ip.OpenIFF(iff, iffparse.IFFF_WRITE) != 0) return dos.RETURN_FAIL;
        _ = ip.PushChunk(iff, ID("FTXT"), iffparse.ID_FORM, iffparse.IFFSIZE_UNKNOWN);
        for (lines) |line| {
            _ = ip.PushChunk(iff, 0, ID("CHRS"), @intCast(line.len));
            _ = ip.WriteChunkBytes(iff, line.ptr, @intCast(line.len));
            _ = ip.PopChunk(iff);
        }
        _ = ip.PopChunk(iff);
        ip.CloseIFF(iff);
    }
    _ = Printf(dl, MSG_CLIPPED, .{@as(i64, clipboard.PRIMARY_CLIP)});

    const iff = ip.AllocIFF() orelse return dos.RETURN_FAIL;
    defer ip.FreeIFF(iff);
    iff.stream = @intFromPtr(clip);
    ip.InitIFFasClip(iff);
    if (ip.OpenIFF(iff, iffparse.IFFF_READ) != 0) return dos.RETURN_FAIL;
    defer ip.CloseIFF(iff);
    _ = ip.CollectionChunk(iff, ID("FTXT"), ID("CHRS"));
    _ = ip.StopOnExit(iff, ID("FTXT"), iffparse.ID_FORM);
    const answer = ip.ParseIFF(iff, iffparse.IFFPARSE_SCAN);
    if (answer != iffparse.IFFERR_EOC) {
        _ = Printf(dl, MSG_NOTIFF, .{ "the clipboard", @as(i64, answer) });
        return dos.RETURN_FAIL;
    }
    var text: [64]u8 = undefined;
    var found: i64 = 0;
    var at = ip.FindCollection(iff, ID("FTXT"), ID("CHRS"));
    while (at) |chunk| : (at = chunk.next) {
        const size: usize = @intCast(@min(chunk.size, text.len - 1));
        @memcpy(text[0..size], chunk.data.?[0..size]);
        text[size] = 0;
        _ = Printf(dl, MSG_TEXT, .{@as([*:0]const u8, @ptrCast(&text))});
        found += 1;
    }
    _ = Printf(dl, MSG_DONE, .{found});
    return dos.RETURN_OK;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [2]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const iff_lib = sys.OpenLibrary(iffparse.IFFPARSENAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{iffparse.IFFPARSENAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(iff_lib);
    const ip: *IFFParseBase = @ptrCast(iff_lib);

    if (argv[arg_clip] != 0) return throughClipboard(dl, ip);
    if (argv[arg_file] != 0) return walk(dl, ip, @ptrFromInt(argv[arg_file]));

    const size = writeOne(dl, ip);
    if (size < 0) return dos.RETURN_FAIL;
    _ = Printf(dl, MSG_WROTE, .{ test_file, @as(i64, size) });
    const answer = readOne(dl, ip);
    if (answer != dos.RETURN_OK) return answer;
    return walk(dl, ip, test_file);
}
