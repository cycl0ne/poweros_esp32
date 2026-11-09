// SPDX-License-Identifier: MIT
//! A directed acyclic graph of nodes the user embeds in its own
//! structures, as the QPU scheduler embeds one in each instruction's node:
//! the port of Mesa's src/util/dag.c and dag.h. The nodes with no parent
//! are the heads, kept in a list in the order they became heads; each
//! node keeps its edges to its children, each edge with a word of the
//! user's.
//!
//! Mesa allocates the edges from the DAG's ralloc context and frees them
//! with it; here each node's edges are freed with `Node.deinit`.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const list = @import("list.zig");
const Link = list.Link;

pub const Error = Allocator.Error;

/// struct dag_edge (dag.h:35).
pub const Edge = struct {
    /// Null once the edge is removed.
    child: ?*Node,
    /// The user's, for the edge.
    data: usize,
};

/// struct dag_node (dag.h:41).
pub const Node = struct {
    /// Its place among the heads, or linked to itself.
    link: Link = .{},
    edges: std.ArrayList(Edge) = .empty,
    parent_count: u32 = 0,

    pub fn deinit(node: *Node, allocator: Allocator) void {
        node.edges.deinit(allocator);
    }
};

/// struct dag (dag.h:48).
pub const Dag = struct {
    allocator: Allocator,
    heads: Link = .{},

    /// An empty DAG (dag_create, dag.c:227), in place: its heads' list
    /// is linked to itself.
    pub fn init(dag: *Dag, allocator: Allocator) void {
        dag.* = .{ .allocator = allocator };
        dag.heads.initHead();
    }

    /// `node`, embedded in the user's structure, made a head
    /// (dag_init_node, dag.c:142).
    pub fn initNode(dag: *Dag, node: *Node) void {
        node.* = .{};
        node.link.addTail(&dag.heads);
    }

    /// The child taken out of the heads, and the edge added (append_edge,
    /// dag.c:28).
    fn appendEdge(dag: *Dag, parent: *Node, child: *Node, data: usize) Error!void {
        try parent.edges.append(dag.allocator, .{ .child = child, .data = data });
        child.link.delInit();
        child.parent_count += 1;
    }

    /// An edge from `parent` to `child`, unless one with the same data is
    /// there: two may join the same nodes with different data
    /// (dag_add_edge, dag.c:49).
    pub fn addEdge(dag: *Dag, parent: *Node, child: *Node, data: usize) Error!void {
        for (parent.edges.items) |edge| {
            if (edge.child == child and edge.data == data) return;
        }
        try dag.appendEdge(parent, child, data);
    }

    /// An edge from `parent` to `child`, or the one there given the larger
    /// of the two data, as where the data is a delay
    /// (dag_add_edge_max_data, dag.c:68).
    pub fn addEdgeMaxData(dag: *Dag, parent: *Node, child: *Node, data: usize) Error!void {
        for (parent.edges.items) |*edge| {
            if (edge.child == child) {
                edge.data = @max(edge.data, data);
                return;
            }
        }
        try dag.appendEdge(parent, child, data);
    }

    /// One edge taken out, its child made a head where that was its last
    /// parent (dag_remove_edge, dag.c:88). The edge stays in its parent's
    /// list, with no child: other than through `pruneHead`, a caller
    /// walking the edges meets those.
    pub fn removeEdge(dag: *Dag, edge: *Edge) void {
        const child = edge.child orelse return;
        child.parent_count -= 1;
        if (child.parent_count == 0) child.link.addTail(&dag.heads);
        edge.child = null;
        edge.data = 0;
    }

    /// A head taken out of the graph, and the children it was the last
    /// parent of made heads, in the order of its edges (dag_prune_head,
    /// dag.c:108).
    pub fn pruneHead(dag: *Dag, node: *Node) void {
        assert(node.parent_count == 0);
        node.link.delInit();
        for (node.edges.items) |*edge| dag.removeEdge(edge);
    }

    pub const Callback = *const fn (node: *Node, data: ?*anyopaque) void;

    /// Every node given to `cb` once, each after all its children: from
    /// each head in turn, depth first, the first child first, with a
    /// stack of its own rather than recursion
    /// (dag_traverse_bottom_up_node, dag.c:159).
    fn traverseBottomUpNode(dag: *Dag, start: *Node, seen: *std.AutoHashMapUnmanaged(*Node, void), stack: *std.ArrayList(*Node), cb: Callback, data: ?*anyopaque) Error!void {
        if (seen.contains(start)) return;
        stack.clearRetainingCapacity();
        var current: ?*Node = start;
        while (current) |first| {
            var node = first;
            while (node.edges.items.len != 0) {
                try stack.append(dag.allocator, node);
                // The children not yet seen, the last first, so that the
                // first is taken next; one may be on the stack already.
                var at = node.edges.items.len;
                while (at > 0) {
                    at -= 1;
                    const child = node.edges.items[at].child.?;
                    if (!seen.contains(child)) try stack.append(dag.allocator, child);
                }
                // The first child, or the node itself where all its
                // children have been seen.
                const top = stack.pop().?;
                if (top == node) break;
                node = top;
            }

            cb(node, data);
            try seen.put(dag.allocator, node, {});

            // The next on the stack not seen yet.
            current = null;
            while (stack.pop()) |next| {
                if (!seen.contains(next)) {
                    current = next;
                    break;
                }
            }
        }
    }

    /// Every node given to `cb` once, each after all its children, from
    /// the leaves up (dag_traverse_bottom_up, dag.c:212).
    pub fn traverseBottomUp(dag: *Dag, cb: Callback, data: ?*anyopaque) Error!void {
        var seen: std.AutoHashMapUnmanaged(*Node, void) = .empty;
        defer seen.deinit(dag.allocator);
        var stack: std.ArrayList(*Node) = .empty;
        defer stack.deinit(dag.allocator);
        var heads = list.Each(Node, "link", .forward){ .head = &dag.heads, .pos = dag.heads.next.? };
        while (heads.next()) |node| try dag.traverseBottomUpNode(node, &seen, &stack, cb, data);
    }

    const ValidateState = struct {
        stack: std.AutoHashMapUnmanaged(*Node, void) = .empty,
        seen: std.AutoHashMapUnmanaged(*Node, void) = .empty,
    };

    /// dag_validate_node (dag.c:245), recursing as Mesa does.
    fn validateNode(dag: *Dag, node: *Node, state: *ValidateState) Error!?*Node {
        if (state.stack.contains(node)) return node;
        if (state.seen.contains(node)) return null;
        try state.stack.put(dag.allocator, node, {});
        try state.seen.put(dag.allocator, node, {});
        for (node.edges.items) |edge| {
            if (try dag.validateNode(edge.child.?, state)) |cycle| return cycle;
        }
        _ = state.stack.remove(node);
        return null;
    }

    /// The node a cycle comes back to, or null where there is none
    /// (dag_validate, dag.c:280). Mesa prints the nodes on the path, by a
    /// callback of the caller's, and aborts.
    pub fn validate(dag: *Dag) Error!?*Node {
        var state: ValidateState = .{};
        defer state.stack.deinit(dag.allocator);
        defer state.seen.deinit(dag.allocator);
        var heads = list.Each(Node, "link", .forward){ .head = &dag.heads, .pos = dag.heads.next.? };
        while (heads.next()) |node| {
            if (try dag.validateNode(node, &state)) |cycle| return cycle;
        }
        return null;
    }
};

const testing = std.testing;

const Item = struct {
    name: u8,
    node: Node = .{},

    fn of(node: *Node) *Item {
        return @fieldParentPtr("node", node);
    }
};

fn expectHeads(dag: *Dag, names: []const u8) !void {
    var buffer: [16]u8 = undefined;
    var count: usize = 0;
    var heads = list.Each(Node, "link", .forward){ .head = &dag.heads, .pos = dag.heads.next.? };
    while (heads.next()) |node| {
        buffer[count] = Item.of(node).name;
        count += 1;
    }
    try testing.expectEqualStrings(names, buffer[0..count]);
}

const Visits = struct {
    names: [16]u8 = undefined,
    count: usize = 0,

    fn visit(node: *Node, data: ?*anyopaque) void {
        const visits: *Visits = @ptrCast(@alignCast(data.?));
        visits.names[visits.count] = Item.of(node).name;
        visits.count += 1;
    }
};

fn deinitItems(items: []Item) void {
    for (items) |*item| item.node.deinit(testing.allocator);
}

test "a node is a head until it has a parent, and becomes one again when its last parent is pruned" {
    var dag: Dag = undefined;
    dag.init(testing.allocator);
    var items = [_]Item{ .{ .name = 'a' }, .{ .name = 'b' }, .{ .name = 'c' }, .{ .name = 'd' } };
    defer deinitItems(&items);
    for (&items) |*item| dag.initNode(&item.node);
    try expectHeads(&dag, "abcd");

    const a = &items[0].node;
    const b = &items[1].node;
    const c = &items[2].node;
    const d = &items[3].node;
    try dag.addEdge(a, c, 0);
    try dag.addEdge(a, b, 0);
    try dag.addEdge(b, d, 0);
    try dag.addEdge(c, d, 0);
    try expectHeads(&dag, "a");
    try testing.expectEqual(@as(u32, 2), d.parent_count);

    // The edge order, not the names': c before b.
    dag.pruneHead(a);
    try expectHeads(&dag, "cb");
    dag.pruneHead(c);
    try expectHeads(&dag, "b");
    try testing.expectEqual(@as(?*Node, null), a.edges.items[0].child);
    dag.pruneHead(b);
    try expectHeads(&dag, "d");
}

test "an edge again with the same data is not added, with other data it is, or takes the larger" {
    var dag: Dag = undefined;
    dag.init(testing.allocator);
    var items = [_]Item{ .{ .name = 'a' }, .{ .name = 'b' }, .{ .name = 'c' } };
    defer deinitItems(&items);
    for (&items) |*item| dag.initNode(&item.node);
    const a = &items[0].node;
    const b = &items[1].node;
    const c = &items[2].node;

    try dag.addEdge(a, b, 1);
    try dag.addEdge(a, b, 1);
    try testing.expectEqual(@as(usize, 1), a.edges.items.len);
    try dag.addEdge(a, b, 2);
    try testing.expectEqual(@as(usize, 2), a.edges.items.len);
    try testing.expectEqual(@as(u32, 2), b.parent_count);

    try dag.addEdgeMaxData(a, c, 5);
    try dag.addEdgeMaxData(a, c, 3);
    try dag.addEdgeMaxData(a, c, 7);
    try testing.expectEqual(@as(usize, 3), a.edges.items.len);
    try testing.expectEqual(@as(usize, 7), a.edges.items[2].data);
    try testing.expectEqual(@as(u32, 1), c.parent_count);

    // One edge removed: b has a parent still, through the other.
    dag.removeEdge(&a.edges.items[0]);
    try testing.expectEqual(@as(u32, 1), b.parent_count);
    try testing.expectEqual(@as(usize, 0), a.edges.items[0].data);
    dag.removeEdge(&a.edges.items[0]);
    try testing.expectEqual(@as(u32, 1), b.parent_count);
    try expectHeads(&dag, "a");
}

test "the bottom-up walk takes each node once, after its children, the first child first" {
    var dag: Dag = undefined;
    dag.init(testing.allocator);
    var items = [_]Item{ .{ .name = 'a' }, .{ .name = 'b' }, .{ .name = 'c' }, .{ .name = 'd' }, .{ .name = 'e' }, .{ .name = 'f' } };
    defer deinitItems(&items);
    for (&items) |*item| dag.initNode(&item.node);
    const a = &items[0].node;
    const b = &items[1].node;
    const c = &items[2].node;
    const d = &items[3].node;
    const e = &items[4].node;
    const f = &items[5].node;
    try dag.addEdge(a, b, 0);
    try dag.addEdge(a, c, 0);
    try dag.addEdge(b, d, 0);
    try dag.addEdge(c, d, 0);
    try dag.addEdge(e, d, 0);
    try dag.addEdge(e, f, 0);
    try expectHeads(&dag, "ae");

    var visits: Visits = .{};
    try dag.traverseBottomUp(Visits.visit, &visits);
    try testing.expectEqualStrings("dbcafe", visits.names[0..visits.count]);
}

test "a cycle is found where it comes back" {
    var dag: Dag = undefined;
    dag.init(testing.allocator);
    var items = [_]Item{ .{ .name = 'a' }, .{ .name = 'b' }, .{ .name = 'c' } };
    defer deinitItems(&items);
    for (&items) |*item| dag.initNode(&item.node);
    const a = &items[0].node;
    const b = &items[1].node;
    const c = &items[2].node;
    try dag.addEdge(a, b, 0);
    try dag.addEdge(b, c, 0);
    try testing.expectEqual(@as(?*Node, null), try dag.validate());
    // c back to b: a stays the head it was.
    try dag.addEdge(c, b, 0);
    try testing.expectEqual(@as(?*Node, b), try dag.validate());
}
