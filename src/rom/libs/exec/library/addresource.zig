// SPDX-License-Identifier: MPL-2.0
//! AddResource: puts a resource on exec's resource list by priority, where
//! `OpenResource` finds it by name.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const Node = sdk.exec.Node;

/// Puts a resource on the resource list, where `OpenResource` finds it.
///
/// SYNOPSIS:
/// ```zig
/// fn AddResource(base: *ExecBase, resource: *anyopaque) void
/// ```
///
/// SINCE: 1.0. LVO -388.
///
/// INPUTS:
/// - `resource` - anything beginning with a Node whose name and priority
///   are set. In practice a library base, so that callers reach it through
///   a jump table.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The node's type becomes a resource and it is enqueued by priority.
///
/// `InitResident` does this for a ROM tag whose type is a resource, so a
/// resource in the image is added without anyone calling this.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It takes Forbid.
/// - Forbid: taken here, around the list.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The resource must outlive its place on the list,
/// which in practice means for ever.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenResource`, `RemResource`, `InitResident`
///
/// EXAMPLES:
/// ```zig
/// sys.AddResource(base);
/// ```
pub fn AddResource(base: *ExecBase, resource: *anyopaque) void {
    const node: *Node = @ptrCast(@alignCast(resource));
    const sys = base.iface();
    sys.Forbid();
    defer sys.Permit();
    node.type = .resource;
    sys.Enqueue(&base.resource_list, node);
}
