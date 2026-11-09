// SPDX-License-Identifier: MIT
//! The `vector` module: shapes with smooth edges drawn onto pens -
//! vector.library's drawing, with no exec or dos call of its own, so the
//! host tests and host tools import it as it is.
//!
//! - `memory.zig` - where its memory comes from: the caller's two
//!   functions, and a list that grows in them.
//! - `path.zig` - a path: contours of lines and curves kept as given.
//! - `flatten.zig` - a path broken into lines when it is drawn, at the
//!   size it is drawn at.
//! - `coverage.zig` - lines summed into how much of each pixel they cover,
//!   a band of rows at a time.
//! - `stroke.zig` - a stroke as pieces, made in the path's own units.
//! - `canvas.zig` - the caller's pens: a fill or a stroke drawn band by
//!   band, and laid down by coverage; the layers pushed on it.
//! - `shapes.zig` - SVG's arc, a rounded rectangle, an ellipse, as curves.
//! - `pathdata.zig` - SVG's path data read onto a path.
//! - `bounds.zig` - a path's bounds, of its curves.
//! - `gradient.zig` - where a pixel is along a gradient, and its colour.
//! - `dash.zig` - a stroke's contours cut into dashes.
//!
//! lottie.datatype drew with the coverage, the flattening and the stroker
//! before vector.library 1.0 (in its raster.zig); they were moved here
//! unchanged, so a frame comes out as it did.

pub const Memory = @import("memory.zig").Memory;
pub const Path = @import("path.zig").Path;
pub const Canvas = @import("canvas.zig").Canvas;
pub const shapes = @import("shapes.zig");
pub const pathdata = @import("pathdata.zig");
pub const bounds = @import("bounds.zig").bounds;

test {
    _ = @import("memory.zig");
    _ = @import("path.zig");
    _ = @import("flatten.zig");
    _ = @import("coverage.zig");
    _ = @import("stroke.zig");
    _ = @import("canvas.zig");
    _ = @import("shapes.zig");
    _ = @import("pathdata.zig");
    _ = @import("bounds.zig");
    _ = @import("gradient.zig");
    _ = @import("dash.zig");
}
