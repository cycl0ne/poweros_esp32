// SPDX-License-Identifier: MIT
//! LZ4's block format: one block of at most 64 KiB in, its compressed
//! form out, and back.
//!
//! A block is a run of sequences. Each starts with a token whose top four
//! bits are how many literal bytes follow and whose low four are the
//! length of the match after them, less four; a nibble of 15 continues in
//! bytes of 255 and a last one below it. Then the literals, then the
//! match's distance back as two bytes, least significant first. The last
//! sequence has literals only: the last five bytes of the input are
//! always literals, and no match starts in its last twelve.
//!
//! **compress** is the greedy one-pass compressor: a hash of the next four
//! bytes finds the last place they were seen, in a table the caller owns
//! (`Work`, 8 KiB, so this keeps no state and nothing goes on a small
//! stack). **decompress** trusts nothing: every length is checked against
//! both ends before a byte moves, so a damaged block is an error and never
//! a read or a write outside its buffers.

/// The most bytes a block may hold.
pub const max_block: usize = 64 * 1024;

const hash_bits = 12;
const hash_shift: u5 = 32 - hash_bits;
const min_match: usize = 4;
/// No match starts in a block's last `mf_limit` bytes, and the last
/// `last_literals` are literals.
const mf_limit: usize = 12;
const last_literals: usize = 5;

/// The compressor's table: where each hash of four bytes was last seen.
pub const Work = struct {
    table: [1 << hash_bits]u16 = undefined,
};

/// The most bytes compressing `len` bytes can take: incompressible input
/// grows by a byte in 255 and a few.
pub fn bound(len: usize) usize {
    return len + len / 255 + 16;
}

fn read32(bytes: []const u8, at: usize) u32 {
    return @as(u32, bytes[at]) |
        (@as(u32, bytes[at + 1]) << 8) |
        (@as(u32, bytes[at + 2]) << 16) |
        (@as(u32, bytes[at + 3]) << 24);
}

fn hashAt(bytes: []const u8, at: usize) usize {
    const product = read32(bytes, at) *% 2654435761;
    return product >> hash_shift;
}

/// Where the output is, and whether it ran out of room.
const Out = struct {
    bytes: []u8,
    len: usize = 0,

    fn put(out: *Out, byte: u8) bool {
        if (out.len >= out.bytes.len) return false;
        out.bytes[out.len] = byte;
        out.len += 1;
        return true;
    }

    fn putLength(out: *Out, length: usize) bool {
        var rest = length;
        while (rest >= 255) : (rest -= 255) {
            if (!out.put(255)) return false;
        }
        return out.put(@intCast(rest));
    }

    fn putBytes(out: *Out, from: []const u8) bool {
        if (from.len > out.bytes.len - out.len) return false;
        @memcpy(out.bytes[out.len..][0..from.len], from);
        out.len += from.len;
        return true;
    }
};

/// One sequence: `literals`, then a match of `match_len` bytes from
/// `distance` back (none when `match_len` is 0, the block's last).
fn sequence(out: *Out, literals: []const u8, distance: usize, match_len: usize) bool {
    const lit_nibble: u8 = if (literals.len >= 15) 15 else @intCast(literals.len);
    var match_nibble: u8 = 0;
    if (match_len != 0) {
        const extra = match_len - min_match;
        match_nibble = if (extra >= 15) 15 else @intCast(extra);
    }
    if (!out.put((lit_nibble << 4) | match_nibble)) return false;
    if (lit_nibble == 15 and !out.putLength(literals.len - 15)) return false;
    if (!out.putBytes(literals)) return false;
    if (match_len == 0) return true;
    if (!out.put(@intCast(distance & 0xFF))) return false;
    if (!out.put(@intCast(distance >> 8))) return false;
    if (match_nibble == 15 and !out.putLength(match_len - min_match - 15)) return false;
    return true;
}

/// `src` (at most `max_block` bytes) compressed into `dst`: the bytes it
/// took, or null when they did not fit - which the caller takes to mean
/// the block is to be stored as it is.
pub fn compress(src: []const u8, dst: []u8, work: *Work) ?usize {
    if (src.len > max_block) return null;
    var out: Out = .{ .bytes = dst };
    if (src.len < mf_limit + 1) {
        if (!sequence(&out, src, 0, 0)) return null;
        return out.len;
    }
    @memset(&work.table, 0);
    const limit = src.len - mf_limit;
    const match_end = src.len - last_literals;
    var anchor: usize = 0;
    var at: usize = 1;
    work.table[hashAt(src, 0)] = 0;
    while (at < limit) {
        const slot = hashAt(src, at);
        var from: usize = work.table[slot];
        work.table[slot] = @intCast(at);
        if (from >= at or at - from > 0xFFFF or read32(src, from) != read32(src, at)) {
            at += 1;
            continue;
        }
        // Back over what matches before, as far as the literals go.
        var start = at;
        while (start > anchor and from > 0 and src[start - 1] == src[from - 1]) {
            start -= 1;
            from -= 1;
        }
        var len: usize = min_match + (at - start);
        while (start + len < match_end and src[from + len] == src[start + len]) len += 1;
        if (!sequence(&out, src[anchor..start], start - from, len)) return null;
        at = start + len;
        anchor = at;
        if (at >= limit) break;
        // What was just passed over, so the next match can find it.
        work.table[hashAt(src, at - 2)] = @intCast(at - 2);
    }
    if (!sequence(&out, src[anchor..], 0, 0)) return null;
    return out.len;
}

/// A compressed block decoded into `dst`: the bytes it gave, or null for
/// a block that is damaged or whose output does not fit `dst`.
pub fn decompress(src: []const u8, dst: []u8) ?usize {
    var in: usize = 0;
    var len: usize = 0;
    while (true) {
        if (in >= src.len) return null;
        const token = src[in];
        in += 1;
        var literals: usize = token >> 4;
        if (literals == 15) {
            while (true) {
                if (in >= src.len) return null;
                const more = src[in];
                in += 1;
                literals += more;
                if (literals > dst.len) return null;
                if (more != 255) break;
            }
        }
        if (literals > src.len - in or literals > dst.len - len) return null;
        @memcpy(dst[len..][0..literals], src[in..][0..literals]);
        in += literals;
        len += literals;
        // The block ends after a sequence's literals, and only there.
        if (in == src.len) return len;
        if (src.len - in < 2) return null;
        const distance: usize = @as(usize, src[in]) | (@as(usize, src[in + 1]) << 8);
        in += 2;
        if (distance == 0 or distance > len) return null;
        var match: usize = token & 0x0F;
        if (match == 15) {
            while (true) {
                if (in >= src.len) return null;
                const more = src[in];
                in += 1;
                match += more;
                if (match > dst.len) return null;
                if (more != 255) break;
            }
        }
        match += min_match;
        if (match > dst.len - len) return null;
        // Byte by byte: a match may overlap what it copies.
        var from = len - distance;
        const end = len + match;
        while (len < end) : (len += 1) {
            dst[len] = dst[from];
            from += 1;
        }
    }
}
