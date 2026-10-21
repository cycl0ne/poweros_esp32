// SPDX-License-Identifier: MIT
//! A SuperSpeed link resting in U1 or U2: how long its way back to U0
//! takes, and how long its port waits idle before it takes the link
//! down. Worked out in nanoseconds, from what each end of each link says
//! of itself, as USB 3.2's appendix C lays the way out:
//!
//! - **MEL**, from the controller to the device: every link on the way
//!   woken - each as slowly as the slower of its two ends - each hub
//!   reading the packet's header and passing it on, and the device's
//!   answer to a PING once.
//! - **PEL**, from the device to the controller's side of its hub: the
//!   device's own link, or the hub passing the wake on up its own way,
//!   whichever takes longer.
//! - **SEL**, from the device starting the way back until the
//!   controller's first packet reaches it: its PEL, the ERDY up through
//!   the hubs, and the packet back down.
//!
//! A hub's own way counts as resting too: what a device is told is the
//! most it can take. The root hub has no way of its own; its ports' exit
//! latencies are the controller's.
//!
//! **A port's timeout** is three times the state's SEL: a link idle that
//! long goes down. U1's is in µs and at most 127, else the port leaves
//! the link to the device; U2's is in 256 µs, at most 254, else the same.

const d = @import("sdk").usb.descriptors;

/// The two states, as the arrays below hold them.
pub const U1 = 0;
pub const U2 = 1;

/// A hop's delay on the wire (tTPTransmissionDelay).
const transmission_ns = 40;
/// The device's answer to a PING (tPingResponse).
const ping_response_ns = 400;
/// A PING answer queued behind a packet of the largest size.
const queued_packet_ns = 2100;
/// A hub passing a wake from its port to its own link
/// (tHubPort2PortExitLat).
const port_to_port_us = 1;
/// The ERDY's way up: through the first hub, then each one more.
const erdy_first_hub_ns = 2100;
const erdy_per_hub_ns = 250;
/// The packet's way down, a hub each.
const packet_per_hub_ns = 250;

/// The way back from each state, in ns.
pub const Latencies = struct {
    mel: [2]u32 = .{ 0, 0 },
    pel: [2]u32 = .{ 0, 0 },
    sel: [2]u32 = .{ 0, 0 },
};

/// The hub a device hangs off, as far as the way back goes.
pub const Upstream = struct {
    /// The hub's own way back; none for the root hub.
    path: Latencies = .{},
    /// Its ports' exit latencies, in µs: its BOS's.
    exits: [2]u16 = .{ 0, 0 },
    /// bHubHdrDecLat, in 0.1 µs, and wHubDelay, in ns: a SuperSpeed hub
    /// descriptor's; 0 for the root hub.
    header_latency: u8 = 0,
    hub_delay: u16 = 0,
    root: bool = false,
};

/// The way back to a device whose own link takes `exits` µs, hanging off
/// `upstream` behind `hubs` hubs (0 on a root port).
pub fn pathOf(exits: [2]u16, upstream: Upstream, hubs: u32) Latencies {
    var path: Latencies = .{};
    for (0..2) |state| {
        const slower: u32 = @max(exits[state], upstream.exits[state]);
        const link = slower * 1000;
        var mel = upstream.path.mel[state] + link + @as(u32, upstream.header_latency) * 100 +
            (@as(u32, upstream.hub_delay) + transmission_ns) * 2;
        if (upstream.root) mel += ping_response_ns + queued_packet_ns;
        path.mel[state] = mel;
        // U2's way through the hub takes as much longer than U1's as its
        // own ports' do.
        const through_us: u32 = if (state == U1) port_to_port_us else port_to_port_us + (upstream.exits[U2] -| upstream.exits[U1]);
        path.pel[state] = @max(link, through_us * 1000 + upstream.path.pel[state]);
        var sel = path.pel[state] + packet_per_hub_ns * hubs;
        if (hubs > 0) sel += erdy_first_hub_ns + erdy_per_hub_ns * (hubs - 1);
        path.sel[state] = sel;
    }
    return path;
}

fn microsOf(ns: u32) u32 {
    return (ns + 999) / 1000;
}

/// SET_SEL's data for the way back: each in µs, rounded up, as much as
/// its field holds.
pub fn selOf(path: Latencies) d.SelData {
    return .{
        .u1_sel = @min(microsOf(path.sel[U1]), 0xFF),
        .u1_pel = @min(microsOf(path.pel[U1]), 0xFF),
        .u2_sel = @min(microsOf(path.sel[U2]), 0xFFFF),
        .u2_pel = @min(microsOf(path.pel[U2]), 0xFFFF),
    };
}

/// The longest way from the controller back to the device of the states
/// it offers (an exit latency not 0), in µs: SET_SEL's `exit_latency`.
pub fn exitLatencyOf(path: Latencies, exits: [2]u16) u16 {
    var longest: u32 = 0;
    for (0..2) |state| {
        if (exits[state] != 0) longest = @max(longest, microsOf(path.mel[state]));
    }
    return @min(longest, 0xFFFF);
}

/// The port's timeout for `state`: three times its SEL, in the state's
/// units; USB_LPM_TIMEOUT_ACCEPT where that is past the most the field
/// holds.
pub fn timeoutOf(state: u32, path: Latencies) u8 {
    const wait: u64 = @as(u64, path.sel[state]) * 3;
    const unit: u64 = if (state == U1) 1000 else 256_000;
    const most: u64 = if (state == U1) d.USB_U1_TIMEOUT_MAX else d.USB_U2_TIMEOUT_MAX;
    const count = @max((wait + unit - 1) / unit, 1);
    if (count > most) return d.USB_LPM_TIMEOUT_ACCEPT;
    return @intCast(count);
}
