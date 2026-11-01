// SPDX-License-Identifier: MIT
//! The decoder of a film's pictures: a codec module from LIBS:codecs/
//! (sdk/libs/videocodec/vcodec.zig), chosen for the track's codec, and the
//! frames it hands out.
//!
//! **The modules there are.** Each time a film is opened, LIBS:codecs/ is
//! looked through: a file whose name, date and size are those it had when
//! its tag was last read keeps what that tag said; any other has its tag
//! read (sdk/libs/dos/loadfile.zig) - a library's, followed by
//! `VCODEC_MAGIC`. Nothing is loaded for that. The table is in the base,
//! shared by every opener, under `modules_lock`.
//!
//! **Choosing.** The modules whose tag names the codec are tried in turn:
//! a chip's before software, the higher priority first, then by name. A
//! module is opened by "codecs/<file>"; when an older one of that name is
//! in memory than its file now holds, the old one is asked to go first,
//! so the file's is loaded. The first whose OpenVCodec takes the track
//! decodes it; the others are closed again, to be expunged.
//!
//! **Decoding.** A frame is asked for, and while the decoder wants data
//! the track's next packet is sent - marked VCPKT_DROP when it is due
//! before what is shown, after a seek - and at the end of the track the
//! end. A packet the decoder has no room for is kept and sent before the
//! next is read. A frame due before what is shown is given back at once.
//! The frame a program is lent is a copy of the decoder's, which is kept
//! by slot, with the decoder's `private`, for ReleaseVCodecFrame.
//!
//! **A decoder that refuses the stream** - VCERR_UNSUPPORTED before the
//! first frame is handed out, as the WAVE511 does 10-bit H.264 - is closed,
//! the next module that takes the track opened, and the track moved back
//! to its key packet at or before the first frame to show; a film read
//! through a function cannot be moved back, and keeps the refusal.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const media = sdk.media;
const vc = sdk.videocodec;
const vcodec = sdk.vcodec;
const loadfile = dos.loadfile;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const VCodecBase = sdk.interface.vcodec.VCodecBase;
const VideoCodecBase = @import("../videocodec_base.zig").VideoCodecBase;
const _stream = @import("../stream/_stream.zig");
const Stream = _stream.Stream;

/// The most modules kept in the table.
pub const max_modules = 16;

/// A module found in LIBS:codecs/: what it is opened by, what its file
/// was when its tag was read, and what the tag says.
pub const Module = struct {
    /// "codecs/<file>", NUL-terminated.
    name: [40]u8 = @splat(0),
    date: dos.DateStamp = .{},
    size: u64 = 0,
    version: u8 = 0,
    revision: u16 = 0,
    codecs: u32 = 0,
    kind: u32 = 0,
    priority: i32 = 0,
};

/// The modules there are, in the base's `modules`.
pub const Table = struct {
    count: u32 = 0,
    list: [max_modules]Module = @splat(.{}),
};

/// The host tests' modules, made with InitResident: the table as given,
/// LIBS:codecs/ not read - each `name` as the host's exec finds it.
pub var test_modules: ?[]const Module = null;

/// The decoder of a stream's pictures.
pub const Decoder = struct {
    /// The module and its decoder.
    lib: ?*exec.Library = null,
    vb: ?*VCodecBase = null,
    handle: ?*vcodec.VCodecDecoder = null,
    /// The modules that decode the track, in the order they are tried,
    /// and which of them is the decoder.
    candidates: [max_modules]Module = @splat(.{}),
    count: u32 = 0,
    current: u32 = 0,
    /// A packet the decoder had no room for, sent before the next is
    /// read: its bytes are media.library's, which stay while the track is
    /// not read.
    pending: bool = false,
    packet: vcodec.VCodecPacket = .{},
    /// The end of the track was sent.
    fed_end: bool = false,
    /// The frames lent out, as the decoder handed them out, by slot.
    lent: [_stream.held_frames]vc.VideoFrame = @splat(.{}),
};

/// A decoder for the stream's picture track, from the modules that
/// decode its codec. VCERR_OK, or why none took it: the first refusal
/// that was not VCERR_NOCODEC, else VCERR_NOCODEC.
pub fn open(s: *Stream) i32 {
    const d = &s.decoder;
    d.* = .{};
    d.count = choose(s.base, s.codec, &d.candidates);
    return openFrom(s, 0);
}

/// The first of the candidates from `first` on that takes the track
/// opened as the decoder.
fn openFrom(s: *Stream, first: u32) i32 {
    const d = &s.decoder;
    const sys = s.sys;
    var why: i32 = vc.VCERR_NOCODEC;
    const config_size: u32 = if (s.picture.config != null) s.picture.config_size else 0;
    const params: vcodec.VCodecParams = .{
        .codec = s.codec,
        .config = s.picture.config,
        .config_size = config_size,
        .width = s.picture.width,
        .height = s.picture.height,
        .max_packet = s.picture.max_packet,
        .held = _stream.held_frames,
    };
    var index = first;
    while (index < d.count) : (index += 1) {
        const lib = openModule(sys, &d.candidates[index]) orelse continue;
        const vb: *VCodecBase = @ptrCast(lib);
        var err: i32 = vc.VCERR_OK;
        if (vb.OpenVCodec(&params, &err)) |handle| {
            d.lib = lib;
            d.vb = vb;
            d.handle = handle;
            d.current = index;
            return vc.VCERR_OK;
        }
        sys.CloseLibrary(lib);
        if (why == vc.VCERR_NOCODEC and err != vc.VCERR_OK) why = err;
    }
    return why;
}

/// The decoder closed, with the frames still lent, and its module.
pub fn close(s: *Stream) void {
    const d = &s.decoder;
    if (d.handle) |handle| d.vb.?.CloseVCodec(handle);
    if (d.lib) |lib| s.sys.CloseLibrary(lib);
    d.lib = null;
    d.vb = null;
    d.handle = null;
}

/// The next frame to be shown into `frame`, lent in `slot`: VCERR_OK,
/// VCERR_END after the last, or why not.
pub fn decode(s: *Stream, frame: *vc.VideoFrame, slot: u32) i32 {
    const d = &s.decoder;
    while (true) {
        var got: vc.VideoFrame = .{};
        const received = d.vb.?.ReceiveVCodecFrame(d.handle.?, &got);
        switch (received) {
            vc.VCERR_OK => {
                if (got.time < s.shown_from) {
                    d.vb.?.ReleaseVCodecFrame(d.handle.?, &got);
                    continue;
                }
                d.lent[slot] = got;
                frame.* = got;
                return vc.VCERR_OK;
            },
            vc.VCERR_NEED_DATA => {
                const fed = feed(s);
                if (fed != vc.VCERR_OK) return fed;
            },
            vc.VCERR_UNSUPPORTED => {
                if (s.number != 0 or !another(s)) return received;
            },
            else => return received,
        }
    }
}

/// The frame lent in `slot` given back to the decoder.
pub fn release(s: *Stream, slot: u32) void {
    const d = &s.decoder;
    d.vb.?.ReleaseVCodecFrame(d.handle.?, &d.lent[slot]);
    d.lent[slot] = .{};
}

/// What was sent and not yet shown forgotten, for a seek.
pub fn flush(s: *Stream) void {
    const d = &s.decoder;
    d.vb.?.FlushVCodec(d.handle.?);
    d.pending = false;
    d.fed_end = false;
}

/// What the decoder read from the stream, into `info`: false while it
/// has read nothing to say it from.
pub fn streamInfo(s: *Stream, info: *vcodec.VCodecInfo) bool {
    const d = &s.decoder;
    return d.vb.?.GetVCodecInfo(d.handle.?, info) == vc.VCERR_OK;
}

/// The track's next packet sent, a packet kept sent again, or the end
/// sent. VCERR_OK, or why not.
fn feed(s: *Stream) i32 {
    const d = &s.decoder;
    if (d.pending) {
        // The decoder wants data, and has no room for what it was sent:
        // it can take no more than it has. Passed over, rather than sent
        // forever.
        d.pending = false;
        const sent = d.vb.?.SendVCodecPacket(d.handle.?, &d.packet);
        return if (sent == vc.VCERR_FULL) vc.VCERR_CORRUPT else sent;
    }
    if (d.fed_end) return vc.VCERR_END;
    var packet: media.MediaPacket = .{};
    const read = _stream.nextPacket(s, &packet);
    if (read == media.MERR_END) {
        d.fed_end = true;
        return send(s, .{ .flags = vcodec.VCPKT_END });
    }
    if (read != media.MERR_OK) return _stream.fromMedia(read);
    var flags: u32 = 0;
    if (packet.flags & media.MPKT_KEY != 0) flags |= vcodec.VCPKT_KEY;
    if (packet.pts < s.shown_from) flags |= vcodec.VCPKT_DROP;
    return send(s, .{ .data = packet.data, .size = packet.size, .time = packet.pts, .flags = flags });
}

/// A packet sent; kept when the decoder has no room for it yet, and sent
/// again after the next frame is taken.
fn send(s: *Stream, packet: vcodec.VCodecPacket) i32 {
    const d = &s.decoder;
    const sent = d.vb.?.SendVCodecPacket(d.handle.?, &packet);
    if (sent != vc.VCERR_FULL) return sent;
    d.packet = packet;
    d.pending = true;
    return vc.VCERR_OK;
}

/// The decoder that refused the stream replaced by the next module that
/// takes the track, and the track moved back to where the first frame to
/// show is decoded from. False when there is none, or the film cannot
/// move: the decoder that refused stays.
fn another(s: *Stream) bool {
    const d = &s.decoder;
    if (s.file_info.seekable == 0 or d.current + 1 >= d.count) return false;
    const old_lib = d.lib;
    const old_vb = d.vb;
    const old_handle = d.handle;
    const old_current = d.current;
    if (openFrom(s, old_current + 1) != vc.VCERR_OK) {
        d.lib = old_lib;
        d.vb = old_vb;
        d.handle = old_handle;
        d.current = old_current;
        return false;
    }
    old_vb.?.CloseVCodec(old_handle.?);
    s.sys.CloseLibrary(old_lib.?);
    d.pending = false;
    d.fed_end = false;
    // The key packet at or before the first frame to show, read again.
    s.peeked = false;
    if (s.mb.SeekMedia(s.file, s.track, s.shown_from) != media.MERR_OK) return true;
    if (s.mb.ReadMediaPacket(s.file, s.track, &s.packet) == media.MERR_OK) s.peeked = true;
    return true;
}

// --- the modules there are -----------------------------------------------------

/// The modules that decode `codec` into `out`, in the order they are
/// tried: how many. On a process: LIBS:codecs/ is read.
fn choose(base: *VideoCodecBase, codec: u32, out: *[max_modules]Module) u32 {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.modules_lock);
    defer sys.ReleaseSemaphore(&base.modules_lock);
    const table = refresh(base) orelse return 0;
    const bit = vcodec.codecBit(codec);
    var count: u32 = 0;
    for (table.list[0..table.count]) |module| {
        if (module.codecs & bit == 0) continue;
        // Most to be tried first: few of them, so a plain insertion sort.
        var at = count;
        while (at > 0 and before(module, out[at - 1])) : (at -= 1) out[at] = out[at - 1];
        out[at] = module;
        count += 1;
    }
    return count;
}

/// Whether `a` is tried before `b`: a chip's before software, the higher
/// priority first, then by name.
fn before(a: Module, b: Module) bool {
    if (a.kind != b.kind) return rank(a.kind) < rank(b.kind);
    if (a.priority != b.priority) return a.priority > b.priority;
    for (a.name, b.name) |x, y| {
        if (x != y) return x < y;
        if (x == 0) break;
    }
    return false;
}

fn rank(kind: u32) u32 {
    return switch (kind) {
        vcodec.VCMOD_CHIP => 0,
        vcodec.VCMOD_SOFTWARE => 1,
        else => 2,
    };
}

/// The table brought up to date with LIBS:codecs/. Under `modules_lock`;
/// null without memory for it.
fn refresh(base: *VideoCodecBase) ?*Table {
    const sys = base.sys_base;
    const table: *Table = if (base.modules) |found| @ptrCast(@alignCast(found)) else made: {
        // Kept in the library's base: the system's.
        const memory = sys.AllocMem(@sizeOf(Table), exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return null;
        const table: *Table = @ptrCast(@alignCast(memory));
        table.* = .{};
        base.modules = table;
        break :made table;
    };
    if (test_modules) |given| {
        table.count = @intCast(@min(given.len, max_modules));
        for (given[0..table.count], 0..) |module, i| table.list[i] = module;
        return table;
    }
    const dl = base.dos_base;
    var fresh: Table = .{};
    defer table.* = fresh;
    const dir = dl.Lock(vcodec.VCODEC_DIR, dos.SHARED_LOCK) orelse return table;
    defer dl.UnLock(dir);
    var fib: dos.FileInfoBlock = .{};
    if (!dl.Examine(dir, &fib)) return table;
    while (dl.ExNext(dir, &fib)) {
        if (dos.isDirectory(fib.dir_entry_type)) continue;
        if (fresh.count >= max_modules) break;
        const into = &fresh.list[fresh.count];
        if (!nameOf(into, fileName(&fib))) continue;
        if (known(table, into.name, fib.date, fib.size)) |module| {
            into.* = module;
        } else {
            if (!readModule(dl, into, fileName(&fib))) continue;
            into.date = fib.date;
            into.size = fib.size;
        }
        fresh.count += 1;
    }
    return table;
}

fn fileName(fib: *const dos.FileInfoBlock) []const u8 {
    var length: usize = 0;
    while (length < fib.file_name.len and fib.file_name[length] != 0) length += 1;
    return fib.file_name[0..length];
}

/// "codecs/<file>" into `module.name`; false when it does not fit.
fn nameOf(module: *Module, file_name: []const u8) bool {
    const prefix = "codecs/";
    module.* = .{};
    if (prefix.len + file_name.len + 1 > module.name.len) return false;
    @memcpy(module.name[0..prefix.len], prefix);
    @memcpy(module.name[prefix.len..][0..file_name.len], file_name);
    return true;
}

/// The module of that name the table has, if its file is as it was.
fn known(table: *const Table, name: [40]u8, date: dos.DateStamp, size: u64) ?Module {
    for (table.list[0..table.count]) |module| {
        if (!sameName(&module.name, &name)) continue;
        if (module.date.eql(date) and module.size == size) return module;
        return null;
    }
    return null;
}

fn sameName(a: *const [40]u8, b: *const [40]u8) bool {
    for (a, b) |x, y| {
        if (x != y) return false;
        if (x == 0) return true;
    }
    return true;
}

/// A file read through dos for `loadfile`'s reader.
const DosFile = struct {
    dl: *DosBase,
    file: *dos.FileHandle,

    fn readAt(context: *anyopaque, offset: u32, into: []u8) bool {
        const self: *DosFile = @ptrCast(@alignCast(context));
        if (self.dl.Seek(self.file, @intCast(offset), dos.OFFSET_BEGINNING) < 0) return false;
        const got = self.dl.Read(self.file, into.ptr, @intCast(into.len));
        return got == @as(isize, @intCast(into.len));
    }
};

/// A file's tag into `module`, if it is a codec module's - named as the
/// file, which ramlib loads it by.
fn readModule(dl: *DosBase, module: *Module, file_name: []const u8) bool {
    var path: [96]u8 = @splat(0);
    const dir_part = vcodec.VCODEC_DIR ++ "/";
    if (dir_part.len + file_name.len + 1 > path.len) return false;
    @memcpy(path[0..dir_part.len], dir_part);
    @memcpy(path[dir_part.len..][0..file_name.len], file_name);
    const file = dl.Open(@ptrCast(&path), dos.MODE_OLDFILE) orelse return false;
    defer _ = dl.Close(file);
    var reader = DosFile{ .dl = dl, .file = file };
    return readTag(.{ .context = &reader, .readAt = DosFile.readAt }, module, file_name);
}

/// A load file's tag into `module`: false when it is not a codec
/// module's, or is named otherwise than `file_name`.
pub fn readTag(source: loadfile.Source, module: *Module, file_name: []const u8) bool {
    const found = loadfile.findResident(source) orelse return false;
    var tag: loadfile.LibraryTag = .{};
    if (!loadfile.readLibrary(source, found, &tag)) return false;
    var length: usize = 0;
    while (tag.name[length] != 0) length += 1;
    const name = tag.name[0..length];
    if (name.len != file_name.len) return false;
    for (name, file_name) |a, b| {
        if (lower(a) != lower(b)) return false;
    }
    const magic = loadfile.readWord(source, found, tag.after) orelse return false;
    if (magic != vcodec.VCODEC_MAGIC) return false;
    module.codecs = loadfile.readWord(source, found, tag.after + 4) orelse return false;
    module.kind = loadfile.readWord(source, found, tag.after + 8) orelse return false;
    module.priority = @bitCast(loadfile.readWord(source, found, tag.after + 12) orelse return false);
    module.version = tag.version;
    module.revision = tag.revision;
    return true;
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// The module opened by its name; when an older one of that name is in
/// memory than its file holds, that one asked to go first - it goes at
/// this close, unless another film has it - and the file's opened.
fn openModule(sys: *ExecBase, module: *const Module) ?*exec.Library {
    const name: [*:0]const u8 = @ptrCast(&module.name);
    const lib = sys.OpenLibrary(name, module.version) orelse return null;
    const older = lib.version < module.version or (lib.version == module.version and lib.revision < module.revision);
    if (!older) return lib;
    _ = sys.RemLibrary(lib);
    sys.CloseLibrary(lib);
    return sys.OpenLibrary(name, module.version);
}

/// The table let go of, at the expunge.
pub fn forget(base: *VideoCodecBase) void {
    const found = base.modules orelse return;
    base.sys_base.FreeMem(found, @sizeOf(Table));
    base.modules = null;
}
