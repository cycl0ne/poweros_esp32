// SPDX-License-Identifier: MIT
//! What an SD card says: the commands it is asked, and the registers it
//! answers with, decoded.
//!
//! Nothing here touches the controller. A card's identification (CID),
//! its description (CSD) and its configuration (SCR) are bit fields in
//! the card's own numbering, and pulling them apart is arithmetic - so it
//! is all pure functions over words and bytes, and the host tests hold
//! every one of them.
//!
//! **Two numberings meet here.** The card's long answers are numbered the
//! way the card's own specification numbers them, 127 down to 0, with the
//! checksum at the bottom; the controller leaves them in four registers
//! at exactly those positions, so `bits` takes the number straight out of
//! the specification. The card's short answers are one word and are read
//! with ordinary shifts. The registers a card sends as *data* rather than
//! as an answer - the SCR - arrive as bytes, highest first, and are
//! decoded from bytes.
//!
//! **What a card is addressed by** is the one difference that runs
//! through the driver: a card of 2 GiB or less counts its offsets in
//! bytes, and every card since counts them in blocks. `Card.blockArg`
//! answers which, so nothing else has to remember.

const std = @import("std");
const td = @import("sdk").devices.trackdisk;

/// The bytes of one block. Every card since the first counts in these,
/// whatever it is told about block lengths.
pub const block_bytes: u64 = 512;

// --- the commands ---------------------------------------------------------

/// The card's own commands.
pub const GO_IDLE_STATE: u32 = 0;
pub const ALL_SEND_CID: u32 = 2;
pub const SEND_RELATIVE_ADDR: u32 = 3;
pub const SWITCH_FUNC: u32 = 6;
pub const SELECT_CARD: u32 = 7;
pub const SEND_IF_COND: u32 = 8;
pub const SEND_CSD: u32 = 9;
pub const SEND_CID: u32 = 10;
pub const STOP_TRANSMISSION: u32 = 12;
pub const SEND_STATUS: u32 = 13;
pub const SET_BLOCKLEN: u32 = 16;
pub const READ_SINGLE_BLOCK: u32 = 17;
pub const READ_MULTIPLE_BLOCK: u32 = 18;
pub const SET_BLOCK_COUNT: u32 = 23;
pub const WRITE_BLOCK: u32 = 24;
pub const WRITE_MULTIPLE_BLOCK: u32 = 25;
pub const APP_CMD: u32 = 55;

/// The commands that must be preceded by APP_CMD. They share their
/// numbers with the ordinary commands, which is why they are kept apart.
pub const SET_BUS_WIDTH: u32 = 6;
pub const SD_SEND_OP_COND: u32 = 41;
pub const SEND_SCR: u32 = 51;

/// CMD8's argument: the voltage the host offers (2.7 to 3.6 volts) and a
/// pattern the card echoes back, so an answer that is not an echo is
/// recognised as noise rather than believed.
pub const if_cond_pattern: u8 = 0xAA;
pub const if_cond_arg: u32 = (1 << 8) | @as(u32, if_cond_pattern);

/// ACMD41's argument: the same voltage window, and the bit that says the
/// host understands a card that counts in blocks. Without it an SDHC card
/// refuses to leave its idle state.
pub const op_cond_arg: u32 = (1 << 30) | 0x00FF_8000;

/// ACMD6's argument for each bus width.
pub const bus_width_1: u32 = 0;
pub const bus_width_4: u32 = 2;

// --- the answers ----------------------------------------------------------

/// `len` bits of `words` from bit `start`, counting from the lowest bit of
/// the first word upwards - which is the card's own numbering, because
/// that is how the controller leaves a long answer.
pub fn bits(words: *const [4]u32, start: u8, len: u8) u32 {
    const word = start / 32;
    const shift: u5 = @intCast(start % 32);
    const mask: u32 = if (len >= 32) 0xFFFF_FFFF else (@as(u32, 1) << @intCast(len)) - 1;
    const low = words[word] >> shift;
    // A field may straddle two words; one at the top of the last word
    // has nothing above it to reach for.
    const high: u32 = if (@as(u32, len) + shift <= 32 or word == 3)
        0
    else
        words[word + 1] << @intCast((32 - @as(u32, shift)) % 32);
    return (low | high) & mask;
}

/// The bits of a card's short answer that say what it is doing. R1's
/// error bits are above these and are checked as a whole.
pub const r1_ready_for_data: u32 = 1 << 8;
/// Everything in R1 that means the card refused or failed. The bits below
/// 8 are the card's own state and flags, not errors.
pub const r1_errors: u32 = 0xFDF9_E008;

/// What the card is doing, from its short answer.
pub const State = enum(u4) {
    idle = 0,
    ready = 1,
    identification = 2,
    standby = 3,
    transfer = 4,
    sending = 5,
    receiving = 6,
    programming = 7,
    disconnect = 8,
    _,
};

/// The state in a card's short answer.
pub fn stateOf(r1: u32) State {
    return @enumFromInt((r1 >> 9) & 0xF);
}

/// The relative address the card was given, which is the top half of the
/// answer to CMD3.
pub fn addressOf(r6: u32) u16 {
    return @intCast(r6 >> 16);
}

/// The card's own registers, once it is identified.
pub const Kind = enum(u8) {
    /// Counts its offsets in bytes: 2 GiB or less.
    standard = 0,
    /// Counts its offsets in blocks: every card since.
    high_capacity = 1,
};

/// Who made a card and which one it is.
pub const Cid = extern struct {
    /// The maker's number, assigned to them.
    manufacturer: u8 = 0,
    /// Two letters: the maker's own identification.
    oem: [2]u8 = .{ 0, 0 },
    /// Five characters, padded with spaces, not terminated.
    name: [5]u8 = .{ 0, 0, 0, 0, 0 },
    /// The card's revision, as the maker counts it: the high half is
    /// before the point and the low half after.
    revision: u8 = 0,
    serial: u32 = 0,
    /// When it was made. A year of 0 means the card did not say.
    year: u16 = 0,
    month: u8 = 0,
};

/// The identification a card answers CMD2 with.
pub fn decodeCid(resp: *const [4]u32) Cid {
    var cid = Cid{};
    cid.manufacturer = @intCast(bits(resp, 120, 8));
    cid.oem[0] = @intCast(bits(resp, 112, 8));
    cid.oem[1] = @intCast(bits(resp, 104, 8));
    for (0..5) |i| cid.name[i] = @intCast(bits(resp, @intCast(96 - i * 8), 8));
    cid.revision = @intCast(bits(resp, 56, 8));
    cid.serial = bits(resp, 24, 32);
    // The date is counted from the year 2000, in months.
    const made = bits(resp, 8, 12);
    cid.month = @intCast(made & 0xF);
    cid.year = @intCast(2000 + (made >> 4));
    return cid;
}

/// What a card says about itself: how big it is and what it will allow.
pub const Csd = extern struct {
    /// 0 for a card that counts in bytes, 1 or 2 for one that counts in
    /// blocks.
    version: u8 = 0,
    /// The card's whole size, in 512-byte blocks. Four-byte aligned, so
    /// that a base holding one is too - a device's base is reached with
    /// @fieldParentPtr from a four-byte-aligned node.
    blocks: u64 align(4) = 0,
    /// Set for good, by the maker or by a program that meant it.
    permanent_write_protect: bool = false,
    /// Set until something clears it.
    temporary_write_protect: bool = false,
    /// The classes of command the card serves. Bit 2 is block reading and
    /// bit 4 block writing; a card without both is of no use here.
    command_classes: u16 = 0,
};

/// The description a card answers CMD9 with, or null if the description
/// is of a kind this driver does not know.
///
/// The two layouts count the size differently. The older one gives a
/// block count and a block size and multiplies them out; the newer one
/// gives the size in units of 512 KiB and fixes the block at 512 bytes,
/// which is what makes a card larger than 2 GiB expressible at all.
pub fn decodeCsd(resp: *const [4]u32) ?Csd {
    var csd = Csd{};
    csd.version = @intCast(bits(resp, 126, 2));
    csd.command_classes = @intCast(bits(resp, 84, 12));
    csd.permanent_write_protect = bits(resp, 13, 1) != 0;
    csd.temporary_write_protect = bits(resp, 12, 1) != 0;
    switch (csd.version) {
        0 => {
            const c_size = bits(resp, 62, 12);
            const c_size_mult = bits(resp, 47, 3);
            const read_len = bits(resp, 80, 4);
            if (read_len > 11) return null;
            // (C_SIZE + 1) * 2^(C_SIZE_MULT + 2) blocks of 2^READ_BL_LEN
            // bytes, restated in blocks of 512.
            const units: u64 = (@as(u64, c_size) + 1) << @intCast(c_size_mult + 2);
            const bytes = units << @intCast(read_len);
            csd.blocks = bytes / block_bytes;
        },
        1, 2 => {
            // The size in units of 512 KiB, which is 1024 blocks.
            const c_size = bits(resp, 48, 22);
            csd.blocks = (@as(u64, c_size) + 1) * 1024;
        },
        else => return null,
    }
    return csd;
}

/// What a card's configuration register says. It arrives as eight bytes
/// of data, highest first, rather than as an answer.
pub const Scr = extern struct {
    /// Whether the card will work four bits wide. One that will not is
    /// left at one bit.
    four_bit: bool = false,
    /// Which version of the specification the card was built to: 0 is
    /// 1.0, 1 is 1.10, 2 is 2.00 and above.
    spec: u8 = 0,
    /// Whether the card takes a block count ahead of a transfer, which
    /// saves the command that ends one.
    set_block_count: bool = false,
};

pub fn decodeScr(raw: *const [8]u8) Scr {
    return .{
        .spec = raw[0] & 0xF,
        .four_bit = raw[1] & 0x4 != 0,
        .set_block_count = raw[3] & 0x2 != 0,
    };
}

/// The eight bytes of an answer sent as data, read as one number, highest
/// byte first - which is the order a card sends them in.
pub fn beU32(raw: []const u8) u32 {
    var value: u32 = 0;
    for (raw[0..4]) |byte| value = (value << 8) | byte;
    return value;
}

// --- what a card is, once it has answered ---------------------------------

/// Everything the driver remembers about the card in the slot.
pub const Card = extern struct {
    kind: Kind = .standard,
    /// The address the card was given, which every command after
    /// identification carries.
    address: u16 = 0,
    cid: Cid = .{},
    csd: Csd = .{},
    scr: Scr = .{},
    /// Whether the bus was actually widened.
    wide: bool = false,
    /// The clock the card is being run at.
    clock_hz: u32 = 0,

    /// The card's size in bytes.
    pub fn bytes(self: *const Card) u64 {
        return self.csd.blocks * block_bytes;
    }

    /// Whether the card refuses to be written, for any of the reasons it
    /// can give.
    pub fn readOnly(self: *const Card) bool {
        return self.csd.permanent_write_protect or self.csd.temporary_write_protect;
    }

    /// What a read or a write command carries as its argument: a block
    /// number, or the byte that block starts at.
    pub fn blockArg(self: *const Card, block: u64) u32 {
        return switch (self.kind) {
            .high_capacity => @truncate(block),
            .standard => @truncate(block * block_bytes),
        };
    }

    /// Whether a run of blocks is on the card at all.
    pub fn holds(self: *const Card, block: u64, count: u64) bool {
        return block <= self.csd.blocks and count <= self.csd.blocks - block;
    }
};

// --- what went wrong ------------------------------------------------------

/// What went wrong with a command, in the card's own terms. The
/// controller says it in its own bits; the device turns those into this,
/// and this says what the caller is told.
pub const Fault = struct {
    /// Nothing came back at all, within the time allowed.
    no_answer: bool = false,
    /// Something came back and did not check out.
    bad_checksum: bool = false,
    /// The controller complained of something else.
    other: bool = false,

    /// The error a caller is given. More than one thing can be wrong at
    /// once, and the order here is the order they matter in: a card that
    /// never answered is worth saying before the checksum of what it did
    /// not send, because the first is a card that is gone and the second
    /// is a card that is failing.
    pub fn code(self: Fault) i8 {
        if (self.no_answer) return td.TDERR_NoCard;
        if (self.bad_checksum) return td.TDERR_BadSecSum;
        if (self.other) return td.TDERR_NotSpecified;
        return 0;
    }

    pub fn any(self: Fault) bool {
        return self.no_answer or self.bad_checksum or self.other;
    }
};

// --- tests ----------------------------------------------------------------

const testing = std.testing;

/// A card's long answer, written the way a specification does - the
/// highest bit first - and packed into the four words the controller
/// leaves it in.
fn longAnswer(hex: *const [32]u8) [4]u32 {
    var words: [4]u32 = @splat(0);
    for (hex, 0..) |char, i| {
        const nibble: u32 = switch (char) {
            '0'...'9' => char - '0',
            'a'...'f' => char - 'a' + 10,
            'A'...'F' => char - 'A' + 10,
            else => unreachable,
        };
        // The first character is bits 127..124.
        const at: u32 = 124 - @as(u32, @intCast(i)) * 4;
        words[at / 32] |= nibble << @intCast(at % 32);
    }
    return words;
}

test "a long answer is read at the card's own bit numbers" {
    // 0x0123456789abcdef in the top two words, nothing in the bottom two.
    const answer = longAnswer("0123456789abcdef0000000000000000");
    try testing.expectEqual(@as(u32, 0x0), bits(&answer, 124, 4));
    try testing.expectEqual(@as(u32, 0x01), bits(&answer, 120, 8));
    try testing.expectEqual(@as(u32, 0x0123), bits(&answer, 112, 16));
    // A field that straddles two words: bits 88..103 are the low byte of
    // one word and the high byte of the next.
    try testing.expectEqual(@as(u32, 0x6789), bits(&answer, 88, 16));
    try testing.expectEqual(@as(u32, 0x4567), bits(&answer, 96, 16));
    try testing.expectEqual(@as(u32, 0x89abcdef), bits(&answer, 64, 32));
    try testing.expectEqual(@as(u32, 0), bits(&answer, 0, 32));
}

test "the identification of a card" {
    // Maker 0x03, "SD", name "SU64G", revision 8.0, serial 0x1A2B3C4D,
    // made in the ninth month of 2021. The fields sit where the card's
    // own numbering puts them: MID at 120, OID at 104, the five name
    // characters from 96 downwards, PRV at 56, PSN at 24, MDT at 8.
    const answer = longAnswer("0353445355363447801a2b3c4d015901");
    const cid = decodeCid(&answer);
    try testing.expectEqual(@as(u8, 0x03), cid.manufacturer);
    try testing.expectEqualSlices(u8, "SD", &cid.oem);
    try testing.expectEqualSlices(u8, "SU64G", &cid.name);
    try testing.expectEqual(@as(u8, 0x80), cid.revision);
    try testing.expectEqual(@as(u32, 0x1A2B_3C4D), cid.serial);
    try testing.expectEqual(@as(u16, 2021), cid.year);
    try testing.expectEqual(@as(u8, 9), cid.month);
}

test "a 64 GB card's size, from the newer description" {
    // CSD version 2, C_SIZE 0x1DBDF at bits 69..48, READ_BL_LEN 9. The
    // size is (C_SIZE + 1) units of 512 KiB - 63,870,861,312 bytes, a
    // card sold as 64 GB - and the 22-bit field is what makes a size
    // this large expressible at all.
    const answer = longAnswer("400e00325b590001dbdf7f800a400001");
    const csd = decodeCsd(&answer).?;
    try testing.expectEqual(@as(u8, 1), csd.version);
    try testing.expectEqual(@as(u32, 0x1DBDF), bits(&answer, 48, 22));
    try testing.expectEqual(@as(u64, 124_747_776), csd.blocks);
    try testing.expectEqual(@as(u64, 63_870_861_312), csd.blocks * block_bytes);
    try testing.expectEqual(@as(u16, 0x5B5), csd.command_classes);
    try testing.expect(!csd.permanent_write_protect);
    try testing.expect(!csd.temporary_write_protect);
}

test "a 500 MB card's size, from the older description" {
    // CSD version 0, C_SIZE 3751, C_SIZE_MULT 5, READ_BL_LEN 10:
    // (3751 + 1) * 2^7 blocks of 1024 bytes = 491,782,144 bytes, which
    // is 960,512 blocks of 512 once restated.
    const answer = longAnswer("002600325b5a03a9c002ff800a800001");
    const csd = decodeCsd(&answer).?;
    try testing.expectEqual(@as(u8, 0), csd.version);
    try testing.expectEqual(@as(u32, 3751), bits(&answer, 62, 12));
    try testing.expectEqual(@as(u32, 5), bits(&answer, 47, 3));
    try testing.expectEqual(@as(u32, 10), bits(&answer, 80, 4));
    try testing.expectEqual(@as(u64, 960_512), csd.blocks);
    try testing.expectEqual(@as(u64, 491_782_144), csd.blocks * block_bytes);
}

test "a description of an unknown kind is refused rather than guessed at" {
    const answer = longAnswer("c00e00325b590001dbdf7f800a400001");
    try testing.expectEqual(@as(?Csd, null), decodeCsd(&answer));
}

test "the write protect bits are read" {
    // The same version 2 description with both protect bits set: bit 13
    // and bit 12, which fall in the lowest word.
    var answer = longAnswer("400e00325b590001dbdf7f800a400001");
    answer[0] |= (1 << 13) | (1 << 12);
    const csd = decodeCsd(&answer).?;
    try testing.expect(csd.permanent_write_protect);
    try testing.expect(csd.temporary_write_protect);
}

test "the configuration register: four bits, and the block count" {
    // Structure 0, spec 2, four-bit and one-bit both offered, CMD23 too.
    const raw = [8]u8{ 0x02, 0x35, 0x80, 0x03, 0x00, 0x00, 0x00, 0x00 };
    const scr = decodeScr(&raw);
    try testing.expectEqual(@as(u8, 2), scr.spec);
    try testing.expect(scr.four_bit);
    try testing.expect(scr.set_block_count);

    // A card that will only do one bit.
    const narrow = [8]u8{ 0x00, 0x21, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    try testing.expect(!decodeScr(&narrow).four_bit);
    try testing.expect(!decodeScr(&narrow).set_block_count);
}

test "what a card is doing, and where its answer said so" {
    // A card in transfer, ready for data.
    const r1: u32 = (4 << 9) | r1_ready_for_data;
    try testing.expectEqual(State.transfer, stateOf(r1));
    try testing.expect(r1 & r1_errors == 0);
    // Its address, from the answer to CMD3.
    try testing.expectEqual(@as(u16, 0xAAAA), addressOf(0xAAAA_0500));
}

test "an offset is blocks on one card and bytes on another" {
    const big = Card{ .kind = .high_capacity, .csd = .{ .blocks = 1000 } };
    const small = Card{ .kind = .standard, .csd = .{ .blocks = 1000 } };
    try testing.expectEqual(@as(u32, 17), big.blockArg(17));
    try testing.expectEqual(@as(u32, 17 * 512), small.blockArg(17));

    // And what is on the card at all.
    try testing.expect(big.holds(999, 1));
    try testing.expect(big.holds(1000, 0));
    try testing.expect(!big.holds(999, 2));
    try testing.expect(!big.holds(1001, 0));
}

test "what went wrong, as the error a caller is given" {
    try testing.expectEqual(@as(i8, 0), (Fault{}).code());
    try testing.expect(!(Fault{}).any());
    try testing.expectEqual(td.TDERR_NoCard, (Fault{ .no_answer = true }).code());
    try testing.expectEqual(td.TDERR_BadSecSum, (Fault{ .bad_checksum = true }).code());
    try testing.expectEqual(td.TDERR_NotSpecified, (Fault{ .other = true }).code());
    // A card that never answered is said before a checksum on what it
    // did not send.
    const both = Fault{ .no_answer = true, .bad_checksum = true };
    try testing.expectEqual(td.TDERR_NoCard, both.code());
    try testing.expect(both.any());
}
