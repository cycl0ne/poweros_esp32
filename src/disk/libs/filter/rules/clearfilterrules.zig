// SPDX-License-Identifier: MIT
//! ClearFilterRules: the rules out of force, and the hooks out of the
//! stack.

const sdk = @import("sdk");
const _base = @import("../filter_base.zig");
const FilterBase = _base.FilterBase;
const _hook = @import("../hook/_hook.zig");

/// Takes the rules out of force: every packet passes again.
///
/// SYNOPSIS:
/// ```zig
/// fn ClearFilterRules(base: *FilterBase) void
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The hooks are taken out of bsdsocket.library's chains first, so when
/// the call returns neither runs; then the rules and the noted exchanges
/// are thrown away. With no rules in force it does nothing.
///
/// CONTEXT:
/// - Waits: yes - for bsdsocket.library's lock.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do: bsdsocket.library is opened on it for the
///   length of the call.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// With the hooks out, the library may be expunged once nobody has it
/// open.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LoadFilterRules`
///
/// EXAMPLES:
/// ```zig
/// fb.ClearFilterRules();
/// ```
pub fn ClearFilterRules(base: *FilterBase) void {
    const sys = base.sys_base;
    _hook.hookOut(base);
    if (base.hooked != 0) return;
    sys.AcquireLock(&base.lock);
    const old = base.rules;
    base.rules = null;
    base.flows.clear();
    sys.ReleaseLock(&base.lock);
    if (old) |gone| sys.FreeVec(gone);
}
