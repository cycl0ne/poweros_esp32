// SPDX-License-Identifier: MIT
//! A card spoken to over SPI: how it is woken, identified, read and
//! written when all there is between it and the chip is a clock, a line
//! each way and a chip select.
//!
//! **The conversation.** Everything is a byte for a byte: the host clocks
//! one out on MOSI and one comes back on MISO, and to listen it sends
//! 0xFF. A command is six bytes - its number, a 32-bit argument, and a
//! seven-bit check - and the card answers within eight bytes with R1, one
//! byte whose top bit is clear; some commands add four more bytes (R3,
//! R7). A block comes after a start token (0xFE) and is followed by a
//! 16-bit check. A block written goes after the same token (0xFC in a run
//! of them), and the card answers it with one byte saying whether it took
//! it, then holds MISO low until it has programmed it.
//!
//! **Waking a card.** It starts in its own native mode. 74 clocks with
//! the chip select high let it power up; GO_IDLE_STATE with the select low
//! puts it in SPI mode. From there the order is the card's: which voltages
//! it takes (SEND_IF_COND, which an old card does not know), powering up
//! until it says it is ready (SD_SEND_OP_COND), whether it counts in
//! blocks (READ_OCR), then the check turned on for everything, its
//! description and its identity, and - for a card that counts in bytes -
//! the block length. Only then is the clock raised.
//!
//! **Checks on everything.** A card in SPI mode checks nothing unless it
//! is told to (CRC_ON_OFF), and the host checks nothing unless it does so
//! itself. Both are turned on: a bit flipped on the wire is then a read
//! that fails, never a wrong byte in a file.
//!
//! **Generic over the bus**, so it is tested on the host against
//! `testcard.zig`. The bus offers
//!
//!     select(on: bool) bool        the chip select; false if it failed
//!     exchange(bytes: []u8) void   out, and what came back in their place
//!     receive(into: []u8) void     in, with 0xFF going out for each byte
//!     setClock(hz: u32) u32        the clock it now runs at
//!     delay(us: u32) void          time passing, for a card to get ready
//!
//! Waiting is counted in the delays it asks for, so a card that never
//! answers ends every wait in its allowance, on the machine and in a test.

const std = @import("std");
const card = @import("card.zig");

// --- the commands ------------------------------------------------------------

/// The commands only SPI mode has.
pub const READ_OCR: u32 = 58;
pub const CRC_ON_OFF: u32 = 59;
/// After APP_CMD: how many blocks the next WRITE_MULTIPLE_BLOCK will
/// write, so the card can erase them ahead of the data.
pub const SET_WR_BLK_ERASE_COUNT: u32 = 23;

/// The first byte of every command: a zero, a one, then its number.
const command_start: u8 = 0x40;

/// A block starts with this, read or written one at a time.
pub const token_single: u8 = 0xFE;
/// Each block of a run written with WRITE_MULTIPLE_BLOCK starts with this,
/// and the run ends with `token_stop`.
pub const token_multiple: u8 = 0xFC;
pub const token_stop: u8 = 0xFD;

// R1, the answer every command gets.
pub const r1_idle: u8 = 1 << 0;
pub const r1_erase_reset: u8 = 1 << 1;
pub const r1_illegal_command: u8 = 1 << 2;
pub const r1_crc_error: u8 = 1 << 3;
pub const r1_erase_sequence: u8 = 1 << 4;
pub const r1_address_error: u8 = 1 << 5;
pub const r1_parameter_error: u8 = 1 << 6;

/// A block that could not be read comes as this token instead of the
/// start token: its top four bits clear, the low four saying why.
pub fn isErrorToken(byte: u8) bool {
    return byte & 0xF0 == 0;
}

// What a card says of a block written to it, in the low five bits of the
// byte after the block.
pub const data_accepted: u8 = 0x05;
pub const data_crc_error: u8 = 0x0B;
pub const data_write_error: u8 = 0x0D;
const data_response_mask: u8 = 0x1F;

/// OCR's bit that says the card counts in blocks, and the one that says
/// it has finished powering up.
pub const ocr_high_capacity: u32 = 1 << 30;
pub const ocr_powered_up: u32 = 1 << 31;

// --- the clocks and the allowances ----------------------------------------

/// The clock a card is woken and identified at, which every card takes.
pub const identify_hz: u32 = 400_000;
/// The clock it is then run at: SPI mode's default speed allows 25 MHz,
/// and this is a margin under it.
pub const fast_hz: u32 = 20_000_000;

/// Clocks with the chip select high before the first command: at least
/// 74, in whole bytes.
const wake_bytes: usize = 10;
/// A card answers a command within this many bytes, or not at all.
const answer_bytes: u32 = 8;
/// How long a card may take to power up, to send a block, and to program
/// one. The first is a second by the specification and more in practice;
/// a read is 100 ms and a write 250 ms by it, and a card that is slow but
/// sound gets several times each.
pub const identify_us: u32 = 3_000_000;
const read_us: u32 = 500_000;
const write_us: u32 = 1_000_000;
/// While a card is busy or has yet to send a block, it is asked this many
/// chunks' worth without a pause - about 10 ms at the fast clock - before
/// the bus is let rest for `rest_us` between chunks. A rest is a sleep on
/// the timer, and a sleep costs a tick of the scheduler, 10 ms, whatever
/// it asks for: spinning for less than that is never slower, and a card
/// busy for a millisecond or two, as they are after most blocks, costs
/// only that.
const spin_chunks: u32 = 768;
/// How many bytes at a time a card that is programming is listened to.
const busy_chunk: usize = 16;
/// How many bytes at a time a block's start token is listened for in.
/// Less than a block, so a chunk never holds the whole of one.
const token_chunk: usize = 16;
const rest_us: u32 = 1_000;

// --- the checks --------------------------------------------------------------

/// The seven-bit check a command ends with (x^7 + x^3 + 1), shifted up
/// with the end bit set - the whole last byte of the command.
pub fn crc7Byte(bytes: []const u8) u8 {
    var crc: u8 = 0;
    for (bytes) |byte| {
        var bit: u8 = 0x80;
        while (bit != 0) : (bit >>= 1) {
            const top = crc & 0x40 != 0;
            const in = byte & bit != 0;
            crc = (crc << 1) & 0x7F;
            if (top != in) crc ^= 0x09;
        }
    }
    return (crc << 1) | 1;
}

/// The sixteen-bit check that follows a block (x^16 + x^12 + x^5 + 1,
/// starting from zero), a byte at a time from a table. Worked out a bit at
/// a time it cost a third of a millisecond a block - more than the block
/// takes on the wire.
pub fn crc16(bytes: []const u8) u16 {
    var crc: u16 = 0;
    for (bytes) |byte| crc = (crc << 8) ^ crc16_table[@as(u8, @truncate(crc >> 8)) ^ byte];
    return crc;
}

/// What each value of the check's top byte contributes, worked out once
/// when the file is compiled.
const crc16_table: [256]u16 = blk: {
    @setEvalBranchQuota(10_000);
    var table: [256]u16 = undefined;
    for (&table, 0..) |*entry, index| {
        var crc: u16 = @as(u16, index) << 8;
        for (0..8) |_| {
            crc = if (crc & 0x8000 != 0) (crc << 1) ^ 0x1021 else crc << 1;
        }
        entry.* = crc;
    }
    break :blk table;
};

/// A register a card sends as a block - its description or identity,
/// sixteen bytes, highest first - as the four words `card.bits` reads, the
/// same words the native bus leaves a long answer in.
pub fn longOf(raw: *const [16]u8) [4]u32 {
    return .{
        card.beU32(raw[12..16]),
        card.beU32(raw[8..12]),
        card.beU32(raw[4..8]),
        card.beU32(raw[0..4]),
    };
}

// --- what a command came to --------------------------------------------------

/// How a read or a write ended.
pub const Outcome = enum {
    ok,
    /// Nothing came back in the time allowed: the card is gone.
    no_answer,
    /// Something came back and its check did not hold.
    bad_checksum,
    /// The card answered, and said no.
    refused,

    /// The error a caller is given.
    pub fn code(outcome: Outcome) i8 {
        return switch (outcome) {
            .ok => 0,
            .no_answer => card.Fault.code(.{ .no_answer = true }),
            .bad_checksum => card.Fault.code(.{ .bad_checksum = true }),
            .refused => card.Fault.code(.{ .other = true }),
        };
    }

    /// Whether the card is to be taken for gone: it did not answer, or
    /// what it said cannot be trusted. A card that said no is still there.
    pub fn lost(outcome: Outcome) bool {
        return outcome == .no_answer or outcome == .bad_checksum;
    }
};

pub fn Protocol(comptime Bus: type) type {
    return struct {
        // --- bytes ---------------------------------------------------------

        /// One byte in, 0xFF out.
        fn byte(bus: *Bus) u8 {
            var one = [1]u8{0xFF};
            bus.exchange(&one);
            return one[0];
        }

        /// `into` filled from the card, 0xFF sent for every byte of it.
        fn receive(bus: *Bus, into: []u8) void {
            bus.receive(into);
        }

        /// `bytes` sent, whatever comes back dropped. They go through a
        /// scratch copy, since an exchange puts what came back in their
        /// place.
        fn send(bus: *Bus, bytes: []const u8) void {
            var scratch: [64]u8 = undefined;
            var at: usize = 0;
            while (at < bytes.len) {
                const piece = @min(bytes.len - at, scratch.len);
                @memcpy(scratch[0..piece], bytes[at..][0..piece]);
                bus.exchange(scratch[0..piece]);
                at += piece;
            }
        }

        /// Until the card lets go of MISO: a card that is programming
        /// holds it low. False if it never did.
        ///
        /// It is listened to `busy_chunk` bytes at a time. A card that has
        /// let go keeps the line high, so the last byte of a chunk says
        /// whether it has. It is asked without a pause for `spin_chunks`
        /// chunks before it is slept on: sleeping from the first
        /// millisecond made every block written cost a tick, and writes a
        /// quarter of their speed.
        fn awaitIdle(bus: *Bus, us: u32) bool {
            var chunk: [busy_chunk]u8 = undefined;
            var waited: u32 = 0;
            var polls: u32 = 0;
            while (true) {
                receive(bus, &chunk);
                if (chunk[chunk.len - 1] == 0xFF) return true;
                polls += 1;
                if (polls < spin_chunks) continue;
                if (waited >= us) return false;
                bus.delay(rest_us);
                waited += rest_us;
            }
        }

        // --- commands ------------------------------------------------------

        /// One command, and R1 - null if the card never answered. A card
        /// busy with the last one is waited out first, except by the
        /// command that wakes it, which comes before there is anything to
        /// wait for, and by STOP_TRANSMISSION, which cuts into a block the
        /// card is still sending.
        pub fn command(bus: *Bus, index: u32, argument: u32) ?u8 {
            const waits = index != card.GO_IDLE_STATE and index != card.STOP_TRANSMISSION;
            if (waits and !awaitIdle(bus, write_us)) return null;
            var frame = [6]u8{
                command_start | @as(u8, @intCast(index & 0x3F)),
                @truncate(argument >> 24),
                @truncate(argument >> 16),
                @truncate(argument >> 8),
                @truncate(argument),
                0,
            };
            frame[5] = crc7Byte(frame[0..5]);
            send(bus, &frame);
            // STOP_TRANSMISSION is sent while a block is still coming, and
            // the byte after it is the tail of that block, not an answer.
            if (index == card.STOP_TRANSMISSION) _ = byte(bus);
            for (0..answer_bytes + 1) |_| {
                const got = byte(bus);
                if (got & 0x80 == 0) return got;
            }
            return null;
        }

        /// A command the card only takes after APP_CMD.
        fn appCommand(bus: *Bus, index: u32, argument: u32) ?u8 {
            const first = command(bus, card.APP_CMD, 0) orelse return null;
            if (first & ~r1_idle != 0) return first;
            return command(bus, index, argument);
        }

        /// A block the card sends after a command: its start token within
        /// the allowance, `into.len` bytes, and its check.
        ///
        /// The card takes hundreds of microseconds to start, and asking a
        /// byte at a time for that long costs a transaction each. So it is
        /// listened for `token_chunk` bytes at a time, and whatever of the
        /// block came in the same chunk after the token is kept.
        fn receiveBlock(bus: *Bus, into: []u8) Outcome {
            var chunk: [token_chunk]u8 = undefined;
            var waited: u32 = 0;
            var polls: u32 = 0;
            const found = find: while (true) {
                receive(bus, &chunk);
                for (chunk, 0..) |got, at| if (got != 0xFF) break :find at;
                polls += 1;
                if (polls < spin_chunks) continue;
                if (waited >= read_us) return .no_answer;
                bus.delay(rest_us);
                waited += rest_us;
            };
            const token = chunk[found];
            if (token != token_single) return if (isErrorToken(token)) .refused else .no_answer;
            const early = chunk[found + 1 ..];
            @memcpy(into[0..early.len], early);
            receive(bus, into[early.len..]);
            var check: [2]u8 = undefined;
            receive(bus, &check);
            const said = (@as(u16, check[0]) << 8) | check[1];
            return if (said == crc16(into)) .ok else .bad_checksum;
        }

        /// One block written after its token, and what the card said of
        /// it. Returns once the card has programmed it.
        fn sendBlock(bus: *Bus, token: u8, from: []const u8) Outcome {
            const check = crc16(from);
            send(bus, &[_]u8{ 0xFF, token });
            send(bus, from);
            send(bus, &[_]u8{ @truncate(check >> 8), @truncate(check) });
            const said = byte(bus) & data_response_mask;
            const outcome: Outcome = switch (said) {
                data_accepted => .ok,
                data_crc_error => .bad_checksum,
                data_write_error => .refused,
                // Nothing that is a data response: the card is not there,
                // or is not listening.
                else => .no_answer,
            };
            if (!awaitIdle(bus, write_us)) return .no_answer;
            return outcome;
        }

        /// A register the card sends as a sixteen-byte block, after
        /// `index`. Null if it did not.
        fn register(bus: *Bus, index: u32) ?[16]u8 {
            const r1 = command(bus, index, 0) orelse return null;
            if (r1 != 0) return null;
            var raw: [16]u8 = undefined;
            if (receiveBlock(bus, &raw) != .ok) return null;
            return raw;
        }

        // --- the card ------------------------------------------------------

        /// The card on the bus, woken, identified and made ready: in SPI
        /// mode, checks on, 512-byte blocks, the fast clock. False if there
        /// is no card, or one this cannot use. The chip select is left low.
        pub fn identify(bus: *Bus, into: *card.Card) bool {
            into.* = .{};
            _ = bus.setClock(identify_hz);

            // The clocks it powers up on, with the select high.
            if (!bus.select(false)) return false;
            var wake: [wake_bytes]u8 = @splat(0xFF);
            bus.exchange(&wake);
            if (!bus.select(true)) return false;

            // Into SPI mode. A card that was part way through something
            // may need to be told twice.
            var awake = false;
            for (0..10) |_| {
                const r1 = command(bus, card.GO_IDLE_STATE, 0) orelse continue;
                if (r1 == r1_idle) {
                    awake = true;
                    break;
                }
            }
            if (!awake) return false;

            // Which voltages it takes, and whether it is new enough to be
            // asked: an old card calls the question illegal. A new one
            // echoes the pattern back, and anything else is noise.
            const voltage_r1 = command(bus, card.SEND_IF_COND, card.if_cond_arg) orelse return false;
            const modern = voltage_r1 & r1_illegal_command == 0;
            if (modern) {
                var r7: [4]u8 = undefined;
                receive(bus, &r7);
                if (r7[2] & 0x0F != 0x01 or r7[3] != card.if_cond_pattern) return false;
            }

            // Powering up, until it leaves its idle state. A new card is
            // told the host understands one that counts in blocks.
            const op_arg: u32 = if (modern) ocr_high_capacity else 0;
            var waited: u32 = 0;
            var ready = false;
            while (waited < identify_us) : (waited += 10_000) {
                const r1 = appCommand(bus, card.SD_SEND_OP_COND, op_arg) orelse return false;
                if (r1 == 0) {
                    ready = true;
                    break;
                }
                if (r1 & ~r1_idle != 0) return false;
                bus.delay(10_000);
            }
            if (!ready) return false;

            // Whether it counts in blocks, which only a new card can.
            into.kind = .standard;
            if (modern) {
                const r1 = command(bus, READ_OCR, 0) orelse return false;
                if (r1 != 0) return false;
                var ocr: [4]u8 = undefined;
                receive(bus, &ocr);
                if (card.beU32(&ocr) & ocr_high_capacity != 0) into.kind = .high_capacity;
            }

            // Checks on, from here to the end.
            if ((command(bus, CRC_ON_OFF, 1) orelse return false) != 0) return false;

            // What it says about itself, and who it is.
            const csd = register(bus, card.SEND_CSD) orelse return false;
            into.csd = card.decodeCsd(&longOf(&csd)) orelse return false;
            if (into.csd.blocks == 0) return false;
            const cid = register(bus, card.SEND_CID) orelse return false;
            into.cid = card.decodeCid(&longOf(&cid));

            // The block length, which a card that counts in blocks fixes
            // at 512 anyway and one that counts in bytes has to be told.
            if (into.kind == .standard) {
                const r1 = command(bus, card.SET_BLOCKLEN, @intCast(card.block_bytes)) orelse return false;
                if (r1 != 0) return false;
            }

            into.clock_hz = bus.setClock(fast_hz);
            into.wide = false;
            return true;
        }

        // --- blocks --------------------------------------------------------

        /// `count` blocks from `block` into `into`: one command for one
        /// block, a run and STOP_TRANSMISSION for more.
        pub fn read(bus: *Bus, of: *const card.Card, block: u64, count: u32, into: [*]u8) Outcome {
            if (count == 0) return .ok;
            const block_size: usize = @intCast(card.block_bytes);
            const many = count > 1;
            const index = if (many) card.READ_MULTIPLE_BLOCK else card.READ_SINGLE_BLOCK;
            const r1 = command(bus, index, of.blockArg(block)) orelse return .no_answer;
            if (r1 != 0) return .refused;
            var outcome: Outcome = .ok;
            for (0..count) |which| {
                outcome = receiveBlock(bus, into[which * block_size ..][0..block_size]);
                if (outcome != .ok) break;
            }
            if (many) {
                // The run ends here whatever came of it, so the card is
                // listening again for the next command.
                const stop = command(bus, card.STOP_TRANSMISSION, 0);
                if (!awaitIdle(bus, write_us) and outcome == .ok) outcome = .no_answer;
                if (stop == null and outcome == .ok) outcome = .no_answer;
            }
            return outcome;
        }

        /// `count` blocks from `from` to the card at `block`: one command
        /// for one block, a run ended by the stop token for more.
        pub fn write(bus: *Bus, of: *const card.Card, block: u64, count: u32, from: [*]const u8) Outcome {
            if (count == 0) return .ok;
            const block_size: usize = @intCast(card.block_bytes);
            const many = count > 1;
            // The card is told the run's length first. It is a hint - a
            // card that ignores it writes the run all the same - so what
            // it answers does not matter, only that it answered.
            if (many) _ = appCommand(bus, SET_WR_BLK_ERASE_COUNT, count) orelse return .no_answer;
            const index = if (many) card.WRITE_MULTIPLE_BLOCK else card.WRITE_BLOCK;
            const r1 = command(bus, index, of.blockArg(block)) orelse return .no_answer;
            if (r1 != 0) return .refused;
            const token = if (many) token_multiple else token_single;
            var outcome: Outcome = .ok;
            for (0..count) |which| {
                outcome = sendBlock(bus, token, from[which * block_size ..][0..block_size]);
                if (outcome != .ok) break;
            }
            if (many) {
                send(bus, &[_]u8{ token_stop, 0xFF });
                if (!awaitIdle(bus, write_us) and outcome == .ok) outcome = .no_answer;
            }
            return outcome;
        }
    };
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;
const testcard = @import("testcard.zig");
const TestCard = testcard.TestCard;
const Spi = Protocol(TestCard);

test "a command's check, as the two a card checks before any is turned on" {
    // GO_IDLE_STATE ends in 0x95 and SEND_IF_COND with 0x1AA in 0x87:
    // every host sends these two literally.
    try testing.expectEqual(@as(u8, 0x95), crc7Byte(&.{ 0x40, 0, 0, 0, 0 }));
    try testing.expectEqual(@as(u8, 0x87), crc7Byte(&.{ 0x48, 0, 0, 0x01, 0xAA }));
}

test "a block's check" {
    // A block of 0xFF, the value an erased card reads back as.
    var block: [512]u8 = @splat(0xFF);
    try testing.expectEqual(@as(u16, 0x7FA1), crc16(&block));
    try testing.expectEqual(@as(u16, 0x31C3), crc16("123456789"));
}

test "a card that counts in blocks is identified" {
    var sim = try TestCard.init(testing.allocator, .{ .blocks = 2048 });
    defer sim.deinit();
    var found: card.Card = .{};
    try testing.expect(Spi.identify(&sim, &found));
    try testing.expectEqual(card.Kind.high_capacity, found.kind);
    try testing.expectEqual(@as(u64, 2048), found.csd.blocks);
    try testing.expectEqualStrings("SPISD", &found.cid.name);
    try testing.expectEqual(fast_hz, found.clock_hz);
    try testing.expect(sim.crc_on);
    try testing.expect(sim.selected);
}

test "a card too old for SEND_IF_COND counts in bytes and is told the block length" {
    var sim = try TestCard.init(testing.allocator, .{ .blocks = 2048, .old = true });
    defer sim.deinit();
    var found: card.Card = .{};
    try testing.expect(Spi.identify(&sim, &found));
    try testing.expectEqual(card.Kind.standard, found.kind);
    try testing.expectEqual(@as(u32, 512), sim.block_length);
}

test "an empty slot is no card, and says so at once" {
    var sim = try TestCard.init(testing.allocator, .{ .blocks = 2048 });
    defer sim.deinit();
    sim.absent = true;
    var found: card.Card = .{};
    try testing.expect(!Spi.identify(&sim, &found));
    try testing.expectEqual(Outcome.no_answer, Spi.read(&sim, &found, 0, 1, @ptrCast(sim.image.ptr)));
}

test "blocks written one at a time and in a run read back the same" {
    var sim = try TestCard.init(testing.allocator, .{ .blocks = 2048 });
    defer sim.deinit();
    var found: card.Card = .{};
    try testing.expect(Spi.identify(&sim, &found));

    var out: [5 * 512]u8 = undefined;
    for (&out, 0..) |*b, i| b.* = @truncate(i *% 7 +% 3);
    try testing.expectEqual(Outcome.ok, Spi.write(&sim, &found, 10, 1, &out));
    try testing.expectEqual(Outcome.ok, Spi.write(&sim, &found, 20, 4, out[512..].ptr));
    try testing.expectEqualSlices(u8, out[0..512], sim.image[10 * 512 ..][0..512]);
    try testing.expectEqualSlices(u8, out[512..], sim.image[20 * 512 ..][0 .. 4 * 512]);
    // The run was announced, so the card could erase ahead of it.
    try testing.expectEqual(@as(u32, 4), sim.erase_count);

    var back: [5 * 512]u8 = @splat(0);
    try testing.expectEqual(Outcome.ok, Spi.read(&sim, &found, 10, 1, &back));
    try testing.expectEqual(Outcome.ok, Spi.read(&sim, &found, 20, 4, back[512..].ptr));
    try testing.expectEqualSlices(u8, &out, &back);
    // The card is left listening: a command after a run is answered.
    try testing.expectEqual(@as(?u8, 0), Spi.command(&sim, card.SEND_STATUS, 0));
}

test "a card that counts in bytes is given byte offsets" {
    var sim = try TestCard.init(testing.allocator, .{ .blocks = 2048, .old = true });
    defer sim.deinit();
    var found: card.Card = .{};
    try testing.expect(Spi.identify(&sim, &found));
    var out: [512]u8 = @splat(0x5A);
    try testing.expectEqual(Outcome.ok, Spi.write(&sim, &found, 7, 1, &out));
    try testing.expectEqualSlices(u8, &out, sim.image[7 * 512 ..][0..512]);
}

test "a block that arrives damaged is a bad checksum, and the card is still there" {
    var sim = try TestCard.init(testing.allocator, .{ .blocks = 2048 });
    defer sim.deinit();
    var found: card.Card = .{};
    try testing.expect(Spi.identify(&sim, &found));
    sim.damage_next_block = true;
    var back: [512]u8 = undefined;
    try testing.expectEqual(Outcome.bad_checksum, Spi.read(&sim, &found, 3, 1, &back));
    try testing.expectEqual(Outcome.ok, Spi.read(&sim, &found, 3, 1, &back));
}

test "a write the card refuses is refused, not a lost card" {
    var sim = try TestCard.init(testing.allocator, .{ .blocks = 2048 });
    defer sim.deinit();
    var found: card.Card = .{};
    try testing.expect(Spi.identify(&sim, &found));
    sim.refuse_writes = true;
    var out: [2 * 512]u8 = @splat(1);
    const single = Spi.write(&sim, &found, 5, 1, &out);
    try testing.expectEqual(Outcome.refused, single);
    try testing.expect(!single.lost());
    try testing.expectEqual(Outcome.refused, Spi.write(&sim, &found, 5, 2, &out));
    // Nothing was written, and the card still answers.
    try testing.expectEqual(@as(u8, 0), sim.image[5 * 512]);
    try testing.expectEqual(@as(?u8, 0), Spi.command(&sim, card.SEND_STATUS, 0));
}

test "a block past the end of the card is refused" {
    var sim = try TestCard.init(testing.allocator, .{ .blocks = 2048 });
    defer sim.deinit();
    var found: card.Card = .{};
    try testing.expect(Spi.identify(&sim, &found));
    var back: [512]u8 = undefined;
    try testing.expectEqual(Outcome.refused, Spi.read(&sim, &found, 5000, 1, &back));
}

test "a card taken out is a lost card" {
    var sim = try TestCard.init(testing.allocator, .{ .blocks = 2048 });
    defer sim.deinit();
    var found: card.Card = .{};
    try testing.expect(Spi.identify(&sim, &found));
    sim.absent = true;
    var back: [2 * 512]u8 = undefined;
    const outcome = Spi.read(&sim, &found, 0, 2, &back);
    try testing.expectEqual(Outcome.no_answer, outcome);
    try testing.expect(outcome.lost());
}
