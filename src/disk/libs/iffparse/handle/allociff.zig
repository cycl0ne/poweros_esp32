// SPDX-License-Identifier: MIT
//! AllocIFF: a handle for one IFF file.

const sdk = @import("sdk");
const exec = sdk.exec;
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const _item = @import("../item/_item.zig");
const IFFParseBase = _base.IFFParseBase;

/// Makes a handle for one IFF file.
///
/// SYNOPSIS:
/// ```zig
/// fn AllocIFF(ib: *IFFParseBase) ?*iffparse.IFFHandle
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// The handle, or null for no memory.
///
/// BEHAVIOR:
/// The handle comes back empty: it has no stream and is not open. Put
/// the stream in `iff.stream`, say what kind it is (`InitIFFasDOS`,
/// `InitIFFasClip` or `InitIFF`), and then open it with `OpenIFF`.
///
/// Only this call makes a handle, because the library keeps more behind
/// it than the three fields a program sees.
///
/// CONTEXT:
/// - Waits: for memory.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The handle is the caller's to give back with `FreeIFF`, after
/// `CloseIFF`. The stream behind it is the caller's throughout: the
/// library never opens or closes a file.
///
/// NOTES:
/// One handle reads or writes one file at a time. A program reading two
/// files at once needs two.
///
/// SEE ALSO:
/// `FreeIFF`, `InitIFFasDOS`, `OpenIFF`
///
/// EXAMPLES:
/// ```zig
/// const iff = ip.AllocIFF() orelse return;
/// defer ip.FreeIFF(iff);
/// ```
pub fn AllocIFF(ib: *IFFParseBase) ?*iffparse.IFFHandle {
    const sys = ib.sys_base;
    const memory = sys.AllocVec(@sizeOf(_base.Handle), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const h: *_base.Handle = @ptrCast(@alignCast(memory));
    h.* = .{ .base = ib };
    h.stack.init();
    h.write_buffers.init();
    // The stack's bottom node, which has no id and is nobody's chunk: it
    // gives the context calls somewhere to look before the walk has
    // entered anything.
    const bottom = _item.allocContextNode(ib) orelse {
        sys.FreeVec(memory);
        return null;
    };
    sys.AddHead(@ptrCast(&h.stack), @ptrCast(&bottom.public.node));
    return &h.public;
}
