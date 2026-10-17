/* SPDX-License-Identifier: MPL-2.0 */
/*
 * The entry points of a RISC-V 64 machine under SBI firmware: where the
 * firmware hands over, the trap entry, and a call on another stack.
 *
 * The firmware (OpenSBI on QEMU, U-Boot's booti on the VisionFive 2)
 * enters _start in supervisor mode on the boot hart, with a0 its hart id
 * and a1 the device tree, at the address the kernel is linked at. The
 * image starts with the 64-byte header of a RISC-V Linux `Image`, which
 * booti wants: a jump past it, where U-Boot puts the image (text_offset,
 * from the start of RAM) and how much memory it takes (image_size, its
 * .bss and boot stack too), and the magic. kernel.ld works the two out.
 *
 * Only the first hart to arrive goes on; one that comes after it - a
 * U-Boot built for SMP sends every hart it has - is stopped (SBI HSM),
 * where the kernel can start it again. The first masks the hart's
 * interrupts, switches the FPU on (a floating-point instruction traps
 * while sstatus.FS is off), makes the hart core 0 (tp, cpu.zig), clears
 * .bss, points stvec at the trap entry and calls kmain(hartid, fdt).
 *
 * Every trap - an exception, an interrupt, the kernel's syscall (an
 * ebreak; ecall is the firmware's) - comes to _trap_entry on the stack it
 * interrupted, and is saved into a `trap.Frame` right below that stack
 * pointer: the integer registers, the trap's CSRs, and the FPU's
 * registers when the interrupted code has used the FPU (sstatus.FS clean
 * or dirty) - code that never has pays nothing for it. riscv_exception
 * (trap.zig) answers the frame to resume: the same one, or another task's
 * when exec switched tasks. sstatus, written back from the resumed frame,
 * gives sret its privilege and interrupt state. tp is the core's number,
 * not the task's, and is not reloaded.
 */

#define F_X(n)          (8 * (n))
#define F_SEPC          256
#define F_SSTATUS       264
#define F_SCAUSE        272
#define F_STVAL         280
#define F_FPU           288
#define F_FCSR          296
#define F_F(n)          (304 + 8 * (n))
#define FRAME_SIZE      560

/* exec's max_cores, and a stack of each one's own for a trap that came
   on a stack with no room. */
#define MAX_CORES       2
#define FAULT_STACK_SIZE 2048

#define SSTATUS_SIE     0x2
#define SSTATUS_FS_INITIAL 0x2000

/* SBI's hart state management extension, and its hart_stop. */
#define SBI_EXT_HSM     0x48534D
#define SBI_HSM_STOP    1

    .option norelax
    .section .text.start, "ax"
    .global _start
    .type _start, @function
_start:
    /* The Image header (Linux's Documentation/arch/riscv/boot-image-header.rst),
       with a four-byte jump: no compressed instruction may shift it. */
    .option push
    .option norvc
    j       _boot                   /* code0 */
    .word   0                       /* code1 */
    .dword  _image_text_offset      /* where in RAM it goes */
    .dword  _image_size             /* how much it takes there */
    .dword  0                       /* flags: little-endian */
    .word   2                       /* header version 0.2 */
    .word   0
    .dword  0
    .ascii  "RISCV\0\0\0"          /* the old magic */
    .ascii  "RSC\x05"               /* the magic booti checks */
    .word   0
    .option pop

_boot:
    /* The first hart here goes on; any other is handed back to the
       firmware, stopped. */
    la      t0, _boot_claimed
    li      t1, 1
    amoswap.w t1, t1, (t0)
    bnez    t1, _boot_other
    csrci   sstatus, SSTATUS_SIE
    csrw    sie, zero
    li      t0, SSTATUS_FS_INITIAL
    csrs    sstatus, t0
    la      sp, _stack_top
    li      tp, 0                   /* core 0 */
    mv      s0, a0
    mv      s1, a1

    la      a0, _bss_start
    la      a1, _bss_end
1:  bgeu    a0, a1, 2f
    sd      zero, 0(a0)
    addi    a0, a0, 8
    j       1b
2:
    la      t0, _trap_entry
    csrw    stvec, t0               /* direct mode */
    li      ra, 0                   /* terminates backtraces */
    mv      a0, s0
    mv      a1, s1
    li      s0, 0
    call    kmain
3:  wfi
    j       3b

_boot_other:
    csrci   sstatus, SSTATUS_SIE
    csrw    sie, zero
    li      a7, SBI_EXT_HSM
    li      a6, SBI_HSM_STOP
    ecall
4:  wfi                             /* the firmware would not stop it */
    j       4b
    .size _start, . - _start

    /* Set by the first hart through _boot: in .data, which _start does
       not clear. */
    .section .data
    .balign 4
_boot_claimed:
    .word   0

/*
 * The trap entry: stvec's base, so on 4 bytes. Every exception and every
 * interrupt comes here, with this hart's interrupts masked (SIE off).
 */
    .section .text.trap, "ax"
    .balign 64
    .global _trap_entry
    .type _trap_entry, @function
_trap_entry:
    /* The stack it came on must be in RAM with room for the frame: a
       task that ran off its stack would otherwise have every trap from
       here on push its frame further into nothing. One that has no room
       goes to riscv_stack_fault (trap.zig) on a stack of its core's own,
       with what can be saved of where it was. The bounds are the RAM's
       (rv_stack_low already above its start by a frame), which the kernel
       sets as it starts. */
    csrw    sscratch, t0
    la      t0, rv_stack_low
    ld      t0, 0(t0)
    bltu    sp, t0, _trap_bad_stack
    la      t0, rv_stack_high
    ld      t0, 0(t0)
    bgeu    sp, t0, _trap_bad_stack
    csrr    t0, sscratch
    addi    sp, sp, -FRAME_SIZE
    sd      x1, F_X(1)(sp)
    sd      x3, F_X(3)(sp)
    sd      x4, F_X(4)(sp)
    sd      x5, F_X(5)(sp)
    sd      x6, F_X(6)(sp)
    sd      x7, F_X(7)(sp)
    sd      x8, F_X(8)(sp)
    sd      x9, F_X(9)(sp)
    sd      x10, F_X(10)(sp)
    sd      x11, F_X(11)(sp)
    sd      x12, F_X(12)(sp)
    sd      x13, F_X(13)(sp)
    sd      x14, F_X(14)(sp)
    sd      x15, F_X(15)(sp)
    sd      x16, F_X(16)(sp)
    sd      x17, F_X(17)(sp)
    sd      x18, F_X(18)(sp)
    sd      x19, F_X(19)(sp)
    sd      x20, F_X(20)(sp)
    sd      x21, F_X(21)(sp)
    sd      x22, F_X(22)(sp)
    sd      x23, F_X(23)(sp)
    sd      x24, F_X(24)(sp)
    sd      x25, F_X(25)(sp)
    sd      x26, F_X(26)(sp)
    sd      x27, F_X(27)(sp)
    sd      x28, F_X(28)(sp)
    sd      x29, F_X(29)(sp)
    sd      x30, F_X(30)(sp)
    sd      x31, F_X(31)(sp)
    addi    t0, sp, FRAME_SIZE
    sd      t0, F_X(2)(sp)          /* the interrupted stack pointer */
    sd      zero, F_X(0)(sp)
    csrr    t0, sepc
    sd      t0, F_SEPC(sp)
    csrr    t0, scause
    sd      t0, F_SCAUSE(sp)
    csrr    t0, stval
    sd      t0, F_STVAL(sp)
    csrr    t0, sstatus
    sd      t0, F_SSTATUS(sp)

    /* The FPU's registers, if the interrupted code has used it: FS (bits
       13-14) 2 or 3. */
    srli    t1, t0, 14
    andi    t1, t1, 1
    sd      t1, F_FPU(sp)
    beqz    t1, 5f
    fsd     f0, F_F(0)(sp)
    fsd     f1, F_F(1)(sp)
    fsd     f2, F_F(2)(sp)
    fsd     f3, F_F(3)(sp)
    fsd     f4, F_F(4)(sp)
    fsd     f5, F_F(5)(sp)
    fsd     f6, F_F(6)(sp)
    fsd     f7, F_F(7)(sp)
    fsd     f8, F_F(8)(sp)
    fsd     f9, F_F(9)(sp)
    fsd     f10, F_F(10)(sp)
    fsd     f11, F_F(11)(sp)
    fsd     f12, F_F(12)(sp)
    fsd     f13, F_F(13)(sp)
    fsd     f14, F_F(14)(sp)
    fsd     f15, F_F(15)(sp)
    fsd     f16, F_F(16)(sp)
    fsd     f17, F_F(17)(sp)
    fsd     f18, F_F(18)(sp)
    fsd     f19, F_F(19)(sp)
    fsd     f20, F_F(20)(sp)
    fsd     f21, F_F(21)(sp)
    fsd     f22, F_F(22)(sp)
    fsd     f23, F_F(23)(sp)
    fsd     f24, F_F(24)(sp)
    fsd     f25, F_F(25)(sp)
    fsd     f26, F_F(26)(sp)
    fsd     f27, F_F(27)(sp)
    fsd     f28, F_F(28)(sp)
    fsd     f29, F_F(29)(sp)
    fsd     f30, F_F(30)(sp)
    fsd     f31, F_F(31)(sp)
    frcsr   t1
    sd      t1, F_FCSR(sp)
5:
    mv      a0, sp
    call    riscv_exception         /* a0 = the frame to resume */
    beq     a0, sp, .Lresume

    /* A task switch: onto the other task's stack. Off the task left, and
       nothing of it in the registers: another core may resume it now
       (context.zig, task_leaving[core] = 0). */
    mv      sp, a0
    slli    t0, tp, 3
    la      t1, task_leaving
    add     t1, t1, t0
    fence   rw, w
    sd      zero, 0(t1)
    fence   rw, rw

.Lresume:
    ld      t0, F_FPU(sp)
    beqz    t0, 6f
    fld     f0, F_F(0)(sp)
    fld     f1, F_F(1)(sp)
    fld     f2, F_F(2)(sp)
    fld     f3, F_F(3)(sp)
    fld     f4, F_F(4)(sp)
    fld     f5, F_F(5)(sp)
    fld     f6, F_F(6)(sp)
    fld     f7, F_F(7)(sp)
    fld     f8, F_F(8)(sp)
    fld     f9, F_F(9)(sp)
    fld     f10, F_F(10)(sp)
    fld     f11, F_F(11)(sp)
    fld     f12, F_F(12)(sp)
    fld     f13, F_F(13)(sp)
    fld     f14, F_F(14)(sp)
    fld     f15, F_F(15)(sp)
    fld     f16, F_F(16)(sp)
    fld     f17, F_F(17)(sp)
    fld     f18, F_F(18)(sp)
    fld     f19, F_F(19)(sp)
    fld     f20, F_F(20)(sp)
    fld     f21, F_F(21)(sp)
    fld     f22, F_F(22)(sp)
    fld     f23, F_F(23)(sp)
    fld     f24, F_F(24)(sp)
    fld     f25, F_F(25)(sp)
    fld     f26, F_F(26)(sp)
    fld     f27, F_F(27)(sp)
    fld     f28, F_F(28)(sp)
    fld     f29, F_F(29)(sp)
    fld     f30, F_F(30)(sp)
    fld     f31, F_F(31)(sp)
    ld      t1, F_FCSR(sp)
    fscsr   t1
    j       7f
6:  fscsr   zero                    /* code that has not used the FPU finds it as new */
7:
    ld      t0, F_SSTATUS(sp)
    csrw    sstatus, t0             /* the resumed frame's SPP, SPIE and FS */
    ld      t0, F_SEPC(sp)
    csrw    sepc, t0
    ld      x1, F_X(1)(sp)
    ld      x3, F_X(3)(sp)
    ld      x5, F_X(5)(sp)
    ld      x6, F_X(6)(sp)
    ld      x7, F_X(7)(sp)
    ld      x8, F_X(8)(sp)
    ld      x9, F_X(9)(sp)
    ld      x10, F_X(10)(sp)
    ld      x11, F_X(11)(sp)
    ld      x12, F_X(12)(sp)
    ld      x13, F_X(13)(sp)
    ld      x14, F_X(14)(sp)
    ld      x15, F_X(15)(sp)
    ld      x16, F_X(16)(sp)
    ld      x17, F_X(17)(sp)
    ld      x18, F_X(18)(sp)
    ld      x19, F_X(19)(sp)
    ld      x20, F_X(20)(sp)
    ld      x21, F_X(21)(sp)
    ld      x22, F_X(22)(sp)
    ld      x23, F_X(23)(sp)
    ld      x24, F_X(24)(sp)
    ld      x25, F_X(25)(sp)
    ld      x26, F_X(26)(sp)
    ld      x27, F_X(27)(sp)
    ld      x28, F_X(28)(sp)
    ld      x29, F_X(29)(sp)
    ld      x30, F_X(30)(sp)
    ld      x31, F_X(31)(sp)
    ld      sp, F_X(2)(sp)
    sret
    .size _trap_entry, . - _trap_entry

/*
 * A trap on a stack with no room: the stack pointer, where the trap came
 * from and why, the return address and the frame pointer to
 * riscv_stack_fault, on the core's fault stack. It does not come back.
 */
    .section .text.trap, "ax"
_trap_bad_stack:
    mv      a0, sp
    addi    t0, tp, 1
    slli    t0, t0, 11              /* (core + 1) * FAULT_STACK_SIZE */
    la      sp, riscv_fault_stacks
    add     sp, sp, t0
    csrr    a1, sepc
    csrr    a2, scause
    csrr    a3, stval
    mv      a4, ra
    mv      a5, s0
    call    riscv_stack_fault
2:  j       2b

    .section .bss
    .balign 16
    .global riscv_fault_stacks
riscv_fault_stacks:
    .space  MAX_CORES * FAULT_STACK_SIZE

/*
 * i32 riscv_call_on_stack(usize stack_upper, fn code, void *arg), for
 * exec's NewStackRun: code(arg) on the stack that ends at stack_upper
 * (rounded down to 16 bytes), and its answer. The caller's stack pointer
 * is kept in s0, which code saves and puts back as every callee does.
 */
    .section .text.riscv_call_on_stack, "ax"
    .global riscv_call_on_stack
    .type riscv_call_on_stack, @function
riscv_call_on_stack:
    addi    sp, sp, -16
    sd      ra, 8(sp)
    sd      s0, 0(sp)
    mv      s0, sp
    andi    sp, a0, -16
    mv      a0, a2
    jalr    a1
    mv      sp, s0
    ld      s0, 0(sp)
    ld      ra, 8(sp)
    addi    sp, sp, 16
    ret
    .size riscv_call_on_stack, . - riscv_call_on_stack
