// SPDX-License-Identifier: MPL-2.0
//! What the display asks of the chip for what it shows: the clocks its
//! parts run at, the state the power manager holds the display
//! controller's clock and the memory in, and the hub's watermarks -
//! worked out as the vendor's mode library works them out for this engine
//! (display_mode_vba_314), for what this driver lights: one timing
//! generator with up to four planes on it, each read by a fetcher of its
//! own from memory laid out in rows - uncompressed, unturned, through the
//! engine's page table of one level and without a second one of the
//! host's - and flipped at the frame's start, never at once.
//!
//! **The clocks** follow from the planes alone (`clocksOf`). The display
//! clock is the pixel clock with the spread and the ramp's margin added,
//! rounded up to a step the dividers make of the PLL (`dfsUp`). A pipe's
//! clock is the pixel clock times what its scaler takes - its taps, its
//! ratios over what the scaler passes on a cycle, twice the pixel clock
//! past six taps - with the spread added; the pipes' clock is the
//! fastest of them rounded up to a step, and each pipe's is a whole
//! number of 255ths of it, rounded up. The controller's clock in deep
//! sleep is what moves each plane's bytes as fast as its lines are
//! delivered, and all of them as fast as they are read, by 64 bytes a
//! cycle and 15% more, a sixteenth of the pixel clock and 8 MHz at least.
//!
//! **The state** is the lowest of the power manager's (`Level`, as the
//! vendor builds them from its table: `levelsOf`) whose controller and
//! fabric clocks and memory return what the planes read
//! (`returnOf`: 64 bytes a cycle of the controller's clock, 32 a cycle of
//! the fabric's, 80% of the less after the urgent latency, or 65% of
//! what the memory's channels move) - where the reorder buffer outlasts
//! the round trip and the reordering, the active picture's reads take 60%
//! of the fabric's and the memory's at most, the reads with the prefetch
//! and their bursts after the urgent latency fit in the return, and every
//! plane's buffer outlasts the urgent latency (`supports`). Its controller
//! clock is the least the manager is asked to hold it at.
//!
//! **The watermarks** (`watermarksOf`) are the urgent latency and the extra
//! one - the round trip and the bytes it waits behind: the channels'
//! reordering, each pipe's chunk and its page-table group - and, on top
//! of those, the memory's own latencies: its clock's change, self-refresh's
//! exit and its entry and exit, and the deeper state's, each with ten
//! cycles of the deep-sleep clock. The deeper state's entry and exit is
//! raised to its least residency where the planes' buffers last less long.
//! The memory's clock changes in the active picture where every plane's
//! line buffer and hub buffer outlast its pipe's delay, the urgent
//! watermark and the change's; with one timing generator it changes in the
//! blank otherwise (`changeInActive`).
//!
//! The prefetch it is checked with is the schedule's (`mode.scheduleFor`),
//! worked out at these clocks with the wait for the memory its prefetch
//! mode allows: the memory clock's change and the urgent latency, or
//! self-refresh's entry and exit, whichever is longer (mode 0); where no
//! state serves that, self-refresh's alone (mode 1).
//!
//! Everything is integers: clocks in kHz or Hz, times in picoseconds,
//! bandwidth in bytes a second, ratios in 19 bits.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const mode = @import("mode.zig");

/// The most planes one timing generator lays, and the most states.
pub const planes_most = 4;
pub const levels_most = 8;

// --- what the engine is, as the vendor's model has it -----------------------------------

/// The spread on the display's clocks and the display clock's ramp, in
/// thousandths and hundredths.
const spread_thousandths: u64 = 1005;
const ramp_hundredths: u64 = 101;
/// The least the display clock runs at, in kHz.
const display_least_khz: u32 = 100_000;
/// What the scaler takes from the hub and passes to the line buffer, in
/// pixels a cycle; a vertical filter's taps it passes on a cycle.
const hub_to_scaler: u64 = 4;
const scaler_to_line_buffer: u64 = 2;
const taps_a_cycle: u64 = 6;
/// The line buffer: its bits, a pixel's, and the lines it holds at most.
const line_buffer_bits: u64 = 789_504;
const line_buffer_pixel_bits: u64 = 48;
const line_buffer_lines: u64 = 12;
/// The reorder buffer and a pipe's chunk of it, in bytes; the bytes a
/// channel may return out of order.
const reorder_buffer_bytes: u64 = 64 * 1024;
const chunk_bytes: u64 = 8 * 1024;
const out_of_order_bytes: u64 = 4096;
/// The round trip to the memory and the arbiter's delay, in cycles of the
/// controller's clock.
const round_trip_cycles: u64 = 106 + 7 + 95;
/// The bytes the controller and the fabric return a cycle.
const return_bus_bytes: u64 = 64;
const fabric_bytes: u64 = 32;
/// The share of the ideal bandwidth the display gets after the urgent
/// latency, and in normal operation, in hundredths.
const after_urgent_fabric: u64 = 80;
const after_urgent_memory: u64 = 65;
const normal_share: u64 = 60;
/// The urgent latency, in picoseconds.
const urgent_ps: u64 = 4_000_000;
/// The deeper state's exit and its entry and exit, and the least it is
/// stayed in, in picoseconds.
const z8_exit_ps: u64 = 390_000_000;
const z8_enter_exit_ps: u64 = 601_000_000;
const z8_residency_ps: u64 = 2_100_000_000;
/// The deep-sleep clock's factor, in hundredths, and its least, in Hz.
const deep_sleep_hundredths: u64 = 115;
const deep_sleep_least_hz: u64 = 8_000_000;
/// The cursor every plane but a film's has in the sums: 256 pixels of 32
/// bits, in a buffer of 16 KiB.
const cursor_bytes: u64 = 256 * 4;
const cursor_buffer_bytes: u64 = 16 * 1024;
/// The page table's requests: 64 bytes, a buffer of 64 for a plane's
/// brightness and 34 for its colour - all 98 for a plane of one - and
/// the group a pipe fetches.
const pte_request_bytes: u64 = 64;
const pte_requests_luma: u64 = 64;
const pte_requests_chroma: u64 = 34;
const pte_group_bytes: u64 = 2048;
/// A page-table request reaches 32 KiB of a surface laid out in rows.
const pte_reach_bytes: u64 = 32 * 1024;

const ratio_one: u64 = 1 << 19;
const ps_a_second: u64 = 1_000_000_000_000;

/// `value` times `by` over `over`, the product in 128 bits.
fn scaled(value: u64, by: u64, over: u64) u64 {
    return @intCast(@as(u128, value) * by / over);
}

// --- the facts -------------------------------------------------------------------------------

/// The memory, as the video BIOS names it: the latency its clock's change
/// takes, self-refresh's exit and its entry and exit, in picoseconds; its
/// channels and a channel's bytes.
pub const Memory = struct {
    change_ps: u64,
    exit_ps: u64,
    enter_exit_ps: u64,
    channels: u32,
    channel_bytes: u32,
};

/// The video BIOS's memory types: SMBIOS's numbers.
pub const MEMORY_DDR5: u8 = 0x22;
pub const MEMORY_LPDDR5: u8 = 0x23;

/// The memory of `kind` with `channels` channels - none named: four - as
/// the vendor's driver takes it: LPDDR5's latencies or DDR5's, eight
/// bytes a channel for DDR5 and four for every other.
pub fn memoryOf(kind: u8, channels: u8) Memory {
    const lpddr5 = kind == MEMORY_LPDDR5;
    return .{
        .change_ps = if (lpddr5) 11_653_330 else 11_720_000,
        .exit_ps = if (lpddr5) 30_000_000 else 12_500_000,
        .enter_exit_ps = if (lpddr5) 32_000_000 else 14_500_000,
        .channels = if (channels != 0) channels else 4,
        .channel_bytes = if (kind == MEMORY_DDR5) 8 else 4,
    };
}

/// Where the video BIOS names the machine's memory: its header, the list
/// of its data tables, the table of the integrated system's facts in it
/// by its number, and in that table, at its revision 2.2, the memory's
/// kind and its channels (atom_integrated_system_info_v2_2).
const bios_header_at = 0x48;
const bios_data_list_at = 0x20;
const bios_system_info = 30;
const system_info_revision: u8 = 2;
const system_info_memory_at = 26;
const system_info_channels_at = 27;

/// The memory the video BIOS `image` names (`memoryOf`); where it names
/// none, as the vendor's driver takes it then: DDR5's latencies, four
/// channels of four bytes.
pub fn memoryOfBios(image: []const u8) Memory {
    const none = memoryOf(0, 0);
    const header = biosHalf(image, bios_header_at) orelse return none;
    const list = biosHalf(image, @as(usize, header) + bios_data_list_at) orelse return none;
    const table: usize = biosHalf(image, @as(usize, list) + 4 + bios_system_info * 2) orelse return none;
    if (table == 0 or table + system_info_channels_at >= image.len) return none;
    if (image[table + 2] != system_info_revision or image[table + 3] != system_info_revision) return none;
    return memoryOf(image[table + system_info_memory_at], image[table + system_info_channels_at]);
}

fn biosHalf(image: []const u8, offset: usize) ?u16 {
    if (offset + 2 > image.len) return null;
    return @as(u16, image[offset]) | @as(u16, image[offset + 1]) << 8;
}

/// A state the power manager can hold: the controller's clock and the
/// fabric's, in kHz, and the memory's transfers a second, in millions.
pub const Level = struct {
    controller_khz: u32,
    fabric_khz: u32,
    memory_mts: u32,
};

/// One of the fabric's states in the power manager's table: its clock and
/// the memory's, in MHz, its voltage, and the memory's WCK ratio code.
pub const Fabric = struct {
    fabric_mhz: u32,
    memory_mhz: u32,
    voltage: u32,
    ratio: u8,
};

/// What the model is worked out with besides the planes: the states, the
/// display's clocks' tops and the PLL they are divided from, in kHz, and
/// the memory.
pub const Facts = struct {
    levels: [levels_most]Level = undefined,
    count: u32 = 0,
    display_most_khz: u32 = 0,
    pipes_most_khz: u32 = 0,
    pll_khz: u32 = 0,
    memory: Memory,
};

fn validClock(mhz: u32) bool {
    return mhz > 1 and mhz < 100_000;
}

fn wckOf(code: u8) u32 {
    return switch (code) {
        1 => 2,
        2 => 4,
        else => 1,
    };
}

/// The states from the power manager's table, as the vendor's driver builds
/// them: one for each of the `count` levels of the controller clock
/// (`controller_mhz`, the table's every entry), with the fabric's slowest
/// state whose voltage the level's own (`soc_voltage`) reaches - the first
/// state's clock where none does, with the memory of the state found for
/// a level before - and a last at the fabric's fastest, with the top of
/// the controller clock's entries, in place of the eighth where there are
/// eight. The memory moves its clock twice a cycle, times its WCK ratio.
pub fn levelsOf(into: *Facts, controller_mhz: []const u32, count_wanted: usize, soc_voltage: []const u32, fabric: []const Fabric) void {
    into.count = 0;
    if (fabric.len == 0) return;
    var fastest: usize = 0;
    var fastest_mhz: u32 = 0;
    for (fabric, 0..) |state, index| {
        if (validClock(state.fabric_mhz) and state.fabric_mhz > fastest_mhz) {
            fastest_mhz = state.fabric_mhz;
            fastest = index;
        }
    }
    var top_controller: u32 = 0;
    for (controller_mhz) |mhz| top_controller = @max(top_controller, mhz);
    var slowest: usize = 0;
    var count: usize = 0;
    for (controller_mhz[0..@min(count_wanted, controller_mhz.len)], 0..) |mhz, level| {
        if (count == levels_most) break;
        var slowest_mhz = fabric[0].fabric_mhz;
        for (fabric[1..], 1..) |state, index| {
            const voltage = if (level < soc_voltage.len) soc_voltage[level] else 0;
            if (validClock(state.fabric_mhz) and state.fabric_mhz < slowest_mhz and state.voltage <= voltage) {
                slowest_mhz = state.fabric_mhz;
                slowest = index;
            }
        }
        into.levels[count] = .{
            .controller_khz = mhz * 1000,
            .fabric_khz = slowest_mhz * 1000,
            .memory_mts = fabric[slowest].memory_mhz * 2 * wckOf(fabric[slowest].ratio),
        };
        count += 1;
    }
    if (fastest != slowest or count == 0) {
        const at: usize = @min(count, levels_most - 1);
        into.levels[at] = .{
            .controller_khz = top_controller * 1000,
            .fabric_khz = fastest_mhz * 1000,
            .memory_mts = fabric[fastest].memory_mhz * 2 * wckOf(fabric[fastest].ratio),
        };
        count = at + 1;
    }
    into.count = @intCast(count);
}

// --- what is laid -----------------------------------------------------------------------------

/// A plane on the timing generator: what its fetcher reads, and the bytes
/// of the hub's buffer it has.
pub const Plane = struct {
    fetch: mode.Fetch,
    buffer_bytes: u32,
};

/// What is laid: the timing, the line the timing generator starts its
/// fetchers on - null for one the schedule works out - and the planes.
pub const Load = struct {
    timings: rtg.RtgTimings,
    vstartup: ?u32 = null,
    planes: []const Plane,
};

/// The clocks the planes need, in kHz - the display clock, the most any
/// pipe needs and each plane's pipe, in the planes' order - and the
/// controller's deep-sleep clock, in Hz.
pub const Clocks = struct {
    display_khz: u32 = 0,
    pipes_khz: u32 = 0,
    pipe_khz: [planes_most]u32 = @splat(0),
    deep_sleep_hz: u32 = 0,
};

/// What the hub is told, in picoseconds: the urgent watermark, the memory
/// clock's change, self-refresh's exit and its entry and exit and the
/// deeper state's, the urgent latency; the planes' read without their
/// bursts as a fraction of the return, in thousandths.
pub const Watermarks = struct {
    urgent_ps: u64 = 0,
    change_ps: u64 = 0,
    exit_ps: u64 = 0,
    enter_exit_ps: u64 = 0,
    z8_exit_ps: u64 = 0,
    z8_enter_exit_ps: u64 = 0,
    latency_ps: u64 = 0,
    fraction: u32 = 0,
};

/// What is asked of the chip for a load: the clocks; the state, its
/// controller clock in kHz; the prefetch mode, the wait for the memory its
/// prefetch allows in nanoseconds, and the watermarks; whether the memory
/// clock changes in the active picture.
pub const Demand = struct {
    clocks: Clocks = .{},
    level: u32 = 0,
    controller_khz: u32 = 0,
    prefetch_mode: u32 = 0,
    wait_ns: u32 = 0,
    watermarks: Watermarks = .{},
    change_in_active: bool = false,

    /// The longest watermark the fetchers' time to urgency in the blank
    /// starts from (MinTTUVBlank, before the time to work out a request):
    /// the memory clock's change where the blank allows it, self-refresh's
    /// entry and exit, the urgent watermark.
    pub fn blankPs(demand: *const Demand) u64 {
        var longest = @max(demand.watermarks.enter_exit_ps, demand.watermarks.urgent_ps);
        if (demand.prefetch_mode == 0) longest = @max(longest, demand.watermarks.change_ps);
        return longest;
    }
};

// --- the working --------------------------------------------------------------------------

/// What one plane is in the model's terms.
const Planar = struct {
    luma: mode.Read,
    chroma: ?mode.Read,
    /// Its lines' time and the bytes of the hub's buffer each part has.
    line_ps: u64,
    luma_buffer: u64,
    chroma_buffer: u64,
    /// The pipe's cursor counted, where its pipe lays it.
    cursor: bool,
};

fn planarOf(plane: Plane, timings: rtg.RtgTimings) Planar {
    const h_total: u64 = @as(u64, timings.h_active) + timings.h_front + timings.h_sync + timings.h_back;
    const line_ps = h_total * ps_a_second / timings.pixel_clock_hz;
    var luma_buffer: u64 = plane.buffer_bytes;
    var chroma_buffer: u64 = 0;
    if (plane.fetch.chroma) |chroma| {
        // Split by the rows' bytes: halves where the brightness's is no
        // more than half again the colour's, else two thirds to it.
        const luma_row = mode.swathOf(plane.fetch.luma) * plane.fetch.luma.bytes;
        const chroma_row = mode.swathOf(chroma) * chroma.bytes;
        if (2 * luma_row <= 3 * chroma_row) {
            luma_buffer = plane.buffer_bytes / 2;
            chroma_buffer = plane.buffer_bytes / 2;
        } else {
            luma_buffer = plane.buffer_bytes * 2 / 3 / 1024 * 1024;
            chroma_buffer = plane.buffer_bytes / 3;
        }
    }
    return .{
        .luma = plane.fetch.luma,
        .chroma = plane.fetch.chroma,
        .line_ps = line_ps,
        .luma_buffer = luma_buffer,
        .chroma_buffer = chroma_buffer,
        .cursor = plane.fetch.cursor,
    };
}

/// The pixels the scaler passes on a cycle, in 19 bits: four at most, two
/// where the plane is not made smaller across, else twice its ratio over
/// the cycles its taps take.
fn throughputOf(read: mode.Read) u64 {
    if (read.h_ratio <= ratio_one) return @min(hub_to_scaler, scaler_to_line_buffer) * ratio_one;
    const cycles = (@as(u64, read.h_taps) + taps_a_cycle - 1) / taps_a_cycle;
    return @min(hub_to_scaler * ratio_one, scaler_to_line_buffer * read.h_ratio / cycles);
}

/// How many times the pixel clock a plane's part needs its pipe's clock,
/// in 19 bits: its vertical taps' share where it is made no smaller across,
/// its pixels over what the scaler passes, once at least - twice past six
/// taps.
fn factorOf(read: mode.Read) u64 {
    const taps = @as(u64, read.v_taps) * @min(ratio_one, @as(u64, read.h_ratio)) / taps_a_cycle;
    const pixels = @as(u64, read.h_ratio) * read.v_ratio / throughputOf(read);
    var factor = @max(taps, @max(pixels, ratio_one));
    if ((read.h_taps > taps_a_cycle or read.v_taps > taps_a_cycle) and factor < 2 * ratio_one) factor = 2 * ratio_one;
    return factor;
}

/// A clock rounded up, and down, to a step the dividers make of the PLL
/// `pll_khz`: four times the PLL over a whole number.
pub fn dfsUp(khz: u64, pll_khz: u64) u64 {
    if (khz == 0) return 0;
    const steps = @max(1, pll_khz * 4 / khz);
    return pll_khz * 4 / steps;
}

pub fn dfsDown(khz: u64, pll_khz: u64) u64 {
    if (khz == 0) return 0;
    const steps = (pll_khz * 4 + khz - 1) / khz;
    return pll_khz * 4 / @max(1, steps);
}

/// The clocks `load`'s planes need (the module's header says how), with
/// the PLL and the tops in `facts`.
pub fn clocksOf(facts: *const Facts, load: Load) Clocks {
    var clocks: Clocks = .{};
    const pixel_khz: u64 = load.timings.pixel_clock_hz / 1000;
    const pixel_hz: u64 = load.timings.pixel_clock_hz;
    const pll: u64 = facts.pll_khz;

    // The display clock: with the ramp's margin, unless that takes it past
    // its top.
    const with_ramp = dfsUp(pixel_khz * spread_thousandths * ramp_hundredths / 100_000, pll);
    const without = dfsUp(pixel_khz * spread_thousandths / 1000, pll);
    const most = dfsDown(facts.display_most_khz, pll);
    const display = if (without > most) without else if (with_ramp > most) most else with_ramp;
    clocks.display_khz = @intCast(@max(display, display_least_khz));

    // Each pipe's, and the pipes' clock: the fastest, rounded up.
    var wanted: [planes_most]u64 = @splat(0);
    var fastest: u64 = 0;
    for (load.planes, 0..) |plane, index| {
        var factor = factorOf(plane.fetch.luma);
        if (plane.fetch.chroma) |chroma| factor = @max(factor, factorOf(chroma));
        wanted[index] = pixel_khz * factor / ratio_one * spread_thousandths / 1000;
        fastest = @max(fastest, wanted[index]);
    }
    const global = dfsUp(fastest, pll);
    for (load.planes, 0..) |_, index| {
        if (global == 0) break;
        const share = (wanted[index] * 255 + global - 1) / global;
        clocks.pipe_khz[index] = @intCast(global * share / 255);
        clocks.pipes_khz = @max(clocks.pipes_khz, clocks.pipe_khz[index]);
    }

    // The controller's deep sleep: each plane's bytes as fast as its lines
    // are delivered, all of them as fast as they are read.
    var deep: u64 = deep_sleep_least_hz;
    var read_total: u64 = 0;
    for (load.planes, 0..) |plane, index| {
        const planar = planarOf(plane, load.timings);
        read_total += readOf(planar.luma, planar.line_ps);
        if (planar.chroma) |chroma| read_total += readOf(chroma, planar.line_ps);
        const pipe_hz = @as(u64, clocks.pipe_khz[index]) * 1000;
        var per = deliveredHz(planar.luma, pixel_hz, pipe_hz, if (planar.chroma != null) 32 else 64);
        if (planar.chroma) |chroma| per = @max(per, deliveredHz(chroma, pixel_hz, pipe_hz, 32));
        deep = @max(deep, @max(per, pixel_hz / 16));
    }
    deep = @max(deep, read_total * deep_sleep_hundredths / (100 * return_bus_bytes));
    clocks.deep_sleep_hz = @intCast(deep);
    return clocks;
}

/// The clock that moves a part's row as fast as its lines are delivered,
/// `per` bytes a cycle and 15% more: at the rate its place is scanned
/// where its lines come no faster than the glass's, else at the rate its
/// scaler takes them across.
fn deliveredHz(read: mode.Read, pixel_hz: u64, pipe_hz: u64, per: u64) u64 {
    const rate = if (read.v_ratio <= ratio_one)
        @as(u64, read.h_ratio) * pixel_hz / ratio_one
    else
        throughputOf(read) * pipe_hz / ratio_one;
    return deep_sleep_hundredths * read.bytes * rate / (100 * per);
}

/// A part's read, in bytes a second: its viewport's row each line, its
/// lines as fast as its ratio down takes them.
fn readOf(read: mode.Read, line_ps: u64) u64 {
    return scaled(@as(u64, read.width) * read.bytes * read.v_ratio, ps_a_second, line_ps * ratio_one);
}

/// The same at the prefetch's ratio `ratio`, its row the swath the
/// prefetch reads.
fn prefetchReadOf(read: mode.Read, ratio: u64, line_ps: u64) u64 {
    return scaled(mode.swathOf(read) * read.bytes * ratio, ps_a_second, line_ps * ratio_one);
}

/// The bytes a second the memory and the fabric return to the display at
/// `level`, after the urgent latency and in normal operation.
pub const Return = struct { urgent: u64, normal: u64 };

pub fn returnOf(facts: *const Facts, level: Level) Return {
    const fabric = @min(return_bus_bytes * level.controller_khz * 1000, fabric_bytes * level.fabric_khz * 1000);
    const memory = @as(u64, level.memory_mts) * 1_000_000 * facts.memory.channels * facts.memory.channel_bytes;
    return .{
        .urgent = @min(fabric * after_urgent_fabric / 100, memory * after_urgent_memory / 100),
        .normal = @min(fabric * normal_share / 100, memory * normal_share / 100),
    };
}

/// A plane's part's page table, read a row of its own at a time: the
/// bytes of a row and the lines it covers.
const PageRows = struct { bytes: u64, lines: u64 };

fn pageRowsOf(read: mode.Read, requests: u64) PageRows {
    const reach = pte_reach_bytes / read.bytes;
    const pitch: u64 = @max(1, read.pitch);
    var lines: u64 = 1;
    const span = requests * reach / pitch;
    while (lines * 2 <= span and lines < 128) lines *= 2;
    const width = ((pitch * lines - 1 + reach - 1) / reach + 1) * reach;
    return .{ .bytes = width / reach * pte_request_bytes, .lines = lines };
}

/// A part's urgent burst: how many times faster it is read for the urgent
/// latency its buffer hides, as a fraction - null where the buffer holds
/// less than the latency. Its buffer's lines at `ratio`.
const Burst = struct { over: u64, under: u64 };

fn burstOf(lines: u64, line_ps: u64, ratio: u64) ?Burst {
    if (ratio == 0) return .{ .over = 1, .under = 1 };
    const time = lines * line_ps * ratio_one / ratio;
    if (time <= urgent_ps) return null;
    return .{ .over = time, .under = time - urgent_ps };
}

/// The lines of a plane's viewport its part of the hub's buffer holds.
fn burstLines(buffer: u64, read: mode.Read) u64 {
    return buffer / read.bytes / @max(1, read.width);
}

/// The cursor's lines in its buffer.
const cursor_lines: u64 = cursor_buffer_bytes / cursor_bytes;

/// What a plane reads, in bytes a second: its pixels; in the active
/// picture - pixels, cursor and page-table rows - with their bursts and
/// without; in the prefetch at its ratios, with and without. Null where a
/// buffer hides no urgent latency.
const Reads = struct { pixels: u64 = 0, active: u64 = 0, plain: u64 = 0, prefetch: u64 = 0, plain_prefetch: u64 = 0 };

fn readsOf(planar: Planar, schedule: *const mode.Schedule) ?Reads {
    const luma_ratio: u64 = schedule.prefetch & prefetch_ratio_mask;
    const chroma_ratio: u64 = schedule.prefetch_chroma & prefetch_ratio_mask;
    var reads: Reads = .{};
    var rows_read: u64 = 0;
    const parts = [_]?mode.Read{ planar.luma, planar.chroma };
    const buffers = [_]u64{ planar.luma_buffer, planar.chroma_buffer };
    const ratios = [_]u64{ luma_ratio, chroma_ratio };
    for (parts, buffers, ratios, 0..) |maybe, buffer, ratio, index| {
        const part = maybe orelse continue;
        const read = readOf(part, planar.line_ps);
        const prefetch = prefetchReadOf(part, ratio, planar.line_ps);
        const lines = burstLines(buffer, part);
        const burst = burstOf(lines, planar.line_ps, part.v_ratio) orelse return null;
        const burst_prefetch = burstOf(lines, planar.line_ps, ratio) orelse return null;
        reads.pixels += read;
        reads.active += read * burst.over / burst.under;
        reads.prefetch += prefetch * burst_prefetch.over / burst_prefetch.under;
        reads.plain += read;
        reads.plain_prefetch += prefetch;
        // Its page table's rows as they are read.
        const requests: u64 = if (planar.chroma == null) pte_requests_luma + pte_requests_chroma else if (index == 0) pte_requests_luma else pte_requests_chroma;
        const rows = pageRowsOf(part, requests);
        rows_read += scaled(rows.bytes * part.v_ratio, ps_a_second, rows.lines * planar.line_ps * ratio_one);
    }
    if (planar.cursor) {
        const cursor = scaled(cursor_bytes * planar.luma.v_ratio, ps_a_second, planar.line_ps * ratio_one);
        const cursor_prefetch = scaled(cursor_bytes * luma_ratio, ps_a_second, planar.line_ps * ratio_one);
        const burst = burstOf(cursor_lines, planar.line_ps, planar.luma.v_ratio) orelse return null;
        const burst_prefetch = burstOf(cursor_lines, planar.line_ps, luma_ratio) orelse return null;
        reads.active += cursor * burst.over / burst.under;
        reads.prefetch += cursor_prefetch * burst_prefetch.over / burst_prefetch.under;
        reads.plain += cursor;
        reads.plain_prefetch += cursor_prefetch;
    }
    reads.active += rows_read;
    reads.plain += rows_read;
    return reads;
}

const prefetch_ratio_mask: u32 = 0x3fffff;

/// The page table's rows a prefetch reads, in bytes a second: a plane's
/// bytes of a row in the half line the schedule gives them.
fn prefetchRowsOf(planar: Planar) u64 {
    var bytes: u64 = 0;
    if (planar.chroma) |chroma| {
        bytes += pageRowsOf(planar.luma, pte_requests_luma).bytes + pageRowsOf(chroma, pte_requests_chroma).bytes;
    } else {
        bytes += pageRowsOf(planar.luma, pte_requests_luma + pte_requests_chroma).bytes;
    }
    return scaled(bytes * 2, ps_a_second, planar.line_ps);
}

/// The wait for the memory a prefetch mode allows, in picoseconds.
pub fn waitOf(memory: Memory, prefetch_mode: u32) u64 {
    return switch (prefetch_mode) {
        0 => @max(memory.change_ps + urgent_ps, @max(memory.enter_exit_ps, urgent_ps)),
        1 => @max(memory.enter_exit_ps, urgent_ps),
        else => urgent_ps,
    };
}

/// What the schedule of plane `index` of `load` is worked out with at
/// `clocks`, waiting `wait_ps` for the memory and with the blank's
/// watermark `blank_ps`.
pub fn heldOf(load: Load, index: usize, clocks: Clocks, wait_ps: u64, blank_ps: u64) mode.Held {
    return .{
        .display_khz = clocks.display_khz,
        .pipes_khz = clocks.pipe_khz[index],
        .pitch = load.planes[index].fetch.luma.pitch,
        .watermark = @intCast(@min(0xffffff, blank_ps * 24 / 1_000_000)),
        .deep_sleep_hz = clocks.deep_sleep_hz,
        .wait_ns = @intCast(wait_ps / 1000),
    };
}

/// Whether `level` serves `load`'s planes, read as `reads` says: the reorder
/// buffer, the active picture's read in normal operation, the reads with
/// the prefetch in the return after the urgent latency.
fn supports(facts: *const Facts, level: Level, reads: []const Reads, prefetch_rows: []const u64) bool {
    const returned = returnOf(facts, level);
    if (returned.urgent == 0 or level.controller_khz == 0) return false;
    const reorder = facts.memory.channels * out_of_order_bytes;
    const buffer_ps = scaled(reorder_buffer_bytes - chunk_bytes, ps_a_second, returned.urgent);
    const trip_ps = round_trip_cycles * 1_000_000_000 / level.controller_khz + scaled(reorder, ps_a_second, returned.urgent);
    if (buffer_ps <= trip_ps) return false;
    var active: u64 = 0;
    var total: u64 = 0;
    for (reads, prefetch_rows) |read, rows| {
        active += read.pixels;
        total += @max(rows, @max(read.active, read.prefetch));
    }
    return active <= returned.normal and total <= returned.urgent;
}

/// The watermarks for `load`'s planes at `level`, with the deep-sleep clock
/// `clocks` has; `reads` and `prefetch_rows` for the fraction of the return.
fn watermarksOf(facts: *const Facts, load: Load, level: Level, clocks: Clocks, reads: []const Reads, prefetch_rows: []const u64) Watermarks {
    const returned = returnOf(facts, level).urgent;
    const count: u64 = load.planes.len;
    const bytes = facts.memory.channels * out_of_order_bytes + count * (chunk_bytes + pte_group_bytes);
    const extra = round_trip_cycles * 1_000_000_000 / level.controller_khz + scaled(bytes, ps_a_second, returned);
    const sleep_ps = 10 * ps_a_second / clocks.deep_sleep_hz;
    var marks: Watermarks = .{
        .urgent_ps = urgent_ps + extra,
        .latency_ps = urgent_ps,
    };
    marks.change_ps = facts.memory.change_ps + marks.urgent_ps;
    marks.exit_ps = facts.memory.exit_ps + extra + sleep_ps;
    marks.enter_exit_ps = facts.memory.enter_exit_ps + extra + sleep_ps;
    marks.z8_exit_ps = z8_exit_ps + extra + sleep_ps;
    marks.z8_enter_exit_ps = z8_enter_exit_ps + extra + sleep_ps;
    if (stutterPs(load) < z8_residency_ps and marks.z8_enter_exit_ps < z8_residency_ps) marks.z8_enter_exit_ps = z8_residency_ps;
    var plain: u64 = 0;
    for (reads, prefetch_rows) |read, rows| plain += @max(rows, @max(read.plain, read.plain_prefetch));
    marks.fraction = @intCast(@min(0xffff, plain * 1000 / returned));
    return marks;
}

/// The shortest time a plane's hub buffer holds its brightness's lines: how
/// long the memory may stay in self-refresh between bursts.
fn stutterPs(load: Load) u64 {
    var shortest: u64 = 0;
    for (load.planes, 0..) |plane, index| {
        const planar = planarOf(plane, load.timings);
        const lines = planar.luma_buffer / planar.luma.bytes / @max(1, planar.luma.width);
        const time = lines * planar.line_ps * ratio_one / @max(1, planar.luma.v_ratio);
        if (index == 0 or time < shortest) shortest = time;
    }
    return shortest;
}

/// Whether the memory clock changes in the active picture: every plane's
/// line buffer and hub buffer outlast its pipe's delay, the urgent
/// watermark and the change's - less part of a row where there are more
/// planes than one.
fn changeInActive(load: Load, clocks: Clocks, marks: Watermarks) bool {
    const count: u64 = load.planes.len;
    for (load.planes, 0..) |plane, index| {
        const planar = planarOf(plane, load.timings);
        const delay = mode.afterScalerPs(plane.fetch, clocks.display_khz, clocks.pipe_khz[index]);
        const parts = [_]?mode.Read{ planar.luma, planar.chroma };
        const buffers = [_]u64{ planar.luma_buffer, planar.chroma_buffer };
        for (parts, buffers) |maybe, buffer| {
            const part = maybe orelse continue;
            const across = @max(1, @as(u64, part.width) * ratio_one / @max(ratio_one, @as(u64, part.h_ratio)));
            const fits = line_buffer_bits / line_buffer_pixel_bits / across;
            const lb_lines = @as(i64, @intCast(@min(line_buffer_lines, fits))) - (@as(i64, part.v_taps) - 1);
            const line = @as(i64, @intCast(planar.line_ps * ratio_one / @max(1, part.v_ratio)));
            const buffered: i64 = @intCast(buffer / part.bytes / @max(1, part.width));
            var margin = lb_lines * line + buffered * line - @as(i64, @intCast(delay)) - @as(i64, @intCast(marks.urgent_ps)) - @as(i64, @intCast(marks.change_ps));
            if (count > 1) margin -= @divTrunc(line * @as(i64, @intCast(count - 1)), @as(i64, @intCast(count)));
            if (margin <= 0) return false;
        }
    }
    return true;
}

/// What `load` asks of the chip (the module's header says how), or null
/// where the clocks' tops, the schedule or no state serves it.
pub fn demandOf(facts: *const Facts, load: Load) ?Demand {
    if (load.planes.len == 0 or load.planes.len > planes_most) return null;
    if (facts.count == 0 or facts.pll_khz == 0 or load.timings.pixel_clock_hz == 0) return null;
    const clocks = clocksOf(facts, load);
    if (clocks.display_khz > facts.display_most_khz) return null;
    if (clocks.pipes_khz > facts.pipes_most_khz) return null;
    for (0..2) |prefetch_mode_index| {
        const prefetch_mode: u32 = @intCast(prefetch_mode_index);
        const wait = waitOf(facts.memory, prefetch_mode);
        var reads: [planes_most]Reads = undefined;
        var rows: [planes_most]u64 = undefined;
        var served = true;
        for (load.planes, 0..) |plane, index| {
            const held = heldOf(load, index, clocks, wait, 0);
            const schedule = mode.scheduleFor(load.timings, plane.fetch, held, load.vstartup) orelse return null;
            const planar = planarOf(plane, load.timings);
            reads[index] = readsOf(planar, &schedule) orelse {
                served = false;
                break;
            };
            rows[index] = prefetchRowsOf(planar);
        }
        if (!served) return null;
        const count = load.planes.len;
        for (facts.levels[0..facts.count], 0..) |level, index| {
            if (!supports(facts, level, reads[0..count], rows[0..count])) continue;
            const marks = watermarksOf(facts, load, level, clocks, reads[0..count], rows[0..count]);
            return .{
                .clocks = clocks,
                .level = @intCast(index),
                .controller_khz = level.controller_khz,
                .prefetch_mode = prefetch_mode,
                .wait_ns = @intCast(wait / 1000),
                .watermarks = marks,
                .change_in_active = prefetch_mode == 0 and changeInActive(load, clocks, marks),
            };
        }
    }
    return null;
}

// --- tests ---------------------------------------------------------------------------------

const testing = @import("std").testing;

/// The box's power manager's table, as it read: the controller clock's
/// levels, the SoC's voltages and the fabric's states.
const box_controller = [_]u32{ 200, 400, 436, 533, 600, 685, 800, 960 };
const box_voltage = [_]u32{ 2600, 2750, 2850, 2950, 3050, 3200, 3450, 3860 };
const box_fabric = [_]Fabric{
    .{ .fabric_mhz = 1960, .memory_mhz = 2800, .voltage = 3860, .ratio = 0 },
    .{ .fabric_mhz = 1400, .memory_mhz = 2800, .voltage = 2960, .ratio = 0 },
    .{ .fabric_mhz = 500, .memory_mhz = 1000, .voltage = 2639, .ratio = 0 },
};

fn boxFacts() Facts {
    var facts: Facts = .{
        .display_most_khz = 1_200_000,
        .pipes_most_khz = 1_200_000,
        .pll_khz = 2_400_000,
        .memory = memoryOf(MEMORY_DDR5, 2),
    };
    levelsOf(&facts, &box_controller, box_controller.len, &box_voltage, &box_fabric);
    return facts;
}

/// The box's monitor's own mode.
const own: rtg.RtgTimings = .{
    .pixel_clock_hz = 241_500_000,
    .h_active = 2560,
    .h_front = 48,
    .h_sync = 32,
    .h_back = 80,
    .v_active = 1440,
    .v_front = 3,
    .v_sync = 5,
    .v_back = 33,
    .flags = rtg.modes.RTGTM_HSYNC_HIGH,
};

/// 3840x2160 at 60 Hz, as CTA-861 has it.
const uhd: rtg.RtgTimings = .{
    .pixel_clock_hz = 594_000_000,
    .h_active = 3840,
    .h_front = 176,
    .h_sync = 88,
    .h_back = 296,
    .v_active = 2160,
    .v_front = 8,
    .v_sync = 10,
    .v_back = 72,
    .flags = rtg.modes.RTGTM_HSYNC_HIGH | rtg.modes.RTGTM_VSYNC_HIGH,
};

fn picture(width: u32) Plane {
    return .{
        .fetch = .{ .out_width = width, .luma = .{ .width = width, .surface = width, .pitch = width, .bytes = 4 } },
        .buffer_bytes = 3 * 64 * 1024,
    };
}

test "the states follow the controller clock's levels, each with the slowest fabric its voltage reaches" {
    const facts = boxFacts();
    try testing.expectEqual(@as(u32, 8), facts.count);
    // The lowest level's voltage reaches no state but the first, which
    // it is given.
    try testing.expectEqual(@as(u32, 200_000), facts.levels[0].controller_khz);
    try testing.expectEqual(@as(u32, 1_960_000), facts.levels[0].fabric_khz);
    try testing.expectEqual(@as(u32, 5600), facts.levels[0].memory_mts);
    // Every other reaches the slowest.
    for (facts.levels[1..7]) |level| {
        try testing.expectEqual(@as(u32, 500_000), level.fabric_khz);
        try testing.expectEqual(@as(u32, 2000), level.memory_mts);
    }
    // The last is the fabric's fastest at the controller clock's top, in
    // place of the eighth level.
    try testing.expectEqual(@as(u32, 960_000), facts.levels[7].controller_khz);
    try testing.expectEqual(@as(u32, 1_960_000), facts.levels[7].fabric_khz);
    try testing.expectEqual(@as(u32, 5600), facts.levels[7].memory_mts);

    // With fewer levels the last is one more.
    var fewer: Facts = .{ .memory = memoryOf(MEMORY_DDR5, 2) };
    levelsOf(&fewer, &box_controller, 3, &box_voltage, &box_fabric);
    try testing.expectEqual(@as(u32, 4), fewer.count);
    try testing.expectEqual(@as(u32, 960_000), fewer.levels[3].controller_khz);
}

test "a clock rounded to the dividers' steps" {
    // 245.13 MHz up: 9600 MHz over 39.
    try testing.expectEqual(@as(u64, 246_153), dfsUp(245_133, 2_400_000));
    try testing.expectEqual(@as(u64, 1_200_000), dfsDown(1_200_000, 2_400_000));
    try testing.expectEqual(@as(u64, 1_200_000), dfsUp(1_200_000, 2_400_000));
}

test "the clocks of the box's own mode, its picture alone" {
    const facts = boxFacts();
    const planes = [_]Plane{picture(2560)};
    const clocks = clocksOf(&facts, .{ .timings = own, .planes = &planes });
    // 241.5 MHz with the spread and the ramp, up to a step.
    try testing.expectEqual(@as(u32, 246_153), clocks.display_khz);
    // 242.7 MHz up to 246.15, the pipe 252 255ths of it.
    try testing.expectEqual(@as(u32, 243_257), clocks.pipe_khz[0]);
    try testing.expectEqual(@as(u32, 243_257), clocks.pipes_khz);
    // A sixteenth of the pixel clock's bytes, and 15% more.
    try testing.expectEqual(@as(u32, 17_357_812), clocks.deep_sleep_hz);
}

test "a film made smaller needs its pipe's clock faster" {
    const facts = boxFacts();
    // Halved with four taps: four pixels a cycle, the pixel clock's own.
    const halved: Plane = .{
        .fetch = .{
            .out_width = 1920,
            .luma = .{ .width = 3840, .surface = 3840, .pitch = 4096, .bytes = 1, .h_ratio = 2 << 19, .v_ratio = 2 << 19, .h_taps = 4, .v_taps = 4 },
            .chroma = .{ .width = 1920, .surface = 1920, .pitch = 2048, .bytes = 2, .h_taps = 4, .v_taps = 4 },
            .scaled = true,
            .cursor = false,
        },
        .buffer_bytes = 3 * 64 * 1024,
    };
    const two = [_]Plane{ picture(2560), halved };
    const same = clocksOf(&facts, .{ .timings = own, .planes = &two });
    try testing.expectEqual(same.pipe_khz[0], same.pipe_khz[1]);
    // A third each way with six taps: nine pixels for every four the
    // scaler passes, the pixel clock times 2.25 with its margins - the
    // pipes' clock the film's, the picture's pipe 114 255ths of it.
    var third = halved;
    third.fetch.luma = .{ .width = 3840, .surface = 3840, .pitch = 4096, .bytes = 1, .h_ratio = 3 << 19, .v_ratio = 3 << 19, .h_taps = 6, .v_taps = 6 };
    third.fetch.chroma = .{ .width = 1920, .surface = 1920, .pitch = 2048, .bytes = 2, .h_ratio = 3 << 18, .v_ratio = 3 << 18, .h_taps = 6, .v_taps = 6 };
    const faster = [_]Plane{ picture(2560), third };
    const clocks = clocksOf(&facts, .{ .timings = own, .planes = &faster });
    try testing.expectEqual(@as(u32, 546_988), clocks.pipe_khz[1]);
    try testing.expectEqual(@as(u32, 243_598), clocks.pipe_khz[0]);
    try testing.expectEqual(clocks.pipe_khz[1], clocks.pipes_khz);
}

test "the box's own mode is served by the lowest state, the memory changing in the active picture" {
    const facts = boxFacts();
    const planes = [_]Plane{picture(2560)};
    const demand = demandOf(&facts, .{ .timings = own, .planes = &planes }) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 0), demand.level);
    try testing.expectEqual(@as(u32, 200_000), demand.controller_khz);
    try testing.expectEqual(@as(u32, 0), demand.prefetch_mode);
    // DDR5's clock change and the urgent latency.
    try testing.expectEqual(@as(u32, 15_720), demand.wait_ns);
    try testing.expect(demand.change_in_active);
    // The urgent latency and the extra: the round trip at 200 MHz, the
    // reordering, the chunk and the page-table group at 10.24 GB/s.
    const marks = demand.watermarks;
    try testing.expectEqual(@as(u64, 4_000_000), marks.latency_ps);
    try testing.expect(marks.urgent_ps > 6_000_000 and marks.urgent_ps < 7_000_000);
    try testing.expectEqual(marks.urgent_ps + 11_720_000, marks.change_ps);
    try testing.expect(marks.enter_exit_ps > marks.exit_ps);
    // The picture's buffer lasts less than the deeper state's residency.
    try testing.expectEqual(z8_residency_ps, marks.z8_enter_exit_ps);
    try testing.expectEqual(marks.change_ps, demand.blankPs());
}

test "LPDDR5 waits for its self-refresh" {
    var facts = boxFacts();
    facts.memory = memoryOf(MEMORY_LPDDR5, 0);
    try testing.expectEqual(@as(u32, 4), facts.memory.channels);
    try testing.expectEqual(@as(u32, 4), facts.memory.channel_bytes);
    const planes = [_]Plane{picture(2560)};
    const demand = demandOf(&facts, .{ .timings = own, .planes = &planes }) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 32_000), demand.wait_ns);
}

test "four planes read faster than the lowest state returns take a higher one" {
    const facts = boxFacts();
    // Four pictures of 3840 at 60 Hz read 8.3 GB/s, past the 7.68 the
    // lowest state returns outside an urgent burst.
    const planes = [_]Plane{ picture(3840), picture(3840), picture(3840), picture(3840) };
    const demand = demandOf(&facts, .{ .timings = uhd, .planes = &planes }) orelse return error.TestUnexpectedResult;
    try testing.expect(demand.level > 0);
    // Each pipe's chunk and group in the extra latency.
    const one = demandOf(&facts, .{ .timings = uhd, .planes = planes[0..1] }) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 0), one.level);
    try testing.expect(demand.watermarks.urgent_ps > one.watermarks.urgent_ps or demand.level != one.level);
}

test "the memory the video BIOS names" {
    var image: [0x400]u8 = @splat(0);
    image[bios_header_at] = 0x00;
    image[bios_header_at + 1] = 0x01;
    // The data tables' list at 0x200, the system's facts at 0x300.
    image[0x100 + bios_data_list_at] = 0x00;
    image[0x100 + bios_data_list_at + 1] = 0x02;
    image[0x200 + 4 + bios_system_info * 2] = 0x00;
    image[0x200 + 4 + bios_system_info * 2 + 1] = 0x03;
    image[0x302] = 2;
    image[0x303] = 2;
    image[0x300 + system_info_memory_at] = MEMORY_LPDDR5;
    image[0x300 + system_info_channels_at] = 8;
    const named = memoryOfBios(&image);
    try testing.expectEqual(@as(u32, 8), named.channels);
    try testing.expectEqual(@as(u32, 4), named.channel_bytes);
    try testing.expectEqual(@as(u64, 32_000_000), named.enter_exit_ps);
    // Another revision of the table says nothing.
    image[0x303] = 1;
    try testing.expectEqual(@as(u32, 4), memoryOfBios(&image).channels);
    try testing.expectEqual(@as(u64, 14_500_000), memoryOfBios(&image).enter_exit_ps);
    try testing.expectEqual(@as(u32, 4), memoryOfBios(image[0..0x40]).channels);
}

test "no planes, or a table without states, ask nothing" {
    var facts = boxFacts();
    try testing.expectEqual(@as(?Demand, null), demandOf(&facts, .{ .timings = own, .planes = &.{} }));
    facts.count = 0;
    const planes = [_]Plane{picture(2560)};
    try testing.expectEqual(@as(?Demand, null), demandOf(&facts, .{ .timings = own, .planes = &planes }));
}
