// SPDX-License-Identifier: MIT
//! A pipeline layout, and a graphics pipeline: its functions and its
//! state, settled as it is made.
//!
//! What facet.library's pipelines draw:
//! - triangles - lists, strips and fans - filled, one sample a pixel;
//! - the vertex function's inputs read from up to four vertex buffers,
//!   an attribute a location, of floats or of bytes 0 to 1;
//! - culled by their facing, front or back or both;
//! - a depth test of any compare, the depth written or not, and no
//!   stencil;
//! - the colour written whole, replacing what is there or laid over it by
//!   its alpha (SRC_ALPHA, ONE_MINUS_SRC_ALPHA, ADD);
//! - one viewport and one scissor, given here or set by commands.
//!
//! Anything else is refused as the pipeline is made
//! (`error_feature_not_present`), rather than drawn otherwise than asked.

const std = @import("std");
const sdk = @import("sdk");
const facet = sdk.facet;
const shader = facet.shader;
const raster = @import("raster");
const Device = @import("../device/_device.zig").Device;
const _instance = @import("../instance/_instance.zig");

pub const PipelineLayout = struct {
    device: *Device,
    set_count: u32,
    push_size: u32,
};

/// Where a vertex buffer binding's data goes.
pub const Binding = struct {
    stride: u32 = 0,
    per_instance: bool = false,
};

/// Where a location's input is read from.
pub const Attribute = struct {
    location: u32,
    binding: u32,
    format: facet.Format,
    offset: u32,
};

pub const Pipeline = struct {
    device: *Device,
    vertex: shader.VertexFn,
    fragment: shader.FragmentFn,
    varyings: u32,
    /// The locations the vertex function's inputs take: the highest an
    /// attribute reads into, and one.
    locations: u32,
    bindings: [_instance.max_vertex_input_bindings]Binding,
    attributes: [_instance.max_vertex_input_attributes]Attribute,
    attribute_count: u32,
    topology: facet.PrimitiveTopology,
    /// An index of all ones ends a strip or a fan, and the next starts.
    restart: bool,
    /// Its draws draw nothing: the rasterizer is switched off, or every
    /// triangle is culled.
    draws_nothing: bool,
    cull: raster.Cull,
    front: raster.Winding,
    depth_test: ?raster.batched.Compare,
    depth_write: bool,
    blend: raster.Blend,
    /// The viewport and the scissor, or null where commands set them.
    viewport: ?facet.Viewport,
    scissor: ?facet.Rect2D,
};

/// The formats an attribute is read in.
pub fn attributeFormat(format: facet.Format) bool {
    return switch (format) {
        .r32_sfloat, .r32g32_sfloat, .r32g32b32_sfloat, .r32g32b32a32_sfloat, .r8g8b8a8_unorm, .b8g8r8a8_unorm => true,
        else => false,
    };
}

/// The value an attribute of `format` holds at `at`, as four floats, the
/// parts the format does not fill (0, 0, 0, 1).
pub fn decode(format: facet.Format, at: [*]const u8) [4]f32 {
    var value = [4]f32{ 0, 0, 0, 1 };
    switch (format) {
        .r32_sfloat, .r32g32_sfloat, .r32g32b32_sfloat, .r32g32b32a32_sfloat => {
            const count: usize = switch (format) {
                .r32_sfloat => 1,
                .r32g32_sfloat => 2,
                .r32g32b32_sfloat => 3,
                else => 4,
            };
            // An offset need not be aligned.
            for (value[0..count], 0..) |*part, k| part.* = @bitCast(std.mem.readInt(u32, at[k * 4 ..][0..4], .little));
        },
        .r8g8b8a8_unorm => for (&value, 0..) |*part, k| {
            part.* = @as(f32, @floatFromInt(at[k])) / 255;
        },
        .b8g8r8a8_unorm => for (&value, [4]usize{ 2, 1, 0, 3 }) |*part, k| {
            part.* = @as(f32, @floatFromInt(at[k])) / 255;
        },
        else => {},
    }
    return value;
}
