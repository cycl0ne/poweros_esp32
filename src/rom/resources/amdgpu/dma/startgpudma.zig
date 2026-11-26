// SPDX-License-Identifier: MPL-2.0
//! StartGPUDMA: the graphics block's DMA engine started with one queue of
//! jobs - its ring made and set as the vendor's driver sets its own
//! kernel queue on this engine (sdma_v6_0_start), tried with one write,
//! and the engine's trap at the end of each job handed to the queue.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;
const _dma = @import("_dma.zig");
const _graphics = @import("../graphics/_graphics.zig");

/// The graphics block's DMA engine started with one queue of jobs:
/// the engine let run, its ring made and set, tried with one write, and
/// its interrupt at the end of each job taken.
///
/// SYNOPSIS:
/// ```zig
/// fn StartGPUDMA(ab: *AMDGPUBase) bool
/// ```
///
/// SINCE: 1.10. LVO -52.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// True once the queue runs and has done the write it was tried with, and
/// at once where an earlier call started it. False where StartGPUGraphics
/// has not started the block, the power manager does not keep it
/// powered, the device's memory has no room for the ring, the engine
/// does not do the write within 100 ms, or its interrupt cannot be had;
/// after the write fails or the interrupt cannot be had, every later call
/// answers false at once. On a machine without the device, false.
///
/// BEHAVIOR:
/// The block is kept powered first (SetGPUPower with GPUPOWER_GRAPHICS),
/// as a block switched off drops every write; it stays so. Then, as the
/// vendor's driver starts its own queue on the engine: the engine let
/// run, its interrupt for a queue that has run empty switched on; the
/// ring's size and its privilege set, its pointers cleared, the page it
/// writes how far it has read into named, as is the copy of the write
/// pointer its firmware looks at, the ring's address set, its doorbell
/// off, its watchdog at 100 ms, its translation's answers and its cache
/// policies set - reads not kept in the L2, writes past it - the engine
/// let run again and the ring and its indirect packets switched on. The
/// ring is tried with one packet that writes a word into the page, which
/// the CPU then reads. Last the engine's trap is handed to the queue's
/// server (AddGPUIntServer) and switched on, so that each job's end
/// wakes whoever waits for it.
///
/// CONTEXT:
/// - Waits: yes, for the power manager, a millisecond or so, and for the
///   write, at most 100 ms.
/// - Interrupts: no.
/// - Locks: takes the queue's lock, and the mailbox's, the memory's and
///   the interrupts' locks inside it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The ring, 64 KiB, and its page, 4 KiB, are taken from the device's
/// memory and kept for as long as the system runs.
///
/// NOTES:
/// The queue runs in the graphics hub's first context, so its packets
/// name memory by its address to the device: the device's own memory
/// through the hub's aperture, the machine's once it is mapped into the
/// hub's page table.
///
/// BUGS:
/// The block is kept powered for as long as the queue runs, rather than
/// allowed to switch off between jobs.
///
/// SEE ALSO:
/// `StartGPUGraphics`, `SendGPUDMA`, `WaitGPUDMA`, `GetGPUDMAState`
///
/// EXAMPLES:
/// ```zig
/// if (!ab.StartGPUGraphics(&files)) return error.NoGraphics;
/// if (!ab.StartGPUDMA()) return error.NoDma;
/// ```
pub fn StartGPUDMA(ab: *AMDGPUBase) bool {
    if (ab.device == null) return false;
    const sys = ab.sys_base;
    const owner = amdgpu.AMDGPUNAME;
    const gpu: *sdk.interface.amdgpu.AMDGPUBase = @ptrCast(&ab.lib);
    sys.ObtainSemaphore(&ab.dma_lock);
    defer sys.ReleaseSemaphore(&ab.dma_lock);
    if (ab.dma_running) return true;
    if (ab.dma_failed or !ab.graphics_started) return false;
    if (!gpu.SetGPUPower(amdgpu.GPUPOWER_GRAPHICS, 0, true)) {
        exec.kprintf(sys, "%s: the power manager does not keep the graphics block powered for its DMA engine\n", .{owner});
        return false;
    }
    var ring: amdgpu.GPUMemory = .{};
    if (!gpu.AllocGPUMemory(_dma.ring_bytes + _dma.page_bytes, _dma.page_bytes, &ring)) {
        exec.kprintf(sys, "%s: no room in the device's memory for the DMA engine's ring\n", .{owner});
        return false;
    }
    ab.dma_ring = ring;
    var offset: u32 = 0;
    while (offset < _dma.ring_bytes + _dma.page_bytes) : (offset += 4) _dma.word(ab, offset).* = 0;
    _dma.word(ab, _dma.test_at).* = 0xCAFE_DEAD;
    ab.dma_written = 0;
    ab.dma_sent = 0;
    _dma.fence();

    const at = _graphics.at;
    // The engine let run, its context-empty interrupt on (sdma_v6_0_enable,
    // ctxempty_int_enable).
    at(ab, _dma.F32_CNTL).* &= ~_dma.HALT;
    at(ab, _dma.CNTL).* |= _dma.CTXEMPTY_INT_ENABLE;

    // The ring (gfx_resume_instance).
    at(ab, _dma.SEM_WAIT_FAIL_TIMER_CNTL).* = 0;
    var control = at(ab, _dma.RB_CNTL).*;
    control = control & ~_dma.RB_SIZE_MASK | _dma.ring_size_code << _dma.RB_SIZE_SHIFT | _dma.RB_PRIV;
    at(ab, _dma.RB_CNTL).* = control;
    at(ab, _dma.RB_RPTR).* = 0;
    at(ab, _dma.RB_RPTR_HI).* = 0;
    at(ab, _dma.RB_WPTR).* = 0;
    at(ab, _dma.RB_WPTR_HI).* = 0;
    const write_copy = ring.device + _dma.write_copy_at;
    at(ab, _dma.RB_WPTR_POLL_ADDR_LO).* = @truncate(write_copy);
    at(ab, _dma.RB_WPTR_POLL_ADDR_HI).* = @truncate(write_copy >> 32);
    const read_back = ring.device + _dma.read_back_at;
    at(ab, _dma.RB_RPTR_ADDR_HI).* = @truncate(read_back >> 32);
    at(ab, _dma.RB_RPTR_ADDR_LO).* = @as(u32, @truncate(read_back)) & 0xffff_fffc;
    control = (control | _dma.RPTR_WRITEBACK_ENABLE | _dma.F32_WPTR_POLL_ENABLE) & ~_dma.WPTR_POLL_ENABLE;
    at(ab, _dma.RB_BASE).* = @truncate(ring.device >> 8);
    at(ab, _dma.RB_BASE_HI).* = @truncate(ring.device >> 40);
    at(ab, _dma.MINOR_PTR_UPDATE).* = 1;
    at(ab, _dma.RB_WPTR).* = 0;
    at(ab, _dma.RB_WPTR_HI).* = 0;
    at(ab, _dma.DOORBELL).* &= ~_dma.DOORBELL_ENABLE;
    at(ab, _dma.DOORBELL_OFFSET).* = at(ab, _dma.DOORBELL_OFFSET).*;
    at(ab, _dma.MINOR_PTR_UPDATE).* = 0;
    at(ab, _dma.WATCHDOG_CNTL).* = at(ab, _dma.WATCHDOG_CNTL).* & ~_dma.QUEUE_HANG_COUNT_MASK | 1;
    at(ab, _dma.UTCL1_CNTL).* = at(ab, _dma.UTCL1_CNTL).* & ~(_dma.RESP_MODE_MASK | _dma.REDO_DELAY_MASK) |
        3 << _dma.RESP_MODE_SHIFT | 9;
    at(ab, _dma.UTCL1_PAGE).* = at(ab, _dma.UTCL1_PAGE).* & _dma.UTCL1_PAGE_KEEP | _dma.UTCL1_PAGE_POLICIES;
    at(ab, _dma.F32_CNTL).* &= ~(_dma.HALT | _dma.TH1_RESET);
    at(ab, _dma.RB_CNTL).* = control | _dma.RB_ENABLE;
    at(ab, _dma.IB_CNTL).* |= _dma.IB_ENABLE;

    // Tried with one write into the page (sdma_v6_0_ring_test_ring).
    const test_device = ring.device + _dma.test_at;
    _dma.putPadded(ab, &.{ _dma.OP_WRITE, @truncate(test_device), @truncate(test_device >> 32), 0, 0xDEAD_BEEF });
    _dma.tell(ab);
    const until = sys.UptimeUs() + _dma.test_most_us;
    while (_dma.word(ab, _dma.test_at).* != 0xDEAD_BEEF) {
        if (sys.UptimeUs() > until) {
            exec.kprintf(sys, "%s: the DMA engine does not write: status %x, read pointer %x, written back %lx\n", .{
                owner, at(ab, _dma.STATUS_REG).*, at(ab, _dma.RB_RPTR).*, _dma.readBack(ab),
            });
            stop(ab);
            return false;
        }
    }

    // Its trap at each job's end, to the queue's server.
    ab.dma_trap = .{};
    ab.dma_traps = 0;
    ab.dma_trap_int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = owner },
        .data = ab,
        .code = &_dma.trapServer,
    };
    if (!gpu.AddGPUIntServer(_dma.INTERRUPT_CLIENT, _dma.TRAP_SOURCE, &ab.dma_trap_int)) {
        exec.kprintf(sys, "%s: the DMA engine's interrupt cannot be had\n", .{owner});
        stop(ab);
        return false;
    }
    at(ab, _dma.CNTL).* |= _dma.TRAP_ENABLE;
    ab.dma_running = true;
    exec.kprintf(sys, "%s: the DMA engine's queue runs: its ring at 0x%lx, %dK, written back at 0x%lx\n", .{
        owner, ring.device, _dma.ring_bytes / 1024, read_back,
    });
    return true;
}

/// The engine halted and its ring switched off, after it failed; the
/// queue is not tried again. Its piece is kept, as the engine may still
/// have been reading it.
fn stop(ab: *AMDGPUBase) void {
    _graphics.at(ab, _dma.RB_CNTL).* &= ~_dma.RB_ENABLE;
    _graphics.at(ab, _dma.F32_CNTL).* |= _dma.HALT;
    ab.dma_failed = true;
}
