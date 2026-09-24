// SPDX-License-Identifier: MPL-2.0
//! MakeLibrary: a library's one block - jump table below the base, the
//! module's data above - taken with `AllocMem`, laid out, and handed to the
//! module's init. It is not put on any list; `AddLibrary` does that.

const sdk = @import("sdk");
const _library = @import("_library.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Library = sdk.exec.Library;
const InitFn = sdk.exec.InitFn;

/// Builds a library in memory and runs its init routine, without putting it
/// on the library list.
///
/// SYNOPSIS:
/// ```zig
/// fn MakeLibrary( base: *ExecBase, vectors: []const *const anyopaque,
///     data_size: usize, init: ?InitFn, seg_list: ?*anyopaque, ) ?*Library
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `vectors` - the jump table, in slot order: Open, Close, Expunge,
///   ExtFunc, then the library's own functions. Every library brings its
///   own table; a resource has no standard vectors and starts at its own
///   first function, which is why no shape is required beyond "at least
///   one".
/// - `count` - how many entries `vectors` has. At least 1.
/// - `data_size` - bytes of base, `@sizeOf(Library)` at least. The Library
///   header is at the front and the module's own state follows it.
/// - `init_fn` - run on the built library, or null for none. It is handed
///   the library, `seg_list` and the SDK's `ExecBase`, and answers the
///   library or null to refuse.
/// - `seg_list` - passed to `init_fn` untouched. Null for a module in the
///   ROM; a loaded module's segments otherwise.
///
/// RESULT:
/// The library base, or null: `count` was 0, `data_size` was smaller than a
/// Library header, the table or the base would not fit a `u16`, there was
/// no memory, or `init_fn` refused - in which case the memory is freed
/// before returning.
///
/// BEHAVIOR:
/// The block is cleared, the vectors are written below the base and the
/// header's `neg_size` and `pos_size` are filled in. The base is 8-aligned
/// whatever the vector count, because a module's data may hold 64-bit
/// fields; the table is rounded up to that and the spare word sits at its
/// far end, below the last vector.
///
/// The library is not on any list when this returns, so nothing can open
/// it yet. `AddLibrary` is the second step, and `CreateLibrary` is both in
/// one.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It allocates, and `init_fn` may do anything.
/// - Forbid: not needed, and not taken here.
/// - Process: a Task will do, unless `init_fn` needs more.
///
/// OWNERSHIP:
/// The caller's until it is added and expunged, or freed by hand. The name
/// and ID string are *not* copied: whatever the init routine puts in
/// `node.name` must outlive the library, which for a ROM module is the ROM
/// image. `CreateLibrary` is the call that copies them.
///
/// NOTES:
/// `count` and `vectors` are two arguments here and one slice inside,
/// because a jump table cannot carry a Zig slice.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddLibrary`, `CreateLibrary`, `RemLibrary`
///
/// EXAMPLES:
/// ```zig
/// const vectors = [_]*const anyopaque{
///     exec.vec(myOpen), exec.vec(myClose), exec.vec(myExpunge),
///     exec.vec(myExtFunc), exec.vec(myFunc),
/// };
/// const lib = sys.MakeLibrary(&vectors, vectors.len,
///     @sizeOf(MyBase), &myInit, null) orelse return;
/// sys.AddLibrary(lib);
/// ```
pub fn MakeLibrary(
    base: *ExecBase,
    vectors: []const *const anyopaque,
    data_size: usize,
    init: ?InitFn,
    seg_list: ?*anyopaque,
) ?*Library {
    const sizes = _library.librarySizes(vectors.len, data_size) orelse return null;
    const sys = base.iface();
    const block = sys.AllocMem(sizes.neg + sizes.pos, sdk.exec.MEMF_ANY) orelse return null;
    const lib = _library.buildLibrary(@ptrCast(block), vectors, sizes);
    if (init) |init_routine| {
        return init_routine(lib, seg_list, sys) orelse {
            _library.freeLibraryMemory(base, lib);
            return null;
        };
    }
    return lib;
}
