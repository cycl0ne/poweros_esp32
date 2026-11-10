// SPDX-License-Identifier: MIT
//! Text on the clipboard: what every program that copies or pastes text
//! does with iffparse.library.
//!
//! A text on the clipboard is a `FORM FTXT` holding the characters in
//! `CHRS` chunks. `writeText` puts one there, in one chunk, after a
//! `CSET` chunk that says it is UTF-8 (106, IANA's number for it, as a
//! big-endian u32 and seven of 0 after it). `readText` hands back the
//! characters of every `CHRS` chunk of the clip, one after another, in
//! memory of the caller's, and always in UTF-8: a clip whose `CSET` says
//! Latin-1 (4) or code page 1252 (2252) is converted, and one with no
//! `CSET` is taken as UTF-8 when the whole of it is, else read as code
//! page 1252. Both work the primary clip
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
//!
//! A program that shows whether there is text to paste - a Paste button
//! disabled while there is none - keeps a `Watch`: it starts it once
//! (`start`), waits for `signal()` beside its window's, and asks
//! `holdsText` at the start and whenever the signal comes, which is each
//! time a clip is finished, by this program or another. It stops it before
//! it quits (`stop`), and the Watch stays where it is in between: the
//! device calls the hook inside it.
//!
//!   var watch: iffparse.clip.Watch = .{};
//!   watch.start(sys, ip);
//!   defer watch.stop();
//!   var can_paste = watch.holdsText();
//!   ...
//!   const got = sys.Wait(window_signal | watch.signal());
//!   if (got & watch.signal() != 0) can_paste = watch.holdsText();

const std = @import("std");
const iffparse = @import("iffparse.zig");
const exec = @import("../exec/exec.zig");
const clipboard = @import("../../devices/clipboard.zig");
const utility = @import("../utility/utility.zig");
const utf8 = @import("../utility/utf8.zig");
const ExecBase = @import("../../interface/exec.zig").ExecBase;
const IFFParseBase = @import("../../interface/iffparse.zig").IFFParseBase;

pub const ID_FTXT = iffparse.MakeID("FTXT");
pub const ID_CHRS = iffparse.MakeID("CHRS");
pub const ID_CSET = iffparse.MakeID("CSET");

/// The code sets a `CSET` names, by IANA's numbers.
pub const CSET_LATIN1: u32 = 4;
pub const CSET_UTF8: u32 = 106;
pub const CSET_CP1252: u32 = 2252;

/// `text`, UTF-8, put on the clipboard as a `FORM FTXT` of a `CSET`
/// that says so and one `CHRS` chunk. Whether it went; an empty text is
/// not put there.
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
    var code_set: [32]u8 = @splat(0);
    code_set[3] = CSET_UTF8;
    if (ip.PushChunk(iff, 0, ID_CSET, code_set.len) != 0) return false;
    if (ip.WriteChunkBytes(iff, &code_set, code_set.len) < 0) return false;
    _ = ip.PopChunk(iff);
    if (ip.PushChunk(iff, 0, ID_CHRS, @intCast(text.len)) != 0) return false;
    if (ip.WriteChunkBytes(iff, text.ptr, @intCast(text.len)) < 0) return false;
    _ = ip.PopChunk(iff);
    _ = ip.PopChunk(iff);
    return true;
}

/// The characters of every `CHRS` chunk of the clipboard's `FORM FTXT`,
/// one after another, in UTF-8 - converted from what its `CSET` names -
/// in memory of their own for the caller to FreeVec; null when the clip
/// holds no text, or there was no memory for it.
pub fn readText(sys: *ExecBase, ip: *IFFParseBase) ?[]u8 {
    const iff = ip.AllocIFF() orelse return null;
    defer ip.FreeIFF(iff);
    const clip = ip.OpenClipboard(clipboard.PRIMARY_CLIP) orelse return null;
    defer ip.CloseClipboard(clip);
    iff.stream = @intFromPtr(clip);
    ip.InitIFFasClip(iff);
    if (ip.OpenIFF(iff, iffparse.IFFF_READ) != 0) return null;
    defer ip.CloseIFF(iff);
    const stops = [_]u32{ ID_FTXT, ID_CSET, ID_FTXT, ID_CHRS };
    if (ip.StopChunks(iff, &stops, 2) != 0) return null;
    var length: usize = 0;
    var gathered: ?[*]u8 = null;
    var code_set: ?u32 = null;
    // A clip is read once, front to back, so the text grows as the chunks
    // come.
    while (ip.ParseIFF(iff, iffparse.IFFPARSE_SCAN) == 0) {
        const chunk = ip.CurrentChunk(iff) orelse continue;
        if (chunk.id == ID_CSET and chunk.size >= 4) {
            var word: [4]u8 = undefined;
            if (ip.ReadChunkBytes(iff, &word, 4) == 4) code_set = @as(u32, word[0]) << 24 | @as(u32, word[1]) << 16 | @as(u32, word[2]) << 8 | word[3];
            continue;
        }
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
    return asUtf8(sys, text[0..length], code_set);
}

/// A text of `CHRS` chunks in UTF-8, by the code set its `CSET` named
/// (null for none), in memory of its own: `text` itself when it is UTF-8
/// already, else a converted copy and `text` freed. Null, and `text`
/// freed, without memory for the copy. `text` is memory from AllocVec.
pub fn asUtf8(sys: *ExecBase, text: []u8, code_set: ?u32) ?[]u8 {
    const latin1 = code_set == CSET_LATIN1;
    if (code_set == CSET_UTF8) return text;
    if (!latin1 and code_set != CSET_CP1252 and utf8.valid(text)) return text;
    defer sys.FreeVec(text.ptr);
    // Latin-1 is code page 1252 but for 0x80 to 0x9F, which it has as
    // controls.
    var size: usize = 0;
    for (text) |byte| size += if (latin1) @as(usize, if (byte < 0x80) 1 else 2) else utf8.lengthOf(utf8.cp1252(byte));
    const into: [*]u8 = @ptrCast(sys.AllocVec(size, exec.MEMF_ANY) orelse return null);
    const written = if (latin1) utf8.fromLatin1(text, into[0..size]) else utf8.fromCp1252(text, into[0..size]);
    return into[0..written];
}

/// Told when the clipboard changes, to show whether it holds text: a
/// change hook on the primary clip (`CBD_CHANGEHOOK`) that signals the
/// task that started it.
///
/// Without iffparse.library's clipboard or the device, `start` does
/// nothing, `signal()` is 0 and `holdsText` answers true - Paste stays
/// usable, as it was without a Watch.
pub const Watch = struct {
    sys: ?*ExecBase = null,
    ip: ?*IFFParseBase = null,
    /// The primary clip, kept open for the hook and the questions.
    clip: ?*iffparse.ClipboardHandle = null,
    task: ?*exec.Task = null,
    bit: i8 = -1,
    hook: utility.Hook = .{},

    /// The hook put on the primary clip, to signal the task calling this
    /// whenever a clip is finished.
    pub fn start(watch: *Watch, sys: *ExecBase, ip: *IFFParseBase) void {
        const bit = sys.AllocSignal(-1);
        if (bit < 0) return;
        const clip = ip.OpenClipboard(clipboard.PRIMARY_CLIP) orelse {
            sys.FreeSignal(bit);
            return;
        };
        watch.* = .{ .sys = sys, .ip = ip, .clip = clip, .task = sys.FindTask(null), .bit = bit, .hook = .{ .entry = changed } };
        clip.req.io.req.command = clipboard.CBD_CHANGEHOOK;
        clip.req.io.data = &watch.hook;
        clip.req.io.length = 1;
        if (sys.DoIO(&clip.req.io.req) != 0) {
            ip.CloseClipboard(clip);
            sys.FreeSignal(bit);
            watch.* = .{};
        }
    }

    /// The signal a change comes with; 0 without one to wait for.
    pub fn signal(watch: *const Watch) u32 {
        if (watch.bit < 0) return 0;
        return @as(u32, 1) << @intCast(watch.bit);
    }

    /// Whether the clip that can be read now is text: a `FORM FTXT`, or a
    /// `CAT` or `LIST` that may hold one. False while nothing has been
    /// put on the clipboard; true when it could not be asked.
    pub fn holdsText(watch: *Watch) bool {
        const sys = watch.sys orelse return true;
        const req = &watch.clip.?.req;
        req.io.req.command = clipboard.CBD_CURRENTREADID;
        if (sys.DoIO(&req.io.req) != 0) return true;
        if (req.io.actual == 0) return false;
        // The clip's first twelve bytes say what it is; a read past its
        // end then tells the device the reading is over.
        var head: [12]u8 = undefined;
        req.io.req.command = exec.CMD_READ;
        req.io.data = &head;
        req.io.length = head.len;
        req.io.offset = 0;
        req.clip_id = 0;
        const failed = sys.DoIO(&req.io.req) != 0;
        const got = req.io.actual;
        req.io.length = 0;
        req.io.offset = ~@as(u64, 0);
        _ = sys.DoIO(&req.io.req);
        if (failed) return true;
        if (got < head.len) return false;
        const kind = std.mem.readInt(u32, head[0..4], .big);
        if (kind == iffparse.ID_CAT or kind == iffparse.ID_LIST) return true;
        return kind == iffparse.ID_FORM and std.mem.readInt(u32, head[8..12], .big) == ID_FTXT;
    }

    /// The hook taken off the clip - it is not called after this - and the
    /// clip and the signal let go.
    pub fn stop(watch: *Watch) void {
        const sys = watch.sys orelse return;
        const clip = watch.clip.?;
        clip.req.io.req.command = clipboard.CBD_CHANGEHOOK;
        clip.req.io.data = &watch.hook;
        clip.req.io.length = 0;
        _ = sys.DoIO(&clip.req.io.req);
        watch.ip.?.CloseClipboard(clip);
        sys.FreeSignal(watch.bit);
        watch.* = .{};
    }

    /// Called by clipboard.device's process when a clip is finished.
    fn changed(hook: *utility.Hook, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) usize {
        const watch: *Watch = @fieldParentPtr("hook", hook);
        watch.sys.?.Signal(watch.task.?, watch.signal());
        return 0;
    }
};
