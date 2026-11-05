// SPDX-License-Identifier: MIT
//! CreateSampler: how a texture bound beside it is sampled.

const sdk = @import("sdk");
const facet = sdk.facet;
const texture = facet.texture;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Device = @import("../device/_device.zig").Device;
const _sampler = @import("_sampler.zig");
const Sampler = _sampler.Sampler;
const max_sampler_anisotropy = @import("../instance/_instance.zig").max_sampler_anisotropy;

/// A sampler: the filter, the levels, the edges and the comparison a
/// texture bound beside it is sampled with.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateSampler(base: *FacetBase, device: *facet.Device, info: *const facet.SamplerCreateInfo, sampler: *?*facet.Sampler) facet.Result
/// ```
///
/// SINCE: 1.28. LVO -448.
///
/// INPUTS:
/// - `device` - the device.
/// - `info` - the filters, the mipmap mode, the three address modes, the
///   bias and clamp on the level, the anisotropy, the comparison and the
///   border colour.
/// - `sampler` - where the sampler is written; null when it fails.
///
/// RESULT:
/// `success`; `error_feature_not_present` for an address mode that is
/// none of Vulkan's five, for a filter, mipmap mode, compare operation or
/// border colour that is not one of Vulkan's, or for
/// `unnormalized_coordinates` on a device that reads none
/// (`PhysicalDeviceFeatures.unnormalized_coordinates`);
/// `error_initialization_failed` for `unnormalized_coordinates` asked for
/// beside something Vulkan does not allow with it;
/// `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// The sampler holds what it was given, in the terms the sampling is
/// written in (`texture.Sampler`): nothing is worked out again for each
/// sample.
///
/// `max_anisotropy` is held to `PhysicalDeviceLimits.max_sampler_anisotropy`
/// rather than refused above it, and is taken only where
/// `PhysicalDeviceFeatures.sampler_anisotropy` says so; without
/// `anisotropy_enable` it is 1, one sample. `max_lod` below `min_lod`
/// leaves the sample on `min_lod`. `compare_enable` makes every sample
/// through it a shadow sample: what is read is compared with the reference
/// the fragment function carries, and what comes out is how much of the
/// sample passed, not a colour.
///
/// `unnormalized_coordinates` places the sample in texels of the texture
/// rather than 0 to 1 across it, for a program that reads a texture as a
/// table of values (since 1.67). Vulkan asks five things of such a
/// sampler, and all five are held to here, an
/// `error_initialization_failed` for each:
/// - one filter for both: `mag_filter` and `min_filter` the same. Which of
///   the two a sample would take is worked out from how fast the
///   coordinates change, which says nothing in texels - so Vulkan has
///   them equal and the question does not arise.
/// - `mipmap_mode` `nearest`, and `min_lod` and `max_lod` both 0: the
///   first level and no other, the coordinates being that level's texels.
/// - no `anisotropy_enable`: one sample.
/// - no `compare_enable`: a colour and not a comparison.
/// - `address_mode_u` and `address_mode_v` either `clamp_to_edge` or
///   `clamp_to_border`. `address_mode_w` is taken as it is given: Vulkan
///   has no 3D texture read this way at all, and a 3D texture's `r` is
///   counted in slices here, which is the library's own answer.
///
/// All five of Vulkan's address modes are taken, `mirror_clamp_to_edge`
/// among them since 1.49: the texture turned round once below 0 and held
/// at its edge past the far side. The three border colours are Vulkan's
/// six: an int border and a float border are the same here, a texel being
/// read as 0 to 1 whatever its format, and Vulkan 1.0 has no border but
/// transparent black, opaque black and opaque white.
///
/// A sampler is made on either device, but is read by the sampling the
/// cores do: a pipeline whose fragment form samples through one
/// (`shader.FixedKind.texture_sampled`, `texture_shadow`, since 1.49
/// `texture_array_sampled`, `texture_cube_sampled` and `texture_3d_sampled`,
/// and since 1.53 `texture_cube_array_sampled`)
/// is refused on a device whose `PhysicalDeviceFeatures.samplers` is false.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The sampler is the caller's, until DestroySampler. It has to last as
/// long as the sets written with it are drawn with: a set holds the
/// address of what it keeps.
///
/// NOTES:
/// The sampler is read by every core that samples through it at once, and
/// written by nothing after it is made.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DestroySampler`, `UpdateDescriptorSets`, `CreateDescriptorSetLayout`
///
/// EXAMPLES:
/// ```zig
/// var sampler: ?*facet.Sampler = null;
/// _ = fb.CreateSampler(device, &.{
///     .mipmap_mode = .linear,
///     .address_mode_u = .clamp_to_edge,
///     .address_mode_v = .clamp_to_edge,
///     .max_lod = facet.texture.lod_unclamped,
///     .anisotropy_enable = true,
///     .max_anisotropy = 4,
/// }, &sampler);
///
/// // A table of values, read at the texel the coordinates name.
/// var table: ?*facet.Sampler = null;
/// _ = fb.CreateSampler(device, &.{
///     .mag_filter = .nearest,
///     .min_filter = .nearest,
///     .address_mode_u = .clamp_to_edge,
///     .address_mode_v = .clamp_to_edge,
///     .unnormalized_coordinates = true,
/// }, &table);
/// ```
pub fn CreateSampler(base: *FacetBase, device: *facet.Device, info: *const facet.SamplerCreateInfo, sampler: *?*facet.Sampler) facet.Result {
    sampler.* = null;
    const owner = _objects.of(Device, device);
    // In texels rather than 0 to 1, where the device samples that way:
    // what Vulkan asks of such a sampler is asked here too, since the
    // sampling holds it to the first level and to one sample and so
    // cannot answer for a sampler that says otherwise (since 1.67).
    if (info.unnormalized_coordinates) {
        if (!owner.physical.features.unnormalized_coordinates) return .error_feature_not_present;
        if (info.mag_filter != info.min_filter) return .error_initialization_failed;
        if (info.mipmap_mode != .nearest) return .error_initialization_failed;
        if (info.min_lod != 0 or info.max_lod != 0) return .error_initialization_failed;
        if (info.anisotropy_enable or info.compare_enable) return .error_initialization_failed;
        for ([2]facet.SamplerAddressMode{ info.address_mode_u, info.address_mode_v }) |mode| {
            if (mode != .clamp_to_edge and mode != .clamp_to_border) return .error_initialization_failed;
        }
    }
    const mag = _sampler.filterOf(info.mag_filter) orelse return .error_feature_not_present;
    const min = _sampler.filterOf(info.min_filter) orelse return .error_feature_not_present;
    const mipmap: texture.Mipmap = switch (info.mipmap_mode) {
        .nearest => .nearest,
        .linear => .linear,
        else => return .error_feature_not_present,
    };
    var wrap: [3]texture.Wrap = undefined;
    for (&wrap, [3]facet.SamplerAddressMode{ info.address_mode_u, info.address_mode_v, info.address_mode_w }) |*into, mode| {
        into.* = _sampler.wrapOf(mode) orelse return .error_feature_not_present;
    }
    const border = _sampler.borderOf(info.border_color) orelse return .error_feature_not_present;
    const compare: texture.Compare = if (!info.compare_enable) .none else _sampler.compareOf(info.compare_op) orelse return .error_feature_not_present;
    const made = _objects.create(base.sys_base, Sampler) orelse return .error_out_of_host_memory;
    made.* = .{
        .device = owner,
        .kept = .{
            .mag_filter = mag,
            .min_filter = min,
            .mipmap = mipmap,
            .wrap = wrap,
            .border = border,
            .lod_bias = info.mip_lod_bias,
            .min_lod = info.min_lod,
            .max_lod = info.max_lod,
            .anisotropy = if (info.anisotropy_enable) anisotropyOf(info.max_anisotropy) else 1,
            .compare = compare,
            .unnormalized = info.unnormalized_coordinates,
        },
    };
    sampler.* = _objects.handle(facet.Sampler, made);
    return .success;
}

/// The samples along the longer axis a sampler takes: what it asked for,
/// held between one and the limit. A NaN takes one.
fn anisotropyOf(asked: f32) f32 {
    if (!(asked > 1)) return 1;
    return @min(asked, @as(f32, max_sampler_anisotropy));
}
