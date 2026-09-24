// SPDX-License-Identifier: MPL-2.0
//! AllocDosObject: allocates one of dos's objects by type.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _packet = @import("_packet.zig");
const initCli = _packet.initCli;
const cli_block_size = _packet.cli_block_size;
const cleared = _packet.cleared;
const DosPacket = dos.DosPacket;
const TagItem = sdk.utility.TagItem;

/// Allocates one of dos's objects by type.
///
/// SYNOPSIS:
/// ```zig
/// fn AllocDosObject(db: *DosBase, obj_type: u32, tags: ?[*]const TagItem) ?*anyopaque
/// ```
///
/// SINCE: 1.0. LVO -40.
///
/// INPUTS:
/// - `obj_type` - what to make: DOS_STDPKT, DOS_FILEHANDLE, DOS_FIB,
///   DOS_EXALLCONTROL, DOS_CLI or DOS_RDARGS.
/// - `tags` - options for the object; none are read yet, so null will
///   do.
///
/// RESULT:
/// The object, ready to use, or null: with ERROR_NO_FREE_STORE when
/// there was no memory, and with IoErr unchanged for a type it doesn't
/// know.
///
/// BEHAVIOR:
/// Each type is made as the area's header lists: cleared, with its
/// defaults, and for a CLI with its name buffers in the same block. A
/// DosPacket's message length is set so it can be sent at once.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not safe; it allocates.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The object is the caller's, to give back with FreeDosObject and the
/// same type.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FreeDosObject`
///
/// EXAMPLES:
/// ```zig
/// const fib: *dos.FileInfoBlock = @ptrCast(@alignCast(dos_lib.AllocDosObject(dos.DOS_FIB, null) orelse return null));
/// defer dos_lib.FreeDosObject(dos.DOS_FIB, fib);
/// ```
pub fn AllocDosObject(db: *DosBase, obj_type: u32, tags: ?[*]const TagItem) ?*anyopaque {
    const dos_lib = db.iface();
    const sys = db.sys_base;
    _ = tags; // no type reads its options yet
    switch (obj_type) {
        dos.DOS_STDPKT => {
            const block = sys.AllocVec(@sizeOf(DosPacket), exec.MEMF_CLEAR) orelse {
                _ = dos_lib.SetIoErr(dos.ERROR_NO_FREE_STORE);
                return null;
            };
            const pkt: *DosPacket = @ptrCast(@alignCast(block));
            pkt.msg.length = @sizeOf(DosPacket);
            return pkt;
        },
        dos.DOS_FILEHANDLE => {
            const fh: *dos.FileHandle = @ptrCast(@alignCast(cleared(db, @sizeOf(dos.FileHandle)) orelse return null));
            fh.* = .{};
            return fh;
        },
        dos.DOS_FIB => return cleared(db, @sizeOf(dos.FileInfoBlock)),
        dos.DOS_EXALLCONTROL => return cleared(db, @sizeOf(dos.ExAllControl)),
        dos.DOS_CLI => {
            const block = cleared(db, cli_block_size) orelse return null;
            return initCli(@ptrCast(block));
        },
        dos.DOS_RDARGS => return cleared(db, @sizeOf(dos.RDArgs)),
        else => {
            _ = dos_lib.SetIoErr(dos.ERROR_BAD_NUMBER);
            return null;
        },
    }
}
