// SPDX-License-Identifier: MPL-2.0
//! The rasterizer core of facet.library: triangles drawn into a surface a
//! tile at a time, the tiles shared out between the cores.
//!
//! A module, not a library. It is compiled into what uses it - facet.library
//! and the test programs that measure it - and has no jump table, no .fd
//! and no name in LIBS:. Its calls are made per triangle, per tile and per
//! span, and how a triangle is drawn - the blend, the texture's format,
//! the depth test - is settled when a pipeline is made: those are comptime
//! parameters, so the loops run for every pixel are built for that one
//! pipeline and look nothing up while they run.
//!
//! Its edge is drawn as a library's would be, and nothing of the API above
//! it shows through. It has four things:
//! - `Target`: a surface cut into tiles, the depth that goes with them,
//!   and what each frame starts with.
//! - `Pipeline(cfg)`: a way of drawing triangles, made from `cfg`.
//! - `draw(target, pipeline, vertices, indices)`: triangles drawn.
//! - `batched.draw(target, state, vertices, stride, indices)`: triangles
//!   drawn as facet.library's pipelines draw them, their vertices from a
//!   vertex function and their pixels' colours from a fragment function,
//!   both the program's, called with batches.
//!
//! A frame is `target.begin()`, any number of draws, and `target.finish()`.
//! A draw transforms the triangles, clips them and sorts them into the
//! tiles they touch; `finish` draws each tile that has anything to do in a
//! buffer of the core's own, where its depth lives as well, and writes the
//! colour into the surface - the tiles shared out between the cores
//! (`Host.share`), a tile at a time to whichever part is free - and then
//! hands each on. A tile nothing touched is not written.
//!
//! What it needs of the system - the cores, memory, and a way to hand on
//! what it wrote - it is given (`Host`), so the same code runs in the host
//! tests, one part after another.

const target = @import("target.zig");
const pipeline = @import("pipeline.zig");
const texture = @import("sdk").facet.texture;

pub const Target = target.Target;
pub const Attachments = target.Attachments;
pub const Surface = target.Surface;
pub const Format = target.Format;
pub const Packing = target.Packing;
pub const Rect = target.Rect;
pub const Host = target.Host;
pub const Work = target.Work;
pub const Finished = target.Finished;
pub const Stats = target.Stats;
pub const Pipeline = pipeline.Pipeline;
pub const Config = pipeline.Config;
pub const ColorSource = pipeline.ColorSource;
pub const Viewport = pipeline.Viewport;
pub const Winding = pipeline.Winding;
pub const Cull = pipeline.Cull;
pub const DepthTest = pipeline.DepthTest;
pub const Blend = pipeline.Blend;
pub const Texture = texture.Texture;
pub const TextureFormat = texture.Format;
pub const Filter = texture.Filter;
pub const Address = texture.Address;
pub const Sampling = texture.Sampling;
pub const Matrix = pipeline.Matrix;
pub const identity = pipeline.identity;
pub const draw = pipeline.draw;
pub const batched = @import("batched.zig");
pub const tile_size = target.tile_size;
pub const most_parts = target.most_parts;

test {
    _ = @import("tests/raster.zig");
    _ = @import("tests/texture.zig");
    _ = @import("tests/shaded.zig");
}
