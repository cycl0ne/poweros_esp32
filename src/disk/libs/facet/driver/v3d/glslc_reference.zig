// SPDX-License-Identifier: MIT
//! Modules a real toolchain produced, to compile against: `glslc`'s own
//! output for shaders whose facet forms `tests/spirv_reference.zig`
//! keeps: the interpolated colour, the colour tinted by the push
//! constants (since 1.138), the texture whose pixel is dropped where
//! its alpha is under a half (since 1.139), a shadow sample (since
//! 1.143), and float arithmetic through GLSL.std.450 (since 1.152).
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
/// function's own, which this back end has no place for, and reads the
/// alpha through an access chain into it. Optimized, it is the shape
/// facet's emitter writes: the comparison, a selection whose block is
/// `OpKill` alone, and the merge block.
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
