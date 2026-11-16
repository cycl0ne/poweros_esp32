// SPDX-License-Identifier: MPL-2.0
//! A mode's timings, read the way the HDMI ports' registers take them.
//!
//! The library hands a port the timings of the mode it is to bring up
//! (`rtg.RtgTimings`): the pixel clock in Hertz, the picture, and on each
//! side of it the porch before the sync, the sync and the porch after it.
//! The ports' registers want totals, a clock in kilohertz and each sync
//! pulse's polarity as a bit; these are those.

const sdk = @import("sdk");
const rtg = sdk.rtg;

/// A whole line, in pixel clocks: the picture and its blanking.
pub fn htotal(mode: *const rtg.RtgTimings) u32 {
    return mode.h_active + mode.h_front + mode.h_sync + mode.h_back;
}

/// A whole frame, in lines.
pub fn vtotal(mode: *const rtg.RtgTimings) u32 {
    return mode.v_active + mode.v_front + mode.v_sync + mode.v_back;
}

/// The pixel clock in kilohertz.
pub fn khz(mode: *const rtg.RtgTimings) u32 {
    return mode.pixel_clock_hz / 1000;
}

/// Whether the horizontal sync pulse is high.
pub fn hsyncHigh(mode: *const rtg.RtgTimings) bool {
    return mode.flags & rtg.modes.RTGTM_HSYNC_HIGH != 0;
}

/// Whether the vertical sync pulse is high.
pub fn vsyncHigh(mode: *const rtg.RtgTimings) bool {
    return mode.flags & rtg.modes.RTGTM_VSYNC_HIGH != 0;
}
