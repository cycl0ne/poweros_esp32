// SPDX-License-Identifier: MIT
//! Where the ESP32-P4's peripherals are: each block's base address, by the
//! name the chip's manual gives it - the high-performance peripherals in
//! two blocks (HPPERIPH0 at 0x5000_0000, HPPERIPH1 at 0x500C_0000), the LP
//! ones that stay on (LPAON at 0x5011_0000) and the LP peripherals (LPPERI
//! at 0x5012_0000). A driver adds its register offsets to these; nothing
//! else in the system writes one of these numbers down.
//!
//! From ESP-IDF v6.1's soc/esp32p4/register/hw_ver1/soc/reg_base.h, the
//! boards' chips' (v1.3). Only addresses: which driver may use a block is
//! not decided here.

/// The windows memory is reached through, for code that must know
/// whether an address can be read at all. L2MEM is the internal memory,
/// 768 KiB, where exec's locks take their atomic instructions (in PSRAM
/// they go through exec's guard word).
pub const DRAM_START: usize = 0x4FF0_0000;
pub const DRAM_END: usize = 0x4FFC_0000;
/// The tightly coupled memory, 8 KiB.
pub const TCM_START: usize = 0x3010_0000;
pub const TCM_END: usize = 0x3010_2000;
/// The HP mask ROM, 128 KiB.
pub const ROM_START: usize = 0x4FC0_0000;
pub const ROM_END: usize = 0x4FC2_0000;
/// Flash and PSRAM, each through the cache and its MMU.
pub const FLASH_START: usize = 0x4000_0000;
pub const FLASH_END: usize = 0x4400_0000;
pub const PSRAM_START: usize = 0x4800_0000;
pub const PSRAM_END: usize = 0x4C00_0000;

pub const HPCPUTCP: usize = 0x3FF0_0000;
pub const HPPERIPH0: usize = 0x5000_0000;
pub const HPPERIPH1: usize = 0x500C_0000;
pub const LPAON: usize = 0x5011_0000;
pub const LPPERIPH: usize = 0x5012_0000;
pub const TRACE0: usize = 0x3FF0_4000;
pub const TRACE1: usize = 0x3FF0_5000;
pub const CPU_BUS_MON: usize = 0x3FF0_6000;
pub const L2MEM_MON: usize = 0x3FF0_E000;
pub const TCM_MON: usize = 0x3FF0_F000;
pub const CACHE: usize = 0x3FF1_0000;
pub const USB2: usize = 0x5000_0000;
pub const USB11: usize = 0x5004_0000;
pub const USB_WRAP: usize = 0x5008_0000;
pub const GDMA: usize = 0x5008_1000;
pub const REGDMA: usize = 0x5008_2000;
pub const SDMMC: usize = 0x5008_3000;
pub const H264_CORE: usize = 0x5008_4000;
pub const AHB_DMA: usize = 0x5008_5000;
pub const JPEG: usize = 0x5008_6000;
pub const PPA: usize = 0x5008_7000;
pub const DMA2D: usize = 0x5008_8000;
pub const KEYMNG: usize = 0x5008_9000;
pub const AXI_DMA: usize = 0x5008_A000;
pub const FLASH_SPI0: usize = 0x5008_C000;
pub const FLASH_SPI1: usize = 0x5008_D000;
pub const PSRAM_MSPI0: usize = 0x5008_E000;
pub const PSRAM_MSPI1: usize = 0x5008_F000;
pub const CRYPTO: usize = 0x5009_0000;
pub const EMAC: usize = 0x5009_8000;
pub const USBPHY: usize = 0x5009_C000;
pub const DDRPHY: usize = 0x5009_D000;
pub const PVT: usize = 0x5009_E000;
pub const CSI_HOST: usize = 0x5009_F000;
pub const CSI_BRG: usize = 0x5009_F800;
pub const DSI_HOST: usize = 0x500A_0000;
pub const DSI_BRG: usize = 0x500A_0800;
pub const ISP: usize = 0x500A_1000;
pub const RMT: usize = 0x500A_2000;
pub const BITSCRAMBLER: usize = 0x500A_3000;
pub const AXI_ICM: usize = 0x500A_4000;
pub const AXI_ICM_QOS: usize = 0x500A_4400;
pub const HP_PERI_PMS: usize = 0x500A_5000;
pub const LP2HP_PERI_PMS: usize = 0x500A_5800;
pub const DMA_PMS: usize = 0x500A_6000;
pub const H264_DMA_2D: usize = 0x500A_7000;
pub const MCPWM0: usize = 0x500C_0000;
pub const MCPWM1: usize = 0x500C_1000;
pub const TIMG0: usize = 0x500C_2000;
pub const TIMG1: usize = 0x500C_3000;
pub const I2C0: usize = 0x500C_4000;
pub const I2C1: usize = 0x500C_5000;
pub const I2S0: usize = 0x500C_6000;
pub const I2S1: usize = 0x500C_7000;
pub const I2S2: usize = 0x500C_8000;
pub const PCNT: usize = 0x500C_9000;
pub const UART0: usize = 0x500C_A000;
pub const UART1: usize = 0x500C_B000;
pub const UART2: usize = 0x500C_C000;
pub const UART3: usize = 0x500C_D000;
pub const UART4: usize = 0x500C_E000;
pub const PARIO: usize = 0x500C_F000;
pub const SPI2: usize = 0x500D_0000;
pub const SPI3: usize = 0x500D_1000;
pub const USB2JTAG: usize = 0x500D_2000;
pub const LEDC: usize = 0x500D_3000;
pub const ETM: usize = 0x500D_5000;
pub const INTR: usize = 0x500D_6000;
pub const TWAI0: usize = 0x500D_7000;
pub const TWAI1: usize = 0x500D_8000;
pub const TWAI2: usize = 0x500D_9000;
pub const I3C_MST: usize = 0x500D_A000;
pub const I3C_MST_MEM: usize = 0x500D_A000;
pub const I3C_SLV: usize = 0x500D_B000;
pub const LCDCAM: usize = 0x500D_C000;
pub const ADC: usize = 0x500D_E000;
pub const UHCI: usize = 0x500D_F000;
pub const GPIO: usize = 0x500E_0000;
pub const GPIO_EXT: usize = 0x500E_0F00;
pub const IO_MUX: usize = 0x500E_1000;
pub const IOMUX_MSPI_PIN: usize = 0x500E_1200;
pub const SYSTIMER: usize = 0x500E_2000;
pub const MEM_MON: usize = 0x500E_3000;
pub const AUDIO_ADDC: usize = 0x500E_4000;
pub const HP_SYS: usize = 0x500E_5000;
pub const HP_SYS_CLKRST: usize = 0x500E_6000;
pub const LP_SYS: usize = 0x5011_0000;
pub const LP_CLKRST: usize = 0x5011_1000;
pub const LP_TIMER: usize = 0x5011_2000;
pub const LP_ANALOG_PERI: usize = 0x5011_3000;
pub const LP_HUK: usize = 0x5011_4000;
pub const HUK: usize = 0x5011_4000;
pub const PMU: usize = 0x5011_5000;
pub const LP_WDT: usize = 0x5011_6000;
pub const LP_MB: usize = 0x5011_8000;
pub const RTC: usize = 0x5011_9000;
pub const LP_PERI_CLKRST: usize = 0x5012_0000;
pub const LP_PERI: usize = 0x5012_0000;
pub const LP_UART: usize = 0x5012_1000;
pub const LP_I2C: usize = 0x5012_2000;
pub const LP_SPI: usize = 0x5012_3000;
pub const LP_I2C_ANA_MST: usize = 0x5012_4000;
pub const LP_I2S: usize = 0x5012_5000;
pub const LP_ADC: usize = 0x5012_7000;
pub const LP_TOUCH: usize = 0x5012_8000;
pub const LP_GPIO: usize = 0x5012_A000;
pub const LP_IOMUX: usize = 0x5012_B000;
pub const LP_INTR: usize = 0x5012_C000;
pub const EFUSE: usize = 0x5012_D000;
pub const LP_PERI_PMS: usize = 0x5012_E000;
pub const HP2LP_PERI_PMS: usize = 0x5012_E800;
pub const LP_TSENSOR: usize = 0x5012_F000;
pub const UART: usize = UART0;
pub const UHCI0: usize = UHCI;
pub const TIMERGROUP0: usize = TIMG0;
pub const TIMERGROUP1: usize = TIMG1;
pub const I2S: usize = I2S0;
pub const USB_SERIAL_JTAG: usize = USB2JTAG;
pub const INTMTX: usize = INTR;
pub const SOC_ETM: usize = ETM;
pub const MCPWM: usize = MCPWM0;
pub const PARL_IO: usize = PARIO;
pub const PVT_MONITOR: usize = PVT;
pub const AES: usize = 0x5009_0000;
pub const SHA: usize = 0x5009_1000;
pub const RSA: usize = 0x5009_2000;
pub const ECC_MULT: usize = 0x5009_3000;
pub const DS: usize = 0x5009_4000;
pub const DIGITAL_SIGNATURE: usize = DS;
pub const HMAC: usize = 0x5009_5000;
pub const ECDSA: usize = 0x5009_6000;
pub const MEM_MONITOR: usize = L2MEM_MON;
pub const HP_CLKRST: usize = HP_SYS_CLKRST;
pub const DSPI_MEM: usize = PSRAM_MSPI0;
pub const INTERRUPT_CORE0: usize = INTR;
pub const INTERRUPT_CORE1: usize = 0x500D_6800;
pub const LPPERI: usize = LP_PERI_CLKRST;
pub const CPU_BUS_MONITOR: usize = CPU_BUS_MON;
pub const ASSIST_DEBUG: usize = CPU_BUS_MON;
pub const PAU: usize = REGDMA;
pub const SDHOST: usize = SDMMC;
pub const TRACE: usize = TRACE0;

/// The random number generator's one register (LP_SYSTEM_REG_RNG_DATA_REG).
pub const RNG_DATA: usize = LP_SYS + 0x1A4;
