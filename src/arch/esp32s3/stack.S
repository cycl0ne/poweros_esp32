/* SPDX-License-Identifier: MPL-2.0 */
/*
 * Code run on a stack of its own, for exec's NewStackRun (and so dos's
 * RunCommand). With the Xtensa's register windows the stack pointer
 * can't be swapped under running compiled code (a StackSwap): the window overflow handlers find a frame's save areas
 * from the stack pointers of its caller and its callee, so every live
 * window has to be on the stack it belongs to before a1 moves.
 *
 * i32 xtensa_call_on_stack(u32 stack_upper, fn code, void *arg):
 *   - With interrupts off, rotate once around all 16 windows, touching a12
 *     each time: every older frame is written to its own stack (as start.S
 *     does for a task switch).
 *   - Copy this frame's base save area (the caller's a0-a3, in the 16 bytes
 *     below a1) below the new stack's top, so a later overflow of this frame
 *     still finds its caller's stack pointer there, and move a1 (MOVSP: the
 *     caller is spilled, so no alloca exception).
 *   - Interrupts back on, code(arg) with call8; then a1 back to where it
 *     was (the caller's save area there never changed) and return code's
 *     answer.
 */
    .section .text.xtensa_call_on_stack, "ax"
    .align 4
    .global xtensa_call_on_stack
    .type xtensa_call_on_stack, @function
xtensa_call_on_stack:
    entry   a1, 32                  /* a2 stack top, a3 code, a4 arg */
    mov     a7, a4                  /* the argument, out of the way */
    rsil    a6, 15                  /* no interrupts while the windows turn */
    and     a12, a12, a12
    rotw    3
    and     a12, a12, a12
    rotw    3
    and     a12, a12, a12
    rotw    3
    and     a12, a12, a12
    rotw    3
    and     a12, a12, a12
    rotw    4                       /* back in this window, the others spilled */

    movi    a5, -16
    and     a2, a2, a5              /* the top, 16-byte aligned */
    addi    a8, a1, -16             /* the caller's base save area ... */
    addi    a9, a2, -16             /* ... goes below the new top */
    l32i    a5, a8, 0
    s32i    a5, a9, 0
    l32i    a5, a8, 4
    s32i    a5, a9, 4
    l32i    a5, a8, 8
    s32i    a5, a9, 8
    l32i    a5, a8, 12
    s32i    a5, a9, 12
    mov     a4, a1                  /* this stack pointer, for after */
    movsp   a1, a2
    wsr     a6, ps
    rsync

    mov     a10, a7                 /* code's a2: the argument */
    callx8  a3
    movsp   a1, a4
    mov     a2, a10                 /* code's answer */
    retw
    .size xtensa_call_on_stack, . - xtensa_call_on_stack
