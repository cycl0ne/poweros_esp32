// SPDX-License-Identifier: MIT
//! An instance and the physical devices it lists: one for each driver
//! whose hardware the machine has (driver/_driver.zig). Each is described
//! as the instance is made, and keeps what its driver found for as long as
//! the instance lasts.

const sdk = @import("sdk");
const facet = sdk.facet;
const ExecBase = sdk.interface.exec.ExecBase;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _driver = @import("../driver/_driver.zig");
const cpu = @import("../driver/cpu/cpu.zig");
const _memory = @import("../memory/_memory.zig");
const _buffer = @import("../buffer/_buffer.zig");
const _render = @import("../render/_render.zig");

pub const Instance = struct {
    base: *FacetBase,
    /// The physical devices listed, the first `physical_count` of these.
    physicals: [1 + _driver.most_modules]PhysicalDevice,
    physical_count: u32 = 0,
    /// The devices and the surfaces made from it and not yet destroyed.
    devices: u32 = 0,
    surfaces: u32 = 0,
};

pub const PhysicalDevice = struct {
    instance: *Instance,
    /// Its driver, and what the driver said of it.
    ops: *const _driver.Ops,
    properties: facet.PhysicalDeviceProperties,
    /// What it cannot do, which is the library's own record and not
    /// Vulkan's features: `Capabilities` below, and
    /// GetPhysicalDeviceFeatures for what a program is told.
    can: Capabilities,
    queue_family: facet.QueueFamilyProperties,
    memory: facet.PhysicalDeviceMemoryProperties,
    /// The side of a tile the device draws in, in pixels, and the cores it
    /// shares a frame's tiles between.
    ///
    /// These two were fields of `PhysicalDeviceLimits` until 1.82, where
    /// `VkPhysicalDeviceLimits` has no counterpart for either and the
    /// structure became Vulkan's own. They are the library's here instead.
    /// A program is not left without the tile: GetRenderAreaGranularity is
    /// Vulkan's way to ask it and answers from this. The core count was
    /// never Vulkan's business, and a program that wants it has exec.
    tile_size: u32,
    cores: u32,
};

/// What a device of this library cannot do, which is a different thing from
/// what Vulkan calls a feature.
///
/// There is a field here where a create call can refuse something: a `false`
/// is what it would answer `error_feature_not_present` to. Until 1.82 this
/// was the public `facet.PhysicalDeviceFeatures` and
/// GetPhysicalDeviceFeatures handed it straight out - 49 fields of facet's
/// own naming against `VkPhysicalDeviceFeatures`' 55 `VkBool32` members,
/// overlapping in about fourteen places, so a program reading a
/// VkPhysicalDeviceFeatures out of that call got nonsense.
///
/// It is the library's own record now, and the reason is not only the shape.
/// About thirty-five of these gate things Vulkan 1.0 requires of every
/// implementation - `depth_test`, `stencil_test`, `blending`,
/// `indirect_draws`, `several_subpasses`, `texture_arrays`, `cube_maps`,
/// `textures_3d`, `samplers`, `input_attachments`, `several_outputs`,
/// `storage_images`, `texel_buffers`, `dynamic_descriptors` and the rest -
/// so a `false` in one of them is a defect to close and not a capability to
/// offer a program as a choice. Every one of them reads true on the cores;
/// several read false on the V3D, and each of those is a conformance block
/// for that device, written down in docs/facet-vulkan10.md. Six more are
/// facet's own idea with no Vulkan meaning at all -
/// `own_fragment_functions`, `sampling_format`, `compute_on_device`,
/// `tessellation_on_device`, `depth_prepass` and
/// `discarding_fragment_forms` - and those belong to the fixed forms, which
/// are facet's own surface and not Vulkan's.
///
/// What the library does with a false has not changed: the call that would
/// have used the thing refuses it, with `error_feature_not_present`.
/// GetPhysicalDeviceFeatures answers Vulkan's 55 members, made from these
/// (instance/getphysicaldevicefeatures.zig), which is where each Vulkan
/// feature's reason for being true or false is written down.
///
/// A driver fills this in `describe` beside the properties. It is part of
/// what a module and the library share, so it is in `stamp`.
pub const Capabilities = extern struct {
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

    /// Four samples a pixel: an image, an attachment and a pipeline of
    /// `SAMPLE_COUNT_4`, a subpass's resolve attachments, and
    /// CmdResolveImage. The sample-count masks a device reports follow it
    /// (`narrowSampleCounts`). Sample shading and alpha to one are
    /// optional features of their own and not part of it, and neither are
    /// two, eight or sixteen samples, nor four in a storage image or an
    /// input attachment. No device of this library has it yet
    /// (docs/facet-vulkan10.md item 61).
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
    /// `texture_shadow`, since 1.49 `texture_array_sampled`,
    /// `texture_cube_sampled` and `texture_3d_sampled`, and since 1.53
    /// `texture_cube_array_sampled` - and with them
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
    /// texels rather than 0 to 1 across the texture. The cores have it
    /// since 1.67; the V3D reads no sampler at all
    /// (`samplers`), so it has none of this either.
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
    /// `bc1_rgba_unorm_block`, `bc2_unorm_block`, `bc3_unorm_block` and
    /// since 1.72 `bc4_unorm_block` and `bc5_unorm_block`, since 1.73
    /// `bc7_unorm_block` and since 1.74 `bc6h_ufloat_block` and
    /// `bc6h_sfloat_block`,
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
    /// the fixed forms that sample one of them
    /// (`shader.FixedKind.texture_cube_array`, varyings x, y, z and which
    /// cube, and since 1.53 `texture_cube_array_sampled`, the same through
    /// a sampler). False where both the view and such a pipeline are
    /// refused - Vulkan's `imageCubeArray`. The cores have it since 1.46;
    /// no QPU program of the V3D reads the fourth coordinate.
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
    /// A texture may keep channels of its own rather than the 8888 colour
    /// a sample makes of them: an image of `r8g8_unorm`, two bytes a
    /// texel, read as (red, green, 0, 1), and of `r16_unorm`,
    /// `r16g16_unorm` or `r16g16b16a16_unorm`, 16 bits a channel. A
    /// sample reads the top 8 bits of each, which is all a tile's colour
    /// holds, while `texture.Texture.partsAt` gives the whole of them and
    /// `setParts` writes the whole of them - a height field, a shadow map
    /// of a program's own, or a texture a function writes through at more
    /// than 8 bits a channel. True on the cores; false on the V3D, whose
    /// texture unit is fed what the library unpacked, where CreateImage
    /// answers `error_format_not_supported` for such an image and
    /// GetPhysicalDeviceFormatProperties says the format is sampled by
    /// nothing. (Since 1.69.)
    wide_channels: bool = false,
    /// A texture may keep whole numbers rather than a colour: an image of
    /// Vulkan's `_uint` and `_sint` formats, one channel, two or four, of
    /// 8, 16 or 32 bits. `texture.Texture.wholesAt` reads the four
    /// numbers a texel keeps and `setWholes` writes them, each held to
    /// what its channel holds; `partsAt` and `setParts` give and take the
    /// same numbers as floats, which carry 24 bits of one exactly; and a
    /// sample holds each to 0 to 1 and over 255, the way a texel buffer
    /// of the format reads one (`shader.Texels.colorAt`), a whole number
    /// being no colour. For a counter, an index into a table, an object
    /// id or a bitfield a function reads or writes a texel at a time.
    /// True on the cores; false on the V3D, where CreateImage answers
    /// `error_format_not_supported` for such an image and
    /// GetPhysicalDeviceFormatProperties says the format is sampled by
    /// nothing. No such format is filtered linearly or drawn into, on any
    /// device. (Since 1.70.)
    whole_textures: bool = false,
};

/// The most vertex buffers, attributes and floats a vertex function hands
/// on, and what the rest of the limits are: what the library's own objects
/// have room for, whatever the driver.
///
/// The first two are Vulkan's floor and not a choice: `maxVertexInputBindings`
/// and `maxVertexInputAttributes` must each be at least 16, and only an
/// implementation advertising `VK_KHR_portability_subset` may report fewer,
/// which this is not. They were 4 and 8 until 1.84 (item 18 of
/// docs/facet-vulkan10.md). Raising them costs a `Binding` and an
/// `Attribute` each in every pipeline's plan and a `VertexBuffer` in every
/// record of what a draw was bound with - about 224 bytes a pipeline and
/// 192 a bound state - and nothing else: the V3D fetches no Vulkan
/// attribute, because the vertex stage runs on the cores for both devices
/// and the hardware is handed a stream already transformed.
pub const max_vertex_input_bindings = 16;
pub const max_vertex_input_attributes = 16;
/// Both ends of Vulkan's varying pair, from the SDK's own constant so
/// that the rasterizer, the widening path and `ir.zig` cannot drift from
/// what is reported here (`shader.MAX_VARYINGS`, 64 since 1.90). The V3D
/// reports its own lower number, which is a real ceiling: ten usable
/// registers, nine pregenerated vertex programs.
pub const max_vertex_output_components = facet.shader.MAX_VARYINGS;
/// The vertices of a tessellated patch, and the floats its control
/// function may write for the whole of it (`shader.Patch.ownValues`,
/// since 1.50).
pub const max_patch_points = 32;
pub const max_tessellation_patch_components = 16;
pub const max_push_constants_size = 128;
pub const max_bound_descriptor_sets = 4;
pub const max_image_dimension = 8192;
pub const max_image_dimension_3d = 256;
pub const max_image_array_layers = 256;
/// The samples a sampler takes along the longer axis at most
/// (`texture.most_taps` is what the sampling itself will do).
pub const max_sampler_anisotropy = 16;
/// The widest point a draw of points makes, in pixels across and down
/// (`shader.Vertices.setPointSize`, `PhysicalDeviceLimits.point_size_range`,
/// since 1.70). A point is widened into a rectangle whatever the device, so
/// nothing in the drawing holds it to a size; this is what the limit says
/// and what the widening holds a program's size to, a point wider than
/// this being a quad the program is better off drawing as one.
pub const max_point_size = 256;

/// A compute workgroup, which is what a compute function's entry holds room
/// for: the invocations it may declare along each axis, the invocations of a
/// group in all - a group runs on one core, one call of the function, so this
/// is how long a loop it is - and the bytes a group's invocations share,
/// which the library finds for each worker of a dispatch.
pub const max_compute_work_group_size = [3]u32{ 1024, 1024, 64 };
pub const max_compute_work_group_invocations = 1024;
pub const max_compute_shared_memory_size = 16 * 1024;

/// What a timestamp's unit is in nanoseconds: the E-clock as the library
/// reads it is microseconds (facet_base.now).
pub const timestamp_period_ns = 1000;

/// The most vertices a draw works, the lowest it reads to the highest. Both
/// drivers hold to it: a draw of more is left out of the frame and said to be,
/// and a CmdDraw whose own count is over it is refused as it is recorded.
pub const max_draw_vertices = 1 << 20;

/// What every device of this library answers for, which is most of
/// `PhysicalDeviceLimits`: what the library's own objects hold room for and
/// what its own rasterizer does, neither of which a driver changes. A driver
/// starts from this in `describe` and sets only the numbers its own hardware
/// decides, so the two cannot drift apart over the ninety-odd it shares.
///
/// Every number here is what the code does, measured and not aspired to, and
/// a number below what Vulkan 1.0 requires is left as it is with a note
/// saying so: the reshape at 1.82 was to make the shortfalls countable
/// (docs/facet-vulkan10.md items 17 to 30), not to paper over them. Where
/// Vulkan names the value an implementation lacking a feature must report,
/// that is what this says.
pub const limits: facet.PhysicalDeviceLimits = .{
    // --- images, and the texels a buffer may hold ---
    // A 1D image is a texture of one row (since 1.86, item 21), and the
    // row is as wide as a 2D image: the same layout holds it, and its
    // levels halve the width alone.
    .max_image_dimension_1d = max_image_dimension,
    .max_image_dimension_2d = max_image_dimension,
    .max_image_dimension_3d = max_image_dimension_3d,
    // A cube is six layers of a square 2D image, so its side is the 2D side.
    .max_image_dimension_cube = max_image_dimension,
    .max_image_array_layers = max_image_array_layers,
    // Nothing caps a view's texels but the buffer behind it, and a u32 of
    // bytes at the widest format a view takes - 16 bytes, rgba32f - is this
    // many texels (buffer/createbufferview.zig).
    .max_texel_buffer_elements = 0xFFFF_FFFF / 16,

    // --- buffers, memory and what one allocation may be ---
    // Neither range is capped: a descriptor reaches as much of its buffer as
    // the buffer has, and what a buffer may be is what memory will bear.
    .max_uniform_buffer_range = 0xFFFF_FFFF,
    .max_storage_buffer_range = 0xFFFF_FFFF,
    .max_push_constants_size = max_push_constants_size,
    // Nothing counts allocations or samplers: AllocateMemory and
    // CreateSampler fail when exec has no memory and not before.
    .max_memory_allocation_count = 0xFFFF_FFFF,
    .max_sampler_allocation_count = 0xFFFF_FFFF,
    // A buffer and an image may lie side by side in one allocation with
    // nothing between them.
    .buffer_image_granularity = 1,
    // No memory is bound a piece at a time, which is what `sparse_binding`
    // says; Vulkan's value for a device without it is 0.
    .sparse_address_space_size = 0,

    // --- descriptors: a stage's, and a whole set's ---
    .max_bound_descriptor_sets = max_bound_descriptor_sets,
    // Nothing holds a stage to a count of descriptors: a layout's binding is
    // refused past 255 and a set's slots past 0xFFFF
    // (descriptor/createdescriptorsetlayout.zig), a stage's flags are never
    // read, and a set's slots are a pointer and not a fixed array
    // (`shader.Set.slots`). So what a stage may read is what a set may hold,
    // and what a pipeline layout may hold is that over its four sets.
    .max_per_stage_descriptor_samplers = 0xFFFF,
    .max_per_stage_descriptor_uniform_buffers = 0xFFFF,
    .max_per_stage_descriptor_storage_buffers = 0xFFFF,
    .max_per_stage_descriptor_sampled_images = 0xFFFF,
    .max_per_stage_descriptor_storage_images = 0xFFFF,
    .max_per_stage_descriptor_input_attachments = 0xFFFF,
    .max_per_stage_resources = 0xFFFF,
    .max_descriptor_set_samplers = facet.shader.MAX_SETS * 0xFFFF,
    .max_descriptor_set_uniform_buffers = facet.shader.MAX_SETS * 0xFFFF,
    // A dynamic descriptor takes an offset from CmdBindDescriptorSets, and
    // one set layout holds `facet.shader.MAX_DYNAMIC_OFFSETS` of them, 12.
    //
    // Vulkan counts these over a whole pipeline layout and these two are
    // its floor exactly, which is 8 + 4 = 12: a layout within them fits
    // in one set however it spreads them, so the numbers hold in every
    // arrangement. The library in fact takes 12 *in each* of its four
    // sets, 48 over a layout, but reporting 48 would be a promise it
    // cannot keep - a layout is entitled to put all 48 in one set, and
    // that set holds 12. So the pair that is true of any arrangement is
    // what is reported, which is Vulkan's own (item 19, done in 1.85).
    .max_descriptor_set_uniform_buffers_dynamic = 8,
    .max_descriptor_set_storage_buffers = facet.shader.MAX_SETS * 0xFFFF,
    .max_descriptor_set_storage_buffers_dynamic = 4,
    .max_descriptor_set_sampled_images = facet.shader.MAX_SETS * 0xFFFF,
    .max_descriptor_set_storage_images = facet.shader.MAX_SETS * 0xFFFF,
    .max_descriptor_set_input_attachments = facet.shader.MAX_SETS * 0xFFFF,

    // --- the vertex stage ---
    // Vulkan asks for 16 of each of the first two and 64 of the components
    // (items 17 and 18).
    .max_vertex_input_attributes = max_vertex_input_attributes,
    .max_vertex_input_bindings = max_vertex_input_bindings,
    // One less than the stride, which is what an attribute inside a vertex
    // of that stride can be.
    .max_vertex_input_attribute_offset = 2047,
    .max_vertex_input_binding_stride = 2048,
    .max_vertex_output_components = max_vertex_output_components,

    // --- the tessellation stages ---
    // All zero, and not because nothing tessellates. The library does: a
    // pipeline may carry a control and an evaluation function and the patch
    // is cut on the cores (driver/_tessellate.zig, `most_level` 64, patches
    // of `max_patch_points` vertices). But `tessellation_shader` is false,
    // because a program bringing SPIR-V cannot declare either stage -
    // `spirv.facet_profile` leaves `Profile.stages` at vertex and fragment -
    // and Vulkan's required-limits table makes the unsupported value
    // mandatory once the feature reads false. So these are what Vulkan asks
    // for, and what facet's own Zig surface can do is said in
    // `shader.Patch` rather than here. docs/facet-vulkan10.md item 60.
    .max_tessellation_generation_level = 0,
    .max_tessellation_patch_size = 0,
    .max_tessellation_control_per_vertex_input_components = 0,
    .max_tessellation_control_per_vertex_output_components = 0,
    .max_tessellation_control_per_patch_output_components = 0,
    .max_tessellation_control_total_output_components = 0,
    .max_tessellation_evaluation_input_components = 0,
    .max_tessellation_evaluation_output_components = 0,

    // --- the geometry stage ---
    // There is none, which is what `geometry_shader` says. Vulkan asks for
    // these numbers only of an implementation that has the stage, so zero is
    // the right answer and not a shortfall.
    .max_geometry_shader_invocations = 0,
    .max_geometry_input_components = 0,
    .max_geometry_output_components = 0,
    .max_geometry_output_vertices = 0,
    .max_geometry_total_output_components = 0,

    // --- the fragment stage ---
    .max_fragment_input_components = max_vertex_output_components,
    // What one fragment function may write, which on this rasterizer is
    // every colour a subpass may hold (`can.several_outputs`).
    //
    // **There is a catch, and it is a defect and not this number.** A
    // subpass gives each colour attachment a part of its own unless it
    // carries facet's own SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER, and
    // CreateGraphicsPipelines refuses a fragment function whose output count
    // is not the part's (pipeline/creategraphicspipelines.zig). So a program
    // using Vulkan's own surface, which has no such flag, is held to one
    // colour a function however many the subpass has - the same
    // inconsistency `max_color_attachments` already carries by saying a
    // subpass may hold four while the pass is drawn in four parts. Saying 1
    // here would move that inconsistency rather than remove it, and would
    // leave the two devices indistinguishable. docs/facet-vulkan10.md item
    // 80 is the defect; item 55 is the V3D's side of it.
    .max_fragment_output_attachments = _render.most_colors,
    // No blend factor reads a second source colour, so Vulkan's value for a
    // device without `dual_src_blend` is 0.
    .max_fragment_dual_src_attachments = 0,
    // Nothing caps the colours, storage images and storage buffers one
    // fragment function writes taken together, beyond what each is capped
    // at on its own.
    .max_fragment_combined_output_resources = 0xFFFF,

    // --- a compute dispatch ---
    .max_compute_shared_memory_size = max_compute_shared_memory_size,
    // Nothing caps a dispatch's groups along an axis (CmdDispatch).
    .max_compute_work_group_count = .{ 0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF },
    .max_compute_work_group_invocations = max_compute_work_group_invocations,
    .max_compute_work_group_size = max_compute_work_group_size,

    // --- how finely a thing is placed and sampled ---
    // The rasterizer works a vertex's position in 1/256 of a pixel and a
    // texel's coordinate and its mipmap level the same way.
    .sub_pixel_precision_bits = 8,
    .sub_texel_precision_bits = 8,
    .mipmap_precision_bits = 8,
    // An index may be any value a u32 holds: CmdDrawIndexed caps nothing and
    // an index is carried as a u32 the whole way (driver/_vertices.zig). What
    // is capped is the *span* a draw names, the lowest index to the highest,
    // at `max_draw_vertices` - a different thing from the largest value, and
    // item 23's subject.
    .max_draw_indexed_index_value = 0xFFFF_FFFF,
    // An indirect draw plays each of the draws its count names, with nothing
    // holding the count (command/cmddrawindirect.zig).
    .max_draw_indirect_count = 0xFFFF_FFFF,

    // --- sampling ---
    // A sampler's bias is added to the level worked out and the sum held
    // inside the image's levels (`texture.zig`), so a bias of more than the
    // mipmap chain of the largest image is one nothing more can be done
    // with: log2(8192) is 13.
    .max_sampler_lod_bias = 13,
    .max_sampler_anisotropy = max_sampler_anisotropy,

    // --- viewports ---
    // One viewport and one scissor: a pipeline asking for more is refused
    // and CmdSetViewport takes the first (`several_viewports`). Vulkan's
    // value for a device without `multi_viewport` is 1.
    .max_viewports = 1,
    .max_viewport_dimensions = .{ max_image_dimension, max_image_dimension },
    // Vulkan asks that these reach twice the viewport's size either way.
    .viewport_bounds_range = .{ -2 * @as(f32, max_image_dimension), 2 * @as(f32, max_image_dimension) - 1 },
    .viewport_sub_pixel_bits = 8,

    // --- how memory and offsets are aligned ---
    .min_memory_map_alignment = _memory.alignment,
    // A buffer is aligned to this and a descriptor's offset into one with it
    // (`_buffer.alignment`). CreateBufferView asks something more of a texel
    // buffer's offset that no power of two can say - a multiple of the
    // *format's* texel size, which is 12 bytes for the three three-channel
    // 32-bit formats - so for those three a program obeying this limit can
    // still be refused. That is a defect of the check and not of the number
    // (docs/facet-vulkan10.md item 79).
    .min_texel_buffer_offset_alignment = _buffer.alignment,
    .min_uniform_buffer_offset_alignment = _buffer.alignment,
    .min_storage_buffer_offset_alignment = _buffer.alignment,

    // --- sampling at an offset from the coordinate given ---
    // A constant offset is sampled at since 1.87 (item 28): SPIR-V's
    // `ConstOffset` on an `OpImageSample*`, which a generated shader
    // carries and the cores apply in texels of the level they chose
    // (`texture.sampleLayerAt`). Vulkan asks for -8 and 7 of every
    // implementation, with no feature to gate it, so this is the range it
    // asks for and the range this takes. **The V3D overrides both to 0**,
    // because it refuses the operand (`compile.Error.Operands`).
    //
    // No gather of four texels is taken: `OpImageGather` is in no profile
    // here and `shader_image_gather_extended` is reported false, which is
    // what makes 0 the mandatory value for the gather pair rather than a
    // shortfall.
    .min_texel_offset = facet.texture.least_texel_offset,
    .max_texel_offset = facet.texture.most_texel_offset,
    .min_texel_gather_offset = 0,
    .max_texel_gather_offset = 0,
    // What was mixed over a triangle is read at the pixel's centre and
    // nowhere else, which is what Vulkan asks of a device without
    // `sample_rate_shading`.
    .min_interpolation_offset = 0,
    .max_interpolation_offset = 0,
    .sub_pixel_interpolation_offset_bits = 0,

    // --- framebuffers, and the samples a pixel may hold ---
    .max_framebuffer_width = max_image_dimension,
    .max_framebuffer_height = max_image_dimension,
    // 256, which is what Vulkan asks and what Mesa's v3dv reports on this
    // same GPU (src/broadcom/vulkan/v3dv_device.c). A pass clears each layer
    // where an attachment's load op clears, CmdClearAttachments the ones a
    // rectangle names, and a draw goes into the first: Vulkan 1.0 picks
    // another only through a geometry shader's `Layer` (since 1.91, item
    // 22). It equals `max_image_array_layers`, so every layer an image may
    // have is one a framebuffer may reach. The V3D reports 1 until its
    // render control list is played once a layer (driver/v3d/driver.zig).
    .max_framebuffer_layers = max_image_array_layers,
    // One sample a pixel and four, which is what Vulkan requires of seven
    // of these masks: the three framebuffer masks, the no-attachments mask,
    // and the colour, depth and stencil sampled-image masks. Both Mesa
    // drivers report it: v3dv on this same GPU, in every row but storage
    // (`supported_sample_counts`, src/broadcom/vulkan/v3dv_device.c), and
    // lavapipe with eight beside it (`LVP_SAMPLE_COUNTS`,
    // src/gallium/frontends/lavapipe/lvp_device.c). The integer
    // sampled-image mask and the storage-image mask want the 1 bit alone,
    // the latter because `shader_storage_image_multisample` is false and
    // Vulkan's unsupported column for it is 1, and that is what they say.
    //
    // **What a device reports is narrower** (`narrowSampleCounts`): one
    // sample in each of the seven until it has `can.multisampling`, which
    // no device has yet, so the seven are still seven shortfalls (item
    // 61); and one sample for a subpass with no attachments, which cannot
    // be made yet (item 43). Until 1.96 this table said one sample itself.
    .framebuffer_color_sample_counts = facet.SAMPLE_COUNT_1 | facet.SAMPLE_COUNT_4,
    .framebuffer_depth_sample_counts = facet.SAMPLE_COUNT_1 | facet.SAMPLE_COUNT_4,
    .framebuffer_stencil_sample_counts = facet.SAMPLE_COUNT_1 | facet.SAMPLE_COUNT_4,
    .framebuffer_no_attachments_sample_counts = facet.SAMPLE_COUNT_1 | facet.SAMPLE_COUNT_4,
    .max_color_attachments = _render.most_colors,
    .sampled_image_color_sample_counts = facet.SAMPLE_COUNT_1 | facet.SAMPLE_COUNT_4,
    .sampled_image_integer_sample_counts = facet.SAMPLE_COUNT_1,
    .sampled_image_depth_sample_counts = facet.SAMPLE_COUNT_1 | facet.SAMPLE_COUNT_4,
    .sampled_image_stencil_sample_counts = facet.SAMPLE_COUNT_1 | facet.SAMPLE_COUNT_4,
    .storage_image_sample_counts = facet.SAMPLE_COUNT_1,
    // One word, which at one sample a pixel is one bit: Vulkan reads
    // ceil(rasterization_samples / 32) words of
    // `PipelineMultisampleStateCreateInfo.sample_mask` and ignores the bits
    // above the sample count, so bit 0 is the whole of it here. It is read
    // and honoured - a pipeline whose mask clears bit 0 covers no sample
    // and draws nothing - which is why this may say 1 while every mask
    // above still says one sample (item 61, since 1.89).
    .max_sample_mask_words = 1,

    // --- timestamps ---
    // The one queue family both draws and computes and writes timestamps,
    // so there is no queue that does the work without the clock. `describe`
    // clears both this and the period on a machine with no timer.device.
    .timestamp_compute_and_graphics = facet.TRUE,
    .timestamp_period = timestamp_period_ns,

    // --- clipping, culling, and the queue's priorities ---
    // Neither built-in is in the SPIR-V profile and no fixed form writes
    // one, so Vulkan's value for a device without `shader_clip_distance`
    // and `shader_cull_distance` is 0.
    .max_clip_distances = 0,
    .max_cull_distances = 0,
    .max_combined_clip_and_cull_distances = 0,
    // A queue's priority is turned into a task priority in 21 steps
    // (device/_device.zig), fewer where the maker's own priority is near an
    // end of the range.
    .discrete_queue_priorities = 21,

    // --- points and lines wider than one pixel ---
    // A point and a line are widened into rectangles by the cores for
    // either device, nothing in the widening capping the width
    // (driver/_vertices.zig). A point is held to `max_point_size`, which is
    // what the limit says and what the widening holds a program's size to;
    // a line's width is held only by the viewport it is drawn in.
    .point_size_range = .{ 1, max_point_size },
    .line_width_range = .{ 1, max_image_dimension },
    // The widening works in floats and the rasterizer places an edge to
    // 1/256 of a pixel, so that is the finest step between two sizes it
    // tells apart. 0 would have read as "only the narrowest is drawn",
    // which is not what happens.
    .point_size_granularity = 1.0 / 256.0,
    .line_width_granularity = 1.0 / 256.0,
    // A line is widened into the rectangle the specification's strict rule
    // draws, and the one sample of a pixel sits at its centre, which is
    // where Vulkan's standard location for one sample is.
    .strict_lines = facet.TRUE,
    .standard_sample_locations = facet.TRUE,

    // --- copies, and memory the host shares ---
    // A copy between a buffer and an image reads and writes a row at a
    // time whatever the offset, so no alignment is faster than another.
    .optimal_buffer_copy_offset_alignment = 1,
    .optimal_buffer_copy_row_pitch_alignment = 1,
    // Every memory a program may map is coherent (each driver's memory
    // types), so a flush covers whatever it is given; this is what memory
    // is aligned to in any case.
    .non_coherent_atom_size = _memory.alignment,
};

/// The physical devices of `instance` described: the cores' first, then each
/// module's that finds its hardware.
pub fn describe(base: *FacetBase, instance: *Instance) void {
    const sys = base.sys_base;
    _driver.lookForModules(base);
    describeOne(sys, instance, &cpu.ops);
    for (base.module_ops[0..base.module_count]) |ops| describeOne(sys, instance, @ptrCast(@alignCast(ops.?)));
    // A timestamp is the E-clock read as a command is played, and the
    // clock is the library's, not a driver's: without timer.device no
    // device of this machine writes one (CmdWriteTimestamp), and each says
    // so as Vulkan has a device say it. `timestamp_compute_and_graphics`
    // too since 1.93, its true promising at least 36 bits on every
    // graphics and compute queue.
    if (!base.clock_open) for (instance.physicals[0..instance.physical_count]) |*physical| {
        physical.can.timestamp_queries = false;
        physical.queue_family.timestamp_valid_bits = 0;
        physical.properties.limits.timestamp_period = 0;
        physical.properties.limits.timestamp_compute_and_graphics = facet.FALSE;
    };
}

fn describeOne(sys: *ExecBase, instance: *Instance, ops: *const _driver.Ops) void {
    const physical = &instance.physicals[instance.physical_count];
    physical.instance = instance;
    physical.ops = ops;
    if (!ops.describe(sys, physical)) return;
    narrowSampleCounts(physical);
    instance.physical_count += 1;
}

/// `physical`'s sample-count masks held to what it draws, so that none says
/// a count before there is code to draw it. `limits` says one sample and
/// four where Vulkan asks for both. A device without `can.multisampling`
/// keeps the 1 bit alone in those seven masks; and since a subpass with no
/// attachments cannot be made on any device yet (render/createrenderpass.zig,
/// item 43), the no-attachments mask keeps the 1 bit alone whatever the
/// device can. A bit a driver cleared stays clear, so the V3D's zeros for
/// the images it does not sample (driver/v3d/driver.zig) survive this.
/// Called after each driver's describe, since 1.96.
pub fn narrowSampleCounts(physical: *PhysicalDevice) void {
    const said = &physical.properties.limits;
    said.framebuffer_no_attachments_sample_counts &= facet.SAMPLE_COUNT_1;
    if (physical.can.multisampling) return;
    said.framebuffer_color_sample_counts &= facet.SAMPLE_COUNT_1;
    said.framebuffer_depth_sample_counts &= facet.SAMPLE_COUNT_1;
    said.framebuffer_stencil_sample_counts &= facet.SAMPLE_COUNT_1;
    said.sampled_image_color_sample_counts &= facet.SAMPLE_COUNT_1;
    said.sampled_image_depth_sample_counts &= facet.SAMPLE_COUNT_1;
    said.sampled_image_stencil_sample_counts &= facet.SAMPLE_COUNT_1;
}
