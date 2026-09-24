// SPDX-License-Identifier: MIT
//! expander.resource: the board's IO expander, an I2C part whose eight
//! pins hold other parts' lines - a panel's enable and reset, a touch
//! controller's reset, a card's chip select - plus the backlight and an
//! analogue input. Where it answers and which part uses which pin is the
//! board's description (expansion.library): a part's line on the
//! expander is a BoardPin of kind BPIN_EXPANDER.
//!
//! It is a resource because it is one piece of hardware shared by drivers
//! that know nothing of each other: the display wants the backlight and
//! DISP, the touch controller wants its reset line, the SD card wants its
//! chip select. One owner keeps the shadow of what has been written, and a
//! pin change is a read-modify-write of that shadow under a lock, so two
//! drivers cannot undo each other's pins.
//!
//! Get its base with OpenResource(EXPANDERNAME); its functions are in
//! sdk/interface/expander.zig.
//!
//! The part is a register file reached over i2c.device. A write is
//! the register number and the value in one transfer; a read writes the
//! register number, then reads without letting go of the bus.

/// The resource's name, for OpenResource.
pub const EXPANDERNAME = "expander.resource";

/// How many pins it has.
pub const PIN_COUNT: u32 = 8;

/// Backlight brightness, as SetBacklight takes it.
pub const BACKLIGHT_OFF: u32 = 0;
pub const BACKLIGHT_FULL: u32 = 100;
