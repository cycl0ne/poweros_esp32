// SPDX-License-Identifier: MPL-2.0
//! The framebuffer the firmware set up and left running
//! (CHIP_UEFI_FB): the one display here with no hardware of its own.
//!
//! A machine started by UEFI firmware reaches the kernel with a picture
//! already on the glass. The firmware chose a mode on whatever is plugged
//! in, lit it, and said where the pixels are, how far apart the rows are
//! and what a pixel looks like; the stub passes that on
//! (`src/boot/uefi/handover.zig`) and the kernel writes it into the
//! board's description as this part. So there is nothing to drive here -
//! no controller, no mode set, no register written - and nothing to probe
//! either: what the firmware said is all there is to know, and where it
//! said nothing the part is not there at all.
//!
//! **The address cannot be moved.** Every other display this driver has
//! is told where to read, so showing a buffer is naming its address; this
//! one reads the buffer the firmware gave it and nothing here can tell it
//! otherwise. So the picture is copied into it: the whole of it when
//! another buffer is shown, and a rectangle alone when the buffer shown
//! is refreshed - which is what the virtio GPU does with its copy in the
//! emulator, and the reason that kind rather than the ramfb's is the one
//! this follows. The copying is `fbboard.zig`'s, which holds the pictures
//! and the engine that moves them.
//!
//! **The memory is the display's, not the machine's.** It is never handed
//! to exec, and the kernel's map has it write-combining
//! (`src/arch/x64uefi/mmu.zig`): the writes are gathered into whole
//! bursts, which is what a picture written once and read every frame
//! wants, and nothing has to be written back out of a cache.

/// The framebuffer, as the firmware set it up.
pub const Framebuffer = struct {
    /// Where the firmware's picture is.
    pixels: usize,
    /// Bytes from the start of one row to the start of the next, which is
    /// not always the width.
    pitch: u32,
    width: u32,
    height: u32,
    /// Bytes a pixel.
    bytes: u32,

    /// Where row `y` of it starts.
    pub fn row(fb: Framebuffer, y: u32) [*]u8 {
        const first: [*]u8 = @ptrFromInt(fb.pixels);
        return first + y * fb.pitch;
    }
};

/// The framebuffer the board's panel part describes. Null where the
/// firmware lit none - a machine started with no display - or where what
/// it said of it does not hold together, which is a firmware to be
/// believed about nothing else either.
pub fn find(address: usize, pitch: u32, width: u32, height: u32, bytes: u32) ?Framebuffer {
    if (address == 0 or width == 0 or height == 0 or bytes == 0) return null;
    if (pitch < width * bytes) return null;
    return .{
        .pixels = address,
        .pitch = pitch,
        .width = width,
        .height = height,
        .bytes = bytes,
    };
}
