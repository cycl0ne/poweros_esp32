// SPDX-License-Identifier: MPL-2.0
//! posfs's trees: B+trees of one block a node, changed by copying.
//!
//! **A leaf** holds its entries sorted by key from the front of the block
//! and their data from the back, growing towards each other; an entry says
//! where its data is. **An inner node** holds, for each child, the
//! smallest key under it, the child's address and the generation the
//! child was written in. The first entry's key stands for everything
//! below the second's.
//!
//! **A change copies.** Before a node on the way to a change is touched it
//! is copied into a buffer of its own (`volume.newDirty`), the pointer in
//! its parent made to point at the copy, and the block it came from given
//! up (`space.dropNode`) - which keeps it for as long as a checkpoint or a
//! snapshot still holds it. The copies get addresses only when a
//! checkpoint writes them (`flush`), children before parents, so a parent
//! is sealed over its children's final addresses and generations.
//!
//! A node that fills is split in two, with the item that did not fit
//! counted in so both halves have room; a node that falls below a quarter
//! is merged into a neighbour when the two fit in one. A root with one
//! child gives way to the child. Every walk is a loop over a path of fixed
//! depth (`max_height`); nothing recurses.
//!
//! An item's data is the tree's to move: a view of it is good until the
//! next call into the tree.

const sdk = @import("sdk");
const layout = sdk.dos.posfs.layout;
const volume = @import("volume.zig");
const space = @import("space.zig");
const Volume = volume.Volume;
const Error = volume.Error;
const Key = layout.Key;
const LeafEntry = layout.LeafEntry;
const InnerEntry = layout.InnerEntry;
const NodeHeader = layout.NodeHeader;
const dirty_bit = volume.dirty_bit;
const max_height = volume.max_height;
const header_size = layout.node_header_size;

pub const Tree = struct {
    id: u32,
    /// The root: an address, or a dirty node's number with `dirty_bit`.
    root: u64 = 0,
    /// The generation the root was written in (0 while it is dirty).
    root_gen: u64 = 0,
    /// The levels, 1 when the root is a leaf.
    height: u32 = 1,
};

pub const Item = struct {
    key: Key,
    data: []const u8,
};

// --- a node's parts ------------------------------------------------------------

pub fn header(block: []const u8) *const NodeHeader {
    return @ptrCast(@alignCast(block.ptr));
}

fn headerMut(block: []u8) *NodeHeader {
    return @ptrCast(@alignCast(block.ptr));
}

pub fn leafEntries(block: []const u8) []const LeafEntry {
    const entries: [*]const LeafEntry = @ptrCast(@alignCast(block.ptr + header_size));
    return entries[0..header(block).count];
}

fn leafEntriesMut(block: []u8) []LeafEntry {
    const entries: [*]LeafEntry = @ptrCast(@alignCast(block.ptr + header_size));
    return entries[0..header(block).count];
}

pub fn innerEntries(block: []const u8) []const InnerEntry {
    const entries: [*]const InnerEntry = @ptrCast(@alignCast(block.ptr + header_size));
    return entries[0..header(block).count];
}

fn innerEntriesMut(block: []u8) []InnerEntry {
    const entries: [*]InnerEntry = @ptrCast(@alignCast(block.ptr + header_size));
    return entries[0..header(block).count];
}

pub fn itemData(block: []const u8, entry: LeafEntry) []const u8 {
    return block[entry.data_off..][0..entry.data_len];
}

fn pad8(len: u32) u32 {
    return (len + 7) & ~@as(u32, 7);
}

/// The bytes a leaf's entries and live data take.
fn leafUsed(vol: *const Volume, block: []const u8) u32 {
    const h = header(block);
    return h.count * @sizeOf(LeafEntry) + (vol.block_size - h.heap - h.dead);
}

/// The room between a leaf's entries and its data.
fn leafFree(block: []const u8) u32 {
    const h = header(block);
    return h.heap - (header_size + h.count * @sizeOf(LeafEntry));
}

/// The first entry at or after `key` in a leaf, and whether it is `key`.
fn leafSearch(entries: []const LeafEntry, key: Key) struct { pos: u32, found: bool } {
    var low: usize = 0;
    var high: usize = entries.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (entries[middle].key.lessThan(key)) low = middle + 1 else high = middle;
    }
    const found = low < entries.len and entries[low].key.eql(key);
    return .{ .pos = @intCast(low), .found = found };
}

/// The child an inner node sends `key` to: the last whose key is at or
/// below it, the first for anything smaller.
fn childFor(entries: []const InnerEntry, key: Key) u32 {
    var low: usize = 1;
    var high: usize = entries.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (key.lessThan(entries[middle].key)) high = middle else low = middle + 1;
    }
    return @intCast(low - 1);
}

/// A fresh, empty node of `tree` at `level`.
fn newNode(vol: *Volume, tree: *const Tree, level: u32) Error!u32 {
    const slot = try vol.newDirty();
    const block = vol.dirtyBuffer(slot);
    headerMut(block).* = .{
        .gen = vol.gen,
        .tree = tree.id,
        .level = level,
        .heap = vol.block_size,
    };
    return slot;
}

/// A node as the tree points at it: a dirty node's buffer, or the block
/// read and checked.
pub fn nodeAt(vol: *Volume, tree: *const Tree, ref: u64, gen: u64) Error![]const u8 {
    if (ref & dirty_bit != 0) return vol.dirtyBuffer(@intCast(ref & ~dirty_bit));
    return vol.nodeView(ref, gen, tree.id);
}

/// The node `ref` as a dirty node: itself if it is one, else a copy, with
/// the block it came from given up.
fn makeDirty(vol: *Volume, tree: *const Tree, ref: u64, gen: u64) Error!u32 {
    if (ref & dirty_bit != 0) return @intCast(ref & ~dirty_bit);
    const block = try vol.nodeView(ref, gen, tree.id);
    const slot = try vol.newDirty();
    const copy = vol.dirtyBuffer(slot);
    @memcpy(copy, block);
    const h = headerMut(copy);
    h.gen = vol.gen;
    h.self = 0;
    try space.dropNode(vol, tree.id, ref, gen);
    return slot;
}

/// The way from the root to a leaf: each level's dirty node, and the
/// entry taken there.
const Path = struct {
    node: [max_height]u32 = undefined,
    slot: [max_height]u32 = undefined,
    depth: u32 = 0,
};

/// The leaf `key` belongs in, every node on the way made dirty.
fn descendMut(vol: *Volume, tree: *Tree, key: Key, path: *Path) Error!u32 {
    var slot = try makeDirty(vol, tree, tree.root, tree.root_gen);
    tree.root = dirty_bit | slot;
    tree.root_gen = 0;
    path.depth = 0;
    while (true) {
        const block = vol.dirtyBuffer(slot);
        if (header(block).level == 0) {
            path.node[path.depth] = slot;
            return slot;
        }
        if (path.depth + 1 >= max_height) return error.Corrupt;
        const entries = innerEntriesMut(block);
        const at = childFor(entries, key);
        const child = try makeDirty(vol, tree, entries[at].child, entries[at].child_gen);
        // The table may have grown; the buffer has not moved.
        const again = innerEntriesMut(vol.dirtyBuffer(slot));
        again[at].child = dirty_bit | child;
        again[at].child_gen = 0;
        path.node[path.depth] = slot;
        path.slot[path.depth] = at;
        path.depth += 1;
        slot = child;
    }
}

// --- looking up -------------------------------------------------------------------

/// The data of the item with exactly `key`.
pub fn find(vol: *Volume, tree: *const Tree, key: Key) Error!?[]const u8 {
    var ref = tree.root;
    var gen = tree.root_gen;
    var levels: u32 = 0;
    while (true) : (levels += 1) {
        if (levels >= max_height) return error.Corrupt;
        const block = try nodeAt(vol, tree, ref, gen);
        if (header(block).level == 0) {
            const entries = leafEntries(block);
            const where = leafSearch(entries, key);
            if (!where.found) return null;
            return itemData(block, entries[where.pos]);
        }
        const entries = innerEntries(block);
        const at = childFor(entries, key);
        ref = entries[at].child;
        gen = entries[at].child_gen;
    }
}

/// The first item whose key is `key` or after it.
pub fn seek(vol: *Volume, tree: *const Tree, key: Key) Error!?Item {
    var refs: [max_height]u64 = undefined;
    var gens: [max_height]u64 = undefined;
    var slots: [max_height]u32 = undefined;
    var depth: u32 = 0;
    refs[0] = tree.root;
    gens[0] = tree.root_gen;
    const want = key;
    var leftmost = false;
    while (true) {
        const block = try nodeAt(vol, tree, refs[depth], gens[depth]);
        if (header(block).level == 0) {
            const entries = leafEntries(block);
            const pos: u32 = if (leftmost) 0 else leafSearch(entries, want).pos;
            if (pos < entries.len) {
                return .{ .key = entries[pos].key, .data = itemData(block, entries[pos]) };
            }
            // Past this leaf: up to the first level with a next child.
            while (true) {
                if (depth == 0) return null;
                depth -= 1;
                const parent = try nodeAt(vol, tree, refs[depth], gens[depth]);
                const entries_up = innerEntries(parent);
                if (slots[depth] + 1 < entries_up.len) {
                    slots[depth] += 1;
                    refs[depth + 1] = entries_up[slots[depth]].child;
                    gens[depth + 1] = entries_up[slots[depth]].child_gen;
                    depth += 1;
                    leftmost = true;
                    break;
                }
            }
            continue;
        }
        if (depth + 1 >= max_height) return error.Corrupt;
        const entries = innerEntries(block);
        const at: u32 = if (leftmost) 0 else childFor(entries, want);
        slots[depth] = at;
        refs[depth + 1] = entries[at].child;
        gens[depth + 1] = entries[at].child_gen;
        depth += 1;
    }
}

/// The last item whose key is `key` or before it.
pub fn floor(vol: *Volume, tree: *const Tree, key: Key) Error!?Item {
    var refs: [max_height]u64 = undefined;
    var gens: [max_height]u64 = undefined;
    var slots: [max_height]u32 = undefined;
    var depth: u32 = 0;
    refs[0] = tree.root;
    gens[0] = tree.root_gen;
    var rightmost = false;
    while (true) {
        const block = try nodeAt(vol, tree, refs[depth], gens[depth]);
        if (header(block).level == 0) {
            const entries = leafEntries(block);
            // How many of the leaf's items are at or before `key`.
            var count: u32 = @intCast(entries.len);
            if (!rightmost) {
                const where = leafSearch(entries, key);
                count = where.pos + @intFromBool(where.found);
            }
            if (count > 0) {
                const entry = entries[count - 1];
                return .{ .key = entry.key, .data = itemData(block, entry) };
            }
            // Before this leaf: up to the first level with a child before.
            while (true) {
                if (depth == 0) return null;
                depth -= 1;
                if (slots[depth] > 0) {
                    slots[depth] -= 1;
                    const parent = try nodeAt(vol, tree, refs[depth], gens[depth]);
                    const entry = innerEntries(parent)[slots[depth]];
                    refs[depth + 1] = entry.child;
                    gens[depth + 1] = entry.child_gen;
                    depth += 1;
                    rightmost = true;
                    break;
                }
            }
            continue;
        }
        if (depth + 1 >= max_height) return error.Corrupt;
        const entries = innerEntries(block);
        const at: u32 = if (rightmost) @intCast(entries.len - 1) else childFor(entries, key);
        slots[depth] = at;
        refs[depth + 1] = entries[at].child;
        gens[depth + 1] = entries[at].child_gen;
        depth += 1;
    }
}

/// The key just after `key`.
pub fn successor(key: Key) Key {
    var next = key;
    if (next.offset != ~@as(u64, 0)) {
        next.offset += 1;
        return next;
    }
    next.offset = 0;
    if (next.kind != ~@as(u32, 0)) {
        next.kind += 1;
        return next;
    }
    next.kind = 0;
    next.oid +%= 1;
    return next;
}

// --- changing ------------------------------------------------------------------------

/// An item put in. error.Exists when one with its key is there.
pub fn insert(vol: *Volume, tree: *Tree, key: Key, data: []const u8) Error!void {
    if (data.len > layout.itemMax(vol.block_size)) return error.InvalidArgument;
    if (try find(vol, tree, key) != null) return error.Exists;
    var path: Path = .{};
    const leaf = try descendMut(vol, tree, key, &path);
    try insertInLeaf(vol, tree, &path, leaf, key, data);
}

/// An item put in, or the one with its key replaced.
pub fn put(vol: *Volume, tree: *Tree, key: Key, data: []const u8) Error!void {
    if (data.len > layout.itemMax(vol.block_size)) return error.InvalidArgument;
    if (try find(vol, tree, key)) |old| {
        if (old.len == data.len) {
            const target = (try modify(vol, tree, key)).?;
            @memcpy(target, data);
            return;
        }
        _ = try remove(vol, tree, key);
    }
    var path: Path = .{};
    const leaf = try descendMut(vol, tree, key, &path);
    try insertInLeaf(vol, tree, &path, leaf, key, data);
}

/// The data of the item with `key`, to change in place: its size stays.
pub fn modify(vol: *Volume, tree: *Tree, key: Key) Error!?[]u8 {
    if (try find(vol, tree, key) == null) return null;
    var path: Path = .{};
    const leaf = try descendMut(vol, tree, key, &path);
    const block = vol.dirtyBuffer(leaf);
    const entries = leafEntries(block);
    const where = leafSearch(entries, key);
    if (!where.found) return error.Corrupt;
    const entry = entries[where.pos];
    return block[entry.data_off..][0..entry.data_len];
}

/// The item with `key` taken out; false when there is none.
pub fn remove(vol: *Volume, tree: *Tree, key: Key) Error!bool {
    if (try find(vol, tree, key) == null) return false;
    var path: Path = .{};
    const leaf = try descendMut(vol, tree, key, &path);
    const block = vol.dirtyBuffer(leaf);
    const where = leafSearch(leafEntries(block), key);
    if (!where.found) return error.Corrupt;
    const h = headerMut(block);
    const entries = leafEntriesMut(block);
    const gone = entries[where.pos];
    var at = where.pos;
    while (at + 1 < entries.len) : (at += 1) entries[at] = entries[at + 1];
    h.count -= 1;
    if (gone.data_off == h.heap) h.heap += pad8(gone.data_len) else h.dead += pad8(gone.data_len);
    try rebalance(vol, tree, &path);
    return true;
}

/// A leaf's data packed against the block's end again.
fn compact(vol: *Volume, block: []u8) void {
    const h = headerMut(block);
    if (h.dead == 0) return;
    const scratch = vol.scratch;
    @memcpy(scratch, block);
    var heap = vol.block_size;
    for (leafEntriesMut(block)) |*entry| {
        const len = pad8(entry.data_len);
        heap -= len;
        @memcpy(block[heap..][0..entry.data_len], scratch[entry.data_off..][0..entry.data_len]);
        entry.data_off = dataOffset(block, heap, entry.data_len);
    }
    h.heap = heap;
    h.dead = 0;
}

/// Where an item's data starts: at the heap, or - for an empty one - at
/// the block's end, where the heap growing back past it never strands it.
fn dataOffset(block: []const u8, heap: u32, len: u32) u32 {
    return if (len == 0) @intCast(block.len) else heap;
}

/// Appends an item to a leaf with room for it, at the end of its entries.
fn appendItem(block: []u8, key: Key, data: []const u8) void {
    const h = headerMut(block);
    const len: u32 = @intCast(data.len);
    h.heap -= pad8(len);
    @memcpy(block[h.heap..][0..data.len], data);
    h.count += 1;
    const entries = leafEntriesMut(block);
    entries[entries.len - 1] = .{ .key = key, .data_off = dataOffset(block, h.heap, len), .data_len = len };
}

fn insertInLeaf(vol: *Volume, tree: *Tree, path: *Path, leaf: u32, key: Key, data: []const u8) Error!void {
    const block = vol.dirtyBuffer(leaf);
    const len: u32 = @intCast(data.len);
    const need = @sizeOf(LeafEntry) + pad8(len);
    if (leafFree(block) < need) compact(vol, block);
    if (leafFree(block) >= need) {
        const where = leafSearch(leafEntries(block), key);
        const h = headerMut(block);
        h.heap -= pad8(len);
        @memcpy(block[h.heap..][0..data.len], data);
        h.count += 1;
        const entries = leafEntriesMut(block);
        var at: usize = entries.len - 1;
        while (at > where.pos) : (at -= 1) entries[at] = entries[at - 1];
        entries[where.pos] = .{ .key = key, .data_off = dataOffset(block, h.heap, len), .data_len = len };
        return;
    }
    try splitLeaf(vol, tree, path, leaf, key, data);
}

/// A full leaf split in two with the new item counted in: the items, in
/// order with it, cut where half their bytes are behind.
fn splitLeaf(vol: *Volume, tree: *Tree, path: *Path, leaf: u32, key: Key, data: []const u8) Error!void {
    const right = try newNode(vol, tree, 0);
    const block = vol.dirtyBuffer(leaf);
    const scratch = vol.scratch;
    @memcpy(scratch, block);
    const old = leafEntries(scratch);
    const where = leafSearch(old, key);
    const total = leafUsed(vol, scratch) + @sizeOf(LeafEntry) + pad8(@intCast(data.len));

    const h = headerMut(block);
    h.count = 0;
    h.heap = vol.block_size;
    h.dead = 0;
    const right_block = vol.dirtyBuffer(right);
    var into = block;
    var behind: u32 = 0;
    var at: u32 = 0;
    const count: u32 = @intCast(old.len + 1);
    var separator: Key = key;
    while (at < count) : (at += 1) {
        var item_key: Key = undefined;
        var item_data: []const u8 = undefined;
        if (at == where.pos) {
            item_key = key;
            item_data = data;
        } else {
            const from = old[if (at < where.pos) at else at - 1];
            item_key = from.key;
            item_data = itemData(scratch, from);
        }
        const size = @sizeOf(LeafEntry) + pad8(@intCast(item_data.len));
        if (into.ptr == block.ptr and behind >= total / 2 and at > 0) {
            into = right_block;
            separator = item_key;
        }
        appendItem(into, item_key, item_data);
        behind += size;
    }
    if (into.ptr == block.ptr) return error.Corrupt;
    try insertInParent(vol, tree, path, path.depth, separator, right);
}

/// A new child `right` under the parent of the node at `depth`, just after
/// that node, with `separator` as its key.
fn insertInParent(vol: *Volume, tree: *Tree, path: *Path, depth: u32, separator: Key, right: u32) Error!void {
    if (depth == 0) {
        // The root split: a new root over the two halves.
        const left = path.node[0];
        const level = header(vol.dirtyBuffer(left)).level + 1;
        const root = try newNode(vol, tree, level);
        const block = vol.dirtyBuffer(root);
        headerMut(block).count = 2;
        const entries = innerEntriesMut(block);
        entries[0] = .{ .key = layout.key_min, .child = dirty_bit | left, .child_gen = 0 };
        entries[1] = .{ .key = separator, .child = dirty_bit | right, .child_gen = 0 };
        tree.root = dirty_bit | root;
        tree.root_gen = 0;
        tree.height += 1;
        if (tree.height > max_height) return error.Corrupt;
        return;
    }
    const parent = path.node[depth - 1];
    const at = path.slot[depth - 1] + 1;
    const block = vol.dirtyBuffer(parent);
    const capacity = layout.innerCapacity(vol.block_size);
    const new_entry: InnerEntry = .{ .key = separator, .child = dirty_bit | right, .child_gen = 0 };
    if (header(block).count < capacity) {
        headerMut(block).count += 1;
        const entries = innerEntriesMut(block);
        var move: usize = entries.len - 1;
        while (move > at) : (move -= 1) entries[move] = entries[move - 1];
        entries[at] = new_entry;
        return;
    }
    // The parent is full: split it the same way, its new entry counted in.
    const sibling = try newNode(vol, tree, header(block).level);
    const scratch = vol.scratch;
    @memcpy(scratch, block);
    const old = innerEntries(scratch);
    const count: u32 = @intCast(old.len + 1);
    const half = count / 2;
    headerMut(block).count = half;
    const sibling_block = vol.dirtyBuffer(sibling);
    headerMut(sibling_block).count = count - half;
    const left_entries = innerEntriesMut(block);
    const right_entries = innerEntriesMut(sibling_block);
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const entry = if (index == at) new_entry else old[if (index < at) index else index - 1];
        if (index < half) left_entries[index] = entry else right_entries[index - half] = entry;
    }
    try insertInParent(vol, tree, path, depth - 1, right_entries[0].key, sibling);
}

/// After an item went: a leaf below a quarter merged into a neighbour
/// when the two fit in one, and so on up; a root with one child replaced
/// by it.
fn rebalance(vol: *Volume, tree: *Tree, path: *Path) Error!void {
    var depth = path.depth;
    while (depth > 0) : (depth -= 1) {
        const slot = path.node[depth];
        const block = vol.dirtyBuffer(slot);
        const level = header(block).level;
        const room = vol.block_size - header_size;
        const used = if (level == 0) leafUsed(vol, block) else header(block).count * @sizeOf(InnerEntry);
        if (used >= room / 4) return;
        const parent = path.node[depth - 1];
        const parent_block = vol.dirtyBuffer(parent);
        const at = path.slot[depth - 1];
        const siblings = innerEntries(parent_block);
        if (siblings.len < 2) {
            if (used != 0 or level != 0) return;
            continue;
        }
        // Merge the right one of a pair into the left one.
        const left_at: u32 = if (at + 1 < siblings.len) at else at - 1;
        const other_at: u32 = if (left_at == at) at + 1 else left_at;
        const other_entry = siblings[other_at];
        const other_view = try nodeAt(vol, tree, other_entry.child, other_entry.child_gen);
        const other_used = if (level == 0) leafUsed(vol, other_view) else header(other_view).count * @sizeOf(InnerEntry);
        if (used + other_used > room) return;
        const other = try makeDirty(vol, tree, other_entry.child, other_entry.child_gen);
        {
            const entries = innerEntriesMut(vol.dirtyBuffer(parent));
            entries[other_at].child = dirty_bit | other;
            entries[other_at].child_gen = 0;
        }
        const left = if (left_at == at) slot else other;
        const right = if (left_at == at) other else slot;
        const right_key = innerEntries(vol.dirtyBuffer(parent))[left_at + 1].key;
        mergeInto(vol, vol.dirtyBuffer(left), vol.dirtyBuffer(right), right_key);
        vol.freeDirty(right);
        // The right one's entry leaves the parent.
        const parent_header = headerMut(vol.dirtyBuffer(parent));
        const entries = innerEntriesMut(vol.dirtyBuffer(parent));
        var move: usize = left_at + 1;
        while (move + 1 < entries.len) : (move += 1) entries[move] = entries[move + 1];
        parent_header.count -= 1;
        path.slot[depth - 1] = left_at;
    }
    // The root: one child left, and it is an inner node's, so the child
    // becomes the root.
    while (tree.height > 1) {
        const root_slot: u32 = @intCast(tree.root & ~dirty_bit);
        if (tree.root & dirty_bit == 0) return;
        const block = vol.dirtyBuffer(root_slot);
        if (header(block).count != 1) return;
        const only = innerEntries(block)[0];
        tree.root = only.child;
        tree.root_gen = only.child_gen;
        tree.height -= 1;
        vol.freeDirty(root_slot);
    }
}

/// `right`'s entries put after `left`'s, in `left`. `right_key` is what
/// the parent said `right` starts at, which its own first key stands for.
fn mergeInto(vol: *Volume, left: []u8, right: []u8, right_key: Key) void {
    if (header(left).level == 0) {
        compact(vol, left);
        for (leafEntries(right)) |entry| appendItem(left, entry.key, itemData(right, entry));
        return;
    }
    const from = innerEntries(right);
    const base = header(left).count;
    headerMut(left).count += @intCast(from.len);
    const into = innerEntriesMut(left);
    for (from, 0..) |entry, index| {
        into[base + index] = entry;
        if (index == 0) into[base].key = right_key;
    }
}

// --- writing ----------------------------------------------------------------------

/// Every dirty node of the tree written, children first, each to a block
/// `space.nodeHome` gives it; the root's address and generation are the
/// tree's after.
pub fn flush(vol: *Volume, tree: *Tree) Error!void {
    if (tree.root & dirty_bit == 0) return;
    var nodes: [max_height]u32 = undefined;
    var next: [max_height]u32 = undefined;
    var depth: u32 = 0;
    nodes[0] = @intCast(tree.root & ~dirty_bit);
    next[0] = 0;
    while (true) {
        const slot = nodes[depth];
        const block = vol.dirtyBuffer(slot);
        if (header(block).level > 0) {
            const entries = innerEntries(block);
            var at = next[depth];
            while (at < entries.len and entries[at].child & dirty_bit == 0) at += 1;
            next[depth] = at;
            if (at < entries.len) {
                if (depth + 1 >= max_height) return error.Corrupt;
                depth += 1;
                nodes[depth] = @intCast(entries[at].child & ~dirty_bit);
                next[depth] = 0;
                continue;
            }
        }
        const addr = try space.nodeHome(vol, tree.id);
        headerMut(block).gen = vol.gen;
        try vol.writeNode(addr, block);
        vol.freeDirty(slot);
        if (depth == 0) {
            tree.root = addr;
            tree.root_gen = vol.gen;
            return;
        }
        depth -= 1;
        const parent = innerEntriesMut(vol.dirtyBuffer(nodes[depth]));
        parent[next[depth]].child = addr;
        parent[next[depth]].child_gen = vol.gen;
        next[depth] += 1;
    }
}

/// How many of the tree's nodes are dirty.
pub fn dirtyNodes(vol: *Volume, tree: *const Tree) u64 {
    if (tree.root & dirty_bit == 0) return 0;
    var nodes: [max_height]u32 = undefined;
    var next: [max_height]u32 = undefined;
    var depth: u32 = 0;
    var count: u64 = 1;
    nodes[0] = @intCast(tree.root & ~dirty_bit);
    next[0] = 0;
    while (true) {
        const block = vol.dirtyBuffer(nodes[depth]);
        if (header(block).level > 0) {
            const entries = innerEntries(block);
            var at = next[depth];
            while (at < entries.len and entries[at].child & dirty_bit == 0) at += 1;
            if (at < entries.len and depth + 1 < max_height) {
                next[depth] = at + 1;
                depth += 1;
                nodes[depth] = @intCast(entries[at].child & ~dirty_bit);
                next[depth] = 0;
                count += 1;
                continue;
            }
        }
        if (depth == 0) return count;
        depth -= 1;
    }
}

/// A new, empty tree: one dirty leaf.
pub fn create(vol: *Volume, tree: *Tree) Error!void {
    const slot = try newNode(vol, tree, 0);
    tree.root = dirty_bit | slot;
    tree.root_gen = 0;
    tree.height = 1;
}

/// The nodes being changed dropped: the tree back where it was, at
/// `root`. Used when a medium goes away under them.
pub fn reset(tree: *Tree, root: u64, gen: u64, height: u32) void {
    tree.root = root;
    tree.root_gen = gen;
    tree.height = height;
}
