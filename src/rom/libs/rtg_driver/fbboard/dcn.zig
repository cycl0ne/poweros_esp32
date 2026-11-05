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
//! **Nothing is written.** Every register below is read. Writing the
//! address a pipe reads from wants two more things first: a buffer of the
//! device's own memory for the picture to live in, which the firmware's
//! framebuffer has no room for - it is exactly one picture - and that
//! memory's writes gathered, which the kernel does for the firmware's
//! framebuffer and a driver has no way to ask for. And until the numbers
//! this reads have been seen on a machine, writing one would be writing
//! where the picture is from a guess.
//!
//! ## Where the registers are
//!
//! The engine's registers are in the function's sixth memory window, in
//! blocks whose addresses are not fixed for the part: they are in a table
//! the device's own firmware leaves in the top of its memory, which lists
//! every block of the chip with its version and the addresses its
//! registers are counted from. That table is read here - plain memory
//! reads through the first window, no register touched to find it - so
//! the engine says where its own registers are and what version it is,
//! and a chip this does not know is one this says so about rather than
//! reads at an address that would belong to something else.
//!
//! The addresses in that table count 32-bit registers, so a register's
//! place is `(block + offset) * 4` bytes into the window.
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

/// The blocks of one chip this reads from, and the one its registers are
/// counted from. A display engine answers with six; the third is the one
/// every register below is in.
const blocks_most = 8;
const block_wanted = 2;

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
    /// Where the registers read here are counted from, in 32-bit words.
    block: u32,
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

    const engine_block = blockOf(memory) orelse return say(sys, device, "it leaves no table of blocks where one is looked for");
    var engine: Engine = .{
        .device = device,
        .library = lib,
        .base = base,
        .sys = sys,
        .memory = memory.at,
        .memory_bytes = memory.bytes,
        .registers = registers.at,
        .block = engine_block.block,
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
    return engine;
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
/// registers are counted from, and what version it is.
const Block = struct { block: u32, major: u8, minor: u8, revision: u8 };

/// The table found in the device's memory and the display engine's entry
/// read out of it. Memory reads only: the table is in the top of the
/// device's own memory, which the first window shows.
fn blockOf(memory: Window) ?Block {
    const table = tableAt(memory) orelse return null;
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
            return .{
                .block = address,
                .major = word8(at + block_version_at),
                .minor = word8(at + block_version_at + 1),
                .revision = word8(at + block_version_at + 2),
            };
        }
        at = first + addresses * @as(usize, if (wide) 8 else 4);
    }
    return null;
}

/// Where the table is in the device's memory: below the top, which is
/// where it is left, and otherwise looked for on whole pages downwards
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
