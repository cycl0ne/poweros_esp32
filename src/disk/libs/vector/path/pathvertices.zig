// SPDX-License-Identifier: MIT
//! PathVertices: a path's vertices and the directions at them.

const sdk = @import("sdk");
const vector = sdk.vector;
const draw = @import("vector");
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// The path's vertices, with the directions into and out of each, as many as there is room for; how many it has.
///
/// SYNOPSIS:
/// ```zig
/// fn PathVertices(vb: *VectorBase, path: *const vector.Path, vertices: ?[*]vector.Vertex, room: u32) u32
/// ```
///
/// SINCE: 1.5. LVO -140.
///
/// INPUTS:
/// - `path` - the path.
/// - `vertices` - where they are put, or null to count them.
/// - `room` - how many it holds.
///
/// RESULT:
/// How many vertices the path has, whatever the room: a call with more
/// room gets the rest.
///
/// BEHAVIOR:
/// A vertex for each segment, in order: a move's point (`VERTEXF_START`),
/// the end of each line and curve, and a close's - where its contour
/// began (`VERTEXF_CLOSED`). The last of each contour is marked
/// `VERTEXF_END`. An arc is the curves it was added as, each a quarter
/// turn or less, and where they meet are vertices too.
///
/// `in_angle` is the way the path comes into the vertex - toward its end
/// from the last control point not on it - and `out_angle` the way it
/// goes out along the next segment, in degrees clockwise from across, 0
/// up to 360. A segment of no length takes the way of the one before it,
/// or the one after. The first and the last vertex of a closed contour
/// are come into by its close and left by its first segment. Where
/// nothing comes in or goes out, the flag says so (`VERTEXF_NO_IN`,
/// `VERTEXF_NO_OUT`) and the angle is the other one; where neither, both
/// are 0.
///
/// This is what SVG's markers need: `marker-start` at the first vertex,
/// `marker-end` at the last, `marker-mid` at those between, and
/// `orient="auto"` the way halfway between in and out.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The path is the caller's and only read; the vertices are written into
/// the caller's room. A table of where each segment's points are is
/// allocated and given back before the call returns.
///
/// NOTES:
/// The points are the path's own units: no matrix is taken, since the
/// angles a marker is turned by are in them too.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `PathLength`, `PathPointAt`, `AddPathData`
///
/// EXAMPLES:
/// ```zig
/// var room: [64]vector.Vertex = undefined;
/// const n = @min(vb.PathVertices(path, &room, room.len), room.len);
/// for (room[0..n]) |vertex| {
///     // A marker drawn at vertex.point.
///     _ = vertex;
/// }
/// ```
pub fn PathVertices(vb: *VectorBase, path: *const vector.Path, vertices: ?[*]vector.Vertex, room: u32) u32 {
    _ = vb;
    const out: []vector.Vertex = if (vertices) |all| all[0..room] else &.{};
    return draw.measure.vertices(_base.pathOf(path), out);
}
