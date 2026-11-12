// SPDX-License-Identifier: MIT
//! Host tests that hand the shaping layout tables that are not sound:
//! tables with numbers changed, tables cut short, and whatever a fuzzer
//! makes of them. A font comes from a share, a download or a mail, so
//! every reader of `GDEF`, `GSUB` and `GPOS` is run on such tables here.
//!
//! Whatever the tables say, a run may come out shaped or as it went in,
//! and this holds all the same (`Harness.check`):
//!
//! - No byte past a table's end is read. Each of the three tables is put
//!   where it ends at a page the host has closed to every access (the
//!   `Arena` of truetype.library's tests), so such a read ends the test
//!   run with a segmentation fault, whose trace names the function that
//!   read.
//! - The answer is one the shaping has. A shaped run's glyphs are numbers
//!   of 16 bits, each of a cluster that went in; a run that grew is no
//!   longer than the growth a run is allowed; there is no more memory
//!   only where the test took it away.
//! - It ends, and soon. Lookups that name each other or a rule that
//!   makes a run longer at every glyph would keep the test run from
//!   ending, and a count changed so that a lookup's list reaches over
//!   the whole table would make it one of minutes.
//! - It leaves nothing allocated: every block comes from the tests'
//!   allocator, which fails a test that leaves one behind - also where
//!   the memory runs out in the middle of a call.
//!
//! Two drivers hand over the tables. One changes the tables built here
//! (`Built`: every kind of lookup and every format of them the shaping
//! tells apart) and, when they are fetched, the real fonts' by a fixed
//! sequence of random numbers: a few bytes or 16-bit numbers a round,
//! most of them where a table's lists and its subtables begin, and every
//! so often a table cut short. A test run so covers the same tables every
//! time, and a failure is met again by running it again. The other is
//! `std.testing.fuzz`, which reads tables and a run from a fuzzer when
//! the tests are built for one, and otherwise shapes its corpus, the
//! built tables with each of their runs.
//!
//! ShapeText goes the same way. A round shapes runs as texts too - each
//! glyph's number as a character, so that the tables' lookups find their
//! glyphs - and a text drawn around a run's glyphs from letters of
//! several scripts, marks, the characters a text does not show,
//! selectors, characters the font lacks and has the parts of, and bytes
//! that are no UTF-8. A fuzzer's run is shaped as a text as well, its
//! bytes as they come.
//!
//! The closed page is the Linux kernel's, so the tests are skipped on
//! another host.

const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("sdk");
const tts = sdk.truetypeshaping;
const layout = @import("layout.zig");
const subtables = @import("subtables.zig");
const shaping = @import("harness.zig");
const reference = @import("reference.zig");
const Arena = @import("../../truetype/tests/fuzz.zig").Arena;

const testing = std.testing;
const File = layout.File;

const X_PLACEMENT = subtables.X_PLACEMENT;
const Y_PLACEMENT = subtables.Y_PLACEMENT;
const X_ADVANCE = subtables.X_ADVANCE;
const X_PLACEMENT_DEVICE: u16 = 0x0010;
const X_ADVANCE_DEVICE: u16 = 0x0040;

/// One way of shaping a run: a script, a language, features, a
/// direction, and the font's place on its axes.
const Way = struct {
    script: u32 = tts.TTS_SCRIPT_DEFAULT,
    language: u32 = tts.TTS_LANGUAGE_DEFAULT,
    features: []const tts.Feature,
    backward: bool = false,
    coords: []const i16 = &.{},
};

/// What a font's tables are shaped with.
const Work = struct {
    runs: []const []const u16,
    ways: []const Way,
    /// How many runs a round shapes, each drawn with a way for it; every
    /// run every way when 0.
    drawn: u32 = 0,
};

const test_tag = tts.featureTag("test");
const more_tag = tts.featureTag("more");

/// The ways the built tables are shaped: their feature `test` in both
/// directions, a second feature on a part of the run under a script of
/// its own, a language's required feature alone, and the feature `test`
/// at two places of the font's axis.
const built_ways = [_]Way{
    .{ .features = &.{.{ .tag = test_tag }} },
    .{ .features = &.{.{ .tag = test_tag }}, .backward = true },
    .{ .script = tts.scriptTag("latn"), .features = &.{ .{ .tag = test_tag }, .{ .tag = more_tag, .first = 1, .last = 3 } } },
    .{ .language = tts.languageTag("TST "), .features = &.{}, .backward = true },
    .{ .features = &.{.{ .tag = test_tag }}, .coords = &.{8192} },
    .{ .features = &.{.{ .tag = test_tag }}, .backward = true, .coords = &.{-16384} },
};

/// The runs the built tables are shaped with: between them a sequence
/// for every lookup, marks where a lookup's flags tell them apart, and
/// glyphs no table names.
const built_runs = [_][]const u16{
    &.{ 10, 11, 12, 13, 14, 15, 16 },
    &.{ 17, 18, 19, 17, 18, 32, 35 },
    &.{ 5, 50, 6, 51, 52 },
    &.{ 20, 21, 22, 23, 24, 25 },
    &.{ 9, 26, 27, 8, 9, 28, 29, 8 },
    &.{ 9, 30, 31, 8, 9, 33, 8, 9, 34, 8 },
    &.{ 7, 50, 8, 36, 51, 37, 7, 51, 8 },
    &.{ 60, 61, 62, 63, 64, 66, 65, 66 },
    &.{ 67, 68, 67, 69, 70, 71, 71, 77, 78 },
    &.{ 5, 50, 51, 6, 50, 52, 40, 50 },
    &.{ 72, 73, 9, 74, 75, 8, 76 },
    &.{ 18, 50, 19, 51, 18, 0, 65535 },
    &.{ 79, 80, 81, 82, 83, 5, 50, 70, 71 },
};

const built_work: Work = .{ .runs = &built_runs, .ways = &built_ways };

/// The lookups of the built `GSUB` that only a context names.
const nested_substitution = 13;
const calling_itself = 10;

/// The lookup of the built `GPOS` that only a context names.
const nested_position = 14;

/// How many subtables are built at a time.
const most_parts = 20;

const mark_anchors = [_]subtables.Mark{
    .{ .class = 0, .anchor = .{ .x = 100, .y = 0, .vary_x = 2 } },
    .{ .class = 1, .anchor = .{ .x = 200, .y = -50 } },
};

/// The tables the tests build. Glyphs 5 to 9, 17 to 19, 36 and 37 are
/// base glyphs, 40 and 41 ligatures, 50 to 52 marks of two attachment
/// classes and three mark sets; the substitutions work on the glyphs
/// below 40, the positionings on the marks and on the glyphs from 60.
/// The font has one axis, and a store of deltas of four items for it:
/// halfway up the axis they add 50, 4, -1 and 25, at its lower end the
/// first one takes 40 off.
const Built = struct {
    store: File = .{},
    gdef: File = .{},
    gsub: File = .{},
    gpos: File = .{},

    fn make(built: *Built) !void {
        const parts = try testing.allocator.alloc(File, most_parts);
        defer testing.allocator.free(parts);
        layout.store(&built.store, 1, &.{ &.{.{ 0, 16384, 16384 }}, &.{.{ -16384, -16384, 0 }} }, &.{
            .{ .regions = &.{ 0, 1 }, .wide = 2, .rows = &.{ &.{ 100, -40 }, &.{ 7, 0 }, &.{ -3, 0 }, &.{ 50, 0 } } },
        });
        layout.gdef(&built.gdef, .{
            .kinds = &.{
                .{ .glyph = 5, .class = 1 },  .{ .glyph = 6, .class = 1 },  .{ .glyph = 7, .class = 1 },
                .{ .glyph = 8, .class = 1 },  .{ .glyph = 9, .class = 1 },  .{ .glyph = 17, .class = 1 },
                .{ .glyph = 18, .class = 1 }, .{ .glyph = 19, .class = 1 }, .{ .glyph = 36, .class = 1 },
                .{ .glyph = 37, .class = 1 }, .{ .glyph = 40, .class = 2 }, .{ .glyph = 41, .class = 2 },
                .{ .glyph = 50, .class = 3 }, .{ .glyph = 51, .class = 3 }, .{ .glyph = 52, .class = 3 },
            },
            .mark_classes = &.{ .{ .glyph = 50, .class = 1 }, .{ .glyph = 51, .class = 2 }, .{ .glyph = 52, .class = 2 } },
            .mark_sets = &.{ &.{50}, &.{ 51, 52 }, &.{ 50, 51, 52 } },
            .store = built.store.written(),
        });
        substitutions(&built.gsub, parts);
        positions(&built.gpos, parts);
    }

    fn tables(built: *const Built) shaping.Tables {
        return .{ .gdef = built.gdef.written(), .gsub = built.gsub.written(), .gpos = built.gpos.written() };
    }

    /// The scripts of both tables: a default with a language that
    /// requires the second feature, and a script with both features.
    const scripts = [_]layout.Script{
        .{ .tag = "DFLT", .languages = &.{ .{ .features = &.{0} }, .{ .tag = "TST ", .required = 1, .features = &.{0} } } },
        .{ .tag = "latn", .languages = &.{.{ .features = &.{ 0, 1 } }} },
    };

    /// The second feature's lookups are replaced where the font is not
    /// varied.
    const variations = [_]layout.Variation{
        .{ .conditions = &.{.{ .low = -16384, .high = 16384 }}, .replaced = &.{.{ .feature = 1, .lookups = &.{1} }} },
    };

    fn substitutions(file: *File, parts: []File) void {
        for (parts) |*part| part.* = .{};
        const into = [_]subtables.Record{.{ .at = 0, .lookup = nested_substitution }};
        const second = [_]subtables.Record{.{ .at = 1, .lookup = nested_substitution }};
        subtables.singleDelta(&parts[0], &.{ 10, 11 }, 100);
        subtables.singleList(&parts[1], &.{ 12, 13 }, &.{ 112, 113 });
        subtables.multiple(&parts[2], &.{ 14, 15 }, &.{ &.{ 114, 115 }, &.{} });
        subtables.multiple(&parts[3], &.{16}, &.{&.{ 116, 117 }});
        subtables.ligature(&parts[4], &.{17}, &.{&.{ .{ .glyph = 41, .rest = &.{ 18, 19 } }, .{ .glyph = 40, .rest = &.{18} } }});
        subtables.ligature(&parts[5], &.{5}, &.{&.{.{ .glyph = 40, .rest = &.{6} }}});
        subtables.context1(&parts[6], &.{20}, &.{&.{.{ .rest = &.{21}, .records = &second }}});
        subtables.context2(&parts[7], &.{ 22, 23 }, &.{ .{ .glyph = 22, .class = 1 }, .{ .glyph = 23, .class = 2 } }, &.{
            &.{},
            &.{.{ .rest = &.{2}, .records = &into }},
        });
        subtables.context3(&parts[8], &.{ &.{24}, &.{25} }, &second);
        subtables.chain1(&parts[9], &.{26}, &.{&.{.{ .before = &.{9}, .rest = &.{27}, .after = &.{8}, .records = &second }}});
        subtables.chain2(
            &parts[10],
            &.{ 28, 29 },
            &.{.{ .glyph = 9, .class = 1 }},
            &.{ .{ .glyph = 28, .class = 1 }, .{ .glyph = 29, .class = 2 } },
            &.{.{ .glyph = 8, .class = 3 }},
            &.{
                &.{},
                &.{.{ .before = &.{1}, .rest = &.{2}, .after = &.{3}, .records = &into }},
            },
        );
        subtables.chain3(&parts[11], &.{&.{9}}, &.{ &.{30}, &.{31} }, &.{&.{8}}, &.{
            .{ .at = 0, .lookup = nested_substitution },
            .{ .at = 1, .lookup = nested_substitution },
        });
        subtables.singleList(&parts[12], &.{32}, &.{132});
        subtables.extension(&parts[13], 1, parts[12].written());
        subtables.reverse(&parts[14], &.{ 33, 34 }, &.{&.{9}}, &.{&.{8}}, &.{ 133, 134 });
        subtables.context3(&parts[15], &.{&.{35}}, &.{
            .{ .at = 0, .lookup = calling_itself },
            .{ .at = 0, .lookup = nested_substitution },
        });
        subtables.ligature(&parts[16], &.{7}, &.{&.{.{ .glyph = 41, .rest = &.{8} }}});
        subtables.ligature(&parts[17], &.{36}, &.{&.{.{ .glyph = 40, .rest = &.{37} }}});
        subtables.singleDelta(&parts[18], &.{ 21, 22, 23, 25, 27, 28, 29, 30, 31, 35 }, 100);
        layout.tableVaried(file, &scripts, &.{
            .{ .tag = "test", .lookups = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 } },
            .{ .tag = "more", .lookups = &.{0} },
        }, &.{
            .{ .kind = 1, .subtables = &.{parts[0].written()} },
            .{ .kind = 1, .subtables = &.{parts[1].written()} },
            .{ .kind = 2, .subtables = &.{parts[2].written()} },
            .{ .kind = 3, .subtables = &.{parts[3].written()} },
            .{ .kind = 4, .subtables = &.{parts[4].written()} },
            // Past the marks.
            .{ .kind = 4, .flags = 0x0008, .subtables = &.{parts[5].written()} },
            .{ .kind = 5, .subtables = &.{ parts[6].written(), parts[7].written(), parts[8].written() } },
            .{ .kind = 6, .subtables = &.{ parts[9].written(), parts[10].written(), parts[11].written() } },
            .{ .kind = 7, .subtables = &.{parts[13].written()} },
            .{ .kind = 8, .subtables = &.{parts[14].written()} },
            .{ .kind = 5, .subtables = &.{parts[15].written()} },
            // Past the marks that are not of the second set, and past
            // those that are not of the first attachment class.
            .{ .kind = 4, .flags = 0x0010, .mark_set = 1, .subtables = &.{parts[16].written()} },
            .{ .kind = 4, .flags = 0x0100, .subtables = &.{parts[17].written()} },
            .{ .kind = 1, .subtables = &.{parts[18].written()} },
        }, &variations);
    }

    fn positions(file: *File, parts: []File) void {
        for (parts) |*part| part.* = .{};
        const moving = [_]subtables.Record{.{ .at = 0, .lookup = nested_position }};
        subtables.positionAll(&parts[0], &.{ 60, 61 }, X_PLACEMENT | Y_PLACEMENT | X_ADVANCE, &.{ 10, 20, -30 });
        subtables.positionEach(&parts[1], &.{ 62, 63 }, Y_PLACEMENT | X_ADVANCE, &.{ &.{ 20, -30 }, &.{ -5, 40 } });
        subtables.pairs(&parts[2], &.{ 64, 65 }, X_ADVANCE, X_PLACEMENT, &.{
            &.{.{ .second = 66, .values = &.{ -50, 5 } }},
            &.{.{ .second = 66, .values = &.{ -20, 3 } }},
        });
        subtables.pairClasses(
            &parts[3],
            &.{67},
            X_ADVANCE,
            0,
            &.{.{ .glyph = 67, .class = 1 }},
            &.{ .{ .glyph = 68, .class = 1 }, .{ .glyph = 69, .class = 2 } },
            3,
            &.{ &.{ 0, 0, 0 }, &.{ 0, -40, -60 } },
        );
        subtables.cursive(&parts[4], &.{ 70, 71 }, &.{
            .{ .exit = .{ .x = 600, .y = 200, .vary_x = 0 } },
            .{ .entry = .{ .x = 50, .y = 0, .vary_y = 1 }, .exit = .{ .x = 500, .y = 100 } },
        });
        subtables.markToBase(&parts[5], &.{ 50, 51 }, &mark_anchors, &.{ 5, 6 }, 2, &.{
            &.{ .{ .x = 300, .y = 700, .vary_x = 0, .vary_y = 1 }, .{ .x = 250, .y = -100 } },
            &.{ .{ .x = 310, .y = 710 }, null },
        });
        subtables.markToLigature(&parts[6], &.{50}, mark_anchors[0..1], &.{40}, 1, &.{&.{
            &.{.{ .x = 200, .y = 500 }},
            &.{.{ .x = 700, .y = 500 }},
        }});
        subtables.markToBase(&parts[7], &.{ 51, 52 }, &.{
            .{ .class = 0, .anchor = .{ .x = 0, .y = 0 } },
            .{ .class = 0, .anchor = .{ .x = 10, .y = 0 } },
        }, &.{50}, 1, &.{&.{.{ .x = 0, .y = 300 }}});
        subtables.context1(&parts[8], &.{72}, &.{&.{.{ .rest = &.{73}, .records = &.{.{ .at = 1, .lookup = nested_position }} }}});
        subtables.chain3(&parts[9], &.{&.{9}}, &.{ &.{74}, &.{75} }, &.{&.{8}}, &moving);
        subtables.positionAll(&parts[10], &.{76}, X_ADVANCE, &.{-70});
        subtables.extension(&parts[11], 1, parts[10].written());
        subtables.pairs(&parts[12], &.{18}, X_ADVANCE, 0, &.{&.{.{ .second = 19, .values = &.{-50} }}});
        subtables.cursive(&parts[13], &.{ 77, 78 }, &.{
            .{ .exit = .{ .x = 400, .y = 150 } },
            .{ .entry = .{ .x = 20, .y = -30 } },
        });
        subtables.pairs(&parts[14], &.{19}, X_ADVANCE, 0, &.{&.{.{ .second = 18, .values = &.{-10} }}});
        subtables.positionAll(&parts[15], &.{ 73, 74, 75 }, X_PLACEMENT, &.{33});
        // Numbers with a device each, which names an item of the store:
        // a single record's, a pair's by glyphs and one's by classes.
        subtables.positionAll(&parts[16], &.{79}, X_PLACEMENT | X_ADVANCE | X_PLACEMENT_DEVICE | X_ADVANCE_DEVICE, &.{ 10, -30, 0, 0 });
        subtables.deviceAt(&parts[16], 10, 0, 0);
        subtables.deviceAt(&parts[16], 12, 0, 2);
        subtables.pairs(&parts[17], &.{80}, X_ADVANCE | X_ADVANCE_DEVICE, 0, &.{&.{.{ .second = 81, .values = &.{ -50, 0 } }}});
        const set: u32 = @intCast(wordAt(parts[17].written(), 10));
        subtables.deviceAt(&parts[17], set + 6, set, 3);
        subtables.pairClasses(
            &parts[18],
            &.{82},
            X_ADVANCE | X_ADVANCE_DEVICE,
            0,
            &.{.{ .glyph = 82, .class = 1 }},
            &.{.{ .glyph = 83, .class = 1 }},
            2,
            &.{ &.{ 0, 0, 0, 0 }, &.{ 0, 0, -50, 0 } },
        );
        subtables.deviceAt(&parts[18], 16 + 3 * 4 + 2, 0, 3);
        layout.tableVaried(file, &scripts, &.{
            .{ .tag = "test", .lookups = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 15, 16, 17 } },
            .{ .tag = "more", .lookups = &.{0} },
        }, &.{
            .{ .kind = 1, .subtables = &.{parts[0].written()} },
            .{ .kind = 1, .subtables = &.{parts[1].written()} },
            .{ .kind = 2, .subtables = &.{parts[2].written()} },
            .{ .kind = 2, .subtables = &.{parts[3].written()} },
            .{ .kind = 3, .subtables = &.{parts[4].written()} },
            .{ .kind = 4, .subtables = &.{parts[5].written()} },
            .{ .kind = 5, .subtables = &.{parts[6].written()} },
            // Only the marks of the third set, which is all of them.
            .{ .kind = 6, .flags = 0x0010, .mark_set = 2, .subtables = &.{parts[7].written()} },
            .{ .kind = 7, .subtables = &.{parts[8].written()} },
            .{ .kind = 8, .subtables = &.{parts[9].written()} },
            .{ .kind = 9, .subtables = &.{parts[11].written()} },
            // Past the marks; from right to left; past the marks that
            // are not of the first attachment class.
            .{ .kind = 2, .flags = 0x0008, .subtables = &.{parts[12].written()} },
            .{ .kind = 3, .flags = 0x0001, .subtables = &.{parts[13].written()} },
            .{ .kind = 2, .flags = 0x0100, .subtables = &.{parts[14].written()} },
            .{ .kind = 1, .subtables = &.{parts[15].written()} },
            .{ .kind = 1, .subtables = &.{parts[16].written()} },
            .{ .kind = 2, .subtables = &.{parts[17].written()} },
            .{ .kind = 2, .subtables = &.{parts[18].written()} },
        }, &variations);
    }
};

/// Whether a positioning moved any glyph of `run`, each of which went in
/// with the tests' advance.
fn moved(run: *const shaping.Run) bool {
    for (run.glyphs[0..run.count]) |glyph| {
        if (glyph.advance != 1000 or glyph.x_offset != 0 or glyph.y_offset != 0) return true;
    }
    return false;
}

test "truetypeshaping: every lookup of the tables built for changing applies" {
    var built: Built = .{};
    try built.make();
    const tables = built.tables();

    // The substitutions, in the order of their lookups.
    try shaping.shape(tables, &.{ 10, 11 }, .{}).expectGlyphs(&.{ 110, 111 });
    try shaping.shape(tables, &.{ 12, 13 }, .{}).expectGlyphs(&.{ 112, 113 });
    try shaping.shape(tables, &.{ 14, 15 }, .{}).expectGlyphs(&.{ 114, 115 });
    try shaping.shape(tables, &.{16}, .{}).expectGlyphs(&.{116});
    try shaping.shape(tables, &.{ 17, 18, 19 }, .{}).expectGlyphs(&.{41});
    try shaping.shape(tables, &.{ 17, 18 }, .{}).expectGlyphs(&.{40});
    try shaping.shape(tables, &.{ 5, 50, 6 }, .{}).expectGlyphs(&.{ 40, 50 });
    try shaping.shape(tables, &.{ 20, 21 }, .{}).expectGlyphs(&.{ 20, 121 });
    try shaping.shape(tables, &.{ 22, 23 }, .{}).expectGlyphs(&.{ 122, 23 });
    try shaping.shape(tables, &.{ 24, 25 }, .{}).expectGlyphs(&.{ 24, 125 });
    try shaping.shape(tables, &.{ 9, 26, 27, 8 }, .{}).expectGlyphs(&.{ 9, 26, 127, 8 });
    try shaping.shape(tables, &.{ 9, 28, 29, 8 }, .{}).expectGlyphs(&.{ 9, 128, 29, 8 });
    try shaping.shape(tables, &.{ 9, 30, 31, 8 }, .{}).expectGlyphs(&.{ 9, 130, 131, 8 });
    try shaping.shape(tables, &.{32}, .{}).expectGlyphs(&.{132});
    try shaping.shape(tables, &.{ 9, 33, 8 }, .{}).expectGlyphs(&.{ 9, 133, 8 });
    try shaping.shape(tables, &.{35}, .{}).expectGlyphs(&.{135});
    try shaping.shape(tables, &.{ 7, 50, 8 }, .{}).expectGlyphs(&.{ 41, 50 });
    try shaping.shape(tables, &.{ 7, 51, 8 }, .{}).expectGlyphs(&.{ 7, 51, 8 });
    try shaping.shape(tables, &.{ 36, 51, 37 }, .{}).expectGlyphs(&.{ 40, 51 });
    try shaping.shape(tables, &.{ 36, 50, 37 }, .{}).expectGlyphs(&.{ 36, 50, 37 });

    // The positionings.
    const single = shaping.shape(tables, &.{ 60, 62, 63 }, .{});
    try single.expectAdvances(&.{ 970, 970, 1040 });
    try single.expectOffsets(&.{ .{ 10, 20 }, .{ 0, 20 }, .{ 0, -5 } });
    const pair = shaping.shape(tables, &.{ 64, 66, 67, 69 }, .{});
    try pair.expectAdvances(&.{ 950, 1000, 940, 1000 });
    try pair.expectOffsets(&.{ .{ 0, 0 }, .{ 5, 0 }, .{ 0, 0 }, .{ 0, 0 } });
    try testing.expect(moved(&shaping.shape(tables, &.{ 70, 71 }, .{})));
    try shaping.shape(tables, &.{ 5, 50 }, .{}).expectOffsets(&.{ .{ 0, 0 }, .{ -800, 700 } });
    const on_ligature = shaping.shape(tables, &.{ 5, 50, 6, 50 }, .{});
    try on_ligature.expectGlyphs(&.{ 40, 50, 50 });
    try testing.expectEqual(@as(i32, 500), on_ligature.glyphs[1].y_offset);
    try testing.expectEqual(@as(i32, 500), on_ligature.glyphs[2].y_offset);
    try testing.expect(on_ligature.glyphs[1].x_offset != on_ligature.glyphs[2].x_offset - 1000);
    const on_mark = shaping.shape(tables, &.{ 5, 50, 52 }, .{});
    try testing.expectEqual(@as(i32, 1000), on_mark.glyphs[2].y_offset);
    try shaping.shape(tables, &.{ 72, 73 }, .{}).expectOffsets(&.{ .{ 0, 0 }, .{ 33, 0 } });
    try shaping.shape(tables, &.{ 9, 74, 75, 8 }, .{}).expectOffsets(&.{ .{ 0, 0 }, .{ 33, 0 }, .{ 0, 0 }, .{ 0, 0 } });
    try shaping.shape(tables, &.{76}, .{}).expectAdvances(&.{930});
    try shaping.shape(tables, &.{ 18, 50, 19 }, .{}).expectAdvances(&.{ 950, 1000, 1000 });
    try testing.expect(moved(&shaping.shape(tables, &.{ 77, 78 }, .{})));
    try shaping.shape(tables, &.{ 19, 51, 18 }, .{}).expectAdvances(&.{ 990, 1000, 1000 });
    try shaping.shape(tables, &.{ 19, 50, 18 }, .{}).expectAdvances(&.{ 1000, 1000, 1000 });

    // The numbers a device varies: at the default, and where the font
    // is on its axis.
    try shaping.shape(tables, &.{79}, .{}).expectAdvances(&.{970});
    try shaping.shape(tables, &.{79}, .{}).expectOffsets(&.{.{ 10, 0 }});
    try shaping.shape(tables, &.{79}, .{ .coords = built_ways[4].coords }).expectAdvances(&.{969});
    try shaping.shape(tables, &.{79}, .{ .coords = built_ways[4].coords }).expectOffsets(&.{.{ 60, 0 }});
    try shaping.shape(tables, &.{79}, .{ .coords = built_ways[5].coords }).expectOffsets(&.{.{ -30, 0 }});
    try shaping.shape(tables, &.{ 80, 81 }, .{}).expectAdvances(&.{ 950, 1000 });
    try shaping.shape(tables, &.{ 80, 81 }, .{ .coords = built_ways[4].coords }).expectAdvances(&.{ 975, 1000 });
    try shaping.shape(tables, &.{ 82, 83 }, .{}).expectAdvances(&.{ 950, 1000 });
    try shaping.shape(tables, &.{ 82, 83 }, .{ .coords = built_ways[4].coords }).expectAdvances(&.{ 975, 1000 });
    try shaping.shape(tables, &.{ 5, 50 }, .{ .coords = built_ways[4].coords }).expectOffsets(&.{ .{ 0, 0 }, .{ -749, 704 } });
    try shaping.shape(tables, &.{ 5, 50 }, .{ .coords = built_ways[5].coords }).expectOffsets(&.{ .{ 0, 0 }, .{ -840, 700 } });

    // The other ways: the second feature on a part of the run, its
    // lookups the ones that replace its own; and the feature a language
    // requires, asked for or not.
    try shaping.shape(tables, &.{ 12, 12, 12, 12, 12 }, .{
        .script = built_ways[2].script,
        .features = &.{.{ .tag = more_tag, .first = 1, .last = 3 }},
    }).expectGlyphs(&.{ 12, 112, 112, 112, 12 });
    try shaping.shape(tables, &.{ 10, 12 }, .{ .language = built_ways[3].language, .features = &.{} }).expectGlyphs(&.{ 10, 112 });
}

/// The 16-bit number at `at` of `table`, 0 past its end.
fn wordAt(table: []const u8, at: usize) usize {
    if (at > table.len or table.len - at < 2) return 0;
    return std.mem.readInt(u16, table[at..][0..2], .big);
}

/// Where in a table a change is aimed: its header, and where each of the
/// lists and tables it names begins - for `GSUB` and `GPOS` down to the
/// first bytes of every subtable, where its format, its coverage and its
/// counts are.
const Targets = struct {
    spans: [most]Span = undefined,
    count: usize = 0,

    const most = 4096;

    /// How much of a list or a subtable counts as its beginning.
    const head = 40;

    const Span = struct {
        at: usize,
        len: usize,
    };

    fn add(targets: *Targets, table: []const u8, at: usize, len: usize) void {
        if (targets.count == most or at >= table.len) return;
        targets.spans[targets.count] = .{ .at = at, .len = @min(len, table.len - at) };
        targets.count += 1;
    }

    /// The targets of a sound `GDEF`.
    fn ofDefinitions(targets: *Targets, table: []const u8) void {
        targets.count = 0;
        targets.add(table, 0, 18);
        for ([_]usize{ 4, 6, 8, 10, 12 }) |place| {
            const start = wordAt(table, place);
            if (start != 0) targets.add(table, start, head);
        }
        // The store of deltas, where the table has one: its header, its
        // regions, and each of its lists.
        if (wordAt(table, 2) < 3 or table.len < 18) return;
        const store: usize = std.mem.readInt(u32, table[14..18], .big);
        if (store == 0 or store > table.len or table.len - store < 8) return;
        targets.add(table, store, head);
        targets.add(table, store + std.mem.readInt(u32, table[store + 2 ..][0..4], .big), head);
        for (0..wordAt(table, store + 6)) |nth| {
            const place = store + 8 + 4 * nth;
            if (place > table.len or table.len - place < 4) break;
            targets.add(table, store + std.mem.readInt(u32, table[place..][0..4], .big), head);
        }
    }

    /// The targets of a sound `GSUB` or `GPOS`.
    fn ofLookups(targets: *Targets, table: []const u8) void {
        targets.count = 0;
        targets.add(table, 0, 14);
        targets.add(table, wordAt(table, 4), head);
        targets.add(table, wordAt(table, 6), head);
        const list = wordAt(table, 8);
        const lookup_count = wordAt(table, list);
        targets.add(table, list, 2 + 2 * lookup_count);
        for (0..lookup_count) |nth| {
            const lookup = list + wordAt(table, list + 2 + 2 * nth);
            const subtable_count = wordAt(table, lookup + 4);
            targets.add(table, lookup, 8 + 2 * subtable_count);
            for (0..subtable_count) |part| {
                targets.add(table, lookup + wordAt(table, lookup + 6 + 2 * part), head);
            }
        }
        // The features replaced, where the table has them.
        if (wordAt(table, 2) != 0 and table.len >= 14) {
            targets.add(table, std.mem.readInt(u32, table[10..14], .big), head);
        }
    }
};

/// A change made to a table, and what was there before it.
const Change = struct {
    table: usize,
    at: usize,
    len: usize,
    before: [2]u8,
};

/// Where a change is made: mostly at one of the table's targets, often
/// in its first bytes, sometimes anywhere.
fn placeOf(random: std.Random, targets: *const Targets, length: usize) usize {
    const aim = random.uintLessThan(u8, 10);
    if (aim < 6 and targets.count != 0) {
        const span = targets.spans[random.uintLessThan(usize, targets.count)];
        return span.at + random.uintLessThan(usize, span.len);
    }
    if (aim < 8) return random.uintLessThan(usize, @min(length, 64));
    return random.uintLessThan(usize, length);
}

/// One change to `table`, which has two bytes or more: a byte, or more
/// often a big-endian number of two bytes at an even place, set to an
/// end of its range, to a neighbour of what it was, to the table's
/// length or what is left of it, with one bit turned, or to anything.
fn alter(random: std.Random, targets: *const Targets, number: usize, table: []u8) Change {
    const width: usize = if (random.uintLessThan(u8, 10) < 7) 2 else 1;
    var at = @min(placeOf(random, targets, table.len), table.len - width);
    if (width == 2 and random.uintLessThan(u8, 10) != 0) at &= ~@as(usize, 1);
    var change: Change = .{ .table = number, .at = at, .len = width, .before = @splat(0) };
    @memcpy(change.before[0..width], table[at..][0..width]);

    const bits: u5 = @intCast(width * 8 - 1);
    const top: u32 = @as(u32, 0xFFFF_FFFF) >> (31 - bits);
    var old: u32 = 0;
    for (table[at..][0..width]) |byte| old = old << 8 | byte;
    const value: u32 = top & switch (random.uintLessThan(u8, 13)) {
        0 => 0,
        1 => 1,
        2 => top,
        3 => top - 1,
        4 => top / 2,
        5 => top / 2 + 1,
        6 => old +% 1,
        7 => old -% 1,
        8 => @as(u32, @truncate(table.len)),
        9 => @as(u32, @truncate(table.len - at)),
        10 => old ^ (@as(u32, 1) << random.uintAtMost(u5, bits)),
        else => random.int(u32),
    };
    for (table[at..][0..width], 0..) |*byte, nth| {
        const shift: u5 = @intCast((width - 1 - nth) * 8);
        byte.* = @truncate(value >> shift);
    }
    return change;
}

/// How long a table cut short is: mostly at one of its targets, give or
/// take a few bytes; often within the first bytes; sometimes anywhere.
fn cutOf(random: std.Random, targets: *const Targets, length: usize) usize {
    const aim = random.uintLessThan(u8, 10);
    var cut: usize = undefined;
    if (aim < 5 and targets.count != 0) {
        const span = targets.spans[random.uintLessThan(usize, targets.count)];
        const edge = if (random.boolean()) span.at else span.at + span.len;
        cut = edge + random.uintLessThan(usize, 9) -| 4;
    } else if (aim < 8) {
        cut = random.uintLessThan(usize, @min(length, 64));
    } else {
        cut = random.uintLessThan(usize, length);
    }
    return @min(cut, length - 1);
}

/// The longest table read from a fuzzer: longer than any built here.
const most_input = 64 * 1024;

/// The most glyphs of a run read from a fuzzer.
const most_read = 64;

/// The most glyphs a run of `count` may have grown to.
fn growthOf(count: usize) usize {
    return @max(count * 64, 16384);
}

fn tablesOf(placed: [3][]u8) shaping.Tables {
    return .{ .gdef = placed[0], .gsub = placed[1], .gpos = placed[2] };
}

/// What a drawn text is made of besides a run's glyphs: letters of
/// several scripts and what many share, marks, the characters a text
/// does not show, selectors, bytes that are no UTF-8, and characters
/// with parts - letters with marks, a syllable, a mark of two - with a
/// space and a hyphen the font lacks.
const text_parts = [_][]const u8{
    "a",        "f",        "i",        " ",         "1",         ",",
    "\u{3B1}",  "\u{5D0}",  "\u{915}",  "\u{94D}",   "\u{4E2D}",  "\u{1F600}",
    "\u{301}",  "\u{323}",  "\u{AD}",   "\u{200C}",  "\u{200D}",  "\u{34F}",
    "\u{180B}", "\u{FE0F}", "\u{2060}", "\u{E0041}", "\u{E0100}", "\xC3",
    "\x80",     "\xE2\x82", "\xF0\x9F", "\xFF",      "\u{E9}",    "\u{1EAD}",
    "\u{1F82}", "\u{AC01}", "\u{344}",  "\u{958}",   "\u{308}",   "\u{5BC}",
    "\u{5B8}",  "\u{2003}", "\u{2011}",
};

/// The most pieces a drawn text has, each of four bytes at most, and the
/// most bytes of a text: a run read from a fuzzer, three bytes a glyph.
const most_pieces = 24;
const most_text = 3 * most_read;

/// The font a text is shaped with has a glyph for one character with a
/// selector, and a `kern` table of a few pairs. It lacks some of the
/// characters with parts, a space and a hyphen.
const text_variants = [_][3]u32{.{ 'a', 0xFE0F, 300 }};
const text_lacking = [_][2]u32{ .{ 0x1EAD, 0 }, .{ 0x1F82, 0 }, .{ 0x1F02, 0 }, .{ 0xAC01, 0 }, .{ 0x344, 0 }, .{ 0x2003, 0 }, .{ 0x2011, 0 } };
const text_kerning = [_][3]i32{ .{ 'a', 'f', -50 }, .{ 'f', 'i', 20 }, .{ 10, 11, 30 }, .{ 17, 18, -40 } };

/// How many texts of runs a round shapes.
const texts_drawn = 4;

/// Writes the character `char` to `bytes` at `at`, as UTF-8 writes one
/// of that number - one a text may not hold too. Answers its length.
fn putChar(bytes: []u8, at: usize, char: u16) usize {
    if (char < 0x80) {
        bytes[at] = @intCast(char);
        return 1;
    }
    if (char < 0x800) {
        bytes[at] = @intCast(0xC0 | (char >> 6));
        bytes[at + 1] = @intCast(0x80 | (char & 0x3F));
        return 2;
    }
    bytes[at] = @intCast(0xE0 | (char >> 12));
    bytes[at + 1] = @intCast(0x80 | ((char >> 6) & 0x3F));
    bytes[at + 2] = @intCast(0x80 | (char & 0x3F));
    return 3;
}

/// The run `glyphs` as a text: each glyph's number as a character.
fn textOf(glyphs: []const u16, bytes: *[most_text]u8) []const u8 {
    var length: usize = 0;
    for (glyphs) |glyph| {
        if (length + 3 > bytes.len) break;
        length += putChar(bytes, length, glyph);
    }
    return bytes[0..length];
}

/// A text drawn piece by piece: a glyph of `glyphs` as a character, or
/// one of `text_parts`.
fn drawnText(random: std.Random, glyphs: []const u16, bytes: *[most_text]u8) []const u8 {
    var length: usize = 0;
    for (0..random.uintAtMost(usize, most_pieces)) |_| {
        if (glyphs.len != 0 and random.boolean()) {
            length += putChar(bytes, length, glyphs[random.uintLessThan(usize, glyphs.len)]);
            continue;
        }
        const part = text_parts[random.uintLessThan(usize, text_parts.len)];
        @memcpy(bytes[length..][0..part.len], part);
        length += part.len;
    }
    return bytes[0..length];
}

const Harness = struct {
    /// Where `GDEF`, `GSUB` and `GPOS` are put, each to end at a closed
    /// page of its own.
    arenas: [3]Arena,
    targets: *[3]Targets,
    /// What a fuzzer's tables and run are read into.
    input: []u8,
    calls: u64 = 0,
    /// The calls that answered a shaped run, and those of them whose
    /// run came out other than it went in.
    shaped: u64 = 0,
    changed: u64 = 0,
    /// The calls whose run grew past the tests' room, and those there
    /// was no more memory for.
    grown: u64 = 0,
    starved: u64 = 0,
    /// The texts shaped, those of them answered shaped, the texts of a
    /// run that came out with a glyph the run does not have, and those
    /// there was no more memory for.
    texts: u64 = 0,
    texts_shaped: u64 = 0,
    texts_replaced: u64 = 0,
    texts_starved: u64 = 0,

    fn up() !Harness {
        const targets = try testing.allocator.create([3]Targets);
        errdefer testing.allocator.destroy(targets);
        const input = try testing.allocator.alloc(u8, most_input);
        errdefer testing.allocator.free(input);
        var arenas: [3]Arena = undefined;
        for (&arenas, 0..) |*arena, nth| {
            arena.* = Arena.init() catch |err| {
                for (arenas[0..nth]) |*made| made.free();
                return err;
            };
        }
        return .{ .arenas = arenas, .targets = targets, .input = input };
    }

    fn down(harness: *Harness) void {
        for (&harness.arenas) |*arena| arena.free();
        testing.allocator.free(harness.input);
        testing.allocator.destroy(harness.targets);
    }

    /// One run shaped one way with `tables`, and what holds of every
    /// answer held against this one. `blocks`, when given, is how many
    /// blocks of memory the call gets.
    fn check(harness: *Harness, tables: shaping.Tables, glyphs: []const u16, way: *const Way, blocks: ?u32) !void {
        const run = shaping.shape(tables, glyphs, .{
            .script = way.script,
            .language = way.language,
            .backward = way.backward,
            .features = way.features,
            .coords = way.coords,
            .blocks = blocks,
        });
        harness.calls += 1;
        switch (run.result) {
            tts.TTS_OK => {
                try testing.expect(run.count <= shaping.room);
                var same = run.count == glyphs.len;
                for (run.glyphs[0..run.count], 0..) |glyph, index| {
                    try testing.expect(glyph.glyph <= 0xFFFF);
                    try testing.expect(glyph.cluster < glyphs.len);
                    if (!same) continue;
                    const from = if (way.backward) glyphs.len - 1 - index else index;
                    same = glyph.glyph == glyphs[from] and glyph.cluster == from and
                        glyph.advance == 1000 and glyph.x_offset == 0 and glyph.y_offset == 0;
                }
                harness.shaped += 1;
                if (!same) harness.changed += 1;
            },
            tts.TTSERR_ROOM => {
                try testing.expect(run.count > shaping.room and run.count <= growthOf(glyphs.len));
                harness.grown += 1;
            },
            tts.TTSERR_NOMEM => {
                try testing.expect(blocks != null);
                harness.starved += 1;
            },
            else => return error.NoSuchAnswer,
        }
    }

    /// One text shaped one way with `tables`, and what holds of every
    /// answer held against this one. `glyphs` is the run the text is
    /// made of, null for another text.
    fn checkText(harness: *Harness, tables: shaping.Tables, text: []const u8, glyphs: ?[]const u16, way: *const Way, blocks: ?u32) !void {
        const run = shaping.shapeText(tables, text, .{
            .language = way.language,
            .backward = way.backward,
            .features = way.features,
            .glyphs = &text_lacking,
            .variants = &text_variants,
            .kerning = &text_kerning,
            .coords = way.coords,
            .blocks = blocks,
        });
        harness.texts += 1;
        switch (run.result) {
            tts.TTS_OK => {
                try testing.expect(run.count <= shaping.room);
                var replaced = false;
                for (run.glyphs[0..run.count]) |glyph| {
                    try testing.expect(glyph.glyph <= 0xFFFF);
                    try testing.expect(glyph.cluster < text.len);
                    const had = glyphs orelse continue;
                    if (glyph.glyph == 0xFFFD or std.mem.indexOfScalar(u16, had, @intCast(glyph.glyph)) != null) continue;
                    replaced = true;
                }
                harness.texts_shaped += 1;
                if (replaced) harness.texts_replaced += 1;
            },
            tts.TTSERR_ROOM => {
                // Each stretch of a script grows by itself.
                try testing.expect(run.count > shaping.room and run.count <= growthOf(1) * text.len);
            },
            tts.TTSERR_NOMEM => {
                try testing.expect(blocks != null);
                try testing.expectEqual(@as(u32, 0xDEAD), run.count);
                harness.texts_starved += 1;
            },
            else => return error.NoSuchAnswer,
        }
    }

    /// Runs of `work` shaped as texts with `tables`, and a text drawn
    /// around one of them - that once more with memory that runs out
    /// after a few blocks.
    fn roundOfTexts(harness: *Harness, random: std.Random, tables: shaping.Tables, work: *const Work) !void {
        var bytes: [most_text]u8 = undefined;
        for (0..texts_drawn) |_| {
            const run = work.runs[random.uintLessThan(usize, work.runs.len)];
            const way = &work.ways[random.uintLessThan(usize, work.ways.len)];
            try harness.checkText(tables, textOf(run, &bytes), run, way, null);
        }
        const run = work.runs[random.uintLessThan(usize, work.runs.len)];
        const way = &work.ways[random.uintLessThan(usize, work.ways.len)];
        const drawn = drawnText(random, run, &bytes);
        try harness.checkText(tables, drawn, null, way, null);
        try harness.checkText(tables, drawn, null, way, random.uintLessThan(u32, 6));
    }

    /// The runs of `work` shaped with `tables`, and one of them once
    /// more with memory that runs out after a few blocks; then texts.
    fn round(harness: *Harness, random: std.Random, tables: shaping.Tables, work: *const Work) !void {
        if (work.drawn == 0) {
            for (work.runs) |run| {
                for (work.ways) |*way| try harness.check(tables, run, way, null);
            }
        } else {
            for (0..work.drawn) |_| {
                const run = work.runs[random.uintLessThan(usize, work.runs.len)];
                const way = &work.ways[random.uintLessThan(usize, work.ways.len)];
                try harness.check(tables, run, way, null);
            }
        }
        const run = work.runs[random.uintLessThan(usize, work.runs.len)];
        const way = &work.ways[random.uintLessThan(usize, work.ways.len)];
        try harness.check(tables, run, way, random.uintLessThan(u32, 4));
        try harness.roundOfTexts(random, tables, work);
    }

    /// The tables of `source` - `GDEF`, `GSUB`, `GPOS` - as they are,
    /// then `rounds` times with a few changes made to them, every
    /// sixteenth time one of them cut short instead.
    fn mutate(harness: *Harness, random: std.Random, source: [3][]const u8, work: *const Work, rounds: u32) !void {
        var placed: [3][]u8 = undefined;
        for (&placed, source, &harness.arenas) |*table, bytes, *arena| table.* = arena.place(bytes);
        harness.targets[0].ofDefinitions(source[0]);
        harness.targets[1].ofLookups(source[1]);
        harness.targets[2].ofLookups(source[2]);
        try harness.round(random, tablesOf(placed), work);

        // The tables there is something of to change.
        var open: [3]usize = undefined;
        var open_count: usize = 0;
        for (source, 0..) |bytes, number| {
            if (bytes.len < 2) continue;
            open[open_count] = number;
            open_count += 1;
        }
        if (open_count == 0) return;

        var changes: [4]Change = undefined;
        for (0..rounds) |number| {
            if (number % 16 == 15) {
                const table = open[random.uintLessThan(usize, open_count)];
                const length = cutOf(random, &harness.targets[table], source[table].len);
                var cut = placed;
                cut[table] = harness.arenas[table].place(source[table][0..length]);
                try harness.round(random, tablesOf(cut), work);
                // The whole of it again, where the cut one was.
                _ = harness.arenas[table].place(source[table]);
                continue;
            }
            const count = random.intRangeAtMost(usize, 1, changes.len);
            for (changes[0..count]) |*change| {
                const table = open[random.uintLessThan(usize, open_count)];
                change.* = alter(random, &harness.targets[table], table, placed[table]);
            }
            try harness.round(random, tablesOf(placed), work);
            // Taken back last first: one may lie over another.
            var left = count;
            while (left != 0) {
                left -= 1;
                const change = &changes[left];
                @memcpy(placed[change.table][change.at..][0..change.len], change.before[0..change.len]);
            }
        }
    }

    /// Three tables and a run read from a fuzzer: `GDEF`, `GSUB`,
    /// `GPOS`, and the run's glyphs, two bytes each. The run's bytes are
    /// shaped as a text too.
    fn one(harness: *Harness, smith: *testing.Smith) anyerror!void {
        var placed: [3][]u8 = undefined;
        for (&placed, &harness.arenas) |*table, *arena| {
            const length = smith.slice(harness.input);
            table.* = arena.place(harness.input[0..length]);
        }
        const length = smith.slice(harness.input[0 .. 2 * most_read]);
        var glyphs: [most_read]u16 = undefined;
        const count = length / 2;
        for (glyphs[0..count], 0..) |*glyph, nth| glyph.* = std.mem.readInt(u16, harness.input[2 * nth ..][0..2], .big);
        for (&built_ways) |*way| try harness.check(tablesOf(placed), glyphs[0..count], way, null);
        for (&built_ways) |*way| try harness.checkText(tablesOf(placed), harness.input[0..length], null, way, null);
    }
};

/// The table `tag` of the font file `font`; of no length when the font
/// has none.
fn tableIn(font: []const u8, tag: *const [4]u8) []const u8 {
    if (font.len < 12) return &.{};
    const listed: usize = std.mem.readInt(u16, font[4..6], .big);
    for (0..listed) |nth| {
        const record = 12 + nth * 16;
        if (record + 16 > font.len) break;
        if (!std.mem.eql(u8, font[record..][0..4], tag)) continue;
        const at: usize = std.mem.readInt(u32, font[record + 8 ..][0..4], .big);
        const len: usize = std.mem.readInt(u32, font[record + 12 ..][0..4], .big);
        if (at > font.len or font.len - at < len) return &.{};
        return font[at..][0..len];
    }
    return &.{};
}

/// What a fetched font's tables are shaped with: the runs its reference
/// writes out, and the reference's cases of more than one feature - or
/// all its cases, when none has more.
const Fetched = struct {
    glyphs: []u16,
    runs: [][]const u16,
    features: []tts.Feature,
    ways: []Way,

    /// How many runs a round draws.
    const drawn = 16;

    fn tagOf(text: []const u8) u32 {
        return if (text.len == 4) tts.featureTag(text[0..4]) else 0;
    }

    fn taken(expected: *const reference.Font, case: *const reference.Case) bool {
        if (case.features.len > 4) return true;
        for (expected.cases) |other| {
            if (other.features.len > 4) return false;
        }
        return true;
    }

    fn of(expected: *const reference.Font) !Fetched {
        var run_count: usize = 0;
        var glyph_count: usize = 0;
        var lines = std.mem.tokenizeScalar(u8, expected.runs, '\n');
        while (lines.next()) |line| : (run_count += 1) {
            var numbers = std.mem.tokenizeScalar(u8, line, ' ');
            while (numbers.next()) |_| glyph_count += 1;
        }
        var way_count: usize = 0;
        var feature_count: usize = 0;
        for (expected.cases) |*case| {
            if (!taken(expected, case)) continue;
            way_count += 1;
            feature_count += case.features.len / 4;
        }

        const glyphs = try testing.allocator.alloc(u16, glyph_count);
        errdefer testing.allocator.free(glyphs);
        const runs = try testing.allocator.alloc([]const u16, run_count);
        errdefer testing.allocator.free(runs);
        const features = try testing.allocator.alloc(tts.Feature, feature_count);
        errdefer testing.allocator.free(features);
        const ways = try testing.allocator.alloc(Way, way_count);
        errdefer testing.allocator.free(ways);

        var glyph_at: usize = 0;
        var run_at: usize = 0;
        lines = std.mem.tokenizeScalar(u8, expected.runs, '\n');
        while (lines.next()) |line| : (run_at += 1) {
            const start = glyph_at;
            var numbers = std.mem.tokenizeScalar(u8, line, ' ');
            while (numbers.next()) |number| : (glyph_at += 1) glyphs[glyph_at] = try std.fmt.parseInt(u16, number, 16);
            runs[run_at] = glyphs[start..glyph_at];
        }
        var feature_at: usize = 0;
        var way_at: usize = 0;
        for (expected.cases) |*case| {
            if (!taken(expected, case)) continue;
            const start = feature_at;
            for (0..case.features.len / 4) |nth| {
                features[feature_at] = .{ .tag = tagOf(case.features[nth * 4 ..][0..4]) };
                feature_at += 1;
            }
            ways[way_at] = .{
                .script = tagOf(case.script),
                .language = tagOf(case.language),
                .features = features[start..feature_at],
                .backward = case.backward,
            };
            way_at += 1;
        }
        return .{ .glyphs = glyphs, .runs = runs, .features = features, .ways = ways };
    }

    fn work(fetched: *const Fetched) Work {
        return .{ .runs = fetched.runs, .ways = fetched.ways, .drawn = drawn };
    }

    fn free(fetched: *const Fetched) void {
        testing.allocator.free(fetched.ways);
        testing.allocator.free(fetched.features);
        testing.allocator.free(fetched.runs);
        testing.allocator.free(fetched.glyphs);
    }
};

/// How many times the built tables are changed, and each fetched font's.
const built_rounds = 1000;
const fetched_rounds = 400;

test "truetypeshaping: built tables with numbers changed and cut short" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var built: Built = .{};
    try built.make();
    var harness = try Harness.up();
    defer harness.down();
    var numbers = std.Random.DefaultPrng.init(0x4753_5542);
    const source = [3][]const u8{ built.gdef.written(), built.gsub.written(), built.gpos.written() };
    try harness.mutate(numbers.random(), source, &built_work, built_rounds);
    // The changes left most of the runs shaped, and many of them shaped
    // to something.
    try testing.expect(harness.shaped >= harness.calls / 2);
    try testing.expect(harness.changed >= harness.shaped / 4);
    try testing.expect(harness.starved != 0);
    // And so with the texts: a lookup found its glyphs in many.
    try testing.expect(harness.texts_shaped >= harness.texts / 2);
    try testing.expect(harness.texts_replaced >= harness.texts / 16);
    try testing.expect(harness.texts_starved != 0);
}

test "truetypeshaping: fetched fonts' tables with numbers changed and cut short" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var harness = try Harness.up();
    defer harness.down();
    var numbers = std.Random.DefaultPrng.init(0x4750_4F53);
    var read: u32 = 0;
    for (reference.all) |expected| {
        const bytes = reference.read(expected) catch |err| switch (err) {
            error.SkipZigTest => continue,
            else => return err,
        };
        defer testing.allocator.free(bytes);
        read += 1;
        const source = [3][]const u8{ tableIn(bytes, "GDEF"), tableIn(bytes, "GSUB"), tableIn(bytes, "GPOS") };
        const fetched = try Fetched.of(expected);
        defer fetched.free();
        // A font of no layout tables has no runs written for it.
        if (fetched.runs.len == 0 or fetched.ways.len == 0) continue;
        try harness.mutate(numbers.random(), source, &fetched.work(), fetched_rounds);
    }
    if (read == 0) return error.SkipZigTest;
    try testing.expect(harness.shaped >= harness.calls / 2);
    try testing.expect(harness.changed >= harness.shaped / 4);
    try testing.expect(harness.texts_shaped >= harness.texts / 2);
}

test "truetypeshaping: tables from a fuzzer, and the built tables as they are" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var built: Built = .{};
    try built.make();
    var harness = try Harness.up();
    defer harness.down();

    // An entry of the corpus is what `Harness.one` reads: each of the
    // three tables and then the run, its length in four bytes before
    // it, the lowest first.
    const source = [3][]const u8{ built.gdef.written(), built.gsub.written(), built.gpos.written() };
    var corpus: [built_runs.len][]const u8 = undefined;
    var made: usize = 0;
    defer for (corpus[0..made]) |entry| testing.allocator.free(entry);
    for (built_runs) |run| {
        var length: usize = 4 + 2 * run.len;
        for (source) |table| length += 4 + table.len;
        const entry = try testing.allocator.alloc(u8, length);
        corpus[made] = entry;
        made += 1;
        var at: usize = 0;
        for (source) |table| {
            std.mem.writeInt(u32, entry[at..][0..4], @intCast(table.len), .little);
            @memcpy(entry[at + 4 ..][0..table.len], table);
            at += 4 + table.len;
        }
        std.mem.writeInt(u32, entry[at..][0..4], @intCast(2 * run.len), .little);
        for (run, 0..) |glyph, nth| std.mem.writeInt(u16, entry[at + 4 + 2 * nth ..][0..2], glyph, .big);
    }
    try testing.fuzz(&harness, Harness.one, .{ .corpus = &corpus });
    // Every run of the corpus came out shaped, each of the four ways.
    try testing.expect(harness.shaped >= built_runs.len * built_ways.len);
    try testing.expect(harness.changed >= harness.shaped / 2);
    try testing.expect(harness.texts_shaped >= built_runs.len * built_ways.len);
}
