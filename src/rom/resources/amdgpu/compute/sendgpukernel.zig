// SPDX-License-Identifier: MPL-2.0
//! SendGPUKernel: a kernel's dispatch put on the compute engine's queue
//! as one job, its arguments copied into a slot of the queue's own and
//! its private memory in the queue's scratch, made for it where the queue
//! has none that holds it.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;
const amdgpu_base = @import("../amdgpu_base.zig");
const _compute = @import("_compute.zig");

/// A kernel run on the compute engine: its arguments copied, and a job of
/// its dispatch put on the engine's queue.
///
/// SYNOPSIS:
/// ```zig
/// fn SendGPUKernel(ab: *AMDGPUBase, kernel: *const amdgpu.GPUKernel, dispatch: *const amdgpu.GPUDispatch) u32
/// ```
///
/// SINCE: 1.12. LVO -84.
///
/// INPUTS:
/// - `kernel` - the kernel, as FindGPUKernel found it in a loaded code
///   object.
/// - `dispatch` - how many groups it runs in each dimension and how many
///   threads each group has, its arguments, and for a kernel whose stack
///   grows as it runs the bytes each lane is given (GPUDispatch).
///
/// RESULT:
/// The job's number, which WaitGPUCompute waits for; 0 where the queue
/// does not run (StartGPUCompute), where the kernel takes anything a
/// dispatch does not hand it - values in its registers other than the
/// address of its arguments, a trap handler - or more private memory,
/// its stack's with it, than a wave's scratch holds, more than 64 KiB of
/// group memory or 256 bytes of arguments, where a dimension of the
/// dispatch is 0, a group has more than 1024 threads, where the scratch
/// its private memory needs cannot be made - the graphics block's
/// compute units not known, no room in the device's memory, or the queue
/// not idle within a second - or the jobs before it leave no room in its
/// ring within a second. Why a kernel is refused is said in the system's
/// log.
///
/// BEHAVIOR:
/// Under the queue's lock the arguments are copied into the next of the
/// queue's 64 slots of 256 bytes, the rest of the slot cleared, once the
/// job that last took that slot is done. Then a job is put on the queue
/// as SendGPUCompute puts one: the engine's caches made to see memory as
/// the CPU left it; the group's size set, the code's address, its
/// resource words - the group memory it takes put in the second, in
/// blocks of 512 bytes - no limits on where its waves run, the queue's
/// scratch, the slot's address in its first two scalar registers; then
/// its groups dispatched from the first, in waves of 32 lanes where the
/// kernel's properties say so (GPUKERNEL_WAVE32); and the job's end, once
/// every group has run.
///
/// Since 1.16 a kernel's private memory - the bytes its descriptor gives
/// each of its lanes - is the queue's scratch: a piece of the device's
/// memory made the first time a kernel needs one, holding 32 waves for
/// each of the graphics block's compute units, each wave with its lanes'
/// private bytes on 256 bytes and 256 more. A kernel that needs more for
/// a wave than the piece holds waits, under the lock, for every job sent
/// before it to be done; then the piece is given back and made again at
/// its size. Every dispatch is told where the piece is and how many waves
/// of what size it holds, one of a kernel without private memory too, as
/// the waves of one sent before it may still be using it.
///
/// Since 1.21 a kernel whose stack grows as it runs
/// (GPUKERNEL_DYNAMIC_STACK) is given the more of its own private bytes
/// and the dispatch's `stack_bytes` for each lane - 1 KiB
/// (GPUDISPATCH_STACK_BYTES) where it names none - and its scratch is
/// made for that.
///
/// Since 1.22 the queue's own scratch takes a 32nd of the device's
/// memory at most. A kernel whose waves would need more, every wave the
/// piece holds counted, is given a scratch of its own instead, made once
/// every job sent before it is done: for the waves of the groups of its
/// dispatch that can be on the shader engines at once - its groups shared
/// out between them, at least the smaller of 16 groups and 256 lanes an
/// engine - at most every wave the queue's holds. It is given back once
/// its job is done: by the next SendGPUKernel, by a WaitGPUCompute that
/// sees the job done, or by GetGPUComputeState. Until then a kernel
/// without private memory is told of it, and one with private memory
/// waits for that job.
///
/// CONTEXT:
/// - Waits: for a slot and for room in the ring, a second at most each;
///   where the scratch is made again or made for one job, for the queue
///   to be idle, and where a scratch made for one job is in use, for that
///   job, a second at most each.
/// - Interrupts: no.
/// - Locks: takes the queue's lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The arguments are copied: they are the caller's again on return. The
/// memory they name and the code object must stay until the job is done.
/// The scratch is the resource's: the queue's own kept once made, one
/// made for a job given back once that job is done.
///
/// NOTES:
/// The kernel's addresses are the device's: its arguments name memory by
/// its `device` address (AllocGPUMemory, MapGPUMemory). A kernel that
/// reads more of its arguments than the dispatch hands it reads zeros
/// past them, up to 256 bytes. The queue's own scratch grows and is never
/// made smaller, up to a 32nd of the device's memory - on the NucBox, 32
/// waves for each of its 12 compute units, 384 times a wave's bytes, 16
/// MiB at most. A kernel given a scratch of its own runs alone: it waits
/// for the jobs before it, and the next kernel with private memory waits
/// for it.
///
/// BUGS:
/// A kernel that needs the dispatch's own packet, its queue or a dispatch
/// number in its registers, or its arguments loaded into registers
/// before it starts, cannot be run. A stack that grows past the bytes its
/// dispatch gives it is not stopped: the kernel then keeps its frames in
/// memory that is not its own.
///
/// SEE ALSO:
/// `LoadGPUCode`, `FindGPUKernel`, `SendGPUCompute`, `WaitGPUCompute`
///
/// EXAMPLES:
/// ```zig
/// const Arguments = extern struct { out: u64, value: u32, count: u32 };
/// const arguments: Arguments = .{ .out = piece.device, .value = 7, .count = 4096 };
/// const dispatch: amdgpu.GPUDispatch = .{
///     .groups = .{ 4096 / 64, 1, 1 }, .threads = .{ 64, 1, 1 },
///     .arguments = &arguments, .argument_bytes = @sizeOf(Arguments),
/// };
/// const job = ab.SendGPUKernel(&kernel, &dispatch);
/// if (job == 0 or !ab.WaitGPUCompute(job, 1000)) return error.NoCompute;
/// ```
pub fn SendGPUKernel(ab: *AMDGPUBase, kernel: *const amdgpu.GPUKernel, dispatch: *const amdgpu.GPUDispatch) u32 {
    if (ab.device == null or !_compute.runs(ab)) return 0;
    const sys = ab.sys_base;
    const owner = amdgpu.AMDGPUNAME;
    if (_compute.refusal(kernel, dispatch.groups, dispatch.threads, dispatch.argument_bytes, dispatch.stack_bytes)) |why| {
        exec.kprintf(sys, "%s: a kernel at 0x%lx is not run: %s\n", .{ owner, kernel.code, why });
        return 0;
    }
    const given: ?[*]const u8 = @ptrCast(dispatch.arguments);
    if (dispatch.argument_bytes != 0 and given == null) return 0;
    sys.ObtainSemaphore(&ab.compute_lock);
    defer sys.ReleaseSemaphore(&ab.compute_lock);
    // A reset of the whole block, which holds the lock, may leave it
    // stopped.
    if (!ab.compute_running) return 0;

    const slot = ab.compute_slot;
    if (!waitFor(ab, ab.compute_slot_jobs[slot], "a kernel's arguments' slot")) return 0;
    const chosen = scratchFor(ab, kernel, dispatch) orelse return 0;
    const slot_at = _compute.slots_at + slot * _compute.slot_bytes;
    const into: [*]volatile u8 = @ptrCast(_compute.words(ab, slot_at));
    for (0.._compute.slot_bytes) |index| {
        into[index] = if (index < dispatch.argument_bytes) given.?[index] else 0;
    }

    var packets: [_compute.dispatch_words]u32 = undefined;
    _compute.dispatch(&packets, ab.graphics.addresses[0], kernel, dispatch.groups, dispatch.threads, ab.compute.device + slot_at, chosen.scratch);
    const job = _compute.send(ab, &packets);
    if (job == 0) {
        if (chosen.once) _compute.dropOnce(ab);
        return 0;
    }
    if (chosen.once) ab.scratch_once_job = job;
    ab.compute_slot_jobs[slot] = job;
    ab.compute_slot = (slot + 1) % amdgpu_base.compute_slots;
    return job;
}

/// The scratch a dispatch is told of, and whether it was made for that
/// dispatch alone.
const Chosen = struct { scratch: _compute.Scratch, once: bool = false };

/// The scratch a dispatch of `kernel` is told of, under the queue's lock.
/// A scratch made for one job is given back first where that job is done;
/// where it is not, a kernel without private memory is told of it, as
/// that job's waves still use it, and one with private memory waits for
/// the job. Then the queue's own, made first where it holds less for a
/// wave than the kernel needs, its stack's `stack_bytes` with it - once
/// every job sent before it is done, as a piece in use keeps its waves'
/// size - where every wave it holds takes no more than its share of the
/// device's memory; past that, one made for this dispatch alone, for the
/// waves of it that can run at once, once every job sent before it is
/// done. Null where none can be, which is said in the system's log.
fn scratchFor(ab: *AMDGPUBase, kernel: *const amdgpu.GPUKernel, dispatch: *const amdgpu.GPUDispatch) ?Chosen {
    const sys = ab.sys_base;
    const owner = amdgpu.AMDGPUNAME;
    _compute.giveBackOnce(ab);
    const needed = _compute.waveBytes(kernel, dispatch.stack_bytes);
    if (needed == 0 and ab.scratch_once.bytes != 0) return .{ .scratch = onceScratch(ab) };
    if (ab.scratch_once.bytes != 0) {
        if (!waitFor(ab, ab.scratch_once_job, "a kernel's scratch")) return null;
        _compute.dropOnce(ab);
    }
    if (needed <= ab.scratch_wave_bytes) return .{ .scratch = keptScratch(ab) };
    if (ab.compute_units == 0) {
        exec.kprintf(sys, "%s: a kernel at 0x%lx is not run: the graphics block's compute units, which its scratch is made for, are not known\n", .{ owner, kernel.code });
        return null;
    }
    const all = _compute.scratchWaves(ab.shader_engines, ab.compute_units);
    const once = _compute.scratchOnce(needed, all, ab.memory_bytes);
    const wave32 = kernel.properties & amdgpu.GPUKERNEL_WAVE32 != 0;
    const waves = if (once) _compute.onceWaves(dispatch.groups, dispatch.threads, wave32, ab.shader_engines, ab.compute_units, all) else all;
    const bytes = needed * waves;
    if (bytes > std.math.maxInt(u32)) {
        exec.kprintf(sys, "%s: a kernel at 0x%lx is not run: its scratch would take %lu bytes\n", .{ owner, kernel.code, bytes });
        return null;
    }
    if (!waitFor(ab, ab.compute_sent, "a kernel's scratch")) return null;
    const gpu: *sdk.interface.amdgpu.AMDGPUBase = @ptrCast(&ab.lib);
    if (once) {
        if (!gpu.AllocGPUMemory(@intCast(bytes), 4096, &ab.scratch_once)) {
            ab.scratch_once = .{};
            exec.kprintf(sys, "%s: a kernel at 0x%lx is not run: no room in the device's memory for a scratch of %lu bytes for its job\n", .{ owner, kernel.code, bytes });
            return null;
        }
        ab.scratch_once_wave_bytes = @intCast(needed);
        ab.scratch_once_waves = waves;
        ab.scratch_once_made +%= 1;
        exec.kprintf(sys, "%s: a scratch for one job: %u waves of %u bytes at 0x%lx\n", .{ owner, waves, ab.scratch_once_wave_bytes, ab.scratch_once.device });
        return .{ .scratch = onceScratch(ab), .once = true };
    }
    if (ab.scratch.bytes != 0) gpu.FreeGPUMemory(&ab.scratch);
    ab.scratch = .{};
    ab.scratch_wave_bytes = 0;
    ab.scratch_waves = 0;
    if (!gpu.AllocGPUMemory(@intCast(bytes), 4096, &ab.scratch)) {
        exec.kprintf(sys, "%s: a kernel at 0x%lx is not run: no room in the device's memory for its scratch of %lu bytes\n", .{ owner, kernel.code, bytes });
        return null;
    }
    ab.scratch_wave_bytes = @intCast(needed);
    ab.scratch_waves = waves;
    exec.kprintf(sys, "%s: the compute engine's scratch: %u waves of %u bytes at 0x%lx\n", .{ owner, waves, ab.scratch_wave_bytes, ab.scratch.device });
    return .{ .scratch = keptScratch(ab) };
}

/// The queue's own scratch, as a dispatch is told of it: none where it
/// has none yet.
fn keptScratch(ab: *AMDGPUBase) _compute.Scratch {
    if (ab.scratch.bytes == 0) return .{};
    return _compute.Scratch.of(ab.scratch.device, ab.scratch_waves, ab.scratch_wave_bytes, ab.shader_engines);
}

/// The scratch made for one job, as a dispatch is told of it.
fn onceScratch(ab: *AMDGPUBase) _compute.Scratch {
    return _compute.Scratch.of(ab.scratch_once.device, ab.scratch_once_waves, ab.scratch_once_wave_bytes, ab.shader_engines);
}

/// Waits, under the queue's lock, a second at most until the engine has
/// done job `job` - none where it is 0 - which `what` waits for; false,
/// said in the system's log, where it has not.
fn waitFor(ab: *AMDGPUBase, job: u32, what: [*:0]const u8) bool {
    const sys = ab.sys_base;
    const until = sys.UptimeUs() + _compute.room_most_us;
    while (job != 0 and !_compute.passed(_compute.done(ab), job)) {
        if (sys.UptimeUs() > until) {
            exec.kprintf(sys, "%s: the compute engine has not done job %u, which %s waits for\n", .{ amdgpu.AMDGPUNAME, job, what });
            return false;
        }
        _compute.pause(ab, 100);
    }
    return true;
}
