// SPDX-License-Identifier: MIT
//! A film's subtitles: its text or picture track read ahead of the film
//! into a queue of what is shown when, from which GetVideoSubtitle says
//! what shows at a time without waiting on the file.
//!
//! **A process of the library's** ("videocodec subtitles") reads the
//! track through media.library, on the stream's own file: a subtitle
//! track is sparse - a line every few seconds, a picture a minute apart -
//! and reading on to its next packet can mean reading megabytes of the
//! film, which the pictures must not wait for. It reads a packet when the
//! queue has room and what it last read starts no more than `lead` past
//! the time last asked about, and otherwise waits for a signal.
//!
//! **What is asked of it** - another time after a seek, another track,
//! none, its end - is posted under `lock` with a new `generation`, and the
//! process signalled (SIGBREAKF_CTRL_F; SIGBREAKF_CTRL_C to end). The
//! process takes it up between packets: the track moved with SeekMedia
//! to `lookback` before the time - it lands on the last packet at or
//! before - so that a line begun before and still showing is read too.
//!
//! **The queue** is appended to by the process alone, and emptied by the
//! caller alone: GetVideoSubtitle first gives back what has ended and
//! what an earlier generation read, so the text and the picture it hands
//! out stay until it is called again. An event whose end the track does
//! not say - a picture, which shows until the next set - ends where the
//! next begins.
//!
//! **Read in line** - the caller reads itself, when it asks - when no
//! process can be made, and on the host, whose tests' exec runs none
//! (`read_inline`).

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const media = sdk.media;
const vc = sdk.videocodec;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const MediaBase = sdk.interface.media.MediaBase;
const text = @import("text.zig");
const pgs = @import("pgs.zig");

/// Read on the caller's task, not a process: set by the host's tests.
pub var read_inline = false;

/// How far past the time asked about the process reads ahead.
const lead: i64 = 10 * 1_000_000;
/// How far before a time moved to it starts to read: what began before
/// and still shows.
const lookback: i64 = 5 * 1_000_000;
/// How many events the queue holds at most.
const max_events = 64;
/// The bytes a line's text may make, and lines joined.
const text_bytes = 1024;
/// No end known yet.
pub const forever: i64 = std.math.maxInt(i64);

const process_name = "videocodec subtitles";
const process_stack = 4096 * @sizeOf(usize);
const process_priority = 0;

/// What is shown from `start` up to `end`: lines of text, or a picture.
const Event = struct {
    next: ?*Event = null,
    generation: u32,
    flags: u32,
    start: i64,
    end: i64,
    text: ?[*:0]const u8 = null,
    pixels: ?[*]const u32 = null,
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

pub const Reader = struct {
    sys: *ExecBase,
    dl: *DosBase,
    mb: *MediaBase,
    file: *media.MediaFile,
    /// The film's pictures' size, which a picture's canvas is fitted to.
    film_width: u32,
    film_height: u32,
    lock: exec.SignalSemaphore,

    // What is asked for, under `lock`.
    generation: u32,
    want_track: u32,
    want_time: i64,
    want_seek: bool,
    /// The time last asked about.
    asked: i64,
    quit: bool,
    /// The process waits, until `asked` comes to `wake_at` - or for a
    /// request.
    waiting: bool,
    wake_at: i64,

    // The queue, in the order read, under `lock`.
    first: ?*Event,
    last: ?*Event,
    count: u32,
    /// The event last read whose end is not known: the next one ends it.
    open_event: ?*Event,

    // The process's own.
    read_generation: u32,
    track: u32,
    codec: u32,
    at_end: bool,
    last_start: i64,
    styles: text.Styles,
    pictures: pgs.State,
    cleaned: [text_bytes]u8,

    process: ?*dos.Process,
    ended: exec.Message,

    // The caller's: lines that show at once, joined.
    joined: [2 * text_bytes]u8,
};

/// A reader started on track `track` at `time` - `seek` when the track is
/// to be moved there first - or null without memory.
pub fn create(sys: *ExecBase, dl: *DosBase, mb: *MediaBase, file: *media.MediaFile, film: *const media.MediaTrack, track: u32, time: i64, seek: bool) ?*Reader {
    // Cleared: every field starts at zero.
    const memory = sys.AllocVec(@sizeOf(Reader), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const r: *Reader = @ptrCast(@alignCast(memory));
    r.sys = sys;
    r.dl = dl;
    r.mb = mb;
    r.file = file;
    r.film_width = film.width;
    r.film_height = film.height;
    sys.InitSemaphore(&r.lock);
    r.pictures = .{};
    r.track = vc.VIDEO_NO_TRACK;
    r.generation = 1;
    r.want_track = track;
    r.want_time = time;
    r.want_seek = seek;
    r.asked = time;
    r.ended = .{ .length = @sizeOf(exec.Message) };
    if (read_inline) return r;
    const tags = [_]utility.TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&readerEntry) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr(process_name) },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(r) },
        .{ .tag = dos.NP_StackSize, .data = process_stack },
        .{ .tag = dos.NP_Priority, .data = @bitCast(@as(isize, process_priority)) },
        .{ .tag = dos.NP_EndMsg, .data = @intFromPtr(&r.ended) },
        .{},
    };
    // Without a process the caller reads.
    r.process = dl.CreateNewProc(&tags);
    return r;
}

/// The process told to end and waited for, the queue and the pictures
/// given back, and the reader.
pub fn destroy(r: *Reader) void {
    const sys = r.sys;
    if (r.process) |process| {
        // The word that it is gone comes to a port of the task closing.
        const port = sys.CreateMsgPort();
        sys.ObtainSemaphore(&r.lock);
        r.ended.reply_port = port;
        r.quit = true;
        sys.ReleaseSemaphore(&r.lock);
        sys.Signal(&process.task, exec.SIGBREAKF_CTRL_C);
        if (port) |own| {
            gone: while (true) {
                _ = sys.WaitPort(own);
                while (sys.GetMsg(own)) |message| {
                    if (message == &r.ended) break :gone;
                }
            }
            sys.DeleteMsgPort(own);
        } else {
            // No port to hear it on: the message comes back freed.
            while (r.ended.node.type != .freemsg) r.dl.Delay(1);
        }
    }
    while (r.first) |event| {
        r.first = event.next;
        sys.FreeVec(event);
    }
    pgs.free(&r.pictures, sys);
    sys.FreeVec(r);
}

/// The reader moved to `time` on `track` - VIDEO_NO_TRACK for none: what
/// it read before is let go.
pub fn move(r: *Reader, track: u32, time: i64) void {
    const sys = r.sys;
    sys.ObtainSemaphore(&r.lock);
    r.generation +%= 1;
    r.want_track = track;
    r.want_time = time;
    r.want_seek = true;
    r.asked = time;
    r.waiting = false;
    sys.ReleaseSemaphore(&r.lock);
    if (r.process) |process| sys.Signal(&process.task, exec.SIGBREAKF_CTRL_F);
}

/// What shows at `time` into `out`: VCERR_OK, or VCERR_END for nothing.
pub fn subtitle(r: *Reader, time: i64, out: *vc.VideoSubtitle) i32 {
    const sys = r.sys;
    if (r.process == null) {
        sys.ObtainSemaphore(&r.lock);
        r.asked = time;
        sys.ReleaseSemaphore(&r.lock);
        while (pump(r) == .worked) {}
    }
    sys.ObtainSemaphore(&r.lock);
    defer sys.ReleaseSemaphore(&r.lock);
    r.asked = time;

    // What has ended, and what was read before a move, given back.
    var link: *?*Event = &r.first;
    var previous: ?*Event = null;
    while (link.*) |event| {
        if (event.generation == r.generation and event.end > time) {
            previous = event;
            link = &event.next;
            continue;
        }
        link.* = event.next;
        if (r.last == event) r.last = previous;
        if (r.open_event == event) r.open_event = null;
        r.count -= 1;
        sys.FreeVec(event);
    }
    if (r.process) |process| {
        if (r.waiting and r.count < max_events and r.asked >= r.wake_at) {
            r.waiting = false;
            sys.Signal(&process.task, exec.SIGBREAKF_CTRL_F);
        }
    }
    return compose(r, time, out);
}

/// What shows at `time`, made of the events that do: a picture - the
/// latest - or their lines joined, in the order they began.
fn compose(r: *Reader, time: i64, out: *vc.VideoSubtitle) i32 {
    var picture: ?*Event = null;
    var lines: u32 = 0;
    var single: ?*Event = null;
    var start: i64 = std.math.minInt(i64);
    var end: i64 = forever;
    var italic = true;
    var event = r.first;
    while (event) |shown| : (event = shown.next) {
        if (shown.start > time or shown.end <= time) continue;
        if (shown.flags & vc.VSUB_BITMAP != 0) {
            picture = shown;
            continue;
        }
        if (lines == 0) single = shown;
        lines += 1;
        start = @max(start, shown.start);
        end = @min(end, shown.end);
        if (shown.flags & vc.VSUB_ITALIC == 0) italic = false;
    }
    if (picture) |shown| {
        out.* = .{
            .flags = vc.VSUB_BITMAP,
            .start = shown.start,
            .end = shown.end,
            .pixels = shown.pixels,
            .x = shown.x,
            .y = shown.y,
            .width = shown.width,
            .height = shown.height,
        };
        return vc.VCERR_OK;
    }
    if (lines == 0) {
        out.* = .{};
        return vc.VCERR_END;
    }
    out.* = .{
        .flags = vc.VSUB_TEXT | if (italic) vc.VSUB_ITALIC else 0,
        .start = start,
        .end = end,
        .text = single.?.text,
    };
    if (lines == 1) return vc.VCERR_OK;
    // Several at once: their lines one under another.
    var length: usize = 0;
    event = r.first;
    while (event) |shown| : (event = shown.next) {
        if (shown.start > time or shown.end <= time or shown.flags & vc.VSUB_TEXT == 0) continue;
        const line = std.mem.span(shown.text.?);
        if (length != 0 and length + 1 < r.joined.len) {
            r.joined[length] = '\n';
            length += 1;
        }
        const take = @min(line.len, r.joined.len - 1 - length);
        @memcpy(r.joined[length..][0..take], line[0..take]);
        length += take;
    }
    r.joined[length] = 0;
    out.text = r.joined[0..length :0];
    return vc.VCERR_OK;
}

// --- the process -------------------------------------------------------------------

const Pumped = enum { worked, idle, quit };

fn readerEntry(sys: *ExecBase) callconv(.c) void {
    const r: *Reader = @ptrCast(@alignCast(sys.FindTask(null).?.user_data.?));
    while (true) {
        switch (pump(r)) {
            .worked => {},
            .idle => _ = sys.Wait(exec.SIGBREAKF_CTRL_F | exec.SIGBREAKF_CTRL_C),
            .quit => return,
        }
    }
}

/// One step: a request taken up, or a packet read - or nothing to do.
fn pump(r: *Reader) Pumped {
    const sys = r.sys;
    sys.ObtainSemaphore(&r.lock);
    if (r.quit) {
        sys.ReleaseSemaphore(&r.lock);
        return .quit;
    }
    if (r.generation != r.read_generation) {
        r.read_generation = r.generation;
        const track = r.want_track;
        const time = r.want_time;
        const seek = r.want_seek;
        r.open_event = null;
        sys.ReleaseSemaphore(&r.lock);
        begin(r, track, time, seek);
        return .worked;
    }
    if (r.track == vc.VIDEO_NO_TRACK or r.at_end or r.count >= max_events or r.last_start > r.asked + lead) {
        r.waiting = true;
        r.wake_at = if (r.track == vc.VIDEO_NO_TRACK or r.at_end)
            forever
        else if (r.count >= max_events)
            std.math.minInt(i64)
        else
            r.last_start - lead;
        sys.ReleaseSemaphore(&r.lock);
        return .idle;
    }
    sys.ReleaseSemaphore(&r.lock);

    var packet: media.MediaPacket = .{};
    if (r.mb.ReadMediaPacket(r.file, r.track, &packet) != media.MERR_OK) {
        r.at_end = true;
        return .worked;
    }
    r.last_start = packet.pts;
    readPacket(r, &packet);
    return .worked;
}

/// A track taken up at `time`: its codec and setup when it is another,
/// moved there when `seek`.
fn begin(r: *Reader, track: u32, time: i64, seek: bool) void {
    pgs.reset(&r.pictures);
    r.at_end = false;
    r.last_start = std.math.minInt(i64);
    if (track != r.track) {
        r.track = track;
        r.codec = media.MCODEC_UNKNOWN;
        r.styles.count = 0;
        if (track == vc.VIDEO_NO_TRACK) return;
        var info: media.MediaTrack = .{};
        if (r.mb.GetMediaTrack(r.file, track, &info) != media.MERR_OK or info.kind != media.MTRACK_TEXT) {
            r.track = vc.VIDEO_NO_TRACK;
            return;
        }
        r.codec = info.codec;
        if (info.codec == media.MCODEC_ASS) {
            if (info.config) |setup| text.readStyles(setup[0..info.config_size], &r.styles);
        }
    }
    if (track == vc.VIDEO_NO_TRACK) return;
    if (seek and r.mb.SeekMedia(r.file, track, @max(time - lookback, 0)) != media.MERR_OK) r.at_end = true;
}

/// A packet made an event and queued.
fn readPacket(r: *Reader, packet: *const media.MediaPacket) void {
    const data = (packet.data orelse return)[0..packet.size];
    const start = packet.pts;
    const end = if (packet.duration != 0) start +| packet.duration else forever;
    switch (r.codec) {
        media.MCODEC_SRT, media.MCODEC_ASS, media.MCODEC_TEXT => {
            const made = switch (r.codec) {
                media.MCODEC_ASS => text.ass(data, &r.styles, &r.cleaned),
                // Timed text: its length, then its bytes.
                media.MCODEC_TEXT => if (data.len >= 2) text.srt(data[2..@min(data.len, 2 + (@as(usize, data[0]) << 8 | data[1]))], &r.cleaned) else null,
                else => text.srt(data, &r.cleaned),
            } orelse return queue(r, null, start);
            const memory = r.sys.AllocVec(@sizeOf(Event) + made.length + 1, exec.MEMF_ANY) orelse return;
            const event: *Event = @ptrCast(@alignCast(memory));
            const bytes: [*]u8 = @as([*]u8, @ptrCast(memory)) + @sizeOf(Event);
            @memcpy(bytes[0 .. made.length + 1], r.cleaned[0 .. made.length + 1]);
            event.* = .{
                .generation = 0,
                .flags = vc.VSUB_TEXT | if (made.italic) vc.VSUB_ITALIC else 0,
                .start = start,
                .end = end,
                .text = @ptrCast(bytes),
            };
            queue(r, event, start);
        },
        media.MCODEC_PGS => switch (pgs.read(&r.pictures, r.sys, data)) {
            .nothing => {},
            .clear => queue(r, null, start),
            .picture => {
                const event = drawSet(r, start) orelse return queue(r, null, start);
                queue(r, event, start);
            },
        },
        else => {},
    }
}

/// The objects a display set places drawn into an event - fitted to the
/// film's size where the canvas is another.
fn drawSet(r: *Reader, start: i64) ?*Event {
    const sys = r.sys;
    const box = pgs.bounds(&r.pictures) orelse return null;
    const canvas_width = r.pictures.canvas_width;
    const canvas_height = r.pictures.canvas_height;
    const fitted = canvas_width != 0 and canvas_height != 0 and r.film_width != 0 and r.film_height != 0 and
        (canvas_width != r.film_width or canvas_height != r.film_height);
    const place: pgs.Rect = if (fitted) .{
        .x = box.x * r.film_width / canvas_width,
        .y = box.y * r.film_height / canvas_height,
        .width = @max(box.width * r.film_width / canvas_width, 1),
        .height = @max(box.height * r.film_height / canvas_height, 1),
    } else box;
    const pixels = @as(usize, place.width) * place.height;
    const memory = sys.AllocVec(@sizeOf(Event) + pixels * 4, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const event: *Event = @ptrCast(@alignCast(memory));
    const out: [*]u32 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(memory)) + @sizeOf(Event)));
    if (fitted) {
        // Drawn as the canvas has it, then each pixel taken from there.
        const drawn_count = @as(usize, box.width) * box.height;
        const drawn_memory = sys.AllocVec(drawn_count * 4, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
            sys.FreeVec(memory);
            return null;
        };
        const drawn: [*]u32 = @ptrCast(@alignCast(drawn_memory));
        pgs.draw(&r.pictures, drawn[0..drawn_count], box);
        for (0..place.height) |row| {
            const from_row = row * box.height / place.height;
            for (0..place.width) |column| {
                out[row * place.width + column] = drawn[from_row * box.width + column * box.width / place.width];
            }
        }
        sys.FreeVec(drawn_memory);
    } else {
        pgs.draw(&r.pictures, out[0..pixels], box);
    }
    event.* = .{
        .generation = 0,
        .flags = vc.VSUB_BITMAP,
        .start = start,
        // Until the next set.
        .end = forever,
        .pixels = out,
        .x = place.x,
        .y = place.y,
        .width = place.width,
        .height = place.height,
    };
    return event;
}

/// An event queued - or none, for what only ends the one before: the
/// event whose end was not known ends at `start`. Nothing is queued when
/// something else has been asked for since it was read.
fn queue(r: *Reader, event: ?*Event, start: i64) void {
    const sys = r.sys;
    sys.ObtainSemaphore(&r.lock);
    defer sys.ReleaseSemaphore(&r.lock);
    if (r.generation != r.read_generation) {
        if (event) |stale| sys.FreeVec(stale);
        return;
    }
    if (r.open_event) |open| {
        open.end = @max(start, open.start);
        r.open_event = null;
    }
    const queued = event orelse return;
    queued.generation = r.read_generation;
    queued.next = null;
    if (r.last) |last| last.next = queued else r.first = queued;
    r.last = queued;
    r.count += 1;
    if (queued.end == forever) r.open_event = queued;
}

test {
    _ = text;
    _ = pgs;
}
