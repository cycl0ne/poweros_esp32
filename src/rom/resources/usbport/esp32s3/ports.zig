// SPDX-License-Identifier: MPL-2.0
//! The ESP32-S3's USB port: one full-speed PHY on GPIO19 (D-) and GPIO20
//! (D+), which USB-Serial-JTAG has as the chip starts and the USB OTG
//! controller can be given. RTC_CNTL's USB_CONF chooses between the two;
//! USB_WRAP holds the OTG side's pad settings - the pads on, and a host's
//! pull-downs on D+ and D-. The pads are driven at their strongest while
//! the OTG controller has them. From ESP-IDF v6.1's usb_phy.c and
//! usb_wrap_ll.h.
//!
//! USB_WRAP is clocked and reset with the OTG controller: its settings
//! hold only while the controller is powered, so usbotg.device powers it
//! before it bids and lets go of the port before it powers it off.

const sdk = @import("sdk");
const usbport = sdk.resources.usbport;
const st = sdk.expansion.systemtags;
const hw = sdk.hardware;
const reg = hw.mmio.reg;
const rtc_cntl = hw.rtc_cntl;

/// The chip's one port.
pub const count = 1;

/// The port `controller`'s unit `unit` is on, or null for a controller
/// the chip does not have.
pub fn portOf(controller: u8, unit: u8) ?u32 {
    if (unit != 0) return null;
    return switch (controller) {
        usbport.USBCTL_SERIALJTAG, usbport.USBCTL_OTG => 0,
        else => null,
    };
}

/// USB_WRAP's OTG_CONF and the bits of it set here.
const OTG_CONF: usize = hw.map.USB_WRAP + 0x00;
/// The pads on the internal PHY, not an external one.
const OTG_CONF_PHY_SEL: u32 = 1 << 2;
const OTG_CONF_PAD_PULL_OVERRIDE: u32 = 1 << 12;
const OTG_CONF_DP_PULLUP: u32 = 1 << 13;
const OTG_CONF_DP_PULLDOWN: u32 = 1 << 14;
const OTG_CONF_DM_PULLUP: u32 = 1 << 15;
const OTG_CONF_DM_PULLDOWN: u32 = 1 << 16;
const OTG_CONF_USB_PAD_ENABLE: u32 = 1 << 18;
const OTG_CONF_PULLS = OTG_CONF_DP_PULLUP | OTG_CONF_DP_PULLDOWN | OTG_CONF_DM_PULLUP | OTG_CONF_DM_PULLDOWN;

/// D- and D+.
const pads = [_]u8{ 19, 20 };

/// The port given to `controller` in `role` (USBROLE_*); null gives it
/// back to what the chip starts with, as the eFuse says (USB-Serial-JTAG).
pub fn route(port: u32, controller: ?u8, role: u8) void {
    _ = port;
    const conf = reg(rtc_cntl.USB_CONF);
    const both = rtc_cntl.USB_CONF_SW_HW_USB_PHY_SEL | rtc_cntl.USB_CONF_SW_USB_PHY_SEL;
    if (controller == usbport.USBCTL_OTG) {
        var wrap = reg(OTG_CONF).* & ~(OTG_CONF_PHY_SEL | OTG_CONF_PULLS | OTG_CONF_PAD_PULL_OVERRIDE);
        wrap |= OTG_CONF_USB_PAD_ENABLE;
        if (role & st.USBROLE_HOST != 0) wrap |= OTG_CONF_DP_PULLDOWN | OTG_CONF_DM_PULLDOWN | OTG_CONF_PAD_PULL_OVERRIDE;
        reg(OTG_CONF).* = wrap;
        for (pads) |pad| hw.gpio.driveStrength(pad, 3);
        conf.* |= both;
        return;
    }
    if (controller == usbport.USBCTL_SERIALJTAG) {
        conf.* = (conf.* & ~both) | rtc_cntl.USB_CONF_SW_HW_USB_PHY_SEL;
    } else {
        conf.* &= ~both;
    }
    // The OTG side's pulls off, where its block is clocked to take it.
    if (hw.system.clockIsOn(.usb_otg)) reg(OTG_CONF).* &= ~OTG_CONF_PAD_PULL_OVERRIDE;
    for (pads) |pad| hw.gpio.driveStrength(pad, 2);
}
