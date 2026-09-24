// SPDX-License-Identifier: MPL-2.0
//! MakeDosEntry: a new device list node with its name.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const DosList = dos.DosList;

/// Makes a device list node with a copy of its name.
///
/// SYNOPSIS:
/// ```zig
/// fn MakeDosEntry(db: *DosBase, name: [*:0]const u8, dlt: i32) ?*DosList
/// ```
///
/// SINCE: 1.0. LVO -88.
///
/// INPUTS:
/// - `name` - the name, without the colon.
/// - `dlt` - the node's type, a DLT_* value.
///
/// RESULT:
/// The node, cleared apart from its type and name, or null with IoErr()
/// ERROR_NO_FREE_STORE, or ERROR_BAD_NUMBER for a `dlt` that is no DLT_*
/// value.
///
/// BEHAVIOR:
/// The node and its name are one allocation, the name right after the node.
/// It is not put on the list.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: allowed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The node is the caller's, freed with FreeDosEntry - or the list's once
/// AddDosEntry took it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FreeDosEntry`, `AddDosEntry`
///
/// EXAMPLES:
/// ```zig
/// const node = dos_lib.MakeDosEntry("RAM", dos.DLT_DEVICE) orelse return null;
/// node.misc.handler.handler = "ram-handler";
/// ```
pub fn MakeDosEntry(db: *DosBase, name: [*:0]const u8, dlt: i32) ?*DosList {
    const dos_lib = db.iface();
    const node_type = typeOf(dlt) orelse {
        _ = dos_lib.SetIoErr(dos.ERROR_BAD_NUMBER);
        return null;
    };
    const len = db.utility_base.Strlen(name);
    const block = db.sys_base.AllocVec(@sizeOf(DosList) + len + 1, exec.MEMF_CLEAR) orelse {
        _ = dos_lib.SetIoErr(dos.ERROR_NO_FREE_STORE);
        return null;
    };
    const node: *DosList = @ptrCast(@alignCast(block));
    const copy: [*]u8 = @as([*]u8, @ptrCast(block)) + @sizeOf(DosList);
    @memcpy(copy[0..len], name[0..len]);
    copy[len] = 0;
    node.* = .{ .type = node_type, .name = @ptrCast(copy) };
    return node;
}

/// The node type a DLT_* value names, or null for a value that names none.
///
/// INPUTS:
/// - `dlt` - the caller's value.
fn typeOf(dlt: i32) ?dos.DosListType {
    inline for (@typeInfo(dos.DosListType).@"enum".fields) |field| {
        if (dlt == field.value) return @enumFromInt(field.value);
    }
    return null;
}
