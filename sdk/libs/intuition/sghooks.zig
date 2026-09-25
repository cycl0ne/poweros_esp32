// SPDX-License-Identifier: MIT
//! A line of text's editing, as hooks see it.
//!
//! Each key typed into a strgclass gadget is edited in two steps before it
//! changes anything. The text is copied into a work buffer and described
//! by an `SGWork`; the **global edit hook** - intuition's own editing, until
//! `SetEditHook` puts another - makes of the key what it will there; then
//! the gadget's own hook (`STRINGA_EditHook`), if it has one, may change
//! that in its turn. What `actions` says afterwards is what happens: the
//! work used as the new text, the gadget ended, the screen flashed.
//!
//! A hook is called with the `SGWork` as its object and a `u32` command as
//! its message - `SGH_KEY` for a key, `SGH_CLICK` for a press that places
//! the cursor - and answers 0 for a command it does not know.

const classusr = @import("classusr.zig");
const Object = @import("classes.zig").Object;
const InputEvent = @import("../../devices/inputevent.zig").InputEvent;

/// The edit of one key, or one press, in progress.
pub const SGWork = extern struct {
    /// The gadget.
    gadget: *Object,
    /// The text as the edit would have it: change it here. As long as the
    /// gadget's buffer, `max_chars` bytes, NUL included.
    work_buffer: [*]u8,
    /// The text as it is, before this key.
    prev_buffer: [*]const u8,
    /// The text as it was when the gadget was activated: what Escape puts
    /// back.
    undo_buffer: [*]const u8,
    max_chars: u32,
    /// `SGM_` bits.
    modes: u32,
    /// The key, as it came. Not to be changed.
    event: *const InputEvent,
    /// The character the key makes, when it makes exactly one, else 0.
    /// When the edit ends the gadget (`SGA_END`), what the program is told
    /// as IDCMP_GADGETUP's code.
    code: u32,
    /// The cursor and the length, as the edit would have them.
    buffer_pos: u32,
    num_chars: u32,
    /// `SGA_` bits: what is done with the work.
    actions: u32,
    /// The text as a number.
    long_int: i32,
    gadget_info: ?*classusr.GadgetInfo,
    /// `EO_`: what kind of change the global hook made.
    edit_op: u32,
};

/// What the global hook did, in `edit_op`.
pub const EO_NOOP: u32 = 0x0001;
pub const EO_DELBACKWARD: u32 = 0x0002;
pub const EO_DELFORWARD: u32 = 0x0003;
pub const EO_MOVECURSOR: u32 = 0x0004;
pub const EO_ENTER: u32 = 0x0005;
pub const EO_RESET: u32 = 0x0006;
pub const EO_REPLACECHAR: u32 = 0x0007;
pub const EO_INSERTCHAR: u32 = 0x0008;
pub const EO_BADFORMAT: u32 = 0x0009;
pub const EO_BIGCHANGE: u32 = 0x000A;
pub const EO_UNDO: u32 = 0x000B;
pub const EO_CLEAR: u32 = 0x000C;
pub const EO_SPECIAL: u32 = 0x000D;

/// `modes`, and `STRINGA_EditModes`: a key replaces the character at the
/// cursor rather than going in before it.
pub const SGM_REPLACE: u32 = 1 << 0;
/// The text is as long as it is: nothing goes in or comes out, keys only
/// replace, and Backspace only moves back. With `SGM_REPLACE`.
pub const SGM_FIXEDFIELD: u32 = 1 << 1;
/// Control characters go into the text rather than being ignored - all
/// but the ones that edit: Return, Tab, Escape, Backspace.
pub const SGM_NOFILTER: u32 = 1 << 2;
/// The Help key ends the gadget, with a code of 0x5F.
pub const SGM_EXITHELP: u32 = 1 << 7;

/// `actions`: the work becomes the text.
pub const SGA_USE: u32 = 0x01;
/// The gadget is done; `code` goes to the program.
pub const SGA_END: u32 = 0x02;
/// The screen flashes: the key could not be taken.
pub const SGA_BEEP: u32 = 0x04;
/// With `SGA_END`: the key is used again once the gadget is inactive.
pub const SGA_REUSE: u32 = 0x08;
/// The gadget is drawn again - a cursor moved, say, with the text the same.
pub const SGA_REDISPLAY: u32 = 0x10;
/// With `SGA_END`: the next (or the previous) gadget that takes the
/// keyboard is made active.
pub const SGA_NEXTACTIVE: u32 = 0x20;
pub const SGA_PREVACTIVE: u32 = 0x40;

/// A hook's command: a key to edit.
pub const SGH_KEY: u32 = 1;
/// A hook's command: a press is putting the cursor at `buffer_pos`.
pub const SGH_CLICK: u32 = 2;
