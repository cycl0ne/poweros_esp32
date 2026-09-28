// SPDX-License-Identifier: MIT
//! Host tests of the modules on the disk: the parts of each that need no
//! hardware. Some of them bring up exec and utility.library the way the
//! ROM's own tests do, through the named import `host_rom`, which the
//! system's build hands this root when it runs them.

test {
    _ = @import("devs/sdcard/card.zig");
    _ = @import("devs/sdcard/sdspi.zig");
    _ = @import("devs/networks/tests/api.zig");
    _ = @import("devs/networks/tests/openeth.zig");
    _ = @import("devs/networks/wifi/tests/wifi.zig");
    _ = @import("devs/networks/wifi/tests/wpa.zig");
    _ = @import("devs/networks/wifi/tests/ie.zig");
    _ = @import("devs/networks/wifi/tests/eapol.zig");
    _ = @import("devs/telnet/filter.zig");
    _ = @import("libs/bsdsocket/tests/bsdsocket.zig");
    _ = @import("libs/bsdsocket/tests/arp.zig");
    _ = @import("libs/bsdsocket/tests/icmp.zig");
    _ = @import("libs/bsdsocket/tests/tcp.zig");
    _ = @import("libs/bsdsocket/tests/netif.zig");
    _ = @import("libs/bsdsocket/tests/dhcp.zig");
    _ = @import("libs/bsdsocket/tests/names.zig");
    _ = @import("libs/bsdsocket/tests/address.zig");
    _ = @import("libs/bsdsocket/tests/ip6.zig");
    _ = @import("libs/bsdsocket/tests/nd.zig");
    _ = @import("libs/bsdsocket/tests/socket6.zig");
    _ = @import("libs/crypto/tests/crypto.zig");
    _ = @import("libs/diskfont/tests/diskfont.zig");
    _ = @import("libs/truetype/tests/truetype.zig");
    _ = @import("libs/asl/tests/asl.zig");
    _ = @import("c/net/addnetinterface/config.zig");
    _ = @import("c/net/timesync/tests/zone.zig");
    _ = @import("c/net/httpget/http.zig");
    _ = @import("handlers/fat/_fat.zig");
    _ = @import("handlers/fat/testmedia.zig");
    _ = @import("handlers/fat/cache.zig");
    _ = @import("handlers/fat/fat32/layout.zig");
    _ = @import("handlers/fat/fat32/table.zig");
    _ = @import("handlers/fat/fat32/names.zig");
    _ = @import("handlers/fat/fat32/dir.zig");
    _ = @import("handlers/fat/fat32/fs.zig");
    _ = @import("handlers/fat/exfat/layout.zig");
    _ = @import("handlers/fat/exfat/table.zig");
    _ = @import("handlers/fat/exfat/bitmap.zig");
    _ = @import("handlers/fat/exfat/upcase.zig");
    _ = @import("handlers/fat/exfat/names.zig");
    _ = @import("handlers/fat/exfat/dir.zig");
    _ = @import("handlers/fat/exfat/fs.zig");
    _ = @import("handlers/fat/fat.zig");
    _ = @import("handlers/fat/tests/_fat.zig");
    _ = @import("handlers/fat/tests/names.zig");
    _ = @import("handlers/fat/tests/dir.zig");
    _ = @import("handlers/fat/tests/fs.zig");
    _ = @import("handlers/fat/tests/exfat_dir.zig");
    _ = @import("handlers/fat/tests/exfat_fs.zig");
    _ = @import("classes/gadgets/tests/classes.zig");
    _ = @import("classes/gadgets/colorwheel/_colour.zig");
}
