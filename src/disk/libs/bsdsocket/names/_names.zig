// SPDX-License-Identifier: MIT
//! Names: the name servers the stack asks, and later the resolver that
//! asks them.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;

/// A name server added, if it is not there already; false when the list
/// is full. Under the lock.
pub fn addServer(stack: *StackBase, address: u32) bool {
    if (address == 0) return false;
    for (stack.nameservers[0..stack.nameserver_count]) |server| {
        if (server == address) return true;
    }
    if (stack.nameserver_count == bsd.NAMESERVERS_MAX) return false;
    stack.nameservers[stack.nameserver_count] = address;
    stack.nameserver_count += 1;
    return true;
}

/// A name server taken off the list; false if it was not on it. Under
/// the lock.
pub fn removeServer(stack: *StackBase, address: u32) bool {
    const count = stack.nameserver_count;
    for (stack.nameservers[0..count], 0..) |server, index| {
        if (server != address) continue;
        var at = index;
        while (at + 1 < count) : (at += 1) stack.nameservers[at] = stack.nameservers[at + 1];
        stack.nameserver_count -= 1;
        return true;
    }
    return false;
}
