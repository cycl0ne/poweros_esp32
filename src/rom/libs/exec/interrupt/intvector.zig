// SPDX-License-Identifier: MPL-2.0
//! IntVector: what exec does when one interrupt number fires - its
//! handler, its server chain, and how often it has been dispatched. It is
//! exec's own vector, not a copy: read it under Disable, and write nothing.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;

/// Hands back one interrupt number's vector.
///
/// SYNOPSIS:
/// ```zig
/// fn IntVector(base: *ExecBase, int_number: u32) ?*sdk.exec.IntVector
/// ```
///
/// SINCE: 1.0. LVO -432.
///
/// INPUTS:
/// - `int_number` - a source from `sdk.hardware.intbits`.
///
/// RESULT:
/// The vector - its handler, its server chain and how many times the source
/// has fired - or null if the number is out of range.
///
/// BEHAVIOR:
/// The live vector, as `ExecList` hands back a live list. **Hold Disable**
/// while reading it: this is state an interrupt itself changes, so Forbid
/// is not enough.
///
/// The count is raised whether or not anything is listening, so a source
/// that fires while its driver is not being woken still shows here - which
/// is what makes it worth reading when a device seems dead.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe.
/// - Forbid: not enough. Disable is what guards the vectors.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetIntVector`, `AddIntServer`, `ExecList`
///
/// EXAMPLES:
/// ```zig
/// sys.Disable();
/// const count = if (sys.IntVector(n)) |v| v.count else 0;
/// sys.Enable();
/// ```
pub fn IntVector(base: *ExecBase, int_number: u32) ?*sdk.exec.IntVector {
    if (int_number >= sdk.hardware.intbits.INTB_COUNT) return null;
    return &base.int_vects[int_number];
}
