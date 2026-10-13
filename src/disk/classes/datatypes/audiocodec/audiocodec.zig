// SPDX-License-Identifier: MIT
//! audiocodec.datatype: a sound file audiocodec.library decodes - WAV,
//! MP3 - as a sound.
//!
//! A sound.datatype subclass. In `OM_NEW` it opens the object's file and
//! a stream of audiocodec.library on it, and tells its superclass what
//! the sound is and what its tags name it; from then on it decodes the
//! next piece when the superclass's player asks (`SDTM_DECODE`) and moves
//! the stream when it is told (`SDTM_SEEK`). The file stays open for as
//! long as the object: the sound is read as it is heard, never whole.
//!
//! **Every kind the library knows is this one class.** The decoding is
//! audiocodec.library's, so a kind it learns needs only a descriptor in
//! `DEVS:DataTypes` that names `BASE=audiocodec`.

const sdk = @import("sdk");
const dos = sdk.dos;
const utility = sdk.utility;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gadgets = sdk.gadgets;
const datatypes = sdk.datatypes;
const ac = sdk.audiocodec;
const subclass = datatypes.subclass;
const dtc = datatypes.datatypesclass;
const sdt = datatypes.soundclass;
const DosBase = sdk.interface.dos.DosBase;
const AudioCodecBase = sdk.interface.audiocodec.AudioCodecBase;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Base = gadgets.Base;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = "audiocodec.datatype",
    .version = 1,
    .date = "13.10.2026",
    .super = sdt.SOUNDDTCLASS,
    .opens = &.{ sdt.SOUND_LIBRARY, ac.AUDIOCODECNAME, dos.DOSNAME },
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

const opened_codec = 1;
const opened_dos = 2;

/// audiocodec.datatype's part of an object: the stream and the file it
/// reads.
pub const Data = extern struct {
    stream: ?*ac.AudioStream = null,
    file: ?*dos.FileHandle = null,
};

fn codecOf(base: *Base) *AudioCodecBase {
    return @ptrCast(base.opened[opened_codec].?);
}

fn dosOf(base: *Base) *DosBase {
    return @ptrCast(base.opened[opened_dos].?);
}

/// A datatypes error for what the library said.
fn errorFor(code: i32) i32 {
    return switch (code) {
        ac.ACERR_NOMEMORY => dos.ERROR_NO_FREE_STORE,
        ac.ACERR_UNSUPPORTED => datatypes.DTERROR_UNKNOWN_COMPRESSION,
        ac.ACERR_OPEN, ac.ACERR_READ => datatypes.DTERROR_COULDNT_OPEN,
        else => datatypes.DTERROR_INVALID_DATA,
    };
}

/// The object's file opened and a stream on it, and the superclass told
/// what the sound is. What went wrong, or 0.
fn openSound(base: *Base, cl: *Class, o: *Object, own: *Data) i32 {
    const ib = base.intuition_base;
    const dl = dosOf(base);
    const acb = codecOf(base);
    if (subclass.superAsk(ib, cl, o, dtc.DTA_SourceType) != dtc.DTST_FILE) return datatypes.DTERROR_COULDNT_OPEN;
    const lock: ?*dos.FileLock = @ptrFromInt(subclass.superAsk(ib, cl, o, dtc.DTA_Handle));
    const copy = dl.DupLock(lock orelse return datatypes.DTERROR_COULDNT_OPEN) orelse return datatypes.DTERROR_COULDNT_OPEN;
    const file = dl.OpenFromLock(copy) orelse {
        dl.UnLock(copy);
        return datatypes.DTERROR_COULDNT_OPEN;
    };
    own.file = file;
    var err: i32 = 0;
    own.stream = acb.OpenAudioStream(&[_]TagItem{
        .{ .tag = ac.ACA_FileHandle, .data = @intFromPtr(file) },
        .{},
    }, &err) orelse return errorFor(err);
    const stream = own.stream.?;

    var info: ac.AudioStreamInfo = .{};
    acb.GetAudioStreamInfo(stream, &info);
    // The names at full length where the library hands them out (1.1).
    var title: [*:0]const u8 = @ptrCast(&info.title);
    var artist: [*:0]const u8 = @ptrCast(&info.artist);
    var album: [*:0]const u8 = @ptrCast(&info.album);
    if (acb.lib().revision >= 1) {
        _ = acb.GetAudioStreamAttrs(stream, &[_]TagItem{
            .{ .tag = ac.ACA_Title, .data = @intFromPtr(&title) },
            .{ .tag = ac.ACA_Artist, .data = @intFromPtr(&artist) },
            .{ .tag = ac.ACA_Album, .data = @intFromPtr(&album) },
            .{},
        });
    }
    subclass.superTell(ib, cl, o, &[_]TagItem{
        .{ .tag = sdt.SDTA_SampleRate, .data = info.rate },
        .{ .tag = sdt.SDTA_Channels, .data = info.channels },
        .{ .tag = sdt.SDTA_Frames, .data = info.frames },
        .{ .tag = if (title[0] != 0) dtc.DTA_ObjName else utility.TAG_IGNORE, .data = @intFromPtr(title) },
        .{ .tag = if (artist[0] != 0) dtc.DTA_ObjAuthor else utility.TAG_IGNORE, .data = @intFromPtr(artist) },
        .{ .tag = if (album[0] != 0) dtc.DTA_ObjAnnotation else utility.TAG_IGNORE, .data = @intFromPtr(album) },
        .{},
    });
    return 0;
}

/// The stream and the file given back.
fn closeSound(base: *Base, kept: *const Data) void {
    if (kept.stream) |stream| codecOf(base).CloseAudioStream(stream);
    if (kept.file) |file| _ = dosOf(base).Close(file);
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
            const own = classes.instData(Data, cl, obj);
            own.* = .{};
            const failure = openSound(base, cl, obj, own);
            if (failure != 0) {
                _ = dosOf(base).SetIoErr(failure);
                ib.DisposeObject(obj);
                return 0;
            }
            return made;
        },
        classusr.OM_DISPOSE => {
            // The player may be in the middle of a piece: the superclass
            // stops it first, and only then may the stream go. The object
            // is gone after that, so what it held is kept here.
            const kept = classes.instData(Data, cl, o.?).*;
            const result = ib.SendSuperMessage(cl, o, msg);
            closeSound(base, &kept);
            return result;
        },
        sdt.SDTM_DECODE => {
            const decode: *sdt.SdtDecode = @ptrCast(@alignCast(msg));
            const stream = classes.instData(Data, cl, o.?).stream orelse return 0;
            const got = codecOf(base).DecodeAudio(stream, decode.samples, decode.frames);
            return if (got > 0) @intCast(got) else 0;
        },
        sdt.SDTM_SEEK => {
            const seek: *sdt.SdtSeek = @ptrCast(@alignCast(msg));
            const stream = classes.instData(Data, cl, o.?).stream orelse return 0;
            return @intFromBool(codecOf(base).SeekAudio(stream, seek.frame) == ac.ACERR_OK);
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
