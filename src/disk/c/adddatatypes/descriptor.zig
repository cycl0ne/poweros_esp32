// SPDX-License-Identifier: MIT
//! What a descriptor file says, and the block of memory it becomes.
//!
//! One `ReadArgs` template says the whole of it, so a new kind of file
//! is added with a text editor and nothing else. What comes out is one
//! `AllocVec` block holding the `DataType`, its header and everything
//! the header points at - the copied names, the parsed pattern, the
//! mask and which of its bytes are wildcards - so that adding a type
//! is one allocation and removing it is one free.
//!
//! It is a file of its own because the command's own file cannot be
//! imported by a test: it carries the program's entry point.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const datatypes = sdk.datatypes;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;

/// What one descriptor file says.
const descriptor_template = "NAME/A,BASE/A,GROUP/A,ID,PATTERN,MASK,PRI/N,TYPE,RECOGNISE/S,CASE/S,DIR/S";
const d_name = 0;
const d_base = 1;
const d_group = 2;
const d_id = 3;
const d_pattern = 4;
const d_mask = 5;
const d_pri = 6;
const d_type = 7;
const d_recognise = 8;
const d_case = 9;
const d_dir = 10;

/// Four characters as the number they make, short names padded with
/// spaces.
pub fn idOf(text: [*:0]const u8) u32 {
    var value: u32 = 0;
    for (0..4) |i| {
        const c: u8 = if (text[i] != 0 and i < 4) text[i] else ' ';
        value = value << 8 | c;
        if (text[i] == 0) {
            // The rest is spaces.
            var left = 3 - i;
            while (left > 0) : (left -= 1) value = value << 8 | ' ';
            break;
        }
    }
    return value;
}

pub fn idText(id: u32, into: *[5]u8) [*:0]const u8 {
    into[0] = @truncate(id >> 24);
    into[1] = @truncate(id >> 16);
    into[2] = @truncate(id >> 8);
    into[3] = @truncate(id);
    into[4] = 0;
    return @ptrCast(into);
}

pub fn textLen(text: [*:0]const u8) usize {
    var n: usize = 0;
    while (text[n] != 0) n += 1;
    return n;
}

/// One hex digit, or 16.
pub fn hexOf(c: u8) u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return 16;
}

/// A mask read: the bytes and which of them are wildcards. How many
/// there are.
pub fn readMask(text: [*:0]const u8, bytes: [*]u8, any: [*]u8, room: usize) u16 {
    var out: usize = 0;
    var i: usize = 0;
    while (text[i] != 0 and out < room) {
        if (text[i] == '?') {
            bytes[out] = 0;
            any[out] = 1;
            i += 1;
        } else if (text[i] == '\\' and text[i + 1] == 'x' and hexOf(text[i + 2]) < 16 and hexOf(text[i + 3]) < 16) {
            bytes[out] = hexOf(text[i + 2]) << 4 | hexOf(text[i + 3]);
            any[out] = 0;
            i += 4;
        } else {
            bytes[out] = text[i];
            any[out] = 0;
            i += 1;
        }
        out += 1;
    }
    return @intCast(out);
}

/// The kind a TYPE word names.
pub fn kindOf(text: ?[*:0]const u8) u16 {
    const word = text orelse return datatypes.DTF_BINARY;
    return switch (word[0]) {
        'i', 'I' => datatypes.DTF_IFF,
        'a', 'A' => datatypes.DTF_ASCII,
        'm', 'M' => datatypes.DTF_MISC,
        else => datatypes.DTF_BINARY,
    };
}

/// A descriptor read into one block of memory: the type, its header and
/// everything the header points at. Null when the file does not say
/// what it must.
pub fn readDescriptor(sys: *ExecBase, dl: *DosBase, ub: *UtilityBase, text: []u8) ?*datatypes.DataType {
    var argv: [11]usize = @splat(0);
    var rda = dos.RDArgs{
        .source = .{ .buffer = text.ptr, .length = @intCast(text.len) },
        .flags = dos.RDAF_NOPROMPT,
    };
    const got = dl.ReadArgs(descriptor_template, &argv, &rda) orelse return null;
    defer dl.FreeArgs(got);

    const name: [*:0]const u8 = @ptrFromInt(argv[d_name]);
    const base: [*:0]const u8 = @ptrFromInt(argv[d_base]);
    const group: [*:0]const u8 = @ptrFromInt(argv[d_group]);
    const pattern: ?[*:0]const u8 = @ptrFromInt(argv[d_pattern]);
    const mask: ?[*:0]const u8 = @ptrFromInt(argv[d_mask]);
    const case = argv[d_case] != 0;

    const name_len = textLen(name) + 1;
    const base_len = textLen(base) + 1;
    // A parsed pattern needs at most two bytes for each one given, and
    // an end marker.
    const pattern_room = if (pattern) |p| 2 * textLen(p) + 3 else 0;
    const mask_room = if (mask) |m| textLen(m) else 0;
    const size = @sizeOf(datatypes.DataType) + @sizeOf(datatypes.DataTypeHeader) +
        name_len + base_len + pattern_room + 2 * mask_room;
    const memory = sys.AllocVec(size, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const dt: *datatypes.DataType = @ptrCast(@alignCast(memory));
    dt.* = .{ .header = undefined, .length = @intCast(size) };
    dt.tools.init(.unknown);

    var at = @intFromPtr(memory) + @sizeOf(datatypes.DataType);
    const header: *datatypes.DataTypeHeader = @ptrFromInt(at);
    at += @sizeOf(datatypes.DataTypeHeader);
    const name_copy: [*]u8 = @ptrFromInt(at);
    @memcpy(name_copy[0..name_len], name[0..name_len]);
    at += name_len;
    const base_copy: [*]u8 = @ptrFromInt(at);
    @memcpy(base_copy[0..base_len], base[0..base_len]);
    at += base_len;

    header.* = .{
        .name = @ptrCast(name_copy),
        .base_name = @ptrCast(base_copy),
        .group_id = idOf(group),
        .flags = kindOf(@ptrFromInt(argv[d_type])),
        .priority = if (argv[d_pri] != 0) @truncate(@as(*const i32, @ptrFromInt(argv[d_pri])).*) else 0,
    };
    header.id = if (argv[d_id] != 0) idOf(@ptrFromInt(argv[d_id])) else idOf(name);
    if (case) header.flags |= datatypes.DTF_CASE;
    if (argv[d_recognise] != 0) header.flags |= datatypes.DTF_RECOGNISE;
    if (argv[d_dir] != 0) header.flags |= datatypes.DTF_DIRECTORY;

    if (pattern) |p| {
        const tokens: [*]u8 = @ptrFromInt(at);
        at += pattern_room;
        const made = if (case)
            ub.ParsePattern(p, tokens, pattern_room)
        else
            ub.ParsePatternNoCase(p, tokens, pattern_room);
        if (made >= 0) header.pattern = @ptrCast(tokens);
    }
    if (mask) |m| {
        const bytes: [*]u8 = @ptrFromInt(at);
        const any: [*]u8 = @ptrFromInt(at + mask_room);
        header.mask_len = readMask(m, bytes, any, mask_room);
        if (header.mask_len != 0) {
            header.mask = bytes;
            header.mask_any = any;
        }
    }
    dt.header = header;
    dt.node.name = @ptrCast(name_copy);
    dt.node.pri = @truncate(header.priority);
    return dt;
}
