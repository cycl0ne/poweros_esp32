// SPDX-License-Identifier: MIT
//! An exFAT volume written by another implementation, for the host tests:
//! what this handler reads has to be what the rest of the world writes.
//!
//! `tests/exfat_kernel.bin` holds the blocks of a 16 MiB volume that are
//! not all zeroes, each without its trailing zeroes. It was made with
//! exfatprogs 1.4.3 and filled through the Linux kernel's exFAT driver:
//!
//!     truncate -s 16M ex.img
//!     mkfs.exfat -c 4K -L POWEROS ex.img
//!     (loop-mounted) hello.txt "Hello, PowerOS!\n" dated 2020-05-06 07:08:10,
//!     Café.txt, 日本.txt, "€ Rechnung.pdf", a 158-character name,
//!     empty.dat (no clusters), big.bin (20000 bytes, (i*7+3) & 255),
//!     frag.bin (4096 x 0xA1, 4096 x 0xA2, 100 x 0xA3 - broken up by
//!     spacer.bin, 4096 x 0x5B, written between its first cluster and
//!     the rest), "Sub Dir/inner.txt", "Sub Dir/Deeper/Note.txt",
//!     Many/entry_01.txt .. entry_60.txt (so Many is two clusters),
//!     deleted.txt made and removed, readonly.txt (chmod a-w)
//!     fsck.exfat -n ex.img  ->  clean, directories 4, files 72
//!
//! The file is: the volume's size in blocks and how many blocks follow
//! (u32 each), then per block its number (u32), its length (u16) and its
//! bytes.

const std = @import("std");
const TestMedia = @import("../testmedia.zig").TestMedia;

const image = @embedFile("../tests/exfat_kernel.bin");

/// The volume's size in blocks.
pub fn blocks() u32 {
    return std.mem.readInt(u32, image[0..4], .little);
}

/// The volume laid down on `media` from block `first` on.
pub fn load(media: *TestMedia, first: u64) !void {
    const count = std.mem.readInt(u32, image[4..8], .little);
    var at: usize = 8;
    for (0..count) |_| {
        const lba = std.mem.readInt(u32, image[at..][0..4], .little);
        const len = std.mem.readInt(u16, image[at + 4 ..][0..2], .little);
        try media.place(first + lba, image[at + 6 ..][0..len]);
        at += 6 + len;
    }
}

/// What the fixture's boot sector says, for the tests to compare against.
pub const heap_offset: u32 = 4096;
pub const fat_offset: u32 = 2048;
pub const fat_length: u32 = 30;
pub const cluster_count: u32 = 3584;
pub const root_cluster: u32 = 5;
pub const serial: u32 = 0xEAFE_F4E7;
pub const sectors_per_cluster: u32 = 8;
