// SPDX-License-Identifier: MIT
//! A shader module: the entries of a `shader.Code`, copied, the functions
//! they name the program's.

const std = @import("std");
const sdk = @import("sdk");
const facet = sdk.facet;
const shader = facet.shader;
const Device = @import("../device/_device.zig").Device;

pub const ShaderModule = struct {
    device: *Device,
    count: u32,

    /// Its entries, which follow it.
    pub fn entries(module: *const ShaderModule) []const shader.Entry {
        const first: [*]const shader.Entry = @ptrFromInt(@intFromPtr(module) + @sizeOf(ShaderModule));
        return first[0..module.count];
    }
};

/// The module's entry for `stage` called `name`, or null.
pub fn find(module: *const ShaderModule, stage: u32, name: [*:0]const u8) ?*const shader.Entry {
    for (module.entries()) |*entry| {
        if (entry.stage == stage and std.mem.orderZ(u8, entry.name, name) == .eq) return entry;
    }
    return null;
}
