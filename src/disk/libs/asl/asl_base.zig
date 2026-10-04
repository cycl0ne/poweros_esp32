// SPDX-License-Identifier: MIT
//! asl.library's base: exec's Library header, the libraries the
//! requesters are built from, and the list of the requesters that have
//! been made.
//!
//! One base is shared by every opener, as exec's standard Open and Close
//! give it. A requester is a thing of its own on that list, and what it
//! answered belongs to it, so two programs asking at once do not meet.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const DiskfontBase = sdk.interface.diskfont.DiskfontBase;

/// The gadget classes a requester makes its gadgets from. They are opened
/// when the library is, because a requester that cannot be built is no
/// use and the failure is better seen at the open than at the request.
pub const class_libraries = [_][*:0]const u8{
    sdk.gadgets.string.STRING_LIBRARY,
    sdk.gadgets.listview.LISTVIEW_LIBRARY,
    sdk.gadgets.text.TEXT_LIBRARY,
    sdk.gadgets.scroller.SCROLLER_LIBRARY,
    sdk.gadgets.checkbox.CHECKBOX_LIBRARY,
    sdk.gadgets.cycle.CYCLE_LIBRARY,
    sdk.gadgets.palette.PALETTE_LIBRARY,
};

pub const AslBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    seg_list: ?*anyopaque = null,
    dos_base: *DosBase,
    intuition_base: *IntuitionBase,
    graphics_base: *GraphicsBase,
    utility_base: *UtilityBase,
    /// diskfont.library, which the font requester lists fonts with. It is
    /// opened at the first font request rather than at the library's
    /// open: a program that only ever asks for a file never loads it.
    diskfont_base: ?*DiskfontBase = null,
    /// The class libraries of `class_libraries`, in that order.
    classes: [class_libraries.len]?*exec.Library = @splat(null),
    /// Every requester made and not yet freed, so the expunge can refuse
    /// while one is out.
    requesters: exec.MinList = .{},
    /// The list above, which any opener's task changes: a spinlock.
    requester_lock: exec.Lock = .{},
};

/// The base from exec's Library header.
pub fn aslBase(lib: *exec.Library) *AslBase {
    return @fieldParentPtr("lib", lib);
}

/// diskfont.library, opened the first time a font requester wants it and
/// kept until the last opener of this library has gone. Null when it
/// cannot be opened, which is a font requester that cannot be shown.
pub fn diskfontOf(ab: *AslBase) ?*DiskfontBase {
    if (ab.diskfont_base) |df| return df;
    const lib = ab.sys_base.OpenLibrary(sdk.diskfont.DISKFONTNAME, 0) orelse return null;
    ab.diskfont_base = @ptrCast(lib);
    return ab.diskfont_base;
}
