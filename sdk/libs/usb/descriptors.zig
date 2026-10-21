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
/// A SuperSpeed device's features: it may itself take its link to U1, to
/// U2, when it has nothing to move.
pub const USB_DEVICE_U1_ENABLE: u16 = 48;
pub const USB_DEVICE_U2_ENABLE: u16 = 49;

/// A SuperSpeed device's SET_SEL: how long the way back from U1 and U2
/// takes (`SelData`), so that it wakes its link early enough.
pub const USB_REQ_SET_SEL: u8 = 48;

/// SET_SEL's six bytes, each state's in µs: from the device starting its
/// link's way back until the controller's first packet reaches it (SEL),
/// and until its hub's link to the controller is back (PEL).
pub const SelData = extern struct {
    u1_sel: u8 = 0,
    u1_pel: u8 = 0,
    u2_sel: u16 align(1) = 0,
    u2_pel: u16 align(1) = 0,
};

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
/// A SuperSpeed hub's descriptor (`SSHubDescriptor`).
pub const USB_DT_SS_HUB: u8 = 0x2A;
/// A SuperSpeed endpoint's companion, right after its endpoint's
/// descriptor (`SSEndpointCompanion`).
pub const USB_DT_SS_ENDPOINT_COMP: u8 = 0x30;
/// The Binary Object Store of a device of bcdUSB 2.01 and later: a
/// header (`BosDescriptor`), then its capabilities, each a
/// USB_DT_DEVICE_CAPABILITY.
pub const USB_DT_BOS: u8 = 0x0F;
pub const USB_DT_DEVICE_CAPABILITY: u8 = 0x10;

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
    /// bMaxPacketSize0: endpoint 0's packet size, 8, 16, 32 or 64; at
    /// SuperSpeed its exponent, 9 for 512.
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
    /// how many more transactions a microframe takes. At SuperSpeed a
    /// companion descriptor follows (`SSEndpointCompanion`).
    max_packet_size: u16 align(1) = 0,
    /// bInterval: how often a periodic endpoint is asked, in frames at
    /// full and low speed.
    interval: u8 = 0,
};

/// What a SuperSpeed endpoint's descriptor has after it: how many
/// packets it takes in a burst, and for a periodic one how much it moves
/// each interval.
pub const SSEndpointCompanion = extern struct {
    /// bLength: 6.
    length: u8 = 6,
    /// bDescriptorType: USB_DT_SS_ENDPOINT_COMP.
    descriptor_type: u8 = USB_DT_SS_ENDPOINT_COMP,
    /// bMaxBurst: the packets of a burst less one, 0 to 15.
    max_burst: u8 = 0,
    /// bmAttributes: a bulk endpoint's streams as a power of two; an
    /// isochronous one's bursts an interval less one (Mult), in the low
    /// two bits.
    attributes: u8 = 0,
    /// wBytesPerInterval: a periodic endpoint's bytes an interval.
    bytes_per_interval: u16 align(1) = 0,
};

/// The Binary Object Store's header, before its capabilities.
pub const BosDescriptor = extern struct {
    /// bLength: 5.
    length: u8 = 5,
    /// bDescriptorType: USB_DT_BOS.
    descriptor_type: u8 = USB_DT_BOS,
    /// wTotalLength: the header and every capability.
    total_length: u16 align(1) = 5,
    /// bNumDeviceCaps
    num_capabilities: u8 = 0,
};

/// bDevCapabilityType: SuperSpeed USB (`SSUsbCapability`).
pub const USB_CAP_SUPERSPEED: u8 = 0x03;

/// A device's SuperSpeed USB capability, in its BOS: its speeds, and how
/// long its link takes to come back from U1 and U2 to U0.
pub const SSUsbCapability = extern struct {
    /// bLength: 10.
    length: u8 = 10,
    /// bDescriptorType: USB_DT_DEVICE_CAPABILITY.
    descriptor_type: u8 = USB_DT_DEVICE_CAPABILITY,
    /// bDevCapabilityType: USB_CAP_SUPERSPEED.
    capability_type: u8 = USB_CAP_SUPERSPEED,
    /// bmAttributes: bit 1, it sends Latency Tolerance Messages.
    attributes: u8 = 0,
    /// wSpeedsSupported: a bit per speed, low (bit 0) to SuperSpeed (3).
    speeds: u16 align(1) = 0,
    /// bFunctionalitySupport: the lowest speed it works fully at.
    functionality: u8 = 0,
    /// bU1DevExitLat: its link's way back from U1, in µs, at most 10.
    u1_exit: u8 = 0,
    /// wU2DevExitLat: from U2, in µs, at most 2047.
    u2_exit: u16 align(1) = 0,
};

/// The SuperSpeed USB capability in a BOS as it came, or null if it has
/// none or the BOS ends before it.
pub fn superSpeedCapabilityOf(bos: []const u8) ?SSUsbCapability {
    if (bos.len < @sizeOf(BosDescriptor) or bos[1] != USB_DT_BOS) return null;
    var at: usize = bos[0];
    while (at + 3 <= bos.len) {
        const length = bos[at];
        if (length < 3 or at + length > bos.len) return null;
        if (bos[at + 1] == USB_DT_DEVICE_CAPABILITY and bos[at + 2] == USB_CAP_SUPERSPEED and length >= @sizeOf(SSUsbCapability)) {
            const capability: *align(1) const SSUsbCapability = @ptrCast(bos[at..].ptr);
            return capability.*;
        }
        at += length;
    }
    return null;
}

/// An endpoint address's number.
pub const USB_ENDPOINT_NUMBER_MASK: u8 = 0x0F;
/// bmAttributes' transfer type.
pub const USB_ENDPOINT_XFERTYPE_MASK: u8 = 0x03;
pub const USB_ENDPOINT_XFER_CONTROL: u8 = 0;
pub const USB_ENDPOINT_XFER_ISOC: u8 = 1;
pub const USB_ENDPOINT_XFER_BULK: u8 = 2;
pub const USB_ENDPOINT_XFER_INT: u8 = 3;
/// bmAttributes' synchronisation of an isochronous endpoint: none, the
/// device's own clock (an OUT endpoint's rate told back on a feedback
/// endpoint), the device following the stream, the bus's frames.
pub const USB_ENDPOINT_SYNCTYPE_MASK: u8 = 0x0C;
pub const USB_ENDPOINT_SYNC_NONE: u8 = 0x00;
pub const USB_ENDPOINT_SYNC_ASYNC: u8 = 0x04;
pub const USB_ENDPOINT_SYNC_ADAPTIVE: u8 = 0x08;
pub const USB_ENDPOINT_SYNC_SYNC: u8 = 0x0C;

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

/// A SuperSpeed hub's descriptor: the same first fields, then its
/// latencies. Its ports carry only SuperSpeed; the hub's USB 2 half is a
/// hub of its own, on the USB 2 side of the same connector.
pub const SSHubDescriptor = extern struct {
    /// bDescLength: 12.
    length: u8 = 12,
    /// bDescriptorType: USB_DT_SS_HUB.
    descriptor_type: u8 = USB_DT_SS_HUB,
    /// bNbrPorts
    num_ports: u8 = 0,
    /// wHubCharacteristics: USB_HUB_CHAR_*.
    characteristics: u16 align(1) = 0,
    /// bPwrOn2PwrGood: in 2 ms.
    power_on_to_good: u8 = 0,
    /// bHubContrCurrent: in mA.
    controller_current: u8 = 0,
    /// bHubHdrDecLat, wHubDelay: its header decode latency and its delay
    /// in ns.
    header_latency: u8 = 0,
    hub_delay: u16 align(1) = 0,
    /// DeviceRemovable, a bit per port.
    removable: u16 align(1) = 0,
};

/// bDeviceProtocol of a hub: a SuperSpeed one.
pub const USB_HUB_PROTOCOL_SUPER: u8 = 3;
/// A SuperSpeed hub's class request: how many hubs are above it, 0 for
/// one on a root port - where its ports' devices' route strings go.
pub const USB_REQ_SET_HUB_DEPTH: u8 = 12;

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
/// A SuperSpeed hub's own: its link state, a link's change, a link that
/// could not be set up, the warm reset and its end.
pub const USB_PORT_FEAT_LINK_STATE: u16 = 5;
pub const USB_PORT_FEAT_C_PORT_LINK_STATE: u16 = 25;
pub const USB_PORT_FEAT_C_PORT_CONFIG_ERROR: u16 = 26;
pub const USB_PORT_FEAT_BH_PORT_RESET: u16 = 28;
pub const USB_PORT_FEAT_C_BH_PORT_RESET: u16 = 29;
/// A SuperSpeed hub's port's timeouts, set with SET_FEATURE, the value
/// in wIndex's high byte, the port in its low one: how long the link is
/// idle before the port takes it to U1 - in µs, at most
/// `USB_U1_TIMEOUT_MAX` - and on to U2, in 256 µs, at most
/// `USB_U2_TIMEOUT_MAX`.
pub const USB_PORT_FEAT_U1_TIMEOUT: u16 = 23;
pub const USB_PORT_FEAT_U2_TIMEOUT: u16 = 24;
pub const USB_U1_TIMEOUT_MAX: u8 = 0x7F;
pub const USB_U2_TIMEOUT_MAX: u8 = 0xFE;
/// A timeout's other values: the port never takes the link down, nor
/// lets the device; the port lets the device take it down, never itself.
pub const USB_LPM_TIMEOUT_OFF: u8 = 0;
pub const USB_LPM_TIMEOUT_ACCEPT: u8 = 0xFF;

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
/// What is on the port runs at SuperSpeed. Not a USB 2 hub's: the root
/// hubs say it so, and usb.library turns a SuperSpeed hub's status into
/// this form (`superPortStatus`).
pub const USB_PORT_STAT_SUPER_SPEED: u16 = 1 << 13;
// wPortChange
pub const USB_PORT_STAT_C_CONNECTION: u16 = 1 << 0;
pub const USB_PORT_STAT_C_ENABLE: u16 = 1 << 1;
pub const USB_PORT_STAT_C_SUSPEND: u16 = 1 << 2;
pub const USB_PORT_STAT_C_OVERCURRENT: u16 = 1 << 3;
pub const USB_PORT_STAT_C_RESET: u16 = 1 << 4;

// A SuperSpeed hub's wPortStatus: connection, enable, over-current and
// reset as above; the link's state, power and speed its own.
pub const USB_SS_PORT_STAT_LINK_STATE_SHIFT = 5;
pub const USB_SS_PORT_STAT_LINK_STATE: u16 = 0xF << USB_SS_PORT_STAT_LINK_STATE_SHIFT;
pub const USB_SS_PORT_STAT_POWER: u16 = 1 << 9;
// Its wPortChange: connection, over-current and reset as above; then a
// warm reset's end, a link's change, and a link that could not be set up.
pub const USB_SS_PORT_STAT_C_BH_RESET: u16 = 1 << 5;
pub const USB_SS_PORT_STAT_C_LINK_STATE: u16 = 1 << 6;
pub const USB_SS_PORT_STAT_C_CONFIG_ERROR: u16 = 1 << 7;
/// A SuperSpeed link's states: working, suspended, off, looking for a
/// device, failed, training, held in compliance mode. A port in
/// SS.Inactive or compliance mode takes a warm reset.
pub const USB_SS_LINK_U0: u16 = 0;
pub const USB_SS_LINK_U3: u16 = 3;
pub const USB_SS_LINK_DISABLED: u16 = 4;
pub const USB_SS_LINK_RX_DETECT: u16 = 5;
pub const USB_SS_LINK_INACTIVE: u16 = 6;
pub const USB_SS_LINK_POLLING: u16 = 7;
pub const USB_SS_LINK_COMPLIANCE: u16 = 10;

/// A SuperSpeed hub's port status in the USB 2 form the library works
/// with: its speed USB_PORT_STAT_SUPER_SPEED, a suspended link
/// USB_PORT_STAT_SUSPEND; a link's change as C_SUSPEND, a link that could
/// not be set up as C_ENABLE, a warm reset's end as C_RESET.
pub fn superPortStatus(raw: PortStatus) PortStatus {
    const kept_status = USB_PORT_STAT_CONNECTION | USB_PORT_STAT_ENABLE | USB_PORT_STAT_OVERCURRENT | USB_PORT_STAT_RESET;
    var status: u16 = raw.status & kept_status;
    if (raw.status & USB_SS_PORT_STAT_POWER != 0) status |= USB_PORT_STAT_POWER;
    if (superLinkState(raw.status) == USB_SS_LINK_U3) status |= USB_PORT_STAT_SUSPEND;
    if (raw.status & USB_PORT_STAT_CONNECTION != 0) status |= USB_PORT_STAT_SUPER_SPEED;
    const kept_change = USB_PORT_STAT_C_CONNECTION | USB_PORT_STAT_C_OVERCURRENT | USB_PORT_STAT_C_RESET;
    var change: u16 = raw.change & kept_change;
    if (raw.change & USB_SS_PORT_STAT_C_BH_RESET != 0) change |= USB_PORT_STAT_C_RESET;
    if (raw.change & USB_SS_PORT_STAT_C_LINK_STATE != 0) change |= USB_PORT_STAT_C_SUSPEND;
    if (raw.change & USB_SS_PORT_STAT_C_CONFIG_ERROR != 0) change |= USB_PORT_STAT_C_ENABLE;
    return .{ .status = status, .change = change };
}

/// A SuperSpeed hub's port's link state, from its wPortStatus.
pub fn superLinkState(status: u16) u16 {
    return (status & USB_SS_PORT_STAT_LINK_STATE) >> USB_SS_PORT_STAT_LINK_STATE_SHIFT;
}

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

// --- communications (CDC) ---------------------------------------------------------

/// A class-specific interface descriptor: CDC's functional descriptors,
/// after the interface they describe.
pub const USB_DT_CS_INTERFACE: u8 = 0x24;
/// bInterfaceSubClass of a communications interface: a serial line
/// (Abstract Control Model), Ethernet (Ethernet Control Model).
pub const CDC_SUBCLASS_ACM: u8 = 0x02;
pub const CDC_SUBCLASS_ECM: u8 = 0x06;
/// A functional descriptor's bDescriptorSubtype: the union of a control
/// interface and the data interfaces it drives; Ethernet's (the MAC
/// address string, the largest frame).
pub const CDC_FD_UNION: u8 = 0x06;
pub const CDC_FD_ETHERNET: u8 = 0x0F;
/// Class requests: a serial line's coding, its DTR and RTS, a break.
pub const CDC_REQ_SET_LINE_CODING: u8 = 0x20;
pub const CDC_REQ_SET_CONTROL_LINE_STATE: u8 = 0x22;
pub const CDC_REQ_SEND_BREAK: u8 = 0x23;
/// Class request: which frames an Ethernet function passes up.
pub const CDC_REQ_SET_ETHERNET_PACKET_FILTER: u8 = 0x43;
/// Notifications on the control interface's interrupt endpoint, each an
/// 8-byte header (bNotification at 1, wValue at 2) and its data.
pub const CDC_NOTIFY_NETWORK_CONNECTION: u8 = 0x00;
pub const CDC_NOTIFY_SERIAL_STATE: u8 = 0x20;
pub const CDC_NOTIFY_SPEED_CHANGE: u8 = 0x2A;

// --- audio ----------------------------------------------------------------------

/// bInterfaceSubClass of an audio interface: the one that controls the
/// function (its terminals and units), and one a stream goes over.
pub const AUDIO_SUBCLASS_CONTROL: u8 = 0x01;
pub const AUDIO_SUBCLASS_STREAMING: u8 = 0x02;
/// A class-specific endpoint descriptor, after the endpoint it describes.
pub const USB_DT_CS_ENDPOINT: u8 = 0x25;
/// A control interface's descriptors' bDescriptorSubtype: its header, a
/// terminal a stream comes in by or goes out by, a feature unit (mute,
/// volume) between them.
pub const UAC_HEADER: u8 = 0x01;
pub const UAC_INPUT_TERMINAL: u8 = 0x02;
pub const UAC_OUTPUT_TERMINAL: u8 = 0x03;
pub const UAC_FEATURE_UNIT: u8 = 0x06;
/// A streaming interface's: the terminal it is linked to and its format
/// tag, then the format's own descriptor.
pub const UAC_AS_GENERAL: u8 = 0x01;
pub const UAC_FORMAT_TYPE: u8 = 0x02;
/// A streaming endpoint's: which controls it has (UAC_EP_SAMPLING_FREQ).
pub const UAC_EP_GENERAL: u8 = 0x01;
/// wFormatTag: linear PCM, two's complement, little-endian; bFormatType:
/// type I, a frame of samples a channel.
pub const UAC_FORMAT_PCM: u16 = 0x0001;
pub const UAC_FORMAT_TYPE_I: u8 = 0x01;
/// Class requests: set a control's value, read its lowest and highest.
pub const UAC_SET_CUR: u8 = 0x01;
pub const UAC_GET_MIN: u8 = 0x82;
pub const UAC_GET_MAX: u8 = 0x83;
/// A feature unit's controls (wValue's high byte, and bits of bmaControls
/// from bit 0): mute, volume - in 1/256 dB, signed.
pub const UAC_FU_MUTE: u8 = 0x01;
pub const UAC_FU_VOLUME: u8 = 0x02;
/// An endpoint's control: its sampling rate, three bytes.
pub const UAC_EP_SAMPLING_FREQ: u8 = 0x01;

// --- mass storage -----------------------------------------------------------------

/// bInterfaceSubClass: the command set is SCSI's, transparent.
pub const MSC_SUBCLASS_SCSI: u8 = 0x06;
/// bInterfaceProtocol: Bulk-Only Transport - a command block, the data,
/// a status, each on a bulk endpoint.
pub const MSC_PROTOCOL_BULK_ONLY: u8 = 0x50;
/// Bulk-Only's class requests: the interface reset, and the highest
/// logical unit number.
pub const MSC_REQ_RESET: u8 = 0xFF;
pub const MSC_REQ_GET_MAX_LUN: u8 = 0xFE;
/// bInterfaceProtocol: USB Attached SCSI - commands, status and data
/// each on a bulk pipe of their own, with streams at SuperSpeed.
pub const MSC_PROTOCOL_UAS: u8 = 0x62;
/// UAS's Pipe Usage descriptor, after each of its endpoints: bLength 4,
/// this type, the pipe's ID, a reserved byte.
pub const MSC_DT_PIPE_USAGE: u8 = 0x24;
/// The Pipe Usage descriptor's IDs: the command pipe (out), the status
/// pipe (in), the data-in and the data-out pipes.
pub const MSC_PIPE_COMMAND: u8 = 1;
pub const MSC_PIPE_STATUS: u8 = 2;
pub const MSC_PIPE_DATA_IN: u8 = 3;
pub const MSC_PIPE_DATA_OUT: u8 = 4;

comptime {
    if (@sizeOf(SetupPacket) != 8 or @sizeOf(DeviceDescriptor) != 18 or
        @sizeOf(ConfigDescriptor) != 9 or @sizeOf(InterfaceDescriptor) != 9 or
        @sizeOf(EndpointDescriptor) != 7 or @sizeOf(HubDescriptor) != 9 or
        @sizeOf(PortStatus) != 4 or @sizeOf(SelData) != 6 or
        @sizeOf(BosDescriptor) != 5 or @sizeOf(SSUsbCapability) != 10)
        @compileError("a USB descriptor's layout is not what goes on the wire");
}
