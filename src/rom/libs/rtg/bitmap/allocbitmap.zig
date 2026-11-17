// SPDX-License-Identifier: MPL-2.0
//! AllocBitMap: A buffer in the board's display memory, its rows
//! aligned as the board asks.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const bm_flags = rtg.bitmaps;
const boards = @import("../board/_board.zig");

/// Makes a buffer in a board's display memory.
///
/// SYNOPSIS:
/// ```zig
/// fn AllocBitMap(rb: *RtgBase, board: *rtg.RtgBoard, width: u32, height: u32, format: u32, flags: u32) ?*rtg.RtgBitMap
/// ```
///
/// SINCE: 1.0. LVO -44.
///
/// INPUTS:
/// - `board` - the board, in a mode or not: a buffer is the board's, not a
///   mode's, and keeps its memory when the mode changes.
/// - `width` - its width, in pixels.
/// - `height` - its height.
/// - `format` - its pixel format.
/// - `flags` - `RTGBMF_DISPLAYABLE` for a buffer the board can show.
///
/// RESULT:
/// The buffer, or null: for a size of 0, a format this build does not
/// know, a board with no display memory, or no room - in the display
/// memory, in the system's, or because the board holds as many buffers as
/// it may.
///
/// BEHAVIOR:
/// Every row starts on the board's alignment, so a stretch of rows handed
/// to `RefreshRect` is exactly the memory that was written. On a board
/// whose display memory is system memory (`RTGRF_SYSTEM_MEMORY`) the
/// buffer is taken from exec now, external memory first, and given back by
/// `FreeBitMap`; its pixels are whatever that memory held. Its first
/// seven fields are a drawing surface: pixels, width, height, pitch, size
/// and format.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the board's lock - through a
///   show, which may last a frame.
/// - Interrupts: no. It allocates.
/// - Locks: takes the board's lock around the board's display memory and
///   its list of buffers. No spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's until `FreeBitMap`. Its pixels are the board's display
/// memory.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FreeBitMap`, `AttachBitMap`, `ShowBitMap`
///
/// EXAMPLES:
/// ```zig
/// const buffer = rb.AllocBitMap(board, 1024, 600, @intFromEnum(rtg.PixelFormat.rgb565), rtg.bitmaps.RTGBMF_DISPLAYABLE) orelse return error.NoMemory;
/// ```
pub fn AllocBitMap(rb: *RtgBase, board: *rtg.RtgBoard, width: u32, height: u32, format: u32, flags: u32) ?*rtg.RtgBitMap {
    const sys = rb.sys_base;
    const private = boards.privateOf(board);

    if (width == 0 or height == 0) {
        return null;
    }
    // No bytes a row is a format this build does not know, a number no
    // format has included.
    const row = rb.iface().RtgRowBytes(format, width);
    if (row == 0) return null;
    const pixel_format: rtg.PixelFormat = @enumFromInt(format);

    boards.obtain(rb, board);
    defer boards.release(rb, board);
    // A board with no display memory is asked for nothing.
    if (!private.arena.usable()) {
        return null;
    }
    // Every row starts on the board's alignment, so a stretch of rows
    // handed back with RefreshRect is exactly the memory that was
    // written and nothing either side of it.
    const pitch = private.arena.roundUp(row);
    const bytes = pitch * @as(usize, height);

    const memory = sys.AllocVec(@sizeOf(rtg.RtgBitMap), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        return null;
    };
    const bitmap: *rtg.RtgBitMap = @ptrCast(@alignCast(memory));
    bitmap.* = .{};

    const piece = private.arena.take(sys, bytes) orelse {
        sys.FreeVec(memory);
        return null;
    };

    bitmap.pixels = @ptrFromInt(piece.pixels);
    bitmap.width = width;
    bitmap.height = height;
    bitmap.pitch = @truncate(pitch);
    bitmap.size_bytes = bytes;
    bitmap.format = pixel_format;
    bitmap.flags = flags | bm_flags.PIXMAPF_MEMORY | bm_flags.RTGBMF_BOARD_MEMORY;
    if (board.region.flags & rtg.boards.RTGRF_CPU_CACHED != 0) bitmap.flags |= bm_flags.RTGBMF_CACHED;
    bitmap.board = @ptrCast(board);
    bitmap.offset = piece.offset;
    bitmap.taken = piece.taken;
    bitmap.node.type = .graphics;

    sys.AddTail(&board.bitmaps, &bitmap.node);
    return bitmap;
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const testing = fixture.testing;

test "a buffer: a format that is none, and a board with no display memory" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);

    // A number past every format is refused as a format not known.
    const board = try fixture.makeBoard(rb);
    try testing.expect(fixture.base(rb).AllocBitMap(board, 8, 8, 256, 0) == null);
    try testing.expect(fixture.base(rb).AllocBitMap(board, 8, 8, ~@as(u32, 0), 0) == null);
    fixture.driverBase(rb).DeleteBoard(board);

    // A board that reports no display memory says so, and no memory was
    // taken for the buffer's handle: the leak check holds that.
    fk.region_size = 0;
    const dark = try fixture.makeBoard(rb);
    try testing.expect(fixture.base(rb).AllocBitMap(dark, 8, 8, format, 0) == null);
    fixture.driverBase(rb).DeleteBoard(dark);
    try fixture.tearDown(rb);
}
