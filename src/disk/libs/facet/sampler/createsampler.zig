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
/// `success`; `error_feature_not_present` for `unnormalized_coordinates`,
/// for `mirror_clamp_to_edge` or another address mode the library has not
/// got, or for a filter, mipmap mode, compare operation or border colour
/// that is not one of Vulkan's; `error_out_of_host_memory`.
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
/// A sampler is made on either device, but is read by the sampling the
/// cores do: a pipeline whose fragment form samples through one
/// (`shader.FixedKind.texture_sampled`, `texture_shadow`) is refused on a
/// device whose `PhysicalDeviceFeatures.samplers` is false.
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
/// ```
pub fn CreateSampler(base: *FacetBase, device: *facet.Device, info: *const facet.SamplerCreateInfo, sampler: *?*facet.Sampler) facet.Result {
    sampler.* = null;
    const owner = _objects.of(Device, device);
    if (info.unnormalized_coordinates) return .error_feature_not_present;
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
