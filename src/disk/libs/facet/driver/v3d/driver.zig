// SPDX-License-Identifier: MIT
//! The second driver: the BCM2712's V3D 7.1, the 3D core of its VideoCore
//! VII, a module of its own in LIBS:facet/ (v3d_fdriver.zig). What knows the
//! hardware is the Zig module `v3d` (v3d.zig); this is its table, and
//! `_play.zig` a command buffer made into its control lists.
//!
//! The board part is what finds it: where the machine has no such part the
//! instance lists no device of it. It is switched on when a device first
//! wants it, and what that makes - the MMU's table, the interrupts, the
//! programs - stays while any queue, block of memory or pipeline's program
//! is left, in the one `Hardware` all the instances of the library share.
//! It goes back to nothing but stays powered: a second power-up after a
//! power-down halted the machine.
//!
//! Vertex functions stay the program's, and run on the cores; pixels are the
//! V3D's, and it has a program for each fixed form of fragment function
//! (shader.Fixed), so a pipeline with another fragment function is refused.
//!
//! **Its memory is one heap**, what DMA reaches, each block mapped for the
//! V3D as it is allocated. Only what the V3D reads has to reach it: vertices
//! and uniforms go out as a frame is sent (`_play.zig`), texels as they are
//! copied in, and an image drawn into is written back before and dropped
//! from the caches after, so that for a program the type is coherent.
//! Textures lie in the V3D's own layout (`tiling.zig`).

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const facet = sdk.facet;
const v3d = @import("v3d");
const ExecBase = sdk.interface.exec.ExecBase;
const facet_version = @import("../../facet_version.zig");
const FacetBase = @import("../../facet_base.zig").FacetBase;
const _objects = @import("../../_objects.zig");
const _render = @import("../../render/_render.zig");
const _instance = @import("../../instance/_instance.zig");
const PhysicalDevice = _instance.PhysicalDevice;
const Device = @import("../../device/_device.zig").Device;
const _memory = @import("../../memory/_memory.zig");
const DeviceMemory = _memory.DeviceMemory;
const Pipeline = @import("../../pipeline/_pipeline.zig").Pipeline;
const Queue = @import("../../queue/_queue.zig").Queue;
const CommandBuffer = @import("../../command/_command.zig").CommandBuffer;
const _driver = @import("../_driver.zig");
const _image = @import("../../image/_image.zig");
const _format = @import("../_format.zig");
const _play = @import("_play.zig");
const qpu = v3d.qpu;
const compile = v3d.compile;
const tiling = v3d.tiling;
const Block = v3d.Block;

pub const ops = _driver.Ops{
    .describe = &describe,
    .format_properties = &_format.properties,
    .allocate_memory = &allocateMemory,
    .free_memory = &freeMemory,
    .make_pipeline = &makePipeline,
    .unmake_pipeline = &unmakePipeline,
    .open_queue = &_play.open,
    .close_queue = &_play.close,
    .execute = &execute,
    .texture_offset = &textureOffset,
    .texture_memory = &textureMemory,
    .texture_level = &textureLevel,
    .picture_memory = exec.MEMF_DMA,
};

/// Where the programs are on the V3D.
pub const Programs = struct {
    coordinate: u32,
    vertex: [qpu.most_varyings + 1]u32,
    color: u32,
    texture: u32,
    texture_color: u32,
    array: u32,
    cube: u32,
    volume: u32,
    shadow: u32,
};

/// What the V3D has while anything uses it. Its job, and its table, are
/// one at a time: both are taken under `FacetBase.v3d_lock`.
pub const Hardware = struct {
    gpu: v3d.Gpu,
    space: v3d.Space,
    engine: v3d.Engine,
    /// The queues, the blocks of memory and the pipelines' programs that
    /// hold it.
    users: u32,
    programs_block: Block,
    programs: Programs,
    /// The table has changed since the MMU last read it.
    stale: bool = false,
    /// A job faulted or never ended. Nothing more is sent: what comes after
    /// it would be drawn over what it left.
    broken: bool = false,
};

fn describe(sys: *ExecBase, physical: *PhysicalDevice) callconv(.c) bool {
    if (v3d.Gpu.find(sys) == null) return false;
    physical.properties = .{
        .api_version = facet.API_VERSION_1_0,
        .driver_version = facet.makeVersion(facet_version.LIBRARY_VERSION, facet_version.LIBRARY_REVISION, 0),
        .vendor_id = 0x14E4,
        .device_id = 0x2712,
        .device_type = .integrated_gpu,
        .device_name = @splat(0),
        // Filled from the properties themselves once they are all here,
        // just below, so the UUID cannot fall out of step with them.
        .pipeline_cache_uuid = undefined,
        .sparse_properties = .{},
        // The library's own numbers, with what this hardware decides for
        // itself set over them. Everything not named here the V3D answers
        // for exactly as the cores do, because the library's own objects
        // decide it (`_instance.limits`).
        .limits = said: {
            var said = _instance.limits;
            // A program samples through the sampler bound beside its
            // texture, and the TMU is given all of it as v3dv packs it
            // (`tiling.samplerOf`, since 1.140): one a stage, as there is
            // one texture a stage below, since a program samples once.
            // The bias, the anisotropy and the precision are v3dv's for
            // this GPU (v3dv_device.c:1153, 1158, 1159); the bias is what
            // Vulkan asks at least 2 of, and the field holds -128 to just
            // under 128 (`tiling.SamplerState.bias`). A fixed form that
            // wants a sampler reads it the same way where this device
            // draws it (`samplesHere`, since 1.141).
            said.max_per_stage_descriptor_samplers = 1;
            said.max_descriptor_set_samplers = facet.shader.MAX_SETS;
            said.max_sampler_lod_bias = 14;
            said.max_sampler_anisotropy = 16;
            said.mipmap_precision_bits = 8;
            // The texture unit takes one texture a stage.
            said.max_per_stage_descriptor_sampled_images = 1;
            said.max_descriptor_set_sampled_images = facet.shader.MAX_SETS;
            // No storage image and no input attachment here
            // (`can.storage_images`, `can.input_attachments`).
            said.max_per_stage_descriptor_storage_images = 0;
            said.max_descriptor_set_storage_images = 0;
            said.max_per_stage_descriptor_input_attachments = 0;
            // A QPU fragment program writes one colour: the forms that
            // write several are refused here and drawn on the cores
            // (`can.several_outputs`). docs/facet-vulkan10.md item 55.
            said.max_fragment_output_attachments = 1;
            said.max_fragment_combined_output_resources = 1;
            said.max_descriptor_set_input_attachments = 0;
            // What this device will sample from, by what the image holds: a
            // colour, and a depth since 1.142 (`can.sampled_depth`), each
            // of one sample: one of four it draws into since 1.148 but
            // samples none, its TMU yet to fetch a sample where the frame
            // stored it (item 61's V7), so these two say the 1 bit alone
            // as `narrowSampleCounts` said it for them before. No
            // whole-number format (`can.whole_textures`), no stencil, no
            // storage image. A mask of no bits says the device samples no
            // image of that kind at all, which is what Vulkan means by it.
            said.sampled_image_color_sample_counts = facet.SAMPLE_COUNT_1;
            said.sampled_image_depth_sample_counts = facet.SAMPLE_COUNT_1;
            said.sampled_image_integer_sample_counts = 0;
            said.sampled_image_stencil_sample_counts = 0;
            said.storage_image_sample_counts = 0;
            // The rasterizer places an edge in 1/64 of a pixel, not 1/256,
            // and a point's or a line's width is told apart that finely
            // with it.
            said.sub_pixel_precision_bits = 6;
            said.point_size_granularity = 1.0 / 64.0;
            said.line_width_granularity = 1.0 / 64.0;
            // A viewport's position is written as a signed 16-bit whole
            // part and a 6-bit fraction (`cl.zig`), so the furthest a
            // corner may lie is -32768 and 16383.996, the largest the
            // encoding holds.
            said.viewport_bounds_range = .{ -32768, 16383 };
            // A constant texel offset, which the cores apply and this
            // device refuses: `spirv.look` turns the `ConstOffset` image
            // operand away against this driver's own profile and
            // `compile` answers `Error.Operands`, so a pipeline asking
            // for one is refused where it is made. Vulkan asks -8 and 7
            // of every implementation unconditionally, so a zero here is
            // a shortfall of this device and not a choice - the shape
            // `samplers` is in, and item 28's remaining half.
            //
            // **Read off the profile rather than written down.** Without
            // something here this device would inherit the cores' range
            // from `_instance.limits` and advertise an offset it refuses
            // every use of, which is worse than advertising none; and a
            // number written here by hand would have to be remembered on
            // the day the QPUs learn the operand. The limit follows the
            // capability instead, and cannot fall out of step with it.
            const offsets = compile.profile.takesImageOperand(.const_offset);
            said.min_texel_offset = if (offsets) _instance.limits.min_texel_offset else 0;
            said.max_texel_offset = if (offsets) _instance.limits.max_texel_offset else 0;
            // The varyings a vertex hands on: eight, which is the limit of
            // this library's own QPU code and not of the V3D. The hardware
            // takes 64 - Mesa's v3dv reports `16 * 4` for both rows on this
            // same V3D 7.1 (src/broadcom/vulkan/v3dv_device.c, from
            // `V3D_MAX_FS_INPUTS` in src/broadcom/common/v3d_limits.h), its
            // compiler writing each output into the VPM as it is made
            // (`vir_STVPMV`, src/broadcom/compiler/nir_to_vir.c). This
            // compiler instead keeps every varying in one of ten usable
            // registers beside the four floats a program needs of its own
            // (compile.zig), and the vertex programs are pregenerated, one
            // for each count, `programs.vertex` being
            // `qpu.most_varyings + 1` long. So the number is read off the
            // compiler's own cap, for the reason the texel offsets are read
            // off its profile: the cores report `shader.MAX_VARYINGS` since
            // 1.90, and without these two lines this device would inherit
            // 64 and refuse every pipeline above 8 while advertising it
            // takes them. It rises when the compiler's vertex outputs are
            // ported from Mesa's, not by writing a larger number here.
            // Item 17 of docs/facet-vulkan10.md. (1.90 called this a real
            // ceiling of the hardware, which Mesa shows it is not.)
            said.max_vertex_output_components = compile.most_varyings;
            said.max_fragment_input_components = compile.most_varyings;
            // One layer a framebuffer. A frame here is one pass of the
            // binner and one render control list over one layer; v3dv
            // takes 256 by emitting `NUMBER_OF_LAYERS` before the binning
            // mode, sizing the tile lists and the tile state for every
            // layer, and walking the render list once a layer at that
            // layer's tile lists and addresses (`job_emit_binning_prolog`
            // and `cmd_buffer_emit_render_pass_layer_rcl`,
            // src/broadcom/vulkan/v3dvx_cmd_buffer.c), which is the port
            // this number waits on. What it already does is begin at the
            // layer a view names, as v3dv's `v3dv_layer_offset` does
            // (`_play.zig`, since 1.91). Item 22.
            said.max_framebuffer_layers = 1;
            break :said said;
        },
    };
    physical.properties.pipeline_cache_uuid = _driver.cacheUuid(&physical.properties);
    // The library's own two numbers, which left the limits at 1.82.
    physical.tile_size = v3d.frame.tile_pixels;
    physical.cores = 1;
    const name = "VideoCore VII V3D 7.1";
    @memcpy(physical.properties.device_name[0..name.len], name);
    physical.can = .{
        // Only the fixed forms have QPU programs; a pipeline with a function
        // of its own is refused here and runs on the cores instead.
        .own_fragment_functions = false,
        // The TMU reads a texture's format from the image it is given.
        .sampling_format = false,
        // Both run on the cores, whichever device made the pipeline.
        .compute_on_device = false,
        .tessellation_on_device = false,
        // No QPU program discards yet, so texture_cutout is refused above.
        .discarding_fragment_forms = false,
        // Not every fixed form that wants a sampler: the 2D, array, cube
        // and 3D ones run here since 1.141, their programs the ones of
        // the forms without a sampler and the TMU told the bound sampler
        // whole (`samplesHere` beside makePipeline), and the shadow one
        // since 1.142, but the cube of an array is refused and drawn on
        // the cores. A generated program's sampler is the TMU's whole
        // since 1.140 (`tiling.samplerOf`).
        .samplers = false,
        // The TMU's own, 2 to 16 samples, as v3dv has it
        // (v3dv_device.c:349; `tiling.anisotropyOf`). Until 1.140 this was
        // false and the limit 1, as Vulkan asks of a device without it.
        .sampler_anisotropy = true,
        // Bit 1 of the TMU's configuration parameter 1, which v3dv sets
        // from the sampler (v3dv_uniforms.c:213-218; `tiling.parameter1`).
        // Refused until 1.140, with the rest of what a sampler says.
        .unnormalized_coordinates = true,
        // The hardware's own counter, pointed at a word of the frame's by
        // the packet beside a draw and added to the query as the frame is
        // drawn (`cl.occlusionQuery`, since 1.47). What the QPUs were
        // given is still counted by nothing, so a statistics pool is
        // refused here. A timestamp is the library's clock, which every
        // device has (CmdWriteTimestamp).
        .occlusion_queries = true,
        .pipeline_statistics_queries = false,
        .timestamp_queries = true,
        // The tiles' depth and stencil are stored to an image's rows and
        // loaded back from them, as the render target is (`cl.STORE_Z`,
        // `STORE_STENCIL`, since 1.47). The hardware writes a plane's own
        // pixels one after another, so the image's format holds that
        // plane alone: a format of both keeps neither here.
        .stored_depth = true,
        .stored_stencil = true,
        .stored_both = false,
        // A sampled D16_UNORM lies as a texture does here, the pass
        // storing its depth in the level's tiling, and the TMU reads it as
        // DEPTH_COMP16, as v3dv does (v3dvx_formats.c:204,
        // v3dvx_cmd_buffer.c:396-406; `_image.deviceLaid`). Refused until
        // 1.142, the format query leaving the sampled bits out since 1.80.
        // Unfiltered, as v3dv has D16_UNORM here (v3dvx_formats.c:204, its
        // filtering false, so v3dv_formats.c:273-276 gives no
        // FILTER_LINEAR), and no stencil: v3dv's one format of both is
        // D24_UNORM_S8_UINT (v3dvx_formats.c:209), which is not here.
        .sampled_depth = true,
        .sampled_stencil = false,
        .filtered_depth = false,
        // Its TMU is fed texels the library unpacked, so a compressed or a
        // float image is unpacked on the copy here as before.
        .kept_compressed = false,
        .kept_floats = false,
        // Its TMU is fed what the library unpacked, which is 8 bits a
        // channel: a texture of its own channels is refused here (since
        // 1.69).
        .wide_channels = false,
        // Nor a texture of whole numbers, for the same reason (since
        // 1.70).
        .whole_textures = false,
        // No QPU program reads a fourth coordinate, so a cube of an array
        // is refused here: the view as well as the pipeline.
        .cube_arrays = false,
        // ETC2 and EAC are unpacked by the library as they are copied in,
        // which is the same work on either device.
        .etc2_textures = true,
        // The TMU reads an R8 texture with a swizzle of its own, and has
        // never spread an 8888 texel: one byte a texel there, and the
        // packed flag costs nothing and changes nothing (tiling.zig).
        .small_texels = true,
        // Its fragment programs are the fixed forms, and each writes the
        // one colour: a subpass of several is drawn once for each.
        .several_outputs = false,
        // A set layout's own sampler is the library's doing, not a
        // driver's: it is kept here as well, though no program of the QPUs
        // reads a sampler.
        .immutable_samplers = true,
        // Version 7.1 has both of these: the clamp is a bit of the
        // configuration, which turns the clip to the z planes off with it
        // as Vulkan has a depth clamp, and the bounds are a packet of
        // their own (`cl.depthBounds`, since 1.47).
        .depth_clamp = true,
        .depth_bounds = true,
        // A V3D texture lies the way its TMU reads it, which is not the
        // layout the library writes (`texture_offset`), so a storage image
        // is refused on this device and the set layout says so.
        .storage_images = false,
        // A texel buffer is a buffer's bytes and a format: nothing of a
        // device's own layout is in it, so every device takes one. What
        // reads it is a function of the program's, which on a device
        // without them is its compute functions, run on the cores.
        .texel_buffers = true,
        // No fragment program of the QPUs reads an attachment's pixels,
        // so a set layout with the kind is refused here, as is a subpass
        // with input attachments.
        .input_attachments = false,
        // A dynamic buffer descriptor is a pointer and a range, shifted
        // by what the bind gave: the function that reads it is the
        // program's, so every device takes one.
        .dynamic_descriptors = true,
        // A colour attachment is drawn as a pass of its own, so each
        // takes the mixing asked for it as it is drawn.
        .independent_blend = true,
        // The hardware's own depth offset, a packet beside the
        // configuration that enables it (`cl.depthOffset`): the units are
        // the depth buffer's smallest differences and the factor the
        // triangle's slope, as Vulkan asks (since 1.47).
        .depth_bias = true,
        // The depth pre-pass is the rasterizer's (driver/cpu/raster/prepass.zig).
        .depth_prepass = false,
        .points_and_lines = true,
        .depth_test = true,
        .stencil_test = true,
        .blending = true,
        .indirect_draws = true,
        .secondary_command_buffers = true,
        .several_subpasses = true,
        .several_color_attachments = true,
        .texture_arrays = true,
        .cube_maps = true,
        .textures_3d = true,
        .compressed_textures = true,
        .float_textures = true,
        // Four samples a pixel, in tiles of four (since 1.148,
        // docs/facet-vulkan10.md item 61): the frame takes its coverage at
        // four places, stores its colour and its depth all four together
        // where their images keep them (`_image.Image.quads`), and averages
        // the colour into a resolve attachment as each tile ends, or on the
        // CPU where the render area is not of whole supertiles
        // (`frame.resolvesInTiles`). Sampling such an image is item 59's
        // and step V7's, and refused until then (`_image.multisampled`).
        .multisampling = true,
    };
    physical.queue_family = .{
        .queue_flags = facet.QUEUE_GRAPHICS | facet.QUEUE_COMPUTE | facet.QUEUE_TRANSFER,
        .queue_count = 1,
        .timestamp_valid_bits = 64,
        .min_image_transfer_granularity = .{ .width = 1, .height = 1, .depth = 1 },
    };
    describeMemory(sys, &physical.memory);
    return true;
}

/// The one heap and its type, and the type with nothing behind it.
fn describeMemory(sys: *ExecBase, into: *facet.PhysicalDeviceMemoryProperties) void {
    into.* = std.mem.zeroes(facet.PhysicalDeviceMemoryProperties);
    var size: u64 = 0;
    if (sys.LockExecList(exec.EXECLIST_MEMORY)) |list| {
        var it = list.iterator();
        while (it.next()) |node| {
            const region: *const exec.MemHeader = @fieldParentPtr("node", node);
            if (region.attributes & exec.MEMF_DMA != 0) size += @intFromPtr(region.upper) - @intFromPtr(region.lower);
        }
        sys.UnlockExecList(exec.EXECLIST_MEMORY);
    }
    into.memory_heaps[0] = .{ .size = size, .flags = facet.MEMORY_HEAP_DEVICE_LOCAL, .attributes = exec.MEMF_DMA };
    into.memory_types[0] = .{
        .property_flags = facet.MEMORY_PROPERTY_DEVICE_LOCAL | facet.MEMORY_PROPERTY_HOST_VISIBLE | facet.MEMORY_PROPERTY_HOST_COHERENT | facet.MEMORY_PROPERTY_HOST_CACHED | facet.MEMORY_PROPERTY_DMA,
        .heap_index = 0,
    };
    into.memory_types[1] = .{ .property_flags = facet.MEMORY_PROPERTY_DEVICE_LOCAL | facet.MEMORY_PROPERTY_LAZILY_ALLOCATED, .heap_index = 0 };
    into.memory_heap_count = 1;
    into.memory_type_count = 2;
}

/// The V3D held once more, switched on if this is the first; null when it
/// cannot be had.
pub fn hold(base: *FacetBase) ?*Hardware {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.v3d_lock);
    defer sys.ReleaseSemaphore(&base.v3d_lock);
    if (base.v3d) |made| {
        const hardware: *Hardware = @ptrCast(@alignCast(made));
        hardware.users += 1;
        return hardware;
    }
    const hardware = _objects.create(sys, Hardware) orelse return null;
    if (!bringUp(sys, hardware)) {
        _objects.destroy(sys, hardware);
        return null;
    }
    base.v3d = hardware;
    return hardware;
}

/// The V3D held once more for a block of memory or a program a device
/// makes. The device's queue holds it from CreateDevice to DestroyDevice
/// (`_play.open`), so it is there and this cannot fail, as v3dv's device
/// works on the hardware its physical device opened (v3dv_device.c:1514
/// `create_physical_device`). Since 1.134: AllocateMemory and the fragment
/// program held it with `hold`, and answered `error_initialization_failed`
/// where it would not come up, which neither call lists and no program
/// reached.
fn holdAgain(base: *FacetBase) *Hardware {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.v3d_lock);
    defer sys.ReleaseSemaphore(&base.v3d_lock);
    const hardware: *Hardware = @ptrCast(@alignCast(base.v3d.?));
    hardware.users += 1;
    return hardware;
}

fn bringUp(sys: *ExecBase, hardware: *Hardware) bool {
    hardware.users = 1;
    hardware.stale = false;
    hardware.broken = false;
    hardware.gpu = v3d.Gpu.find(sys) orelse return false;
    hardware.gpu.powerUp() catch return false;
    const ident = hardware.gpu.identify();
    hardware.space = v3d.Space.open(&hardware.gpu) orelse return false;
    if (!hardware.engine.start(&hardware.gpu, &hardware.space, ident.virtual_bits)) {
        hardware.space.close();
        return false;
    }
    if (!loadPrograms(hardware)) {
        hardware.engine.stop();
        hardware.space.close();
        return false;
    }
    return true;
}

/// Every program in one block of the V3D's.
fn loadPrograms(hardware: *Hardware) bool {
    const fragments = [_]*const qpu.Fragment{ &qpu.color_fragment, &qpu.texture_fragment, &qpu.texture_color_fragment, &qpu.array_fragment, &qpu.cube_fragment, &qpu.volume_fragment, &qpu.shadow_fragment };
    var words: usize = qpu.coordinate_program.len;
    for (0..qpu.most_varyings + 1) |varyings| words += qpu.vertexProgram(@intCast(varyings)).len;
    for (fragments) |fragment| words += fragment.code.len;
    const block = hardware.space.alloc(@intCast(words * 8)) orelse return false;
    if (!hardware.space.flush()) {
        var given_back = block;
        hardware.space.free(&given_back);
        return false;
    }
    var used: u32 = 0;
    const put = struct {
        fn program(at: Block, offset: *u32, code: []const u64) u32 {
            const into: [*]u64 = @ptrCast(@alignCast(at.cpu + offset.*));
            @memcpy(into[0..code.len], code);
            const address = at.address + offset.*;
            offset.* += @intCast(code.len * 8);
            return address;
        }
    }.program;
    hardware.programs.coordinate = put(block, &used, &qpu.coordinate_program);
    for (&hardware.programs.vertex, 0..) |*address, varyings| address.* = put(block, &used, qpu.vertexProgram(@intCast(varyings)));
    hardware.programs.color = put(block, &used, qpu.color_fragment.code);
    hardware.programs.texture = put(block, &used, qpu.texture_fragment.code);
    hardware.programs.texture_color = put(block, &used, qpu.texture_color_fragment.code);
    hardware.programs.array = put(block, &used, qpu.array_fragment.code);
    hardware.programs.cube = put(block, &used, qpu.cube_fragment.code);
    hardware.programs.volume = put(block, &used, qpu.volume_fragment.code);
    hardware.programs.shadow = put(block, &used, qpu.shadow_fragment.code);
    hardware.space.toGpu(&block);
    hardware.programs_block = block;
    return true;
}

/// The V3D let go of once, what it holds given back with the last. The core
/// stays powered and its clock running.
pub fn letGo(base: *FacetBase, hardware: *Hardware) void {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.v3d_lock);
    defer sys.ReleaseSemaphore(&base.v3d_lock);
    hardware.users -= 1;
    if (hardware.users != 0) return;
    hardware.space.free(&hardware.programs_block);
    hardware.engine.stop();
    hardware.space.close();
    base.v3d = null;
    _objects.destroy(sys, hardware);
}

fn allocateMemory(device: *Device, memory: *DeviceMemory) callconv(.c) facet.Result {
    const bytes = std.math.cast(u32, memory.size) orelse return .error_out_of_device_memory;
    if (bytes == 0) return .error_out_of_device_memory;
    const base = device.base;
    const sys = device.sys;
    const kept = _objects.create(sys, Block) orelse return .error_out_of_host_memory;
    const hardware = holdAgain(base);
    sys.ObtainSemaphore(&base.v3d_lock);
    const block = hardware.space.alloc(bytes);
    if (block != null) hardware.stale = true;
    sys.ReleaseSemaphore(&base.v3d_lock);
    kept.* = block orelse {
        letGo(base, hardware);
        _objects.destroy(sys, kept);
        return .error_out_of_device_memory;
    };
    memory.block = @ptrCast(kept);
    memory.block_bytes = 0;
    memory.data = kept.cpu;
    return .success;
}

fn freeMemory(device: *Device, memory: *DeviceMemory) callconv(.c) void {
    const base = device.base;
    const sys = device.sys;
    const kept: *Block = @ptrCast(@alignCast(memory.block.?));
    const hardware: *Hardware = @ptrCast(@alignCast(base.v3d.?));
    sys.ObtainSemaphore(&base.v3d_lock);
    hardware.space.free(kept);
    hardware.stale = true;
    sys.ReleaseSemaphore(&base.v3d_lock);
    _objects.destroy(sys, kept);
    letGo(base, hardware);
}

/// What a pipeline whose fragment shader the V3D compiles itself keeps.
pub const Shader = struct {
    /// The code, in a block of its own. The per-frame chunks cannot hold
    /// it: `beginRenderPass` resets them, and this lives as long as the
    /// pipeline.
    block: Block,
    /// Where the V3D has its first instruction. The shader record ORs its
    /// flag bits into the low bits of a program address, which a block of
    /// the space's leaves clear (`space.alloc` aligns to a page).
    address: u32,
    /// The varyings it reads, which is the vertex function's count: it was
    /// held to that as the pipeline was made.
    varyings: u32,
    /// The head of its uniform stream, by value, because a draw copies it
    /// into the stream it carves and the compiler's own memory is one
    /// block every pipeline is compiled through. Two of its words may be
    /// the TMU's configuration, which only a draw can fill in.
    uniforms: [compile.most_uniforms]compile.Word,
    uniform_count: u32,
    /// The combined image sampler it reads, where it reads one: where
    /// the draw is to look for the texture and the sampler whose state
    /// those two words are.
    sampler: ?compile.Sampler,
    /// What the shader record says of the program, which Mesa's back end
    /// decided as it compiled (`cl.Programs`): its threads, whether it
    /// reads W at the pixel's centre, and where it waits on the
    /// scoreboard (since 1.137).
    threads: u8,
    center_w: bool,
    lock_scoreboard_on_first_thrsw: bool,
    /// Whether it writes Z and has early Z off: a program that drops
    /// pixels (since 1.139).
    writes_z: bool,
    disable_ez: bool,

    pub fn stream(made: *const Shader) []const compile.Word {
        return made.uniforms[0..made.uniform_count];
    }
};

fn makePipeline(pipeline: *Pipeline) callconv(.c) facet.Result {
    // A pipeline that draws nothing - its rasterizer discarding, or every
    // face culled - has no program to make: a draw with it ends before one
    // is read (`_play.draw`), and this device counts no statistics a
    // stage would owe. So such a pipeline of no fragment stage is made
    // here, which is the one Vulkan allows beside a discarding rasterizer
    // (VUID-VkGraphicsPipelineCreateInfo-pStages-06894; since 1.134,
    // refused before as item 85's V3D half refuses the others).
    if (pipeline.draws_nothing) return .success;
    const fixed = pipeline.fixed;
    // Alpha to coverage wants a QPU program that writes the coverage,
    // which none does yet: step V6 of item 61 of docs/facet-vulkan10.md
    // (since 1.108; refused with every device before it).
    if (pipeline.alpha_to_coverage) return .error_feature_not_present;
    // No fixed form: the program's own fragment shader, which this device
    // draws with where the program shipped the SPIR-V beside the function
    // and the back end can make code of it (since 1.76). Where it cannot,
    // the pipeline is refused and the cores draw it, as before. A pipeline
    // of no fragment stage ships none: refused until v3dv's no-op
    // fragment shader is ported (v3dv_pipeline.c:2616-2642,
    // docs/facet-vulkan10.md item 85).
    if (fixed.kind == .none) {
        if (pipeline.fragment_words.len == 0) return .error_feature_not_present;
        return compiled(pipeline);
    }
    // A form that drops pixels needs a QPU program that discards, which no
    // fixed form's has yet, so such a pipeline is refused here and drawn
    // on the cores. Nor is there a program for a cube of an array, which
    // reads a fourth coordinate (since 1.46). A form that samples through
    // the sampler bound beside its texture is drawn where `samplesHere`
    // says, and refused elsewhere.
    if (fixed.kind == .texture_cube_array or fixed.discards() or (fixed.needsSampler() and !samplesHere(fixed)) or pipeline.varyings != fixed.varyings()) return .error_feature_not_present;
    return .success;
}

/// Whether this device draws `fixed`, a form that samples through the
/// sampler bound beside its texture. It runs the program of the form it is
/// otherwise, with the TMU told the sampler whole as v3dv packs it
/// (`_play.zig`'s `textureUniforms`, since 1.141): a 2D texture, a layer
/// of an array, a cube and a 3D texture. A cube is read over its seams
/// with the sampler's wraps saying nothing of it, as Vulkan has it (the
/// spec's "Wrapping Operation") and as the cores read it since 1.60
/// (`texture.sampleCubeBy`); v3dv packs the wraps as they are whatever
/// the view (v3dvx_device.c:255-257), and so does this.
///
/// `texture_shadow` since 1.142: its program writes the reference to
/// TMUDREF, where the TMU compares (v3d_tex.c:155-157; `qpu.shadow_code`),
/// and the depth it reads is a D16_UNORM laid out as a texture. One it
/// refuses: `texture_cube_array_sampled`, as no program reads a cube of an
/// array.
fn samplesHere(fixed: facet.shader.Fixed) bool {
    return switch (fixed.kind) {
        .texture_sampled, .texture_array_sampled, .texture_cube_sampled, .texture_3d_sampled, .texture_shadow => true,
        else => false,
    };
}

/// The pipeline's own fragment shader compiled and put where the V3D
/// reads it. The compiler's working memory is a block of its own and some
/// kilobytes wide, so it is taken for the call and given back: a pipeline
/// is made once and drawn with many times.
///
/// The compiler is the one ported from Mesa (compile.compileThroughMesa,
/// driver/v3d/compiler/), since 1.137: the plan's (compile.compile) is
/// what V3DTest's GENERATED still draws with, and reads the same words.
/// Its lists and graphs are in an arena of the calling task's for the one
/// compile. What it refuses the cores draw, as before.
fn compiled(pipeline: *Pipeline) facet.Result {
    const device = pipeline.device;
    const base = device.base;
    const sys = device.sys;
    const work = _objects.create(sys, compile.Work) orelse return .error_out_of_host_memory;
    defer _objects.destroy(sys, work);
    const code = compile.compileThroughMesa(work, pipeline.fragment_words, v3d.heap.of(sys)) catch |err| return switch (err) {
        error.OutOfMemory => .error_out_of_host_memory,
        else => .error_feature_not_present,
    };
    // The vertex function writes the varyings the fragment program reads.
    // CreateGraphicsPipelines already holds the two entries to the one
    // count, so this is the words disagreeing with the entry that shipped
    // them rather than a pipeline that was put together wrongly.
    if (code.varyings != pipeline.varyings) return .error_feature_not_present;
    const kept = _objects.create(sys, Shader) orelse return .error_out_of_host_memory;
    const hardware = holdAgain(base);
    sys.ObtainSemaphore(&base.v3d_lock);
    const block = hardware.space.alloc(@intCast(code.words.len * 8));
    if (block) |each| {
        const into: [*]u64 = @ptrCast(@alignCast(each.cpu));
        @memcpy(into[0..code.words.len], code.words);
        hardware.space.toGpu(&each);
        hardware.stale = true;
    }
    sys.ReleaseSemaphore(&base.v3d_lock);
    const made = block orelse {
        letGo(base, hardware);
        _objects.destroy(sys, kept);
        return .error_out_of_device_memory;
    };
    kept.* = .{
        .block = made,
        .address = made.address,
        .varyings = code.varyings,
        .uniforms = code.uniforms,
        .uniform_count = code.uniform_count,
        .sampler = code.sampler,
        .threads = code.threads,
        .center_w = code.center_w,
        .lock_scoreboard_on_first_thrsw = code.lock_scoreboard_on_first_thrsw,
        .writes_z = code.writes_z,
        .disable_ez = code.disable_ez,
    };
    pipeline.driver = kept;
    return .success;
}

fn unmakePipeline(pipeline: *Pipeline) callconv(.c) void {
    const kept: *Shader = @ptrCast(@alignCast(pipeline.driver orelse return));
    const base = pipeline.device.base;
    const sys = pipeline.device.sys;
    const hardware: *Hardware = @ptrCast(@alignCast(base.v3d.?));
    sys.ObtainSemaphore(&base.v3d_lock);
    hardware.space.free(&kept.block);
    hardware.stale = true;
    sys.ReleaseSemaphore(&base.v3d_lock);
    pipeline.driver = null;
    _objects.destroy(sys, kept);
    letGo(base, hardware);
}

/// The queue's task blocks in the frame's jobs, on what the V3D's interrupts
/// signal, so the buffer's work is done by the time this signals.
fn execute(queue: *Queue, buffer: *CommandBuffer, done: *exec.Waitable) callconv(.c) void {
    _play.play(queue, buffer);
    if (_play.broken(queue)) queue.device.lose();
    queue.device.sys.SignalWaitable(done);
}

/// A layer's memory, or a 3D image's whole: its levels each its slices one
/// after another, the step from a slice to the next level 0's (since
/// 1.141, `tiling.layoutOf`).
fn textureMemory(format: facet.Format, width: u32, height: u32, depth: u32, levels: u32, samples: u32) callconv(.c) _driver.TextureMemory {
    const layout = _play.layoutOf(format, width, height, depth, levels, samples > 1);
    return .{ .bytes = layout.bytes, .alignment = tiling.alignment, .layer_bytes = if (depth > 1) layout.levels[0].slice_bytes else 0 };
}

/// Where a texel of a layer of a texture is, or of a 3D texture's slice,
/// in bytes from its memory. Of one sample's plane of an image of four,
/// that sample's texel in the pixel's quad (`tiling.sampleTexel`, since
/// 1.146).
fn textureOffset(image: *const _image.Image, level: u32, layer: u32, x: u32, y: u32) callconv(.c) usize {
    const layout = _play.imageLayout(image);
    const at: [2]u32 = if (image.quads) tiling.sampleTexel(x, y, image.sample) else .{ x, y };
    return _play.layerAt(image, &layout, level, layer) + tiling.texelOffset(&layout, level, at[0], at[1]);
}

/// A level of a layer of a texture, or of a 3D texture's slice: all of
/// its texels, the padding of its tiles with them.
fn textureLevel(image: *const _image.Image, level: u32, layer: u32) callconv(.c) _driver.Span {
    const layout = _play.imageLayout(image);
    return .{ .at = _play.layerAt(image, &layout, level, layer) + layout.levels[level].offset, .bytes = layout.levels[level].slice_bytes };
}
