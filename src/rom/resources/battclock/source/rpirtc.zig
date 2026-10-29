// SPDX-License-Identifier: MPL-2.0
//! The Raspberry Pi's RTC as the clock - the Compute Module 5's and the
//! Pi 5's: a count of seconds since 1 January 1970 in the board's power
//! chip, which counts for as long as the board has power, and through a
//! power cut on a cell at the BAT connector. The ARM does not reach it:
//! the VideoCore's firmware reads and sets it, asked through its mailbox
//! (CHIP_RPI_RTC, `sdk.hardware.videocore`), as Linux's rtc-rpi asks. A
//! power-on without a cell starts the count again from 0, which is
//! before 1978: no date.
//!
//! The RTC's tags read (0x00030087) and set (0x00038087) one of its
//! registers, the value being the register's number and its contents:
//! register 0 is the count.

const sdk = @import("sdk");
const videocore = sdk.hardware.videocore;
const ExecBase = sdk.interface.exec.ExecBase;

pub const TAG_GET_RTC_REG: u32 = 0x0003_0087;
pub const TAG_SET_RTC_REG: u32 = 0x0003_8087;
const RTC_TIME: u32 = 0;

/// The buffer the messages are written in, as the mailbox has it.
pub const buffer_bytes = videocore.buffer_bytes;
pub const Buffer = videocore.Buffer;
pub const bufferIn = videocore.bufferIn;

/// The seconds from 1 January 1970 to 1 January 1978.
pub const unix_1978: u32 = 252_460_800;

/// The seconds since 1978 a count since 1970 is; null before 1978.
pub fn secondsOf(count: u32) ?u32 {
    return if (count < unix_1978) null else count - unix_1978;
}

/// The count since 1970 the seconds since 1978 are: the count's last
/// second past it, in 2106.
pub fn countOf(seconds: u32) u32 {
    return seconds +| unix_1978;
}

/// The count, seconds since 1970; null when the firmware does not answer.
pub fn read(sys: *ExecBase, mailbox: usize, buffer: *align(buffer_bytes) Buffer) ?u32 {
    var value = [2]u32{ RTC_TIME, 0 };
    if (!videocore.call(sys, mailbox, buffer, TAG_GET_RTC_REG, &value)) return null;
    return value[1];
}

/// The count set to `count`, seconds since 1970: whether the firmware
/// took it.
pub fn write(sys: *ExecBase, mailbox: usize, buffer: *align(buffer_bytes) Buffer, count: u32) bool {
    var value = [2]u32{ RTC_TIME, count };
    return videocore.call(sys, mailbox, buffer, TAG_SET_RTC_REG, &value);
}
