// SPDX-License-Identifier: MPL-2.0
//! AllocGPUMemory: a piece of the device's own memory, for its blocks to
//! read and write.

const sdk = @import("sdk");
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;
const _arena = @import("_arena.zig");

/// A piece of the device's own memory, for its blocks to read and write.
///
/// SYNOPSIS:
/// ```zig
/// fn AllocGPUMemory(ab: *AMDGPUBase, bytes: u32, alignment: u32,
///     memory: *GPUMemory) bool
/// ```
///
/// SINCE: 1.1. LVO -16.
///
/// INPUTS:
/// - `bytes` - how many.
/// - `alignment` - a power of two the piece starts on a multiple of, in
///   the device's addresses and the CPU's alike; less than a page is a
///   page.
/// - `memory` - filled in.
///
/// RESULT:
/// True with `memory` holding the piece: `cpu`, where the CPU reaches it,
/// `device`, where the device's blocks do, and `bytes`. False where no
/// gap holds it, the resource holds as many pieces as it keeps, the
/// alignment is no power of two, `bytes` is 0, or the device's memory is
/// not placed where the resource knows to read it - and on a machine
/// without the device; `memory` is then left alone.
///
/// BEHAVIOR:
/// The piece is the first gap of the part of the device's memory the
/// resource hands out that holds it, in whole pages. That part leaves the
/// bottom and the top 64 MiB of the device's memory alone: the screen the
/// firmware lit is at the bottom, the firmware's own region at the top.
/// The piece is not cleared.
///
/// CONTEXT:
/// - Waits: for another task handing out or giving back.
/// - Interrupts: no.
/// - Locks: takes the resource's memory lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The piece is the caller's until it gives it to FreeGPUMemory; the
/// resource gives nothing back on a task's behalf.
///
/// NOTES:
/// The device does not look into the CPU's caches, and the CPU reaches
/// the pieces write-combining - uncached where the machine's map would
/// not mark them, which the resource says at start. A write is gathered
/// with the ones beside it and sent on by a fence (`mfence`), which a
/// driver puts before it tells a block to read; a read is uncached and
/// sees what a block wrote. Plain loads fetch a word at a time, so a
/// driver copies out once, by streaming loads (`movntdqa`), which fetch a
/// line, rather than reading in place.
///
/// BUGS:
/// The firmware's region at the top is sized in the video firmware's
/// tables, which are not read: 64 MiB is kept clear of it on trust.
///
/// SEE ALSO:
/// `FreeGPUMemory`, `SetGPUPower`
///
/// EXAMPLES:
/// ```zig
/// var ring: amdgpu.GPUMemory = .{};
/// if (!ab.AllocGPUMemory(4096, 4096, &ring)) return error.NoMemory;
/// defer ab.FreeGPUMemory(&ring);
/// ```
pub fn AllocGPUMemory(ab: *AMDGPUBase, bytes: u32, alignment: u32, memory: *amdgpu.GPUMemory) bool {
    if (ab.device == null or ab.memory_bytes == 0) return false;
    const sys = ab.sys_base;
    sys.ObtainSemaphore(&ab.arena_lock);
    defer sys.ReleaseSemaphore(&ab.arena_lock);
    const offset = _arena.place(&ab.arena, bytes, alignment) orelse return false;
    memory.* = .{
        .cpu = ab.memory_machine + offset,
        .device = ab.memory_device + offset,
        .bytes = bytes,
    };
    return true;
}
