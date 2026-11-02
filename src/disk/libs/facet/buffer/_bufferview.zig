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
        else => .none,
    };
}
