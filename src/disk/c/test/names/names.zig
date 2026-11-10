// SPDX-License-Identifier: MIT
//! Names: makes, finds, matches and deletes files whose names go past
//! ASCII, each step printed with PASS or FAIL. Built against the SDK only.
//!
//!   Names DIR/A,KEEP/S
//!
//! In a directory of its own under DIR (`NamesTest`, removed at the end),
//! each name of the list - a letter past Latin-1, the euro sign, a Greek
//! word, an emoji, a German word in UTF-8 and one in Latin-1 - is made as
//! a file holding its own name, then found by Lock, found again written
//! in the other case, looked for in an ExNext listing under the name it
//! is kept as - in UTF-8, the one given in Latin-1 too - matched by a
//! pattern with `?` for its first character (one entry, that one),
//! deleted by its name in the other case, and looked for once more, which
//! must fail. The labels are ASCII, so the
//! report reads on any console. With KEEP each name is made once more at
//! the end and the directory left, for a look at how the names show
//! (`NamesTest` must then be gone before the next run). RETURN_OK when
//! every step passed, RETURN_ERROR when one failed.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const FileInfoBlock = dos.FileInfoBlock;
const FileLock = dos.FileLock;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Names";
const VERSION_STRING = "\x00$VER: Names 1.2 (10.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "DIR/A,KEEP/S";
const arg_dir = 0;
const arg_keep = 1;

const MSG_PASS = "PASS  %s: %s\n";
const MSG_FAIL = "FAIL  %s: %s (error %ld)\n";
const MSG_RESULT = "%u of %u steps passed\n";

/// The directory the test works in, under DIR.
const work_name = "NamesTest";
/// Room for DIR, the work directory and a name.
const path_max = 512;

/// A name, the same name in the other case, what to call it, and the
/// name it is kept as when that is not the name itself.
const Name = struct {
    label: [*:0]const u8,
    name: [:0]const u8,
    other_case: [:0]const u8,
    kept_as: ?[:0]const u8 = null,

    fn kept(name: *const Name) [:0]const u8 {
        return name.kept_as orelse name.name;
    }
};

const names = [_]Name{
    .{ .label = "A with macron", .name = "\xC4\x80", .other_case = "\xC4\x81" },
    .{ .label = "euro sign", .name = "\xE2\x82\xAC.txt", .other_case = "\xE2\x82\xAC.TXT" },
    .{ .label = "Greek", .name = "\xCE\xA9\xCE\xBC\xCE\xAD\xCE\xB3\xCE\xB1", .other_case = "\xCF\x89\xCE\x9C\xCE\x88\xCE\x93\xCE\x91" },
    .{ .label = "emoji", .name = "\xF0\x9F\x98\x80smile", .other_case = "\xF0\x9F\x98\x80SMILE" },
    .{ .label = "UTF-8 umlaut", .name = "M\xC3\xBCll", .other_case = "m\xC3\x9CLL" },
    .{ .label = "Latin-1 umlaut", .name = "Gr\xFCn", .other_case = "GR\xC3\x9CN", .kept_as = "Gr\xC3\xBCn" },
};

/// How the steps went.
const Tally = struct {
    dl: *DosBase,
    steps: u32 = 0,
    passed: u32 = 0,

    /// A step of `name`'s whose outcome is `ok`; IoErr is said if not.
    fn say(tally: *Tally, name: *const Name, step: [*:0]const u8, ok: bool) void {
        tally.steps += 1;
        if (ok) {
            tally.passed += 1;
            _ = Printf(tally.dl, MSG_PASS, .{ name.label, step });
        } else {
            _ = Printf(tally.dl, MSG_FAIL, .{ name.label, step, @as(i64, tally.dl.IoErr()) });
        }
        _ = tally.dl.Flush(tally.dl.Output());
    }
};

/// `dir` and `name` joined into `into`; false when they do not fit.
fn join(dl: *DosBase, into: *[path_max:0]u8, dir: [*:0]const u8, name: [*:0]const u8) bool {
    var at: usize = 0;
    while (dir[at] != 0) : (at += 1) {
        if (at == path_max) return false;
        into[at] = dir[at];
    }
    into[at] = 0;
    return dl.AddPart(into, name, path_max + 1);
}

/// Whether two NUL-terminated names are the same bytes.
fn sameBytes(one: [*:0]const u8, other: []const u8) bool {
    var at: usize = 0;
    while (at < other.len) : (at += 1) {
        if (one[at] != other[at]) return false;
    }
    return one[other.len] == 0;
}

/// Whether the directory `lock` is on lists an entry named `wanted`, byte
/// for byte.
fn listed(dl: *DosBase, lock: *FileLock, fib: *FileInfoBlock, wanted: []const u8) bool {
    if (!dl.Examine(lock, fib)) return false;
    var found = false;
    while (dl.ExNext(lock, fib)) {
        if (sameBytes(@ptrCast(&fib.file_name), wanted)) found = true;
    }
    return found;
}

/// Whether `pattern` matches exactly one entry, named `wanted`.
fn matchesOnly(dl: *DosBase, anchor: *dos.AnchorPath, pattern: [*:0]const u8, wanted: []const u8) bool {
    anchor.* = .{};
    var count: u32 = 0;
    var right = false;
    var rc = dl.MatchFirst(pattern, anchor);
    while (rc == 0) : (rc = dl.MatchNext(anchor)) {
        count += 1;
        if (sameBytes(@ptrCast(&anchor.info.file_name), wanted)) right = true;
    }
    dl.MatchEnd(anchor);
    return rc == dos.ERROR_NO_MORE_ENTRIES and count == 1 and right;
}

/// The pattern for `name` in `into`: `?` for its first character, the
/// rest as it is.
fn questionFirst(name: []const u8, into: *[64:0]u8) [*:0]const u8 {
    var skip: usize = 1;
    if (name[0] >= 0xC0) {
        while (skip < name.len and name[skip] & 0xC0 == 0x80) skip += 1;
    }
    into[0] = '?';
    const rest = name[skip..];
    for (rest, 0..) |byte, at| into[1 + at] = byte;
    into[1 + rest.len] = 0;
    return into;
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
    const dir: [*:0]const u8 = @ptrFromInt(argv[arg_dir]);

    const memory = sys.AllocVec(3 * (path_max + 1) + @sizeOf(dos.AnchorPath), exec.MEMF_CLEAR) orelse return dos.RETURN_FAIL;
    defer sys.FreeVec(memory);
    // The anchor first, where the allocation's alignment is; the paths,
    // which need none, after it.
    const anchor: *dos.AnchorPath = @ptrCast(@alignCast(memory));
    const bytes: [*]u8 = @as([*]u8, @ptrCast(memory)) + @sizeOf(dos.AnchorPath);
    const work: *[path_max:0]u8 = @ptrCast(bytes);
    const path: *[path_max:0]u8 = @ptrCast(bytes + (path_max + 1));
    const other: *[path_max:0]u8 = @ptrCast(bytes + 2 * (path_max + 1));
    const fib: *FileInfoBlock = @ptrCast(@alignCast(dl.AllocDosObject(dos.DOS_FIB, null) orelse return dos.RETURN_FAIL));
    defer dl.FreeDosObject(dos.DOS_FIB, fib);

    if (!join(dl, work, dir, work_name)) {
        _ = dl.PrintFault(dos.ERROR_LINE_TOO_LONG, COMMAND_NAME);
        return dos.RETURN_FAIL;
    }
    // CreateDir's lock is exclusive, which would keep a search out of
    // the directory: a shared one instead.
    dl.UnLock(dl.CreateDir(work) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    });
    const work_lock = dl.Lock(work, dos.SHARED_LOCK) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    var tally: Tally = .{ .dl = dl };
    var pattern: [64:0]u8 = undefined;

    for (&names) |*name| {
        if (!join(dl, path, work, name.name) or !join(dl, other, work, name.other_case)) {
            tally.say(name, "the path fits", false);
            continue;
        }
        // Made, holding its own name.
        const file = dl.Open(path, dos.MODE_NEWFILE);
        const written = if (file) |fh| dl.Write(fh, name.name.ptr, @intCast(name.name.len)) == @as(isize, @intCast(name.name.len)) else false;
        const closed = if (file) |fh| dl.Close(fh) else false;
        tally.say(name, "made", file != null and written and closed);

        const found = dl.Lock(path, dos.SHARED_LOCK);
        tally.say(name, "found by its name", found != null);
        dl.UnLock(found);
        const found_other = dl.Lock(other, dos.SHARED_LOCK);
        tally.say(name, "found in the other case", found_other != null);
        dl.UnLock(found_other);

        tally.say(name, "listed as it is kept", listed(dl, work_lock, fib, name.kept()));

        if (!join(dl, path, work, questionFirst(name.name, &pattern))) {
            tally.say(name, "the pattern fits", false);
        } else {
            tally.say(name, "matched by ? for its first character", matchesOnly(dl, anchor, path, name.kept()));
        }

        tally.say(name, "deleted in the other case", dl.DeleteFile(other));
        _ = join(dl, path, work, name.name);
        const left = dl.Lock(path, dos.SHARED_LOCK);
        tally.say(name, "gone", left == null);
        dl.UnLock(left);
    }

    dl.UnLock(work_lock);
    if (argv[arg_keep] != 0) {
        for (&names) |*name| {
            if (!join(dl, path, work, name.name)) continue;
            const file = dl.Open(path, dos.MODE_NEWFILE) orelse {
                _ = dl.PrintFault(dl.IoErr(), path);
                continue;
            };
            _ = dl.Write(file, name.name.ptr, @intCast(name.name.len));
            _ = dl.Close(file);
        }
    } else if (!dl.DeleteFile(work)) _ = dl.PrintFault(dl.IoErr(), work);
    _ = Printf(dl, MSG_RESULT, .{ tally.passed, tally.steps });
    return if (tally.passed == tally.steps) dos.RETURN_OK else dos.RETURN_ERROR;
}
