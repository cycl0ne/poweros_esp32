// SPDX-License-Identifier: MIT
//! SetTranslate: a translator's events.

const sdk = @import("sdk");
const cx = sdk.commodities;
const ie = sdk.devices.inputevent;
const _base = @import("../commodities_base.zig");
const CxBase = _base.CxBase;

/// Sets the events a translator puts in place of each message it gets.
///
/// SYNOPSIS:
/// ```zig
/// fn SetTranslate(base: *CxBase, translator: ?*cx.CxObj, events: ?*const ie.InputEvent) void
/// ```
///
/// SINCE: 1.0. LVO -72.
///
/// INPUTS:
/// - `translator` - a translator; null does nothing.
/// - `events` - a list of events linked by `next`; null swallows every
///   message.
///
/// RESULT:
/// None; COERR_BADTYPE is recorded in an object that is not a
/// translator.
///
/// BEHAVIOR:
/// Each message that reaches the translator is replaced by a message for
/// each event of the list, in the list's order, each stamped with the
/// time of the one it replaces and going on from where it would have:
/// the next object after the translator. With no list, the message is
/// simply gone. The events are not copied: the library reads the list
/// every time a message passes.
///
/// CONTEXT:
/// - Waits: for the network's lock.
/// - Interrupts: no.
/// - Locks: takes the network's lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The list stays the caller's, and must not change or go while the
/// translator has it: set another first.
///
/// NOTES:
/// InvertString in the SDK makes the list for a string, which is how a
/// key comes to type a word.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CxTranslate`, `InvertString`
///
/// EXAMPLES:
/// ```zig
/// const typed = cx.InvertString(sys, cb, "dir\n", null) orelse return;
/// cb.SetTranslate(translator, typed);
/// ```
pub fn SetTranslate(base: *CxBase, translator: ?*cx.CxObj, events: ?*const ie.InputEvent) void {
    const object = _base.objectOf(translator orelse return);
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.lock);
    if (object.kind == cx.CX_TRANSLATE) object.data.translate = events else object.err |= cx.COERR_BADTYPE;
    sys.ReleaseSemaphore(&base.lock);
}
