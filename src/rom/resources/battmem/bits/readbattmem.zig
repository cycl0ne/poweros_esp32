// SPDX-License-Identifier: MPL-2.0
//! ReadBattMem: bits of the memory into a buffer.

const sdk = @import("sdk");
const battmem = sdk.resources.battmem;
const _bits = @import("_bits.zig");
const BattMemBase = @import("../battmem_base.zig").BattMemBase;

/// `length` bits from bit `offset` on, into `buffer`.
///
/// SYNOPSIS:
/// ```zig
/// fn ReadBattMem(mb: *BattMemBase, buffer: [*]u8, offset: u32, length: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -12.
///
/// INPUTS:
/// - `buffer` - where the bits go: (length + 7) / 8 bytes.
/// - `offset` - the first bit, from 0 (sdk.resources.battmembits names
///   which bits hold what).
/// - `length` - how many bits.
///
/// RESULT:
/// 0; BATTMEMERR_RANGE when the bits run past BATTMEM_BITS, and then
/// `buffer` is not touched.
///
/// BEHAVIOR:
/// Bit `offset` goes to bit 0 of the buffer's first byte, the next to
/// bit 1, and so on into the next byte: a setting of 64 bits read into
/// a u64 is its number on every chip PowerOS runs on. The bits of the
/// last byte past `length` stay as they were. Bits nobody wrote are 0.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the bits.
/// - Interrupts: no.
/// - Locks: the resource's semaphore, for the call.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// It sends no packet and reads no file, so a file system handler may
/// ask it for a setting it cannot read from a file on its own volume.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `WriteBattMem`, `ObtainBattSemaphore`, sdk.resources.battmembits
///
/// EXAMPLES:
/// ```zig
/// var bits: u64 = 0;
/// if (mb.ReadBattMem(@ptrCast(&bits), battmembits.BATTMEM_ZONE_ADDR, battmembits.BATTMEM_ZONE_LEN) == 0) {
///     const zone = dos.timezone.unpack(bits) orelse .{};
/// }
/// ```
pub fn ReadBattMem(mb: *BattMemBase, buffer: [*]u8, offset: u32, length: u32) u32 {
    if (!_bits.within(offset, length)) return battmem.BATTMEMERR_RANGE;
    const sys = mb.sys_base;
    sys.ObtainSemaphore(&mb.lock);
    defer sys.ReleaseSemaphore(&mb.lock);
    _bits.copyBits(buffer, 0, &mb.store.bytes, offset, length);
    return 0;
}
