// SPDX-License-Identifier: MPL-2.0
//! The controller: out of reset, and a verb sent to a codec with its
//! answer read.
//!
//! **A verb goes through the immediate command registers, not the
//! rings.** The specification has two ways to reach a codec. One is a
//! pair of rings in memory: commands are written into one and the
//! controller writes answers into the other, and it stops fetching
//! commands once it has written so many answers without being told they
//! were taken - which is built for a driver that keeps a conversation
//! going with a codec while sound plays, and services an interrupt for
//! each batch of answers. The other is three registers: a command, a
//! result, and a bit that says a command is in flight. They carry one
//! verb at a time and answer it before returning.
//!
//! This driver talks to a codec while it is being set up, as a way out
//! is started and stopped, and as the display links are looked at, and
//! waits for each answer where it asked for it, so the second is the one
//! that fits: no memory a controller has to reach, no ring pointers, no
//! acknowledgement protocol, and nothing to get wrong between two verbs.
//! The rings have one job this cannot do - a codec's unsolicited
//! answers, which is how a jack says something was plugged into it - and
//! they can be brought up for that alone when something wants it, with
//! no commands going through them at all.
//!
//! **One verb at a time, whoever sends it.** The registers carry one
//! command, and more than one task talks to a codec - the one that
//! starts a way out, and the one that looks at the display links - so a
//! verb is sent and its answer read under the controller's lock.
//!
//! **Nothing here waits on an interrupt.** Setting a codec up happens at
//! cold start, before there is anything to be interrupted for, and a
//! verb is answered in the time a few frames take on the link. So a verb
//! is sent and its answer waited for by reading the busy bit, with a
//! limit on the wait: a codec that does not answer is one the driver
//! gives up on rather than one the machine stops for.
//!
//! **A reset is two waits, each with a limit.** Clearing the reset bit
//! and waiting for it to read back clear stops the controller; setting
//! it and waiting for it to read back set starts it. Then the codecs
//! need a moment to announce themselves on the link before `statests`
//! says which of them are there - the specification allows them 521
//! microseconds.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const timer = sdk.devices.timer;
const regs = @import("regs.zig");

/// What a controller is while it is being used: where its registers are,
/// what it can do, and what its waits are measured by.
pub const Controller = struct {
    sys: *ExecBase,
    /// timer.device's microsecond unit, opened by whoever made this.
    /// Without one there is nothing to measure a wait with, and the
    /// register polls stand in for it.
    io: ?*timer.TimeRequest = null,
    at: usize = 0,
    /// Whether what the controller reads and writes sees the processors'
    /// caches, so that nothing is written back or thrown away around a
    /// buffer it reads.
    coherent: bool = false,
    /// How many streams of each kind it has, and whether it takes
    /// 64-bit addresses.
    out_streams: u32 = 0,
    in_streams: u32 = 0,
    wide: bool = false,
    /// Held while a verb is in flight, so that the answer read is that
    /// verb's: set up with InitSemaphore by whoever made this.
    lock: exec.SignalSemaphore = .{},

    /// What the processors wrote, written back for the controller.
    pub fn toDevice(c: *Controller, address: usize, bytes: usize) void {
        if (bytes == 0 or c.coherent) return;
        var length: u32 = @intCast(bytes);
        _ = c.sys.CachePreDMA(@ptrFromInt(address), &length, 0);
    }

    /// What the controller wrote, read past the processors' caches.
    pub fn fromDevice(c: *Controller, address: usize, bytes: usize) void {
        if (bytes == 0 or c.coherent) return;
        var length: u32 = @intCast(bytes);
        c.sys.CachePostDMA(@ptrFromInt(address), &length, 0);
    }
};

/// How long a register is waited on, in microseconds. The
/// specification's waits are in hundreds of microseconds; this is far
/// past all of them, and a controller that has not answered by here is
/// one that is not going to.
const wait_limit: u32 = 100_000;

/// How long a verb's answer is waited for.
const answer_limit: u32 = 10_000;

/// The controller taken through its reset, and which codecs answered
/// afterwards - a bit per serial data in line. Null where it does not
/// come out of reset.
pub fn reset(c: *Controller) ?u16 {
    const at = c.at;
    // Everything turned off before the reset, so that nothing is left
    // running across it: the interrupts, both rings - which this driver
    // does not use, but a firmware may have started - and the buffer the
    // controller writes stream positions into.
    regs.write32(at, regs.intctl, 0);
    regs.write8(at, regs.corbctl, 0);
    regs.write8(at, regs.rirbctl, 0);
    regs.write32(at, regs.dplbase, 0);
    regs.write32(at, regs.dpubase, 0);

    var waited: u32 = 0;
    regs.write32(at, regs.gctl, regs.read32(at, regs.gctl) & ~regs.gctl_crst);
    while (regs.read32(at, regs.gctl) & regs.gctl_crst != 0) {
        if (waited >= wait_limit) return null;
        waited += pause(c, 10);
    }
    // The specification asks for a short wait with the reset held before
    // it is let go of again.
    _ = pause(c, 100);
    waited = 0;
    regs.write32(at, regs.gctl, regs.read32(at, regs.gctl) | regs.gctl_crst);
    while (regs.read32(at, regs.gctl) & regs.gctl_crst == 0) {
        if (waited >= wait_limit) return null;
        waited += pause(c, 10);
    }
    // The codecs announce themselves on the link now; 521 microseconds
    // is what the specification allows them.
    _ = pause(c, 600);
    const answered = regs.read16(at, regs.statests);
    // The bits are written back to clear them, so that a codec which
    // arrives later is a change and not a state.
    regs.write16(at, regs.statests, answered);

    const capability = regs.read16(at, regs.gcap);
    c.out_streams = (capability & regs.gcap_oss) >> 12;
    c.in_streams = (capability & regs.gcap_iss) >> 8;
    c.wide = capability & regs.gcap_64ok != 0;
    return answered;
}

/// A verb sent to a node of a codec and its answer, or null where none
/// came. `payload` is the verb's own bits: twelve of verb and eight of
/// payload, or four and sixteen, as the verb says.
pub fn verb(c: *Controller, codec: u4, node: u8, payload: u20) ?u32 {
    const command: u32 = (@as(u32, codec) << 28) | (@as(u32, node) << 20) | payload;
    const at = c.at;
    c.sys.ObtainSemaphore(&c.lock);
    defer c.sys.ReleaseSemaphore(&c.lock);

    // Nothing in flight before this one. A controller left busy by
    // whoever had it before is waited for rather than written over.
    var waited: u32 = 0;
    while (regs.read16(at, regs.irs) & regs.irs_busy != 0) {
        if (waited >= answer_limit) {
            why(c, "the controller is still busy with an earlier verb", .{});
            return null;
        }
        waited += pause(c, 10);
    }
    // Any answer still standing is cleared, so that the bit which says
    // one has arrived can only mean this verb's.
    regs.write16(at, regs.irs, regs.irs_valid);
    regs.write32(at, regs.ic, command);
    regs.write16(at, regs.irs, regs.irs_busy);

    waited = 0;
    while (true) {
        const status = regs.read16(at, regs.irs);
        if (status & regs.irs_valid != 0) break;
        if (waited >= answer_limit) {
            why(c, "codec %d node %d: no answer, status %x", .{
                @as(u32, codec), @as(u32, node), @as(u32, status),
            });
            return null;
        }
        waited += pause(c, 10);
    }
    const answer = regs.read32(at, regs.ir);
    regs.write16(at, regs.irs, regs.irs_valid);
    return answer;
}

/// Why a verb came back with nothing, which is otherwise silent: the
/// controller's own state at the moment it gave up. Debug lines.
fn why(c: *Controller, comptime text: [:0]const u8, args: anytype) void {
    sdk.exec.klog(c.sys, exec.LOG_DEBUG, "rta-hda: " ++ text ++ "\n", args);
}

/// `us` microseconds given up, and how many were - which is what every
/// wait on this controller counts, so a controller with no timer to wait
/// on still gives up after a bounded number of turns rather than never.
pub fn pause(c: *Controller, us: u32) u32 {
    const io = c.io orelse {
        // No timer: a read of a register that cannot be cached is the
        // turn's cost, and the count stands for the time it took.
        var turns: u32 = 0;
        while (turns < us) : (turns += 1) _ = regs.read32(c.at, regs.walclk);
        return us;
    };
    io.node.command = timer.TR_ADDREQUEST;
    io.time = timer.TimeVal.fromMicros(us);
    _ = c.sys.DoIO(&io.node);
    return us;
}
