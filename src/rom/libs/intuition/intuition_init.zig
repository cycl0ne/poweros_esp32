// SPDX-License-Identifier: MPL-2.0
//! intuition.library's ROM tag, and the init routine it names.
//!
//! The tag is a cold-start, auto-init resident at priority 18, under
//! layers.library and graphics.library, which the init opens along with
//! utility.library and, when it is there, keymap.library. exec builds the
//! library from the InitTable - the jump table is intuition_lvo.zig's - and
//! calls `init`, which makes the public classes.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const layers = sdk.layers;
const intuition = sdk.intuition;
const ExecBase = sdk.interface.exec.ExecBase;
const intuition_lvo = @import("intuition_lvo.zig");
const IntuitionBase = @import("intuition_base.zig").IntuitionBase;
const rootclass = @import("classes/rootclass.zig");
const imageclass = @import("classes/imageclass.zig");
const icclass = @import("classes/icclass.zig");
const modelclass = @import("classes/modelclass.zig");
const frameiclass = @import("classes/frameiclass.zig");
const sysiclass = @import("classes/sysiclass.zig");
const gadgetclass = @import("classes/gadgetclass.zig");
const buttongclass = @import("classes/buttongclass.zig");
const propgclass = @import("classes/propgclass.zig");
const frbuttonclass = @import("classes/frbuttonclass.zig");
const groupgclass = @import("classes/groupgclass.zig");
const fillrectclass = @import("classes/fillrectclass.zig");
const itexticlass = @import("classes/itexticlass.zig");
const strgclass = @import("classes/strgclass.zig");

/// The version of utility.library the hook and pack calls are taken from.
const UTILITY_VERSION = 1;

/// The name it is opened by, and the name in its ROM tag and on exec's
/// library list. The SDK's, so a caller and the library cannot disagree.
pub const LIBRARY_NAME = intuition.INTUITIONNAME;
pub const LIBRARY_VERSION = 0;
/// 2: the object system. 3: icclass, modelclass and the image calls.
/// 4: screens. 5: windows, frameiclass and sysiclass. 6: gadgets:
/// gadgetclass, buttongclass and the gadget calls. 7: the rest of the
/// classes - propgclass, strgclass, groupgclass, frbuttonclass,
/// fillrectclass and itexticlass. 8: the classes read against their own
/// sources and put right, the input rules with them; a gadget draws in a
/// RastPort of its own; and the window tags - its pens, its flags in bulk,
/// which border holds the size gadget, zoom and GimmeZeroZero. 9: text
/// and lines drawn from a description (PrintIText, DrawBorder), a run of
/// text measured, and the screens held still (LockIBase). 10: a window's
/// box flipped (ZipWindow), its titles changed and its screen title shown,
/// its limits set, and a gadget turned off and on. 11: the easy
/// requester. 12: menus - the strip, its panels and subitems, checkmarks,
/// shortcuts, IDCMP_MENUVERIFY and IDCMP_MENUHELP, and lent menus. 13:
/// requesters in a window and the double-click requester, the requester
/// from IntuiTexts, ActivateGadget and DoGadgetMethodA. 14:
/// IDCMP_SIZEVERIFY, the verifies in a file of their own.
pub const LIBRARY_REVISION = 14;
const BUILD_DATE = "22.9.2026";
const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

fn intuitionBase(lib: *exec.Library) *IntuitionBase {
    return @alignCast(@fieldParentPtr("lib", lib));
}

/// LibInit: open the libraries this one is built on, set up the class
/// and screen lists, and make the four public classes.
///
/// INPUTS:
/// - `lib` - the base exec made from the init table.
/// - `seg_list` - null: a module in the ROM has no segments.
/// - `sys_base` - SysBase, kept in the base.
///
/// RESULT:
/// The base, or null when utility, graphics or layers cannot be opened or there was no memory for the classes - after which
/// nothing it took is left behind.
///
/// CONTEXT:
/// - Waits: only for the semaphore it has just made, which nobody else
///   can hold yet.
/// - Interrupts: no; it runs on the exec task at cold start.
/// - Forbid: not held. InitCode takes none.
/// - Process: a Task will do.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const ib = intuitionBase(lib);
    lib.revision = LIBRARY_REVISION;
    ib.sys_base = sys_base;
    ib.font_height = @import("screen/_screen.zig").default_font_height;

    const utility_lib = sys_base.OpenLibrary(sdk.interface.utility.NAME, UTILITY_VERSION) orelse return null;
    const graphics_lib = sys_base.OpenLibrary(graphics.GRAPHICSNAME, graphics.GRAPHICS_VERSION) orelse {
        sys_base.CloseLibrary(utility_lib);
        return null;
    };
    const layers_lib = sys_base.OpenLibrary(layers.LAYERSNAME, layers.LAYERS_VERSION) orelse {
        sys_base.CloseLibrary(graphics_lib);
        sys_base.CloseLibrary(utility_lib);
        return null;
    };
    ib.rtg_base = @ptrCast(@alignCast(sys_base.OpenLibrary(sdk.rtg.RTGNAME, 0)));
    ib.utility_base = @ptrCast(utility_lib);
    ib.graphics_base = @ptrCast(graphics_lib);
    ib.layers_base = @ptrCast(layers_lib);

    // No screen is opened here: a machine with no display boots, and the
    // default screen opens the first time something asks for it.
    ib.screen_list.init();
    ib.pub_screens.init(.unknown);
    ib.default_pub = null;
    ib.pub_modes = 0;
    ib.timer_io = .{};
    ib.timer_open = false;
    ib.alert = .{};
    sys_base.InitSemaphore(&ib.alert_lock);
    ib.default_edit_hook = .{ .entry = &strgclass.defaultEdit };
    ib.edit_hook = &ib.default_edit_hook;
    sys_base.InitSemaphore(&ib.screen_lock);

    ib.class_list.init();
    sys_base.InitSemaphore(&ib.class_lock);
    // Each from the one before it or from rootclass, so the first failure
    // leaves the rest unmade and they are given back newest first.
    ib.root_class = rootclass.make(ib);
    ib.image_class = if (ib.root_class != null) imageclass.make(ib) else null;
    ib.ic_class = if (ib.image_class != null) icclass.make(ib) else null;
    ib.model_class = if (ib.ic_class != null) modelclass.make(ib) else null;
    ib.frame_class = if (ib.model_class != null) frameiclass.make(ib) else null;
    ib.sys_class = if (ib.frame_class != null) sysiclass.make(ib) else null;
    ib.gadget_class = if (ib.sys_class != null) gadgetclass.make(ib) else null;
    ib.button_class = if (ib.gadget_class != null) buttongclass.make(ib) else null;
    ib.prop_class = if (ib.button_class != null) propgclass.make(ib) else null;
    ib.frbutton_class = if (ib.prop_class != null) frbuttonclass.make(ib) else null;
    ib.group_class = if (ib.frbutton_class != null) groupgclass.make(ib) else null;
    ib.fillrect_class = if (ib.group_class != null) fillrectclass.make(ib) else null;
    ib.itext_class = if (ib.fillrect_class != null) itexticlass.make(ib) else null;
    ib.string_class = if (ib.itext_class != null) strgclass.make(ib) else null;
    ib.active_window = null;
    ib.input = .{};
    @import("input/menus.zig").init(ib);
    @import("input/verify.zig").init(ib);
    // A second and a half, until there is a preference that says otherwise.
    ib.double_seconds = 1;
    ib.double_micros = 500_000;
    ib.keymap_base = @ptrCast(sys_base.OpenLibrary(sdk.keymap.KEYMAPNAME, sdk.keymap.KEYMAP_VERSION));
    if (ib.string_class == null) {
        _ = ib.iface().FreeClass(ib.itext_class);
        _ = ib.iface().FreeClass(ib.fillrect_class);
        _ = ib.iface().FreeClass(ib.group_class);
        _ = ib.iface().FreeClass(ib.frbutton_class);
        _ = ib.iface().FreeClass(ib.prop_class);
        _ = ib.iface().FreeClass(ib.button_class);
        _ = ib.iface().FreeClass(ib.gadget_class);
        _ = ib.iface().FreeClass(ib.sys_class);
        _ = ib.iface().FreeClass(ib.frame_class);
        _ = ib.iface().FreeClass(ib.model_class);
        _ = ib.iface().FreeClass(ib.ic_class);
        _ = ib.iface().FreeClass(ib.image_class);
        _ = ib.iface().FreeClass(ib.root_class);
        if (ib.keymap_base) |kb| sys_base.CloseLibrary(@ptrCast(@alignCast(kb)));
        if (ib.rtg_base) |rb| sys_base.CloseLibrary(@ptrCast(@alignCast(rb)));
        sys_base.CloseLibrary(layers_lib);
        sys_base.CloseLibrary(graphics_lib);
        sys_base.CloseLibrary(utility_lib);
        return null;
    }
    return lib;
}

const init_table = exec.InitTable{
    .data_size = @sizeOf(IntuitionBase),
    .vectors = &intuition_lvo.vectors,
    .vector_count = intuition_lvo.vectors.len,
    .init = &init,
};

/// Cold start at 18: below layers.library (19) and graphics.library (20),
/// which it opens, and so below rtg.library and its drivers as well.
pub export const intuition_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &intuition_library_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 18,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
