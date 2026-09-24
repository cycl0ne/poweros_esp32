// SPDX-License-Identifier: MIT
//! Interrupts (exec/interrupts.h). Interrupt numbers are the ESP32-S3's
//! peripheral interrupt sources.

const Node = @import("nodes.zig").Node;
const List = @import("lists.zig").List;

/// struct Interrupt.
pub const Interrupt = extern struct {
    /// is_Node: ln_Type NT_INTERRUPT; ln_Pri sets the order on its list.
    node: Node = .{ .type = .interrupt },
    /// is_Data: handed to the code.
    data: ?*anyopaque = null,
    /// is_Code: the function; its type depends on the list (IntHandlerFn,
    /// IntServerFn, SoftIntFn, MemHandlerFn).
    code: ?*const anyopaque = null,
};

/// struct IntVector: what exec does when one interrupt number fires. Read
/// it with the IntVector call, under Forbid, the way exec's lists are read.
pub const IntVector = extern struct {
    /// Set with SetIntVector: one function, instead of the chain.
    handler: ?*Interrupt = null,
    /// The AddIntServer chain, by priority.
    servers: List = .{},
    /// How often the number was dispatched.
    count: u32 = 0,
};

/// is_Code of a handler (SetIntVector).
pub const IntHandlerFn = *const fn (is_data: ?*anyopaque, int_number: u32) callconv(.c) void;

/// is_Code of a server (AddIntServer). Return non-zero if the interrupt was
/// yours and the chain should stop, 0 to pass it on.
pub const IntServerFn = *const fn (is_data: ?*anyopaque, int_number: u32) callconv(.c) i32;

/// is_Code of a software interrupt (Cause).
pub const SoftIntFn = *const fn (is_data: ?*anyopaque) callconv(.c) void;
