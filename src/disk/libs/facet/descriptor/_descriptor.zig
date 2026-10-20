// SPDX-License-Identifier: MIT
//! Descriptor set layouts, pools and sets.
//!
//! A set is what its shaders read it as (`shader.Set`): a slot for each
//! descriptor, the elements of a binding's array one after the other, and
//! where each binding's first is. A buffer's slot holds the address of
//! its bytes from the offset written and how many there are; a sampled
//! image's the texture of its view. A slot is read as a draw's shaders
//! run, so a set written between recording and submitting is drawn with
//! as written then, as in Vulkan.
//!
//! A pool counts its sets against its most, and keeps them on a list to
//! give back when it is reset or destroyed; each set is a block of its
//! own, its slots after it. A pool's sizes are not counted: a set takes
//! what its layout needs.

const sdk = @import("sdk");
const exec = sdk.exec;
const facet = sdk.facet;
const shader = facet.shader;
const ExecBase = sdk.interface.exec.ExecBase;
const Device = @import("../device/_device.zig").Device;

/// The kinds of descriptor facet.library has.
pub fn known(kind: facet.DescriptorType) bool {
    return switch (kind) {
        .sampled_image, .uniform_buffer, .storage_buffer => true,
        else => false,
    };
}

/// A binding of a layout: its kind, its first slot and its descriptors.
/// A binding not given has none.
pub const Binding = struct {
    kind: facet.DescriptorType,
    first: u16,
    count: u16,
};

pub const SetLayout = struct {
    device: *Device,
    /// The highest binding given, and one; the slots all of them take.
    binding_count: u32,
    slot_count: u32,

    /// Its bindings, which follow it.
    pub fn bindings(layout: *const SetLayout) []const Binding {
        const first: [*]const Binding = @ptrFromInt(@intFromPtr(layout) + @sizeOf(SetLayout));
        return first[0..layout.binding_count];
    }
};

pub const Pool = struct {
    device: *Device,
    flags: u32,
    max_sets: u32,
    /// Its sets, the last allocated first, and how many.
    first: ?*Set = null,
    count: u32 = 0,
};

pub const Set = struct {
    pool: *Pool,
    next: ?*Set = null,
    previous: ?*Set = null,
    /// What its shaders read it as.
    view: shader.Set,
    /// Each binding's kind.
    kinds: [*]facet.DescriptorType,
};

/// A set of `layout`'s from `pool`, its slots empty; null when memory ran
/// out.
pub fn makeSet(sys: *ExecBase, pool: *Pool, layout: *const SetLayout) ?*Set {
    const bindings = layout.bindings();
    // The slots first after the set, aligned for a pointer; the kinds and
    // where each binding starts after them.
    const slots_bytes = layout.slot_count * @sizeOf(shader.Slot);
    const kinds_bytes = layout.binding_count * @sizeOf(facet.DescriptorType);
    const firsts_bytes = (layout.binding_count + 1) * @sizeOf(u16);
    const memory = sys.AllocVec(@sizeOf(Set) + slots_bytes + kinds_bytes + firsts_bytes, exec.MEMF_CLEAR) orelse return null;
    const set: *Set = @ptrCast(@alignCast(memory));
    const slots: [*]shader.Slot = @ptrFromInt(@intFromPtr(memory) + @sizeOf(Set));
    const kinds: [*]facet.DescriptorType = @ptrFromInt(@intFromPtr(slots) + slots_bytes);
    const firsts: [*]u16 = @ptrFromInt(@intFromPtr(kinds) + kinds_bytes);
    for (bindings, 0..) |binding, k| {
        kinds[k] = binding.kind;
        firsts[k] = binding.first;
    }
    firsts[layout.binding_count] = @intCast(layout.slot_count);
    set.* = .{
        .pool = pool,
        .view = .{ .first = firsts, .binding_count = layout.binding_count, .slots = slots },
        .kinds = kinds,
    };
    return set;
}

/// `set` put on its pool's list.
pub fn link(set: *Set) void {
    const pool = set.pool;
    set.next = pool.first;
    if (pool.first) |first| first.previous = set;
    pool.first = set;
    pool.count += 1;
}

/// `set` taken off its pool's list and given back.
pub fn freeSet(sys: *ExecBase, set: *Set) void {
    const pool = set.pool;
    if (set.previous) |previous| previous.next = set.next else pool.first = set.next;
    if (set.next) |next| next.previous = set.previous;
    pool.count -= 1;
    sys.FreeVec(set);
}

/// Every set of the pool given back.
pub fn freeAll(sys: *ExecBase, pool: *Pool) void {
    var each = pool.first;
    while (each) |set| {
        each = set.next;
        sys.FreeVec(set);
    }
    pool.first = null;
    pool.count = 0;
}

/// The slot of element `element` of binding `binding`, running on into
/// the bindings after it as a write or a copy does; null past the last.
pub fn slotAt(set: *Set, binding: u32, element: u32) ?struct { slot: *shader.Slot, kind: facet.DescriptorType } {
    var at_binding = binding;
    var at_element = element;
    while (at_binding < set.view.binding_count) : (at_binding += 1) {
        const count = set.view.first[at_binding + 1] - set.view.first[at_binding];
        if (at_element < count) {
            const slots: [*]shader.Slot = @constCast(set.view.slots);
            return .{ .slot = &slots[set.view.first[at_binding] + at_element], .kind = set.kinds[at_binding] };
        }
        at_element -= count;
    }
    return null;
}
