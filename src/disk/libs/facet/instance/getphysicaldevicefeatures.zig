// SPDX-License-Identifier: MIT
//! GetPhysicalDeviceFeatures: what a physical device does.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _instance = @import("_instance.zig");
const PhysicalDevice = _instance.PhysicalDevice;

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
/// Vulkan's 55 members, in Vulkan's order and four bytes each, made from
/// what the device's driver said of itself as the instance was made. They
/// hold while the instance lasts.
///
/// Until 1.82 this handed out a structure of facet's own: 49 Zig `bool`
/// fields, one byte each, chosen so there was one wherever a create call
/// could refuse something. A program reading a `VkPhysicalDeviceFeatures`
/// out of that read 49 bytes of something else. Those 49 are the library's
/// own record now (`_instance.Capabilities`) and still decide what every
/// create call refuses; this call answers Vulkan's question instead, which
/// is a different question.
///
/// **Vulkan 1.0 requires exactly one of these 55**, `robust_buffer_access`,
/// of an implementation that does not advertise
/// `VK_KHR_portability_subset`; its "Feature Requirements" section ends
/// "All other features defined in the Specification are optional". So a
/// `FALSE` here is usually a real choice a program may work around, which
/// is the opposite of facet's old 49, where most of the fields gated
/// something Vulkan requires unconditionally and a false was a defect.
///
/// **But a `FALSE` is not free.** Vulkan's required-limits table gives most
/// limits two values, one for the feature being off and one for it on, and
/// the off value is *mandatory*: say `sampler_anisotropy` is false and
/// `max_sampler_anisotropy` must read 1, say `multi_viewport` is false and
/// `max_viewports` must read 1, say `shader_clip_distance` is false and
/// `max_clip_distances` must read 0. Each `of(...)` below therefore ties a
/// limit as well, and `_instance.limits` says which.
///
/// What a program may usefully branch on per device is `sampler_anisotropy`
/// and `image_cube_array`, which the cores have and a CM5's V3D has not,
/// with the limits saying the rest of what differs - that V3D takes one
/// sampled image a stage where the cores take as many as a set will hold
/// (`GetPhysicalDeviceProperties`).
///
/// **What is no longer asked here.** Six of facet's 49 were facet's own
/// idea with no Vulkan meaning - `own_fragment_functions`,
/// `sampling_format`, `compute_on_device`, `tessellation_on_device`,
/// `depth_prepass` and `discarding_fragment_forms` - and they described the
/// fixed forms, which are facet's own surface rather than Vulkan's. There
/// is no member for them, so a program that wants a fixed form asks for the
/// pipeline and is answered `error_feature_not_present` if the device has
/// not got it, which it was answered before as well. Where those belong is
/// the open question of docs/facet-vulkan10.md item 51.
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
/// if (features.sampler_anisotropy == facet.TRUE) {
///     // This device samples along the longer axis: maxSamplerAnisotropy.
/// }
/// ```
pub fn GetPhysicalDeviceFeatures(base: *FacetBase, physical: *facet.PhysicalDevice, features: *facet.PhysicalDeviceFeatures) void {
    _ = base;
    features.* = vulkanOf(&_objects.of(PhysicalDevice, physical).can);
}

/// Vulkan's 55 features for a device whose capabilities are `can`.
///
/// Every answer here is what the library does, never what would be
/// convenient to claim: a `TRUE` is a promise a program may build on, and
/// a `FALSE` against something Vulkan 1.0 requires is a defect this says
/// out loud. The comment on a line is why it reads as it does.
pub fn vulkanOf(can: *const _instance.Capabilities) facet.PhysicalDeviceFeatures {
    const yes = facet.TRUE;
    const no = facet.FALSE;
    return .{
        // **The one feature Vulkan 1.0 requires of every implementation**,
        // and the library has it on every path a program can take.
        //
        // An attribute read past the end of its vertex buffer is left at
        // the (0, 0, 0, 1) the inputs were cleared to - driver/_vertices.zig
        // `readInputs`, which is `@memset(into, .{ 0, 0, 0, 1 })` and then
        // `if (at + size > bytes.len) continue;` - which is the behaviour
        // Vulkan's robustness rules name for exactly that case.
        //
        // Every buffer a function reaches is bounded by the descriptor it
        // reaches it through, and the bound is the descriptor's own range:
        // `shader.Resources.bufferAt` answers null rather than a pointer
        // where the range does not hold the type asked for,
        // `storageAt` hands back a Zig slice of `range / @sizeOf(T)`
        // elements, `texels` carries a count worked out the same way, and
        // an index naming a vertex past the vertex buffer has its triangle
        // left out (driver/_vertices.zig). So there is no access here that
        // reads or writes outside the range bound to it.
        .robust_buffer_access = yes,
        // CmdDrawIndexed caps nothing, the index type may be `uint32`, and
        // an index is carried as a u32 the whole way
        // (driver/_vertices.zig: `number > maxInt(u32)` is the only bound),
        // with 0xFFFFFFFF reserved as Vulkan reserves it - the primitive
        // restart index, which is `no_corner` here. The 2^20 cap on
        // CmdDraw is a cap on a draw's vertex *count* and not on an index
        // value (docs/facet-vulkan10.md item 23 is about the count).
        .full_draw_index_uint32 = yes,
        .image_cube_array = of(can.cube_arrays),
        .independent_blend = of(can.independent_blend),
        // There is no geometry stage. SHADER_STAGE_GEOMETRY has a name
        // since 1.80 because ALL_GRAPHICS always included its bit, which is
        // not the same as there being a stage behind it.
        .geometry_shader = no,
        // The library tessellates - a pipeline may carry a control and an
        // evaluation function, and the patch is cut on the cores whichever
        // device made it - but not for a program that brings SPIR-V, which
        // is what this call is asked by. `spirv.facet_profile` leaves
        // `Profile.stages` at its default of vertex and fragment, so
        // `takesStage` refuses a tessellation_control or
        // tessellation_evaluation entry point and CreateShaderModule turns
        // the module away (shader/createshadermodule.zig). The stage is
        // reachable only through facet's own Zig entry constructors, which
        // are facet's surface and not Vulkan's. Saying true here would also
        // oblige the eight maxTessellation* limits to the values Vulkan asks
        // of a device that has the stage, which this does not meet.
        // docs/facet-vulkan10.md item 60 is the SPIR-V side of it.
        .tessellation_shader = no,
        // Optional, and off on both devices whether or not they draw four
        // samples a pixel (`can.multisampling`): a pipeline asking for
        // either is refused (pipeline/creategraphicspipelines.zig). Both
        // Mesa drivers have them, v3dv on this same GPU and lavapipe on
        // the cores (src/broadcom/vulkan/v3dv_device.c,
        // src/gallium/frontends/lavapipe/lvp_device.c), so they are a port
        // of their own after docs/facet-vulkan10.md item 61. Sample rate
        // shading would bring the three interpolation-offset limits with
        // it, which are 0 here (_instance.zig).
        .sample_rate_shading = no,
        .alpha_to_one = no,
        // The blend factors that read a second source colour are refused.
        // docs/facet-vulkan10.md item 62.
        .dual_src_blend = no,
        .logic_op = of(can.logic_ops),
        // An indirect draw takes a count and a stride and plays each of the
        // draws in turn, and each carries its own first_instance, which the
        // draw honours (driver/cpu/_draw.zig).
        .multi_draw_indirect = of(can.indirect_draws),
        .draw_indirect_first_instance = of(can.indirect_draws),
        .depth_clamp = of(can.depth_clamp),
        // The depth offset packet takes Vulkan's three numbers as they are,
        // the clamp among them, so the clamp comes with the bias.
        .depth_bias_clamp = of(can.depth_bias),
        // A triangle drawn as its edges or its corners is what
        // `points_and_lines` covers, with `polygon_mode`.
        .fill_mode_non_solid = of(can.points_and_lines),
        .depth_bounds = of(can.depth_bounds),
        // A line and a point are widened into rectangles by the cores for
        // either device, and nothing in the widening caps the width
        // (driver/_vertices.zig widen), so a device that draws lines at all
        // draws wide ones. `lineWidthRange` and `pointSizeRange` say how
        // wide.
        .wide_lines = of(can.points_and_lines),
        .large_points = of(can.points_and_lines),
        .multi_viewport = of(can.several_viewports),
        .sampler_anisotropy = of(can.sampler_anisotropy),
        // Each of these three is a promise about a whole family of formats
        // and not about one: Vulkan asks that every format of the family
        // report SAMPLED_IMAGE, BLIT_SRC and SAMPLED_IMAGE_FILTER_LINEAR.
        // Measured against the registry header: the ETC2 and EAC family is
        // ten formats and five are here (no sRGB, no snorm EAC), and the BC
        // family is sixteen and nine are here (no sRGB, no snorm BC4 or
        // BC5). So neither bit may be set, however much of each family is
        // decoded - `can.etc2_textures`, `can.compressed_textures` and
        // `can.kept_compressed` say what really is, and
        // GetPhysicalDeviceFormatProperties says it format by format,
        // which is where a program should look. ASTC is not decoded at all.
        // docs/facet-vulkan10.md items 38 and 63.
        .texture_compression_etc2 = no,
        .texture_compression_astc_ldr = no,
        .texture_compression_bc = no,
        // The tiles count the samples that passed as they are drawn, which
        // is an exact count and not merely a non-zero one.
        .occlusion_query_precise = of(can.occlusion_queries),
        .pipeline_statistics_query = of(can.pipeline_statistics_queries),
        // No shader writes a storage buffer or image, and there are no
        // atomics. docs/facet-vulkan10.md item 39.
        .vertex_pipeline_stores_and_atomics = no,
        .fragment_stores_and_atomics = no,
        // No tessellation or geometry function writes PointSize.
        .shader_tessellation_and_geometry_point_size = no,

        // --- what a shader may contain ---
        // The SPIR-V profile is what a module may hold (sdk/libs/facet/
        // spirv.zig's facet_profile, and driver/v3d/compile.zig's profile
        // for the V3D), and none of these is in it: no gather, no storage
        // image of any kind, no array of descriptors indexed by anything
        // the shader works out, no clip or cull distance, no 64- or 16-bit
        // arithmetic. docs/facet-vulkan10.md item 59 is the profile's own
        // growth.
        .shader_image_gather_extended = no,
        .shader_storage_image_extended_formats = no,
        .shader_storage_image_multisample = no,
        .shader_storage_image_read_without_format = no,
        .shader_storage_image_write_without_format = no,
        .shader_uniform_buffer_array_dynamic_indexing = no,
        .shader_sampled_image_array_dynamic_indexing = no,
        .shader_storage_buffer_array_dynamic_indexing = no,
        .shader_storage_image_array_dynamic_indexing = no,
        .shader_clip_distance = no,
        .shader_cull_distance = no,
        .shader_float64 = no,
        .shader_int64 = no,
        .shader_int16 = no,
        .shader_resource_residency = no,
        .shader_resource_min_lod = no,

        // --- memory bound a piece at a time ---
        // Nothing here binds memory sparsely: there are no sparse commands
        // in the jump table and `PhysicalDeviceSparseProperties` is five
        // falses beside these. docs/facet-vulkan10.md item 12.
        .sparse_binding = no,
        .sparse_residency_buffer = no,
        .sparse_residency_image_2d = no,
        .sparse_residency_image_3d = no,
        .sparse_residency_2_samples = no,
        .sparse_residency_4_samples = no,
        .sparse_residency_8_samples = no,
        .sparse_residency_16_samples = no,
        .sparse_residency_aliased = no,

        // --- the rest ---
        // Pipelines of different sample counts in one subpass with no
        // attachments, where without the feature they must all agree.
        // Off, as v3dv has it on this same GPU
        // (src/broadcom/vulkan/v3dv_device.c); and a subpass with no
        // attachments is drawn at one sample alone here
        // (render/createrenderpass.zig, since 1.113), until item 61's K8.
        .variable_multisample_rate = no,
        // `CommandBufferInheritanceInfo` is a render pass, a subpass and a
        // framebuffer and nothing else, so there is no way for a secondary
        // buffer to be told which query it runs inside. The library cannot
        // express this rather than merely declining it.
        .inherited_queries = no,
    };
}

/// A capability bit as Vulkan's four-byte boolean.
fn of(able: bool) facet.Bool32 {
    return if (able) facet.TRUE else facet.FALSE;
}
