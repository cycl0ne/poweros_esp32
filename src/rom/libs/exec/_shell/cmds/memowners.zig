// SPDX-License-Identifier: MPL-2.0
//! memowners [<number>]: who holds the memory. Every region is walked and
//! its blocks summed by owner (`sdk.exec.memowners`): the system, each
//! task by its number and name, and the numbers of tasks that have ended -
//! what they left behind. With a number, that owner's blocks one by one.
//!
//! The walk is made with exec's memory list locked and the names are taken
//! under Disable; what is printed was copied out first.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "memowners";
pub const usage = "memowners [<number>]";
pub const help =
    \\  memowners [<number>] who holds the memory: the system, each task, the ended ones;
    \\                       with a task's number, its blocks
    \\
;

/// How many owners one look keeps apart; the rest are counted together.
const max_owners = 48;
/// How many of one owner's blocks are listed.
const max_blocks = 48;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    const sys = shell.base.iface();
    if (args.peek() != null) return blocksOf(shell, try args.number());

    var tally: sdk.exec.memowners.Tally(max_owners) = .{};
    tally.take(sys);
    tally.name(sys);
    tally.sort();
    shell.print("owner  task                      blocks       bytes     private\n", .{});
    for (tally.owners[0..tally.used]) |*owner| {
        if (owner.system()) {
            shell.print("system                          %6u  %10zu  %10zu\n", .{ owner.blocks, owner.bytes, owner.private_bytes });
            continue;
        }
        const task: [*:0]const u8 = if (owner.living) @ptrCast(&owner.name) else "(ended)";
        shell.print("%5u  %-24s  %6u  %10zu  %10zu\n", .{ owner.id, task, owner.blocks, owner.bytes, owner.private_bytes });
    }
    if (tally.rest_owners != 0) {
        shell.print("%5u  more owners               %6u  %10zu  %10zu\n", .{ tally.rest_owners, tally.rest.blocks, tally.rest.bytes, tally.rest.private_bytes });
    }
    shell.print("free   in %u chunks                       %10zu\n", .{ tally.free_chunks, tally.free_bytes });
    if (tally.damaged) |at| {
        shell.print("%u regions, %u blocks - damaged at 0x%08x, the rest of that region not counted\n", .{ tally.regions, tally.blocks, @as(u32, @truncate(at)) });
    } else {
        shell.print("%u regions, %u blocks, every one readable\n", .{ tally.regions, tally.blocks });
    }
}

/// One block of the owner asked about, copied out under the lock.
const Block = struct {
    address: usize,
    bytes: usize,
    private: bool,
};

/// The blocks of owner `id`, address and size, the first `max_blocks`.
fn blocksOf(shell: *Shell, id: u32) void {
    const sys = shell.base.iface();
    var blocks: [max_blocks]Block = undefined;
    var count: usize = 0;
    var more: u32 = 0;
    var bytes: usize = 0;
    const list = sys.LockExecList(sdk.exec.EXECLIST_MEMORY).?;
    var it = list.iterator();
    while (it.next()) |node| {
        const region: *const sdk.exec.MemHeader = @fieldParentPtr("node", node);
        var walk = sdk.exec.RegionWalk.init(region);
        while (walk.next()) |stretch| {
            if (stretch.free or stretch.owner != id) continue;
            bytes += stretch.bytes;
            if (count == blocks.len) {
                more += 1;
                continue;
            }
            blocks[count] = .{ .address = stretch.start + sdk.exec.MEM_BLOCKSIZE, .bytes = stretch.bytes - sdk.exec.MEM_BLOCKSIZE, .private = stretch.private };
            count += 1;
        }
    }
    sys.UnlockExecList(sdk.exec.EXECLIST_MEMORY);

    shell.print("block       size        private\n", .{});
    for (blocks[0..count]) |*block| {
        const private: [*:0]const u8 = if (block.private) "private" else "";
        shell.print("0x%08x  %10zu  %s\n", .{ @as(u32, @truncate(block.address)), block.bytes, private });
    }
    if (more != 0) shell.print("... and %u more\n", .{more});
    shell.print("%u blocks, %zu bytes with their MemBlocks\n", .{ @as(u32, @intCast(count)) + more, bytes });
}
