// SPDX-License-Identifier: MIT
//! facet.library's structures and constants: the objects a program draws
//! in three dimensions with, what it makes them from, and what it asks of
//! them. The calls are in `sdk.interface.facet`.
//!
//! **The objects are Vulkan's**, with their names and their lifetimes,
//! and without the prefix: an `Instance` is a program's hold on the
//! library; the `PhysicalDevice`s it lists are what draws - the machine's
//! cores, as one device, through the rasterizer of facet.library; a
//! `Device` made on one is the program's own, with the `Queue` its work
//! goes to. Memory is allocated from the device (`DeviceMemory`), buffers
//! and images are bound into it, command buffers record what is drawn,
//! and a queue plays them. Each object is made by a `Create...` or an
//! `Allocate...` call and goes by the `Destroy...` or `Free...` that goes
//! with it, before the object it was made from goes.
//!
//! **A call answers a `Result`** where it can fail, and writes what it
//! made through its last parameter, null when it failed. What a call is
//! given in a `...CreateInfo` is read during the call alone.
//!
//! **The device is the processor.** Its memory is the machine's RAM:
//! every memory type is local to the device, seen by the program and
//! coherent with it, and mapping memory is handing out its address. The
//! types are made from the attributes exec's memory regions carry
//! (MEMF_*), one for each set of them, and one more for attachments that
//! are never stored (`MEMORY_PROPERTY_LAZILY_ALLOCATED`).
//!
//! **Shaders are functions** of the program's own, compiled into it: a
//! shader module carries them where Vulkan's carries SPIR-V (`shader`).
//! A pipeline's state - its vertex input, culling, depth test and blend -
//! is settled as it is made, and its draws run the rasterizer's code made
//! for that state.
//!
//! **Pictures are shown through a surface** made over a screen of
//! intuition's or a window on one. A swapchain on a screen hands out the
//! screen's buffers as its images, one at a time (AcquireNextImage), and
//! QueuePresent shows one from the display's next frame on, as
//! ChangeScreenBuffer does. A swapchain on a window hands out pictures in
//! memory, and QueuePresent copies one into the window at the display's
//! next frame, through its layer - or, on a screen whose windows are
//! composed, shows it in the window as it is, without the copy.

/// The library's name, for OpenLibrary.
pub const FACETNAME = "facet.library";

/// How an optimal image keeps a texture, and how a fragment function
/// samples it.
pub const texture = @import("texture.zig");

/// A pipeline's vertex and fragment functions: what a shader module
/// carries, what they are given, and the helpers they are written with.
pub const shader = @import("shader.zig");

const intuition = @import("../intuition/intuition.zig");

// --- handles ----------------------------------------------------------------

/// A program's hold on the library: what it lists the devices through.
pub const Instance = opaque {};
/// What draws: the machine's cores, through facet.library's rasterizer.
pub const PhysicalDevice = opaque {};
/// A program's own device, made on a physical one.
pub const Device = opaque {};
/// Where a device's work goes, played in turn by a task of its own.
pub const Queue = opaque {};
/// A block of the device's memory.
pub const DeviceMemory = opaque {};

// --- results ----------------------------------------------------------------

/// What a call came to. The numbers are Vulkan's.
pub const Result = enum(i32) {
    success = 0,
    /// A fence or a query is not yet signalled.
    not_ready = 1,
    /// A wait ran out of time first.
    timeout = 2,
    /// An array was too short for all there is: as much as fits is in it.
    incomplete = 5,
    /// The library's own memory ran out.
    error_out_of_host_memory = -1,
    /// The device's memory ran out.
    error_out_of_device_memory = -2,
    error_initialization_failed = -3,
    /// The device can do nothing more: its queue's task is gone.
    error_device_lost = -4,
    /// The memory cannot be mapped: it is lazily allocated, or mapped
    /// already.
    error_memory_map_failed = -5,
    /// What was asked for is not something this library does.
    error_feature_not_present = -8,
    error_too_many_objects = -10,
    /// The format is not one this library does for what it was asked.
    error_format_not_supported = -11,
    /// A descriptor pool has room for the sets, but not in one piece.
    error_fragmented_pool = -12,
    /// A descriptor pool has no room for another set.
    error_out_of_pool_memory = -1000069000,
    /// A shader module's code is not a `shader.Code`, or names no
    /// function a pipeline's stage asks for.
    error_invalid_shader_nv = -1000012000,
    /// A swapchain's image was shown, but the surface has changed under
    /// it: it still works, and is better made again.
    suboptimal = 1000001003,
    /// The surface is gone: its screen is closed.
    error_surface_lost = -1000000000,
    /// The surface already has a swapchain that was not handed on.
    error_native_window_in_use = -1000000001,
    /// The surface changed under a swapchain: it has to be made again.
    error_out_of_date = -1000001004,
    _,
};

/// The size that means all of a memory or a buffer from the offset given.
pub const WHOLE_SIZE: u64 = ~@as(u64, 0);

// --- the instance -----------------------------------------------------------

/// The facet.library version a program asks for: `major` is the
/// library's version, `minor` its revision.
pub fn makeVersion(major: u32, minor: u32) u32 {
    return major << 16 | minor;
}

/// The first version of the interface.
pub const API_VERSION_1_0: u32 = makeVersion(1, 0);

/// What a program is, for an Instance.
pub const InstanceCreateInfo = extern struct {
    flags: u32 = 0,
    /// The program's name and its own version, for whoever lists who uses
    /// the library; may be null.
    application_name: ?[*:0]const u8 = null,
    application_version: u32 = 0,
    /// The interface the program was written for: no newer than the
    /// library's, or the instance is refused
    /// (`error_initialization_failed`). 0 is `API_VERSION_1_0`.
    api_version: u32 = API_VERSION_1_0,
};

// --- the physical device ----------------------------------------------------

/// What kind of device it is. The numbers are Vulkan's.
pub const PhysicalDeviceType = enum(u32) {
    other = 0,
    integrated_gpu = 1,
    discrete_gpu = 2,
    virtual_gpu = 3,
    /// The processor: facet.library's own.
    cpu = 4,
    _,
};

/// The most a device does.
pub const PhysicalDeviceLimits = extern struct {
    /// The widest and highest image, and framebuffer.
    max_image_dimension_2d: u32,
    max_framebuffer_width: u32,
    max_framebuffer_height: u32,
    /// The deepest 3D image, and the layers of an array.
    max_image_dimension_3d: u32,
    max_image_array_layers: u32,
    /// The colour attachments of a subpass.
    max_color_attachments: u32,
    /// The vertex buffers bound at once, and the attributes and the
    /// stride of a vertex in them.
    max_vertex_input_bindings: u32,
    max_vertex_input_attributes: u32,
    max_vertex_input_binding_stride: u32,
    /// The floats a vertex function hands the fragment function, past
    /// the position: what is mixed over a triangle.
    max_vertex_output_components: u32,
    /// The bytes of push constants.
    max_push_constants_size: u32,
    /// The descriptor sets bound at once, and the descriptors of each
    /// kind in a pipeline's layout.
    max_bound_descriptor_sets: u32,
    max_per_stage_descriptor_sampled_images: u32,
    max_per_stage_descriptor_uniform_buffers: u32,
    /// How a buffer's or an image's offset in its memory is aligned at
    /// most, and a mapping's address at least.
    min_memory_map_alignment: u32,
    /// The side of a tile the rasterizer draws in, in pixels, and the
    /// cores it shares a frame's tiles between.
    tile_size: u32,
    cores: u32,
    /// The samples a sampler may take along the longer axis
    /// (`SamplerCreateInfo.max_anisotropy`); 1 where there is no
    /// anisotropic filtering.
    max_sampler_anisotropy: u32,
    /// The nanoseconds one step of a timestamp is (CmdWriteTimestamp): a
    /// difference of two times this many nanoseconds. 0 where the device
    /// writes no timestamps.
    timestamp_period_ns: u32,
    /// The dynamic buffer descriptors one set layout may hold, each
    /// taking an offset from CmdBindDescriptorSets; 0 where the device
    /// has none (`PhysicalDeviceFeatures.dynamic_descriptors`). A field
    /// added at the end, so that none already there moves.
    max_descriptor_set_dynamic_buffers: u32 = 0,
    /// A compute workgroup: the invocations a compute function's entry may
    /// declare along each axis (`shader.computeGroup`), the invocations a
    /// group may hold in all, and the bytes its invocations may share
    /// (`shader.Groups.shared`). All zero where the device runs no compute
    /// function. Fields added at the end, so that none already there moves.
    max_compute_work_group_size: [3]u32 = .{ 0, 0, 0 },
    max_compute_work_group_invocations: u32 = 0,
    max_compute_shared_memory_size: u32 = 0,
    /// The floats a tessellation control function may write for the whole
    /// patch, which its evaluation function reads back (`shader.control`,
    /// `shader.Patch.ownValues`); 0 where the library tessellates nothing.
    /// A field added at the end, so that none already there moves.
    /// (Since 1.50.)
    max_tessellation_patch_components: u32 = 0,
};

/// The longest name a device has, its NUL included.
pub const MAX_PHYSICAL_DEVICE_NAME_SIZE = 64;

/// What a physical device is.
pub const PhysicalDeviceProperties = extern struct {
    /// The interface it has (`makeVersion`), and the library's own
    /// version and revision the same way.
    api_version: u32,
    driver_version: u32,
    vendor_id: u32,
    device_id: u32,
    device_type: PhysicalDeviceType,
    device_name: [MAX_PHYSICAL_DEVICE_NAME_SIZE]u8,
    limits: PhysicalDeviceLimits,
};

/// What a physical device does, as GetPhysicalDeviceFeatures answers.
///
/// There is a field here where a create call can refuse something: a `false`
/// is what it would answer `error_feature_not_present` to, so that a program
/// can ask instead of being told. What the library has no call for at all -
/// events, a pipeline cache, sparse memory - has no field: its absence is in
/// the jump table, not here.
///
/// The first few differ between the devices of one machine, and so do
/// `samplers` and `sampler_anisotropy` at the end - a field added later goes
/// there, where it moves nothing a program already reads. The rest are the
/// library's and the same on each.
pub const PhysicalDeviceFeatures = extern struct {
    /// A pipeline's fragment function may be one the program wrote, any Zig
    /// function. False where only the fixed forms run and a pipeline with its
    /// own is refused: `shader.fixedFragment` then says what it may do. The
    /// cores have it; the BCM2712's V3D has not.
    own_fragment_functions: bool = false,
    /// `texture.Sampling.format` is the format the fast path reads. False
    /// where the device reads a texture's format from its image instead, so
    /// a pipeline built for one format samples an image of another at full
    /// speed. Either way the picture is drawn: since 1.44 a texture whose
    /// format is not the form's goes through the run-time sampler here, a
    /// pixel at a time, rather than painting `shader.missing` as it did
    /// before. So this says what a form costs, not what it may sample.
    sampling_format: bool = false,
    /// Compute functions run on the device itself. False says they run - on
    /// the cores behind it, whichever device the pipeline was made on.
    compute_on_device: bool = false,
    /// Tessellation likewise.
    tessellation_on_device: bool = false,
    /// The fixed forms that drop a pixel rather than colour it run here -
    /// `shader.FixedKind.texture_cutout`, for cut-out textures. A device
    /// without it refuses a pipeline that asks for one.
    discarding_fragment_forms: bool = false,

    /// Points and lines, and triangles drawn as their edges or corners.
    points_and_lines: bool = false,
    depth_test: bool = false,
    stencil_test: bool = false,
    /// Any blend factors and operation, the alpha's its own.
    blending: bool = false,
    /// `PIPELINE_CREATE_DEPTH_PREPASS`.
    depth_prepass: bool = false,
    indirect_draws: bool = false,
    secondary_command_buffers: bool = false,
    several_subpasses: bool = false,
    several_color_attachments: bool = false,
    texture_arrays: bool = false,
    cube_maps: bool = false,
    textures_3d: bool = false,
    /// BC1, BC2 and BC3 are taken: unpacked to 8 bits a channel as they
    /// are copied in, or kept in their blocks where `kept_compressed`
    /// says so.
    compressed_textures: bool = false,
    /// The float formats, the same way.
    float_textures: bool = false,

    /// More than one sample a pixel, sample shading, alpha to coverage or to
    /// one. No device of this library has it.
    multisampling: bool = false,
    /// `PipelineColorBlendStateCreateInfo.logic_op_enable`.
    logic_ops: bool = false,
    several_viewports: bool = false,
    /// `PipelineRasterizationStateCreateInfo.depth_bias_enable` and
    /// CmdSetDepthBias: a triangle's depth moved before it is tested and
    /// written, for the shadow map that would shade itself and the decal
    /// that would fight the wall it is on. False where a pipeline that asks
    /// for one is refused. The cores have it since 1.34; the BCM2712's V3D
    /// since 1.47, through its depth offset packet, which takes Vulkan's
    /// three numbers as they are.
    depth_bias: bool = false,
    /// `PipelineDepthStencilStateCreateInfo.depth_bounds_test_enable`,
    /// `min_depth_bounds`, `max_depth_bounds` and CmdSetDepthBounds: a
    /// pixel is drawn only where the depth already there lies between the
    /// two, whatever the depth being drawn. False where a pipeline that
    /// asks for it is refused. The cores have it since 1.40, the V3D since
    /// 1.47: its depth bounds packet holds the tiles' test to the two.
    depth_bounds: bool = false,
    /// `PipelineRasterizationStateCreateInfo.depth_clamp_enable`: what
    /// lies past the near plane is drawn all the same, each pixel's depth
    /// held inside the viewport's `min_depth` and `max_depth`, rather than
    /// cut away - which is what a shadow volume wants. False where a
    /// pipeline that asks for it is refused. The cores have it since 1.40,
    /// the V3D since 1.47: asking for it turns its clip to the z planes
    /// off, as Vulkan's does.
    depth_clamp: bool = false,
    /// A depth attachment of `d16_unorm` that may `load` or `store`: depth
    /// outliving the pass it was drawn in, written into the image's memory
    /// as each tile is drawn and read back from it, to be copied out or
    /// made into a shadow map. False where the depth lives in the device's
    /// tiles alone and CreateRenderPass refuses both ops. The cores have it
    /// since 1.30, the V3D since 1.47, which loads and stores the tiles'
    /// depth as it does their colour - one plane an image, so `stored_both`
    /// is what a pass keeping depth and stencil together asks for.
    stored_depth: bool = false,
    /// `input_attachment` descriptors and `SubpassDescription`'s
    /// `input_attachments`: an attachment a later subpass reads pixel by
    /// pixel, out of the image's memory, which is how a deferred pass
    /// reads what the pass before it drew (`shader.Resources.input`).
    /// False where a set layout with the kind, and a subpass with input
    /// attachments, are both refused. The cores have it since 1.37; on
    /// the V3D no fragment program reads one.
    input_attachments: bool = false,
    /// Whether a render pass may keep its stencil attachment: the stencil
    /// load and store ops, a plane of the image's rows beside the depth's
    /// (`s8_uint`, `d16_unorm_s8_uint`), so a stencil outlives its pass
    /// and can be read back, written and cleared. The cores have it since
    /// 1.38, the V3D since 1.47 for a stencil of its own (`s8_uint`); a
    /// pass that keeps both planes of `d16_unorm_s8_uint` asks for
    /// `stored_both` as well, which the V3D has not.
    stored_stencil: bool = false,
    /// A depth attachment's image may be sampled where it lies: an image
    /// of `d16_unorm` with IMAGE_USAGE_SAMPLED, kept in rows as a depth
    /// attachment is, sampled through a sampler
    /// (`combined_image_sampler`, `sampled_image`), and compared with a
    /// reference at all 16 bits where the sampler asks for it
    /// (`CompareOp`). So a shadow map is drawn into an image and sampled
    /// out of it with nothing copied. The cores have it since 1.39; the
    /// V3D's texture unit keeps a texture its own way and knows no depth
    /// format, so there it is refused.
    sampled_depth: bool = false,
    /// `storage_image` descriptors, and the texel buffer kinds.
    storage_images: bool = false,
    texel_buffers: bool = false,
    /// `uniform_buffer_dynamic` and `storage_buffer_dynamic`: a buffer
    /// descriptor whose bytes start where CmdBindDescriptorSets'
    /// `dynamic_offsets` says, so one set serves draw after draw with a
    /// range of its own for each. Every device has it since 1.35; false
    /// where a set layout with either kind is refused.
    dynamic_descriptors: bool = false,
    /// The fixed forms that sample through the sampler bound beside the
    /// texture run here - `shader.FixedKind.texture_sampled`,
    /// `texture_shadow`, and since 1.49 `texture_array_sampled`,
    /// `texture_cube_sampled` and `texture_3d_sampled` - and with them
    /// everything a sampler says: the two
    /// levels round a point mixed, a bias on the level and a clamp,
    /// mirrored and bordered edges, and a comparison with a reference. A
    /// device without it refuses such a pipeline, as with a dropping form;
    /// samplers are made and written into sets on either. This one differs
    /// between the devices of a machine, though it is down here: a field is
    /// added at the end so that none already there moves.
    samplers: bool = false,
    /// A sampler's `max_anisotropy` is taken: several samples along the
    /// longer axis, up to `PhysicalDeviceLimits.max_sampler_anisotropy`.
    /// False where one sample is taken whatever a sampler asks for. This
    /// differs between the devices as well.
    sampler_anisotropy: bool = false,
    /// Occlusion queries: the samples that passed the tests counted where
    /// this device draws (`QueryType.occlusion`). The cores count in the
    /// rasterizer; the V3D since 1.47 reads the counter of its own its
    /// draws point at. False where CreateQueryPool refuses the kind.
    /// Differs between the devices of a machine.
    occlusion_queries: bool = false,
    /// `QueryType.pipeline_statistics`, the same way: what the stages were
    /// given is counted where they run.
    pipeline_statistics_queries: bool = false,
    /// `QueryType.timestamp` and CmdWriteTimestamp: the clock read as the
    /// command is played. Every device has it where the machine has
    /// timer.device.
    timestamp_queries: bool = false,
    /// `DescriptorSetLayoutBinding.immutable_samplers`: a sampler the
    /// layout holds, which a write into the set cannot change. Every set
    /// made of such a layout starts with it in the slot; a write of a
    /// combined image sampler then brings the texture alone, and a write
    /// of a sampler nothing. Every device has it since 1.49: the layout
    /// keeps the sampler, which is the library's doing and not a driver's.
    immutable_samplers: bool = false,
    /// `SamplerCreateInfo.unnormalized_coordinates`: a sample placed in
    /// texels rather than 0 to 1 across the texture.
    unnormalized_coordinates: bool = false,
    /// Each colour attachment of a subpass blended its own way:
    /// `PipelineColorBlendStateCreateInfo.attachments` is taken one by one.
    /// False where a pipeline whose attachments do not all say the same
    /// thing is refused. Every device of this library has it since 1.33: a
    /// colour attachment is drawn as a pass of its own, so each takes its
    /// own mixing as it is drawn.
    independent_blend: bool = false,
    /// A compressed image is kept in its blocks and decoded as it is
    /// sampled, nothing unpacked: `bc1_rgb_unorm_block`,
    /// `bc1_rgba_unorm_block`, `bc2_unorm_block` and `bc3_unorm_block`
    /// lie as they were copied in, an eighth to a quarter of the memory
    /// the unpacked texels take, and the four texels a sample mixes come
    /// out of the one block where they share it. False where such an
    /// image is unpacked into `r8g8b8a8_unorm` on the copy
    /// (`compressed_textures` alone), which reads the same and costs the
    /// memory. GetImageMemoryRequirements says which was done. The cores
    /// have it since 1.44; the V3D's texture unit is fed unpacked texels
    /// here, so there an image is unpacked as before.
    kept_compressed: bool = false,
    /// A float image is kept as the floats it was copied in as, nothing
    /// unpacked: `r16g16b16a16_sfloat`, `r32g32b32a32_sfloat`,
    /// `b10g11r11_ufloat_pack32` and `e5b9g9r9_ufloat_pack32` lie as they
    /// were given, so a copy out of such an image gives back what went in,
    /// and the two packed ones take half of what their texels unpacked
    /// would (4 bytes against the 8 an 8888 texel is kept spread in). A
    /// sample holds each channel inside 0 to 1 and rounds it to 8 bits, the
    /// tiles having no more, so what is drawn is the same either way; what
    /// is above 1 or below 0 is still lost there, and only on the way into
    /// the tiles. False where such an image is unpacked into
    /// `r8g8b8a8_unorm` on the copy, as it was before, and cannot be copied
    /// out of. The cores have it since 1.45; the V3D's TMU is fed unpacked
    /// texels, so there an image is unpacked as before.
    kept_floats: bool = false,
    /// Cubes in an array: an image of CUBE_COMPATIBLE whose layers are a
    /// multiple of six, a view of `ImageViewType.cube_array` over them, and
    /// the fixed form that samples one of them
    /// (`shader.FixedKind.texture_cube_array`, varyings x, y, z and which
    /// cube). False where both the view and such a pipeline are refused -
    /// Vulkan's `imageCubeArray`. The cores have it since 1.46; no QPU
    /// program of the V3D reads the fourth coordinate.
    cube_arrays: bool = false,
    /// ETC2 and EAC: `etc2_r8g8b8_unorm_block`,
    /// `etc2_r8g8b8a1_unorm_block`, `etc2_r8g8b8a8_unorm_block`,
    /// `eac_r11_unorm_block` and `eac_r11g11_unorm_block`, unpacked to 8
    /// bits a channel as they are copied in - Vulkan's
    /// `textureCompressionETC2`. No device of this library samples such a
    /// block where it lies, so this is true on every device from 1.46 and
    /// says only that the formats are taken.
    etc2_textures: bool = false,
    /// Whether a format that holds a depth **and** a stencil may keep
    /// either of them in its image's rows (`stored_depth`,
    /// `stored_stencil`): the cores write each pixel's planes where they
    /// lie in its four bytes, while a device that stores the whole of a
    /// tile buffer writes one plane's pixels one after another and so
    /// keeps only a format of that plane alone - `d16_unorm` or
    /// `s8_uint`. False on the V3D, where a load or a store op of
    /// `d16_unorm_s8_uint` is `error_feature_not_present`
    /// (CreateRenderPass). (Since 1.47.)
    stored_both: bool = false,
    /// A texel may be kept in fewer bytes than the colour it reads as: an
    /// image of `r8_unorm`, one byte a texel, read as (red, 0, 0, 1); and
    /// IMAGE_CREATE_PACKED_TEXELS on a sampled image of R8G8B8A8 or
    /// B8G8R8A8, whose texel is then the 32 bits of its word rather than
    /// the 64 it is spread over. An eighth and a half of the memory, for
    /// the spread a sample does itself. False where CreateImage refuses
    /// both the format and the flag with `error_format_not_supported`.
    /// Every device has it since 1.48: the cores keep such a texel in
    /// their own layout, the V3D's TMU reads R8 with a swizzle of its own
    /// and has never spread an 8888 texel, so the flag costs it nothing
    /// and changes nothing there. (Since 1.48.)
    small_texels: bool = false,
    /// A fragment function may write all the colour attachments of its
    /// subpass in the one call, the subpass drawn once rather than once
    /// for each of them (`shader.fragmentOutputs`,
    /// SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER): a G-buffer's three or four
    /// planes cost one pass over the vertices, one binning and one call a
    /// quad instead of as many as there are attachments. True on the
    /// cores, where the tiles hold a colour plane for each attachment of
    /// such a subpass. False on the V3D, whose fragment programs are the
    /// fixed forms and each writes the one colour: there a subpass of
    /// several is drawn once for each, as it was before, and the flag is
    /// `error_feature_not_present` (CreateRenderPass). (Since 1.51.)
    several_outputs: bool = false,
};

/// QueueFamilyProperties.queue_flags: what a family's queues do.
pub const QUEUE_GRAPHICS: u32 = 1 << 0;
pub const QUEUE_COMPUTE: u32 = 1 << 1;
pub const QUEUE_TRANSFER: u32 = 1 << 2;

/// A width, a height and a depth.
pub const Extent3D = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    depth: u32 = 1,
};

/// What GetPhysicalDeviceImageFormatProperties answers: the largest image
/// of the format, type, tiling and usage it was asked about.
pub const ImageFormatProperties = extern struct {
    /// The largest extent, in texels. `depth` is 1 but for a 3D image.
    max_extent: Extent3D = .{ .depth = 1 },
    /// The levels an image of `max_extent` may have, and the layers of an
    /// array; 1 for a shape that takes no levels or no layers.
    max_mip_levels: u32 = 0,
    max_array_layers: u32 = 0,
    /// The sample counts as bits, as Vulkan has them: always 1, one
    /// sample a pixel, there being no multisampling here.
    sample_counts: u32 = 0,
    /// The bytes an image of this shape may take, which is the largest
    /// heap's size.
    max_resource_size: u64 align(4) = 0,
};

/// A width and a height.
pub const Extent2D = extern struct {
    width: u32 = 0,
    height: u32 = 0,
};

/// What the queues of a family are and do.
pub const QueueFamilyProperties = extern struct {
    queue_flags: u32,
    /// The most queues a device has of it.
    queue_count: u32,
    timestamp_valid_bits: u32,
    /// The smallest part of an image a copy moves.
    min_image_transfer_granularity: Extent3D,
};

/// The most memory types and heaps a device has.
pub const MAX_MEMORY_TYPES = 8;
pub const MAX_MEMORY_HEAPS = 8;

/// MemoryType.property_flags: what memory of a type is.
/// The device reads and writes it as fast as any: all of a processor's is.
pub const MEMORY_PROPERTY_DEVICE_LOCAL: u32 = 1 << 0;
/// It can be mapped, and the program reads and writes it.
pub const MEMORY_PROPERTY_HOST_VISIBLE: u32 = 1 << 1;
/// What the program writes the device sees, and the other way round,
/// with nothing flushed.
pub const MEMORY_PROPERTY_HOST_COHERENT: u32 = 1 << 2;
/// It is behind the processor's data cache (MEMF_EXTERNAL): fast to read
/// back.
pub const MEMORY_PROPERTY_HOST_CACHED: u32 = 1 << 3;
/// There is nothing behind it: for an attachment a render pass clears and
/// never stores, whose pixels live in the tiles alone.
pub const MEMORY_PROPERTY_LAZILY_ALLOCATED: u32 = 1 << 4;
/// facet.library's own: a DMA engine addresses it (MEMF_DMA) - the
/// display, the board's 2D engine - so a picture in it can be shown or
/// blitted as it is.
pub const MEMORY_PROPERTY_DMA: u32 = 1 << 16;

/// MemoryHeap.flags: the heap is the device's own.
pub const MEMORY_HEAP_DEVICE_LOCAL: u32 = 1 << 0;

/// A kind of memory: what it is, and the heap it comes from.
pub const MemoryType = extern struct {
    property_flags: u32,
    heap_index: u32,
};

/// Memory memory types come from.
pub const MemoryHeap = extern struct {
    /// Its bytes, all told.
    size: u64 align(4),
    flags: u32,
    /// facet.library's own: the MEMF_* attributes of the exec regions it
    /// is, and what its memory is allocated with. 0 for the heap of the
    /// lazily allocated type, which has no memory.
    attributes: u32,
};

/// The memory of a physical device.
pub const PhysicalDeviceMemoryProperties = extern struct {
    memory_type_count: u32,
    memory_types: [MAX_MEMORY_TYPES]MemoryType,
    memory_heap_count: u32,
    memory_heaps: [MAX_MEMORY_HEAPS]MemoryHeap,
};

// --- the device -------------------------------------------------------------

/// The queues of a family a device is made with.
pub const DeviceQueueCreateInfo = extern struct {
    flags: u32 = 0,
    queue_family_index: u32 = 0,
    queue_count: u32 = 1,
    /// 0.0 to 1.0 for each queue; null for all 0.5. The priority of the
    /// queue's task, from -10 to 10 round the caller's.
    queue_priorities: ?[*]const f32 = null,
};

/// What a device is made with.
pub const DeviceCreateInfo = extern struct {
    flags: u32 = 0,
    queue_create_info_count: u32 = 0,
    queue_create_infos: ?[*]const DeviceQueueCreateInfo = null,
};

// --- memory -----------------------------------------------------------------

/// A block of device memory asked for.
pub const MemoryAllocateInfo = extern struct {
    allocation_size: u64 align(4),
    /// Into PhysicalDeviceMemoryProperties.memory_types.
    memory_type_index: u32,
};

// --- formats ----------------------------------------------------------------

/// How a texel, a pixel or a vertex's value is kept. The numbers are
/// Vulkan's; these are the formats facet.library knows.
pub const Format = enum(u32) {
    undefined = 0,
    /// 16 bits: red in the top 5, green in the middle 6, blue in the low 5.
    r5g6b5_unorm_pack16 = 4,
    /// One byte of red, as a texture: read as (red, 0, 0, 1), one byte a
    /// texel in memory, where an 8888 texel takes eight
    /// (`PhysicalDeviceFeatures.small_texels`, since 1.48).
    r8_unorm = 9,
    /// Bytes red, green, blue, alpha: 0xAABBGGRR as a 32-bit word.
    r8g8b8a8_unorm = 37,
    /// Bytes blue, green, red, alpha: 0xAARRGGBB as a 32-bit word - the
    /// order the rasterizer keeps its colours in.
    b8g8r8a8_unorm = 44,
    /// Four half-floats, as a texture: kept in 8 bits a channel, cut to 0 to 1.
    r16g16b16a16_sfloat = 97,
    /// A float, two, three or four of them.
    r32_sfloat = 100,
    r32g32_sfloat = 103,
    r32g32b32_sfloat = 106,
    r32g32b32a32_sfloat = 109,
    /// 16 bits of depth: 0 nearest.
    d16_unorm = 124,
    s8_uint = 127,
    d16_unorm_s8_uint = 128,
    /// As textures: kept in 8 bits a channel, cut to 0 to 1.
    b10g11r11_ufloat_pack32 = 122,
    e5b9g9r9_ufloat_pack32 = 123,
    /// As textures: unpacked as they come in, into 8 bits a channel.
    bc1_rgb_unorm_block = 131,
    bc1_rgba_unorm_block = 133,
    bc2_unorm_block = 135,
    bc3_unorm_block = 137,
    /// ETC2 and EAC, as textures: unpacked as they come in, into 8 bits a
    /// channel, on every device (since 1.46). A block is 4 x 4 texels in 8
    /// bytes, or 16 where there is an alpha or a second channel.
    etc2_r8g8b8_unorm_block = 147,
    etc2_r8g8b8a1_unorm_block = 149,
    etc2_r8g8b8a8_unorm_block = 151,
    /// One channel of 11 bits, read as red alone; and two, read as red and
    /// green with a blue of 0 - as Vulkan reads them, the alpha whole.
    eac_r11_unorm_block = 153,
    eac_r11g11_unorm_block = 155,
    _,
};

/// What a format does: FormatProperties' features.
pub const FORMAT_FEATURE_SAMPLED_IMAGE: u32 = 1 << 0;
/// A `storage_image` descriptor of this format may be written through by a
/// shader function (`shader.Resources.written`).
pub const FORMAT_FEATURE_STORAGE_IMAGE: u32 = 1 << 1;
/// A BufferView of this format may be read by a shader function, and with
/// `STORAGE_TEXEL_BUFFER` written through as well.
pub const FORMAT_FEATURE_UNIFORM_TEXEL_BUFFER: u32 = 1 << 3;
pub const FORMAT_FEATURE_STORAGE_TEXEL_BUFFER: u32 = 1 << 4;
pub const FORMAT_FEATURE_VERTEX_BUFFER: u32 = 1 << 6;
pub const FORMAT_FEATURE_COLOR_ATTACHMENT: u32 = 1 << 7;
pub const FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND: u32 = 1 << 8;
pub const FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT: u32 = 1 << 9;
pub const FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR: u32 = 1 << 12;
pub const FORMAT_FEATURE_TRANSFER_SRC: u32 = 1 << 14;
pub const FORMAT_FEATURE_TRANSFER_DST: u32 = 1 << 15;

/// What a format does in an image of each tiling, and in a buffer.
pub const FormatProperties = extern struct {
    linear_tiling_features: u32,
    optimal_tiling_features: u32,
    buffer_features: u32,
};

// --- buffers ----------------------------------------------------------------

/// Bytes of the device's memory, for vertices, indices, uniforms, or
/// what a copy moves.
pub const Buffer = opaque {};

/// A range of a buffer read as texels of a format, which a shader function
/// reaches through a `uniform_texel_buffer` or `storage_texel_buffer`
/// descriptor (CreateBufferView, `shader.Resources.texels`).
pub const BufferView = opaque {};

/// What a BufferView is made of.
pub const BufferViewCreateInfo = extern struct {
    buffer: *Buffer,
    /// How its bytes are read: one of the formats whose `buffer_features`
    /// say `UNIFORM_TEXEL_BUFFER` (GetPhysicalDeviceFormatProperties).
    format: Format,
    /// Where the texels start in the buffer, a multiple of the format's
    /// size, and how many bytes of them; `WHOLE_SIZE` reaches the end.
    offset: u64 align(4) = 0,
    range: u64 align(4) = WHOLE_SIZE,
};

/// BufferCreateInfo.usage: what a buffer is for.
pub const BUFFER_USAGE_TRANSFER_SRC: u32 = 1 << 0;
pub const BUFFER_USAGE_TRANSFER_DST: u32 = 1 << 1;
/// Read by a shader function as texels of a format, through a BufferView
/// (`shader.Resources.texels`).
pub const BUFFER_USAGE_UNIFORM_TEXEL_BUFFER: u32 = 1 << 2;
/// The same, and written through as well.
pub const BUFFER_USAGE_STORAGE_TEXEL_BUFFER: u32 = 1 << 3;
pub const BUFFER_USAGE_UNIFORM_BUFFER: u32 = 1 << 4;
pub const BUFFER_USAGE_STORAGE_BUFFER: u32 = 1 << 5;
pub const BUFFER_USAGE_INDEX_BUFFER: u32 = 1 << 6;
pub const BUFFER_USAGE_VERTEX_BUFFER: u32 = 1 << 7;
pub const BUFFER_USAGE_INDIRECT_BUFFER: u32 = 1 << 8;

/// Who may use a buffer or an image at once. There is one queue family,
/// so both are the same.
pub const SharingMode = enum(u32) {
    exclusive = 0,
    concurrent = 1,
    _,
};

/// What a buffer is made with.
pub const BufferCreateInfo = extern struct {
    flags: u32 = 0,
    size: u64 align(4),
    usage: u32,
    sharing_mode: SharingMode = .exclusive,
    queue_family_index_count: u32 = 0,
    queue_family_indices: ?[*]const u32 = null,
};

/// What a buffer or an image needs of the memory it is bound into: its
/// bytes, how its offset there is aligned, and the memory types it may be
/// in (bit `n` for type `n`).
pub const MemoryRequirements = extern struct {
    size: u64 align(4),
    alignment: u64 align(4),
    memory_type_bits: u32,
};

// --- images -----------------------------------------------------------------

/// A picture of the device's: a texture, an attachment drawn into, or
/// what a copy moves.
pub const Image = opaque {};
/// An image as a pipeline or a framebuffer sees it.
pub const ImageView = opaque {};

/// How many dimensions an image has. facet.library's have two.
pub const ImageType = enum(u32) {
    @"1d" = 0,
    @"2d" = 1,
    @"3d" = 2,
    _,
};

/// How an image's texels are laid out in its memory.
pub const ImageTiling = enum(u32) {
    /// As the device reads them best, which is not the program's to know:
    /// a texture's in blocks of 4 x 4 texels, an 8888 one's spread to 64
    /// bits each (sdk.facet.texture); an attachment's in rows, as linear.
    optimal = 0,
    /// Row after row, `SubresourceLayout.row_pitch` bytes apart.
    linear = 1,
    _,
};

/// What an image is laid out for, as work on it goes from one use to the
/// next. facet.library's layouts change nothing in memory; a barrier that
/// changes one orders the work round it all the same.
pub const ImageLayout = enum(u32) {
    undefined = 0,
    general = 1,
    color_attachment_optimal = 2,
    depth_stencil_attachment_optimal = 3,
    shader_read_only_optimal = 5,
    transfer_src_optimal = 6,
    transfer_dst_optimal = 7,
    preinitialized = 8,
    present_src = 1000001002,
    _,
};

/// ImageCreateInfo.usage: what an image is for.
pub const IMAGE_USAGE_TRANSFER_SRC: u32 = 1 << 0;
pub const IMAGE_USAGE_TRANSFER_DST: u32 = 1 << 1;
pub const IMAGE_USAGE_SAMPLED: u32 = 1 << 2;
/// Written through by a shader function, as a `storage_image` descriptor
/// (`PhysicalDeviceFeatures.storage_images`). It is kept the way a sampled
/// image is, so an image may be both.
pub const IMAGE_USAGE_STORAGE: u32 = 1 << 3;
pub const IMAGE_USAGE_COLOR_ATTACHMENT: u32 = 1 << 4;
pub const IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT: u32 = 1 << 5;
/// Its pixels live in the tiles alone: memory of the lazily allocated
/// type will do.
pub const IMAGE_USAGE_TRANSIENT_ATTACHMENT: u32 = 1 << 6;
/// Read pixel by pixel by a fragment function of a later subpass, as an
/// `input_attachment` descriptor (`shader.Attachment`, since 1.37). Rows
/// in memory, so not with SAMPLED, STORAGE or TRANSIENT, and not a depth
/// attachment's.
pub const IMAGE_USAGE_INPUT_ATTACHMENT: u32 = 1 << 7;

/// What an image is made with.
/// ImageCreateInfo.flags: a view of type cube may be made of it.
pub const IMAGE_CREATE_CUBE_COMPATIBLE: u32 = 1 << 4;

/// facet.library's own, in `ImageCreateInfo.flags`: a sampled image of
/// R8G8B8A8 or B8G8R8A8 keeps each texel in the 32 bits of its word rather
/// than spread over 64 (`texture.Format.argb8888`) - half the memory and
/// half the cache it fills, for the spread a sample then does itself. A
/// fixed form reads it at full speed where it was compiled for
/// `argb8888`; one compiled for `rgba8888` draws it through the run-time
/// sampler, a pixel at a time, as it does any other format it was not
/// built for. Refused where `PhysicalDeviceFeatures.small_texels` is
/// false, and on an image that is neither sampled nor a storage image.
/// (Since 1.48.)
pub const IMAGE_CREATE_PACKED_TEXELS: u32 = 1 << 31;

/// facet.library's own, in `SubpassDescription.flags`: the subpass's
/// colour attachments are drawn **together**, in one pass over the tiles,
/// by a fragment function that writes all of them in the one call
/// (`shader.fragmentOutputs`, `shader.Fragments.colorsOf`). Without it a
/// subpass of several colour attachments is drawn once for each, every
/// command of the pass played again with `shader.Resources.output` saying
/// which - the vertices worked and the triangles binned over again - and
/// a fragment function writing the one colour.
///
/// Refused with `error_feature_not_present` where
/// `PhysicalDeviceFeatures.several_outputs` is false, and with
/// `error_invalid_shader_nv` for a pipeline of such a subpass whose
/// fragment entry does not write exactly the subpass's colour
/// attachments. (Since 1.51.)
pub const SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER: u32 = 1 << 31;

pub const ImageCreateInfo = extern struct {
    flags: u32 = 0,
    image_type: ImageType = .@"2d",
    format: Format,
    extent: Extent3D,
    mip_levels: u32 = 1,
    array_layers: u32 = 1,
    /// Samples a pixel: 1.
    samples: u32 = 1,
    tiling: ImageTiling = .optimal,
    usage: u32,
    sharing_mode: SharingMode = .exclusive,
    queue_family_index_count: u32 = 0,
    queue_family_indices: ?[*]const u32 = null,
    initial_layout: ImageLayout = .undefined,
};

/// ImageSubresource.aspect_mask and ImageSubresourceRange.aspect_mask:
/// which of an image's parts.
pub const IMAGE_ASPECT_COLOR: u32 = 1 << 0;
pub const IMAGE_ASPECT_DEPTH: u32 = 1 << 1;
pub const IMAGE_ASPECT_STENCIL: u32 = 1 << 2;

/// One level of one layer of an image.
pub const ImageSubresource = extern struct {
    aspect_mask: u32 = IMAGE_ASPECT_COLOR,
    mip_level: u32 = 0,
    array_layer: u32 = 0,
};

/// Where a level of a linear image is in its memory, and how its rows
/// lie.
pub const SubresourceLayout = extern struct {
    offset: u64 align(4),
    size: u64 align(4),
    row_pitch: u64 align(4),
    array_pitch: u64 align(4),
    depth_pitch: u64 align(4),
};

/// How many levels or layers: all from the first one given on.
pub const REMAINING: u32 = ~@as(u32, 0);

/// The levels and layers of an image a view or a barrier takes.
pub const ImageSubresourceRange = extern struct {
    aspect_mask: u32 = IMAGE_ASPECT_COLOR,
    base_mip_level: u32 = 0,
    level_count: u32 = REMAINING,
    base_array_layer: u32 = 0,
    layer_count: u32 = REMAINING,
};

/// What a view of an image is.
pub const ImageViewType = enum(u32) {
    @"1d" = 0,
    @"2d" = 1,
    @"3d" = 2,
    cube = 3,
    @"2d_array" = 5,
    /// Cubes one after another, six layers to each: the view's layers are a
    /// multiple of six and its first a multiple of six, for
    /// `shader.FixedKind.texture_cube_array`. (Since 1.46.)
    cube_array = 6,
    _,
};

/// Where a view's channel comes from. facet.library's views take each
/// from itself.
pub const ComponentSwizzle = enum(u32) {
    identity = 0,
    zero = 1,
    one = 2,
    r = 3,
    g = 4,
    b = 5,
    a = 6,
    _,
};

pub const ComponentMapping = extern struct {
    r: ComponentSwizzle = .identity,
    g: ComponentSwizzle = .identity,
    b: ComponentSwizzle = .identity,
    a: ComponentSwizzle = .identity,
};

/// A place in an image.
pub const Offset3D = extern struct {
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
};

/// One level of the layers of an image a copy takes.
pub const ImageSubresourceLayers = extern struct {
    aspect_mask: u32 = IMAGE_ASPECT_COLOR,
    mip_level: u32 = 0,
    base_array_layer: u32 = 0,
    layer_count: u32 = 1,
};

/// A rectangle of texels copied between a buffer and an image. In the
/// buffer the texels are in rows, in the image's format: `buffer_row_length`
/// texels from one row to the next (0: the rectangle's width).
pub const BufferImageCopy = extern struct {
    buffer_offset: u64 align(4) = 0,
    buffer_row_length: u32 = 0,
    buffer_image_height: u32 = 0,
    image_subresource: ImageSubresourceLayers = .{},
    image_offset: Offset3D = .{},
    image_extent: Extent3D,
};

/// A rectangle of texels copied from one image to another, as they are.
pub const ImageCopy = extern struct {
    src_subresource: ImageSubresourceLayers = .{},
    src_offset: Offset3D = .{},
    dst_subresource: ImageSubresourceLayers = .{},
    dst_offset: Offset3D = .{},
    extent: Extent3D,
};

/// A rectangle of an image drawn over one of another, its size and direction
/// as the corners say.
pub const ImageBlit = extern struct {
    src_subresource: ImageSubresourceLayers = .{},
    src_offsets: [2]Offset3D = .{ .{}, .{} },
    dst_subresource: ImageSubresourceLayers = .{},
    dst_offsets: [2]Offset3D = .{ .{}, .{} },
};

/// How CmdBlitImage reads between texels.
pub const Filter = enum(u32) {
    nearest = 0,
    linear = 1,
    _,
};

/// What of a render pass's attachments CmdClearAttachments clears, and to what.
pub const ClearAttachment = extern struct {
    aspect_mask: u32 = IMAGE_ASPECT_COLOR,
    color_attachment: u32 = 0,
    clear_value: ClearValue,
};

/// Where CmdClearAttachments clears.
pub const ClearRect = extern struct {
    rect: Rect2D,
    base_array_layer: u32 = 0,
    layer_count: u32 = 1,
};

/// What a view of an image is made with.
pub const ImageViewCreateInfo = extern struct {
    flags: u32 = 0,
    image: *Image,
    view_type: ImageViewType = .@"2d",
    /// The image's own.
    format: Format,
    components: ComponentMapping = .{},
    subresource_range: ImageSubresourceRange = .{},
};

// --- samplers ----------------------------------------------------------------

/// How a texture is sampled: a draw binds one beside the image, as a
/// combined image sampler or beside a sampled image, and the sampling reads
/// it (CreateSampler, `texture.Sampler`).
pub const Sampler = opaque {};

/// Whether the two levels a point falls between are mixed, or the nearer
/// one read alone.
pub const SamplerMipmapMode = enum(u32) {
    nearest = 0,
    linear = 1,
    _,
};

/// What a coordinate past the texture's edge reads.
pub const SamplerAddressMode = enum(u32) {
    repeat = 0,
    mirrored_repeat = 1,
    clamp_to_edge = 2,
    clamp_to_border = 3,
    /// The texture turned round once below 0 and held at its edge past the
    /// far side: Vulkan's MIRROR_CLAMP_TO_EDGE (since 1.49).
    mirror_clamp_to_edge = 4,
    _,
};

/// What `clamp_to_border` reads past the edge. The int kinds are the float
/// kinds here: a texture's texels are read as 0 to 1 whatever their format.
pub const BorderColor = enum(u32) {
    float_transparent_black = 0,
    int_transparent_black = 1,
    float_opaque_black = 2,
    int_opaque_black = 3,
    float_opaque_white = 4,
    int_opaque_white = 5,
    _,
};

/// What a sampler is made with. Vulkan's structure, with the fields the
/// library has no sampling for left out of it: there is no
/// `mipLodBias`-less path, so a bias of 0 is what the fixed forms do.
pub const SamplerCreateInfo = extern struct {
    flags: u32 = 0,
    /// Where a texel covers more than a pixel, and where it covers less.
    mag_filter: Filter = .linear,
    min_filter: Filter = .linear,
    mipmap_mode: SamplerMipmapMode = .nearest,
    /// Past the edges: across, down, and through a 3D texture.
    address_mode_u: SamplerAddressMode = .repeat,
    address_mode_v: SamplerAddressMode = .repeat,
    address_mode_w: SamplerAddressMode = .repeat,
    /// Added to the level a sample falls on.
    mip_lod_bias: f32 = 0,
    /// Several samples along the longer axis, up to `max_anisotropy`:
    /// `PhysicalDeviceFeatures.sampler_anisotropy` says where that happens,
    /// and `PhysicalDeviceLimits.max_sampler_anisotropy` how many at most.
    anisotropy_enable: bool = false,
    max_anisotropy: f32 = 1,
    /// A shadow sample: what was read compared with the reference the
    /// fragment function carries, rather than read as a colour. The red
    /// channel, 0 to 1, is what is compared.
    compare_enable: bool = false,
    compare_op: CompareOp = .never,
    /// The levels a sample is held to, over and above those the texture has.
    min_lod: f32 = 0,
    /// `texture.lod_unclamped` (1000) for the texture's own last level.
    max_lod: f32 = 0,
    border_color: BorderColor = .float_transparent_black,
    /// Coordinates in texels rather than 0 to 1: not here
    /// (`error_feature_not_present`).
    unnormalized_coordinates: bool = false,
};

// --- query pools -------------------------------------------------------------

/// Where what a frame's work came to is counted: samples that passed the
/// tests, what each stage was given, or the clock as a command was played
/// (CreateQueryPool).
pub const QueryPool = opaque {};

/// What a pool's queries count.
pub const QueryType = enum(u32) {
    /// Samples that passed the depth and stencil tests between the query's
    /// begin and its end: what says whether anything of a shape is seen.
    occlusion = 0,
    /// What the stages were given and what they handed on, one value for
    /// each of the `QUERY_PIPELINE_STATISTIC_` bits asked for, in that
    /// order.
    pipeline_statistics = 1,
    /// The clock as the command was played (CmdWriteTimestamp), in the
    /// units `PhysicalDeviceLimits.timestamp_period_ns` gives.
    timestamp = 2,
    _,
};

/// QueryPoolCreateInfo.pipeline_statistics: what a statistics query counts.
/// A value is written for each of these that is asked for, lowest bit
/// first.
pub const QUERY_PIPELINE_STATISTIC_INPUT_ASSEMBLY_VERTICES: u32 = 1 << 0;
pub const QUERY_PIPELINE_STATISTIC_INPUT_ASSEMBLY_PRIMITIVES: u32 = 1 << 1;
pub const QUERY_PIPELINE_STATISTIC_VERTEX_SHADER_INVOCATIONS: u32 = 1 << 2;
/// Geometry shaders: there is no such stage here, and either of these is
/// refused.
pub const QUERY_PIPELINE_STATISTIC_GEOMETRY_SHADER_INVOCATIONS: u32 = 1 << 3;
pub const QUERY_PIPELINE_STATISTIC_GEOMETRY_SHADER_PRIMITIVES: u32 = 1 << 4;
/// Triangles the rasterizer was given, and those it drew: one that was
/// wholly outside the view, had no area or faced away is counted in the
/// first and not the second.
pub const QUERY_PIPELINE_STATISTIC_CLIPPING_INVOCATIONS: u32 = 1 << 5;
pub const QUERY_PIPELINE_STATISTIC_CLIPPING_PRIMITIVES: u32 = 1 << 6;
/// Pixels a fragment function was called for: quads of 2 x 2, all four
/// whether covered or not, as a GPU shades them.
pub const QUERY_PIPELINE_STATISTIC_FRAGMENT_SHADER_INVOCATIONS: u32 = 1 << 7;
pub const QUERY_PIPELINE_STATISTIC_TESSELLATION_CONTROL_SHADER_PATCHES: u32 = 1 << 8;
pub const QUERY_PIPELINE_STATISTIC_TESSELLATION_EVALUATION_SHADER_INVOCATIONS: u32 = 1 << 9;
/// Invocations of a compute function: the dispatch's workgroups times the
/// invocations each holds (`shader.Groups.invocations`), which for a
/// `shader.compute` entry is one for each workgroup, since that is what a
/// compute function is called with here (`shader.Groups`).
pub const QUERY_PIPELINE_STATISTIC_COMPUTE_SHADER_INVOCATIONS: u32 = 1 << 10;

/// The statistics there are, which is what CreateQueryPool takes.
pub const QUERY_PIPELINE_STATISTIC_ALL: u32 = 0x7FF;

pub const QueryPoolCreateInfo = extern struct {
    flags: u32 = 0,
    query_type: QueryType,
    query_count: u32,
    /// With `pipeline_statistics`, the `QUERY_PIPELINE_STATISTIC_` bits it
    /// counts; 0 for the other kinds.
    pipeline_statistics: u32 = 0,
};

/// CmdBeginQuery's flags: every sample counted, not merely whether any
/// passed. The library counts them all either way.
pub const QUERY_CONTROL_PRECISE: u32 = 1 << 0;

/// GetQueryPoolResults' and CmdCopyQueryPoolResults' flags.
/// Values of 64 bits rather than 32.
pub const QUERY_RESULT_64: u32 = 1 << 0;
/// Wait for the queue's work to be done rather than answer `not_ready`.
pub const QUERY_RESULT_WAIT: u32 = 1 << 1;
/// A value after each query's own, 0 where it is not available yet.
pub const QUERY_RESULT_WITH_AVAILABILITY: u32 = 1 << 2;
/// What a query has counted so far, for one that is not available.
pub const QUERY_RESULT_PARTIAL: u32 = 1 << 3;

// --- command buffers --------------------------------------------------------

/// Where a device's command buffers come from.
pub const CommandPool = opaque {};
/// Commands recorded, to be played by a queue.
pub const CommandBuffer = opaque {};

/// CommandPoolCreateInfo.flags.
/// Its buffers are short-lived: recorded, submitted once, reset.
pub const COMMAND_POOL_CREATE_TRANSIENT: u32 = 1 << 0;
/// Each of its buffers may be reset on its own.
pub const COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER: u32 = 1 << 1;

/// What a command pool is made with.
pub const CommandPoolCreateInfo = extern struct {
    flags: u32 = 0,
    queue_family_index: u32 = 0,
};

/// Whether a command buffer is submitted itself, or called from another.
/// facet.library's are primary.
pub const CommandBufferLevel = enum(u32) {
    primary = 0,
    secondary = 1,
    _,
};

/// The command buffers asked of a pool.
pub const CommandBufferAllocateInfo = extern struct {
    command_pool: *CommandPool,
    level: CommandBufferLevel = .primary,
    command_buffer_count: u32 = 1,
};

/// CommandBufferBeginInfo.flags.
/// It is submitted once, then reset or recorded again.
pub const COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT: u32 = 1 << 0;
/// A secondary command buffer played wholly inside a render pass. Taken and
/// not looked at: what it draws goes into the pass it is played in.
pub const COMMAND_BUFFER_USAGE_RENDER_PASS_CONTINUE: u32 = 1 << 1;
/// It may be submitted again while a submission of it is still pending.
pub const COMMAND_BUFFER_USAGE_SIMULTANEOUS_USE: u32 = 1 << 2;

/// The pass a secondary command buffer is played in. Taken and not looked at.
pub const CommandBufferInheritanceInfo = extern struct {
    render_pass: ?*RenderPass = null,
    subpass: u32 = 0,
    framebuffer: ?*Framebuffer = null,
};

/// How a command buffer is to be recorded.
pub const CommandBufferBeginInfo = extern struct {
    flags: u32 = 0,
    inheritance_info: ?*const CommandBufferInheritanceInfo = null,
};

/// What CmdDrawIndirect reads from its buffer for each draw: CmdDraw's numbers.
pub const DrawIndirectCommand = extern struct {
    vertex_count: u32,
    instance_count: u32,
    first_vertex: u32,
    first_instance: u32,
};

/// What CmdDrawIndexedIndirect reads: CmdDrawIndexed's numbers.
pub const DrawIndexedIndirectCommand = extern struct {
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    vertex_offset: i32,
    first_instance: u32,
};

/// ResetCommandBuffer's and ResetCommandPool's flags: the memory of the
/// recording given back, not kept for the next.
pub const COMMAND_BUFFER_RESET_RELEASE_RESOURCES: u32 = 1 << 0;

/// The stages of the work a command does, in the order they run: where a
/// barrier or a semaphore's wait takes effect.
pub const PIPELINE_STAGE_TOP_OF_PIPE: u32 = 1 << 0;
pub const PIPELINE_STAGE_VERTEX_INPUT: u32 = 1 << 2;
pub const PIPELINE_STAGE_VERTEX_SHADER: u32 = 1 << 3;
pub const PIPELINE_STAGE_FRAGMENT_SHADER: u32 = 1 << 7;
pub const PIPELINE_STAGE_EARLY_FRAGMENT_TESTS: u32 = 1 << 8;
pub const PIPELINE_STAGE_LATE_FRAGMENT_TESTS: u32 = 1 << 9;
pub const PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT: u32 = 1 << 10;
pub const PIPELINE_STAGE_TRANSFER: u32 = 1 << 12;
pub const PIPELINE_STAGE_BOTTOM_OF_PIPE: u32 = 1 << 13;
pub const PIPELINE_STAGE_HOST: u32 = 1 << 14;
pub const PIPELINE_STAGE_ALL_GRAPHICS: u32 = 1 << 15;
pub const PIPELINE_STAGE_ALL_COMMANDS: u32 = 1 << 16;

/// What work reads or writes, on either side of a barrier.
pub const ACCESS_INDEX_READ: u32 = 1 << 1;
pub const ACCESS_VERTEX_ATTRIBUTE_READ: u32 = 1 << 2;
pub const ACCESS_UNIFORM_READ: u32 = 1 << 3;
pub const ACCESS_SHADER_READ: u32 = 1 << 5;
pub const ACCESS_COLOR_ATTACHMENT_READ: u32 = 1 << 7;
pub const ACCESS_COLOR_ATTACHMENT_WRITE: u32 = 1 << 8;
pub const ACCESS_DEPTH_STENCIL_ATTACHMENT_READ: u32 = 1 << 9;
pub const ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE: u32 = 1 << 10;
pub const ACCESS_TRANSFER_READ: u32 = 1 << 11;
pub const ACCESS_TRANSFER_WRITE: u32 = 1 << 12;
pub const ACCESS_HOST_READ: u32 = 1 << 13;
pub const ACCESS_HOST_WRITE: u32 = 1 << 14;
pub const ACCESS_MEMORY_READ: u32 = 1 << 15;
pub const ACCESS_MEMORY_WRITE: u32 = 1 << 16;

/// A barrier's queue family that is none: nothing changes hands.
pub const QUEUE_FAMILY_IGNORED: u32 = ~@as(u32, 0);

/// What work before a barrier wrote that work after it reads.
pub const MemoryBarrier = extern struct {
    src_access_mask: u32 = 0,
    dst_access_mask: u32 = 0,
};

/// The same for part of a buffer.
pub const BufferMemoryBarrier = extern struct {
    src_access_mask: u32 = 0,
    dst_access_mask: u32 = 0,
    src_queue_family_index: u32 = QUEUE_FAMILY_IGNORED,
    dst_queue_family_index: u32 = QUEUE_FAMILY_IGNORED,
    buffer: *Buffer,
    offset: u64 align(4) = 0,
    size: u64 align(4) = WHOLE_SIZE,
};

/// The same for part of an image, and the layout it goes from and to.
pub const ImageMemoryBarrier = extern struct {
    src_access_mask: u32 = 0,
    dst_access_mask: u32 = 0,
    old_layout: ImageLayout = .undefined,
    new_layout: ImageLayout = .undefined,
    src_queue_family_index: u32 = QUEUE_FAMILY_IGNORED,
    dst_queue_family_index: u32 = QUEUE_FAMILY_IGNORED,
    image: *Image,
    subresource_range: ImageSubresourceRange = .{},
};

/// Bytes copied from one buffer to another.
pub const BufferCopy = extern struct {
    src_offset: u64 align(4) = 0,
    dst_offset: u64 align(4) = 0,
    size: u64 align(4),
};

// --- synchronization --------------------------------------------------------

/// What a queue signals when a submission is done, for the program to
/// wait on.
pub const Fence = opaque {};
/// What one submission signals and another waits for, on a queue.
pub const Semaphore = opaque {};

/// FenceCreateInfo.flags: the fence starts signalled.
pub const FENCE_CREATE_SIGNALED: u32 = 1 << 0;

/// What a fence is made with.
pub const FenceCreateInfo = extern struct {
    flags: u32 = 0,
};

/// What a semaphore is made with.
pub const SemaphoreCreateInfo = extern struct {
    flags: u32 = 0,
};

/// WaitForFences' time limit for none.
pub const WAIT_FOREVER_NS: u64 = ~@as(u64, 0);

/// One batch of work for a queue: the semaphores it waits for first, the
/// command buffers it plays, in order, and the semaphores it signals
/// when they are done.
pub const SubmitInfo = extern struct {
    wait_semaphore_count: u32 = 0,
    wait_semaphores: ?[*]const *Semaphore = null,
    /// For each semaphore waited for, the stages that wait
    /// (PIPELINE_STAGE_*): facet.library waits before all of them.
    wait_dst_stage_mask: ?[*]const u32 = null,
    command_buffer_count: u32 = 0,
    command_buffers: ?[*]const *CommandBuffer = null,
    signal_semaphore_count: u32 = 0,
    signal_semaphores: ?[*]const *Semaphore = null,
};

// --- render passes ----------------------------------------------------------

/// The attachments a pass draws into, what each starts with and what is
/// kept of it.
pub const RenderPass = opaque {};
/// The image views a render pass draws into.
pub const Framebuffer = opaque {};

/// What an attachment holds as a pass starts: what it held, `clear`'s
/// value, or nothing anyone may count on.
pub const AttachmentLoadOp = enum(u32) {
    load = 0,
    clear = 1,
    dont_care = 2,
    _,
};

/// What is kept of an attachment as a pass ends.
pub const AttachmentStoreOp = enum(u32) {
    store = 0,
    dont_care = 1,
    _,
};

/// One attachment of a render pass.
pub const AttachmentDescription = extern struct {
    flags: u32 = 0,
    format: Format,
    /// Samples a pixel: 1.
    samples: u32 = 1,
    load_op: AttachmentLoadOp = .dont_care,
    store_op: AttachmentStoreOp = .dont_care,
    stencil_load_op: AttachmentLoadOp = .dont_care,
    stencil_store_op: AttachmentStoreOp = .dont_care,
    initial_layout: ImageLayout = .undefined,
    final_layout: ImageLayout,
};

/// AttachmentReference.attachment for none.
pub const ATTACHMENT_UNUSED: u32 = ~@as(u32, 0);

/// An attachment as a subpass uses it.
pub const AttachmentReference = extern struct {
    /// Into RenderPassCreateInfo.attachments, or ATTACHMENT_UNUSED.
    attachment: u32,
    layout: ImageLayout,
};

/// What a pipeline is bound for.
pub const PipelineBindPoint = enum(u32) {
    graphics = 0,
    compute = 1,
    _,
};

/// A subpass: the attachments its draws read and write.
pub const SubpassDescription = extern struct {
    flags: u32 = 0,
    pipeline_bind_point: PipelineBindPoint = .graphics,
    input_attachment_count: u32 = 0,
    input_attachments: ?[*]const AttachmentReference = null,
    color_attachment_count: u32 = 0,
    color_attachments: ?[*]const AttachmentReference = null,
    resolve_attachments: ?[*]const AttachmentReference = null,
    depth_stencil_attachment: ?*const AttachmentReference = null,
    preserve_attachment_count: u32 = 0,
    preserve_attachments: ?[*]const u32 = null,
};

/// SubpassDependency's subpass for the work outside the pass.
pub const SUBPASS_EXTERNAL: u32 = ~@as(u32, 0);

/// What one subpass's work waits for of another's, or of the work
/// outside the pass.
pub const SubpassDependency = extern struct {
    src_subpass: u32,
    dst_subpass: u32,
    src_stage_mask: u32,
    dst_stage_mask: u32,
    src_access_mask: u32 = 0,
    dst_access_mask: u32 = 0,
    dependency_flags: u32 = 0,
};

/// What a render pass is made with.
pub const RenderPassCreateInfo = extern struct {
    flags: u32 = 0,
    attachment_count: u32 = 0,
    attachments: ?[*]const AttachmentDescription = null,
    subpass_count: u32,
    subpasses: [*]const SubpassDescription,
    dependency_count: u32 = 0,
    dependencies: ?[*]const SubpassDependency = null,
};

/// What a framebuffer is made with: a view for each of the render pass's
/// attachments, in their order.
pub const FramebufferCreateInfo = extern struct {
    flags: u32 = 0,
    render_pass: *RenderPass,
    attachment_count: u32,
    attachments: [*]const *ImageView,
    width: u32,
    height: u32,
    layers: u32 = 1,
};

/// A place on a surface.
pub const Offset2D = extern struct {
    x: i32 = 0,
    y: i32 = 0,
};

/// A rectangle of a surface.
pub const Rect2D = extern struct {
    offset: Offset2D = .{},
    extent: Extent2D,
};

/// A colour an attachment is cleared to: red, green, blue and alpha, 0 to
/// 1, as floats for a UNORM format.
pub const ClearColorValue = extern union {
    float32: [4]f32,
    int32: [4]i32,
    uint32: [4]u32,
};

/// The depth a depth attachment is cleared to, 0 to 1.
pub const ClearDepthStencilValue = extern struct {
    depth: f32,
    stencil: u32 = 0,
};

/// What an attachment is cleared to: `color` for a colour attachment,
/// `depth_stencil` for a depth one.
pub const ClearValue = extern union {
    color: ClearColorValue,
    depth_stencil: ClearDepthStencilValue,
};

/// What a render pass begins with: its framebuffer, the rectangle drawn
/// in, and a clear value for each attachment, in their order, that is
/// cleared.
pub const RenderPassBeginInfo = extern struct {
    render_pass: *RenderPass,
    framebuffer: *Framebuffer,
    render_area: Rect2D,
    clear_value_count: u32 = 0,
    clear_values: ?[*]const ClearValue = null,
};

/// Where a subpass's commands are: recorded in line, in facet.library.
pub const SubpassContents = enum(u32) {
    @"inline" = 0,
    secondary_command_buffers = 1,
    _,
};

// --- shaders and pipelines --------------------------------------------------

/// A vertex function and a fragment function, or more (`shader.Code`).
pub const ShaderModule = opaque {};
/// The descriptor sets and push constants a pipeline's shaders read.
pub const PipelineLayout = opaque {};
/// A way of drawing: its shaders and its state, settled as it is made.
pub const Pipeline = opaque {};
/// What pipelines are made faster with the next time: facet.library has
/// none; CreateGraphicsPipelines takes null.
pub const PipelineCache = opaque {};

/// The stages a shader runs at: PipelineShaderStageCreateInfo.stage,
/// shader.Entry.stage, and the stage masks of layouts and push constants.
pub const SHADER_STAGE_VERTEX: u32 = 0x01;
pub const SHADER_STAGE_TESSELLATION_CONTROL: u32 = 0x02;
pub const SHADER_STAGE_TESSELLATION_EVALUATION: u32 = 0x04;
pub const SHADER_STAGE_FRAGMENT: u32 = 0x10;
pub const SHADER_STAGE_COMPUTE: u32 = 0x20;
pub const SHADER_STAGE_ALL_GRAPHICS: u32 = 0x1F;

/// What a shader module is made with.
pub const ShaderModuleCreateInfo = extern struct {
    flags: u32 = 0,
    /// The bytes of `code`: @sizeOf(shader.Code).
    code_size: usize = @sizeOf(shader.Code),
    /// A `shader.Code`. SPIR-V is not something facet.library reads.
    code: *const anyopaque,
};

/// A shader stage of a pipeline: the module's function for it.
pub const PipelineShaderStageCreateInfo = extern struct {
    flags: u32 = 0,
    /// SHADER_STAGE_VERTEX or SHADER_STAGE_FRAGMENT.
    stage: u32,
    module: *ShaderModule,
    /// The entry's name in the module.
    name: [*:0]const u8 = "main",
    specialization_info: ?*const anyopaque = null,
};

/// Whether a binding's data goes a vertex at a time or an instance.
pub const VertexInputRate = enum(u32) {
    vertex = 0,
    instance = 1,
    _,
};

/// A vertex buffer binding: the bytes from one vertex's data to the
/// next's.
pub const VertexInputBindingDescription = extern struct {
    binding: u32,
    stride: u32,
    input_rate: VertexInputRate = .vertex,
};

/// An attribute: what a location of the vertex function's input is read
/// from - a binding, an offset in its vertex's data, and a format:
/// r32_sfloat to r32g32b32a32_sfloat, r8g8b8a8_unorm or b8g8r8a8_unorm.
pub const VertexInputAttributeDescription = extern struct {
    location: u32,
    binding: u32,
    format: Format,
    offset: u32 = 0,
};

/// A pipeline's vertex buffers and attributes.
pub const PipelineVertexInputStateCreateInfo = extern struct {
    flags: u32 = 0,
    vertex_binding_description_count: u32 = 0,
    vertex_binding_descriptions: ?[*]const VertexInputBindingDescription = null,
    vertex_attribute_description_count: u32 = 0,
    vertex_attribute_descriptions: ?[*]const VertexInputAttributeDescription = null,
};

/// How the vertices make triangles.
pub const PrimitiveTopology = enum(u32) {
    point_list = 0,
    line_list = 1,
    line_strip = 2,
    triangle_list = 3,
    triangle_strip = 4,
    triangle_fan = 5,
    /// Patches of PipelineTessellationStateCreateInfo.patch_control_points
    /// vertices each, for a pipeline that tessellates.
    patch_list = 10,
    _,
};

pub const PipelineInputAssemblyStateCreateInfo = extern struct {
    flags: u32 = 0,
    topology: PrimitiveTopology = .triangle_list,
    primitive_restart_enable: bool = false,
};

/// Where clip space lands on the framebuffer: x = -1 is the left, y = -1
/// the top, and z from 0 to 1 the depths from `min_depth` to `max_depth`.
pub const Viewport = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32,
    height: f32,
    min_depth: f32 = 0,
    max_depth: f32 = 1,
};

/// A pipeline's viewport and scissor: one each, here or set by commands
/// (DynamicState).
pub const PipelineViewportStateCreateInfo = extern struct {
    flags: u32 = 0,
    viewport_count: u32 = 1,
    viewports: ?[*]const Viewport = null,
    scissor_count: u32 = 1,
    scissors: ?[*]const Rect2D = null,
};

/// How a triangle is drawn: filled.
pub const PolygonMode = enum(u32) {
    fill = 0,
    line = 1,
    point = 2,
    _,
};

/// PipelineRasterizationStateCreateInfo.cull_mode: which triangles are
/// not drawn.
pub const CULL_MODE_NONE: u32 = 0;
pub const CULL_MODE_FRONT: u32 = 1;
pub const CULL_MODE_BACK: u32 = 2;
pub const CULL_MODE_FRONT_AND_BACK: u32 = 3;

/// Which way round a triangle's vertices run on the framebuffer, y down,
/// when it faces the eye.
pub const FrontFace = enum(u32) {
    counter_clockwise = 0,
    clockwise = 1,
    _,
};

pub const PipelineRasterizationStateCreateInfo = extern struct {
    flags: u32 = 0,
    depth_clamp_enable: bool = false,
    rasterizer_discard_enable: bool = false,
    polygon_mode: PolygonMode = .fill,
    cull_mode: u32 = CULL_MODE_NONE,
    front_face: FrontFace = .counter_clockwise,
    /// A triangle's depth moved before it is tested and written, by
    /// `depth_bias_slope_factor` times its steepest slope and
    /// `depth_bias_constant_factor` times the smallest difference the
    /// depth attachment holds, held inside `depth_bias_clamp` where that
    /// is not 0 - a positive one the most it may be moved, a negative one
    /// the least. Since 1.34, on a device whose
    /// `PhysicalDeviceFeatures.depth_bias` is true; what
    /// `DynamicState.depth_bias` leaves to CmdSetDepthBias is the three
    /// numbers, never whether there is a bias at all.
    depth_bias_enable: bool = false,
    depth_bias_constant_factor: f32 = 0,
    depth_bias_clamp: f32 = 0,
    depth_bias_slope_factor: f32 = 0,
    line_width: f32 = 1,
};

pub const PipelineMultisampleStateCreateInfo = extern struct {
    flags: u32 = 0,
    rasterization_samples: u32 = 1,
    sample_shading_enable: bool = false,
    min_sample_shading: f32 = 0,
    sample_mask: ?[*]const u32 = null,
    alpha_to_coverage_enable: bool = false,
    alpha_to_one_enable: bool = false,
};

/// How a depth is compared with the one kept: the pixel passes when it is
/// so to it.
pub const CompareOp = enum(u32) {
    never = 0,
    less = 1,
    equal = 2,
    less_or_equal = 3,
    greater = 4,
    not_equal = 5,
    greater_or_equal = 6,
    always = 7,
    _,
};

pub const StencilOp = enum(u32) {
    keep = 0,
    zero = 1,
    replace = 2,
    increment_and_clamp = 3,
    decrement_and_clamp = 4,
    invert = 5,
    increment_and_wrap = 6,
    decrement_and_wrap = 7,
    _,
};

/// CmdSetStencilCompareMask and the like: which faces' values are set.
pub const STENCIL_FACE_FRONT: u32 = 1 << 0;
pub const STENCIL_FACE_BACK: u32 = 1 << 1;
pub const STENCIL_FACE_FRONT_AND_BACK: u32 = 3;

pub const StencilOpState = extern struct {
    fail_op: StencilOp = .keep,
    pass_op: StencilOp = .keep,
    depth_fail_op: StencilOp = .keep,
    compare_op: CompareOp = .never,
    compare_mask: u32 = 0,
    write_mask: u32 = 0,
    reference: u32 = 0,
};

pub const PipelineDepthStencilStateCreateInfo = extern struct {
    flags: u32 = 0,
    depth_test_enable: bool = false,
    depth_write_enable: bool = false,
    depth_compare_op: CompareOp = .less,
    depth_bounds_test_enable: bool = false,
    stencil_test_enable: bool = false,
    front: StencilOpState = .{},
    back: StencilOpState = .{},
    min_depth_bounds: f32 = 0,
    max_depth_bounds: f32 = 1,
};

pub const BlendFactor = enum(u32) {
    zero = 0,
    one = 1,
    src_color = 2,
    one_minus_src_color = 3,
    dst_color = 4,
    one_minus_dst_color = 5,
    src_alpha = 6,
    one_minus_src_alpha = 7,
    dst_alpha = 8,
    one_minus_dst_alpha = 9,
    constant_color = 10,
    one_minus_constant_color = 11,
    constant_alpha = 12,
    one_minus_constant_alpha = 13,
    src_alpha_saturate = 14,
    _,
};

pub const BlendOp = enum(u32) {
    add = 0,
    subtract = 1,
    reverse_subtract = 2,
    min = 3,
    max = 4,
    _,
};

/// PipelineColorBlendAttachmentState.color_write_mask: the channels
/// written.
pub const COLOR_COMPONENT_R: u32 = 1 << 0;
pub const COLOR_COMPONENT_G: u32 = 1 << 1;
pub const COLOR_COMPONENT_B: u32 = 1 << 2;
pub const COLOR_COMPONENT_A: u32 = 1 << 3;
pub const COLOR_COMPONENT_ALL: u32 = 0xF;

/// How a pixel's colour goes into a colour attachment.
pub const PipelineColorBlendAttachmentState = extern struct {
    blend_enable: bool = false,
    src_color_blend_factor: BlendFactor = .one,
    dst_color_blend_factor: BlendFactor = .zero,
    color_blend_op: BlendOp = .add,
    src_alpha_blend_factor: BlendFactor = .one,
    dst_alpha_blend_factor: BlendFactor = .zero,
    alpha_blend_op: BlendOp = .add,
    color_write_mask: u32 = COLOR_COMPONENT_ALL,
};

pub const LogicOp = enum(u32) {
    clear = 0,
    @"and" = 1,
    and_reverse = 2,
    copy = 3,
    and_inverted = 4,
    no_op = 5,
    xor = 6,
    @"or" = 7,
    nor = 8,
    equivalent = 9,
    invert = 10,
    or_reverse = 11,
    copy_inverted = 12,
    or_inverted = 13,
    nand = 14,
    set = 15,
    _,
};

/// How each colour attachment of the subpass is blended into.
pub const PipelineColorBlendStateCreateInfo = extern struct {
    flags: u32 = 0,
    logic_op_enable: bool = false,
    logic_op: LogicOp = .copy,
    attachment_count: u32 = 0,
    /// One for each colour attachment of the subpass the pipeline is made
    /// for, or none for the default over all of them. Each is taken on its
    /// own since 1.33 (`PhysicalDeviceFeatures.independent_blend`).
    attachments: ?[*]const PipelineColorBlendAttachmentState = null,
    blend_constants: [4]f32 = @splat(0),
    /// One set of blend constants for each colour attachment of the
    /// subpass, in place of the one `blend_constants` holds for all of
    /// them: facet.library's own, where Vulkan has the one set
    /// (since 1.51). Null, and every attachment blends by
    /// `blend_constants`. As many as `attachment_count` says, or as the
    /// subpass has colour attachments where that is 0.
    ///
    /// With `blend_constants` among the dynamic states, CmdSetBlendConstants
    /// sets the one set over all of them and CmdSetBlendConstantsAt one
    /// attachment's own.
    attachment_constants: ?[*]const [4]f32 = null,
};

/// State a pipeline leaves to commands.
pub const DynamicState = enum(u32) {
    viewport = 0,
    scissor = 1,
    line_width = 2,
    depth_bias = 3,
    blend_constants = 4,
    depth_bounds = 5,
    stencil_compare_mask = 6,
    stencil_write_mask = 7,
    stencil_reference = 8,
    _,
};

pub const PipelineDynamicStateCreateInfo = extern struct {
    flags: u32 = 0,
    dynamic_state_count: u32 = 0,
    dynamic_states: ?[*]const DynamicState = null,
};

/// facet.library's own, in `GraphicsPipelineCreateInfo.flags`: the depth
/// pre-pass. In each tile the pipeline's triangles have their depth drawn
/// first, alone, and are then shaded only where theirs is the depth left,
/// so that a pixel several cover is shaded once, by the nearest, in
/// whatever order they were drawn. Nothing drawn looks different. For a
/// pipeline whose depth test is LESS or LESS_OR_EQUAL, written, and not
/// blended; any other ignores it. It covers the triangles of a tile up to
/// the first of a pipeline without it, so the opaque are drawn first.
pub const PIPELINE_CREATE_DEPTH_PREPASS: u32 = 1 << 31;

/// What a graphics pipeline is made with.
/// How many vertices make a patch.
pub const PipelineTessellationStateCreateInfo = extern struct {
    flags: u32 = 0,
    patch_control_points: u32,
};

/// A compute pipeline: its function and its layout.
pub const ComputePipelineCreateInfo = extern struct {
    flags: u32 = 0,
    stage: PipelineShaderStageCreateInfo,
    layout: *PipelineLayout,
    base_pipeline_handle: ?*Pipeline = null,
    base_pipeline_index: i32 = -1,
};

/// What CmdDispatchIndirect reads from its buffer: CmdDispatch's numbers.
pub const DispatchIndirectCommand = extern struct {
    x: u32,
    y: u32,
    z: u32,
};

pub const GraphicsPipelineCreateInfo = extern struct {
    flags: u32 = 0,
    stage_count: u32,
    stages: [*]const PipelineShaderStageCreateInfo,
    vertex_input_state: ?*const PipelineVertexInputStateCreateInfo = null,
    input_assembly_state: ?*const PipelineInputAssemblyStateCreateInfo = null,
    tessellation_state: ?*const PipelineTessellationStateCreateInfo = null,
    viewport_state: ?*const PipelineViewportStateCreateInfo = null,
    rasterization_state: *const PipelineRasterizationStateCreateInfo,
    multisample_state: ?*const PipelineMultisampleStateCreateInfo = null,
    depth_stencil_state: ?*const PipelineDepthStencilStateCreateInfo = null,
    color_blend_state: ?*const PipelineColorBlendStateCreateInfo = null,
    dynamic_state: ?*const PipelineDynamicStateCreateInfo = null,
    layout: *PipelineLayout,
    render_pass: *RenderPass,
    subpass: u32 = 0,
    base_pipeline_handle: ?*Pipeline = null,
    base_pipeline_index: i32 = -1,
};

// --- descriptors ------------------------------------------------------------

/// What a descriptor set holds: its bindings, each of a kind.
pub const DescriptorSetLayout = opaque {};
/// Where descriptor sets come from.
pub const DescriptorPool = opaque {};
/// Buffers and images, as a pipeline's shaders read them.
pub const DescriptorSet = opaque {};

/// A descriptor's kind. facet.library has samplers and combined image
/// samplers (CreateSampler), sampled images - sampled as the fragment
/// function says - and uniform and storage buffers.
pub const DescriptorType = enum(u32) {
    sampler = 0,
    combined_image_sampler = 1,
    sampled_image = 2,
    storage_image = 3,
    uniform_texel_buffer = 4,
    storage_texel_buffer = 5,
    uniform_buffer = 6,
    storage_buffer = 7,
    uniform_buffer_dynamic = 8,
    storage_buffer_dynamic = 9,
    input_attachment = 10,
    _,
};

/// A binding of a set: its number, its kind and how many descriptors it
/// has, an array of them.
pub const DescriptorSetLayoutBinding = extern struct {
    binding: u32,
    descriptor_type: DescriptorType,
    descriptor_count: u32 = 1,
    stage_flags: u32 = SHADER_STAGE_ALL_GRAPHICS,
    /// A sampler of the layout's own for each descriptor, which a write
    /// cannot change (`PhysicalDeviceFeatures.immutable_samplers`, since
    /// 1.49): `descriptor_count` of them, for a `sampler` or
    /// `combined_image_sampler` binding and passed over on any other
    /// kind. Every set made of the layout starts with them, so a write of
    /// a combined image sampler then brings the texture alone. They have
    /// to last as long as the sets do.
    immutable_samplers: ?[*]const *Sampler = null,
};

pub const DescriptorSetLayoutCreateInfo = extern struct {
    flags: u32 = 0,
    binding_count: u32 = 0,
    bindings: ?[*]const DescriptorSetLayoutBinding = null,
};

/// Bytes of push constants the stages read.
pub const PushConstantRange = extern struct {
    stage_flags: u32 = SHADER_STAGE_ALL_GRAPHICS,
    offset: u32 = 0,
    size: u32,
};

pub const PipelineLayoutCreateInfo = extern struct {
    flags: u32 = 0,
    set_layout_count: u32 = 0,
    set_layouts: ?[*]const *DescriptorSetLayout = null,
    push_constant_range_count: u32 = 0,
    push_constant_ranges: ?[*]const PushConstantRange = null,
};

/// DescriptorPoolCreateInfo.flags: its sets may be freed one at a time.
pub const DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET: u32 = 1 << 0;

/// Descriptors of one kind a pool holds.
pub const DescriptorPoolSize = extern struct {
    type: DescriptorType,
    descriptor_count: u32,
};

pub const DescriptorPoolCreateInfo = extern struct {
    flags: u32 = 0,
    max_sets: u32,
    pool_size_count: u32 = 0,
    pool_sizes: ?[*]const DescriptorPoolSize = null,
};

/// Sets allocated from a pool: one of each layout.
pub const DescriptorSetAllocateInfo = extern struct {
    descriptor_pool: *DescriptorPool,
    descriptor_set_count: u32,
    set_layouts: [*]const *DescriptorSetLayout,
};

/// A sampled image written into a set, with its sampler for a combined
/// image sampler or a sampler of its own.
pub const DescriptorImageInfo = extern struct {
    /// For `.sampler` and `.combined_image_sampler`; null for the kinds
    /// that have none.
    sampler: ?*Sampler = null,
    image_view: ?*ImageView,
    image_layout: ImageLayout = .shader_read_only_optimal,
};

/// A buffer's bytes written into a set.
pub const DescriptorBufferInfo = extern struct {
    buffer: ?*Buffer,
    offset: u64 align(4) = 0,
    range: u64 align(4) = WHOLE_SIZE,
};

/// Descriptors written into a set: `descriptor_count` from element
/// `dst_array_element` of binding `dst_binding` on, running on into the
/// bindings after it.
pub const WriteDescriptorSet = extern struct {
    dst_set: *DescriptorSet,
    dst_binding: u32,
    dst_array_element: u32 = 0,
    descriptor_count: u32 = 1,
    descriptor_type: DescriptorType,
    image_info: ?[*]const DescriptorImageInfo = null,
    buffer_info: ?[*]const DescriptorBufferInfo = null,
    /// For `uniform_texel_buffer` and `storage_texel_buffer`: a view for
    /// each descriptor written (CreateBufferView).
    texel_buffer_view: ?[*]const *BufferView = null,
};

/// Descriptors copied from one set to another.
pub const CopyDescriptorSet = extern struct {
    src_set: *DescriptorSet,
    src_binding: u32,
    src_array_element: u32 = 0,
    dst_set: *DescriptorSet,
    dst_binding: u32,
    dst_array_element: u32 = 0,
    descriptor_count: u32 = 1,
};

/// An index buffer's indices.
pub const IndexType = enum(u32) {
    uint16 = 0,
    uint32 = 1,
    _,
};

// --- surfaces and swapchains -------------------------------------------------

/// Where pictures are shown: a screen of intuition's.
pub const Surface = opaque {};
/// The images a surface shows, handed out in turn.
pub const Swapchain = opaque {};

/// A surface over a screen the program has opened, the whole of it: the
/// swapchain's images are the screen's buffers (AllocScreenBuffer), the
/// first its own, and showing one is ChangeScreenBuffer. The screen stays
/// open for as long as the surface lasts.
pub const ScreenSurfaceCreateInfo = extern struct {
    flags: u32 = 0,
    screen: *intuition.Screen,
};

/// A surface over the inside of a window the program has opened, inside
/// its border: the swapchain's images are pictures of that size in
/// memory, and showing one copies it into the window at the display's
/// next frame, through the window's layer - what covers the window is
/// left alone. On a screen whose windows are composed, each in a buffer
/// of its own, the picture is shown in the window rather than copied into
/// it, and kept shown until the next is; the last stays in the window as
/// the swapchain goes. The window stays open for as long as the surface
/// lasts.
pub const WindowSurfaceCreateInfo = extern struct {
    flags: u32 = 0,
    window: *intuition.Window,
};

/// SurfaceCapabilities.supported_transforms and the pre_transform of a
/// swapchain: the picture as it is drawn.
pub const SURFACE_TRANSFORM_IDENTITY: u32 = 1 << 0;

/// SurfaceCapabilities.supported_composite_alpha and the composite_alpha
/// of a swapchain: a picture's alpha is not looked at.
pub const COMPOSITE_ALPHA_OPAQUE: u32 = 1 << 0;

/// What a surface can be given.
pub const SurfaceCapabilities = extern struct {
    /// The fewest images a swapchain can have, and the most; 0 for no
    /// most. How many are made is also what the display's memory has room
    /// for.
    min_image_count: u32,
    max_image_count: u32,
    /// The surface's size now, and the sizes a swapchain may have: for a
    /// screen, its size alone.
    current_extent: Extent2D,
    min_image_extent: Extent2D,
    max_image_extent: Extent2D,
    max_image_array_layers: u32,
    supported_transforms: u32,
    current_transform: u32,
    supported_composite_alpha: u32,
    /// What a swapchain's images can be used for (IMAGE_USAGE_*).
    supported_usage_flags: u32,
};

/// How a surface's colours are meant: sRGB, as every display of the
/// system's is.
pub const ColorSpace = enum(u32) {
    srgb_nonlinear = 0,
    _,
};

/// A format a surface's images can have, and how its colours are meant.
pub const SurfaceFormat = extern struct {
    format: Format,
    color_space: ColorSpace,
};

/// When a picture shown is taken up. The numbers are Vulkan's.
/// facet.library's surfaces have `fifo`: each picture from the display's
/// next frame on, in the order they were presented, none left out.
pub const PresentMode = enum(u32) {
    immediate = 0,
    mailbox = 1,
    fifo = 2,
    fifo_relaxed = 3,
    _,
};

/// What a swapchain is made with.
pub const SwapchainCreateInfo = extern struct {
    flags: u32 = 0,
    surface: *Surface,
    /// The fewest images it is to have: at least the surface's
    /// min_image_count, at most its max_image_count.
    min_image_count: u32,
    /// One of the surface's formats, and the size it is now.
    image_format: Format,
    image_color_space: ColorSpace = .srgb_nonlinear,
    image_extent: Extent2D,
    image_array_layers: u32 = 1,
    /// What its images are used for (IMAGE_USAGE_*): among the surface's
    /// supported_usage_flags.
    image_usage: u32 = IMAGE_USAGE_COLOR_ATTACHMENT,
    image_sharing_mode: SharingMode = .exclusive,
    queue_family_index_count: u32 = 0,
    queue_family_indices: ?[*]const u32 = null,
    pre_transform: u32 = SURFACE_TRANSFORM_IDENTITY,
    composite_alpha: u32 = COMPOSITE_ALPHA_OPAQUE,
    present_mode: PresentMode = .fifo,
    /// Pixels the display does not show need not be drawn: always so.
    clipped: bool = true,
    /// The surface's swapchain before this one, now handed on: it shows
    /// what it was given and hands out no more images.
    old_swapchain: ?*Swapchain = null,
};

/// Images shown: the semaphores waited for first, and an image of each
/// swapchain, with what came of each into `results` where it is not null.
pub const PresentInfo = extern struct {
    wait_semaphore_count: u32 = 0,
    wait_semaphores: ?[*]const *Semaphore = null,
    swapchain_count: u32 = 1,
    swapchains: [*]const *Swapchain,
    image_indices: [*]const u32,
    results: ?[*]Result = null,
};
