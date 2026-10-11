// SPDX-License-Identifier: MIT
//! What a USB device says about itself and how it is asked: the setup
//! packet of a control transfer, the standard requests, the descriptors
//! and their types, the class codes, and a hub's own requests, features
//! and port bits. Shared by the host controller devices, usb.library, the
//! class drivers and programs.
//!
//! A descriptor comes as bytes, little-endian, one after another with no
//! padding, so every field wider than a byte is `align(1)`: a structure
//! here can be laid over any byte of a configuration's descriptors.

// --- the setup packet ------------------------------------------------------------

/// The eight bytes that start every control transfer.
pub const SetupPacket = extern struct {
    /// bmRequestType: the direction (USB_DIR_*), the type (USB_TYPE_*)
    /// and the recipient (USB_RECIP_*), or'd.
    request_type: u8,
    /// bRequest: USB_REQ_* for a standard request, the class's otherwise.
    request: u8,
    /// wValue
    value: u16 align(1),
    /// wIndex: an interface's or an endpoint's number, a hub's port.
    index: u16 align(1),
    /// wLength: the bytes of the data stage, 0 for none.
    length: u16 align(1),
};

/// bmRequestType's direction, and an endpoint address's: device to host.
pub const USB_DIR_IN: u8 = 0x80;
pub const USB_DIR_OUT: u8 = 0x00;
/// bmRequestType's type.
pub const USB_TYPE_STANDARD: u8 = 0x00;
pub const USB_TYPE_CLASS: u8 = 0x20;
pub const USB_TYPE_VENDOR: u8 = 0x40;
/// bmRequestType's recipient. A hub's port is USB_RECIP_OTHER.
pub const USB_RECIP_DEVICE: u8 = 0x00;
pub const USB_RECIP_INTERFACE: u8 = 0x01;
pub const USB_RECIP_ENDPOINT: u8 = 0x02;
pub const USB_RECIP_OTHER: u8 = 0x03;

// The standard requests (bRequest).
pub const USB_REQ_GET_STATUS: u8 = 0;
pub const USB_REQ_CLEAR_FEATURE: u8 = 1;
pub const USB_REQ_SET_FEATURE: u8 = 3;
pub const USB_REQ_SET_ADDRESS: u8 = 5;
pub const USB_REQ_GET_DESCRIPTOR: u8 = 6;
pub const USB_REQ_SET_DESCRIPTOR: u8 = 7;
pub const USB_REQ_GET_CONFIGURATION: u8 = 8;
pub const USB_REQ_SET_CONFIGURATION: u8 = 9;
pub const USB_REQ_GET_INTERFACE: u8 = 10;
pub const USB_REQ_SET_INTERFACE: u8 = 11;

/// A standard feature: an endpoint's halt, cleared to take a stall away.
pub const USB_FEATURE_ENDPOINT_HALT: u16 = 0;

// --- descriptors -----------------------------------------------------------------

// bDescriptorType
pub const USB_DT_DEVICE: u8 = 0x01;
pub const USB_DT_CONFIG: u8 = 0x02;
pub const USB_DT_STRING: u8 = 0x03;
pub const USB_DT_INTERFACE: u8 = 0x04;
pub const USB_DT_ENDPOINT: u8 = 0x05;
pub const USB_DT_INTERFACE_ASSOCIATION: u8 = 0x0B;
pub const USB_DT_HID: u8 = 0x21;
pub const USB_DT_REPORT: u8 = 0x22;
pub const USB_DT_HUB: u8 = 0x29;

/// What every descriptor starts with: its length, which is how the next
/// one is found, and its type.
pub const DescriptorHeader = extern struct {
    /// bLength
    length: u8,
    /// bDescriptorType: USB_DT_*.
    descriptor_type: u8,
};

/// The device's own descriptor, 18 bytes.
pub const DeviceDescriptor = extern struct {
    /// bLength: 18.
    length: u8 = 18,
    /// bDescriptorType: USB_DT_DEVICE.
    descriptor_type: u8 = USB_DT_DEVICE,
    /// bcdUSB: the USB version it speaks, 0x0200 for 2.0.
    bcd_usb: u16 align(1) = 0,
    /// bDeviceClass, bDeviceSubClass, bDeviceProtocol: 0 when each
    /// interface says its own.
    device_class: u8 = 0,
    device_subclass: u8 = 0,
    device_protocol: u8 = 0,
    /// bMaxPacketSize0: endpoint 0's packet size, 8, 16, 32 or 64.
    max_packet_size0: u8 = 0,
    /// idVendor, idProduct, bcdDevice.
    vendor_id: u16 align(1) = 0,
    product_id: u16 align(1) = 0,
    bcd_device: u16 align(1) = 0,
    /// iManufacturer, iProduct, iSerialNumber: string indices, 0 for none.
    manufacturer_string: u8 = 0,
    product_string: u8 = 0,
    serial_string: u8 = 0,
    /// bNumConfigurations
    num_configurations: u8 = 0,
};

/// A configuration's descriptor, 9 bytes; its interfaces' and endpoints'
/// descriptors follow it, `total_length` bytes in all.
pub const ConfigDescriptor = extern struct {
    /// bLength: 9.
    length: u8 = 9,
    /// bDescriptorType: USB_DT_CONFIG.
    descriptor_type: u8 = USB_DT_CONFIG,
    /// wTotalLength: this and every descriptor after it.
    total_length: u16 align(1) = 0,
    /// bNumInterfaces
    num_interfaces: u8 = 0,
    /// bConfigurationValue: what SET_CONFIGURATION takes.
    configuration_value: u8 = 0,
    /// iConfiguration
    configuration_string: u8 = 0,
    /// bmAttributes: USB_CONFIG_*.
    attributes: u8 = 0x80,
    /// bMaxPower: in 2 mA.
    max_power: u8 = 0,
};

/// bmAttributes: always set, then self-powered and remote wakeup.
pub const USB_CONFIG_ONE: u8 = 0x80;
pub const USB_CONFIG_SELF_POWERED: u8 = 0x40;
pub const USB_CONFIG_REMOTE_WAKEUP: u8 = 0x20;

/// An interface's descriptor, 9 bytes; its endpoints follow it.
pub const InterfaceDescriptor = extern struct {
    /// bLength: 9.
    length: u8 = 9,
    /// bDescriptorType: USB_DT_INTERFACE.
    descriptor_type: u8 = USB_DT_INTERFACE,
    /// bInterfaceNumber, bAlternateSetting.
    interface_number: u8 = 0,
    alternate_setting: u8 = 0,
    /// bNumEndpoints: not counting endpoint 0.
    num_endpoints: u8 = 0,
    /// bInterfaceClass, bInterfaceSubClass, bInterfaceProtocol.
    interface_class: u8 = 0,
    interface_subclass: u8 = 0,
    interface_protocol: u8 = 0,
    /// iInterface
    interface_string: u8 = 0,
};

/// An endpoint's descriptor, 7 bytes.
pub const EndpointDescriptor = extern struct {
    /// bLength: 7.
    length: u8 = 7,
    /// bDescriptorType: USB_DT_ENDPOINT.
    descriptor_type: u8 = USB_DT_ENDPOINT,
    /// bEndpointAddress: the number, with USB_DIR_IN for one that sends.
    endpoint_address: u8 = 0,
    /// bmAttributes: the transfer type in its low two bits
    /// (USB_ENDPOINT_XFER_*).
    attributes: u8 = 0,
    /// wMaxPacketSize: the low 11 bits; at high speed the two above say
    /// how many more transactions a microframe takes.
    max_packet_size: u16 align(1) = 0,
    /// bInterval: how often a periodic endpoint is asked, in frames at
    /// full and low speed.
    interval: u8 = 0,
};

/// An endpoint address's number.
pub const USB_ENDPOINT_NUMBER_MASK: u8 = 0x0F;
/// bmAttributes' transfer type.
pub const USB_ENDPOINT_XFERTYPE_MASK: u8 = 0x03;
pub const USB_ENDPOINT_XFER_CONTROL: u8 = 0;
pub const USB_ENDPOINT_XFER_ISOC: u8 = 1;
pub const USB_ENDPOINT_XFER_BULK: u8 = 2;
pub const USB_ENDPOINT_XFER_INT: u8 = 3;

/// A string's descriptor: after these two bytes, UTF-16LE characters to
/// `length`. String 0 is the list of languages, of which the first is
/// asked for.
pub const StringDescriptor = DescriptorHeader;

// --- class codes -----------------------------------------------------------------

pub const USB_CLASS_PER_INTERFACE: u8 = 0x00;
pub const USB_CLASS_AUDIO: u8 = 0x01;
pub const USB_CLASS_COMM: u8 = 0x02;
pub const USB_CLASS_HID: u8 = 0x03;
pub const USB_CLASS_PRINTER: u8 = 0x07;
pub const USB_CLASS_MASS_STORAGE: u8 = 0x08;
pub const USB_CLASS_HUB: u8 = 0x09;
pub const USB_CLASS_CDC_DATA: u8 = 0x0A;
pub const USB_CLASS_VENDOR_SPEC: u8 = 0xFF;

// --- hubs ------------------------------------------------------------------------

/// A hub's descriptor: its ports, how they are powered, and how long a
/// port takes to have power. The bitmaps after it are not used here.
pub const HubDescriptor = extern struct {
    /// bDescLength
    length: u8 = 9,
    /// bDescriptorType: USB_DT_HUB.
    descriptor_type: u8 = USB_DT_HUB,
    /// bNbrPorts
    num_ports: u8 = 0,
    /// wHubCharacteristics: USB_HUB_CHAR_*.
    characteristics: u16 align(1) = 0,
    /// bPwrOn2PwrGood: in 2 ms.
    power_on_to_good: u8 = 0,
    /// bHubContrCurrent: in mA.
    controller_current: u8 = 0,
    /// DeviceRemovable and PortPwrCtrlMask, for a hub of up to 7 ports.
    removable: u8 = 0,
    power_mask: u8 = 0xFF,
};

/// wHubCharacteristics: each port powered on its own, each port's
/// over-current reported on its own.
pub const USB_HUB_CHAR_INDIVIDUAL_POWER: u16 = 0x0001;
pub const USB_HUB_CHAR_INDIVIDUAL_OVERCURRENT: u16 = 0x0008;

/// A hub's class requests' bmRequestType: to the hub, or to one of its
/// ports (wIndex the port, from 1).
pub const USB_RT_HUB: u8 = USB_TYPE_CLASS | USB_RECIP_DEVICE;
pub const USB_RT_PORT: u8 = USB_TYPE_CLASS | USB_RECIP_OTHER;

/// A port's features, for SET_FEATURE and CLEAR_FEATURE.
pub const USB_PORT_FEAT_CONNECTION: u16 = 0;
pub const USB_PORT_FEAT_ENABLE: u16 = 1;
pub const USB_PORT_FEAT_SUSPEND: u16 = 2;
pub const USB_PORT_FEAT_OVER_CURRENT: u16 = 3;
pub const USB_PORT_FEAT_RESET: u16 = 4;
pub const USB_PORT_FEAT_POWER: u16 = 8;
pub const USB_PORT_FEAT_LOWSPEED: u16 = 9;
pub const USB_PORT_FEAT_C_CONNECTION: u16 = 16;
pub const USB_PORT_FEAT_C_ENABLE: u16 = 17;
pub const USB_PORT_FEAT_C_SUSPEND: u16 = 18;
pub const USB_PORT_FEAT_C_OVER_CURRENT: u16 = 19;
pub const USB_PORT_FEAT_C_RESET: u16 = 20;

/// GET_STATUS of a port: wPortStatus, then wPortChange.
pub const PortStatus = extern struct {
    /// wPortStatus: USB_PORT_STAT_*.
    status: u16 align(1) = 0,
    /// wPortChange: USB_PORT_STAT_C_*.
    change: u16 align(1) = 0,
};

// wPortStatus
pub const USB_PORT_STAT_CONNECTION: u16 = 1 << 0;
pub const USB_PORT_STAT_ENABLE: u16 = 1 << 1;
pub const USB_PORT_STAT_SUSPEND: u16 = 1 << 2;
pub const USB_PORT_STAT_OVERCURRENT: u16 = 1 << 3;
pub const USB_PORT_STAT_RESET: u16 = 1 << 4;
pub const USB_PORT_STAT_POWER: u16 = 1 << 8;
pub const USB_PORT_STAT_LOW_SPEED: u16 = 1 << 9;
pub const USB_PORT_STAT_HIGH_SPEED: u16 = 1 << 10;
// wPortChange
pub const USB_PORT_STAT_C_CONNECTION: u16 = 1 << 0;
pub const USB_PORT_STAT_C_ENABLE: u16 = 1 << 1;
pub const USB_PORT_STAT_C_SUSPEND: u16 = 1 << 2;
pub const USB_PORT_STAT_C_OVERCURRENT: u16 = 1 << 3;
pub const USB_PORT_STAT_C_RESET: u16 = 1 << 4;

// --- HID -------------------------------------------------------------------------

/// HID's class requests.
pub const HID_REQ_GET_REPORT: u8 = 0x01;
pub const HID_REQ_SET_REPORT: u8 = 0x09;
pub const HID_REQ_SET_IDLE: u8 = 0x0A;
pub const HID_REQ_SET_PROTOCOL: u8 = 0x0B;
/// bInterfaceSubClass: the boot interface, whose reports have a fixed
/// form; bInterfaceProtocol then says which.
pub const HID_SUBCLASS_BOOT: u8 = 1;
pub const HID_PROTOCOL_KEYBOARD: u8 = 1;
pub const HID_PROTOCOL_MOUSE: u8 = 2;
/// SET_REPORT's wValue high byte: an output report (a keyboard's LEDs).
pub const HID_REPORT_OUTPUT: u8 = 2;

comptime {
    if (@sizeOf(SetupPacket) != 8 or @sizeOf(DeviceDescriptor) != 18 or
        @sizeOf(ConfigDescriptor) != 9 or @sizeOf(InterfaceDescriptor) != 9 or
        @sizeOf(EndpointDescriptor) != 7 or @sizeOf(HubDescriptor) != 9 or
        @sizeOf(PortStatus) != 4)
        @compileError("a USB descriptor's layout is not what goes on the wire");
}
