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
///   threads each group has, and its arguments (GPUDispatch).
///
/// RESULT:
/// The job's number, which WaitGPUCompute waits for; 0 where the queue
/// does not run (StartGPUCompute), where the kernel takes anything a
/// dispatch does not hand it - values in its registers other than the
/// address of its arguments, a stack that grows as it runs, a trap
/// handler - or more private memory than a wave's scratch holds, more
/// than 64 KiB of group memory or 256 bytes of arguments, where a
/// dimension of the dispatch is 0, a group has more than 1024 threads,
/// where the scratch its private memory needs cannot be made - the
/// graphics block's compute units not known, no room in the device's
/// memory, or the queue not idle within a second - or the jobs before it
/// leave no room in its ring within a second. Why a kernel is refused is
/// said in the system's log.
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
/// CONTEXT:
/// - Waits: for a slot and for room in the ring, a second at most each;
///   where the scratch is made again, for the queue to be idle, a second
///   at most.
/// - Interrupts: no.
/// - Locks: takes the queue's lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The arguments are copied: they are the caller's again on return. The
/// memory they name and the code object must stay until the job is done.
/// The scratch is the resource's, kept once made.
///
/// NOTES:
/// The kernel's addresses are the device's: its arguments name memory by
/// its `device` address (AllocGPUMemory, MapGPUMemory). A kernel that
/// reads more of its arguments than the dispatch hands it reads zeros
/// past them, up to 256 bytes. The scratch grows and is never made
/// smaller: a kernel with a large private array holds that much of the
/// device's memory from then on - on the NucBox, 32 waves for each of its
/// 12 compute units, 384 times a wave's bytes.
///
/// BUGS:
/// A kernel whose stack grows as it runs - recursion, a call it cannot
/// see the end of, an array of a size it works out - or that needs the
/// dispatch's own packet, its queue or a dispatch number in its
/// registers, or its arguments loaded into registers before it starts,
/// cannot be run. On a part whose table gives the graphics block's sizes
/// in a later form than the first four, a kernel with private memory is
/// refused.
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
    if (ab.device == null or !ab.compute_running) return 0;
    const sys = ab.sys_base;
    const owner = amdgpu.AMDGPUNAME;
    if (_compute.refusal(kernel, dispatch.groups, dispatch.threads, dispatch.argument_bytes)) |why| {
        exec.kprintf(sys, "%s: a kernel at 0x%lx is not run: %s\n", .{ owner, kernel.code, why });
        return 0;
    }
    const given: ?[*]const u8 = @ptrCast(dispatch.arguments);
    if (dispatch.argument_bytes != 0 and given == null) return 0;
    sys.ObtainSemaphore(&ab.compute_lock);
    defer sys.ReleaseSemaphore(&ab.compute_lock);

    const slot = ab.compute_slot;
    const last = ab.compute_slot_jobs[slot];
    const until = sys.UptimeUs() + _compute.room_most_us;
    while (last != 0 and !_compute.passed(_compute.done(ab), last)) {
        if (sys.UptimeUs() > until) {
            exec.kprintf(sys, "%s: the compute engine has not done job %u, whose arguments' slot a kernel waits for\n", .{ owner, last });
            return 0;
        }
        _compute.pause(ab, 100);
    }
    const scratch = scratchFor(ab, kernel) orelse return 0;
    const slot_at = _compute.slots_at + slot * _compute.slot_bytes;
    const into: [*]volatile u8 = @ptrCast(_compute.words(ab, slot_at));
    for (0.._compute.slot_bytes) |index| {
        into[index] = if (index < dispatch.argument_bytes) given.?[index] else 0;
    }

    var packets: [_compute.dispatch_words]u32 = undefined;
    _compute.dispatch(&packets, ab.graphics.addresses[0], kernel, dispatch.groups, dispatch.threads, ab.compute.device + slot_at, scratch);
    const job = _compute.send(ab, &packets);
    if (job == 0) return 0;
    ab.compute_slot_jobs[slot] = job;
    ab.compute_slot = (slot + 1) % amdgpu_base.compute_slots;
    return job;
}

/// The scratch a dispatch of `kernel` is told of, under the queue's lock:
/// the queue's own, made first where it holds less for a wave than the
/// kernel needs - once every job sent before it is done, as a piece in
/// use keeps its waves' size; null where it cannot be, which is said in
/// the system's log.
fn scratchFor(ab: *AMDGPUBase, kernel: *const amdgpu.GPUKernel) ?_compute.Scratch {
    const sys = ab.sys_base;
    const owner = amdgpu.AMDGPUNAME;
    const needed = _compute.waveBytes(kernel);
    if (needed > ab.scratch_wave_bytes) {
        if (ab.compute_units == 0) {
            exec.kprintf(sys, "%s: a kernel at 0x%lx is not run: the graphics block's compute units, which its scratch is made for, are not known\n", .{ owner, kernel.code });
            return null;
        }
        const waves = _compute.scratchWaves(ab.shader_engines, ab.compute_units);
        const bytes = needed * waves;
        if (bytes > std.math.maxInt(u32)) {
            exec.kprintf(sys, "%s: a kernel at 0x%lx is not run: its scratch would take %lu bytes\n", .{ owner, kernel.code, bytes });
            return null;
        }
        const until = sys.UptimeUs() + _compute.room_most_us;
        while (ab.compute_sent != 0 and !_compute.passed(_compute.done(ab), ab.compute_sent)) {
            if (sys.UptimeUs() > until) {
                exec.kprintf(sys, "%s: the compute engine has not done job %u, which a kernel's scratch waits for\n", .{ owner, ab.compute_sent });
                return null;
            }
            _compute.pause(ab, 100);
        }
        const gpu: *sdk.interface.amdgpu.AMDGPUBase = @ptrCast(&ab.lib);
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
    }
    if (ab.scratch.bytes == 0) return .{};
    return _compute.Scratch.of(ab.scratch.device, ab.scratch_waves, ab.scratch_wave_bytes, ab.shader_engines);
}
