// SPDX-License-Identifier: MIT
//! CloseOutline: what OpenOutline made, given back.

const sdk = @import("sdk");
const truetype = sdk.truetype;
const _base = @import("../truetype_base.zig");
const TrueTypeBase = _base.TrueTypeBase;

/// What OpenOutline made, given back.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseOutline(tb: *TrueTypeBase, outline: ?*truetype.Outline) void
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `outline` - what `OpenOutline` answered, or null.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The outline's memory goes back; null does nothing. The font images
/// rendered from it stay: each is a whole font of its own.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The file's bytes are the caller's again, free to go.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenOutline`
///
/// EXAMPLES:
/// ```zig
/// tb.CloseOutline(outline);
/// ```
pub fn CloseOutline(tb: *TrueTypeBase, outline: ?*truetype.Outline) void {
    tb.sys_base.FreeVec(outline);
}
