// SPDX-License-Identifier: MPL-2.0
//! GetGPUConnector: one of the display's connectors, as the device's
//! video BIOS lists it.

const sdk = @import("sdk");
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;

/// One of the display's connectors.
///
/// SYNOPSIS:
/// ```zig
/// fn GetGPUConnector(ab: *AMDGPUBase, index: u32, connector: *GPUConnector) bool
/// ```
///
/// SINCE: 1.5. LVO -44.
///
/// INPUTS:
/// - `index` - which connector, from 0.
/// - `connector` - filled in.
///
/// RESULT:
/// True with `connector` filled in: its kind (GPUCONNECTOR_HDMI,
/// GPUCONNECTOR_DISPLAYPORT, ...) and its number among those of its kind,
/// the PHY that drives it, the I2C line of its monitor's DDC and the pin
/// of its hot-plug line, and its and its encoder's object ids. False for
/// an `index` past the last connector, or where the device's video BIOS
/// lists none, with `connector` left alone.
///
/// BEHAVIOR:
/// The list was read once, as the resource started, from the display
/// object table of the device's video BIOS image (GetGPUBios): a path per
/// connector the board wires, in the order the table gives them, those
/// without an encoder left out. A table of a version the resource does
/// not read lists nothing. At most GPUCONNECTORS_MAX are kept.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: it may be called from one.
/// - Locks: none.
/// - Process: any.
///
/// OWNERSHIP:
/// `connector` is the caller's.
///
/// NOTES:
/// A PHY, a DDC line or a hot-plug pin the table names none of is
/// GPULINE_NONE. The lines are numbered as the BIOS numbers them: the
/// DDC line as the BIOS's I2C id, the hot-plug pin as its GPIO pin id.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetGPUBios`
///
/// EXAMPLES:
/// ```zig
/// var connector: amdgpu.GPUConnector = .{};
/// var index: u32 = 0;
/// while (ab.GetGPUConnector(index, &connector)) : (index += 1) {
///     if (connector.kind == amdgpu.GPUCONNECTOR_HDMI) ... // its PHY drives an HDMI socket
/// }
/// ```
pub fn GetGPUConnector(ab: *AMDGPUBase, index: u32, connector: *amdgpu.GPUConnector) bool {
    if (ab.device == null or index >= ab.connector_count) return false;
    connector.* = ab.connectors[index];
    return true;
}
