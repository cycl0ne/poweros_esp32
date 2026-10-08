// SPDX-License-Identifier: MIT
//! filter.library's structures and constants: a packet filter on
//! bsdsocket.library's packet hooks, its rules loaded as text. The calls
//! are in `sdk.interface.filter`.
//!
//! **The rules**, a line each, the first that matches deciding:
//!
//!   # ENVARC:Sys/net/filter: '#' to the line's end is a comment
//!   default in on wlan0 block
//!   pass   in on wlan0 proto tcp from 192.168.1.0/24 to port 23
//!   pass   in proto icmp type echo
//!   refuse in on eth0 proto udp to port 161
//!
//! - **Action**: `pass`, `block` (dropped, nothing said) or `refuse` (a
//!   TCP reset, or a port unreachable; anything else dropped). Then `in`.
//! - **Matches**, each at most once, in any order: `on <interface>`;
//!   `inet` or `inet6`; `proto tcp|udp|icmp|icmp6`; `from` and `to`, each
//!   with an address and a prefix length (`10.0.0.0/8`, `fd00::/8`), or
//!   `any`, or nothing, and `port <n>` or `port <n>-<m>`; `type echo`,
//!   `type echo-reply` or `type <number>` for ICMP; `flags S` for a TCP
//!   segment that opens a connection (SYN without ACK). A port makes a
//!   rule TCP's and UDP's, a type ICMP's, `flags` TCP's. An IPv4 address
//!   matches IPv4 packets, an IPv6 one IPv6.
//! - **`default in [on <interface>] pass|block|refuse`**: what a packet on
//!   that interface gets when no rule matched; without `on`, every
//!   interface no other default names. An interface no default names is
//!   open.
//!
//! **What passes first**, before the rules: a segment of a TCP connection
//! the stack has, and an answer to a UDP datagram or an echo this machine
//! sent - a UDP exchange is kept 60 seconds after its last packet, an
//! echo 10. What bsdsocket.library never shows a hook passes too: lo0,
//! ARP, IGMP, ICMP's errors, Neighbor Discovery, MLD, and the machine's
//! own DHCP.

const bsd = @import("../bsdsocket/bsdsocket.zig");

/// The library's name, for OpenLibrary.
pub const FILTERNAME = "filter.library";

/// Where the rules are kept, and C:net/Filter loads them from.
pub const FILTER_FILE = "ENVARC:Sys/net/filter";

/// LoadFilterRules' answers.
pub const FILTERERR_OK: u32 = 0;
/// A word not understood, or out of its place: FilterError says which.
pub const FILTERERR_SYNTAX: u32 = 1;
/// A second default for one interface, or a match given twice.
pub const FILTERERR_TWICE: u32 = 2;
pub const FILTERERR_NOMEM: u32 = 3;
/// bsdsocket.library could not be opened, or took no hook.
pub const FILTERERR_NOSTACK: u32 = 4;

/// Where LoadFilterRules stopped: the line, the column of the word (both
/// from 1) and the word itself, NUL-terminated and cut to fit.
pub const FilterError = extern struct {
    code: u32 = FILTERERR_OK,
    line: u32 = 0,
    column: u32 = 0,
    word: [32]u8 = @splat(0),
};

/// FilterRuleInfo's `kind`.
pub const FILTERINFO_RULE: u8 = 0;
pub const FILTERINFO_DEFAULT: u8 = 1;

/// FilterRuleInfo's `action`.
pub const FILTER_PASS: u8 = 0;
pub const FILTER_BLOCK: u8 = 1;
pub const FILTER_REFUSE: u8 = 2;

/// The longest text of a rule GetFilterRules hands back.
pub const FILTER_TEXT_MAX = 96;

/// A rule or a default as GetFilterRules hands it back, in the file's
/// order: the line it came from, how many packets it decided, and its
/// text as written, NUL-terminated.
pub const FilterRuleInfo = extern struct {
    kind: u8 = FILTERINFO_RULE,
    action: u8 = FILTER_PASS,
    pad: [2]u8 = .{ 0, 0 },
    line: u32 = 0,
    hits: u32 = 0,
    text: [FILTER_TEXT_MAX]u8 = @splat(0),
};

/// An exchange this machine began - a UDP datagram or an echo it sent -
/// whose answers come in without a rule: the protocol, this machine's end
/// and the other's (an echo's identifier as `local_port`), and how long
/// since its last packet.
pub const FilterFlowInfo = extern struct {
    protocol: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
    local: bsd.in6_addr = .{},
    remote: bsd.in6_addr = .{},
    local_port: u16 = 0,
    remote_port: u16 = 0,
    idle_ms: u32 = 0,
};
