// SPDX-License-Identifier: MPL-2.0
//! SendGPUDMA: a job of the DMA engine's packets put on its queue, with
//! the fence and the trap that end it, and the engine told.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;
const _dma = @import("_dma.zig");

/// A job of the DMA engine's packets put on its queue: copied into the
/// ring with a fence and a trap after them, and the engine told.
///
/// SYNOPSIS:
/// ```zig
/// fn SendGPUDMA(ab: *AMDGPUBase, packets: [*]const u32, words: u32) u32
/// ```
///
/// SINCE: 1.10. LVO -56.
///
/// INPUTS:
/// - `packets` - the engine's packets (GPUDMA_OP_*), one after another.
/// - `words` - how many words they are; 0 makes a job of nothing, whose
///   end says every job before it is done.
///
/// RESULT:
/// The job's number, which WaitGPUDMA waits for: never 0, one more than
/// the last job's, past 0 to 1. 0 where the queue does not run
/// (StartGPUDMA), where the job with its fence and trap would take the
/// whole ring (some 16 thousand words), or where the engine has not
/// read enough of the ring to make room for it within a second.
///
/// BEHAVIOR:
/// Under the queue's lock the job waits for room in the ring - the engine
/// reads it as it goes, and says how far after every few packets - then
/// its words are copied into the ring, followed by a fence that writes
/// its number into the queue's page once the engine has done its
/// packets, a trap that raises the engine's interrupt, and NOPs to the
/// next 16 words. The engine is told through its write pointer, after a
/// fence for the ring's words: it starts on the job at once where it is
/// idle, else after the jobs before it. The packets are not looked at:
/// what they name is the caller's to have right.
///
/// CONTEXT:
/// - Waits: only for room in the ring, a second at most.
/// - Interrupts: no.
/// - Locks: takes the queue's lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The packets are copied: they are the caller's again on return. The
/// memory they name must stay where it is until the job is done.
///
/// NOTES:
/// Addresses in the packets are the device's: a piece of its own memory
/// by its `device` address (AllocGPUMemory). What the engine writes is
/// in the memory once the job is done: its writes go past the graphics
/// block's caches.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartGPUDMA`, `WaitGPUDMA`, `GetGPUDMAState`
///
/// EXAMPLES:
/// ```zig
/// // 4 KiB of the device's memory set to a constant.
/// const fill = [_]u32{
///     amdgpu.GPUDMA_OP_CONST_FILL | amdgpu.GPUDMA_FILL_WORDS,
///     @truncate(piece.device), @truncate(piece.device >> 32),
///     0x1234_5678, 4096 - 1,
/// };
/// const job = ab.SendGPUDMA(&fill, fill.len);
/// if (job == 0 or !ab.WaitGPUDMA(job, 1000)) return error.NoDma;
/// ```
pub fn SendGPUDMA(ab: *AMDGPUBase, packets: [*]const u32, words: u32) u32 {
    if (ab.device == null or !ab.dma_running) return 0;
    const sys = ab.sys_base;
    const bytes = @as(u64, _dma.jobWords(words)) * 4;
    if (bytes >= _dma.ring_bytes) return 0;
    sys.ObtainSemaphore(&ab.dma_lock);
    defer sys.ReleaseSemaphore(&ab.dma_lock);
    const until = sys.UptimeUs() + _dma.room_most_us;
    while (_dma.pending(ab.dma_written, _dma.readBack(ab)) + bytes >= _dma.ring_bytes) {
        if (sys.UptimeUs() > until) {
            exec.kprintf(sys, "%s: the DMA engine makes no room in its ring: read %lx of %lx written\n", .{
                amdgpu.AMDGPUNAME, _dma.readBack(ab), ab.dma_written,
            });
            return 0;
        }
        pause(ab, 100);
    }
    var number = ab.dma_sent +% 1;
    if (number == 0) number = 1;
    _dma.putJob(ab, packets[0..words], number);
    _dma.tell(ab);
    ab.dma_sent = number;
    return number;
}

/// A wait of so many microseconds, at the least.
fn pause(ab: *AMDGPUBase, us: u32) void {
    var never: exec.Waitable = .{};
    const list = [_]*exec.Waitable{&never};
    _ = ab.sys_base.WaitForAny(&list, 1, us);
}
