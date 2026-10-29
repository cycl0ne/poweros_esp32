/* SPDX-License-Identifier: MPL-2.0 */
/*
 * The entry points of an AArch64 machine under PSCI firmware: where the
 * firmware hands over, the exception vectors, and a call on another
 * stack.
 *
 * The firmware (QEMU's own boot code for -kernel, the Pi's firmware with
 * Trusted Firmware) enters _start on the boot core with x0 the device
 * tree, the MMU and the data cache off, at EL2 or EL1. The image starts
 * with the 64-byte header of an arm64 Linux `Image`, which both read: a
 * branch past it, where in RAM the image goes (text_offset, from a 2 MiB
 * boundary near its start), how much memory it takes there (image_size,
 * its .bss and boot stack too), the flags and the magic. kernel.ld works
 * the two sizes out.
 *
 * The kernel runs at EL1, on SP_EL1 throughout: a core that comes in at
 * EL2 sets EL2 up to stay out of the way - EL1 in AArch64, the counters
 * and the FPU let through, no traps - and drops to EL1. Then the FPU is
 * switched on (CPACR_EL1: the code the compiler makes uses the vector
 * registers for copies), the core is core 0 (TPIDR_EL1, cpu.zig), .bss
 * is cleared and the MMU switched on with an identity map, which makes
 * RAM normal cacheable memory - without it every access is to device
 * memory: no caches, no unaligned accesses, no atomics to rely on. Until
 * then nothing but aligned 8-byte stores touches memory, and what was
 * written with the MMU off is dropped from the caches before it is on,
 * so a line the firmware left there is not read in its place.
 *
 * The map is a table of 1 GiB blocks: RAM as the board says
 * (_board_ram_base to _board_ram_end) normal memory, everything else
 * device memory that never runs. Two of them are finer. The first GiB is
 * 2 MiB blocks and its first 2 MiB are pages, the first of which is not
 * mapped at all, so a null pointer faults whatever is at address 0 (QEMU
 * has flash there, the Pi RAM). And the kernel's GiB is 2 MiB blocks
 * whose first ones - those its code is in - are pages, the code's
 * read-only. All of it is made here, before the MMU is on: changing a
 * table under the code that runs from it would take the break-before-
 * make dance the architecture asks for, which the code cannot do to
 * itself. mmu.zig adds RAM the device tree has beyond the window.
 *
 * Every exception - a synchronous one (the kernel's syscall, an `svc`,
 * among them), an interrupt, an SError - comes to its vector on the
 * stack it interrupted, and is saved into a `trap.Frame` right below
 * that stack pointer: the general registers, the exception's registers
 * and the FPU's, all of them each time - there is no telling whether
 * the interrupted code used them. a64_exception (trap.zig) answers the
 * frame to resume: the same one, or another task's when exec switched
 * tasks. SPSR, written back from the resumed frame, gives eret its
 * interrupt state.
 */

#define F_X(n)          (8 * (n))
#define F_SP            248
#define F_ELR           256
#define F_SPSR          264
#define F_ESR           272
#define F_FAR           280
#define F_FPCR          288
#define F_FPSR          296
#define F_Q(n)          (304 + 16 * (n))
#define FRAME_SIZE      816

/* What came: a64_exception's second argument. */
#define KIND_SYNC       0
#define KIND_IRQ        1
#define KIND_FIQ        2
#define KIND_SERROR     3
/* A vector that should never be taken: one for code on SP_EL0, or from
   a lower exception level. */
#define KIND_UNEXPECTED 4

/* exec's max_cores, and a stack of each one's own for an exception that
   came on a stack with no room. */
#define MAX_CORES       4
#define FAULT_STACK_SIZE 2048

/* EL2's registers as the kernel leaves them: EL1 runs AArch64 and is not
   trapped; it reads the physical counter and timer; the FPU and the
   performance monitor are not trapped either. */
#define HCR_EL2_RW      (1 << 31)
#define CNTHCTL_EL1PCEN_EL1PCTEN 3
#define CPTR_EL2_NO_TRAPS 0x33FF
/* EL1h with every exception masked, for the eret that drops to EL1. */
#define SPSR_EL1H_MASKED 0x3C5

/* SCTLR_EL1: the bits that have to be 1, the MMU off - and with it on,
   the caches and SP alignment checking. */
#define SCTLR_EL1_RES1  0x30D00800
#define SCTLR_EL1_MMU   (SCTLR_EL1_RES1 | (1 << 0) | (1 << 2) | (1 << 3) | (1 << 12))

/* CPACR_EL1.FPEN: the FPU and the vector registers not trapped. */
#define CPACR_FPEN      (3 << 20)

/* The memory types (MAIR_EL1): 0 device nGnRE, 1 normal write-back,
   2 normal non-cacheable. */
#define MAIR_VALUE      0x44FF04
/* TCR_EL1: 39-bit addresses through TTBR0 from a level-1 table, 4 KiB
   pages, the walks write-back and inner shareable; no TTBR1; a 40-bit
   physical address space. */
#define TCR_VALUE       0x280803519

/* A block's or page's attributes: accessed; RAM normal write-back and
   inner shareable, the kernel's code read-only too (AP[2]), the rest
   device memory that never runs (PXN, UXN). The low two bits say which
   descriptor it is: a block (1), a page or a table (3). */
#define ATTR_RAM        0x704
#define ATTR_CODE       0x784
#define ATTR_DEVICE     0x0060000000000400
#define DESC_BLOCK      1
#define DESC_PAGE       3
#define DESC_TABLE      3
/* How many 2 MiB of the kernel's code get pages of their own, read-only:
   past them it stays writable. */
#define CODE_TABLES     8

/* PSCI's CPU_OFF. */
#define PSCI_CPU_OFF    0x84000002

/* EL2 set up for the kernel at EL1 and left for it, on a core that is at
   EL2; nothing on one at EL1. Uses x9. */
    .macro drop_to_el1
    mrs     x9, CurrentEL
    lsr     x9, x9, #2
    cmp     x9, #2
    b.ne    .Lat_el1\@
    mov     x9, #HCR_EL2_RW
    msr     hcr_el2, x9
    mrs     x9, cnthctl_el2
    orr     x9, x9, #CNTHCTL_EL1PCEN_EL1PCTEN
    msr     cnthctl_el2, x9
    msr     cntvoff_el2, xzr
    mov     x9, #CPTR_EL2_NO_TRAPS
    msr     cptr_el2, x9
    msr     hstr_el2, xzr
    mrs     x9, pmcr_el0
    ubfx    x9, x9, #11, #5         /* PMCR_EL0.N: every counter EL1's */
    msr     mdcr_el2, x9
    mrs     x9, midr_el1
    msr     vpidr_el2, x9
    mrs     x9, mpidr_el1
    msr     vmpidr_el2, x9
    msr     vttbr_el2, xzr
    ldr     x9, =SCTLR_EL1_RES1
    msr     sctlr_el1, x9
    mov     x9, #SPSR_EL1H_MASKED
    msr     spsr_el2, x9
    adr     x9, .Lat_el1\@
    msr     elr_el2, x9
    isb
    eret
.Lat_el1\@:
    .endm

/* The MMU on with the identity map, the caches with it. Uses x9. */
    .macro mmu_on
    ldr     x9, =MAIR_VALUE
    msr     mair_el1, x9
    ldr     x9, =TCR_VALUE
    msr     tcr_el1, x9
    adrp    x9, a64_page_table
    msr     ttbr0_el1, x9
    isb
    tlbi    vmalle1
    dsb     nsh
    isb
    ldr     x9, =SCTLR_EL1_MMU
    msr     sctlr_el1, x9
    isb
    ic      iallu
    dsb     nsh
    isb
    .endm

    .section .text.start, "ax"
    .global _start
    .type _start, %function
_start:
    /* The Image header (Linux's Documentation/arch/arm64/booting.rst). */
    b       _boot                   /* code0 */
    .word   0                       /* code1 */
    .quad   _image_text_offset      /* where in RAM it goes */
    .quad   _image_size             /* how much it takes there */
    .quad   0x2                     /* flags: little-endian, 4 KiB pages */
    .quad   0                       /* res2 */
    .quad   0                       /* res3 */
    .quad   0                       /* res4 */
    .ascii  "ARM\x64"               /* the magic */
    .word   0                       /* res5 */

_boot:
    msr     daifset, #0xf
    mov     x19, x0                 /* the device tree */
    /* An image loaded where it is not linked - the Pi's firmware loads
       nothing above RAM's first GiB - is copied where it is, from its
       header to the end of its data, and goes on there. Only the boot
       core comes here, before anything has been written. With the MMU
       off the copy goes straight to memory; lines the caches hold of
       where it went are dropped, as for .bss below, and so is what the
       instruction cache holds. */
    adr     x9, _start              /* where it is */
    ldr     x10, =_start            /* where it is linked */
    cmp     x9, x10
    b.eq    .Lplaced
    ldr     x11, =_image_end
    mov     x12, x10
1:  ldp     x13, x14, [x9], #16
    stp     x13, x14, [x12], #16
    cmp     x12, x11
    b.lo    1b
    dsb     sy
    mrs     x13, ctr_el0
    ubfx    x13, x13, #16, #4       /* DminLine: log2 of the line in words */
    mov     x14, #4
    lsl     x14, x14, x13           /* the line, in bytes */
    sub     x13, x14, #1
    bic     x12, x10, x13
2:  dc      ivac, x12
    add     x12, x12, x14
    cmp     x12, x11
    b.lo    2b
    dsb     sy
    ic      iallu
    dsb     sy
    isb
    ldr     x9, =.Lplaced
    br      x9
.Lplaced:
    /* The first core here goes on; any other is handed back to the
       firmware, stopped. Plain loads and stores: before the MMU is on
       there are no atomics to rely on, and only one core ever comes. */
    adrp    x9, _boot_claimed
    add     x9, x9, :lo12:_boot_claimed
    ldr     w10, [x9]
    cbnz    w10, _boot_other
    mov     w10, #1
    str     w10, [x9]

    drop_to_el1
    ldr     x9, =SCTLR_EL1_RES1     /* MMU and caches off, as they came */
    msr     sctlr_el1, x9
    mov     x9, #CPACR_FPEN
    msr     cpacr_el1, x9
    isb
    msr     spsel, #1
    adrp    x9, _stack_top
    add     x9, x9, :lo12:_stack_top
    mov     sp, x9
    msr     tpidr_el1, xzr          /* core 0 */

    /* .bss cleared, a doubleword at a time. */
    adrp    x0, _bss_start
    add     x0, x0, :lo12:_bss_start
    adrp    x1, _bss_end
    add     x1, x1, :lo12:_bss_end
1:  cmp     x0, x1
    b.hs    2f
    str     xzr, [x0], #8
    b       1b
2:
    /* The map: a level-1 block a GiB, RAM's normal memory. */
    adrp    x0, a64_page_table
    add     x0, x0, :lo12:a64_page_table
    ldr     x1, =_board_ram_base
    lsr     x1, x1, #30             /* RAM's first GiB */
    ldr     x2, =(_board_ram_end + 0x3FFFFFFF)
    lsr     x2, x2, #30             /* past its last */
    mov     x3, #0                  /* the GiB */
3:  lsl     x4, x3, #30
    cmp     x3, x1
    b.lo    4f
    cmp     x3, x2
    b.hs    4f
    ldr     x5, =(ATTR_RAM | DESC_BLOCK)
    b       5f
4:  ldr     x5, =(ATTR_DEVICE | DESC_BLOCK)
5:  orr     x4, x4, x5
    str     x4, [x0, x3, lsl #3]
    add     x3, x3, #1
    cmp     x3, #512
    b.lo    3b

    /* The first GiB in 2 MiB blocks of what it is, the first 2 MiB in
       pages, page 0 left out. */
    ldr     x6, [x0]
    and     x6, x6, #~3             /* GiB 0's attributes */
    adrp    x1, a64_low_l2
    add     x1, x1, :lo12:a64_low_l2
    mov     x3, #0
6:  lsl     x4, x3, #21
    orr     x4, x4, x6
    orr     x4, x4, #DESC_BLOCK
    str     x4, [x1, x3, lsl #3]
    add     x3, x3, #1
    cmp     x3, #512
    b.lo    6b
    adrp    x2, a64_low_l3
    add     x2, x2, :lo12:a64_low_l3
    str     xzr, [x2]               /* page 0: nothing */
    mov     x3, #1
7:  lsl     x4, x3, #12
    orr     x4, x4, x6
    orr     x4, x4, #DESC_PAGE
    str     x4, [x2, x3, lsl #3]
    add     x3, x3, #1
    cmp     x3, #512
    b.lo    7b
    orr     x4, x2, #DESC_TABLE
    str     x4, [x1]
    orr     x4, x1, #DESC_TABLE
    str     x4, [x0]

    /* The kernel's GiB in 2 MiB blocks of RAM, and the blocks its code is
       in in pages, the code's read-only. */
    adrp    x7, _text_start
    add     x7, x7, :lo12:_text_start
    adrp    x8, _text_end
    add     x8, x8, :lo12:_text_end
    lsr     x9, x7, #30             /* the kernel's GiB */
    lsl     x10, x9, #30            /* where it starts */
    adrp    x1, a64_kernel_l2
    add     x1, x1, :lo12:a64_kernel_l2
    ldr     x6, =ATTR_RAM
    mov     x3, #0
8:  lsl     x4, x3, #21
    add     x4, x4, x10
    orr     x4, x4, x6
    orr     x4, x4, #DESC_BLOCK
    str     x4, [x1, x3, lsl #3]
    add     x3, x3, #1
    cmp     x3, #512
    b.lo    8b
    orr     x4, x1, #DESC_TABLE
    str     x4, [x0, x9, lsl #3]
    adrp    x2, a64_code_l3
    add     x2, x2, :lo12:a64_code_l3
    lsr     x11, x7, #21            /* the code's first 2 MiB */
    sub     x12, x8, #1
    lsr     x12, x12, #21           /* its last */
    add     x13, x11, #(CODE_TABLES - 1)
    cmp     x12, x13
    csel    x12, x12, x13, ls       /* no further than there are tables */
    ldr     x14, =ATTR_CODE
9:  lsl     x15, x11, #21           /* the block's address */
    mov     x3, #0
10: lsl     x4, x3, #12
    add     x4, x4, x15
    cmp     x4, x7
    b.lo    11f
    cmp     x4, x8
    b.hs    11f
    orr     x4, x4, x14             /* code */
    b       12f
11: orr     x4, x4, x6
12: orr     x4, x4, #DESC_PAGE
    str     x4, [x2, x3, lsl #3]
    add     x3, x3, #1
    cmp     x3, #512
    b.lo    10b
    and     x3, x11, #511
    orr     x4, x2, #DESC_TABLE
    str     x4, [x1, x3, lsl #3]
    add     x2, x2, #4096
    add     x11, x11, #1
    cmp     x11, x12
    b.ls    9b

    /* What was written with the MMU off - .bss with the map in it, the
       boot stack, the claim word - dropped from the caches, so the first
       cached read finds it in memory and not a line the firmware left. */
    dsb     sy
    mrs     x9, ctr_el0
    ubfx    x9, x9, #16, #4         /* DminLine: log2 of the line in words */
    mov     x10, #4
    lsl     x10, x10, x9            /* the line, in bytes */
    sub     x11, x10, #1
    adrp    x0, _bss_start
    add     x0, x0, :lo12:_bss_start
    bic     x0, x0, x11
    adrp    x1, _stack_top
    add     x1, x1, :lo12:_stack_top
13: dc      ivac, x0
    add     x0, x0, x10
    cmp     x0, x1
    b.lo    13b
    adrp    x0, _boot_claimed
    add     x0, x0, :lo12:_boot_claimed
    dc      ivac, x0
    dsb     sy

    mmu_on
    adrp    x9, _vectors
    add     x9, x9, :lo12:_vectors
    msr     vbar_el1, x9
    isb
    msr     daifclr, #0xC           /* SErrors and debug exceptions are
                                       taken; IRQs not yet */

    mrs     x0, mpidr_el1
    mov     x1, x19
    mov     x29, #0                 /* terminates backtraces */
    mov     x30, #0
    bl      kmain
14: wfi
    b       14b

_boot_other:
    /* At EL2 only an SMC reaches the firmware; at EL1 QEMU's answers an
       HVC. */
    ldr     x0, =PSCI_CPU_OFF
    mrs     x9, CurrentEL
    lsr     x9, x9, #2
    cmp     x9, #2
    b.ne    15f
    smc     #0
    b       16f
15: hvc     #0
16: wfe                             /* the firmware would not stop it */
    b       16b
    .ltorg
    .size _start, . - _start

/*
 * Where another core comes in, started by core 0 through PSCI's CPU_ON
 * (cpu1.zig): x0 the core number core 0 gave it as its context. It may
 * come in at EL2 even where core 0 came in at EL1 - Trusted Firmware
 * starts a core at the highest non-secure level - and is set up as
 * _start set up core 0: EL2 out of the way, the FPU on, the MMU on with
 * core 0's map, TPIDR_EL1 the core's number, VBAR the vectors - on the
 * stack core 0 set aside for it (a64_core_stacks), read once its caches
 * are on and see what core 0 wrote. Then kmain_other(core).
 */
    .section .text.start_other, "ax"
    .balign 4
    .global _start_other
    .type _start_other, %function
_start_other:
    msr     daifset, #0xf
    mov     x19, x0
    drop_to_el1
    ldr     x9, =SCTLR_EL1_RES1
    msr     sctlr_el1, x9
    mov     x9, #CPACR_FPEN
    msr     cpacr_el1, x9
    isb
    msr     spsel, #1
    mmu_on
    msr     tpidr_el1, x19
    adrp    x9, a64_core_stacks
    add     x9, x9, :lo12:a64_core_stacks
    ldr     x9, [x9, x19, lsl #3]
    mov     sp, x9
    adrp    x9, _vectors
    add     x9, x9, :lo12:_vectors
    msr     vbar_el1, x9
    isb
    msr     daifclr, #0xC
    mov     x0, x19
    mov     x29, #0
    mov     x30, #0
    bl      kmain_other
1:  wfi
    b       1b
    .ltorg
    .size _start_other, . - _start_other

    /* Set by the first core through _boot: in .data, which _start does
       not clear. */
    .section .data
    .balign 8
_boot_claimed:
    .word   0
    .word   0

    /* The identity map's tables: the level-1 table, 512 blocks of
       1 GiB; the first GiB's level-2 and its first 2 MiB's level-3; the
       kernel's GiB's level-2, and the level-3 tables of its code. */
    .section .bss.a64_page_table, "aw", %nobits
    .balign 4096
    .global a64_page_table
a64_page_table:
    .space  4096
    .global a64_low_l2
a64_low_l2:
    .space  4096
a64_low_l3:
    .space  4096
    .global a64_kernel_l2
a64_kernel_l2:
    .space  4096
a64_code_l3:
    .space  CODE_TABLES * 4096

/*
 * The vectors: VBAR_EL1's table, 16 entries of 128 bytes on 2 KiB. Each
 * exception from the kernel's own level on SP_EL1 - the only way the
 * kernel runs - comes to one of the second four; the others are never
 * taken. An entry keeps x0 and x1 in TPIDR_EL0 and TPIDRRO_EL0, which
 * nothing at EL1 uses (there is no EL0), puts what came in x1 and goes to
 * the common path: nothing is on the stack until it is known to have room.
 */
    .macro vector kind
    .balign 128
    msr     tpidr_el0, x0
    msr     tpidrro_el0, x1
    mov     x1, #\kind
    b       _trap_common
    .endm

    .macro unexpected n
    .balign 128
    msr     tpidr_el0, x0
    msr     tpidrro_el0, x1
    mov     x1, #(KIND_UNEXPECTED + \n)
    b       _trap_unexpected
    .endm

    .section .text.vectors, "ax"
    .balign 2048
    .global _vectors
_vectors:
    unexpected 0                    /* current EL with SP_EL0 */
    unexpected 1
    unexpected 2
    unexpected 3
    vector  KIND_SYNC               /* current EL with SP_EL1 */
    vector  KIND_IRQ
    vector  KIND_FIQ
    vector  KIND_SERROR
    unexpected 4                    /* a lower EL in AArch64 */
    unexpected 5
    unexpected 6
    unexpected 7
    unexpected 8                    /* a lower EL in AArch32 */
    unexpected 9
    unexpected 10
    unexpected 11

    .section .text.trap, "ax"
    .balign 16
_trap_common:
    /* The stack it came on must be in RAM with room for the frame: a
       task that ran off its stack would otherwise have every exception
       from here on push its frame further into nothing. One that has no
       room goes to a64_stack_fault (trap.zig) on a stack of its core's
       own, with what can be saved of where it was. The bounds are RAM's
       (a64_stack_low already above its start by a frame), which the
       kernel sets as it starts. */
    adrp    x0, a64_stack_low
    ldr     x0, [x0, :lo12:a64_stack_low]
    cmp     sp, x0
    b.lo    _trap_bad_stack
    adrp    x0, a64_stack_high
    ldr     x0, [x0, :lo12:a64_stack_high]
    cmp     sp, x0
    b.hs    _trap_bad_stack

    sub     sp, sp, #FRAME_SIZE
    stp     x2, x3, [sp, #F_X(2)]
    stp     x4, x5, [sp, #F_X(4)]
    stp     x6, x7, [sp, #F_X(6)]
    stp     x8, x9, [sp, #F_X(8)]
    stp     x10, x11, [sp, #F_X(10)]
    stp     x12, x13, [sp, #F_X(12)]
    stp     x14, x15, [sp, #F_X(14)]
    stp     x16, x17, [sp, #F_X(16)]
    stp     x18, x19, [sp, #F_X(18)]
    stp     x20, x21, [sp, #F_X(20)]
    stp     x22, x23, [sp, #F_X(22)]
    stp     x24, x25, [sp, #F_X(24)]
    stp     x26, x27, [sp, #F_X(26)]
    stp     x28, x29, [sp, #F_X(28)]
    mrs     x2, tpidr_el0
    mrs     x3, tpidrro_el0
    stp     x2, x3, [sp, #F_X(0)]
    add     x2, sp, #FRAME_SIZE
    stp     x30, x2, [sp, #F_X(30)] /* x30, and the interrupted stack pointer */
    mrs     x2, elr_el1
    mrs     x3, spsr_el1
    stp     x2, x3, [sp, #F_ELR]
    mrs     x2, esr_el1
    mrs     x3, far_el1
    stp     x2, x3, [sp, #F_ESR]
    mrs     x2, fpcr
    mrs     x3, fpsr
    stp     x2, x3, [sp, #F_FPCR]
    stp     q0, q1, [sp, #F_Q(0)]
    stp     q2, q3, [sp, #F_Q(2)]
    stp     q4, q5, [sp, #F_Q(4)]
    stp     q6, q7, [sp, #F_Q(6)]
    stp     q8, q9, [sp, #F_Q(8)]
    stp     q10, q11, [sp, #F_Q(10)]
    stp     q12, q13, [sp, #F_Q(12)]
    stp     q14, q15, [sp, #F_Q(14)]
    stp     q16, q17, [sp, #F_Q(16)]
    stp     q18, q19, [sp, #F_Q(18)]
    stp     q20, q21, [sp, #F_Q(20)]
    stp     q22, q23, [sp, #F_Q(22)]
    stp     q24, q25, [sp, #F_Q(24)]
    stp     q26, q27, [sp, #F_Q(26)]
    stp     q28, q29, [sp, #F_Q(28)]
    stp     q30, q31, [sp, #F_Q(30)]

    mov     x0, sp
    mov     x29, #0                 /* the chain ends at the exception */
    bl      a64_exception           /* x0 = the frame to resume */
    mov     x1, sp
    cmp     x0, x1
    b.eq    .Lresume

    /* A task switch: onto the other task's stack. Off the task left, and
       nothing of it in the registers: another core may resume it now
       (context.zig, task_leaving[core] = 0). */
    mov     sp, x0
    mrs     x1, tpidr_el1
    adrp    x2, task_leaving
    add     x2, x2, :lo12:task_leaving
    dmb     ish
    str     xzr, [x2, x1, lsl #3]
    dmb     ish

.Lresume:
    ldp     q0, q1, [x0, #F_Q(0)]
    ldp     q2, q3, [x0, #F_Q(2)]
    ldp     q4, q5, [x0, #F_Q(4)]
    ldp     q6, q7, [x0, #F_Q(6)]
    ldp     q8, q9, [x0, #F_Q(8)]
    ldp     q10, q11, [x0, #F_Q(10)]
    ldp     q12, q13, [x0, #F_Q(12)]
    ldp     q14, q15, [x0, #F_Q(14)]
    ldp     q16, q17, [x0, #F_Q(16)]
    ldp     q18, q19, [x0, #F_Q(18)]
    ldp     q20, q21, [x0, #F_Q(20)]
    ldp     q22, q23, [x0, #F_Q(22)]
    ldp     q24, q25, [x0, #F_Q(24)]
    ldp     q26, q27, [x0, #F_Q(26)]
    ldp     q28, q29, [x0, #F_Q(28)]
    ldp     q30, q31, [x0, #F_Q(30)]
    ldp     x2, x3, [x0, #F_FPCR]
    msr     fpcr, x2
    msr     fpsr, x3
    ldp     x2, x3, [x0, #F_ELR]
    msr     elr_el1, x2             /* where it goes on */
    msr     spsr_el1, x3            /* its interrupt state */
    ldp     x2, x3, [x0, #F_X(2)]
    ldp     x4, x5, [x0, #F_X(4)]
    ldp     x6, x7, [x0, #F_X(6)]
    ldp     x8, x9, [x0, #F_X(8)]
    ldp     x10, x11, [x0, #F_X(10)]
    ldp     x12, x13, [x0, #F_X(12)]
    ldp     x14, x15, [x0, #F_X(14)]
    ldp     x16, x17, [x0, #F_X(16)]
    ldp     x18, x19, [x0, #F_X(18)]
    ldp     x20, x21, [x0, #F_X(20)]
    ldp     x22, x23, [x0, #F_X(22)]
    ldp     x24, x25, [x0, #F_X(24)]
    ldp     x26, x27, [x0, #F_X(26)]
    ldp     x28, x29, [x0, #F_X(28)]
    /* The stack pointer before the last two: the frame stays below it,
       and with every exception masked nothing comes to write over it. */
    ldr     x1, [x0, #F_SP]
    mov     sp, x1
    ldr     x30, [x0, #F_X(30)]
    ldp     x0, x1, [x0, #F_X(0)]
    eret
    .size _trap_common, . - _trap_common

/*
 * An exception on a stack with no room: the stack pointer, where it came
 * from and why, the address it named, the link register and the frame
 * pointer to a64_stack_fault, on the core's fault stack. It does not come
 * back.
 */
_trap_bad_stack:
    mov     x0, sp
    mrs     x2, tpidr_el1
    add     x2, x2, #1
    lsl     x2, x2, #11             /* (core + 1) * FAULT_STACK_SIZE */
    adrp    x3, a64_fault_stacks
    add     x3, x3, :lo12:a64_fault_stacks
    add     x3, x3, x2
    mov     sp, x3
    mrs     x1, elr_el1
    mrs     x2, esr_el1
    mrs     x3, far_el1
    mov     x4, x30
    mov     x5, x29
    mov     x29, #0
    bl      a64_stack_fault
1:  b       1b

/*
 * A vector that is never taken: on the core's fault stack, with what it
 * has, to a64_unexpected. It does not come back.
 */
_trap_unexpected:
    mov     x0, sp
    mrs     x2, tpidr_el1
    add     x2, x2, #1
    lsl     x2, x2, #11
    adrp    x3, a64_fault_stacks
    add     x3, x3, :lo12:a64_fault_stacks
    add     x3, x3, x2
    mov     sp, x3
    mov     x6, x1                  /* which vector */
    mrs     x1, elr_el1
    mrs     x2, esr_el1
    mrs     x3, far_el1
    mov     x4, x30
    mov     x5, x29
    mov     x29, #0
    bl      a64_unexpected
2:  b       2b

    .section .bss.a64_fault_stacks, "aw", %nobits
    .balign 16
    .global a64_fault_stacks
a64_fault_stacks:
    .space  MAX_CORES * FAULT_STACK_SIZE

/*
 * i32 a64_call_on_stack(usize stack_upper, fn code, void *arg), for
 * exec's NewStackRun: code(arg) on the stack that ends at stack_upper
 * (rounded down to 16 bytes), and its answer. The caller's stack pointer
 * is kept in x29, which code saves and puts back as every callee does.
 */
    .section .text.a64_call_on_stack, "ax"
    .global a64_call_on_stack
    .type a64_call_on_stack, %function
a64_call_on_stack:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    and     x9, x0, #0xFFFFFFFFFFFFFFF0
    mov     sp, x9
    mov     x0, x2
    blr     x1
    mov     sp, x29
    ldp     x29, x30, [sp], #16
    ret
    .size a64_call_on_stack, . - a64_call_on_stack
