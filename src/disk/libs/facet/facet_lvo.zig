// SPDX-License-Identifier: MIT
//! facet.library's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const facet = sdk.facet;
const vec = exec.vec;
const FacetBase = @import("facet_base.zig").FacetBase;
const facet_init = @import("facet_init.zig");

const CreateInstance = @import("instance/createinstance.zig").CreateInstance;
const DestroyInstance = @import("instance/destroyinstance.zig").DestroyInstance;
const EnumeratePhysicalDevices = @import("instance/enumeratephysicaldevices.zig").EnumeratePhysicalDevices;
const GetPhysicalDeviceProperties = @import("instance/getphysicaldeviceproperties.zig").GetPhysicalDeviceProperties;
const GetPhysicalDeviceQueueFamilyProperties = @import("instance/getphysicaldevicequeuefamilyproperties.zig").GetPhysicalDeviceQueueFamilyProperties;
const GetPhysicalDeviceMemoryProperties = @import("instance/getphysicaldevicememoryproperties.zig").GetPhysicalDeviceMemoryProperties;
const CreateDevice = @import("device/createdevice.zig").CreateDevice;
const DestroyDevice = @import("device/destroydevice.zig").DestroyDevice;
const GetDeviceQueue = @import("device/getdevicequeue.zig").GetDeviceQueue;
const AllocateMemory = @import("memory/allocatememory.zig").AllocateMemory;
const FreeMemory = @import("memory/freememory.zig").FreeMemory;
const MapMemory = @import("memory/mapmemory.zig").MapMemory;
const UnmapMemory = @import("memory/unmapmemory.zig").UnmapMemory;
const GetPhysicalDeviceFormatProperties = @import("instance/getphysicaldeviceformatproperties.zig").GetPhysicalDeviceFormatProperties;
const CreateBuffer = @import("buffer/createbuffer.zig").CreateBuffer;
const DestroyBuffer = @import("buffer/destroybuffer.zig").DestroyBuffer;
const GetBufferMemoryRequirements = @import("buffer/getbuffermemoryrequirements.zig").GetBufferMemoryRequirements;
const BindBufferMemory = @import("buffer/bindbuffermemory.zig").BindBufferMemory;
const CreateImage = @import("image/createimage.zig").CreateImage;
const DestroyImage = @import("image/destroyimage.zig").DestroyImage;
const GetImageMemoryRequirements = @import("image/getimagememoryrequirements.zig").GetImageMemoryRequirements;
const BindImageMemory = @import("image/bindimagememory.zig").BindImageMemory;
const GetImageSubresourceLayout = @import("image/getimagesubresourcelayout.zig").GetImageSubresourceLayout;
const CreateImageView = @import("image/createimageview.zig").CreateImageView;
const DestroyImageView = @import("image/destroyimageview.zig").DestroyImageView;
const CreateCommandPool = @import("command/createcommandpool.zig").CreateCommandPool;
const DestroyCommandPool = @import("command/destroycommandpool.zig").DestroyCommandPool;
const ResetCommandPool = @import("command/resetcommandpool.zig").ResetCommandPool;
const AllocateCommandBuffers = @import("command/allocatecommandbuffers.zig").AllocateCommandBuffers;
const FreeCommandBuffers = @import("command/freecommandbuffers.zig").FreeCommandBuffers;
const BeginCommandBuffer = @import("command/begincommandbuffer.zig").BeginCommandBuffer;
const EndCommandBuffer = @import("command/endcommandbuffer.zig").EndCommandBuffer;
const ResetCommandBuffer = @import("command/resetcommandbuffer.zig").ResetCommandBuffer;
const CmdPipelineBarrier = @import("command/cmdpipelinebarrier.zig").CmdPipelineBarrier;
const CmdCopyBufferToImage = @import("command/cmdcopybuffertoimage.zig").CmdCopyBufferToImage;
const CmdCopyBuffer = @import("command/cmdcopybuffer.zig").CmdCopyBuffer;
const QueueSubmit = @import("queue/queuesubmit.zig").QueueSubmit;
const QueueWaitIdle = @import("queue/queuewaitidle.zig").QueueWaitIdle;
const DeviceWaitIdle = @import("queue/devicewaitidle.zig").DeviceWaitIdle;
const CreateFence = @import("sync/createfence.zig").CreateFence;
const DestroyFence = @import("sync/destroyfence.zig").DestroyFence;
const ResetFences = @import("sync/resetfences.zig").ResetFences;
const GetFenceStatus = @import("sync/getfencestatus.zig").GetFenceStatus;
const WaitForFences = @import("sync/waitforfences.zig").WaitForFences;
const CreateSemaphore = @import("sync/createsemaphore.zig").CreateSemaphore;
const DestroySemaphore = @import("sync/destroysemaphore.zig").DestroySemaphore;
const CreateRenderPass = @import("render/createrenderpass.zig").CreateRenderPass;
const DestroyRenderPass = @import("render/destroyrenderpass.zig").DestroyRenderPass;
const CreateFramebuffer = @import("render/createframebuffer.zig").CreateFramebuffer;
const DestroyFramebuffer = @import("render/destroyframebuffer.zig").DestroyFramebuffer;
const CreateShaderModule = @import("shader/createshadermodule.zig").CreateShaderModule;
const DestroyShaderModule = @import("shader/destroyshadermodule.zig").DestroyShaderModule;
const CreateDescriptorSetLayout = @import("descriptor/createdescriptorsetlayout.zig").CreateDescriptorSetLayout;
const DestroyDescriptorSetLayout = @import("descriptor/destroydescriptorsetlayout.zig").DestroyDescriptorSetLayout;
const CreatePipelineLayout = @import("pipeline/createpipelinelayout.zig").CreatePipelineLayout;
const DestroyPipelineLayout = @import("pipeline/destroypipelinelayout.zig").DestroyPipelineLayout;
const CreateDescriptorPool = @import("descriptor/createdescriptorpool.zig").CreateDescriptorPool;
const DestroyDescriptorPool = @import("descriptor/destroydescriptorpool.zig").DestroyDescriptorPool;
const ResetDescriptorPool = @import("descriptor/resetdescriptorpool.zig").ResetDescriptorPool;
const AllocateDescriptorSets = @import("descriptor/allocatedescriptorsets.zig").AllocateDescriptorSets;
const FreeDescriptorSets = @import("descriptor/freedescriptorsets.zig").FreeDescriptorSets;
const UpdateDescriptorSets = @import("descriptor/updatedescriptorsets.zig").UpdateDescriptorSets;
const CreateGraphicsPipelines = @import("pipeline/creategraphicspipelines.zig").CreateGraphicsPipelines;
const DestroyPipeline = @import("pipeline/destroypipeline.zig").DestroyPipeline;
const CmdBeginRenderPass = @import("command/cmdbeginrenderpass.zig").CmdBeginRenderPass;
const CmdEndRenderPass = @import("command/cmdendrenderpass.zig").CmdEndRenderPass;
const CmdBindPipeline = @import("command/cmdbindpipeline.zig").CmdBindPipeline;
const CmdBindVertexBuffers = @import("command/cmdbindvertexbuffers.zig").CmdBindVertexBuffers;
const CmdBindIndexBuffer = @import("command/cmdbindindexbuffer.zig").CmdBindIndexBuffer;
const CmdBindDescriptorSets = @import("command/cmdbinddescriptorsets.zig").CmdBindDescriptorSets;
const CmdPushConstants = @import("command/cmdpushconstants.zig").CmdPushConstants;
const CmdSetViewport = @import("command/cmdsetviewport.zig").CmdSetViewport;
const CmdSetScissor = @import("command/cmdsetscissor.zig").CmdSetScissor;
const CmdDraw = @import("command/cmddraw.zig").CmdDraw;
const CmdDrawIndexed = @import("command/cmddrawindexed.zig").CmdDrawIndexed;
const CreateScreenSurface = @import("surface/createscreensurface.zig").CreateScreenSurface;
const DestroySurface = @import("surface/destroysurface.zig").DestroySurface;
const GetPhysicalDeviceSurfaceSupport = @import("surface/getphysicaldevicesurfacesupport.zig").GetPhysicalDeviceSurfaceSupport;
const GetPhysicalDeviceSurfaceCapabilities = @import("surface/getphysicaldevicesurfacecapabilities.zig").GetPhysicalDeviceSurfaceCapabilities;
const GetPhysicalDeviceSurfaceFormats = @import("surface/getphysicaldevicesurfaceformats.zig").GetPhysicalDeviceSurfaceFormats;
const GetPhysicalDeviceSurfacePresentModes = @import("surface/getphysicaldevicesurfacepresentmodes.zig").GetPhysicalDeviceSurfacePresentModes;
const CreateSwapchain = @import("swapchain/createswapchain.zig").CreateSwapchain;
const DestroySwapchain = @import("swapchain/destroyswapchain.zig").DestroySwapchain;
const GetSwapchainImages = @import("swapchain/getswapchainimages.zig").GetSwapchainImages;
const AcquireNextImage = @import("swapchain/acquirenextimage.zig").AcquireNextImage;
const QueuePresent = @import("swapchain/queuepresent.zig").QueuePresent;
const CreateWindowSurface = @import("surface/createwindowsurface.zig").CreateWindowSurface;

/// facet.library's interface, as the SDK generates it from
/// sdk/fd/facet_lib.fd.
const interface = sdk.interface.facet;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("facet.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "facet.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("instance/createinstance.zig"),
    @embedFile("instance/destroyinstance.zig"),
    @embedFile("instance/enumeratephysicaldevices.zig"),
    @embedFile("instance/getphysicaldeviceproperties.zig"),
    @embedFile("instance/getphysicaldevicequeuefamilyproperties.zig"),
    @embedFile("instance/getphysicaldevicememoryproperties.zig"),
    @embedFile("device/createdevice.zig"),
    @embedFile("device/destroydevice.zig"),
    @embedFile("device/getdevicequeue.zig"),
    @embedFile("memory/allocatememory.zig"),
    @embedFile("memory/freememory.zig"),
    @embedFile("memory/mapmemory.zig"),
    @embedFile("memory/unmapmemory.zig"),
    @embedFile("instance/getphysicaldeviceformatproperties.zig"),
    @embedFile("buffer/createbuffer.zig"),
    @embedFile("buffer/destroybuffer.zig"),
    @embedFile("buffer/getbuffermemoryrequirements.zig"),
    @embedFile("buffer/bindbuffermemory.zig"),
    @embedFile("image/createimage.zig"),
    @embedFile("image/destroyimage.zig"),
    @embedFile("image/getimagememoryrequirements.zig"),
    @embedFile("image/bindimagememory.zig"),
    @embedFile("image/getimagesubresourcelayout.zig"),
    @embedFile("image/createimageview.zig"),
    @embedFile("image/destroyimageview.zig"),
    @embedFile("command/createcommandpool.zig"),
    @embedFile("command/destroycommandpool.zig"),
    @embedFile("command/resetcommandpool.zig"),
    @embedFile("command/allocatecommandbuffers.zig"),
    @embedFile("command/freecommandbuffers.zig"),
    @embedFile("command/begincommandbuffer.zig"),
    @embedFile("command/endcommandbuffer.zig"),
    @embedFile("command/resetcommandbuffer.zig"),
    @embedFile("command/cmdpipelinebarrier.zig"),
    @embedFile("command/cmdcopybuffertoimage.zig"),
    @embedFile("command/cmdcopybuffer.zig"),
    @embedFile("queue/queuesubmit.zig"),
    @embedFile("queue/queuewaitidle.zig"),
    @embedFile("queue/devicewaitidle.zig"),
    @embedFile("sync/createfence.zig"),
    @embedFile("sync/destroyfence.zig"),
    @embedFile("sync/resetfences.zig"),
    @embedFile("sync/getfencestatus.zig"),
    @embedFile("sync/waitforfences.zig"),
    @embedFile("sync/createsemaphore.zig"),
    @embedFile("sync/destroysemaphore.zig"),
    @embedFile("render/createrenderpass.zig"),
    @embedFile("render/destroyrenderpass.zig"),
    @embedFile("render/createframebuffer.zig"),
    @embedFile("render/destroyframebuffer.zig"),
    @embedFile("shader/createshadermodule.zig"),
    @embedFile("shader/destroyshadermodule.zig"),
    @embedFile("descriptor/createdescriptorsetlayout.zig"),
    @embedFile("descriptor/destroydescriptorsetlayout.zig"),
    @embedFile("pipeline/createpipelinelayout.zig"),
    @embedFile("pipeline/destroypipelinelayout.zig"),
    @embedFile("descriptor/createdescriptorpool.zig"),
    @embedFile("descriptor/destroydescriptorpool.zig"),
    @embedFile("descriptor/resetdescriptorpool.zig"),
    @embedFile("descriptor/allocatedescriptorsets.zig"),
    @embedFile("descriptor/freedescriptorsets.zig"),
    @embedFile("descriptor/updatedescriptorsets.zig"),
    @embedFile("pipeline/creategraphicspipelines.zig"),
    @embedFile("pipeline/destroypipeline.zig"),
    @embedFile("command/cmdbeginrenderpass.zig"),
    @embedFile("command/cmdendrenderpass.zig"),
    @embedFile("command/cmdbindpipeline.zig"),
    @embedFile("command/cmdbindvertexbuffers.zig"),
    @embedFile("command/cmdbindindexbuffer.zig"),
    @embedFile("command/cmdbinddescriptorsets.zig"),
    @embedFile("command/cmdpushconstants.zig"),
    @embedFile("command/cmdsetviewport.zig"),
    @embedFile("command/cmdsetscissor.zig"),
    @embedFile("command/cmddraw.zig"),
    @embedFile("command/cmddrawindexed.zig"),
    @embedFile("surface/createscreensurface.zig"),
    @embedFile("surface/destroysurface.zig"),
    @embedFile("surface/getphysicaldevicesurfacesupport.zig"),
    @embedFile("surface/getphysicaldevicesurfacecapabilities.zig"),
    @embedFile("surface/getphysicaldevicesurfaceformats.zig"),
    @embedFile("surface/getphysicaldevicesurfacepresentmodes.zig"),
    @embedFile("swapchain/createswapchain.zig"),
    @embedFile("swapchain/destroyswapchain.zig"),
    @embedFile("swapchain/getswapchainimages.zig"),
    @embedFile("swapchain/acquirenextimage.zig"),
    @embedFile("swapchain/queuepresent.zig"),
    @embedFile("surface/createwindowsurface.zig"),
};

fn lvoCreateInstance(base: *FacetBase, info: *const facet.InstanceCreateInfo, instance: *?*facet.Instance) callconv(.c) facet.Result {
    return CreateInstance(base, info, instance);
}
fn lvoDestroyInstance(base: *FacetBase, instance: ?*facet.Instance) callconv(.c) void {
    return DestroyInstance(base, instance);
}
fn lvoEnumeratePhysicalDevices(base: *FacetBase, instance: *facet.Instance, count: *u32, devices: ?[*]*facet.PhysicalDevice) callconv(.c) facet.Result {
    return EnumeratePhysicalDevices(base, instance, count, devices);
}
fn lvoGetPhysicalDeviceProperties(base: *FacetBase, physical: *facet.PhysicalDevice, properties: *facet.PhysicalDeviceProperties) callconv(.c) void {
    return GetPhysicalDeviceProperties(base, physical, properties);
}
fn lvoGetPhysicalDeviceQueueFamilyProperties(base: *FacetBase, physical: *facet.PhysicalDevice, count: *u32, properties: ?[*]facet.QueueFamilyProperties) callconv(.c) void {
    return GetPhysicalDeviceQueueFamilyProperties(base, physical, count, properties);
}
fn lvoGetPhysicalDeviceMemoryProperties(base: *FacetBase, physical: *facet.PhysicalDevice, properties: *facet.PhysicalDeviceMemoryProperties) callconv(.c) void {
    return GetPhysicalDeviceMemoryProperties(base, physical, properties);
}
fn lvoCreateDevice(base: *FacetBase, physical: *facet.PhysicalDevice, info: *const facet.DeviceCreateInfo, device: *?*facet.Device) callconv(.c) facet.Result {
    return CreateDevice(base, physical, info, device);
}
fn lvoDestroyDevice(base: *FacetBase, device: ?*facet.Device) callconv(.c) void {
    return DestroyDevice(base, device);
}
fn lvoGetDeviceQueue(base: *FacetBase, device: *facet.Device, family: u32, index: u32, queue: *?*facet.Queue) callconv(.c) void {
    return GetDeviceQueue(base, device, family, index, queue);
}
fn lvoAllocateMemory(base: *FacetBase, device: *facet.Device, info: *const facet.MemoryAllocateInfo, memory: *?*facet.DeviceMemory) callconv(.c) facet.Result {
    return AllocateMemory(base, device, info, memory);
}
fn lvoFreeMemory(base: *FacetBase, device: *facet.Device, memory: ?*facet.DeviceMemory) callconv(.c) void {
    return FreeMemory(base, device, memory);
}
fn lvoMapMemory(base: *FacetBase, device: *facet.Device, memory: *facet.DeviceMemory, offset: u64, size: u64, flags: u32, data: *?*anyopaque) callconv(.c) facet.Result {
    return MapMemory(base, device, memory, offset, size, flags, data);
}
fn lvoUnmapMemory(base: *FacetBase, device: *facet.Device, memory: *facet.DeviceMemory) callconv(.c) void {
    return UnmapMemory(base, device, memory);
}
fn lvoGetPhysicalDeviceFormatProperties(base: *FacetBase, physical: *facet.PhysicalDevice, format: facet.Format, properties: *facet.FormatProperties) callconv(.c) void {
    return GetPhysicalDeviceFormatProperties(base, physical, format, properties);
}
fn lvoCreateBuffer(base: *FacetBase, device: *facet.Device, info: *const facet.BufferCreateInfo, buffer: *?*facet.Buffer) callconv(.c) facet.Result {
    return CreateBuffer(base, device, info, buffer);
}
fn lvoDestroyBuffer(base: *FacetBase, device: *facet.Device, buffer: ?*facet.Buffer) callconv(.c) void {
    return DestroyBuffer(base, device, buffer);
}
fn lvoGetBufferMemoryRequirements(base: *FacetBase, device: *facet.Device, buffer: *facet.Buffer, requirements: *facet.MemoryRequirements) callconv(.c) void {
    return GetBufferMemoryRequirements(base, device, buffer, requirements);
}
fn lvoBindBufferMemory(base: *FacetBase, device: *facet.Device, buffer: *facet.Buffer, memory: *facet.DeviceMemory, offset: u64) callconv(.c) facet.Result {
    return BindBufferMemory(base, device, buffer, memory, offset);
}
fn lvoCreateImage(base: *FacetBase, device: *facet.Device, info: *const facet.ImageCreateInfo, image: *?*facet.Image) callconv(.c) facet.Result {
    return CreateImage(base, device, info, image);
}
fn lvoDestroyImage(base: *FacetBase, device: *facet.Device, image: ?*facet.Image) callconv(.c) void {
    return DestroyImage(base, device, image);
}
fn lvoGetImageMemoryRequirements(base: *FacetBase, device: *facet.Device, image: *facet.Image, requirements: *facet.MemoryRequirements) callconv(.c) void {
    return GetImageMemoryRequirements(base, device, image, requirements);
}
fn lvoBindImageMemory(base: *FacetBase, device: *facet.Device, image: *facet.Image, memory: *facet.DeviceMemory, offset: u64) callconv(.c) facet.Result {
    return BindImageMemory(base, device, image, memory, offset);
}
fn lvoGetImageSubresourceLayout(base: *FacetBase, device: *facet.Device, image: *facet.Image, subresource: *const facet.ImageSubresource, layout: *facet.SubresourceLayout) callconv(.c) void {
    return GetImageSubresourceLayout(base, device, image, subresource, layout);
}
fn lvoCreateImageView(base: *FacetBase, device: *facet.Device, info: *const facet.ImageViewCreateInfo, view: *?*facet.ImageView) callconv(.c) facet.Result {
    return CreateImageView(base, device, info, view);
}
fn lvoDestroyImageView(base: *FacetBase, device: *facet.Device, view: ?*facet.ImageView) callconv(.c) void {
    return DestroyImageView(base, device, view);
}
fn lvoCreateCommandPool(base: *FacetBase, device: *facet.Device, info: *const facet.CommandPoolCreateInfo, pool: *?*facet.CommandPool) callconv(.c) facet.Result {
    return CreateCommandPool(base, device, info, pool);
}
fn lvoDestroyCommandPool(base: *FacetBase, device: *facet.Device, pool: ?*facet.CommandPool) callconv(.c) void {
    return DestroyCommandPool(base, device, pool);
}
fn lvoResetCommandPool(base: *FacetBase, device: *facet.Device, pool: *facet.CommandPool, flags: u32) callconv(.c) facet.Result {
    return ResetCommandPool(base, device, pool, flags);
}
fn lvoAllocateCommandBuffers(base: *FacetBase, device: *facet.Device, info: *const facet.CommandBufferAllocateInfo, buffers: [*]?*facet.CommandBuffer) callconv(.c) facet.Result {
    return AllocateCommandBuffers(base, device, info, buffers);
}
fn lvoFreeCommandBuffers(base: *FacetBase, device: *facet.Device, pool: *facet.CommandPool, count: u32, buffers: [*]const ?*facet.CommandBuffer) callconv(.c) void {
    return FreeCommandBuffers(base, device, pool, count, buffers);
}
fn lvoBeginCommandBuffer(base: *FacetBase, buffer: *facet.CommandBuffer, info: *const facet.CommandBufferBeginInfo) callconv(.c) facet.Result {
    return BeginCommandBuffer(base, buffer, info);
}
fn lvoEndCommandBuffer(base: *FacetBase, buffer: *facet.CommandBuffer) callconv(.c) facet.Result {
    return EndCommandBuffer(base, buffer);
}
fn lvoResetCommandBuffer(base: *FacetBase, buffer: *facet.CommandBuffer, flags: u32) callconv(.c) facet.Result {
    return ResetCommandBuffer(base, buffer, flags);
}
fn lvoCmdPipelineBarrier(base: *FacetBase, buffer: *facet.CommandBuffer, src_stage_mask: u32, dst_stage_mask: u32, dependency_flags: u32, memory_barrier_count: u32, memory_barriers: ?[*]const facet.MemoryBarrier, buffer_barrier_count: u32, buffer_barriers: ?[*]const facet.BufferMemoryBarrier, image_barrier_count: u32, image_barriers: ?[*]const facet.ImageMemoryBarrier) callconv(.c) void {
    return CmdPipelineBarrier(base, buffer, src_stage_mask, dst_stage_mask, dependency_flags, memory_barrier_count, memory_barriers, buffer_barrier_count, buffer_barriers, image_barrier_count, image_barriers);
}
fn lvoCmdCopyBufferToImage(base: *FacetBase, buffer: *facet.CommandBuffer, source: *facet.Buffer, image: *facet.Image, layout: facet.ImageLayout, region_count: u32, regions: [*]const facet.BufferImageCopy) callconv(.c) void {
    return CmdCopyBufferToImage(base, buffer, source, image, layout, region_count, regions);
}
fn lvoCmdCopyBuffer(base: *FacetBase, buffer: *facet.CommandBuffer, source: *facet.Buffer, destination: *facet.Buffer, region_count: u32, regions: [*]const facet.BufferCopy) callconv(.c) void {
    return CmdCopyBuffer(base, buffer, source, destination, region_count, regions);
}
fn lvoQueueSubmit(base: *FacetBase, queue: *facet.Queue, count: u32, submits: ?[*]const facet.SubmitInfo, fence: ?*facet.Fence) callconv(.c) facet.Result {
    return QueueSubmit(base, queue, count, submits, fence);
}
fn lvoQueueWaitIdle(base: *FacetBase, queue: *facet.Queue) callconv(.c) facet.Result {
    return QueueWaitIdle(base, queue);
}
fn lvoDeviceWaitIdle(base: *FacetBase, device: *facet.Device) callconv(.c) facet.Result {
    return DeviceWaitIdle(base, device);
}
fn lvoCreateFence(base: *FacetBase, device: *facet.Device, info: *const facet.FenceCreateInfo, fence: *?*facet.Fence) callconv(.c) facet.Result {
    return CreateFence(base, device, info, fence);
}
fn lvoDestroyFence(base: *FacetBase, device: *facet.Device, fence: ?*facet.Fence) callconv(.c) void {
    return DestroyFence(base, device, fence);
}
fn lvoResetFences(base: *FacetBase, device: *facet.Device, count: u32, fences: [*]const *facet.Fence) callconv(.c) facet.Result {
    return ResetFences(base, device, count, fences);
}
fn lvoGetFenceStatus(base: *FacetBase, device: *facet.Device, fence: *facet.Fence) callconv(.c) facet.Result {
    return GetFenceStatus(base, device, fence);
}
fn lvoWaitForFences(base: *FacetBase, device: *facet.Device, count: u32, fences: [*]const *facet.Fence, wait_all: bool, timeout: u64) callconv(.c) facet.Result {
    return WaitForFences(base, device, count, fences, wait_all, timeout);
}
fn lvoCreateSemaphore(base: *FacetBase, device: *facet.Device, info: *const facet.SemaphoreCreateInfo, semaphore: *?*facet.Semaphore) callconv(.c) facet.Result {
    return CreateSemaphore(base, device, info, semaphore);
}
fn lvoDestroySemaphore(base: *FacetBase, device: *facet.Device, semaphore: ?*facet.Semaphore) callconv(.c) void {
    return DestroySemaphore(base, device, semaphore);
}
fn lvoCreateRenderPass(base: *FacetBase, device: *facet.Device, info: *const facet.RenderPassCreateInfo, render_pass: *?*facet.RenderPass) callconv(.c) facet.Result {
    return CreateRenderPass(base, device, info, render_pass);
}
fn lvoDestroyRenderPass(base: *FacetBase, device: *facet.Device, render_pass: ?*facet.RenderPass) callconv(.c) void {
    return DestroyRenderPass(base, device, render_pass);
}
fn lvoCreateFramebuffer(base: *FacetBase, device: *facet.Device, info: *const facet.FramebufferCreateInfo, framebuffer: *?*facet.Framebuffer) callconv(.c) facet.Result {
    return CreateFramebuffer(base, device, info, framebuffer);
}
fn lvoDestroyFramebuffer(base: *FacetBase, device: *facet.Device, framebuffer: ?*facet.Framebuffer) callconv(.c) void {
    return DestroyFramebuffer(base, device, framebuffer);
}
fn lvoCreateShaderModule(base: *FacetBase, device: *facet.Device, info: *const facet.ShaderModuleCreateInfo, module: *?*facet.ShaderModule) callconv(.c) facet.Result {
    return CreateShaderModule(base, device, info, module);
}
fn lvoDestroyShaderModule(base: *FacetBase, device: *facet.Device, module: ?*facet.ShaderModule) callconv(.c) void {
    return DestroyShaderModule(base, device, module);
}
fn lvoCreateDescriptorSetLayout(base: *FacetBase, device: *facet.Device, info: *const facet.DescriptorSetLayoutCreateInfo, layout: *?*facet.DescriptorSetLayout) callconv(.c) facet.Result {
    return CreateDescriptorSetLayout(base, device, info, layout);
}
fn lvoDestroyDescriptorSetLayout(base: *FacetBase, device: *facet.Device, layout: ?*facet.DescriptorSetLayout) callconv(.c) void {
    return DestroyDescriptorSetLayout(base, device, layout);
}
fn lvoCreatePipelineLayout(base: *FacetBase, device: *facet.Device, info: *const facet.PipelineLayoutCreateInfo, layout: *?*facet.PipelineLayout) callconv(.c) facet.Result {
    return CreatePipelineLayout(base, device, info, layout);
}
fn lvoDestroyPipelineLayout(base: *FacetBase, device: *facet.Device, layout: ?*facet.PipelineLayout) callconv(.c) void {
    return DestroyPipelineLayout(base, device, layout);
}
fn lvoCreateDescriptorPool(base: *FacetBase, device: *facet.Device, info: *const facet.DescriptorPoolCreateInfo, pool: *?*facet.DescriptorPool) callconv(.c) facet.Result {
    return CreateDescriptorPool(base, device, info, pool);
}
fn lvoDestroyDescriptorPool(base: *FacetBase, device: *facet.Device, pool: ?*facet.DescriptorPool) callconv(.c) void {
    return DestroyDescriptorPool(base, device, pool);
}
fn lvoResetDescriptorPool(base: *FacetBase, device: *facet.Device, pool: *facet.DescriptorPool, flags: u32) callconv(.c) facet.Result {
    return ResetDescriptorPool(base, device, pool, flags);
}
fn lvoAllocateDescriptorSets(base: *FacetBase, device: *facet.Device, info: *const facet.DescriptorSetAllocateInfo, sets: [*]?*facet.DescriptorSet) callconv(.c) facet.Result {
    return AllocateDescriptorSets(base, device, info, sets);
}
fn lvoFreeDescriptorSets(base: *FacetBase, device: *facet.Device, pool: *facet.DescriptorPool, count: u32, sets: [*]const ?*facet.DescriptorSet) callconv(.c) facet.Result {
    return FreeDescriptorSets(base, device, pool, count, sets);
}
fn lvoUpdateDescriptorSets(base: *FacetBase, device: *facet.Device, write_count: u32, writes: ?[*]const facet.WriteDescriptorSet, copy_count: u32, copies: ?[*]const facet.CopyDescriptorSet) callconv(.c) void {
    return UpdateDescriptorSets(base, device, write_count, writes, copy_count, copies);
}
fn lvoCreateGraphicsPipelines(base: *FacetBase, device: *facet.Device, cache: ?*facet.PipelineCache, count: u32, infos: [*]const facet.GraphicsPipelineCreateInfo, pipelines: [*]?*facet.Pipeline) callconv(.c) facet.Result {
    return CreateGraphicsPipelines(base, device, cache, count, infos, pipelines);
}
fn lvoDestroyPipeline(base: *FacetBase, device: *facet.Device, pipeline: ?*facet.Pipeline) callconv(.c) void {
    return DestroyPipeline(base, device, pipeline);
}
fn lvoCmdBeginRenderPass(base: *FacetBase, buffer: *facet.CommandBuffer, info: *const facet.RenderPassBeginInfo, contents: facet.SubpassContents) callconv(.c) void {
    return CmdBeginRenderPass(base, buffer, info, contents);
}
fn lvoCmdEndRenderPass(base: *FacetBase, buffer: *facet.CommandBuffer) callconv(.c) void {
    return CmdEndRenderPass(base, buffer);
}
fn lvoCmdBindPipeline(base: *FacetBase, buffer: *facet.CommandBuffer, bind_point: facet.PipelineBindPoint, pipeline: *facet.Pipeline) callconv(.c) void {
    return CmdBindPipeline(base, buffer, bind_point, pipeline);
}
fn lvoCmdBindVertexBuffers(base: *FacetBase, buffer: *facet.CommandBuffer, first_binding: u32, count: u32, buffers: [*]const *facet.Buffer, offsets: [*]const u64) callconv(.c) void {
    return CmdBindVertexBuffers(base, buffer, first_binding, count, buffers, offsets);
}
fn lvoCmdBindIndexBuffer(base: *FacetBase, buffer: *facet.CommandBuffer, index_buffer: *facet.Buffer, offset: u64, index_type: facet.IndexType) callconv(.c) void {
    return CmdBindIndexBuffer(base, buffer, index_buffer, offset, index_type);
}
fn lvoCmdBindDescriptorSets(base: *FacetBase, buffer: *facet.CommandBuffer, bind_point: facet.PipelineBindPoint, layout: *facet.PipelineLayout, first_set: u32, count: u32, sets: [*]const *facet.DescriptorSet, dynamic_offset_count: u32, dynamic_offsets: ?[*]const u32) callconv(.c) void {
    return CmdBindDescriptorSets(base, buffer, bind_point, layout, first_set, count, sets, dynamic_offset_count, dynamic_offsets);
}
fn lvoCmdPushConstants(base: *FacetBase, buffer: *facet.CommandBuffer, layout: *facet.PipelineLayout, stage_flags: u32, offset: u32, size: u32, values: *const anyopaque) callconv(.c) void {
    return CmdPushConstants(base, buffer, layout, stage_flags, offset, size, values);
}
fn lvoCmdSetViewport(base: *FacetBase, buffer: *facet.CommandBuffer, first_viewport: u32, count: u32, viewports: [*]const facet.Viewport) callconv(.c) void {
    return CmdSetViewport(base, buffer, first_viewport, count, viewports);
}
fn lvoCmdSetScissor(base: *FacetBase, buffer: *facet.CommandBuffer, first_scissor: u32, count: u32, scissors: [*]const facet.Rect2D) callconv(.c) void {
    return CmdSetScissor(base, buffer, first_scissor, count, scissors);
}
fn lvoCmdDraw(base: *FacetBase, buffer: *facet.CommandBuffer, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) callconv(.c) void {
    return CmdDraw(base, buffer, vertex_count, instance_count, first_vertex, first_instance);
}
fn lvoCmdDrawIndexed(base: *FacetBase, buffer: *facet.CommandBuffer, index_count: u32, instance_count: u32, first_index: u32, vertex_offset: i32, first_instance: u32) callconv(.c) void {
    return CmdDrawIndexed(base, buffer, index_count, instance_count, first_index, vertex_offset, first_instance);
}
fn lvoCreateScreenSurface(base: *FacetBase, instance: *facet.Instance, info: *const facet.ScreenSurfaceCreateInfo, surface: *?*facet.Surface) callconv(.c) facet.Result {
    return CreateScreenSurface(base, instance, info, surface);
}
fn lvoDestroySurface(base: *FacetBase, instance: *facet.Instance, surface: ?*facet.Surface) callconv(.c) void {
    return DestroySurface(base, instance, surface);
}
fn lvoGetPhysicalDeviceSurfaceSupport(base: *FacetBase, physical: *facet.PhysicalDevice, family: u32, surface: *facet.Surface, supported: *bool) callconv(.c) facet.Result {
    return GetPhysicalDeviceSurfaceSupport(base, physical, family, surface, supported);
}
fn lvoGetPhysicalDeviceSurfaceCapabilities(base: *FacetBase, physical: *facet.PhysicalDevice, surface: *facet.Surface, capabilities: *facet.SurfaceCapabilities) callconv(.c) facet.Result {
    return GetPhysicalDeviceSurfaceCapabilities(base, physical, surface, capabilities);
}
fn lvoGetPhysicalDeviceSurfaceFormats(base: *FacetBase, physical: *facet.PhysicalDevice, surface: *facet.Surface, count: *u32, formats: ?[*]facet.SurfaceFormat) callconv(.c) facet.Result {
    return GetPhysicalDeviceSurfaceFormats(base, physical, surface, count, formats);
}
fn lvoGetPhysicalDeviceSurfacePresentModes(base: *FacetBase, physical: *facet.PhysicalDevice, surface: *facet.Surface, count: *u32, modes: ?[*]facet.PresentMode) callconv(.c) facet.Result {
    return GetPhysicalDeviceSurfacePresentModes(base, physical, surface, count, modes);
}
fn lvoCreateSwapchain(base: *FacetBase, device: *facet.Device, info: *const facet.SwapchainCreateInfo, swapchain: *?*facet.Swapchain) callconv(.c) facet.Result {
    return CreateSwapchain(base, device, info, swapchain);
}
fn lvoDestroySwapchain(base: *FacetBase, device: *facet.Device, swapchain: ?*facet.Swapchain) callconv(.c) void {
    return DestroySwapchain(base, device, swapchain);
}
fn lvoGetSwapchainImages(base: *FacetBase, device: *facet.Device, swapchain: *facet.Swapchain, count: *u32, images: ?[*]*facet.Image) callconv(.c) facet.Result {
    return GetSwapchainImages(base, device, swapchain, count, images);
}
fn lvoAcquireNextImage(base: *FacetBase, device: *facet.Device, swapchain: *facet.Swapchain, timeout: u64, semaphore: ?*facet.Semaphore, fence: ?*facet.Fence, index: *u32) callconv(.c) facet.Result {
    return AcquireNextImage(base, device, swapchain, timeout, semaphore, fence, index);
}
fn lvoQueuePresent(base: *FacetBase, queue: *facet.Queue, info: *const facet.PresentInfo) callconv(.c) facet.Result {
    return QueuePresent(base, queue, info);
}
fn lvoCreateWindowSurface(base: *FacetBase, instance: *facet.Instance, info: *const facet.WindowSurfaceCreateInfo, surface: *?*facet.Surface) callconv(.c) facet.Result {
    return CreateWindowSurface(base, instance, info, surface);
}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(facet_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoCreateInstance),
    vec(lvoDestroyInstance),
    vec(lvoEnumeratePhysicalDevices),
    vec(lvoGetPhysicalDeviceProperties),
    vec(lvoGetPhysicalDeviceQueueFamilyProperties),
    vec(lvoGetPhysicalDeviceMemoryProperties),
    vec(lvoCreateDevice),
    vec(lvoDestroyDevice),
    vec(lvoGetDeviceQueue),
    vec(lvoAllocateMemory),
    vec(lvoFreeMemory),
    vec(lvoMapMemory),
    vec(lvoUnmapMemory),
    vec(lvoGetPhysicalDeviceFormatProperties),
    vec(lvoCreateBuffer),
    vec(lvoDestroyBuffer),
    vec(lvoGetBufferMemoryRequirements),
    vec(lvoBindBufferMemory),
    vec(lvoCreateImage),
    vec(lvoDestroyImage),
    vec(lvoGetImageMemoryRequirements),
    vec(lvoBindImageMemory),
    vec(lvoGetImageSubresourceLayout),
    vec(lvoCreateImageView),
    vec(lvoDestroyImageView),
    vec(lvoCreateCommandPool),
    vec(lvoDestroyCommandPool),
    vec(lvoResetCommandPool),
    vec(lvoAllocateCommandBuffers),
    vec(lvoFreeCommandBuffers),
    vec(lvoBeginCommandBuffer),
    vec(lvoEndCommandBuffer),
    vec(lvoResetCommandBuffer),
    vec(lvoCmdPipelineBarrier),
    vec(lvoCmdCopyBufferToImage),
    vec(lvoCmdCopyBuffer),
    vec(lvoQueueSubmit),
    vec(lvoQueueWaitIdle),
    vec(lvoDeviceWaitIdle),
    vec(lvoCreateFence),
    vec(lvoDestroyFence),
    vec(lvoResetFences),
    vec(lvoGetFenceStatus),
    vec(lvoWaitForFences),
    vec(lvoCreateSemaphore),
    vec(lvoDestroySemaphore),
    vec(lvoCreateRenderPass),
    vec(lvoDestroyRenderPass),
    vec(lvoCreateFramebuffer),
    vec(lvoDestroyFramebuffer),
    vec(lvoCreateShaderModule),
    vec(lvoDestroyShaderModule),
    vec(lvoCreateDescriptorSetLayout),
    vec(lvoDestroyDescriptorSetLayout),
    vec(lvoCreatePipelineLayout),
    vec(lvoDestroyPipelineLayout),
    vec(lvoCreateDescriptorPool),
    vec(lvoDestroyDescriptorPool),
    vec(lvoResetDescriptorPool),
    vec(lvoAllocateDescriptorSets),
    vec(lvoFreeDescriptorSets),
    vec(lvoUpdateDescriptorSets),
    vec(lvoCreateGraphicsPipelines),
    vec(lvoDestroyPipeline),
    vec(lvoCmdBeginRenderPass),
    vec(lvoCmdEndRenderPass),
    vec(lvoCmdBindPipeline),
    vec(lvoCmdBindVertexBuffers),
    vec(lvoCmdBindIndexBuffer),
    vec(lvoCmdBindDescriptorSets),
    vec(lvoCmdPushConstants),
    vec(lvoCmdSetViewport),
    vec(lvoCmdSetScissor),
    vec(lvoCmdDraw),
    vec(lvoCmdDrawIndexed),
    vec(lvoCreateScreenSurface),
    vec(lvoDestroySurface),
    vec(lvoGetPhysicalDeviceSurfaceSupport),
    vec(lvoGetPhysicalDeviceSurfaceCapabilities),
    vec(lvoGetPhysicalDeviceSurfaceFormats),
    vec(lvoGetPhysicalDeviceSurfacePresentModes),
    vec(lvoCreateSwapchain),
    vec(lvoDestroySwapchain),
    vec(lvoGetSwapchainImages),
    vec(lvoAcquireNextImage),
    vec(lvoQueuePresent),
    vec(lvoCreateWindowSurface),
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "the jump table: the standard four, then this library's own" {
    try testing.expectEqual(@as(usize, 4 + @typeInfo(LVO).@"struct".decls.len), vectors.len);
    inline for (@typeInfo(LVO).@"struct".decls) |d| {
        const index: usize = @intCast(@divExact(-@field(LVO, d.name), exec.slot_size) - 1);
        try testing.expectEqual(vec(@field(@This(), "lvo" ++ d.name)), vectors[index]);
    }
}

test "every wrapper hands its parameters on, in order, to the call it is named after" {
    try exec.libraries.checkForwarding(@embedFile("facet_lvo.zig"), LVO, &.{});
}
