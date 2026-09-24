// SPDX-License-Identifier: MPL-2.0
//! Text: path names, the argument parser, and error texts - calls that
//! work on strings and ask no handler.
//!
//! The path calls: AddPart, FilePart, PathPart, SplitName and ParsePath.
//!
//! They work on the text of a path alone - no handler is asked and no lock
//! taken - so they answer the same whether the object exists or not, and a
//! caller can build or pick apart a name before anything is looked up. A
//! path is "device:dir/dir/name": the part up to the colon names the
//! device, volume or assign; a leading ':' is the root of the current
//! volume; a '/' after a '/' or a colon (or at the start) is a way up.
//!
//! FilePart and PathPart point into the caller's string rather than copy,
//! so they cost nothing and cannot fail. AddPart and SplitName write into a
//! buffer the caller sizes, and say so when it is too small: AddPart with
//! ERROR_LINE_TOO_LONG and the buffer unchanged, SplitName by cutting.
//!
//! The argument parser: ReadArgs, FreeArgs, ReadItem, FindArg and
//! StrToLong, and the state and helpers they share.
//!
//! ReadArgs reads items (as ReadItem does) from the RDArgs' CSource, or
//! from Input() through FGetC and UnGetC when it has none, and fills the
//! caller's slots by the template. A keyword (FindArg: any case, aliases
//! joined by '=') fills its own item: a /S at once, anything else with the
//! next item, after an optional '='. Any other item fills the next free one
//! that is not /K, /S or /T; a /M takes all such items; at the end an empty
//! /A takes the last of the /M's (when it has two or more and they are not
//! numbers); a /F takes the rest of the line.
//!
//! Strings, numbers and the /M array go into the RDArgs' buffer. When it
//! is full a new block is allocated, bigger than what was left, and linked
//! on the DAList; the old block keeps the results already in it, so every
//! pointer handed out stays good until FreeArgs frees the list. A caller's
//! RDArgs brings a CSource, an ExtHelp and flags, which is what lets a task
//! parse a string of its own rather than a shell's input.
//!
//! A lone '?' at the end of a line prints the template (ExtHelp the second
//! time) to Output() and reads the line again from Input() - also when the
//! line came from a CSource, which is used up by then. In a quoted item
//! "*E" is an escape, "*N" a newline, and '*' before anything else is that
//! character. A slot is pointer-sized; a /N slot points at an i32 in the
//! buffer.
//!
//! Error texts: Fault and PrintFault, over one table of texts by code.
//!
//! The table has the shell's messages (-100 to -162), which the shell asks
//! Fault for like any other text, the IoErr codes, and the codes of 400 and
//! up. A few of the shell's texts hold formats the shell fills in itself
//! (%N, %TH, %b), so they are kept as the shell wants them.
//!
//! Fault builds "header: text" into the caller's buffer - just the text for
//! a null header, "Error <n>" for a code without one, nothing for 0 - cut to
//! the buffer with its NUL (`Fill`). PrintFault writes that and a newline to
//! Output() and leaves IoErr at the code, so a caller can report an error
//! and still hand it on.

const std = @import("std");
const sdk = @import("sdk");
const process = @import("../process/_process.zig");
const files = @import("../file/_file.zig");
const DosBase = @import("../dos_base.zig").DosBase;
const dos = sdk.dos;
const exec = sdk.exec;
const rd = dos.rdargs;
const RDArgs = rd.RDArgs;
const CSource = rd.CSource;

/// A tab: a blank between items, as a space is.
pub const TAB = '\t';
/// The line's end.
pub const LF = '\n';

// A template item's flags, one byte per item in State.argimage.
/// /A: the item must be given.
const REQUIRED: u8 = 1 << 0;
/// /K: the item is filled only after its keyword.
const KEYWORD: u8 = 1 << 1;
/// /S: a switch, set by its keyword alone.
pub const SWITCH: u8 = 1 << 2;
/// /N: the item is a number.
const NUMBER: u8 = 1 << 3;
/// /F: the item is the rest of the line.
pub const REST: u8 = 1 << 4;
/// /T: a toggle, YES/ON or NO/OFF.
const TOGGLE: u8 = 1 << 5;
/// /M (or /...): the item takes many.
const MULTI: u8 = 1 << 6;
/// The item has been given.
pub const DONE: u8 = 1 << 7;

/// The template's modifier letters and the flag each sets.
const arg_keys = [_]struct { flag: u8, char: u8 }{
    .{ .flag = REQUIRED, .char = 'A' },
    .{ .flag = KEYWORD, .char = 'K' },
    .{ .flag = SWITCH, .char = 'S' },
    .{ .flag = NUMBER, .char = 'N' },
    .{ .flag = REST, .char = 'F' },
    .{ .flag = TOGGLE, .char = 'T' },
    .{ .flag = MULTI, .char = '.' },
    .{ .flag = MULTI, .char = 'M' },
};

// RDA_Flags' bits for ReadArgs' own use, which FreeArgs clears.
/// The template has been shown once; a second '?' shows ExtHelp.
pub const RDAF_PROMPT_SHOWN: u32 = 1 << 30;
/// Reserved for a buffer ReadArgs made; nothing sets it yet.
pub const RDAF_OURBUFFER: u32 = 1 << 29;

/// The buffer grows by this much.
pub const VECSIZE = 128;
/// A DAList block's link to the next, before its bytes.
pub const link = @sizeOf(usize);
/// A /S's or /T's "on": DOSTRUE in a slot.
pub const TRUE_SLOT: usize = std.math.maxInt(usize);

/// The parser's state for one ReadArgs.
pub const State = struct {
    /// dos.library's base.
    db: *DosBase,
    /// The RDArgs being filled.
    rda: *RDArgs,
    /// Where items come from; null: Input().
    cs: ?*CSource,
    /// The template.
    keys: [*:0]const u8,
    /// The buffer's next free byte and its end.
    w: [*]u8,
    end: [*]u8,
    /// The caller's slots, one per template item.
    argv: [*]usize,
    /// How many items /M has collected.
    multi: usize = 0,
    /// How many items the template has.
    numargs: usize = 0,
    /// The item being filled, -1 for none yet.
    argno: isize = -1,
    /// The last item ReadItem read in the main loop.
    lastitem: i32 = 0,
    /// Each item's flags: REQUIRED, KEYWORD, ... DONE.
    argimage: [rd.MAX_TEMPLATE_ITEMS]u8 = undefined,
    /// The items /M has collected, in the buffer.
    multiargs: [rd.MAX_MULTIARGS][*]u8 = undefined,

    /// The bytes left in the buffer.
    ///
    /// INPUTS:
    /// - `st` - the parser's state.
    fn room(st: *const State) isize {
        return @as(isize, @intCast(@intFromPtr(st.end))) - @as(isize, @intCast(@intFromPtr(st.w)));
    }

    /// The item just read, at the buffer's next free byte.
    ///
    /// INPUTS:
    /// - `st` - the parser's state.
    pub fn text(st: *const State) [*:0]u8 {
        return @ptrCast(st.w);
    }

    /// The buffer's next free byte moved up to `alignment`.
    ///
    /// INPUTS:
    /// - `st` - the parser's state.
    /// - `alignment` - a power of two.
    fn alignTo(st: *State, alignment: usize) void {
        st.w = @ptrFromInt(st.db.utility_base.AlignUp(@intFromPtr(st.w), alignment));
    }
};

// --- The input ---

/// The next character, or -1 at the end: from the CSource's text, or from
/// Input() when there is none.
///
/// INPUTS:
/// - `db` - dos.library's base.
/// - `cs` - the source, or null for Input().
///
/// BEHAVIOR:
/// Reading a CSource's end moves CurChr one past it, so that putting the
/// end back with `unreadChar` doesn't step back over a real character.
pub fn readChar(db: *DosBase, cs: ?*CSource) i32 {
    const dos_lib = db.iface();
    if (cs) |source| {
        if (source.buffer) |b| {
            if (source.cur_chr >= source.length) {
                source.cur_chr = source.length + 1;
                return -1;
            }
            const c = b[@intCast(source.cur_chr)];
            source.cur_chr += 1;
            return c;
        }
    }
    return dos_lib.FGetC(dos_lib.Input());
}

/// Puts the last character read back, for the next reader.
///
/// INPUTS:
/// - `db` - dos.library's base.
/// - `cs` - the source, or null for Input().
pub fn unreadChar(db: *DosBase, cs: ?*CSource) void {
    const dos_lib = db.iface();
    if (cs) |source| {
        if (source.buffer != null) {
            if (source.cur_chr > 0) source.cur_chr -= 1;
            return;
        }
    }
    _ = dos_lib.UnGetC(dos_lib.Input(), -1);
}

/// CurChr back onto the CSource's end, if the end was read past.
///
/// INPUTS:
/// - `cs` - the source.
pub fn settle(cs: *CSource) void {
    if (cs.cur_chr > cs.length) cs.cur_chr = cs.length;
}

// --- The buffer ---

/// `size` cleared bytes, linked into the RDArgs' DAList so FreeArgs frees
/// them; null with RDAF_NOALLOC or without memory.
///
/// INPUTS:
/// - `db` - dos.library's base.
/// - `rda` - the RDArgs whose list gets the block.
/// - `size` - the bytes wanted.
pub fn gimmeAVec(db: *DosBase, rda: *RDArgs, size: usize) ?[*]u8 {
    if (rda.flags & rd.RDAF_NOALLOC != 0) return null;
    const block = db.sys_base.AllocVec(@intCast(size + link), exec.MEMF_CLEAR) orelse return null;
    const next: *?*anyopaque = @ptrCast(@alignCast(block));
    next.* = rda.da_list;
    rda.da_list = block;
    return @as([*]u8, @ptrCast(block)) + link;
}

/// A new block for the buffer, VECSIZE bigger than what was left of the
/// old one, which stays with the results already in it. Returns the old
/// free byte, so an item begun there can be copied over; null without
/// memory.
///
/// INPUTS:
/// - `st` - the parser's state.
fn newBuffer(st: *State) ?[*]u8 {
    const old = st.w;
    const left: usize = @intCast(@max(st.room(), 0));
    const size = st.db.utility_base.AlignUp(left + VECSIZE, VECSIZE);
    const new = gimmeAVec(st.db, st.rda, size) orelse return null;
    st.w = new;
    st.end = new + size;
    return old;
}

// --- Items ---

/// One item into `first`, ended with a NUL: ITEM_QUOTED, ITEM_UNQUOTED,
/// ITEM_NOTHING at the line's end, ITEM_EQUAL for a '=' where an item
/// should start, ITEM_ERROR when it doesn't fit or a quote isn't closed.
///
/// INPUTS:
/// - `db` - dos.library's base.
/// - `st` - ReadArgs' state, whose buffer then grows instead of the item
///   failing; null for ReadItem.
/// - `first` - where the item goes.
/// - `maxchars_given` - `first`'s size, the NUL included.
/// - `cs` - the source, or null for Input().
///
/// BEHAVIOR:
/// The blank after an item is read; the line's end, a ';' or the input's
/// end is put back for the next reader.
pub fn readItem(db: *DosBase, st: ?*State, first: [*]u8, maxchars_given: isize, cs: ?*CSource) i32 {
    var name = first;
    var maxchars = maxchars_given;
    var currpos: isize = 0;
    name[0] = 0;

    var c = readChar(db, cs);
    while (c == ' ' or c == TAB) c = readChar(db, cs);
    var quoted = false;
    if (c == '"') {
        quoted = true;
        c = readChar(db, cs);
    }
    while (true) : (c = readChar(db, cs)) {
        if (c == LF or c < 0) break;
        if (quoted) {
            if (c == '"') return rd.ITEM_QUOTED; // the quote is read
            if (c == '*') {
                c = readChar(db, cs);
                if (c < 0 or c == LF) break;
                if (c == 'e' or c == 'E') {
                    c = 0x1B;
                } else if (c == 'n' or c == 'N') {
                    c = LF;
                }
            }
        } else {
            if (c == ';') break;
            if (c == ' ' or c == TAB) return rd.ITEM_UNQUOTED; // read, not put back
            if (c == '=') return if (currpos != 0) rd.ITEM_UNQUOTED else rd.ITEM_EQUAL;
        }
        currpos += 1;
        if (currpos >= maxchars) {
            const state = st orelse return rd.ITEM_ERROR;
            const old = newBuffer(state) orelse return rd.ITEM_ERROR;
            const kept: usize = @intCast(currpos - 1);
            @memcpy(state.w[0..kept], old[0..kept]);
            name = state.w + kept;
            maxchars = state.room() - 1;
        }
        name[0] = @intCast(c);
        name += 1;
        name[0] = 0;
    }
    // The line's end, a ';' or the input's end goes back for the next
    // reader.
    unreadChar(db, cs);
    if (quoted) return rd.ITEM_ERROR;
    return if (currpos != 0) rd.ITEM_UNQUOTED else rd.ITEM_NOTHING;
}

// --- ReadArgs ---

/// The template's items into argimage and their number into numargs. 0,
/// or ERROR_LINE_TOO_LONG for more than MAX_TEMPLATE_ITEMS items and
/// ERROR_BAD_TEMPLATE for a second /M.
///
/// INPUTS:
/// - `st` - the parser's state, keys the template.
pub fn initKeys(st: *State) i32 {
    const ub = st.db.utility_base;
    var keys = st.keys;
    var len: isize = @intCast(st.db.utility_base.Strlen(keys));
    var multiseen = false;
    st.numargs = 0;
    while (true) {
        st.numargs += 1;
        if (st.numargs > rd.MAX_TEMPLATE_ITEMS) return dos.ERROR_LINE_TOO_LONG;
        const image = &st.argimage[st.numargs - 1];
        image.* = 0;
        while (true) {
            len -= 1;
            if (len < 0) return 0;
            var c = keys[0];
            keys += 1;
            if (c == '/') {
                c = ub.ToUpper(keys[0]);
                keys += 1;
                len -= 1;
                for (arg_keys) |key| {
                    if (key.char != c) continue;
                    image.* |= key.flag;
                    if (key.flag == MULTI) {
                        if (multiseen) return dos.ERROR_BAD_TEMPLATE;
                        multiseen = true;
                    }
                    break;
                }
            }
            if (c == ',') break;
        }
    }
}

/// An item into the buffer, which grows when it is full.
///
/// INPUTS:
/// - `st` - the parser's state.
pub fn rdItem(st: *State) i32 {
    while (st.room() - 1 < 0) {
        if (newBuffer(st) == null) return rd.ITEM_ERROR;
    }
    return readItem(st.db, st, st.w, st.room() - 1, st.cs);
}

/// The rest of the line after `start` bytes already at the buffer's free
/// byte, for a /F. Trailing blanks go unless the first item was quoted.
/// False without memory.
///
/// INPUTS:
/// - `st` - the parser's state.
/// - `start` - how many bytes of the item are already there.
pub fn readRest(st: *State, start: usize) bool {
    var count = start;
    while (true) {
        if (st.room() - @as(isize, @intCast(count)) <= 1) {
            const old = newBuffer(st) orelse return false;
            @memcpy(st.w[0..count], old[0..count]);
        }
        const c = readChar(st.db, st.cs);
        if (c < 0 or c == LF) break;
        st.w[count] = @intCast(c);
        count += 1;
    }
    if (st.lastitem != rd.ITEM_QUOTED) {
        while (count > 0 and (st.w[count - 1] == ' ' or st.w[count - 1] == TAB)) count -= 1;
    }
    st.w[count] = 0;
    return true;
}

/// Answers a lone '?': the template, or ExtHelp from the second time on,
/// and ": " to Output(), after which items come from Input().
///
/// INPUTS:
/// - `st` - the parser's state.
pub fn prompt(st: *State) void {
    const dos_lib = st.db.iface();
    const rda = st.rda;
    var shown: [*:0]const u8 = st.keys;
    if (rda.flags & RDAF_PROMPT_SHOWN != 0) {
        if (rda.ext_help) |help| shown = help;
    }
    rda.flags |= RDAF_PROMPT_SHOWN;
    if (dos_lib.Output()) |out| {
        _ = dos_lib.FPuts(out, shown);
        _ = dos_lib.FPuts(out, ": ");
        _ = files.flush(st.db, out);
    }
    st.cs = null;
}

/// `digits` as an i32 stored, aligned, in the buffer: its address, or
/// ERROR_BAD_NUMBER for anything but a whole number, ERROR_NO_FREE_STORE.
///
/// INPUTS:
/// - `st` - the parser's state.
/// - `digits` - the item's text.
fn storeNumber(st: *State, digits: [*:0]const u8) union(enum) { at: [*]u8, err: i32 } {
    const dos_lib = st.db.iface();
    var value: i32 = 0;
    const n = dos_lib.StrToLong(digits, &value);
    if (n <= 0 or n != st.db.utility_base.Strlen(digits)) return .{ .err = dos.ERROR_BAD_NUMBER };
    st.alignTo(@alignOf(i32));
    if (st.room() < @sizeOf(i32)) {
        if (newBuffer(st) == null) return .{ .err = dos.ERROR_NO_FREE_STORE };
    }
    const at = st.w;
    @as(*i32, @ptrCast(@alignCast(at))).* = value;
    st.w += @sizeOf(i32);
    return .{ .at = at };
}

/// The item at the buffer's free byte into the current slot: a string, a
/// number, a toggle, or one more for the /M. 0, or the error.
///
/// INPUTS:
/// - `st` - the parser's state, argno the slot.
pub fn storeArg(st: *State) i32 {
    const i: usize = @intCast(st.argno);
    const item_type = st.argimage[i];
    st.argimage[i] |= DONE;
    const item = st.text();
    const after = st.db.utility_base.Strlen(item) + 1;

    if (item_type & MULTI != 0) {
        if (st.multi >= rd.MAX_MULTIARGS - 1) return dos.ERROR_LINE_TOO_LONG;
        if (item_type & NUMBER != 0) {
            switch (storeNumber(st, item)) {
                .at => |at| st.multiargs[st.multi] = at,
                .err => |code| return code,
            }
            st.multi += 1;
            return 0;
        }
        st.multiargs[st.multi] = st.w;
        st.multi += 1;
        st.w += after;
        return 0;
    }
    if (item_type & DONE != 0 and item_type & SWITCH == 0) return dos.ERROR_TOO_MANY_ARGS;
    if (item_type & TOGGLE != 0) {
        const ub = st.db.utility_base;
        if (ub.Stricmp(item, "yes") == 0 or ub.Stricmp(item, "on") == 0) {
            st.argv[i] = TRUE_SLOT;
        } else if (ub.Stricmp(item, "no") == 0 or ub.Stricmp(item, "off") == 0) {
            st.argv[i] = 0;
        } else {
            return dos.ERROR_KEY_NEEDS_ARG;
        }
        st.w += after;
        return 0;
    }
    if (item_type & NUMBER != 0) {
        switch (storeNumber(st, item)) {
            .at => |at| st.argv[i] = @intFromPtr(at),
            .err => |code| return code,
        }
        return 0;
    }
    st.argv[i] = @intFromPtr(item);
    st.w += after;
    return 0;
}

/// The end of the line: the /M array (null-terminated) into the buffer,
/// then every /A checked. 0, or ERROR_REQUIRED_ARG_MISSING,
/// ERROR_NO_FREE_STORE or a number's error.
///
/// INPUTS:
/// - `st` - the parser's state.
///
/// BEHAVIOR:
/// An /A still empty (and not /K, /S or /T) takes the last /M item, when
/// the /M has two or more and they are not numbers.
pub fn finish(st: *State) i32 {
    var array: ?[*]usize = null;
    var multi_numbers = false;
    for (0..st.numargs) |i| {
        const item_type = st.argimage[i];
        if (item_type & MULTI == 0) continue;
        st.argv[i] = 0;
        if (st.multi == 0) continue;
        st.alignTo(@alignOf(usize));
        const need = (st.multi + 1) * @sizeOf(usize);
        const a: [*]usize = if (st.room() >= need) blk: {
            const in_buffer: [*]usize = @ptrCast(@alignCast(st.w));
            st.w += need;
            break :blk in_buffer;
        } else @ptrCast(@alignCast(gimmeAVec(st.db, st.rda, need) orelse return dos.ERROR_NO_FREE_STORE));
        for (st.multiargs[0..st.multi], 0..) |item, j| a[j] = @intFromPtr(item);
        a[st.multi] = 0;
        st.argv[i] = @intFromPtr(a);
        array = a;
        multi_numbers = item_type & NUMBER != 0;
    }
    var left = st.multi;
    for (0..st.numargs) |i| {
        const item_type = st.argimage[i];
        if (item_type & DONE != 0 or item_type & REQUIRED == 0) continue;
        const a = array orelse return dos.ERROR_REQUIRED_ARG_MISSING;
        if (item_type & (KEYWORD | SWITCH | TOGGLE) != 0 or left < 2 or multi_numbers)
            return dos.ERROR_REQUIRED_ARG_MISSING;
        left -= 1;
        const stolen = a[left];
        a[left] = 0;
        st.argimage[i] |= DONE;
        if (item_type & NUMBER != 0) {
            switch (storeNumber(st, @ptrFromInt(stolen))) {
                .at => |at| st.argv[i] = @intFromPtr(at),
                .err => |code| return code,
            }
        } else {
            st.argv[i] = stolen;
        }
    }
    return 0;
}

/// The next item a positional argument fills, into argno: 0, or -1 when it
/// is the /F (the rest of the line), or ERROR_TOO_MANY_ARGS.
///
/// INPUTS:
/// - `st` - the parser's state.
pub fn nextSlot(st: *State) i32 {
    while (true) {
        st.argno += 1;
        if (st.argno >= st.numargs) return dos.ERROR_TOO_MANY_ARGS;
        const item_type = st.argimage[@intCast(st.argno)];
        if (item_type & MULTI != 0) return 0;
        if (item_type & DONE != 0) continue;
        if (item_type & REST != 0) return -1;
        if (item_type & (KEYWORD | TOGGLE | SWITCH) != 0) continue;
        return 0;
    }
}

/// ReadArgs' failure: the rest of the line skipped, everything allocated
/// freed, IoErr `code`, and null.
///
/// INPUTS:
/// - `st` - the parser's state.
/// - `code` - the error.
pub fn fail(st: *State, code: i32) ?*RDArgs {
    const dos_lib = st.db.iface();
    var c = readChar(st.db, st.cs);
    while (c != LF and c != ';' and c >= 0) c = readChar(st.db, st.cs);
    settle(&st.rda.source);
    dos_lib.FreeArgs(st.rda);
    _ = dos_lib.SetIoErr(code);
    return null;
}

/// An error code and its text.
const Text = struct { code: i32, text: [*:0]const u8 };

/// The texts by code: the shell's messages, the IoErr codes, then the codes
/// of 400 and up.
const texts = [_]Text{
    .{ .code = -162, .text = "Software Failure" },
    .{ .code = -161, .text = "%s failed returncode %ld\n" },
    .{ .code = -160, .text = "%TH USE COUNT\n\n" },
    .{ .code = -159, .text = "NAME" },
    .{ .code = -158, .text = "%TH DISABLED\n" },
    .{ .code = -157, .text = "%TH INTERNAL\n" },
    .{ .code = -156, .text = "%TH SYSTEM\n" },
    .{ .code = -155, .text = "Fault %3ld" },
    .{ .code = -154, .text = "Fail limit: %ld\n" },
    .{ .code = -153, .text = "Bad return code specified" },
    .{ .code = -152, .text = "Current_directory" },
    .{ .code = -151, .text = "The last command did not set a return code" },
    .{ .code = -150, .text = "Last command failed because " },
    .{ .code = -149, .text = "Process %N ending" },
    .{ .code = -148, .text = "Requested size too small" },
    .{ .code = -147, .text = "Requested size too large" },
    .{ .code = -146, .text = "Current stack size is %ld bytes\n" },
    .{ .code = -145, .text = "NewShell failed" },
    .{ .code = -144, .text = "Missing ELSE or ENDIF" },
    .{ .code = -143, .text = "Must be in a command file" },
    .{ .code = -142, .text = "More than one directory matches" },
    .{ .code = -141, .text = "Can't set %s\n" },
    .{ .code = -140, .text = "Block %ld corrupt directory" },
    .{ .code = -139, .text = "Block %ld corrupt file" },
    .{ .code = -138, .text = "Block %ld bad header type" },
    .{ .code = -137, .text = "Block %ld out of range" },
    .{ .code = -136, .text = "Block %ld used twice" },
    .{ .code = -135, .text = "Error validating %b" },
    .{ .code = -134, .text = "on disk block %ld" },
    .{ .code = -133, .text = "has a checksum error" },
    .{ .code = -132, .text = "has a write error" },
    .{ .code = -131, .text = "has a read error" },
    .{ .code = -130, .text = "Unable to create process\n" },
    .{ .code = -129, .text = "New Shell process %ld\n" },
    .{ .code = -128, .text = "Cannot open FROM file %s\n" },
    .{ .code = -127, .text = "Suspend|Reboot" },
    .{ .code = -126, .text = "Retry|Cancel" },
    .{ .code = -125, .text = "No room for bitmap" },
    .{ .code = -124, .text = "Command too long" },
    .{ .code = -123, .text = "Shell error:" },
    .{ .code = -122, .text = "Error in command name" },
    .{ .code = -121, .text = "Unknown command" },
    .{ .code = -120, .text = "Unable to load" },
    .{ .code = -119, .text = "syntax error" },
    .{ .code = -118, .text = "unable to open redirection file" },
    .{ .code = -117, .text = "Error " },
    .{ .code = -116, .text = "" },
    .{ .code = -115, .text = "Disk corrupt - task stopped" },
    .{ .code = -114, .text = "Program failed (error #" },
    .{ .code = -113, .text = "Wait for disk activity to finish." },
    .{ .code = -112, .text = "in device %s%s" },
    .{ .code = -111, .text = "in unit %ld%s" },
    .{ .code = -110, .text = "You MUST replace volume" },
    .{ .code = -109, .text = "has a read/write error" },
    .{ .code = -108, .text = "No disk present" },
    .{ .code = -107, .text = "Not a DOS disk" },
    .{ .code = -106, .text = "in any drive" },
    .{ .code = -105, .text = "Please replace volume" },
    .{ .code = -104, .text = "Please insert volume" },
    .{ .code = -103, .text = "is full" },
    .{ .code = -102, .text = "is write protected" },
    .{ .code = -101, .text = "is not validated" },
    .{ .code = -100, .text = "Volume" },
    .{ .code = 103, .text = "not enough memory available" },
    .{ .code = 105, .text = "process table full" },
    .{ .code = 114, .text = "bad template" },
    .{ .code = 115, .text = "bad number" },
    .{ .code = 116, .text = "required argument missing" },
    .{ .code = 117, .text = "value after keyword missing" },
    .{ .code = 118, .text = "wrong number of arguments" },
    .{ .code = 119, .text = "unmatched quotes" },
    .{ .code = 120, .text = "argument line invalid or too long" },
    .{ .code = 121, .text = "file is not executable" },
    .{ .code = 122, .text = "invalid resident library" },
    .{ .code = 202, .text = "object is in use" },
    .{ .code = 203, .text = "object already exists" },
    .{ .code = 204, .text = "directory not found" },
    .{ .code = 205, .text = "object not found" },
    .{ .code = 206, .text = "invalid window description" },
    .{ .code = 207, .text = "object too large" },
    .{ .code = 209, .text = "packet request type unknown" },
    .{ .code = 210, .text = "object name invalid" },
    .{ .code = 211, .text = "invalid object lock" },
    .{ .code = 212, .text = "object is not of required type" },
    .{ .code = 213, .text = "disk not validated" },
    .{ .code = 214, .text = "disk is write-protected" },
    .{ .code = 215, .text = "rename across devices attempted" },
    .{ .code = 216, .text = "directory not empty" },
    .{ .code = 217, .text = "too many levels" },
    .{ .code = 218, .text = "device (or volume) is not mounted" },
    .{ .code = 219, .text = "seek failure" },
    .{ .code = 220, .text = "comment is too long" },
    .{ .code = 221, .text = "disk is full" },
    .{ .code = 222, .text = "object is protected from deletion" },
    .{ .code = 223, .text = "file is write protected" },
    .{ .code = 224, .text = "file is read protected" },
    .{ .code = 225, .text = "not a valid DOS disk" },
    .{ .code = 226, .text = "no disk in drive" },
    .{ .code = 232, .text = "no more entries in directory" },
    .{ .code = 233, .text = "object is soft link" },
    .{ .code = 234, .text = "object is linked" },
    .{ .code = 235, .text = "bad loadfile hunk" },
    .{ .code = 236, .text = "function not implemented" },
    .{ .code = 240, .text = "record not locked" },
    .{ .code = 241, .text = "record lock collision" },
    .{ .code = 242, .text = "record lock timeout" },
    .{ .code = 243, .text = "record unlock error" },
    .{ .code = 303, .text = "buffer overflow" },
    .{ .code = 304, .text = "***Break" },
    .{ .code = 305, .text = "file not executable" },
    // The codes of 400 and up.
    .{ .code = 400, .text = "invalid argument" },
    .{ .code = 401, .text = "invalid device list entry" },
    .{ .code = 402, .text = "no input stream" },
    .{ .code = 403, .text = "buffer too small" },
    .{ .code = 404, .text = "not a process" },
    .{ .code = 405, .text = "no handler" },
    .{ .code = 406, .text = "packet out of turn" },
    .{ .code = 407, .text = "error in packet" },
    .{ .code = 408, .text = "no current directory" },
    .{ .code = 409, .text = "handler not loaded" },
    .{ .code = 410, .text = "handler failed to start" },
    .{ .code = 411, .text = "the other end of the pipe is gone" },
};

/// The text for `code`, or null when there is none.
///
/// INPUTS:
/// - `code` - the error code.
pub fn text(code: i32) ?[*:0]const u8 {
    for (texts) |t| {
        if (t.code == code) return t.text;
    }
    return null;
}

/// Bytes into a buffer, as many as fit; the buffer is given one byte short,
/// which stays for the NUL.
pub const Fill = struct {
    buffer: []u8,
    n: usize = 0,

    /// Appends as much of `bytes` as fits.
    ///
    /// INPUTS:
    /// - `f` - the buffer being filled.
    /// - `bytes` - what to append.
    pub fn put(f: *Fill, bytes: []const u8) void {
        const count = @min(bytes.len, f.buffer.len - f.n);
        @memcpy(f.buffer[f.n..][0..count], bytes[0..count]);
        f.n += count;
    }
};
