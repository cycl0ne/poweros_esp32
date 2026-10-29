// SPDX-License-Identifier: MPL-2.0
//! The Raspberry Pi's RTC as the clock - the Compute Module 5's and the
//! Pi 5's: a count of seconds since 1 January 1970 in the board's power
//! chip, which counts for as long as the board has power, and through a
//! power cut on a cell at the BAT connector. The ARM does not reach it:
//! the VideoCore's firmware reads and sets it, asked through its mailbox
//! (CHIP_RPI_RTC), as Linux's rtc-rpi asks. A power-on without a cell
//! starts the count again from 0, which is before 1978: no date.
//!
//! **The mailbox** - the BCM2835's, still on the BCM2712: a message is a
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
//! to end them. The RTC's tags read (0x00030087) and set (0x00038087) one
//! of its registers, the value being the register's number and its
//! contents: register 0 is the count.
//!
//! The firmware reads the buffer from memory and writes its answer
//! there, past the ARM's caches: the buffer is written back before the
//! message goes and invalidated before the answer is read. It is where
//! the firmware's DMA reaches - Linux keeps its buffers for it in the
//! first GiB, and the board's DMA limit says as much (MEMF_DMA) - at the
//! address the ARM has it at, as the device tree maps the firmware's
//! DMA one to one.

const sdk = @import("sdk");
const exec = sdk.exec;
const reg = sdk.hardware.mmio.reg;
const systimer = sdk.hardware.systimer;
const ExecBase = sdk.interface.exec.ExecBase;

const MAIL0_READ: usize = 0x00;
const MAIL0_STATUS: usize = 0x18;
const MAIL1_WRITE: usize = 0x20;
const MAIL1_STATUS: usize = 0x38;
const STATUS_FULL: u32 = 1 << 31;
const STATUS_EMPTY: u32 = 1 << 30;
const CHANNEL_PROPERTY: u32 = 8;

const TAG_GET_RTC_REG: u32 = 0x0003_0087;
const TAG_SET_RTC_REG: u32 = 0x0003_8087;
const RTC_TIME: u32 = 0;

const CODE_REQUEST: u32 = 0;
const CODE_SUCCESS: u32 = 0x8000_0000;
const TAG_ANSWERED: u32 = 1 << 31;

/// A message: the buffer's two words, one tag of three with its value of
/// two, and the end.
pub const message_words = 8;
const message_bytes = message_words * 4;

/// The buffer the messages are written in: a cache line of its own.
pub const buffer_bytes = 64;
pub const Buffer = [buffer_bytes / 4]u32;

/// How long the firmware is given to answer.
const answer_us: u64 = 100_000;

/// The seconds from 1 January 1970 to 1 January 1978.
pub const unix_1978: u32 = 252_460_800;

/// The message asking for tag `tag` with RTC register `register` and
/// `value`.
pub fn message(tag: u32, register: u32, value: u32) [message_words]u32 {
    return .{ message_bytes, CODE_REQUEST, tag, 8, 0, register, value, 0 };
}

/// The register's contents in an answered message; null when the
/// firmware did not answer it.
pub fn answer(words: *const [message_words]u32) ?u32 {
    if (words[1] != CODE_SUCCESS or words[4] & TAG_ANSWERED == 0) return null;
    return words[6];
}

/// The seconds since 1978 a count since 1970 is; null before 1978.
pub fn secondsOf(count: u32) ?u32 {
    return if (count < unix_1978) null else count - unix_1978;
}

/// The count since 1970 the seconds since 1978 are: the count's last
/// second past it, in 2106.
pub fn countOf(seconds: u32) u32 {
    return seconds +| unix_1978;
}

/// The firmware asked `words` through the mailbox at `mailbox`, in
/// `buffer`: the register's contents it answers, null without an answer
/// in time.
fn call(sys: *ExecBase, mailbox: usize, buffer: *align(buffer_bytes) Buffer, words: [message_words]u32) ?u32 {
    buffer[0..message_words].* = words;
    var length: u32 = buffer_bytes;
    _ = sys.CachePreDMA(buffer, &length, 0);
    const sent: u32 = @as(u32, @intCast(@intFromPtr(buffer))) | CHANNEL_PROPERTY;
    const until = systimer.uptimeUs() + answer_us;
    while (reg(mailbox + MAIL1_STATUS).* & STATUS_FULL != 0) {
        if (systimer.uptimeUs() > until) return null;
    }
    reg(mailbox + MAIL1_WRITE).* = sent;
    while (true) {
        // Another's answer - none is asked for here but this - is passed.
        if (reg(mailbox + MAIL0_STATUS).* & STATUS_EMPTY == 0) {
            if (reg(mailbox + MAIL0_READ).* == sent) break;
            continue;
        }
        if (systimer.uptimeUs() > until) return null;
    }
    sys.CachePostDMA(buffer, &length, 0);
    return answer(buffer[0..message_words]);
}

/// The buffer for the firmware's messages, from `memory`: 128 bytes of
/// MEMF_DMA, which the buffer is aligned in. Null when it is not where a
/// message can name it, below 4 GiB.
pub fn bufferIn(memory: *anyopaque) ?*align(buffer_bytes) Buffer {
    const at = (@intFromPtr(memory) + buffer_bytes - 1) & ~@as(usize, buffer_bytes - 1);
    if (at + buffer_bytes > 1 << 32) return null;
    return @ptrFromInt(at);
}

/// The count, seconds since 1970; null when the firmware does not answer.
pub fn read(sys: *ExecBase, mailbox: usize, buffer: *align(buffer_bytes) Buffer) ?u32 {
    return call(sys, mailbox, buffer, message(TAG_GET_RTC_REG, RTC_TIME, 0));
}

/// The count set to `count`, seconds since 1970: whether the firmware
/// took it.
pub fn write(sys: *ExecBase, mailbox: usize, buffer: *align(buffer_bytes) Buffer, count: u32) bool {
    return call(sys, mailbox, buffer, message(TAG_SET_RTC_REG, RTC_TIME, count)) != null;
}
