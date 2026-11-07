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

/// SPIR-V: the form a shader is shipped in for a device that compiles it,
/// built at comptime beside the Zig function and read by a driver. The
/// format alone - it knows nothing of facet's own shaders. (Since 1.75.)
pub const spirv = @import("spirv.zig");

/// A shader written once as a comptime graph, for both kinds of device:
/// the words for one that compiles, and a function for the cores.
/// (Since 1.75.)
pub const ir = @import("ir.zig");

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
    /// An event is signalled. Vulkan's `VK_EVENT_SET`, and the name is
    /// here for a program that was written against it: this library has
    /// no events yet, so no call answers it. (Since 1.80.)
    event_set = 3,
    /// An event is not signalled. Vulkan's `VK_EVENT_RESET`, and as with
    /// `event_set` no call of this library answers it yet. (Since 1.80.)
    event_reset = 4,
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
    /// A layer asked for is not there. Vulkan's
    /// `VK_ERROR_LAYER_NOT_PRESENT`: this library has no layers and no
    /// call that takes a list of them, so the name is here for a program
    /// written against Vulkan rather than for an answer it will get.
    /// (Since 1.80.)
    error_layer_not_present = -6,
    /// An extension asked for is not there. Vulkan's
    /// `VK_ERROR_EXTENSION_NOT_PRESENT`, and as with
    /// `error_layer_not_present` no call takes a list of them yet.
    /// (Since 1.80.)
    error_extension_not_present = -7,
    /// What was asked for is not something this library does.
    error_feature_not_present = -8,
    /// There is nothing here that provides the interface asked for: the
    /// version a program gives CreateInstance is newer than the
    /// library's. Vulkan's `VK_ERROR_INCOMPATIBLE_DRIVER`, and what that
    /// call answered with `error_initialization_failed` before 1.80.
    /// (Since 1.80.)
    error_incompatible_driver = -9,
    error_too_many_objects = -10,
    /// The format is not one this library does for what it was asked.
    error_format_not_supported = -11,
    /// A descriptor pool has room for the sets, but not in one piece.
    error_fragmented_pool = -12,
    /// Something failed that no valid use of this library explains.
    /// Vulkan's `VK_ERROR_UNKNOWN`, which any call that answers a result
    /// may give: it carries no name in the header for a version, every
    /// one of them being allowed to return it. Nothing here answers it
    /// yet - a call that cannot say what went wrong is a defect to find,
    /// not a code to hand back - and the name is here for a program
    /// written against Vulkan that switches on it. (Since 1.80.)
    error_unknown = -13,
    /// A descriptor pool has no room for another set.
    error_out_of_pool_memory = -1000069000,
    /// A shader module's code is not a `shader.Code`, or names no
    /// function a pipeline's stage asks for.
    ///
    /// One of the two results this library answers that core Vulkan 1.0
    /// does not list for the call that gives it (`error_out_of_pool_memory`
    /// is the other): `vkCreateShaderModule`'s whole list in core 1.0 is
    /// success and the two out-of-memory codes, words that are not SPIR-V
    /// being undefined behaviour there rather than a reportable error.
    /// Khronos's own reference page does list this code for the call,
    /// because the extension below contributes it. facet refuses instead, and keeps Khronos's own number for
    /// the refusal - `VK_ERROR_INVALID_SHADER_NV`, which the extension
    /// VK_NV_glsl_shader contributes for exactly this meaning - rather
    /// than inventing a code of its own. It is the first of
    /// CreateShaderModule's two tiers: malformed words here, well formed
    /// words a device will not compile at the pipeline
    /// (`error_feature_not_present`). A Vulkan shim running without that
    /// extension enabled is the layer that has to translate it.
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

/// Vulkan's boolean: a `uint32_t` and not a one-byte bool, which is why
/// `VkPhysicalDeviceFeatures` is 220 bytes where a structure of Zig `bool`
/// would be 55. `VkBool32`, with `VK_TRUE` and `VK_FALSE`.
pub const Bool32 = u32;
pub const TRUE: Bool32 = 1;
pub const FALSE: Bool32 = 0;

// --- the instance -----------------------------------------------------------

/// A version packed into one word the way Vulkan packs one: a variant in
/// the top three bits, then seven bits of major version, ten of minor and
/// twelve of patch. `VK_MAKE_API_VERSION`.
///
/// The variant is 0 for Vulkan itself and names another API built on the
/// same encoding where it is not; nothing here answers for one, and
/// CreateInstance refuses an instance asked for with a variant of its own.
///
/// Until 1.82 this was `major << 16 | minor`, with the library's own
/// version and revision in it rather than an interface version - so
/// Vulkan's own `VK_API_VERSION_1_0`, which is 4194304, was a number far
/// above anything the comparison in CreateInstance would take, and a
/// program that filled `InstanceCreateInfo.api_version` with the constant
/// Vulkan told it to use was turned away at the door with
/// `error_incompatible_driver`. facet's default hid it: `api_version`
/// defaults to this library's own value, so only a program saying what
/// Vulkan says was hurt by it.
pub fn makeApiVersion(variant: u32, major: u32, minor: u32, patch: u32) u32 {
    return variant << 29 | major << 22 | minor << 12 | patch;
}

/// The same with no variant, which is every version of Vulkan itself:
/// `VK_MAKE_VERSION`. This is what a `driver_version` is made with, where
/// the library's own version and revision go in the major and the minor -
/// Vulkan leaves a driver's version to whoever wrote the driver, and asks
/// only that it be packed like this so that a tool can print it.
pub fn makeVersion(major: u32, minor: u32, patch: u32) u32 {
    return makeApiVersion(0, major, minor, patch);
}

/// The four parts of a packed version, taken back out:
/// `VK_API_VERSION_VARIANT`, `_MAJOR`, `_MINOR` and `_PATCH`.
pub fn apiVersionVariant(version: u32) u32 {
    return version >> 29;
}

pub fn apiVersionMajor(version: u32) u32 {
    return version >> 22 & 0x7F;
}

pub fn apiVersionMinor(version: u32) u32 {
    return version >> 12 & 0x3FF;
}

pub fn apiVersionPatch(version: u32) u32 {
    return version & 0xFFF;
}

/// The interface this library has, and the only one it answers for:
/// `VK_API_VERSION_1_0`, which is 4194304. A program asking for a major
/// and minor version no higher than this is taken, whatever its patch -
/// Vulkan asks that the patch not be compared - and one asking for more
/// is refused with `error_incompatible_driver`.
pub const API_VERSION_1_0: u32 = makeApiVersion(0, 1, 0, 0);

/// What a program is, for an Instance.
pub const InstanceCreateInfo = extern struct {
    flags: u32 = 0,
    /// The program's name and its own version, for whoever lists who uses
    /// the library; may be null.
    application_name: ?[*:0]const u8 = null,
    application_version: u32 = 0,
    /// The interface version the program was written for
    /// (`makeApiVersion`), which is `API_VERSION_1_0` here and in Vulkan
    /// is `VkApplicationInfo.apiVersion`. Its major and minor version may
    /// be no higher than this library's or the instance is refused
    /// (`error_incompatible_driver`, since 1.80;
    /// `error_initialization_failed` before it); the patch is not
    /// compared, because Vulkan asks that an implementation take any
    /// patch of a version it has. A variant of its own is refused: this
    /// is Vulkan's encoding and no other API's. 0 is `API_VERSION_1_0`.
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

/// The samples a pixel may hold, as a bit: `VkSampleCountFlagBits`. The
/// limits below say which of these a device has for a colour attachment, a
/// depth attachment and the rest, each as a mask of them, and
/// `ImageCreateInfo.samples` is one of them - the numbers are the counts
/// themselves, so a `samples` of 4 and `SAMPLE_COUNT_4` are the same word.
///
/// Every device of this library has `SAMPLE_COUNT_1` and nothing else:
/// CreateImage refuses an image of more (image/_image.zig). Vulkan 1.0
/// requires 4 of every implementation, so the single bit is a defect
/// written down in docs/facet-vulkan10.md item 61 and not a choice.
/// (Since 1.82; there was no name for any of these before it.)
pub const SAMPLE_COUNT_1: u32 = 1 << 0;
pub const SAMPLE_COUNT_2: u32 = 1 << 1;
pub const SAMPLE_COUNT_4: u32 = 1 << 2;
pub const SAMPLE_COUNT_8: u32 = 1 << 3;
pub const SAMPLE_COUNT_16: u32 = 1 << 4;
pub const SAMPLE_COUNT_32: u32 = 1 << 5;
pub const SAMPLE_COUNT_64: u32 = 1 << 6;

/// The most a device does: `VkPhysicalDeviceLimits`, member for member, as
/// `scripts/vulkan-struct-check.sh` holds it.
///
/// Vulkan's 106 members, in Vulkan's order, with Vulkan's types. Until 1.82
/// this was 26 fields of facet's own, append-only by contract - "a field
/// added at the end, so that none already there moves" - which is how an LVO
/// library keeps its ABI across releases and the exact opposite of Vulkan's
/// frozen layout. PowerOS is at v0.2 and the interface is not frozen, so the
/// contract was the one thing standing between this structure and Vulkan's,
/// and it is gone: about 25 of facet's fields had a counterpart here and the
/// other 81 members had no field at all.
///
/// Two of facet's fields had no Vulkan counterpart and have left:
/// `tile_size`, which GetRenderAreaGranularity answers for in Vulkan's own
/// way, and `cores`, which was never Vulkan's business. Both are on the
/// library's own `PhysicalDevice` record now.
///
/// Three changed type to match: `min_memory_map_alignment` is Vulkan's
/// `size_t`, `max_sampler_anisotropy` is a float, and `timestamp_period_ns`
/// has become `timestamp_period`, a float of nanoseconds - which also
/// settles a period that is not a whole number of nanoseconds, something a
/// u32 could not say. `max_descriptor_set_dynamic_buffers` folded two
/// Vulkan limits into one and has split back into them.
///
/// The 64-bit members carry `align(4)`, as every 64-bit field of this SDK
/// does: the ESP32's compiler moves the stack pointer by exactly the bytes
/// of a call's stack arguments, so a call with an odd number of them leaves
/// what it calls 4 bytes off an 8-byte boundary and a structure wanting 8
/// would sit where `@alignCast` refuses it (sdk/sdk.zig). So this is
/// Vulkan's structure member for member, name for name and type for type,
/// but not byte for byte: on a 64-bit chip C pads before
/// `bufferImageGranularity` where this does not. Nothing in this library
/// casts one onto the other, and the shim that would one day speak to a
/// Vulkan program marshals every structure field by field in any case
/// (docs/facet-vulkan10.md item 68), so the difference costs nothing and
/// saying it out loud costs less than finding it later.
///
/// **A number here is what the device does, not what Vulkan requires.**
/// Where this library falls short of a required minimum the real number is
/// reported and the shortfall is written down in docs/facet-vulkan10.md,
/// items 17 to 30; where Vulkan names the value an implementation without
/// some feature must report - 1 for `max_sampler_anisotropy` without
/// `sampler_anisotropy`, 0 for the tessellation and geometry limits without
/// those stages, `SAMPLE_COUNT_1` alone for the sample masks - that is what
/// it says. Each driver's `describe` says where its own numbers come from.
pub const PhysicalDeviceLimits = extern struct {

    // --- images, and the texels a buffer may hold ---
    /// The widest 1D image, the widest and highest 2D image and
    /// framebuffer, the deepest 3D image, the side of a cube, and the
    /// layers of an array.
    max_image_dimension_1d: u32,
    max_image_dimension_2d: u32,
    max_image_dimension_3d: u32,
    max_image_dimension_cube: u32,
    max_image_array_layers: u32,
    /// The texels a uniform or storage texel buffer may hold
    /// (`CreateBufferView`).
    max_texel_buffer_elements: u32,

    // --- buffers, memory and what one allocation may be ---
    /// The bytes of a uniform buffer and of a storage buffer one
    /// descriptor reaches.
    max_uniform_buffer_range: u32,
    max_storage_buffer_range: u32,
    /// The bytes of push constants a pipeline's layout may hold.
    max_push_constants_size: u32,
    /// The allocations and the samplers that may be alive at once.
    /// Nothing here keeps a count of either, so these say what the
    /// machine's memory will bear rather than a number the library
    /// enforces.
    max_memory_allocation_count: u32,
    max_sampler_allocation_count: u32,
    /// How far apart a buffer and an image must lie in one memory
    /// allocation to be sure of not disturbing each other: 1 where
    /// they may be packed together.
    buffer_image_granularity: u64 align(4),
    /// The address space a sparse resource may cover. 0 where no
    /// memory is bound a piece at a time, which is the case here.
    sparse_address_space_size: u64 align(4),

    // --- descriptors: a stage's, and a whole set's ---
    /// The descriptor sets bound at once.
    max_bound_descriptor_sets: u32,
    /// The descriptors of each kind one stage may read: samplers,
    /// uniform buffers, storage buffers, sampled images, storage
    /// images and input attachments.
    max_per_stage_descriptor_samplers: u32,
    max_per_stage_descriptor_uniform_buffers: u32,
    max_per_stage_descriptor_storage_buffers: u32,
    max_per_stage_descriptor_sampled_images: u32,
    max_per_stage_descriptor_storage_images: u32,
    max_per_stage_descriptor_input_attachments: u32,
    /// The descriptors and attachments of every kind together that one
    /// stage may read.
    max_per_stage_resources: u32,
    /// The same counted over a whole pipeline layout rather than one
    /// stage of it, with the two dynamic kinds counted apart: a dynamic
    /// descriptor takes an offset from CmdBindDescriptorSets, and one set
    /// holds `shader.MAX_DYNAMIC_OFFSETS` of them, which is these two
    /// added together so that a layout within them always fits in a set.
    max_descriptor_set_samplers: u32,
    max_descriptor_set_uniform_buffers: u32,
    max_descriptor_set_uniform_buffers_dynamic: u32,
    max_descriptor_set_storage_buffers: u32,
    max_descriptor_set_storage_buffers_dynamic: u32,
    max_descriptor_set_sampled_images: u32,
    max_descriptor_set_storage_images: u32,
    max_descriptor_set_input_attachments: u32,

    // --- the vertex stage ---
    /// The attributes of a vertex and the vertex buffers bound at
    /// once, the offset of an attribute within its vertex, and the
    /// stride from one vertex to the next.
    max_vertex_input_attributes: u32,
    max_vertex_input_bindings: u32,
    max_vertex_input_attribute_offset: u32,
    max_vertex_input_binding_stride: u32,
    /// The floats a vertex function hands on, past the position:
    /// what is mixed over a triangle.
    max_vertex_output_components: u32,

    // --- the tessellation stages ---
    /// How finely a patch may be cut up, and the vertices a patch
    /// may have (`_instance.max_patch_points`).
    max_tessellation_generation_level: u32,
    max_tessellation_patch_size: u32,
    /// The floats a control function reads of each vertex and writes
    /// for each vertex, the floats it writes for the whole patch
    /// (`shader.Patch.ownValues`), and all of its output together.
    max_tessellation_control_per_vertex_input_components: u32,
    max_tessellation_control_per_vertex_output_components: u32,
    max_tessellation_control_per_patch_output_components: u32,
    max_tessellation_control_total_output_components: u32,
    /// The floats an evaluation function reads of each vertex and
    /// writes for each vertex it makes.
    max_tessellation_evaluation_input_components: u32,
    max_tessellation_evaluation_output_components: u32,

    // --- the geometry stage ---
    /// The geometry stage's limits. All zero: there is no geometry
    /// stage here, which is what `geometry_shader` says, and Vulkan
    /// asks for these numbers only of an implementation that has one.
    max_geometry_shader_invocations: u32,
    max_geometry_input_components: u32,
    max_geometry_output_components: u32,
    max_geometry_output_vertices: u32,
    max_geometry_total_output_components: u32,

    // --- the fragment stage ---
    /// The floats a fragment function reads of what was mixed over
    /// the triangle: the other end of `max_vertex_output_components`.
    max_fragment_input_components: u32,
    /// The colour attachments one fragment function may write, the
    /// two it may write for dual-source blending, and its
    /// attachments and storage resources counted together.
    max_fragment_output_attachments: u32,
    max_fragment_dual_src_attachments: u32,
    max_fragment_combined_output_resources: u32,

    // --- a compute dispatch ---
    /// A compute workgroup: the bytes its invocations share
    /// (`shader.Groups.shared`), the groups a dispatch may hold along
    /// each axis, the invocations one group may hold in all - a group
    /// runs on one core, one call of the function, so this is how long
    /// a loop it is - and the invocations it may declare along each
    /// axis (`shader.computeGroup`).
    max_compute_shared_memory_size: u32,
    max_compute_work_group_count: [3]u32,
    max_compute_work_group_invocations: u32,
    max_compute_work_group_size: [3]u32,

    // --- how finely a thing is placed and sampled ---
    /// The fraction bits a vertex's position, a texel's coordinate and
    /// a mipmap level are worked out to.
    sub_pixel_precision_bits: u32,
    sub_texel_precision_bits: u32,
    mipmap_precision_bits: u32,
    /// The largest index value a draw may use, and the draws one
    /// indirect buffer may hold.
    max_draw_indexed_index_value: u32,
    max_draw_indirect_count: u32,
    /// The mipmap levels a sampler may be biased by
    /// (`SamplerCreateInfo.lod_bias`).
    max_sampler_lod_bias: f32,
    /// The samples a sampler may take along the longer axis
    /// (`SamplerCreateInfo.max_anisotropy`); 1 where there is no
    /// anisotropic filtering, which is the value Vulkan asks for of a
    /// device without `sampler_anisotropy`.
    max_sampler_anisotropy: f32,

    // --- viewports ---
    /// The viewports and scissor rectangles bound at once, how wide and
    /// high one may be, how far outside the framebuffer its corners may
    /// lie, and the fraction bits its position is worked out to.
    max_viewports: u32,
    max_viewport_dimensions: [2]u32,
    viewport_bounds_range: [2]f32,
    viewport_sub_pixel_bits: u32,

    // --- how memory and offsets are aligned ---
    /// What MapMemory's address is aligned to at least: Vulkan's
    /// `size_t`, so `usize` here, four bytes wide on a 32-bit chip and
    /// eight on this one.
    min_memory_map_alignment: usize align(4),
    /// What a texel buffer's, a uniform buffer's and a storage
    /// buffer's offset in its memory must be aligned to.
    min_texel_buffer_offset_alignment: u64 align(4),
    min_uniform_buffer_offset_alignment: u64 align(4),
    min_storage_buffer_offset_alignment: u64 align(4),

    // --- sampling at an offset from the coordinate given ---
    /// How far a constant offset may reach from the coordinate a
    /// sample was taken at, and the same for a gather of four texels.
    /// The lowest is negative and the highest one less in magnitude,
    /// which is Vulkan's asymmetry and not a slip.
    min_texel_offset: i32,
    max_texel_offset: u32,
    min_texel_gather_offset: i32,
    max_texel_gather_offset: u32,
    /// How far from a pixel's centre a fragment function may ask for
    /// what was mixed, and the fraction bits of that offset. All zero
    /// where only the centre is sampled.
    min_interpolation_offset: f32,
    max_interpolation_offset: f32,
    sub_pixel_interpolation_offset_bits: u32,

    // --- framebuffers, and the samples a pixel may hold ---
    /// The widest and highest framebuffer, and the layers one may have.
    max_framebuffer_width: u32,
    max_framebuffer_height: u32,
    max_framebuffer_layers: u32,
    /// The samples a pixel may hold, as a bitmask of
    /// `SampleCountFlagBits` and not a count: for a colour, a
    /// depth, a stencil attachment, and for a subpass with no
    /// attachment at all. `SAMPLE_COUNT_1` alone where there is no
    /// multisampling, which is where this library stands - Vulkan
    /// requires four, so that single bit is a defect and not a
    /// choice (docs/facet-vulkan10.md item 61).
    framebuffer_color_sample_counts: u32,
    framebuffer_depth_sample_counts: u32,
    framebuffer_stencil_sample_counts: u32,
    framebuffer_no_attachments_sample_counts: u32,
    /// The colour attachments of a subpass (`_render.most_colors`).
    max_color_attachments: u32,
    /// The samples an image may hold to be sampled from, by what it
    /// holds: a colour format, a whole-number format, a depth, a
    /// stencil, and a storage image. One bit each here, as above.
    sampled_image_color_sample_counts: u32,
    sampled_image_integer_sample_counts: u32,
    sampled_image_depth_sample_counts: u32,
    sampled_image_stencil_sample_counts: u32,
    storage_image_sample_counts: u32,
    /// The 32-bit words of a sample mask that
    /// `PipelineMultisampleStateCreateInfo.sample_mask` may hold. One:
    /// Vulkan reads ceil(rasterization_samples / 32) of them and ignores
    /// the bits above the sample count, so with one sample a pixel the
    /// mask is bit 0 alone. A pipeline that clears it covers no sample and
    /// draws nothing.
    max_sample_mask_words: u32,
    /// Whether every queue that draws or computes also writes
    /// timestamps, which saves a program looking at each queue
    /// family's `timestamp_valid_bits`.
    timestamp_compute_and_graphics: Bool32,
    /// The nanoseconds one step of a timestamp is (CmdWriteTimestamp):
    /// a difference of two times this many nanoseconds. Vulkan's float,
    /// so a period that is not a whole number of nanoseconds can be
    /// said - `timestamp_period_ns`, a u32, could not. 0 where the
    /// device writes no timestamps.
    timestamp_period: f32,

    // --- clipping, culling, and the queue's priorities ---
    /// The clip distances, cull distances, and the two together a
    /// shader may write. All zero: neither built-in is in the SPIR-V
    /// profile (`shader_clip_distance`, `shader_cull_distance`).
    max_clip_distances: u32,
    max_cull_distances: u32,
    max_combined_clip_and_cull_distances: u32,
    /// How many priorities a queue may be made with that the device
    /// tells apart: 2 means the ends of the range and nothing
    /// between.
    discrete_queue_priorities: u32,

    // --- points and lines wider than one pixel ---
    /// The narrowest and widest point a draw of points makes, and the
    /// same for the width of a line, in pixels. A vertex function says
    /// the size of its own point (`shader.Vertices.setPointSize`) and it
    /// is held inside this, so a size of 0 draws the one pixel a point
    /// always was and one above the end draws the end.
    point_size_range: [2]f32,
    line_width_range: [2]f32,
    /// The step between two sizes the device tells apart, in pixels,
    /// and 0 here: every size between the ends of the range is drawn
    /// as it is, the widening working in floats.
    point_size_granularity: f32,
    line_width_granularity: f32,
    /// Whether a line is rasterized exactly as the specification draws
    /// one, and whether a multisampled pixel's sample positions are
    /// Vulkan's standard ones.
    strict_lines: Bool32,
    standard_sample_locations: Bool32,

    // --- copies, and memory the host shares ---
    /// What a buffer's offset and a row's length should be aligned to
    /// for a copy between a buffer and an image to go the fast way.
    optimal_buffer_copy_offset_alignment: u64 align(4),
    optimal_buffer_copy_row_pitch_alignment: u64 align(4),
    /// The bytes FlushMappedMemoryRanges and
    /// InvalidateMappedMemoryRanges work in: an offset and a size are
    /// rounded out to this.
    non_coherent_atom_size: u64 align(4),
};

/// The longest name a device has, its NUL included:
/// `VK_MAX_PHYSICAL_DEVICE_NAME_SIZE`. 64 until 1.82, where Vulkan has
/// always asked for 256.
pub const MAX_PHYSICAL_DEVICE_NAME_SIZE = 256;

/// The bytes of a UUID: `VK_UUID_SIZE`.
pub const UUID_SIZE = 16;

/// What a device does with memory bound a piece at a time, as
/// `PhysicalDeviceProperties.sparse_properties` says:
/// `VkPhysicalDeviceSparseProperties`.
///
/// Every one of these is false here, and says nothing more than that,
/// because no device of this library binds memory sparsely - `sparse_binding`
/// and the eight `sparse_residency_*` features are all false, and Vulkan
/// leaves these five meaningless where they are. Vulkan 1.0 requires the
/// structure all the same, so a program reading one gets five honest falses
/// rather than whatever lay past the end of the properties.
pub const PhysicalDeviceSparseProperties = extern struct {
    /// Standard sparse block shapes for 2D, multisampled 2D and 3D images.
    residency_standard_2d_block_shape: Bool32 = FALSE,
    residency_standard_2d_multisample_block_shape: Bool32 = FALSE,
    residency_standard_3d_block_shape: Bool32 = FALSE,
    /// Mip levels smaller than the sparse block are aligned, rather than
    /// gathered into one tail.
    residency_aligned_mip_size: Bool32 = FALSE,
    /// Reading an unbound texel gives zero rather than something undefined.
    residency_non_resident_strict: Bool32 = FALSE,
};

/// What a physical device is: `VkPhysicalDeviceProperties`, member for
/// member, as `scripts/vulkan-struct-check.sh` holds it.
pub const PhysicalDeviceProperties = extern struct {
    /// The interface it has (`makeApiVersion`), which is
    /// `API_VERSION_1_0`, and the library's own version and revision
    /// packed the same way - Vulkan leaves a driver's version to whoever
    /// wrote the driver.
    api_version: u32,
    driver_version: u32,
    vendor_id: u32,
    device_id: u32,
    device_type: PhysicalDeviceType,
    device_name: [MAX_PHYSICAL_DEVICE_NAME_SIZE]u8,
    /// What a pipeline cache made on this device belongs to. Vulkan asks
    /// that it change whenever anything that could make a cached pipeline
    /// wrong changes, so a program may keep a cache across runs and know
    /// when to throw it away. Here it is the driver module's own stamp -
    /// the sum of the library's version and of every shape a module and
    /// the library share (`driver/_driver.zig`) - mixed with what names the
    /// device, so it moves when the library is rebuilt, when a driver is
    /// rebuilt against another library, or when the device is a different
    /// one. (Since 1.82; there was no such member before it.)
    pipeline_cache_uuid: [UUID_SIZE]u8,
    limits: PhysicalDeviceLimits,
    sparse_properties: PhysicalDeviceSparseProperties,
};

/// What a physical device does, as GetPhysicalDeviceFeatures answers:
/// `VkPhysicalDeviceFeatures`, member for member, as
/// `scripts/vulkan-struct-check.sh` holds it.
///
/// Vulkan's 55 members in Vulkan's order, each a `Bool32` and so four bytes
/// wide: 220 bytes in all. Until 1.82 this was 49 fields of facet's own
/// naming, Zig `bool` and one byte each, 49 bytes - a structure a conformant
/// caller could not read at all. Those 49 are the library's own record of
/// what each device cannot do and live on as `Capabilities`
/// (instance/_instance.zig), which is what the library's refusals read;
/// about thirty-five of them gate things Vulkan 1.0 requires
/// unconditionally, so they are defects written down rather than features
/// offered.
///
/// Where each of these comes from on each device, and why, is written in
/// instance/getphysicaldevicefeatures.zig: the answers are made from the
/// device's `Capabilities` and from what the library implements at all,
/// never from what would be convenient to claim.
///
/// There is no `DeviceCreateInfo.pEnabledFeatures` step in Vulkan's sense
/// here. `DeviceCreateInfo.enabled_features` is read and anything asked for
/// that the device does not have is refused with
/// `error_feature_not_present`, which Vulkan requires; what Vulkan leaves
/// undefined - using a feature without having enabled it - this library
/// refuses at the call instead, which is a permitted way to implement
/// undefined behaviour and the more useful one.
pub const PhysicalDeviceFeatures = extern struct {

    // --- the draw and its state ---
    /// Reading or writing outside a buffer's bound range is caught rather
    /// than undefined: a read gives zero or a value from somewhere in the
    /// same buffer, and a write outside is dropped.
    robust_buffer_access: Bool32 = FALSE,
    /// A 32-bit index may use its whole range. Without it the largest index
    /// value is 2^24-1 (`maxDrawIndexedIndexValue`).
    full_draw_index_uint32: Bool32 = FALSE,
    /// A cube image may be an array of cubes, and a view of one.
    image_cube_array: Bool32 = FALSE,
    /// Each colour attachment blends by its own state, rather than every one
    /// of them by the first's.
    independent_blend: Bool32 = FALSE,
    /// The geometry stage.
    geometry_shader: Bool32 = FALSE,
    /// The tessellation control and evaluation stages.
    tessellation_shader: Bool32 = FALSE,
    /// A fragment function run once a sample rather than once a pixel
    /// (`min_sample_shading`).
    sample_rate_shading: Bool32 = FALSE,
    /// The blend factors that read a second source colour.
    dual_src_blend: Bool32 = FALSE,
    /// `PipelineColorBlendStateCreateInfo.logic_op_enable`.
    logic_op: Bool32 = FALSE,
    /// More than one draw in an indirect buffer.
    multi_draw_indirect: Bool32 = FALSE,
    /// A `first_instance` other than zero in an indirect draw.
    draw_indirect_first_instance: Bool32 = FALSE,
    /// `PipelineRasterizationStateCreateInfo.depth_clamp_enable`: what lies
    /// past the near plane is drawn all the same, each pixel's depth held
    /// inside the viewport's, rather than cut away.
    depth_clamp: Bool32 = FALSE,
    /// `depth_bias_clamp`: a bound on how far a triangle's depth is moved.
    depth_bias_clamp: Bool32 = FALSE,
    /// A triangle drawn as its edges or its corners: `POLYGON_MODE_LINE`
    /// and `POLYGON_MODE_POINT`.
    fill_mode_non_solid: Bool32 = FALSE,
    /// `depth_bounds_test_enable`: a pixel is drawn only where the depth
    /// already there lies between two numbers, whatever depth is being drawn.
    depth_bounds: Bool32 = FALSE,
    /// A line wider than one pixel (`line_width`, `lineWidthRange`).
    wide_lines: Bool32 = FALSE,
    /// A point wider than one pixel (`point_size_range`).
    large_points: Bool32 = FALSE,
    /// `alpha_to_one_enable`: the alpha a fragment wrote is forced to one.
    alpha_to_one: Bool32 = FALSE,
    /// More than one viewport and scissor rectangle at once.
    multi_viewport: Bool32 = FALSE,
    /// A sampler that takes more than one sample along the longer axis
    /// (`SamplerCreateInfo.max_anisotropy`, `maxSamplerAnisotropy`).
    sampler_anisotropy: Bool32 = FALSE,
    /// The ETC2 and EAC formats, sampled from their blocks.
    texture_compression_etc2: Bool32 = FALSE,
    /// The ASTC LDR formats, sampled from their blocks.
    texture_compression_astc_ldr: Bool32 = FALSE,
    /// The BC formats, sampled from their blocks.
    texture_compression_bc: Bool32 = FALSE,
    /// An occlusion query that counts the samples which passed, rather than
    /// only saying whether any did.
    occlusion_query_precise: Bool32 = FALSE,
    /// `QueryType.pipeline_statistics`.
    pipeline_statistics_query: Bool32 = FALSE,
    /// A vertex, tessellation or geometry function writing a storage buffer
    /// or a storage image, and the atomic operations on them.
    vertex_pipeline_stores_and_atomics: Bool32 = FALSE,
    /// The same from a fragment function.
    fragment_stores_and_atomics: Bool32 = FALSE,
    /// `PointSize` written from a tessellation or a geometry function.
    shader_tessellation_and_geometry_point_size: Bool32 = FALSE,

    // --- what a shader may contain ---
    /// `OpImage*Gather` with a component chosen and with offsets.
    shader_image_gather_extended: Bool32 = FALSE,
    /// The storage-image formats past the small set Vulkan requires.
    shader_storage_image_extended_formats: Bool32 = FALSE,
    /// A storage image of more than one sample.
    shader_storage_image_multisample: Bool32 = FALSE,
    /// A storage image read without its format given in the shader.
    shader_storage_image_read_without_format: Bool32 = FALSE,
    /// The same for a write.
    shader_storage_image_write_without_format: Bool32 = FALSE,
    /// An array of uniform-buffer descriptors indexed by a value the shader
    /// works out rather than a constant.
    shader_uniform_buffer_array_dynamic_indexing: Bool32 = FALSE,
    /// The same for sampled images and samplers.
    shader_sampled_image_array_dynamic_indexing: Bool32 = FALSE,
    /// The same for storage buffers.
    shader_storage_buffer_array_dynamic_indexing: Bool32 = FALSE,
    /// The same for storage images.
    shader_storage_image_array_dynamic_indexing: Bool32 = FALSE,
    /// The `ClipDistance` built-in.
    shader_clip_distance: Bool32 = FALSE,
    /// The `CullDistance` built-in.
    shader_cull_distance: Bool32 = FALSE,
    /// 64-bit floats in a shader.
    shader_float64: Bool32 = FALSE,
    /// 64-bit integers in a shader.
    shader_int64: Bool32 = FALSE,
    /// 16-bit integers in a shader.
    shader_int16: Bool32 = FALSE,
    /// A shader asking whether a sparse resource's texel is bound.
    shader_resource_residency: Bool32 = FALSE,
    /// `MinLod` on an image operation.
    shader_resource_min_lod: Bool32 = FALSE,

    // --- memory bound a piece at a time ---
    /// Memory bound to a resource a piece at a time.
    sparse_binding: Bool32 = FALSE,
    /// A buffer only partly bound.
    sparse_residency_buffer: Bool32 = FALSE,
    /// A 2D image only partly bound.
    sparse_residency_image_2d: Bool32 = FALSE,
    /// A 3D image only partly bound.
    sparse_residency_image_3d: Bool32 = FALSE,
    /// A partly bound image of 2, 4, 8 and 16 samples.
    sparse_residency_2_samples: Bool32 = FALSE,
    sparse_residency_4_samples: Bool32 = FALSE,
    sparse_residency_8_samples: Bool32 = FALSE,
    sparse_residency_16_samples: Bool32 = FALSE,
    /// Two sparse resources sharing the memory bound behind them.
    sparse_residency_aliased: Bool32 = FALSE,

    // --- the rest ---
    /// A subpass with no attachments may be drawn at a sample rate other
    /// than another subpass's.
    variable_multisample_rate: Bool32 = FALSE,
    /// A secondary command buffer run inside a query its primary began
    /// (`CommandBufferInheritanceInfo`).
    inherited_queries: Bool32 = FALSE,
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
    /// The sample counts as bits, as Vulkan has them: 1, and 4 as well
    /// for an image of the shape that may have four samples a pixel, on a
    /// device that draws them (since 1.98).
    sample_counts: u32 = 0,
    /// The bytes an image of `max_extent`, of `max_mip_levels` levels and
    /// of `max_array_layers` layers takes - what
    /// GetImageMemoryRequirements answers for such an image (since 1.66,
    /// where it was the largest heap's size before). More memory than any
    /// heap holds, where the largest extent and the most layers meet:
    /// AllocateMemory is what finds that out.
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
    /// The features the program means to use, as
    /// GetPhysicalDeviceFeatures answered them for this device:
    /// `VkDeviceCreateInfo.pEnabledFeatures`. Null asks for none, which is
    /// what Vulkan's null means too.
    ///
    /// Any feature asked for that the device has not got makes the device
    /// `error_feature_not_present`, which Vulkan requires of vkCreateDevice.
    /// What Vulkan then leaves *undefined* - using a feature without having
    /// asked for it - this library does not: every call that would use one
    /// checks the device and refuses, as it did before this field existed,
    /// so a program that asks for nothing is not thereby given a device
    /// that behaves unpredictably. Vulkan permits an implementation to do
    /// anything at all in that case, and refusing is the useful thing to do.
    ///
    /// (Since 1.82; there was no counterpart to Vulkan's enable step before
    /// it, which is docs/facet-vulkan10.md item 49.)
    enabled_features: ?*const PhysicalDeviceFeatures = null,
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
    /// (`Capabilities.small_texels`, since 1.48).
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
    /// One channel of red, and two of red and green: a block is the very
    /// block BC3 keeps its alpha in - two endpoints and three bits for
    /// each texel between them - over one channel and over two. BC4 is 8
    /// bytes for its sixteen texels and BC5 is 16, and they read as
    /// (red, 0, 0, 1) and (red, green, 0, 1), as Vulkan reads a format of
    /// fewer channels. The `_snorm` pair is not here: a texture holds 0
    /// to 1. (Since 1.72.)
    bc4_unorm_block = 139,
    bc5_unorm_block = 141,
    /// Three channels of half float in 16 bytes a block, and no alpha:
    /// the one of these to hold a texture whose channels run past 1 - a
    /// light probe, a sky, an exposure a frame is drawn from. The block
    /// is cut into one subset or two as BC7's is, and one of fourteen
    /// modes says how many bits the first endpoint's channels take and
    /// how many the others take as offsets on it. `_ufloat` holds nothing
    /// under 0 and `_sfloat` runs either way. A sample reads the texel
    /// held between 0 and 1 and rounded to 8 bits, the way a float
    /// texture's is, and `texture.Texture.partsAt` gives a function the
    /// halves themselves. (Since 1.74.)
    bc6h_ufloat_block = 143,
    bc6h_sfloat_block = 144,
    /// Four channels in the same 16 bytes a block: subsets cut out of the
    /// block by one of 64 patterns, two endpoints for each, and an index
    /// for every texel - one of eight modes saying how many bits each of
    /// those takes and whether the alpha is indexed apart from the
    /// colour. The one block of these to hold a smooth alpha and a sharp
    /// colour at once, at a quarter of the memory the texels take. The
    /// `_srgb` form is not here: a texture of this library is read as it
    /// lies. (Since 1.73.)
    bc7_unorm_block = 145,
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
    /// The formats a texel buffer reads and no image is kept in (since
    /// 1.54): a whole number of 8, 16 or 32 bits a channel, signed or
    /// not, and a half-float; one channel, two or four. A view of one
    /// reads the buffer where it lies (`CreateBufferView`,
    /// `shader.Texels`), so these say `UNIFORM_TEXEL_BUFFER` and
    /// `STORAGE_TEXEL_BUFFER` in `buffer_features` and nothing else.
    /// `_unorm` is read as 0 to 1, `_uint` and `_sint` as the number
    /// itself, `_sfloat` as the float.
    r8g8_unorm = 16,
    r8_uint = 13,
    r8g8_uint = 20,
    r8g8b8a8_uint = 41,
    r8_sint = 14,
    r8g8_sint = 21,
    r8g8b8a8_sint = 42,
    r16_unorm = 70,
    r16g16_unorm = 77,
    r16g16b16a16_unorm = 91,
    r16_uint = 74,
    r16g16_uint = 81,
    r16g16b16a16_uint = 95,
    r16_sint = 75,
    r16g16_sint = 82,
    r16g16b16a16_sint = 96,
    r16_sfloat = 76,
    r16g16_sfloat = 83,
    r32_uint = 98,
    r32g32_uint = 101,
    r32g32b32a32_uint = 107,
    r32_sint = 99,
    r32g32_sint = 102,
    r32g32b32a32_sint = 108,
    /// The rest of the texel-buffer formats, since 1.68, read where they
    /// lie as the others are (`shader.TexelFormat`), and no image kept in
    /// any of them either.
    /// `_snorm`: a whole number read as -1 to 1, the largest the channel
    /// holds either way standing for 1.
    r8_snorm = 10,
    r8g8_snorm = 17,
    r8g8b8a8_snorm = 38,
    r16_snorm = 71,
    r16g16_snorm = 78,
    r16g16b16a16_snorm = 92,
    /// `_srgb`: 8 bits a channel kept the way a picture is written down,
    /// read as linear 0 to 1 - the three colour channels through sRGB's
    /// transfer function, the alpha straight.
    r8_srgb = 15,
    r8g8_srgb = 22,
    r8g8b8a8_srgb = 43,
    b8g8r8a8_srgb = 50,
    /// The same bytes as `r8g8b8a8_unorm` and `r8g8b8a8_srgb` on a
    /// little-endian machine, which is every machine this library runs
    /// on: a word of 0xAABBGGRR.
    a8b8g8r8_unorm_pack32 = 51,
    a8b8g8r8_srgb_pack32 = 57,
    /// Three channels of 10 bits and an alpha of 2 in one word, as 0 to 1
    /// or as the whole numbers themselves.
    a2r10g10b10_unorm_pack32 = 58,
    a2r10g10b10_uint_pack32 = 62,
    a2b10g10r10_unorm_pack32 = 64,
    a2b10g10r10_uint_pack32 = 68,
    /// Three channels of 32 bits, whole, beside the `r32g32b32_sfloat`
    /// that was there already. The three-channel formats of 8 and of 16
    /// bits are not here, 3 or 6 bytes a texel being what almost no
    /// hardware carries either.
    r32g32b32_uint = 104,
    r32g32b32_sint = 105,
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
    /// A depth or stencil attachment read and not written: tested
    /// against, or read by a function, after the pass that stored it.
    /// (Since 1.80.)
    depth_stencil_read_only_optimal = 4,
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
/// (`Capabilities.storage_images`). It is kept the way a sampled
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
/// built for. Refused where `Capabilities.small_texels` is
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
/// `Capabilities.several_outputs` is false, and with
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
    /// Samples a pixel: 1, or 4 on a device that draws them
    /// (`Capabilities.multisampling`, since 1.98), for a 2D image of one
    /// level in optimal tiling that is an attachment (`CreateImage`).
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
    /// The layers of a 1D image, one row each (since 1.86).
    @"1d_array" = 4,
    @"2d_array" = 5,
    /// Cubes one after another, six layers to each: the view's layers are a
    /// multiple of six and its first a multiple of six, for
    /// `shader.FixedKind.texture_cube_array` and, since 1.53,
    /// `texture_cube_array_sampled`. (Since 1.46.)
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

/// A rectangle of a multisampled image whose samples CmdResolveImage
/// averages into the pixels of an image of one sample, `dst_offset` on
/// (since 1.101).
pub const ImageResolve = extern struct {
    src_subresource: ImageSubresourceLayers = .{},
    src_offset: Offset3D = .{},
    dst_subresource: ImageSubresourceLayers = .{},
    dst_offset: Offset3D = .{},
    extent: Extent3D,
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
    /// `Capabilities.sampler_anisotropy` says where that happens,
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
    /// Coordinates in texels of the texture rather than 0 to 1 across it,
    /// for a program that reads a texture as a table of values (since
    /// 1.67, where `Capabilities.unnormalized_coordinates` says
    /// which devices have it). Vulkan allows it beside little else: one
    /// filter for both, `nearest` mipmapping, `min_lod` and `max_lod` 0,
    /// no anisotropy, no comparison, and `address_mode_u` and
    /// `address_mode_v` either `clamp_to_edge` or `clamp_to_border` -
    /// anything else is `error_initialization_failed`.
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
/// barrier or a semaphore's wait takes effect. The bits are Vulkan's, all
/// of VkPipelineStageFlagBits' core ones since 1.80 - a program ported
/// from Vulkan finds every name, including the stages this library has
/// not got.
pub const PIPELINE_STAGE_TOP_OF_PIPE: u32 = 1 << 0;
/// Where a draw or a dispatch reads its own numbers out of a buffer
/// (CmdDrawIndirect, CmdDrawIndexedIndirect, CmdDispatchIndirect).
/// (Since 1.80.)
pub const PIPELINE_STAGE_DRAW_INDIRECT: u32 = 1 << 1;
pub const PIPELINE_STAGE_VERTEX_INPUT: u32 = 1 << 2;
pub const PIPELINE_STAGE_VERTEX_SHADER: u32 = 1 << 3;
/// Where a patch's control function runs (`shader.control`).
/// (Since 1.80.)
pub const PIPELINE_STAGE_TESSELLATION_CONTROL_SHADER: u32 = 1 << 4;
/// Where a patch's evaluation function runs. (Since 1.80.)
pub const PIPELINE_STAGE_TESSELLATION_EVALUATION_SHADER: u32 = 1 << 5;
/// Vulkan's name for a stage this library has not got: there are no
/// geometry functions. (Since 1.80.)
pub const PIPELINE_STAGE_GEOMETRY_SHADER: u32 = 1 << 6;
pub const PIPELINE_STAGE_FRAGMENT_SHADER: u32 = 1 << 7;
pub const PIPELINE_STAGE_EARLY_FRAGMENT_TESTS: u32 = 1 << 8;
pub const PIPELINE_STAGE_LATE_FRAGMENT_TESTS: u32 = 1 << 9;
pub const PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT: u32 = 1 << 10;
/// Where a dispatched function runs (CmdDispatch). (Since 1.80.)
pub const PIPELINE_STAGE_COMPUTE_SHADER: u32 = 1 << 11;
pub const PIPELINE_STAGE_TRANSFER: u32 = 1 << 12;
pub const PIPELINE_STAGE_BOTTOM_OF_PIPE: u32 = 1 << 13;
pub const PIPELINE_STAGE_HOST: u32 = 1 << 14;
pub const PIPELINE_STAGE_ALL_GRAPHICS: u32 = 1 << 15;
pub const PIPELINE_STAGE_ALL_COMMANDS: u32 = 1 << 16;

/// What work reads or writes, on either side of a barrier. The bits are
/// Vulkan's, all of VkAccessFlagBits' core ones since 1.80.
///
/// This first bit is what a draw or a dispatch reads of its own numbers
/// out of a buffer (CmdDrawIndirect, CmdDispatchIndirect). (Since 1.80.)
pub const ACCESS_INDIRECT_COMMAND_READ: u32 = 1 << 0;
pub const ACCESS_INDEX_READ: u32 = 1 << 1;
pub const ACCESS_VERTEX_ATTRIBUTE_READ: u32 = 1 << 2;
pub const ACCESS_UNIFORM_READ: u32 = 1 << 3;
/// What a fragment function reads of an input attachment, pixel by pixel
/// (`shader.Attachment`, IMAGE_USAGE_INPUT_ATTACHMENT). (Since 1.80.)
pub const ACCESS_INPUT_ATTACHMENT_READ: u32 = 1 << 4;
pub const ACCESS_SHADER_READ: u32 = 1 << 5;
/// What a function writes through a storage image or a storage buffer
/// (IMAGE_USAGE_STORAGE). (Since 1.80.)
pub const ACCESS_SHADER_WRITE: u32 = 1 << 6;
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
    /// Samples a pixel: 1, or 4 on a device that draws them
    /// (`Capabilities.multisampling`, since 1.100). Every attachment a
    /// subpass draws into or tests against holds the same count.
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
    /// Null, or one for each colour attachment: the attachment of one
    /// sample and the colour's format that its four samples are averaged
    /// into as the subpass ends, or `ATTACHMENT_UNUSED` for none (since
    /// 1.100).
    resolve_attachments: ?[*]const AttachmentReference = null,
    depth_stencil_attachment: ?*const AttachmentReference = null,
    preserve_attachment_count: u32 = 0,
    preserve_attachments: ?[*]const u32 = null,
};

/// SubpassDependency's subpass for the work outside the pass.
pub const SUBPASS_EXTERNAL: u32 = ~@as(u32, 0);

/// SubpassDependency.dependency_flags: the work depends on what was
/// written at the same pixel alone, which is what lets a subpass read the
/// attachment it is drawing into (`CreateRenderPass`, since 1.64).
pub const DEPENDENCY_BY_REGION: u32 = 0x1;

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
/// Vulkan's name for a stage this library has not got: there are no
/// geometry functions, and `SHADER_STAGE_ALL_GRAPHICS` has always
/// included this bit without a name for it. (Since 1.80.)
pub const SHADER_STAGE_GEOMETRY: u32 = 0x08;
pub const SHADER_STAGE_FRAGMENT: u32 = 0x10;
pub const SHADER_STAGE_COMPUTE: u32 = 0x20;
pub const SHADER_STAGE_ALL_GRAPHICS: u32 = 0x1F;

/// What a shader module is made with.
pub const ShaderModuleCreateInfo = extern struct {
    /// `SHADER_MODULE_CREATE_SPIRV` where `code` is a `shader.Module`.
    flags: u32 = 0,
    /// The bytes of `code`: @sizeOf(shader.Code), or
    /// @sizeOf(shader.Module) where the words are there too.
    code_size: usize = @sizeOf(shader.Code),
    /// A `shader.Code` - the Zig functions - or, with the flag above, a
    /// `shader.Module`, which is those and the SPIR-V beside them.
    code: *const anyopaque,
};

/// `code` is a `shader.Module` and not a `shader.Code`: the entries ship
/// their SPIR-V as well, for a device that compiles. A library without
/// this flag reads the same memory as a `shader.Code` and runs the Zig
/// functions, so a program may always pass it. (Since 1.75.)
pub const SHADER_MODULE_CREATE_SPIRV: u32 = 0x01;

/// Where one specialization constant's value is: which constant, where
/// in `SpecializationInfo.data` its bytes start, and how many of them.
/// Vulkan's `VkSpecializationMapEntry`. (Since 1.80.)
pub const SpecializationMapEntry = extern struct {
    /// The constant's id, as the SPIR-V's `SpecId` decoration gives it.
    constant_id: u32,
    /// Where its value starts in `SpecializationInfo.data`.
    offset: u32,
    /// Its bytes there.
    size: usize,
};

/// The specialization constants one stage of a pipeline is made with:
/// the entries and the bytes they point into. Vulkan's
/// `VkSpecializationInfo`.
///
/// facet.library does not specialise a shader yet, so a stage that
/// carries one is **refused**, with `error_feature_not_present`, rather
/// than made with the constants quietly dropped: a pipeline that ignored
/// them would draw something the program did not ask for
/// (CreateGraphicsPipelines, CreateComputePipelines). The type is here so
/// a program may be written against Vulkan's shape now and work when the
/// constants are honoured. (Since 1.80.)
pub const SpecializationInfo = extern struct {
    map_entry_count: u32 = 0,
    map_entries: ?[*]const SpecializationMapEntry = null,
    data_size: usize = 0,
    data: ?*const anyopaque = null,
};

/// A shader stage of a pipeline: the module's function for it.
pub const PipelineShaderStageCreateInfo = extern struct {
    flags: u32 = 0,
    /// SHADER_STAGE_VERTEX or SHADER_STAGE_FRAGMENT.
    stage: u32,
    module: *ShaderModule,
    /// The entry's name in the module.
    name: [*:0]const u8 = "main",
    /// The constants this stage is specialised with, or null. Not
    /// honoured: a stage that carries one has its pipeline refused with
    /// `error_feature_not_present` (since 1.80, which also gave the
    /// field Vulkan's own type - it was `?*const anyopaque`, and read by
    /// nothing, before; a nullable pointer either way, so the shape of
    /// this struct has not changed).
    specialization_info: ?*const SpecializationInfo = null,
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
    /// `Capabilities.depth_bias` is true; what
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
    /// The subpass's own count: 1, or 4 on a device that draws them
    /// (`Capabilities.multisampling`, since 1.100).
    rasterization_samples: u32 = 1,
    sample_shading_enable: bool = false,
    min_sample_shading: f32 = 0,
    sample_mask: ?[*]const u32 = null,
    /// Colour 0's alpha cuts the samples each pixel covers, dithered by
    /// the pixel's place: on the cores since 1.108, and refused by the V3D
    /// until step V6 of item 61 of docs/facet-vulkan10.md.
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
    /// own since 1.33 (`Capabilities.independent_blend`).
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
    /// cannot change (`Capabilities.immutable_samplers`, since
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
