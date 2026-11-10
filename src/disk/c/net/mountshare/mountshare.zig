// SPDX-License-Identifier: MIT
//! MountShare: a share on an SMB server mounted as a device. Built
//! against the SDK only.
//!
//!   MountShare NAME/M,ALL/S,SHARE/K,USER/K,PASSWORD/K,DOMAIN/K,
//!              VOLUME/K,PORT/K/N,READONLY/S,ENCRYPT/S,SAVE/S,QUIET/S,
//!              DISMOUNT/S
//!
//! NAME is the device - `NAS` or `NAS:` - and SHARE where it is,
//! `//server/share`: a name or an address, IPv6 in brackets, a port after
//! a colon if not 445. USER and PASSWORD log on, in DOMAIN when the
//! server asks for one; with neither the logon is anonymous, and a server
//! may take any of them as a guest. VOLUME names the volume - the
//! share's name without it. READONLY writes nothing whatever the server
//! allows; ENCRYPT mounts only if every message can be encrypted.
//!
//! **A share file**, DEVS:Shares/<NAME>, says the same in keywords
//! (`sharefile.zig`), so that `MountShare NAS` is all a mount takes; what
//! the command line gives goes over what the file says. The password is
//! the first line of ENVARC:Sys/net/shares/<NAME> when PASSWORD is not
//! given - or its NT hash, as 32 hex digits. ALL mounts every share
//! there, as its file says. SAVE, once a mount worked, writes what it was
//! mounted with into the share file, and a PASSWORD's NT hash - never the
//! password - into the password file, making the directories they need.
//!
//! A share mounted already is left as it is, and said, unless QUIET; a
//! device of another kind by the name is an error.
//!
//! The device goes on the list with `HANDLERS:smb-handler` behind it, and
//! the handler is started at once: it connects, logs on and connects to
//! the share before MountShare goes on, and says how far it got. A share
//! that cannot be had is not left mounted, and MountShare says why - no
//! address for the name, no answer, a refused logon, no such share,
//! encryption that cannot be had, or an answer whose signature is wrong.
//! Mounted, it says the dialect, and whether the session is signed and
//! encrypted, unless QUIET.
//!
//! The password never reaches the handler: MountShare gives it the
//! password's NT hash - MD4 over its UTF-16, crypto.library's - which is
//! all the logon needs.
//!
//! DISMOUNT asks each NAME's handler to log off and end, and takes the
//! device off the list - not while anything on it is locked, open or
//! watched; with ALL, every share's.
//!
//! **LIST** says what shares a server has, mounting nothing: SERVER names
//! it - `//nas.lan`, a name or an address, a port after a colon - and
//! USER, PASSWORD and DOMAIN who asks, anonymously with none of them. It
//! is the server's own account of itself, which it may refuse to anyone
//! who has not logged on.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const smb = dos.smb;
const crypto = sdk.crypto;
const bsd = sdk.bsdsocket;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;
const client = @import("smbclient");
const placeOf = client.place.placeOf;
const sharefile = client.sharefile;
const browse = client.browse;
const share_area = client.shares;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const ShareFile = sharefile.ShareFile;

pub const COMMAND_NAME = "MountShare";
const VERSION_STRING = "\x00$VER: MountShare 1.3 (10.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "NAME/M,ALL/S,SHARE/K,USER/K,PASSWORD/K,DOMAIN/K,VOLUME/K,PORT/K/N,READONLY/S,ENCRYPT/S,SAVE/S,QUIET/S,DISMOUNT/S,LIST/S,SERVER/K";
const arg_name = 0;
const arg_all = 1;
const arg_share = 2;
const arg_user = 3;
const arg_password = 4;
const arg_domain = 5;
const arg_volume = 6;
const arg_port = 7;
const arg_readonly = 8;
const arg_encrypt = 9;
const arg_save = 10;
const arg_quiet = 11;
const arg_dismount = 12;
const arg_list = 13;
const arg_server = 14;
const arg_count = 15;

/// The handler process's stack: a command's, which grows with the
/// chip's pointers - the logon's work is deeper than a handler's default.
const handler_stack: u32 = dos.CLI_DEFAULT_STACK;
const handler_priority: i32 = 5;

/// crypto.library's first revision with MD4.
const CRYPTO_VERSION = 1;
const CRYPTO_REVISION = 4;

/// The longest device name, without its colon.
const device_max = 30;

/// The most shares ALL DISMOUNT takes off the list at once.
const shares_max = 32;

/// A share file's or a password file's path.
const Path = [64:0]u8;

const MSG_MOUNTED = "%s: %s: is //%s/%s, SMB %s%s";
const MSG_SIGNED = ", signed with %s";
const MSG_ENCRYPTED = ", encrypted with %s";
const MSG_GUEST = " as a guest";
const MSG_ANONYMOUS = " anonymously";
const MSG_NOSHARE = "%s: %s: needs SHARE, as //server/share, or a file in DEVS:Shares/\n";
const MSG_BADSHARE = "%s: '%s' is not //server/share\n";
const MSG_TOOLONG = "%s: %s is too long\n";
const MSG_ALREADY = "%s: %s: is mounted already\n";
const MSG_TAKEN = "%s: %s: is a device of another kind\n";
const MSG_UNKNOWN = "%s: unknown keyword '%s' in %s, line %u column %u\n";
const MSG_EQUAL = "%s: '=' expected after the keyword in %s, line %u column %u\n";
const MSG_TEXT = "%s: a value was expected in %s, line %u column %u\n";
const MSG_LONG = "%s: '%s' is too long, in %s, line %u column %u\n";
const MSG_PLACE = "%s: '%s' is not //server/share, in %s, line %u column %u\n";
const MSG_NUMBER = "%s: a port was expected, not '%s', in %s, line %u column %u\n";
const MSG_YESNO = "%s: YES or NO was expected, not '%s', in %s, line %u column %u\n";
const MSG_MISSING = "%s: %s says nothing about its %s\n";
const MSG_SAVED = "%s: %s: saved in %s\n";
const MSG_SAVED_HASH = "%s: %s: saved in %s, its password's hash in %s\n";
const MSG_NOSAVE = "%s: %s could not be written";
const MSG_UNSAVABLE = "%s: %s: '%s' cannot be saved: it has a quote in it\n";
const MSG_NOSERVER = "%s: LIST needs SERVER, as //server or an address\n";
const MSG_BADSERVER = "%s: '%s' is not a server's name\n";
const MSG_NOSOCKET = "%s: can't open %s\n";
const MSG_LISTED = "%s: SMB %s%s%s%s\n";
const MSG_SHARES = "Share                            Kind     Comment\n";
const MSG_SHARE = "%-32s %-8s %s\n";
const MSG_MORE = "%s: %u shares of %u - the rest did not fit\n";
const MSG_NOLIST = "%s: %s\n";
const MSG_NOMEM = "%s: out of memory\n";
const MSG_NOCRYPTO = "%s: crypto.library %u.%u is needed for a password\n";
const MSG_RESOLVE = "%s: %s has no address\n";
const MSG_REFUSED = "%s: %s refused the connection on port %u\n";
const MSG_NOANSWER = "%s: %s does not answer on port %u\n";
const MSG_NEGOTIATE = "%s: %s does not speak SMB 2 or 3 (status 0x%x)\n";
const MSG_LOGON = "%s: %s refused the logon: %s\n";
const MSG_LOGON_STATUS = "%s: %s refused the logon (status 0x%x)\n";
const MSG_NOTREE = "%s: %s has no share %s\n";
const MSG_TREEDENIED = "%s: %s does not let this user at %s\n";
const MSG_TREE = "%s: %s refused the share %s (status 0x%x)\n";
const MSG_ENCRYPT_ASKED = "%s: %s cannot encrypt this session: that takes AES-GCM on SMB 3.1.1 and a logon with a password\n";
const MSG_ENCRYPT_REQUIRED = "%s: %s requires encryption this session cannot give: that takes AES-GCM on SMB 3.1.1 and a logon with a password\n";
const MSG_FORGED = "%s: an answer from %s failed its signature check\n";
const MSG_NETWORK = "%s: smb-handler needs bsdsocket.library and crypto.library %u.%u\n";
const MSG_HANDLERMEM = "%s: smb-handler is out of memory\n";
const MSG_NOSTART = "%s: %s:'s handler did not start\n";
const MSG_NOTMOUNTED = "%s: %s: is not a mounted share\n";
const MSG_INUSE = "%s: %s: is in use\n";
const MSG_DISMOUNTED = "%s: %s: dismounted\n";

fn span(text: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (text[len] != 0) len += 1;
    return text[0..len];
}

/// `text` into `into` with its NUL: false when it does not fit.
fn copyInto(into: []u8, text: []const u8) bool {
    if (text.len >= into.len) return false;
    @memcpy(into[0..text.len], text);
    into[text.len] = 0;
    return true;
}

fn upper(char: u8) u8 {
    return if (char >= 'a' and char <= 'z') char - 0x20 else char;
}

/// A device's name as the list keeps it: in capitals, without its colon.
fn deviceName(name: [*:0]const u8, into: *[device_max + 1]u8) ?[*:0]const u8 {
    var text = span(name);
    if (text.len > 0 and text[text.len - 1] == ':') text = text[0 .. text.len - 1];
    if (text.len == 0 or text.len > device_max) return null;
    for (text, 0..) |char, at| into[at] = upper(char);
    into[text.len] = 0;
    return @ptrCast(into);
}

/// The names of the dialects, ciphers and signing algorithms, as they
/// are said.
fn dialectName(dialect: u16) [*:0]const u8 {
    return switch (dialect) {
        smb.SMB2_DIALECT_0202 => "2.0.2",
        smb.SMB2_DIALECT_0210 => "2.1",
        smb.SMB2_DIALECT_0300 => "3.0",
        smb.SMB2_DIALECT_0302 => "3.0.2",
        smb.SMB2_DIALECT_0311 => "3.1.1",
        else => "?",
    };
}

fn signingName(algorithm: u16) [*:0]const u8 {
    return switch (algorithm) {
        smb.SMB2_SIGNING_HMAC_SHA256 => "HMAC-SHA256",
        smb.SMB2_SIGNING_AES_CMAC => "AES-CMAC",
        smb.SMB2_SIGNING_AES_GMAC => "AES-GMAC",
        else => "?",
    };
}

fn cipherName(cipher: u16) [*:0]const u8 {
    return switch (cipher) {
        smb.SMB2_CIPHER_AES_128_GCM => "AES-128-GCM",
        smb.SMB2_CIPHER_AES_256_GCM => "AES-256-GCM",
        smb.SMB2_CIPHER_AES_128_CCM => "AES-128-CCM",
        smb.SMB2_CIPHER_AES_256_CCM => "AES-256-CCM",
        else => "?",
    };
}

/// What a logon's refusal means, when it says.
fn logonReason(status: u32) ?[*:0]const u8 {
    return switch (status) {
        smb.STATUS_LOGON_FAILURE, smb.STATUS_WRONG_PASSWORD, smb.STATUS_NO_SUCH_USER => "wrong user or password",
        smb.STATUS_ACCOUNT_DISABLED => "the account is disabled",
        smb.STATUS_ACCOUNT_LOCKED_OUT => "the account is locked out",
        smb.STATUS_PASSWORD_EXPIRED => "the password has expired",
        smb.STATUS_ACCOUNT_RESTRICTION, smb.STATUS_INVALID_LOGON_HOURS => "the account may not log on now",
        smb.STATUS_ACCESS_DENIED => "access denied",
        else => null,
    };
}

/// Why a start failed, in words, from what the handler wrote.
fn sayFailure(dl: *DosBase, startup: *const smb.SmbStartup, server: [*:0]const u8, share: [*:0]const u8, port: u16, device: [*:0]const u8, encrypt: bool) void {
    const result = startup.result;
    switch (result.stage) {
        smb.SMBSTAGE_RESOLVE => _ = Printf(dl, MSG_RESOLVE, .{ COMMAND_NAME, server }),
        smb.SMBSTAGE_CONNECT => if (result.@"error" == bsd.ECONNREFUSED) {
            _ = Printf(dl, MSG_REFUSED, .{ COMMAND_NAME, server, @as(u32, port) });
        } else {
            _ = Printf(dl, MSG_NOANSWER, .{ COMMAND_NAME, server, @as(u32, port) });
        },
        smb.SMBSTAGE_NEGOTIATE => _ = Printf(dl, MSG_NEGOTIATE, .{ COMMAND_NAME, server, result.status }),
        smb.SMBSTAGE_LOGON => if (logonReason(result.status)) |reason| {
            _ = Printf(dl, MSG_LOGON, .{ COMMAND_NAME, server, reason });
        } else {
            _ = Printf(dl, MSG_LOGON_STATUS, .{ COMMAND_NAME, server, result.status });
        },
        smb.SMBSTAGE_TREE => switch (result.status) {
            smb.STATUS_BAD_NETWORK_NAME => _ = Printf(dl, MSG_NOTREE, .{ COMMAND_NAME, server, share }),
            smb.STATUS_ACCESS_DENIED, smb.STATUS_NETWORK_ACCESS_DENIED => _ = Printf(dl, MSG_TREEDENIED, .{ COMMAND_NAME, server, share }),
            else => _ = Printf(dl, MSG_TREE, .{ COMMAND_NAME, server, share, result.status }),
        },
        smb.SMBSTAGE_SECURITY => if (result.@"error" == smb.SMBSECURITY_SIGNATURE) {
            _ = Printf(dl, MSG_FORGED, .{ COMMAND_NAME, server });
        } else if (encrypt) {
            _ = Printf(dl, MSG_ENCRYPT_ASKED, .{ COMMAND_NAME, server });
        } else {
            _ = Printf(dl, MSG_ENCRYPT_REQUIRED, .{ COMMAND_NAME, server });
        },
        smb.SMBSTAGE_NETWORK => _ = Printf(dl, MSG_NETWORK, .{ COMMAND_NAME, @as(u32, CRYPTO_VERSION), @as(u32, CRYPTO_REVISION) }),
        smb.SMBSTAGE_MEMORY => _ = Printf(dl, MSG_HANDLERMEM, .{COMMAND_NAME}),
        else => _ = Printf(dl, MSG_NOSTART, .{ COMMAND_NAME, device }),
    }
}

/// What the command line gives.
const Given = struct {
    share: ?[*:0]const u8 = null,
    user: ?[*:0]const u8 = null,
    password: ?[*:0]const u8 = null,
    domain: ?[*:0]const u8 = null,
    volume: ?[*:0]const u8 = null,
    port: ?i32 = null,
    readonly: bool = false,
    encrypt: bool = false,
    save: bool = false,
    quiet: bool = false,
};

/// What a mount asks for: the share file's keywords, the command line's
/// over them. An empty text is none.
const Wanted = struct {
    share: ?[]const u8 = null,
    user: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    volume: ?[]const u8 = null,
    port: ?u16 = null,
    readonly: bool = false,
    encrypt: bool = false,
    /// The password, or its NT hash from the password file.
    password: ?[]const u8 = null,
    nt_hash: ?[16]u8 = null,
};

fn given(text: ?[*:0]const u8) ?[]const u8 {
    const value = span(text orelse return null);
    return if (value.len == 0) null else value;
}

fn filed(text: [*:0]const u8) ?[]const u8 {
    const value = span(text);
    return if (value.len == 0) null else value;
}

/// How a device by a name stands on the list.
const Standing = enum { none, share, other };

fn standingOf(dl: *DosBase, device: [*:0]const u8) Standing {
    const flags = dos.LDF_DEVICES | dos.LDF_READ;
    const list = dl.LockDosList(flags) orelse return .none;
    defer dl.UnLockDosList(flags);
    const node = dl.FindDosEntry(list, device, dos.LDF_DEVICES) orelse return .none;
    return if (smb.SmbStartup.of(node.misc.handler.startup) != null) .share else .other;
}

/// `first` and `second` joined into `into`.
fn join(into: *Path, first: []const u8, second: [*:0]const u8) [*:0]const u8 {
    var at: usize = 0;
    for (first) |char| {
        into[at] = char;
        at += 1;
    }
    var index: usize = 0;
    while (second[index] != 0 and at < into.len) : (index += 1) {
        into[at] = second[index];
        at += 1;
    }
    into[at] = 0;
    return @ptrCast(into);
}

/// The share file read into `file`: whether there was one, or null when
/// it is wrong - which is said.
fn readShareFile(dl: *DosBase, path: [*:0]const u8, file: *ShareFile) ?bool {
    const handle = dl.Open(path, dos.MODE_OLDFILE) orelse return false;
    var scanner = dos.keywords.Scanner.ofFile(dl, handle);
    const found = sharefile.read(&scanner, file);
    _ = dl.Close(handle);
    if (found.kind == .none) return true;
    const token: [*:0]const u8 = @ptrCast(&found.token);
    _ = switch (found.kind) {
        .none => 0,
        .unknown => Printf(dl, MSG_UNKNOWN, .{ COMMAND_NAME, token, path, found.line, found.column }),
        .equal => Printf(dl, MSG_EQUAL, .{ COMMAND_NAME, path, found.line, found.column }),
        .text => Printf(dl, MSG_TEXT, .{ COMMAND_NAME, path, found.line, found.column }),
        .long => Printf(dl, MSG_LONG, .{ COMMAND_NAME, token, path, found.line, found.column }),
        .place => Printf(dl, MSG_PLACE, .{ COMMAND_NAME, token, path, found.line, found.column }),
        .number => Printf(dl, MSG_NUMBER, .{ COMMAND_NAME, token, path, found.line, found.column }),
        .yes_no => Printf(dl, MSG_YESNO, .{ COMMAND_NAME, token, path, found.line, found.column }),
        .missing => Printf(dl, MSG_MISSING, .{ COMMAND_NAME, path, token }),
    };
    return null;
}

/// The password file's first line, in `into`: null when there is none.
fn readPassword(dl: *DosBase, path: [*:0]const u8, into: *[sharefile.password_max + 1]u8) ?[]const u8 {
    const handle = dl.Open(path, dos.MODE_OLDFILE) orelse return null;
    const got = dl.Read(handle, into, into.len);
    _ = dl.Close(handle);
    if (got <= 0) return null;
    return sharefile.firstLine(into[0..@intCast(got)]);
}

/// One share mounted as `name`: its file read, the command line put over
/// it, the node made, the handler started, and what it came to said.
fn mountOne(sys: *ExecBase, dl: *DosBase, name: [*:0]const u8, options: *const Given) i32 {
    var device_buffer: [device_max + 1]u8 = undefined;
    const device = deviceName(name, &device_buffer) orelse {
        _ = Printf(dl, MSG_TOOLONG, .{ COMMAND_NAME, name });
        return dos.RETURN_ERROR;
    };
    switch (standingOf(dl, device)) {
        .none => {},
        .share => {
            if (!options.quiet) _ = Printf(dl, MSG_ALREADY, .{ COMMAND_NAME, device });
            return dos.RETURN_OK;
        },
        .other => {
            _ = Printf(dl, MSG_TAKEN, .{ COMMAND_NAME, device });
            return dos.RETURN_ERROR;
        },
    }

    var file: ShareFile = .{};
    var file_path: Path = @splat(0);
    const share_path = join(&file_path, sharefile.directory, device);
    const had_file = readShareFile(dl, share_path, &file) orelse return dos.RETURN_ERROR;
    var wanted: Wanted = .{
        .share = given(options.share),
        .user = given(options.user),
        .domain = given(options.domain),
        .volume = given(options.volume),
        .readonly = options.readonly,
        .encrypt = options.encrypt,
    };
    if (options.port) |port| {
        if (port > 0 and port <= 0xFFFF) wanted.port = @intCast(port);
    }
    if (had_file) {
        if (wanted.share == null) wanted.share = filed(&file.share);
        if (wanted.user == null) wanted.user = filed(&file.user);
        if (wanted.domain == null) wanted.domain = filed(&file.domain);
        if (wanted.volume == null) wanted.volume = filed(&file.volume);
        if (wanted.port == null and file.port != 0) wanted.port = file.port;
        wanted.readonly = wanted.readonly or file.readonly;
        wanted.encrypt = wanted.encrypt or file.encrypt;
    }

    // The password: the command line's, or the password file's.
    var password_path: Path = @splat(0);
    const hash_path = join(&password_path, sharefile.password_directory, device);
    var password_buffer: [sharefile.password_max + 1]u8 = @splat(0);
    defer @memset(&password_buffer, 0);
    if (given(options.password)) |password| {
        wanted.password = password;
    } else if (readPassword(dl, hash_path, &password_buffer)) |line| {
        if (sharefile.hashOf(line)) |hash| wanted.nt_hash = hash else wanted.password = line;
    }

    const share_text = wanted.share orelse {
        _ = Printf(dl, MSG_NOSHARE, .{ COMMAND_NAME, device });
        return dos.RETURN_ERROR;
    };
    var share_buffer: [dos.keywords.max_token + 1:0]u8 = @splat(0);
    if (!copyInto(&share_buffer, share_text)) {
        _ = Printf(dl, MSG_TOOLONG, .{ COMMAND_NAME, @as([*:0]const u8, "SHARE") });
        return dos.RETURN_ERROR;
    }
    const share_name: [*:0]const u8 = @ptrCast(&share_buffer);
    const place = placeOf(share_text) orelse {
        _ = Printf(dl, MSG_BADSHARE, .{ COMMAND_NAME, share_name });
        return dos.RETURN_ERROR;
    };
    if (options.save) {
        // Checked before anything is mounted: a share mounted but not
        // saved is not what was asked for.
        const values = [_]?[]const u8{ wanted.share, wanted.user, wanted.domain, wanted.volume };
        for (values) |value| {
            const text = value orelse continue;
            if (sharefile.savable(text)) continue;
            var shown: [dos.keywords.max_token + 1:0]u8 = @splat(0);
            _ = copyInto(&shown, text[0..@min(text.len, dos.keywords.max_token)]);
            _ = Printf(dl, MSG_UNSAVABLE, .{ COMMAND_NAME, device, @as([*:0]const u8, @ptrCast(&shown)) });
            return dos.RETURN_ERROR;
        }
    }

    const block = sys.AllocVec(@sizeOf(smb.SmbStartup), exec.MEMF_CLEAR) orelse {
        _ = Printf(dl, MSG_NOMEM, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    const startup: *smb.SmbStartup = @ptrCast(@alignCast(block));
    startup.* = .{};
    startup.fssm.environ = &startup.env;
    const fits = copyInto(&startup.server, place.server) and copyInto(&startup.share, place.share) and
        copyInto(&startup.user, wanted.user orelse "") and
        copyInto(&startup.domain, wanted.domain orelse "") and
        copyInto(&startup.volume, wanted.volume orelse "");
    if (!fits) {
        sys.FreeVec(block);
        _ = Printf(dl, MSG_TOOLONG, .{ COMMAND_NAME, share_name });
        return dos.RETURN_ERROR;
    }
    startup.port = place.port;
    if (wanted.port) |port| startup.port = port;
    if (wanted.readonly) startup.flags |= smb.SMBF_READONLY;
    if (wanted.encrypt) startup.flags |= smb.SMBF_ENCRYPT;
    if (wanted.nt_hash) |hash| {
        startup.nt_hash = hash;
        startup.flags |= smb.SMBF_HASH;
    } else if (wanted.password) |password| {
        const crypto_lib = sys.OpenLibrary(crypto.CRYPTONAME, CRYPTO_VERSION);
        const usable = if (crypto_lib) |lib| lib.version > CRYPTO_VERSION or lib.revision >= CRYPTO_REVISION else false;
        if (!usable) {
            if (crypto_lib) |lib| sys.CloseLibrary(lib);
            sys.FreeVec(block);
            _ = Printf(dl, MSG_NOCRYPTO, .{ COMMAND_NAME, @as(u32, CRYPTO_VERSION), @as(u32, CRYPTO_REVISION) });
            return dos.RETURN_FAIL;
        }
        startup.nt_hash = client.ntlm.ntHash(@ptrCast(crypto_lib.?), password);
        startup.flags |= smb.SMBF_HASH;
        sys.CloseLibrary(crypto_lib.?);
    }

    const node = dl.MakeDosEntry(device, dos.DLT_DEVICE) orelse {
        sys.FreeVec(block);
        _ = Printf(dl, MSG_NOMEM, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    node.misc.handler.handler = smb.SMB_HANDLER;
    node.misc.handler.stack_size = handler_stack;
    node.misc.handler.priority = handler_priority;
    node.misc.handler.startup = @intFromPtr(startup);
    if (!dl.AddDosEntry(node)) {
        dl.FreeDosEntry(node);
        sys.FreeVec(block);
        _ = Printf(dl, MSG_TAKEN, .{ COMMAND_NAME, device });
        return dos.RETURN_ERROR;
    }

    var with_colon: [device_max + 2:0]u8 = @splat(0);
    const device_text = span(device);
    @memcpy(with_colon[0..device_text.len], device_text);
    with_colon[device_text.len] = ':';
    const port: u16 = if (startup.port == 0) smb.SMB_PORT else startup.port;
    if (dl.GetDeviceProc(&with_colon, null)) |dp| {
        dl.FreeDeviceProc(dp);
    } else {
        // A share that cannot be had is not left mounted.
        const reason = dl.IoErr();
        sayFailure(dl, startup, @ptrCast(&startup.server), @ptrCast(&startup.share), port, device, wanted.encrypt);
        _ = removeNode(sys, dl, device);
        _ = dl.SetIoErr(reason);
        return dos.RETURN_FAIL;
    }
    if (!options.quiet) {
        const result = startup.result;
        // A server may say nothing of an anonymous session but leave it
        // unsigned: no user and no password is one.
        const anonymous = result.session_flags & smb.SMB2_SESSION_FLAG_IS_NULL != 0 or
            (wanted.user == null and startup.flags & smb.SMBF_HASH == 0);
        const how: [*:0]const u8 = if (result.session_flags & smb.SMB2_SESSION_FLAG_IS_GUEST != 0) MSG_GUEST else if (anonymous) MSG_ANONYMOUS else "";
        _ = Printf(dl, MSG_MOUNTED, .{
            COMMAND_NAME,
            device,
            @as([*:0]const u8, @ptrCast(&startup.server)),
            @as([*:0]const u8, @ptrCast(&startup.share)),
            dialectName(result.dialect),
            how,
        });
        if (result.signing != smb.SMB2_SIGNING_NONE) _ = Printf(dl, MSG_SIGNED, .{signingName(result.signing)});
        if (result.cipher != smb.SMB2_CIPHER_NONE) _ = Printf(dl, MSG_ENCRYPTED, .{cipherName(result.cipher)});
        _ = Printf(dl, "\n", .{});
    }
    if (!options.save) return dos.RETURN_OK;
    // Only a password given now is saved: one from the password file is
    // there already.
    const hash: ?[16]u8 = if (given(options.password) != null) startup.nt_hash else null;
    return save(dl, device, &wanted, share_path, if (hash) |*digest| .{ .path = hash_path, .hash = digest } else null, options.quiet);
}

// --- saving -------------------------------------------------------------------

/// A file that could not be written, said with the reason dos gives.
fn sayNotSaved(dl: *DosBase, path: [*:0]const u8) i32 {
    const reason = dl.IoErr();
    _ = Printf(dl, MSG_NOSAVE, .{ COMMAND_NAME, path });
    _ = dl.PrintFault(reason, null);
    return dos.RETURN_WARN;
}

/// Where a password's hash goes, and the hash.
const HashFile = struct {
    path: [*:0]const u8,
    hash: *const [16]u8,
};

/// SAVE: what the share was mounted with written into its share file,
/// and a password's NT hash into its password file.
fn save(dl: *DosBase, device: [*:0]const u8, wanted: *const Wanted, share_path: [*:0]const u8, hash_file: ?HashFile, quiet: bool) i32 {
    const written = sharefile.writeTo(dl, share_path, span(device), &.{
        .share = wanted.share,
        .user = wanted.user,
        .domain = wanted.domain,
        .volume = wanted.volume,
        .port = wanted.port,
        .readonly = wanted.readonly,
        .encrypt = wanted.encrypt,
    });
    if (!written) return sayNotSaved(dl, share_path);

    const saved = hash_file orelse {
        if (!quiet) _ = Printf(dl, MSG_SAVED, .{ COMMAND_NAME, device, share_path });
        return dos.RETURN_OK;
    };
    if (!sharefile.writePassword(dl, saved.path, saved.hash)) return sayNotSaved(dl, saved.path);
    if (!quiet) _ = Printf(dl, MSG_SAVED_HASH, .{ COMMAND_NAME, device, share_path, saved.path });
    return dos.RETURN_OK;
}

/// ALL: every share in DEVS:Shares/, as its file says.
fn mountAll(sys: *ExecBase, dl: *DosBase, quiet: bool) i32 {
    const lock = dl.Lock(sharefile.directory, dos.ACCESS_READ) orelse return dos.RETURN_OK;
    defer dl.UnLock(lock);
    const fib: *dos.FileInfoBlock = @ptrCast(@alignCast(dl.AllocDosObject(dos.DOS_FIB, null) orelse return dos.RETURN_FAIL));
    defer dl.FreeDosObject(dos.DOS_FIB, fib);
    if (!dl.Examine(lock, fib)) return dos.RETURN_OK;
    const options: Given = .{ .quiet = quiet };
    var worst: i32 = dos.RETURN_OK;
    while (dl.ExNext(lock, fib)) {
        if (dos.isDirectory(fib.dir_entry_type)) continue;
        worst = @max(worst, mountOne(sys, dl, @ptrCast(&fib.file_name), &options));
    }
    return worst;
}

/// ALL DISMOUNT: every share on the device list dismounted.
fn dismountAll(sys: *ExecBase, dl: *DosBase, quiet: bool) i32 {
    var devices: [shares_max][device_max + 1]u8 = undefined;
    var count: usize = 0;
    const flags = dos.LDF_DEVICES | dos.LDF_READ;
    if (dl.LockDosList(flags)) |list| {
        var node = list;
        while (count < shares_max) {
            node = dl.NextDosEntry(node, dos.LDF_DEVICES) orelse break;
            if (smb.SmbStartup.of(node.misc.handler.startup) == null) continue;
            const name = span(node.name);
            if (name.len > device_max) continue;
            @memcpy(devices[count][0..name.len], name);
            devices[count][name.len] = 0;
            count += 1;
        }
        dl.UnLockDosList(flags);
    }
    var worst: i32 = dos.RETURN_OK;
    for (devices[0..count]) |*device| worst = @max(worst, dismountOne(sys, dl, @ptrCast(device), quiet));
    return worst;
}

/// A share's device off the list, once its handler has ended, and its
/// startup freed: false when it is not a share's or did not come off.
fn removeNode(sys: *ExecBase, dl: *DosBase, device: [*:0]const u8) bool {
    const flags = dos.LDF_DEVICES | dos.LDF_WRITE;
    var waited: u32 = 0;
    while (true) : (waited += 1) {
        const list = dl.LockDosList(flags) orelse return false;
        const node = dl.FindDosEntry(list, device, dos.LDF_DEVICES) orelse {
            dl.UnLockDosList(flags);
            return false;
        };
        const startup = smb.SmbStartup.of(node.misc.handler.startup) orelse {
            dl.UnLockDosList(flags);
            return false;
        };
        // Two words, each read whole, under the list's lock: the handler
        // lets go of its port under it, and its users are counted down
        // before.
        const running = node.task != null or node.misc.handler.users != 0;
        if (!running) {
            const removed = dl.RemDosEntry(node);
            dl.UnLockDosList(flags);
            if (!removed) return false;
            dl.FreeDosEntry(node);
            sys.FreeVec(startup);
            return true;
        }
        dl.UnLockDosList(flags);
        if (waited == 50) return false;
        dl.Delay(1);
    }
}

/// DISMOUNT: the handler asked to end, and the device taken off the
/// list.
fn dismountOne(sys: *ExecBase, dl: *DosBase, name: [*:0]const u8, quiet: bool) i32 {
    var device_buffer: [device_max + 1]u8 = undefined;
    const device = deviceName(name, &device_buffer) orelse {
        _ = Printf(dl, MSG_NOTMOUNTED, .{ COMMAND_NAME, name });
        return dos.RETURN_ERROR;
    };
    const flags = dos.LDF_DEVICES | dos.LDF_READ;
    const list = dl.LockDosList(flags) orelse return dos.RETURN_FAIL;
    const node = dl.FindDosEntry(list, device, dos.LDF_DEVICES);
    const share = if (node) |found| smb.SmbStartup.of(found.misc.handler.startup) != null else false;
    const port = if (node) |found| found.task else null;
    dl.UnLockDosList(flags);
    if (!share) {
        _ = Printf(dl, MSG_NOTMOUNTED, .{ COMMAND_NAME, device });
        return dos.RETURN_ERROR;
    }
    if (port) |handler| {
        if (dl.DoPkt(handler, @intFromEnum(dos.ActionCode.die), 0, 0, 0, 0, 0) == dos.DOSFALSE) {
            _ = Printf(dl, MSG_INUSE, .{ COMMAND_NAME, device });
            return dos.RETURN_WARN;
        }
    }
    if (!removeNode(sys, dl, device)) {
        _ = Printf(dl, MSG_INUSE, .{ COMMAND_NAME, device });
        return dos.RETURN_WARN;
    }
    if (!quiet) _ = Printf(dl, MSG_DISMOUNTED, .{ COMMAND_NAME, device });
    return dos.RETURN_OK;
}

/// The buffers one look at a server takes: a session's two, and the one a
/// listing is gathered in. A question and its answer are small beside
/// what a mounted share reads and writes.
const list_send: usize = 8 * 1024;
const list_gather: usize = 32 * 1024;
const list_receive: usize = list_gather + 8 * 1024;
/// The most shares LIST says.
const list_max: usize = 64;

/// What `onOwnStack` is handed: everything the look needs, and what it
/// came to.
const ListWork = struct {
    sys: *ExecBase,
    dl: *DosBase,
    typed: []const u8,
    options: *const Given,
};

fn onOwnStack(arg: ?*anyopaque) callconv(.c) i32 {
    const work: *ListWork = @ptrCast(@alignCast(arg.?));
    return listShares(work.sys, work.dl, work.typed, work.options);
}

/// LIST on a stack of its own: a command is run on the shell's stack,
/// which a logon and a share list together go deeper than.
fn listOnOwnStack(sys: *ExecBase, dl: *DosBase, typed: []const u8, options: *const Given) i32 {
    var work: ListWork = .{ .sys = sys, .dl = dl, .typed = typed, .options = options };
    const rc = sys.NewStackRun(&onOwnStack, &work, client.stack_bytes);
    if (rc < 0) {
        _ = Printf(dl, MSG_NOMEM, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    }
    return rc;
}

/// Where a server is, from what LIST was given: `//nas`, `\\nas`,
/// `smb://nas`, a bare name or an address, a port after a colon, an IPv6
/// address in brackets. A share written after the server is ignored: the
/// shares are what is being asked for.
fn serverOf(typed: []const u8, into: *[smb.SMB_SERVER_MAX + 1:0]u8, port: *u16) bool {
    var rest = client.place.withoutScheme(typed);
    while (rest.len > 0 and (rest[0] == '/' or rest[0] == '\\')) rest = rest[1..];
    var cut: usize = 0;
    while (cut < rest.len and rest[cut] != '/' and rest[cut] != '\\') cut += 1;
    const host = rest[0..cut];
    if (host.len == 0 or host.len > smb.SMB_SERVER_MAX) return false;
    // `placeOf` knows the brackets and the port; it wants a share after
    // the server, so one is lent to it.
    var with_share: [smb.SMB_SERVER_MAX + 8]u8 = undefined;
    @memcpy(with_share[0..2], "//");
    @memcpy(with_share[2..][0..host.len], host);
    @memcpy(with_share[2 + host.len ..][0..2], "/x");
    const place = placeOf(with_share[0 .. 4 + host.len]) orelse return false;
    if (!copyInto(into, place.server)) return false;
    port.* = place.port;
    return true;
}

/// Why a look at a server came to nothing, in words.
fn sayLookFailure(dl: *DosBase, result: *const smb.SmbResult, server: [*:0]const u8, port: u16) void {
    switch (result.stage) {
        smb.SMBSTAGE_RESOLVE => _ = Printf(dl, MSG_RESOLVE, .{ COMMAND_NAME, server }),
        smb.SMBSTAGE_CONNECT => if (result.@"error" == bsd.ECONNREFUSED) {
            _ = Printf(dl, MSG_REFUSED, .{ COMMAND_NAME, server, @as(u32, port) });
        } else {
            _ = Printf(dl, MSG_NOANSWER, .{ COMMAND_NAME, server, @as(u32, port) });
        },
        smb.SMBSTAGE_NEGOTIATE => _ = Printf(dl, MSG_NEGOTIATE, .{ COMMAND_NAME, server, result.status }),
        smb.SMBSTAGE_LOGON => if (logonReason(result.status)) |reason| {
            _ = Printf(dl, MSG_LOGON, .{ COMMAND_NAME, server, reason });
        } else {
            _ = Printf(dl, MSG_LOGON_STATUS, .{ COMMAND_NAME, server, result.status });
        },
        smb.SMBSTAGE_TREE => _ = Printf(dl, MSG_NOTREE, .{ COMMAND_NAME, server, "IPC$" }),
        smb.SMBSTAGE_SECURITY => if (result.@"error" == smb.SMBSECURITY_SIGNATURE) {
            _ = Printf(dl, MSG_FORGED, .{ COMMAND_NAME, server });
        } else {
            _ = Printf(dl, MSG_ENCRYPT_REQUIRED, .{ COMMAND_NAME, server });
        },
        smb.SMBSTAGE_MEMORY => _ = Printf(dl, MSG_NOMEM, .{COMMAND_NAME}),
        else => _ = Printf(dl, MSG_NOLIST, .{ COMMAND_NAME, "nothing came of it" }),
    }
}

/// LIST: every share a server has, printed, nothing mounted.
fn listShares(sys: *ExecBase, dl: *DosBase, typed: []const u8, options: *const Given) i32 {
    var server: [smb.SMB_SERVER_MAX + 1:0]u8 = @splat(0);
    var port: u16 = 0;
    if (!serverOf(typed, &server, &port)) {
        var shown: [smb.SMB_SERVER_MAX + 1]u8 = undefined;
        _ = copyInto(&shown, typed[0..@min(typed.len, smb.SMB_SERVER_MAX)]);
        _ = Printf(dl, MSG_BADSERVER, .{ COMMAND_NAME, @as([*:0]const u8, @ptrCast(&shown)) });
        return dos.RETURN_ERROR;
    }
    const name: [*:0]const u8 = @ptrCast(&server);

    const socket_lib = sys.OpenLibrary(bsd.SOCKETNAME, 0) orelse {
        _ = Printf(dl, MSG_NOSOCKET, .{ COMMAND_NAME, bsd.SOCKETNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(socket_lib);
    const crypto_lib = sys.OpenLibrary(crypto.CRYPTONAME, CRYPTO_VERSION) orelse {
        _ = Printf(dl, MSG_NOSOCKET, .{ COMMAND_NAME, crypto.CRYPTONAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(crypto_lib);
    if (crypto_lib.version == CRYPTO_VERSION and crypto_lib.revision < CRYPTO_REVISION) {
        _ = Printf(dl, MSG_NOCRYPTO, .{ COMMAND_NAME, @as(u32, CRYPTO_VERSION), @as(u32, CRYPTO_REVISION) });
        return dos.RETURN_FAIL;
    }
    const cb: *CryptoBase = @ptrCast(crypto_lib);

    const memory = sys.AllocVec(list_send + list_receive + list_gather, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        _ = Printf(dl, MSG_NOMEM, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const bytes: [*]u8 = @ptrCast(memory);
    var session = browse.sessionOn(@ptrCast(socket_lib), cb, .{
        .send = bytes[0..list_send],
        .receive = bytes[list_send..][0..list_receive],
    });
    const gather = bytes[list_send + list_receive ..][0..list_gather];

    var account: browse.Account = .{
        .user = given(options.user) orelse &.{},
        .domain = given(options.domain) orelse &.{},
    };
    var hash: [16]u8 = undefined;
    if (given(options.password)) |password| {
        hash = client.ntlm.ntHash(cb, password);
        account.nt_hash = hash;
    }
    var result: smb.SmbResult = .{};
    if (!browse.open(&session, name, port, &account, &result)) {
        sayLookFailure(dl, &result, name, if (port == 0) smb.SMB_PORT else port);
        return dos.RETURN_ERROR;
    }
    defer browse.close(&session);

    var shares: [list_max]share_area.Share = @splat(.{});
    const listing = browse.list(&session, span(name), &shares, gather) catch {
        _ = Printf(dl, MSG_NOLIST, .{ COMMAND_NAME, "the connection broke while asking" });
        return dos.RETURN_ERROR;
    };
    if (!listing.ok()) {
        _ = Printf(dl, MSG_NOLIST, .{ COMMAND_NAME, if (listing.refused) "the server has no share list to ask" else "the server would not say what shares it has" });
        return dos.RETURN_ERROR;
    }
    if (!options.quiet) {
        _ = Printf(dl, MSG_LISTED, .{
            COMMAND_NAME,
            dialectName(result.dialect),
            if (result.signing != smb.SMB2_SIGNING_NONE) ", signed" else "",
            if (result.cipher != smb.SMB2_CIPHER_NONE) ", encrypted" else "",
            if (result.session_flags & smb.SMB2_SESSION_FLAG_IS_GUEST != 0) " as a guest" else "",
        });
        _ = Printf(dl, MSG_SHARES, .{});
    }
    for (shares[0..listing.count]) |*share| {
        var shown: [client.names.name_max:0]u8 = @splat(0);
        const share_name = client.names.toDos(share.name, @ptrCast(&shown));
        shown[share_name.len] = 0;
        var comment: [80:0]u8 = @splat(0);
        const units = @min(share.comment.len / 2, comment.len - 1);
        for (0..units) |index| {
            const unit = client.names.unitAt(share.comment, index);
            comment[index] = if (unit >= 0x20 and unit <= 0xFF) @intCast(unit) else '?';
        }
        _ = Printf(dl, MSG_SHARE, .{
            @as([*:0]const u8, @ptrCast(&shown)),
            kindName(share),
            @as([*:0]const u8, @ptrCast(&comment)),
        });
    }
    if (listing.total > listing.count) {
        _ = Printf(dl, MSG_MORE, .{ COMMAND_NAME, @as(u32, @intCast(listing.count)), listing.total });
        return dos.RETURN_WARN;
    }
    return dos.RETURN_OK;
}

/// What a share's kind is called.
fn kindName(share: *const share_area.Share) [*:0]const u8 {
    return switch (share.kind()) {
        share_area.STYPE_DISKTREE => if (share.isSpecial()) "Disk*" else "Disk",
        share_area.STYPE_PRINTQ => "Printer",
        share_area.STYPE_DEVICE => "Device",
        share_area.STYPE_IPC => "Pipe",
        else => "?",
    };
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [arg_count]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const quiet = argv[arg_quiet] != 0;
    const dismount = argv[arg_dismount] != 0;
    if (argv[arg_list] != 0) {
        const options: Given = .{
            .user = rdargs.string(argv[arg_user]),
            .password = rdargs.string(argv[arg_password]),
            .domain = rdargs.string(argv[arg_domain]),
            .quiet = quiet,
        };
        // SERVER, or the first NAME where none was given with the keyword.
        const typed = rdargs.string(argv[arg_server]) orelse blk: {
            const names = rdargs.multi(argv[arg_name]);
            if (names.len == 1) break :blk names[0];
            _ = Printf(dl, MSG_NOSERVER, .{COMMAND_NAME});
            return dos.RETURN_ERROR;
        };
        return listOnOwnStack(sys, dl, span(typed), &options);
    }
    if (argv[arg_all] != 0) return if (dismount) dismountAll(sys, dl, quiet) else mountAll(sys, dl, quiet);
    const device_names = rdargs.multi(argv[arg_name]);
    if (device_names.len == 0) {
        _ = dl.PrintFault(dos.ERROR_REQUIRED_ARG_MISSING, COMMAND_NAME);
        return dos.RETURN_FAIL;
    }
    const options: Given = .{
        .share = rdargs.string(argv[arg_share]),
        .user = rdargs.string(argv[arg_user]),
        .password = rdargs.string(argv[arg_password]),
        .domain = rdargs.string(argv[arg_domain]),
        .volume = rdargs.string(argv[arg_volume]),
        .port = rdargs.number(argv[arg_port]),
        .readonly = argv[arg_readonly] != 0,
        .encrypt = argv[arg_encrypt] != 0,
        .save = argv[arg_save] != 0,
        .quiet = quiet,
    };
    var worst: i32 = dos.RETURN_OK;
    for (device_names) |name| {
        const rc = if (dismount) dismountOne(sys, dl, name, quiet) else mountOne(sys, dl, name, &options);
        if (rc > worst) worst = rc;
    }
    return worst;
}
