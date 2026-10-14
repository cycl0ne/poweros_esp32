// SPDX-License-Identifier: MIT
//! The station's MAC address, as the factory burned it into eFuse block 1:
//! 48 bits in its first two words, the address's last byte lowest.

const efuse_base: usize = 0x6000_7000;
/// EFUSE_RD_MAC_SPI_SYS_0 and _1.
const mac_low = efuse_base + 0x44;
const mac_high = efuse_base + 0x48;

fn read(address: usize) u32 {
    return @as(*const volatile u32, @ptrFromInt(address)).*;
}

/// The factory MAC address, first byte first.
pub fn stationAddress() [6]u8 {
    const low = read(mac_low);
    const high = read(mac_high);
    return .{
        @truncate(high >> 8), @truncate(high),
        @truncate(low >> 24), @truncate(low >> 16),
        @truncate(low >> 8),  @truncate(low),
    };
}
