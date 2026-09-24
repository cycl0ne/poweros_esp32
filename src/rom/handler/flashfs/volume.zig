// SPDX-License-Identifier: MPL-2.0
//! The log on the medium: the superblock, the segments, and appending,
//! replaying and reclaiming records. `sdk/libs/dos/flashfs.zig` has the layout and
//! says why it is a log; this is the code that works it.
//!
//! `Volume(Media)` is generic over the medium so the whole format can be
//! tested on the host: the handler passes flash.device, the tests a block
//! of memory that behaves like flash (bits only clear, erasing sets a whole
//! sector). The medium must offer
//!
//!     alloc(u32) ?[]u8         free([]u8)
//!     size() u32               the bytes of the volume
//!     sectorSize() u32         the erase unit
//!     pageSize() u32           the program unit, 0 if there is none
//!     bytes() ?[]const u8      the whole medium to read straight from, or null
//!     read(u32, []u8) bool     used when bytes() is null
//!     write(u32, []const u8) bool
//!     erase(u32, u32) bool
//!
//! **The head.** Records are appended into a buffer of one sector and
//! programmed a whole page at a time, so no page is ever programmed twice.
//! `flush` writes the part-full page out, padded, and then moves on to the
//! next page: up to a page is wasted per flush, which is why a flush
//! happens when a file is closed or the disk is asked to flush, not per
//! record. Reads of what is still in the buffer are served from it.
//!
//! **The collector** always takes the oldest segment, so the log runs
//! round the volume. Moving the newest state of a file forward is safe -
//! it stays the newest - but a record that only says something about what
//! came before it (a truncation, a deletion) must not be moved, since that
//! would put it after records it was meant to precede. In the oldest
//! segment there is nothing before it left, so it is simply dropped. Taking
//! the emptiest segment instead would copy less, but there is no way to
//! keep those records in order then.
//!
//! **After a power cut** the last record is half written and fails its
//! checksum, so mounting ends that segment there. The page that was being
//! programmed may hold anything, so appending starts again at the next
//! page, and only if every page from there to the end of the sector is
//! still blank; otherwise the segment counts as full.

const std = @import("std");
const sdk = @import("sdk");
const dos = sdk.dos;
const flashfs = dos.flashfs;

/// What replay hands back for each record, in the order they were written.
pub const Record = struct {
    kind: flashfs.Kind,
    /// Where the payload is on the medium, and how long it is.
    at: u32,
    length: u32,
    /// The sector the record is in, for the collector's accounting.
    sector: u32,
    /// The bytes the record takes, header and padding included.
    size: u32,
};

pub const Error = error{
    NoMemory,
    NotFormatted,
    BadVersion,
    MediumFull,
    WriteFailed,
    EraseFailed,
    ReadFailed,
};

/// A sector's place in the log.
const Segment = struct {
    /// Which turn it had; 0 means it holds no segment (blank or garbage).
    seq: u64 align(4) = 0,
    /// How often it has been erased, as far as the log remembers.
    erases: u32 = 0,
    /// Bytes in use: the header and the records after it.
    used: u32 = 0,
    /// Of those, the bytes of records that still say something.
    live: u32 = 0,
    /// Known to be all ones, so it can be written without erasing first.
    blank: bool = false,
};

pub fn Volume(comptime Media: type) type {
    return struct {
        const V = @This();

        media: *Media,
        sector_size: u32 = 0,
        page_size: u32 = 0,
        /// Sectors in all, the superblock's included.
        sectors: u32 = 0,
        super: flashfs.Super = .{},
        /// One entry per sector; [0] is the superblock's and unused.
        segs: []Segment = &.{},
        /// The sector being appended to, 0 if there is none yet.
        head: u32 = 0,
        /// The head sector's bytes, and how much of it is filled and how
        /// much of that has reached the medium (always a whole page).
        head_buf: []u8 = &.{},
        head_used: u32 = 0,
        head_written: u32 = 0,
        /// The next segment's turn.
        next_seq: u64 align(4) = 1,
        /// Where a read lands when the medium can't be read directly.
        scratch: []u8 = &.{},

        pub fn init(media: *Media) V {
            return .{ .media = media };
        }

        /// The buffers a volume needs: one sector for the head, one for
        /// reads, and the table of segments.
        fn take(v: *V) Error!void {
            if (v.segs.len != 0) return; // mounted or formatted before
            v.sector_size = v.media.sectorSize();
            v.page_size = v.media.pageSize();
            v.sectors = v.media.size() / v.sector_size;
            if (v.sectors < 2) return error.MediumFull;
            const table = v.media.alloc(v.sectors * @sizeOf(Segment)) orelse return error.NoMemory;
            v.segs = @alignCast(std.mem.bytesAsSlice(Segment, table));
            @memset(v.segs, .{});
            v.head_buf = v.media.alloc(v.sector_size) orelse return error.NoMemory;
            v.scratch = v.media.alloc(v.sector_size) orelse return error.NoMemory;
        }

        pub fn deinit(v: *V) void {
            if (v.segs.len != 0) v.media.free(std.mem.sliceAsBytes(v.segs));
            if (v.head_buf.len != 0) v.media.free(v.head_buf);
            if (v.scratch.len != 0) v.media.free(v.scratch);
            v.* = .{ .media = v.media };
        }

        // --- reading ------------------------------------------------------

        /// `len` bytes at `off`, to look at: the medium's own memory if it
        /// can be read directly, else a copy in the scratch buffer (so at
        /// most a sector, and only valid until the next call).
        fn peek(v: *V, off: u32, len: u32) ?[]const u8 {
            if (len == 0) return v.scratch[0..0];
            if (off > v.media.size() or len > v.media.size() - off) return null;
            if (v.media.bytes()) |all| return all[off..][0..len];
            if (len > v.scratch.len) return null;
            if (!v.media.read(off, v.scratch[0..len])) return null;
            return v.scratch[0..len];
        }

        /// `into.len` bytes from `off` on the medium, or from the head
        /// buffer where they have not reached it yet.
        pub fn readAt(v: *V, off: u32, into: []u8) bool {
            const len: u32 = @intCast(into.len);
            if (len == 0) return true;
            if (v.head != 0) {
                const head_at = v.head * v.sector_size + v.head_written;
                const pending = v.head_used - v.head_written;
                if (off >= head_at and off + len <= head_at + pending) {
                    const from = v.head_written + (off - head_at);
                    @memcpy(into, v.head_buf[from..][0..len]);
                    return true;
                }
            }
            if (v.media.bytes()) |all| {
                if (off > all.len or len > all.len - off) return false;
                @memcpy(into, all[off..][0..len]);
                return true;
            }
            return v.media.read(off, into);
        }

        /// Whether every byte of a range is still all ones, so it can be
        /// programmed without erasing first.
        fn blank(v: *V, off: u32, len: u32) bool {
            var done: u32 = 0;
            while (done < len) {
                const piece = @min(@as(u32, @intCast(v.scratch.len)), len - done);
                const bytes = v.peek(off + done, piece) orelse return false;
                for (bytes) |b| {
                    if (b != 0xFF) return false;
                }
                done += piece;
            }
            return true;
        }

        // --- mounting -----------------------------------------------------

        /// The superblock and every segment header. The records themselves
        /// are `replay`'s business.
        pub fn mount(v: *V) Error!void {
            try v.take();
            const raw = v.peek(0, @sizeOf(flashfs.Super)) orelse return error.ReadFailed;
            var super: flashfs.Super = undefined;
            @memcpy(std.mem.asBytes(&super), raw);
            if (super.magic != flashfs.super_magic) return error.NotFormatted;
            if (flashfs.checksumOf(&super) != super.checksum) return error.NotFormatted;
            if (super.version != flashfs.format_version) return error.BadVersion;
            if (super.sector_size != v.sector_size or super.sectors > v.sectors) return error.NotFormatted;
            v.super = super;
            v.sectors = super.sectors;

            var sector: u32 = 1;
            while (sector < v.sectors) : (sector += 1) {
                const seg = &v.segs[sector];
                if (v.header(sector)) |h| {
                    seg.seq = h.seq;
                    seg.erases = h.erases;
                    seg.used = @sizeOf(flashfs.SegmentHeader);
                    if (h.seq >= v.next_seq) v.next_seq = h.seq + 1;
                } else {
                    seg.blank = v.blank(sector * v.sector_size, v.sector_size);
                }
            }
            return;
        }

        /// A sector's segment header, if it has a sound one.
        fn header(v: *V, sector: u32) ?flashfs.SegmentHeader {
            const raw = v.peek(sector * v.sector_size, @sizeOf(flashfs.SegmentHeader)) orelse return null;
            var h: flashfs.SegmentHeader = undefined;
            @memcpy(std.mem.asBytes(&h), raw);
            if (h.magic != flashfs.segment_magic or h.seq == 0) return null;
            if (flashfs.checksumOf(&h) != h.checksum) return null;
            return h;
        }

        /// Every record, oldest first, to `apply`. It answers how many of
        /// the record's bytes still count as live (its own size to keep it,
        /// 0 for one that is already superseded); the collector goes by
        /// that. A record that fails its checksum ends its segment: that is
        /// what a power cut leaves.
        pub fn replay(
            v: *V,
            ctx: anytype,
            comptime apply: fn (@TypeOf(ctx), *V, Record) Error!u32,
        ) Error!void {
            const order = v.media.alloc(v.sectors * @sizeOf(u32)) orelse return error.NoMemory;
            defer v.media.free(order);
            const list: []u32 = @alignCast(std.mem.bytesAsSlice(u32, order));
            var count: u32 = 0;
            for (v.segs, 0..) |seg, sector| {
                if (seg.seq == 0) continue;
                list[count] = @intCast(sector);
                count += 1;
            }
            const used = list[0..count];
            std.mem.sort(u32, used, v, lessBySeq);

            for (used) |sector| {
                try v.replaySegment(sector, ctx, apply);
            }
            if (count != 0) try v.openHead(used[count - 1]);
        }

        fn lessBySeq(v: *V, a: u32, b: u32) bool {
            return v.segs[a].seq < v.segs[b].seq;
        }

        fn replaySegment(
            v: *V,
            sector: u32,
            ctx: anytype,
            comptime apply: fn (@TypeOf(ctx), *V, Record) Error!u32,
        ) Error!void {
            const base = sector * v.sector_size;
            var off: u32 = @sizeOf(flashfs.SegmentHeader);
            var end: u32 = off;
            while (off + @sizeOf(flashfs.RecordHeader) <= v.sector_size) {
                const raw = v.peek(base + off, @sizeOf(flashfs.RecordHeader)) orelse return error.ReadFailed;
                var h: flashfs.RecordHeader = undefined;
                @memcpy(std.mem.asBytes(&h), raw);
                const size: u32 = if (h.length <= v.sector_size) @intCast(flashfs.recordSize(h.length)) else 0;
                const sound = h.kind != .end and size != 0 and
                    off + size <= v.sector_size and v.recordSound(base + off, h);
                if (!sound) {
                    // Either the end, or the ones a flush pads the rest of
                    // its page with: the next record starts on the page
                    // after this one, if there is anything there at all.
                    off = v.nextPage(off) orelse break;
                    continue;
                }
                const record: Record = .{
                    .kind = h.kind,
                    .at = base + off + @sizeOf(flashfs.RecordHeader),
                    .length = h.length,
                    .sector = sector,
                    .size = size,
                };
                v.segs[sector].live += try apply(ctx, v, record);
                off += size;
                end = off;
            }
            v.segs[sector].used = end;
        }

        /// A record's checksum over its header (with the field zeroed) and
        /// its payload.
        fn recordSound(v: *V, at: u32, h: flashfs.RecordHeader) bool {
            var bare = h;
            bare.checksum = 0;
            var crc = flashfs.crcAdd(flashfs.crcStart(), std.mem.asBytes(&bare));
            var done: u32 = 0;
            while (done < h.length) {
                const piece = @min(@as(u32, @intCast(v.scratch.len)), h.length - done);
                const bytes = v.peek(at + @sizeOf(flashfs.RecordHeader) + done, piece) orelse return false;
                crc = flashfs.crcAdd(crc, bytes);
                done += piece;
            }
            return flashfs.crcEnd(crc) == h.checksum;
        }

        /// The newest segment becomes the head again: its bytes into the
        /// buffer, and appending goes on at the next blank page.
        fn openHead(v: *V, sector: u32) Error!void {
            const seg = &v.segs[sector];
            const resume_at = v.pageUp(seg.used);
            if (resume_at >= v.sector_size or !v.blank(sector * v.sector_size + resume_at, v.sector_size - resume_at)) {
                // The page that was being programmed when the power went,
                // or a full sector: leave it closed and take a fresh one.
                seg.used = v.sector_size;
                return;
            }
            const raw = v.peek(sector * v.sector_size, resume_at) orelse return error.ReadFailed;
            @memcpy(v.head_buf[0..resume_at], raw);
            @memset(v.head_buf[resume_at..], 0xFF);
            v.head = sector;
            v.head_used = resume_at;
            v.head_written = resume_at;
            seg.used = resume_at;
        }

        fn pageUp(v: *V, off: u32) u32 {
            if (v.page_size == 0) return off;
            return (off + v.page_size - 1) & ~(v.page_size - 1);
        }

        /// The next page boundary after `off` inside the sector, or null if
        /// the sector ends first. Records only ever start at one after a
        /// flush, so this is where to look next when the bytes here are
        /// padding.
        fn nextPage(v: *V, off: u32) ?u32 {
            if (v.page_size == 0) return null;
            const next = v.pageUp(off + 1);
            if (next <= off or next + @sizeOf(flashfs.RecordHeader) > v.sector_size) return null;
            return next;
        }

        // --- formatting ---------------------------------------------------

        /// A fresh volume: the superblock, and every segment forgotten. The
        /// sectors are not erased - a segment header that isn't sound means
        /// the sector holds nothing, and one that is blank is written
        /// without erasing - so formatting a 14 MiB disk takes one erase
        /// and one page.
        pub fn format(v: *V, label: []const u8, date: dos.DateStamp) Error!void {
            try v.take();
            var super: flashfs.Super = .{
                .sector_size = v.sector_size,
                .sectors = v.sectors,
                .created = date,
            };
            const len = @min(label.len, flashfs.max_name);
            @memcpy(super.name[0..len], label[0..len]);
            super.checksum = flashfs.checksumOf(&super);

            if (!v.blank(0, v.sector_size) and !v.media.erase(0, v.sector_size)) return error.EraseFailed;
            const bytes = std.mem.asBytes(&super);
            if (!v.media.write(0, bytes)) return error.WriteFailed;
            v.super = super;
            @memset(v.segs, .{});
            v.next_seq = 1;
            v.head = 0;
            v.head_used = 0;
            v.head_written = 0;
            // Every other sector is stale, not blank: whether it has to be
            // erased is decided when it is taken.
            var sector: u32 = 1;
            while (sector < v.sectors) : (sector += 1) {
                v.segs[sector].blank = v.blank(sector * v.sector_size, v.sector_size);
            }
        }

        /// The volume's name, as the superblock holds it.
        pub fn name(v: *const V) []const u8 {
            return v.super.name[0..v.super.nameLen()];
        }

        // --- appending ----------------------------------------------------

        /// Room for a record of `payload` bytes in the head, taking a new
        /// segment if the one there is full.
        fn room(v: *V, payload: u32) Error!void {
            const size: u32 = @intCast(flashfs.recordSize(payload));
            if (size + @sizeOf(flashfs.SegmentHeader) > v.sector_size) return error.MediumFull;
            if (v.head != 0 and v.head_used + size <= v.sector_size) return;
            try v.newHead();
            if (v.head_used + size > v.sector_size) return error.MediumFull;
        }

        /// A fresh segment at the head: the emptiest free sector, erased if
        /// it isn't blank, with the next turn and one more erase counted.
        fn newHead(v: *V) Error!void {
            try v.flush();
            const sector = v.freeSector() orelse return error.MediumFull;
            const seg = &v.segs[sector];
            if (!seg.blank) {
                if (!v.media.erase(sector * v.sector_size, v.sector_size)) return error.EraseFailed;
                seg.erases += 1;
            }
            var h: flashfs.SegmentHeader = .{ .seq = v.next_seq, .erases = seg.erases };
            h.checksum = flashfs.checksumOf(&h);
            v.next_seq += 1;
            seg.seq = h.seq;
            seg.live = 0;
            seg.used = @sizeOf(flashfs.SegmentHeader);
            seg.blank = false;
            @memset(v.head_buf, 0xFF);
            @memcpy(v.head_buf[0..@sizeOf(flashfs.SegmentHeader)], std.mem.asBytes(&h));
            v.head = sector;
            v.head_used = @sizeOf(flashfs.SegmentHeader);
            v.head_written = 0;
        }

        /// A sector holding no segment: a blank one first, else the one
        /// erased least often, so the wear spreads.
        fn freeSector(v: *V) ?u32 {
            var best: ?u32 = null;
            var sector: u32 = 1;
            while (sector < v.sectors) : (sector += 1) {
                const seg = &v.segs[sector];
                if (seg.seq != 0) continue;
                if (seg.blank) return sector;
                const chosen = best orelse {
                    best = sector;
                    continue;
                };
                if (seg.erases < v.segs[chosen].erases) best = sector;
            }
            return best;
        }

        /// How many sectors hold no segment.
        pub fn freeSegments(v: *V) u32 {
            var count: u32 = 0;
            for (v.segs[1..]) |seg| {
                if (seg.seq == 0) count += 1;
            }
            return count;
        }

        /// A record at the end of the log: its header, the fixed part of
        /// its payload and up to two tails (a name and a comment, or a
        /// file's bytes). Answers where the payload landed on the medium,
        /// so the caller can point an extent at it.
        pub fn append(v: *V, kind: flashfs.Kind, fixed: []const u8, tail: []const u8, more: []const u8) Error!u32 {
            const payload: u32 = @intCast(fixed.len + tail.len + more.len);
            try v.room(payload);
            var h: flashfs.RecordHeader = .{ .kind = kind, .length = payload };
            var crc = flashfs.crcAdd(flashfs.crcStart(), std.mem.asBytes(&h));
            crc = flashfs.crcAdd(crc, fixed);
            crc = flashfs.crcAdd(crc, tail);
            crc = flashfs.crcAdd(crc, more);
            h.checksum = flashfs.crcEnd(crc);

            const at = v.head * v.sector_size + v.head_used + @sizeOf(flashfs.RecordHeader);
            v.put(std.mem.asBytes(&h));
            v.put(fixed);
            v.put(tail);
            v.put(more);
            v.head_used = @intCast(flashfs.padded(v.head_used));
            v.segs[v.head].used = v.head_used;
            v.segs[v.head].live += @intCast(flashfs.recordSize(payload));
            try v.write();
            return at;
        }

        fn put(v: *V, bytes: []const u8) void {
            if (bytes.len == 0) return;
            @memcpy(v.head_buf[v.head_used..][0..bytes.len], bytes);
            v.head_used += @intCast(bytes.len);
        }

        /// The whole pages the buffer has gathered, out to the medium.
        fn write(v: *V) Error!void {
            if (v.page_size == 0) return;
            const ready = (v.head_used / v.page_size) * v.page_size;
            if (ready <= v.head_written) return;
            const at = v.head * v.sector_size + v.head_written;
            if (!v.media.write(at, v.head_buf[v.head_written..ready])) return error.WriteFailed;
            v.head_written = ready;
        }

        /// What is still in the buffer, out to the medium. The rest of that
        /// page is given up, so no page is ever programmed twice.
        pub fn flush(v: *V) Error!void {
            if (v.head == 0 or v.head_used == v.head_written) return;
            const end = if (v.page_size == 0) v.head_used else v.pageUp(v.head_used);
            const at = v.head * v.sector_size + v.head_written;
            if (!v.media.write(at, v.head_buf[v.head_written..end])) return error.WriteFailed;
            v.head_written = end;
            v.head_used = end;
            v.segs[v.head].used = end;
        }

        // --- the collector ------------------------------------------------

        /// The segment with the lowest turn: the oldest thing on the
        /// volume, and so the one the collector takes.
        pub fn oldest(v: *V) ?u32 {
            var best: ?u32 = null;
            var sector: u32 = 1;
            while (sector < v.sectors) : (sector += 1) {
                if (v.segs[sector].seq == 0) continue;
                const chosen = best orelse {
                    best = sector;
                    continue;
                };
                if (v.segs[sector].seq < v.segs[chosen].seq) best = sector;
            }
            return best;
        }

        /// A sector's segment forgotten: what was worth keeping in it has
        /// been appended at the head, so the next segment that needs a
        /// sector may erase this one and take it.
        pub fn forget(v: *V, sector: u32) Error!void {
            try v.flush();
            v.segs[sector] = .{};
        }

        /// The sector a byte on the medium is in.
        pub fn sectorOf(v: *const V, at: u32) u32 {
            return at / v.sector_size;
        }

        /// A record's bytes stop counting: its segment has that much less
        /// worth keeping.
        pub fn kill(v: *V, at: u32, size: u32) void {
            const sector = v.sectorOf(at);
            const seg = &v.segs[sector];
            seg.live -= @min(seg.live, size);
        }

        /// A record's bytes start counting.
        pub fn keep(v: *V, at: u32, size: u32) void {
            v.segs[v.sectorOf(at)].live += size;
        }
    };
}

// --- tests ------------------------------------------------------------------

const testing = std.testing;
const MemMedia = @import("memmedia.zig").MemMedia;

const TestVolume = Volume(MemMedia);

/// A small volume: 16 sectors of 512 bytes, pages of 64.
const test_sectors = 16;
const test_sector = 512;
const test_page = 64;

fn testMedia(store: []u8) MemMedia {
    return MemMedia.init(store, test_sector, test_page);
}

/// What replay saw, in order.
const Seen = struct {
    kinds: [64]flashfs.Kind = undefined,
    count: usize = 0,

    fn note(seen: *Seen, _: *TestVolume, r: Record) Error!u32 {
        seen.kinds[seen.count] = r.kind;
        seen.count += 1;
        return r.size;
    }
};

fn formatted(v: *TestVolume) !void {
    try v.format("Test Disk", .{ .days = 1, .minute = 2, .tick = 3 });
}

test "format writes a superblock that mounts again" {
    var store: [test_sectors * test_sector]u8 = undefined;
    var media = testMedia(&store);
    var v = TestVolume.init(&media);
    try formatted(&v);
    try testing.expectEqualStrings("Test Disk", v.name());
    v.deinit();

    var again = TestVolume.init(&media);
    try again.mount();
    try testing.expectEqualStrings("Test Disk", again.name());
    try testing.expectEqual(@as(i32, 1), again.super.created.days);
    try testing.expectEqual(@as(u32, test_sectors - 1), again.freeSegments());
    again.deinit();
    try testing.expectEqual(@as(usize, 0), media.live);
}

test "an unformatted medium doesn't mount" {
    var store: [test_sectors * test_sector]u8 = undefined;
    var media = testMedia(&store);
    var v = TestVolume.init(&media);
    try testing.expectError(error.NotFormatted, v.mount());
    v.deinit();
    try testing.expectEqual(@as(usize, 0), media.live);
}

test "records come back in the order they were written" {
    var store: [test_sectors * test_sector]u8 = undefined;
    var media = testMedia(&store);
    var v = TestVolume.init(&media);
    try formatted(&v);
    const meta: flashfs.Meta = .{ .inode = 2, .parent = 1, .name_len = 3 };
    _ = try v.append(.meta, flashfs.bytesOf(&meta), "one", "");
    const data: flashfs.Data = .{ .inode = 2 };
    const at = try v.append(.data, flashfs.bytesOf(&data), "hello", "");
    const kill_it: flashfs.Kill = .{ .inode = 2 };
    _ = try v.append(.kill, flashfs.bytesOf(&kill_it), "", "");
    // Still in the buffer: a read must find it there.
    var buffer: [5]u8 = undefined;
    try testing.expect(v.readAt(at + @sizeOf(flashfs.Data), &buffer));
    try testing.expectEqualStrings("hello", &buffer);
    try v.flush();
    try testing.expect(v.readAt(at + @sizeOf(flashfs.Data), &buffer));
    try testing.expectEqualStrings("hello", &buffer);
    v.deinit();

    var again = TestVolume.init(&media);
    try again.mount();
    var seen: Seen = .{};
    try again.replay(&seen, Seen.note);
    try testing.expectEqual(@as(usize, 3), seen.count);
    try testing.expectEqual(flashfs.Kind.meta, seen.kinds[0]);
    try testing.expectEqual(flashfs.Kind.data, seen.kinds[1]);
    try testing.expectEqual(flashfs.Kind.kill, seen.kinds[2]);
    // Appending goes on in the same segment.
    _ = try again.append(.kill, flashfs.bytesOf(&kill_it), "", "");
    try again.flush();
    again.deinit();
    try testing.expectEqual(@as(usize, 0), media.live);
}

test "records fill one segment after another" {
    var store: [test_sectors * test_sector]u8 = undefined;
    var media = testMedia(&store);
    var v = TestVolume.init(&media);
    try formatted(&v);
    const data: flashfs.Data = .{ .inode = 2 };
    var payload: [200]u8 = undefined;
    @memset(&payload, 'x');
    var written: u32 = 0;
    while (written < 10) : (written += 1) {
        _ = try v.append(.data, flashfs.bytesOf(&data), &payload, "");
    }
    try v.flush();
    try testing.expect(v.freeSegments() < test_sectors - 2);
    v.deinit();

    var again = TestVolume.init(&media);
    try again.mount();
    var seen: Seen = .{};
    try again.replay(&seen, Seen.note);
    try testing.expectEqual(@as(usize, 10), seen.count);
    again.deinit();
    try testing.expectEqual(@as(usize, 0), media.live);
}

test "a medium that can't be read as memory works the same" {
    var store: [test_sectors * test_sector]u8 = undefined;
    var media = testMedia(&store);
    media.direct = false;
    var v = TestVolume.init(&media);
    try formatted(&v);
    const data: flashfs.Data = .{ .inode = 7 };
    _ = try v.append(.data, flashfs.bytesOf(&data), "over spi", "");
    try v.flush();
    v.deinit();

    var again = TestVolume.init(&media);
    try again.mount();
    var seen: Seen = .{};
    try again.replay(&seen, Seen.note);
    try testing.expectEqual(@as(usize, 1), seen.count);
    again.deinit();
    try testing.expectEqual(@as(usize, 0), media.live);
}

test "a write cut short ends the log there, and the rest is still good" {
    var store: [test_sectors * test_sector]u8 = undefined;
    var media = testMedia(&store);
    var v = TestVolume.init(&media);
    try formatted(&v);
    const data: flashfs.Data = .{ .inode = 2 };
    _ = try v.append(.data, flashfs.bytesOf(&data), "first", "");
    try v.flush();
    // The power goes 8 bytes into the next flush.
    media.budget = 8;
    _ = try v.append(.data, flashfs.bytesOf(&data), "second", "");
    v.flush() catch {};
    media.budget = null;
    v.deinit();

    var again = TestVolume.init(&media);
    try again.mount();
    var seen: Seen = .{};
    try again.replay(&seen, Seen.note);
    try testing.expectEqual(@as(usize, 1), seen.count);
    // And the volume takes writes again.
    _ = try again.append(.data, flashfs.bytesOf(&data), "third", "");
    try again.flush();
    again.deinit();

    var third = TestVolume.init(&media);
    try third.mount();
    var after: Seen = .{};
    try third.replay(&after, Seen.note);
    try testing.expectEqual(@as(usize, 2), after.count);
    third.deinit();
    try testing.expectEqual(@as(usize, 0), media.live);
}

test "a forgotten segment's sector comes back" {
    var store: [test_sectors * test_sector]u8 = undefined;
    var media = testMedia(&store);
    var v = TestVolume.init(&media);
    try formatted(&v);
    const data: flashfs.Data = .{ .inode = 2 };
    var payload: [200]u8 = undefined;
    @memset(&payload, 'y');
    var written: u32 = 0;
    while (written < 6) : (written += 1) {
        _ = try v.append(.data, flashfs.bytesOf(&data), &payload, "");
    }
    try v.flush();
    const before = v.freeSegments();
    const old = v.oldest().?;
    try testing.expect(v.segs[old].seq != 0);
    try v.forget(old);
    try testing.expectEqual(@as(u64, 0), v.segs[old].seq);
    try testing.expectEqual(before + 1, v.freeSegments());
    v.deinit();
    try testing.expectEqual(@as(usize, 0), media.live);
}
