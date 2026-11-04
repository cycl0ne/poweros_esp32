// SPDX-License-Identifier: MIT
//! power.resource: the machine's own power - what can be done about it,
//! turning it off, and who is told when its power button is pressed.
//!
//! What a machine can do is not the same everywhere, so it says so:
//! PowerAbilities answers POWERF_OFF where the machine can turn itself
//! off and POWERF_BUTTON where it has a power button that reports being
//! pressed. A machine that can do neither still has the resource, and
//! answers that it can do neither.
//!
//! **The button.** Pressing it is a request, not a switch: the machine
//! goes on running until something turns it off. Where no program has
//! asked to hear about it, the resource does the plain thing itself - the
//! drives are stopped so that what they hold is written out, and the
//! machine is turned off - which is what a press means on a machine
//! nobody is watching. A program that asks with AddPowerNotify takes that
//! over: the resource then only tells it, and turning the machine off is
//! that program's to do, after asking whoever is sitting in front of it.
//!
//! Get its base with OpenResource(POWERNAME); its functions are in
//! sdk/interface/power.zig.

/// The resource's name, for OpenResource.
pub const POWERNAME = "power.resource";

/// The machine can turn itself off (PowerOff).
pub const POWERF_OFF: u32 = 1 << 0;
/// The machine has a power button, and says when it is pressed.
pub const POWERF_BUTTON: u32 = 1 << 1;

/// A program told when the button is pressed (AddPowerNotify): the
/// resource's, given back with RemPowerNotify.
pub const PowerNotify = opaque {};

pub const PowerBase = @import("../interface/power.zig").PowerBase;
