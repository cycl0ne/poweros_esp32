// SPDX-License-Identifier: MIT
//! Command buses.
//!
//! A display that is not wired straight to the pixels is reached over a
//! bus: a command, some parameters, and runs of pixels. The bus and the
//! panel are two different things - the same controller turns up on more
//! than one bus, and the same bus carries more than one kind of panel - so
//! a transport is its own handle, made by its own driver, and a board is
//! given one to talk through.
//!
//! What crosses the bus is a command word and then either parameter words
//! or pixels, each at its own width, behind however many control bytes the
//! part wants in front. Which of those bytes' bits says "this is data and
//! not a command" is the part's business, so it is configured, not
//! assumed.

const nodes = @import("../exec/nodes.zig");
const lists = @import("../exec/lists.zig");
const events = @import("events.zig");

const Node = nodes.Node;
const List = lists.List;
const RtgBase = @import("../../interface/rtg.zig").RtgBase;

/// A bus a board talks through.
pub const RtgTransport = extern struct {
    /// ln_Name is the instance's name ("i2c0").
    node: Node = .{},
    rtg_base: ?*RtgBase = null,
    /// An *RtgDriver of type RTGDT_TRANSPORT.
    driver: ?*anyopaque = null,
    ops: ?*const RtgTransportOps = null,
    /// Bits a command word and bits a parameter word on this bus.
    cmd_bits: u32 = 8,
    param_bits: u32 = 8,
    /// How many control bytes go in front of every transfer, and which bit
    /// of them says that what follows is pixels rather than a command.
    control_bytes: u32 = 0,
    dc_bit: u32 = 0,
    flags: u32 = 0,
    /// How many boards were given this bus. DeleteTransport refuses while
    /// it is not zero.
    open_cnt: u16 = 0,
    pad: u16 = 0,
    event_lists: [events.RTGEV_COUNT]List = [_]List{.{}} ** events.RTGEV_COUNT,
    user_data: ?*anyopaque = null,
    /// The driver's own data: `instance_size` bytes the library allocated
    /// and cleared when the bus was made, and frees with it.
    instance: ?*anyopaque = null,
    instance_size: u32 = 0,
};

/// RtgTransport.flags: a clear data bit means pixels and a set one means a
/// command, rather than the other way round.
pub const RTGTRF_DC_LOW_ON_DATA: u32 = 1 << 0;

pub const RtgTransportOps = extern struct {
    destroy: ?*const fn (*RtgTransport) callconv(.c) void = null,
    /// A command and its parameters. A command below zero sends the
    /// parameters alone.
    tx_param: ?*const fn (*RtgTransport, i32, ?*const anyopaque, u32) callconv(.c) i32 = null,
    /// A command and a run of pixels. It may come back before the bytes
    /// have gone; RTGEV_TX_DONE says when they have.
    tx_color: ?*const fn (*RtgTransport, i32, ?*const anyopaque, u32) callconv(.c) i32 = null,
    /// Send a command and read `size` bytes back, with nothing else
    /// reaching the bus in between.
    rx_param: ?*const fn (*RtgTransport, i32, ?*anyopaque, u32) callconv(.c) i32 = null,
};
