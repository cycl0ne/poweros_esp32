// SPDX-License-Identifier: MPL-2.0
//! RemNamedObject: takes an object out of its name space at once and
//! replies the message when its last use is gone.

const sdk = @import("sdk");
const exec = sdk.exec;
const _namedobjects = @import("_namedobjects.zig");

const UtilityBase = @import("../utility.zig").UtilityBase;
const NamedObject = sdk.utility.NamedObject;

/// Takes an object out of its name space, and reports when its last user
/// has let go.
///
/// SYNOPSIS:
/// ```zig
/// fn RemNamedObject(ub: *UtilityBase, object: ?*NamedObject, message: ?*exec.Message) void
/// ```
///
/// SINCE: 1.0. LVO -176.
///
/// INPUTS:
/// - `object` - the object to take out. For null the message comes back at
///   once with `ln_Name` null.
/// - `message` - replied when the last use is gone. Null makes this
///   `AttemptRemNamedObject`, with nothing to report the result.
///
/// RESULT:
/// Nothing. The reply is the answer: its `ln_Name` points to the object
/// when it was taken out, and is null when the object was in no name
/// space.
///
/// BEHAVIOR:
/// The object leaves its name space at once, so no search finds it any
/// more, and the caller's use is given back as by `ReleaseNamedObject`. The
/// message comes back when every other use has been released - at once if
/// there are none. After the reply nobody holds the object, and
/// `FreeNamedObject` may free it.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the name space's semaphore. It
///   does not wait for the reply; that is the caller's to do.
/// - Interrupts: no. It may wait.
/// - Forbid: taken here, and broken while waiting for the semaphore.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The name space holds the message until it is
/// replied. The caller's use is consumed.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AttemptRemNamedObject`, `ReleaseNamedObject`, `FreeNamedObject`
///
/// EXAMPLES:
/// ```zig
/// var msg: Message = .{ .reply_port = port };
/// ub.RemNamedObject(obj, &msg);
/// _ = sys.WaitPort(port);
/// _ = sys.GetMsg(port);
/// ub.FreeNamedObject(obj);
/// ```
pub fn RemNamedObject(ub: *UtilityBase, object: ?*NamedObject, message: ?*exec.Message) void {
    _ = _namedobjects.remNamedObject(ub, object, message);
}
