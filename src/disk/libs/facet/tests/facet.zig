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
    try testing.expectEqual(facet.makeVersion(facet_init.LIBRARY_VERSION, facet_init.LIBRARY_REVISION), properties.driver_version);
    try testing.expect(properties.limits.cores >= 1 and properties.limits.cores <= 4);
    try testing.expectEqual(@as(u32, 64), properties.limits.tile_size);
    try testing.expect(std.mem.startsWith(u8, &properties.device_name, "facet.library rasterizer, "));

    count = 0;
    rig.fb.GetPhysicalDeviceQueueFamilyProperties(physical, &count, null);
    try testing.expectEqual(@as(u32, 1), count);
    var family: [1]facet.QueueFamilyProperties = undefined;
    rig.fb.GetPhysicalDeviceQueueFamilyProperties(physical, &count, &family);
    try testing.expectEqual(facet.QUEUE_GRAPHICS | facet.QUEUE_TRANSFER, family[0].queue_flags);
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

test "an interface newer than the library's is refused; the library stays while an instance lasts" {
    var rig = try Rig.up();
    defer rig.down() catch |err| std.debug.panic("{}", .{err});
    var instance: ?*facet.Instance = null;
    const newer = facet.makeVersion(facet_init.LIBRARY_VERSION, facet_init.LIBRARY_REVISION + 1);
    try testing.expectEqual(facet.Result.error_initialization_failed, rig.fb.CreateInstance(&.{ .api_version = newer }, &instance));
    try testing.expect(instance == null);
    try testing.expectEqual(facet.Result.success, rig.fb.CreateInstance(&.{ .api_version = 0 }, &instance));

    const lib = rig.fb.lib();
    try testing.expectEqual(@as(u16, 0), lib.open_cnt);
    try testing.expect(rig.sys.RemLibrary(lib) == null);
    try testing.expect(lib.flags & exec.LIBF_DELEXP != 0);
    rig.fb.DestroyInstance(instance);
    rig.fb.DestroyInstance(null);
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
    rig.fb.GetPhysicalDeviceFormatProperties(physical, .d16_unorm, &properties);
    try testing.expectEqual(facet.FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT, properties.optimal_tiling_features);
    rig.fb.GetPhysicalDeviceFormatProperties(physical, .r32g32b32_sfloat, &properties);
    try testing.expectEqual(facet.FORMAT_FEATURE_VERTEX_BUFFER, properties.buffer_features);
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
        .{ .format = .b8g8r8a8_unorm, .extent = .{ .width = 100, .height = 64 }, .usage = sampled },
        .{ .format = .b8g8r8a8_unorm, .extent = .{ .width = 64, .height = 64 }, .tiling = .linear, .usage = sampled },
        .{ .format = .b8g8r8a8_unorm, .extent = .{ .width = 64, .height = 64 }, .mip_levels = 8, .usage = sampled },
        .{ .format = .r32_sfloat, .extent = .{ .width = 64, .height = 64 }, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT },
        .{ .format = .d16_unorm, .extent = .{ .width = 64, .height = 64 }, .usage = facet.IMAGE_USAGE_SAMPLED },
        .{ .format = .b8g8r8a8_unorm, .extent = .{ .width = 64, .height = 64, .depth = 2 }, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT },
        .{ .format = .b8g8r8a8_unorm, .extent = .{ .width = 64, .height = 64 }, .samples = 4, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT },
        .{ .format = .r32g32_sfloat, .extent = .{ .width = 64, .height = 64 }, .usage = facet.IMAGE_USAGE_TRANSFER_DST },
        .{ .format = .b8g8r8a8_unorm, .extent = .{ .width = 16384, .height = 64 }, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT },
    };
    for (refused) |info| {
        try testing.expectEqual(facet.Result.error_format_not_supported, rig.fb.CreateImage(device, &info, &image));
        try testing.expect(image == null);
    }
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

// --- command buffers, the queue, fences and semaphores -------------------------

const _stream = @import("../command/_stream.zig");
const _command = @import("../command/_command.zig");

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
    try testing.expectEqual(facet.Result.error_feature_not_present, rig.fb.AllocateCommandBuffers(device, &.{ .command_pool = pool.?, .level = .secondary, .command_buffer_count = 2 }, &commands));
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
    try testing.expectEqual(@as(u64, 1), @import("../sync/_sync.zig").microseconds(1));
    try testing.expectEqual(@as(u64, 2), @import("../sync/_sync.zig").microseconds(1001));
    try testing.expectEqual(exec.WAIT_FOREVER, @import("../sync/_sync.zig").microseconds(facet.WAIT_FOREVER_NS));
}
