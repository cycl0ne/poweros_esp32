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

/// glslc's own output, at `-O`, for a uniform buffer read in a fragment
/// shader: a block of a vec4, a float and a vec2 at set 0, binding 0, each
/// member a load_ubo of a constant offset (nir_lower_explicit_io), which
/// v3d reads through unifa, written once and stepped by ldunifa
/// (ntq_emit_load_unifa, nir_to_vir.c:3299-3507; since 1.160).
///
/// ```glsl
/// #version 450
/// layout(location = 0) in vec4 vcolor;
/// layout(location = 0) out vec4 ocolor;
/// layout(set = 0, binding = 0) uniform Material {
///     vec4 tint;
///     float strength;
///     vec2 shift;
/// } material;
/// void main() {
///     ocolor = vec4(vcolor.rgb * material.tint.rgb * material.strength + vec3(material.shift, 0.0), vcolor.a);
/// }
/// ```
///
/// ```sh
/// glslc -O -fshader-stage=frag ubo.frag -o ubo.spv   # 274 words
/// spirv-val --target-env vulkan1.0 ubo.spv         # no output, and 0
/// ```
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 49
/// ; Schema: 0
///                OpCapability Shader
///           %1 = OpExtInstImport "GLSL.std.450"
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %4 "main" %9 %11
///                OpExecutionMode %4 OriginUpperLeft
///                OpDecorate %9 Location 0
///                OpDecorate %11 Location 0
///                OpDecorate %16 Block
///                OpMemberDecorate %16 0 Offset 0
///                OpMemberDecorate %16 1 Offset 16
///                OpMemberDecorate %16 2 Offset 24
///                OpDecorate %18 Binding 0
///                OpDecorate %18 DescriptorSet 0
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeFloat 32
///           %7 = OpTypeVector %6 4
///           %8 = OpTypePointer Output %7
///           %9 = OpVariable %8 Output
///          %10 = OpTypePointer Input %7
///          %11 = OpVariable %10 Input
///          %12 = OpTypeVector %6 3
///          %15 = OpTypeVector %6 2
///          %16 = OpTypeStruct %7 %6 %15
///          %17 = OpTypePointer Uniform %16
///          %18 = OpVariable %17 Uniform
///          %19 = OpTypeInt 32 1
///          %20 = OpConstant %19 0
///          %21 = OpTypePointer Uniform %7
///          %26 = OpConstant %19 1
///          %27 = OpTypePointer Uniform %6
///          %31 = OpConstant %19 2
///          %32 = OpTypePointer Uniform %15
///          %35 = OpConstant %6 0
///          %40 = OpTypeInt 32 0
///          %41 = OpConstant %40 3
///          %42 = OpTypePointer Input %6
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///          %13 = OpLoad %7 %11
///          %14 = OpVectorShuffle %12 %13 %13 0 1 2
///          %22 = OpAccessChain %21 %18 %20
///          %23 = OpLoad %7 %22
///          %24 = OpVectorShuffle %12 %23 %23 0 1 2
///          %25 = OpFMul %12 %14 %24
///          %28 = OpAccessChain %27 %18 %26
///          %29 = OpLoad %6 %28
///          %30 = OpVectorTimesScalar %12 %25 %29
///          %33 = OpAccessChain %32 %18 %31
///          %34 = OpLoad %15 %33
///          %36 = OpCompositeExtract %6 %34 0
///          %37 = OpCompositeExtract %6 %34 1
///          %38 = OpCompositeConstruct %12 %36 %37 %35
///          %39 = OpFAdd %12 %30 %38
///          %43 = OpAccessChain %42 %11 %41
///          %44 = OpLoad %6 %43
///          %45 = OpCompositeExtract %6 %39 0
///          %46 = OpCompositeExtract %6 %39 1
///          %47 = OpCompositeExtract %6 %39 2
///          %48 = OpCompositeConstruct %7 %45 %46 %47 %44
///                OpStore %9 %48
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_uniform_buffer = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x00000031, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x00000009, 0x0000000B, 0x00030010,
    0x00000004, 0x00000007, 0x00040047, 0x00000009, 0x0000001E, 0x00000000,
    0x00040047, 0x0000000B, 0x0000001E, 0x00000000, 0x00030047, 0x00000010,
    0x00000002, 0x00050048, 0x00000010, 0x00000000, 0x00000023, 0x00000000,
    0x00050048, 0x00000010, 0x00000001, 0x00000023, 0x00000010, 0x00050048,
    0x00000010, 0x00000002, 0x00000023, 0x00000018, 0x00040047, 0x00000012,
    0x00000021, 0x00000000, 0x00040047, 0x00000012, 0x00000022, 0x00000000,
    0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002, 0x00030016,
    0x00000006, 0x00000020, 0x00040017, 0x00000007, 0x00000006, 0x00000004,
    0x00040020, 0x00000008, 0x00000003, 0x00000007, 0x0004003B, 0x00000008,
    0x00000009, 0x00000003, 0x00040020, 0x0000000A, 0x00000001, 0x00000007,
    0x0004003B, 0x0000000A, 0x0000000B, 0x00000001, 0x00040017, 0x0000000C,
    0x00000006, 0x00000003, 0x00040017, 0x0000000F, 0x00000006, 0x00000002,
    0x0005001E, 0x00000010, 0x00000007, 0x00000006, 0x0000000F, 0x00040020,
    0x00000011, 0x00000002, 0x00000010, 0x0004003B, 0x00000011, 0x00000012,
    0x00000002, 0x00040015, 0x00000013, 0x00000020, 0x00000001, 0x0004002B,
    0x00000013, 0x00000014, 0x00000000, 0x00040020, 0x00000015, 0x00000002,
    0x00000007, 0x0004002B, 0x00000013, 0x0000001A, 0x00000001, 0x00040020,
    0x0000001B, 0x00000002, 0x00000006, 0x0004002B, 0x00000013, 0x0000001F,
    0x00000002, 0x00040020, 0x00000020, 0x00000002, 0x0000000F, 0x0004002B,
    0x00000006, 0x00000023, 0x00000000, 0x00040015, 0x00000028, 0x00000020,
    0x00000000, 0x0004002B, 0x00000028, 0x00000029, 0x00000003, 0x00040020,
    0x0000002A, 0x00000001, 0x00000006, 0x00050036, 0x00000002, 0x00000004,
    0x00000000, 0x00000003, 0x000200F8, 0x00000005, 0x0004003D, 0x00000007,
    0x0000000D, 0x0000000B, 0x0008004F, 0x0000000C, 0x0000000E, 0x0000000D,
    0x0000000D, 0x00000000, 0x00000001, 0x00000002, 0x00050041, 0x00000015,
    0x00000016, 0x00000012, 0x00000014, 0x0004003D, 0x00000007, 0x00000017,
    0x00000016, 0x0008004F, 0x0000000C, 0x00000018, 0x00000017, 0x00000017,
    0x00000000, 0x00000001, 0x00000002, 0x00050085, 0x0000000C, 0x00000019,
    0x0000000E, 0x00000018, 0x00050041, 0x0000001B, 0x0000001C, 0x00000012,
    0x0000001A, 0x0004003D, 0x00000006, 0x0000001D, 0x0000001C, 0x0005008E,
    0x0000000C, 0x0000001E, 0x00000019, 0x0000001D, 0x00050041, 0x00000020,
    0x00000021, 0x00000012, 0x0000001F, 0x0004003D, 0x0000000F, 0x00000022,
    0x00000021, 0x00050051, 0x00000006, 0x00000024, 0x00000022, 0x00000000,
    0x00050051, 0x00000006, 0x00000025, 0x00000022, 0x00000001, 0x00060050,
    0x0000000C, 0x00000026, 0x00000024, 0x00000025, 0x00000023, 0x00050081,
    0x0000000C, 0x00000027, 0x0000001E, 0x00000026, 0x00050041, 0x0000002A,
    0x0000002B, 0x0000000B, 0x00000029, 0x0004003D, 0x00000006, 0x0000002C,
    0x0000002B, 0x00050051, 0x00000006, 0x0000002D, 0x00000027, 0x00000000,
    0x00050051, 0x00000006, 0x0000002E, 0x00000027, 0x00000001, 0x00050051,
    0x00000006, 0x0000002F, 0x00000027, 0x00000002, 0x00070050, 0x00000007,
    0x00000030, 0x0000002D, 0x0000002E, 0x0000002F, 0x0000002C, 0x0003003E,
    0x00000009, 0x00000030, 0x000100FD, 0x00010038,
};

/// glslc's own output, at `-O`, for two uniform buffers read in a fragment
/// shader, one of them backwards: `light.far` at 64 before `light.color` at
/// 0, then `light.near` at 16, then `mix_by.amount` in the other block. A
/// load before the last one's, or of another block, writes unifa again
/// (ntq_emit_load_unifa, nir_to_vir.c:3398-3415; since 1.160).
///
/// ```glsl
/// #version 450
/// layout(location = 0) in vec4 vcolor;
/// layout(location = 0) out vec4 ocolor;
/// layout(set = 0, binding = 0) uniform Light {
///     vec4 color;
///     vec4 near;
///     vec4 middle;
///     vec4 beyond;
///     vec4 far;
/// } light;
/// layout(set = 1, binding = 2) uniform Mix {
///     float amount;
/// } mix_by;
/// void main() {
///     vec4 lit = vcolor * light.far + light.color;
///     ocolor = mix(lit, light.near, mix_by.amount);
/// }
/// ```
///
/// ```sh
/// glslc -O -fshader-stage=frag ubos.frag -o ubos.spv   # 241 words
/// spirv-val --target-env vulkan1.0 ubos.spv          # no output, and 0
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
///                OpEntryPoint Fragment %4 "main" %11 %27
///                OpExecutionMode %4 OriginUpperLeft
///                OpDecorate %11 Location 0
///                OpDecorate %13 Block
///                OpMemberDecorate %13 0 Offset 0
///                OpMemberDecorate %13 1 Offset 16
///                OpMemberDecorate %13 2 Offset 32
///                OpMemberDecorate %13 3 Offset 48
///                OpMemberDecorate %13 4 Offset 64
///                OpDecorate %15 Binding 0
///                OpDecorate %15 DescriptorSet 0
///                OpDecorate %27 Location 0
///                OpDecorate %32 Block
///                OpMemberDecorate %32 0 Offset 0
///                OpDecorate %34 Binding 2
///                OpDecorate %34 DescriptorSet 1
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeFloat 32
///           %7 = OpTypeVector %6 4
///          %10 = OpTypePointer Input %7
///          %11 = OpVariable %10 Input
///          %13 = OpTypeStruct %7 %7 %7 %7 %7
///          %14 = OpTypePointer Uniform %13
///          %15 = OpVariable %14 Uniform
///          %16 = OpTypeInt 32 1
///          %17 = OpConstant %16 4
///          %18 = OpTypePointer Uniform %7
///          %22 = OpConstant %16 0
///          %26 = OpTypePointer Output %7
///          %27 = OpVariable %26 Output
///          %29 = OpConstant %16 1
///          %32 = OpTypeStruct %6
///          %33 = OpTypePointer Uniform %32
///          %34 = OpVariable %33 Uniform
///          %35 = OpTypePointer Uniform %6
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///          %12 = OpLoad %7 %11
///          %19 = OpAccessChain %18 %15 %17
///          %20 = OpLoad %7 %19
///          %21 = OpFMul %7 %12 %20
///          %23 = OpAccessChain %18 %15 %22
///          %24 = OpLoad %7 %23
///          %25 = OpFAdd %7 %21 %24
///          %30 = OpAccessChain %18 %15 %29
///          %31 = OpLoad %7 %30
///          %36 = OpAccessChain %35 %34 %22
///          %37 = OpLoad %6 %36
///          %38 = OpCompositeConstruct %7 %37 %37 %37 %37
///          %39 = OpExtInst %7 %1 FMix %25 %31 %38
///                OpStore %27 %39
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_uniform_buffers = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x00000028, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x0000000B, 0x0000001B, 0x00030010,
    0x00000004, 0x00000007, 0x00040047, 0x0000000B, 0x0000001E, 0x00000000,
    0x00030047, 0x0000000D, 0x00000002, 0x00050048, 0x0000000D, 0x00000000,
    0x00000023, 0x00000000, 0x00050048, 0x0000000D, 0x00000001, 0x00000023,
    0x00000010, 0x00050048, 0x0000000D, 0x00000002, 0x00000023, 0x00000020,
    0x00050048, 0x0000000D, 0x00000003, 0x00000023, 0x00000030, 0x00050048,
    0x0000000D, 0x00000004, 0x00000023, 0x00000040, 0x00040047, 0x0000000F,
    0x00000021, 0x00000000, 0x00040047, 0x0000000F, 0x00000022, 0x00000000,
    0x00040047, 0x0000001B, 0x0000001E, 0x00000000, 0x00030047, 0x00000020,
    0x00000002, 0x00050048, 0x00000020, 0x00000000, 0x00000023, 0x00000000,
    0x00040047, 0x00000022, 0x00000021, 0x00000002, 0x00040047, 0x00000022,
    0x00000022, 0x00000001, 0x00020013, 0x00000002, 0x00030021, 0x00000003,
    0x00000002, 0x00030016, 0x00000006, 0x00000020, 0x00040017, 0x00000007,
    0x00000006, 0x00000004, 0x00040020, 0x0000000A, 0x00000001, 0x00000007,
    0x0004003B, 0x0000000A, 0x0000000B, 0x00000001, 0x0007001E, 0x0000000D,
    0x00000007, 0x00000007, 0x00000007, 0x00000007, 0x00000007, 0x00040020,
    0x0000000E, 0x00000002, 0x0000000D, 0x0004003B, 0x0000000E, 0x0000000F,
    0x00000002, 0x00040015, 0x00000010, 0x00000020, 0x00000001, 0x0004002B,
    0x00000010, 0x00000011, 0x00000004, 0x00040020, 0x00000012, 0x00000002,
    0x00000007, 0x0004002B, 0x00000010, 0x00000016, 0x00000000, 0x00040020,
    0x0000001A, 0x00000003, 0x00000007, 0x0004003B, 0x0000001A, 0x0000001B,
    0x00000003, 0x0004002B, 0x00000010, 0x0000001D, 0x00000001, 0x0003001E,
    0x00000020, 0x00000006, 0x00040020, 0x00000021, 0x00000002, 0x00000020,
    0x0004003B, 0x00000021, 0x00000022, 0x00000002, 0x00040020, 0x00000023,
    0x00000002, 0x00000006, 0x00050036, 0x00000002, 0x00000004, 0x00000000,
    0x00000003, 0x000200F8, 0x00000005, 0x0004003D, 0x00000007, 0x0000000C,
    0x0000000B, 0x00050041, 0x00000012, 0x00000013, 0x0000000F, 0x00000011,
    0x0004003D, 0x00000007, 0x00000014, 0x00000013, 0x00050085, 0x00000007,
    0x00000015, 0x0000000C, 0x00000014, 0x00050041, 0x00000012, 0x00000017,
    0x0000000F, 0x00000016, 0x0004003D, 0x00000007, 0x00000018, 0x00000017,
    0x00050081, 0x00000007, 0x00000019, 0x00000015, 0x00000018, 0x00050041,
    0x00000012, 0x0000001E, 0x0000000F, 0x0000001D, 0x0004003D, 0x00000007,
    0x0000001F, 0x0000001E, 0x00050041, 0x00000023, 0x00000024, 0x00000022,
    0x00000016, 0x0004003D, 0x00000006, 0x00000025, 0x00000024, 0x00070050,
    0x00000007, 0x00000026, 0x00000025, 0x00000025, 0x00000025, 0x00000025,
    0x0008000C, 0x00000007, 0x00000027, 0x00000001, 0x0000002E, 0x00000019,
    0x0000001F, 0x00000026, 0x0003003E, 0x0000001B, 0x00000027, 0x000100FD,
    0x00010038,
};

/// glslc's own output, at `-O`, for a uniform buffer of an array, a struct
/// and a vector, read through access chains of two and three constant
/// indexes: `scene.palette[2]` at 32, `scene.tint.amount` at 64 and
/// `scene.palette[1].w` at 28, the offsets the ArrayStride and the member
/// Offsets give, as nir_lower_explicit_io folds them (since 1.161).
///
/// ```glsl
/// #version 450
/// layout(location = 0) in vec4 vcolor;
/// layout(location = 0) out vec4 ocolor;
/// struct Tint {
///     vec4 color;
///     float amount;
/// };
/// layout(set = 0, binding = 0) uniform Scene {
///     vec4 palette[3];
///     Tint tint;
///     vec4 last;
/// } scene;
/// void main() {
///     vec4 c = vcolor * scene.palette[2] + scene.palette[0];
///     vec3 mixed = mix(c.rgb, scene.tint.color.rgb, scene.tint.amount);
///     ocolor = vec4(mixed + scene.last.xyz * scene.palette[1].w, c.a);
/// }
/// ```
///
/// ```sh
/// glslc -O -fshader-stage=frag nested.frag -o nested.spv   # 320 words
/// spirv-val --target-env vulkan1.0 nested.spv              # no output, and 0
/// ```
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 61
/// ; Schema: 0
///                OpCapability Shader
///           %1 = OpExtInstImport "GLSL.std.450"
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %4 "main" %11 %45
///                OpExecutionMode %4 OriginUpperLeft
///                OpDecorate %11 Location 0
///                OpDecorate %15 ArrayStride 16
///                OpMemberDecorate %16 0 Offset 0
///                OpMemberDecorate %16 1 Offset 16
///                OpDecorate %17 Block
///                OpMemberDecorate %17 0 Offset 0
///                OpMemberDecorate %17 1 Offset 48
///                OpMemberDecorate %17 2 Offset 80
///                OpDecorate %19 Binding 0
///                OpDecorate %19 DescriptorSet 0
///                OpDecorate %45 Location 0
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeFloat 32
///           %7 = OpTypeVector %6 4
///          %10 = OpTypePointer Input %7
///          %11 = OpVariable %10 Input
///          %13 = OpTypeInt 32 0
///          %14 = OpConstant %13 3
///          %15 = OpTypeArray %7 %14
///          %16 = OpTypeStruct %7 %6
///          %17 = OpTypeStruct %15 %16 %7
///          %18 = OpTypePointer Uniform %17
///          %19 = OpVariable %18 Uniform
///          %20 = OpTypeInt 32 1
///          %21 = OpConstant %20 0
///          %22 = OpConstant %20 2
///          %23 = OpTypePointer Uniform %7
///          %30 = OpTypeVector %6 3
///          %35 = OpConstant %20 1
///          %39 = OpTypePointer Uniform %6
///          %44 = OpTypePointer Output %7
///          %45 = OpVariable %44 Output
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///          %12 = OpLoad %7 %11
///          %24 = OpAccessChain %23 %19 %21 %22
///          %25 = OpLoad %7 %24
///          %26 = OpFMul %7 %12 %25
///          %27 = OpAccessChain %23 %19 %21 %21
///          %28 = OpLoad %7 %27
///          %29 = OpFAdd %7 %26 %28
///          %34 = OpVectorShuffle %30 %29 %29 0 1 2
///          %36 = OpAccessChain %23 %19 %35 %21
///          %37 = OpLoad %7 %36
///          %38 = OpVectorShuffle %30 %37 %37 0 1 2
///          %40 = OpAccessChain %39 %19 %35 %35
///          %41 = OpLoad %6 %40
///          %42 = OpCompositeConstruct %30 %41 %41 %41
///          %43 = OpExtInst %30 %1 FMix %34 %38 %42
///          %47 = OpAccessChain %23 %19 %22
///          %48 = OpLoad %7 %47
///          %49 = OpVectorShuffle %30 %48 %48 0 1 2
///          %50 = OpAccessChain %39 %19 %21 %35 %14
///          %51 = OpLoad %6 %50
///          %52 = OpVectorTimesScalar %30 %49 %51
///          %53 = OpFAdd %30 %43 %52
///          %56 = OpCompositeExtract %6 %29 3
///          %57 = OpCompositeExtract %6 %53 0
///          %58 = OpCompositeExtract %6 %53 1
///          %59 = OpCompositeExtract %6 %53 2
///          %60 = OpCompositeConstruct %7 %57 %58 %59 %56
///                OpStore %45 %60
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_uniform_nested = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x0000003D, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x0000000B, 0x0000002D, 0x00030010,
    0x00000004, 0x00000007, 0x00040047, 0x0000000B, 0x0000001E, 0x00000000,
    0x00040047, 0x0000000F, 0x00000006, 0x00000010, 0x00050048, 0x00000010,
    0x00000000, 0x00000023, 0x00000000, 0x00050048, 0x00000010, 0x00000001,
    0x00000023, 0x00000010, 0x00030047, 0x00000011, 0x00000002, 0x00050048,
    0x00000011, 0x00000000, 0x00000023, 0x00000000, 0x00050048, 0x00000011,
    0x00000001, 0x00000023, 0x00000030, 0x00050048, 0x00000011, 0x00000002,
    0x00000023, 0x00000050, 0x00040047, 0x00000013, 0x00000021, 0x00000000,
    0x00040047, 0x00000013, 0x00000022, 0x00000000, 0x00040047, 0x0000002D,
    0x0000001E, 0x00000000, 0x00020013, 0x00000002, 0x00030021, 0x00000003,
    0x00000002, 0x00030016, 0x00000006, 0x00000020, 0x00040017, 0x00000007,
    0x00000006, 0x00000004, 0x00040020, 0x0000000A, 0x00000001, 0x00000007,
    0x0004003B, 0x0000000A, 0x0000000B, 0x00000001, 0x00040015, 0x0000000D,
    0x00000020, 0x00000000, 0x0004002B, 0x0000000D, 0x0000000E, 0x00000003,
    0x0004001C, 0x0000000F, 0x00000007, 0x0000000E, 0x0004001E, 0x00000010,
    0x00000007, 0x00000006, 0x0005001E, 0x00000011, 0x0000000F, 0x00000010,
    0x00000007, 0x00040020, 0x00000012, 0x00000002, 0x00000011, 0x0004003B,
    0x00000012, 0x00000013, 0x00000002, 0x00040015, 0x00000014, 0x00000020,
    0x00000001, 0x0004002B, 0x00000014, 0x00000015, 0x00000000, 0x0004002B,
    0x00000014, 0x00000016, 0x00000002, 0x00040020, 0x00000017, 0x00000002,
    0x00000007, 0x00040017, 0x0000001E, 0x00000006, 0x00000003, 0x0004002B,
    0x00000014, 0x00000023, 0x00000001, 0x00040020, 0x00000027, 0x00000002,
    0x00000006, 0x00040020, 0x0000002C, 0x00000003, 0x00000007, 0x0004003B,
    0x0000002C, 0x0000002D, 0x00000003, 0x00050036, 0x00000002, 0x00000004,
    0x00000000, 0x00000003, 0x000200F8, 0x00000005, 0x0004003D, 0x00000007,
    0x0000000C, 0x0000000B, 0x00060041, 0x00000017, 0x00000018, 0x00000013,
    0x00000015, 0x00000016, 0x0004003D, 0x00000007, 0x00000019, 0x00000018,
    0x00050085, 0x00000007, 0x0000001A, 0x0000000C, 0x00000019, 0x00060041,
    0x00000017, 0x0000001B, 0x00000013, 0x00000015, 0x00000015, 0x0004003D,
    0x00000007, 0x0000001C, 0x0000001B, 0x00050081, 0x00000007, 0x0000001D,
    0x0000001A, 0x0000001C, 0x0008004F, 0x0000001E, 0x00000022, 0x0000001D,
    0x0000001D, 0x00000000, 0x00000001, 0x00000002, 0x00060041, 0x00000017,
    0x00000024, 0x00000013, 0x00000023, 0x00000015, 0x0004003D, 0x00000007,
    0x00000025, 0x00000024, 0x0008004F, 0x0000001E, 0x00000026, 0x00000025,
    0x00000025, 0x00000000, 0x00000001, 0x00000002, 0x00060041, 0x00000027,
    0x00000028, 0x00000013, 0x00000023, 0x00000023, 0x0004003D, 0x00000006,
    0x00000029, 0x00000028, 0x00060050, 0x0000001E, 0x0000002A, 0x00000029,
    0x00000029, 0x00000029, 0x0008000C, 0x0000001E, 0x0000002B, 0x00000001,
    0x0000002E, 0x00000022, 0x00000026, 0x0000002A, 0x00050041, 0x00000017,
    0x0000002F, 0x00000013, 0x00000016, 0x0004003D, 0x00000007, 0x00000030,
    0x0000002F, 0x0008004F, 0x0000001E, 0x00000031, 0x00000030, 0x00000030,
    0x00000000, 0x00000001, 0x00000002, 0x00070041, 0x00000027, 0x00000032,
    0x00000013, 0x00000015, 0x00000023, 0x0000000E, 0x0004003D, 0x00000006,
    0x00000033, 0x00000032, 0x0005008E, 0x0000001E, 0x00000034, 0x00000031,
    0x00000033, 0x00050081, 0x0000001E, 0x00000035, 0x0000002B, 0x00000034,
    0x00050051, 0x00000006, 0x00000038, 0x0000001D, 0x00000003, 0x00050051,
    0x00000006, 0x00000039, 0x00000035, 0x00000000, 0x00050051, 0x00000006,
    0x0000003A, 0x00000035, 0x00000001, 0x00050051, 0x00000006, 0x0000003B,
    0x00000035, 0x00000002, 0x00070050, 0x00000007, 0x0000003C, 0x00000039,
    0x0000003A, 0x0000003B, 0x00000038, 0x0003003E, 0x0000002D, 0x0000003C,
    0x000100FD, 0x00010038,
};

/// glslc's own output, at `-O`, for a mat3 in a uniform buffer times a
/// vector: the matrix loaded whole, its three columns 16 bytes apart, and
/// OpMatrixTimesVector, which vtn's matrix_multiply makes the last column
/// times the vector's last float, then each column before it times its
/// float added on (vtn_alu.c:45-98; since 1.161).
///
/// ```glsl
/// #version 450
/// layout(location = 0) in vec4 vcolor;
/// layout(location = 0) out vec4 ocolor;
/// layout(set = 0, binding = 0) uniform Turn {
///     mat3 turn;
///     vec4 shift;
/// } t;
/// void main() {
///     vec3 turned = t.turn * vcolor.rgb;
///     ocolor = vec4(turned + t.shift.xyz, vcolor.a);
/// }
/// ```
///
/// ```sh
/// glslc -O -fshader-stage=frag matrix.frag -o matrix.spv   # 235 words
/// spirv-val --target-env vulkan1.0 matrix.spv              # no output, and 0
/// ```
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 43
/// ; Schema: 0
///                OpCapability Shader
///           %1 = OpExtInstImport "GLSL.std.450"
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %4 "main" %21 %26
///                OpExecutionMode %4 OriginUpperLeft
///                OpDecorate %12 Block
///                OpMemberDecorate %12 0 ColMajor
///                OpMemberDecorate %12 0 MatrixStride 16
///                OpMemberDecorate %12 0 Offset 0
///                OpMemberDecorate %12 1 Offset 48
///                OpDecorate %14 Binding 0
///                OpDecorate %14 DescriptorSet 0
///                OpDecorate %21 Location 0
///                OpDecorate %26 Location 0
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeFloat 32
///           %7 = OpTypeVector %6 3
///          %10 = OpTypeMatrix %7 3
///          %11 = OpTypeVector %6 4
///          %12 = OpTypeStruct %10 %11
///          %13 = OpTypePointer Uniform %12
///          %14 = OpVariable %13 Uniform
///          %15 = OpTypeInt 32 1
///          %16 = OpConstant %15 0
///          %17 = OpTypePointer Uniform %10
///          %20 = OpTypePointer Input %11
///          %21 = OpVariable %20 Input
///          %25 = OpTypePointer Output %11
///          %26 = OpVariable %25 Output
///          %28 = OpConstant %15 1
///          %29 = OpTypePointer Uniform %11
///          %34 = OpTypeInt 32 0
///          %35 = OpConstant %34 3
///          %36 = OpTypePointer Input %6
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///          %18 = OpAccessChain %17 %14 %16
///          %19 = OpLoad %10 %18
///          %22 = OpLoad %11 %21
///          %23 = OpVectorShuffle %7 %22 %22 0 1 2
///          %24 = OpMatrixTimesVector %7 %19 %23
///          %30 = OpAccessChain %29 %14 %28
///          %31 = OpLoad %11 %30
///          %32 = OpVectorShuffle %7 %31 %31 0 1 2
///          %33 = OpFAdd %7 %24 %32
///          %37 = OpAccessChain %36 %21 %35
///          %38 = OpLoad %6 %37
///          %39 = OpCompositeExtract %6 %33 0
///          %40 = OpCompositeExtract %6 %33 1
///          %41 = OpCompositeExtract %6 %33 2
///          %42 = OpCompositeConstruct %11 %39 %40 %41 %38
///                OpStore %26 %42
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_uniform_matrix = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x0000002B, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x00000015, 0x0000001A, 0x00030010,
    0x00000004, 0x00000007, 0x00030047, 0x0000000C, 0x00000002, 0x00040048,
    0x0000000C, 0x00000000, 0x00000005, 0x00050048, 0x0000000C, 0x00000000,
    0x00000007, 0x00000010, 0x00050048, 0x0000000C, 0x00000000, 0x00000023,
    0x00000000, 0x00050048, 0x0000000C, 0x00000001, 0x00000023, 0x00000030,
    0x00040047, 0x0000000E, 0x00000021, 0x00000000, 0x00040047, 0x0000000E,
    0x00000022, 0x00000000, 0x00040047, 0x00000015, 0x0000001E, 0x00000000,
    0x00040047, 0x0000001A, 0x0000001E, 0x00000000, 0x00020013, 0x00000002,
    0x00030021, 0x00000003, 0x00000002, 0x00030016, 0x00000006, 0x00000020,
    0x00040017, 0x00000007, 0x00000006, 0x00000003, 0x00040018, 0x0000000A,
    0x00000007, 0x00000003, 0x00040017, 0x0000000B, 0x00000006, 0x00000004,
    0x0004001E, 0x0000000C, 0x0000000A, 0x0000000B, 0x00040020, 0x0000000D,
    0x00000002, 0x0000000C, 0x0004003B, 0x0000000D, 0x0000000E, 0x00000002,
    0x00040015, 0x0000000F, 0x00000020, 0x00000001, 0x0004002B, 0x0000000F,
    0x00000010, 0x00000000, 0x00040020, 0x00000011, 0x00000002, 0x0000000A,
    0x00040020, 0x00000014, 0x00000001, 0x0000000B, 0x0004003B, 0x00000014,
    0x00000015, 0x00000001, 0x00040020, 0x00000019, 0x00000003, 0x0000000B,
    0x0004003B, 0x00000019, 0x0000001A, 0x00000003, 0x0004002B, 0x0000000F,
    0x0000001C, 0x00000001, 0x00040020, 0x0000001D, 0x00000002, 0x0000000B,
    0x00040015, 0x00000022, 0x00000020, 0x00000000, 0x0004002B, 0x00000022,
    0x00000023, 0x00000003, 0x00040020, 0x00000024, 0x00000001, 0x00000006,
    0x00050036, 0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200F8,
    0x00000005, 0x00050041, 0x00000011, 0x00000012, 0x0000000E, 0x00000010,
    0x0004003D, 0x0000000A, 0x00000013, 0x00000012, 0x0004003D, 0x0000000B,
    0x00000016, 0x00000015, 0x0008004F, 0x00000007, 0x00000017, 0x00000016,
    0x00000016, 0x00000000, 0x00000001, 0x00000002, 0x00050091, 0x00000007,
    0x00000018, 0x00000013, 0x00000017, 0x00050041, 0x0000001D, 0x0000001E,
    0x0000000E, 0x0000001C, 0x0004003D, 0x0000000B, 0x0000001F, 0x0000001E,
    0x0008004F, 0x00000007, 0x00000020, 0x0000001F, 0x0000001F, 0x00000000,
    0x00000001, 0x00000002, 0x00050081, 0x00000007, 0x00000021, 0x00000018,
    0x00000020, 0x00050041, 0x00000024, 0x00000025, 0x00000015, 0x00000023,
    0x0004003D, 0x00000006, 0x00000026, 0x00000025, 0x00050051, 0x00000006,
    0x00000027, 0x00000021, 0x00000000, 0x00050051, 0x00000006, 0x00000028,
    0x00000021, 0x00000001, 0x00050051, 0x00000006, 0x00000029, 0x00000021,
    0x00000002, 0x00070050, 0x0000000B, 0x0000002A, 0x00000027, 0x00000028,
    0x00000029, 0x00000026, 0x0003003E, 0x0000001A, 0x0000002A, 0x000100FD,
    0x00010038,
};

/// glslc's own output, at `-O`, for the rest of what SPIR-V does with
/// matrices: two built of columns, a transpose, a matrix times a matrix and
/// times a scalar, a vector times a matrix, a mat3x2 times a vec3, an outer
/// product, and a matrix's column and one float of it extracted. spirv-opt
/// has made the sum, the difference and the negation columns of vector
/// arithmetic, as SPIR-V gives OpFAdd, OpFSub and OpFNegate no matrices
/// (since 1.161).
///
/// ```glsl
/// #version 450
/// layout(location = 0) in vec4 vcolor;
/// layout(location = 0) out vec4 ocolor;
/// layout(set = 0, binding = 0) uniform Mats {
///     mat2 a;
///     mat2 b;
///     mat3x2 c;
///     vec4 pad;
/// } m;
/// void main() {
///     mat2 sum = m.a + m.b;
///     mat2 diff = m.a - m.b;
///     mat2 prod = sum * transpose(diff) * vcolor.w;
///     vec2 left = vcolor.xy * prod;
///     vec2 right = (-m.a) * vcolor.zw;
///     vec2 cs = m.c * vcolor.xyz;
///     mat2 made = mat2(vcolor.xy, vcolor.zw);
///     vec2 col = made[1] + prod[0];
///     mat2 outer = outerProduct(vcolor.xy, m.pad.zw);
///     ocolor = vec4(left + right, cs.x + col.y * col.x, prod[1][0] + m.pad.x + outer[1].x);
/// }
/// ```
///
/// ```sh
/// glslc -O -fshader-stage=frag matrices.frag -o matrices.spv   # 493 words
/// spirv-val --target-env vulkan1.0 matrices.spv                # no output, and 0
/// ```
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 139
/// ; Schema: 0
///                OpCapability Shader
///           %1 = OpExtInstImport "GLSL.std.450"
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %4 "main" %49 %112
///                OpExecutionMode %4 OriginUpperLeft
///                OpDecorate %13 Block
///                OpMemberDecorate %13 0 ColMajor
///                OpMemberDecorate %13 0 MatrixStride 16
///                OpMemberDecorate %13 0 Offset 0
///                OpMemberDecorate %13 1 ColMajor
///                OpMemberDecorate %13 1 MatrixStride 16
///                OpMemberDecorate %13 1 Offset 32
///                OpMemberDecorate %13 2 ColMajor
///                OpMemberDecorate %13 2 MatrixStride 16
///                OpMemberDecorate %13 2 Offset 64
///                OpMemberDecorate %13 3 Offset 112
///                OpDecorate %15 Binding 0
///                OpDecorate %15 DescriptorSet 0
///                OpDecorate %49 Location 0
///                OpDecorate %112 Location 0
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeFloat 32
///           %7 = OpTypeVector %6 2
///           %8 = OpTypeMatrix %7 2
///          %11 = OpTypeMatrix %7 3
///          %12 = OpTypeVector %6 4
///          %13 = OpTypeStruct %8 %8 %11 %12
///          %14 = OpTypePointer Uniform %13
///          %15 = OpVariable %14 Uniform
///          %16 = OpTypeInt 32 1
///          %17 = OpConstant %16 0
///          %18 = OpTypePointer Uniform %8
///          %21 = OpConstant %16 1
///          %48 = OpTypePointer Input %12
///          %49 = OpVariable %48 Input
///          %50 = OpTypeInt 32 0
///          %51 = OpConstant %50 3
///          %52 = OpTypePointer Input %6
///          %74 = OpConstant %16 2
///          %75 = OpTypePointer Uniform %11
///          %78 = OpTypeVector %6 3
///         %105 = OpConstant %16 3
///         %106 = OpTypePointer Uniform %12
///         %111 = OpTypePointer Output %12
///         %112 = OpVariable %111 Output
///         %116 = OpConstant %50 0
///         %129 = OpTypePointer Uniform %6
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///          %19 = OpAccessChain %18 %15 %17
///          %20 = OpLoad %8 %19
///          %22 = OpAccessChain %18 %15 %21
///          %23 = OpLoad %8 %22
///          %24 = OpCompositeExtract %7 %20 0
///          %25 = OpCompositeExtract %7 %23 0
///          %26 = OpFAdd %7 %24 %25
///          %27 = OpCompositeExtract %7 %20 1
///          %28 = OpCompositeExtract %7 %23 1
///          %29 = OpFAdd %7 %27 %28
///          %30 = OpCompositeConstruct %8 %26 %29
///          %38 = OpFSub %7 %24 %25
///          %41 = OpFSub %7 %27 %28
///          %42 = OpCompositeConstruct %8 %38 %41
///          %46 = OpTranspose %8 %42
///          %47 = OpMatrixTimesMatrix %8 %30 %46
///          %53 = OpAccessChain %52 %49 %51
///          %54 = OpLoad %6 %53
///          %55 = OpMatrixTimesScalar %8 %47 %54
///          %58 = OpLoad %12 %49
///          %59 = OpVectorShuffle %7 %58 %58 0 1
///          %61 = OpVectorTimesMatrix %7 %59 %55
///          %66 = OpFNegate %7 %24
///          %68 = OpFNegate %7 %27
///          %69 = OpCompositeConstruct %8 %66 %68
///          %71 = OpVectorShuffle %7 %58 %58 2 3
///          %72 = OpMatrixTimesVector %7 %69 %71
///          %76 = OpAccessChain %75 %15 %74
///          %77 = OpLoad %11 %76
///          %80 = OpVectorShuffle %78 %58 %58 0 1 2
///          %81 = OpMatrixTimesVector %7 %77 %80
///          %91 = OpCompositeExtract %6 %58 2
///          %92 = OpCompositeExtract %6 %58 3
///          %94 = OpCompositeConstruct %7 %91 %92
///         %100 = OpCompositeExtract %7 %55 0
///         %101 = OpFAdd %7 %94 %100
///         %107 = OpAccessChain %106 %15 %105
///         %108 = OpLoad %12 %107
///         %109 = OpVectorShuffle %7 %108 %108 2 3
///         %110 = OpOuterProduct %8 %59 %109
///         %115 = OpFAdd %7 %61 %72
///         %119 = OpCompositeExtract %6 %81 0
///         %122 = OpCompositeExtract %6 %101 1
///         %124 = OpCompositeExtract %6 %101 0
///         %125 = OpFMul %6 %122 %124
///         %126 = OpFAdd %6 %119 %125
///         %128 = OpCompositeExtract %6 %55 1 0
///         %130 = OpAccessChain %129 %15 %105 %116
///         %131 = OpLoad %6 %130
///         %132 = OpFAdd %6 %128 %131
///         %134 = OpCompositeExtract %6 %110 1 0
///         %135 = OpFAdd %6 %132 %134
///         %136 = OpCompositeExtract %6 %115 0
///         %137 = OpCompositeExtract %6 %115 1
///         %138 = OpCompositeConstruct %12 %136 %137 %126 %135
///                OpStore %112 %138
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_uniform_matrices = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x0000008B, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x00000031, 0x00000070, 0x00030010,
    0x00000004, 0x00000007, 0x00030047, 0x0000000D, 0x00000002, 0x00040048,
    0x0000000D, 0x00000000, 0x00000005, 0x00050048, 0x0000000D, 0x00000000,
    0x00000007, 0x00000010, 0x00050048, 0x0000000D, 0x00000000, 0x00000023,
    0x00000000, 0x00040048, 0x0000000D, 0x00000001, 0x00000005, 0x00050048,
    0x0000000D, 0x00000001, 0x00000007, 0x00000010, 0x00050048, 0x0000000D,
    0x00000001, 0x00000023, 0x00000020, 0x00040048, 0x0000000D, 0x00000002,
    0x00000005, 0x00050048, 0x0000000D, 0x00000002, 0x00000007, 0x00000010,
    0x00050048, 0x0000000D, 0x00000002, 0x00000023, 0x00000040, 0x00050048,
    0x0000000D, 0x00000003, 0x00000023, 0x00000070, 0x00040047, 0x0000000F,
    0x00000021, 0x00000000, 0x00040047, 0x0000000F, 0x00000022, 0x00000000,
    0x00040047, 0x00000031, 0x0000001E, 0x00000000, 0x00040047, 0x00000070,
    0x0000001E, 0x00000000, 0x00020013, 0x00000002, 0x00030021, 0x00000003,
    0x00000002, 0x00030016, 0x00000006, 0x00000020, 0x00040017, 0x00000007,
    0x00000006, 0x00000002, 0x00040018, 0x00000008, 0x00000007, 0x00000002,
    0x00040018, 0x0000000B, 0x00000007, 0x00000003, 0x00040017, 0x0000000C,
    0x00000006, 0x00000004, 0x0006001E, 0x0000000D, 0x00000008, 0x00000008,
    0x0000000B, 0x0000000C, 0x00040020, 0x0000000E, 0x00000002, 0x0000000D,
    0x0004003B, 0x0000000E, 0x0000000F, 0x00000002, 0x00040015, 0x00000010,
    0x00000020, 0x00000001, 0x0004002B, 0x00000010, 0x00000011, 0x00000000,
    0x00040020, 0x00000012, 0x00000002, 0x00000008, 0x0004002B, 0x00000010,
    0x00000015, 0x00000001, 0x00040020, 0x00000030, 0x00000001, 0x0000000C,
    0x0004003B, 0x00000030, 0x00000031, 0x00000001, 0x00040015, 0x00000032,
    0x00000020, 0x00000000, 0x0004002B, 0x00000032, 0x00000033, 0x00000003,
    0x00040020, 0x00000034, 0x00000001, 0x00000006, 0x0004002B, 0x00000010,
    0x0000004A, 0x00000002, 0x00040020, 0x0000004B, 0x00000002, 0x0000000B,
    0x00040017, 0x0000004E, 0x00000006, 0x00000003, 0x0004002B, 0x00000010,
    0x00000069, 0x00000003, 0x00040020, 0x0000006A, 0x00000002, 0x0000000C,
    0x00040020, 0x0000006F, 0x00000003, 0x0000000C, 0x0004003B, 0x0000006F,
    0x00000070, 0x00000003, 0x0004002B, 0x00000032, 0x00000074, 0x00000000,
    0x00040020, 0x00000081, 0x00000002, 0x00000006, 0x00050036, 0x00000002,
    0x00000004, 0x00000000, 0x00000003, 0x000200F8, 0x00000005, 0x00050041,
    0x00000012, 0x00000013, 0x0000000F, 0x00000011, 0x0004003D, 0x00000008,
    0x00000014, 0x00000013, 0x00050041, 0x00000012, 0x00000016, 0x0000000F,
    0x00000015, 0x0004003D, 0x00000008, 0x00000017, 0x00000016, 0x00050051,
    0x00000007, 0x00000018, 0x00000014, 0x00000000, 0x00050051, 0x00000007,
    0x00000019, 0x00000017, 0x00000000, 0x00050081, 0x00000007, 0x0000001A,
    0x00000018, 0x00000019, 0x00050051, 0x00000007, 0x0000001B, 0x00000014,
    0x00000001, 0x00050051, 0x00000007, 0x0000001C, 0x00000017, 0x00000001,
    0x00050081, 0x00000007, 0x0000001D, 0x0000001B, 0x0000001C, 0x00050050,
    0x00000008, 0x0000001E, 0x0000001A, 0x0000001D, 0x00050083, 0x00000007,
    0x00000026, 0x00000018, 0x00000019, 0x00050083, 0x00000007, 0x00000029,
    0x0000001B, 0x0000001C, 0x00050050, 0x00000008, 0x0000002A, 0x00000026,
    0x00000029, 0x00040054, 0x00000008, 0x0000002E, 0x0000002A, 0x00050092,
    0x00000008, 0x0000002F, 0x0000001E, 0x0000002E, 0x00050041, 0x00000034,
    0x00000035, 0x00000031, 0x00000033, 0x0004003D, 0x00000006, 0x00000036,
    0x00000035, 0x0005008F, 0x00000008, 0x00000037, 0x0000002F, 0x00000036,
    0x0004003D, 0x0000000C, 0x0000003A, 0x00000031, 0x0007004F, 0x00000007,
    0x0000003B, 0x0000003A, 0x0000003A, 0x00000000, 0x00000001, 0x00050090,
    0x00000007, 0x0000003D, 0x0000003B, 0x00000037, 0x0004007F, 0x00000007,
    0x00000042, 0x00000018, 0x0004007F, 0x00000007, 0x00000044, 0x0000001B,
    0x00050050, 0x00000008, 0x00000045, 0x00000042, 0x00000044, 0x0007004F,
    0x00000007, 0x00000047, 0x0000003A, 0x0000003A, 0x00000002, 0x00000003,
    0x00050091, 0x00000007, 0x00000048, 0x00000045, 0x00000047, 0x00050041,
    0x0000004B, 0x0000004C, 0x0000000F, 0x0000004A, 0x0004003D, 0x0000000B,
    0x0000004D, 0x0000004C, 0x0008004F, 0x0000004E, 0x00000050, 0x0000003A,
    0x0000003A, 0x00000000, 0x00000001, 0x00000002, 0x00050091, 0x00000007,
    0x00000051, 0x0000004D, 0x00000050, 0x00050051, 0x00000006, 0x0000005B,
    0x0000003A, 0x00000002, 0x00050051, 0x00000006, 0x0000005C, 0x0000003A,
    0x00000003, 0x00050050, 0x00000007, 0x0000005E, 0x0000005B, 0x0000005C,
    0x00050051, 0x00000007, 0x00000064, 0x00000037, 0x00000000, 0x00050081,
    0x00000007, 0x00000065, 0x0000005E, 0x00000064, 0x00050041, 0x0000006A,
    0x0000006B, 0x0000000F, 0x00000069, 0x0004003D, 0x0000000C, 0x0000006C,
    0x0000006B, 0x0007004F, 0x00000007, 0x0000006D, 0x0000006C, 0x0000006C,
    0x00000002, 0x00000003, 0x00050093, 0x00000008, 0x0000006E, 0x0000003B,
    0x0000006D, 0x00050081, 0x00000007, 0x00000073, 0x0000003D, 0x00000048,
    0x00050051, 0x00000006, 0x00000077, 0x00000051, 0x00000000, 0x00050051,
    0x00000006, 0x0000007A, 0x00000065, 0x00000001, 0x00050051, 0x00000006,
    0x0000007C, 0x00000065, 0x00000000, 0x00050085, 0x00000006, 0x0000007D,
    0x0000007A, 0x0000007C, 0x00050081, 0x00000006, 0x0000007E, 0x00000077,
    0x0000007D, 0x00060051, 0x00000006, 0x00000080, 0x00000037, 0x00000001,
    0x00000000, 0x00060041, 0x00000081, 0x00000082, 0x0000000F, 0x00000069,
    0x00000074, 0x0004003D, 0x00000006, 0x00000083, 0x00000082, 0x00050081,
    0x00000006, 0x00000084, 0x00000080, 0x00000083, 0x00060051, 0x00000006,
    0x00000086, 0x0000006E, 0x00000001, 0x00000000, 0x00050081, 0x00000006,
    0x00000087, 0x00000084, 0x00000086, 0x00050051, 0x00000006, 0x00000088,
    0x00000073, 0x00000000, 0x00050051, 0x00000006, 0x00000089, 0x00000073,
    0x00000001, 0x00070050, 0x0000000C, 0x0000008A, 0x00000088, 0x00000089,
    0x0000007E, 0x00000087, 0x0003003E, 0x00000070, 0x0000008A, 0x000100FD,
    0x00010038,
};

/// glslc's own output, at `-O`, for a constant mat3 times a vector: the
/// matrix an OpConstantComposite of three constant columns, each a load_const
/// of its own as vtn_const_ssa_value makes it (spirv_to_nir.c:544-552), then
/// OpMatrixTimesVector as of a matrix in a buffer (since 1.162). No float of
/// the matrix or of the vector subtracted is 0 or 1, which
/// nir_opt_algebraic's rules would take out (nir_opt_algebraic.py:236-237,
/// 282-283, 292) and the compiler does not have; none is a power of two or
/// another's size.
///
/// ```glsl
/// #version 450
/// layout(location = 0) in vec4 vcolor;
/// layout(location = 0) out vec4 ocolor;
/// const mat3 turn = mat3(-0.78125, -0.28125, -0.5625,
///                        -0.4375, -0.53125, -0.3125,
///                        -0.375, -0.71875, -0.8125);
/// void main() {
///     ocolor = vec4(turn * (vcolor.rgb - vec3(0.90625, 0.84375, 0.46875)), vcolor.a);
/// }
/// ```
///
/// ```sh
/// glslc -O -fshader-stage=frag constmat.frag -o constmat.spv   # 225 words
/// spirv-val --target-env vulkan1.0 constmat.spv                # no output, and 0
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
///                OpEntryPoint Fragment %4 "main" %9 %26
///                OpExecutionMode %4 OriginUpperLeft
///                OpDecorate %9 Location 0
///                OpDecorate %26 Location 0
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeFloat 32
///           %7 = OpTypeVector %6 4
///           %8 = OpTypePointer Output %7
///           %9 = OpVariable %8 Output
///          %10 = OpTypeVector %6 3
///          %11 = OpTypeMatrix %10 3
///          %12 = OpConstant %6 -0.78125
///          %13 = OpConstant %6 -0.28125
///          %14 = OpConstant %6 -0.5625
///          %15 = OpConstantComposite %10 %12 %13 %14
///          %16 = OpConstant %6 -0.4375
///          %17 = OpConstant %6 -0.53125
///          %18 = OpConstant %6 -0.3125
///          %19 = OpConstantComposite %10 %16 %17 %18
///          %20 = OpConstant %6 -0.375
///          %21 = OpConstant %6 -0.71875
///          %22 = OpConstant %6 -0.8125
///          %23 = OpConstantComposite %10 %20 %21 %22
///          %24 = OpConstantComposite %11 %15 %19 %23
///          %25 = OpTypePointer Input %7
///          %26 = OpVariable %25 Input
///          %29 = OpConstant %6 0.90625
///          %30 = OpConstant %6 0.84375
///          %31 = OpConstant %6 0.46875
///          %32 = OpConstantComposite %10 %29 %30 %31
///          %35 = OpTypeInt 32 0
///          %36 = OpConstant %35 3
///          %37 = OpTypePointer Input %6
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///          %27 = OpLoad %7 %26
///          %28 = OpVectorShuffle %10 %27 %27 0 1 2
///          %33 = OpFSub %10 %28 %32
///          %34 = OpMatrixTimesVector %10 %24 %33
///          %38 = OpAccessChain %37 %26 %36
///          %39 = OpLoad %6 %38
///          %40 = OpCompositeExtract %6 %34 0
///          %41 = OpCompositeExtract %6 %34 1
///          %42 = OpCompositeExtract %6 %34 2
///          %43 = OpCompositeConstruct %7 %40 %41 %42 %39
///                OpStore %9 %43
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_constant_matrix = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x0000002C, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x00000009, 0x0000001A, 0x00030010,
    0x00000004, 0x00000007, 0x00040047, 0x00000009, 0x0000001E, 0x00000000,
    0x00040047, 0x0000001A, 0x0000001E, 0x00000000, 0x00020013, 0x00000002,
    0x00030021, 0x00000003, 0x00000002, 0x00030016, 0x00000006, 0x00000020,
    0x00040017, 0x00000007, 0x00000006, 0x00000004, 0x00040020, 0x00000008,
    0x00000003, 0x00000007, 0x0004003B, 0x00000008, 0x00000009, 0x00000003,
    0x00040017, 0x0000000A, 0x00000006, 0x00000003, 0x00040018, 0x0000000B,
    0x0000000A, 0x00000003, 0x0004002B, 0x00000006, 0x0000000C, 0xBF480000,
    0x0004002B, 0x00000006, 0x0000000D, 0xBE900000, 0x0004002B, 0x00000006,
    0x0000000E, 0xBF100000, 0x0006002C, 0x0000000A, 0x0000000F, 0x0000000C,
    0x0000000D, 0x0000000E, 0x0004002B, 0x00000006, 0x00000010, 0xBEE00000,
    0x0004002B, 0x00000006, 0x00000011, 0xBF080000, 0x0004002B, 0x00000006,
    0x00000012, 0xBEA00000, 0x0006002C, 0x0000000A, 0x00000013, 0x00000010,
    0x00000011, 0x00000012, 0x0004002B, 0x00000006, 0x00000014, 0xBEC00000,
    0x0004002B, 0x00000006, 0x00000015, 0xBF380000, 0x0004002B, 0x00000006,
    0x00000016, 0xBF500000, 0x0006002C, 0x0000000A, 0x00000017, 0x00000014,
    0x00000015, 0x00000016, 0x0006002C, 0x0000000B, 0x00000018, 0x0000000F,
    0x00000013, 0x00000017, 0x00040020, 0x00000019, 0x00000001, 0x00000007,
    0x0004003B, 0x00000019, 0x0000001A, 0x00000001, 0x0004002B, 0x00000006,
    0x0000001D, 0x3F680000, 0x0004002B, 0x00000006, 0x0000001E, 0x3F580000,
    0x0004002B, 0x00000006, 0x0000001F, 0x3EF00000, 0x0006002C, 0x0000000A,
    0x00000020, 0x0000001D, 0x0000001E, 0x0000001F, 0x00040015, 0x00000023,
    0x00000020, 0x00000000, 0x0004002B, 0x00000023, 0x00000024, 0x00000003,
    0x00040020, 0x00000025, 0x00000001, 0x00000006, 0x00050036, 0x00000002,
    0x00000004, 0x00000000, 0x00000003, 0x000200F8, 0x00000005, 0x0004003D,
    0x00000007, 0x0000001B, 0x0000001A, 0x0008004F, 0x0000000A, 0x0000001C,
    0x0000001B, 0x0000001B, 0x00000000, 0x00000001, 0x00000002, 0x00050083,
    0x0000000A, 0x00000021, 0x0000001C, 0x00000020, 0x00050091, 0x0000000A,
    0x00000022, 0x00000018, 0x00000021, 0x00050041, 0x00000025, 0x00000026,
    0x0000001A, 0x00000024, 0x0004003D, 0x00000006, 0x00000027, 0x00000026,
    0x00050051, 0x00000006, 0x00000028, 0x00000022, 0x00000000, 0x00050051,
    0x00000006, 0x00000029, 0x00000022, 0x00000001, 0x00050051, 0x00000006,
    0x0000002A, 0x00000022, 0x00000002, 0x00070050, 0x00000007, 0x0000002B,
    0x00000028, 0x00000029, 0x0000002A, 0x00000027, 0x0003003E, 0x00000009,
    0x0000002B, 0x000100FD, 0x00010038,
};

/// FacetBoth's "as it is" vertex function as a vertex shader, glslc -O
/// (`-fshader-stage=vert`), 239 words: the corner's place
/// moved by the instance's offset times its W, and its colour handed on.
/// Since 1.163 Mesa's back end compiles it for the QPU, the vertex program
/// and the coordinate program both.
///
/// ```glsl
/// #version 450
/// layout(location = 0) in vec4 p;
/// layout(location = 1) in vec4 c;
/// layout(location = 3) in vec2 moved;
/// layout(location = 0) out vec4 vcolor;
/// void main() {
///     gl_Position = vec4(p.xy + moved * p.w, p.z, p.w);
///     vcolor = c;
/// }
/// ```
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 43
/// ; Schema: 0
///                OpCapability Shader
///           %1 = OpExtInstImport "GLSL.std.450"
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Vertex %4 "main" %13 %17 %22 %40 %41
///                OpDecorate %11 Block
///                OpMemberDecorate %11 0 BuiltIn Position
///                OpMemberDecorate %11 1 BuiltIn PointSize
///                OpMemberDecorate %11 2 BuiltIn ClipDistance
///                OpMemberDecorate %11 3 BuiltIn CullDistance
///                OpDecorate %17 Location 0
///                OpDecorate %22 Location 3
///                OpDecorate %40 Location 0
///                OpDecorate %41 Location 1
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeFloat 32
///           %7 = OpTypeVector %6 4
///           %8 = OpTypeInt 32 0
///           %9 = OpConstant %8 1
///          %10 = OpTypeArray %6 %9
///          %11 = OpTypeStruct %7 %6 %10 %10
///          %12 = OpTypePointer Output %11
///          %13 = OpVariable %12 Output
///          %14 = OpTypeInt 32 1
///          %15 = OpConstant %14 0
///          %16 = OpTypePointer Input %7
///          %17 = OpVariable %16 Input
///          %18 = OpTypeVector %6 2
///          %21 = OpTypePointer Input %18
///          %22 = OpVariable %21 Input
///          %24 = OpConstant %8 3
///          %25 = OpTypePointer Input %6
///          %30 = OpConstant %8 2
///          %38 = OpTypePointer Output %7
///          %40 = OpVariable %38 Output
///          %41 = OpVariable %16 Input
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///          %19 = OpLoad %7 %17
///          %20 = OpVectorShuffle %18 %19 %19 0 1
///          %23 = OpLoad %18 %22
///          %26 = OpAccessChain %25 %17 %24
///          %27 = OpLoad %6 %26
///          %28 = OpVectorTimesScalar %18 %23 %27
///          %29 = OpFAdd %18 %20 %28
///          %31 = OpAccessChain %25 %17 %30
///          %32 = OpLoad %6 %31
///          %35 = OpCompositeExtract %6 %29 0
///          %36 = OpCompositeExtract %6 %29 1
///          %37 = OpCompositeConstruct %7 %35 %36 %32 %27
///          %39 = OpAccessChain %38 %13 %15
///                OpStore %39 %37
///          %42 = OpLoad %7 %41
///                OpStore %40 %42
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_vertex_as_it_is = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x0000002B, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x000A000F, 0x00000000,
    0x00000004, 0x6E69616D, 0x00000000, 0x0000000D, 0x00000011, 0x00000016,
    0x00000028, 0x00000029, 0x00030047, 0x0000000B, 0x00000002, 0x00050048,
    0x0000000B, 0x00000000, 0x0000000B, 0x00000000, 0x00050048, 0x0000000B,
    0x00000001, 0x0000000B, 0x00000001, 0x00050048, 0x0000000B, 0x00000002,
    0x0000000B, 0x00000003, 0x00050048, 0x0000000B, 0x00000003, 0x0000000B,
    0x00000004, 0x00040047, 0x00000011, 0x0000001E, 0x00000000, 0x00040047,
    0x00000016, 0x0000001E, 0x00000003, 0x00040047, 0x00000028, 0x0000001E,
    0x00000000, 0x00040047, 0x00000029, 0x0000001E, 0x00000001, 0x00020013,
    0x00000002, 0x00030021, 0x00000003, 0x00000002, 0x00030016, 0x00000006,
    0x00000020, 0x00040017, 0x00000007, 0x00000006, 0x00000004, 0x00040015,
    0x00000008, 0x00000020, 0x00000000, 0x0004002B, 0x00000008, 0x00000009,
    0x00000001, 0x0004001C, 0x0000000A, 0x00000006, 0x00000009, 0x0006001E,
    0x0000000B, 0x00000007, 0x00000006, 0x0000000A, 0x0000000A, 0x00040020,
    0x0000000C, 0x00000003, 0x0000000B, 0x0004003B, 0x0000000C, 0x0000000D,
    0x00000003, 0x00040015, 0x0000000E, 0x00000020, 0x00000001, 0x0004002B,
    0x0000000E, 0x0000000F, 0x00000000, 0x00040020, 0x00000010, 0x00000001,
    0x00000007, 0x0004003B, 0x00000010, 0x00000011, 0x00000001, 0x00040017,
    0x00000012, 0x00000006, 0x00000002, 0x00040020, 0x00000015, 0x00000001,
    0x00000012, 0x0004003B, 0x00000015, 0x00000016, 0x00000001, 0x0004002B,
    0x00000008, 0x00000018, 0x00000003, 0x00040020, 0x00000019, 0x00000001,
    0x00000006, 0x0004002B, 0x00000008, 0x0000001E, 0x00000002, 0x00040020,
    0x00000026, 0x00000003, 0x00000007, 0x0004003B, 0x00000026, 0x00000028,
    0x00000003, 0x0004003B, 0x00000010, 0x00000029, 0x00000001, 0x00050036,
    0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200F8, 0x00000005,
    0x0004003D, 0x00000007, 0x00000013, 0x00000011, 0x0007004F, 0x00000012,
    0x00000014, 0x00000013, 0x00000013, 0x00000000, 0x00000001, 0x0004003D,
    0x00000012, 0x00000017, 0x00000016, 0x00050041, 0x00000019, 0x0000001A,
    0x00000011, 0x00000018, 0x0004003D, 0x00000006, 0x0000001B, 0x0000001A,
    0x0005008E, 0x00000012, 0x0000001C, 0x00000017, 0x0000001B, 0x00050081,
    0x00000012, 0x0000001D, 0x00000014, 0x0000001C, 0x00050041, 0x00000019,
    0x0000001F, 0x00000011, 0x0000001E, 0x0004003D, 0x00000006, 0x00000020,
    0x0000001F, 0x00050051, 0x00000006, 0x00000023, 0x0000001D, 0x00000000,
    0x00050051, 0x00000006, 0x00000024, 0x0000001D, 0x00000001, 0x00070050,
    0x00000007, 0x00000025, 0x00000023, 0x00000024, 0x00000020, 0x0000001B,
    0x00050041, 0x00000026, 0x00000027, 0x0000000D, 0x0000000F, 0x0003003E,
    0x00000027, 0x00000025, 0x0004003D, 0x00000007, 0x0000002A, 0x00000029,
    0x0003003E, 0x00000028, 0x0000002A, 0x000100FD, 0x00010038,
};

/// A storage buffer read at constant offsets, glslc -O
/// (`-fshader-stage=frag`), 206 words: the colour times the buffer's tint
/// and its scale, plus the third of its values. The buffer is `readonly`,
/// so glslc decorates its block BufferBlock and its members and variable
/// NonWritable, and its last member is a runtime array. Since 1.164 Mesa's
/// back end reads it through unifa, as a load_ssbo of a buffer the program
/// does not write (ntq_emit_load_unifa, nir_to_vir.c:3299-3507).
///
/// ```glsl
/// #version 450
/// layout(location = 0) in vec4 vcolor;
/// layout(location = 0) out vec4 ocolor;
/// layout(std430, set = 0, binding = 0) readonly buffer Tints {
///     vec4 tint;
///     float scale;
///     vec4 values[];
/// } tints;
/// void main() {
///     ocolor = vcolor * tints.tint * tints.scale + tints.values[2];
/// }
/// ```
///
/// ```sh
/// glslc -O -fshader-stage=frag ssbo.frag -o ssbo.spv   # 206 words
/// spirv-val --target-env vulkan1.0 ssbo.spv          # no output, and 0
/// ```
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 32
/// ; Schema: 0
///                OpCapability Shader
///           %1 = OpExtInstImport "GLSL.std.450"
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %4 "main" %9 %11
///                OpExecutionMode %4 OriginUpperLeft
///                OpDecorate %9 Location 0
///                OpDecorate %11 Location 0
///                OpDecorate %13 ArrayStride 16
///                OpDecorate %14 BufferBlock
///                OpMemberDecorate %14 0 NonWritable
///                OpMemberDecorate %14 0 Offset 0
///                OpMemberDecorate %14 1 NonWritable
///                OpMemberDecorate %14 1 Offset 16
///                OpMemberDecorate %14 2 NonWritable
///                OpMemberDecorate %14 2 Offset 32
///                OpDecorate %16 NonWritable
///                OpDecorate %16 Binding 0
///                OpDecorate %16 DescriptorSet 0
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeFloat 32
///           %7 = OpTypeVector %6 4
///           %8 = OpTypePointer Output %7
///           %9 = OpVariable %8 Output
///          %10 = OpTypePointer Input %7
///          %11 = OpVariable %10 Input
///          %13 = OpTypeRuntimeArray %7
///          %14 = OpTypeStruct %7 %6 %13
///          %15 = OpTypePointer Uniform %14
///          %16 = OpVariable %15 Uniform
///          %17 = OpTypeInt 32 1
///          %18 = OpConstant %17 0
///          %19 = OpTypePointer Uniform %7
///          %23 = OpConstant %17 1
///          %24 = OpTypePointer Uniform %6
///          %28 = OpConstant %17 2
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///          %12 = OpLoad %7 %11
///          %20 = OpAccessChain %19 %16 %18
///          %21 = OpLoad %7 %20
///          %22 = OpFMul %7 %12 %21
///          %25 = OpAccessChain %24 %16 %23
///          %26 = OpLoad %6 %25
///          %27 = OpVectorTimesScalar %7 %22 %26
///          %29 = OpAccessChain %19 %16 %28 %28
///          %30 = OpLoad %7 %29
///          %31 = OpFAdd %7 %27 %30
///                OpStore %9 %31
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_storage_buffer = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x00000020, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x00000009, 0x0000000B, 0x00030010,
    0x00000004, 0x00000007, 0x00040047, 0x00000009, 0x0000001E, 0x00000000,
    0x00040047, 0x0000000B, 0x0000001E, 0x00000000, 0x00040047, 0x0000000D,
    0x00000006, 0x00000010, 0x00030047, 0x0000000E, 0x00000003, 0x00040048,
    0x0000000E, 0x00000000, 0x00000018, 0x00050048, 0x0000000E, 0x00000000,
    0x00000023, 0x00000000, 0x00040048, 0x0000000E, 0x00000001, 0x00000018,
    0x00050048, 0x0000000E, 0x00000001, 0x00000023, 0x00000010, 0x00040048,
    0x0000000E, 0x00000002, 0x00000018, 0x00050048, 0x0000000E, 0x00000002,
    0x00000023, 0x00000020, 0x00030047, 0x00000010, 0x00000018, 0x00040047,
    0x00000010, 0x00000021, 0x00000000, 0x00040047, 0x00000010, 0x00000022,
    0x00000000, 0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002,
    0x00030016, 0x00000006, 0x00000020, 0x00040017, 0x00000007, 0x00000006,
    0x00000004, 0x00040020, 0x00000008, 0x00000003, 0x00000007, 0x0004003B,
    0x00000008, 0x00000009, 0x00000003, 0x00040020, 0x0000000A, 0x00000001,
    0x00000007, 0x0004003B, 0x0000000A, 0x0000000B, 0x00000001, 0x0003001D,
    0x0000000D, 0x00000007, 0x0005001E, 0x0000000E, 0x00000007, 0x00000006,
    0x0000000D, 0x00040020, 0x0000000F, 0x00000002, 0x0000000E, 0x0004003B,
    0x0000000F, 0x00000010, 0x00000002, 0x00040015, 0x00000011, 0x00000020,
    0x00000001, 0x0004002B, 0x00000011, 0x00000012, 0x00000000, 0x00040020,
    0x00000013, 0x00000002, 0x00000007, 0x0004002B, 0x00000011, 0x00000017,
    0x00000001, 0x00040020, 0x00000018, 0x00000002, 0x00000006, 0x0004002B,
    0x00000011, 0x0000001C, 0x00000002, 0x00050036, 0x00000002, 0x00000004,
    0x00000000, 0x00000003, 0x000200F8, 0x00000005, 0x0004003D, 0x00000007,
    0x0000000C, 0x0000000B, 0x00050041, 0x00000013, 0x00000014, 0x00000010,
    0x00000012, 0x0004003D, 0x00000007, 0x00000015, 0x00000014, 0x00050085,
    0x00000007, 0x00000016, 0x0000000C, 0x00000015, 0x00050041, 0x00000018,
    0x00000019, 0x00000010, 0x00000017, 0x0004003D, 0x00000006, 0x0000001A,
    0x00000019, 0x0005008E, 0x00000007, 0x0000001B, 0x00000016, 0x0000001A,
    0x00060041, 0x00000013, 0x0000001D, 0x00000010, 0x0000001C, 0x0000001C,
    0x0004003D, 0x00000007, 0x0000001E, 0x0000001D, 0x00050081, 0x00000007,
    0x0000001F, 0x0000001B, 0x0000001E, 0x0003003E, 0x00000009, 0x0000001F,
    0x000100FD, 0x00010038,
};

/// 32-bit integers, glslc -O (`-fshader-stage=frag`), 663 words: the colour
/// made integers, offset and clamped, and its green made an unsigned
/// integer and held to 100; then of the push constants' integers a product
/// plus an arithmetic shift by a pushed amount, its abs; a logical shift
/// XORed, ORed and ANDed with the NOT of another; the most less the least
/// of two times five plus the least of one negated; signed and unsigned
/// comparisons each choosing an integer; and the most and least of two
/// unsigned. Each lands in a channel 0 to 255, as FacetBoth draws it
/// (since 1.33): an operation computed wrong moves a channel by 4 steps or
/// more. Since 1.165 Mesa's back end compiles them as ntq_emit_alu does
/// (nir_to_vir.c:1421-1806).
///
/// ```glsl
/// #version 450
/// layout(location = 0) in vec4 vcolor;
/// layout(location = 0) out vec4 ocolor;
/// layout(push_constant) uniform Push { ivec4 s; uvec4 u; } push;
/// void main() {
///     ivec4 c = clamp(ivec4(vcolor * 255.0) + push.s.x, ivec4(0), ivec4(100));
///     uint green = min(uint(vcolor.y * 255.0), 100u);
///     int r = abs(push.s.y * push.s.z + (push.s.w >> (push.u.z - 2u)));
///     uint g = (((push.u.x >> 25) ^ push.u.y) | (push.u.z << 3)) & ~push.u.w;
///     int b = (max(push.s.y, push.s.z) - min(push.s.y, push.s.z)) * 5 + min(-push.s.y, push.s.z);
///     int a = (push.s.y < push.s.z ? 40 : 0) + (push.u.x < push.u.y ? 32 : 0)
///           + (push.s.z >= push.s.y ? 20 : 0) + (push.u.x > push.u.y ? 12 : 0)
///           + (push.s.y == push.s.z ? 8 : 0) + (push.u.x != push.u.y ? 4 : 0);
///     uint most = (max(push.u.x, push.u.y) >> 27) + (min(push.u.x, push.u.y) >> 2);
///     ocolor = vec4(float(c.x + r), float(green) + float(g), float(c.z + b), float(c.w + a) + float(most)) / 255.0;
/// }
/// ```
///
/// ```sh
/// glslc -O -fshader-stage=frag integers.frag -o integers.spv   # 663 words
/// spirv-val --target-env vulkan1.0 integers.spv              # no output, and 0
/// ```
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 200
/// ; Schema: 0
///                OpCapability Shader
///           %1 = OpExtInstImport "GLSL.std.450"
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %4 "main" %13 %167
///                OpExecutionMode %4 OriginUpperLeft
///                OpDecorate %13 Location 0
///                OpDecorate %20 Block
///                OpMemberDecorate %20 0 Offset 0
///                OpMemberDecorate %20 1 Offset 16
///                OpDecorate %167 Location 0
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeInt 32 1
///           %7 = OpTypeVector %6 4
///          %10 = OpTypeFloat 32
///          %11 = OpTypeVector %10 4
///          %12 = OpTypePointer Input %11
///          %13 = OpVariable %12 Input
///          %15 = OpConstant %10 255
///          %18 = OpTypeInt 32 0
///          %19 = OpTypeVector %18 4
///          %20 = OpTypeStruct %7 %19
///          %21 = OpTypePointer PushConstant %20
///          %22 = OpVariable %21 PushConstant
///          %23 = OpConstant %6 0
///          %24 = OpConstant %18 0
///          %25 = OpTypePointer PushConstant %6
///          %30 = OpConstantComposite %7 %23 %23 %23 %23
///          %31 = OpConstant %6 100
///          %32 = OpConstantComposite %7 %31 %31 %31 %31
///          %36 = OpConstant %18 1
///          %37 = OpTypePointer Input %10
///          %42 = OpConstant %18 100
///          %48 = OpConstant %18 2
///          %52 = OpConstant %18 3
///          %55 = OpConstant %6 1
///          %56 = OpTypePointer PushConstant %18
///          %66 = OpConstant %6 25
///          %73 = OpConstant %6 3
///          %92 = OpConstant %6 5
///         %106 = OpTypeBool
///         %108 = OpConstant %6 40
///         %115 = OpConstant %6 32
///         %123 = OpConstant %6 20
///         %131 = OpConstant %6 12
///         %139 = OpConstant %6 8
///         %147 = OpConstant %6 4
///         %156 = OpConstant %6 27
///         %163 = OpConstant %6 2
///         %166 = OpTypePointer Output %11
///         %167 = OpVariable %166 Output
///         %198 = OpConstant %10 0.00392156886
///         %199 = OpConstantComposite %11 %198 %198 %198 %198
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///          %14 = OpLoad %11 %13
///          %16 = OpVectorTimesScalar %11 %14 %15
///          %17 = OpConvertFToS %7 %16
///          %26 = OpAccessChain %25 %22 %23 %24
///          %27 = OpLoad %6 %26
///          %28 = OpCompositeConstruct %7 %27 %27 %27 %27
///          %29 = OpIAdd %7 %17 %28
///          %33 = OpExtInst %7 %1 SClamp %29 %30 %32
///          %38 = OpAccessChain %37 %13 %36
///          %39 = OpLoad %10 %38
///          %40 = OpFMul %10 %39 %15
///          %41 = OpConvertFToU %18 %40
///          %43 = OpExtInst %18 %1 UMin %41 %42
///          %46 = OpAccessChain %25 %22 %23 %36
///          %47 = OpLoad %6 %46
///          %49 = OpAccessChain %25 %22 %23 %48
///          %50 = OpLoad %6 %49
///          %51 = OpIMul %6 %47 %50
///          %53 = OpAccessChain %25 %22 %23 %52
///          %54 = OpLoad %6 %53
///          %57 = OpAccessChain %56 %22 %55 %48
///          %58 = OpLoad %18 %57
///          %59 = OpISub %18 %58 %48
///          %60 = OpShiftRightArithmetic %6 %54 %59
///          %61 = OpIAdd %6 %51 %60
///          %62 = OpExtInst %6 %1 SAbs %61
///          %64 = OpAccessChain %56 %22 %55 %24
///          %65 = OpLoad %18 %64
///          %67 = OpShiftRightLogical %18 %65 %66
///          %68 = OpAccessChain %56 %22 %55 %36
///          %69 = OpLoad %18 %68
///          %70 = OpBitwiseXor %18 %67 %69
///          %74 = OpShiftLeftLogical %18 %58 %73
///          %75 = OpBitwiseOr %18 %70 %74
///          %76 = OpAccessChain %56 %22 %55 %52
///          %77 = OpLoad %18 %76
///          %78 = OpNot %18 %77
///          %79 = OpBitwiseAnd %18 %75 %78
///          %85 = OpExtInst %6 %1 SMax %47 %50
///          %90 = OpExtInst %6 %1 SMin %47 %50
///          %91 = OpISub %6 %85 %90
///          %93 = OpIMul %6 %91 %92
///          %96 = OpSNegate %6 %47
///          %99 = OpExtInst %6 %1 SMin %96 %50
///         %100 = OpIAdd %6 %93 %99
///         %107 = OpSLessThan %106 %47 %50
///         %109 = OpSelect %6 %107 %108 %23
///         %114 = OpULessThan %106 %65 %69
///         %116 = OpSelect %6 %114 %115 %23
///         %117 = OpIAdd %6 %109 %116
///         %122 = OpSGreaterThanEqual %106 %50 %47
///         %124 = OpSelect %6 %122 %123 %23
///         %125 = OpIAdd %6 %117 %124
///         %130 = OpUGreaterThan %106 %65 %69
///         %132 = OpSelect %6 %130 %131 %23
///         %133 = OpIAdd %6 %125 %132
///         %138 = OpIEqual %106 %47 %50
///         %140 = OpSelect %6 %138 %139 %23
///         %141 = OpIAdd %6 %133 %140
///         %146 = OpINotEqual %106 %65 %69
///         %148 = OpSelect %6 %146 %147 %23
///         %149 = OpIAdd %6 %141 %148
///         %155 = OpExtInst %18 %1 UMax %65 %69
///         %157 = OpShiftRightLogical %18 %155 %156
///         %162 = OpExtInst %18 %1 UMin %65 %69
///         %164 = OpShiftRightLogical %18 %162 %163
///         %165 = OpIAdd %18 %157 %164
///         %169 = OpCompositeExtract %6 %33 0
///         %171 = OpIAdd %6 %169 %62
///         %172 = OpConvertSToF %10 %171
///         %174 = OpConvertUToF %10 %43
///         %176 = OpConvertUToF %10 %79
///         %177 = OpFAdd %10 %174 %176
///         %179 = OpCompositeExtract %6 %33 2
///         %181 = OpIAdd %6 %179 %100
///         %182 = OpConvertSToF %10 %181
///         %184 = OpCompositeExtract %6 %33 3
///         %186 = OpIAdd %6 %184 %149
///         %187 = OpConvertSToF %10 %186
///         %189 = OpConvertUToF %10 %165
///         %190 = OpFAdd %10 %187 %189
///         %191 = OpCompositeConstruct %11 %172 %177 %182 %190
///         %193 = OpFMul %11 %191 %199
///                OpStore %167 %193
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_integers = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x000000C8, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x0000000D, 0x000000A7, 0x00030010,
    0x00000004, 0x00000007, 0x00040047, 0x0000000D, 0x0000001E, 0x00000000,
    0x00030047, 0x00000014, 0x00000002, 0x00050048, 0x00000014, 0x00000000,
    0x00000023, 0x00000000, 0x00050048, 0x00000014, 0x00000001, 0x00000023,
    0x00000010, 0x00040047, 0x000000A7, 0x0000001E, 0x00000000, 0x00020013,
    0x00000002, 0x00030021, 0x00000003, 0x00000002, 0x00040015, 0x00000006,
    0x00000020, 0x00000001, 0x00040017, 0x00000007, 0x00000006, 0x00000004,
    0x00030016, 0x0000000A, 0x00000020, 0x00040017, 0x0000000B, 0x0000000A,
    0x00000004, 0x00040020, 0x0000000C, 0x00000001, 0x0000000B, 0x0004003B,
    0x0000000C, 0x0000000D, 0x00000001, 0x0004002B, 0x0000000A, 0x0000000F,
    0x437F0000, 0x00040015, 0x00000012, 0x00000020, 0x00000000, 0x00040017,
    0x00000013, 0x00000012, 0x00000004, 0x0004001E, 0x00000014, 0x00000007,
    0x00000013, 0x00040020, 0x00000015, 0x00000009, 0x00000014, 0x0004003B,
    0x00000015, 0x00000016, 0x00000009, 0x0004002B, 0x00000006, 0x00000017,
    0x00000000, 0x0004002B, 0x00000012, 0x00000018, 0x00000000, 0x00040020,
    0x00000019, 0x00000009, 0x00000006, 0x0007002C, 0x00000007, 0x0000001E,
    0x00000017, 0x00000017, 0x00000017, 0x00000017, 0x0004002B, 0x00000006,
    0x0000001F, 0x00000064, 0x0007002C, 0x00000007, 0x00000020, 0x0000001F,
    0x0000001F, 0x0000001F, 0x0000001F, 0x0004002B, 0x00000012, 0x00000024,
    0x00000001, 0x00040020, 0x00000025, 0x00000001, 0x0000000A, 0x0004002B,
    0x00000012, 0x0000002A, 0x00000064, 0x0004002B, 0x00000012, 0x00000030,
    0x00000002, 0x0004002B, 0x00000012, 0x00000034, 0x00000003, 0x0004002B,
    0x00000006, 0x00000037, 0x00000001, 0x00040020, 0x00000038, 0x00000009,
    0x00000012, 0x0004002B, 0x00000006, 0x00000042, 0x00000019, 0x0004002B,
    0x00000006, 0x00000049, 0x00000003, 0x0004002B, 0x00000006, 0x0000005C,
    0x00000005, 0x00020014, 0x0000006A, 0x0004002B, 0x00000006, 0x0000006C,
    0x00000028, 0x0004002B, 0x00000006, 0x00000073, 0x00000020, 0x0004002B,
    0x00000006, 0x0000007B, 0x00000014, 0x0004002B, 0x00000006, 0x00000083,
    0x0000000C, 0x0004002B, 0x00000006, 0x0000008B, 0x00000008, 0x0004002B,
    0x00000006, 0x00000093, 0x00000004, 0x0004002B, 0x00000006, 0x0000009C,
    0x0000001B, 0x0004002B, 0x00000006, 0x000000A3, 0x00000002, 0x00040020,
    0x000000A6, 0x00000003, 0x0000000B, 0x0004003B, 0x000000A6, 0x000000A7,
    0x00000003, 0x0004002B, 0x0000000A, 0x000000C6, 0x3B808081, 0x0007002C,
    0x0000000B, 0x000000C7, 0x000000C6, 0x000000C6, 0x000000C6, 0x000000C6,
    0x00050036, 0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200F8,
    0x00000005, 0x0004003D, 0x0000000B, 0x0000000E, 0x0000000D, 0x0005008E,
    0x0000000B, 0x00000010, 0x0000000E, 0x0000000F, 0x0004006E, 0x00000007,
    0x00000011, 0x00000010, 0x00060041, 0x00000019, 0x0000001A, 0x00000016,
    0x00000017, 0x00000018, 0x0004003D, 0x00000006, 0x0000001B, 0x0000001A,
    0x00070050, 0x00000007, 0x0000001C, 0x0000001B, 0x0000001B, 0x0000001B,
    0x0000001B, 0x00050080, 0x00000007, 0x0000001D, 0x00000011, 0x0000001C,
    0x0008000C, 0x00000007, 0x00000021, 0x00000001, 0x0000002D, 0x0000001D,
    0x0000001E, 0x00000020, 0x00050041, 0x00000025, 0x00000026, 0x0000000D,
    0x00000024, 0x0004003D, 0x0000000A, 0x00000027, 0x00000026, 0x00050085,
    0x0000000A, 0x00000028, 0x00000027, 0x0000000F, 0x0004006D, 0x00000012,
    0x00000029, 0x00000028, 0x0007000C, 0x00000012, 0x0000002B, 0x00000001,
    0x00000026, 0x00000029, 0x0000002A, 0x00060041, 0x00000019, 0x0000002E,
    0x00000016, 0x00000017, 0x00000024, 0x0004003D, 0x00000006, 0x0000002F,
    0x0000002E, 0x00060041, 0x00000019, 0x00000031, 0x00000016, 0x00000017,
    0x00000030, 0x0004003D, 0x00000006, 0x00000032, 0x00000031, 0x00050084,
    0x00000006, 0x00000033, 0x0000002F, 0x00000032, 0x00060041, 0x00000019,
    0x00000035, 0x00000016, 0x00000017, 0x00000034, 0x0004003D, 0x00000006,
    0x00000036, 0x00000035, 0x00060041, 0x00000038, 0x00000039, 0x00000016,
    0x00000037, 0x00000030, 0x0004003D, 0x00000012, 0x0000003A, 0x00000039,
    0x00050082, 0x00000012, 0x0000003B, 0x0000003A, 0x00000030, 0x000500C3,
    0x00000006, 0x0000003C, 0x00000036, 0x0000003B, 0x00050080, 0x00000006,
    0x0000003D, 0x00000033, 0x0000003C, 0x0006000C, 0x00000006, 0x0000003E,
    0x00000001, 0x00000005, 0x0000003D, 0x00060041, 0x00000038, 0x00000040,
    0x00000016, 0x00000037, 0x00000018, 0x0004003D, 0x00000012, 0x00000041,
    0x00000040, 0x000500C2, 0x00000012, 0x00000043, 0x00000041, 0x00000042,
    0x00060041, 0x00000038, 0x00000044, 0x00000016, 0x00000037, 0x00000024,
    0x0004003D, 0x00000012, 0x00000045, 0x00000044, 0x000500C6, 0x00000012,
    0x00000046, 0x00000043, 0x00000045, 0x000500C4, 0x00000012, 0x0000004A,
    0x0000003A, 0x00000049, 0x000500C5, 0x00000012, 0x0000004B, 0x00000046,
    0x0000004A, 0x00060041, 0x00000038, 0x0000004C, 0x00000016, 0x00000037,
    0x00000034, 0x0004003D, 0x00000012, 0x0000004D, 0x0000004C, 0x000400C8,
    0x00000012, 0x0000004E, 0x0000004D, 0x000500C7, 0x00000012, 0x0000004F,
    0x0000004B, 0x0000004E, 0x0007000C, 0x00000006, 0x00000055, 0x00000001,
    0x0000002A, 0x0000002F, 0x00000032, 0x0007000C, 0x00000006, 0x0000005A,
    0x00000001, 0x00000027, 0x0000002F, 0x00000032, 0x00050082, 0x00000006,
    0x0000005B, 0x00000055, 0x0000005A, 0x00050084, 0x00000006, 0x0000005D,
    0x0000005B, 0x0000005C, 0x0004007E, 0x00000006, 0x00000060, 0x0000002F,
    0x0007000C, 0x00000006, 0x00000063, 0x00000001, 0x00000027, 0x00000060,
    0x00000032, 0x00050080, 0x00000006, 0x00000064, 0x0000005D, 0x00000063,
    0x000500B1, 0x0000006A, 0x0000006B, 0x0000002F, 0x00000032, 0x000600A9,
    0x00000006, 0x0000006D, 0x0000006B, 0x0000006C, 0x00000017, 0x000500B0,
    0x0000006A, 0x00000072, 0x00000041, 0x00000045, 0x000600A9, 0x00000006,
    0x00000074, 0x00000072, 0x00000073, 0x00000017, 0x00050080, 0x00000006,
    0x00000075, 0x0000006D, 0x00000074, 0x000500AF, 0x0000006A, 0x0000007A,
    0x00000032, 0x0000002F, 0x000600A9, 0x00000006, 0x0000007C, 0x0000007A,
    0x0000007B, 0x00000017, 0x00050080, 0x00000006, 0x0000007D, 0x00000075,
    0x0000007C, 0x000500AC, 0x0000006A, 0x00000082, 0x00000041, 0x00000045,
    0x000600A9, 0x00000006, 0x00000084, 0x00000082, 0x00000083, 0x00000017,
    0x00050080, 0x00000006, 0x00000085, 0x0000007D, 0x00000084, 0x000500AA,
    0x0000006A, 0x0000008A, 0x0000002F, 0x00000032, 0x000600A9, 0x00000006,
    0x0000008C, 0x0000008A, 0x0000008B, 0x00000017, 0x00050080, 0x00000006,
    0x0000008D, 0x00000085, 0x0000008C, 0x000500AB, 0x0000006A, 0x00000092,
    0x00000041, 0x00000045, 0x000600A9, 0x00000006, 0x00000094, 0x00000092,
    0x00000093, 0x00000017, 0x00050080, 0x00000006, 0x00000095, 0x0000008D,
    0x00000094, 0x0007000C, 0x00000012, 0x0000009B, 0x00000001, 0x00000029,
    0x00000041, 0x00000045, 0x000500C2, 0x00000012, 0x0000009D, 0x0000009B,
    0x0000009C, 0x0007000C, 0x00000012, 0x000000A2, 0x00000001, 0x00000026,
    0x00000041, 0x00000045, 0x000500C2, 0x00000012, 0x000000A4, 0x000000A2,
    0x000000A3, 0x00050080, 0x00000012, 0x000000A5, 0x0000009D, 0x000000A4,
    0x00050051, 0x00000006, 0x000000A9, 0x00000021, 0x00000000, 0x00050080,
    0x00000006, 0x000000AB, 0x000000A9, 0x0000003E, 0x0004006F, 0x0000000A,
    0x000000AC, 0x000000AB, 0x00040070, 0x0000000A, 0x000000AE, 0x0000002B,
    0x00040070, 0x0000000A, 0x000000B0, 0x0000004F, 0x00050081, 0x0000000A,
    0x000000B1, 0x000000AE, 0x000000B0, 0x00050051, 0x00000006, 0x000000B3,
    0x00000021, 0x00000002, 0x00050080, 0x00000006, 0x000000B5, 0x000000B3,
    0x00000064, 0x0004006F, 0x0000000A, 0x000000B6, 0x000000B5, 0x00050051,
    0x00000006, 0x000000B8, 0x00000021, 0x00000003, 0x00050080, 0x00000006,
    0x000000BA, 0x000000B8, 0x00000095, 0x0004006F, 0x0000000A, 0x000000BB,
    0x000000BA, 0x00040070, 0x0000000A, 0x000000BD, 0x000000A5, 0x00050081,
    0x0000000A, 0x000000BE, 0x000000BB, 0x000000BD, 0x00070050, 0x0000000B,
    0x000000BF, 0x000000AC, 0x000000B1, 0x000000B6, 0x000000BE, 0x00050085,
    0x0000000B, 0x000000C1, 0x000000BF, 0x000000C7, 0x0003003E, 0x000000A7,
    0x000000C1, 0x000100FD, 0x00010038,
};

/// The integer comparisons, glslc -O (`-fshader-stage=frag`), 338 words:
/// greater, greater-or-equal and less-or-equal of signed and of unsigned
/// integers, equal and not equal, bools compared with == and !=, a float
/// made an unsigned integer and back, and a float's bits read as an
/// integer and back. Since 1.165 Mesa's back end compiles them as
/// ntq_emit_comparison does (nir_to_vir.c:1173-1232), the four NIR has no
/// comparison of with their operands swapped (vtn_alu.c:388-396).
///
/// ```glsl
/// #version 450
/// layout(location = 0) in vec4 vcolor;
/// layout(location = 0) out vec4 ocolor;
/// layout(push_constant) uniform Push {
///     ivec2 s;
///     uvec2 u;
/// } push;
/// void main() {
///     uint level = uint(vcolor.x * 8.0);
///     int bits = floatBitsToInt(vcolor.y);
///     bool a = push.s.x > push.s.y;
///     bool b = push.s.x >= push.s.y;
///     bool c = push.s.x <= push.s.y;
///     bool d = push.u.x > push.u.y;
///     bool e = push.u.x >= push.u.y;
///     bool f = push.u.x <= push.u.y;
///     bool g = push.s.x == push.s.y;
///     bool h = level != push.u.x;
///     bool same = (a == b) && (c != d) && (e == f) && (g != h);
///     float lifted = intBitsToFloat(bits + 0);
///     ocolor = vec4(float(level) / 8.0, lifted, same ? 1.0 : 0.0, vcolor.w);
/// }
/// ```
///
/// ```sh
/// glslc -O -fshader-stage=frag compares.frag -o compares.spv   # 338 words
/// spirv-val --target-env vulkan1.0 compares.spv              # no output, and 0
/// ```
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 121
/// ; Schema: 0
///                OpCapability Shader
///           %1 = OpExtInstImport "GLSL.std.450"
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %4 "main" %12 %107
///                OpExecutionMode %4 OriginUpperLeft
///                OpDecorate %12 Location 0
///                OpDecorate %32 Block
///                OpMemberDecorate %32 0 Offset 0
///                OpMemberDecorate %32 1 Offset 8
///                OpDecorate %107 Location 0
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeInt 32 0
///           %9 = OpTypeFloat 32
///          %10 = OpTypeVector %9 4
///          %11 = OpTypePointer Input %10
///          %12 = OpVariable %11 Input
///          %13 = OpConstant %6 0
///          %14 = OpTypePointer Input %9
///          %17 = OpConstant %9 8
///          %20 = OpTypeInt 32 1
///          %23 = OpConstant %6 1
///          %27 = OpTypeBool
///          %30 = OpTypeVector %20 2
///          %31 = OpTypeVector %6 2
///          %32 = OpTypeStruct %30 %31
///          %33 = OpTypePointer PushConstant %32
///          %34 = OpVariable %33 PushConstant
///          %35 = OpConstant %20 0
///          %36 = OpTypePointer PushConstant %20
///          %55 = OpConstant %20 1
///          %56 = OpTypePointer PushConstant %6
///         %106 = OpTypePointer Output %10
///         %107 = OpVariable %106 Output
///         %113 = OpConstant %9 1
///         %114 = OpConstant %9 0
///         %116 = OpConstant %6 3
///         %120 = OpConstant %9 0.125
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///          %15 = OpAccessChain %14 %12 %13
///          %16 = OpLoad %9 %15
///          %18 = OpFMul %9 %16 %17
///          %19 = OpConvertFToU %6 %18
///          %24 = OpAccessChain %14 %12 %23
///          %25 = OpLoad %9 %24
///          %37 = OpAccessChain %36 %34 %35 %13
///          %38 = OpLoad %20 %37
///          %39 = OpAccessChain %36 %34 %35 %23
///          %40 = OpLoad %20 %39
///          %41 = OpSGreaterThan %27 %38 %40
///          %47 = OpSGreaterThanEqual %27 %38 %40
///          %53 = OpSLessThanEqual %27 %38 %40
///          %57 = OpAccessChain %56 %34 %55 %13
///          %58 = OpLoad %6 %57
///          %59 = OpAccessChain %56 %34 %55 %23
///          %60 = OpLoad %6 %59
///          %61 = OpUGreaterThan %27 %58 %60
///          %67 = OpUGreaterThanEqual %27 %58 %60
///          %73 = OpULessThanEqual %27 %58 %60
///          %79 = OpIEqual %27 %38 %40
///          %84 = OpINotEqual %27 %19 %58
///          %88 = OpLogicalEqual %27 %41 %47
///          %91 = OpLogicalNotEqual %27 %53 %61
///          %92 = OpLogicalAnd %27 %88 %91
///          %95 = OpLogicalEqual %27 %67 %73
///          %96 = OpLogicalAnd %27 %92 %95
///          %99 = OpLogicalNotEqual %27 %79 %84
///         %100 = OpLogicalAnd %27 %96 %99
///         %109 = OpConvertUToF %9 %19
///         %110 = OpFMul %9 %109 %120
///         %115 = OpSelect %9 %100 %113 %114
///         %117 = OpAccessChain %14 %12 %116
///         %118 = OpLoad %9 %117
///         %119 = OpCompositeConstruct %10 %110 %25 %115 %118
///                OpStore %107 %119
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_integer_compares = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x00000079, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x0000000C, 0x0000006B, 0x00030010,
    0x00000004, 0x00000007, 0x00040047, 0x0000000C, 0x0000001E, 0x00000000,
    0x00030047, 0x00000020, 0x00000002, 0x00050048, 0x00000020, 0x00000000,
    0x00000023, 0x00000000, 0x00050048, 0x00000020, 0x00000001, 0x00000023,
    0x00000008, 0x00040047, 0x0000006B, 0x0000001E, 0x00000000, 0x00020013,
    0x00000002, 0x00030021, 0x00000003, 0x00000002, 0x00040015, 0x00000006,
    0x00000020, 0x00000000, 0x00030016, 0x00000009, 0x00000020, 0x00040017,
    0x0000000A, 0x00000009, 0x00000004, 0x00040020, 0x0000000B, 0x00000001,
    0x0000000A, 0x0004003B, 0x0000000B, 0x0000000C, 0x00000001, 0x0004002B,
    0x00000006, 0x0000000D, 0x00000000, 0x00040020, 0x0000000E, 0x00000001,
    0x00000009, 0x0004002B, 0x00000009, 0x00000011, 0x41000000, 0x00040015,
    0x00000014, 0x00000020, 0x00000001, 0x0004002B, 0x00000006, 0x00000017,
    0x00000001, 0x00020014, 0x0000001B, 0x00040017, 0x0000001E, 0x00000014,
    0x00000002, 0x00040017, 0x0000001F, 0x00000006, 0x00000002, 0x0004001E,
    0x00000020, 0x0000001E, 0x0000001F, 0x00040020, 0x00000021, 0x00000009,
    0x00000020, 0x0004003B, 0x00000021, 0x00000022, 0x00000009, 0x0004002B,
    0x00000014, 0x00000023, 0x00000000, 0x00040020, 0x00000024, 0x00000009,
    0x00000014, 0x0004002B, 0x00000014, 0x00000037, 0x00000001, 0x00040020,
    0x00000038, 0x00000009, 0x00000006, 0x00040020, 0x0000006A, 0x00000003,
    0x0000000A, 0x0004003B, 0x0000006A, 0x0000006B, 0x00000003, 0x0004002B,
    0x00000009, 0x00000071, 0x3F800000, 0x0004002B, 0x00000009, 0x00000072,
    0x00000000, 0x0004002B, 0x00000006, 0x00000074, 0x00000003, 0x0004002B,
    0x00000009, 0x00000078, 0x3E000000, 0x00050036, 0x00000002, 0x00000004,
    0x00000000, 0x00000003, 0x000200F8, 0x00000005, 0x00050041, 0x0000000E,
    0x0000000F, 0x0000000C, 0x0000000D, 0x0004003D, 0x00000009, 0x00000010,
    0x0000000F, 0x00050085, 0x00000009, 0x00000012, 0x00000010, 0x00000011,
    0x0004006D, 0x00000006, 0x00000013, 0x00000012, 0x00050041, 0x0000000E,
    0x00000018, 0x0000000C, 0x00000017, 0x0004003D, 0x00000009, 0x00000019,
    0x00000018, 0x00060041, 0x00000024, 0x00000025, 0x00000022, 0x00000023,
    0x0000000D, 0x0004003D, 0x00000014, 0x00000026, 0x00000025, 0x00060041,
    0x00000024, 0x00000027, 0x00000022, 0x00000023, 0x00000017, 0x0004003D,
    0x00000014, 0x00000028, 0x00000027, 0x000500AD, 0x0000001B, 0x00000029,
    0x00000026, 0x00000028, 0x000500AF, 0x0000001B, 0x0000002F, 0x00000026,
    0x00000028, 0x000500B3, 0x0000001B, 0x00000035, 0x00000026, 0x00000028,
    0x00060041, 0x00000038, 0x00000039, 0x00000022, 0x00000037, 0x0000000D,
    0x0004003D, 0x00000006, 0x0000003A, 0x00000039, 0x00060041, 0x00000038,
    0x0000003B, 0x00000022, 0x00000037, 0x00000017, 0x0004003D, 0x00000006,
    0x0000003C, 0x0000003B, 0x000500AC, 0x0000001B, 0x0000003D, 0x0000003A,
    0x0000003C, 0x000500AE, 0x0000001B, 0x00000043, 0x0000003A, 0x0000003C,
    0x000500B2, 0x0000001B, 0x00000049, 0x0000003A, 0x0000003C, 0x000500AA,
    0x0000001B, 0x0000004F, 0x00000026, 0x00000028, 0x000500AB, 0x0000001B,
    0x00000054, 0x00000013, 0x0000003A, 0x000500A4, 0x0000001B, 0x00000058,
    0x00000029, 0x0000002F, 0x000500A5, 0x0000001B, 0x0000005B, 0x00000035,
    0x0000003D, 0x000500A7, 0x0000001B, 0x0000005C, 0x00000058, 0x0000005B,
    0x000500A4, 0x0000001B, 0x0000005F, 0x00000043, 0x00000049, 0x000500A7,
    0x0000001B, 0x00000060, 0x0000005C, 0x0000005F, 0x000500A5, 0x0000001B,
    0x00000063, 0x0000004F, 0x00000054, 0x000500A7, 0x0000001B, 0x00000064,
    0x00000060, 0x00000063, 0x00040070, 0x00000009, 0x0000006D, 0x00000013,
    0x00050085, 0x00000009, 0x0000006E, 0x0000006D, 0x00000078, 0x000600A9,
    0x00000009, 0x00000073, 0x00000064, 0x00000071, 0x00000072, 0x00050041,
    0x0000000E, 0x00000075, 0x0000000C, 0x00000074, 0x0004003D, 0x00000009,
    0x00000076, 0x00000075, 0x00070050, 0x0000000A, 0x00000077, 0x0000006E,
    0x00000019, 0x00000073, 0x00000076, 0x0003003E, 0x0000006B, 0x00000077,
    0x000100FD, 0x00010038,
};

/// The not of an integer comparison, glslc -O0 (`-fshader-stage=frag`), 428
/// words: three comparisons of the push constants' integers, signed less,
/// unsigned less and equal, each kept in a bool of the function's own and
/// read back through OpLogicalNot into an OpLogicalAnd with a float
/// comparison, which chooses a float. glslc -O would fold each not into
/// the opposite comparison itself; at -O0 it is Mesa's nir_opt_algebraic
/// that does (nir_opt_algebraic.py:749-754), which facet.library ports
/// since 1.165.
///
/// ```glsl
/// #version 450
/// layout(location = 0) in vec4 vcolor;
/// layout(location = 0) out vec4 ocolor;
/// layout(push_constant) uniform Push { ivec2 s; uvec2 u; } push;
/// void main() {
///     bool lt = push.s.x < push.s.y;
///     bool ult = push.u.x < push.u.y;
///     bool eq = push.s.x == push.s.y;
///     bool far = vcolor.x > 0.5;
///     ocolor = vcolor * vec4((!lt && far) ? 1.0 : 0.5, (!ult && far) ? 1.0 : 0.25, (!eq && far) ? 1.0 : 0.75, 1.0);
/// }
/// ```
///
/// ```sh
/// glslc -O0 -fshader-stage=frag nots.frag -o nots_O0.spv   # 428 words
/// spirv-val --target-env vulkan1.0 nots_O0.spv             # no output, and 0
/// ```
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 72
/// ; Schema: 0
///                OpCapability Shader
///           %1 = OpExtInstImport "GLSL.std.450"
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %4 "main" %43 %50
///                OpExecutionMode %4 OriginUpperLeft
///                OpSource GLSL 450
///                OpSourceExtension "GL_GOOGLE_cpp_style_line_directive"
///                OpSourceExtension "GL_GOOGLE_include_directive"
///                OpName %4 "main"
///                OpName %8 "lt"
///                OpName %13 "Push"
///                OpMemberName %13 0 "s"
///                OpMemberName %13 1 "u"
///                OpName %15 "push"
///                OpName %25 "ult"
///                OpName %33 "eq"
///                OpName %39 "far"
///                OpName %43 "vcolor"
///                OpName %50 "ocolor"
///                OpDecorate %13 Block
///                OpMemberDecorate %13 0 Offset 0
///                OpMemberDecorate %13 1 Offset 8
///                OpDecorate %43 Location 0
///                OpDecorate %50 Location 0
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeBool
///           %7 = OpTypePointer Function %6
///           %9 = OpTypeInt 32 1
///          %10 = OpTypeVector %9 2
///          %11 = OpTypeInt 32 0
///          %12 = OpTypeVector %11 2
///          %13 = OpTypeStruct %10 %12
///          %14 = OpTypePointer PushConstant %13
///          %15 = OpVariable %14 PushConstant
///          %16 = OpConstant %9 0
///          %17 = OpConstant %11 0
///          %18 = OpTypePointer PushConstant %9
///          %21 = OpConstant %11 1
///          %26 = OpConstant %9 1
///          %27 = OpTypePointer PushConstant %11
///          %40 = OpTypeFloat 32
///          %41 = OpTypeVector %40 4
///          %42 = OpTypePointer Input %41
///          %43 = OpVariable %42 Input
///          %44 = OpTypePointer Input %40
///          %47 = OpConstant %40 0.5
///          %49 = OpTypePointer Output %41
///          %50 = OpVariable %49 Output
///          %56 = OpConstant %40 1
///          %62 = OpConstant %40 0.25
///          %68 = OpConstant %40 0.75
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///           %8 = OpVariable %7 Function
///          %25 = OpVariable %7 Function
///          %33 = OpVariable %7 Function
///          %39 = OpVariable %7 Function
///          %19 = OpAccessChain %18 %15 %16 %17
///          %20 = OpLoad %9 %19
///          %22 = OpAccessChain %18 %15 %16 %21
///          %23 = OpLoad %9 %22
///          %24 = OpSLessThan %6 %20 %23
///                OpStore %8 %24
///          %28 = OpAccessChain %27 %15 %26 %17
///          %29 = OpLoad %11 %28
///          %30 = OpAccessChain %27 %15 %26 %21
///          %31 = OpLoad %11 %30
///          %32 = OpULessThan %6 %29 %31
///                OpStore %25 %32
///          %34 = OpAccessChain %18 %15 %16 %17
///          %35 = OpLoad %9 %34
///          %36 = OpAccessChain %18 %15 %16 %21
///          %37 = OpLoad %9 %36
///          %38 = OpIEqual %6 %35 %37
///                OpStore %33 %38
///          %45 = OpAccessChain %44 %43 %17
///          %46 = OpLoad %40 %45
///          %48 = OpFOrdGreaterThan %6 %46 %47
///                OpStore %39 %48
///          %51 = OpLoad %41 %43
///          %52 = OpLoad %6 %8
///          %53 = OpLogicalNot %6 %52
///          %54 = OpLoad %6 %39
///          %55 = OpLogicalAnd %6 %53 %54
///          %57 = OpSelect %40 %55 %56 %47
///          %58 = OpLoad %6 %25
///          %59 = OpLogicalNot %6 %58
///          %60 = OpLoad %6 %39
///          %61 = OpLogicalAnd %6 %59 %60
///          %63 = OpSelect %40 %61 %56 %62
///          %64 = OpLoad %6 %33
///          %65 = OpLogicalNot %6 %64
///          %66 = OpLoad %6 %39
///          %67 = OpLogicalAnd %6 %65 %66
///          %69 = OpSelect %40 %67 %56 %68
///          %70 = OpCompositeConstruct %41 %57 %63 %69 %56
///          %71 = OpFMul %41 %51 %70
///                OpStore %50 %71
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_integer_nots_O0 = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x00000048, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x0000002B, 0x00000032, 0x00030010,
    0x00000004, 0x00000007, 0x00030003, 0x00000002, 0x000001C2, 0x000A0004,
    0x475F4C47, 0x4C474F4F, 0x70635F45, 0x74735F70, 0x5F656C79, 0x656E696C,
    0x7269645F, 0x69746365, 0x00006576, 0x00080004, 0x475F4C47, 0x4C474F4F,
    0x6E695F45, 0x64756C63, 0x69645F65, 0x74636572, 0x00657669, 0x00040005,
    0x00000004, 0x6E69616D, 0x00000000, 0x00030005, 0x00000008, 0x0000746C,
    0x00040005, 0x0000000D, 0x68737550, 0x00000000, 0x00040006, 0x0000000D,
    0x00000000, 0x00000073, 0x00040006, 0x0000000D, 0x00000001, 0x00000075,
    0x00040005, 0x0000000F, 0x68737570, 0x00000000, 0x00030005, 0x00000019,
    0x00746C75, 0x00030005, 0x00000021, 0x00007165, 0x00030005, 0x00000027,
    0x00726166, 0x00040005, 0x0000002B, 0x6C6F6376, 0x0000726F, 0x00040005,
    0x00000032, 0x6C6F636F, 0x0000726F, 0x00030047, 0x0000000D, 0x00000002,
    0x00050048, 0x0000000D, 0x00000000, 0x00000023, 0x00000000, 0x00050048,
    0x0000000D, 0x00000001, 0x00000023, 0x00000008, 0x00040047, 0x0000002B,
    0x0000001E, 0x00000000, 0x00040047, 0x00000032, 0x0000001E, 0x00000000,
    0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002, 0x00020014,
    0x00000006, 0x00040020, 0x00000007, 0x00000007, 0x00000006, 0x00040015,
    0x00000009, 0x00000020, 0x00000001, 0x00040017, 0x0000000A, 0x00000009,
    0x00000002, 0x00040015, 0x0000000B, 0x00000020, 0x00000000, 0x00040017,
    0x0000000C, 0x0000000B, 0x00000002, 0x0004001E, 0x0000000D, 0x0000000A,
    0x0000000C, 0x00040020, 0x0000000E, 0x00000009, 0x0000000D, 0x0004003B,
    0x0000000E, 0x0000000F, 0x00000009, 0x0004002B, 0x00000009, 0x00000010,
    0x00000000, 0x0004002B, 0x0000000B, 0x00000011, 0x00000000, 0x00040020,
    0x00000012, 0x00000009, 0x00000009, 0x0004002B, 0x0000000B, 0x00000015,
    0x00000001, 0x0004002B, 0x00000009, 0x0000001A, 0x00000001, 0x00040020,
    0x0000001B, 0x00000009, 0x0000000B, 0x00030016, 0x00000028, 0x00000020,
    0x00040017, 0x00000029, 0x00000028, 0x00000004, 0x00040020, 0x0000002A,
    0x00000001, 0x00000029, 0x0004003B, 0x0000002A, 0x0000002B, 0x00000001,
    0x00040020, 0x0000002C, 0x00000001, 0x00000028, 0x0004002B, 0x00000028,
    0x0000002F, 0x3F000000, 0x00040020, 0x00000031, 0x00000003, 0x00000029,
    0x0004003B, 0x00000031, 0x00000032, 0x00000003, 0x0004002B, 0x00000028,
    0x00000038, 0x3F800000, 0x0004002B, 0x00000028, 0x0000003E, 0x3E800000,
    0x0004002B, 0x00000028, 0x00000044, 0x3F400000, 0x00050036, 0x00000002,
    0x00000004, 0x00000000, 0x00000003, 0x000200F8, 0x00000005, 0x0004003B,
    0x00000007, 0x00000008, 0x00000007, 0x0004003B, 0x00000007, 0x00000019,
    0x00000007, 0x0004003B, 0x00000007, 0x00000021, 0x00000007, 0x0004003B,
    0x00000007, 0x00000027, 0x00000007, 0x00060041, 0x00000012, 0x00000013,
    0x0000000F, 0x00000010, 0x00000011, 0x0004003D, 0x00000009, 0x00000014,
    0x00000013, 0x00060041, 0x00000012, 0x00000016, 0x0000000F, 0x00000010,
    0x00000015, 0x0004003D, 0x00000009, 0x00000017, 0x00000016, 0x000500B1,
    0x00000006, 0x00000018, 0x00000014, 0x00000017, 0x0003003E, 0x00000008,
    0x00000018, 0x00060041, 0x0000001B, 0x0000001C, 0x0000000F, 0x0000001A,
    0x00000011, 0x0004003D, 0x0000000B, 0x0000001D, 0x0000001C, 0x00060041,
    0x0000001B, 0x0000001E, 0x0000000F, 0x0000001A, 0x00000015, 0x0004003D,
    0x0000000B, 0x0000001F, 0x0000001E, 0x000500B0, 0x00000006, 0x00000020,
    0x0000001D, 0x0000001F, 0x0003003E, 0x00000019, 0x00000020, 0x00060041,
    0x00000012, 0x00000022, 0x0000000F, 0x00000010, 0x00000011, 0x0004003D,
    0x00000009, 0x00000023, 0x00000022, 0x00060041, 0x00000012, 0x00000024,
    0x0000000F, 0x00000010, 0x00000015, 0x0004003D, 0x00000009, 0x00000025,
    0x00000024, 0x000500AA, 0x00000006, 0x00000026, 0x00000023, 0x00000025,
    0x0003003E, 0x00000021, 0x00000026, 0x00050041, 0x0000002C, 0x0000002D,
    0x0000002B, 0x00000011, 0x0004003D, 0x00000028, 0x0000002E, 0x0000002D,
    0x000500BA, 0x00000006, 0x00000030, 0x0000002E, 0x0000002F, 0x0003003E,
    0x00000027, 0x00000030, 0x0004003D, 0x00000029, 0x00000033, 0x0000002B,
    0x0004003D, 0x00000006, 0x00000034, 0x00000008, 0x000400A8, 0x00000006,
    0x00000035, 0x00000034, 0x0004003D, 0x00000006, 0x00000036, 0x00000027,
    0x000500A7, 0x00000006, 0x00000037, 0x00000035, 0x00000036, 0x000600A9,
    0x00000028, 0x00000039, 0x00000037, 0x00000038, 0x0000002F, 0x0004003D,
    0x00000006, 0x0000003A, 0x00000019, 0x000400A8, 0x00000006, 0x0000003B,
    0x0000003A, 0x0004003D, 0x00000006, 0x0000003C, 0x00000027, 0x000500A7,
    0x00000006, 0x0000003D, 0x0000003B, 0x0000003C, 0x000600A9, 0x00000028,
    0x0000003F, 0x0000003D, 0x00000038, 0x0000003E, 0x0004003D, 0x00000006,
    0x00000040, 0x00000021, 0x000400A8, 0x00000006, 0x00000041, 0x00000040,
    0x0004003D, 0x00000006, 0x00000042, 0x00000027, 0x000500A7, 0x00000006,
    0x00000043, 0x00000041, 0x00000042, 0x000600A9, 0x00000028, 0x00000045,
    0x00000043, 0x00000038, 0x00000044, 0x00070050, 0x00000029, 0x00000046,
    0x00000039, 0x0000003F, 0x00000045, 0x00000038, 0x00050085, 0x00000029,
    0x00000047, 0x00000033, 0x00000046, 0x0003003E, 0x00000032, 0x00000047,
    0x000100FD, 0x00010038,
};

/// Block reads at offsets the program computes, glslc -O (`-fshader-
/// stage=frag`), 483 words: of a uniform buffer an element of a vec4 array,
/// of a float array, the sum of a push constant and one as an index, and a
/// mat2 of an array of them; of a storage buffer a member of an element of
/// a runtime array of structs, 48 bytes apart, the same sum as an index, a
/// float of a float array and a float of a vec4. Every index is a push
/// constant's, the same in every lane. Since 1.166 Mesa's back end reads
/// them through unifa at the offset computed (ntq_emit_load_unifa,
/// nir_to_vir.c:3441-3444).
///
/// ```glsl
/// #version 450
/// layout(location = 0) in vec4 vcolor;
/// layout(location = 0) out vec4 ocolor;
/// struct Triple { vec4 a; vec4 b; vec4 c; };
/// layout(push_constant) uniform Push { int which; int other; } push;
/// layout(set = 0, binding = 0) uniform Block { vec4 tints[4]; float weights[4]; mat2 turns[2]; } block;
/// layout(set = 0, binding = 1) readonly buffer Storage { vec4 base; float scale[3]; Triple triples[]; } storage;
/// void main() {
///     vec4 tint = block.tints[push.which];
///     float weight = block.weights[push.other + 1];
///     vec2 turned = block.turns[push.which] * vcolor.xy;
///     vec4 middle = storage.triples[push.which].b;
///     vec4 last = storage.triples[push.other + 1].c;
///     float k = storage.scale[push.other] + storage.base[push.which];
///     ocolor = vcolor * tint * weight + middle * k + last + vec4(turned, 0.0, 0.0);
/// }
/// ```
///
/// ```sh
/// glslc -O -fshader-stage=frag indexed.frag -o indexed.spv   # 483 words
/// spirv-val --target-env vulkan1.0 indexed.spv              # no output, and 0
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
///                OpEntryPoint Fragment %4 "main" %50 %83
///                OpExecutionMode %4 OriginUpperLeft
///                OpDecorate %12 ArrayStride 16
///                OpDecorate %13 ArrayStride 16
///                OpDecorate %17 ArrayStride 32
///                OpDecorate %18 Block
///                OpMemberDecorate %18 0 Offset 0
///                OpMemberDecorate %18 1 Offset 64
///                OpMemberDecorate %18 2 ColMajor
///                OpMemberDecorate %18 2 MatrixStride 16
///                OpMemberDecorate %18 2 Offset 128
///                OpDecorate %20 Binding 0
///                OpDecorate %20 DescriptorSet 0
///                OpDecorate %23 Block
///                OpMemberDecorate %23 0 Offset 0
///                OpMemberDecorate %23 1 Offset 4
///                OpDecorate %50 Location 0
///                OpDecorate %56 ArrayStride 4
///                OpMemberDecorate %57 0 Offset 0
///                OpMemberDecorate %57 1 Offset 16
///                OpMemberDecorate %57 2 Offset 32
///                OpDecorate %58 ArrayStride 48
///                OpDecorate %59 BufferBlock
///                OpMemberDecorate %59 0 NonWritable
///                OpMemberDecorate %59 0 Offset 0
///                OpMemberDecorate %59 1 NonWritable
///                OpMemberDecorate %59 1 Offset 16
///                OpMemberDecorate %59 2 NonWritable
///                OpMemberDecorate %59 2 Offset 32
///                OpDecorate %61 NonWritable
///                OpDecorate %61 Binding 1
///                OpDecorate %61 DescriptorSet 0
///                OpDecorate %83 Location 0
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeFloat 32
///           %7 = OpTypeVector %6 4
///          %10 = OpTypeInt 32 0
///          %11 = OpConstant %10 4
///          %12 = OpTypeArray %7 %11
///          %13 = OpTypeArray %6 %11
///          %14 = OpTypeVector %6 2
///          %15 = OpTypeMatrix %14 2
///          %16 = OpConstant %10 2
///          %17 = OpTypeArray %15 %16
///          %18 = OpTypeStruct %12 %13 %17
///          %19 = OpTypePointer Uniform %18
///          %20 = OpVariable %19 Uniform
///          %21 = OpTypeInt 32 1
///          %22 = OpConstant %21 0
///          %23 = OpTypeStruct %21 %21
///          %24 = OpTypePointer PushConstant %23
///          %25 = OpVariable %24 PushConstant
///          %26 = OpTypePointer PushConstant %21
///          %29 = OpTypePointer Uniform %7
///          %34 = OpConstant %21 1
///          %38 = OpTypePointer Uniform %6
///          %43 = OpConstant %21 2
///          %46 = OpTypePointer Uniform %15
///          %49 = OpTypePointer Input %7
///          %50 = OpVariable %49 Input
///          %55 = OpConstant %10 3
///          %56 = OpTypeArray %6 %55
///          %57 = OpTypeStruct %7 %7 %7
///          %58 = OpTypeRuntimeArray %57
///          %59 = OpTypeStruct %7 %56 %58
///          %60 = OpTypePointer Uniform %59
///          %61 = OpVariable %60 Uniform
///          %82 = OpTypePointer Output %7
///          %83 = OpVariable %82 Output
///          %96 = OpConstant %6 0
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///          %27 = OpAccessChain %26 %25 %22
///          %28 = OpLoad %21 %27
///          %30 = OpAccessChain %29 %20 %22 %28
///          %31 = OpLoad %7 %30
///          %35 = OpAccessChain %26 %25 %34
///          %36 = OpLoad %21 %35
///          %37 = OpIAdd %21 %36 %34
///          %39 = OpAccessChain %38 %20 %34 %37
///          %40 = OpLoad %6 %39
///          %47 = OpAccessChain %46 %20 %43 %28
///          %48 = OpLoad %15 %47
///          %51 = OpLoad %7 %50
///          %52 = OpVectorShuffle %14 %51 %51 0 1
///          %53 = OpMatrixTimesVector %14 %48 %52
///          %64 = OpAccessChain %29 %61 %43 %28 %34
///          %65 = OpLoad %7 %64
///          %70 = OpAccessChain %29 %61 %43 %37 %43
///          %71 = OpLoad %7 %70
///          %75 = OpAccessChain %38 %61 %34 %36
///          %76 = OpLoad %6 %75
///          %79 = OpAccessChain %38 %61 %22 %28
///          %80 = OpLoad %6 %79
///          %81 = OpFAdd %6 %76 %80
///          %86 = OpFMul %7 %51 %31
///          %88 = OpVectorTimesScalar %7 %86 %40
///          %91 = OpVectorTimesScalar %7 %65 %81
///          %92 = OpFAdd %7 %88 %91
///          %94 = OpFAdd %7 %92 %71
///          %97 = OpCompositeExtract %6 %53 0
///          %98 = OpCompositeExtract %6 %53 1
///          %99 = OpCompositeConstruct %7 %97 %98 %96 %96
///         %100 = OpFAdd %7 %94 %99
///                OpStore %83 %100
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_indexed = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x00000065, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x00000032, 0x00000053, 0x00030010,
    0x00000004, 0x00000007, 0x00040047, 0x0000000C, 0x00000006, 0x00000010,
    0x00040047, 0x0000000D, 0x00000006, 0x00000010, 0x00040047, 0x00000011,
    0x00000006, 0x00000020, 0x00030047, 0x00000012, 0x00000002, 0x00050048,
    0x00000012, 0x00000000, 0x00000023, 0x00000000, 0x00050048, 0x00000012,
    0x00000001, 0x00000023, 0x00000040, 0x00040048, 0x00000012, 0x00000002,
    0x00000005, 0x00050048, 0x00000012, 0x00000002, 0x00000007, 0x00000010,
    0x00050048, 0x00000012, 0x00000002, 0x00000023, 0x00000080, 0x00040047,
    0x00000014, 0x00000021, 0x00000000, 0x00040047, 0x00000014, 0x00000022,
    0x00000000, 0x00030047, 0x00000017, 0x00000002, 0x00050048, 0x00000017,
    0x00000000, 0x00000023, 0x00000000, 0x00050048, 0x00000017, 0x00000001,
    0x00000023, 0x00000004, 0x00040047, 0x00000032, 0x0000001E, 0x00000000,
    0x00040047, 0x00000038, 0x00000006, 0x00000004, 0x00050048, 0x00000039,
    0x00000000, 0x00000023, 0x00000000, 0x00050048, 0x00000039, 0x00000001,
    0x00000023, 0x00000010, 0x00050048, 0x00000039, 0x00000002, 0x00000023,
    0x00000020, 0x00040047, 0x0000003A, 0x00000006, 0x00000030, 0x00030047,
    0x0000003B, 0x00000003, 0x00040048, 0x0000003B, 0x00000000, 0x00000018,
    0x00050048, 0x0000003B, 0x00000000, 0x00000023, 0x00000000, 0x00040048,
    0x0000003B, 0x00000001, 0x00000018, 0x00050048, 0x0000003B, 0x00000001,
    0x00000023, 0x00000010, 0x00040048, 0x0000003B, 0x00000002, 0x00000018,
    0x00050048, 0x0000003B, 0x00000002, 0x00000023, 0x00000020, 0x00030047,
    0x0000003D, 0x00000018, 0x00040047, 0x0000003D, 0x00000021, 0x00000001,
    0x00040047, 0x0000003D, 0x00000022, 0x00000000, 0x00040047, 0x00000053,
    0x0000001E, 0x00000000, 0x00020013, 0x00000002, 0x00030021, 0x00000003,
    0x00000002, 0x00030016, 0x00000006, 0x00000020, 0x00040017, 0x00000007,
    0x00000006, 0x00000004, 0x00040015, 0x0000000A, 0x00000020, 0x00000000,
    0x0004002B, 0x0000000A, 0x0000000B, 0x00000004, 0x0004001C, 0x0000000C,
    0x00000007, 0x0000000B, 0x0004001C, 0x0000000D, 0x00000006, 0x0000000B,
    0x00040017, 0x0000000E, 0x00000006, 0x00000002, 0x00040018, 0x0000000F,
    0x0000000E, 0x00000002, 0x0004002B, 0x0000000A, 0x00000010, 0x00000002,
    0x0004001C, 0x00000011, 0x0000000F, 0x00000010, 0x0005001E, 0x00000012,
    0x0000000C, 0x0000000D, 0x00000011, 0x00040020, 0x00000013, 0x00000002,
    0x00000012, 0x0004003B, 0x00000013, 0x00000014, 0x00000002, 0x00040015,
    0x00000015, 0x00000020, 0x00000001, 0x0004002B, 0x00000015, 0x00000016,
    0x00000000, 0x0004001E, 0x00000017, 0x00000015, 0x00000015, 0x00040020,
    0x00000018, 0x00000009, 0x00000017, 0x0004003B, 0x00000018, 0x00000019,
    0x00000009, 0x00040020, 0x0000001A, 0x00000009, 0x00000015, 0x00040020,
    0x0000001D, 0x00000002, 0x00000007, 0x0004002B, 0x00000015, 0x00000022,
    0x00000001, 0x00040020, 0x00000026, 0x00000002, 0x00000006, 0x0004002B,
    0x00000015, 0x0000002B, 0x00000002, 0x00040020, 0x0000002E, 0x00000002,
    0x0000000F, 0x00040020, 0x00000031, 0x00000001, 0x00000007, 0x0004003B,
    0x00000031, 0x00000032, 0x00000001, 0x0004002B, 0x0000000A, 0x00000037,
    0x00000003, 0x0004001C, 0x00000038, 0x00000006, 0x00000037, 0x0005001E,
    0x00000039, 0x00000007, 0x00000007, 0x00000007, 0x0003001D, 0x0000003A,
    0x00000039, 0x0005001E, 0x0000003B, 0x00000007, 0x00000038, 0x0000003A,
    0x00040020, 0x0000003C, 0x00000002, 0x0000003B, 0x0004003B, 0x0000003C,
    0x0000003D, 0x00000002, 0x00040020, 0x00000052, 0x00000003, 0x00000007,
    0x0004003B, 0x00000052, 0x00000053, 0x00000003, 0x0004002B, 0x00000006,
    0x00000060, 0x00000000, 0x00050036, 0x00000002, 0x00000004, 0x00000000,
    0x00000003, 0x000200F8, 0x00000005, 0x00050041, 0x0000001A, 0x0000001B,
    0x00000019, 0x00000016, 0x0004003D, 0x00000015, 0x0000001C, 0x0000001B,
    0x00060041, 0x0000001D, 0x0000001E, 0x00000014, 0x00000016, 0x0000001C,
    0x0004003D, 0x00000007, 0x0000001F, 0x0000001E, 0x00050041, 0x0000001A,
    0x00000023, 0x00000019, 0x00000022, 0x0004003D, 0x00000015, 0x00000024,
    0x00000023, 0x00050080, 0x00000015, 0x00000025, 0x00000024, 0x00000022,
    0x00060041, 0x00000026, 0x00000027, 0x00000014, 0x00000022, 0x00000025,
    0x0004003D, 0x00000006, 0x00000028, 0x00000027, 0x00060041, 0x0000002E,
    0x0000002F, 0x00000014, 0x0000002B, 0x0000001C, 0x0004003D, 0x0000000F,
    0x00000030, 0x0000002F, 0x0004003D, 0x00000007, 0x00000033, 0x00000032,
    0x0007004F, 0x0000000E, 0x00000034, 0x00000033, 0x00000033, 0x00000000,
    0x00000001, 0x00050091, 0x0000000E, 0x00000035, 0x00000030, 0x00000034,
    0x00070041, 0x0000001D, 0x00000040, 0x0000003D, 0x0000002B, 0x0000001C,
    0x00000022, 0x0004003D, 0x00000007, 0x00000041, 0x00000040, 0x00070041,
    0x0000001D, 0x00000046, 0x0000003D, 0x0000002B, 0x00000025, 0x0000002B,
    0x0004003D, 0x00000007, 0x00000047, 0x00000046, 0x00060041, 0x00000026,
    0x0000004B, 0x0000003D, 0x00000022, 0x00000024, 0x0004003D, 0x00000006,
    0x0000004C, 0x0000004B, 0x00060041, 0x00000026, 0x0000004F, 0x0000003D,
    0x00000016, 0x0000001C, 0x0004003D, 0x00000006, 0x00000050, 0x0000004F,
    0x00050081, 0x00000006, 0x00000051, 0x0000004C, 0x00000050, 0x00050085,
    0x00000007, 0x00000056, 0x00000033, 0x0000001F, 0x0005008E, 0x00000007,
    0x00000058, 0x00000056, 0x00000028, 0x0005008E, 0x00000007, 0x0000005B,
    0x00000041, 0x00000051, 0x00050081, 0x00000007, 0x0000005C, 0x00000058,
    0x0000005B, 0x00050081, 0x00000007, 0x0000005E, 0x0000005C, 0x00000047,
    0x00050051, 0x00000006, 0x00000061, 0x00000035, 0x00000000, 0x00050051,
    0x00000006, 0x00000062, 0x00000035, 0x00000001, 0x00070050, 0x00000007,
    0x00000063, 0x00000061, 0x00000062, 0x00000060, 0x00000060, 0x00050081,
    0x00000007, 0x00000064, 0x0000005E, 0x00000063, 0x0003003E, 0x00000053,
    0x00000064, 0x000100FD, 0x00010038,
};

/// A uniform buffer's element at an index the colour gives, glslc -O
/// (`-fshader-stage=frag`), 178 words: an offset that differs from lane to
/// lane, which v3d reads through the TMU (nir_to_vir.c:3315-3317) and the
/// profile refuses (since 1.166).
///
/// ```glsl
/// #version 450
/// layout(location = 0) in vec4 vcolor;
/// layout(location = 0) out vec4 ocolor;
/// layout(set = 0, binding = 0) uniform Block { vec4 tints[4]; } block;
/// void main() {
///     ocolor = vcolor * block.tints[int(vcolor.x * 3.0)];
/// }
/// ```
///
/// ```sh
/// glslc -O -fshader-stage=frag divergent.frag -o divergent.spv   # 178 words
/// spirv-val --target-env vulkan1.0 divergent.spv              # no output, and 0
/// ```
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 32
/// ; Schema: 0
///                OpCapability Shader
///           %1 = OpExtInstImport "GLSL.std.450"
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %4 "main" %9 %11
///                OpExecutionMode %4 OriginUpperLeft
///                OpDecorate %9 Location 0
///                OpDecorate %11 Location 0
///                OpDecorate %15 ArrayStride 16
///                OpDecorate %16 Block
///                OpMemberDecorate %16 0 Offset 0
///                OpDecorate %18 Binding 0
///                OpDecorate %18 DescriptorSet 0
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeFloat 32
///           %7 = OpTypeVector %6 4
///           %8 = OpTypePointer Output %7
///           %9 = OpVariable %8 Output
///          %10 = OpTypePointer Input %7
///          %11 = OpVariable %10 Input
///          %13 = OpTypeInt 32 0
///          %14 = OpConstant %13 4
///          %15 = OpTypeArray %7 %14
///          %16 = OpTypeStruct %15
///          %17 = OpTypePointer Uniform %16
///          %18 = OpVariable %17 Uniform
///          %19 = OpTypeInt 32 1
///          %20 = OpConstant %19 0
///          %21 = OpConstant %13 0
///          %22 = OpTypePointer Input %6
///          %25 = OpConstant %6 3
///          %28 = OpTypePointer Uniform %7
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///          %12 = OpLoad %7 %11
///          %23 = OpAccessChain %22 %11 %21
///          %24 = OpLoad %6 %23
///          %26 = OpFMul %6 %24 %25
///          %27 = OpConvertFToS %19 %26
///          %29 = OpAccessChain %28 %18 %20 %27
///          %30 = OpLoad %7 %29
///          %31 = OpFMul %7 %12 %30
///                OpStore %9 %31
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_divergent = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x00000020, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x00000009, 0x0000000B, 0x00030010,
    0x00000004, 0x00000007, 0x00040047, 0x00000009, 0x0000001E, 0x00000000,
    0x00040047, 0x0000000B, 0x0000001E, 0x00000000, 0x00040047, 0x0000000F,
    0x00000006, 0x00000010, 0x00030047, 0x00000010, 0x00000002, 0x00050048,
    0x00000010, 0x00000000, 0x00000023, 0x00000000, 0x00040047, 0x00000012,
    0x00000021, 0x00000000, 0x00040047, 0x00000012, 0x00000022, 0x00000000,
    0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002, 0x00030016,
    0x00000006, 0x00000020, 0x00040017, 0x00000007, 0x00000006, 0x00000004,
    0x00040020, 0x00000008, 0x00000003, 0x00000007, 0x0004003B, 0x00000008,
    0x00000009, 0x00000003, 0x00040020, 0x0000000A, 0x00000001, 0x00000007,
    0x0004003B, 0x0000000A, 0x0000000B, 0x00000001, 0x00040015, 0x0000000D,
    0x00000020, 0x00000000, 0x0004002B, 0x0000000D, 0x0000000E, 0x00000004,
    0x0004001C, 0x0000000F, 0x00000007, 0x0000000E, 0x0003001E, 0x00000010,
    0x0000000F, 0x00040020, 0x00000011, 0x00000002, 0x00000010, 0x0004003B,
    0x00000011, 0x00000012, 0x00000002, 0x00040015, 0x00000013, 0x00000020,
    0x00000001, 0x0004002B, 0x00000013, 0x00000014, 0x00000000, 0x0004002B,
    0x0000000D, 0x00000015, 0x00000000, 0x00040020, 0x00000016, 0x00000001,
    0x00000006, 0x0004002B, 0x00000006, 0x00000019, 0x40400000, 0x00040020,
    0x0000001C, 0x00000002, 0x00000007, 0x00050036, 0x00000002, 0x00000004,
    0x00000000, 0x00000003, 0x000200F8, 0x00000005, 0x0004003D, 0x00000007,
    0x0000000C, 0x0000000B, 0x00050041, 0x00000016, 0x00000017, 0x0000000B,
    0x00000015, 0x0004003D, 0x00000006, 0x00000018, 0x00000017, 0x00050085,
    0x00000006, 0x0000001A, 0x00000018, 0x00000019, 0x0004006E, 0x00000013,
    0x0000001B, 0x0000001A, 0x00060041, 0x0000001C, 0x0000001D, 0x00000012,
    0x00000014, 0x0000001B, 0x0004003D, 0x00000007, 0x0000001E, 0x0000001D,
    0x00050085, 0x00000007, 0x0000001F, 0x0000000C, 0x0000001E, 0x0003003E,
    0x00000009, 0x0000001F, 0x000100FD, 0x00010038,
};

/// A push constant's vec4 at an index another push constant gives, glslc -O
/// (`-fshader-stage=frag`), 181 words: an index computed into the push
/// constants, which v3dv reads from a buffer of them the profile does not
/// have, and is refused (since 1.166).
///
/// ```glsl
/// #version 450
/// layout(location = 0) in vec4 vcolor;
/// layout(location = 0) out vec4 ocolor;
/// layout(push_constant) uniform Push { int which; int pad; int pad2; int pad3; vec4 colors[2]; } push;
/// void main() {
///     ocolor = vcolor * push.colors[push.which];
/// }
/// ```
///
/// ```sh
/// glslc -O -fshader-stage=frag pushed.frag -o pushed.spv   # 181 words
/// spirv-val --target-env vulkan1.0 pushed.spv              # no output, and 0
/// ```
///
/// ```
/// ; SPIR-V
/// ; Version: 1.0
/// ; Generator: Google Shaderc over Glslang; 11
/// ; Bound: 29
/// ; Schema: 0
///                OpCapability Shader
///           %1 = OpExtInstImport "GLSL.std.450"
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %4 "main" %9 %11
///                OpExecutionMode %4 OriginUpperLeft
///                OpDecorate %9 Location 0
///                OpDecorate %11 Location 0
///                OpDecorate %16 ArrayStride 16
///                OpDecorate %17 Block
///                OpMemberDecorate %17 0 Offset 0
///                OpMemberDecorate %17 1 Offset 4
///                OpMemberDecorate %17 2 Offset 8
///                OpMemberDecorate %17 3 Offset 12
///                OpMemberDecorate %17 4 Offset 16
///           %2 = OpTypeVoid
///           %3 = OpTypeFunction %2
///           %6 = OpTypeFloat 32
///           %7 = OpTypeVector %6 4
///           %8 = OpTypePointer Output %7
///           %9 = OpVariable %8 Output
///          %10 = OpTypePointer Input %7
///          %11 = OpVariable %10 Input
///          %13 = OpTypeInt 32 1
///          %14 = OpTypeInt 32 0
///          %15 = OpConstant %14 2
///          %16 = OpTypeArray %7 %15
///          %17 = OpTypeStruct %13 %13 %13 %13 %16
///          %18 = OpTypePointer PushConstant %17
///          %19 = OpVariable %18 PushConstant
///          %20 = OpConstant %13 4
///          %21 = OpConstant %13 0
///          %22 = OpTypePointer PushConstant %13
///          %25 = OpTypePointer PushConstant %7
///           %4 = OpFunction %2 None %3
///           %5 = OpLabel
///          %12 = OpLoad %7 %11
///          %23 = OpAccessChain %22 %19 %21
///          %24 = OpLoad %13 %23
///          %26 = OpAccessChain %25 %19 %20 %24
///          %27 = OpLoad %7 %26
///          %28 = OpFMul %7 %12 %27
///                OpStore %9 %28
///                OpReturn
///                OpFunctionEnd
/// ```
pub const glslc_pushed = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x0000001D, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x00000009, 0x0000000B, 0x00030010,
    0x00000004, 0x00000007, 0x00040047, 0x00000009, 0x0000001E, 0x00000000,
    0x00040047, 0x0000000B, 0x0000001E, 0x00000000, 0x00040047, 0x00000010,
    0x00000006, 0x00000010, 0x00030047, 0x00000011, 0x00000002, 0x00050048,
    0x00000011, 0x00000000, 0x00000023, 0x00000000, 0x00050048, 0x00000011,
    0x00000001, 0x00000023, 0x00000004, 0x00050048, 0x00000011, 0x00000002,
    0x00000023, 0x00000008, 0x00050048, 0x00000011, 0x00000003, 0x00000023,
    0x0000000C, 0x00050048, 0x00000011, 0x00000004, 0x00000023, 0x00000010,
    0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002, 0x00030016,
    0x00000006, 0x00000020, 0x00040017, 0x00000007, 0x00000006, 0x00000004,
    0x00040020, 0x00000008, 0x00000003, 0x00000007, 0x0004003B, 0x00000008,
    0x00000009, 0x00000003, 0x00040020, 0x0000000A, 0x00000001, 0x00000007,
    0x0004003B, 0x0000000A, 0x0000000B, 0x00000001, 0x00040015, 0x0000000D,
    0x00000020, 0x00000001, 0x00040015, 0x0000000E, 0x00000020, 0x00000000,
    0x0004002B, 0x0000000E, 0x0000000F, 0x00000002, 0x0004001C, 0x00000010,
    0x00000007, 0x0000000F, 0x0007001E, 0x00000011, 0x0000000D, 0x0000000D,
    0x0000000D, 0x0000000D, 0x00000010, 0x00040020, 0x00000012, 0x00000009,
    0x00000011, 0x0004003B, 0x00000012, 0x00000013, 0x00000009, 0x0004002B,
    0x0000000D, 0x00000014, 0x00000004, 0x0004002B, 0x0000000D, 0x00000015,
    0x00000000, 0x00040020, 0x00000016, 0x00000009, 0x0000000D, 0x00040020,
    0x00000019, 0x00000009, 0x00000007, 0x00050036, 0x00000002, 0x00000004,
    0x00000000, 0x00000003, 0x000200F8, 0x00000005, 0x0004003D, 0x00000007,
    0x0000000C, 0x0000000B, 0x00050041, 0x00000016, 0x00000017, 0x00000013,
    0x00000015, 0x0004003D, 0x0000000D, 0x00000018, 0x00000017, 0x00060041,
    0x00000019, 0x0000001A, 0x00000013, 0x00000014, 0x00000018, 0x0004003D,
    0x00000007, 0x0000001B, 0x0000001A, 0x00050085, 0x00000007, 0x0000001C,
    0x0000000C, 0x0000001B, 0x0003003E, 0x00000009, 0x0000001C, 0x000100FD,
    0x00010038,
};
