// SPDX-License-Identifier: MIT
//! A driver: what draws behind a physical device.
//!
//! The library's calls check what a program asks and keep what it records;
//! what the machine does with it is behind the physical device's `Ops`:
//! what the device is, its memory, a pipeline in the device's own terms, and
//! a command buffer carried out. Each instance asks every driver for its
//! physical device (instance/_instance.zig).
//!
//! The cores are the first driver (cpu/cpu.zig), in the library and always
//! there, as the fallback and as the reference the others are checked against.
//!
//! **Any other driver is a module of its own in LIBS:facet/**, which the
//! first instance looks through, on a process: each file there is opened as
//! "facet/<file>", a library whose base (`ModuleBase`) gives its `Ops`. One
//! that describes no device on this machine is closed again, and the others
//! stay open until the library goes. The V3D of the BCM2712 is such a module
//! (v3d_fdriver.zig), built only for the processor that can be next to one.
//!
//! **A module is built from the library's own source.** It is handed the
//! library's objects and reads them as they are - an image, a pipeline, the
//! commands recorded - so the two have to agree on all of that. `stamp` is
//! the sum of the shapes they share and of the library's version: a module
//! whose stamp is not the library's is refused, with a line in the log, and
//! the machine goes on with the drivers it has. So there is no interface for
//! a driver built apart from the library: none is promised to last.
//!
//! A command buffer's work need not be done as `execute` returns. The
//! queue's task waits for `done` before it goes on to the next, and only
//! then signals what the program waits for - its semaphores and its fence
//! (queue/_queue.zig) - so a driver that hands a command list to its
//! hardware signals `done` from the interrupt that says the list has run.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const facet = sdk.facet;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const _base = @import("../facet_base.zig");
const FacetBase = _base.FacetBase;
const facet_version = @import("../facet_version.zig");
const _instance = @import("../instance/_instance.zig");
const _image = @import("../image/_image.zig");
const _buffer = @import("../buffer/_buffer.zig");
const _render = @import("../render/_render.zig");
const _pipeline = @import("../pipeline/_pipeline.zig");
const _descriptor = @import("../descriptor/_descriptor.zig");
const _command = @import("../command/_command.zig");
const _stream = @import("../command/_stream.zig");
const PhysicalDevice = @import("../instance/_instance.zig").PhysicalDevice;
const Device = @import("../device/_device.zig").Device;
const DeviceMemory = @import("../memory/_memory.zig").DeviceMemory;
const Pipeline = @import("../pipeline/_pipeline.zig").Pipeline;
const Queue = @import("../queue/_queue.zig").Queue;
const CommandBuffer = @import("../command/_command.zig").CommandBuffer;

/// What a sampled image of a device's own layout needs of its memory.
pub const TextureMemory = extern struct {
    bytes: u64,
    alignment: u64,
};

pub const Ops = extern struct {
    /// `physical`'s properties, queue family and memory filled in: false
    /// where the machine has not got what the driver drives, and the
    /// instance lists no device of it.
    describe: *const fn (sys: *ExecBase, physical: *PhysicalDevice) callconv(.c) bool,
    /// What the device does with a format.
    format_properties: *const fn (format: facet.Format) callconv(.c) facet.FormatProperties,
    /// `memory.size` bytes of `memory.type_index` behind `memory`: its
    /// `data` set, or the error AllocateMemory answers with. Never asked
    /// for the lazily allocated type, which has nothing behind it.
    allocate_memory: *const fn (device: *Device, memory: *DeviceMemory) callconv(.c) facet.Result,
    free_memory: *const fn (device: *Device, memory: *DeviceMemory) callconv(.c) void,
    /// A pipeline the library has checked put in the device's terms, kept
    /// in its `driver`; or the error CreateGraphicsPipelines answers with.
    make_pipeline: *const fn (pipeline: *Pipeline) callconv(.c) facet.Result,
    unmake_pipeline: *const fn (pipeline: *Pipeline) callconv(.c) void,
    /// What the driver keeps for a queue made, in its `driver`: false when
    /// it cannot be had. Given back as the queue goes, after its last work.
    open_queue: *const fn (queue: *Queue) callconv(.c) bool,
    close_queue: *const fn (queue: *Queue) callconv(.c) void,
    /// A command buffer's commands carried out in order, on the queue's
    /// task: `done` signalled when the last has finished, by the time this
    /// returns or later, an interrupt included. A driver whose device cannot
    /// carry on says so with `queue.device.lose()` and signals `done` all the
    /// same.
    execute: *const fn (queue: *Queue, buffer: *CommandBuffer, done: *exec.Waitable) callconv(.c) void,
    /// A sampled image's memory, for a device that does not read textures
    /// in the rasterizer's layout. Null for one that does.
    texture_memory: ?*const fn (format: facet.Format, width: u32, height: u32, levels: u32) callconv(.c) TextureMemory = null,
    /// Where a texel of such an image is, in bytes from its memory: null for
    /// the rasterizer's layout, kept as `Image.texels` says.
    texture_offset: ?*const fn (image: *const @import("../image/_image.zig").Image, level: u32, x: u32, y: u32) callconv(.c) usize = null,
    /// What a swapchain's pictures in the machine's memory have to be, for
    /// the device to reach them.
    picture_memory: u32 = exec.MEMF_ANY,
};

/// Where the modules are.
pub const module_directory = "LIBS:facet";
/// What is opened: this, and a file's name.
const module_prefix = "facet/";
/// The most modules kept open, and so the most physical devices after the
/// cores'.
pub const most_modules = _base.most_modules;
/// "FDRV": a driver module's base, not some other file's.
pub const module_magic: u32 = 0x4644_5256;

/// A driver module's base: the Library, and what the library reads of it.
pub const ModuleBase = extern struct {
    lib: exec.Library,
    magic: u32 = module_magic,
    /// Its `stamp`, as it was built.
    stamp: u64,
    ops: *const Ops,
    sys_base: *ExecBase,
    /// What LoadSeg made, handed back at the expunge.
    seg_list: ?*anyopaque = null,
};

/// What a module and the library share has this shape: `shape` of each of
/// these, and the library's version, summed. Different in a module built from
/// other source, even where it would load and run for a while.
pub const stamp: u64 = blk: {
    @setEvalBranchQuota(1_000_000);
    var sum: u64 = 0xCBF2_9CE4_8422_2325;
    sum = mixed(sum, facet_version.LIBRARY_VERSION);
    sum = mixed(sum, facet_version.LIBRARY_REVISION);
    const shared = [_]type{
        Ops,            TextureMemory,         PhysicalDevice,  _instance.Instance,
        FacetBase,      Device,                DeviceMemory,    Queue,
        Pipeline,       _pipeline.Tessellated, _image.Image,    _image.ImageView,
        _buffer.Buffer, _render.Part,          _render.Subpass, _render.RenderPass,
        _render.Target, _render.Framebuffer,   _descriptor.Set, CommandBuffer,
        _stream.Stream, _stream.Head,          _vertices.Bound,
    };
    for (shared) |T| sum = shapeOf(sum, T);
    // Every command as it is recorded.
    for (@typeInfo(_command).@"struct".decls) |decl| {
        const value = @field(_command, decl.name);
        if (@TypeOf(value) == type and @typeInfo(value) == .@"struct") sum = shapeOf(sum, value);
    }
    for (@typeInfo(_stream.Op).@"enum".fields) |field| sum = named(mixed(sum, field.value), field.name);
    break :blk sum;
};
const _vertices = @import("_vertices.zig");

fn mixed(sum: u64, value: u64) u64 {
    return (sum ^ value) *% 0x100_0000_01B3;
}

fn named(sum: u64, name: []const u8) u64 {
    var made = sum;
    for (name) |byte| made = mixed(made, byte);
    return made;
}

/// A struct's size, and each field's name, place and size.
fn shapeOf(sum: u64, comptime T: type) u64 {
    var made = mixed(mixed(sum, @sizeOf(T)), @alignOf(T));
    if (@typeInfo(T) != .@"struct") return made;
    for (@typeInfo(T).@"struct".fields) |field| {
        if (field.is_comptime) continue;
        made = named(made, field.name);
        made = mixed(made, @offsetOf(T, field.name));
        made = mixed(made, @sizeOf(field.type));
    }
    return made;
}

/// What a file opened as a module turned out to be.
const Standing = enum { module, not_a_driver, other_version };

fn standingOf(lib: *const exec.Library) Standing {
    const base: *const ModuleBase = @alignCast(@fieldParentPtr("lib", lib));
    if (lib.pos_size < @sizeOf(ModuleBase) or base.magic != module_magic) return .not_a_driver;
    if (base.stamp != stamp) return .other_version;
    return .module;
}

/// What is opened as a module, if it is one: its table. What it is not is
/// said in the log.
fn opsOf(sys: *ExecBase, lib: *const exec.Library) ?*const Ops {
    const base: *const ModuleBase = @alignCast(@fieldParentPtr("lib", lib));
    switch (standingOf(lib)) {
        .module => return base.ops,
        .not_a_driver => exec.kprintf(sys, "facet.library: %s is not a driver\n", .{lib.node.name.?}),
        .other_version => exec.kprintf(sys, "facet.library: %s was built for another version of the library\n", .{lib.node.name.?}),
    }
    return null;
}

/// The physical devices' drivers beside the cores: LIBS:facet/ read, the
/// first time this is called on a process that finds it there. A task
/// cannot read a directory, and goes on with what is known by then.
pub fn lookForModules(base: *FacetBase) void {
    const sys = base.sys_base;
    if (base.inline_queues) return;
    sys.ObtainSemaphore(&base.modules_lock);
    defer sys.ReleaseSemaphore(&base.modules_lock);
    if (base.modules_read) return;
    const me = sys.FindTask(null) orelse return;
    if (me.node.type != .process) return;
    const dos_lib = sys.OpenLibrary(sdk.interface.dos.NAME, 0) orelse return;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(@alignCast(dos_lib));
    const directory = dl.Lock(module_directory, dos.SHARED_LOCK) orelse return;
    defer dl.UnLock(directory);
    var fib: dos.FileInfoBlock = .{};
    if (!dl.Examine(directory, &fib)) return;
    base.modules_read = true;
    while (dl.ExNext(directory, &fib)) {
        if (dos.isDirectory(fib.dir_entry_type)) continue;
        if (base.module_count == most_modules) break;
        var name: [module_prefix.len + fib.file_name.len + 1]u8 = undefined;
        @memcpy(name[0..module_prefix.len], module_prefix);
        var length: usize = 0;
        while (length < fib.file_name.len and fib.file_name[length] != 0) : (length += 1) name[module_prefix.len + length] = fib.file_name[length];
        name[module_prefix.len + length] = 0;
        const lib = sys.OpenLibrary(@ptrCast(&name), 0) orelse continue;
        const ops = opsOf(sys, lib) orelse {
            sys.CloseLibrary(lib);
            continue;
        };
        var probe: PhysicalDevice = undefined;
        if (!ops.describe(sys, &probe)) {
            sys.CloseLibrary(lib);
            continue;
        }
        base.modules[base.module_count] = lib;
        base.module_ops[base.module_count] = ops;
        base.module_count += 1;
    }
}

const testing = std.testing;

test "a module is taken only with the library's stamp" {
    var memory: [@sizeOf(ModuleBase)]u8 align(@alignOf(ModuleBase)) = undefined;
    const base: *ModuleBase = @ptrCast(&memory);
    var table: Ops = undefined;
    base.* = .{ .lib = std.mem.zeroes(exec.Library), .stamp = stamp, .ops = &table, .sys_base = undefined };
    base.lib.pos_size = @sizeOf(ModuleBase);
    try testing.expectEqual(Standing.module, standingOf(&base.lib));
    base.stamp +%= 1;
    try testing.expectEqual(Standing.other_version, standingOf(&base.lib));
    base.stamp = stamp;
    base.magic = 0;
    try testing.expectEqual(Standing.not_a_driver, standingOf(&base.lib));
    base.magic = module_magic;
    base.lib.pos_size = @sizeOf(exec.Library);
    try testing.expectEqual(Standing.not_a_driver, standingOf(&base.lib));
}
