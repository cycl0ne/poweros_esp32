// SPDX-License-Identifier: MPL-2.0
//! The last words: the end of the system log, kept over the reset that
//! follows a dead end.
//!
//! RTC slow memory - 8 KiB at 0x5000_0000 - is not touched by a software
//! reset, only by a power-on (and by the reset button, which is one). A
//! dead end copies the log's last 4 KiB there, from the start of a line,
//! before it restarts the machine; the next boot finds them there and puts
//! them at the head of its own log, marked, ahead of its first line, so
//! `C:Log` shows what the boot before ended with. They are taken once:
//! the block is cleared as it is read.
//!
//! The block carries a magic number, its length and a checksum over both
//! and the bytes, since after a power-on the memory holds whatever it
//! holds: a block that does not add up is not words.

const _log = @import("../../rom/libs/exec/log/_log.zig");

/// RTC slow memory's first byte: nothing else of this system uses it.
const rtc_slow_memory = 0x5000_0000;

/// How much of the log is kept.
const capacity = 4096 - 12;

const magic_words: u32 = 0x4C57_4F52; // "LWOR"

const LastWords = extern struct {
    magic: u32,
    length: u32,
    checksum: u32,
    bytes: [capacity]u8,
};

fn block() *LastWords {
    return @ptrFromInt(rtc_slow_memory);
}

/// FNV-1a over the magic number, the length and the bytes - not the
/// checksum itself, and nothing past the length.
fn checksumOf(words: *const LastWords) u32 {
    const head: [8]u8 = @bitCast([2]u32{ words.magic, words.length });
    var hash: u32 = 0x811C_9DC5;
    for (head) |byte| hash = (hash ^ byte) *% 0x0100_0193;
    for (words.bytes[0..words.length]) |byte| hash = (hash ^ byte) *% 0x0100_0193;
    return hash;
}

/// The log's end into RTC memory, for the next boot. A dead end calls it
/// with interrupts off, once everything it prints is printed.
pub fn save() void {
    const words = block();
    const kept = _log.tail(&words.bytes);
    // `tail` leaves the text from the start of a line, which may be past
    // the block's start: moved down to it, each byte from further on.
    for (kept, 0..) |byte, at| words.bytes[at] = byte;
    words.length = @intCast(kept.len);
    words.magic = magic_words;
    words.checksum = checksumOf(words);
}

/// Whether the boot before left last words, which `restore` put into the
/// log.
pub var restored = false;

/// The boot before's last words, if it left any, at the head of the log -
/// between two marking lines, and without going out on the port: they
/// were printed once already. The kernel calls it once the ring is set,
/// before the first line of its own.
pub fn restore() void {
    const words = block();
    if (words.magic != magic_words or words.length > capacity) return;
    if (words.checksum != checksumOf(words)) return;
    keepText("---- the last words of the boot before ----\n");
    for (words.bytes[0..words.length]) |byte| _log.keep(byte);
    if (words.length > 0 and words.bytes[words.length - 1] != '\n') _log.keep('\n');
    keepText("---- the end of them ----\n");
    words.magic = 0;
    restored = true;
}

fn keepText(text: []const u8) void {
    for (text) |byte| _log.keep(byte);
}

comptime {
    if (@sizeOf(LastWords) > 8 * 1024) @compileError("the last words do not fit RTC slow memory");
}
