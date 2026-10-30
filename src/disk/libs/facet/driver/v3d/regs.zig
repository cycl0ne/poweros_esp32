// SPDX-License-Identifier: MIT
//! The registers of the V3D 7.1 in the BCM2712, as far as the driver uses
//! them. Offsets and fields as Linux's drivers/gpu/drm/v3d/v3d_regs.h names
//! them: nothing else here is known to read safely, and a read at an address
//! nothing answers halts the machine.

// --- the hub: what the cores share ------------------------------------------

pub const HUB_AXICFG: usize = 0x00000;
pub const HUB_IDENT0: usize = 0x00008;
/// 19 MSO, 18 TSY, 17 TFU, 16 L3C; 15:12 hosts; 11:8 cores; 7:4 revision;
/// 3:0 version.
pub const HUB_IDENT1: usize = 0x0000c;
/// 8 an MMU; 7:0 L3C's KiB.
pub const HUB_IDENT2: usize = 0x00010;
/// 15:8 IP revision; 7:0 IP index.
pub const HUB_IDENT3: usize = 0x00014;

pub const HUB_INT_STS: usize = 0x00050;
pub const HUB_INT_CLR: usize = 0x00058;
pub const HUB_INT_MSK_SET: usize = 0x00060;
pub const HUB_INT_MSK_CLR: usize = 0x00064;
pub const HUB_INT_GMPV: u32 = 1 << 6;
pub const HUB_INT_MMU_WRV: u32 = 1 << 5;
pub const HUB_INT_MMU_PTI: u32 = 1 << 4;
pub const HUB_INT_MMU_CAP: u32 = 1 << 3;
pub const HUB_INT_TFUC: u32 = 1 << 1;

pub const MMUC_CONTROL: usize = 0x01000;
pub const MMUC_CONTROL_FLUSHING: u32 = 1 << 2;
pub const MMUC_CONTROL_FLUSH: u32 = 1 << 1;
pub const MMUC_CONTROL_ENABLE: u32 = 1 << 0;

pub const MMU_CTL: usize = 0x01200;
pub const MMU_CTL_CAP_EXCEEDED_ABORT: u32 = 1 << 26;
pub const MMU_CTL_CAP_EXCEEDED_INT: u32 = 1 << 25;
pub const MMU_CTL_PT_INVALID_ABORT: u32 = 1 << 19;
pub const MMU_CTL_PT_INVALID_INT: u32 = 1 << 18;
pub const MMU_CTL_PT_INVALID_ENABLE: u32 = 1 << 16;
pub const MMU_CTL_WRITE_VIOLATION_ABORT: u32 = 1 << 11;
pub const MMU_CTL_WRITE_VIOLATION_INT: u32 = 1 << 10;
pub const MMU_CTL_TLB_CLEARING: u32 = 1 << 7;
pub const MMU_CTL_TLB_CLEAR: u32 = 1 << 2;
pub const MMU_CTL_ENABLE: u32 = 1 << 0;
pub const MMU_PT_PA_BASE: usize = 0x01204;
/// AXI ID of the access that faulted: 7:5 which client.
pub const MMU_VIO_ID: usize = 0x0122c;
pub const MMU_ILLEGAL_ADDR: usize = 0x01230;
pub const MMU_ILLEGAL_ADDR_ENABLE: u32 = 1 << 31;
/// The address that faulted, shifted right by the virtual address bits
/// less 32.
pub const MMU_VIO_ADDR: usize = 0x01234;
/// 11:8 physical address bits less 30; 7:4 virtual address bits less 30;
/// 3:0 version.
pub const MMU_DEBUG_INFO: usize = 0x01238;

/// What the MMU's PTEs hold: these and the page's number.
pub const PTE_SUPERPAGE: u32 = 1 << 31;
pub const PTE_BIGPAGE: u32 = 1 << 30;
pub const PTE_WRITEABLE: u32 = 1 << 29;
pub const PTE_VALID: u32 = 1 << 28;

// --- a core, offset from its own registers ----------------------------------

/// 31:24 version.
pub const CTL_IDENT0: usize = 0x00000;
/// 31:28 VPM's size, in 8 KiB; 23:16 semaphores; 15:12 TMUs; 11:8 QPUs a slice;
/// 7:4 slices; 3:0 revision.
pub const CTL_IDENT1: usize = 0x00004;
pub const CTL_IDENT2: usize = 0x00008;
/// The read-only caches of a slice, invalidated: the 4 bits of each of them.
pub const CTL_SLCACTL: usize = 0x00024;
pub const SLCACTL_ALL: u32 = 0x0F0F_0F0F;
pub const CTL_L2TCACTL: usize = 0x00030;
pub const L2TCACTL_TMUWCF: u32 = 1 << 8;
pub const L2TCACTL_FLM_FLUSH: u32 = 0 << 1;
pub const L2TCACTL_FLM_CLEAR: u32 = 1 << 1;
pub const L2TCACTL_FLM_CLEAN: u32 = 2 << 1;
pub const L2TCACTL_L2TFLS: u32 = 1 << 0;
pub const CTL_L2TFLSTA: usize = 0x00034;
pub const CTL_L2TFLEND: usize = 0x00038;

pub const CTL_INT_STS: usize = 0x00050;
pub const CTL_INT_CLR: usize = 0x00058;
pub const CTL_INT_MSK_SET: usize = 0x00060;
pub const CTL_INT_MSK_CLR: usize = 0x00064;
pub const INT_CSDDONE: u32 = 1 << 6;
pub const INT_OUTOMEM: u32 = 1 << 2;
pub const INT_FLDONE: u32 = 1 << 1;
pub const INT_FRDONE: u32 = 1 << 0;

pub const CLE_CT0CS: usize = 0x00100;
pub const CLE_CT1CS: usize = 0x00104;
pub const CLE_CT0EA: usize = 0x00108;
pub const CLE_CT1EA: usize = 0x0010c;
pub const CLE_CT0CA: usize = 0x00110;
pub const CLE_CT1CA: usize = 0x00114;
/// Frames the binner and the renderer have finished, each counted to 255.
pub const CLE_BFC: usize = 0x00134;
pub const CLE_RFC: usize = 0x00138;
/// Where the binner keeps its state of a tile, with this to say so.
pub const CLE_CT0QTS: usize = 0x0015c;
pub const CLE_CT0QTS_ENABLE: u32 = 1 << 1;
pub const CLE_CT0QBA: usize = 0x00160;
pub const CLE_CT1QBA: usize = 0x00164;
pub const CLE_CT0QEA: usize = 0x00168;
pub const CLE_CT1QEA: usize = 0x0016c;
pub const CLE_CT0QMA: usize = 0x00170;
pub const CLE_CT0QMS: usize = 0x00174;

/// The binner's memory: the address and the bytes it has, and the overflow
/// it is given as it runs out.
pub const PTB_BPCA: usize = 0x00300;
pub const PTB_BPCS: usize = 0x00304;
pub const PTB_BPOA: usize = 0x00308;
pub const PTB_BPOS: usize = 0x0030c;

// --- SMS, the state machine that runs the core's power ----------------------

pub const SMS_REE_CS: usize = 0x00000;
pub const SMS_TEE_CS: usize = 0x00400;
pub const SMS_CLEAR_POWER_OFF: u32 = 1 << 29;
pub const SMS_STATE_MASK: u32 = 0xF;
pub const SMS_IDLE: u32 = 0x0;
/// Written, it asks for a reset.
pub const SMS_RESET: u32 = 0x4;
pub const SMS_ISOLATING_FOR_RESET: u32 = 0xa;
pub const SMS_RESETTING: u32 = 0xb;

// --- the power manager the core's reset is in -------------------------------

/// What each write to the power manager carries.
pub const PM_PASSWORD: u32 = 0x5a00_0000;
pub const PM_GRAFX: usize = 0x304;
/// Set, the core is out of reset.
pub const PM_V3DRSTN: u32 = 1 << 6;
