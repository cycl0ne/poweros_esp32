// SPDX-License-Identifier: MIT
//! noto/NotoColorEmoji.ttf
//! sha256 15671215ab769fdc7162a045d56fd7d7e477c51b04e6b3c761d914d8fdd6cc44
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
    .file = "noto/NotoColorEmoji.ttf",
    .sha256 = "15671215ab769fdc7162a045d56fd7d7e477c51b04e6b3c761d914d8fdd6cc44",
    .cases = &.{
        .{
            .name = "a family joined",
            .text = "\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7",
            .glyphs = &.{
                .{ 2031, 0, 2550, 0, 0 },
            },
        },
        .{
            .name = "a family left apart",
            .text = "\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7",
            .features = &.{
                .{ .tag = "ccmp", .value = 0 },
            },
            .glyphs = &.{
                .{ 596, 0, 2550, 0, 0 },
                .{ 597, 7, 2550, 0, 0 },
                .{ 595, 14, 2550, 0, 0 },
            },
        },
        .{
            .name = "two families, the second left apart",
            .text = "\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7",
            .features = &.{
                .{ .tag = "ccmp", .value = 0, .first = 18, .last = 35 },
            },
            .glyphs = &.{
                .{ 2031, 0, 2550, 0, 0 },
                .{ 596, 18, 2550, 0, 0 },
                .{ 597, 25, 2550, 0, 0 },
                .{ 595, 32, 2550, 0, 0 },
            },
        },
        .{
            .name = "a non-joiner in a family",
            .text = "\xf0\x9f\x91\xa8\xe2\x80\x8c\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7",
            .glyphs = &.{
                .{ 596, 0, 2550, 0, 0 },
                .{ 2317, 7, 2550, 0, 0 },
            },
        },
        .{
            .name = "skin tones",
            .text = "\xf0\x9f\x91\x8d\xf0\x9f\x8f\xbd\xf0\x9f\x91\x8d",
            .glyphs = &.{
                .{ 1978, 0, 2550, 0, 0 },
                .{ 569, 8, 2550, 0, 0 },
            },
        },
        .{
            .name = "a skin tone behind a joiner",
            .text = "\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x8f\xbd",
            .glyphs = &.{
                .{ 2150, 0, 2550, 0, 0 },
            },
        },
        .{
            .name = "flags",
            .text = "\xf0\x9f\x87\xa9\xf0\x9f\x87\xaa\xf0\x9f\x87\xab\xf0\x9f\x87\xb7\xf0\x9f\x87\xa9",
            .glyphs = &.{
                .{ 1605, 0, 2550, 0, 0 },
                .{ 1624, 8, 2550, 0, 0 },
                .{ 208, 16, 2550, 0, 0 },
            },
        },
        .{
            .name = "keycaps",
            .text = "1\xef\xb8\x8f\xe2\x83\xa3#\xe2\x83\xa3",
            .glyphs = &.{
                .{ 1494, 0, 2550, 0, 0 },
                .{ 1491, 7, 2550, 0, 0 },
            },
        },
        .{
            .name = "selectors",
            .text = "\xe2\x98\xba\xef\xb8\x8f\xe2\x98\xba\xef\xb8\x8e\xe2\x98\xba",
            .glyphs = &.{
                .{ 79, 0, 2550, 0, 0 },
                .{ 79, 6, 2550, 0, 0 },
                .{ 79, 12, 2550, 0, 0 },
            },
        },
        .{
            .name = "a selector within a joined pair",
            .text = "\xe2\x9d\xa4\xef\xb8\x8f\xe2\x80\x8d\xf0\x9f\x94\xa5",
            .glyphs = &.{
                .{ 1546, 0, 2550, 0, 0 },
            },
        },
        .{
            .name = "a flag of tag characters",
            .text = "\xf0\x9f\x8f\xb4\xf3\xa0\x81\xa7\xf3\xa0\x81\xa2\xf3\xa0\x81\xa5\xf3\xa0\x81\xae\xf3\xa0\x81\xa7\xf3\xa0\x81\xbf\xf0\x9f\x8f\xb4",
            .glyphs = &.{
                .{ 1922, 0, 2550, 0, 0 },
                .{ 481, 28, 2550, 0, 0 },
            },
        },
    },
};
