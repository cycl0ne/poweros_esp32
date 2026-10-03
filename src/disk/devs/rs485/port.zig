// SPDX-License-Identifier: MIT
//! The UART behind rs485.device: UART1, in its RS-485 mode, with the
//! receive time-out ending each frame.
//!
//! **Receiving.** The FIFO raises an interrupt at 64 bytes and when the
//! line has been quiet for the gap with bytes in it. Either way the
//! interrupt moves the bytes into the frame being received; at 64 it
//! leaves the last one in the FIFO, because the quiet-line interrupt
//! comes only for a FIFO that holds something, and a frame whose bytes
//! had all been taken would never be closed. The quiet line closes the
//! frame. A parity or framing error marks the frame it came in.
//!
//! **Sending.** The task puts as much of a frame into the FIFO as fits;
//! the interrupt tops it up each time it runs down to 32 bytes, which at
//! the fastest rate is a few milliseconds' warning. TX_DONE comes when
//! the last bit has left with nothing more to send, and the frame is
//! sent.
//!
//! In RS-485 mode with RS485TX_RX_EN clear the receiver takes nothing in
//! while the transmitter sends, so a transceiver that hears itself gives
//! no echo.

const sdk = @import("sdk");
const exec = sdk.exec;
const hardware = sdk.hardware;
const uart = hardware.uart;
const reg = hardware.mmio.reg;
const pads = hardware.gpio;
const rs485 = sdk.devices.rs485;
const _rs485 = @import("_rs485.zig");
const Work = _rs485.Work;
const RS485Base = _rs485.RS485Base;
const Line = _rs485.Line;
const ExecBase = sdk.interface.exec.ExecBase;

/// The UART the port runs on.
pub const port: uart.Port = .uart1;

/// UART1's signals in the GPIO matrix (U1TXD_OUT_IDX, U1RXD_IN_IDX).
const signal_tx: u32 = 15;
const signal_rx: u32 = 15;

/// Where the FIFOs raise their interrupts.
const rx_threshold: u32 = 64;
const tx_threshold: u32 = 32;

const rx_ints = uart.INT_RXFIFO_FULL | uart.INT_RXFIFO_TOUT | uart.INT_PARITY_ERR |
    uart.INT_FRM_ERR | uart.INT_RXFIFO_OVF;

fn r(offset: usize) *volatile u32 {
    return reg(uart.baseOf(@intFromEnum(port)) + offset);
}

/// The interrupt source to hook.
pub fn source() u32 {
    return port.source();
}

/// The UART up, on the pads, in RS-485 mode with the line given; the
/// receive interrupts on. The source is hooked by the caller first.
pub fn start(tx_pad: u8, rx_pad: u8, line: Line) void {
    uart.setUp(port);
    pads.toMatrix(tx_pad);
    pads.outputEnable(tx_pad, true);
    pads.connectOut(tx_pad, signal_tx, false);
    pads.toMatrix(rx_pad);
    pads.inputEnable(rx_pad, true);
    pads.pullUp(rx_pad, true);
    pads.connectIn(signal_rx, rx_pad);

    r(uart.RS485_CONF).* = (r(uart.RS485_CONF).* & ~uart.RS485TX_RX_EN) | uart.RS485_EN | uart.RS485RXBY_TX_EN;
    _ = setLine(line);
    var conf1 = r(uart.CONF1).* & ~(uart.CONF1_RXFIFO_FULL_THRHD | uart.CONF1_TXFIFO_EMPTY_THRHD);
    conf1 |= rx_threshold | tx_threshold << uart.CONF1_TXFIFO_EMPTY_THRHD_SHIFT | uart.CONF1_RX_TOUT_EN;
    r(uart.CONF1).* = conf1;
    drain();
    r(uart.INT_CLR).* = 0xFFFF_FFFF;
    r(uart.INT_ENA).* = rx_ints;
}

/// Every interrupt off, for good.
pub fn stop() void {
    r(uart.INT_ENA).* = 0;
    r(uart.INT_CLR).* = 0xFFFF_FFFF;
}

/// Bits a character takes on the wire: start, data, parity, stop.
fn characterBits(line: Line) u32 {
    return 1 + @as(u32, line.data_bits) + @as(u32, if (line.parity != rs485.RS485_PARITY_NONE) 1 else 0) + line.stop_bits;
}

/// The gap in bit times, or null when the UART cannot time it.
pub fn gapBits(line: Line) ?u32 {
    const bits = (line.gap * characterBits(line) + 9) / 10;
    if (bits == 0 or bits > uart.MEM_CONF_RX_TOUT_THRHD >> uart.MEM_CONF_RX_TOUT_THRHD_SHIFT) return null;
    return bits;
}

/// Whether the UART can have this line.
pub fn valid(line: Line) bool {
    if (line.baud < 300 or line.baud > 5_000_000) return false;
    if (line.data_bits < 5 or line.data_bits > 8) return false;
    if (line.parity > rs485.RS485_PARITY_ODD) return false;
    if (line.stop_bits != 1 and line.stop_bits != 2) return false;
    return gapBits(line) != null;
}

/// The line and the gap set, once the last byte has left. False, and
/// nothing changed, for one the UART cannot have.
pub fn setLine(line: Line) bool {
    if (!valid(line)) return false;
    uart.setLine(port, .{
        .baud = line.baud,
        .bits = line.data_bits,
        .parity = switch (line.parity) {
            rs485.RS485_PARITY_EVEN => .even,
            rs485.RS485_PARITY_ODD => .odd,
            else => .none,
        },
        .stop_bits = line.stop_bits,
        .xon_xoff = false,
        .xon = 0x11,
        .xoff = 0x13,
    });
    const mem = r(uart.MEM_CONF).* & ~uart.MEM_CONF_RX_TOUT_THRHD;
    r(uart.MEM_CONF).* = mem | gapBits(line).? << uart.MEM_CONF_RX_TOUT_THRHD_SHIFT;
    return true;
}

/// Whatever is in the receive FIFO, thrown away.
fn drain() void {
    while (uart.read(port)) |_| {}
}

fn rxCount() u32 {
    return r(uart.STATUS).* & uart.STATUS_RXFIFO_CNT;
}

fn txRoom() u32 {
    const used = (r(uart.STATUS).* & uart.STATUS_TXFIFO_CNT) >> uart.STATUS_TXFIFO_CNT_SHIFT;
    return uart.FIFO_LEN - 1 - @min(used, uart.FIFO_LEN - 1);
}

/// As much of the frame being sent as the FIFO takes.
fn fill(work: *Work) void {
    var room = txRoom();
    while (room > 0 and work.send_left > 0) : (room -= 1) {
        r(uart.FIFO).* = work.send_data.?[0];
        work.send_data = work.send_data.? + 1;
        work.send_left -= 1;
    }
}

/// A frame onto the wire: the FIFO filled, the interrupts that keep it
/// filled and say when it is out turned on. Called by the task, with
/// nothing being sent.
pub fn send(work: *Work, sys: *ExecBase, data: [*]const u8, length: u32) void {
    sys.Disable();
    defer sys.Enable();
    work.send_data = data;
    work.send_left = length;
    r(uart.INT_CLR).* = uart.INT_TX_DONE | uart.INT_TXFIFO_EMPTY;
    fill(work);
    var enable = r(uart.INT_ENA).* | uart.INT_TX_DONE;
    if (work.send_left > 0) enable |= uart.INT_TXFIFO_EMPTY;
    r(uart.INT_ENA).* = enable;
}

/// The bytes waiting in the FIFO into the frame being received; all of
/// them when `all`, else all but the last.
fn take(work: *Work, all: bool) void {
    var count = rxCount();
    if (!all and count > 0) count -= 1;
    while (count > 0) : (count -= 1) {
        const byte: u8 = @truncate(r(uart.FIFO).*);
        if (work.dropping != 0) continue;
        if (work.receiving == 0) {
            if (work.kept == _rs485.slot_count) {
                work.dropping = 1;
                continue;
            }
            work.receiving = 1;
            const slot = &work.slots[(work.first + work.kept) % _rs485.slot_count];
            slot.length = 0;
            slot.flags = 0;
        }
        const slot = &work.slots[(work.first + work.kept) % _rs485.slot_count];
        if (slot.length == slot.bytes.len) {
            slot.flags |= _rs485.FRAME_OVERFLOW;
            continue;
        }
        slot.bytes[slot.length] = byte;
        slot.length += 1;
    }
}

/// The frame being received, closed: kept, or dropped if it had no slot.
fn close(work: *Work) bool {
    if (work.dropping != 0) {
        work.dropping = 0;
        work.dropped += 1;
        return false;
    }
    if (work.receiving == 0) return false;
    work.receiving = 0;
    work.kept += 1;
    return true;
}

fn mark(work: *Work, flags: u8) void {
    if (work.receiving == 0 or work.dropping != 0) return;
    work.slots[(work.first + work.kept) % _rs485.slot_count].flags |= flags;
}

/// The UART's interrupt: bytes in, the frame closed on a quiet line,
/// the FIFO topped up, the end of a frame sent. The task is signalled
/// when a frame was kept or sent.
pub fn intServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const base: *RS485Base = @ptrCast(@alignCast(is_data.?));
    const work = base.work orelse return 0;
    const raised = r(uart.INT_ST).*;
    if (raised == 0) return 0;
    r(uart.INT_CLR).* = raised;
    var events: u32 = 0;

    if (raised & (uart.INT_PARITY_ERR | uart.INT_FRM_ERR | uart.INT_RXFIFO_OVF) != 0) {
        take(work, false);
        if (raised & uart.INT_PARITY_ERR != 0) mark(work, _rs485.FRAME_PARITY);
        if (raised & uart.INT_FRM_ERR != 0) mark(work, _rs485.FRAME_FRAMING);
        if (raised & uart.INT_RXFIFO_OVF != 0) mark(work, _rs485.FRAME_OVERFLOW);
    }
    if (raised & uart.INT_RXFIFO_TOUT != 0) {
        take(work, true);
        if (close(work)) events |= _rs485.EVENT_FRAME;
    } else if (raised & uart.INT_RXFIFO_FULL != 0) {
        take(work, false);
    }

    if (raised & uart.INT_TXFIFO_EMPTY != 0) {
        fill(work);
        if (work.send_left == 0) r(uart.INT_ENA).* &= ~uart.INT_TXFIFO_EMPTY;
    }
    if (raised & uart.INT_TX_DONE != 0) {
        if (work.send_left == 0) {
            r(uart.INT_ENA).* &= ~(uart.INT_TX_DONE | uart.INT_TXFIFO_EMPTY);
            work.send_data = null;
            events |= _rs485.EVENT_SENT;
        } else fill(work);
    }

    if (events != 0) {
        work.events |= events;
        base.sys_base.Signal(&base.task, base.int_mask);
    }
    return 1;
}
