// SPDX-License-Identifier: MIT
//! Hooks: a function with a data pointer, called with an object and a
//! message. Libraries call back into applications through them. `h_Entry`
//! is a C function that gets the hook, the object and the message, in
//! that order.

const MinNode = @import("../exec/nodes.zig").MinNode;

pub const HookFn = *const fn (hook: *Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize;

/// struct Hook.
pub const Hook = extern struct {
    /// h_MinNode: for lists of hooks.
    node: MinNode = .{},
    /// h_Entry: what CallHookPkt calls.
    entry: ?HookFn = null,
    /// h_SubEntry: the hook's own, for whatever its owner wants: a second
    /// function `h_Entry` hands on to, for instance.
    sub_entry: ?*const anyopaque = null,
    /// h_Data: the owner's.
    data: ?*anyopaque = null,
};
