// SPDX-License-Identifier: MPL-2.0
//! The power manager: a processor of the device's own, whose firmware the
//! machine's firmware started, and which powers the device's other blocks
//! up and runs their clocks. It is told what to do through a mailbox.
//!
//! **The mailbox** is three registers of the power manager's second
//! segment: the message, its argument, and the answer. The answer reads
//! nonzero once the manager has taken the last message, so a message is
//! sent only when it does: the answer cleared, the argument written, then
//! the message, and the answer waited for again. What the manager hands
//! back is in the argument register. An answer of 1 means done. The
//! answer is read over and over for as long as one tick of the system's
//! lasts, as the vendor's driver reads it (smu_cmn_poll_stat), so that a
//! message the manager answers within that is answered as soon as it is;
//! after that it is looked at once each tick.
//!
//! One message at a time: the mailbox is the device's, and the resource
//! is the one thing that writes it.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const reg = sdk.hardware.mmio.reg;
const systimer = sdk.hardware.systimer;
const AMDGPUBase = @import("../amdgpu_base.zig").AMDGPUBase;

/// The mailbox's registers, counted in 32-bit words from the power
/// manager's second address.
const segment = 1;
const mailbox_message = 0x282;
const mailbox_argument = 0x292;
const mailbox_answer = 0x29a;

/// What the manager answers: done, and the answers that are not.
pub const ANSWER_DONE: u32 = 0x01;

/// The messages sent, as the manager whose messages are known numbers
/// them (`known`): its firmware's version, then each block powered down
/// and up - the video decoder with its instance in the argument's upper
/// half, the JPEG decoder with 0 - the graphics block let off while it is
/// idle and kept powered, its power controller (IMU) started, with the
/// controller's own switching off of the block allowed (1), once its
/// firmware is in the security processor's region, and the graphics
/// block's clock and the data fabric's asked for, with 0.
pub const MESSAGE_FIRMWARE_VERSION: u32 = 0x02;
pub const MESSAGE_POWER_DOWN_VIDEO: u32 = 0x06;
pub const MESSAGE_POWER_UP_VIDEO: u32 = 0x07;
pub const MESSAGE_START_GRAPHICS_CONTROLLER: u32 = 0x16;
pub const MESSAGE_GRAPHICS_CLOCK: u32 = 0x17;
pub const MESSAGE_FABRIC_CLOCK: u32 = 0x18;
pub const MESSAGE_ALLOW_GRAPHICS_OFF: u32 = 0x19;
pub const MESSAGE_DISALLOW_GRAPHICS_OFF: u32 = 0x1A;
pub const MESSAGE_POWER_DOWN_JPEG: u32 = 0x21;
pub const MESSAGE_POWER_UP_JPEG: u32 = 0x22;
pub const GRAPHICS_CONTROLLER_MAY_SWITCH_OFF: u32 = 1;

/// The manager whose messages are numbered so. Another numbers them
/// otherwise and is sent none of them but the version's, which every
/// manager answers the same.
const known = .{ .major = 13, .minor = 0, .revision = 4 };

/// The manager kept in the base where its messages are known, so that
/// SetGPUPower sends them.
pub fn take(ab: *AMDGPUBase, manager: amdgpu.GPUBlock) void {
    if (manager.major != known.major or manager.minor != known.minor or manager.revision != known.revision) return;
    ab.power = manager;
    ab.power_known = true;
}

/// How long an answer is waited for; for how long of that the answer is
/// read over and over, one tick of the system's at its 100 a second; and
/// how often it is looked at after.
const answer_most_us: u64 = 1_000_000;
const answer_spin_us: u64 = 10_000;
const answer_step_us: u32 = 100;

/// What a message was answered with: the answer, and what the manager
/// handed back.
pub const Answer = struct { answer: u32, value: u32 };

/// `message` sent with `argument`: what the manager answered, or null
/// where it did not take the last message, or this one, in time.
pub fn send(ab: *AMDGPUBase, manager: amdgpu.GPUBlock, message: u32, argument: u32) ?Answer {
    if (manager.count <= segment) return null;
    const at = @as(usize, @intCast(ab.info.registers)) + @as(usize, manager.addresses[segment]) * 4;
    if (!answered(ab, at)) return null;
    reg(at + mailbox_answer * 4).* = 0;
    reg(at + mailbox_argument * 4).* = argument;
    reg(at + mailbox_message * 4).* = message;
    if (!answered(ab, at)) return null;
    return .{
        .answer = reg(at + mailbox_answer * 4).*,
        .value = reg(at + mailbox_argument * 4).*,
    };
}

/// Whether the answer register reads nonzero within the time an answer
/// is waited for: read over and over for `answer_spin_us`, then once
/// each step.
///
/// The time is the machine's clock, not the steps counted: a wait is
/// woken by the system's tick, so a step lasts longer than it asks for -
/// a whole tick where it begins just after one, which is why the answer
/// is read without waiting first.
fn answered(ab: *AMDGPUBase, at: usize) bool {
    const sys = ab.sys_base;
    const began = sys.UptimeUs();
    while (reg(at + mailbox_answer * 4).* == 0) {
        const waited = sys.UptimeUs() -% began;
        if (waited > answer_most_us) return false;
        if (waited > answer_spin_us) pause(ab, answer_step_us);
    }
    return true;
}

/// A wait of so many microseconds, at the least.
fn pause(ab: *AMDGPUBase, us: u32) void {
    var never: exec.Waitable = .{};
    const list = [_]*exec.Waitable{&never};
    _ = ab.sys_base.WaitForAny(&list, 1, us);
}

/// `message` sent with `argument` under the mailbox's lock: what the
/// manager handed back once it says done, or null where it refuses or
/// does not answer, which is put on the system's lines.
pub fn read(ab: *AMDGPUBase, message: u32, argument: u32) ?u32 {
    const sys = ab.sys_base;
    sys.ObtainSemaphore(&ab.mailbox_lock);
    defer sys.ReleaseSemaphore(&ab.mailbox_lock);
    const answer = send(ab, ab.power, message, argument) orelse {
        exec.kprintf(sys, "%s: the power manager does not answer message %x\n", .{ amdgpu.AMDGPUNAME, message });
        return null;
    };
    if (answer.answer != ANSWER_DONE) {
        exec.kprintf(sys, "%s: the power manager answers %x to message %x\n", .{ amdgpu.AMDGPUNAME, answer.answer, message });
        return null;
    }
    return answer.value;
}

/// The manager's state, said: its firmware's version, asked for, which is
/// the one message sent before anything is to be powered up - it proves
/// the mailbox answers.
pub fn tell(ab: *AMDGPUBase, manager: amdgpu.GPUBlock) void {
    const sys = ab.sys_base;
    const owner = sdk.resources.amdgpu.AMDGPUNAME;
    const answer = send(ab, manager, MESSAGE_FIRMWARE_VERSION, 0) orelse {
        exec.kprintf(sys, "%s: the power manager does not answer its mailbox\n", .{owner});
        return;
    };
    if (answer.answer != ANSWER_DONE) {
        exec.kprintf(sys, "%s: the power manager answers %x when asked its version\n", .{ owner, answer.answer });
        return;
    }
    exec.kprintf(sys, "%s: the power manager's firmware is %d.%d.%d\n", .{
        owner, answer.value >> 16 & 0xff, answer.value >> 8 & 0xff, answer.value & 0xff,
    });
}
