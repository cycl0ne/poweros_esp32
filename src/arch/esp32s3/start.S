/* SPDX-License-Identifier: MPL-2.0 */
/*
 * Reset entry, vector table and exception entry for the ESP32-S3 (Xtensa LX7).
 *
 * The ROM bootloader loads our RAM segments into SRAM and jumps to _start.
 * From there we own the CPU: install our vector table, reset the register
 * window, set up the stack, call kernel_early() (in IRAM: it maps the code
 * in flash) and then kmain() with the windowed ABI.
 */

#define PS_UM               0x00000020
#define PS_WOE              0x00040000
#define PS_INTLEVEL(n)      (n)
#define EXCM_LEVEL          3

/* Exception frame, must match trap.Frame in trap.zig. */
#define F_PC                0
#define F_PS                4
#define F_SAR               8
#define F_EXCCAUSE          12
#define F_EXCVADDR          16
#define F_LBEG              20
#define F_LEND              24
#define F_LCOUNT            28
#define F_A(n)              (32 + 4 * (n))
#define FRAME_SIZE          96

/*
 * The frame lives below the interrupted stack pointer with a 32 byte gap:
 * 16 bytes are the base save area the interrupted function's caller spills
 * into, 16 bytes are the trampoline's own call8 spill area. The interrupted
 * a1 is never modified, so window spills of older frames land exactly where
 * the windowed ABI expects them.
 */
#define FRAME_OFFSET        (FRAME_SIZE + 32)
#define TRAMP_FRAME         (FRAME_OFFSET + 16)

    .section .rodata.start, "a"
fatal_msg:
    .asciz "\r\n*** FATAL: unexpected exception vector "

/* ------------------------------------------------------------------------- */
/* Vector table (VECBASE). Offsets are fixed by the LX7 core configuration.  */
/* ------------------------------------------------------------------------- */

    .section .vectors, "ax"
    .balign 1024
    .global _vector_table
_vector_table:

    .org 0x000
_WindowOverflow4:
    s32e    a0, a5, -16
    s32e    a1, a5, -12
    s32e    a2, a5, -8
    s32e    a3, a5, -4
    rfwo

    .org 0x040
_WindowUnderflow4:
    l32e    a0, a5, -16
    l32e    a1, a5, -12
    l32e    a2, a5, -8
    l32e    a3, a5, -4
    rfwu

    .org 0x080
_WindowOverflow8:
    s32e    a0, a9, -16
    l32e    a0, a1, -12
    s32e    a1, a9, -12
    s32e    a2, a9, -8
    s32e    a3, a9, -4
    s32e    a4, a0, -32
    s32e    a5, a0, -28
    s32e    a6, a0, -24
    s32e    a7, a0, -20
    rfwo

    .org 0x0C0
_WindowUnderflow8:
    l32e    a1, a9, -12
    l32e    a0, a9, -16
    l32e    a7, a1, -12
    l32e    a2, a9, -8
    l32e    a4, a7, -32
    l32e    a3, a9, -4
    l32e    a5, a7, -28
    l32e    a6, a7, -24
    l32e    a7, a7, -20
    rfwu

    .org 0x100
_WindowOverflow12:
    s32e    a0, a13, -16
    l32e    a0, a1, -12
    s32e    a1, a13, -12
    s32e    a2, a13, -8
    s32e    a3, a13, -4
    s32e    a4, a0, -48
    s32e    a5, a0, -44
    s32e    a6, a0, -40
    s32e    a7, a0, -36
    s32e    a8, a0, -32
    s32e    a9, a0, -28
    s32e    a10, a0, -24
    s32e    a11, a0, -20
    rfwo

    .org 0x140
_WindowUnderflow12:
    l32e    a1, a13, -12
    l32e    a0, a13, -16
    l32e    a11, a1, -12
    l32e    a2, a13, -8
    l32e    a4, a11, -48
    l32e    a8, a11, -32
    l32e    a3, a13, -4
    l32e    a5, a11, -44
    l32e    a6, a11, -40
    l32e    a7, a11, -36
    l32e    a9, a11, -28
    l32e    a10, a11, -24
    l32e    a11, a11, -20
    rfwu

    .org 0x180
_Level2Vector:
    movi    a0, '2'
    j       _fatal_vector

    .org 0x1C0
_Level3Vector:
    movi    a0, '3'
    j       _fatal_vector

    .org 0x200
_Level4Vector:
    movi    a0, '4'
    j       _fatal_vector

    .org 0x240
_Level5Vector:
    movi    a0, '5'
    j       _fatal_vector

    .org 0x280
_DebugVector:
    movi    a0, 'D'
    j       _fatal_vector

    .org 0x2C0
_NMIVector:
    movi    a0, 'N'
    j       _fatal_vector

    .org 0x300
_KernelVector:
    movi    a0, 'K'
    j       _fatal_vector

    .org 0x340
_UserVector:
    wsr     a0, excsave1
    rsr     a0, exccause
    beqi    a0, 5, _alloca_exception        /* EXCCAUSE_ALLOCA */
    j       _user_exception

/*
 * The alloca exception: a MOVSP while the caller's frame (a0-a3 of the
 * window below) is spilled to the stack. The compiler emits MOVSP around
 * calls with more than six arguments (the rest go on the stack) and for
 * dynamic stack allocation. As in the Xtensa ABI (ESP-IDF's
 * _xt_alloca_exc): rotate back to the caller's window, set PS.OWB to it,
 * and let the window underflow handler for its call size reload the frame;
 * its RFWU returns to the MOVSP, which then goes through. The underflow
 * handlers are out of a BBCI's reach, hence BBSI and J.
 */
_alloca_exception:
    rsr     a0, windowbase                  /* WINDOWBASE, to a4 after the rotw */
    rotw    -1                              /* new a0-a3 are scratch */
    rsr     a2, ps
    extui   a3, a2, 8, 4                    /* PS.OWB */
    xor     a3, a3, a4                      /* bits that differ from WINDOWBASE */
    rsr     a4, excsave1                    /* the original a0, with the call size */
    slli    a3, a3, 8
    xor     a2, a2, a3                      /* PS.OWB = the rotated WINDOWBASE */
    wsr     a2, ps
    rsync
    bbsi    a4, 31, 1f
    j       _WindowUnderflow4               /* call4 */
1:  rotw    -1                              /* the original a0 is now a8 */
    bbsi    a8, 30, 2f
    j       _WindowUnderflow8               /* call8 */
2:  rotw    -1
    j       _WindowUnderflow12              /* call12 */

    .org 0x3C0
_DoubleExceptionVector:
    movi    a0, 'X'
    j       _fatal_vector

    .org 0x400

/* ------------------------------------------------------------------------- */

    .section .iram.text, "ax"
    .balign 4
.Llit_vecbase:      .long _vector_table
.Llit_stack_top:    .long _stack_top
.Llit_bss_start:    .long _bss_start
.Llit_bss_end:      .long _bss_end
.Llit_ps_kernel:    .long PS_UM | PS_WOE | PS_INTLEVEL(5)
.Llit_ps_handler:   .long PS_UM | PS_WOE | PS_INTLEVEL(EXCM_LEVEL)
.Llit_early:        .long kernel_early
.Llit_kmain:        .long kmain
.Llit_tramp:        .long _exception_trampoline
.Llit_dispatch:     .long xtensa_exception
.Llit_uart:         .long 0x60000000
.Llit_fatal_msg:    .long fatal_msg

/*
 * Reset entry, jumped to by the ROM bootloader.
 */
    .balign 4
    .global _start
    .type _start, @function
_start:
    movi    a0, PS_UM | PS_INTLEVEL(5)      /* interrupts masked, windowing off */
    wsr     a0, ps
    rsync
    movi    a0, 0
    wsr     a0, intenable
    l32r    a0, .Llit_vecbase
    wsr     a0, vecbase
    rsync

    /* Fresh register window: only window 0 is live. */
    movi    a0, 0
    wsr     a0, windowbase
    rsync
    movi    a0, 1
    wsr     a0, windowstart
    rsync

    /* Enable the coprocessors (FPU) so float code does not trap. */
    movi    a0, 0xff
    wsr     a0, cpenable
    rsync

    /* Zero .bss */
    l32r    a2, .Llit_bss_start
    l32r    a3, .Llit_bss_end
    movi    a4, 0
    bgeu    a2, a3, 2f
1:  s32i    a4, a2, 0
    addi    a2, a2, 4
    bltu    a2, a3, 1b
2:

    l32r    a1, .Llit_stack_top
    movi    a0, 0                           /* terminates backtraces */
    l32r    a2, .Llit_ps_kernel             /* windowed ABI on, still masked */
    wsr     a2, ps
    rsync
    l32r    a8, .Llit_early
    callx4  a8
    l32r    a8, .Llit_kmain
    callx4  a8
3:  waiti   15
    j       3b

/*
 * Level-1 exceptions and interrupts (PS.UM = 1).
 * On entry: a0 is stashed in EXCSAVE1, a1 is the interrupted stack pointer.
 */
    .balign 4
    .global _user_exception
_user_exception:
    addi    a0, a1, -FRAME_OFFSET
    s32i    a2, a0, F_A(2)
    s32i    a3, a0, F_A(3)
    s32i    a4, a0, F_A(4)
    s32i    a5, a0, F_A(5)
    s32i    a6, a0, F_A(6)
    s32i    a7, a0, F_A(7)
    s32i    a8, a0, F_A(8)
    s32i    a9, a0, F_A(9)
    s32i    a10, a0, F_A(10)
    s32i    a11, a0, F_A(11)
    s32i    a12, a0, F_A(12)
    s32i    a13, a0, F_A(13)
    s32i    a14, a0, F_A(14)
    s32i    a15, a0, F_A(15)
    s32i    a1, a0, F_A(1)
    rsr     a2, excsave1
    s32i    a2, a0, F_A(0)
    rsr     a2, epc1
    s32i    a2, a0, F_PC
    rsr     a2, ps
    s32i    a2, a0, F_PS
    rsr     a2, sar
    s32i    a2, a0, F_SAR
    rsr     a2, exccause
    s32i    a2, a0, F_EXCCAUSE
    rsr     a2, excvaddr
    s32i    a2, a0, F_EXCVADDR
    rsr     a2, lbeg
    s32i    a2, a0, F_LBEG
    rsr     a2, lend
    s32i    a2, a0, F_LEND
    rsr     a2, lcount
    s32i    a2, a0, F_LCOUNT
    movi    a2, 0
    wsr     a2, lcount              /* no zero-overhead loop inside the handler */

    /* Leave exception mode so the handler can use the register window. */
    mov     a6, a0                  /* trampoline's a2 = frame */
    l32r    a2, .Llit_ps_handler
    wsr     a2, ps
    rsync
    l32r    a8, .Llit_tramp
    callx4  a8                      /* a6 = frame to resume */

    /* Back in the interrupted window: a0-a3 are intact, a4-a15 are scratch. */
    addi    a4, a1, -FRAME_OFFSET
    beq     a4, a6, .Lresume

    /*
     * Task switch. Write every register window except this one to the
     * stack it belongs to, so nothing of the interrupted task's call chain
     * stays in the register file: touching a12 while rotating once around
     * all 16 windows raises the window overflow for each live one.
     */
    and     a12, a12, a12
    rotw    3
    and     a12, a12, a12
    rotw    3
    and     a12, a12, a12
    rotw    3
    and     a12, a12, a12
    rotw    3
    and     a12, a12, a12
    rotw    4

    /* The other task: its stack pointer is FRAME_OFFSET above its frame,
       and all of its older windows are on its stack. */
    addi    a1, a6, FRAME_OFFSET
    mov     a4, a6
    rsr     a5, windowbase
    movi    a6, 1
    ssl     a5
    sll     a6, a6
    wsr     a6, windowstart
    rsync

.Lresume:                           /* a4 = frame */
    l32i    a5, a4, F_PS
    wsr     a5, ps                  /* PS.EXCM = 1 again */
    rsync
    l32i    a5, a4, F_PC
    wsr     a5, epc1
    l32i    a5, a4, F_SAR
    wsr     a5, sar
    l32i    a5, a4, F_LBEG
    wsr     a5, lbeg
    l32i    a5, a4, F_LEND
    wsr     a5, lend
    l32i    a5, a4, F_LCOUNT
    wsr     a5, lcount
    isync
    l32i    a0, a4, F_A(0)
    l32i    a2, a4, F_A(2)
    l32i    a3, a4, F_A(3)
    l32i    a5, a4, F_A(5)
    l32i    a6, a4, F_A(6)
    l32i    a7, a4, F_A(7)
    l32i    a8, a4, F_A(8)
    l32i    a9, a4, F_A(9)
    l32i    a10, a4, F_A(10)
    l32i    a11, a4, F_A(11)
    l32i    a12, a4, F_A(12)
    l32i    a13, a4, F_A(13)
    l32i    a14, a4, F_A(14)
    l32i    a15, a4, F_A(15)
    l32i    a4, a4, F_A(4)
    rfe

/*
 * Windowed-ABI bridge into Zig. Its frame is large enough to cover the
 * exception frame, so the Zig handler's stack starts below it.
 */
    .balign 4
_exception_trampoline:
    entry   a1, TRAMP_FRAME
    mov     a10, a2
    l32r    a8, .Llit_dispatch
    callx8  a8
    mov     a2, a10                 /* frame to resume */
    retw

/*
 * Vectors we never expect to hit. Print which one (code in a0) and halt.
 */
    .balign 4
_fatal_vector:
    rsil    a2, 15
    l32r    a2, .Llit_uart
    l32r    a3, .Llit_fatal_msg
1:  l8ui    a4, a3, 0
    beqz    a4, 3f
2:  l32i    a5, a2, 0x1c            /* UART_STATUS: TX FIFO count in [25:16] */
    extui   a5, a5, 16, 10
    bgeui   a5, 64, 2b
    s32i    a4, a2, 0
    addi    a3, a3, 1
    j       1b
3:  s32i    a0, a2, 0
    movi    a4, 13
    s32i    a4, a2, 0
    movi    a4, 10
    s32i    a4, a2, 0
4:  waiti   15
    j       4b
