// SPDX-License-Identifier: MIT
//! GetPhysicalDeviceFeatures: what a physical device does.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const PhysicalDevice = @import("_instance.zig").PhysicalDevice;

/// What a physical device does, so that a program may ask before it is
/// refused.
///
/// SYNOPSIS:
/// ```zig
/// fn GetPhysicalDeviceFeatures(base: *FacetBase, physical: *facet.PhysicalDevice, features: *facet.PhysicalDeviceFeatures) void
/// ```
///
/// SINCE: 1.24. LVO -432.
///
/// INPUTS:
/// - `physical` - a physical device EnumeratePhysicalDevices listed.
/// - `features` - where they are written.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Every field is what the device's driver said of it as the instance was
/// made, and holds while the instance lasts. A `false` is what a create call
/// would answer `error_feature_not_present` to, so a program may choose
/// another way instead of failing; a `true` is a promise for this device, not
/// for the next one listed.
///
/// Five of the fields differ between the devices of one machine, and are the
/// reason to look. `own_fragment_functions`, `sampling_format` and
/// `depth_prepass` are the cores' and not the V3D's. `compute_on_device` and
/// `tessellation_on_device` are the cores' too, and for the plain reason that
/// the cores are that device: both kinds of work run on them whichever device
/// made the pipeline, so on the V3D they are false while the work still
/// happens. The limits say the rest of
/// what parts differ: a CM5's V3D takes one sampled image a stage where the
/// cores take sixteen (`GetPhysicalDeviceProperties`).
///
/// What the library has no call for at all - samplers, events, query pools, a
/// pipeline cache, sparse memory - has no field here. That a call is missing
/// is in the jump table, not in a feature.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `features` is the caller's.
///
/// NOTES:
/// The devices are listed with the cores first, so a program that wants the
/// GPU looks for one whose features suit it rather than taking the first.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `EnumeratePhysicalDevices`, `GetPhysicalDeviceProperties`, `CreateGraphicsPipelines`
///
/// EXAMPLES:
/// ```zig
/// var features: facet.PhysicalDeviceFeatures = undefined;
/// fb.GetPhysicalDeviceFeatures(physical, &features);
/// if (!features.own_fragment_functions) {
///     // This device runs only the fixed forms: shader.fixedFragment.
/// }
/// ```
pub fn GetPhysicalDeviceFeatures(base: *FacetBase, physical: *facet.PhysicalDevice, features: *facet.PhysicalDeviceFeatures) void {
    _ = base;
    features.* = _objects.of(PhysicalDevice, physical).features;
}
