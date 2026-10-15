// SPDX-License-Identifier: MIT
//! Who holds the memory: every region on exec's memory list walked
//! (`RegionWalk`), its blocks summed by owner (`MemBlock.owner`), and the
//! owners named after the tasks there are. What `Avail OWNERS`, `Top`,
//! `MemMap` and the ROM debugger's `memowners` show.
//!
//! Two steps, each under its own lock, with nothing printed meanwhile:
//!
//! - `take` walks the regions with exec's memory list locked
//!   (`LockExecList(EXECLIST_MEMORY)`). That lock is a spinlock, so the
//!   walk waits for nothing and allocates nothing: the tally is the
//!   caller's, of a size fixed when it is declared, and an owner past it
//!   is counted in `rest`. Anything else that allocates waits for the
//!   walk, which is a few milliseconds for a few thousand blocks.
//! - `name` goes through the tasks under Disable, as `Top` copies them:
//!   what each core runs, then the ready and the waiting ones. An owner no
//!   task has any more is one that has ended - what it holds is what it
//!   left behind, or what a library allocated on its behalf and keeps.
//!
//! A task that ends between the two shows as ended; one that starts holds
//! nothing yet.

const memory = @import("memory.zig");
const exec = @import("exec.zig");
const ExecBase = @import("../../interface/exec.zig").ExecBase;
const Task = @import("tasks.zig").Task;

/// The longest task name kept; a longer one is cut.
pub const name_max = 23;

/// What one owner holds.
pub const Owner = struct {
    /// MEMOWNER_SYSTEM or a task's number.
    id: u32,
    blocks: u32 = 0,
    /// Bytes taken from the regions, the blocks' MemBlocks included.
    bytes: usize = 0,
    /// Of those, the ones in private blocks (MEMF_PRIVATE).
    private_bytes: usize = 0,
    /// A task with that number is there now (`name`).
    living: bool = false,
    /// Its name, cut to `name_max`; empty for the system and an ended task.
    name: [name_max:0]u8 = @splat(0),

    /// Whether it is the system's rather than a task's.
    pub fn system(owner: *const Owner) bool {
        return owner.id == memory.MEMOWNER_SYSTEM;
    }
};

/// The memory by owner, for up to `max_owners` owners.
pub fn Tally(comptime max_owners: usize) type {
    return struct {
        const Self = @This();

        owners: [max_owners]Owner = undefined,
        used: usize = 0,
        /// The owners there was no room for, together, and how many.
        rest: Owner = .{ .id = memory.MEMOWNER_SYSTEM },
        rest_owners: u32 = 0,
        /// Free space, and in how many chunks.
        free_bytes: usize = 0,
        free_chunks: u32 = 0,
        /// Blocks in all, and regions walked.
        blocks: u32 = 0,
        regions: u32 = 0,
        /// Where a region's walk met something it could not read, or null:
        /// a MemBlock written over. The rest of that region is not counted.
        damaged: ?usize = null,
        /// The owner the last block went to: blocks next to each other are
        /// mostly the same task's.
        last: usize = 0,

        /// Every region walked and its blocks summed by owner, under exec's
        /// memory list lock. Starts the tally afresh.
        pub fn take(tally: *Self, sys: *ExecBase) void {
            tally.* = .{};
            const list = sys.LockExecList(exec.EXECLIST_MEMORY).?;
            var it = list.iterator();
            while (it.next()) |node| {
                const region: *const memory.MemHeader = @fieldParentPtr("node", node);
                tally.regions += 1;
                var walk = memory.RegionWalk.init(region);
                while (walk.next()) |stretch| _ = tally.add(stretch);
                if (tally.damaged == null) tally.damaged = walk.damaged;
            }
            sys.UnlockExecList(exec.EXECLIST_MEMORY);
        }

        /// One stretch counted. The index in `owners` of the owner it went
        /// to, or null for free space and an owner there was no room for -
        /// for a program that walks itself and keeps more of each block
        /// than the sums (`MemMap` paints them). Until `sort`, an owner
        /// keeps its index.
        pub fn add(tally: *Self, stretch: memory.Stretch) ?usize {
            if (stretch.free) {
                tally.free_bytes += stretch.bytes;
                tally.free_chunks += 1;
                return null;
            }
            tally.blocks += 1;
            const owner = tally.find(stretch.owner) orelse &tally.rest;
            owner.blocks += 1;
            owner.bytes += stretch.bytes;
            if (stretch.private) owner.private_bytes += stretch.bytes;
            if (owner == &tally.rest) return null;
            return tally.last;
        }

        /// The owner with number `id`, made when it is new and there is
        /// room; null when there is none.
        fn find(tally: *Self, id: u32) ?*Owner {
            if (tally.last < tally.used and tally.owners[tally.last].id == id) return &tally.owners[tally.last];
            for (tally.owners[0..tally.used], 0..) |*owner, index| {
                if (owner.id != id) continue;
                tally.last = index;
                return owner;
            }
            if (tally.used == max_owners) {
                tally.rest_owners += 1;
                return null;
            }
            tally.owners[tally.used] = .{ .id = id };
            tally.last = tally.used;
            tally.used += 1;
            return &tally.owners[tally.last];
        }

        /// The owners named after the tasks there are now, under Disable.
        pub fn name(tally: *Self, sys: *ExecBase) void {
            sys.Disable();
            defer sys.Enable();
            var core: u32 = 0;
            while (sys.CoreTask(core)) |task| : (core += 1) tally.nameTask(task);
            for ([_]u32{ exec.EXECLIST_TASK_READY, exec.EXECLIST_TASK_WAIT }) |which| {
                const list = sys.LockExecList(which).?;
                var it = list.iterator();
                while (it.next()) |node| tally.nameTask(@fieldParentPtr("node", node));
                sys.UnlockExecList(which);
            }
        }

        fn nameTask(tally: *Self, task: *const Task) void {
            if (task.id == memory.MEMOWNER_SYSTEM) return;
            for (tally.owners[0..tally.used]) |*owner| {
                if (owner.id != task.id) continue;
                owner.living = true;
                const text = task.node.name orelse return;
                var length: usize = 0;
                while (length < name_max and text[length] != 0) : (length += 1) owner.name[length] = text[length];
                owner.name[length] = 0;
                return;
            }
        }

        /// The owners, the most memory first.
        pub fn sort(tally: *Self) void {
            var index: usize = 1;
            while (index < tally.used) : (index += 1) {
                const moving = tally.owners[index];
                var to = index;
                while (to > 0 and tally.owners[to - 1].bytes < moving.bytes) : (to -= 1) tally.owners[to] = tally.owners[to - 1];
                tally.owners[to] = moving;
            }
            tally.last = 0;
        }

        /// What the owner with number `id` holds, or null when it holds
        /// nothing.
        pub fn of(tally: *const Self, id: u32) ?*const Owner {
            for (tally.owners[0..tally.used]) |*owner| {
                if (owner.id == id) return owner;
            }
            return null;
        }
    };
}
