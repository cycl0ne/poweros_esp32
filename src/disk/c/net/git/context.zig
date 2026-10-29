// SPDX-License-Identifier: MIT
//! One run of Git: the libraries open for it, where it writes, how it
//! says what went wrong, and the zone the clock keeps - handed to every
//! verb - and an arena, memory
//! taken in blocks and given back at once, for what a verb collects as
//! it goes (a remote's refs, paths).

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const bsd = sdk.bsdsocket;
const http = sdk.http;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const CompressionBase = sdk.interface.compression.CompressionBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const HttpBase = sdk.interface.http.HttpBase;
const timezone = dos.timezone;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Git";

const MSG_NOLIBRARY = "can't open %s\n";

pub const Git = struct {
    sys: *ExecBase,
    dl: *DosBase,
    cb: *CryptoBase,
    zb: *CompressionBase,
    /// Opened by `network`, the first time a verb needs a remote.
    sb: ?*SocketBase = null,
    hb: ?*HttpBase = null,
    output: ?*dos.FileHandle,
    /// QUIET: progress is not shown.
    quiet: bool = false,
    /// A progress line ended by a carriage return is on the screen: the
    /// next message starts a new line first.
    progress_open: bool = false,
    /// The zone in ENV:Sys/timezone, read the first time a date is
    /// turned into git's time.
    zone: ?timezone.Zone = null,

    /// `format` said on the output after the command's name.
    pub fn say(git: *Git, comptime format: [:0]const u8, args: anytype) void {
        git.endProgress();
        _ = Printf(git.dl, "%s: " ++ format, .{@as([*:0]const u8, COMMAND_NAME)} ++ args);
    }

    /// Bytes as they are onto the output.
    pub fn put(git: *Git, text: []const u8) void {
        if (text.len != 0) _ = git.dl.Write(git.output, text.ptr, @intCast(text.len));
    }

    /// A progress line, overwritten by the next: `format` ended by a
    /// carriage return.
    pub fn progress(git: *Git, comptime format: [:0]const u8, args: anytype) void {
        if (git.quiet) return;
        _ = Printf(git.dl, format ++ "\r", args);
        _ = git.dl.Flush(git.output);
        git.progress_open = true;
    }

    /// The progress line left standing, the next output below it.
    pub fn endProgress(git: *Git) void {
        if (!git.progress_open) return;
        git.put("\n");
        git.progress_open = false;
    }

    /// Whether Ctrl-C came.
    pub fn stopped(git: *Git) bool {
        return git.dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0;
    }

    /// bsdsocket.library and http.library, opened the first time: false,
    /// said, when one cannot be.
    pub fn network(git: *Git) bool {
        if (git.hb != null) return true;
        const socket_lib = git.sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse {
            git.say(MSG_NOLIBRARY, .{@as([*:0]const u8, bsd.SOCKETNAME)});
            return false;
        };
        const http_lib = git.sys.OpenLibrary(http.HTTPNAME, 1) orelse {
            git.sys.CloseLibrary(socket_lib);
            git.say(MSG_NOLIBRARY, .{@as([*:0]const u8, http.HTTPNAME)});
            return false;
        };
        git.sb = @ptrCast(socket_lib);
        git.hb = @ptrCast(http_lib);
        return true;
    }

    /// What `network` opened, closed.
    pub fn close(git: *Git) void {
        git.endProgress();
        if (git.hb) |hb| git.sys.CloseLibrary(hb.lib());
        if (git.sb) |sb| git.sys.CloseLibrary(sb.lib());
        git.hb = null;
        git.sb = null;
    }

    /// A dos date - the local time - as git keeps time: seconds since
    /// 1970 UTC, and the nanoseconds past them.
    pub fn unixTime(git: *Git, date: dos.DateStamp) struct { seconds: i64, nanoseconds: u32 } {
        if (git.zone == null) git.zone = readZone(git.dl);
        const zone = &git.zone.?;
        const ticks_per_second = 50;
        const local = @as(i64, date.days) * 86400 + @as(i64, date.minute) * 60 + @divFloor(date.tick, ticks_per_second) + timezone.datestamp_epoch;
        const guess = local - zone.offsetAt(local);
        const utc = local - zone.offsetAt(guess);
        const ticks: u32 = @intCast(@mod(date.tick, ticks_per_second));
        return .{ .seconds = utc, .nanoseconds = ticks * (1_000_000_000 / ticks_per_second) };
    }

    /// `size` bytes of memory, cleared; null, said, when there are none.
    pub fn alloc(git: *Git, size: usize) ?[*]u8 {
        const memory = git.sys.AllocVec(size, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
            git.say("no memory\n", .{});
            return null;
        };
        return @ptrCast(memory);
    }

    /// A `T` of its own, its fields their defaults or undefined.
    pub fn create(git: *Git, comptime T: type) ?*T {
        const memory = git.alloc(@sizeOf(T)) orelse return null;
        return @ptrCast(@alignCast(memory));
    }

    pub fn free(git: *Git, memory: ?*const anyopaque) void {
        if (memory) |block| git.sys.FreeVec(@constCast(block));
    }
};

/// The zone the system clock keeps: the rule on the zone file's first
/// line that is not a comment, however long the comments before it; UTC
/// without one.
fn readZone(dl: *DosBase) timezone.Zone {
    const file = dl.Open(timezone.zone_file, dos.MODE_OLDFILE) orelse return .{};
    defer _ = dl.Close(file);
    var text: [256]u8 = undefined;
    // A line longer than the buffer comes in pieces; only the first
    // piece of a line is looked at.
    var line_start = true;
    while (dl.FGets(file, &text, text.len) != null) {
        var length: usize = 0;
        while (length < text.len and text[length] != 0) length += 1;
        const starts = line_start;
        line_start = length > 0 and text[length - 1] == '\n';
        if (!starts) continue;
        var line: []const u8 = text[0..length];
        while (line.len > 0 and (line[line.len - 1] == '\n' or line[line.len - 1] == '\r' or line[line.len - 1] == ' ' or line[line.len - 1] == '\t')) line = line[0 .. line.len - 1];
        while (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) line = line[1..];
        if (line.len == 0 or line[0] == '#') continue;
        return timezone.parse(line) orelse .{};
    }
    return .{};
}

/// Memory handed out from blocks taken as needed, all given back by
/// `free`.
pub const Arena = struct {
    sys: *ExecBase,
    /// The newest block; each holds the one before it.
    block: ?*Block = null,
    at: usize = 0,
    end: usize = 0,

    const Block = struct { older: ?*Block };
    const block_bytes = 16 * 1024;

    /// `size` bytes aligned to `alignment`; null when there is no memory.
    pub fn take(arena: *Arena, size: usize, alignment: usize) ?[*]u8 {
        var start = (arena.at + alignment - 1) & ~(alignment - 1);
        if (arena.block == null or start + size > arena.end) {
            const wanted = @max(block_bytes, size + @sizeOf(Block) + alignment);
            const memory = arena.sys.AllocVec(wanted, exec.MEMF_ANY) orelse return null;
            const block: *Block = @ptrCast(@alignCast(memory));
            block.older = arena.block;
            arena.block = block;
            arena.at = @intFromPtr(block) + @sizeOf(Block);
            arena.end = @intFromPtr(block) + wanted;
            start = (arena.at + alignment - 1) & ~(alignment - 1);
        }
        arena.at = start + size;
        return @ptrFromInt(start);
    }

    /// A `T`, set to `value`.
    pub fn create(arena: *Arena, comptime T: type, value: T) ?*T {
        const memory = arena.take(@sizeOf(T), @alignOf(T)) orelse return null;
        const made: *T = @ptrCast(@alignCast(memory));
        made.* = value;
        return made;
    }

    /// `bytes` copied, with a NUL after them that the slice leaves out.
    pub fn copy(arena: *Arena, bytes: []const u8) ?[:0]u8 {
        const memory = arena.take(bytes.len + 1, 1) orelse return null;
        @memcpy(memory[0..bytes.len], bytes);
        memory[bytes.len] = 0;
        return memory[0..bytes.len :0];
    }

    pub fn free(arena: *Arena) void {
        var block = arena.block;
        while (block) |each| {
            block = each.older;
            arena.sys.FreeVec(each);
        }
        arena.* = .{ .sys = arena.sys };
    }
};
