/* SPDX-License-Identifier: MPL-2.0 */
/*
 * Where the ROM hands over: core 0, at _start, with the image's RAM
 * segments loaded and the second core waiting in the ROM.
 *
 * The stack is set to the kernel's own, interrupts are masked, the FPU is
 * switched on (a floating-point instruction traps while mstatus.FS is
 * off), .bss is cleared, a trap goes to kernel_trap, and kmain runs.
 */

    .section .text.start, "ax"
    .global _start
_start:
    csrci   mstatus, 0x8            /* MIE off */
    li      t0, 0x2000
    csrs    mstatus, t0             /* FS = initial: the FPU on */
    la      sp, _stack_top

    la      a0, _bss_start
    la      a1, _bss_end
1:  bgeu    a0, a1, 2f
    sw      zero, 0(a0)
    addi    a0, a0, 4
    j       1b
2:
    la      t0, trap_entry
    csrw    mtvec, t0               /* direct mode: every trap here */
    call    kmain
3:  wfi
    j       3b

/* A trap: its cause, where, and its value, to kernel_trap, which does not
   return. On whatever stack the trap came on. */
    .align  2
trap_entry:
    csrr    a0, mcause
    csrr    a1, mepc
    csrr    a2, mtval
    call    kernel_trap
4:  wfi
    j       4b
