// SPDX-License-Identifier: MPL-2.0
//! The ROM tags QEMU's AArch64 virt machine carries beyond the ones every
//! image has: the display driver for its virtio GPU and its ramfb, and
//! sound that plays into nothing - rta.library, the null sink and
//! audio.device - so a program that plays runs as it would on a board, and
//! the file sink, which plays into a WAV file.

pub const modules = .{
    @import("../../rom/libs/rtg_driver/fbboard/fbboard.zig"),
    @import("../../rom/libs/rta/rta.zig"),
    @import("../../rom/libs/rta_driver/null/null.zig"),
    @import("../../rom/libs/rta_driver/file/file.zig"),
    @import("../../rom/devs/audio/audio.zig"),
};
