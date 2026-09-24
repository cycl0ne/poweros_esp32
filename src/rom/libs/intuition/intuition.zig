// SPDX-License-Identifier: MPL-2.0
//! intuition.library: screens and windows, the input that reaches them,
//! and the object system everything on them is built from.
//!
//! A **class** is a dispatcher (a utility Hook), a superclass and a slice
//! of instance data; an **object** is one block holding the data of each
//! class from rootclass down to its own, with a header in front of the
//! handle; and a **message** is a method ID and whatever that method
//! needs, handed to a class's dispatcher, which passes on what it does not
//! handle to the class it was made from. Fourteen classes are public from
//! the start, and every window border and gadget is made of them.
//!
//! What it builds on is below it in the ROM: layers.library, which gives a
//! window a rectangle of the display, and graphics.library, which draws.
//! Neither knows a window exists; this is the layer that does.
//!
//! Each call is a file of its own in the folder for its area - boopsi/ for
//! the class and object calls, image/, screen/, window/, gadget/, render/
//! and ibase/ - and input/ holds the handler on input.device's chain and
//! the task that acts on it. classes/ holds the classes, one file each.
//! The jump table is intuition_lvo.zig, the ROM tag and init
//! intuition_init.zig, the base intuition_base.zig. This file holds the
//! names the rest of the kernel reaches the library by, and the tests of
//! calls working together. Its functions are `sdk/fd/intuition_lib.fd` and
//! its types `sdk/libs/intuition/`.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const Class = intuition.Class;
const Object = intuition.Object;
const Msg = intuition.Msg;
const TagItem = utility.TagItem;

/// intuition.library's base (intuition_base.zig).
const intuition_base = @import("intuition_base.zig");
/// intuition.library's ROM tag and init routine (intuition_init.zig).
const intuition_init = @import("intuition_init.zig");

// The tag is an export in .resident, found there by its address; this
// keeps it in whatever is built from intuition.library.
comptime {
    _ = &intuition_init.intuition_library_tag;
}

/// The library's base, for the modules that keep a pointer to it.
pub const IntuitionBase = intuition_base.IntuitionBase;
/// What the library is on exec's list as.
pub const LIBRARY_NAME = intuition_init.LIBRARY_NAME;
/// The ROM tag, for the host tests that make the library from it.
pub const intuition_library_tag = intuition_init.intuition_library_tag;

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const _window = @import("window/_window.zig");
const _gadget = @import("gadget/_gadget.zig");
const _input = @import("input/_input.zig");
const _menus = @import("input/menus.zig");
const _menu_area = @import("menu/_menu.zig");
const gadgetclass = @import("classes/gadgetclass.zig");
const groupgclass = @import("classes/groupgclass.zig");
const kexec = @import("../exec/exec.zig");
const kutility = @import("../utility/utility.zig");
const krtg = @import("../rtg/rtg.zig");
const kgraphics = @import("../graphics/graphics.zig");
const klayers = @import("../layers/layers.zig");
const kkeymap = @import("../keymap/keymap.zig");
const fake = @import("../rtg_driver/fakeboard/fakeboard.zig");
const classusr = intuition.classusr;
const ic = intuition.imageclass;

test {
    _ = @import("intuition_base.zig");
    _ = @import("intuition_init.zig");
    _ = @import("intuition_lvo.zig");
    _ = @import("boopsi/_boopsi.zig");
    _ = @import("boopsi/addclass.zig");
    _ = @import("boopsi/coercemessage.zig");
    _ = @import("boopsi/disposeobject.zig");
    _ = @import("boopsi/findclass.zig");
    _ = @import("boopsi/freeclass.zig");
    _ = @import("boopsi/getattr.zig");
    _ = @import("boopsi/lockclasslist.zig");
    _ = @import("boopsi/makeclass.zig");
    _ = @import("boopsi/newobjecttaglist.zig");
    _ = @import("boopsi/nextobject.zig");
    _ = @import("boopsi/removeclass.zig");
    _ = @import("boopsi/sendmessage.zig");
    _ = @import("boopsi/sendsupermessage.zig");
    _ = @import("boopsi/setattrstaglist.zig");
    _ = @import("boopsi/unlockclasslist.zig");
    _ = @import("image/_image.zig");
    _ = @import("image/drawimage.zig");
    _ = @import("image/drawimagestate.zig");
    _ = @import("image/eraseimage.zig");
    _ = @import("image/pointinimage.zig");
    _ = @import("screen/_screen.zig");
    _ = @import("screen/closescreen.zig");
    _ = @import("screen/freescreendrawinfo.zig");
    _ = @import("screen/getscreenattrs.zig");
    _ = @import("screen/getscreendrawinfo.zig");
    _ = @import("screen/lockpubscreen.zig");
    _ = @import("screen/openscreentaglist.zig");
    _ = @import("screen/screentoback.zig");
    _ = @import("screen/screentofront.zig");
    _ = @import("screen/unlockpubscreen.zig");
    _ = @import("window/_window.zig");
    _ = @import("window/activatewindow.zig");
    _ = @import("window/beginrefresh.zig");
    _ = @import("window/changewindowbox.zig");
    _ = @import("window/closewindow.zig");
    _ = @import("window/endrefresh.zig");
    _ = @import("window/getwindowattrs.zig");
    _ = @import("window/modifyidcmp.zig");
    _ = @import("window/movewindow.zig");
    _ = @import("window/openwindowtaglist.zig");
    _ = @import("window/refreshwindowframe.zig");
    _ = @import("window/sizewindow.zig");
    _ = @import("window/windowtoback.zig");
    _ = @import("window/windowtofront.zig");
    _ = @import("window/zipwindow.zig");
    _ = @import("window/setwindowtitles.zig");
    _ = @import("window/windowlimits.zig");
    _ = @import("gadget/ongadget.zig");
    _ = @import("gadget/offgadget.zig");
    _ = @import("request/easyrequestargs.zig");
    _ = @import("request/buildeasyrequestargs.zig");
    _ = @import("request/sysreqhandler.zig");
    _ = @import("request/freesysrequest.zig");
    _ = @import("request/_request.zig");
    _ = @import("render/_render.zig");
    _ = @import("gadget/_gadget.zig");
    _ = @import("gadget/addglist.zig");
    _ = @import("gadget/obtaingirport.zig");
    _ = @import("gadget/refreshglist.zig");
    _ = @import("gadget/releasegirport.zig");
    _ = @import("gadget/removeglist.zig");
    _ = @import("gadget/setgadgetattrstaglist.zig");
    _ = @import("render/drawborder.zig");
    _ = @import("render/intuitextlength.zig");
    _ = @import("render/printitext.zig");
    _ = @import("ibase/lockibase.zig");
    _ = @import("ibase/unlockibase.zig");
    _ = @import("input/_input.zig");
    _ = @import("classes/buttongclass.zig");
    _ = @import("classes/draw.zig");
    _ = @import("classes/fillrectclass.zig");
    _ = @import("classes/frameiclass.zig");
    _ = @import("classes/frbuttonclass.zig");
    _ = @import("classes/gadgetclass.zig");
    _ = @import("classes/groupgclass.zig");
    _ = @import("classes/icclass.zig");
    _ = @import("classes/imageclass.zig");
    _ = @import("classes/itexticlass.zig");
    _ = @import("classes/modelclass.zig");
    _ = @import("classes/propgclass.zig");
    _ = @import("classes/rootclass.zig");
    _ = @import("classes/strgclass.zig");
    _ = @import("classes/sysiclass.zig");
    _ = @import("menu/_menu.zig");
    _ = @import("menu/setmenustrip.zig");
    _ = @import("menu/clearmenustrip.zig");
    _ = @import("menu/resetmenustrip.zig");
    _ = @import("menu/itemaddress.zig");
    _ = @import("menu/onmenu.zig");
    _ = @import("menu/offmenu.zig");
    _ = @import("menu/lendmenus.zig");
    _ = @import("input/menus.zig");
    _ = @import("input/verify.zig");
    _ = @import("gadget/activategadget.zig");
    _ = @import("gadget/dogadgetmethoda.zig");
    _ = @import("requester/_requester.zig");
    _ = @import("requester/initrequester.zig");
    _ = @import("requester/request.zig");
    _ = @import("requester/endrequest.zig");
    _ = @import("requester/setdmrequest.zig");
    _ = @import("requester/cleardmrequest.zig");
    _ = @import("request/autorequesttaglist.zig");
    _ = @import("request/buildsysrequesttaglist.zig");
    _ = @import("input/doubleclick.zig");
}

/// exec on its test RAM, and every library this one stands on.
fn setUp() !*IntuitionBase {
    try kexec.setUp();
    _ = kexec.InitResident(kexec.SysBase, &kutility.utility_library_tag, null) orelse return error.NoUtility;
    _ = kexec.InitResident(kexec.SysBase, &krtg.rtg_library_tag, null) orelse return error.NoRtg;
    _ = kexec.InitResident(kexec.SysBase, &kgraphics.graphics_library_tag, null) orelse return error.NoGraphics;
    _ = kexec.InitResident(kexec.SysBase, &klayers.layers_library_tag, null) orelse return error.NoLayers;
    _ = kexec.InitResident(kexec.SysBase, &kkeymap.keymap_library_tag, null) orelse return error.NoKeymap;
    const made = kexec.InitResident(kexec.SysBase, &intuition_library_tag, null) orelse return error.NoIntuition;
    const ib: *IntuitionBase = @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(made))));
    // The tests' displays are 64 by 40 and laid out for the 8-row font.
    ib.font_height = 8;
    return ib;
}

/// Nothing here expunges itself, so the test gives back every class, every
/// open and every library.
fn tearDown(ib: *IntuitionBase) !void {
    try testing.expect(ib.iface().FreeClass(ib.string_class));
    try testing.expect(ib.iface().FreeClass(ib.itext_class));
    try testing.expect(ib.iface().FreeClass(ib.fillrect_class));
    try testing.expect(ib.iface().FreeClass(ib.group_class));
    try testing.expect(ib.iface().FreeClass(ib.frbutton_class));
    try testing.expect(ib.iface().FreeClass(ib.prop_class));
    try testing.expect(ib.iface().FreeClass(ib.button_class));
    try testing.expect(ib.iface().FreeClass(ib.gadget_class));
    try testing.expect(ib.iface().FreeClass(ib.sys_class));
    try testing.expect(ib.iface().FreeClass(ib.frame_class));
    try testing.expect(ib.iface().FreeClass(ib.model_class));
    try testing.expect(ib.iface().FreeClass(ib.ic_class));
    try testing.expect(ib.iface().FreeClass(ib.image_class));
    try testing.expect(ib.iface().FreeClass(ib.root_class));

    const gb: *kgraphics.GraphicsBase = @ptrCast(@alignCast(ib.graphics_base));
    const lb: *klayers.LayersBase = @ptrCast(@alignCast(ib.layers_base));
    const rb: *krtg.RtgBase = @ptrCast(@alignCast(gb.rtg_base));
    const ub: *kutility.UtilityBase = @ptrCast(@alignCast(ib.utility_base));

    const kb: *kkeymap.KeymapBase = @ptrCast(@alignCast(ib.keymap_base.?));
    kexec.CloseLibrary(kexec.SysBase, &kb.lib);
    kexec.Remove(kexec.SysBase, &kb.lib.node);
    kexec.freeLibraryMemory(kexec.SysBase, &kb.lib);

    kexec.CloseLibrary(kexec.SysBase, &lb.lib);
    kexec.CloseLibrary(kexec.SysBase, &gb.lib);
    kexec.CloseLibrary(kexec.SysBase, &ub.lib);
    kexec.Remove(kexec.SysBase, &ib.lib.node);
    kexec.freeLibraryMemory(kexec.SysBase, &ib.lib);

    kexec.CloseLibrary(kexec.SysBase, &gb.lib);
    kexec.CloseLibrary(kexec.SysBase, &ub.lib);
    kexec.Remove(kexec.SysBase, &lb.lib.node);
    kexec.freeLibraryMemory(kexec.SysBase, &lb.lib);

    kgraphics.freeOwnedForTests(gb);
    kexec.CloseLibrary(kexec.SysBase, &rb.lib);
    kexec.CloseLibrary(kexec.SysBase, &ub.lib);
    kexec.Remove(kexec.SysBase, &gb.lib.node);
    kexec.freeLibraryMemory(kexec.SysBase, &gb.lib);

    kexec.CloseLibrary(kexec.SysBase, &ub.lib);
    kexec.Remove(kexec.SysBase, &rb.lib.node);
    kexec.freeLibraryMemory(kexec.SysBase, &rb.lib);

    kutility.freeForTests(ub);
    try kexec.expectNoLeaks();
}

test "intuition.library: made from its tag, with its classes public" {
    const ib = try setUp();
    defer kexec.deinit();

    try testing.expectEqualStrings(LIBRARY_NAME, ib.lib.name());
    try testing.expectEqual(@as(u16, intuition_init.LIBRARY_REVISION), ib.lib.revision);
    try testing.expectEqual(ib.root_class.?, ib.iface().FindClass(classusr.ROOTCLASS).?);
    try testing.expectEqual(ib.image_class.?, ib.iface().FindClass(classusr.IMAGECLASS).?);
    try testing.expect(ib.iface().FindClass("nosuchclass") == null);

    try testing.expectEqual(ib.ic_class.?, ib.iface().FindClass(classusr.ICCLASS).?);
    try testing.expectEqual(ib.model_class.?, ib.iface().FindClass(classusr.MODELCLASS).?);

    // imageclass and icclass are made from rootclass, which they hold
    // there; modelclass from icclass.
    try testing.expectEqual(ib.root_class.?, ib.image_class.?.super.?);
    try testing.expectEqual(ib.root_class.?, ib.ic_class.?.super.?);
    try testing.expectEqual(ib.ic_class.?, ib.model_class.?.super.?);
    // gadgetclass is made from rootclass too, and buttongclass from it.
    try testing.expectEqual(ib.gadget_class.?, ib.iface().FindClass(classusr.GADGETCLASS).?);
    try testing.expectEqual(ib.button_class.?, ib.iface().FindClass(classusr.BUTTONGCLASS).?);
    try testing.expectEqual(ib.root_class.?, ib.gadget_class.?.super.?);
    try testing.expectEqual(ib.gadget_class.?, ib.button_class.?.super.?);
    try testing.expectEqual(@as(u32, 3), ib.root_class.?.subclass_count);
    try testing.expect(ib.root_class.?.super == null);

    // And the rest of them, each from the one it is a kind of.
    try testing.expectEqual(ib.prop_class.?, ib.iface().FindClass(classusr.PROPGCLASS).?);
    try testing.expectEqual(ib.frbutton_class.?, ib.iface().FindClass(classusr.FRBUTTONCLASS).?);
    try testing.expectEqual(ib.group_class.?, ib.iface().FindClass(classusr.GROUPGCLASS).?);
    try testing.expectEqual(ib.fillrect_class.?, ib.iface().FindClass(classusr.FILLRECTCLASS).?);
    try testing.expectEqual(ib.itext_class.?, ib.iface().FindClass(classusr.ITEXTICLASS).?);
    try testing.expectEqual(ib.gadget_class.?, ib.prop_class.?.super.?);
    try testing.expectEqual(ib.button_class.?, ib.frbutton_class.?.super.?);
    try testing.expectEqual(ib.gadget_class.?, ib.group_class.?.super.?);
    try testing.expectEqual(ib.image_class.?, ib.fillrect_class.?.super.?);
    try testing.expectEqual(ib.image_class.?, ib.itext_class.?.super.?);
    try testing.expectEqual(ib.string_class.?, ib.iface().FindClass(classusr.STRGCLASS).?);
    try testing.expectEqual(ib.gadget_class.?, ib.string_class.?.super.?);

    try testing.expectEqual(&ib.lib, kexec.OpenLibrary(kexec.SysBase, LIBRARY_NAME, intuition_init.LIBRARY_VERSION).?);
    kexec.CloseLibrary(kexec.SysBase, &ib.lib);
    try testing.expect(intuition_base.expunge(&ib.lib) == null);

    try tearDown(ib);
}

test "MakeClass: names, superclasses, offsets, and FreeClass waits for the last user" {
    const ib = try setUp();
    defer kexec.deinit();

    // A name taken, and a superclass that is not there.
    try testing.expect(ib.iface().MakeClass(classusr.IMAGECLASS, classusr.ROOTCLASS, null, 4) == null);
    try testing.expect(ib.iface().MakeClass("mine", "nosuchclass", null, 4) == null);

    // A private class made from imageclass by name: its data starts past
    // imageclass's, rounded up to 8. imageclass already has subclasses of
    // this library's own, so its count is watched from where it starts.
    const image_subclasses = ib.image_class.?.subclass_count;
    const private = ib.iface().MakeClass(null, classusr.IMAGECLASS, null, 3).?;
    try testing.expect(private.id == null);
    try testing.expectEqual(ib.image_class.?, private.super.?);
    try testing.expectEqual(@as(u32, 0), private.inst_offset % 8);
    try testing.expect(private.inst_offset >= ib.image_class.?.inst_offset + ib.image_class.?.inst_size);
    try testing.expectEqual(image_subclasses + 1, ib.image_class.?.subclass_count);

    // A private class cannot be made public; it is used by pointer.
    ib.iface().AddClass(private);
    try testing.expectEqual(@as(u32, 0), private.flags & intuition.classes.CLF_INLIST);

    // A class made from the private one, by pointer, holds it.
    const below = ib.iface().MakeClass("belowclass", null, private, 0).?;
    ib.iface().AddClass(below);
    try testing.expectEqual(below, ib.iface().FindClass("belowclass").?);
    try testing.expect(!ib.iface().FreeClass(private));

    // Freeing takes it off the list whatever happens; this one goes.
    try testing.expect(ib.iface().FreeClass(below));
    try testing.expect(ib.iface().FindClass("belowclass") == null);
    try testing.expectEqual(@as(u32, 0), private.subclass_count);
    try testing.expect(ib.iface().FreeClass(private));
    try testing.expectEqual(image_subclasses, ib.image_class.?.subclass_count);
    try testing.expect(ib.iface().FreeClass(null));

    try tearDown(ib);
}

/// A subclass of rootclass with a counter in each object: OM_NEW passes
/// up first and then sets its own part from the tags; OM_SET and OM_GET
/// are its own; everything else goes up.
const Counter = extern struct { value: u32, messages: u32 };
const COUNTER_Value = utility.TAG_USER + 1;

fn counterDispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *Class = @ptrCast(hook);
    const ib: *IntuitionBase = @ptrFromInt(cl.user_data);
    const msg: *Msg = @ptrCast(@alignCast(message.?));
    const o: ?*Object = @ptrCast(object);
    switch (msg.method_id) {
        classusr.OM_NEW => {
            const made = ib.iface().SendSuperMessage(cl, o, msg);
            if (made == 0) return 0;
            const data = intuition.instData(Counter, cl, @ptrFromInt(made));
            const new: *classusr.OpSet = @ptrCast(@alignCast(msg));
            data.value = @intCast(ib.utility_base.GetTagData(COUNTER_Value, 7, new.attr_list));
            return made;
        },
        classusr.OM_SET => {
            const data = intuition.instData(Counter, cl, o.?);
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            data.value = @intCast(ib.utility_base.GetTagData(COUNTER_Value, data.value, set.attr_list));
            data.messages += 1;
            return 1;
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            if (get.attr_id != COUNTER_Value) return 0;
            get.storage.* = intuition.instData(Counter, cl, o.?).value;
            return 1;
        },
        else => return ib.iface().SendSuperMessage(cl, o, msg),
    }
}

test "objects: made by pointer and by name, set, read, counted and freed" {
    const ib = try setUp();
    defer kexec.deinit();

    const cl = ib.iface().MakeClass("counterclass", classusr.ROOTCLASS, null, @sizeOf(Counter)).?;
    cl.dispatcher.entry = &counterDispatch;
    cl.user_data = @intFromPtr(ib);

    // Not public yet: by name there is nothing, by pointer there is.
    try testing.expect(ib.iface().NewObjectTagList(null, "counterclass", null) == null);
    const first = ib.iface().NewObjectTagList(cl, null, null).?;
    try testing.expectEqual(cl, intuition.objectClass(first));
    try testing.expectEqual(@as(u32, 7), intuition.instData(Counter, cl, first).value);

    ib.iface().AddClass(cl);
    const tags = [_]TagItem{ .{ .tag = COUNTER_Value, .data = 42 }, .{} };
    const second = ib.iface().NewObjectTagList(null, "counterclass", &tags).?;
    try testing.expectEqual(@as(u32, 2), cl.object_count);

    // Set and read back through the library's calls.
    var got: usize = 0;
    try testing.expectEqual(@as(u32, 1), ib.iface().GetAttr(COUNTER_Value, second, &got));
    try testing.expectEqual(@as(usize, 42), got);
    const change = [_]TagItem{ .{ .tag = COUNTER_Value, .data = 9 }, .{} };
    try testing.expectEqual(@as(u32, 1), ib.iface().SetAttrsTagList(second, &change));
    try testing.expectEqual(@as(u32, 1), ib.iface().GetAttr(COUNTER_Value, second, &got));
    try testing.expectEqual(@as(usize, 9), got);
    // An attribute nobody knows reaches rootclass, which answers 0.
    try testing.expectEqual(@as(u32, 0), ib.iface().GetAttr(utility.TAG_USER + 99, second, &got));

    // Null objects are harmless everywhere.
    try testing.expectEqual(@as(u32, 0), ib.iface().SetAttrsTagList(null, &change));
    ib.iface().DisposeObject(null);

    // A class with objects stays, off the list; the last dispose lets it go.
    try testing.expect(!ib.iface().FreeClass(cl));
    try testing.expectEqual(@as(u32, 0), cl.flags & intuition.classes.CLF_INLIST);
    ib.iface().DisposeObject(first);
    ib.iface().DisposeObject(second);
    try testing.expectEqual(@as(u32, 0), cl.object_count);
    // Every count change took the class list and gave it back.
    try testing.expectEqual(@as(i16, 0), ib.class_lock.nest_count);
    try testing.expect(ib.iface().FreeClass(cl));

    try tearDown(ib);
}

test "OM_ADDTAIL, NextObject and OM_REMOVE: a list of objects, emptied while walked" {
    const ib = try setUp();
    defer kexec.deinit();

    var members: exec.MinList = .{};
    members.init();
    var made: [3]*Object = undefined;
    for (&made) |*o| {
        o.* = ib.iface().NewObjectTagList(null, classusr.IMAGECLASS, null).?;
        var add = classusr.OpAddTail{ .method_id = classusr.OM_ADDTAIL, .list = &members };
        try testing.expectEqual(@as(usize, 1), ib.iface().SendMessage(o.*, @ptrCast(&add)));
    }

    var at = members.head;
    var seen: usize = 0;
    while (ib.iface().NextObject(&at)) |o| : (seen += 1) {
        try testing.expectEqual(made[seen], o);
        var remove = Msg{ .method_id = classusr.OM_REMOVE };
        _ = ib.iface().SendMessage(o, &remove);
        ib.iface().DisposeObject(o);
    }
    try testing.expectEqual(@as(usize, 3), seen);
    try testing.expect(members.isEmpty());
    try testing.expectEqual(@as(u32, 0), ib.image_class.?.object_count);

    try tearDown(ib);
}

test "imageclass: attributes, hit tests, and a shape drawn in its pens" {
    const ib = try setUp();
    defer kexec.deinit();
    const gb = ib.graphics_base;

    // An eight-by-two shape: the top row alternate pixels, the bottom row
    // all clear.
    const shape = [_]u8{ 0b1010_1010, 0b0000_0000 };
    const red = graphics.penRGB(255, 0, 0);
    const tags = [_]TagItem{
        .{ .tag = ic.IA_Left, .data = 2 },
        .{ .tag = ic.IA_Top, .data = 1 },
        .{ .tag = ic.IA_Width, .data = 8 },
        .{ .tag = ic.IA_Height, .data = 2 },
        .{ .tag = ic.IA_FGPen, .data = red },
        .{ .tag = ic.IA_Data, .data = @intFromPtr(&shape) },
        .{},
    };
    const image = ib.iface().NewObjectTagList(null, classusr.IMAGECLASS, &tags).?;

    // Read back, the pointer included, and the default for what was not
    // given.
    var got: usize = 0;
    try testing.expectEqual(@as(u32, 1), ib.iface().GetAttr(ic.IA_Width, image, &got));
    try testing.expectEqual(@as(usize, 8), got);
    try testing.expectEqual(@as(u32, 1), ib.iface().GetAttr(ic.IA_Data, image, &got));
    try testing.expectEqual(@intFromPtr(&shape), got);
    got = 0;
    try testing.expectEqual(@as(u32, 1), ib.iface().GetAttr(ic.IA_BGPen, image, &got));
    try testing.expectEqual(@as(usize, 0), got);

    // A hit test is the box; a frame test the message's size at its corner.
    var hit = ic.ImpHitTest{ .method_id = ic.IM_HITTEST, .point = .{ .x = 9, .y = 2 } };
    try testing.expectEqual(@as(usize, 1), ib.iface().SendMessage(image, @ptrCast(&hit)));
    hit.point = .{ .x = 10, .y = 2 };
    try testing.expectEqual(@as(usize, 0), ib.iface().SendMessage(image, @ptrCast(&hit)));
    hit = .{ .method_id = ic.IM_HITFRAME, .point = .{ .x = 20, .y = 2 }, .dimensions = .{ .width = 30, .height = 5 } };
    try testing.expectEqual(@as(usize, 1), ib.iface().SendMessage(image, @ptrCast(&hit)));

    // A RastPort on sixteen by four pixels of memory, blue all over.
    var pixels: [16 * 4]u32 = @splat(0xFF0000FF);
    var surface = sdk.rtg.Surface{
        .pixels = @ptrCast(&pixels),
        .width = 16,
        .height = 4,
        .pitch = 16 * 4,
        .size_bytes = @sizeOf(@TypeOf(pixels)),
        .format = .bgra32,
    };
    const on = [_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) },
        .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(0, 255, 0) },
        .{ .tag = graphics.RPTAG_BPen, .data = graphics.penRGB(1, 2, 3) },
        .{},
    };
    const rp = gb.CreateRastPortTagList(&on).?;

    // Drawn at an offset of one across: set bits red, clear bits left
    // alone, since the background pen is transparent.
    var draw = ic.ImpDraw{ .method_id = ic.IM_DRAW, .rast_port = rp, .offset = .{ .x = 1, .y = 0 } };
    try testing.expectEqual(@as(usize, 1), ib.iface().SendMessage(image, @ptrCast(&draw)));
    for (0..8) |i| {
        const want: u32 = if (i % 2 == 0) 0xFFFF0000 else 0xFF0000FF;
        try testing.expectEqual(want, pixels[1 * 16 + 3 + i]);
        try testing.expectEqual(@as(u32, 0xFF0000FF), pixels[2 * 16 + 3 + i]);
    }
    try testing.expectEqual(@as(u32, 0xFF0000FF), pixels[1 * 16 + 2]);

    // The RastPort is as it was.
    var apen: u32 = 0;
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = @intFromPtr(&apen) }, .{} };
    gb.GetRPAttrs(rp, &ask);
    try testing.expectEqual(graphics.penRGB(0, 255, 0), apen);

    // With a background pen, the clear bits take it - drawn through
    // IM_DRAWFRAME, which draws as IM_DRAW.
    const white = [_]TagItem{ .{ .tag = ic.IA_BGPen, .data = graphics.penRGB(255, 255, 255) }, .{} };
    try testing.expectEqual(@as(u32, 1), ib.iface().SetAttrsTagList(image, &white));
    draw.method_id = ic.IM_DRAWFRAME;
    try testing.expectEqual(@as(usize, 1), ib.iface().SendMessage(image, @ptrCast(&draw)));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), pixels[1 * 16 + 4]);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), pixels[2 * 16 + 3]);

    // Erased: the box in the RastPort's own background pen.
    var erase = ic.ImpErase{ .method_id = ic.IM_ERASE, .rast_port = rp, .offset = .{ .x = 1, .y = 0 } };
    try testing.expectEqual(@as(usize, 1), ib.iface().SendMessage(image, @ptrCast(&erase)));
    try testing.expectEqual(graphics.penRGB(1, 2, 3), pixels[1 * 16 + 3]);
    try testing.expectEqual(graphics.penRGB(1, 2, 3), pixels[2 * 16 + 10]);
    try testing.expectEqual(@as(u32, 0xFF0000FF), pixels[2 * 16 + 11]);

    // Anything imageclass does not know goes to rootclass: 0.
    var frame = Msg{ .method_id = ic.IM_FRAMEBOX };
    try testing.expectEqual(@as(usize, 0), ib.iface().SendMessage(image, &frame));

    ib.iface().DisposeObject(image);
    gb.FreeRastPort(rp);
    try tearDown(ib);
}

/// A subclass of rootclass that counts the updates it is sent and keeps
/// the last value of one tag - a target and a member for the tests.
const Recorder = extern struct { updates: u32, last: usize };
const REC_Value = utility.TAG_USER + 10;
const SLIDER_Position = utility.TAG_USER + 11;

fn recorderDispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *Class = @ptrCast(hook);
    const ib: *IntuitionBase = @ptrFromInt(cl.user_data);
    const msg: *Msg = @ptrCast(@alignCast(message.?));
    const o: ?*Object = @ptrCast(object);
    if (msg.method_id != classusr.OM_UPDATE) return ib.iface().SendSuperMessage(cl, o, msg);
    const up: *classusr.OpUpdate = @ptrCast(@alignCast(msg));
    const r = intuition.instData(Recorder, cl, o.?);
    r.updates += 1;
    r.last = ib.utility_base.GetTagData(REC_Value, r.last, up.attr_list);
    return 1;
}

fn recorderClass(ib: *IntuitionBase) *Class {
    const cl = ib.iface().MakeClass(null, classusr.ROOTCLASS, null, @sizeOf(Recorder)).?;
    cl.dispatcher.entry = &recorderDispatch;
    cl.user_data = @intFromPtr(ib);
    return cl;
}

fn notify(ib: *IntuitionBase, o: *Object, tags: [*]const TagItem) void {
    var msg = classusr.OpUpdate{ .method_id = classusr.OM_NOTIFY, .attr_list = tags };
    _ = ib.iface().SendMessage(o, @ptrCast(&msg));
}

test "icclass: passes updates to its target through its map, and stops a loop" {
    const ib = try setUp();
    defer kexec.deinit();
    const icc = intuition.icclass;
    const rec_class = recorderClass(ib);
    const target = ib.iface().NewObjectTagList(rec_class, null, null).?;

    // The sender says "position", the target listens for "value".
    const map = [_]TagItem{ .{ .tag = SLIDER_Position, .data = REC_Value }, .{} };
    const make = [_]TagItem{
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(target) },
        .{ .tag = icc.ICA_MAP, .data = @intFromPtr(&map) },
        .{},
    };
    const link = ib.iface().NewObjectTagList(null, classusr.ICCLASS, &make).?;
    const said = [_]TagItem{ .{ .tag = SLIDER_Position, .data = 5 }, .{} };
    notify(ib, link, &said);
    const r = intuition.instData(Recorder, rec_class, target);
    try testing.expectEqual(@as(u32, 1), r.updates);
    try testing.expectEqual(@as(usize, 5), r.last);
    // The sender's own list is as it sent it.
    try testing.expectEqual(SLIDER_Position, said[0].tag);

    // The target and the map are not read back.
    var got: usize = 0;
    try testing.expectEqual(@as(u32, 0), ib.iface().GetAttr(icc.ICA_TARGET, link, &got));

    // No target passes nothing on.
    const none = [_]TagItem{ .{ .tag = icc.ICA_TARGET, .data = 0 }, .{} };
    _ = ib.iface().SetAttrsTagList(link, &none);
    notify(ib, link, &said);
    try testing.expectEqual(@as(u32, 1), r.updates);

    // Two connections that are each other's targets: one round, then quiet.
    const other_make = [_]TagItem{ .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(link) }, .{} };
    const other = ib.iface().NewObjectTagList(null, classusr.ICCLASS, &other_make).?;
    const back = [_]TagItem{ .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(other) }, .{} };
    _ = ib.iface().SetAttrsTagList(link, &back);
    notify(ib, link, &said);
    var loop = Msg{ .method_id = icc.ICM_CHECKLOOP };
    try testing.expectEqual(@as(usize, 0), ib.iface().SendMessage(link, &loop));
    try testing.expectEqual(@as(usize, 0), ib.iface().SendMessage(other, &loop));

    ib.iface().DisposeObject(other);
    ib.iface().DisposeObject(link);
    ib.iface().DisposeObject(target);
    try testing.expect(ib.iface().FreeClass(rec_class));
    try tearDown(ib);
}

test "modelclass: every member told, then the target; members go with the model" {
    const ib = try setUp();
    defer kexec.deinit();
    const icc = intuition.icclass;
    const rec_class = recorderClass(ib);
    const target = ib.iface().NewObjectTagList(rec_class, null, null).?;
    const first = ib.iface().NewObjectTagList(rec_class, null, null).?;
    const second = ib.iface().NewObjectTagList(rec_class, null, null).?;

    const make = [_]TagItem{ .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(target) }, .{} };
    const model = ib.iface().NewObjectTagList(null, classusr.MODELCLASS, &make).?;
    for ([_]*Object{ first, second }) |member| {
        var add = classusr.OpMember{ .method_id = classusr.OM_ADDMEMBER, .object = member };
        try testing.expectEqual(@as(usize, 1), ib.iface().SendMessage(model, @ptrCast(&add)));
    }

    const said = [_]TagItem{ .{ .tag = REC_Value, .data = 42 }, .{} };
    notify(ib, model, &said);
    for ([_]*Object{ first, second, target }) |o| {
        const r = intuition.instData(Recorder, rec_class, o);
        try testing.expectEqual(@as(u32, 1), r.updates);
        try testing.expectEqual(@as(usize, 42), r.last);
    }

    // Out of the model, out of the broadcast - and no longer the model's
    // to dispose of.
    var rem = classusr.OpMember{ .method_id = classusr.OM_REMMEMBER, .object = first };
    _ = ib.iface().SendMessage(model, @ptrCast(&rem));
    notify(ib, model, &said);
    try testing.expectEqual(@as(u32, 1), intuition.instData(Recorder, rec_class, first).updates);
    try testing.expectEqual(@as(u32, 2), intuition.instData(Recorder, rec_class, second).updates);

    // The model takes its remaining member with it.
    try testing.expectEqual(@as(u32, 3), rec_class.object_count);
    ib.iface().DisposeObject(model);
    try testing.expectEqual(@as(u32, 2), rec_class.object_count);

    ib.iface().DisposeObject(first);
    ib.iface().DisposeObject(target);
    try testing.expect(ib.iface().FreeClass(rec_class));
    try tearDown(ib);
}

test "DrawImage, EraseImage and PointInImage send the image methods" {
    const ib = try setUp();
    defer kexec.deinit();
    const gb = ib.graphics_base;

    const shape = [_]u8{0b1100_0000};
    const tags = [_]TagItem{
        .{ .tag = ic.IA_Width, .data = 2 },
        .{ .tag = ic.IA_Height, .data = 1 },
        .{ .tag = ic.IA_FGPen, .data = graphics.penRGB(255, 255, 255) },
        .{ .tag = ic.IA_Data, .data = @intFromPtr(&shape) },
        .{},
    };
    const image = ib.iface().NewObjectTagList(null, classusr.IMAGECLASS, &tags).?;

    var pixels: [4 * 2]u32 = @splat(0xFF000000);
    var surface = sdk.rtg.Surface{
        .pixels = @ptrCast(&pixels),
        .width = 4,
        .height = 2,
        .pitch = 4 * 4,
        .size_bytes = @sizeOf(@TypeOf(pixels)),
        .format = .bgra32,
    };
    const on = [_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) },
        .{ .tag = graphics.RPTAG_BPen, .data = graphics.penRGB(0, 0, 128) },
        .{},
    };
    const rp = gb.CreateRastPortTagList(&on).?;

    ib.iface().DrawImage(rp, image, 1, 1);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), pixels[4 + 1]);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), pixels[4 + 2]);
    try testing.expectEqual(@as(u32, 0xFF000000), pixels[4 + 3]);
    ib.iface().EraseImage(rp, image, 1, 1);
    try testing.expectEqual(graphics.penRGB(0, 0, 128), pixels[4 + 1]);
    try testing.expectEqual(@as(u32, 0xFF000000), pixels[4 + 3]);

    // Null draws nothing and contains everything.
    ib.iface().DrawImage(rp, null, 0, 0);
    try testing.expect(ib.iface().PointInImage(1000, 1000, null));
    try testing.expect(ib.iface().PointInImage(1, 0, image));
    try testing.expect(!ib.iface().PointInImage(2, 0, image));

    ib.iface().DisposeObject(image);
    gb.FreeRastPort(rp);
    try tearDown(ib);
}

/// A display for the screen tests: the fake board, showing a 64 by 40
/// buffer of its display memory.
const Display = struct {
    state: *fake.State,
    board: *sdk.rtg.RtgBoard,
    bitmap: *sdk.rtg.RtgBitMap,

    fn up(ib: *IntuitionBase) !Display {
        return sized(ib, 64, 40, .rgb565);
    }

    fn sized(ib: *IntuitionBase, width: u32, height: u32, format: sdk.rtg.bitmaps.PixelFormat) !Display {
        const gb: *kgraphics.GraphicsBase = @ptrCast(@alignCast(ib.graphics_base));
        const rb: *sdk.interface.rtg.RtgBase = @ptrCast(@alignCast(gb.rtg_base));
        const state = fake.create(ib.sys_base) orelse return error.NoDriver;
        try testing.expect(rb.AddRtgDriver(&state.driver));
        const empty = [_]TagItem{.{}};
        const board = rb.CreateBoardTagList(fake.DRIVER_NAME, &empty) orelse return error.NoBoard;
        const bitmap = rb.AllocBitMap(board, width, height, @intFromEnum(format), sdk.rtg.bitmaps.RTGBMF_DISPLAYABLE) orelse return error.NoBitMap;
        try testing.expectEqual(sdk.rtg.errors.RTGERR_OK, rb.ShowBitMap(board, bitmap, 0, 0));
        return .{ .state = state, .board = board, .bitmap = bitmap };
    }

    fn down(d: Display, ib: *IntuitionBase) void {
        const gb: *kgraphics.GraphicsBase = @ptrCast(@alignCast(ib.graphics_base));
        const rb: *sdk.interface.rtg.RtgBase = @ptrCast(@alignCast(gb.rtg_base));
        rb.FreeBitMap(d.bitmap);
        rb.DeleteBoard(d.board);
        _ = rb.RemRtgDriver(&d.state.driver);
        fake.destroy(d.state);
    }

    fn pixel(d: Display, x: usize, y: usize) u16 {
        const row = d.bitmap.pixels.? + y * d.bitmap.pitch;
        return @as([*]const u16, @ptrCast(@alignCast(row)))[x];
    }
};

fn screenAttr(ib: *IntuitionBase, s: *intuition.Screen, tag: utility.Tag) usize {
    var value: usize = 0;
    const ask = [_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} };
    ib.iface().GetScreenAttrs(s, &ask);
    return value;
}

test "screens: none without a display, one to a display, and closed again" {
    const ib = try setUp();
    defer kexec.deinit();
    const sc = intuition.screens;

    var why: u32 = 0;
    const with_code = [_]TagItem{ .{ .tag = sc.SA_ErrorCode, .data = @intFromPtr(&why) }, .{} };
    try testing.expect(ib.iface().OpenScreenTagList(&with_code) == null);
    try testing.expectEqual(sc.OSERR_NOMONITOR, why);

    const display = try Display.up(ib);
    const tags = [_]TagItem{
        .{ .tag = sc.SA_Title, .data = @intFromPtr("Test") },
        .{ .tag = sc.SA_ErrorCode, .data = @intFromPtr(&why) },
        .{},
    };
    const s = ib.iface().OpenScreenTagList(&tags).?;
    try testing.expectEqual(@as(usize, 64), screenAttr(ib, s, sc.SA_Width));
    try testing.expectEqual(@as(usize, 40), screenAttr(ib, s, sc.SA_Height));
    try testing.expectEqual(@as(usize, 16), screenAttr(ib, s, sc.SA_Depth));
    // Pospaz 8, a border above and below, and the trim line.
    try testing.expectEqual(@as(usize, 8 + 2 + 1), screenAttr(ib, s, sc.SA_BarHeight));
    try testing.expect(screenAttr(ib, s, sc.SA_RastPort) != 0);
    try testing.expectEqual(@as(usize, 0), screenAttr(ib, s, sc.SA_PubName));

    // The ground in the background pen, the bar in its fill, the trim line
    // under it - rgb565: grey 0xAAAAAA is 0xAD55, white 0xFFFF, black 0.
    try testing.expectEqual(@as(u16, 0xAD55), display.pixel(10, 30));
    try testing.expectEqual(@as(u16, 0xFFFF), display.pixel(63, 1));
    try testing.expectEqual(@as(u16, 0x0000), display.pixel(20, 10));
    // Some of the title is drawn, in black, somewhere in the bar.
    var ink: usize = 0;
    for (0..40) |x| {
        for (1..9) |y| {
            if (display.pixel(x, y) == 0) ink += 1;
        }
    }
    try testing.expect(ink > 10);

    // The pens, as the DrawInfo hands them out.
    const dri = ib.iface().GetScreenDrawInfo(s);
    try testing.expectEqual(sc.DRI_VERSION, dri.version);
    try testing.expectEqual(graphics.penRGB(0x66, 0x88, 0xBB), dri.pens[sc.FILLPEN]);
    try testing.expectEqual(@as(u32, 16), dri.depth);

    // A second screen on the same display is refused.
    try testing.expect(ib.iface().OpenScreenTagList(&with_code) == null);
    try testing.expectEqual(sc.OSERR_NOTAVAILABLE, why);

    try testing.expect(ib.iface().CloseScreen(s));
    try testing.expectEqual(@as(u16, 0), display.pixel(10, 30));
    try testing.expect(ib.iface().CloseScreen(null));
    display.down(ib);
    try tearDown(ib);
}

test "public screens: the default opened on first use, locks keep it open" {
    const ib = try setUp();
    defer kexec.deinit();
    const sc = intuition.screens;
    const display = try Display.up(ib);

    // A name that nobody opened is not opened for the asking.
    try testing.expect(ib.iface().LockPubScreen("Nobody") == null);

    const wb = ib.iface().LockPubScreen(null).?;
    const name: [*:0]const u8 = @ptrFromInt(screenAttr(ib, wb, sc.SA_PubName));
    try testing.expectEqualStrings(sc.WBENCHNAME, std.mem.span(name));
    // Locked twice, once by name and once as the default: the same screen.
    try testing.expectEqual(wb, ib.iface().LockPubScreen(sc.WBENCHNAME).?);

    try testing.expect(!ib.iface().CloseScreen(wb));
    ib.iface().UnlockPubScreen(null, wb);
    try testing.expect(!ib.iface().CloseScreen(wb));
    ib.iface().UnlockPubScreen(sc.WBENCHNAME, null);
    try testing.expect(ib.iface().CloseScreen(wb));

    // A public name is unique, and a long one refused.
    var why: u32 = 0;
    const named = [_]TagItem{
        .{ .tag = sc.SA_PubName, .data = @intFromPtr("Mine") },
        .{ .tag = sc.SA_ShowTitle, .data = 0 },
        .{ .tag = sc.SA_ErrorCode, .data = @intFromPtr(&why) },
        .{},
    };
    const mine = ib.iface().OpenScreenTagList(&named).?;
    try testing.expectEqual(@as(usize, 0), screenAttr(ib, mine, sc.SA_BarHeight));
    try testing.expect(ib.iface().OpenScreenTagList(&named) == null);
    try testing.expectEqual(sc.OSERR_PUBNOTUNIQUE, why);
    const long = [_]TagItem{
        .{ .tag = sc.SA_PubName, .data = @intFromPtr("A name much longer than thirty-one characters") },
        .{ .tag = sc.SA_ErrorCode, .data = @intFromPtr(&why) },
        .{},
    };
    try testing.expect(ib.iface().OpenScreenTagList(&long) == null);
    try testing.expectEqual(sc.OSERR_BADNAME, why);
    try testing.expect(ib.iface().CloseScreen(mine));

    display.down(ib);
    try tearDown(ib);
}

fn windowAttr(ib: *IntuitionBase, w: *intuition.Window, tag: utility.Tag) usize {
    var value: usize = 0;
    const ask = [_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} };
    ib.iface().GetWindowAttrs(w, &ask);
    return value;
}

/// Every message waiting on a window's port, replied, as their classes in
/// the order they came.
fn drainClasses(ib: *IntuitionBase, w: *intuition.Window, out: []u32) usize {
    const port: *exec.MsgPort = @ptrFromInt(windowAttr(ib, w, intuition.windows.WA_UserPort));
    var n: usize = 0;
    while (ib.sys_base.GetMsg(port)) |m| {
        const im: *intuition.IntuiMessage = @ptrCast(@alignCast(m));
        if (n < out.len) out[n] = im.class;
        n += 1;
        ib.sys_base.ReplyMsg(m);
    }
    return n;
}

/// A backfill hook that paints one colour and counts what it was asked for.
const Ground = struct {
    var calls: u32 = 0;
    var area: graphics.Rect = .{};
    const pen = graphics.penRGB(0, 255, 0);

    fn paint(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
        const gb: *sdk.interface.graphics.GraphicsBase = @ptrCast(@alignCast(hook.data.?));
        const rp: *graphics.RastPort = @ptrCast(@alignCast(object.?));
        const msg: *graphics.BackFillMsg = @ptrCast(@alignCast(message.?));
        calls += 1;
        area = msg.area;
        const set = [_]TagItem{
            .{ .tag = graphics.RPTAG_APen, .data = pen },
            .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 },
            .{},
        };
        gb.SetRPAttrs(rp, &set);
        gb.RectFill(rp, &msg.area);
        return 0;
    }
};

test "an image erased in a window leaves the window's own ground behind" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const it = ib.iface();
    const gb = ib.graphics_base;
    const display = try Display.up(ib);

    Ground.calls = 0;
    var hook = utility.Hook{ .entry = &Ground.paint, .data = gb };

    // A window that paints its ground itself, and a block pen that is not
    // that ground - so an erase that used the pen and an erase that used
    // the hook cannot be mistaken for one another.
    const wrong = graphics.penRGB(255, 0, 0);
    const w = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 40 },
        .{ .tag = wn.WA_Borderless, .data = 1 },
        .{ .tag = wn.WA_BackFill, .data = @intFromPtr(&hook) },
        .{ .tag = wn.WA_BlockPen, .data = wrong },
        .{},
    }).?;
    try testing.expect(Ground.calls > 0); // it painted the window when it opened

    // An image drawn and then taken off again.
    const image = it.NewObjectTagList(null, classusr.FILLRECTCLASS, &[_]TagItem{
        .{ .tag = ic.IA_Width, .data = 10 },
        .{ .tag = ic.IA_Height, .data = 10 },
        .{ .tag = ic.IA_FGPen, .data = graphics.penRGB(0, 0, 255) },
        .{},
    }).?;
    const plain = it.NewObjectTagList(null, classusr.IMAGECLASS, &[_]TagItem{
        .{ .tag = ic.IA_Width, .data = 10 },
        .{ .tag = ic.IA_Height, .data = 10 },
        .{},
    }).?;
    const rp: *graphics.RastPort = @ptrFromInt(windowAttr(ib, w, wn.WA_RastPort));
    const layer: *sdk.layers.Layer = @ptrFromInt(windowAttr(ib, w, wn.WA_Layer));

    ib.layers_base.LockLayer(layer);
    ib.iface().DrawImage(rp, image, 4, 4);
    ib.layers_base.UnlockLayer(layer);
    try testing.expectEqual(@as(u16, 0x001F), display.pixel(6, 6));

    // Erased through imageclass: the window's ground comes back, not the
    // block pen, and not a hole.
    Ground.calls = 0;
    ib.layers_base.LockLayer(layer);
    ib.iface().EraseImage(rp, plain, 4, 4);
    ib.layers_base.UnlockLayer(layer);
    try testing.expectEqual(@as(u32, 1), Ground.calls);
    try testing.expectEqual(@as(u16, 0x07E0), display.pixel(6, 6));

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    ib.iface().CloseWindow(w);
    try testing.expect(ib.iface().CloseScreen(screen));
    it.DisposeObject(plain);
    it.DisposeObject(image);
    display.down(ib);
    try tearDown(ib);
}

test "windows: its own pens, the flag word in bulk, and a place it may not be moved from" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const gc = intuition.gadgetclass;
    const it = ib.iface();
    const display = try Display.up(ib);
    const paint = paintClass(ib);

    const ink = graphics.penRGB(255, 0, 255);
    const ground = graphics.penRGB(0, 128, 0);
    const g = it.NewObjectTagList(paint, null, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 2 },
        .{ .tag = gc.GA_Top, .data = 2 },
        .{ .tag = gc.GA_Width, .data = 8 },
        .{ .tag = gc.GA_Height, .data = 8 },
        .{},
    }).?;

    // WA_Flags carries the whole word; the close gadget comes from it and
    // not from a tag of its own.
    const w = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 40 },
        .{ .tag = wn.WA_Height, .data = 30 },
        .{ .tag = wn.WA_Flags, .data = wn.WFLG_CLOSEGADGET | wn.WFLG_DRAGBAR },
        .{ .tag = wn.WA_DetailPen, .data = ink },
        .{ .tag = wn.WA_BlockPen, .data = ground },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(g) },
        .{},
    }).?;
    const win: *_window.Window = @ptrCast(@alignCast(w));
    try testing.expect(win.flags & wn.WFLG_CLOSEGADGET != 0);
    try testing.expect(win.flags & wn.WFLG_DRAGBAR != 0);

    // A gadget is told the window's pens, not only the screen's, so it can
    // look like the window it is on.
    const gi = _gadget.info(win);
    try testing.expectEqual(@as(u32, ink), gi.detail_pen);
    try testing.expectEqual(@as(u32, ground), gi.block_pen);

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    ib.iface().CloseWindow(w);

    // A window that says where it goes is put there or not at all: this one
    // is off the right of a 64-wide display and may not be moved.
    try testing.expect(ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 40 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 40 },
        .{ .tag = wn.WA_Height, .data = 20 },
        .{},
    }) == null);

    // The same window, told it may be adjusted, opens - moved onto the
    // display rather than refused.
    const moved = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 40 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 40 },
        .{ .tag = wn.WA_Height, .data = 20 },
        .{ .tag = wn.WA_AutoAdjust, .data = 1 },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 24), windowAttr(ib, moved, wn.WA_Left));
    ib.iface().CloseWindow(moved);

    try testing.expect(ib.iface().CloseScreen(screen));
    it.DisposeObject(g);
    try testing.expect(ib.iface().FreeClass(paint));
    display.down(ib);
    try tearDown(ib);
}

/// Counts the times a window asks for a part of itself to be painted.
const Painter = struct {
    var calls: u32 = 0;
    fn paint(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
        _ = hook;
        _ = object;
        _ = message;
        calls += 1;
        return 0;
    }
};

test "windows: GimmeZeroZero gives the program the inside and keeps the border" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const gc = intuition.gadgetclass;
    const it = ib.iface();
    const gb = ib.graphics_base;
    const display = try Display.up(ib);
    const paint = paintClass(ib);
    const told_class = toldClass(ib);

    // A gadget at the very corner of the program's part, and one that
    // paints, so where each lands can be read off the display.
    const g = it.NewObjectTagList(told_class, null, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 0 },
        .{ .tag = gc.GA_Top, .data = 0 },
        .{ .tag = gc.GA_Width, .data = 6 },
        .{ .tag = gc.GA_Height, .data = 6 },
        .{},
    }).?;

    const w = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 40 },
        .{ .tag = wn.WA_Title, .data = @intFromPtr("T") },
        .{ .tag = wn.WA_GimmeZeroZero, .data = 1 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(g) },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{},
    }).?;
    const win: *_window.Window = @ptrCast(@alignCast(w));
    try testing.expect(win.inner_layer != null);

    const bl: i32 = @intCast(windowAttr(ib, w, wn.WA_BorderLeft));
    const bt: i32 = @intCast(windowAttr(ib, w, wn.WA_BorderTop));
    try testing.expect(bl > 0 and bt > 0);

    // What the program is handed is the interior's, not the window's: it
    // draws at its own (0,0) and the ink lands inside the border.
    const rp: *graphics.RastPort = @ptrFromInt(windowAttr(ib, w, wn.WA_RastPort));
    const mark = graphics.penRGB(255, 0, 0);
    const pen = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = mark }, .{} };
    ib.layers_base.LockLayer(@ptrFromInt(windowAttr(ib, w, wn.WA_Layer)));
    gb.SetRPAttrs(rp, &pen);
    const dot = graphics.Rect{ .min_x = 0, .min_y = 0, .max_x = 3, .max_y = 3 };
    gb.RectFill(rp, &dot);
    ib.layers_base.UnlockLayer(@ptrFromInt(windowAttr(ib, w, wn.WA_Layer)));
    try testing.expectEqual(@as(u16, 0xF800), display.pixel(@intCast(bl), @intCast(bt)));

    // And it cannot reach the border: the title bar is untouched.
    try testing.expect(display.pixel(0, 0) != 0xF800);

    // A gadget's box is measured from that corner too, so a press at the
    // interior's own corner finds the gadget sitting at 0,0 of it.
    click(ib, bl + 2, bt + 2);
    try testing.expectEqual(@as(u32, 1), intuition.instData(Told, told_class, g).active);

    // A press in the border is not that gadget, though it is at the
    // window's own 0,0 where a gadget measured from the window would be.
    const before = intuition.instData(Told, told_class, g).active;
    click(ib, 1, bt + 2);
    try testing.expectEqual(before, intuition.instData(Told, told_class, g).active);

    // WA_InnerWidth says how much room there is.
    try testing.expectEqual(
        @as(usize, @intCast(64 - bl - @as(i32, @intCast(windowAttr(ib, w, wn.WA_BorderRight))))),
        windowAttr(ib, w, wn.WA_InnerWidth),
    );

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    ib.iface().CloseWindow(w);
    try testing.expect(ib.iface().CloseScreen(screen));
    it.DisposeObject(g);
    try testing.expect(ib.iface().FreeClass(told_class));
    try testing.expect(ib.iface().FreeClass(paint));
    display.down(ib);
    try tearDown(ib);
}

test "windows: the zoom gadget flips to a box and back" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const ie = sdk.devices.inputevent;
    const display = try Display.up(ib);

    // A box of its own, and a title bar wide enough to hold the gadget.
    const box = wn.WindowBox{ .left = 2, .top = 2, .width = 30, .height = 20 };
    const w = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 36 },
        .{ .tag = wn.WA_MinWidth, .data = 16 },
        .{ .tag = wn.WA_MinHeight, .data = 10 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_Zoom, .data = @intFromPtr(&box) },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{},
    }).?;
    const win: *_window.Window = @ptrCast(@alignCast(w));

    // Asking for a box is what gives a window the gadget.
    try testing.expect(win.flags & wn.WFLG_HASZOOM != 0);
    try testing.expect(win.zoom_image != null);

    // Pressed and let go over it: the window is the box it was given.
    const at_x = 64 - _window.zoom_width + 4;
    pointerEvent(ib, ie.IECODE_LBUTTON, at_x, 3);
    pointerEvent(ib, ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX, at_x, 3);
    try testing.expectEqual(@as(usize, 2), windowAttr(ib, w, wn.WA_Left));
    try testing.expectEqual(@as(usize, 30), windowAttr(ib, w, wn.WA_Width));
    try testing.expectEqual(@as(usize, 20), windowAttr(ib, w, wn.WA_Height));

    // Again, and it is back where it was. The gadget moved with the window,
    // so the second press is at the new right-hand end.
    const back_x = 2 + 30 - _window.zoom_width + 4;
    pointerEvent(ib, ie.IECODE_LBUTTON, back_x, 3);
    pointerEvent(ib, ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX, back_x, 3);
    try testing.expectEqual(@as(usize, 0), windowAttr(ib, w, wn.WA_Left));
    try testing.expectEqual(@as(usize, 64), windowAttr(ib, w, wn.WA_Width));
    try testing.expectEqual(@as(usize, 36), windowAttr(ib, w, wn.WA_Height));

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    ib.iface().CloseWindow(w);
    try testing.expect(ib.iface().CloseScreen(screen));
    display.down(ib);
    try tearDown(ib);
}

test "windows: which border holds the size gadget, and who paints the empty parts" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const display = try Display.up(ib);

    // Saying neither puts the size gadget in the right border, which is
    // where a window that says nothing has it.
    const right = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 60 },
        .{ .tag = wn.WA_Height, .data = 36 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, _window.size_width), windowAttr(ib, right, wn.WA_BorderRight));
    try testing.expect(windowAttr(ib, right, wn.WA_BorderBottom) < _window.size_height);
    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, right, wn.WA_Screen));
    ib.iface().CloseWindow(right);

    // Asking for the bottom moves it there and gives the right border back.
    const bottom = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 60 },
        .{ .tag = wn.WA_Height, .data = 36 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_SizeBBottom, .data = 1 },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, _window.size_height), windowAttr(ib, bottom, wn.WA_BorderBottom));
    try testing.expect(windowAttr(ib, bottom, wn.WA_BorderRight) < _window.size_width);
    ib.iface().CloseWindow(bottom);

    // A window may paint its own empty parts. The hook is called when the
    // window opens, which is the first thing there is to paint.
    Painter.calls = 0;
    var hook = utility.Hook{ .entry = &Painter.paint };
    const own = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 40 },
        .{ .tag = wn.WA_Height, .data = 30 },
        .{ .tag = wn.WA_BackFill, .data = @intFromPtr(&hook) },
        .{},
    }).?;
    try testing.expect(Painter.calls > 0);
    ib.iface().CloseWindow(own);

    try testing.expect(ib.iface().CloseScreen(screen));
    display.down(ib);
    try tearDown(ib);
}

test "windows: the pointer and the depth order are reported only when asked" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const ie = sdk.devices.inputevent;
    const display = try Display.up(ib);

    const quiet = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 40 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_MOUSEMOVE | wn.IDCMP_CHANGEWINDOW },
        .{},
    }).?;
    var got: [8]intuition.IntuiMessage = undefined;
    _ = drainMessages(ib, quiet, &got);

    // It listens for the class but never said it wanted the pointer, so a
    // move over it says nothing.
    pointerEvent(ib, ie.IECODE_NOBUTTON, 20, 20);
    try testing.expectEqual(@as(usize, 0), drainMessages(ib, quiet, &got));

    // Nor is it told about being sent to the back, having not asked.
    ib.iface().WindowToBack(quiet);
    try testing.expectEqual(@as(usize, 0), drainMessages(ib, quiet, &got));

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, quiet, wn.WA_Screen));
    ib.iface().CloseWindow(quiet);

    // The same window, having asked for both, hears both.
    const asking = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 40 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_ReportMouse, .data = 1 },
        .{ .tag = wn.WA_NotifyDepth, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_MOUSEMOVE | wn.IDCMP_CHANGEWINDOW },
        .{},
    }).?;
    _ = drainMessages(ib, asking, &got);
    pointerEvent(ib, ie.IECODE_NOBUTTON, 22, 22);
    var n = drainMessages(ib, asking, &got);
    try testing.expect(n >= 1);
    try testing.expectEqual(wn.IDCMP_MOUSEMOVE, got[0].class);

    ib.iface().WindowToBack(asking);
    n = drainMessages(ib, asking, &got);
    try testing.expect(n >= 1);
    try testing.expectEqual(wn.IDCMP_CHANGEWINDOW, got[n - 1].class);

    ib.iface().CloseWindow(asking);
    try testing.expect(ib.iface().CloseScreen(screen));
    display.down(ib);
    try tearDown(ib);
}

test "windows: a screen title is not mistaken for a list of gadgets" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const display = try Display.up(ib);

    // The two tags sit next to each other in the vocabulary, and a window
    // given the one must not be read as having been given the other: a
    // string walked as a list of objects is a fault, not a wrong picture.
    const w = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 40 },
        .{ .tag = wn.WA_Height, .data = 30 },
        .{ .tag = wn.WA_ScreenTitle, .data = @intFromPtr("A title, not a gadget") },
        .{},
    }).?;
    const win: *_window.Window = @ptrCast(@alignCast(w));
    try testing.expect(win.gadgets == null);

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    ib.iface().CloseWindow(w);
    try testing.expect(ib.iface().CloseScreen(screen));
    display.down(ib);
    try tearDown(ib);
}

test "windows: a border of frame and gadget images, and the screen held open" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const sc = intuition.screens;
    const display = try Display.up(ib);

    const tags = [_]TagItem{
        .{ .tag = wn.WA_Left, .data = 4 },
        .{ .tag = wn.WA_Top, .data = 12 },
        .{ .tag = wn.WA_Width, .data = 56 },
        .{ .tag = wn.WA_Height, .data = 26 },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{},
    };
    // No screen named: the default one is opened for it.
    const w = ib.iface().OpenWindowTagList(&tags).?;
    try testing.expectEqual(@as(usize, 4), windowAttr(ib, w, wn.WA_BorderLeft));
    try testing.expectEqual(@as(usize, 8 + 3), windowAttr(ib, w, wn.WA_BorderTop));
    try testing.expectEqual(@as(usize, 2), windowAttr(ib, w, wn.WA_BorderBottom));
    try testing.expectEqual(@as(usize, 56 - 8), windowAttr(ib, w, wn.WA_InnerWidth));
    try testing.expectEqual(@as(usize, 1), windowAttr(ib, w, wn.WA_Active));
    try testing.expectEqual(@as(usize, 0), windowAttr(ib, w, wn.WA_UserPort));

    // rgb565: white 0xFFFF, black 0, grey 0xAD55, the fill pen's blue 0x6457.
    // The outer frame: shine along the top-left, shadow at the bottom-right.
    try testing.expectEqual(@as(u16, 0xFFFF), display.pixel(4 + 30, 12));
    try testing.expectEqual(@as(u16, 0x0000), display.pixel(4 + 55, 12 + 20));
    // The title bar between the gadgets, active: the fill pen.
    try testing.expectEqual(@as(u16, 0x6457), display.pixel(4 + 24, 12 + 2));
    // Inside: the background pen.
    try testing.expectEqual(@as(u16, 0xAD55), display.pixel(4 + 20, 12 + 18));

    // A screen with a window on it stays open.
    const s: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    try testing.expect(!ib.iface().CloseScreen(s));

    // Deactivated, the bar is the background pen.
    const other = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Width, .data = 10 },
        .{ .tag = wn.WA_Height, .data = 10 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 0), windowAttr(ib, w, wn.WA_Active));
    try testing.expectEqual(@as(u16, 0xAD55), display.pixel(4 + 24, 12 + 2));

    ib.iface().CloseWindow(other);

    // Moved left, what it leaves on the right is the screen's background
    // again - the ground's damage, backfilled.
    try testing.expectEqual(@as(u16, 0x0000), display.pixel(59, 30));
    ib.iface().MoveWindow(w, -4, 0);
    try testing.expectEqual(@as(u16, 0xAD55), display.pixel(59, 30));

    // A backdrop window is behind the ordinary one where they overlap and
    // visible where they do not.
    const backdrop = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 40 },
        .{ .tag = wn.WA_Top, .data = 20 },
        .{ .tag = wn.WA_Width, .data = 24 },
        .{ .tag = wn.WA_Height, .data = 20 },
        .{ .tag = wn.WA_Backdrop, .data = 1 },
        .{},
    }).?;
    // Its right edge's shadow shows past the ordinary window's right edge.
    try testing.expectEqual(@as(u16, 0x0000), display.pixel(63, 30));
    // Inside the ordinary window it is hidden: the background pen there.
    try testing.expectEqual(@as(u16, 0xAD55), display.pixel(44, 30));
    ib.iface().CloseWindow(backdrop);

    ib.iface().CloseWindow(w);
    ib.iface().CloseWindow(null);
    try testing.expect(ib.iface().CloseScreen(s));
    _ = sc;
    display.down(ib);
    try tearDown(ib);
}

test "windows: IDCMP - activation, a simple window repaired and told, moves and sizes" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const display = try Display.up(ib);
    const lb: *sdk.interface.layers.LayersBase = ib.layers_base;

    const everything = wn.IDCMP_REFRESHWINDOW | wn.IDCMP_NEWSIZE | wn.IDCMP_CHANGEWINDOW |
        wn.IDCMP_ACTIVEWINDOW | wn.IDCMP_INACTIVEWINDOW;
    const back = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 12 },
        .{ .tag = wn.WA_Width, .data = 40 },
        .{ .tag = wn.WA_Height, .data = 24 },
        .{ .tag = wn.WA_SimpleRefresh, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = everything },
        .{ .tag = wn.WA_MaxWidth, .data = 50 },
        .{ .tag = wn.WA_MinHeight, .data = 20 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{},
    }).?;
    // Over its bottom right, and active in its place.
    const front = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 20 },
        .{ .tag = wn.WA_Top, .data = 20 },
        .{ .tag = wn.WA_Width, .data = 30 },
        .{ .tag = wn.WA_Height, .data = 16 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{},
    }).?;

    var got: [8]u32 = undefined;
    try testing.expectEqual(@as(usize, 2), drainClasses(ib, back, &got));
    try testing.expectEqual(wn.IDCMP_ACTIVEWINDOW, got[0]);
    try testing.expectEqual(wn.IDCMP_INACTIVEWINDOW, got[1]);

    // Scribble in the back window where the front one covers it, then
    // close the front one: what was under it is damage, its border is put
    // back (the right edge's shadow) and the program is told, once.
    ib.iface().CloseWindow(front);
    try testing.expectEqual(@as(u16, 0x0000), display.pixel(39, 30));
    try testing.expectEqual(@as(usize, 1), drainClasses(ib, back, &got));
    try testing.expectEqual(wn.IDCMP_REFRESHWINDOW, got[0]);

    // The program redraws inside BeginRefresh, where it can read what needs
    // it - the part the front window covered, in its own coordinates - and
    // afterwards no damage is left.
    try testing.expectEqual(@as(usize, 0), windowAttr(ib, back, wn.WA_Damage));
    ib.iface().BeginRefresh(back);
    const dirty: *graphics.Region = @ptrFromInt(windowAttr(ib, back, wn.WA_Damage));
    var rects: [4]graphics.Rect = undefined;
    const n = ib.graphics_base.RegionRectangles(dirty, &rects, rects.len);
    try testing.expect(n >= 1);
    for (rects[0..@min(n, rects.len)]) |r| {
        // Inside where the front window was: from (20, 8) in the back one's
        // coordinates on.
        try testing.expect(r.min_x >= 20 and r.min_y >= 8);
    }
    ib.iface().EndRefresh(back, true);
    try testing.expectEqual(@as(usize, 0), windowAttr(ib, back, wn.WA_Damage));
    var damage: usize = 0;
    const ask = [_]TagItem{ .{ .tag = sdk.layers.LATAG_GetDamage, .data = @intFromPtr(&damage) }, .{} };
    lb.GetLayerAttrs(@ptrFromInt(windowAttr(ib, back, wn.WA_Layer)), &ask);
    try testing.expect(damage == 0 or ib.graphics_base.RegionRectangles(@ptrFromInt(damage), null, 0) == 0);

    // A move says CHANGEWINDOW; a size NEWSIZE and CHANGEWINDOW, within
    // the limits - no wider than 50, no shorter than 20 - and on the screen.
    ib.iface().MoveWindow(back, 5, 2);
    try testing.expectEqual(@as(usize, 5), windowAttr(ib, back, wn.WA_Left));
    try testing.expectEqual(@as(usize, 1), drainClasses(ib, back, &got));
    try testing.expectEqual(wn.IDCMP_CHANGEWINDOW, got[0]);
    ib.iface().SizeWindow(back, 30, -10);
    try testing.expectEqual(@as(usize, 50), windowAttr(ib, back, wn.WA_Width));
    try testing.expectEqual(@as(usize, 20), windowAttr(ib, back, wn.WA_Height));
    // It grew wider, and a simple window keeps nothing: the new strip is
    // damage, so it is told to redraw as well.
    try testing.expectEqual(@as(usize, 3), drainClasses(ib, back, &got));
    try testing.expectEqual(wn.IDCMP_NEWSIZE, got[0]);
    try testing.expectEqual(wn.IDCMP_CHANGEWINDOW, got[1]);
    try testing.expectEqual(wn.IDCMP_REFRESHWINDOW, got[2]);
    ib.iface().BeginRefresh(back);
    ib.iface().EndRefresh(back, true);
    // Pushed off the right edge, it stops at it.
    ib.iface().MoveWindow(back, 100, 0);
    try testing.expectEqual(@as(usize, 64 - 50), windowAttr(ib, back, wn.WA_Left));

    // No port, no messages: taken away, and a message left on it goes too.
    ib.iface().MoveWindow(back, -1, 0);
    try testing.expect(ib.iface().ModifyIDCMP(back, 0));
    try testing.expectEqual(@as(usize, 0), windowAttr(ib, back, wn.WA_UserPort));
    try testing.expect(ib.iface().ModifyIDCMP(back, wn.IDCMP_CHANGEWINDOW));
    ib.iface().MoveWindow(back, 1, 0);

    const s: *intuition.Screen = @ptrFromInt(windowAttr(ib, back, wn.WA_Screen));
    ib.iface().CloseWindow(back);
    try testing.expect(ib.iface().CloseScreen(s));
    display.down(ib);
    try tearDown(ib);
}

/// Every message on a window's port, copied out and replied.
fn drainMessages(ib: *IntuitionBase, w: *intuition.Window, out: []intuition.IntuiMessage) usize {
    const port: *exec.MsgPort = @ptrFromInt(windowAttr(ib, w, intuition.windows.WA_UserPort));
    var n: usize = 0;
    while (ib.sys_base.GetMsg(port)) |m| {
        const im: *intuition.IntuiMessage = @ptrCast(@alignCast(m));
        if (n < out.len) out[n] = im.*;
        n += 1;
        ib.sys_base.ReplyMsg(m);
    }
    return n;
}

fn pointerEvent(ib: *IntuitionBase, code: u32, x: i32, y: i32) void {
    const ie = sdk.devices.inputevent;
    const e: ie.InputEvent = .{ .class = ie.IECLASS_NEWPOINTERPOS, .code = code, .x = x, .y = y };
    _input.handle(ib, &e);
}

fn click(ib: *IntuitionBase, x: i32, y: i32) void {
    const ie = sdk.devices.inputevent;
    pointerEvent(ib, ie.IECODE_LBUTTON, x, y);
    pointerEvent(ib, ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX, x, y);
}

test "input: clicks, keys and ticks to the active window; the border gadgets act" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const ie = sdk.devices.inputevent;
    const display = try Display.up(ib);
    const lb: *sdk.interface.layers.LayersBase = ib.layers_base;

    // Something to be in front of, out of the way in the bottom right.
    const other = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 54 },
        .{ .tag = wn.WA_Top, .data = 30 },
        .{ .tag = wn.WA_Width, .data = 10 },
        .{ .tag = wn.WA_Height, .data = 10 },
        .{},
    }).?;
    const listen = wn.IDCMP_MOUSEBUTTONS | wn.IDCMP_RAWKEY | wn.IDCMP_INTUITICKS | wn.IDCMP_CLOSEWINDOW |
        wn.IDCMP_CHANGEWINDOW | wn.IDCMP_NEWSIZE | wn.IDCMP_ACTIVEWINDOW;
    // Close 4..23, drag bar 24..35, depth 36..59; the size gadget in the
    // bottom right ten rows.
    const w = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 4 },
        .{ .tag = wn.WA_Top, .data = 12 },
        .{ .tag = wn.WA_Width, .data = 56 },
        .{ .tag = wn.WA_Height, .data = 26 },
        .{ .tag = wn.WA_MinWidth, .data = 20 },
        .{ .tag = wn.WA_MinHeight, .data = 15 },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = listen },
        .{},
    }).?;
    var got: [8]intuition.IntuiMessage = undefined;

    // A click inside: active first, then the button down and up, where it
    // was in the window.
    click(ib, 14, 27);
    try testing.expectEqual(@as(usize, 3), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.IDCMP_ACTIVEWINDOW, got[0].class);
    try testing.expectEqual(wn.IDCMP_MOUSEBUTTONS, got[1].class);
    try testing.expectEqual(wn.SELECTDOWN, got[1].code);
    try testing.expectEqual(@as(i32, 10), got[1].mouse_x);
    try testing.expectEqual(@as(i32, 15), got[1].mouse_y);
    try testing.expectEqual(wn.SELECTUP, got[2].code);

    // A key, with its qualifier.
    const key: ie.InputEvent = .{ .class = ie.IECLASS_RAWKEY, .code = 0x20, .qualifier = ie.IEQUALIFIER_LSHIFT };
    _input.handle(ib, &key);
    // Asked for as characters, a key that makes one comes as that character
    // - through the default keymap, "deutsch", so the key where Y is on a
    // US keyboard is a z - and a cursor key still comes as a rawkey.
    try testing.expect(ib.iface().ModifyIDCMP(w, listen | wn.IDCMP_VANILLAKEY));
    const z: ie.InputEvent = .{ .class = ie.IECLASS_RAWKEY, .code = 0x15 };
    _input.handle(ib, &z);
    const up: ie.InputEvent = .{ .class = ie.IECLASS_RAWKEY, .code = 0x4C };
    _input.handle(ib, &up);
    try testing.expectEqual(@as(usize, 3), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.IDCMP_RAWKEY, got[0].class);
    try testing.expectEqual(wn.IDCMP_VANILLAKEY, got[1].class);
    try testing.expectEqual(@as(u32, 'z'), got[1].code);
    try testing.expectEqual(wn.IDCMP_RAWKEY, got[2].class);
    try testing.expect(ib.iface().ModifyIDCMP(w, listen));
    _input.handle(ib, &key);
    // Two ticks while the first is not replied are one; replied, the next
    // comes.
    const tick: ie.InputEvent = .{ .class = ie.IECLASS_TIMER };
    _input.handle(ib, &tick);
    _input.handle(ib, &tick);
    try testing.expectEqual(@as(usize, 2), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.IDCMP_RAWKEY, got[0].class);
    try testing.expectEqual(@as(u32, 0x20), got[0].code);
    try testing.expectEqual(ie.IEQUALIFIER_LSHIFT, got[0].qualifier);
    try testing.expectEqual(wn.IDCMP_INTUITICKS, got[1].class);
    _input.handle(ib, &tick);
    try testing.expectEqual(@as(usize, 1), drainMessages(ib, w, &got));

    // The drag bar: held, moved by two and one, let go.
    pointerEvent(ib, ie.IECODE_LBUTTON, 30, 14);
    pointerEvent(ib, ie.IECODE_NOBUTTON, 32, 15);
    pointerEvent(ib, ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX, 32, 15);
    try testing.expectEqual(@as(usize, 6), windowAttr(ib, w, wn.WA_Left));
    try testing.expectEqual(@as(usize, 13), windowAttr(ib, w, wn.WA_Top));
    try testing.expectEqual(@as(usize, 1), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.IDCMP_CHANGEWINDOW, got[0].class);

    // The size gadget, now at 6+56-5, 13+26-3: two narrower, two shorter.
    pointerEvent(ib, ie.IECODE_LBUTTON, 57, 36);
    pointerEvent(ib, ie.IECODE_NOBUTTON, 55, 34);
    pointerEvent(ib, ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX, 55, 34);
    try testing.expectEqual(@as(usize, 54), windowAttr(ib, w, wn.WA_Width));
    try testing.expectEqual(@as(usize, 24), windowAttr(ib, w, wn.WA_Height));
    try testing.expectEqual(@as(usize, 2), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.IDCMP_NEWSIZE, got[0].class);

    // The close gadget let go somewhere else does nothing; let go over it,
    // it says so - and the window stays open until the program closes it.
    pointerEvent(ib, ie.IECODE_LBUTTON, 10, 16);
    pointerEvent(ib, ie.IECODE_NOBUTTON, 10, 30);
    pointerEvent(ib, ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX, 10, 30);
    try testing.expectEqual(@as(usize, 0), drainMessages(ib, w, &got));
    click(ib, 10, 16);
    try testing.expectEqual(@as(usize, 1), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.IDCMP_CLOSEWINDOW, got[0].class);

    // The depth gadget: in front, so to the back; then to the front again.
    const layer: *sdk.layers.Layer = @ptrFromInt(windowAttr(ib, w, wn.WA_Layer));
    var in_front: usize = 0;
    const ask = [_]TagItem{ .{ .tag = sdk.layers.LATAG_GetInFront, .data = @intFromPtr(&in_front) }, .{} };
    lb.GetLayerAttrs(layer, &ask);
    try testing.expectEqual(@as(usize, 0), in_front);
    click(ib, 50, 16);
    lb.GetLayerAttrs(layer, &ask);
    try testing.expect(in_front != 0);
    click(ib, 50, 16);
    lb.GetLayerAttrs(layer, &ask);
    try testing.expectEqual(@as(usize, 0), in_front);

    // A press on the other window makes it active; this one is told nothing
    // it did not ask for.
    click(ib, 62, 38);
    try testing.expectEqual(@as(usize, 1), windowAttr(ib, other, wn.WA_Active));
    _ = drainMessages(ib, w, &got);

    const s: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    ib.iface().CloseWindow(w);
    ib.iface().CloseWindow(other);
    try testing.expect(ib.iface().CloseScreen(s));
    display.down(ib);
    try tearDown(ib);
}

/// A key pressed and let go, as the input chain delivers one.
fn rawKey(ib: *IntuitionBase, code: u32) void {
    const ie = sdk.devices.inputevent;
    const down: ie.InputEvent = .{ .class = ie.IECLASS_RAWKEY, .code = code };
    _input.handle(ib, &down);
    const up: ie.InputEvent = .{ .class = ie.IECLASS_RAWKEY, .code = code | ie.IECODE_UP_PREFIX };
    _input.handle(ib, &up);
}

fn getAttr(ib: *IntuitionBase, o: *Object, attr: utility.Tag) usize {
    var value: usize = 0;
    _ = ib.iface().GetAttr(attr, o, &value);
    return value;
}

test "a string gadget: a right-aligned cursor stays inside the field" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const gc = intuition.gadgetclass;
    const it = ib.iface();
    const display = try Display.up(ib);

    // Text pushed against the right edge, with the cursor after it - the
    // place it has nowhere to go but onto the frame.
    const left = 2;
    const width = 56;
    const field = it.NewObjectTagList(null, classusr.STRGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = left },
        .{ .tag = gc.GA_Top, .data = 2 },
        .{ .tag = gc.GA_Width, .data = width },
        .{ .tag = gc.GA_Height, .data = 12 },
        .{ .tag = gc.STRINGA_MaxChars, .data = 16 },
        .{ .tag = gc.STRINGA_Justification, .data = gc.GACT_STRINGRIGHT },
        .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr("ab") },
        .{},
    }).?;

    const w = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 30 },
        .{ .tag = wn.WA_Borderless, .data = 1 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(field) },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{},
    }).?;

    // Activated with the cursor past the last character: press at the far
    // right of the field, which puts it after the text.
    click(ib, left + width - 3, 6);

    // The field's own right-hand edge is the last column it may write in.
    // Nothing of the cursor may be beyond it.
    const past = left + width;
    var ink_outside = false;
    var y: i32 = 2;
    while (y < 14) : (y += 1) {
        var x: i32 = past;
        while (x < past + 8) : (x += 1) {
            if (display.pixel(@intCast(x), @intCast(y)) != 0xAD55) ink_outside = true;
        }
    }
    try testing.expect(!ink_outside);

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    ib.iface().CloseWindow(w);
    try testing.expect(ib.iface().CloseScreen(screen));
    it.DisposeObject(field);
    display.down(ib);
    try tearDown(ib);
}

test "a string gadget: Escape puts back what was there, whoever owns the buffer" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const gc = intuition.gadgetclass;
    const it = ib.iface();
    const display = try Display.up(ib);

    // A buffer of the caller's, and no undo room offered with it - which is
    // what a program that has text to edit actually passes. The gadget must
    // find somewhere to keep the old copy itself, or Escape does nothing
    // and says nothing.
    var mine = [_]u8{0} ** 32;
    const start = "kept";
    @memcpy(mine[0..start.len], start);
    const field = it.NewObjectTagList(null, classusr.STRGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 2 },
        .{ .tag = gc.GA_Top, .data = 2 },
        .{ .tag = gc.GA_Width, .data = 50 },
        .{ .tag = gc.GA_Height, .data = 12 },
        .{ .tag = gc.STRINGA_MaxChars, .data = mine.len },
        .{ .tag = gc.STRINGA_Buffer, .data = @intFromPtr(&mine) },
        .{},
    }).?;

    const w = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 30 },
        .{ .tag = wn.WA_Borderless, .data = 1 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(field) },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{},
    }).?;

    // Activated, typed into, then Escape.
    click(ib, 10, 6);
    rawKey(ib, 0x21); // 'x'
    rawKey(ib, 0x32); // 'm'
    try testing.expect(firstChar(ib, field) != 'k');
    rawKey(ib, 0x45); // Escape
    try testing.expectEqualStrings("kept", mine[0..4]);

    // The buffer is the caller's and is not swapped for another one later:
    // a gadget that took its own would have nothing pointing at it.
    var other = [_]u8{0} ** 32;
    const swap = [_]TagItem{ .{ .tag = gc.STRINGA_Buffer, .data = @intFromPtr(&other) }, .{} };
    _ = ib.iface().SetGadgetAttrsTagList(field, @ptrCast(@alignCast(w)), &swap);
    click(ib, 4, 6);
    rawKey(ib, 0x21); // 'x'
    // What was typed went into the caller's buffer, and the one offered
    // afterwards was never taken up.
    try testing.expect(!std.mem.eql(u8, mine[0..4], "kept"));
    try testing.expectEqual(@as(u8, 0), other[0]);
    rawKey(ib, 0x45);

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    ib.iface().CloseWindow(w);
    try testing.expect(ib.iface().CloseScreen(screen));
    it.DisposeObject(field);
    display.down(ib);
    try tearDown(ib);
}

test "a string gadget: typed into, moved about, finished and cancelled" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const gc = intuition.gadgetclass;
    const ie = sdk.devices.inputevent;
    const it = ib.iface();
    const display = try Display.up(ib);

    // Its own buffer, with what it starts with written in.
    const field = it.NewObjectTagList(null, classusr.STRGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 4 },
        .{ .tag = gc.GA_Top, .data = 4 },
        .{ .tag = gc.GA_Width, .data = 50 },
        .{ .tag = gc.GA_Height, .data = 10 },
        .{ .tag = gc.GA_ID, .data = 5 },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{ .tag = gc.STRINGA_MaxChars, .data = 16 },
        .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr("ab") },
        .{},
    }).?;
    const w = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 12 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 28 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(field) },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_GADGETUP },
        .{},
    }).?;
    var got: [4]intuition.IntuiMessage = undefined;
    const buffer: [*:0]const u8 = @ptrFromInt(getAttr(ib, field, gc.STRINGA_Buffer));
    try testing.expectEqualStrings("ab", std.mem.span(buffer));

    // Pressed: it takes the keys. 'c' goes in at the cursor, which the
    // press put at the end of what is there.
    pointerEvent(ib, ie.IECODE_LBUTTON, 40, 12 + 8);
    pointerEvent(ib, ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX, 40, 12 + 8);
    rawKey(ib, 0x33); // c
    try testing.expectEqualStrings("abc", std.mem.span(buffer));

    // Left twice and a character goes in between the others.
    rawKey(ib, 0x4F); // cursor left
    rawKey(ib, 0x4F);
    rawKey(ib, 0x21); // s
    try testing.expectEqualStrings("asbc", std.mem.span(buffer));

    // Backspace takes out what is before the cursor.
    rawKey(ib, 0x41);
    try testing.expectEqualStrings("abc", std.mem.span(buffer));

    // Return finishes it, and the window hears that it was let go.
    rawKey(ib, 0x44);
    try testing.expectEqual(@as(usize, 1), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.IDCMP_GADGETUP, got[0].class);

    // Typed into again and cancelled: what it held when it was activated
    // is what it holds afterwards.
    pointerEvent(ib, ie.IECODE_LBUTTON, 40, 12 + 8);
    pointerEvent(ib, ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX, 40, 12 + 8);
    rawKey(ib, 0x33);
    rawKey(ib, 0x33);
    try testing.expectEqualStrings("abccc", std.mem.span(buffer));
    rawKey(ib, 0x45); // escape
    try testing.expectEqualStrings("abc", std.mem.span(buffer));

    // A number written in is the text, and the text read back is a number.
    const set = [_]TagItem{ .{ .tag = gc.STRINGA_LongVal, .data = @bitCast(@as(isize, -42)) }, .{} };
    _ = ib.iface().SetGadgetAttrsTagList(field, @ptrCast(@alignCast(w)), &set);
    try testing.expectEqualStrings("-42", std.mem.span(buffer));
    try testing.expectEqual(@as(isize, -42), @as(isize, @bitCast(getAttr(ib, field, gc.STRINGA_LongVal))));

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    ib.iface().CloseWindow(w);
    try testing.expect(ib.iface().CloseScreen(screen));
    it.DisposeObject(field);
    display.down(ib);
    try tearDown(ib);
}

test "the rest of the classes: a box, words, a framed button and a group" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const gc = intuition.gadgetclass;
    const ie = sdk.devices.inputevent;
    _ = ie;
    const it = ib.iface();
    const display = try Display.up(ib);

    // fillrectclass: a box of one colour, drawn where it is put.
    const red = graphics.penRGB(255, 0, 0);
    const fill = it.NewObjectTagList(null, classusr.FILLRECTCLASS, &[_]TagItem{
        .{ .tag = ic.IA_Width, .data = 8 },
        .{ .tag = ic.IA_Height, .data = 4 },
        .{ .tag = ic.IA_FGPen, .data = red },
        .{},
    }).?;
    // itexticlass: the same, but its shape is words, in the image's pen:
    // the run's own is passed over.
    var words = intuition.IntuiText{
        .front_pen = graphics.penRGB(255, 0, 0),
        .text = "Hi",
    };
    const label = it.NewObjectTagList(null, classusr.ITEXTICLASS, &[_]TagItem{
        .{ .tag = ic.IA_Width, .data = 20 },
        .{ .tag = ic.IA_Height, .data = 8 },
        .{ .tag = ic.IA_FGPen, .data = graphics.penRGB(255, 255, 255) },
        .{ .tag = ic.IA_Data, .data = @intFromPtr(&words) },
        .{},
    }).?;

    // A group of two framed buttons, placed inside the group's own box.
    const one = it.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 0 },
        .{ .tag = gc.GA_Top, .data = 0 },
        .{ .tag = gc.GA_Width, .data = 12 },
        .{ .tag = gc.GA_Height, .data = 8 },
        .{ .tag = gc.GA_ID, .data = 1 },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{ .tag = intuition.icclass.ICA_TARGET, .data = intuition.icclass.ICTARGET_IDCMP },
        .{},
    }).?;
    const two = it.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 14 },
        .{ .tag = gc.GA_Top, .data = 0 },
        .{ .tag = gc.GA_Width, .data = 12 },
        .{ .tag = gc.GA_Height, .data = 8 },
        .{ .tag = gc.GA_ID, .data = 2 },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{ .tag = intuition.icclass.ICA_TARGET, .data = intuition.icclass.ICTARGET_IDCMP },
        .{},
    }).?;
    const group = it.NewObjectTagList(null, classusr.GROUPGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 4 },
        .{ .tag = gc.GA_Top, .data = 4 },
        .{ .tag = gc.GA_Width, .data = 30 },
        .{ .tag = gc.GA_Height, .data = 10 },
        .{},
    }).?;
    var add = classusr.OpMember{ .method_id = classusr.OM_ADDMEMBER, .object = one };
    try testing.expect(it.SendMessage(group, @ptrCast(&add)) != 0);
    add.object = two;
    try testing.expect(it.SendMessage(group, @ptrCast(&add)) != 0);

    const w = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 12 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 28 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(group) },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_GADGETUP | wn.IDCMP_IDCMPUPDATE },
        .{},
    }).?;
    var got: [8]intuition.IntuiMessage = undefined;

    // The two images drawn straight into the window's RastPort.
    const rp: *graphics.RastPort = @ptrFromInt(windowAttr(ib, w, wn.WA_RastPort));
    ib.layers_base.LockLayer(@ptrFromInt(windowAttr(ib, w, wn.WA_Layer)));
    ib.iface().DrawImage(rp, fill, 40, 2);
    ib.iface().DrawImage(rp, label, 40, 8);
    ib.layers_base.UnlockLayer(@ptrFromInt(windowAttr(ib, w, wn.WA_Layer)));
    // The box is that colour all through, and stops where it ends.
    try testing.expectEqual(@as(u16, 0xF800), display.pixel(40, 12 + 2));
    try testing.expectEqual(@as(u16, 0xF800), display.pixel(47, 12 + 5));
    try testing.expectEqual(@as(u16, 0xAD55), display.pixel(48, 12 + 2));
    // The words put some ink down where there was ground.
    var ink = false;
    for (0..16) |x| {
        for (0..8) |y| {
            if (display.pixel(40 + x, 12 + 8 + y) == 0xFFFF) ink = true;
        }
    }
    try testing.expect(ink);

    // The group's second button is hit inside the group's own box: the
    // group is at 4,4 and the button 14 further on. The member tells its
    // own target which one it is - the group is the gadget the window
    // knows, so the ID in an IDCMP message would be the group's.
    click(ib, 4 + 14 + 6, 12 + 4 + 4);
    const n = drainMessages(ib, w, &got);
    try testing.expect(n >= 1);
    try testing.expectEqual(wn.IDCMP_IDCMPUPDATE, got[0].class);
    const told: [*]const TagItem = @ptrCast(@alignCast(got[0].iaddress.?));
    try testing.expectEqual(gc.GA_ID, told[0].tag);
    try testing.expectEqual(@as(usize, 2), told[0].data);

    // A press in the gap between them belongs to neither.
    click(ib, 4 + 13, 12 + 4 + 4);
    try testing.expectEqual(@as(usize, 0), drainMessages(ib, w, &got));

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    ib.iface().CloseWindow(w);
    try testing.expect(ib.iface().CloseScreen(screen));
    it.DisposeObject(group); // its members go with it
    it.DisposeObject(label);
    it.DisposeObject(fill);
    display.down(ib);
    try tearDown(ib);
}

/// The first character of what is in a line-of-text gadget.
fn firstChar(ib: *IntuitionBase, o: *Object) usize {
    const gc = intuition.gadgetclass;
    var text: usize = 0;
    _ = ib.iface().GetAttr(gc.STRINGA_TextVal, o, &text);
    if (text == 0) return 0;
    const p: [*:0]const u8 = @ptrFromInt(text);
    return p[0];
}

/// A gadget that counts the times it is taken up and put down again - the
/// two messages a group has to pass on to whichever member holds the input.
const Told = extern struct { active: u32, inactive: u32, laid_out: u32 };

fn toldDispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *Class = @ptrCast(hook);
    const ib: *IntuitionBase = @ptrFromInt(cl.user_data);
    const msg: *Msg = @ptrCast(@alignCast(message.?));
    const o: ?*Object = @ptrCast(object);
    const gc = intuition.gadgetclass;
    const ie = sdk.devices.inputevent;
    switch (msg.method_id) {
        gc.GM_HITTEST => return gc.GMR_GADGETHIT,
        gc.GM_RENDER => return 0,
        gc.GM_GOACTIVE => {
            intuition.instData(Told, cl, o.?).active += 1;
            return gc.GMR_MEACTIVE;
        },
        gc.GM_HANDLEINPUT => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const e = in.event orelse return gc.GMR_MEACTIVE;
            const up = ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX;
            if (e.class == ie.IECLASS_NEWPOINTERPOS and e.code == up) return gc.GMR_NOREUSE;
            return gc.GMR_MEACTIVE;
        },
        gc.GM_GOINACTIVE => {
            intuition.instData(Told, cl, o.?).inactive += 1;
            return 0;
        },
        gc.GM_LAYOUT => {
            intuition.instData(Told, cl, o.?).laid_out += 1;
            return 0;
        },
        else => return ib.iface().SendSuperMessage(cl, o, msg),
    }
}

fn toldClass(ib: *IntuitionBase) *Class {
    const cl = ib.iface().MakeClass(null, classusr.GADGETCLASS, null, @sizeOf(Told)).?;
    cl.dispatcher.entry = &toldDispatch;
    cl.user_data = @intFromPtr(ib);
    return cl;
}

/// A gadget that fills its box with one colour, so that what covers what
/// can be read off the display.
const Paint = extern struct { pen: u32 };

fn paintDispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *Class = @ptrCast(hook);
    const ib: *IntuitionBase = @ptrFromInt(cl.user_data);
    const msg: *Msg = @ptrCast(@alignCast(message.?));
    const o: ?*Object = @ptrCast(object);
    const gc = intuition.gadgetclass;
    switch (msg.method_id) {
        gc.GM_HITTEST => return gc.GMR_GADGETHIT,
        gc.GM_RENDER => {
            const r: *gc.GpRender = @ptrCast(@alignCast(msg));
            const gi = r.gadget_info orelse return 0;
            const g = gadgetclass.gadgetOf(ib, o.?);
            const b = _gadget.boxIn(g, gi.domain_width, gi.domain_height);
            const gb = ib.graphics_base;
            const pen = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = intuition.instData(Paint, cl, o.?).pen }, .{} };
            gb.SetRPAttrs(r.rast_port, &pen);
            const rect = graphics.Rect{ .min_x = b.left, .min_y = b.top, .max_x = b.left + b.width, .max_y = b.top + b.height };
            gb.RectFill(r.rast_port, &rect);
            return 0;
        },
        else => return ib.iface().SendSuperMessage(cl, o, msg),
    }
}

fn paintClass(ib: *IntuitionBase) *Class {
    const cl = ib.iface().MakeClass(null, classusr.GADGETCLASS, null, @sizeOf(Paint)).?;
    cl.dispatcher.entry = &paintDispatch;
    cl.user_data = @intFromPtr(ib);
    return cl;
}

test "gadgets: Tab hands the keyboard on, and a resize says so" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const gc = intuition.gadgetclass;
    const it = ib.iface();
    const display = try Display.up(ib);
    const told_class = toldClass(ib);

    // Two lines of text, one after the other, and a button between them
    // that does not take the keyboard - Tab goes past it.
    const first = it.NewObjectTagList(null, classusr.STRGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 2 },
        .{ .tag = gc.GA_Top, .data = 2 },
        .{ .tag = gc.GA_Width, .data = 50 },
        .{ .tag = gc.GA_Height, .data = 10 },
        .{ .tag = gc.GA_TabCycle, .data = 1 },
        .{ .tag = gc.STRINGA_MaxChars, .data = 16 },
        .{},
    }).?;
    const middle = it.NewObjectTagList(told_class, null, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 2 },
        .{ .tag = gc.GA_Top, .data = 14 },
        .{ .tag = gc.GA_Width, .data = 50 },
        .{ .tag = gc.GA_Height, .data = 10 },
        .{ .tag = gc.GA_Previous, .data = @intFromPtr(first) },
        .{},
    }).?;
    const second = it.NewObjectTagList(null, classusr.STRGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 2 },
        .{ .tag = gc.GA_Top, .data = 26 },
        .{ .tag = gc.GA_Width, .data = 50 },
        .{ .tag = gc.GA_Height, .data = 10 },
        .{ .tag = gc.GA_TabCycle, .data = 1 },
        .{ .tag = gc.STRINGA_MaxChars, .data = 16 },
        .{ .tag = gc.GA_Previous, .data = @intFromPtr(middle) },
        .{},
    }).?;

    const w = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 60 },
        .{ .tag = wn.WA_Height, .data = 40 },
        .{ .tag = wn.WA_MinWidth, .data = 30 },
        .{ .tag = wn.WA_MinHeight, .data = 20 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(first) },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{},
    }).?;

    // Typed into the first, then Tab: what is typed next goes to the
    // second, without the pointer having moved.
    click(ib, 10, 6);
    rawKey(ib, 0x20); // 'a'
    rawKey(ib, 0x42); // Tab
    rawKey(ib, 0x35); // 'b'
    try testing.expectEqual(@as(usize, 'a'), firstChar(ib, first));
    try testing.expectEqual(@as(usize, 'b'), firstChar(ib, second));

    // The button in between never had it: Tab passed over it.
    try testing.expectEqual(@as(u32, 0), intuition.instData(Told, told_class, middle).active);

    // A resize tells every gadget the room it is measured against changed.
    const before = intuition.instData(Told, told_class, middle).laid_out;
    ib.iface().SizeWindow(w, -6, -4);
    try testing.expect(intuition.instData(Told, told_class, middle).laid_out > before);

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    ib.iface().CloseWindow(w);
    try testing.expect(ib.iface().CloseScreen(screen));
    it.DisposeObject(first);
    it.DisposeObject(middle);
    it.DisposeObject(second);
    try testing.expect(ib.iface().FreeClass(told_class));
    display.down(ib);
    try tearDown(ib);
}

test "IDCMP: moves and repeats are held to a few at a time, news always goes" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const ie = sdk.devices.inputevent;
    const display = try Display.up(ib);

    const w = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 40 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_MouseQueue, .data = 3 },
        .{ .tag = wn.WA_RptQueue, .data = 2 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_MOUSEMOVE | wn.IDCMP_RAWKEY | wn.IDCMP_MOUSEBUTTONS },
        .{},
    }).?;
    const win: *_window.Window = @ptrCast(@alignCast(w));

    // A program that never replies hears three moves and no more: the next
    // move says where the pointer is anyway, so the rest are no loss.
    var sent: u32 = 0;
    for (0..20) |_| {
        if (_window.sendWith(ib, win, wn.IDCMP_MOUSEMOVE, 0, null)) sent += 1;
    }
    try testing.expectEqual(@as(u32, 3), sent);

    // A key held down is the same: it says the same thing over again.
    ib.input.qualifier = ie.IEQUALIFIER_REPEAT;
    sent = 0;
    for (0..20) |_| {
        if (_window.sendWith(ib, win, wn.IDCMP_RAWKEY, 65, null)) sent += 1;
    }
    try testing.expectEqual(@as(u32, 2), sent);

    // A button is news, and news is never dropped however far behind the
    // program is.
    ib.input.qualifier = 0;
    sent = 0;
    for (0..20) |_| {
        if (_window.sendWith(ib, win, wn.IDCMP_MOUSEBUTTONS, ie.IECODE_LBUTTON, null)) sent += 1;
    }
    try testing.expectEqual(@as(u32, 20), sent);

    // Replied, the places come back and the window hears moves again.
    var got: [64]intuition.IntuiMessage = undefined;
    _ = drainMessages(ib, w, &got);
    sent = 0;
    for (0..20) |_| {
        if (_window.sendWith(ib, win, wn.IDCMP_MOUSEMOVE, 0, null)) sent += 1;
    }
    try testing.expectEqual(@as(u32, 3), sent);
    _ = drainMessages(ib, w, &got);

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    ib.iface().CloseWindow(w);
    try testing.expect(ib.iface().CloseScreen(screen));
    display.down(ib);
    try tearDown(ib);
}

test "ObtainGIRPort: a gadget draws in its own RastPort, and the lock comes back" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const gc = intuition.gadgetclass;
    const it = ib.iface();
    const gb = ib.graphics_base;
    const display = try Display.up(ib);
    const paint = paintClass(ib);

    const g = it.NewObjectTagList(paint, null, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 10 },
        .{ .tag = gc.GA_Top, .data = 10 },
        .{ .tag = gc.GA_Width, .data = 12 },
        .{ .tag = gc.GA_Height, .data = 8 },
        .{},
    }).?;
    intuition.instData(Paint, paint, g).pen = graphics.penRGB(255, 0, 0);

    const w = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 40 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(g) },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{},
    }).?;
    const win: *_window.Window = @ptrCast(@alignCast(w));

    // What a program has set on its own RastPort before any gadget draws.
    const rp: *graphics.RastPort = @ptrFromInt(windowAttr(ib, w, wn.WA_RastPort));
    const mine = graphics.penRGB(0, 255, 0);
    const set = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = mine },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_COMPLEMENT },
        .{},
    };
    gb.SetRPAttrs(rp, &set);

    // The gadget is given a RastPort of its own, not the program's.
    var gi = _gadget.info(win);
    const got = it.ObtainGIRPort(&gi).?;
    try testing.expect(got != rp);
    it.ReleaseGIRPort(got);

    // It draws through it, and the program's pen and mode are untouched
    // afterwards - a gadget that set them carelessly could not reach them.
    _gadget.renderAll(ib, win);
    try testing.expectEqual(@as(u16, 0xF800), display.pixel(12, 12));
    var pen_now: usize = 0;
    var mode_now: usize = 0;
    const ask = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = @intFromPtr(&pen_now) },
        .{ .tag = graphics.RPTAG_DrMd, .data = @intFromPtr(&mode_now) },
        .{},
    };
    gb.GetRPAttrs(rp, &ask);
    try testing.expectEqual(@as(usize, mine), pen_now);
    try testing.expectEqual(@as(usize, graphics.DRMD_COMPLEMENT), mode_now);

    // Every obtain gave its layer back: the table is empty, so nothing is
    // still holding a lock that was never released.
    for (ib.held) |slot| try testing.expect(slot.rp == null);

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    ib.iface().CloseWindow(w);
    try testing.expect(ib.iface().CloseScreen(screen));
    it.DisposeObject(g);
    try testing.expect(ib.iface().FreeClass(paint));
    display.down(ib);
    try tearDown(ib);
}

test "icclass: an update aimed at a window's IDCMP reaches it" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const gc = intuition.gadgetclass;
    const icc = intuition.icclass;
    const it = ib.iface();
    const display = try Display.up(ib);

    const w = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 40 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_IDCMPUPDATE },
        .{},
    }).?;

    // A connection whose target is the window's port rather than another
    // object. It is told through the GadgetInfo the update carries, which
    // is the only thing that says which window.
    const conn = it.NewObjectTagList(null, classusr.ICCLASS, &[_]TagItem{
        .{ .tag = icc.ICA_TARGET, .data = icc.ICTARGET_IDCMP },
        .{},
    }).?;

    var gi = _gadget.info(@ptrCast(@alignCast(w)));
    const tags = [_]TagItem{ .{ .tag = gc.GA_ID, .data = 77 }, .{} };
    var msg = classusr.OpUpdate{
        .method_id = classusr.OM_UPDATE,
        .attr_list = &tags,
        .gadget_info = &gi,
        .flags = 0,
    };
    _ = it.SendMessage(conn, @ptrCast(&msg));

    var got: [4]intuition.IntuiMessage = undefined;
    try testing.expectEqual(@as(usize, 1), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.IDCMP_IDCMPUPDATE, got[0].class);
    const told: [*]const TagItem = @ptrCast(@alignCast(got[0].iaddress.?));
    try testing.expectEqual(gc.GA_ID, told[0].tag);
    try testing.expectEqual(@as(usize, 77), told[0].data);
    try testing.expectEqual(@as(u32, 0), got[0].code);

    // Mapped to ICSPECIAL_CODE, an attribute becomes the message's code.
    const map = [_]TagItem{ .{ .tag = gc.GA_ID, .data = icc.ICSPECIAL_CODE }, .{} };
    _ = it.SetAttrsTagList(conn, &[_]TagItem{ .{ .tag = icc.ICA_MAP, .data = @intFromPtr(&map) }, .{} });
    _ = it.SendMessage(conn, @ptrCast(&msg));
    try testing.expectEqual(@as(usize, 1), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.IDCMP_IDCMPUPDATE, got[0].class);
    try testing.expectEqual(@as(u32, 77), got[0].code);
    const mapped: [*]const TagItem = @ptrCast(@alignCast(got[0].iaddress.?));
    try testing.expectEqual(icc.ICSPECIAL_CODE, mapped[0].tag);

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    it.DisposeObject(conn);
    ib.iface().CloseWindow(w);
    try testing.expect(ib.iface().CloseScreen(screen));
    display.down(ib);
    try tearDown(ib);
}

test "input: a press in another window takes the gadget's hold away" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const gc = intuition.gadgetclass;
    const it = ib.iface();
    const display = try Display.up(ib);
    const told_class = toldClass(ib);

    // A gadget that holds the input until a release over itself - which is
    // what a line of text does, and what a press elsewhere must end.
    const holder = it.NewObjectTagList(told_class, null, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 4 },
        .{ .tag = gc.GA_Top, .data = 4 },
        .{ .tag = gc.GA_Width, .data = 20 },
        .{ .tag = gc.GA_Height, .data = 20 },
        .{},
    }).?;
    const left = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 32 },
        .{ .tag = wn.WA_Height, .data = 40 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(holder) },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{},
    }).?;
    const right = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 32 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 32 },
        .{ .tag = wn.WA_Height, .data = 40 },
        .{},
    }).?;

    const state = intuition.instData(Told, told_class, holder);
    const ie = sdk.devices.inputevent;
    pointerEvent(ib, ie.IECODE_LBUTTON, 10, 10);
    try testing.expectEqual(@as(u32, 1), state.active);
    try testing.expectEqual(@as(u32, 0), state.inactive);

    // Pressed in the other window without ever letting go in this one: the
    // gadget is told it is done and the other window takes the press.
    pointerEvent(ib, ie.IECODE_LBUTTON, 44, 20);
    try testing.expectEqual(@as(u32, 1), state.inactive);
    try testing.expectEqual(@intFromPtr(right), @intFromPtr(ib.active_window.?));
    pointerEvent(ib, ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX, 44, 20);

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, left, wn.WA_Screen));
    ib.iface().CloseWindow(right);
    ib.iface().CloseWindow(left);
    try testing.expect(ib.iface().CloseScreen(screen));
    it.DisposeObject(holder);
    try testing.expect(ib.iface().FreeClass(told_class));
    display.down(ib);
    try tearDown(ib);
}

test "input: a disabled gadget swallows the press, a border gadget takes it" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const gc = intuition.gadgetclass;
    const it = ib.iface();
    const display = try Display.up(ib);
    const told_class = toldClass(ib);

    // Two gadgets over the same ground, the disabled one in front, and a
    // third up in the window's title-bar row.
    const off = it.NewObjectTagList(told_class, null, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 10 },
        .{ .tag = gc.GA_Top, .data = 20 },
        .{ .tag = gc.GA_Width, .data = 20 },
        .{ .tag = gc.GA_Height, .data = 10 },
        .{ .tag = gc.GA_Disabled, .data = 1 },
        .{},
    }).?;
    const under = it.NewObjectTagList(told_class, null, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 10 },
        .{ .tag = gc.GA_Top, .data = 20 },
        .{ .tag = gc.GA_Width, .data = 20 },
        .{ .tag = gc.GA_Height, .data = 10 },
        .{ .tag = gc.GA_Previous, .data = @intFromPtr(off) },
        .{},
    }).?;
    const up_top = it.NewObjectTagList(told_class, null, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 24 },
        .{ .tag = gc.GA_Top, .data = 0 },
        .{ .tag = gc.GA_Width, .data = 16 },
        .{ .tag = gc.GA_Height, .data = 10 },
        .{ .tag = gc.GA_Previous, .data = @intFromPtr(under) },
        .{},
    }).?;

    const w = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 40 },
        .{ .tag = wn.WA_Title, .data = @intFromPtr("T") },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(off) },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{},
    }).?;

    // A press where the disabled one is goes no further: the gadget behind
    // it hears nothing, because the press belonged to the disabled one.
    click(ib, 20, 25);
    try testing.expectEqual(@as(u32, 0), intuition.instData(Told, told_class, under).active);
    try testing.expectEqual(@as(u32, 0), intuition.instData(Told, told_class, off).active);

    // A gadget put in the title-bar row is pressed there, rather than the
    // press being taken as the beginning of a drag.
    const before_left = windowAttr(ib, w, wn.WA_Left);
    click(ib, 30, 4);
    try testing.expectEqual(@as(u32, 1), intuition.instData(Told, told_class, up_top).active);
    try testing.expectEqual(before_left, windowAttr(ib, w, wn.WA_Left));

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    ib.iface().CloseWindow(w);
    try testing.expect(ib.iface().CloseScreen(screen));
    it.DisposeObject(off);
    it.DisposeObject(under);
    it.DisposeObject(up_top);
    try testing.expect(ib.iface().FreeClass(told_class));
    display.down(ib);
    try tearDown(ib);
}

test "gadgets: drawn back to front, so the one a press finds is on top" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const gc = intuition.gadgetclass;
    const it = ib.iface();
    const display = try Display.up(ib);
    const paint = paintClass(ib);

    // Two gadgets of the same window, overlapping. The first of the list
    // is the one a press finds, so it has to be the one seen.
    const front = it.NewObjectTagList(paint, null, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 20 },
        .{ .tag = gc.GA_Top, .data = 20 },
        .{ .tag = gc.GA_Width, .data = 16 },
        .{ .tag = gc.GA_Height, .data = 8 },
        .{},
    }).?;
    const behind = it.NewObjectTagList(paint, null, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 28 },
        .{ .tag = gc.GA_Top, .data = 20 },
        .{ .tag = gc.GA_Width, .data = 16 },
        .{ .tag = gc.GA_Height, .data = 8 },
        .{ .tag = gc.GA_Previous, .data = @intFromPtr(front) },
        .{},
    }).?;
    intuition.instData(Paint, paint, front).pen = graphics.penRGB(255, 0, 0);
    intuition.instData(Paint, paint, behind).pen = graphics.penRGB(0, 0, 255);

    const w = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 40 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(front) },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{},
    }).?;
    _gadget.renderAll(ib, @ptrCast(@alignCast(w)));

    // The display is the window, so a gadget's box is where it is drawn.
    // Where only one of them is, each has its own colour.
    try testing.expectEqual(@as(u16, 0xF800), display.pixel(22, 22));
    try testing.expectEqual(@as(u16, 0x001F), display.pixel(40, 22));
    // Where they meet, the first of the list is on top - drawn last.
    try testing.expectEqual(@as(u16, 0xF800), display.pixel(30, 22));
    // And that is the one a press there finds, which is the whole point.
    try testing.expect(_gadget.hit(ib, @ptrCast(@alignCast(w)), 30, 22).gadget == front);

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    ib.iface().CloseWindow(w);
    try testing.expect(ib.iface().CloseScreen(screen));
    it.DisposeObject(front);
    it.DisposeObject(behind);
    try testing.expect(ib.iface().FreeClass(paint));
    display.down(ib);
    try tearDown(ib);
}

test "gadgets: a toggle stays as it was left, and a border gadget keeps to the border" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const gc = intuition.gadgetclass;
    const it = ib.iface();
    const display = try Display.up(ib);

    // A toggle: pressed once it is on, pressed again it is off, and it does
    // not flicker while the pointer wanders over it.
    const toggle = it.NewObjectTagList(null, classusr.BUTTONGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 4 },
        .{ .tag = gc.GA_Top, .data = 4 },
        .{ .tag = gc.GA_Width, .data = 20 },
        .{ .tag = gc.GA_Height, .data = 10 },
        .{ .tag = gc.GA_ToggleSelect, .data = 1 },
        .{},
    }).?;
    const w = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 30 },
        .{ .tag = wn.WA_Borderless, .data = 1 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(toggle) },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{},
    }).?;

    try testing.expectEqual(@as(usize, 0), getAttr(ib, toggle, gc.GA_Selected));
    click(ib, 10, 8);
    try testing.expectEqual(@as(usize, 1), getAttr(ib, toggle, gc.GA_Selected));
    click(ib, 10, 8);
    try testing.expectEqual(@as(usize, 0), getAttr(ib, toggle, gc.GA_Selected));

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    ib.iface().CloseWindow(w);
    it.DisposeObject(toggle);

    // A GimmeZeroZero window's gadgets belong to its interior, unless one
    // says it belongs to the border - and then it is measured from the
    // window's corner, not the interior's.
    const inside = it.NewObjectTagList(null, classusr.BUTTONGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 0 },
        .{ .tag = gc.GA_Top, .data = 0 },
        .{ .tag = gc.GA_Width, .data = 8 },
        .{ .tag = gc.GA_Height, .data = 8 },
        .{},
    }).?;
    const on_border = it.NewObjectTagList(null, classusr.BUTTONGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 0 },
        .{ .tag = gc.GA_Top, .data = 0 },
        .{ .tag = gc.GA_Width, .data = 8 },
        .{ .tag = gc.GA_Height, .data = 8 },
        .{ .tag = gc.GA_GZZGadget, .data = 1 },
        .{ .tag = gc.GA_Previous, .data = @intFromPtr(inside) },
        .{},
    }).?;
    const gzz = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 30 },
        .{ .tag = wn.WA_Title, .data = @intFromPtr("T") },
        .{ .tag = wn.WA_GimmeZeroZero, .data = 1 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(inside) },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{},
    }).?;
    const win: *_window.Window = @ptrCast(@alignCast(gzz));
    const bl: i32 = @intCast(windowAttr(ib, gzz, wn.WA_BorderLeft));
    const bt: i32 = @intCast(windowAttr(ib, gzz, wn.WA_BorderTop));

    // The one on the border draws through the border's layer and is found
    // at the window's own corner.
    const border_info = _gadget.infoFor(ib, win, on_border);
    try testing.expectEqual(@as(i32, 0), border_info.domain_left);
    try testing.expectEqual(@intFromPtr(win.layer), @intFromPtr(border_info.layer.?));

    // The one inside is measured from the interior's corner.
    const inside_info = _gadget.infoFor(ib, win, inside);
    try testing.expectEqual(bl, inside_info.domain_left);
    try testing.expectEqual(bt, inside_info.domain_top);
    try testing.expectEqual(@intFromPtr(win.inner_layer.?), @intFromPtr(inside_info.layer.?));

    // A press at the window's own corner is the border one's, not the
    // interior one's, though both say they sit at 0,0.
    try testing.expect(_gadget.hit(ib, win, 2, 2).gadget == on_border);
    try testing.expect(_gadget.hit(ib, win, bl + 2, bt + 2).gadget == inside);

    ib.iface().CloseWindow(gzz);
    try testing.expect(ib.iface().CloseScreen(screen));
    it.DisposeObject(inside);
    it.DisposeObject(on_border);
    display.down(ib);
    try tearDown(ib);
}

test "a group holds what it is given, and gives a member back where it found it" {
    const ib = try setUp();
    defer kexec.deinit();
    const gc = intuition.gadgetclass;
    const it = ib.iface();
    const told_class = toldClass(ib);

    const group = it.NewObjectTagList(null, classusr.GROUPGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 30 },
        .{ .tag = gc.GA_Top, .data = 20 },
        .{ .tag = gc.GA_Width, .data = 4 },
        .{ .tag = gc.GA_Height, .data = 4 },
        .{},
    }).?;

    // More than a handful: a group holds what it is given, and the
    // seventeenth is not turned away in silence.
    var members: [40]*Object = undefined;
    for (&members, 0..) |*slot, i| {
        slot.* = it.NewObjectTagList(told_class, null, &[_]TagItem{
            .{ .tag = gc.GA_Left, .data = 0 },
            .{ .tag = gc.GA_Top, .data = @as(usize, i) * 2 },
            .{ .tag = gc.GA_Width, .data = 6 },
            .{ .tag = gc.GA_Height, .data = 2 },
            .{},
        }).?;
        var add = classusr.OpMember{ .method_id = classusr.OM_ADDMEMBER, .object = slot.* };
        try testing.expect(it.SendMessage(group, @ptrCast(&add)) != 0);
    }

    // They are on a list, so anything that walks objects can walk them.
    const p = intuition.instData(groupgclass.Data, ib.group_class.?, group);
    var state: ?*sdk.exec.MinNode = p.members.head;
    var seen: u32 = 0;
    while (it.NextObject(&state)) |_| seen += 1;
    try testing.expectEqual(@as(u32, members.len), seen);

    // The group grew to hold them: the last one's bottom is its height.
    try testing.expectEqual(@as(usize, (members.len - 1) * 2 + 2), getAttr(ib, group, gc.GA_Height));

    // A member says where it is inside the group when it joins, and the
    // group adds its own corner - so the first one sits at the group's.
    try testing.expectEqual(@as(usize, 30), getAttr(ib, members[0], gc.GA_Left));
    try testing.expectEqual(@as(usize, 20), getAttr(ib, members[0], gc.GA_Top));

    // Taken out, it is put back where it said it was, so handing it to
    // another group places it once rather than twice.
    var off = classusr.OpMember{ .method_id = classusr.OM_REMMEMBER, .object = members[0] };
    try testing.expect(it.SendMessage(group, @ptrCast(&off)) != 0);
    try testing.expectEqual(@as(usize, 0), getAttr(ib, members[0], gc.GA_Left));
    try testing.expectEqual(@as(usize, 0), getAttr(ib, members[0], gc.GA_Top));

    state = p.members.head;
    seen = 0;
    while (it.NextObject(&state)) |_| seen += 1;
    try testing.expectEqual(@as(u32, members.len - 1), seen);

    it.DisposeObject(members[0]); // no longer the group's
    it.DisposeObject(group); // the rest go with it
    try testing.expect(ib.iface().FreeClass(told_class));
    try tearDown(ib);
}

test "a group tells the member that had the input that it is done" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const gc = intuition.gadgetclass;
    const it = ib.iface();
    const display = try Display.up(ib);
    const told_class = toldClass(ib);

    const member = it.NewObjectTagList(told_class, null, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 0 },
        .{ .tag = gc.GA_Top, .data = 0 },
        .{ .tag = gc.GA_Width, .data = 10 },
        .{ .tag = gc.GA_Height, .data = 10 },
        .{},
    }).?;
    const group = it.NewObjectTagList(null, classusr.GROUPGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 4 },
        .{ .tag = gc.GA_Top, .data = 4 },
        .{ .tag = gc.GA_Width, .data = 10 },
        .{ .tag = gc.GA_Height, .data = 10 },
        .{},
    }).?;
    var add = classusr.OpMember{ .method_id = classusr.OM_ADDMEMBER, .object = member };
    try testing.expect(it.SendMessage(group, @ptrCast(&add)) != 0);

    const w = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 12 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 28 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(group) },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{},
    }).?;

    // Pressed and let go again inside the member: it is taken up once and
    // put down once. Without the second the member would go on believing
    // it had the input - a field would keep its cursor for ever.
    const state = intuition.instData(Told, told_class, member);
    click(ib, 4 + 5, 12 + 4 + 5);
    try testing.expectEqual(@as(u32, 1), state.active);
    try testing.expectEqual(@as(u32, 1), state.inactive);

    // And again, which it could not be if the group still thought the
    // first press was going on.
    click(ib, 4 + 5, 12 + 4 + 5);
    try testing.expectEqual(@as(u32, 2), state.active);
    try testing.expectEqual(@as(u32, 2), state.inactive);

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    ib.iface().CloseWindow(w);
    try testing.expect(ib.iface().CloseScreen(screen));
    it.DisposeObject(group); // its member goes with it
    try testing.expect(ib.iface().FreeClass(told_class));
    display.down(ib);
    try tearDown(ib);
}

test "sliders: what stands where, in things and in fractions" {
    const pg = intuition.propgclass;

    // A hundred things with ten in view: nine of the ninety-nine gaps are
    // in view, and the knob is that much of the container. Nothing is
    // scrolled yet, so it is at the near end.
    const at_top = pg.valuesOf(100, 10, 0);
    try testing.expectEqual(@as(u32, 0), at_top.pot);
    try testing.expectEqual(@as(u32, (9 * pg.MAXBODY) / 99), at_top.body);

    // Scrolled as far as it goes: the knob is at the far end, and a top
    // past that is brought back to it.
    const at_end = pg.valuesOf(100, 10, 90);
    try testing.expectEqual(pg.MAXPOT, at_end.pot);
    try testing.expectEqual(@as(u32, 90), pg.valuesOf(100, 10, 500).top);

    // Everything in view: the knob fills the container and does not move.
    const all = pg.valuesOf(10, 10, 0);
    try testing.expectEqual(pg.MAXBODY, all.body);
    try testing.expectEqual(@as(u32, 0), all.pot);

    // One thing in view - a slider that picks a value rather than a view
    // of a list. There is no overlap to leave, so the knob is measured
    // whole against the total: a hundredth of the container, not nothing.
    // A knob of no size is one a page cannot step by.
    const one = pg.valuesOf(100, 1, 0);
    try testing.expectEqual(@as(u32, pg.MAXBODY / 100), one.body);
    try testing.expect(one.body > 0);
    try testing.expectEqual(@as(u32, 99), pg.valuesOf(100, 1, 99).top);
    try testing.expectEqual(pg.MAXPOT, pg.valuesOf(100, 1, 99).pot);

    // Two in view has one of overlap, which is where the rule begins.
    try testing.expectEqual(@as(u32, pg.MAXBODY / 99), pg.valuesOf(100, 2, 0).body);

    // A knob at the far end names the last thing that can be first, for a
    // single-thing view as much as for any other.
    try testing.expectEqual(@as(u32, 99), pg.topOf(100, 1, pg.MAXPOT));

    // And back the other way, which is what a drag answers with.
    try testing.expectEqual(@as(u32, 0), pg.topOf(100, 10, 0));
    try testing.expectEqual(@as(u32, 90), pg.topOf(100, 10, pg.MAXPOT));
    try testing.expectEqual(@as(u32, 45), pg.topOf(100, 10, pg.MAXPOT / 2));
}

test "sliders: dragged, paged, and set" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const gc = intuition.gadgetclass;
    const pg = intuition.propgclass;
    const ie = sdk.devices.inputevent;
    const it = ib.iface();
    const display = try Display.up(ib);

    // A slider down the right of a window: a hundred things, ten in view.
    const slider = it.NewObjectTagList(null, classusr.PROPGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 4 },
        .{ .tag = gc.GA_Top, .data = 4 },
        .{ .tag = gc.GA_Width, .data = 10 },
        .{ .tag = gc.GA_Height, .data = 20 },
        .{ .tag = gc.GA_ID, .data = 3 },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{ .tag = pg.PGA_Freedom, .data = pg.FREEVERT },
        .{ .tag = pg.PGA_Total, .data = 100 },
        .{ .tag = pg.PGA_Visible, .data = 50 },
        .{ .tag = pg.PGA_Top, .data = 0 },
        .{ .tag = intuition.icclass.ICA_TARGET, .data = intuition.icclass.ICTARGET_IDCMP },
        .{},
    }).?;
    const w = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 12 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 28 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(slider) },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_GADGETUP | wn.IDCMP_IDCMPUPDATE },
        .{},
    }).?;
    var got: [8]intuition.IntuiMessage = undefined;

    // What it was given in things it answers in fractions as well.
    try testing.expectEqual(@as(usize, 0), getAttr(ib, slider, pg.PGA_Top));
    try testing.expectEqual(@as(usize, 0), getAttr(ib, slider, pg.PGA_VertPot));
    try testing.expectEqual(@as(usize, (49 * pg.MAXBODY) / 99), getAttr(ib, slider, pg.PGA_VertBody));

    // Half of them are in view, so the knob is half the container and a
    // press near the top of it takes hold; dragged past the bottom it
    // stops at the last thing that can be first.
    pointerEvent(ib, ie.IECODE_LBUTTON, 8, 12 + 8);
    pointerEvent(ib, ie.IECODE_NOBUTTON, 8, 12 + 60);
    try testing.expectEqual(@as(usize, 50), getAttr(ib, slider, pg.PGA_Top));
    try testing.expectEqual(@as(usize, pg.MAXPOT), getAttr(ib, slider, pg.PGA_VertPot));
    pointerEvent(ib, ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX, 8, 12 + 60);

    // The window was told as it went and once more at the end, and then
    // that the gadget was let go.
    const n = drainMessages(ib, w, &got);
    try testing.expect(n >= 2);
    try testing.expectEqual(wn.IDCMP_IDCMPUPDATE, got[0].class);
    const told: [*]const TagItem = @ptrCast(@alignCast(got[0].iaddress.?));
    try testing.expectEqual(pg.PGA_Top, told[0].tag);
    try testing.expectEqual(wn.IDCMP_GADGETUP, got[n - 1].class);

    // Which slider moved goes with it, so a program listening to several
    // on one target can tell them apart.
    var said_id = false;
    var t: usize = 0;
    while (told[t].tag != utility.TAG_DONE) : (t += 1) {
        if (told[t].tag == gc.GA_ID) {
            try testing.expectEqual(@as(usize, 3), told[t].data);
            said_id = true;
        }
    }
    try testing.expect(said_id);

    // A program setting it moves the knob: back to the near end.
    const home = [_]TagItem{ .{ .tag = pg.PGA_Top, .data = 0 }, .{} };
    _ = ib.iface().SetGadgetAttrsTagList(slider, @ptrCast(@alignCast(w)), &home);
    try testing.expectEqual(@as(usize, 0), getAttr(ib, slider, pg.PGA_VertPot));

    // A press below the knob is a page: the last thing in view becomes the
    // first, so one line of the old view stays in the new one.
    _ = drainMessages(ib, w, &got);
    pointerEvent(ib, ie.IECODE_LBUTTON, 8, 12 + 22);
    pointerEvent(ib, ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX, 8, 12 + 22);
    try testing.expectEqual(@as(usize, 49), getAttr(ib, slider, pg.PGA_Top));

    // And a slider given fractions rather than things answers in them.
    const free = it.NewObjectTagList(null, classusr.PROPGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Width, .data = 20 },
        .{ .tag = gc.GA_Height, .data = 8 },
        .{ .tag = pg.PGA_Freedom, .data = pg.FREEHORIZ },
        .{ .tag = pg.PGA_HorizPot, .data = pg.MAXPOT / 4 },
        .{ .tag = pg.PGA_HorizBody, .data = pg.MAXBODY / 2 },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, pg.MAXPOT / 4), getAttr(ib, free, pg.PGA_HorizPot));
    try testing.expectEqual(@as(usize, pg.MAXBODY / 2), getAttr(ib, free, pg.PGA_HorizBody));
    it.DisposeObject(free);

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    ib.iface().CloseWindow(w);
    try testing.expect(ib.iface().CloseScreen(screen));
    it.DisposeObject(slider);
    display.down(ib);
    try tearDown(ib);
}

test "sliders: the flags a freedom change keeps, and one told only in fractions" {
    const ib = try setUp();
    defer kexec.deinit();
    const gc = intuition.gadgetclass;
    const pg = intuition.propgclass;
    const it = ib.iface();

    // Setting which way the knob may move changes that and nothing else.
    // The look is asked for first, so a freedom that masked the whole word
    // down to its own two bits would take it away again.
    const look = it.NewObjectTagList(null, classusr.PROPGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Width, .data = 12 },
        .{ .tag = gc.GA_Height, .data = 40 },
        .{ .tag = pg.PGA_NewLook, .data = 1 },
        .{ .tag = pg.PGA_Borderless, .data = 1 },
        .{ .tag = pg.PGA_Freedom, .data = pg.FREEVERT },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 1), getAttr(ib, look, pg.PGA_NewLook));
    try testing.expectEqual(@as(usize, 1), getAttr(ib, look, pg.PGA_Borderless));
    try testing.expectEqual(@as(usize, pg.FREEVERT), getAttr(ib, look, pg.PGA_Freedom));
    it.DisposeObject(look);

    // A slider given a pot and no counts still says which thing is first:
    // it starts with a count of its own, so the two are in step from the
    // beginning whichever the program speaks in.
    const fractions = it.NewObjectTagList(null, classusr.PROPGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Width, .data = 12 },
        .{ .tag = gc.GA_Height, .data = 40 },
        .{ .tag = pg.PGA_VertPot, .data = pg.MAXPOT },
        .{},
    }).?;
    const total = getAttr(ib, fractions, pg.PGA_Total);
    const visible = getAttr(ib, fractions, pg.PGA_Visible);
    try testing.expect(total > 0 and visible > 0 and visible < total);
    try testing.expectEqual(total - visible, getAttr(ib, fractions, pg.PGA_Top));
    // And its knob has a size, rather than the whole container.
    try testing.expect(getAttr(ib, fractions, pg.PGA_VertBody) < pg.MAXBODY);
    it.DisposeObject(fractions);

    // A knob free both ways is read along the horizontal, so that is the
    // pot `PGA_Top` follows.
    const both = it.NewObjectTagList(null, classusr.PROPGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Width, .data = 40 },
        .{ .tag = gc.GA_Height, .data = 40 },
        .{ .tag = pg.PGA_Freedom, .data = pg.FREEHORIZ | pg.FREEVERT },
        .{ .tag = pg.PGA_VertPot, .data = 0 },
        .{ .tag = pg.PGA_HorizPot, .data = pg.MAXPOT },
        .{},
    }).?;
    try testing.expectEqual(
        getAttr(ib, both, pg.PGA_Total) - getAttr(ib, both, pg.PGA_Visible),
        getAttr(ib, both, pg.PGA_Top),
    );
    it.DisposeObject(both);

    // A knob free neither way could not be used and has no axis to answer
    // on, so it is made vertical.
    const stuck = it.NewObjectTagList(null, classusr.PROPGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Width, .data = 12 },
        .{ .tag = gc.GA_Height, .data = 40 },
        .{ .tag = pg.PGA_Freedom, .data = 0 },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, pg.FREEVERT), getAttr(ib, stuck, pg.PGA_Freedom));
    it.DisposeObject(stuck);

    try tearDown(ib);
}

test "gadgets: buttons pressed, followed off and on, told about, disabled and taken out" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const gc = intuition.gadgetclass;
    const ie = sdk.devices.inputevent;
    const it = ib.iface();
    const display = try Display.up(ib);

    // A labelled button of its own frame, and one placed from the window's
    // right edge that tells the window what happens to it.
    const a = it.NewObjectTagList(null, classusr.BUTTONGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 6 },
        .{ .tag = gc.GA_Top, .data = 4 },
        .{ .tag = gc.GA_Width, .data = 20 },
        .{ .tag = gc.GA_Height, .data = 10 },
        .{ .tag = gc.GA_Text, .data = @intFromPtr("A") },
        .{ .tag = gc.GA_ID, .data = 7 },
        .{ .tag = gc.GA_Immediate, .data = 1 },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{},
    }).?;
    const b = it.NewObjectTagList(null, classusr.BUTTONGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_RelRight, .data = @bitCast(@as(isize, -25)) },
        .{ .tag = gc.GA_Top, .data = 4 },
        .{ .tag = gc.GA_Width, .data = 20 },
        .{ .tag = gc.GA_Height, .data = 10 },
        .{ .tag = gc.GA_ID, .data = 9 },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{ .tag = gc.GA_Previous, .data = @intFromPtr(a) },
        .{ .tag = intuition.icclass.ICA_TARGET, .data = intuition.icclass.ICTARGET_IDCMP },
        .{},
    }).?;
    const w = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 12 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 28 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(a) },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_GADGETDOWN | wn.IDCMP_GADGETUP | wn.IDCMP_IDCMPUPDATE },
        .{},
    }).?;
    var got: [8]intuition.IntuiMessage = undefined;

    // Both drawn when the window opened: a raised frame, the ground inside.
    // B's left is the window's width - 1 - 25.
    try testing.expectEqual(@as(u16, 0xFFFF), display.pixel(6, 12 + 4));
    try testing.expectEqual(@as(u16, 0xAD55), display.pixel(8, 12 + 6));
    try testing.expectEqual(@as(u16, 0xFFFF), display.pixel(38, 12 + 4));

    // Pressed: GADGETDOWN, and drawn selected - sunk and filled - while held.
    pointerEvent(ib, ie.IECODE_LBUTTON, 10, 12 + 8);
    try testing.expectEqual(@as(u16, 0x6457), display.pixel(8, 12 + 6));
    // Off it, it lets go; back on, it is pressed again.
    pointerEvent(ib, ie.IECODE_NOBUTTON, 40, 36);
    try testing.expectEqual(@as(u16, 0xAD55), display.pixel(8, 12 + 6));
    pointerEvent(ib, ie.IECODE_NOBUTTON, 12, 12 + 8);
    try testing.expectEqual(@as(u16, 0x6457), display.pixel(8, 12 + 6));
    // Let go over it: GADGETUP, the gadget in iaddress, and drawn let go.
    pointerEvent(ib, ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX, 12, 12 + 8);
    try testing.expectEqual(@as(u16, 0xAD55), display.pixel(8, 12 + 6));
    try testing.expectEqual(@as(usize, 2), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.IDCMP_GADGETDOWN, got[0].class);
    try testing.expectEqual(wn.IDCMP_GADGETUP, got[1].class);
    try testing.expectEqual(@as(usize, 7), getAttr(ib, @ptrCast(got[1].iaddress.?), gc.GA_ID));

    // Let go somewhere else: pressed, but no GADGETUP.
    pointerEvent(ib, ie.IECODE_LBUTTON, 10, 12 + 8);
    pointerEvent(ib, ie.IECODE_NOBUTTON, 40, 36);
    pointerEvent(ib, ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX, 40, 36);
    try testing.expectEqual(@as(usize, 1), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.IDCMP_GADGETDOWN, got[0].class);

    // B tells the window its ID - an interim update on the press, a final
    // one on the release - and then GADGETUP.
    click(ib, 45, 12 + 8);
    try testing.expectEqual(@as(usize, 3), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.IDCMP_IDCMPUPDATE, got[0].class);
    try testing.expectEqual(wn.IDCMP_IDCMPUPDATE, got[1].class);
    const told: [*]const TagItem = @ptrCast(@alignCast(got[1].iaddress.?));
    try testing.expectEqual(gc.GA_ID, told[0].tag);
    try testing.expectEqual(@as(usize, 9), told[0].data);
    try testing.expectEqual(wn.IDCMP_GADGETUP, got[2].class);

    // Disabled, A is not pressed at all.
    const off = [_]TagItem{ .{ .tag = gc.GA_Disabled, .data = 1 }, .{} };
    _ = ib.iface().SetGadgetAttrsTagList(a, @ptrCast(@alignCast(w)), &off);
    click(ib, 10, 12 + 8);
    try testing.expectEqual(@as(usize, 0), drainMessages(ib, w, &got));

    // Taken out, first B then A, each from where it was.
    try testing.expectEqual(@as(i32, 1), ib.iface().RemoveGList(@ptrCast(@alignCast(w)), b, 1));
    try testing.expectEqual(@as(i32, 0), ib.iface().RemoveGList(@ptrCast(@alignCast(w)), a, -1));
    try testing.expectEqual(@as(i32, -1), ib.iface().RemoveGList(@ptrCast(@alignCast(w)), a, 1));
    // And back in, one at the end of the other.
    try testing.expectEqual(@as(u32, 0), ib.iface().AddGList(@ptrCast(@alignCast(w)), b, -1, 1));
    try testing.expectEqual(@as(u32, 0), ib.iface().AddGList(@ptrCast(@alignCast(w)), a, 0, 1));
    try testing.expectEqual(@as(i32, 1), ib.iface().RemoveGList(@ptrCast(@alignCast(w)), b, 1));

    const s: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    ib.iface().CloseWindow(w);
    it.DisposeObject(a);
    it.DisposeObject(b);
    try testing.expect(ib.iface().CloseScreen(s));
    display.down(ib);
    try tearDown(ib);
}

test "sysiclass: it refuses an image it has no design for, and knows its own size" {
    const ib = try setUp();
    defer kexec.deinit();
    const it = ib.iface();

    // An image kind this class cannot draw is not made at all. An object
    // that answered every call and put nothing on the display would be
    // worse: the caller would never learn it had asked for nothing.
    try testing.expect(it.NewObjectTagList(ib.sys_class, null, &[_]TagItem{
        .{ .tag = ic.SYSIA_Which, .data = 9999 },
        .{},
    }) == null);

    // One it can draw has a size of its own, which is what makes it that
    // image rather than a stretched copy of one.
    const close = it.NewObjectTagList(ib.sys_class, null, &[_]TagItem{
        .{ .tag = ic.SYSIA_Which, .data = ic.CLOSEIMAGE },
        .{},
    }).?;
    try testing.expect(getAttr(ib, close, ic.IA_Width) > 0);
    try testing.expect(getAttr(ib, close, ic.IA_Height) > 0);

    // And a caller that says how big still gets what it asked for.
    const wide = it.NewObjectTagList(ib.sys_class, null, &[_]TagItem{
        .{ .tag = ic.SYSIA_Which, .data = ic.CLOSEIMAGE },
        .{ .tag = ic.IA_Width, .data = 40 },
        .{ .tag = ic.IA_Height, .data = 9 },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 40), getAttr(ib, wide, ic.IA_Width));
    try testing.expectEqual(@as(usize, 9), getAttr(ib, wide, ic.IA_Height));

    it.DisposeObject(wide);
    it.DisposeObject(close);
    try tearDown(ib);
}

test "images: a chain is drawn as one, and a button is as big as what it shows" {
    const ib = try setUp();
    defer kexec.deinit();
    const gc = intuition.gadgetclass;
    const it = ib.iface();
    const display = try Display.up(ib);

    // Two boxes of one colour, the second chained to the first. Drawing the
    // first puts both down.
    const red = graphics.penRGB(255, 0, 0);
    const blue = graphics.penRGB(0, 0, 255);
    const second = it.NewObjectTagList(null, classusr.FILLRECTCLASS, &[_]TagItem{
        .{ .tag = ic.IA_Left, .data = 10 },
        .{ .tag = ic.IA_Width, .data = 6 },
        .{ .tag = ic.IA_Height, .data = 6 },
        .{ .tag = ic.IA_FGPen, .data = blue },
        .{},
    }).?;
    const first = it.NewObjectTagList(null, classusr.FILLRECTCLASS, &[_]TagItem{
        .{ .tag = ic.IA_Width, .data = 6 },
        .{ .tag = ic.IA_Height, .data = 6 },
        .{ .tag = ic.IA_FGPen, .data = red },
        .{ .tag = ic.IA_NextImage, .data = @intFromPtr(second) },
        .{},
    }).?;

    const wn = intuition.windows;
    const w = ib.iface().OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 40 },
        .{ .tag = wn.WA_Borderless, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{},
    }).?;
    const rp: *graphics.RastPort = @ptrFromInt(windowAttr(ib, w, wn.WA_RastPort));
    ib.layers_base.LockLayer(@ptrFromInt(windowAttr(ib, w, wn.WA_Layer)));
    ib.iface().DrawImage(rp, first, 2, 2);
    ib.layers_base.UnlockLayer(@ptrFromInt(windowAttr(ib, w, wn.WA_Layer)));
    try testing.expectEqual(@as(u16, 0xF800), display.pixel(4, 4));
    try testing.expectEqual(@as(u16, 0x001F), display.pixel(14, 4));

    // A button given an image is that image's size, without being told one.
    const button = it.NewObjectTagList(null, classusr.BUTTONGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Image, .data = @intFromPtr(second) },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 6), getAttr(ib, button, gc.GA_Width));
    try testing.expectEqual(@as(usize, 6), getAttr(ib, button, gc.GA_Height));

    // And one with neither image nor frame is still hit anywhere in its box:
    // there is no shape to miss.
    const plain = it.NewObjectTagList(null, classusr.BUTTONGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Width, .data = 10 },
        .{ .tag = gc.GA_Height, .data = 10 },
        .{ .tag = gc.GA_Image, .data = @intFromPtr(second) },
        .{},
    }).?;
    const clear = [_]TagItem{ .{ .tag = gc.GA_Image, .data = 0 }, .{} };
    _ = it.SetAttrsTagList(plain, &clear);
    var ht = gc.GpHitTest{ .gadget_info = null, .mouse = .{ .x = 1, .y = 1 } };
    try testing.expectEqual(gc.GMR_GADGETHIT, it.SendMessage(plain, @ptrCast(&ht)));

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    ib.iface().CloseWindow(w);
    try testing.expect(ib.iface().CloseScreen(screen));
    it.DisposeObject(plain);
    it.DisposeObject(button);
    it.DisposeObject(first);
    it.DisposeObject(second);
    display.down(ib);
    try tearDown(ib);
}

test "frameiclass: a thick frame's edges meet on the diagonal" {
    const ib = try setUp();
    defer kexec.deinit();
    const gb = ib.graphics_base;
    const it = ib.iface();

    // A surface of its own, so every pixel of the frame can be read.
    const side = 12;
    var pixels: [side * side]u32 = undefined;
    @memset(&pixels, 0);
    var surface = sdk.rtg.bitmaps.Surface{
        .pixels = @ptrCast(&pixels),
        .width = side,
        .height = side,
        .pitch = side * 4,
        .size_bytes = side * side * 4,
        .format = .rgba32,
    };
    const rp = gb.CreateRastPortTagList(&[_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) },
        .{},
    }).?;

    const shine = graphics.penRGB(255, 255, 255);
    const shadow = graphics.penRGB(0, 0, 0);
    // A button frame: two pixels down each side, one along the top and
    // bottom. Drawn with the screen's own shine and shadow so the two can
    // be told apart.
    const o = it.NewObjectTagList(ib.frame_class, null, &[_]TagItem{
        .{ .tag = ic.IA_FrameType, .data = ic.FRAME_BUTTON },
        .{ .tag = ic.IA_EdgesOnly, .data = 1 },
        .{},
    }).?;
    var draw = ic.ImpDraw{
        .method_id = ic.IM_DRAWFRAME,
        .rast_port = rp,
        .dimensions = .{ .width = side, .height = side },
    };
    try testing.expectEqual(@as(usize, 1), it.SendMessage(o, @ptrCast(&draw)));

    const at = struct {
        fn px(p: []const u32, x: usize, y: usize) u32 {
            return p[y * side + x];
        }
    };
    // The two corners each colour owns outright.
    try testing.expectEqual(shine, at.px(&pixels, 0, 0));
    try testing.expectEqual(shadow, at.px(&pixels, side - 1, side - 1));

    // And the two the edges meet at, which a frame drawn without angled
    // joins leaves bare: the light edge reaches the bottom left, the dark
    // one the top right.
    try testing.expectEqual(shine, at.px(&pixels, 0, side - 1));
    try testing.expectEqual(shadow, at.px(&pixels, side - 1, 0));

    // Two pixels thick down each side, one along the top.
    try testing.expectEqual(shine, at.px(&pixels, 1, 5));
    try testing.expectEqual(@as(u32, 0), at.px(&pixels, 2, 5));
    try testing.expectEqual(shadow, at.px(&pixels, side - 2, 5));
    try testing.expectEqual(@as(u32, 0), at.px(&pixels, side - 3, 5));
    try testing.expectEqual(@as(u32, 0), at.px(&pixels, 5, 1));

    it.DisposeObject(o);
    gb.FreeRastPort(rp);
    try tearDown(ib);
}

test "frameiclass: how much bigger than its contents a frame has to be" {
    const ib = try setUp();
    defer kexec.deinit();
    const it = ib.iface();

    // A frame is asked how big it must be to sit around something, and it
    // answers with a box centred on it. How much bigger depends on the kind:
    // the inner frame a ridge has, plus one stroke to get inside it and one
    // for a little air, on each of the two sides.
    const kinds = [_]struct { frame: u32, pad_w: i32, pad_h: i32 }{
        .{ .frame = ic.FRAME_DEFAULT, .pad_w = 4, .pad_h = 4 },
        .{ .frame = ic.FRAME_BUTTON, .pad_w = 8, .pad_h = 4 },
        .{ .frame = ic.FRAME_RIDGE, .pad_w = 12, .pad_h = 6 },
        .{ .frame = ic.FRAME_ICONDROPBOX, .pad_w = 16, .pad_h = 8 },
    };
    for (kinds) |kind| {
        const o = it.NewObjectTagList(ib.frame_class, null, &[_]TagItem{
            .{ .tag = ic.IA_FrameType, .data = kind.frame },
            .{},
        }).?;
        const contents = ic.Box{ .left = 10, .top = 20, .width = 30, .height = 12 };
        var box = ic.Box{};
        var ask = ic.ImpFrameBox{ .contents = &contents, .frame = &box };
        try testing.expectEqual(@as(usize, 1), it.SendMessage(o, @ptrCast(&ask)));
        try testing.expectEqual(30 + kind.pad_w, box.width);
        try testing.expectEqual(12 + kind.pad_h, box.height);
        // Centred on what it holds: the same room on each side.
        try testing.expectEqual(10 - @divTrunc(kind.pad_w, 2), box.left);
        try testing.expectEqual(20 - @divTrunc(kind.pad_h, 2), box.top);

        // Told the size itself, it works out only where the frame goes.
        var given = ic.Box{ .width = 60, .height = 40 };
        var place = ic.ImpFrameBox{ .contents = &contents, .frame = &given, .flags = ic.FRAMEF_SPECIFY };
        try testing.expectEqual(@as(usize, 1), it.SendMessage(o, @ptrCast(&place)));
        try testing.expectEqual(@as(i32, 60), given.width);
        try testing.expectEqual(@as(i32, 10 - 15), given.left);
        it.DisposeObject(o);
    }
    try tearDown(ib);
}

test "frameiclass and sysiclass: a bevel sized by the message, a gadget in the pens" {
    const ib = try setUp();
    defer kexec.deinit();
    const gb = ib.graphics_base;

    var pixels: [12 * 8]u32 = @splat(0xFF112233);
    var surface = sdk.rtg.Surface{
        .pixels = @ptrCast(&pixels),
        .width = 12,
        .height = 8,
        .pitch = 12 * 4,
        .size_bytes = @sizeOf(@TypeOf(pixels)),
        .format = .bgra32,
    };
    const on = [_]TagItem{ .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) }, .{} };
    const rp = gb.CreateRastPortTagList(&on).?;

    // A button frame, drawn to 12 by 8 whatever its own size: shine along
    // the top and two columns on the left, shadow at the bottom and right,
    // the background pen inside.
    const button = [_]TagItem{ .{ .tag = ic.IA_FrameType, .data = ic.FRAME_BUTTON }, .{} };
    const frame = ib.iface().NewObjectTagList(null, classusr.FRAMEICLASS, &button).?;
    var draw = ic.ImpDraw{ .method_id = ic.IM_DRAWFRAME, .rast_port = rp, .dimensions = .{ .width = 12, .height = 8 } };
    try testing.expectEqual(@as(usize, 1), ib.iface().SendMessage(frame, @ptrCast(&draw)));
    const white: u32 = 0xFFFFFFFF;
    const black: u32 = 0xFF000000;
    const grey: u32 = 0xFFAAAAAA;
    try testing.expectEqual(white, pixels[0 * 12 + 5]);
    try testing.expectEqual(white, pixels[3 * 12 + 0]);
    try testing.expectEqual(white, pixels[3 * 12 + 1]);
    try testing.expectEqual(black, pixels[7 * 12 + 5]);
    try testing.expectEqual(black, pixels[3 * 12 + 11]);
    try testing.expectEqual(black, pixels[3 * 12 + 10]);
    try testing.expectEqual(grey, pixels[3 * 12 + 5]);

    // Recessed, the two swap.
    const sunk = [_]TagItem{ .{ .tag = ic.IA_Recessed, .data = 1 }, .{} };
    _ = ib.iface().SetAttrsTagList(frame, &sunk);
    _ = ib.iface().SendMessage(frame, @ptrCast(&draw));
    try testing.expectEqual(black, pixels[0 * 12 + 5]);
    try testing.expectEqual(white, pixels[7 * 12 + 5]);
    ib.iface().DisposeObject(frame);

    // A close gadget: the fill pen when active, the background pen when
    // not, with its box in the middle.
    const close_tags = [_]TagItem{
        .{ .tag = ic.SYSIA_Which, .data = ic.CLOSEIMAGE },
        .{ .tag = ic.IA_Width, .data = 12 },
        .{ .tag = ic.IA_Height, .data = 8 },
        .{},
    };
    const close = ib.iface().NewObjectTagList(null, classusr.SYSICLASS, &close_tags).?;
    // The design's box, 7,3 to 11,7 on a 20 by 11 grid, scaled to 12 by 8:
    // x 4 to 6, y 2 to 5 - outlined in shadow, shine inside.
    ib.iface().DrawImageState(rp, close, 0, 0, ic.IDS_NORMAL, null);
    try testing.expectEqual(@as(u32, 0xFF6688BB), pixels[1 * 12 + 1]);
    try testing.expectEqual(white, pixels[0 * 12 + 1]);
    try testing.expectEqual(black, pixels[2 * 12 + 4]);
    try testing.expectEqual(white, pixels[3 * 12 + 5]);
    try testing.expectEqual(black, pixels[5 * 12 + 6]);
    // A line of shine down its right side, where the title bar begins.
    try testing.expectEqual(white, pixels[3 * 12 + 11]);
    // Selected: the box in the background pen and the edge pressed.
    ib.iface().DrawImageState(rp, close, 0, 0, ic.IDS_SELECTED, null);
    try testing.expectEqual(grey, pixels[3 * 12 + 5]);
    try testing.expectEqual(black, pixels[0 * 12 + 1]);
    // Inactive: the ground is the background pen.
    ib.iface().DrawImageState(rp, close, 0, 0, ic.IDS_INACTIVENORMAL, null);
    try testing.expectEqual(grey, pixels[1 * 12 + 1]);
    ib.iface().DisposeObject(close);

    gb.FreeRastPort(rp);
    try tearDown(ib);
}

/// A RastPort over a surface of the test's own, so each pixel can be read.
const Canvas = struct {
    const side = 48;
    pixels: [side * side]u32 = [_]u32{0} ** (side * side),
    surface: sdk.rtg.bitmaps.Surface = .{},

    fn up(canvas: *Canvas, ib: *IntuitionBase) *graphics.RastPort {
        canvas.surface = .{
            .pixels = @ptrCast(&canvas.pixels),
            .width = side,
            .height = side,
            .pitch = side * 4,
            .size_bytes = side * side * 4,
            // B, G, R, A in memory: a pixel read as a u32 is the pen.
            .format = .bgra32,
        };
        return ib.graphics_base.CreateRastPortTagList(&[_]TagItem{
            .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&canvas.surface) },
            .{},
        }).?;
    }

    fn px(canvas: *const Canvas, x: usize, y: usize) u32 {
        return canvas.pixels[y * side + x];
    }
};

fn rpAttr(ib: *IntuitionBase, rp: *graphics.RastPort, tag: utility.Tag) usize {
    var value: usize = 0;
    ib.graphics_base.GetRPAttrs(rp, &[_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} });
    return value;
}

test "PrintIText: each run in its own pens and place, and the RastPort left as it was" {
    const ib = try setUp();
    defer kexec.deinit();
    const gb = ib.graphics_base;
    const it = ib.iface();
    var canvas: Canvas = .{};
    const rp = canvas.up(ib);
    const pospaz = gb.OpenFont(graphics.POSPAZNAME, 8).?;

    const green = graphics.penRGB(0, 255, 0);
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = green }, .{} });

    // A space in JAM2 is its whole cell in the back pen: 8x8 in pospaz 8,
    // with its top left where the run says, whatever the baseline.
    const red = graphics.penRGB(255, 0, 0);
    const blue = graphics.penRGB(0, 0, 255);
    var second = intuition.IntuiText{
        .back_pen = blue,
        .draw_mode = graphics.DRMD_JAM2,
        .left = 20,
        .top = 10,
        .font = pospaz,
        .text = " ",
    };
    var first = intuition.IntuiText{
        .back_pen = red,
        .draw_mode = graphics.DRMD_JAM2,
        .font = pospaz,
        .text = " ",
        .next = &second,
    };
    it.PrintIText(rp, &first, 4, 2);
    try testing.expectEqual(red, canvas.px(4, 2));
    try testing.expectEqual(red, canvas.px(11, 9));
    try testing.expectEqual(@as(u32, 0), canvas.px(12, 2));
    try testing.expectEqual(@as(u32, 0), canvas.px(4, 10));
    try testing.expectEqual(blue, canvas.px(24, 12));
    try testing.expectEqual(blue, canvas.px(31, 19));
    try testing.expectEqual(@as(u32, 0), canvas.px(32, 12));

    // The caller's pen, mode and font are its own again; the point is where
    // the last run ended.
    try testing.expectEqual(@as(usize, green), rpAttr(ib, rp, graphics.RPTAG_APen));
    try testing.expectEqual(@as(usize, graphics.DRMD_JAM1), rpAttr(ib, rp, graphics.RPTAG_DrMd));
    try testing.expectEqual(@as(usize, 0), rpAttr(ib, rp, graphics.RPTAG_Font));
    var cursor: graphics.Point = .{};
    gb.GetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Cursor, .data = @intFromPtr(&cursor) }, .{} });
    try testing.expectEqual(@as(i32, 4 + 20 + 8), cursor.x);

    // Null draws nothing, and neither does a run with no text.
    it.PrintIText(rp, null, 0, 0);
    var empty = intuition.IntuiText{ .back_pen = red, .draw_mode = graphics.DRMD_JAM2, .font = pospaz };
    it.PrintIText(rp, &empty, 40, 40);
    try testing.expectEqual(@as(u32, 0), canvas.px(40, 40));

    gb.CloseFont(pospaz);
    gb.FreeRastPort(rp);
    try tearDown(ib);
}

test "IntuiTextLength: one run, in its font or the screen's default" {
    const ib = try setUp();
    defer kexec.deinit();
    const it = ib.iface();

    var three = intuition.IntuiText{ .text = "abc" };
    try testing.expectEqual(@as(i32, 3 * 8), it.IntuiTextLength(&three));

    // The runs after it are not added: each is drawn where it says.
    var after = intuition.IntuiText{ .text = "defgh" };
    three.next = &after;
    try testing.expectEqual(@as(i32, 3 * 8), it.IntuiTextLength(&three));

    var none = intuition.IntuiText{};
    try testing.expectEqual(@as(i32, 0), it.IntuiTextLength(&none));
    var empty = intuition.IntuiText{ .text = "" };
    try testing.expectEqual(@as(i32, 0), it.IntuiTextLength(&empty));

    try tearDown(ib);
}

test "DrawBorder: a line through the points, every Border of the chain, the RastPort left as it was" {
    const ib = try setUp();
    defer kexec.deinit();
    const gb = ib.graphics_base;
    const it = ib.iface();
    var canvas: Canvas = .{};
    const rp = canvas.up(ib);
    gb.Move(rp, 1, 1);

    const red = graphics.penRGB(255, 0, 0);
    const blue = graphics.penRGB(0, 0, 255);
    // A 10x6 box, and a rule of one stretch chained after it.
    const corners = [_]i32{ 0, 0, 9, 0, 9, 5, 0, 5, 0, 0 };
    const rule = [_]i32{ 0, 0, 7, 0 };
    const under = intuition.Border{ .left = 0, .top = 10, .front_pen = blue, .count = rule.len / 2, .xy = &rule };
    const box = intuition.Border{ .left = 2, .front_pen = red, .count = corners.len / 2, .xy = &corners, .next = &under };
    it.DrawBorder(rp, &box, 10, 20);

    try testing.expectEqual(red, canvas.px(12, 20)); // top left corner
    try testing.expectEqual(red, canvas.px(21, 25)); // bottom right
    try testing.expectEqual(red, canvas.px(16, 25)); // along the bottom
    try testing.expectEqual(@as(u32, 0), canvas.px(16, 22)); // inside
    try testing.expectEqual(@as(u32, 0), canvas.px(22, 20)); // past the right
    try testing.expectEqual(blue, canvas.px(10, 30));
    try testing.expectEqual(blue, canvas.px(17, 30));
    try testing.expectEqual(@as(u32, 0), canvas.px(18, 30));

    var cursor: graphics.Point = .{};
    gb.GetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Cursor, .data = @intFromPtr(&cursor) }, .{} });
    try testing.expectEqual(@as(i32, 1), cursor.x);
    try testing.expectEqual(@as(i32, 1), cursor.y);

    // One point is no line, and null is nothing.
    const dot = intuition.Border{ .front_pen = red, .count = 1, .xy = &rule };
    it.DrawBorder(rp, &dot, 40, 40);
    it.DrawBorder(rp, null, 0, 0);
    try testing.expectEqual(@as(u32, 0), canvas.px(40, 40));

    gb.FreeRastPort(rp);
    try tearDown(ib);
}

test "LockIBase: the screens held, nesting, and let go as often as taken" {
    const ib = try setUp();
    defer kexec.deinit();
    const it = ib.iface();
    const me = ib.sys_base.FindTask(null);

    try testing.expectEqual(@as(u32, 0), it.LockIBase(0));
    try testing.expectEqual(me, ib.screen_lock.owner);
    // A call that takes the same semaphore goes through while it is held.
    const again = it.LockIBase(0);
    try testing.expectEqual(@as(i16, 2), ib.screen_lock.nest_count);
    it.UnlockIBase(again);
    it.UnlockIBase(0);
    try testing.expectEqual(@as(?*exec.Task, null), ib.screen_lock.owner);
    try testing.expectEqual(@as(i16, 0), ib.screen_lock.nest_count);

    try tearDown(ib);
}

test "ZipWindow: to the box it was given and back" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const it = ib.iface();
    const display = try Display.up(ib);

    // The test display is 64 by 40.
    const zoom = wn.WindowBox{ .left = 0, .top = 0, .width = 60, .height = 36 };
    const w = it.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 4 },
        .{ .tag = wn.WA_Top, .data = 6 },
        .{ .tag = wn.WA_Width, .data = 30 },
        .{ .tag = wn.WA_Height, .data = 20 },
        .{ .tag = wn.WA_Zoom, .data = @intFromPtr(&zoom) },
        .{},
    }).?;
    it.ZipWindow(w);
    try testing.expectEqual(@as(usize, 0), windowAttr(ib, w, wn.WA_Left));
    try testing.expectEqual(@as(usize, 60), windowAttr(ib, w, wn.WA_Width));
    try testing.expectEqual(@as(usize, 36), windowAttr(ib, w, wn.WA_Height));
    it.ZipWindow(w);
    try testing.expectEqual(@as(usize, 4), windowAttr(ib, w, wn.WA_Left));
    try testing.expectEqual(@as(usize, 6), windowAttr(ib, w, wn.WA_Top));
    try testing.expectEqual(@as(usize, 30), windowAttr(ib, w, wn.WA_Width));
    try testing.expectEqual(@as(usize, 20), windowAttr(ib, w, wn.WA_Height));

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    it.CloseWindow(w);
    try testing.expect(it.CloseScreen(screen));
    display.down(ib);
    try tearDown(ib);
}

test "SetWindowTitles: each title set, left or cleared; the screen bar follows the active window" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const sc = intuition.screens;
    const it = ib.iface();
    const display = try Display.up(ib);

    const a_bar: [*:0]const u8 = "A's bar";
    const b_bar: [*:0]const u8 = "B's bar";
    const renamed: [*:0]const u8 = "Renamed";
    // The screen's own title, before any window has shown another.
    const screen = it.LockPubScreen(null).?;
    const own = screenAttr(ib, screen, sc.SA_Title);
    try testing.expect(own != 0);
    const a = it.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Width, .data = 30 },
        .{ .tag = wn.WA_Height, .data = 30 },
        .{ .tag = wn.WA_Title, .data = @intFromPtr("A") },
        .{ .tag = wn.WA_ScreenTitle, .data = @intFromPtr(a_bar) },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{},
    }).?;
    try testing.expectEqual(@intFromPtr(a_bar), screenAttr(ib, screen, sc.SA_Title));

    // The window's title changes and the screen's stays.
    it.SetWindowTitles(a, renamed, wn.TITLE_UNCHANGED);
    try testing.expectEqual(@intFromPtr(renamed), windowAttr(ib, a, wn.WA_Title));
    try testing.expectEqual(@intFromPtr(a_bar), screenAttr(ib, screen, sc.SA_Title));
    // The active window's screen title shows at once.
    it.SetWindowTitles(a, wn.TITLE_UNCHANGED, b_bar);
    try testing.expectEqual(@intFromPtr(renamed), windowAttr(ib, a, wn.WA_Title));
    try testing.expectEqual(@intFromPtr(b_bar), screenAttr(ib, screen, sc.SA_Title));

    // A window that asks for none shows the screen's own, and when the
    // active window closes, the screen says its own title again.
    const b = it.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 32 },
        .{ .tag = wn.WA_Width, .data = 30 },
        .{ .tag = wn.WA_Height, .data = 30 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{},
    }).?;
    try testing.expectEqual(own, screenAttr(ib, screen, sc.SA_Title));
    it.ActivateWindow(a);
    try testing.expectEqual(@intFromPtr(b_bar), screenAttr(ib, screen, sc.SA_Title));
    it.CloseWindow(a);
    try testing.expectEqual(own, screenAttr(ib, screen, sc.SA_Title));

    // Null clears a title.
    it.SetWindowTitles(b, null, wn.TITLE_UNCHANGED);
    try testing.expectEqual(@as(usize, 0), windowAttr(ib, b, wn.WA_Title));

    it.CloseWindow(b);
    it.UnlockPubScreen(null, screen);
    try testing.expect(it.CloseScreen(screen));
    display.down(ib);
    try tearDown(ib);
}

test "WindowLimits: 0 leaves a limit, one that does not fit is refused, a negative maximum is the screen" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const sc = intuition.screens;
    const it = ib.iface();
    const display = try Display.up(ib);

    const w = it.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Width, .data = 40 },
        .{ .tag = wn.WA_Height, .data = 30 },
        .{},
    }).?;
    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));

    const min_height = windowAttr(ib, w, wn.WA_MinHeight);
    try testing.expect(it.WindowLimits(w, 20, 0, 0, 0));
    try testing.expectEqual(@as(usize, 20), windowAttr(ib, w, wn.WA_MinWidth));
    try testing.expectEqual(min_height, windowAttr(ib, w, wn.WA_MinHeight));

    // Larger than it is: refused, and the height asked for alongside taken.
    try testing.expect(!it.WindowLimits(w, 50, 20, 0, 0));
    try testing.expectEqual(@as(usize, 20), windowAttr(ib, w, wn.WA_MinWidth));
    try testing.expectEqual(@as(usize, 20), windowAttr(ib, w, wn.WA_MinHeight));

    try testing.expect(it.WindowLimits(w, 0, 0, -1, -1));
    try testing.expectEqual(screenAttr(ib, screen, sc.SA_Width), windowAttr(ib, w, wn.WA_MaxWidth));
    try testing.expectEqual(screenAttr(ib, screen, sc.SA_Height), windowAttr(ib, w, wn.WA_MaxHeight));
    try testing.expect(!it.WindowLimits(w, 0, 0, 30, 0));

    // Sizing afterwards keeps to them.
    it.SizeWindow(w, -40, -30);
    try testing.expectEqual(@as(usize, 20), windowAttr(ib, w, wn.WA_Width));
    try testing.expectEqual(@as(usize, 20), windowAttr(ib, w, wn.WA_Height));

    it.CloseWindow(w);
    try testing.expect(it.CloseScreen(screen));
    display.down(ib);
    try tearDown(ib);
}

test "OffGadget and OnGadget: a press is swallowed while it is off, and reaches it again" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const gc = intuition.gadgetclass;
    const it = ib.iface();
    const display = try Display.up(ib);
    const told_class = toldClass(ib);

    const g = it.NewObjectTagList(told_class, null, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 10 },
        .{ .tag = gc.GA_Top, .data = 10 },
        .{ .tag = gc.GA_Width, .data = 20 },
        .{ .tag = gc.GA_Height, .data = 10 },
        .{},
    }).?;
    const w = it.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 40 },
        .{ .tag = wn.WA_Borderless, .data = 1 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(g) },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{},
    }).?;

    it.OffGadget(g, w, null);
    try testing.expectEqual(@as(usize, 1), getAttr(ib, g, gc.GA_Disabled));
    click(ib, 15, 15);
    try testing.expectEqual(@as(u32, 0), intuition.instData(Told, told_class, g).active);

    it.OnGadget(g, w, null);
    try testing.expectEqual(@as(usize, 0), getAttr(ib, g, gc.GA_Disabled));
    click(ib, 15, 15);
    try testing.expectEqual(@as(u32, 1), intuition.instData(Told, told_class, g).active);

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    it.CloseWindow(w);
    try testing.expect(it.CloseScreen(screen));
    it.DisposeObject(g);
    try testing.expect(it.FreeClass(told_class));
    display.down(ib);
    try tearDown(ib);
}

test "a disabled button is ghosted: one pixel in four in the block pen, and back when it is on" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const gc = intuition.gadgetclass;
    const it = ib.iface();
    const display = try Display.up(ib);

    const button = it.NewObjectTagList(null, classusr.BUTTONGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 8 },
        .{ .tag = gc.GA_Top, .data = 8 },
        .{ .tag = gc.GA_Width, .data = 40 },
        .{ .tag = gc.GA_Height, .data = 20 },
        .{},
    }).?;
    const w = it.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 40 },
        .{ .tag = wn.WA_Borderless, .data = 1 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(button) },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{},
    }).?;

    // The pattern is anchored to the display: on an even row the second
    // pixel of every four, on an odd row the fourth.
    const on_even = display.pixel(21, 16);
    const beside_even = display.pixel(22, 16);
    const on_odd = display.pixel(23, 17);
    const beside_odd = display.pixel(21, 17);
    it.OffGadget(button, w, null);
    try testing.expect(display.pixel(21, 16) != on_even);
    try testing.expect(display.pixel(23, 17) != on_odd);
    try testing.expectEqual(display.pixel(21, 16), display.pixel(23, 17));
    try testing.expectEqual(beside_even, display.pixel(22, 16));
    try testing.expectEqual(beside_odd, display.pixel(21, 17));

    it.OnGadget(button, w, null);
    try testing.expectEqual(on_even, display.pixel(21, 16));
    try testing.expectEqual(on_odd, display.pixel(23, 17));

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    it.CloseWindow(w);
    try testing.expect(it.CloseScreen(screen));
    it.DisposeObject(button);
    display.down(ib);
    try tearDown(ib);
}

test "an easy requester: its buttons numbered and spread, answered by a button and by the caller's own class" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const gc = intuition.gadgetclass;
    const requesters = intuition.requesters;
    const it = ib.iface();
    // What the fake board's memory holds, with room to spare for where
    // the board's rows start, so the words are short.
    const display = try Display.sized(ib, 128, 60, .rgb565);

    const ask = intuition.EasyStruct{
        .title = "Ask",
        .text_format = "%s",
        .gadget_format = "Y|N",
    };
    const stream = sdk.exec.fmtStream(.{@as([*:0]const u8, "a")});
    const req = it.BuildEasyRequestArgs(null, &ask, wn.IDCMP_MOUSEBUTTONS, &stream).?;
    const w: *_window.Window = @ptrCast(@alignCast(req));
    const request: *@import("request/_request.zig").Request = @ptrCast(@alignCast(w.request.?));

    try testing.expectEqualStrings("a", std.mem.span(request.lines[0].text.?));
    try testing.expectEqual(@as(u32, 2), request.button_count);
    const yes = request.buttons[0].?;
    const no = request.buttons[1].?;
    try testing.expectEqual(@as(usize, 1), getAttr(ib, yes, gc.GA_ID));
    try testing.expectEqual(@as(usize, 0), getAttr(ib, no, gc.GA_ID));
    try testing.expectEqual(@intFromPtr(ask.title.?), windowAttr(ib, req, wn.WA_Title));

    // Spread to the frame: the first at the left margin, the last ending at
    // the right one.
    const inner = windowAttr(ib, req, wn.WA_InnerWidth);
    const left_edge = windowAttr(ib, req, wn.WA_BorderLeft);
    try testing.expectEqual(left_edge + 4, getAttr(ib, yes, gc.GA_Left));
    try testing.expectEqual(left_edge + inner - 4, getAttr(ib, no, gc.GA_Left) + getAttr(ib, no, gc.GA_Width));

    // Nothing waiting: not answered.
    try testing.expectEqual(requesters.SYSREQ_PENDING, it.SysReqHandler(req, null, false));

    // Y, pressed and let go.
    const at_x = windowAttr(ib, req, wn.WA_Left) + getAttr(ib, yes, gc.GA_Left) + 4;
    const at_y = windowAttr(ib, req, wn.WA_Top) + getAttr(ib, yes, gc.GA_Top) + 4;
    click(ib, @intCast(at_x), @intCast(at_y));
    try testing.expectEqual(@as(i32, 1), it.SysReqHandler(req, null, false));

    // A click on the message is the caller's own class.
    var class: u32 = 0;
    const body_x = windowAttr(ib, req, wn.WA_Left) + left_edge + 8;
    const body_y = windowAttr(ib, req, wn.WA_Top) + windowAttr(ib, req, wn.WA_BorderTop) + 8;
    click(ib, @intCast(body_x), @intCast(body_y));
    try testing.expectEqual(requesters.SYSREQ_IDCMP, it.SysReqHandler(req, &class, false));
    try testing.expectEqual(wn.IDCMP_MOUSEBUTTONS, class);

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, req, wn.WA_Screen));
    it.FreeSysRequest(req);
    // A failed one answers 0, and freeing it does nothing.
    try testing.expectEqual(@as(i32, 0), it.SysReqHandler(null, null, false));
    it.FreeSysRequest(null);
    try testing.expect(it.CloseScreen(screen));
    display.down(ib);
    try tearDown(ib);
}

test "an easy requester: formatted and then split into lines, a single button centred and answering 0" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const gc = intuition.gadgetclass;
    const it = ib.iface();
    // Taller than wide, within the fake board's memory: two lines fit.
    const display = try Display.sized(ib, 96, 85, .rgb565);

    const ask = intuition.EasyStruct{
        .title = "A",
        .text_format = "%s\nb",
        .gadget_format = "OK",
    };
    const stream = sdk.exec.fmtStream(.{@as([*:0]const u8, "a")});
    const req = it.BuildEasyRequestArgs(null, &ask, 0, &stream).?;
    const w: *_window.Window = @ptrCast(@alignCast(req));
    const request: *@import("request/_request.zig").Request = @ptrCast(@alignCast(w.request.?));

    try testing.expectEqual(@as(u32, 2), request.line_count);
    try testing.expectEqualStrings("a", std.mem.span(request.lines[0].text.?));
    try testing.expectEqualStrings("b", std.mem.span(request.lines[1].text.?));
    try testing.expectEqual(&request.lines[1], request.lines[0].next.?);
    try testing.expectEqual(@as(u32, 1), request.button_count);
    const ok = request.buttons[0].?;
    try testing.expectEqual(@as(usize, 0), getAttr(ib, ok, gc.GA_ID));

    // Centred on the frame, which is the interior less a margin each side.
    const inner = windowAttr(ib, req, wn.WA_InnerWidth);
    const left_edge = windowAttr(ib, req, wn.WA_BorderLeft);
    const width = getAttr(ib, ok, gc.GA_Width);
    try testing.expectEqual(left_edge + 4 + (inner - 8 - width) / 2, getAttr(ib, ok, gc.GA_Left));

    const at_x = windowAttr(ib, req, wn.WA_Left) + getAttr(ib, ok, gc.GA_Left) + 4;
    const at_y = windowAttr(ib, req, wn.WA_Top) + getAttr(ib, ok, gc.GA_Top) + 4;
    click(ib, @intCast(at_x), @intCast(at_y));
    try testing.expectEqual(@as(i32, 0), it.SysReqHandler(req, null, false));

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, req, wn.WA_Screen));
    it.FreeSysRequest(req);
    try testing.expect(it.CloseScreen(screen));
    display.down(ib);
    try tearDown(ib);
}

test "fillrectclass: a pattern in two pens or one, a solid box without, and the frame's size" {
    const ib = try setUp();
    defer kexec.deinit();
    const gb = ib.graphics_base;
    const it = ib.iface();
    var canvas: Canvas = .{};
    const rp = canvas.up(ib);

    const red = graphics.penRGB(255, 0, 0);
    const blue = graphics.penRGB(0, 0, 255);
    // Two rows: the first four pixels, then the next four.
    const tile = [_]u8{ 0xF0, 0x00, 0x0F, 0x00 };
    const two_pens = it.NewObjectTagList(null, classusr.FILLRECTCLASS, &[_]TagItem{
        .{ .tag = ic.IA_Width, .data = 16 },
        .{ .tag = ic.IA_Height, .data = 4 },
        .{ .tag = ic.IA_FGPen, .data = red },
        .{ .tag = ic.IA_BGPen, .data = blue },
        .{ .tag = ic.IA_APattern, .data = @intFromPtr(&tile) },
        .{ .tag = ic.IA_APatSize, .data = 1 },
        .{ .tag = ic.IA_Mode, .data = graphics.DRMD_JAM2 },
        .{},
    }).?;
    it.DrawImage(rp, two_pens, 0, 0);
    try testing.expectEqual(red, canvas.px(0, 0));
    try testing.expectEqual(red, canvas.px(3, 0));
    try testing.expectEqual(blue, canvas.px(4, 0));
    try testing.expectEqual(blue, canvas.px(0, 1));
    try testing.expectEqual(red, canvas.px(4, 1));
    try testing.expectEqual(red, canvas.px(7, 1));
    // The tile repeats down the box.
    try testing.expectEqual(red, canvas.px(0, 2));
    try testing.expectEqual(red, canvas.px(4, 3));
    try testing.expectEqual(@as(u32, 0), canvas.px(0, 4));

    // JAM1 leaves a clear bit's pixel as it was; the mode is settable, and
    // setting anything says it shows.
    try testing.expectEqual(@as(u32, 1), it.SetAttrsTagList(two_pens, &[_]TagItem{ .{ .tag = ic.IA_Mode, .data = graphics.DRMD_JAM1 }, .{} }));
    it.DrawImage(rp, two_pens, 0, 10);
    try testing.expectEqual(red, canvas.px(0, 10));
    try testing.expectEqual(@as(u32, 0), canvas.px(4, 10));

    // No pattern: one colour, and IM_DRAWFRAME fills the size it is given.
    const solid = it.NewObjectTagList(null, classusr.FILLRECTCLASS, &[_]TagItem{
        .{ .tag = ic.IA_Width, .data = 4 },
        .{ .tag = ic.IA_Height, .data = 4 },
        .{ .tag = ic.IA_FGPen, .data = blue },
        .{},
    }).?;
    var frame = ic.ImpDraw{
        .method_id = ic.IM_DRAWFRAME,
        .rast_port = rp,
        .offset = .{ .x = 20, .y = 20 },
        .dimensions = .{ .width = 10, .height = 2 },
    };
    try testing.expectEqual(@as(usize, 1), it.SendMessage(solid, @ptrCast(&frame)));
    try testing.expectEqual(blue, canvas.px(20, 20));
    try testing.expectEqual(blue, canvas.px(29, 21));
    try testing.expectEqual(@as(u32, 0), canvas.px(30, 20));
    try testing.expectEqual(@as(u32, 0), canvas.px(20, 22));

    it.DisposeObject(solid);
    it.DisposeObject(two_pens);
    gb.FreeRastPort(rp);
    try tearDown(ib);
}

test "frameiclass: a frame's own attributes set, and the answer says it shows" {
    const ib = try setUp();
    defer kexec.deinit();
    const it = ib.iface();
    const frame = it.NewObjectTagList(null, classusr.FRAMEICLASS, &[_]TagItem{.{}}).?;
    const data = intuition.instData(@import("classes/frameiclass.zig").Data, ib.frame_class.?, frame);
    try testing.expectEqual(@as(u32, 0), data.flags);
    try testing.expectEqual(@as(usize, 1), it.SetAttrsTagList(frame, &[_]TagItem{
        .{ .tag = ic.IA_Recessed, .data = 1 },
        .{ .tag = ic.IA_FrameType, .data = ic.FRAME_RIDGE },
        .{},
    }));
    try testing.expect(data.flags != 0);
    try testing.expectEqual(ic.FRAME_RIDGE, data.frame_type);
    it.DisposeObject(frame);
    try tearDown(ib);
}

test "the classes against their sources: a string gadget's size and name, a framed button, a group, a system image" {
    const ib = try setUp();
    defer kexec.deinit();
    const gc = intuition.gadgetclass;
    const it = ib.iface();

    // A string gadget keeps the size its buffer was made for, and names
    // itself to its target.
    const recorder_class = recorderClass(ib);
    const recorder = it.NewObjectTagList(recorder_class, null, &[_]TagItem{.{}}).?;
    const map = [_]TagItem{ .{ .tag = gc.GA_ID, .data = REC_Value }, .{} };
    const field = it.NewObjectTagList(null, classusr.STRGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 7 },
        .{ .tag = gc.STRINGA_MaxChars, .data = 8 },
        .{ .tag = intuition.icclass.ICA_TARGET, .data = @intFromPtr(recorder) },
        .{ .tag = intuition.icclass.ICA_MAP, .data = @intFromPtr(&map) },
        .{},
    }).?;
    _ = it.SetAttrsTagList(field, &[_]TagItem{ .{ .tag = gc.STRINGA_MaxChars, .data = 100 }, .{} });
    try testing.expectEqual(@as(usize, 8), getAttr(ib, field, gc.STRINGA_MaxChars));
    // Made active, then ended by a press outside it, which tells the target.
    var code: i32 = 0;
    var active = gc.GpInput{ .method_id = gc.GM_GOACTIVE, .gadget_info = null, .event = null, .termination = &code, .mouse = .{} };
    _ = it.SendMessage(field, @ptrCast(&active));
    const press = sdk.devices.inputevent.InputEvent{
        .class = sdk.devices.inputevent.IECLASS_NEWPOINTERPOS,
        .code = sdk.devices.inputevent.IECODE_LBUTTON,
    };
    var outside = gc.GpInput{ .method_id = gc.GM_HANDLEINPUT, .gadget_info = null, .event = &press, .termination = &code, .mouse = .{ .x = -1, .y = -1 } };
    try testing.expectEqual(gc.GMR_REUSE, it.SendMessage(field, @ptrCast(&outside)));
    try testing.expectEqual(@as(usize, 7), intuition.instData(Recorder, recorder_class, recorder).last);

    // A framed button without a size is its frame round its label: the
    // default font's eight pixels a letter, and the button frame's room.
    const framed = it.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr("OK") },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 2 * 8 + 8), getAttr(ib, framed, gc.GA_Width));
    try testing.expectEqual(@as(usize, 8 + 4), getAttr(ib, framed, gc.GA_Height));
    // With an image it is the frame round the image, not the image itself.
    const picture = it.NewObjectTagList(null, classusr.FILLRECTCLASS, &[_]TagItem{
        .{ .tag = intuition.imageclass.IA_Width, .data = 10 },
        .{ .tag = intuition.imageclass.IA_Height, .data = 6 },
        .{},
    }).?;
    const pictured = it.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Image, .data = @intFromPtr(picture) },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 10 + 8), getAttr(ib, pictured, gc.GA_Width));
    try testing.expectEqual(@as(usize, 6 + 4), getAttr(ib, pictured, gc.GA_Height));

    // A group starts with no size at all.
    const group = it.NewObjectTagList(null, classusr.GROUPGCLASS, &[_]TagItem{.{}}).?;
    try testing.expectEqual(@as(usize, 0), getAttr(ib, group, gc.GA_Width));
    try testing.expectEqual(@as(usize, 0), getAttr(ib, group, gc.GA_Height));

    // A system image that does not say which is not made.
    try testing.expect(it.NewObjectTagList(null, classusr.SYSICLASS, &[_]TagItem{.{}}) == null);

    it.DisposeObject(group);
    it.DisposeObject(pictured);
    it.DisposeObject(picture);
    it.DisposeObject(framed);
    it.DisposeObject(field);
    it.DisposeObject(recorder);
    try testing.expect(it.FreeClass(recorder_class));
    try tearDown(ib);
}

test "input: the menu button is the window's with WA_RMBTrap, let go always; the middle one is told" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const ie = sdk.devices.inputevent;
    const it = ib.iface();
    const display = try Display.up(ib);

    const w = it.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 40 },
        .{ .tag = wn.WA_Borderless, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_MOUSEBUTTONS },
        .{},
    }).?;
    var got: [4]intuition.IntuiMessage = undefined;

    // Without WA_RMBTrap the press and the let-go are the menus', and the
    // window hears nothing of either.
    pointerEvent(ib, ie.IECODE_RBUTTON, 10, 10);
    pointerEvent(ib, ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX, 10, 10);
    try testing.expectEqual(@as(usize, 0), drainMessages(ib, w, &got));

    // With it, both.
    const wnd: *_window.Window = @ptrCast(@alignCast(w));
    wnd.flags |= _window.WF_RMBTRAP;
    pointerEvent(ib, ie.IECODE_RBUTTON, 10, 10);
    pointerEvent(ib, ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX, 10, 10);
    try testing.expectEqual(@as(usize, 2), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.MENUDOWN, got[0].code);
    try testing.expectEqual(wn.MENUUP, got[1].code);

    // The middle button goes through as it is, wherever the pointer is.
    pointerEvent(ib, ie.IECODE_MBUTTON, 200, 200);
    pointerEvent(ib, ie.IECODE_MBUTTON | ie.IECODE_UP_PREFIX, 200, 200);
    try testing.expectEqual(@as(usize, 2), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.MIDDLEDOWN, got[0].code);
    try testing.expectEqual(wn.MIDDLEUP, got[1].code);

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    it.CloseWindow(w);
    try testing.expect(it.CloseScreen(screen));
    display.down(ib);
    try tearDown(ib);
}

// --- menus --------------------------------------------------------------------------

/// A strip for the menu tests, on a 96 by 64 display with an 11-pixel bar:
///
/// - "Project" at 0, 30 wide, its panel's items from (5, 11): Open (0, 0),
///   Save (0, 10) with the shortcut S, More (0, 20) with two subitems A
///   (30, 0) and B (30, 10), B with the shortcut B. Each item is 40 by 10.
/// - "Opts" at 30, 30 wide, its items from (35, 11): One (0, 0), toggling,
///   and Two (0, 10), each checkable and each ruling the other out.
const TestMenus = struct {
    texts: [7]intuition.IntuiText,
    items: [7]intuition.MenuItem,
    menus: [2]intuition.Menu,

    const mn = intuition.menus;
    const open = 0;
    const save = 1;
    const more = 2;
    const sub_a = 3;
    const sub_b = 4;
    const one = 5;
    const two = 6;

    fn make(self: *TestMenus) void {
        const words = [_][*:0]const u8{ "Open", "Save", "More", "A", "B", "One", "Two" };
        for (&self.texts, words) |*text, word| text.* = .{ .text = word };
        const boxes = [_][4]i32{
            .{ 0, 0, 40, 10 },  .{ 0, 10, 40, 10 },  .{ 0, 20, 40, 10 },
            .{ 30, 0, 20, 10 }, .{ 30, 10, 20, 10 }, .{ 0, 0, 30, 10 },
            .{ 0, 10, 30, 10 },
        };
        for (&self.items, boxes, 0..) |*item, b, i| {
            item.* = .{ .left = b[0], .top = b[1], .width = b[2], .height = b[3], .item_fill = &self.texts[i] };
        }
        self.items[open].next_item = &self.items[save];
        self.items[save].next_item = &self.items[more];
        self.items[save].flags |= mn.COMMSEQ;
        self.items[save].command = 'S';
        self.items[more].sub_item = &self.items[sub_a];
        self.items[sub_a].next_item = &self.items[sub_b];
        self.items[sub_b].flags |= mn.COMMSEQ;
        self.items[sub_b].command = 'b';
        self.items[one].next_item = &self.items[two];
        self.items[one].flags |= mn.CHECKIT | mn.MENUTOGGLE;
        self.items[one].mutual_exclude = 0b10;
        self.items[two].flags |= mn.CHECKIT;
        self.items[two].mutual_exclude = 0b01;
        self.menus[0] = .{ .left = 0, .width = 30, .name = "Project", .first_item = &self.items[open], .next_menu = &self.menus[1] };
        self.menus[1] = .{ .left = 30, .width = 30, .name = "Opts", .first_item = &self.items[one] };
    }
};

/// A window for the menu tests, borderless at the bottom right, out of the
/// panels' way, active and listening for `idcmp`.
fn menuWindow(ib: *IntuitionBase, idcmp: u32, more: []const TagItem) !*intuition.Window {
    const wn = intuition.windows;
    var tags: [12]TagItem = undefined;
    const fixed = [_]TagItem{
        .{ .tag = wn.WA_Left, .data = 66 },
        .{ .tag = wn.WA_Top, .data = 44 },
        .{ .tag = wn.WA_Width, .data = 30 },
        .{ .tag = wn.WA_Height, .data = 20 },
        .{ .tag = wn.WA_Borderless, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = idcmp },
    };
    for (fixed, 0..) |t, i| tags[i] = t;
    for (more, 0..) |t, i| tags[fixed.len + i] = t;
    tags[fixed.len + more.len] = .{};
    return ib.iface().OpenWindowTagList(&tags) orelse error.NoWindow;
}

/// The next message waiting for a window, taken but not replied.
fn nextMessage(ib: *IntuitionBase, w: *intuition.Window) ?*intuition.IntuiMessage {
    const port: *exec.MsgPort = @ptrFromInt(windowAttr(ib, w, intuition.windows.WA_UserPort));
    return @ptrCast(@alignCast(ib.sys_base.GetMsg(port) orelse return null));
}

fn tickEvent(ib: *IntuitionBase) void {
    const ie = sdk.devices.inputevent;
    const e: ie.InputEvent = .{ .class = ie.IECLASS_TIMER };
    _input.handle(ib, &e);
}

fn keyEvent(ib: *IntuitionBase, code: u32, qualifier: u32) void {
    const ie = sdk.devices.inputevent;
    const e: ie.InputEvent = .{ .class = ie.IECLASS_RAWKEY, .code = code, .qualifier = qualifier };
    _input.handle(ib, &e);
}

test "menus: menu numbers, ItemAddress, the laid-out panels and OnMenu/OffMenu" {
    const ib = try setUp();
    defer kexec.deinit();
    const mn = intuition.menus;
    const it = ib.iface();
    const display = try Display.sized(ib, 96, 64, .rgb565);
    var strip: TestMenus = undefined;
    strip.make();

    try testing.expectEqual(@as(u32, 0xF820), mn.FULLMENUNUM(0, 1, mn.NOSUB));
    try testing.expectEqual(@as(u32, 1), mn.ITEMNUM(0xF820));
    try testing.expectEqual(mn.NOSUB, mn.SUBNUM(0xF820));
    try testing.expectEqual(&strip.items[TestMenus.save], it.ItemAddress(&strip.menus[0], mn.FULLMENUNUM(0, 1, mn.NOSUB)).?);
    try testing.expectEqual(&strip.items[TestMenus.sub_b], it.ItemAddress(&strip.menus[0], mn.FULLMENUNUM(0, 2, 1)).?);
    try testing.expectEqual(&strip.items[TestMenus.two], it.ItemAddress(&strip.menus[0], mn.FULLMENUNUM(1, 1, mn.NOSUB)).?);
    // A title alone, nothing at all, and what the strip does not have.
    try testing.expect(it.ItemAddress(&strip.menus[0], mn.FULLMENUNUM(0, mn.NOITEM, mn.NOSUB)) == null);
    try testing.expect(it.ItemAddress(&strip.menus[0], mn.MENUNULL) == null);
    try testing.expect(it.ItemAddress(&strip.menus[0], mn.FULLMENUNUM(0, 7, mn.NOSUB)) == null);
    try testing.expect(it.ItemAddress(null, 0) == null);

    const w = try menuWindow(ib, 0, &.{});
    // The screen's menu images, sized to its font, unless it says.
    const dri = it.GetScreenDrawInfo(@ptrFromInt(windowAttr(ib, w, intuition.windows.WA_Screen)));
    try testing.expect(dri.check_mark != null and dri.amiga_key != null);
    try testing.expectEqual(@intFromPtr(dri.check_mark), windowAttr(ib, w, intuition.windows.WA_Checkmark));
    try testing.expectEqual(@intFromPtr(dri.amiga_key), windowAttr(ib, w, intuition.windows.WA_AmigaKey));
    try testing.expectEqual(@as(i32, 8 + 7), _menu_area.imageWidth(ib, dri.check_mark));
    try testing.expectEqual(@as(i32, 8), _menu_area.imageHeight(ib, dri.amiga_key));
    it.FreeScreenDrawInfo(@ptrFromInt(windowAttr(ib, w, intuition.windows.WA_Screen)), dri);
    try testing.expect(it.SetMenuStrip(w, &strip.menus[0]));
    // Project's panel: the items' boxes (0..39 by 0..29) and the trim of
    // four across and two down, from the bar - 0 whatever the items say.
    try testing.expectEqual(@as(i32, -4), strip.menus[0].jazz_x);
    try testing.expectEqual(@as(i32, -2), strip.menus[0].jazz_y);
    try testing.expectEqual(@as(i32, 43), strip.menus[0].beat_x);
    try testing.expectEqual(@as(i32, 31), strip.menus[0].beat_y);
    // Opts' items are 30 wide; its panel still spans its title.
    try testing.expectEqual(@as(i32, 33), strip.menus[1].beat_x);

    it.OffMenu(w, mn.FULLMENUNUM(0, 1, mn.NOSUB));
    try testing.expect(strip.items[TestMenus.save].flags & mn.ITEMENABLED == 0);
    it.OffMenu(w, mn.FULLMENUNUM(0, 2, 0));
    try testing.expect(strip.items[TestMenus.sub_a].flags & mn.ITEMENABLED == 0);
    it.OffMenu(w, mn.FULLMENUNUM(1, mn.NOITEM, mn.NOSUB));
    try testing.expect(strip.menus[1].flags & mn.MENUENABLED == 0);
    it.OnMenu(w, mn.FULLMENUNUM(0, 1, mn.NOSUB));
    it.OnMenu(w, mn.FULLMENUNUM(0, 2, 0));
    it.OnMenu(w, mn.FULLMENUNUM(1, mn.NOITEM, mn.NOSUB));
    try testing.expect(strip.items[TestMenus.save].flags & mn.ITEMENABLED != 0);
    try testing.expect(strip.items[TestMenus.sub_a].flags & mn.ITEMENABLED != 0);
    try testing.expect(strip.menus[1].flags & mn.MENUENABLED != 0);
    // Nothing the strip has: nothing changes, and no strip at all is fine.
    it.OffMenu(w, mn.FULLMENUNUM(5, 0, mn.NOSUB));

    it.ClearMenuStrip(w);
    it.OffMenu(w, 0);
    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, intuition.windows.WA_Screen));
    it.CloseWindow(w);
    try testing.expect(it.CloseScreen(screen));
    display.down(ib);
    try tearDown(ib);
}

test "menus: the menu button shows the strip, the pointer highlights, letting go picks" {
    const ib = try setUp();
    defer kexec.deinit();
    const mn = intuition.menus;
    const wn = intuition.windows;
    const ie = sdk.devices.inputevent;
    const it = ib.iface();
    const display = try Display.sized(ib, 96, 64, .rgb565);
    var strip: TestMenus = undefined;
    strip.make();
    const w = try menuWindow(ib, wn.IDCMP_MENUPICK | wn.IDCMP_MOUSEBUTTONS, &.{});
    _ = it.SetMenuStrip(w, &strip.menus[0]);
    const wnd: *_window.Window = @ptrCast(@alignCast(w));
    var got: [4]intuition.IntuiMessage = undefined;

    // The ground under where the panel will be.
    const ground = display.pixel(42, 25);
    try testing.expectEqual(@as(u16, 0xAD55), ground);

    // Down over Project: the titles over the bar, its panel under it.
    pointerEvent(ib, ie.IECODE_RBUTTON, 10, 5);
    try testing.expectEqual(_menus.Stage.shown, ib.menu.stage);
    try testing.expect(ib.menu.strip != null and ib.menu.items.layer != null);
    try testing.expect(wnd.flags & _window.WF_MENUSTATE != 0);
    try testing.expect(strip.menus[0].flags & mn.MIDRAWN != 0);
    // The panel's fill beside Save's word, then inverted under the pointer.
    try testing.expectEqual(@as(u16, 0xFFFF), display.pixel(42, 25));
    pointerEvent(ib, ie.IECODE_NOBUTTON, 20, 25);
    try testing.expectEqual(mn.FULLMENUNUM(0, 1, mn.NOSUB), ib.menu.selected);
    try testing.expectEqual(@as(u16, 0x0000), display.pixel(42, 25));
    try testing.expect(strip.items[TestMenus.save].flags & mn.HIGHITEM != 0);
    // Disabled while shown: ghosted and no longer highlighted at once;
    // enabled again, highlighted again under the pointer.
    it.OffMenu(w, mn.FULLMENUNUM(0, 1, mn.NOSUB));
    try testing.expect(strip.items[TestMenus.save].flags & mn.HIGHITEM == 0);
    try testing.expect(display.pixel(42, 25) != 0x0000 or display.pixel(43, 25) != 0x0000);
    it.OnMenu(w, mn.FULLMENUNUM(0, 1, mn.NOSUB));
    try testing.expect(strip.items[TestMenus.save].flags & mn.HIGHITEM != 0);
    try testing.expectEqual(@as(u16, 0x0000), display.pixel(42, 25));
    // A whole menu disabled while its panel is open: its items can no
    // longer be highlighted.
    it.OffMenu(w, mn.FULLMENUNUM(0, mn.NOITEM, mn.NOSUB));
    try testing.expect(strip.items[TestMenus.save].flags & mn.HIGHITEM == 0);
    it.OnMenu(w, mn.FULLMENUNUM(0, mn.NOITEM, mn.NOSUB));
    try testing.expect(strip.items[TestMenus.save].flags & mn.HIGHITEM != 0);
    // Off it again, onto Open.
    pointerEvent(ib, ie.IECODE_NOBUTTON, 20, 15);
    try testing.expectEqual(@as(u16, 0xFFFF), display.pixel(42, 25));
    try testing.expect(strip.items[TestMenus.save].flags & mn.HIGHITEM == 0);

    // Over to Opts: Project's panel goes, Opts' comes.
    pointerEvent(ib, ie.IECODE_NOBUTTON, 40, 5);
    try testing.expect(strip.menus[0].flags & mn.MIDRAWN == 0);
    try testing.expect(strip.menus[1].flags & mn.MIDRAWN != 0);
    try testing.expectEqual(@as(u32, 1), mn.MENUNUM(ib.menu.drawn));

    // Back, and let go over Save: picked, alone in the chain, and the
    // screen as it was.
    pointerEvent(ib, ie.IECODE_NOBUTTON, 10, 5);
    pointerEvent(ib, ie.IECODE_NOBUTTON, 20, 25);
    pointerEvent(ib, ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX, 20, 25);
    try testing.expectEqual(_menus.Stage.idle, ib.menu.stage);
    try testing.expectEqual(@as(usize, 1), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.IDCMP_MENUPICK, got[0].class);
    try testing.expectEqual(mn.FULLMENUNUM(0, 1, mn.NOSUB), got[0].code);
    try testing.expectEqual(mn.MENUNULL, strip.items[TestMenus.save].next_select);
    try testing.expectEqual(ground, display.pixel(42, 25));
    try testing.expect(wnd.flags & _window.WF_MENUSTATE == 0);

    // Let go over nothing: MENUNULL. Over a title alone: the same.
    pointerEvent(ib, ie.IECODE_RBUTTON, 10, 5);
    pointerEvent(ib, ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX, 10, 5);
    try testing.expectEqual(@as(usize, 1), drainMessages(ib, w, &got));
    try testing.expectEqual(mn.MENUNULL, got[0].code);
    // A disabled item is not picked.
    it.OffMenu(w, mn.FULLMENUNUM(0, 0, mn.NOSUB));
    pointerEvent(ib, ie.IECODE_RBUTTON, 10, 5);
    pointerEvent(ib, ie.IECODE_NOBUTTON, 20, 15);
    pointerEvent(ib, ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX, 20, 15);
    try testing.expectEqual(@as(usize, 1), drainMessages(ib, w, &got));
    try testing.expectEqual(mn.MENUNULL, got[0].code);

    it.ClearMenuStrip(w);
    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    it.CloseWindow(w);
    try testing.expect(it.CloseScreen(screen));
    display.down(ib);
    try tearDown(ib);
}

test "menus: subitems, checkmarks, excluding each other, and picking several by dragging" {
    const ib = try setUp();
    defer kexec.deinit();
    const mn = intuition.menus;
    const wn = intuition.windows;
    const ie = sdk.devices.inputevent;
    const it = ib.iface();
    const display = try Display.sized(ib, 96, 64, .rgb565);
    var strip: TestMenus = undefined;
    strip.make();
    const w = try menuWindow(ib, wn.IDCMP_MENUPICK, &.{});
    _ = it.SetMenuStrip(w, &strip.menus[0]);
    var got: [4]intuition.IntuiMessage = undefined;

    // More opens its subitems beside it; B is picked, More itself is not.
    pointerEvent(ib, ie.IECODE_RBUTTON, 10, 5);
    pointerEvent(ib, ie.IECODE_NOBUTTON, 20, 35);
    try testing.expect(ib.menu.subs.layer != null);
    try testing.expect(strip.items[TestMenus.more].flags & mn.ISDRAWN != 0);
    pointerEvent(ib, ie.IECODE_NOBUTTON, 45, 45);
    try testing.expectEqual(mn.FULLMENUNUM(0, 2, 1), ib.menu.selected);
    pointerEvent(ib, ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX, 45, 45);
    try testing.expectEqual(@as(usize, 1), drainMessages(ib, w, &got));
    try testing.expectEqual(mn.FULLMENUNUM(0, 2, 1), got[0].code);
    try testing.expect(strip.items[TestMenus.more].flags & mn.ISDRAWN == 0);

    // Over to Opts with the select button held: One and then Two picked,
    // each checked, Two unchecking One, in that order in the chain.
    pointerEvent(ib, ie.IECODE_RBUTTON, 40, 5);
    pointerEvent(ib, ie.IECODE_NOBUTTON, 45, 15);
    pointerEvent(ib, ie.IECODE_LBUTTON, 45, 15);
    try testing.expect(strip.items[TestMenus.one].flags & mn.CHECKED != 0);
    pointerEvent(ib, ie.IECODE_NOBUTTON, 45, 25);
    try testing.expect(strip.items[TestMenus.two].flags & mn.CHECKED != 0);
    try testing.expect(strip.items[TestMenus.one].flags & mn.CHECKED == 0);
    pointerEvent(ib, ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX, 45, 25);
    pointerEvent(ib, ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX, 45, 25);
    try testing.expectEqual(@as(usize, 1), drainMessages(ib, w, &got));
    const first = mn.FULLMENUNUM(1, 0, mn.NOSUB);
    const second = mn.FULLMENUNUM(1, 1, mn.NOSUB);
    try testing.expectEqual(first, got[0].code);
    try testing.expectEqual(second, strip.items[TestMenus.one].next_select);
    try testing.expectEqual(mn.MENUNULL, strip.items[TestMenus.two].next_select);

    // Two picked again stays checked; One, which toggles, checks and then
    // unchecks.
    pointerEvent(ib, ie.IECODE_RBUTTON, 40, 5);
    pointerEvent(ib, ie.IECODE_NOBUTTON, 45, 25);
    pointerEvent(ib, ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX, 45, 25);
    try testing.expect(strip.items[TestMenus.two].flags & mn.CHECKED != 0);
    for (0..2) |round| {
        pointerEvent(ib, ie.IECODE_RBUTTON, 40, 5);
        pointerEvent(ib, ie.IECODE_NOBUTTON, 45, 15);
        pointerEvent(ib, ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX, 45, 15);
        try testing.expectEqual(round == 0, strip.items[TestMenus.one].flags & mn.CHECKED != 0);
    }
    _ = drainMessages(ib, w, &got);

    it.ClearMenuStrip(w);
    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    it.CloseWindow(w);
    try testing.expect(it.CloseScreen(screen));
    display.down(ib);
    try tearDown(ib);
}

test "menus: IDCMP_MENUVERIFY holds them back, cancels them, times out, and warns the other windows" {
    const ib = try setUp();
    defer kexec.deinit();
    const mn = intuition.menus;
    const wn = intuition.windows;
    const ie = sdk.devices.inputevent;
    const it = ib.iface();
    const display = try Display.sized(ib, 96, 64, .rgb565);
    var strip: TestMenus = undefined;
    strip.make();
    const listen = wn.IDCMP_MENUPICK | wn.IDCMP_MENUVERIFY | wn.IDCMP_MOUSEBUTTONS;
    const other = try menuWindow(ib, listen, &.{.{ .tag = wn.WA_Left, .data = 0 }});
    const w = try menuWindow(ib, listen, &.{});
    _ = it.SetMenuStrip(w, &strip.menus[0]);
    var got: [4]intuition.IntuiMessage = undefined;

    // Asked first; nothing shown until it answers.
    pointerEvent(ib, ie.IECODE_RBUTTON, 10, 5);
    try testing.expectEqual(_menus.Stage.verify, ib.menu.stage);
    try testing.expect(ib.menu.strip == null);
    const hot = nextMessage(ib, w).?;
    try testing.expectEqual(wn.IDCMP_MENUVERIFY, hot.class);
    try testing.expectEqual(mn.MENUHOT, hot.code);
    ib.sys_base.ReplyMsg(&hot.msg);
    // Then the other window is warned, and it too is waited for.
    pointerEvent(ib, ie.IECODE_NOBUTTON, 10, 5);
    try testing.expectEqual(_menus.Stage.verify, ib.menu.stage);
    const waiting = nextMessage(ib, other).?;
    try testing.expectEqual(mn.MENUWAITING, waiting.code);
    ib.sys_base.ReplyMsg(&waiting.msg);
    pointerEvent(ib, ie.IECODE_NOBUTTON, 10, 5);
    try testing.expectEqual(_menus.Stage.shown, ib.menu.stage);
    // Over, and the warned window hears so.
    pointerEvent(ib, ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX, 10, 5);
    try testing.expectEqual(@as(usize, 1), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.IDCMP_MENUPICK, got[0].class);
    try testing.expectEqual(@as(usize, 1), drainMessages(ib, other, &got));
    try testing.expectEqual(wn.IDCMP_MOUSEBUTTONS, got[0].class);
    try testing.expectEqual(wn.MENUUP, got[0].code);

    // Cancelled: no menus, and the let-go is the window's own.
    pointerEvent(ib, ie.IECODE_RBUTTON, 10, 5);
    const cancel = nextMessage(ib, w).?;
    cancel.code = mn.MENUCANCEL;
    ib.sys_base.ReplyMsg(&cancel.msg);
    pointerEvent(ib, ie.IECODE_NOBUTTON, 10, 5);
    try testing.expectEqual(_menus.Stage.idle, ib.menu.stage);
    pointerEvent(ib, ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX, 10, 5);
    try testing.expectEqual(@as(usize, 1), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.MENUUP, got[0].code);
    try testing.expectEqual(@as(usize, 0), drainMessages(ib, other, &got));

    // No answer for three seconds of ticks: no menus, and the window is
    // told nothing was picked. The late reply is freed when it comes.
    pointerEvent(ib, ie.IECODE_RBUTTON, 10, 5);
    const late = nextMessage(ib, w).?;
    for (0..31) |_| tickEvent(ib);
    try testing.expectEqual(_menus.Stage.idle, ib.menu.stage);
    try testing.expectEqual(@as(usize, 1), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.IDCMP_MENUPICK, got[0].class);
    try testing.expectEqual(mn.MENUNULL, got[0].code);
    ib.sys_base.ReplyMsg(&late.msg);
    pointerEvent(ib, ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX, 10, 5);
    _ = drainMessages(ib, w, &got);

    // Giving up while it waits: the window hears the let-go and that
    // nothing was picked.
    pointerEvent(ib, ie.IECODE_RBUTTON, 10, 5);
    const dropped = nextMessage(ib, w).?;
    pointerEvent(ib, ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX, 10, 5);
    try testing.expectEqual(_menus.Stage.idle, ib.menu.stage);
    try testing.expectEqual(@as(usize, 2), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.MENUUP, got[0].code);
    try testing.expectEqual(mn.MENUNULL, got[1].code);
    ib.sys_base.ReplyMsg(&dropped.msg);
    tickEvent(ib);

    it.ClearMenuStrip(w);
    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    it.CloseWindow(w);
    it.CloseWindow(other);
    try testing.expect(it.CloseScreen(screen));
    display.down(ib);
    try tearDown(ib);
}

test "menus: right-Amiga shortcuts, the Help key, lending, and a strip taken away while shown" {
    const ib = try setUp();
    defer kexec.deinit();
    const mn = intuition.menus;
    const wn = intuition.windows;
    const ie = sdk.devices.inputevent;
    const it = ib.iface();
    const display = try Display.sized(ib, 96, 64, .rgb565);
    var strip: TestMenus = undefined;
    strip.make();
    const listen = wn.IDCMP_MENUPICK | wn.IDCMP_MENUHELP | wn.IDCMP_RAWKEY;
    const w = try menuWindow(ib, listen, &.{.{ .tag = wn.WA_MenuHelp, .data = 1 }});
    _ = it.SetMenuStrip(w, &strip.menus[0]);
    var got: [4]intuition.IntuiMessage = undefined;

    // Right-Amiga S picks Save, and right-Amiga B the subitem B, whatever
    // the case; the key itself is not the window's. S without it is.
    keyEvent(ib, 0x21, ie.IEQUALIFIER_RCOMMAND);
    keyEvent(ib, 0x35, ie.IEQUALIFIER_RCOMMAND);
    keyEvent(ib, 0x21, 0);
    try testing.expectEqual(@as(usize, 3), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.IDCMP_MENUPICK, got[0].class);
    try testing.expectEqual(mn.FULLMENUNUM(0, 1, mn.NOSUB), got[0].code);
    try testing.expectEqual(mn.FULLMENUNUM(0, 2, 1), got[1].code);
    try testing.expectEqual(wn.IDCMP_RAWKEY, got[2].class);
    // A disabled one is no pick.
    it.OffMenu(w, mn.FULLMENUNUM(0, 1, mn.NOSUB));
    keyEvent(ib, 0x21, ie.IEQUALIFIER_RCOMMAND);
    try testing.expectEqual(@as(usize, 1), drainMessages(ib, w, &got));
    try testing.expectEqual(mn.MENUNULL, got[0].code);
    it.OnMenu(w, mn.FULLMENUNUM(0, 1, mn.NOSUB));

    // Help over Open: IDCMP_MENUHELP with Open's number, nothing picked.
    pointerEvent(ib, ie.IECODE_RBUTTON, 10, 5);
    pointerEvent(ib, ie.IECODE_NOBUTTON, 20, 15);
    keyEvent(ib, 0x5F, 0);
    try testing.expectEqual(_menus.Stage.idle, ib.menu.stage);
    try testing.expectEqual(@as(usize, 1), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.IDCMP_MENUHELP, got[0].class);
    try testing.expectEqual(mn.FULLMENUNUM(0, 0, mn.NOSUB), got[0].code);
    pointerEvent(ib, ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX, 20, 15);
    _ = drainMessages(ib, w, &got);

    // The strip taken away while shown: the session ends, nothing picked.
    pointerEvent(ib, ie.IECODE_RBUTTON, 10, 5);
    it.ClearMenuStrip(w);
    try testing.expectEqual(_menus.Stage.idle, ib.menu.stage);
    try testing.expectEqual(@as(usize, 1), drainMessages(ib, w, &got));
    try testing.expectEqual(mn.MENUNULL, got[0].code);
    pointerEvent(ib, ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX, 10, 5);
    _ = drainMessages(ib, w, &got);
    _ = it.SetMenuStrip(w, &strip.menus[0]);

    // A window with no menus of its own lends w's: w is active for the
    // session, gets the pick, and the lender is active again after.
    const lender = try menuWindow(ib, 0, &.{.{ .tag = wn.WA_Left, .data = 0 }});
    it.LendMenus(lender, w);
    try testing.expectEqual(@as(usize, 1), windowAttr(ib, lender, wn.WA_Active));
    pointerEvent(ib, ie.IECODE_RBUTTON, 10, 5);
    try testing.expectEqual(@as(usize, 1), windowAttr(ib, w, wn.WA_Active));
    pointerEvent(ib, ie.IECODE_NOBUTTON, 20, 15);
    pointerEvent(ib, ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX, 20, 15);
    try testing.expectEqual(@as(usize, 1), windowAttr(ib, lender, wn.WA_Active));
    try testing.expectEqual(@as(usize, 1), drainMessages(ib, w, &got));
    try testing.expectEqual(mn.FULLMENUNUM(0, 0, mn.NOSUB), got[0].code);

    // The window closing while its menus are shown ends them, and the loan
    // with it.
    it.ActivateWindow(w);
    pointerEvent(ib, ie.IECODE_RBUTTON, 10, 5);
    try testing.expectEqual(_menus.Stage.shown, ib.menu.stage);
    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    it.CloseWindow(w);
    try testing.expectEqual(_menus.Stage.idle, ib.menu.stage);
    const lender_window: *_window.Window = @ptrCast(@alignCast(lender));
    try testing.expect(lender_window.menu_lend == null);
    pointerEvent(ib, ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX, 10, 5);
    it.CloseWindow(lender);
    try testing.expect(it.CloseScreen(screen));
    display.down(ib);
    try tearDown(ib);
}

test "ActivateGadget gives a line of text the keys; DoGadgetMethodA fills in the GadgetInfo" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const gc = intuition.gadgetclass;
    const it = ib.iface();
    const display = try Display.up(ib);

    const field = it.NewObjectTagList(null, classusr.STRGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 2 },
        .{ .tag = gc.GA_Top, .data = 2 },
        .{ .tag = gc.GA_Width, .data = 50 },
        .{ .tag = gc.GA_Height, .data = 12 },
        .{ .tag = gc.STRINGA_MaxChars, .data = 16 },
        .{},
    }).?;
    const w = it.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 30 },
        .{ .tag = wn.WA_Borderless, .data = 1 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(field) },
        .{},
    }).?;

    // Not while the window is not the active one, nor for a requester.
    try testing.expect(!it.ActivateGadget(field, w, null));
    it.ActivateWindow(w);
    var other: intuition.Requester = .{};
    try testing.expect(!it.ActivateGadget(field, w, &other));
    // Disabled, no.
    it.OffGadget(field, w, null);
    try testing.expect(!it.ActivateGadget(field, w, null));
    it.OnGadget(field, w, null);

    // Then it takes the keys without having been clicked: A, deutsch.
    try testing.expect(it.ActivateGadget(field, w, null));
    try testing.expectEqual(field, ib.input.active.?);
    keyEvent(ib, 0x20, 0);
    keyEvent(ib, 0x20 | sdk.devices.inputevent.IECODE_UP_PREFIX, 0);
    var text: usize = 0;
    _ = it.GetAttr(gc.STRINGA_TextVal, field, &text);
    try testing.expectEqualStrings("a", std.mem.span(@as([*:0]const u8, @ptrFromInt(text))));
    // Something has the input already: a second time is refused.
    try testing.expect(!it.ActivateGadget(field, w, null));

    // Any gadget method: the GadgetInfo second, for this window.
    var probe = gc.GpHitTest{ .gadget_info = null, .mouse = .{ .x = 1, .y = 1 } };
    try testing.expectEqual(gc.GMR_GADGETHIT, it.DoGadgetMethodA(field, w, null, @ptrCast(&probe)));
    try testing.expect(probe.gadget_info != null);
    try testing.expectEqual(@intFromPtr(w), @intFromPtr(probe.gadget_info.?.window));
    // OM_SET's is third; without a window there is none.
    const tags = [_]TagItem{ .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr("xy") }, .{} };
    var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
    _ = it.DoGadgetMethodA(field, w, null, @ptrCast(&set));
    try testing.expect(set.gadget_info != null);
    _ = it.DoGadgetMethodA(field, null, null, @ptrCast(&set));
    try testing.expect(set.gadget_info == null);
    _ = it.GetAttr(gc.STRINGA_TextVal, field, &text);
    try testing.expectEqualStrings("xy", std.mem.span(@as([*:0]const u8, @ptrFromInt(text))));

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    it.CloseWindow(w);
    try testing.expect(it.CloseScreen(screen));
    it.DisposeObject(field);
    display.down(ib);
    try tearDown(ib);
}

// --- requesters in a window ---------------------------------------------------------

fn pointerEventAt(ib: *IntuitionBase, code: u32, x: i32, y: i32, seconds: u32) void {
    const ie = sdk.devices.inputevent;
    const e: ie.InputEvent = .{ .class = ie.IECLASS_NEWPOINTERPOS, .code = code, .x = x, .y = y, .time = .{ .secs = seconds } };
    _input.handle(ib, &e);
}

fn tickEventAt(ib: *IntuitionBase, seconds: u32) void {
    const ie = sdk.devices.inputevent;
    const e: ie.InputEvent = .{ .class = ie.IECLASS_TIMER, .time = .{ .secs = seconds } };
    _input.handle(ib, &e);
}

fn testButton(ib: *IntuitionBase, id: usize, left: i32, top: i32, end: bool) *Object {
    const gc = intuition.gadgetclass;
    return ib.iface().NewObjectTagList(null, classusr.BUTTONGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = @intCast(left) },
        .{ .tag = gc.GA_Top, .data = @intCast(top) },
        .{ .tag = gc.GA_Width, .data = 16 },
        .{ .tag = gc.GA_Height, .data = 8 },
        .{ .tag = gc.GA_ID, .data = id },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{ .tag = gc.GA_EndGadget, .data = @intFromBool(end) },
        .{},
    }).?;
}

test "requesters: one up in front of its window, only its gadgets pressed, an end gadget takes it down" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const rq = intuition.requesters;
    const it = ib.iface();
    const display = try Display.sized(ib, 96, 64, .rgb565);

    // A window at (10, 10), 60 by 40, with a button of its own at its top
    // left; a requester at (20, 10) in it, 30 by 20, filled in white, with
    // an end gadget at its top left.
    const own = testButton(ib, 1, 2, 2, false);
    const w = it.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 10 },
        .{ .tag = wn.WA_Top, .data = 10 },
        .{ .tag = wn.WA_Width, .data = 60 },
        .{ .tag = wn.WA_Height, .data = 40 },
        .{ .tag = wn.WA_Borderless, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(own) },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_GADGETUP | wn.IDCMP_REQSET | wn.IDCMP_REQCLEAR | wn.IDCMP_RAWKEY },
        .{},
    }).?;
    const wnd: *_window.Window = @ptrCast(@alignCast(w));
    const ok = testButton(ib, 7, 2, 2, true);
    var box: intuition.Requester = undefined;
    it.InitRequester(&box);
    box.left = 20;
    box.top = 10;
    box.width = 30;
    box.height = 20;
    box.back_fill = graphics.penRGB(0xFF, 0xFF, 0xFF);
    box.gadgets = ok;
    var got: [4]intuition.IntuiMessage = undefined;

    const under = display.pixel(10 + 20 + 25, 10 + 10 + 15);
    try testing.expect(it.Request(&box, w));
    try testing.expect(!it.Request(&box, w)); // already up
    try testing.expect(box.layer != null and box.flags & rq.REQACTIVE != 0);
    try testing.expect(wnd.flags & _window.WF_INREQUEST != 0);
    try testing.expectEqual(@as(u16, 0xFFFF), display.pixel(10 + 20 + 25, 10 + 10 + 15));
    try testing.expectEqual(@as(usize, 1), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.IDCMP_REQSET, got[0].class);
    try testing.expectEqual(@intFromPtr(&box), @intFromPtr(got[0].iaddress));

    // The window's own button is not pressed, nor are keys the window's.
    click(ib, 10 + 5, 10 + 5);
    keyEvent(ib, 0x20, 0);
    try testing.expectEqual(@as(usize, 0), drainMessages(ib, w, &got));
    // The requester's is, and ends it: GADGETUP, then REQCLEAR.
    click(ib, 10 + 20 + 2 + 5, 10 + 10 + 2 + 4);
    try testing.expectEqual(@as(usize, 2), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.IDCMP_GADGETUP, got[0].class);
    try testing.expectEqual(wn.IDCMP_REQCLEAR, got[1].class);
    try testing.expect(box.layer == null and box.flags & rq.REQACTIVE == 0);
    try testing.expect(wnd.first_request == null and wnd.flags & _window.WF_INREQUEST == 0);
    try testing.expectEqual(under, display.pixel(10 + 20 + 25, 10 + 10 + 15));
    // And the window's own button works again.
    click(ib, 10 + 5, 10 + 5);
    try testing.expectEqual(@as(usize, 1), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.IDCMP_GADGETUP, got[0].class);

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    it.CloseWindow(w);
    try testing.expect(it.CloseScreen(screen));
    it.DisposeObject(ok);
    it.DisposeObject(own);
    display.down(ib);
    try tearDown(ib);
}

test "requesters: stacked, placed by POINTREL, noisy, moved with the window, cut by it, and closed with it" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const rq = intuition.requesters;
    const gc = intuition.gadgetclass;
    const it = ib.iface();
    const display = try Display.sized(ib, 96, 64, .rgb565);

    const w = it.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 10 },
        .{ .tag = wn.WA_Top, .data = 10 },
        .{ .tag = wn.WA_Width, .data = 60 },
        .{ .tag = wn.WA_Height, .data = 40 },
        .{ .tag = wn.WA_MinWidth, .data = 10 },
        .{ .tag = wn.WA_MinHeight, .data = 10 },
        .{ .tag = wn.WA_Borderless, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_GADGETUP | wn.IDCMP_REQSET | wn.IDCMP_REQCLEAR | wn.IDCMP_RAWKEY | wn.IDCMP_MOUSEBUTTONS },
        .{},
    }).?;
    const wnd: *_window.Window = @ptrCast(@alignCast(w));
    var got: [4]intuition.IntuiMessage = undefined;

    // In the middle, and kept inside when it is moved out of it.
    const first_button = testButton(ib, 1, 2, 2, false);
    var first: intuition.Requester = .{ .width = 30, .height = 20, .flags = rq.POINTREL, .gadgets = first_button };
    try testing.expect(it.Request(&first, w));
    try testing.expectEqual(@as(i32, 15), first.left);
    try testing.expectEqual(@as(i32, 10), first.top);
    var second: intuition.Requester = .{ .width = 20, .height = 10, .flags = rq.POINTREL | rq.NOISYREQ, .rel_left = 100 };
    try testing.expect(it.Request(&second, w));
    try testing.expectEqual(@as(i32, 40), second.left);
    try testing.expectEqual(&second, wnd.first_request.?);
    try testing.expectEqual(@as(u32, 2), wnd.req_count);
    _ = drainMessages(ib, w, &got);

    // The one in front is noisy: presses it does not take and keys reach
    // the window, and the older one's gadgets are not pressed.
    click(ib, 10 + 15 + 2 + 5, 10 + 10 + 2 + 4);
    keyEvent(ib, 0x20, 0);
    try testing.expectEqual(@as(usize, 3), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.IDCMP_MOUSEBUTTONS, got[0].class);
    try testing.expectEqual(wn.IDCMP_RAWKEY, got[2].class);

    // The older one taken down from behind; the newer stays up. Then the
    // first again, and its gadget answers and takes the input by call.
    it.EndRequest(&first, w);
    try testing.expectEqual(&second, wnd.first_request.?);
    try testing.expectEqual(@as(u32, 1), wnd.req_count);
    it.EndRequest(&second, w);
    try testing.expect(it.Request(&first, w));
    _ = drainMessages(ib, w, &got);
    click(ib, 10 + 15 + 2 + 5, 10 + 10 + 2 + 4);
    try testing.expectEqual(@as(usize, 1), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.IDCMP_GADGETUP, got[0].class);
    // Its gadget is measured from its corner, drawn through its layer.
    var probe = gc.GpHitTest{ .gadget_info = null, .mouse = .{ .x = 1, .y = 1 } };
    _ = it.DoGadgetMethodA(first_button, w, &first, @ptrCast(&probe));
    try testing.expectEqual(@intFromPtr(&first), @intFromPtr(probe.gadget_info.?.requester));
    try testing.expectEqual(@as(i32, 15), probe.gadget_info.?.domain_left);
    try testing.expectEqual(@intFromPtr(first.layer), @intFromPtr(probe.gadget_info.?.layer));
    it.OffGadget(first_button, w, &first);
    click(ib, 10 + 15 + 2 + 5, 10 + 10 + 2 + 4);
    try testing.expectEqual(@as(usize, 0), drainMessages(ib, w, &got));
    it.OnGadget(first_button, w, &first);

    // Moved with the window, carried as it is.
    it.MoveWindow(w, 10, 5);
    var bounds: graphics.Rect = .{};
    ib.layers_base.GetLayerAttrs(first.layer.?, &[_]TagItem{ .{ .tag = sdk.layers.LATAG_GetBounds, .data = @intFromPtr(&bounds) }, .{} });
    try testing.expectEqual(@as(i32, 20 + 15), bounds.min_x);
    try testing.expectEqual(@as(i32, 15 + 10), bounds.min_y);
    // Sized so that it is cut, then so that it is outside altogether.
    it.SizeWindow(w, -20, 0);
    try testing.expect(first.flags & rq.REQOFFWINDOW != 0);
    ib.layers_base.GetLayerAttrs(first.layer.?, &[_]TagItem{ .{ .tag = sdk.layers.LATAG_GetBounds, .data = @intFromPtr(&bounds) }, .{} });
    try testing.expectEqual(@as(i32, 20 + 40), bounds.max_x);
    it.SizeWindow(w, -30, -25);
    try testing.expect(first.layer == null and first.flags & rq.REQACTIVE != 0);
    it.SizeWindow(w, 50, 25);
    try testing.expect(first.layer != null);

    // Closing the window takes it down with nothing told.
    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    it.CloseWindow(w);
    try testing.expect(first.flags & rq.REQACTIVE == 0 and first.layer == null);
    try testing.expect(it.CloseScreen(screen));
    it.DisposeObject(first_button);
    display.down(ib);
    try tearDown(ib);
}

test "requesters: a double-click of the menu button puts up the double-click requester after IDCMP_REQVERIFY" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const mn = intuition.menus;
    const ie = sdk.devices.inputevent;
    const it = ib.iface();
    const display = try Display.sized(ib, 96, 64, .rgb565);
    var strip: TestMenus = undefined;
    strip.make();
    const w = try menuWindow(ib, wn.IDCMP_MENUPICK | wn.IDCMP_REQVERIFY | wn.IDCMP_REQSET | wn.IDCMP_REQCLEAR, &.{});
    _ = it.SetMenuStrip(w, &strip.menus[0]);
    const wnd: *_window.Window = @ptrCast(@alignCast(w));
    var quick: intuition.Requester = .{ .width = 20, .height = 10, .flags = intuition.requesters.POINTREL };
    try testing.expect(it.SetDMRequest(w, &quick));
    var got: [4]intuition.IntuiMessage = undefined;

    // One press, held past the double-click time: the menus, as ever.
    pointerEventAt(ib, ie.IECODE_RBUTTON, 70, 50, 10);
    try testing.expectEqual(_menus.Stage.dmr, ib.menu.stage);
    try testing.expect(ib.menu.strip != null);
    tickEventAt(ib, 12);
    try testing.expectEqual(_menus.Stage.shown, ib.menu.stage);
    pointerEventAt(ib, ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX, 70, 50, 12);
    _ = drainMessages(ib, w, &got);

    // Pressed and let go, then nothing in time: nothing picked.
    pointerEventAt(ib, ie.IECODE_RBUTTON, 70, 50, 20);
    pointerEventAt(ib, ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX, 70, 50, 20);
    try testing.expect(ib.menu.strip == null);
    tickEventAt(ib, 22);
    try testing.expectEqual(_menus.Stage.idle, ib.menu.stage);
    try testing.expectEqual(@as(usize, 1), drainMessages(ib, w, &got));
    try testing.expectEqual(mn.MENUNULL, got[0].code);

    // Twice in time: asked with REQVERIFY, then up under the pointer.
    pointerEventAt(ib, ie.IECODE_RBUTTON, 70, 50, 30);
    pointerEventAt(ib, ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX, 70, 50, 30);
    pointerEventAt(ib, ie.IECODE_RBUTTON, 72, 51, 31);
    const verify = nextMessage(ib, w).?;
    try testing.expectEqual(wn.IDCMP_REQVERIFY, verify.class);
    ib.sys_base.ReplyMsg(&verify.msg);
    tickEventAt(ib, 31);
    try testing.expectEqual(&quick, wnd.first_request.?);
    try testing.expectEqual(@as(i32, 72 - 66), quick.left);
    try testing.expectEqual(@as(usize, 1), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.IDCMP_REQSET, got[0].class);
    // Refused to change while it is up; the menu button is the
    // requester's now.
    try testing.expect(!it.ClearDMRequest(w));
    pointerEventAt(ib, ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX, 72, 51, 31);
    pointerEventAt(ib, ie.IECODE_RBUTTON, 72, 51, 40);
    try testing.expectEqual(_menus.Stage.idle, ib.menu.stage);
    it.EndRequest(&quick, w);
    try testing.expect(it.ClearDMRequest(w));

    it.ClearMenuStrip(w);
    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    it.CloseWindow(w);
    try testing.expect(it.CloseScreen(screen));
    display.down(ib);
    try tearDown(ib);
}

/// A system requester's lines and buttons, what BuildSysRequestTagList makes of
/// the texts.
fn sysRequestOf(req: *intuition.Window) *@import("request/_request.zig").Request {
    const w: *_window.Window = @ptrCast(@alignCast(req));
    return @ptrCast(@alignCast(w.request.?));
}

test "BuildSysRequestTagList: a line a run of the body" {
    const ib = try setUp();
    defer kexec.deinit();
    const it = ib.iface();
    // Tall enough for two lines and a button under them.
    const display = try Display.sized(ib, 96, 85, .rgb565);

    var second = intuition.IntuiText{ .text = "b" };
    const body = intuition.IntuiText{ .text = "a", .next = &second };
    const no = intuition.IntuiText{ .text = "N" };
    const req = it.BuildSysRequestTagList(null, &[_]TagItem{
        .{ .tag = intuition.requesters.SYSREQ_Body, .data = @intFromPtr(&body) },
        .{ .tag = intuition.requesters.SYSREQ_Negative, .data = @intFromPtr(&no) },
        .{},
    }).?;
    const request = sysRequestOf(req);
    try testing.expectEqual(@as(u32, 2), request.line_count);
    try testing.expectEqualStrings("a", std.mem.span(request.lines[0].text.?));
    try testing.expectEqualStrings("b", std.mem.span(request.lines[1].text.?));
    try testing.expectEqual(@as(u32, 1), request.button_count);
    it.FreeSysRequest(req);

    const screen = it.LockPubScreen(null).?;
    it.UnlockPubScreen(null, screen);
    try testing.expect(it.CloseScreen(screen));
    display.down(ib);
    try tearDown(ib);
}

test "BuildSysRequestTagList: the left button 1, the right 0, the words taken as they are; DoubleClick" {
    const ib = try setUp();
    defer kexec.deinit();
    const gc = intuition.gadgetclass;
    const it = ib.iface();
    // What the fake board's memory holds with room to spare, wide enough
    // for two buttons.
    const display = try Display.sized(ib, 128, 60, .rgb565);

    const body = intuition.IntuiText{ .text = "b%s" };
    const yes = intuition.IntuiText{ .text = "Y" };
    const no = intuition.IntuiText{ .text = "N" };
    const req = it.BuildSysRequestTagList(null, &[_]TagItem{
        .{ .tag = intuition.requesters.SYSREQ_Body, .data = @intFromPtr(&body) },
        .{ .tag = intuition.requesters.SYSREQ_Positive, .data = @intFromPtr(&yes) },
        .{ .tag = intuition.requesters.SYSREQ_Negative, .data = @intFromPtr(&no) },
        .{},
    }).?;
    // Without its body or its right button there is nothing to show.
    try testing.expect(it.BuildSysRequestTagList(null, &[_]TagItem{
        .{ .tag = intuition.requesters.SYSREQ_Body, .data = @intFromPtr(&body) },
        .{},
    }) == null);
    const request = sysRequestOf(req);
    try testing.expectEqualStrings("b%s", std.mem.span(request.lines[0].text.?));
    try testing.expectEqual(@as(u32, 2), request.button_count);
    var id: usize = 9;
    _ = it.GetAttr(gc.GA_ID, request.buttons[0], &id);
    try testing.expectEqual(@as(usize, 1), id);
    _ = it.GetAttr(gc.GA_ID, request.buttons[1], &id);
    try testing.expectEqual(@as(usize, 0), id);
    it.FreeSysRequest(req);

    try testing.expect(it.DoubleClick(10, 0, 11, 499_999));
    try testing.expect(!it.DoubleClick(10, 0, 11, 500_000));
    try testing.expect(!it.DoubleClick(10, 0, 9, 0));

    const screen = it.LockPubScreen(null).?;
    it.UnlockPubScreen(null, screen);
    try testing.expect(it.CloseScreen(screen));
    display.down(ib);
    try tearDown(ib);
}

test "IDCMP_SIZEVERIFY: sizing waits for the reply, is given up by letting go or by silence, and NEWSIZE ends it" {
    const ib = try setUp();
    defer kexec.deinit();
    const wn = intuition.windows;
    const ie = sdk.devices.inputevent;
    const it = ib.iface();
    const display = try Display.up(ib);

    // At (4, 12), 56 by 26, its size gadget in the bottom right ten rows;
    // a zoom gadget at the right of its bar, flipping to 30 by 20.
    const zoom = wn.WindowBox{ .left = -1, .top = -1, .width = 30, .height = 20 };
    const w = it.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 4 },
        .{ .tag = wn.WA_Top, .data = 12 },
        .{ .tag = wn.WA_Width, .data = 56 },
        .{ .tag = wn.WA_Height, .data = 26 },
        .{ .tag = wn.WA_MinWidth, .data = 20 },
        .{ .tag = wn.WA_MinHeight, .data = 15 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_Zoom, .data = @intFromPtr(&zoom) },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_SIZEVERIFY | wn.IDCMP_NEWSIZE },
        .{},
    }).?;
    const wnd: *_window.Window = @ptrCast(@alignCast(w));
    var got: [4]intuition.IntuiMessage = undefined;

    // Pressed: asked, and nothing moves until the reply.
    pointerEvent(ib, ie.IECODE_LBUTTON, 55, 35);
    const asked = nextMessage(ib, w).?;
    try testing.expectEqual(wn.IDCMP_SIZEVERIFY, asked.class);
    pointerEvent(ib, ie.IECODE_NOBUTTON, 50, 30);
    try testing.expectEqual(@as(i32, 56), wnd.width);
    ib.sys_base.ReplyMsg(&asked.msg);
    pointerEvent(ib, ie.IECODE_NOBUTTON, 50, 30);
    try testing.expectEqual(@as(i32, 56 - 5), wnd.width);
    pointerEvent(ib, ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX, 50, 30);
    try testing.expect(drainMessages(ib, w, &got) >= 1);
    try testing.expectEqual(wn.IDCMP_NEWSIZE, got[0].class);

    // Pressed and let go before the reply: no sizing, NEWSIZE says it is
    // over, and the late reply is freed.
    pointerEvent(ib, ie.IECODE_LBUTTON, 50, 30);
    const early = nextMessage(ib, w).?;
    pointerEvent(ib, ie.IECODE_NOBUTTON, 45, 28);
    pointerEvent(ib, ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX, 45, 28);
    try testing.expectEqual(@as(i32, 51), wnd.width);
    try testing.expectEqual(@as(usize, 1), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.IDCMP_NEWSIZE, got[0].class);
    ib.sys_base.ReplyMsg(&early.msg);
    tickEvent(ib);

    // No reply for three seconds: given up the same way.
    pointerEvent(ib, ie.IECODE_LBUTTON, 50, 30);
    const silent = nextMessage(ib, w).?;
    for (0..31) |_| tickEvent(ib);
    try testing.expectEqual(@as(usize, 1), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.IDCMP_NEWSIZE, got[0].class);
    pointerEvent(ib, ie.IECODE_NOBUTTON, 40, 28);
    try testing.expectEqual(@as(i32, 51), wnd.width);
    pointerEvent(ib, ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX, 40, 28);
    ib.sys_base.ReplyMsg(&silent.msg);
    tickEvent(ib);

    // Answered and let go without moving: NEWSIZE all the same.
    pointerEvent(ib, ie.IECODE_LBUTTON, 50, 30);
    ib.sys_base.ReplyMsg(&nextMessage(ib, w).?.msg);
    pointerEvent(ib, ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX, 50, 30);
    try testing.expectEqual(@as(usize, 1), drainMessages(ib, w, &got));
    try testing.expectEqual(wn.IDCMP_NEWSIZE, got[0].class);

    // The zoom gadget: asked when let go over it, zipped once answered.
    const zoom_x = 4 + wnd.width - _window.zoom_width / 2;
    click(ib, zoom_x, 14);
    const zooming = nextMessage(ib, w).?;
    try testing.expectEqual(wn.IDCMP_SIZEVERIFY, zooming.class);
    try testing.expectEqual(@as(i32, 51), wnd.width);
    ib.sys_base.ReplyMsg(&zooming.msg);
    tickEvent(ib);
    try testing.expectEqual(@as(i32, 30), wnd.width);
    try testing.expect(drainMessages(ib, w, &got) >= 1);
    try testing.expectEqual(wn.IDCMP_NEWSIZE, got[0].class);

    const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, w, wn.WA_Screen));
    it.CloseWindow(w);
    try testing.expect(it.CloseScreen(screen));
    display.down(ib);
    try tearDown(ib);
}
