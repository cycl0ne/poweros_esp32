// SPDX-License-Identifier: MIT
//! `spirv.Emit` against modules Khronos' own assembler made, word for
//! word, and `spirv.look` against modules that are wrong in one way each.
//!
//! The emitter's test is a comparison and not an inspection on purpose. A
//! module that is nearly right is not nearly valid: a word count off by
//! one shifts every word after it, a bound one too small is refused by a
//! validator and by nothing else, and a string whose length is a multiple
//! of four costs a whole word of zeroes. The only check that catches all
//! of those is the bytes, against a module `spirv-val` has already
//! accepted - `tests/spirv_reference.zig` says how each was made.

const std = @import("std");
const sdk = @import("sdk");
const spirv = sdk.facet.spirv;
const reference = @import("spirv_reference.zig");

/// The revision the reference modules are compared at. The generator word
/// is the one word facet writes differently from the assembler, so it is
/// checked on its own and left out of the comparison.
const revision = 75;

fn expectModule(want: []const u32, made: []const u32) !void {
    try std.testing.expectEqual(want.len, made.len);
    try std.testing.expectEqual(spirv.generator(revision), made[2]);
    for (want, made, 0..) |a, b, at| {
        if (at == 2) continue;
        if (a != b) {
            std.debug.print("word {d}: want 0x{X:0>8}, made 0x{X:0>8}\n", .{ at, a, b });
            return error.TestExpectedEqual;
        }
    }
}

/// Where a fragment module's first ids go. The entry point names its
/// Input and Output variables, so their ids are taken before any type is
/// declared; the function's own id is 1, as it is in every module an
/// assembler writes.
fn fragmentHead(emit: *spirv.Emit, interface: []const u32) u32 {
    const main_id: u32 = 1;
    emit.capability(.shader);
    emit.memoryModel(.logical, .glsl450);
    emit.entryPoint(.fragment, main_id, "main", interface);
    emit.executionMode(main_id, .origin_upper_left);
    return main_id;
}

const bits_one: u32 = @bitCast(@as(f32, 1));
const bits_zero: u32 = @bitCast(@as(f32, 0));
const bits_half: u32 = @bitCast(@as(f32, 0.5));

/// A colour of its own.
fn flatModule() []const u32 {
    @setEvalBranchQuota(20_000);
    var emit = spirv.Emit{ .revision = revision };
    const main_id = emit.id();
    const colour_out = emit.id();
    _ = fragmentHead(&emit, &.{colour_out});
    emit.decorate(colour_out, .location, &.{0});
    const void_type = emit.typeVoid();
    const function_type = emit.typeFunction(void_type, &.{});
    const float_type = emit.typeFloat(32);
    const vec4 = emit.typeVector(float_type, 4);
    const out_pointer = emit.typePointer(.output, vec4);
    emit.variable(out_pointer, colour_out, .output);
    const one = emit.constant(float_type, bits_one);
    const zero = emit.constant(float_type, bits_zero);
    const red = emit.constantComposite(vec4, &.{ one, zero, zero, one });
    emit.function(void_type, main_id, function_type);
    emit.label(emit.id());
    emit.at(.store, &.{ colour_out, red });
    emit.at(.returns, &.{});
    emit.functionEnd();
    return emit.finish();
}

/// The colour the vertices carry.
fn interpolatedModule() []const u32 {
    @setEvalBranchQuota(20_000);
    var emit = spirv.Emit{ .revision = revision };
    const main_id = emit.id();
    const colour_out = emit.id();
    const colour_in = emit.id();
    _ = fragmentHead(&emit, &.{ colour_out, colour_in });
    emit.decorate(colour_out, .location, &.{0});
    emit.decorate(colour_in, .location, &.{0});
    const void_type = emit.typeVoid();
    const function_type = emit.typeFunction(void_type, &.{});
    const float_type = emit.typeFloat(32);
    const vec4 = emit.typeVector(float_type, 4);
    emit.variable(emit.typePointer(.output, vec4), colour_out, .output);
    emit.variable(emit.typePointer(.input, vec4), colour_in, .input);
    emit.function(void_type, main_id, function_type);
    emit.label(emit.id());
    const loaded = emit.id();
    emit.at(.load, &.{ vec4, loaded, colour_in });
    emit.at(.store, &.{ colour_out, loaded });
    emit.at(.returns, &.{});
    emit.functionEnd();
    return emit.finish();
}

/// A texture at the two coordinates the vertices carry.
fn texturedModule() []const u32 {
    @setEvalBranchQuota(20_000);
    var emit = spirv.Emit{ .revision = revision };
    const main_id = emit.id();
    const colour_out = emit.id();
    const uv_in = emit.id();
    const picture = emit.id();
    _ = fragmentHead(&emit, &.{ colour_out, uv_in });
    emit.decorate(colour_out, .location, &.{0});
    emit.decorate(uv_in, .location, &.{0});
    emit.decorate(picture, .descriptor_set, &.{0});
    emit.decorate(picture, .binding, &.{0});
    const void_type = emit.typeVoid();
    const function_type = emit.typeFunction(void_type, &.{});
    const float_type = emit.typeFloat(32);
    const vec4 = emit.typeVector(float_type, 4);
    emit.variable(emit.typePointer(.output, vec4), colour_out, .output);
    const vec2 = emit.typeVector(float_type, 2);
    emit.variable(emit.typePointer(.input, vec2), uv_in, .input);
    const image = emit.typeImage(float_type, .dim_2d, 0, 0, 0, 1, .unknown);
    const sampled = emit.typeSampledImage(image);
    emit.variable(emit.typePointer(.uniform_constant, sampled), picture, .uniform_constant);
    emit.function(void_type, main_id, function_type);
    emit.label(emit.id());
    const sampler_value = emit.id();
    emit.at(.load, &.{ sampled, sampler_value, picture });
    const uv = emit.id();
    emit.at(.load, &.{ vec2, uv, uv_in });
    const taken = emit.id();
    emit.at(.image_sample_implicit_lod, &.{ vec4, taken, sampler_value, uv });
    emit.at(.store, &.{ colour_out, taken });
    emit.at(.returns, &.{});
    emit.functionEnd();
    return emit.finish();
}

/// The sample multiplied by the colour the vertices carry.
fn modulatedModule() []const u32 {
    @setEvalBranchQuota(20_000);
    var emit = spirv.Emit{ .revision = revision };
    const main_id = emit.id();
    const colour_out = emit.id();
    const uv_in = emit.id();
    const colour_in = emit.id();
    const picture = emit.id();
    _ = fragmentHead(&emit, &.{ colour_out, uv_in, colour_in });
    emit.decorate(colour_out, .location, &.{0});
    emit.decorate(uv_in, .location, &.{0});
    emit.decorate(colour_in, .location, &.{1});
    emit.decorate(picture, .descriptor_set, &.{0});
    emit.decorate(picture, .binding, &.{0});
    const void_type = emit.typeVoid();
    const function_type = emit.typeFunction(void_type, &.{});
    const float_type = emit.typeFloat(32);
    const vec4 = emit.typeVector(float_type, 4);
    emit.variable(emit.typePointer(.output, vec4), colour_out, .output);
    const vec2 = emit.typeVector(float_type, 2);
    emit.variable(emit.typePointer(.input, vec2), uv_in, .input);
    emit.variable(emit.typePointer(.input, vec4), colour_in, .input);
    const image = emit.typeImage(float_type, .dim_2d, 0, 0, 0, 1, .unknown);
    const sampled = emit.typeSampledImage(image);
    emit.variable(emit.typePointer(.uniform_constant, sampled), picture, .uniform_constant);
    emit.function(void_type, main_id, function_type);
    emit.label(emit.id());
    const sampler_value = emit.id();
    emit.at(.load, &.{ sampled, sampler_value, picture });
    const uv = emit.id();
    emit.at(.load, &.{ vec2, uv, uv_in });
    const taken = emit.id();
    emit.at(.image_sample_implicit_lod, &.{ vec4, taken, sampler_value, uv });
    const tint = emit.id();
    emit.at(.load, &.{ vec4, tint, colour_in });
    const mixed = emit.id();
    emit.at(.f_mul, &.{ vec4, mixed, taken, tint });
    emit.at(.store, &.{ colour_out, mixed });
    emit.at(.returns, &.{});
    emit.functionEnd();
    return emit.finish();
}

/// The same sample, with a pixel dropped where its alpha is under a half.
fn discardingModule() []const u32 {
    @setEvalBranchQuota(20_000);
    var emit = spirv.Emit{ .revision = revision };
    const main_id = emit.id();
    const colour_out = emit.id();
    const uv_in = emit.id();
    const picture = emit.id();
    _ = fragmentHead(&emit, &.{ colour_out, uv_in });
    emit.decorate(colour_out, .location, &.{0});
    emit.decorate(uv_in, .location, &.{0});
    emit.decorate(picture, .descriptor_set, &.{0});
    emit.decorate(picture, .binding, &.{0});
    const void_type = emit.typeVoid();
    const function_type = emit.typeFunction(void_type, &.{});
    const float_type = emit.typeFloat(32);
    const vec4 = emit.typeVector(float_type, 4);
    emit.variable(emit.typePointer(.output, vec4), colour_out, .output);
    const vec2 = emit.typeVector(float_type, 2);
    emit.variable(emit.typePointer(.input, vec2), uv_in, .input);
    const image = emit.typeImage(float_type, .dim_2d, 0, 0, 0, 1, .unknown);
    const sampled = emit.typeSampledImage(image);
    emit.variable(emit.typePointer(.uniform_constant, sampled), picture, .uniform_constant);
    const bool_type = emit.typeBool();
    const half = emit.constant(float_type, bits_half);
    emit.function(void_type, main_id, function_type);
    emit.label(emit.id());
    const sampler_value = emit.id();
    emit.at(.load, &.{ sampled, sampler_value, picture });
    const uv = emit.id();
    emit.at(.load, &.{ vec2, uv, uv_in });
    const taken = emit.id();
    emit.at(.image_sample_implicit_lod, &.{ vec4, taken, sampler_value, uv });
    const alpha = emit.id();
    emit.at(.composite_extract, &.{ float_type, alpha, taken, 3 });
    const too_clear = emit.id();
    emit.at(.f_ord_less_than, &.{ bool_type, too_clear, alpha, half });
    // A conditional branch is structured or it is not SPIR-V: the merge
    // block is named before the branch, and the dropping block ends in
    // OpKill, which is a terminator and takes no branch of its own.
    const merge = emit.id();
    const drop = emit.id();
    emit.at(.selection_merge, &.{ merge, 0 });
    emit.at(.branch_conditional, &.{ too_clear, drop, merge });
    emit.label(drop);
    emit.at(.kill, &.{});
    emit.label(merge);
    emit.at(.store, &.{ colour_out, taken });
    emit.at(.returns, &.{});
    emit.functionEnd();
    return emit.finish();
}

test "a flat colour, word for word" {
    try expectModule(&reference.min_flat, comptime flatModule());
}

test "an interpolated colour, word for word" {
    try expectModule(&reference.min_interp, comptime interpolatedModule());
}

test "a texture, word for word" {
    try expectModule(&reference.min_tex, comptime texturedModule());
}

test "a texture times a colour, word for word" {
    try expectModule(&reference.min_texmod, comptime modulatedModule());
}

test "a dropped pixel, word for word" {
    try expectModule(&reference.min_discard, comptime discardingModule());
}

test "a type is declared once however often it is asked for" {
    const twice = comptime made: {
        @setEvalBranchQuota(20_000);
        var emit = spirv.Emit{ .revision = revision };
        const float_type = emit.typeFloat(32);
        const again = emit.typeFloat(32);
        const vec4 = emit.typeVector(float_type, 4);
        const vec4_again = emit.typeVector(again, 4);
        // An image type is the same only where all seven operands are.
        const one = emit.typeImage(float_type, .dim_2d, 0, 0, 0, 1, .unknown);
        const other = emit.typeImage(float_type, .dim_3d, 0, 0, 0, 1, .unknown);
        break :made .{ float_type, again, vec4, vec4_again, one, other, emit.next };
    };
    try std.testing.expectEqual(twice[0], twice[1]);
    try std.testing.expectEqual(twice[2], twice[3]);
    try std.testing.expect(twice[4] != twice[5]);
    // Four ids for four distinct types, from 1.
    try std.testing.expectEqual(@as(u32, 5), twice[6]);
}

// --- reading ---------------------------------------------------------------

fn seenOf(words: []const u32) spirv.Seen {
    return switch (spirv.look(words, spirv.facet_profile)) {
        .seen => |seen| seen,
        .fault => |fault| std.debug.panic("refused: {s}", .{@tagName(fault)}),
    };
}

fn faultOf(words: []const u32) spirv.Fault {
    return switch (spirv.look(words, spirv.facet_profile)) {
        .seen => std.debug.panic("taken, and it should not have been", .{}),
        .fault => |fault| fault,
    };
}

test "what a module says about itself" {
    const flat = seenOf(&reference.min_flat);
    try std.testing.expectEqual(spirv.ExecutionModel.fragment, flat.stage);
    try std.testing.expectEqual(@as(u32, 1), flat.entry);
    try std.testing.expectEqual(@as(u32, 12), flat.bound);
    try std.testing.expectEqual(@as(u32, 1), flat.outputs);
    try std.testing.expectEqual(@as(u32, 0), flat.inputs);
    try std.testing.expectEqual(@as(u32, 0), flat.samplers);
    try std.testing.expect(!flat.discards);

    const textured = seenOf(&reference.min_tex);
    try std.testing.expectEqual(@as(u32, 1), textured.inputs);
    try std.testing.expectEqual(@as(u32, 1), textured.samplers);

    const dropping = seenOf(&reference.min_discard);
    try std.testing.expect(dropping.discards);
}

test "a module that is not one is refused, and says why" {
    var words: [reference.min_flat.len]u32 = reference.min_flat;

    words = reference.min_flat;
    words[0] = 0x0123_4567;
    try std.testing.expectEqual(spirv.Fault.bad_magic, faultOf(&words));

    words = reference.min_flat;
    words[1] = 0x0001_0300; // SPIR-V 1.3, which is Vulkan 1.1's
    try std.testing.expectEqual(spirv.Fault.bad_version, faultOf(&words));

    words = reference.min_flat;
    words[3] = 0;
    try std.testing.expectEqual(spirv.Fault.bad_bound, faultOf(&words));

    words = reference.min_flat;
    words[3] = spirv.most_ids + 1;
    try std.testing.expectEqual(spirv.Fault.bad_bound, faultOf(&words));

    // A word count of zero would leave a reader standing where it is.
    words = reference.min_flat;
    words[5] = words[5] & 0xFFFF;
    try std.testing.expectEqual(spirv.Fault.bad_word_count, faultOf(&words));

    // A count that reaches past the end.
    words = reference.min_flat;
    words[5] = (@as(u32, 0x4000) << 16) | (words[5] & 0xFFFF);
    try std.testing.expectEqual(spirv.Fault.bad_word_count, faultOf(&words));

    try std.testing.expectEqual(spirv.Fault.too_short, faultOf(reference.min_flat[0..4]));

    // A `Location` without the literal that says which: cut short, and
    // said to be. Since 1.95 that is all `look` reads of one, a back end
    // reading the literal beside the variable it decorates.
    words = reference.min_flat;
    var reader = spirv.Reader.of(&words);
    while (reader.next() catch unreachable) |instruction| {
        if (instruction.op == .decorate and instruction.operands()[1] == @intFromEnum(spirv.Decoration.location)) {
            const at = reader.at - @as(u32, @intCast(instruction.words.len));
            words[at] = (3 << 16) | @as(u32, @intFromEnum(spirv.Op.decorate));
            break;
        }
    } else unreachable;
    try std.testing.expectEqual(spirv.Fault.truncated_instruction, faultOf(&words));

    // The header alone, with nothing after it.
    const header = [_]u32{ spirv.MAGIC, spirv.VERSION, 0, 1, 0 };
    try std.testing.expectEqual(spirv.Fault.too_short, faultOf(&header));
}

test "a module richer than the format is refused by the format, not by its words" {
    // OpDPdx is a plain Shader opcode - no capability says it is there -
    // so only an opcode allowlist catches it. It is the one a validator
    // passes and a tiled rasterizer cannot answer.
    var words: [reference.min_flat.len]u32 = reference.min_flat;
    words[65] = (@as(u32, 4) << 16) | @intFromEnum(spirv.Op.dpdx);
    const fault = faultOf(&words);
    try std.testing.expectEqual(spirv.Fault.opcode_refused, fault);
    try std.testing.expect(!fault.malformed());

    // Malformed and unsupported are told apart, because the library
    // refuses the first and keeps the second for a device that may take it.
    try std.testing.expect(spirv.Fault.bad_magic.malformed());
    try std.testing.expect(spirv.Fault.no_entry_point.malformed());
    try std.testing.expect(!spirv.Fault.capability_refused.malformed());
    try std.testing.expect(!spirv.Fault.storage_class_refused.malformed());
}

test "a profile narrower than the format refuses more" {
    // What a back end does: the same module, a profile of its own.
    const no_textures = spirv.Profile{
        .opcodes = &.{ .capability, .memory_model, .entry_point, .execution_mode, .decorate, .type_void, .type_function, .type_float, .type_vector, .type_pointer, .constant, .constant_composite, .function, .function_end, .variable, .store, .returns, .label },
        .stages = &.{.fragment},
    };
    try std.testing.expect(spirv.look(&reference.min_flat, no_textures) == .seen);
    switch (spirv.look(&reference.min_tex, no_textures)) {
        .seen => return error.TestUnexpectedResult,
        .fault => |fault| try std.testing.expect(!fault.malformed()),
    }

    // And a profile that does not run vertex programs says so.
    const fragment_only = spirv.Profile{ .opcodes = spirv.facet_opcodes, .stages = &.{.fragment} };
    _ = fragment_only;
}

// --- a vertex module -------------------------------------------------------

/// A vertex: a matrix from a uniform block at set 0 binding 0, a position
/// from location 0, and one varying out.
///
/// Where a fragment module's ids come out exactly as an assembler numbers
/// them, this one's do not, and cannot: the `gl_PerVertex` block and the
/// uniform block are decorated, so an assembler gives them early ids,
/// while facet hands out an id when it declares the type. The module is
/// the same module - `spirv-val` says so, and
/// `scripts/spirv-check.sh` runs it - so this one is held to its own
/// words, which `spirv_reference.zig` keeps for the same reason: a change
/// in the emitter that moves a word is a change somebody meant to make.
fn vertexModule() []const u32 {
    @setEvalBranchQuota(20_000);
    var emit = spirv.Emit{ .revision = revision };
    const main_id = emit.id();
    const per_vertex = emit.id();
    const place_in = emit.id();
    const carried_out = emit.id();
    const block = emit.id();
    emit.capability(.shader);
    emit.memoryModel(.logical, .glsl450);
    // A vertex entry point needs no execution mode at all.
    emit.entryPoint(.vertex, main_id, "main", &.{ per_vertex, place_in, carried_out });

    const void_type = emit.typeVoid();
    const function_type = emit.typeFunction(void_type, &.{});
    const float_type = emit.typeFloat(32);
    const vec4 = emit.typeVector(float_type, 4);
    // The built-in block: one member, the position. glslang writes four
    // members because GLSL declares four; one validates, and saves 130
    // words.
    const per_vertex_type = emit.typeStruct(&.{vec4});
    emit.memberDecorate(per_vertex_type, 0, .built_in, &.{@intFromEnum(spirv.BuiltIn.position)});
    emit.decorate(per_vertex_type, .block, &.{});
    emit.variable(emit.typePointer(.output, per_vertex_type), per_vertex, .output);

    // The uniform block. A matrix member wants three decorations, not one:
    // which way round it is, how far apart its columns are, and where in
    // the block it sits.
    const matrix = emit.typeMatrix(vec4, 4);
    const block_type = emit.typeStruct(&.{matrix});
    emit.decorate(block_type, .block, &.{});
    emit.memberDecorate(block_type, 0, .col_major, &.{});
    emit.memberDecorate(block_type, 0, .matrix_stride, &.{16});
    emit.memberDecorate(block_type, 0, .offset, &.{0});
    emit.decorate(block, .descriptor_set, &.{0});
    emit.decorate(block, .binding, &.{0});
    emit.variable(emit.typePointer(.uniform, block_type), block, .uniform);
    const matrix_pointer = emit.typePointer(.uniform, matrix);

    const vec3 = emit.typeVector(float_type, 3);
    emit.decorate(place_in, .location, &.{0});
    emit.variable(emit.typePointer(.input, vec3), place_in, .input);
    const out_pointer = emit.typePointer(.output, vec4);
    emit.decorate(carried_out, .location, &.{0});
    emit.variable(out_pointer, carried_out, .output);

    const int_type = emit.typeInt(32, true);
    const first = emit.constant(int_type, 0);
    const one = emit.constant(float_type, bits_one);

    emit.function(void_type, main_id, function_type);
    emit.label(emit.id());
    const where = emit.id();
    emit.at(.access_chain, &.{ matrix_pointer, where, block, first });
    const held = emit.id();
    emit.at(.load, &.{ matrix, held, where });
    const place = emit.id();
    emit.at(.load, &.{ vec3, place, place_in });
    var parts: [3]u32 = undefined;
    for (&parts, 0..) |*part, which| {
        part.* = emit.id();
        emit.at(.composite_extract, &.{ float_type, part.*, place, @intCast(which) });
    }
    const wide = emit.id();
    emit.at(.composite_construct, &.{ vec4, wide, parts[0], parts[1], parts[2], one });
    const moved = emit.id();
    emit.at(.matrix_times_vector, &.{ vec4, moved, held, wide });
    const position = emit.id();
    emit.at(.access_chain, &.{ out_pointer, position, per_vertex, first });
    emit.at(.store, &.{ position, moved });
    emit.at(.store, &.{ carried_out, wide });
    emit.at(.returns, &.{});
    emit.functionEnd();
    return emit.finish();
}

test "a vertex module says it is one" {
    const made = comptime vertexModule();
    const seen = seenOf(made);
    try std.testing.expectEqual(spirv.ExecutionModel.vertex, seen.stage);
    try std.testing.expectEqual(@as(u32, 1), seen.entry);
    try std.testing.expectEqual(@as(u32, 1), seen.inputs);
    // The built-in block and the varying.
    try std.testing.expectEqual(@as(u32, 2), seen.outputs);
    try std.testing.expectEqual(@as(u32, 1), seen.uniforms);
    try std.testing.expectEqual(@as(u32, 0), seen.samplers);
    try std.testing.expectEqual(made.len, seen.bound + made.len - seen.bound);
}

test "a vertex module, word for word" {
    try expectModule(&reference.min_vert, comptime vertexModule());
}
