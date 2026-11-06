// SPDX-License-Identifier: MIT
//! SPIR-V modules to compare against: the smallest valid module for each
//! of the forms facet's V3D already has a hand-written QPU program for,
//! and one vertex module.
//!
//! **Where they come from.** Each of the five fragment modules was
//! written by hand as SPIR-V assembly, assembled with Khronos' own tool
//! and accepted by Khronos' own validator, on a PC:
//!
//! ```sh
//! spirv-as --target-env vulkan1.0 min_flat.spvasm -o min_flat.spv
//! spirv-val --target-env vulkan1.0 min_flat.spv     # no output, and 0
//! spirv-dis --raw-id min_flat.spv                   # to read it back
//! ```
//!
//! So these words are not facet's idea of a module: they are a module,
//! and `spirv.Emit` is held to them word for word. The assembly is above
//! each one, so that a word can be found by reading rather than by
//! counting. The generator word (index 2) is the assembler's own, and is
//! the one word facet writes differently - `spirv.generator` puts the
//! library's revision there - so a comparison leaves it out.
//!
//! Each was first compiled from GLSL with `glslc -O0` as well, which
//! settled what has to be in a module and what glslang merely likes to
//! put there: the debug instructions, `OpExtInstImport "GLSL.std.450"`,
//! the three members of `gl_PerVertex` that nothing reads, and a
//! `Function` variable where `OpCompositeExtract` does. None of those is
//! needed, and leaving them out is what makes these the smallest valid
//! forms: 70 words against glslc's 110 for the flat colour, 193 against
//! 330 for the vertex.
//!
//! `scripts/spirv-check.sh` hands every array here back to `spirv-val`,
//! so the claim that they are valid is checked rather than remembered.

/// A colour of its own, written to location 0.
///
/// ```
///                OpCapability Shader
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %1 "main" %2
///                OpExecutionMode %1 OriginUpperLeft
///                OpDecorate %2 Location 0
///           %3 = OpTypeVoid
///           %4 = OpTypeFunction %3
///           %5 = OpTypeFloat 32
///           %6 = OpTypeVector %5 4
///           %7 = OpTypePointer Output %6
///           %2 = OpVariable %7 Output
///           %8 = OpConstant %5 1
///           %9 = OpConstant %5 0
///          %10 = OpConstantComposite %6 %8 %9 %9 %8
///           %1 = OpFunction %3 None %4
///          %11 = OpLabel
///                OpStore %2 %10
///                OpReturn
///                OpFunctionEnd
/// ```
pub const min_flat = [_]u32{
    0x07230203, 0x00010000, 0x00070000, 0x0000000C, 0x00000000, 0x00020011,
    0x00000001, 0x0003000E, 0x00000000, 0x00000001, 0x0006000F, 0x00000004,
    0x00000001, 0x6E69616D, 0x00000000, 0x00000002, 0x00030010, 0x00000001,
    0x00000007, 0x00040047, 0x00000002, 0x0000001E, 0x00000000, 0x00020013,
    0x00000003, 0x00030021, 0x00000004, 0x00000003, 0x00030016, 0x00000005,
    0x00000020, 0x00040017, 0x00000006, 0x00000005, 0x00000004, 0x00040020,
    0x00000007, 0x00000003, 0x00000006, 0x0004003B, 0x00000007, 0x00000002,
    0x00000003, 0x0004002B, 0x00000005, 0x00000008, 0x3F800000, 0x0004002B,
    0x00000005, 0x00000009, 0x00000000, 0x0007002C, 0x00000006, 0x0000000A,
    0x00000008, 0x00000009, 0x00000009, 0x00000008, 0x00050036, 0x00000003,
    0x00000001, 0x00000000, 0x00000004, 0x000200F8, 0x0000000B, 0x0003003E,
    0x00000002, 0x0000000A, 0x000100FD, 0x00010038,
};

/// The colour the vertices carry, interpolated from location 0.
///
/// ```
///                OpCapability Shader
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %1 "main" %2 %3
///                OpExecutionMode %1 OriginUpperLeft
///                OpDecorate %2 Location 0
///                OpDecorate %3 Location 0
///           %4 = OpTypeVoid
///           %5 = OpTypeFunction %4
///           %6 = OpTypeFloat 32
///           %7 = OpTypeVector %6 4
///           %8 = OpTypePointer Output %7
///           %2 = OpVariable %8 Output
///           %9 = OpTypePointer Input %7
///           %3 = OpVariable %9 Input
///           %1 = OpFunction %4 None %5
///          %10 = OpLabel
///          %11 = OpLoad %7 %3
///                OpStore %2 %11
///                OpReturn
///                OpFunctionEnd
/// ```
pub const min_interp = [_]u32{
    0x07230203, 0x00010000, 0x00070000, 0x0000000C, 0x00000000, 0x00020011,
    0x00000001, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000001, 0x6E69616D, 0x00000000, 0x00000002, 0x00000003, 0x00030010,
    0x00000001, 0x00000007, 0x00040047, 0x00000002, 0x0000001E, 0x00000000,
    0x00040047, 0x00000003, 0x0000001E, 0x00000000, 0x00020013, 0x00000004,
    0x00030021, 0x00000005, 0x00000004, 0x00030016, 0x00000006, 0x00000020,
    0x00040017, 0x00000007, 0x00000006, 0x00000004, 0x00040020, 0x00000008,
    0x00000003, 0x00000007, 0x0004003B, 0x00000008, 0x00000002, 0x00000003,
    0x00040020, 0x00000009, 0x00000001, 0x00000007, 0x0004003B, 0x00000009,
    0x00000003, 0x00000001, 0x00050036, 0x00000004, 0x00000001, 0x00000000,
    0x00000005, 0x000200F8, 0x0000000A, 0x0004003D, 0x00000007, 0x0000000B,
    0x00000003, 0x0003003E, 0x00000002, 0x0000000B, 0x000100FD, 0x00010038,
};

/// A texture at the two coordinates location 0 carries, sampled through
/// the sampled image at set 0 binding 0.
///
/// ```
///                OpCapability Shader
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %1 "main" %2 %3
///                OpExecutionMode %1 OriginUpperLeft
///                OpDecorate %2 Location 0
///                OpDecorate %3 Location 0
///                OpDecorate %4 DescriptorSet 0
///                OpDecorate %4 Binding 0
///           %5 = OpTypeVoid
///           %6 = OpTypeFunction %5
///           %7 = OpTypeFloat 32
///           %8 = OpTypeVector %7 4
///           %9 = OpTypePointer Output %8
///           %2 = OpVariable %9 Output
///          %10 = OpTypeVector %7 2
///          %11 = OpTypePointer Input %10
///           %3 = OpVariable %11 Input
///          %12 = OpTypeImage %7 2D 0 0 0 1 Unknown
///          %13 = OpTypeSampledImage %12
///          %14 = OpTypePointer UniformConstant %13
///           %4 = OpVariable %14 UniformConstant
///           %1 = OpFunction %5 None %6
///          %15 = OpLabel
///          %16 = OpLoad %13 %4
///          %17 = OpLoad %10 %3
///          %18 = OpImageSampleImplicitLod %8 %16 %17
///                OpStore %2 %18
///                OpReturn
///                OpFunctionEnd
/// ```
pub const min_tex = [_]u32{
    0x07230203, 0x00010000, 0x00070000, 0x00000013, 0x00000000, 0x00020011,
    0x00000001, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000001, 0x6E69616D, 0x00000000, 0x00000002, 0x00000003, 0x00030010,
    0x00000001, 0x00000007, 0x00040047, 0x00000002, 0x0000001E, 0x00000000,
    0x00040047, 0x00000003, 0x0000001E, 0x00000000, 0x00040047, 0x00000004,
    0x00000022, 0x00000000, 0x00040047, 0x00000004, 0x00000021, 0x00000000,
    0x00020013, 0x00000005, 0x00030021, 0x00000006, 0x00000005, 0x00030016,
    0x00000007, 0x00000020, 0x00040017, 0x00000008, 0x00000007, 0x00000004,
    0x00040020, 0x00000009, 0x00000003, 0x00000008, 0x0004003B, 0x00000009,
    0x00000002, 0x00000003, 0x00040017, 0x0000000A, 0x00000007, 0x00000002,
    0x00040020, 0x0000000B, 0x00000001, 0x0000000A, 0x0004003B, 0x0000000B,
    0x00000003, 0x00000001, 0x00090019, 0x0000000C, 0x00000007, 0x00000001,
    0x00000000, 0x00000000, 0x00000000, 0x00000001, 0x00000000, 0x0003001B,
    0x0000000D, 0x0000000C, 0x00040020, 0x0000000E, 0x00000000, 0x0000000D,
    0x0004003B, 0x0000000E, 0x00000004, 0x00000000, 0x00050036, 0x00000005,
    0x00000001, 0x00000000, 0x00000006, 0x000200F8, 0x0000000F, 0x0004003D,
    0x0000000D, 0x00000010, 0x00000004, 0x0004003D, 0x0000000A, 0x00000011,
    0x00000003, 0x00050057, 0x00000008, 0x00000012, 0x00000010, 0x00000011,
    0x0003003E, 0x00000002, 0x00000012, 0x000100FD, 0x00010038,
};

/// The same sample taken a constant offset away in texels: one across and
/// two up, SPIR-V's `ConstOffset` image operand. The only optional image
/// operand facet writes, and the only one of the offsets that needs no
/// capability - which is why Vulkan requires `minTexelOffset` and
/// `maxTexelOffset` of every implementation and the gather pair only with
/// `shaderImageGatherExtended`. (Since 1.87, item 28.)
///
/// `min_tex` with five declarations inserted after the sampler variable
/// and two operands on the sample: the mask word, `ConstOffset` being
/// 0x8, and then the id of the vector. The id bound goes from 0x13 to
/// 0x18 and the sample's word count from 5 to 7.
///
/// ```
///                OpCapability Shader
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %1 "main" %2 %3
///                OpExecutionMode %1 OriginUpperLeft
///                OpDecorate %2 Location 0
///                OpDecorate %3 Location 0
///                OpDecorate %4 DescriptorSet 0
///                OpDecorate %4 Binding 0
///           %5 = OpTypeVoid
///           %6 = OpTypeFunction %5
///           %7 = OpTypeFloat 32
///           %8 = OpTypeVector %7 4
///           %9 = OpTypePointer Output %8
///           %2 = OpVariable %9 Output
///          %10 = OpTypeVector %7 2
///          %11 = OpTypePointer Input %10
///           %3 = OpVariable %11 Input
///          %12 = OpTypeImage %7 2D 0 0 0 1 Unknown
///          %13 = OpTypeSampledImage %12
///          %14 = OpTypePointer UniformConstant %13
///           %4 = OpVariable %14 UniformConstant
///          %15 = OpTypeInt 32 1
///          %16 = OpTypeVector %15 2
///          %17 = OpConstant %15 1
///          %18 = OpConstant %15 -2
///          %19 = OpConstantComposite %16 %17 %18
///           %1 = OpFunction %5 None %6
///          %20 = OpLabel
///          %21 = OpLoad %13 %4
///          %22 = OpLoad %10 %3
///          %23 = OpImageSampleImplicitLod %8 %21 %22 ConstOffset %19
///                OpStore %2 %23
///                OpReturn
///                OpFunctionEnd
/// ```
pub const min_offset = [_]u32{
    0x07230203, 0x00010000, 0x00070000, 0x00000018, 0x00000000, 0x00020011,
    0x00000001, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000001, 0x6E69616D, 0x00000000, 0x00000002, 0x00000003, 0x00030010,
    0x00000001, 0x00000007, 0x00040047, 0x00000002, 0x0000001E, 0x00000000,
    0x00040047, 0x00000003, 0x0000001E, 0x00000000, 0x00040047, 0x00000004,
    0x00000022, 0x00000000, 0x00040047, 0x00000004, 0x00000021, 0x00000000,
    0x00020013, 0x00000005, 0x00030021, 0x00000006, 0x00000005, 0x00030016,
    0x00000007, 0x00000020, 0x00040017, 0x00000008, 0x00000007, 0x00000004,
    0x00040020, 0x00000009, 0x00000003, 0x00000008, 0x0004003B, 0x00000009,
    0x00000002, 0x00000003, 0x00040017, 0x0000000A, 0x00000007, 0x00000002,
    0x00040020, 0x0000000B, 0x00000001, 0x0000000A, 0x0004003B, 0x0000000B,
    0x00000003, 0x00000001, 0x00090019, 0x0000000C, 0x00000007, 0x00000001,
    0x00000000, 0x00000000, 0x00000000, 0x00000001, 0x00000000, 0x0003001B,
    0x0000000D, 0x0000000C, 0x00040020, 0x0000000E, 0x00000000, 0x0000000D,
    0x0004003B, 0x0000000E, 0x00000004, 0x00000000, 0x00040015, 0x0000000F,
    0x00000020, 0x00000001, 0x00040017, 0x00000010, 0x0000000F, 0x00000002,
    0x0004002B, 0x0000000F, 0x00000011, 0x00000001, 0x0004002B, 0x0000000F,
    0x00000012, 0xFFFFFFFE, 0x0005002C, 0x00000010, 0x00000013, 0x00000011,
    0x00000012, 0x00050036, 0x00000005, 0x00000001, 0x00000000, 0x00000006,
    0x000200F8, 0x00000014, 0x0004003D, 0x0000000D, 0x00000015, 0x00000004,
    0x0004003D, 0x0000000A, 0x00000016, 0x00000003, 0x00070057, 0x00000008,
    0x00000017, 0x00000015, 0x00000016, 0x00000008, 0x00000013, 0x0003003E,
    0x00000002, 0x00000017, 0x000100FD, 0x00010038,
};

/// That sample multiplied by the colour at location 1.
///
/// ```
///                OpCapability Shader
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %1 "main" %2 %3 %4
///                OpExecutionMode %1 OriginUpperLeft
///                OpDecorate %2 Location 0
///                OpDecorate %3 Location 0
///                OpDecorate %4 Location 1
///                OpDecorate %5 DescriptorSet 0
///                OpDecorate %5 Binding 0
///           %6 = OpTypeVoid
///           %7 = OpTypeFunction %6
///           %8 = OpTypeFloat 32
///           %9 = OpTypeVector %8 4
///          %10 = OpTypePointer Output %9
///           %2 = OpVariable %10 Output
///          %11 = OpTypeVector %8 2
///          %12 = OpTypePointer Input %11
///           %3 = OpVariable %12 Input
///          %13 = OpTypePointer Input %9
///           %4 = OpVariable %13 Input
///          %14 = OpTypeImage %8 2D 0 0 0 1 Unknown
///          %15 = OpTypeSampledImage %14
///          %16 = OpTypePointer UniformConstant %15
///           %5 = OpVariable %16 UniformConstant
///           %1 = OpFunction %6 None %7
///          %17 = OpLabel
///          %18 = OpLoad %15 %5
///          %19 = OpLoad %11 %3
///          %20 = OpImageSampleImplicitLod %9 %18 %19
///          %21 = OpLoad %9 %4
///          %22 = OpFMul %9 %20 %21
///                OpStore %2 %22
///                OpReturn
///                OpFunctionEnd
/// ```
pub const min_texmod = [_]u32{
    0x07230203, 0x00010000, 0x00070000, 0x00000017, 0x00000000, 0x00020011,
    0x00000001, 0x0003000E, 0x00000000, 0x00000001, 0x0008000F, 0x00000004,
    0x00000001, 0x6E69616D, 0x00000000, 0x00000002, 0x00000003, 0x00000004,
    0x00030010, 0x00000001, 0x00000007, 0x00040047, 0x00000002, 0x0000001E,
    0x00000000, 0x00040047, 0x00000003, 0x0000001E, 0x00000000, 0x00040047,
    0x00000004, 0x0000001E, 0x00000001, 0x00040047, 0x00000005, 0x00000022,
    0x00000000, 0x00040047, 0x00000005, 0x00000021, 0x00000000, 0x00020013,
    0x00000006, 0x00030021, 0x00000007, 0x00000006, 0x00030016, 0x00000008,
    0x00000020, 0x00040017, 0x00000009, 0x00000008, 0x00000004, 0x00040020,
    0x0000000A, 0x00000003, 0x00000009, 0x0004003B, 0x0000000A, 0x00000002,
    0x00000003, 0x00040017, 0x0000000B, 0x00000008, 0x00000002, 0x00040020,
    0x0000000C, 0x00000001, 0x0000000B, 0x0004003B, 0x0000000C, 0x00000003,
    0x00000001, 0x00040020, 0x0000000D, 0x00000001, 0x00000009, 0x0004003B,
    0x0000000D, 0x00000004, 0x00000001, 0x00090019, 0x0000000E, 0x00000008,
    0x00000001, 0x00000000, 0x00000000, 0x00000000, 0x00000001, 0x00000000,
    0x0003001B, 0x0000000F, 0x0000000E, 0x00040020, 0x00000010, 0x00000000,
    0x0000000F, 0x0004003B, 0x00000010, 0x00000005, 0x00000000, 0x00050036,
    0x00000006, 0x00000001, 0x00000000, 0x00000007, 0x000200F8, 0x00000011,
    0x0004003D, 0x0000000F, 0x00000012, 0x00000005, 0x0004003D, 0x0000000B,
    0x00000013, 0x00000003, 0x00050057, 0x00000009, 0x00000014, 0x00000012,
    0x00000013, 0x0004003D, 0x00000009, 0x00000015, 0x00000004, 0x00050085,
    0x00000009, 0x00000016, 0x00000014, 0x00000015, 0x0003003E, 0x00000002,
    0x00000016, 0x000100FD, 0x00010038,
};

/// The same sample, with a pixel dropped where its alpha is under a half.
///
/// ```
///                OpCapability Shader
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %1 "main" %2 %3
///                OpExecutionMode %1 OriginUpperLeft
///                OpDecorate %2 Location 0
///                OpDecorate %3 Location 0
///                OpDecorate %4 DescriptorSet 0
///                OpDecorate %4 Binding 0
///           %5 = OpTypeVoid
///           %6 = OpTypeFunction %5
///           %7 = OpTypeFloat 32
///           %8 = OpTypeVector %7 4
///           %9 = OpTypePointer Output %8
///           %2 = OpVariable %9 Output
///          %10 = OpTypeVector %7 2
///          %11 = OpTypePointer Input %10
///           %3 = OpVariable %11 Input
///          %12 = OpTypeImage %7 2D 0 0 0 1 Unknown
///          %13 = OpTypeSampledImage %12
///          %14 = OpTypePointer UniformConstant %13
///           %4 = OpVariable %14 UniformConstant
///          %15 = OpTypeBool
///          %16 = OpConstant %7 0.5
///           %1 = OpFunction %5 None %6
///          %17 = OpLabel
///          %18 = OpLoad %13 %4
///          %19 = OpLoad %10 %3
///          %20 = OpImageSampleImplicitLod %8 %18 %19
///          %21 = OpCompositeExtract %7 %20 3
///          %22 = OpFOrdLessThan %15 %21 %16
///                OpSelectionMerge %23 None
///                OpBranchConditional %22 %24 %23
///          %24 = OpLabel
///                OpKill
///          %23 = OpLabel
///                OpStore %2 %20
///                OpReturn
///                OpFunctionEnd
/// ```
pub const min_discard = [_]u32{
    0x07230203, 0x00010000, 0x00070000, 0x00000019, 0x00000000, 0x00020011,
    0x00000001, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000001, 0x6E69616D, 0x00000000, 0x00000002, 0x00000003, 0x00030010,
    0x00000001, 0x00000007, 0x00040047, 0x00000002, 0x0000001E, 0x00000000,
    0x00040047, 0x00000003, 0x0000001E, 0x00000000, 0x00040047, 0x00000004,
    0x00000022, 0x00000000, 0x00040047, 0x00000004, 0x00000021, 0x00000000,
    0x00020013, 0x00000005, 0x00030021, 0x00000006, 0x00000005, 0x00030016,
    0x00000007, 0x00000020, 0x00040017, 0x00000008, 0x00000007, 0x00000004,
    0x00040020, 0x00000009, 0x00000003, 0x00000008, 0x0004003B, 0x00000009,
    0x00000002, 0x00000003, 0x00040017, 0x0000000A, 0x00000007, 0x00000002,
    0x00040020, 0x0000000B, 0x00000001, 0x0000000A, 0x0004003B, 0x0000000B,
    0x00000003, 0x00000001, 0x00090019, 0x0000000C, 0x00000007, 0x00000001,
    0x00000000, 0x00000000, 0x00000000, 0x00000001, 0x00000000, 0x0003001B,
    0x0000000D, 0x0000000C, 0x00040020, 0x0000000E, 0x00000000, 0x0000000D,
    0x0004003B, 0x0000000E, 0x00000004, 0x00000000, 0x00020014, 0x0000000F,
    0x0004002B, 0x00000007, 0x00000010, 0x3F000000, 0x00050036, 0x00000005,
    0x00000001, 0x00000000, 0x00000006, 0x000200F8, 0x00000011, 0x0004003D,
    0x0000000D, 0x00000012, 0x00000004, 0x0004003D, 0x0000000A, 0x00000013,
    0x00000003, 0x00050057, 0x00000008, 0x00000014, 0x00000012, 0x00000013,
    0x00050051, 0x00000007, 0x00000015, 0x00000014, 0x00000003, 0x000500B8,
    0x0000000F, 0x00000016, 0x00000015, 0x00000010, 0x000300F7, 0x00000017,
    0x00000000, 0x000400FA, 0x00000016, 0x00000018, 0x00000017, 0x000200F8,
    0x00000018, 0x000100FC, 0x000200F8, 0x00000017, 0x0003003E, 0x00000002,
    0x00000014, 0x000100FD, 0x00010038,
};

/// A vertex: a matrix from a uniform block at set 0 binding 0, a position
/// from location 0, and one varying out.
///
/// This one is **facet's own output**, validated the same way, rather than
/// an assembler's, because the two cannot have the same ids. A decorated
/// type has to be named before the decoration that names it, so an
/// assembler gives the `gl_PerVertex` block and the uniform block early
/// ids; facet hands out an id where it declares a type and puts the
/// decoration in its own section, which is what lets one emitter write
/// both. The module is the same module - 193 words against the
/// assembler's 200 - and Khronos' validator says so:
///
/// ```sh
/// spirv-val --target-env vulkan1.0 facet_vert.spv   # no output, and 0
/// ```
///
/// Read back with `spirv-dis --raw-id --no-header`:
///
/// ```
///                OpCapability Shader
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Vertex %1 "main" %2 %3 %4
///                OpMemberDecorate %10 0 BuiltIn Position
///                OpDecorate %10 Block
///                OpDecorate %13 Block
///                OpMemberDecorate %13 0 ColMajor
///                OpMemberDecorate %13 0 MatrixStride 16
///                OpMemberDecorate %13 0 Offset 0
///                OpDecorate %5 DescriptorSet 0
///                OpDecorate %5 Binding 0
///                OpDecorate %3 Location 0
///                OpDecorate %4 Location 0
///           %6 = OpTypeVoid
///           %7 = OpTypeFunction %6
///           %8 = OpTypeFloat 32
///           %9 = OpTypeVector %8 4
///          %10 = OpTypeStruct %9
///          %11 = OpTypePointer Output %10
///           %2 = OpVariable %11 Output
///          %12 = OpTypeMatrix %9 4
///          %13 = OpTypeStruct %12
///          %14 = OpTypePointer Uniform %13
///           %5 = OpVariable %14 Uniform
///          %15 = OpTypePointer Uniform %12
///          %16 = OpTypeVector %8 3
///          %17 = OpTypePointer Input %16
///           %3 = OpVariable %17 Input
///          %18 = OpTypePointer Output %9
///           %4 = OpVariable %18 Output
///          %19 = OpTypeInt 32 1
///          %20 = OpConstant %19 0
///          %21 = OpConstant %8 1
///           %1 = OpFunction %6 None %7
///          %22 = OpLabel
///          %23 = OpAccessChain %15 %5 %20
///          %24 = OpLoad %12 %23
///          %25 = OpLoad %16 %3
///          %26 = OpCompositeExtract %8 %25 0
///          %27 = OpCompositeExtract %8 %25 1
///          %28 = OpCompositeExtract %8 %25 2
///          %29 = OpCompositeConstruct %9 %26 %27 %28 %21
///          %30 = OpMatrixTimesVector %9 %24 %29
///          %31 = OpAccessChain %18 %2 %20
///                OpStore %31 %30
///                OpStore %4 %29
///                OpReturn
///                OpFunctionEnd
/// ```
pub const min_vert = [_]u32{
    0x07230203, 0x00010000, 0x0000004B, 0x00000020, 0x00000000, 0x00020011,
    0x00000001, 0x0003000E, 0x00000000, 0x00000001, 0x0008000F, 0x00000000,
    0x00000001, 0x6E69616D, 0x00000000, 0x00000002, 0x00000003, 0x00000004,
    0x00050048, 0x0000000A, 0x00000000, 0x0000000B, 0x00000000, 0x00030047,
    0x0000000A, 0x00000002, 0x00030047, 0x0000000D, 0x00000002, 0x00040048,
    0x0000000D, 0x00000000, 0x00000005, 0x00050048, 0x0000000D, 0x00000000,
    0x00000007, 0x00000010, 0x00050048, 0x0000000D, 0x00000000, 0x00000023,
    0x00000000, 0x00040047, 0x00000005, 0x00000022, 0x00000000, 0x00040047,
    0x00000005, 0x00000021, 0x00000000, 0x00040047, 0x00000003, 0x0000001E,
    0x00000000, 0x00040047, 0x00000004, 0x0000001E, 0x00000000, 0x00020013,
    0x00000006, 0x00030021, 0x00000007, 0x00000006, 0x00030016, 0x00000008,
    0x00000020, 0x00040017, 0x00000009, 0x00000008, 0x00000004, 0x0003001E,
    0x0000000A, 0x00000009, 0x00040020, 0x0000000B, 0x00000003, 0x0000000A,
    0x0004003B, 0x0000000B, 0x00000002, 0x00000003, 0x00040018, 0x0000000C,
    0x00000009, 0x00000004, 0x0003001E, 0x0000000D, 0x0000000C, 0x00040020,
    0x0000000E, 0x00000002, 0x0000000D, 0x0004003B, 0x0000000E, 0x00000005,
    0x00000002, 0x00040020, 0x0000000F, 0x00000002, 0x0000000C, 0x00040017,
    0x00000010, 0x00000008, 0x00000003, 0x00040020, 0x00000011, 0x00000001,
    0x00000010, 0x0004003B, 0x00000011, 0x00000003, 0x00000001, 0x00040020,
    0x00000012, 0x00000003, 0x00000009, 0x0004003B, 0x00000012, 0x00000004,
    0x00000003, 0x00040015, 0x00000013, 0x00000020, 0x00000001, 0x0004002B,
    0x00000013, 0x00000014, 0x00000000, 0x0004002B, 0x00000008, 0x00000015,
    0x3F800000, 0x00050036, 0x00000006, 0x00000001, 0x00000000, 0x00000007,
    0x000200F8, 0x00000016, 0x00050041, 0x0000000F, 0x00000017, 0x00000005,
    0x00000014, 0x0004003D, 0x0000000C, 0x00000018, 0x00000017, 0x0004003D,
    0x00000010, 0x00000019, 0x00000003, 0x00050051, 0x00000008, 0x0000001A,
    0x00000019, 0x00000000, 0x00050051, 0x00000008, 0x0000001B, 0x00000019,
    0x00000001, 0x00050051, 0x00000008, 0x0000001C, 0x00000019, 0x00000002,
    0x00070050, 0x00000009, 0x0000001D, 0x0000001A, 0x0000001B, 0x0000001C,
    0x00000015, 0x00050091, 0x00000009, 0x0000001E, 0x00000018, 0x0000001D,
    0x00050041, 0x00000012, 0x0000001F, 0x00000002, 0x00000014, 0x0003003E,
    0x0000001F, 0x0000001E, 0x0003003E, 0x00000004, 0x0000001D, 0x000100FD,
    0x00010038,
};

/// The colour the vertices carry, dimmed by one float they carry beside
/// it: a varying of one float, which is a float and not a vector of one.
/// SPIR-V has no vector of one component, and facet wrote one here until
/// the QPU back end's reader turned the module down (`spirv.Emit.typeVector`
/// refuses to write one now).
///
/// Facet's own output, like `min_vert` above: there is no assembled
/// counterpart, because the ids of a module with decorated inputs cannot
/// be an assembler's. Khronos' validator says it is a module:
///
/// ```sh
/// spirv-val --target-env vulkan1.0 facet_scaled.spv   # no output, and 0
/// ```
///
/// Read back with `spirv-dis --raw-id --no-header`:
///
/// ```
///                OpCapability Shader
///                OpMemoryModel Logical GLSL450
///                OpEntryPoint Fragment %1 "main" %2 %3 %4
///                OpExecutionMode %1 OriginUpperLeft
///                OpDecorate %2 Location 0
///                OpDecorate %3 Location 0
///                OpDecorate %4 Location 1
///           %5 = OpTypeVoid
///           %6 = OpTypeFunction %5
///           %7 = OpTypeFloat 32
///           %8 = OpTypeVector %7 4
///           %9 = OpTypePointer Output %8
///           %2 = OpVariable %9 Output
///          %10 = OpTypePointer Input %8
///           %3 = OpVariable %10 Input
///          %11 = OpTypePointer Input %7
///           %4 = OpVariable %11 Input
///           %1 = OpFunction %5 None %6
///          %12 = OpLabel
///          %13 = OpLoad %8 %3
///          %14 = OpLoad %7 %4
///          %15 = OpVectorTimesScalar %8 %13 %14
///                OpStore %2 %15
///                OpReturn
///                OpFunctionEnd
/// ```
pub const min_scaled = [_]u32{
    0x07230203, 0x00010000, 0x0000004B, 0x00000010, 0x00000000, 0x00020011,
    0x00000001, 0x0003000E, 0x00000000, 0x00000001, 0x0008000F, 0x00000004,
    0x00000001, 0x6E69616D, 0x00000000, 0x00000002, 0x00000003, 0x00000004,
    0x00030010, 0x00000001, 0x00000007, 0x00040047, 0x00000002, 0x0000001E,
    0x00000000, 0x00040047, 0x00000003, 0x0000001E, 0x00000000, 0x00040047,
    0x00000004, 0x0000001E, 0x00000001, 0x00020013, 0x00000005, 0x00030021,
    0x00000006, 0x00000005, 0x00030016, 0x00000007, 0x00000020, 0x00040017,
    0x00000008, 0x00000007, 0x00000004, 0x00040020, 0x00000009, 0x00000003,
    0x00000008, 0x0004003B, 0x00000009, 0x00000002, 0x00000003, 0x00040020,
    0x0000000A, 0x00000001, 0x00000008, 0x0004003B, 0x0000000A, 0x00000003,
    0x00000001, 0x00040020, 0x0000000B, 0x00000001, 0x00000007, 0x0004003B,
    0x0000000B, 0x00000004, 0x00000001, 0x00050036, 0x00000005, 0x00000001,
    0x00000000, 0x00000006, 0x000200F8, 0x0000000C, 0x0004003D, 0x00000008,
    0x0000000D, 0x00000003, 0x0004003D, 0x00000007, 0x0000000E, 0x00000004,
    0x0005008E, 0x00000008, 0x0000000F, 0x0000000D, 0x0000000E, 0x0003003E,
    0x00000002, 0x0000000F, 0x000100FD, 0x00010038,
};
