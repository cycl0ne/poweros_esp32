// SPDX-License-Identifier: MPL-2.0
//! AllocNamedObjectA: a new named object in one block - the object, an
//! optional name space, the name and the user space - with one use.

const sdk = @import("sdk");
const exec = sdk.exec;
const _namedobjects = @import("_namedobjects.zig");

const UtilityBase = @import("../utility.zig").UtilityBase;
const TagItem = sdk.utility.TagItem;
const NamedObject = sdk.utility.NamedObject;
const ANO_NameSpace = sdk.utility.ANO_NameSpace;
const ANO_UserSpace = sdk.utility.ANO_UserSpace;
const ANO_Priority = sdk.utility.ANO_Priority;
const ANO_Flags = sdk.utility.ANO_Flags;
const NameSpace = _namedobjects.NameSpace;
const Object = _namedobjects.Object;

/// Makes a named object, with a name space and user space of its own if
/// asked for.
///
/// SYNOPSIS:
/// ```zig
/// fn AllocNamedObjectA(ub: *UtilityBase, name: ?[*:0]const u8, tag_list: ?[*]const TagItem) ?*NamedObject
/// ```
///
/// SINCE: 1.0. LVO -152.
///
/// INPUTS:
/// - `name` - the name. Copied, so the caller's string may go. Null fails.
/// - `tag_list` - options, null for none:
///   - `ANO_NameSpace` - non-zero gives the object a name space, so that
///     other objects can be added to it.
///   - `ANO_UserSpace` - bytes of user space. It is cleared and aligned to
///     a pointer, and `NamedObject.object` points to it; without it that is
///     null.
///   - `ANO_Priority` - the object's place in a name space, higher first.
///     The low 8 bits count, signed.
///   - `ANO_Flags` - its own name space's flags: `NSF_NODUPS` refuses a
///     second object of a name, `NSF_CASE` compares names with case.
///
/// RESULT:
/// The object, or null without a name or without memory.
///
/// BEHAVIOR:
/// The object, its name space, its name and its user space are one
/// allocation. The object has one use - the caller's - and is in no name
/// space until `AddNamedObject` puts it into one.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It allocates, and `AllocMem` takes Forbid.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller owns the object. `FreeNamedObject` gives it back once it is
/// in no name space.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddNamedObject`, `FreeNamedObject`, `NamedObjectName`
///
/// EXAMPLES:
/// ```zig
/// const tags = [_]TagItem{ .{ .tag = ANO_UserSpace, .data = @sizeOf(Entry) }, .{} };
/// const obj = ub.AllocNamedObjectA("fonts", &tags) orelse return error.NoMemory;
/// ```
pub fn AllocNamedObjectA(ub: *UtilityBase, name: ?[*:0]const u8, tag_list: ?[*]const TagItem) ?*NamedObject {
    const utility = ub.iface();
    const text = name orelse return null;
    const len = utility.Strlen(text);
    const space_size: usize = if (utility.GetTagData(ANO_NameSpace, 0, tag_list) != 0) @sizeOf(NameSpace) else 0;
    const user_size = utility.GetTagData(ANO_UserSpace, 0, tag_list);
    const space_at = utility.AlignUp(@sizeOf(Object), @alignOf(NameSpace));
    const name_at = space_at + space_size;
    const user_at = utility.AlignUp(name_at + len + 1, @alignOf(usize));
    const block: [*]u8 = @ptrCast(ub.sys_base.AllocVec(user_at + user_size, exec.MEMF_CLEAR) orelse return null);

    @memcpy(block[name_at..][0..len], text[0..len]);
    const priority: isize = @bitCast(utility.GetTagData(ANO_Priority, 0, tag_list));
    const obj: *Object = @ptrCast(@alignCast(block));
    obj.* = .{
        .node = .{ .name = block[name_at .. name_at + len :0].ptr, .pri = @truncate(priority) },
        .use_count = 1,
        .public = .{ .object = if (user_size != 0) @ptrCast(block + user_at) else null },
        .parent = null,
        .space = null,
        .remove_msg = null,
    };
    if (space_size != 0) {
        const space: *NameSpace = @ptrCast(@alignCast(block + space_at));
        space.entries.init(.unknown);
        ub.sys_base.InitSemaphore(&space.lock);
        space.flags = @truncate(utility.GetTagData(ANO_Flags, 0, tag_list));
        obj.space = space;
    }
    return &obj.public;
}
