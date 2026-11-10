// SPDX-License-Identifier: MIT
//! SPIR-V: the form a shader is shipped in, for a device that compiles it.
//!
//! facet's own shaders are Zig functions (`shader.zig`), which the cores
//! call and no GPU can. A program that wants a device with a processor of
//! its own to run a function of its own ships the same shader as a **real
//! SPIR-V 1.0 module** beside it, the one Vulkan hands a driver: a header
//! of five words, then instructions of `(words << 16) | opcode`.
//!
//! The reason it is Khronos' format and not one of facet's own is that
//! this file can then be checked by somebody else. `spirv-val` says
//! whether a module the emitter built is a module at all; `spirv-dis`
//! reads it back; `glslc` turns any GLSL shader into an input for the
//! reader; Mesa compiles the same words for the same V3D; and a desktop
//! driver draws the same picture to compare with. A private format would
//! have none of that behind it.
//!
//! **This file knows the format and nothing else.** It imports `std`
//! alone - not `ir.zig`, not `shader.zig` - because a back end does not
//! need facet's language in order to compile facet's SPIR-V: it needs the
//! format. That is what lets the V3D's driver module, which is given `sdk`
//! and nothing more, read a module the SDK built.
//!
//! Two halves:
//!
//! - `Emit` builds a module, at **comptime only**: fixed buffers, a
//!   section each, ids handed out in order, and the types that may not be
//!   declared twice held in a table. Nothing on the board emits SPIR-V.
//! - `look` reads one: the header, every instruction's word count, the
//!   entry point, and what the module asks of a device, against a
//!   `Profile`. It answers in two tiers, because the two mean different
//!   things to a program: **malformed** is not a module and is refused by
//!   the library (`error_invalid_shader_nv`), while **unsupported** is a
//!   module this device will not compile and is refused by its driver
//!   (`error_feature_not_present`). The library never refuses words a
//!   later device could run.

const std = @import("std");

/// The first word of every module.
pub const MAGIC: u32 = 0x0723_0203;

/// The version word for SPIR-V 1.0, which is what Vulkan 1.0 takes:
/// `(major << 16) | (minor << 8)`. A 1.3 module (`0x0001_0300`, which is
/// Vulkan 1.1's) offered to a Vulkan 1.0 consumer is refused.
pub const VERSION: u32 = 0x0001_0000;

/// The generator word: the high half a tool id reserved with Khronos, the
/// low half the tool's own version. Tool 0 is the registry's own
/// "Reserved by Khronos", which is the only value a tool that has not
/// reserved one may use - the `unused` range starts at 52 and belongs to
/// whoever reserves it next. The low half is facet's library revision, so
/// a module says which revision built it. Nothing checks this word;
/// `spirv-dis` prints it.
pub fn generator(revision: u32) u32 {
    return revision & 0xFFFF;
}

/// The words of the header, before the first instruction.
pub const header_words = 5;

/// The largest id a module may use, from the specification.
pub const most_ids: u32 = 4194303;

/// The opcodes this file emits or reads. The numbers are the
/// specification's and were read out of modules assembled by `spirv-as`.
pub const Op = enum(u16) {
    nop = 0,
    source = 3,
    source_extension = 4,
    name = 5,
    member_name = 6,
    extension = 10,
    ext_inst_import = 11,
    ext_inst = 12,
    memory_model = 14,
    entry_point = 15,
    execution_mode = 16,
    capability = 17,
    type_void = 19,
    type_bool = 20,
    type_int = 21,
    type_float = 22,
    type_vector = 23,
    type_matrix = 24,
    type_image = 25,
    type_sampler = 26,
    type_sampled_image = 27,
    type_array = 28,
    type_runtime_array = 29,
    type_struct = 30,
    type_pointer = 32,
    type_function = 33,
    constant = 43,
    constant_composite = 44,
    function = 54,
    function_end = 56,
    function_call = 57,
    variable = 59,
    load = 61,
    store = 62,
    access_chain = 65,
    decorate = 71,
    member_decorate = 72,
    vector_shuffle = 79,
    composite_construct = 80,
    composite_extract = 81,
    composite_insert = 82,
    transpose = 84,
    sampled_image = 86,
    image_sample_implicit_lod = 87,
    image_sample_explicit_lod = 88,
    image_sample_dref_implicit_lod = 89,
    image_sample_dref_explicit_lod = 90,
    // A texel of an image of a sampled image at a level: NIR's txf
    // (vtn_handle_texture, spirv_to_nir.c; since 1.182).
    image_fetch = 95,
    image_write = 99,
    // An image of a sampled image, and its size and levels: NIR's txs and
    // query_levels (vtn_handle_texture, spirv_to_nir.c; since 1.181).
    image = 100,
    image_query_size_lod = 103,
    image_query_levels = 106,
    convert_f_to_u = 109,
    convert_f_to_s = 110,
    convert_s_to_f = 111,
    convert_u_to_f = 112,
    bitcast = 124,
    s_negate = 126,
    f_negate = 127,
    i_add = 128,
    f_add = 129,
    i_sub = 130,
    f_sub = 131,
    i_mul = 132,
    f_mul = 133,
    u_div = 134,
    s_div = 135,
    f_div = 136,
    u_mod = 137,
    s_rem = 138,
    s_mod = 139,
    vector_times_scalar = 142,
    matrix_times_scalar = 143,
    vector_times_matrix = 144,
    matrix_times_vector = 145,
    matrix_times_matrix = 146,
    outer_product = 147,
    dot = 148,
    logical_equal = 164,
    logical_not_equal = 165,
    logical_or = 166,
    logical_and = 167,
    logical_not = 168,
    select = 169,
    i_equal = 170,
    i_not_equal = 171,
    u_greater_than = 172,
    s_greater_than = 173,
    u_greater_than_equal = 174,
    s_greater_than_equal = 175,
    u_less_than = 176,
    s_less_than = 177,
    u_less_than_equal = 178,
    s_less_than_equal = 179,
    f_ord_equal = 180,
    f_unord_not_equal = 183,
    f_ord_less_than = 184,
    f_unord_less_than = 185,
    f_ord_greater_than = 186,
    f_unord_greater_than = 187,
    f_ord_less_than_equal = 188,
    f_unord_less_than_equal = 189,
    f_ord_greater_than_equal = 190,
    f_unord_greater_than_equal = 191,
    shift_right_logical = 194,
    shift_right_arithmetic = 195,
    shift_left_logical = 196,
    bitwise_or = 197,
    bitwise_xor = 198,
    bitwise_and = 199,
    not = 200,
    dpdx = 207,
    dpdy = 208,
    fwidth = 209,
    memory_barrier = 225,
    atomic_load = 227,
    atomic_store = 228,
    atomic_exchange = 229,
    atomic_compare_exchange = 230,
    atomic_compare_exchange_weak = 231,
    atomic_i_increment = 232,
    atomic_i_decrement = 233,
    atomic_i_add = 234,
    atomic_i_sub = 235,
    atomic_s_min = 236,
    atomic_u_min = 237,
    atomic_s_max = 238,
    atomic_u_max = 239,
    atomic_and = 240,
    atomic_or = 241,
    atomic_xor = 242,
    phi = 245,
    loop_merge = 246,
    selection_merge = 247,
    label = 248,
    branch = 249,
    branch_conditional = 250,
    switch_on = 251,
    kill = 252,
    returns = 253,
    return_value = 254,
    _,
};

pub const Capability = enum(u32) { shader = 1, geometry = 2, tessellation = 3, float16 = 9, float64 = 10, int64 = 11, int16 = 22, int8 = 39, image_query = 50, derivative_control = 51, variable_pointers = 4442, _ };
pub const AddressingModel = enum(u32) { logical = 0, _ };
pub const MemoryModel = enum(u32) { simple = 0, glsl450 = 1, _ };
pub const ExecutionModel = enum(u32) { vertex = 0, tessellation_control = 1, tessellation_evaluation = 2, geometry = 3, fragment = 4, gl_compute = 5, _ };
pub const ExecutionMode = enum(u32) { origin_upper_left = 7, origin_lower_left = 8, early_fragment_tests = 9, depth_replacing = 12, local_size = 17, _ };
pub const StorageClass = enum(u32) { uniform_constant = 0, input = 1, uniform = 2, output = 3, workgroup = 4, cross_workgroup = 5, private = 6, function = 7, push_constant = 9, _ };
pub const Decoration = enum(u32) { block = 2, buffer_block = 3, row_major = 4, col_major = 5, array_stride = 6, matrix_stride = 7, built_in = 11, no_perspective = 13, flat = 14, non_writable = 24, location = 30, binding = 33, descriptor_set = 34, offset = 35, _ };
pub const BuiltIn = enum(u32) { position = 0, point_size = 1, clip_distance = 3, cull_distance = 4, frag_depth = 22, vertex_index = 42, instance_index = 43, _ };
/// The instructions of the extended set GLSL.std.450, by the numbers its
/// specification gives them (GLSL.std.450.h), which an OpExtInst names.
/// Read out of glslc's modules as well: Normalize 69, FClamp 43, FMix 46,
/// Fract 10, FAbs 4, Sqrt 31, Pow 26, FMax 40, Length 66 (since 1.152).
pub const Glsl = enum(u32) {
    round = 1,
    round_even = 2,
    trunc = 3,
    f_abs = 4,
    s_abs = 5,
    f_sign = 6,
    s_sign = 7,
    floor = 8,
    ceil = 9,
    fract = 10,
    radians = 11,
    degrees = 12,
    sin = 13,
    cos = 14,
    tan = 15,
    asin = 16,
    acos = 17,
    atan = 18,
    sinh = 19,
    cosh = 20,
    tanh = 21,
    asinh = 22,
    acosh = 23,
    atanh = 24,
    atan2 = 25,
    pow = 26,
    exp = 27,
    log = 28,
    exp2 = 29,
    log2 = 30,
    sqrt = 31,
    inverse_sqrt = 32,
    determinant = 33,
    matrix_inverse = 34,
    modf = 35,
    modf_struct = 36,
    f_min = 37,
    u_min = 38,
    s_min = 39,
    f_max = 40,
    u_max = 41,
    s_max = 42,
    f_clamp = 43,
    u_clamp = 44,
    s_clamp = 45,
    f_mix = 46,
    i_mix = 47,
    step = 48,
    smooth_step = 49,
    fma = 50,
    frexp = 51,
    frexp_struct = 52,
    ldexp = 53,
    pack_snorm_4x8 = 54,
    pack_unorm_4x8 = 55,
    pack_snorm_2x16 = 56,
    pack_unorm_2x16 = 57,
    pack_half_2x16 = 58,
    pack_double_2x32 = 59,
    unpack_snorm_2x16 = 60,
    unpack_unorm_2x16 = 61,
    unpack_half_2x16 = 62,
    unpack_snorm_4x8 = 63,
    unpack_unorm_4x8 = 64,
    unpack_double_2x32 = 65,
    length = 66,
    distance = 67,
    cross = 68,
    normalize = 69,
    face_forward = 70,
    reflect = 71,
    refract = 72,
    find_i_lsb = 73,
    find_s_msb = 74,
    find_u_msb = 75,
    interpolate_at_centroid = 76,
    interpolate_at_sample = 77,
    interpolate_at_offset = 78,
    n_min = 79,
    n_max = 80,
    n_clamp = 81,
    _,
};

/// The name a module imports GLSL.std.450 by.
pub const glsl_set = "GLSL.std.450";

pub const Dim = enum(u32) { dim_1d = 0, dim_2d = 1, dim_3d = 2, cube = 3, _ };
pub const ImageFormat = enum(u32) { unknown = 0, _ };
pub const FunctionControl = enum(u32) { none = 0, _ };
pub const SelectionControl = enum(u32) { none = 0, _ };

/// The optional operands an image instruction may carry past its four: one
/// literal word of these bits, and then an id for each bit set, in the
/// order the bits run. (Since 1.87.)
///
/// `const_offset` is the only one facet writes and the only one a profile
/// here takes. It is also the only *offset* that needs no capability,
/// which is why Vulkan requires `minTexelOffset` and `maxTexelOffset` of
/// every implementation unconditionally and the gather pair only with
/// `shaderImageGatherExtended`: `offset`, the one that is not constant,
/// wants ImageGatherExtended.
pub const ImageOperands = enum(u32) {
    bias = 1,
    lod = 2,
    grad = 4,
    const_offset = 8,
    offset = 16,
    const_offsets = 32,
    sample = 64,
    min_lod = 128,
    _,

    /// How many ids follow the mask for this one: `grad` two, the
    /// derivatives along x and along y, and every other one id.
    pub fn ids(operand: ImageOperands) u32 {
        return switch (operand) {
            .grad => 2,
            else => 1,
        };
    }
};

/// How many words a literal string takes: its bytes, a zero, and up to
/// three more to the word. A length that is a multiple of four costs a
/// whole word of zeroes.
pub fn textWords(text: []const u8) u32 {
    return @intCast((text.len + 4) / 4);
}

// --- building a module ------------------------------------------------------

/// How much room each of a module's sections has, in words. A shader of
/// facet's own is far smaller than this; the emitter says so at compile
/// time rather than writing past the end.
pub const most_head = 64;
pub const most_annotations = 256;
pub const most_declarations = 1024;
pub const most_body = 2048;

/// A type or constant already declared, so that it is declared once. The
/// non-aggregate types - void, bool, int, float, vector, matrix, image,
/// sampled image, function - may not be declared twice at all
/// ("Duplicate non-aggregate type declarations are not allowed"), and the
/// rest cost words for nothing.
const Declared = struct {
    op: Op,
    operands: [9]u32 = @splat(0),
    count: u8 = 0,
    id: u32 = 0,
};

/// A module being built, section by section. The sections are kept apart
/// because SPIR-V's logical layout is enforced: capabilities, then the
/// memory model, then entry points and execution modes, then annotations,
/// then types, constants and global variables, then the functions. A
/// decoration emitted after a type is `Decorate is in an invalid layout
/// section`, and the message names the section rather than the mistake.
///
/// Comptime only. Every buffer is a fixed array and every overflow is a
/// `@compileError`, which is the right answer for a shader written into a
/// program: it cannot be handled at run time, and it cannot happen later
/// than the build.
pub const Emit = struct {
    head: [most_head]u32 = undefined,
    head_count: u32 = 0,
    annotations: [most_annotations]u32 = undefined,
    annotation_count: u32 = 0,
    declarations: [most_declarations]u32 = undefined,
    declaration_count: u32 = 0,
    body: [most_body]u32 = undefined,
    body_count: u32 = 0,
    /// The next id to hand out. Ids run from 1, and the header's bound is
    /// one past the largest, which is this.
    next: u32 = 1,
    declared: [128]Declared = undefined,
    declared_count: u32 = 0,
    revision: u32 = 0,

    const Section = enum { head, annotations, declarations, body };

    /// An id nothing has yet. A global's is taken before its type is
    /// declared, because the entry point's interface names it.
    pub fn id(emit: *Emit) u32 {
        const made = emit.next;
        emit.next += 1;
        return made;
    }

    fn put(emit: *Emit, comptime section: Section, value: u32) void {
        switch (section) {
            .head => {
                if (emit.head_count == most_head) @compileError("a module's first section is full: raise spirv.most_head");
                emit.head[emit.head_count] = value;
                emit.head_count += 1;
            },
            .annotations => {
                if (emit.annotation_count == most_annotations) @compileError("a module's decorations are full: raise spirv.most_annotations");
                emit.annotations[emit.annotation_count] = value;
                emit.annotation_count += 1;
            },
            .declarations => {
                if (emit.declaration_count == most_declarations) @compileError("a module's declarations are full: raise spirv.most_declarations");
                emit.declarations[emit.declaration_count] = value;
                emit.declaration_count += 1;
            },
            .body => {
                if (emit.body_count == most_body) @compileError("a shader's body is full: raise spirv.most_body");
                emit.body[emit.body_count] = value;
                emit.body_count += 1;
            },
        }
    }

    fn instruction(emit: *Emit, comptime section: Section, op: Op, operands: []const u32) void {
        emit.put(section, (@as(u32, @intCast(operands.len + 1)) << 16) | @intFromEnum(op));
        for (operands) |operand| emit.put(section, operand);
    }

    fn text(emit: *Emit, comptime section: Section, string: []const u8) void {
        var from: usize = 0;
        while (from < textWords(string) * 4) : (from += 4) {
            var word: u32 = 0;
            for (0..4) |byte| if (from + byte < string.len) {
                word |= @as(u32, string[from + byte]) << @intCast(8 * byte);
            };
            emit.put(section, word);
        }
    }

    // The first section.

    pub fn capability(emit: *Emit, which: Capability) void {
        emit.instruction(.head, .capability, &.{@intFromEnum(which)});
    }

    /// An extended instruction set imported as `which`: after the
    /// capabilities and before the memory model, where the logical layout
    /// has it (since 1.152).
    pub fn extInstImport(emit: *Emit, which: u32, name: []const u8) void {
        emit.put(.head, (@as(u32, 2 + textWords(name)) << 16) | @intFromEnum(Op.ext_inst_import));
        emit.put(.head, which);
        emit.text(.head, name);
    }

    pub fn memoryModel(emit: *Emit, addressing: AddressingModel, memory: MemoryModel) void {
        emit.instruction(.head, .memory_model, &.{ @intFromEnum(addressing), @intFromEnum(memory) });
    }

    /// An entry point and the Input and Output variables it uses. Only
    /// those: a descriptor is reached through its decorations, and naming
    /// one here is an error, while leaving out an interface variable that
    /// is used is also an error.
    pub fn entryPoint(emit: *Emit, model: ExecutionModel, entry: u32, name: []const u8, interface: []const u32) void {
        emit.put(.head, (@as(u32, 3 + textWords(name) + @as(u32, @intCast(interface.len))) << 16) | @intFromEnum(Op.entry_point));
        emit.put(.head, @intFromEnum(model));
        emit.put(.head, entry);
        emit.text(.head, name);
        for (interface) |each| emit.put(.head, each);
    }

    /// A fragment entry point must have one of these; a vertex entry point
    /// needs none at all.
    pub fn executionMode(emit: *Emit, entry: u32, mode: ExecutionMode) void {
        emit.instruction(.head, .execution_mode, &.{ entry, @intFromEnum(mode) });
    }

    // The annotations.

    pub fn decorate(emit: *Emit, target: u32, which: Decoration, literals: []const u32) void {
        emit.put(.annotations, (@as(u32, 3 + @as(u32, @intCast(literals.len))) << 16) | @intFromEnum(Op.decorate));
        emit.put(.annotations, target);
        emit.put(.annotations, @intFromEnum(which));
        for (literals) |literal| emit.put(.annotations, literal);
    }

    pub fn memberDecorate(emit: *Emit, target: u32, member: u32, which: Decoration, literals: []const u32) void {
        emit.put(.annotations, (@as(u32, 4 + @as(u32, @intCast(literals.len))) << 16) | @intFromEnum(Op.member_decorate));
        emit.put(.annotations, target);
        emit.put(.annotations, member);
        emit.put(.annotations, @intFromEnum(which));
        for (literals) |literal| emit.put(.annotations, literal);
    }

    // The declarations: types, constants and global variables, interleaved
    // as they are reached. Each type is declared once, by its operands.

    /// An instruction of the declarations whose result id comes first,
    /// which is every `OpType`: emitted once, and the same operands answer
    /// the same id. `typed` is for the two that name their result *type*
    /// before their result id - a constant and a composite - because the
    /// order of those two words is the order the specification gives and
    /// not a choice.
    fn once(emit: *Emit, op: Op, operands: []const u32) u32 {
        return emit.onceAt(op, false, operands);
    }

    fn onceTyped(emit: *Emit, op: Op, operands: []const u32) u32 {
        return emit.onceAt(op, true, operands);
    }

    fn onceAt(emit: *Emit, op: Op, comptime result_type_first: bool, operands: []const u32) u32 {
        for (emit.declared[0..emit.declared_count]) |each| {
            if (each.op != op or each.count != operands.len) continue;
            var same = true;
            for (operands, 0..) |operand, k| if (each.operands[k] != operand) {
                same = false;
            };
            if (same) return each.id;
        }
        const made = emit.id();
        if (emit.declared_count == emit.declared.len) @compileError("a module holds 128 types and constants");
        var kept = Declared{ .op = op, .count = @intCast(operands.len), .id = made };
        for (operands, 0..) |operand, k| kept.operands[k] = operand;
        emit.declared[emit.declared_count] = kept;
        emit.declared_count += 1;
        // The result id comes first in every one of these.
        emit.put(.declarations, (@as(u32, 2 + @as(u32, @intCast(operands.len))) << 16) | @intFromEnum(op));
        if (result_type_first) {
            emit.put(.declarations, operands[0]);
            emit.put(.declarations, made);
            for (operands[1..]) |operand| emit.put(.declarations, operand);
        } else {
            emit.put(.declarations, made);
            for (operands) |operand| emit.put(.declarations, operand);
        }
        return made;
    }

    pub fn typeVoid(emit: *Emit) u32 {
        return emit.once(.type_void, &.{});
    }
    pub fn typeBool(emit: *Emit) u32 {
        return emit.once(.type_bool, &.{});
    }
    pub fn typeFloat(emit: *Emit, width: u32) u32 {
        return emit.once(.type_float, &.{width});
    }
    pub fn typeInt(emit: *Emit, width: u32, signed: bool) u32 {
        return emit.once(.type_int, &.{ width, @intFromBool(signed) });
    }
    /// A vector is of 2, 3 or 4 components: there is no vector of one,
    /// and a module that declares one is not SPIR-V. A caller with a
    /// width it took from somewhere says `if (wide == 1)` first - or
    /// better, asks for the component type instead.
    pub fn typeVector(emit: *Emit, component: u32, count: u32) u32 {
        if (count < 2 or count > 4) @compileError("a vector is of 2 to 4 components");
        return emit.once(.type_vector, &.{ component, count });
    }
    pub fn typeMatrix(emit: *Emit, column: u32, count: u32) u32 {
        return emit.once(.type_matrix, &.{ column, count });
    }
    /// All seven operands matter to whether two image types are the same.
    pub fn typeImage(emit: *Emit, sampled_type: u32, dim: Dim, depth: u32, arrayed: u32, multisampled: u32, sampled: u32, format: ImageFormat) u32 {
        return emit.once(.type_image, &.{ sampled_type, @intFromEnum(dim), depth, arrayed, multisampled, sampled, @intFromEnum(format) });
    }
    pub fn typeSampledImage(emit: *Emit, image: u32) u32 {
        return emit.once(.type_sampled_image, &.{image});
    }
    pub fn typePointer(emit: *Emit, class: StorageClass, to: u32) u32 {
        return emit.once(.type_pointer, &.{ @intFromEnum(class), to });
    }
    pub fn typeStruct(emit: *Emit, members: []const u32) u32 {
        return emit.once(.type_struct, members);
    }
    /// A struct of its own, never one declared before: a block is one,
    /// decorated as itself, as glslang declares each block (since 1.160).
    pub fn typeStructOwn(emit: *Emit, members: []const u32) u32 {
        const made = emit.id();
        emit.put(.declarations, (@as(u32, 2 + @as(u32, @intCast(members.len))) << 16) | @intFromEnum(Op.type_struct));
        emit.put(.declarations, made);
        for (members) |member| emit.put(.declarations, member);
        return made;
    }
    pub fn typeFunction(emit: *Emit, returns: u32, parameters: []const u32) u32 {
        var operands: [8]u32 = @splat(0);
        operands[0] = returns;
        for (parameters, 0..) |each, k| operands[1 + k] = each;
        return emit.once(.type_function, operands[0 .. 1 + parameters.len]);
    }

    /// A 32-bit constant, by its bits: two constants of the same type and
    /// the same bits are the same constant. `@bitCast` a float into it, so
    /// that a negative zero is not mistaken for a zero.
    pub fn constant(emit: *Emit, of_type: u32, bits: u32) u32 {
        return emit.onceTyped(.constant, &.{ of_type, bits });
    }

    pub fn constantComposite(emit: *Emit, of_type: u32, parts: []const u32) u32 {
        var operands: [8]u32 = @splat(0);
        operands[0] = of_type;
        for (parts, 0..) |each, k| operands[1 + k] = each;
        return emit.onceTyped(.constant_composite, operands[0 .. 1 + parts.len]);
    }

    /// A global variable, whose id was taken earlier because the entry
    /// point's interface names it. `pointer_type` is a pointer to what it
    /// holds, in the same storage class.
    pub fn variable(emit: *Emit, pointer_type: u32, which: u32, class: StorageClass) void {
        emit.instruction(.declarations, .variable, &.{ pointer_type, which, @intFromEnum(class) });
    }

    // The body.

    pub fn function(emit: *Emit, returns: u32, which: u32, kind: u32) void {
        emit.instruction(.body, .function, &.{ returns, which, @intFromEnum(FunctionControl.none), kind });
    }
    pub fn label(emit: *Emit, which: u32) void {
        emit.instruction(.body, .label, &.{which});
    }
    /// Any instruction of the function's body, its operands in the
    /// specification's order. A result id, where there is one, is the
    /// caller's to take from `id` and to pass here.
    pub fn at(emit: *Emit, op: Op, operands: []const u32) void {
        emit.instruction(.body, op, operands);
    }
    pub fn functionEnd(emit: *Emit) void {
        emit.instruction(.body, .function_end, &.{});
    }

    /// The whole module: the header, then the sections in the order the
    /// layout wants them. The bound is one past the largest id handed out,
    /// which a validator checks and nothing else does.
    pub fn finish(emit: *const Emit) []const u32 {
        // The words are a value of the build, not of a run: what is
        // answered here points into one, which at run time would be a
        // pointer to a dead frame.
        if (!@inComptime()) @compileError("a module is built at comptime: call finish in a comptime block");
        const whole = [header_words]u32{ MAGIC, VERSION, generator(emit.revision), emit.next, 0 } ++
            emit.head[0..emit.head_count].* ++
            emit.annotations[0..emit.annotation_count].* ++
            emit.declarations[0..emit.declaration_count].* ++
            emit.body[0..emit.body_count].*;
        return &whole;
    }
};

// --- reading a module -------------------------------------------------------

/// Why a module was turned down. The first group is a module that is not
/// one, which no device could run; the second is one this device will not
/// compile, which another might.
pub const Fault = enum {
    // Malformed.
    too_short,
    bad_magic,
    bad_version,
    bad_bound,
    bad_word_count,
    truncated_instruction,
    id_over_bound,
    no_entry_point,
    several_entry_points,
    no_execution_mode,
    no_function,
    // Unsupported.
    capability_refused,
    opcode_refused,
    type_refused,
    storage_class_refused,
    image_refused,
    stage_refused,
    too_many_ids,
    /// An image operand this device has no answer for: a bias, a lod, a
    /// gradient, a non-constant offset. A constant texel offset is taken
    /// by the library's own profile, because the cores apply one, and
    /// refused by the V3D's. (Since 1.87.)
    image_operand_refused,

    /// Whether this is a module that is not a module, rather than one this
    /// device will not take. The library refuses the first and keeps the
    /// second for a device that may.
    pub fn malformed(fault: Fault) bool {
        return @intFromEnum(fault) <= @intFromEnum(Fault.no_function);
    }
};

/// What a module asks of a device, and what a back end needs before it
/// looks at the body: enough to size its own tables and to refuse early.
pub const Seen = struct {
    stage: ExecutionModel,
    /// The entry point's function id.
    entry: u32,
    /// One past the largest id, as the header says.
    bound: u32,
    /// How many of each kind of global variable.
    inputs: u32 = 0,
    outputs: u32 = 0,
    samplers: u32 = 0,
    uniforms: u32 = 0,
    push_constants: u32 = 0,
    // Which locations are in play is not here, and since 1.95 nothing
    // claims it is: a back end reads each `Location` beside the variable
    // it decorates, as the V3D's does (driver/v3d/compile.zig), and as
    // Mesa's translation does (vtn_variables.c `var_decoration_cb`, then
    // `nir_shader_gather_info`'s `inputs_read` and `outputs_written`).
    /// Whether the body can drop a pixel (`OpKill`), which decides where
    /// a pipeline's depth is written.
    discards: bool = false,
    /// How many instructions the body holds, the terminators among them.
    instructions: u32 = 0,
};

/// What a device will take. The library's own (`facet_profile`) is the
/// format's: it holds only what no facet device could ever run, so that
/// the library never refuses words a later device could. A back end
/// carries its own, narrower, and refuses against it as a pipeline is
/// made.
pub const Profile = struct {
    /// Every capability the module declares has to be here.
    capabilities: []const Capability = &.{.shader},
    /// Every opcode in the module has to be here.
    opcodes: []const Op,
    /// Every global variable's storage class has to be here.
    storage_classes: []const StorageClass = &.{ .input, .output, .uniform_constant, .uniform, .push_constant, .function },
    /// Every image type's dimensionality has to be here.
    image_dims: []const Dim = &.{.dim_2d},
    /// The stages this device runs a program of the module's own for.
    stages: []const ExecutionModel = &.{ .vertex, .fragment },
    /// The optional operands this device takes on an image instruction.
    /// Empty by default, so a profile that says nothing refuses every
    /// one of them - which is what a back end wants, and what the V3D's
    /// profile relies on. (Since 1.87.)
    image_operands: []const ImageOperands = &.{},
    /// How many ids it will make room for.
    most_ids: u32 = 1024,

    pub fn takes(profile: Profile, op: Op) bool {
        for (profile.opcodes) |each| if (each == op) return true;
        return false;
    }
    pub fn takesCapability(profile: Profile, capability: Capability) bool {
        for (profile.capabilities) |each| if (each == capability) return true;
        return false;
    }
    pub fn takesStorage(profile: Profile, class: StorageClass) bool {
        for (profile.storage_classes) |each| if (each == class) return true;
        return false;
    }
    pub fn takesDim(profile: Profile, dim: Dim) bool {
        for (profile.image_dims) |each| if (each == dim) return true;
        return false;
    }
    pub fn takesStage(profile: Profile, stage: ExecutionModel) bool {
        for (profile.stages) |each| if (each == stage) return true;
        return false;
    }
    pub fn takesImageOperand(profile: Profile, operand: ImageOperands) bool {
        for (profile.image_operands) |each| if (each == operand) return true;
        return false;
    }
};

/// The opcodes facet's own format holds: what the SDK's builder emits,
/// what a real toolchain puts around that, and what a reader is prepared
/// to walk. It is deliberately a list and not a range - a module richer
/// than this is not refused by the library, only by a driver that cannot
/// compile it.
///
/// The declarations and annotations at the end carry no computation and
/// are what made every glslc module refused before 1.81: a trivial
/// `ocolor = vcolor;` emits OpExtInstImport, OpSource, OpSourceExtension
/// and OpName around instructions that were all already here, so the
/// module was turned away at its sixth word. `ext_inst_import` is the
/// declaration alone; `ext_inst`, which is the use of an imported set,
/// is here since 1.152, when the V3D began to compile GLSL.std.450's
/// float functions: a call a device cannot run is that device's to
/// refuse, at the pipeline, as every other opcode its profile leaves out
/// is.
pub const facet_opcodes: []const Op = &.{
    .capability,                .memory_model,        .entry_point,              .execution_mode,
    .decorate,                  .member_decorate,     .type_void,                .type_bool,
    .type_int,                  .type_float,          .type_vector,              .type_matrix,
    .type_image,                .type_sampled_image,  .type_pointer,             .type_struct,
    .type_function,             .constant,            .constant_composite,       .function,
    .function_end,              .variable,            .load,                     .store,
    .access_chain,              .composite_construct, .composite_extract,        .vector_shuffle,
    .f_add,                     .f_sub,               .f_mul,                    .f_div,
    .f_negate,                  .vector_times_scalar, .matrix_times_vector,      .dot,
    .f_ord_less_than,           .f_ord_greater_than,  .f_ord_greater_than_equal, .select,
    .image_sample_implicit_lod, .selection_merge,     .label,                    .branch,
    // The last, a depth compared with a reference: a shadow sample (since
    // 1.143).
    .branch_conditional,        .kill,                .returns,                  .image_sample_dref_implicit_lod,
    // Declarations and annotations, which say nothing a device runs.
    .ext_inst_import,           .source,              .source_extension,         .name,
    // .member_name, then a call into an imported set (since 1.152) and
    // the comparisons glslc writes for ==, != and <= (since 1.153), then
    // a value chosen at a selection's merge, and one float of a vector
    // replaced, as glslc writes an if and else (since 1.154); then bools
    // of bools and the unordered comparisons, as glslc writes &&, || and
    // ! (since 1.157).
    .member_name,               .ext_inst,            .f_ord_equal,              .f_unord_not_equal,
    .f_ord_less_than_equal,     .phi,                 .composite_insert,         .logical_and,
    .logical_or,                .f_unord_less_than,   .f_unord_less_than_equal,  .f_unord_greater_than_equal,
    .f_unord_greater_than,      .logical_not,
    // Arrays in a block, and the matrix arithmetic SPIR-V has: what
    // vtn_handle_matrix_alu and OpOuterProduct lower to columns of vector
    // arithmetic (vtn_alu.c:182-237, :817-823; since 1.161).
            .type_array,               .transpose,
    .matrix_times_scalar,       .vector_times_matrix, .matrix_times_matrix,      .outer_product,
};

/// The format's own profile, which is what `CreateShaderModule` reads a
/// module against. Everything here is a thing no device facet draws with
/// could run: another capability means another machine, and the opcodes
/// outside the list are the ones a QPU or a tiled rasterizer has no answer
/// for at all.
pub const facet_profile: Profile = .{
    .capabilities = &.{.shader},
    .opcodes = facet_opcodes,
    // A constant texel offset, which the cores apply (`ir.Op.offset`,
    // since 1.87) and the V3D puts in P2 (since 1.180). Every other image
    // operand is outside facet's own format; a module asking for one is
    // kept for a device that takes it, and the V3D's profile takes a bias
    // and a level.
    .image_operands = &.{.const_offset},
    .most_ids = 1024,
};

/// One instruction of a module.
pub const Instruction = struct {
    op: Op,
    /// Its words, the first one among them.
    words: []const u32,

    /// Its operands: the words past the opcode.
    pub fn operands(instruction: Instruction) []const u32 {
        return instruction.words[1..];
    }
};

/// A walk over a module's instructions. It checks each word count against
/// what is left, so a reader cannot be walked off the end by a module.
pub const Reader = struct {
    words: []const u32,
    at: u32 = header_words,

    pub fn of(words: []const u32) Reader {
        return .{ .words = words };
    }

    /// The next instruction, or null at the end. A word count of 0, or one
    /// that reaches past the end, answers `error.Malformed`.
    pub fn next(reader: *Reader) error{Malformed}!?Instruction {
        if (reader.at == reader.words.len) return null;
        if (reader.at > reader.words.len) return error.Malformed;
        const first = reader.words[reader.at];
        const count = first >> 16;
        if (count == 0) return error.Malformed;
        if (reader.at + count > reader.words.len) return error.Malformed;
        const made = Instruction{
            .op = @enumFromInt(@as(u16, @truncate(first))),
            .words = reader.words[reader.at .. reader.at + count],
        };
        reader.at += count;
        return made;
    }
};

/// What `look` answers: what the module is, or why not.
pub const Outcome = union(enum) {
    seen: Seen,
    fault: Fault,
};

/// A module read against `profile`: its header, every instruction's word
/// count, its one entry point, and what it asks for. Nothing here follows
/// a pointer out of `words`, and nothing allocates: a caller may read a
/// module that came from a program without trusting it.
pub fn look(words: []const u32, profile: Profile) Outcome {
    if (words.len < header_words + 1) return .{ .fault = .too_short };
    if (words[0] != MAGIC) return .{ .fault = .bad_magic };
    if (words[1] != VERSION) return .{ .fault = .bad_version };
    const bound = words[3];
    if (bound == 0 or bound > most_ids) return .{ .fault = .bad_bound };
    if (bound > profile.most_ids) return .{ .fault = .too_many_ids };

    var seen = Seen{ .stage = .fragment, .entry = 0, .bound = bound };
    var entry_points: u32 = 0;
    var modes: u32 = 0;
    var functions: u32 = 0;
    // The ids of the pointer types declared, with the storage class each
    // points into, so that a variable's class is known from its type as
    // well as from its own operand.
    var reader = Reader.of(words);
    while (reader.next() catch return .{ .fault = .bad_word_count }) |instruction| {
        seen.instructions += 1;
        const operands = instruction.operands();
        // Every opcode the module uses has to be one this device knows.
        if (!profile.takes(instruction.op)) return .{ .fault = .opcode_refused };
        // A result id past the bound is the mistake a wrong bound makes,
        // and the one a validator finds first.
        switch (instruction.op) {
            .capability => {
                if (operands.len < 1) return .{ .fault = .truncated_instruction };
                const which: Capability = @enumFromInt(operands[0]);
                if (!profile.takesCapability(which)) return .{ .fault = .capability_refused };
            },
            .entry_point => {
                if (operands.len < 3) return .{ .fault = .truncated_instruction };
                entry_points += 1;
                if (entry_points > 1) return .{ .fault = .several_entry_points };
                seen.stage = @enumFromInt(operands[0]);
                seen.entry = operands[1];
                if (seen.entry >= bound) return .{ .fault = .id_over_bound };
                if (!profile.takesStage(seen.stage)) return .{ .fault = .stage_refused };
            },
            .execution_mode => {
                if (operands.len < 2) return .{ .fault = .truncated_instruction };
                modes += 1;
            },
            .decorate => {
                if (operands.len < 2) return .{ .fault = .truncated_instruction };
                if (operands[0] >= bound) return .{ .fault = .id_over_bound };
                const which: Decoration = @enumFromInt(operands[1]);
                // A location is a literal after the two, and a decoration
                // without it is cut short.
                if (which == .location and operands.len < 3) return .{ .fault = .truncated_instruction };
            },
            .type_image => {
                if (operands.len < 8) return .{ .fault = .truncated_instruction };
                // Result, SampledType, Dim, Depth, Arrayed, MS, Sampled,
                // ImageFormat: the dimensionality is the third operand,
                // not the second.
                const dim: Dim = @enumFromInt(operands[2]);
                if (!profile.takesDim(dim)) return .{ .fault = .image_refused };
                // Sampled must be 1 or 2 under Vulkan, and only 1 is a
                // texture a shader reads through a sampler.
                if (operands[6] != 1) return .{ .fault = .image_refused };
                if (@as(ImageFormat, @enumFromInt(operands[7])) != .unknown) return .{ .fault = .image_refused };
            },
            .type_float => {
                if (operands.len < 2) return .{ .fault = .truncated_instruction };
                if (operands[1] != 32) return .{ .fault = .type_refused };
            },
            .type_int => {
                if (operands.len < 3) return .{ .fault = .truncated_instruction };
                if (operands[1] != 32) return .{ .fault = .type_refused };
            },
            .type_pointer => {
                if (operands.len < 3) return .{ .fault = .truncated_instruction };
                const class: StorageClass = @enumFromInt(operands[1]);
                if (!profile.takesStorage(class)) return .{ .fault = .storage_class_refused };
            },
            .variable => {
                if (operands.len < 3) return .{ .fault = .truncated_instruction };
                const class: StorageClass = @enumFromInt(operands[2]);
                if (!profile.takesStorage(class)) return .{ .fault = .storage_class_refused };
                switch (class) {
                    .input => seen.inputs += 1,
                    .output => seen.outputs += 1,
                    .uniform_constant => seen.samplers += 1,
                    .uniform => seen.uniforms += 1,
                    .push_constant => seen.push_constants += 1,
                    else => {},
                }
            },
            .function => {
                if (operands.len < 4) return .{ .fault = .truncated_instruction };
                functions += 1;
            },
            // The four an OpImageSample* must have - ResultType, Result,
            // SampledImage, Coordinate - and then the optional operands:
            // one literal mask word and an id for each bit set. Until
            // 1.87 none of this was read anywhere in the tree, so a
            // module asking for a bias, a lod or an offset walked
            // through `look` untouched and was sampled without it.
            //
            // A Dref sample has a fifth before the optional ones, the
            // reference it compares with (since 1.143). An explicit
            // level's sample must carry its Lod or Grad, so its mask is
            // no option there (since 1.180). A fetch has the same four as
            // a sample, its Image where a sample's SampledImage is, and
            // its mask optional (since 1.182).
            .image_sample_implicit_lod, .image_sample_dref_implicit_lod, .image_sample_explicit_lod, .image_sample_dref_explicit_lod, .image_fetch => {
                const dref = instruction.op == .image_sample_dref_implicit_lod or instruction.op == .image_sample_dref_explicit_lod;
                const explicit = instruction.op == .image_sample_explicit_lod or instruction.op == .image_sample_dref_explicit_lod;
                const fixed: u32 = if (dref) 5 else 4;
                if (operands.len < fixed + @intFromBool(explicit)) return .{ .fault = .truncated_instruction };
                if (operands.len > fixed) {
                    var mask = operands[fixed];
                    var ids: u32 = 0;
                    while (mask != 0) {
                        // The lowest bit set, and then that bit cleared.
                        const bit = mask & ~(mask -% 1);
                        mask &= mask -% 1;
                        const which: ImageOperands = @enumFromInt(bit);
                        if (!profile.takesImageOperand(which)) return .{ .fault = .image_operand_refused };
                        ids += which.ids();
                    }
                    // One id for each bit, no more and no fewer: a mask
                    // whose ids are missing is a truncated instruction
                    // and not an operand this device refuses.
                    if (operands.len != fixed + 1 + ids) return .{ .fault = .truncated_instruction };
                    for (operands[fixed + 1 ..]) |id| if (id >= bound) return .{ .fault = .id_over_bound };
                }
            },
            .kill => seen.discards = true,
            else => {},
        }
    }
    if (entry_points == 0) return .{ .fault = .no_entry_point };
    if (functions == 0) return .{ .fault = .no_function };
    if (seen.stage == .fragment and modes == 0) return .{ .fault = .no_execution_mode };
    return .{ .seen = seen };
}
