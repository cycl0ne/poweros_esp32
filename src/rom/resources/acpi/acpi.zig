// SPDX-License-Identifier: MPL-2.0
//! acpi.resource: the firmware's description of the machine in its own
//! bytecode, read - the namespace the DSDT and the SSDTs build, made at
//! cold start and kept for as long as the system runs.
//!
//! **What it is made of.** `tables/` finds the tables in the order they
//! are loaded; `aml/` reads the bytecode - the reader of its encodings
//! (`_aml.zig`), every opcode's shape, so that a term can be stepped over
//! whole (`opcodes.zig`), and the loader, which makes each name a table
//! defines (`load.zig`); `namespace/` is the tree of names, their paths
//! and the rules a name is looked up by, with the two calls a program
//! makes (`findacpinode.zig`, `nextacpidevice.zig`); `object/` what a
//! name holds. Code at a table's own level, and the methods, are kept and
//! not yet run.
//!
//! **Where it runs.** `machine/` is what the interpreter asks of what it
//! runs in - memory, the log, the lock - as a table of calls the base
//! points at. The resource's table is exec's; tools/acpicheck gives the
//! same code its own and loads a folder of saved tables on the host, so
//! what is proved there is the resource's code.
//!
//! The jump table is acpi_lvo.zig, the ROM tag and init acpi_init.zig,
//! the base acpi_base.zig. This file is the module's root: the names the
//! kernel and the tool reach it by. It imports the SDK alone, so that the
//! tool can build it; the tests that need the ROM's exec are in
//! tests.zig.

const acpi_base = @import("acpi_base.zig");
const acpi_init = @import("acpi_init.zig");

// The tag is an export in .resident, found there by its address; this
// keeps it in whatever is built from acpi.resource.
comptime {
    _ = &acpi_init.acpi_resource_tag;
}

/// The resource's base.
pub const AcpiBase = acpi_base.AcpiBase;
pub const Loaded = acpi_base.Loaded;
/// What the resource is on exec's list as.
pub const RESOURCE_NAME = acpi_init.RESOURCE_NAME;
/// The ROM tag.
pub const acpi_resource_tag = acpi_init.acpi_resource_tag;

/// The interpreter's parts, for tools/acpicheck.
pub const machine = @import("machine/_machine.zig");
pub const namespace = @import("namespace/_namespace.zig");
pub const object = @import("object/_object.zig");
pub const load = @import("aml/load.zig");
pub const FindAcpiNode = @import("namespace/findacpinode.zig").FindAcpiNode;
pub const NextAcpiDevice = @import("namespace/nextacpidevice.zig").NextAcpiDevice;
