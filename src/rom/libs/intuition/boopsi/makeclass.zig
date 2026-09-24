// SPDX-License-Identifier: MPL-2.0
//! MakeClass: makes a class.

const sdk = @import("sdk");
const exec = sdk.exec;
const intuition = sdk.intuition;
const classes = intuition.classes;
const Class = classes.Class;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _boopsi = @import("_boopsi.zig");
const answerNothing = _boopsi.answerNothing;
const instOffsetAfter = _boopsi.instOffsetAfter;

/// Makes a class.
///
/// SYNOPSIS:
/// ```zig
/// fn MakeClass(ib: *IntuitionBase, class_id: ?[*:0]const u8,
///     super_id: ?[*:0]const u8, super_class: ?*Class,
///     inst_size: u32) ?*Class
/// ```
///
/// SINCE: 0.2. LVO -20.
///
/// INPUTS:
/// - `class_id` - the name it will be found by once it is on the public
///   list, or null for a private class, which is used by pointer only.
///   Not copied: it must outlive the class.
/// - `super_id` - the public class to make it from, by name.
/// - `super_class` - the class to make it from, by pointer, when
///   `super_id` is null; how a class is made from a private one.
/// - `inst_size` - how many bytes of data this class adds to an object.
///
/// RESULT:
/// The class, or null: `class_id` names a public class already, `super_id`
/// names none, or there was no memory.
///
/// BEHAVIOR:
/// The class comes back **off the public list**, with a dispatcher that
/// answers 0 to every message. Its owner sets `dispatcher.entry` (and
/// `user_data`, if the dispatcher needs anything found again), and then
/// calls `AddClass` if it is public - so no object can be made of it
/// before it can answer. Its data starts after its superclass's, rounded
/// up to 8. The superclass's subclass count goes up, so it cannot be freed
/// while this class exists.
///
/// CONTEXT:
/// - Waits: for the class list's semaphore.
/// - Interrupts: no; it allocates.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's, until `FreeClass`.
///
/// NOTES:
/// - Only rootclass has neither a `super_id` nor a `super_class`. A class
///   made from nothing must allocate its own objects in `OM_NEW`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddClass`, `FreeClass`, `NewObjectTagList`
///
/// EXAMPLES:
/// ```zig
/// const cl = ib.MakeClass(null, intuition.classusr.IMAGECLASS, null, @sizeOf(MyData)) orelse return;
/// cl.dispatcher.entry = &myDispatch;
/// ```
pub fn MakeClass(ib: *IntuitionBase, class_id: ?[*:0]const u8, super_id: ?[*:0]const u8, super_class: ?*Class, inst_size: u32) ?*Class {
    const it = ib.iface();
    // Held across the whole of it, so no other task can take the name or
    // free the superclass between the checks and the count going up.
    _ = it.LockClassList();
    defer it.UnlockClassList();

    if (class_id) |id| {
        if (it.FindClass(id) != null) return null;
    }
    const super = if (super_id) |sid| (it.FindClass(sid) orelse return null) else super_class;

    const memory = ib.sys_base.AllocMem(@sizeOf(Class), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const cl: *Class = @ptrCast(@alignCast(memory));
    cl.* = .{
        .dispatcher = .{ .entry = &answerNothing },
        .super = super,
        .id = class_id,
        .inst_offset = instOffsetAfter(super),
        .inst_size = inst_size,
    };
    // Only now that nothing can fail: the superclass is kept for as long
    // as this class exists.
    if (super) |s| s.subclass_count += 1;
    return cl;
}
