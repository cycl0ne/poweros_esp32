// SPDX-License-Identifier: MPL-2.0
//! CallHookPkt: calls a hook's h_Entry with the hook, an object and a
//! message, and returns what it returns.

const std = @import("std");
const sdk = @import("sdk");

const UtilityBase = @import("../utility.zig").UtilityBase;
const Hook = sdk.utility.Hook;

/// Calls a hook with an object and a message.
///
/// SYNOPSIS:
/// ```zig
/// fn CallHookPkt(_: *UtilityBase, hook: *Hook, object: ?*anyopaque, param_packet: ?*anyopaque) usize
/// ```
///
/// SINCE: 1.0. LVO -68.
///
/// INPUTS:
/// - `hook` - the hook. One without an `h_Entry` does nothing.
/// - `object` - what the hook works on, handed on as it is.
/// - `param_packet` - the message, handed on as it is.
///
/// RESULT:
/// What `h_Entry` returns, or 0 for a hook without one.
///
/// BEHAVIOR:
/// `h_Entry(hook, object, param_packet)`. The hook is passed to its own
/// function, which is how the function finds its context: `h_Data`, or the
/// structure the hook is embedded in. Nothing is looked at or checked on
/// the way.
///
/// CONTEXT:
/// - Waits: only if the hook's function does.
/// - Interrupts: as far as the hook's function allows.
/// - Forbid: not taken; the hook's function decides what it needs.
/// - Process: whatever the hook's function needs.
///
/// OWNERSHIP:
/// Nothing is allocated. The object and the message stay the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Hook`
///
/// EXAMPLES:
/// ```zig
/// fn count(hook: *Hook, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) usize {
///     const total: *usize = @ptrCast(@alignCast(hook.data.?));
///     total.* += 1;
///     return total.*;
/// }
///
/// var hook: Hook = .{ .entry = count, .data = &total };
/// _ = ub.CallHookPkt(&hook, null, null);
/// ```
pub fn CallHookPkt(_: *UtilityBase, hook: *Hook, object: ?*anyopaque, param_packet: ?*anyopaque) usize {
    const entry = hook.entry orelse return 0;
    return entry(hook, object, param_packet);
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

var seen: struct { hook: ?*Hook = null, object: ?*anyopaque = null, message: ?*anyopaque = null } = .{};

fn remember(hook: *Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    seen = .{ .hook = hook, .object = object, .message = message };
    const count: *usize = @ptrCast(@alignCast(hook.data.?));
    count.* += 1;
    return count.*;
}

test "CallHookPkt calls h_Entry with the hook, the object and the message" {
    const ub: *UtilityBase = undefined; // CallHookPkt never reads it
    var count: usize = 41;
    var object: u32 = 1;
    var message: u32 = 2;
    var hook: Hook = .{ .entry = remember, .data = &count };
    try testing.expectEqual(@as(usize, 42), CallHookPkt(ub, &hook, &object, &message));
    try testing.expectEqual(&hook, seen.hook.?);
    try testing.expectEqual(@as(?*anyopaque, &object), seen.object);
    try testing.expectEqual(@as(?*anyopaque, &message), seen.message);

    var empty: Hook = .{};
    try testing.expectEqual(@as(usize, 0), CallHookPkt(ub, &empty, null, null));
}
