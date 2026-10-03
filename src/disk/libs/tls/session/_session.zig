// SPDX-License-Identifier: MIT
//! What every session call shares: the session behind the program's
//! handle, the libraries and stores the base holds for all of them, the
//! clock in UTC, and records over the program's socket.
//!
//! A session is one allocation, in the memory a program's own data goes
//! to: the client (`protocol/client.zig`), a buffer for the record that
//! arrives and one for what goes out, and the bytes already decrypted
//! that the program has not read yet. It is the program's: its socket,
//! in its bsdsocket base, read and written from its task.
//!
//! The base reads what is the same for everybody once, under its lock,
//! when the first session needs it: crypto, dos and utility opened, the
//! trusted roots (`SYS:Certificates/Roots`), the program's own
//! (`ENVARC:Sys/net/certificates/`, PEM files, turned into a store of
//! the same form) and the clock's time zone (`ENVARC:Sys/timezone`). A
//! file that is not there is no failure: no roots trust nothing, no zone
//! is UTC.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const tls = sdk.tls;
const timezone = dos.timezone;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const _base = @import("../tls_base.zig");
const TLSBase = _base.TLSBase;
const client_module = @import("../protocol/client.zig");
const Client = client_module.Client;
const Output = client_module.Output;
const record = @import("../protocol/record.zig");
const certificate = @import("../x509/certificate.zig");
const anchors = @import("../x509/anchors.zig");
const pem = @import("../x509/pem.zig");

pub const roots_file = "SYS:Certificates/Roots";
pub const own_directory = "ENVARC:Sys/net/certificates";
/// The most a program's own roots take as a store.
const own_max = 32768;
/// The longest PEM file of its own read.
const pem_max = 65536;

pub const Session = struct {
    base: *TLSBase,
    sockets: *SocketBase,
    socket: i32,
    last_error: i32 = tls.TLSERR_OK,
    /// The server closed: ReadSession answers 0 from here.
    finished: bool = false,
    host: [256]u8 = @splat(0),
    asked_protocol: [64]u8 = @splat(0),
    /// The protocol the server chose, NUL-terminated, for GetSessionAttr.
    chosen_protocol: [33]u8 = @splat(0),
    stores: [2][]const u8 = .{ &.{}, &.{} },
    /// Decrypted bytes not read yet: a slice of `incoming`.
    waiting: []u8 = &.{},
    client: Client = undefined,
    incoming: [record.header_length + record.max_ciphertext]u8 = undefined,
    outgoing: [record.max_ciphertext + 2048]u8 = undefined,
};

pub fn sessionOf(handle: *tls.Session) *Session {
    return @ptrCast(@alignCast(handle));
}

pub fn handleOf(session: *Session) *tls.Session {
    return @ptrCast(session);
}

// --- what the base shares -----------------------------------------------------

/// The libraries opened and the stores and zone read, once. An error
/// code, or OK.
pub fn ready(base: *TLSBase) i32 {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.lock);
    defer sys.ReleaseSemaphore(&base.lock);
    if (base.crypto_base == null) {
        const library = sys.OpenLibrary(sdk.crypto.CRYPTONAME, 1) orelse return tls.TLSERR_CRYPTO;
        base.crypto_base = @ptrCast(library);
    }
    if (base.dos_base == null) {
        base.dos_base = @ptrCast(sys.OpenLibrary(dos.DOSNAME, 0) orelse return tls.TLSERR_NOMEM);
    }
    if (base.utility_base == null) {
        base.utility_base = @ptrCast(sys.OpenLibrary(sdk.interface.utility.NAME, 0) orelse return tls.TLSERR_NOMEM);
    }
    if (!base.loaded) {
        loadRoots(base);
        loadOwnRoots(base);
        loadZone(base);
        base.loaded = true;
    }
    return tls.TLSERR_OK;
}

/// A whole file into memory; null for none, or one past `limit`.
fn readFile(base: *TLSBase, name: [*:0]const u8, limit: u32, length: *u32) ?[*]u8 {
    const sys = base.sys_base;
    const dl = base.dos_base.?;
    const file = dl.Open(name, dos.MODE_OLDFILE) orelse return null;
    defer _ = dl.Close(file);
    _ = dl.Seek(file, 0, dos.OFFSET_END);
    const size = dl.Seek(file, 0, dos.OFFSET_BEGINNING);
    if (size <= 0 or size > limit) return null;
    const memory = sys.AllocVec(@intCast(size), exec.MEMF_ANY) orelse return null;
    const bytes: [*]u8 = @ptrCast(memory);
    if (dl.Read(file, bytes, size) != size) {
        sys.FreeVec(memory);
        return null;
    }
    length.* = @intCast(size);
    return bytes;
}

fn loadRoots(base: *TLSBase) void {
    var length: u32 = 0;
    const bytes = readFile(base, roots_file, 1 << 20, &length) orelse return;
    base.roots = bytes;
    base.roots_length = length;
}

/// Every certificate of every PEM file in the program's own directory,
/// as anchors in a store of their own.
fn loadOwnRoots(base: *TLSBase) void {
    const sys = base.sys_base;
    const dl = base.dos_base.?;
    const lock = dl.Lock(own_directory, dos.ACCESS_READ) orelse return;
    defer dl.UnLock(lock);
    var fib: dos.FileInfoBlock = .{};
    if (!dl.Examine(lock, &fib) or fib.dir_entry_type <= 0) return;
    const memory = sys.AllocVec(own_max, exec.MEMF_ANY) orelse return;
    const store: [*]u8 = @ptrCast(memory);
    @memcpy(store[0..anchors.magic.len], anchors.magic);
    var at: usize = anchors.magic.len;
    // A certificate at a time, decoded off the stack.
    const scratch = sys.AllocVec(8192, exec.MEMF_ANY) orelse {
        sys.FreeVec(memory);
        return;
    };
    defer sys.FreeVec(scratch);
    const der: *[8192]u8 = @ptrCast(scratch);
    var path: [300]u8 = undefined;
    while (dl.ExNext(lock, &fib)) {
        if (fib.dir_entry_type > 0) continue;
        const name = nameOf(&fib.file_name);
        const prefix = own_directory ++ "/";
        if (prefix.len + name.len + 1 > path.len) continue;
        @memcpy(path[0..prefix.len], prefix);
        @memcpy(path[prefix.len..][0..name.len], name);
        path[prefix.len + name.len] = 0;
        var length: u32 = 0;
        const text = readFile(base, @ptrCast(&path), pem_max, &length) orelse continue;
        defer sys.FreeVec(text);
        var blocks = pem.Blocks.of(text[0..length]);
        while (blocks.next(der)) |encoded| {
            const cert = certificate.parse(encoded) orelse continue;
            const anchor = anchors.fromCertificate(&cert) orelse continue;
            const size = anchors.encodedLength(&anchor);
            if (at + size > own_max) break;
            at += anchors.encode(&anchor, store[at..own_max]);
        }
    }
    if (at == anchors.magic.len) {
        sys.FreeVec(memory);
        return;
    }
    base.own = store;
    base.own_length = @intCast(at);
}

fn nameOf(field: []const u8) []const u8 {
    var length: usize = 0;
    while (length < field.len and field[length] != 0) length += 1;
    return field[0..length];
}

/// The time zone rule's first line that is not a comment.
fn loadZone(base: *TLSBase) void {
    var length: u32 = 0;
    const text = readFile(base, timezone.zone_file, 4096, &length) orelse return;
    defer base.sys_base.FreeVec(text);
    var start: usize = 0;
    while (start < length) {
        var end = start;
        while (end < length and text[end] != '\n') end += 1;
        var line = text[start..end];
        while (line.len > 0 and (line[line.len - 1] == '\r' or line[line.len - 1] == ' ')) line = line[0 .. line.len - 1];
        if (line.len > 0 and line[0] != '#' and line.len <= base.zone.len) {
            @memcpy(base.zone[0..line.len], line);
            base.zone_length = @intCast(line.len);
            return;
        }
        start = end + 1;
    }
}

/// Now, in seconds since 1970, UTC: the clock keeps local time by the
/// zone's rule.
pub fn now(base: *TLSBase) i64 {
    var stamp: dos.DateStamp = .{};
    _ = base.dos_base.?.DateStamp(&stamp);
    const local: i64 = timezone.datestamp_epoch + @as(i64, stamp.days) * 86400 + @as(i64, stamp.minute) * 60 + @divTrunc(@as(i64, stamp.tick), 50);
    const zone = timezone.parse(base.zone[0..base.zone_length]) orelse return local;
    // The offset is the one at UTC; a first guess at it is close enough
    // to find it, but within the hour summer time changes.
    const guess = local - zone.offsetAt(local);
    return local - zone.offsetAt(guess);
}

/// The stores a session's chain may end in.
pub fn storesOf(base: *TLSBase, session: *Session) void {
    var count: usize = 0;
    if (base.roots) |bytes| {
        session.stores[count] = bytes[0..base.roots_length];
        count += 1;
    }
    if (base.own) |bytes| {
        session.stores[count] = bytes[0..base.own_length];
        count += 1;
    }
}

// --- the socket --------------------------------------------------------------

/// Exactly `buffer.len` bytes from the socket; false when it failed or
/// closed first.
fn receiveAll(session: *Session, buffer: []u8) bool {
    var at: usize = 0;
    while (at < buffer.len) {
        const got = session.sockets.Recv(session.socket, buffer[at..].ptr, @intCast(buffer.len - at), 0);
        if (got <= 0) return false;
        at += @intCast(got);
    }
    return true;
}

/// One whole record into `incoming`; its bytes, or null.
pub fn readRecord(session: *Session) ?[]u8 {
    if (!receiveAll(session, session.incoming[0..record.header_length])) return null;
    const head = record.header(session.incoming[0..record.header_length]) orelse return null;
    const total = record.header_length + @as(usize, head.length);
    if (!receiveAll(session, session.incoming[record.header_length..total])) return null;
    return session.incoming[0..total];
}

/// Everything in `output` to the socket; false when it failed.
pub fn flush(session: *Session, output: *Output) bool {
    var at: usize = 0;
    defer output.length = 0;
    while (at < output.length) {
        const sent = session.sockets.Send(session.socket, output.buffer[at..].ptr, @intCast(output.length - at), 0);
        if (sent <= 0) return false;
        at += @intCast(sent);
    }
    return true;
}

/// The error a failed client stands for.
pub fn errorOf(client: *const Client) i32 {
    return switch (client.failure) {
        .certificate => tls.TLSERR_CERTIFICATE,
        .alert => tls.TLSERR_ALERT,
        .closed => tls.TLSERR_IO,
        .none => tls.TLSERR_OK,
        else => tls.TLSERR_HANDSHAKE,
    };
}
