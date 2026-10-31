// SPDX-License-Identifier: MIT
//! What the drivers do with a format: all alike, what they draw into and read
//! being kept in the same formats.

const sdk = @import("sdk");
const facet = sdk.facet;

/// What `format` does.
pub fn properties(format: facet.Format) callconv(.c) facet.FormatProperties {
    const transfer = facet.FORMAT_FEATURE_TRANSFER_SRC | facet.FORMAT_FEATURE_TRANSFER_DST;
    const attachment = facet.FORMAT_FEATURE_COLOR_ATTACHMENT | facet.FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND;
    const sampled = facet.FORMAT_FEATURE_SAMPLED_IMAGE | facet.FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR | facet.FORMAT_FEATURE_TRANSFER_DST;
    return switch (format) {
        .b8g8r8a8_unorm, .r8g8b8a8_unorm => .{
            .linear_tiling_features = attachment | transfer,
            .optimal_tiling_features = attachment | transfer | sampled,
            .buffer_features = facet.FORMAT_FEATURE_VERTEX_BUFFER,
        },
        .r5g6b5_unorm_pack16 => .{ .linear_tiling_features = attachment | transfer, .optimal_tiling_features = attachment | transfer | sampled, .buffer_features = 0 },
        .d16_unorm, .s8_uint, .d16_unorm_s8_uint => .{ .linear_tiling_features = 0, .optimal_tiling_features = facet.FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT, .buffer_features = 0 },
        .bc1_rgb_unorm_block, .bc1_rgba_unorm_block, .bc2_unorm_block, .bc3_unorm_block, .r16g16b16a16_sfloat, .b10g11r11_ufloat_pack32, .e5b9g9r9_ufloat_pack32 => .{
            .linear_tiling_features = 0,
            .optimal_tiling_features = sampled | facet.FORMAT_FEATURE_TRANSFER_DST,
            .buffer_features = 0,
        },
        .r32g32b32a32_sfloat => .{
            .linear_tiling_features = 0,
            .optimal_tiling_features = sampled | facet.FORMAT_FEATURE_TRANSFER_DST,
            .buffer_features = facet.FORMAT_FEATURE_VERTEX_BUFFER,
        },
        .r32_sfloat, .r32g32_sfloat, .r32g32b32_sfloat => .{ .linear_tiling_features = 0, .optimal_tiling_features = 0, .buffer_features = facet.FORMAT_FEATURE_VERTEX_BUFFER },
        else => .{ .linear_tiling_features = 0, .optimal_tiling_features = 0, .buffer_features = 0 },
    };
}
