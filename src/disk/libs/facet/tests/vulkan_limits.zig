// SPDX-License-Identifier: MIT
//! Vulkan 1.0's required value for every one of VkPhysicalDeviceLimits' 106
//! members, and the count of the ones this library does not meet.
//!
//! docs/facet-vulkan10.md item 16's reshape was done so that the shortfalls
//! would be *countable*, which is only true if something counts them. This
//! does, on every build, and the count is pinned: close one of items 17 to
//! 30 and this test fails until the number is lowered, which is the point.
//!
//! **Where the numbers come from.** Not from this tree, and not from
//! anyone's memory. The Vulkan specification's "Limit Requirements" section
//! carries two tables - "Required Limit Types" (the C type and the feature
//! each limit depends on) and "Required Limits" (Limit | Unsupported Limit |
//! Supported Limit | Limit Type) - and this is the Vulkan 1.0 column of
//! those, read from the Khronos registry's HTML and cross-checked against
//! docs.vulkan.org's rendering of the same two tables with no differences
//! over all 106. Values the spec marks as raised by a later version or by a
//! Roadmap profile are *not* here: this is 1.0's floor, which is what facet
//! answers for (`API_VERSION_1_0`).
//!
//! **A limit's requirement often depends on a feature**, and the dependency
//! runs the way that catches people out: the table's *Unsupported* value is
//! mandatory when the feature reads false. Say `sampler_anisotropy` is
//! false and `max_sampler_anisotropy` must read 1, not "may read anything".
//! So a row names the feature it hangs on and carries both values, and the
//! check reads the device's features to pick one.
//!
//! What this does not check is the *shape* - that is
//! `scripts/vulkan-struct-check.sh` against the registry header, and the
//! layout test in tests/facet.zig. Member names here are only strings.

const std = @import("std");
const sdk = @import("sdk");
const facet = sdk.facet;

/// How a required value is to be read.
pub const Kind = enum {
    /// The device must report at least this.
    at_least,
    /// At most this - the alignment and granularity limits, where a smaller
    /// number is the better one.
    at_most,
    /// Every element of an array at least its own value.
    each_at_least,
    /// A range that must reach outward at least this far: `[0]` no higher
    /// than the first value, `[1]` no lower than the second.
    pair_outward,
    /// A bitmask that must have at least these bits set. Vulkan's footnote:
    /// "For bitmasks a minimum limit is the least bits all implementations
    /// must set, but they may have additional bits set beyond this minimum."
    mask_includes,
    /// The spec asks for nothing: implementation-dependent, a duration, or
    /// a recommendation.
    none,
};

pub const Row = struct {
    /// The field of `facet.PhysicalDeviceLimits`.
    name: []const u8,
    /// Vulkan's own spelling, for the message when one falls short.
    vk: []const u8,
    kind: Kind,
    /// The required value, or values for an array or a range.
    want: []const f64 = &.{},
    /// What is required instead when `feature` reads false.
    without: ?[]const f64 = null,
    /// The field of `facet.PhysicalDeviceFeatures` this hangs on.
    feature: ?[]const u8 = null,
};

/// Vulkan 1.0's floor, member by member, in the header's order.
pub const required = [_]Row{
    .{ .name = "max_image_dimension_1d", .vk = "maxImageDimension1D", .kind = .at_least, .want = &.{4096} },
    .{ .name = "max_image_dimension_2d", .vk = "maxImageDimension2D", .kind = .at_least, .want = &.{4096} },
    .{ .name = "max_image_dimension_3d", .vk = "maxImageDimension3D", .kind = .at_least, .want = &.{256} },
    .{ .name = "max_image_dimension_cube", .vk = "maxImageDimensionCube", .kind = .at_least, .want = &.{4096} },
    .{ .name = "max_image_array_layers", .vk = "maxImageArrayLayers", .kind = .at_least, .want = &.{256} },
    .{ .name = "max_texel_buffer_elements", .vk = "maxTexelBufferElements", .kind = .at_least, .want = &.{65536} },
    .{ .name = "max_uniform_buffer_range", .vk = "maxUniformBufferRange", .kind = .at_least, .want = &.{16384} },
    .{ .name = "max_storage_buffer_range", .vk = "maxStorageBufferRange", .kind = .at_least, .want = &.{134217728} },
    .{ .name = "max_push_constants_size", .vk = "maxPushConstantsSize", .kind = .at_least, .want = &.{128} },
    .{ .name = "max_memory_allocation_count", .vk = "maxMemoryAllocationCount", .kind = .at_least, .want = &.{4096} },
    .{ .name = "max_sampler_allocation_count", .vk = "maxSamplerAllocationCount", .kind = .at_least, .want = &.{4000} },
    .{ .name = "buffer_image_granularity", .vk = "bufferImageGranularity", .kind = .at_most, .want = &.{131072} },
    .{ .name = "sparse_address_space_size", .vk = "sparseAddressSpaceSize", .kind = .at_least, .want = &.{2147483648}, .without = &.{0}, .feature = "sparse_binding" },
    .{ .name = "max_bound_descriptor_sets", .vk = "maxBoundDescriptorSets", .kind = .at_least, .want = &.{4} },
    .{ .name = "max_per_stage_descriptor_samplers", .vk = "maxPerStageDescriptorSamplers", .kind = .at_least, .want = &.{16} },
    .{ .name = "max_per_stage_descriptor_uniform_buffers", .vk = "maxPerStageDescriptorUniformBuffers", .kind = .at_least, .want = &.{12} },
    .{ .name = "max_per_stage_descriptor_storage_buffers", .vk = "maxPerStageDescriptorStorageBuffers", .kind = .at_least, .want = &.{4} },
    .{ .name = "max_per_stage_descriptor_sampled_images", .vk = "maxPerStageDescriptorSampledImages", .kind = .at_least, .want = &.{16} },
    .{ .name = "max_per_stage_descriptor_storage_images", .vk = "maxPerStageDescriptorStorageImages", .kind = .at_least, .want = &.{4} },
    .{ .name = "max_per_stage_descriptor_input_attachments", .vk = "maxPerStageDescriptorInputAttachments", .kind = .at_least, .want = &.{4} },
    .{ .name = "max_per_stage_resources", .vk = "maxPerStageResources", .kind = .at_least, .want = &.{128} },
    .{ .name = "max_descriptor_set_samplers", .vk = "maxDescriptorSetSamplers", .kind = .at_least, .want = &.{96} },
    .{ .name = "max_descriptor_set_uniform_buffers", .vk = "maxDescriptorSetUniformBuffers", .kind = .at_least, .want = &.{72} },
    .{ .name = "max_descriptor_set_uniform_buffers_dynamic", .vk = "maxDescriptorSetUniformBuffersDynamic", .kind = .at_least, .want = &.{8} },
    .{ .name = "max_descriptor_set_storage_buffers", .vk = "maxDescriptorSetStorageBuffers", .kind = .at_least, .want = &.{24} },
    .{ .name = "max_descriptor_set_storage_buffers_dynamic", .vk = "maxDescriptorSetStorageBuffersDynamic", .kind = .at_least, .want = &.{4} },
    .{ .name = "max_descriptor_set_sampled_images", .vk = "maxDescriptorSetSampledImages", .kind = .at_least, .want = &.{96} },
    .{ .name = "max_descriptor_set_storage_images", .vk = "maxDescriptorSetStorageImages", .kind = .at_least, .want = &.{24} },
    .{ .name = "max_descriptor_set_input_attachments", .vk = "maxDescriptorSetInputAttachments", .kind = .at_least, .want = &.{4} },
    .{ .name = "max_vertex_input_attributes", .vk = "maxVertexInputAttributes", .kind = .at_least, .want = &.{16} },
    .{ .name = "max_vertex_input_bindings", .vk = "maxVertexInputBindings", .kind = .at_least, .want = &.{16} },
    .{ .name = "max_vertex_input_attribute_offset", .vk = "maxVertexInputAttributeOffset", .kind = .at_least, .want = &.{2047} },
    .{ .name = "max_vertex_input_binding_stride", .vk = "maxVertexInputBindingStride", .kind = .at_least, .want = &.{2048} },
    .{ .name = "max_vertex_output_components", .vk = "maxVertexOutputComponents", .kind = .at_least, .want = &.{64} },
    .{ .name = "max_tessellation_generation_level", .vk = "maxTessellationGenerationLevel", .kind = .at_least, .want = &.{64}, .without = &.{0}, .feature = "tessellation_shader" },
    .{ .name = "max_tessellation_patch_size", .vk = "maxTessellationPatchSize", .kind = .at_least, .want = &.{32}, .without = &.{0}, .feature = "tessellation_shader" },
    .{ .name = "max_tessellation_control_per_vertex_input_components", .vk = "maxTessellationControlPerVertexInputComponents", .kind = .at_least, .want = &.{64}, .without = &.{0}, .feature = "tessellation_shader" },
    .{ .name = "max_tessellation_control_per_vertex_output_components", .vk = "maxTessellationControlPerVertexOutputComponents", .kind = .at_least, .want = &.{64}, .without = &.{0}, .feature = "tessellation_shader" },
    .{ .name = "max_tessellation_control_per_patch_output_components", .vk = "maxTessellationControlPerPatchOutputComponents", .kind = .at_least, .want = &.{120}, .without = &.{0}, .feature = "tessellation_shader" },
    .{ .name = "max_tessellation_control_total_output_components", .vk = "maxTessellationControlTotalOutputComponents", .kind = .at_least, .want = &.{2048}, .without = &.{0}, .feature = "tessellation_shader" },
    .{ .name = "max_tessellation_evaluation_input_components", .vk = "maxTessellationEvaluationInputComponents", .kind = .at_least, .want = &.{64}, .without = &.{0}, .feature = "tessellation_shader" },
    .{ .name = "max_tessellation_evaluation_output_components", .vk = "maxTessellationEvaluationOutputComponents", .kind = .at_least, .want = &.{64}, .without = &.{0}, .feature = "tessellation_shader" },
    .{ .name = "max_geometry_shader_invocations", .vk = "maxGeometryShaderInvocations", .kind = .at_least, .want = &.{32}, .without = &.{0}, .feature = "geometry_shader" },
    .{ .name = "max_geometry_input_components", .vk = "maxGeometryInputComponents", .kind = .at_least, .want = &.{64}, .without = &.{0}, .feature = "geometry_shader" },
    .{ .name = "max_geometry_output_components", .vk = "maxGeometryOutputComponents", .kind = .at_least, .want = &.{64}, .without = &.{0}, .feature = "geometry_shader" },
    .{ .name = "max_geometry_output_vertices", .vk = "maxGeometryOutputVertices", .kind = .at_least, .want = &.{256}, .without = &.{0}, .feature = "geometry_shader" },
    .{ .name = "max_geometry_total_output_components", .vk = "maxGeometryTotalOutputComponents", .kind = .at_least, .want = &.{1024}, .without = &.{0}, .feature = "geometry_shader" },
    .{ .name = "max_fragment_input_components", .vk = "maxFragmentInputComponents", .kind = .at_least, .want = &.{64} },
    .{ .name = "max_fragment_output_attachments", .vk = "maxFragmentOutputAttachments", .kind = .at_least, .want = &.{4} },
    .{ .name = "max_fragment_dual_src_attachments", .vk = "maxFragmentDualSrcAttachments", .kind = .at_least, .want = &.{1}, .without = &.{0}, .feature = "dual_src_blend" },
    .{ .name = "max_fragment_combined_output_resources", .vk = "maxFragmentCombinedOutputResources", .kind = .at_least, .want = &.{4} },
    .{ .name = "max_compute_shared_memory_size", .vk = "maxComputeSharedMemorySize", .kind = .at_least, .want = &.{16384} },
    .{ .name = "max_compute_work_group_count", .vk = "maxComputeWorkGroupCount", .kind = .each_at_least, .want = &.{ 65535, 65535, 65535 } },
    .{ .name = "max_compute_work_group_invocations", .vk = "maxComputeWorkGroupInvocations", .kind = .at_least, .want = &.{128} },
    .{ .name = "max_compute_work_group_size", .vk = "maxComputeWorkGroupSize", .kind = .each_at_least, .want = &.{ 128, 128, 64 } },
    .{ .name = "sub_pixel_precision_bits", .vk = "subPixelPrecisionBits", .kind = .at_least, .want = &.{4} },
    .{ .name = "sub_texel_precision_bits", .vk = "subTexelPrecisionBits", .kind = .at_least, .want = &.{4} },
    .{ .name = "mipmap_precision_bits", .vk = "mipmapPrecisionBits", .kind = .at_least, .want = &.{4} },
    .{ .name = "max_draw_indexed_index_value", .vk = "maxDrawIndexedIndexValue", .kind = .at_least, .want = &.{4294967295}, .without = &.{16777215}, .feature = "full_draw_index_uint32" },
    .{ .name = "max_draw_indirect_count", .vk = "maxDrawIndirectCount", .kind = .at_least, .want = &.{65535}, .without = &.{1}, .feature = "multi_draw_indirect" },
    .{ .name = "max_sampler_lod_bias", .vk = "maxSamplerLodBias", .kind = .at_least, .want = &.{2} },
    .{ .name = "max_sampler_anisotropy", .vk = "maxSamplerAnisotropy", .kind = .at_least, .want = &.{16}, .without = &.{1}, .feature = "sampler_anisotropy" },
    .{ .name = "max_viewports", .vk = "maxViewports", .kind = .at_least, .want = &.{16}, .without = &.{1}, .feature = "multi_viewport" },
    .{ .name = "max_viewport_dimensions", .vk = "maxViewportDimensions", .kind = .each_at_least, .want = &.{ 4096, 4096 } },
    .{ .name = "viewport_bounds_range", .vk = "viewportBoundsRange", .kind = .pair_outward, .want = &.{ -8192, 8191 } },
    .{ .name = "viewport_sub_pixel_bits", .vk = "viewportSubPixelBits", .kind = .at_least, .want = &.{0} },
    .{ .name = "min_memory_map_alignment", .vk = "minMemoryMapAlignment", .kind = .at_least, .want = &.{64} },
    .{ .name = "min_texel_buffer_offset_alignment", .vk = "minTexelBufferOffsetAlignment", .kind = .at_most, .want = &.{256} },
    .{ .name = "min_uniform_buffer_offset_alignment", .vk = "minUniformBufferOffsetAlignment", .kind = .at_most, .want = &.{256} },
    .{ .name = "min_storage_buffer_offset_alignment", .vk = "minStorageBufferOffsetAlignment", .kind = .at_most, .want = &.{256} },
    .{ .name = "min_texel_offset", .vk = "minTexelOffset", .kind = .at_most, .want = &.{-8} },
    .{ .name = "max_texel_offset", .vk = "maxTexelOffset", .kind = .at_least, .want = &.{7} },
    .{ .name = "min_texel_gather_offset", .vk = "minTexelGatherOffset", .kind = .at_most, .want = &.{-8}, .without = &.{0}, .feature = "shader_image_gather_extended" },
    .{ .name = "max_texel_gather_offset", .vk = "maxTexelGatherOffset", .kind = .at_least, .want = &.{7}, .without = &.{0}, .feature = "shader_image_gather_extended" },
    .{ .name = "min_interpolation_offset", .vk = "minInterpolationOffset", .kind = .at_most, .want = &.{-0.5}, .without = &.{0}, .feature = "sample_rate_shading" },
    .{ .name = "max_interpolation_offset", .vk = "maxInterpolationOffset", .kind = .at_least, .want = &.{0.5}, .without = &.{0}, .feature = "sample_rate_shading" },
    .{ .name = "sub_pixel_interpolation_offset_bits", .vk = "subPixelInterpolationOffsetBits", .kind = .at_least, .want = &.{4}, .without = &.{0}, .feature = "sample_rate_shading" },
    .{ .name = "max_framebuffer_width", .vk = "maxFramebufferWidth", .kind = .at_least, .want = &.{4096} },
    .{ .name = "max_framebuffer_height", .vk = "maxFramebufferHeight", .kind = .at_least, .want = &.{4096} },
    .{ .name = "max_framebuffer_layers", .vk = "maxFramebufferLayers", .kind = .at_least, .want = &.{256} },
    .{ .name = "framebuffer_color_sample_counts", .vk = "framebufferColorSampleCounts", .kind = .mask_includes, .want = &.{5} },
    .{ .name = "framebuffer_depth_sample_counts", .vk = "framebufferDepthSampleCounts", .kind = .mask_includes, .want = &.{5} },
    .{ .name = "framebuffer_stencil_sample_counts", .vk = "framebufferStencilSampleCounts", .kind = .mask_includes, .want = &.{5} },
    .{ .name = "framebuffer_no_attachments_sample_counts", .vk = "framebufferNoAttachmentsSampleCounts", .kind = .mask_includes, .want = &.{5} },
    .{ .name = "max_color_attachments", .vk = "maxColorAttachments", .kind = .at_least, .want = &.{4} },
    .{ .name = "sampled_image_color_sample_counts", .vk = "sampledImageColorSampleCounts", .kind = .mask_includes, .want = &.{5} },
    .{ .name = "sampled_image_integer_sample_counts", .vk = "sampledImageIntegerSampleCounts", .kind = .mask_includes, .want = &.{1} },
    .{ .name = "sampled_image_depth_sample_counts", .vk = "sampledImageDepthSampleCounts", .kind = .mask_includes, .want = &.{5} },
    .{ .name = "sampled_image_stencil_sample_counts", .vk = "sampledImageStencilSampleCounts", .kind = .mask_includes, .want = &.{5} },
    .{ .name = "storage_image_sample_counts", .vk = "storageImageSampleCounts", .kind = .mask_includes, .want = &.{5}, .without = &.{1}, .feature = "shader_storage_image_multisample" },
    .{ .name = "max_sample_mask_words", .vk = "maxSampleMaskWords", .kind = .at_least, .want = &.{1} },
    .{ .name = "timestamp_compute_and_graphics", .vk = "timestampComputeAndGraphics", .kind = .none },
    .{ .name = "timestamp_period", .vk = "timestampPeriod", .kind = .none },
    .{ .name = "max_clip_distances", .vk = "maxClipDistances", .kind = .at_least, .want = &.{8}, .without = &.{0}, .feature = "shader_clip_distance" },
    .{ .name = "max_cull_distances", .vk = "maxCullDistances", .kind = .at_least, .want = &.{8}, .without = &.{0}, .feature = "shader_cull_distance" },
    .{ .name = "max_combined_clip_and_cull_distances", .vk = "maxCombinedClipAndCullDistances", .kind = .at_least, .want = &.{8}, .without = &.{0}, .feature = "shader_cull_distance" },
    .{ .name = "discrete_queue_priorities", .vk = "discreteQueuePriorities", .kind = .at_least, .want = &.{2} },
    .{ .name = "point_size_range", .vk = "pointSizeRange", .kind = .pair_outward, .want = &.{ 1, 64 }, .without = &.{ 1, 1 }, .feature = "large_points" },
    .{ .name = "line_width_range", .vk = "lineWidthRange", .kind = .pair_outward, .want = &.{ 1, 8 }, .without = &.{ 1, 1 }, .feature = "wide_lines" },
    .{ .name = "point_size_granularity", .vk = "pointSizeGranularity", .kind = .at_most, .want = &.{1}, .without = &.{0}, .feature = "large_points" },
    .{ .name = "line_width_granularity", .vk = "lineWidthGranularity", .kind = .at_most, .want = &.{1}, .without = &.{0}, .feature = "wide_lines" },
    .{ .name = "strict_lines", .vk = "strictLines", .kind = .none },
    .{ .name = "standard_sample_locations", .vk = "standardSampleLocations", .kind = .none },
    .{ .name = "optimal_buffer_copy_offset_alignment", .vk = "optimalBufferCopyOffsetAlignment", .kind = .none },
    .{ .name = "optimal_buffer_copy_row_pitch_alignment", .vk = "optimalBufferCopyRowPitchAlignment", .kind = .none },
    .{ .name = "non_coherent_atom_size", .vk = "nonCoherentAtomSize", .kind = .at_most, .want = &.{256} },
};

fn asFloat(value: anytype) f64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        else => @compileError("a limit that is neither a number nor an array of them"),
    };
}

fn fromFloat(comptime T: type, value: f64) T {
    return switch (@typeInfo(T)) {
        .int => @intFromFloat(value),
        .float => @floatCast(value),
        else => @compileError("a limit that is neither a number nor an array of them"),
    };
}

/// Which of a row's two required values applies: the Unsupported column is
/// mandatory where the feature reads false, not merely permitted.
pub fn wanted(
    comptime row: Row,
    features: *const facet.PhysicalDeviceFeatures,
) []const f64 {
    const named = row.feature orelse return row.want;
    const has = @field(features, named) != facet.FALSE;
    return if (has) row.want else (row.without orelse row.want);
}

/// Whether `limits` meets `row` on a device whose features are `features`.
pub fn meets(
    comptime row: Row,
    limits: *const facet.PhysicalDeviceLimits,
    features: *const facet.PhysicalDeviceFeatures,
) bool {
    if (row.kind == .none) return true;
    const want = wanted(row, features);
    const got = @field(limits, row.name);
    return switch (row.kind) {
        .none => true,
        .at_least => asFloat(got) >= want[0],
        .at_most => asFloat(got) <= want[0],
        .mask_includes => blk: {
            const bits: u32 = @intFromFloat(want[0]);
            break :blk got & bits == bits;
        },
        .each_at_least => blk: {
            for (got, 0..) |each, i| {
                if (asFloat(each) < want[@min(i, want.len - 1)]) break :blk false;
            }
            break :blk true;
        },
        .pair_outward => asFloat(got[0]) <= want[0] and asFloat(got[1]) >= want[1],
    };
}

/// How many of the 106 `limits` does not meet.
pub fn shortfalls(
    limits: *const facet.PhysicalDeviceLimits,
    features: *const facet.PhysicalDeviceFeatures,
) u32 {
    var count: u32 = 0;
    inline for (required) |row| {
        if (!meets(row, limits, features)) count += 1;
    }
    return count;
}

/// Every one it does not meet, with the number it reports and the number
/// Vulkan asks for.
pub fn report(
    limits: *const facet.PhysicalDeviceLimits,
    features: *const facet.PhysicalDeviceFeatures,
) void {
    inline for (required) |row| {
        if (!meets(row, limits, features)) {
            std.debug.print("  {s} reports {any}, Vulkan asks {s} {any}\n", .{
                row.vk,
                @field(limits, row.name),
                @tagName(row.kind),
                wanted(row, features),
            });
        }
    }
}

/// A device sitting exactly on Vulkan's floor: every limit the table names
/// set to the least value that is allowed to pass, and the rest left at
/// zero. Nothing reports this - it is how the check below proves itself.
pub fn atTheFloor(features: *const facet.PhysicalDeviceFeatures) facet.PhysicalDeviceLimits {
    var limits = std.mem.zeroes(facet.PhysicalDeviceLimits);
    inline for (required) |row| {
        if (row.kind != .none) {
            const want = wanted(row, features);
            const Field = @TypeOf(@field(limits, row.name));
            switch (@typeInfo(Field)) {
                .array => |array| for (0..array.len) |i| {
                    @field(limits, row.name)[i] = fromFloat(array.child, want[@min(i, want.len - 1)]);
                },
                else => @field(limits, row.name) = fromFloat(Field, want[0]),
            }
        }
    }
    return limits;
}

const testing = std.testing;
const Rig = @import("facet.zig").Rig;

/// How many of the 106 the cores do not meet.
///
/// **Lower this when an item closes; do not raise it.** A number going up
/// means a limit now reports worse than it did, which is a regression and
/// is what this is here to catch. The V3D is not in this count because it
/// is not on this host: it reports its own numbers (driver/v3d/driver.zig
/// overrides about eighteen of them downward) and only the board can say
/// whether it meets them.
///
/// **None since 1.114**: the cores meet all 106. The last was item 61 of
/// docs/facet-vulkan10.md, multisampling, in its no-attachments
/// sample-count mask, which holds VK_SAMPLE_COUNT_4_BIT since a subpass of
/// no attachment is drawn at its pipelines' count: item 43 made such a
/// subpass in 1.113, and item 61's step K8 its four samples. The other
/// eight sample-count masks are met: six hold the 4 bit since 1.112, and
/// of the integer sampled-image mask and the storage-image mask Vulkan
/// asks only the 1 bit, of the second while
/// `shader_storage_image_multisample` is false.
///
/// Closed since this count was first taken, which began at eighteen:
/// **item 18** in 1.84, maxVertexInputBindings 4 and
/// maxVertexInputAttributes 8 against 16 apiece; and **item 19** in 1.85,
/// the one combined cap of 2 dynamic buffer descriptors a set against
/// Vulkan's 8 uniform and 4 storage a pipeline layout; **item 21** in
/// 1.86, maxImageDimension1D 0 because there were no 1D images; **item
/// 28's half of two** in 1.87, minTexelOffset and maxTexelOffset both 0
/// because no sample took a constant texel offset; and **item 61's first
/// row of eight** in 1.89, maxSampleMaskWords 0 against 1, which was the
/// one row of that item needing no new sample: at one sample a pixel the
/// mask is bit 0 alone, and a pipeline that clears it draws nothing; **item
/// 17's half of two** in 1.90, maxVertexOutputComponents and
/// maxFragmentInputComponents both 8 against 64; **item 22's half of
/// two** in 1.91, maxFramebufferLayers 1 against 256, a pass clearing each
/// layer and drawing into the first; **item 61's six rows** in 1.112,
/// the three framebuffer sample-count masks and the colour, depth and
/// stencil sampled-image masks, which hold the 4 bit since the cores draw
/// four samples a pixel; and **item 61's last row** in 1.114, the
/// no-attachments mask, after item 43 made such a subpass in 1.113.
///
/// Items 28, 17, 22, 61 and 43 are split the way item 52 was, so **this
/// count is the cores' and the V3D still falls short on twelve rows**: 0
/// for the two texel offsets, which it reads off its own SPIR-V profile; 8
/// for the two varyings, which it reads off its compiler's own cap - Mesa's
/// v3dv carries 64 on this same GPU, so that is this compiler's limit, not
/// the hardware's; 1 framebuffer layer, until its render list is played
/// once a layer as v3dv's is (driver/v3d/driver.zig); one sample in the
/// six masks, until it draws four (item 61's V5); and one in the
/// no-attachments mask, until it makes a subpass of no attachment (item
/// 43's V3D half) and draws four in it (item 61's V8).
const shortfalls_on_the_cores = 0;

test "the check itself: Vulkan's floor passes, and a step below it is caught" {
    // A check that passes is worth nothing on its own: one whose loop never
    // runs passes too, and `at_most` read as `at_least` passes on most of
    // the table. So: a device built from the table, on the floor
    // everywhere, must have nothing against it...
    const bare = facet.PhysicalDeviceFeatures{}; // every feature false
    const floor = atTheFloor(&bare);
    if (shortfalls(&floor, &bare) != 0) {
        report(&floor, &bare);
        return error.TheFloorDoesNotPass;
    }

    // ...and one step the wrong way, in each of the five kinds that are
    // checked, must be caught - which is what says the comparison runs the
    // right way round for that kind.
    var below = floor;
    below.max_image_dimension_2d -= 1; // at_least 4096
    try testing.expectEqual(1, shortfalls(&below, &bare));

    below = floor;
    below.buffer_image_granularity += 1; // at_most 131072
    try testing.expectEqual(1, shortfalls(&below, &bare));

    below = floor;
    below.framebuffer_color_sample_counts &= ~facet.SAMPLE_COUNT_1; // mask_includes 1|4
    try testing.expectEqual(1, shortfalls(&below, &bare));

    below = floor;
    below.max_compute_work_group_count[1] -= 1; // each_at_least 65535
    try testing.expectEqual(1, shortfalls(&below, &bare));

    below = floor;
    below.point_size_range[0] += 1; // pair_outward, outward from 1
    try testing.expectEqual(1, shortfalls(&below, &bare));

    // And a feature claimed without the limit to match it: `large_points`
    // true moves pointSizeRange's requirement from (1,1) to (1,64), which
    // the floor-for-no-features device does not meet. This is the trap the
    // Unsupported column sets, caught here on purpose.
    var claimed = bare;
    claimed.large_points = facet.TRUE;
    try testing.expect(shortfalls(&floor, &claimed) > 0);
}

test "every Vulkan 1.0 limit requirement, and how many the cores do not meet" {
    var rig = try Rig.up();
    defer rig.down() catch |err| std.debug.panic("{}", .{err});
    const instance, const physical = try rig.instance();
    defer rig.fb.DestroyInstance(instance);
    var properties: facet.PhysicalDeviceProperties = undefined;
    rig.fb.GetPhysicalDeviceProperties(physical, &properties);
    var features: facet.PhysicalDeviceFeatures = undefined;
    rig.fb.GetPhysicalDeviceFeatures(physical, &features);

    // Every row names a real member, at the member's own position, which is
    // what keeps this table from drifting away from the structure as the
    // structure changes.
    const members = @typeInfo(facet.PhysicalDeviceLimits).@"struct".fields;
    try testing.expectEqual(members.len, required.len);
    inline for (required, 0..) |row, i| {
        try testing.expectEqualStrings(members[i].name, row.name);
    }

    const short = shortfalls(&properties.limits, &features);
    // Said only when the number moved, so that a passing build is quiet: a
    // test that prints eighteen lines every time is one nobody reads.
    if (short != shortfalls_on_the_cores) {
        std.debug.print(
            "\n{d} of Vulkan 1.0's 106 limit requirements are not met, where {d} were:\n",
            .{ short, shortfalls_on_the_cores },
        );
        report(&properties.limits, &features);
        std.debug.print(
            "Fewer is progress: lower `shortfalls_on_the_cores` and say which item closed.\n" ++
                "More is a regression: a limit now reports worse than it did.\n",
            .{},
        );
    }
    try testing.expectEqual(shortfalls_on_the_cores, short);

    // Two rules the table cannot carry, because they are relative.
    //
    // The viewport's bounds must reach twice the viewport's own size either
    // way, so this one scales with what the device reports rather than
    // sitting at the table's base minimum of -8192 and 8191.
    const side: f32 = @floatFromInt(properties.limits.max_viewport_dimensions[0]);
    try testing.expect(properties.limits.viewport_bounds_range[0] <= -2 * side);
    try testing.expect(properties.limits.viewport_bounds_range[1] >= 2 * side - 1);
    // And maxPerStageResources must reach the smaller of 128 and the sum of
    // the per-stage descriptor limits with the colour attachments.
    const summed: u64 = @as(u64, properties.limits.max_per_stage_descriptor_uniform_buffers) +
        properties.limits.max_per_stage_descriptor_storage_buffers +
        properties.limits.max_per_stage_descriptor_sampled_images +
        properties.limits.max_per_stage_descriptor_storage_images +
        properties.limits.max_per_stage_descriptor_input_attachments +
        properties.limits.max_color_attachments;
    try testing.expect(properties.limits.max_per_stage_resources >= @min(summed, 128));
}
