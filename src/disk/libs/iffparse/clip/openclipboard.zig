// SPDX-License-Identifier: MIT
//! OpenClipboard: clipboard.device opened, ready to be a stream.

const sdk = @import("sdk");
const exec = sdk.exec;
const clipboard = sdk.devices.clipboard;
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const IFFParseBase = _base.IFFParseBase;

/// Opens clipboard.device, ready to be a handle's stream.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenClipboard(ib: *IFFParseBase, unit: u32) ?*iffparse.ClipboardHandle
/// ```
///
/// SINCE: 1.0. LVO -160.
///
/// INPUTS:
/// - `unit` - which clipboard: `PRIMARY_CLIP` is the one programs share.
///
/// RESULT:
/// The handle, or null when there is no memory, no signal to spare or no
/// clipboard.device.
///
/// BEHAVIOR:
/// The handle carries a request and two ports: one for the request to
/// come back on, one for a `CBD_POST` to be answered on. It is a
/// clipboard request like any other until it is given to `InitIFFasClip`
/// and the handle is opened, after which it is the library's until
/// `CloseIFF`.
///
/// The ports are the calling task's: the handle is used by the task that
/// opened it and no other.
///
/// CONTEXT:
/// - Waits: for memory, and for clipboard.device to open.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's, to give back with `CloseClipboard`.
///
/// NOTES:
/// The clipboard holds IFF, which is why this call is here rather than
/// in a program: what is cut from one program and pasted into another
/// has to be read by both, and an `FTXT` form is what both understand.
///
/// SEE ALSO:
/// `CloseClipboard`, `InitIFFasClip`
///
/// EXAMPLES:
/// ```zig
/// const clip = ip.OpenClipboard(clipboard.PRIMARY_CLIP) orelse return;
/// defer ip.CloseClipboard(clip);
/// ```
pub fn OpenClipboard(ib: *IFFParseBase, unit: u32) ?*iffparse.ClipboardHandle {
    const sys = ib.sys_base;
    const memory = sys.AllocVec(@sizeOf(iffparse.ClipboardHandle), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const clip: *iffparse.ClipboardHandle = @ptrCast(@alignCast(memory));
    clip.* = .{};
    const reply_signal = sys.AllocSignal(-1);
    const satisfy_signal = sys.AllocSignal(-1);
    if (reply_signal < 0 or satisfy_signal < 0) {
        if (reply_signal >= 0) sys.FreeSignal(reply_signal);
        if (satisfy_signal >= 0) sys.FreeSignal(satisfy_signal);
        sys.FreeVec(memory);
        return null;
    }
    const task = sys.FindTask(null);
    clip.port = .{ .flags = exec.PA_SIGNAL, .sig_bit = @intCast(reply_signal), .sig_task = task };
    clip.port.node.type = .msgport;
    clip.port.msg_list.init(.message);
    clip.satisfy_port = .{ .flags = exec.PA_SIGNAL, .sig_bit = @intCast(satisfy_signal), .sig_task = task };
    clip.satisfy_port.node.type = .msgport;
    clip.satisfy_port.msg_list.init(.message);
    clip.req.io.req.message.reply_port = &clip.port;
    // How big the request really is, which is what the device checks
    // before it reads the fields past the standard ones.
    clip.req.io.req.message.length = @sizeOf(clipboard.IOClipReq);
    if (sys.OpenDevice(clipboard.CLIPBOARDNAME, unit, &clip.req.io.req, 0) != 0) {
        sys.FreeSignal(reply_signal);
        sys.FreeSignal(satisfy_signal);
        sys.FreeVec(memory);
        return null;
    }
    return clip;
}
