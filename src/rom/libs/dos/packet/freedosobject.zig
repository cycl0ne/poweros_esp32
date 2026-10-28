// SPDX-License-Identifier: MPL-2.0
//! FreeDosObject: frees an object AllocDosObject made.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _request = @import("../file/_request.zig");

/// Frees an object AllocDosObject made.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeDosObject(db: *DosBase, obj_type: u32, ptr: ?*anyopaque) void
/// ```
///
/// SINCE: 1.0. LVO -44.
///
/// INPUTS:
/// - `obj_type` - the type it was made as.
/// - `ptr` - the object; null does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The object's block is freed. Nothing it points to is: a FileHandle's
/// buffer, a CLI's streams and an RDArgs' memory are their owners' to
/// free first (Close, FreeArgs). An unknown type does nothing.
///
/// A DosRequest still out is waited for first - its handler has its
/// packet - and the port dos made for it is deleted; a port
/// `ADO_ReplyPort` named is left to its owner.
///
/// CONTEXT:
/// - Waits: only for a DosRequest still out.
/// - Interrupts: not safe; it frees memory.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The object is gone; `ptr` must not be used again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocDosObject`
///
/// EXAMPLES:
/// ```zig
/// dos_lib.FreeDosObject(dos.DOS_FIB, fib);
/// ```
pub fn FreeDosObject(db: *DosBase, obj_type: u32, ptr: ?*anyopaque) void {
    const sys = db.sys_base;
    const object = ptr orelse return;
    switch (obj_type) {
        dos.DOS_STDPKT, dos.DOS_FILEHANDLE, dos.DOS_FIB, dos.DOS_EXALLCONTROL, dos.DOS_CLI, dos.DOS_RDARGS => sys.FreeVec(object),
        dos.DOS_REQUEST => {
            const req: *dos.DosRequest = @ptrCast(@alignCast(object));
            _ = _request.take(db, req, true);
            if (req.own_port) sys.DeleteMsgPort(req.port);
            sys.FreeVec(req);
        },
        else => {},
    }
}
