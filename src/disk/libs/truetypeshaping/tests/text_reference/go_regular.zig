// SPDX-License-Identifier: MIT
//! go/Go-Regular.ttf
//! sha256 197d9f3703b4c00af609178876a8d73e396f64fe438b2c871778566632374be3
//! HarfBuzz 15.1.0
//!
//! What HarfBuzz shapes texts to with that font, as
//! `../text_reference.zig` says a font's cases are written: what
//! truetypeshaping.library's host tests compare its shaping of the
//! same texts with. Written by scripts/shape-text-reference.py and
//! never edited; it is written again when the font's pin in
//! scripts/fetch-fonts.sh changes.

const reference = @import("../text_reference.zig");

pub const font: reference.Font = .{
    .file = "go/Go-Regular.ttf",
    .sha256 = "197d9f3703b4c00af609178876a8d73e396f64fe438b2c871778566632374be3",
    .cases = &.{
        .{
            .name = "letters, figures and signs",
            .text = "Hello, World! 0123456789 (a+b)",
            .glyphs = &.{
                .{ 43, 0, 1479, 0, 0 },
                .{ 72, 1, 1139, 0, 0 },
                .{ 79, 2, 548, 0, 0 },
                .{ 79, 3, 548, 0, 0 },
                .{ 82, 4, 1139, 0, 0 },
                .{ 15, 5, 648, 0, 0 },
                .{ 3, 6, 569, 0, 0 },
                .{ 58, 7, 1933, 0, 0 },
                .{ 82, 8, 1139, 0, 0 },
                .{ 85, 9, 682, 0, 0 },
                .{ 79, 10, 548, 0, 0 },
                .{ 71, 11, 1139, 0, 0 },
                .{ 4, 12, 569, 0, 0 },
                .{ 3, 13, 569, 0, 0 },
                .{ 19, 14, 1139, 0, 0 },
                .{ 20, 15, 1139, 0, 0 },
                .{ 21, 16, 1139, 0, 0 },
                .{ 22, 17, 1139, 0, 0 },
                .{ 23, 18, 1139, 0, 0 },
                .{ 24, 19, 1139, 0, 0 },
                .{ 25, 20, 1139, 0, 0 },
                .{ 26, 21, 1139, 0, 0 },
                .{ 27, 22, 1139, 0, 0 },
                .{ 28, 23, 1139, 0, 0 },
                .{ 3, 24, 569, 0, 0 },
                .{ 11, 25, 682, 0, 0 },
                .{ 68, 26, 1139, 0, 0 },
                .{ 14, 27, 1196, 0, 0 },
                .{ 69, 28, 1139, 0, 0 },
                .{ 12, 29, 682, 0, 0 },
            },
        },
        .{
            .name = "a soft hyphen inside and at the end",
            .text = "co\xc2\xadop\xc2\xad",
            .glyphs = &.{
                .{ 70, 0, 1024, 0, 0 },
                .{ 82, 1, 1139, 0, 0 },
                .{ 82, 4, 1139, 0, 0 },
                .{ 83, 5, 1139, 0, 0 },
            },
        },
        .{
            .name = "a soft hyphen at the start",
            .text = "\xc2\xadab",
            .glyphs = &.{
                .{ 68, 0, 1139, 0, 0 },
                .{ 69, 3, 1139, 0, 0 },
            },
        },
        .{
            .name = "joiners and a word joiner",
            .text = "a\xe2\x80\x8db\xe2\x80\x8cc\xe2\x81\xa0d",
            .glyphs = &.{
                .{ 68, 0, 1139, 0, 0 },
                .{ 69, 4, 1139, 0, 0 },
                .{ 70, 8, 1024, 0, 0 },
                .{ 71, 12, 1139, 0, 0 },
            },
        },
        .{
            .name = "selectors the font has nothing for",
            .text = "a\xef\xb8\x8fb\xef\xb8\x8e",
            .glyphs = &.{
                .{ 68, 0, 1139, 0, 0 },
                .{ 69, 4, 1139, 0, 0 },
            },
        },
        .{
            .name = "characters the font lacks",
            .text = "\xe4\xb8\xad\xe6\x96\x87",
            .glyphs = &.{
                .{ 0, 0, 1536, 0, 0 },
                .{ 0, 3, 1536, 0, 0 },
            },
        },
        .{
            .name = "Greek",
            .text = "\xce\x91\xce\xb8\xce\xae\xce\xbd\xce\xb1, \xcf\x89\xce\xbc\xce\xad\xce\xb3\xce\xb1",
            .glyphs = &.{
                .{ 370, 0, 1366, 0, 0 },
                .{ 408, 2, 1139, 0, 0 },
                .{ 398, 4, 1139, 0, 0 },
                .{ 413, 6, 1024, 0, 0 },
                .{ 401, 8, 1184, 0, 0 },
                .{ 15, 10, 648, 0, 0 },
                .{ 3, 11, 569, 0, 0 },
                .{ 425, 12, 1599, 0, 0 },
                .{ 412, 14, 1180, 0, 0 },
                .{ 397, 16, 913, 0, 0 },
                .{ 403, 18, 1024, 0, 0 },
                .{ 401, 20, 1184, 0, 0 },
            },
        },
        .{
            .name = "Cyrillic",
            .text = "\xd0\x9f\xd1\x80\xd0\xb8\xd0\xb2\xd0\xb5\xd1\x82, \xd0\xbc\xd0\xb8\xd1\x80",
            .glyphs = &.{
                .{ 462, 0, 1472, 0, 0 },
                .{ 495, 2, 1139, 0, 0 },
                .{ 487, 4, 1144, 0, 0 },
                .{ 481, 6, 1088, 0, 0 },
                .{ 484, 8, 1139, 0, 0 },
                .{ 497, 10, 938, 0, 0 },
                .{ 15, 12, 648, 0, 0 },
                .{ 3, 13, 569, 0, 0 },
                .{ 491, 14, 1408, 0, 0 },
                .{ 487, 16, 1144, 0, 0 },
                .{ 495, 18, 1139, 0, 0 },
            },
        },
        .{
            .name = "from right to left",
            .text = "abc, def",
            .backward = true,
            .glyphs = &.{
                .{ 73, 7, 569, 0, 0 },
                .{ 72, 6, 1139, 0, 0 },
                .{ 71, 5, 1139, 0, 0 },
                .{ 3, 4, 569, 0, 0 },
                .{ 15, 3, 648, 0, 0 },
                .{ 70, 2, 1024, 0, 0 },
                .{ 69, 1, 1139, 0, 0 },
                .{ 68, 0, 1139, 0, 0 },
            },
        },
        .{
            .name = "bytes that are no UTF-8",
            .text = "a\xc3b\x80c\xffd\xf8 \xbf",
            .glyphs = &.{
                .{ 68, 0, 1139, 0, 0 },
                .{ 709, 1, 2048, 0, 0 },
                .{ 69, 2, 1139, 0, 0 },
                .{ 709, 3, 2048, 0, 0 },
                .{ 70, 4, 1024, 0, 0 },
                .{ 709, 5, 2048, 0, 0 },
                .{ 71, 6, 1139, 0, 0 },
                .{ 709, 7, 2048, 0, 0 },
                .{ 3, 8, 569, 0, 0 },
                .{ 709, 9, 2048, 0, 0 },
            },
        },
    },
};
