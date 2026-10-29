// SPDX-License-Identifier: MIT
//! CloseLocale: a locale given back.

const sdk = @import("sdk");
const locale = sdk.locale;
const _base = @import("../locale_base.zig");
const LocaleBase = _base.LocaleBase;

/// Gives a locale back.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseLocale(lb: *LocaleBase, loc: ?*locale.Locale) void
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `loc` - a locale from OpenLocale, or one SetDefaultLocale answered;
///   null does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// A locale is held once by each OpenLocale that answered it and by the
/// library while it is the default. The last to give it back frees it;
/// the library's own is never freed.
///
/// CONTEXT:
/// - Waits: for the library's lock, for a moment.
/// - Interrupts: no.
/// - Locks: takes the library's lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's hold ends: the locale and its strings may be gone once
/// this returns.
///
/// NOTES:
/// Each OpenLocale is matched by one CloseLocale, also for the default.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenLocale`, `SetDefaultLocale`
///
/// EXAMPLES:
/// ```zig
/// const loc = lb.OpenLocale(null) orelse return;
/// defer lb.CloseLocale(loc);
/// ```
pub fn CloseLocale(lb: *LocaleBase, loc: ?*locale.Locale) void {
    const ext = _base.extOf(loc orelse return);
    const sys = lb.sys_base;
    sys.ObtainSemaphore(&lb.lock);
    if (ext.usage != 0) ext.usage -= 1;
    const last = ext.usage == 0 and !ext.builtin;
    sys.ReleaseSemaphore(&lb.lock);
    if (last) sys.FreeVec(ext);
}
