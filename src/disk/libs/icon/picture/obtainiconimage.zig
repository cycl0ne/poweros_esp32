// SPDX-License-Identifier: MIT
//! ObtainIconImage: an icon's picture at a size.

const sdk = @import("sdk");
const icon = sdk.icon;
const IconBase = @import("../icon_base.zig").IconBase;
const _shrunk = @import("_shrunk.zig");

/// `image` at most `most` pixels each way, shrunk when it is larger.
///
/// SYNOPSIS:
/// ```zig
/// fn ObtainIconImage(base: *IconBase, image: *const IconImage, most: u32) ?*const IconImage
/// ```
///
/// SINCE: 1.3. LVO -60.
///
/// INPUTS:
/// - `image` - an icon's picture (`DiskObject.image`), or an image of the
///   program's own in the same form: rgba32, a row `width * 4` bytes.
/// - `most` - the largest width and height wanted, in pixels; 0 is taken
///   as 1.
///
/// RESULT:
/// The picture to show, in the same form as `image`: `image` itself when
/// it is no larger than `most` either way, else a copy shrunk to the
/// largest size that fits with its shape kept, at least a pixel each way.
/// Null without the memory for the copy.
///
/// BEHAVIOR:
/// Each pixel of a copy is the average of the pixels of `image` it
/// covers, red, green and blue weighted by their coverage, so a soft edge
/// stays soft and a pixel nothing covers stays clear.
///
/// A copy of a picture the library made is kept with that picture and
/// shared: whoever asks for the same picture at the same size - from the
/// same icon, another icon that shows it, as every file without an icon
/// of a kind does, or another program - gets the same copy, shrunk once.
/// A copy of an image of the program's own is made for this call alone.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The answer is held for the caller until `ReleaseIconImage` and is read
/// only. One of the library's pictures stays while it is held, so the icon
/// it came from may be given back first. An image of the program's own is
/// not held: when it is answered whole, the program keeps it until then.
///
/// NOTES:
/// `BlendPixelArray` draws the answer, as it draws an icon's picture.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReleaseIconImage`, `GetDiskObjectNew`, `FreeDiskObject`
///
/// EXAMPLES:
/// ```zig
/// const object = ib.GetDiskObjectNew("SYS:Programs/Notepad") orelse return;
/// const shown = ib.ObtainIconImage(object.image.?, 32);
/// ib.FreeDiskObject(object); // the picture is held by `shown`
/// const image = shown orelse return;
/// defer ib.ReleaseIconImage(image);
/// // image.width and image.height at most 32
/// ```
pub fn ObtainIconImage(base: *IconBase, image: *const icon.IconImage, most: u32) ?*const icon.IconImage {
    return _shrunk.obtain(base, image, most);
}
