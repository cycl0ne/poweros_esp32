// SPDX-License-Identifier: MPL-2.0
//! OpenResource: a resource by name. Nothing is counted and nothing is
//! owed back - there is no CloseResource.
//!
//! This searches the resource list and nothing else. What loads a
//! resource from DEVS: is ramlib.library, which replaces the slot in front
//! of it.

const ExecBase = @import("../exec.zig").ExecBase;

/// Finds a resource by name.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenResource(base: *ExecBase, res_name: [*:0]const u8) ?*anyopaque
/// ```
///
/// SINCE: 1.0. LVO -396.
///
/// INPUTS:
/// - `res_name` - the resource's name, matched exactly.
///
/// RESULT:
/// The resource, or null if there is none of that name - which for a
/// resource that only exists on some boards is the ordinary answer and not
/// an error.
///
/// BEHAVIOR:
/// It is called "open" for the shape of the thing, but **nothing is
/// counted and there is no close**. The pointer is good for as long as the
/// machine is running.
///
/// A resource in the ROM is there from the start. With ramlib.library in
/// front of this call, one that is not there is looked for as
/// `DEVS:<res_name>` - or where a `:` in the name says - and made from its
/// file, which stays loaded; the asker's current directory is not looked
/// in. Every ask for a resource that is not there looks on the disk again.
///
/// CONTEXT:
/// - Waits: for exec's library list, while another task holds it; and
///   with ramlib.library in front of it, the replacement loads a resource
///   that is not there from DEVS:, which reaches a handler.
/// - Interrupts: no. It takes exec's library list, a semaphore.
/// - Locks: takes exec's library list, a semaphore; no spinlock may be held.
/// - Process: a Task will do for exec's own. ramlib's replacement needs a
///   Process to load from a disk, and sends the work to its own when a bare
///   Task calls it.
///
/// OWNERSHIP:
/// Nothing is allocated and nothing is owed.
///
/// NOTES:
/// A resource is how a program reaches a fact of the machine it cannot
/// import: platform.resource holds the chip's, expander.resource a pin
/// that is not the chip's own. What is soldered on the board comes from
/// expansion.library.
///
/// exec's own search is the resource list and nothing else. What loads a
/// resource from DEVS: is ramlib.library, which replaces this slot with
/// `SetFunction`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddResource`, `OpenLibrary`, `OpenDevice`
///
/// EXAMPLES:
/// ```zig
/// const pb = sys.OpenResource("platform.resource") orelse return;
/// ```
pub fn OpenResource(base: *ExecBase, res_name: [*:0]const u8) ?*anyopaque {
    const sys = base.iface();
    sys.ObtainSemaphore(&base.sem_libraries);
    defer sys.ReleaseSemaphore(&base.sem_libraries);
    return sys.FindName(&base.resource_list, res_name);
}
