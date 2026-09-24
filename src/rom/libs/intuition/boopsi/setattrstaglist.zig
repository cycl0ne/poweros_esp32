// SPDX-License-Identifier: MPL-2.0
//! SetAttrsTagList: changes an object's attributes.

const sdk = @import("sdk");
const utility = sdk.utility;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const Object = classes.Object;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// Changes an object's attributes.
///
/// SYNOPSIS:
/// ```zig
/// fn SetAttrsTagList(ib: *IntuitionBase, object: ?*Object,
///     tags: ?[*]const TagItem) u32
/// ```
///
/// SINCE: 0.2. LVO -56.
///
/// INPUTS:
/// - `object` - the object. Null does nothing and answers 0.
/// - `tags` - the attributes to change. One its classes do not know is
///   passed over.
///
/// RESULT:
/// Nonzero when something that shows changed and the object wants
/// drawing again, as its class decides.
///
/// BEHAVIOR:
/// `OM_SET` goes to the object's own class.
///
/// CONTEXT:
/// - Waits: whatever its classes do.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `tags` is read during the call. What a tag points at may be kept - each
/// class says, as imageclass does for `IA_Data`.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetAttr`
///
/// EXAMPLES:
/// ```zig
/// const move = [_]TagItem{ .{ .tag = IA_Left, .data = 10 }, .{} };
/// _ = ib.SetAttrsTagList(image, &move);
/// ```
pub fn SetAttrsTagList(ib: *IntuitionBase, object: ?*Object, tags: ?[*]const TagItem) u32 {
    var msg = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = tags };
    return @truncate(ib.iface().SendMessage(object, @ptrCast(&msg)));
}
