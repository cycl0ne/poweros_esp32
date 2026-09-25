// SPDX-License-Identifier: MIT
//! SocketBaseTagList: the opener's settings.

const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const utility = sdk.utility;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("_socket.zig");
const _lock = @import("../lock/_lock.zig");
const Socket = _socket.Socket;

/// The opener's settings, read and changed by a tag list.
///
/// SYNOPSIS:
/// ```zig
/// fn SocketBaseTagList(base: *SocketBase, tags: ?[*]const TagItem) i32
/// ```
///
/// SINCE: 1.0. LVO -96.
///
/// INPUTS:
/// - `tags` - each tag `SBTM_SETVAL(code)` with the value in ti_Data, or
///   `SBTM_GETREF(code)` with a pointer to an u32 in ti_Data that gets the
///   value. The codes:
///   - `SBTC_BREAKMASK` - the signals that break a wait with `EINTR`;
///   - `SBTC_SIGEVENTMASK` - the signal socket events are told with;
///   - `SBTC_ERRNO` - the error number;
///   - `SBTC_DTABLESIZE` - the size of the descriptor table, from 1 to
///     `FD_SETSIZE`; set only while no socket is open;
///   - `SBTC_LOGSTAT` - not 0 to have every call that fails logged, with
///     its errno, on the serial line.
///
/// RESULT:
/// 0 when every tag was taken, else the position of the first that was
/// not, from 1; the tags before it were taken.
///
/// BEHAVIOR:
/// The tags are taken in order, through utility.library, so TAG_MORE and
/// the other system tags work as anywhere.
///
/// CONTEXT:
/// - Waits: only for the stack's lock.
/// - Interrupts: no.
/// - Forbid: not held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The tag list is read and not kept.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Errno`, `WaitSelect`, `GetDTableSize`
///
/// EXAMPLES:
/// ```zig
/// const tags = [_]TagItem{
///     .{ .tag = bsd.SBTM_SETVAL(bsd.SBTC_BREAKMASK), .data = exec.SIGBREAKF_CTRL_C | exec.SIGBREAKF_CTRL_D },
///     .{},
/// };
/// _ = sb.SocketBaseTagList(&tags);
/// ```
pub fn SocketBaseTagList(sb: *SocketBase, tags: ?[*]const utility.TagItem) i32 {
    const ub = sb.stack.utility.?;
    var walk = tags;
    var position: i32 = 0;
    while (ub.NextTagItem(&walk)) |item| {
        position += 1;
        if (item.tag & utility.TAG_USER == 0) return position;
        const code = (item.tag >> bsd.SBTB_CODE) & bsd.SBTS_CODE;
        const set = item.tag & bsd.SBTF_SET != 0;
        if (!take(sb, code, set, item.data)) return position;
    }
    return 0;
}

/// One setting read or changed; false if there is no such code, or the
/// value cannot be taken.
fn take(sb: *SocketBase, code: u32, set: bool, data: usize) bool {
    if (set) return change(sb, code, @truncate(data));
    const value = read(sb, code) orelse return false;
    if (data == 0) return false;
    @as(*align(1) u32, @ptrFromInt(data)).* = value;
    return true;
}

fn read(sb: *SocketBase, code: u32) ?u32 {
    return switch (code) {
        bsd.SBTC_BREAKMASK => sb.break_mask,
        bsd.SBTC_SIGEVENTMASK => sb.event_mask,
        bsd.SBTC_ERRNO => @bitCast(sb.errno),
        bsd.SBTC_LOGSTAT => sb.log,
        bsd.SBTC_DTABLESIZE => sb.table_size,
        else => null,
    };
}

fn change(sb: *SocketBase, code: u32, value: u32) bool {
    switch (code) {
        bsd.SBTC_BREAKMASK => sb.break_mask = value,
        bsd.SBTC_SIGEVENTMASK => sb.event_mask = value,
        bsd.SBTC_ERRNO => _socket.setErrno(sb, @bitCast(value)),
        bsd.SBTC_LOGSTAT => sb.log = value,
        bsd.SBTC_DTABLESIZE => return resize(sb, value),
        else => return false,
    }
    return true;
}

/// The descriptor table made `size` long, while it holds no socket.
fn resize(sb: *SocketBase, size: u32) bool {
    if (size < 1 or size > bsd.FD_SETSIZE) return false;
    const sys = sb.sys_base;
    const held = _lock.take(sb.stack);
    defer _lock.give(sb.stack, held);
    for (sb.table.?[0..sb.table_size]) |entry| {
        if (entry != null) return false;
    }
    const table = sys.AllocMem(size * @sizeOf(?*Socket), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return false;
    sys.FreeMem(@ptrCast(sb.table), sb.table_size * @sizeOf(?*Socket));
    sb.table = @ptrCast(@alignCast(table));
    sb.table_size = size;
    return true;
}
