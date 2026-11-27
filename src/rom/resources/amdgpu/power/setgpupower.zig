// SPDX-License-Identifier: MPL-2.0
//! SetGPUPower: a block of the device powered up or down by its power
//! manager. Which decoders it has powered up since the machine started
//! is kept in the base, so that a decoder's first power-down follows its
//! first power-up.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;
const _power = @import("_power.zig");

/// A block of the device powered up or down by its power manager.
///
/// SYNOPSIS:
/// ```zig
/// fn SetGPUPower(ab: *AMDGPUBase, part: u32, instance: u32, on: bool) bool
/// ```
///
/// SINCE: 1.1. LVO -12.
///
/// INPUTS:
/// - `part` - GPUPOWER_VIDEO, the video decoder; GPUPOWER_JPEG, the
///   JPEG decoder beside it; or GPUPOWER_GRAPHICS (since 1.9), the
///   graphics block.
/// - `instance` - which of them: the video block's instance for the video
///   decoder; 0 for the JPEG decoder and the graphics block, of which
///   there is one.
/// - `on` - true to power it up, false to power it down. The graphics
///   block is kept powered while it is up; down, the manager may switch
///   it off whenever it is idle.
///
/// RESULT:
/// True once the power manager says done. False where it refused - what
/// it answered is put on the system's lines - or did not answer within a
/// second; where `part` or `instance` is not one there is; where the
/// manager is one whose messages the resource does not know; and on a
/// machine without the device.
///
/// BEHAVIOR:
/// One message through the manager's mailbox, under the mailbox's lock.
/// Powering up what is up, or down what is down, is done again and says
/// done - but a decoder is powered down only once this call has powered
/// it up since the machine started (since 1.19): before that it is left
/// as the machine's firmware left it, nothing is sent, and the call says
/// done. The block's clocks are the manager's to run once it is up. For
/// the graphics block the manager is told whether it may switch the
/// block off (its graphics-off state): up forbids it, and brings the
/// block back where it is off; down allows it again.
///
/// CONTEXT:
/// - Waits: yes, for the mailbox and for the manager's answer - a
///   millisecond or so, at most a second.
/// - Interrupts: no.
/// - Locks: takes the mailbox's lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The block is its driver's: the resource powers it, and touches none of
/// its registers.
///
/// NOTES:
/// A powered-up block still has its own gating to let go of, through its
/// registers, before it runs; that is its driver's. The graphics block
/// runs nothing before StartGPUGraphics has started it; a driver that
/// reads its registers keeps it up meanwhile, since the registers of a
/// block switched off do not answer.
///
/// The manager of the NucBox (13.0.4), told to power its video decoder
/// down before anything had powered it up since the machine started,
/// answered nothing after - neither the JPEG decoder's message nor the
/// graphics block's - until the machine was reset. Once a decoder has
/// been powered up, powering it down again and again is answered.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindGPUBlock`, `AllocGPUMemory`, `StartGPUGraphics`
///
/// EXAMPLES:
/// ```zig
/// if (!ab.SetGPUPower(amdgpu.GPUPOWER_JPEG, 0, true)) return error.NoEngine;
/// defer _ = ab.SetGPUPower(amdgpu.GPUPOWER_JPEG, 0, false);
/// ```
pub fn SetGPUPower(ab: *AMDGPUBase, part: u32, instance: u32, on: bool) bool {
    if (ab.device == null or !ab.power_known) return false;
    var video: amdgpu.GPUBlock = .{};
    const message: u32, const argument: u32 = switch (part) {
        amdgpu.GPUPOWER_VIDEO => blk: {
            const gpu: *sdk.interface.amdgpu.AMDGPUBase = @ptrCast(&ab.lib);
            if (instance >= 31 or !gpu.FindGPUBlock(amdgpu.GPUBLOCK_VIDEO, instance, &video)) return false;
            break :blk .{ if (on) _power.MESSAGE_POWER_UP_VIDEO else _power.MESSAGE_POWER_DOWN_VIDEO, instance << 16 };
        },
        amdgpu.GPUPOWER_JPEG => blk: {
            if (instance != 0) return false;
            break :blk .{ if (on) _power.MESSAGE_POWER_UP_JPEG else _power.MESSAGE_POWER_DOWN_JPEG, 0 };
        },
        amdgpu.GPUPOWER_GRAPHICS => blk: {
            if (instance != 0) return false;
            break :blk .{ if (on) _power.MESSAGE_DISALLOW_GRAPHICS_OFF else _power.MESSAGE_ALLOW_GRAPHICS_OFF, 0 };
        },
        else => return false,
    };
    const sys = ab.sys_base;
    const bit = decoderBit(part, instance);
    sys.ObtainSemaphore(&ab.mailbox_lock);
    defer sys.ReleaseSemaphore(&ab.mailbox_lock);
    if (!on and bit != 0 and ab.powered_decoders & bit == 0) return true;
    const answer = _power.send(ab, ab.power, message, argument) orelse {
        exec.kprintf(sys, "%s: the power manager does not answer message %x\n", .{ amdgpu.AMDGPUNAME, message });
        return false;
    };
    if (answer.answer != _power.ANSWER_DONE) {
        exec.kprintf(sys, "%s: the power manager answers %x to message %x\n", .{ amdgpu.AMDGPUNAME, answer.answer, message });
        return false;
    }
    if (on) ab.powered_decoders |= bit;
    return true;
}

/// The bit the base keeps for a decoder powered up: a video decoder's
/// at its instance, the JPEG decoder's the top one; none for the
/// graphics block.
fn decoderBit(part: u32, instance: u32) u32 {
    return switch (part) {
        amdgpu.GPUPOWER_VIDEO => @as(u32, 1) << @intCast(instance),
        amdgpu.GPUPOWER_JPEG => 1 << 31,
        else => 0,
    };
}
