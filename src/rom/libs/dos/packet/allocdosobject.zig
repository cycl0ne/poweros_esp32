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
///   DOS_EXALLCONTROL, DOS_CLI, DOS_RDARGS or DOS_REQUEST.
/// - `tags` - options for the object, null for none. Only DOS_REQUEST
///   reads one: `ADO_ReplyPort`, the port it comes back to.
///
/// RESULT:
/// The object, ready to use, or null: with ERROR_NO_FREE_STORE when
/// there was no memory, and with ERROR_BAD_NUMBER for a type it doesn't
/// know.
///
/// BEHAVIOR:
/// Each type is made as the area's header lists: cleared, with its
/// defaults, and for a CLI with its name buffers in the same block. A
/// DosPacket's message length is set so it can be sent at once.
///
/// A DosRequest (StartRead, StartWrite) comes back to the port
/// `ADO_ReplyPort` names, which other requests and the caller's own
/// messages may share; without the tag it gets a port of its own, made
/// with CreateMsgPort - a signal of the caller's - and freed with it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not safe; it allocates.
/// - Locks: none needed.
/// - Process: a Task will do. A DosRequest's own port signals the task
///   that allocated it.
///
/// OWNERSHIP:
/// The object is the caller's, to give back with FreeDosObject and the
/// same type. A port `ADO_ReplyPort` names stays the caller's, and must
/// outlive the request.
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
///
/// const request: *dos.DosRequest = @ptrCast(@alignCast(dos_lib.AllocDosObject(dos.DOS_REQUEST, null) orelse return null));
/// defer dos_lib.FreeDosObject(dos.DOS_REQUEST, request);
/// ```
pub fn AllocDosObject(db: *DosBase, obj_type: u32, tags: ?[*]const TagItem) ?*anyopaque {
    const dos_lib = db.iface();
    const sys = db.sys_base;
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
        dos.DOS_REQUEST => {
            const req: *dos.DosRequest = @ptrCast(@alignCast(cleared(db, @sizeOf(dos.DosRequest)) orelse return null));
            req.* = .{};
            const named: ?*exec.MsgPort = @ptrFromInt(db.utility_base.GetTagData(dos.ADO_ReplyPort, 0, tags));
            if (named) |port| {
                req.port = port;
                return req;
            }
            req.port = sys.CreateMsgPort() orelse {
                sys.FreeVec(req);
                _ = dos_lib.SetIoErr(dos.ERROR_NO_FREE_STORE);
                return null;
            };
            req.own_port = true;
            return req;
        },
        else => {
            _ = dos_lib.SetIoErr(dos.ERROR_BAD_NUMBER);
            return null;
        },
    }
}
