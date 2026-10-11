// SPDX-License-Identifier: MIT
//! Text on the clipboard: what every program that copies or pastes text
//! does with iffparse.library.
//!
//! A text on the clipboard is a `FORM FTXT` holding the characters in
//! `CHRS` chunks. `writeText` puts one there, in one chunk; `readText`
//! hands back the characters of every `CHRS` chunk of the clip, one after
//! another, in memory of the caller's. Both work the primary clip
//! (`clipboard.PRIMARY_CLIP`) through `OpenClipboard` and wait for
//! clipboard.device, so they run on a task that may wait - a program's
//! own, or a method a program sent, as a datatype's `DTM_COPY` - and never
//! on intuition's input task.
//!
//!   const ip: *IFFParseBase = @ptrCast(sys.OpenLibrary(iffparse.IFFPARSENAME, 0) orelse return);
//!   defer sys.CloseLibrary(@ptrCast(ip));
//!   _ = iffparse.clip.writeText(ip, "Hello");
//!   if (iffparse.clip.readText(sys, ip)) |text| {
//!       defer sys.FreeVec(text.ptr);
//!       use(text);
//!   }

const iffparse = @import("iffparse.zig");
const exec = @import("../exec/exec.zig");
const clipboard = @import("../../devices/clipboard.zig");
const ExecBase = @import("../../interface/exec.zig").ExecBase;
const IFFParseBase = @import("../../interface/iffparse.zig").IFFParseBase;

pub const ID_FTXT = iffparse.MakeID("FTXT");
pub const ID_CHRS = iffparse.MakeID("CHRS");

/// `text` put on the clipboard as a `FORM FTXT` of one `CHRS` chunk.
/// Whether it went; an empty text is not put there.
pub fn writeText(ip: *IFFParseBase, text: []const u8) bool {
    if (text.len == 0) return false;
    const iff = ip.AllocIFF() orelse return false;
    defer ip.FreeIFF(iff);
    const clip = ip.OpenClipboard(clipboard.PRIMARY_CLIP) orelse return false;
    defer ip.CloseClipboard(clip);
    iff.stream = @intFromPtr(clip);
    ip.InitIFFasClip(iff);
    if (ip.OpenIFF(iff, iffparse.IFFF_WRITE) != 0) return false;
    defer ip.CloseIFF(iff);
    if (ip.PushChunk(iff, ID_FTXT, iffparse.ID_FORM, iffparse.IFFSIZE_UNKNOWN) != 0) return false;
    if (ip.PushChunk(iff, 0, ID_CHRS, @intCast(text.len)) != 0) return false;
    if (ip.WriteChunkBytes(iff, text.ptr, @intCast(text.len)) < 0) return false;
    _ = ip.PopChunk(iff);
    _ = ip.PopChunk(iff);
    return true;
}

/// The characters of every `CHRS` chunk of the clipboard's `FORM FTXT`,
/// one after another, in memory of their own for the caller to FreeVec;
/// null when the clip holds no text, or there was no memory for it.
pub fn readText(sys: *ExecBase, ip: *IFFParseBase) ?[]u8 {
    const iff = ip.AllocIFF() orelse return null;
    defer ip.FreeIFF(iff);
    const clip = ip.OpenClipboard(clipboard.PRIMARY_CLIP) orelse return null;
    defer ip.CloseClipboard(clip);
    iff.stream = @intFromPtr(clip);
    ip.InitIFFasClip(iff);
    if (ip.OpenIFF(iff, iffparse.IFFF_READ) != 0) return null;
    defer ip.CloseIFF(iff);
    if (ip.StopChunk(iff, ID_FTXT, ID_CHRS) != 0) return null;
    var length: usize = 0;
    var gathered: ?[*]u8 = null;
    // A clip is read once, front to back, so the text grows as the chunks
    // come.
    while (ip.ParseIFF(iff, iffparse.IFFPARSE_SCAN) == 0) {
        const chunk = ip.CurrentChunk(iff) orelse continue;
        if (chunk.id != ID_CHRS or chunk.size <= 0) continue;
        const size: usize = @intCast(chunk.size);
        const bigger: [*]u8 = @ptrCast(sys.AllocVec(length + size, exec.MEMF_ANY) orelse break);
        if (gathered) |old| {
            @memcpy(bigger[0..length], old[0..length]);
            sys.FreeVec(old);
        }
        gathered = bigger;
        if (ip.ReadChunkBytes(iff, bigger + length, chunk.size) != chunk.size) break;
        length += size;
    }
    const text = gathered orelse return null;
    if (length == 0) {
        sys.FreeVec(text);
        return null;
    }
    return text[0..length];
}
