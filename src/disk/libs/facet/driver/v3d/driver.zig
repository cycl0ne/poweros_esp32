// SPDX-License-Identifier: MIT
//! The second driver: the BCM2712's V3D 7.1, the 3D core of its VideoCore
//! VII, a module of its own in LIBS:facet/ (v3d_fdriver.zig). What knows the
//! hardware is the Zig module `v3d` (v3d.zig); this is its table, and
//! `_play.zig` a command buffer made into its control lists.
//!
//! The board part is what finds it: where the machine has no such part the
//! instance lists no device of it. It is switched on when a device first
//! wants it, and what that makes - the MMU's table, the interrupts, the
//! programs - stays while any queue or block of memory is left, in the one
//! `Hardware` all the instances of the library share. It goes back to
//! nothing but stays powered: a second power-up after a power-down halted
//! the machine.
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
};

/// What the V3D has while anything uses it. Its job, and its table, are
/// one at a time: both are taken under `FacetBase.v3d_lock`.
pub const Hardware = struct {
    gpu: v3d.Gpu,
    space: v3d.Space,
    engine: v3d.Engine,
    /// The queues and the blocks of memory that hold it.
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
            // No program of the QPUs reads a sampler: the TMU is given the
            // state a fixed form's own `sampling` says, so the forms that
            // want a sampler are refused here and drawn on the cores
            // (`can.samplers` below). A sampler descriptor is of no use to
            // this device, and nor is a bias, and the mipmap level is
            // written as `mip_nearest` whatever the sampler asks
            // (`tiling.zig`). Vulkan's value for a device without
            // `sampler_anisotropy` is 1.
            said.max_per_stage_descriptor_samplers = 0;
            said.max_descriptor_set_samplers = 0;
            said.max_sampler_lod_bias = 0;
            said.max_sampler_anisotropy = 1;
            said.mipmap_precision_bits = 0;
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
            // colour, and nothing else. No depth through the TMU
            // (`can.sampled_depth`), no whole-number format
            // (`can.whole_textures`), no storage image. A mask of no bits
            // says the device samples no image of that kind at all, which
            // is what Vulkan means by it.
            said.sampled_image_integer_sample_counts = 0;
            said.sampled_image_depth_sample_counts = 0;
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
        // The TMU's state is written from the form's own `sampling` as a
        // draw is played: there is no program that reads a sampler, so the
        // forms that want one are refused and drawn on the cores.
        .samplers = false,
        // And the limit says 1 with it, as Vulkan asks of a device without
        // the feature (since 1.80).
        .sampler_anisotropy = false,
        // Nothing here reads a sampler at all, so a sample in texels is
        // refused with the rest of what a sampler says (since 1.67).
        .unnormalized_coordinates = false,
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
        // Its texture unit keeps a texture its own way, and knows no
        // depth format: a sampled depth image is refused. Since 1.80
        // GetPhysicalDeviceFormatProperties agrees with that refusal,
        // leaving the sampled bits out of D16_UNORM here rather than
        // promising a shadow map CreateImage turns down.
        .sampled_depth = false,
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
    const fragments = [_]*const qpu.Fragment{ &qpu.color_fragment, &qpu.texture_fragment, &qpu.texture_color_fragment, &qpu.array_fragment, &qpu.cube_fragment, &qpu.volume_fragment };
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
    const hardware = hold(base) orelse {
        _objects.destroy(sys, kept);
        return .error_initialization_failed;
    };
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

    pub fn stream(made: *const Shader) []const compile.Word {
        return made.uniforms[0..made.uniform_count];
    }
};

fn makePipeline(pipeline: *Pipeline) callconv(.c) facet.Result {
    const fixed = pipeline.fixed;
    // Alpha to coverage wants a QPU program that writes the coverage,
    // which none does yet: step V6 of item 61 of docs/facet-vulkan10.md
    // (since 1.108; refused with every device before it).
    if (pipeline.alpha_to_coverage) return .error_feature_not_present;
    // No fixed form: the program's own fragment shader, which this device
    // draws with where the program shipped the SPIR-V beside the function
    // and the back end can make code of it (since 1.76). Where it cannot,
    // the pipeline is refused and the cores draw it, as before.
    if (fixed.kind == .none) {
        if (pipeline.fragment_words.len == 0) return .error_feature_not_present;
        return compiled(pipeline);
    }
    // A form that drops pixels needs a QPU program that discards, and one
    // that samples through a sampler a program that reads it: there is
    // neither yet, so such a pipeline is refused here and drawn on the
    // cores.
    // Nor is there one for a cube of an array, which reads a fourth
    // coordinate (since 1.46) - `texture_cube_array_sampled` reads a
    // sampler besides, so `needsSampler` already refuses it (since 1.53).
    if (fixed.kind == .texture_cube_array or fixed.discards() or fixed.needsSampler() or pipeline.varyings != fixed.varyings()) return .error_feature_not_present;
    return .success;
}

/// The pipeline's own fragment shader compiled and put where the V3D
/// reads it. The compiler's working memory is a block of its own and some
/// kilobytes wide, so it is taken for the call and given back: a pipeline
/// is made once and drawn with many times.
fn compiled(pipeline: *Pipeline) facet.Result {
    const device = pipeline.device;
    const base = device.base;
    const sys = device.sys;
    const work = _objects.create(sys, compile.Work) orelse return .error_out_of_host_memory;
    defer _objects.destroy(sys, work);
    const code = compile.compile(work, pipeline.fragment_words) catch return .error_feature_not_present;
    // The vertex function writes the varyings the fragment program reads.
    // CreateGraphicsPipelines already holds the two entries to the one
    // count, so this is the words disagreeing with the entry that shipped
    // them rather than a pipeline that was put together wrongly.
    if (code.varyings != pipeline.varyings) return .error_feature_not_present;
    const kept = _objects.create(sys, Shader) orelse return .error_out_of_host_memory;
    const hardware = hold(base) orelse {
        _objects.destroy(sys, kept);
        return .error_initialization_failed;
    };
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

fn textureMemory(format: facet.Format, width: u32, height: u32, levels: u32) callconv(.c) _driver.TextureMemory {
    const layout = _play.layoutOf(format, width, height, levels);
    return .{ .bytes = layout.bytes, .alignment = tiling.alignment };
}

/// Where a texel of a texture is, in bytes from its memory.
fn textureOffset(image: *const @import("../../image/_image.zig").Image, level: u32, x: u32, y: u32) callconv(.c) usize {
    const layout = _play.layoutOf(image.format, image.width, image.height, image.levels);
    return tiling.texelOffset(&layout, level, x, y);
}
