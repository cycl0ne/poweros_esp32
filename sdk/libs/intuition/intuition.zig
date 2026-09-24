// SPDX-License-Identifier: MIT
//! intuition.library's types and constants.
//!
//! What it has so far is the object system: classes, objects and the
//! messages sent to them (`classes.zig`, `classusr.zig`), and the first
//! public classes: rootclass, which every class is made from; imageclass
//! (`imageclass.zig`); and icclass and modelclass, which pass on what
//! changed (`icclass.zig`). Screens (`screens.zig`) own a display each,
//! and windows (`windows.zig`) are layers of a screen with a border and a
//! message port. Gadgets (`gadgetclass.zig`) are objects in a window that
//! the pointer presses, and menus (`menus.zig`) a strip of titles a window
//! shows in its screen's bar.
//!
//! What it builds on is below it: layers.library (`sdk/libs/layers/`) for
//! windows that share one display buffer, and graphics.library
//! (`sdk/libs/graphics/`) for what is drawn in them.

pub const classes = @import("classes.zig");
pub const classusr = @import("classusr.zig");
pub const imageclass = @import("imageclass.zig");
pub const icclass = @import("icclass.zig");
pub const gadgetclass = @import("gadgetclass.zig");
pub const propgclass = @import("propgclass.zig");
pub const text = @import("text.zig");
pub const IntuiText = text.IntuiText;
pub const border = @import("border.zig");
pub const Border = border.Border;
pub const requesters = @import("requesters.zig");
pub const EasyStruct = requesters.EasyStruct;
pub const Requester = requesters.Requester;
pub const screens = @import("screens.zig");
pub const windows = @import("windows.zig");
pub const menus = @import("menus.zig");

/// The name to open it by.
pub const INTUITIONNAME = "intuition.library";
/// The version a caller of this SDK asks for.
pub const INTUITION_VERSION = 0;

pub const Class = classes.Class;
pub const Object = classes.Object;
pub const ObjectHeader = classes.ObjectHeader;
pub const Msg = classusr.Msg;
pub const MethodID = classusr.MethodID;
pub const Screen = screens.Screen;
pub const DrawInfo = screens.DrawInfo;
pub const Window = windows.Window;
pub const IntuiMessage = windows.IntuiMessage;
pub const Menu = menus.Menu;
pub const MenuItem = menus.MenuItem;
pub const GadgetInfo = classusr.GadgetInfo;
pub const objectClass = classes.objectClass;
pub const instData = classes.instData;
