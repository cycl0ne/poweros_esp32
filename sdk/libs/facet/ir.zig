// SPDX-License-Identifier: MIT
//! A shader written once, for both kinds of device.
//!
//! A fragment function of a program's own is a Zig function
//! (`shader.FragmentFn`), which the cores call and a GPU cannot: the QPUs
//! of the BCM2712 run no program of the library's, so such a pipeline is
//! refused on that device and drawn on the cores. What this file adds is a
//! way to write the same shader so that **both** can have it: the program
//! records it at comptime as a small graph, and two artefacts come out of
//! the one source.
//!
//! | Artefact | What it is | Who reads it |
//! |---|---|---|
//! | `words` | a SPIR-V 1.0 module, in the program's rodata | a device that compiles; `spirv-val` and a desktop driver in the tests |
//! | `function` | a `shader.FragmentFn` | the cores, at the speed of a hand-written one |
//!
//! The cores keep running Zig because their fragment ABI is a batch - one
//! call for up to 64 quads, four pixels of a plane at a time in a
//! `@Vector(4, f32)`, and no branching a pixel - and an interpreter
//! cannot meet that. The graph is walked at **comptime**: `inline for`
//! over the operations leaves no loop behind, every value is a local with
//! a comptime index, and `exact` stays a comptime parameter, so what the
//! compiler is given is the same shape as `shader.smooth`.
//!
//! ```zig
//! const Tinted = ir.Fragment(struct {
//!     pub fn body(b: *ir.Build) void {
//!         const uv = b.input(0, .f32x2);
//!         const colour = b.input(1, .f32x4);
//!         b.color(b.mul(b.sample(0, 0, uv), colour));
//!     }
//! });
//!
//! const entries = [_]shader.Entry{
//!     shader.vertex("tinted", &tintedVertex, 6),
//!     Tinted.entry("tinted"),              // the cores' function
//! };
//! // Tinted.words is the same shader, for a device that compiles.
//! ```
//!
//! **Colours are 0 to 1 here**, which is Vulkan's convention and
//! therefore the words': a module means to a desktop driver what it means
//! to facet. The scaling to a channel of 0 to 255 happens in one place,
//! where the generated function writes its colour. A fixed form's
//! varyings carry a channel already scaled (`shader.channel`), so **a
//! program whose fragment entry is generated does not call
//! `shader.channel` in its vertex function**: it writes 0 to 1 and this
//! does the rest.
//!
//! What this is not: it does not replace the fixed forms
//! (`shader.fixedFragment`). Those keep every pipeline that names one -
//! they are faster, their pictures are what the reference images were
//! drawn with, and they are the oracles a generated function is compared
//! against. This is for the fragment function a program writes itself,
//! which is the one the V3D refuses today.

const std = @import("std");
const facet = @import("facet.zig");
const shader = @import("shader.zig");
const spirv = @import("spirv.zig");
const texture = @import("texture.zig");

/// What goes in the generator word's low half: the revision of
/// facet.library this emitter ships beside. Nothing reads it - a
/// disassembler prints it - so a stale value costs a wrong label and
/// nothing else.
pub const revision: u32 = 75;

/// How many operations a shader holds. A fixed form is four to eight;
/// this is room to be going on with, and a graph over it is a compile
/// error rather than a truncation.
pub const most_ops = 64;

/// What a value is: floats, one to four of them, or the answer to a
/// comparison. There is no integer and no half here yet - a QPU has them,
/// and the cores have them, but nothing in the tree asks.
pub const Kind = enum(u8) {
    f32x1 = 1,
    f32x2 = 2,
    f32x3 = 3,
    f32x4 = 4,
    boolean = 5,

    /// How many floats it holds. A comparison holds none, and answers 1 so
    /// that the one lane it does use has somewhere to go.
    pub fn parts(kind: Kind) u32 {
        return switch (kind) {
            .f32x1, .boolean => 1,
            .f32x2 => 2,
            .f32x3 => 3,
            .f32x4 => 4,
        };
    }

    /// The type a vector of it is in a module.
    fn sameSize(kind: Kind, other: Kind) bool {
        return kind.parts() == other.parts();
    }
};

/// What an operation does.
pub const Tag = enum(u8) {
    /// A varying, as the vertex function wrote it, divided through by w.
    input,
    /// A value of the shader's own.
    constant,
    /// Floats the draw hands over in its push constants
    /// (CmdPushConstants), `at` bytes in. (Since 1.138.)
    push,
    /// A texture read at a coordinate.
    sample,
    multiply,
    add,
    subtract,
    /// A vector times one float.
    scale,
    /// One float out of a value.
    component,
    less_than,
    greater_than,
    /// Drop the pixels a comparison holds.
    discard_if,
    /// The colour, which is where a shader ends.
    color,
};

/// One operation. Plain comptime data: it is not an ABI, and it never
/// leaves the program it is compiled into.
pub const Op = struct {
    tag: Tag,
    kind: Kind = .f32x4,
    /// Which operations it reads, as indices into the graph.
    a: u16 = 0,
    b: u16 = 0,
    /// A location for an input, `set << 16 | binding` for a sample, a
    /// component for a component.
    at: u32 = 0,
    value: [4]f32 = .{ 0, 0, 0, 0 },
    /// How a sample reads its texture. The words say which texture; how it
    /// is filtered is the device's own business, and on the cores it is
    /// this, as a fixed form's is.
    sampling: texture.Sampling = .{},
    /// What a sample adds to the texel it reads, in texels of the level
    /// the sample chose: SPIR-V's `ConstOffset` image operand, applied
    /// after the level is picked and before the addressing wraps or holds
    /// it. Held to `texture.least_texel_offset`..`most_texel_offset`,
    /// which is Vulkan's required range.
    ///
    /// `.{ 0, 0 }` is no offset at all and emits no image operand, so a
    /// graph that does not ask for one is word for word the module it
    /// always was. (Since 1.87.)
    offset: [2]i32 = .{ 0, 0 },
};

/// A varying the shader reads.
pub const Input = struct {
    location: u32,
    kind: Kind,
    /// Which of the varyings its first float is, so that its plane is
    /// `1 + first`.
    first: u32,
};

/// A texture the shader reads.
pub const Sampled = struct {
    set: u32,
    binding: u32,
    sampling: texture.Sampling,
};

/// A member of the shader's one push-constant block: where it is and
/// what it holds.
pub const Push = struct {
    offset: u32,
    kind: Kind,

    /// How many bytes it is.
    pub fn bytes(member: Push) u32 {
        return 4 * member.kind.parts();
    }
};

/// A shader, recorded. Everything here is comptime.
pub const Graph = struct {
    ops: []const Op,
    inputs: []const Input,
    sampled: []const Sampled,
    /// The push-constant block's members, each place it is read at once,
    /// in the order of their offsets.
    pushes: []const Push = &.{},
    /// The floats the vertex function writes past the position, which is
    /// what the entry's word has to say.
    varyings: u32,
    /// Whether it can drop a pixel.
    discards: bool,
};

/// The recorder a shader is written against. Each call puts one operation
/// down and answers where it is, which is the only handle there is: no
/// expression, no precedence, no inference past what an operation says,
/// because a back end that has never heard of Zig has to read this.
pub const Build = struct {
    ops: [most_ops]Op = undefined,
    count: u16 = 0,
    /// The varyings used so far, so that an input knows which plane it is
    /// on.
    varyings: u32 = 0,
    /// The locations declared so far, to hold a shader to declaring them
    /// in order.
    locations: u32 = 0,

    fn put(build: *Build, op: Op) u16 {
        if (build.count == most_ops) @compileError("a shader holds ir.most_ops operations");
        build.ops[build.count] = op;
        build.count += 1;
        return build.count - 1;
    }

    /// A varying, at `location`. The floats of the locations are the
    /// varyings in order, so locations are declared from 0 upwards with
    /// nothing missed: location 0 of two floats and location 1 of four
    /// are varyings 0 and 1, then 2 to 5, which is what a vertex function
    /// writes and what a fixed form of the same shape expects.
    pub fn input(build: *Build, comptime location: u32, comptime kind: Kind) u16 {
        if (kind == .boolean) @compileError("a varying is floats");
        if (location != build.locations) @compileError("locations are declared from 0 upwards, in order");
        build.locations += 1;
        const first = build.varyings;
        build.varyings += kind.parts();
        if (build.varyings > shader.MAX_VARYINGS) @compileError("a shader reads at most shader.MAX_VARYINGS varyings: PhysicalDeviceLimits.max_vertex_output_components and max_fragment_input_components");
        return build.put(.{ .tag = .input, .kind = kind, .at = location, .value = .{ @bitCast(first), 0, 0, 0 } });
    }

    pub fn scalar(build: *Build, comptime value: f32) u16 {
        return build.put(.{ .tag = .constant, .kind = .f32x1, .value = .{ value, 0, 0, 0 } });
    }

    pub fn constant(build: *Build, comptime parts: [4]f32) u16 {
        return build.put(.{ .tag = .constant, .kind = .f32x4, .value = parts });
    }

    /// Floats of the push constants, `offset` bytes in: a member of the
    /// shader's one push-constant block, at that Offset, which the draw
    /// fills with CmdPushConstants. Vulkan lays such a block out by
    /// std430's rules (the Vulkan specification's "Offset and Stride
    /// Assignment"), so a vector of two floats sits at a multiple of 8
    /// and one of three or four at a multiple of 16; and all of it lies
    /// within `shader.MAX_PUSH_CONSTANTS_SIZE`. Two reads of one place
    /// and one width are one member; two members may not overlap.
    /// (Since 1.138.)
    pub fn push(build: *Build, comptime offset: u32, comptime kind: Kind) u16 {
        if (kind == .boolean) @compileError("a push constant is floats");
        const alignment: u32 = switch (kind) {
            .f32x1 => 4,
            .f32x2 => 8,
            else => 16,
        };
        if (offset % alignment != 0) @compileError("a push constant is placed as std430 places it: 4 for a float, 8 for two, 16 for three or four");
        if (offset + 4 * kind.parts() > shader.MAX_PUSH_CONSTANTS_SIZE) @compileError("the push constants are shader.MAX_PUSH_CONSTANTS_SIZE bytes");
        return build.put(.{ .tag = .push, .kind = kind, .at = offset });
    }

    /// A texture, bound at `set` and `binding`, read at `coordinate`. The
    /// coordinate is two floats; the answer is four.
    pub fn sample(build: *Build, comptime set: u32, comptime binding: u32, coordinate: u16) u16 {
        return build.sampleOffsetBy(set, binding, coordinate, .{}, .{ 0, 0 });
    }

    /// The same, saying how the cores are to filter it.
    pub fn sampleBy(build: *Build, comptime set: u32, comptime binding: u32, coordinate: u16, comptime sampling: texture.Sampling) u16 {
        return build.sampleOffsetBy(set, binding, coordinate, sampling, .{ 0, 0 });
    }

    /// The same at a constant offset in texels from the texel the
    /// coordinate falls on: SPIR-V's `ConstOffset`, which every Vulkan 1.0
    /// implementation takes on an `OpImageSample*` - no feature gates it,
    /// which is why `min_texel_offset` and `max_texel_offset` are required
    /// limits. (Since 1.87.)
    pub fn sampleOffset(build: *Build, comptime set: u32, comptime binding: u32, coordinate: u16, comptime offset: [2]i32) u16 {
        return build.sampleOffsetBy(set, binding, coordinate, .{}, offset);
    }

    /// Both at once: the filter the cores fall back on, and the offset.
    pub fn sampleOffsetBy(
        build: *Build,
        comptime set: u32,
        comptime binding: u32,
        coordinate: u16,
        comptime sampling: texture.Sampling,
        comptime offset: [2]i32,
    ) u16 {
        if (build.ops[coordinate].kind != .f32x2) @compileError("a texture is read at two coordinates");
        for (offset) |each| if (each < texture.least_texel_offset or each > texture.most_texel_offset) {
            @compileError("a texel offset is -8 to 7: PhysicalDeviceLimits.min_texel_offset and max_texel_offset");
        };
        return build.put(.{
            .tag = .sample,
            .kind = .f32x4,
            .a = coordinate,
            .at = set << 16 | binding,
            .sampling = sampling,
            .offset = offset,
        });
    }

    fn pair(build: *Build, tag: Tag, a: u16, b: u16) u16 {
        if (!build.ops[a].kind.sameSize(build.ops[b].kind)) @compileError("these two are not the same width");
        return build.put(.{ .tag = tag, .kind = build.ops[a].kind, .a = a, .b = b });
    }

    pub fn mul(build: *Build, a: u16, b: u16) u16 {
        return build.pair(.multiply, a, b);
    }
    pub fn add(build: *Build, a: u16, b: u16) u16 {
        return build.pair(.add, a, b);
    }
    pub fn sub(build: *Build, a: u16, b: u16) u16 {
        return build.pair(.subtract, a, b);
    }

    /// A value times one float.
    pub fn scale(build: *Build, of: u16, by: u16) u16 {
        if (build.ops[by].kind != .f32x1) @compileError("a scale is by one float");
        return build.put(.{ .tag = .scale, .kind = build.ops[of].kind, .a = of, .b = by });
    }

    /// One float of a value: 0 is red or s, 3 is alpha.
    pub fn component(build: *Build, of: u16, comptime which: u32) u16 {
        if (which >= build.ops[of].kind.parts()) @compileError("that value has no such part");
        return build.put(.{ .tag = .component, .kind = .f32x1, .a = of, .at = which });
    }

    pub fn lessThan(build: *Build, a: u16, b: u16) u16 {
        if (build.ops[a].kind != .f32x1 or build.ops[b].kind != .f32x1) @compileError("a comparison is of one float each");
        return build.put(.{ .tag = .less_than, .kind = .boolean, .a = a, .b = b });
    }

    pub fn greaterThan(build: *Build, a: u16, b: u16) u16 {
        if (build.ops[a].kind != .f32x1 or build.ops[b].kind != .f32x1) @compileError("a comparison is of one float each");
        return build.put(.{ .tag = .greater_than, .kind = .boolean, .a = a, .b = b });
    }

    /// Drop the pixels the comparison holds: neither their colour nor
    /// their depth is kept.
    pub fn discardIf(build: *Build, held: u16) void {
        if (build.ops[held].kind != .boolean) @compileError("what is dropped is said by a comparison");
        _ = build.put(.{ .tag = .discard_if, .kind = .boolean, .a = held });
    }

    /// The colour, 0 to 1 a channel. A shader says this once and last.
    pub fn color(build: *Build, value: u16) void {
        if (build.ops[value].kind != .f32x4) @compileError("a colour is four floats");
        _ = build.put(.{ .tag = .color, .kind = .f32x4, .a = value });
    }
};

/// The graph `body` records.
pub fn graphOf(comptime body: fn (*Build) void) Graph {
    comptime {
        var build = Build{};
        body(&build);
        if (build.count == 0) @compileError("a shader does something");
        if (build.ops[build.count - 1].tag != .color) @compileError("a shader ends by saying its colour");

        var inputs: [most_ops]Input = undefined;
        var input_count: u32 = 0;
        var sampled: [most_ops]Sampled = undefined;
        var sampled_count: u32 = 0;
        var discards = false;
        var pushes: [most_ops]Push = undefined;
        var push_count: u32 = 0;
        for (build.ops[0..build.count]) |op| switch (op.tag) {
            .input => {
                inputs[input_count] = .{ .location = op.at, .kind = op.kind, .first = @bitCast(op.value[0]) };
                input_count += 1;
            },
            .push => {
                const member = Push{ .offset = op.at, .kind = op.kind };
                var known = false;
                for (pushes[0..push_count]) |each| {
                    if (each.offset == member.offset and each.kind == member.kind) {
                        known = true;
                    } else if (member.offset < each.offset + each.bytes() and each.offset < member.offset + member.bytes()) {
                        @compileError("two push constants overlap: a block's members may not");
                    }
                }
                if (!known) {
                    // In the order of their offsets, which is the order a
                    // block's members are declared in.
                    var at = push_count;
                    while (at > 0 and pushes[at - 1].offset > member.offset) : (at -= 1) pushes[at] = pushes[at - 1];
                    pushes[at] = member;
                    push_count += 1;
                }
            },
            .sample => {
                sampled[sampled_count] = .{ .set = op.at >> 16, .binding = op.at & 0xFFFF, .sampling = op.sampling };
                sampled_count += 1;
            },
            .discard_if => discards = true,
            else => {},
        };
        const kept_ops = build.ops[0..build.count].*;
        const kept_inputs = inputs[0..input_count].*;
        const kept_sampled = sampled[0..sampled_count].*;
        const kept_pushes = pushes[0..push_count].*;
        return .{
            .ops = &kept_ops,
            .inputs = &kept_inputs,
            .sampled = &kept_sampled,
            .pushes = &kept_pushes,
            .varyings = build.varyings,
            .discards = discards,
        };
    }
}

/// A fragment shader: a declaration type with a `pub fn body`, and the
/// artefacts taken from the one graph it records.
pub fn Fragment(comptime Declare: type) type {
    return struct {
        pub const graph = graphOf(Declare.body);
        /// The module, for a device that compiles.
        pub const words: []const u32 = wordsOf(graph);
        /// The same, for a shader module's table: `shader.Module.spirv`
        /// wants one of these for each entry, in the entries' own order.
        pub const spirv: shader.Spirv = shader.Spirv.of(words);
        /// The function, for the cores.
        pub const function: shader.FragmentFn = functionOf(graph);
        /// The floats the vertex function writes past the position.
        pub const varyings: u32 = graph.varyings;
        /// Whether it drops pixels, which a pipeline's depth has to know.
        pub const discards: bool = graph.discards;

        /// Its entry for a shader module's table: the cores' function, at
        /// `name`, with the varyings the graph reads.
        pub fn entry(comptime name: [*:0]const u8) shader.Entry {
            return shader.fragment(name, function, varyings);
        }
    };
}

// --- the words --------------------------------------------------------------

/// The graph as a SPIR-V module.
///
/// The order is not a matter of taste: the five shapes the V3D already has
/// hand-written QPU programs for come out **word for word** the same as
/// the modules Khronos' own assembler writes for them, which is what the
/// host tests check. So the ids go out in the order an assembler gives
/// them - the function, the colour out, the varyings in, the textures -
/// and the declarations in the order those are reached.
fn wordsOf(comptime graph: Graph) []const u32 {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var emit = spirv.Emit{ .revision = revision };
        const main_id = emit.id();
        const colour_out = emit.id();
        var input_ids: [most_ops]u32 = @splat(0);
        for (graph.inputs, 0..) |_, k| input_ids[k] = emit.id();
        var sampler_ids: [most_ops]u32 = @splat(0);
        for (graph.sampled, 0..) |_, k| sampler_ids[k] = emit.id();
        // The push-constant block's variable, where there is a block:
        // taken last, so that a graph with none is the module it was.
        const push_id: u32 = if (graph.pushes.len == 0) 0 else emit.id();

        emit.capability(.shader);
        emit.memoryModel(.logical, .glsl450);
        var interface: [1 + most_ops]u32 = @splat(0);
        interface[0] = colour_out;
        for (graph.inputs, 0..) |_, k| interface[1 + k] = input_ids[k];
        emit.entryPoint(.fragment, main_id, "main", interface[0 .. 1 + graph.inputs.len]);
        emit.executionMode(main_id, .origin_upper_left);

        emit.decorate(colour_out, .location, &.{0});
        for (graph.inputs, 0..) |each, k| emit.decorate(input_ids[k], .location, &.{each.location});
        for (graph.sampled, 0..) |each, k| {
            emit.decorate(sampler_ids[k], .descriptor_set, &.{each.set});
            emit.decorate(sampler_ids[k], .binding, &.{each.binding});
        }

        const void_type = emit.typeVoid();
        const function_type = emit.typeFunction(void_type, &.{});
        const float_type = emit.typeFloat(32);
        const vec4 = emit.typeVector(float_type, 4);
        emit.variable(emit.typePointer(.output, vec4), colour_out, .output);
        var vector_types: [5]u32 = @splat(0);
        vector_types[4] = vec4;
        for (graph.inputs, 0..) |each, k| {
            // A varying of one float is a float and not a vector of one:
            // SPIR-V has no such vector, and `spirv.Emit.typeVector`
            // refuses to write one.
            const of_type = vectorFor(&emit, &vector_types, float_type, each.kind);
            emit.variable(emit.typePointer(.input, of_type), input_ids[k], .input);
        }
        var sampled_type: u32 = 0;
        for (graph.sampled, 0..) |_, k| {
            if (sampled_type == 0) {
                const image = emit.typeImage(float_type, .dim_2d, 0, 0, 0, 1, .unknown);
                sampled_type = emit.typeSampledImage(image);
            }
            emit.variable(emit.typePointer(.uniform_constant, sampled_type), sampler_ids[k], .uniform_constant);
        }
        var bool_type: u32 = 0;
        for (graph.ops) |op| if (op.kind == .boolean and bool_type == 0) {
            bool_type = emit.typeBool();
        };

        // The push constants: one block, a member for each place read, at
        // its Offset, and a pointer in the PushConstant class for each
        // member's type, which an access chain answers. The chain's index
        // is a 32-bit signed integer constant, as glslc writes it. Lazy,
        // as the offsets below are: a graph without push constants
        // declares none of it.
        var member_pointers: [most_ops]u32 = @splat(0);
        var member_indices: [most_ops]u32 = @splat(0);
        if (graph.pushes.len != 0) {
            var member_types: [most_ops]u32 = @splat(0);
            for (graph.pushes, 0..) |each, k| member_types[k] = vectorFor(&emit, &vector_types, float_type, each.kind);
            const block = emit.typeStruct(member_types[0..graph.pushes.len]);
            emit.decorate(block, .block, &.{});
            for (graph.pushes, 0..) |each, k| emit.memberDecorate(block, k, .offset, &.{each.offset});
            emit.variable(emit.typePointer(.push_constant, block), push_id, .push_constant);
            const int_type = emit.typeInt(32, true);
            for (graph.pushes, 0..) |_, k| {
                member_indices[k] = emit.constant(int_type, k);
                member_pointers[k] = emit.typePointer(.push_constant, member_types[k]);
            }
        }

        // The constants, in the order they are first asked for: each
        // float once, then a composite for a value of several.
        var constant_ids: [most_ops]u32 = @splat(0);
        for (graph.ops, 0..) |op, k| if (op.tag == .constant) {
            const wide = op.kind.parts();
            var parts: [4]u32 = @splat(0);
            for (0..wide) |which| parts[which] = emit.constant(float_type, @bitCast(op.value[which]));
            if (wide == 1) {
                constant_ids[k] = parts[0];
            } else {
                if (vector_types[wide] == 0) vector_types[wide] = emit.typeVector(float_type, wide);
                constant_ids[k] = emit.constantComposite(vector_types[wide], parts[0..wide]);
            }
        };

        // The constant offsets, for the samples that ask for one: a vector
        // of two signed 32-bit integers, which is what `ConstOffset`
        // takes for a 2D image.
        //
        // Lazy in every part. A graph with no offset must allocate no id,
        // because the header's third word is the id bound and the
        // reference modules in tests/ir.zig are held to it word for word
        // - so an eager `typeInt` here would fail all five of them on one
        // word that reads like nothing.
        var offset_ids: [most_ops]u32 = @splat(0);
        var int_type: u32 = 0;
        var offset_type: u32 = 0;
        for (graph.ops, 0..) |op, k| if (op.tag == .sample and (op.offset[0] != 0 or op.offset[1] != 0)) {
            if (int_type == 0) {
                int_type = emit.typeInt(32, true);
                offset_type = emit.typeVector(int_type, 2);
            }
            const parts = [2]u32{
                emit.constant(int_type, @bitCast(op.offset[0])),
                emit.constant(int_type, @bitCast(op.offset[1])),
            };
            offset_ids[k] = emit.constantComposite(offset_type, &parts);
        };

        emit.function(void_type, main_id, function_type);
        emit.label(emit.id());

        // A varying is loaded where it is first read, not where it was
        // declared, because that is where an assembler puts it.
        var value_ids: [most_ops]u32 = @splat(0);
        for (graph.ops, 0..) |op, k| {
            switch (op.tag) {
                .input => {},
                .constant => value_ids[k] = constant_ids[k],
                .push => {
                    // Loaded where it is read, through a chain to its
                    // member, as glslc writes `pc.colour`.
                    const member = pushMember(graph, op);
                    const pointer = emit.id();
                    emit.at(.access_chain, &.{ member_pointers[member], pointer, push_id, member_indices[member] });
                    const made = emit.id();
                    emit.at(.load, &.{ vectorFor(&emit, &vector_types, float_type, op.kind), made, pointer });
                    value_ids[k] = made;
                },
                .sample => {
                    const which = sampledBefore(graph, k);
                    const held = emit.id();
                    emit.at(.load, &.{ sampled_type, held, sampler_ids[which] });
                    const where = loadInput(&emit, graph, &value_ids, &input_ids, &vector_types, float_type, op.a);
                    const taken = emit.id();
                    if (offset_ids[k] == 0) {
                        emit.at(.image_sample_implicit_lod, &.{ vec4, taken, held, where });
                    } else {
                        // One literal mask word, then the id of the
                        // offset: the shape `spirv.look` reads back and
                        // the V3D's profile refuses.
                        emit.at(.image_sample_implicit_lod, &.{ vec4, taken, held, where, @intFromEnum(spirv.ImageOperands.const_offset), offset_ids[k] });
                    }
                    value_ids[k] = taken;
                },
                .multiply, .add, .subtract => {
                    const left = loadInput(&emit, graph, &value_ids, &input_ids, &vector_types, float_type, op.a);
                    const right = loadInput(&emit, graph, &value_ids, &input_ids, &vector_types, float_type, op.b);
                    const made = emit.id();
                    const of_type = vectorFor(&emit, &vector_types, float_type, op.kind);
                    emit.at(switch (op.tag) {
                        .multiply => .f_mul,
                        .add => .f_add,
                        else => .f_sub,
                    }, &.{ of_type, made, left, right });
                    value_ids[k] = made;
                },
                .scale => {
                    const left = loadInput(&emit, graph, &value_ids, &input_ids, &vector_types, float_type, op.a);
                    const right = loadInput(&emit, graph, &value_ids, &input_ids, &vector_types, float_type, op.b);
                    const made = emit.id();
                    emit.at(.vector_times_scalar, &.{ vectorFor(&emit, &vector_types, float_type, op.kind), made, left, right });
                    value_ids[k] = made;
                },
                .component => {
                    const of = loadInput(&emit, graph, &value_ids, &input_ids, &vector_types, float_type, op.a);
                    const made = emit.id();
                    emit.at(.composite_extract, &.{ float_type, made, of, op.at });
                    value_ids[k] = made;
                },
                .less_than, .greater_than => {
                    const left = loadInput(&emit, graph, &value_ids, &input_ids, &vector_types, float_type, op.a);
                    const right = loadInput(&emit, graph, &value_ids, &input_ids, &vector_types, float_type, op.b);
                    const made = emit.id();
                    emit.at(if (op.tag == .less_than) .f_ord_less_than else .f_ord_greater_than, &.{ bool_type, made, left, right });
                    value_ids[k] = made;
                },
                .discard_if => {
                    // Structured or it is not SPIR-V: the block they join
                    // at is named before the branch, and the block that
                    // drops ends in OpKill, which is a terminator of its
                    // own.
                    const merge = emit.id();
                    const drop = emit.id();
                    emit.at(.selection_merge, &.{ merge, 0 });
                    emit.at(.branch_conditional, &.{ value_ids[op.a], drop, merge });
                    emit.label(drop);
                    emit.at(.kill, &.{});
                    emit.label(merge);
                },
                .color => {
                    const value = loadInput(&emit, graph, &value_ids, &input_ids, &vector_types, float_type, op.a);
                    emit.at(.store, &.{ colour_out, value });
                },
            }
        }
        emit.at(.returns, &.{});
        emit.functionEnd();
        return emit.finish();
    }
}

/// Which member of the push-constant block an operation reads.
fn pushMember(comptime graph: Graph, comptime op: Op) u32 {
    comptime {
        for (graph.pushes, 0..) |each, k| if (each.offset == op.at and each.kind == op.kind) return k;
        unreachable;
    }
}

/// How many samples there are before the one at `at`, which is which
/// texture it reads.
fn sampledBefore(comptime graph: Graph, comptime at: usize) u32 {
    comptime {
        var which: u32 = 0;
        for (graph.ops[0..at]) |before| if (before.tag == .sample) {
            which += 1;
        };
        return which;
    }
}

fn vectorFor(comptime emit: *spirv.Emit, comptime vector_types: *[5]u32, comptime float_type: u32, comptime kind: Kind) u32 {
    comptime {
        const wide = kind.parts();
        if (wide == 1) return float_type;
        if (vector_types[wide] == 0) vector_types[wide] = emit.typeVector(float_type, wide);
        return vector_types[wide];
    }
}

/// The id of what operation `at` answers, loading a varying the first time
/// one is read.
fn loadInput(
    comptime emit: *spirv.Emit,
    comptime graph: Graph,
    comptime value_ids: *[most_ops]u32,
    comptime input_ids: *const [most_ops]u32,
    comptime vector_types: *[5]u32,
    comptime float_type: u32,
    comptime at: u16,
) u32 {
    comptime {
        if (value_ids[at] != 0) return value_ids[at];
        const op = graph.ops[at];
        if (op.tag != .input) return value_ids[at];
        var which: u32 = 0;
        for (graph.ops[0..at]) |before| if (before.tag == .input) {
            which += 1;
        };
        const of_type = vectorFor(emit, vector_types, float_type, op.kind);
        const made = emit.id();
        emit.at(.load, &.{ of_type, made, input_ids[which] });
        value_ids[at] = made;
        return made;
    }
}

// --- the function for the cores ---------------------------------------------

/// Four pixels of one channel.
const Pixels = shader.Pixels;

/// A channel of four pixels, 0 to 255, held inside first so that the
/// conversion cannot fail - a NaN as well, which `@min` and `@max` pass
/// over. The same arithmetic as `shader.smooth`'s own, which is what makes
/// a generated colour comparable with a fixed form's.
inline fn bytesOf(at: Pixels) @Vector(4, u32) {
    @setRuntimeSafety(false);
    return @intFromFloat(@min(@max(at * @as(Pixels, @splat(255)) + @as(Pixels, @splat(0.5)), @as(Pixels, @splat(0))), @as(Pixels, @splat(255.5))));
}

/// The graph as a function the cores call, expanded inline over the quad
/// batch. Every index into `values` is comptime, every operation is a
/// `switch` the compiler settles, and the loop over the operations is
/// `inline`: what is left is straight-line vector arithmetic a quad.
fn functionOf(comptime graph: Graph) shader.FragmentFn {
    const made = struct {
        fn run(fragments: *const shader.Fragments) callconv(.c) void {
            if (fragments.exact) quads(true, fragments) else quads(false, fragments);
        }

        inline fn quads(comptime exact: bool, fragments: *const shader.Fragments) void {
            @setRuntimeSafety(false);
            @setEvalBranchQuota(1_000_000);
            const planes = comptime graph.varyings + 1;
            var rows = shader.Rows(planes).of(fragments);
            // The textures, once a call rather than once a quad - and
            // how each is sampled, which comes from the sampler the draw
            // bound and not from the graph.
            //
            // Vulkan puts filtering in the sampler object, and SPIR-V has
            // nowhere to carry what the graph asked for, so a generated
            // shader's sampling is the bound sampler's on whichever
            // device draws it. Where nothing is bound there is no sampler
            // to read and the graph's own answer stands.
            //
            // A sampler `texture.samplingOf` can collapse into a
            // `Sampling` is taken by the fast path, which samples a whole
            // quad at once. One it cannot - mirrored or bordered edges,
            // the levels mixed, a bias or a clamp on them, anisotropy,
            // unnormalized coordinates - is carried whole instead and
            // taken a pixel at a time by `texture.sampleBy`, which is the
            // call the fixed form `shader.texturedBy` makes for the same
            // sampler. **Until 1.83 the texture was dropped here and the
            // pixel painted `shader.missing`**, so a generated pipeline
            // reached by a sampler of any depth drew magenta on purpose;
            // the cores answer for every sampler now, and the V3D's own
            // half of that is item 54 of docs/facet-vulkan10.md.
            var pictures: [@max(graph.sampled.len, 1)]?*const texture.Texture = @splat(null);
            var sampled_how: [@max(graph.sampled.len, 1)]?texture.Sampling = @splat(null);
            var sampled_by: [@max(graph.sampled.len, 1)]?*const texture.Sampler = @splat(null);
            inline for (graph.sampled, 0..) |each, which| {
                pictures[which] = fragments.resources.sampled(each.set, each.binding, 0);
                if (fragments.resources.samplerOf(each.set, each.binding, 0)) |bound| {
                    // No `continue` here: the loop is unrolled and this
                    // is a runtime condition.
                    if (texture.samplingOf(bound, each.sampling.format)) |said| {
                        sampled_how[which] = said;
                    } else {
                        // Whole and untouched, which is the agreement
                        // that matters: one sampler draws one thing on
                        // this device whichever path takes it. A graph's
                        // `sample` is an ordinary sample and carries no
                        // reference, so a sampler with a comparison
                        // compares against 0 here - exactly what
                        // `shader.texturedBy` does when the same sampler
                        // is bound beside a form that is not a shadow
                        // form. Vulkan holds that a sampler made with
                        // `compareEnable` is to be used only by an
                        // `OpImage*Dref*`, so the pairing is the
                        // program's own fault and what it draws is
                        // undefined; drawing what the fixed form draws
                        // is the one answer that keeps the device
                        // consistent with itself.
                        sampled_by[which] = bound;
                    }
                }
            }
            // The push constants as floats, once a call: the draw's, the
            // same for every pixel.
            const pushed: *const [shader.MAX_PUSH_CONSTANTS_SIZE / 4]f32 = @ptrCast(&fragments.resources.push);
            for (0..fragments.count) |k| {
                const quad = &fragments.quads[k];
                const out = &fragments.colors[k];
                const at = rows.at(quad.*);
                const inverse_w = at[0];
                // One divide a quad where w changes slowly enough, put
                // right with a step of Newton's, as `shader.smooth` does;
                // each pixel its own where it does not.
                const w = if (exact) @as(Pixels, @splat(1)) / inverse_w else newton: {
                    const centre: Pixels = @splat(1 / ((inverse_w[0] + inverse_w[3]) * 0.5));
                    break :newton centre + centre * (@as(Pixels, @splat(1)) - inverse_w * centre);
                };
                var values: [graph.ops.len][4]Pixels = undefined;
                var holds: [graph.ops.len]@Vector(4, bool) = undefined;
                inline for (graph.ops, 0..) |op, i| switch (op.tag) {
                    .input => {
                        const first = comptime 1 + inputFirst(graph, i);
                        inline for (0..comptime op.kind.parts()) |part| values[i][part] = at[first + part] * w;
                    },
                    .constant => inline for (0..comptime op.kind.parts()) |part| {
                        values[i][part] = @splat(op.value[part]);
                    },
                    .push => inline for (0..comptime op.kind.parts()) |part| {
                        values[i][part] = @splat(pushed[op.at / 4 + part]);
                    },
                    .sample => {
                        const which = comptime sampledBefore(graph, i);
                        values[i] = if (sampled_by[which]) |whole|
                            sampleThrough(whole, pictures[which], quad.*, values[op.a][0], values[op.a][1], op.offset)
                        else
                            sampleAt(sampled_how[which] orelse op.sampling, pictures[which], quad.*, values[op.a][0], values[op.a][1], op.offset);
                    },
                    .multiply => inline for (0..comptime op.kind.parts()) |part| {
                        values[i][part] = values[op.a][part] * values[op.b][part];
                    },
                    .add => inline for (0..comptime op.kind.parts()) |part| {
                        values[i][part] = values[op.a][part] + values[op.b][part];
                    },
                    .subtract => inline for (0..comptime op.kind.parts()) |part| {
                        values[i][part] = values[op.a][part] - values[op.b][part];
                    },
                    .scale => inline for (0..comptime op.kind.parts()) |part| {
                        values[i][part] = values[op.a][part] * values[op.b][0];
                    },
                    .component => values[i][0] = values[op.a][op.at],
                    .less_than => holds[i] = values[op.a][0] < values[op.b][0],
                    .greater_than => holds[i] = values[op.a][0] > values[op.b][0],
                    .discard_if => inline for (0..4) |pixel| {
                        if (holds[op.a][pixel]) quad.kept &= ~(@as(u8, 1) << @intCast(pixel));
                    },
                    .color => {
                        var bytes: [4]@Vector(4, u32) = undefined;
                        inline for (&bytes, 0..) |*channel, part| channel.* = bytesOf(values[op.a][part]);
                        out.* = bytes[3] << @splat(24) | bytes[0] << @splat(16) | bytes[1] << @splat(8) | bytes[2];
                    },
                };
            }
        }
    };
    return &made.run;
}

/// Which varying an input's first float is.
fn inputFirst(comptime graph: Graph, comptime at: usize) u32 {
    comptime {
        var first: u32 = 0;
        for (graph.ops[0..at]) |before| if (before.tag == .input) {
            first += before.kind.parts();
        };
        return first;
    }
}

/// A texture read at a quad's four coordinates, the level chosen from how
/// fast they change over the quad, as a GPU chooses it. A pixel at a time,
/// the way `shader.textured` reads a texture whose format is not the
/// form's: the fixed forms' fast path is theirs, and a pipeline that wants
/// it names one.
/// A colour as 0xAARRGGBB taken into the four floats of 0 to 1 the graph
/// works in.
///
/// Both the texel a sampler hands back and the `shader.missing` that
/// stands for a sampler with no texture come through here, so the two
/// cannot disagree about which byte is which channel. They did: the
/// missing branch read each channel one place over - alpha where red
/// belonged - and put `channelOfByte`'s half-step on top of it, where
/// the texel's own conversion has neither. Nothing had noticed, because
/// the function this sits in had never compiled.
inline fn channelsOf(colour: u32) [4]f32 {
    var made: [4]f32 = undefined;
    inline for (0..4) |channel| {
        const byte = colour >> @intCast(8 * (if (channel == 3) 3 else 2 - channel)) & 0xFF;
        made[channel] = @as(f32, @floatFromInt(byte)) / 255;
    }
    return made;
}

/// A sample a quad at a time, through what a `Sampling` can say: one
/// filter, one of two wraps, the level chosen from the quad's own steps
/// and read on its own. The fast of the two paths, and the one a sampler
/// `texture.samplingOf` could collapse takes.
inline fn sampleAt(sampling: texture.Sampling, picture: ?*const texture.Texture, quad: shader.Quad, u: Pixels, v: Pixels, comptime offset: [2]i32) [4]Pixels {
    @setRuntimeSafety(false);
    var made: [4]Pixels = @splat(@splat(0));
    const given = picture orelse {
        const colour = channelsOf(shader.missing);
        inline for (0..4) |channel| made[channel] = @splat(colour[channel]);
        return made;
    };
    const texels = [2]f32{ @floatFromInt(given.width(0)), @floatFromInt(given.height(0)) };
    // The offset is not in this: Vulkan picks the level from how fast the
    // coordinates run, and a constant whole-texel shift does not change
    // that. It is applied to the texel of the level this chooses.
    const lod = if (given.levels == 1) 0 else texture.levelFor(given, (u[1] - u[0]) * texels[0], (v[1] - v[0]) * texels[1], (u[2] - u[0]) * texels[0], (v[2] - v[0]) * texels[1]);
    // The condition is runtime and the loop is unrolled, so this is an
    // `if` around the body and not a `continue` out of it: a `continue`
    // here is comptime control flow inside a runtime block, which is a
    // compile error. Nothing had ever instantiated this function - every
    // sampling graph in the tree was asked only for its `.words` - so it
    // sat here uncompiled until a test asked the cores to draw one.
    inline for (0..4) |pixel| {
        if (quad.covered >> @intCast(pixel) & 1 != 0) {
            const colour = channelsOf(given.sampleLayerAt(sampling, 0, lod, u[pixel], v[pixel], offset));
            inline for (0..4) |channel| made[channel][pixel] = colour[channel];
        }
    }
    return made;
}

/// A sample through the whole of a bound sampler, for the one a
/// `Sampling` cannot say: the levels mixed, a bias or a clamp on them,
/// mirrored and bordered edges, anisotropy, unnormalized coordinates.
///
/// `texture.sampleBy` is the call, which is the same call the fixed form
/// `shader.texturedBy` makes with the same sampler - so a generated
/// shader and a fixed form reached by one sampler draw the same thing,
/// which is the agreement that matters here. A pixel at a time and by
/// floats, where the fast path above does a quad at once: that is the
/// cost of the sampler asking for more, and it is paid only by the
/// samples that ask.
///
/// How fast the coordinates change is the quad's own, as a GPU takes it
/// and as `texturedBy` takes it: across from the left pixel to the right,
/// down from the top row to the bottom, 0 to 1 across the texture like
/// the point itself. So a quad's four samples share a level.
inline fn sampleThrough(sampler: *const texture.Sampler, picture: ?*const texture.Texture, quad: shader.Quad, u: Pixels, v: Pixels, comptime offset: [2]i32) [4]Pixels {
    @setRuntimeSafety(false);
    var made: [4]Pixels = @splat(@splat(0));
    const given = picture orelse {
        const colour = channelsOf(shader.missing);
        inline for (0..4) |channel| made[channel] = @splat(colour[channel]);
        return made;
    };
    const du_dx = u[1] - u[0];
    const du_dy = u[2] - u[0];
    const dv_dx = v[1] - v[0];
    const dv_dy = v[2] - v[0];
    inline for (0..4) |pixel| {
        if (quad.covered >> @intCast(pixel) & 1 != 0) {
            const colour = channelsOf(texture.sampleBy(given, sampler, 0, .{
                .u = u[pixel],
                .v = v[pixel],
                .du_dx = du_dx,
                .dv_dx = dv_dx,
                .du_dy = du_dy,
                .dv_dy = dv_dy,
                .offset = offset,
            }));
            inline for (0..4) |channel| made[channel][pixel] = colour[channel];
        }
    }
    return made;
}
