// SPDX-License-Identifier: MIT
//! What the drivers do with a format: all alike, what they draw into and read
//! being kept in the same formats. What differs between two devices of one
//! machine is what each keeps as it was given it and what it samples, which
//! its own capabilities say, so there is one answer here, read off those
//! (since 1.80; `_instance.Capabilities` rather than the public features
//! structure since 1.82, the public one being Vulkan's own now).

const sdk = @import("sdk");
const facet = sdk.facet;
const _instance = @import("../instance/_instance.zig");
const PhysicalDevice = _instance.PhysicalDevice;

/// What `format` does on `physical`, whose driver has described it: both
/// drivers point at this, the features the device said it has deciding
/// every answer that differs between two of them.
///
/// A device that keeps what it was given - a compressed image in its
/// blocks, a float one in its floats, a texture's own channels or its whole
/// numbers as they lie (`Capabilities.kept_compressed`,
/// `kept_floats`, `wide_channels`, `whole_textures`) - says so of those
/// formats, and a copy out of such an image reads them back as well. One
/// that unpacks them into 8 bits a channel as they are copied in says
/// nothing of the formats it keeps none of, which is what CreateImage
/// refuses there. And a depth image is sampled where its rows lie only on a
/// device with `sampled_depth`, for the same reason.
///
/// Until 1.80 this was a function of the format alone, with one bool
/// standing in for the four kept features and nothing at all for
/// `sampled_depth`: D16_UNORM was answered for as sampled and filtered on
/// every device, which contradicted the CreateImage that refuses a sampled
/// depth image where the feature is false.
pub fn properties(physical: *const PhysicalDevice, format: facet.Format) callconv(.c) facet.FormatProperties {
    return describe(&physical.can, format);
}

fn describe(can: *const _instance.Capabilities, format: facet.Format) facet.FormatProperties {
    const transfer = facet.FORMAT_FEATURE_TRANSFER_SRC | facet.FORMAT_FEATURE_TRANSFER_DST;
    // A colour attachment is a blit's destination as well, in either
    // tiling (since 1.126): v3dv sets BLIT_DST with COLOR_ATTACHMENT
    // (`image_format_plane_features`, src/broadcom/vulkan/
    // v3dv_formats.c:176-179), and lavapipe sets the two blit bits in both
    // tilings (lvp_formats.c:214-223, :233-234). The blit writes each of
    // these where it lies, in rows or a texture (`_transfer.blitImage`).
    const attachment = facet.FORMAT_FEATURE_COLOR_ATTACHMENT | facet.FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND | facet.FORMAT_FEATURE_BLIT_DST;
    // And a format sampled in optimal tiling is a blit's source there
    // (since 1.126), as v3dv sets BLIT_SRC with SAMPLED_IMAGE in that
    // tiling alone (v3dv_formats.c:169-173): the blit reads such a texel as
    // the colour a sample reads, out of rows, a texture, its blocks or its
    // floats (`_transfer.colorAt`).
    const sampled = facet.FORMAT_FEATURE_SAMPLED_IMAGE | facet.FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR | facet.FORMAT_FEATURE_TRANSFER_DST | facet.FORMAT_FEATURE_BLIT_SRC;
    // A format of whole numbers is sampled without the linear filter:
    // Vulkan has no integer format filtered, there being nothing to mix
    // between two whole numbers (since 1.70). Nor is it a blit's source: a
    // blit carries a colour of 8 bits a channel, which a whole number is
    // not, and Vulkan blits one into another of whole numbers alone
    // (VUID-vkCmdBlitImage-srcImage-00229, -00230), none of which is a
    // blit's destination here.
    const nearest = facet.FORMAT_FEATURE_SAMPLED_IMAGE | facet.FORMAT_FEATURE_TRANSFER_DST;
    // The formats a texture is kept in are the ones a function can write
    // through as well; the unpacked ones are not, being kept as 8888.
    const storage = facet.FORMAT_FEATURE_STORAGE_IMAGE;
    // What a depth image adds on a device that samples one where its rows
    // lie (`Capabilities.sampled_depth`).
    const depth_sampled = facet.FORMAT_FEATURE_SAMPLED_IMAGE | facet.FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR;
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
        // Rows of this one are not written through: the texture that
        // reads a word with red in its low byte (`texture.Format.rgba8`,
        // since 1.110) is fetched from, not written through. Its texels,
        // kept in a texture's own layout, are.
        .r8g8b8a8_unorm => .{
            .linear_tiling_features = attachment | transfer,
            .optimal_tiling_features = attachment | transfer | sampled | storage,
            .buffer_features = vertices | texels,
        },
        .r5g6b5_unorm_pack16 => .{ .linear_tiling_features = attachment | transfer | storage, .optimal_tiling_features = attachment | transfer | sampled | storage, .buffer_features = texels },
        // One byte of red a texel, sampled and written through, and never
        // an attachment: a texture of one channel, read as (red, 0, 0, 1)
        // (`Capabilities.small_texels`, since 1.48). A device
        // without that feature refuses such an image all the same.
        // A blit's destination as well since 1.126, its byte of red
        // written as a colour's is: Mesa's two drivers have R8_UNORM one,
        // it being an attachment there (v3dv_formats.c:176-179,
        // lvp_formats.c:214-223).
        .r8_unorm => .{
            .linear_tiling_features = 0,
            .optimal_tiling_features = transfer | sampled | storage | facet.FORMAT_FEATURE_BLIT_DST,
            // And a texel buffer of one byte a texel, since 1.54.
            .buffer_features = texels,
        },
        // A depth attachment, and since 1.30 a transfer as well: a pass
        // that stores its depth writes the image's rows, and a copy reads
        // them (`Capabilities.stored_depth`).
        // Sampled as well since 1.39, where the device has it
        // (`Capabilities.sampled_depth`): a shadow map drawn
        // into and sampled out of without a copy. Where it has not, the
        // sampled bits are left out, as they have been since 1.80: a
        // device whose texture unit knows no depth format refuses such an
        // image at CreateImage, and this said otherwise.
        //
        // Blitted both ways since 1.126, into an image of its own format
        // and without a filter, as Vulkan blits a depth
        // (VUID-vkCmdBlitImage-srcImage-00231, -00232): each pixel takes
        // the nearest one's depth as it lies in the rows. The processor
        // blits for either device, so this is not held to the sampling as
        // v3dv's BLIT_SRC is (v3dv_formats.c:169-182); lavapipe has a depth
        // format blitted both ways (lvp_formats.c:93-104).
        .d16_unorm => .{
            .linear_tiling_features = 0,
            .optimal_tiling_features = facet.FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT | transfer |
                facet.FORMAT_FEATURE_BLIT_SRC | facet.FORMAT_FEATURE_BLIT_DST |
                if (can.sampled_depth) depth_sampled else 0,
            .buffer_features = 0,
        },
        // Since 1.38 these two keep their stencil the same way, each
        // pixel's depth and stencil beside each other in the rows
        // (`Capabilities.stored_stencil`), and a copy reads or
        // writes both at once, 1 byte a pixel or 4.
        //
        // Since 1.80 each says it is an attachment only where the device
        // stores one: a stencil alone wants `stored_stencil`, and a format
        // of both planes `stored_both`, which is what CreateRenderPass
        // holds an attachment to. The V3D stores a stencil and not both,
        // and this promised an attachment of both there that a pass then
        // refused. A copy stands either way: a transfer reads and writes
        // the rows whatever a pass can do with them.
        .s8_uint => .{
            .linear_tiling_features = 0,
            .optimal_tiling_features = transfer |
                if (can.stored_stencil) facet.FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT else 0,
            .buffer_features = 0,
        },
        .d16_unorm_s8_uint => .{
            .linear_tiling_features = 0,
            .optimal_tiling_features = transfer |
                if (can.stored_both) facet.FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT else 0,
            .buffer_features = 0,
        },
        // Compressed: sampled and written, and read back as well where the
        // blocks are kept, there being something of the format to read.
        .bc1_rgb_unorm_block, .bc1_rgba_unorm_block, .bc2_unorm_block, .bc3_unorm_block, .bc4_unorm_block, .bc5_unorm_block, .bc7_unorm_block, .bc6h_ufloat_block, .bc6h_sfloat_block => .{
            .linear_tiling_features = 0,
            .optimal_tiling_features = sampled | facet.FORMAT_FEATURE_TRANSFER_DST |
                if (can.kept_compressed) facet.FORMAT_FEATURE_TRANSFER_SRC else 0,
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
        // Four channels in 16 bits (since 1.127), unpacked the same way on
        // every device: sampled, filtered, copied into and a blit's
        // source, and never read back. v3dv samples both where they lie,
        // its texture unit reading the words (v3dvx_formats.c:187, :190),
        // which no sampler of this library does; A1R5G5B5's attachment
        // half is to come with the other colour attachments.
        .b4g4r4a4_unorm_pack16, .a1r5g5b5_unorm_pack16 => .{
            .linear_tiling_features = 0,
            .optimal_tiling_features = sampled,
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
                if (can.kept_floats) facet.FORMAT_FEATURE_TRANSFER_SRC else 0,
            .buffer_features = texels,
        },
        // The same, and a texel buffer of half-floats as well since 1.54.
        .r16g16b16a16_sfloat => .{
            .linear_tiling_features = 0,
            .optimal_tiling_features = sampled | storage | facet.FORMAT_FEATURE_TRANSFER_DST |
                if (can.kept_floats) facet.FORMAT_FEATURE_TRANSFER_SRC else 0,
            .buffer_features = texels,
        },
        .r32g32b32a32_sfloat => .{
            .linear_tiling_features = 0,
            .optimal_tiling_features = sampled | storage | facet.FORMAT_FEATURE_TRANSFER_DST |
                if (can.kept_floats) facet.FORMAT_FEATURE_TRANSFER_SRC else 0,
            .buffer_features = vertices | texels,
        },
        // One float a texel as an image since 1.57, sampled as
        // (red, 0, 0, 1) and written through by a function
        // (`texture.Texture.setParts`): kept as the float where the
        // device keeps floats, and unpacked to 8888 where it does not.
        .r32_sfloat => .{
            .linear_tiling_features = 0,
            .optimal_tiling_features = sampled | storage | facet.FORMAT_FEATURE_TRANSFER_DST |
                if (can.kept_floats) facet.FORMAT_FEATURE_TRANSFER_SRC else 0,
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
            .optimal_tiling_features = if (can.wide_channels) sampled | storage | transfer else 0,
            .buffer_features = texels,
        },
        // The whole numbers of 1.70, where the device keeps what it was
        // given: a texture a function reads with
        // `texture.Texture.wholesAt` and writes with `setWholes`, and
        // read back, there being something of the format to read. No
        // linear filter and never an attachment: a whole number is no
        // colour, and nothing blends one. The A8B8G8R8 words of the 8-bit
        // four are the same bytes, and so the same texels (since 1.127).
        .r8_uint,
        .r8g8_uint,
        .r8g8b8a8_uint,
        .r8_sint,
        .r8g8_sint,
        .r8g8b8a8_sint,
        .a8b8g8r8_uint_pack32,
        .a8b8g8r8_sint_pack32,
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
            .optimal_tiling_features = if (can.whole_textures) nearest | storage | transfer else 0,
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
        .a8b8g8r8_snorm_pack32,
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

const std = @import("std");
const testing = std.testing;

/// A device that keeps nothing it was given and samples no depth: what the
/// V3D says of itself for the features read here.
const unpacking = _instance.Capabilities{
    .kept_compressed = false,
    .kept_floats = false,
    .wide_channels = false,
    .whole_textures = false,
    .sampled_depth = false,
    .stored_stencil = true,
    .stored_both = false,
};

/// One that keeps all of it and samples a depth where its rows lie: the
/// cores.
const keeping = _instance.Capabilities{
    .kept_compressed = true,
    .kept_floats = true,
    .wide_channels = true,
    .whole_textures = true,
    .sampled_depth = true,
    .stored_stencil = true,
    .stored_both = true,
};

test "a depth format says it is sampled only where the device samples one" {
    const sampled = facet.FORMAT_FEATURE_SAMPLED_IMAGE | facet.FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR;

    // The cores sample a depth image where its rows lie, so D16_UNORM says
    // so; the V3D's texture unit knows no depth format and CreateImage
    // refuses such an image there, so it says nothing of sampling. Before
    // 1.80 both answered alike and the V3D's answer was a promise it broke.
    const on_cores = describe(&keeping, .d16_unorm);
    const on_v3d = describe(&unpacking, .d16_unorm);
    try testing.expectEqual(sampled, on_cores.optimal_tiling_features & sampled);
    try testing.expectEqual(@as(u32, 0), on_v3d.optimal_tiling_features & sampled);

    // A depth attachment either way, and copied either way: what differs is
    // the sampling alone.
    const attachment = facet.FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT | facet.FORMAT_FEATURE_TRANSFER_SRC | facet.FORMAT_FEATURE_TRANSFER_DST;
    try testing.expectEqual(attachment, on_cores.optimal_tiling_features & attachment);
    try testing.expectEqual(attachment, on_v3d.optimal_tiling_features & attachment);

    // Nothing is in linear tiling or in a buffer for a depth format.
    try testing.expectEqual(@as(u32, 0), on_v3d.linear_tiling_features);
    try testing.expectEqual(@as(u32, 0), on_v3d.buffer_features);
}

test "a stencil format says it is an attachment only where the device stores that plane" {
    const attachment = facet.FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT;

    // The V3D stores a stencil alone and not a pixel's depth and stencil
    // together (`stored_both`), which is what CreateRenderPass holds an
    // attachment of `d16_unorm_s8_uint` to: so it says the one and not the
    // other. Both said attachment before 1.80, and a pass refused the one.
    try testing.expectEqual(attachment, describe(&unpacking, .s8_uint).optimal_tiling_features & attachment);
    try testing.expectEqual(@as(u32, 0), describe(&unpacking, .d16_unorm_s8_uint).optimal_tiling_features & attachment);
    try testing.expectEqual(attachment, describe(&keeping, .s8_uint).optimal_tiling_features & attachment);
    try testing.expectEqual(attachment, describe(&keeping, .d16_unorm_s8_uint).optimal_tiling_features & attachment);

    // Copied either way, a transfer reading the rows whatever a pass can do
    // with them.
    const copied = facet.FORMAT_FEATURE_TRANSFER_SRC | facet.FORMAT_FEATURE_TRANSFER_DST;
    try testing.expectEqual(copied, describe(&unpacking, .d16_unorm_s8_uint).optimal_tiling_features & copied);
}

test "each of the four kept features answers for its own formats" {
    // A device that unpacks an image as it is copied in cannot be copied out
    // of; one that keeps the blocks or the floats can. Each format reads the
    // feature for what it is kept as, where one bool stood for all four
    // before 1.80.
    const src = facet.FORMAT_FEATURE_TRANSFER_SRC;
    try testing.expectEqual(@as(u32, 0), describe(&unpacking, .bc1_rgb_unorm_block).optimal_tiling_features & src);
    try testing.expectEqual(src, describe(&keeping, .bc1_rgb_unorm_block).optimal_tiling_features & src);
    try testing.expectEqual(@as(u32, 0), describe(&unpacking, .r16g16b16a16_sfloat).optimal_tiling_features & src);
    try testing.expectEqual(src, describe(&keeping, .r16g16b16a16_sfloat).optimal_tiling_features & src);

    // A texture's own channels and its whole numbers are not an image at all
    // on a device that keeps neither, which is the CreateImage there.
    try testing.expectEqual(@as(u32, 0), describe(&unpacking, .r16g16_unorm).optimal_tiling_features);
    try testing.expect(describe(&keeping, .r16g16_unorm).optimal_tiling_features != 0);
    try testing.expectEqual(@as(u32, 0), describe(&unpacking, .r8g8b8a8_uint).optimal_tiling_features);
    try testing.expect(describe(&keeping, .r8g8b8a8_uint).optimal_tiling_features != 0);

    // A buffer's texels are the same on either: the bytes are read as they
    // lie, with no image to keep.
    try testing.expectEqual(describe(&keeping, .r16g16_unorm).buffer_features, describe(&unpacking, .r16g16_unorm).buffer_features);
}

test "an A8B8G8R8 word says what its R8G8B8A8 form says, on either device" {
    // The same bytes on a little-endian machine, so the same texels: v3dv
    // gives each pair the one texture type (src/broadcom/vulkan/
    // v3dvx_formats.c:132-134, :192-194). Since 1.127, where the three
    // were not formats of this library at all.
    const pairs = [_][2]facet.Format{
        .{ .a8b8g8r8_snorm_pack32, .r8g8b8a8_snorm },
        .{ .a8b8g8r8_uint_pack32, .r8g8b8a8_uint },
        .{ .a8b8g8r8_sint_pack32, .r8g8b8a8_sint },
    };
    for ([2]*const _instance.Capabilities{ &keeping, &unpacking }) |can| for (pairs) |pair| {
        try testing.expectEqual(describe(can, pair[1]), describe(can, pair[0]));
    };
    // A texel buffer of each on either device, and an image of the whole
    // numbers where the device keeps them.
    try testing.expect(describe(&keeping, .a8b8g8r8_uint_pack32).optimal_tiling_features != 0);
    try testing.expectEqual(@as(u32, 0), describe(&unpacking, .a8b8g8r8_sint_pack32).optimal_tiling_features);
    try testing.expect(describe(&unpacking, .a8b8g8r8_snorm_pack32).buffer_features != 0);
}

test "four channels in 16 bits are sampled and blitted out of on either device, and never read back" {
    // Unpacked into 8 bits a channel as they are copied in, as ETC2 is,
    // whatever the device keeps: the three features Vulkan asks of
    // B4G4R4A4 and of A1R5G5B5's sampled half, and a copy into them.
    // Since 1.127.
    const want = facet.FORMAT_FEATURE_SAMPLED_IMAGE | facet.FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR |
        facet.FORMAT_FEATURE_BLIT_SRC | facet.FORMAT_FEATURE_TRANSFER_DST;
    for ([2]*const _instance.Capabilities{ &keeping, &unpacking }) |can| for ([2]facet.Format{ .b4g4r4a4_unorm_pack16, .a1r5g5b5_unorm_pack16 }) |format| {
        const said = describe(can, format);
        try testing.expectEqual(want, said.optimal_tiling_features);
        try testing.expectEqual(@as(u32, 0), said.linear_tiling_features | said.buffer_features);
    };
}

// The one format whose four features a single bool used to stand for is
// not the only one a device differs on, so each is read where it belongs:
// a device that keeps nothing says nothing of an image it cannot keep.
test "one bool could not have answered for all of them" {
    // Had `kept_floats` stood in for `wide_channels` as well, these two
    // would move together; they do not.
    const halved = _instance.Capabilities{ .kept_floats = true, .wide_channels = false, .stored_stencil = true };
    try testing.expect(describe(&halved, .r16g16b16a16_sfloat).optimal_tiling_features & facet.FORMAT_FEATURE_TRANSFER_SRC != 0);
    try testing.expectEqual(@as(u32, 0), describe(&halved, .r16g16_unorm).optimal_tiling_features);
}
