// SPDX-License-Identifier: MIT
//! A module a real toolchain produced, to compile against: `glslc`'s own
//! output for the shader `tests/spirv_reference.zig` keeps the minimal
//! hand-written form of.
//!
//! It is here rather than beside the other reference modules because a
//! Zig module cannot import a file above its own root, and this one is
//! read by `compile.zig`'s tests, which are the V3D module's. The other
//! arrays are read by the library's tests instead.
//! `scripts/spirv-check.sh` hands this one to `spirv-val` with the rest,
//! so the claim that it is a valid Vulkan 1.0 module is checked rather
//! than remembered.

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
