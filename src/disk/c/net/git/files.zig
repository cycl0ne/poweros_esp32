// SPDX-License-Identifier: MIT
//! Files as Git uses them: one read whole into memory, one written whole,
//! one written as a sink, one read at any offset through a window, the
//! directories on a path made, a directory removed with all it holds, and
//! paths put together - each path a NUL-terminated buffer of `path_most`
//! bytes.
//!
//! **Names**: git's paths are UTF-8, a dos name Latin-1. A path whose
//! characters Latin-1 all has is written as Latin-1 (`ä` one byte), any
//! other byte for byte.

const sdk = @import("sdk");
const dos = sdk.dos;
const utility = sdk.utility;
const UtilityBase = sdk.interface.utility.UtilityBase;
const _git = @import("_git.zig");
const Git = @import("context.zig").Git;

pub const path_most = dos.path_max;
pub const Path = [path_most + 1]u8;

/// The file at `path` read into memory of its own, at most `most` bytes:
/// null when it cannot be read or is longer (IoErr says why). The
/// caller frees the bytes with `git.free`.
pub fn readWhole(git: *Git, path: [*:0]const u8, most: usize) ?[]u8 {
    const dl = git.dl;
    const file = dl.Open(path, dos.MODE_OLDFILE) orelse return null;
    defer _ = dl.Close(file);
    // Its size, from its end; a byte more is read to see it did not grow.
    if (dl.Seek(file, 0, dos.OFFSET_END) < 0) return null;
    const end = dl.Seek(file, 0, dos.OFFSET_BEGINNING);
    if (end < 0) return null;
    if (end > most) {
        _ = dl.SetIoErr(dos.ERROR_OBJECT_TOO_LARGE);
        return null;
    }
    const size: usize = @intCast(end);
    const memory = git.sys.AllocVec(size + 1, sdk.exec.MEMF_ANY) orelse {
        _ = dl.SetIoErr(dos.ERROR_NO_FREE_STORE);
        return null;
    };
    const bytes: [*]u8 = @ptrCast(memory);
    var length: usize = 0;
    while (length <= size) {
        const got = dl.Read(file, bytes + length, @intCast(size + 1 - length));
        if (got < 0) {
            git.sys.FreeVec(memory);
            return null;
        }
        if (got == 0) break;
        length += @intCast(got);
    }
    if (length > size) {
        git.sys.FreeVec(memory);
        _ = dl.SetIoErr(dos.ERROR_OBJECT_TOO_LARGE);
        return null;
    }
    return bytes[0..length];
}

/// `parts` written one after another as the file at `path`, the
/// directories on its way made: false when it could not be (IoErr says
/// why), and then no file is left.
pub fn writeWhole(git: *Git, path: [*:0]const u8, parts: []const []const u8) bool {
    const dl = git.dl;
    if (!makeDirs(git, path)) return false;
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

/// Every directory on the way to the last part of `path` made where
/// there is none.
pub fn makeDirs(git: *Git, path: [*:0]const u8) bool {
    const dl = git.dl;
    var into: Path = undefined;
    var at: usize = 0;
    while (path[at] != 0) : (at += 1) {
        if (at >= path_most) return false;
        into[at] = path[at];
        if (path[at] != '/' or at == 0 or path[at - 1] == ':') continue;
        into[at] = 0;
        if (dl.Lock(@ptrCast(&into), dos.ACCESS_READ)) |lock| {
            dl.UnLock(lock);
        } else {
            const made = dl.CreateDir(@ptrCast(&into)) orelse return false;
            dl.UnLock(made);
        }
        into[at] = '/';
    }
    return true;
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

/// The directory `path` removed, and all it holds, depth first - itself
/// kept, emptied, with `keep`: false when something in it could not be
/// (IoErr says why). Each removal starts the directory's listing again,
/// so no listing goes on over a name taken from it.
pub fn removeTree(git: *Git, path: [*:0]const u8, keep: bool) bool {
    const dl = git.dl;
    const walk = git.create(RemoveWalk) orelse return false;
    defer git.free(walk);
    var length = span(path).len;
    if (length > path_most) return false;
    @memcpy(walk.path[0..length], path[0..length]);
    walk.path[length] = 0;
    const root_length = length;
    while (true) {
        const lock = dl.Lock(@ptrCast(&walk.path), dos.ACCESS_READ) orelse return false;
        var inside = false;
        var directory = false;
        if (dl.Examine(lock, &walk.fib)) {
            directory = dos.isDirectory(walk.fib.dir_entry_type);
            inside = directory and dl.ExNext(lock, &walk.fib);
        }
        dl.UnLock(lock);
        if (inside) {
            const name = span(@ptrCast(&walk.fib.file_name));
            if (length + 1 + name.len > path_most) return false;
            walk.path[length] = '/';
            @memcpy(walk.path[length + 1 ..][0..name.len], name);
            length += 1 + name.len;
            walk.path[length] = 0;
            if (dos.isDirectory(walk.fib.dir_entry_type)) continue;
            if (!dl.DeleteFile(@ptrCast(&walk.path))) return false;
        } else if (keep and length == root_length) {
            return true;
        } else if (!dl.DeleteFile(@ptrCast(&walk.path))) {
            return false;
        } else if (length == root_length) {
            return true;
        }
        // Up to the directory the removed one was in.
        while (length > root_length and walk.path[length - 1] != '/') length -= 1;
        if (length > root_length) length -= 1;
        walk.path[length] = 0;
    }
}

const RemoveWalk = struct {
    path: Path,
    fib: dos.FileInfoBlock,
};

/// The dos name for a git path, in `into`: Latin-1 when every character
/// of it is one Latin-1 has, else its bytes as they are; null when it is
/// too long.
pub fn localName(ub: *UtilityBase, into: []u8, name: []const u8) ?[]u8 {
    if (name.len > into.len) return null;
    var refuse: utility.Utf8Conversion = .{ .flags = utility.UTF8F_REFUSE };
    const length = ub.Utf8ToLatin1(&refuse, name.ptr, name.len, into.ptr, into.len);
    if (length != utility.UTF8_REFUSED) return into[0..length];
    @memcpy(into[0..name.len], name);
    return into[0..name.len];
}

/// The git path for a dos name, in `into` - what `localName` made
/// Latin-1 made UTF-8 again: a name that is UTF-8 with a character
/// Latin-1 has not is taken as it is, any other read as Latin-1. Null
/// when it is too long.
pub fn gitName(ub: *UtilityBase, into: []u8, name: []const u8) ?[]u8 {
    if (ub.Utf8Kind(name.ptr, name.len) == utility.UTF8KIND_WIDE) {
        if (name.len > into.len) return null;
        @memcpy(into[0..name.len], name);
        return into[0..name.len];
    }
    const length = ub.Latin1ToUtf8(name.ptr, name.len, into.ptr, into.len);
    if (length > into.len) return null;
    return into[0..length];
}

/// A server's UTF-8 text for the console, as utility.library makes it
/// Latin-1 a piece at a time: a character Latin-1 has not a `?`, a byte
/// that starts no UTF-8 character taken as it is. One for each text:
/// the sideband's messages carry theirs (`connect.zig`), each line an
/// SSH server writes has its own (`ssh.zig`).
pub fn serverText() utility.Utf8Conversion {
    return .{ .flags = utility.UTF8F_PIECES | utility.UTF8F_LATIN1 };
}

/// The length of a NUL-terminated string.
pub fn span(text: [*:0]const u8) []const u8 {
    var length: usize = 0;
    while (text[length] != 0) length += 1;
    return text[0..length];
}
