// SPDX-License-Identifier: MPL-2.0
//! StartGPUCompute: the graphics block's compute engine started with one
//! queue of jobs - the doorbells opened, the scheduler's two pipes started
//! and their queues set as the vendor's driver sets them on this block
//! (gfx_v11_0_cp_resume, mes_v11_0_kiq_hw_init, mes_v11_0_hw_init), the
//! queue mapped by the scheduler, tried, and its end-of-pipe interrupt
//! handed to it.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;
const _compute = @import("_compute.zig");
const _graphics = @import("../graphics/_graphics.zig");

/// The graphics block's compute engine started with one queue of jobs,
/// mapped by the block's scheduler: its doorbells opened, the scheduler's
/// two pipes started and told the block's resources, the queue mapped and
/// tried, and its interrupt at the end of each job taken.
///
/// SYNOPSIS:
/// ```zig
/// fn StartGPUCompute(ab: *AMDGPUBase) bool
/// ```
///
/// SINCE: 1.12. LVO -76.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// True once the queue runs and has set a register it was tried with, and
/// at once where an earlier call started it. False where StartGPUGraphics
/// has not started the block, the device has no doorbell window, the
/// power manager does not keep the block powered, the device's memory has
/// no room for the queues, the scheduler's firmware is older than the
/// version that maps the system's own queues (0x47), or the scheduler,
/// its mapper or the queue does not answer in time; after any of these
/// but the first three every later call answers false at once. On a
/// machine without the device, false.
///
/// BEHAVIOR:
/// The block is kept powered first (SetGPUPower with GPUPOWER_GRAPHICS).
/// Then, as the vendor's driver does on this block: the bus block's
/// doorbell window opened, and the window the device's own engines ring
/// doorbells through set over it (soc21_enable_doorbell_aperture); memory
/// as the system context's shaders address it set (constants_init); the
/// doorbells each engine answers to set (cp_set_doorbell_range); the
/// compute engine's first micro engine let run, then the graphics
/// engine's two, and the command processor waited for to be idle, 100 ms
/// at most - as the vendor's driver does, it goes on where it is not.
/// The scheduler's two pipes are reset, each pointed at the first
/// instruction its file's header names, and let run (mes_v11_0_enable);
/// their firmware's versions are read; the second pipe, the mapper, is
/// told it maps queues (kiq_setting) and its own queue set through its
/// registers. Where the scheduler is 0x47 or later, its own queue is
/// mapped by the mapper (MAP_QUEUES) and the mapper's ring tried with a
/// register it sets; the scheduler is told the block's resources
/// (SET_HW_RESOURCES), from 0x52 on its second call of them too, and
/// asked its status. Last the queue: its description made, the mapper
/// told which queues are the system's (SET_RESOURCES) and tried again,
/// the queue mapped by the scheduler as one of the system's own
/// (ADD_QUEUE), tried with a register it sets, and its end-of-pipe
/// interrupt handed to the queue's server (AddGPUIntServer) and switched
/// on. Where any of it fails the scheduler's pipes are halted, and the
/// engines halted again.
///
/// CONTEXT:
/// - Waits: yes, for the power manager, a millisecond or so; for the
///   command processor and each ring's test, at most 100 ms; for each call
///   of the scheduler, at most 2.1 s - a few milliseconds in all where
///   all goes well.
/// - Interrupts: no.
/// - Locks: takes the queue's lock, and the mailbox's, the memory's and
///   the interrupts' locks inside it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The rings, their descriptions, the engines' buffers and the slots of
/// arguments, 136 KiB of the device's memory, are taken and kept for as
/// long as the system runs.
///
/// NOTES:
/// The queue runs in the graphics hub's first context, as the DMA
/// engine's does: its packets and its kernels name memory by its address
/// to the device - the device's own memory through the hub's aperture,
/// the machine's once it is mapped into the hub's page table
/// (MapGPUMemory). The golden values the vendor's driver writes into
/// nine of the block's registers at its start - its drawing pipeline's,
/// its texture caches' and its second-level cache's - are not written.
///
/// BUGS:
/// The block is kept powered for as long as the queue runs, rather than
/// allowed to switch off between jobs.
///
/// SEE ALSO:
/// `StartGPUGraphics`, `SendGPUCompute`, `SendGPUKernel`,
/// `WaitGPUCompute`, `GetGPUComputeState`
///
/// EXAMPLES:
/// ```zig
/// if (!ab.StartGPUGraphics(&files)) return error.NoGraphics;
/// if (!ab.StartGPUCompute()) return error.NoCompute;
/// ```
pub fn StartGPUCompute(ab: *AMDGPUBase) bool {
    if (ab.device == null) return false;
    const sys = ab.sys_base;
    const owner = amdgpu.AMDGPUNAME;
    const gpu: *sdk.interface.amdgpu.AMDGPUBase = @ptrCast(&ab.lib);
    sys.ObtainSemaphore(&ab.compute_lock);
    defer sys.ReleaseSemaphore(&ab.compute_lock);
    if (ab.compute_running) return true;
    if (ab.compute_failed or !ab.graphics_started) return false;
    if (ab.doorbells == 0) {
        exec.kprintf(sys, "%s: the device has no doorbell window for the compute engine's queues\n", .{owner});
        return false;
    }
    var bus: amdgpu.GPUBlock = .{};
    var hub: amdgpu.GPUBlock = .{};
    var interrupts: amdgpu.GPUBlock = .{};
    if (!gpu.FindGPUBlock(amdgpu.GPUBLOCK_BUS, 0, &bus) or bus.count <= _compute.bus_segment or
        !gpu.FindGPUBlock(amdgpu.GPUBLOCK_MEMORY_HUB, 0, &hub) or !gpu.FindGPUBlock(amdgpu.GPUBLOCK_INTERRUPTS, 0, &interrupts))
    {
        exec.kprintf(sys, "%s: the device names no bus block, memory hub or interrupt block for the compute engine's scheduler\n", .{owner});
        return false;
    }
    if (!gpu.SetGPUPower(amdgpu.GPUPOWER_GRAPHICS, 0, true)) {
        exec.kprintf(sys, "%s: the power manager does not keep the graphics block powered for its compute engine\n", .{owner});
        return false;
    }
    var piece: amdgpu.GPUMemory = .{};
    if (!gpu.AllocGPUMemory(_compute.piece_bytes, 4096, &piece)) {
        exec.kprintf(sys, "%s: no room in the device's memory for the compute engine's queues\n", .{owner});
        return false;
    }
    ab.compute = piece;
    var offset: u32 = 0;
    while (offset < _compute.piece_bytes) : (offset += 4) _compute.word(ab, offset).* = 0;
    _compute.fence();
    ab.scheduler_written = 0;
    ab.mapper_written = 0;
    ab.compute_written = 0;
    ab.scheduler_calls = 0;
    ab.compute_sent = 0;
    ab.compute_slot = 0;
    ab.compute_slot_jobs = @splat(0);

    const at = _graphics.at;
    // The doorbell window, and the device's own way into it
    // (nbio_v7_7_enable_doorbell_aperture, _selfring_aperture).
    _compute.busAt(ab, &bus, _compute.RCC_DOORBELL_APER_EN).* |= _compute.BIF_DOORBELL_APER_EN;
    _compute.busAt(ab, &bus, _compute.SELFRING_GPA_APER_BASE_LOW).* = @truncate(ab.doorbells);
    _compute.busAt(ab, &bus, _compute.SELFRING_GPA_APER_BASE_HIGH).* = @truncate(ab.doorbells >> 32);
    _compute.busAt(ab, &bus, _compute.SELFRING_GPA_APER_CNTL).* = _compute.SELFRING_APER_EN | _compute.SELFRING_APER_MODE;

    // Memory as the system context's shaders address it (constants_init).
    _compute.select(ab, _compute.no_queue, 0);
    at(ab, _compute.SH_MEM_CONFIG).* = _compute.SH_MEM_CONFIG_DEFAULT;

    // The doorbells each engine answers to (cp_set_doorbell_range).
    at(ab, _compute.CP_RB_DOORBELL_RANGE_LOWER).* = _compute.rb_doorbells_lower;
    at(ab, _compute.CP_RB_DOORBELL_RANGE_UPPER).* = _compute.rb_doorbells_upper;
    at(ab, _compute.CP_MEC_DOORBELL_RANGE_LOWER).* = _compute.mec_doorbells_lower;
    at(ab, _compute.CP_MEC_DOORBELL_RANGE_UPPER).* = _compute.mec_doorbells_upper;

    // The compute engine's first micro engine let run - the second is the
    // scheduler's to run - then the graphics engine's two
    // (cp_compute_enable, cp_gfx_enable).
    at(ab, _compute.CP_MEC_CNTL).* = at(ab, _compute.CP_MEC_CNTL).* & ~_compute.MEC_ME1_HALT;
    _compute.pause(ab, 50);
    at(ab, _compute.CP_ME_CNTL).* = at(ab, _compute.CP_ME_CNTL).* & ~(_compute.ME_HALT | _compute.PFP_HALT);
    const idle_until = sys.UptimeUs() + _compute.test_most_us;
    while (at(ab, _compute.CP_STAT).* != 0) {
        if (sys.UptimeUs() > idle_until) {
            exec.kprintf(sys, "%s: the command processor is not idle once its engines run: CP_STAT %x\n", .{ owner, at(ab, _compute.CP_STAT).* });
            break;
        }
    }

    // The scheduler's two pipes reset, pointed at their first instructions
    // and let run (mes_v11_0_enable).
    at(ab, _compute.CP_MES_CNTL).* = at(ab, _compute.CP_MES_CNTL).* | _compute.MES_PIPE0_RESET | _compute.MES_PIPE1_RESET;
    for ([_]_compute.Queue{ _compute.scheduler_queue, _compute.mapper_queue }, 0..) |queue, pipe| {
        _compute.select(ab, queue, 0);
        const start = ab.scheduler_start[pipe] >> 2;
        at(ab, _compute.CP_MES_PRGRM_CNTR_START).* = @truncate(start);
        at(ab, _compute.CP_MES_PRGRM_CNTR_START_HI).* = @truncate(start >> 32);
    }
    _compute.select(ab, _compute.no_queue, 0);
    at(ab, _compute.CP_MES_CNTL).* = _compute.MES_PIPE0_ACTIVE | _compute.MES_PIPE1_ACTIVE;
    _compute.pause(ab, 500);

    // Their firmware's versions (get_fw_version).
    _compute.select(ab, _compute.scheduler_queue, 0);
    ab.scheduler_version = at(ab, _compute.CP_MES_GP3_LO).*;
    _compute.select(ab, _compute.mapper_queue, 0);
    ab.mapper_version = at(ab, _compute.CP_MES_GP3_LO).*;
    _compute.select(ab, _compute.no_queue, 0);

    // The second pipe told it maps queues (kiq_setting), and its own queue
    // set through its registers (queue_init of the mapper's pipe).
    const mapper = _compute.mapper_queue;
    const schedulers = at(ab, _compute.RLC_CP_SCHEDULERS).* & 0xffff_ff00 | mapper.me << 5 | mapper.pipe << 3 | mapper.queue;
    at(ab, _compute.RLC_CP_SCHEDULERS).* = schedulers;
    at(ab, _compute.RLC_CP_SCHEDULERS).* = schedulers | 0x80;
    describe(ab, .scheduler, _compute.mapper_mqd_at, _compute.mapper_ring_at, _compute.mapper_ring_bytes, _compute.mapper_eop_at, _compute.mapper_read_at, _compute.mapper_write_at, _compute.mapper_doorbell);
    _compute.select(ab, mapper, 0);
    _compute.setQueue(ab, _compute.words(ab, _compute.mapper_mqd_at));
    _compute.select(ab, _compute.no_queue, 0);

    const version = ab.scheduler_version & _compute.scheduler_version_mask;
    if (version < _compute.scheduler_maps_from) {
        exec.kprintf(sys, "%s: the compute engine's scheduler, firmware %x, does not map the system's own queues: that takes %x or later\n", .{
            owner, version, _compute.scheduler_maps_from,
        });
        return stop(ab);
    }

    // The scheduler's own queue, mapped by the mapper (queue_init of the
    // scheduler's pipe, kiq_enable_queue).
    describe(ab, .scheduler, _compute.scheduler_mqd_at, _compute.scheduler_ring_at, _compute.scheduler_ring_bytes, _compute.scheduler_eop_at, _compute.scheduler_read_at, _compute.scheduler_write_at, _compute.scheduler_doorbell);
    _compute.put(ab, .mapper, &_compute.mapScheduler(piece.device + _compute.scheduler_mqd_at, piece.device + _compute.scheduler_write_at));
    if (!_compute.tryRing(ab, .mapper)) {
        exec.kprintf(sys, "%s: the compute engine's scheduler's mapper does not set a register: MES_INSTR_PNTR %x, CP_STAT %x\n", .{
            owner, at(ab, _compute.CP_MES_INSTR_PNTR).*, at(ab, _compute.CP_STAT).*,
        });
        return stop(ab);
    }

    // The block's resources (set_hw_resources, set_hw_resources_1), and the
    // scheduler's status asked (query_sched_status).
    var resources: _compute.Resources = .{
        .context = piece.device + _compute.scheduler_context_at,
        .query_fence = piece.device + _compute.scheduler_query_at,
        .graphics = undefined,
        .memory_hub = undefined,
        .interrupts = undefined,
    };
    for (0..5) |index| {
        resources.graphics[index] = ab.graphics.addresses[index];
        resources.memory_hub[index] = hub.addresses[index];
        resources.interrupts[index] = interrupts.addresses[index];
    }
    var frame = _compute.resourcesFrame(resources);
    if (!_compute.call(ab, &frame, _compute.resources_status_at)) return refused(ab, "the block's resources");
    if (version >= _compute.scheduler_resources_1_from) {
        frame = _compute.resources1Frame(piece.device + _compute.cleaner_at);
        if (!_compute.call(ab, &frame, _compute.resources_1_status_at)) return refused(ab, "the second call of the block's resources");
    }
    frame = _compute.queryFrame();
    if (!_compute.call(ab, &frame, _compute.query_status_at)) return refused(ab, "a question of its status");

    // The queue: its description, as the vendor's driver makes it with the
    // queue selected (kcq_init_queue); the mapper told which queues are
    // the system's and tried (kiq_set_resources); the queue mapped by the
    // scheduler (map_legacy_queue) and tried (ring_test_ring).
    _compute.select(ab, _compute.compute_queue, 0);
    describe(ab, .compute, _compute.compute_mqd_at, _compute.compute_ring_at, _compute.compute_ring_bytes, _compute.compute_eop_at, _compute.compute_read_at, _compute.compute_write_at, _compute.compute_doorbell);
    _compute.select(ab, _compute.no_queue, 0);
    _compute.put(ab, .mapper, &_compute.setResources(~@as(u64, 0)));
    if (!_compute.tryRing(ab, .mapper)) {
        exec.kprintf(sys, "%s: the compute engine's scheduler's mapper does not take the system's queues\n", .{owner});
        return stop(ab);
    }
    frame = _compute.mapFrame(_compute.compute_queue, _compute.compute_doorbell, piece.device + _compute.compute_mqd_at, piece.device + _compute.compute_write_at);
    if (!_compute.call(ab, &frame, _compute.add_queue_status_at)) return refused(ab, "the queue's map");
    if (!_compute.tryRing(ab, .compute)) {
        _compute.select(ab, _compute.compute_queue, 0);
        const active = at(ab, _compute.CP_HQD_ACTIVE).*;
        const queue_read = at(ab, _compute.CP_HQD_PQ_RPTR).*;
        const queue_written = at(ab, _compute.CP_HQD_PQ_WPTR_LO).*;
        _compute.select(ab, _compute.no_queue, 0);
        exec.kprintf(sys, "%s: the compute engine's queue does not set a register: active %x, read %x, written %x, CP_CPC_STATUS %x\n", .{
            owner, active, queue_read, queue_written, at(ab, _compute.CP_CPC_STATUS).*,
        });
        return stop(ab);
    }

    // Its end-of-pipe interrupt, to the queue's server.
    ab.compute_end = .{};
    ab.compute_ends = 0;
    ab.compute_end_int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = owner },
        .data = ab,
        .code = &_compute.endServer,
    };
    if (!gpu.AddGPUIntServer(_compute.INTERRUPT_CLIENT, _compute.END_SOURCE, &ab.compute_end_int)) {
        exec.kprintf(sys, "%s: the compute engine's interrupt cannot be had\n", .{owner});
        return stop(ab);
    }
    at(ab, _compute.CP_ME1_PIPE0_INT_CNTL).* = at(ab, _compute.CP_ME1_PIPE0_INT_CNTL).* | _compute.TIME_STAMP_INT_ENABLE | _compute.GENERIC0_INT_ENABLE;
    ab.compute_running = true;
    exec.kprintf(sys, "%s: the compute engine's queue runs: its scheduler's firmware %x, its mapper's %x; its ring at 0x%lx, %dK\n", .{
        owner, ab.scheduler_version, ab.mapper_version, piece.device + _compute.compute_ring_at, _compute.compute_ring_bytes / 1024,
    });
    return true;
}

/// The description of the queue whose places in the piece these are
/// written, and sent on to the memory.
fn describe(ab: *AMDGPUBase, kind: @FieldType(_compute.Description, "kind"), mqd_at: u32, ring_at: u32, ring_bytes: u32, eop_at: u32, read_at: u32, write_at: u32, doorbell: u32) void {
    const device = ab.compute.device;
    _compute.describe(_compute.words(ab, mqd_at), .{
        .kind = kind,
        .mqd = device + mqd_at,
        .ring = device + ring_at,
        .ring_bytes = ring_bytes,
        .eop = device + eop_at,
        .read_back = device + read_at,
        .write_copy = device + write_at,
        .doorbell = doorbell,
    });
    _compute.fence();
}

/// A call of the scheduler not answered: said so, and the start stopped.
fn refused(ab: *AMDGPUBase, what: [*:0]const u8) bool {
    const at = _graphics.at;
    exec.kprintf(ab.sys_base, "%s: the compute engine's scheduler does not answer %s: its fence %x of call %d, MES_INSTR_PNTR %x\n", .{
        amdgpu.AMDGPUNAME, what, _compute.word(ab, _compute.scheduler_fence_at).*, ab.scheduler_calls, at(ab, _compute.CP_MES_INSTR_PNTR).*,
    });
    return stop(ab);
}

/// The scheduler's pipes halted as the vendor's driver halts them
/// (mes_v11_0_enable), and the engines halted again, after the start
/// failed; it is not tried again. The piece is kept, as the engines may
/// still have been reading it. False, for the caller to answer.
fn stop(ab: *AMDGPUBase) bool {
    const at = _graphics.at;
    at(ab, _compute.CP_MES_CNTL).* = at(ab, _compute.CP_MES_CNTL).* & ~(_compute.MES_PIPE0_ACTIVE | _compute.MES_PIPE1_ACTIVE) |
        _compute.MES_INVALIDATE_ICACHE | _compute.MES_PIPE0_RESET | _compute.MES_PIPE1_RESET | _compute.MES_HALT;
    at(ab, _compute.CP_ME_CNTL).* = at(ab, _compute.CP_ME_CNTL).* | _compute.ME_HALT | _compute.PFP_HALT;
    at(ab, _compute.CP_MEC_CNTL).* = at(ab, _compute.CP_MEC_CNTL).* | _compute.MEC_ME1_HALT | _compute.MEC_ME2_HALT;
    ab.compute_failed = true;
    return false;
}
