// SPDX-License-Identifier: MIT
//! truetype.library's reading of a font file, for a tool on the host:
//! the tables found (`outline`), a glyph's contours and their segments
//! (`segments`) - the same code the library's calls are made of, without
//! its jump table. tools/svgcompare draws text with it.

pub const outline = @import("outline/_outline.zig");
pub const segments = @import("glyph/_segments.zig");
