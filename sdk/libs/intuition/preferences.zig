// SPDX-License-Identifier: MIT
//! The settings intuition.library keeps: what a program may change while
//! the system runs, read with `GetPrefs`, changed with `SetPrefs`, and
//! set back to what the system started with from `GetDefPrefs`.
//!
//! The structure is this system's own. What a machine of another shape
//! kept here - the pointer's sprite, the printer, the serial port's
//! speed, the screen's size in a display mode that no longer exists -
//! either belongs to the driver that has it or is not a thing here at
//! all; what is left is what intuition itself acts on.
//!
//! It is read and written with a size, so a program built against an
//! older SDK than the library reads and writes the part it knows and the
//! rest keeps its value. `struct_size` says which that was.
//!
//!   var prefs: intuition.Preferences = undefined;
//!   _ = ib.GetPrefs(&prefs, @sizeOf(@TypeOf(prefs)));
//!   prefs.double_click = .{ .secs = 0, .micro = 300_000 };
//!   _ = ib.SetPrefs(&prefs, @sizeOf(@TypeOf(prefs)), true);
//!
//! The values a `Preferences` is born with here are what the library
//! starts with, but `GetDefPrefs` is what answers for the library: a
//! program that wants the system's own defaults asks it rather than
//! writing the numbers down.
//!
//! A change told with `announce` reaches every window that asked for
//! `IDCMP_NEWPREFS`, whichever screen it is on: a window that draws
//! something the settings decide reads them again and draws it anew.

const timer = @import("../../devices/timer.zig");

/// What intuition keeps. Anything added goes at the end, so that a
/// program built against an older version still reads what it knew.
pub const Preferences = extern struct {
    /// How many bytes of this the caller knows about, which is what
    /// `GetPrefs` filled in or `SetPrefs` read.
    struct_size: u32 = @sizeOf(Preferences),
    /// How far apart two presses may be and still be one double-click.
    /// `DoubleClick` answers by this.
    double_click: timer.TimeVal = .{ .secs = 1, .micro = 500_000 },
    /// How tall the font a screen opens with is, when the screen is
    /// given none. Rows.
    screen_font_height: u32 = 16,
};
