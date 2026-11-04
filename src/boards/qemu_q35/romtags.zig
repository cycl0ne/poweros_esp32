// SPDX-License-Identifier: MPL-2.0
//! The ROM tags QEMU's q35 machine carries beyond the ones every image
//! has: none yet. The machine reaches its shell on its console, its timer
//! and the disk image in RAM, which the image has in any case; its screen
//! wants a driver kind of its own and its disk wants PCI, and those are
//! the next items of the list in `todo/port_x86_64/`.

pub const modules = .{};
