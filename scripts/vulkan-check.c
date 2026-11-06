// SPDX-License-Identifier: MIT
// Rung 8 of docs/facet-ir.md: the SPIR-V facet emits, handed to a desktop
// Vulkan driver and drawn with, every pixel held against the arithmetic
// the other rungs hold facet to.
//
// Rungs 1 and 2 say the modules are the words facet means and that
// Khronos' validator takes them. They do not say that a driver reads them
// as facet does: a Location on the wrong variable, a missing execution
// mode or an interface facet alone agrees with would pass both. This
// draws with them for real.
//
// The oracle is the shares of a triangle worked out here, which is the
// same arithmetic src/disk/c/test/v3d/fragments.zig holds the V3D to and
// src/disk/libs/facet/tests/draw.zig holds facet's own rasterizer to. So
// facet's picture == the arithmetic (rungs 4 and 6) and the driver's
// picture == the arithmetic (this) together say the two pictures are the
// same, which is what the ladder asks for.
//
// The sampler cases keep that oracle by keeping the sampling exactly
// computable: NEAREST filtering over a pattern of known texels, so the
// texel the mixed coordinate lands in is the answer, with no weights of
// the driver's own in it.
//
// Every case is drawn on every Vulkan device the machine has, each an
// implementation that has never seen facet. Built and run by
// scripts/vulkan-check.sh, which hands over the directory the modules
// were written to.

#include <vulkan/vulkan.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define WIDTH 256
#define HEIGHT 256

/// How far a channel may be out: what FacetBoth allows between two
/// rasterizers of the same picture.
#define SLACK 2

/// The shares a pixel must have to be called inside the triangle, and
/// outside it: between the two is the edge, where coverage is the
/// driver's own business and nothing is checked. fragments.zig's
/// `edge_margin`.
#define MARGIN 0.01

/// How close to a texel's edge a sampled coordinate may land before the
/// pixel is left unchecked, in texels of the pattern below. It is there
/// for the reason MARGIN is, one step further on: a driver snaps a vertex
/// to its own subpixel grid, so the coordinate it interpolates differs
/// from the one worked out here in the last few bits - and within a
/// fraction of a texel of a boundary that difference is a different
/// texel, which is a whole different colour rather than a channel out by
/// one. 0.02 texels is about a pixel either side of a boundary here, the
/// same band MARGIN leaves along the triangle's edge, and some hundreds
/// of times the most a corner snapped to a 1/256-pixel grid can move the
/// coordinate at a pixel.
#define TEXEL_MARGIN 0.02

/// What the pass clears to: no part of it is a colour any case draws, so
/// a draw that did not happen shows rather than passing for black.
static const float backdrop[4] = { 0.75f, 0.0f, 0.75f, 1.0f };

#define TEX_W 4
#define TEX_H 4

/// The texture the sampler cases read, as a R8G8B8A8_UNORM image of
/// sixteen texels. No two are alike and no two are a swap of u and v
/// apart, so a driver that took the coordinate the other way round, or
/// walked the rows the other way, could not draw this picture. Every
/// channel is well away from zero, alpha with them, or a channel lost on
/// the way would pass for one the module never asked for.
static const unsigned char texels[TEX_H][TEX_W][4] = {
    { { 0x20, 0x40, 0xE0, 0xFF }, { 0x40, 0xE0, 0x20, 0xD0 }, { 0xE0, 0x20, 0x40, 0xA0 }, { 0xC0, 0xC0, 0x20, 0x70 } },
    { { 0x60, 0x20, 0xA0, 0xD0 }, { 0x20, 0xA0, 0x60, 0xA0 }, { 0xA0, 0x60, 0x20, 0x70 }, { 0x80, 0x20, 0xC0, 0xFF } },
    { { 0xA0, 0xE0, 0x40, 0xA0 }, { 0xE0, 0x40, 0xA0, 0x70 }, { 0x40, 0xA0, 0xE0, 0xFF }, { 0x20, 0x80, 0x80, 0xD0 } },
    { { 0xE0, 0x80, 0x60, 0x70 }, { 0x80, 0x60, 0xE0, 0xFF }, { 0x60, 0xE0, 0x80, 0xD0 }, { 0xE0, 0xE0, 0xE0, 0xA0 } },
};

/// A vertex as the three vertex shaders read it: the clip position, a
/// colour, one float, and a texture coordinate. facet's own module reads
/// the first three floats of it and nothing else.
struct Vertex {
    float pos[4];
    float colour[4];
    float light;
    float uv[2];
    float pad[1];
};

/// The triangle the modules that take varyings are drawn over. w is 1 at
/// every corner, so a varying is mixed as the shares are and the
/// arithmetic below needs no perspective. The coordinate follows the
/// corner across the screen, so the picture is the pattern seen through
/// the triangle, and stays well inside 0 to 1, so the sampler's
/// CLAMP_TO_EDGE never comes into the answer.
static const struct Vertex carried[3] = {
    { { 0.0f, -0.8f, 0.5f, 1.0f }, { 1.0f, 0.0f, 0.0f, 1.0f }, 1.0f, { 0.50f, 0.05f }, { 0 } },
    { { -0.8f, 0.8f, 0.5f, 1.0f }, { 0.0f, 1.0f, 0.0f, 1.0f }, 0.5f, { 0.05f, 0.95f }, { 0 } },
    { { 0.8f, 0.8f, 0.5f, 1.0f }, { 0.0f, 0.0f, 1.0f, 1.0f }, 0.0f, { 0.95f, 0.95f }, { 0 } },
};

/// The triangle for facet's own vertex module, which hands the position
/// on as the varying at location 0: every part of it is between 0 and 1,
/// so the colour that comes out is the position itself and nothing is
/// clamped on the way. z stays inside 0 to 1 as well, or it would be
/// clipped.
static const struct Vertex placed[3] = {
    { { 0.1f, 0.1f, 0.25f, 1.0f }, { 0, 0, 0, 0 }, 0.0f, { 0, 0 }, { 0 } },
    { { 0.9f, 0.1f, 0.50f, 1.0f }, { 0, 0, 0, 0 }, 0.0f, { 0, 0 }, { 0 } },
    { { 0.5f, 0.9f, 0.75f, 1.0f }, { 0, 0, 0, 0 }, 0.0f, { 0, 0 }, { 0 } },
};

enum Want {
    /// The colour the module holds itself: `min_flat`'s red.
    want_flat,
    /// The colour the corners carry, mixed.
    want_carried,
    /// That colour times the float beside it, alpha with it.
    want_scaled,
    /// The position the corners carry, mixed, as a colour.
    want_placed,
    /// The texel the coordinate the corners carry lands in.
    want_texel,
    /// That texel times the colour the corners carry, mixed.
    want_modulated,
};

struct Case {
    const char *name;
    /// The modules, by the name of the file in the directory handed over.
    const char *vertex;
    const char *fragment;
    const struct Vertex *corners;
    /// Whether the vertex shader reads the colour and the third
    /// attribute too, or only the position's first three floats.
    int wide;
    /// Whether the vertex shader wants a mat4 at set 0, binding 0.
    int matrix;
    /// Whether the fragment module wants the texture and its sampler
    /// there instead, and with it the third attribute as a coordinate
    /// rather than a float.
    int textured;
    enum Want want;
};

static const struct Case cases[] = {
    { "flat", "own_vert", "min_flat", carried, 1, 0, 0, want_flat },
    { "interp", "own_vert", "min_interp", carried, 1, 0, 0, want_carried },
    { "scaled", "own_vert", "min_scaled", carried, 1, 0, 0, want_scaled },
    { "placed", "min_vert", "min_interp", placed, 0, 1, 0, want_placed },
    { "tex", "uv_vert", "min_tex", carried, 1, 0, 1, want_texel },
    { "texmod", "uv_vert", "min_texmod", carried, 1, 0, 1, want_modulated },
};

#define case_count ((int)(sizeof cases / sizeof cases[0]))

/// Column-major, which is what `min_vert`'s ColMajor and MatrixStride 16
/// say its uniform holds.
static const float identity[16] = {
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
};

static const char *module_dir = ".";
static const char *picture_dir = NULL;

/// How the arithmetic may be spoiled on purpose.
///
/// A rung is worth having only if it is able to fail, and "it passed" is
/// no evidence of that: a check that compares a picture with itself
/// passes too, and so does one whose loop never runs. So each of these
/// is a named, small, plausible lie about what the pixel should hold -
/// the kind of mistake a back end makes - and a run told to tell one
/// must come back with wrong pixels. `vulkan-check.sh --prove` tells
/// each in turn and fails if any goes unnoticed.
///
/// Two of the three are lies about the sampler alone, so they leave the
/// four colour cases right and are caught in the two that sample. That
/// is the point rather than a weakness: a lie is caught exactly where
/// the thing it lies about is looked at.
enum Spoiling {
    spoil_none,
    spoil_channels, ///< red and green the wrong way round in the answer
    spoil_filter,   ///< the texel LINEAR's lower-left weight would reach
    spoil_flip      ///< u and v the wrong way round before the lookup
};

static const struct {
    const char *name;
    enum Spoiling which;
    const char *what;
} spoilings[] = {
    { "channels", spoil_channels, "red and green swapped in the answer" },
    { "filter", spoil_filter, "the texel at floor(c*size - 0.5), which is LINEAR's lower-left" },
    { "flip", spoil_flip, "u and v swapped before the lookup" },
};
#define spoiling_count ((int)(sizeof spoilings / sizeof spoilings[0]))

static enum Spoiling spoiling = spoil_none;

/// Cases whose pixels were all right, and cases that held a wrong one.
/// Counted rather than inferred from the exit status, because a run told
/// a lie about the sampler is meant to leave the colour cases alone.
static int cases_run = 0;
static int cases_wrong = 0;

/// What the run was told, for the line at the end.
static const char *spoiled_what(void) {
    int k;

    for (k = 0; k < spoiling_count; k++)
        if (spoilings[k].which == spoiling) return spoilings[k].what;
    return "nothing";
}

static int failed = 0;

/// Who made the device, by the number Vulkan gives: the short name the
/// lines below are labelled with.
static const char *vendor_named(uint32_t vendor) {
    switch (vendor) {
    case 0x1002: return "amd";
    case 0x1010: return "imgtec";
    case 0x106b: return "apple";
    case 0x10de: return "nvidia";
    case 0x13b5: return "arm";
    case 0x14e4: return "broadcom";
    case 0x5143: return "qualcomm";
    case 0x8086: return "intel";
    case 0x10005: return "mesa";
    default: return "other";
    }
}

static int oh(VkResult result, const char *what) {
    if (result == VK_SUCCESS) return 1;
    fprintf(stderr, "%s: %d\n", what, (int)result);
    return 0;
}

/// A module's words, read from the file the script wrote. Freed by the
/// caller; null and said where it could not be read.
static uint32_t *module_words(const char *name, size_t *bytes) {
    char path[1024];
    uint32_t *words;
    long size;
    FILE *file;

    snprintf(path, sizeof path, "%s/%s.spv", module_dir, name);
    file = fopen(path, "rb");
    if (!file) {
        fprintf(stderr, "%s is not there\n", path);
        return NULL;
    }
    if (fseek(file, 0, SEEK_END) != 0 || (size = ftell(file)) <= 0 || size % 4 != 0) {
        fprintf(stderr, "%s is no module\n", path);
        fclose(file);
        return NULL;
    }
    rewind(file);
    words = malloc((size_t)size);
    if (!words) {
        fclose(file);
        fprintf(stderr, "no memory for %s\n", path);
        return NULL;
    }
    if (fread(words, 1, (size_t)size, file) != (size_t)size) {
        fprintf(stderr, "%s stops in the middle\n", path);
        free(words);
        fclose(file);
        return NULL;
    }
    fclose(file);
    *bytes = (size_t)size;
    return words;
}

static VkShaderModule shader_of(VkDevice device, const char *name) {
    VkShaderModuleCreateInfo how;
    VkShaderModule made = VK_NULL_HANDLE;
    size_t bytes = 0;
    uint32_t *words = module_words(name, &bytes);

    if (!words) return VK_NULL_HANDLE;
    memset(&how, 0, sizeof how);
    how.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    how.codeSize = bytes;
    how.pCode = words;
    if (!oh(vkCreateShaderModule(device, &how, NULL, &made), name)) made = VK_NULL_HANDLE;
    free(words);
    return made;
}

static uint32_t memory_type(VkPhysicalDevice physical, uint32_t allowed, VkMemoryPropertyFlags want) {
    VkPhysicalDeviceMemoryProperties memories;
    uint32_t k;

    vkGetPhysicalDeviceMemoryProperties(physical, &memories);
    for (k = 0; k < memories.memoryTypeCount; k++) {
        if ((allowed & (1u << k)) == 0) continue;
        if ((memories.memoryTypes[k].propertyFlags & want) == want) return k;
    }
    return UINT32_MAX;
}

/// The three shares of the pixel's centre, which sum to one wherever the
/// pixel is: inside the triangle they are all above zero.
static int shares(const struct Vertex *corners, int x, int y, double out[3]) {
    double px = 2.0 * ((double)x + 0.5) / (double)WIDTH - 1.0;
    double py = 2.0 * ((double)y + 0.5) / (double)HEIGHT - 1.0;
    double x0 = corners[0].pos[0], y0 = corners[0].pos[1];
    double x1 = corners[1].pos[0], y1 = corners[1].pos[1];
    double x2 = corners[2].pos[0], y2 = corners[2].pos[1];
    double area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0);

    if (area == 0.0) return 0;
    out[0] = ((x1 - px) * (y2 - py) - (x2 - px) * (y1 - py)) / area;
    out[1] = ((x2 - px) * (y0 - py) - (x0 - px) * (y2 - py)) / area;
    out[2] = ((x0 - px) * (y1 - py) - (x1 - px) * (y0 - py)) / area;
    return 1;
}

static double mixed(const struct Case *each, const double b[3], int k, int of_position) {
    const struct Vertex *corners = each->corners;
    const float *a = of_position ? corners[0].pos : corners[0].colour;
    const float *c = of_position ? corners[1].pos : corners[1].colour;
    const float *d = of_position ? corners[2].pos : corners[2].colour;

    return b[0] * (double)a[k] + b[1] * (double)c[k] + b[2] * (double)d[k];
}

/// The texture coordinate at the pixel, mixed from the corners' as every
/// other varying is.
static void mixed_uv(const struct Case *each, const double b[3], double out[2]) {
    const struct Vertex *corners = each->corners;
    int k;

    for (k = 0; k < 2; k++)
        out[k] = b[0] * (double)corners[0].uv[k] + b[1] * (double)corners[1].uv[k] +
                 b[2] * (double)corners[2].uv[k];
}

/// Where a coordinate lands: the texel a NEAREST sampler reads, and how
/// far into it, 0 at its near edge and 1 at its far one. Either answer
/// may be left out. The texel is held inside the image, which is what
/// CLAMP_TO_EDGE does.
static void lands(double coord, int size, int *texel, double *over) {
    double scaled = coord * (double)size;
    long whole = (long)scaled;

    // A cast truncates towards zero, which is a floor only above it.
    if (scaled < (double)whole) whole--;
    if (over) *over = scaled - (double)whole;
    if (texel) *texel = whole < 0 ? 0 : (whole >= size ? size - 1 : (int)whole);
}

/// The texel the sampler reads at the pixel.
static const unsigned char *texel_at(const struct Case *each, const double b[3]) {
    double uv[2];
    int x = 0, y = 0;

    mixed_uv(each, b, uv);
    if (spoiling == spoil_flip) {
        double swap = uv[0];
        uv[0] = uv[1];
        uv[1] = swap;
    }
    // Half a texel back along both axes, which is where LINEAR's
    // lower-left weight sits and NEAREST's answer is not.
    if (spoiling == spoil_filter) {
        uv[0] -= 0.5 / (double)TEX_W;
        uv[1] -= 0.5 / (double)TEX_H;
    }
    lands(uv[0], TEX_W, &x, NULL);
    lands(uv[1], TEX_H, &y, NULL);
    return texels[y][x];
}

/// Whether the pixel's coordinate lands within TEXEL_MARGIN of a texel's
/// edge, where which texel is read is rounding rather than arithmetic.
/// Only the sampler cases have such an edge.
static int on_texel_edge(const struct Case *each, const double b[3]) {
    double uv[2], over[2];
    int k;

    if (each->want != want_texel && each->want != want_modulated) return 0;
    mixed_uv(each, b, uv);
    lands(uv[0], TEX_W, NULL, &over[0]);
    lands(uv[1], TEX_H, NULL, &over[1]);
    for (k = 0; k < 2; k++)
        if (over[k] < TEXEL_MARGIN || over[k] > 1.0 - TEXEL_MARGIN) return 1;
    return 0;
}

/// What the pixel should hold, as the four bytes a R8G8B8A8_UNORM
/// attachment keeps.
static void wanted(const struct Case *each, const double b[3], unsigned char out[4]) {
    double channel[4] = { 0, 0, 0, 0 };
    const unsigned char *texel;
    double light;
    int k;

    switch (each->want) {
    case want_flat:
        channel[0] = 1;
        channel[3] = 1;
        break;
    case want_carried:
        for (k = 0; k < 4; k++) channel[k] = mixed(each, b, k, 0);
        break;
    case want_scaled:
        light = b[0] * (double)each->corners[0].light + b[1] * (double)each->corners[1].light +
                b[2] * (double)each->corners[2].light;
        for (k = 0; k < 4; k++) channel[k] = light * mixed(each, b, k, 0);
        break;
    case want_placed:
        for (k = 0; k < 3; k++) channel[k] = mixed(each, b, k, 1);
        channel[3] = 1;
        break;
    case want_texel:
        // A NEAREST sample of a UNORM texel is that texel, and storing it
        // to a UNORM attachment gives the byte back: the answer is the
        // table's own row.
        texel = texel_at(each, b);
        for (k = 0; k < 4; k++) channel[k] = (double)texel[k] / 255.0;
        break;
    case want_modulated:
        texel = texel_at(each, b);
        for (k = 0; k < 4; k++) channel[k] = (double)texel[k] / 255.0 * mixed(each, b, k, 0);
        break;
    }
    if (spoiling == spoil_channels) {
        double swap = channel[0];
        channel[0] = channel[1];
        channel[1] = swap;
    }
    for (k = 0; k < 4; k++) {
        double held = channel[k] < 0 ? 0 : (channel[k] > 1 ? 1 : channel[k]);
        out[k] = (unsigned char)(held * 255.0 + 0.5);
    }
}

static void write_picture(const char *driver, const char *name, const unsigned char *pixels) {
    char path[1024];
    FILE *file;
    int at;

    if (!picture_dir) return;
    snprintf(path, sizeof path, "%s/%s-%s.ppm", picture_dir, driver, name);
    file = fopen(path, "wb");
    if (!file) {
        fprintf(stderr, "%s could not be written\n", path);
        return;
    }
    fprintf(file, "P6\n%d %d\n255\n", WIDTH, HEIGHT);
    for (at = 0; at < WIDTH * HEIGHT; at++) fwrite(pixels + (size_t)at * 4, 1, 3, file);
    fclose(file);
}

/// Everything one device needs for every case, made once.
struct Bench {
    VkPhysicalDevice physical;
    VkDevice device;
    VkQueue queue;
    uint32_t family;
    VkImage image;
    VkDeviceMemory image_memory;
    VkImageView view;
    VkRenderPass pass;
    VkFramebuffer frame;
    VkBuffer readback;
    VkDeviceMemory readback_memory;
    VkBuffer vertices;
    VkDeviceMemory vertices_memory;
    VkBuffer uniform;
    VkDeviceMemory uniform_memory;
    VkBuffer staging;
    VkDeviceMemory staging_memory;
    VkImage texture;
    VkDeviceMemory texture_memory;
    VkImageView texture_view;
    VkSampler sampler;
    VkDescriptorSetLayout set_layout;
    VkDescriptorSetLayout sampler_layout;
    VkDescriptorPool set_pool;
    VkDescriptorSet set;
    VkDescriptorSet sampler_set;
    VkCommandPool commands;
    VkCommandBuffer command;
    VkFence fence;
};

static int buffer_of(struct Bench *bench, VkDeviceSize bytes, VkBufferUsageFlags usage,
                     VkBuffer *into, VkDeviceMemory *memory) {
    VkBufferCreateInfo how;
    VkMemoryRequirements wants;
    VkMemoryAllocateInfo give;
    uint32_t kind;

    memset(&how, 0, sizeof how);
    how.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    how.size = bytes;
    how.usage = usage;
    how.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (!oh(vkCreateBuffer(bench->device, &how, NULL, into), "a buffer")) return 0;
    vkGetBufferMemoryRequirements(bench->device, *into, &wants);
    kind = memory_type(bench->physical, wants.memoryTypeBits,
                       VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (kind == UINT32_MAX) {
        fprintf(stderr, "no memory a buffer can be read from\n");
        return 0;
    }
    memset(&give, 0, sizeof give);
    give.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    give.allocationSize = wants.size;
    give.memoryTypeIndex = kind;
    if (!oh(vkAllocateMemory(bench->device, &give, NULL, memory), "memory for a buffer")) return 0;
    return oh(vkBindBufferMemory(bench->device, *into, *memory, 0), "a buffer's memory");
}

/// The texture the sampler cases read: made, filled through a staging
/// buffer, left in SHADER_READ_ONLY_OPTIMAL, with the sampler and the
/// descriptor that reach it. NEAREST and CLAMP_TO_EDGE are what make the
/// answer exactly computable - the texel the coordinate lands in is the
/// colour, with no weights and no wrap in it - and what the back end
/// facet is being held against does as well.
static int texture_up(struct Bench *bench) {
    VkImageCreateInfo image_how;
    VkMemoryRequirements wants;
    VkMemoryAllocateInfo give;
    VkImageViewCreateInfo view_how;
    VkSamplerCreateInfo sampler_how;
    VkCommandBufferBeginInfo begin;
    VkImageMemoryBarrier barrier;
    VkBufferImageCopy copy;
    VkSubmitInfo submit;
    VkDescriptorImageInfo set_image;
    VkWriteDescriptorSet write;
    uint32_t kind;
    void *at;

    memset(&image_how, 0, sizeof image_how);
    image_how.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    image_how.imageType = VK_IMAGE_TYPE_2D;
    image_how.format = VK_FORMAT_R8G8B8A8_UNORM;
    image_how.extent.width = TEX_W;
    image_how.extent.height = TEX_H;
    image_how.extent.depth = 1;
    image_how.mipLevels = 1;
    image_how.arrayLayers = 1;
    image_how.samples = VK_SAMPLE_COUNT_1_BIT;
    image_how.tiling = VK_IMAGE_TILING_OPTIMAL;
    image_how.usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    image_how.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    image_how.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    if (!oh(vkCreateImage(bench->device, &image_how, NULL, &bench->texture), "the texture")) return 0;
    vkGetImageMemoryRequirements(bench->device, bench->texture, &wants);
    kind = memory_type(bench->physical, wants.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (kind == UINT32_MAX) kind = memory_type(bench->physical, wants.memoryTypeBits, 0);
    if (kind == UINT32_MAX) {
        fprintf(stderr, "no memory the texture fits in\n");
        return 0;
    }
    memset(&give, 0, sizeof give);
    give.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    give.allocationSize = wants.size;
    give.memoryTypeIndex = kind;
    if (!oh(vkAllocateMemory(bench->device, &give, NULL, &bench->texture_memory), "memory for the texture")) return 0;
    if (!oh(vkBindImageMemory(bench->device, bench->texture, bench->texture_memory, 0),
            "the texture's memory")) return 0;

    if (!buffer_of(bench, sizeof texels, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                   &bench->staging, &bench->staging_memory)) return 0;
    if (!oh(vkMapMemory(bench->device, bench->staging_memory, 0, sizeof texels, 0, &at), "the texels")) return 0;
    memcpy(at, texels, sizeof texels);
    vkUnmapMemory(bench->device, bench->staging_memory);

    if (!oh(vkResetCommandBuffer(bench->command, 0), "the command buffer")) return 0;
    memset(&begin, 0, sizeof begin);
    begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    if (!oh(vkBeginCommandBuffer(bench->command, &begin), "recording the upload")) return 0;
    memset(&barrier, 0, sizeof barrier);
    barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.image = bench->texture;
    barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.layerCount = 1;
    barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    vkCmdPipelineBarrier(bench->command, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         0, 0, NULL, 0, NULL, 1, &barrier);
    memset(&copy, 0, sizeof copy);
    copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    copy.imageSubresource.layerCount = 1;
    copy.imageExtent.width = TEX_W;
    copy.imageExtent.height = TEX_H;
    copy.imageExtent.depth = 1;
    vkCmdCopyBufferToImage(bench->command, bench->staging, bench->texture,
                           VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
    barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    vkCmdPipelineBarrier(bench->command, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, NULL, 0, NULL, 1, &barrier);
    if (!oh(vkEndCommandBuffer(bench->command), "the upload's recording")) return 0;
    if (!oh(vkResetFences(bench->device, 1, &bench->fence), "the fence")) return 0;
    memset(&submit, 0, sizeof submit);
    submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &bench->command;
    if (!oh(vkQueueSubmit(bench->queue, 1, &submit, bench->fence), "the upload")) return 0;
    if (!oh(vkWaitForFences(bench->device, 1, &bench->fence, VK_TRUE, 5000000000ull),
            "the upload to land")) return 0;

    memset(&view_how, 0, sizeof view_how);
    view_how.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    view_how.image = bench->texture;
    view_how.viewType = VK_IMAGE_VIEW_TYPE_2D;
    view_how.format = VK_FORMAT_R8G8B8A8_UNORM;
    view_how.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    view_how.subresourceRange.levelCount = 1;
    view_how.subresourceRange.layerCount = 1;
    if (!oh(vkCreateImageView(bench->device, &view_how, NULL, &bench->texture_view),
            "the texture's view")) return 0;

    memset(&sampler_how, 0, sizeof sampler_how);
    sampler_how.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    sampler_how.magFilter = VK_FILTER_NEAREST;
    sampler_how.minFilter = VK_FILTER_NEAREST;
    sampler_how.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
    sampler_how.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    sampler_how.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    sampler_how.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    // minLod and maxLod stay 0, so the level of detail the modules ask
    // the driver to work out from the derivatives lands on the one level
    // there is, however it comes out.
    if (!oh(vkCreateSampler(bench->device, &sampler_how, NULL, &bench->sampler), "the sampler")) return 0;

    memset(&set_image, 0, sizeof set_image);
    set_image.sampler = bench->sampler;
    set_image.imageView = bench->texture_view;
    set_image.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    memset(&write, 0, sizeof write);
    write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    write.dstSet = bench->sampler_set;
    write.descriptorCount = 1;
    write.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    write.pImageInfo = &set_image;
    vkUpdateDescriptorSets(bench->device, 1, &write, 0, NULL);
    return 1;
}

static int bench_up(struct Bench *bench) {
    VkImageCreateInfo image_how;
    VkMemoryRequirements wants;
    VkMemoryAllocateInfo give;
    VkImageViewCreateInfo view_how;
    VkAttachmentDescription attachment;
    VkAttachmentReference reference;
    VkSubpassDescription subpass;
    VkSubpassDependency after;
    VkRenderPassCreateInfo pass_how;
    VkFramebufferCreateInfo frame_how;
    VkDescriptorSetLayoutBinding binding;
    VkDescriptorSetLayoutCreateInfo set_layout_how;
    VkDescriptorPoolSize pool_sizes[2];
    VkDescriptorPoolCreateInfo pool_how;
    VkDescriptorSetAllocateInfo set_how;
    VkDescriptorBufferInfo set_buffer;
    VkWriteDescriptorSet write;
    VkCommandPoolCreateInfo commands_how;
    VkCommandBufferAllocateInfo command_how;
    VkFenceCreateInfo fence_how;
    uint32_t kind;
    void *at;

    memset(&image_how, 0, sizeof image_how);
    image_how.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    image_how.imageType = VK_IMAGE_TYPE_2D;
    image_how.format = VK_FORMAT_R8G8B8A8_UNORM;
    image_how.extent.width = WIDTH;
    image_how.extent.height = HEIGHT;
    image_how.extent.depth = 1;
    image_how.mipLevels = 1;
    image_how.arrayLayers = 1;
    image_how.samples = VK_SAMPLE_COUNT_1_BIT;
    image_how.tiling = VK_IMAGE_TILING_OPTIMAL;
    image_how.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    image_how.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    image_how.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    if (!oh(vkCreateImage(bench->device, &image_how, NULL, &bench->image), "the picture")) return 0;
    vkGetImageMemoryRequirements(bench->device, bench->image, &wants);
    kind = memory_type(bench->physical, wants.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (kind == UINT32_MAX) kind = memory_type(bench->physical, wants.memoryTypeBits, 0);
    if (kind == UINT32_MAX) {
        fprintf(stderr, "no memory the picture fits in\n");
        return 0;
    }
    memset(&give, 0, sizeof give);
    give.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    give.allocationSize = wants.size;
    give.memoryTypeIndex = kind;
    if (!oh(vkAllocateMemory(bench->device, &give, NULL, &bench->image_memory), "memory for the picture")) return 0;
    if (!oh(vkBindImageMemory(bench->device, bench->image, bench->image_memory, 0), "the picture's memory")) return 0;

    memset(&view_how, 0, sizeof view_how);
    view_how.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    view_how.image = bench->image;
    view_how.viewType = VK_IMAGE_VIEW_TYPE_2D;
    view_how.format = VK_FORMAT_R8G8B8A8_UNORM;
    view_how.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    view_how.subresourceRange.levelCount = 1;
    view_how.subresourceRange.layerCount = 1;
    if (!oh(vkCreateImageView(bench->device, &view_how, NULL, &bench->view), "the picture's view")) return 0;

    memset(&attachment, 0, sizeof attachment);
    attachment.format = VK_FORMAT_R8G8B8A8_UNORM;
    attachment.samples = VK_SAMPLE_COUNT_1_BIT;
    attachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    attachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    attachment.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    attachment.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    attachment.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    attachment.finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    memset(&reference, 0, sizeof reference);
    reference.attachment = 0;
    reference.layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    memset(&subpass, 0, sizeof subpass);
    subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments = &reference;
    memset(&after, 0, sizeof after);
    after.srcSubpass = 0;
    after.dstSubpass = VK_SUBPASS_EXTERNAL;
    after.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    after.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    after.dstStageMask = VK_PIPELINE_STAGE_TRANSFER_BIT;
    after.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    memset(&pass_how, 0, sizeof pass_how);
    pass_how.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    pass_how.attachmentCount = 1;
    pass_how.pAttachments = &attachment;
    pass_how.subpassCount = 1;
    pass_how.pSubpasses = &subpass;
    pass_how.dependencyCount = 1;
    pass_how.pDependencies = &after;
    if (!oh(vkCreateRenderPass(bench->device, &pass_how, NULL, &bench->pass), "the pass")) return 0;

    memset(&frame_how, 0, sizeof frame_how);
    frame_how.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
    frame_how.renderPass = bench->pass;
    frame_how.attachmentCount = 1;
    frame_how.pAttachments = &bench->view;
    frame_how.width = WIDTH;
    frame_how.height = HEIGHT;
    frame_how.layers = 1;
    if (!oh(vkCreateFramebuffer(bench->device, &frame_how, NULL, &bench->frame), "the framebuffer")) return 0;

    if (!buffer_of(bench, (VkDeviceSize)WIDTH * HEIGHT * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                   &bench->readback, &bench->readback_memory)) return 0;
    if (!buffer_of(bench, sizeof carried, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                   &bench->vertices, &bench->vertices_memory)) return 0;
    if (!buffer_of(bench, sizeof identity, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                   &bench->uniform, &bench->uniform_memory)) return 0;

    if (!oh(vkMapMemory(bench->device, bench->uniform_memory, 0, sizeof identity, 0, &at), "the matrix")) return 0;
    memcpy(at, identity, sizeof identity);
    vkUnmapMemory(bench->device, bench->uniform_memory);

    memset(&binding, 0, sizeof binding);
    binding.binding = 0;
    binding.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    binding.descriptorCount = 1;
    binding.stageFlags = VK_SHADER_STAGE_VERTEX_BIT;
    memset(&set_layout_how, 0, sizeof set_layout_how);
    set_layout_how.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    set_layout_how.bindingCount = 1;
    set_layout_how.pBindings = &binding;
    if (!oh(vkCreateDescriptorSetLayout(bench->device, &set_layout_how, NULL, &bench->set_layout),
            "the set's layout")) return 0;
    // The sampler modules read their image at the same set and the same
    // binding, from the other stage, so it is a layout of its own: a
    // pipeline is made with the one or the other, never both.
    binding.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    binding.stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    if (!oh(vkCreateDescriptorSetLayout(bench->device, &set_layout_how, NULL, &bench->sampler_layout),
            "the sampler's layout")) return 0;
    memset(pool_sizes, 0, sizeof pool_sizes);
    pool_sizes[0].type = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    pool_sizes[0].descriptorCount = 1;
    pool_sizes[1].type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    pool_sizes[1].descriptorCount = 1;
    memset(&pool_how, 0, sizeof pool_how);
    pool_how.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    pool_how.maxSets = 2;
    pool_how.poolSizeCount = 2;
    pool_how.pPoolSizes = pool_sizes;
    if (!oh(vkCreateDescriptorPool(bench->device, &pool_how, NULL, &bench->set_pool), "the set's pool")) return 0;
    memset(&set_how, 0, sizeof set_how);
    set_how.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    set_how.descriptorPool = bench->set_pool;
    set_how.descriptorSetCount = 1;
    set_how.pSetLayouts = &bench->set_layout;
    if (!oh(vkAllocateDescriptorSets(bench->device, &set_how, &bench->set), "the set")) return 0;
    set_how.pSetLayouts = &bench->sampler_layout;
    if (!oh(vkAllocateDescriptorSets(bench->device, &set_how, &bench->sampler_set),
            "the sampler's set")) return 0;
    memset(&set_buffer, 0, sizeof set_buffer);
    set_buffer.buffer = bench->uniform;
    set_buffer.range = sizeof identity;
    memset(&write, 0, sizeof write);
    write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    write.dstSet = bench->set;
    write.descriptorCount = 1;
    write.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    write.pBufferInfo = &set_buffer;
    vkUpdateDescriptorSets(bench->device, 1, &write, 0, NULL);

    memset(&commands_how, 0, sizeof commands_how);
    commands_how.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    commands_how.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    commands_how.queueFamilyIndex = bench->family;
    if (!oh(vkCreateCommandPool(bench->device, &commands_how, NULL, &bench->commands), "the command pool")) return 0;
    memset(&command_how, 0, sizeof command_how);
    command_how.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    command_how.commandPool = bench->commands;
    command_how.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    command_how.commandBufferCount = 1;
    if (!oh(vkAllocateCommandBuffers(bench->device, &command_how, &bench->command), "the command buffer")) return 0;
    memset(&fence_how, 0, sizeof fence_how);
    fence_how.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    if (!oh(vkCreateFence(bench->device, &fence_how, NULL, &bench->fence), "the fence")) return 0;
    // Last, because the upload is drawn on the command buffer and waited
    // for on the fence.
    return texture_up(bench);
}

static void bench_down(struct Bench *bench) {
    VkDevice device = bench->device;

    if (bench->sampler) vkDestroySampler(device, bench->sampler, NULL);
    if (bench->texture_view) vkDestroyImageView(device, bench->texture_view, NULL);
    if (bench->texture) vkDestroyImage(device, bench->texture, NULL);
    if (bench->texture_memory) vkFreeMemory(device, bench->texture_memory, NULL);
    if (bench->staging) vkDestroyBuffer(device, bench->staging, NULL);
    if (bench->staging_memory) vkFreeMemory(device, bench->staging_memory, NULL);
    if (bench->fence) vkDestroyFence(device, bench->fence, NULL);
    if (bench->commands) vkDestroyCommandPool(device, bench->commands, NULL);
    if (bench->set_pool) vkDestroyDescriptorPool(device, bench->set_pool, NULL);
    if (bench->sampler_layout) vkDestroyDescriptorSetLayout(device, bench->sampler_layout, NULL);
    if (bench->set_layout) vkDestroyDescriptorSetLayout(device, bench->set_layout, NULL);
    if (bench->uniform) vkDestroyBuffer(device, bench->uniform, NULL);
    if (bench->uniform_memory) vkFreeMemory(device, bench->uniform_memory, NULL);
    if (bench->vertices) vkDestroyBuffer(device, bench->vertices, NULL);
    if (bench->vertices_memory) vkFreeMemory(device, bench->vertices_memory, NULL);
    if (bench->readback) vkDestroyBuffer(device, bench->readback, NULL);
    if (bench->readback_memory) vkFreeMemory(device, bench->readback_memory, NULL);
    if (bench->frame) vkDestroyFramebuffer(device, bench->frame, NULL);
    if (bench->pass) vkDestroyRenderPass(device, bench->pass, NULL);
    if (bench->view) vkDestroyImageView(device, bench->view, NULL);
    if (bench->image) vkDestroyImage(device, bench->image, NULL);
    if (bench->image_memory) vkFreeMemory(device, bench->image_memory, NULL);
    vkDestroyDevice(device, NULL);
}

/// One case drawn and checked. False where something was refused, which
/// is a failure of its own: facet's module is meant to make a pipeline.
static int run_case(struct Bench *bench, const char *driver, const struct Case *each) {
    VkDevice device = bench->device;
    VkShaderModule vertex = VK_NULL_HANDLE;
    VkShaderModule fragment = VK_NULL_HANDLE;
    VkPipelineLayout layout = VK_NULL_HANDLE;
    VkPipeline pipeline = VK_NULL_HANDLE;
    // The one descriptor set the case wants: the matrix for facet's own
    // vertex module, the texture and its sampler for the sampler
    // modules, and nothing at all for the rest.
    const VkDescriptorSetLayout *set_layout = each->textured ? &bench->sampler_layout :
                                              each->matrix ? &bench->set_layout : NULL;
    const VkDescriptorSet *set = each->textured ? &bench->sampler_set :
                                 each->matrix ? &bench->set : NULL;
    VkPipelineShaderStageCreateInfo stages[2];
    VkVertexInputBindingDescription stride;
    VkVertexInputAttributeDescription attributes[3];
    VkPipelineVertexInputStateCreateInfo input;
    VkPipelineInputAssemblyStateCreateInfo assembly;
    VkViewport viewport;
    VkRect2D scissor;
    VkPipelineViewportStateCreateInfo viewports;
    VkPipelineRasterizationStateCreateInfo raster;
    VkPipelineMultisampleStateCreateInfo samples;
    VkPipelineColorBlendAttachmentState blending;
    VkPipelineColorBlendStateCreateInfo blend;
    VkPipelineLayoutCreateInfo layout_how;
    VkGraphicsPipelineCreateInfo pipeline_how;
    VkCommandBufferBeginInfo begin;
    VkClearValue clear;
    VkRenderPassBeginInfo pass_begin;
    VkBufferImageCopy copy;
    VkSubmitInfo submit;
    VkDeviceSize nothing = 0;
    unsigned char *pixels = NULL;
    void *at;
    unsigned long checked = 0, wrong = 0;
    unsigned worst = 0;
    int first_x = 0, first_y = 0;
    unsigned char first_got[4] = { 0, 0, 0, 0 }, first_want[4] = { 0, 0, 0, 0 };
    int ok = 0;
    int x, y, k;

    if (!oh(vkMapMemory(device, bench->vertices_memory, 0, sizeof carried, 0, &at), "the vertices")) return 0;
    memcpy(at, each->corners, sizeof carried);
    vkUnmapMemory(device, bench->vertices_memory);

    vertex = shader_of(device, each->vertex);
    fragment = shader_of(device, each->fragment);
    if (!vertex || !fragment) goto done;

    memset(stages, 0, sizeof stages);
    stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module = vertex;
    stages[0].pName = "main";
    stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].module = fragment;
    stages[1].pName = "main";

    memset(&stride, 0, sizeof stride);
    stride.binding = 0;
    stride.stride = sizeof(struct Vertex);
    stride.inputRate = VK_VERTEX_INPUT_RATE_VERTEX;
    memset(attributes, 0, sizeof attributes);
    attributes[0].location = 0;
    attributes[0].format = each->wide ? VK_FORMAT_R32G32B32A32_SFLOAT : VK_FORMAT_R32G32B32_SFLOAT;
    attributes[0].offset = 0;
    attributes[1].location = 1;
    attributes[1].format = VK_FORMAT_R32G32B32A32_SFLOAT;
    attributes[1].offset = (uint32_t)(sizeof(float) * 4);
    attributes[2].location = 2;
    // Location 2 is the float the colour modules take beside the colour,
    // or the coordinate the sampler ones take in its place: a different
    // format at a different offset, which is the other half of why they
    // cannot be given the same vertex shader.
    attributes[2].format = each->textured ? VK_FORMAT_R32G32_SFLOAT : VK_FORMAT_R32_SFLOAT;
    attributes[2].offset = (uint32_t)(sizeof(float) * (each->textured ? 9 : 8));
    memset(&input, 0, sizeof input);
    input.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    input.vertexBindingDescriptionCount = 1;
    input.pVertexBindingDescriptions = &stride;
    input.vertexAttributeDescriptionCount = each->wide ? 3 : 1;
    input.pVertexAttributeDescriptions = attributes;

    memset(&assembly, 0, sizeof assembly);
    assembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

    memset(&viewport, 0, sizeof viewport);
    viewport.width = (float)WIDTH;
    viewport.height = (float)HEIGHT;
    viewport.maxDepth = 1.0f;
    memset(&scissor, 0, sizeof scissor);
    scissor.extent.width = WIDTH;
    scissor.extent.height = HEIGHT;
    memset(&viewports, 0, sizeof viewports);
    viewports.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    viewports.viewportCount = 1;
    viewports.pViewports = &viewport;
    viewports.scissorCount = 1;
    viewports.pScissors = &scissor;

    memset(&raster, 0, sizeof raster);
    raster.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    raster.polygonMode = VK_POLYGON_MODE_FILL;
    raster.cullMode = VK_CULL_MODE_NONE;
    raster.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
    raster.lineWidth = 1.0f;

    memset(&samples, 0, sizeof samples);
    samples.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    samples.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    samples.minSampleShading = 1.0f;

    memset(&blending, 0, sizeof blending);
    blending.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                              VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
    memset(&blend, 0, sizeof blend);
    blend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    blend.attachmentCount = 1;
    blend.pAttachments = &blending;

    memset(&layout_how, 0, sizeof layout_how);
    layout_how.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    if (set_layout) {
        layout_how.setLayoutCount = 1;
        layout_how.pSetLayouts = set_layout;
    }
    if (!oh(vkCreatePipelineLayout(device, &layout_how, NULL, &layout), "the pipeline's layout")) goto done;

    memset(&pipeline_how, 0, sizeof pipeline_how);
    pipeline_how.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    pipeline_how.stageCount = 2;
    pipeline_how.pStages = stages;
    pipeline_how.pVertexInputState = &input;
    pipeline_how.pInputAssemblyState = &assembly;
    pipeline_how.pViewportState = &viewports;
    pipeline_how.pRasterizationState = &raster;
    pipeline_how.pMultisampleState = &samples;
    pipeline_how.pColorBlendState = &blend;
    pipeline_how.layout = layout;
    pipeline_how.renderPass = bench->pass;
    pipeline_how.subpass = 0;
    if (!oh(vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &pipeline_how, NULL, &pipeline),
            "the pipeline")) goto done;

    if (!oh(vkResetCommandBuffer(bench->command, 0), "the command buffer again")) goto done;
    memset(&begin, 0, sizeof begin);
    begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    if (!oh(vkBeginCommandBuffer(bench->command, &begin), "recording")) goto done;
    memset(&clear, 0, sizeof clear);
    for (k = 0; k < 4; k++) clear.color.float32[k] = backdrop[k];
    memset(&pass_begin, 0, sizeof pass_begin);
    pass_begin.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    pass_begin.renderPass = bench->pass;
    pass_begin.framebuffer = bench->frame;
    pass_begin.renderArea.extent.width = WIDTH;
    pass_begin.renderArea.extent.height = HEIGHT;
    pass_begin.clearValueCount = 1;
    pass_begin.pClearValues = &clear;
    vkCmdBeginRenderPass(bench->command, &pass_begin, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdBindPipeline(bench->command, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    if (set)
        vkCmdBindDescriptorSets(bench->command, VK_PIPELINE_BIND_POINT_GRAPHICS, layout, 0, 1,
                                set, 0, NULL);
    vkCmdBindVertexBuffers(bench->command, 0, 1, &bench->vertices, &nothing);
    vkCmdDraw(bench->command, 3, 1, 0, 0);
    vkCmdEndRenderPass(bench->command);
    memset(&copy, 0, sizeof copy);
    copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    copy.imageSubresource.layerCount = 1;
    copy.imageExtent.width = WIDTH;
    copy.imageExtent.height = HEIGHT;
    copy.imageExtent.depth = 1;
    vkCmdCopyImageToBuffer(bench->command, bench->image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                           bench->readback, 1, &copy);
    if (!oh(vkEndCommandBuffer(bench->command), "the recording")) goto done;

    if (!oh(vkResetFences(device, 1, &bench->fence), "the fence again")) goto done;
    memset(&submit, 0, sizeof submit);
    submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &bench->command;
    if (!oh(vkQueueSubmit(bench->queue, 1, &submit, bench->fence), "the submit")) goto done;
    if (!oh(vkWaitForFences(device, 1, &bench->fence, VK_TRUE, 5000000000ull), "the wait")) goto done;

    if (!oh(vkMapMemory(device, bench->readback_memory, 0, (VkDeviceSize)WIDTH * HEIGHT * 4, 0, &at),
            "the picture back")) goto done;
    pixels = at;
    for (y = 0; y < HEIGHT; y++) {
        for (x = 0; x < WIDTH; x++) {
            const unsigned char *got = pixels + ((size_t)y * WIDTH + (size_t)x) * 4;
            unsigned char want[4];
            double b[3];
            unsigned apart = 0;
            int inside, outside;

            if (!shares(each->corners, x, y, b)) continue;
            inside = b[0] > MARGIN && b[1] > MARGIN && b[2] > MARGIN;
            outside = b[0] < -MARGIN || b[1] < -MARGIN || b[2] < -MARGIN;
            if (!inside && !outside) continue;
            // The sampler's edge, for the reason TEXEL_MARGIN gives.
            if (inside && on_texel_edge(each, b)) continue;
            if (inside) {
                wanted(each, b, want);
            } else {
                for (k = 0; k < 4; k++) want[k] = (unsigned char)(backdrop[k] * 255.0 + 0.5);
            }
            for (k = 0; k < 4; k++) {
                int far = (int)got[k] - (int)want[k];
                if (far < 0) far = -far;
                if ((unsigned)far > apart) apart = (unsigned)far;
            }
            checked++;
            if (apart > worst) worst = apart;
            if (apart <= SLACK) continue;
            if (wrong == 0) {
                first_x = x;
                first_y = y;
                memcpy(first_got, got, 4);
                memcpy(first_want, want, 4);
            }
            wrong++;
        }
    }
    write_picture(driver, each->name, pixels);
    vkUnmapMemory(device, bench->readback_memory);
    printf("%-8s %-7s %lu pixels checked, %lu wrong, %u at worst\n", driver, each->name, checked, wrong, worst);
    if (wrong != 0) {
        printf("         the first at %d,%d reads %02X%02X%02X%02X, not %02X%02X%02X%02X\n",
               first_x, first_y, first_got[0], first_got[1], first_got[2], first_got[3],
               first_want[0], first_want[1], first_want[2], first_want[3]);
    }
    cases_run++;
    if (wrong != 0) cases_wrong++;
    ok = wrong == 0;

done:
    if (pipeline) vkDestroyPipeline(device, pipeline, NULL);
    if (layout) vkDestroyPipelineLayout(device, layout, NULL);
    if (fragment) vkDestroyShaderModule(device, fragment, NULL);
    if (vertex) vkDestroyShaderModule(device, vertex, NULL);
    return ok;
}

static void run_device(VkPhysicalDevice physical) {
    VkPhysicalDeviceProperties what;
    VkQueueFamilyProperties families[16];
    VkDeviceQueueCreateInfo queue_how;
    VkDeviceCreateInfo device_how;
    struct Bench bench;
    float one = 1.0f;
    uint32_t count = 16;
    uint32_t k;
    const char *driver;
    int at;

    vkGetPhysicalDeviceProperties(physical, &what);
    memset(&bench, 0, sizeof bench);
    bench.physical = physical;
    bench.family = UINT32_MAX;
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, families);
    for (k = 0; k < count; k++) {
        if (families[k].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
            bench.family = k;
            break;
        }
    }
    if (bench.family == UINT32_MAX) {
        printf("%s: no queue that draws\n", what.deviceName);
        return;
    }
    // A short, steady name for the lines below and for the pictures'
    // files: the device's own has blanks in it and says the model, which
    // is not what a reader of these lines wants to know.
    driver = vendor_named(what.vendorID);

    memset(&queue_how, 0, sizeof queue_how);
    queue_how.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    queue_how.queueFamilyIndex = bench.family;
    queue_how.queueCount = 1;
    queue_how.pQueuePriorities = &one;
    memset(&device_how, 0, sizeof device_how);
    device_how.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    device_how.queueCreateInfoCount = 1;
    device_how.pQueueCreateInfos = &queue_how;
    if (!oh(vkCreateDevice(physical, &device_how, NULL, &bench.device), what.deviceName)) {
        failed = 1;
        return;
    }
    vkGetDeviceQueue(bench.device, bench.family, 0, &bench.queue);
    printf("%s, API %u.%u.%u\n", what.deviceName, VK_VERSION_MAJOR(what.apiVersion),
           VK_VERSION_MINOR(what.apiVersion), VK_VERSION_PATCH(what.apiVersion));
    if (bench_up(&bench)) {
        for (at = 0; at < case_count; at++)
            if (!run_case(&bench, driver, &cases[at])) failed = 1;
    } else {
        failed = 1;
    }
    vkDeviceWaitIdle(bench.device);
    bench_down(&bench);
}

int main(int argc, char **argv) {
    VkApplicationInfo about;
    VkInstanceCreateInfo how;
    VkInstance instance = VK_NULL_HANDLE;
    VkPhysicalDevice physicals[8];
    VkResult result;
    uint32_t count = 8;
    uint32_t k;
    int at;

    for (at = 1; at < argc; at++) {
        if (strcmp(argv[at], "-o") == 0 && at + 1 < argc) {
            picture_dir = argv[++at];
        } else if (strcmp(argv[at], "-w") == 0 && at + 1 < argc) {
            const char *name = argv[++at];
            int found = 0;
            int which;

            for (which = 0; which < spoiling_count; which++) {
                if (strcmp(spoilings[which].name, name) != 0) continue;
                spoiling = spoilings[which].which;
                found = 1;
            }
            if (!found) {
                fprintf(stderr, "no spoiling called %s. There are:", name);
                for (which = 0; which < spoiling_count; which++)
                    fprintf(stderr, " %s", spoilings[which].name);
                fprintf(stderr, "\n");
                return 2;
            }
        } else {
            module_dir = argv[at];
        }
    }

    memset(&about, 0, sizeof about);
    about.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    about.pApplicationName = "facet-vulkan-check";
    about.apiVersion = VK_API_VERSION_1_0;
    memset(&how, 0, sizeof how);
    how.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    how.pApplicationInfo = &about;
    if (!oh(vkCreateInstance(&how, NULL, &instance), "no Vulkan instance")) return 2;
    // VK_INCOMPLETE says there are more than the eight there is room for,
    // which is eight more than this needs.
    result = vkEnumeratePhysicalDevices(instance, &count, physicals);
    if (result != VK_SUCCESS && result != VK_INCOMPLETE) {
        (void)oh(result, "no list of devices");
        vkDestroyInstance(instance, NULL);
        return 2;
    }
    if (count == 0) {
        printf("no Vulkan device here: nothing drawn.\n");
        vkDestroyInstance(instance, NULL);
        return 0;
    }
    for (k = 0; k < count; k++) run_device(physicals[k]);
    vkDestroyInstance(instance, NULL);
    if (spoiling != spoil_none) {
        // Being told a lie, a run that finds nothing wrong has found out
        // something worse: that it is not looking at what it says it is.
        printf("%d devices, told %s: %d of %d cases caught it - %s\n", (int)count, spoiled_what(),
               cases_wrong, cases_run, cases_wrong > 0 ? "the check can fail" : "NOT CAUGHT");
        return cases_wrong > 0 ? 0 : 1;
    }
    printf("%d devices, %d cases each: %s\n", (int)count, case_count,
           failed ? "something is wrong" : "every pixel as the arithmetic says");
    return failed ? 1 : 0;
}
