// SPDX-License-Identifier: MIT
//! Host tests of what a call applies: the script and the language found
//! in a table, the feature a language requires, features replaced under
//! conditions, the glyphs a feature holds for, and the errors.

const std = @import("std");
const tts = @import("sdk").truetypeshaping;
const layout = @import("layout.zig");
const subtables = @import("subtables.zig");
const harness = @import("harness.zig");

const File = layout.File;
const shape = harness.shape;
const testing = std.testing;

const test_tag = tts.featureTag("test");

/// Six lookups, the one of number n adding n + 1 to the glyph 5; `room`
/// holds their subtables.
fn sixLookups(room: *[6]File, lookups: *[6]layout.Lookup, subtable_lists: *[6][1][]const u8) void {
    for (room, lookups, subtable_lists, 0..) |*file, *lookup, *list, index| {
        file.* = .{};
        subtables.singleDelta(file, &.{5}, @intCast(index + 1));
        list[0] = file.written();
        lookup.* = .{ .kind = 1, .subtables = list };
    }
}

/// Six features tagged `test`, the one of number n with the lookup n.
const six_features = [_]layout.Feature{
    .{ .tag = "test", .lookups = &.{0} },
    .{ .tag = "test", .lookups = &.{1} },
    .{ .tag = "test", .lookups = &.{2} },
    .{ .tag = "test", .lookups = &.{3} },
    .{ .tag = "test", .lookups = &.{4} },
    .{ .tag = "test", .lookups = &.{5} },
};

/// What the glyph 5 becomes with `scripts`, for a script and a language:
/// 5 plus the number of the feature that was applied, plus 1.
fn became(scripts: []const layout.Script, script: u32, language: u32) !u32 {
    var room: [6]File = undefined;
    var lookups: [6]layout.Lookup = undefined;
    var lists: [6][1][]const u8 = undefined;
    sixLookups(&room, &lookups, &lists);
    var file: File = .{};
    layout.tableOf(&file, scripts, &six_features, &lookups);
    const run = shape(.{ .gsub = file.written() }, &.{5}, .{ .script = script, .language = language });
    try testing.expectEqual(tts.TTS_OK, run.result);
    return run.glyphs[0].glyph;
}

test "the script asked for, or else DFLT" {
    const scripts = [_]layout.Script{
        .{ .tag = "DFLT", .languages = &.{.{ .features = &.{0} }} },
        .{ .tag = "cyrl", .languages = &.{ .{ .features = &.{2} }, .{ .tag = "SRB ", .features = &.{3} } } },
        .{ .tag = "latn", .languages = &.{.{ .features = &.{1} }} },
    };
    try testing.expectEqual(@as(u32, 7), try became(&scripts, tts.scriptTag("latn"), tts.TTS_LANGUAGE_DEFAULT));
    try testing.expectEqual(@as(u32, 8), try became(&scripts, tts.scriptTag("cyrl"), tts.TTS_LANGUAGE_DEFAULT));
    try testing.expectEqual(@as(u32, 6), try became(&scripts, tts.scriptTag("grek"), tts.TTS_LANGUAGE_DEFAULT));
    try testing.expectEqual(@as(u32, 6), try became(&scripts, tts.TTS_SCRIPT_DEFAULT, tts.TTS_LANGUAGE_DEFAULT));
    // The language of a script, or else the script's default.
    try testing.expectEqual(@as(u32, 9), try became(&scripts, tts.scriptTag("cyrl"), tts.languageTag("SRB ")));
    try testing.expectEqual(@as(u32, 8), try became(&scripts, tts.scriptTag("cyrl"), tts.languageTag("MKD ")));
    try testing.expectEqual(@as(u32, 7), try became(&scripts, tts.scriptTag("latn"), tts.languageTag("SRB ")));
}

test "without DFLT the script dflt, and without that latn" {
    const two = [_]layout.Script{
        .{ .tag = "dflt", .languages = &.{.{ .features = &.{0} }} },
        .{ .tag = "latn", .languages = &.{.{ .features = &.{1} }} },
    };
    try testing.expectEqual(@as(u32, 6), try became(&two, tts.scriptTag("grek"), tts.TTS_LANGUAGE_DEFAULT));
    try testing.expectEqual(@as(u32, 6), try became(two[0..1], tts.TTS_SCRIPT_DEFAULT, tts.TTS_LANGUAGE_DEFAULT));
    try testing.expectEqual(@as(u32, 7), try became(two[1..2], tts.scriptTag("grek"), tts.TTS_LANGUAGE_DEFAULT));
    // A table of another script alone has nothing for this one.
    const other = [_]layout.Script{.{ .tag = "cyrl", .languages = &.{.{ .features = &.{0} }} }};
    try testing.expectEqual(@as(u32, 5), try became(&other, tts.scriptTag("grek"), tts.TTS_LANGUAGE_DEFAULT));
}

test "a language tagged dflt comes before the script's default" {
    const scripts = [_]layout.Script{.{ .tag = "latn", .languages = &.{
        .{ .features = &.{0} },
        .{ .tag = "dflt", .features = &.{1} },
        .{ .tag = "TRK ", .features = &.{2} },
    } }};
    try testing.expectEqual(@as(u32, 8), try became(&scripts, tts.scriptTag("latn"), tts.languageTag("TRK ")));
    try testing.expectEqual(@as(u32, 7), try became(&scripts, tts.scriptTag("latn"), tts.languageTag("DEU ")));
    try testing.expectEqual(@as(u32, 7), try became(&scripts, tts.scriptTag("latn"), tts.TTS_LANGUAGE_DEFAULT));
    // A script with tagged languages alone and none that fits has nothing.
    const tagged = [_]layout.Script{.{ .tag = "latn", .languages = &.{.{ .tag = "TRK ", .features = &.{2} }} }};
    try testing.expectEqual(@as(u32, 5), try became(&tagged, tts.scriptTag("latn"), tts.languageTag("DEU ")));
}

test "of a language's features with one tag the first is applied" {
    const scripts = [_]layout.Script{.{ .tag = "DFLT", .languages = &.{.{ .features = &.{ 3, 1 } }} }};
    try testing.expectEqual(@as(u32, 9), try became(&scripts, tts.TTS_SCRIPT_DEFAULT, tts.TTS_LANGUAGE_DEFAULT));
}

/// A `GSUB` of the script `DFLT` whose language requires the feature 1,
/// which adds 100 to the glyphs 5 and 15, and has the feature `test`,
/// which adds 10 to the glyph 5.
fn requiring(file: *File, ten: *File, hundred: *File) []const u8 {
    subtables.singleDelta(ten, &.{5}, 10);
    subtables.singleDelta(hundred, &.{ 5, 15 }, 100);
    layout.tableOf(
        file,
        &.{.{ .tag = "DFLT", .languages = &.{.{ .required = 1, .features = &.{0} }} }},
        &.{ .{ .tag = "test", .lookups = &.{0} }, .{ .tag = "rqrd", .lookups = &.{1} } },
        &.{ .{ .kind = 1, .subtables = &.{ten.written()} }, .{ .kind = 1, .subtables = &.{hundred.written()} } },
    );
    return file.written();
}

test "what a language requires is applied to every glyph, asked for or not" {
    var file: File = .{};
    var ten: File = .{};
    var hundred: File = .{};
    const gsub = requiring(&file, &ten, &hundred);
    try shape(.{ .gsub = gsub }, &.{ 5, 5 }, .{ .features = &.{} }).expectGlyphs(&.{ 105, 105 });
    try shape(.{ .gsub = gsub }, &.{ 5, 5 }, .{}).expectGlyphs(&.{ 115, 115 });
    // A feature for a part of the run leaves the required one to all of it.
    const part = [_]tts.Feature{.{ .tag = test_tag, .first = 1, .last = 1 }};
    try shape(.{ .gsub = gsub }, &.{ 5, 5 }, .{ .features = &part }).expectGlyphs(&.{ 105, 115 });
}

test "a feature the language does not list does nothing" {
    var ten: File = .{};
    subtables.singleDelta(&ten, &.{5}, 10);
    var file: File = .{};
    layout.tableOf(
        &file,
        &.{.{ .tag = "DFLT", .languages = &.{.{ .features = &.{1} }} }},
        &.{ .{ .tag = "test", .lookups = &.{0} }, .{ .tag = "liga", .lookups = &.{} } },
        &.{.{ .kind = 1, .subtables = &.{ten.written()} }},
    );
    try shape(.{ .gsub = file.written() }, &.{5}, .{}).expectGlyphs(&.{5});
    // Nor does one the table does not have, or no feature at all.
    var plain: File = .{};
    layout.tableOfOne(&plain, &.{.{ .kind = 1, .subtables = &.{ten.written()} }});
    const other = [_]tts.Feature{.{ .tag = tts.featureTag("liga") }};
    try shape(.{ .gsub = plain.written() }, &.{5}, .{ .features = &other }).expectGlyphs(&.{5});
    try shape(.{ .gsub = plain.written() }, &.{5}, .{ .features = &.{} }).expectGlyphs(&.{5});
}

test "a table of a version not known does nothing" {
    var ten: File = .{};
    subtables.singleDelta(&ten, &.{5}, 10);
    var file: File = .{};
    layout.tableOfOne(&file, &.{.{ .kind = 1, .subtables = &.{ten.written()} }});
    file.setWord(0, 2);
    try shape(.{ .gsub = file.written() }, &.{5}, .{}).expectGlyphs(&.{5});
    try shape(.{ .gsub = file.written()[0..7] }, &.{5}, .{}).expectGlyphs(&.{5});
    try shape(.{}, &.{5}, .{}).expectGlyphs(&.{5});
}

/// A `GSUB` whose feature `test` adds 10 to the glyph 5, and adds 20
/// instead where `variations` say so.
fn varied(file: *File, ten: *File, twenty: *File, variations: []const layout.Variation) []const u8 {
    subtables.singleDelta(ten, &.{5}, 10);
    subtables.singleDelta(twenty, &.{5}, 20);
    layout.tableVaried(
        file,
        &.{.{ .tag = "DFLT", .languages = &.{.{ .features = &.{0} }} }},
        &.{.{ .tag = "test", .lookups = &.{0} }},
        &.{ .{ .kind = 1, .subtables = &.{ten.written()} }, .{ .kind = 1, .subtables = &.{twenty.written()} } },
        variations,
    );
    return file.written();
}

fn variedTo(variations: []const layout.Variation) !u32 {
    var file: File = .{};
    var ten: File = .{};
    var twenty: File = .{};
    const run = shape(.{ .gsub = varied(&file, &ten, &twenty, variations) }, &.{5}, .{});
    try testing.expectEqual(tts.TTS_OK, run.result);
    return run.glyphs[0].glyph;
}

test "features replaced under conditions: judged for the font with no axis set" {
    const replaced = [_]layout.Replaced{.{ .feature = 0, .lookups = &.{1} }};
    // The axis's 0 lies within the range.
    try testing.expectEqual(@as(u32, 25), try variedTo(&.{.{ .conditions = &.{.{ .low = -8192, .high = 8192 }}, .replaced = &replaced }}));
    try testing.expectEqual(@as(u32, 25), try variedTo(&.{.{ .conditions = &.{.{ .low = 0, .high = 0 }}, .replaced = &replaced }}));
    // It lies outside.
    try testing.expectEqual(@as(u32, 15), try variedTo(&.{.{ .conditions = &.{.{ .low = 4096, .high = 16384 }}, .replaced = &replaced }}));
    try testing.expectEqual(@as(u32, 15), try variedTo(&.{.{ .conditions = &.{.{ .low = -16384, .high = -1 }}, .replaced = &replaced }}));
    // Every condition has to hold; none at all holds.
    try testing.expectEqual(@as(u32, 15), try variedTo(&.{.{
        .conditions = &.{ .{ .low = -8192, .high = 8192 }, .{ .axis = 1, .low = 100, .high = 200 } },
        .replaced = &replaced,
    }}));
    try testing.expectEqual(@as(u32, 25), try variedTo(&.{.{ .conditions = &.{}, .replaced = &replaced }}));
    // A condition of a form not known does not hold.
    try testing.expectEqual(@as(u32, 15), try variedTo(&.{.{ .conditions = &.{.{ .format = 2, .low = 0, .high = 0 }}, .replaced = &replaced }}));
}

test "features replaced under conditions: the first record that holds" {
    const twenty = [_]layout.Replaced{.{ .feature = 0, .lookups = &.{1} }};
    const neither = [_]layout.Replaced{.{ .feature = 0, .lookups = &.{} }};
    try testing.expectEqual(@as(u32, 25), try variedTo(&.{
        .{ .conditions = &.{.{ .low = 100, .high = 200 }}, .replaced = &neither },
        .{ .conditions = &.{.{ .low = -100, .high = 200 }}, .replaced = &twenty },
        .{ .conditions = &.{.{ .low = -100, .high = 200 }}, .replaced = &neither },
    }));
    // A record that replaces another feature leaves this one as it is.
    try testing.expectEqual(@as(u32, 15), try variedTo(&.{.{ .conditions = &.{}, .replaced = &.{.{ .feature = 3, .lookups = &.{1} }} }}));
}

/// A `GSUB` whose feature `test` adds 10 to the glyph 5.
fn plusTen(file: *File, ten: *File) []const u8 {
    subtables.singleDelta(ten, &.{5}, 10);
    layout.tableOfOne(file, &.{.{ .kind = 1, .subtables = &.{ten.written()} }});
    return file.written();
}

test "a feature holds for the glyphs whose cluster is within its range" {
    var file: File = .{};
    var ten: File = .{};
    const gsub = plusTen(&file, &ten);
    const middle = [_]tts.Feature{.{ .tag = test_tag, .first = 1, .last = 2 }};
    try shape(.{ .gsub = gsub }, &.{ 5, 5, 5, 5 }, .{ .features = &middle }).expectGlyphs(&.{ 5, 15, 15, 5 });
    // By cluster, not by place.
    try shape(.{ .gsub = gsub }, &.{ 5, 5, 5, 5 }, .{ .features = &middle, .clusters = &.{ 0, 0, 2, 9 } }).expectGlyphs(&.{ 5, 5, 15, 5 });
    const from = [_]tts.Feature{.{ .tag = test_tag, .first = 2 }};
    try shape(.{ .gsub = gsub }, &.{ 5, 5, 5, 5 }, .{ .features = &from }).expectGlyphs(&.{ 5, 5, 15, 15 });
    const none = [_]tts.Feature{.{ .tag = test_tag, .first = 3, .last = 2 }};
    try shape(.{ .gsub = gsub }, &.{ 5, 5, 5, 5 }, .{ .features = &none }).expectGlyphs(&.{ 5, 5, 5, 5 });
}

test "a feature of the value 0 is off" {
    var file: File = .{};
    var ten: File = .{};
    const gsub = plusTen(&file, &ten);
    const off = [_]tts.Feature{.{ .tag = test_tag, .value = 0 }};
    try shape(.{ .gsub = gsub }, &.{ 5, 5 }, .{ .features = &off }).expectGlyphs(&.{ 5, 5 });
}

test "where two features of one tag hold for a glyph, the later one does" {
    var file: File = .{};
    var ten: File = .{};
    const gsub = plusTen(&file, &ten);
    // On for the run, off for a part of it.
    const but_one = [_]tts.Feature{ .{ .tag = test_tag }, .{ .tag = test_tag, .value = 0, .first = 2, .last = 2 } };
    try shape(.{ .gsub = gsub }, &.{ 5, 5, 5, 5 }, .{ .features = &but_one }).expectGlyphs(&.{ 15, 15, 5, 15 });
    // Off for the run, on for a part of it.
    const only_one = [_]tts.Feature{ .{ .tag = test_tag, .value = 0 }, .{ .tag = test_tag, .first = 2, .last = 2 } };
    try shape(.{ .gsub = gsub }, &.{ 5, 5, 5, 5 }, .{ .features = &only_one }).expectGlyphs(&.{ 5, 5, 15, 5 });
    // The later of two for the whole run.
    const off_then_on = [_]tts.Feature{ .{ .tag = test_tag, .value = 0 }, .{ .tag = test_tag } };
    try shape(.{ .gsub = gsub }, &.{ 5, 5 }, .{ .features = &off_then_on }).expectGlyphs(&.{ 15, 15 });
    const on_then_off = [_]tts.Feature{ .{ .tag = test_tag }, .{ .tag = test_tag, .value = 0 } };
    try shape(.{ .gsub = gsub }, &.{ 5, 5 }, .{ .features = &on_then_off }).expectGlyphs(&.{ 5, 5 });
}

test "two features of one tag with different values, each for its glyphs" {
    var forms: File = .{};
    subtables.multiple(&forms, &.{5}, &.{&.{ 30, 31, 32 }});
    var file: File = .{};
    layout.tableOfOne(&file, &.{.{ .kind = 3, .subtables = &.{forms.written()} }});
    const features = [_]tts.Feature{ .{ .tag = test_tag, .value = 1 }, .{ .tag = test_tag, .value = 3, .first = 1, .last = 1 } };
    try shape(.{ .gsub = file.written() }, &.{ 5, 5, 5 }, .{ .features = &features }).expectGlyphs(&.{ 30, 32, 30 });
}

test "two features with one lookup: for the glyphs of either" {
    var ten: File = .{};
    subtables.singleDelta(&ten, &.{5}, 10);
    var file: File = .{};
    layout.table(
        &file,
        &.{ .{ .tag = "aaaa", .lookups = &.{0} }, .{ .tag = "bbbb", .lookups = &.{0} } },
        &.{.{ .kind = 1, .subtables = &.{ten.written()} }},
    );
    const features = [_]tts.Feature{
        .{ .tag = tts.featureTag("aaaa"), .first = 0, .last = 0 },
        .{ .tag = tts.featureTag("bbbb"), .first = 2, .last = 2 },
    };
    try shape(.{ .gsub = file.written() }, &.{ 5, 5, 5 }, .{ .features = &features }).expectGlyphs(&.{ 15, 5, 15 });
}

test "a call takes 31 features that hold for a part of the run" {
    var file: File = .{};
    var ten: File = .{};
    const gsub = plusTen(&file, &ten);
    var features: [32]tts.Feature = undefined;
    for (&features, 0..) |*feature, index| {
        feature.* = .{ .tag = tts.featureTag("aaaa") + @as(u32, @intCast(index)), .first = 0, .last = 0 };
    }
    features[30] = .{ .tag = test_tag, .first = 1, .last = 1 };
    const fits = shape(.{ .gsub = gsub }, &.{ 5, 5 }, .{ .features = features[0..31] });
    try testing.expectEqual(tts.TTS_OK, fits.result);
    try fits.expectGlyphs(&.{ 5, 15 });
    try testing.expectEqual(tts.TTSERR_FEATURES, shape(.{ .gsub = gsub }, &.{ 5, 5 }, .{ .features = &features }).result);
    // Those for the whole run, and those that are off, need no bit.
    for (features[0..30]) |*feature| feature.last = 0xFFFF_FFFF;
    try testing.expectEqual(tts.TTS_OK, shape(.{ .gsub = gsub }, &.{ 5, 5 }, .{ .features = &features }).result);
    for (features[0..30]) |*feature| feature.* = .{ .tag = feature.tag, .value = 0, .first = 0, .last = 0 };
    try testing.expectEqual(tts.TTS_OK, shape(.{ .gsub = gsub }, &.{ 5, 5 }, .{ .features = &features }).result);
}

test "a call that runs out of memory at any block says so and leaves none behind" {
    var doubling: File = .{};
    subtables.multiple(&doubling, &.{5}, &.{&.{ 5, 5 }});
    var lookups: [8]layout.Lookup = undefined;
    for (&lookups) |*lookup| lookup.* = .{ .kind = 2, .subtables = &.{doubling.written()} };
    var gsub: File = .{};
    layout.tableOfOne(&gsub, &lookups);
    var narrow: File = .{};
    subtables.positionAll(&narrow, &.{5}, subtables.X_ADVANCE, &.{-100});
    var gpos: File = .{};
    layout.tableOfOne(&gpos, &.{.{ .kind = 1, .subtables = &.{narrow.written()} }});
    const tables: harness.Tables = .{ .gsub = gsub.written(), .gpos = gpos.written() };

    var failed: u32 = 0;
    var blocks: u32 = 0;
    while (blocks < 64) : (blocks += 1) {
        const run = shape(tables, &.{5}, .{ .blocks = blocks });
        if (run.result == tts.TTS_OK) break;
        try testing.expectEqual(tts.TTSERR_NOMEM, run.result);
        failed += 1;
    }
    // The run, the call's own block, each table's lookups, and the run
    // grown: more than three blocks, and the call ends well with enough.
    try testing.expect(failed > 3);
    try testing.expect(blocks < 64);
    const run = shape(tables, &.{5}, .{});
    try testing.expectEqual(@as(u32, 256), run.count);
    try testing.expectEqual(@as(i32, 900), run.glyphs[255].advance);
}

test "an empty run is shaped to an empty run" {
    var file: File = .{};
    var ten: File = .{};
    const run = shape(.{ .gsub = plusTen(&file, &ten) }, &.{}, .{});
    try testing.expectEqual(tts.TTS_OK, run.result);
    try testing.expectEqual(@as(u32, 0), run.count);
}
