// SPDX-License-Identifier: MIT
//! Version: what version something is, and whether it is new enough. Built
//! against the SDK only.
//!
//!   Version NAME,VERSION/N,REVISION/N,FILE/S,FULL/S,UNIT/N,INTERNAL/S,RES/S
//!
//!   Version                      the system's own version
//!   Version dos.library          a library that is open, or a ROM tag
//!   Version serial.device UNIT 0 a device, by opening that unit
//!   Version C:Dir FILE           the $VER: string in a file
//!   Version Echo INTERNAL        a resident segment: a built-in, or what
//!                                `Resident` put on the list
//!   Version exec.library 40      RETURN_OK if it is 40 or newer, else WARN
//!
//! With no NAME it answers with the system's own, which is exec.library's;
//! it puts that in the local variable `Kickstart` as well, where scripts
//! read it.
//!
//! Where it looks, in order, unless a switch narrows it: an open library by
//! that name; a device, if UNIT says which one; a ROM tag (FindResident),
//! which finds devices and handlers without starting them; a resident
//! segment, with INTERNAL; and the file, which is searched for a "$VER:"
//! string. There is no version.library, so this does the looking itself.
//!
//! **The string**:
//!
//!   $VER: <name words> <version>[.<revision>] [(<date>)] [<comment>]
//!
//! The name is every word until one begins with a digit, so a name may hold
//! spaces. Without FULL only the name and the numbers are printed, which is
//! all that is printed; FULL adds the date in its brackets and the comment on
//! the next line.
//!
//! The date is printed as it stands, dd.mm.yyyy, without going through a
//! DateStamp.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Version";
const VERSION_STRING = "\x00$VER: Version 1.0 (16.9.2026)\r\n";

const template = "NAME,VERSION/N,REVISION/N,FILE/S,FULL/S,UNIT/N,INTERNAL/S,RES/S";
const arg_name = 0;
const arg_version = 1;
const arg_revision = 2;
const arg_file = 3;
const arg_full = 4;
const arg_unit = 5;
const arg_internal = 6;
const arg_res = 7;

const MSG_NOVERSION = "Could not find version information for '%s'\n";

/// The most of a file it reads at a time while looking for the string.
const file_chunk = 4096;
const tag = "$VER: ";

/// What a "$VER:" string says. The slices point into the string itself.
const Info = struct {
    name: []const u8 = &.{},
    version: u32 = 0,
    revision: u32 = 0,
    date: []const u8 = &.{},
    comment: []const u8 = &.{},
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [8]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const want_version = rdargs.number(argv[arg_version]);
    const want_revision = rdargs.number(argv[arg_revision]);
    const full = argv[arg_full] != 0;

    // The system's own version is exec's, and goes into the local variable
    // `Kickstart`.
    const asked = rdargs.string(argv[arg_name]);
    const name = asked orelse "exec.library";

    const found = blk: {
        if (argv[arg_file] == 0) {
            const narrowed = argv[arg_res] != 0 or argv[arg_internal] != 0;
            if (!narrowed) {
                if (rdargs.number(argv[arg_unit])) |unit| {
                    if (fromDevice(sys, dl, name, unit, full)) |it| break :blk it;
                } else if (fromLibrary(sys, dl, name, full)) |it| break :blk it;
            }
            if (argv[arg_internal] == 0) {
                if (fromResident(sys, dl, name, full)) |it| break :blk it;
            }
            if (argv[arg_res] == 0) {
                if (fromSegment(dl, name, full)) |it| break :blk it;
            }
            if (narrowed) {
                _ = Printf(dl, MSG_NOVERSION, .{name});
                return dos.RETURN_WARN;
            }
        }
        break :blk inFile(sys, dl, name, full) orelse {
            _ = Printf(dl, MSG_NOVERSION, .{name});
            return dos.RETURN_WARN;
        };
    };
    if (asked == null) {
        var text: [16:0]u8 = @splat(0);
        const written = twoNumbers(&text, found.version, found.revision);
        _ = dl.SetVar("Kickstart", @ptrCast(&text), @intCast(written), dos.LV_VAR | dos.GVF_LOCAL_ONLY);
    }
    return compare(found, want_version, want_revision);
}

// --- the string ----------------------------------------------------------

/// version.library's parse. The name is every word until one begins with a
/// digit; then the version, an optional ".revision", an optional "(date)",
/// and the rest of the line as the comment.
fn parseVer(text: []const u8) Info {
    var info: Info = .{};
    var i: usize = 0;
    if (starts(text, tag)) i = tag.len;
    while (i < text.len and text[i] == ' ') i += 1;

    const name_at = i;
    var name_end = i;
    while (true) {
        while (i < text.len and text[i] != ' ') i += 1;
        name_end = i;
        while (i < text.len and text[i] == ' ') i += 1;
        if (i >= text.len) break;
        if (text[i] >= '0' and text[i] <= '9') break;
    }
    info.name = text[name_at..name_end];

    i += digits(text[i..], &info.version);
    if (i < text.len and text[i] == '.') {
        i += 1;
        i += digits(text[i..], &info.revision);
    }
    while (i < text.len and text[i] == ' ') i += 1;
    if (i < text.len and text[i] == '(') {
        i += 1;
        const date_at = i;
        while (i < text.len and text[i] != ')') i += 1;
        info.date = text[date_at..i];
        if (i < text.len) i += 1;
    }
    while (i < text.len and text[i] == ' ') i += 1;
    info.comment = text[i..];
    return info;
}

/// The line a "$VER:" string is on, up to its end.
fn line(text: []const u8) []const u8 {
    var end: usize = 0;
    while (end < text.len and text[end] != '\r' and text[end] != '\n' and text[end] != 0) end += 1;
    return text[0..end];
}

/// What is printed: the name and the numbers, and with FULL the date in its
/// brackets and the comment on a line of its own.
fn report(dl: *DosBase, info: Info, full: bool) void {
    write(dl, info.name);
    _ = Printf(dl, " %d.%d", .{ info.version, info.revision });
    if (full and info.date.len != 0) {
        _ = dl.PutStr(" (");
        write(dl, info.date);
        _ = dl.PutStr(")");
    }
    _ = dl.PutStr("\n");
    if (full and info.comment.len != 0) {
        write(dl, info.comment);
        _ = dl.PutStr("\n");
    }
}

/// Bytes that have no NUL after them.
fn write(dl: *DosBase, bytes: []const u8) void {
    if (bytes.len != 0) _ = dl.WriteChars(bytes.ptr, @intCast(bytes.len));
}

// --- where to look --------------------------------------------------------

/// A library, opened by name: its node holds the version and revision its
/// ROM tag gave it, and its id string the rest. Opening one that is already
/// there costs a count.
fn fromLibrary(sys: *ExecBase, dl: *DosBase, name: [*:0]const u8, full: bool) ?Info {
    const library = sys.OpenLibrary(name, 0) orelse return null;
    defer sys.CloseLibrary(library);
    return fromNode(dl, name, library.version, library.revision, library.id_string, full);
}

/// A device's version, by opening the unit asked for. It is the one thing
/// that cannot be read without side effects, which is why it wants UNIT
/// before it will.
fn fromDevice(sys: *ExecBase, dl: *DosBase, name: [*:0]const u8, unit: i32, full: bool) ?Info {
    var io: exec.IOStdReq = .{ .req = .{ .message = .{ .length = @sizeOf(exec.IOStdReq) } } };
    if (sys.OpenDevice(name, @intCast(@max(unit, 0)), &io.req, 0) != 0) return null;
    defer sys.CloseDevice(&io.req);
    const device = io.req.device orelse return null;
    return fromNode(dl, name, device.version, device.revision, device.id_string, full);
}

/// Any ROM module, by its tag: devices and handlers as well as libraries,
/// and none of them started.
fn fromResident(sys: *ExecBase, dl: *DosBase, name: [*:0]const u8, full: bool) ?Info {
    const tag_found = sys.FindResident(name) orelse return null;
    return fromNode(dl, name, tag_found.version, 0, tag_found.id_string, full);
}

/// A resident segment: a shell built-in, or what `Resident` put on the
/// list. A segment has no version of its own, so its code is searched for
/// the same "$VER:" string a file carries; a built-in in ROM has none, and
/// then only its name is printed.
fn fromSegment(dl: *DosBase, name: [*:0]const u8, full: bool) ?Info {
    _ = dl.LockSegmentList(true) orelse return null;
    defer dl.UnLockSegmentList();
    const segment = dl.FindSegment(name, null, false) orelse dl.FindSegment(name, null, true) orelse return null;
    var node = segment.seg_list;
    while (node) |seg| : (node = seg.next) {
        const data = seg.data orelse continue;
        if (find(data[0..seg.mem_size])) |info| {
            report(dl, info, full);
            return info;
        }
    }
    _ = Printf(dl, "%s (internal)\n", .{name});
    return .{};
}

/// A node's numbers, with whatever its id string adds. The string's own
/// numbers win when it has them, as version.library's do.
fn fromNode(
    dl: *DosBase,
    name: [*:0]const u8,
    version: u16,
    revision: u16,
    id_string: ?[*:0]const u8,
    full: bool,
) Info {
    var info: Info = .{ .version = version, .revision = revision };
    if (id_string) |id| {
        var end: usize = 0;
        while (id[end] != 0) end += 1;
        const parsed = parseVer(line(id[0..end]));
        if (parsed.name.len != 0) {
            info = parsed;
            if (parsed.version == 0) {
                info.version = version;
                info.revision = revision;
            }
            report(dl, info, full);
            return info;
        }
    }
    var end: usize = 0;
    while (name[end] != 0) end += 1;
    info.name = name[0..end];
    report(dl, info, full);
    return info;
}

/// The "$VER:" string in a file.
fn inFile(sys: *ExecBase, dl: *DosBase, name: [*:0]const u8, full: bool) ?Info {
    const fh = dl.Open(name, dos.MODE_OLDFILE) orelse return null;
    defer _ = dl.Close(fh);
    const buffer = sys.AllocVec(file_chunk, exec.MEMF_ANY) orelse return null;
    defer sys.FreeVec(buffer);
    const bytes: [*]u8 = @ptrCast(buffer);

    // The string may straddle two chunks, so each keeps the tail of the one
    // before it.
    const keep = tag.len + 128;
    var held: usize = 0;
    while (true) {
        const got = dl.Read(fh, bytes + held, @intCast(file_chunk - held));
        if (got <= 0) break;
        const have = held + @as(usize, @intCast(got));
        if (find(bytes[0..have])) |info| {
            report(dl, info, full);
            return info;
        }
        if (have <= keep) {
            held = have;
        } else {
            const tail = bytes[have - keep ..][0..keep];
            var i: usize = 0;
            while (i < keep) : (i += 1) bytes[i] = tail[i];
            held = keep;
        }
        if (have < file_chunk) break;
    }
    _ = dl.SetIoErr(dos.ERROR_OBJECT_WRONG_TYPE);
    return null;
}

/// The first "$VER:" string in a block of bytes, parsed.
fn find(bytes: []const u8) ?Info {
    var at: usize = 0;
    while (at + tag.len < bytes.len) : (at += 1) {
        if (!starts(bytes[at..], tag)) continue;
        return parseVer(line(bytes[at..]));
    }
    return null;
}

// --- odds and ends --------------------------------------------------------

fn starts(bytes: []const u8, with: []const u8) bool {
    if (bytes.len < with.len) return false;
    for (with, 0..) |c, i| {
        if (bytes[i] != c) return false;
    }
    return true;
}

fn digits(bytes: []const u8, into: *u32) usize {
    var i: usize = 0;
    var value: u32 = 0;
    while (i < bytes.len and bytes[i] >= '0' and bytes[i] <= '9') : (i += 1) {
        value = value * 10 + (bytes[i] - '0');
    }
    into.* = value;
    return i;
}

/// Two numbers as "x.y", for the `Kickstart` variable.
fn twoNumbers(into: *[16:0]u8, version: u32, revision: u32) usize {
    var at: usize = 0;
    at += decimal(into, at, version);
    into[at] = '.';
    at += 1;
    at += decimal(into, at, revision);
    into[at] = 0;
    return at;
}

fn decimal(into: *[16:0]u8, at: usize, value: u32) usize {
    if (value >= 10) {
        const higher = decimal(into, at, value / 10);
        into[at + higher] = '0' + @as(u8, @intCast(value % 10));
        return higher + 1;
    }
    into[at] = '0' + @as(u8, @intCast(value));
    return 1;
}

/// RETURN_OK when it is at least what was asked for, RETURN_WARN when it is
/// older - what a script tests.
fn compare(found: Info, version: ?i32, revision: ?i32) i32 {
    const want_version: u32 = if (version) |v| @intCast(@max(v, 0)) else return dos.RETURN_OK;
    if (found.version > want_version) return dos.RETURN_OK;
    if (found.version < want_version) return dos.RETURN_WARN;
    const want_revision: u32 = if (revision) |r| @intCast(@max(r, 0)) else 0;
    return if (found.revision >= want_revision) dos.RETURN_OK else dos.RETURN_WARN;
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs: the linker collects unused
/// sections, and a plain constant never reaches the file at all - which is
/// all the comptime reference that used to stand here achieved.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
