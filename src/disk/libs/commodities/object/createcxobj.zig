// SPDX-License-Identifier: MIT
//! CreateCxObj: a new object of the network.

const sdk = @import("sdk");
const cx = sdk.commodities;
const _base = @import("../commodities_base.zig");
const _object = @import("_object.zig");
const _broker = @import("../broker/_broker.zig");
const CxBase = _base.CxBase;

/// Makes a new object of the network.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateCxObj(base: *CxBase, kind: u32, arg1: usize, arg2: usize) ?*cx.CxObj
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `kind` - CX_FILTER, CX_SEND, CX_SIGNAL, CX_TRANSLATE, CX_BROKER,
///   CX_DEBUG or CX_CUSTOM.
/// - `arg1`, `arg2` - what the kind needs: a filter's description (or
///   0); a sender's port and id; a signal object's task and signal
///   number; a translator's events (or 0); a broker's NewBroker; a debug
///   object's id; a custom object's function and id.
///
/// RESULT:
/// The object, active - a broker inactive - and on no list; null without
/// memory, for a kind there is none of, and for a broker without a
/// NewBroker.
///
/// BEHAVIOR:
/// Programs call it through the SDK's CxFilter, CxSender, CxSignal,
/// CxTranslate, CxDebug and CxCustom, and CxBroker for a broker, which
/// also puts it on the network's list. A filter's description is parsed
/// at once (SetFilter): one that makes no sense still makes the filter,
/// with COERR_BADFILTER recorded in it, matching nothing.
///
/// CONTEXT:
/// - Waits: for the network's lock, only for a filter.
/// - Interrupts: no.
/// - Locks: takes the network's lock for a filter's condition.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The object is the caller's, to attach to a broker's tree or delete
/// (DeleteCxObj, DeleteCxObjAll). A translator's events and a sender's
/// port stay the caller's and must outlast the object.
///
/// NOTES:
/// An object attached under a broker is deleted with it by
/// DeleteCxObjAll, which is how a program usually ends.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CxBroker`, `AttachCxObj`, `DeleteCxObjAll`, `CxObjError`
///
/// EXAMPLES:
/// ```zig
/// const filter = cx.CxFilter(cb, "rawkey ctrl alt f1");
/// cb.AttachCxObj(broker, filter);
/// cb.AttachCxObj(filter, cx.CxSender(cb, port, 1));
/// ```
pub fn CreateCxObj(base: *CxBase, kind: u32, arg1: usize, arg2: usize) ?*cx.CxObj {
    if (kind == cx.CX_INVALID or kind > cx.CX_CUSTOM) return null;
    if (kind == cx.CX_BROKER and arg1 == 0) return null;
    const object = _object.make(base, kind) orelse return null;
    const id: i32 = @bitCast(@as(u32, @truncate(arg2)));
    switch (kind) {
        cx.CX_FILTER => {
            object.data = .{ .filter = .{} };
            base.iface().SetFilter(_base.handleOf(object), @ptrFromInt(arg1));
        },
        cx.CX_SEND => object.data = .{ .send = .{ .port = @ptrFromInt(arg1), .id = id } },
        cx.CX_SIGNAL => object.data = .{ .signal = .{ .task = @ptrFromInt(arg1), .signal = @as(u32, @truncate(arg2)) & 31 } },
        cx.CX_TRANSLATE => object.data = .{ .translate = @ptrFromInt(arg1) },
        cx.CX_BROKER => _broker.initBroker(base, object, @ptrFromInt(arg1)),
        cx.CX_DEBUG => object.data = .{ .debug = @bitCast(@as(u32, @truncate(arg1))) },
        cx.CX_CUSTOM => object.data = .{ .custom = .{ .action = @ptrFromInt(arg1), .id = id } },
        else => unreachable,
    }
    return _base.handleOf(object);
}
