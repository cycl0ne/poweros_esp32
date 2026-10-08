// SPDX-License-Identifier: MIT
//! A network unit's requests (sdk/devices/network.zig), apart from the
//! hardware that carries its frames: the openers and what each has
//! queued, which read a frame that came in goes to, the events, the
//! multicast groups, the tracked types and the counts. The hardware is
//! the `Link` it is made with, which it tells when to change the station
//! address, start or stop, change its receive filter, or look for writes
//! to send.
//!
//! **Who runs what.** Everything here runs on the device's task, except
//! `open`, `close`, `abort`, `query` and `stationAddress`, which run on the
//! caller's. The queues are therefore touched only under the unit's lock
//! (`lock`), a semaphore: nothing an interrupt does reaches them, and an
//! opener's packet filter runs inside it while a read is claimed. An
//! opener's copy calls run outside it: a request is taken off its queue
//! first, and copied into or out of afterwards. The opener stays until every request
//! of its own is answered - its CloseDevice comes after them - so its copy
//! calls are still there when one of its requests is being answered.
//!
//! **Where a frame goes.** To the first read of its type in each opener's
//! queue that the opener's filter accepts; if no opener has one, to the
//! first S2_READORPHAN of each opener that has one; else it is counted as
//! unknown. A frame sent to a group nobody here joined, which the
//! hardware's hash filter let through, is dropped unless the unit is
//! promiscuous.
//!
//! **Two framings** (`Framing`): Ethernet's, a header with two addresses
//! and a type before the packet; or a point-to-point line's - SLIP - where
//! a frame is the packet alone, its type read from its version (IPv4,
//! IPv6), and the link has no addresses at all.

const exec = @import("../../libs/exec/exec.zig");
const net = @import("../network.zig");
const TimeVal = @import("../timer.zig").TimeVal;
const ExecBase = @import("../../interface/exec.zig").ExecBase;
const UtilityBase = @import("../../interface/utility.zig").UtilityBase;
const TagItem = @import("../../libs/utility/tagitem.zig").TagItem;
const Hook = @import("../../libs/utility/hooks.zig").Hook;
const ethernet = @import("ethernet.zig");

/// What a link's frames are: Ethernet's, or a point-to-point line's bare
/// packets. A Link says `pub const framing = .point_to_point`, with its
/// `wire_type` (S2WireType_*) and `mtu`, for the second; Ethernet is what
/// it is without.
pub const Framing = enum { ethernet, point_to_point };

/// The packet types a point-to-point frame's version gives.
pub const type_ipv4: u32 = 0x0800;
pub const type_ipv6: u32 = 0x86DD;

/// How many packet types S2_TRACKTYPE can count at once, and how many
/// multicast groups the unit can join.
pub const tracked_max = 8;
pub const groups_max = 16;

/// An opener's record, which its requests carry in ios2_BufferManagement
/// from OpenDevice on.
pub const Opener = extern struct {
    /// In the unit's list of openers.
    node: exec.Node = .{},
    /// Its S2_CopyToBuff and S2_CopyFromBuff.
    copy_to: ?net.CopyFn = null,
    copy_from: ?net.CopyFn = null,
    /// Its S2_PacketFilter, if it gave one.
    filter: ?*Hook = null,
    /// Its CMD_READs, S2_READORPHANs and S2_ONEVENTs, oldest first.
    reads: exec.List = .{},
    orphans: exec.List = .{},
    events: exec.List = .{},
    /// OpenDevice's flags: SANA2OPF_*.
    flags: u32 = 0,
};

/// A packet type S2_TRACKTYPE counts.
pub const Tracked = extern struct {
    packet_type: u32 = 0,
    used: u32 = 0,
    stats: net.Sana2PacketTypeStats = .{},
};

/// A multicast group the unit has joined, and how often: an address added
/// twice needs deleting twice.
pub const Group = extern struct {
    address: ethernet.Address = @splat(0),
    pad: [2]u8 = .{ 0, 0 },
    users: u32 = 0,
};

/// Every event S2_ONEVENT may wait for.
const events_all: u32 = net.S2EVENT_ERROR | net.S2EVENT_TX | net.S2EVENT_RX |
    net.S2EVENT_ONLINE | net.S2EVENT_OFFLINE | net.S2EVENT_BUFF |
    net.S2EVENT_HARDWARE | net.S2EVENT_SOFTWARE;

/// The request a queue's node belongs to.
pub fn requestOf(node: *exec.Node) *net.IOSana2Req {
    const message: *exec.Message = @fieldParentPtr("node", node);
    const io: *exec.IORequest = @fieldParentPtr("message", message);
    return @alignCast(@fieldParentPtr("req", io));
}

fn nodeOf(req: *net.IOSana2Req) *exec.Node {
    return &req.req.message.node;
}

/// The opener a request came from.
pub fn openerOf(req: *net.IOSana2Req) ?*Opener {
    return @ptrCast(@alignCast(req.buffer_management));
}

fn fail(req: *net.IOSana2Req, err: i8, wire_error: u32) void {
    req.req.err = err;
    req.wire_error = wire_error;
}

/// A unit on `Link`, which provides:
///
///   bps: u64                       the link's speed
///   setStation(link, *Address)     the address the hardware answers to
///   setRunning(link, bool)         frames in and out, or neither
///   setFilter(link, []Group, bool) the groups to take, and whether all
///   startWrites(link)              send what `nextWrite` hands out
///   now(link) TimeVal              the system time
///
/// **Online** is two things at once: the unit is wanted on line
/// (configured, and not taken off line by S2_OFFLINE), and the link has a
/// carrier. A link that is always there never says otherwise; one that
/// comes and goes - a radio joining and leaving its network - tells the
/// unit with `setCarrier`, and the unit goes on and off line with it,
/// with the events S2_ONEVENT waits for.
pub fn Unit(comptime Link: type) type {
    return extern struct {
        const Self = @This();
        const framing: Framing = if (@hasDecl(Link, "framing")) Link.framing else .ethernet;
        const point = framing == .point_to_point;
        /// The most bytes of one packet, and of one frame on the link.
        const mtu: u32 = if (point) Link.mtu else ethernet.mtu;
        const frame_max: u32 = if (point) Link.mtu else ethernet.frame_max;
        /// What stands in front of the packet in a frame.
        const header_bytes: u32 = if (point) 0 else ethernet.header_bytes;

        sys: *ExecBase,
        link: *Link,
        /// The openers and every queue below: see the file's header.
        lock: exec.SignalSemaphore = .{},
        /// The openers' records.
        openers: exec.List = .{},
        /// The writes waiting for the hardware, oldest first.
        writes: exec.List = .{},
        /// The address the unit runs with, and the hardware's own.
        station: ethernet.Address = @splat(0),
        factory: ethernet.Address = @splat(0),
        configured: u8 = 0,
        online: u8 = 0,
        /// An opener has the unit alone (SANA2OPF_MINE).
        exclusive: u8 = 0,
        /// Wanted on line, and whether the link has a carrier.
        wanted: u8 = 0,
        carrier: u8 = 1,
        pad: [3]u8 = @splat(0),
        /// The openers that asked for every frame (SANA2OPF_PROM).
        promiscuous: u32 = 0,
        stats: net.Sana2DeviceStats = .{},
        tracked: [tracked_max]Tracked = @splat(.{}),
        groups: [groups_max]Group = @splat(.{}),

        /// A unit that is neither configured nor online, in place: its
        /// lists point into it.
        pub fn init(unit: *Self, sys: *ExecBase, link: *Link, factory: *const ethernet.Address) void {
            unit.* = .{ .sys = sys, .link = link, .station = factory.*, .factory = factory.* };
            sys.InitSemaphore(&unit.lock);
            unit.openers.init(.unknown);
            unit.writes.init(.message);
        }

        // --- opening and closing ------------------------------------------

        /// OpenDevice's part, inside the device's lock: a record for the opener,
        /// made from the tag list in ios2_BufferManagement, which the
        /// record then replaces. 0 or the error OpenDevice answers.
        pub fn open(unit: *Self, req: *net.IOSana2Req, flags: u32, utility: *UtilityBase) i8 {
            const sys = unit.sys;
            const alone = flags & net.SANA2OPF_MINE != 0;
            if (!unit.openers.isEmpty() and (alone or unit.exclusive != 0)) return exec.IOERR_UNITBUSY;
            const tags: ?[*]const TagItem = @ptrCast(@alignCast(req.buffer_management));
            const copy_to = utility.GetTagData(net.S2_CopyToBuff, 0, tags);
            const copy_from = utility.GetTagData(net.S2_CopyFromBuff, 0, tags);
            if (copy_to == 0 or copy_from == 0) return exec.IOERR_OPENFAIL;
            const filter = utility.GetTagData(net.S2_PacketFilter, 0, tags);
            const memory = sys.AllocVec(@sizeOf(Opener), exec.MEMF_CLEAR) orelse return exec.IOERR_OPENFAIL;
            const opener: *Opener = @ptrCast(@alignCast(memory));
            opener.* = .{
                .copy_to = @ptrFromInt(copy_to),
                .copy_from = @ptrFromInt(copy_from),
                .filter = @ptrFromInt(filter),
                .flags = flags,
            };
            opener.reads.init(.message);
            opener.orphans.init(.message);
            opener.events.init(.message);
            // The device's task walks the openers as a frame comes in.
            sys.ObtainSemaphore(&unit.lock);
            sys.AddTail(&unit.openers, &opener.node);
            sys.ReleaseSemaphore(&unit.lock);
            if (alone) unit.exclusive = 1;
            if (flags & net.SANA2OPF_PROM != 0) {
                unit.promiscuous += 1;
                unit.refilter();
            }
            req.buffer_management = opener;
            return 0;
        }

        /// CloseDevice's part: whatever the opener still has queued is
        /// answered as aborted, and its record goes.
        pub fn close(unit: *Self, req: *net.IOSana2Req) void {
            const opener = openerOf(req) orelse return;
            unit.flush(opener);
            const sys = unit.sys;
            sys.ObtainSemaphore(&unit.lock);
            sys.Remove(&opener.node);
            sys.ReleaseSemaphore(&unit.lock);
            if (opener.flags & net.SANA2OPF_MINE != 0) unit.exclusive = 0;
            if (opener.flags & net.SANA2OPF_PROM != 0) {
                unit.promiscuous -= 1;
                unit.refilter();
            }
            sys.FreeVec(opener);
            req.buffer_management = null;
        }

        /// AbortIO's part: true if `req` was waiting in one of the unit's
        /// queues, and is now answered as aborted.
        pub fn abort(unit: *Self, req: *net.IOSana2Req) bool {
            const sys = unit.sys;
            const opener = openerOf(req) orelse return false;
            const node = nodeOf(req);
            sys.ObtainSemaphore(&unit.lock);
            const found = holds(&opener.reads, node) or holds(&opener.orphans, node) or
                holds(&opener.events, node) or holds(&unit.writes, node);
            if (found) sys.Remove(node);
            sys.ReleaseSemaphore(&unit.lock);
            if (!found) return false;
            req.req.err = exec.IOERR_ABORTED;
            sys.ReplyIO(&req.req);
            return true;
        }

        fn holds(list: *exec.List, wanted: *exec.Node) bool {
            var it = list.iterator();
            while (it.next()) |node| {
                if (node == wanted) return true;
            }
            return false;
        }

        // --- the requests -------------------------------------------------

        /// A request, on the device's task. One that waits - a read, a
        /// write, an event - is queued; every other one is answered.
        pub fn perform(unit: *Self, req: *net.IOSana2Req) void {
            const io = &req.req;
            switch (io.command) {
                exec.CMD_READ => return unit.queueRead(req, false),
                net.S2_READORPHAN => return unit.queueRead(req, true),
                exec.CMD_WRITE, net.S2_BROADCAST, net.S2_MULTICAST => return unit.queueWrite(req),
                net.S2_ONEVENT => return unit.queueEvent(req),
                exec.CMD_FLUSH => if (openerOf(req)) |opener| unit.flush(opener),
                net.S2_DEVICEQUERY => unit.query(req),
                net.S2_GETSTATIONADDRESS => unit.stationAddress(req),
                net.S2_CONFIGINTERFACE => unit.configure(req),
                net.S2_ONLINE => {
                    if (unit.configured == 0) {
                        fail(req, net.S2ERR_BAD_STATE, net.S2WERR_NOT_CONFIGURED);
                    } else if (unit.wanted != 0) {
                        fail(req, net.S2ERR_BAD_STATE, net.S2WERR_UNIT_ONLINE);
                    } else {
                        unit.wanted = 1;
                        if (unit.carrier != 0) unit.goOnline();
                    }
                },
                net.S2_OFFLINE => {
                    if (unit.wanted == 0) {
                        fail(req, net.S2ERR_BAD_STATE, net.S2WERR_UNIT_OFFLINE);
                    } else {
                        unit.wanted = 0;
                        if (unit.online != 0) unit.goOffline();
                    }
                },
                net.S2_ADDMULTICASTADDRESS => unit.join(req),
                net.S2_DELMULTICASTADDRESS => unit.leave(req),
                net.S2_TRACKTYPE => unit.track(req),
                net.S2_UNTRACKTYPE => unit.untrack(req),
                net.S2_GETTYPESTATS => unit.typeStats(req),
                net.S2_GETSPECIALSTATS => {
                    const header: *net.Sana2SpecialStatHeader = @ptrCast(@alignCast(req.stat_data orelse
                        return unit.answer(req, net.S2ERR_BAD_ARGUMENT, net.S2WERR_NULL_POINTER)));
                    // The hardware counts nothing past the global counts.
                    header.record_count_supplied = 0;
                },
                net.S2_GETGLOBALSTATS => {
                    const into: *net.Sana2DeviceStats = @ptrCast(@alignCast(req.stat_data orelse
                        return unit.answer(req, net.S2ERR_BAD_ARGUMENT, net.S2WERR_NULL_POINTER)));
                    into.* = unit.stats;
                },
                else => io.err = exec.IOERR_NOCMD,
            }
            unit.sys.ReplyIO(io);
        }

        /// `req` answered with an error.
        fn answer(unit: *Self, req: *net.IOSana2Req, err: i8, wire_error: u32) void {
            fail(req, err, wire_error);
            unit.sys.ReplyIO(&req.req);
        }

        /// Why a unit that is not online refuses a read or a write.
        fn offlineError(unit: *Self) u32 {
            return if (unit.configured == 0) net.S2WERR_NOT_CONFIGURED else net.S2WERR_UNIT_OFFLINE;
        }

        fn queueRead(unit: *Self, req: *net.IOSana2Req, orphan: bool) void {
            if (unit.online == 0) return unit.answer(req, net.S2ERR_OUTOFSERVICE, unit.offlineError());
            const opener = openerOf(req) orelse return unit.answer(req, net.S2ERR_BAD_ARGUMENT, net.S2WERR_BUFF_ERROR);
            const sys = unit.sys;
            sys.ObtainSemaphore(&unit.lock);
            sys.AddTail(if (orphan) &opener.orphans else &opener.reads, nodeOf(req));
            sys.ReleaseSemaphore(&unit.lock);
        }

        fn queueWrite(unit: *Self, req: *net.IOSana2Req) void {
            if (unit.online == 0) return unit.answer(req, net.S2ERR_OUTOFSERVICE, unit.offlineError());
            if (openerOf(req) == null) return unit.answer(req, net.S2ERR_BAD_ARGUMENT, net.S2WERR_BUFF_ERROR);
            if (req.req.flags & net.SANA2IOF_RAW != 0) {
                if (req.data_length < @max(header_bytes, 1) or req.data_length > frame_max) {
                    return unit.answer(req, net.S2ERR_MTU_EXCEEDED, net.S2WERR_GENERIC_ERROR);
                }
            } else {
                if (req.data_length > mtu) return unit.answer(req, net.S2ERR_MTU_EXCEEDED, net.S2WERR_GENERIC_ERROR);
                // A line between two ends sends every packet to the other.
                if (!point and req.req.command == net.S2_MULTICAST and !ethernet.isGroup(req.dst_addr[0..ethernet.address_bytes])) {
                    return unit.answer(req, net.S2ERR_BAD_ADDRESS, net.S2WERR_BAD_MULTICAST);
                }
            }
            const sys = unit.sys;
            sys.ObtainSemaphore(&unit.lock);
            sys.AddTail(&unit.writes, nodeOf(req));
            sys.ReleaseSemaphore(&unit.lock);
            Link.startWrites(unit.link);
        }

        fn queueEvent(unit: *Self, req: *net.IOSana2Req) void {
            const wanted = req.wire_error;
            if (wanted == 0 or wanted & ~events_all != 0) return unit.answer(req, net.S2ERR_BAD_ARGUMENT, net.S2WERR_BAD_EVENT);
            const opener = openerOf(req) orelse return unit.answer(req, net.S2ERR_BAD_ARGUMENT, net.S2WERR_BUFF_ERROR);
            // A state that already holds is answered at once.
            const holding: u32 = if (unit.online != 0) net.S2EVENT_ONLINE else net.S2EVENT_OFFLINE;
            if (wanted & holding != 0) {
                req.wire_error = holding;
                return unit.sys.ReplyIO(&req.req);
            }
            const sys = unit.sys;
            sys.ObtainSemaphore(&unit.lock);
            sys.AddTail(&opener.events, nodeOf(req));
            sys.ReleaseSemaphore(&unit.lock);
        }

        /// Everything `opener` has queued, answered as aborted.
        pub fn flush(unit: *Self, opener: *Opener) void {
            const sys = unit.sys;
            var taken: exec.List = .{};
            taken.init(.message);
            sys.ObtainSemaphore(&unit.lock);
            moveAll(sys, &opener.reads, &taken);
            moveAll(sys, &opener.orphans, &taken);
            moveAll(sys, &opener.events, &taken);
            var it = unit.writes.iterator();
            while (it.next()) |node| {
                if (openerOf(requestOf(node)) != opener) continue;
                sys.Remove(node);
                sys.AddTail(&taken, node);
            }
            sys.ReleaseSemaphore(&unit.lock);
            unit.answerAll(&taken, exec.IOERR_ABORTED, 0);
        }

        fn moveAll(sys: *ExecBase, from: *exec.List, into: *exec.List) void {
            while (sys.RemHead(from)) |node| sys.AddTail(into, node);
        }

        /// Every request in `list`, which is the caller's own, answered.
        fn answerAll(unit: *Self, list: *exec.List, err: i8, wire_error: u32) void {
            while (unit.sys.RemHead(list)) |node| unit.answer(requestOf(node), err, wire_error);
        }

        // --- what the unit is ---------------------------------------------

        /// S2_DEVICEQUERY, as much of it as the caller has room for.
        pub fn query(unit: *Self, req: *net.IOSana2Req) void {
            _ = unit;
            const into: *net.Sana2DeviceQuery = @ptrCast(@alignCast(req.stat_data orelse
                return fail(req, net.S2ERR_BAD_ARGUMENT, net.S2WERR_NULL_POINTER)));
            const room = into.size_available;
            if (room < 2 * @sizeOf(u32)) return fail(req, net.S2ERR_BAD_ARGUMENT, net.S2WERR_BAD_STATDATA);
            const supplied: u32 = @min(room, @as(u32, @sizeOf(net.Sana2DeviceQuery)));
            const full: net.Sana2DeviceQuery = .{
                .size_available = room,
                .size_supplied = supplied,
                .addr_field_size = if (point) 0 else ethernet.address_bits,
                .mtu = mtu,
                .bps = Link.bps,
                .hardware_type = if (point) Link.wire_type else net.S2WireType_Ethernet,
                .raw_mtu = frame_max,
            };
            const from: [*]const u8 = @ptrCast(&full);
            const to: [*]u8 = @ptrCast(into);
            @memcpy(to[0..supplied], from[0..supplied]);
        }

        /// S2_GETSTATIONADDRESS: the address the unit runs with, and the
        /// hardware's own.
        pub fn stationAddress(unit: *Self, req: *net.IOSana2Req) void {
            req.src_addr = @splat(0);
            req.dst_addr = @splat(0);
            req.src_addr[0..ethernet.address_bytes].* = unit.station;
            req.dst_addr[0..ethernet.address_bytes].* = unit.factory;
        }

        fn configure(unit: *Self, req: *net.IOSana2Req) void {
            if (unit.configured != 0) return fail(req, net.S2ERR_BAD_STATE, net.S2WERR_IS_CONFIGURED);
            const address = req.src_addr[0..ethernet.address_bytes];
            if (ethernet.isGroup(address)) return fail(req, net.S2ERR_BAD_ADDRESS, net.S2WERR_SRC_ADDRESS);
            unit.station = address.*;
            Link.setStation(unit.link, &unit.station);
            unit.configured = 1;
            unit.wanted = 1;
            if (unit.carrier != 0) unit.goOnline();
        }

        /// The link's carrier came or went: the unit goes on line with it
        /// if it is wanted there, and off line without it.
        pub fn setCarrier(unit: *Self, up: bool) void {
            unit.carrier = @intFromBool(up);
            if (up and unit.wanted != 0 and unit.online == 0) unit.goOnline();
            if (!up and unit.online != 0) unit.goOffline();
        }

        fn goOnline(unit: *Self) void {
            Link.setRunning(unit.link, true);
            unit.online = 1;
            unit.stats.last_start = Link.now(unit.link);
            unit.event(net.S2EVENT_ONLINE);
        }

        /// Off the link: every read and write still waiting is answered.
        fn goOffline(unit: *Self) void {
            Link.setRunning(unit.link, false);
            unit.online = 0;
            const sys = unit.sys;
            var taken: exec.List = .{};
            taken.init(.message);
            sys.ObtainSemaphore(&unit.lock);
            var it = unit.openers.iterator();
            while (it.next()) |node| {
                const opener: *Opener = @fieldParentPtr("node", node);
                moveAll(sys, &opener.reads, &taken);
                moveAll(sys, &opener.orphans, &taken);
            }
            moveAll(sys, &unit.writes, &taken);
            sys.ReleaseSemaphore(&unit.lock);
            unit.answerAll(&taken, net.S2ERR_OUTOFSERVICE, net.S2WERR_UNIT_OFFLINE);
            unit.event(net.S2EVENT_OFFLINE);
        }

        /// Every S2_ONEVENT waiting for one of `happened`, answered with
        /// the ones it waited for.
        pub fn event(unit: *Self, happened: u32) void {
            const sys = unit.sys;
            var taken: exec.List = .{};
            taken.init(.message);
            sys.ObtainSemaphore(&unit.lock);
            var openers = unit.openers.iterator();
            while (openers.next()) |opener_node| {
                const opener: *Opener = @fieldParentPtr("node", opener_node);
                var it = opener.events.iterator();
                while (it.next()) |node| {
                    if (requestOf(node).wire_error & happened == 0) continue;
                    sys.Remove(node);
                    sys.AddTail(&taken, node);
                }
            }
            sys.ReleaseSemaphore(&unit.lock);
            while (sys.RemHead(&taken)) |node| {
                const req = requestOf(node);
                req.wire_error &= happened;
                sys.ReplyIO(&req.req);
            }
        }

        // --- groups and tracked types ---------------------------------------

        fn groupAddress(req: *net.IOSana2Req) ?*const ethernet.Address {
            const address = req.src_addr[0..ethernet.address_bytes];
            if (!ethernet.isGroup(address) or ethernet.isBroadcast(address)) return null;
            return address;
        }

        fn findGroup(unit: *Self, address: *const ethernet.Address) ?*Group {
            for (&unit.groups) |*group| {
                if (group.users != 0 and sameAddress(&group.address, address)) return group;
            }
            return null;
        }

        fn join(unit: *Self, req: *net.IOSana2Req) void {
            const address = groupAddress(req) orelse return fail(req, net.S2ERR_BAD_ADDRESS, net.S2WERR_BAD_MULTICAST);
            if (unit.findGroup(address)) |group| {
                group.users += 1;
                return;
            }
            for (&unit.groups) |*group| {
                if (group.users != 0) continue;
                group.* = .{ .address = address.*, .users = 1 };
                return unit.refilter();
            }
            fail(req, net.S2ERR_NO_RESOURCES, net.S2WERR_MULTICAST_FULL);
        }

        fn leave(unit: *Self, req: *net.IOSana2Req) void {
            const address = groupAddress(req) orelse return fail(req, net.S2ERR_BAD_ADDRESS, net.S2WERR_BAD_MULTICAST);
            const group = unit.findGroup(address) orelse return fail(req, net.S2ERR_BAD_STATE, net.S2WERR_BAD_MULTICAST);
            group.users -= 1;
            if (group.users == 0) unit.refilter();
        }

        fn refilter(unit: *Self) void {
            Link.setFilter(unit.link, &unit.groups, unit.promiscuous != 0);
        }

        fn findTracked(unit: *Self, packet_type: u32) ?*Tracked {
            for (&unit.tracked) |*tracked| {
                if (tracked.used != 0 and tracked.packet_type == packet_type) return tracked;
            }
            return null;
        }

        fn track(unit: *Self, req: *net.IOSana2Req) void {
            if (unit.findTracked(req.packet_type) != null) return fail(req, net.S2ERR_BAD_STATE, net.S2WERR_ALREADY_TRACKED);
            for (&unit.tracked) |*tracked| {
                if (tracked.used != 0) continue;
                tracked.* = .{ .packet_type = req.packet_type, .used = 1 };
                return;
            }
            fail(req, net.S2ERR_NO_RESOURCES, net.S2WERR_GENERIC_ERROR);
        }

        fn untrack(unit: *Self, req: *net.IOSana2Req) void {
            const tracked = unit.findTracked(req.packet_type) orelse return fail(req, net.S2ERR_BAD_STATE, net.S2WERR_NOT_TRACKED);
            tracked.used = 0;
        }

        fn typeStats(unit: *Self, req: *net.IOSana2Req) void {
            const tracked = unit.findTracked(req.packet_type) orelse return fail(req, net.S2ERR_BAD_STATE, net.S2WERR_NOT_TRACKED);
            const into: *net.Sana2PacketTypeStats = @ptrCast(@alignCast(req.stat_data orelse
                return fail(req, net.S2ERR_BAD_ARGUMENT, net.S2WERR_NULL_POINTER)));
            into.* = tracked.stats;
        }

        // --- frames in ------------------------------------------------------

        /// A frame the hardware received, without its checksum: handed to
        /// the reads that want it.
        pub fn receive(unit: *Self, frame: []const u8) void {
            if (point) {
                if (frame.len == 0 or frame.len > frame_max) return unit.damaged();
                const packet_type: u32 = switch (frame[0] >> 4) {
                    4 => type_ipv4,
                    6 => type_ipv6,
                    else => return unit.damaged(),
                };
                return unit.deliver(frame, packet_type, null, 0);
            }
            const header = ethernet.parse(frame) orelse return unit.damaged();
            if (frame.len > ethernet.frame_max) return unit.damaged();
            var flags: u8 = 0;
            if (ethernet.isBroadcast(&header.dst)) {
                flags = net.SANA2IOF_BCAST;
            } else if (ethernet.isGroup(&header.dst)) {
                if (unit.promiscuous == 0 and unit.findGroup(&header.dst) == null) return;
                flags = net.SANA2IOF_MCAST;
            }
            unit.deliver(frame, header.type, &header, flags);
        }

        /// A frame of `packet_type` - behind `header` on Ethernet - to the
        /// first read of its type of each opener, or to the orphan reads.
        fn deliver(unit: *Self, frame: []const u8, packet_type: u32, header: ?*const ethernet.Header, flags: u8) void {
            unit.stats.packets_received += 1;
            const sys = unit.sys;
            var taken: exec.List = .{};
            taken.init(.message);
            var orphan = false;
            sys.ObtainSemaphore(&unit.lock);
            var it = unit.openers.iterator();
            while (it.next()) |node| {
                const opener: *Opener = @fieldParentPtr("node", node);
                const req = claimRead(sys, opener, packet_type, frame) orelse continue;
                sys.AddTail(&taken, nodeOf(req));
            }
            if (taken.isEmpty()) {
                orphan = true;
                it = unit.openers.iterator();
                while (it.next()) |node| {
                    const opener: *Opener = @fieldParentPtr("node", node);
                    if (sys.RemHead(&opener.orphans)) |read| sys.AddTail(&taken, read);
                }
            }
            sys.ReleaseSemaphore(&unit.lock);
            if (unit.findTracked(packet_type)) |tracked| {
                if (orphan) {
                    tracked.stats.packets_dropped += 1;
                } else {
                    tracked.stats.packets_received += 1;
                    tracked.stats.bytes_received += frame.len - header_bytes;
                }
            }
            if (taken.isEmpty()) {
                unit.stats.unknown_types_received += 1;
                return;
            }
            while (sys.RemHead(&taken)) |node| unit.answerRead(requestOf(node), frame, packet_type, header, flags);
        }

        /// A frame too short or too long to be one, or one the hardware
        /// found damaged.
        pub fn damaged(unit: *Self) void {
            unit.stats.bad_data += 1;
            unit.event(net.S2EVENT_RX | net.S2EVENT_ERROR);
        }

        /// A frame the hardware had no room for.
        pub fn overrun(unit: *Self) void {
            unit.stats.overruns += 1;
            unit.event(net.S2EVENT_BUFF | net.S2EVENT_ERROR);
        }

        /// The first of `opener`'s reads of `packet_type` its filter
        /// accepts, taken off its queue. Under the unit's lock.
        fn claimRead(sys: *ExecBase, opener: *Opener, packet_type: u32, frame: []const u8) ?*net.IOSana2Req {
            var it = opener.reads.iterator();
            while (it.next()) |node| {
                const req = requestOf(node);
                if (req.packet_type != packet_type) continue;
                if (opener.filter) |filter| {
                    const entry = filter.entry orelse continue;
                    if (entry(filter, req, @ptrCast(@constCast(frame.ptr))) == 0) continue;
                }
                sys.Remove(node);
                return req;
            }
            return null;
        }

        fn answerRead(unit: *Self, req: *net.IOSana2Req, frame: []const u8, packet_type: u32, header: ?*const ethernet.Header, flags: u8) void {
            const data = if (req.req.flags & net.SANA2IOF_RAW != 0) frame else frame[header_bytes..];
            req.data_length = @intCast(data.len);
            req.packet_type = packet_type;
            req.src_addr = @splat(0);
            req.dst_addr = @splat(0);
            if (header) |ether| {
                req.src_addr[0..ethernet.address_bytes].* = ether.src;
                req.dst_addr[0..ethernet.address_bytes].* = ether.dst;
            }
            req.req.flags = (req.req.flags & ~(net.SANA2IOF_BCAST | net.SANA2IOF_MCAST)) | flags;
            const opener = openerOf(req).?;
            if (!opener.copy_to.?(req.data, data.ptr, req.data_length)) {
                fail(req, net.S2ERR_NO_RESOURCES, net.S2WERR_BUFF_ERROR);
                unit.event(net.S2EVENT_BUFF);
            }
            unit.sys.ReplyIO(&req.req);
        }

        // --- frames out -----------------------------------------------------

        /// The oldest write waiting, taken off the queue for the link to
        /// send; null if there is none.
        pub fn nextWrite(unit: *Self) ?*net.IOSana2Req {
            const sys = unit.sys;
            sys.ObtainSemaphore(&unit.lock);
            defer sys.ReleaseSemaphore(&unit.lock);
            const node = sys.RemHead(&unit.writes) orelse return null;
            return requestOf(node);
        }

        /// `req`'s frame, built into `into` (the link's largest frame):
        /// its length, or 0 if the opener's copy call failed, in which case
        /// the request has been answered. A point-to-point frame is the
        /// packet as it is.
        pub fn buildFrame(unit: *Self, req: *net.IOSana2Req, into: []u8) u32 {
            const opener = openerOf(req).?;
            const copy = opener.copy_from.?;
            var length = req.data_length;
            var ok: bool = undefined;
            if (point or req.req.flags & net.SANA2IOF_RAW != 0) {
                ok = copy(into.ptr, req.data, length);
            } else {
                const dst: *const ethernet.Address = if (req.req.command == net.S2_BROADCAST)
                    &ethernet.broadcast
                else
                    req.dst_addr[0..ethernet.address_bytes];
                ethernet.write(into, dst, &unit.station, @truncate(req.packet_type));
                ok = copy(into[ethernet.header_bytes..].ptr, req.data, length);
                length += ethernet.header_bytes;
            }
            if (ok) return length;
            unit.answer(req, net.S2ERR_NO_RESOURCES, net.S2WERR_BUFF_ERROR);
            unit.event(net.S2EVENT_BUFF);
            return 0;
        }

        /// A write the link has sent, or could not: counted and answered.
        pub fn written(unit: *Self, req: *net.IOSana2Req, sent: bool) void {
            if (!sent) {
                unit.answer(req, net.S2ERR_TX_FAILURE, net.S2WERR_GENERIC_ERROR);
                return unit.event(net.S2EVENT_TX | net.S2EVENT_ERROR);
            }
            unit.stats.packets_sent += 1;
            if (unit.findTracked(req.packet_type)) |tracked| {
                tracked.stats.packets_sent += 1;
                tracked.stats.bytes_sent += req.data_length;
            }
            unit.sys.ReplyIO(&req.req);
        }
    };
}

fn sameAddress(a: *const ethernet.Address, b: *const ethernet.Address) bool {
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}
