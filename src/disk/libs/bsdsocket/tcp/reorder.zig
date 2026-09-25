// SPDX-License-Identifier: MIT
//! Segments that came before their turn: held, in sequence order, until
//! the hole in front of them is filled, then moved into the receive ring.
//!
//! A held segment keeps only its data, in a frame of its own, with its
//! sequence number where a datagram keeps its sender. All that is held
//! together may not be more than the room left in the receive ring - what
//! the window offered - so a peer cannot fill the stack's frames with
//! segments that never become whole. What does not fit is dropped; the
//! peer sends it again.

const sdk = @import("sdk");
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const Frame = @import("../frame/_frame.zig").Frame;
const _tcp = @import("_tcp.zig");
const Tcb = _tcp.Tcb;

fn sequenceOf(frame: *const Frame) u32 {
    return frame.from_address;
}

/// `data`, which starts at `sequence` past RCV.NXT, held.
pub fn hold(stack: *StackBase, tcb: *Tcb, sequence: u32, data: []const u8) void {
    const sys = stack.sys_base;
    const length: u32 = @intCast(data.len);
    if (length == 0 or tcb.held_bytes + length > tcb.receive.space()) return;
    // Where it goes: before the first held segment that starts after it.
    var before: ?*Frame = null;
    var it = tcb.held.iterator();
    while (it.next()) |node| {
        const frame: *Frame = @fieldParentPtr("node", node);
        const start = sequenceOf(frame);
        // One already held that covers it: nothing new.
        if (_tcp.atOrBefore(start, sequence) and _tcp.atOrAfter(start +% frame.length, sequence +% length)) return;
        if (_tcp.after(start, sequence)) {
            before = frame;
            break;
        }
    }
    const frame = stack.frames.take(sys) orelse return;
    if (length > frame.capacity - frame.start) {
        stack.frames.give(sys, frame);
        return;
    }
    @memcpy(frame.room()[frame.start..][0..length], data);
    frame.length = length;
    frame.from_address = sequence;
    if (before) |next| {
        // Insert puts a node at the list's head when it has no
        // predecessor, which the first node's is the head of the list.
        const predecessor = next.node.pred.?;
        sys.Insert(&tcb.held, &frame.node, if (predecessor == tcb.held.headNode()) null else predecessor);
    } else {
        sys.AddTail(&tcb.held, &frame.node);
    }
    tcb.held_bytes += length;
}

/// What the held segments have that starts at RCV.NXT, moved into the
/// receive ring, as far as it goes on without a hole: how many bytes.
pub fn release(stack: *StackBase, tcb: *Tcb) u32 {
    const sys = stack.sys_base;
    var moved: u32 = 0;
    while (tcb.held.first()) |node| {
        const frame: *Frame = @fieldParentPtr("node", node);
        const start = sequenceOf(frame);
        if (_tcp.after(start, tcb.rcv_nxt)) break;
        sys.Remove(node);
        tcb.held_bytes -= frame.length;
        const end = start +% frame.length;
        if (_tcp.after(end, tcb.rcv_nxt)) {
            const skip = tcb.rcv_nxt -% start;
            const taken = tcb.receive.write(frame.bytes()[skip..]);
            tcb.rcv_nxt +%= taken;
            moved += taken;
        }
        stack.frames.give(sys, frame);
    }
    return moved;
}

/// Everything held given back, when the connection goes.
pub fn clear(stack: *StackBase, tcb: *Tcb) void {
    const sys = stack.sys_base;
    while (sys.RemHead(&tcb.held)) |node| stack.frames.give(sys, @fieldParentPtr("node", node));
    tcb.held_bytes = 0;
}
