/* SPDX-License-Identifier: MPL-2.0 */
/*
 * The entry point of an x86-64 machine started by UEFI firmware, the 256
 * interrupt vectors, and a call on another stack.
 *
 * The firmware does not start this code: the stub does
 * (src/boot/uefi/stub.zig). The stub asks the firmware for the machine,
 * reads this image off the boot partition into the pages it asks the
 * firmware for by address, leaves the firmware and calls _boot with the
 * handover's address in RDI - on the firmware's map, which identifies
 * every address with itself, with the interrupts masked and nothing else
 * running. Where the image has to be, how much memory it takes there and
 * where its entry is are in the header at _start, which the stub reads
 * before it asks for anything: so the one place the kernel's address is
 * written down is this kernel's own linker script.
 *
 * What _boot does, in order: descriptor tables of the kernel's own, since
 * the firmware's are in memory that is about to be handed out; the segment
 * registers reloaded from them; the boot stack; .bss cleared; the core's
 * number where GS points, which is how anything asks which core it is on
 * (cpu.zig) and is wanted before the first lock is taken; and kmain with
 * the handover. The map, the task segment and the interrupt descriptor
 * table come after that, from the kernel, once it has read the machine.
 *
 * Every exception and every interrupt comes to the stub of its vector,
 * which pushes the vector's number - and a zero where the core pushes no
 * error code of its own, so that the frame is the same shape whichever
 * came - and goes to the common path. There the whole interrupted context
 * is saved into a `trap.Frame` right below the stack it came on: every
 * general register and the SSE state, all of them each time, since there
 * is no telling what the interrupted code was using. x64_exception
 * (trap.zig) answers the frame to resume: the same one, or another task's
 * when exec switched tasks. RFLAGS, written back from the resumed frame by
 * the `iretq`, gives it its interrupt state.
 */

/* The selectors of the kernel's own descriptor table, below. */
#define GDT_CODE        0x08
#define GDT_DATA        0x10

/* trap.Frame, whose comptime asserts hold these. */
#define F_FX            0
#define F_R15           512
#define F_RAX           624
#define F_VECTOR        632
#define F_ERROR         640
#define F_RIP           648
#define F_RSP           672
#define FRAME_SIZE      688

/* How far apart the vectors' stubs are: each is at most twelve bytes
   (two pushes and a jump), and trap.zig's table reads them at this
   stride. */
#define STUB_STRIDE     16

/* exec's max_cores, and a stack of each core's own for an exception taken
   with no room on the stack it came on. */
#define MAX_CORES       4
#define FAULT_STACK_SIZE 4096

/* GS's base: which core this is (cpu.MSR_GS_BASE). */
#define MSR_GS_BASE     0xC0000101

    .section .text.start, "ax"
    .global _start
    .type _start, %function
_start:
    /* The header the stub reads (src/boot/uefi/handover.zig's
       KernelHeader): what it is, where the image must be, how much memory
       it takes there - its .bss and boot stack too - and where to call. */
    .byte   'P','O','S','K','R','N',0,1
    .quad   _text_start
    .quad   _image_size
    .quad   _boot - _start

    .balign 16
_boot:
    cli
    cld
    movq    %rdi, %r15              /* the handover */

    /* Descriptor tables of the kernel's own: the firmware's are in memory
       the kernel is about to hand out. CS can only be reloaded by a far
       return, so one is made here; the rest are written. */
    lgdt    x64_gdt_pointer(%rip)
    pushq   $GDT_CODE
    leaq    .Lreloaded(%rip), %rax
    pushq   %rax
    lretq
.Lreloaded:
    movl    $GDT_DATA, %eax
    movl    %eax, %ds
    movl    %eax, %es
    movl    %eax, %ss
    /* FS and GS get nothing: writing a selector into either clears its
       base, and GS's base is set below to what it is wanted for. */
    xorl    %eax, %eax
    movl    %eax, %fs
    movl    %eax, %gs

    leaq    _stack_top(%rip), %rsp
    xorl    %ebp, %ebp              /* terminates backtraces */

    /* .bss cleared, a quadword at a time; the linker script makes it a
       whole number of them. The boot stack is past it and keeps what was
       pushed above. */
    leaq    _bss_start(%rip), %rdi
    leaq    _bss_end(%rip), %rcx
    subq    %rdi, %rcx
    shrq    $3, %rcx
    xorl    %eax, %eax
    rep stosq

    /* Which core this is, where GS points: core 0's block, whose number
       is the zero .bss already holds. exec asks for the core on every
       lock it takes, so this comes before anything is called. */
    leaq    core_blocks(%rip), %rax
    movq    %rax, %rdx
    shrq    $32, %rdx
    movl    $MSR_GS_BASE, %ecx
    wrmsr

    movq    %r15, %rdi
    xorl    %ebp, %ebp
    callq   kmain
1:  hlt
    jmp     1b
    .size _start, . - _start

/*
 * The kernel's global descriptor table: a null entry, one 64-bit code
 * segment and one data segment, then room for a task segment per core,
 * whose descriptors the kernel writes once it knows where its task
 * segments are (desc.zig). A 64-bit code or data segment has no base and
 * no limit: the bits that say so are here because the architecture still
 * reads them.
 */
    .section .data
    .balign 16
    .global x64_gdt
x64_gdt:
    .quad   0                       /* 0x00: none */
    .quad   0x00AF9A000000FFFF      /* 0x08: code, 64-bit, this level */
    .quad   0x00CF92000000FFFF      /* 0x10: data */
    .quad   0, 0                    /* 0x18: core 0's task segment */
    .quad   0, 0                    /* 0x28: core 1's */
    .quad   0, 0                    /* 0x38: core 2's */
    .quad   0, 0                    /* 0x48: core 3's */
x64_gdt_end:

    .balign 8
    .global x64_gdt_pointer
x64_gdt_pointer:
    .word   x64_gdt_end - x64_gdt - 1
    .quad   x64_gdt

/*
 * The vectors' stubs: one per vector, STUB_STRIDE bytes apart, which is
 * how trap.zig finds the one for a vector when it builds the interrupt
 * descriptor table. Each pushes the vector's number, and a zero first
 * where the core does not push an error code of its own - the ten
 * exceptions that do are named here - so that the frame has the same
 * shape whichever vector came.
 */
    .section .text.stubs, "ax"
    .balign STUB_STRIDE
    .global x64_isr_stubs
x64_isr_stubs:
    .set    vector, 0
    .rept   256
    .balign STUB_STRIDE
    .if (vector != 8) && (vector != 10) && (vector != 11) && (vector != 12) && (vector != 13) && (vector != 14) && (vector != 17) && (vector != 21) && (vector != 29) && (vector != 30)
    pushq   $0
    .endif
    pushq   $vector
    jmp     _trap_common
    .set    vector, vector + 1
    .endr

    .section .text.trap, "ax"
    .balign 16
_trap_common:
    /* The stack it came on must be in RAM with room for the frame: a task
       that ran off its stack would otherwise have every exception from
       here on push its frame further into nothing. One that has no room
       goes to x64_stack_fault (trap.zig) on a stack of its core's own,
       with what can be saved of where it was. The bounds are RAM's
       (x64_stack_low already above its start by a frame), which the kernel
       sets as it starts. RAX is pushed first because there is no register
       to check with until one is saved; where the check fails it is left
       where it lies, since nothing comes back from there. */
    pushq   %rax
    movq    %rsp, %rax
    cmpq    x64_stack_low(%rip), %rax
    jb      _trap_bad_stack
    cmpq    x64_stack_high(%rip), %rax
    jae     _trap_bad_stack

    pushq   %rbx
    pushq   %rcx
    pushq   %rdx
    pushq   %rsi
    pushq   %rdi
    pushq   %rbp
    pushq   %r8
    pushq   %r9
    pushq   %r10
    pushq   %r11
    pushq   %r12
    pushq   %r13
    pushq   %r14
    pushq   %r15
    /* The x87 and SSE state. The frame is 16-byte aligned here: the core
       aligns the stack to 16 before it pushes its own five words, and
       everything pushed since is a whole number of 16 bytes. */
    subq    $512, %rsp
    fxsave64 (%rsp)

    movq    %rsp, %rdi
    xorl    %ebp, %ebp              /* the chain ends at the exception */
    callq   x64_exception           /* RAX = the frame to resume */
    cmpq    %rsp, %rax
    je      .Lresume

    /* A task switch: onto the other task's stack. Off the task left, and
       nothing of it in the registers: another core may resume it now
       (context.zig, task_leaving[core] = 0). The store is seen in its
       place by every core - this architecture does not reorder stores -
       and the `iretq` below serialises in any case. */
    movq    %rax, %rsp
    leaq    task_leaving(%rip), %rdx
    movl    %gs:0, %ecx
    movq    $0, (%rdx,%rcx,8)

.Lresume:
    fxrstor64 (%rsp)
    addq    $512, %rsp
    popq    %r15
    popq    %r14
    popq    %r13
    popq    %r12
    popq    %r11
    popq    %r10
    popq    %r9
    popq    %r8
    popq    %rbp
    popq    %rdi
    popq    %rsi
    popq    %rdx
    popq    %rcx
    popq    %rbx
    popq    %rax
    /* Past the vector and its error code, which the core does not pop. */
    addq    $16, %rsp
    iretq
    .size _trap_common, . - _trap_common

/*
 * An exception on a stack with no room: the stack pointer, where it came
 * from, which vector it was and its error code, and the frame pointer, to
 * x64_stack_fault on the core's fault stack. It does not come back.
 */
_trap_bad_stack:
    movq    %rsp, %rdi              /* where it came on */
    movq    8(%rsp), %rdx           /* the vector */
    movq    16(%rsp), %rcx          /* its error code */
    movq    24(%rsp), %rsi          /* where it came from */
    movq    %rbp, %r8               /* the frame pointer */
    movl    %gs:0, %eax
    incl    %eax
    shll    $12, %eax               /* (core + 1) * FAULT_STACK_SIZE */
    leaq    x64_fault_stacks(%rip), %r9
    addq    %rax, %r9
    movq    %r9, %rsp
    xorl    %ebp, %ebp
    callq   x64_stack_fault
1:  hlt
    jmp     1b

    .section .bss.x64_fault_stacks, "aw", %nobits
    .balign 16
    .global x64_fault_stacks
x64_fault_stacks:
    .space  MAX_CORES * FAULT_STACK_SIZE

/*
 * i32 x64_call_on_stack(usize stack_upper, fn code, void *arg), for exec's
 * NewStackRun: code(arg) on the stack that ends at stack_upper (rounded
 * down to 16 bytes), and its answer. The caller's stack pointer is kept in
 * RBP, which code saves and puts back as every callee does.
 */
    .section .text.x64_call_on_stack, "ax"
    .global x64_call_on_stack
    .type x64_call_on_stack, %function
x64_call_on_stack:
    pushq   %rbp
    movq    %rsp, %rbp
    andq    $-16, %rdi
    movq    %rdi, %rsp
    movq    %rdx, %rdi
    callq   *%rsi
    movq    %rbp, %rsp
    popq    %rbp
    ret
    .size x64_call_on_stack, . - x64_call_on_stack
