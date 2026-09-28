// SPDX-License-Identifier: MIT
//! A card in SPI mode, simulated for the host tests: `sdspi.zig`'s bus,
//! with a card on the other end of it.
//!
//! It works a byte at a time, as a card does: every byte the host clocks
//! out gets one back, taken from what the card has queued to say, and is
//! then heard - as part of a command, a block being written, or nothing.
//! What it says to a command is queued behind one byte of silence, so the
//! host finds its answer the way it finds a real card's: by listening
//! until a byte comes back that is not 0xFF.
//!
//! It is either generation of card: a new one that answers SEND_IF_COND
//! and counts in blocks, or an old one (`old`) that calls SEND_IF_COND
//! illegal and counts in bytes. A test can take it out (`absent`), damage
//! the next block it sends (`damage_next_block`) and have it refuse every
//! write (`refuse_writes`); it records what the host told it (`crc_on`,
//! `block_length`, `selected`).

const std = @import("std");
const card = @import("card.zig");
const sdspi = @import("sdspi.zig");

pub const Options = struct {
    /// The card's size, in blocks: a multiple of 1024, which is what its
    /// description can say.
    blocks: u32,
    old: bool = false,
};

/// What it does with the blocks of a write.
const Writing = enum { none, single, multiple };

pub const TestCard = struct {
    allocator: std.mem.Allocator,
    /// The card's contents.
    image: []u8,
    blocks: u32,
    old: bool,

    // What a test sets.
    absent: bool = false,
    damage_next_block: bool = false,
    refuse_writes: bool = false,

    // What the host told it.
    selected: bool = false,
    crc_on: bool = false,
    block_length: u32 = 0,
    clock_hz: u32 = 0,
    /// The time the host has let pass, in microseconds.
    waited_us: u64 = 0,

    // The card's own state.
    spi_mode: bool = false,
    idle: bool = true,
    high_capacity: bool = false,
    /// The last command was APP_CMD.
    app: bool = false,
    /// SD_SEND_OP_COND's still to be answered "idle" before it is ready.
    powering: u32 = 0,
    /// A command coming in.
    frame: [6]u8 = @splat(0),
    frame_len: usize = 0,
    /// What it will say next, and how many bytes it is busy for after.
    out: [1024]u8 = @splat(0),
    out_head: usize = 0,
    out_len: usize = 0,
    busy_bytes: u32 = 0,
    /// The next block of a READ_MULTIPLE_BLOCK run, while one runs.
    streaming: ?u64 = null,
    /// A write in progress: the block it goes to, and the token, the data
    /// and the check as they come in.
    writing: Writing = .none,
    write_at: u64 = 0,
    incoming: [1 + 512 + 2]u8 = @splat(0),
    incoming_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, options: Options) !TestCard {
        const image = try allocator.alloc(u8, @as(usize, options.blocks) * 512);
        @memset(image, 0);
        return .{ .allocator = allocator, .image = image, .blocks = options.blocks, .old = options.old };
    }

    pub fn deinit(sim: *TestCard) void {
        sim.allocator.free(sim.image);
    }

    // --- the bus -------------------------------------------------------------

    pub fn select(sim: *TestCard, on: bool) bool {
        sim.selected = on;
        if (!on) sim.frame_len = 0;
        return true;
    }

    pub fn exchange(sim: *TestCard, bytes: []u8) void {
        for (bytes) |*b| b.* = sim.clock(b.*);
    }

    pub fn setClock(sim: *TestCard, hz: u32) u32 {
        sim.clock_hz = hz;
        return hz;
    }

    pub fn delay(sim: *TestCard, us: u32) void {
        sim.waited_us += us;
    }

    // --- a byte each way -----------------------------------------------------

    /// One byte clocked: what the card says, then what it heard.
    fn clock(sim: *TestCard, in: u8) u8 {
        // Out of the slot, or not selected, it drives nothing and the
        // pull-up reads high.
        if (sim.absent or !sim.selected) return 0xFF;
        const said = sim.next();
        sim.hear(in);
        return said;
    }

    fn next(sim: *TestCard) u8 {
        if (sim.out_len == 0) {
            if (sim.busy_bytes > 0) {
                sim.busy_bytes -= 1;
                return 0x00;
            }
            if (sim.streaming) |block| sim.queueNextOfRun(block);
        }
        if (sim.out_len == 0) return 0xFF;
        const got = sim.out[sim.out_head];
        sim.out_head += 1;
        sim.out_len -= 1;
        if (sim.out_len == 0) sim.out_head = 0;
        return got;
    }

    fn say(sim: *TestCard, bytes: []const u8) void {
        if (sim.out_head > 0) {
            std.mem.copyForwards(u8, &sim.out, sim.out[sim.out_head..][0..sim.out_len]);
            sim.out_head = 0;
        }
        @memcpy(sim.out[sim.out_len..][0..bytes.len], bytes);
        sim.out_len += bytes.len;
    }

    fn hear(sim: *TestCard, in: u8) void {
        if (sim.writing != .none) return sim.hearWrite(in);
        if (sim.frame_len > 0 or in & 0xC0 == 0x40) {
            sim.frame[sim.frame_len] = in;
            sim.frame_len += 1;
            if (sim.frame_len == sim.frame.len) {
                sim.frame_len = 0;
                sim.obey();
            }
        }
    }

    // --- commands --------------------------------------------------------------

    fn r1(sim: *const TestCard) u8 {
        return if (sim.idle) sdspi.r1_idle else 0;
    }

    /// An answer, behind the byte of silence every answer has before it.
    fn answer(sim: *TestCard, bytes: []const u8) void {
        sim.say(&.{0xFF});
        sim.say(bytes);
    }

    fn obey(sim: *TestCard) void {
        const index = sim.frame[0] & 0x3F;
        const argument = card.beU32(sim.frame[1..5]);
        const checked = sdspi.crc7Byte(sim.frame[0..5]) == sim.frame[5];
        const app = sim.app;
        sim.app = false;

        if (index == card.GO_IDLE_STATE) {
            if (!checked) return;
            // Built apart and then copied in: a literal assigned straight
            // to `sim.*` may overwrite fields it has yet to read.
            const fresh: TestCard = .{
                .allocator = sim.allocator,
                .image = sim.image,
                .blocks = sim.blocks,
                .old = sim.old,
                .absent = sim.absent,
                .damage_next_block = sim.damage_next_block,
                .refuse_writes = sim.refuse_writes,
                .selected = sim.selected,
                .clock_hz = sim.clock_hz,
                .waited_us = sim.waited_us,
                .spi_mode = true,
                .powering = 3,
            };
            sim.* = fresh;
            return sim.answer(&.{sdspi.r1_idle});
        }
        // Outside SPI mode it is not listening to any of this.
        if (!sim.spi_mode) return;
        // SEND_IF_COND is checked whether or not checks are on.
        if ((sim.crc_on or index == card.SEND_IF_COND) and !checked) {
            return sim.answer(&.{sim.r1() | sdspi.r1_crc_error});
        }

        if (app) switch (index) {
            card.SD_SEND_OP_COND => {
                if (sim.powering > 0) {
                    sim.powering -= 1;
                } else {
                    sim.idle = false;
                    sim.high_capacity = !sim.old and argument & sdspi.ocr_high_capacity != 0;
                }
                return sim.answer(&.{sim.r1()});
            },
            else => return sim.answer(&.{sim.r1() | sdspi.r1_illegal_command}),
        };

        switch (index) {
            card.SEND_IF_COND => {
                if (sim.old) return sim.answer(&.{sim.r1() | sdspi.r1_illegal_command});
                sim.answer(&.{ sim.r1(), 0, 0, @truncate(argument >> 8), @truncate(argument) });
            },
            card.APP_CMD => {
                sim.app = true;
                sim.answer(&.{sim.r1()});
            },
            sdspi.READ_OCR => {
                const top: u8 = if (sim.idle) 0 else 0x80 | @as(u8, if (sim.high_capacity) 0x40 else 0);
                sim.answer(&.{ sim.r1(), top, 0xFF, 0x80, 0x00 });
            },
            sdspi.CRC_ON_OFF => {
                sim.crc_on = argument & 1 != 0;
                sim.answer(&.{sim.r1()});
            },
            card.SEND_CSD => sim.sendRegister(&sim.csd()),
            card.SEND_CID => sim.sendRegister(&cid),
            card.SEND_STATUS => sim.answer(&.{ sim.r1(), 0 }),
            card.SET_BLOCKLEN => {
                sim.block_length = argument;
                sim.answer(&.{sim.r1()});
            },
            card.STOP_TRANSMISSION => {
                sim.streaming = null;
                sim.out_len = 0;
                sim.out_head = 0;
                sim.answer(&.{sim.r1()});
                sim.busy_bytes = 2;
            },
            card.READ_SINGLE_BLOCK, card.READ_MULTIPLE_BLOCK, card.WRITE_BLOCK, card.WRITE_MULTIPLE_BLOCK => {
                if (sim.idle) return sim.answer(&.{sim.r1() | sdspi.r1_illegal_command});
                const block = sim.blockOf(argument) orelse return sim.answer(&.{sdspi.r1_address_error});
                sim.answer(&.{0});
                switch (index) {
                    card.READ_SINGLE_BLOCK => sim.queueBlock(block),
                    card.READ_MULTIPLE_BLOCK => sim.streaming = block,
                    card.WRITE_BLOCK => sim.startWrite(.single, block),
                    else => sim.startWrite(.multiple, block),
                }
            },
            else => sim.answer(&.{sim.r1() | sdspi.r1_illegal_command}),
        }
    }

    /// The block an argument names, if it is on the card: a block number
    /// on a card that counts in blocks, a byte offset on one that does not.
    fn blockOf(sim: *const TestCard, argument: u32) ?u64 {
        const block: u64 = if (sim.high_capacity) argument else argument / 512;
        if (!sim.high_capacity and argument % 512 != 0) return null;
        if (block >= sim.blocks) return null;
        return block;
    }

    // --- blocks out --------------------------------------------------------------

    fn sendBlockBytes(sim: *TestCard, data: []const u8) void {
        const check = sdspi.crc16(data);
        sim.say(&.{ 0xFF, sdspi.token_single });
        const start = sim.out_head + sim.out_len;
        sim.say(data);
        if (sim.damage_next_block) {
            sim.damage_next_block = false;
            sim.out[start] ^= 0x01;
        }
        sim.say(&.{ @truncate(check >> 8), @truncate(check) });
    }

    fn sendRegister(sim: *TestCard, raw: *const [16]u8) void {
        sim.answer(&.{sim.r1()});
        sim.sendBlockBytes(raw);
    }

    fn queueBlock(sim: *TestCard, block: u64) void {
        sim.sendBlockBytes(sim.image[@intCast(block * 512)..][0..512]);
    }

    /// The next block of a run, or - past the card's end - the error token
    /// that says it is out of range, and the run is over.
    fn queueNextOfRun(sim: *TestCard, block: u64) void {
        if (block >= sim.blocks) {
            sim.streaming = null;
            return sim.say(&.{ 0xFF, 0x08 });
        }
        sim.queueBlock(block);
        sim.streaming = block + 1;
    }

    // --- blocks in -----------------------------------------------------------------

    fn startWrite(sim: *TestCard, how: Writing, block: u64) void {
        sim.writing = how;
        sim.write_at = block;
        sim.incoming_len = 0;
    }

    fn hearWrite(sim: *TestCard, in: u8) void {
        if (sim.incoming_len == 0) {
            if (sim.writing == .multiple and in == sdspi.token_stop) {
                sim.writing = .none;
                sim.say(&.{0xFF});
                sim.busy_bytes = 4;
                return;
            }
            const token = if (sim.writing == .multiple) sdspi.token_multiple else sdspi.token_single;
            // Anything else is the host waiting before its token.
            if (in != token) return;
        }
        sim.incoming[sim.incoming_len] = in;
        sim.incoming_len += 1;
        if (sim.incoming_len < sim.incoming.len) return;

        sim.incoming_len = 0;
        const data = sim.incoming[1..513];
        const check = (@as(u16, sim.incoming[513]) << 8) | sim.incoming[514];
        const response: u8 = if (sim.refuse_writes)
            sdspi.data_write_error
        else if (sim.crc_on and check != sdspi.crc16(data))
            sdspi.data_crc_error
        else accepted: {
            if (sim.write_at >= sim.blocks) break :accepted sdspi.data_write_error;
            @memcpy(sim.image[@intCast(sim.write_at * 512)..][0..512], data);
            sim.write_at += 1;
            break :accepted sdspi.data_accepted;
        };
        sim.say(&.{0xE0 | response});
        sim.busy_bytes = 4;
        if (sim.writing == .single) sim.writing = .none;
    }

    // --- its registers ---------------------------------------------------------------

    /// Its description: the newer layout, its size in units of 1024
    /// blocks, reading and writing among its command classes. The last
    /// byte is the check and the end bit.
    fn csd(sim: *const TestCard) [16]u8 {
        var raw: [16]u8 = @splat(0);
        raw[0] = 0x40; // CSD_STRUCTURE 1
        // CCC (bits 95:84): classes 0, 2, 4, 5, 7, 8, 10.
        const classes: u16 = 0x5B5;
        raw[4] = @truncate(classes >> 4);
        raw[5] = @as(u8, @truncate(classes << 4)) | 0x09; // READ_BL_LEN 9
        // C_SIZE (bits 69:48).
        const c_size: u32 = sim.blocks / 1024 - 1;
        raw[7] = @truncate((c_size >> 16) & 0x3F);
        raw[8] = @truncate(c_size >> 8);
        raw[9] = @truncate(c_size);
        raw[15] = sdspi.crc7Byte(raw[0..15]);
        return raw;
    }
};

/// Its identity: maker 0x03, "SD", named SPISD.
const cid = blk: {
    var raw: [16]u8 = @splat(0);
    raw[0] = 0x03;
    raw[1] = 'S';
    raw[2] = 'D';
    for ("SPISD", 0..) |char, i| raw[3 + i] = char;
    raw[8] = 0x10;
    raw[15] = 0x01;
    break :blk raw;
};
