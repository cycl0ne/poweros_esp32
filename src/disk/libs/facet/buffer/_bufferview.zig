// SPDX-License-Identifier: MIT
//! A buffer view: a range of a buffer read as texels of a format, which a
//! shader function reaches through a `uniform_texel_buffer` or a
//! `storage_texel_buffer` descriptor (`shader.Resources.texels`).
//!
//! It is the library's one way of giving a function bytes it reads as
//! something other than a Zig type: a storage buffer is read as whatever
//! struct the program declares, which wants the program and the data to
//! agree, while a texel buffer is read as a format, which is what a file
//! or another machine hands over.

const sdk = @import("sdk");
const facet = sdk.facet;
const shader = facet.shader;
const Buffer = @import("_buffer.zig").Buffer;
const Device = @import("../device/_device.zig").Device;

pub const BufferView = struct {
    device: *Device,
    buffer: *Buffer,
    /// How the bytes are read, and the format as it was asked for.
    texels: shader.TexelFormat,
    format: facet.Format,
    /// Where the texels start in the buffer, and how many bytes of them.
    offset: u64,
    bytes: u64,
};

/// How `format` is read as texels, or `.none` for one no view takes.
pub fn texelsOf(format: facet.Format) shader.TexelFormat {
    return switch (format) {
        .r8g8b8a8_unorm => .rgba8888,
        .b8g8r8a8_unorm => .bgra8888,
        .r5g6b5_unorm_pack16 => .rgb565,
        .r32_sfloat => .r32f,
        .r32g32_sfloat => .rg32f,
        .r32g32b32_sfloat => .rgb32f,
        .r32g32b32a32_sfloat => .rgba32f,
        // The regular grid of 1.54: one channel, two or four, of 8, 16 or
        // 32 bits, as 0 to 1, as whole numbers or as floats.
        .r8_unorm => .r8,
        .r8g8_unorm => .rg8,
        .r8_uint => .r8u,
        .r8g8_uint => .rg8u,
        .r8g8b8a8_uint => .rgba8u,
        .r8_sint => .r8i,
        .r8g8_sint => .rg8i,
        .r8g8b8a8_sint => .rgba8i,
        .r16_unorm => .r16,
        .r16g16_unorm => .rg16,
        .r16g16b16a16_unorm => .rgba16,
        .r16_uint => .r16u,
        .r16g16_uint => .rg16u,
        .r16g16b16a16_uint => .rgba16u,
        .r16_sint => .r16i,
        .r16g16_sint => .rg16i,
        .r16g16b16a16_sint => .rgba16i,
        .r16_sfloat => .r16f,
        .r16g16_sfloat => .rg16f,
        .r16g16b16a16_sfloat => .rgba16f,
        .r32_uint => .r32u,
        .r32g32_uint => .rg32u,
        .r32g32b32a32_uint => .rgba32u,
        .r32_sint => .r32i,
        .r32g32_sint => .rg32i,
        .r32g32b32a32_sint => .rgba32i,
        else => .none,
    };
}
