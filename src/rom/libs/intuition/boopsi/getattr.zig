// SPDX-License-Identifier: MPL-2.0
//! GetAttr: reads one attribute of an object.

const sdk = @import("sdk");
const utility = sdk.utility;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const Object = classes.Object;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// Reads one attribute of an object.
///
/// SYNOPSIS:
/// ```zig
/// fn GetAttr(ib: *IntuitionBase, attr_id: utility.Tag, object: ?*Object,
///     storage: *usize) u32
/// ```
///
/// SINCE: 0.2. LVO -60.
///
/// INPUTS:
/// - `attr_id` - the attribute's tag.
/// - `object` - the object. Null answers 0.
/// - `storage` - where the value goes: the same value `SetAttrsTagList`
///   takes in a tag's data.
///
/// RESULT:
/// Nonzero when its class knew the attribute; 0, with `storage` untouched,
/// when none did.
///
/// BEHAVIOR:
/// `OM_GET` goes to the object's own class.
///
/// CONTEXT:
/// - Waits: whatever its classes do.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// A pointer read back still belongs to the object.
///
/// NOTES:
/// - A 32-bit attribute is written as 32 bits. Set `storage` to 0 first
///   where `usize` is wider, as on the host the tests run on.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetAttrsTagList`
///
/// EXAMPLES:
/// ```zig
/// var width: usize = 0;
/// _ = ib.GetAttr(IA_Width, image, &width);
/// ```
pub fn GetAttr(ib: *IntuitionBase, attr_id: utility.Tag, object: ?*Object, storage: *usize) u32 {
    var msg = classusr.OpGet{ .method_id = classusr.OM_GET, .attr_id = attr_id, .storage = storage };
    return @truncate(ib.iface().SendMessage(object, @ptrCast(&msg)));
}
