// SPDX-License-Identifier: MIT
//! clipboard.device: what is cut, copied and pasted, a unit at a time.
//!
//! A unit holds one piece of data, written with `CMD_WRITE` and ended
//! with `CMD_UPDATE`, read back with `CMD_READ` from `io.offset`. The
//! data is IFF - an `FTXT` form for text, an `ILBM` for a picture - so
//! that what one program puts there another can read whatever it is, and
//! iffparse.library reads and writes it through `InitIFFasClip`.
//!
//! `CBD_POST` names a port instead of writing: the data stays where it is
//! until somebody reads it, and the port is sent a `SatisfyMsg` when they
//! do. `CBD_CHANGEHOOK` asks to be told whenever the unit changes.
//!
//! Unit 0 (`PRIMARY_CLIP`) is the one programs use unless they have a
//! reason not to.

const exec = @import("../libs/exec/exec.zig");

pub const CLIPBOARDNAME = "clipboard.device";

/// The unit every program uses unless it has a reason not to.
pub const PRIMARY_CLIP: u32 = 0;

/// Data offered rather than written: `io.data` is a `*MsgPort` to be sent
/// a `SatisfyMsg` when somebody reads it.
pub const CBD_POST: u16 = exec.CMD_NONSTD + 0;
/// The clip id of what can be read now, in `io.actual`.
pub const CBD_CURRENTREADID: u16 = exec.CMD_NONSTD + 1;
/// The clip id the write being made will have, in `io.actual`.
pub const CBD_CURRENTWRITEID: u16 = exec.CMD_NONSTD + 2;
/// `io.data` is a `*utility.Hook` called whenever the unit changes;
/// `io.length` 1 adds it, 0 takes it away.
pub const CBD_CHANGEHOOK: u16 = exec.CMD_NONSTD + 3;

/// A read that asked for a clip that is no longer the current one.
pub const CBERR_OBSOLETEID: i8 = 1;

/// struct IOClipReq: a request to clipboard.device.
pub const IOClipReq = extern struct {
    /// The standard fields: `command`, `data`, `length`, `actual` and
    /// `offset` - where in the clip a read or a write starts.
    io: exec.IOStdReq = .{},
    /// io_ClipID: which clip this is. A write is given its number by the
    /// device; a read asks for the one it was given.
    clip_id: i32 = 0,
};

/// What a posted port is sent when somebody reads the data it offered.
pub const SatisfyMsg = extern struct {
    msg: exec.Message = .{},
    /// sm_Unit
    unit: u16 = 0,
    pad: u16 = 0,
    /// sm_ClipID
    clip_id: i32 = 0,
};

/// What a change hook is called with: the hook's message.
pub const ClipHookMsg = extern struct {
    /// chm_Type: 0 for this shape.
    type: u32 = 0,
    /// chm_ChangeCmd: `CMD_UPDATE` or `CBD_POST`.
    change_cmd: i32 = 0,
    /// chm_ClipID: the clip that is there now.
    clip_id: i32 = 0,
};
