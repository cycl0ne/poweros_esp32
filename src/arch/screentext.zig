// SPDX-License-Identifier: MPL-2.0
//! The kernel's lines on the screen the firmware lit, for as long as
//! nothing else owns it.
//!
//! A machine started by UEFI need have no serial port at all - most
//! machines made for the last ten years have none - and then the raw port
//! writes into nothing and a boot that stops says nothing at all. The
//! screen is the one output such a machine certainly has: the firmware
//! lit it, the stub wrote the firmware's console on it, and the pixels
//! stay where they are until something draws over them.
//!
//! So this is a second place for exec's raw output (`exec.RawIOHardware`,
//! as a mirror): every line the kernel writes is drawn here as well as
//! written to the port, from the moment the kernel knows where the
//! framebuffer is until the display driver has the screen - the kernel
//! takes the mirror away again once the cold-start modules have run, so
//! that nothing is drawn over the picture.
//!
//! **The letters are the system's own**, at 8 by 8 (`pospaz8`): the font
//! is in the image already, and taking the data rather than a second copy
//! of it means the machine's first lines are set in the same letters as
//! everything after them.
//!
//! **White on black, which every order of pixels agrees on.** What the
//! firmware left stands until the kernel has a line of its own to put
//! there, so a machine that stops before the kernel writes anything still
//! shows what the stub said; then the screen is cleared once and is the
//! kernel's.
//!
//! **A full screen keeps its newer half.** The rows are kept as text as
//! well as drawn, and a screen with no room left is written again from
//! that text with its lower half at the top - so the line a boot stopped
//! on is always on the screen, with what led to it above. The picture is
//! never read back to be moved: reading a framebuffer whose writes are
//! gathered is slow enough that scrolling by the pixel would hold the
//! boot up, while writing it again from the text costs one screenful of
//! writes for every half screen of lines.
//!
//! **A line at a time, each core its own.** Cores write to the raw port
//! as the characters come, and a boot where one core starts another has
//! two of them writing at once; on a port that leaves the characters
//! mixed and on a screen it would leave them unreadable. So each core
//! fills a line of its own and a line is drawn whole, which is the one
//! place a reader needs it: the line that says what went wrong is the
//! line a core wrote while another was saying something else.

const cpu = @import("cpu.zig");
const exec = @import("../../rom/libs/exec/exec.zig");
const font = @import("../../rom/libs/graphics/fonts/pospaz8.zig");
const handover = @import("../../boot/uefi/handover.zig");

/// A character's cell, in pixels. The font is eight wide and eight tall,
/// and a row of pixels between lines keeps them apart.
const cell_wide = 8;
const cell_high = font.FONT_HEIGHT + 1;

/// What is written and what is written over. A mono picture is the one
/// thing both orders of pixels agree on, so nothing here asks which way
/// round the colours are.
const ink: u32 = 0x00ff_ffff;
const paper: u32 = 0x0000_0000;

/// The screen, while there is one: where its pixels are and how far apart
/// its rows are. `pixels` null means no screen was handed over, and then
/// nothing is drawn.
var pixels: ?[*]volatile u32 = null;
var wide: u32 = 0;
var high: u32 = 0;
var row_pixels: u32 = 0;
/// What fits: characters across, rows down.
var columns: u32 = 0;
var rows_fit: u32 = 0;

/// The rows on the screen, as text, and how many of them are filled. The
/// text is what the screen is written again from.
const rows_most = 128;
var shown: [rows_most][line_longest]u8 = undefined;
var shown_len: [rows_most]u32 = @splat(0);
var rows_used: u32 = 0;
/// Whether what the firmware left has been cleared, which is done once,
/// at the kernel's first line.
var cleared = false;

/// The screen the firmware lit, as the stub described it. A format the
/// stub did not know is one nothing is drawn in: the pixels would be the
/// wrong size.
/// Whether there is one, which is whether anything is drawn.
pub fn take(screen: handover.Framebuffer) bool {
    if (screen.base == 0 or screen.format == .unknown) return false;
    if (screen.width < cell_wide or screen.height < cell_high) return false;
    pixels = @ptrFromInt(@as(usize, @intCast(screen.base)));
    wide = screen.width;
    high = screen.height;
    row_pixels = screen.stride;
    columns = @min(wide / cell_wide, @as(u32, line_longest));
    rows_fit = @min(high / cell_high, @as(u32, rows_most));
    rows_used = 0;
    cleared = false;
    return true;
}

/// The screen taken again from the top, with what is on it left where it
/// is: the rows written from here on go over it one line at a time. For
/// a machine that has the screen back after something else drew on it.
pub fn restart() void {
    rows_used = 0;
}

/// Text put on the screen as it stands, without the log's own marks: what
/// was logged while the screen was somebody else's.
pub fn show(text: []const u8) void {
    for (text) |character| put(character);
}

/// How many rows of text the screen holds at once.
pub fn rows() u32 {
    return rows_fit;
}

/// How many of them are written, counted from the last `take`, `restart`
/// or `turn`.
pub fn rowsWritten() u32 {
    return rows_used;
}

/// The next page: the screen cleared and written again from its top row.
/// For text that is read off the screen rather than scrolled past, where
/// a page is held long enough to be read and then turned.
pub fn turn() void {
    clearAll();
    rows_used = 0;
}

/// What exec's raw output is mirrored to while the screen is the kernel's.
pub const hardware: exec.RawIOHardware = .{ .init = start, .put = put, .get = get };

/// The screen is lit already: there is nothing to set up.
fn start() void {}

/// Nothing is typed on a screen.
fn get() ?u8 {
    return null;
}

/// A line being written, one for each core there is room for: a core
/// past them shares the first, which is the mixing this is here to avoid
/// but on a machine with more cores than any has yet had.
const lines_most = 32;
const line_longest = 256;
var lines: [lines_most][line_longest]u8 = undefined;
var filled: [lines_most]u32 = @splat(0);

/// Held while a line is drawn, so that two cores' lines do not land in
/// the same place. A core that waits too long draws anyway: a core that
/// stopped holding this must not take the machine's last words with it.
var drawing: u32 = 0;
const waits_most = 10_000_000;

fn lock() void {
    var waited: u32 = 0;
    while (@cmpxchgWeak(u32, &drawing, 0, 1, .acquire, .monotonic) != null) {
        waited += 1;
        if (waited > waits_most) return;
    }
}

fn unlock() void {
    @atomicStore(u32, &drawing, 0, .release);
}

/// One character into this core's line, which is drawn when the line ends
/// or fills.
fn put(character: u8) void {
    if (pixels == null) return;
    const core = @min(cpu.coreId(), lines_most - 1);
    switch (character) {
        // A line ends where the writer says it does; the carriage return
        // before it is the port's business, not a screen's.
        '\r' => {},
        '\n' => flush(core),
        // What has no glyph of its own and no place on a line of text is
        // left out rather than drawn as the stand-in.
        0, '\t' => {},
        else => {
            if (filled[core] == line_longest) flush(core);
            lines[core][filled[core]] = character;
            filled[core] += 1;
        },
    }
}

/// This core's line on the screen, and the line emptied. One longer than
/// the screen is wide goes on as many rows as it takes, rather than over
/// the edge: a line of ranges is worth having whole.
fn flush(core: usize) void {
    const length = filled[core];
    filled[core] = 0;
    if (length == 0) return;
    lock();
    defer unlock();
    // The firmware's lines stand until here: the kernel has something to
    // say now, and the screen is its own from this line on.
    if (!cleared) {
        clearAll();
        cleared = true;
    }
    var at: u32 = 0;
    while (at < length) {
        const takes = @min(length - at, columns);
        putRow(lines[core][at..][0..takes]);
        at += takes;
    }
}

/// One row of text kept and drawn; a screen with no room left keeps its
/// newer half first.
fn putRow(text: []const u8) void {
    if (rows_used >= rows_fit) scroll();
    const which = rows_used;
    rows_used += 1;
    @memcpy(shown[which][0..text.len], text);
    shown_len[which] = @intCast(text.len);
    drawRow(which);
}

/// The screen written again with its lower half at the top, and the rest
/// of it empty: the newest rows stay, the oldest go.
fn scroll() void {
    const keep = @max(rows_fit / 2, 1);
    const from = rows_fit - keep;
    var which: u32 = 0;
    while (which < keep) : (which += 1) {
        shown[which] = shown[from + which];
        shown_len[which] = shown_len[from + which];
    }
    rows_used = keep;
    clearAll();
    which = 0;
    while (which < keep) : (which += 1) drawRow(which);
}

/// Row `which` on the screen: its own height cleared across the whole
/// width, then its characters.
fn drawRow(which: u32) void {
    const y = which * cell_high;
    clearRow(y);
    for (shown[which][0..shown_len[which]], 0..) |character, column| {
        draw(character, @as(u32, @intCast(column)) * cell_wide, y);
    }
}

/// One row's pixels, across the whole width.
fn clearRow(y: u32) void {
    const at = pixels orelse return;
    var line: u32 = 0;
    while (line < cell_high) : (line += 1) {
        const start_at = (y + line) * row_pixels;
        var x: u32 = 0;
        while (x < wide) : (x += 1) at[start_at + x] = paper;
    }
}

/// Every pixel of it.
fn clearAll() void {
    const at = pixels orelse return;
    var line: u32 = 0;
    while (line < high) : (line += 1) {
        const start_at = line * row_pixels;
        var x: u32 = 0;
        while (x < wide) : (x += 1) at[start_at + x] = paper;
    }
}

/// One character's glyph, its left edge at `x` and its top at `y`.
fn draw(character: u8, x: u32, y: u32) void {
    const at = pixels orelse return;
    const glyph = font.find(character) orelse &font.missing;
    var row: u32 = 0;
    while (row < font.FONT_HEIGHT) : (row += 1) {
        // A row of the glyph holds its leftmost pixel in the highest bit.
        var bits = glyph[row];
        const start_at = (y + row) * row_pixels + x;
        var column_in_cell: u32 = 0;
        while (column_in_cell < cell_wide) : (column_in_cell += 1) {
            at[start_at + column_in_cell] = if (bits & 0x8000 != 0) ink else paper;
            bits <<= 1;
        }
    }
}
