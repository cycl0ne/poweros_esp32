// SPDX-License-Identifier: MIT
//! A driver: what draws behind a physical device.
//!
//! The library's calls check what a program asks and keep what it records;
//! what the machine does with it is behind the physical device's `Ops`:
//! what the device is, its memory, a pipeline in the device's own terms, and
//! a command buffer carried out. Each instance asks every driver in
//! `drivers` for its physical device (instance/_instance.zig).
//!
//! The cores are the first driver (cpu/cpu.zig), and always there, as the
//! fallback and as the reference the others are checked against. The V3D of
//! the BCM2712 is the second (v3d/driver.zig), in the library only where the
//! processor can be next to one, and listed only where the board has it.
//!
//! A command buffer's work need not be done as `execute` returns. The
//! queue's task waits for `done` before it goes on to the next, and only
//! then signals what the program waits for - its semaphores and its fence
//! (queue/_queue.zig) - so a driver that hands a command list to its
//! hardware signals `done` from the interrupt that says the list has run.

const builtin = @import("builtin");
const sdk = @import("sdk");
const exec = sdk.exec;
const facet = sdk.facet;
const ExecBase = sdk.interface.exec.ExecBase;
const PhysicalDevice = @import("../instance/_instance.zig").PhysicalDevice;
const Device = @import("../device/_device.zig").Device;
const DeviceMemory = @import("../memory/_memory.zig").DeviceMemory;
const Pipeline = @import("../pipeline/_pipeline.zig").Pipeline;
const Queue = @import("../queue/_queue.zig").Queue;
const CommandBuffer = @import("../command/_command.zig").CommandBuffer;
const cpu = @import("cpu/cpu.zig");

/// The drivers, in the order an instance lists their physical devices.
pub const drivers = [_]*const Ops{&cpu.ops} ++ if (builtin.cpu.arch == .aarch64) [_]*const Ops{&@import("v3d/driver.zig").ops} else [_]*const Ops{};

/// What a sampled image of a device's own layout needs of its memory.
pub const TextureMemory = struct {
    bytes: u64,
    alignment: u64,
};

pub const Ops = struct {
    /// `physical`'s properties, queue family and memory filled in: false
    /// where the machine has not got what the driver drives, and the
    /// instance lists no device of it.
    describe: *const fn (sys: *ExecBase, physical: *PhysicalDevice) bool,
    /// What the device does with a format.
    format_properties: *const fn (format: facet.Format) facet.FormatProperties,
    /// `memory.size` bytes of `memory.type_index` behind `memory`: its
    /// `data` set, or the error AllocateMemory answers with. Never asked
    /// for the lazily allocated type, which has nothing behind it.
    allocate_memory: *const fn (device: *Device, memory: *DeviceMemory) facet.Result,
    free_memory: *const fn (device: *Device, memory: *DeviceMemory) void,
    /// A pipeline the library has checked put in the device's terms, kept
    /// in its `driver`; or the error CreateGraphicsPipelines answers with.
    make_pipeline: *const fn (pipeline: *Pipeline) facet.Result,
    unmake_pipeline: *const fn (pipeline: *Pipeline) void,
    /// What the driver keeps for a queue made, in its `driver`: false when
    /// it cannot be had. Given back as the queue goes, after its last work.
    open_queue: *const fn (queue: *Queue) bool,
    close_queue: *const fn (queue: *Queue) void,
    /// A command buffer's commands carried out in order, on the queue's
    /// task: `done` signalled when the last has finished, by the time this
    /// returns or later, an interrupt included.
    execute: *const fn (queue: *Queue, buffer: *CommandBuffer, done: *exec.Waitable) void,
    /// A sampled image's memory, for a device that does not read textures
    /// in the rasterizer's layout. Null for one that does.
    texture_memory: ?*const fn (format: facet.Format, width: u32, height: u32, levels: u32) TextureMemory = null,
    /// What a swapchain's pictures in the machine's memory have to be, for
    /// the device to reach them.
    picture_memory: u32 = exec.MEMF_ANY,
};
