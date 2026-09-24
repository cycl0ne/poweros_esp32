// SPDX-License-Identifier: MIT
//! Type: files written to the output, as a program on disk, built as a load
//! file by sdk/tools/elf2seg.
//!
//! `TYPE [FROM] [TO file] [OPT h|n] [HEX] [NUMBER]`: the files to the output,
//! plainly, with line numbers (NUMBER, `OPT n`) or as hex (HEX, `OPT h`).
//! Each FROM may be a pattern, and every match is typed in turn. Ctrl-C
//! stops it.
//!
//! FROM is optional. Without it Type copies its own input, so it can stand
//! at the end of a pipeline (`echo hello | type`); a pipe read by name
//! (`type PIPE:ll`) works too. A last line without a newline gets one, HEX
//! and NUMBER together is refused, and an unknown OPT
//! letter is only reported.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

const NAME = "Type";
const VERSION_STRING = "\x00$VER: Type 1.0 (16.9.2026)\r\n";

/// The line buffer, and 16 bytes a row for HEX.
const out_size = 255;
const hex_row = 16;

const Mode = enum { plain, number, hex };

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [5]usize = @splat(0);
    const rda = dl.ReadArgs("FROM/M,TO/K,OPT/K,HEX/S,NUMBER/S", &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), NAME);
        return dos.RETURN_ERROR;
    };
    defer dl.FreeArgs(rda);

    // HEX and NUMBER, from the switches and from OPT's letters.
    var hex = argv[3] != 0;
    var number = argv[4] != 0;
    if (rdargs.string(argv[2])) |opt| {
        var i: usize = 0;
        while (opt[i] != 0) : (i += 1) {
            switch (opt[i] | 0x20) {
                'h' => hex = true,
                'n' => number = true,
                else => _ = Printf(dl, "Option '%c' ignored\n", .{opt[i]}),
            }
        }
    }
    if (hex and number) {
        _ = dl.PutStr("Type can't do both HEX and NUMBER\n");
        return dos.RETURN_WARN;
    }
    const mode: Mode = if (hex) .hex else if (number) .number else .plain;

    const to = if (rdargs.string(argv[1])) |name| dl.Open(name, dos.MODE_NEWFILE) orelse {
        _ = Printf(dl, "TYPE can't open %s\n", .{name});
        return dos.RETURN_ERROR;
    } else null;
    defer if (to) |fh| {
        _ = dl.Close(fh);
    };
    const old_out = dl.Output();
    if (to) |fh| _ = dl.SelectOutput(fh);
    defer if (to != null) {
        _ = dl.SelectOutput(old_out);
    };

    // No file: our own input, so Type can end a pipeline.
    const files = rdargs.multi(argv[0]);
    if (files.len == 0) {
        const code = typeFile(dl, dl.Input(), mode);
        return finish(dl, code);
    }

    var code: i32 = 0;
    for (files) |pattern| {
        code = typePattern(dl, pattern, mode);
        if (code != 0) break;
    }
    return finish(dl, code);
}

/// What the return code says about an error (a break is a warning).
fn finish(dl: *DosBase, code: i32) i32 {
    if (code == 0) return dos.RETURN_OK;
    if (code == dos.ERROR_BREAK) {
        // "***Break", so a Ctrl-C that stopped a long file says it did;
        // output that just stops looks like a file that just ended.
        _ = dl.PrintFault(code, null);
        _ = dl.SetIoErr(code);
        return dos.RETURN_WARN;
    }
    _ = dl.PrintFault(code, NAME);
    _ = dl.SetIoErr(code);
    return dos.RETURN_ERROR;
}

/// Every file the pattern matches, typed in turn.
fn typePattern(dl: *DosBase, pattern: [*:0]const u8, mode: Mode) i32 {
    var anchor: AnchorBuffer = .{};
    anchor.ap.strlen = @intCast(anchor.path.len);
    anchor.ap.break_bits = exec.SIGBREAKF_CTRL_C;
    var code = dl.MatchFirst(pattern, &anchor.ap);
    if (code != 0) {
        if (code == dos.ERROR_NO_MORE_ENTRIES or code == dos.ERROR_OBJECT_NOT_FOUND) {
            _ = Printf(dl, "TYPE can't open %s\n", .{pattern});
            dl.MatchEnd(&anchor.ap);
            return 0;
        }
        dl.MatchEnd(&anchor.ap);
        return code;
    }
    defer dl.MatchEnd(&anchor.ap);
    while (true) {
        const current = anchor.ap.last orelse break;
        if (anchor.ap.info.dir_entry_type < 0) { // a file, not a directory
            const old = dl.CurrentDir(current.lock);
            const fh = dl.Open(@ptrCast(&anchor.ap.info.file_name), dos.MODE_OLDFILE);
            _ = dl.CurrentDir(old);
            if (fh) |file| {
                const result = typeFile(dl, file, mode);
                _ = dl.Close(file);
                if (result != 0) return result;
            } else {
                _ = Printf(dl, "TYPE can't open %s\n", .{@as([*:0]const u8, @ptrCast(&anchor.ap.info.file_name))});
            }
        }
        code = dl.MatchNext(&anchor.ap);
        if (code != 0) return if (code == dos.ERROR_NO_MORE_ENTRIES) 0 else code;
    }
    return 0;
}

/// An AnchorPath with room for the path it fills in.
const AnchorBuffer = extern struct {
    ap: dos.AnchorPath = .{},
    path: [256]u8 = @splat(0),
};

/// The handle to the output in the mode given. 0, or the
/// error that stopped it (ERROR_BREAK after Ctrl-C).
fn typeFile(dl: *DosBase, fh: ?*dos.FileHandle, mode: Mode) i32 {
    var out: [out_size + 2]u8 = undefined;
    var used: usize = 0;
    var counter: u32 = 0;
    var numbered = mode == .number; // a line cut in two keeps one number
    var pending = false;

    while (true) {
        const c = dl.FGetC(fh);
        if (c < 0) break;
        const byte: u8 = @truncate(@as(u32, @bitCast(c)));
        switch (mode) {
            .hex => {
                out[used] = byte;
                used += 1;
                pending = true;
                if (used == hex_row) {
                    hexRow(dl, out[0..used], counter);
                    counter += hex_row;
                    used = 0;
                    pending = false;
                }
            },
            .plain, .number => {
                out[used] = byte;
                used += 1;
                pending = true;
                if (used == out_size - 1) {
                    // Too long for one line: it goes out as it is, and the
                    // rest keeps the same number.
                    out[used] = 0;
                    textRow(dl, out[0..used :0], if (numbered) counter + 1 else null);
                    if (mode == .number) numbered = false;
                    used = 0;
                    pending = false;
                } else if (byte == '\n') {
                    out[used] = 0;
                    textRow(dl, out[0..used :0], if (numbered) counter + 1 else null);
                    if (mode == .number) numbered = true;
                    counter += 1;
                    used = 0;
                    pending = false;
                }
            },
        }
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) return dos.ERROR_BREAK;
    }
    // What is left of an unfinished line (a file whose last line has no
    // newline still gets one).
    if (pending) {
        if (mode == .hex) {
            hexRow(dl, out[0..used], counter);
        } else {
            if (used == 0 or out[used - 1] != '\n') {
                out[used] = '\n';
                used += 1;
            }
            out[used] = 0;
            textRow(dl, out[0..used :0], if (numbered) counter + 1 else null);
        }
    }
    return 0;
}

fn textRow(dl: *DosBase, line: [:0]const u8, number: ?u32) void {
    if (number) |n| {
        _ = Printf(dl, "%5d %s", .{ n, line });
    } else {
        _ = dl.PutStr(line.ptr);
    }
}

/// One row of HEX: the offset, sixteen bytes, then their printable form.
fn hexRow(dl: *DosBase, bytes: []const u8, offset: u32) void {
    const digits = "0123456789ABCDEF";
    var row: [64]u8 = @splat(' ');
    for (bytes, 0..) |b, i| {
        // Grouped in fours: two digits per byte, a space between.
        const at = i * 2 + (i >> 2);
        row[at] = digits[b >> 4];
        row[at + 1] = digits[b & 15];
        row[39 + i] = if ((b +% 1) & 0x7F <= ' ') '.' else b;
    }
    row[39 + bytes.len] = 0;
    _ = Printf(dl, "%04x: %s\n", .{ offset, @as([:0]const u8, row[0 .. 39 + bytes.len :0]) });
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs: the linker collects unused
/// sections, and a plain constant never reaches the file at all - which is
/// all the comptime reference that used to stand here achieved.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
