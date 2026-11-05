// SPDX-License-Identifier: MIT
//! What the drivers do with a format: all alike, what they draw into and read
//! being kept in the same formats.

const sdk = @import("sdk");
const facet = sdk.facet;

/// What `format` does on a device that unpacks a compressed or a float
/// image as it is copied in: it can be written and sampled, and not read
/// back.
pub fn properties(format: facet.Format) callconv(.c) facet.FormatProperties {
    return describe(format, false);
}

/// The same on a device that keeps what it was given - a compressed image
/// in its blocks, a float one in its floats
/// (`PhysicalDeviceFeatures.kept_compressed`, `kept_floats`): they lie as
/// they were copied in, so a copy out of such an image reads them back as
/// well.
pub fn keptProperties(format: facet.Format) callconv(.c) facet.FormatProperties {
    return describe(format, true);
}

fn describe(format: facet.Format, keeps_blocks: bool) facet.FormatProperties {
    const transfer = facet.FORMAT_FEATURE_TRANSFER_SRC | facet.FORMAT_FEATURE_TRANSFER_DST;
    const attachment = facet.FORMAT_FEATURE_COLOR_ATTACHMENT | facet.FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND;
    const sampled = facet.FORMAT_FEATURE_SAMPLED_IMAGE | facet.FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR | facet.FORMAT_FEATURE_TRANSFER_DST;
    // A format of whole numbers is sampled without the linear filter:
    // Vulkan has no integer format filtered, there being nothing to mix
    // between two whole numbers (since 1.70).
    const nearest = facet.FORMAT_FEATURE_SAMPLED_IMAGE | facet.FORMAT_FEATURE_TRANSFER_DST;
    // The formats a texture is kept in are the ones a function can write
    // through as well; the unpacked ones are not, being kept as 8888.
    const storage = facet.FORMAT_FEATURE_STORAGE_IMAGE;
    // A BufferView of these reads a buffer's bytes as texels, and a
    // storage one is written through as well (CreateBufferView).
    const texels = facet.FORMAT_FEATURE_UNIFORM_TEXEL_BUFFER | facet.FORMAT_FEATURE_STORAGE_TEXEL_BUFFER;
    const vertices = facet.FORMAT_FEATURE_VERTEX_BUFFER;
    return switch (format) {
        // STORAGE_IMAGE in the linear features says the rows of this
        // format may be written through by a function, which is what a
        // colour attachment written through as a storage image is kept in
        // (`_image.rowTexture`, since 1.56): a texture of 8888 is
        // 0xAARRGGBB, as these rows are.
        .b8g8r8a8_unorm => .{
            .linear_tiling_features = attachment | transfer | storage,
            .optimal_tiling_features = attachment | transfer | sampled | storage,
            .buffer_features = vertices | texels,
        },
        // No texture reads a word with red in its low byte, so rows of
        // this one are not written through; its texels, kept in a
        // texture's own layout, are.
        .r8g8b8a8_unorm => .{
            .linear_tiling_features = attachment | transfer,
            .optimal_tiling_features = attachment | transfer | sampled | storage,
            .buffer_features = vertices | texels,
        },
        .r5g6b5_unorm_pack16 => .{ .linear_tiling_features = attachment | transfer | storage, .optimal_tiling_features = attachment | transfer | sampled | storage, .buffer_features = texels },
        // One byte of red a texel, sampled and written through, and never
        // an attachment: a texture of one channel, read as (red, 0, 0, 1)
        // (`PhysicalDeviceFeatures.small_texels`, since 1.48). A device
        // without that feature refuses such an image all the same.
        .r8_unorm => .{
            .linear_tiling_features = 0,
            .optimal_tiling_features = transfer | sampled | storage,
            // And a texel buffer of one byte a texel, since 1.54.
            .buffer_features = texels,
        },
        // A depth attachment, and since 1.30 a transfer as well: a pass
        // that stores its depth writes the image's rows, and a copy reads
        // them (`PhysicalDeviceFeatures.stored_depth`).
        // Sampled as well since 1.39, where the device has it
        // (`PhysicalDeviceFeatures.sampled_depth`): a shadow map drawn
        // into and sampled out of without a copy.
        .d16_unorm => .{
            .linear_tiling_features = 0,
            .optimal_tiling_features = facet.FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT | transfer | facet.FORMAT_FEATURE_SAMPLED_IMAGE | facet.FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR,
            .buffer_features = 0,
        },
        // Since 1.38 these two keep their stencil the same way, each
        // pixel's depth and stencil beside each other in the rows
        // (`PhysicalDeviceFeatures.stored_stencil`), and a copy reads or
        // writes both at once, 1 byte a pixel or 4.
        .s8_uint, .d16_unorm_s8_uint => .{ .linear_tiling_features = 0, .optimal_tiling_features = facet.FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT | transfer, .buffer_features = 0 },
        // Compressed: sampled and written, and read back as well where the
        // blocks are kept, there being something of the format to read.
        .bc1_rgb_unorm_block, .bc1_rgba_unorm_block, .bc2_unorm_block, .bc3_unorm_block, .bc4_unorm_block, .bc5_unorm_block, .bc7_unorm_block, .bc6h_ufloat_block, .bc6h_sfloat_block => .{
            .linear_tiling_features = 0,
            .optimal_tiling_features = sampled | facet.FORMAT_FEATURE_TRANSFER_DST |
                if (keeps_blocks) facet.FORMAT_FEATURE_TRANSFER_SRC else 0,
            .buffer_features = 0,
        },
        // ETC2 and EAC are unpacked as they are copied in, on every
        // device: sampled and written, and never read back, there being no
        // block of the format left to read.
        .etc2_r8g8b8_unorm_block, .etc2_r8g8b8a1_unorm_block, .etc2_r8g8b8a8_unorm_block, .eac_r11_unorm_block, .eac_r11g11_unorm_block => .{
            .linear_tiling_features = 0,
            .optimal_tiling_features = sampled | facet.FORMAT_FEATURE_TRANSFER_DST,
            .buffer_features = 0,
        },
        // Float: sampled, and written through by a function since 1.57
        // (`texture.Texture.setParts`), and read back as well where the
        // floats are kept, there being something of the format to read.
        // And a texel buffer of either since 1.68, read where it lies by
        // the same code a texture of the format is read with
        // (`shader.TexelFormat.rg11b10f`, `rgb9e5`).
        .b10g11r11_ufloat_pack32, .e5b9g9r9_ufloat_pack32 => .{
            .linear_tiling_features = 0,
            .optimal_tiling_features = sampled | storage | facet.FORMAT_FEATURE_TRANSFER_DST |
                if (keeps_blocks) facet.FORMAT_FEATURE_TRANSFER_SRC else 0,
            .buffer_features = texels,
        },
        // The same, and a texel buffer of half-floats as well since 1.54.
        .r16g16b16a16_sfloat => .{
            .linear_tiling_features = 0,
            .optimal_tiling_features = sampled | storage | facet.FORMAT_FEATURE_TRANSFER_DST |
                if (keeps_blocks) facet.FORMAT_FEATURE_TRANSFER_SRC else 0,
            .buffer_features = texels,
        },
        .r32g32b32a32_sfloat => .{
            .linear_tiling_features = 0,
            .optimal_tiling_features = sampled | storage | facet.FORMAT_FEATURE_TRANSFER_DST |
                if (keeps_blocks) facet.FORMAT_FEATURE_TRANSFER_SRC else 0,
            .buffer_features = vertices | texels,
        },
        // One float a texel as an image since 1.57, sampled as
        // (red, 0, 0, 1) and written through by a function
        // (`texture.Texture.setParts`): kept as the float where the
        // device keeps floats, and unpacked to 8888 where it does not.
        .r32_sfloat => .{
            .linear_tiling_features = 0,
            .optimal_tiling_features = sampled | storage | facet.FORMAT_FEATURE_TRANSFER_DST |
                if (keeps_blocks) facet.FORMAT_FEATURE_TRANSFER_SRC else 0,
            .buffer_features = vertices | texels,
        },
        .r32g32_sfloat, .r32g32b32_sfloat => .{ .linear_tiling_features = 0, .optimal_tiling_features = 0, .buffer_features = vertices | texels },
        // A texel buffer and nothing else, since 1.54: no image is kept
        // in these, and no vertex attribute is read in one. The grid is
        // one channel, two or four, of 8, 16 or 32 bits, as 0 to 1, as
        // whole numbers signed or not, or as a half-float.
        // A texture of its own channels since 1.69, where the device
        // keeps them: sampled as the colour of their top 8 bits, written
        // through by a function as the whole of them, and read back,
        // there being something of the format to read. A device that
        // keeps 8 bits a channel says nothing but the texel buffer here,
        // and CreateImage refuses such an image there.
        .r8g8_unorm, .r16_unorm, .r16g16_unorm, .r16g16b16a16_unorm => .{
            .linear_tiling_features = 0,
            .optimal_tiling_features = if (keeps_blocks) sampled | storage | transfer else 0,
            .buffer_features = texels,
        },
        // The whole numbers of 1.70, where the device keeps what it was
        // given: a texture a function reads with
        // `texture.Texture.wholesAt` and writes with `setWholes`, and
        // read back, there being something of the format to read. No
        // linear filter and never an attachment: a whole number is no
        // colour, and nothing blends one.
        .r8_uint,
        .r8g8_uint,
        .r8g8b8a8_uint,
        .r8_sint,
        .r8g8_sint,
        .r8g8b8a8_sint,
        .r16_uint,
        .r16g16_uint,
        .r16g16b16a16_uint,
        .r16_sint,
        .r16g16_sint,
        .r16g16b16a16_sint,
        .r32_uint,
        .r32g32_uint,
        .r32g32b32a32_uint,
        .r32_sint,
        .r32g32_sint,
        .r32g32b32a32_sint,
        => .{
            .linear_tiling_features = 0,
            .optimal_tiling_features = if (keeps_blocks) nearest | storage | transfer else 0,
            .buffer_features = texels,
        },
        .r16_sfloat,
        .r16g16_sfloat,
        // The rest of them since 1.68: `_snorm` read as -1 to 1, `_srgb`
        // read through the transfer function, the words whose channels
        // are packed into them, and three channels of 32 bits. An
        // `a8b8g8r8_..._pack32` word is where `r8g8b8a8_...` keeps its
        // bytes on a little-endian machine, so those two are the same
        // texels read twice over.
        .r8_snorm,
        .r8g8_snorm,
        .r8g8b8a8_snorm,
        .r16_snorm,
        .r16g16_snorm,
        .r16g16b16a16_snorm,
        .r8_srgb,
        .r8g8_srgb,
        .r8g8b8a8_srgb,
        .b8g8r8a8_srgb,
        .a8b8g8r8_unorm_pack32,
        .a8b8g8r8_srgb_pack32,
        .a2r10g10b10_unorm_pack32,
        .a2r10g10b10_uint_pack32,
        .a2b10g10r10_unorm_pack32,
        .a2b10g10r10_uint_pack32,
        .r32g32b32_uint,
        .r32g32b32_sint,
        => .{ .linear_tiling_features = 0, .optimal_tiling_features = 0, .buffer_features = texels },
        else => .{ .linear_tiling_features = 0, .optimal_tiling_features = 0, .buffer_features = 0 },
    };
}
