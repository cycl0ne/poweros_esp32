// SPDX-License-Identifier: MPL-2.0
//! The display engine of an AMD graphics device, read as the firmware
//! left it running.
//!
//! A machine whose firmware is UEFI reaches the kernel with a picture
//! already on the glass: the firmware chose a mode, trained the link and
//! told the engine where to read, and all the driver is given is where
//! those pixels are (`uefi.zig`). Nothing of that is undone here. What
//! this does is find the engine behind that framebuffer and read what it
//! was told, so that showing a buffer can one day be naming its address
//! instead of copying a picture into the one buffer the firmware named.
//!
//! **What is written, and what is not.** Nothing of the picture is
//! written: the mode the firmware chose, the link it trained and the
//! buffer the pipe reads are left exactly as they were found, and the
//! picture is still copied into the firmware's framebuffer as before.
//! Writing the address a pipe reads from instead of copying wants two
//! more things first: a buffer of the device's own memory for the picture
//! to live in, which the firmware's framebuffer has no room for - it is
//! exactly one picture - and that memory's writes gathered, which the
//! kernel does for the firmware's framebuffer and a driver has no way to
//! ask for.
//!
//! What is written is the audio side of the link the firmware lit
//! (`soundUp`), which the firmware leaves switched off and which no other
//! driver can reach: those registers are this engine's.
//!
//! ## Where the registers are
//!
//! The engine's registers are in the function's sixth memory window, in
//! blocks whose addresses are not fixed for the part: they are in a table
//! the device's own firmware leaves behind, which lists every block of
//! the chip with its version and the addresses its registers are counted
//! from. That table is read here, so the engine says where its own
//! registers are and what version it is, and a chip this does not know is
//! one this says so about rather than reads at an address that would
//! belong to something else.
//!
//! The addresses in that table count 32-bit registers, so a register's
//! place is `(block + offset) * 4` bytes into the window.
//!
//! ## Where the table is
//!
//! Three places, and which one it was in is said out loud, because it is
//! the first thing to know about a part this has not been run on before.
//!
//! It is left below the top of the device's own memory - but the device's
//! memory is longer than the window onto it, so the top of the window is
//! not the top of the memory and reading there finds a picture, not a
//! table. What reads it is a pair of registers whose place is the same on
//! every part the vendor has made: an address is latched in the first and
//! the four bytes there come back from the second, with no window needed.
//! How far up to look is the device's own answer for how much memory it
//! has.
//!
//! A firmware that keeps that region in the machine's memory instead
//! leaves its address in three more registers of that fixed set, and then
//! the table is read where any other address in the machine is read.
//!
//! And on a part whose window shows all of its memory the table is in the
//! window after all, which is where this looks last.
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
//! answer, the link's packet part is told whose samples to carry, and the
//! clock the samples are counted out by is set from the pixel clock. The
//! audio driver then needs nothing new, because what it was missing was
//! never its own to write.
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

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const pci = sdk.pci;
const reg = sdk.hardware.mmio.reg;
const ExecBase = sdk.interface.exec.ExecBase;
const PCIBase = sdk.interface.pci.PCIBase;
const PCIDevice = pci.PCIDevice;
const uefi = @import("uefi.zig");
const edid = @import("../edid.zig");

/// Who the function is claimed by, for a listing.
const owner = "rtg-fb";
/// The vendor, and the class every display function carries in its upper
/// sixteen bits.
const VENDOR: u32 = 0x1002;
const CLASS_DISPLAY: u32 = 0x0300;

/// The window the memory is in, and the one the registers are in.
const bar_memory = 0;
const bar_registers = 5;
/// The least either window can be and still be the one: a chip's
/// registers fill a quarter of a mebibyte, and its memory is never a
/// handful of pages.
const registers_least = 256 * 1024;
const memory_least = 16 * 1024 * 1024;

// --- the table that says where the blocks are --------------------------------------

/// What the table's first word is, what the list of blocks inside it
/// begins with, and which block is the display engine.
const binary_mark: u32 = 0x2821_1407;
const list_mark: u32 = 0x5344_5049;
const display_block: u16 = 271;

/// The table sits below the top of the device's memory, and is looked for
/// from there downwards on whole pages. The distance is fixed, but the
/// memory above the window's end is not always the device's to show, so
/// the look walks rather than trusting one place.
const table_below_top = 64 * 1024;
const look_page = 4096;
const look_bytes = 64 * 1024 * 1024;

/// How much of the table is read out of the device. It is the room the
/// firmware reserves for it; the list of blocks is far shorter, and the
/// rest is the other tables of the same binary.
const table_bytes = 10 * 1024;

/// The pair that reads the device's own memory with no window onto it,
/// and the registers that say how much memory there is and where the
/// firmware put the table when it is not in that memory. These few have
/// the same place on every part of this vendor, which is what makes them
/// readable before the table that says where everything else is.
/// Counted in 32-bit words, as every register here is.
const mm_index = 0x0;
const mm_data = 0x1;
const mm_index_high = 0x6;
const config_memsize = 0xde3;
const scratch_address = 0x94;
const scratch_address_high = 0x95;
const scratch_bytes = 0x96;

/// In the latched address, that it is an address in the device's memory
/// and not one of the device's registers. It takes the place of the
/// address's own bit 31, which is why the upper register is given the
/// address shifted by one less than the half it carries.
const index_is_memory: u32 = 0x8000_0000;
const index_high_shift = 31;

/// The furthest up the device's memory the table is looked for, so that a
/// device answering with something wild for how much memory it has is not
/// read at an address that means nothing.
const memory_most: u64 = 64 * 1024 * 1024 * 1024;

/// Where the list of blocks is in the table, and how long an entry of the
/// table's own list is.
const binary_list_at = 12;
const binary_list_entry = 8;
/// In the list of blocks: its own version and the version from which a
/// block's addresses may be 64-bit, where the count of dies is, where
/// their places are, and where the word that says how wide those
/// addresses are.
const list_version_at = 4;
const list_version_wide = 4;
const list_dies_at = 12;
const list_die_at = 14;
const list_dies_most = 16;
const list_wide_at = 78;
/// A die's own header, and a block's entry in it.
const die_count_at = 2;
const die_first_at = 4;
const block_instance_at = 2;
const block_addresses_at = 3;
const block_version_at = 4;
const block_header_bytes = 8;

/// The blocks of one chip this reads from, and the two of a block's
/// addresses the registers here are counted from. A display engine
/// answers with six: the third holds the pipes, the links and the audio
/// endpoints, and the second the clocks the engine is given.
const blocks_most = 8;
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
const dto_which_mask: u32 = 0x1;
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
    /// The function, for giving it back, and pci.library as it was opened
    /// and as it is called.
    device: *PCIDevice,
    library: *exec.Library,
    base: *PCIBase,
    sys: *ExecBase,
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

/// The engine behind the framebuffer `fb`, claimed, with what it says of
/// itself read out. Null where the machine has no pci.library, no display
/// function of this vendor, one somebody else has claimed, one whose
/// windows are not the two this reads, one whose memory the firmware's
/// framebuffer is not in - which is a display function that is not the
/// one driving the screen - one whose table of blocks is not there or
/// does not hold a display engine, or one no pipe of which is scanning
/// the picture the firmware described. Each of those is said out loud:
/// what this reads is worth knowing even when it comes to nothing, since
/// it is read on a machine the author does not have.
pub fn find(sys: *ExecBase, fb: uefi.Framebuffer) ?Engine {
    const lib = sys.OpenLibrary(pci.PCINAME, 1) orelse return null;
    const base: *PCIBase = @ptrCast(lib);
    var found: ?*PCIDevice = null;
    while (base.FindPCIDevice(found, VENDOR, pci.PCI_ANY)) |device| {
        found = device;
        if (device.class_code >> 8 != CLASS_DISPLAY) continue;
        if (base.ClaimPCIDevice(device, owner) != null) continue;
        if (engineOf(sys, lib, base, device, fb)) |engine| return engine;
        base.ReleasePCIDevice(device);
    }
    sys.CloseLibrary(lib);
    return null;
}

/// The function given back and pci.library closed.
pub fn forget(engine: *Engine) void {
    engine.base.ReleasePCIDevice(engine.device);
    engine.sys.CloseLibrary(engine.library);
}

/// One function read through: its windows, its table of blocks, and the
/// pipe that is scanning the firmware's picture.
fn engineOf(sys: *ExecBase, lib: *exec.Library, base: *PCIBase, device: *PCIDevice, fb: uefi.Framebuffer) ?Engine {
    const memory = window(device, bar_memory, memory_least) orelse return say(sys, device, "its memory window is not one this reads");
    const registers = window(device, bar_registers, registers_least) orelse return say(sys, device, "its register window is not one this reads");
    // The one free check that this is the function driving the screen.
    if (fb.pixels < memory.at or fb.pixels >= memory.at + memory.bytes) {
        return say(sys, device, "the firmware's framebuffer is not in its memory, so it is not the display's");
    }

    const table = tableOf(sys, memory, registers) orelse return say(sys, device, "it leaves no table of blocks in any of the three places one is looked for");
    defer sys.FreeVec(table.room);
    const engine_block = blockIn(table.at) orelse return say(sys, device, "its table of blocks holds no display engine");
    exec.kprintf(sys, "%s: the table of blocks is in %s\n", .{ owner, table.where });
    var engine: Engine = .{
        .device = device,
        .library = lib,
        .base = base,
        .sys = sys,
        .memory = memory.at,
        .memory_bytes = memory.bytes,
        .registers = registers.at,
        .block = engine_block.block,
        .clocks = engine_block.clocks,
        .major = engine_block.major,
        .minor = engine_block.minor,
        .revision = engine_block.revision,
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
    engine.shift = fetcher.surface -% @as(u64, fb.pixels - memory.at);

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

/// A line about a function that was looked at and left alone, and null,
/// which is what the caller returns.
fn say(sys: *ExecBase, device: *PCIDevice, why: [*:0]const u8) ?Engine {
    exec.kprintf(sys, "%s: %x:%x is a display function and %s\n", .{
        owner, @as(u32, device.vendor_id), @as(u32, device.device_id), why,
    });
    return null;
}

/// One of the function's memory windows: where it is and how long.
const Window = struct { at: usize, bytes: usize };

/// A window of the function, when it is memory the firmware or the
/// library placed, it is at least `least` bytes, and it is within what
/// this machine can address.
fn window(device: *PCIDevice, which: usize, least: usize) ?Window {
    const bar = device.bars[which];
    if (bar.address == 0 or bar.size < least) return null;
    if (bar.flags & pci.PCIBAR_IO != 0) return null;
    if (bar.address > std.math.maxInt(usize) or bar.address + bar.size > std.math.maxInt(usize)) return null;
    return .{ .at = @intCast(bar.address), .bytes = @intCast(bar.size) };
}

// --- the table of blocks -----------------------------------------------------------

/// The display engine's entry in the chip's table of blocks: where its
/// registers are counted from - the pipes' and the clocks' - and what
/// version it is.
const Block = struct { block: u32, clocks: u32, major: u8, minor: u8, revision: u8 };

/// The display engine's entry read out of the table at `table`.
fn blockIn(table: usize) ?Block {
    // The first entry of the table's own list is the list of blocks, as
    // far into the table as that entry says.
    const list = table + word16(table + binary_list_at);
    if (word32(list) != list_mark) return null;
    const dies = @min(word16(list + list_dies_at), list_dies_most);
    // The word after the dies is what says whether a block's addresses
    // are 64-bit, and only from the fourth version of the list: before
    // that it is padding, and every address is 32-bit.
    const wide = word16(list + list_version_at) >= list_version_wide and word8(list + list_wide_at) & 1 != 0;
    var die: u32 = 0;
    while (die < dies) : (die += 1) {
        const place = word16(list + list_die_at + die * 4 + 2);
        if (place == 0) continue;
        if (blockInDie(table + place, wide)) |block| return block;
    }
    return null;
}

/// The first instance of the display engine among one die's blocks, or
/// null. Every entry is walked whether or not it is the one, since an
/// entry's length is its own number of addresses and the next one begins
/// after it.
fn blockInDie(die: usize, wide: bool) ?Block {
    const count = word16(die + die_count_at);
    var at = die + die_first_at;
    var which: u32 = 0;
    while (which < count) : (which += 1) {
        const what = word16(at);
        const addresses = word8(at + block_addresses_at);
        const first = at + block_header_bytes;
        if (what == display_block and word8(at + block_instance_at) == 0 and addresses > block_wanted) {
            // Even where the addresses are 64-bit, the lower half is what
            // the registers are counted from.
            const address = if (wide) word32(first + block_wanted * 8) else word32(first + block_wanted * 4);
            const clocks = if (wide) word32(first + clocks_wanted * 8) else word32(first + clocks_wanted * 4);
            return .{
                .block = address,
                .clocks = clocks,
                .major = word8(at + block_version_at),
                .minor = word8(at + block_version_at + 1),
                .revision = word8(at + block_version_at + 2),
            };
        }
        at = first + addresses * @as(usize, if (wide) 8 else 4);
    }
    return null;
}

/// The table, wherever it was found: where it can be read, the room a
/// copy of it is in - which is given back once it has been read, and null
/// where the table was read where it lies - and where it came from, for
/// the line that says so.
const Table = struct { at: usize, room: ?*anyopaque = null, where: [*:0]const u8 };

/// The chip's table of blocks, looked for in each of the three places it
/// is. The device's own memory first, read through the latch, as far up
/// as the device says its memory goes; then the machine's memory, where a
/// firmware that keeps the region there leaves the address; then the
/// window, which is where it is on a part whose window shows all of its
/// memory. Each is taken only when what is there begins with the table's
/// mark, so a place that holds something else is passed over rather than
/// read as a table.
fn tableOf(sys: *ExecBase, memory: Window, registers: Window) ?Table {
    // Every register read here is within the first kibibytes of the
    // window but for one, which is checked for rather than assumed.
    if (registers.bytes > (scratch_bytes + 1) * 4 and registers.bytes > (config_memsize + 1) * 4) {
        const megabytes = readWord(registers, config_memsize);
        const memory_bytes = @as(u64, megabytes) << 20;
        if (megabytes != 0 and memory_bytes <= memory_most and memory_bytes > table_below_top) {
            if (copyOut(sys, registers, memory_bytes - table_below_top)) |room| {
                return .{ .at = @intFromPtr(room), .room = room, .where = "the top of the device's own memory" };
            }
        }
        const left = @as(u64, readWord(registers, scratch_address_high)) << 32 |
            readWord(registers, scratch_address);
        const bytes = readWord(registers, scratch_bytes);
        if (bytes >= table_bytes and left != 0 and left % 4 == 0 and left <= std.math.maxInt(usize) - table_bytes) {
            const at: usize = @intCast(left);
            if (word32(at) == binary_mark) {
                return .{ .at = at, .where = "the machine's memory, where the firmware left it" };
            }
        }
    }
    if (tableAt(memory)) |at| return .{ .at = at, .where = "the device's memory window" };
    return null;
}

/// The table copied out of the device's memory from `at`, in room of our
/// own, when what is there begins with the table's mark; null otherwise,
/// with the room given back. A word at a time, which is what the latch
/// gives: ten kibibytes is a few thousand reads of an uncached register
/// and happens once.
fn copyOut(sys: *ExecBase, registers: Window, at: u64) ?*anyopaque {
    const room = sys.AllocVec(table_bytes, exec.MEMF_ANY) orelse return null;
    const words: [*]u32 = @ptrCast(@alignCast(room));
    var which: usize = 0;
    while (which < table_bytes / 4) : (which += 1) {
        words[which] = readMemory(registers, at + which * 4);
    }
    if (words[0] != binary_mark) {
        sys.FreeVec(room);
        return null;
    }
    return room;
}

/// Four bytes of the device's own memory, through the latch.
fn readMemory(registers: Window, at: u64) u32 {
    writeWord(registers, mm_index, @as(u32, @truncate(at)) | index_is_memory);
    writeWord(registers, mm_index_high, @truncate(at >> index_high_shift));
    return readWord(registers, mm_data);
}

/// A register of the window, by its number in 32-bit words.
fn readWord(registers: Window, offset: u32) u32 {
    return reg(registers.at + offset * 4).*;
}

fn writeWord(registers: Window, offset: u32, value: u32) void {
    reg(registers.at + offset * 4).* = value;
}

/// Where the table is in the device's memory window: below the top, and
/// otherwise looked for on whole pages downwards
/// from there. Null where no page in the stretch begins with the table's
/// mark.
fn tableAt(memory: Window) ?usize {
    if (memory.bytes <= table_below_top) return null;
    const top = memory.at + memory.bytes;
    const likely = top - table_below_top;
    if (word32(likely) == binary_mark) return likely;
    const end = if (memory.bytes > look_bytes) top - look_bytes else memory.at;
    var at = std.mem.alignBackward(usize, likely, look_page);
    while (at >= end) {
        if (word32(at) == binary_mark) return at;
        if (at < end + look_page) break;
        at -= look_page;
    }
    return null;
}

fn word8(at: usize) u8 {
    return sdk.hardware.mmio.reg8(at).*;
}

fn word16(at: usize) u32 {
    return sdk.hardware.mmio.reg16(at).*;
}

fn word32(at: usize) u32 {
    return reg(at).*;
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
/// - the link's packet part, told which endpoint's samples to carry, how
///   many channels there are, what to say in the status that rides with
///   them, and how the far end is to rebuild the sample clock;
/// - the endpoint itself, told which speakers the far end has and what it
///   takes, and then allowed to answer.
///
/// The endpoint is allowed to answer last, so that the pin never reports
/// a monitor before the rest of the way is standing.
///
/// After this the audio driver needs nothing new: its pin reports a
/// monitor, it takes its converter, sets the format and the stream and
/// sends the description of the sound as it already does, and the samples
/// it writes leave the machine. What the far end does with them is the
/// far end's to say.
///
/// False where there was nothing to do it to - no link takes the pipe
/// that is scanning, no endpoint is wired to a socket, or the picture is
/// one no standard times, so that no pixel clock can be had without
/// guessing one. Each is said out loud.
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
        exec.kprintf(engine.sys, "%s: %dx%d of %dx%d is not a picture any standard times, so link %d's sound is left alone\n", .{
            owner, engine.width, engine.height, engine.h_total + 1, engine.v_total + 1, link,
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

/// The pixel clock of the picture the pipe is scanning, in kilohertz,
/// from the standard that times it: the engine does not hold the number,
/// and the one standard mode whose line and frame are as long as the
/// pipe's does. Null where no mode matches, which is a picture to leave
/// alone rather than count a clock for.
fn pixelClock(engine: Engine) ?u32 {
    for (&edid.known) |*timing| {
        if (timing.width != engine.width or timing.height != engine.height) continue;
        if (timing.htotal() != engine.h_total + 1 or timing.vtotal() != engine.v_total + 1) continue;
        return timing.pixel_khz;
    }
    return null;
}

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
    // The part's own clock, without which none of the rest of it moves.
    orLink(engine, link, afmt_clock, link_clock_on);
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
