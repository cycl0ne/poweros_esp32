// SPDX-License-Identifier: MIT
//! facet.library: three-dimensional drawing as Vulkan has it, on the
//! machine's cores or on its GPU, on the disk in LIBS:. A program makes an
//! instance, finds a physical device - the cores, drawing through the
//! rasterizer (driver/cpu/raster/), and on a CM5 the V3D after them - makes
//! a device on it, allocates memory, binds
//! buffers and images into it, records command buffers and submits them to
//! the device's queue, whose task plays them: copies, and render passes
//! drawn by pipelines whose shaders are the program's own functions -
//! and shows what was drawn on a screen or in a window, through a
//! swapchain.
//!
//! The jump table is facet_lvo.zig, the ROM tag, the init and the
//! expunge facet_init.zig, the base facet_base.zig, how an object is made
//! and found from its handle _objects.zig. Each call is a file under its
//! area: `instance/` (`_instance.zig` the instance and its physical
//! device), `device/` (`_device.zig` the device and its queue),
//! `memory/` (`_memory.zig` the memory types and a block), `buffer/`
//! (`_buffer.zig`), `image/` (`_image.zig` an image, its layout and its
//! views), `render/` (`_render.zig` render passes and framebuffers),
//! `shader/` (`_shader.zig` shader modules), `descriptor/`
//! (`_descriptor.zig` set layouts, pools and sets), `pipeline/`
//! (`_pipeline.zig` pipeline layouts and pipelines), `command/`
//! (`_stream.zig` the bytes a command buffer records, `_command.zig` the
//! pool, the buffer and the commands), `queue/` (`_queue.zig` the queue's
//! task and its submissions), `sync/` (`_sync.zig` fences and
//! semaphores), `surface/` (`_surface.zig` a surface and what shows its
//! pictures, `screen.zig` a screen's, `window.zig` a window's) and
//! `swapchain/` (`_swapchain.zig` its images and where each of them is).
//!
//! What draws is a driver's, behind each physical device's table:
//! `driver/` (`_driver.zig` the table and the drivers there are), and
//! `driver/cpu/` the cores (`cpu.zig` their table, `_play.zig` how the
//! queue's task plays a command buffer, `_draw.zig` a draw, `raster/` the
//! rasterizer). `driver/v3d/` is the BCM2712's 3D core: `driver.zig` its
//! table, `_play.zig` a command buffer made into its control lists, and the
//! module `v3d.zig` what knows the hardware, which its test program
//! (c/test/v3d) uses too.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const facet_init = @import("facet_init.zig");

comptime {
    _ = &facet_init.facet_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const facet_library_tag = facet_init.facet_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{facet_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [facet_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = facet_init.LIBRARY_VERSION_STRING.*;
