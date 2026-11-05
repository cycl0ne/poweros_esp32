// SPDX-License-Identifier: MIT
//! What the controller needs before it can finish a packet's checksums,
//! for intelnet.device.
//!
//! The controller fills in the checksum of a packet's transport part on
//! its way out, which is the one expensive sum in sending a packet: it
//! covers every byte of the payload. What the controller does is add up
//! the bytes from the end of the IP header to the end of the frame and
//! write the complement of that where the transport header keeps its
//! checksum. Where the headers end it is told by a context descriptor in
//! front of the frame.
//!
//! What it does not do is work out the pseudo-header - the addresses, the
//! protocol and the length that a transport checksum covers although
//! none of them is in the transport header. The sum it starts from is
//! whatever already stands in the checksum field, so the pseudo-header's
//! own sum has to be put there first, and that is this file's work.
//! Twelve bytes against fifteen hundred: almost all of the saving is
//! kept.
//!
//! The IP header's own checksum is worked out here as well, over the
//! twenty bytes it covers. The controller would do that one too, given
//! another bit in the descriptor - but the transport checksum with the
//! pseudo-header seeded is the path these parts are driven along
//! everywhere, and twenty bytes is not worth stepping off it for.
//!
//! A packet this cannot be done for is left alone and sent whole, with
//! whatever checksums it came with.

/// An Ethernet header, and the two bytes in it that say what follows.
const ethernet_bytes = 14;
const ethernet_type_at = 12;
const ethertype_ipv4 = 0x0800;

/// An IPv4 header: the least it can be, where it keeps its own checksum,
/// where the addresses are, and the fragment field with the bits that
/// say the packet is one piece of several.
const ip_least = 20;
const ip_total_at = 2;
const ip_fragment_at = 6;
const ip_protocol_at = 9;
const ip_checksum_at = 10;
const ip_source_at = 12;
const ip_fragment_mask: u32 = 0x3FFF;

/// The two transports whose checksum the controller works out, and where
/// each keeps it.
const protocol_tcp = 6;
const protocol_udp = 17;
const tcp_checksum_at = 16;
const udp_checksum_at = 6;

/// Where a frame's headers end, which is what the context descriptor
/// carries.
pub const Headers = struct {
    /// The Ethernet header's length.
    mac: u32,
    /// The IP header's length.
    ip: u32,
    /// Whether the transport part is TCP; UDP otherwise.
    tcp: bool,
};

/// The lengths an ordinary packet has, for the context descriptor that
/// goes in front of a frame the controller turns out not to be able to
/// finish: the descriptor has to say something, and nothing reads it.
pub const plain: Headers = .{ .mac = ethernet_bytes, .ip = ip_least, .tcp = false };

/// `frame` made ready for the controller to finish: its IP header's
/// checksum worked out, and the pseudo-header's sum put where the
/// transport checksum goes. The answer is where its headers end.
///
/// Null where this is not a packet the controller can finish - anything
/// but a whole, unfragmented IPv4 packet carrying TCP or UDP, and one
/// whose length does not account for the whole frame, since the
/// controller would add up whatever followed it. Nothing of the frame is
/// changed in that case, and it goes out as it came.
pub fn seed(frame: []u8) ?Headers {
    if (frame.len < ethernet_bytes + ip_least) return null;
    if (read16(frame, ethernet_type_at) != ethertype_ipv4) return null;
    const packet = frame[ethernet_bytes..];
    if (packet[0] >> 4 != 4) return null;
    const ip_bytes: u32 = @as(u32, packet[0] & 0xF) * 4;
    const total: u32 = read16(packet, ip_total_at);
    if (ip_bytes < ip_least or total < ip_bytes or total != packet.len) return null;
    if (read16(packet, ip_fragment_at) & ip_fragment_mask != 0) return null;
    const protocol = packet[ip_protocol_at];
    const tcp = switch (protocol) {
        protocol_tcp => true,
        protocol_udp => false,
        else => return null,
    };
    const transport = total - ip_bytes;
    const checksum_at: u32 = if (tcp) tcp_checksum_at else udp_checksum_at;
    if (transport < checksum_at + 2) return null;

    // The header's own checksum covers the header with its checksum
    // field zero, so the field is cleared before the sum is taken rather
    // than trusted to be zero already.
    const header = packet[0..ip_bytes];
    write16(header, ip_checksum_at, 0);
    write16(header, ip_checksum_at, ~fold(sum(header)));
    // The pseudo-header's sum where the transport checksum goes. The
    // controller adds the bytes it covers to what it finds there, so
    // this stands in for the twelve bytes it cannot see.
    write16(packet[ip_bytes..], checksum_at, fold(pseudo(header, protocol, transport)));
    return .{ .mac = ethernet_bytes, .ip = ip_bytes, .tcp = tcp };
}

/// The sum of the pseudo-header a transport checksum covers: the two
/// addresses out of `header`, the protocol, and the transport part's
/// length. Not folded - the caller does that once.
fn pseudo(header: []const u8, protocol: u8, transport: u32) u32 {
    var total: u32 = protocol;
    total += transport;
    total += read16(header, ip_source_at);
    total += read16(header, ip_source_at + 2);
    total += read16(header, ip_source_at + 4);
    total += read16(header, ip_source_at + 6);
    return total;
}

/// The one's complement sum of `bytes` as 16-bit words, carries left to
/// be folded in afterwards. A trailing odd byte cannot arise here: an IP
/// header is a whole number of words.
fn sum(bytes: []const u8) u32 {
    var total: u32 = 0;
    var at: usize = 0;
    while (at + 1 < bytes.len) : (at += 2) total += read16(bytes, at);
    return total;
}

/// A sum with its carries folded back in, which is that sum as sixteen
/// bits.
fn fold(total: u32) u16 {
    var left = total;
    while (left >> 16 != 0) left = (left & 0xFFFF) + (left >> 16);
    return @truncate(left);
}

/// A packet's two bytes at `at`, which are the high byte first.
fn read16(bytes: []const u8, at: usize) u32 {
    return @as(u32, bytes[at]) << 8 | bytes[at + 1];
}

fn write16(bytes: []u8, at: usize, value: u16) void {
    bytes[at] = @truncate(value >> 8);
    bytes[at + 1] = @truncate(value);
}
