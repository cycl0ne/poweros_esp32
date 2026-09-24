// SPDX-License-Identifier: MPL-2.0
//! intuition.library as a library: its base, and the Expunge vector that
//! keeps it in memory.

const sdk = @import("sdk");
const exec = sdk.exec;
const intuition = sdk.intuition;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const LayersBase = sdk.interface.layers.LayersBase;
const Class = intuition.Class;
const _window = @import("window/_window.zig");
const _input = @import("input/_input.zig");
const _menus = @import("input/menus.zig");
const _gadget = @import("gadget/_gadget.zig");

/// The base: everything about the library that can change.
///
/// A library's memory is exec's, not the image's, so nothing here may
/// become a global. What a caller holds is the `lib` field, handed out as
/// the opaque `sdk.interface.intuition.IntuitionBase`.
pub const IntuitionBase = extern struct {
    lib: exec.Library,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
    /// utility.library, opened by the init and kept: every message goes
    /// through CallHookPkt, and imageclass's attributes through its pack
    /// calls.
    utility_base: *UtilityBase,
    /// graphics.library, opened by the init and kept: an image draws
    /// through it, and a screen is a RastPort on a display.
    graphics_base: *GraphicsBase,
    /// layers.library, opened by the init and kept: a screen's windows and
    /// its title bar are layers of its display.
    layers_base: *LayersBase,
    /// The open screens, oldest first.
    screen_list: exec.MinList,
    /// Guards `screen_list` and every public screen's lock count.
    screen_lock: exec.SignalSemaphore,
    /// The public classes, newest first. Each node is a class's
    /// dispatcher hook, which is the class's first field.
    class_list: exec.MinList,
    /// Guards `class_list` and every class's counts while they are
    /// checked against it.
    class_lock: exec.SignalSemaphore,
    /// The classes this library makes for itself, kept so a test can give
    /// them back. None is ever freed on the machine.
    root_class: ?*Class,
    image_class: ?*Class,
    ic_class: ?*Class,
    model_class: ?*Class,
    /// Kept for the windows too: every border is made of a frameiclass
    /// frame and sysiclass gadget images.
    frame_class: ?*Class,
    sys_class: ?*Class,
    /// Every gadget is a gadgetclass object, and its part of one is how
    /// this library reaches a gadget's box and flags.
    gadget_class: ?*Class,
    button_class: ?*Class,
    /// propgclass, the slider.
    prop_class: ?*Class,
    /// frbuttonclass, a button with a frame of its own.
    frbutton_class: ?*Class,
    /// groupgclass, a gadget made of gadgets.
    group_class: ?*Class,
    /// fillrectclass, a box of one colour.
    fillrect_class: ?*Class,
    /// itexticlass, an image whose shape is words.
    itext_class: ?*Class,
    /// strgclass, a line of text a person types.
    string_class: ?*Class,
    /// The height of the ROM font a screen opens with when it is given
    /// none, and what `IntuiTextLength` measures a run without a font in.
    /// It starts at `default_font_height`.
    font_height: u32,
    /// The window the border colours say is active, or null.
    active_window: ?*_window.Window,
    /// The handler on input.device's chain, its task, and what the pointer
    /// is doing.
    input: _input.State,
    /// The menu session: what it is waiting for, and what it shows.
    menu: _menus.State,
    /// The verify out to a window, and where its reply comes back.
    verify: @import("input/verify.zig").State,
    /// How far apart two clicks may be and still be a double-click.
    double_seconds: u32,
    double_micros: u32,
    /// The RastPorts `ObtainGIRPort` has given out, and the layer held for
    /// each, so that the release can let the right one go.
    held: [_gadget.held_max]_gadget.Held,
    /// keymap.library, opened by the init when it is there: a key becomes
    /// IDCMP_VANILLAKEY through it. Null without it, and then keys are only
    /// ever IDCMP_RAWKEY.
    keymap_base: ?*sdk.interface.keymap.KeymapBase,

    /// This library as a caller sees it, to call its own functions through
    /// the jump table.
    pub fn iface(ib: *IntuitionBase) *sdk.interface.intuition.IntuitionBase {
        return @ptrCast(ib);
    }
};

/// LibExpunge: a module in the ROM stays. Its classes are on the list and
/// programs hold objects of them, and the image it came from cannot be
/// read back in.
pub fn expunge(_: *exec.Library) callconv(.c) ?*anyopaque {
    return null;
}
