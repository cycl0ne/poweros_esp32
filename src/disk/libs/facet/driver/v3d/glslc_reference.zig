// SPDX-License-Identifier: MIT
//! Modules a real toolchain produced, to compile against: `glslc`'s own
//! output for shaders whose facet forms `tests/spirv_reference.zig`
//! keeps: the interpolated colour, the colour tinted by the push
//! constants (since 1.138), the texture whose pixel is dropped where
//! its alpha is under a half (since 1.139), a shadow sample (since
//! 1.143), float arithmetic through GLSL.std.450 (since 1.152), and
//! floats chosen by comparisons beside the rest of its float functions
//! (since 1.153), and selections whose arms Mesa flattens (since 1.154).
//!
//! They are here rather than beside the other reference modules because a
//! Zig module cannot import a file above its own root, and these are read
//! by `compile.zig`'s tests, which are the V3D module's. The other arrays
//! are read by the library's tests instead. `scripts/spirv-check.sh` hands
//! these to `spirv-val` with the rest, so the claim that they are valid
//! Vulkan 1.0 modules is checked rather than remembered.

/// glslc's own output for the interpolated colour: the same shader as
/// `min_interp`, compiled by a real toolchain instead of written by hand.
///
/// ```sh
/// # interp.frag: #version 450, in vec4 vcolor at 0, out vec4 ocolor at 0,
/// # void main() { ocolor = vcolor; }
/// glslc -fshader-stage=frag interp.frag -o interp.spv   # 111 words
/// spirv-val --target-env vulkan1.0 interp.spv           # no output, and 0
/// ```
///
/// It is 111 words against `min_interp`'s 72, and every extra word is
/// something glslang likes to put there rather than something a device
/// needs: `OpExtInstImport "GLSL.std.450"` that nothing calls into, the
/// debug names, the source strings, and a `Function` variable the colour
/// goes through. Before 1.81 facet refused it at its sixth word.
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 13
/// ; Schema: 0
/// OpCapability Shader
/// %1 = OpExtInstImport "GLSL.std.450"
/// OpMemoryModel Logical GLSL450
/// OpEntryPoint Fragment %4 "main" %9 %11
/// OpExecutionMode %4 OriginUpperLeft
/// OpSource GLSL 450
/// OpSourceExtension "GL_GOOGLE_cpp_style_line_directive"
/// OpSourceExtension "GL_GOOGLE_include_directive"
/// OpName %4 "main"
/// OpName %9 "ocolor"
/// OpName %11 "vcolor"
/// OpDecorate %9 Location 0
/// OpDecorate %11 Location 0
/// %2 = OpTypeVoid
/// %3 = OpTypeFunction %2
/// %6 = OpTypeFloat 32
/// %7 = OpTypeVector %6 4
/// %8 = OpTypePointer Output %7
/// %9 = OpVariable %8 Output
/// %10 = OpTypePointer Input %7
/// %11 = OpVariable %10 Input
/// %4 = OpFunction %2 None %3
/// %5 = OpLabel
/// %12 = OpLoad %7 %11
/// OpStore %9 %12
/// OpReturn
/// OpFunctionEnd
/// ```
pub const glslc_interp = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x0000000D, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x00000009, 0x0000000B, 0x00030010,
    0x00000004, 0x00000007, 0x00030003, 0x00000002, 0x000001C2, 0x000A0004,
    0x475F4C47, 0x4C474F4F, 0x70635F45, 0x74735F70, 0x5F656C79, 0x656E696C,
    0x7269645F, 0x69746365, 0x00006576, 0x00080004, 0x475F4C47, 0x4C474F4F,
    0x6E695F45, 0x64756C63, 0x69645F65, 0x74636572, 0x00657669, 0x00040005,
    0x00000004, 0x6E69616D, 0x00000000, 0x00040005, 0x00000009, 0x6C6F636F,
    0x0000726F, 0x00040005, 0x0000000B, 0x6C6F6376, 0x0000726F, 0x00040047,
    0x00000009, 0x0000001E, 0x00000000, 0x00040047, 0x0000000B, 0x0000001E,
    0x00000000, 0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002,
    0x00030016, 0x00000006, 0x00000020, 0x00040017, 0x00000007, 0x00000006,
    0x00000004, 0x00040020, 0x00000008, 0x00000003, 0x00000007, 0x0004003B,
    0x00000008, 0x00000009, 0x00000003, 0x00040020, 0x0000000A, 0x00000001,
    0x00000007, 0x0004003B, 0x0000000A, 0x0000000B, 0x00000001, 0x00050036,
    0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200F8, 0x00000005,
    0x0004003D, 0x00000007, 0x0000000C, 0x0000000B, 0x0003003E, 0x00000009,
    0x0000000C, 0x000100FD, 0x00010038,
};

/// glslc's output for a colour tinted by the push constants: the varying
/// colour times a float of them, plus a vector of them. It is what
/// `compile.zig`'s Tinted is, written by a real toolchain, and the one
/// module here that declares a block, an integer and an access chain.
///
/// ```sh
/// # tinted.frag: #version 450, in vec4 vcolor at 0, out vec4 ocolor at 0,
/// # layout(push_constant) uniform P { vec4 tint; float light; } pc;
/// # void main() { ocolor = vcolor * pc.light + pc.tint; }
/// glslc -fshader-stage=frag tinted.frag -o tinted.spv   # 200 words
/// spirv-val --target-env vulkan1.0 tinted.spv           # no output, and 0
/// ```
///
/// glslang indexes the block with signed integers, reads the float before
/// the vector, and declares each member's pointer type as it is first
/// wanted, between the constants (since 1.138).
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 27
/// ; Schema: 0
/// OpCapability Shader
/// %1 = OpExtInstImport "GLSL.std.450"
/// OpMemoryModel Logical GLSL450
/// OpEntryPoint Fragment %4 "main" %9 %11
/// OpExecutionMode %4 OriginUpperLeft
/// OpSource GLSL 450
/// OpSourceExtension "GL_GOOGLE_cpp_style_line_directive"
/// OpSourceExtension "GL_GOOGLE_include_directive"
/// OpName %4 "main"
/// OpName %9 "ocolor"
/// OpName %11 "vcolor"
/// OpName %13 "P"
/// OpMemberName %13 0 "tint"
/// OpMemberName %13 1 "light"
/// OpName %15 "pc"
/// OpDecorate %9 Location 0
/// OpDecorate %11 Location 0
/// OpDecorate %13 Block
/// OpMemberDecorate %13 0 Offset 0
/// OpMemberDecorate %13 1 Offset 16
/// %2 = OpTypeVoid
/// %3 = OpTypeFunction %2
/// %6 = OpTypeFloat 32
/// %7 = OpTypeVector %6 4
/// %8 = OpTypePointer Output %7
/// %9 = OpVariable %8 Output
/// %10 = OpTypePointer Input %7
/// %11 = OpVariable %10 Input
/// %13 = OpTypeStruct %7 %6
/// %14 = OpTypePointer PushConstant %13
/// %15 = OpVariable %14 PushConstant
/// %16 = OpTypeInt 32 1
/// %17 = OpConstant %16 1
/// %18 = OpTypePointer PushConstant %6
/// %22 = OpConstant %16 0
/// %23 = OpTypePointer PushConstant %7
/// %4 = OpFunction %2 None %3
/// %5 = OpLabel
/// %12 = OpLoad %7 %11
/// %19 = OpAccessChain %18 %15 %17
/// %20 = OpLoad %6 %19
/// %21 = OpVectorTimesScalar %7 %12 %20
/// %24 = OpAccessChain %23 %15 %22
/// %25 = OpLoad %7 %24
/// %26 = OpFAdd %7 %21 %25
/// OpStore %9 %26
/// OpReturn
/// OpFunctionEnd
/// ```
pub const glslc_tinted = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x0000001B, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x00000009, 0x0000000B, 0x00030010,
    0x00000004, 0x00000007, 0x00030003, 0x00000002, 0x000001C2, 0x000A0004,
    0x475F4C47, 0x4C474F4F, 0x70635F45, 0x74735F70, 0x5F656C79, 0x656E696C,
    0x7269645F, 0x69746365, 0x00006576, 0x00080004, 0x475F4C47, 0x4C474F4F,
    0x6E695F45, 0x64756C63, 0x69645F65, 0x74636572, 0x00657669, 0x00040005,
    0x00000004, 0x6E69616D, 0x00000000, 0x00040005, 0x00000009, 0x6C6F636F,
    0x0000726F, 0x00040005, 0x0000000B, 0x6C6F6376, 0x0000726F, 0x00030005,
    0x0000000D, 0x00000050, 0x00050006, 0x0000000D, 0x00000000, 0x746E6974,
    0x00000000, 0x00050006, 0x0000000D, 0x00000001, 0x6867696C, 0x00000074,
    0x00030005, 0x0000000F, 0x00006370, 0x00040047, 0x00000009, 0x0000001E,
    0x00000000, 0x00040047, 0x0000000B, 0x0000001E, 0x00000000, 0x00030047,
    0x0000000D, 0x00000002, 0x00050048, 0x0000000D, 0x00000000, 0x00000023,
    0x00000000, 0x00050048, 0x0000000D, 0x00000001, 0x00000023, 0x00000010,
    0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002, 0x00030016,
    0x00000006, 0x00000020, 0x00040017, 0x00000007, 0x00000006, 0x00000004,
    0x00040020, 0x00000008, 0x00000003, 0x00000007, 0x0004003B, 0x00000008,
    0x00000009, 0x00000003, 0x00040020, 0x0000000A, 0x00000001, 0x00000007,
    0x0004003B, 0x0000000A, 0x0000000B, 0x00000001, 0x0004001E, 0x0000000D,
    0x00000007, 0x00000006, 0x00040020, 0x0000000E, 0x00000009, 0x0000000D,
    0x0004003B, 0x0000000E, 0x0000000F, 0x00000009, 0x00040015, 0x00000010,
    0x00000020, 0x00000001, 0x0004002B, 0x00000010, 0x00000011, 0x00000001,
    0x00040020, 0x00000012, 0x00000009, 0x00000006, 0x0004002B, 0x00000010,
    0x00000016, 0x00000000, 0x00040020, 0x00000017, 0x00000009, 0x00000007,
    0x00050036, 0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200F8,
    0x00000005, 0x0004003D, 0x00000007, 0x0000000C, 0x0000000B, 0x00050041,
    0x00000012, 0x00000013, 0x0000000F, 0x00000011, 0x0004003D, 0x00000006,
    0x00000014, 0x00000013, 0x0005008E, 0x00000007, 0x00000015, 0x0000000C,
    0x00000014, 0x00050041, 0x00000017, 0x00000018, 0x0000000F, 0x00000016,
    0x0004003D, 0x00000007, 0x00000019, 0x00000018, 0x00050081, 0x00000007,
    0x0000001A, 0x00000015, 0x00000019, 0x0003003E, 0x00000009, 0x0000001A,
    0x000100FD, 0x00010038,
};

/// glslc's output for a texture whose pixel is dropped where its alpha is
/// under a half: what `compile.zig`'s Cutout is, written by a real
/// toolchain (since 1.139).
///
/// ```sh
/// # cutout.frag: #version 450, in vec2 uv at 0, out vec4 ocolor at 0,
/// # a sampler2D at set 0 binding 0; void main() { vec4 texel =
/// # texture(tex, uv); if (texel.a < 0.5) discard; ocolor = texel; }
/// glslc -O -fshader-stage=frag cutout.frag -o cutout.spv   # 147 words
/// spirv-val --target-env vulkan1.0 cutout.spv              # no output, and 0
/// ```
///
/// With `-O`: without it glslang keeps `texel` in a variable of the
/// function's own and reads the alpha through an access chain into it,
/// which the walk makes values as Mesa does since 1.155
/// (`glslc_cutout_unoptimized`). Optimized, it is the shape facet's
/// emitter writes: the comparison, a selection whose block is `OpKill`
/// alone, and the merge block.
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 33
/// ; Schema: 0
/// OpCapability Shader
/// %1 = OpExtInstImport "GLSL.std.450"
/// OpMemoryModel Logical GLSL450
/// OpEntryPoint Fragment %4 "main" %17 %32
/// OpExecutionMode %4 OriginUpperLeft
/// OpDecorate %13 Binding 0
/// OpDecorate %13 DescriptorSet 0
/// OpDecorate %17 Location 0
/// OpDecorate %32 Location 0
/// %2 = OpTypeVoid
/// %3 = OpTypeFunction %2
/// %6 = OpTypeFloat 32
/// %7 = OpTypeVector %6 4
/// %10 = OpTypeImage %6 2D 0 0 0 1 Unknown
/// %11 = OpTypeSampledImage %10
/// %12 = OpTypePointer UniformConstant %11
/// %13 = OpVariable %12 UniformConstant
/// %15 = OpTypeVector %6 2
/// %16 = OpTypePointer Input %15
/// %17 = OpVariable %16 Input
/// %25 = OpConstant %6 0.5
/// %26 = OpTypeBool
/// %31 = OpTypePointer Output %7
/// %32 = OpVariable %31 Output
/// %4 = OpFunction %2 None %3
/// %5 = OpLabel
/// %14 = OpLoad %11 %13
/// %18 = OpLoad %15 %17
/// %19 = OpImageSampleImplicitLod %7 %14 %18
/// %24 = OpCompositeExtract %6 %19 3
/// %27 = OpFOrdLessThan %26 %24 %25
/// OpSelectionMerge %29 None
/// OpBranchConditional %27 %28 %29
/// %28 = OpLabel
/// OpKill
/// %29 = OpLabel
/// OpStore %32 %19
/// OpReturn
/// OpFunctionEnd
/// ```
pub const glslc_cutout = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x00000021, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x00000011, 0x00000020, 0x00030010,
    0x00000004, 0x00000007, 0x00040047, 0x0000000D, 0x00000021, 0x00000000,
    0x00040047, 0x0000000D, 0x00000022, 0x00000000, 0x00040047, 0x00000011,
    0x0000001E, 0x00000000, 0x00040047, 0x00000020, 0x0000001E, 0x00000000,
    0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002, 0x00030016,
    0x00000006, 0x00000020, 0x00040017, 0x00000007, 0x00000006, 0x00000004,
    0x00090019, 0x0000000A, 0x00000006, 0x00000001, 0x00000000, 0x00000000,
    0x00000000, 0x00000001, 0x00000000, 0x0003001B, 0x0000000B, 0x0000000A,
    0x00040020, 0x0000000C, 0x00000000, 0x0000000B, 0x0004003B, 0x0000000C,
    0x0000000D, 0x00000000, 0x00040017, 0x0000000F, 0x00000006, 0x00000002,
    0x00040020, 0x00000010, 0x00000001, 0x0000000F, 0x0004003B, 0x00000010,
    0x00000011, 0x00000001, 0x0004002B, 0x00000006, 0x00000019, 0x3F000000,
    0x00020014, 0x0000001A, 0x00040020, 0x0000001F, 0x00000003, 0x00000007,
    0x0004003B, 0x0000001F, 0x00000020, 0x00000003, 0x00050036, 0x00000002,
    0x00000004, 0x00000000, 0x00000003, 0x000200F8, 0x00000005, 0x0004003D,
    0x0000000B, 0x0000000E, 0x0000000D, 0x0004003D, 0x0000000F, 0x00000012,
    0x00000011, 0x00050057, 0x00000007, 0x00000013, 0x0000000E, 0x00000012,
    0x00050051, 0x00000006, 0x00000018, 0x00000013, 0x00000003, 0x000500B8,
    0x0000001A, 0x0000001B, 0x00000018, 0x00000019, 0x000300F7, 0x0000001D,
    0x00000000, 0x000400FA, 0x0000001B, 0x0000001C, 0x0000001D, 0x000200F8,
    0x0000001C, 0x000100FC, 0x000200F8, 0x0000001D, 0x0003003E, 0x00000020,
    0x00000013, 0x000100FD, 0x00010038,
};

/// glslc's own output for a shadow sample: a depth compared with the
/// reference the vertices carry, what passed times (1, 0, 0, 1) - the
/// same shader as `Shadowed` in `compile.zig`'s tests, from GLSL (since
/// 1.143).
///
/// ```sh
/// # shadow.frag: #version 450, in vec2 uv at 0, in float ref at 1,
/// # out vec4 colour at 0, uniform sampler2DShadow map at set 0, binding
/// # 0; void main() { colour = vec4(1, 0, 0, 1) * texture(map, vec3(uv, ref)); }
/// glslc -fshader-stage=frag shadow.frag -o shadow.spv   # 220 words
/// spirv-val --target-env vulkan1.0 shadow.spv           # no output, and 0
/// ```
///
/// Its coordinate is three floats, the reference the third, and the Dref
/// is that float extracted again: SPIR-V lets a coordinate be wider than
/// the image needs, and `compile.zig` gives the TMU its first two.
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 32
/// ; Schema: 0
/// OpCapability Shader
/// %1 = OpExtInstImport "GLSL.std.450"
/// OpMemoryModel Logical GLSL450
/// OpEntryPoint Fragment %4 "main" %9 %20 %23
/// OpExecutionMode %4 OriginUpperLeft
/// OpSource GLSL 450
/// OpSourceExtension "GL_GOOGLE_cpp_style_line_directive"
/// OpSourceExtension "GL_GOOGLE_include_directive"
/// OpName %4 "main"
/// OpName %9 "colour"
/// OpName %16 "map"
/// OpName %20 "uv"
/// OpName %23 "ref"
/// OpDecorate %9 Location 0
/// OpDecorate %16 Binding 0
/// OpDecorate %16 DescriptorSet 0
/// OpDecorate %20 Location 0
/// OpDecorate %23 Location 1
/// %2 = OpTypeVoid
/// %3 = OpTypeFunction %2
/// %6 = OpTypeFloat 32
/// %7 = OpTypeVector %6 4
/// %8 = OpTypePointer Output %7
/// %9 = OpVariable %8 Output
/// %10 = OpConstant %6 1
/// %11 = OpConstant %6 0
/// %12 = OpConstantComposite %7 %10 %11 %11 %10
/// %13 = OpTypeImage %6 2D 1 0 0 1 Unknown
/// %14 = OpTypeSampledImage %13
/// %15 = OpTypePointer UniformConstant %14
/// %16 = OpVariable %15 UniformConstant
/// %18 = OpTypeVector %6 2
/// %19 = OpTypePointer Input %18
/// %20 = OpVariable %19 Input
/// %22 = OpTypePointer Input %6
/// %23 = OpVariable %22 Input
/// %25 = OpTypeVector %6 3
/// %4 = OpFunction %2 None %3
/// %5 = OpLabel
/// %17 = OpLoad %14 %16
/// %21 = OpLoad %18 %20
/// %24 = OpLoad %6 %23
/// %26 = OpCompositeExtract %6 %21 0
/// %27 = OpCompositeExtract %6 %21 1
/// %28 = OpCompositeConstruct %25 %26 %27 %24
/// %29 = OpCompositeExtract %6 %28 2
/// %30 = OpImageSampleDrefImplicitLod %6 %17 %28 %29
/// %31 = OpVectorTimesScalar %7 %12 %30
/// OpStore %9 %31
/// OpReturn
/// OpFunctionEnd
/// ```
pub const glslc_shadow = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x00000020, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0008000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x00000009, 0x00000014, 0x00000017,
    0x00030010, 0x00000004, 0x00000007, 0x00030003, 0x00000002, 0x000001C2,
    0x000A0004, 0x475F4C47, 0x4C474F4F, 0x70635F45, 0x74735F70, 0x5F656C79,
    0x656E696C, 0x7269645F, 0x69746365, 0x00006576, 0x00080004, 0x475F4C47,
    0x4C474F4F, 0x6E695F45, 0x64756C63, 0x69645F65, 0x74636572, 0x00657669,
    0x00040005, 0x00000004, 0x6E69616D, 0x00000000, 0x00040005, 0x00000009,
    0x6F6C6F63, 0x00007275, 0x00030005, 0x00000010, 0x0070616D, 0x00030005,
    0x00000014, 0x00007675, 0x00030005, 0x00000017, 0x00666572, 0x00040047,
    0x00000009, 0x0000001E, 0x00000000, 0x00040047, 0x00000010, 0x00000021,
    0x00000000, 0x00040047, 0x00000010, 0x00000022, 0x00000000, 0x00040047,
    0x00000014, 0x0000001E, 0x00000000, 0x00040047, 0x00000017, 0x0000001E,
    0x00000001, 0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002,
    0x00030016, 0x00000006, 0x00000020, 0x00040017, 0x00000007, 0x00000006,
    0x00000004, 0x00040020, 0x00000008, 0x00000003, 0x00000007, 0x0004003B,
    0x00000008, 0x00000009, 0x00000003, 0x0004002B, 0x00000006, 0x0000000A,
    0x3F800000, 0x0004002B, 0x00000006, 0x0000000B, 0x00000000, 0x0007002C,
    0x00000007, 0x0000000C, 0x0000000A, 0x0000000B, 0x0000000B, 0x0000000A,
    0x00090019, 0x0000000D, 0x00000006, 0x00000001, 0x00000001, 0x00000000,
    0x00000000, 0x00000001, 0x00000000, 0x0003001B, 0x0000000E, 0x0000000D,
    0x00040020, 0x0000000F, 0x00000000, 0x0000000E, 0x0004003B, 0x0000000F,
    0x00000010, 0x00000000, 0x00040017, 0x00000012, 0x00000006, 0x00000002,
    0x00040020, 0x00000013, 0x00000001, 0x00000012, 0x0004003B, 0x00000013,
    0x00000014, 0x00000001, 0x00040020, 0x00000016, 0x00000001, 0x00000006,
    0x0004003B, 0x00000016, 0x00000017, 0x00000001, 0x00040017, 0x00000019,
    0x00000006, 0x00000003, 0x00050036, 0x00000002, 0x00000004, 0x00000000,
    0x00000003, 0x000200F8, 0x00000005, 0x0004003D, 0x0000000E, 0x00000011,
    0x00000010, 0x0004003D, 0x00000012, 0x00000015, 0x00000014, 0x0004003D,
    0x00000006, 0x00000018, 0x00000017, 0x00050051, 0x00000006, 0x0000001A,
    0x00000015, 0x00000000, 0x00050051, 0x00000006, 0x0000001B, 0x00000015,
    0x00000001, 0x00060050, 0x00000019, 0x0000001C, 0x0000001A, 0x0000001B,
    0x00000018, 0x00050051, 0x00000006, 0x0000001D, 0x0000001C, 0x00000002,
    0x00060059, 0x00000006, 0x0000001E, 0x00000011, 0x0000001C, 0x0000001D,
    0x0005008E, 0x00000007, 0x0000001F, 0x0000000C, 0x0000001E, 0x0003003E,
    0x00000009, 0x0000001F, 0x000100FD, 0x00010038,
};

/// glslc's own output, at `-O`, for float arithmetic through GLSL.std.450:
/// a difference, Normalize, a dot, FClamp, FMix, Fract, a product by a
/// half where the source divides by 2, FAbs, Sqrt, Pow, a negation,
/// FMax and Length, the floats of the varying read through access
/// chains and a shuffle (since 1.152).
///
/// ```glsl
/// #version 450
/// layout(location = 0) in vec4 vcolor;
/// layout(location = 0) out vec4 ocolor;
/// void main() {
///     vec3 n = normalize(vcolor.xyz - vec3(0.5));
///     float lit = clamp(dot(n, vec3(0.267, 0.535, 0.802)), 0.0, 1.0);
///     float r = mix(vcolor.x, lit, 0.25);
///     float g = fract(vcolor.y * 3.0) / 2.0;
///     float b = sqrt(abs(vcolor.z - 0.5)) * pow(vcolor.w, 2.2);
///     ocolor = vec4(r, g, max(b, -vcolor.x), length(vcolor.xy) * 0.5);
/// }
/// ```
///
/// ```sh
/// glslc -O -fshader-stage=frag arith.frag -o arith.spv   # 315 words
/// spirv-val --target-env vulkan1.0 arith.spv           # no output, and 0
/// ```
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 76
/// ; Schema: 0
///                OpCapability Shader
///           %1 = OpExtInstImport "GLSL.std.450"
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %4 "main" %12 %62
///                OpExecutionMode %4 OriginUpperLeft
///                OpDecorate %12 Location 0
///                OpDecorate %62 Location 0
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeFloat 32
///           %7 = OpTypeVector %6 3
///          %10 = OpTypeVector %6 4
///          %11 = OpTypePointer Input %10
///          %12 = OpVariable %11 Input
///          %15 = OpConstant %6 0.5
///          %16 = OpConstantComposite %7 %15 %15 %15
///          %22 = OpConstant %6 0.26699999
///          %23 = OpConstant %6 0.535000026
///          %24 = OpConstant %6 0.801999986
///          %25 = OpConstantComposite %7 %22 %23 %24
///          %27 = OpConstant %6 0
///          %28 = OpConstant %6 1
///          %31 = OpTypeInt 32 0
///          %32 = OpConstant %31 0
///          %33 = OpTypePointer Input %6
///          %37 = OpConstant %6 0.25
///          %40 = OpConstant %31 1
///          %43 = OpConstant %6 3
///          %49 = OpConstant %31 2
///          %55 = OpConstant %31 3
///          %58 = OpConstant %6 2.20000005
///          %61 = OpTypePointer Output %10
///          %62 = OpVariable %61 Output
///          %70 = OpTypeVector %6 2
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///          %13 = OpLoad %10 %12
///          %14 = OpVectorShuffle %7 %13 %13 0 1 2
///          %17 = OpFSub %7 %14 %16
///          %18 = OpExtInst %7 %1 Normalize %17
///          %26 = OpDot %6 %18 %25
///          %29 = OpExtInst %6 %1 FClamp %26 %27 %28
///          %34 = OpAccessChain %33 %12 %32
///          %35 = OpLoad %6 %34
///          %38 = OpExtInst %6 %1 FMix %35 %29 %37
///          %41 = OpAccessChain %33 %12 %40
///          %42 = OpLoad %6 %41
///          %44 = OpFMul %6 %42 %43
///          %45 = OpExtInst %6 %1 Fract %44
///          %47 = OpFMul %6 %45 %15
///          %50 = OpAccessChain %33 %12 %49
///          %51 = OpLoad %6 %50
///          %52 = OpFSub %6 %51 %15
///          %53 = OpExtInst %6 %1 FAbs %52
///          %54 = OpExtInst %6 %1 Sqrt %53
///          %56 = OpAccessChain %33 %12 %55
///          %57 = OpLoad %6 %56
///          %59 = OpExtInst %6 %1 Pow %57 %58
///          %60 = OpFMul %6 %54 %59
///          %68 = OpFNegate %6 %35
///          %69 = OpExtInst %6 %1 FMax %60 %68
///          %72 = OpVectorShuffle %70 %13 %13 0 1
///          %73 = OpExtInst %6 %1 Length %72
///          %74 = OpFMul %6 %73 %15
///          %75 = OpCompositeConstruct %10 %38 %47 %69 %74
///                OpStore %62 %75
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_arith = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x0000004C, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x0000000C, 0x0000003E, 0x00030010,
    0x00000004, 0x00000007, 0x00040047, 0x0000000C, 0x0000001E, 0x00000000,
    0x00040047, 0x0000003E, 0x0000001E, 0x00000000, 0x00020013, 0x00000002,
    0x00030021, 0x00000003, 0x00000002, 0x00030016, 0x00000006, 0x00000020,
    0x00040017, 0x00000007, 0x00000006, 0x00000003, 0x00040017, 0x0000000A,
    0x00000006, 0x00000004, 0x00040020, 0x0000000B, 0x00000001, 0x0000000A,
    0x0004003B, 0x0000000B, 0x0000000C, 0x00000001, 0x0004002B, 0x00000006,
    0x0000000F, 0x3F000000, 0x0006002C, 0x00000007, 0x00000010, 0x0000000F,
    0x0000000F, 0x0000000F, 0x0004002B, 0x00000006, 0x00000016, 0x3E88B439,
    0x0004002B, 0x00000006, 0x00000017, 0x3F08F5C3, 0x0004002B, 0x00000006,
    0x00000018, 0x3F4D4FDF, 0x0006002C, 0x00000007, 0x00000019, 0x00000016,
    0x00000017, 0x00000018, 0x0004002B, 0x00000006, 0x0000001B, 0x00000000,
    0x0004002B, 0x00000006, 0x0000001C, 0x3F800000, 0x00040015, 0x0000001F,
    0x00000020, 0x00000000, 0x0004002B, 0x0000001F, 0x00000020, 0x00000000,
    0x00040020, 0x00000021, 0x00000001, 0x00000006, 0x0004002B, 0x00000006,
    0x00000025, 0x3E800000, 0x0004002B, 0x0000001F, 0x00000028, 0x00000001,
    0x0004002B, 0x00000006, 0x0000002B, 0x40400000, 0x0004002B, 0x0000001F,
    0x00000031, 0x00000002, 0x0004002B, 0x0000001F, 0x00000037, 0x00000003,
    0x0004002B, 0x00000006, 0x0000003A, 0x400CCCCD, 0x00040020, 0x0000003D,
    0x00000003, 0x0000000A, 0x0004003B, 0x0000003D, 0x0000003E, 0x00000003,
    0x00040017, 0x00000046, 0x00000006, 0x00000002, 0x00050036, 0x00000002,
    0x00000004, 0x00000000, 0x00000003, 0x000200F8, 0x00000005, 0x0004003D,
    0x0000000A, 0x0000000D, 0x0000000C, 0x0008004F, 0x00000007, 0x0000000E,
    0x0000000D, 0x0000000D, 0x00000000, 0x00000001, 0x00000002, 0x00050083,
    0x00000007, 0x00000011, 0x0000000E, 0x00000010, 0x0006000C, 0x00000007,
    0x00000012, 0x00000001, 0x00000045, 0x00000011, 0x00050094, 0x00000006,
    0x0000001A, 0x00000012, 0x00000019, 0x0008000C, 0x00000006, 0x0000001D,
    0x00000001, 0x0000002B, 0x0000001A, 0x0000001B, 0x0000001C, 0x00050041,
    0x00000021, 0x00000022, 0x0000000C, 0x00000020, 0x0004003D, 0x00000006,
    0x00000023, 0x00000022, 0x0008000C, 0x00000006, 0x00000026, 0x00000001,
    0x0000002E, 0x00000023, 0x0000001D, 0x00000025, 0x00050041, 0x00000021,
    0x00000029, 0x0000000C, 0x00000028, 0x0004003D, 0x00000006, 0x0000002A,
    0x00000029, 0x00050085, 0x00000006, 0x0000002C, 0x0000002A, 0x0000002B,
    0x0006000C, 0x00000006, 0x0000002D, 0x00000001, 0x0000000A, 0x0000002C,
    0x00050085, 0x00000006, 0x0000002F, 0x0000002D, 0x0000000F, 0x00050041,
    0x00000021, 0x00000032, 0x0000000C, 0x00000031, 0x0004003D, 0x00000006,
    0x00000033, 0x00000032, 0x00050083, 0x00000006, 0x00000034, 0x00000033,
    0x0000000F, 0x0006000C, 0x00000006, 0x00000035, 0x00000001, 0x00000004,
    0x00000034, 0x0006000C, 0x00000006, 0x00000036, 0x00000001, 0x0000001F,
    0x00000035, 0x00050041, 0x00000021, 0x00000038, 0x0000000C, 0x00000037,
    0x0004003D, 0x00000006, 0x00000039, 0x00000038, 0x0007000C, 0x00000006,
    0x0000003B, 0x00000001, 0x0000001A, 0x00000039, 0x0000003A, 0x00050085,
    0x00000006, 0x0000003C, 0x00000036, 0x0000003B, 0x0004007F, 0x00000006,
    0x00000044, 0x00000023, 0x0007000C, 0x00000006, 0x00000045, 0x00000001,
    0x00000028, 0x0000003C, 0x00000044, 0x0007004F, 0x00000046, 0x00000048,
    0x0000000D, 0x0000000D, 0x00000000, 0x00000001, 0x0006000C, 0x00000006,
    0x00000049, 0x00000001, 0x00000042, 0x00000048, 0x00050085, 0x00000006,
    0x0000004A, 0x00000049, 0x0000000F, 0x00070050, 0x0000000A, 0x0000004B,
    0x00000026, 0x0000002F, 0x00000045, 0x0000004A, 0x0003003E, 0x0000003E,
    0x0000004B, 0x000100FD, 0x00010038,
};

/// glslc's own output, at `-O`, for a float chosen by a comparison and
/// the rest of GLSL.std.450's float functions: Sin, Cos, Tan, FClamp to
/// 0.0 and 1.0, Step, SmoothStep and FSign, and OpSelect after <, >=,
/// !=, == and <=, five of the six comparisons the walk reads (since
/// 1.153). glslc makes each ternary of plain values an OpSelect, so the
/// module is one block.
///
/// ```glsl
/// #version 450
/// layout(location = 0) in vec4 vcolor;
/// layout(location = 0) out vec4 ocolor;
/// void main() {
///     float s = sin(vcolor.x * 6.0) * 0.5 + 0.5;
///     float c = cos(vcolor.y * 6.0) * 0.5 + 0.5;
///     float t = clamp(tan(vcolor.z) * 0.25, 0.0, 1.0);
///     float g = vcolor.x < vcolor.y ? s : c;
///     float st = step(0.3, vcolor.x);
///     float sm = smoothstep(0.2, 0.8, vcolor.y);
///     float e = vcolor.z >= 0.5 ? st : sm;
///     float k = sign(vcolor.x - 0.5) * 0.25 + 0.5;
///     float ne = vcolor.x != vcolor.y ? 0.75 : 1.0;
///     float eq = vcolor.y == vcolor.z ? 0.25 : ne;
///     float a = vcolor.x <= vcolor.z ? k : eq;
///     ocolor = vec4(g, e, t, a);
/// }
/// ```
///
/// ```sh
/// glslc -O -fshader-stage=frag chosen.frag -o chosen.spv   # 318 words
/// spirv-val --target-env vulkan1.0 chosen.spv            # no output, and 0
/// ```
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 108
/// ; Schema: 0
///                OpCapability Shader
///           %1 = OpExtInstImport "GLSL.std.450"
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %4 "main" %11 %102
///                OpExecutionMode %4 OriginUpperLeft
///                OpDecorate %11 Location 0
///                OpDecorate %102 Location 0
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeFloat 32
///           %9 = OpTypeVector %6 4
///          %10 = OpTypePointer Input %9
///          %11 = OpVariable %10 Input
///          %12 = OpTypeInt 32 0
///          %13 = OpConstant %12 0
///          %14 = OpTypePointer Input %6
///          %17 = OpConstant %6 6
///          %20 = OpConstant %6 0.5
///          %24 = OpConstant %12 1
///          %32 = OpConstant %12 2
///          %36 = OpConstant %6 0.25
///          %38 = OpConstant %6 0
///          %39 = OpConstant %6 1
///          %46 = OpTypeBool
///          %52 = OpConstant %6 0.300000012
///          %57 = OpConstant %6 0.200000003
///          %58 = OpConstant %6 0.800000012
///          %82 = OpConstant %6 0.75
///         %101 = OpTypePointer Output %9
///         %102 = OpVariable %101 Output
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///          %15 = OpAccessChain %14 %11 %13
///          %16 = OpLoad %6 %15
///          %18 = OpFMul %6 %16 %17
///          %19 = OpExtInst %6 %1 Sin %18
///          %21 = OpFMul %6 %19 %20
///          %22 = OpFAdd %6 %21 %20
///          %25 = OpAccessChain %14 %11 %24
///          %26 = OpLoad %6 %25
///          %27 = OpFMul %6 %26 %17
///          %28 = OpExtInst %6 %1 Cos %27
///          %29 = OpFMul %6 %28 %20
///          %30 = OpFAdd %6 %29 %20
///          %33 = OpAccessChain %14 %11 %32
///          %34 = OpLoad %6 %33
///          %35 = OpExtInst %6 %1 Tan %34
///          %37 = OpFMul %6 %35 %36
///          %40 = OpExtInst %6 %1 FClamp %37 %38 %39
///          %47 = OpFOrdLessThan %46 %16 %26
///          %50 = OpSelect %6 %47 %22 %30
///          %55 = OpExtInst %6 %1 Step %52 %16
///          %61 = OpExtInst %6 %1 SmoothStep %57 %58 %26
///          %65 = OpFOrdGreaterThanEqual %46 %34 %20
///          %68 = OpSelect %6 %65 %55 %61
///          %72 = OpFSub %6 %16 %20
///          %73 = OpExtInst %6 %1 FSign %72
///          %74 = OpFMul %6 %73 %36
///          %75 = OpFAdd %6 %74 %20
///          %81 = OpFUnordNotEqual %46 %16 %26
///          %83 = OpSelect %6 %81 %82 %39
///          %89 = OpFOrdEqual %46 %26 %34
///          %91 = OpSelect %6 %89 %36 %83
///          %97 = OpFOrdLessThanEqual %46 %16 %34
///         %100 = OpSelect %6 %97 %75 %91
///         %107 = OpCompositeConstruct %9 %50 %68 %40 %100
///                OpStore %102 %107
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_chosen = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x0000006C, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x0000000B, 0x00000066, 0x00030010,
    0x00000004, 0x00000007, 0x00040047, 0x0000000B, 0x0000001E, 0x00000000,
    0x00040047, 0x00000066, 0x0000001E, 0x00000000, 0x00020013, 0x00000002,
    0x00030021, 0x00000003, 0x00000002, 0x00030016, 0x00000006, 0x00000020,
    0x00040017, 0x00000009, 0x00000006, 0x00000004, 0x00040020, 0x0000000A,
    0x00000001, 0x00000009, 0x0004003B, 0x0000000A, 0x0000000B, 0x00000001,
    0x00040015, 0x0000000C, 0x00000020, 0x00000000, 0x0004002B, 0x0000000C,
    0x0000000D, 0x00000000, 0x00040020, 0x0000000E, 0x00000001, 0x00000006,
    0x0004002B, 0x00000006, 0x00000011, 0x40C00000, 0x0004002B, 0x00000006,
    0x00000014, 0x3F000000, 0x0004002B, 0x0000000C, 0x00000018, 0x00000001,
    0x0004002B, 0x0000000C, 0x00000020, 0x00000002, 0x0004002B, 0x00000006,
    0x00000024, 0x3E800000, 0x0004002B, 0x00000006, 0x00000026, 0x00000000,
    0x0004002B, 0x00000006, 0x00000027, 0x3F800000, 0x00020014, 0x0000002E,
    0x0004002B, 0x00000006, 0x00000034, 0x3E99999A, 0x0004002B, 0x00000006,
    0x00000039, 0x3E4CCCCD, 0x0004002B, 0x00000006, 0x0000003A, 0x3F4CCCCD,
    0x0004002B, 0x00000006, 0x00000052, 0x3F400000, 0x00040020, 0x00000065,
    0x00000003, 0x00000009, 0x0004003B, 0x00000065, 0x00000066, 0x00000003,
    0x00050036, 0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200F8,
    0x00000005, 0x00050041, 0x0000000E, 0x0000000F, 0x0000000B, 0x0000000D,
    0x0004003D, 0x00000006, 0x00000010, 0x0000000F, 0x00050085, 0x00000006,
    0x00000012, 0x00000010, 0x00000011, 0x0006000C, 0x00000006, 0x00000013,
    0x00000001, 0x0000000D, 0x00000012, 0x00050085, 0x00000006, 0x00000015,
    0x00000013, 0x00000014, 0x00050081, 0x00000006, 0x00000016, 0x00000015,
    0x00000014, 0x00050041, 0x0000000E, 0x00000019, 0x0000000B, 0x00000018,
    0x0004003D, 0x00000006, 0x0000001A, 0x00000019, 0x00050085, 0x00000006,
    0x0000001B, 0x0000001A, 0x00000011, 0x0006000C, 0x00000006, 0x0000001C,
    0x00000001, 0x0000000E, 0x0000001B, 0x00050085, 0x00000006, 0x0000001D,
    0x0000001C, 0x00000014, 0x00050081, 0x00000006, 0x0000001E, 0x0000001D,
    0x00000014, 0x00050041, 0x0000000E, 0x00000021, 0x0000000B, 0x00000020,
    0x0004003D, 0x00000006, 0x00000022, 0x00000021, 0x0006000C, 0x00000006,
    0x00000023, 0x00000001, 0x0000000F, 0x00000022, 0x00050085, 0x00000006,
    0x00000025, 0x00000023, 0x00000024, 0x0008000C, 0x00000006, 0x00000028,
    0x00000001, 0x0000002B, 0x00000025, 0x00000026, 0x00000027, 0x000500B8,
    0x0000002E, 0x0000002F, 0x00000010, 0x0000001A, 0x000600A9, 0x00000006,
    0x00000032, 0x0000002F, 0x00000016, 0x0000001E, 0x0007000C, 0x00000006,
    0x00000037, 0x00000001, 0x00000030, 0x00000034, 0x00000010, 0x0008000C,
    0x00000006, 0x0000003D, 0x00000001, 0x00000031, 0x00000039, 0x0000003A,
    0x0000001A, 0x000500BE, 0x0000002E, 0x00000041, 0x00000022, 0x00000014,
    0x000600A9, 0x00000006, 0x00000044, 0x00000041, 0x00000037, 0x0000003D,
    0x00050083, 0x00000006, 0x00000048, 0x00000010, 0x00000014, 0x0006000C,
    0x00000006, 0x00000049, 0x00000001, 0x00000006, 0x00000048, 0x00050085,
    0x00000006, 0x0000004A, 0x00000049, 0x00000024, 0x00050081, 0x00000006,
    0x0000004B, 0x0000004A, 0x00000014, 0x000500B7, 0x0000002E, 0x00000051,
    0x00000010, 0x0000001A, 0x000600A9, 0x00000006, 0x00000053, 0x00000051,
    0x00000052, 0x00000027, 0x000500B4, 0x0000002E, 0x00000059, 0x0000001A,
    0x00000022, 0x000600A9, 0x00000006, 0x0000005B, 0x00000059, 0x00000024,
    0x00000053, 0x000500BC, 0x0000002E, 0x00000061, 0x00000010, 0x00000022,
    0x000600A9, 0x00000006, 0x00000064, 0x00000061, 0x0000004B, 0x0000005B,
    0x00070050, 0x00000009, 0x0000006B, 0x00000032, 0x00000044, 0x00000028,
    0x00000064, 0x0003003E, 0x00000066, 0x0000006B, 0x000100FD, 0x00010038,
};

/// glslc's own output, at `-O`, for an `if` and `else` and a ternary
/// whose arms call functions: selections, each arm a block that ends in
/// an OpBranch to the merge block, and the values chosen there by OpPhi,
/// one of a vector whose floats each arm replaces with
/// OpCompositeInsert. Mesa's nir_opt_peephole_select flattens both, the
/// arms being few and cheap enough (since 1.154).
///
/// ```glsl
/// #version 450
/// layout(location = 0) in vec4 vcolor;
/// layout(location = 0) out vec4 ocolor;
/// void main() {
///     vec4 c = vcolor;
///     if (vcolor.x < 0.5) {
///         c.r = sin(vcolor.y * 3.0) * 0.5 + 0.5;
///         c.g = vcolor.z * vcolor.w;
///     } else {
///         c.r = vcolor.y * 0.25;
///         c.b = sqrt(vcolor.z);
///     }
///     float k = vcolor.w > 0.5 ? pow(vcolor.x, 2.0) + 0.1 : exp2(vcolor.y) * 0.25;
///     ocolor = vec4(c.r, c.g, c.b, k);
/// }
/// ```
///
/// ```sh
/// glslc -O -fshader-stage=frag branch.frag -o branch.spv   # 360 words
/// spirv-val --target-env vulkan1.0 branch.spv            # no output, and 0
/// ```
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 94
/// ; Schema: 0
///                OpCapability Shader
///           %1 = OpExtInstImport "GLSL.std.450"
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %4 "main" %11 %71
///                OpExecutionMode %4 OriginUpperLeft
///                OpDecorate %11 Location 0
///                OpDecorate %71 Location 0
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeFloat 32
///           %7 = OpTypeVector %6 4
///          %10 = OpTypePointer Input %7
///          %11 = OpVariable %10 Input
///          %13 = OpTypeInt 32 0
///          %14 = OpConstant %13 0
///          %15 = OpTypePointer Input %6
///          %18 = OpConstant %6 0.5
///          %19 = OpTypeBool
///          %23 = OpConstant %13 1
///          %26 = OpConstant %6 3
///          %33 = OpConstant %13 2
///          %36 = OpConstant %13 3
///          %44 = OpConstant %6 0.25
///          %60 = OpConstant %6 2
///          %62 = OpConstant %6 0.100000001
///          %70 = OpTypePointer Output %7
///          %71 = OpVariable %70 Output
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///          %12 = OpLoad %7 %11
///          %16 = OpAccessChain %15 %11 %14
///          %17 = OpLoad %6 %16
///          %20 = OpFOrdLessThan %19 %17 %18
///                OpSelectionMerge %22 None
///                OpBranchConditional %20 %21 %41
///          %21 = OpLabel
///          %24 = OpAccessChain %15 %11 %23
///          %25 = OpLoad %6 %24
///          %27 = OpFMul %6 %25 %26
///          %28 = OpExtInst %6 %1 Sin %27
///          %29 = OpFMul %6 %28 %18
///          %30 = OpFAdd %6 %29 %18
///          %81 = OpCompositeInsert %7 %30 %12 0
///          %34 = OpAccessChain %15 %11 %33
///          %35 = OpLoad %6 %34
///          %37 = OpAccessChain %15 %11 %36
///          %38 = OpLoad %6 %37
///          %39 = OpFMul %6 %35 %38
///          %83 = OpCompositeInsert %7 %39 %81 1
///                OpBranch %22
///          %41 = OpLabel
///          %42 = OpAccessChain %15 %11 %23
///          %43 = OpLoad %6 %42
///          %45 = OpFMul %6 %43 %44
///          %85 = OpCompositeInsert %7 %45 %12 0
///          %47 = OpAccessChain %15 %11 %33
///          %48 = OpLoad %6 %47
///          %49 = OpExtInst %6 %1 Sqrt %48
///          %87 = OpCompositeInsert %7 %49 %85 2
///                OpBranch %22
///          %22 = OpLabel
///          %93 = OpPhi %7 %83 %21 %87 %41
///          %52 = OpAccessChain %15 %11 %36
///          %53 = OpLoad %6 %52
///          %54 = OpFOrdGreaterThan %19 %53 %18
///                OpSelectionMerge %57 None
///                OpBranchConditional %54 %56 %64
///          %56 = OpLabel
///          %61 = OpExtInst %6 %1 Pow %17 %60
///          %63 = OpFAdd %6 %61 %62
///                OpBranch %57
///          %64 = OpLabel
///          %65 = OpAccessChain %15 %11 %23
///          %66 = OpLoad %6 %65
///          %67 = OpExtInst %6 %1 Exp2 %66
///          %68 = OpFMul %6 %67 %44
///                OpBranch %57
///          %57 = OpLabel
///          %91 = OpPhi %6 %63 %56 %68 %64
///          %73 = OpCompositeExtract %6 %93 0
///          %75 = OpCompositeExtract %6 %93 1
///          %77 = OpCompositeExtract %6 %93 2
///          %79 = OpCompositeConstruct %7 %73 %75 %77 %91
///                OpStore %71 %79
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_branch = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x0000005E, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x0000000B, 0x00000047, 0x00030010,
    0x00000004, 0x00000007, 0x00040047, 0x0000000B, 0x0000001E, 0x00000000,
    0x00040047, 0x00000047, 0x0000001E, 0x00000000, 0x00020013, 0x00000002,
    0x00030021, 0x00000003, 0x00000002, 0x00030016, 0x00000006, 0x00000020,
    0x00040017, 0x00000007, 0x00000006, 0x00000004, 0x00040020, 0x0000000A,
    0x00000001, 0x00000007, 0x0004003B, 0x0000000A, 0x0000000B, 0x00000001,
    0x00040015, 0x0000000D, 0x00000020, 0x00000000, 0x0004002B, 0x0000000D,
    0x0000000E, 0x00000000, 0x00040020, 0x0000000F, 0x00000001, 0x00000006,
    0x0004002B, 0x00000006, 0x00000012, 0x3F000000, 0x00020014, 0x00000013,
    0x0004002B, 0x0000000D, 0x00000017, 0x00000001, 0x0004002B, 0x00000006,
    0x0000001A, 0x40400000, 0x0004002B, 0x0000000D, 0x00000021, 0x00000002,
    0x0004002B, 0x0000000D, 0x00000024, 0x00000003, 0x0004002B, 0x00000006,
    0x0000002C, 0x3E800000, 0x0004002B, 0x00000006, 0x0000003C, 0x40000000,
    0x0004002B, 0x00000006, 0x0000003E, 0x3DCCCCCD, 0x00040020, 0x00000046,
    0x00000003, 0x00000007, 0x0004003B, 0x00000046, 0x00000047, 0x00000003,
    0x00050036, 0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200F8,
    0x00000005, 0x0004003D, 0x00000007, 0x0000000C, 0x0000000B, 0x00050041,
    0x0000000F, 0x00000010, 0x0000000B, 0x0000000E, 0x0004003D, 0x00000006,
    0x00000011, 0x00000010, 0x000500B8, 0x00000013, 0x00000014, 0x00000011,
    0x00000012, 0x000300F7, 0x00000016, 0x00000000, 0x000400FA, 0x00000014,
    0x00000015, 0x00000029, 0x000200F8, 0x00000015, 0x00050041, 0x0000000F,
    0x00000018, 0x0000000B, 0x00000017, 0x0004003D, 0x00000006, 0x00000019,
    0x00000018, 0x00050085, 0x00000006, 0x0000001B, 0x00000019, 0x0000001A,
    0x0006000C, 0x00000006, 0x0000001C, 0x00000001, 0x0000000D, 0x0000001B,
    0x00050085, 0x00000006, 0x0000001D, 0x0000001C, 0x00000012, 0x00050081,
    0x00000006, 0x0000001E, 0x0000001D, 0x00000012, 0x00060052, 0x00000007,
    0x00000051, 0x0000001E, 0x0000000C, 0x00000000, 0x00050041, 0x0000000F,
    0x00000022, 0x0000000B, 0x00000021, 0x0004003D, 0x00000006, 0x00000023,
    0x00000022, 0x00050041, 0x0000000F, 0x00000025, 0x0000000B, 0x00000024,
    0x0004003D, 0x00000006, 0x00000026, 0x00000025, 0x00050085, 0x00000006,
    0x00000027, 0x00000023, 0x00000026, 0x00060052, 0x00000007, 0x00000053,
    0x00000027, 0x00000051, 0x00000001, 0x000200F9, 0x00000016, 0x000200F8,
    0x00000029, 0x00050041, 0x0000000F, 0x0000002A, 0x0000000B, 0x00000017,
    0x0004003D, 0x00000006, 0x0000002B, 0x0000002A, 0x00050085, 0x00000006,
    0x0000002D, 0x0000002B, 0x0000002C, 0x00060052, 0x00000007, 0x00000055,
    0x0000002D, 0x0000000C, 0x00000000, 0x00050041, 0x0000000F, 0x0000002F,
    0x0000000B, 0x00000021, 0x0004003D, 0x00000006, 0x00000030, 0x0000002F,
    0x0006000C, 0x00000006, 0x00000031, 0x00000001, 0x0000001F, 0x00000030,
    0x00060052, 0x00000007, 0x00000057, 0x00000031, 0x00000055, 0x00000002,
    0x000200F9, 0x00000016, 0x000200F8, 0x00000016, 0x000700F5, 0x00000007,
    0x0000005D, 0x00000053, 0x00000015, 0x00000057, 0x00000029, 0x00050041,
    0x0000000F, 0x00000034, 0x0000000B, 0x00000024, 0x0004003D, 0x00000006,
    0x00000035, 0x00000034, 0x000500BA, 0x00000013, 0x00000036, 0x00000035,
    0x00000012, 0x000300F7, 0x00000039, 0x00000000, 0x000400FA, 0x00000036,
    0x00000038, 0x00000040, 0x000200F8, 0x00000038, 0x0007000C, 0x00000006,
    0x0000003D, 0x00000001, 0x0000001A, 0x00000011, 0x0000003C, 0x00050081,
    0x00000006, 0x0000003F, 0x0000003D, 0x0000003E, 0x000200F9, 0x00000039,
    0x000200F8, 0x00000040, 0x00050041, 0x0000000F, 0x00000041, 0x0000000B,
    0x00000017, 0x0004003D, 0x00000006, 0x00000042, 0x00000041, 0x0006000C,
    0x00000006, 0x00000043, 0x00000001, 0x0000001D, 0x00000042, 0x00050085,
    0x00000006, 0x00000044, 0x00000043, 0x0000002C, 0x000200F9, 0x00000039,
    0x000200F8, 0x00000039, 0x000700F5, 0x00000006, 0x0000005B, 0x0000003F,
    0x00000038, 0x00000044, 0x00000040, 0x00050051, 0x00000006, 0x00000049,
    0x0000005D, 0x00000000, 0x00050051, 0x00000006, 0x0000004B, 0x0000005D,
    0x00000001, 0x00050051, 0x00000006, 0x0000004D, 0x0000005D, 0x00000002,
    0x00070050, 0x00000007, 0x0000004F, 0x00000049, 0x0000004B, 0x0000004D,
    0x0000005B, 0x0003003E, 0x00000047, 0x0000004F, 0x000100FD, 0x00010038,
};

/// glslc's own output, at `-O`, for an `if` whose arm samples: a
/// texture instruction, which nir_opt_peephole_select does not move out
/// of its arm, so the selection stays a branch, which this back end
/// refuses (since 1.154).
///
/// ```glsl
/// #version 450
/// layout(location = 0) in vec4 vcolor;
/// layout(location = 0) out vec4 ocolor;
/// layout(set = 0, binding = 0) uniform sampler2D tex;
/// void main() {
///     vec4 c = vcolor;
///     if (vcolor.x < 0.5) {
///         c = texture(tex, vcolor.yz);
///     }
///     ocolor = c;
/// }
/// ```
///
/// ```sh
/// glslc -O -fshader-stage=frag sampled.frag -o sampled.spv   # 178 words
/// spirv-val --target-env vulkan1.0 sampled.spv             # no output, and 0
/// ```
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 36
/// ; Schema: 0
///                OpCapability Shader
///           %1 = OpExtInstImport "GLSL.std.450"
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %4 "main" %11 %33
///                OpExecutionMode %4 OriginUpperLeft
///                OpDecorate %11 Location 0
///                OpDecorate %26 Binding 0
///                OpDecorate %26 DescriptorSet 0
///                OpDecorate %33 Location 0
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeFloat 32
///           %7 = OpTypeVector %6 4
///          %10 = OpTypePointer Input %7
///          %11 = OpVariable %10 Input
///          %13 = OpTypeInt 32 0
///          %14 = OpConstant %13 0
///          %15 = OpTypePointer Input %6
///          %18 = OpConstant %6 0.5
///          %19 = OpTypeBool
///          %23 = OpTypeImage %6 2D 0 0 0 1 Unknown
///          %24 = OpTypeSampledImage %23
///          %25 = OpTypePointer UniformConstant %24
///          %26 = OpVariable %25 UniformConstant
///          %28 = OpTypeVector %6 2
///          %32 = OpTypePointer Output %7
///          %33 = OpVariable %32 Output
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///          %12 = OpLoad %7 %11
///          %16 = OpAccessChain %15 %11 %14
///          %17 = OpLoad %6 %16
///          %20 = OpFOrdLessThan %19 %17 %18
///                OpSelectionMerge %22 None
///                OpBranchConditional %20 %21 %22
///          %21 = OpLabel
///          %27 = OpLoad %24 %26
///          %30 = OpVectorShuffle %28 %12 %12 1 2
///          %31 = OpImageSampleImplicitLod %7 %27 %30
///                OpBranch %22
///          %22 = OpLabel
///          %35 = OpPhi %7 %12 %5 %31 %21
///                OpStore %33 %35
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_sampled_arm = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x00000024, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x0000000B, 0x00000021, 0x00030010,
    0x00000004, 0x00000007, 0x00040047, 0x0000000B, 0x0000001E, 0x00000000,
    0x00040047, 0x0000001A, 0x00000021, 0x00000000, 0x00040047, 0x0000001A,
    0x00000022, 0x00000000, 0x00040047, 0x00000021, 0x0000001E, 0x00000000,
    0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002, 0x00030016,
    0x00000006, 0x00000020, 0x00040017, 0x00000007, 0x00000006, 0x00000004,
    0x00040020, 0x0000000A, 0x00000001, 0x00000007, 0x0004003B, 0x0000000A,
    0x0000000B, 0x00000001, 0x00040015, 0x0000000D, 0x00000020, 0x00000000,
    0x0004002B, 0x0000000D, 0x0000000E, 0x00000000, 0x00040020, 0x0000000F,
    0x00000001, 0x00000006, 0x0004002B, 0x00000006, 0x00000012, 0x3F000000,
    0x00020014, 0x00000013, 0x00090019, 0x00000017, 0x00000006, 0x00000001,
    0x00000000, 0x00000000, 0x00000000, 0x00000001, 0x00000000, 0x0003001B,
    0x00000018, 0x00000017, 0x00040020, 0x00000019, 0x00000000, 0x00000018,
    0x0004003B, 0x00000019, 0x0000001A, 0x00000000, 0x00040017, 0x0000001C,
    0x00000006, 0x00000002, 0x00040020, 0x00000020, 0x00000003, 0x00000007,
    0x0004003B, 0x00000020, 0x00000021, 0x00000003, 0x00050036, 0x00000002,
    0x00000004, 0x00000000, 0x00000003, 0x000200F8, 0x00000005, 0x0004003D,
    0x00000007, 0x0000000C, 0x0000000B, 0x00050041, 0x0000000F, 0x00000010,
    0x0000000B, 0x0000000E, 0x0004003D, 0x00000006, 0x00000011, 0x00000010,
    0x000500B8, 0x00000013, 0x00000014, 0x00000011, 0x00000012, 0x000300F7,
    0x00000016, 0x00000000, 0x000400FA, 0x00000014, 0x00000015, 0x00000016,
    0x000200F8, 0x00000015, 0x0004003D, 0x00000018, 0x0000001B, 0x0000001A,
    0x0007004F, 0x0000001C, 0x0000001E, 0x0000000C, 0x0000000C, 0x00000001,
    0x00000002, 0x00050057, 0x00000007, 0x0000001F, 0x0000001B, 0x0000001E,
    0x000200F9, 0x00000016, 0x000200F8, 0x00000016, 0x000700F5, 0x00000007,
    0x00000023, 0x0000000C, 0x00000005, 0x0000001F, 0x00000015, 0x0003003E,
    0x00000021, 0x00000023, 0x000100FD, 0x00010038,
};

/// glslc's own output for `glslc_branch`'s GLSL without `-O`: `c` and `k`
/// in variables of the function's own, each arm storing into floats of
/// `c` through access chains and the ternary storing into one of its
/// own, and the merges loading them back. Mesa's nir_lower_vars_to_ssa
/// makes the variables values and their merges phis, and it is the
/// optimized module again (since 1.155).
///
/// ```sh
/// glslc -fshader-stage=frag branch.frag -o branch_O0.spv   # 454 words
/// spirv-val --target-env vulkan1.0 branch_O0.spv         # no output, and 0
/// ```
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 80
/// ; Schema: 0
///                OpCapability Shader
///           %1 = OpExtInstImport "GLSL.std.450"
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %4 "main" %11 %71
///                OpExecutionMode %4 OriginUpperLeft
///                OpSource GLSL 450
///                OpSourceExtension "GL_GOOGLE_cpp_style_line_directive"
///                OpSourceExtension "GL_GOOGLE_include_directive"
///                OpName %4 "main"
///                OpName %9 "c"
///                OpName %11 "vcolor"
///                OpName %51 "k"
///                OpName %71 "ocolor"
///                OpDecorate %11 Location 0
///                OpDecorate %71 Location 0
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeFloat 32
///           %7 = OpTypeVector %6 4
///           %8 = OpTypePointer Function %7
///          %10 = OpTypePointer Input %7
///          %11 = OpVariable %10 Input
///          %13 = OpTypeInt 32 0
///          %14 = OpConstant %13 0
///          %15 = OpTypePointer Input %6
///          %18 = OpConstant %6 0.5
///          %19 = OpTypeBool
///          %23 = OpConstant %13 1
///          %26 = OpConstant %6 3
///          %31 = OpTypePointer Function %6
///          %33 = OpConstant %13 2
///          %36 = OpConstant %13 3
///          %44 = OpConstant %6 0.25
///          %60 = OpConstant %6 2
///          %62 = OpConstant %6 0.100000001
///          %70 = OpTypePointer Output %7
///          %71 = OpVariable %70 Output
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///           %9 = OpVariable %8 Function
///          %51 = OpVariable %31 Function
///          %55 = OpVariable %31 Function
///          %12 = OpLoad %7 %11
///                OpStore %9 %12
///          %16 = OpAccessChain %15 %11 %14
///          %17 = OpLoad %6 %16
///          %20 = OpFOrdLessThan %19 %17 %18
///                OpSelectionMerge %22 None
///                OpBranchConditional %20 %21 %41
///          %21 = OpLabel
///          %24 = OpAccessChain %15 %11 %23
///          %25 = OpLoad %6 %24
///          %27 = OpFMul %6 %25 %26
///          %28 = OpExtInst %6 %1 Sin %27
///          %29 = OpFMul %6 %28 %18
///          %30 = OpFAdd %6 %29 %18
///          %32 = OpAccessChain %31 %9 %14
///                OpStore %32 %30
///          %34 = OpAccessChain %15 %11 %33
///          %35 = OpLoad %6 %34
///          %37 = OpAccessChain %15 %11 %36
///          %38 = OpLoad %6 %37
///          %39 = OpFMul %6 %35 %38
///          %40 = OpAccessChain %31 %9 %23
///                OpStore %40 %39
///                OpBranch %22
///          %41 = OpLabel
///          %42 = OpAccessChain %15 %11 %23
///          %43 = OpLoad %6 %42
///          %45 = OpFMul %6 %43 %44
///          %46 = OpAccessChain %31 %9 %14
///                OpStore %46 %45
///          %47 = OpAccessChain %15 %11 %33
///          %48 = OpLoad %6 %47
///          %49 = OpExtInst %6 %1 Sqrt %48
///          %50 = OpAccessChain %31 %9 %33
///                OpStore %50 %49
///                OpBranch %22
///          %22 = OpLabel
///          %52 = OpAccessChain %15 %11 %36
///          %53 = OpLoad %6 %52
///          %54 = OpFOrdGreaterThan %19 %53 %18
///                OpSelectionMerge %57 None
///                OpBranchConditional %54 %56 %64
///          %56 = OpLabel
///          %58 = OpAccessChain %15 %11 %14
///          %59 = OpLoad %6 %58
///          %61 = OpExtInst %6 %1 Pow %59 %60
///          %63 = OpFAdd %6 %61 %62
///                OpStore %55 %63
///                OpBranch %57
///          %64 = OpLabel
///          %65 = OpAccessChain %15 %11 %23
///          %66 = OpLoad %6 %65
///          %67 = OpExtInst %6 %1 Exp2 %66
///          %68 = OpFMul %6 %67 %44
///                OpStore %55 %68
///                OpBranch %57
///          %57 = OpLabel
///          %69 = OpLoad %6 %55
///                OpStore %51 %69
///          %72 = OpAccessChain %31 %9 %14
///          %73 = OpLoad %6 %72
///          %74 = OpAccessChain %31 %9 %23
///          %75 = OpLoad %6 %74
///          %76 = OpAccessChain %31 %9 %33
///          %77 = OpLoad %6 %76
///          %78 = OpLoad %6 %51
///          %79 = OpCompositeConstruct %7 %73 %75 %77 %78
///                OpStore %71 %79
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_branch_unoptimized = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x00000050, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x0000000B, 0x00000047, 0x00030010,
    0x00000004, 0x00000007, 0x00030003, 0x00000002, 0x000001C2, 0x000A0004,
    0x475F4C47, 0x4C474F4F, 0x70635F45, 0x74735F70, 0x5F656C79, 0x656E696C,
    0x7269645F, 0x69746365, 0x00006576, 0x00080004, 0x475F4C47, 0x4C474F4F,
    0x6E695F45, 0x64756C63, 0x69645F65, 0x74636572, 0x00657669, 0x00040005,
    0x00000004, 0x6E69616D, 0x00000000, 0x00030005, 0x00000009, 0x00000063,
    0x00040005, 0x0000000B, 0x6C6F6376, 0x0000726F, 0x00030005, 0x00000033,
    0x0000006B, 0x00040005, 0x00000047, 0x6C6F636F, 0x0000726F, 0x00040047,
    0x0000000B, 0x0000001E, 0x00000000, 0x00040047, 0x00000047, 0x0000001E,
    0x00000000, 0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002,
    0x00030016, 0x00000006, 0x00000020, 0x00040017, 0x00000007, 0x00000006,
    0x00000004, 0x00040020, 0x00000008, 0x00000007, 0x00000007, 0x00040020,
    0x0000000A, 0x00000001, 0x00000007, 0x0004003B, 0x0000000A, 0x0000000B,
    0x00000001, 0x00040015, 0x0000000D, 0x00000020, 0x00000000, 0x0004002B,
    0x0000000D, 0x0000000E, 0x00000000, 0x00040020, 0x0000000F, 0x00000001,
    0x00000006, 0x0004002B, 0x00000006, 0x00000012, 0x3F000000, 0x00020014,
    0x00000013, 0x0004002B, 0x0000000D, 0x00000017, 0x00000001, 0x0004002B,
    0x00000006, 0x0000001A, 0x40400000, 0x00040020, 0x0000001F, 0x00000007,
    0x00000006, 0x0004002B, 0x0000000D, 0x00000021, 0x00000002, 0x0004002B,
    0x0000000D, 0x00000024, 0x00000003, 0x0004002B, 0x00000006, 0x0000002C,
    0x3E800000, 0x0004002B, 0x00000006, 0x0000003C, 0x40000000, 0x0004002B,
    0x00000006, 0x0000003E, 0x3DCCCCCD, 0x00040020, 0x00000046, 0x00000003,
    0x00000007, 0x0004003B, 0x00000046, 0x00000047, 0x00000003, 0x00050036,
    0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200F8, 0x00000005,
    0x0004003B, 0x00000008, 0x00000009, 0x00000007, 0x0004003B, 0x0000001F,
    0x00000033, 0x00000007, 0x0004003B, 0x0000001F, 0x00000037, 0x00000007,
    0x0004003D, 0x00000007, 0x0000000C, 0x0000000B, 0x0003003E, 0x00000009,
    0x0000000C, 0x00050041, 0x0000000F, 0x00000010, 0x0000000B, 0x0000000E,
    0x0004003D, 0x00000006, 0x00000011, 0x00000010, 0x000500B8, 0x00000013,
    0x00000014, 0x00000011, 0x00000012, 0x000300F7, 0x00000016, 0x00000000,
    0x000400FA, 0x00000014, 0x00000015, 0x00000029, 0x000200F8, 0x00000015,
    0x00050041, 0x0000000F, 0x00000018, 0x0000000B, 0x00000017, 0x0004003D,
    0x00000006, 0x00000019, 0x00000018, 0x00050085, 0x00000006, 0x0000001B,
    0x00000019, 0x0000001A, 0x0006000C, 0x00000006, 0x0000001C, 0x00000001,
    0x0000000D, 0x0000001B, 0x00050085, 0x00000006, 0x0000001D, 0x0000001C,
    0x00000012, 0x00050081, 0x00000006, 0x0000001E, 0x0000001D, 0x00000012,
    0x00050041, 0x0000001F, 0x00000020, 0x00000009, 0x0000000E, 0x0003003E,
    0x00000020, 0x0000001E, 0x00050041, 0x0000000F, 0x00000022, 0x0000000B,
    0x00000021, 0x0004003D, 0x00000006, 0x00000023, 0x00000022, 0x00050041,
    0x0000000F, 0x00000025, 0x0000000B, 0x00000024, 0x0004003D, 0x00000006,
    0x00000026, 0x00000025, 0x00050085, 0x00000006, 0x00000027, 0x00000023,
    0x00000026, 0x00050041, 0x0000001F, 0x00000028, 0x00000009, 0x00000017,
    0x0003003E, 0x00000028, 0x00000027, 0x000200F9, 0x00000016, 0x000200F8,
    0x00000029, 0x00050041, 0x0000000F, 0x0000002A, 0x0000000B, 0x00000017,
    0x0004003D, 0x00000006, 0x0000002B, 0x0000002A, 0x00050085, 0x00000006,
    0x0000002D, 0x0000002B, 0x0000002C, 0x00050041, 0x0000001F, 0x0000002E,
    0x00000009, 0x0000000E, 0x0003003E, 0x0000002E, 0x0000002D, 0x00050041,
    0x0000000F, 0x0000002F, 0x0000000B, 0x00000021, 0x0004003D, 0x00000006,
    0x00000030, 0x0000002F, 0x0006000C, 0x00000006, 0x00000031, 0x00000001,
    0x0000001F, 0x00000030, 0x00050041, 0x0000001F, 0x00000032, 0x00000009,
    0x00000021, 0x0003003E, 0x00000032, 0x00000031, 0x000200F9, 0x00000016,
    0x000200F8, 0x00000016, 0x00050041, 0x0000000F, 0x00000034, 0x0000000B,
    0x00000024, 0x0004003D, 0x00000006, 0x00000035, 0x00000034, 0x000500BA,
    0x00000013, 0x00000036, 0x00000035, 0x00000012, 0x000300F7, 0x00000039,
    0x00000000, 0x000400FA, 0x00000036, 0x00000038, 0x00000040, 0x000200F8,
    0x00000038, 0x00050041, 0x0000000F, 0x0000003A, 0x0000000B, 0x0000000E,
    0x0004003D, 0x00000006, 0x0000003B, 0x0000003A, 0x0007000C, 0x00000006,
    0x0000003D, 0x00000001, 0x0000001A, 0x0000003B, 0x0000003C, 0x00050081,
    0x00000006, 0x0000003F, 0x0000003D, 0x0000003E, 0x0003003E, 0x00000037,
    0x0000003F, 0x000200F9, 0x00000039, 0x000200F8, 0x00000040, 0x00050041,
    0x0000000F, 0x00000041, 0x0000000B, 0x00000017, 0x0004003D, 0x00000006,
    0x00000042, 0x00000041, 0x0006000C, 0x00000006, 0x00000043, 0x00000001,
    0x0000001D, 0x00000042, 0x00050085, 0x00000006, 0x00000044, 0x00000043,
    0x0000002C, 0x0003003E, 0x00000037, 0x00000044, 0x000200F9, 0x00000039,
    0x000200F8, 0x00000039, 0x0004003D, 0x00000006, 0x00000045, 0x00000037,
    0x0003003E, 0x00000033, 0x00000045, 0x00050041, 0x0000001F, 0x00000048,
    0x00000009, 0x0000000E, 0x0004003D, 0x00000006, 0x00000049, 0x00000048,
    0x00050041, 0x0000001F, 0x0000004A, 0x00000009, 0x00000017, 0x0004003D,
    0x00000006, 0x0000004B, 0x0000004A, 0x00050041, 0x0000001F, 0x0000004C,
    0x00000009, 0x00000021, 0x0004003D, 0x00000006, 0x0000004D, 0x0000004C,
    0x0004003D, 0x00000006, 0x0000004E, 0x00000033, 0x00070050, 0x00000007,
    0x0000004F, 0x00000049, 0x0000004B, 0x0000004D, 0x0000004E, 0x0003003E,
    0x00000047, 0x0000004F, 0x000100FD, 0x00010038,
};

/// glslc's own output for `glslc_cutout`'s GLSL without `-O`: `texel`
/// in a variable of the function's own, its alpha loaded through an
/// access chain into it, and the colour loaded from it after the
/// conditional discard (since 1.155).
///
/// ```sh
/// glslc -fshader-stage=frag cutout.frag -o cutout_O0.spv   # 217 words
/// spirv-val --target-env vulkan1.0 cutout_O0.spv         # no output, and 0
/// ```
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 34
/// ; Schema: 0
///                OpCapability Shader
///           %1 = OpExtInstImport "GLSL.std.450"
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %4 "main" %17 %32
///                OpExecutionMode %4 OriginUpperLeft
///                OpSource GLSL 450
///                OpSourceExtension "GL_GOOGLE_cpp_style_line_directive"
///                OpSourceExtension "GL_GOOGLE_include_directive"
///                OpName %4 "main"
///                OpName %9 "texel"
///                OpName %13 "tex"
///                OpName %17 "uv"
///                OpName %32 "ocolor"
///                OpDecorate %13 Binding 0
///                OpDecorate %13 DescriptorSet 0
///                OpDecorate %17 Location 0
///                OpDecorate %32 Location 0
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeFloat 32
///           %7 = OpTypeVector %6 4
///           %8 = OpTypePointer Function %7
///          %10 = OpTypeImage %6 2D 0 0 0 1 Unknown
///          %11 = OpTypeSampledImage %10
///          %12 = OpTypePointer UniformConstant %11
///          %13 = OpVariable %12 UniformConstant
///          %15 = OpTypeVector %6 2
///          %16 = OpTypePointer Input %15
///          %17 = OpVariable %16 Input
///          %20 = OpTypeInt 32 0
///          %21 = OpConstant %20 3
///          %22 = OpTypePointer Function %6
///          %25 = OpConstant %6 0.5
///          %26 = OpTypeBool
///          %31 = OpTypePointer Output %7
///          %32 = OpVariable %31 Output
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///           %9 = OpVariable %8 Function
///          %14 = OpLoad %11 %13
///          %18 = OpLoad %15 %17
///          %19 = OpImageSampleImplicitLod %7 %14 %18
///                OpStore %9 %19
///          %23 = OpAccessChain %22 %9 %21
///          %24 = OpLoad %6 %23
///          %27 = OpFOrdLessThan %26 %24 %25
///                OpSelectionMerge %29 None
///                OpBranchConditional %27 %28 %29
///          %28 = OpLabel
///                OpKill
///          %29 = OpLabel
///          %33 = OpLoad %7 %9
///                OpStore %32 %33
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_cutout_unoptimized = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x00000022, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x00000011, 0x00000020, 0x00030010,
    0x00000004, 0x00000007, 0x00030003, 0x00000002, 0x000001C2, 0x000A0004,
    0x475F4C47, 0x4C474F4F, 0x70635F45, 0x74735F70, 0x5F656C79, 0x656E696C,
    0x7269645F, 0x69746365, 0x00006576, 0x00080004, 0x475F4C47, 0x4C474F4F,
    0x6E695F45, 0x64756C63, 0x69645F65, 0x74636572, 0x00657669, 0x00040005,
    0x00000004, 0x6E69616D, 0x00000000, 0x00040005, 0x00000009, 0x65786574,
    0x0000006C, 0x00030005, 0x0000000D, 0x00786574, 0x00030005, 0x00000011,
    0x00007675, 0x00040005, 0x00000020, 0x6C6F636F, 0x0000726F, 0x00040047,
    0x0000000D, 0x00000021, 0x00000000, 0x00040047, 0x0000000D, 0x00000022,
    0x00000000, 0x00040047, 0x00000011, 0x0000001E, 0x00000000, 0x00040047,
    0x00000020, 0x0000001E, 0x00000000, 0x00020013, 0x00000002, 0x00030021,
    0x00000003, 0x00000002, 0x00030016, 0x00000006, 0x00000020, 0x00040017,
    0x00000007, 0x00000006, 0x00000004, 0x00040020, 0x00000008, 0x00000007,
    0x00000007, 0x00090019, 0x0000000A, 0x00000006, 0x00000001, 0x00000000,
    0x00000000, 0x00000000, 0x00000001, 0x00000000, 0x0003001B, 0x0000000B,
    0x0000000A, 0x00040020, 0x0000000C, 0x00000000, 0x0000000B, 0x0004003B,
    0x0000000C, 0x0000000D, 0x00000000, 0x00040017, 0x0000000F, 0x00000006,
    0x00000002, 0x00040020, 0x00000010, 0x00000001, 0x0000000F, 0x0004003B,
    0x00000010, 0x00000011, 0x00000001, 0x00040015, 0x00000014, 0x00000020,
    0x00000000, 0x0004002B, 0x00000014, 0x00000015, 0x00000003, 0x00040020,
    0x00000016, 0x00000007, 0x00000006, 0x0004002B, 0x00000006, 0x00000019,
    0x3F000000, 0x00020014, 0x0000001A, 0x00040020, 0x0000001F, 0x00000003,
    0x00000007, 0x0004003B, 0x0000001F, 0x00000020, 0x00000003, 0x00050036,
    0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200F8, 0x00000005,
    0x0004003B, 0x00000008, 0x00000009, 0x00000007, 0x0004003D, 0x0000000B,
    0x0000000E, 0x0000000D, 0x0004003D, 0x0000000F, 0x00000012, 0x00000011,
    0x00050057, 0x00000007, 0x00000013, 0x0000000E, 0x00000012, 0x0003003E,
    0x00000009, 0x00000013, 0x00050041, 0x00000016, 0x00000017, 0x00000009,
    0x00000015, 0x0004003D, 0x00000006, 0x00000018, 0x00000017, 0x000500B8,
    0x0000001A, 0x0000001B, 0x00000018, 0x00000019, 0x000300F7, 0x0000001D,
    0x00000000, 0x000400FA, 0x0000001B, 0x0000001C, 0x0000001D, 0x000200F8,
    0x0000001C, 0x000100FC, 0x000200F8, 0x0000001D, 0x0004003D, 0x00000007,
    0x00000021, 0x00000009, 0x0003003E, 0x00000020, 0x00000021, 0x000100FD,
    0x00010038,
};

/// glslc's own output, at `-O`, for selections nested in others' arms: an
/// `else if`, the inner selection in the outer one's false arm, and an
/// `if` and `else` in the true arm of one with no false arm, work after it
/// in the inner merge block. Each outer arm ends in the inner merge block,
/// which its phi names. Mesa flattens the inner first, then the outer
/// (since 1.156).
///
/// ```glsl
/// #version 450
/// layout(location = 0) in vec4 vcolor;
/// layout(location = 0) out vec4 ocolor;
/// void main() {
///     vec4 c = vcolor;
///     if (vcolor.x < 0.25) {
///         c.r = vcolor.y * 2.0;
///     } else if (vcolor.x < 0.5) {
///         c.g = sin(vcolor.z * 3.0);
///         c.r = 0.5;
///     } else {
///         c.b = vcolor.w + 0.125;
///     }
///     float k = vcolor.z;
///     if (vcolor.w > 0.5) {
///         if (vcolor.y > 0.5) {
///             k = vcolor.x * vcolor.y;
///         } else {
///             k = exp2(vcolor.y);
///         }
///         k = k * 0.5 + 0.25;
///     }
///     ocolor = vec4(c.rgb, k);
/// }
/// ```
///
/// ```sh
/// glslc -O -fshader-stage=frag nested.frag -o nested.spv   # 387 words
/// spirv-val --target-env vulkan1.0 nested.spv            # no output, and 0
/// ```
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 101
/// ; Schema: 0
///                OpCapability Shader
///           %1 = OpExtInstImport "GLSL.std.450"
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %4 "main" %11 %78
///                OpExecutionMode %4 OriginUpperLeft
///                OpDecorate %11 Location 0
///                OpDecorate %78 Location 0
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeFloat 32
///           %7 = OpTypeVector %6 4
///          %10 = OpTypePointer Input %7
///          %11 = OpVariable %10 Input
///          %13 = OpTypeInt 32 0
///          %14 = OpConstant %13 0
///          %15 = OpTypePointer Input %6
///          %18 = OpConstant %6 0.25
///          %19 = OpTypeBool
///          %23 = OpConstant %13 1
///          %26 = OpConstant %6 2
///          %33 = OpConstant %6 0.5
///          %37 = OpConstant %13 2
///          %40 = OpConstant %6 3
///          %46 = OpConstant %13 3
///          %49 = OpConstant %6 0.125
///          %77 = OpTypePointer Output %7
///          %78 = OpVariable %77 Output
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///          %12 = OpLoad %7 %11
///          %16 = OpAccessChain %15 %11 %14
///          %17 = OpLoad %6 %16
///          %20 = OpFOrdLessThan %19 %17 %18
///                OpSelectionMerge %22 None
///                OpBranchConditional %20 %21 %30
///          %21 = OpLabel
///          %24 = OpAccessChain %15 %11 %23
///          %25 = OpLoad %6 %24
///          %27 = OpFMul %6 %25 %26
///          %88 = OpCompositeInsert %7 %27 %12 0
///                OpBranch %22
///          %30 = OpLabel
///          %34 = OpFOrdLessThan %19 %17 %33
///                OpSelectionMerge %36 None
///                OpBranchConditional %34 %35 %45
///          %35 = OpLabel
///          %38 = OpAccessChain %15 %11 %37
///          %39 = OpLoad %6 %38
///          %41 = OpFMul %6 %39 %40
///          %42 = OpExtInst %6 %1 Sin %41
///          %90 = OpCompositeInsert %7 %42 %12 1
///          %92 = OpCompositeInsert %7 %33 %90 0
///                OpBranch %36
///          %45 = OpLabel
///          %47 = OpAccessChain %15 %11 %46
///          %48 = OpLoad %6 %47
///          %50 = OpFAdd %6 %48 %49
///          %94 = OpCompositeInsert %7 %50 %12 2
///                OpBranch %36
///          %36 = OpLabel
///          %98 = OpPhi %7 %92 %35 %94 %45
///                OpBranch %22
///          %22 = OpLabel
///          %97 = OpPhi %7 %88 %21 %98 %36
///          %53 = OpAccessChain %15 %11 %37
///          %54 = OpLoad %6 %53
///          %55 = OpAccessChain %15 %11 %46
///          %56 = OpLoad %6 %55
///          %57 = OpFOrdGreaterThan %19 %56 %33
///                OpSelectionMerge %59 None
///                OpBranchConditional %57 %58 %59
///          %58 = OpLabel
///          %60 = OpAccessChain %15 %11 %23
///          %61 = OpLoad %6 %60
///          %62 = OpFOrdGreaterThan %19 %61 %33
///                OpSelectionMerge %64 None
///                OpBranchConditional %62 %63 %70
///          %63 = OpLabel
///          %69 = OpFMul %6 %17 %61
///                OpBranch %64
///          %70 = OpLabel
///          %73 = OpExtInst %6 %1 Exp2 %61
///                OpBranch %64
///          %64 = OpLabel
///          %95 = OpPhi %6 %69 %63 %73 %70
///          %75 = OpFMul %6 %95 %33
///          %76 = OpFAdd %6 %75 %18
///                OpBranch %59
///          %59 = OpLabel
///         %100 = OpPhi %6 %54 %22 %76 %64
///          %83 = OpCompositeExtract %6 %97 0
///          %84 = OpCompositeExtract %6 %97 1
///          %85 = OpCompositeExtract %6 %97 2
///          %86 = OpCompositeConstruct %7 %83 %84 %85 %100
///                OpStore %78 %86
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_nested = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x00000065, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x0000000B, 0x0000004E, 0x00030010,
    0x00000004, 0x00000007, 0x00040047, 0x0000000B, 0x0000001E, 0x00000000,
    0x00040047, 0x0000004E, 0x0000001E, 0x00000000, 0x00020013, 0x00000002,
    0x00030021, 0x00000003, 0x00000002, 0x00030016, 0x00000006, 0x00000020,
    0x00040017, 0x00000007, 0x00000006, 0x00000004, 0x00040020, 0x0000000A,
    0x00000001, 0x00000007, 0x0004003B, 0x0000000A, 0x0000000B, 0x00000001,
    0x00040015, 0x0000000D, 0x00000020, 0x00000000, 0x0004002B, 0x0000000D,
    0x0000000E, 0x00000000, 0x00040020, 0x0000000F, 0x00000001, 0x00000006,
    0x0004002B, 0x00000006, 0x00000012, 0x3E800000, 0x00020014, 0x00000013,
    0x0004002B, 0x0000000D, 0x00000017, 0x00000001, 0x0004002B, 0x00000006,
    0x0000001A, 0x40000000, 0x0004002B, 0x00000006, 0x00000021, 0x3F000000,
    0x0004002B, 0x0000000D, 0x00000025, 0x00000002, 0x0004002B, 0x00000006,
    0x00000028, 0x40400000, 0x0004002B, 0x0000000D, 0x0000002E, 0x00000003,
    0x0004002B, 0x00000006, 0x00000031, 0x3E000000, 0x00040020, 0x0000004D,
    0x00000003, 0x00000007, 0x0004003B, 0x0000004D, 0x0000004E, 0x00000003,
    0x00050036, 0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200F8,
    0x00000005, 0x0004003D, 0x00000007, 0x0000000C, 0x0000000B, 0x00050041,
    0x0000000F, 0x00000010, 0x0000000B, 0x0000000E, 0x0004003D, 0x00000006,
    0x00000011, 0x00000010, 0x000500B8, 0x00000013, 0x00000014, 0x00000011,
    0x00000012, 0x000300F7, 0x00000016, 0x00000000, 0x000400FA, 0x00000014,
    0x00000015, 0x0000001E, 0x000200F8, 0x00000015, 0x00050041, 0x0000000F,
    0x00000018, 0x0000000B, 0x00000017, 0x0004003D, 0x00000006, 0x00000019,
    0x00000018, 0x00050085, 0x00000006, 0x0000001B, 0x00000019, 0x0000001A,
    0x00060052, 0x00000007, 0x00000058, 0x0000001B, 0x0000000C, 0x00000000,
    0x000200F9, 0x00000016, 0x000200F8, 0x0000001E, 0x000500B8, 0x00000013,
    0x00000022, 0x00000011, 0x00000021, 0x000300F7, 0x00000024, 0x00000000,
    0x000400FA, 0x00000022, 0x00000023, 0x0000002D, 0x000200F8, 0x00000023,
    0x00050041, 0x0000000F, 0x00000026, 0x0000000B, 0x00000025, 0x0004003D,
    0x00000006, 0x00000027, 0x00000026, 0x00050085, 0x00000006, 0x00000029,
    0x00000027, 0x00000028, 0x0006000C, 0x00000006, 0x0000002A, 0x00000001,
    0x0000000D, 0x00000029, 0x00060052, 0x00000007, 0x0000005A, 0x0000002A,
    0x0000000C, 0x00000001, 0x00060052, 0x00000007, 0x0000005C, 0x00000021,
    0x0000005A, 0x00000000, 0x000200F9, 0x00000024, 0x000200F8, 0x0000002D,
    0x00050041, 0x0000000F, 0x0000002F, 0x0000000B, 0x0000002E, 0x0004003D,
    0x00000006, 0x00000030, 0x0000002F, 0x00050081, 0x00000006, 0x00000032,
    0x00000030, 0x00000031, 0x00060052, 0x00000007, 0x0000005E, 0x00000032,
    0x0000000C, 0x00000002, 0x000200F9, 0x00000024, 0x000200F8, 0x00000024,
    0x000700F5, 0x00000007, 0x00000062, 0x0000005C, 0x00000023, 0x0000005E,
    0x0000002D, 0x000200F9, 0x00000016, 0x000200F8, 0x00000016, 0x000700F5,
    0x00000007, 0x00000061, 0x00000058, 0x00000015, 0x00000062, 0x00000024,
    0x00050041, 0x0000000F, 0x00000035, 0x0000000B, 0x00000025, 0x0004003D,
    0x00000006, 0x00000036, 0x00000035, 0x00050041, 0x0000000F, 0x00000037,
    0x0000000B, 0x0000002E, 0x0004003D, 0x00000006, 0x00000038, 0x00000037,
    0x000500BA, 0x00000013, 0x00000039, 0x00000038, 0x00000021, 0x000300F7,
    0x0000003B, 0x00000000, 0x000400FA, 0x00000039, 0x0000003A, 0x0000003B,
    0x000200F8, 0x0000003A, 0x00050041, 0x0000000F, 0x0000003C, 0x0000000B,
    0x00000017, 0x0004003D, 0x00000006, 0x0000003D, 0x0000003C, 0x000500BA,
    0x00000013, 0x0000003E, 0x0000003D, 0x00000021, 0x000300F7, 0x00000040,
    0x00000000, 0x000400FA, 0x0000003E, 0x0000003F, 0x00000046, 0x000200F8,
    0x0000003F, 0x00050085, 0x00000006, 0x00000045, 0x00000011, 0x0000003D,
    0x000200F9, 0x00000040, 0x000200F8, 0x00000046, 0x0006000C, 0x00000006,
    0x00000049, 0x00000001, 0x0000001D, 0x0000003D, 0x000200F9, 0x00000040,
    0x000200F8, 0x00000040, 0x000700F5, 0x00000006, 0x0000005F, 0x00000045,
    0x0000003F, 0x00000049, 0x00000046, 0x00050085, 0x00000006, 0x0000004B,
    0x0000005F, 0x00000021, 0x00050081, 0x00000006, 0x0000004C, 0x0000004B,
    0x00000012, 0x000200F9, 0x0000003B, 0x000200F8, 0x0000003B, 0x000700F5,
    0x00000006, 0x00000064, 0x00000036, 0x00000016, 0x0000004C, 0x00000040,
    0x00050051, 0x00000006, 0x00000053, 0x00000061, 0x00000000, 0x00050051,
    0x00000006, 0x00000054, 0x00000061, 0x00000001, 0x00050051, 0x00000006,
    0x00000055, 0x00000061, 0x00000002, 0x00070050, 0x00000007, 0x00000056,
    0x00000053, 0x00000054, 0x00000055, 0x00000064, 0x0003003E, 0x0000004E,
    0x00000056, 0x000100FD, 0x00010038,
};

/// glslc's own output for `glslc_nested`'s GLSL without `-O`: `c` and `k`
/// in variables of the function's own, stored in the arms and loaded past
/// the merges (since 1.156).
///
/// ```sh
/// glslc -fshader-stage=frag nested.frag -o nested_O0.spv   # 497 words
/// spirv-val --target-env vulkan1.0 nested_O0.spv         # no output, and 0
/// ```
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 87
/// ; Schema: 0
///                OpCapability Shader
///           %1 = OpExtInstImport "GLSL.std.450"
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %4 "main" %11 %78
///                OpExecutionMode %4 OriginUpperLeft
///                OpSource GLSL 450
///                OpSourceExtension "GL_GOOGLE_cpp_style_line_directive"
///                OpSourceExtension "GL_GOOGLE_include_directive"
///                OpName %4 "main"
///                OpName %9 "c"
///                OpName %11 "vcolor"
///                OpName %52 "k"
///                OpName %78 "ocolor"
///                OpDecorate %11 Location 0
///                OpDecorate %78 Location 0
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeFloat 32
///           %7 = OpTypeVector %6 4
///           %8 = OpTypePointer Function %7
///          %10 = OpTypePointer Input %7
///          %11 = OpVariable %10 Input
///          %13 = OpTypeInt 32 0
///          %14 = OpConstant %13 0
///          %15 = OpTypePointer Input %6
///          %18 = OpConstant %6 0.25
///          %19 = OpTypeBool
///          %23 = OpConstant %13 1
///          %26 = OpConstant %6 2
///          %28 = OpTypePointer Function %6
///          %33 = OpConstant %6 0.5
///          %37 = OpConstant %13 2
///          %40 = OpConstant %6 3
///          %46 = OpConstant %13 3
///          %49 = OpConstant %6 0.125
///          %77 = OpTypePointer Output %7
///          %78 = OpVariable %77 Output
///          %79 = OpTypeVector %6 3
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///           %9 = OpVariable %8 Function
///          %52 = OpVariable %28 Function
///          %12 = OpLoad %7 %11
///                OpStore %9 %12
///          %16 = OpAccessChain %15 %11 %14
///          %17 = OpLoad %6 %16
///          %20 = OpFOrdLessThan %19 %17 %18
///                OpSelectionMerge %22 None
///                OpBranchConditional %20 %21 %30
///          %21 = OpLabel
///          %24 = OpAccessChain %15 %11 %23
///          %25 = OpLoad %6 %24
///          %27 = OpFMul %6 %25 %26
///          %29 = OpAccessChain %28 %9 %14
///                OpStore %29 %27
///                OpBranch %22
///          %30 = OpLabel
///          %31 = OpAccessChain %15 %11 %14
///          %32 = OpLoad %6 %31
///          %34 = OpFOrdLessThan %19 %32 %33
///                OpSelectionMerge %36 None
///                OpBranchConditional %34 %35 %45
///          %35 = OpLabel
///          %38 = OpAccessChain %15 %11 %37
///          %39 = OpLoad %6 %38
///          %41 = OpFMul %6 %39 %40
///          %42 = OpExtInst %6 %1 Sin %41
///          %43 = OpAccessChain %28 %9 %23
///                OpStore %43 %42
///          %44 = OpAccessChain %28 %9 %14
///                OpStore %44 %33
///                OpBranch %36
///          %45 = OpLabel
///          %47 = OpAccessChain %15 %11 %46
///          %48 = OpLoad %6 %47
///          %50 = OpFAdd %6 %48 %49
///          %51 = OpAccessChain %28 %9 %37
///                OpStore %51 %50
///                OpBranch %36
///          %36 = OpLabel
///                OpBranch %22
///          %22 = OpLabel
///          %53 = OpAccessChain %15 %11 %37
///          %54 = OpLoad %6 %53
///                OpStore %52 %54
///          %55 = OpAccessChain %15 %11 %46
///          %56 = OpLoad %6 %55
///          %57 = OpFOrdGreaterThan %19 %56 %33
///                OpSelectionMerge %59 None
///                OpBranchConditional %57 %58 %59
///          %58 = OpLabel
///          %60 = OpAccessChain %15 %11 %23
///          %61 = OpLoad %6 %60
///          %62 = OpFOrdGreaterThan %19 %61 %33
///                OpSelectionMerge %64 None
///                OpBranchConditional %62 %63 %70
///          %63 = OpLabel
///          %65 = OpAccessChain %15 %11 %14
///          %66 = OpLoad %6 %65
///          %67 = OpAccessChain %15 %11 %23
///          %68 = OpLoad %6 %67
///          %69 = OpFMul %6 %66 %68
///                OpStore %52 %69
///                OpBranch %64
///          %70 = OpLabel
///          %71 = OpAccessChain %15 %11 %23
///          %72 = OpLoad %6 %71
///          %73 = OpExtInst %6 %1 Exp2 %72
///                OpStore %52 %73
///                OpBranch %64
///          %64 = OpLabel
///          %74 = OpLoad %6 %52
///          %75 = OpFMul %6 %74 %33
///          %76 = OpFAdd %6 %75 %18
///                OpStore %52 %76
///                OpBranch %59
///          %59 = OpLabel
///          %80 = OpLoad %7 %9
///          %81 = OpVectorShuffle %79 %80 %80 0 1 2
///          %82 = OpLoad %6 %52
///          %83 = OpCompositeExtract %6 %81 0
///          %84 = OpCompositeExtract %6 %81 1
///          %85 = OpCompositeExtract %6 %81 2
///          %86 = OpCompositeConstruct %7 %83 %84 %85 %82
///                OpStore %78 %86
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_nested_unoptimized = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x00000057, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x0000000B, 0x0000004E, 0x00030010,
    0x00000004, 0x00000007, 0x00030003, 0x00000002, 0x000001C2, 0x000A0004,
    0x475F4C47, 0x4C474F4F, 0x70635F45, 0x74735F70, 0x5F656C79, 0x656E696C,
    0x7269645F, 0x69746365, 0x00006576, 0x00080004, 0x475F4C47, 0x4C474F4F,
    0x6E695F45, 0x64756C63, 0x69645F65, 0x74636572, 0x00657669, 0x00040005,
    0x00000004, 0x6E69616D, 0x00000000, 0x00030005, 0x00000009, 0x00000063,
    0x00040005, 0x0000000B, 0x6C6F6376, 0x0000726F, 0x00030005, 0x00000034,
    0x0000006B, 0x00040005, 0x0000004E, 0x6C6F636F, 0x0000726F, 0x00040047,
    0x0000000B, 0x0000001E, 0x00000000, 0x00040047, 0x0000004E, 0x0000001E,
    0x00000000, 0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002,
    0x00030016, 0x00000006, 0x00000020, 0x00040017, 0x00000007, 0x00000006,
    0x00000004, 0x00040020, 0x00000008, 0x00000007, 0x00000007, 0x00040020,
    0x0000000A, 0x00000001, 0x00000007, 0x0004003B, 0x0000000A, 0x0000000B,
    0x00000001, 0x00040015, 0x0000000D, 0x00000020, 0x00000000, 0x0004002B,
    0x0000000D, 0x0000000E, 0x00000000, 0x00040020, 0x0000000F, 0x00000001,
    0x00000006, 0x0004002B, 0x00000006, 0x00000012, 0x3E800000, 0x00020014,
    0x00000013, 0x0004002B, 0x0000000D, 0x00000017, 0x00000001, 0x0004002B,
    0x00000006, 0x0000001A, 0x40000000, 0x00040020, 0x0000001C, 0x00000007,
    0x00000006, 0x0004002B, 0x00000006, 0x00000021, 0x3F000000, 0x0004002B,
    0x0000000D, 0x00000025, 0x00000002, 0x0004002B, 0x00000006, 0x00000028,
    0x40400000, 0x0004002B, 0x0000000D, 0x0000002E, 0x00000003, 0x0004002B,
    0x00000006, 0x00000031, 0x3E000000, 0x00040020, 0x0000004D, 0x00000003,
    0x00000007, 0x0004003B, 0x0000004D, 0x0000004E, 0x00000003, 0x00040017,
    0x0000004F, 0x00000006, 0x00000003, 0x00050036, 0x00000002, 0x00000004,
    0x00000000, 0x00000003, 0x000200F8, 0x00000005, 0x0004003B, 0x00000008,
    0x00000009, 0x00000007, 0x0004003B, 0x0000001C, 0x00000034, 0x00000007,
    0x0004003D, 0x00000007, 0x0000000C, 0x0000000B, 0x0003003E, 0x00000009,
    0x0000000C, 0x00050041, 0x0000000F, 0x00000010, 0x0000000B, 0x0000000E,
    0x0004003D, 0x00000006, 0x00000011, 0x00000010, 0x000500B8, 0x00000013,
    0x00000014, 0x00000011, 0x00000012, 0x000300F7, 0x00000016, 0x00000000,
    0x000400FA, 0x00000014, 0x00000015, 0x0000001E, 0x000200F8, 0x00000015,
    0x00050041, 0x0000000F, 0x00000018, 0x0000000B, 0x00000017, 0x0004003D,
    0x00000006, 0x00000019, 0x00000018, 0x00050085, 0x00000006, 0x0000001B,
    0x00000019, 0x0000001A, 0x00050041, 0x0000001C, 0x0000001D, 0x00000009,
    0x0000000E, 0x0003003E, 0x0000001D, 0x0000001B, 0x000200F9, 0x00000016,
    0x000200F8, 0x0000001E, 0x00050041, 0x0000000F, 0x0000001F, 0x0000000B,
    0x0000000E, 0x0004003D, 0x00000006, 0x00000020, 0x0000001F, 0x000500B8,
    0x00000013, 0x00000022, 0x00000020, 0x00000021, 0x000300F7, 0x00000024,
    0x00000000, 0x000400FA, 0x00000022, 0x00000023, 0x0000002D, 0x000200F8,
    0x00000023, 0x00050041, 0x0000000F, 0x00000026, 0x0000000B, 0x00000025,
    0x0004003D, 0x00000006, 0x00000027, 0x00000026, 0x00050085, 0x00000006,
    0x00000029, 0x00000027, 0x00000028, 0x0006000C, 0x00000006, 0x0000002A,
    0x00000001, 0x0000000D, 0x00000029, 0x00050041, 0x0000001C, 0x0000002B,
    0x00000009, 0x00000017, 0x0003003E, 0x0000002B, 0x0000002A, 0x00050041,
    0x0000001C, 0x0000002C, 0x00000009, 0x0000000E, 0x0003003E, 0x0000002C,
    0x00000021, 0x000200F9, 0x00000024, 0x000200F8, 0x0000002D, 0x00050041,
    0x0000000F, 0x0000002F, 0x0000000B, 0x0000002E, 0x0004003D, 0x00000006,
    0x00000030, 0x0000002F, 0x00050081, 0x00000006, 0x00000032, 0x00000030,
    0x00000031, 0x00050041, 0x0000001C, 0x00000033, 0x00000009, 0x00000025,
    0x0003003E, 0x00000033, 0x00000032, 0x000200F9, 0x00000024, 0x000200F8,
    0x00000024, 0x000200F9, 0x00000016, 0x000200F8, 0x00000016, 0x00050041,
    0x0000000F, 0x00000035, 0x0000000B, 0x00000025, 0x0004003D, 0x00000006,
    0x00000036, 0x00000035, 0x0003003E, 0x00000034, 0x00000036, 0x00050041,
    0x0000000F, 0x00000037, 0x0000000B, 0x0000002E, 0x0004003D, 0x00000006,
    0x00000038, 0x00000037, 0x000500BA, 0x00000013, 0x00000039, 0x00000038,
    0x00000021, 0x000300F7, 0x0000003B, 0x00000000, 0x000400FA, 0x00000039,
    0x0000003A, 0x0000003B, 0x000200F8, 0x0000003A, 0x00050041, 0x0000000F,
    0x0000003C, 0x0000000B, 0x00000017, 0x0004003D, 0x00000006, 0x0000003D,
    0x0000003C, 0x000500BA, 0x00000013, 0x0000003E, 0x0000003D, 0x00000021,
    0x000300F7, 0x00000040, 0x00000000, 0x000400FA, 0x0000003E, 0x0000003F,
    0x00000046, 0x000200F8, 0x0000003F, 0x00050041, 0x0000000F, 0x00000041,
    0x0000000B, 0x0000000E, 0x0004003D, 0x00000006, 0x00000042, 0x00000041,
    0x00050041, 0x0000000F, 0x00000043, 0x0000000B, 0x00000017, 0x0004003D,
    0x00000006, 0x00000044, 0x00000043, 0x00050085, 0x00000006, 0x00000045,
    0x00000042, 0x00000044, 0x0003003E, 0x00000034, 0x00000045, 0x000200F9,
    0x00000040, 0x000200F8, 0x00000046, 0x00050041, 0x0000000F, 0x00000047,
    0x0000000B, 0x00000017, 0x0004003D, 0x00000006, 0x00000048, 0x00000047,
    0x0006000C, 0x00000006, 0x00000049, 0x00000001, 0x0000001D, 0x00000048,
    0x0003003E, 0x00000034, 0x00000049, 0x000200F9, 0x00000040, 0x000200F8,
    0x00000040, 0x0004003D, 0x00000006, 0x0000004A, 0x00000034, 0x00050085,
    0x00000006, 0x0000004B, 0x0000004A, 0x00000021, 0x00050081, 0x00000006,
    0x0000004C, 0x0000004B, 0x00000012, 0x0003003E, 0x00000034, 0x0000004C,
    0x000200F9, 0x0000003B, 0x000200F8, 0x0000003B, 0x0004003D, 0x00000007,
    0x00000050, 0x00000009, 0x0008004F, 0x0000004F, 0x00000051, 0x00000050,
    0x00000050, 0x00000000, 0x00000001, 0x00000002, 0x0004003D, 0x00000006,
    0x00000052, 0x00000034, 0x00050051, 0x00000006, 0x00000053, 0x00000051,
    0x00000000, 0x00050051, 0x00000006, 0x00000054, 0x00000051, 0x00000001,
    0x00050051, 0x00000006, 0x00000055, 0x00000051, 0x00000002, 0x00070050,
    0x00000007, 0x00000056, 0x00000053, 0x00000054, 0x00000055, 0x00000052,
    0x0003003E, 0x0000004E, 0x00000056, 0x000100FD, 0x00010038,
};

/// glslc's own output, at `-O`, for a selection of no false arm that is
/// all of the true arm of another of none: the shape nir_opt_collapse_if
/// makes one selection on the two conditions' iand before anything is
/// flattened (since 1.156), which the walk does too (since 1.159).
///
/// ```glsl
/// #version 450
/// layout(location = 0) in vec4 vcolor;
/// layout(location = 0) out vec4 ocolor;
/// void main() {
///     vec4 c = vcolor;
///     if (vcolor.x < 0.5) {
///         if (vcolor.y < 0.5) {
///             c.r = sin(vcolor.z * 3.0);
///         }
///     }
///     ocolor = c;
/// }
/// ```
///
/// ```sh
/// glslc -O -fshader-stage=frag collapse.frag -o collapse.spv   # 202 words
/// spirv-val --target-env vulkan1.0 collapse.spv              # no output, and 0
/// ```
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 44
/// ; Schema: 0
///                OpCapability Shader
///           %1 = OpExtInstImport "GLSL.std.450"
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %4 "main" %11 %38
///                OpExecutionMode %4 OriginUpperLeft
///                OpDecorate %11 Location 0
///                OpDecorate %38 Location 0
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeFloat 32
///           %7 = OpTypeVector %6 4
///          %10 = OpTypePointer Input %7
///          %11 = OpVariable %10 Input
///          %13 = OpTypeInt 32 0
///          %14 = OpConstant %13 0
///          %15 = OpTypePointer Input %6
///          %18 = OpConstant %6 0.5
///          %19 = OpTypeBool
///          %23 = OpConstant %13 1
///          %29 = OpConstant %13 2
///          %32 = OpConstant %6 3
///          %37 = OpTypePointer Output %7
///          %38 = OpVariable %37 Output
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///          %12 = OpLoad %7 %11
///          %16 = OpAccessChain %15 %11 %14
///          %17 = OpLoad %6 %16
///          %20 = OpFOrdLessThan %19 %17 %18
///                OpSelectionMerge %22 None
///                OpBranchConditional %20 %21 %22
///          %21 = OpLabel
///          %24 = OpAccessChain %15 %11 %23
///          %25 = OpLoad %6 %24
///          %26 = OpFOrdLessThan %19 %25 %18
///                OpSelectionMerge %28 None
///                OpBranchConditional %26 %27 %28
///          %27 = OpLabel
///          %30 = OpAccessChain %15 %11 %29
///          %31 = OpLoad %6 %30
///          %33 = OpFMul %6 %31 %32
///          %34 = OpExtInst %6 %1 Sin %33
///          %41 = OpCompositeInsert %7 %34 %12 0
///                OpBranch %28
///          %28 = OpLabel
///          %43 = OpPhi %7 %12 %21 %41 %27
///                OpBranch %22
///          %22 = OpLabel
///          %42 = OpPhi %7 %12 %5 %43 %28
///                OpStore %38 %42
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_collapse = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x0000002C, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x0000000B, 0x00000026, 0x00030010,
    0x00000004, 0x00000007, 0x00040047, 0x0000000B, 0x0000001E, 0x00000000,
    0x00040047, 0x00000026, 0x0000001E, 0x00000000, 0x00020013, 0x00000002,
    0x00030021, 0x00000003, 0x00000002, 0x00030016, 0x00000006, 0x00000020,
    0x00040017, 0x00000007, 0x00000006, 0x00000004, 0x00040020, 0x0000000A,
    0x00000001, 0x00000007, 0x0004003B, 0x0000000A, 0x0000000B, 0x00000001,
    0x00040015, 0x0000000D, 0x00000020, 0x00000000, 0x0004002B, 0x0000000D,
    0x0000000E, 0x00000000, 0x00040020, 0x0000000F, 0x00000001, 0x00000006,
    0x0004002B, 0x00000006, 0x00000012, 0x3F000000, 0x00020014, 0x00000013,
    0x0004002B, 0x0000000D, 0x00000017, 0x00000001, 0x0004002B, 0x0000000D,
    0x0000001D, 0x00000002, 0x0004002B, 0x00000006, 0x00000020, 0x40400000,
    0x00040020, 0x00000025, 0x00000003, 0x00000007, 0x0004003B, 0x00000025,
    0x00000026, 0x00000003, 0x00050036, 0x00000002, 0x00000004, 0x00000000,
    0x00000003, 0x000200F8, 0x00000005, 0x0004003D, 0x00000007, 0x0000000C,
    0x0000000B, 0x00050041, 0x0000000F, 0x00000010, 0x0000000B, 0x0000000E,
    0x0004003D, 0x00000006, 0x00000011, 0x00000010, 0x000500B8, 0x00000013,
    0x00000014, 0x00000011, 0x00000012, 0x000300F7, 0x00000016, 0x00000000,
    0x000400FA, 0x00000014, 0x00000015, 0x00000016, 0x000200F8, 0x00000015,
    0x00050041, 0x0000000F, 0x00000018, 0x0000000B, 0x00000017, 0x0004003D,
    0x00000006, 0x00000019, 0x00000018, 0x000500B8, 0x00000013, 0x0000001A,
    0x00000019, 0x00000012, 0x000300F7, 0x0000001C, 0x00000000, 0x000400FA,
    0x0000001A, 0x0000001B, 0x0000001C, 0x000200F8, 0x0000001B, 0x00050041,
    0x0000000F, 0x0000001E, 0x0000000B, 0x0000001D, 0x0004003D, 0x00000006,
    0x0000001F, 0x0000001E, 0x00050085, 0x00000006, 0x00000021, 0x0000001F,
    0x00000020, 0x0006000C, 0x00000006, 0x00000022, 0x00000001, 0x0000000D,
    0x00000021, 0x00060052, 0x00000007, 0x00000029, 0x00000022, 0x0000000C,
    0x00000000, 0x000200F9, 0x0000001C, 0x000200F8, 0x0000001C, 0x000700F5,
    0x00000007, 0x0000002B, 0x0000000C, 0x00000015, 0x00000029, 0x0000001B,
    0x000200F9, 0x00000016, 0x000200F8, 0x00000016, 0x000700F5, 0x00000007,
    0x0000002A, 0x0000000C, 0x00000005, 0x0000002B, 0x0000001C, 0x0003003E,
    0x00000026, 0x0000002A, 0x000100FD, 0x00010038,
};

/// glslc's own output, at `-O`, for a conditional discard nested in a
/// selection's arm: Mesa's terminate_if on the two conditions' iand
/// (rewrite_instr; since 1.156), which the walk makes too (since 1.159).
///
/// ```glsl
/// #version 450
/// layout(location = 0) in vec4 vcolor;
/// layout(location = 0) out vec4 ocolor;
/// void main() {
///     if (vcolor.x < 0.5) {
///         if (vcolor.y < 0.5) discard;
///     }
///     ocolor = vcolor;
/// }
/// ```
///
/// ```sh
/// glslc -O -fshader-stage=frag nested_discard.frag -o nested_discard.spv   # 153 words
/// spirv-val --target-env vulkan1.0 nested_discard.spv                    # no output, and 0
/// ```
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 30
/// ; Schema: 0
///                OpCapability Shader
///           %1 = OpExtInstImport "GLSL.std.450"
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %4 "main" %9 %28
///                OpExecutionMode %4 OriginUpperLeft
///                OpDecorate %9 Location 0
///                OpDecorate %28 Location 0
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeFloat 32
///           %7 = OpTypeVector %6 4
///           %8 = OpTypePointer Input %7
///           %9 = OpVariable %8 Input
///          %10 = OpTypeInt 32 0
///          %11 = OpConstant %10 0
///          %12 = OpTypePointer Input %6
///          %15 = OpConstant %6 0.5
///          %16 = OpTypeBool
///          %20 = OpConstant %10 1
///          %27 = OpTypePointer Output %7
///          %28 = OpVariable %27 Output
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///          %13 = OpAccessChain %12 %9 %11
///          %14 = OpLoad %6 %13
///          %17 = OpFOrdLessThan %16 %14 %15
///                OpSelectionMerge %19 None
///                OpBranchConditional %17 %18 %19
///          %18 = OpLabel
///          %21 = OpAccessChain %12 %9 %20
///          %22 = OpLoad %6 %21
///          %23 = OpFOrdLessThan %16 %22 %15
///                OpSelectionMerge %25 None
///                OpBranchConditional %23 %24 %25
///          %24 = OpLabel
///                OpKill
///          %25 = OpLabel
///                OpBranch %19
///          %19 = OpLabel
///          %29 = OpLoad %7 %9
///                OpStore %28 %29
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_nested_discard = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x0000001E, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x00000009, 0x0000001C, 0x00030010,
    0x00000004, 0x00000007, 0x00040047, 0x00000009, 0x0000001E, 0x00000000,
    0x00040047, 0x0000001C, 0x0000001E, 0x00000000, 0x00020013, 0x00000002,
    0x00030021, 0x00000003, 0x00000002, 0x00030016, 0x00000006, 0x00000020,
    0x00040017, 0x00000007, 0x00000006, 0x00000004, 0x00040020, 0x00000008,
    0x00000001, 0x00000007, 0x0004003B, 0x00000008, 0x00000009, 0x00000001,
    0x00040015, 0x0000000A, 0x00000020, 0x00000000, 0x0004002B, 0x0000000A,
    0x0000000B, 0x00000000, 0x00040020, 0x0000000C, 0x00000001, 0x00000006,
    0x0004002B, 0x00000006, 0x0000000F, 0x3F000000, 0x00020014, 0x00000010,
    0x0004002B, 0x0000000A, 0x00000014, 0x00000001, 0x00040020, 0x0000001B,
    0x00000003, 0x00000007, 0x0004003B, 0x0000001B, 0x0000001C, 0x00000003,
    0x00050036, 0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200F8,
    0x00000005, 0x00050041, 0x0000000C, 0x0000000D, 0x00000009, 0x0000000B,
    0x0004003D, 0x00000006, 0x0000000E, 0x0000000D, 0x000500B8, 0x00000010,
    0x00000011, 0x0000000E, 0x0000000F, 0x000300F7, 0x00000013, 0x00000000,
    0x000400FA, 0x00000011, 0x00000012, 0x00000013, 0x000200F8, 0x00000012,
    0x00050041, 0x0000000C, 0x00000015, 0x00000009, 0x00000014, 0x0004003D,
    0x00000006, 0x00000016, 0x00000015, 0x000500B8, 0x00000010, 0x00000017,
    0x00000016, 0x0000000F, 0x000300F7, 0x00000019, 0x00000000, 0x000400FA,
    0x00000017, 0x00000018, 0x00000019, 0x000200F8, 0x00000018, 0x000100FC,
    0x000200F8, 0x00000019, 0x000200F9, 0x00000013, 0x000200F8, 0x00000013,
    0x0004003D, 0x00000007, 0x0000001D, 0x00000009, 0x0003003E, 0x0000001C,
    0x0000001D, 0x000100FD, 0x00010038,
};

/// glslc's own output, at `-O`, for && and || in conditions: each a
/// selection that computes the second comparison only where the first
/// leaves the answer open, and an OpPhi of the bools at its merge, the
/// condition of the next selection; `!(w < 0.75)` an
/// OpFUnordGreaterThanEqual. Mesa flattens each and nir_opt_algebraic makes
/// the phi's bcsel an iand or an ior (since 1.157).
///
/// ```glsl
/// #version 450
/// layout(location = 0) in vec4 vcolor;
/// layout(location = 0) out vec4 ocolor;
/// void main() {
///     vec4 c = vcolor;
///     if (vcolor.x < 0.5 && vcolor.y > 0.25) {
///         c.r = vcolor.z * 2.0;
///     }
///     if (vcolor.z < 0.25 || !(vcolor.w < 0.75)) {
///         c.g = 0.5;
///     }
///     ocolor = c;
/// }
/// ```
///
/// ```sh
/// glslc -O -fshader-stage=frag logic.frag -o logic.spv   # 286 words
/// spirv-val --target-env vulkan1.0 logic.spv           # no output, and 0
/// ```
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 65
/// ; Schema: 0
///                OpCapability Shader
///           %1 = OpExtInstImport "GLSL.std.450"
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %4 "main" %11 %55
///                OpExecutionMode %4 OriginUpperLeft
///                OpDecorate %11 Location 0
///                OpDecorate %55 Location 0
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeFloat 32
///           %7 = OpTypeVector %6 4
///          %10 = OpTypePointer Input %7
///          %11 = OpVariable %10 Input
///          %13 = OpTypeBool
///          %14 = OpTypeInt 32 0
///          %15 = OpConstant %14 0
///          %16 = OpTypePointer Input %6
///          %19 = OpConstant %6 0.5
///          %23 = OpConstant %14 1
///          %26 = OpConstant %6 0.25
///          %31 = OpConstant %14 2
///          %34 = OpConstant %6 2
///          %44 = OpConstant %14 3
///          %47 = OpConstant %6 0.75
///          %54 = OpTypePointer Output %7
///          %55 = OpVariable %54 Output
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///          %12 = OpLoad %7 %11
///          %17 = OpAccessChain %16 %11 %15
///          %18 = OpLoad %6 %17
///          %20 = OpFOrdLessThan %13 %18 %19
///                OpSelectionMerge %22 None
///                OpBranchConditional %20 %21 %22
///          %21 = OpLabel
///          %24 = OpAccessChain %16 %11 %23
///          %25 = OpLoad %6 %24
///          %27 = OpFOrdGreaterThan %13 %25 %26
///                OpBranch %22
///          %22 = OpLabel
///          %28 = OpPhi %13 %20 %5 %27 %21
///                OpSelectionMerge %30 None
///                OpBranchConditional %28 %29 %30
///          %29 = OpLabel
///          %32 = OpAccessChain %16 %11 %31
///          %33 = OpLoad %6 %32
///          %35 = OpFMul %6 %33 %34
///          %58 = OpCompositeInsert %7 %35 %12 0
///                OpBranch %30
///          %30 = OpLabel
///          %63 = OpPhi %7 %12 %22 %58 %29
///          %38 = OpAccessChain %16 %11 %31
///          %39 = OpLoad %6 %38
///          %40 = OpFOrdLessThan %13 %39 %26
///          %41 = OpLogicalNot %13 %40
///                OpSelectionMerge %43 None
///                OpBranchConditional %41 %42 %43
///          %42 = OpLabel
///          %45 = OpAccessChain %16 %11 %44
///          %46 = OpLoad %6 %45
///          %49 = OpFUnordGreaterThanEqual %13 %46 %47
///                OpBranch %43
///          %43 = OpLabel
///          %50 = OpPhi %13 %40 %30 %49 %42
///                OpSelectionMerge %52 None
///                OpBranchConditional %50 %51 %52
///          %51 = OpLabel
///          %60 = OpCompositeInsert %7 %19 %63 1
///                OpBranch %52
///          %52 = OpLabel
///          %64 = OpPhi %7 %63 %43 %60 %51
///                OpStore %55 %64
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_logic = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x00000041, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x0000000B, 0x00000037, 0x00030010,
    0x00000004, 0x00000007, 0x00040047, 0x0000000B, 0x0000001E, 0x00000000,
    0x00040047, 0x00000037, 0x0000001E, 0x00000000, 0x00020013, 0x00000002,
    0x00030021, 0x00000003, 0x00000002, 0x00030016, 0x00000006, 0x00000020,
    0x00040017, 0x00000007, 0x00000006, 0x00000004, 0x00040020, 0x0000000A,
    0x00000001, 0x00000007, 0x0004003B, 0x0000000A, 0x0000000B, 0x00000001,
    0x00020014, 0x0000000D, 0x00040015, 0x0000000E, 0x00000020, 0x00000000,
    0x0004002B, 0x0000000E, 0x0000000F, 0x00000000, 0x00040020, 0x00000010,
    0x00000001, 0x00000006, 0x0004002B, 0x00000006, 0x00000013, 0x3F000000,
    0x0004002B, 0x0000000E, 0x00000017, 0x00000001, 0x0004002B, 0x00000006,
    0x0000001A, 0x3E800000, 0x0004002B, 0x0000000E, 0x0000001F, 0x00000002,
    0x0004002B, 0x00000006, 0x00000022, 0x40000000, 0x0004002B, 0x0000000E,
    0x0000002C, 0x00000003, 0x0004002B, 0x00000006, 0x0000002F, 0x3F400000,
    0x00040020, 0x00000036, 0x00000003, 0x00000007, 0x0004003B, 0x00000036,
    0x00000037, 0x00000003, 0x00050036, 0x00000002, 0x00000004, 0x00000000,
    0x00000003, 0x000200F8, 0x00000005, 0x0004003D, 0x00000007, 0x0000000C,
    0x0000000B, 0x00050041, 0x00000010, 0x00000011, 0x0000000B, 0x0000000F,
    0x0004003D, 0x00000006, 0x00000012, 0x00000011, 0x000500B8, 0x0000000D,
    0x00000014, 0x00000012, 0x00000013, 0x000300F7, 0x00000016, 0x00000000,
    0x000400FA, 0x00000014, 0x00000015, 0x00000016, 0x000200F8, 0x00000015,
    0x00050041, 0x00000010, 0x00000018, 0x0000000B, 0x00000017, 0x0004003D,
    0x00000006, 0x00000019, 0x00000018, 0x000500BA, 0x0000000D, 0x0000001B,
    0x00000019, 0x0000001A, 0x000200F9, 0x00000016, 0x000200F8, 0x00000016,
    0x000700F5, 0x0000000D, 0x0000001C, 0x00000014, 0x00000005, 0x0000001B,
    0x00000015, 0x000300F7, 0x0000001E, 0x00000000, 0x000400FA, 0x0000001C,
    0x0000001D, 0x0000001E, 0x000200F8, 0x0000001D, 0x00050041, 0x00000010,
    0x00000020, 0x0000000B, 0x0000001F, 0x0004003D, 0x00000006, 0x00000021,
    0x00000020, 0x00050085, 0x00000006, 0x00000023, 0x00000021, 0x00000022,
    0x00060052, 0x00000007, 0x0000003A, 0x00000023, 0x0000000C, 0x00000000,
    0x000200F9, 0x0000001E, 0x000200F8, 0x0000001E, 0x000700F5, 0x00000007,
    0x0000003F, 0x0000000C, 0x00000016, 0x0000003A, 0x0000001D, 0x00050041,
    0x00000010, 0x00000026, 0x0000000B, 0x0000001F, 0x0004003D, 0x00000006,
    0x00000027, 0x00000026, 0x000500B8, 0x0000000D, 0x00000028, 0x00000027,
    0x0000001A, 0x000400A8, 0x0000000D, 0x00000029, 0x00000028, 0x000300F7,
    0x0000002B, 0x00000000, 0x000400FA, 0x00000029, 0x0000002A, 0x0000002B,
    0x000200F8, 0x0000002A, 0x00050041, 0x00000010, 0x0000002D, 0x0000000B,
    0x0000002C, 0x0004003D, 0x00000006, 0x0000002E, 0x0000002D, 0x000500BF,
    0x0000000D, 0x00000031, 0x0000002E, 0x0000002F, 0x000200F9, 0x0000002B,
    0x000200F8, 0x0000002B, 0x000700F5, 0x0000000D, 0x00000032, 0x00000028,
    0x0000001E, 0x00000031, 0x0000002A, 0x000300F7, 0x00000034, 0x00000000,
    0x000400FA, 0x00000032, 0x00000033, 0x00000034, 0x000200F8, 0x00000033,
    0x00060052, 0x00000007, 0x0000003C, 0x00000013, 0x0000003F, 0x00000001,
    0x000200F9, 0x00000034, 0x000200F8, 0x00000034, 0x000700F5, 0x00000007,
    0x00000040, 0x0000003F, 0x0000002B, 0x0000003C, 0x00000033, 0x0003003E,
    0x00000037, 0x00000040, 0x000100FD, 0x00010038,
};

/// glslc's own output for `glslc_logic`'s GLSL without `-O`: `c` in a
/// variable of the function's own, and `!(w < 0.75)` an OpLogicalNot of
/// the ordered comparison (since 1.157).
///
/// ```sh
/// glslc -fshader-stage=frag logic.frag -o logic_O0.spv   # 335 words
/// spirv-val --target-env vulkan1.0 logic_O0.spv        # no output, and 0
/// ```
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 57
/// ; Schema: 0
///                OpCapability Shader
///           %1 = OpExtInstImport "GLSL.std.450"
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %4 "main" %11 %55
///                OpExecutionMode %4 OriginUpperLeft
///                OpSource GLSL 450
///                OpSourceExtension "GL_GOOGLE_cpp_style_line_directive"
///                OpSourceExtension "GL_GOOGLE_include_directive"
///                OpName %4 "main"
///                OpName %9 "c"
///                OpName %11 "vcolor"
///                OpName %55 "ocolor"
///                OpDecorate %11 Location 0
///                OpDecorate %55 Location 0
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeFloat 32
///           %7 = OpTypeVector %6 4
///           %8 = OpTypePointer Function %7
///          %10 = OpTypePointer Input %7
///          %11 = OpVariable %10 Input
///          %13 = OpTypeBool
///          %14 = OpTypeInt 32 0
///          %15 = OpConstant %14 0
///          %16 = OpTypePointer Input %6
///          %19 = OpConstant %6 0.5
///          %23 = OpConstant %14 1
///          %26 = OpConstant %6 0.25
///          %31 = OpConstant %14 2
///          %34 = OpConstant %6 2
///          %36 = OpTypePointer Function %6
///          %44 = OpConstant %14 3
///          %47 = OpConstant %6 0.75
///          %54 = OpTypePointer Output %7
///          %55 = OpVariable %54 Output
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///           %9 = OpVariable %8 Function
///          %12 = OpLoad %7 %11
///                OpStore %9 %12
///          %17 = OpAccessChain %16 %11 %15
///          %18 = OpLoad %6 %17
///          %20 = OpFOrdLessThan %13 %18 %19
///                OpSelectionMerge %22 None
///                OpBranchConditional %20 %21 %22
///          %21 = OpLabel
///          %24 = OpAccessChain %16 %11 %23
///          %25 = OpLoad %6 %24
///          %27 = OpFOrdGreaterThan %13 %25 %26
///                OpBranch %22
///          %22 = OpLabel
///          %28 = OpPhi %13 %20 %5 %27 %21
///                OpSelectionMerge %30 None
///                OpBranchConditional %28 %29 %30
///          %29 = OpLabel
///          %32 = OpAccessChain %16 %11 %31
///          %33 = OpLoad %6 %32
///          %35 = OpFMul %6 %33 %34
///          %37 = OpAccessChain %36 %9 %15
///                OpStore %37 %35
///                OpBranch %30
///          %30 = OpLabel
///          %38 = OpAccessChain %16 %11 %31
///          %39 = OpLoad %6 %38
///          %40 = OpFOrdLessThan %13 %39 %26
///          %41 = OpLogicalNot %13 %40
///                OpSelectionMerge %43 None
///                OpBranchConditional %41 %42 %43
///          %42 = OpLabel
///          %45 = OpAccessChain %16 %11 %44
///          %46 = OpLoad %6 %45
///          %48 = OpFOrdLessThan %13 %46 %47
///          %49 = OpLogicalNot %13 %48
///                OpBranch %43
///          %43 = OpLabel
///          %50 = OpPhi %13 %40 %30 %49 %42
///                OpSelectionMerge %52 None
///                OpBranchConditional %50 %51 %52
///          %51 = OpLabel
///          %53 = OpAccessChain %36 %9 %23
///                OpStore %53 %19
///                OpBranch %52
///          %52 = OpLabel
///          %56 = OpLoad %7 %9
///                OpStore %55 %56
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_logic_unoptimized = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x00000039, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x0000000B, 0x00000037, 0x00030010,
    0x00000004, 0x00000007, 0x00030003, 0x00000002, 0x000001C2, 0x000A0004,
    0x475F4C47, 0x4C474F4F, 0x70635F45, 0x74735F70, 0x5F656C79, 0x656E696C,
    0x7269645F, 0x69746365, 0x00006576, 0x00080004, 0x475F4C47, 0x4C474F4F,
    0x6E695F45, 0x64756C63, 0x69645F65, 0x74636572, 0x00657669, 0x00040005,
    0x00000004, 0x6E69616D, 0x00000000, 0x00030005, 0x00000009, 0x00000063,
    0x00040005, 0x0000000B, 0x6C6F6376, 0x0000726F, 0x00040005, 0x00000037,
    0x6C6F636F, 0x0000726F, 0x00040047, 0x0000000B, 0x0000001E, 0x00000000,
    0x00040047, 0x00000037, 0x0000001E, 0x00000000, 0x00020013, 0x00000002,
    0x00030021, 0x00000003, 0x00000002, 0x00030016, 0x00000006, 0x00000020,
    0x00040017, 0x00000007, 0x00000006, 0x00000004, 0x00040020, 0x00000008,
    0x00000007, 0x00000007, 0x00040020, 0x0000000A, 0x00000001, 0x00000007,
    0x0004003B, 0x0000000A, 0x0000000B, 0x00000001, 0x00020014, 0x0000000D,
    0x00040015, 0x0000000E, 0x00000020, 0x00000000, 0x0004002B, 0x0000000E,
    0x0000000F, 0x00000000, 0x00040020, 0x00000010, 0x00000001, 0x00000006,
    0x0004002B, 0x00000006, 0x00000013, 0x3F000000, 0x0004002B, 0x0000000E,
    0x00000017, 0x00000001, 0x0004002B, 0x00000006, 0x0000001A, 0x3E800000,
    0x0004002B, 0x0000000E, 0x0000001F, 0x00000002, 0x0004002B, 0x00000006,
    0x00000022, 0x40000000, 0x00040020, 0x00000024, 0x00000007, 0x00000006,
    0x0004002B, 0x0000000E, 0x0000002C, 0x00000003, 0x0004002B, 0x00000006,
    0x0000002F, 0x3F400000, 0x00040020, 0x00000036, 0x00000003, 0x00000007,
    0x0004003B, 0x00000036, 0x00000037, 0x00000003, 0x00050036, 0x00000002,
    0x00000004, 0x00000000, 0x00000003, 0x000200F8, 0x00000005, 0x0004003B,
    0x00000008, 0x00000009, 0x00000007, 0x0004003D, 0x00000007, 0x0000000C,
    0x0000000B, 0x0003003E, 0x00000009, 0x0000000C, 0x00050041, 0x00000010,
    0x00000011, 0x0000000B, 0x0000000F, 0x0004003D, 0x00000006, 0x00000012,
    0x00000011, 0x000500B8, 0x0000000D, 0x00000014, 0x00000012, 0x00000013,
    0x000300F7, 0x00000016, 0x00000000, 0x000400FA, 0x00000014, 0x00000015,
    0x00000016, 0x000200F8, 0x00000015, 0x00050041, 0x00000010, 0x00000018,
    0x0000000B, 0x00000017, 0x0004003D, 0x00000006, 0x00000019, 0x00000018,
    0x000500BA, 0x0000000D, 0x0000001B, 0x00000019, 0x0000001A, 0x000200F9,
    0x00000016, 0x000200F8, 0x00000016, 0x000700F5, 0x0000000D, 0x0000001C,
    0x00000014, 0x00000005, 0x0000001B, 0x00000015, 0x000300F7, 0x0000001E,
    0x00000000, 0x000400FA, 0x0000001C, 0x0000001D, 0x0000001E, 0x000200F8,
    0x0000001D, 0x00050041, 0x00000010, 0x00000020, 0x0000000B, 0x0000001F,
    0x0004003D, 0x00000006, 0x00000021, 0x00000020, 0x00050085, 0x00000006,
    0x00000023, 0x00000021, 0x00000022, 0x00050041, 0x00000024, 0x00000025,
    0x00000009, 0x0000000F, 0x0003003E, 0x00000025, 0x00000023, 0x000200F9,
    0x0000001E, 0x000200F8, 0x0000001E, 0x00050041, 0x00000010, 0x00000026,
    0x0000000B, 0x0000001F, 0x0004003D, 0x00000006, 0x00000027, 0x00000026,
    0x000500B8, 0x0000000D, 0x00000028, 0x00000027, 0x0000001A, 0x000400A8,
    0x0000000D, 0x00000029, 0x00000028, 0x000300F7, 0x0000002B, 0x00000000,
    0x000400FA, 0x00000029, 0x0000002A, 0x0000002B, 0x000200F8, 0x0000002A,
    0x00050041, 0x00000010, 0x0000002D, 0x0000000B, 0x0000002C, 0x0004003D,
    0x00000006, 0x0000002E, 0x0000002D, 0x000500B8, 0x0000000D, 0x00000030,
    0x0000002E, 0x0000002F, 0x000400A8, 0x0000000D, 0x00000031, 0x00000030,
    0x000200F9, 0x0000002B, 0x000200F8, 0x0000002B, 0x000700F5, 0x0000000D,
    0x00000032, 0x00000028, 0x0000001E, 0x00000031, 0x0000002A, 0x000300F7,
    0x00000034, 0x00000000, 0x000400FA, 0x00000032, 0x00000033, 0x00000034,
    0x000200F8, 0x00000033, 0x00050041, 0x00000024, 0x00000035, 0x00000009,
    0x00000017, 0x0003003E, 0x00000035, 0x00000013, 0x000200F9, 0x00000034,
    0x000200F8, 0x00000034, 0x0004003D, 0x00000007, 0x00000038, 0x00000009,
    0x0003003E, 0x00000037, 0x00000038, 0x000100FD, 0x00010038,
};

/// glslc's own output for `glslc_collapse`'s GLSL without -O: `c` a variable
/// of the function's own, its float stored through an access chain in the
/// inner arm, which the V3D's host tests hold to compile to the optimized
/// module's program, word for word (since 1.159).
///
/// ```sh
/// glslc -O0 -fshader-stage=frag collapse.frag -o collapse_O0.spv   # 245 words
/// spirv-val --target-env vulkan1.0 collapse_O0.spv               # no output, and 0
/// ```
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 40
/// ; Schema: 0
///                OpCapability Shader
///           %1 = OpExtInstImport "GLSL.std.450"
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %4 "main" %11 %38
///                OpExecutionMode %4 OriginUpperLeft
///                OpSource GLSL 450
///                OpSourceExtension "GL_GOOGLE_cpp_style_line_directive"
///                OpSourceExtension "GL_GOOGLE_include_directive"
///                OpName %4 "main"
///                OpName %9 "c"
///                OpName %11 "vcolor"
///                OpName %38 "ocolor"
///                OpDecorate %11 Location 0
///                OpDecorate %38 Location 0
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeFloat 32
///           %7 = OpTypeVector %6 4
///           %8 = OpTypePointer Function %7
///          %10 = OpTypePointer Input %7
///          %11 = OpVariable %10 Input
///          %13 = OpTypeInt 32 0
///          %14 = OpConstant %13 0
///          %15 = OpTypePointer Input %6
///          %18 = OpConstant %6 0.5
///          %19 = OpTypeBool
///          %23 = OpConstant %13 1
///          %29 = OpConstant %13 2
///          %32 = OpConstant %6 3
///          %35 = OpTypePointer Function %6
///          %37 = OpTypePointer Output %7
///          %38 = OpVariable %37 Output
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///           %9 = OpVariable %8 Function
///          %12 = OpLoad %7 %11
///                OpStore %9 %12
///          %16 = OpAccessChain %15 %11 %14
///          %17 = OpLoad %6 %16
///          %20 = OpFOrdLessThan %19 %17 %18
///                OpSelectionMerge %22 None
///                OpBranchConditional %20 %21 %22
///          %21 = OpLabel
///          %24 = OpAccessChain %15 %11 %23
///          %25 = OpLoad %6 %24
///          %26 = OpFOrdLessThan %19 %25 %18
///                OpSelectionMerge %28 None
///                OpBranchConditional %26 %27 %28
///          %27 = OpLabel
///          %30 = OpAccessChain %15 %11 %29
///          %31 = OpLoad %6 %30
///          %33 = OpFMul %6 %31 %32
///          %34 = OpExtInst %6 %1 Sin %33
///          %36 = OpAccessChain %35 %9 %14
///                OpStore %36 %34
///                OpBranch %28
///          %28 = OpLabel
///                OpBranch %22
///          %22 = OpLabel
///          %39 = OpLoad %7 %9
///                OpStore %38 %39
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_collapse_unoptimized = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x00000028, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x0000000B, 0x00000026, 0x00030010,
    0x00000004, 0x00000007, 0x00030003, 0x00000002, 0x000001C2, 0x000A0004,
    0x475F4C47, 0x4C474F4F, 0x70635F45, 0x74735F70, 0x5F656C79, 0x656E696C,
    0x7269645F, 0x69746365, 0x00006576, 0x00080004, 0x475F4C47, 0x4C474F4F,
    0x6E695F45, 0x64756C63, 0x69645F65, 0x74636572, 0x00657669, 0x00040005,
    0x00000004, 0x6E69616D, 0x00000000, 0x00030005, 0x00000009, 0x00000063,
    0x00040005, 0x0000000B, 0x6C6F6376, 0x0000726F, 0x00040005, 0x00000026,
    0x6C6F636F, 0x0000726F, 0x00040047, 0x0000000B, 0x0000001E, 0x00000000,
    0x00040047, 0x00000026, 0x0000001E, 0x00000000, 0x00020013, 0x00000002,
    0x00030021, 0x00000003, 0x00000002, 0x00030016, 0x00000006, 0x00000020,
    0x00040017, 0x00000007, 0x00000006, 0x00000004, 0x00040020, 0x00000008,
    0x00000007, 0x00000007, 0x00040020, 0x0000000A, 0x00000001, 0x00000007,
    0x0004003B, 0x0000000A, 0x0000000B, 0x00000001, 0x00040015, 0x0000000D,
    0x00000020, 0x00000000, 0x0004002B, 0x0000000D, 0x0000000E, 0x00000000,
    0x00040020, 0x0000000F, 0x00000001, 0x00000006, 0x0004002B, 0x00000006,
    0x00000012, 0x3F000000, 0x00020014, 0x00000013, 0x0004002B, 0x0000000D,
    0x00000017, 0x00000001, 0x0004002B, 0x0000000D, 0x0000001D, 0x00000002,
    0x0004002B, 0x00000006, 0x00000020, 0x40400000, 0x00040020, 0x00000023,
    0x00000007, 0x00000006, 0x00040020, 0x00000025, 0x00000003, 0x00000007,
    0x0004003B, 0x00000025, 0x00000026, 0x00000003, 0x00050036, 0x00000002,
    0x00000004, 0x00000000, 0x00000003, 0x000200F8, 0x00000005, 0x0004003B,
    0x00000008, 0x00000009, 0x00000007, 0x0004003D, 0x00000007, 0x0000000C,
    0x0000000B, 0x0003003E, 0x00000009, 0x0000000C, 0x00050041, 0x0000000F,
    0x00000010, 0x0000000B, 0x0000000E, 0x0004003D, 0x00000006, 0x00000011,
    0x00000010, 0x000500B8, 0x00000013, 0x00000014, 0x00000011, 0x00000012,
    0x000300F7, 0x00000016, 0x00000000, 0x000400FA, 0x00000014, 0x00000015,
    0x00000016, 0x000200F8, 0x00000015, 0x00050041, 0x0000000F, 0x00000018,
    0x0000000B, 0x00000017, 0x0004003D, 0x00000006, 0x00000019, 0x00000018,
    0x000500B8, 0x00000013, 0x0000001A, 0x00000019, 0x00000012, 0x000300F7,
    0x0000001C, 0x00000000, 0x000400FA, 0x0000001A, 0x0000001B, 0x0000001C,
    0x000200F8, 0x0000001B, 0x00050041, 0x0000000F, 0x0000001E, 0x0000000B,
    0x0000001D, 0x0004003D, 0x00000006, 0x0000001F, 0x0000001E, 0x00050085,
    0x00000006, 0x00000021, 0x0000001F, 0x00000020, 0x0006000C, 0x00000006,
    0x00000022, 0x00000001, 0x0000000D, 0x00000021, 0x00050041, 0x00000023,
    0x00000024, 0x00000009, 0x0000000E, 0x0003003E, 0x00000024, 0x00000022,
    0x000200F9, 0x0000001C, 0x000200F8, 0x0000001C, 0x000200F9, 0x00000016,
    0x000200F8, 0x00000016, 0x0004003D, 0x00000007, 0x00000027, 0x00000009,
    0x0003003E, 0x00000026, 0x00000027, 0x000100FD, 0x00010038,
};

/// glslc's own output, at `-O`, for the shape of `glslc_collapse` with a
/// float of `c` stored in the outer arm before the inner selection: the
/// outer phi then takes a value the inner one does not, which
/// nir_opt_collapse_if cannot drop (nir_opt_peephole_select.c:444-462), so
/// the two are flattened from the inside out (since 1.159).
///
/// ```glsl
/// #version 450
/// layout(location = 0) in vec4 vcolor;
/// layout(location = 0) out vec4 ocolor;
/// void main() {
///     vec4 c = vcolor;
///     if (vcolor.x < 0.5) {
///         c.r = vcolor.w * 0.5;
///         if (vcolor.y < 0.5) {
///             c.r = sin(vcolor.z * 3.0);
///         }
///     }
///     ocolor = c;
/// }
/// ```
///
/// ```sh
/// glslc -O -fshader-stage=frag kept.frag -o kept.spv   # 226 words
/// spirv-val --target-env vulkan1.0 kept.spv          # no output, and 0
/// ```
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 51
/// ; Schema: 0
///                OpCapability Shader
///           %1 = OpExtInstImport "GLSL.std.450"
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %4 "main" %11 %43
///                OpExecutionMode %4 OriginUpperLeft
///                OpDecorate %11 Location 0
///                OpDecorate %43 Location 0
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeFloat 32
///           %7 = OpTypeVector %6 4
///          %10 = OpTypePointer Input %7
///          %11 = OpVariable %10 Input
///          %13 = OpTypeInt 32 0
///          %14 = OpConstant %13 0
///          %15 = OpTypePointer Input %6
///          %18 = OpConstant %6 0.5
///          %19 = OpTypeBool
///          %23 = OpConstant %13 3
///          %29 = OpConstant %13 1
///          %35 = OpConstant %13 2
///          %38 = OpConstant %6 3
///          %42 = OpTypePointer Output %7
///          %43 = OpVariable %42 Output
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///          %12 = OpLoad %7 %11
///          %16 = OpAccessChain %15 %11 %14
///          %17 = OpLoad %6 %16
///          %20 = OpFOrdLessThan %19 %17 %18
///                OpSelectionMerge %22 None
///                OpBranchConditional %20 %21 %22
///          %21 = OpLabel
///          %24 = OpAccessChain %15 %11 %23
///          %25 = OpLoad %6 %24
///          %26 = OpFMul %6 %25 %18
///          %46 = OpCompositeInsert %7 %26 %12 0
///          %30 = OpAccessChain %15 %11 %29
///          %31 = OpLoad %6 %30
///          %32 = OpFOrdLessThan %19 %31 %18
///                OpSelectionMerge %34 None
///                OpBranchConditional %32 %33 %34
///          %33 = OpLabel
///          %36 = OpAccessChain %15 %11 %35
///          %37 = OpLoad %6 %36
///          %39 = OpFMul %6 %37 %38
///          %40 = OpExtInst %6 %1 Sin %39
///          %48 = OpCompositeInsert %7 %40 %46 0
///                OpBranch %34
///          %34 = OpLabel
///          %50 = OpPhi %7 %46 %21 %48 %33
///                OpBranch %22
///          %22 = OpLabel
///          %49 = OpPhi %7 %12 %5 %50 %34
///                OpStore %43 %49
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_collapse_kept = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x00000033, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x0000000B, 0x0000002B, 0x00030010,
    0x00000004, 0x00000007, 0x00040047, 0x0000000B, 0x0000001E, 0x00000000,
    0x00040047, 0x0000002B, 0x0000001E, 0x00000000, 0x00020013, 0x00000002,
    0x00030021, 0x00000003, 0x00000002, 0x00030016, 0x00000006, 0x00000020,
    0x00040017, 0x00000007, 0x00000006, 0x00000004, 0x00040020, 0x0000000A,
    0x00000001, 0x00000007, 0x0004003B, 0x0000000A, 0x0000000B, 0x00000001,
    0x00040015, 0x0000000D, 0x00000020, 0x00000000, 0x0004002B, 0x0000000D,
    0x0000000E, 0x00000000, 0x00040020, 0x0000000F, 0x00000001, 0x00000006,
    0x0004002B, 0x00000006, 0x00000012, 0x3F000000, 0x00020014, 0x00000013,
    0x0004002B, 0x0000000D, 0x00000017, 0x00000003, 0x0004002B, 0x0000000D,
    0x0000001D, 0x00000001, 0x0004002B, 0x0000000D, 0x00000023, 0x00000002,
    0x0004002B, 0x00000006, 0x00000026, 0x40400000, 0x00040020, 0x0000002A,
    0x00000003, 0x00000007, 0x0004003B, 0x0000002A, 0x0000002B, 0x00000003,
    0x00050036, 0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200F8,
    0x00000005, 0x0004003D, 0x00000007, 0x0000000C, 0x0000000B, 0x00050041,
    0x0000000F, 0x00000010, 0x0000000B, 0x0000000E, 0x0004003D, 0x00000006,
    0x00000011, 0x00000010, 0x000500B8, 0x00000013, 0x00000014, 0x00000011,
    0x00000012, 0x000300F7, 0x00000016, 0x00000000, 0x000400FA, 0x00000014,
    0x00000015, 0x00000016, 0x000200F8, 0x00000015, 0x00050041, 0x0000000F,
    0x00000018, 0x0000000B, 0x00000017, 0x0004003D, 0x00000006, 0x00000019,
    0x00000018, 0x00050085, 0x00000006, 0x0000001A, 0x00000019, 0x00000012,
    0x00060052, 0x00000007, 0x0000002E, 0x0000001A, 0x0000000C, 0x00000000,
    0x00050041, 0x0000000F, 0x0000001E, 0x0000000B, 0x0000001D, 0x0004003D,
    0x00000006, 0x0000001F, 0x0000001E, 0x000500B8, 0x00000013, 0x00000020,
    0x0000001F, 0x00000012, 0x000300F7, 0x00000022, 0x00000000, 0x000400FA,
    0x00000020, 0x00000021, 0x00000022, 0x000200F8, 0x00000021, 0x00050041,
    0x0000000F, 0x00000024, 0x0000000B, 0x00000023, 0x0004003D, 0x00000006,
    0x00000025, 0x00000024, 0x00050085, 0x00000006, 0x00000027, 0x00000025,
    0x00000026, 0x0006000C, 0x00000006, 0x00000028, 0x00000001, 0x0000000D,
    0x00000027, 0x00060052, 0x00000007, 0x00000030, 0x00000028, 0x0000002E,
    0x00000000, 0x000200F9, 0x00000022, 0x000200F8, 0x00000022, 0x000700F5,
    0x00000007, 0x00000032, 0x0000002E, 0x00000015, 0x00000030, 0x00000021,
    0x000200F9, 0x00000016, 0x000200F8, 0x00000016, 0x000700F5, 0x00000007,
    0x00000031, 0x0000000C, 0x00000005, 0x00000032, 0x00000022, 0x0003003E,
    0x0000002B, 0x00000031, 0x000100FD, 0x00010038,
};

/// glslc's own output, at `-O`, for the shape of `glslc_collapse` with a
/// constant alone in the inner arm: nir_opt_peephole_select's first pass,
/// of no ALU operation allowed, flattens the inner selection before the
/// outer arm's comparison lets nir_opt_collapse_if take the two, and the
/// select of a select is then one on an iand (nir_opt_algebraic.py:2512;
/// since 1.159).
///
/// ```glsl
/// #version 450
/// layout(location = 0) in vec4 vcolor;
/// layout(location = 0) out vec4 ocolor;
/// void main() {
///     vec4 c = vcolor;
///     if (vcolor.x < 0.5) {
///         if (vcolor.y < 0.5) {
///             c.r = 0.25;
///         }
///     }
///     ocolor = c;
/// }
/// ```
///
/// ```sh
/// glslc -O -fshader-stage=frag free.frag -o free.spv   # 178 words
/// spirv-val --target-env vulkan1.0 free.spv          # no output, and 0
/// ```
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 39
/// ; Schema: 0
///                OpCapability Shader
///           %1 = OpExtInstImport "GLSL.std.450"
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %4 "main" %11 %33
///                OpExecutionMode %4 OriginUpperLeft
///                OpDecorate %11 Location 0
///                OpDecorate %33 Location 0
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeFloat 32
///           %7 = OpTypeVector %6 4
///          %10 = OpTypePointer Input %7
///          %11 = OpVariable %10 Input
///          %13 = OpTypeInt 32 0
///          %14 = OpConstant %13 0
///          %15 = OpTypePointer Input %6
///          %18 = OpConstant %6 0.5
///          %19 = OpTypeBool
///          %23 = OpConstant %13 1
///          %29 = OpConstant %6 0.25
///          %32 = OpTypePointer Output %7
///          %33 = OpVariable %32 Output
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///          %12 = OpLoad %7 %11
///          %16 = OpAccessChain %15 %11 %14
///          %17 = OpLoad %6 %16
///          %20 = OpFOrdLessThan %19 %17 %18
///                OpSelectionMerge %22 None
///                OpBranchConditional %20 %21 %22
///          %21 = OpLabel
///          %24 = OpAccessChain %15 %11 %23
///          %25 = OpLoad %6 %24
///          %26 = OpFOrdLessThan %19 %25 %18
///                OpSelectionMerge %28 None
///                OpBranchConditional %26 %27 %28
///          %27 = OpLabel
///          %36 = OpCompositeInsert %7 %29 %12 0
///                OpBranch %28
///          %28 = OpLabel
///          %38 = OpPhi %7 %12 %21 %36 %27
///                OpBranch %22
///          %22 = OpLabel
///          %37 = OpPhi %7 %12 %5 %38 %28
///                OpStore %33 %37
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_collapse_free = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x00000027, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x0000000B, 0x00000021, 0x00030010,
    0x00000004, 0x00000007, 0x00040047, 0x0000000B, 0x0000001E, 0x00000000,
    0x00040047, 0x00000021, 0x0000001E, 0x00000000, 0x00020013, 0x00000002,
    0x00030021, 0x00000003, 0x00000002, 0x00030016, 0x00000006, 0x00000020,
    0x00040017, 0x00000007, 0x00000006, 0x00000004, 0x00040020, 0x0000000A,
    0x00000001, 0x00000007, 0x0004003B, 0x0000000A, 0x0000000B, 0x00000001,
    0x00040015, 0x0000000D, 0x00000020, 0x00000000, 0x0004002B, 0x0000000D,
    0x0000000E, 0x00000000, 0x00040020, 0x0000000F, 0x00000001, 0x00000006,
    0x0004002B, 0x00000006, 0x00000012, 0x3F000000, 0x00020014, 0x00000013,
    0x0004002B, 0x0000000D, 0x00000017, 0x00000001, 0x0004002B, 0x00000006,
    0x0000001D, 0x3E800000, 0x00040020, 0x00000020, 0x00000003, 0x00000007,
    0x0004003B, 0x00000020, 0x00000021, 0x00000003, 0x00050036, 0x00000002,
    0x00000004, 0x00000000, 0x00000003, 0x000200F8, 0x00000005, 0x0004003D,
    0x00000007, 0x0000000C, 0x0000000B, 0x00050041, 0x0000000F, 0x00000010,
    0x0000000B, 0x0000000E, 0x0004003D, 0x00000006, 0x00000011, 0x00000010,
    0x000500B8, 0x00000013, 0x00000014, 0x00000011, 0x00000012, 0x000300F7,
    0x00000016, 0x00000000, 0x000400FA, 0x00000014, 0x00000015, 0x00000016,
    0x000200F8, 0x00000015, 0x00050041, 0x0000000F, 0x00000018, 0x0000000B,
    0x00000017, 0x0004003D, 0x00000006, 0x00000019, 0x00000018, 0x000500B8,
    0x00000013, 0x0000001A, 0x00000019, 0x00000012, 0x000300F7, 0x0000001C,
    0x00000000, 0x000400FA, 0x0000001A, 0x0000001B, 0x0000001C, 0x000200F8,
    0x0000001B, 0x00060052, 0x00000007, 0x00000024, 0x0000001D, 0x0000000C,
    0x00000000, 0x000200F9, 0x0000001C, 0x000200F8, 0x0000001C, 0x000700F5,
    0x00000007, 0x00000026, 0x0000000C, 0x00000015, 0x00000024, 0x0000001B,
    0x000200F9, 0x00000016, 0x000200F8, 0x00000016, 0x000700F5, 0x00000007,
    0x00000025, 0x0000000C, 0x00000005, 0x00000026, 0x0000001C, 0x0003003E,
    0x00000021, 0x00000025, 0x000100FD, 0x00010038,
};
