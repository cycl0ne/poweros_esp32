// SPDX-License-Identifier: MPL-2.0
//! What the image calls share: finding the next image of a chain.
//!
//! DrawImage, DrawImageState, EraseImage and PointInImage are the image
//! methods, sent for a caller. Each builds the method's message and sends it to the image's own class
//! through the jump table, so an image of any class - imageclass or one
//! that draws itself - answers. A null image draws and erases nothing, and
//! contains every point, so a caller with an optional image needs no test
//! of its own.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const ic = intuition.imageclass;
const Object = intuition.Object;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// The image drawn after this one, if any. Asked for rather than read, so
/// that a class that is not imageclass may answer for itself.
pub fn nextOf(ib: *IntuitionBase, o: *Object) ?*Object {
    var next: usize = 0;
    if (ib.iface().GetAttr(ic.IA_NextImage, o, &next) == 0) return null;
    return @ptrFromInt(next);
}
