// SPDX-License-Identifier: MPL-2.0
//! ps2.resource's base: what the machine's keyboard controller has
//! plugged in, the bytes its interrupts took, and the task that turns
//! them into keys and moves.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const port = @import("port/_port.zig");

/// How many bytes are kept between an interrupt and the task: a power
/// of two, several packets and keys deep.
pub const ring_size = 256;

pub const Ps2Base = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// What the controller has: itself, a pointing device, its wheel.
    controller: bool = false,
    pointer: bool = false,
    wheel: bool = false,
    /// The servers on the keyboard's and the pointing device's lines.
    key_server: exec.Interrupt = .{},
    pointer_server: exec.Interrupt = .{},
    /// The bytes taken, each with `from_pointer` in its ninth bit: put
    /// in at `head` by the servers, taken out at `tail` by the task.
    ring: [ring_size]u16 = @splat(0),
    head: u32 = 0,
    tail: u32 = 0,
    /// Bytes that came with the ring full.
    lost: u32 = 0,
    task: exec.Task = .{},
    stack: ?*anyopaque = null,
    /// The signal the servers wake the task with; 0 without one.
    byte_signal: u32 = 0,
    starter: ?*exec.Task = null,
    start_signal: u32 = 0,
};

/// A byte's ninth bit in the ring: it is the pointing device's.
pub const from_pointer: u16 = 1 << 8;

pub fn ps2Base(lib: *exec.Library) *Ps2Base {
    return @fieldParentPtr("lib", lib);
}

comptime {
    _ = port;
}
