/* SPDX-License-Identifier: MPL-2.0 */
/*
 * The ESP32-P4's entry points: where the ROM hands over, the trap entry,
 * and a call on another stack.
 *
 * Core 0 comes to _start with the image's RAM segments loaded; core 1 to
 * _start_cpu1 once core 0 lets it go (cpu1.zig), on the stack core 0 set
 * aside for it in cpu1_stack_top. Each masks its interrupts, switches the
 * FPU on (a floating-point instruction traps while mstatus.FS is off),
 * points mtvec at the trap entry in the interrupt controller's (CLIC)
 * mode, and calls kmain or kmain_cpu1; core 0 clears .bss first and maps
 * the flash (kernel_early), whose part of the kernel kmain is in.
 *
 * Every trap - an exception, an interrupt, an ecall - comes to _trap_entry
 * on the stack it interrupted, and is saved into a `trap.Frame` right
 * below that stack pointer: the integer registers, the trap's CSRs, and
 * the FPU's registers when the interrupted code has used the FPU
 * (mstatus.FS clean or dirty) - code that never has pays nothing for it.
 * riscv_exception (trap.zig) answers the frame to resume: the same one,
 * or another task's when exec switched tasks. The exit writes back the
 * mcause of the trap it leaves, whichever frame it resumes: with the
 * interrupt controller (CLIC), mret ends the interrupt mcause names and
 * puts back the level it was taken at (mpil) - an interrupt left with
 * another frame's mcause would stay in service and hold off every line at
 * its level for good. Tasks run at level 0 and only the outermost trap
 * switches, so that level is the resumed task's too. mstatus, written
 * after it, gives mret the resumed frame's privilege and interrupt state.
 */

#define F_X(n)          (4 * (n))
#define F_MEPC          128
#define F_MSTATUS       132
#define F_MCAUSE        136
#define F_MTVAL         140
#define F_FPU           144
#define F_FCSR          148
#define F_F(n)          (152 + 4 * (n))
#define FRAME_SIZE      288

#define MSTATUS_MIE     0x8
#define MSTATUS_FS_INITIAL 0x2000
#define MTVEC_CLIC      3

    .section .text.start, "ax"
    .global _start
    .type _start, @function
_start:
    csrci   mstatus, MSTATUS_MIE
    li      t0, MSTATUS_FS_INITIAL
    csrs    mstatus, t0
    la      sp, _stack_top

    la      a0, _bss_start
    la      a1, _bss_end
1:  bgeu    a0, a1, 2f
    sw      zero, 0(a0)
    addi    a0, a0, 4
    j       1b
2:
    la      t0, _trap_entry
    ori     t0, t0, MTVEC_CLIC
    csrw    mtvec, t0
    li      ra, 0                   /* terminates backtraces */
    call    kernel_early            /* the flash mapped: the RAM part's last */
    call    kmain
3:  wfi
    j       3b
    .size _start, . - _start

/*
 * The second core's entry: what _start does, but no .bss to clear - core 0
 * did that - and the stack core 0 set aside for it.
 */
    .global _start_cpu1
    .type _start_cpu1, @function
_start_cpu1:
    csrci   mstatus, MSTATUS_MIE
    li      t0, MSTATUS_FS_INITIAL
    csrs    mstatus, t0
    la      t0, cpu1_stack_top
    lw      sp, 0(t0)
    la      t0, _trap_entry
    ori     t0, t0, MTVEC_CLIC
    csrw    mtvec, t0
    li      ra, 0
    call    kmain_cpu1
4:  wfi
    j       4b
    .size _start_cpu1, . - _start_cpu1

/*
 * The trap entry: mtvec's base, so on 64 bytes. In CLIC mode every
 * exception and every interrupt that is not hardware-vectored comes here,
 * with this core's interrupts masked (MIE off).
 */
    .section .text.trap, "ax"
    .balign 64
    .global _trap_entry
    .type _trap_entry, @function
_trap_entry:
    addi    sp, sp, -FRAME_SIZE
    sw      x1, F_X(1)(sp)
    sw      x3, F_X(3)(sp)
    sw      x4, F_X(4)(sp)
    sw      x5, F_X(5)(sp)
    sw      x6, F_X(6)(sp)
    sw      x7, F_X(7)(sp)
    sw      x8, F_X(8)(sp)
    sw      x9, F_X(9)(sp)
    sw      x10, F_X(10)(sp)
    sw      x11, F_X(11)(sp)
    sw      x12, F_X(12)(sp)
    sw      x13, F_X(13)(sp)
    sw      x14, F_X(14)(sp)
    sw      x15, F_X(15)(sp)
    sw      x16, F_X(16)(sp)
    sw      x17, F_X(17)(sp)
    sw      x18, F_X(18)(sp)
    sw      x19, F_X(19)(sp)
    sw      x20, F_X(20)(sp)
    sw      x21, F_X(21)(sp)
    sw      x22, F_X(22)(sp)
    sw      x23, F_X(23)(sp)
    sw      x24, F_X(24)(sp)
    sw      x25, F_X(25)(sp)
    sw      x26, F_X(26)(sp)
    sw      x27, F_X(27)(sp)
    sw      x28, F_X(28)(sp)
    sw      x29, F_X(29)(sp)
    sw      x30, F_X(30)(sp)
    sw      x31, F_X(31)(sp)
    addi    t0, sp, FRAME_SIZE
    sw      t0, F_X(2)(sp)          /* the interrupted stack pointer */
    sw      zero, F_X(0)(sp)
    csrr    t0, mepc
    sw      t0, F_MEPC(sp)
    csrr    t0, mcause
    sw      t0, F_MCAUSE(sp)
    csrr    t0, mtval
    sw      t0, F_MTVAL(sp)
    csrr    t0, mstatus
    sw      t0, F_MSTATUS(sp)

    /* The FPU's registers, if the interrupted code has used it: FS (bits
       13-14) 2 or 3. */
    srli    t1, t0, 14
    andi    t1, t1, 1
    sw      t1, F_FPU(sp)
    beqz    t1, 5f
    fsw     f0, F_F(0)(sp)
    fsw     f1, F_F(1)(sp)
    fsw     f2, F_F(2)(sp)
    fsw     f3, F_F(3)(sp)
    fsw     f4, F_F(4)(sp)
    fsw     f5, F_F(5)(sp)
    fsw     f6, F_F(6)(sp)
    fsw     f7, F_F(7)(sp)
    fsw     f8, F_F(8)(sp)
    fsw     f9, F_F(9)(sp)
    fsw     f10, F_F(10)(sp)
    fsw     f11, F_F(11)(sp)
    fsw     f12, F_F(12)(sp)
    fsw     f13, F_F(13)(sp)
    fsw     f14, F_F(14)(sp)
    fsw     f15, F_F(15)(sp)
    fsw     f16, F_F(16)(sp)
    fsw     f17, F_F(17)(sp)
    fsw     f18, F_F(18)(sp)
    fsw     f19, F_F(19)(sp)
    fsw     f20, F_F(20)(sp)
    fsw     f21, F_F(21)(sp)
    fsw     f22, F_F(22)(sp)
    fsw     f23, F_F(23)(sp)
    fsw     f24, F_F(24)(sp)
    fsw     f25, F_F(25)(sp)
    fsw     f26, F_F(26)(sp)
    fsw     f27, F_F(27)(sp)
    fsw     f28, F_F(28)(sp)
    fsw     f29, F_F(29)(sp)
    fsw     f30, F_F(30)(sp)
    fsw     f31, F_F(31)(sp)
    frcsr   t1
    sw      t1, F_FCSR(sp)
5:
    mv      a0, sp
    call    riscv_exception         /* a0 = the frame to resume */
    lw      t2, F_MCAUSE(sp)        /* the cause of the trap being left */
    beq     a0, sp, .Lresume

    /* A task switch: onto the other task's stack. Off the task left, and
       nothing of it in the registers: another core may resume it now
       (context.zig, task_leaving[core] = 0). */
    mv      sp, a0
    csrr    t0, mhartid
    slli    t0, t0, 2
    la      t1, task_leaving
    add     t1, t1, t0
    fence   rw, w
    sw      zero, 0(t1)
    fence   rw, rw

.Lresume:                           /* t2 = the left trap's mcause */
    lw      t0, F_FPU(sp)
    beqz    t0, 6f
    flw     f0, F_F(0)(sp)
    flw     f1, F_F(1)(sp)
    flw     f2, F_F(2)(sp)
    flw     f3, F_F(3)(sp)
    flw     f4, F_F(4)(sp)
    flw     f5, F_F(5)(sp)
    flw     f6, F_F(6)(sp)
    flw     f7, F_F(7)(sp)
    flw     f8, F_F(8)(sp)
    flw     f9, F_F(9)(sp)
    flw     f10, F_F(10)(sp)
    flw     f11, F_F(11)(sp)
    flw     f12, F_F(12)(sp)
    flw     f13, F_F(13)(sp)
    flw     f14, F_F(14)(sp)
    flw     f15, F_F(15)(sp)
    flw     f16, F_F(16)(sp)
    flw     f17, F_F(17)(sp)
    flw     f18, F_F(18)(sp)
    flw     f19, F_F(19)(sp)
    flw     f20, F_F(20)(sp)
    flw     f21, F_F(21)(sp)
    flw     f22, F_F(22)(sp)
    flw     f23, F_F(23)(sp)
    flw     f24, F_F(24)(sp)
    flw     f25, F_F(25)(sp)
    flw     f26, F_F(26)(sp)
    flw     f27, F_F(27)(sp)
    flw     f28, F_F(28)(sp)
    flw     f29, F_F(29)(sp)
    flw     f30, F_F(30)(sp)
    flw     f31, F_F(31)(sp)
    lw      t1, F_FCSR(sp)
    fscsr   t1
    j       7f
6:  fscsr   zero                    /* code that has not used the FPU finds it as new */
7:
    csrw    mcause, t2              /* the trap left ended, its level put back */
    lw      t0, F_MSTATUS(sp)
    csrw    mstatus, t0             /* the resumed frame's MPP, MPIE and FS */
    lw      t0, F_MEPC(sp)
    csrw    mepc, t0
    lw      x1, F_X(1)(sp)
    lw      x3, F_X(3)(sp)
    lw      x4, F_X(4)(sp)
    lw      x5, F_X(5)(sp)
    lw      x6, F_X(6)(sp)
    lw      x7, F_X(7)(sp)
    lw      x8, F_X(8)(sp)
    lw      x9, F_X(9)(sp)
    lw      x10, F_X(10)(sp)
    lw      x11, F_X(11)(sp)
    lw      x12, F_X(12)(sp)
    lw      x13, F_X(13)(sp)
    lw      x14, F_X(14)(sp)
    lw      x15, F_X(15)(sp)
    lw      x16, F_X(16)(sp)
    lw      x17, F_X(17)(sp)
    lw      x18, F_X(18)(sp)
    lw      x19, F_X(19)(sp)
    lw      x20, F_X(20)(sp)
    lw      x21, F_X(21)(sp)
    lw      x22, F_X(22)(sp)
    lw      x23, F_X(23)(sp)
    lw      x24, F_X(24)(sp)
    lw      x25, F_X(25)(sp)
    lw      x26, F_X(26)(sp)
    lw      x27, F_X(27)(sp)
    lw      x28, F_X(28)(sp)
    lw      x29, F_X(29)(sp)
    lw      x30, F_X(30)(sp)
    lw      x31, F_X(31)(sp)
    lw      sp, F_X(2)(sp)
    mret
    .size _trap_entry, . - _trap_entry

/*
 * i32 riscv_call_on_stack(u32 stack_upper, fn code, void *arg), for exec's
 * NewStackRun: code(arg) on the stack that ends at stack_upper (rounded
 * down to 16 bytes), and its answer. The caller's stack pointer is kept in
 * s0, which code saves and puts back as every callee does.
 */
    .section .text.riscv_call_on_stack, "ax"
    .global riscv_call_on_stack
    .type riscv_call_on_stack, @function
riscv_call_on_stack:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s0, 8(sp)
    mv      s0, sp
    andi    sp, a0, -16
    mv      a0, a2
    jalr    a1
    mv      sp, s0
    lw      s0, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
    .size riscv_call_on_stack, . - riscv_call_on_stack
