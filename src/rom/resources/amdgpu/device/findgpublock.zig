// SPDX-License-Identifier: MPL-2.0
//! FindGPUBlock: one of the device's blocks, out of its table.

const sdk = @import("sdk");
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;
const _table = @import("../table/_table.zig");

/// One of the device's blocks: its version and where its registers are.
///
/// SYNOPSIS:
/// ```zig
/// fn FindGPUBlock(ab: *AMDGPUBase, id: u32, instance: u32, block: *GPUBlock) bool
/// ```
///
/// SINCE: 1.0. LVO -8.
///
/// INPUTS:
/// - `id` - the kind of block, a GPUBLOCK_* or any other number the
///   device's table gives a kind.
/// - `instance` - which of them, from 0.
/// - `block` - filled in.
///
/// RESULT:
/// True with `block` filled in: its kind and instance, its version, and
/// `count` addresses its registers are counted from, in 32-bit words into
/// the register window. False where the device has no such block, or
/// there is no device; `block` is then left alone.
///
/// BEHAVIOR:
/// The answer is read out of the table of blocks the device's firmware
/// left, which the resource kept as it started; the table is not changed
/// by anything that runs, so the answer is the same each time. A block
/// with more addresses than GPUBLOCK_ADDRESSES is answered with its first
/// ones.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: it may be called from one.
/// - Locks: none.
/// - Process: any.
///
/// OWNERSHIP:
/// `block` is the caller's.
///
/// NOTES:
/// Which of a block's addresses a register is counted from is the
/// block's own fact: its registers come in segments, each from its own
/// address. A driver checks the version it is answered with against the
/// versions it knows, and leaves a block of another version alone.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetGPUInfo`
///
/// EXAMPLES:
/// ```zig
/// var block: amdgpu.GPUBlock = .{};
/// if (!ab.FindGPUBlock(amdgpu.GPUBLOCK_VIDEO, 0, &block)) return;
/// const status = info.registers + (block.addresses[1] + 0x143) * 4;
/// ```
pub fn FindGPUBlock(ab: *AMDGPUBase, id: u32, instance: u32, block: *amdgpu.GPUBlock) bool {
    if (ab.table == 0) return false;
    return _table.block(ab.table, id, instance, block);
}
