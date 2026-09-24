// SPDX-License-Identifier: MPL-2.0
//! What the named-object calls share: the private NameSpace and Object
//! behind a NamedObject, the name-space lookup and search, and the removal
//! both RemNamedObject and AttemptRemNamedObject are.

const sdk = @import("sdk");
const exec = sdk.exec;

const UtilityBase = @import("../utility.zig").UtilityBase;
const NamedObject = sdk.utility.NamedObject;
const NSF_CASE = sdk.utility.NSF_CASE;

/// struct NameSpace (private).
pub const NameSpace = extern struct {
    /// ns_Entries: the objects, by priority.
    entries: exec.List,
    /// ns_Semaphore: shared while FindNamedObject searches, exclusive to
    /// change the entries.
    lock: exec.SignalSemaphore,
    /// ns_Flags: NSF_NODUPS, NSF_CASE.
    flags: u32,
};

/// struct NamedObj (private). One AllocVec block: this, the name space,
/// the name, the user space.
pub const Object = extern struct {
    /// no_Node: ln_Name is the copy of the name, ln_Pri is ANO_Priority.
    node: exec.Node,
    /// no_UseCount
    use_count: u16,
    /// no_object: what the caller has.
    public: NamedObject,
    /// The name space the object is in (no_NameSpace once added).
    parent: ?*NameSpace,
    /// The object's own name space from ANO_NameSpace. Kept apart from
    /// `parent`, so an object with a name space keeps it when it is added
    /// to another.
    space: ?*NameSpace,
    /// no_RemoveMsg: RemNamedObject's message, replied at the last release.
    remove_msg: ?*exec.Message,

    /// The object behind the handle a caller has.
    ///
    /// INPUTS:
    /// - `object` - the public part, as `AllocNamedObjectA` returned it.
    pub fn of(object: *NamedObject) *Object {
        return @fieldParentPtr("public", object);
    }

    /// The object a name-space node belongs to.
    ///
    /// INPUTS:
    /// - `node` - the object's node, from a name space's list.
    fn fromNode(node: *exec.Node) *Object {
        return @fieldParentPtr("node", node);
    }
};

/// The name space of an object, or the root one for null.
///
/// INPUTS:
/// - `ub` - the library, whose base holds the root name space.
/// - `name_space` - an object, or null for the root name space.
///
/// RESULT:
/// The name space, or null for an object without one.
pub fn spaceOf(ub: *UtilityBase, name_space: ?*NamedObject) ?*NameSpace {
    return Object.of(name_space orelse ub.master_space).space;
}

/// The first object of a name space, from a given node on, whose name
/// matches - with or without case as the name space says.
///
/// INPUTS:
/// - `ub` - the library, called through for `Strcmp` and `Stricmp`.
/// - `space` - the name space; the caller holds its semaphore.
/// - `start` - the node to start at: the list's head, or the node after
///   the last object found.
/// - `name` - the name; null matches any object.
pub fn search(ub: *UtilityBase, space: *NameSpace, start: *exec.Node, name: ?[*:0]const u8) ?*Object {
    const utility = ub.iface();
    var it: exec.lists.Iterator = .{ .next_node = start };
    while (it.next()) |node| {
        const obj = Object.fromNode(node);
        const wanted = name orelse return obj;
        const own = obj.node.name.?;
        const same = if (space.flags & NSF_CASE != 0)
            utility.Strcmp(own, wanted) == 0
        else
            utility.Stricmp(own, wanted) == 0;
        if (same) return obj;
    }
    return null;
}

/// What `RemNamedObject` and `AttemptRemNamedObject` both are.
///
/// With a message, the object leaves its name space at once, the caller's
/// use is given back, and the message is replied with `ln_Name` pointing to
/// the object when the last use is gone; for an object in no name space it
/// comes back at once with `ln_Name` null. Without a message, the object
/// leaves only when the caller's use is the only one.
///
/// INPUTS:
/// - `ub` - the library, called through for `ReleaseNamedObject`, and its
///   `sys_base` for exec.
/// - `object` - the object to take out.
/// - `message` - the message to reply, or null to only try.
///
/// RESULT:
/// True if the object was taken out.
///
/// CONTEXT:
/// Takes Forbid, and then the name space's semaphore, which may wait.
pub fn remNamedObject(ub: *UtilityBase, object: ?*NamedObject, message: ?*exec.Message) bool {
    const utility = ub.iface();
    ub.sys_base.Forbid();
    defer ub.sys_base.Permit();
    const obj = Object.of(object orelse return notRemoved(ub, message));
    const space = obj.parent orelse return notRemoved(ub, message);
    if (message == null and obj.use_count != 1) return false;
    obj.parent = null;
    ub.sys_base.ObtainSemaphore(&space.lock);
    ub.sys_base.Remove(&obj.node);
    obj.remove_msg = message;
    if (message) |msg| msg.node.name = @ptrFromInt(@intFromPtr(&obj.public));
    ub.sys_base.ReleaseSemaphore(&space.lock);
    utility.ReleaseNamedObject(object);
    return true;
}

/// The answer for an object that is in no name space: the message, if any,
/// comes back at once with `ln_Name` null.
///
/// INPUTS:
/// - `ub` - the library, whose `sys_base` replies the message.
/// - `message` - the message, or null.
///
/// RESULT:
/// False, always.
fn notRemoved(ub: *UtilityBase, message: ?*exec.Message) bool {
    const msg = message orelse return false;
    msg.node.name = null;
    ub.sys_base.ReplyMsg(msg);
    return false;
}
