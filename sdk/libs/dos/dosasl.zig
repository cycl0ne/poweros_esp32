// SPDX-License-Identifier: MIT
//! Pattern searches over directories (dos/dosasl.h): MatchFirst's
//! AnchorPath and its chain of AChain nodes, linked by pointers. The patterns themselves are utility.library's
//! (sdk/libs/utility/pattern.zig).

const FileInfoBlock = @import("dos.zig").FileInfoBlock;
const FileLock = @import("dosextens.zig").FileLock;

// ap_Flags
/// APF_DOWILD: "user option ALL"; nothing uses it.
pub const APF_DOWILD: u32 = 1 << 0;
/// The pattern has wildcards (set by MatchFirst).
pub const APF_ITSWILD: u32 = 1 << 1;
/// Set by the caller: MatchNext goes into the directory just found.
pub const APF_DODIR: u32 = 1 << 2;
/// Set by MatchNext when it gives a directory again after going through
/// it; the caller clears it.
pub const APF_DIDDIR: u32 = 1 << 3;
/// MatchFirst failed for memory (or a lock).
pub const APF_NOMEMERR: u32 = 1 << 4;
/// APF_DODOT: `.` as the current directory; nothing uses it.
pub const APF_DODOT: u32 = 1 << 5;
/// ap_Last's lock changed since the last call.
pub const APF_DirChanged: u32 = 1 << 6;
/// DODIR goes into hard-linked directories too.
pub const APF_FollowHLinks: u32 = 1 << 7;

// an_Flags
pub const DDF_PatternBit: u8 = 1 << 0;
pub const DDF_ExaminedBit: u8 = 1 << 1;
pub const DDF_Completed: u8 = 1 << 2;
pub const DDF_AllBit: u8 = 1 << 3;
pub const DDF_Single: u8 = 1 << 4;

/// struct AnchorPath: a search's state, cleared before MatchFirst. With
/// `strlen` not 0, the caller puts that many bytes right after it
/// (ap_Buf[]) for each entry's full path: allocate
/// `@sizeOf(AnchorPath) + strlen`.
pub const AnchorPath = extern struct {
    /// ap_Base (ap_First): the first node.
    base: ?*AChain = null,
    /// ap_Last (ap_Current): the node MatchNext works on.
    last: ?*AChain = null,
    /// ap_BreakBits: signals that stop the search (ERROR_BREAK).
    break_bits: u32 = 0,
    /// ap_FoundBreak: the ones that did.
    found_break: u32 = 0,
    /// ap_Flags: APF_*.
    flags: u32 = 0,
    /// ap_Strlen: the size of the path buffer after the structure; 0: none.
    strlen: u32 = 0,
    /// ap_Info: the entry found.
    info: FileInfoBlock = .{},

    /// ap_Buf: the full path of the entry found.
    pub fn buffer(ap: *AnchorPath) [*]u8 {
        return @as([*]u8, @ptrCast(ap)) + @sizeOf(AnchorPath);
    }
};

/// struct AChain: one level of the search, its string right after it.
pub const AChain = extern struct {
    /// an_Child: the next level down.
    child: ?*AChain = null,
    /// an_Parent: the level above.
    parent: ?*AChain = null,
    /// an_Lock: the directory this level searches in.
    lock: ?*FileLock = null,
    /// an_Info: the entry this level is at.
    info: FileInfoBlock = .{},
    /// an_Flags: DDF_*.
    flags: u8 = 0,

    /// an_String: the level's name, or its pattern in tokens (upper case).
    pub fn string(a: *AChain) [*:0]u8 {
        return @ptrCast(@as([*]u8, @ptrCast(a)) + @sizeOf(AChain));
    }
};
