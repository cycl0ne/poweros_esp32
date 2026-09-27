/* SPDX-License-Identifier: MPL-2.0 */
/*
 * DCache lines written back with the cache frozen - one line, or a range -
 * for exec's cache functions (src/rom/libs/exec/cache/_cache.zig): ESP-IDF's
 * workaround for the ESP32-S3's cache errata
 * (esp_rom_cache_writeback_esp32s3.S). While a
 * write-back runs, a CPU that touches the same line may hit it with a wrong
 * value. So interrupts go off and the DCache is frozen; then the write-back
 * runs, and the cache thaws.
 *
 * While the cache is frozen, this code must not touch any cached address,
 * or it waits for itself: no stack (it may be in PSRAM), no literals after
 * the freeze, no calls. The registers it uses are all touched before the
 * freeze (a2 to a7, and a8 for the range's size), so any window overflow
 * comes before it too.
 *
 * void cache_writeback_line_frozen(u32 addr): the line holding addr.
 */
#define EXTMEM_DCACHE_SYNC_CTRL     0x600C4028
#define EXTMEM_DCACHE_SYNC_ADDR     0x600C402C
#define EXTMEM_DCACHE_SYNC_SIZE     0x600C4030
#define EXTMEM_DCACHE_FREEZE        0x600C4150
#define SYNC_WRITEBACK_ENA          0x2
#define SYNC_DONE                   0x8
#define FREEZE_ENA                  0x1
#define FREEZE_DONE                 0x4
#define NMI_LEVEL                   7

    .section .iram.text, "ax"
    .align 4
.Llit_sync_ctrl:    .long EXTMEM_DCACHE_SYNC_CTRL
.Llit_sync_addr:    .long EXTMEM_DCACHE_SYNC_ADDR
.Llit_sync_size:    .long EXTMEM_DCACHE_SYNC_SIZE
.Llit_freeze:       .long EXTMEM_DCACHE_FREEZE

    .align 4
    .global cache_writeback_line_frozen
    .type cache_writeback_line_frozen, @function
cache_writeback_line_frozen:
    entry   a1, 32
    l32r    a3, .Llit_sync_addr
    l32r    a4, .Llit_sync_size
    l32r    a5, .Llit_freeze
    l32r    a7, .Llit_sync_ctrl
    rsil    a6, NMI_LEVEL           /* all interrupts off */
    s32i    a2, a3, 0               /* SYNC_ADDR: the line */
    movi    a3, 1
    s32i    a3, a4, 0               /* SYNC_SIZE: one byte, so that line */
    memw

    l32i    a3, a5, 0               /* freeze: FREEZE_MODE 0, FREEZE_ENA 1 */
    movi    a4, -3                  /* ~FREEZE_MODE */
    and     a3, a3, a4
    movi    a4, FREEZE_ENA
    or      a3, a3, a4
    s32i    a3, a5, 0
    movi    a4, FREEZE_DONE
.Lfreezing:
    l32i    a3, a5, 0
    memw
    bnone   a3, a4, .Lfreezing

    l32i    a3, a7, 0               /* the write-back */
    movi    a4, SYNC_WRITEBACK_ENA
    or      a3, a3, a4
    s32i    a3, a7, 0
    movi    a4, SYNC_DONE
.Lwriting:
    l32i    a3, a7, 0
    memw
    bnone   a3, a4, .Lwriting

    l32i    a3, a5, 0               /* thaw: FREEZE_ENA 0 */
    movi    a4, -2                  /* ~FREEZE_ENA */
    and     a3, a3, a4
    s32i    a3, a5, 0
    movi    a4, FREEZE_DONE
.Lthawing:
    l32i    a3, a5, 0
    memw
    bany    a3, a4, .Lthawing

    wsr     a6, ps                  /* interrupts as they were */
    rsync
    retw
    .size cache_writeback_line_frozen, . - cache_writeback_line_frozen

/*
 * void cache_writeback_range_frozen(u32 addr, u32 size): the same for the
 * lines of `size` bytes at `addr` (whole lines, at most the 8 MB the size
 * register holds). What the whole cache's write-back is made of: those
 * lines include every task's stack, which an interrupt touches.
 */
    .align 4
    .global cache_writeback_range_frozen
    .type cache_writeback_range_frozen, @function
cache_writeback_range_frozen:
    entry   a1, 32
    mov     a8, a3                  /* the size, before a3 is reused */
    l32r    a3, .Llit_sync_addr
    l32r    a4, .Llit_sync_size
    l32r    a5, .Llit_freeze
    l32r    a7, .Llit_sync_ctrl
    rsil    a6, NMI_LEVEL           /* all interrupts off */
    s32i    a2, a3, 0               /* SYNC_ADDR */
    s32i    a8, a4, 0               /* SYNC_SIZE */
    memw

    l32i    a3, a5, 0               /* freeze: FREEZE_MODE 0, FREEZE_ENA 1 */
    movi    a4, -3
    and     a3, a3, a4
    movi    a4, FREEZE_ENA
    or      a3, a3, a4
    s32i    a3, a5, 0
    movi    a4, FREEZE_DONE
.Lrfreezing:
    l32i    a3, a5, 0
    memw
    bnone   a3, a4, .Lrfreezing

    l32i    a3, a7, 0               /* the write-back */
    movi    a4, SYNC_WRITEBACK_ENA
    or      a3, a3, a4
    s32i    a3, a7, 0
    movi    a4, SYNC_DONE
.Lrwriting:
    l32i    a3, a7, 0
    memw
    bnone   a3, a4, .Lrwriting

    l32i    a3, a5, 0               /* thaw */
    movi    a4, -2
    and     a3, a3, a4
    s32i    a3, a5, 0
    movi    a4, FREEZE_DONE
.Lrthawing:
    l32i    a3, a5, 0
    memw
    bany    a3, a4, .Lrthawing

    wsr     a6, ps
    rsync
    retw
    .size cache_writeback_range_frozen, . - cache_writeback_range_frozen
