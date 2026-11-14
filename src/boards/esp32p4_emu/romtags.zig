// SPDX-License-Identifier: MPL-2.0
//! The ROM tags the emulator's image carries beyond the ones every image
//! has: none yet.

const rom = @import("../../rom/modules.zig");

// What every image has, what draws, the ESP32s' own,
// and the drivers of this board's parts.
pub const modules = rom.core ++ rom.screen ++ rom.esp32;
