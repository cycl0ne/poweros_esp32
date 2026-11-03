// SPDX-License-Identifier: MIT
//! CmdBindDescriptorSets: the descriptor sets shaders read.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const shader = facet.shader;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");
const Set = @import("../descriptor/_descriptor.zig").Set;

/// Recorded: descriptor sets bound, from set `first_set` on.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdBindDescriptorSets(base: *FacetBase, buffer: *facet.CommandBuffer, bind_point: facet.PipelineBindPoint, layout: *facet.PipelineLayout, first_set: u32, count: u32, sets: [*]const *facet.DescriptorSet, dynamic_offset_count: u32, dynamic_offsets: ?[*]const u32) void
/// ```
///
/// SINCE: 1.0. LVO -296.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `bind_point` - `graphics`; nothing is recorded for another.
/// - `layout` - the pipeline layout the sets are bound for.
/// - `first_set`, `count`, `sets` - the sets, from set `first_set` on.
/// - `dynamic_offset_count`, `dynamic_offsets` - one offset in bytes for
///   each dynamic buffer descriptor of the sets bound, in the order the
///   sets, their bindings and the elements of each run; null and 0 where
///   there is none. Offsets past what the sets want are left alone, and a
///   descriptor whose offset is missing is read from where it was written
///   (since 1.35, `PhysicalDeviceFeatures.dynamic_descriptors`).
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The draws after it read the sets as `Resources.sets`, as they hold them
/// when the draws run. Sets past the fourth are not bound.
///
/// A `uniform_buffer_dynamic` or a `storage_buffer_dynamic` reads its
/// buffer from the offset given here, past the one its write gave, and
/// what is left of the range from there is what a function may read
/// (`shader.Resources.buffer`, and `bufferAt` for an element past the
/// first). The offsets are the binding's, not the set's: binding the same
/// set again with others is how one set serves draw after draw, each with
/// a range of its own.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The sets have to last until the work is done.
///
/// NOTES:
/// Every pipeline layout reads set `n` the same way, so a set stays bound
/// across pipelines. A set holds at most
/// `PhysicalDeviceLimits.max_descriptor_set_dynamic_buffers` dynamic
/// buffer descriptors, which CreateDescriptorSetLayout holds it to.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocateDescriptorSets`, `UpdateDescriptorSets`, `CmdDraw`
///
/// EXAMPLES:
/// ```zig
/// fb.CmdBindDescriptorSets(commands, .graphics, layout.?, 0, 1, @ptrCast(&set), 0, null);
/// // The same set again, its one dynamic buffer read from 256 bytes in:
/// const offsets = [1]u32{256};
/// fb.CmdBindDescriptorSets(commands, .graphics, layout.?, 0, 1, @ptrCast(&set), 1, &offsets);
/// ```
pub fn CmdBindDescriptorSets(base: *FacetBase, buffer: *facet.CommandBuffer, bind_point: facet.PipelineBindPoint, layout: *facet.PipelineLayout, first_set: u32, count: u32, sets: [*]const *facet.DescriptorSet, dynamic_offset_count: u32, dynamic_offsets: ?[*]const u32) void {
    _ = base;
    _ = layout;
    const made = _command.recording(buffer) orelse return;
    if ((bind_point != .graphics and bind_point != .compute) or first_set >= shader.MAX_SETS) return;
    var bound: [shader.MAX_SETS]?*Set = @splat(null);
    const taken = @min(count, shader.MAX_SETS - first_set);
    for (bound[0..taken], sets[0..taken]) |*into, given| into.* = _objects.of(Set, given);
    // At most what the sets bound could want, each of them holding
    // `shader.MAX_DYNAMIC_OFFSETS` dynamic buffer descriptors at most.
    const most = shader.MAX_SETS * shader.MAX_DYNAMIC_OFFSETS;
    const offsets: []const u32 = if (dynamic_offsets) |given| given[0..@min(dynamic_offset_count, most)] else &.{};
    _command.record(made, _command.BindDescriptorSets{
        .first = first_set,
        .count = taken,
        .compute = @intFromBool(bind_point == .compute),
        .offset_count = @intCast(offsets.len),
        .sets = bound,
    }, u32, offsets);
}
