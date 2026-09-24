// SPDX-License-Identifier: MIT
//! watchdog.resource: the chip's watchdog timer for programs. Get its base
//! with OpenResource(WATCHDOGNAME); its functions are in
//! sdk/interface/watchdog.zig. Whoever arms it feeds it.

/// The resource's name, for OpenResource.
pub const WATCHDOGNAME = "watchdog.resource";

/// ArmWatchdog's actions, when the time is up: reset the whole chip...
pub const WATCHDOG_RESET_SYSTEM: u32 = 3;
/// ...or only the CPU cores.
pub const WATCHDOG_RESET_CPU: u32 = 2;

/// The resource's base, with its functions.
pub const WatchdogBase = @import("../interface/watchdog.zig").WatchdogBase;
