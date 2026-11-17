// SPDX-License-Identifier: MPL-2.0
//! HdmiAudioClock: The numbers a monitor rebuilds a link's sample clock
//! from.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;

/// Works out N and CTS for a link's sound: the two numbers a monitor
/// rebuilds the sample clock from.
///
/// SYNOPSIS:
/// ```zig
/// fn HdmiAudioClock(_: *RtgBase, pixel_clock_hz: u32, sample_rate: u32, n: *u32, cts: *u32) bool
/// ```
///
/// SINCE: 1.33. LVO -324.
///
/// INPUTS:
/// - `pixel_clock_hz` - the link's clock: the mode's pixel clock, with
///   eight bits a colour.
/// - `sample_rate` - samples a second.
/// - `n` - where N goes.
/// - `cts` - where CTS goes.
///
/// RESULT:
/// True, and both written. False for a clock or a rate of 0: nothing is
/// written.
///
/// BEHAVIOR:
/// A link carries no sample clock: the monitor makes one from the link's
/// own, by two numbers sent with the sound, so that 128 times the sample
/// rate is the link's clock times N over CTS. N is the rate's own, as
/// HDMI names it: 4096 for 32000 Hz, 6272 for 44100, 6144 for 48000,
/// and as many times that for a rate that is a multiple of one of them;
/// for any other rate, 128 times the rate over 1000. CTS is the link's
/// clock times N over 128 times the rate, rounded down - with 6144 at
/// 48000 Hz, the clock in kilohertz.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: yes.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BuildAviInfoFrame`
///
/// EXAMPLES:
/// ```zig
/// var n: u32 = 0;
/// var cts: u32 = 0;
/// if (!rb.HdmiAudioClock(timings.pixel_clock_hz, 48_000, &n, &cts)) return;
/// ```
pub fn HdmiAudioClock(_: *RtgBase, pixel_clock_hz: u32, sample_rate: u32, n: *u32, cts: *u32) bool {
    if (pixel_clock_hz == 0 or sample_rate == 0) return false;
    const number: u64 = if (sample_rate % 48_000 == 0)
        6144 * @as(u64, sample_rate / 48_000)
    else if (sample_rate % 44_100 == 0)
        6272 * @as(u64, sample_rate / 44_100)
    else if (sample_rate % 32_000 == 0)
        4096 * @as(u64, sample_rate / 32_000)
    else
        128 * @as(u64, sample_rate) / 1000;
    if (number == 0) return false;
    n.* = @intCast(number);
    cts.* = @intCast(@as(u64, pixel_clock_hz) * number / (128 * @as(u64, sample_rate)));
    return true;
}
