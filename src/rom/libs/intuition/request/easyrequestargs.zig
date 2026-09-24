// SPDX-License-Identifier: MPL-2.0
//! EasyRequestArgs: asks something in a requester and waits for the
//! answer.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const EasyStruct = intuition.EasyStruct;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const Window = @import("../window/_window.zig").Window;

/// Asks something in a requester and waits for the answer.
///
/// SYNOPSIS:
/// ```zig
/// fn EasyRequestArgs(ib: *IntuitionBase, window: ?*Window,
///     easy_struct: *const EasyStruct, idcmp_ptr: ?*u32,
///     args: ?*const anyopaque) i32
/// ```
///
/// SINCE: 0.11. LVO -248.
///
/// INPUTS:
/// - `window` - the window it is about, whose screen it opens on and whose
///   title it takes, or null for the default public screen.
/// - `easy_struct` - what it says, as `BuildEasyRequestArgs` reads it.
/// - `idcmp_ptr` - null, or IDCMP classes of the caller's own that answer
///   it too; the one that did is written back here.
/// - `args` - the values for both formats, the message's first
///   (`sdk.exec.fmtStream`), or null.
///
/// RESULT:
/// 1, 2, ... for the buttons from the left and 0 for the rightmost; -1
/// (`SYSREQ_IDCMP`) when one of the caller's classes arrived. 0 as well
/// when the requester could not be made, and a process's IoErr is then
/// `ERROR_NO_FREE_STORE`, which is how the two zeros are told apart.
///
/// BEHAVIOR:
/// `BuildEasyRequestArgs`, then `SysReqHandler` waiting until something
/// answers, then `FreeSysRequest`. The requester is closed before this
/// returns.
///
/// CONTEXT:
/// - Waits: until it is answered.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing stays behind. The EasyStruct and the values are read and not
/// kept.
///
/// NOTES:
/// - `sdk.intuition.requesters.EasyRequest` takes the values as a tuple
///   and checks both formats against them at compile time.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BuildEasyRequestArgs`, `SysReqHandler`, `FreeSysRequest`
///
/// EXAMPLES:
/// ```zig
/// const ask = EasyStruct{ .text_format = "Delete %s?", .gadget_format = "Delete|Cancel" };
/// const stream = sdk.exec.fmtStream(.{name});
/// if (ib.EasyRequestArgs(window, &ask, null, &stream) == 1) delete(name);
/// ```
pub fn EasyRequestArgs(ib: *IntuitionBase, window: ?*Window, easy_struct: *const EasyStruct, idcmp_ptr: ?*u32, args: ?*const anyopaque) i32 {
    const it = ib.iface();
    const idcmp: u32 = if (idcmp_ptr) |p| p.* else 0;
    const request = it.BuildEasyRequestArgs(@ptrCast(window), easy_struct, idcmp, args);
    var answer = it.SysReqHandler(request, idcmp_ptr, true);
    while (answer == intuition.requesters.SYSREQ_PENDING) answer = it.SysReqHandler(request, idcmp_ptr, true);
    it.FreeSysRequest(request);
    return answer;
}
