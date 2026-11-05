# facet.library

facet.library's functions: three-dimensional drawing as Vulkan has
it - an instance, the devices, their memory, buffers and images,
render passes, pipelines whose shaders are the program's own
functions, and command buffers played on a queue - on the machine's
cores - and the swapchains that show what is drawn on a screen. Open
it with OpenLibrary("facet.library", 1); the structures are in
sdk.facet.

Generated from the source by `./zig build autodoc`.

## Index

- [AcquireNextImage](#acquirenextimage) - An image of the swapchain to draw into, its number written to `index`.
- [AllocateCommandBuffers](#allocatecommandbuffers) - Command buffers allocated from a pool.
- [AllocateDescriptorSets](#allocatedescriptorsets) - A descriptor set for each layout `info` names, into `sets`.
- [AllocateMemory](#allocatememory) - A block of the device's memory, of one of its memory types.
- [BeginCommandBuffer](#begincommandbuffer) - The command buffer's recording begun.
- [BindBufferMemory](#bindbuffermemory) - The buffer bound into a block of memory, at an offset.
- [BindImageMemory](#bindimagememory) - The image bound into a block of memory, at an offset.
- [CmdBeginQuery](#cmdbeginquery) - Recorded: query `query` of `pool` begun - what the draws and the dispatches until `CmdEndQuery` come to is counted into it.
- [CmdBeginRenderPass](#cmdbeginrenderpass) - Recorded: a render pass begun, drawing into a framebuffer.
- [CmdBindDescriptorSets](#cmdbinddescriptorsets) - Recorded: descriptor sets bound, from set `first_set` on.
- [CmdBindIndexBuffer](#cmdbindindexbuffer) - Recorded: the index buffer CmdDrawIndexed reads.
- [CmdBindPipeline](#cmdbindpipeline) - Recorded: the pipeline the draws after it draw with.
- [CmdBindVertexBuffers](#cmdbindvertexbuffers) - Recorded: vertex buffers bound, from binding `first_binding` on.
- [CmdBlitImage](#cmdblitimage) - Recorded: a rectangle of an image drawn over one of another, scaled.
- [CmdClearAttachments](#cmdclearattachments) - Recorded: parts of a render pass's attachments cleared, in the middle of it.
- [CmdClearColorImage](#cmdclearcolorimage) - Recorded: an image's levels and layers set to a colour.
- [CmdClearDepthStencilImage](#cmdcleardepthstencilimage) - Recorded: a depth image's pixels set to a depth.
- [CmdCopyBuffer](#cmdcopybuffer) - Recorded: bytes copied from one buffer to another.
- [CmdCopyBufferToImage](#cmdcopybuffertoimage) - Recorded: rectangles of texels copied from a buffer into an image.
- [CmdCopyImage](#cmdcopyimage) - Recorded: a rectangle of texels copied from one image to another, as they are.
- [CmdCopyImageToBuffer](#cmdcopyimagetobuffer) - Recorded: a rectangle of texels copied from an image to a buffer.
- [CmdCopyQueryPoolResults](#cmdcopyquerypoolresults) - Recorded: what `count` queries from `first` counted, written into a buffer as `GetQueryPoolResults` writes it into memory.
- [CmdDispatch](#cmddispatch) - Recorded: the compute function bound run, for each of the groups.
- [CmdDispatchIndirect](#cmddispatchindirect) - Recorded: as CmdDispatch, its numbers in a buffer.
- [CmdDraw](#cmddraw) - Recorded: vertices drawn, in the order they are in the vertex buffers.
- [CmdDrawIndexed](#cmddrawindexed) - Recorded: vertices drawn in the order the index buffer gives them.
- [CmdDrawIndexedIndirect](#cmddrawindexedindirect) - Recorded: draws whose numbers, as CmdDrawIndexed takes them, are in a buffer.
- [CmdDrawIndirect](#cmddrawindirect) - Recorded: draws whose numbers, as CmdDraw takes them, are in a buffer.
- [CmdEndQuery](#cmdendquery) - Recorded: the query ended - nothing after it is counted into it - and what it counted made available.
- [CmdEndRenderPass](#cmdendrenderpass) - Recorded: the render pass ended, and what it drew stored.
- [CmdExecuteCommands](#cmdexecutecommands) - Recorded: secondary command buffers played, in the order given.
- [CmdFillBuffer](#cmdfillbuffer) - Recorded: a run of a buffer set to one value, four bytes at a time.
- [CmdNextSubpass](#cmdnextsubpass) - Recorded: what the subpass drew stored, and the next subpass begun.
- [CmdPipelineBarrier](#cmdpipelinebarrier) - Recorded: a barrier between the work before it and the work after.
- [CmdPushConstants](#cmdpushconstants) - Recorded: bytes of push constants set.
- [CmdResetQueryPool](#cmdresetquerypool) - Recorded: `count` queries from `first` set back to nothing counted and not available.
- [CmdSetBlendConstants](#cmdsetblendconstants) - Recorded: the blend constants, for a pipeline that leaves them to commands.
- [CmdSetBlendConstantsAt](#cmdsetblendconstantsat) - Recorded: one colour attachment's own blend constants, for a pipeline that leaves them to commands.
- [CmdSetDepthBias](#cmdsetdepthbias) - Recorded: the depth bias, for a pipeline that leaves it to commands.
- [CmdSetDepthBounds](#cmdsetdepthbounds) - Recorded: the depth bounds, for a pipeline that leaves them to commands.
- [CmdSetLineWidth](#cmdsetlinewidth) - Recorded: the width of lines, for a pipeline that leaves it to commands.
- [CmdSetScissor](#cmdsetscissor) - Recorded: the scissor, for a pipeline that leaves it to commands.
- [CmdSetStencilCompareMask](#cmdsetstencilcomparemask) - Recorded: the stencil test's compare mask, for a pipeline that leaves it to commands.
- [CmdSetStencilReference](#cmdsetstencilreference) - Recorded: the stencil test's reference, for a pipeline that leaves it to commands.
- [CmdSetStencilWriteMask](#cmdsetstencilwritemask) - Recorded: the stencil test's write mask, for a pipeline that leaves it to commands.
- [CmdSetViewport](#cmdsetviewport) - Recorded: the viewport, for a pipeline that leaves it to commands.
- [CmdUpdateBuffer](#cmdupdatebuffer) - Recorded: bytes written into a buffer, kept with the command.
- [CmdWriteTimestamp](#cmdwritetimestamp) - Recorded: the clock written into query `query` of `pool` when the command is played.
- [CreateBuffer](#createbuffer) - A buffer of so many bytes, for what its usage says.
- [CreateBufferView](#createbufferview) - A range of a buffer read as texels of a format, for a texel buffer descriptor.
- [CreateCommandPool](#createcommandpool) - A pool the device's command buffers are allocated from.
- [CreateComputePipelines](#createcomputepipelines) - `count` compute pipelines, one for each of `infos`, into `pipelines`.
- [CreateDescriptorPool](#createdescriptorpool) - A descriptor pool: the most sets it gives out at once.
- [CreateDescriptorSetLayout](#createdescriptorsetlayout) - A descriptor set layout: a set's bindings, each of a kind, with its descriptors.
- [CreateDevice](#createdevice) - A device of the program's own, with its queue.
- [CreateFence](#createfence) - A fence: signalled by a queue when the submission it came with is done.
- [CreateFramebuffer](#createframebuffer) - A framebuffer: an image view for each of a render pass's attachments.
- [CreateGraphicsPipelines](#creategraphicspipelines) - `count` graphics pipelines, one for each of `infos`, into `pipelines`.
- [CreateImage](#createimage) - An image: a texture, an attachment, or what a copy moves.
- [CreateImageView](#createimageview) - A view of an image: the levels of it a texture descriptor samples, or what a framebuffer draws into.
- [CreateInstance](#createinstance) - A program's hold on the library, through which it finds the devices.
- [CreatePipelineLayout](#createpipelinelayout) - A pipeline layout: the descriptor sets and the push constants a pipeline's shaders read.
- [CreateQueryPool](#createquerypool) - A query pool: `query_count` queries of one kind, nothing counted yet.
- [CreateRenderPass](#createrenderpass) - A render pass: the attachments it draws into, what each starts with and what is kept of it.
- [CreateSampler](#createsampler) - A sampler: the filter, the levels, the edges and the comparison a texture bound beside it is sampled with.
- [CreateScreenSurface](#createscreensurface) - A surface over a screen the program has opened, written to `surface`.
- [CreateSemaphore](#createsemaphore) - A semaphore: signalled by one submission, waited for by another.
- [CreateShaderModule](#createshadermodule) - A shader module: the vertex and fragment functions a `shader.Code` names.
- [CreateSwapchain](#createswapchain) - A swapchain on a surface, written to `swapchain`.
- [CreateWindowSurface](#createwindowsurface) - A surface over the inside of a window the program has opened, written to `surface`.
- [DestroyBuffer](#destroybuffer) - The buffer given back.
- [DestroyBufferView](#destroybufferview) - A buffer view given back.
- [DestroyCommandPool](#destroycommandpool) - The pool given back, and every command buffer allocated from it.
- [DestroyDescriptorPool](#destroydescriptorpool) - The descriptor pool given back, and every set allocated from it.
- [DestroyDescriptorSetLayout](#destroydescriptorsetlayout) - The descriptor set layout given back; the sets allocated with it stay.
- [DestroyDevice](#destroydevice) - The device given back, and its queue's task ended.
- [DestroyFence](#destroyfence) - The fence given back.
- [DestroyFramebuffer](#destroyframebuffer) - The framebuffer given back.
- [DestroyImage](#destroyimage) - The image given back.
- [DestroyImageView](#destroyimageview) - The view given back.
- [DestroyInstance](#destroyinstance) - The instance given back.
- [DestroyPipeline](#destroypipeline) - The pipeline given back: no submission still drawing with it.
- [DestroyPipelineLayout](#destroypipelinelayout) - The pipeline layout given back.
- [DestroyQueryPool](#destroyquerypool) - The pool given back.
- [DestroyRenderPass](#destroyrenderpass) - The render pass given back.
- [DestroySampler](#destroysampler) - The sampler given back.
- [DestroySemaphore](#destroysemaphore) - The semaphore given back.
- [DestroyShaderModule](#destroyshadermodule) - The shader module given back; the pipelines made from it stay.
- [DestroySurface](#destroysurface) - The surface given back: every swapchain made on it destroyed first.
- [DestroySwapchain](#destroyswapchain) - The swapchain given back, and its images.
- [DeviceWaitIdle](#devicewaitidle) - Wait until every queue of the device has done all it was given.
- [EndCommandBuffer](#endcommandbuffer) - The command buffer's recording ended: it can be submitted.
- [EnumeratePhysicalDevices](#enumeratephysicaldevices) - The instance's physical devices.
- [FreeCommandBuffers](#freecommandbuffers) - Command buffers given back to the pool they came from.
- [FreeDescriptorSets](#freedescriptorsets) - `count` descriptor sets given back to the pool they came from.
- [FreeMemory](#freememory) - The block given back.
- [GetBufferMemoryRequirements](#getbuffermemoryrequirements) - What the buffer needs of the memory it is bound into.
- [GetDeviceMemoryCommitment](#getdevicememorycommitment) - How many bytes of a block the device has really put behind it.
- [GetDeviceQueue](#getdevicequeue) - A queue the device was made with.
- [GetFenceStatus](#getfencestatus) - Whether a fence is signalled, without waiting.
- [GetImageMemoryRequirements](#getimagememoryrequirements) - What the image needs of the memory it is bound into.
- [GetImageSubresourceLayout](#getimagesubresourcelayout) - Where a level of an image lies in its memory, and how its rows do.
- [GetPhysicalDeviceFeatures](#getphysicaldevicefeatures) - What a physical device does, so that a program may ask before it is refused.
- [GetPhysicalDeviceFormatProperties](#getphysicaldeviceformatproperties) - What the device does with a format, in each tiling and in a buffer.
- [GetPhysicalDeviceImageFormatProperties](#getphysicaldeviceimageformatproperties) - The largest image of a format, type, tiling and usage, or `error_format_not_supported` where there is no such image at all.
- [GetPhysicalDeviceMemoryProperties](#getphysicaldevicememoryproperties) - The physical device's memory types and heaps.
- [GetPhysicalDeviceProperties](#getphysicaldeviceproperties) - What a physical device is, and the most it does.
- [GetPhysicalDeviceQueueFamilyProperties](#getphysicaldevicequeuefamilyproperties) - The physical device's queue families.
- [GetPhysicalDeviceSurfaceCapabilities](#getphysicaldevicesurfacecapabilities) - What a swapchain on the surface can be, into `capabilities`.
- [GetPhysicalDeviceSurfaceFormats](#getphysicaldevicesurfaceformats) - The formats a swapchain on the surface can have into `formats`, at most `count.*` of them, and how many there are into `count`; null for `formats` counts alone.
- [GetPhysicalDeviceSurfacePresentModes](#getphysicaldevicesurfacepresentmodes) - The present modes of the surface into `modes`, at most `count.*` of them, and how many there are into `count`; null for `modes` counts alone.
- [GetPhysicalDeviceSurfaceSupport](#getphysicaldevicesurfacesupport) - Whether queue family `family` can present to the surface, into `supported`.
- [GetQueryPoolResults](#getquerypoolresults) - What `count` queries from `first` counted, written into `data`.
- [GetRenderAreaGranularity](#getrenderareagranularity) - The granularity of a render area on this device: the tile it draws in.
- [GetSwapchainImages](#getswapchainimages) - The swapchain's images into `images`, at most `count.*` of them, and how many there are into `count`; null for `images` counts alone.
- [MapMemory](#mapmemory) - The address of a block's memory, from an offset on.
- [QueuePresent](#queuepresent) - Images handed to the queue to be shown, once the semaphores are signalled.
- [QueueSubmit](#queuesubmit) - Batches of work for the queue, played in order by its task.
- [QueueWaitIdle](#queuewaitidle) - Wait until the queue has done all it was given.
- [ResetCommandBuffer](#resetcommandbuffer) - The command buffer back to where it started.
- [ResetCommandPool](#resetcommandpool) - Every command buffer of the pool back to where it started.
- [ResetDescriptorPool](#resetdescriptorpool) - Every set allocated from the pool freed at once.
- [ResetFences](#resetfences) - Fences back to unsignalled.
- [UnmapMemory](#unmapmemory) - The block's mapping ended.
- [UpdateDescriptorSets](#updatedescriptorsets) - Descriptors written into sets, and copied from one set to another.
- [WaitForFences](#waitforfences) - Wait until fences are signalled: all of them, or any.

## AcquireNextImage

An image of the swapchain to draw into, its number written to `index`.

**SYNOPSIS**

```zig
fn AcquireNextImage(base: *FacetBase, device: *facet.Device, swapchain: *facet.Swapchain, timeout: u64, semaphore: ?*facet.Semaphore, fence: ?*facet.Fence, index: *u32) facet.Result
```

**SINCE**

1.0. LVO -356.

**INPUTS**

- `device` - the device it was made with.
- `swapchain` - the swapchain.
- `timeout` - the nanoseconds to wait for one at most; WAIT_FOREVER_NS
  waits as long as it takes, 0 not at all.
- `semaphore`, `fence` - signalled when the image can be drawn into, or
  null.
- `index` - the image's number, as GetSwapchainImages lists them.

**RESULT**

`success`; `timeout`, or `not_ready` with a timeout of 0, when none
came free in time, or none will - each held by the program, or shown
with nothing presented after it; `error_out_of_date` when the surface's
size or format has changed, or the swapchain has been handed on;
`error_surface_lost` when the window the surface is over has closed;
`error_device_lost` once the device is lost.

**BEHAVIOR**

An image is handed out when the display no longer reads it: the one
shown comes free when the display has taken up the next presented. So
the semaphore and the fence are signalled as the call returns. A
swapchain of one image hands out the image shown, drawn while it is seen.

**CONTEXT**

- Waits: for an image to come free, at most `timeout`.
- Interrupts: no.
- Locks: no spinlock may be held; on a window's surface, no layer's
  lock either - its window is found under the screens' semaphore.
- Process: a Task will do.

**OWNERSHIP**

The image is the program's until it is presented.

**NOTES**

With two images, a frame is drawn into one while the other is shown,
and the next acquire waits for the display to take up the frame
presented: this is what holds a program to the display's rate.

**BUGS**

None known.

**SEE ALSO**

`QueuePresent`, `GetSwapchainImages`

**EXAMPLES**

```zig
var index: u32 = 0;
switch (fb.AcquireNextImage(device, swapchain.?, facet.WAIT_FOREVER_NS, acquired.?, null, &index)) {
    .success => {},
    .error_out_of_date => return remake(),
    .error_surface_lost => return error.WindowClosed,
    else => return error.NoImage,
}
```

## AllocateCommandBuffers

Command buffers allocated from a pool.

**SYNOPSIS**

```zig
fn AllocateCommandBuffers(base: *FacetBase, device: *facet.Device, info: *const facet.CommandBufferAllocateInfo, buffers: [*]?*facet.CommandBuffer) facet.Result
```

**SINCE**

1.0. LVO -132.

**INPUTS**

- `device` - the device.
- `info` - the pool, how many, and whether they are primary or secondary.
- `buffers` - where they are written, `info.command_buffer_count` of
  them; all null when it fails.

**RESULT**

`success`; `error_feature_not_present` for a level there is not;
`error_out_of_host_memory`, none allocated.

**BEHAVIOR**

Each buffer starts with nothing recorded, ready for
BeginCommandBuffer. A secondary one is played by CmdExecuteCommands; given
to QueueSubmit, it plays nothing.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The buffers are the pool's, given back by FreeCommandBuffers or with it.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`FreeCommandBuffers`, `BeginCommandBuffer`

**EXAMPLES**

```zig
var commands: [1]?*facet.CommandBuffer = undefined;
if (fb.AllocateCommandBuffers(device, &.{ .command_pool = pool.? }, &commands) != .success) return error.NoCommands;
```

## AllocateDescriptorSets

A descriptor set for each layout `info` names, into `sets`.

**SYNOPSIS**

```zig
fn AllocateDescriptorSets(base: *FacetBase, device: *facet.Device, info: *const facet.DescriptorSetAllocateInfo, sets: [*]?*facet.DescriptorSet) facet.Result
```

**SINCE**

1.0. LVO -256.

**INPUTS**

- `device` - the device.
- `info` - the pool, and a layout for each set.
- `sets` - where the sets are written, one for each layout; all null
  when it fails.

**RESULT**

`success`; `error_out_of_pool_memory` when the pool has given out its
most; `error_out_of_host_memory`. Either way none is allocated.

**BEHAVIOR**

A set's descriptors start empty: a shader reads null for each until it
is written (UpdateDescriptorSets).

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The sets are the pool's: they go with it, with ResetDescriptorPool or
with FreeDescriptorSets.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`UpdateDescriptorSets`, `CmdBindDescriptorSets`, `FreeDescriptorSets`

**EXAMPLES**

```zig
var set: ?*facet.DescriptorSet = null;
_ = fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, @ptrCast(&set));
```

## AllocateMemory

A block of the device's memory, of one of its memory types.

**SYNOPSIS**

```zig
fn AllocateMemory(base: *FacetBase, device: *facet.Device, info: *const facet.MemoryAllocateInfo, memory: *?*facet.DeviceMemory) facet.Result
```

**SINCE**

1.0. LVO -56.

**INPUTS**

- `device` - the device.
- `info` - how many bytes, and of which memory type.
- `memory` - where the block is written; null when it fails.

**RESULT**

`success`; `error_out_of_device_memory` when no region with the
type's attributes has room, for no bytes, and for a type the device
has not got; `error_out_of_host_memory`.

**BEHAVIOR**

The memory is exec's (AllocMem, with the attributes of the type's
heap), aligned to a cache line and not cleared. Memory of the lazily
allocated type takes nothing: it is for an attachment whose pixels
stay in the tiles, and cannot be mapped.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: exec's memory list.
- Process: a Task will do.

**OWNERSHIP**

The block is the caller's, until FreeMemory. It is the calling task's
memory as exec's tools show it, and not private: the queue's task
reads and writes it.

**NOTES**

A few large blocks with many buffers and images bound into each cost
less than a block for each.

**BUGS**

None known.

**SEE ALSO**

`FreeMemory`, `MapMemory`, `GetPhysicalDeviceMemoryProperties`

**EXAMPLES**

```zig
var memory: ?*facet.DeviceMemory = null;
const info = facet.MemoryAllocateInfo{ .allocation_size = 1 << 20, .memory_type_index = 0 };
if (fb.AllocateMemory(device, &info, &memory) != .success) return error.NoMemory;
defer fb.FreeMemory(device, memory);
```

## BeginCommandBuffer

The command buffer's recording begun.

**SYNOPSIS**

```zig
fn BeginCommandBuffer(base: *FacetBase, buffer: *facet.CommandBuffer, info: *const facet.CommandBufferBeginInfo) facet.Result
```

**SINCE**

1.0. LVO -140.

**INPUTS**

- `buffer` - a command buffer that is not pending.
- `info` - how it is used: COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT for a
  buffer submitted once.

**RESULT**

`success`.

**BEHAVIOR**

What it recorded before is gone, its memory kept for this recording.
The Cmd calls that follow record into it until EndCommandBuffer.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The buffer stays its pool's.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`EndCommandBuffer`, `ResetCommandBuffer`

**EXAMPLES**

```zig
_ = fb.BeginCommandBuffer(commands, &.{ .flags = facet.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT });
```

## BindBufferMemory

The buffer bound into a block of memory, at an offset.

**SYNOPSIS**

```zig
fn BindBufferMemory(base: *FacetBase, device: *facet.Device, buffer: *facet.Buffer, memory: *facet.DeviceMemory, offset: u64) facet.Result
```

**SINCE**

1.0. LVO -88.

**INPUTS**

- `device` - the device both are of.
- `buffer` - a buffer not yet bound.
- `memory` - the block.
- `offset` - where in it the buffer starts.

**RESULT**

`success`; `error_out_of_device_memory` when the buffer does not fit
there - past the block's end, the offset not aligned as
GetBufferMemoryRequirements says, or a type the buffer may not be in -
or it is bound already.

**BEHAVIOR**

The buffer's bytes are the block's from `offset` on, for as long as
both last; what the program writes there through MapMemory is what the
queue reads.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The block stays the caller's to free, after the buffer is no longer in
use.

**NOTES**

Several buffers may be bound into one block side by side.

**BUGS**

None known.

**SEE ALSO**

`GetBufferMemoryRequirements`, `AllocateMemory`

**EXAMPLES**

```zig
if (fb.BindBufferMemory(device, vertices, memory, 0) != .success) return error.NoBind;
```

## BindImageMemory

The image bound into a block of memory, at an offset.

**SYNOPSIS**

```zig
fn BindImageMemory(base: *FacetBase, device: *facet.Device, image: *facet.Image, memory: *facet.DeviceMemory, offset: u64) facet.Result
```

**SINCE**

1.0. LVO -104.

**INPUTS**

- `device` - the device both are of.
- `image` - an image not yet bound.
- `memory` - the block.
- `offset` - where in it the image starts.

**RESULT**

`success`; `error_out_of_device_memory` when the image does not fit
there - past the block's end, the offset not aligned as
GetImageMemoryRequirements says, or a type the image may not be in -
or it is bound already, as a swapchain's image always is.

**BEHAVIOR**

The image's texels are the block's from `offset` on, for as long as
both last, undefined until something is copied or drawn into them.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The block stays the caller's to free, after the image is no longer in
use.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`GetImageMemoryRequirements`, `AllocateMemory`, `CreateImageView`

**EXAMPLES**

```zig
if (fb.BindImageMemory(device, picture, memory, 0) != .success) return error.NoBind;
```

## CmdBeginQuery

Recorded: query `query` of `pool` begun - what the draws and the dispatches until `CmdEndQuery` come to is counted into it.

**SYNOPSIS**

```zig
fn CmdBeginQuery(base: *FacetBase, buffer: *facet.CommandBuffer, pool: *facet.QueryPool, query: u32, flags: u32) void
```

**SINCE**

1.29. LVO -468.

**INPUTS**

- `buffer` - a command buffer recording.
- `pool` - an occlusion or a statistics pool; a timestamp pool has
  nothing to begin and the command is left out of the frame, said in
  the log.
- `query` - which query of it; one past its last is left out the same
  way.
- `flags` - `QUERY_CONTROL_PRECISE`, which changes nothing: every
  sample is counted either way.

**RESULT**

None.

**BEHAVIOR**

An occlusion query counts the samples that passed the depth and the
stencil test and were not dropped by the fragment function; a statistics
query counts what each stage was given and handed on, one value for each
statistic the pool was made with.

What is counted is added to what the query holds, so a query begun and
ended twice over without a reset in between holds the sum. One begun
while another of the same pool is being counted into takes its place:
commands are played one after another, and the library counts into one
query at a time.

The pixels of a render pass are shaded when its tiles are drawn, at the
end of the pass: a query begun and ended inside a pass counts the draws
between them, and the count lands when the pass does.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The pool has to last until the work is done.

**NOTES**

Vulkan's rule that a query is reset before it is used holds here too:
a pool is made counting nothing, and `CmdResetQueryPool` puts it back.

**BUGS**

None known.

**SEE ALSO**

`CmdEndQuery`, `CmdResetQueryPool`, `CreateQueryPool`

**EXAMPLES**

```zig
fb.CmdBeginQuery(commands, counted, 0, 0);
fb.CmdDrawIndexed(commands, indices.len, 1, 0, 0, 0);
fb.CmdEndQuery(commands, counted, 0);
```

## CmdBeginRenderPass

Recorded: a render pass begun, drawing into a framebuffer.

**SYNOPSIS**

```zig
fn CmdBeginRenderPass(base: *FacetBase, buffer: *facet.CommandBuffer, info: *const facet.RenderPassBeginInfo, contents: facet.SubpassContents) void
```

**SINCE**

1.0. LVO -276.

**INPUTS**

- `buffer` - a command buffer recording.
- `info` - the render pass, the framebuffer, the rectangle drawn in, and
  the clear values: one for each attachment, in their order, up to the
  last that is cleared.
- `contents` - `inline`: the draws are recorded in this buffer.

**RESULT**

None.

**BEHAVIOR**

Played, the rasterizer's frame begins over the render area of the
framebuffer's colour attachment, cut to the framebuffer: cleared to the
colour attachment's clear value where its load op is CLEAR, else kept,
and with the stencil cleared to the depth attachment's, 0 where it has
none, and with the depth cleared to the depth attachment's - 1.0 where it has
none - as each tile starts. The draws until CmdEndRenderPass are
gathered; the tiles are drawn and stored when it ends. A pass begun in
another ends it first.

The tiles keep 8 bits a channel whatever the colour attachment's
format, and are drawn and blended so. Stored into R5G6B5 they are
dithered, 4 x 4 ordered over the image's pixels; kept from one, a pixel
is read as the least colour that packs to it again, so that what no
draw covers is stored as it was.

A pass whose framebuffer's colour image is not bound draws nothing.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The clear values are copied as the command is recorded. The render
pass, the framebuffer and its views have to last until the work is
done.

**NOTES**

Draws are recorded between CmdBeginRenderPass and CmdEndRenderPass; a
draw recorded outside a pass draws nothing. The pass begins with its first
subpass: CmdNextSubpass goes on to the next.

**BUGS**

None known.

**SEE ALSO**

`CmdEndRenderPass`, `CreateRenderPass`, `CreateFramebuffer`

**EXAMPLES**

```zig
const clear = facet.ClearValue{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } };
fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass.?, .framebuffer = frame.?, .render_area = .{ .extent = .{ .width = 800, .height = 600 } }, .clear_value_count = 1, .clear_values = @ptrCast(&clear) }, .@"inline");
```

## CmdBindDescriptorSets

Recorded: descriptor sets bound, from set `first_set` on.

**SYNOPSIS**

```zig
fn CmdBindDescriptorSets(base: *FacetBase, buffer: *facet.CommandBuffer, bind_point: facet.PipelineBindPoint, layout: *facet.PipelineLayout, first_set: u32, count: u32, sets: [*]const *facet.DescriptorSet, dynamic_offset_count: u32, dynamic_offsets: ?[*]const u32) void
```

**SINCE**

1.0. LVO -296.

**INPUTS**

- `buffer` - a command buffer recording.
- `bind_point` - `graphics`; nothing is recorded for another.
- `layout` - the pipeline layout the sets are bound for.
- `first_set`, `count`, `sets` - the sets, from set `first_set` on.
- `dynamic_offset_count`, `dynamic_offsets` - one offset in bytes for
  each dynamic buffer descriptor of the sets bound, in the order the
  sets, their bindings and the elements of each run; null and 0 where
  there is none. Offsets past what the sets want are left alone, and a
  descriptor whose offset is missing is read from where it was written
  (since 1.35, `PhysicalDeviceFeatures.dynamic_descriptors`).

**RESULT**

None.

**BEHAVIOR**

The draws after it read the sets as `Resources.sets`, as they hold them
when the draws run. Sets past the fourth are not bound.

A `uniform_buffer_dynamic` or a `storage_buffer_dynamic` reads its
buffer from the offset given here, past the one its write gave, and
what is left of the range from there is what a function may read
(`shader.Resources.buffer`, and `bufferAt` for an element past the
first). The offsets are the binding's, not the set's: binding the same
set again with others is how one set serves draw after draw, each with
a range of its own.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The sets have to last until the work is done.

**NOTES**

Every pipeline layout reads set `n` the same way, so a set stays bound
across pipelines. A set holds at most
`PhysicalDeviceLimits.max_descriptor_set_dynamic_buffers` dynamic
buffer descriptors, which CreateDescriptorSetLayout holds it to.

**BUGS**

None known.

**SEE ALSO**

`AllocateDescriptorSets`, `UpdateDescriptorSets`, `CmdDraw`

**EXAMPLES**

```zig
fb.CmdBindDescriptorSets(commands, .graphics, layout.?, 0, 1, @ptrCast(&set), 0, null);
// The same set again, its one dynamic buffer read from 256 bytes in:
const offsets = [1]u32{256};
fb.CmdBindDescriptorSets(commands, .graphics, layout.?, 0, 1, @ptrCast(&set), 1, &offsets);
```

## CmdBindIndexBuffer

Recorded: the index buffer CmdDrawIndexed reads.

**SYNOPSIS**

```zig
fn CmdBindIndexBuffer(base: *FacetBase, buffer: *facet.CommandBuffer, index_buffer: *facet.Buffer, offset: u64, index_type: facet.IndexType) void
```

**SINCE**

1.0. LVO -292.

**INPUTS**

- `buffer` - a command buffer recording.
- `index_buffer` - the buffer.
- `offset` - where the indices start in it.
- `index_type` - `uint16` or `uint32`.

**RESULT**

None.

**BEHAVIOR**

An indexed draw reads its indices from here; one past the buffer's end
names no vertex, and leaves its triangle out.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The buffer has to last until the work is done.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CmdDrawIndexed`, `CmdBindVertexBuffers`

**EXAMPLES**

```zig
fb.CmdBindIndexBuffer(commands, indices.?, 0, .uint16);
```

## CmdBindPipeline

Recorded: the pipeline the draws after it draw with.

**SYNOPSIS**

```zig
fn CmdBindPipeline(base: *FacetBase, buffer: *facet.CommandBuffer, bind_point: facet.PipelineBindPoint, pipeline: *facet.Pipeline) void
```

**SINCE**

1.0. LVO -284.

**INPUTS**

- `buffer` - a command buffer recording.
- `bind_point` - `graphics`; nothing is recorded for another.
- `pipeline` - a graphics pipeline.

**RESULT**

None.

**BEHAVIOR**

The pipeline stays bound until another is, or the command buffer ends.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The pipeline has to last until the work is done.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateGraphicsPipelines`, `CmdDraw`

**EXAMPLES**

```zig
fb.CmdBindPipeline(commands, .graphics, pipeline.?);
```

## CmdBindVertexBuffers

Recorded: vertex buffers bound, from binding `first_binding` on.

**SYNOPSIS**

```zig
fn CmdBindVertexBuffers(base: *FacetBase, buffer: *facet.CommandBuffer, first_binding: u32, count: u32, buffers: [*]const *facet.Buffer, offsets: [*]const u64) void
```

**SINCE**

1.0. LVO -288.

**INPUTS**

- `buffer` - a command buffer recording.
- `first_binding` - the first binding bound.
- `count`, `buffers`, `offsets` - a buffer for each binding from it, and
  where its vertices start in it.

**RESULT**

None.

**BEHAVIOR**

A draw reads each attribute from its binding's buffer: a vertex's from
its offset, plus the binding's stride times the vertex, plus the
attribute's own offset. A value past the buffer's end is (0, 0, 0, 1).
Bindings past the fourth are not bound.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The arrays are copied as the command is recorded. The buffers have to
last until the work is done.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CmdDraw`, `CmdBindIndexBuffer`

**EXAMPLES**

```zig
const offset: u64 = 0;
fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertices), @ptrCast(&offset));
```

## CmdBlitImage

Recorded: a rectangle of an image drawn over one of another, scaled.

**SYNOPSIS**

```zig
fn CmdBlitImage(base: *FacetBase, buffer: *facet.CommandBuffer, source: *facet.Image, source_layout: facet.ImageLayout, destination: *facet.Image, destination_layout: facet.ImageLayout, region_count: u32, regions: [*]const facet.ImageBlit, filter: facet.Filter) void
```

**SINCE**

1.16. LVO -392.

**INPUTS**

- `buffer` - a command buffer recording.
- `source`, `destination` - images of colour, of any formats.
- `source_layout`, `destination_layout` - not looked at.
- `region_count`, `regions` - the rectangles: corners the other way round
  turn it round.
- `filter` - NEAREST or LINEAR.

**RESULT**

None.

**BEHAVIOR**

Outside a render pass. Colours go by way of 8 bits a channel, and are
rounded into the destination's format, not dithered. What falls outside
the destination is left out, and the source's edge is read beyond it.

A source kept in its blocks is read out of them, texel by texel (since
1.44), and one kept as floats is read and rounded the same way (since
1.45). Nothing here compresses or makes floats, so a destination that
keeps what it was given takes nothing, as Vulkan does not allow a
compressed one either.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

What is given is copied as the command is recorded; the images and buffers
have to last until it has been played.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CmdCopyImage`

**EXAMPLES**

```zig
fb.CmdBlitImage(commands, from.?, .general, to.?, .general, 1, @ptrCast(&region), .linear);
```

## CmdClearAttachments

Recorded: parts of a render pass's attachments cleared, in the middle of it.

**SYNOPSIS**

```zig
fn CmdClearAttachments(base: *FacetBase, buffer: *facet.CommandBuffer, attachment_count: u32, attachments: [*]const facet.ClearAttachment, rect_count: u32, rects: [*]const facet.ClearRect) void
```

**SINCE**

1.16. LVO -400.

**INPUTS**

- `buffer` - a command buffer recording.
- `attachment_count`, `attachments` - what to clear: IMAGE_ASPECT_COLOR for
  the colour attachment, and IMAGE_ASPECT_DEPTH and IMAGE_ASPECT_STENCIL.
- `rect_count`, `rects` - where: inside the render area.

**RESULT**

None.

**BEHAVIOR**

Inside a render pass, whatever draws there before or after it. The scissor
and the pipeline bound have no part in it, and nothing bound changes.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

What is given is copied as the command is recorded; the images and buffers
have to last until it has been played.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CmdBeginRenderPass`

**EXAMPLES**

```zig
fb.CmdClearAttachments(commands, 1, @ptrCast(&attachment), 1, @ptrCast(&rect));
```

## CmdClearColorImage

Recorded: an image's levels and layers set to a colour.

**SYNOPSIS**

```zig
fn CmdClearColorImage(base: *FacetBase, buffer: *facet.CommandBuffer, image: *facet.Image, layout: facet.ImageLayout, color: *const facet.ClearColorValue, range_count: u32, ranges: [*]const facet.ImageSubresourceRange) void
```

**SINCE**

1.27. LVO -444.

**INPUTS**

- `buffer` - a command buffer recording.
- `image` - the image cleared, which is not an attachment of the pass
  being recorded: this is a transfer, not a draw.
- `layout` - what the image is in, which this library does not act on.
- `color` - the colour, as `float32`: 0 to 1 a channel for a format of
  bytes, and since 1.61 whatever it says for a float one. An image of
  whole numbers reads `uint32` instead, or `int32` where its format is
  signed, as Vulkan has it (since 1.70).
- `range_count`, `ranges` - which levels and layers, by
  `base_mip_level`, `level_count`, `base_array_layer` and `layer_count`;
  `facet.REMAINING`, which both counts default to, reaches to the end.

**RESULT**

None.

**BEHAVIOR**

Every texel of each level and layer named is set to the colour. A level
or a layer the image does not have is left out. An image whose format
this cannot write a single texel of is left out and said to be in the
log: a compressed one, whose texels are written as whole blocks and
which nothing here compresses, and a depth one, which
`CmdClearDepthStencilImage` writes instead.

**A float image takes the channels as they were given** since 1.61
(`PhysicalDeviceFeatures.kept_floats`): the four floats are put into
the format's own texel the way a copy of one would be, so a channel
above 1 or below 0 goes in as far as the format reaches instead of
being rounded to a byte. Before 1.61 such an image was the one this
could not write and was left alone.

Whole levels are written, so the clear does not care how a level's
texels are laid out in memory: every one of them takes the same value.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The ranges are copied as the command is recorded. The image has to last
until the work is done.

**NOTES**

This is how a texture is cleared without a render pass over it, which
before wanted an attachment, a framebuffer and a pass of its own.

**BUGS**

None known.

**SEE ALSO**

`CmdClearAttachments` for an attachment of the pass being drawn,
`CmdFillBuffer`

**EXAMPLES**

```zig
const color = facet.ClearColorValue{ .float32 = .{ 0, 0, 0, 1 } };
const range = facet.ImageSubresourceRange{};
fb.CmdClearColorImage(commands, texture.?, .transfer_dst_optimal, &color, 1, @ptrCast(&range));
```

## CmdClearDepthStencilImage

Recorded: a depth image's pixels set to a depth.

**SYNOPSIS**

```zig
fn CmdClearDepthStencilImage(base: *FacetBase, buffer: *facet.CommandBuffer, image: *facet.Image, layout: u32, value: *const facet.ClearDepthStencilValue, range_count: u32, ranges: [*]const facet.ImageSubresourceRange) void
```

**SINCE**

1.30. LVO -488.

**INPUTS**

- `buffer` - a command buffer recording.
- `image` - the image cleared, a depth attachment's of `d16_unorm`,
  `s8_uint` or `d16_unorm_s8_uint`, which is not an attachment of the
  pass being recorded: this is a transfer, not a draw.
- `layout` - what the image is in, which this library does not act on.
- `value` - the depth, 0 to 1, as the tiles hold one: 0 nearest, and
  the stencil, a byte, for a format that holds one (since 1.38).
- `range_count`, `ranges` - which levels and layers, by
  `base_mip_level`, `level_count`, `base_array_layer` and `layer_count`,
  and which of the two the range's `aspect_mask` asks for: a format
  that holds both has each cleared on its own. A range past the levels
  or the layers the image has is left out; such an image has had
  layers since 1.58 and levels since 1.63, each level's own rows
  cleared over the level's own size.

**RESULT**

None.

**BEHAVIOR**

Every pixel of the image is set to the depth, to the stencil, or to
both, as the range's aspects say and as the format holds. What the
aspects leave out is left as it is: the depth of a `d16_unorm_s8_uint`
image whose stencil alone was cleared still says what the pass stored.
An image this cannot write - one that is not a depth attachment's - is
left out of the frame and said to be in the log.

A transient depth image is left alone: its pixels live in the tiles and
there is nothing in memory to clear, which the render pass does as each
tile starts. It is not an error.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The ranges are copied as the command is recorded. The image has to last
until the work is done.

**NOTES**

This is for a depth or stencil image a render pass stores into
(`PhysicalDeviceFeatures.stored_depth`, `stored_stencil`): it is how
one is put back to the furthest depth, or to a stencil of its own,
without a pass over it. Where the pass clears its attachment itself
there is nothing for this to do.

**BUGS**

None known.

**SEE ALSO**

`CmdClearColorImage`, `CmdClearAttachments`, `CreateRenderPass`

**EXAMPLES**

```zig
const value = facet.ClearDepthStencilValue{ .depth = 1 };
const range = facet.ImageSubresourceRange{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH };
fb.CmdClearDepthStencilImage(commands, depth.?, 0, &value, 1, @ptrCast(&range));
```

## CmdCopyBuffer

Recorded: bytes copied from one buffer to another.

**SYNOPSIS**

```zig
fn CmdCopyBuffer(base: *FacetBase, buffer: *facet.CommandBuffer, source: *facet.Buffer, destination: *facet.Buffer, region_count: u32, regions: [*]const facet.BufferCopy) void
```

**SINCE**

1.0. LVO -160.

**INPUTS**

- `buffer` - a command buffer recording.
- `source` - the buffer copied from.
- `destination` - the buffer copied into.
- `region_count`, `regions` - where in each, and how many bytes.

**RESULT**

None.

**BEHAVIOR**

Played, a region that lies past the end of either buffer is left out.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The regions are copied as the command is recorded. The buffers have to
last until the work is done.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CmdCopyBufferToImage`

**EXAMPLES**

```zig
const region = facet.BufferCopy{ .size = bytes };
fb.CmdCopyBuffer(commands, staging.?, vertices.?, 1, @ptrCast(&region));
```

## CmdCopyBufferToImage

Recorded: rectangles of texels copied from a buffer into an image.

**SYNOPSIS**

```zig
fn CmdCopyBufferToImage(base: *FacetBase, buffer: *facet.CommandBuffer, source: *facet.Buffer, image: *facet.Image, layout: facet.ImageLayout, region_count: u32, regions: [*]const facet.BufferImageCopy) void
```

**SINCE**

1.0. LVO -156.

**INPUTS**

- `buffer` - a command buffer recording.
- `source` - the buffer the texels are in, in rows, in the image's
  format.
- `image` - the image they go into: a texture, or rows.
- `layout` - the image's layout: TRANSFER_DST_OPTIMAL or GENERAL.
- `region_count`, `regions` - the rectangles: where each is in the
  buffer, and which level of the image and where in it.

**RESULT**

None.

**BEHAVIOR**

Played, each texel goes where the image keeps it: in a texture,
converted to its layout - into blocks, an 8888 texel spread, an R8G8B8A8
one put in the order the rasterizer keeps colours in - and in rows,
copied as it is. What lies outside the level, or past the end of the
buffer, is left out. A depth attachment takes nothing.

An image of a compressed format kept in its blocks
(`PhysicalDeviceFeatures.kept_compressed`, since 1.44) takes them as
they lie, nothing decoded: the buffer holds a row of blocks every
`buffer_row_length` texels, as Vulkan counts them, and the offsets are
on a multiple of 4 or the region is left out. One that is unpacked
instead takes the texels decoded. A float image kept as its floats
(`kept_floats`, since 1.45) takes them as they lie too, a texel at a
time; one that is unpacked takes them rounded to 8 bits a channel.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The regions are copied as the command is recorded. The buffer and the
image have to last until the work is done.

**NOTES**

Each level of a texture is a copy of its own: the library makes no levels.

**BUGS**

None known.

**SEE ALSO**

`CmdPipelineBarrier`, `CreateImage`

**EXAMPLES**

```zig
const region = facet.BufferImageCopy{ .image_extent = .{ .width = 256, .height = 256 } };
fb.CmdCopyBufferToImage(commands, staging.?, picture.?, .transfer_dst_optimal, 1, @ptrCast(&region));
```

## CmdCopyImage

Recorded: a rectangle of texels copied from one image to another, as they are.

**SYNOPSIS**

```zig
fn CmdCopyImage(base: *FacetBase, buffer: *facet.CommandBuffer, source: *facet.Image, source_layout: facet.ImageLayout, destination: *facet.Image, destination_layout: facet.ImageLayout, region_count: u32, regions: [*]const facet.ImageCopy) void
```

**SINCE**

1.16. LVO -388.

**INPUTS**

- `buffer` - a command buffer recording.
- `source`, `destination` - images of the same size of texel, whatever their
  formats: the bytes go as they are.
- `source_layout`, `destination_layout` - not looked at.
- `region_count`, `regions` - the rectangles.

**RESULT**

None.

**BEHAVIOR**

Outside a render pass. The part of a rectangle outside either image is
left out, and so are images of depth or stencil, which live in the tiles.

Two images that keep their blocks, of the one format, are copied block by
block (`PhysicalDeviceFeatures.kept_compressed`, since 1.44), their
offsets on a multiple of 4; a compressed image and an uncompressed one,
either way round, take nothing. Two that keep their floats, of the one
format, are copied texel by texel as they lie (`kept_floats`, since
1.45), and a float image beside one of another kind takes nothing.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

What is given is copied as the command is recorded; the images and buffers
have to last until it has been played.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CmdBlitImage`, `CmdCopyImageToBuffer`, `CmdCopyBufferToImage`

**EXAMPLES**

```zig
fb.CmdCopyImage(commands, from.?, .general, to.?, .general, 1, @ptrCast(&facet.ImageCopy{ .extent = .{ .width = 64, .height = 64 } }));
```

## CmdCopyImageToBuffer

Recorded: a rectangle of texels copied from an image to a buffer.

**SYNOPSIS**

```zig
fn CmdCopyImageToBuffer(base: *FacetBase, buffer: *facet.CommandBuffer, image: *facet.Image, image_layout: facet.ImageLayout, destination: *facet.Buffer, region_count: u32, regions: [*]const facet.BufferImageCopy) void
```

**SINCE**

1.16. LVO -396.

**INPUTS**

- `buffer` - a command buffer recording.
- `image` - an image of colour.
- `image_layout` - not looked at.
- `destination` - the buffer.
- `region_count`, `regions` - the rectangles.

**RESULT**

None.

**BEHAVIOR**

Outside a render pass. In the buffer the texels are in rows, in the image's
format. The part of a rectangle outside the image, or past the buffer's
end, is left out.

An image kept in its blocks gives them back as they lie, a row of them
every `buffer_row_length` texels, its offsets on a multiple of 4
(`PhysicalDeviceFeatures.kept_compressed`, since 1.44). A float image
kept as its floats gives its texels back the same way (`kept_floats`,
since 1.45). One that was unpacked as it was copied in, either kind,
has nothing of its format to give and takes nothing.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

What is given is copied as the command is recorded; the images and buffers
have to last until it has been played.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CmdCopyBufferToImage`, `CmdCopyImage`

**EXAMPLES**

```zig
fb.CmdCopyImageToBuffer(commands, picture.?, .general, readback.?, 1, @ptrCast(&region));
```

## CmdCopyQueryPoolResults

Recorded: what `count` queries from `first` counted, written into a buffer as `GetQueryPoolResults` writes it into memory.

**SYNOPSIS**

```zig
fn CmdCopyQueryPoolResults(base: *FacetBase, buffer: *facet.CommandBuffer, pool: *facet.QueryPool, first: u32, count: u32, destination: *facet.Buffer, offset: u64, stride: u64, flags: u32) void
```

**SINCE**

1.29. LVO -484.

**INPUTS**

- `buffer` - a command buffer recording.
- `pool`, `first`, `count` - the queries read.
- `destination`, `offset` - the buffer written and where in it.
- `stride` - the bytes from one query's values to the next.
- `flags` - as `GetQueryPoolResults` takes them, `QUERY_RESULT_WAIT`
  apart: the commands are played in order, so a query ended before this
  one is already written.

**RESULT**

None.

**BEHAVIOR**

Played, a copy whose values would lie past the end of the buffer is left
out and said to be in the log, as every command that will not fit is.
A query that is not available writes nothing unless `QUERY_RESULT_PARTIAL`
says to write what it has counted so far, and
`QUERY_RESULT_WITH_AVAILABILITY` puts a value after each query's saying
which it was.

`QUERY_RESULT_WAIT` is passed over: a value this command reads was
written by a command before it, which is finished by the time this one
is played.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The pool and the buffer have to last until the work is done.

**NOTES**

This is how a program keeps what a frame counted without waiting for it:
the values go into a buffer it reads when it pleases.

**BUGS**

None known.

**SEE ALSO**

`GetQueryPoolResults`, `CmdEndQuery`

**EXAMPLES**

```zig
fb.CmdCopyQueryPoolResults(commands, counted, 0, 1, readings, 0, 8, facet.QUERY_RESULT_64);
```

## CmdDispatch

Recorded: the compute function bound run, for each of the groups.

**SYNOPSIS**

```zig
fn CmdDispatch(base: *FacetBase, buffer: *facet.CommandBuffer, x: u32, y: u32, z: u32) void
```

**SINCE**

1.18. LVO -420.

**INPUTS**

- `buffer` - a command buffer recording, outside a render pass.
- `x`, `y`, `z` - how many groups along each axis.

**RESULT**

None.

**BEHAVIOR**

The function of the pipeline bound with `PipelineBindPoint.compute` is
called once for each group, given the descriptor sets bound for compute and
the push constants. What it writes is there for the commands after it. It
runs on the cores, the groups in no order and shared between them; the
dispatch ends when all are done. In a render pass it does nothing.

A group holds as many invocations as the function's entry declared
(`shader.computeGroup`), which the call is given in
`shader.Groups.local`: the function makes them itself, so one call runs
them all, one after the other, in whatever order it chooses. What they
share is `shader.Groups.shared`, as many bytes as the entry asked for,
found once for each worker of the dispatch and given back as it ends: a
group has it to itself while it runs, cleared for the first group a worker
takes and holding what the group before it left after that. Memory the
library could not find leaves `shared` null.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

None.

**NOTES**

Barriers are taken and need do nothing: the cores run a command at a time.

**BUGS**

None known.

**SEE ALSO**

`CreateComputePipelines`, `CmdDispatchIndirect`, `CmdBindDescriptorSets`,
`shader.computeGroup`

**EXAMPLES**

```zig
fb.CmdDispatch(commands, 16, 1, 1);
```

## CmdDispatchIndirect

Recorded: as CmdDispatch, its numbers in a buffer.

**SYNOPSIS**

```zig
fn CmdDispatchIndirect(base: *FacetBase, buffer: *facet.CommandBuffer, numbers: *facet.Buffer, offset: u64) void
```

**SINCE**

1.18. LVO -424.

**INPUTS**

- `buffer` - a command buffer recording, outside a render pass.
- `numbers` - the buffer they are in, a `facet.DispatchIndirectCommand`.
- `offset` - where.

**RESULT**

None.

**BEHAVIOR**

As `CmdDispatch`, with the numbers read as the command is played. If the
buffer ends before them, it does nothing.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

`numbers` has to last until the work recorded is done.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CmdDispatch`, `CmdDrawIndirect`

**EXAMPLES**

```zig
fb.CmdDispatchIndirect(commands, numbers, 0);
```

## CmdDraw

Recorded: vertices drawn, in the order they are in the vertex buffers.

**SYNOPSIS**

```zig
fn CmdDraw(base: *FacetBase, buffer: *facet.CommandBuffer, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void
```

**SINCE**

1.0. LVO -312.

**INPUTS**

- `buffer` - a command buffer recording, inside a render pass.
- `vertex_count` - how many vertices.
- `instance_count` - how many times they are drawn.
- `first_vertex` - the first: the vertices are it and those after it.
- `first_instance` - the first instance's number.

**RESULT**

None, but a `vertex_count` of more vertices than a draw works is not
recorded, and `EndCommandBuffer` then answers `error_feature_not_present`.

**BEHAVIOR**

Played inside a render pass, the vertices the draw names - from the
lowest to the highest - are read from the vertex buffers and given to
the pipeline's vertex function, in one batch for each instance; the
triangles are put together from them as the pipeline's topology says,
clipped, culled and set up, and gathered on the tiles they touch. The
fragment function colours them as the pass ends. A draw outside a render
pass, or without a pipeline bound, draws nothing.

A `vertex_count` of more than 1 048 576 is more than either device works,
and is refused as it is recorded. CmdDrawIndexed cannot be refused the
same way: what its indices reach is not known until it is played, so a
draw whose lowest index to highest spans more than that is left out of
the frame, with a line in the log and nothing said to the program.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

None.

**NOTES**

The vertex function is given each vertex's number and the instance's,
as Vulkan's vertex and instance indices.

**BUGS**

None known.

**SEE ALSO**

`CmdDrawIndexed`, `CmdBindPipeline`, `CmdBindVertexBuffers`

**EXAMPLES**

```zig
fb.CmdDraw(commands, 36, 1, 0, 0);
```

## CmdDrawIndexed

Recorded: vertices drawn in the order the index buffer gives them.

**SYNOPSIS**

```zig
fn CmdDrawIndexed(base: *FacetBase, buffer: *facet.CommandBuffer, index_count: u32, instance_count: u32, first_index: u32, vertex_offset: i32, first_instance: u32) void
```

**SINCE**

1.0. LVO -316.

**INPUTS**

- `buffer` - a command buffer recording, inside a render pass.
- `index_count` - how many indices.
- `instance_count` - how many times they are drawn.
- `first_index` - the first index read from the index buffer.
- `vertex_offset` - added to each index for its vertex.
- `first_instance` - the first instance's number.

**RESULT**

None.

**BEHAVIOR**

Played inside a render pass, the vertices the draw names - from the
lowest to the highest - are read from the vertex buffers and given to
the pipeline's vertex function, in one batch for each instance; the
triangles are put together from them as the pipeline's topology says,
clipped, culled and set up, and gathered on the tiles they touch. The
fragment function colours them as the pass ends. A draw outside a render
pass, or without a pipeline bound, draws nothing.

An index past the index buffer's end, or naming a vertex below 0, leaves
its triangle out.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

None.

**NOTES**

A shared vertex is worked once for each instance however many triangles
name it.

**BUGS**

None known.

**SEE ALSO**

`CmdDraw`, `CmdBindIndexBuffer`, `CmdBindPipeline`

**EXAMPLES**

```zig
fb.CmdDrawIndexed(commands, 36, 1, 0, 0, 0);
```

## CmdDrawIndexedIndirect

Recorded: draws whose numbers, as CmdDrawIndexed takes them, are in a buffer.

**SYNOPSIS**

```zig
fn CmdDrawIndexedIndirect(base: *FacetBase, buffer: *facet.CommandBuffer, numbers: *facet.Buffer, offset: u64, draw_count: u32, stride: u32) void
```

**SINCE**

1.17. LVO -408.

**INPUTS**

- `buffer` - a command buffer recording, in a render pass.
- `numbers` - the buffer they are in.
- `offset` - where the first draw's are.
- `draw_count` - how many draws.
- `stride` - the bytes from one draw's to the next: `facet.DrawIndexedIndirectCommand`'s at
  least, unless there is one draw at most.

**RESULT**

None.

**BEHAVIOR**

The numbers are read as the command is played, not as it is recorded, so
a program may write them after recording, up to the submission, and a
compute function played before it may too. Each draw is as `CmdDrawIndexed` with
those numbers. The draws past the end of the buffer are left out, and with
a `stride` too small nothing is recorded.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

`numbers` has to last until the work recorded is done.

**NOTES**

The cores read the numbers, whichever device draws.

**BUGS**

None known.

**SEE ALSO**

`CmdDrawIndexed`, `CmdDispatchIndirect`

**EXAMPLES**

```zig
fb.CmdDrawIndexedIndirect(commands, numbers, 0, 2, @sizeOf(facet.DrawIndexedIndirectCommand));
```

## CmdDrawIndirect

Recorded: draws whose numbers, as CmdDraw takes them, are in a buffer.

**SYNOPSIS**

```zig
fn CmdDrawIndirect(base: *FacetBase, buffer: *facet.CommandBuffer, numbers: *facet.Buffer, offset: u64, draw_count: u32, stride: u32) void
```

**SINCE**

1.17. LVO -404.

**INPUTS**

- `buffer` - a command buffer recording, in a render pass.
- `numbers` - the buffer they are in.
- `offset` - where the first draw's are.
- `draw_count` - how many draws.
- `stride` - the bytes from one draw's to the next: `facet.DrawIndirectCommand`'s at
  least, unless there is one draw at most.

**RESULT**

None.

**BEHAVIOR**

The numbers are read as the command is played, not as it is recorded, so
a program may write them after recording, up to the submission, and a
compute function played before it may too. Each draw is as `CmdDraw` with
those numbers. The draws past the end of the buffer are left out, and with
a `stride` too small nothing is recorded.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

`numbers` has to last until the work recorded is done.

**NOTES**

The cores read the numbers, whichever device draws.

**BUGS**

None known.

**SEE ALSO**

`CmdDraw`, `CmdDispatchIndirect`

**EXAMPLES**

```zig
fb.CmdDrawIndirect(commands, numbers, 0, 2, @sizeOf(facet.DrawIndirectCommand));
```

## CmdEndQuery

Recorded: the query ended - nothing after it is counted into it - and what it counted made available.

**SYNOPSIS**

```zig
fn CmdEndQuery(base: *FacetBase, buffer: *facet.CommandBuffer, pool: *facet.QueryPool, query: u32) void
```

**SINCE**

1.29. LVO -472.

**INPUTS**

- `buffer` - a command buffer recording.
- `pool`, `query` - the query `CmdBeginQuery` begun.

**RESULT**

None.

**BEHAVIOR**

The query is available from then on, which is what
`GetQueryPoolResults` answers `success` for. Its value is whole once the
submission is done: the pixels a pass shaded are counted while its tiles
are drawn, which is after the command that ended the query if the query
was ended inside the pass.

An end without a begin, or of another query than the one being counted
into, makes the query available with what it holds.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The pool has to last until the work is done.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CmdBeginQuery`, `GetQueryPoolResults`

**EXAMPLES**

```zig
fb.CmdEndQuery(commands, counted, 0);
```

## CmdEndRenderPass

Recorded: the render pass ended, and what it drew stored.

**SYNOPSIS**

```zig
fn CmdEndRenderPass(base: *FacetBase, buffer: *facet.CommandBuffer) void
```

**SINCE**

1.0. LVO -280.

**INPUTS**

- `buffer` - a command buffer recording, inside a render pass.

**RESULT**

None.

**BEHAVIOR**

Played, the tiles the draws touched are drawn - shared out between the
cores - and stored into the colour attachment; with a CLEAR load op the
whole render area is.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

None.

**NOTES**

This is where the work of a frame is done: the draws only gather it.

**BUGS**

None known.

**SEE ALSO**

`CmdBeginRenderPass`

**EXAMPLES**

```zig
fb.CmdEndRenderPass(commands);
```

## CmdExecuteCommands

Recorded: secondary command buffers played, in the order given.

**SYNOPSIS**

```zig
fn CmdExecuteCommands(base: *FacetBase, buffer: *facet.CommandBuffer, count: u32, secondaries: [*]const *facet.CommandBuffer) void
```

**SINCE**

1.17. LVO -412.

**INPUTS**

- `buffer` - a primary command buffer recording.
- `count`, `secondaries` - command buffers allocated with
  `CommandBufferLevel.secondary`, recorded and ended.

**RESULT**

None.

**BEHAVIOR**

Their commands are played where this command stands, inside or outside
a render pass, into the pass that is begun there. In a secondary command
buffer it does nothing, nor does a buffer given that is primary or not
ended count: it is left out.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The secondaries have to last, and stay as they are, until the work recorded is done.

**NOTES**

Vulkan leaves what a secondary finds bound undefined, and what the primary finds after it: here each goes on from what the last left. A program written for Vulkan binds what it uses, and that works.

**BUGS**

None known.

**SEE ALSO**

`AllocateCommandBuffers`, `BeginCommandBuffer`, `QueueSubmit`

**EXAMPLES**

```zig
fb.CmdExecuteCommands(primary, 1, @ptrCast(&secondary));
```

## CmdFillBuffer

Recorded: a run of a buffer set to one value, four bytes at a time.

**SYNOPSIS**

```zig
fn CmdFillBuffer(base: *FacetBase, buffer: *facet.CommandBuffer, destination: *facet.Buffer, offset: u64, size: u64, data: u32) void
```

**SINCE**

1.27. LVO -436.

**INPUTS**

- `buffer` - a command buffer recording.
- `destination` - the buffer written.
- `offset` - where the run starts, a multiple of four.
- `size` - how many bytes, a multiple of four, or `facet.WHOLE_SIZE`
  for the rest of the buffer from `offset`.
- `data` - the four bytes written over and over, as they lie in memory:
  the low byte first.

**RESULT**

None.

**BEHAVIOR**

Played, a run that lies past the end of the buffer is left out and said
to be in the log. An `offset` or a `size` that is not a multiple of four
is rounded down to one, as Vulkan asks of the program instead.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The buffer has to last until the work is done.

**NOTES**

What `CmdUpdateBuffer` is for one run of bytes, this is for one value
repeated: neither wants a staging buffer, a map or a submit of its own.

**BUGS**

None known.

**SEE ALSO**

`CmdUpdateBuffer`, `CmdCopyBuffer`, `CmdClearColorImage`

**EXAMPLES**

```zig
// Every index zeroed before the real ones are written.
fb.CmdFillBuffer(commands, indices.?, 0, facet.WHOLE_SIZE, 0);
```

## CmdNextSubpass

Recorded: what the subpass drew stored, and the next subpass begun.

**SYNOPSIS**

```zig
fn CmdNextSubpass(base: *FacetBase, buffer: *facet.CommandBuffer, contents: facet.SubpassContents) void
```

**SINCE**

1.21. LVO -428.

**INPUTS**

- `buffer` - a command buffer recording, inside a render pass of a further
  subpass.
- `contents` - whether the subpass's draws are in secondary command
  buffers. Not looked at: either may be played.

**RESULT**

None.

**BEHAVIOR**

A subpass with other attachments than the one before it is a pass of its
own: it stores what was drawn, and begins with the clear values
CmdBeginRenderPass was given. One with the same attachments goes on in the
same tiles, the depth with them, and only the pipelines it can bind differ.

Past the last subpass, or outside a pass, nothing is recorded. A pipeline
bound stays bound, though Vulkan would have one made for the subpass.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

None.

**NOTES**

A subpass of several colour attachments is played over for each of them from where it began, with what was bound then.

**BUGS**

None known.

**SEE ALSO**

`CmdBeginRenderPass`, `CmdEndRenderPass`, `CreateRenderPass`

**EXAMPLES**

```zig
fb.CmdNextSubpass(commands, .@"inline");
```

## CmdPipelineBarrier

Recorded: a barrier between the work before it and the work after.

**SYNOPSIS**

```zig
fn CmdPipelineBarrier(base: *FacetBase, buffer: *facet.CommandBuffer, src_stage_mask: u32, dst_stage_mask: u32, dependency_flags: u32, memory_barrier_count: u32, memory_barriers: ?[*]const facet.MemoryBarrier, buffer_barrier_count: u32, buffer_barriers: ?[*]const facet.BufferMemoryBarrier, image_barrier_count: u32, image_barriers: ?[*]const facet.ImageMemoryBarrier) void
```

**SINCE**

1.0. LVO -152.

**INPUTS**

- `buffer` - a command buffer recording.
- `src_stage_mask`, `dst_stage_mask` - the stages before and after
  (PIPELINE_STAGE_*).
- `dependency_flags` - 0.
- `memory_barrier_count`, `memory_barriers` - what memory is written
  before and read after.
- `buffer_barrier_count`, `buffer_barriers` - the same for buffers.
- `image_barrier_count`, `image_barriers` - the same for images, and
  the layouts they go from and to.

**RESULT**

None.

**BEHAVIOR**

A queue plays its commands one after the other, each finished before
the next starts, and a layout changes nothing in memory: the barrier
is kept in its place in the recording, and has nothing to wait for
when it is played. A program written for any device records it all
the same.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The arrays are the caller's, read during the call.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CmdCopyBufferToImage`, `QueueSubmit`

**EXAMPLES**

```zig
const barrier = facet.ImageMemoryBarrier{
    .dst_access_mask = facet.ACCESS_TRANSFER_WRITE,
    .old_layout = .undefined,
    .new_layout = .transfer_dst_optimal,
    .image = picture.?,
};
fb.CmdPipelineBarrier(commands, facet.PIPELINE_STAGE_TOP_OF_PIPE, facet.PIPELINE_STAGE_TRANSFER, 0, 0, null, 0, null, 1, @ptrCast(&barrier));
```

## CmdPushConstants

Recorded: bytes of push constants set.

**SYNOPSIS**

```zig
fn CmdPushConstants(base: *FacetBase, buffer: *facet.CommandBuffer, layout: *facet.PipelineLayout, stage_flags: u32, offset: u32, size: u32, values: *const anyopaque) void
```

**SINCE**

1.0. LVO -300.

**INPUTS**

- `buffer` - a command buffer recording.
- `layout` - the pipeline layout they are set for.
- `stage_flags` - the stages that read them.
- `offset`, `size` - which bytes, inside the first 128.
- `values` - `size` bytes.

**RESULT**

None.

**BEHAVIOR**

The draws after it read the push constants as `Resources.push`, every
stage the same bytes. Bytes not set are 0 as each command buffer
starts. A range past byte 128 is not recorded.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The bytes are copied as the command is recorded.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreatePipelineLayout`, `CmdDraw`

**EXAMPLES**

```zig
fb.CmdPushConstants(commands, layout.?, facet.SHADER_STAGE_VERTEX, 0, @sizeOf(Matrix), &transform);
```

## CmdResetQueryPool

Recorded: `count` queries from `first` set back to nothing counted and not available.

**SYNOPSIS**

```zig
fn CmdResetQueryPool(base: *FacetBase, buffer: *facet.CommandBuffer, pool: *facet.QueryPool, first: u32, count: u32) void
```

**SINCE**

1.29. LVO -476.

**INPUTS**

- `buffer` - a command buffer recording.
- `pool` - the pool.
- `first`, `count` - the queries reset; those past its last are left
  alone.

**RESULT**

None.

**BEHAVIOR**

Played in its turn, as every command is: a reset recorded before the
draws of a frame leaves the queries counting that frame alone, which is
how a frame loop reads one pool over and over.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The pool has to last until the work is done.

**NOTES**

A pool is made counting nothing, so the first frame needs no reset; the
ones after it do, and Vulkan asks for one before every use.

**BUGS**

None known.

**SEE ALSO**

`CmdBeginQuery`, `CreateQueryPool`

**EXAMPLES**

```zig
fb.CmdResetQueryPool(commands, counted, 0, 1);
```

## CmdSetBlendConstants

Recorded: the blend constants, for a pipeline that leaves them to commands.

**SYNOPSIS**

```zig
fn CmdSetBlendConstants(base: *FacetBase, buffer: *facet.CommandBuffer, constants: *const [4]f32) void
```

**SINCE**

1.12. LVO -368.

**INPUTS**

- `buffer` - a command buffer recording.
- `constants` - red, green, blue and alpha, 0 to 1.

**RESULT**

None.

**BEHAVIOR**

The draws after it with a pipeline whose blend constants are dynamic mix
by these, every colour attachment of the subpass by the one set, as in
Vulkan. It also forgets what CmdSetBlendConstantsAt set for any
attachment of its own (since 1.51).

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The constants are copied as the command is recorded.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CmdSetBlendConstantsAt`, `CreateGraphicsPipelines`

**EXAMPLES**

```zig
fb.CmdSetBlendConstants(commands, &.{ 1, 0.5, 0.25, 1 });
```

## CmdSetBlendConstantsAt

Recorded: one colour attachment's own blend constants, for a pipeline that leaves them to commands.

**SYNOPSIS**

```zig
fn CmdSetBlendConstantsAt(base: *FacetBase, buffer: *facet.CommandBuffer, attachment: u32, constants: *const [4]f32) void
```

**SINCE**

1.51. LVO -520.

**INPUTS**

- `buffer` - a command buffer recording.
- `attachment` - which colour attachment of the subpass, 0 to 3.
- `constants` - red, green, blue and alpha, 0 to 1.

**RESULT**

None.

**BEHAVIOR**

The draws after it with a pipeline whose blend constants are dynamic mix
that one colour attachment by these, and the others by whatever they had:
what CmdSetBlendConstants set over all of them, or their own set before.
facet.library's own, where Vulkan has the one set a pipeline shares
between its attachments - which matters where a subpass draws several
together and one fragment call writes them all
(SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER), there being no replay left to
set them between.

A later CmdSetBlendConstants sets the one set again over every
attachment, and forgets what this set for any of them. An `attachment`
past the subpass's does nothing.

The pipeline's own constants win where it has them
(`PipelineColorBlendStateCreateInfo.attachment_constants`,
`blend_constants`): a command sets only what a pipeline left to one.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The constants are copied as the command is recorded.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CmdSetBlendConstants`, `CreateGraphicsPipelines`, `CreateRenderPass`

**EXAMPLES**

```zig
// The second attachment of a G-buffer mixed by a constant of its own.
fb.CmdSetBlendConstantsAt(commands, 1, &.{ 0.25, 0.25, 0.25, 1 });
```

## CmdSetDepthBias

Recorded: the depth bias, for a pipeline that leaves it to commands.

**SYNOPSIS**

```zig
fn CmdSetDepthBias(base: *FacetBase, buffer: *facet.CommandBuffer, constant: f32, clamp: f32, slope: f32) void
```

**SINCE**

1.34. LVO -500.

**INPUTS**

- `buffer` - a command buffer recording.
- `constant` - how many of the smallest difference the depth
  attachment holds are added; 65535ths of the range for `d16_unorm`.
- `clamp` - the most of the depth range a triangle may be moved by,
  or the least where it is negative; 0 for no limit.
- `slope` - how much of the triangle's steepest slope is added, in
  depth over a pixel.

**RESULT**

None.

**BEHAVIOR**

The draws after it, with a pipeline whose depth bias is dynamic
(`DynamicState.depth_bias`) and whose `depth_bias_enable` is true, move
their triangles' depth by these before it is tested and written. A
pipeline that gave the numbers itself is not touched by this, and one
without `depth_bias_enable` adds nothing whatever is set here.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The three numbers are copied as the command is recorded.

**NOTES**

Only triangles are moved, as in Vulkan: points and lines, and triangles
drawn as their edges or corners, are drawn where they are. The bias is
worked out once a triangle, from the depth plane the rasterizer set up,
so it costs nothing a pixel.

**BUGS**

None known.

**SEE ALSO**

`CreateGraphicsPipelines`, `GetPhysicalDeviceFeatures`, `CmdSetBlendConstants`

**EXAMPLES**

```zig
// The decal lifted off the wall it is on: a unit of depth, and a
// little more where the wall is seen at an angle.
fb.CmdSetDepthBias(commands, 1, 0, 1.5);
```

## CmdSetDepthBounds

Recorded: the depth bounds, for a pipeline that leaves them to commands.

**SYNOPSIS**

```zig
fn CmdSetDepthBounds(base: *FacetBase, buffer: *facet.CommandBuffer, min: f32, max: f32) void
```

**SINCE**

1.40. LVO -516.

**INPUTS**

- `buffer` - a command buffer recording.
- `min`, `max` - the depths, 0 to 1, a pixel's **stored** depth has to
  lie between to be drawn; outside 0 to 1 they are held to it.

**RESULT**

None.

**BEHAVIOR**

The draws after it, with a pipeline whose depth bounds are dynamic
(`DynamicState.depth_bounds`) and whose `depth_bounds_test_enable` is
true, drop a pixel whose depth attachment holds a depth outside these.
It is the depth already there that is looked at, not the one being
drawn, and the test comes before the stencil's: a pixel the bounds drop
leaves the stencil as it is.

A pipeline that gave the numbers itself is not touched by this, and one
without `depth_bounds_test_enable` drops nothing whatever is set here.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The two numbers are copied as the command is recorded.

**NOTES**

`min` above `max` keeps nothing, as in Vulkan, and a pass whose depth
attachment is only in the tiles still has a depth to look at: the
clear's, where nothing was drawn. A draw whose bounds are tested is
drawn a pixel at a time, as one with a stencil test is, so it costs
more than the quads the fast paths walk.

**BUGS**

None known.

**SEE ALSO**

`CreateGraphicsPipelines`, `GetPhysicalDeviceFeatures`, `CmdSetDepthBias`

**EXAMPLES**

```zig
// The nearer half of the depth alone: a light's volume, drawn only
// where what is there is near enough to be lit.
fb.CmdSetDepthBounds(commands, 0, 0.5);
```

## CmdSetLineWidth

Recorded: the width of lines, for a pipeline that leaves it to commands.

**SYNOPSIS**

```zig
fn CmdSetLineWidth(base: *FacetBase, buffer: *facet.CommandBuffer, width: f32) void
```

**SINCE**

1.14. LVO -372.

**INPUTS**

- `buffer` - a command buffer recording.
- `width` - in pixels.

**RESULT**

None.

**BEHAVIOR**

The draws after it with a pipeline whose line width is dynamic draw their
lines this wide.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

None.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateGraphicsPipelines`

**EXAMPLES**

```zig
fb.CmdSetLineWidth(commands, 2);
```

## CmdSetScissor

Recorded: the scissor, for a pipeline that leaves it to commands.

**SYNOPSIS**

```zig
fn CmdSetScissor(base: *FacetBase, buffer: *facet.CommandBuffer, first_scissor: u32, count: u32, scissors: [*]const facet.Rect2D) void
```

**SINCE**

1.0. LVO -308.

**INPUTS**

- `buffer` - a command buffer recording.
- `first_scissor`, `count`, `scissors` - scissor 0, the one there is,
  and any after it, which are not looked at.

**RESULT**

None.

**BEHAVIOR**

The draws after it with a pipeline whose scissor is dynamic draw only
inside it, and inside the render area.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The scissor is copied as the command is recorded.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CmdSetViewport`, `CreateGraphicsPipelines`

**EXAMPLES**

```zig
fb.CmdSetScissor(commands, 0, 1, @ptrCast(&facet.Rect2D{ .extent = .{ .width = 800, .height = 600 } }));
```

## CmdSetStencilCompareMask

Recorded: the stencil test's compare mask, for a pipeline that leaves it to commands.

**SYNOPSIS**

```zig
fn CmdSetStencilCompareMask(base: *FacetBase, buffer: *facet.CommandBuffer, face_mask: u32, value: u32) void
```

**SINCE**

1.15. LVO -376.

**INPUTS**

- `buffer` - a command buffer recording.
- `face_mask` - the faces it is for: STENCIL_FACE_FRONT, STENCIL_FACE_BACK
  or STENCIL_FACE_FRONT_AND_BACK.
- `value` - its low 8 bits.

**RESULT**

None.

**BEHAVIOR**

The draws after it with a pipeline that leaves this to commands test
their stencil by it.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

None.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateGraphicsPipelines`

**EXAMPLES**

```zig
fb.CmdSetStencilCompareMask(commands, facet.STENCIL_FACE_FRONT_AND_BACK, 1);
```

## CmdSetStencilReference

Recorded: the stencil test's reference, for a pipeline that leaves it to commands.

**SYNOPSIS**

```zig
fn CmdSetStencilReference(base: *FacetBase, buffer: *facet.CommandBuffer, face_mask: u32, value: u32) void
```

**SINCE**

1.15. LVO -384.

**INPUTS**

- `buffer` - a command buffer recording.
- `face_mask` - the faces it is for: STENCIL_FACE_FRONT, STENCIL_FACE_BACK
  or STENCIL_FACE_FRONT_AND_BACK.
- `value` - its low 8 bits.

**RESULT**

None.

**BEHAVIOR**

The draws after it with a pipeline that leaves this to commands test
their stencil by it.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

None.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateGraphicsPipelines`

**EXAMPLES**

```zig
fb.CmdSetStencilReference(commands, facet.STENCIL_FACE_FRONT_AND_BACK, 1);
```

## CmdSetStencilWriteMask

Recorded: the stencil test's write mask, for a pipeline that leaves it to commands.

**SYNOPSIS**

```zig
fn CmdSetStencilWriteMask(base: *FacetBase, buffer: *facet.CommandBuffer, face_mask: u32, value: u32) void
```

**SINCE**

1.15. LVO -380.

**INPUTS**

- `buffer` - a command buffer recording.
- `face_mask` - the faces it is for: STENCIL_FACE_FRONT, STENCIL_FACE_BACK
  or STENCIL_FACE_FRONT_AND_BACK.
- `value` - its low 8 bits.

**RESULT**

None.

**BEHAVIOR**

The draws after it with a pipeline that leaves this to commands test
their stencil by it.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

None.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateGraphicsPipelines`

**EXAMPLES**

```zig
fb.CmdSetStencilWriteMask(commands, facet.STENCIL_FACE_FRONT_AND_BACK, 1);
```

## CmdSetViewport

Recorded: the viewport, for a pipeline that leaves it to commands.

**SYNOPSIS**

```zig
fn CmdSetViewport(base: *FacetBase, buffer: *facet.CommandBuffer, first_viewport: u32, count: u32, viewports: [*]const facet.Viewport) void
```

**SINCE**

1.0. LVO -304.

**INPUTS**

- `buffer` - a command buffer recording.
- `first_viewport`, `count`, `viewports` - viewport 0, the one there is,
  and any after it, which are not looked at.

**RESULT**

None.

**BEHAVIOR**

The draws after it with a pipeline whose viewport is dynamic draw
through it; a pipeline with a viewport of its own draws through that.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The viewport is copied as the command is recorded.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CmdSetScissor`, `CreateGraphicsPipelines`

**EXAMPLES**

```zig
fb.CmdSetViewport(commands, 0, 1, @ptrCast(&facet.Viewport{ .width = 800, .height = 600 }));
```

## CmdUpdateBuffer

Recorded: bytes written into a buffer, kept with the command.

**SYNOPSIS**

```zig
fn CmdUpdateBuffer(base: *FacetBase, buffer: *facet.CommandBuffer, destination: *facet.Buffer, offset: u64, size: u64, data: *const anyopaque) void
```

**SINCE**

1.27. LVO -440.

**INPUTS**

- `buffer` - a command buffer recording.
- `destination` - the buffer written.
- `offset` - where the bytes go, a multiple of four.
- `size` - how many, a multiple of four and at most 65536
  (`most_update_bytes`).
- `data` - the bytes, read as the command is recorded.

**RESULT**

None.

**BEHAVIOR**

The bytes are copied into the command buffer as this is recorded, so
what `data` points at may go as soon as it returns. A `size` over
`most_update_bytes` records nothing. Played, a run that lies past the
end of the buffer is left out and said to be in the log.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The bytes become the command buffer's own. The destination has to last
until the work is done.

**NOTES**

For a small write this takes a staging buffer, a map and a submit out of
the way; the bytes travel in the command buffer instead, which is why
there is a limit on them.

**BUGS**

None known.

**SEE ALSO**

`CmdFillBuffer`, `CmdCopyBuffer`

**EXAMPLES**

```zig
const matrix: [16]f32 = transform;
fb.CmdUpdateBuffer(commands, uniforms.?, 0, @sizeOf(@TypeOf(matrix)), &matrix);
```

## CmdWriteTimestamp

Recorded: the clock written into query `query` of `pool` when the command is played.

**SYNOPSIS**

```zig
fn CmdWriteTimestamp(base: *FacetBase, buffer: *facet.CommandBuffer, stage: u32, pool: *facet.QueryPool, query: u32) void
```

**SINCE**

1.29. LVO -480.

**INPUTS**

- `buffer` - a command buffer recording.
- `stage` - the `PIPELINE_STAGE_` the time is asked for at; every stage
  is the same moment here, see below.
- `pool` - a timestamp pool; one of another kind is left out of the
  frame and said to be in the log.
- `query` - which query of it.

**RESULT**

None.

**BEHAVIOR**

The value is the E-clock in microseconds, which is what
`PhysicalDeviceLimits.timestamp_period_ns` of 1000 says; the query is
available from then on.

The commands of a buffer are played one after another, each finished
before the next starts - on the cores by the queue's task itself, on the
V3D by waiting for the frame's interrupts - so a timestamp is the moment
everything recorded before it was done, whatever `stage` asks for. Two
of them round a render pass measure that pass.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The pool has to last until the work is done.

**NOTES**

Without timer.device there is no clock to read:
`PhysicalDeviceFeatures.timestamp_queries` is false then and
CreateQueryPool refuses the kind, so this cannot be reached.

**BUGS**

None known.

**SEE ALSO**

`CreateQueryPool`, `GetQueryPoolResults`

**EXAMPLES**

```zig
fb.CmdWriteTimestamp(commands, facet.PIPELINE_STAGE_TOP_OF_PIPE, times, 0);
fb.CmdBeginRenderPass(commands, &begin, .@"inline");
// ... the frame ...
fb.CmdEndRenderPass(commands);
fb.CmdWriteTimestamp(commands, facet.PIPELINE_STAGE_BOTTOM_OF_PIPE, times, 1);
```

## CreateBuffer

A buffer of so many bytes, for what its usage says.

**SYNOPSIS**

```zig
fn CreateBuffer(base: *FacetBase, device: *facet.Device, info: *const facet.BufferCreateInfo, buffer: *?*facet.Buffer) facet.Result
```

**SINCE**

1.0. LVO -76.

**INPUTS**

- `device` - the device.
- `info` - its size, and what it is for (BUFFER_USAGE_*).
- `buffer` - where the buffer is written; null when it fails.

**RESULT**

`success`; `error_out_of_device_memory` for a size of nothing;
`error_out_of_host_memory`.

**BEHAVIOR**

The buffer has no memory until BindBufferMemory binds it into some;
GetBufferMemoryRequirements says what it needs. The usage is what the
program says it does with it, and is not checked.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The buffer is the caller's, until DestroyBuffer; the memory it is
bound into stays the caller's to free.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`DestroyBuffer`, `GetBufferMemoryRequirements`, `BindBufferMemory`

**EXAMPLES**

```zig
var vertices: ?*facet.Buffer = null;
const info = facet.BufferCreateInfo{ .size = @sizeOf(@TypeOf(cube)), .usage = facet.BUFFER_USAGE_VERTEX_BUFFER };
if (fb.CreateBuffer(device, &info, &vertices) != .success) return error.NoBuffer;
```

## CreateBufferView

A range of a buffer read as texels of a format, for a texel buffer descriptor.

**SYNOPSIS**

```zig
fn CreateBufferView(base: *FacetBase, device: *facet.Device, info: *const facet.BufferViewCreateInfo, view: *?*facet.BufferView) facet.Result
```

**SINCE**

1.32. LVO -492.

**INPUTS**

- `device` - the device whose buffer it is.
- `info.buffer` - a buffer made with `BUFFER_USAGE_UNIFORM_TEXEL_BUFFER`,
  or `BUFFER_USAGE_STORAGE_TEXEL_BUFFER` for one a function writes
  through, and bound to memory.
- `info.format` - how the bytes are read: `r8g8b8a8_unorm`,
  `b8g8r8a8_unorm`, `r5g6b5_unorm_pack16`, `r32_sfloat`,
  `r32g32_sfloat`, `r32g32b32_sfloat`, `r32g32b32a32_sfloat`, and
  since 1.54 one channel, two or four of 8, 16 or 32 bits - a
  `_unorm` read as 0 to 1, a `_uint` or a `_sint` as the whole number
  itself, and `r16_sfloat`, `r16g16_sfloat` and
  `r16g16b16a16_sfloat` as half-floats. Those are the formats whose
  `buffer_features` say `UNIFORM_TEXEL_BUFFER`, which
  `GetPhysicalDeviceFormatProperties` tells and is the same on every
  device.
- `info.offset` - the first byte of the texels, a multiple of the
  format's size.
- `info.range` - how many bytes of them, a multiple of the format's
  size; `facet.WHOLE_SIZE` reaches the end of the buffer.
- `view` - where the view goes.

**RESULT**

`success`; `error_format_not_supported` for a format no view takes;
`error_feature_not_present` where the device has no texel buffers, or
the buffer was not made for them; `error_initialization_failed` for an
offset or a range that is not the format's size, or a range of no
texels, or a buffer with no memory; `error_out_of_host_memory`.

**BEHAVIOR**

The view holds the buffer, the format and the range, and nothing of the
bytes: they are read where they lie, as the buffer's memory holds them.
So a program writing the buffer through its mapped memory is seen by
the next function that reads the view, with no copy anywhere.

The range is held to the buffer: a range reaching past its end is cut
to it, and what is left has to be a texel at least.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The view is the caller's, given back by `DestroyBufferView`. The buffer
has to outlive it, and the view has to outlive every set it is written
into and every submission reading one.

**NOTES**

This is how a function reads bytes as a format rather than as a Zig
type: a storage buffer wants the program and the data to agree on a
struct, where a texel buffer reads what a file or another machine
handed over. `shader.Resources.texels` gives the function a
`shader.Texels`, whose `at` reads a texel as four floats and `colorAt`
as 0xAARRGGBB, whatever the format. Since 1.54 `intAt` reads it as four
whole numbers as well, and `setInt` writes it from them, which is what
a 32-bit integer format wants: a value past 2^24 is more than `at`'s
float carries exactly.

No image is kept in the formats 1.54 added and no vertex attribute is
read in one: they say `UNIFORM_TEXEL_BUFFER` and
`STORAGE_TEXEL_BUFFER` in `buffer_features` and nothing else. The two
that were already image formats, `r8_unorm` and `r16g16b16a16_sfloat`,
keep what they had and gain these.

**BUGS**

None known.

**SEE ALSO**

`DestroyBufferView`, `UpdateDescriptorSets`, `CreateDescriptorSetLayout`

**EXAMPLES**

```zig
var view: ?*facet.BufferView = null;
_ = fb.CreateBufferView(device, &.{ .buffer = buffer.?, .format = .r32g32b32a32_sfloat }, &view);
```

## CreateCommandPool

A pool the device's command buffers are allocated from.

**SYNOPSIS**

```zig
fn CreateCommandPool(base: *FacetBase, device: *facet.Device, info: *const facet.CommandPoolCreateInfo, pool: *?*facet.CommandPool) facet.Result
```

**SINCE**

1.0. LVO -120.

**INPUTS**

- `device` - the device.
- `info` - its queue family, 0, and its flags
  (COMMAND_POOL_CREATE_*).
- `pool` - where the pool is written; null when it fails.

**RESULT**

`success`; `error_initialization_failed` for a queue family the device
has not got; `error_out_of_host_memory`.

**BEHAVIOR**

The pool keeps its command buffers: DestroyCommandPool frees all of
them, ResetCommandPool resets all of them. Each buffer may be reset on
its own whatever the flags say.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The pool is the caller's, until DestroyCommandPool.

**NOTES**

A pool and its buffers are used by one task at a time: recording into
two buffers of one pool from two tasks at once is the program's to
keep apart.

**BUGS**

None known.

**SEE ALSO**

`DestroyCommandPool`, `AllocateCommandBuffers`

**EXAMPLES**

```zig
var pool: ?*facet.CommandPool = null;
if (fb.CreateCommandPool(device, &.{ .flags = facet.COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER }, &pool) != .success) return error.NoPool;
```

## CreateComputePipelines

`count` compute pipelines, one for each of `infos`, into `pipelines`.

**SYNOPSIS**

```zig
fn CreateComputePipelines(base: *FacetBase, device: *facet.Device, cache: ?*facet.PipelineCache, count: u32, infos: [*]const facet.ComputePipelineCreateInfo, pipelines: [*]?*facet.Pipeline) facet.Result
```

**SINCE**

1.18. LVO -416.

**INPUTS**

- `device` - the device.
- `cache` - null: facet.library has no pipeline caches.
- `count`, `infos` - each pipeline's function, of stage
  SHADER_STAGE_COMPUTE, and layout. The function's own entry says what a
  group of it holds: its invocations and the bytes they share
  (`shader.computeGroup`).
- `pipelines` - where each is written; null for one that could not be
  made.

**RESULT**

`success`; else what the first that could not be made came to:
`error_invalid_shader_nv` for a stage that is not of a compute function
the module has; `error_feature_not_present` for a workgroup over the
device's limits; `error_out_of_host_memory`. Those made are made either
way.

**BEHAVIOR**

A compute function runs on the cores, whichever device it was made on: a
CM5's V3D runs no program of the library's but its fragment programs.

A group of more than one invocation is still one call of the function:
what the pipeline carries from the entry is the group's size and the bytes
its invocations share, which CmdDispatch hands the function
(`shader.Groups.local`, `shader.Groups.shared`) for it to make the
invocations itself. A group over `PhysicalDeviceLimits`'
`max_compute_work_group_size` along an axis, or holding more invocations
than `max_compute_work_group_invocations`, or sharing more than
`max_compute_shared_memory_size` bytes, is refused here rather than cut
to what fits.

**CONTEXT**

- Waits: yes, for memory.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The pipeline is the caller's, given back by DestroyPipeline. The module
may go once it is made, not the function it names.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CmdDispatch`, `CmdBindPipeline`, `shader.compute`, `shader.computeGroup`

**EXAMPLES**

```zig
const info = facet.ComputePipelineCreateInfo{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module.? }, .layout = layout.? };
var pipeline: [1]?*facet.Pipeline = undefined;
if (fb.CreateComputePipelines(device, null, 1, @ptrCast(&info), &pipeline) != .success) return error.NoPipeline;
```

## CreateDescriptorPool

A descriptor pool: the most sets it gives out at once.

**SYNOPSIS**

```zig
fn CreateDescriptorPool(base: *FacetBase, device: *facet.Device, info: *const facet.DescriptorPoolCreateInfo, pool: *?*facet.DescriptorPool) facet.Result
```

**SINCE**

1.0. LVO -244.

**INPUTS**

- `device` - the device.
- `info` - the most sets, the descriptors of each kind, and whether its
  sets may be freed one by one.
- `pool` - where the pool is written; null when it fails.

**RESULT**

`success`; `error_initialization_failed` for a pool of no sets;
`error_out_of_host_memory`.

**BEHAVIOR**

The pool counts the sets it has given out against `max_sets`. The
descriptors of each kind are not counted: a set takes what its layout
needs, from the caller's memory, as it is allocated.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The pool is the caller's, until DestroyDescriptorPool, and the sets it
gives out are the pool's.

**NOTES**

Sets may be freed one by one whether or not the pool was made with
DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET.

**BUGS**

None known.

**SEE ALSO**

`AllocateDescriptorSets`, `ResetDescriptorPool`, `DestroyDescriptorPool`

**EXAMPLES**

```zig
const size = facet.DescriptorPoolSize{ .type = .sampled_image, .descriptor_count = 4 };
var pool: ?*facet.DescriptorPool = null;
_ = fb.CreateDescriptorPool(device, &.{ .max_sets = 4, .pool_size_count = 1, .pool_sizes = @ptrCast(&size) }, &pool);
```

## CreateDescriptorSetLayout

A descriptor set layout: a set's bindings, each of a kind, with its descriptors.

**SYNOPSIS**

```zig
fn CreateDescriptorSetLayout(base: *FacetBase, device: *facet.Device, info: *const facet.DescriptorSetLayoutCreateInfo, layout: *?*facet.DescriptorSetLayout) facet.Result
```

**SINCE**

1.0. LVO -228.

**INPUTS**

- `device` - the device.
- `info` - the bindings, in any order.
- `layout` - where the layout is written; null when it fails.

**RESULT**

`success`; `error_feature_not_present` for a kind of descriptor
facet.library does not have, for samplers of the layout's own on a
device without `PhysicalDeviceFeatures.immutable_samplers`, a binding
numbered past 255, or more than 65535 descriptors;
`error_initialization_failed` for a binding given twice;
`error_out_of_host_memory`.

**BEHAVIOR**

The kinds are sampler, combined_image_sampler, sampled_image,
storage_image, uniform_buffer, storage_buffer, uniform_texel_buffer,
storage_texel_buffer, uniform_buffer_dynamic, storage_buffer_dynamic
and, since 1.37, input_attachment: all eleven of Vulkan's. A binding
not given has no descriptors, and neither has one given with a count
of 0. A binding's descriptors are an array, read by a shader as
element 0 on (shader.Resources).

Some kinds want a device that has them, others answering
`error_feature_not_present`: a storage image `storage_images`, a texel
buffer `texel_buffers`, a dynamic buffer `dynamic_descriptors` (and no
more of them in one set than
`PhysicalDeviceLimits.max_descriptor_set_dynamic_buffers`), and an
input attachment `input_attachments` - the cores, not the V3D, whose
fragment functions are of fixed forms and read none.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The layout is the caller's, until DestroyDescriptorSetLayout. The
bindings are read during the call alone.

**NOTES**

A fragment function of a fixed form samples either as it was compiled
to (sdk.facet.shader.textured) or through the sampler bound beside the
texture (shader.FixedKind.texture_sampled), which is what a combined
image sampler is for. Stage flags are not looked at: every stage reads
every binding.

**A sampler of the layout's own** is taken since 1.49
(`immutable_samplers`, `PhysicalDeviceFeatures.immutable_samplers`): on
a `sampler` or `combined_image_sampler` binding the layout holds one
sampler for each of the binding's descriptors, and every set made of
the layout starts with them in its slots. A write of a combined image
sampler into such a binding brings the texture and leaves the sampler;
a write of a sampler alone changes nothing. The samplers have to last
as long as the sets do, as a written one does. On a binding of another
kind the pointer is passed over, as Vulkan passes it over.

**BUGS**

None known.

**SEE ALSO**

`CreatePipelineLayout`, `AllocateDescriptorSets`, `UpdateDescriptorSets`

**EXAMPLES**

```zig
const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .sampled_image, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
var set_layout: ?*facet.DescriptorSetLayout = null;
_ = fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout);
```

## CreateDevice

A device of the program's own, with its queue.

**SYNOPSIS**

```zig
fn CreateDevice(base: *FacetBase, physical: *facet.PhysicalDevice, info: *const facet.DeviceCreateInfo, device: *?*facet.Device) facet.Result
```

**SINCE**

1.0. LVO -44.

**INPUTS**

- `physical` - the physical device it is made on.
- `info` - its queues: none, or one of family 0.
- `device` - where the device is written; null when it fails.

**RESULT**

`success`; `error_initialization_failed` for queues the family has
not got, and when the queue's task cannot be made;
`error_out_of_host_memory`.

**BEHAVIOR**

The device's queue plays its command buffers on a task of its own,
at the priority the queue was given: 0.5 the caller's own, 0.0 ten
below it, 1.0 ten above.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The device is the caller's, until DestroyDevice; it has to go before
the instance it was made from.

**NOTES**

A device has no features to switch on: what it does, it does.

**BUGS**

None known.

**SEE ALSO**

`DestroyDevice`, `GetDeviceQueue`, `GetPhysicalDeviceQueueFamilyProperties`

**EXAMPLES**

```zig
const queue_info = facet.DeviceQueueCreateInfo{ .queue_family_index = 0 };
var device: ?*facet.Device = null;
if (fb.CreateDevice(physical, &.{ .queue_create_info_count = 1, .queue_create_infos = @ptrCast(&queue_info) }, &device) != .success) return error.NoDevice;
defer fb.DestroyDevice(device);
```

## CreateFence

A fence: signalled by a queue when the submission it came with is done.

**SYNOPSIS**

```zig
fn CreateFence(base: *FacetBase, device: *facet.Device, info: *const facet.FenceCreateInfo, fence: *?*facet.Fence) facet.Result
```

**SINCE**

1.0. LVO -176.

**INPUTS**

- `device` - the device.
- `info` - FENCE_CREATE_SIGNALED for one that starts signalled.
- `fence` - where the fence is written; null when it fails.

**RESULT**

`success`; `error_out_of_host_memory`.

**BEHAVIOR**

A fence is an exec waitable (exec.Waitable): signalled, it stays so
until ResetFences.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The fence is the caller's, until DestroyFence.

**NOTES**

A fence made signalled lets a frame loop wait for the frame before
from its very first frame on.

**BUGS**

None known.

**SEE ALSO**

`WaitForFences`, `ResetFences`, `QueueSubmit`

**EXAMPLES**

```zig
var frame_done: ?*facet.Fence = null;
if (fb.CreateFence(device, &.{ .flags = facet.FENCE_CREATE_SIGNALED }, &frame_done) != .success) return error.NoFence;
```

## CreateFramebuffer

A framebuffer: an image view for each of a render pass's attachments.

**SYNOPSIS**

```zig
fn CreateFramebuffer(base: *FacetBase, device: *facet.Device, info: *const facet.FramebufferCreateInfo, framebuffer: *?*facet.Framebuffer) facet.Result
```

**SINCE**

1.0. LVO -212.

**INPUTS**

- `device` - the device.
- `info` - the render pass, a view for each of its attachments in their
  order, and the size drawn in.
- `framebuffer` - where the framebuffer is written; null when it fails.

**RESULT**

`success`; `error_initialization_failed` for views that do not fit the
pass - another number of them, a colour view of an image not made for a
colour attachment or in another format, a depth view of an image not
made for depth, an image smaller than the size, more than one layer;
`error_out_of_host_memory`.

**BEHAVIOR**

Each colour attachment's view is of its image's first level. The size
may be smaller than the images: the framebuffer is their top left.

A depth view names the level and the layer the pass draws into - levels
since 1.63, layers since 1.58 - and it is that level's rows that have
to hold the size, not the image's first. So the levels of one depth
image are a shadow map and the smaller copies a pass draws for
themselves, each through a framebuffer of that level's size.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The framebuffer is the caller's, until DestroyFramebuffer. The views
have to last as long as it does, and their images.

**NOTES**

The images have to be bound into memory before a pass draws into them.

**BUGS**

None known.

**SEE ALSO**

`CreateRenderPass`, `CmdBeginRenderPass`, `DestroyFramebuffer`

**EXAMPLES**

```zig
var frame: ?*facet.Framebuffer = null;
_ = fb.CreateFramebuffer(device, &.{ .render_pass = pass.?, .attachment_count = 1, .attachments = @ptrCast(&view), .width = 800, .height = 600 }, &frame);
```

## CreateGraphicsPipelines

`count` graphics pipelines, one for each of `infos`, into `pipelines`.

**SYNOPSIS**

```zig
fn CreateGraphicsPipelines(base: *FacetBase, device: *facet.Device, cache: ?*facet.PipelineCache, count: u32, infos: [*]const facet.GraphicsPipelineCreateInfo, pipelines: [*]?*facet.Pipeline) facet.Result
```

**SINCE**

1.0. LVO -268.

**INPUTS**

- `device` - the device.
- `cache` - null: facet.library has no pipeline caches.
- `count`, `infos` - each pipeline's stages and state.
- `pipelines` - where each is written; null for one that could not be
  made.

**RESULT**

`success`; else what the first that could not be made came to:
`error_invalid_shader_nv` for stages that are not one vertex and one
fragment function of the same varyings, with or without a tessellation
control and evaluation function, whose varyings then the fragment
function's have to be, or for a fragment function that writes other
than the subpass's colour attachments (`shader.fragmentOutputs`, since
1.51); `error_feature_not_present`
for state facet.library does not draw (see BEHAVIOR);
`error_format_not_supported` for an attribute in a format it does not
read; `error_initialization_failed` for state that does not hold
together - an attribute of a binding not given, no viewport where it is
not set by commands; `error_out_of_host_memory`. Those made are made
either way.

**BEHAVIOR**

A pipeline takes its vertex and fragment functions from the modules by
stage and name, and settles its state as it is made: the rasterizer's
code for its depth test and blend is chosen then, not as it draws. On a
device with a processor of its own the fragment function has to be of a
fixed form (`shader.fixedFragment`), or the pipeline is refused with
`error_feature_not_present`.

With tessellation functions, the topology is `patch_list` and the
`tessellation_state` says the vertices of a patch, 1 to 32: the cores make
each patch into triangles or lines (`shader.Tessellation`), for a device
with a processor of its own too, and those are drawn; without them,
`patch_list` is `error_initialization_failed`. The evaluation entry says
the domain, which way round its triangles go, and how the fraction of a
level is spent (`shader.Spacing`, since 1.50): a domain or a spacing of a
value this library has not is `error_invalid_shader_nv`. The control entry
says the floats the patch carries from the one function to the other
(`shader.control`, `Patch.ownValues`, since 1.50), more of them than
`PhysicalDeviceLimits.max_tessellation_patch_components` being
`error_feature_not_present`.

What it draws: points, lines and line strips, and triangle lists, strips
and fans, a restart index ending a strip or a fan; triangles filled, or as
their edges or corners (POLYGON_MODE_LINE, POINT); one sample a pixel,
triangles culled by facing as asked; lines `line_width` pixels wide, set
here or by CmdSetLineWidth, and points one pixel; a
depth test of any compare, written or not, with a bias on the triangles'
depth where the device takes one, held inside the viewport's range
where it clamps (`depth_clamp_enable`) and kept only between two
bounds where it tests them (`depth_bounds_test_enable`, since 1.40);
a stencil test of any compare and operations, a face's own, the masks and
the reference given here or set by commands; the channels of the write mask written, replacing what is
there or mixed with it by any blend factors and operation, the alpha by
its own and each colour attachment of the subpass by its own
(`color_blend_state.attachments`, one for each), and no logic op; one viewport and one scissor, given here or set
by CmdSetViewport and CmdSetScissor (DynamicState viewport and scissor;
blend_constants with CmdSetBlendConstants, line_width with CmdSetLineWidth,
depth_bias with CmdSetDepthBias, depth_bounds with CmdSetDepthBounds,
the stencil's with CmdSetStencilCompareMask, CmdSetStencilWriteMask and
CmdSetStencilReference;
the others are taken and do nothing). A pipeline with the rasterizer
discarding, or culling front and back, draws nothing.

`PIPELINE_CREATE_DEPTH_PREPASS` in `flags`, facet.library's own, has the
pipeline's triangles' depth drawn first in each tile and each pixel then
shaded once, by the nearest: a scene drawn back to front costs little
more than one drawn front to back, which costs a little more than
without it. For a depth test of LESS or LESS_OR_EQUAL, written, and no
blending; ignored otherwise. Other flags are taken and do nothing.

On a device with a processor of its own, the fragment function has to be
one of the fixed forms (`shader.fixedFragment`), or the pipeline is
refused with `error_feature_not_present`; the cores, always the first
device listed, take any.

Attributes are read as floats - r32_sfloat to r32g32b32a32_sfloat - or
as bytes 0 to 1, r8g8b8a8_unorm and b8g8r8a8_unorm, into four floats
each, up to four bindings and eight locations.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

Each pipeline is the caller's, until DestroyPipeline. The modules, the
layout and the render pass may go before it; the functions it took have
to last as long as it does, as the program's code does.

**NOTES**

A depth test on a render pass without depth is no test, as Vulkan has
it, nor a stencil test on one without stencil. Lines and points use the
front's stencil test, and take no depth bias: only triangles are moved,
as in Vulkan, and `depth_bias_enable` wants a device whose
`PhysicalDeviceFeatures.depth_bias` is true (since 1.34).

`depth_clamp_enable` draws what lies past the near plane instead of
cutting it away, each pixel's depth held inside the viewport's
`min_depth` and `max_depth` - which is what a shadow volume wants - and
`depth_bounds_test_enable` draws a pixel only where the depth
**already** in the attachment lies between `min_depth_bounds` and
`max_depth_bounds`, whatever the depth being drawn; `DynamicState`'s
`depth_bounds` leaves the two to CmdSetDepthBounds. Both want a device
whose `PhysicalDeviceFeatures.depth_clamp` or `depth_bounds` is true -
every device since 1.47, the V3D's own configuration having both - and
on the cores both have a draw's pixels walked one at a time, as a
stencil test does, so they cost more there than the quads the fast
paths walk.

On an attachment without alpha, R5G6B5, what is there reads as wholly
opaque. `color_blend_state.attachments` holds one state for each colour
attachment of the subpass, or none for the default over all of them; a
subpass of several has each blended its own way (since 1.33,
`PhysicalDeviceFeatures.independent_blend`). The blend constants are
the pipeline's and shared, as in Vulkan, unless
`attachment_constants` gives one set for each attachment instead -
facet.library's own, since 1.51 - and with `blend_constants` among the
dynamic states CmdSetBlendConstants sets the one set over all of them
and CmdSetBlendConstantsAt one attachment's own. On the cores,
SRC_ALPHA and ONE_MINUS_SRC_ALPHA or ONE, with
the alpha's factors the same or ZERO and ONE and the mask whole, cost
less than any other mixing.

The fragment entry says how many colours its function writes in the
one call: one, or the subpass's colour attachments where the subpass
draws them together (SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER,
`shader.fragmentOutputs`, since 1.51). It has to come to exactly what
the subpass has either way, and a function of several wants a device
whose `several_outputs` is true.

**BUGS**

None known.

**SEE ALSO**

`CreateShaderModule`, `CreatePipelineLayout`, `CreateRenderPass`, `CmdBindPipeline`, `DestroyPipeline`

**EXAMPLES**

```zig
const stages = [2]facet.PipelineShaderStageCreateInfo{
    .{ .stage = facet.SHADER_STAGE_VERTEX, .module = module.? },
    .{ .stage = facet.SHADER_STAGE_FRAGMENT, .module = module.? },
};
const raster_state = facet.PipelineRasterizationStateCreateInfo{ .cull_mode = facet.CULL_MODE_BACK, .front_face = .clockwise };
const depth = facet.PipelineDepthStencilStateCreateInfo{ .depth_test_enable = true, .depth_write_enable = true };
const viewport_state = facet.PipelineViewportStateCreateInfo{ .viewports = @ptrCast(&viewport), .scissors = @ptrCast(&scissor) };
var pipeline: ?*facet.Pipeline = null;
_ = fb.CreateGraphicsPipelines(device, null, 1, @ptrCast(&facet.GraphicsPipelineCreateInfo{
    .stage_count = 2,
    .stages = &stages,
    .viewport_state = &viewport_state,
    .rasterization_state = &raster_state,
    .depth_stencil_state = &depth,
    .layout = layout.?,
    .render_pass = pass.?,
}), @ptrCast(&pipeline));
```

## CreateImage

An image: a texture, an attachment, or what a copy moves.

**SYNOPSIS**

```zig
fn CreateImage(base: *FacetBase, device: *facet.Device, info: *const facet.ImageCreateInfo, image: *?*facet.Image) facet.Result
```

**SINCE**

1.0. LVO -92.

**INPUTS**

- `device` - the device.
- `info` - its format, size, levels, tiling and usage.
- `image` - where the image is written; null when it fails.

**RESULT**

`success`; `error_format_not_supported` for an image facet.library
does not make; `error_out_of_host_memory`.

**BEHAVIOR**

What it is for decides how it lies in its memory:
- SAMPLED, in optimal tiling, of B8G8R8A8, R8G8B8A8, R5G6B5 or R8_UNORM, of any
  sides, with up to as many levels as halving the longer gives -
  floor(log2(side)) + 1, each level the one before halved and no less
  than one: a texture, in blocks of 4 x 4 texels, an 8888 texel kept in
  64 bits (sdk.facet.texture). Its texels come in by
  CmdCopyBufferToImage. A width that is not a power of two is laid out
  by the next one up, so such a texture takes up to 2 x the memory of
  one as wide as a power of two (since 1.42); past the width nothing is
  ever read.
- COLOR_ATTACHMENT, of B8G8R8A8, R8G8B8A8 or R5G6B5, one level: rows,
  each on a cache line, in either tiling. What is drawn into one of
  R5G6B5 is dithered into it (CmdBeginRenderPass).
- D16_UNORM, S8_UINT or D16_UNORM_S8_UINT with
  DEPTH_STENCIL_ATTACHMENT, optimal, one level: a depth that lives in
  the tiles alone, never stored, whose memory may be of the lazily
  allocated type. With a load or a store op it is kept in rows instead
  (CreateRenderPass), and with SAMPLED as well those rows are the
  texture a sampler reads: a shadow map drawn into and sampled out of
  with nothing copied (`PhysicalDeviceFeatures.sampled_depth`, since
  1.39). One sampled wants memory something is behind and is not
  written through as a storage image.
  Any of the three formats is sampled since 1.58, and such an image
  may have layers: a view of it takes one plane - the depth, or the
  stencil - of the layers it names, and a pass draws into the layer
  its framebuffer's view begins at (CreateImageView). A layer's rows
  come after the one before, each on a cache line.
  Levels of its own since 1.63, as many as halving the longer side
  gives: a layer holds the whole pyramid, a level's rows after the
  level before it and each level on a cache line, its pitch as wide
  as that level is. A pass draws into the level its framebuffer's
  view names, and a sample reads any of them, so a shadow map and its
  smaller copies are the levels of one image. It is never of type
  `3d`: a slice is nothing a pass draws into.
  With INPUT_ATTACHMENT it is read pixel by pixel by a later subpass
  instead, or as well (since 1.62): the same rows, the same feature,
  and the same memory behind them, so TRANSIENT_ATTACHMENT is refused
  with it too.
- INPUT_ATTACHMENT, of B8G8R8A8, R8G8B8A8 or R5G6B5, in either
  tiling: rows, which a later subpass reads pixel by pixel
  (CreateRenderPass). It goes with COLOR_ATTACHMENT and the transfers,
  not with SAMPLED, STORAGE or TRANSIENT_ATTACHMENT, which lie
  otherwise or nowhere. On a depth format it is the bullet above.
- Anything else of a colour format, one level: rows.

Images have one sample a pixel, and are up to 8192 wide and high. One both
SAMPLED and COLOR_ATTACHMENT is not made: a texture and an attachment lie
differently.

**A colour attachment may be written through as a storage image** since
1.56: COLOR_ATTACHMENT, or INPUT_ATTACHMENT, with STORAGE and without
SAMPLED, of B8G8R8A8 or R5G6B5, one level and one layer. The image stays
in rows, as an attachment is, and those rows are the texture a function
writes (`shader.Resources.written`): a write reaches them at once, where
what a subpass draws reaches them when it stores, at the end of its part.
So a function may seed the rows before a pass draws into them, or write
over them after it, and writing them while the pass that draws into them
is open has no order against that store - as it has none in Vulkan
without a barrier. R8G8B8A8 is `error_format_not_supported` for this: a
texture of 8888 is 0xAARRGGBB, as B8G8R8A8's rows are, and nothing reads
a word with red in its low byte. FORMAT_FEATURE_STORAGE_IMAGE in a
format's **linear** features says its rows may be written through.

A SAMPLED image may have up to 256 layers, or be 3D, of type `3d`, of any
depth up to 256 and with levels of its own (since 1.46): a level is half
as deep as the one before it, and no less than one slice deep, each slice
carrying the whole of its own pyramid. IMAGE_CREATE_CUBE_COMPATIBLE says a
view of type cube, or of cube_array, will be made: of a square image of 6
layers or more, a multiple of six of them for an array of cubes.

A STORAGE image may have layers and levels the same way, and since
1.55 needs no SAMPLED beside it to have them: a function writing one
names the level and the layer of the view it writes
(`shader.Resources.written`, `texture.Texture.setColor`). Before that
an image of layers was refused unless it was sampled as well.

A SAMPLED image may be of BC1, BC2, BC3, R16G16B16A16_SFLOAT,
R32G32B32A32_SFLOAT, B10G11R11_UFLOAT or E5B9G9R9_UFLOAT, in optimal tiling.
A float one is kept as the floats it was copied in as on a device that
samples them (`PhysicalDeviceFeatures.kept_floats`, since 1.45): the two
packed formats then take 4 bytes a texel rather than the 8 an unpacked
texel is kept spread in, and a copy out gives back what went in. A sample
holds each channel inside 0 to 1 and rounds it to 8 bits, the tiles having
no more. A device without the feature keeps it as R8G8B8A8, unpacked as it
is copied in: it takes that one's memory, and there is no copying it out,
nor another image into it, by CmdCopyImage.

It may also be of ETC2 or EAC - ETC2_R8G8B8, ETC2_R8G8B8A1, ETC2_R8G8B8A8,
EAC_R11 or EAC_R11G11 - which no sampler of this library reads: such an
image is always kept as R8G8B8A8, its blocks unpacked as they are copied
in (`PhysicalDeviceFeatures.etc2_textures`, since 1.46).

R32_SFLOAT is an image since 1.57, in optimal tiling: one float a texel,
sampled as (red, 0, 0, 1) the way R8_UNORM is read, with the float held
between 0 and 1 and rounded to 8 bits for the sample, and written through
by a function as the float it is (`texture.Texture.setParts`). A height
field, a mask or an accumulation buffer is kept in it. It is not a colour
attachment and not a vertex's value.

A compressed one - BC1, BC2, BC3 - is kept in its blocks on a device that
samples them (`PhysicalDeviceFeatures.kept_compressed`, since 1.44): an
eighth to a quarter of that memory, and the blocks are copied in and out
as they lie, by CmdCopyBufferToImage, CmdCopyImageToBuffer and CmdCopyImage
between two images of the one format, their offsets and extents on a
multiple of 4 as Vulkan asks. GetImageMemoryRequirements says which was
done. A device without the feature unpacks it as a float image is unpacked.
A STORAGE image is written texel by texel, so a compressed one is unpacked
there whatever the device: nothing writes one texel of a block, and such
an image wants SAMPLED beside it, being unpacked to be sampled. A float
one keeps its floats since 1.57, a function writing one texel of them by
`texture.Texture.setParts`, so a float storage image needs no SAMPLED
either.

**A texel may be kept smaller than the colour it reads as** on a device
that says so (`PhysicalDeviceFeatures.small_texels`, since 1.48), which
is where a texture is large enough that the memory it fills is what it
costs:
- R8_UNORM is one byte a texel, read as (red, 0, 0, 1) the way Vulkan
  reads a one-channel format - an eighth of what the same texels kept
  as 8888 take. For SAMPLED or STORAGE, in optimal tiling; a copy moves
  the bytes both ways. It is not a colour attachment and not a vertex's
  value.
- IMAGE_CREATE_PACKED_TEXELS on a SAMPLED or STORAGE image of B8G8R8A8
  or R8G8B8A8 keeps each texel in the 32 bits of its word rather than
  spread over 64: half the memory, for the spread a sample then does
  itself. Nothing else of the image changes - the same colours in, the
  same out, the same copies - and a fixed form compiled for
  `texture.Format.argb8888` reads it at full speed, while one compiled
  for `rgba8888` draws it through the run-time sampler as it does any
  other format it was not built for.

Both are `error_format_not_supported` where the device has not got
them, and so is the flag on an image that is neither sampled nor a
storage image, or whose format has no 8888 word to keep.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The image is the caller's, until DestroyImage.

**NOTES**

Layouts change nothing in facet.library's memory: `initial_layout` is
taken as it is.

**BUGS**

None known.

**SEE ALSO**

`DestroyImage`, `GetImageMemoryRequirements`, `BindImageMemory`, `GetPhysicalDeviceFormatProperties`

**EXAMPLES**

```zig
var picture: ?*facet.Image = null;
const info = facet.ImageCreateInfo{
    .format = .b8g8r8a8_unorm,
    .extent = .{ .width = 256, .height = 256 },
    .mip_levels = 9,
    .usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST,
};
if (fb.CreateImage(device, &info, &picture) != .success) return error.NoImage;
```

## CreateImageView

A view of an image: the levels of it a texture descriptor samples, or what a framebuffer draws into.

**SYNOPSIS**

```zig
fn CreateImageView(base: *FacetBase, device: *facet.Device, info: *const facet.ImageViewCreateInfo, view: *?*facet.ImageView) facet.Result
```

**SINCE**

1.0. LVO -112.

**INPUTS**

- `device` - the device the image was made on.
- `info` - the image, bound already, its own format, and the levels
  the view takes.
- `view` - where the view is written; null when it fails.

**RESULT**

`success`; `error_format_not_supported` for a view facet.library does
not make - of another format than the image's, of a type the image is
not for, with channels swizzled, of levels or layers the image has not
got, or of an image not yet bound into memory; `error_out_of_host_memory`.

**BEHAVIOR**

A view of a texture samples its levels from `base_mip_level` on, as a
texture of its own whose first level is that one. A view of an
attachment is all of it.

Of type `2d` it is one layer, of a texture with any number of them. Of type
`2d_array` it is the layers asked for, for `shader.FixedKind.texture_array`;
`cube` is 6 layers of an image made IMAGE_CREATE_CUBE_COMPATIBLE, for
`texture_cube`, and `3d` the whole of a 3D image, for `texture_3d`.

Of type `cube_array` it is as many cubes as its layers divided by six, of
such an image, for `texture_cube_array` and, since 1.53,
`texture_cube_array_sampled`: its layers are a multiple of six
and its first layer begins a cube, so `base_array_layer` is a multiple of
six as well (`PhysicalDeviceFeatures.cube_arrays`, since 1.46).

**A view of a sampled depth image takes one of its planes** since 1.58
(`PhysicalDeviceFeatures.sampled_depth`): IMAGE_ASPECT_DEPTH is the
depth, read at all 16 bits by a sampler that compares and as a grey of
its top 8 by one that does not, and IMAGE_ASPECT_STENCIL is the
stencil, read as (red, 0, 0, 1) the way a texel of one byte is. Both
aspects at once is `error_format_not_supported`, as is a plane the
format has not got; an aspect naming neither - IMAGE_ASPECT_COLOR, the
default, and what every such view asked for before 1.58 - is the
format's own plane, its depth where it has one and its stencil where
it has not. The plane is a texture over the image's own rows, so a
format holding both is two textures inside the same rows, read four
bytes apart. Since 1.63 it is the levels the view names as well, each
in rows of its own: a sample of such a view reads the level it chooses,
as it does of any texture.

Since 1.62 the same plane is what a later subpass reads as an **input
attachment** (`shader.Attachment`), where the image was made one
(IMAGE_USAGE_INPUT_ATTACHMENT): the view's first layer, the depth as
`r16`, 0 to 1 and nearest first, and the stencil as `r8u`, the whole
number it is. A format holding both is read four bytes from one pixel
to the next, the view's aspect saying which plane this is.

Such a view is of the layers it names as well, of type `2d` or
`2d_array`: the image's own rows for that layer, which is what a pass
drawing into the view writes and what a sample of it reads. So the
layers of one image are the shadow maps of several lights, each drawn
into through a framebuffer with a view of that layer.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The view is the caller's, until DestroyImageView, which comes before
the image's DestroyImage.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`DestroyImageView`, `CreateImage`, `CreateFramebuffer`

**EXAMPLES**

```zig
var view: ?*facet.ImageView = null;
const info = facet.ImageViewCreateInfo{ .image = picture.?, .format = .b8g8r8a8_unorm };
if (fb.CreateImageView(device, &info, &view) != .success) return error.NoView;
```

## CreateInstance

A program's hold on the library, through which it finds the devices.

**SYNOPSIS**

```zig
fn CreateInstance(base: *FacetBase, info: *const facet.InstanceCreateInfo, instance: *?*facet.Instance) facet.Result
```

**SINCE**

1.0. LVO -20.

**INPUTS**

- `info` - what the program is, and the interface it was written for
  (`api_version`).
- `instance` - where the instance is written; null when it fails.

**RESULT**

`success`; `error_initialization_failed` for an interface newer than
the library's; `error_out_of_host_memory`.

**BEHAVIOR**

The instance's physical devices are described as it is made. The first is
the cores: those it draws on are counted, and its memory types made from
the regions exec has (GetPhysicalDeviceMemoryProperties). A region added
later is in the memory types of an instance made after it.

After them comes a device for each driver module that finds its hardware.
The first instance made on a process looks for them in LIBS:facet/, opening
each file there as a library; an instance made on a task before that lists
only the cores. One built from other source than this library is refused,
with a line in the log. They stay open until the library goes.

While an instance lasts the library stays loaded, even after the
program has closed it: its queues' tasks run the library's code.

**CONTEXT**

- Waits: the first time on a process, on the disk.
- Interrupts: no.
- Locks: exec's memory list, for a moment.
- Process: a Task will do.

**OWNERSHIP**

The instance is the caller's, until DestroyInstance.

**NOTES**

A program has one instance, as a rule; it may have more, each with
devices of its own.

**BUGS**

None known.

**SEE ALSO**

`DestroyInstance`, `EnumeratePhysicalDevices`

**EXAMPLES**

```zig
var instance: ?*facet.Instance = null;
if (fb.CreateInstance(&.{ .application_name = "Cube" }, &instance) != .success) return error.NoInstance;
defer fb.DestroyInstance(instance);
```

## CreatePipelineLayout

A pipeline layout: the descriptor sets and the push constants a pipeline's shaders read.

**SYNOPSIS**

```zig
fn CreatePipelineLayout(base: *FacetBase, device: *facet.Device, info: *const facet.PipelineLayoutCreateInfo, layout: *?*facet.PipelineLayout) facet.Result
```

**SINCE**

1.0. LVO -236.

**INPUTS**

- `device` - the device.
- `info` - a set layout for each set from 0, and the ranges of push
  constants.
- `layout` - where the layout is written; null when it fails.

**RESULT**

`success`; `error_feature_not_present` for more than four sets, or
push constants past 128 bytes; `error_initialization_failed` for a range
not on 4 bytes; `error_out_of_host_memory`.

**BEHAVIOR**

A shader reads set `n` as `Resources.sets[n]` and the push constants
as `Resources.push`, from byte 0, whatever the stages.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The layout is the caller's, until DestroyPipelineLayout. The set
layouts may go before it.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateDescriptorSetLayout`, `CreateGraphicsPipelines`, `CmdBindDescriptorSets`, `CmdPushConstants`

**EXAMPLES**

```zig
const push = facet.PushConstantRange{ .stage_flags = facet.SHADER_STAGE_VERTEX, .size = 64 };
var layout: ?*facet.PipelineLayout = null;
_ = fb.CreatePipelineLayout(device, &.{ .set_layout_count = 1, .set_layouts = @ptrCast(&set_layout), .push_constant_range_count = 1, .push_constant_ranges = @ptrCast(&push) }, &layout);
```

## CreateQueryPool

A query pool: `query_count` queries of one kind, nothing counted yet.

**SYNOPSIS**

```zig
fn CreateQueryPool(base: *FacetBase, device: *facet.Device, info: *const facet.QueryPoolCreateInfo, pool: *?*facet.QueryPool) facet.Result
```

**SINCE**

1.29. LVO -456.

**INPUTS**

- `device` - the device whose work is counted.
- `info` - the kind, how many queries, and for `pipeline_statistics`
  which statistics each one counts.
- `pool` - where the pool is written; null when it fails.

**RESULT**

`success`; `error_feature_not_present` for a kind this device has not
got (`PhysicalDeviceFeatures.occlusion_queries`,
`pipeline_statistics_queries`, `timestamp_queries`), or for a bit that
is none of Vulkan's; `error_initialization_failed` for no queries at
all, or a statistics pool that counts nothing;
`error_out_of_host_memory`. A geometry shader's two statistics may be
asked for since 1.43, there being no such stage to count: they read 0,
which is what Vulkan has a statistic of a stage that never ran hold.

**BEHAVIOR**

A query holds one value, or for `pipeline_statistics` one for each
statistic asked for, in the order of their bits. Every query starts not
available and counting nothing, as `CmdResetQueryPool` leaves it; Vulkan
asks for a reset before a query is used all the same, and a program that
means to be read elsewhere should do it.

Which kinds a device has is what it counts with: an occlusion query is
counted by the rasterizer on the cores and by the hardware's own counter
on the V3D, which every device has since 1.47; the statistics are the
calls round the rasterizer, so they are the cores' alone; and a
timestamp is the E-clock read as the command is played, which every
device does - where the machine has timer.device, or there is no clock
to read and the kind is refused.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The pool is the caller's, until DestroyQueryPool. Its values are written
by the queue's task and by the cores that draw the tiles, so it has to
last until the work that names it is done.

**NOTES**

There is one pool for each kind, as in Vulkan: a pool of statistics does
not also count samples.

**BUGS**

None known.

**SEE ALSO**

`CmdBeginQuery`, `CmdWriteTimestamp`, `GetQueryPoolResults`,
`DestroyQueryPool`

**EXAMPLES**

```zig
var counted: ?*facet.QueryPool = null;
_ = fb.CreateQueryPool(device, &.{ .query_type = .occlusion, .query_count = 1 }, &counted);
```

## CreateRenderPass

A render pass: the attachments it draws into, what each starts with and what is kept of it.

**SYNOPSIS**

```zig
fn CreateRenderPass(base: *FacetBase, device: *facet.Device, info: *const facet.RenderPassCreateInfo, render_pass: *?*facet.RenderPass) facet.Result
```

**SINCE**

1.0. LVO -204.

**INPUTS**

- `device` - the device.
- `info` - the attachments and the subpasses that draw into them.
- `render_pass` - where the render pass is written; null when it fails.

**RESULT**

`success`; `error_feature_not_present` for a pass facet.library does
not draw (BEHAVIOR); `error_format_not_supported` for an attachment in
a format it cannot draw into, or read as an input attachment;
`error_initialization_failed` for a subpass that names an attachment
there is not, or reads one it draws into itself without saying so in a
dependency by region (BEHAVIOR);
`error_out_of_host_memory`.

**BEHAVIOR**

The pass has up to 4 subpasses and up to 8 attachments. A subpass draws
into 1 to 4 colour attachments - b8g8r8a8_unorm or r8g8b8a8_unorm - 8 in all
the subpasses, and may test against a depth attachment, d16_unorm, s8_uint
or d16_unorm_s8_uint. No resolve or multisampled attachments.

The subpasses are drawn one after another. A colour attachment's load op
CLEAR clears the render area the first time a subpass names it; LOAD,
DONT_CARE and later subpasses keep what the image holds. What is drawn is
stored, whatever its store op.

The depth attachment lives in the rasterizer's tiles, and its load op
CLEAR or DONT_CARE - both clear it - and its store op DONT_CARE leave it
there, costing no memory at all. Since 1.30 it may outlive the pass
instead: with the store op STORE each tile's depth is written into the
image's memory as the tile is drawn, and with the load op LOAD each
tile starts from what is there. Both want a format that holds a depth
and a device whose `stored_depth` is true - every device since 1.47 -
and an image bound to memory something is behind, which
CreateFramebuffer holds to; otherwise that is
`error_feature_not_present`. A depth the V3D stored may be one of the
65535ths away from the one the cores would have stored: the hardware
keeps a deeper number and writes its top 16 bits, which is the same
where the depth falls on a 65535th and one more where it does not.

Since 1.38 the stencil keeps its own the same way, by its own two ops:
with `stencil_store_op` STORE each tile's stencil, a byte a pixel, is
written into its own plane of the image's rows, and with
`stencil_load_op` LOAD each tile starts from what is there. That wants
a format that holds a stencil - `s8_uint` or `d16_unorm_s8_uint` - and
a device whose `stored_stencil` is true, every device again. A format
that holds both keeps each pixel's depth and its stencil beside each
other, so the four ops are taken on their own: a pass may store the
stencil and leave the depth in the tiles, or the other way round. An
op for a plane the format has not is `error_feature_not_present`.

Keeping either plane of a format that holds **both** - `d16_unorm_s8_uint`
- wants `stored_both` as well (since 1.47): the cores write a pixel's
planes where they lie in its four bytes, while a device that stores the
whole of a tile buffer, the V3D, writes one plane's pixels one after
another and so keeps only a format of that plane alone. There such an
op is `error_feature_not_present`, and a `d16_unorm` or an `s8_uint`
attachment keeps what it holds.

Two subpasses share a depth attachment either way. One right after the
other and with the same colour attachments too goes on in the tiles of
the first, which costs nothing at all. Otherwise - another subpass in
between, or other colour attachments, so that the tiles are gone - the
pass keeps it for them (since 1.52): the part that drew it last writes
it into the image's rows and the next one to name it reads it in, both
whatever the attachment's own ops say, those being for the whole pass.
So the depth of a pass over a scene is still there for a pass over it
again, with the colour of something else drawn between them.

That wants what keeping it always wants: a device whose `stored_depth`
is true for the depth and `stored_stencil` for the stencil - and
`stored_both` where the format holds both - and an image with memory
something is behind, which CreateFramebuffer holds to
(`error_feature_not_present` for a transient one, which has none).

Since 1.37 a subpass may read attachments as well as draw into them:
up to 8 `input_attachments`, each read pixel by pixel at the
fragment's own place (`shader.Resources.input`, `shader.Attachment`).
Such an attachment is read out of the image's memory, so its format is
one whose pixels are kept in rows - b8g8r8a8_unorm, r8g8b8a8_unorm or
r5g6b5_unorm_pack16, anything else being
`error_format_not_supported` - and what it holds is what an earlier
subpass drew, or what its load op left there.

**A depth attachment is read that way too** since 1.62
(`PhysicalDeviceFeatures.sampled_depth`): one plane of it, the one the
view's aspect names, the depth as 0 to 1 and the stencil as the whole
number it is (`CreateImageView`, `shader.Attachment`). Where an
earlier subpass drew that depth, the part which drew it last writes it
into the image's rows for this subpass to read, the way a depth two
subpasses share is kept (1.52): so it wants `stored_depth`, a stencil
`stored_stencil`, and a format holding both `stored_both`. The image
is one made IMAGE_USAGE_INPUT_ATTACHMENT, which for a depth means
memory behind it and not the tiles alone - a transient one is refused
(CreateImage).

**A subpass may read the colour attachment it is drawing into** since
1.64, which is Vulkan's self-dependency by region: the subpass names
one of its own colour attachments as an input attachment, and the pass
carries a `SubpassDependency` of that subpass on itself with
DEPENDENCY_BY_REGION. It is read as any input attachment is - the
`input_attachment` descriptor written with a view of it, and
`shader.Fragments.input` then `colorAt` at the fragment's own place -
and what it answers there is the tile, which already holds that pixel
(since 1.65). So programmable blending costs no copy here: the pixel
is where the tiles are.

Only the fragment's own pixel is read: the rest of the attachment is
in other tiles, drawn on other cores or not yet drawn, and reads as
transparent black - which is all Vulkan's by-region dependency
promises either. A subpass of several colour attachments drawn
together reads the first of them this way and no other; reading the
depth attachment it draws into is not among this.

Without that dependency, drawing into an attachment
and reading it in the same subpass is a loop, which is
`error_initialization_failed`, and only a device whose
`input_attachments` is true reads any - the cores, not the V3D -
others answering `error_feature_not_present`. The pass does not say
which descriptor a subpass reads one through: the set written with the
`input_attachment` descriptor does (UpdateDescriptorSets), and the
image wants IMAGE_USAGE_INPUT_ATTACHMENT (CreateImage).

A subpass of several colour attachments is drawn once for each, its commands
played over, so it costs that much more: its fragment function is called for
each, and `shader.Resources.output` says for which. A fixed fragment
function has one colour, which every attachment gets.

Since 1.51 such a subpass may be drawn **together** instead, in one
pass over the tiles: SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER in its
`flags`, facet.library's own, and every pipeline of it has a fragment
entry that writes exactly its colour attachments in the one call
(`shader.fragmentOutputs`, `shader.Fragments.colorsOf`); one that does
not is `error_invalid_shader_nv` (CreateGraphicsPipelines). The
vertices are worked once, the triangles binned once and a quad's
fragment function called once for all of them - a G-buffer's three or
four planes for the price of one - and each attachment is still
blended its own way, into a plane of each tile's own. The flag wants a
device whose `several_outputs` is true: the cores, not the V3D, whose
fragment programs are the fixed forms and each write the one colour;
there it is `error_feature_not_present`, and a subpass without it is
drawn as it always was. Any other bit in `flags` is
`error_feature_not_present` too.

Attachments a subpass does not name are left as they are. The
dependencies say nothing of what waits for what - a queue's commands
are done one after the other - and are read for one thing alone: a
subpass's dependency on itself by region, which lets it read the
attachment it draws into (since 1.64).

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The render pass is the caller's, until DestroyRenderPass. The arrays
in `info` are read during the call alone.

**NOTES**

LOAD and DONT_CARE are the same: a tile nothing is drawn into is
neither read nor written, so keeping costs nothing there, where clearing
writes every tile.

**BUGS**

None known.

**SEE ALSO**

`CreateFramebuffer`, `CmdBeginRenderPass`, `DestroyRenderPass`

**EXAMPLES**

```zig
const color = facet.AttachmentDescription{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .present_src };
const color_ref = facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
const subpass = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&color_ref) };
var pass: ?*facet.RenderPass = null;
_ = fb.CreateRenderPass(device, &.{ .attachment_count = 1, .attachments = @ptrCast(&color), .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &pass);
```

## CreateSampler

A sampler: the filter, the levels, the edges and the comparison a texture bound beside it is sampled with.

**SYNOPSIS**

```zig
fn CreateSampler(base: *FacetBase, device: *facet.Device, info: *const facet.SamplerCreateInfo, sampler: *?*facet.Sampler) facet.Result
```

**SINCE**

1.28. LVO -448.

**INPUTS**

- `device` - the device.
- `info` - the filters, the mipmap mode, the three address modes, the
  bias and clamp on the level, the anisotropy, the comparison and the
  border colour.
- `sampler` - where the sampler is written; null when it fails.

**RESULT**

`success`; `error_feature_not_present` for an address mode that is
none of Vulkan's five, for a filter, mipmap mode, compare operation or
border colour that is not one of Vulkan's, or for
`unnormalized_coordinates` on a device that reads none
(`PhysicalDeviceFeatures.unnormalized_coordinates`);
`error_initialization_failed` for `unnormalized_coordinates` asked for
beside something Vulkan does not allow with it;
`error_out_of_host_memory`.

**BEHAVIOR**

The sampler holds what it was given, in the terms the sampling is
written in (`texture.Sampler`): nothing is worked out again for each
sample.

`max_anisotropy` is held to `PhysicalDeviceLimits.max_sampler_anisotropy`
rather than refused above it, and is taken only where
`PhysicalDeviceFeatures.sampler_anisotropy` says so; without
`anisotropy_enable` it is 1, one sample. `max_lod` below `min_lod`
leaves the sample on `min_lod`. `compare_enable` makes every sample
through it a shadow sample: what is read is compared with the reference
the fragment function carries, and what comes out is how much of the
sample passed, not a colour.

`unnormalized_coordinates` places the sample in texels of the texture
rather than 0 to 1 across it, for a program that reads a texture as a
table of values (since 1.67). Vulkan asks five things of such a
sampler, and all five are held to here, an
`error_initialization_failed` for each:
- one filter for both: `mag_filter` and `min_filter` the same. Which of
  the two a sample would take is worked out from how fast the
  coordinates change, which says nothing in texels - so Vulkan has
  them equal and the question does not arise.
- `mipmap_mode` `nearest`, and `min_lod` and `max_lod` both 0: the
  first level and no other, the coordinates being that level's texels.
- no `anisotropy_enable`: one sample.
- no `compare_enable`: a colour and not a comparison.
- `address_mode_u` and `address_mode_v` either `clamp_to_edge` or
  `clamp_to_border`. `address_mode_w` is taken as it is given: Vulkan
  has no 3D texture read this way at all, and a 3D texture's `r` is
  counted in slices here, which is the library's own answer.

All five of Vulkan's address modes are taken, `mirror_clamp_to_edge`
among them since 1.49: the texture turned round once below 0 and held
at its edge past the far side. The three border colours are Vulkan's
six: an int border and a float border are the same here, a texel being
read as 0 to 1 whatever its format, and Vulkan 1.0 has no border but
transparent black, opaque black and opaque white.

A sampler is made on either device, but is read by the sampling the
cores do: a pipeline whose fragment form samples through one
(`shader.FixedKind.texture_sampled`, `texture_shadow`, since 1.49
`texture_array_sampled`, `texture_cube_sampled` and `texture_3d_sampled`,
and since 1.53 `texture_cube_array_sampled`)
is refused on a device whose `PhysicalDeviceFeatures.samplers` is false.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The sampler is the caller's, until DestroySampler. It has to last as
long as the sets written with it are drawn with: a set holds the
address of what it keeps.

**NOTES**

The sampler is read by every core that samples through it at once, and
written by nothing after it is made.

**BUGS**

None known.

**SEE ALSO**

`DestroySampler`, `UpdateDescriptorSets`, `CreateDescriptorSetLayout`

**EXAMPLES**

```zig
var sampler: ?*facet.Sampler = null;
_ = fb.CreateSampler(device, &.{
    .mipmap_mode = .linear,
    .address_mode_u = .clamp_to_edge,
    .address_mode_v = .clamp_to_edge,
    .max_lod = facet.texture.lod_unclamped,
    .anisotropy_enable = true,
    .max_anisotropy = 4,
}, &sampler);

// A table of values, read at the texel the coordinates name.
var table: ?*facet.Sampler = null;
_ = fb.CreateSampler(device, &.{
    .mag_filter = .nearest,
    .min_filter = .nearest,
    .address_mode_u = .clamp_to_edge,
    .address_mode_v = .clamp_to_edge,
    .unnormalized_coordinates = true,
}, &table);
```

## CreateScreenSurface

A surface over a screen the program has opened, written to `surface`.

**SYNOPSIS**

```zig
fn CreateScreenSurface(base: *FacetBase, instance: *facet.Instance, info: *const facet.ScreenSurfaceCreateInfo, surface: *?*facet.Surface) facet.Result
```

**SINCE**

1.0. LVO -320.

**INPUTS**

- `instance` - the instance.
- `info` - the screen, the whole of which the surface is.
- `surface` - where the surface goes; null when none was made.

**RESULT**

`success`; `error_initialization_failed` without intuition.library, or
without rtg.library 1.5 or newer; `error_out_of_host_memory`.

**BEHAVIOR**

A swapchain made on the surface has the screen's buffers as its
images: the first is the screen's own buffer, the one its bar and windows
are drawn in, and the rest are made in the display's memory as
AllocScreenBuffer makes them. Presenting an image is ChangeScreenBuffer:
the display takes it up at the start of its next frame. The screen can be
pulled down, put behind another and brought forward as before.

intuition.library and rtg.library are opened for as long as the surface
lasts.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The surface is the caller's, to give back with `DestroySurface` before
the screen closes and before the instance goes. The screen stays the
caller's.

**NOTES**

A screen whose pixels are neither 32 bits nor 565 has no format
facet.library draws in: GetPhysicalDeviceSurfaceFormats lists none for
it.

**BUGS**

None known.

**SEE ALSO**

`DestroySurface`, `GetPhysicalDeviceSurfaceCapabilities`, `CreateSwapchain`

**EXAMPLES**

```zig
var surface: ?*facet.Surface = null;
if (fb.CreateScreenSurface(instance, &.{ .screen = screen }, &surface) != .success) return error.NoSurface;
defer fb.DestroySurface(instance, surface);
```

## CreateSemaphore

A semaphore: signalled by one submission, waited for by another.

**SYNOPSIS**

```zig
fn CreateSemaphore(base: *FacetBase, device: *facet.Device, info: *const facet.SemaphoreCreateInfo, semaphore: *?*facet.Semaphore) facet.Result
```

**SINCE**

1.0. LVO -196.

**INPUTS**

- `device` - the device.
- `info` - 0 for its flags.
- `semaphore` - where the semaphore is written; null when it fails.

**RESULT**

`success`; `error_out_of_host_memory`.

**BEHAVIOR**

A semaphore is an exec waitable, unsignalled at first. A submission
that waits for it takes the signal: each signal lets one go.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The semaphore is the caller's, until DestroySemaphore.

**NOTES**

What a swapchain's image becoming free signals, and a frame's drawing
waits for before it starts.

**BUGS**

None known.

**SEE ALSO**

`DestroySemaphore`, `QueueSubmit`

**EXAMPLES**

```zig
var drawn: ?*facet.Semaphore = null;
if (fb.CreateSemaphore(device, &.{}, &drawn) != .success) return error.NoSemaphore;
```

## CreateShaderModule

A shader module: the vertex and fragment functions a `shader.Code` names.

**SYNOPSIS**

```zig
fn CreateShaderModule(base: *FacetBase, device: *facet.Device, info: *const facet.ShaderModuleCreateInfo, module: *?*facet.ShaderModule) facet.Result
```

**SINCE**

1.0. LVO -220.

**INPUTS**

- `device` - the device.
- `info` - `code`, a shader.Code, and its size.
- `module` - where the module is written; null when it fails.

**RESULT**

`success`; `error_invalid_shader_nv` for code that is not a
shader.Code - SPIR-V among it - or an entry of a stage that is neither
vertex nor fragment, or with more varyings than a vertex carries;
`error_out_of_host_memory`. Two stages carry something else in that
word: a compute entry its workgroup (`shader.computeGroup`), and a
tessellation control entry the floats its patch carries to its
evaluation function (`shader.control`, since 1.50). What those may
hold is CreateComputePipelines' and CreateGraphicsPipelines' to say.

**BEHAVIOR**

The entries are copied. The functions they name are the program's
own, compiled into it: CreateGraphicsPipelines takes a pipeline's from
them by stage and name.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The module is the caller's, until DestroyShaderModule. The code is
read during the call alone; the functions, and the names, have to last
as long as the module and the pipelines made from it - as the program's
code does.

**NOTES**

A shader runs on every core at once and on the queue's task: see
sdk.facet.shader for what it may do.

**BUGS**

None known.

**SEE ALSO**

`CreateGraphicsPipelines`, `DestroyShaderModule`

**EXAMPLES**

```zig
const entries = [_]facet.shader.Entry{
    facet.shader.vertex("main", &boxVertex, 2),
    facet.shader.fragment("main", &boxFragment, 2),
};
const code = facet.shader.Code{ .entry_count = entries.len, .entries = &entries };
var module: ?*facet.ShaderModule = null;
_ = fb.CreateShaderModule(device, &.{ .code = &code }, &module);
```

## CreateSwapchain

A swapchain on a surface, written to `swapchain`.

**SYNOPSIS**

```zig
fn CreateSwapchain(base: *FacetBase, device: *facet.Device, info: *const facet.SwapchainCreateInfo, swapchain: *?*facet.Swapchain) facet.Result
```

**SINCE**

1.0. LVO -344.

**INPUTS**

- `device` - the device whose queue presents its images.
- `info` - the surface, how many images at least, their format and size
  - the surface's own, as GetPhysicalDeviceSurfaceFormats and
  GetPhysicalDeviceSurfaceCapabilities give them - what they are used
  for, the present mode, and the swapchain before it, if any.
- `swapchain` - where the swapchain goes; null when none was made.

**RESULT**

`success`; `error_out_of_device_memory` when the display's memory has
no room for that many pictures; `error_native_window_in_use` when the
surface has a swapchain that is not `old_swapchain`;
`error_initialization_failed` for a size that is not the surface's;
`error_format_not_supported` for a format that is not its;
`error_feature_not_present` for a use, a present mode or layers it does
not have; `error_surface_lost` when the window the surface is over has
closed; `error_out_of_host_memory`.

**BEHAVIOR**

`min_image_count` images are made, at least one and at most four. On a
screen the first is the screen's own buffer, shown as the swapchain
starts; the rest are new buffers, black, made as AllocScreenBuffer makes
them. Each is an image of `rows`, bound already, its pixels the
buffer's: what is drawn into it is handed on to the display tile by tile
as the render pass ends.

`image_usage` may be COLOR_ATTACHMENT, TRANSFER_SRC and TRANSFER_DST,
in any mix (since 1.43): an image is drawn into through a render pass,
copied out of - a picture of the frame, taken with CmdCopyImageToBuffer
- and copied into. SAMPLED is not among them: a texture is kept in
blocks of texels, which a display's buffer is not. `present_mode` has
to be `fifo`: a buffer is shown from the display's next frame on, and
there is no way to ask a display for anything else.

`old_swapchain` is handed on: it hands out no more images
(AcquireNextImage answers `error_out_of_date`), and what it was given to
present is still shown. It is destroyed with DestroySwapchain as before.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The swapchain is the caller's, to give back with `DestroySwapchain`
before the surface goes. Its images are the swapchain's: they are not
bound, and not destroyed, by the program.

**NOTES**

A display's memory holds a few pictures, and every screen open takes
one: on a display with room for three - Workbench's, the program's screen
and one more - two images is all there is. A swapchain made while an
older one is there, even handed on from it, has none of its pictures:
make the new swapchain after destroying the old one where both would not
fit.

**BUGS**

None known.

**SEE ALSO**

`DestroySwapchain`, `GetSwapchainImages`, `AcquireNextImage`, `QueuePresent`

**EXAMPLES**

```zig
var swapchain: ?*facet.Swapchain = null;
const result = fb.CreateSwapchain(device, &.{
    .surface = surface.?,
    .min_image_count = 2,
    .image_format = format.format,
    .image_extent = capabilities.current_extent,
}, &swapchain);
```

## CreateWindowSurface

A surface over the inside of a window the program has opened, written to `surface`.

**SYNOPSIS**

```zig
fn CreateWindowSurface(base: *FacetBase, instance: *facet.Instance, info: *const facet.WindowSurfaceCreateInfo, surface: *?*facet.Surface) facet.Result
```

**SINCE**

1.0. LVO -364.

**INPUTS**

- `instance` - the instance.
- `info` - the window, whose inside - within its border - the surface is.
- `surface` - where the surface goes; null when none was made.

**RESULT**

`success`; `error_initialization_failed` without intuition.library,
graphics.library, layers.library or rtg.library, or with an
intuition.library that does not number its windows (before 0.47);
`error_out_of_host_memory`.

**BEHAVIOR**

A swapchain made on the surface has pictures in memory as its images,
the size of the window inside its border when the swapchain is made.
Presenting one waits for the display's next frame and copies the picture
into the window, through the window's layer, which is held meanwhile:
what covers the window is left alone, and the board's engine does the
copying. Copied as the frame starts, the picture is in place before the
display reads that part of the screen, so the window never shows half of
one picture and half of the next; a present is shown a frame at most
after the one before. An image is free again as soon as it is copied, so
a swapchain of one image is drawn, copied and drawn again, and one of two
is drawn while the other waits for its frame.

The window can be moved, put behind others and brought forward while
the swapchain is in use: each picture lands where the window is then.
Once it is made bigger or smaller, the swapchain is out of date:
AcquireNextImage and QueuePresent answer `error_out_of_date`, and a new
swapchain of the new size is made, the old one handed to it as
`old_swapchain`. A picture presented after the window was made smaller
and before that is cut to the window's inside.

The window is found by its number (`WA_Number`) each time it is read or
drawn into, so a window that closes under the surface is never drawn
into once it has gone. That is what happens to a program that ends -
returns, or is stopped by a fault - with its window open while facet's
queue still has a frame of it to show: intuition closes the window, the
frame is not copied, and AcquireNextImage, QueuePresent, CreateSwapchain
and the surface queries answer `error_surface_lost` from then on. The
swapchain and the surface are still destroyed as before.

intuition.library, graphics.library, layers.library and rtg.library are
opened for as long as the surface lasts.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed; while the surface lasts, the calls that read or
  show on it take the screens' semaphore (`LockIBase`), so they are
  never made holding a layer's lock.
- Process: a Task will do.

**OWNERSHIP**

The surface is the caller's, to give back with `DestroySurface` before
the window closes and before the instance goes. The window stays the
caller's: its IDCMP messages, its gadgets and its border too. What the
program draws into the window's inside itself is drawn over by the next
picture.

**NOTES**

A window on a screen whose pixels are neither 32 bits nor 565 has no
format facet.library draws in: GetPhysicalDeviceSurfaceFormats lists
none for it. A simple-refresh window with `WA_NoCareRefresh` keeps no copy of its
covered parts, which the next picture draws anyway.

**BUGS**

None known.

**SEE ALSO**

`DestroySurface`, `CreateScreenSurface`, `CreateSwapchain`

**EXAMPLES**

```zig
var surface: ?*facet.Surface = null;
if (fb.CreateWindowSurface(instance, &.{ .window = window }, &surface) != .success) return error.NoSurface;
defer fb.DestroySurface(instance, surface);
```

## DestroyBuffer

The buffer given back.

**SYNOPSIS**

```zig
fn DestroyBuffer(base: *FacetBase, device: *facet.Device, buffer: ?*facet.Buffer) void
```

**SINCE**

1.0. LVO -80.

**INPUTS**

- `device` - the device it was made on.
- `buffer` - the buffer, or null, which does nothing.

**RESULT**

None.

**BEHAVIOR**

No work the queue has not finished may use it: wait for its fence
first. The memory it was bound into stays as it is.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The buffer is gone; its memory is still the caller's.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateBuffer`

**EXAMPLES**

```zig
fb.DestroyBuffer(device, vertices);
```

## DestroyBufferView

A buffer view given back.

**SYNOPSIS**

```zig
fn DestroyBufferView(base: *FacetBase, device: *facet.Device, view: ?*facet.BufferView) void
```

**SINCE**

1.32. LVO -496.

**INPUTS**

- `device` - the device it was made on.
- `view` - the view, or null, which does nothing.

**RESULT**

None.

**BEHAVIOR**

The view's memory is given back. The buffer it was made of is untouched:
a view holds none of its bytes.

A set a destroyed view was written into reads bytes that are no longer
a view's, as Vulkan has it: the program writes the set again, or does
not submit work that reads it.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The view is gone; nothing of the buffer is.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateBufferView`

**EXAMPLES**

```zig
fb.DestroyBufferView(device, view);
```

## DestroyCommandPool

The pool given back, and every command buffer allocated from it.

**SYNOPSIS**

```zig
fn DestroyCommandPool(base: *FacetBase, device: *facet.Device, pool: ?*facet.CommandPool) void
```

**SINCE**

1.0. LVO -124.

**INPUTS**

- `device` - the device it was made on.
- `pool` - the pool, or null, which does nothing.

**RESULT**

None.

**BEHAVIOR**

No buffer of it may be pending: wait for the fences of the work it was
submitted with first.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The pool and its command buffers are gone.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateCommandPool`, `FreeCommandBuffers`

**EXAMPLES**

```zig
fb.DestroyCommandPool(device, pool);
```

## DestroyDescriptorPool

The descriptor pool given back, and every set allocated from it.

**SYNOPSIS**

```zig
fn DestroyDescriptorPool(base: *FacetBase, device: *facet.Device, pool: ?*facet.DescriptorPool) void
```

**SINCE**

1.0. LVO -248.

**INPUTS**

- `device` - the device.
- `pool` - a pool CreateDescriptorPool made, or null, which does
  nothing.

**RESULT**

None.

**BEHAVIOR**

No command buffer still pending may have bound one of its sets.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The pool is gone, and its sets.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateDescriptorPool`, `ResetDescriptorPool`

**EXAMPLES**

```zig
fb.DestroyDescriptorPool(device, pool);
```

## DestroyDescriptorSetLayout

The descriptor set layout given back; the sets allocated with it stay.

**SYNOPSIS**

```zig
fn DestroyDescriptorSetLayout(base: *FacetBase, device: *facet.Device, layout: ?*facet.DescriptorSetLayout) void
```

**SINCE**

1.0. LVO -232.

**INPUTS**

- `device` - the device.
- `layout` - a layout CreateDescriptorSetLayout made, or null, which
  does nothing.

**RESULT**

None.

**BEHAVIOR**

A set keeps what it needs of its layout; so does a pipeline layout.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The layout is gone.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateDescriptorSetLayout`

**EXAMPLES**

```zig
fb.DestroyDescriptorSetLayout(device, set_layout);
```

## DestroyDevice

The device given back, and its queue's task ended.

**SYNOPSIS**

```zig
fn DestroyDevice(base: *FacetBase, device: ?*facet.Device) void
```

**SINCE**

1.0. LVO -48.

**INPUTS**

- `device` - a device CreateDevice made, or null, which does nothing.

**RESULT**

None.

**BEHAVIOR**

Everything made from the device has to be destroyed or freed first,
and its queue idle (DeviceWaitIdle). Memory not freed is left as it
is, and said so on the debug output.

**CONTEXT**

- Waits: for the queue's task to end.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The device is gone, and its queue with it.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateDevice`, `DestroyInstance`

**EXAMPLES**

```zig
fb.DestroyDevice(device);
```

## DestroyFence

The fence given back.

**SYNOPSIS**

```zig
fn DestroyFence(base: *FacetBase, device: *facet.Device, fence: ?*facet.Fence) void
```

**SINCE**

1.0. LVO -180.

**INPUTS**

- `device` - the device it was made on.
- `fence` - the fence, or null, which does nothing.

**RESULT**

None.

**BEHAVIOR**

No submission still to be done may signal it, and no task may be
waiting on it.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The fence is gone.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateFence`

**EXAMPLES**

```zig
fb.DestroyFence(device, frame_done);
```

## DestroyFramebuffer

The framebuffer given back.

**SYNOPSIS**

```zig
fn DestroyFramebuffer(base: *FacetBase, device: *facet.Device, framebuffer: ?*facet.Framebuffer) void
```

**SINCE**

1.0. LVO -216.

**INPUTS**

- `device` - the device.
- `framebuffer` - a framebuffer CreateFramebuffer made, or null, which
  does nothing.

**RESULT**

None.

**BEHAVIOR**

No command buffer still pending may draw into it. Its views stay.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The framebuffer is gone.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateFramebuffer`

**EXAMPLES**

```zig
fb.DestroyFramebuffer(device, frame);
```

## DestroyImage

The image given back.

**SYNOPSIS**

```zig
fn DestroyImage(base: *FacetBase, device: *facet.Device, image: ?*facet.Image) void
```

**SINCE**

1.0. LVO -96.

**INPUTS**

- `device` - the device it was made on.
- `image` - the image, or null, which does nothing.

**RESULT**

None.

**BEHAVIOR**

No work the queue has not finished may use it, and its views go
first. The memory it was bound into stays as it is. A swapchain's
image is left alone: it goes with the swapchain.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The image is gone; its memory is still the caller's.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateImage`, `DestroyImageView`

**EXAMPLES**

```zig
fb.DestroyImage(device, picture);
```

## DestroyImageView

The view given back.

**SYNOPSIS**

```zig
fn DestroyImageView(base: *FacetBase, device: *facet.Device, view: ?*facet.ImageView) void
```

**SINCE**

1.0. LVO -116.

**INPUTS**

- `device` - the device its image was made on.
- `view` - the view, or null, which does nothing.

**RESULT**

None.

**BEHAVIOR**

No work the queue has not finished may use it, nor a framebuffer or a
descriptor set still in use. The image stays as it is.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The view is gone.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateImageView`

**EXAMPLES**

```zig
fb.DestroyImageView(device, view);
```

## DestroyInstance

The instance given back.

**SYNOPSIS**

```zig
fn DestroyInstance(base: *FacetBase, instance: ?*facet.Instance) void
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `instance` - an instance CreateInstance made, or null, which does
  nothing.

**RESULT**

None.

**BEHAVIOR**

Every device and surface made from the instance has to be destroyed
first. One that is not is left as it is, with the instance under it,
and said so on the debug output: a device's queue's task may still be
running.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The instance is gone; so are its physical devices.

**NOTES**

The library may go once its last instance has: an Expunge it refused
while instances lasted is tried again when memory runs short.

**BUGS**

None known.

**SEE ALSO**

`CreateInstance`, `DestroyDevice`

**EXAMPLES**

```zig
fb.DestroyInstance(instance);
```

## DestroyPipeline

The pipeline given back: no submission still drawing with it.

**SYNOPSIS**

```zig
fn DestroyPipeline(base: *FacetBase, device: *facet.Device, pipeline: ?*facet.Pipeline) void
```

**SINCE**

1.0. LVO -272.

**INPUTS**

- `device` - the device.
- `pipeline` - a pipeline CreateGraphicsPipelines made, or null, which
  does nothing.

**RESULT**

None.

**BEHAVIOR**

No command buffer still pending may have bound it.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The pipeline is gone.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateGraphicsPipelines`

**EXAMPLES**

```zig
fb.DestroyPipeline(device, pipeline);
```

## DestroyPipelineLayout

The pipeline layout given back.

**SYNOPSIS**

```zig
fn DestroyPipelineLayout(base: *FacetBase, device: *facet.Device, layout: ?*facet.PipelineLayout) void
```

**SINCE**

1.0. LVO -240.

**INPUTS**

- `device` - the device.
- `layout` - a layout CreatePipelineLayout made, or null, which does
  nothing.

**RESULT**

None.

**BEHAVIOR**

The pipelines made with it stay.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The layout is gone.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreatePipelineLayout`

**EXAMPLES**

```zig
fb.DestroyPipelineLayout(device, layout);
```

## DestroyQueryPool

The pool given back.

**SYNOPSIS**

```zig
fn DestroyQueryPool(base: *FacetBase, device: *facet.Device, pool: ?*facet.QueryPool) void
```

**SINCE**

1.29. LVO -460.

**INPUTS**

- `device` - the device it was made on.
- `pool` - the pool, or null, which does nothing.

**RESULT**

None.

**BEHAVIOR**

No command buffer that names it may be pending: the queue's task and the
cores that draw the tiles write its values as the work is done.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The pool is gone.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateQueryPool`

**EXAMPLES**

```zig
fb.DestroyQueryPool(device, counted);
```

## DestroyRenderPass

The render pass given back.

**SYNOPSIS**

```zig
fn DestroyRenderPass(base: *FacetBase, device: *facet.Device, render_pass: ?*facet.RenderPass) void
```

**SINCE**

1.0. LVO -208.

**INPUTS**

- `device` - the device.
- `render_pass` - a render pass CreateRenderPass made, or null, which does
  nothing.

**RESULT**

None.

**BEHAVIOR**

No command buffer still pending may have recorded it. The framebuffers
and pipelines made for it stay.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The render pass is gone.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateRenderPass`

**EXAMPLES**

```zig
fb.DestroyRenderPass(device, pass);
```

## DestroySampler

The sampler given back.

**SYNOPSIS**

```zig
fn DestroySampler(base: *FacetBase, device: *facet.Device, sampler: ?*facet.Sampler) void
```

**SINCE**

1.28. LVO -452.

**INPUTS**

- `device` - the device it was made on.
- `sampler` - the sampler, or null, which does nothing.

**RESULT**

None.

**BEHAVIOR**

No set written with it may be drawn with any more, and no command
buffer that bound such a set may be pending: a set holds the address of
what the sampler keeps, and the draws read it as they run.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The sampler is gone.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateSampler`

**EXAMPLES**

```zig
fb.DestroySampler(device, sampler);
```

## DestroySemaphore

The semaphore given back.

**SYNOPSIS**

```zig
fn DestroySemaphore(base: *FacetBase, device: *facet.Device, semaphore: ?*facet.Semaphore) void
```

**SINCE**

1.0. LVO -200.

**INPUTS**

- `device` - the device it was made on.
- `semaphore` - the semaphore, or null, which does nothing.

**RESULT**

None.

**BEHAVIOR**

No submission still to be done may wait for it or signal it.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The semaphore is gone.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateSemaphore`

**EXAMPLES**

```zig
fb.DestroySemaphore(device, drawn);
```

## DestroyShaderModule

The shader module given back; the pipelines made from it stay.

**SYNOPSIS**

```zig
fn DestroyShaderModule(base: *FacetBase, device: *facet.Device, module: ?*facet.ShaderModule) void
```

**SINCE**

1.0. LVO -224.

**INPUTS**

- `device` - the device.
- `module` - a module CreateShaderModule made, or null, which does
  nothing.

**RESULT**

None.

**BEHAVIOR**

A pipeline keeps the functions it took from the module.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The module is gone.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateShaderModule`

**EXAMPLES**

```zig
fb.DestroyShaderModule(device, module);
```

## DestroySurface

The surface given back: every swapchain made on it destroyed first.

**SYNOPSIS**

```zig
fn DestroySurface(base: *FacetBase, instance: *facet.Instance, surface: ?*facet.Surface) void
```

**SINCE**

1.0. LVO -324.

**INPUTS**

- `instance` - the instance it was made from.
- `surface` - the surface; null does nothing.

**RESULT**

None.

**BEHAVIOR**

The libraries it opened are closed. A surface with a swapchain left is
kept as it is, and said so on the debug output.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The screen or window it was over stays open: it is the caller's.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateScreenSurface`, `CreateWindowSurface`, `DestroySwapchain`

**EXAMPLES**

```zig
fb.DestroySurface(instance, surface);
```

## DestroySwapchain

The swapchain given back, and its images.

**SYNOPSIS**

```zig
fn DestroySwapchain(base: *FacetBase, device: *facet.Device, swapchain: ?*facet.Swapchain) void
```

**SINCE**

1.0. LVO -348.

**INPUTS**

- `device` - the device it was made with.
- `swapchain` - the swapchain; null does nothing.

**RESULT**

None.

**BEHAVIOR**

What the device's queue still has to do is done first, the images it
was given to present shown. On a screen the screen's own buffer is shown
again, and the buffers made for the swapchain are freed.

**CONTEXT**

- Waits: for the queue's work, and for the display's next frame where
  the screen's own buffer is shown again.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The framebuffers and views made of its images go first: the images go
with it.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateSwapchain`

**EXAMPLES**

```zig
fb.DestroySwapchain(device, swapchain);
```

## DeviceWaitIdle

Wait until every queue of the device has done all it was given.

**SYNOPSIS**

```zig
fn DeviceWaitIdle(base: *FacetBase, device: *facet.Device) facet.Result
```

**SINCE**

1.0. LVO -172.

**INPUTS**

- `device` - the device.

**RESULT**

`success`; `error_device_lost` once the device is lost. The queue is idle
either way.

**BEHAVIOR**

QueueWaitIdle on its queue; at once for a device without one.

**CONTEXT**

- Waits: yes, on the queue's idle waitable.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

None.

**NOTES**

What a program does before it destroys what its work uses, and the device.

**BUGS**

None known.

**SEE ALSO**

`QueueWaitIdle`, `DestroyDevice`

**EXAMPLES**

```zig
_ = fb.DeviceWaitIdle(device);
fb.DestroyDevice(device);
```

## EndCommandBuffer

The command buffer's recording ended: it can be submitted.

**SYNOPSIS**

```zig
fn EndCommandBuffer(base: *FacetBase, buffer: *facet.CommandBuffer) facet.Result
```

**SINCE**

1.0. LVO -144.

**INPUTS**

- `buffer` - a command buffer recording.

**RESULT**

`success`; `error_out_of_host_memory` when memory ran out for a command
while it recorded; `error_feature_not_present` when a command asked for
more than the library draws, as CmdDraw does of more vertices than a draw
works. Either way the buffer cannot be submitted, and is recorded again
after a reset; `error_initialization_failed` for a buffer not recording.

**BEHAVIOR**

The buffer is executable: QueueSubmit plays it, as often as it is submitted.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The buffer stays its pool's.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`BeginCommandBuffer`, `QueueSubmit`

**EXAMPLES**

```zig
if (fb.EndCommandBuffer(commands) != .success) return error.NoRecording;
```

## EnumeratePhysicalDevices

The instance's physical devices.

**SYNOPSIS**

```zig
fn EnumeratePhysicalDevices(base: *FacetBase, instance: *facet.Instance, count: *u32, devices: ?[*]*facet.PhysicalDevice) facet.Result
```

**SINCE**

1.0. LVO -28.

**INPUTS**

- `instance` - the instance.
- `count` - with `devices`, how many it has room for; written with
  how many there are, or with how many it was given.
- `devices` - where they go; null to count them alone.

**RESULT**

`success`, or `incomplete` when `devices` was too short for them all.

**BEHAVIOR**

The machine's cores come first, drawing through the rasterizer. On a
machine with a GPU facet.library drives - the V3D of a Raspberry Pi 5 or
a Compute Module 5 - that follows, which draws with fixed forms of
fragment function alone (`shader.fixedFragment`). A program whose
fragment functions are all of those takes the last device listed, and
has the GPU where there is one and the cores where not.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

A physical device is the instance's, and goes with it.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`GetPhysicalDeviceProperties`, `CreateDevice`

**EXAMPLES**

```zig
var count: u32 = 1;
var physical: [1]*facet.PhysicalDevice = undefined;
_ = fb.EnumeratePhysicalDevices(instance, &count, &physical);
if (count == 0) return error.NoDevice;
```

## FreeCommandBuffers

Command buffers given back to the pool they came from.

**SYNOPSIS**

```zig
fn FreeCommandBuffers(base: *FacetBase, device: *facet.Device, pool: *facet.CommandPool, count: u32, buffers: [*]const ?*facet.CommandBuffer) void
```

**SINCE**

1.0. LVO -136.

**INPUTS**

- `device` - the device.
- `pool` - the pool they were allocated from.
- `count` - how many.
- `buffers` - the buffers; a null among them is passed over.

**RESULT**

None.

**BEHAVIOR**

None of them may be pending. What they recorded goes with them.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The buffers are gone.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`AllocateCommandBuffers`, `DestroyCommandPool`

**EXAMPLES**

```zig
fb.FreeCommandBuffers(device, pool.?, 1, &commands);
```

## FreeDescriptorSets

`count` descriptor sets given back to the pool they came from.

**SYNOPSIS**

```zig
fn FreeDescriptorSets(base: *FacetBase, device: *facet.Device, pool: *facet.DescriptorPool, count: u32, sets: [*]const ?*facet.DescriptorSet) facet.Result
```

**SINCE**

1.0. LVO -260.

**INPUTS**

- `device` - the device.
- `pool` - the pool they were allocated from.
- `count`, `sets` - the sets; a null among them is passed over.

**RESULT**

`success`.

**BEHAVIOR**

No command buffer still pending may have bound one of them.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The sets are gone, and the pool may give out as many again.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`AllocateDescriptorSets`, `ResetDescriptorPool`

**EXAMPLES**

```zig
_ = fb.FreeDescriptorSets(device, pool.?, 1, @ptrCast(&set));
```

## FreeMemory

The block given back.

**SYNOPSIS**

```zig
fn FreeMemory(base: *FacetBase, device: *facet.Device, memory: ?*facet.DeviceMemory) void
```

**SINCE**

1.0. LVO -60.

**INPUTS**

- `device` - the device it was allocated from.
- `memory` - the block, or null, which does nothing.

**RESULT**

None.

**BEHAVIOR**

A mapping of it ends with it. Nothing bound into it may be in use by
work the queue has not finished: wait for its fence first.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: exec's memory list.
- Process: a Task will do.

**OWNERSHIP**

The block is gone. The buffers and images bound into it stay, and may
only be destroyed.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`AllocateMemory`

**EXAMPLES**

```zig
fb.FreeMemory(device, memory);
```

## GetBufferMemoryRequirements

What the buffer needs of the memory it is bound into.

**SYNOPSIS**

```zig
fn GetBufferMemoryRequirements(base: *FacetBase, device: *facet.Device, buffer: *facet.Buffer, requirements: *facet.MemoryRequirements) void
```

**SINCE**

1.0. LVO -84.

**INPUTS**

- `device` - the device it was made on.
- `buffer` - the buffer.
- `requirements` - where they are written.

**RESULT**

None.

**BEHAVIOR**

Its size rounded up to 16 bytes, an offset aligned to 16, and any
memory type with memory behind it: not the lazily allocated one.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

`requirements` is the caller's.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`BindBufferMemory`, `AllocateMemory`

**EXAMPLES**

```zig
var needs: facet.MemoryRequirements = undefined;
fb.GetBufferMemoryRequirements(device, vertices, &needs);
```

## GetDeviceMemoryCommitment

How many bytes of a block the device has really put behind it.

**SYNOPSIS**

```zig
fn GetDeviceMemoryCommitment(base: *FacetBase, device: *facet.Device, memory: *facet.DeviceMemory, bytes: *u64) void
```

**SINCE**

1.36. LVO -512.

**INPUTS**

- `device` - the device the block was allocated on.
- `memory` - a block AllocateMemory gave.
- `bytes` - where the answer is written.

**BEHAVIOR**

A block of the lazily allocated type has nothing behind it at all, so
0 is its answer however much was asked for: the transient attachments
bound into it live in the device's tiles and never in memory. Every
other block is whole from the moment it is allocated, so its answer is
its `allocation_size`, as AllocateMemory was given it.

**RESULT**

None.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

`bytes` is the caller's.

**NOTES**

Vulkan asks this of lazily allocated memory alone, and leaves the rest
undefined; here every block answers.

**BUGS**

None known.

**SEE ALSO**

`AllocateMemory`, `GetPhysicalDeviceMemoryProperties`, `CreateImage`

**EXAMPLES**

```zig
var bytes: u64 = 0;
fb.GetDeviceMemoryCommitment(device, block.?, &bytes);
// 0 for the lazily allocated type: nothing is behind it.
```

## GetDeviceQueue

A queue the device was made with.

**SYNOPSIS**

```zig
fn GetDeviceQueue(base: *FacetBase, device: *facet.Device, family: u32, index: u32, queue: *?*facet.Queue) void
```

**SINCE**

1.0. LVO -52.

**INPUTS**

- `device` - the device.
- `family` - the queue's family: 0.
- `index` - which of the family's queues: 0.
- `queue` - where the queue is written; null for one the device was
  not made with.

**RESULT**

None.

**BEHAVIOR**

The same queue each time it is asked for.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The queue is the device's, and goes with it.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateDevice`, `QueueSubmit`

**EXAMPLES**

```zig
var queue: ?*facet.Queue = null;
fb.GetDeviceQueue(device, 0, 0, &queue);
```

## GetFenceStatus

Whether a fence is signalled, without waiting.

**SYNOPSIS**

```zig
fn GetFenceStatus(base: *FacetBase, device: *facet.Device, fence: *facet.Fence) facet.Result
```

**SINCE**

1.0. LVO -188.

**INPUTS**

- `device` - the device it was made on.
- `fence` - the fence.

**RESULT**

`success` for a signalled fence, `not_ready` for one not yet;
`error_device_lost` once the device is lost.

**BEHAVIOR**

Nothing changes: the fence stays as it is.

**CONTEXT**

- Waits: no.
- Interrupts: yes: it only reads.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

None.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`WaitForFences`

**EXAMPLES**

```zig
const ready = fb.GetFenceStatus(device, frame_done.?) == .success;
```

## GetImageMemoryRequirements

What the image needs of the memory it is bound into.

**SYNOPSIS**

```zig
fn GetImageMemoryRequirements(base: *FacetBase, device: *facet.Device, image: *facet.Image, requirements: *facet.MemoryRequirements) void
```

**SINCE**

1.0. LVO -100.

**INPUTS**

- `device` - the device it was made on.
- `image` - the image.
- `requirements` - where they are written.

**RESULT**

None.

**BEHAVIOR**

An offset aligned to a cache line, 64 bytes. A texture's size is its
levels in blocks, an 8888 texel at 8 bytes; rows' are their pitch, the
width rounded up to a cache line, times the height. A depth attachment
may be in any memory type, the lazily allocated one too, and nothing
of its memory is touched; every other image needs a type with memory
behind it.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

`requirements` is the caller's.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`BindImageMemory`, `AllocateMemory`

**EXAMPLES**

```zig
var needs: facet.MemoryRequirements = undefined;
fb.GetImageMemoryRequirements(device, picture, &needs);
```

## GetImageSubresourceLayout

Where a level of an image lies in its memory, and how its rows do.

**SYNOPSIS**

```zig
fn GetImageSubresourceLayout(base: *FacetBase, device: *facet.Device, image: *facet.Image, subresource: *const facet.ImageSubresource, layout: *facet.SubresourceLayout) void
```

**SINCE**

1.0. LVO -108.

**INPUTS**

- `device` - the device it was made on.
- `image` - the image.
- `subresource` - which level: 0 for an image in rows.
- `layout` - where its layout is written.

**RESULT**

None.

**BEHAVIOR**

For an image in rows - a linear image, and an attachment - the offset
is 0, `row_pitch` the bytes from one row to the next, `size` the pitch
times the height: with its memory mapped, the program reads and writes
the pixels there. For a texture it is where the level starts and how
many bytes it takes, its rows not the program's to know (`row_pitch`
0). A depth attachment answers since 1.63, its rows being real and
its levels its own: the offset is where the level of the layer begins,
`row_pitch` that level's own pitch, `size` what the level takes and
`array_pitch` the whole pyramid one layer holds. One with nothing
behind it - a transient one, which lives in the tiles - answers all 0,
as does a level or a layer it has not got.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

`layout` is the caller's.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateImage`, `MapMemory`

**EXAMPLES**

```zig
var layout: facet.SubresourceLayout = undefined;
fb.GetImageSubresourceLayout(device, picture, &.{}, &layout);
const row = pixels + y * layout.row_pitch;
```

## GetPhysicalDeviceFeatures

What a physical device does, so that a program may ask before it is refused.

**SYNOPSIS**

```zig
fn GetPhysicalDeviceFeatures(base: *FacetBase, physical: *facet.PhysicalDevice, features: *facet.PhysicalDeviceFeatures) void
```

**SINCE**

1.24. LVO -432.

**INPUTS**

- `physical` - a physical device EnumeratePhysicalDevices listed.
- `features` - where they are written.

**RESULT**

None.

**BEHAVIOR**

Every field is what the device's driver said of it as the instance was
made, and holds while the instance lasts. A `false` is what a create call
would answer `error_feature_not_present` to, so a program may choose
another way instead of failing; a `true` is a promise for this device, not
for the next one listed.

Sixteen of the fields differ between the devices of one machine, and are
the reason to look. `own_fragment_functions`, `sampling_format`,
`depth_prepass`, `discarding_fragment_forms`, `input_attachments`,
`sampled_depth`, `storage_images`, `samplers`, `sampler_anisotropy`,
`pipeline_statistics_queries`, `kept_compressed`, `kept_floats`,
`cube_arrays` and `stored_both` are the cores' and not the V3D's.
`compute_on_device` and `tessellation_on_device` are the cores' too, and
for the plain reason that the cores are that device: both kinds of work
run on them whichever device made the pipeline, so on the V3D they are
false while the work still happens. The limits say the rest of
what parts differ: a CM5's V3D takes one sampled image a stage where the
cores take sixteen (`GetPhysicalDeviceProperties`).

What the library has no call for at all - samplers, events, query pools, a
pipeline cache, sparse memory - has no field here. That a call is missing
is in the jump table, not in a feature.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

`features` is the caller's.

**NOTES**

The devices are listed with the cores first, so a program that wants the
GPU looks for one whose features suit it rather than taking the first.

**BUGS**

None known.

**SEE ALSO**

`EnumeratePhysicalDevices`, `GetPhysicalDeviceProperties`, `CreateGraphicsPipelines`

**EXAMPLES**

```zig
var features: facet.PhysicalDeviceFeatures = undefined;
fb.GetPhysicalDeviceFeatures(physical, &features);
if (!features.own_fragment_functions) {
    // This device runs only the fixed forms: shader.fixedFragment.
}
```

## GetPhysicalDeviceFormatProperties

What the device does with a format, in each tiling and in a buffer.

**SYNOPSIS**

```zig
fn GetPhysicalDeviceFormatProperties(base: *FacetBase, physical: *facet.PhysicalDevice, format: facet.Format, properties: *facet.FormatProperties) void
```

**SINCE**

1.0. LVO -72.

**INPUTS**

- `physical` - a physical device EnumeratePhysicalDevices listed.
- `format` - the format.
- `properties` - where its features are written: none for a format
  facet.library does not know.

**RESULT**

None.

**BEHAVIOR**

- B8G8R8A8_UNORM and R8G8B8A8_UNORM: colour attachments, blended, in
  either tiling; sampled, filtered, in optimal tiling; copied to and
  from; a vertex's value.
- R5G6B5_UNORM_PACK16: colour attachments, blended, in either tiling;
  sampled, filtered, in optimal tiling; copied.
- D16_UNORM: a depth attachment, in optimal tiling.
- R32_SFLOAT to R32G32B32A32_SFLOAT: a vertex's value.
- R8_UNORM: sampled, filtered, written through as a storage image, in
  optimal tiling, and copied both ways. One byte a texel, read as
  (red, 0, 0, 1) (`PhysicalDeviceFeatures.small_texels`, since 1.48);
  never an attachment and never a buffer's.
- BC1, BC2, BC3, R16G16B16A16_SFLOAT, R32G32B32A32_SFLOAT,
  B10G11R11_UFLOAT and E5B9G9R9_UFLOAT: sampled, filtered, in optimal
  tiling, and copied into. A device that samples such a texel where it
  lies keeps it as it was copied in and is copied out of as well
  (`kept_compressed` since 1.44, `kept_floats` since 1.45, and
  TRANSFER_SRC here says which); one that does not keeps it as 8 bits a
  channel, floats cut to 0 to 1, taking B8G8R8A8's memory and holding
  no more than it.
- ETC2 and EAC - ETC2_R8G8B8, ETC2_R8G8B8A1, ETC2_R8G8B8A8, EAC_R11 and
  EAC_R11G11: sampled, filtered, in optimal tiling, and copied into.
  No sampler of this library reads such a block, so they are always
  unpacked to 8 bits a channel and never copied out of (since 1.46).

An image to be sampled may have sides of any size (since 1.42). One of
B8G8R8A8 or R8G8B8A8 may keep its texel in the 32 bits of its word
rather than spread over 64 (IMAGE_CREATE_PACKED_TEXELS, since 1.48);
the format's features are the same either way.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

`properties` is the caller's.

**NOTES**

A colour attachment is not sampled as well: the two lie differently in
memory (CreateImage).

**BUGS**

None known.

**SEE ALSO**

`CreateImage`

**EXAMPLES**

```zig
var properties: facet.FormatProperties = undefined;
fb.GetPhysicalDeviceFormatProperties(physical, .r5g6b5_unorm_pack16, &properties);
const can_sample = properties.optimal_tiling_features & facet.FORMAT_FEATURE_SAMPLED_IMAGE != 0;
```

## GetPhysicalDeviceImageFormatProperties

The largest image of a format, type, tiling and usage, or `error_format_not_supported` where there is no such image at all.

**SYNOPSIS**

```zig
fn GetPhysicalDeviceImageFormatProperties(base: *FacetBase, physical: *facet.PhysicalDevice, format: facet.Format, image_type: facet.ImageType, tiling: facet.ImageTiling, usage: u32, flags: u32, properties: *facet.ImageFormatProperties) facet.Result
```

**SINCE**

1.36. LVO -504.

**INPUTS**

- `physical` - a physical device EnumeratePhysicalDevices listed.
- `format` - the format the image would be made with.
- `image_type` - `2d` or `3d`; `1d` has no images.
- `tiling` - `optimal` or `linear`.
- `usage` - the IMAGE_USAGE_* bits it would be made with.
- `flags` - the IMAGE_CREATE_* flags, CUBE_COMPATIBLE among them.
- `properties` - where the answer is written; zeroed where there is
  no such image.

**RESULT**

`success`, or `error_format_not_supported` where CreateImage would
refuse every image of that shape, whatever its extent.

**BEHAVIOR**

The question is asked of the same rules CreateImage keeps: the image
of the largest extent is laid out by the very code CreateImage lays
an image out with, so an extent inside what is answered here is made
and one outside it is refused.

What is answered, from the device's own limits
(GetPhysicalDeviceProperties) and from what CreateImage takes of
them:
- `max_extent`: `max_image_dimension_2d` square for a 2D image -
  8192 on this machine's devices - `max_image_dimension_3d` cubed for
  a 3D one, 256, and 1 deep for every other.
- `max_mip_levels`: the levels of `max_extent`, as many as halving
  its longest side gives, where the shape takes levels - a sampled
  image, one written through, a depth attachment since 1.63, and a 3D
  image whose slices have levels of their own - and 1 where it does
  not, which is a colour attachment and rows.
- `max_array_layers`: `max_image_array_layers`, 256, where the shape
  takes layers - an image a function reads or writes, a sampled or
  read-back depth attachment among them - and 1 for every other
  shape, a 3D image's layers being its depth.
- `sample_counts`: 1, one sample a pixel.
- `max_resource_size`: the bytes an image of all of the above takes,
  every level of every layer of it (since 1.66), which is what
  GetImageMemoryRequirements answers for such an image. It may be
  more memory than any heap holds: AllocateMemory is what finds that
  out.

An image to be sampled may have sides of any size (since 1.42); its
levels are as many as halving the longer side gives, which
`max_mip_levels` says.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

`properties` is the caller's.

**NOTES**

A format may be sampled and drawn into without one image being both:
the two lie differently in memory, so the usages are asked about one
at a time, as CreateImage takes them.

Until 1.66 `max_resource_size` was the largest heap's bytes, which is
a fact about the memory and not about the image, and the levels and
the layers were worked out from the kind of image rather than asked
of CreateImage - so a depth attachment answered one level where 1.63
had given it as many as a colour one has, a sampled depth attachment
answered one layer where 1.58 had given it 256, and a 3D image
answered one level where its slices have their own.

**BUGS**

None known.

**SEE ALSO**

`CreateImage`, `GetPhysicalDeviceFormatProperties`, `GetPhysicalDeviceProperties`

**EXAMPLES**

```zig
var properties: facet.ImageFormatProperties = undefined;
const answer = fb.GetPhysicalDeviceImageFormatProperties(physical, .b8g8r8a8_unorm, .@"2d", .optimal, facet.IMAGE_USAGE_SAMPLED, 0, &properties);
if (answer == .success) {
    // 8192 x 8192, 14 levels, 256 layers.
    const side = properties.max_extent.width;
    _ = side;
}
```

## GetPhysicalDeviceMemoryProperties

The physical device's memory types and heaps.

**SYNOPSIS**

```zig
fn GetPhysicalDeviceMemoryProperties(base: *FacetBase, physical: *facet.PhysicalDevice, properties: *facet.PhysicalDeviceMemoryProperties) void
```

**SINCE**

1.0. LVO -40.

**INPUTS**

- `physical` - a physical device EnumeratePhysicalDevices listed.
- `properties` - where they are written.

**RESULT**

None.

**BEHAVIOR**

The heaps are made from exec's memory regions as the instance was
made, in the order exec prefers them: each set of MEMF_INTERNAL,
MEMF_EXTERNAL and MEMF_DMA that a region has is a heap, as large as
its regions together, its attributes in `MemoryHeap.attributes`, with
a memory type of its own in the same place. Every one of those types
is DEVICE_LOCAL, HOST_VISIBLE and HOST_COHERENT - the device is the
processor - and HOST_CACHED where its regions are behind the data
cache (MEMF_EXTERNAL), MEMORY_PROPERTY_DMA where a DMA engine reaches
them (MEMF_DMA). The last type is DEVICE_LOCAL and LAZILY_ALLOCATED:
memory with nothing behind it, for an attachment that lives only in
the tiles, such as a depth a render pass clears and does not store.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

`properties` is the caller's.

**NOTES**

On a RISC-V 64 machine the RAM below 4 GiB is MEMF_DMA and the RAM
above it not, so RAM past 4 GiB is a heap of its own. An ESP32's
internal SRAM and its PSRAM are two heaps.

**BUGS**

None known.

**SEE ALSO**

`AllocateMemory`, `GetPhysicalDeviceProperties`

**EXAMPLES**

```zig
fn typeFor(memory: *const facet.PhysicalDeviceMemoryProperties, bits: u32, wanted: u32) ?u32 {
    for (memory.memory_types[0..memory.memory_type_count], 0..) |kind, index| {
        if (bits >> @intCast(index) & 1 != 0 and kind.property_flags & wanted == wanted) return @intCast(index);
    }
    return null;
}
```

## GetPhysicalDeviceProperties

What a physical device is, and the most it does.

**SYNOPSIS**

```zig
fn GetPhysicalDeviceProperties(base: *FacetBase, physical: *facet.PhysicalDevice, properties: *facet.PhysicalDeviceProperties) void
```

**SINCE**

1.0. LVO -32.

**INPUTS**

- `physical` - a physical device EnumeratePhysicalDevices listed.
- `properties` - where they are written.

**RESULT**

None.

**BEHAVIOR**

The device is of type `cpu`, with no vendor or device ID; its name
says how many cores it shares a frame's tiles between, and so do its
limits (`cores`, with `tile_size`). `api_version` is the interface it
has, `driver_version` the library's own version and revision.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

`properties` is the caller's.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`EnumeratePhysicalDevices`, `GetPhysicalDeviceMemoryProperties`

**EXAMPLES**

```zig
var properties: facet.PhysicalDeviceProperties = undefined;
fb.GetPhysicalDeviceProperties(physical, &properties);
```

## GetPhysicalDeviceQueueFamilyProperties

The physical device's queue families.

**SYNOPSIS**

```zig
fn GetPhysicalDeviceQueueFamilyProperties(base: *FacetBase, physical: *facet.PhysicalDevice, count: *u32, properties: ?[*]facet.QueueFamilyProperties) void
```

**SINCE**

1.0. LVO -36.

**INPUTS**

- `physical` - a physical device EnumeratePhysicalDevices listed.
- `count` - with `properties`, how many it has room for; written with
  how many there are, or with how many it was given.
- `properties` - where they go; null to count them alone.

**RESULT**

None.

**BEHAVIOR**

There is one family, 0: QUEUE_GRAPHICS, QUEUE_COMPUTE and QUEUE_TRANSFER, with one
queue. Its queue plays command buffers on a task of its own and
shares each frame's tiles between the cores.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

`properties` is the caller's.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateDevice`, `GetDeviceQueue`

**EXAMPLES**

```zig
var count: u32 = 1;
var family: [1]facet.QueueFamilyProperties = undefined;
fb.GetPhysicalDeviceQueueFamilyProperties(physical, &count, &family);
```

## GetPhysicalDeviceSurfaceCapabilities

What a swapchain on the surface can be, into `capabilities`.

**SYNOPSIS**

```zig
fn GetPhysicalDeviceSurfaceCapabilities(base: *FacetBase, physical: *facet.PhysicalDevice, surface: *facet.Surface, capabilities: *facet.SurfaceCapabilities) facet.Result
```

**SINCE**

1.0. LVO -332.

**INPUTS**

- `physical` - the physical device.
- `surface` - the surface.
- `capabilities` - filled in.

**RESULT**

`success`; `error_surface_lost`, and nothing written, when the window
the surface is over has closed.

**BEHAVIOR**

A swapchain on a screen is the screen's size, which is its display's,
and has from one image to as many pictures as the display's memory
holds, four at most. One on a window is the size inside the window's
border now, and has from one image to four. Its images are drawn into,
copied out of and copied into (`supported_usage_flags`, since 1.43),
and shown as they are drawn: no transform, no alpha.

**CONTEXT**

- Waits: on a window's surface, for the screens' semaphore.
- Interrupts: no.
- Locks: on a window's surface, no layer's lock may be held.
- Process: a Task will do.

**OWNERSHIP**

None.

**NOTES**

The display's memory is shared with every other screen open, each of
which takes a picture of it: max_image_count is the most there could be,
and CreateSwapchain says whether there is room now.

**BUGS**

None known.

**SEE ALSO**

`CreateSwapchain`

**EXAMPLES**

```zig
var capabilities: facet.SurfaceCapabilities = undefined;
_ = fb.GetPhysicalDeviceSurfaceCapabilities(physical, surface.?, &capabilities);
const extent = capabilities.current_extent;
```

## GetPhysicalDeviceSurfaceFormats

The formats a swapchain on the surface can have into `formats`, at most `count.*` of them, and how many there are into `count`; null for `formats` counts alone.

**SYNOPSIS**

```zig
fn GetPhysicalDeviceSurfaceFormats(base: *FacetBase, physical: *facet.PhysicalDevice, surface: *facet.Surface, count: *u32, formats: ?[*]facet.SurfaceFormat) facet.Result
```

**SINCE**

1.0. LVO -336.

**INPUTS**

- `physical` - the physical device.
- `surface` - the surface.
- `count` - how many `formats` has room for; how many were written.
- `formats` - where they go, or null.

**RESULT**

`success`, or `incomplete` when `formats` was too short for them all;
`error_surface_lost`, and none, when the window the surface is over has
closed.

**BEHAVIOR**

A surface has one format, its display's: `b8g8r8a8_unorm`,
`r8g8b8a8_unorm` or `r5g6b5_unorm_pack16`, in sRGB. A display of
another - 24 bits, 1555, a palette's - has none. In 565 what is drawn
is drawn and blended in 8 bits a channel, as in the 32-bit formats,
and dithered into the display's pixels as it is stored
(CmdBeginRenderPass).

**CONTEXT**

- Waits: on a window's surface, for the screens' semaphore.
- Interrupts: no.
- Locks: on a window's surface, no layer's lock may be held.
- Process: a Task will do.

**OWNERSHIP**

None.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CreateSwapchain`

**EXAMPLES**

```zig
var count: u32 = 1;
var format: facet.SurfaceFormat = undefined;
_ = fb.GetPhysicalDeviceSurfaceFormats(physical, surface.?, &count, @ptrCast(&format));
if (count == 0) return error.NotThirtyTwoBits;
```

## GetPhysicalDeviceSurfacePresentModes

The present modes of the surface into `modes`, at most `count.*` of them, and how many there are into `count`; null for `modes` counts alone.

**SYNOPSIS**

```zig
fn GetPhysicalDeviceSurfacePresentModes(base: *FacetBase, physical: *facet.PhysicalDevice, surface: *facet.Surface, count: *u32, modes: ?[*]facet.PresentMode) facet.Result
```

**SINCE**

1.0. LVO -340.

**INPUTS**

- `physical` - the physical device.
- `surface` - the surface.
- `count` - how many `modes` has room for; how many were written.
- `modes` - where they go, or null.

**RESULT**

`success`, or `incomplete` when `modes` was too short.

**BEHAVIOR**

Every surface has `fifo`, and only that: each image presented is shown
from the display's next frame on, in the order they were presented, and
none is left out. A program drawing faster than the display shows is
held to its rate.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

None.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`QueuePresent`

**EXAMPLES**

```zig
var count: u32 = 1;
var mode: facet.PresentMode = undefined;
_ = fb.GetPhysicalDeviceSurfacePresentModes(physical, surface.?, &count, @ptrCast(&mode));
```

## GetPhysicalDeviceSurfaceSupport

Whether queue family `family` can present to the surface, into `supported`.

**SYNOPSIS**

```zig
fn GetPhysicalDeviceSurfaceSupport(base: *FacetBase, physical: *facet.PhysicalDevice, family: u32, surface: *facet.Surface, supported: *bool) facet.Result
```

**SINCE**

1.0. LVO -328.

**INPUTS**

- `physical` - the physical device.
- `family` - a queue family of it.
- `surface` - the surface.
- `supported` - true where the family's queues can present to it.

**RESULT**

`success`; `error_surface_lost`, and not supported, when the window the
surface is over has closed.

**BEHAVIOR**

The one queue family can present to a surface whose pixels
facet.library draws in: 32 bits, in either order of red and blue, or
565.

**CONTEXT**

- Waits: on a window's surface, for the screens' semaphore.
- Interrupts: no.
- Locks: on a window's surface, no layer's lock may be held.
- Process: a Task will do.

**OWNERSHIP**

None.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`GetPhysicalDeviceSurfaceFormats`, `QueuePresent`

**EXAMPLES**

```zig
var supported = false;
_ = fb.GetPhysicalDeviceSurfaceSupport(physical, 0, surface.?, &supported);
if (!supported) return error.CannotShow;
```

## GetQueryPoolResults

What `count` queries from `first` counted, written into `data`.

**SYNOPSIS**

```zig
fn GetQueryPoolResults(base: *FacetBase, device: *facet.Device, pool: *facet.QueryPool, first: u32, count: u32, size: usize, data: *anyopaque, stride: u64, flags: u32) facet.Result
```

**SINCE**

1.29. LVO -464.

**INPUTS**

- `device` - the device the pool was made on.
- `pool` - the pool.
- `first`, `count` - the queries read; those past the pool's last are
  left out.
- `size`, `data` - the bytes written into, and how many there are.
- `stride` - the bytes from one query's values to the next.
- `flags` - `QUERY_RESULT_64` for values of 8 bytes rather than 4,
  `QUERY_RESULT_WAIT` to wait for the work rather than answer
  `not_ready`, `QUERY_RESULT_WITH_AVAILABILITY` for a value after each
  query's saying whether it is available, `QUERY_RESULT_PARTIAL` to
  write what a query not available has counted so far.

**RESULT**

`success` where every query read was available; `not_ready` where one
was not, the others written all the same; `error_device_lost`;
`error_out_of_host_memory` where `size` is too small for what was asked
for, nothing written past what fitted.

**BEHAVIOR**

A statistics query writes one value for each statistic it counts, in the
order of their bits; the other kinds write one. Without
`QUERY_RESULT_64` a value is 4 bytes and one that will not fit is held
at 0xFFFFFFFF, where Vulkan leaves it undefined.

`QUERY_RESULT_WAIT` waits for the device's queue to go idle, which is
when everything recorded before has been played and every value is
written. Without it the answer is what is there: a query is available
once the command that ended it was played, and the pixels a pass shaded
are counted as its tiles are drawn, at the end of the pass - so a
program that reads values without waiting for the fence of the
submission that counted them may read a sum still being added to.

**CONTEXT**

- Waits: with `QUERY_RESULT_WAIT`, for the queue.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

`data` is the caller's.

**NOTES**

`CmdCopyQueryPoolResults` writes the same values into a buffer as part
of a command buffer, which wants no wait at all.

**BUGS**

None known.

**SEE ALSO**

`CreateQueryPool`, `CmdEndQuery`, `CmdCopyQueryPoolResults`

**EXAMPLES**

```zig
var samples: u64 = 0;
_ = fb.GetQueryPoolResults(device, counted, 0, 1, @sizeOf(u64), &samples, @sizeOf(u64), facet.QUERY_RESULT_64 | facet.QUERY_RESULT_WAIT);
```

## GetRenderAreaGranularity

The granularity of a render area on this device: the tile it draws in.

**SYNOPSIS**

```zig
fn GetRenderAreaGranularity(base: *FacetBase, device: *facet.Device, pass: *facet.RenderPass, granularity: *facet.Extent2D) void
```

**SINCE**

1.36. LVO -508.

**INPUTS**

- `device` - the device the pass is drawn on.
- `pass` - a render pass. Every pass of a device has the same answer.
- `granularity` - where the width and the height are written.

**RESULT**

None.

**BEHAVIOR**

A render area whose offset is a multiple of this and whose extent is
too - or which reaches the framebuffer's edge - costs nothing that a
whole-framebuffer area would not: the device draws in tiles of this
size, and a tile the area touches at all is drawn. An area inside one
tile is as dear as that whole tile.

It is the device's tile, `PhysicalDeviceLimits.tile_size` square: the
cores' rasterizer and the V3D both draw a frame tile by tile. The
render pass makes no difference to it, and is asked for because
Vulkan asks for it.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

`granularity` is the caller's.

**NOTES**

What a render area narrower than the framebuffer does save is the
pixels drawn, and the tiles it does not touch at all.

**BUGS**

None known.

**SEE ALSO**

`CmdBeginRenderPass`, `GetPhysicalDeviceProperties`

**EXAMPLES**

```zig
var granularity: facet.Extent2D = undefined;
fb.GetRenderAreaGranularity(device, pass.?, &granularity);
// The area rounded out to whole tiles.
const left = x / granularity.width * granularity.width;
_ = left;
```

## GetSwapchainImages

The swapchain's images into `images`, at most `count.*` of them, and how many there are into `count`; null for `images` counts alone.

**SYNOPSIS**

```zig
fn GetSwapchainImages(base: *FacetBase, device: *facet.Device, swapchain: *facet.Swapchain, count: *u32, images: ?[*]*facet.Image) facet.Result
```

**SINCE**

1.0. LVO -352.

**INPUTS**

- `device` - the device it was made with.
- `swapchain` - the swapchain.
- `count` - how many `images` has room for; how many were written.
- `images` - where they go, or null.

**RESULT**

`success`, or `incomplete` when `images` was too short for them all.

**BEHAVIOR**

The images in the order AcquireNextImage and QueuePresent number them.
Views and framebuffers are made of them as of any colour attachment.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The images are the swapchain's, and go with it.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`AcquireNextImage`, `CreateImageView`

**EXAMPLES**

```zig
var count: u32 = 4;
var images: [4]*facet.Image = undefined;
_ = fb.GetSwapchainImages(device, swapchain.?, &count, &images);
```

## MapMemory

The address of a block's memory, from an offset on.

**SYNOPSIS**

```zig
fn MapMemory(base: *FacetBase, device: *facet.Device, memory: *facet.DeviceMemory, offset: u64, size: u64, flags: u32, data: *?*anyopaque) facet.Result
```

**SINCE**

1.0. LVO -64.

**INPUTS**

- `device` - the device it was allocated from.
- `memory` - the block.
- `offset` - where in it the mapping starts.
- `size` - how many bytes, or WHOLE_SIZE for all of it from `offset`.
- `flags` - 0.
- `data` - where the address of the byte at `offset` is written;
  null when it fails.

**RESULT**

`success`; `error_memory_map_failed` for lazily allocated memory, for
a block mapped already, and for a range past its end.

**BEHAVIOR**

Mapping is handing out the address: the memory is the machine's RAM,
and what the program writes there the queue sees, and the other way
round, with nothing flushed (MEMORY_PROPERTY_HOST_COHERENT). The
address is aligned as the block is, to a cache line, plus `offset`.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The address is good until UnmapMemory or FreeMemory.

**NOTES**

What the queue is reading or writing still has to be waited for, with
a fence: the mapping is coherent, not synchronized.

**BUGS**

None known.

**SEE ALSO**

`UnmapMemory`, `AllocateMemory`

**EXAMPLES**

```zig
var data: ?*anyopaque = null;
if (fb.MapMemory(device, memory, 0, facet.WHOLE_SIZE, 0, &data) != .success) return error.NoMap;
const vertices: [*]Vertex = @ptrCast(@alignCast(data.?));
```

## QueuePresent

Images handed to the queue to be shown, once the semaphores are signalled.

**SYNOPSIS**

```zig
fn QueuePresent(base: *FacetBase, queue: *facet.Queue, info: *const facet.PresentInfo) facet.Result
```

**SINCE**

1.0. LVO -360.

**INPUTS**

- `queue` - the queue that shows them: the device's.
- `info` - the semaphores waited for, and an image of each swapchain,
  acquired, with a place for what came of each where `results` is not
  null.

**RESULT**

`success`; `error_out_of_date` when a swapchain's surface has changed,
or an image was not one the program held - that image is not shown;
`error_surface_lost` when the window a surface is over has closed;
`error_device_lost` once the device is lost, the image given back unshown;
`error_out_of_host_memory`. The worst of them, and each in `results`.

**BEHAVIOR**

The images go on the queue after the work submitted before: when the
queue's task comes to them it waits for the semaphores, then shows each,
returning when the display has taken it up at the start of a frame. The
image shown before it then comes free for AcquireNextImage. The call
itself returns at once. A window closed by then - its program ended, and
its windows closed with it - is not drawn into: the image comes free
unshown, and the next AcquireNextImage answers `error_surface_lost`. So
does an image on the queue when the device is lost: what it holds may not
be finished, and the display keeps what it shows.

**CONTEXT**

- Waits: on a window's surface, for the screens' semaphore.
- Interrupts: no.
- Locks: on a window's surface, no layer's lock may be held.
- Process: a Task will do.

**OWNERSHIP**

The images are the swapchain's again: the program has them no more.

**NOTES**

The queue's task waits for the display while it shows an image: work
submitted after the present waits behind it.

**BUGS**

None known.

**SEE ALSO**

`AcquireNextImage`, `QueueSubmit`

**EXAMPLES**

```zig
const shown = fb.QueuePresent(queue.?, &.{
    .wait_semaphore_count = 1,
    .wait_semaphores = @ptrCast(&rendered),
    .swapchains = @ptrCast(&swapchain),
    .image_indices = @ptrCast(&index),
});
```

## QueueSubmit

Batches of work for the queue, played in order by its task.

**SYNOPSIS**

```zig
fn QueueSubmit(base: *FacetBase, queue: *facet.Queue, count: u32, submits: ?[*]const facet.SubmitInfo, fence: ?*facet.Fence) facet.Result
```

**SINCE**

1.0. LVO -164.

**INPUTS**

- `queue` - the queue.
- `count`, `submits` - the batches: for each, the semaphores it waits
  for, the command buffers it plays and the semaphores it signals.
- `fence` - signalled when all of them are done; may be null. With no
  batches, signalled when all submitted before is done.

**RESULT**

`success`; `error_out_of_host_memory`, and nothing submitted;
`error_device_lost`, and nothing submitted, once the device is lost.

**BEHAVIOR**

The queue's task takes the batches in the order they were submitted,
after everything submitted before: for each it waits until each of its
semaphores is signalled, and takes the signal; plays its command
buffers, one after the other, each command finished before the next
starts; then signals its semaphores, and with the last batch the fence.
A command buffer not executable - not ended, or spent by a one-time
submission - is passed over.

The call returns at once: the work is the task's. If the device is lost
while a batch is on the queue, nothing more of it is played, and its
semaphores and fence are signalled all the same.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: the queue's list, for a moment.
- Process: a Task will do.

**OWNERSHIP**

The arrays are copied as the call is made. The command buffers, and
everything their commands name, have to last until the work is done:
until the fence is signalled.

**NOTES**

A command buffer recorded with ONE_TIME_SUBMIT is spent once played;
any other may be submitted again once its work is done, or while it is
pending if it was recorded with SIMULTANEOUS_USE.

**BUGS**

None known.

**SEE ALSO**

`WaitForFences`, `QueueWaitIdle`, `CreateSemaphore`

**EXAMPLES**

```zig
const submit = facet.SubmitInfo{ .command_buffer_count = 1, .command_buffers = @ptrCast(&commands[0]) };
if (fb.QueueSubmit(queue.?, 1, @ptrCast(&submit), frame_done) != .success) return error.NoSubmit;
```

## QueueWaitIdle

Wait until the queue has done all it was given.

**SYNOPSIS**

```zig
fn QueueWaitIdle(base: *FacetBase, queue: *facet.Queue) facet.Result
```

**SINCE**

1.0. LVO -168.

**INPUTS**

- `queue` - the queue.

**RESULT**

`success`; `error_device_lost` once the device is lost.

**BEHAVIOR**

Returns once every batch submitted before the call has been played and
its fence and semaphores signalled.

**CONTEXT**

- Waits: yes, on the queue's idle waitable.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

None.

**NOTES**

A fence waits for one submission; this for all.

**BUGS**

None known.

**SEE ALSO**

`DeviceWaitIdle`, `WaitForFences`

**EXAMPLES**

```zig
_ = fb.QueueWaitIdle(queue.?);
```

## ResetCommandBuffer

The command buffer back to where it started.

**SYNOPSIS**

```zig
fn ResetCommandBuffer(base: *FacetBase, buffer: *facet.CommandBuffer, flags: u32) facet.Result
```

**SINCE**

1.0. LVO -148.

**INPUTS**

- `buffer` - a command buffer that is not pending.
- `flags` - COMMAND_BUFFER_RESET_RELEASE_RESOURCES to give back the
  memory its recording took, or 0 to keep it for the next.

**RESULT**

`success`.

**BEHAVIOR**

Nothing is recorded in it, as when it was allocated.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The buffer stays its pool's.

**NOTES**

BeginCommandBuffer resets a buffer itself.

**BUGS**

None known.

**SEE ALSO**

`BeginCommandBuffer`, `ResetCommandPool`

**EXAMPLES**

```zig
_ = fb.ResetCommandBuffer(commands, 0);
```

## ResetCommandPool

Every command buffer of the pool back to where it started.

**SYNOPSIS**

```zig
fn ResetCommandPool(base: *FacetBase, device: *facet.Device, pool: *facet.CommandPool, flags: u32) facet.Result
```

**SINCE**

1.0. LVO -128.

**INPUTS**

- `device` - the device it was made on.
- `pool` - the pool.
- `flags` - COMMAND_BUFFER_RESET_RELEASE_RESOURCES to give back the
  memory the recordings took, or 0 to keep it for the next.

**RESULT**

`success`.

**BEHAVIOR**

Each buffer is as it was allocated, nothing recorded in it. None may
be pending.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The buffers stay the pool's.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`ResetCommandBuffer`, `CreateCommandPool`

**EXAMPLES**

```zig
_ = fb.ResetCommandPool(device, pool, 0);
```

## ResetDescriptorPool

Every set allocated from the pool freed at once.

**SYNOPSIS**

```zig
fn ResetDescriptorPool(base: *FacetBase, device: *facet.Device, pool: *facet.DescriptorPool, flags: u32) facet.Result
```

**SINCE**

1.0. LVO -252.

**INPUTS**

- `device` - the device.
- `pool` - the pool.
- `flags` - 0.

**RESULT**

`success`.

**BEHAVIOR**

No command buffer still pending may have bound one of its sets.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The sets are gone; the pool is the caller's still.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`AllocateDescriptorSets`, `FreeDescriptorSets`

**EXAMPLES**

```zig
_ = fb.ResetDescriptorPool(device, pool.?, 0);
```

## ResetFences

Fences back to unsignalled.

**SYNOPSIS**

```zig
fn ResetFences(base: *FacetBase, device: *facet.Device, count: u32, fences: [*]const *facet.Fence) facet.Result
```

**SINCE**

1.0. LVO -184.

**INPUTS**

- `device` - the device they were made on.
- `count`, `fences` - the fences.

**RESULT**

`success`.

**BEHAVIOR**

None of them may be waiting for a submission still to be done.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The array is the caller's.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`WaitForFences`, `CreateFence`

**EXAMPLES**

```zig
_ = fb.WaitForFences(device, 1, @ptrCast(&frame_done), true, facet.WAIT_FOREVER_NS);
_ = fb.ResetFences(device, 1, @ptrCast(&frame_done));
```

## UnmapMemory

The block's mapping ended.

**SYNOPSIS**

```zig
fn UnmapMemory(base: *FacetBase, device: *facet.Device, memory: *facet.DeviceMemory) void
```

**SINCE**

1.0. LVO -68.

**INPUTS**

- `device` - the device it was allocated from.
- `memory` - a block MapMemory mapped.

**RESULT**

None.

**BEHAVIOR**

The address MapMemory gave is no longer the program's to use; the
block may be mapped again. Nothing is flushed: nothing needs to be.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The block stays the caller's.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`MapMemory`

**EXAMPLES**

```zig
fb.UnmapMemory(device, memory);
```

## UpdateDescriptorSets

Descriptors written into sets, and copied from one set to another.

**SYNOPSIS**

```zig
fn UpdateDescriptorSets(base: *FacetBase, device: *facet.Device, write_count: u32, writes: ?[*]const facet.WriteDescriptorSet, copy_count: u32, copies: ?[*]const facet.CopyDescriptorSet) void
```

**SINCE**

1.0. LVO -264.

**INPUTS**

- `device` - the device.
- `write_count`, `writes` - descriptors written: a sampled image's view
  and a sampler's sampler from `image_info` - a combined image sampler
  takes both from it - a buffer's range from `buffer_info`, one for each
  descriptor.
- `copy_count`, `copies` - descriptors copied, after the writes.

**RESULT**

None.

**BEHAVIOR**

A write or a copy of more descriptors than are left in its binding runs
on into the bindings after it. A descriptor of another kind than the
binding's, or past the set's last, is passed over.

A sampled image's view has to be of an image made to be sampled; a
buffer's range is what lies inside the buffer, which has to be bound. A
combined image sampler whose `sampler` is null is written with the
texture and no sampler, which the fixed forms that sample through one
paint `shader.missing` for rather than sampling some other way.

An input attachment is written from `image_info` too, and its view has
to be of an image made with IMAGE_USAGE_INPUT_ATTACHMENT, of a format
whose pixels are kept in rows - or, since 1.62, of a depth attachment
that is kept, whose plane the view names is read the same way
(CreateImageView); anything else leaves the descriptor empty, and a fragment function then finds nothing
(`shader.Resources.input` answers null). What the set holds is the
view's rows, so the attachment is read wherever the image's memory
stands when the draw runs - which is what the subpass before it drew
(CreateRenderPass).

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The arrays are read during the call alone. What a set holds is the
address of each buffer's range, of each view's texture and of what each
sampler keeps: the buffers, the views and the samplers have to last as
long as the set is used.

**NOTES**

A set is read as the draws that bound it run: written before the
command buffer is submitted, it is drawn with as written then. It may
not be written while a command buffer that bound it is pending.

**BUGS**

None known.

**SEE ALSO**

`AllocateDescriptorSets`, `CmdBindDescriptorSets`

**EXAMPLES**

```zig
const image = facet.DescriptorImageInfo{ .image_view = view };
const write = facet.WriteDescriptorSet{ .dst_set = set.?, .dst_binding = 0, .descriptor_type = .sampled_image, .image_info = @ptrCast(&image) };
fb.UpdateDescriptorSets(device, 1, @ptrCast(&write), 0, null);
```

## WaitForFences

Wait until fences are signalled: all of them, or any.

**SYNOPSIS**

```zig
fn WaitForFences(base: *FacetBase, device: *facet.Device, count: u32, fences: [*]const *facet.Fence, wait_all: bool, timeout: u64) facet.Result
```

**SINCE**

1.0. LVO -192.

**INPUTS**

- `device` - the device they were made on.
- `count`, `fences` - the fences: with `wait_all` false, at most
  WAIT_MAX (32).
- `wait_all` - true to wait for all, false for any one.
- `timeout` - nanoseconds at most, rounded up to microseconds and kept
  to the system tick; 0 only looks; WAIT_FOREVER_NS has no limit.

**RESULT**

`success` once they are; `timeout` when the time ran out first;
`error_device_lost` once the device is lost, at once if it already is.

**BEHAVIOR**

WaitForAny on the fences' waitables: the task sleeps until a queue
signals one.

**CONTEXT**

- Waits: yes.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The array is the caller's.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`ResetFences`, `GetFenceStatus`, `QueueSubmit`

**EXAMPLES**

```zig
if (fb.WaitForFences(device, 1, @ptrCast(&frame_done), true, facet.WAIT_FOREVER_NS) != .success) return error.Hung;
```
