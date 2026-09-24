// SPDX-License-Identifier: MPL-2.0
//! NewObjectTagList: makes an object.

const sdk = @import("sdk");
const utility = sdk.utility;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// Makes an object.
///
/// SYNOPSIS:
/// ```zig
/// fn NewObjectTagList(ib: *IntuitionBase, cl: ?*Class,
///     class_id: ?[*:0]const u8, tags: ?[*]const TagItem) ?*Object
/// ```
///
/// SINCE: 0.2. LVO -48.
///
/// INPUTS:
/// - `cl` - the class, by pointer: how a private class is used.
/// - `class_id` - the public class, by name, when `cl` is null.
/// - `tags` - its first attributes, as its classes define them. May be
///   null.
///
/// RESULT:
/// The object, or null: no such class, or one of its classes would not
/// make it - no memory, or an attribute it will not take.
///
/// BEHAVIOR:
/// `OM_NEW` is sent to the class with the class itself as the object,
/// since there is none yet. Each class passes it up first and then sets
/// up its own part: rootclass allocates the whole object, cleared, and
/// every class below it fills in its data from `tags`. The class is kept
/// from being freed while that runs.
///
/// CONTEXT:
/// - Waits: for the class list's semaphore when finding by name; beyond
///   that, whatever the classes do.
/// - Interrupts: no; it allocates.
/// - Forbid: not held and not needed.
/// - Process: a Task will do, unless a class says otherwise.
///
/// OWNERSHIP:
/// The object is the caller's, until `DisposeObject`. `tags` is read
/// during the call and not kept.
///
/// NOTES:
/// - An object's handle is not the start of its memory: a header sits in
///   front of it. Free it only with `DisposeObject`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DisposeObject`, `MakeClass`, `SetAttrsTagList`
///
/// EXAMPLES:
/// ```zig
/// const tags = [_]TagItem{ .{ .tag = IA_Width, .data = 16 }, .{} };
/// const image = ib.NewObjectTagList(null, IMAGECLASS, &tags) orelse return;
/// defer ib.DisposeObject(image);
/// ```
pub fn NewObjectTagList(ib: *IntuitionBase, cl: ?*Class, class_id: ?[*:0]const u8, tags: ?[*]const TagItem) ?*Object {
    const it = ib.iface();
    // The class's count goes up before OM_NEW and down after it, so the
    // class cannot be freed while its dispatcher is running. The list's
    // lock is held for each change of the count and not through OM_NEW,
    // which may take as long as a class likes and may make objects of its
    // own.
    const c = cl orelse blk: {
        const id = class_id orelse return null;
        _ = it.LockClassList();
        defer it.UnlockClassList();
        const found = it.FindClass(id) orelse return null;
        found.object_count += 1;
        break :blk found;
    };
    if (cl != null) {
        _ = it.LockClassList();
        c.object_count += 1;
        it.UnlockClassList();
    }
    defer {
        _ = it.LockClassList();
        c.object_count -= 1;
        it.UnlockClassList();
    }

    // OM_NEW goes to the true class with the class itself as the object:
    // there is no object yet, and rootclass needs to know which class it
    // is allocating for.
    var msg = classusr.OpSet{ .method_id = classusr.OM_NEW, .attr_list = tags };
    const made = it.CoerceMessage(c, @ptrCast(c), @ptrCast(&msg));
    return @ptrFromInt(made);
}
