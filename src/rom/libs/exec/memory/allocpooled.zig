// SPDX-License-Identifier: MPL-2.0
//! AllocPooled: a block from a pool. It is cut from the first ordinary
//! puddle with room - newest first, the one most likely to have some - and
//! a new puddle is taken when none has. A request at or above the pool's
//! threshold gets a puddle of its own.

const sdk = @import("sdk");
const _memory = @import("_memory.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Pool = _memory.Pool;
const Puddle = _memory.Puddle;
const MEM_BLOCKSIZE = sdk.exec.MEM_BLOCKSIZE;

/// Takes a block of memory from a pool.
///
/// SYNOPSIS:
/// ```zig
/// fn AllocPooled(base: *ExecBase, pool_handle: ?*anyopaque,
///     byte_size: usize) ?*anyopaque
/// ```
///
/// SINCE: 1.0. LVO -456.
///
/// INPUTS:
/// - `pool` - what CreatePool answered, or null.
/// - `byte_size` - how many bytes.
///
/// RESULT:
/// The memory, or null: no pool, no bytes asked for, or the system had
/// none left to make a puddle from.
///
/// BEHAVIOR:
/// A request below the pool's threshold is cut from a puddle that has
/// room, or from a new one. At or above it the request gets a puddle to
/// itself, which goes back to the system when the block is freed. The
/// memory is cleared only if the pool was made with MEMF_CLEAR.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: no; it may allocate. - Forbid: taken here,
///   so one pool may be used from more than one task. - Process: a Task
///   will do.
///
/// OWNERSHIP:
/// The caller's until `FreePooled`, or until `DeletePool` takes the lot.
///
/// NOTES:
/// The size has to be remembered by the caller, since the block carries no
/// header saying it. Where that is inconvenient, `AllocVec` is the call
/// that remembers instead - at the cost of a block per allocation.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FreePooled`, `DeletePool`, `AllocVec`
pub fn AllocPooled(base: *ExecBase, pool_handle: ?*anyopaque, byte_size: usize) ?*anyopaque {
    const pool: *Pool = @ptrCast(@alignCast(pool_handle orelse return null));
    if (byte_size == 0) return null;
    const sys = base.iface();
    sys.Forbid();
    defer sys.Permit();

    const block = take(base, pool, byte_size) orelse return null;
    if (pool.clear) {
        const bytes: [*]u8 = @ptrCast(block);
        @memset(bytes[0.._memory.alignUp(byte_size, MEM_BLOCKSIZE)], 0);
    }
    return block;
}

/// The memory for one request, from a puddle that has room or from a new
/// one. Called with the scheduler held.
///
/// INPUTS:
/// - `base` - exec: the jump table `Allocate` goes through.
/// - `pool` - the pool.
/// - `byte_size` - what is wanted, not 0.
fn take(base: *ExecBase, pool: *Pool, byte_size: usize) ?*anyopaque {
    const sys = base.iface();
    if (byte_size >= pool.thresh_size) {
        const puddle = newPuddle(base, pool, byte_size, true) orelse return null;
        return sys.Allocate(puddle.header, byte_size);
    }

    var it = pool.puddles.iterator();
    while (it.next()) |node| {
        const puddle: *Puddle = @fieldParentPtr("node", node);
        // A puddle made for one block has no room for anything else, and
        // is meant to go back to the system whole.
        if (puddle.alone) continue;
        if (sys.Allocate(puddle.header, byte_size)) |block| return block;
    }

    const puddle = newPuddle(base, pool, byte_size, false) orelse return null;
    return sys.Allocate(puddle.header, byte_size);
}

/// Takes another stretch from the system and puts it at the head of the
/// pool's puddles.
///
/// INPUTS:
/// - `base` - exec: the jump table `AllocMem`, `CreateMemHeader` and
///   `AddHead` go through.
/// - `pool` - the pool.
/// - `need` - the bytes the puddle must have free.
/// - `alone` - whether it is made for one block, and sized for just that.
///
/// RESULT:
/// The puddle, or null if there is no memory.
fn newPuddle(base: *ExecBase, pool: *Pool, need: usize, alone: bool) ?*Puddle {
    const sum = @addWithOverflow(need, _memory.puddle_overhead);
    if (sum[1] != 0) return null;
    const wanted = sum[0];
    const bytes = if (alone) wanted else @max(pool.puddle_size, wanted);

    const sys = base.iface();
    const block = sys.AllocMem(bytes, pool.requirements) orelse return null;
    const header_at: *anyopaque = @ptrFromInt(@intFromPtr(block) + @sizeOf(Puddle));
    const mh = sys.CreateMemHeader(bytes - @sizeOf(Puddle), pool.requirements, 0, header_at, "pool puddle") orelse {
        sys.FreeMem(block, bytes);
        return null;
    };

    const puddle: *Puddle = @ptrCast(@alignCast(block));
    puddle.* = .{ .bytes = bytes, .header = mh, .alone = alone };
    sys.AddHead(&pool.puddles, &puddle.node);
    return puddle;
}
