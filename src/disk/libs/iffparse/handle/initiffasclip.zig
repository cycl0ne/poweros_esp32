// SPDX-License-Identifier: MIT
//! InitIFFasClip: the stream is the clipboard.
//!
//! The hook is the handle's own, as the file stream's is: a module keeps
//! no state of its own.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const clipboard = sdk.devices.clipboard;
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const IFFParseBase = _base.IFFParseBase;

/// How far a read is asked to seek to find the end of the data.
const far_end: u64 = 0x7FFF_FFFF;

/// The stream of a handle whose `stream` is a `ClipboardHandle`.
fn clipStream(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const iff: *iffparse.IFFHandle = @ptrCast(@alignCast(object orelse return 1));
    const cmd: *iffparse.IFFStreamCmd = @ptrCast(@alignCast(message orelse return 1));
    const h = _base.handleOf(iff);
    _ = hook;
    const sys = h.base.sys_base;
    const clip: *iffparse.ClipboardHandle = @ptrFromInt(iff.stream);
    const bytes: u64 = @intCast(@max(cmd.bytes, 0));
    switch (cmd.command) {
        iffparse.IFFCMD_INIT => {
            clip.req.clip_id = 0;
            clip.req.io.offset = 0;
            clip.req.io.req.err = 0;
            return 0;
        },
        iffparse.IFFCMD_CLEANUP => {
            if (iff.flags & iffparse.IFFF_RWBITS == iffparse.IFFF_WRITE) {
                clip.req.io.req.command = exec.CMD_UPDATE;
            } else {
                // A read is finished by asking for the end of the data,
                // which is how the device is told nobody wants more.
                clip.req.io.req.command = exec.CMD_READ;
                clip.req.io.data = null;
                clip.req.io.length = 1;
                clip.req.io.offset = far_end;
            }
            return @intCast(@as(u32, @bitCast(sys.DoIO(&clip.req.io.req))));
        },
        iffparse.IFFCMD_READ => {
            clip.req.io.req.command = exec.CMD_READ;
            clip.req.io.data = cmd.buf;
            clip.req.io.length = bytes;
            return @intCast(@as(u32, @bitCast(sys.DoIO(&clip.req.io.req))));
        },
        iffparse.IFFCMD_WRITE => {
            clip.req.io.req.command = exec.CMD_WRITE;
            clip.req.io.data = cmd.buf;
            clip.req.io.length = bytes;
            return @intCast(@as(u32, @bitCast(sys.DoIO(&clip.req.io.req))));
        },
        iffparse.IFFCMD_SEEK => {
            const at: i64 = @as(i64, @bitCast(clip.req.io.offset)) + cmd.bytes;
            if (at < 0) return 1;
            clip.req.io.offset = @intCast(at);
            return 0;
        },
        else => return 0,
    }
}

/// Says a handle's stream is the clipboard.
///
/// SYNOPSIS:
/// ```zig
/// fn InitIFFasClip(ib: *IFFParseBase, iff: *iffparse.IFFHandle) void
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `iff` - a handle from `AllocIFF`, not open, whose `stream` holds a
///   `*ClipboardHandle` from `OpenClipboard`.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The clipboard seeks both ways, since a seek is only a change of
/// offset in the unit. Writing ends with `CMD_UPDATE`, which is what
/// makes the data the current clip; reading ends by asking past the end,
/// which tells the device nobody wants more.
///
/// CONTEXT:
/// - Waits: no, but everything done through the stream afterwards waits
///   on clipboard.device.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The clipboard handle stays the caller's, to close with
/// `CloseClipboard` after `CloseIFF`.
///
/// NOTES:
/// Between `OpenIFF` and `CloseIFF` the clipboard handle is the
/// library's to drive: a program that sends its own requests on it
/// meanwhile will lose its place.
///
/// SEE ALSO:
/// `OpenClipboard`, `CloseClipboard`, `OpenIFF`
///
/// EXAMPLES:
/// ```zig
/// const clip = ip.OpenClipboard(clipboard.PRIMARY_CLIP) orelse return;
/// defer ip.CloseClipboard(clip);
/// iff.stream = @intFromPtr(clip);
/// ip.InitIFFasClip(iff);
/// ```
pub fn InitIFFasClip(ib: *IFFParseBase, iff: *iffparse.IFFHandle) void {
    const h = _base.handleOf(iff);
    h.own_stream = .{ .entry = &clipStream };
    InitIFF(ib, iff, iffparse.IFFF_FSEEK | iffparse.IFFF_RSEEK, &h.own_stream);
}

const InitIFF = @import("initiff.zig").InitIFF;
