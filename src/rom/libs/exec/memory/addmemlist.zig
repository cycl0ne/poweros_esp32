// SPDX-License-Identifier: MPL-2.0
//! AddMemList: hands a block of memory to the system - `CreateMemHeader`
//! over it, then onto the memory list by priority.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const MemHeader = sdk.exec.MemHeader;

/// Hands a block of memory to the system, for anyone to allocate from.
///
/// SYNOPSIS:
/// ```zig
/// fn AddMemList(base: *ExecBase, size: usize, attributes: u32, pri: i8,
///     region: *anyopaque, name: ?[*:0]const u8) ?*MemHeader
/// ```
///
/// SINCE: 1.0. LVO -96.
///
/// INPUTS:
/// As `CreateMemHeader`, which this calls: `size` bytes at `region`,
/// `attributes` saying what the memory is, `pri` its place on the list, and
/// `name` for a listing.
///
/// RESULT:
/// The header, now on the system memory list, or null if the block was too
/// small.
///
/// BEHAVIOR:
/// The region is enqueued by priority, and from that moment any `AllocMem`
/// whose requirements it satisfies may take memory from it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It takes Forbid for the memory list.
/// - Forbid: taken here, around the list.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The system holds it from here. There is no call that takes a region
/// back: memory given to exec stays given, because anything already
/// allocated from it would be left pointing into nothing.
///
/// NOTES:
/// The machine's own regions are added at boot from `src/arch/esp32s3/ram.zig`,
/// with internal memory at the higher priority so that `MEMF_ANY` spends
/// external memory first and leaves what interrupts and DMA need.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateMemHeader`, `AllocMem`, `AvailMem`
///
/// EXAMPLES:
/// ```zig
/// _ = sys.AddMemList(size, exec.MEMF_EXTERNAL, -10, base, "external memory");
/// ```
pub fn AddMemList(base: *ExecBase, size: usize, attributes: u32, pri: i8, region: *anyopaque, name: ?[*:0]const u8) ?*MemHeader {
    const sys = base.iface();
    const mh = sys.CreateMemHeader(size, attributes, pri, region, name) orelse return null;
    sys.Forbid();
    defer sys.Permit();
    sys.Enqueue(&base.mem_list, &mh.node);
    return mh;
}
