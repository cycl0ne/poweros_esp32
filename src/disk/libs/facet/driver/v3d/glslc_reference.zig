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
