// SPDX-License-Identifier: MIT
//! Files as Git uses them: one read whole into memory, one written whole,
//! one written as a sink, one read at any offset through a window, and
//! paths put together - each path a NUL-terminated buffer of `path_most`
//! bytes.
//!
//! **Names**: git's paths are UTF-8, and so is a dos name: a path is
//! the name as it is. One that is no UTF-8 - a repository made where
//! names were in another encoding - is read as Latin-1.

const sdk = @import("sdk");
const dos = sdk.dos;
const utf8 = sdk.utility.utf8;
const _git = @import("_git.zig");
const Git = @import("context.zig").Git;

pub const path_most = dos.path_max;
pub const Path = [path_most + 1]u8;

/// The file at `path` read into memory of its own by dos's ReadFile, at
/// most `most` bytes, a NUL after them: null when it cannot be read or is
/// longer (IoErr says why). The caller frees the bytes with `git.free`.
pub fn readWhole(git: *Git, path: [*:0]const u8, most: usize) ?[]u8 {
    var length: usize = 0;
    const bytes = git.dl.ReadFile(path, most, sdk.exec.MEMF_ANY, &length) orelse return null;
    return bytes[0..length];
}

/// `parts` written one after another as the file at `path`, the
/// directories on its way made: false when it could not be (IoErr says
/// why), and then no file is left.
pub fn writeWhole(git: *Git, path: [*:0]const u8, parts: []const []const u8) bool {
    const dl = git.dl;
    if (!dl.CreateDirs(path, false)) return false;
    const file = dl.Open(path, dos.MODE_NEWFILE) orelse return false;
    var written = true;
    for (parts) |part| {
        if (part.len != 0 and dl.Write(file, part.ptr, @intCast(part.len)) != part.len) {
            written = false;
            break;
        }
    }
    if (!dl.Close(file)) written = false;
    if (!written) {
        const code = dl.IoErr();
        _ = dl.DeleteFile(path);
        _ = dl.SetIoErr(code);
    }
    return written;
}

/// `parts` joined into `into`, NUL-terminated: null when they do not fit.
pub fn join(into: *Path, parts: []const []const u8) ?[*:0]const u8 {
    var out: _git.Out = .{ .into = into[0..path_most] };
    for (parts) |part| out.put(part);
    if (out.overflow) return null;
    into[out.at] = 0;
    return @ptrCast(into);
}

/// `parts` joined after the directory `base` - a `/` between them
/// unless `base` ends a device's name - into `into`: null when they do
/// not fit.
pub fn child(into: *Path, base: []const u8, parts: []const []const u8) ?[*:0]const u8 {
    var out: _git.Out = .{ .into = into[0..path_most] };
    out.put(base);
    if (base.len != 0 and base[base.len - 1] != ':' and base[base.len - 1] != '/') out.byte('/');
    for (parts) |part| out.put(part);
    if (out.overflow) return null;
    into[out.at] = 0;
    return @ptrCast(into);
}

/// A file as a sink: each piece written as it comes.
pub const FileSink = struct {
    dl: *sdk.interface.dos.DosBase,
    file: ?*dos.FileHandle,

    fn write(context: *anyopaque, data: []const u8) bool {
        const sink: *FileSink = @ptrCast(@alignCast(context));
        return sink.dl.Write(sink.file, data.ptr, @intCast(data.len)) == data.len;
    }

    pub fn asSink(sink: *FileSink) _git.Sink {
        return .{ .context = sink, .write = write };
    }
};

/// A file read at any offset, through a window of its bytes: reads near
/// one another come from one Read.
pub const Window = struct {
    dl: *sdk.interface.dos.DosBase,
    file: ?*dos.FileHandle,
    at: u64 = 0,
    length: usize = 0,
    bytes: [window_bytes]u8 = undefined,

    pub const window_bytes = 32 * 1024;

    /// The file's bytes from `offset` into `into`: how many - fewer only
    /// at its end - or -1 when reading failed.
    pub fn read(window: *Window, offset: u64, into: []u8) i32 {
        const dl = window.dl;
        if (into.len > window_bytes) {
            if (dl.Seek(window.file, @intCast(offset), dos.OFFSET_BEGINNING) < 0) return -1;
            const got = dl.Read(window.file, into.ptr, @intCast(into.len));
            return if (got < 0) -1 else @intCast(got);
        }
        if (offset < window.at or offset + into.len > window.at + window.length) {
            if (dl.Seek(window.file, @intCast(offset), dos.OFFSET_BEGINNING) < 0) return -1;
            const got = dl.Read(window.file, &window.bytes, window_bytes);
            if (got < 0) return -1;
            window.at = offset;
            window.length = @intCast(got);
        }
        if (offset - window.at > window.length) return 0;
        const start: usize = @intCast(offset - window.at);
        const count = @min(into.len, window.length - start);
        @memcpy(into[0..count], window.bytes[start..][0..count]);
        return @intCast(count);
    }

    fn readAt(context: *anyopaque, offset: u64, into: []u8) i32 {
        const window: *Window = @ptrCast(@alignCast(context));
        return window.read(offset, into);
    }

    /// The window as a pack's source.
    pub fn source(window: *Window) @import("packread.zig").Source {
        return .{ .context = window, .read = readAt };
    }
};

/// The dos name for a git path, in `into`: the path as it is, or read
/// as Latin-1 when it is no UTF-8; null when it is too long.
pub fn localName(into: []u8, name: []const u8) ?[]u8 {
    if (utf8.valid(name)) {
        if (name.len > into.len) return null;
        @memcpy(into[0..name.len], name);
        return into[0..name.len];
    }
    var needed = name.len;
    for (name) |char| needed += char >> 7;
    if (needed > into.len) return null;
    return into[0..utf8.fromLatin1(name, into)];
}

/// The git path for a dos name, in `into`: the name as it is. Null when
/// it is too long.
pub fn gitName(into: []u8, name: []const u8) ?[]u8 {
    if (name.len > into.len) return null;
    @memcpy(into[0..name.len], name);
    return into[0..name.len];
}

/// A byte of a server's text as the console is given it: a 7-bit control
/// as `?`, the rest - UTF-8's bytes among them - as it is. The line ends
/// are the caller's.
pub fn shown(char: u8) u8 {
    return if (char < ' ' or char == 0x7F) '?' else char;
}

/// The length of a NUL-terminated string.
pub fn span(text: [*:0]const u8) []const u8 {
    var length: usize = 0;
    while (text[length] != 0) length += 1;
    return text[0..length];
}
