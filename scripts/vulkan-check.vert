// SPDX-License-Identifier: MIT
// The vertex shader scripts/vulkan-check.sh builds for the fragment
// modules that want varyings facet's own vertex module does not hand on:
// the position as it is, a colour, and one float beside it.
//
// It writes more than `min_flat` and `min_interp` read, which Vulkan
// allows: an output nothing consumes is dropped, while an input nothing
// writes is not a pipeline at all.
#version 450

layout(location = 0) in vec4 position;
layout(location = 1) in vec4 colour;
layout(location = 2) in float light;

layout(location = 0) out vec4 carried_colour;
layout(location = 1) out float carried_light;

void main() {
    gl_Position = position;
    carried_colour = colour;
    carried_light = light;
}
