// SPDX-License-Identifier: MIT
//! Lists (exec/lists.h): doubly linked, and the list header doubles as head
//! and tail sentinel node, so inserting and removing never has to check for
//! the ends of the list.

const Node = @import("nodes.zig").Node;
const MinNode = @import("nodes.zig").MinNode;
const NodeType = @import("nodes.zig").NodeType;

/// struct List: lh_Head, lh_Tail, lh_TailPred, lh_Type.
///
/// `head` and `tail` are the succ/pred fields of the head sentinel node,
/// `tail` and `tail_pred` those of the tail sentinel. `tail` is always null.
/// The list is empty when `head` points at the tail sentinel.
pub const List = extern struct {
    head: ?*Node = null,
    tail: ?*Node = null,
    tail_pred: ?*Node = null,
    type: NodeType = .unknown,
    pad: u8 = 0,

    /// NewList() plus lh_Type.
    pub fn init(list: *List, node_type: NodeType) void {
        newList(list);
        list.type = node_type;
    }

    pub fn isEmpty(list: *List) bool {
        return list.head == list.tailNode();
    }

    pub fn first(list: *List) ?*Node {
        return if (list.isEmpty()) null else list.head;
    }

    pub fn last(list: *List) ?*Node {
        return if (list.isEmpty()) null else list.tail_pred;
    }

    /// Walks the real nodes; removing the node just returned is allowed.
    pub fn iterator(list: *List) Iterator {
        return .{ .next_node = list.head.? };
    }

    /// The head sentinel: its succ is lh_Head.
    pub fn headNode(list: *List) *Node {
        return @ptrCast(&list.head);
    }

    /// The tail sentinel: its succ is lh_Tail (null), its pred lh_TailPred.
    pub fn tailNode(list: *List) *Node {
        return @ptrCast(&list.tail);
    }
};

pub const Iterator = struct {
    next_node: *Node,

    pub fn next(it: *Iterator) ?*Node {
        const node = it.next_node;
        it.next_node = node.succ orelse return null; // tail sentinel
        return node;
    }
};

/// struct MinList: mlh_Head, mlh_Tail, mlh_TailPred. A List of MinNodes,
/// without lh_Type; the same sentinel trick.
pub const MinList = extern struct {
    head: ?*MinNode = null,
    tail: ?*MinNode = null,
    tail_pred: ?*MinNode = null,

    /// NewList() for a MinList.
    pub fn init(list: *MinList) void {
        list.head = @ptrCast(&list.tail);
        list.tail = null;
        list.tail_pred = @ptrCast(&list.head);
    }

    pub fn isEmpty(list: *MinList) bool {
        return list.head == @as(?*MinNode, @ptrCast(&list.tail));
    }
};

/// NewList: make `list` empty, the sentinels point at each
/// other. lh_Type is left alone.
pub fn newList(list: *List) void {
    list.head = list.tailNode();
    list.tail = null;
    list.tail_pred = list.headNode();
}
