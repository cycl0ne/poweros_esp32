// SPDX-License-Identifier: MIT
//! An xHCI controller's registers, its TRBs and its contexts, as the
//! eXtensible Host Controller Interface specification (revision 1.2)
//! lays them out: what the device's other files say in numbers.
//!
//! **Four blocks of registers** behind BAR0: the capability registers at
//! its start, which say where the others are; the operational registers
//! CAPLENGTH past it, with a block of four per root port at 0x400; the
//! runtime registers at RTSOFF, with interrupter 0 at 0x20; and the
//! doorbells at DBOFF, a word each - 0 the controller's, n slot n's.

// --- capability registers ---------------------------------------------------------

/// CAPLENGTH in its low byte, HCIVERSION in its top half.
pub const CAPLENGTH: usize = 0x00;
pub const HCSPARAMS1: usize = 0x04;
pub const HCSPARAMS2: usize = 0x08;
pub const HCCPARAMS1: usize = 0x10;
pub const DBOFF: usize = 0x14;
pub const RTSOFF: usize = 0x18;

/// HCSPARAMS1: the device slots, the interrupters and the root ports.
pub fn maxSlots(params1: u32) u32 {
    return params1 & 0xFF;
}
pub fn maxPorts(params1: u32) u32 {
    return params1 >> 24;
}

/// HCSPARAMS2: the scratchpad buffers the controller wants, split over
/// two fields.
pub fn scratchpads(params2: u32) u32 {
    return ((params2 >> 21) & 0x1F) << 5 | (params2 >> 27);
}

/// HCCPARAMS1: 64-bit addresses, 64-byte contexts, port power switches,
/// and where the extended capabilities start, in words.
pub const HCC_AC64: u32 = 1 << 0;
pub const HCC_CSZ: u32 = 1 << 2;
pub const HCC_PPC: u32 = 1 << 3;
pub fn extendedCaps(params1: u32) u32 {
    return params1 >> 16;
}

// --- operational registers --------------------------------------------------------

pub const USBCMD: usize = 0x00;
pub const USBSTS: usize = 0x04;
pub const PAGESIZE: usize = 0x08;
pub const CRCR: usize = 0x18;
pub const DCBAAP: usize = 0x30;
pub const CONFIG: usize = 0x38;
/// Root port n's PORTSC (n from 1).
pub fn portsc(port: u32) usize {
    return 0x400 + 0x10 * @as(usize, port - 1);
}

pub const USBCMD_RS: u32 = 1 << 0;
pub const USBCMD_HCRST: u32 = 1 << 1;
pub const USBCMD_INTE: u32 = 1 << 2;
pub const USBCMD_HSEE: u32 = 1 << 3;

pub const USBSTS_HCH: u32 = 1 << 0;
pub const USBSTS_HSE: u32 = 1 << 2;
pub const USBSTS_EINT: u32 = 1 << 3;
pub const USBSTS_PCD: u32 = 1 << 4;
pub const USBSTS_CNR: u32 = 1 << 11;
pub const USBSTS_HCE: u32 = 1 << 12;

/// CRCR: the ring's cycle state.
pub const CRCR_RCS: u32 = 1 << 0;

// PORTSC.
pub const PORT_CCS: u32 = 1 << 0;
pub const PORT_PED: u32 = 1 << 1;
pub const PORT_OCA: u32 = 1 << 3;
pub const PORT_PR: u32 = 1 << 4;
pub const PORT_PLS_SHIFT = 5;
pub const PORT_PLS_MASK: u32 = 0xF << PORT_PLS_SHIFT;
pub const PORT_PP: u32 = 1 << 9;
pub const PORT_SPEED_SHIFT = 10;
pub const PORT_SPEED_MASK: u32 = 0xF << PORT_SPEED_SHIFT;
pub const PORT_PIC_MASK: u32 = 3 << 14;
pub const PORT_CSC: u32 = 1 << 17;
pub const PORT_PEC: u32 = 1 << 18;
pub const PORT_WRC: u32 = 1 << 19;
pub const PORT_OCC: u32 = 1 << 20;
pub const PORT_PRC: u32 = 1 << 21;
pub const PORT_PLC: u32 = 1 << 22;
pub const PORT_CEC: u32 = 1 << 23;
pub const PORT_WAKE_MASK: u32 = 7 << 25;
pub const PORT_DR: u32 = 1 << 30;
/// Every change bit: written 1 to clear.
pub const PORT_CHANGES: u32 = PORT_CSC | PORT_PEC | PORT_WRC | PORT_OCC | PORT_PRC | PORT_PLC | PORT_CEC;
/// What a write keeps as it is: the read-only bits and the ones that
/// keep what is written. PED is not among them - a 1 there disables the
/// port - nor any change bit, nor PR.
pub const PORT_NEUTRAL: u32 = PORT_CCS | PORT_OCA | PORT_SPEED_MASK | PORT_DR |
    PORT_PLS_MASK | PORT_PP | PORT_PIC_MASK | PORT_WAKE_MASK;
/// PLS's U3: the port suspended.
pub const PLS_U3: u32 = 3;

/// A port's speed (PORTSC's, and a slot context's): the protocol's
/// default speed IDs.
pub const SPEED_FULL: u32 = 1;
pub const SPEED_LOW: u32 = 2;
pub const SPEED_HIGH: u32 = 3;
pub const SPEED_SUPER: u32 = 4;

// --- runtime registers ------------------------------------------------------------

/// Interrupter 0's registers, from the runtime block.
pub const IMAN: usize = 0x20;
pub const IMOD: usize = 0x24;
pub const ERSTSZ: usize = 0x28;
pub const ERSTBA: usize = 0x30;
pub const ERDP: usize = 0x38;

pub const IMAN_IP: u32 = 1 << 0;
pub const IMAN_IE: u32 = 1 << 1;
/// ERDP: the event handler is busy, written 1 to clear.
pub const ERDP_EHB: u32 = 1 << 3;

// --- extended capabilities --------------------------------------------------------

pub const EXT_LEGACY: u32 = 1;
pub const EXT_PROTOCOL: u32 = 2;
/// USBLEGSUP: who owns the controller.
pub const LEGACY_BIOS_OWNED: u32 = 1 << 16;
pub const LEGACY_OS_OWNED: u32 = 1 << 24;
/// USBLEGCTLSTS: its SMI enables cleared, its SMI events written 1 to
/// clear (as Linux's handoff writes it).
pub const LEGACY_DISABLE_SMI: u32 = (0x7 << 1) | (0xFF << 5) | (0x7 << 17);
pub const LEGACY_SMI_EVENTS: u32 = 0x7 << 29;

// --- TRBs -------------------------------------------------------------------------

/// A TRB's control word.
pub const TRB_CYCLE: u32 = 1 << 0;
/// A Link TRB's toggle cycle.
pub const TRB_TC: u32 = 1 << 1;
pub const TRB_ISP: u32 = 1 << 2;
pub const TRB_CHAIN: u32 = 1 << 4;
pub const TRB_IOC: u32 = 1 << 5;
pub const TRB_IDT: u32 = 1 << 6;
/// Address Device: block SET_ADDRESS. Configure Endpoint: deconfigure.
pub const TRB_BSR: u32 = 1 << 9;
pub const TRB_DC: u32 = 1 << 9;
/// A Data Stage TRB's direction: IN.
pub const TRB_DIR_IN: u32 = 1 << 16;
pub const TRB_TYPE_SHIFT = 10;

pub fn trbType(control: u32) u32 {
    return (control >> TRB_TYPE_SHIFT) & 0x3F;
}
pub fn typeField(kind: u32) u32 {
    return kind << TRB_TYPE_SHIFT;
}
pub fn slotField(slot: u32) u32 {
    return slot << 24;
}
pub fn endpointField(dci: u32) u32 {
    return dci << 16;
}

/// A Setup Stage TRB's transfer type: no data, OUT, IN.
pub const TRT_NONE: u32 = 0 << 16;
pub const TRT_OUT: u32 = 2 << 16;
pub const TRT_IN: u32 = 3 << 16;

pub const TRB_NORMAL: u32 = 1;
pub const TRB_SETUP: u32 = 2;
pub const TRB_DATA: u32 = 3;
pub const TRB_STATUS: u32 = 4;
pub const TRB_LINK: u32 = 6;
pub const TRB_NOOP: u32 = 8;
pub const TRB_ENABLE_SLOT: u32 = 9;
pub const TRB_DISABLE_SLOT: u32 = 10;
pub const TRB_ADDRESS_DEVICE: u32 = 11;
pub const TRB_CONFIGURE_ENDPOINT: u32 = 12;
pub const TRB_EVALUATE_CONTEXT: u32 = 13;
pub const TRB_RESET_ENDPOINT: u32 = 14;
pub const TRB_STOP_ENDPOINT: u32 = 15;
pub const TRB_SET_TR_DEQUEUE: u32 = 16;
pub const TRB_NOOP_COMMAND: u32 = 23;
pub const TRB_TRANSFER_EVENT: u32 = 32;
pub const TRB_COMMAND_COMPLETION: u32 = 33;
pub const TRB_PORT_STATUS_CHANGE: u32 = 34;
pub const TRB_HOST_CONTROLLER: u32 = 37;

/// An event's completion code, and a transfer event's bytes not moved.
pub fn completionCode(status: u32) u32 {
    return status >> 24;
}
pub fn residual(status: u32) u32 {
    return status & 0xFF_FFFF;
}
pub fn eventSlot(control: u32) u32 {
    return control >> 24;
}
pub fn eventEndpoint(control: u32) u32 {
    return (control >> 16) & 0x1F;
}
/// A Port Status Change Event's port, from its parameter's low word.
pub fn eventPort(param_lo: u32) u32 {
    return param_lo >> 24;
}

pub const CC_SUCCESS: u32 = 1;
pub const CC_DATA_BUFFER: u32 = 2;
pub const CC_BABBLE: u32 = 3;
pub const CC_TRANSACTION: u32 = 4;
pub const CC_TRB: u32 = 5;
pub const CC_STALL: u32 = 6;
pub const CC_RESOURCE: u32 = 7;
pub const CC_BANDWIDTH: u32 = 8;
pub const CC_NO_SLOTS: u32 = 9;
pub const CC_SHORT_PACKET: u32 = 13;
pub const CC_PARAMETER: u32 = 17;
pub const CC_CONTEXT_STATE: u32 = 19;
pub const CC_STOPPED: u32 = 26;
pub const CC_STOPPED_LENGTH_INVALID: u32 = 27;
pub const CC_STOPPED_SHORT_PACKET: u32 = 28;
pub const CC_SPLIT_TRANSACTION: u32 = 36;

// --- contexts ---------------------------------------------------------------------

/// The Input Control Context's words: what a command drops and adds.
pub const ICC_DROP = 0;
pub const ICC_ADD = 1;
/// The add flags of the slot context and of endpoint 0.
pub const ADD_SLOT: u32 = 1 << 0;
pub fn addFlag(dci: u32) u32 {
    return @as(u32, 1) << @intCast(dci);
}

/// Slot context, word 0: route string, speed, MTT, hub, context entries.
pub fn slotWord0(route: u32, speed: u32, hub: bool, entries: u32) u32 {
    return (route & 0xF_FFFF) | speed << 20 | @as(u32, @intFromBool(hub)) << 26 | entries << 27;
}
/// Word 1: the root port, and a hub's ports.
pub fn slotWord1(root_port: u32, ports: u32) u32 {
    return root_port << 16 | ports << 24;
}
/// Word 2: the transaction translator - its hub's slot and port - and a
/// high-speed hub's think time.
pub fn slotWord2(tt_slot: u32, tt_port: u32, ttt: u32) u32 {
    return tt_slot | tt_port << 8 | (ttt & 3) << 16;
}

/// An endpoint's type in its context.
pub const EP_ISOCH_OUT: u32 = 1;
pub const EP_BULK_OUT: u32 = 2;
pub const EP_INTERRUPT_OUT: u32 = 3;
pub const EP_CONTROL: u32 = 4;
pub const EP_ISOCH_IN: u32 = 5;
pub const EP_BULK_IN: u32 = 6;
pub const EP_INTERRUPT_IN: u32 = 7;

/// Endpoint context, word 0: the interval, as an exponent of 125 µs.
pub fn endpointWord0(interval: u32) u32 {
    return interval << 16;
}
/// Word 1: three tries on an error, the type, the burst, the packet size.
pub fn endpointWord1(kind: u32, burst: u32, max_packet: u32) u32 {
    return 3 << 1 | kind << 3 | burst << 8 | max_packet << 16;
}
/// Word 4: the average TRB length and the largest payload per service
/// interval.
pub fn endpointWord4(average: u32, esit: u32) u32 {
    return average | (esit & 0xFFFF) << 16;
}

/// A device context index: endpoint 0 is 1; endpoint n's OUT 2n, its IN
/// 2n + 1.
pub fn dciOf(endpoint_address: u8) u32 {
    const number: u32 = endpoint_address & 0x0F;
    if (number == 0) return 1;
    return number * 2 + @intFromBool(endpoint_address & 0x80 != 0);
}
