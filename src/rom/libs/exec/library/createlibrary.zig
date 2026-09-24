// SPDX-License-Identifier: MPL-2.0
//! CreateLibrary: `MakeLibrary` and `AddLibrary` in one step, from a
//! description. The name and ID string are copied into the library's own
//! memory, behind its data, so the description need not outlive the call.

const sdk = @import("sdk");
const _library = @import("_library.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Library = sdk.exec.Library;
const LibraryInit = sdk.exec.LibraryInit;

/// Makes a library from one description and adds it, name and all.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateLibrary(base: *ExecBase, desc: *const LibraryInit) ?*Library
/// ```
///
/// SINCE: 1.0. LVO -44.
///
/// INPUTS:
/// - `desc` - what the library is to be. `data_size` must be at least
///   `@sizeOf(Library)`; `vectors` is the library's whole jump table, the
///   four standard vectors first; `name` is required and `id_string` is
///   not; `init` is run before the library is added, and null to refuse.
///
/// RESULT:
/// The library base, already on the library list, or null: `data_size` was
/// too small, there was no memory, or `init` refused - in which case the
/// memory is freed before returning.
///
/// BEHAVIOR:
/// It is `MakeLibrary` and `AddLibrary` with one difference that matters:
/// the name and the ID string are **copied into the library's own
/// memory**, past the module's data. So the library is a single block, and
/// its Expunge frees the name with it - which is what lets a library be
/// created by code that then goes away, and what `MakeLibrary` alone
/// cannot offer.
///
/// The init routine runs while the library is still off the list, so
/// nothing can open it half-built; it is added only if the init agrees.
///
/// CONTEXT:
/// - Waits: no, unless `init` does.
/// - Interrupts: no. It allocates and takes Forbid.
/// - Forbid: not needed; `AddLibrary` takes it for the list.
/// - Process: a Task will do, unless `init` needs more.
///
/// OWNERSHIP:
/// The system holds it from here. It goes with `RemLibrary`, or on the last
/// `CloseLibrary` after something marked it.
///
/// NOTES:
/// A resource is made the same way and put on the resource list with
/// `AddResource` instead, which is why no shape of vector table is
/// required.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MakeLibrary`, `AddLibrary`, `AddResource`
///
/// EXAMPLES:
/// ```zig
/// const lib = sys.CreateLibrary(&.{
///     .name = "my.library",
///     .version = 1,
///     .data_size = @sizeOf(MyBase),
///     .vectors = &my_vectors,
///     .init = &myInit,
/// }) orelse return;
/// ```
pub fn CreateLibrary(base: *ExecBase, desc: *const LibraryInit) ?*Library {
    if (desc.data_size < @sizeOf(Library)) return null;
    const data = _library.alignUp(desc.data_size, @alignOf(Library));
    const id_len = if (desc.id_string) |id_string| id_string.len + 1 else 0;
    const vectors = desc.vectors;
    const sys = base.iface();
    const lib = sys.MakeLibrary(vectors.ptr, vectors.len, data + desc.name.len + 1 + id_len, null, null) orelse return null;

    const bytes: [*]u8 = @ptrCast(lib);
    lib.node.name = copyString(bytes + data, desc.name);
    if (desc.id_string) |id_string| lib.id_string = copyString(bytes + data + desc.name.len + 1, id_string);
    lib.node.pri = desc.pri;
    lib.version = desc.version;
    lib.revision = desc.revision;

    if (desc.init) |init_routine| {
        if (init_routine(lib, desc.seg_list, sys) == null) {
            _library.freeLibraryMemory(base, lib);
            return null;
        }
    }
    sys.AddLibrary(lib);
    return lib;
}

/// Copies a string into the library's own memory, NUL included.
///
/// INPUTS:
/// - `dest` - where it goes.
/// - `text` - what is copied.
///
/// RESULT:
/// Where it landed.
fn copyString(dest: [*]u8, text: [:0]const u8) [*:0]const u8 {
    @memcpy(dest[0..text.len], text);
    dest[text.len] = 0;
    return @ptrCast(dest);
}
