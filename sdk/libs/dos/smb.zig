// SPDX-License-Identifier: MIT
//! A share on an SMB 2/3 server mounted as a DOS device: what the handler
//! (`src/disk/devs/handlers/smb`) and C:net/MountShare share - the
//! share's startup message, its DosType, the protocol's names for
//! dialects, signing and ciphers, and the server's status codes.
//!
//! **The startup begins with a FileSysStartupMsg.** Every program that
//! walks the device list reads a node's startup as one
//! (`filehandler.startupOf`): automount, the partition tools, Format, dos
//! itself. A share's has no device, so `opensUnit` is false for it
//! wherever it is asked, and an environment whose DosType is ID_SMB_DISK,
//! which is what Format reads; the share's own fields follow. MountShare
//! allocates it with the node and frees it with the node. The handler
//! reads it at every start and writes what it found into `result`, so the
//! tool can say what a mount came to.
//!
//! **No password in it.** The tool puts in the password's NT hash - MD4
//! over its UTF-16 - which is all NTLMv2 needs, and all a later start of
//! the handler needs: the password itself is never kept.

const dos = @import("dos.zig");
const filehandler = @import("filehandler.zig");

/// The DosType of a share: 'SMB\0'. Not one a partition may name, so it
/// is not in `filesystems.zig`'s table.
pub const ID_SMB_DISK: u32 = 0x534D_4200;

/// The port SMB is served on, straight over TCP.
pub const SMB_PORT: u16 = 445;

/// The handler's name, as a device node's Handler names it.
pub const SMB_HANDLER = "smb-handler";

/// The longest server name, share name, user name and domain the startup
/// holds, without the NUL.
pub const SMB_SERVER_MAX: usize = 255;
pub const SMB_SHARE_MAX: usize = 80;
pub const SMB_USER_MAX: usize = 104;
pub const SMB_DOMAIN_MAX: usize = 255;

/// The share's settings, `SmbStartup.flags`. SMBF_READONLY: nothing is
/// written, whatever the server would allow. SMBF_ENCRYPT: every message
/// encrypted, or no mount. SMBF_HASH: `nt_hash` holds a password's hash;
/// without it the logon has no password - anonymous with no user, the
/// empty password with one.
pub const SMBF_READONLY: u32 = 1 << 0;
pub const SMBF_ENCRYPT: u32 = 1 << 1;
pub const SMBF_HASH: u32 = 1 << 2;

/// Where a start of the handler stopped, `SmbResult.stage`: SMBSTAGE_DONE
/// when it did not. RESOLVE, the server's name gave no address
/// (`error` is GetAddrInfo's EAI_*); CONNECT, no connection to any of its
/// addresses (`error` is the errno); NEGOTIATE, LOGON and TREE, the
/// server's answer to the negotiation, the logon and the connection to the
/// share (`status`); SECURITY, signing or encryption that failed or could
/// not be had (`error` is SMBSECURITY_*); NETWORK, no bsdsocket.library or
/// crypto.library; MEMORY, no memory.
pub const SMBSTAGE_DONE: u32 = 0;
pub const SMBSTAGE_RESOLVE: u32 = 1;
pub const SMBSTAGE_CONNECT: u32 = 2;
pub const SMBSTAGE_NEGOTIATE: u32 = 3;
pub const SMBSTAGE_LOGON: u32 = 4;
pub const SMBSTAGE_TREE: u32 = 5;
pub const SMBSTAGE_SECURITY: u32 = 6;
pub const SMBSTAGE_NETWORK: u32 = 7;
pub const SMBSTAGE_MEMORY: u32 = 8;

/// Why a start stopped at SMBSTAGE_SECURITY, `SmbResult.error`.
/// SMBSECURITY_ENCRYPTION: encryption was asked for - by SMBF_ENCRYPT, the
/// server or the share - and this session cannot have it; it takes
/// AES-GCM on SMB 3.1.1 and a logon with keys, not a guest's or an
/// anonymous one. SMBSECURITY_SIGNATURE: an answer's signature or seal did
/// not verify, or its signed account of the negotiation differed from the
/// one made.
pub const SMBSECURITY_ENCRYPTION: i32 = 1;
pub const SMBSECURITY_SIGNATURE: i32 = 2;

/// What the handler found, written at each start it makes.
pub const SmbResult = extern struct {
    /// SMBSTAGE_*: where the start stopped, or SMBSTAGE_DONE.
    stage: u32 = SMBSTAGE_DONE,
    /// The server's NTSTATUS at that stage (STATUS_*).
    status: u32 = 0,
    /// The errno or EAI_* code at RESOLVE and CONNECT, SMBSECURITY_* at
    /// SECURITY.
    @"error": i32 = 0,
    /// The dialect spoken (SMB2_DIALECT_*), 0 before the negotiation.
    dialect: u16 = 0,
    /// SMB2_SESSION_FLAG_*: a guest's or an anonymous session.
    session_flags: u16 = 0,
    /// The signing algorithm (SMB2_SIGNING_*), SMB2_SIGNING_NONE when
    /// nothing is signed.
    signing: u16 = SMB2_SIGNING_NONE,
    /// The cipher (SMB2_CIPHER_*), SMB2_CIPHER_NONE when nothing is
    /// encrypted.
    cipher: u16 = SMB2_CIPHER_NONE,
};

/// The startup message of a share's device node. Every string is
/// Latin-1 and ends in a NUL.
pub const SmbStartup = extern struct {
    /// What every reader of the device list takes it for: no device, and
    /// `environ` at `env`.
    fssm: filehandler.FileSysStartupMsg = .{},
    /// DosType ID_SMB_DISK.
    env: filehandler.DosEnvec = .{ .dos_type = ID_SMB_DISK },
    /// The structure's size as the tool was built with it.
    size: u32 = @sizeOf(SmbStartup),
    /// SMBF_*.
    flags: u32 = 0,
    /// The server's port; 0 is SMB_PORT.
    port: u16 = 0,
    reserved: u16 = 0,
    /// The server, by name or address.
    server: [SMB_SERVER_MAX + 1]u8 = @splat(0),
    /// The share on it.
    share: [SMB_SHARE_MAX + 1]u8 = @splat(0),
    /// Who logs on, and in which domain; both may be empty.
    user: [SMB_USER_MAX + 1]u8 = @splat(0),
    domain: [SMB_DOMAIN_MAX + 1]u8 = @splat(0),
    /// The volume's name; empty for the share's.
    volume: [dos.name_max + 1]u8 = @splat(0),
    /// The password's NT hash, with SMBF_HASH.
    nt_hash: [16]u8 = @splat(0),
    /// Written by the handler.
    result: SmbResult = .{},

    /// The startup a device node points at, or null when it is no
    /// share's: no FileSysStartupMsg there, a device named in it, another
    /// DosType, or a size smaller than this one's.
    pub fn of(startup: usize) ?*SmbStartup {
        const fssm = filehandler.startupOf(startup) orelse return null;
        if (fssm.device != null) return null;
        const env = fssm.environ orelse return null;
        if (env.dos_type != ID_SMB_DISK) return null;
        const share: *SmbStartup = @ptrFromInt(startup);
        if (share.size < @sizeOf(SmbStartup)) return null;
        return share;
    }
};

// --- the protocol's names ----------------------------------------------------

/// The dialects, as NEGOTIATE names them.
pub const SMB2_DIALECT_0202: u16 = 0x0202;
pub const SMB2_DIALECT_0210: u16 = 0x0210;
pub const SMB2_DIALECT_0300: u16 = 0x0300;
pub const SMB2_DIALECT_0302: u16 = 0x0302;
pub const SMB2_DIALECT_0311: u16 = 0x0311;

/// SESSION_SETUP's session flags: a guest's session, an anonymous one,
/// and one whose every message is encrypted.
pub const SMB2_SESSION_FLAG_IS_GUEST: u16 = 0x0001;
pub const SMB2_SESSION_FLAG_IS_NULL: u16 = 0x0002;
pub const SMB2_SESSION_FLAG_ENCRYPT_DATA: u16 = 0x0004;

/// The signing algorithms, as 3.1.1's signing capabilities name them;
/// 2.x always signs with HMAC-SHA256, 3.0 and 3.0.2 with AES-CMAC.
pub const SMB2_SIGNING_HMAC_SHA256: u16 = 0x0000;
pub const SMB2_SIGNING_AES_CMAC: u16 = 0x0001;
pub const SMB2_SIGNING_AES_GMAC: u16 = 0x0002;
pub const SMB2_SIGNING_NONE: u16 = 0xFFFF;

/// The ciphers, as the encryption capabilities name them.
pub const SMB2_CIPHER_NONE: u16 = 0x0000;
pub const SMB2_CIPHER_AES_128_CCM: u16 = 0x0001;
pub const SMB2_CIPHER_AES_128_GCM: u16 = 0x0002;
pub const SMB2_CIPHER_AES_256_CCM: u16 = 0x0003;
pub const SMB2_CIPHER_AES_256_GCM: u16 = 0x0004;

// --- the server's status codes (NTSTATUS) -------------------------------------

pub const STATUS_SUCCESS: u32 = 0x0000_0000;
pub const STATUS_PENDING: u32 = 0x0000_0103;
pub const STATUS_NOTIFY_ENUM_DIR: u32 = 0x0000_010C;
pub const STATUS_BUFFER_OVERFLOW: u32 = 0x8000_0005;
pub const STATUS_NO_MORE_FILES: u32 = 0x8000_0006;
pub const STATUS_INFO_LENGTH_MISMATCH: u32 = 0xC000_0004;
pub const STATUS_INVALID_HANDLE: u32 = 0xC000_0008;
pub const STATUS_INVALID_PARAMETER: u32 = 0xC000_000D;
pub const STATUS_NO_SUCH_FILE: u32 = 0xC000_000F;
pub const STATUS_INVALID_DEVICE_REQUEST: u32 = 0xC000_0010;
pub const STATUS_END_OF_FILE: u32 = 0xC000_0011;
pub const STATUS_MORE_PROCESSING_REQUIRED: u32 = 0xC000_0016;
pub const STATUS_ACCESS_DENIED: u32 = 0xC000_0022;
pub const STATUS_BUFFER_TOO_SMALL: u32 = 0xC000_0023;
pub const STATUS_OBJECT_NAME_INVALID: u32 = 0xC000_0033;
pub const STATUS_OBJECT_NAME_NOT_FOUND: u32 = 0xC000_0034;
pub const STATUS_OBJECT_NAME_COLLISION: u32 = 0xC000_0035;
pub const STATUS_OBJECT_PATH_INVALID: u32 = 0xC000_0039;
pub const STATUS_OBJECT_PATH_NOT_FOUND: u32 = 0xC000_003A;
pub const STATUS_OBJECT_PATH_SYNTAX_BAD: u32 = 0xC000_003B;
pub const STATUS_SHARING_VIOLATION: u32 = 0xC000_0043;
pub const STATUS_QUOTA_EXCEEDED: u32 = 0xC000_0044;
pub const STATUS_FILE_LOCK_CONFLICT: u32 = 0xC000_0054;
pub const STATUS_LOCK_NOT_GRANTED: u32 = 0xC000_0055;
pub const STATUS_DELETE_PENDING: u32 = 0xC000_0056;
pub const STATUS_NO_SUCH_USER: u32 = 0xC000_0064;
pub const STATUS_WRONG_PASSWORD: u32 = 0xC000_006A;
pub const STATUS_LOGON_FAILURE: u32 = 0xC000_006D;
pub const STATUS_ACCOUNT_RESTRICTION: u32 = 0xC000_006E;
pub const STATUS_INVALID_LOGON_HOURS: u32 = 0xC000_006F;
pub const STATUS_PASSWORD_EXPIRED: u32 = 0xC000_0071;
pub const STATUS_ACCOUNT_DISABLED: u32 = 0xC000_0072;
pub const STATUS_DISK_FULL: u32 = 0xC000_007F;
pub const STATUS_INSUFFICIENT_RESOURCES: u32 = 0xC000_009A;
pub const STATUS_MEDIA_WRITE_PROTECTED: u32 = 0xC000_00A2;
pub const STATUS_FILE_IS_A_DIRECTORY: u32 = 0xC000_00BA;
pub const STATUS_NOT_SUPPORTED: u32 = 0xC000_00BB;
pub const STATUS_NETWORK_NAME_DELETED: u32 = 0xC000_00C9;
pub const STATUS_NETWORK_ACCESS_DENIED: u32 = 0xC000_00CA;
pub const STATUS_BAD_NETWORK_NAME: u32 = 0xC000_00CC;
pub const STATUS_REQUEST_NOT_ACCEPTED: u32 = 0xC000_00D0;
pub const STATUS_NOT_SAME_DEVICE: u32 = 0xC000_00D4;
pub const STATUS_FILE_RENAMED: u32 = 0xC000_00D5;
pub const STATUS_DIRECTORY_NOT_EMPTY: u32 = 0xC000_0101;
pub const STATUS_NOT_A_DIRECTORY: u32 = 0xC000_0103;
pub const STATUS_CANCELLED: u32 = 0xC000_0120;
pub const STATUS_CANNOT_DELETE: u32 = 0xC000_0121;
pub const STATUS_FILE_CLOSED: u32 = 0xC000_0128;
pub const STATUS_USER_SESSION_DELETED: u32 = 0xC000_0203;
pub const STATUS_ACCOUNT_LOCKED_OUT: u32 = 0xC000_0234;
pub const STATUS_NETWORK_SESSION_EXPIRED: u32 = 0xC000_035C;
pub const STATUS_INVALID_SIGNATURE: u32 = 0xC000_A000;

/// Whether a status is an error, rather than success or a warning.
pub fn isError(status: u32) bool {
    return status >> 30 == 3;
}
