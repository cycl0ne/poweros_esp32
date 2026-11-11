// SPDX-License-Identifier: MIT
//! noto/NotoSansDevanagari-Regular.ttf
//! sha256 4e3c66638958c3e2ab5d37f47a8deb89fffeb7be9985c665a519bbc7ba762313
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
    .file = "noto/NotoSansDevanagari-Regular.ttf",
    .sha256 = "4e3c66638958c3e2ab5d37f47a8deb89fffeb7be9985c665a519bbc7ba762313",
    .cases = &.{
        .{
            .name = "vowel signs",
            .text = "\xe0\xa4\x95\xe0\xa4\xbe \xe0\xa4\x95\xe0\xa4\xbf \xe0\xa4\x95\xe0\xa5\x81 \xe0\xa4\x95\xe0\xa5\x87 \xe0\xa4\x95\xe0\xa4\x82",
            .glyphs = &.{
                .{ 56, 0, 768, 0, 0 },
                .{ 31, 3, 259, 0, 0 },
                .{ 3, 6, 260, 0, 0 },
                .{ 56, 7, 768, 0, 0 },
                .{ 32, 10, 259, 0, 0 },
                .{ 3, 13, 260, 0, 0 },
                .{ 56, 14, 768, 0, 0 },
                .{ 34, 17, 0, -221, 0 },
                .{ 3, 20, 260, 0, 0 },
                .{ 56, 21, 768, 0, 0 },
                .{ 40, 24, 0, -221, 0 },
                .{ 3, 27, 260, 0, 0 },
                .{ 56, 28, 768, 0, 0 },
                .{ 100, 31, 0, -221, 0 },
            },
        },
        .{
            .name = "a halant between letters",
            .text = "\xe0\xa4\x95\xe0\xa5\x8d\xe0\xa4\xb7 \xe0\xa4\xb0\xe0\xa5\x81 \xe0\xa4\xa6\xe0\xa5\x8d\xe0\xa4\xa7\xe0\xa5\x80\xe0\xa4\x82",
            .glyphs = &.{
                .{ 56, 0, 768, 0, 0 },
                .{ 103, 3, 0, -221, 0 },
                .{ 86, 6, 578, 0, 0 },
                .{ 3, 9, 260, 0, 0 },
                .{ 82, 10, 409, 0, 0 },
                .{ 34, 13, 0, 0, 0 },
                .{ 3, 16, 260, 0, 0 },
                .{ 73, 17, 531, 0, 0 },
                .{ 103, 20, 0, -83, -45 },
                .{ 74, 23, 615, 0, 0 },
                .{ 33, 26, 259, 0, 0 },
                .{ 100, 29, 0, 0, 0 },
            },
        },
        .{
            .name = "the features of the script asked for",
            .text = "\xe0\xa4\x95\xe0\xa5\x8d\xe0\xa4\xb7 \xe0\xa4\xb0\xe0\xa5\x81 \xe0\xa4\xa6\xe0\xa5\x8d\xe0\xa4\xa7\xe0\xa5\x80\xe0\xa4\x82",
            .features = &.{
                .{ .tag = "akhn" },
                .{ .tag = "half" },
                .{ .tag = "blws" },
                .{ .tag = "psts" },
                .{ .tag = "abvs" },
            },
            .glyphs = &.{
                .{ 90, 0, 717, 0, 0 },
                .{ 3, 9, 260, 0, 0 },
                .{ 493, 10, 598, 0, 0 },
                .{ 3, 16, 260, 0, 0 },
                .{ 73, 17, 531, 0, 0 },
                .{ 103, 20, 0, -83, -45 },
                .{ 74, 23, 615, 0, 0 },
                .{ 635, 26, 259, 0, 0 },
            },
        },
        .{
            .name = "a joiner and a non-joiner behind the halant",
            .text = "\xe0\xa4\x95\xe0\xa5\x8d\xe2\x80\x8d\xe0\xa4\xb7 \xe0\xa4\x95\xe0\xa5\x8d\xe2\x80\x8c\xe0\xa4\xb7",
            .features = &.{
                .{ .tag = "akhn" },
            },
            .glyphs = &.{
                .{ 90, 0, 717, 0, 0 },
                .{ 3, 12, 260, 0, 0 },
                .{ 56, 13, 768, 0, 0 },
                .{ 103, 16, 0, -221, 0 },
                .{ 86, 22, 578, 0, 0 },
            },
        },
        .{
            .name = "the forms of Marathi",
            .text = "\xe0\xa4\xb2\xe0\xa4\xb6\xe0\xa4\x9d \xe0\xa4\x95\xe0\xa5\x81",
            .language = "MAR ",
            .glyphs = &.{
                .{ 478, 0, 699, 0, 0 },
                .{ 482, 3, 672, 0, 0 },
                .{ 64, 6, 756, 0, 0 },
                .{ 3, 9, 260, 0, 0 },
                .{ 56, 10, 768, 0, 0 },
                .{ 34, 13, 0, -221, 0 },
            },
        },
        .{
            .name = "distances switched off",
            .text = "\xe0\xa4\x95\xe0\xa5\x8d\xe0\xa4\xb7 \xe0\xa4\xb0\xe0\xa5\x81 \xe0\xa4\xa6\xe0\xa5\x8d\xe0\xa4\xa7\xe0\xa5\x80\xe0\xa4\x82",
            .features = &.{
                .{ .tag = "dist", .value = 0 },
            },
            .glyphs = &.{
                .{ 56, 0, 768, 0, 0 },
                .{ 103, 3, 0, -221, 0 },
                .{ 86, 6, 578, 0, 0 },
                .{ 3, 9, 260, 0, 0 },
                .{ 82, 10, 409, 0, 0 },
                .{ 34, 13, 0, 0, 0 },
                .{ 3, 16, 260, 0, 0 },
                .{ 73, 17, 531, 0, 0 },
                .{ 103, 20, 0, -83, -45 },
                .{ 74, 23, 615, 0, 0 },
                .{ 33, 26, 259, 0, 0 },
                .{ 100, 29, 0, 0, 0 },
            },
        },
    },
};
