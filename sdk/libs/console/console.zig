// SPDX-License-Identifier: MIT
//! console.device: a terminal in a window.
//!
//! A unit is bound to an intuition window: `CMD_WRITE` is a stream of
//! characters and control sequences it draws (docs/console.md), `CMD_READ`
//! the keys typed into that window, as the window's keymap makes them.
//!
//! The terminal it speaks is VT100 with the parts of xterm a program
//! expects: `ESC [` and the 8-bit `0x9B` both open a control sequence, and
//! what it sends - for a cursor key, a function key, a report - is the
//! 7-bit form.

const exec = @import("../exec/exec.zig");
const devices = @import("../exec/devices.zig");

/// The name to open it by.
pub const CONSOLENAME = "console.device";
pub const CONSOLE_VERSION = 0;

/// No console at all: the request is filled in far enough to call the
/// device's functions (`RawKeyConvert`).
pub const CONU_LIBRARY: i32 = -1;
/// A console that keeps no text: what is covered is the program's to draw
/// again.
pub const CONU_STANDARD: i32 = 0;
/// A console that keeps its text, and so puts it back itself when the
/// window is uncovered or sized.
pub const CONU_CHARMAP: i32 = 1;
/// As CONU_CHARMAP, and the pointer selects text in it: what is selected
/// is copied when the button is let go, and Shift+Insert or right-Amiga-V
/// pastes it back as though it had been typed.
pub const CONU_SNIPMAP: i32 = 3;

pub const CONFLAG_DEFAULT: u32 = 0;
/// Do not draw the text again when the window is sized; the program will.
pub const CONFLAG_NODRAW_ON_NEWSIZE: u32 = 1;

/// The unit's keymap, into `io_Data` (a `KeyMap`).
pub const CD_ASKKEYMAP: u16 = devices.CMD_NONSTD + 0;
/// `io_Data` a `KeyMap` the unit is to use from now on.
pub const CD_SETKEYMAP: u16 = devices.CMD_NONSTD + 1;
/// keymap.library's default keymap, into `io_Data`.
pub const CD_ASKDEFAULTKEYMAP: u16 = devices.CMD_NONSTD + 2;
/// `io_Data` a `KeyMap` to make keymap.library's default. It is not copied:
/// it must stay.
pub const CD_SETDEFAULTKEYMAP: u16 = devices.CMD_NONSTD + 3;

/// What `io_Unit` points at: where the console is and how big, for a
/// program that wants to draw beside it. Read it; the device writes it.
pub const ConUnit = extern struct {
    /// cu_MP: the unit's port, where its requests queue.
    msg_port: exec.MsgPort = .{},
    /// cu_Window: the window this console is on.
    window: ?*anyopaque = null,
    /// cu_XCP, cu_YCP: where the next character goes, in characters.
    cp_x: i32 = 0,
    cp_y: i32 = 0,
    /// cu_XMax, cu_YMax: the last column and row.
    max_x: i32 = 0,
    max_y: i32 = 0,
    /// cu_XRSize, cu_YRSize: a character cell, in pixels.
    cell_width: i32 = 0,
    cell_height: i32 = 0,
    /// cu_XROrigin, cu_YROrigin: where the first cell is in the window.
    origin_x: i32 = 0,
    origin_y: i32 = 0,
    /// CONU_ as it was opened, and the CONFLAG_ flags.
    unit_type: i32 = 0,
    flags: u32 = 0,
};

/// What a snip hook is handed: the text a console window's selection came
/// to. The object of the call is the `ConUnit` it was selected in. Neither
/// the message nor the text outlives the call, so a hook that wants to
/// keep the text copies it.
pub const SnipHookMsg = extern struct {
    /// shm_Type: 0, which says the two fields after it are what follows.
    /// Anything else is a message shape this one does not describe.
    type: u32 = 0,
    /// shm_SnipLen: the text's length, the NUL not counted.
    snip_len: u32 = 0,
    /// shm_SnipData: the text, NUL terminated.
    snip_data: ?[*:0]const u8 = null,
};

pub const ConsoleBase = @import("../../interface/console.zig").ConsoleBase;
