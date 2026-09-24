// SPDX-License-Identifier: MIT
//! ReadArgs' structures (dos/rdargs.h): CSource, the text to parse, and
//! RDArgs, which carries it with ReadArgs' allocations, an extra help
//! text and flags; the ITEM_* codes ReadItem answers; and helpers that
//! read ReadArgs' result slots.
//!
//! Each template item has one pointer-sized slot in the caller's array:
//! a string's address, the address of an i32 (/N), DOSTRUE or 0 (/S, /T),
//! or the address of a null-terminated array of strings (or i32
//! addresses, /M/N). A slot ReadArgs doesn't fill keeps the caller's
//! value (except /M, which is 0 without items).
//!
//!   var argv: [3]usize = @splat(0);
//!   const rda = dl.ReadArgs("FROM/M/A,TO/A,QUIET/S", &argv, null) orelse ...;
//!   defer dl.FreeArgs(rda);
//!   for (rdargs.multi(argv[0])) |name| ...

/// struct CSource: text for ReadArgs and ReadItem to parse instead of
/// Input(). It should end in a newline.
pub const CSource = extern struct {
    /// CS_Buffer: the text; null reads Input().
    buffer: ?[*]const u8 = null,
    /// CS_Length: its length.
    length: isize = 0,
    /// CS_CurChr: how far it has been read.
    cur_chr: isize = 0,
};

/// struct RDArgs: ReadArgs' state. Give one to ReadArgs for a CSource, an
/// extra help text or flags (AllocDosObject(DOS_RDARGS) makes a cleared
/// one), or pass null and ReadArgs makes its own. Clear `buffer` before
/// each ReadArgs, and FreeArgs after it.
pub const RDArgs = extern struct {
    /// RDA_Source: the text to parse; without a buffer, Input().
    source: CSource = .{},
    /// RDA_DAList: ReadArgs' allocations, which FreeArgs frees.
    da_list: ?*anyopaque = null,
    /// RDA_Buffer: where the results go (strings, numbers, /M arrays);
    /// null makes ReadArgs allocate it, and it grows as needed.
    buffer: ?[*]u8 = null,
    /// RDA_BufSiz: its size, when the caller gives one.
    buf_siz: isize = 0,
    /// RDA_ExtHelp: shown at a second '?' instead of the template.
    ext_help: ?[*:0]const u8 = null,
    /// RDAF_*
    flags: u32 = 0,
};

/// RDAF_STDIN: defined, and never looked at.
pub const RDAF_STDIN: u32 = 1 << 0;
/// Never allocate: the caller's buffer must be big enough.
pub const RDAF_NOALLOC: u32 = 1 << 1;
/// A lone '?' is an argument, not a request for the template.
pub const RDAF_NOPROMPT: u32 = 1 << 2;

/// How many items a template may have.
pub const MAX_TEMPLATE_ITEMS = 100;
/// How many items /M may collect (one fewer).
pub const MAX_MULTIARGS = 128;

// ReadItem's answers.
/// A '=' came first (and was read).
pub const ITEM_EQUAL: i32 = -2;
/// The buffer is full, or a quote isn't closed.
pub const ITEM_ERROR: i32 = -1;
/// The line's end, a ';' or the end of the input, before anything.
pub const ITEM_NOTHING: i32 = 0;
pub const ITEM_UNQUOTED: i32 = 1;
pub const ITEM_QUOTED: i32 = 2;

/// A string slot: the string, or null when it wasn't given.
pub fn string(slot: usize) ?[*:0]const u8 {
    return if (slot == 0) null else @ptrFromInt(slot);
}

/// A /N slot: the number, or null when it wasn't given.
pub fn number(slot: usize) ?i32 {
    return if (slot == 0) null else @as(*const i32, @ptrFromInt(slot)).*;
}

/// A /M slot's strings (none when it is 0).
pub fn multi(slot: usize) []const [*:0]const u8 {
    if (slot == 0) return &.{};
    const array: [*]const ?[*:0]const u8 = @ptrFromInt(slot);
    var n: usize = 0;
    while (array[n] != null) n += 1;
    return @ptrCast(array[0..n]);
}

/// A /M/N slot's numbers: the i-th, as `multi` counts them.
pub fn multiNumber(slot: usize, i: usize) i32 {
    const array: [*]const *const i32 = @ptrFromInt(slot);
    return array[i].*;
}
