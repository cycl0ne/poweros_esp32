// SPDX-License-Identifier: MIT
//! CmdUpdateBuffer: bytes written into a buffer, kept with the command.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");
const Buffer = @import("../buffer/_buffer.zig").Buffer;

/// The most bytes one of these writes, as Vulkan has it.
pub const most_update_bytes: u64 = 65536;

/// Recorded: bytes written into a buffer, kept with the command.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdUpdateBuffer(base: *FacetBase, buffer: *facet.CommandBuffer, destination: *facet.Buffer, offset: u64, size: u64, data: *const anyopaque) void
/// ```
///
/// SINCE: 1.27. LVO -440.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `destination` - the buffer written.
/// - `offset` - where the bytes go, a multiple of four.
/// - `size` - how many, a multiple of four and at most 65536
///   (`most_update_bytes`).
/// - `data` - the bytes, read as the command is recorded.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The bytes are copied into the command buffer as this is recorded, so
/// what `data` points at may go as soon as it returns. A `size` over
/// `most_update_bytes` records nothing. Played, a run that lies past the
/// end of the buffer is left out and said to be in the log.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The bytes become the command buffer's own. The destination has to last
/// until the work is done.
///
/// NOTES:
/// For a small write this takes a staging buffer, a map and a submit out of
/// the way; the bytes travel in the command buffer instead, which is why
/// there is a limit on them.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdFillBuffer`, `CmdCopyBuffer`
///
/// EXAMPLES:
/// ```zig
/// const matrix: [16]f32 = transform;
/// fb.CmdUpdateBuffer(commands, uniforms.?, 0, @sizeOf(@TypeOf(matrix)), &matrix);
/// ```
pub fn CmdUpdateBuffer(base: *FacetBase, buffer: *facet.CommandBuffer, destination: *facet.Buffer, offset: u64, size: u64, data: *const anyopaque) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    if (size > most_update_bytes) return;
    const whole: u64 = size & ~@as(u64, 3);
    const bytes: [*]const u8 = @ptrCast(data);
    const command = _command.UpdateBuffer{
        .destination = _objects.of(Buffer, destination),
        .offset = offset & ~@as(u64, 3),
        .size = whole,
    };
    _command.record(made, command, u8, bytes[0..@intCast(whole)]);
}
