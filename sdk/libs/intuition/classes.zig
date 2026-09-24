// SPDX-License-Identifier: MIT
//! Classes and objects: what a class implementor sees.
//!
//! A **class** is a dispatcher - a `Hook` that is handed every message sent
//! to one of its objects - plus where its superclass is and how much
//! instance data it adds. An **object** is one allocation holding the data
//! of every class from the root down to its own, in that order, with a
//! small header in front of the handle a caller holds.
//!
//! A class passes a message it does not handle, or handles only in part,
//! on to its superclass (`SendSuperMessage`), so a subclass is written as
//! the difference from what it is made from. rootclass is at the top of
//! every chain: it is what allocates an object and frees it.
//!
//! The structures here are read-only outside intuition.library: a class is
//! made with `MakeClass` and an object with `NewObjectTagList`, and neither
//! is ever laid out by hand.

const exec = @import("../exec/exec.zig");
const hooks = @import("../utility/hooks.zig");

/// A class. Made only by `MakeClass`; the dispatcher is the owner's to
/// set, and `user_data` the owner's to use, and nothing else may be
/// written.
pub const Class = extern struct {
    /// cl_Dispatcher: called with the class (this hook), the object and the
    /// message for every message sent to an object of this class. Its
    /// `node` links the public class list.
    dispatcher: hooks.Hook = .{},
    /// cl_Reserved: 0.
    reserved: u32 = 0,
    /// cl_Super: the class this one is made from. Null only for rootclass.
    super: ?*Class = null,
    /// cl_ID: the name it is found by, or null for a private class, which
    /// is used by pointer and can never be put on the public list.
    id: ?[*:0]const u8 = null,
    /// cl_InstOffset: where in an object this class's data begins, from the
    /// object's handle. Rounded up to 8, so a class may keep 64-bit fields.
    inst_offset: u32 = 0,
    /// cl_InstSize: how much data this class adds.
    inst_size: u32 = 0,
    /// cl_UserData: the owner's, for whatever its dispatcher needs - a
    /// library that implements a class keeps its base here, since it has
    /// no globals to keep it in.
    user_data: usize = 0,
    /// cl_SubclassCount: how many classes are made from this one. A class
    /// with any cannot be freed.
    subclass_count: u32 = 0,
    /// cl_ObjectCount: how many objects of this class exist. A class with
    /// any cannot be freed.
    object_count: u32 = 0,
    /// cl_Flags: `CLF_INLIST`.
    flags: u32 = 0,
};

/// On the public list, where `FindClass` and `NewObjectTagList` by name
/// can reach it.
pub const CLF_INLIST: u32 = 0x0000_0001;

/// An object, as its handle. What is behind the handle is the instance
/// data of each of its classes in turn; `instData` finds one class's part.
pub const Object = opaque {};

/// _Object: in front of every object's handle.
pub const ObjectHeader = extern struct {
    /// o_Node: for a list the object is on (`OM_ADDTAIL`, `NextObject`).
    node: exec.MinNode = .{},
    /// o_Class: the class the object was made of - its true class, not
    /// whichever class is handling a message at the moment.
    class: *Class,
    /// Makes the header a multiple of 8 on both a 32- and a 64-bit CPU, so
    /// the data behind it keeps 8-byte alignment.
    reserved: usize = 0,
};

/// The header of an object.
pub inline fn objectHeader(o: *Object) *ObjectHeader {
    return @ptrFromInt(@intFromPtr(o) - @sizeOf(ObjectHeader));
}

/// OCLASS: the class an object was made of.
pub inline fn objectClass(o: *Object) *Class {
    return objectHeader(o).class;
}

/// INST_DATA: where `cl`'s part of an object is. `cl` is the class whose
/// dispatcher is running, which may be any class from the object's own up
/// to the root.
pub inline fn instData(comptime T: type, cl: *const Class, o: *Object) *T {
    return @ptrFromInt(@intFromPtr(o) + cl.inst_offset);
}

/// SIZEOF_INSTANCE: the whole allocation for an object of this class.
pub inline fn sizeofInstance(cl: *const Class) usize {
    return @sizeOf(ObjectHeader) + cl.inst_offset + cl.inst_size;
}
