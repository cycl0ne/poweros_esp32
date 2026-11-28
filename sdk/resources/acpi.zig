// SPDX-License-Identifier: MIT
//! acpi.resource: the firmware's description of the machine in its own
//! bytecode - the namespace its DSDT and SSDTs build, with the machine's
//! devices and what the firmware says about each - read at cold start.
//!
//! The namespace is a tree of names of four characters: `\` is its root,
//! `\_SB` the scope of the devices on the system bus, `\_SB.PCI0` one of
//! them and `\_SB.PCI0._HID` what that one is. FindAcpiNode finds a name
//! by its path; NextAcpiDevice goes through the devices, all of them or
//! those of one identity.
//!
//! The resource is the firmware's run-time half and nothing more. What
//! the namespace says about the machine's hardware reaches the rest of
//! the system as board parts (expansion.library), and what the firmware
//! does for the machine is done behind the system's own services
//! (power.resource, thermal.resource, platform.resource): a driver finds
//! its hardware there, never here.
//!
//! Get its base with OpenResource(ACPINAME); its functions are in
//! sdk/interface/acpi.zig.

/// The resource's name, for OpenResource.
pub const ACPINAME = "acpi.resource";

/// A name in the namespace (FindAcpiNode, NextAcpiDevice): the
/// resource's, good for as long as the system runs.
pub const AcpiNode = opaque {};

pub const AcpiBase = @import("../interface/acpi.zig").AcpiBase;
