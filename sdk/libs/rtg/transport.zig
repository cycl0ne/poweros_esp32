// SPDX-License-Identifier: MIT
//! Command buses.
//!
//! A display that is not wired straight to the pixels is reached over a
//! bus: a command, some parameters, and runs of pixels. The bus and the
//! panel are two different things - the same controller turns up on more
//! than one bus, and the same bus carries more than one kind of panel - so
//! a transport is its own handle, made by its own driver, and a board's
//! driver opens the one its device sits on (`OpenTransport`).
//!
//! What crosses the bus is a command and then either its parameters or a
//! run of pixels. How a part wants them framed is its bus driver's
//! business, configured by the driver's own tags.

const nodes = @import("../exec/nodes.zig");

const Node = nodes.Node;
const RtgBase = @import("../../interface/rtg.zig").RtgBase;

/// A bus a board talks through.
pub const RtgTransport = extern struct {
    /// ln_Name is the bus's name: its driver's.
    node: Node = .{},
    rtg_base: ?*RtgBase = null,
    /// The *RtgDriver that made it, one of kind RTGDT_TRANSPORT.
    driver: ?*anyopaque = null,
    ops: ?*const RtgTransportOps = null,
    /// Whoever opened it's own, untouched by the library and the bus's
    /// driver.
    user_data: ?*anyopaque = null,
    /// The driver's own data: `instance_size` bytes the library allocated
    /// and cleared when the bus was made, and frees with it.
    instance: ?*anyopaque = null,
    instance_size: u32 = 0,
};

pub const RtgTransportOps = extern struct {
    destroy: ?*const fn (*RtgTransport) callconv(.c) void = null,
    /// A command and its parameters. A command below zero sends the
    /// parameters alone.
    tx_param: ?*const fn (*RtgTransport, i32, ?*const anyopaque, u32) callconv(.c) i32 = null,
    /// A command and a run of pixels. It comes back when the bytes have
    /// gone: the caller's memory is its own again.
    tx_color: ?*const fn (*RtgTransport, i32, ?*const anyopaque, u32) callconv(.c) i32 = null,
    /// Send a command and read `size` bytes back, with nothing else
    /// reaching the bus in between.
    rx_param: ?*const fn (*RtgTransport, i32, ?*anyopaque, u32) callconv(.c) i32 = null,
};
