// SPDX-License-Identifier: MIT
//! FallbackFamily: a family font.prefs names for the characters a font
//! has no glyph for.

const sdk = @import("sdk");
const _base = @import("../diskfont_base.zig");
const DiskfontBase = _base.DiskfontBase;
const _font = @import("_font.zig");

/// A family a character is looked for in that a font has no glyph for:
/// one of those `font.prefs` names under FALLBACK.
///
/// SYNOPSIS:
/// ```zig
/// fn FallbackFamily(dfb: *DiskfontBase, index: u32, name: [*]u8, size: u32) bool
/// ```
///
/// SINCE: 1.16. LVO -48.
///
/// INPUTS:
/// - `index` - which of them, from 0, in the list's order.
/// - `name` - where its name goes: "cjk-jp.font", a NUL after it.
/// - `size` - how many bytes `name` holds.
///
/// RESULT:
/// True, the name in `name`. False past the end of the list, with no
/// list, or for a name and its NUL that `size` cannot hold; `name` is
/// then left as it was.
///
/// BEHAVIOR:
/// The list is read from ENV:Sys/font.prefs again when `index` is 0, so
/// a program that walks it from the start has it as the prefs are now,
/// and then kept: the same list the fonts `OpenDiskFont` makes fall back
/// to, in the same order. A program that draws a family's outline itself
/// - `OpenOutlineFont` - looks for a character the family lacks in
/// these, one after another.
///
/// CONTEXT:
/// - Waits: yes: for another task loading a font, and for the disk.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Process, since it reads a file.
///
/// OWNERSHIP:
/// `name` is the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenOutlineFont`, `OpenDiskFont`
///
/// EXAMPLES:
/// ```zig
/// var family: [32]u8 = undefined;
/// var index: u32 = 0;
/// while (dfb.FallbackFamily(index, &family, family.len)) : (index += 1) {
///     const face = dfb.OpenOutlineFont(@ptrCast(&family), sdk.graphics.FS_NORMAL) orelse continue;
///     defer dfb.CloseOutlineFont(face);
///     // Look for the character in face.outline.
/// }
/// ```
pub fn FallbackFamily(dfb: *DiskfontBase, index: u32, name: [*]u8, size: u32) bool {
    const sys = dfb.sys_base;
    sys.ObtainSemaphore(&dfb.load_lock);
    defer sys.ReleaseSemaphore(&dfb.load_lock);
    if (index == 0) dfb.fallbacks_read = false;
    const family = _font.fallbackFamily(dfb, index) orelse return false;
    if (family.len + 1 > size) return false;
    @memcpy(name[0..family.len], family);
    name[family.len] = 0;
    return true;
}
