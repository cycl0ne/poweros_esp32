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
/// - `dynamic_offset_count`, `dynamic_offsets` - none: facet.library has no
///   dynamic descriptors.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The draws after it read the sets as `Resources.sets`, as they hold them
/// when the draws run. Sets past the fourth are not bound.
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
/// across pipelines.
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
/// ```
pub fn CmdBindDescriptorSets(base: *FacetBase, buffer: *facet.CommandBuffer, bind_point: facet.PipelineBindPoint, layout: *facet.PipelineLayout, first_set: u32, count: u32, sets: [*]const *facet.DescriptorSet, dynamic_offset_count: u32, dynamic_offsets: ?[*]const u32) void {
    _ = base;
    _ = layout;
    _ = dynamic_offset_count;
    _ = dynamic_offsets;
    const made = _command.recording(buffer) orelse return;
    if (bind_point != .graphics or first_set >= shader.MAX_SETS) return;
    var bound: [shader.MAX_SETS]*Set = undefined;
    const taken = @min(count, shader.MAX_SETS - first_set);
    for (bound[0..taken], sets[0..taken]) |*into, given| into.* = _objects.of(Set, given);
    _command.record(made, _command.BindDescriptorSets{ .first = first_set, .count = taken }, *Set, bound[0..taken]);
}
