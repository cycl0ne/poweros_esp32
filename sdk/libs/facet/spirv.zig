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
    sampled_image = 86,
    image_sample_implicit_lod = 87,
    image_sample_explicit_lod = 88,
    image_write = 99,
    convert_f_to_s = 110,
    convert_s_to_f = 111,
    bitcast = 124,
    f_negate = 127,
    f_add = 129,
    f_sub = 131,
    f_mul = 133,
    f_div = 136,
    vector_times_scalar = 142,
    matrix_times_vector = 145,
    dot = 148,
    select = 169,
    f_ord_less_than = 184,
    f_ord_greater_than = 186,
    f_ord_greater_than_equal = 190,
    dpdx = 207,
    dpdy = 208,
    fwidth = 209,
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

pub const Capability = enum(u32) { shader = 1, geometry = 2, tessellation = 3, float16 = 9, float64 = 10, int64 = 11, int16 = 22, int8 = 39, derivative_control = 51, variable_pointers = 4442, _ };
pub const AddressingModel = enum(u32) { logical = 0, _ };
pub const MemoryModel = enum(u32) { simple = 0, glsl450 = 1, _ };
pub const ExecutionModel = enum(u32) { vertex = 0, tessellation_control = 1, tessellation_evaluation = 2, geometry = 3, fragment = 4, gl_compute = 5, _ };
pub const ExecutionMode = enum(u32) { origin_upper_left = 7, origin_lower_left = 8, early_fragment_tests = 9, depth_replacing = 12, local_size = 17, _ };
pub const StorageClass = enum(u32) { uniform_constant = 0, input = 1, uniform = 2, output = 3, workgroup = 4, cross_workgroup = 5, private = 6, function = 7, push_constant = 9, _ };
pub const Decoration = enum(u32) { block = 2, row_major = 4, col_major = 5, array_stride = 6, matrix_stride = 7, built_in = 11, no_perspective = 13, flat = 14, location = 30, binding = 33, descriptor_set = 34, offset = 35, _ };
pub const BuiltIn = enum(u32) { position = 0, point_size = 1, clip_distance = 3, cull_distance = 4, frag_depth = 22, _ };
pub const Dim = enum(u32) { dim_1d = 0, dim_2d = 1, dim_3d = 2, cube = 3, _ };
pub const ImageFormat = enum(u32) { unknown = 0, _ };
pub const FunctionControl = enum(u32) { none = 0, _ };
pub const SelectionControl = enum(u32) { none = 0, _ };

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
    pub fn typeVector(emit: *Emit, component: u32, count: u32) u32 {
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
    /// The largest `Location` decorated on an input and on an output, and
    /// one more, so that a back end knows how many varyings are in play.
    input_locations: u32 = 0,
    output_locations: u32 = 0,
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
};

/// The opcodes facet's own format holds: what the SDK's builder emits, and
/// what a reader is prepared to walk. It is deliberately a list and not a
/// range - a module richer than this is not refused by the library, only
/// by a driver that cannot compile it.
pub const facet_opcodes: []const Op = &.{
    .capability,    .memory_model,              .entry_point,       .execution_mode,
    .decorate,      .member_decorate,           .type_void,         .type_bool,
    .type_int,      .type_float,                .type_vector,       .type_matrix,
    .type_image,    .type_sampled_image,        .type_pointer,      .type_struct,
    .type_function, .constant,                  .constant_composite, .function,
    .function_end,  .variable,                  .load,              .store,
    .access_chain,  .composite_construct,       .composite_extract, .vector_shuffle,
    .f_add,         .f_sub,                     .f_mul,             .f_div,
    .f_negate,      .vector_times_scalar,       .matrix_times_vector, .dot,
    .f_ord_less_than, .f_ord_greater_than,      .f_ord_greater_than_equal,
    .select,        .image_sample_implicit_lod, .selection_merge,   .label,
    .branch,        .branch_conditional,        .kill,              .returns,
};

/// The format's own profile, which is what `CreateShaderModule` reads a
/// module against. Everything here is a thing no device facet draws with
/// could run: another capability means another machine, and the opcodes
/// outside the list are the ones a QPU or a tiled rasterizer has no answer
/// for at all.
pub const facet_profile: Profile = .{
    .capabilities = &.{.shader},
    .opcodes = facet_opcodes,
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
                if (which == .location) {
                    if (operands.len < 3) return .{ .fault = .truncated_instruction };
                    // Which side it is on is not known here - a variable's
                    // storage class says that - so both are raised and the
                    // caller reads the one it wants.
                    seen.input_locations = @max(seen.input_locations, operands[2] + 1);
                    seen.output_locations = @max(seen.output_locations, operands[2] + 1);
                }
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
            .kill => seen.discards = true,
            else => {},
        }
    }
    if (entry_points == 0) return .{ .fault = .no_entry_point };
    if (functions == 0) return .{ .fault = .no_function };
    if (seen.stage == .fragment and modes == 0) return .{ .fault = .no_execution_mode };
    return .{ .seen = seen };
}
