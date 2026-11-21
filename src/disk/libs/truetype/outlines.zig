// SPDX-License-Identifier: MIT
//! truetype.library's reading of a font file, for a tool on the host:
//! the tables found (`outline`), a glyph's contours and their segments
//! (`segments`), a variable font's axes and named instances
//! (`variation`), a font's names (`names`), a glyph's measures in a
//! column (`vertical`) and its drawing in colour (`colour`, `picture`,
//! `document`) - the same code the
//! library's calls are made of, without its jump table. tools/svgcompare
//! draws text with it, and tools/fontconv lists a variable font's styles.

pub const outline = @import("outline/_outline.zig");
pub const segments = @import("glyph/_segments.zig");
pub const variation = @import("outline/_variation.zig");
pub const names = @import("outline/fontname.zig");
pub const vertical = @import("glyph/glyphverticalmetrics.zig");
pub const colour = @import("colour/_colr.zig");
pub const picture = @import("colour/glyphpicture.zig");
pub const document = @import("colour/glyphdocument.zig");
