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
//! next frame, through its layer.

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
    /// Bytes red, green, blue, alpha: 0xAABBGGRR as a 32-bit word.
    r8g8b8a8_unorm = 37,
    /// Bytes blue, green, red, alpha: 0xAARRGGBB as a 32-bit word - the
    /// order the rasterizer keeps its colours in.
    b8g8r8a8_unorm = 44,
    /// A float, two, three or four of them.
    r32_sfloat = 100,
    r32g32_sfloat = 103,
    r32g32b32_sfloat = 106,
    r32g32b32a32_sfloat = 109,
    /// 16 bits of depth: 0 nearest.
    d16_unorm = 124,
    _,
};

/// What a format does: FormatProperties' features.
pub const FORMAT_FEATURE_SAMPLED_IMAGE: u32 = 1 << 0;
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

/// BufferCreateInfo.usage: what a buffer is for.
pub const BUFFER_USAGE_TRANSFER_SRC: u32 = 1 << 0;
pub const BUFFER_USAGE_TRANSFER_DST: u32 = 1 << 1;
pub const BUFFER_USAGE_UNIFORM_BUFFER: u32 = 1 << 4;
pub const BUFFER_USAGE_STORAGE_BUFFER: u32 = 1 << 5;
pub const BUFFER_USAGE_INDEX_BUFFER: u32 = 1 << 6;
pub const BUFFER_USAGE_VERTEX_BUFFER: u32 = 1 << 7;

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
pub const IMAGE_USAGE_COLOR_ATTACHMENT: u32 = 1 << 4;
pub const IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT: u32 = 1 << 5;
/// Its pixels live in the tiles alone: memory of the lazily allocated
/// type will do.
pub const IMAGE_USAGE_TRANSIENT_ATTACHMENT: u32 = 1 << 6;

/// What an image is made with.
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
/// It may be submitted again while a submission of it is still pending.
pub const COMMAND_BUFFER_USAGE_SIMULTANEOUS_USE: u32 = 1 << 2;

/// How a command buffer is to be recorded.
pub const CommandBufferBeginInfo = extern struct {
    flags: u32 = 0,
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
pub const SHADER_STAGE_FRAGMENT: u32 = 0x10;
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
    attachments: ?[*]const PipelineColorBlendAttachmentState = null,
    blend_constants: [4]f32 = @splat(0),
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
pub const GraphicsPipelineCreateInfo = extern struct {
    flags: u32 = 0,
    stage_count: u32,
    stages: [*]const PipelineShaderStageCreateInfo,
    vertex_input_state: ?*const PipelineVertexInputStateCreateInfo = null,
    input_assembly_state: ?*const PipelineInputAssemblyStateCreateInfo = null,
    tessellation_state: ?*const anyopaque = null,
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

/// A descriptor's kind. facet.library has sampled images - sampled as
/// the fragment function says, with no sampler - and uniform and storage
/// buffers.
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
    immutable_samplers: ?*const anyopaque = null,
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

/// A sampled image written into a set.
pub const DescriptorImageInfo = extern struct {
    sampler: ?*const anyopaque = null,
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
    texel_buffer_view: ?*const anyopaque = null,
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
/// left alone. The window stays open for as long as the surface lasts.
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
