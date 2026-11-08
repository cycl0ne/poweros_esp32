// SPDX-License-Identifier: MIT
//! CreateImageView: an image as a pipeline or a framebuffer sees it.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _image = @import("_image.zig");
const Image = _image.Image;
const ImageView = _image.ImageView;
const texture = facet.texture;

/// A view of an image: the levels of it a texture descriptor samples, or
/// what a framebuffer draws into.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateImageView(base: *FacetBase, device: *facet.Device, info: *const facet.ImageViewCreateInfo, view: *?*facet.ImageView) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -112.
///
/// INPUTS:
/// - `device` - the device the image was made on.
/// - `info` - the image, bound already, its own format - or another Vulkan
///   has compatible with it, where the image was made
///   IMAGE_CREATE_MUTABLE_FORMAT (since 1.131) - and the levels the view
///   takes.
/// - `view` - where the view is written; null when it fails.
///
/// RESULT:
/// `success`; `error_validation_failed` for a view Vulkan's rules forbid
/// (since 1.135; `error_format_not_supported` until then): of another
/// format than the image's where the image was not made
/// IMAGE_CREATE_MUTABLE_FORMAT (VUID-VkImageViewCreateInfo-image-12397),
/// of one not compatible with it (-image-01761), or of one whose features
/// do not do what the image is for (-None-02273, -usage-02274,
/// -usage-02275, -usage-08931, -usage-02277, -usage-08932), CreateImage
/// making no image of the flag that a view Vulkan allows would be refused
/// of; of an image made for no view, which Vulkan has take none
/// (-image-04441), of another format its texels are not read in where
/// they lie, its other views being made (`_image.takesView`); with a
/// swizzle that is none of Vulkan's seven values
/// (VUID-VkComponentMapping-r-parameter and the other three); of a type
/// that is none of Vulkan's or that the image does not take, or of layers
/// that type does not take (-viewType-parameter, -subResourceRange-01021,
/// -image-01003, -image-06723, -image-06728, -viewType-01004,
/// -imageViewType-04973, -imageViewType-04974, -viewType-02960 to
/// -viewType-02963); of levels or layers the image has not got, or of none
/// (-subresourceRange-01478, -subresourceRange-01718, -image-06724,
/// -subresourceRange-06725, VUID-VkImageSubresourceRange-levelCount-01720,
/// -layerCount-01721); of an aspect its format has not got - a plane of a
/// depth format it has not, or a depth or a stencil of a colour format
/// (-subresourceRange-09594); or of an image not yet bound into memory
/// (-image-01020); `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// A view of a texture samples its levels from `base_mip_level` on, as a
/// texture of its own whose first level is that one. So, since 1.119, does
/// a view of an attachment drawn into and sampled at once, which is kept
/// in rows: it reads the rows a pass drew into, at the levels and the
/// layers it names. A framebuffer given a view of any image kept in rows
/// draws into the level the view begins at, an image kept in rows having
/// levels since 1.119.
///
/// **It may be of another format than the image's** since 1.131, where
/// the image was made IMAGE_CREATE_MUTABLE_FORMAT: one Vulkan has
/// compatible with the image's own - the same bytes a texel, or a
/// compressed format's block - which reads the same texels at the same
/// places its own way, as Vulkan has it ("the same mapping between texel
/// coordinates and memory locations irrespective of the format, with only
/// the interpretation of the bit pattern changing"). Such an image keeps
/// its texels as they lie, so a view of R32_UINT of an R8G8B8A8_UNORM
/// image reads each texel's four bytes as one whole number, and one of
/// B8G8R8A8_UNORM reads them with red and blue the other way round. A
/// texture's view reads them in the texture's layout, a view of an image
/// sampled where its rows lie reads the rows, and a framebuffer given
/// such a view draws into the rows in the view's format, which is the
/// one its render pass names. That is lavapipe's view: the view's format
/// handed to the sampler view, the image view and the surface of the one
/// resource (`lvp_CreateImageView`, src/gallium/frontends/lavapipe/
/// lvp_image.c:483; `add_img_view_surface`, lvp_execute.c:1520-1525).
///
/// **Its channels may be swizzled** since 1.120, as Vulkan's
/// `VkComponentMapping` has them: each of `components` names the channel of
/// the texel it reads, its own (`identity`), or 0 or 1. Every read of the
/// view's texels is swizzled - a sample through a sampler or by a fixed
/// form, `colorAt`, `partsAt` and `wholesAt` - and so are the border and
/// what a comparison gave, Vulkan replacing a texel and comparing a depth
/// before it swizzles (`texture.Swizzle`). A channel the format has not got
/// reads 0, or 1 for an alpha, before the swizzle: an R8 view may read its
/// alpha as its red, and reads 1. A depth or a stencil reads (D, 0, 0, 1),
/// as Vulkan converts such a texel, before the swizzle: a swizzle takes 0
/// from its green and its blue and 1 from its alpha (since 1.121 whatever
/// the view's swizzle, since 1.120 where it swizzles). A fixed form
/// compiled for the view's format draws one that swizzles through the
/// run-time sampler, a pixel at a time. A framebuffer takes no view that
/// swizzles, and neither a storage image nor an input attachment may be
/// one, as Vulkan has it (VUID-VkWriteDescriptorSet-descriptorType-00336).
/// On the V3D the TMU swizzles, the view's over the format's own.
///
/// Of type `2d` it is one layer, of a texture with any number of them. Of type
/// `2d_array` it is the layers asked for, for `shader.FixedKind.texture_array`;
/// `cube` is 6 layers of an image made IMAGE_CREATE_CUBE_COMPATIBLE, for
/// `texture_cube`, and `3d` the whole of a 3D image, for `texture_3d`: the
/// one layer Vulkan has such an image have, `layer_count` 1 or REMAINING,
/// which holds every slice. From `base_mip_level` on it reads the slices
/// of the levels it begins at, each level half as deep as the one before
/// (`texture.Texture.slicesAt`). Both since 1.135: a `layer_count` of 1
/// was refused before and one of the whole depth taken, and a view from a
/// level past the first read the whole depth's slices at it, which that
/// level has not got.
///
/// Of type `cube_array` it is as many cubes as its layers divided by six, of
/// such an image, for `texture_cube_array` and, since 1.53,
/// `texture_cube_array_sampled`: its layers are a multiple of six, and its
/// first is the first face of its first cube whatever layer of the image
/// that is, as Vulkan counts a cube array's faces from `baseArrayLayer`
/// (since 1.135; a multiple of six before) (`Capabilities.cube_arrays`,
/// since 1.46).
///
/// **A view of a sampled depth image takes one of its planes** since 1.58
/// (`Capabilities.sampled_depth`): IMAGE_ASPECT_DEPTH is the
/// depth, read at all 16 bits by a sampler that compares and as a grey of
/// its top 8 by one that does not, and IMAGE_ASPECT_STENCIL is the
/// stencil, read as (red, 0, 0, 1) the way a texel of one byte is. A
/// plane the format has not got is `error_validation_failed` (since 1.135,
/// `error_format_not_supported` before); an
/// aspect naming neither - IMAGE_ASPECT_COLOR, the default, and what every
/// such view asked for before 1.58 - is the format's own plane, its depth
/// where it has one and its stencil where it has not. The plane is a
/// texture over the image's own rows, so a format holding both is two
/// textures inside the same rows, read four bytes apart. Since 1.63 it is
/// the levels the view names as well, each in rows of its own: a sample
/// of such a view reads the level it chooses, as it does of any texture.
///
/// **Both aspects at once**, of a format holding both, is a view since
/// 1.94 and was refused before. It is what a framebuffer is given for a
/// pass's depth/stencil attachment, which draws into both planes whatever
/// the view names, as Vulkan has it. No descriptor may hold such a view,
/// Vulkan having a descriptor's view of a depth/stencil image name one
/// aspect, so its texture is only what a sample would read regardless:
/// the depth, as lavapipe's is (`lvp_create_samplerview` takes the stencil
/// for the stencil alone).
///
/// Since 1.62 the same plane is what a later subpass reads as an **input
/// attachment** (`shader.Attachment`), where the image was made one
/// (IMAGE_USAGE_INPUT_ATTACHMENT): the view's first layer, the depth as
/// `r16`, 0 to 1 and nearest first, and the stencil as `r8u`, the whole
/// number it is. A format holding both is read four bytes from one pixel
/// to the next, the view's aspect saying which plane this is.
///
/// Such a view is of the layers it names as well, of type `2d` or
/// `2d_array`: the image's own rows for that layer, which is what a pass
/// drawing into the view writes and what a sample of it reads. So the
/// layers of one image are the shadow maps of several lights, each drawn
/// into through a framebuffer with a view of that layer.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The view is the caller's, until DestroyImageView, which comes before
/// the image's DestroyImage.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DestroyImageView`, `CreateImage`, `CreateFramebuffer`
///
/// EXAMPLES:
/// ```zig
/// var view: ?*facet.ImageView = null;
/// const info = facet.ImageViewCreateInfo{ .image = picture.?, .format = .b8g8r8a8_unorm };
/// if (fb.CreateImageView(device, &info, &view) != .success) return error.NoView;
/// ```
pub fn CreateImageView(base: *FacetBase, device: *facet.Device, info: *const facet.ImageViewCreateInfo, view: *?*facet.ImageView) facet.Result {
    _ = device;
    view.* = null;
    const image = _objects.of(Image, info.image);
    // The image's own format, or since 1.131 another of the same bytes
    // read its own way, where the image was made for that
    // (`_image.takesView`). Any other breaks one of Vulkan's rules (since
    // 1.135): another format of an image not made
    // IMAGE_CREATE_MUTABLE_FORMAT (VUID-VkImageViewCreateInfo-image-12397),
    // or of one made for no view at all - none of SAMPLED, STORAGE or an
    // attachment's usage, whose formats `_image.shapeFor` does not look at
    // (-image-04441) - one not compatible with the image's (-image-01761),
    // or one whose features do not do what the image is for (-None-02273,
    // -usage-02274, -usage-02275, -usage-08931, -usage-02277,
    // -usage-08932). No view Vulkan allows is refused here: CreateImage
    // makes no image of the flag that one would be refused of
    // (`_image.shapeFor`).
    if (!_image.takesView(&image.device.physical.can, image, info.format)) return .error_validation_failed;
    // A value that is none of VkComponentSwizzle's seven
    // (VUID-VkComponentMapping-r-parameter and the other three); each of
    // the seven is taken, in any channel, since 1.120.
    const swizzle = swizzleOf(info.components) orelse return .error_validation_failed;
    const range = info.subresource_range;
    // The layers Vulkan has the image made with: a 3D image's one
    // (VUID-VkImageCreateInfo-imageType-00961), its depth being the slices
    // this library keeps as its layers (`Image.layers`). Until 1.135 the
    // depth was taken for them, so a 3D view of one layer was refused and
    // one of as many as the depth taken.
    const array_layers: u32 = if (image.volume) 1 else image.layers;
    // A first level or layer the image has not got, no layers, or more of
    // them than it has from the first on
    // (VUID-VkImageViewCreateInfo-subresourceRange-01478, -image-06724,
    // VUID-VkImageSubresourceRange-layerCount-01721,
    // VUID-VkImageViewCreateInfo-subresourceRange-06725).
    if (range.base_mip_level >= image.levels or range.base_array_layer >= array_layers) return .error_validation_failed;
    const layers = if (range.layer_count == facet.REMAINING) array_layers - range.base_array_layer else range.layer_count;
    if (layers == 0 or layers > array_layers - range.base_array_layer) return .error_validation_failed;
    switch (info.view_type) {
        // A type the image's own takes
        // (VUID-VkImageViewCreateInfo-subResourceRange-01021): a 1D image
        // takes the 1D view types and no other, and a 2D image a row high
        // is not one - the two are different kinds of image to Vulkan
        // however alike their texels lie (since 1.86). A 1D, a 2D or a 3D
        // view is of one layer (-imageViewType-04973, -imageViewType-04974).
        .@"1d" => if (layers != 1 or !image.line) return .error_validation_failed,
        .@"1d_array" => if (!image.line) return .error_validation_failed,
        // A 3D image takes neither 2D type on a 1.0 device, which has no
        // IMAGE_CREATE_2D_ARRAY_COMPATIBLE (-image-06728, -image-06723).
        .@"2d" => if (layers != 1 or image.volume or image.line) return .error_validation_failed,
        .@"2d_array" => if (image.volume or image.line) return .error_validation_failed,
        // Six layers, from any layer, of an image made CUBE_COMPATIBLE
        // (-image-01003, -viewType-02960, -viewType-02962).
        .cube => if (!image.cube or layers != 6) return .error_validation_failed,
        // Cubes one after another, six layers to each (since 1.46), on a
        // device that has imageCubeArray (-viewType-01004; the V3D has
        // not): of an image made CUBE_COMPATIBLE, a multiple of six layers
        // of it (-viewType-02961, -viewType-02963). Its first layer is the
        // first face of its first cube whatever layer of the image that
        // is, as Vulkan counts a cube array's faces from `baseArrayLayer`
        // and the view's texture begins there (`_image.levelsFrom`); until
        // 1.135 it had to be a multiple of six.
        .cube_array => if (!image.device.physical.can.cube_arrays or !image.cube or layers % 6 != 0) return .error_validation_failed,
        // Of a 3D image, its one layer, which the checks above hold it to.
        .@"3d" => if (!image.volume) return .error_validation_failed,
        // None of Vulkan's (-viewType-parameter).
        else => return .error_validation_failed,
    }
    // Its levels the same way (VUID-VkImageSubresourceRange-levelCount-01720,
    // VUID-VkImageViewCreateInfo-subresourceRange-01718).
    const count = if (range.level_count == facet.REMAINING) image.levels - range.base_mip_level else range.level_count;
    if (count == 0 or count > image.levels - range.base_mip_level) return .error_validation_failed;
    // Not yet bound into memory (VUID-VkImageViewCreateInfo-image-01020):
    // BindImageMemory sets `memory` for every type, the lazily allocated
    // one too, whose blocks have no bytes behind them, and a swapchain's
    // image is the swapchain's, no program's to bind. Until 1.135 a depth
    // image's binding was looked at only where the view reads it.
    if (image.memory == null and !image.presentable) return .error_validation_failed;
    // An aspect the format has not got
    // (VUID-VkImageViewCreateInfo-subresourceRange-09594): a plane of a
    // depth format it has not, IMAGE_ASPECT_COLOR being the format's own
    // plane (BEHAVIOR), and a depth or a stencil of a colour format. Until
    // 1.135 a depth image's aspect was looked at only where the view reads
    // it, and a colour image's not at all.
    if (image.kind == .depth and !_image.hasPlane(image, range.aspect_mask)) return .error_validation_failed;
    if (image.kind != .depth and range.aspect_mask & (facet.IMAGE_ASPECT_DEPTH | facet.IMAGE_ASPECT_STENCIL) != 0) return .error_validation_failed;
    // A depth attachment sampled where it lies: the plane the view's
    // aspect names, of the layers it names (since 1.58). Both planes at
    // once is the depth (since 1.94), and an aspect naming neither is the
    // format's own plane. Neither this nor the rows below is without a
    // plane or bytes to be over: an aspect the format has not got is
    // refused above, and so is an image never bound, while a depth image
    // sampled or read as an input attachment is offered no lazily
    // allocated type (`_image.requirements`) and so has bytes behind it
    // once bound. Until 1.135 each was refused here instead.
    const plane = if (_image.sampledDepth(image))
        _image.depthPlane(image, range.aspect_mask, range.base_mip_level, count, range.base_array_layer, layers).?
    else
        null;
    // The same plane as rows, for a later subpass to read pixel by pixel
    // (since 1.62): the view's first layer, the depth 0 to 1 and the
    // stencil the whole number it is - by the same two rules.
    const read_rows = if (image.kind == .depth and image.usage & facet.IMAGE_USAGE_INPUT_ATTACHMENT != 0)
        _image.depthRows(image, range.aspect_mask, range.base_mip_level, range.base_array_layer).?
    else
        null;
    // What the view holds: of a 3D image every slice, that image's one
    // layer to Vulkan (`vk_image_view_init`,
    // src/vulkan/runtime/vk_image.c:671), as v3dv gives the TMU the depth
    // of the image's first level and the view's first level apart from it
    // (src/broadcom/vulkan/v3dvx_image.c:68, :79-80).
    const held = if (image.volume) image.layers else layers;
    const made = _objects.create(base.sys_base, ImageView) orelse return .error_out_of_host_memory;
    made.* = .{ .image = image, .format = info.format, .base_level = range.base_mip_level, .level_count = count, .base_layer = range.base_array_layer, .layer_count = held, .swizzle = swizzle };
    // A level of a 3D image has half the slices of the one before
    // (`texture.Texture.slicesAt`), and the view's texture begins at the
    // level it names, so it has that level's slices (since 1.135), as
    // Mesa's view takes the extent of its first level and is as deep as
    // that (src/vulkan/runtime/vk_image.c:648-649, :695).
    if (image.kind == .texture) made.texels = _image.levelsFrom(image, range.base_mip_level, count, range.base_array_layer, if (image.volume) image.texels.slicesAt(range.base_mip_level) else layers);
    // A colour attachment written through as a storage image (since
    // 1.56): its rows are the one level, and a view of it takes them as
    // they are.
    if (_image.writtenRows(image)) made.texels = image.texels;
    // An image kept in rows sampled where they lie: the layers the view
    // names, of every sample (since 1.110), and the levels it names
    // (since 1.119).
    if (_image.sampledRows(image)) made.texels = _image.rowLevels(image, range.base_mip_level, count, range.base_array_layer, layers);
    if (plane) |one| made.texels = one;
    // Of another format than the image's (since 1.131): the same texels
    // at the same places, read the view's way.
    if (info.format != image.given_format and _image.hasTexels(image)) made.texels = _image.readAs(made.texels, image, info.format);
    // What a sample, a fetch and a read of the texels give back, swizzled
    // as the view says (since 1.120), and of a depth or a stencil read
    // (D, 0, 0, 1) whatever it says (since 1.121). An input attachment's
    // rows and a storage image's texels are read where Vulkan has the view
    // swizzle nothing (VUID-VkWriteDescriptorSet-descriptorType-00336), so
    // a view that does is not one either may be.
    if (_image.hasTexels(image)) made.texels.swizzle = if (image.kind == .depth) depthRead(swizzle) else swizzle;
    if (read_rows) |one| made.rows = one;
    // Its pixels, for a later subpass to read as an input attachment: the
    // rows of the level and the layer the view begins at, an image kept in
    // rows having layers since 1.91 and levels since 1.119, and of four
    // samples each sample's rows a plane after the one before (since
    // 1.111).
    if (image.kind == .rows) {
        const rows = _image.rowsAt(image, range.base_mip_level, range.base_array_layer);
        const size = _image.levelSize(image, range.base_mip_level);
        const first = image.data.? + rows.at;
        made.rows = .{
            .bytes = first,
            .pitch = rows.pitch,
            .width = size[0],
            .height = size[1],
            .format = _image.rowFormat(info.format),
            .samples = image.samples,
            .sample_bytes = @intCast(image.sample_bytes),
            .others = first + @as(usize, @intCast(image.sample_bytes)),
        };
    }
    view.* = _objects.handle(facet.ImageView, made);
    return .success;
}

/// The view's component swizzle, as the program gave it: null for a value
/// that is none of Vulkan's seven. It is what a framebuffer asks of the
/// view and what the V3D's TMU takes over the format's own.
fn swizzleOf(components: facet.ComponentMapping) ?texture.Swizzle {
    return .{
        .r = sourceOf(components.r, .red) orelse return null,
        .g = sourceOf(components.g, .green) orelse return null,
        .b = sourceOf(components.b, .blue) orelse return null,
        .a = sourceOf(components.a, .alpha) orelse return null,
    };
}

/// The swizzle a depth's or a stencil's texels apply, whatever the view's:
/// the green and the blue read as 0 and the alpha as 1, so the grey this
/// library reads such a texel as, (D, D, D, 1), is read (D, 0, 0, 1), as
/// Vulkan converts it (13.2.2, "(0,0,0,1) for missing (R,G,B,A)
/// components"). This is lavapipe's `conv_depth_swiz`, on every view of a
/// depth or a stencil (src/gallium/frontends/lavapipe/lvp_image.c:337-347,
/// 389-396), over llvmpipe's read of one, the same grey
/// (`lp_build_format_swizzle_soa`,
/// src/gallium/auxiliary/gallivm/lp_bld_format_soa.c:82-101). Since 1.121
/// on a view that swizzles nothing as well (docs/facet-vulkan10.md item
/// 89); since 1.120 on one that does.
fn depthRead(given: texture.Swizzle) texture.Swizzle {
    var made = given;
    inline for (.{ "r", "g", "b", "a" }) |name| @field(made, name) = switch (@field(made, name)) {
        .green, .blue => .zero,
        .alpha => .one,
        else => |same| same,
    };
    return made;
}

/// Where one channel of a view comes from: `identity` is the channel's
/// own, `own`.
fn sourceOf(component: facet.ComponentSwizzle, own: texture.Swizzle.Source) ?texture.Swizzle.Source {
    return switch (component) {
        .identity => own,
        .zero => .zero,
        .one => .one,
        .r => .red,
        .g => .green,
        .b => .blue,
        .a => .alpha,
        _ => null,
    };
}
