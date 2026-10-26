// SPDX-License-Identifier: MIT
//! Hash: the digests of files, written as a list, and a list read back
//! with every file it names checked against its digest. Built against the
//! SDK only.
//!
//!   Hash FILE/M,ALGO/K,CHECK/S,TO/K,ALL/S,QUIET/S
//!
//!   Hash #?.lha                  a SHA-256 line for each archive
//!   Hash Work: ALL TO=RAM:sums   everything below Work:, into a list
//!   Hash file ALGO=CRC32         the CRC-32 a zip or an SFV file holds
//!   Hash CHECK RAM:sums          each file the list names, read again
//!
//! ALGO is CRC32, MD5, SHA1, SHA224, SHA256 (what it is without ALGO),
//! SHA384 or SHA512, in either case and with or without a `-` after SHA.
//! CRC-32 is worked out here; the others come from crypto.library, which
//! is opened only when one of them is asked for.
//!
//! **A list** is sha256sum's, so one made here checks on any other
//! system and one made there checks here: a line per file, the digest in
//! lower-case hex, two spaces, the name as the pattern reached it.
//! Reading, BSD's tagged lines and SFV files are taken as well
//! (digests.zig has the forms). FILE takes patterns; a directory is
//! stepped into with ALL, skipped when a pattern reached it, and an error
//! when named on its own. With no FILE at all, Hash reads its input and
//! names it `-`. TO writes the list to a file instead of the output, and
//! a pattern that reaches the list itself leaves it out.
//!
//! **CHECK** turns FILE into lists: each line's file is opened by its
//! name, from the current directory as the names were written, and said
//! to be OK or FAILED; a file that cannot be read is named with the
//! reason. QUIET leaves the OKs out. The algorithm of a line is what ALGO
//! says, else the line's tag, else the length of its digest - with ALGO,
//! a line made with another one is not understood. A line that is not
//! understood is passed over and counted.
//!
//! It ends with 0 when every file was read (and, with CHECK, matched), 5
//! when one was not, 10 when a list had no line it understood, 20 when it
//! could not start.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const crypto = sdk.crypto;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;
const FPrintf = dos.stdio.FPrintf;
const digests = @import("digests.zig");
const Algorithm = digests.Algorithm;

pub const COMMAND_NAME = "Hash";
const VERSION_STRING = "\x00$VER: Hash 1.0 (25.10.2026)\r\n";

const template = "FILE/M,ALGO/K,CHECK/S,TO/K,ALL/S,QUIET/S";
const arg_file = 0;
const arg_algo = 1;
const arg_check = 2;
const arg_to = 3;
const arg_all = 4;
const arg_quiet = 5;

const MSG_BADALGO = "%s: no algorithm %s - CRC32, MD5, SHA1, SHA224, SHA256, SHA384 or SHA512\n";
const MSG_CHECKARGS = "%s: CHECK takes neither TO nor ALL\n";
const MSG_NOLIBRARY = "%s: cannot open %s\n";
const MSG_NOHASH = "%s: this %s has no %s\n";
const MSG_OK = "%s: OK\n";
const MSG_FAILED = "%s: FAILED\n";
const MSG_EMPTYLIST = "%s: %s has no line naming a file and its digest\n";
const MSG_MISMATCHES = "%s: %u of %u %s not match\n";
const MSG_UNREAD = "%s: %u %s not be read\n";
const MSG_MALFORMED = "%s: %u %s not understood\n";

/// What one Read takes in: large enough that the hash, not the calls,
/// is what a large file costs.
const read_size = 64 * 1024;
/// The longest line a list holds: a name of dos's full length with every
/// character two bytes in UTF-8, escaped, behind the longest digest.
const line_max = 1 + 2 * digests.digest_max + 2 + 2 * dos.path_max + 2;

const Anchor = extern struct {
    ap: dos.AnchorPath = .{},
    buf: [dos.path_max]u8 = @splat(0),
};

/// The command's state, allocated once: the buffers are too large for a
/// command's stack.
const Run = struct {
    sys: *ExecBase,
    dl: *DosBase,
    /// crypto.library once an algorithm of its has been asked for.
    crypto_lib: ?*exec.Library,
    /// ALGO, or null when it was not given.
    algorithm: ?Algorithm,
    quiet: bool,
    all: bool,
    /// Where the list's lines go.
    list: ?*dos.FileHandle,
    /// TO's directory and its entry, to know the list when a pattern
    /// reaches it.
    to_parent: ?*dos.FileLock,
    to_info: dos.FileInfoBlock,
    /// Set by Ctrl-C, by a list that cannot be written, or by an
    /// algorithm that cannot be had: nothing more is done.
    stop: bool,
    /// Ctrl-C was what stopped it.
    broken: bool,
    /// The files checked, and those that did not match, could not be
    /// read, and the lines not understood.
    checked: u32,
    failed: u32,
    unread: u32,
    malformed: u32,
    /// A list with no line understood.
    empty_list: bool,
    anchor: Anchor,
    line: [line_max]u8,
    name: [dos.path_max + 1]u8,
    buffer: [read_size]u8,
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [6]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const check = argv[arg_check] != 0;
    const to = rdargs.string(argv[arg_to]);
    if (check and (to != null or argv[arg_all] != 0)) {
        _ = Printf(dl, MSG_CHECKARGS, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    }
    var algorithm: ?Algorithm = null;
    if (rdargs.string(argv[arg_algo])) |text| {
        algorithm = Algorithm.of(spanOf(text)) orelse {
            _ = Printf(dl, MSG_BADALGO, .{ COMMAND_NAME, text });
            return dos.RETURN_FAIL;
        };
    }

    const memory = sys.AllocVec(@sizeOf(Run), exec.MEMF_ANY) orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const run: *Run = @ptrCast(@alignCast(memory));
    run.sys = sys;
    run.dl = dl;
    run.crypto_lib = null;
    run.algorithm = algorithm;
    run.quiet = argv[arg_quiet] != 0;
    run.all = argv[arg_all] != 0;
    run.list = dl.Output();
    run.to_parent = null;
    run.stop = false;
    run.broken = false;
    run.checked = 0;
    run.failed = 0;
    run.unread = 0;
    run.malformed = 0;
    run.empty_list = false;
    defer if (run.crypto_lib) |crypto_lib| sys.CloseLibrary(crypto_lib);

    if (!check) {
        // An algorithm crypto.library lacks is said once, before anything
        // is read.
        if (hasher(run, algorithm orelse .sha256) == null and algorithm != .crc32) return dos.RETURN_FAIL;
    }

    var to_file: ?*dos.FileHandle = null;
    if (to) |to_name| {
        to_file = dl.Open(to_name, dos.MODE_NEWFILE) orelse {
            _ = dl.PrintFault(dl.IoErr(), to_name);
            return dos.RETURN_FAIL;
        };
        run.list = to_file;
        if (dl.ExamineFH(to_file, &run.to_info)) run.to_parent = dl.ParentOfFH(to_file);
    }

    const files = rdargs.multi(argv[arg_file]);
    if (files.len == 0) {
        if (check) checkList(run, dl.Input(), "-") else hashFile(run, dl.Input(), "-");
    } else for (files) |pattern| {
        walk(run, pattern, check);
        if (run.stop) break;
    }

    if (run.to_parent) |parent| dl.UnLock(parent);
    if (to_file) |file| {
        if (!dl.Close(file)) {
            run.unread += 1;
            _ = dl.PrintFault(dl.IoErr(), to.?);
        }
    }
    _ = dl.Flush(dl.Output());

    const errors = dl.ErrorOutput() orelse dl.Output();
    if (check and run.failed != 0) _ = FPrintf(dl, errors, MSG_MISMATCHES, .{ COMMAND_NAME, run.failed, run.checked, plural(run.checked, "file did", "files did") });
    if (check and run.unread != 0) _ = FPrintf(dl, errors, MSG_UNREAD, .{ COMMAND_NAME, run.unread, plural(run.unread, "file could", "files could") });
    if (run.malformed != 0) _ = FPrintf(dl, errors, MSG_MALFORMED, .{ COMMAND_NAME, run.malformed, plural(run.malformed, "line was", "lines were") });

    if (run.broken) {
        _ = dl.PrintFault(dos.ERROR_BREAK, null);
        return dos.RETURN_WARN;
    }
    if (run.stop) return dos.RETURN_FAIL;
    if (run.empty_list) return dos.RETURN_ERROR;
    if (run.failed != 0 or run.unread != 0) return dos.RETURN_WARN;
    return dos.RETURN_OK;
}

/// Every entry `pattern` reaches: a file hashed into the list, or with
/// CHECK read as a list.
fn walk(run: *Run, pattern: [*:0]const u8, check: bool) void {
    const dl = run.dl;
    const ap = &run.anchor.ap;
    run.anchor = .{};
    ap.strlen = run.anchor.buf.len;
    ap.break_bits = exec.SIGBREAKF_CTRL_C;
    ap.flags = dos.APF_DOWILD;

    var err = dl.MatchFirst(pattern, ap);
    defer dl.MatchEnd(ap);
    while (err == 0 or err == dos.ERROR_BUFFER_OVERFLOW) : (err = dl.MatchNext(ap)) {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
            err = dos.ERROR_BREAK;
            break;
        }
        if (ap.flags & dos.APF_DIDDIR != 0) {
            // On the way out of a directory, already stepped into.
            ap.flags &= ~dos.APF_DIDDIR;
            continue;
        }
        const path: [*:0]const u8 = @ptrCast(ap.buffer());
        if (err == dos.ERROR_BUFFER_OVERFLOW) {
            // A path cut to fit names no file a list could hold.
            run.unread += 1;
            reportFault(run, err, path);
            continue;
        }
        if (dos.isDirectory(ap.info.dir_entry_type)) {
            if (run.all) {
                ap.flags |= dos.APF_DODIR;
            } else if (ap.flags & dos.APF_ITSWILD == 0) {
                run.unread += 1;
                reportFault(run, dos.ERROR_OBJECT_WRONG_TYPE, path);
            }
            continue;
        }
        if (!check and isList(run, ap)) continue;

        // Opened from its own directory: the path is the name the list
        // shows, which a deep tree may make longer than a name dos opens.
        const here = dl.CurrentDir(entryDirectory(ap));
        const file = dl.Open(@ptrCast(&ap.info.file_name), dos.MODE_OLDFILE);
        const open_error = dl.IoErr();
        _ = dl.CurrentDir(here);
        const opened = file orelse {
            run.unread += 1;
            reportFault(run, open_error, path);
            continue;
        };
        defer _ = dl.Close(opened);
        if (check) checkList(run, opened, path) else hashFile(run, opened, path);
        if (run.stop) return;
    }
    if (err == dos.ERROR_BREAK) {
        run.broken = true;
        run.stop = true;
    } else if (err != dos.ERROR_NO_MORE_ENTRIES) {
        run.unread += 1;
        reportFault(run, err, pattern);
    }
}

/// The directory a matched entry is in.
fn entryDirectory(ap: *dos.AnchorPath) ?*dos.FileLock {
    return if (ap.last) |node| node.lock else null;
}

/// Whether the entry is the list TO is writing.
fn isList(run: *Run, ap: *dos.AnchorPath) bool {
    const parent = run.to_parent orelse return false;
    if (!sameName(@ptrCast(&ap.info.file_name), @ptrCast(&run.to_info.file_name))) return false;
    var directory = entryDirectory(ap);
    if (directory == null) {
        directory = run.dl.CurrentDir(null);
        _ = run.dl.CurrentDir(directory);
    }
    return run.dl.SameLock(parent, directory) == dos.LOCK_SAME;
}

/// Two dos names alike, case aside.
fn sameName(left: [*:0]const u8, right: [*:0]const u8) bool {
    var at: usize = 0;
    while (true) : (at += 1) {
        if (upperLatin1(left[at]) != upperLatin1(right[at])) return false;
        if (left[at] == 0) return true;
    }
}

fn upperLatin1(char: u8) u8 {
    return switch (char) {
        'a'...'z', 0xE0...0xF6, 0xF8...0xFE => char - 0x20,
        else => char,
    };
}

/// One file's line, into the list.
fn hashFile(run: *Run, file: ?*dos.FileHandle, path: [*:0]const u8) void {
    var digest: [digests.digest_max]u8 = undefined;
    const length = digestOf(run, file, run.algorithm orelse .sha256, &digest) orelse {
        if (run.stop) return;
        run.unread += 1;
        reportFault(run, run.dl.IoErr(), path);
        return;
    };
    const line_length = digests.formatLine(digest[0..length], spanOf(path), &run.line) orelse {
        run.unread += 1;
        reportFault(run, dos.ERROR_LINE_TOO_LONG, path);
        return;
    };
    if (run.dl.FWrite(run.list, &run.line, @intCast(line_length)) != line_length) {
        reportFault(run, run.dl.IoErr(), null);
        run.stop = true;
    }
}

/// Every line of a list checked.
fn checkList(run: *Run, file: ?*dos.FileHandle, list_name: [*:0]const u8) void {
    const dl = run.dl;
    var understood: u32 = 0;
    while (dl.FGets(file, &run.line, run.line.len)) |_| {
        const raw = spanOf(@ptrCast(&run.line));
        if (raw.len == run.line.len - 1 and raw[raw.len - 1] != '\n') {
            // Longer than any line a list has: the rest of it passed over.
            while (dl.FGets(file, &run.line, run.line.len)) |_| {
                const more = spanOf(@ptrCast(&run.line));
                if (more[more.len - 1] == '\n') break;
            }
            run.malformed += 1;
            continue;
        }
        var entry: digests.Entry = .{};
        switch (digests.parseLine(raw, &entry, run.name[0 .. run.name.len - 1])) {
            .nothing => continue,
            .malformed => {
                run.malformed += 1;
                continue;
            },
            .entry => {},
        }
        const algorithm = algorithmOf(run, &entry) orelse {
            run.malformed += 1;
            continue;
        };
        understood += 1;
        checkEntry(run, &entry, algorithm);
        if (run.stop) return;
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
            run.broken = true;
            run.stop = true;
            return;
        }
    }
    if (understood == 0) {
        run.empty_list = true;
        _ = dl.Flush(dl.Output());
        _ = FPrintf(dl, dl.ErrorOutput() orelse dl.Output(), MSG_EMPTYLIST, .{ COMMAND_NAME, list_name });
    }
}

/// The algorithm a list's line is checked with, or null when ALGO rules
/// it out.
fn algorithmOf(run: *Run, entry: *const digests.Entry) ?Algorithm {
    if (entry.algorithm) |tagged| {
        if (run.algorithm) |wanted| if (wanted != tagged) return null;
        return tagged;
    }
    if (run.algorithm) |wanted| return if (wanted.length() == entry.digest_len) wanted else null;
    return Algorithm.ofDigits(2 * entry.digest_len);
}

/// One file of a list read and its digest compared.
fn checkEntry(run: *Run, entry: *const digests.Entry, algorithm: Algorithm) void {
    const dl = run.dl;
    run.name[entry.name.len] = 0;
    const name: [*:0]const u8 = @ptrCast(&run.name);
    run.checked += 1;
    const file = dl.Open(name, dos.MODE_OLDFILE) orelse {
        run.unread += 1;
        reportFault(run, dl.IoErr(), name);
        return;
    };
    defer _ = dl.Close(file);
    var digest: [digests.digest_max]u8 = undefined;
    const length = digestOf(run, file, algorithm, &digest) orelse {
        if (run.stop) return;
        run.unread += 1;
        reportFault(run, dl.IoErr(), name);
        return;
    };
    var same = length == entry.digest_len;
    if (same) for (digest[0..length], entry.digest[0..length]) |got, want| {
        if (got != want) same = false;
    };
    if (!same) {
        run.failed += 1;
        _ = Printf(dl, MSG_FAILED, .{name});
    } else if (!run.quiet) {
        _ = Printf(dl, MSG_OK, .{name});
    }
}

/// The digest of what is left of `file`: its length, or null with IoErr
/// set when it could not be read, or with `stop` set when Ctrl-C or a
/// missing algorithm ended it.
fn digestOf(run: *Run, file: ?*dos.FileHandle, algorithm: Algorithm, digest: *[digests.digest_max]u8) ?usize {
    const dl = run.dl;
    var crc = digests.crc_start;
    var context: crypto.HashContext = .{};
    var engine: ?*CryptoBase = null;
    if (algorithm != .crc32) {
        engine = hasher(run, algorithm) orelse {
            run.stop = true;
            return null;
        };
        _ = engine.?.InitHash(&context, cryptoAlgorithm(algorithm));
    }
    while (true) {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
            run.broken = true;
            run.stop = true;
            return null;
        }
        const got = dl.Read(file, &run.buffer, run.buffer.len);
        if (got < 0) return null;
        if (got == 0) break;
        const bytes = run.buffer[0..@intCast(got)];
        if (engine) |cb| cb.UpdateHash(&context, bytes.ptr, @intCast(bytes.len)) else crc = digests.crcAdd(crc, bytes);
    }
    if (engine) |cb| return cb.FinishHash(&context, digest);
    digests.crcDigest(crc, digest[0..4]);
    return 4;
}

/// crypto.library, opened the first time it is needed, when it has
/// `algorithm`; null (and said) when it cannot be had. CRC-32 needs none.
fn hasher(run: *Run, algorithm: Algorithm) ?*CryptoBase {
    if (algorithm == .crc32) return null;
    const dl = run.dl;
    const crypto_lib = run.crypto_lib orelse open: {
        const opened = run.sys.OpenLibrary(crypto.CRYPTONAME, 1) orelse {
            _ = dl.Flush(dl.Output());
            _ = FPrintf(dl, dl.ErrorOutput() orelse dl.Output(), MSG_NOLIBRARY, .{ COMMAND_NAME, crypto.CRYPTONAME });
            return null;
        };
        run.crypto_lib = opened;
        break :open opened;
    };
    const cb: *CryptoBase = @ptrCast(crypto_lib);
    var context: crypto.HashContext = .{};
    if (cb.InitHash(&context, cryptoAlgorithm(algorithm)) != 0) {
        _ = dl.Flush(dl.Output());
        _ = FPrintf(dl, dl.ErrorOutput() orelse dl.Output(), MSG_NOHASH, .{ COMMAND_NAME, crypto.CRYPTONAME, algorithm.name().ptr });
        return null;
    }
    return cb;
}

fn cryptoAlgorithm(algorithm: Algorithm) u32 {
    return switch (algorithm) {
        .crc32 => unreachable,
        .md5 => crypto.HASH_MD5,
        .sha1 => crypto.HASH_SHA1,
        .sha224 => crypto.HASH_SHA224,
        .sha256 => crypto.HASH_SHA256,
        .sha384 => crypto.HASH_SHA384,
        .sha512 => crypto.HASH_SHA512,
    };
}

/// A fault on the error stream, after what the output holds so far.
fn reportFault(run: *Run, code: i32, header: ?[*:0]const u8) void {
    _ = run.dl.Flush(run.dl.Output());
    _ = run.dl.PrintFault(code, header);
}

fn plural(count: u32, one: [*:0]const u8, many: [*:0]const u8) [*:0]const u8 {
    return if (count == 1) one else many;
}

fn spanOf(text: [*:0]const u8) []const u8 {
    var length: usize = 0;
    while (text[length] != 0) length += 1;
    return text[0..length];
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
