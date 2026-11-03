// SPDX-License-Identifier: MIT
//! What the drivers do with a format: all alike, what they draw into and read
//! being kept in the same formats.

const sdk = @import("sdk");
const facet = sdk.facet;

/// What `format` does on a device that unpacks a compressed image as it is
/// copied in: it can be written and sampled, and not read back.
pub fn properties(format: facet.Format) callconv(.c) facet.FormatProperties {
    return describe(format, false);
}

/// The same on a device that keeps a compressed image in its blocks
/// (`PhysicalDeviceFeatures.kept_compressed`): the blocks lie as they were
/// given, so a copy out of such an image reads them back as well.
pub fn keptProperties(format: facet.Format) callconv(.c) facet.FormatProperties {
    return describe(format, true);
}

fn describe(format: facet.Format, keeps_blocks: bool) facet.FormatProperties {
    const transfer = facet.FORMAT_FEATURE_TRANSFER_SRC | facet.FORMAT_FEATURE_TRANSFER_DST;
    const attachment = facet.FORMAT_FEATURE_COLOR_ATTACHMENT | facet.FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND;
    const sampled = facet.FORMAT_FEATURE_SAMPLED_IMAGE | facet.FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR | facet.FORMAT_FEATURE_TRANSFER_DST;
    // The formats a texture is kept in are the ones a function can write
    // through as well; the unpacked ones are not, being kept as 8888.
    const storage = facet.FORMAT_FEATURE_STORAGE_IMAGE;
    // A BufferView of these reads a buffer's bytes as texels, and a
    // storage one is written through as well (CreateBufferView).
    const texels = facet.FORMAT_FEATURE_UNIFORM_TEXEL_BUFFER | facet.FORMAT_FEATURE_STORAGE_TEXEL_BUFFER;
    const vertices = facet.FORMAT_FEATURE_VERTEX_BUFFER;
    return switch (format) {
        .b8g8r8a8_unorm, .r8g8b8a8_unorm => .{
            .linear_tiling_features = attachment | transfer,
            .optimal_tiling_features = attachment | transfer | sampled | storage,
            .buffer_features = vertices | texels,
        },
        .r5g6b5_unorm_pack16 => .{ .linear_tiling_features = attachment | transfer, .optimal_tiling_features = attachment | transfer | sampled | storage, .buffer_features = texels },
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
        .bc1_rgb_unorm_block, .bc1_rgba_unorm_block, .bc2_unorm_block, .bc3_unorm_block => .{
            .linear_tiling_features = 0,
            .optimal_tiling_features = sampled | facet.FORMAT_FEATURE_TRANSFER_DST |
                if (keeps_blocks) facet.FORMAT_FEATURE_TRANSFER_SRC else 0,
            .buffer_features = 0,
        },
        .r16g16b16a16_sfloat, .b10g11r11_ufloat_pack32, .e5b9g9r9_ufloat_pack32 => .{
            .linear_tiling_features = 0,
            .optimal_tiling_features = sampled | facet.FORMAT_FEATURE_TRANSFER_DST,
            .buffer_features = 0,
        },
        .r32g32b32a32_sfloat => .{
            .linear_tiling_features = 0,
            .optimal_tiling_features = sampled | facet.FORMAT_FEATURE_TRANSFER_DST,
            .buffer_features = vertices | texels,
        },
        .r32_sfloat, .r32g32_sfloat, .r32g32b32_sfloat => .{ .linear_tiling_features = 0, .optimal_tiling_features = 0, .buffer_features = vertices | texels },
        else => .{ .linear_tiling_features = 0, .optimal_tiling_features = 0, .buffer_features = 0 },
    };
}
