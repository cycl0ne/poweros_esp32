// SPDX-License-Identifier: MIT
//! AddPathData: SVG path data read onto a path.

const sdk = @import("sdk");
const vector = sdk.vector;
const draw = @import("vector");
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// SVG path data onto the path: VECTORERR_SYNTAX at the first error, the path kept up to it.
///
/// SYNOPSIS:
/// ```zig
/// fn AddPathData(vb: *VectorBase, path: *vector.Path, text: [*]const u8, length: u32) i32
/// ```
///
/// SINCE: 1.1. LVO -84.
///
/// INPUTS:
/// - `path` - the path the contours are added to.
/// - `text`, `length` - the data: the `d` of an SVG `path`, such as
///   `M 10 10 h 20 a 5 5 0 0 1 5 5 z`. It need not end in a 0.
///
/// RESULT:
/// `VECTOR_OK`; `VECTORERR_SYNTAX` at the first thing that is not SVG's
/// path data; `VECTORERR_NOMEM` when a segment did not fit.
///
/// BEHAVIOR:
/// Every command of SVG's path data, in both its forms: absolute, and
/// relative to the current point. `M`, `L`, `H`, `V`, `C`, `S`, `Q`,
/// `T`, `A`, `Z`; a command's numbers given again for another of the
/// same - a move's as lines - and `S` and `T` mirroring the last curve's
/// control point when the command before was one of their kind. Numbers
/// may run together where a sign or a second point parts them
/// (`10-5.5.5`), with an exponent, and an arc's two flags may be single
/// digits with nothing between them.
///
/// At an error the commands before it are kept and the one it is in is
/// not, which is how SVG draws data that goes wrong. The data is a path
/// of its own: it must start with a move, and a relative one first is
/// taken from (0, 0).
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The text is the caller's and only read.
///
/// NOTES:
/// A program can keep its pictures as path data and build them with
/// this, as an SVG file does.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ArcTo`, `MoveTo`, `PathBounds`
///
/// EXAMPLES:
/// ```zig
/// const d = "M 4 12 l 6 6 l 10 -12";
/// if (vb.AddPathData(path, d, d.len) != vector.VECTOR_OK) return;
/// ```
pub fn AddPathData(vb: *VectorBase, path: *vector.Path, text: [*]const u8, length: u32) i32 {
    _ = vb;
    return draw.pathdata.add(_base.pathOf(path), text[0..length]);
}
