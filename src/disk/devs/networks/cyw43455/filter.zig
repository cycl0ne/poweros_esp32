// SPDX-License-Identifier: MIT
//! The multicast groups the radio takes, for cyw43455.device. The
//! firmware hands the host a group's frames only once it is told of the
//! group - IPv6's all-nodes group and each address's solicited-node group
//! among them, without which no neighbor finds the station's addresses
//! but the ones it has already heard from. So the unit's groups are given
//! it as Linux's brcmfmac gives them: their list ("mcast_list": how many,
//! then each address); and while an opener is promiscuous, every group
//! ("allmulti") and every frame (`C_SET_PROMISC`).

const std = @import("std");
const unit = @import("sdk").devices.network.unit;

/// The command that has the firmware hand over every frame it hears.
pub const C_SET_PROMISC: u32 = 10;

/// The most "mcast_list" holds: the count, and every group the unit can
/// join.
pub const list_max = 4 + unit.groups_max * 6;

/// "mcast_list"'s value.
pub const List = struct {
    bytes: [list_max]u8 = undefined,
    len: usize = 0,

    pub fn slice(list: *const List) []const u8 {
        return list.bytes[0..list.len];
    }
};

/// The list of the groups in `groups` that have users.
pub fn listOf(groups: []const unit.Group) List {
    var made: List = .{};
    var count: usize = 0;
    for (groups) |*group| {
        if (group.users == 0) continue;
        if (count == unit.groups_max) break;
        made.bytes[4 + count * 6 ..][0..6].* = group.address;
        count += 1;
    }
    std.mem.writeInt(u32, made.bytes[0..4], @intCast(count), .little);
    made.len = 4 + count * 6;
    return made;
}
