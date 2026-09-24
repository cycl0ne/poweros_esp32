// SPDX-License-Identifier: MPL-2.0
//! LayersErrorText: what an `LERR_` code means, in words.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;

const LayersBase = @import("../layers.zig").LayersBase;

/// Says what an `LERR_` code means, in words.
///
/// SYNOPSIS:
/// ```zig
/// fn LayersErrorText(_: *LayersBase, code: i32) [*:0]const u8
/// ```
///
/// SINCE: 0.1. LVO -116.
///
/// INPUTS:
/// - `code` - an `LERR_` code, as `LATAG_ErrorPtr` or `LATAG_GetLastError`
///   gives it.
///
/// RESULT:
/// The text, which is the library's and not the caller's, so a program
/// built against an older SDK still prints something true about a code
/// that arrived after it. A code the library does not know is "unknown
/// error" rather than null, so the answer can be printed unchecked.
///
/// BEHAVIOR:
/// A table of the codes the library returns.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The text is read-only and lives as long as the
/// library.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateLayerTagList`, `GetLayerAttrs`
///
/// EXAMPLES:
/// ```zig
/// print("layer: %s\n", .{lb.LayersErrorText(err)});
/// ```
pub fn LayersErrorText(_: *LayersBase, code: i32) [*:0]const u8 {
    return switch (code) {
        layers.LERR_OK => "no error",
        layers.LERR_NO_MEMORY => "out of memory",
        layers.LERR_BAD_BOUNDS => "a layer needs a rectangle with something in it",
        layers.LERR_NO_RASTPORT => "no RastPort could be made for the layer",
        layers.LERR_NO_SUPERBITMAP => "a LAYERSUPER layer needs a bitmap at least as big as itself",
        layers.LERR_NOT_DONE => "that is not built yet",
        else => "unknown error",
    };
}
