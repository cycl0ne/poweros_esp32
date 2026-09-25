// SPDX-License-Identifier: MIT
//! hello.gadget: a gadget class in a library of its own, loaded from
//! `SYS:classes/gadgets/`. It is a gadgetclass and nothing more - its
//! dispatcher hands every message to gadgetclass - and it is the smallest
//! class library there is: `sdk.gadgets.ClassLibrary` makes the library,
//! the class and the ROM tag, and this file adds the dispatcher.
//!
//! A program opens it as `gadgets/hello.gadget`: ramlib finds the file as
//! `LIBS:gadgets/hello.gadget`, which the multi-assign `LIBS:` holds in
//! `SYS:classes`, and the library is called by the name's tail,
//! `hello.gadget`, which is also the class's name.
//!
//! `C:test/Classes` opens it, makes an object and disposes of it.

const sdk = @import("sdk");
const utility = sdk.utility;
const classusr = sdk.intuition.classusr;
const gadgets = sdk.gadgets;
const Class = sdk.intuition.classes.Class;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = "hello.gadget",
    .version = 1,
    .date = "25.09.2026",
    .super = classusr.GADGETCLASS,
    .Instance = struct {},
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// The class's dispatcher: everything is gadgetclass's.
fn dispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *Class = @ptrCast(hook);
    const msg: *classusr.Msg = @ptrCast(@alignCast(message orelse return 0));
    return gadgets.baseOf(cl).intuition_base.SendSuperMessage(cl, @ptrCast(object), msg);
}
