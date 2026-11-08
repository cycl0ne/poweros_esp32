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
//! the link it trained are left as they were found - the one change to
//! the link is that one driven for a picture alone is moved to the kind
//! that carries packets as well (`soundUp`). What the fetcher reads is
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
//! (`soundUp`): the firmware leaves it switched off and no other driver
//! can reach it, since those registers are this engine's.
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
//! ## The audio side
//!
//! A display link carries sound as packets between the pictures, and the
//! codec that the machine's audio controller talks to does not hold the
//! answers about that link: the display engine does. Every pin of that
//! codec is backed by an endpoint here, and what the pin answers when it
//! is asked whether anything is plugged into it, what the monitor is
//! called and which rates it takes is what the engine was told to answer
//! - by the driver that lit the link, after it read the monitor. A
//! firmware that only lit the link tells it nothing, so the pin answers
//! that there is nothing there, and the audio driver believes it, which
//! is right: a link whose audio packets are not being sent is not an
//! output, whatever is plugged into it.
//!
//! So those registers are read here, along with what each link's packet
//! part is doing and where the sample clock comes from - and then
//! written: the endpoint is told what the far end has and allowed to
//! answer, the link's packet part is told whose samples to carry, its
//! store for them is switched on and the description of the sound is
//! sent, and the clock the samples are counted out by is set from the
//! pixel clock, timed off the pipe's own frames. What is left is the
//! audio driver's: the codec's converter and slots, which it reaches
//! through verbs like any other codec's.
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
const regs = sdk.hardware.amd_dcn;
const edid = @import("../edid.zig");

/// Who says what is found, on the boot's lines.
const owner = "rtg-fb";

/// The two of the display block's addresses the registers here are
/// counted from. A display engine answers with six: the third holds the
/// pipes, the links and the audio endpoints, and the second the clocks
/// the engine is given.
const block_wanted = 2;
const clocks_wanted = 1;

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
const otg_frame_count = 0x1b4c;
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

// --- the audio side, counted the same way ------------------------------------------

/// An audio endpoint's window: the register that latches which of the
/// endpoint's own registers is wanted, and the one that reads it. One
/// pair per endpoint, a fixed distance apart, and more endpoints than a
/// part has links.
const endpoint_index = 0x0386;
const endpoint_data = 0x0387;
const endpoint_stride = 6;
const endpoints = 8;

/// The endpoint's own registers, by the number latched in its index: what
/// kind of socket the pin is to answer that it is, what it answers when
/// asked what is plugged into it, whether it answers at all, how the
/// channels sit, the first of the rates it answers that the monitor
/// takes, and the first word of what the monitor is called.
const pin_default = 0x0056;
const pin_sense = 0x0023;
const pin_hotplug = 0x0054;
const pin_speaker = 0x0025;
const pin_descriptor = 0x0028;
const pin_sink = 0x003a;

/// A link: the front that takes a pipe's pixels and the back that drives
/// the wire, what the link is driven as where it is driven as this kind
/// of link, and - where it is driven as the other kind - whether a
/// picture is going out on it and whether it carries sound.
const dig_front = 0x208b;
const dig_back = 0x20b1;
const hdmi_control = 0x2094;
const hdmi_audio = 0x2096;
const hdmi_clock = 0x2097;
const port_config = 0x210b;
const port_picture = 0x210c;
const port_sound = 0x212b;

/// The part of a link that puts packets between the pictures: whether
/// samples are being sent, which of the controller's streams they are
/// taken from, and what the link is told about the sound it carries.
const afmt_audio = 0x2082;
const afmt_infoframe = 0x2083;
const afmt_source = 0x2085;

/// One of each per link, a fixed distance apart, and more links than a
/// part has sockets.
const link_stride = 0x100;
const links = 6;

/// The clock the samples are counted out by: which pipe's clock it is
/// taken from, and the two halves of the ratio it is divided by. These
/// are counted from the engine's other block, not the one the pipes are
/// in.
const audio_dto_source = 0x00ab;
const audio_dto_phase = 0x00ac;
const audio_dto_module = 0x00ad;

/// The rest of a link's packet part: how the channels are laid out and
/// how many are on, what each side's channel is called in the status that
/// goes out with the samples, whether the part's own clock is running,
/// and the numbers by which the far end rebuilds the sample clock from
/// the pixel clock - a pair for each rate that can be sent.
const afmt_layout = 0x2075;
const afmt_status_left = 0x2078;
const afmt_status_right = 0x2079;
const afmt_clock = 0x20b0;
const acr_32_cycle = 0x20a8;
const acr_32_samples = 0x20a9;
const acr_44_cycle = 0x20aa;
const acr_44_samples = 0x20ab;
const acr_48_cycle = 0x20ac;
const acr_48_samples = 0x20ad;

/// What a link of this kind sends between the pictures besides the
/// samples: which of the packets that fill the blanking go out, which
/// descriptions go out and on which line of the blanking, and what the
/// general control packet says.
const hdmi_general_packet = 0x2098;
const hdmi_sending = 0x2099;
const hdmi_sending_line = 0x209a;
const hdmi_general = 0x209e;

/// The store a link's packet part keeps the samples in on their way into
/// the packets. A firmware that lit the link for a picture can leave it
/// forced into its low-power state, in which no sample passes through it,
/// so it is switched on - the low-power state not allowed and none
/// forced - before the rest of the link's sound is set.
const afmt_memory = 0x2087;
const memory_low_power_off: u32 = 1 << 0;
const memory_force_shift = 4;
const memory_force_mask: u32 = 0x3;

/// What the rest of the channels are called in the status that goes with
/// the samples, a nibble each from the third channel on.
const afmt_status_rest = 0x207f;
const status_rest_mask: u32 = 0xffffff;
const status_rest_channels: u32 = 3 | 4 << 4 | 5 << 8 | 6 << 12 | 7 << 16 | 8 << 20;

// --- the fields written, each a shift and the field's own width --------------------

/// In a link's front: which pipe's pixels it takes, and that its clock is
/// running, which is what tells the link the firmware lit from the rest.
const front_pipe_shift = 0;
const front_pipe_mask: u32 = 0x7;
const front_running: u32 = 1 << 24;

/// In an endpoint's socket: what it is connected to. Zero there is a
/// socket on the machine's outside; anything else is an endpoint no
/// socket is wired to.
const socket_wired_shift = 30;
const socket_wired_mask: u32 = 0x3;

/// In an endpoint's answering: that it may answer at all, and that its
/// registers are not to be clock-gated while they are written, which is
/// how they are reached and then let go of again.
const answering_on: u32 = 1 << 31;
const answering_awake: u32 = 1 << 0;

/// In an endpoint's channels: which speakers the far end has, and which
/// kind of link it is on. The far end of a link of this kind has the two
/// a stereo monitor has, front left and front right.
const speakers_shift = 0;
const speakers_mask: u32 = 0x7f;
const speakers_stereo: u32 = 1;
const speakers_wire: u32 = 1 << 16;
const speakers_port: u32 = 1 << 17;

/// In an endpoint's first description of what the far end takes: the
/// channels less one, the rates, the sizes of a sample, and the rates
/// again for two channels. The rates are 44.1 and 48 kHz, which is what
/// the converter behind it takes, and the sizes 16 and 24 bits.
const description_channels_shift = 0;
const description_rates_shift = 8;
const description_sizes_shift = 16;
const description_stereo_shift = 24;
const description_byte_mask: u32 = 0xff;
const description_rates: u32 = 1 << 1 | 1 << 2;
const description_sizes: u32 = 1 << 0 | 1 << 2;
const description_stereo_channels = 2;

/// In a link's audio: that samples are being sent, and that the status
/// that goes with them is to be taken up.
const samples_sending: u32 = 1 << 0;
const samples_status_again: u32 = 1 << 26;

/// In what the link is told about the sound: that the description of it
/// is to be taken up again.
const description_again: u32 = 1 << 7;

/// In a link's layout: that neither the layout nor the oversampling is
/// being overridden, and which channels are on - the first two.
const layout_override: u32 = 1 << 0;
const layout_oversampling: u32 = 1 << 28;
const layout_channels_shift = 8;
const layout_channels_mask: u32 = 0xff;
const layout_channels_stereo: u32 = 0x3;

/// In the status that goes with the samples: what each side's channel is
/// called, and how accurate the clock is said to be.
const status_channel_shift = 20;
const status_channel_mask: u32 = 0xf;
const status_accuracy_shift = 28;
const status_accuracy_mask: u32 = 0x3;

/// In a link's own clock: that it is to run.
const link_clock_on: u32 = 1 << 0;

/// In what a link sends between the pictures: that the description of the
/// sound is among it, that it goes out with every frame rather than once -
/// which is also what has a later change to it sent at all - and which
/// line of the blanking it goes on, the second, which is where there is
/// room for it. The description itself is the codec's, which is what the
/// engine takes it from unless it is told to take it from registers of
/// its own, and it is not told to.
const sending_sound_description: u32 = 1 << 4;
const sending_sound_description_always: u32 = 1 << 5;
const sending_line_shift = 8;
const sending_line_mask: u32 = 0x3f;
const sending_line = 2;

/// In a link's control of this kind: that it adds no empty packets of its
/// own beyond the ones it is asked for, which is how the engine is set
/// wherever a link carries sound.
const control_no_extra_empty: u32 = 1 << 3;

/// In the general control the link carries: that the far end is to mute.
/// Cleared, since the point of all of this is that it does not.
const general_mute: u32 = 1 << 0;

/// In the general control packet: that it is sent, that it keeps being
/// sent, and that the gaps between packets are filled with empty ones -
/// which is what makes the blanking of this kind of link a place packets
/// can live at all.
const packet_empty: u32 = 1 << 0;
const packet_general: u32 = 1 << 4;
const packet_general_always: u32 = 1 << 5;

/// In a link's back end: which kind of link it is driving. A wire of this
/// shape carries either kind, and the two differ in exactly what this is
/// about - the one has blanking with nothing in it, the other has packets
/// there, which is where sound goes. A firmware that only wants a picture
/// has no reason to choose the second, and leaves the first.
const back_kind_shift = 16;
const back_kind_mask: u32 = 0x7;
const back_kind_picture_only = 2;
const back_kind_with_packets = 3;

/// In what tells the far end how to rebuild the sample clock: that the
/// numbers are sent by themselves, that the engine works out the cycle
/// rather than taking what is written here, and that they do not come
/// before the picture.
const acr_sending: u32 = 1 << 12;
const acr_from_what_is_written: u32 = 1 << 8;
const acr_before_the_picture: u32 = 1 << 31;
const acr_cycle_shift = 12;
const acr_cycle_mask: u32 = 0xfffff;
const acr_samples_shift = 0;
const acr_samples_mask: u32 = 0xfffff;

/// The samples a cycle for each rate, as the standard for this kind of
/// link gives them. The cycle itself is then the pixel clock where the
/// two agree, which is what is written beside each.
const acr_samples_32 = 4096;
const acr_samples_44 = 6272;
const acr_samples_48 = 6144;
const acr_rate_32 = 32;
const acr_rate_44_tenths = 441;
const acr_rate_48 = 48;

/// In the sample clock: which pipe it follows and which of the two is in
/// use, and what it is divided down to - 24 MHz, in the hundreds of hertz
/// both halves of the ratio are counted in.
const dto_pipe_shift = 0;
const dto_pipe_mask: u32 = 0xf;
const dto_which_shift = 4;
const dto_which_mask: u32 = 0x7;
const dto_phase_hundreds = 240_000;
const hundreds_in_a_kilohertz = 10;

/// Which endpoint's samples a link takes.
const link_from_shift = 0;
const link_from_mask: u32 = 0x7;

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
    /// The resource that holds the device.
    gpu: *AMDGPUBase,
    /// The device's memory as the machine reaches it, and its registers.
    memory: usize,
    memory_bytes: usize,
    registers: usize,
    /// Where the registers read here are counted from, in 32-bit words:
    /// the pipes', the links' and the endpoints', and the clocks'.
    block: u32,
    clocks: u32,
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

/// The engine behind the framebuffer `fb`, with what it says of itself
/// read out. Null where the machine has no AMD graphics device, one whose
/// memory window the firmware's framebuffer is not in - which is a device
/// that is not the one driving the screen - one whose table holds no
/// display engine, or one no pipe of which is scanning the picture the
/// firmware described. Each of those is said out loud: what this reads is
/// worth knowing even when it comes to nothing, since it is read on a
/// machine the author does not have.
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
    var engine: Engine = .{
        .sys = sys,
        .gpu = gpu,
        .memory = @intCast(info.window),
        .memory_bytes = @intCast(info.window_bytes),
        .registers = @intCast(info.registers),
        .block = block.addresses[block_wanted],
        .clocks = block.addresses[clocks_wanted],
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
    tellAudio(engine);
    return engine;
}

// --- the frames the fetcher is flipped between -------------------------------------

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

/// What the engine's audio side is holding. Read only: every line is what
/// the engine answers, and the machine it is read on is not the author's,
/// so the numbers themselves are the finding.
///
/// An endpoint whose kind is zero is one no pin of the codec is backed
/// by, and is passed over. A link whose registers are all zero is one
/// that is not driven, and is passed over as well, so that what is said
/// is the one link the firmware lit and the endpoint it answers from.
fn tellAudio(engine: Engine) void {
    var which: u32 = 0;
    while (which < endpoints) : (which += 1) {
        const kind = readEndpoint(engine, which, pin_default);
        if (kind == 0) continue;
        exec.kprintf(engine.sys, "%s:   endpoint %d: socket %x, sees %x, answers %x, channels %x, first rate %x, name %x\n", .{
            owner,
            which,
            kind,
            readEndpoint(engine, which, pin_sense),
            readEndpoint(engine, which, pin_hotplug),
            readEndpoint(engine, which, pin_speaker),
            readEndpoint(engine, which, pin_descriptor),
            readEndpoint(engine, which, pin_sink),
        });
    }
    which = 0;
    while (which < links) : (which += 1) {
        exec.kprintf(engine.sys, "%s:   link %d: front %x, back %x, as a wire %x, a picture %x of %x\n", .{
            owner,
            which,
            readLink(engine, which, dig_front),
            readLink(engine, which, dig_back),
            readLink(engine, which, hdmi_control),
            readLink(engine, which, port_picture),
            readLink(engine, which, port_config),
        });
        exec.kprintf(engine.sys, "%s:   link %d sound: samples %x, from stream %x, told %x, packets %x, counted %x, on the other kind %x\n", .{
            owner,
            which,
            readLink(engine, which, afmt_audio),
            readLink(engine, which, afmt_source),
            readLink(engine, which, afmt_infoframe),
            readLink(engine, which, hdmi_audio),
            readLink(engine, which, hdmi_clock),
            readLink(engine, which, port_sound),
        });
    }
    exec.kprintf(engine.sys, "%s:   the sample clock is %x of %x, taken from %x\n", .{
        owner,
        readClock(engine, audio_dto_phase),
        readClock(engine, audio_dto_module),
        readClock(engine, audio_dto_source),
    });
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

// --- the pipes ---------------------------------------------------------------------

/// A register of the engine, by its number in 32-bit words from the block
/// the table named.
fn readRegister(engine: Engine, offset: u32) u32 {
    return reg(engine.registers + (engine.block + offset) * 4).*;
}

fn writeRegister(engine: Engine, offset: u32, value: u32) void {
    reg(engine.registers + (engine.block + offset) * 4).* = value;
}

// --- the sound a link carries ------------------------------------------------------

/// The audio side of the link the firmware lit, switched on.
///
/// A codec answers for a display link out of what the display engine was
/// told, and a firmware that only lit the link tells it nothing: the pin
/// answers that there is nothing plugged into it and offers no rates, and
/// the audio driver leaves it alone, which is the right answer for a link
/// whose packets are not being sent. Three things turn that around, and
/// all three are here rather than in the audio driver, because all three
/// are registers of this engine:
///
/// - the clock the samples are counted out by, set from the pixel clock
///   the pipe is scanning at;
/// - the link's packet part: driven as the kind of link that carries
///   packets, its store for the samples out of its low-power state, told
///   which endpoint's samples to carry, how many channels there are, what
///   to say in the status that rides with them and how the far end is to
///   rebuild the sample clock, and sending the description of the sound;
/// - the endpoint itself, told which speakers the far end has and what it
///   takes, and then allowed to answer.
///
/// The endpoint is allowed to answer last, so that the pin never reports
/// a monitor before the rest of the way is standing.
///
/// After this the link is the audio driver's like any other: its pin
/// reports a monitor, and the driver takes the converter, sets the shape
/// and the stream, switches the converter's digital output on and gives
/// the link's slots their channels, and the samples it writes leave the
/// machine. What the far end does with them is the far end's to say.
///
/// False where there was nothing to do it to - no link takes the pipe
/// that is scanning, no endpoint is wired to a socket, or the pipe's
/// frames cannot be timed, so that no pixel clock can be had. Each is
/// said out loud.
pub fn soundUp(engine: Engine) bool {
    const link = litLink(engine) orelse {
        exec.kprintf(engine.sys, "%s: no link takes pipe %d, so its sound is left alone\n", .{ owner, engine.pipe });
        return false;
    };
    const endpoint = wiredEndpoint(engine) orelse {
        exec.kprintf(engine.sys, "%s: no audio endpoint is wired to a socket, so link %d's sound is left alone\n", .{ owner, link });
        return false;
    };
    const pixel_khz = pixelClock(engine) orelse {
        exec.kprintf(engine.sys, "%s: pipe %d's frames cannot be timed, so link %d's sound is left alone\n", .{
            owner, engine.pipe, link,
        });
        return false;
    };

    clockUp(engine, pixel_khz);
    linkUp(engine, link, endpoint, pixel_khz);
    endpointUp(engine, endpoint);

    exec.kprintf(engine.sys, "%s: link %d carries sound from endpoint %d, %d kHz pixels; the pin now sees %x\n", .{
        owner, link, endpoint, pixel_khz, readEndpoint(engine, endpoint, pin_sense),
    });
    return true;
}

/// The link the firmware lit: the one whose front takes the pipe that is
/// scanning and whose clock is running.
fn litLink(engine: Engine) ?u32 {
    var which: u32 = 0;
    while (which < links) : (which += 1) {
        const front = readLink(engine, which, dig_front);
        if (front & front_running == 0) continue;
        if (front >> front_pipe_shift & front_pipe_mask != engine.pipe) continue;
        return which;
    }
    return null;
}

/// The first audio endpoint wired to a socket on the machine's outside.
/// An endpoint that answers nothing for its socket is one no pin of the
/// codec is backed by; one that answers that it is wired to nothing is an
/// endpoint the part has and the machine did not bring out.
fn wiredEndpoint(engine: Engine) ?u32 {
    var which: u32 = 0;
    while (which < endpoints) : (which += 1) {
        const socket = readEndpoint(engine, which, pin_default);
        if (socket == 0) continue;
        if (socket >> socket_wired_shift & socket_wired_mask != 0) continue;
        return which;
    }
    return null;
}

/// The pixel clock of the picture the pipe is scanning, in kilohertz. The
/// engine does not hold the number - the firmware set the clock and kept
/// it - so it is timed: a frame is the pipe's line times its frame in
/// pixels, and how long one takes is read off the pipe's own count of
/// frames against the machine's clock. Each of a few frames is timed on
/// its own and the middle one taken, so that a frame the reading was held
/// up in does not count.
///
/// Where a standard mode has the same picture, the same totals and a
/// clock within half a percent of that, the standard's number is taken
/// instead: it is the clock the firmware set, and the timing is not as
/// exact as the standard. Null where the pipe's count does not move,
/// which is a pipe to leave alone.
fn pixelClock(engine: Engine) ?u32 {
    const h_total = engine.h_total + 1;
    const v_total = engine.v_total + 1;
    const timer = sdk.hardware.systimer;
    var periods: [frames_timed]u64 = undefined;
    var timed: usize = 0;
    var last = readPipe(engine, engine.pipe, otg_frame_count);
    var since: u64 = 0;
    var started = false;
    const deadline = timer.uptimeUs() + timing_limit_us;
    // The first frame that begins starts the clock; each one after it
    // ends a period and begins the next.
    while (timed < frames_timed) {
        const now = timer.uptimeUs();
        if (now > deadline) return null;
        const count = readPipe(engine, engine.pipe, otg_frame_count);
        if (count == last) continue;
        last = count;
        if (started) {
            periods[timed] = now - since;
            timed += 1;
        }
        started = true;
        since = now;
    }
    // The middle of them, by sorting a handful in place.
    var at: usize = 1;
    while (at < frames_timed) : (at += 1) {
        var back = at;
        while (back > 0 and periods[back - 1] > periods[back]) : (back -= 1) {
            const held = periods[back];
            periods[back] = periods[back - 1];
            periods[back - 1] = held;
        }
    }
    const frame_us = periods[frames_timed / 2];
    if (frame_us == 0) return null;
    const timed_khz: u32 = @intCast(@as(u64, h_total) * v_total * 1000 / frame_us);
    for (&edid.known) |*timing| {
        if (timing.width != engine.width or timing.height != engine.height) continue;
        if (timing.htotal() != h_total or timing.vtotal() != v_total) continue;
        const apart = if (timing.pixel_khz > timed_khz) timing.pixel_khz - timed_khz else timed_khz - timing.pixel_khz;
        if (apart * 200 <= timing.pixel_khz) return timing.pixel_khz;
    }
    return timed_khz;
}

/// How many frames are timed, and how long the timing may take before
/// the pipe is taken not to be counting: five frames of the slowest
/// picture a link carries, and the one before them.
const frames_timed = 5;
const timing_limit_us: u64 = 300_000;

/// The clock the samples are counted out by: 24 MHz divided out of the
/// pixel clock. Which pipe it follows and which of the two clocks is in
/// use are written before the ratio, which is the order this engine
/// wants them in.
fn clockUp(engine: Engine, pixel_khz: u32) void {
    setClock(engine, audio_dto_source, dto_pipe_shift, dto_pipe_mask, engine.pipe);
    setClock(engine, audio_dto_source, dto_which_shift, dto_which_mask, 0);
    writeClock(engine, audio_dto_module, pixel_khz * hundreds_in_a_kilohertz);
    writeClock(engine, audio_dto_phase, dto_phase_hundreds);
}

/// One link's packet part set to carry the samples of one endpoint.
fn linkUp(engine: Engine, link: u32, endpoint: u32, pixel_khz: u32) void {
    // The kind of link it is driven as. Where the firmware left it driving
    // a picture and nothing else, its blanking carries nothing and no
    // amount of telling the rest of the engine about sound puts anything
    // there, so it is moved to the kind that carries packets - which is
    // the same wire, the same mode and the same picture, with the blanking
    // put to use. Nothing else of the picture is touched: the timing, the
    // front end and the buffer the pipe reads are left alone. Whether the
    // monitor takes packets is not asked - nothing on this path reads what
    // the monitor says of itself - so one that takes a picture alone is
    // sent them too.
    const kind = readLink(engine, link, dig_back) >> back_kind_shift & back_kind_mask;
    if (kind == back_kind_picture_only) {
        setLink(engine, link, dig_back, back_kind_shift, back_kind_mask, back_kind_with_packets);
        exec.kprintf(engine.sys, "%s: link %d was driving a picture only; it now carries packets too\n", .{ owner, link });
    }
    // Nothing of its own between the packets it is asked to send.
    orLink(engine, link, hdmi_control, control_no_extra_empty);
    // The blanking filled: the general control sent and kept being sent,
    // and empty packets where there is nothing else, so that what is sent
    // between the pictures is a stream the far end can follow.
    orLink(engine, link, hdmi_general_packet, packet_empty | packet_general | packet_general_always);
    // The part's own clock, without which none of the rest of it moves.
    orLink(engine, link, afmt_clock, link_clock_on);
    // The store the samples pass through, out of its low-power state.
    setLink(engine, link, afmt_memory, memory_force_shift, memory_force_mask, 0);
    orLink(engine, link, afmt_memory, memory_low_power_off);
    // The packets wait for the pixels of the line they belong to.
    orLink(engine, link, hdmi_audio, 1 << 4);
    // The status that rides with the samples is taken up as written.
    orLink(engine, link, afmt_audio, samples_status_again);
    // The layout is the one the channel count gives, and the first two
    // channels are the ones on.
    andLink(engine, link, afmt_layout, ~(layout_override | layout_oversampling));
    setLink(engine, link, afmt_layout, layout_channels_shift, layout_channels_mask, layout_channels_stereo);
    // The far end is told how to rebuild the sample clock: the engine
    // works the cycle out, the numbers go by themselves, and they do not
    // come before the picture.
    orLink(engine, link, hdmi_clock, acr_sending);
    andLink(engine, link, hdmi_clock, ~(acr_from_what_is_written | acr_before_the_picture));
    // The pair for each rate. The cycle is the pixel clock where the
    // samples a cycle and the rate agree, which is what the standard's
    // numbers are chosen for.
    setLink(engine, link, acr_32_samples, acr_samples_shift, acr_samples_mask, acr_samples_32);
    setLink(engine, link, acr_32_cycle, acr_cycle_shift, acr_cycle_mask, cycleFor(pixel_khz, acr_samples_32, acr_rate_32 * 10));
    setLink(engine, link, acr_44_samples, acr_samples_shift, acr_samples_mask, acr_samples_44);
    setLink(engine, link, acr_44_cycle, acr_cycle_shift, acr_cycle_mask, cycleFor(pixel_khz, acr_samples_44, acr_rate_44_tenths));
    setLink(engine, link, acr_48_samples, acr_samples_shift, acr_samples_mask, acr_samples_48);
    setLink(engine, link, acr_48_cycle, acr_cycle_shift, acr_cycle_mask, cycleFor(pixel_khz, acr_samples_48, acr_rate_48 * 10));
    // Which channel each side is, and that the clock is as accurate as
    // such a clock usually is.
    setLink(engine, link, afmt_status_left, status_channel_shift, status_channel_mask, 1);
    setLink(engine, link, afmt_status_left, status_accuracy_shift, status_accuracy_mask, 0);
    setLink(engine, link, afmt_status_right, status_channel_shift, status_channel_mask, 2);
    setLink(engine, link, afmt_status_rest, 0, status_rest_mask, status_rest_channels);
    // The description of the sound - how many channels there are and what
    // kind they are - goes out between the pictures, on the second line of
    // the blanking. Without it a monitor has not been told what is coming
    // and stays quiet whatever arrives. The description is the one the
    // codec wrote, taken up again now that it is being sent.
    orLink(engine, link, hdmi_sending, sending_sound_description | sending_sound_description_always);
    setLink(engine, link, hdmi_sending_line, sending_line_shift, sending_line_mask, sending_line);
    orLink(engine, link, afmt_infoframe, description_again);
    // And the far end is not told to mute.
    andLink(engine, link, hdmi_general, ~general_mute);
    // Whose samples they are, and that they are being sent.
    writeLink(engine, link, afmt_source, (endpoint & link_from_mask) << link_from_shift);
    orLink(engine, link, afmt_audio, samples_sending);
}

/// How long a cycle of the sample clock is in pixels: the samples a cycle
/// over the rate, times the pixel clock. The rate is in tenths of a
/// kilohertz, so that 44.1 is a whole number of them.
fn cycleFor(pixel_khz: u32, samples: u32, rate_tenths: u32) u32 {
    const whole = @as(u64, pixel_khz) * samples * 10;
    const over = @as(u64, 128) * rate_tenths;
    const cycle = whole / over;
    return if (cycle > acr_cycle_mask) acr_cycle_mask else @intCast(cycle);
}

/// One endpoint told what the far end has and allowed to answer. Its
/// registers are held awake while they are written and let go of after,
/// which is how this part wants them reached.
fn endpointUp(engine: Engine, endpoint: u32) void {
    orEndpoint(engine, endpoint, pin_hotplug, answering_awake);

    var speakers = readEndpoint(engine, endpoint, pin_speaker);
    speakers = speakers & ~(speakers_mask << speakers_shift) | speakers_stereo << speakers_shift;
    speakers = speakers & ~speakers_port | speakers_wire;
    writeEndpoint(engine, endpoint, pin_speaker, speakers);

    const description = (description_stereo_channels - 1) << description_channels_shift |
        description_rates << description_rates_shift |
        description_sizes << description_sizes_shift |
        description_rates << description_stereo_shift;
    writeEndpoint(engine, endpoint, pin_descriptor, description);

    orEndpoint(engine, endpoint, pin_hotplug, answering_on);
    andEndpoint(engine, endpoint, pin_hotplug, ~answering_awake);
}

// --- writing a register, a field of one, and an endpoint's own ---------------------

fn writeClock(engine: Engine, offset: u32, value: u32) void {
    reg(engine.registers + (engine.clocks + offset) * 4).* = value;
}

fn setClock(engine: Engine, offset: u32, shift: u5, mask: u32, value: u32) void {
    writeClock(engine, offset, readClock(engine, offset) & ~(mask << shift) | (value & mask) << shift);
}

fn writeLink(engine: Engine, link: u32, offset: u32, value: u32) void {
    writeRegister(engine, offset + link * link_stride, value);
}

fn orLink(engine: Engine, link: u32, offset: u32, bits: u32) void {
    writeLink(engine, link, offset, readLink(engine, link, offset) | bits);
}

fn andLink(engine: Engine, link: u32, offset: u32, bits: u32) void {
    writeLink(engine, link, offset, readLink(engine, link, offset) & bits);
}

fn setLink(engine: Engine, link: u32, offset: u32, shift: u5, mask: u32, value: u32) void {
    writeLink(engine, link, offset, readLink(engine, link, offset) & ~(mask << shift) | (value & mask) << shift);
}

/// One of an audio endpoint's own registers written, through its latch.
fn writeEndpoint(engine: Engine, endpoint: u32, offset: u32, value: u32) void {
    writeRegister(engine, endpoint_index + endpoint * endpoint_stride, offset);
    writeRegister(engine, endpoint_data + endpoint * endpoint_stride, value);
}

fn orEndpoint(engine: Engine, endpoint: u32, offset: u32, bits: u32) void {
    writeEndpoint(engine, endpoint, offset, readEndpoint(engine, endpoint, offset) | bits);
}

fn andEndpoint(engine: Engine, endpoint: u32, offset: u32, bits: u32) void {
    writeEndpoint(engine, endpoint, offset, readEndpoint(engine, endpoint, offset) & bits);
}

/// A register of the engine's clocks, which are counted from the
/// engine's other block.
fn readClock(engine: Engine, offset: u32) u32 {
    return reg(engine.registers + (engine.clocks + offset) * 4).*;
}

/// One of an audio endpoint's own registers, through its latch.
fn readEndpoint(engine: Engine, endpoint: u32, offset: u32) u32 {
    writeRegister(engine, endpoint_index + endpoint * endpoint_stride, offset);
    return readRegister(engine, endpoint_data + endpoint * endpoint_stride);
}

/// A register of one link's packet part.
fn readLink(engine: Engine, link: u32, offset: u32) u32 {
    return readRegister(engine, offset + link * link_stride);
}

/// A register of one pipe's timing generator.
fn readPipe(engine: Engine, pipe: u32, offset: u32) u32 {
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
