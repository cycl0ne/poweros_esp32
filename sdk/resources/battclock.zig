// SPDX-License-Identifier: MIT
//! battclock.resource: the clock that keeps the date while the system is
//! off or restarting. Get its base with OpenResource(BATTCLOCKNAME); its
//! functions are in sdk/interface/battclock.zig. The date is seconds since
//! 1 January 1978, as timer.device's system time counts them;
//! utility.library's Amiga2Date and Date2Amiga turn them into a date and
//! back.
//!
//! The clock is the board's clock chip (PARTKIND_RTC) when it lists one,
//! and otherwise the chip's own RTC timer, which keeps counting through a
//! reset but not through a power cut. At its start the resource sets the
//! system time from the clock; `C:SetClock SAVE` writes the system time
//! back to it.

/// The resource's name, for OpenResource.
pub const BATTCLOCKNAME = "battclock.resource";

/// The resource's base, with its functions.
pub const BattClockBase = @import("../interface/battclock.zig").BattClockBase;
