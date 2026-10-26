// SPDX-License-Identifier: MIT
//! A pack's index, version 2: where in the pack each object starts, found
//! by its id.
//!
//! `\377tOc`, version 2, a fanout of 256 counts - how many ids start
//! with a byte up to each - the ids sorted, a CRC-32 of each entry as the
//! pack holds it, each entry's offset in four bytes - or, its top bit
//! set, the index of an eight-byte one in the table after - the pack's
//! SHA-1 and the SHA-1 of the index before it.

const _git = @import("_git.zig");
const Id = _git.Id;
const CryptoBase = @import("sdk").interface.crypto.CryptoBase;

const magic = "\xfftOc";
const fanout_at = 8;
const ids_at = fanout_at + 256 * 4;

/// What the index holds of one entry.
pub const Entry = struct {
    id: Id,
    crc: u32,
    offset: u64,
};

/// An index read in place.
pub const Idx = struct {
    bytes: []const u8,
    count: u32,
    large_count: usize,

    /// The index in `bytes`, its sizes checked; null when it is none.
    pub fn open(bytes: []const u8) ?Idx {
        if (bytes.len < ids_at + 40 or !_git.same(bytes[0..4], magic) or _git.get32(bytes[4..8]) != 2) return null;
        var previous: u32 = 0;
        for (0..256) |index| {
            const count = _git.get32(bytes[fanout_at + index * 4 ..]);
            if (count < previous) return null;
            previous = count;
        }
        const needed = ids_at + @as(usize, previous) * 28 + 40;
        if (bytes.len < needed or (bytes.len - needed) % 8 != 0) return null;
        return .{ .bytes = bytes, .count = previous, .large_count = (bytes.len - needed) / 8 };
    }

    /// How many ids start with a byte up to `byte`.
    pub fn fanout(idx: *const Idx, byte: usize) u32 {
        return _git.get32(idx.bytes[fanout_at + byte * 4 ..]);
    }

    pub fn idAt(idx: *const Idx, index: u32) *const Id {
        return idx.bytes[ids_at + @as(usize, index) * 20 ..][0..20];
    }

    pub fn crcAt(idx: *const Idx, index: u32) u32 {
        return _git.get32(idx.bytes[ids_at + @as(usize, idx.count) * 20 + @as(usize, index) * 4 ..]);
    }

    /// Where the entry starts in the pack; null for an eight-byte offset
    /// the table does not have.
    pub fn offsetAt(idx: *const Idx, index: u32) ?u64 {
        const small_at = ids_at + @as(usize, idx.count) * 24;
        const small = _git.get32(idx.bytes[small_at + @as(usize, index) * 4 ..]);
        if (small & 0x8000_0000 == 0) return small;
        const large = small & 0x7FFF_FFFF;
        if (large >= idx.large_count) return null;
        const at = small_at + @as(usize, idx.count) * 4 + @as(usize, large) * 8;
        return @as(u64, _git.get32(idx.bytes[at..])) << 32 | _git.get32(idx.bytes[at + 4 ..]);
    }

    /// The position of `id` among the index's; null when the pack does
    /// not hold it.
    pub fn find(idx: *const Idx, id: *const Id) ?u32 {
        var low: u32 = if (id[0] == 0) 0 else idx.fanout(id[0] - 1);
        var high: u32 = idx.fanout(id[0]);
        while (low < high) {
            const middle = low + (high - low) / 2;
            switch (_git.order(idx.idAt(middle), id)) {
                .equal => return middle,
                .less => low = middle + 1,
                .greater => high = middle,
            }
        }
        return null;
    }

    /// The SHA-1 of the pack it indexes.
    pub fn packChecksum(idx: *const Idx) *const Id {
        return idx.bytes[idx.bytes.len - 40 ..][0..20];
    }

    /// Whether its own SHA-1, at its end, is right.
    pub fn verify(idx: *const Idx, cb: *CryptoBase) bool {
        const sum = _git.sha1Of(cb, idx.bytes[0 .. idx.bytes.len - 20]);
        return _git.same(&sum, idx.bytes[idx.bytes.len - 20 ..]);
    }
};

/// The size of an index of `count` entries, `large` of them past 2 GiB.
pub fn size(count: usize, large: usize) usize {
    return ids_at + count * 28 + large * 8 + 40;
}

/// The index of `entries`, sorted by id, for the pack whose SHA-1 is
/// `pack_checksum`, into `sink`: false when the sink failed.
pub fn write(cb: *CryptoBase, entries: []const Entry, pack_checksum: *const Id, sink: _git.Sink) bool {
    var emit: _git.Emit = .{ .sink = sink, .sha = _git.Sha1.start(cb) };
    emit.put(magic);
    emit.be32(2);
    var at: usize = 0;
    for (0..256) |byte| {
        while (at < entries.len and entries[at].id[0] <= byte) at += 1;
        emit.be32(@intCast(at));
    }
    for (entries) |*entry| emit.put(&entry.id);
    for (entries) |*entry| emit.be32(entry.crc);
    var large: u32 = 0;
    for (entries) |*entry| {
        if (entry.offset < 0x8000_0000) {
            emit.be32(@intCast(entry.offset));
        } else {
            emit.be32(0x8000_0000 | large);
            large += 1;
        }
    }
    for (entries) |*entry| {
        if (entry.offset < 0x8000_0000) continue;
        emit.be32(@intCast(entry.offset >> 32));
        emit.be32(@truncate(entry.offset));
    }
    emit.put(pack_checksum);
    return emit.finish();
}

/// `entries` sorted by id, in place.
pub fn sort(entries: []Entry) void {
    _git.heapSort(Entry, entries, {}, idBefore);
}

fn idBefore(_: void, a: *const Entry, b: *const Entry) bool {
    return _git.order(&a.id, &b.id) == .less;
}
