// SPDX-License-Identifier: MIT
//! go/Go-Regular.ttf
//! sha256 197d9f3703b4c00af609178876a8d73e396f64fe438b2c871778566632374be3
//!
//! What a second applier of that font's lookups shapes its runs to, as
//! `../reference.zig` says a font's cases are written: what
//! truetypeshaping.library's host tests compare its shaping of the
//! same runs with. Written by scripts/shape-reference.py and never
//! edited; it is written again when the font's pin in
//! scripts/fetch-fonts.sh changes.

const reference = @import("../reference.zig");

pub const font: reference.Font = .{
    .file = "go/Go-Regular.ttf",
    .sha256 = "197d9f3703b4c00af609178876a8d73e396f64fe438b2c871778566632374be3",
    .glyph_count = 712,
    .runs = "",
    .cases = &.{
        .{ .script = "", .language = "", .features = "", .backward = false, .changed = 0, .sha256 = "22e28a916b9e0d8816dd8d91656a825e839306d6dc6f9edf44886ed37de766e1" },
    },
};
