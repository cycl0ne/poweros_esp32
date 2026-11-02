// SPDX-License-Identifier: MIT
//! A sampler: how a texture bound beside it is sampled, settled when the
//! sampler is made.
//!
//! It is the one object of the library that a shader reads directly. What
//! CreateSampler was given becomes a `texture.Sampler` here, in the terms
//! the sampling itself is written in (`texture.sampleBy`), and a descriptor
//! written with the sampler holds the address of that field: a draw's
//! fragment function reaches it through `shader.Resources.samplerOf`. So a
//! sampler has to last as long as the sets that hold it are drawn with, and
//! nothing writes it while it does - every core samples through the same
//! one at once.

const sdk = @import("sdk");
const facet = sdk.facet;
const texture = facet.texture;
const Device = @import("../device/_device.zig").Device;

pub const Sampler = struct {
    device: *Device,
    /// What the sampling reads: the address a descriptor holds.
    kept: texture.Sampler,
};

/// A filter as the sampling has it.
pub fn filterOf(filter: facet.Filter) ?texture.Filter {
    return switch (filter) {
        .nearest => .nearest,
        .linear => .bilinear,
        else => null,
    };
}

/// An address mode as the sampling has it; null for one it has not got.
pub fn wrapOf(mode: facet.SamplerAddressMode) ?texture.Wrap {
    return switch (mode) {
        .repeat => .repeat,
        .mirrored_repeat => .mirrored_repeat,
        .clamp_to_edge => .clamp_to_edge,
        .clamp_to_border => .clamp_to_border,
        else => null,
    };
}

/// A compare operation as the sampling has it. `never` is Vulkan's, and
/// means a shadow sample that nothing passes; `none` here is an ordinary
/// sample of the colour, which `compare_enable` being false asks for.
pub fn compareOf(op: facet.CompareOp) ?texture.Compare {
    return switch (op) {
        .never => .never,
        .less => .less,
        .equal => .equal,
        .less_or_equal => .less_or_equal,
        .greater => .greater,
        .not_equal => .not_equal,
        .greater_or_equal => .greater_or_equal,
        .always => .always,
        else => null,
    };
}

/// What `clamp_to_border` reads, as 0xAARRGGBB; null for a colour there is
/// none of.
pub fn borderOf(color: facet.BorderColor) ?u32 {
    return switch (color) {
        .float_transparent_black, .int_transparent_black => 0x0000_0000,
        .float_opaque_black, .int_opaque_black => 0xFF00_0000,
        .float_opaque_white, .int_opaque_white => 0xFFFF_FFFF,
        else => null,
    };
}
