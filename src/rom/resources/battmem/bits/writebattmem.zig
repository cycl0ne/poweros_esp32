// SPDX-License-Identifier: MPL-2.0
//! WriteBattMem: bits of a buffer into the memory.

const sdk = @import("sdk");
const battmem = sdk.resources.battmem;
const _bits = @import("_bits.zig");
const BattMemBase = @import("../battmem_base.zig").BattMemBase;

/// `length` bits from `buffer`, to bit `offset` on.
///
/// SYNOPSIS:
/// ```zig
/// fn WriteBattMem(mb: *BattMemBase, buffer: [*]const u8, offset: u32, length: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -16.
///
/// INPUTS:
/// - `buffer` - the bits: (length + 7) / 8 bytes, from its first byte's
///   bit 0 up, as ReadBattMem gives them.
/// - `offset` - the first bit they go to, from 0.
/// - `length` - how many bits.
///
/// RESULT:
/// 0; BATTMEMERR_RANGE when the bits run past BATTMEM_BITS, and then
/// nothing is written.
///
/// BEHAVIOR:
/// The bits around them stay as they are. The memory is written whole,
/// with a check sum: when a reset comes in the middle of it, the next
/// start finds a sum that does not add up and makes every bit 0.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the bits.
/// - Interrupts: no.
/// - Locks: the resource's semaphore, for the call.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands: the bits are copied.
///
/// NOTES:
/// The bits outlive a reset on the ESP32-S3 and the ESP32-P4, not a
/// power-on; on the rv64sbi machines they last until the next start.
/// What should outlive that is kept in a file too, and written here
/// again as the system starts.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReadBattMem`, `ObtainBattSemaphore`, sdk.resources.battmembits,
/// C:SetClock
///
/// EXAMPLES:
/// ```zig
/// const bits = dos.timezone.pack(&zone) orelse return error.NotKept;
/// _ = mb.WriteBattMem(@ptrCast(&bits), battmembits.BATTMEM_ZONE_ADDR, battmembits.BATTMEM_ZONE_LEN);
/// ```
pub fn WriteBattMem(mb: *BattMemBase, buffer: [*]const u8, offset: u32, length: u32) u32 {
    if (!_bits.within(offset, length)) return battmem.BATTMEMERR_RANGE;
    const sys = mb.sys_base;
    sys.ObtainSemaphore(&mb.lock);
    defer sys.ReleaseSemaphore(&mb.lock);
    _bits.write(mb.store, buffer, offset, length);
    return 0;
}
