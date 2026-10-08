// SPDX-License-Identifier: MIT
//! AddPacketHook: a program's hook put in the chain that sees every packet
//! coming in, or going out, and decides what becomes of it.

const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const utility = sdk.utility;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("../socket/_socket.zig");
const _lock = @import("../lock/_lock.zig");
const _hook = @import("_hook.zig");
const PacketHook = _hook.PacketHook;

/// Puts `hook` in front of the stack: it is shown every packet coming in
/// (or going out) and answers what becomes of it.
///
/// SYNOPSIS:
/// ```zig
/// fn AddPacketHook(base: *SocketBase, hook: *Hook, tags: ?[*]const TagItem) i32
/// ```
///
/// SINCE: 1.4. LVO -216.
///
/// INPUTS:
/// - `hook` - a utility.library Hook. Its `h_Entry` is called with the
///   hook, a `*const PacketView` as the object and no message, and answers
///   `PACKET_PASS`, `PACKET_DROP` or `PACKET_REFUSE`.
/// - `tags` - `PH_Direction` (`PH_IN`, the default, or `PH_OUT`),
///   `PH_Priority` (-128..127, 0 when not given), `PH_Interface` (a name;
///   every interface when not given), `PH_Keep` (TRUE: the hook stays
///   when this base is closed).
///
/// RESULT:
/// 0; -1 with Errno() `ENOMEM` when there is no memory for it, `EINVAL`
/// for a hook already in a chain, a direction there is not, or an
/// interface name longer than IFNAMSIZ - 1.
///
/// BEHAVIOR:
/// Coming in, a TCP segment, a UDP datagram, or an ICMP or ICMPv6 message
/// is shown after its checksum is checked and the stack has looked up what
/// it is for (`belongs`), before it is delivered or answered. Going out,
/// it is shown before its IP header goes on. The hooks of a chain are
/// asked from the highest priority down, those of one priority in the
/// order they came; the first answer that is not `PACKET_PASS` decides,
/// and another answer counts as a pass. `PACKET_DROP` drops the packet
/// and says nothing. `PACKET_REFUSE` answers a TCP segment with a reset
/// and a UDP datagram with a port unreachable (ICMP's rate limit holds),
/// and drops anything else. Going out it is a drop: a datagram's send
/// fails with `EPERM`, and a TCP segment is lost as the network might lose
/// it, so a connection that cannot send times out. What was stopped is
/// counted in `NetCounts`
/// (`hook_dropped`, `hook_refused`), and a packet coming in is copied to
/// every capture socket marked `CAPTURE_FILTERED`.
///
/// Never shown: anything on a loopback interface, IGMP, ICMPv4's errors
/// (types 3, 11, 12), ICMPv6's errors (1-4), Neighbor Discovery and MLD,
/// and the messages of this machine's DHCP and DHCPv6 client - so that no
/// hook can cut an interface off.
///
/// CONTEXT:
/// - Waits: for the stack's lock.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// The hook itself runs under the stack's lock, on whichever task holds
/// it - the stack's for a packet coming in, the sender's for one going
/// out: it may not wait, call bsdsocket.library or touch a file, and
/// should be quick, since every packet waits for it.
///
/// OWNERSHIP:
/// `hook` stays the caller's and must stay where it is until
/// RemPacketHook, or until this base is closed, which takes it out too -
/// unless `PH_Keep` keeps it, and then only RemPacketHook does.
/// `tags` is read during the call only. The PacketView and the bytes it
/// points to are the stack's and valid only while the hook runs.
///
/// NOTES:
/// A firewall is a module of its own built on this: the stack names no
/// firewall and keeps no rules.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemPacketHook`, `sdk.bsdsocket.PacketView`, `GetNetworkStatistics`
///
/// EXAMPLES:
/// ```zig
/// fn noTelnet(_: *utility.Hook, object: ?*anyopaque, _: ?*anyopaque) callconv(.c) usize {
///     const view: *const bsd.PacketView = @ptrCast(@alignCast(object.?));
///     if (view.protocol == bsd.IPPROTO_TCP and view.destination_port == 23) return bsd.PACKET_REFUSE;
///     return bsd.PACKET_PASS;
/// }
/// var hook: utility.Hook = .{ .entry = &noTelnet };
/// _ = sb.AddPacketHook(&hook, &[_]utility.TagItem{ .{ .tag = bsd.PH_Interface, .data = @intFromPtr("wlan0") }, .{} });
/// ```
pub fn AddPacketHook(sb: *SocketBase, hook: *utility.Hook, tags: ?[*]const utility.TagItem) i32 {
    const sys = sb.sys_base;
    const stack = sb.stack;
    const ub = stack.utility.?;
    const direction: u32 = @truncate(ub.GetTagData(bsd.PH_Direction, bsd.PH_IN, tags));
    if (direction != bsd.PH_IN and direction != bsd.PH_OUT) return _socket.fail(sb, bsd.EINVAL, "AddPacketHook");
    const priority: i32 = @bitCast(@as(u32, @truncate(ub.GetTagData(bsd.PH_Priority, 0, tags))));
    const kept = ub.GetTagData(bsd.PH_Keep, 0, tags) != 0;
    var entry: PacketHook = .{ .hook = hook, .owner = if (kept) null else sb };
    entry.node.pri = @intCast(@max(-128, @min(127, priority)));
    if (ub.GetTagData(bsd.PH_Interface, 0, tags) != 0) {
        const name: [*:0]const u8 = @ptrFromInt(ub.GetTagData(bsd.PH_Interface, 0, tags));
        var length: usize = 0;
        while (name[length] != 0) : (length += 1) {
            if (length == entry.interface.len - 1) return _socket.fail(sb, bsd.EINVAL, "AddPacketHook");
            entry.interface[length] = name[length];
        }
    }
    const memory = sys.AllocVec(@sizeOf(PacketHook), exec.MEMF_CLEAR) orelse return _socket.fail(sb, bsd.ENOMEM, "AddPacketHook");
    const held = _lock.take(stack);
    defer _lock.give(stack, held);
    if (_hook.find(stack, hook) != null) {
        sys.FreeVec(memory);
        return _socket.fail(sb, bsd.EINVAL, "AddPacketHook");
    }
    const placed: *PacketHook = @ptrCast(@alignCast(memory));
    placed.* = entry;
    sys.Enqueue(_hook.chain(stack, direction), &placed.node);
    return 0;
}
