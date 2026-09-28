// SPDX-License-Identifier: MIT
//! iffparse.library: reading and writing IFF, on the disk in LIBS:.
//!
//! An IFF file is chunks inside chunks. Each chunk is an id of four
//! characters and a size, and the three generic ids - `FORM`, `LIST` and
//! `CAT ` - hold other chunks and carry a type of four characters as
//! well. A picture is a `FORM ILBM`, a piece of text a `FORM FTXT`, and
//! what is in them is chunks named by the form's own kind.
//!
//! **Reading.** A program makes a handle (`AllocIFF`), says where the
//! bytes come from (`InitIFFasDOS` for a file, `InitIFFasClip` for the
//! clipboard, or `InitIFF` with a hook of its own), opens it (`OpenIFF`)
//! and then walks the file with `ParseIFF`. The walk stops where the
//! program asked it to: `StopChunk` names a chunk to stop at,
//! `PropChunk` one to remember the contents of (read back later with
//! `FindProp`), `CollectionChunk` one to remember every one of, and
//! `StopOnExit` a chunk to stop at when its end is reached. Where the
//! walk has stopped, `CurrentChunk` says which chunk that is and
//! `ReadChunkBytes` reads it.
//!
//! **Writing.** The same handle opened `IFFF_WRITE`: `PushChunk` starts
//! a chunk, `WriteChunkBytes` fills it, `PopChunk` ends it. A chunk
//! pushed with `IFFSIZE_UNKNOWN` has its size written back when it is
//! popped, so nothing has to be counted in advance.
//!
//! **Context.** The chunks the walk is inside are a stack, deepest last:
//! `CurrentChunk` is the top and `ParentChunk` the one it is in. Each
//! carries local items - the properties it has stored, the handlers set
//! on it - which are thrown away when the walk leaves it. That is what
//! makes a property found inside a `FORM` the one that `FORM` set, and
//! not one from a form already gone past.
//!
//!   const iff = ip.AllocIFF() orelse return;
//!   defer ip.FreeIFF(iff);
//!   iff.stream = @intFromPtr(file);
//!   ip.InitIFFasDOS(iff);
//!   if (ip.OpenIFF(iff, ip.IFFF_READ) != 0) return;
//!   defer ip.CloseIFF(iff);
//!   _ = ip.PropChunk(iff, ip.MakeID("ILBM"), ip.MakeID("BMHD"));
//!   _ = ip.StopChunk(iff, ip.MakeID("ILBM"), ip.MakeID("BODY"));
//!   if (ip.ParseIFF(iff, ip.IFFPARSE_SCAN) != 0) return;
//!   const header = ip.FindProp(iff, ip.MakeID("ILBM"), ip.MakeID("BMHD"));

const exec = @import("../exec/exec.zig");
const utility = @import("../utility/utility.zig");
const clipboard = @import("../../devices/clipboard.zig");

pub const IFFPARSENAME = "iffparse.library";

/// The four characters of an id as the number they make: the first
/// character is the highest byte, so the number sorts and compares as
/// the characters do.
pub fn MakeID(comptime name: *const [4:0]u8) u32 {
    return @as(u32, name[0]) << 24 | @as(u32, name[1]) << 16 | @as(u32, name[2]) << 8 | name[3];
}

// --- the handle -------------------------------------------------------------

/// struct IFFHandle: an IFF file being read or written. Only
/// `AllocIFF` makes one, since the library keeps its own parts behind it.
pub const IFFHandle = extern struct {
    /// iff_Stream: whatever the stream hook needs to find the bytes - a
    /// dos file handle, a `*ClipboardHandle`, anything. The library never
    /// looks at it.
    stream: usize = 0,
    /// iff_Flags: `IFFF_*`. The high half is the library's.
    flags: u32 = 0,
    /// iff_Depth: how many chunks deep the walk is.
    depth: i32 = 0,
};

/// Read mode: the default, and what `OpenIFF` is given for reading.
pub const IFFF_READ: u32 = 0;
/// Write mode.
pub const IFFF_WRITE: u32 = 1;
pub const IFFF_RWBITS: u32 = IFFF_READ | IFFF_WRITE;
/// The stream can seek forwards. Without it a seek forward is read and
/// thrown away, which is enough to read an IFF file.
pub const IFFF_FSEEK: u32 = 1 << 1;
/// The stream can seek both ways. A write to a stream without this is
/// held in memory until the file is done, so that a chunk's size can be
/// written back into it.
pub const IFFF_RSEEK: u32 = 1 << 2;
/// The library's own bits; a program leaves them alone.
pub const IFFF_RESERVED: u32 = 0xFFFF_0000;

/// What a stream hook is called with.
pub const IFFStreamCmd = extern struct {
    /// sc_Command: `IFFCMD_*`.
    command: i32 = 0,
    /// sc_Buf
    buf: ?[*]u8 = null,
    /// sc_NBytes: how many bytes, or how far to seek.
    bytes: i32 = 0,
};

/// A stream hook's commands. It answers 0 for done and anything else for
/// a failure, which the library turns into the matching `IFFERR_`.
pub const IFFCMD_INIT: i32 = 0;
pub const IFFCMD_CLEANUP: i32 = 1;
pub const IFFCMD_READ: i32 = 2;
pub const IFFCMD_WRITE: i32 = 3;
pub const IFFCMD_SEEK: i32 = 4;
pub const IFFCMD_ENTRY: i32 = 5;
pub const IFFCMD_EXIT: i32 = 6;
pub const IFFCMD_PURGELCI: i32 = 7;

// --- the context stack ------------------------------------------------------

/// struct ContextNode: one chunk of those the walk is inside.
pub const ContextNode = extern struct {
    node: exec.MinNode = .{},
    /// cn_ID: the chunk's own four characters.
    id: u32 = 0,
    /// cn_Type: the kind of the generic chunk it is in - `ILBM` for the
    /// chunks of a `FORM ILBM` - and its own for a generic chunk.
    type: u32 = 0,
    /// cn_Size: how many bytes the chunk holds.
    size: i32 = 0,
    /// cn_Scan: how many of them have been read or written.
    scan: i32 = 0,
};

/// struct LocalContextItem: something kept with a chunk for as long as
/// the walk is inside it.
pub const LocalContextItem = extern struct {
    node: exec.MinNode = .{},
    /// lci_ID, lci_Type: the chunk it is about.
    id: u32 = 0,
    type: u32 = 0,
    /// lci_Ident: what kind of item it is (`IFFLCI_*`, or a program's
    /// own).
    ident: u32 = 0,
};

/// struct StoredProperty: the contents of a property chunk, kept by
/// `PropChunk` and found again with `FindProp`.
pub const StoredProperty = extern struct {
    /// sp_Size
    size: i32 = 0,
    /// sp_Data
    data: ?[*]u8 = null,
};

/// struct CollectionItem: one of the chunks `CollectionChunk` kept, newest
/// first.
pub const CollectionItem = extern struct {
    /// ci_Next
    next: ?*CollectionItem = null,
    /// ci_Size
    size: i32 = 0,
    /// ci_Data
    data: ?[*]u8 = null,
};

/// struct ClipboardHandle: `OpenClipboard`'s answer, which goes in a
/// handle's `stream` for `InitIFFasClip`.
pub const ClipboardHandle = extern struct {
    /// cbh_Req
    req: clipboard.IOClipReq = .{},
    /// cbh_CBport: where the request comes back.
    port: exec.MsgPort = .{},
    /// cbh_SatisfyPort: where a `CBD_POST` is answered.
    satisfy_port: exec.MsgPort = .{},
};

// --- what the calls answer --------------------------------------------------

/// The end of the file: there is nothing more to walk.
pub const IFFERR_EOF: i32 = -1;
/// The end of a chunk: the walk is about to leave it.
pub const IFFERR_EOC: i32 = -2;
/// No `FORM` or `LIST` to store a property in.
pub const IFFERR_NOSCOPE: i32 = -3;
pub const IFFERR_NOMEM: i32 = -4;
pub const IFFERR_READ: i32 = -5;
pub const IFFERR_WRITE: i32 = -6;
pub const IFFERR_SEEK: i32 = -7;
/// The file says one thing and holds another.
pub const IFFERR_MANGLED: i32 = -8;
/// A chunk where the IFF rules allow none.
pub const IFFERR_SYNTAX: i32 = -9;
/// It does not begin `FORM`, `LIST` or `CAT `.
pub const IFFERR_NOTIFF: i32 = -10;
/// No stream hook: `InitIFF` was never called.
pub const IFFERR_NOHOOK: i32 = -11;
/// A handler asked for the walk to stop; `ParseIFF` answers 0.
pub const IFF_RETURN2CLIENT: i32 = -12;

// --- the ids every IFF file knows -------------------------------------------

pub const ID_FORM = MakeID("FORM");
pub const ID_LIST = MakeID("LIST");
pub const ID_CAT = MakeID("CAT ");
pub const ID_PROP = MakeID("PROP");
pub const ID_NULL = MakeID("    ");

/// The `ident` of the local items the library keeps itself.
pub const IFFLCI_PROP = MakeID("prop");
pub const IFFLCI_COLLECTION = MakeID("coll");
pub const IFFLCI_ENTRYHANDLER = MakeID("enhd");
pub const IFFLCI_EXITHANDLER = MakeID("exhd");

/// How far `ParseIFF` goes: on to the next chunk the program asked to
/// stop at (`SCAN`), one chunk at a time with the handlers run (`STEP`),
/// or one chunk at a time with nothing run (`RAWSTEP`).
pub const IFFPARSE_SCAN: i32 = 0;
pub const IFFPARSE_STEP: i32 = 1;
pub const IFFPARSE_RAWSTEP: i32 = 2;

/// Where `StoreLocalItem` puts an item: with the handle itself, with the
/// chunk the walk is in, or with the `FORM` or `LIST` it is inside.
pub const IFFSLI_ROOT: i32 = 1;
pub const IFFSLI_TOP: i32 = 2;
pub const IFFSLI_PROP: i32 = 3;

/// A chunk pushed with this has its size written back when it is popped.
pub const IFFSIZE_UNKNOWN: i32 = -1;

/// Whether an id is one of the three that hold other chunks.
pub fn isGenericID(id: u32) bool {
    return id == ID_FORM or id == ID_LIST or id == ID_CAT or id == ID_PROP;
}

/// A hook's shape, for a stream of a program's own: it is called with the
/// handle as the object and an `IFFStreamCmd` as the message.
pub const StreamHook = utility.Hook;
