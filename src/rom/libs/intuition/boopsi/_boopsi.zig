// SPDX-License-Identifier: MPL-2.0
//! Classes, objects and messages: what the class and object calls share.
//!
//! A class is a `Class` allocated here and handed back to its owner, who
//! sets its dispatcher and, if it is public, puts it on the list. The list
//! is guarded by one semaphore in the base; exec's semaphores nest, so a
//! call that holds it can call another that takes it.
//!
//! An object is one allocation - rootclass makes it - and every message to
//! it goes to a class's dispatcher through utility.library's CallHookPkt.
//! Each class keeps two counts, its objects and its subclasses, and cannot
//! be freed while either is above zero: its dispatcher is code that may be
//! in a file on disk, and something still able to call it would call into
//! freed memory.
//!
//! Both counts change only with the class list's semaphore held, so the
//! check FreeClass makes is never against a count another task is halfway
//! through changing.
//!
//! Every call in boopsi/ that has an LVO - this library's own included - goes
//! through the jump table (docs/codex.md), so SetFunction can stand in
//! front of any of it.

const sdk = @import("sdk");
const utility = sdk.utility;
const intuition = sdk.intuition;
const classes = intuition.classes;
const Class = classes.Class;

/// Where a class's data begins: after its superclass's, rounded up to 8
/// so a class may keep a 64-bit field in its part of an object.
pub fn instOffsetAfter(super: ?*const Class) u32 {
    const s = super orelse return 0;
    return (s.inst_offset + s.inst_size + 7) & ~@as(u32, 7);
}

/// What a class answers until its owner gives it a dispatcher: 0 to
/// everything, which NewObject reads as "made nothing".
pub fn answerNothing(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = hook;
    _ = object;
    _ = message;
    return 0;
}

pub fn sameName(a: [*:0]const u8, b: [*:0]const u8) bool {
    var i: usize = 0;
    while (a[i] == b[i]) : (i += 1) {
        if (a[i] == 0) return true;
    }
    return false;
}
