// SPDX-License-Identifier: MIT
//! FreeProject: what LoadProject allocated given back.

const sdk = @import("sdk");
const paintio = sdk.paintio;
const PaintIOBase = @import("../paintio_base.zig").PaintIOBase;

/// Gives back what `LoadProject` allocated for a project.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeProject(base: *PaintIOBase, project: *paintio.Project) void
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `project`: one `LoadProject` filled in, or one it left empty.
///
/// RESULT:
/// None. The project is empty afterwards: no layers, no size.
///
/// BEHAVIOR:
/// Every layer's pixels and mask are freed, then the layers, and the project is
/// set back to its defaults. An empty project is left as it is, so the
/// call may be made whatever `LoadProject` answered.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not from an interrupt.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The memory was the caller's from `LoadProject` on; it is gone now. A
/// project the caller made itself, with its own pixels, is not handed
/// in: those pixels are not the library's to free.
///
/// NOTES:
/// A caller that keeps a layer's pixels or its mask sets that layer's
/// `pixels` or `mask` to null first, and frees them itself later with
/// `FreeVec`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LoadProject`
///
/// EXAMPLES:
/// ```zig
/// var project = paintio.Project{};
/// if (pio.LoadProject("Work:sky.paint", &project) == 0) {
///     // ... the layers taken over ...
///     pio.FreeProject(&project);
/// }
/// ```
pub fn FreeProject(base: *PaintIOBase, project: *paintio.Project) void {
    const sys = base.sys_base;
    if (project.layers) |layers| {
        for (layers[0..project.layer_count]) |layer| {
            if (layer.pixels) |pixels| sys.FreeVec(pixels);
            if (layer.mask) |mask| sys.FreeVec(mask);
        }
        sys.FreeVec(layers);
    }
    project.* = .{};
}
