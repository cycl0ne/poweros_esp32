// SPDX-License-Identifier: MPL-2.0
//! RehomeBitMap: A buffer given to another board, its handle the same.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const bm_flags = rtg.bitmaps;
const boards = @import("../board/_board.zig");

/// Gives a buffer to another board.
///
/// SYNOPSIS:
/// ```zig
/// fn RehomeBitMap(rb: *RtgBase, bitmap: *rtg.RtgBitMap, board: *rtg.RtgBoard) i32
/// ```
///
/// SINCE: 1.36. LVO -128.
///
/// INPUTS:
/// - `bitmap` - the buffer: one `AllocBitMap` or `AttachBitMap` made.
/// - `board` - the board it is to be a buffer of.
///
/// RESULT:
/// `RTGERR_OK`, also for a buffer that is that board's already;
/// `RTGERR_IN_USE` while its board shows it; `RTGERR_NO_DISPLAY` for a
/// board that is gone; `RTGERR_NO_MEMORY` where the board has no room
/// for it. On anything but `RTGERR_OK` the buffer is as it was.
///
/// BEHAVIOR:
/// The handle stays the buffer's, so whoever holds it - a RastPort, a
/// screen, a layer - holds a buffer of the new board from now on: the
/// new board shows it, its engine draws into it, and it counts against
/// that board's display memory.
///
/// Where the memory can go along it does: a buffer over memory of the
/// caller's (`AttachBitMap`), and one taken from the system's memory
/// for a board that reads its buffers from there, given to another such
/// board that aligns them alike and asks no other kind of memory. Then
/// nothing of the buffer moves or changes but whose it is.
///
/// Where it cannot - the new board cuts its buffers out of display
/// memory of its own, or aligns them otherwise - the pixels are copied
/// into memory of the new board's and the old memory is given back:
/// `pixels`, `pitch` and `size_bytes` of the handle are other than they
/// were. The caller sees to it that nothing draws into the buffer
/// meanwhile, and that nothing keeps a row's address over the call.
///
/// A buffer goes to another board when its own is gone, or is no
/// longer the one its owner shows on: intuition.library gives a
/// screen's buffers to the first board when a driver loaded from the
/// disk made another board the first.
///
/// CONTEXT:
/// - Waits: only while another task holds one of the two boards' locks.
/// - Interrupts: no.
/// - Locks: takes both boards' locks, the one at the lower address
///   first.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The buffer stays its owner's to free (`FreeBitMap`). Memory the
/// library took for it is the library's to give back; memory the caller
/// attached stays the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocBitMap`, `AttachBitMap`, `FreeBitMap`, `NextBoard`
///
/// EXAMPLES:
/// ```zig
/// // The picture goes with its owner to the machine's new display.
/// const first = rb.NextBoard(null).?;
/// if (rb.RehomeBitMap(picture, first) == rtg.errors.RTGERR_OK) {
///     _ = rb.ShowBitMap(first, picture);
/// }
/// ```
pub fn RehomeBitMap(rb: *RtgBase, bitmap: *rtg.RtgBitMap, board: *rtg.RtgBoard) i32 {
    const sys = rb.sys_base;
    const from: ?*rtg.RtgBoard = @ptrCast(@alignCast(bitmap.board));
    if (from == board) return err.RTGERR_OK;

    // Both boards' locks, always in the one order.
    const first = if (from) |old| (if (@intFromPtr(old) < @intFromPtr(board)) old else board) else board;
    const second: ?*rtg.RtgBoard = if (from) |old| (if (first == old) board else old) else null;
    boards.obtain(rb, first);
    defer boards.release(rb, first);
    if (second) |other| boards.obtain(rb, other);
    defer if (second) |other| boards.release(rb, other);

    if (boards.dark(board)) return err.RTGERR_NO_DISPLAY;
    if (bitmap.flags & bm_flags.RTGBMF_SHOWING != 0) return err.RTGERR_IN_USE;
    const to = boards.privateOf(board);

    const own = bitmap.flags & bm_flags.RTGBMF_BOARD_MEMORY != 0 and bitmap.pixels != null;
    if (own) {
        // Memory the library took: `from` is the board it was taken for.
        const old = boards.privateOf(from.?);
        if (!to.arena.usable()) return err.RTGERR_NO_MEMORY;
        const alike = old.arena.system and to.arena.system and
            old.arena.alignment == to.arena.alignment and to.arena.attributes & ~old.arena.attributes == 0;
        if (alike) {
            // The memory goes along: only who counts it changes.
            if (!to.arena.adopt(bitmap.taken)) return err.RTGERR_NO_MEMORY;
            old.arena.disown(bitmap.taken);
        } else {
            const row = rb.iface().RtgRowBytes(@intFromEnum(bitmap.format), bitmap.width);
            const pitch = to.arena.roundUp(row);
            const bytes = pitch * @as(usize, bitmap.height);
            const piece = to.arena.take(sys, bytes) orelse return err.RTGERR_NO_MEMORY;
            const source = bitmap.pixels.?;
            const target: [*]u8 = @ptrFromInt(piece.pixels);
            var y: usize = 0;
            while (y < bitmap.height) : (y += 1) {
                @memcpy(target[y * pitch ..][0..row], source[y * bitmap.pitch ..][0..row]);
            }
            old.arena.give(sys, bitmap.offset, bitmap.taken);
            bitmap.pixels = target;
            bitmap.pitch = @truncate(pitch);
            bitmap.size_bytes = bytes;
            bitmap.offset = piece.offset;
            bitmap.taken = piece.taken;
        }
        bitmap.flags &= ~@as(u32, bm_flags.RTGBMF_CACHED);
        if (board.region.flags & rtg.boards.RTGRF_CPU_CACHED != 0) bitmap.flags |= bm_flags.RTGBMF_CACHED;
    }
    if (from != null) sys.Remove(&bitmap.node);
    sys.AddTail(&board.bitmaps, &bitmap.node);
    bitmap.board = @ptrCast(board);
    return err.RTGERR_OK;
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const testing = fixture.testing;

test "a buffer given to another board: the memory along where it can go, the pixels copied where it cannot, the handle the same" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    // Two boards that take their buffers from the system's memory, and
    // one that cuts them out of display memory of its own.
    fk.system_memory = true;
    fk.region_size = 4096;
    const one = try fixture.makeDisplay(rb, 16, 16);
    const other = try fixture.makeDisplay(rb, 16, 16);
    fk.system_memory = false;
    fk.region_size = fixture.fake.region_bytes;
    const fixed = try fixture.makeDisplay(rb, 16, 16);

    const picture = fixture.base(rb).AllocBitMap(one, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    fixture.paint(picture, 5);
    const pixels = picture.pixels.?;
    const free_one = fixture.infoOf(rb, one).memory_free;
    const free_other = fixture.infoOf(rb, other).memory_free;
    const used = fixture.infoOf(rb, one).memory_total - free_one;
    try testing.expect(used != 0);

    // Shown, it is its board's.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(one, picture));
    try testing.expectEqual(rtg.errors.RTGERR_IN_USE, fixture.base(rb).RehomeBitMap(picture, other));
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(one, null));
    // To the board it is on: nothing to do.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).RehomeBitMap(picture, one));

    // To a board that reads the same memory: the memory goes along, and
    // each board counts what it holds.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).RehomeBitMap(picture, other));
    try testing.expectEqual(pixels, picture.pixels.?);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(other)), picture.board);
    try testing.expectEqual(free_one + used, fixture.infoOf(rb, one).memory_free);
    try testing.expectEqual(free_other - used, fixture.infoOf(rb, other).memory_free);
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, fixture.base(rb).ShowBitMap(one, picture));
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(other, picture));
    try testing.expectEqual(picture, fk.log.bands[0].bitmap);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(other, null));

    // To a board with display memory of its own: the pixels are copied
    // there, the handle is the same, and the old memory is given back.
    const free_fixed = fixture.infoOf(rb, fixed).memory_free;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).RehomeBitMap(picture, fixed));
    try testing.expect(picture.pixels.? != pixels);
    for (0..16) |y| {
        const row: [*]const u16 = @ptrCast(@alignCast(picture.pixels.? + y * picture.pitch));
        for (0..16) |x| try testing.expectEqual(fixture.painted(5, @intCast(x), @intCast(y)), row[x]);
    }
    try testing.expectEqual(free_other, fixture.infoOf(rb, other).memory_free);
    try testing.expect(fixture.infoOf(rb, fixed).memory_free < free_fixed);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(fixed, picture));
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(fixed, null));

    // A board with no room refuses, and the buffer stays where it is.
    fk.system_memory = true;
    fk.region_size = 64;
    const cramped = try fixture.makeDisplay(rb, 16, 16);
    try testing.expectEqual(rtg.errors.RTGERR_NO_MEMORY, fixture.base(rb).RehomeBitMap(picture, cramped));
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(fixed)), picture.board);

    // Memory of the caller's goes along as it is.
    var rows: [16 * 16]u16 align(64) = @splat(0);
    const described = rtg.RtgBitMap{ .pixels = @ptrCast(&rows), .width = 16, .height = 16, .pitch = 32, .size_bytes = 512, .format = .rgb565 };
    const attached = fixture.base(rb).AttachBitMap(one, &described).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).RehomeBitMap(attached, cramped));
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(cramped)), attached.board);
    try testing.expectEqual(@as(?[*]u8, @ptrCast(&rows)), attached.pixels);

    // A board that is gone takes none.
    fixture.driverBase(rb).RemRtgDevice(one.device.?);
    try testing.expectEqual(rtg.errors.RTGERR_NO_DISPLAY, fixture.base(rb).RehomeBitMap(attached, one));

    fixture.base(rb).FreeBitMap(attached);
    fixture.base(rb).FreeBitMap(picture);
    try fixture.tearDown(rb);
}
