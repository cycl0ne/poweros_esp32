// SPDX-License-Identifier: MIT
//! A register by its address, and a register by its **port**.
//!
//! This machine has two spaces where the others have one. Memory-mapped
//! registers are read and written as everywhere else - the local and the
//! I/O interrupt controller, and whatever is behind the PCI bridge, live
//! there - and a volatile pointer of the register's own width is what
//! device memory takes.
//!
//! Beside that is the I/O port space, which only this architecture has: a
//! separate 16-bit address space reached with `in` and `out` rather than
//! with a load and a store. The machine's oldest parts are in it, and two
//! of them matter here - the serial port the console is on, and the
//! register that resets the machine. A port access is ordered against
//! memory by the instruction itself, so none of them wants a fence.

pub inline fn reg(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}

pub inline fn reg8(addr: usize) *volatile u8 {
    return @ptrFromInt(addr);
}

pub inline fn reg16(addr: usize) *volatile u16 {
    return @ptrFromInt(addr);
}

pub inline fn reg64(addr: usize) *volatile u64 {
    return @ptrFromInt(addr);
}

// --- the port space ----------------------------------------------------------------

/// `N{dx}` lets a port below 256 be an immediate in the instruction and
/// puts a higher one in DX, which is the only register `in` and `out` take
/// for an address.
pub inline fn in8(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

pub inline fn out8(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}

pub inline fn in16(port: u16) u16 {
    return asm volatile ("inw %[port], %[result]"
        : [result] "={ax}" (-> u16),
        : [port] "N{dx}" (port),
    );
}

pub inline fn out16(port: u16, value: u16) void {
    asm volatile ("outw %[value], %[port]"
        :
        : [value] "{ax}" (value),
          [port] "N{dx}" (port),
    );
}

pub inline fn in32(port: u16) u32 {
    return asm volatile ("inl %[port], %[result]"
        : [result] "={eax}" (-> u32),
        : [port] "N{dx}" (port),
    );
}

pub inline fn out32(port: u16, value: u32) void {
    asm volatile ("outl %[value], %[port]"
        :
        : [value] "{eax}" (value),
          [port] "N{dx}" (port),
    );
}
