// SPDX-License-Identifier: MPL-2.0
//! The settings intuition keeps, and what reading and writing them does.
//!
//! The library holds them one field at a time where it uses them - the
//! double-click time is two numbers the input code reads on every press,
//! the screen font height is what a screen opens with - rather than as a
//! structure of its own. These gather them into one and scatter them
//! back, so that a `Preferences` a program hands in or takes away is a
//! copy and never a window onto the library's own state.
//!
//! A caller's `size` says how much of the structure it knows: fewer
//! bytes than the library has means a program built against an older
//! SDK, and the fields past that are left as they were.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const Preferences = intuition.Preferences;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// What the library starts with, which `GetDefPrefs` answers. The
/// numbers are the init's own, so that the two cannot drift apart.
pub const defaults = Preferences{
    .double_click = .{ .secs = default_double_seconds, .micro = default_double_micros },
    .screen_font_height = @import("../screen/_screen.zig").default_font_height,
};

/// How far apart two presses may be and still be one double-click, as
/// the library is born.
pub const default_double_seconds: u32 = 1;
pub const default_double_micros: u32 = 500_000;

/// The settings as the library holds them, gathered into one structure.
pub fn gather(ib: *IntuitionBase) Preferences {
    return .{
        .double_click = .{ .secs = ib.double_seconds, .micro = ib.double_micros },
        .screen_font_height = ib.font_height,
        .keyboard = ib.keyboard_mode,
    };
}

/// `bytes` of `from` copied into `into`, and no more than either holds.
/// The rest of `into` is left as it was, which is what lets a program
/// that knows less of the structure read and write the part it does.
pub fn copyIn(into: *Preferences, from: *const Preferences, bytes: u32) void {
    const room: usize = @min(bytes, @sizeOf(Preferences));
    const dst: [*]u8 = @ptrCast(into);
    const src: [*]const u8 = @ptrCast(from);
    var i: usize = 0;
    while (i < room) : (i += 1) dst[i] = src[i];
    // Whatever the caller thought the size was, what it now holds is
    // what this library wrote.
    into.struct_size = @intCast(room);
}

/// The settings taken from a structure, each to the field the library
/// keeps it in. A number that makes no sense is left alone rather than
/// taken: a double-click time of nothing would make every second press
/// one, and a screen font of no height would open a screen that cannot
/// draw a line of text.
pub fn scatter(ib: *IntuitionBase, prefs: *const Preferences, bytes: u32) void {
    if (bytes >= @offsetOf(Preferences, "double_click") + @sizeOf(@TypeOf(prefs.double_click))) {
        if (prefs.double_click.secs != 0 or prefs.double_click.micro != 0) {
            ib.double_seconds = prefs.double_click.secs;
            ib.double_micros = prefs.double_click.micro;
        }
    }
    if (bytes >= @offsetOf(Preferences, "screen_font_height") + @sizeOf(u32)) {
        if (prefs.screen_font_height != 0) ib.font_height = prefs.screen_font_height;
    }
    if (bytes >= @offsetOf(Preferences, "keyboard") + @sizeOf(u32)) {
        if (prefs.keyboard <= intuition.KEYBOARD_NEVER) ib.keyboard_mode = prefs.keyboard;
    }
}
