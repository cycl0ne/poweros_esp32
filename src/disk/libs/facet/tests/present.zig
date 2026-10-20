// SPDX-License-Identifier: MIT
//! Host tests of facet.library's swapchains, over a surface of the
//! test's own: what it says it can be given, images handed out in turn
//! and shown in the order presented, drawn into where they are the
//! surface's buffers, and what is refused - a surface that changed, a
//! swapchain handed on, no room, a second swapchain.
//!
//! The tests' exec runs no task but theirs, so a present is shown as
//! QueuePresent is called (`inline_queues`).

const std = @import("std");
const sdk = @import("sdk");
const facet = sdk.facet;
const rig_zig = @import("facet.zig");
const Rig = rig_zig.Rig;
const _objects = @import("../_objects.zig");
const _surface = @import("../surface/_surface.zig");
const Instance = @import("../instance/_instance.zig").Instance;
const testing = std.testing;

const width = 64;
const height = 32;
const pitch = width * 4;

/// The test's surface: buffers in memory of the host's, the order they
/// were shown in, and how many it has room for.
const Fake = struct {
    width: u32 = width,
    height: u32 = height,
    format: facet.Format = .b8g8r8a8_unorm,
    room: u32 = 3,
    pixels: [4][pitch * height]u8 align(64) = undefined,
    /// Buffers made and not given back.
    made: u32 = 0,
    /// What `unmake` was told was shown, the last time.
    unmade_shown: ?u32 = null,
    shown: [16]u32 = undefined,
    shows: u32 = 0,
    closed: bool = false,

    const ops = _surface.Ops{ .shape = &shape, .most = &most, .make = &make, .unmake = &unmake, .show = &show, .close = &close };

    fn of(surface: *_surface.Surface) *Fake {
        return @ptrCast(@alignCast(surface.context.?));
    }

    fn shape(surface: *_surface.Surface) _surface.Shape {
        const fake = of(surface);
        return .{ .width = fake.width, .height = fake.height, .format = fake.format };
    }

    fn most(surface: *_surface.Surface) u32 {
        return of(surface).room;
    }

    fn make(surface: *_surface.Surface, pictures: []_surface.Picture) bool {
        const fake = of(surface);
        if (pictures.len > fake.room - fake.made) return false;
        for (pictures, 0..) |*picture, k| {
            picture.* = .{ .pixels = &fake.pixels[fake.made], .pitch = pitch, .handle = @ptrFromInt(fake.made + 1), .shown = k == 0 };
            fake.made += 1;
        }
        return true;
    }

    fn unmake(surface: *_surface.Surface, pictures: []_surface.Picture, shown: ?u32) void {
        const fake = of(surface);
        fake.made -= @intCast(pictures.len);
        fake.unmade_shown = shown;
    }

    fn show(surface: *_surface.Surface, picture: *_surface.Picture) void {
        const fake = of(surface);
        fake.shown[fake.shows] = @intCast(@intFromPtr(picture.handle.?) - 1);
        fake.shows += 1;
    }

    fn close(surface: *_surface.Surface) void {
        of(surface).closed = true;
    }

    fn pixel(fake: *const Fake, buffer: u32, x: u32, y: u32) u32 {
        return std.mem.readInt(u32, fake.pixels[buffer][y * pitch + x * 4 ..][0..4], .little);
    }
};

/// A device, its queue, and a surface over the test's `Fake`.
const Bench = struct {
    rig: Rig,
    instance: *facet.Instance,
    physical: *facet.PhysicalDevice,
    device: *facet.Device,
    queue: *facet.Queue,
    surface: *facet.Surface,

    fn up(fake: *Fake) !Bench {
        var rig = try Rig.up();
        const instance, const physical = try rig.instance();
        const device = try rig.device(physical);
        var queue: ?*facet.Queue = null;
        rig.fb.GetDeviceQueue(device, 0, 0, &queue);
        // Made as CreateScreenSurface makes one, over the fake's ops.
        const owner = _objects.of(Instance, instance);
        const surface = _objects.create(rig.sys, _surface.Surface) orelse return error.NoMemory;
        surface.* = .{ .instance = owner, .ops = &Fake.ops, .context = fake };
        owner.surfaces += 1;
        return .{ .rig = rig, .instance = instance, .physical = physical, .device = device, .queue = queue.?, .surface = _objects.handle(facet.Surface, surface) };
    }

    fn down(bench: *Bench) void {
        const fb = bench.rig.fb;
        fb.DestroySurface(bench.instance, bench.surface);
        fb.DestroyDevice(bench.device);
        fb.DestroyInstance(bench.instance);
        bench.rig.down() catch |err| std.debug.panic("{}", .{err});
    }

    fn swapchain(bench: *Bench, images: u32, old: ?*facet.Swapchain) struct { facet.Result, ?*facet.Swapchain } {
        var made: ?*facet.Swapchain = null;
        const result = bench.rig.fb.CreateSwapchain(bench.device, &.{
            .surface = bench.surface,
            .min_image_count = images,
            .image_format = .b8g8r8a8_unorm,
            .image_extent = .{ .width = width, .height = height },
            .old_swapchain = old,
        }, &made);
        return .{ result, made };
    }

    fn acquire(bench: *Bench, chain: *facet.Swapchain, timeout: u64) struct { facet.Result, u32 } {
        var index: u32 = 99;
        const result = bench.rig.fb.AcquireNextImage(bench.device, chain, timeout, null, null, &index);
        return .{ result, index };
    }

    fn present(bench: *Bench, chain: *facet.Swapchain, index: u32) facet.Result {
        var result: facet.Result = .incomplete;
        const shown = bench.rig.fb.QueuePresent(bench.queue, &.{ .swapchains = @ptrCast(&chain), .image_indices = @ptrCast(&index), .results = @ptrCast(&result) });
        testing.expectEqual(shown, result) catch unreachable;
        return shown;
    }
};

test "a surface: its size, one format, fifo, and as many images as it has room for" {
    var fake = Fake{};
    var bench = try Bench.up(&fake);
    defer bench.down();
    const fb = bench.rig.fb;

    var supported = false;
    try testing.expectEqual(facet.Result.success, fb.GetPhysicalDeviceSurfaceSupport(bench.physical, 0, bench.surface, &supported));
    try testing.expect(supported);
    try testing.expectEqual(facet.Result.success, fb.GetPhysicalDeviceSurfaceSupport(bench.physical, 1, bench.surface, &supported));
    try testing.expect(!supported);

    var capabilities: facet.SurfaceCapabilities = undefined;
    try testing.expectEqual(facet.Result.success, fb.GetPhysicalDeviceSurfaceCapabilities(bench.physical, bench.surface, &capabilities));
    try testing.expectEqual(@as(u32, 1), capabilities.min_image_count);
    try testing.expectEqual(@as(u32, 3), capabilities.max_image_count);
    try testing.expectEqual(facet.Extent2D{ .width = width, .height = height }, capabilities.current_extent);
    try testing.expectEqual(capabilities.current_extent, capabilities.max_image_extent);
    try testing.expectEqual(facet.IMAGE_USAGE_COLOR_ATTACHMENT, capabilities.supported_usage_flags);

    var count: u32 = 0;
    try testing.expectEqual(facet.Result.success, fb.GetPhysicalDeviceSurfaceFormats(bench.physical, bench.surface, &count, null));
    try testing.expectEqual(@as(u32, 1), count);
    var format: [1]facet.SurfaceFormat = undefined;
    try testing.expectEqual(facet.Result.success, fb.GetPhysicalDeviceSurfaceFormats(bench.physical, bench.surface, &count, &format));
    try testing.expectEqual(facet.Format.b8g8r8a8_unorm, format[0].format);
    var mode: [1]facet.PresentMode = undefined;
    count = 1;
    try testing.expectEqual(facet.Result.success, fb.GetPhysicalDeviceSurfacePresentModes(bench.physical, bench.surface, &count, &mode));
    try testing.expectEqual(facet.PresentMode.fifo, mode[0]);

    // A display of 16 bits a pixel: nothing facet.library draws in.
    fake.format = .undefined;
    try testing.expectEqual(facet.Result.success, fb.GetPhysicalDeviceSurfaceFormats(bench.physical, bench.surface, &count, null));
    try testing.expectEqual(@as(u32, 0), count);
    try testing.expectEqual(facet.Result.success, fb.GetPhysicalDeviceSurfaceSupport(bench.physical, 0, bench.surface, &supported));
    try testing.expect(!supported);
    const result, _ = bench.swapchain(2, null);
    try testing.expectEqual(facet.Result.error_format_not_supported, result);
}

test "a swapchain: its images the surface's buffers, handed out in turn, shown in the order presented" {
    var fake = Fake{};
    var bench = try Bench.up(&fake);
    defer bench.down();
    const fb = bench.rig.fb;
    const made, const swapchain = bench.swapchain(2, null);
    try testing.expectEqual(facet.Result.success, made);
    try testing.expectEqual(@as(u32, 2), fake.made);

    var count: u32 = 0;
    try testing.expectEqual(facet.Result.success, fb.GetSwapchainImages(bench.device, swapchain.?, &count, null));
    try testing.expectEqual(@as(u32, 2), count);
    var images: [2]*facet.Image = undefined;
    count = 1;
    try testing.expectEqual(facet.Result.incomplete, fb.GetSwapchainImages(bench.device, swapchain.?, &count, &images));
    count = 2;
    try testing.expectEqual(facet.Result.success, fb.GetSwapchainImages(bench.device, swapchain.?, &count, &images));
    // Bound already, and the program's to neither bind nor destroy.
    var needs: facet.MemoryRequirements = undefined;
    fb.GetImageMemoryRequirements(bench.device, images[0], &needs);
    const block = try rig_zig.allocate(&bench.rig, bench.device, needs.size);
    defer fb.FreeMemory(bench.device, block);
    try testing.expectEqual(facet.Result.error_out_of_device_memory, fb.BindImageMemory(bench.device, images[0], block, 0));
    fb.DestroyImage(bench.device, images[0]);

    // The first is shown as the swapchain starts: the second is handed out,
    // and then none until something presented is shown.
    var acquired, var index = bench.acquire(swapchain.?, facet.WAIT_FOREVER_NS);
    try testing.expectEqual(facet.Result.success, acquired);
    try testing.expectEqual(@as(u32, 1), index);
    acquired, _ = bench.acquire(swapchain.?, 0);
    try testing.expectEqual(facet.Result.not_ready, acquired);
    acquired, _ = bench.acquire(swapchain.?, 1000);
    try testing.expectEqual(facet.Result.timeout, acquired);

    // Drawn into through a render pass: the buffer's pixels.
    try drawRed(&bench, images[index]);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), fake.pixel(1, 0, 0));
    try testing.expectEqual(@as(u32, 0xFFFF_0000), fake.pixel(1, width - 1, height - 1));

    try testing.expectEqual(facet.Result.success, bench.present(swapchain.?, index));
    // Presented twice: the program holds it no more.
    try testing.expectEqual(facet.Result.error_out_of_date, bench.present(swapchain.?, index));
    acquired, index = bench.acquire(swapchain.?, facet.WAIT_FOREVER_NS);
    try testing.expectEqual(facet.Result.success, acquired);
    try testing.expectEqual(@as(u32, 0), index);
    try testing.expectEqual(facet.Result.success, bench.present(swapchain.?, index));
    acquired, index = bench.acquire(swapchain.?, facet.WAIT_FOREVER_NS);
    try testing.expectEqual(@as(u32, 1), index);
    try testing.expectEqual(facet.Result.success, bench.present(swapchain.?, index));
    try testing.expectEqualSlices(u32, &.{ 1, 0, 1 }, fake.shown[0..fake.shows]);

    fb.DestroySwapchain(bench.device, swapchain);
    try testing.expectEqual(@as(u32, 0), fake.made);
    try testing.expectEqual(@as(?u32, 1), fake.unmade_shown);
}

test "one image: handed out while it is shown, and shown at each present" {
    var fake = Fake{};
    var bench = try Bench.up(&fake);
    defer bench.down();
    const made, const swapchain = bench.swapchain(1, null);
    try testing.expectEqual(facet.Result.success, made);
    defer bench.rig.fb.DestroySwapchain(bench.device, swapchain);
    for (0..3) |_| {
        const acquired, const index = bench.acquire(swapchain.?, facet.WAIT_FOREVER_NS);
        try testing.expectEqual(facet.Result.success, acquired);
        try testing.expectEqual(@as(u32, 0), index);
        try testing.expectEqual(facet.Result.success, bench.present(swapchain.?, index));
    }
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0 }, fake.shown[0..fake.shows]);
}

test "a frame's semaphores: acquired, drawn, presented; the acquire's fence signalled" {
    var fake = Fake{};
    var bench = try Bench.up(&fake);
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const made, const swapchain = bench.swapchain(2, null);
    try testing.expectEqual(facet.Result.success, made);
    defer fb.DestroySwapchain(device, swapchain);
    var acquired: ?*facet.Semaphore = null;
    var rendered: ?*facet.Semaphore = null;
    var fence: ?*facet.Fence = null;
    try testing.expectEqual(facet.Result.success, fb.CreateSemaphore(device, &.{}, &acquired));
    defer fb.DestroySemaphore(device, acquired);
    try testing.expectEqual(facet.Result.success, fb.CreateSemaphore(device, &.{}, &rendered));
    defer fb.DestroySemaphore(device, rendered);
    try testing.expectEqual(facet.Result.success, fb.CreateFence(device, &.{}, &fence));
    defer fb.DestroyFence(device, fence);

    var index: u32 = 0;
    try testing.expectEqual(facet.Result.success, fb.AcquireNextImage(device, swapchain.?, facet.WAIT_FOREVER_NS, acquired, fence, &index));
    try testing.expectEqual(facet.Result.success, fb.GetFenceStatus(device, fence.?));
    // Nothing recorded: a submission that waits and signals alone.
    const stage: u32 = facet.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT;
    const submit = facet.SubmitInfo{
        .wait_semaphore_count = 1,
        .wait_semaphores = @ptrCast(&acquired),
        .wait_dst_stage_mask = @ptrCast(&stage),
        .signal_semaphore_count = 1,
        .signal_semaphores = @ptrCast(&rendered),
    };
    try testing.expectEqual(facet.Result.success, fb.QueueSubmit(bench.queue, 1, @ptrCast(&submit), null));
    try testing.expectEqual(facet.Result.success, fb.QueuePresent(bench.queue, &.{
        .wait_semaphore_count = 1,
        .wait_semaphores = @ptrCast(&rendered),
        .swapchains = @ptrCast(&swapchain),
        .image_indices = @ptrCast(&index),
    }));
    try testing.expectEqualSlices(u32, &.{1}, fake.shown[0..fake.shows]);
}

test "refused: a surface that changed, a swapchain handed on, no room, a second swapchain" {
    var fake = Fake{};
    var bench = try Bench.up(&fake);
    defer bench.down();
    const fb = bench.rig.fb;

    // More than there is room for.
    var result, _ = bench.swapchain(4, null);
    try testing.expectEqual(facet.Result.error_out_of_device_memory, result);
    try testing.expectEqual(@as(u32, 0), fake.made);

    result, const first = bench.swapchain(2, null);
    try testing.expectEqual(facet.Result.success, result);
    result, _ = bench.swapchain(1, null);
    try testing.expectEqual(facet.Result.error_native_window_in_use, result);

    // Handed on: the old one hands out no more, the new one goes on.
    var acquired, const held = bench.acquire(first.?, 0);
    try testing.expectEqual(facet.Result.success, acquired);
    result, const second = bench.swapchain(1, first);
    try testing.expectEqual(facet.Result.success, result);
    acquired, _ = bench.acquire(first.?, 0);
    try testing.expectEqual(facet.Result.error_out_of_date, acquired);
    // What it handed out before is still shown.
    try testing.expectEqual(facet.Result.success, bench.present(first.?, held));
    fb.DestroySwapchain(bench.device, first);
    try testing.expectEqual(@as(?u32, null), fake.unmade_shown);

    // The surface's size changed: out of date, and nothing shown.
    const shows = fake.shows;
    acquired, const index = bench.acquire(second.?, 0);
    try testing.expectEqual(facet.Result.success, acquired);
    fake.width = 80;
    try testing.expectEqual(facet.Result.error_out_of_date, bench.present(second.?, index));
    try testing.expectEqual(shows, fake.shows);
    acquired, _ = bench.acquire(second.?, 0);
    try testing.expectEqual(facet.Result.error_out_of_date, acquired);
    result, _ = bench.swapchain(1, second);
    try testing.expectEqual(facet.Result.error_initialization_failed, result);
    fb.DestroySwapchain(bench.device, second);
    try testing.expectEqual(@as(u32, 0), fake.made);
}

test "a surface is kept while a swapchain on it is left" {
    var fake = Fake{};
    var bench = try Bench.up(&fake);
    defer bench.down();
    const result, const swapchain = bench.swapchain(1, null);
    try testing.expectEqual(facet.Result.success, result);
    bench.rig.fb.DestroySurface(bench.instance, bench.surface);
    try testing.expect(!fake.closed);
    bench.rig.fb.DestroySwapchain(bench.device, swapchain);
}

/// `image` cleared to red by a render pass over the whole of it.
fn drawRed(bench: *Bench, image: *facet.Image) !void {
    const fb = bench.rig.fb;
    const device = bench.device;
    var view: ?*facet.ImageView = null;
    try testing.expectEqual(facet.Result.success, fb.CreateImageView(device, &.{ .image = image, .format = .b8g8r8a8_unorm, .subresource_range = .{ .aspect_mask = facet.IMAGE_ASPECT_COLOR } }, &view));
    defer fb.DestroyImageView(device, view);
    const attachment = facet.AttachmentDescription{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .present_src };
    const color = facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
    const subpass = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&color) };
    var pass: ?*facet.RenderPass = null;
    try testing.expectEqual(facet.Result.success, fb.CreateRenderPass(device, &.{ .attachment_count = 1, .attachments = @ptrCast(&attachment), .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &pass));
    defer fb.DestroyRenderPass(device, pass);
    var frame: ?*facet.Framebuffer = null;
    try testing.expectEqual(facet.Result.success, fb.CreateFramebuffer(device, &.{ .render_pass = pass.?, .attachment_count = 1, .attachments = @ptrCast(&view), .width = width, .height = height }, &frame));
    defer fb.DestroyFramebuffer(device, frame);
    var pool: ?*facet.CommandPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateCommandPool(device, &.{}, &pool));
    defer fb.DestroyCommandPool(device, pool);
    var commands: [1]?*facet.CommandBuffer = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateCommandBuffers(device, &.{ .command_pool = pool.?, .command_buffer_count = 1 }, &commands));
    try testing.expectEqual(facet.Result.success, fb.BeginCommandBuffer(commands[0].?, &.{}));
    const red = facet.ClearValue{ .color = .{ .float32 = .{ 1, 0, 0, 1 } } };
    fb.CmdBeginRenderPass(commands[0].?, &.{ .render_pass = pass.?, .framebuffer = frame.?, .render_area = .{ .extent = .{ .width = width, .height = height } }, .clear_value_count = 1, .clear_values = @ptrCast(&red) }, .@"inline");
    fb.CmdEndRenderPass(commands[0].?);
    try testing.expectEqual(facet.Result.success, fb.EndCommandBuffer(commands[0].?));
    const submit = facet.SubmitInfo{ .command_buffer_count = 1, .command_buffers = @ptrCast(&commands) };
    try testing.expectEqual(facet.Result.success, fb.QueueSubmit(bench.queue, 1, @ptrCast(&submit), null));
    try testing.expectEqual(facet.Result.success, fb.QueueWaitIdle(bench.queue));
}
