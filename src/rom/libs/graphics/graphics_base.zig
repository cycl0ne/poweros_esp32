// SPDX-License-Identifier: MPL-2.0
//! graphics.library as a library: its base, and the Expunge vector that
//! keeps it in memory.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const RtgBase = sdk.interface.rtg.RtgBase;
const RtgBoard = sdk.rtg.RtgBoard;

/// The base: everything about the library that can change.
///
/// A library's memory is exec's, not the image's - `CreateLibrary`
/// allocates the jump table and this together, and the ROM it was built
/// from is read only - so nothing here may become a global. What a caller
/// holds a pointer to is the `lib` field; the SDK hands it out as the
/// opaque `sdk.interface.graphics.GraphicsBase`.
pub const GraphicsBase = extern struct {
    /// The Library header, at the base, with the jump table in front of it.
    lib: exec.Library,
    /// SysBase, to call exec through its jump table. Every call this
    /// library makes reaches exec through this and never through the
    /// kernel's own `exec.SysBase`.
    sys_base: *ExecBase,
    /// utility.library, opened by the init and kept: a RastPort is
    /// configured by tags, and the tag calls are utility's. A caller
    /// reaches them through this library and need open nothing itself.
    utility_base: *UtilityBase,
    /// rtg.library, opened by the init and kept: the buffers drawn into
    /// are its, and so is the engine a board offers. This is what keeps
    /// rtg off the caller's side of the fence.
    rtg_base: *RtgBase,
    /// Every font the library knows, the three in this ROM to begin with.
    /// A list rather than an array because something that loads one from a
    /// file will add to it, and `OpenFont` should not have to change when
    /// it does.
    fonts: exec.List,
    /// Held while `fonts` is walked or changed, and while a font's open
    /// count moves: RemFont reads that count and takes the font off in one
    /// step, so the two must not come apart.
    font_lock: exec.SignalSemaphore,
    /// The memory every region's rectangles come from. A region is a list
    /// of one-rectangle nodes and a cut makes up to four where there was
    /// one, so they are small, many, and taken and given back in bursts -
    /// which is what a pool is for. It is made at init and never deleted,
    /// because this library never expunges.
    region_pool: ?*anyopaque,
    /// The ROM fonts, copied into memory of the library's own at init:
    /// opening a font counts, and the image cannot be written.
    rom_fonts: ?*anyopaque,
    /// The View: the display drawn on when a caller names no buffer. It is
    /// the board and not its buffer, because a board's displayed buffer
    /// can be swapped, and it is the board as last resolved rather than
    /// one held onto, because a board can be deleted. Null until something
    /// asks, and null on a machine that has no display at all.
    view: ?*RtgBoard,

    /// This library as a caller sees it, to call its own functions through
    /// the jump table.
    ///
    /// INPUTS:
    /// - `gb` - the library's base.
    pub fn iface(gb: *GraphicsBase) *sdk.interface.graphics.GraphicsBase {
        return @ptrCast(gb);
    }
};

/// Expunges the library: a module in the ROM stays, so nothing is freed.
///
/// SYNOPSIS:
/// ```zig
/// pub fn expunge(lib: *exec.Library) callconv(.c) ?*anyopaque
/// ```
///
/// SINCE: 0.1. `LIB_EXPUNGE`, the third standard vector, LVO -12.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// Null, always. A non-null result is exec's way of handing back the
/// seglist of an expunged library that was loaded from a file, for the
/// caller to unload; one in the ROM has none.
///
/// BEHAVIOR:
/// It keeps the library, and exec reads that from the library still being
/// on its list when the vector returns.
///
/// The standard Expunge, `exec.libExpunge`, takes the library off exec's
/// list and frees its memory. For a module in the ROM that would be a
/// one-way trip: the image cannot be read in again, so the name would be
/// gone for the rest of the boot and the next `OpenLibrary` would fail
/// with nothing able to put it back. Every ROM library refuses for that
/// reason.
///
/// The open count is not consulted, because the answer does not turn on
/// it: an open library would be kept, and a closed one is kept too.
///
/// CONTEXT:
/// - Waits: no, and it must not. exec's `flushLibraries` reaches
///   it from inside AllocMem, where a low-memory handler runs under Forbid
///   and is forbidden to wait.
/// - Interrupts: safe. It takes nothing and touches nothing.
/// - Forbid: every caller holds it already - `RemLibrary` and
///   `CloseLibrary` take it around the vector, and the low-memory handler
///   runs inside it. It does not take Forbid itself.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated and nothing is freed. The base and its jump table
/// are exec's, from `CreateLibrary` at init, and they last until reboot.
///
/// NOTES:
/// - Three ways in: `RemLibrary`, the last `CloseLibrary` of a library
///   marked `LIBF_DELEXP`, and `flushLibraries` when memory runs out.
/// - `LIBF_DELEXP` is never set here. The standard Expunge sets it on a
///   library that is open so that the last close tries again; nothing here
///   ever goes, so a retry would only ask the same question twice.
/// - The declaration names the base `_`: it is the interface's parameter
///   and this implementation has no use for it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `exec.libExpunge`, `exec.libOpen`, `exec.libClose`, `exec.libExtFunc`,
/// exec's `flushLibraries`, `OpenLibrary`, `CloseLibrary`,
/// `RemLibrary`
///
/// EXAMPLES:
/// ```zig
/// // Nothing calls a library's Expunge itself - exec does, through the
/// // vector. What a program does is open the library and close it, and
/// // the close of a ROM library leaves it on the list for the next one.
/// const lib = sys.OpenLibrary(sdk.graphics.GRAPHICSNAME, 0) orelse {
///     // Version 0 demands nothing, so a failure here means the library
///     // is not on exec's list at all.
///     return dos.RETURN_FAIL;
/// };
/// defer sys.CloseLibrary(lib);
/// // The base a caller names is the SDK's opaque one, whose methods are
/// // the library's functions; `GraphicsBase` here is the library's own.
/// const gb: *interface.GraphicsBase = @ptrCast(lib);
/// ```
pub fn expunge(_: *exec.Library) callconv(.c) ?*anyopaque {
    return null;
}
