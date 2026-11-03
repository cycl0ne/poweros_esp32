// SPDX-License-Identifier: MIT
//! The interrupt sources: the vectors this machine's kernel hands out, and
//! after them the alarms on its timer (systimer.zig).
//!
//! The architecture's own 256 vectors are not the numbering used here. The
//! first 32 are the core's exceptions and are the kernel's
//! (`src/arch/x64uefi/trap.zig`); above them the kernel hands a vector to
//! each source the I/O controller routes, and a driver asks for its source
//! by the number the board or the firmware's tables give it - the line an
//! old part sits on, or the message a PCI function was told to send. So
//! the count here is how many sources the kernel can route at once, not a
//! property of the machine.

/// The first source a driver may be given: above the core's exceptions and
/// the vectors the kernel keeps for itself (the tick, the software
/// interrupt, the poke to another core, and the spurious one the controller
/// sends).
pub const INTB_FIRST = 48;
/// One past the highest source: the architecture's last vector.
pub const INTB_VECTOR_COUNT = 256;
/// The alarms: timer.device's micro timer, and its VBLANK.
pub const INTB_ALARM0 = INTB_VECTOR_COUNT;
pub const INTB_ALARM1 = INTB_VECTOR_COUNT + 1;
pub const INTB_COUNT = INTB_VECTOR_COUNT + 2;
