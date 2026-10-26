// SPDX-License-Identifier: MPL-2.0
//! posfs's journal: every change, as it was asked for, in the order it
//! was made - gathered in memory and written in groups, the changes of a
//! moment with one barrier, and read again by the next mount when the
//! volume was not put away.
//!
//! **A journal block** starts with its header - its place in the chain
//! (`jseq`), the next block (taken with this one, so writing a record
//! never waits for an allocation), the first record's lsn and the life of
//! the mount that wrote it - and holds records after it. **A record** is
//! its header (lsn, kind, length, flags, checksum) and its payload, padded
//! to eight bytes; it never crosses a block. A change too big for the
//! room left goes in pieces, each a record of its own, all but the last
//! marked RECORD_CONTINUED: read back, the pieces are one record again
//! (`Assembly`), and a group the journal ends in the middle of is not
//! there at all.
//!
//! **Records are written a unit at a time**, and a unit only once: the
//! records waiting (`pending`) go out in whole units at `flush`, the last
//! padded, and the next records start in the unit after. On flash that
//! means no page is programmed twice; on a disk, that no sector holding a
//! durable record is ever written again, so a cut while one is written
//! loses only what was in it - the records of that flush.
//!
//! **Data goes down first.** A commit names blocks written before it, and
//! a device with a cache puts writes down in an order of its own: while
//! such blocks wait (`unordered`), a barrier goes in front of the
//! journal's next write, so no record on the medium names data that is
//! not.
//!
//! **Reading it back** (`Scanner`) takes a record only when its lsn is the
//! next one, its checksum - seeded with the volume's id and the life -
//! holds, and it fits its block. A record that fails ends its flush; the
//! next flush starts at the next unit, or in the next block, and if no
//! record there is the next one the journal ends there. So a cut that
//! put down only part of a flush keeps its records up to the first one
//! lost, and none after it. A journal block
//! is the one wanted only when its header has the jseq and the life the
//! checkpoint said; one left from an earlier use has neither.

const sdk = @import("sdk");
const layout = sdk.dos.posfs.layout;
const volume = @import("volume.zig");
const space = @import("space.zig");
const Volume = volume.Volume;
const Error = volume.Error;

const header_size: u32 = @sizeOf(layout.JournalHeader);
const record_header: u32 = @sizeOf(layout.RecordHeader);

/// A journal block in use, and its place in the chain.
const InUse = struct { addr: u64, jseq: u64 };

pub const Journal = struct {
    /// The block records go into now, its jseq, and the one after it.
    block: u64 = 0,
    jseq: u64 = 0,
    next: u64 = 0,
    /// Where in the block the units not yet written start, and the bytes
    /// of records waiting in `pending` from there.
    unit_start: u32 = 0,
    pending_len: u32 = 0,
    pending: []u8 = &.{},
    /// The lsn the next record gets.
    lsn: u64 = 1,
    /// The blocks the journal holds, oldest first.
    blocks: []InUse = &.{},
    used: usize = 0,
    /// Blocks begun since the last checkpoint.
    since_checkpoint: u32 = 0,
    /// Records written since the last checkpoint.
    records: u32 = 0,
    /// The highest jseq a mount found in the journal.
    highest_jseq: u64 = 0,
};

/// The jseq a new journal starts at: past every one the volume has seen.
pub fn nextJseq(vol: *const Volume) u64 {
    const seen = vol.journal.highest_jseq;
    const after = if (seen > vol.durable.jseq) seen else vol.durable.jseq;
    return after + 1;
}

/// The most bytes one record's payload may have.
pub fn payloadMax(vol: *const Volume) u32 {
    return vol.block_size - header_size - record_header;
}

/// The most bytes a change written in pieces may have.
pub const max_record: u32 = 256 * 1024;

pub fn release(vol: *Volume) void {
    const journal = &vol.journal;
    vol.free(journal.pending);
    vol.freeSlice(InUse, journal.blocks);
    journal.* = .{};
}

fn remember(vol: *Volume, addr: u64, jseq: u64) Error!void {
    const journal = &vol.journal;
    if (journal.used == journal.blocks.len) {
        const grown = try vol.allocSlice(InUse, if (journal.blocks.len == 0) 16 else journal.blocks.len * 2);
        @memcpy(grown[0..journal.used], journal.blocks[0..journal.used]);
        vol.freeSlice(InUse, journal.blocks);
        journal.blocks = grown;
    }
    journal.blocks[journal.used] = .{ .addr = addr, .jseq = jseq };
    journal.used += 1;
}

/// A journal block taken: held, since nothing durable names it.
fn takeBlock(vol: *Volume) Error!u64 {
    const run = try space.alloc(vol, 1, .held, true);
    try vol.prepare(run.start, 1);
    return run.start;
}

/// A new journal: its first block (jseq `jseq`) and the one after it, the
/// header waiting for the first flush. What it held before stays held
/// until checkpoints let it go.
pub fn begin(vol: *Volume, jseq: u64) Error!void {
    const journal = &vol.journal;
    if (journal.pending.len == 0) journal.pending = try vol.alloc(vol.block_size);
    const first = try takeBlock(vol);
    journal.next = try takeBlock(vol);
    journal.block = first;
    journal.jseq = jseq;
    try remember(vol, first, jseq);
    startBlock(vol);
}

/// The current block's header put in front of what is pending.
fn startBlock(vol: *Volume) void {
    const journal = &vol.journal;
    var header: layout.JournalHeader = .{
        .jseq = journal.jseq,
        .next = journal.next,
        .first_lsn = journal.lsn,
        .life = vol.life,
        .uuid = vol.uuid,
    };
    header.checksum = layout.checksumOf(&vol.uuid, &header);
    @memcpy(journal.pending[0..header_size], layout.bytesOf(&header));
    journal.unit_start = 0;
    journal.pending_len = header_size;
}

/// Where replay of the records after now would start: the block, its
/// jseq, and the offset of the next record.
pub fn position(vol: *const Volume) struct { block: u64, jseq: u64, offset: u32 } {
    const journal = &vol.journal;
    return .{ .block = journal.block, .jseq = journal.jseq, .offset = journal.unit_start + journal.pending_len };
}

/// A record put in the pending units: `kind`, `flags`, and the payload
/// made of `parts` in order - in pieces when it does not fit the room
/// left. It is on the medium after the next `flush`.
pub fn append(vol: *Volume, kind: layout.Record, flags: u32, parts: []const []const u8) Error!void {
    const journal = &vol.journal;
    var total: usize = 0;
    for (parts) |part| total += part.len;
    if (total > max_record) return error.InvalidArgument;
    var part_index: usize = 0;
    var part_at: usize = 0;
    var left = total;
    while (true) {
        // A piece needs its header and a word; less than that left, and
        // the record goes on in the next block.
        var room = vol.block_size - journal.unit_start - journal.pending_len;
        if (room < record_header + 8) {
            try nextBlock(vol);
            room = vol.block_size - journal.unit_start - journal.pending_len;
        }
        const fits: usize = room - record_header;
        const len: u32 = @intCast(if (left < fits) left else fits);
        const continued = len < left;
        const at = journal.pending_len;
        var header: layout.RecordHeader = .{
            .lsn = journal.lsn,
            .kind = @intFromEnum(kind),
            .len = len,
            .flags = flags | (if (continued) layout.RECORD_CONTINUED else 0),
        };
        var crc = layout.seededLife(&vol.uuid, vol.life);
        crc = layout.crcAdd(crc, layout.checked(&header));
        var put: u32 = at + record_header;
        var need: usize = len;
        while (need > 0) {
            const part = parts[part_index];
            const piece = @min(need, part.len - part_at);
            const bytes = part[part_at..][0..piece];
            crc = layout.crcAdd(crc, bytes);
            @memcpy(journal.pending[put..][0..piece], bytes);
            put += @intCast(piece);
            need -= piece;
            part_at += piece;
            if (part_at == part.len) {
                part_index += 1;
                part_at = 0;
            }
        }
        // Parts that are empty are passed over.
        while (part_index < parts.len and parts[part_index].len == 0) part_index += 1;
        header.checksum = layout.crcEnd(crc);
        @memcpy(journal.pending[at..][0..record_header], layout.bytesOf(&header));
        // The padding: what an unwritten byte reads as.
        const size = record_header + @as(u32, @intCast(layout.pad8(len)));
        const fill: u8 = if (vol.erase_size != 0) 0xFF else 0;
        @memset(journal.pending[put .. at + size], fill);
        journal.pending_len += size;
        journal.lsn += 1;
        journal.records += 1;
        left -= len;
        if (!continued) return;
    }
}

/// On to the journal's next block: what is pending in this one goes out
/// first, and the block after the next is taken.
fn nextBlock(vol: *Volume) Error!void {
    const journal = &vol.journal;
    try writePending(vol);
    journal.block = journal.next;
    journal.jseq += 1;
    journal.next = try takeBlock(vol);
    try remember(vol, journal.block, journal.jseq);
    journal.since_checkpoint += 1;
    startBlock(vol);
}

/// The pending units written, padded to a whole unit, and nothing more
/// pending: the next record starts in the unit after. Data written since
/// the last barrier is put down before them.
fn writePending(vol: *Volume) Error!void {
    const journal = &vol.journal;
    if (journal.pending_len == 0) return;
    if (vol.unordered) try vol.barrier();
    const unit = vol.write_unit;
    var len = (journal.pending_len + unit - 1) / unit * unit;
    if (journal.unit_start + len > vol.block_size) len = vol.block_size - journal.unit_start;
    const fill: u8 = if (vol.erase_size != 0) 0xFF else 0;
    @memset(journal.pending[journal.pending_len..len], fill);
    try vol.writeAt(journal.block, journal.unit_start, journal.pending[0..len]);
    journal.unit_start += len;
    journal.pending_len = 0;
}

/// Everything appended on the medium itself: the changes answered since
/// the last flush made durable together.
pub fn flush(vol: *Volume) Error!void {
    if (vol.journal.pending_len == 0) return;
    try writePending(vol);
    try vol.barrier();
    // A block too full for another record is left: the next record
    // starts the next block.
}

/// Whether records are waiting to be written.
pub fn hasPending(vol: *const Volume) bool {
    const journal = &vol.journal;
    return journal.pending_len > 0 and !(journal.unit_start == 0 and journal.pending_len == header_size);
}

/// A checkpoint is durable: the blocks the one before it needed no
/// longer are.
pub fn afterCheckpoint(vol: *Volume, keep_from: u64) Error!void {
    const journal = &vol.journal;
    var kept: usize = 0;
    for (journal.blocks[0..journal.used]) |entry| {
        if (entry.jseq < keep_from and entry.addr != journal.block) {
            try space.releaseHeld(vol, entry.addr, 1);
        } else {
            journal.blocks[kept] = entry;
            kept += 1;
        }
    }
    journal.used = kept;
    journal.since_checkpoint = 0;
    journal.records = 0;
}

/// The blocks a mount found the journal holding, kept until checkpoints
/// let them go.
pub fn adopt(vol: *Volume, addr: u64, jseq: u64) Error!void {
    try remember(vol, addr, jseq);
}

// --- reading back ---------------------------------------------------------------

pub const Record = struct {
    lsn: u64,
    kind: layout.Record,
    flags: u32,
    payload: []const u8,
};

/// The records after a checkpoint, one at a time. Each block is read into
/// `buffer` (a block of the scanner's own), so a record's payload is good
/// until the next one is asked for.
pub const Scanner = struct {
    vol: *Volume,
    buffer: []u8,
    block: u64,
    jseq: u64,
    offset: u32,
    life: u64,
    lsn: u64,
    /// Whether `buffer` holds `block` and its header checked out.
    loaded: bool = false,
    /// The blocks seen, for the caller to keep.
    on_block: ?*const fn (scanner: *Scanner, addr: u64, jseq: u64, next: u64) Error!void = null,
    context: ?*anyopaque = null,

    pub fn init(vol: *Volume, buffer: []u8, slot: *const layout.CheckpointSlot) Scanner {
        return .{
            .vol = vol,
            .buffer = buffer,
            .block = slot.jblock,
            .jseq = slot.jseq,
            .offset = slot.joffset,
            .life = slot.life,
            .lsn = slot.next_lsn,
        };
    }

    /// Reads `addr` and checks its header is the one the chain wants.
    fn load(scanner: *Scanner, addr: u64) Error!bool {
        const vol = scanner.vol;
        if (addr == 0 or addr >= vol.block_count) return false;
        scanner.vol.readBlocks(addr, scanner.buffer) catch |err| switch (err) {
            error.Io => return false,
            else => return err,
        };
        var header: layout.JournalHeader = undefined;
        @memcpy(layout.bytesOfMut(&header), scanner.buffer[0..header_size]);
        if (header.magic != layout.journal_magic) return false;
        if (!volume.eqlBytes(&header.uuid, &vol.uuid)) return false;
        if (layout.checksumOf(&vol.uuid, &header) != header.checksum) return false;
        if (header.jseq != scanner.jseq or header.life != scanner.life) return false;
        if (scanner.on_block) |seen| try seen(scanner, addr, header.jseq, header.next);
        scanner.loaded = true;
        return true;
    }

    fn nextOf(scanner: *const Scanner) u64 {
        return layout.getU64(scanner.buffer, @offsetOf(layout.JournalHeader, "next"));
    }

    /// The record at `offset`, if it is the next one.
    fn recordAt(scanner: *Scanner, offset: u32) ?Record {
        const vol = scanner.vol;
        if (offset + record_header > vol.block_size) return null;
        var header: layout.RecordHeader = undefined;
        @memcpy(layout.bytesOfMut(&header), scanner.buffer[offset..][0..record_header]);
        if (header.lsn != scanner.lsn) return null;
        if (header.len > vol.block_size - offset - record_header) return null;
        const payload = scanner.buffer[offset + record_header ..][0..header.len];
        var crc = layout.seededLife(&vol.uuid, scanner.life);
        crc = layout.crcAdd(crc, layout.checked(&header));
        crc = layout.crcAdd(crc, payload);
        if (layout.crcEnd(crc) != header.checksum) return null;
        return .{ .lsn = header.lsn, .kind = @enumFromInt(header.kind), .flags = header.flags, .payload = payload };
    }

    /// The next record, or null where the journal ends.
    pub fn next(scanner: *Scanner) Error!?Record {
        const vol = scanner.vol;
        if (!scanner.loaded) {
            if (!try scanner.load(scanner.block)) return null;
            if (scanner.offset < header_size) scanner.offset = header_size;
        }
        if (scanner.recordAt(scanner.offset)) |record| return scanner.take(record);
        // Not here: the rest of this unit was padding. The next flush
        // starts at the next unit.
        const unit = vol.write_unit;
        const boundary = (scanner.offset + unit - 1) / unit * unit;
        if (boundary != scanner.offset and boundary < vol.block_size) {
            if (scanner.recordAt(boundary)) |record| {
                scanner.offset = boundary;
                return scanner.take(record);
            }
        }
        // Or in the next block.
        const following = scanner.nextOf();
        scanner.jseq += 1;
        if (!try scanner.load(following)) return null;
        scanner.block = following;
        scanner.offset = header_size;
        if (scanner.recordAt(scanner.offset)) |record| return scanner.take(record);
        return null;
    }

    fn take(scanner: *Scanner, record: Record) Record {
        scanner.offset += record_header + @as(u32, @intCast(layout.pad8(record.payload.len)));
        scanner.lsn += 1;
        return record;
    }

    /// The next whole record, its pieces put together in `assembly`; null
    /// where the journal ends, even in the middle of one.
    pub fn nextWhole(scanner: *Scanner, assembly: *Assembly) Error!?Record {
        const first = try scanner.next() orelse return null;
        if (first.flags & layout.RECORD_CONTINUED == 0) return first;
        assembly.len = 0;
        const kind = first.kind;
        const lsn = first.lsn;
        const flags = first.flags & ~layout.RECORD_CONTINUED;
        try assembly.add(scanner.vol, first.payload);
        while (true) {
            const piece = try scanner.next() orelse return null;
            if (piece.kind != kind) return null;
            try assembly.add(scanner.vol, piece.payload);
            if (piece.flags & layout.RECORD_CONTINUED == 0) {
                return .{ .lsn = lsn, .kind = kind, .flags = flags, .payload = assembly.bytes[0..assembly.len] };
            }
        }
    }
};

/// The pieces of a record written in pieces, put together.
pub const Assembly = struct {
    bytes: []u8 = &.{},
    len: usize = 0,

    fn add(assembly: *Assembly, vol: *Volume, piece: []const u8) Error!void {
        if (assembly.len + piece.len > max_record) return error.Corrupt;
        if (assembly.len + piece.len > assembly.bytes.len) {
            var size: usize = if (assembly.bytes.len == 0) 4096 else assembly.bytes.len;
            while (size < assembly.len + piece.len) size *= 2;
            const grown = try vol.alloc(size);
            @memcpy(grown[0..assembly.len], assembly.bytes[0..assembly.len]);
            vol.free(assembly.bytes);
            assembly.bytes = grown;
        }
        @memcpy(assembly.bytes[assembly.len..][0..piece.len], piece);
        assembly.len += piece.len;
    }

    pub fn deinit(assembly: *Assembly, vol: *Volume) void {
        vol.free(assembly.bytes);
        assembly.* = .{};
    }
};
