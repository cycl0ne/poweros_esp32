// SPDX-License-Identifier: MPL-2.0
//! ramimage <in.bin> <out.bin>: the part of an ESP image that the chip's
//! ROM loads, cut from one esptool made with --ram-only-header.
//!
//! Such an image is its header (24 bytes), the RAM segments its header
//! counts - each an address, a length and the bytes - and the checksum,
//! which ends a 16-byte block; the other segments follow, hidden from the
//! ROM. The ESP32-P4's kernel keeps its code and constants in those other
//! segments but writes them to flash on their own, at the offset they are
//! linked for (src/arch/esp32p4/kernel.ld): what goes where the ROM loads
//! from is the part up to the checksum, and after it the SHA-256 digest of
//! that part, which the ROM checks the image against - the header says it
//! is there (byte 23).

const std = @import("std");

const image_magic = 0xE9;
const header_size = 24;
const segment_header_size = 8;
/// The extended header's "hash appended" byte.
const hash_appended = 23;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: ramimage <in.bin> <out.bin>\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    const image = try cwd.readFileAlloc(io, args[1], arena, .limited(64 * 1024 * 1024));
    if (image.len < header_size or image[0] != image_magic) return fail("{s} is not an ESP image", .{args[1]});
    var offset: usize = header_size;
    var segments = image[1];
    while (segments > 0) : (segments -= 1) {
        if (offset + segment_header_size > image.len) return fail("{s} ends inside a segment's header", .{args[1]});
        const length = std.mem.readInt(u32, image[offset + 4 ..][0..4], .little);
        offset += segment_header_size + length;
    }
    // The checksum ends the 16-byte block the segments end in.
    const end = (offset | 15) + 1;
    if (end > image.len) return fail("{s} ends before its checksum", .{args[1]});
    const sha256 = std.crypto.hash.sha2.Sha256;
    const out = try arena.alloc(u8, end + sha256.digest_length);
    @memcpy(out[0..end], image[0..end]);
    out[hash_appended] = 1;
    sha256.hash(out[0..end], out[end..][0..sha256.digest_length], .{});
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = out });
}

fn fail(comptime format: []const u8, args: anytype) error{Invalid} {
    std.debug.print("ramimage: " ++ format ++ "\n", args);
    return error.Invalid;
}
