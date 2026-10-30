// SPDX-License-Identifier: MIT
//! CxMsgID: the id a commodity message carries.

const sdk = @import("sdk");
const cx = sdk.commodities;
const _base = @import("../commodities_base.zig");
const CxBase = _base.CxBase;

/// Answers the id a commodity message carries.
///
/// SYNOPSIS:
/// ```zig
/// fn CxMsgID(base: *CxBase, cxm: *const cx.CxMsg) i32
/// ```
///
/// SINCE: 1.0. LVO -96.
///
/// INPUTS:
/// - `cxm` - a message from a sender, or the one a custom object's
///   function was given; not null.
///
/// RESULT:
/// For an event the id of the sender that sent it, or of the custom
/// object whose function has it; for a command the command, CXCMD_.
///
/// BEHAVIOR:
/// The id is what the program gave the object when it made it, so one
/// port can take the messages of several senders - a hotkey each - and
/// tell them apart. An event no object gave an id has 0.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do; a custom object's function may call it.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// Ids other than 0 make a message nobody sent stand out.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CxMsgType`, `CreateCxObj`
///
/// EXAMPLES:
/// ```zig
/// if (cb.CxMsgType(cxm) == cx.CXM_IEVENT and cb.CxMsgID(cxm) == hotkey_id) showWindow();
/// ```
pub fn CxMsgID(_: *CxBase, cxm: *const cx.CxMsg) i32 {
    return _base.constMessageOf(cxm).id;
}
