/* SPDX-License-Identifier: MPL-2.0 */
/*
 * One DCache line written back with the cache frozen, for exec's cache
 * functions (src/rom/libs/exec/cacheio.zig): ESP-IDF's workaround for the
 * ESP32-S3's cache errata (esp_rom_cache_writeback_esp32s3.S). While a
 * write-back runs, a CPU that touches the same line may hit it with a wrong
 * value. So interrupts go off and the DCache is frozen; then the write-back
 * runs, and the cache thaws.
 *
 * While the cache is frozen, this code must not touch any cached address,
 * or it waits for itself: no stack (it may be in PSRAM), no literals after
 * the freeze, no calls. It uses a2 to a7 only, so the one window overflow
 * that may come is at `entry`, before the freeze.
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
