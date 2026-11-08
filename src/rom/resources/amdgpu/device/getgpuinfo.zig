// SPDX-License-Identifier: MPL-2.0
//! GetGPUInfo: what the device is, and where the machine reaches it.

const sdk = @import("sdk");
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;

/// What the device is and where the machine reaches it.
///
/// SYNOPSIS:
/// ```zig
/// fn GetGPUInfo(ab: *AMDGPUBase, info: *GPUInfo) bool
/// ```
///
/// SINCE: 1.0. LVO -4.
///
/// INPUTS:
/// - `info` - filled in.
///
/// RESULT:
/// True with `info` filled in: the device's PCI vendor and device ids,
/// its register window and its memory window as the machine reaches them,
/// each with its length, and how much memory of its own it has. False on
/// a machine without the device, with `info` left alone.
///
/// BEHAVIOR:
/// The device was found, claimed and read once, as the resource started;
/// what is answered is what was read then. `memory_bytes` is the device's
/// own answer for its memory - the part of the machine's memory set aside
/// for it - of which the memory window shows the first `window_bytes`.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: it may be called from one.
/// - Locks: none.
/// - Process: any.
///
/// OWNERSHIP:
/// `info` is the caller's. The windows are the device's: a driver reads
/// and writes the registers of the block it drives, and only those.
///
/// NOTES:
/// A register's place is `registers + (block.addresses[n] + offset) * 4`,
/// with the block from FindGPUBlock.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindGPUBlock`
///
/// EXAMPLES:
/// ```zig
/// var info: amdgpu.GPUInfo = .{};
/// if (!ab.GetGPUInfo(&info)) return; // no such device here
/// ```
pub fn GetGPUInfo(ab: *AMDGPUBase, info: *amdgpu.GPUInfo) bool {
    if (ab.device == null) return false;
    info.* = ab.info;
    return true;
}
