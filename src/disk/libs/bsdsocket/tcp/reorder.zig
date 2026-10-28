// SPDX-License-Identifier: MIT
//! Segments that came before their turn: held, in sequence order, until
//! the hole in front of them is filled, then moved into the receive ring.
//!
//! A held segment keeps only its data, in a frame of its own, with its
//! sequence number where a datagram keeps its sender. All that is held
//! together may not be more than the room left in the receive ring - what
//! the window offered - nor more than `held_max` frames, so a peer cannot
//! fill the stack's frames with segments that never become whole, however
//! wide a scaled window is or however small the segments. What does not
//! fit is dropped; the peer sends it again.

const sdk = @import("sdk");
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const _frame = @import("../frame/_frame.zig");
const Frame = _frame.Frame;
const _tcp = @import("_tcp.zig");
const Tcb = _tcp.Tcb;
const sack = @import("sack.zig");

/// The most segments one connection holds: a quarter of the stack's
/// frames, about 180 KiB of full segments.
const held_max = _frame.frames_max / 4;

fn sequenceOf(frame: *const Frame) u32 {
    return frame.sequence;
}

/// `data`, which starts at `sequence` past RCV.NXT, held; it is the
/// segment held last, whose block a SACK option names first.
pub fn hold(stack: *StackBase, tcb: *Tcb, sequence: u32, data: []const u8) void {
    const sys = stack.sys_base;
    const length: u32 = @intCast(data.len);
    tcb.held_last = sequence;
    if (length == 0 or tcb.held_bytes + length > tcb.receive.space() or tcb.held_count >= held_max) return;
    // Where it goes: before the first held segment that starts after it.
    var before: ?*Frame = null;
    var it = tcb.held.iterator();
    while (it.next()) |node| {
        const frame: *Frame = @fieldParentPtr("node", node);
        const start = sequenceOf(frame);
        // One already held that covers it: nothing new, but a copy the
        // peer is told of.
        if (_tcp.atOrBefore(start, sequence) and _tcp.atOrAfter(start +% frame.length, sequence +% length)) {
            sack.copied(tcb, sequence, sequence +% length);
            return;
        }
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
    frame.sequence = sequence;
    if (before) |next| {
        // Insert puts a node at the list's head when it has no
        // predecessor, which the first node's is the head of the list.
        const predecessor = next.node.pred.?;
        sys.Insert(&tcb.held, &frame.node, if (predecessor == tcb.held.headNode()) null else predecessor);
    } else {
        sys.AddTail(&tcb.held, &frame.node);
    }
    tcb.held_bytes += length;
    tcb.held_count += 1;
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
        tcb.held_count -= 1;
        const end = start +% frame.length;
        if (_tcp.after(end, tcb.rcv_nxt)) {
            const skip = tcb.rcv_nxt -% start;
            const taken = _tcp.deliver(tcb, frame.bytes()[skip..]);
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
    tcb.held_count = 0;
}
