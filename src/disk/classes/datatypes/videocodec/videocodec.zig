// SPDX-License-Identifier: MIT
//! videocodec.datatype: a film in a window - what every film is, whatever
//! file it came out of.
//!
//! A datatypesclass subclass in the group `movi`, and the only class in
//! that group: media.library knows the containers - MP4, QuickTime's MOV,
//! Matroska's MKV and WebM - and videocodec.library finds a decoder for
//! the pictures and opens audiocodec.library for the sound, so a kind of
//! film the system learns needs only a descriptor in `DEVS:DataTypes`
//! that names `BASE=videocodec`. There is no format class under this one,
//! and nothing a superclass over it could hold that videocodec.library is
//! not already.
//!
//! **A process plays, `GM_RENDER` only puts up.** The object opens the
//! film in `OM_NEW` and starts a process of its own when it is first laid
//! out (play.zig); that process decodes the pictures, keeps the film's
//! sound fed through audio.device and puts each picture up when what is
//! heard has come to its time, and asks for the object to be drawn again.
//! `GM_RENDER` does nothing but put the picture that is up into the
//! window, with the RastPort intuition hands it and the layers intuition
//! has locked. Nothing a program or intuition asks of the object waits
//! for a decoder.
//!
//! **The picture takes the room it is given**, as large as fits with its
//! shape kept, in the middle, black where it does not reach: a film is
//! watched, not looked at, so there is nothing outside the room to scroll
//! to (`DTA_TotalVert` is `DTA_VisibleVert`) and a window shows no bars
//! for it. The film's own size is what the object asks for, so a window
//! opened for it opens at that size. The picture goes down through
//! graphics.library - `WriteYUVPixelArray` at its own size,
//! `ScaleYUVPixelArray` at any other - and not through a display's video
//! layer: a layer lies under the whole screen's picture, and an object in
//! a window cannot have one without covering the windows in front of it.
//! Movie, which owns its window, uses one.
//!
//! **What it is told**: `DTA_Immediate` plays it as soon as it is laid
//! out, `DTA_Repeat` plays it again when it ends, and `DTM_TRIGGER` with
//! `STM_PLAY`, `STM_PAUSE` (which turns over), `STM_STOP`, `STM_LOCATE`
//! (a time in milliseconds), `STM_FASTFORWARD` and `STM_REWIND` drives
//! it; a press on the picture pauses it and a second goes on. The
//! attributes are `sdk.datatypes.movieclass`.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const sc = intuition.screens;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const datatypes = sdk.datatypes;
const subclass = datatypes.subclass;
const dtc = datatypes.datatypesclass;
const vdt = datatypes.movieclass;
const vc = sdk.videocodec;
const play = @import("play.zig");
const Data = play.Data;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const VideoCodecBase = sdk.interface.videocodec.VideoCodecBase;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Base = gadgets.Base;
const Pen = graphics.Pen;
const Rect = graphics.Rect;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
/// datatypes.library because datatypesclass is made by it; videocodec for
/// the film; dos for the player's process.
pub const Library = gadgets.ClassLibrary(.{
    .name = vdt.VIDEOCODECDTCLASS,
    .version = 1,
    .date = "04.11.2026",
    .super = dtc.DATATYPESCLASS,
    .opens = &.{ datatypes.DATATYPESNAME, vc.VIDEOCODECNAME, dos.DOSNAME },
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// What it can be told to do, for a program to offer without knowing it
/// holds a film.
const trigger_methods = [_]dtc.DTMethod{
    .{ .label = "Play", .command = "PLAY", .method = dtc.STM_PLAY },
    .{ .label = "Pause", .command = "PAUSE", .method = dtc.STM_PAUSE },
    .{ .label = "Stop", .command = "STOP", .method = dtc.STM_STOP },
    .{ .label = "Back ten seconds", .command = "REWIND", .method = dtc.STM_REWIND },
    .{ .label = "On ten seconds", .command = "FORWARD", .method = dtc.STM_FASTFORWARD },
    .{},
};

/// What a film is shown on where its picture does not reach.
const black: Pen = 0xFF00_0000;

fn dataOf(cl: *Class, o: *Object) *Data {
    return classes.instData(Data, cl, o);
}

fn dosOf(base: *Base) *DosBase {
    return @ptrCast(base.opened[play.opened_dos].?);
}

fn codecOf(base: *Base) *VideoCodecBase {
    return @ptrCast(base.opened[play.opened_videocodec].?);
}

// --- the film ---------------------------------------------------------------

/// A datatypes error for what videocodec.library said.
fn errorFor(code: i32) i32 {
    return switch (code) {
        vc.VCERR_NOMEMORY => dos.ERROR_NO_FREE_STORE,
        vc.VCERR_UNSUPPORTED, vc.VCERR_NOCODEC => datatypes.DTERROR_UNKNOWN_COMPRESSION,
        vc.VCERR_OPEN, vc.VCERR_READ => datatypes.DTERROR_COULDNT_OPEN,
        vc.VCERR_BUSY => dos.ERROR_OBJECT_IN_USE,
        else => datatypes.DTERROR_INVALID_DATA,
    };
}

/// The object's file opened and a stream of videocodec.library on it, and
/// the superclass told what the film is. What went wrong, or 0.
///
/// The file stays open for as long as the object: a film is read as it is
/// played and never held whole, so bytes in memory and the clipboard are
/// no source for one.
fn openFilm(base: *Base, cl: *Class, o: *Object, own: *Data) i32 {
    const ib = base.intuition_base;
    const dl = dosOf(base);
    const vcb = codecOf(base);
    if (subclass.superAsk(ib, cl, o, dtc.DTA_SourceType) != dtc.DTST_FILE) return datatypes.DTERROR_COULDNT_OPEN;
    const lock: ?*dos.FileLock = @ptrFromInt(subclass.superAsk(ib, cl, o, dtc.DTA_Handle));
    const copy = dl.DupLock(lock orelse return datatypes.DTERROR_COULDNT_OPEN) orelse return datatypes.DTERROR_COULDNT_OPEN;
    const file = dl.OpenFromLock(copy) orelse {
        dl.UnLock(copy);
        return datatypes.DTERROR_COULDNT_OPEN;
    };
    own.file = file;
    var err: i32 = 0;
    own.film = vcb.OpenVideoStream(&[_]TagItem{
        .{ .tag = vc.VCA_FileHandle, .data = @intFromPtr(file) },
        .{},
    }, &err) orelse return errorFor(if (err != 0) err else vc.VCERR_OPEN);
    const film = own.film.?;
    vcb.GetVideoStreamInfo(film, &own.info);
    if (own.info.width == 0 or own.info.height == 0) return datatypes.DTERROR_INVALID_DATA;
    own.frame_us = if (own.info.rate_num != 0)
        @intCast(@as(u64, 1_000_000) * @max(own.info.rate_den, 1) / own.info.rate_num)
    else
        40_000;

    // The title at full length where the file's tags give one; what the
    // info says, cut at 63 characters, otherwise. Either lives as long as
    // the object - the one in the library's stream, the other in the
    // object's own memory - which is what the superclass keeps a pointer
    // to.
    var title: [*:0]const u8 = @ptrCast(&own.info.title);
    _ = vcb.GetVideoStreamAttrs(film, &[_]TagItem{
        .{ .tag = sdk.media.MDA_Title, .data = @intFromPtr(&title) },
        .{},
    });
    subclass.superTell(ib, cl, o, &[_]TagItem{
        .{ .tag = dtc.DTA_NominalHoriz, .data = own.info.width },
        .{ .tag = dtc.DTA_NominalVert, .data = own.info.height },
        .{ .tag = dtc.DTA_HorizUnit, .data = 1 },
        .{ .tag = dtc.DTA_VertUnit, .data = 1 },
        .{ .tag = dtc.DTA_TriggerMethods, .data = @intFromPtr(&trigger_methods) },
        .{ .tag = if (title[0] != 0) dtc.DTA_ObjName else utility.TAG_IGNORE, .data = @intFromPtr(title) },
        .{},
    });
    return 0;
}

/// The film and the file given back, once the process that played it is
/// gone.
fn closeFilm(base: *Base, kept: *const Data) void {
    if (kept.film) |film| codecOf(base).CloseVideoStream(film);
    if (kept.file) |file| _ = dosOf(base).Close(file);
}

// --- the process ------------------------------------------------------------

/// The player's process, made the first time the object is laid out.
/// False when it could not be, and then the film stands.
fn begin(base: *Base, own: *Data) bool {
    if (own.started) return true;
    if (own.film == null) return false;
    const sys = base.sys_base;
    sys.InitSemaphore(&own.alive);
    own.start_signal = sys.AllocSignal(-1);
    if (own.start_signal < 0) return false;
    own.starter = sys.FindTask(null);
    const proc = dosOf(base).CreateNewProc(&[_]TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&play.main) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr("film player") },
        .{ .tag = dos.NP_StackSize, .data = play.stack_bytes },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(own) },
        .{},
    });
    // It holds `alive` from its first step, which is what `end` waits on.
    if (proc != null) _ = sys.Wait(@as(u32, 1) << @intCast(own.start_signal));
    sys.FreeSignal(own.start_signal);
    own.start_signal = -1;
    own.starter = null;
    if (proc == null) return false;
    own.player = @ptrCast(proc);
    own.started = true;
    return true;
}

/// The process told to go, and waited for: it gives the pictures back and
/// ends the sound's process on its way out, so nothing of the film is
/// still in hand when it is closed.
fn end(base: *Base, own: *Data) void {
    const sys = base.sys_base;
    const task = own.player orelse return;
    own.quitting = true;
    sys.Signal(task, exec.SIGBREAKF_CTRL_C);
    sys.ObtainSemaphore(&own.alive);
    sys.ReleaseSemaphore(&own.alive);
    own.player = null;
    own.started = false;
}

// --- playing, as the object is told to -----------------------------------------

/// Where the film is, in microseconds.
fn positionOf(base: *Base, own: *Data) i64 {
    const sys = base.sys_base;
    sys.AcquireLock(&own.lock);
    const at = own.position;
    sys.ReleaseLock(&own.lock);
    return at;
}

/// Play it: from the top again when it has played out.
fn playFilm(base: *Base, own: *Data) void {
    const sys = base.sys_base;
    sys.AcquireLock(&own.lock);
    if (own.ended and own.info.seekable != 0) {
        own.seek_to = 0;
        own.seek_wanted = true;
    }
    own.ended = false;
    own.playing = true;
    sys.ReleaseLock(&own.lock);
    play.wake(base, own);
}

fn pauseFilm(base: *Base, own: *Data) void {
    const sys = base.sys_base;
    sys.AcquireLock(&own.lock);
    own.playing = false;
    sys.ReleaseLock(&own.lock);
    play.wake(base, own);
}

/// The film taken to `time` microseconds - to the key frame at or before
/// it - by the process, whose film it is.
fn seekTo(base: *Base, own: *Data, time: i64) void {
    const sys = base.sys_base;
    sys.AcquireLock(&own.lock);
    const can = own.info.seekable != 0;
    if (can) {
        own.seek_to = @max(time, 0);
        own.seek_wanted = true;
        own.ended = false;
    }
    sys.ReleaseLock(&own.lock);
    if (can) play.wake(base, own);
}

fn volumeTo(base: *Base, own: *Data, percent: u32) void {
    const sys = base.sys_base;
    sys.AcquireLock(&own.lock);
    own.volume = @min(percent, 100);
    own.volume_wanted = true;
    sys.ReleaseLock(&own.lock);
    play.wake(base, own);
}

fn playingNow(base: *Base, own: *Data) bool {
    const sys = base.sys_base;
    sys.AcquireLock(&own.lock);
    const playing = own.playing;
    sys.ReleaseLock(&own.lock);
    return playing;
}

fn trigger(base: *Base, own: *Data, function: u32, data: ?*anyopaque) void {
    switch (function) {
        dtc.STM_PLAY, dtc.STM_RESUME => playFilm(base, own),
        dtc.STM_PAUSE => if (playingNow(base, own)) pauseFilm(base, own) else playFilm(base, own),
        dtc.STM_STOP => {
            pauseFilm(base, own);
            seekTo(base, own, 0);
        },
        dtc.STM_LOCATE => seekTo(base, own, @as(i64, @intCast(@intFromPtr(data))) * 1000),
        dtc.STM_FASTFORWARD => seekTo(base, own, positionOf(base, own) + play.jump_us),
        dtc.STM_REWIND => seekTo(base, own, positionOf(base, own) - play.jump_us),
        else => {},
    }
}

// --- the room and the picture ---------------------------------------------------

fn same(a: Rect, b: Rect) bool {
    return a.min_x == b.min_x and a.min_y == b.min_y and a.max_x == b.max_x and a.max_y == b.max_y;
}

/// Where a picture `width` by `height` goes in `box`: as large as fits
/// with its shape kept, in the middle.
fn fit(box: gc.Box, width: u32, height: u32) Rect {
    const room_w: i64 = box.width;
    const room_h: i64 = box.height;
    if (width == 0 or height == 0 or room_w <= 0 or room_h <= 0) {
        return .{ .min_x = box.left, .min_y = box.top, .max_x = box.left, .max_y = box.top };
    }
    var w: i64 = room_w;
    var h: i64 = @divTrunc(w * height, width);
    if (h > room_h) {
        h = room_h;
        w = @max(@divTrunc(h * width, height), 1);
    }
    h = @max(h, 1);
    const x = box.left + @as(i32, @intCast(@divTrunc(room_w - w, 2)));
    const y = box.top + @as(i32, @intCast(@divTrunc(room_h - h, 2)));
    return .{ .min_x = x, .min_y = y, .max_x = x + @as(i32, @intCast(w)), .max_y = y + @as(i32, @intCast(h)) };
}

/// The room laid out: its size is the film's room, all of it seen, and the
/// picture is put anew in it.
fn layOut(base: *Base, cl: *Class, o: *Object, own: *Data, lay: *gc.GpLayout) void {
    const info = lay.gadget_info orelse return;
    const box = gc.boxFor(gc.gadget(o), info);
    const width: usize = @intCast(@max(box.width, 0));
    const height: usize = @intCast(@max(box.height, 0));
    subclass.superTell(base.intuition_base, cl, o, &[_]TagItem{
        .{ .tag = dtc.DTA_VisibleHoriz, .data = width },
        .{ .tag = dtc.DTA_VisibleVert, .data = height },
        .{ .tag = dtc.DTA_TotalHoriz, .data = width },
        .{ .tag = dtc.DTA_TotalVert, .data = height },
        .{ .tag = dtc.DTA_TopHoriz, .data = 0 },
        .{ .tag = dtc.DTA_TopVert, .data = 0 },
        .{},
    });
    own.drawn = .{};
    if (!begin(base, own)) return;
    if (own.immediate and !playingNow(base, own)) playFilm(base, own);
}

/// `text` in the middle of `box`, its end cut where it does not fit.
fn say(gb: *GraphicsBase, rp: *graphics.RastPort, box: gc.Box, text: [*:0]const u8, pen: Pen) void {
    var count: u32 = support.textLen(text);
    while (count > 0 and gb.TextLength(rp, text, count) > box.width - 8) count -= 1;
    if (count == 0) return;
    var cut: [96:0]u8 = @splat(0);
    const kept = @min(count, cut.len);
    for (0..kept) |i| cut[i] = text[i];
    var font_height: u32 = 8;
    gb.GetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&font_height) }, .{} });
    const width = gb.TextLength(rp, &cut, kept);
    support.drawText(gb, rp, box.left + @divTrunc(box.width - width, 2), box.top + @divTrunc(box.height - @as(i32, @intCast(font_height)), 2), &cut, pen);
}

/// The picture that is up put into `box`, and the black beside it; or
/// what keeps the film from being played, in words.
///
/// The picture is the decoder's own memory, lent to the object: it is
/// held here while it is put down (`Data.readers`), and the process gives
/// no picture back while one is held, so what is drawn is never decoded
/// into halfway through. The black is filled when the picture lands
/// elsewhere than the last did, and whenever the whole of the object is
/// asked for.
fn paint(base: *Base, own: *Data, rp: *graphics.RastPort, box: gc.Box, whole: bool, ground: Pen, text_pen: Pen) void {
    const sys = base.sys_base;
    const gb = base.graphics_base;
    if (box.width <= 0 or box.height <= 0) return;
    sys.AcquireLock(&own.lock);
    const trouble = own.trouble;
    const has = own.have_shown and trouble == null;
    var frame: vc.VideoFrame = .{};
    if (has) {
        frame = own.shown;
        own.readers += 1;
    }
    sys.ReleaseLock(&own.lock);
    if (!has) {
        support.fill(gb, rp, box, if (trouble != null) ground else black);
        if (trouble) |words| say(gb, rp, box, words, text_pen);
        own.drawn = .{};
        return;
    }
    const place = fit(box, frame.width, frame.height);
    if (whole or !same(place, own.drawn)) {
        support.fill(gb, rp, box, black);
        own.drawn = place;
    }
    if (place.width() == @as(i32, @intCast(frame.width)) and place.height() == @as(i32, @intCast(frame.height))) {
        gb.WriteYUVPixelArray(rp, &frame.picture, 0, 0, &place);
    } else {
        const all = Rect{ .max_x = @intCast(frame.width), .max_y = @intCast(frame.height) };
        gb.ScaleYUVPixelArray(rp, &frame.picture, &all, &place);
    }
    sys.AcquireLock(&own.lock);
    own.readers -= 1;
    const tell = own.readers == 0 and own.wake_on_free;
    own.wake_on_free = false;
    sys.ReleaseLock(&own.lock);
    // The process was waiting for this picture to be let go of, so that
    // the next can take its place.
    if (tell) play.wake(base, own);
}

fn frameBox(own: *Data, frame: *dtc.DtFrameBox) void {
    const want = frame.frame_info;
    want.* = frame.contents_info.*;
    want.width = own.info.width;
    want.height = own.info.height;
    want.depth = 32;
    want.red_bits = 8;
    want.green_bits = 8;
    want.blue_bits = 8;
    // It is drawn at the size of the room it is given, and has nothing
    // outside it.
    want.flags = dtc.FIF_SCALABLE;
}

// --- the attributes ---------------------------------------------------------------

/// What `tags` says of this class's attributes.
fn setAttrs(base: *Base, own: *Data, tags: ?[*]const TagItem) void {
    const ub = base.utility_base;
    var state = tags;
    while (ub.NextTagItem(&state)) |item| {
        switch (item.tag) {
            vdt.VDTA_Position => seekTo(base, own, @as(i64, @intCast(item.data)) * 1000),
            vdt.VDTA_Volume => volumeTo(base, own, @truncate(item.data)),
            dtc.DTA_Immediate => own.immediate = item.data != 0,
            dtc.DTA_Repeat => own.repeat = item.data != 0,
            else => {},
        }
    }
}

fn getAttr(base: *Base, own: *Data, attr: utility.Tag, storage: *usize) bool {
    const sys = base.sys_base;
    sys.AcquireLock(&own.lock);
    defer sys.ReleaseLock(&own.lock);
    storage.* = switch (attr) {
        vdt.VDTA_Width => own.info.width,
        vdt.VDTA_Height => own.info.height,
        vdt.VDTA_FramesPerSecond => play.framesPerSecond(&own.info),
        vdt.VDTA_Frames => own.info.frames,
        vdt.VDTA_Duration => @intCast(@min(own.info.duration / 1000, @as(u64, 0xFFFF_FFFF))),
        vdt.VDTA_Position => @intCast(@max(own.position, 0) / 1000),
        vdt.VDTA_Codec => own.info.codec,
        vdt.VDTA_SoundCodec => own.info.sound_codec,
        vdt.VDTA_SoundRate => own.info.sound_rate,
        vdt.VDTA_SoundChannels => own.info.sound_channels,
        vdt.VDTA_Volume => own.volume,
        vdt.VDTA_Seekable => @intFromBool(own.info.seekable != 0),
        vdt.VDTA_Playing => @intFromBool(own.playing),
        dtc.DTA_Immediate => @intFromBool(own.immediate),
        dtc.DTA_Repeat => @intFromBool(own.repeat),
        else => return false,
    };
    return true;
}

fn dispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *Class = @ptrCast(hook);
    const base = gadgets.baseOf(cl);
    const ib = base.intuition_base;
    const msg: *classusr.Msg = @ptrCast(@alignCast(message orelse return 0));
    const o: ?*Object = @ptrCast(object);

    switch (msg.method_id) {
        classusr.OM_NEW => {
            const made = ib.SendSuperMessage(cl, o, msg);
            if (made == 0) return 0;
            const obj: *Object = @ptrFromInt(made);
            const own = dataOf(cl, obj);
            own.* = .{};
            own.object = obj;
            own.base = base;
            base.sys_base.InitLock(&own.lock, "film", exec.LOCKORDER_DRIVER, 0);
            const failure = openFilm(base, cl, obj, own);
            if (failure != 0) {
                // What was opened before it failed goes back in
                // OM_DISPOSE, which is where everything of the film's is
                // given back.
                _ = dosOf(base).SetIoErr(failure);
                ib.DisposeObject(obj);
                return 0;
            }
            const new: *classusr.OpSet = @ptrCast(@alignCast(msg));
            setAttrs(base, own, new.attr_list);
            return made;
        },
        classusr.OM_DISPOSE => {
            const own = dataOf(cl, o.?);
            // The process first: it holds pictures of the film and the
            // sound's process, and both are the film's.
            end(base, own);
            const kept = own.*;
            const result = ib.SendSuperMessage(cl, o, msg);
            closeFilm(base, &kept);
            return result;
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            setAttrs(base, dataOf(cl, o.?), set.attr_list);
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            if (getAttr(base, dataOf(cl, o.?), get.attr_id, get.storage)) return 1;
            return ib.SendSuperMessage(cl, o, msg);
        },
        gc.GM_RENDER => {
            const r: *gc.GpRender = @ptrCast(@alignCast(msg));
            const info = r.gadget_info orelse return 0;
            const gb = base.graphics_base;
            const saved = support.Saved.of(gb, r.rast_port);
            defer saved.restore(gb, r.rast_port);
            const style = gc.gadget(o.?).style;
            const ground = support.background(ib, info.draw_info, style, intuition.style.PART_MAIN);
            const pens = support.pensFor(ib, info.draw_info, style, intuition.style.PART_MAIN, null);
            paint(base, dataOf(cl, o.?), r.rast_port, gc.boxFor(gc.gadget(o.?), info), r.redraw == gc.GREDRAW_REDRAW, ground, pens[sc.TEXTPEN]);
            return 0;
        },
        // A press on the picture pauses the film, or plays it on.
        gc.GM_HITTEST => return gc.GMR_GADGETHIT,
        gc.GM_GOACTIVE => {
            trigger(base, dataOf(cl, o.?), dtc.STM_PAUSE, null);
            return gc.GMR_NOREUSE;
        },
        dtc.DTM_PROCLAYOUT, dtc.DTM_ASYNCLAYOUT => {
            layOut(base, cl, o.?, dataOf(cl, o.?), @ptrCast(@alignCast(msg)));
            return 1;
        },
        dtc.DTM_FRAMEBOX => {
            frameBox(dataOf(cl, o.?), @ptrCast(@alignCast(msg)));
            return 1;
        },
        dtc.DTM_TRIGGER => {
            const t: *dtc.DtTrigger = @ptrCast(@alignCast(msg));
            trigger(base, dataOf(cl, o.?), t.function, t.data);
            return 1;
        },
        // Out of its window there is nowhere to put a picture: the film
        // stands until it is put in one again and played.
        dtc.DTM_REMOVEDTOBJECT => {
            pauseFilm(base, dataOf(cl, o.?));
            return ib.SendSuperMessage(cl, o, msg);
        },
        dtc.DTM_DRAW => {
            const draw: *dtc.DtDraw = @ptrCast(@alignCast(msg));
            const gb = base.graphics_base;
            const saved = support.Saved.of(gb, draw.rast_port);
            defer saved.restore(gb, draw.rast_port);
            paint(base, dataOf(cl, o.?), draw.rast_port, .{
                .left = draw.left,
                .top = draw.top,
                .width = draw.width,
                .height = draw.height,
            }, true, black, 0xFFFF_FFFF);
            return 1;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
