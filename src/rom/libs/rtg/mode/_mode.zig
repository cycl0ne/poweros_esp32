// SPDX-License-Identifier: MPL-2.0
//! A board's modes, as the library keeps them.
//!
//! A mode is a record of the library's own behind the board: what a
//! caller is handed of it (`rtg.RtgMode`, copied out), and the timings its
//! driver is given when the board is put in it. A driver adds a panel's
//! modes while it is offered the device (`AddBoardMode`); the record is
//! made here, named and numbered. The number is the board's own, counted
//! from 1 in the order the modes were made, and a mode added again with
//! the figures of one that is there is that one: its number stays.
//!
//! The list is in the order a caller is to read it: the larger picture
//! first, of one size the higher refresh, and of two alike the one made
//! first. One mode is the default - the one its driver marked, or else the
//! first made - and is what a wish that leaves everything open answers.
//!
//! A mode comes from one of two sides (`Origin`): its driver added it, or
//! the library made it of what a monitor names (`monitor/_monitor.zig`).
//! The monitor's are made again when the monitor changes. A mode that is
//! not offered any more leaves the list and is set aside, with its number
//! (`withdraw`): added again it comes back as the mode it was. The
//! driver's own stand while the monitor names none, and are set aside
//! while it does.
//!
//! A mode's name is its size ("1024x600"), with an "i" behind an
//! interlaced one, and with its refresh ("1024x600@75") where the board
//! has that size at more than one. A row of a buffer of the mode is the
//! width in its format, rounded up to what the board's buffers are
//! aligned to: the one figure `AllocBitMap` rounds by too, set once the
//! board has joined the list and its display memory is known.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const modes = rtg.modes;

const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");

/// Where a mode comes from.
pub const Origin = enum(u8) {
    /// Its driver added it (`AddBoardMode`).
    driver,
    /// The library made it of what the monitor names.
    monitor,
};

/// One mode of a board.
pub const Record = struct {
    /// Its place in the board's list, or among the modes set aside.
    node: exec.Node = .{},
    /// What a caller is handed, as a copy.
    mode: rtg.RtgMode = .{},
    /// What the driver is handed with it.
    timings: rtg.RtgTimings = .{},
    origin: Origin = .driver,
    /// Whether the board offers it: it is in the list, not set aside.
    offered: bool = true,
    /// Whether it was added as the default of its side.
    marked_default: bool = false,
};

/// The record a node of a board's mode list belongs to.
///
/// INPUTS:
/// - `node` - the record's node.
pub fn recordOf(node: *exec.Node) *Record {
    return @fieldParentPtr("node", node);
}

/// What of a mode's flags is its own figure, beside its size, format and
/// refresh: two modes that differ in one of these are two modes.
const kind_flags = modes.RTGMF_TURNED | modes.RTGMF_INTERLACED;

/// Frames a second of a timing, in thousandths: the pixel clock over
/// everything a frame costs, blanking and all. 0 for a timing with no
/// clock.
///
/// INPUTS:
/// - `timings` - the timing.
pub fn refreshOf(timings: *const rtg.RtgTimings) u32 {
    const line: u64 = @as(u64, timings.h_active) + timings.h_front + timings.h_sync + timings.h_back;
    const lines: u64 = @as(u64, timings.v_active) + timings.v_front + timings.v_sync + timings.v_back;
    const whole = line * lines;
    if (whole == 0 or timings.pixel_clock_hz == 0) return 0;
    const refresh = @as(u64, timings.pixel_clock_hz) * 1000 / whole;
    return if (refresh > 0xFFFF_FFFF) 0xFFFF_FFFF else @intCast(refresh);
}

/// Bytes a row of a buffer of `width` pixels in `format` has on `board`:
/// rounded up to what its display memory is aligned to. 0 until the board
/// has joined the list.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board.
/// - `format` - a pixel format this build knows.
/// - `width` - the width in pixels.
fn pitchOf(rb: *RtgBase, board: *rtg.RtgBoard, format: u32, width: u32) u32 {
    const private = boards.privateOf(board);
    if (!private.listed) return 0;
    return @truncate(private.arena.roundUp(rb.iface().RtgRowBytes(format, width)));
}

/// Every mode's row length set from the board's display memory, as it is
/// now: when the board joins the list, and when its driver replaced the
/// memory.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board, on the list.
pub fn setPitches(rb: *RtgBase, board: *rtg.RtgBoard) void {
    const private = boards.privateOf(board);
    var node = private.modes.first();
    while (node) |n| : (node = n.next()) {
        const record = recordOf(n);
        record.mode.pitch = pitchOf(rb, board, @intFromEnum(record.mode.format), record.mode.width);
    }
}

/// How many modes a board has.
///
/// INPUTS:
/// - `board` - the board.
pub fn count(board: *rtg.RtgBoard) u32 {
    var total: u32 = 0;
    var node = boards.privateOf(board).modes.first();
    while (node) |n| : (node = n.next()) total += 1;
    return total;
}

/// The mode of that number, or null.
///
/// INPUTS:
/// - `board` - the board.
/// - `id` - the mode's number.
pub fn byId(board: *rtg.RtgBoard, id: u32) ?*Record {
    var node = boards.privateOf(board).modes.first();
    while (node) |n| : (node = n.next()) {
        const record = recordOf(n);
        if (record.mode.id == id) return record;
    }
    return null;
}

/// The board's default mode, or null on a board with none.
///
/// INPUTS:
/// - `board` - the board.
pub fn defaultOf(board: *rtg.RtgBoard) ?*Record {
    var node = boards.privateOf(board).modes.first();
    while (node) |n| : (node = n.next()) {
        const record = recordOf(n);
        if (record.mode.flags & modes.RTGMF_DEFAULT != 0) return record;
    }
    return null;
}

/// Whether `value` is what a wish asks for: the figure itself, or
/// anything for RTG_ANY.
fn wished(wish: u32, value: u32) bool {
    return wish == modes.RTG_ANY or wish == value;
}

/// The mode of exactly that size, refresh and format, each left open by
/// RTG_ANY: the default where it is one of them, else the first of the
/// list. Null for none.
///
/// INPUTS:
/// - `board` - the board.
/// - `width`, `height` - the picture's size.
/// - `refresh_mhz` - the refresh, in milli-Hertz.
/// - `format` - the pixel format's number.
pub fn find(board: *rtg.RtgBoard, width: u32, height: u32, refresh_mhz: u32, format: u32) ?*Record {
    var first: ?*Record = null;
    var node = boards.privateOf(board).modes.first();
    while (node) |n| : (node = n.next()) {
        const record = recordOf(n);
        const mode = &record.mode;
        if (!wished(width, mode.width) or !wished(height, mode.height)) continue;
        if (!wished(refresh_mhz, mode.refresh_mhz) or !wished(format, @intFromEnum(mode.format))) continue;
        if (mode.flags & modes.RTGMF_DEFAULT != 0) return record;
        if (first == null) first = record;
    }
    return first;
}

/// How far a mode's refresh is from the one wished for.
fn refreshGap(wish: u32, mode: *const rtg.RtgMode) u32 {
    return if (mode.refresh_mhz > wish) mode.refresh_mhz - wish else wish - mode.refresh_mhz;
}

/// Whether `candidate` answers a wish better than `kept`, among modes of
/// one size: the refresh wished for or the nearest to it; with the
/// refresh left open the default, else the higher refresh.
fn betterRefresh(refresh_mhz: u32, candidate: *const rtg.RtgMode, kept: *const rtg.RtgMode) bool {
    if (refresh_mhz != modes.RTG_ANY) return refreshGap(refresh_mhz, candidate) < refreshGap(refresh_mhz, kept);
    if (kept.flags & modes.RTGMF_DEFAULT != 0) return false;
    if (candidate.flags & modes.RTGMF_DEFAULT != 0) return true;
    return candidate.refresh_mhz > kept.refresh_mhz;
}

/// Where a mode stands against a wished size: the size itself, one that
/// holds it, or one too small for it.
const Fit = enum(u8) { exact = 0, holds = 1, smaller = 2 };

fn fitOf(width: u32, height: u32, mode: *const rtg.RtgMode) Fit {
    const wide = width == modes.RTG_ANY or mode.width == width;
    const high = height == modes.RTG_ANY or mode.height == height;
    if (wide and high) return .exact;
    const holds_width = width == modes.RTG_ANY or mode.width >= width;
    const holds_height = height == modes.RTG_ANY or mode.height >= height;
    return if (holds_width and holds_height) .holds else .smaller;
}

/// The mode nearest a wish. Among the board's modes of the format wished
/// for - all of them where it has none of that format, or the format is
/// left open - one of that size if there is one, else the smallest that
/// holds it, else the largest; and of several of one size the refresh
/// nearest the one wished for. With the size left open, the default
/// mode's size. Null only on a board with no mode.
///
/// INPUTS:
/// - `board` - the board.
/// - `width`, `height` - the picture's size, or RTG_ANY.
/// - `refresh_mhz` - the refresh in milli-Hertz, or RTG_ANY.
/// - `format` - the pixel format's number, or RTG_ANY.
pub fn best(board: *rtg.RtgBoard, width: u32, height: u32, refresh_mhz: u32, format: u32) ?*Record {
    // Nothing said of the size: the default's, so that a wish for a
    // refresh or a format alone stays with the picture the board comes up
    // in.
    var wide = width;
    var high = height;
    if (width == modes.RTG_ANY and height == modes.RTG_ANY) {
        const usual = defaultOf(board) orelse return null;
        wide = usual.mode.width;
        high = usual.mode.height;
    }
    var kept: ?*Record = null;
    var node = boards.privateOf(board).modes.first();
    while (node) |n| : (node = n.next()) {
        const record = recordOf(n);
        const have = kept orelse {
            kept = record;
            continue;
        };
        if (nearer(wide, high, refresh_mhz, format, &record.mode, &have.mode)) kept = record;
    }
    return kept;
}

/// Whether `candidate` is nearer a wish than `kept`.
fn nearer(width: u32, height: u32, refresh_mhz: u32, format: u32, candidate: *const rtg.RtgMode, kept: *const rtg.RtgMode) bool {
    const formed = format == modes.RTG_ANY or @intFromEnum(candidate.format) == format;
    const kept_formed = format == modes.RTG_ANY or @intFromEnum(kept.format) == format;
    if (formed != kept_formed) return formed;
    const fit = fitOf(width, height, candidate);
    const kept_fit = fitOf(width, height, kept);
    if (fit != kept_fit) return @intFromEnum(fit) < @intFromEnum(kept_fit);
    const area = @as(u64, candidate.width) * candidate.height;
    const kept_area = @as(u64, kept.width) * kept.height;
    // Of those that hold the wish the smallest, of those too small the
    // largest.
    if (area != kept_area) return if (fit == .holds) area < kept_area else if (fit == .smaller) area > kept_area else false;
    return betterRefresh(refresh_mhz, candidate, kept);
}

/// `value` in decimal into `into` from `at`, as far as there is room;
/// where it ends.
fn writeNumber(into: []u8, at: usize, value: u32) usize {
    var digits: [10]u8 = undefined;
    var digit_count: usize = 0;
    var rest = value;
    while (true) {
        digits[digit_count] = @intCast('0' + rest % 10);
        digit_count += 1;
        rest /= 10;
        if (rest == 0) break;
    }
    var end = at;
    while (digit_count > 0 and end + 1 < into.len) {
        digit_count -= 1;
        into[end] = digits[digit_count];
        end += 1;
    }
    return end;
}

/// One character into `into` at `at`, where there is room; where it
/// ends.
fn writeChar(into: []u8, at: usize, char: u8) usize {
    if (at + 1 >= into.len) return at;
    into[at] = char;
    return at + 1;
}

/// A mode's name written: its size, an "i" behind an interlaced one, and
/// its refresh to the nearest Hertz where another mode of the board has
/// its size.
///
/// INPUTS:
/// - `board` - the board, for its other modes.
/// - `record` - the mode to name.
fn setName(board: *rtg.RtgBoard, record: *Record) void {
    const mode = &record.mode;
    var shared = false;
    var node = boards.privateOf(board).modes.first();
    while (node) |n| : (node = n.next()) {
        const other = &recordOf(n).mode;
        if (other == mode) continue;
        if (other.width != mode.width or other.height != mode.height) continue;
        if ((other.flags ^ mode.flags) & kind_flags != 0) continue;
        if (other.refresh_mhz != mode.refresh_mhz) shared = true;
    }
    mode.name = @splat(0);
    var at = writeNumber(&mode.name, 0, mode.width);
    at = writeChar(&mode.name, at, 'x');
    at = writeNumber(&mode.name, at, mode.height);
    if (mode.flags & modes.RTGMF_INTERLACED != 0) at = writeChar(&mode.name, at, 'i');
    if (shared) {
        at = writeChar(&mode.name, at, '@');
        at = writeNumber(&mode.name, at, (mode.refresh_mhz + 500) / 1000);
    }
    mode.name[at] = 0;
}

/// Every mode of the board named again: a mode that came or went may
/// have changed which sizes the board has at more than one refresh.
///
/// INPUTS:
/// - `board` - the board.
fn nameAll(board: *rtg.RtgBoard) void {
    var node = boards.privateOf(board).modes.first();
    while (node) |n| : (node = n.next()) setName(board, recordOf(n));
}

/// Whether `record` stands before `other` in the list: the larger
/// picture, and of one size the higher refresh.
fn before(record: *const Record, other: *const Record) bool {
    const area = @as(u64, record.mode.width) * record.mode.height;
    const other_area = @as(u64, other.mode.width) * other.mode.height;
    if (area != other_area) return area > other_area;
    return record.mode.refresh_mhz > other.mode.refresh_mhz;
}

/// `record` put in its place in the board's list: before the first mode
/// it stands before.
fn place(rb: *RtgBase, board: *rtg.RtgBoard, record: *Record) void {
    const private = boards.privateOf(board);
    var after: ?*exec.Node = null;
    var walk = private.modes.first();
    while (walk) |n| : (walk = n.next()) {
        if (before(record, recordOf(n))) break;
        after = n;
    }
    rb.sys_base.Insert(&private.modes, &record.node, after);
    record.offered = true;
}

/// The mode of these figures in one of the board's two lists, or null.
fn sameIn(list: *exec.List, timings: *const rtg.RtgTimings, format: u32, refresh_mhz: u32, kind: u32) ?*Record {
    var node = list.first();
    while (node) |n| : (node = n.next()) {
        const mode = &recordOf(n).mode;
        if (mode.width != timings.h_active or mode.height != timings.v_active) continue;
        if (@intFromEnum(mode.format) != format or mode.refresh_mhz != refresh_mhz) continue;
        if (mode.flags & kind_flags != kind) continue;
        return recordOf(n);
    }
    return null;
}

/// The default a board's modes have by themselves: the mode that was
/// added as it, else the first of the list. Null on a board with none.
///
/// INPUTS:
/// - `board` - the board.
pub fn ownDefault(board: *rtg.RtgBoard) ?*Record {
    const private = boards.privateOf(board);
    var walk = private.modes.first();
    while (walk) |n| : (walk = n.next()) {
        if (recordOf(n).marked_default) return recordOf(n);
    }
    return if (private.modes.first()) |first| recordOf(first) else null;
}

/// The default put on one mode of the list and taken from the others.
///
/// INPUTS:
/// - `board` - the board.
/// - `record` - the mode that is the default from now on; in the list.
pub fn setDefault(board: *rtg.RtgBoard, record: *Record) void {
    var walk = boards.privateOf(board).modes.first();
    while (walk) |n| : (walk = n.next()) recordOf(n).mode.flags &= ~modes.RTGMF_DEFAULT;
    record.mode.flags |= modes.RTGMF_DEFAULT;
}

/// A mode added to a board: its record made, numbered, put in its place
/// in the list and named - or, for the figures of a mode that is there or
/// was set aside, that mode given these timings and offered again. The
/// first mode a board is given is its default until one is added that
/// says it is.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board; its lock is held, or it is on no list yet.
/// - `timings` - the mode's timings; its picture is not empty.
/// - `format` - a pixel format this build knows.
/// - `flags` - RTGMF_DEFAULT, RTGMF_TURNED.
/// - `origin` - which side it comes from.
///
/// RESULT:
/// The mode's record, or null without memory.
pub fn add(rb: *RtgBase, board: *rtg.RtgBoard, timings: *const rtg.RtgTimings, format: u32, flags: u32, origin: Origin) ?*Record {
    const sys = rb.sys_base;
    const private = boards.privateOf(board);
    const refresh_mhz = refreshOf(timings);
    var kind = flags & modes.RTGMF_TURNED;
    if (timings.flags & modes.RTGTM_INTERLACED != 0) kind |= modes.RTGMF_INTERLACED;

    const made = sameIn(&private.modes, timings, format, refresh_mhz, kind) orelse made: {
        if (private.monitor) |state| {
            if (sameIn(&state.modes_aside, timings, format, refresh_mhz, kind)) |aside| {
                // Back as the mode it was: its number is still its own.
                sys.Remove(&aside.node);
                aside.mode.pitch = pitchOf(rb, board, format, timings.h_active);
                place(rb, board, aside);
                break :made aside;
            }
        }
        const memory = sys.AllocVec(@sizeOf(Record), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
        const new: *Record = @ptrCast(@alignCast(memory));
        new.* = .{};
        private.mode_serial += 1;
        new.mode = .{
            .id = private.mode_serial,
            .width = timings.h_active,
            .height = timings.v_active,
            .format = @enumFromInt(format),
            .pitch = pitchOf(rb, board, format, timings.h_active),
            .refresh_mhz = refresh_mhz,
            .flags = kind,
        };
        place(rb, board, new);
        break :made new;
    };
    made.origin = origin;
    made.timings = timings.*;
    made.mode.pixel_clock_hz = timings.pixel_clock_hz;

    const wants_default = flags & modes.RTGMF_DEFAULT != 0;
    if (wants_default) made.marked_default = true;
    if (wants_default or defaultOf(board) == null) setDefault(board, made);
    nameAll(board);
    board.info.modes = count(board);
    return made;
}

/// Every mode of one side taken out of the board's list and set aside,
/// with its number: the monitor's, as its list is made again; the
/// driver's own, while the monitor names modes. The mode the board is in
/// stays the board's, set aside or not.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board; its lock is held.
/// - `origin` - whose modes go.
pub fn withdraw(rb: *RtgBase, board: *rtg.RtgBoard, origin: Origin) void {
    const sys = rb.sys_base;
    const private = boards.privateOf(board);
    // Only a board with a connector has modes that go.
    const state = private.monitor orelse return;
    var node = private.modes.first();
    while (node) |n| {
        node = n.next();
        const record = recordOf(n);
        if (record.origin != origin) continue;
        sys.Remove(n);
        record.offered = false;
        record.mode.flags &= ~modes.RTGMF_DEFAULT;
        if (origin == .monitor) record.marked_default = false;
        sys.AddTail(&state.modes_aside, n);
    }
    // Which sizes the board has at more than one refresh may be other now.
    nameAll(board);
    board.info.modes = count(board);
}

/// The driver's own modes offered again, as it added them: taken back
/// from where they were set aside, the one it marked the default. How
/// many the board then has.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board; its lock is held.
pub fn restore(rb: *RtgBase, board: *rtg.RtgBoard) u32 {
    const sys = rb.sys_base;
    const private = boards.privateOf(board);
    var node = if (private.monitor) |state| state.modes_aside.first() else null;
    while (node) |n| {
        node = n.next();
        const record = recordOf(n);
        if (record.origin != .driver) continue;
        sys.Remove(n);
        record.mode.pitch = pitchOf(rb, board, @intFromEnum(record.mode.format), record.mode.width);
        place(rb, board, record);
    }
    // The default of what is offered now: the one marked, else the first.
    if (ownDefault(board)) |record| setDefault(board, record);
    nameAll(board);
    board.info.modes = count(board);
    return board.info.modes;
}

/// Every mode of a board freed, as the board itself goes.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board.
pub fn freeAll(rb: *RtgBase, board: *rtg.RtgBoard) void {
    const sys = rb.sys_base;
    const private = boards.privateOf(board);
    while (sys.RemHead(&private.modes)) |node| sys.FreeVec(recordOf(node));
    if (private.monitor) |state| {
        while (sys.RemHead(&state.modes_aside)) |node| sys.FreeVec(recordOf(node));
    }
    private.mode = null;
    board.info.modes = 0;
}
