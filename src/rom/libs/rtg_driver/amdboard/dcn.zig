// SPDX-License-Identifier: MPL-2.0
//! The display engine of an AMD graphics device, read as the firmware
//! left it running.
//!
//! A machine whose firmware is UEFI reaches the kernel with a picture
//! already on the glass: the firmware chose a mode, trained the link and
//! told the engine where to read, and all the driver is given is where
//! those pixels are (`uefi.zig`). Nothing of that is undone here. What
//! this does is find the engine behind that framebuffer and read what it
//! was told, so that showing a picture is naming its address instead of
//! copying it into the one buffer the firmware named.
//!
//! **What is written, and what is not.** The mode the firmware chose and
//! the link it trained are left as they were found. What the fetcher reads is
//! written: the board shows two frames, the firmware's framebuffer and
//! one of the device's own memory (`newFrame`), and has the fetcher read
//! the other at the pipe's next update (`flip`) - the point in each
//! frame where the pipe takes up what its double-buffered registers were
//! told, between two frames, so that a picture is never shown half old
//! and half new. That point raises an interrupt, which comes through the
//! device's interrupt ring (`hookFrames`, `takeFrame`): it is the board's
//! frame interrupt, what a flip and WaitVBlank wait for. A flip is taken
//! once it is no longer pending and the fetcher reads the address it was
//! told (`flipTaken`).
//!
//! The audio side of the link the firmware lit is written as well
//! (`sound.zig`): the firmware leaves it switched off and no other
//! driver can reach it, since those registers are this engine's.
//!
//! ## Where the registers are
//!
//! The device is held by amdgpu.resource, which claims the function and
//! reads the table its firmware leaves of the chip's blocks; the engine is
//! its display block. Of the addresses the table gives that block, the
//! third is where the pipes', the links' and the audio endpoints'
//! registers are counted from, and the second the clocks'. A register's
//! place is `(block + offset) * 4` bytes into the register window.
//!
//! ## Which pipe
//!
//! An engine has several pipes, each able to drive a display, and the
//! firmware lit one of them. Which one is not written down anywhere: it
//! is worked out from what each pipe says of itself. A running pipe's
//! timing generator says where horizontal and vertical blanking begin and
//! end, and the picture it scans is as wide as the difference between
//! those two and as tall as the vertical pair's - so the pipe whose
//! numbers come out as the size the firmware reported is the pipe the
//! screen is on. That is two agreements over values nothing here chose.
//!
//! The buffer each pipe reads is its own, and the one that holds the
//! firmware's framebuffer is found the same way: by its rows being as far
//! apart as the firmware said they are.
//!
//! ## What the addresses mean
//!
//! A pipe is told where to read in the device's own addresses, not the
//! machine's. The two are a fixed distance apart within one window, and
//! this reads one point of that line - the firmware's framebuffer, whose
//! address the machine knows and whose address the device holds - which
//! is all that is needed to turn any address in that window into the one
//! the device would be given.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const reg = sdk.hardware.mmio.reg;
const ExecBase = sdk.interface.exec.ExecBase;
const AMDGPUBase = sdk.interface.amdgpu.AMDGPUBase;
const uefi = @import("uefi.zig");
const sound = @import("sound.zig");
const regs = sdk.hardware.amd_dcn;
const rtg = sdk.rtg;
const RtgDriverBase = sdk.interface.rtgdriver.RtgDriverBase;

/// Who says what is found, on the boot's lines.
pub const owner = "rtg-amd";

/// The three of the display block's addresses the registers here are
/// counted from. A display engine answers with six: the third holds the
/// pipes, the links and the audio endpoints, the second the clocks the
/// engine is given, and the fourth the blender, which lays the pipes'
/// planes over each other and holds each output's colour matrix.
const block_wanted = 2;
const clocks_wanted = 1;
const blender_wanted = 3;

/// The engine whose registers these files name: every offset here is
/// that version's, and another's are elsewhere.
const engine_major = 3;
const engine_minor = 1;
const engine_revision = 4;

/// How far, in 32-bit words, the registers read and written here reach
/// from where the display block's are counted - the DDC lines' pads are
/// the furthest - and from where the clocks' are.
const display_reach: u64 = 0x2a00;
const clocks_reach: u64 = 0x100;
const blender_reach: u64 = 0x600;

// --- the registers, counted in 32-bit words from the block -------------------------

/// A timing generator: whether it is driving a display, where blanking
/// begins and ends in both directions, how long a line and a frame are,
/// and where the beam is. One per pipe, a fixed distance apart.
const otg_h_total = 0x1b2a;
const otg_h_blank = 0x1b2b;
const otg_v_total = 0x1b2f;
const otg_v_blank = 0x1b36;
const otg_control = 0x1b41;
const otg_position = 0x1b4a;
const otg_pipe_stride = 0x80;

/// The part of a pipe that fetches the picture: how far apart its rows
/// are, and the device's address of its first pixel. One per pipe, a
/// fixed distance apart.
const hubp_pitch = 0x0607;
const hubp_address = 0x060a;
const hubp_address_high = 0x060b;
const hubp_pipe_stride = 0xdc;

/// How many pipes are read. An engine of this kind has four.
const pipes = 4;

// --- the fields written, each a shift and the field's own width --------------------

const description_byte_mask: u32 = 0xff;

/// In the timing generator's control word, that it is driving a display;
/// in the blanking words, where each of the two numbers is and how wide;
/// and how wide the upper half of an address is.
const otg_running: u32 = 1 << 0;
const blank_start_shift = 0;
const blank_end_shift = 16;
const blank_mask: u32 = 0x7fff;
const total_mask: u32 = 0x7fff;
const pitch_mask: u32 = 0x3fff;
const address_high_mask: u32 = 0xffff;

// --- what was found ----------------------------------------------------------------

/// The engine behind the firmware's framebuffer, and what it was read to
/// be saying.
pub const Engine = struct {
    sys: *ExecBase,
    /// rtg.library as a driver calls it, for the standards' timings a
    /// timed pixel clock is held against; null until the driver gives it.
    rtg_base: ?*RtgDriverBase = null,
    /// The resource that holds the device.
    gpu: *AMDGPUBase,
    /// The device's memory as the machine reaches it, and its registers.
    memory: usize,
    memory_bytes: usize,
    registers: usize,
    /// Where the registers read here are counted from, in 32-bit words:
    /// the pipes', the links' and the endpoints', the clocks', and the
    /// blender's - 0 where the device's table names none, or counts it
    /// from past the device's registers.
    block: u32,
    clocks: u32,
    blender: u32 = 0,
    /// What the engine says it is.
    major: u8,
    minor: u8,
    revision: u8,
    /// The pipe driving the display, and the one of its fetchers that
    /// holds the firmware's framebuffer.
    pipe: u32,
    fetcher: u32,
    /// What that pipe is scanning: the picture's size, a line and a frame
    /// in its own units.
    width: u32,
    height: u32,
    h_total: u32,
    v_total: u32,
    /// The device's address of the firmware's framebuffer, and how far
    /// apart its rows are in that fetcher's units.
    surface: u64,
    pitch: u32,
    /// What the machine's addresses in this window have to be moved by to
    /// become the device's own: `surface` less where the framebuffer is
    /// in the window. A picture anywhere in the window is named to the
    /// device by adding it.
    shift: u64,

    /// Where `at` - an address in the device's memory window - is in the
    /// device's own addresses.
    pub fn deviceAddress(engine: Engine, at: usize) u64 {
        return @as(u64, at - engine.memory) + engine.shift;
    }

    /// Where the beam is: the line being scanned, and the pixel in it.
    /// Read twice it says whether the display is refreshing at all.
    pub fn beam(engine: Engine) struct { line: u32, pixel: u32 } {
        const position = readPipe(engine, engine.pipe, otg_position);
        return .{
            .line = position >> blank_start_shift & blank_mask,
            .pixel = position >> blank_end_shift & blank_mask,
        };
    }
};

/// Where the blender's registers are counted from, in the display block
/// `block` of a device with `registers_bytes` of them: 0 where the block
/// names no such address, or one they would reach past the end from.
fn blenderOf(block: amdgpu.GPUBlock, registers_bytes: u64) u32 {
    if (block.count <= blender_wanted) return 0;
    const at = block.addresses[blender_wanted];
    if ((@as(u64, at) + blender_reach) * 4 > registers_bytes) return 0;
    return at;
}

/// The engine behind the framebuffer `fb`, with what it says of itself
/// read out. Null where the machine has no AMD graphics device, one whose
/// memory window the firmware's framebuffer is not in - which is a device
/// that is not the one driving the screen - one whose table holds no
/// display engine, or one no pipe of which is scanning the picture the
/// firmware described. Each of those is said out loud: what this reads is
/// worth knowing even when it comes to nothing, since it is read on a
/// machine the author does not have. Null as well for an engine of
/// another version than the one whose registers these files name, and
/// for a table that counts the engine's registers from outside the
/// device's own: nothing of such an engine is read or written.
pub fn find(sys: *ExecBase, fb: uefi.Framebuffer) ?Engine {
    const resource = sys.OpenResource(amdgpu.AMDGPUNAME) orelse return null;
    const gpu: *AMDGPUBase = @ptrCast(resource);
    var info: amdgpu.GPUInfo = .{};
    if (!gpu.GetGPUInfo(&info)) return null;
    // The one free check that this is the device driving the screen.
    if (fb.pixels < info.window or fb.pixels >= info.window + info.window_bytes) {
        return say(sys, info, "the firmware's framebuffer is not in its memory, so it is not the display's");
    }
    var block: amdgpu.GPUBlock = .{};
    if (!gpu.FindGPUBlock(amdgpu.GPUBLOCK_DISPLAY, 0, &block) or block.count <= block_wanted) {
        return say(sys, info, "its table of blocks holds no display engine");
    }
    // The registers named here are one version's. An engine of another
    // is read and written nowhere: its picture stays the firmware's
    // framebuffer's, copied into.
    if (block.major != engine_major or block.minor != engine_minor or block.revision != engine_revision) {
        exec.kprintf(sys, "%s: the display engine is %d.%d.%d, and only %d.%d.%d is driven here\n", .{
            owner,
            @as(u32, block.major),
            @as(u32, block.minor),
            @as(u32, block.revision),
            @as(u32, engine_major),
            @as(u32, engine_minor),
            @as(u32, engine_revision),
        });
        return null;
    }
    // And they lie inside the device's own: a table that counts them
    // from past its end is believed about nothing.
    const display_end = (@as(u64, block.addresses[block_wanted]) + display_reach) * 4;
    const clocks_end = (@as(u64, block.addresses[clocks_wanted]) + clocks_reach) * 4;
    if (display_end > info.registers_bytes or clocks_end > info.registers_bytes) {
        return say(sys, info, "its table counts the display engine's registers from past the end of its own");
    }
    var engine: Engine = .{
        .sys = sys,
        .gpu = gpu,
        .memory = @intCast(info.window),
        .memory_bytes = @intCast(info.window_bytes),
        .registers = @intCast(info.registers),
        .block = block.addresses[block_wanted],
        .clocks = block.addresses[clocks_wanted],
        .blender = blenderOf(block, info.registers_bytes),
        .major = block.major,
        .minor = block.minor,
        .revision = block.revision,
        .pipe = 0,
        .fetcher = 0,
        .width = 0,
        .height = 0,
        .h_total = 0,
        .v_total = 0,
        .surface = 0,
        .pitch = 0,
        .shift = 0,
    };

    const pipe = scanningPipe(engine, fb) orelse {
        exec.kprintf(sys, "%s: the display engine is %d.%d.%d and no pipe of it scans %dx%d\n", .{
            owner, @as(u32, engine.major), @as(u32, engine.minor), @as(u32, engine.revision), fb.width, fb.height,
        });
        tell(engine);
        return null;
    };
    engine.pipe = pipe.pipe;
    engine.width = pipe.width;
    engine.height = pipe.height;
    engine.h_total = pipe.h_total;
    engine.v_total = pipe.v_total;

    const fetcher = holdingFetcher(engine, fb) orelse {
        exec.kprintf(sys, "%s: the display engine is %d.%d.%d, pipe %d scans %dx%d, and no fetcher of it reads rows %d apart\n", .{
            owner,       @as(u32, engine.major), @as(u32, engine.minor), @as(u32, engine.revision),
            engine.pipe, engine.width,           engine.height,          fb.pitch,
        });
        tell(engine);
        return null;
    };
    engine.fetcher = fetcher.fetcher;
    engine.surface = fetcher.surface;
    engine.pitch = fetcher.pitch;
    engine.shift = fetcher.surface -% @as(u64, fb.pixels - engine.memory);

    exec.kprintf(sys, "%s: display engine %d.%d.%d at 0x%lx, memory 0x%lx %ldM\n", .{
        owner,
        @as(u32, engine.major),
        @as(u32, engine.minor),
        @as(u32, engine.revision),
        @as(u64, engine.registers),
        @as(u64, engine.memory),
        @as(u64, engine.memory_bytes / (1024 * 1024)),
    });
    exec.kprintf(sys, "%s: pipe %d scans %dx%d of %dx%d, fetcher %d reads 0x%lx, rows %d, the window is 0x%lx on\n", .{
        owner,
        engine.pipe,
        engine.width,
        engine.height,
        engine.h_total,
        engine.v_total,
        engine.fetcher,
        engine.surface,
        engine.pitch,
        engine.shift,
    });
    sound.tellAudio(engine);
    return engine;
}

// --- the frames the fetcher is flipped between -------------------------------------

/// `us` microseconds let pass, the task waiting.
pub fn pause(sys: *ExecBase, us: u64) void {
    var never: exec.Waitable = .{};
    const list = [_]*exec.Waitable{&never};
    _ = sys.WaitForAny(&list, 1, us);
}

/// `bytes` of the device's own memory for a frame, from a page on; null
/// where there is no room.
pub fn newFrame(engine: Engine, bytes: usize) ?amdgpu.GPUMemory {
    if (bytes > 0xffff_ffff) return null;
    var frame: amdgpu.GPUMemory = .{};
    if (!engine.gpu.AllocGPUMemory(@intCast(bytes), 4096, &frame)) return null;
    return frame;
}

pub fn freeFrame(engine: Engine, frame: *amdgpu.GPUMemory) void {
    engine.gpu.FreeGPUMemory(frame);
}

/// A register of the fetcher holding the screen, to be written.
fn fetcherRegister(engine: Engine, offset: u32) *volatile u32 {
    return reg(engine.registers + (engine.block + offset + engine.fetcher * hubp_pipe_stride) * 4);
}

fn pipeRegister(engine: Engine, offset: u32) *volatile u32 {
    return reg(engine.registers + (engine.block + offset + engine.pipe * otg_pipe_stride) * 4);
}

/// The fetcher told to read the frame at the device's `address` from
/// the pipe's next update on - or, `now`, at once, wherever the scan is:
/// what a board giving up on flipping does. Every write of the frame is
/// sent on first: the frames are reached write-combining, and a fence
/// drains the writes this core gathered - those of exec's workers were
/// drained as each said it was done, which is a locked write. The high
/// word goes first, since writing the low one arms the flip.
pub fn flip(engine: Engine, address: u64, now: bool) void {
    sdk.hardware.barrier.full();
    const control = fetcherRegister(engine, regs.DCSURF_FLIP_CONTROL);
    const kind: u32 = if (now) regs.SURFACE_FLIP_TYPE else 0;
    control.* = control.* & ~(regs.SURFACE_FLIP_TYPE | regs.SURFACE_UPDATE_LOCK) | kind;
    fetcherRegister(engine, regs.DCSURF_PRIMARY_SURFACE_ADDRESS_HIGH).* = @truncate(address >> 32 & regs.ADDRESS_HIGH_MASK);
    fetcherRegister(engine, regs.DCSURF_PRIMARY_SURFACE_ADDRESS).* = @truncate(address);
}

/// Whether the flip to `address` has been taken: none is pending, and
/// the fetcher reads it.
pub fn flipTaken(engine: Engine, address: u64) bool {
    if (fetcherRegister(engine, regs.DCSURF_FLIP_CONTROL).* & regs.SURFACE_FLIP_PENDING != 0) return false;
    const low = fetcherRegister(engine, regs.DCSURF_SURFACE_EARLIEST_INUSE).*;
    const high = fetcherRegister(engine, regs.DCSURF_SURFACE_EARLIEST_INUSE_HIGH).* & regs.ADDRESS_HIGH_MASK;
    return (@as(u64, high) << 32 | low) == address;
}

/// The pipe's interrupt at its update point handed to `server`, and
/// switched on at the pipe; false where the device's interrupts cannot
/// be had. Its acknowledging is the server's (`takeFrame`).
pub fn hookFrames(engine: Engine, server: *exec.Interrupt) bool {
    if (!engine.gpu.AddGPUIntServer(amdgpu.GPUINT_CLIENT_DISPLAY, amdgpu.GPUINT_DISPLAY_UPDATE + engine.pipe, server)) return false;
    const status = pipeRegister(engine, regs.OTG_GLOBAL_SYNC_STATUS);
    // The server writes the same register on whichever core takes the
    // device's message.
    engine.sys.Disable();
    status.* = status.* | regs.VUPDATE_NO_LOCK_EVENT_CLEAR | regs.VUPDATE_NO_LOCK_INT_EN;
    engine.sys.Enable();
    return true;
}

/// The interrupt switched off at the pipe and the server taken off.
pub fn unhookFrames(engine: Engine, server: *exec.Interrupt) void {
    const status = pipeRegister(engine, regs.OTG_GLOBAL_SYNC_STATUS);
    engine.sys.Disable();
    status.* = status.* & ~regs.VUPDATE_NO_LOCK_INT_EN | regs.VUPDATE_NO_LOCK_EVENT_CLEAR;
    engine.sys.Enable();
    engine.gpu.RemGPUIntServer(server);
}

/// The pipe's interrupt acknowledged, in its server.
pub fn takeFrame(engine: Engine) void {
    const status = pipeRegister(engine, regs.OTG_GLOBAL_SYNC_STATUS);
    status.* = status.* | regs.VUPDATE_NO_LOCK_EVENT_CLEAR;
}

/// What every pipe and every fetcher of the engine is holding, a line
/// each. This is said when the numbers did not come out as the firmware's
/// framebuffer says they should: the machine this is read on is not the
/// author's, so what it saw instead is the whole of what there is to go
/// on, and a line of it is worth more than the silence of a refusal.
fn tell(engine: Engine) void {
    var which: u32 = 0;
    while (which < pipes) : (which += 1) {
        const horizontal = readPipe(engine, which, otg_h_blank);
        const vertical = readPipe(engine, which, otg_v_blank);
        exec.kprintf(engine.sys, "%s:   pipe %d %s, blanking %d-%d by %d-%d of %dx%d\n", .{
            owner,
            which,
            @as([*:0]const u8, if (readPipe(engine, which, otg_control) & otg_running != 0) "runs" else "is off"),
            horizontal >> blank_start_shift & blank_mask,
            horizontal >> blank_end_shift & blank_mask,
            vertical >> blank_start_shift & blank_mask,
            vertical >> blank_end_shift & blank_mask,
            readPipe(engine, which, otg_h_total) & total_mask,
            readPipe(engine, which, otg_v_total) & total_mask,
        });
    }
    which = 0;
    while (which < pipes) : (which += 1) {
        const high = readFetcher(engine, which, hubp_address_high) & address_high_mask;
        exec.kprintf(engine.sys, "%s:   fetcher %d reads 0x%lx, rows %d\n", .{
            owner,
            which,
            @as(u64, high) << 32 | readFetcher(engine, which, hubp_address),
            readFetcher(engine, which, hubp_pitch) & pitch_mask,
        });
    }
}

/// A line about a device that was looked at and left alone, and null,
/// which is what the caller returns.
fn say(sys: *ExecBase, info: amdgpu.GPUInfo, why: [*:0]const u8) ?Engine {
    exec.kprintf(sys, "%s: %x:%x is a display function and %s\n", .{ owner, info.vendor, info.device, why });
    return null;
}

// --- writing a register, a field of one, and an endpoint's own ---------------------

/// A register of one pipe's timing generator.
pub fn readPipe(engine: Engine, pipe: u32, offset: u32) u32 {
    return reg(engine.registers + (engine.block + offset + pipe * otg_pipe_stride) * 4).*;
}

/// A register of one pipe's fetcher.
fn readFetcher(engine: Engine, fetcher: u32, offset: u32) u32 {
    return reg(engine.registers + (engine.block + offset + fetcher * hubp_pipe_stride) * 4).*;
}

/// The pipe that is driving a display of the size the firmware reported.
/// A pipe's picture is as wide as the distance between where horizontal
/// blanking begins and where it ends, and as tall as the vertical pair's.
fn scanningPipe(engine: Engine, fb: uefi.Framebuffer) ?struct {
    pipe: u32,
    width: u32,
    height: u32,
    h_total: u32,
    v_total: u32,
} {
    var pipe: u32 = 0;
    while (pipe < pipes) : (pipe += 1) {
        if (readPipe(engine, pipe, otg_control) & otg_running == 0) continue;
        const horizontal = readPipe(engine, pipe, otg_h_blank);
        const vertical = readPipe(engine, pipe, otg_v_blank);
        const width = (horizontal >> blank_start_shift & blank_mask) -% (horizontal >> blank_end_shift & blank_mask);
        const height = (vertical >> blank_start_shift & blank_mask) -% (vertical >> blank_end_shift & blank_mask);
        if (width != fb.width or height != fb.height) continue;
        return .{
            .pipe = pipe,
            .width = width,
            .height = height,
            .h_total = readPipe(engine, pipe, otg_h_total) & total_mask,
            .v_total = readPipe(engine, pipe, otg_v_total) & total_mask,
        };
    }
    return null;
}

/// The fetcher that is reading the firmware's framebuffer: the one whose
/// rows are as far apart as the firmware said they are. The number it
/// holds counts pixels and is one short of the row, which is checked both
/// ways, since what is wanted of it here is which fetcher it is and not
/// the number itself.
fn holdingFetcher(engine: Engine, fb: uefi.Framebuffer) ?struct { fetcher: u32, surface: u64, pitch: u32 } {
    const wanted = fb.pitch / fb.bytes;
    var fetcher: u32 = 0;
    while (fetcher < pipes) : (fetcher += 1) {
        const pitch = readFetcher(engine, fetcher, hubp_pitch) & pitch_mask;
        if (pitch != wanted and pitch +% 1 != wanted) continue;
        const low = readFetcher(engine, fetcher, hubp_address);
        const high = readFetcher(engine, fetcher, hubp_address_high) & address_high_mask;
        const surface = @as(u64, high) << 32 | low;
        if (surface == 0) continue;
        return .{ .fetcher = fetcher, .surface = surface, .pitch = pitch };
    }
    return null;
}
