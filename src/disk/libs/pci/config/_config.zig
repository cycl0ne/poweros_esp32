// SPDX-License-Identifier: MIT
//! What ReadPCIConfig and WritePCIConfig take: 1, 2 or 4 bytes, aligned
//! to their size, within a function's 4 KiB.

/// Whether `size` bytes at `offset` are a register access.
pub fn sound(offset: u32, size: u32) bool {
    if (size != 1 and size != 2 and size != 4) return false;
    return offset < 4096 and offset % size == 0;
}
