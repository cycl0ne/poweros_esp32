// SPDX-License-Identifier: MPL-2.0
//! battmem.resource's base: where its bits are kept, and the semaphore
//! that hands them to one task at a time.

const sdk = @import("sdk");
const exec = sdk.exec;
const battmem = sdk.resources.battmem;
const ExecBase = sdk.interface.exec.ExecBase;

/// What the memory holds: the bits, with a magic number and a check sum
/// over both, since after a power-on RTC memory holds whatever it holds.
pub const Store = extern struct {
    magic: u32,
    checksum: u32,
    bytes: [battmem.BATTMEM_BITS / 8]u8,
};

pub const BattMemBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// Where the bits are: the chip's memory that a reset leaves alone,
    /// or `own` on a chip without it.
    store: *Store,
    own: Store,
    /// Held for each call, and by ObtainBattSemaphore for several.
    lock: exec.SignalSemaphore,
};
