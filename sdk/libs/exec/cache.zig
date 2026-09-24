// SPDX-License-Identifier: MIT
//! The cache functions' flags (exec/execbase.h), at their CACRF_* bit
//! positions: CacheClearE's caches and CachePreDMA's and CachePostDMA's
//! flags. Only what the ESP32-S3 uses; the bits for enable, freeze, burst,
//! write-allocate, copyback and external caches are CacheControl's, which
//! is left out.

/// CacheClearE: clear the instruction cache.
pub const CACRF_ClearI: u32 = 1 << 3;
/// CacheClearE: clear the data cache (write back, then invalidate).
pub const CACRF_ClearD: u32 = 1 << 11;

/// CachePreDMA: this call continues a request that was broken up.
pub const DMAF_Continue: u32 = 1 << 1;
/// CachePostDMA: the DMA didn't change memory.
pub const DMAF_NoModify: u32 = 1 << 2;
/// The DMA goes from memory to the device (must match in both calls).
pub const DMAF_ReadFromRAM: u32 = 1 << 3;
