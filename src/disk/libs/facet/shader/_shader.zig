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
    /// How many entries ship their SPIR-V as well: `count`, or 0 where
    /// the program passed a plain `shader.Code` (since 1.75).
    spirv_count: u32 = 0,

    /// Its entries, which follow it.
    pub fn entries(module: *const ShaderModule) []const shader.Entry {
        const first: [*]const shader.Entry = @ptrFromInt(@intFromPtr(module) + @sizeOf(ShaderModule));
        return first[0..module.count];
    }

    /// The words beside the entries, which follow those, or nothing.
    pub fn spirv(module: *const ShaderModule) []const shader.Spirv {
        if (module.spirv_count == 0) return &.{};
        const after = @intFromPtr(module) + @sizeOf(ShaderModule) + module.count * @sizeOf(shader.Entry);
        const first: [*]const shader.Spirv = @ptrFromInt(after);
        return first[0..module.spirv_count];
    }

    /// The SPIR-V of the entry at `at`, or nothing. The words are the
    /// program's own memory and live as long as it keeps them there.
    pub fn wordsAt(module: *const ShaderModule, at: usize) []const u32 {
        const table = module.spirv();
        if (at >= table.len) return &.{};
        return table[at].module();
    }
};

/// Where the module's entry for `stage` called `name` is, or null. The
/// place and not the entry, because the words are found by it.
pub fn findAt(module: *const ShaderModule, stage: u32, name: [*:0]const u8) ?usize {
    for (module.entries(), 0..) |*entry, at| {
        if (entry.stage == stage and std.mem.orderZ(u8, entry.name, name) == .eq) return at;
    }
    return null;
}

/// The module's entry for `stage` called `name`, or null.
pub fn find(module: *const ShaderModule, stage: u32, name: [*:0]const u8) ?*const shader.Entry {
    const at = findAt(module, stage, name) orelse return null;
    return &module.entries()[at];
}
