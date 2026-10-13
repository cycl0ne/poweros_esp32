// SPDX-License-Identifier: MIT
//! 8svx.datatype: an IFF 8SVX sound as a sound.
//!
//! A sound.datatype subclass. It reads the file in `OM_NEW` through
//! iffparse - the voice header (`VHDR`), the sound's name (`NAME`),
//! author (`AUTH`) and annotation (`ANNO`), which channels it has
//! (`CHAN`), and the body (`BODY`) - and hands the samples to its
//! superclass as a sound in memory (`SDTA_Sample`, 8 bits), which plays
//! them from there.
//!
//! An 8SVX sound is short - an instrument, an effect - and is read whole.
//! A body coded Fibonacci-delta is unpacked, a body of two channels put
//! together into frames (body.zig). The voice header's octaves past the
//! first, which an instrument plays at other pitches, are left out: the
//! sound is its first octave's one-shot and repeat parts, played once.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gadgets = sdk.gadgets;
const datatypes = sdk.datatypes;
const iffparse = sdk.iffparse;
const audio = sdk.devices.audio;
const subclass = datatypes.subclass;
const dtc = datatypes.datatypesclass;
const sdt = datatypes.soundclass;
const body = @import("body.zig");
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IFFParseBase = sdk.interface.iffparse.IFFParseBase;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Base = gadgets.Base;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = "8svx.datatype",
    .version = 1,
    .date = "13.10.2026",
    .super = sdt.SOUNDDTCLASS,
    .opens = &.{ sdt.SOUND_LIBRARY, iffparse.IFFPARSENAME, dos.DOSNAME },
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

const opened_iffparse = 1;
const opened_dos = 2;

const ID_8SVX = iffparse.MakeID("8SVX");
const ID_VHDR = iffparse.MakeID("VHDR");
const ID_BODY = iffparse.MakeID("BODY");
const ID_NAME = iffparse.MakeID("NAME");
const ID_AUTH = iffparse.MakeID("AUTH");
const ID_ANNO = iffparse.MakeID("ANNO");
const ID_CHAN = iffparse.MakeID("CHAN");

/// `VHDR`'s sCompression.
const cmp_none = 0;
const cmp_fibdelta = 1;
/// `CHAN`: both channels.
const chan_stereo = 6;

/// 8svx.datatype's part of an object: the samples, and the texts the
/// superclass is given, kept for as long as the object.
pub const Data = extern struct {
    samples: ?[*]i8 = null,
    name: [64:0]u8 = @splat(0),
    author: [64:0]u8 = @splat(0),
    annotation: [128:0]u8 = @splat(0),
};

fn iffOf(base: *Base) *IFFParseBase {
    return @ptrCast(base.opened[opened_iffparse].?);
}

fn dosOf(base: *Base) *DosBase {
    return @ptrCast(base.opened[opened_dos].?);
}

fn be32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) << 24 | @as(u32, bytes[1]) << 16 | @as(u32, bytes[2]) << 8 | bytes[3];
}

/// A text chunk's words into `into`, cut where it is full.
fn keepText(ip: *IFFParseBase, iff: *iffparse.IFFHandle, id: u32, into: []u8) bool {
    const said = ip.FindProp(iff, ID_8SVX, id) orelse return false;
    const bytes = (said.data orelse return false)[0..@intCast(said.size)];
    var length: usize = 0;
    while (length < bytes.len and length < into.len - 1 and bytes[length] != 0) : (length += 1) into[length] = bytes[length];
    into[length] = 0;
    return length > 0;
}

/// The form read and the samples handed to the superclass. What went
/// wrong, or 0.
fn readForm(base: *Base, cl: *Class, o: *Object, own: *Data, iff: *iffparse.IFFHandle) i32 {
    const sys = base.sys_base;
    const ip = iffOf(base);
    for ([_]u32{ ID_VHDR, ID_NAME, ID_AUTH, ID_ANNO, ID_CHAN }) |id| _ = ip.PropChunk(iff, ID_8SVX, id);
    _ = ip.StopChunk(iff, ID_8SVX, ID_BODY);
    if (ip.ParseIFF(iff, iffparse.IFFPARSE_SCAN) != 0) return datatypes.DTERROR_INVALID_DATA;

    const said = ip.FindProp(iff, ID_8SVX, ID_VHDR) orelse return datatypes.DTERROR_INVALID_DATA;
    if (said.size < 20) return datatypes.DTERROR_INVALID_DATA;
    const header = (said.data orelse return datatypes.DTERROR_INVALID_DATA)[0..20];
    const one_shot = be32(header[0..4]);
    const repeat = be32(header[4..8]);
    const rate: u32 = @as(u32, header[12]) << 8 | header[13];
    const compression = header[15];
    if (rate == 0) return datatypes.DTERROR_INVALID_DATA;
    if (compression != cmp_none and compression != cmp_fibdelta) return datatypes.DTERROR_UNKNOWN_COMPRESSION;
    var stereo = false;
    if (ip.FindProp(iff, ID_8SVX, ID_CHAN)) |chan| {
        if (chan.size >= 4) stereo = be32((chan.data orelse return datatypes.DTERROR_INVALID_DATA)[0..4]) == chan_stereo;
    }

    const chunk = ip.CurrentChunk(iff) orelse return datatypes.DTERROR_INVALID_DATA;
    if (chunk.size <= 0) return datatypes.DTERROR_NOT_ENOUGH_DATA;
    const size: usize = @intCast(chunk.size);
    if (!subclass.roomFor(sys, size * 3)) return datatypes.DTERROR_TOO_LARGE;
    const raw_memory = sys.AllocVec(size, exec.MEMF_ANY) orelse return dos.ERROR_NO_FREE_STORE;
    defer sys.FreeVec(raw_memory);
    const raw: [*]u8 = @ptrCast(raw_memory);
    if (ip.ReadChunkBytes(iff, raw, @intCast(size)) != @as(i32, @intCast(size))) return datatypes.DTERROR_NOT_ENOUGH_DATA;

    // Each channel's part of the body, unpacked where it is coded.
    const parts: usize = if (stereo) 2 else 1;
    const part_bytes = size / parts;
    const per_channel = if (compression == cmp_fibdelta) body.unpackedLength(part_bytes) else part_bytes;
    if (per_channel == 0) return datatypes.DTERROR_NOT_ENOUGH_DATA;
    const total = per_channel * parts;
    const memory = sys.AllocVec(total * 2, exec.MEMF_ANY) orelse return dos.ERROR_NO_FREE_STORE;
    const samples: [*]i8 = @ptrCast(memory);
    own.samples = samples;
    // Unpacked into the second half, then put together into the first.
    const plain = samples + total;
    for (0..parts) |part| {
        const from = raw[part * part_bytes ..][0..part_bytes];
        const into = plain[part * per_channel ..][0..per_channel];
        if (compression == cmp_fibdelta) body.unpack(from, into) else @memcpy(into, @as([]const i8, @ptrCast(from)));
    }
    if (stereo) body.interleave(plain[0..per_channel], plain[per_channel..][0..per_channel], samples[0..total]) else @memcpy(samples[0..total], plain[0..total]);

    // The first octave: its one-shot and repeat parts, where the header
    // gives them and the body holds them.
    var frames: u32 = @intCast(per_channel);
    const first_octave = one_shot +| repeat;
    if (first_octave != 0 and first_octave < frames) frames = first_octave;

    const has_name = keepText(ip, iff, ID_NAME, &own.name);
    const has_author = keepText(ip, iff, ID_AUTH, &own.author);
    const has_annotation = keepText(ip, iff, ID_ANNO, &own.annotation);
    subclass.superTell(base.intuition_base, cl, o, &[_]TagItem{
        .{ .tag = sdt.SDTA_SampleRate, .data = rate },
        .{ .tag = sdt.SDTA_Channels, .data = parts },
        .{ .tag = sdt.SDTA_SampleType, .data = audio.AUDIO_S8 },
        .{ .tag = sdt.SDTA_Sample, .data = @intFromPtr(samples) },
        .{ .tag = sdt.SDTA_SampleLength, .data = frames },
        .{ .tag = sdt.SDTA_Frames, .data = frames },
        .{ .tag = if (has_name) dtc.DTA_ObjName else utility.TAG_IGNORE, .data = @intFromPtr(&own.name) },
        .{ .tag = if (has_author) dtc.DTA_ObjAuthor else utility.TAG_IGNORE, .data = @intFromPtr(&own.author) },
        .{ .tag = if (has_annotation) dtc.DTA_ObjAnnotation else utility.TAG_IGNORE, .data = @intFromPtr(&own.annotation) },
        .{},
    });
    return 0;
}

/// The object's own source read: a file opened from its lock, or the
/// clipboard stream it was handed.
fn readSource(base: *Base, cl: *Class, o: *Object, own: *Data) i32 {
    const ib = base.intuition_base;
    const ip = iffOf(base);
    const dl = dosOf(base);
    const source = subclass.superAsk(ib, cl, o, dtc.DTA_SourceType);
    const handle: ?*anyopaque = @ptrFromInt(subclass.superAsk(ib, cl, o, dtc.DTA_Handle));
    if (source == dtc.DTST_CLIPBOARD) {
        const iff: *iffparse.IFFHandle = @ptrCast(@alignCast(handle orelse return datatypes.DTERROR_COULDNT_OPEN));
        return readForm(base, cl, o, own, iff);
    }
    const lock: ?*dos.FileLock = @ptrCast(@alignCast(handle));
    const copy = dl.DupLock(lock orelse return datatypes.DTERROR_COULDNT_OPEN) orelse return datatypes.DTERROR_COULDNT_OPEN;
    const file = dl.OpenFromLock(copy) orelse {
        dl.UnLock(copy);
        return datatypes.DTERROR_COULDNT_OPEN;
    };
    defer _ = dl.Close(file);
    const iff = ip.AllocIFF() orelse return dos.ERROR_NO_FREE_STORE;
    defer ip.FreeIFF(iff);
    iff.stream = @intFromPtr(file);
    ip.InitIFFasDOS(iff);
    if (ip.OpenIFF(iff, iffparse.IFFF_READ) != 0) return datatypes.DTERROR_COULDNT_OPEN;
    defer ip.CloseIFF(iff);
    return readForm(base, cl, o, own, iff);
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
            const failure = readSource(base, cl, obj, own);
            if (failure != 0) {
                _ = dosOf(base).SetIoErr(failure);
                ib.DisposeObject(obj);
                return 0;
            }
            return made;
        },
        classusr.OM_DISPOSE => {
            // The superclass stops its player first; the samples it
            // plays from may go only then.
            const samples = classes.instData(Data, cl, o.?).samples;
            const result = ib.SendSuperMessage(cl, o, msg);
            if (samples) |memory| base.sys_base.FreeVec(memory);
            return result;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
