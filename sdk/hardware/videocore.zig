// SPDX-License-Identifier: MIT
//! The VideoCore's mailbox on the Raspberry Pis' chips - the BCM2835's,
//! still on the BCM2712 - and the property channel through which the ARM
//! asks the VideoCore's firmware for what only it reaches: the RTC
//! (battclock.resource), the display's clocks (rtg-fb). A message is a
//! buffer's address with its channel in the low four bits, written into
//! mailbox 1 when it is not full; the firmware answers on mailbox 0 with
//! the same word once it has written its answer into the buffer.
//!
//!   0x00  MAIL0_READ    the firmware's answers
//!   0x18  MAIL0_STATUS  bit 30: none waiting
//!   0x20  MAIL1_WRITE   the ARM's messages
//!   0x38  MAIL1_STATUS  bit 31: full
//!
//! **The property channel** (8) carries a buffer of words: its length, a
//! code - 0 asking, 0x80000000 answered - then the tags, each its id, the
//! size of its value, a code (bit 31 once answered) and the value; and 0
//! to end them. A message here is one tag, its answer written over its
//! value.
//!
//! The firmware reads the buffer from memory and writes its answer
//! there, past the ARM's caches: the buffer is written back before the
//! message goes and invalidated before the answer is read. It is where
//! the firmware's DMA reaches - Linux keeps its buffers for it in the
//! first GiB, and the board's DMA limit says as much (MEMF_DMA) - at the
//! address the ARM has it at, as the device tree maps the firmware's
//! DMA one to one.
//!
//! **One at a time.** An answer is only the word its message was sent
//! with, so two asking at once could each take the other's: everyone who
//! asks holds one lock, a public semaphore (`lock_name`), while the
//! message is out. The first to ask makes it and it stays for good; on
//! the board that has the mailbox that is battclock.resource at cold
//! start, before any task could ask beside it.

const exec = @import("../libs/exec/exec.zig");
const ExecBase = @import("../interface/exec.zig").ExecBase;
const hardware = @import("hardware.zig");

const MAIL0_READ: usize = 0x00;
const MAIL0_STATUS: usize = 0x18;
const MAIL1_WRITE: usize = 0x20;
const MAIL1_STATUS: usize = 0x38;
const STATUS_FULL: u32 = 1 << 31;
const STATUS_EMPTY: u32 = 1 << 30;
const CHANNEL_PROPERTY: u32 = 8;

const CODE_REQUEST: u32 = 0;
const CODE_SUCCESS: u32 = 0x8000_0000;
const TAG_ANSWERED: u32 = 1 << 31;

/// The buffer the messages are written in: a cache line of its own.
pub const buffer_bytes = 64;
pub const Buffer = [buffer_bytes / 4]u32;
/// The most words a tag's value has here: the buffer less its two words,
/// the tag's three and the end.
pub const value_words = buffer_bytes / 4 - 6;

/// The public semaphore everyone who asks holds.
pub const lock_name = "videocore.mailbox";

/// How long the firmware is given to answer.
const answer_us: u64 = 100_000;

/// The message asking tag `tag` with `value` written into `into`: how
/// many words it is.
pub fn message(into: *Buffer, tag: u32, value: []const u32) usize {
    const words = 6 + value.len;
    into[0] = @intCast(words * 4);
    into[1] = CODE_REQUEST;
    into[2] = tag;
    into[3] = @intCast(value.len * 4);
    into[4] = 0;
    @memcpy(into[5 .. 5 + value.len], value);
    into[5 + value.len] = 0;
    return words;
}

/// The answer to a message of `value.len` words read into `value`: false,
/// and nothing read, when the firmware did not answer it.
pub fn answer(words: *const Buffer, value: []u32) bool {
    if (words[1] != CODE_SUCCESS or words[4] & TAG_ANSWERED == 0) return false;
    @memcpy(value, words[5 .. 5 + value.len]);
    return true;
}

/// The buffer for the firmware's messages, in `memory`: 128 bytes of
/// MEMF_DMA, which the buffer is aligned in. Null when it is not where a
/// message can name it, below 4 GiB.
pub fn bufferIn(memory: *anyopaque) ?*align(buffer_bytes) Buffer {
    const at = (@intFromPtr(memory) + buffer_bytes - 1) & ~@as(usize, buffer_bytes - 1);
    if (at + buffer_bytes > 1 << 32) return null;
    return @ptrFromInt(at);
}

/// The lock, made when nobody has yet; null when there is no memory for
/// it, and the message goes without.
fn lockOf(sys: *ExecBase) ?*exec.SignalSemaphore {
    if (sys.FindSemaphore(lock_name)) |found| return found;
    const memory = sys.AllocMem(@sizeOf(exec.SignalSemaphore), exec.MEMF_SYSTEM | exec.MEMF_CLEAR) orelse return null;
    const made: *exec.SignalSemaphore = @ptrCast(@alignCast(memory));
    made.* = .{};
    made.link.name = lock_name;
    sys.AddSemaphore(made);
    return made;
}

/// The firmware asked tag `tag` with `value` through the mailbox at
/// `mailbox`, in `buffer`, and its answer read back into `value`: false
/// when it did not answer in time.
pub fn call(sys: *ExecBase, mailbox: usize, buffer: *align(buffer_bytes) Buffer, tag: u32, value: []u32) bool {
    const reg = hardware.mmio.reg;
    const systimer = hardware.systimer;
    _ = message(buffer, tag, value);
    const lock = lockOf(sys);
    if (lock) |held| sys.ObtainSemaphore(held);
    defer if (lock) |held| sys.ReleaseSemaphore(held);
    var length: u32 = buffer_bytes;
    _ = sys.CachePreDMA(buffer, &length, 0);
    const sent: u32 = @as(u32, @intCast(@intFromPtr(buffer))) | CHANNEL_PROPERTY;
    const until = systimer.uptimeUs() + answer_us;
    while (reg(mailbox + MAIL1_STATUS).* & STATUS_FULL != 0) {
        if (systimer.uptimeUs() > until) return false;
    }
    reg(mailbox + MAIL1_WRITE).* = sent;
    while (true) {
        // An answer to a message given up on earlier is passed over.
        if (reg(mailbox + MAIL0_STATUS).* & STATUS_EMPTY == 0) {
            if (reg(mailbox + MAIL0_READ).* == sent) break;
            continue;
        }
        if (systimer.uptimeUs() > until) return false;
    }
    sys.CachePostDMA(buffer, &length, 0);
    return answer(buffer, value);
}
