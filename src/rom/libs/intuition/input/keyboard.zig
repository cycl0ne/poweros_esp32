// SPDX-License-Identifier: MPL-2.0
//! The on-screen keyboard: a window of keys that comes up by itself while
//! a field is being typed into, on a board with no keyboard.
//!
//! After each event the input task has handled, with nothing held,
//! `follow` looks at what has the input. A string gadget - strgclass or a
//! class made from it, as the innermost gadget with the keys - on a
//! screen is being typed into; then, if the keyboard is wanted and not up,
//! it opens: a borderless window across the bottom of that screen, never
//! made active (`WA_NoActivate`), holding one keyboard.gadget as large as
//! the window. Its keys go to input.device, and from there to the field
//! as any key does. When nothing is being typed into any more - the field
//! let go, Return pressed - and no key of it is held, it closes again.
//!
//! **Wanted** is `Preferences.keyboard`: always, never, or - the default -
//! when the board has no keyboard of its own (expansion.library has no
//! `PARTKIND_KEYBOARD`), which is asked once.
//!
//! keyboard.gadget is a class on the disk: opened the first time the
//! keyboard comes up, from this task through ramlib's process, and kept.
//! Without it there is no keyboard, and nothing asks again.

const sdk = @import("sdk");
const exec = sdk.exec;
const intuition = sdk.intuition;
const wn = intuition.windows;
const gc = intuition.gadgetclass;
const classes = intuition.classes;
const st_tags = sdk.expansion.systemtags;
const kbg = sdk.gadgets.keyboard;
const TagItem = sdk.utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const Window = @import("../window/_window.zig").Window;
const Screen = @import("../screen/_screen.zig").Screen;

/// The keyboard's part of intuition's input state.
pub const State = extern struct {
    window: ?*Window = null,
    object: ?*intuition.Object = null,
    library: ?*exec.Library = null,
    /// The board's own keyboard: 0 not asked yet, 1 there, 2 none.
    board_keys: u8 = 0,
    /// The class could not be had: not asked again.
    failed: u8 = 0,
    pad: [2]u8 = .{ 0, 0 },
};

/// Whether `o`'s class is strgclass or made from it.
fn isString(ib: *IntuitionBase, o: *intuition.Object) bool {
    var cl: ?*classes.Class = classes.objectClass(o);
    while (cl) |c| : (cl = c.super) {
        if (c == ib.string_class) return true;
    }
    return false;
}

/// The screen a field is being typed into on, or null.
fn typingOn(ib: *IntuitionBase) ?*Screen {
    const in = &ib.input;
    if (in.mode != .active) return null;
    const o = in.focused orelse return null;
    if (!isString(ib, o)) return null;
    const w = in.window orelse return null;
    return w.screen;
}

/// Whether the keyboard comes up: as the preference says, or when the
/// board has none of its own.
fn wanted(ib: *IntuitionBase) bool {
    switch (ib.keyboard_mode) {
        intuition.KEYBOARD_ALWAYS => return true,
        intuition.KEYBOARD_NEVER => return false,
        else => {},
    }
    const st = &ib.input.keyboard;
    if (st.board_keys == 0) {
        st.board_keys = 2;
        if (ib.sys_base.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1)) |lib| {
            const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(lib);
            if (eb.FindBoardPart(null, st_tags.PARTKIND_KEYBOARD, st_tags.CHIP_ANY) != null) st.board_keys = 1;
            ib.sys_base.CloseLibrary(lib);
        }
    }
    return st.board_keys == 2;
}

fn open(ib: *IntuitionBase, screen: *Screen) void {
    const st = &ib.input.keyboard;
    if (st.failed != 0) return;
    const it = ib.iface();
    if (st.library == null) {
        st.library = ib.sys_base.OpenLibrary(kbg.KEYBOARD_LIBRARY, 0) orelse {
            st.failed = 1;
            return;
        };
    }
    const object = it.NewObjectTagList(null, kbg.KEYBOARD_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 0 },
        .{ .tag = gc.GA_Top, .data = 0 },
        .{ .tag = gc.GA_RelWidth, .data = 0 },
        .{ .tag = gc.GA_RelHeight, .data = 0 },
        .{},
    }) orelse return;
    var size = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL };
    _ = it.SendMessage(object, @ptrCast(&size));
    const height = @min(size.domain.height, @divTrunc(screen.height, 2));
    const window = it.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_CustomScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = @intCast(screen.height - height) },
        .{ .tag = wn.WA_Width, .data = @intCast(screen.width) },
        .{ .tag = wn.WA_Height, .data = @intCast(height) },
        .{ .tag = wn.WA_Borderless, .data = 1 },
        .{ .tag = wn.WA_NoActivate, .data = 1 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(object) },
        .{},
    }) orelse {
        it.DisposeObject(object);
        return;
    };
    st.window = @ptrCast(@alignCast(window));
    st.object = object;
}

fn close(ib: *IntuitionBase) void {
    const st = &ib.input.keyboard;
    const window = st.window orelse return;
    st.window = null;
    ib.iface().CloseWindow(@ptrCast(window));
    ib.iface().DisposeObject(st.object);
    st.object = null;
}

/// The keyboard up while a field is typed into and it is wanted, down
/// when none is and no key of it is held. On the input task, after an
/// event, with nothing held.
pub fn follow(ib: *IntuitionBase) void {
    const st = &ib.input.keyboard;
    if (typingOn(ib)) |screen| {
        if (st.window == null and wanted(ib)) open(ib, screen);
    } else if (st.window != null and ib.input.side == null) {
        close(ib);
    }
}
