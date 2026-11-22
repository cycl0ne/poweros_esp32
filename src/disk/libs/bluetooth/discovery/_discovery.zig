// SPDX-License-Identifier: MIT
//! A found device as ObtainBTDevices hands it out: the public record and
//! its name, in one piece, copied from the controller's table
//! (hci/devices.zig) under the base's lock.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const devices = @import("../hci/devices.zig");

pub const Entry = extern struct {
    public: bluetooth.BTDevice = .{},
    name: [hci.HCI_MAX_NAME + 1]u8 = @splat(0),
};

/// A device of controller `id` copied into an entry; `now` the time in
/// milliseconds, which its age is counted from.
pub fn describe(id: u32, device: *const devices.Device, entry: *Entry, now: u64) void {
    @memcpy(&entry.name, &device.name);
    entry.name[hci.HCI_MAX_NAME] = 0;
    entry.public = .{
        .controller = id,
        .flags = device.flags,
        .address = device.address,
        .class_of_device = device.class_of_device,
        .age = @intCast(@min(if (now > device.seen) now - device.seen else 0, 0xFFFF_FFFF)),
        .rssi = device.rssi,
        .tx_power = device.tx_power,
        .ad_flags = device.ad_flags,
        .uuid16_count = device.uuid16_count,
        .appearance = device.appearance,
        .company = device.company,
        .uuid16 = device.uuid16,
        .uuid128_count = device.uuid128_count,
        .uuid128 = device.uuid128,
    };
    entry.public.node.name = @ptrCast(&entry.name);
}
