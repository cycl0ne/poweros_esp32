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
//! **An eMMC** is asked most of the same things in most of the same
//! ways, and where it is not - how it is powered up, given its address,
//! switched to a faster mode or a wider bus, and what it says about its
//! size - the commands and the registers are here beside an SD card's,
//! named for it (`SEND_OP_COND`, `decodeMmcCid`, `decodeExtCsd`).
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

/// An eMMC's own commands, where they differ from an SD card's. It is
/// told to power up with CMD1 rather than ACMD41, given its address
/// rather than asked for one (CMD3, the same number), switched by writing
/// a byte of its EXT_CSD (CMD6, the same number with another argument),
/// and sends that register with CMD8 - which an SD card takes as its
/// voltage check, and an eMMC in its idle state does not answer.
pub const SEND_OP_COND: u32 = 1;
pub const SET_RELATIVE_ADDR: u32 = 3;
pub const SWITCH: u32 = 6;
pub const SEND_EXT_CSD: u32 = 8;

/// CMD1's argument: 2.7 to 3.6 volts, and the bit that says the host
/// counts an eMMC larger than 2 GiB in sectors.
pub const mmc_op_cond_arg: u32 = (1 << 30) | 0x00FF_8000;
/// The address the host gives the one eMMC on its bus.
pub const mmc_address: u16 = 1;
/// R1's bit that says the last CMD6 was refused.
pub const r1_switch_error: u32 = 1 << 7;

/// An eMMC's clocks: before it is switched to anything - 20 MHz for a
/// card older than version 4, which has no EXT_CSD, 26 MHz for one that
/// has - and in its high-speed timing, whichever of the two it offers.
pub const mmc_legacy_hz: u32 = 20_000_000;
pub const mmc_default_hz: u32 = 26_000_000;
pub const mmc_high_speed_26_hz: u32 = 26_000_000;
pub const mmc_high_speed_52_hz: u32 = 52_000_000;

/// The EXT_CSD: 512 bytes an eMMC sends as data. The bytes read here, by
/// their place in it.
pub const ext_csd_bytes: u32 = 512;
pub const EXT_CSD_PARTITION_CONFIG: u8 = 179;
pub const EXT_CSD_BUS_WIDTH: u8 = 183;
pub const EXT_CSD_HS_TIMING: u8 = 185;
pub const EXT_CSD_REV: u8 = 192;
/// FLUSH_CACHE: 1 written has the card put what its cache holds into
/// its flash, busy until it has.
pub const EXT_CSD_FLUSH_CACHE: u8 = 32;
/// CACHE_CTRL: 1 turns the card's write cache on.
pub const EXT_CSD_CACHE_CTRL: u8 = 33;
/// CACHE_SIZE, four bytes, lowest first: 0 for a card with no cache.
pub const EXT_CSD_CACHE_SIZE: u16 = 249;
/// The first revision with a cache (eMMC 4.5).
pub const ext_csd_rev_cache: u8 = 6;
pub const EXT_CSD_DEVICE_TYPE: u8 = 196;
pub const EXT_CSD_SEC_COUNT: u16 = 212;
/// PARTITION_CONFIG's low bits: which of the card's areas the commands
/// reach - 0 the user area, where its partitions are; the boot areas
/// and the rest are left alone.
pub const partition_access_mask: u8 = 0x7;
/// DEVICE_TYPE's bits for the high-speed timing at 26 and at 52 MHz,
/// and for its dual data rate at 52 MHz on 1.8 or 3.3 V lines.
pub const device_type_hs_26: u8 = 1 << 0;
pub const device_type_hs_52: u8 = 1 << 1;
pub const device_type_ddr_52: u8 = 1 << 2;

/// CMD6's argument for an eMMC: the byte at `index` of its EXT_CSD
/// written with `value` (access 3, "write byte").
pub fn switchArg(index: u8, value: u8) u32 {
    return (3 << 24) | (@as(u32, index) << 16) | (@as(u32, value) << 8);
}

/// BUS_WIDTH's value for one, four or eight data lines at single data
/// rate.
pub fn mmcBusWidth(lines: u8) u8 {
    return switch (lines) {
        8 => 2,
        4 => 1,
        else => 0,
    };
}

/// BUS_WIDTH's value for four or eight data lines at dual data rate, a
/// bit on each edge of the clock. There is none for one line.
pub fn mmcBusWidthDdr(lines: u8) u8 {
    return if (lines == 8) 6 else 5;
}

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

/// CMD6's argument: function group 1, the access mode, asked about
/// (bit 31 clear) or switched (set) to high speed, which is its function
/// 1; every other group is left as it is (0xF).
pub const switch_check_high_speed: u32 = 0x00FF_FFF1;
pub const switch_to_high_speed: u32 = 0x80FF_FFF1;
/// What CMD6 sends back over the data lines: 512 bits.
pub const switch_status_bytes: u32 = 64;
/// The command class CMD6 is in, as the card's description lists them.
pub const class_switch: u16 = 1 << 10;

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
    /// Five characters - six on an eMMC - padded with spaces, not
    /// terminated; an SD card's sixth is 0.
    name: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    /// The card's revision, as the maker counts it: the high half is
    /// before the point and the low half after.
    revision: u8 = 0,
    serial: u32 = 0,
    /// When it was made. A year of 0 means the card did not say.
    year: u16 = 0,
    month: u8 = 0,
};

/// Whether two identifications are of one card: every field the card
/// answers with the same. A card woken again after it stopped answering
/// is the one that was in only if it says so here.
pub fn sameCard(a: Cid, b: Cid) bool {
    return a.manufacturer == b.manufacturer and
        std.mem.eql(u8, &a.oem, &b.oem) and
        std.mem.eql(u8, &a.name, &b.name) and
        a.revision == b.revision and
        a.serial == b.serial and
        a.year == b.year and
        a.month == b.month;
}

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
    /// An eMMC's SPEC_VERS: 4 or more has an EXT_CSD. 0 on an SD card.
    mmc_spec: u8 = 0,
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

/// The identification an eMMC answers CMD2 with: the maker's number, a
/// one-byte OEM (kept in `oem[1]`), six characters of name, the
/// revision, the serial, and a month and a year counted from 1997 -
/// from 2013 on a card of EXT_CSD revision 5 or later, which is read
/// after this (`mmcYear`).
pub fn decodeMmcCid(resp: *const [4]u32) Cid {
    var cid = Cid{};
    cid.manufacturer = @intCast(bits(resp, 120, 8));
    cid.oem[1] = @intCast(bits(resp, 104, 8));
    for (0..6) |i| cid.name[i] = @intCast(bits(resp, @intCast(96 - i * 8), 8));
    cid.revision = @intCast(bits(resp, 48, 8));
    cid.serial = bits(resp, 16, 32);
    cid.month = @intCast(bits(resp, 12, 4));
    cid.year = @intCast(1997 + bits(resp, 8, 4));
    return cid;
}

/// The year an eMMC was made, once its EXT_CSD revision is known: the
/// four bits count from 2013 on revision 5 (eMMC 4.41) and later.
pub fn mmcYear(cid: *Cid, ext_csd_revision: u8) void {
    if (ext_csd_revision > 4 and cid.year < 2010) cid.year += 16;
}

/// The description an eMMC answers CMD9 with, or null if it says
/// nothing this driver can use. Every eMMC states its size the way the
/// older SD layout does - (C_SIZE + 1) * 2^(C_SIZE_MULT + 2) blocks of
/// 2^READ_BL_LEN bytes - whatever its CSD_STRUCTURE says; one larger
/// than 2 GiB sets C_SIZE to its top and gives its size in the EXT_CSD
/// instead (`ExtCsd.sectors`), which the caller puts here.
pub fn decodeMmcCsd(resp: *const [4]u32) ?Csd {
    var csd = Csd{};
    csd.version = @intCast(bits(resp, 126, 2));
    csd.mmc_spec = @intCast(bits(resp, 122, 4));
    csd.command_classes = @intCast(bits(resp, 84, 12));
    csd.permanent_write_protect = bits(resp, 13, 1) != 0;
    csd.temporary_write_protect = bits(resp, 12, 1) != 0;
    const c_size = bits(resp, 62, 12);
    const c_size_mult = bits(resp, 47, 3);
    const read_len = bits(resp, 80, 4);
    if (read_len > 11) return null;
    const units: u64 = (@as(u64, c_size) + 1) << @intCast(c_size_mult + 2);
    csd.blocks = (units << @intCast(read_len)) / block_bytes;
    return csd;
}

/// What an eMMC's EXT_CSD says that matters here.
pub const ExtCsd = struct {
    /// Its size in 512-byte sectors, on a card that counts in them.
    sectors: u32 = 0,
    revision: u8 = 0,
    /// The timings it offers (`device_type_hs_26`, `device_type_hs_52`).
    device_type: u8 = 0,
    partition_config: u8 = 0,
    /// How big its write cache is; 0 if it has none.
    cache_size: u32 = 0,
    /// Bytes the card fixes, read again over a wider bus to see that
    /// every line of it is wired (`sameExtCsd`).
    fingerprint: [fingerprint_at.len]u8 = @splat(0),
};

/// Where in the EXT_CSD the bytes are that the card fixes and the host
/// never writes - its partitioning support, its revision and structure,
/// the timings it offers, its size, its timeouts and erase sizes - as
/// Linux compares them after it widens the bus.
const fingerprint_at = [_]u16{ 160, 192, 194, 196, 212, 213, 214, 215, 217, 221, 223, 224, 229, 230, 231, 232 };

pub fn decodeExtCsd(raw: *const [ext_csd_bytes]u8) ExtCsd {
    var ext = ExtCsd{
        .sectors = @as(u32, raw[EXT_CSD_SEC_COUNT]) |
            @as(u32, raw[EXT_CSD_SEC_COUNT + 1]) << 8 |
            @as(u32, raw[EXT_CSD_SEC_COUNT + 2]) << 16 |
            @as(u32, raw[EXT_CSD_SEC_COUNT + 3]) << 24,
        .revision = raw[EXT_CSD_REV],
        .device_type = raw[EXT_CSD_DEVICE_TYPE],
        .partition_config = raw[EXT_CSD_PARTITION_CONFIG],
        .cache_size = std.mem.readInt(u32, raw[EXT_CSD_CACHE_SIZE..][0..4], .little),
    };
    for (fingerprint_at, 0..) |index, i| ext.fingerprint[i] = raw[index];
    return ext;
}

/// Whether two readings of an EXT_CSD are of the same register: the one
/// read over a single line, and one read over a wider bus, which a line
/// the board did not wire reads differently - or fails its checksum.
pub fn sameExtCsd(a: ExtCsd, b: ExtCsd) bool {
    return std.mem.eql(u8, &a.fingerprint, &b.fingerprint);
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

/// What CMD6 said about the access mode: whether the card offers high
/// speed, and whether that is the mode it took - or, asked rather than
/// switched, would take.
pub const AccessMode = struct {
    offered: bool = false,
    high_speed: bool = false,
};

/// The 64 bytes CMD6 sends, highest first. Function group 1's support
/// bits are bytes 12 and 13, high speed bit 1 of byte 13; the function
/// it took is the low half of byte 16, 0xF if it could not take the one
/// it was given.
pub fn decodeSwitch(raw: *const [64]u8) AccessMode {
    return .{
        .offered = raw[13] & 0x2 != 0,
        .high_speed = raw[16] & 0xF == 1,
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
    /// Whether the bus was actually widened, and to how many data lines.
    wide: bool = false,
    bus_bits: u8 = 1,
    /// Whether the card is an eMMC (or an MMC), not an SD card.
    mmc: bool = false,
    /// Whether the card was switched to high speed.
    high_speed: bool = false,
    /// Whether its data lines carry a bit on both edges of the clock.
    ddr: bool = false,
    /// Whether its write cache is on, so that what it was given has to be
    /// flushed to be in its flash (CMD_UPDATE).
    cache: bool = false,
    /// The clock the card is being run at.
    clock_hz: u32 = 0,

    /// The card's size in bytes.
    pub fn bytes(self: *const Card) u64 {
        return self.csd.blocks * block_bytes;
    }

    /// Whether the card can be asked to switch its mode (CMD6): it was
    /// built to version 1.10 or later and serves the command's class.
    pub fn canSwitch(self: *const Card) bool {
        return self.scr.spec >= 1 and self.csd.command_classes & class_switch != 0;
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
    try testing.expectEqualSlices(u8, "SU64G", cid.name[0..5]);
    try testing.expectEqual(@as(u8, 0x80), cid.revision);
    try testing.expectEqual(@as(u32, 0x1A2B_3C4D), cid.serial);
    try testing.expectEqual(@as(u16, 2021), cid.year);
    try testing.expectEqual(@as(u8, 9), cid.month);
}

test "a card woken again is the same card only if every field of its identification is" {
    const was = decodeCid(&longAnswer("0353445355363447801a2b3c4d015901"));
    try testing.expect(sameCard(was, decodeCid(&longAnswer("0353445355363447801a2b3c4d015901"))));
    // Another card of the same make and size: only its serial differs.
    try testing.expect(!sameCard(was, decodeCid(&longAnswer("0353445355363447801a2b3c4e015901"))));
    // The same serial from another maker.
    try testing.expect(!sameCard(was, decodeCid(&longAnswer("2753445355363447801a2b3c4d015901"))));
    // Nothing read back at all.
    try testing.expect(!sameCard(was, .{}));
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

test "high speed, as CMD6 says it is offered and taken" {
    // Max current 100 mA, every group's default function, group 2's
    // function 1 and group 1's high speed offered; group 1 switched to
    // high speed, group 2 left at its default; structure version 1.
    var raw: [64]u8 = @splat(0);
    @memcpy(raw[0..18], &[18]u8{ 0x00, 0x64, 0x80, 0x01, 0x80, 0x01, 0x80, 0x01, 0x80, 0x01, 0x80, 0x03, 0x80, 0x03, 0x00, 0x00, 0x01, 0x01 });
    const taken = decodeSwitch(&raw);
    try testing.expect(taken.offered);
    try testing.expect(taken.high_speed);

    // A switch the card could not make answers 0xF for the group.
    raw[16] = 0x0F;
    try testing.expect(!decodeSwitch(&raw).high_speed);
    // A card that offers only the default.
    raw[13] = 0x01;
    raw[16] = 0x00;
    try testing.expect(!decodeSwitch(&raw).offered);
    try testing.expect(!decodeSwitch(&raw).high_speed);
}

test "only a card built to 1.10 that serves class 10 is asked to switch" {
    // The 64 GB card's command classes, 0x5B5, which include 10.
    var new = Card{ .scr = .{ .spec = 2 }, .csd = .{ .command_classes = 0x5B5 } };
    try testing.expect(new.canSwitch());
    new.csd.command_classes = 0x1B5;
    try testing.expect(!new.canSwitch());
    const old = Card{ .scr = .{ .spec = 0 }, .csd = .{ .command_classes = 0x5B5 } };
    try testing.expect(!old.canSwitch());
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

/// A field of `len` bits at `start` set in a long answer, for building
/// one field by field.
fn setBits(words: *[4]u32, start: u8, len: u8, value: u32) void {
    for (0..len) |i| {
        if ((value >> @intCast(i)) & 1 == 0) continue;
        const bit: u32 = start + @as(u32, @intCast(i));
        words[bit / 32] |= @as(u32, 1) << @intCast(bit % 32);
    }
}

test "the identification of an eMMC" {
    // Maker 0x15, BGA (CBX 1), OEM 0, name "BJTD4R", revision 0x30,
    // serial 0x12345678, made in the tenth month of year 6 - 2003 by the
    // first count, 2019 on a card of EXT_CSD revision 5 or later.
    var cid = decodeMmcCid(&longAnswer("150100424a544434523012345678a601"));
    try testing.expectEqual(@as(u8, 0x15), cid.manufacturer);
    try testing.expectEqual(@as(u8, 0), cid.oem[1]);
    try testing.expectEqualSlices(u8, "BJTD4R", &cid.name);
    try testing.expectEqual(@as(u8, 0x30), cid.revision);
    try testing.expectEqual(@as(u32, 0x1234_5678), cid.serial);
    try testing.expectEqual(@as(u8, 10), cid.month);
    try testing.expectEqual(@as(u16, 2003), cid.year);
    mmcYear(&cid, 8);
    try testing.expectEqual(@as(u16, 2019), cid.year);
    // Counted once only.
    mmcYear(&cid, 8);
    try testing.expectEqual(@as(u16, 2019), cid.year);
}

test "an eMMC's description, whatever its structure says" {
    // CSD_STRUCTURE 3 - "see the EXT_CSD" - and SPEC_VERS 4, with the
    // size fields at their top: C_SIZE 0xFFF, C_SIZE_MULT 7, READ_BL_LEN
    // 9. The older formula reads that as 1 GiB; the card's real size is
    // its EXT_CSD's.
    var answer: [4]u32 = @splat(0);
    setBits(&answer, 126, 2, 3);
    setBits(&answer, 122, 4, 4);
    setBits(&answer, 84, 12, 0x0F5);
    setBits(&answer, 80, 4, 9);
    setBits(&answer, 62, 12, 0xFFF);
    setBits(&answer, 47, 3, 7);
    const csd = decodeMmcCsd(&answer).?;
    try testing.expectEqual(@as(u8, 4), csd.mmc_spec);
    try testing.expectEqual(@as(u64, 2_097_152), csd.blocks);
    try testing.expectEqual(@as(u16, 0x0F5), csd.command_classes);
    try testing.expect(!csd.permanent_write_protect);
    // An SD card's decoder would read structure 3 as a layout it does
    // not know.
    try testing.expect(decodeCsd(&answer) == null);
}

test "what an eMMC's EXT_CSD says" {
    // A 32 GB module's eMMC: 61,071,360 sectors (29.1 GiB), revision 8
    // (eMMC 5.1), both high-speed timings and DDR, its user area the one
    // reached.
    var raw: [ext_csd_bytes]u8 = @splat(0);
    std.mem.writeInt(u32, raw[EXT_CSD_SEC_COUNT..][0..4], 61_071_360, .little);
    raw[EXT_CSD_REV] = 8;
    raw[EXT_CSD_DEVICE_TYPE] = 0x57;
    raw[EXT_CSD_PARTITION_CONFIG] = 0x48;
    std.mem.writeInt(u32, raw[EXT_CSD_CACHE_SIZE..][0..4], 0x400, .little);
    const ext = decodeExtCsd(&raw);
    try testing.expectEqual(@as(u32, 61_071_360), ext.sectors);
    try testing.expectEqual(@as(u32, 0x400), ext.cache_size);
    try testing.expectEqual(@as(u8, 8), ext.revision);
    try testing.expect(ext.device_type & device_type_hs_52 != 0);
    try testing.expectEqual(@as(u8, 0), ext.partition_config & partition_access_mask);
    // Read again over a wider bus: the same register...
    try testing.expect(sameExtCsd(ext, decodeExtCsd(&raw)));
    // ...unless a line the board did not wire changed a byte of it.
    var garbled = raw;
    garbled[EXT_CSD_SEC_COUNT + 3] ^= 0x10;
    try testing.expect(!sameExtCsd(ext, decodeExtCsd(&garbled)));
    // Bytes the host writes are left out of the comparison: HS_TIMING
    // reads 1 once the card is switched, CACHE_CTRL 1 once its cache is.
    var switched = raw;
    switched[EXT_CSD_HS_TIMING] = 1;
    switched[EXT_CSD_CACHE_CTRL] = 1;
    try testing.expect(sameExtCsd(ext, decodeExtCsd(&switched)));
}

test "an eMMC is switched by writing a byte of its EXT_CSD" {
    // Access 3 (write byte), BUS_WIDTH (183), 8 lines (2).
    try testing.expectEqual(@as(u32, 0x03B7_0200), switchArg(EXT_CSD_BUS_WIDTH, mmcBusWidth(8)));
    try testing.expectEqual(@as(u32, 0x03B9_0100), switchArg(EXT_CSD_HS_TIMING, 1));
    try testing.expectEqual(@as(u8, 1), mmcBusWidth(4));
    try testing.expectEqual(@as(u8, 0), mmcBusWidth(1));
    // Both edges of the clock: 8 lines 6, 4 lines 5.
    try testing.expectEqual(@as(u32, 0x03B7_0600), switchArg(EXT_CSD_BUS_WIDTH, mmcBusWidthDdr(8)));
    try testing.expectEqual(@as(u8, 5), mmcBusWidthDdr(4));
}
