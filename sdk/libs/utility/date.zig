// SPDX-License-Identifier: MIT
//! Dates: seconds since 1 January 1978, 00:00, and struct ClockData.

/// struct ClockData.
pub const ClockData = extern struct {
    /// 0 to 59
    sec: u16 = 0,
    /// 0 to 59
    min: u16 = 0,
    /// 0 to 23
    hour: u16 = 0,
    /// 1 to 31
    mday: u16 = 0,
    /// 1 to 12
    month: u16 = 0,
    /// 1978 to 2114
    year: u16 = 0,
    /// 0 (Sunday) to 6 (Saturday)
    wday: u16 = 0,
};
