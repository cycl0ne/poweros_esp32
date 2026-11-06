// SPDX-License-Identifier: MIT
// The second vertex shader scripts/vulkan-check.sh builds, for the
// sampler modules. What it differs from vulkan-check.vert in is what
// location 0 carries: `min_tex` reads a vec2 coordinate there where
// `min_interp` reads a vec4 colour, and two fragment modules that
// disagree about a location cannot be given the same vertex shader.
//
// The colour goes out at location 1, which is where `min_texmod` reads
// it. `min_tex` reads only the coordinate: an output nothing consumes is
// dropped, while an input nothing writes is not a pipeline at all.
#version 450

layout(location = 0) in vec4 position;
layout(location = 1) in vec4 colour;
layout(location = 2) in vec2 uv;

layout(location = 0) out vec2 carried_uv;
layout(location = 1) out vec4 carried_colour;

void main() {
    gl_Position = position;
    carried_uv = uv;
    carried_colour = colour;
}
