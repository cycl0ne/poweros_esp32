// SPDX-License-Identifier: MIT
//! iffparse.library's base, and the shapes behind the public ones.
//!
//! Every structure a program sees - the handle, a context node, a local
//! item - is the head of a larger one the library keeps for itself, which
//! is why only the library makes them. `Handle` holds the stack of chunks
//! the walk is inside and, for a stream that cannot seek, the writes held
//! back until the file is done; `Node` holds a chunk's local items;
//! `Item` holds an item's purge hook, with the item's own bytes after it.
//!
//! The stack's bottom node is a node of its own with no id, made when the
//! handle is. It is what gives every context call somewhere to look when
//! the walk has entered nothing, and is why `CurrentChunk` answers null
//! by looking at the id rather than at the list.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const iffparse = sdk.iffparse;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;

pub const IFFParseBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    seg_list: ?*anyopaque = null,
    /// dos.library, which the file stream reads and writes through.
    dos_base: *DosBase,
    /// utility.library, which the hooks are called through.
    utility_base: *UtilityBase,
};

/// The base from exec's Library header.
pub fn iffBase(lib: *exec.Library) *IFFParseBase {
    return @fieldParentPtr("lib", lib);
}

/// A handle, with what the library keeps behind the public part.
pub const Handle = extern struct {
    public: iffparse.IFFHandle = .{},
    /// The chunks the walk is inside, innermost first, the bottom node
    /// last.
    stack: exec.MinList = .{},
    /// Writes held back for a stream that cannot seek back.
    write_buffers: exec.MinList = .{},
    stream_hook: ?*utility.Hook = null,
    /// The hook of a stream the library provides itself - a file, the
    /// clipboard. A module keeps no state of its own, so the hook lives
    /// with the handle it belongs to rather than in the library's code.
    own_stream: utility.Hook = .{},
    base: *IFFParseBase,
};

/// A newly opened file, before the first chunk is pushed.
pub const IFFFP_NEWIO: u32 = 1 << 16;
/// Poised at the end of a chunk: the next step pops it.
pub const IFFFP_PAUSE: u32 = 1 << 17;

/// A context node, with the local items kept with its chunk.
pub const Node = extern struct {
    public: iffparse.ContextNode = .{},
    local_items: exec.MinList = .{},
};

/// A local item, with its purge hook. Its `data_size` bytes follow it.
pub const Item = extern struct {
    public: iffparse.LocalContextItem = .{},
    purge_hook: ?*utility.Hook = null,
};

/// A write held back: its bytes follow it.
pub const WriteBuffer = extern struct {
    node: exec.MinNode = .{},
    size: i32 = 0,
};

/// What an entry or exit handler is: the item data `EntryHandler` and
/// `ExitHandler` store.
pub const ChunkHandler = extern struct {
    hook: *utility.Hook,
    object: ?*anyopaque,
    /// The library's own handlers - the ones `PropChunk`, `StopChunk`,
    /// `CollectionChunk` and `StopOnExit` install - have no hook of a
    /// caller's to point at, so each keeps its own here.
    own: utility.Hook = .{},
};

/// What a collection is: the item data `CollectionChunk` stores. The
/// items from `first` up to but not including `last_ptr` are this
/// context's own, and go when it does; the rest belong to a context
/// further out.
pub const CollectionList = extern struct {
    first: ?*iffparse.CollectionItem = null,
    last_ptr: ?*iffparse.CollectionItem = null,
    context: *iffparse.ContextNode,
    /// What frees the items this context gathered when it is left, and
    /// the base it frees them through: a purge hook is handed the item
    /// and nothing else.
    purge: utility.Hook = .{},
    base: *IFFParseBase,
};

/// The handle's private part from the public one.
pub fn handleOf(iff: *iffparse.IFFHandle) *Handle {
    return @fieldParentPtr("public", iff);
}

/// A context node's private part from the public one.
pub fn nodeOf(cn: *iffparse.ContextNode) *Node {
    return @fieldParentPtr("public", cn);
}

/// A local item's private part from the public one.
pub fn itemOf(item: *iffparse.LocalContextItem) *Item {
    return @fieldParentPtr("public", item);
}

/// Each node of a list in turn, the tail sentinel left out.
pub const Walk = struct {
    at: ?*exec.MinNode,

    pub fn over(list: *exec.MinList) Walk {
        return .{ .at = list.head };
    }

    pub fn next(w: *Walk) ?*exec.MinNode {
        const node = w.at orelse return null;
        w.at = node.succ orelse return null;
        return node;
    }
};
