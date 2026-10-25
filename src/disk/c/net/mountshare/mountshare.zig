// SPDX-License-Identifier: MIT
//! MountShare: a share on an SMB server mounted as a device. Built
//! against the SDK only.
//!
//!   MountShare NAME/M,SHARE/K,USER/K,PASSWORD/K,DOMAIN/K,VOLUME/K,
//!              PORT/K/N,READONLY/S,ENCRYPT/S,QUIET/S,DISMOUNT/S
//!
//! NAME is the device - `NAS` or `NAS:` - and SHARE where it is,
//! `//server/share`: a name or an address, IPv6 in brackets, a port after
//! a colon if not 445. USER and PASSWORD log on, in DOMAIN when the
//! server asks for one; with neither the logon is anonymous, and a server
//! may take any of them as a guest. VOLUME names the volume - the
//! share's name without it. READONLY writes nothing whatever the server
//! allows; ENCRYPT mounts only if every message can be encrypted.
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
//! device off the list - not while anything on it is locked or open.

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
const placeOf = @import("place.zig").placeOf;

pub const COMMAND_NAME = "MountShare";
const VERSION_STRING = "\x00$VER: MountShare 1.0 (25.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "NAME/M,SHARE/K,USER/K,PASSWORD/K,DOMAIN/K,VOLUME/K,PORT/K/N,READONLY/S,ENCRYPT/S,QUIET/S,DISMOUNT/S";
const arg_name = 0;
const arg_share = 1;
const arg_user = 2;
const arg_password = 3;
const arg_domain = 4;
const arg_volume = 5;
const arg_port = 6;
const arg_readonly = 7;
const arg_encrypt = 8;
const arg_quiet = 9;
const arg_dismount = 10;
const arg_count = 11;

/// The handler process's stack: a command's, which grows with the
/// chip's pointers - the logon's work is deeper than a handler's default.
const handler_stack: u32 = dos.CLI_DEFAULT_STACK;
const handler_priority: i32 = 5;

/// crypto.library's first revision with MD4.
const CRYPTO_VERSION = 1;
const CRYPTO_REVISION = 4;

/// The longest device name, without its colon.
const device_max = 30;

const MSG_MOUNTED = "%s: %s: is //%s/%s, SMB %s%s";
const MSG_SIGNED = ", signed with %s";
const MSG_ENCRYPTED = ", encrypted with %s";
const MSG_GUEST = " as a guest";
const MSG_ANONYMOUS = " anonymously";
const MSG_NOSHARE = "%s: SHARE is needed, as //server/share\n";
const MSG_BADSHARE = "%s: '%s' is not //server/share\n";
const MSG_TOOLONG = "%s: %s is too long\n";
const MSG_TAKEN = "%s: %s: is already mounted\n";
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

/// The password's NT hash: MD4 over its UTF-16.
fn ntHash(cb: *CryptoBase, password: []const u8) [16]u8 {
    var context: crypto.HashContext = .{};
    _ = cb.InitHash(&context, crypto.HASH_MD4);
    for (password) |char| cb.UpdateHash(&context, &[2]u8{ char, 0 }, 2);
    var digest: [crypto.DIGEST_MAX]u8 = undefined;
    _ = cb.FinishHash(&context, &digest);
    return digest[0..16].*;
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

/// What a mount asks for, from the arguments.
const Wanted = struct {
    share: ?[*:0]const u8,
    user: ?[*:0]const u8,
    password: ?[*:0]const u8,
    domain: ?[*:0]const u8,
    volume: ?[*:0]const u8,
    port: ?i32,
    readonly: bool,
    encrypt: bool,
    quiet: bool,
};

/// One share mounted as `name`: the node made, the handler started, and
/// what it came to said.
fn mountOne(sys: *ExecBase, dl: *DosBase, name: [*:0]const u8, wanted: *const Wanted) i32 {
    var device_buffer: [device_max + 1]u8 = undefined;
    const device = deviceName(name, &device_buffer) orelse {
        _ = Printf(dl, MSG_TOOLONG, .{ COMMAND_NAME, name });
        return dos.RETURN_ERROR;
    };
    const share_text = wanted.share orelse {
        _ = Printf(dl, MSG_NOSHARE, .{COMMAND_NAME});
        return dos.RETURN_ERROR;
    };
    const place = placeOf(span(share_text)) orelse {
        _ = Printf(dl, MSG_BADSHARE, .{ COMMAND_NAME, share_text });
        return dos.RETURN_ERROR;
    };

    const block = sys.AllocVec(@sizeOf(smb.SmbStartup), exec.MEMF_CLEAR) orelse {
        _ = Printf(dl, MSG_NOMEM, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    const startup: *smb.SmbStartup = @ptrCast(@alignCast(block));
    startup.* = .{};
    startup.fssm.environ = &startup.env;
    const fits = copyInto(&startup.server, place.server) and copyInto(&startup.share, place.share) and
        copyInto(&startup.user, if (wanted.user) |user| span(user) else "") and
        copyInto(&startup.domain, if (wanted.domain) |domain| span(domain) else "") and
        copyInto(&startup.volume, if (wanted.volume) |volume| span(volume) else "");
    if (!fits) {
        sys.FreeVec(block);
        _ = Printf(dl, MSG_TOOLONG, .{ COMMAND_NAME, share_text });
        return dos.RETURN_ERROR;
    }
    startup.port = place.port;
    if (wanted.port) |port| {
        if (port > 0 and port <= 0xFFFF) startup.port = @intCast(port);
    }
    if (wanted.readonly) startup.flags |= smb.SMBF_READONLY;
    if (wanted.encrypt) startup.flags |= smb.SMBF_ENCRYPT;
    if (wanted.password) |password| {
        const crypto_lib = sys.OpenLibrary(crypto.CRYPTONAME, CRYPTO_VERSION);
        const usable = if (crypto_lib) |lib| lib.version > CRYPTO_VERSION or lib.revision >= CRYPTO_REVISION else false;
        if (!usable) {
            if (crypto_lib) |lib| sys.CloseLibrary(lib);
            sys.FreeVec(block);
            _ = Printf(dl, MSG_NOCRYPTO, .{ COMMAND_NAME, @as(u32, CRYPTO_VERSION), @as(u32, CRYPTO_REVISION) });
            return dos.RETURN_FAIL;
        }
        startup.nt_hash = ntHash(@ptrCast(crypto_lib.?), span(password));
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
    if (!wanted.quiet) {
        const result = startup.result;
        // A server may say nothing of an anonymous session but leave it
        // unsigned: no user and no password is one.
        const anonymous = result.session_flags & smb.SMB2_SESSION_FLAG_IS_NULL != 0 or
            (wanted.user == null and wanted.password == null);
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
    return dos.RETURN_OK;
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

    const device_names = rdargs.multi(argv[arg_name]);
    if (device_names.len == 0) {
        _ = dl.PrintFault(dos.ERROR_REQUIRED_ARG_MISSING, COMMAND_NAME);
        return dos.RETURN_FAIL;
    }
    const quiet = argv[arg_quiet] != 0;
    const wanted: Wanted = .{
        .share = rdargs.string(argv[arg_share]),
        .user = rdargs.string(argv[arg_user]),
        .password = rdargs.string(argv[arg_password]),
        .domain = rdargs.string(argv[arg_domain]),
        .volume = rdargs.string(argv[arg_volume]),
        .port = rdargs.number(argv[arg_port]),
        .readonly = argv[arg_readonly] != 0,
        .encrypt = argv[arg_encrypt] != 0,
        .quiet = quiet,
    };
    var worst: i32 = dos.RETURN_OK;
    for (device_names) |name| {
        const rc = if (argv[arg_dismount] != 0) dismountOne(sys, dl, name, quiet) else mountOne(sys, dl, name, &wanted);
        if (rc > worst) worst = rc;
    }
    return worst;
}
