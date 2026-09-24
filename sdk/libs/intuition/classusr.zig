// SPDX-License-Identifier: MIT
//! Messages: what is sent to an object, and the names of the public
//! classes.
//!
//! Every message begins with its method ID, and the rest of it is that
//! method's. A dispatcher looks at the ID and casts the message to the
//! structure that goes with it.

const utility = @import("../utility/utility.zig");
const exec = @import("../exec/exec.zig");
const classes = @import("classes.zig");

pub const MethodID = u32;

/// Any message, as far as every message agrees.
pub const Msg = extern struct {
    method_id: MethodID,
};

// --- the public classes -----------------------------------------------------

pub const ROOTCLASS = "rootclass";
pub const IMAGECLASS = "imageclass";
pub const ICCLASS = "icclass";
pub const MODELCLASS = "modelclass";
pub const FRAMEICLASS = "frameiclass";
pub const SYSICLASS = "sysiclass";
pub const GADGETCLASS = "gadgetclass";
pub const BUTTONGCLASS = "buttongclass";
pub const PROPGCLASS = "propgclass";
pub const FRBUTTONCLASS = "frbuttonclass";
pub const GROUPGCLASS = "groupgclass";
pub const FILLRECTCLASS = "fillrectclass";
pub const ITEXTICLASS = "itexticlass";
pub const STRGCLASS = "strgclass";

// --- the methods every object has ---------------------------------------

/// Where the object methods begin; used for nothing itself.
pub const OM_Dummy: MethodID = 0x100;
/// Make an object. Sent with the true class as the object, since there is
/// no object yet; the answer is the new object, or 0. `OpSet`.
pub const OM_NEW: MethodID = OM_Dummy + 0x01;
/// Free the object, and whatever each class had it hold. `Msg`.
pub const OM_DISPOSE: MethodID = 0x102;
/// Change attributes. `OpSet`; the answer is nonzero when something
/// visible changed.
pub const OM_SET: MethodID = 0x103;
/// Read one attribute. `OpGet`; the answer is nonzero when the class knew
/// it.
pub const OM_GET: MethodID = 0x104;
/// Put the object at the end of a list. `OpAddTail`.
pub const OM_ADDTAIL: MethodID = 0x105;
/// Take it off whichever list it is on. `Msg`.
pub const OM_REMOVE: MethodID = 0x106;
/// Tell others about attributes that changed: an object sends this to
/// itself, and icclass passes it on to its target. `OpUpdate`.
pub const OM_NOTIFY: MethodID = 0x107;
/// Being told about attributes that changed somewhere else. `OpUpdate`.
pub const OM_UPDATE: MethodID = 0x108;
/// Add a member to a group object: a model's dependents. `OpMember`.
pub const OM_ADDMEMBER: MethodID = 0x109;
/// Take a member out of a group object. `OpMember`.
pub const OM_REMMEMBER: MethodID = 0x10A;

/// Where a gadget is: its window, and what the window is on. Made by
/// intuition.library for each message it sends a gadget, and good for that
/// message only.
pub const GadgetInfo = extern struct {
    /// gi_Screen, gi_Window.
    screen: *@import("screens.zig").Screen,
    window: *@import("windows.zig").Window,
    /// gi_Requester: the requester the gadget is in, or null for one of the
    /// window's own.
    requester: ?*@import("requesters.zig").Requester = null,
    /// gi_DrInfo: the screen's pens.
    draw_info: *@import("screens.zig").DrawInfo,
    /// gi_Pens: the window's own two pens, which is what a gadget draws
    /// itself in when it wants to look like the window it is on rather than
    /// like the screen. The screen's whole set is in `draw_info`.
    detail_pen: u32 = 0,
    block_pen: u32 = 0,
    /// gi_RastPort, gi_Layer: where this gadget is drawn and what has to be
    /// held to draw there. A gadget asks for them with `ObtainGIRPort`
    /// rather than reading them, which is what takes the lock; they are
    /// here because that call needs them and because a class that only
    /// wants to measure something may read them without drawing.
    rast_port: ?*@import("../graphics/graphics.zig").RastPort = null,
    layer: ?*@import("../layers/layers.zig").Layer = null,
    /// gi_Domain: the box the gadget's coordinates are measured in, as a
    /// place on the window. **Left and top are what to subtract** from a
    /// point in the window to reach that box - nothing for a window's own
    /// gadgets, the border for an inner layer, the requester's corner for a
    /// requester's. Width and height are what a gadget's `GA_Rel` values
    /// are measured against.
    domain_left: i32,
    domain_top: i32,
    domain_width: i32,
    domain_height: i32,
};

/// OM_NEW and OM_SET.
pub const OpSet = extern struct {
    method_id: MethodID,
    /// ops_AttrList: the attributes, as tags.
    attr_list: ?[*]const utility.TagItem,
    /// ops_GInfo: the gadget's window, when a gadget is set through
    /// SetGadgetAttrsTagList; null otherwise.
    gadget_info: ?*GadgetInfo = null,
};

/// OM_GET.
pub const OpGet = extern struct {
    method_id: MethodID,
    /// opg_AttrID: which attribute.
    attr_id: utility.Tag,
    /// opg_Storage: where its value goes - the same value SetAttrs would
    /// be given for it in a tag's data.
    storage: *usize,
};

/// OM_NOTIFY and OM_UPDATE.
pub const OpUpdate = extern struct {
    method_id: MethodID,
    /// opu_AttrList: the attributes that changed, as tags. A receiver may
    /// read them, and does not keep or change them.
    attr_list: ?[*]const utility.TagItem,
    /// opu_GInfo: the window of the gadget the update started from, or null.
    gadget_info: ?*GadgetInfo = null,
    /// opu_Flags: `OPUF_INTERIM`.
    flags: u32 = 0,
};

/// The update comes from something still changing - a slider being
/// dragged - and a final one without this bit follows when it stops.
pub const OPUF_INTERIM: u32 = 1 << 0;

/// OM_ADDMEMBER and OM_REMMEMBER.
pub const OpMember = extern struct {
    method_id: MethodID,
    /// opam_Object: the member.
    object: *classes.Object,
};

/// OM_ADDTAIL.
pub const OpAddTail = extern struct {
    method_id: MethodID,
    /// opat_List: the list to go on. Its members are read back with
    /// `NextObject`.
    list: *exec.MinList,
};

pub const Class = classes.Class;
pub const Object = classes.Object;
