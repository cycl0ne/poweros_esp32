// SPDX-License-Identifier: MPL-2.0
//! GetGPUBios: the device's video BIOS image, as the machine's firmware
//! kept it.

const sdk = @import("sdk");
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;

/// The device's video BIOS image.
///
/// SYNOPSIS:
/// ```zig
/// fn GetGPUBios(ab: *AMDGPUBase, bios: *GPUBios) bool
/// ```
///
/// SINCE: 1.5. LVO -40.
///
/// INPUTS:
/// - `bios` - filled in.
///
/// RESULT:
/// True with `bios` naming the image - where it is and how many bytes it
/// is. False where there is no device, or the firmware kept no image that
/// is the device's, with `bios` left alone.
///
/// BEHAVIOR:
/// The image was found once, as the resource started: in the table of
/// images the machine's firmware keeps (VFCT), which the kernel names as
/// a board part. It is the one whose PCI vendor and device ids, slot and
/// function are the device's, and whose first bytes are a PCI ROM
/// image's marks with the ATOM tables' header inside: the tables a
/// driver reads - the display's connectors and how each is wired, the
/// clocks - and the command tables the device's controllers run.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: it may be called from one.
/// - Locks: none.
/// - Process: any.
///
/// OWNERSHIP:
/// The image is the firmware's, in memory the kernel keeps for as long as
/// the machine runs: read it, never write it. A controller that wants it
/// in memory of its own is given a copy.
///
/// NOTES:
/// The ATOM tables' header is at the 16-bit offset the image holds at
/// 0x48; the tables are found through the offsets that header lists.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetGPUInfo`, `GetGPUConnector`
///
/// EXAMPLES:
/// ```zig
/// var bios: amdgpu.GPUBios = .{};
/// if (!ab.GetGPUBios(&bios)) return; // no image: no tables to read
/// const image = bios.image.?[0..bios.bytes];
/// ```
pub fn GetGPUBios(ab: *AMDGPUBase, bios: *amdgpu.GPUBios) bool {
    if (ab.device == null or ab.bios.image == null) return false;
    bios.* = ab.bios;
    return true;
}
