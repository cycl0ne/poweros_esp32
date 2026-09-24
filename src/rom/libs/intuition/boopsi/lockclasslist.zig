// SPDX-License-Identifier: MPL-2.0
//! LockClassList: holds the public class list.

const sdk = @import("sdk");
const exec = sdk.exec;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// Holds the public class list.
///
/// SYNOPSIS:
/// ```zig
/// fn LockClassList(ib: *IntuitionBase) *exec.MinList
/// ```
///
/// SINCE: 0.2. LVO -40.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// The list. Each node on it is a class: the dispatcher's node is the
/// class's first field.
///
/// BEHAVIOR:
/// Nothing is added to it, taken off it or freed until `UnlockClassList`.
/// The same task may take it again inside; each take needs its release.
///
/// CONTEXT:
/// - Waits: yes, for another task that holds it.
/// - Interrupts: no.
/// - Forbid: must not be held - it may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Read only. Nothing on it may be changed through it.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `UnlockClassList`, `FindClass`
///
/// EXAMPLES:
/// ```zig
/// const list = ib.LockClassList();
/// defer ib.UnlockClassList();
/// ```
pub fn LockClassList(ib: *IntuitionBase) *exec.MinList {
    ib.sys_base.ObtainSemaphore(&ib.class_lock);
    return &ib.class_list;
}
