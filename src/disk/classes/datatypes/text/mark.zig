// SPDX-License-Identifier: MIT
//! Marking a stretch of the text with the pointer, and what is marked
//! put on the clipboard.
//!
//! A press puts both ends of the mark where it landed; dragging moves
//! the far end; letting go leaves the mark standing. A press that never
//! moved marks nothing and, where it landed on a run that is a link,
//! leaves that link's name for the program to read.
//!
//! What is copied is a `FORM FTXT`, which is what everything that takes
//! text off the clipboard understands.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const gadgets = sdk.gadgets;
const iffparse = sdk.iffparse;
const datatypes = sdk.datatypes;
const tdc = datatypes.textclass;
const _text = @import("_text.zig");
const layout = @import("layout.zig");
const IFFParseBase = sdk.interface.iffparse.IFFParseBase;
const Data = _text.Data;
const Base = gadgets.Base;

/// Where in the text a place in the box falls: the nearest boundary
/// between two characters.
pub fn offsetAt(base: *Base, own: *Data, x: i32, y: i32) u32 {
    const lines = own.lines orelse return 0;
    const fragments = own.fragments orelse return 0;
    const pieces = own.pieces orelse return 0;
    if (own.line_count == 0) return 0;
    const line = lines[layout.lineAt(own, y)];
    if (line.count == 0) return endOfLine(own, line);

    var f: u32 = 0;
    while (f < line.count) : (f += 1) {
        const fragment = fragments[line.first + f];
        if (x >= fragment.left + fragment.width and f + 1 < line.count) continue;
        const piece = &pieces[fragment.piece];
        const into = x - fragment.left;
        if (into <= 0) return fragment.offset;
        // The character boundary nearest the place pressed.
        var best: u32 = 0;
        var n: u32 = 1;
        while (n <= fragment.length) : (n += 1) {
            const width = _text.widthOf(base, own, piece, fragment.offset, n);
            if (width > into) {
                const before = _text.widthOf(base, own, piece, fragment.offset, n - 1);
                best = if (into - before < width - into) n - 1 else n;
                return fragment.offset + best;
            }
        }
        return fragment.offset + fragment.length;
    }
    return endOfLine(own, line);
}

fn endOfLine(own: *const Data, line: _text.Line) u32 {
    if (line.count == 0) return 0;
    const last = own.fragments.?[line.first + line.count - 1];
    return last.offset + last.length;
}

/// The run a place in the box falls in, for a press that landed on a
/// link.
fn pieceAt(own: *Data, x: i32, y: i32) ?*const tdc.Piece {
    const lines = own.lines orelse return null;
    const fragments = own.fragments orelse return null;
    const pieces = own.pieces orelse return null;
    if (own.line_count == 0) return null;
    const line = lines[layout.lineAt(own, y)];
    var f: u32 = 0;
    while (f < line.count) : (f += 1) {
        const fragment = fragments[line.first + f];
        if (x >= fragment.left and x < fragment.left + fragment.width) return &pieces[fragment.piece];
    }
    return null;
}

/// A press taken, and the mark started where it landed.
pub fn press(base: *Base, own: *Data, x: i32, y: i32) void {
    const at = offsetAt(base, own, x, y);
    own.mark_from = at;
    own.mark_start = at;
    own.mark_end = at;
    own.dragging = 1;
    own.link[0] = 0;
}

/// The far end of the mark moved. Whether anything changed.
pub fn drag(base: *Base, own: *Data, x: i32, y: i32) bool {
    const at = offsetAt(base, own, x, y);
    const start = @min(own.mark_from, at);
    const end = @max(own.mark_from, at);
    if (start == own.mark_start and end == own.mark_end) return false;
    own.mark_start = start;
    own.mark_end = end;
    return true;
}

/// The press let go. A press that never moved marks nothing, and leaves
/// the link it landed on for the program to read.
pub fn release(own: *Data, x: i32, y: i32) void {
    own.dragging = 0;
    if (own.mark_start != own.mark_end) return;
    own.mark_start = 0;
    own.mark_end = 0;
    const piece = pieceAt(own, x, y) orelse return;
    if (piece.link_length == 0) return;
    const buffer = own.buffer orelse return;
    const length = @min(piece.link_length, own.link.len - 1);
    @memcpy(own.link[0..length], (buffer + piece.link_offset)[0..length]);
    own.link[length] = 0;
}

/// What is marked written to the clipboard as a `FORM FTXT`. Whether it
/// went.
pub fn copy(own: *Data, ip: *IFFParseBase) bool {
    const buffer = own.buffer orelse return false;
    const from = @min(own.mark_start, own.mark_end);
    const to = @min(@max(own.mark_start, own.mark_end), own.buffer_len);
    if (from >= to) return false;

    const iff = ip.AllocIFF() orelse return false;
    defer ip.FreeIFF(iff);
    const clip = ip.OpenClipboard(sdk.devices.clipboard.PRIMARY_CLIP) orelse return false;
    iff.stream = @intFromPtr(clip);
    ip.InitIFFasClip(iff);
    defer {
        ip.CloseClipboard(clip);
    }
    if (ip.OpenIFF(iff, iffparse.IFFF_WRITE) != 0) return false;
    defer ip.CloseIFF(iff);

    if (ip.PushChunk(iff, iffparse.MakeID("FTXT"), iffparse.ID_FORM, iffparse.IFFSIZE_UNKNOWN) != 0) return false;
    if (ip.PushChunk(iff, 0, iffparse.MakeID("CHRS"), @intCast(to - from)) != 0) return false;
    if (ip.WriteChunkBytes(iff, buffer + from, @intCast(to - from)) < 0) return false;
    _ = ip.PopChunk(iff);
    _ = ip.PopChunk(iff);
    return true;
}
