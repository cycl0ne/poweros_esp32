// SPDX-License-Identifier: MIT
//! A register allocator by graph colouring: the port of Mesa's
//! src/util/register_allocate.c, which its V3D compiler gives temporaries
//! registers with (allocate.zig). A node is anything that wants a
//! register, an edge between two that they cannot have the same one.
//! Simplify takes nodes out of the graph onto a stack, each one that its
//! neighbours left cannot keep from a register - Runeson and Nyström's
//! test of "Retargetable Graph-Coloring Register Allocation for Irregular
//! Architectures", the sum of q(B, C) over the neighbours below p(B) - and
//! where none is, the one whose neighbours weigh least, on the chance it
//! gets one anyway. Select gives them back their registers off the
//! stack, each one its coloured neighbours do not have.
//!
//! What the V3D uses is ported: classes of registers in a row, one
//! register long on the V3D; nodes forced to a register; the driver's own
//! choice among the registers a node may have, through a callback; and
//! the choice of a node to spill. So is Mesa's choice of the lowest
//! register where there is no callback, which Mesa's own tests, and
//! these, allocate with. Left out are conflicts between the registers of
//! a set (ra_add_reg_conflict, the transitive ones and the conflict
//! lists), which a set of classes in a row does not have,
//! ra_class_override_p, ra_set_allocate_round_robin, and the set's
//! serialization; Mesa's ralloc is the allocator a set and a graph are
//! made with.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error;

/// No register (NO_REG, register_allocate.h:132).
pub const no_reg: u32 = std.math.maxInt(u32);

/// The bits of Mesa's BITSET_WORD.
const word_bits = 32;

/// BITSET_WORDS: the words a set of `count` bits takes.
pub fn bitsetWords(count: u64) usize {
    return @intCast((count + word_bits - 1) / word_bits);
}

fn bitTest(set: []const u32, i: u64) bool {
    return set[@intCast(i / word_bits)] & (@as(u32, 1) << @intCast(i % word_bits)) != 0;
}

fn bitSet(set: []u32, i: u64) void {
    set[@intCast(i / word_bits)] |= @as(u32, 1) << @intCast(i % word_bits);
}

fn bitClear(set: []u32, i: u64) void {
    set[@intCast(i / word_bits)] &= ~(@as(u32, 1) << @intCast(i % word_bits));
}

/// BITSET_BIT
fn bit(j: u32) u32 {
    return @as(u32, 1) << @intCast(j);
}

/// A set of registers, and the classes of them nodes are given (struct
/// ra_regs, register_allocate_internal.h:52).
pub const Regs = struct {
    allocator: Allocator,
    count: u32,
    /// In the order they were made, which is their index.
    classes: std.ArrayList(*Class) = .empty,

    /// ra_alloc_reg_set (register_allocate.c:90), without conflict lists,
    /// which a set of classes in a row has no use for.
    pub fn create(allocator: Allocator, count: u32) Error!*Regs {
        const regs = try allocator.create(Regs);
        regs.* = .{ .allocator = allocator, .count = count };
        return regs;
    }

    pub fn destroy(regs: *Regs) void {
        for (regs.classes.items) |class| {
            regs.allocator.free(class.regs);
            regs.allocator.free(class.q);
            regs.allocator.destroy(class);
        }
        regs.classes.deinit(regs.allocator);
        regs.allocator.destroy(regs);
    }

    /// A class whose allocations are each `contig_len` registers in a row,
    /// starting at a register of the class (ra_alloc_contig_reg_class,
    /// register_allocate.c:253, on ra_alloc_reg_class, :226). A class's
    /// index is the order it was made in, from 0, which users rely on.
    pub fn allocContigClass(regs: *Regs, contig_len: u32) Error!*Class {
        assert(contig_len != 0);
        try regs.classes.ensureUnusedCapacity(regs.allocator, 1);
        const class = try regs.allocator.create(Class);
        errdefer regs.allocator.destroy(class);
        const bits = try regs.allocator.alloc(u32, bitsetWords(regs.count));
        @memset(bits, 0);
        class.* = .{
            .regset = regs,
            .regs = bits,
            .contig_len = contig_len,
            .index = @intCast(regs.classes.items.len),
        };
        regs.classes.appendAssumeCapacity(class);
        return class;
    }

    /// ra_get_class_from_index (register_allocate.c:264).
    pub fn classFromIndex(regs: *const Regs, index: u32) *Class {
        return regs.classes.items[index];
    }

    /// The set made ready to allocate from, once every class has its
    /// registers (ra_set_finalize, register_allocate.c:316, the q values
    /// worked out rather than given): for each two classes B and C, how
    /// many registers of B an allocation in C can conflict with at worst.
    pub fn finalize(regs: *Regs) Error!void {
        const class_count = regs.classes.items.len;
        for (regs.classes.items) |class| {
            regs.allocator.free(class.q);
            class.q = &.{};
            class.q = try regs.allocator.alloc(u32, class_count);
        }
        for (regs.classes.items) |class_b| {
            for (regs.classes.items, 0..) |class_c, c| {
                if (class_b.contig_len == 1 and class_c.contig_len == 1) {
                    // Classes of single registers conflict only through a
                    // register they share, a cheap test of a common case.
                    class_b.q[c] = 0;
                    for (class_b.regs, class_c.regs) |b_word, c_word| {
                        if (b_word & c_word != 0) {
                            class_b.q[c] = 1;
                            break;
                        }
                    }
                } else {
                    const max_possible_conflicts = class_b.contig_len + class_c.contig_len - 1;
                    var max_conflicts: u32 = 0;
                    var rc: u32 = 0;
                    while (rc < regs.count) : (rc += 1) {
                        if (!bitTest(class_c.regs, rc)) continue;
                        const start: u32 = @intCast(@max(0, @as(i64, rc) - class_b.contig_len + 1));
                        const end = @min(regs.count, rc + class_c.contig_len);
                        var conflicts: u32 = 0;
                        var i = start;
                        while (i < end) : (i += 1) {
                            if (bitTest(class_b.regs, i)) conflicts += 1;
                        }
                        max_conflicts = @max(max_conflicts, conflicts);
                        // Unless the class's registers are restricted, as
                        // to aligned ones, this limit is found soon.
                        if (max_conflicts == max_possible_conflicts) break;
                    }
                    class_b.q[c] = max_conflicts;
                }
            }
        }
    }
};

/// struct ra_class (register_allocate_internal.h:63).
pub const Class = struct {
    regset: *const Regs,
    /// The registers an allocation in the class may start at, a bit each.
    regs: []u32,
    /// The registers an allocation takes, from where it starts.
    contig_len: u32,
    /// p(B): how many registers the class has.
    p: u32 = 0,
    /// q(B, C), by C's index: how many registers of this class an
    /// allocation in C can conflict with at worst.
    q: []u32 = &.{},
    index: u32,

    /// ra_class_add_reg (register_allocate.c:276).
    pub fn addReg(class: *Class, r: u32) void {
        assert(r < class.regset.count);
        assert(r + class.contig_len <= class.regset.count);
        bitSet(class.regs, r);
        class.p += 1;
    }
};

/// Whether an allocation at `r1` in `c1` and one at `r2` in `c2` take a
/// register both (ra_class_allocations_conflict, register_allocate.c:860),
/// for classes in a row. The sums wrap as C's unsigned ones do.
pub fn classAllocationsConflict(c1: *const Class, r1: u32, c2: *const Class, r2: u32) bool {
    assert(c1.contig_len != 0 and c2.contig_len != 0);
    const r1_end = r1 +% c1.contig_len;
    const r2_end = r2 +% c2.contig_len;
    return !(r2 >= r1_end or r1 >= r2_end);
}

/// The driver's choice of a register for node `n` among those it may
/// have, a bit each in `regs` (ra_select_reg_callback,
/// register_allocate.h:115); `optimistic` says the node went onto the
/// stack on the chance of a register rather than the certainty of one.
pub const SelectRegCallback = *const fn (n: u32, regs: []u32, data: ?*anyopaque, optimistic: bool) u32;

/// struct ra_node (register_allocate_internal.h:96).
const Node = struct {
    /// The nodes it interferes with, each of which has it in its own.
    adjacency: std.ArrayList(u32) = .empty,
    class: u32 = 0,
    /// Its register, or no_reg.
    reg: u32 = no_reg,
    /// Runeson and Nyström's q total over its neighbours not on the stack.
    q_total: u32 = 0,
    /// q_total as simplify takes the neighbours out (tmp.q_total).
    tmp_q_total: u32 = 0,
};

/// struct ra_node_extra (register_allocate_internal.h:126).
const NodeExtra = struct {
    /// What spilling the node would cost, roughly; 0 is never spilled.
    spill_cost: f32 = 0,
    /// The register the user gave it, or no_reg.
    forced_reg: u32 = no_reg,
};

/// The nodes that want registers, and which of them interfere (struct
/// ra_graph, register_allocate_internal.h:138).
pub const Graph = struct {
    allocator: Allocator,
    regs: *const Regs,
    nodes: []Node = &.{},
    nodes_extra: []NodeExtra = &.{},
    /// A bit for each two nodes, a triangle of them: ra_get_adjacency_bit_index.
    adjacency: []u32 = &.{},
    /// The nodes there are.
    count: u32 = 0,
    /// The nodes there is room for.
    alloc: u32 = 0,
    select_reg_callback: ?SelectRegCallback = null,
    select_reg_callback_data: ?*anyopaque = null,
    tmp: struct {
        stack: []u32 = &.{},
        stack_count: u32 = 0,
        /// For each node, whether it is on the stack.
        in_stack: []u32 = &.{},
        /// For each node, whether it was given its register beforehand.
        reg_assigned: []u32 = &.{},
        /// For each node, the pq test's answer.
        pq_test: []u32 = &.{},
        /// For each word of nodes, the least q total, or the most a u32
        /// holds where it is to be found again.
        min_q_total: []u32 = &.{},
        /// For each word, the node with that q total, where it is known.
        min_q_node: []u32 = &.{},
        /// Where the nodes put on the stack on chance start.
        stack_optimistic_start: u32 = 0,
    } = .{},

    /// ra_alloc_interference_graph (register_allocate.c:621).
    pub fn create(allocator: Allocator, regs: *const Regs, count: u32) Error!*Graph {
        const g = try allocator.create(Graph);
        g.* = .{ .allocator = allocator, .regs = regs, .count = count };
        errdefer g.destroy();
        try g.realloc(count);
        return g;
    }

    pub fn destroy(g: *Graph) void {
        const allocator = g.allocator;
        for (g.nodes) |*node| node.adjacency.deinit(allocator);
        allocator.free(g.nodes);
        allocator.free(g.nodes_extra);
        allocator.free(g.adjacency);
        allocator.free(g.tmp.stack);
        allocator.free(g.tmp.in_stack);
        allocator.free(g.tmp.reg_assigned);
        allocator.free(g.tmp.pq_test);
        allocator.free(g.tmp.min_q_total);
        allocator.free(g.tmp.min_q_node);
        allocator.destroy(g);
    }

    fn class(g: *const Graph, index: u32) *const Class {
        return g.regs.classes.items[index];
    }

    /// Room for `alloc` nodes, a whole number of words of them
    /// (ra_realloc_interference_graph, register_allocate.c:578). Mesa
    /// leaves the scratch values as they come, simplify setting them; they
    /// are zeroed here, so that one read before an allocation reads 0.
    fn realloc(g: *Graph, wanted: u32) Error!void {
        if (wanted <= g.alloc) return;
        assert(g.alloc % word_bits == 0);
        const old = g.alloc;
        const alloc = std.mem.alignForward(u32, wanted, word_bits);

        g.nodes = try g.allocator.realloc(g.nodes, alloc);
        for (g.nodes[old..]) |*node| node.* = .{};
        g.nodes_extra = try g.allocator.realloc(g.nodes_extra, alloc);
        for (g.nodes_extra[old..]) |*extra| extra.* = .{};
        const old_words = g.adjacency.len;
        g.adjacency = try g.allocator.realloc(g.adjacency, bitsetWords(numAdjacencyBits(alloc)));
        @memset(g.adjacency[old_words..], 0);

        const bitset_count = bitsetWords(alloc);
        g.tmp.stack = try reallocZeroed(g.allocator, g.tmp.stack, alloc);
        g.tmp.in_stack = try reallocZeroed(g.allocator, g.tmp.in_stack, bitset_count);
        g.tmp.reg_assigned = try reallocZeroed(g.allocator, g.tmp.reg_assigned, bitset_count);
        g.tmp.pq_test = try reallocZeroed(g.allocator, g.tmp.pq_test, bitset_count);
        g.tmp.min_q_total = try reallocZeroed(g.allocator, g.tmp.min_q_total, bitset_count);
        g.tmp.min_q_node = try reallocZeroed(g.allocator, g.tmp.min_q_node, bitset_count);
        g.alloc = alloc;
    }

    fn reallocZeroed(allocator: Allocator, old: []u32, len: usize) Error![]u32 {
        const grown = try allocator.realloc(old, len);
        @memset(grown[old.len..], 0);
        return grown;
    }

    /// `count` nodes, room made by doubling (ra_resize_interference_graph,
    /// register_allocate.c:634), as ra_add_node grows it by one.
    pub fn resize(g: *Graph, count: u32) Error!void {
        g.count = count;
        if (count > g.alloc) try g.realloc(g.alloc * 2);
    }

    /// ra_set_select_reg_callback (register_allocate.c:641).
    pub fn setSelectRegCallback(g: *Graph, callback: SelectRegCallback, data: ?*anyopaque) void {
        g.select_reg_callback = callback;
        g.select_reg_callback_data = data;
    }

    /// ra_set_node_class (register_allocate.c:650).
    pub fn setNodeClass(g: *Graph, n: u32, c: *const Class) void {
        g.nodes[n].class = c.index;
    }

    /// ra_get_node_class (register_allocate.c:657).
    pub fn getNodeClass(g: *const Graph, n: u32) *Class {
        return g.regs.classes.items[g.nodes[n].class];
    }

    /// A node more, of class `c` (ra_add_node, register_allocate.c:664).
    pub fn addNode(g: *Graph, c: *const Class) Error!u32 {
        const n = g.count;
        try g.resize(g.count + 1);
        g.setNodeClass(n, c);
        return n;
    }

    fn testAdjacencyBit(g: *const Graph, n1: u32, n2: u32) bool {
        return bitTest(g.adjacency, adjacencyBitIndex(n1, n2));
    }

    fn setAdjacencyBit(g: *Graph, n1: u32, n2: u32) void {
        bitSet(g.adjacency, adjacencyBitIndex(n1, n2));
    }

    fn clearAdjacencyBit(g: *Graph, n1: u32, n2: u32) void {
        bitClear(g.adjacency, adjacencyBitIndex(n1, n2));
    }

    /// `n2` among `n1`'s neighbours (ra_add_node_adjacency,
    /// register_allocate.c:541).
    fn addNodeAdjacency(g: *Graph, n1: u32, n2: u32) Error!void {
        assert(n1 != n2);
        try g.nodes[n1].adjacency.ensureUnusedCapacity(g.allocator, 1);
        const n1_class = g.nodes[n1].class;
        const n2_class = g.nodes[n2].class;
        g.nodes[n1].q_total += g.class(n1_class).q[n2_class];
        g.nodes[n1].adjacency.appendAssumeCapacity(n2);
    }

    /// `n2` no longer among `n1`'s neighbours, the last of them put in its
    /// place (ra_node_remove_adjacency, register_allocate.c:558).
    fn removeNodeAdjacency(g: *Graph, n1: u32, n2: u32) void {
        assert(n1 != n2);
        g.clearAdjacencyBit(n1, n2);
        const n1_class = g.nodes[n1].class;
        const n2_class = g.nodes[n2].class;
        g.nodes[n1].q_total -= g.class(n1_class).q[n2_class];
        const adj = &g.nodes[n1].adjacency;
        for (adj.items, 0..) |elem, i| {
            if (elem == n2) {
                _ = adj.swapRemove(i);
                break;
            }
        }
    }

    /// ra_add_node_interference (register_allocate.c:675).
    pub fn addNodeInterference(g: *Graph, n1: u32, n2: u32) Error!void {
        assert(n1 < g.count and n2 < g.count);
        if (n1 != n2 and !g.testAdjacencyBit(n1, n2)) {
            g.setAdjacencyBit(n1, n2);
            try g.addNodeAdjacency(n1, n2);
            try g.addNodeAdjacency(n2, n1);
        }
    }

    /// `n` no longer interfering with any node (ra_reset_node_interference,
    /// register_allocate.c:687). As in Mesa, its neighbours' q totals go
    /// down, and its own stays what it was.
    pub fn resetNodeInterference(g: *Graph, n: u32) void {
        const adj = &g.nodes[n].adjacency;
        for (adj.items) |neighbour| g.removeNodeAdjacency(neighbour, n);
        adj.clearRetainingCapacity();
    }

    /// The pq test of `n` noted, or its word's least q total where `n`
    /// fails it; where q totals are equal the higher node is taken, as
    /// Mesa's first way of doing this did (update_pq_info,
    /// register_allocate.c:698).
    fn updatePqInfo(g: *Graph, n: u32) void {
        const i = n / word_bits;
        const n_class = g.nodes[n].class;
        if (g.nodes[n].tmp_q_total < g.class(n_class).p) {
            bitSet(g.tmp.pq_test, n);
        } else if (g.tmp.min_q_total[i] != std.math.maxInt(u32)) {
            // Only where the word's minimum is known: one being found
            // again is not to be taken for known.
            if (g.nodes[n].tmp_q_total < g.tmp.min_q_total[i] or
                (g.nodes[n].tmp_q_total == g.tmp.min_q_total[i] and n > g.tmp.min_q_node[i]))
            {
                g.tmp.min_q_total[i] = g.nodes[n].tmp_q_total;
                g.tmp.min_q_node[i] = n;
            }
        }
    }

    /// add_node_to_stack (register_allocate.c:721).
    fn addNodeToStack(g: *Graph, n: u32) void {
        const n_class = g.nodes[n].class;
        assert(!bitTest(g.tmp.in_stack, n));

        for (g.nodes[n].adjacency.items) |n2| {
            const n2_class = g.nodes[n2].class;
            if (!bitTest(g.tmp.in_stack, n2) and !bitTest(g.tmp.reg_assigned, n2)) {
                const q = g.class(n2_class).q[n_class];
                assert(g.nodes[n2].tmp_q_total >= q);
                g.nodes[n2].tmp_q_total -= q;
                g.updatePqInfo(n2);
            }
        }

        g.tmp.stack[g.tmp.stack_count] = n;
        g.tmp.stack_count += 1;
        bitSet(g.tmp.in_stack, n);

        // n's word's least q total is to be found again.
        g.tmp.min_q_total[n / word_bits] = std.math.maxInt(u32);
    }

    /// Every node not given a register beforehand onto the stack: those
    /// that pass the pq test as they come, and where none does, the one
    /// with the least q total, as the likeliest to get a register anyway
    /// (ra_simplify, register_allocate.c:759). The words of nodes are
    /// walked from the last, each from its highest bit.
    fn simplify(g: *Graph) void {
        const max = std.math.maxInt(u32);
        var progress = true;
        var stack_optimistic_start: u32 = max;
        const top_word_high_bit: u32 = (g.count -% 1) % word_bits;
        const top_word: isize = @as(isize, @intCast(bitsetWords(g.count))) - 1;

        g.tmp.stack_count = 0;
        {
            var i = top_word;
            var high_bit = top_word_high_bit;
            while (i >= 0) : ({
                i -= 1;
                high_bit = word_bits - 1;
            }) {
                const w: usize = @intCast(i);
                g.tmp.in_stack[w] = 0;
                g.tmp.reg_assigned[w] = 0;
                g.tmp.pq_test[w] = 0;
                g.tmp.min_q_total[w] = max;
                g.tmp.min_q_node[w] = max;
                var j: i32 = @intCast(high_bit);
                while (j >= 0) : (j -= 1) {
                    const n: u32 = @intCast(w * word_bits + @as(usize, @intCast(j)));
                    g.nodes[n].reg = g.nodes_extra[n].forced_reg;
                    g.nodes[n].tmp_q_total = g.nodes[n].q_total;
                    if (g.nodes[n].reg != no_reg) g.tmp.reg_assigned[w] |= bit(@intCast(j));
                    g.updatePqInfo(n);
                }
            }
        }

        while (progress) {
            var min_q_total: u32 = max;
            var min_q_node: u32 = max;
            progress = false;

            var i = top_word;
            var high_bit = top_word_high_bit;
            while (i >= 0) : ({
                i -= 1;
                high_bit = word_bits - 1;
            }) {
                const w: usize = @intCast(i);
                const mask = ~@as(u32, 0) >> @intCast(31 - high_bit);
                const skip = g.tmp.in_stack[w] | g.tmp.reg_assigned[w];
                if (skip == mask) continue;

                var pq = g.tmp.pq_test[w] & ~skip;
                if (pq != 0) {
                    // Nodes to take as they are: progress is certain, and
                    // another round comes before anything on chance, so
                    // the least q total is not looked for.
                    var j: i32 = @intCast(high_bit);
                    while (j >= 0) : (j -= 1) {
                        if (pq & bit(@intCast(j)) != 0) {
                            const n: u32 = @intCast(w * word_bits + @as(usize, @intCast(j)));
                            assert(n < g.count);
                            g.addNodeToStack(n);
                            // Taking n may have passed others of the word.
                            pq = g.tmp.pq_test[w] & ~skip;
                            progress = true;
                        }
                    }
                } else if (!progress) {
                    if (g.tmp.min_q_total[w] == max) {
                        // A node of the word went onto the stack: its
                        // least q total is found again.
                        var j: i32 = @intCast(high_bit);
                        while (j >= 0) : (j -= 1) {
                            if (skip & bit(@intCast(j)) != 0) continue;
                            const n: u32 = @intCast(w * word_bits + @as(usize, @intCast(j)));
                            assert(n < g.count);
                            if (g.nodes[n].tmp_q_total < g.tmp.min_q_total[w]) {
                                g.tmp.min_q_total[w] = g.nodes[n].tmp_q_total;
                                g.tmp.min_q_node[w] = n;
                            }
                        }
                    }
                    if (g.tmp.min_q_total[w] < min_q_total) {
                        min_q_node = g.tmp.min_q_node[w];
                        min_q_total = g.tmp.min_q_total[w];
                    }
                }
            }

            if (!progress and min_q_total != max) {
                if (stack_optimistic_start == max) stack_optimistic_start = g.tmp.stack_count;
                g.addNodeToStack(min_q_node);
                progress = true;
            }
        }

        g.tmp.stack_optimistic_start = stack_optimistic_start;
    }

    /// The first neighbour of `n` with a register an allocation of `n` at
    /// `r` would conflict with (ra_find_conflicting_neighbor,
    /// register_allocate.c:875); one on the stack has none yet.
    fn findConflictingNeighbor(g: *const Graph, n: u32, r: u32) ?*const Node {
        for (g.nodes[n].adjacency.items) |n2| {
            if (!bitTest(g.tmp.in_stack, n2) and
                classAllocationsConflict(g.class(g.nodes[n].class), r, g.class(g.nodes[n2].class), g.nodes[n2].reg))
            {
                return &g.nodes[n2];
            }
        }
        return null;
    }

    /// The registers of `n`'s class none of its coloured neighbours'
    /// allocations take, into `regs`, and whether there is one
    /// (ra_compute_available_regs, register_allocate.c:899). A
    /// neighbour's register is turned to C's int as Mesa turns it.
    fn computeAvailableRegs(g: *const Graph, n: u32, regs: []u32) bool {
        const c = g.class(g.nodes[n].class);
        @memcpy(regs, c.regs);

        for (g.nodes[n].adjacency.items) |m| {
            const n2 = &g.nodes[m];
            const n2c = g.class(n2.class);
            if (!bitTest(g.tmp.in_stack, m)) {
                const reg: i32 = @bitCast(n2.reg);
                const start: u32 = @intCast(@max(0, @as(i64, reg) - c.contig_len + 1));
                const end = @min(g.regs.count, n2.reg +% n2c.contig_len);
                var i = start;
                while (i < end) : (i += 1) bitClear(regs, i);
            }
        }

        for (regs) |word| {
            if (word != 0) return true;
        }
        return false;
    }

    /// The nodes taken off the stack, each given a register its coloured
    /// neighbours do not take: the callback's choice, or else the lowest
    /// (ra_select, register_allocate.c:943). Where the stack holds only
    /// nodes that passed the pq test this cannot fail; nodes put on it on
    /// chance may find none, and then it answers false. A node taken off
    /// is no longer on the stack even then, so that the spill choice
    /// looks at it.
    fn select(g: *Graph) Error!bool {
        var select_regs: []u32 = &.{};
        if (g.select_reg_callback != null) {
            select_regs = try g.allocator.alloc(u32, bitsetWords(g.regs.count));
        }
        defer g.allocator.free(select_regs);

        while (g.tmp.stack_count != 0) {
            var r: u32 = no_reg;
            const n = g.tmp.stack[g.tmp.stack_count - 1];
            const c = g.class(g.nodes[n].class);

            bitClear(g.tmp.in_stack, n);

            if (g.select_reg_callback) |callback| {
                if (!g.computeAvailableRegs(n, select_regs)) return false;
                r = callback(n, select_regs, g.select_reg_callback_data, g.tmp.stack_count - 1 >= g.tmp.stack_optimistic_start);
                assert(r < g.regs.count);
            } else {
                // The lowest register no neighbour's allocation takes.
                var ri: u32 = 0;
                while (ri < g.regs.count) : (ri += 1) {
                    r = ri;
                    if (!bitTest(c.regs, r)) continue;
                    const conflicting = g.findConflictingNeighbor(n, r) orelse break;
                    if (g.class(conflicting.class).contig_len != 0) {
                        // On to the last register the conflicting
                        // allocation takes; the loop goes past it.
                        const conflicting_end = conflicting.reg + g.class(conflicting.class).contig_len - 1;
                        assert(conflicting_end >= r);
                        ri += conflicting_end - r;
                    }
                }
                if (ri >= g.regs.count) return false;
            }

            g.nodes[n].reg = r;
            g.tmp.stack_count -= 1;
        }
        return true;
    }

    /// Every node given a register, or false where one could not be
    /// (ra_allocate, register_allocate.c:1024).
    pub fn allocate(g: *Graph) Error!bool {
        g.simplify();
        return g.select();
    }

    /// ra_get_node_reg (register_allocate.c:1031).
    pub fn getNodeReg(g: *const Graph, n: u32) u32 {
        if (g.nodes_extra[n].forced_reg != no_reg) return g.nodes_extra[n].forced_reg;
        return g.nodes[n].reg;
    }

    /// Node `n` given `reg` beforehand, which is no class's business: it
    /// goes on no stack, and at select is as if taken off first
    /// (ra_set_node_reg, register_allocate.c:1053).
    pub fn setNodeReg(g: *Graph, n: u32, reg: u32) void {
        g.nodes_extra[n].forced_reg = reg;
    }

    /// What spilling `n` would gain: q(C, B) / p(C) for each neighbour of
    /// class B, C being n's (ra_get_spill_benefit, register_allocate.c:1059).
    fn getSpillBenefit(g: *const Graph, n: u32) f32 {
        var benefit: f32 = 0;
        const n_class = g.class(g.nodes[n].class);
        for (g.nodes[n].adjacency.items) |n2| {
            const n2_class = g.nodes[n2].class;
            benefit += @as(f32, @floatFromInt(n_class.q[n2_class])) / @as(f32, @floatFromInt(n_class.p));
        }
        return benefit;
    }

    /// The node whose spilling gains the most for what it costs, of those
    /// with a cost and not still on the stack, or null for none
    /// (ra_get_best_spill_node, register_allocate.c:1091): select, where
    /// it failed, looked only at those.
    pub fn getBestSpillNode(g: *const Graph) ?u32 {
        var best_node: ?u32 = null;
        var best_benefit: f32 = 0.0;
        var n: u32 = 0;
        while (n < g.count) : (n += 1) {
            const cost = g.nodes_extra[n].spill_cost;
            if (cost <= 0.0) continue;
            if (bitTest(g.tmp.in_stack, n)) continue;
            const benefit = g.getSpillBenefit(n);
            if (benefit / cost > best_benefit) {
                best_benefit = benefit / cost;
                best_node = n;
            }
        }
        return best_node;
    }

    /// ra_set_node_spill_cost (register_allocate.c:1128): only a node with
    /// a cost is spilled.
    pub fn setNodeSpillCost(g: *Graph, n: u32, cost: f32) void {
        g.nodes_extra[n].spill_cost = cost;
    }
};

/// The bits of the triangle `n` nodes need (ra_get_num_adjacency_bits,
/// register_allocate.c:505).
fn numAdjacencyBits(n: u64) u64 {
    return n * (n -| 1) / 2;
}

/// ra_get_adjacency_bit_index (register_allocate.c:511).
fn adjacencyBitIndex(n1: u32, n2: u32) u64 {
    assert(n1 != n2);
    const k1 = @max(n1, n2);
    const k2 = @min(n1, n2);
    return numAdjacencyBits(k1) + k2;
}

const testing = std.testing;

/// Mesa's thumb_checks (src/util/tests/register_allocate_test.cpp:51):
/// Table 4.1 of Runeson and Nyström's paper, and which allocations of the
/// thumb's classes conflict.
fn thumbChecks(regs: *const Regs, reg32_base: u32, reg64_base: u32) !void {
    const reg32low = regs.classFromIndex(0);
    const reg64low = regs.classFromIndex(1);
    const reg96 = regs.classFromIndex(2);

    try testing.expectEqual(@as(u32, 8), reg32low.p);
    try testing.expectEqual(@as(u32, 1), reg32low.q[reg32low.index]);
    try testing.expectEqual(@as(u32, 2), reg32low.q[reg64low.index]);
    try testing.expectEqual(@as(u32, 3), reg32low.q[reg96.index]);
    try testing.expectEqual(@as(u32, 8), reg64low.p);
    try testing.expectEqual(@as(u32, 2), reg64low.q[reg32low.index]);
    try testing.expectEqual(@as(u32, 3), reg64low.q[reg64low.index]);
    try testing.expectEqual(@as(u32, 4), reg64low.q[reg96.index]);
    try testing.expectEqual(@as(u32, 2), reg96.p);
    // Mesa's test holds q(reg96, reg96) twice and q(reg96, reg32low) not
    // at all; it is kept so.
    try testing.expectEqual(@as(u32, 2), reg96.q[reg96.index]);
    try testing.expectEqual(@as(u32, 2), reg96.q[reg64low.index]);
    try testing.expectEqual(@as(u32, 2), reg96.q[reg96.index]);

    // A single register conflicts with itself and with nothing else of
    // its class.
    for (0..7) |at| {
        const i: u32 = @intCast(at);
        try testing.expect(!classAllocationsConflict(reg32low, reg32_base + i, reg32low, reg32_base + i + 1));
        try testing.expect(classAllocationsConflict(reg32low, reg32_base + i, reg32low, reg32_base + i));
    }

    // A pair conflicts with the two registers it is, and not with those
    // beside them.
    try testing.expect(classAllocationsConflict(reg64low, reg64_base + 0, reg32low, reg32_base + 0));
    try testing.expect(classAllocationsConflict(reg64low, reg64_base + 0, reg32low, reg32_base + 1));
    try testing.expect(!classAllocationsConflict(reg64low, reg64_base + 0, reg32low, reg32_base + 2));

    try testing.expect(!classAllocationsConflict(reg64low, reg64_base + 1, reg32low, reg32_base + 0));
    try testing.expect(classAllocationsConflict(reg64low, reg64_base + 1, reg32low, reg32_base + 1));
    try testing.expect(classAllocationsConflict(reg64low, reg64_base + 1, reg32low, reg32_base + 2));
    try testing.expect(!classAllocationsConflict(reg64low, reg64_base + 1, reg32low, reg32_base + 3));
}

test "Mesa's thumb_contigregs: the thumb's classes as registers in a row" {
    const regs = try Regs.create(testing.allocator, 16);
    defer regs.destroy();
    // Any of the low 8 registers.
    const reg32low = try regs.allocContigClass(1);
    for (0..8) |i| reg32low.addReg(@intCast(i));
    // Pairs of them, the wraparound of the real thumb left out.
    const reg64low = try regs.allocContigClass(2);
    for (0..8) |i| reg64low.addReg(@intCast(i));
    // r0 to r2, or r1 to r3.
    const reg96 = try regs.allocContigClass(3);
    for (0..2) |i| reg96.addReg(@intCast(i));
    try regs.finalize();
    try thumbChecks(regs, 0, 0);
}

test "Mesa's nonintersect_contigregs: classes with no register in common do not conflict" {
    const regs = try Regs.create(testing.allocator, 16);
    defer regs.destroy();
    const low = try regs.allocContigClass(1);
    for (0..8) |i| low.addReg(@intCast(i));
    const high = try regs.allocContigClass(1);
    for (8..16) |i| high.addReg(@intCast(i));
    try regs.finalize();

    try testing.expectEqual(@as(u32, 1), low.q[low.index]);
    try testing.expectEqual(@as(u32, 0), low.q[high.index]);
    try testing.expectEqual(@as(u32, 0), high.q[low.index]);
    try testing.expectEqual(@as(u32, 1), high.q[high.index]);
}

test "Mesa's aligned_contigregs: aligned pairs and fours" {
    const base_regs = 32;
    const regs = try Regs.create(testing.allocator, base_regs);
    defer regs.destroy();
    const c1 = try regs.allocContigClass(1);
    for (0..base_regs) |i| c1.addReg(@intCast(i));
    const c2 = try regs.allocContigClass(2);
    var i: u32 = 8;
    while (i < base_regs) : (i += 2) c2.addReg(i);
    const c4 = try regs.allocContigClass(4);
    i = 8;
    while (i < base_regs) : (i += 4) c4.addReg(i);
    try regs.finalize();

    try testing.expectEqual(@as(u32, 1), c1.q[c1.index]);
    try testing.expectEqual(@as(u32, 2), c1.q[c2.index]);
    try testing.expectEqual(@as(u32, 4), c1.q[c4.index]);
    try testing.expectEqual(@as(u32, 1), c2.q[c1.index]);
    try testing.expectEqual(@as(u32, 1), c2.q[c2.index]);
    try testing.expectEqual(@as(u32, 2), c2.q[c4.index]);
    try testing.expectEqual(@as(u32, 1), c4.q[c1.index]);
    try testing.expectEqual(@as(u32, 1), c4.q[c2.index]);
    try testing.expectEqual(@as(u32, 1), c4.q[c4.index]);

    // A four at i against the other classes.
    i = 0;
    while (i < base_regs / 4) : (i += 4) {
        var j: u32 = 0;
        while (j < base_regs) : (j += 1) {
            try testing.expectEqual(j >= i and j < i + 4, classAllocationsConflict(c4, i, c1, j));
        }
        j = 0;
        while (j < base_regs) : (j += 2) {
            try testing.expectEqual(j >= i and j < i + 4, classAllocationsConflict(c4, i, c2, j));
        }
    }
}

/// A set of `count` registers, one class of all of them.
fn singleClass(count: u32) !*Regs {
    const regs = try Regs.create(testing.allocator, count);
    errdefer regs.destroy();
    const all = try regs.allocContigClass(1);
    for (0..count) |i| all.addReg(@intCast(i));
    try regs.finalize();
    return regs;
}

/// Three nodes, each interfering with the others.
fn triangle(regs: *const Regs) !*Graph {
    const g = try Graph.create(testing.allocator, regs, 3);
    errdefer g.destroy();
    for (0..3) |n| g.setNodeClass(@intCast(n), regs.classFromIndex(0));
    try g.addNodeInterference(0, 1);
    try g.addNodeInterference(0, 2);
    try g.addNodeInterference(1, 2);
    return g;
}

test "nodes that all interfere take the lowest registers, the first off the stack the lowest" {
    const regs = try singleClass(3);
    defer regs.destroy();
    const g = try triangle(regs);
    defer g.destroy();
    for (0..3) |n| try testing.expectEqual(@as(u32, 2), g.nodes[n].q_total);

    // All three pass the pq test (2 < 3) and go onto the stack from the
    // highest, so node 0 comes off first.
    try testing.expect(try g.allocate());
    try testing.expectEqual(@as(u32, 0), g.getNodeReg(0));
    try testing.expectEqual(@as(u32, 1), g.getNodeReg(1));
    try testing.expectEqual(@as(u32, 2), g.getNodeReg(2));
    try testing.expectEqual(no_reg, g.tmp.stack_optimistic_start);
}

test "where the registers run out, the node gaining most for its cost is the one to spill" {
    const regs = try singleClass(2);
    defer regs.destroy();
    const g = try triangle(regs);
    defer g.destroy();

    // No node passes (2 < 2 fails): node 2, the highest of the least q
    // total, goes on first on chance, the others then pass; coming off,
    // 0 and 1 take both registers and node 2 finds none.
    try testing.expect(!try g.allocate());
    try testing.expectEqual(@as(u32, 0), g.tmp.stack_optimistic_start);
    try testing.expectEqual(@as(?u32, null), g.getBestSpillNode());

    // Each gains 1/2 for each of its two neighbours.
    g.setNodeSpillCost(0, 4);
    g.setNodeSpillCost(1, 2);
    g.setNodeSpillCost(2, 1);
    try testing.expectEqual(@as(f32, 1.0), g.getSpillBenefit(2));
    try testing.expectEqual(@as(?u32, 2), g.getBestSpillNode());
    g.setNodeSpillCost(2, 0);
    try testing.expectEqual(@as(?u32, 1), g.getBestSpillNode());
}

test "a node given its register beforehand keeps it, and its neighbours keep off it" {
    const regs = try singleClass(2);
    defer regs.destroy();
    const g = try Graph.create(testing.allocator, regs, 2);
    defer g.destroy();
    try g.addNodeInterference(0, 1);
    g.setNodeReg(0, 1);
    try testing.expect(try g.allocate());
    try testing.expectEqual(@as(u32, 1), g.getNodeReg(0));
    try testing.expectEqual(@as(u32, 0), g.getNodeReg(1));
}

const Choices = struct {
    optimistic: [3]bool = .{ false, false, false },
    calls: u32 = 0,
};

/// The highest register left, and what the allocator said of the node.
fn highest(n: u32, regs: []u32, data: ?*anyopaque, optimistic: bool) u32 {
    const choices: *Choices = @ptrCast(@alignCast(data.?));
    choices.optimistic[n] = optimistic;
    choices.calls += 1;
    var r: u32 = @intCast(regs.len * word_bits);
    while (r > 0) {
        r -= 1;
        if (bitTest(regs, r)) return r;
    }
    unreachable;
}

test "the callback chooses among the registers the coloured neighbours leave" {
    const regs = try singleClass(3);
    defer regs.destroy();
    const g = try triangle(regs);
    defer g.destroy();
    var choices: Choices = .{};
    g.setSelectRegCallback(highest, &choices);
    try testing.expect(try g.allocate());
    try testing.expectEqual(@as(u32, 2), g.getNodeReg(0));
    try testing.expectEqual(@as(u32, 1), g.getNodeReg(1));
    try testing.expectEqual(@as(u32, 0), g.getNodeReg(2));
    try testing.expectEqual([3]bool{ false, false, false }, choices.optimistic);

    // On two registers every node is above where the optimistic ones
    // start; node 2 finds no register, and the callback is not asked.
    const two = try singleClass(2);
    defer two.destroy();
    const h = try triangle(two);
    defer h.destroy();
    choices = .{};
    h.setSelectRegCallback(highest, &choices);
    try testing.expect(!try h.allocate());
    try testing.expectEqual(@as(u32, 2), choices.calls);
    try testing.expectEqual([3]bool{ true, true, false }, choices.optimistic);
}

test "a node's interference reset leaves its neighbours lighter and its own q total as it was" {
    const regs = try singleClass(3);
    defer regs.destroy();
    const g = try triangle(regs);
    defer g.destroy();
    g.resetNodeInterference(2);
    try testing.expectEqual(@as(u32, 1), g.nodes[0].q_total);
    try testing.expectEqual(@as(u32, 1), g.nodes[1].q_total);
    try testing.expectEqual(@as(u32, 2), g.nodes[2].q_total);
    try testing.expectEqualSlices(u32, &.{1}, g.nodes[0].adjacency.items);
    try testing.expectEqualSlices(u32, &.{0}, g.nodes[1].adjacency.items);
    try testing.expectEqual(@as(usize, 0), g.nodes[2].adjacency.items.len);
    try testing.expect(!g.testAdjacencyBit(0, 2));
    try testing.expect(g.testAdjacencyBit(0, 1));

    try g.addNodeInterference(0, 2);
    try testing.expectEqual(@as(u32, 2), g.nodes[0].q_total);
    try testing.expectEqual(@as(u32, 3), g.nodes[2].q_total);
}

test "a graph grown node by node keeps its edges" {
    const regs = try singleClass(2);
    defer regs.destroy();
    const g = try Graph.create(testing.allocator, regs, 1);
    defer g.destroy();
    try testing.expectEqual(@as(u32, 32), g.alloc);
    for (1..41) |n| try testing.expectEqual(@as(u32, @intCast(n)), try g.addNode(regs.classFromIndex(0)));
    try testing.expectEqual(@as(u32, 41), g.count);
    try testing.expectEqual(@as(u32, 64), g.alloc);
    try g.addNodeInterference(0, 40);
    try g.addNodeInterference(39, 40);
    try testing.expect(g.testAdjacencyBit(40, 0));
    try testing.expect(g.testAdjacencyBit(40, 39));
    try testing.expect(!g.testAdjacencyBit(0, 39));
    try testing.expect(try g.allocate());
    try testing.expect(g.getNodeReg(40) != g.getNodeReg(0));
    try testing.expect(g.getNodeReg(40) != g.getNodeReg(39));
}
