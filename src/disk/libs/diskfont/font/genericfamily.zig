// SPDX-License-Identifier: MIT
//! GenericFamily: the family font.prefs names for a generic family - a
//! serif, a sans-serif, a fixed-width, a handwriting or a decorative
//! font - read from ENV:Sys/font.prefs as it is now.

const sdk = @import("sdk");
const exec = sdk.exec;
const diskfont = sdk.diskfont;
const font_prefs = sdk.prefs.font;
const _base = @import("../diskfont_base.zig");
const DiskfontBase = _base.DiskfontBase;

/// The family a generic family is.
///
/// SYNOPSIS:
/// ```zig
/// fn GenericFamily(dfb: *DiskfontBase, generic: u32, into: [*]u8, size: u32) bool
/// ```
///
/// SINCE: 1.16. LVO -56.
///
/// INPUTS:
/// - `generic` - which: `GENERIC_SERIF`, `GENERIC_SANS`, `GENERIC_MONO`,
///   `GENERIC_CURSIVE` or `GENERIC_FANTASY`.
/// - `into` - where the family's name goes: "serif.font", a NUL after it.
/// - `size` - how many bytes `into` holds.
///
/// RESULT:
/// True, the name in `into`. False for a `generic` that is none of
/// them, one font.prefs names no family for and that has no default,
/// or a name and its NUL that `size` cannot hold; `into` is then left as
/// it was.
///
/// BEHAVIOR:
/// font.prefs names them under SERIF, SANS, MONO, CURSIVE and FANTASY.
/// One it leaves out - or all, with no file or a line that cannot be
/// read - is `serif.font`, `sans.font` and `mono.font` for the first
/// three, and none for the other two. The file is read at each call, so
/// the answer is what the prefs say now. Whether the family is in FONTS:
/// is not looked at: the caller finds that out by opening it.
///
/// CONTEXT:
/// - Waits: yes: for the disk.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Process, since it reads a file.
///
/// OWNERSHIP:
/// `into` is the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// FindFamily, FallbackFamily, OpenOutlineFontTagList
///
/// EXAMPLES:
/// ```zig
/// var family: [64]u8 = undefined;
/// if (dfb.GenericFamily(diskfont.GENERIC_CURSIVE, &family, family.len)) {
///     // A handwriting font is set: draw in it.
/// }
/// ```
pub fn GenericFamily(dfb: *DiskfontBase, generic: u32, into: [*]u8, size: u32) bool {
    if (generic >= font_prefs.generic_names.len) return false;
    const which: font_prefs.Generic = @enumFromInt(generic);
    const sys = dfb.sys_base;
    // The line is most of a kilobyte, and this is deep in the stack of
    // whoever draws text.
    const memory = sys.AllocVec(@sizeOf(font_prefs.Line), exec.MEMF_ANY) orelse return false;
    defer sys.FreeVec(memory);
    const line: *font_prefs.Line = @ptrCast(@alignCast(memory));
    line.* = .{};
    readPrefs(dfb, line);
    const name = line.generic(which) orelse font_prefs.generic_defaults[generic] orelse return false;
    if (name.len + 1 > size) return false;
    @memcpy(into[0..name.len], name);
    into[name.len] = 0;
    return true;
}

/// ENV:Sys/font.prefs read into `line`; left empty when there is no
/// file or its line is not a font line.
fn readPrefs(dfb: *DiskfontBase, line: *font_prefs.Line) void {
    const sys = dfb.sys_base;
    const read = sdk.prefs.loadWhole(sys, dfb.dos_base, font_prefs.ENV_FILE) orelse return;
    defer sys.FreeVec(read.ptr);
    const words = sdk.prefs.firstLine(read) orelse return;
    if (font_prefs.parse(dfb.utility_base, words, line) != null) line.* = .{};
}
