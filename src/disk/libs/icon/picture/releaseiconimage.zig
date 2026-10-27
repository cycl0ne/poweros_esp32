// SPDX-License-Identifier: MIT
//! ReleaseIconImage: a picture at a size given back.

const sdk = @import("sdk");
const icon = sdk.icon;
const IconBase = @import("../icon_base.zig").IconBase;
const _shrunk = @import("_shrunk.zig");

/// Gives back an image from `ObtainIconImage`.
///
/// SYNOPSIS:
/// ```zig
/// fn ReleaseIconImage(base: *IconBase, image: ?*const IconImage) void
/// ```
///
/// SINCE: 1.3. LVO -64.
///
/// INPUTS:
/// - `image` - an answer of `ObtainIconImage`; null does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The hold `ObtainIconImage` took is let go of: a shrunk copy is freed
/// with the last that holds it, and then lets go of the picture it was
/// shrunk from, which goes with the last icon that shows it. An image of
/// the program's own that was answered whole was not held, and nothing
/// is done.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The image may not be used after.
///
/// NOTES:
/// Each answer is given back once, however many times the same image was
/// answered.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ObtainIconImage`
///
/// EXAMPLES:
/// ```zig
/// const image = ib.ObtainIconImage(object.image.?, 48) orelse return;
/// ib.ReleaseIconImage(image);
/// ```
pub fn ReleaseIconImage(base: *IconBase, image: ?*const icon.IconImage) void {
    const given = image orelse return;
    _shrunk.release(base, given);
}
