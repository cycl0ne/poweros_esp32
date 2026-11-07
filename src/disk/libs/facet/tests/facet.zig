// SPDX-License-Identifier: MIT
//! Host tests of facet.library through its jump table: the library made
//! from its ROM tag on the ROM's exec, with a region of memory of the
//! test's own beside exec's test RAM - as a machine has its RAM, DMA
//! reachable and behind the cache - and every call made as a program
//! makes it. exec runs no task here but the test's, so a device's queue
//! is played by the task that submits to it (FacetBase.inline_queues).

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const facet = sdk.facet;
const FacetBase = sdk.interface.facet.FacetBase;
const ExecBase = sdk.interface.exec.ExecBase;
const kexec = @import("host_rom").exec;
const facet_init = @import("../facet_init.zig");
const _base = @import("../facet_base.zig");

const testing = std.testing;

/// The test's region: RAM as a machine has it.
const region_attributes = exec.MEMF_INTERNAL | exec.MEMF_EXTERNAL | exec.MEMF_DMA;
const region_bytes = 16 << 20;

/// exec, the test's region in it, and the library made from its tag.
pub const Rig = struct {
    sys: *ExecBase,
    fb: *FacetBase,
    region: []align(64) u8,
    header: *exec.MemHeader,
    free_at_start: u32,

    pub fn up() !Rig {
        try kexec.setUp();
        const sys = kexec.SysBase.iface();
        const region = try std.heap.page_allocator.alignedAlloc(u8, .@"64", region_bytes);
        errdefer std.heap.page_allocator.free(region);
        const header = sys.AddMemList(region.len, region_attributes, 0, region.ptr, "facet test RAM") orelse return error.NoRegion;
        const lib: *exec.Library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &facet_init.facet_library_tag, null) orelse return error.NoLibrary));
        _base.facetBase(lib).inline_queues = true;
        return .{ .sys = sys, .fb = @ptrCast(lib), .region = region, .header = header, .free_at_start = header.free };
    }

    /// Everything the library took from the test's region is back, and
    /// the region given back to the host.
    pub fn down(rig: *Rig) !void {
        const free = rig.header.free;
        std.heap.page_allocator.free(rig.region);
        try testing.expectEqual(rig.free_at_start, free);
    }

    /// Whether `address` is in the test's region.
    pub fn inRegion(rig: *const Rig, address: usize) bool {
        return address >= @intFromPtr(rig.region.ptr) and address < @intFromPtr(rig.region.ptr) + rig.region.len;
    }

    /// An instance and its one physical device.
    pub fn instance(rig: *Rig) !struct { *facet.Instance, *facet.PhysicalDevice } {
        var made: ?*facet.Instance = null;
        try testing.expectEqual(facet.Result.success, rig.fb.CreateInstance(&.{ .application_name = "facet tests" }, &made));
        var count: u32 = 1;
        var physical: [1]*facet.PhysicalDevice = undefined;
        try testing.expectEqual(facet.Result.success, rig.fb.EnumeratePhysicalDevices(made.?, &count, &physical));
        return .{ made.?, physical[0] };
    }

    /// A device with its queue on `physical`.
    pub fn device(rig: *Rig, physical: *facet.PhysicalDevice) !*facet.Device {
        const queue_info = facet.DeviceQueueCreateInfo{};
        var made: ?*facet.Device = null;
        try testing.expectEqual(facet.Result.success, rig.fb.CreateDevice(physical, &.{ .queue_create_info_count = 1, .queue_create_infos = @ptrCast(&queue_info) }, &made));
        return made.?;
    }
};

test "an instance lists one physical device: the cores, its memory made from exec's regions" {
    var rig = try Rig.up();
    defer rig.down() catch |err| std.debug.panic("{}", .{err});
    const instance, const physical = try rig.instance();
    defer rig.fb.DestroyInstance(instance);

    var count: u32 = 0;
    try testing.expectEqual(facet.Result.success, rig.fb.EnumeratePhysicalDevices(instance, &count, null));
    try testing.expectEqual(@as(u32, 1), count);
    var none: [1]*facet.PhysicalDevice = undefined;
    count = 0;
    try testing.expectEqual(facet.Result.incomplete, rig.fb.EnumeratePhysicalDevices(instance, &count, &none));

    var properties: facet.PhysicalDeviceProperties = undefined;
    rig.fb.GetPhysicalDeviceProperties(physical, &properties);
    try testing.expectEqual(facet.PhysicalDeviceType.cpu, properties.device_type);
    try testing.expectEqual(facet.API_VERSION_1_0, properties.api_version);
    try testing.expectEqual(facet.makeVersion(facet_init.LIBRARY_VERSION, facet_init.LIBRARY_REVISION, 0), properties.driver_version);
    try testing.expect(std.mem.startsWith(u8, &properties.device_name, "facet.library rasterizer, "));
    // The tile and the core count left PhysicalDeviceLimits at 1.82, Vulkan
    // having no member for either, and are the library's own record's now.
    // The tile is still asked for in Vulkan's way, by
    // GetRenderAreaGranularity (see the render pass tests).
    const record = _objects.of(_instance.PhysicalDevice, physical);
    try testing.expect(record.cores >= 1 and record.cores <= 4);
    try testing.expectEqual(@as(u32, 64), record.tile_size);
    // Vulkan's own members, which the structure had none of before 1.82.
    try testing.expectEqual(@as(usize, 256), facet.MAX_PHYSICAL_DEVICE_NAME_SIZE);
    try testing.expectEqual(@as(usize, 256), properties.device_name.len);
    // A pipeline cache UUID has to say which implementation made a cache,
    // so it must not be all zeroes and the two devices must not share one.
    try testing.expect(!std.mem.allEqual(u8, &properties.pipeline_cache_uuid, 0));
    // Nothing here binds memory a piece at a time, so every one of the five
    // is false - and they are read as `Bool32`, four bytes, not a Zig bool.
    try testing.expectEqual(@as(u32, 0), properties.sparse_properties.residency_standard_2d_block_shape);
    try testing.expectEqual(@as(u32, 0), properties.sparse_properties.residency_non_resident_strict);
    try testing.expectEqual(@as(u64, 0), properties.limits.sparse_address_space_size);
    // The three members whose type changed to Vulkan's: a float period, a
    // float anisotropy, and a `usize` map alignment.
    // The period is cleared with the queue family's timestamp bits on a
    // machine with no timer.device, which is this rig: what must hold is
    // that the two agree, not which way they went.
    try testing.expectEqual(properties.limits.timestamp_period > 0, record.queue_family.timestamp_valid_bits > 0);
    // And Vulkan's true for every graphics and compute queue timing things
    // promises them at least 36 bits, so it goes with them (since 1.93).
    try testing.expect(properties.limits.timestamp_compute_and_graphics == facet.FALSE or record.queue_family.timestamp_valid_bits >= 36);
    try testing.expectEqual(@as(f32, 16), properties.limits.max_sampler_anisotropy);
    try testing.expectEqual(@as(usize, 64), properties.limits.min_memory_map_alignment);

    count = 0;
    rig.fb.GetPhysicalDeviceQueueFamilyProperties(physical, &count, null);
    try testing.expectEqual(@as(u32, 1), count);
    var family: [1]facet.QueueFamilyProperties = undefined;
    rig.fb.GetPhysicalDeviceQueueFamilyProperties(physical, &count, &family);
    try testing.expectEqual(facet.QUEUE_GRAPHICS | facet.QUEUE_COMPUTE | facet.QUEUE_TRANSFER, family[0].queue_flags);
    try testing.expectEqual(@as(u32, 1), family[0].queue_count);

    // The test's region comes first, as exec prefers it; exec's test RAM,
    // which claims no attribute, after it; then the lazily allocated type.
    var memory: facet.PhysicalDeviceMemoryProperties = undefined;
    rig.fb.GetPhysicalDeviceMemoryProperties(physical, &memory);
    try testing.expectEqual(@as(u32, 2), memory.memory_heap_count);
    try testing.expectEqual(@as(u32, 3), memory.memory_type_count);
    try testing.expectEqual(region_attributes, memory.memory_heaps[0].attributes);
    // The region less exec's header at its start.
    try testing.expect(memory.memory_heaps[0].size <= region_bytes and memory.memory_heaps[0].size > region_bytes - 256);
    try testing.expectEqual(@as(u32, 0), memory.memory_heaps[1].attributes);
    const everywhere = facet.MEMORY_PROPERTY_DEVICE_LOCAL | facet.MEMORY_PROPERTY_HOST_VISIBLE | facet.MEMORY_PROPERTY_HOST_COHERENT;
    try testing.expectEqual(everywhere | facet.MEMORY_PROPERTY_HOST_CACHED | facet.MEMORY_PROPERTY_DMA, memory.memory_types[0].property_flags);
    try testing.expectEqual(everywhere, memory.memory_types[1].property_flags);
    try testing.expectEqual(@as(u32, 1), memory.memory_types[1].heap_index);
    try testing.expectEqual(facet.MEMORY_PROPERTY_DEVICE_LOCAL | facet.MEMORY_PROPERTY_LAZILY_ALLOCATED, memory.memory_types[2].property_flags);
}

test "a device asked for a feature it has not got is refused, which is Vulkan's enable step" {
    var rig = try Rig.up();
    defer rig.down() catch |err| std.debug.panic("{}", .{err});
    var instance: ?*facet.Instance = null;
    try testing.expectEqual(facet.Result.success, rig.fb.CreateInstance(&.{}, &instance));
    defer rig.fb.DestroyInstance(instance);
    var count: u32 = 1;
    var physicals: [1]*facet.PhysicalDevice = undefined;
    try testing.expectEqual(facet.Result.success, rig.fb.EnumeratePhysicalDevices(instance.?, &count, &physicals));
    const physical = physicals[0];
    var features: facet.PhysicalDeviceFeatures = undefined;
    rig.fb.GetPhysicalDeviceFeatures(physical, &features);

    const queue_info = facet.DeviceQueueCreateInfo{};
    const one_queue = facet.DeviceCreateInfo{ .queue_create_info_count = 1, .queue_create_infos = @ptrCast(&queue_info) };

    // Asking for nothing is what Vulkan's null pEnabledFeatures means, and
    // every call still refuses what the device cannot do, so a program that
    // asks for nothing is not given a device that behaves unpredictably.
    var device: ?*facet.Device = null;
    try testing.expectEqual(facet.Result.success, rig.fb.CreateDevice(physical, &one_queue, &device));
    rig.fb.DestroyDevice(device);

    // Asking for exactly what it said it has.
    device = null;
    var wanted = features;
    var asking = one_queue;
    asking.enabled_features = &wanted;
    try testing.expectEqual(facet.Result.success, rig.fb.CreateDevice(physical, &asking, &device));
    rig.fb.DestroyDevice(device);

    // Asking for a geometry stage, which no device of this library has.
    try testing.expectEqual(facet.FALSE, features.geometry_shader);
    device = null;
    wanted = features;
    wanted.geometry_shader = facet.TRUE;
    try testing.expectEqual(facet.Result.error_feature_not_present, rig.fb.CreateDevice(physical, &asking, &device));
    try testing.expect(device == null);

    // And the one feature Vulkan 1.0 requires of every implementation is
    // there to be asked for on its own.
    try testing.expectEqual(facet.TRUE, features.robust_buffer_access);
    device = null;
    wanted = .{ .robust_buffer_access = facet.TRUE };
    try testing.expectEqual(facet.Result.success, rig.fb.CreateDevice(physical, &asking, &device));
    rig.fb.DestroyDevice(device);
}

// The shape of the three structures a physical device is described by,
// held without needing a Vulkan header - which the build cannot count on,
// and `scripts/vulkan-struct-check.sh` is for. What that script does and
// this cannot is say the *names* are Vulkan's; what this does and the
// script cannot is run on every build.
test "the physical-device structures keep Vulkan's shape" {
    const Limits = facet.PhysicalDeviceLimits;
    const Features = facet.PhysicalDeviceFeatures;
    const Sparse = facet.PhysicalDeviceSparseProperties;
    const Properties = facet.PhysicalDeviceProperties;

    // Vulkan's member counts. A field added or dropped lands here first.
    try testing.expectEqual(106, @typeInfo(Limits).@"struct".fields.len);
    try testing.expectEqual(55, @typeInfo(Features).@"struct".fields.len);
    try testing.expectEqual(5, @typeInfo(Sparse).@"struct".fields.len);
    try testing.expectEqual(9, @typeInfo(Properties).@"struct".fields.len);

    // Not one Zig `bool` anywhere in them. A VkBool32 is four bytes, and a
    // one-byte bool is how facet's old features structure came to be 49
    // bytes where Vulkan's is 220 - the single mistake that made the call
    // unreadable to a conformant caller.
    inline for (.{ Limits, Features, Sparse, Properties }) |T| {
        inline for (@typeInfo(T).@"struct".fields) |field| {
            try testing.expect(field.type != bool);
        }
    }
    inline for (@typeInfo(Features).@"struct".fields) |field| {
        try testing.expectEqual(@as(usize, 4), @sizeOf(field.type));
    }
    inline for (@typeInfo(Sparse).@"struct".fields) |field| {
        try testing.expectEqual(@as(usize, 4), @sizeOf(field.type));
    }

    // Vulkan's order, at the ends and at the one member that was added in
    // the middle.
    try testing.expectEqualStrings("max_image_dimension_1d", @typeInfo(Limits).@"struct".fields[0].name);
    try testing.expectEqualStrings("non_coherent_atom_size", @typeInfo(Limits).@"struct".fields[105].name);
    try testing.expectEqualStrings("robust_buffer_access", @typeInfo(Features).@"struct".fields[0].name);
    try testing.expectEqualStrings("inherited_queries", @typeInfo(Features).@"struct".fields[54].name);
    try testing.expectEqualStrings("pipeline_cache_uuid", @typeInfo(Properties).@"struct".fields[6].name);
    try testing.expectEqualStrings("sparse_properties", @typeInfo(Properties).@"struct".fields[8].name);

    // Vulkan's array lengths, which were 64 and absent before 1.82.
    try testing.expectEqual(@as(usize, 256), @typeInfo(@FieldType(Properties, "device_name")).array.len);
    try testing.expectEqual(@as(usize, 16), @typeInfo(@FieldType(Properties, "pipeline_cache_uuid")).array.len);

    // Four-byte aligned, every one, which is what sdk/sdk.zig asks of every
    // structure of this SDK for the ESP32's stack - and the reason these are
    // Vulkan's member for member but not byte for byte.
    try testing.expectEqual(@as(usize, 4), @alignOf(Limits));
    try testing.expectEqual(@as(usize, 4), @alignOf(Features));
    try testing.expectEqual(@as(usize, 4), @alignOf(Sparse));
    try testing.expectEqual(@as(usize, 4), @alignOf(Properties));

    // The sizes. Features and the sparse properties are byte for byte
    // Vulkan's, every member of each being four bytes wide, and measured
    // against the header on the machine this was written on they are 220
    // and 20. The limits and the properties are 492 and 804 where C makes
    // them 504 and 824: the twelve and twenty bytes are padding C inserts
    // before an eight-byte member and `align(4)` does not. A 32-bit chip
    // has a shorter `min_memory_map_alignment`, so these hold where a
    // pointer is eight bytes.
    try testing.expectEqual(@as(usize, 220), @sizeOf(Features));
    try testing.expectEqual(@as(usize, 4 * 55), @sizeOf(Features));
    try testing.expectEqual(@as(usize, 20), @sizeOf(Sparse));
    if (@sizeOf(usize) == 8) {
        try testing.expectEqual(@as(usize, 492), @sizeOf(Limits));
        try testing.expectEqual(@as(usize, 804), @sizeOf(Properties));
    }
}

// Measured against Vulkan's own macros on the machine this was written on:
// `VK_API_VERSION_1_0` and the three after it, and a round trip through the
// widest value each field holds. The numbers are the header's, not this
// file's arithmetic repeated.
test "the version encoding is Vulkan's, field for field" {
    try testing.expectEqual(@as(u32, 4194304), facet.makeApiVersion(0, 1, 0, 0));
    try testing.expectEqual(@as(u32, 4198400), facet.makeApiVersion(0, 1, 1, 0));
    try testing.expectEqual(@as(u32, 4202496), facet.makeApiVersion(0, 1, 2, 0));
    try testing.expectEqual(@as(u32, 4206592), facet.makeApiVersion(0, 1, 3, 0));
    try testing.expectEqual(@as(u32, 4202627), facet.makeApiVersion(0, 1, 2, 131));
    // The highest patch of 1.0 is one below 1.1, which is only true if the
    // minor version really is ten bits and the patch twelve.
    try testing.expectEqual(@as(u32, 4198399), facet.makeApiVersion(0, 1, 0, 4095));
    try testing.expectEqual(facet.makeApiVersion(0, 1, 1, 0), facet.makeApiVersion(0, 1, 0, 4095) + 1);
    // makeVersion is the same with no variant, which is Vulkan's own.
    try testing.expectEqual(facet.makeApiVersion(0, 1, 81, 0), facet.makeVersion(1, 81, 0));
    // Every field at its widest, packed and taken back out.
    const packed_all = facet.makeApiVersion(3, 77, 1023, 4095);
    try testing.expectEqual(@as(u32, 1937768447), packed_all);
    try testing.expectEqual(@as(u32, 3), facet.apiVersionVariant(packed_all));
    try testing.expectEqual(@as(u32, 77), facet.apiVersionMajor(packed_all));
    try testing.expectEqual(@as(u32, 1023), facet.apiVersionMinor(packed_all));
    try testing.expectEqual(@as(u32, 4095), facet.apiVersionPatch(packed_all));
    // And the library's own revision fits the minor version with room to
    // spare: ten bits is 1023, where 1.81 is the revision today.
    try testing.expect(facet_init.LIBRARY_REVISION <= 1023);
    try testing.expectEqual(facet_init.LIBRARY_REVISION, facet.apiVersionMinor(facet.makeVersion(facet_init.LIBRARY_VERSION, facet_init.LIBRARY_REVISION, 0)));
}

test "an interface newer than the library's is refused; the library stays while an instance lasts" {
    var rig = try Rig.up();
    defer rig.down() catch |err| std.debug.panic("{}", .{err});
    var instance: ?*facet.Instance = null;
    // Vulkan's own VK_API_VERSION_1_0, which is what a ported program fills
    // this in with, and the number the comparison refused until 1.82.
    try testing.expectEqual(@as(u32, 4194304), facet.API_VERSION_1_0);
    try testing.expectEqual(facet.Result.success, rig.fb.CreateInstance(&.{ .api_version = 4194304 }, &instance));
    rig.fb.DestroyInstance(instance);
    // The patch is not compared: any patch of a version the library has is
    // taken, which is what Vulkan asks of an implementation.
    instance = null;
    try testing.expectEqual(facet.Result.success, rig.fb.CreateInstance(&.{ .api_version = facet.makeApiVersion(0, 1, 0, 4095) }, &instance));
    rig.fb.DestroyInstance(instance);
    // A newer minor version, a newer major version, and a variant that is
    // not Vulkan's: Vulkan's code for a version nothing present can provide
    // (1.80).
    for ([_]u32{
        facet.makeApiVersion(0, 1, 1, 0),
        facet.makeApiVersion(0, 2, 0, 0),
        facet.makeApiVersion(1, 1, 0, 0),
    }) |newer| {
        instance = null;
        try testing.expectEqual(facet.Result.error_incompatible_driver, rig.fb.CreateInstance(&.{ .api_version = newer }, &instance));
        try testing.expect(instance == null);
    }
    instance = null;
    try testing.expectEqual(facet.Result.success, rig.fb.CreateInstance(&.{ .api_version = 0 }, &instance));

    const lib = rig.fb.lib();
    try testing.expectEqual(@as(u16, 0), lib.open_cnt);
    try testing.expect(rig.sys.RemLibrary(lib) == null);
    try testing.expect(lib.flags & exec.LIBF_DELEXP != 0);
    rig.fb.DestroyInstance(instance);
    rig.fb.DestroyInstance(null);
}

test "the result codes, the barrier masks and the image layouts carry Vulkan's own numbers" {
    // VkResult. The five 1.80 added are in place, and their neighbours
    // have not moved to make room for them.
    try testing.expectEqual(@as(i32, 2), @intFromEnum(facet.Result.timeout));
    try testing.expectEqual(@as(i32, 3), @intFromEnum(facet.Result.event_set));
    try testing.expectEqual(@as(i32, 4), @intFromEnum(facet.Result.event_reset));
    try testing.expectEqual(@as(i32, 5), @intFromEnum(facet.Result.incomplete));
    try testing.expectEqual(@as(i32, -5), @intFromEnum(facet.Result.error_memory_map_failed));
    try testing.expectEqual(@as(i32, -6), @intFromEnum(facet.Result.error_layer_not_present));
    try testing.expectEqual(@as(i32, -7), @intFromEnum(facet.Result.error_extension_not_present));
    try testing.expectEqual(@as(i32, -8), @intFromEnum(facet.Result.error_feature_not_present));
    try testing.expectEqual(@as(i32, -9), @intFromEnum(facet.Result.error_incompatible_driver));
    try testing.expectEqual(@as(i32, -10), @intFromEnum(facet.Result.error_too_many_objects));

    // VkPipelineStageFlagBits, every core bit of it (1.80).
    try testing.expectEqual(@as(u32, 1 << 1), facet.PIPELINE_STAGE_DRAW_INDIRECT);
    try testing.expectEqual(@as(u32, 1 << 4), facet.PIPELINE_STAGE_TESSELLATION_CONTROL_SHADER);
    try testing.expectEqual(@as(u32, 1 << 5), facet.PIPELINE_STAGE_TESSELLATION_EVALUATION_SHADER);
    try testing.expectEqual(@as(u32, 1 << 6), facet.PIPELINE_STAGE_GEOMETRY_SHADER);
    try testing.expectEqual(@as(u32, 1 << 11), facet.PIPELINE_STAGE_COMPUTE_SHADER);
    const stages = [_]u32{
        facet.PIPELINE_STAGE_TOP_OF_PIPE,                 facet.PIPELINE_STAGE_DRAW_INDIRECT,
        facet.PIPELINE_STAGE_VERTEX_INPUT,                facet.PIPELINE_STAGE_VERTEX_SHADER,
        facet.PIPELINE_STAGE_TESSELLATION_CONTROL_SHADER, facet.PIPELINE_STAGE_TESSELLATION_EVALUATION_SHADER,
        facet.PIPELINE_STAGE_GEOMETRY_SHADER,             facet.PIPELINE_STAGE_FRAGMENT_SHADER,
        facet.PIPELINE_STAGE_EARLY_FRAGMENT_TESTS,        facet.PIPELINE_STAGE_LATE_FRAGMENT_TESTS,
        facet.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT,     facet.PIPELINE_STAGE_COMPUTE_SHADER,
        facet.PIPELINE_STAGE_TRANSFER,                    facet.PIPELINE_STAGE_BOTTOM_OF_PIPE,
        facet.PIPELINE_STAGE_HOST,                        facet.PIPELINE_STAGE_ALL_GRAPHICS,
        facet.PIPELINE_STAGE_ALL_COMMANDS,
    };
    // The seventeen are bits 0 to 16, each of them once: the sum says no
    // two are the same bit, the or says none is missing.
    try testing.expectEqual(@as(u32, (1 << 17) - 1), orAndSum(&stages).ored);
    try testing.expectEqual(@as(u32, (1 << 17) - 1), orAndSum(&stages).sum);

    // VkAccessFlagBits, likewise.
    try testing.expectEqual(@as(u32, 1 << 0), facet.ACCESS_INDIRECT_COMMAND_READ);
    try testing.expectEqual(@as(u32, 1 << 4), facet.ACCESS_INPUT_ATTACHMENT_READ);
    try testing.expectEqual(@as(u32, 1 << 6), facet.ACCESS_SHADER_WRITE);
    const accesses = [_]u32{
        facet.ACCESS_INDIRECT_COMMAND_READ,          facet.ACCESS_INDEX_READ,
        facet.ACCESS_VERTEX_ATTRIBUTE_READ,          facet.ACCESS_UNIFORM_READ,
        facet.ACCESS_INPUT_ATTACHMENT_READ,          facet.ACCESS_SHADER_READ,
        facet.ACCESS_SHADER_WRITE,                   facet.ACCESS_COLOR_ATTACHMENT_READ,
        facet.ACCESS_COLOR_ATTACHMENT_WRITE,         facet.ACCESS_DEPTH_STENCIL_ATTACHMENT_READ,
        facet.ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE, facet.ACCESS_TRANSFER_READ,
        facet.ACCESS_TRANSFER_WRITE,                 facet.ACCESS_HOST_READ,
        facet.ACCESS_HOST_WRITE,                     facet.ACCESS_MEMORY_READ,
        facet.ACCESS_MEMORY_WRITE,
    };
    try testing.expectEqual(@as(u32, (1 << 17) - 1), orAndSum(&accesses).ored);
    try testing.expectEqual(@as(u32, (1 << 17) - 1), orAndSum(&accesses).sum);

    // VkImageLayout's nine core values are 0 to 8 in order, which is
    // where `depth_stencil_read_only_optimal` lands (1.80): added in the
    // middle, so this is also the check that nothing after it shifted.
    const layouts = [_]facet.ImageLayout{
        .undefined,                       .general,
        .color_attachment_optimal,        .depth_stencil_attachment_optimal,
        .depth_stencil_read_only_optimal, .shader_read_only_optimal,
        .transfer_src_optimal,            .transfer_dst_optimal,
        .preinitialized,
    };
    for (layouts, 0..) |layout, k| try testing.expectEqual(@as(u32, @intCast(k)), @intFromEnum(layout));
}

/// The or of `bits` and their sum: equal only where no two of them are
/// the same bit.
fn orAndSum(bits: []const u32) struct { ored: u32, sum: u32 } {
    var ored: u32 = 0;
    var sum: u32 = 0;
    for (bits) |bit| {
        ored |= bit;
        sum += bit;
    }
    return .{ .ored = ored, .sum = sum };
}

test "a device with its queue, and queues the family has not got refused" {
    var rig = try Rig.up();
    defer rig.down() catch |err| std.debug.panic("{}", .{err});
    const instance, const physical = try rig.instance();
    defer rig.fb.DestroyInstance(instance);

    const device = try rig.device(physical);
    var queue: ?*facet.Queue = null;
    rig.fb.GetDeviceQueue(device, 0, 0, &queue);
    try testing.expect(queue != null);
    var again: ?*facet.Queue = null;
    rig.fb.GetDeviceQueue(device, 0, 0, &again);
    try testing.expectEqual(queue, again);
    rig.fb.GetDeviceQueue(device, 0, 1, &again);
    try testing.expect(again == null);
    rig.fb.GetDeviceQueue(device, 1, 0, &again);
    try testing.expect(again == null);

    var refused: ?*facet.Device = null;
    const two = facet.DeviceQueueCreateInfo{ .queue_count = 2 };
    try testing.expectEqual(facet.Result.error_initialization_failed, rig.fb.CreateDevice(physical, &.{ .queue_create_info_count = 1, .queue_create_infos = @ptrCast(&two) }, &refused));
    const other = facet.DeviceQueueCreateInfo{ .queue_family_index = 1 };
    try testing.expectEqual(facet.Result.error_initialization_failed, rig.fb.CreateDevice(physical, &.{ .queue_create_info_count = 1, .queue_create_infos = @ptrCast(&other) }, &refused));
    try testing.expect(refused == null);

    // Without a queue: a device for memory and objects alone.
    var bare: ?*facet.Device = null;
    try testing.expectEqual(facet.Result.success, rig.fb.CreateDevice(physical, &.{}, &bare));
    rig.fb.GetDeviceQueue(bare.?, 0, 0, &again);
    try testing.expect(again == null);
    rig.fb.DestroyDevice(bare);
    rig.fb.DestroyDevice(device);
    rig.fb.DestroyDevice(null);
}

test "a queue's task runs at its priority round its maker's" {
    const _device = @import("../device/_device.zig");
    try testing.expectEqual(@as(i8, 0), _device.taskPriority(0, null));
    try testing.expectEqual(@as(i8, 10), _device.taskPriority(0, 1.0));
    try testing.expectEqual(@as(i8, -10), _device.taskPriority(0, 0.0));
    try testing.expectEqual(@as(i8, 5), _device.taskPriority(5, std.math.nan(f32)));
    try testing.expectEqual(@as(i8, 127), _device.taskPriority(120, 1.0));
    try testing.expectEqual(@as(i8, -128), _device.taskPriority(-125, 0.0));
}

test "memory: from its type's heap, aligned to a cache line, mapped once; the lazily allocated type has nothing" {
    var rig = try Rig.up();
    defer rig.down() catch |err| std.debug.panic("{}", .{err});
    const instance, const physical = try rig.instance();
    defer rig.fb.DestroyInstance(instance);
    const device = try rig.device(physical);
    defer rig.fb.DestroyDevice(device);

    var memory: ?*facet.DeviceMemory = null;
    try testing.expectEqual(facet.Result.success, rig.fb.AllocateMemory(device, &.{ .allocation_size = 100_000, .memory_type_index = 0 }, &memory));
    var data: ?*anyopaque = null;
    try testing.expectEqual(facet.Result.success, rig.fb.MapMemory(device, memory.?, 0, facet.WHOLE_SIZE, 0, &data));
    const address = @intFromPtr(data.?);
    try testing.expect(rig.inRegion(address));
    try testing.expectEqual(@as(usize, 0), address % 64);
    // Every byte of it is the program's.
    @memset(@as([*]u8, @ptrCast(data.?))[0..100_000], 0x5A);
    var twice: ?*anyopaque = null;
    try testing.expectEqual(facet.Result.error_memory_map_failed, rig.fb.MapMemory(device, memory.?, 0, facet.WHOLE_SIZE, 0, &twice));
    try testing.expect(twice == null);
    rig.fb.UnmapMemory(device, memory.?);
    try testing.expectEqual(facet.Result.success, rig.fb.MapMemory(device, memory.?, 4096, 1000, 0, &twice));
    try testing.expectEqual(address + 4096, @intFromPtr(twice.?));
    rig.fb.UnmapMemory(device, memory.?);
    try testing.expectEqual(facet.Result.error_memory_map_failed, rig.fb.MapMemory(device, memory.?, 99_000, 2000, 0, &twice));
    try testing.expectEqual(facet.Result.error_memory_map_failed, rig.fb.MapMemory(device, memory.?, 100_000, facet.WHOLE_SIZE, 0, &twice));

    // A type the device has not got cannot be had, nor no bytes, nor
    // more than there is.
    var refused: ?*facet.DeviceMemory = null;
    try testing.expectEqual(facet.Result.error_out_of_device_memory, rig.fb.AllocateMemory(device, &.{ .allocation_size = region_bytes, .memory_type_index = 0 }, &refused));
    try testing.expectEqual(facet.Result.error_out_of_device_memory, rig.fb.AllocateMemory(device, &.{ .allocation_size = 64, .memory_type_index = 3 }, &refused));
    try testing.expectEqual(facet.Result.error_out_of_device_memory, rig.fb.AllocateMemory(device, &.{ .allocation_size = 0, .memory_type_index = 0 }, &refused));
    try testing.expect(refused == null);

    var lazy: ?*facet.DeviceMemory = null;
    const before = rig.header.free;
    try testing.expectEqual(facet.Result.success, rig.fb.AllocateMemory(device, &.{ .allocation_size = 4 << 20, .memory_type_index = 2 }, &lazy));
    try testing.expect(before - rig.header.free < 4096);
    try testing.expectEqual(facet.Result.error_memory_map_failed, rig.fb.MapMemory(device, lazy.?, 0, facet.WHOLE_SIZE, 0, &twice));

    rig.fb.FreeMemory(device, lazy);
    rig.fb.FreeMemory(device, memory);
    rig.fb.FreeMemory(device, null);
}

// --- buffers and images -------------------------------------------------------

const _objects = @import("../_objects.zig");
const _instance = @import("../instance/_instance.zig");
const _image = @import("../image/_image.zig");
const texture = facet.texture;

/// A block of memory type 0, the test's region, bound to nothing yet.
pub fn allocate(rig: *Rig, device: *facet.Device, bytes: u64) !*facet.DeviceMemory {
    var memory: ?*facet.DeviceMemory = null;
    try testing.expectEqual(facet.Result.success, rig.fb.AllocateMemory(device, &.{ .allocation_size = bytes, .memory_type_index = 0 }, &memory));
    return memory.?;
}

test "the formats: what each does in each tiling" {
    var rig = try Rig.up();
    defer rig.down() catch |err| std.debug.panic("{}", .{err});
    const instance, const physical = try rig.instance();
    defer rig.fb.DestroyInstance(instance);
    var properties: facet.FormatProperties = undefined;
    rig.fb.GetPhysicalDeviceFormatProperties(physical, .b8g8r8a8_unorm, &properties);
    try testing.expect(properties.optimal_tiling_features & facet.FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR != 0);
    try testing.expect(properties.linear_tiling_features & facet.FORMAT_FEATURE_COLOR_ATTACHMENT != 0);
    try testing.expect(properties.linear_tiling_features & facet.FORMAT_FEATURE_SAMPLED_IMAGE == 0);
    rig.fb.GetPhysicalDeviceFormatProperties(physical, .r5g6b5_unorm_pack16, &properties);
    try testing.expect(properties.optimal_tiling_features & facet.FORMAT_FEATURE_SAMPLED_IMAGE != 0);
    try testing.expect(properties.linear_tiling_features & facet.FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND != 0);
    try testing.expect(properties.linear_tiling_features & facet.FORMAT_FEATURE_SAMPLED_IMAGE == 0);
    // A depth attachment, and a transfer since a pass may store its depth;
    // never sampled, and never linear.
    rig.fb.GetPhysicalDeviceFormatProperties(physical, .d16_unorm, &properties);
    try testing.expectEqual(
        facet.FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT | facet.FORMAT_FEATURE_TRANSFER_SRC | facet.FORMAT_FEATURE_TRANSFER_DST |
            facet.FORMAT_FEATURE_SAMPLED_IMAGE | facet.FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR,
        properties.optimal_tiling_features,
    );
    try testing.expectEqual(0, properties.linear_tiling_features);
    // Since 1.38 one with a stencil keeps it the same way, so it too is
    // transferred: a copy reads or writes each pixel's depth and stencil
    // at once.
    rig.fb.GetPhysicalDeviceFormatProperties(physical, .d16_unorm_s8_uint, &properties);
    try testing.expectEqual(facet.FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT | facet.FORMAT_FEATURE_TRANSFER_SRC | facet.FORMAT_FEATURE_TRANSFER_DST, properties.optimal_tiling_features);
    try testing.expectEqual(0, properties.linear_tiling_features);
    rig.fb.GetPhysicalDeviceFormatProperties(physical, .s8_uint, &properties);
    try testing.expectEqual(facet.FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT | facet.FORMAT_FEATURE_TRANSFER_SRC | facet.FORMAT_FEATURE_TRANSFER_DST, properties.optimal_tiling_features);
    // A vertex format, and texels a BufferView reads as well.
    rig.fb.GetPhysicalDeviceFormatProperties(physical, .r32g32b32_sfloat, &properties);
    try testing.expectEqual(facet.FORMAT_FEATURE_VERTEX_BUFFER | facet.FORMAT_FEATURE_UNIFORM_TEXEL_BUFFER | facet.FORMAT_FEATURE_STORAGE_TEXEL_BUFFER, properties.buffer_features);
    rig.fb.GetPhysicalDeviceFormatProperties(physical, @enumFromInt(1234), &properties);
    try testing.expectEqual(@as(u32, 0), properties.optimal_tiling_features | properties.linear_tiling_features | properties.buffer_features);
}

test "a buffer: its requirements, and bound only where it fits" {
    var rig = try Rig.up();
    defer rig.down() catch |err| std.debug.panic("{}", .{err});
    const instance, const physical = try rig.instance();
    defer rig.fb.DestroyInstance(instance);
    const device = try rig.device(physical);
    defer rig.fb.DestroyDevice(device);

    var buffer: ?*facet.Buffer = null;
    try testing.expectEqual(facet.Result.error_out_of_device_memory, rig.fb.CreateBuffer(device, &.{ .size = 0, .usage = facet.BUFFER_USAGE_VERTEX_BUFFER }, &buffer));
    try testing.expectEqual(facet.Result.success, rig.fb.CreateBuffer(device, &.{ .size = 1000, .usage = facet.BUFFER_USAGE_VERTEX_BUFFER }, &buffer));
    defer rig.fb.DestroyBuffer(device, buffer);
    var needs: facet.MemoryRequirements = undefined;
    rig.fb.GetBufferMemoryRequirements(device, buffer.?, &needs);
    try testing.expectEqual(@as(u64, 1008), needs.size);
    try testing.expectEqual(@as(u64, 16), needs.alignment);
    try testing.expectEqual(@as(u32, 0b011), needs.memory_type_bits);

    const memory = try allocate(&rig, device, 4096);
    defer rig.fb.FreeMemory(device, memory);
    var lazy: ?*facet.DeviceMemory = null;
    try testing.expectEqual(facet.Result.success, rig.fb.AllocateMemory(device, &.{ .allocation_size = 4096, .memory_type_index = 2 }, &lazy));
    defer rig.fb.FreeMemory(device, lazy);
    try testing.expectEqual(facet.Result.error_out_of_device_memory, rig.fb.BindBufferMemory(device, buffer.?, lazy.?, 0));
    try testing.expectEqual(facet.Result.error_out_of_device_memory, rig.fb.BindBufferMemory(device, buffer.?, memory, 8));
    try testing.expectEqual(facet.Result.error_out_of_device_memory, rig.fb.BindBufferMemory(device, buffer.?, memory, 3200));
    try testing.expectEqual(facet.Result.success, rig.fb.BindBufferMemory(device, buffer.?, memory, 3088));
    try testing.expectEqual(facet.Result.error_out_of_device_memory, rig.fb.BindBufferMemory(device, buffer.?, memory, 0));
    var data: ?*anyopaque = null;
    try testing.expectEqual(facet.Result.success, rig.fb.MapMemory(device, memory, 0, facet.WHOLE_SIZE, 0, &data));
    const made = _objects.of(@import("../buffer/_buffer.zig").Buffer, buffer.?);
    try testing.expectEqual(@intFromPtr(data.?) + 3088, @intFromPtr(made.data.?));
}

test "an image: a texture, rows or a depth, by what it is for" {
    var rig = try Rig.up();
    defer rig.down() catch |err| std.debug.panic("{}", .{err});
    const instance, const physical = try rig.instance();
    defer rig.fb.DestroyInstance(instance);
    const device = try rig.device(physical);
    defer rig.fb.DestroyDevice(device);

    const sampled = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST;
    var image: ?*facet.Image = null;
    var needs: facet.MemoryRequirements = undefined;
    // A texture: its levels in blocks, 8 bytes an 8888 texel.
    try testing.expectEqual(facet.Result.success, rig.fb.CreateImage(device, &.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = 256, .height = 256 }, .mip_levels = 9, .usage = sampled }, &image));
    rig.fb.GetImageMemoryRequirements(device, image.?, &needs);
    try testing.expectEqual(try texture.Texture.bytes(.rgba8888, 256, 256, 9), needs.size);
    try testing.expectEqual(@as(u64, 64), needs.alignment);
    try testing.expectEqual(@as(u32, 0b011), needs.memory_type_bits);
    var layout: facet.SubresourceLayout = undefined;
    rig.fb.GetImageSubresourceLayout(device, image.?, &.{ .mip_level = 1 }, &layout);
    try testing.expectEqual(@as(u64, 256 * 256 * 8), layout.offset);
    try testing.expectEqual(@as(u64, 128 * 128 * 8), layout.size);
    rig.fb.DestroyImage(device, image);

    // A texture of any size, since 1.42: each level the one before halved
    // and no less than one, its blocks laid out by the next power of two
    // across - 100 by 60 keeps 32 blocks by 15 - and nothing padded down.
    try testing.expectEqual(facet.Result.success, rig.fb.CreateImage(device, &.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = 100, .height = 60 }, .mip_levels = 6, .usage = sampled }, &image));
    rig.fb.GetImageMemoryRequirements(device, image.?, &needs);
    try testing.expectEqual(try texture.Texture.bytes(.rgba8888, 100, 60, 6), needs.size);
    rig.fb.GetImageSubresourceLayout(device, image.?, &.{ .mip_level = 1 }, &layout);
    try testing.expectEqual(@as(u64, 32 * 15 * 16 * 8), layout.offset);
    const levels = &_objects.of(_image.Image, image.?).texels;
    for ([6]u32{ 100, 50, 25, 12, 6, 3 }, [6]u32{ 60, 30, 15, 7, 3, 1 }, 0..) |across, down, lod| {
        try testing.expectEqual(across, levels.width(@intCast(lod)));
        try testing.expectEqual(down, levels.height(@intCast(lod)));
    }
    rig.fb.DestroyImage(device, image);
    // More levels than halving the longer side gives is still refused.
    try testing.expectEqual(facet.Result.error_format_not_supported, rig.fb.CreateImage(device, &.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = 100, .height = 60 }, .mip_levels = 8, .usage = sampled }, &image));

    // Rows: each on a cache line.
    try testing.expectEqual(facet.Result.success, rig.fb.CreateImage(device, &.{ .format = .r8g8b8a8_unorm, .extent = .{ .width = 100, .height = 30 }, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, &image));
    rig.fb.GetImageMemoryRequirements(device, image.?, &needs);
    try testing.expectEqual(@as(u64, 448 * 30), needs.size);
    rig.fb.GetImageSubresourceLayout(device, image.?, &.{}, &layout);
    try testing.expectEqual(@as(u64, 448), layout.row_pitch);
    rig.fb.DestroyImage(device, image);
    try testing.expectEqual(facet.Result.success, rig.fb.CreateImage(device, &.{ .format = .r5g6b5_unorm_pack16, .extent = .{ .width = 100, .height = 30 }, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, &image));
    rig.fb.GetImageSubresourceLayout(device, image.?, &.{}, &layout);
    try testing.expectEqual(@as(u64, 256), layout.row_pitch);
    rig.fb.DestroyImage(device, image);

    // A depth: any memory type, the lazily allocated one too.
    try testing.expectEqual(facet.Result.success, rig.fb.CreateImage(device, &.{ .format = .d16_unorm, .extent = .{ .width = 800, .height = 600 }, .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT }, &image));
    rig.fb.GetImageMemoryRequirements(device, image.?, &needs);
    try testing.expectEqual(@as(u32, 0b111), needs.memory_type_bits);
    var lazy: ?*facet.DeviceMemory = null;
    try testing.expectEqual(facet.Result.success, rig.fb.AllocateMemory(device, &.{ .allocation_size = needs.size, .memory_type_index = 2 }, &lazy));
    try testing.expectEqual(facet.Result.success, rig.fb.BindImageMemory(device, image.?, lazy.?, 0));
    var view: ?*facet.ImageView = null;
    try testing.expectEqual(facet.Result.success, rig.fb.CreateImageView(device, &.{ .image = image.?, .format = .d16_unorm, .subresource_range = .{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH } }, &view));
    rig.fb.DestroyImageView(device, view);
    rig.fb.DestroyImage(device, image);
    rig.fb.FreeMemory(device, lazy);

    // What facet.library 1.0 does not make.
    const refused = [_]facet.ImageCreateInfo{
        .{ .format = .b8g8r8a8_unorm, .extent = .{ .width = 64, .height = 64 }, .usage = sampled | facet.IMAGE_USAGE_COLOR_ATTACHMENT },
        .{ .format = .b8g8r8a8_unorm, .extent = .{ .width = 64, .height = 64 }, .tiling = .linear, .usage = sampled },
        .{ .format = .b8g8r8a8_unorm, .extent = .{ .width = 64, .height = 64 }, .mip_levels = 8, .usage = sampled },
        .{ .format = .r32_sfloat, .extent = .{ .width = 64, .height = 64 }, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT },
        .{ .format = .d16_unorm, .extent = .{ .width = 64, .height = 64 }, .usage = facet.IMAGE_USAGE_SAMPLED },
        .{ .format = .b8g8r8a8_unorm, .extent = .{ .width = 64, .height = 64, .depth = 2 }, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT },
        .{ .format = .b8g8r8a8_unorm, .extent = .{ .width = 64, .height = 64 }, .samples = 2, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT },
        .{ .format = .b8g8r8a8_unorm, .extent = .{ .width = 64, .height = 64 }, .samples = 8, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT },
        .{ .format = .r32g32_sfloat, .extent = .{ .width = 64, .height = 64 }, .usage = facet.IMAGE_USAGE_TRANSFER_DST },
        .{ .format = .b8g8r8a8_unorm, .extent = .{ .width = 16384, .height = 64 }, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT },
    };
    for (refused) |info| {
        try testing.expectEqual(facet.Result.error_format_not_supported, rig.fb.CreateImage(device, &info, &image));
        try testing.expect(image == null);
    }
}

test "a compressed image down to its last level, and no compressed image of one dimension" {
    var rig = try Rig.up();
    defer rig.down() catch |err| std.debug.panic("{}", .{err});
    const instance, const physical = try rig.instance();
    defer rig.fb.DestroyInstance(instance);
    const device = try rig.device(physical);
    defer rig.fb.DestroyDevice(device);
    const fb = rig.fb;
    const sampled = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST;

    // A block of 8 bytes, BC1's and BC4's, at every level down to one
    // texel: until 1.97 the level 4 texels across overflowed its layout,
    // in CreateImage and in the query's largest image, which has them all.
    // BC3's block of 16 bytes did not, and is here beside them.
    for ([_]facet.Format{ .bc1_rgb_unorm_block, .bc1_rgba_unorm_block, .bc4_unorm_block, .bc3_unorm_block }) |format| {
        var image: ?*facet.Image = null;
        try testing.expectEqual(facet.Result.success, fb.CreateImage(device, &.{ .format = format, .extent = .{ .width = 16, .height = 16, .depth = 1 }, .mip_levels = 5, .usage = sampled }, &image));
        fb.DestroyImage(device, image);
        var properties: facet.ImageFormatProperties = undefined;
        try testing.expectEqual(facet.Result.success, fb.GetPhysicalDeviceImageFormatProperties(physical, format, .@"2d", .optimal, sampled, 0, &properties));
        try testing.expectEqual(@as(u32, 14), properties.max_mip_levels);

        // And no compressed image of one dimension, as neither Mesa driver
        // makes one: the query and CreateImage say so alike.
        try testing.expectEqual(facet.Result.error_format_not_supported, fb.GetPhysicalDeviceImageFormatProperties(physical, format, .@"1d", .optimal, sampled, 0, &properties));
        try testing.expectEqual(facet.Result.error_format_not_supported, fb.CreateImage(device, &.{ .format = format, .image_type = .@"1d", .extent = .{ .width = 16, .height = 1, .depth = 1 }, .usage = sampled }, &image));
    }
    // ETC2 is unpacked as it is copied in, and is refused as one dimension
    // all the same.
    var image: ?*facet.Image = null;
    try testing.expectEqual(facet.Result.error_format_not_supported, fb.CreateImage(device, &.{ .format = .etc2_r8g8b8_unorm_block, .image_type = .@"1d", .extent = .{ .width = 16, .height = 1, .depth = 1 }, .usage = sampled }, &image));
}

test "a copy into a texture: each texel where the texture layout keeps it, as 0xAARRGGBB; a view from a level on" {
    var rig = try Rig.up();
    defer rig.down() catch |err| std.debug.panic("{}", .{err});
    const instance, const physical = try rig.instance();
    defer rig.fb.DestroyInstance(instance);
    const device = try rig.device(physical);
    defer rig.fb.DestroyDevice(device);

    var image: ?*facet.Image = null;
    try testing.expectEqual(facet.Result.success, rig.fb.CreateImage(device, &.{ .format = .r8g8b8a8_unorm, .extent = .{ .width = 64, .height = 32 }, .mip_levels = 3, .usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST }, &image));
    defer rig.fb.DestroyImage(device, image);
    var needs: facet.MemoryRequirements = undefined;
    rig.fb.GetImageMemoryRequirements(device, image.?, &needs);
    const memory = try allocate(&rig, device, needs.size);
    defer rig.fb.FreeMemory(device, memory);
    try testing.expectEqual(facet.Result.success, rig.fb.BindImageMemory(device, image.?, memory, 0));

    // A 10 x 6 rectangle at (50, 20) of the first level, from rows 16
    // texels long, each texel's bytes red, green, blue, alpha.
    var bytes: [16 * 6 * 4]u8 = undefined;
    for (0..6) |y| for (0..16) |x| {
        const at = (y * 16 + x) * 4;
        bytes[at..][0..4].* = .{ @intCast(x), @intCast(y), 0x80, 0xFF };
    };
    const made = _objects.of(_image.Image, image.?);
    @memset(made.data.?[0..@intCast(needs.size)], 0);
    _image.copyFromBuffer(made, &bytes, &.{ .buffer_row_length = 16, .image_offset = .{ .x = 50, .y = 20 }, .image_extent = .{ .width = 10, .height = 6 } });
    const kept: [*]const u64 = @ptrCast(@alignCast(made.data.?));
    for (0..32) |y| for (0..64) |x| {
        const texel = texture.gather(kept[made.texels.index(0, @intCast(x), @intCast(y))]);
        const inside = x >= 50 and x < 60 and y >= 20 and y < 26;
        const want: u32 = if (inside) 0xFF00_0080 | @as(u32, @intCast(x - 50)) << 16 | @as(u32, @intCast(y - 20)) << 8 else 0;
        try testing.expectEqual(want, texel);
    };
    // Past the image's edge, or past the end of the buffer: left out.
    _image.copyFromBuffer(made, &bytes, &.{ .buffer_row_length = 16, .image_offset = .{ .x = 60, .y = 30 }, .image_extent = .{ .width = 10, .height = 6 } });
    try testing.expectEqual(@as(u32, 0xFF03_0180), texture.gather(kept[made.texels.index(0, 63, 31)]));
    _image.copyFromBuffer(made, bytes[0..100], &.{ .image_extent = .{ .width = 16, .height = 6 } });
    try testing.expectEqual(@as(u32, 0), texture.gather(kept[made.texels.index(0, 0, 1)]));

    var view: ?*facet.ImageView = null;
    try testing.expectEqual(facet.Result.error_format_not_supported, rig.fb.CreateImageView(device, &.{ .image = image.?, .format = .b8g8r8a8_unorm }, &view));
    try testing.expectEqual(facet.Result.error_format_not_supported, rig.fb.CreateImageView(device, &.{ .image = image.?, .format = .r8g8b8a8_unorm, .components = .{ .r = .b } }, &view));
    try testing.expectEqual(facet.Result.error_format_not_supported, rig.fb.CreateImageView(device, &.{ .image = image.?, .format = .r8g8b8a8_unorm, .subresource_range = .{ .base_mip_level = 1, .level_count = 3 } }, &view));
    try testing.expectEqual(facet.Result.success, rig.fb.CreateImageView(device, &.{ .image = image.?, .format = .r8g8b8a8_unorm, .subresource_range = .{ .base_mip_level = 1 } }, &view));
    defer rig.fb.DestroyImageView(device, view);
    const seen = _objects.of(_image.ImageView, view.?);
    try testing.expectEqual(@as(u32, 2), seen.texels.levels);
    try testing.expectEqual(@as(u32, 32), seen.texels.width(0));
    try testing.expectEqual(@as(u32, 16), seen.texels.height(0));
    try testing.expectEqual(@intFromPtr(made.data.?) + made.texels.layout[1].start, @intFromPtr(seen.texels.memory));
    try testing.expectEqual(made.texels.layout[2].start - made.texels.layout[1].start, seen.texels.layout[1].start);
}

test "a texture whose sides are not powers of two: copied into, and a view from a level on" {
    var rig = try Rig.up();
    defer rig.down() catch |err| std.debug.panic("{}", .{err});
    const instance, const physical = try rig.instance();
    defer rig.fb.DestroyInstance(instance);
    const device = try rig.device(physical);
    defer rig.fb.DestroyDevice(device);

    // 100 by 60: the blocks laid out by 128 across and 60 down, which is
    // what a view of a level has to go by as well.
    var image: ?*facet.Image = null;
    try testing.expectEqual(facet.Result.success, rig.fb.CreateImage(device, &.{ .format = .r8g8b8a8_unorm, .extent = .{ .width = 100, .height = 60 }, .mip_levels = 3, .usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST }, &image));
    defer rig.fb.DestroyImage(device, image);
    var needs: facet.MemoryRequirements = undefined;
    rig.fb.GetImageMemoryRequirements(device, image.?, &needs);
    const memory = try allocate(&rig, device, needs.size);
    defer rig.fb.FreeMemory(device, memory);
    try testing.expectEqual(facet.Result.success, rig.fb.BindImageMemory(device, image.?, memory, 0));
    const made = _objects.of(_image.Image, image.?);
    @memset(made.data.?[0..@intCast(needs.size)], 0);

    // Every texel of the level, each its own: copied in a row at a time
    // over a width that is not a whole number of blocks.
    var bytes: [100 * 60 * 4]u8 = undefined;
    for (0..60) |y| for (0..100) |x| {
        bytes[(y * 100 + x) * 4 ..][0..4].* = .{ @intCast(x % 256), @intCast(y), 0x40, 0xFF };
    };
    _image.copyFromBuffer(made, &bytes, &.{ .image_extent = .{ .width = 100, .height = 60 } });
    const kept: [*]const u64 = @ptrCast(@alignCast(made.data.?));
    for (0..60) |y| for (0..100) |x| {
        const want: u32 = 0xFF00_0040 | @as(u32, @intCast(x % 256)) << 16 | @as(u32, @intCast(y)) << 8;
        try testing.expectEqual(want, texture.gather(kept[made.texels.index(0, @intCast(x), @intCast(y))]));
    };

    // A view from level 1 on: 50 by 30, and its texels the image's own.
    var view: ?*facet.ImageView = null;
    try testing.expectEqual(facet.Result.success, rig.fb.CreateImageView(device, &.{ .image = image.?, .format = .r8g8b8a8_unorm, .subresource_range = .{ .base_mip_level = 1 } }, &view));
    defer rig.fb.DestroyImageView(device, view);
    const seen = _objects.of(_image.ImageView, view.?);
    try testing.expectEqual(@as(u32, 50), seen.texels.width(0));
    try testing.expectEqual(@as(u32, 30), seen.texels.height(0));
    try testing.expectEqual(@as(u32, 25), seen.texels.width(1));
    try testing.expectEqual(@as(u32, 15), seen.texels.height(1));
    try testing.expectEqual(@intFromPtr(made.data.?) + made.texels.layout[1].start, @intFromPtr(seen.texels.memory));
    try testing.expectEqual(made.texels.layout[2].start - made.texels.layout[1].start, seen.texels.layout[1].start);
    // A texel put through the view lands where the image keeps it: the
    // view's levels are laid out by the width the image was, not by their
    // own (`texture.Texture.from`).
    var writable = seen.texels;
    writable.put(1, 24, 14, 0x1234_5678);
    try testing.expectEqual(@as(u32, 0x1234_5678), made.texels.peek(2, 24, 14));
}

/// Every format this library names, for a test that asks the same of each.
const every_format = names: {
    const fields = @typeInfo(facet.Format).@"enum".fields;
    var all: [fields.len]facet.Format = undefined;
    for (fields, 0..) |field, n| all[n] = @enumFromInt(field.value);
    break :names all;
};

/// What CreateImage's image of `info` asks of its memory, or null where
/// CreateImage refuses it.
fn imageBytes(rig: *Rig, device: *facet.Device, info: facet.ImageCreateInfo) ?u64 {
    var image: ?*facet.Image = null;
    if (rig.fb.CreateImage(device, &info, &image) != .success) return null;
    defer rig.fb.DestroyImage(device, image);
    var needs: facet.MemoryRequirements = undefined;
    rig.fb.GetImageMemoryRequirements(device, image.?, &needs);
    return needs.size;
}

test "an image of four samples a pixel is four planes of one sample's bytes, and the format query says 4 exactly where one is made" {
    var rig = try Rig.up();
    defer rig.down() catch |err| std.debug.panic("{}", .{err});
    const instance, const physical = try rig.instance();
    defer rig.fb.DestroyInstance(instance);
    const device = try rig.device(physical);
    defer rig.fb.DestroyDevice(device);
    const fb = rig.fb;
    const record = _objects.of(_instance.PhysicalDevice, physical);
    const color = facet.IMAGE_USAGE_COLOR_ATTACHMENT;
    const depth = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT;
    const copied = facet.IMAGE_USAGE_TRANSFER_SRC | facet.IMAGE_USAGE_TRANSFER_DST;
    const small = facet.Extent3D{ .width = 37, .height = 19, .depth = 1 };

    // The cores draw four samples since 1.112; a device that does not
    // makes no image of four.
    try testing.expect(record.can.multisampling);
    record.can.multisampling = false;
    try testing.expectEqual(null, imageBytes(&rig, device, .{ .format = .b8g8r8a8_unorm, .extent = small, .samples = 4, .usage = color }));
    record.can.multisampling = true;

    // Four planes, each the whole of the image at one sample: a colour
    // attachment's rows, padded to a cache line at this width, and a
    // depth attachment's, with layers and without.
    const shapes = [_]struct { facet.Format, u32, u32 }{
        .{ .b8g8r8a8_unorm, color | copied, 1 },
        .{ .r8g8b8a8_unorm, color | facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT, 1 },
        .{ .r5g6b5_unorm_pack16, color | facet.IMAGE_USAGE_INPUT_ATTACHMENT, 3 },
        .{ .d16_unorm, depth | copied, 1 },
        .{ .s8_uint, depth, 6 },
        .{ .d16_unorm_s8_uint, depth | facet.IMAGE_USAGE_INPUT_ATTACHMENT, 2 },
        // Sampled where it lies, since 1.110.
        .{ .d16_unorm, depth | facet.IMAGE_USAGE_SAMPLED, 1 },
        .{ .d16_unorm_s8_uint, depth | facet.IMAGE_USAGE_SAMPLED | copied, 3 },
    };
    for (shapes) |shape| {
        const format, const usage, const layers = shape;
        var info = facet.ImageCreateInfo{ .format = format, .extent = small, .array_layers = layers, .usage = usage };
        const one = imageBytes(&rig, device, info) orelse return error.TestUnexpectedResult;
        info.samples = 4;
        try testing.expectEqual(@as(?u64, 4 * one), imageBytes(&rig, device, info));
    }
    // Sampled, of each colour format an attachment is drawn in (since
    // 1.110): rows at four samples, an attachment's of its size four times
    // over, where one sample is a texture's blocks. Not a colour attachment
    // or an input attachment as well, as one sample is neither, nor
    // written through, as no image of four samples is.
    for ([_]facet.Format{ .b8g8r8a8_unorm, .r8g8b8a8_unorm, .r5g6b5_unorm_pack16 }) |format| {
        const rows = imageBytes(&rig, device, .{ .format = format, .extent = small, .array_layers = 2, .usage = color }) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(?u64, 4 * rows), imageBytes(&rig, device, .{ .format = format, .extent = small, .array_layers = 2, .samples = 4, .usage = facet.IMAGE_USAGE_SAMPLED | copied }));
        for ([_]u32{ color, facet.IMAGE_USAGE_INPUT_ATTACHMENT, facet.IMAGE_USAGE_STORAGE }) |beside| {
            try testing.expectEqual(null, imageBytes(&rig, device, .{ .format = format, .extent = small, .samples = 4, .usage = facet.IMAGE_USAGE_SAMPLED | beside }));
        }
    }

    // What Vulkan forbids of a multisampled image, and what this library
    // does not make one of yet, is refused, each beside the same image
    // made at one sample.
    const refused = [_]facet.ImageCreateInfo{
        .{ .format = .b8g8r8a8_unorm, .image_type = .@"3d", .extent = small, .usage = copied },
        .{ .format = .b8g8r8a8_unorm, .image_type = .@"1d", .extent = .{ .width = 37, .height = 1, .depth = 1 }, .usage = copied },
        .{ .format = .d16_unorm, .extent = small, .mip_levels = 2, .usage = depth },
        .{ .format = .b8g8r8a8_unorm, .extent = small, .tiling = .linear, .usage = color },
        .{ .format = .b8g8r8a8_unorm, .flags = facet.IMAGE_CREATE_CUBE_COMPATIBLE, .extent = .{ .width = 16, .height = 16, .depth = 1 }, .array_layers = 6, .usage = color },
        .{ .format = .b8g8r8a8_unorm, .extent = small, .usage = color | facet.IMAGE_USAGE_STORAGE },
        .{ .format = .b8g8r8a8_unorm, .extent = small, .usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_STORAGE },
    };
    for (refused) |shape| {
        var info = shape;
        try testing.expect(imageBytes(&rig, device, info) != null);
        info.samples = 4;
        try testing.expectEqual(null, imageBytes(&rig, device, info));
    }
    for ([_]u32{ 2, 8, 16, 3 }) |count| {
        try testing.expectEqual(null, imageBytes(&rig, device, .{ .format = .b8g8r8a8_unorm, .extent = small, .samples = count, .usage = color }));
    }
    // A format that is no attachment is refused at four samples though
    // an image of it is made at one, as Vulkan says only one sample of it.
    var no_attachment: u32 = 0;
    for (every_format) |format| {
        var features: facet.FormatProperties = undefined;
        fb.GetPhysicalDeviceFormatProperties(physical, format, &features);
        if (features.optimal_tiling_features & (facet.FORMAT_FEATURE_COLOR_ATTACHMENT | facet.FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT) != 0) continue;
        var info = facet.ImageCreateInfo{ .format = format, .extent = small, .usage = copied };
        if (imageBytes(&rig, device, info) == null) continue;
        info.samples = 4;
        try testing.expectEqual(null, imageBytes(&rig, device, info));
        no_attachment += 1;
    }
    try testing.expect(no_attachment > 0);

    // The query asks CreateImage's own rules, at four samples as at one:
    // its largest image of four samples is the largest of one at one
    // level, four times the bytes.
    var properties: facet.ImageFormatProperties = undefined;
    try testing.expectEqual(facet.Result.success, fb.GetPhysicalDeviceImageFormatProperties(physical, .b8g8r8a8_unorm, .@"2d", .optimal, color, 0, &properties));
    try testing.expectEqual(facet.SAMPLE_COUNT_1 | facet.SAMPLE_COUNT_4, properties.sample_counts);
    try testing.expectEqual(@as(u64, 8192 * 4 * 8192 * 256 * 4), properties.max_resource_size);
    // Sampled, a colour and a depth (since 1.110): Vulkan has a query's
    // sample counts hold `sampled_image_color_sample_counts` and
    // `sampled_image_depth_sample_counts` for such a usage, 1 and 4 here.
    for ([_]struct { facet.Format, u32 }{
        .{ .r8g8b8a8_unorm, facet.IMAGE_USAGE_SAMPLED },
        .{ .r5g6b5_unorm_pack16, facet.IMAGE_USAGE_SAMPLED | copied },
        .{ .d16_unorm_s8_uint, depth | facet.IMAGE_USAGE_SAMPLED },
    }) |asked| {
        try testing.expectEqual(facet.Result.success, fb.GetPhysicalDeviceImageFormatProperties(physical, asked[0], .@"2d", .optimal, asked[1], 0, &properties));
        try testing.expectEqual(facet.SAMPLE_COUNT_1 | facet.SAMPLE_COUNT_4, properties.sample_counts);
    }

    // And over every format, image type, tiling, both flags and each of
    // the 255 usages, with the capability and without: 4 is said exactly
    // where CreateImage makes such an image at four samples, the largest
    // one inside what is answered and the smallest; never where Vulkan
    // has the answer be one sample alone (2D, optimal, not cube
    // compatible, a format that is an attachment); and never without the
    // capability.
    for ([_]bool{ false, true }) |can| {
        record.can.multisampling = can;
        var said_four: u32 = 0;
        for (every_format) |format| {
            var features: facet.FormatProperties = undefined;
            fb.GetPhysicalDeviceFormatProperties(physical, format, &features);
            const attachment = features.optimal_tiling_features & (facet.FORMAT_FEATURE_COLOR_ATTACHMENT | facet.FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT) != 0;
            for ([_]facet.ImageType{ .@"1d", .@"2d", .@"3d" }) |image_type| {
                for ([_]facet.ImageTiling{ .optimal, .linear }) |tiling| {
                    for ([_]u32{ 0, facet.IMAGE_CREATE_CUBE_COMPATIBLE }) |flags| {
                        for (1..256) |bits| {
                            const usage: u32 = @intCast(bits);
                            if (fb.GetPhysicalDeviceImageFormatProperties(physical, format, image_type, tiling, usage, flags, &properties) != .success) continue;
                            try testing.expectEqual(facet.SAMPLE_COUNT_1, properties.sample_counts & ~facet.SAMPLE_COUNT_4);
                            const four = properties.sample_counts & facet.SAMPLE_COUNT_4 != 0;
                            if (four) {
                                try testing.expect(can and attachment and image_type == .@"2d" and tiling == .optimal and flags == 0);
                                said_four += 1;
                            }
                            const largest = facet.ImageCreateInfo{ .flags = flags, .image_type = image_type, .format = format, .extent = properties.max_extent, .array_layers = properties.max_array_layers, .samples = 4, .tiling = tiling, .usage = usage };
                            try testing.expectEqual(four, imageBytes(&rig, device, largest) != null);
                            var smallest = largest;
                            smallest.extent = .{ .width = 1, .height = 1, .depth = 1 };
                            smallest.array_layers = if (flags != 0) 6 else 1;
                            try testing.expectEqual(four, imageBytes(&rig, device, smallest) != null);
                        }
                    }
                }
            }
        }
        if (can) try testing.expect(said_four > 0) else try testing.expectEqual(0, said_four);
    }
}

// --- command buffers, the queue, fences and semaphores -------------------------

const _stream = @import("../command/_stream.zig");
const _command = @import("../command/_command.zig");

test "the three device queries: the largest image of a shape, the render area's granularity, and what a block has behind it" {
    var rig = try Rig.up();
    defer rig.down() catch |err| std.debug.panic("{}", .{err});
    const instance, const physical = try rig.instance();
    defer rig.fb.DestroyInstance(instance);
    const device = try rig.device(physical);
    defer rig.fb.DestroyDevice(device);
    const fb = rig.fb;

    // A sampled image: the levels and the layers of the largest.
    var properties: facet.ImageFormatProperties = undefined;
    const sampled = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST;
    try testing.expectEqual(facet.Result.success, fb.GetPhysicalDeviceImageFormatProperties(physical, .b8g8r8a8_unorm, .@"2d", .optimal, sampled, 0, &properties));
    try testing.expectEqual(@as(u32, 8192), properties.max_extent.width);
    try testing.expectEqual(@as(u32, 8192), properties.max_extent.height);
    try testing.expectEqual(@as(u32, 1), properties.max_extent.depth);
    try testing.expectEqual(@as(u32, 14), properties.max_mip_levels);
    try testing.expectEqual(@as(u32, 256), properties.max_array_layers);
    // One sample or four: an image of four is sampled since 1.110, and the
    // cores draw four since 1.112.
    try testing.expectEqual(facet.SAMPLE_COUNT_1 | facet.SAMPLE_COUNT_4, properties.sample_counts);
    try testing.expect(properties.max_resource_size != 0);

    // A colour attachment is one level, and its bytes are its rows: one
    // layer of them in linear tiling, and in optimal tiling the 256 a
    // framebuffer may reach since 1.91, a layer's rows after the layer
    // before, at four samples a pixel since 1.112, four planes of them.
    try testing.expectEqual(facet.Result.success, fb.GetPhysicalDeviceImageFormatProperties(physical, .b8g8r8a8_unorm, .@"2d", .linear, facet.IMAGE_USAGE_COLOR_ATTACHMENT, 0, &properties));
    try testing.expectEqual(@as(u32, 1), properties.max_mip_levels);
    try testing.expectEqual(@as(u32, 1), properties.max_array_layers);
    try testing.expectEqual(@as(u64, 8192 * 4 * 8192), properties.max_resource_size);
    try testing.expectEqual(facet.Result.success, fb.GetPhysicalDeviceImageFormatProperties(physical, .b8g8r8a8_unorm, .@"2d", .optimal, facet.IMAGE_USAGE_COLOR_ATTACHMENT, 0, &properties));
    try testing.expectEqual(@as(u32, 1), properties.max_mip_levels);
    try testing.expectEqual(@as(u32, 256), properties.max_array_layers);
    try testing.expectEqual(facet.SAMPLE_COUNT_1 | facet.SAMPLE_COUNT_4, properties.sample_counts);
    try testing.expectEqual(@as(u64, 8192 * 4 * 8192 * 256 * 4), properties.max_resource_size);
    // A depth attachment has the levels 1.63 gave it, and the layers 1.58
    // gave one sampled as well, which since 1.91 one never sampled has
    // too, for a framebuffer of layers.
    try testing.expectEqual(facet.Result.success, fb.GetPhysicalDeviceImageFormatProperties(physical, .d16_unorm, .@"2d", .optimal, facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT, 0, &properties));
    try testing.expectEqual(@as(u32, 14), properties.max_mip_levels);
    try testing.expectEqual(@as(u32, 256), properties.max_array_layers);
    try testing.expectEqual(facet.Result.success, fb.GetPhysicalDeviceImageFormatProperties(physical, .d16_unorm, .@"2d", .optimal, facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_SAMPLED, 0, &properties));
    try testing.expectEqual(@as(u32, 14), properties.max_mip_levels);
    try testing.expectEqual(@as(u32, 256), properties.max_array_layers);
    // A 3D image is 256 cubed, of one layer - its depth being its layers
    // - and of the levels each of its slices has.
    try testing.expectEqual(facet.Result.success, fb.GetPhysicalDeviceImageFormatProperties(physical, .b8g8r8a8_unorm, .@"3d", .optimal, sampled, 0, &properties));
    try testing.expectEqual(@as(u32, 256), properties.max_extent.depth);
    try testing.expectEqual(@as(u32, 9), properties.max_mip_levels);
    try testing.expectEqual(@as(u32, 1), properties.max_array_layers);
    // A cube's six layers are there to be had.
    try testing.expectEqual(facet.Result.success, fb.GetPhysicalDeviceImageFormatProperties(physical, .b8g8r8a8_unorm, .@"2d", .optimal, sampled, facet.IMAGE_CREATE_CUBE_COMPATIBLE, &properties));
    try testing.expectEqual(@as(u32, 256), properties.max_array_layers);

    // `max_resource_size` is the bytes of the image the rest of the
    // answer describes, to the byte: the same image made, and
    // GetImageMemoryRequirements asked (since 1.66). CreateImage lays an
    // image out and binds nothing, so the largest of them costs an
    // object and no memory at all. Where the answer says four samples a
    // pixel, which the cores draw since 1.112, it is the larger of that
    // image and the largest of four, one level as such an image is: a
    // sampled colour image of four is kept in rows, a word a pixel in
    // each sample's plane, where one of one is a texture of two words a
    // texel and its levels.
    const shapes = [_]struct { facet.Format, facet.ImageType, facet.ImageTiling, u32, u32 }{
        .{ .b8g8r8a8_unorm, .@"2d", .optimal, sampled, 0 },
        .{ .b8g8r8a8_unorm, .@"2d", .optimal, sampled, facet.IMAGE_CREATE_CUBE_COMPATIBLE },
        .{ .b8g8r8a8_unorm, .@"2d", .linear, facet.IMAGE_USAGE_COLOR_ATTACHMENT, 0 },
        .{ .b8g8r8a8_unorm, .@"3d", .optimal, sampled, 0 },
        .{ .d16_unorm, .@"2d", .optimal, facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT, 0 },
        .{ .d16_unorm_s8_uint, .@"2d", .optimal, facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_SAMPLED, 0 },
        .{ .r16g16b16a16_sfloat, .@"2d", .optimal, sampled, 0 },
    };
    for (shapes) |shape| {
        const format, const kind, const tiling, const usage, const flags = shape;
        try testing.expectEqual(facet.Result.success, fb.GetPhysicalDeviceImageFormatProperties(physical, format, kind, tiling, usage, flags, &properties));
        const volume = kind == .@"3d";
        var largest: ?*facet.Image = null;
        try testing.expectEqual(facet.Result.success, fb.CreateImage(device, &.{
            .flags = flags,
            .image_type = kind,
            .format = format,
            .extent = properties.max_extent,
            .mip_levels = properties.max_mip_levels,
            .array_layers = properties.max_array_layers,
            .tiling = tiling,
            .usage = usage,
        }, &largest));
        var needs: facet.MemoryRequirements = undefined;
        fb.GetImageMemoryRequirements(device, largest.?, &needs);
        fb.DestroyImage(device, largest);
        var most = needs.size;
        if (properties.sample_counts & facet.SAMPLE_COUNT_4 != 0) {
            var four: ?*facet.Image = null;
            try testing.expectEqual(facet.Result.success, fb.CreateImage(device, &.{
                .flags = flags,
                .image_type = kind,
                .format = format,
                .extent = properties.max_extent,
                .array_layers = properties.max_array_layers,
                .samples = 4,
                .tiling = tiling,
                .usage = usage,
            }, &four));
            fb.GetImageMemoryRequirements(device, four.?, &needs);
            fb.DestroyImage(device, four);
            most = @max(most, needs.size);
        }
        try testing.expectEqual(properties.max_resource_size, most);
        // One level more, or one layer more, is refused: the answer is
        // the largest there is.
        var over: ?*facet.Image = null;
        try testing.expectEqual(facet.Result.error_format_not_supported, fb.CreateImage(device, &.{
            .flags = flags,
            .image_type = kind,
            .format = format,
            .extent = properties.max_extent,
            .mip_levels = properties.max_mip_levels + 1,
            .array_layers = properties.max_array_layers,
            .tiling = tiling,
            .usage = usage,
        }, &over));
        if (!volume) try testing.expectEqual(facet.Result.error_format_not_supported, fb.CreateImage(device, &.{
            .flags = flags,
            .image_type = kind,
            .format = format,
            .extent = properties.max_extent,
            .mip_levels = properties.max_mip_levels,
            .array_layers = properties.max_array_layers + 1,
            .tiling = tiling,
            .usage = usage,
        }, &over));
        try testing.expect(over == null);
    }

    // Shapes there is no image of at all, and nothing written for them.
    properties = .{ .max_mip_levels = 9 };
    try testing.expectEqual(facet.Result.error_format_not_supported, fb.GetPhysicalDeviceImageFormatProperties(physical, .d16_unorm, .@"2d", .linear, facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT, 0, &properties));
    try testing.expectEqual(@as(u32, 0), properties.max_mip_levels);
    // A 1D image is an image here since 1.86: a texture of one row, as
    // wide as a 2D image and with the levels halving that width alone,
    // which is Vulkan's own rule for one (item 21).
    try testing.expectEqual(facet.Result.success, fb.GetPhysicalDeviceImageFormatProperties(physical, .b8g8r8a8_unorm, .@"1d", .optimal, sampled, 0, &properties));
    var limits: facet.PhysicalDeviceProperties = undefined;
    fb.GetPhysicalDeviceProperties(physical, &limits);
    try testing.expect(limits.limits.max_image_dimension_1d >= 4096);
    try testing.expectEqual(limits.limits.max_image_dimension_1d, properties.max_extent.width);
    try testing.expectEqual(@as(u32, 1), properties.max_extent.height);
    try testing.expectEqual(@as(u32, 1), properties.max_extent.depth);
    try testing.expectEqual(std.math.log2_int(u32, limits.limits.max_image_dimension_1d) + 1, properties.max_mip_levels);
    // A colour attachment that is sampled as well is no image here.
    try testing.expectEqual(facet.Result.error_format_not_supported, fb.GetPhysicalDeviceImageFormatProperties(physical, .b8g8r8a8_unorm, .@"2d", .optimal, sampled | facet.IMAGE_USAGE_COLOR_ATTACHMENT, 0, &properties));
    // And a format nothing is made of.
    try testing.expectEqual(facet.Result.error_format_not_supported, fb.GetPhysicalDeviceImageFormatProperties(physical, .undefined, .@"2d", .optimal, sampled, 0, &properties));

    // What the query answers is what CreateImage does: the largest
    // extent of a shape is made, and one texel over it is refused.
    var image: ?*facet.Image = null;
    try testing.expectEqual(facet.Result.success, fb.GetPhysicalDeviceImageFormatProperties(physical, .b8g8r8a8_unorm, .@"2d", .linear, facet.IMAGE_USAGE_COLOR_ATTACHMENT, 0, &properties));
    const widest = properties.max_extent.width;
    try testing.expectEqual(facet.Result.success, fb.CreateImage(device, &.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = widest, .height = 1 }, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, &image));
    fb.DestroyImage(device, image);
    try testing.expectEqual(facet.Result.error_format_not_supported, fb.CreateImage(device, &.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = widest + 1, .height = 1 }, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, &image));
    try testing.expect(image == null);

    // The render area's granularity is the device's tile, whatever the
    // pass.
    const attachment = facet.AttachmentDescription{ .format = .b8g8r8a8_unorm, .store_op = .store, .final_layout = .color_attachment_optimal };
    const color = facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
    const subpass = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&color) };
    var pass: ?*facet.RenderPass = null;
    try testing.expectEqual(facet.Result.success, fb.CreateRenderPass(device, &.{ .attachment_count = 1, .attachments = @ptrCast(&attachment), .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &pass));
    defer fb.DestroyRenderPass(device, pass);
    var device_properties: facet.PhysicalDeviceProperties = undefined;
    fb.GetPhysicalDeviceProperties(physical, &device_properties);
    var granularity: facet.Extent2D = undefined;
    fb.GetRenderAreaGranularity(device, pass.?, &granularity);
    // GetRenderAreaGranularity is Vulkan's way to ask the tile, and since
    // 1.82 it is the only way: the number left PhysicalDeviceLimits with
    // `cores`, Vulkan having no member for either.
    const tile = _objects.of(_instance.PhysicalDevice, physical).tile_size;
    try testing.expectEqual(tile, granularity.width);
    try testing.expectEqual(tile, granularity.height);
    try testing.expect(granularity.width != 0);

    // What a block has behind it: all of a plain one, none of a lazily
    // allocated one.
    const block = try allocate(&rig, device, 4096);
    var bytes: u64 = 0xFFFF;
    fb.GetDeviceMemoryCommitment(device, block, &bytes);
    try testing.expectEqual(@as(u64, 4096), bytes);
    var lazy: ?*facet.DeviceMemory = null;
    try testing.expectEqual(facet.Result.success, fb.AllocateMemory(device, &.{ .allocation_size = 4 << 20, .memory_type_index = 2 }, &lazy));
    fb.GetDeviceMemoryCommitment(device, lazy.?, &bytes);
    try testing.expectEqual(@as(u64, 0), bytes);
    fb.FreeMemory(device, lazy);
    fb.FreeMemory(device, block);
}

test "a recording: its commands in order over its chunks; a reset keeps them for the next, or gives them back" {
    var rig = try Rig.up();
    defer rig.down() catch |err| std.debug.panic("{}", .{err});
    const free_before = rig.header.free;
    var stream: _stream.Stream = .{};
    // Barriers, and copies whose regions take more than a chunk.
    var regions: [300]facet.BufferCopy = undefined;
    for (&regions, 0..) |*region, k| region.* = .{ .src_offset = k, .size = 1 };
    const fake: *@import("../buffer/_buffer.zig").Buffer = @ptrFromInt(64);
    for (0..1000) |k| {
        if (k % 100 == 0) {
            stream.put(rig.sys, _command.CopyBuffer{ .count = @intCast(k / 100 + 1), .source = fake, .destination = fake }, facet.BufferCopy, regions[0 .. k / 100 * 30 + 1]);
        } else stream.put(rig.sys, _command.Barrier{ .src_stage_mask = @intCast(k), .dst_stage_mask = 0 }, u8, &.{});
    }
    try testing.expect(!stream.failed);
    var commands = stream.commands();
    var k: u32 = 0;
    while (commands.next()) |head| : (k += 1) {
        if (k % 100 == 0) {
            try testing.expectEqual(_stream.Op.copy_buffer, head.op);
            const copy = _stream.as(_command.CopyBuffer, head);
            const carried = _stream.items(_command.CopyBuffer, facet.BufferCopy, copy, k / 100 * 30 + 1);
            try testing.expectEqual(@as(u64, k / 100 * 30), carried[carried.len - 1].src_offset);
        } else {
            try testing.expectEqual(_stream.Op.barrier, head.op);
            try testing.expectEqual(k, _stream.as(_command.Barrier, head).src_stage_mask);
        }
    }
    try testing.expectEqual(@as(u32, 1000), k);

    // Recorded again after a reset: the chunks reused, only the new
    // commands played.
    stream.reset(rig.sys, false);
    const free_kept = rig.header.free;
    for (0..10) |n| stream.put(rig.sys, _command.Barrier{ .src_stage_mask = @intCast(n + 5000), .dst_stage_mask = 0 }, u8, &.{});
    try testing.expectEqual(free_kept, rig.header.free);
    commands = stream.commands();
    k = 0;
    while (commands.next()) |head| : (k += 1) try testing.expectEqual(k + 5000, _stream.as(_command.Barrier, head).src_stage_mask);
    try testing.expectEqual(@as(u32, 10), k);
    stream.reset(rig.sys, false);
    commands = stream.commands();
    try testing.expect(commands.next() == null);
    stream.reset(rig.sys, true);
    try testing.expectEqual(free_before, rig.header.free);
}

/// The nine sample-count masks of `limits` in VkPhysicalDeviceLimits'
/// order: the framebuffer's colour, depth, stencil and no-attachments
/// masks, then the sampled image's colour, integer, depth and stencil
/// masks, and the storage image's.
fn expectSampleCounts(want: [9]u32, limits: *const facet.PhysicalDeviceLimits) !void {
    const got = [9]u32{
        limits.framebuffer_color_sample_counts,
        limits.framebuffer_depth_sample_counts,
        limits.framebuffer_stencil_sample_counts,
        limits.framebuffer_no_attachments_sample_counts,
        limits.sampled_image_color_sample_counts,
        limits.sampled_image_integer_sample_counts,
        limits.sampled_image_depth_sample_counts,
        limits.sampled_image_stencil_sample_counts,
        limits.storage_image_sample_counts,
    };
    try testing.expectEqualSlices(u32, &want, &got);
}

test "a device's sample counts follow what it draws, and the three optional multisample features stay off" {
    var rig = try Rig.up();
    defer rig.down() catch |err| std.debug.panic("{}", .{err});
    const instance, const physical = try rig.instance();
    defer rig.fb.DestroyInstance(instance);
    const record = _objects.of(_instance.PhysicalDevice, physical);
    const one = facet.SAMPLE_COUNT_1;
    const four = facet.SAMPLE_COUNT_1 | facet.SAMPLE_COUNT_4;

    // The library's table is what a device drawing four samples a pixel
    // may say: the 4 bit in the seven masks Vulkan asks it of, and the 1
    // bit alone in the integer and storage masks.
    try expectSampleCounts(.{ four, four, four, four, four, one, four, four, one }, &_instance.limits);

    // The cores draw four since 1.112, so six masks take the 4 bit, at
    // Vulkan's standard places. The no-attachments mask keeps the 1 bit
    // alone, since a subpass with no attachments cannot be made yet (item
    // 43).
    try testing.expect(record.can.multisampling);
    var properties: facet.PhysicalDeviceProperties = undefined;
    rig.fb.GetPhysicalDeviceProperties(physical, &properties);
    try expectSampleCounts(.{ four, four, four, one, four, one, four, four, one }, &properties.limits);
    try testing.expectEqual(facet.TRUE, properties.limits.standard_sample_locations);

    // The cores described again, as a device that does not draw four:
    // one sample in every mask.
    var plain = record.*;
    try testing.expect(record.ops.describe(rig.sys, &plain));
    plain.can.multisampling = false;
    _instance.narrowSampleCounts(&plain);
    try expectSampleCounts(.{ one, one, one, one, one, one, one, one, one }, &plain.properties.limits);

    // A bit a driver cleared stays clear, with the capability or without:
    // the V3D's four zeros for the images it does not sample
    // (driver/v3d/driver.zig), whose describe only the board can run.
    for ([_]bool{ false, true }) |can| {
        var v3d = record.*;
        v3d.properties.limits = _instance.limits;
        v3d.properties.limits.sampled_image_integer_sample_counts = 0;
        v3d.properties.limits.sampled_image_depth_sample_counts = 0;
        v3d.properties.limits.sampled_image_stencil_sample_counts = 0;
        v3d.properties.limits.storage_image_sample_counts = 0;
        v3d.can.multisampling = can;
        _instance.narrowSampleCounts(&v3d);
        const drawn = if (can) four else one;
        try expectSampleCounts(.{ drawn, drawn, drawn, one, drawn, 0, 0, 0, 0 }, &v3d.properties.limits);
    }

    // Sample rate shading, alpha to one and a variable sample rate are
    // optional, and none of them is a part of drawing four samples: each
    // stays false with the capability as it does without.
    for ([_]bool{ false, true }) |can| {
        record.can.multisampling = can;
        defer record.can.multisampling = true;
        var features: facet.PhysicalDeviceFeatures = undefined;
        rig.fb.GetPhysicalDeviceFeatures(physical, &features);
        try testing.expectEqual(facet.FALSE, features.sample_rate_shading);
        try testing.expectEqual(facet.FALSE, features.alpha_to_one);
        try testing.expectEqual(facet.FALSE, features.variable_multisample_rate);
    }
}

test "a device says what it does, and a false is what a create call refuses" {
    var rig = try Rig.up();
    defer rig.down() catch |err| std.debug.panic("{}", .{err});
    const instance, const physical = try rig.instance();
    defer rig.fb.DestroyInstance(instance);
    const device = try rig.device(physical);
    defer rig.fb.DestroyDevice(device);

    const can = _objects.of(_instance.PhysicalDevice, physical).can;

    // The cores: the rasterizer calls whatever function the pipeline carries,
    // and compute and tessellation are on this device because it is them.
    try testing.expect(can.own_fragment_functions);
    try testing.expect(can.sampling_format);
    try testing.expect(can.compute_on_device);
    try testing.expect(can.tessellation_on_device);
    try testing.expect(can.depth_prepass);
    try testing.expect(can.blending);
    try testing.expect(can.stencil_test);
    try testing.expect(can.several_subpasses);
    try testing.expect(can.cube_maps);
    // The cores hold the depth in their tiles, so they can keep it.
    try testing.expect(can.stored_depth);
    // A fragment function of the program's can read an attachment's rows.
    try testing.expect(can.input_attachments);
    // And four samples a pixel (since 1.112).
    try testing.expect(can.multisampling);

    // And what it says it does not do, it refuses: a false here is worth
    // having only if the call agrees with it.
    try testing.expect(!can.logic_ops);

    const color = facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
    var pass: ?*facet.RenderPass = null;

    // An input attachment that is drawn in the same subpass is a loop,
    // whatever the feature says.
    {
        const attachment = facet.AttachmentDescription{ .format = .b8g8r8a8_unorm, .load_op = .clear, .final_layout = .color_attachment_optimal };
        const subpass = facet.SubpassDescription{
            .input_attachment_count = 1,
            .input_attachments = @ptrCast(&color),
            .color_attachment_count = 1,
            .color_attachments = @ptrCast(&color),
        };
        const info = facet.RenderPassCreateInfo{ .attachment_count = 1, .attachments = @ptrCast(&attachment), .subpass_count = 1, .subpasses = @ptrCast(&subpass) };
        try testing.expectEqual(facet.Result.error_initialization_failed, rig.fb.CreateRenderPass(device, &info, &pass));
    }

    // Logic operations, which features deny.
    {
        try testing.expect(!can.logic_ops);
    }

    // Four samples are drawn, and two or eight, which no device draws,
    // are refused.
    for ([_]u32{ 4, 2, 8 }) |samples| {
        const attachment = facet.AttachmentDescription{ .format = .b8g8r8a8_unorm, .samples = samples, .load_op = .clear, .final_layout = .color_attachment_optimal };
        const subpass = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&color) };
        const info = facet.RenderPassCreateInfo{ .attachment_count = 1, .attachments = @ptrCast(&attachment), .subpass_count = 1, .subpasses = @ptrCast(&subpass) };
        const want: facet.Result = if (samples == 4) .success else .error_feature_not_present;
        try testing.expectEqual(want, rig.fb.CreateRenderPass(device, &info, &pass));
        rig.fb.DestroyRenderPass(device, pass);
        pass = null;
    }

    // One sample and no input attachment: the same pass is made.
    {
        const attachment = facet.AttachmentDescription{ .format = .b8g8r8a8_unorm, .load_op = .clear, .final_layout = .color_attachment_optimal };
        const subpass = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&color) };
        const info = facet.RenderPassCreateInfo{ .attachment_count = 1, .attachments = @ptrCast(&attachment), .subpass_count = 1, .subpasses = @ptrCast(&subpass) };
        try testing.expectEqual(facet.Result.success, rig.fb.CreateRenderPass(device, &info, &pass));
        rig.fb.DestroyRenderPass(device, pass);
    }
}

test "a draw of more vertices than one works is refused as it is recorded" {
    const max_draw_vertices = @import("../instance/_instance.zig").max_draw_vertices;
    var rig = try Rig.up();
    defer rig.down() catch |err| std.debug.panic("{}", .{err});
    const instance, const physical = try rig.instance();
    defer rig.fb.DestroyInstance(instance);
    const device = try rig.device(physical);
    defer rig.fb.DestroyDevice(device);

    var pool: ?*facet.CommandPool = null;
    try testing.expectEqual(facet.Result.success, rig.fb.CreateCommandPool(device, &.{ .flags = facet.COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER }, &pool));
    defer rig.fb.DestroyCommandPool(device, pool);
    var commands: [1]?*facet.CommandBuffer = undefined;
    try testing.expectEqual(facet.Result.success, rig.fb.AllocateCommandBuffers(device, &.{ .command_pool = pool.?, .command_buffer_count = 1 }, &commands));
    const buffer = commands[0].?;

    // As many as a draw works: recorded.
    try testing.expectEqual(facet.Result.success, rig.fb.BeginCommandBuffer(buffer, &.{}));
    rig.fb.CmdDraw(buffer, max_draw_vertices, 1, 0, 0);
    try testing.expectEqual(facet.Result.success, rig.fb.EndCommandBuffer(buffer));

    // One more than that: not recorded, and said so rather than left out of
    // the frame later without a word.
    try testing.expectEqual(facet.Result.success, rig.fb.ResetCommandBuffer(buffer, 0));
    try testing.expectEqual(facet.Result.success, rig.fb.BeginCommandBuffer(buffer, &.{}));
    rig.fb.CmdDraw(buffer, max_draw_vertices + 1, 1, 0, 0);
    try testing.expectEqual(facet.Result.error_feature_not_present, rig.fb.EndCommandBuffer(buffer));

    // Spent: it records again only after a reset, and the refusal is not kept.
    try testing.expectEqual(facet.Result.error_initialization_failed, rig.fb.EndCommandBuffer(buffer));
    try testing.expectEqual(facet.Result.success, rig.fb.ResetCommandBuffer(buffer, 0));
    try testing.expectEqual(facet.Result.success, rig.fb.BeginCommandBuffer(buffer, &.{}));
    rig.fb.CmdDraw(buffer, 3, 1, 0, 0);
    try testing.expectEqual(facet.Result.success, rig.fb.EndCommandBuffer(buffer));
}

/// A buffer of `bytes` bound into memory of its own, mapped.
pub fn mappedBuffer(rig: *Rig, device: *facet.Device, bytes: u64, usage: u32) !struct { *facet.Buffer, *facet.DeviceMemory, [*]u8 } {
    var buffer: ?*facet.Buffer = null;
    try testing.expectEqual(facet.Result.success, rig.fb.CreateBuffer(device, &.{ .size = bytes, .usage = usage }, &buffer));
    var needs: facet.MemoryRequirements = undefined;
    rig.fb.GetBufferMemoryRequirements(device, buffer.?, &needs);
    const memory = try allocate(rig, device, needs.size);
    try testing.expectEqual(facet.Result.success, rig.fb.BindBufferMemory(device, buffer.?, memory, 0));
    var data: ?*anyopaque = null;
    try testing.expectEqual(facet.Result.success, rig.fb.MapMemory(device, memory, 0, facet.WHOLE_SIZE, 0, &data));
    return .{ buffer.?, memory, @ptrCast(data.?) };
}

test "a submission plays its command buffers in order, then signals its fence; a one-time buffer is spent" {
    var rig = try Rig.up();
    defer rig.down() catch |err| std.debug.panic("{}", .{err});
    const instance, const physical = try rig.instance();
    defer rig.fb.DestroyInstance(instance);
    const device = try rig.device(physical);
    defer rig.fb.DestroyDevice(device);
    var queue: ?*facet.Queue = null;
    rig.fb.GetDeviceQueue(device, 0, 0, &queue);

    // A staging buffer: 16 x 16 texels, then 64 bytes for the other copy.
    const staging, const staging_memory, const staged = try mappedBuffer(&rig, device, 16 * 16 * 4 + 64, facet.BUFFER_USAGE_TRANSFER_SRC);
    defer rig.fb.FreeMemory(device, staging_memory);
    defer rig.fb.DestroyBuffer(device, staging);
    for (0..256) |k| std.mem.writeInt(u32, staged[k * 4 ..][0..4], 0xFF00_0000 | @as(u32, @intCast(k)), .little);
    for (0..64) |k| staged[1024 + k] = @intCast(k ^ 0x55);
    const target, const target_memory, const copied = try mappedBuffer(&rig, device, 64, facet.BUFFER_USAGE_TRANSFER_DST);
    defer rig.fb.FreeMemory(device, target_memory);
    defer rig.fb.DestroyBuffer(device, target);
    @memset(copied[0..64], 0);

    var image: ?*facet.Image = null;
    try testing.expectEqual(facet.Result.success, rig.fb.CreateImage(device, &.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = 16, .height = 16 }, .usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST }, &image));
    defer rig.fb.DestroyImage(device, image);
    var needs: facet.MemoryRequirements = undefined;
    rig.fb.GetImageMemoryRequirements(device, image.?, &needs);
    const image_memory = try allocate(&rig, device, needs.size);
    defer rig.fb.FreeMemory(device, image_memory);
    try testing.expectEqual(facet.Result.success, rig.fb.BindImageMemory(device, image.?, image_memory, 0));

    var pool: ?*facet.CommandPool = null;
    try testing.expectEqual(facet.Result.success, rig.fb.CreateCommandPool(device, &.{}, &pool));
    defer rig.fb.DestroyCommandPool(device, pool);
    var commands: [2]?*facet.CommandBuffer = undefined;
    try testing.expectEqual(facet.Result.error_feature_not_present, rig.fb.AllocateCommandBuffers(device, &.{ .command_pool = pool.?, .level = @enumFromInt(2), .command_buffer_count = 2 }, &commands));
    try testing.expectEqual(facet.Result.success, rig.fb.AllocateCommandBuffers(device, &.{ .command_pool = pool.?, .command_buffer_count = 2 }, &commands));

    // Recorded outside a recording: nothing.
    const region = facet.BufferImageCopy{ .image_extent = .{ .width = 16, .height = 16 } };
    rig.fb.CmdCopyBufferToImage(commands[0].?, staging, image.?, .transfer_dst_optimal, 1, @ptrCast(&region));
    try testing.expectEqual(facet.Result.error_initialization_failed, rig.fb.EndCommandBuffer(commands[0].?));

    try testing.expectEqual(facet.Result.success, rig.fb.BeginCommandBuffer(commands[0].?, &.{ .flags = facet.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT }));
    const barrier = facet.ImageMemoryBarrier{ .new_layout = .transfer_dst_optimal, .image = image.? };
    rig.fb.CmdPipelineBarrier(commands[0].?, facet.PIPELINE_STAGE_TOP_OF_PIPE, facet.PIPELINE_STAGE_TRANSFER, 0, 0, null, 0, null, 1, @ptrCast(&barrier));
    rig.fb.CmdCopyBufferToImage(commands[0].?, staging, image.?, .transfer_dst_optimal, 1, @ptrCast(&region));
    try testing.expectEqual(facet.Result.success, rig.fb.EndCommandBuffer(commands[0].?));
    try testing.expectEqual(facet.Result.success, rig.fb.BeginCommandBuffer(commands[1].?, &.{}));
    const bytes = facet.BufferCopy{ .src_offset = 1024, .dst_offset = 0, .size = 64 };
    rig.fb.CmdCopyBuffer(commands[1].?, staging, target, 1, @ptrCast(&bytes));
    try testing.expectEqual(facet.Result.success, rig.fb.EndCommandBuffer(commands[1].?));

    var fence: ?*facet.Fence = null;
    try testing.expectEqual(facet.Result.success, rig.fb.CreateFence(device, &.{}, &fence));
    defer rig.fb.DestroyFence(device, fence);
    try testing.expectEqual(facet.Result.not_ready, rig.fb.GetFenceStatus(device, fence.?));
    try testing.expectEqual(facet.Result.timeout, rig.fb.WaitForFences(device, 1, @ptrCast(&fence), true, 0));
    const submit = facet.SubmitInfo{ .command_buffer_count = 2, .command_buffers = @ptrCast(&commands) };
    try testing.expectEqual(facet.Result.success, rig.fb.QueueSubmit(queue.?, 1, @ptrCast(&submit), fence));
    try testing.expectEqual(facet.Result.success, rig.fb.WaitForFences(device, 1, @ptrCast(&fence), true, facet.WAIT_FOREVER_NS));
    try testing.expectEqual(facet.Result.success, rig.fb.GetFenceStatus(device, fence.?));
    try testing.expectEqual(facet.Result.success, rig.fb.QueueWaitIdle(queue.?));
    try testing.expectEqual(facet.Result.success, rig.fb.DeviceWaitIdle(device));

    const made = _objects.of(_image.Image, image.?);
    const kept: [*]const u64 = @ptrCast(@alignCast(made.data.?));
    for (0..16) |y| for (0..16) |x| {
        try testing.expectEqual(0xFF00_0000 | @as(u32, @intCast(y * 16 + x)), texture.gather(kept[made.texels.index(0, @intCast(x), @intCast(y))]));
    };
    for (0..64) |k| try testing.expectEqual(@as(u8, @intCast(k ^ 0x55)), copied[k]);
    const first = _objects.of(_command.CommandBuffer, commands[0].?);
    const second = _objects.of(_command.CommandBuffer, commands[1].?);
    try testing.expectEqual(_command.State.spent, first.state);
    try testing.expectEqual(_command.State.executable, second.state);
    try testing.expectEqual(@as(u32, 0), first.pending + second.pending);

    // Submitted again: the spent one passed over, the other played again.
    @memset(copied[0..64], 0);
    @memset(made.data.?[0..@intCast(needs.size)], 0);
    try testing.expectEqual(facet.Result.success, rig.fb.ResetFences(device, 1, @ptrCast(&fence)));
    try testing.expectEqual(facet.Result.not_ready, rig.fb.GetFenceStatus(device, fence.?));
    try testing.expectEqual(facet.Result.success, rig.fb.QueueSubmit(queue.?, 1, @ptrCast(&submit), fence));
    try testing.expectEqual(facet.Result.success, rig.fb.WaitForFences(device, 1, @ptrCast(&fence), false, 1000));
    try testing.expectEqual(@as(u8, 0x55), copied[0]);
    try testing.expectEqual(@as(u64, 0), kept[0]);

    rig.fb.FreeCommandBuffers(device, pool.?, 2, &commands);
}

test "semaphores order one submission after another; a fence alone follows all before it" {
    var rig = try Rig.up();
    defer rig.down() catch |err| std.debug.panic("{}", .{err});
    const instance, const physical = try rig.instance();
    defer rig.fb.DestroyInstance(instance);
    const device = try rig.device(physical);
    defer rig.fb.DestroyDevice(device);
    var queue: ?*facet.Queue = null;
    rig.fb.GetDeviceQueue(device, 0, 0, &queue);

    var semaphore: ?*facet.Semaphore = null;
    try testing.expectEqual(facet.Result.success, rig.fb.CreateSemaphore(device, &.{}, &semaphore));
    defer rig.fb.DestroySemaphore(device, semaphore);
    var fences: [2]?*facet.Fence = undefined;
    for (&fences) |*fence| try testing.expectEqual(facet.Result.success, rig.fb.CreateFence(device, &.{}, fence));
    defer for (fences) |fence| rig.fb.DestroyFence(device, fence);

    const signal = facet.SubmitInfo{ .signal_semaphore_count = 1, .signal_semaphores = @ptrCast(&semaphore) };
    const stage: u32 = facet.PIPELINE_STAGE_TOP_OF_PIPE;
    const wait = facet.SubmitInfo{ .wait_semaphore_count = 1, .wait_semaphores = @ptrCast(&semaphore), .wait_dst_stage_mask = @ptrCast(&stage) };
    const both = [2]facet.SubmitInfo{ signal, wait };
    try testing.expectEqual(facet.Result.success, rig.fb.QueueSubmit(queue.?, 2, &both, fences[0]));
    try testing.expectEqual(facet.Result.success, rig.fb.GetFenceStatus(device, fences[0].?));
    // The wait took the signal.
    const made = _objects.of(@import("../sync/_sync.zig").Semaphore, semaphore.?);
    try testing.expectEqual(@as(u32, 0), made.waitable.signalled);

    try testing.expectEqual(facet.Result.success, rig.fb.QueueSubmit(queue.?, 0, null, fences[1]));
    try testing.expectEqual(facet.Result.success, rig.fb.WaitForFences(device, 2, @ptrCast(&fences), true, 0));
    try testing.expectEqual(facet.Result.success, rig.fb.QueueSubmit(queue.?, 0, null, null));

    var signalled: ?*facet.Fence = null;
    try testing.expectEqual(facet.Result.success, rig.fb.CreateFence(device, &.{ .flags = facet.FENCE_CREATE_SIGNALED }, &signalled));
    try testing.expectEqual(facet.Result.success, rig.fb.GetFenceStatus(device, signalled.?));
    rig.fb.DestroyFence(device, signalled);
    try testing.expectEqual(@as(u64, 700), @import("../sync/_sync.zig").timeLeft(1000, 50, 350));
    try testing.expectEqual(@as(u64, 0), @import("../sync/_sync.zig").timeLeft(1000, 50, 2000));
    try testing.expectEqual(@as(u64, 1000), @import("../sync/_sync.zig").timeLeft(1000, 50, 50));
    try testing.expectEqual(@as(u64, 1), @import("../sync/_sync.zig").microseconds(1));
    try testing.expectEqual(@as(u64, 2), @import("../sync/_sync.zig").microseconds(1001));
    try testing.expectEqual(exec.WAIT_FOREVER, @import("../sync/_sync.zig").microseconds(facet.WAIT_FOREVER_NS));
}

/// A vertex, a fragment and a compute function, each as plain as the
/// pipelines that specialization constants are refused on need.
const Specialized = struct {
    fn vertex(vertices: *const facet.shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| vertices.output(@intCast(k))[0..4].* = .{ 0, 0, 0, 1 };
    }

    fn fragment(fragments: *const facet.shader.Fragments) callconv(.c) void {
        facet.shader.fill(fragments, 0xFF00_0000);
    }

    fn group(groups: *const facet.shader.Groups) callconv(.c) void {
        _ = groups;
    }

    const entries = [_]facet.shader.Entry{
        facet.shader.vertex("main", &vertex, 0),
        facet.shader.fragment("main", &fragment, 0),
        facet.shader.compute("main", &group),
    };
    const code = facet.shader.Code{ .entry_count = entries.len, .entries = &entries };
};

test "a stage that names specialization constants is refused, not made with them dropped, and an empty SpecializationInfo is made" {
    var rig = try Rig.up();
    defer rig.down() catch |err| std.debug.panic("{}", .{err});
    const instance, const physical = try rig.instance();
    defer rig.fb.DestroyInstance(instance);
    const device = try rig.device(physical);
    defer rig.fb.DestroyDevice(device);

    var module: ?*facet.ShaderModule = null;
    try testing.expectEqual(facet.Result.success, rig.fb.CreateShaderModule(device, &.{ .code = &Specialized.code }, &module));
    defer rig.fb.DestroyShaderModule(device, module);
    var layout: ?*facet.PipelineLayout = null;
    try testing.expectEqual(facet.Result.success, rig.fb.CreatePipelineLayout(device, &.{}, &layout));
    defer rig.fb.DestroyPipelineLayout(device, layout);

    // Nothing reads them, so a pipeline made with them would run what the
    // program did not ask for.
    const value: u32 = 7;
    const entry = facet.SpecializationMapEntry{ .constant_id = 0, .offset = 0, .size = @sizeOf(u32) };
    const constants = facet.SpecializationInfo{
        .map_entry_count = 1,
        .map_entries = @ptrCast(&entry),
        .data_size = @sizeOf(u32),
        .data = &value,
    };
    // One naming no constant specializes nothing, as in Vulkan: a program
    // that fills the struct for every stage and leaves it empty where it
    // has none is not turned away by it.
    const none = facet.SpecializationInfo{};

    // A compute pipeline.
    {
        var pipeline: [1]?*facet.Pipeline = .{null};
        const asked = facet.ComputePipelineCreateInfo{
            .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module.?, .specialization_info = &constants },
            .layout = layout.?,
        };
        try testing.expectEqual(facet.Result.error_feature_not_present, rig.fb.CreateComputePipelines(device, null, 1, @ptrCast(&asked), &pipeline));
        try testing.expect(pipeline[0] == null);

        // The same one without them is made, so the refusal is the
        // constants' and not the stage's or the module's.
        const plain = facet.ComputePipelineCreateInfo{
            .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module.? },
            .layout = layout.?,
        };
        try testing.expectEqual(facet.Result.success, rig.fb.CreateComputePipelines(device, null, 1, @ptrCast(&plain), &pipeline));
        rig.fb.DestroyPipeline(device, pipeline[0]);

        // And one that points at a `SpecializationInfo` naming no
        // constant is made as well: the pointer alone is not the refusal.
        const empty = facet.ComputePipelineCreateInfo{
            .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module.?, .specialization_info = &none },
            .layout = layout.?,
        };
        try testing.expectEqual(facet.Result.success, rig.fb.CreateComputePipelines(device, null, 1, @ptrCast(&empty), &pipeline));
        try testing.expect(pipeline[0] != null);
        rig.fb.DestroyPipeline(device, pipeline[0]);
    }

    // A graphics pipeline, the fragment stage alone carrying them.
    {
        const color = facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
        const attachment = facet.AttachmentDescription{ .format = .b8g8r8a8_unorm, .load_op = .clear, .final_layout = .color_attachment_optimal };
        const subpass = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&color) };
        var pass: ?*facet.RenderPass = null;
        const pass_info = facet.RenderPassCreateInfo{ .attachment_count = 1, .attachments = @ptrCast(&attachment), .subpass_count = 1, .subpasses = @ptrCast(&subpass) };
        try testing.expectEqual(facet.Result.success, rig.fb.CreateRenderPass(device, &pass_info, &pass));
        defer rig.fb.DestroyRenderPass(device, pass);

        const raster = facet.PipelineRasterizationStateCreateInfo{};
        const viewport = facet.Viewport{ .width = 8, .height = 8 };
        const scissor = facet.Rect2D{ .extent = .{ .width = 8, .height = 8 } };
        const viewport_state = facet.PipelineViewportStateCreateInfo{ .viewports = @ptrCast(&viewport), .scissors = @ptrCast(&scissor) };
        var stages = [2]facet.PipelineShaderStageCreateInfo{
            .{ .stage = facet.SHADER_STAGE_VERTEX, .module = module.? },
            .{ .stage = facet.SHADER_STAGE_FRAGMENT, .module = module.?, .specialization_info = &constants },
        };
        const info = facet.GraphicsPipelineCreateInfo{
            .stage_count = stages.len,
            .stages = &stages,
            .viewport_state = &viewport_state,
            .rasterization_state = &raster,
            .layout = layout.?,
            .render_pass = pass.?,
        };
        var pipeline: ?*facet.Pipeline = null;
        try testing.expectEqual(facet.Result.error_feature_not_present, rig.fb.CreateGraphicsPipelines(device, null, 1, @ptrCast(&info), @ptrCast(&pipeline)));
        try testing.expect(pipeline == null);

        stages[1].specialization_info = null;
        try testing.expectEqual(facet.Result.success, rig.fb.CreateGraphicsPipelines(device, null, 1, @ptrCast(&info), @ptrCast(&pipeline)));
        rig.fb.DestroyPipeline(device, pipeline);

        // The empty one here too.
        stages[1].specialization_info = &none;
        try testing.expectEqual(facet.Result.success, rig.fb.CreateGraphicsPipelines(device, null, 1, @ptrCast(&info), @ptrCast(&pipeline)));
        try testing.expect(pipeline != null);
        rig.fb.DestroyPipeline(device, pipeline);
    }
}
