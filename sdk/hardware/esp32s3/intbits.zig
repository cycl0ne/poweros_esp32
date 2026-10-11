// SPDX-License-Identifier: MIT
//! The ESP32-S3's peripheral interrupt sources, by name: exec's interrupt
//! numbers (SetIntVector, AddIntServer): the interrupt matrix's sources,
//! 0 to 98, each routed to a CPU line of its own while a
//! handler or server is on it.
//!
//! From ESP-IDF v6.1's soc/esp32s3/include/soc/interrupts.h: ETS_<name>_INTR_SOURCE
//! is INTB_<name> (ETS_<name>_SOURCE too). The deprecated aliases
//! (ETS_SYSTIMER_TARGETn_EDGE_INTR_SOURCE) are left out; ESP-IDF names no
//! source 23, 33, 34, 46.

/// ETS_WIFI_MAC_INTR_SOURCE: interrupt of WiFi MAC, level
pub const INTB_WIFI_MAC: u32 = 0;
/// ETS_WIFI_MAC_NMI_SOURCE: interrupt of WiFi MAC, NMI, use if MAC have bug to fix in NMI
pub const INTB_WIFI_MAC_NMI: u32 = 1;
/// ETS_WIFI_PWR_INTR_SOURCE
pub const INTB_WIFI_PWR: u32 = 2;
/// ETS_WIFI_BB_INTR_SOURCE: interrupt of WiFi BB, level, we can do some calibartion
pub const INTB_WIFI_BB: u32 = 3;
/// ETS_BT_MAC_INTR_SOURCE: will be cancelled
pub const INTB_BT_MAC: u32 = 4;
/// ETS_BT_BB_INTR_SOURCE: interrupt of BT BB, level
pub const INTB_BT_BB: u32 = 5;
/// ETS_BT_BB_NMI_SOURCE: interrupt of BT BB, NMI, use if BB have bug to fix in NMI
pub const INTB_BT_BB_NMI: u32 = 6;
/// ETS_RWBT_INTR_SOURCE: interrupt of RWBT, level
pub const INTB_RWBT: u32 = 7;
/// ETS_RWBLE_INTR_SOURCE: interrupt of RWBLE, level
pub const INTB_RWBLE: u32 = 8;
/// ETS_RWBT_NMI_SOURCE: interrupt of RWBT, NMI, use if RWBT have bug to fix in NMI
pub const INTB_RWBT_NMI: u32 = 9;
/// ETS_RWBLE_NMI_SOURCE: interrupt of RWBLE, NMI, use if RWBT have bug to fix in NMI
pub const INTB_RWBLE_NMI: u32 = 10;
/// ETS_I2C_MASTER_SOURCE: interrupt of I2C Master, level
pub const INTB_I2C_MASTER: u32 = 11;
/// ETS_SLC0_INTR_SOURCE: interrupt of SLC0, level
pub const INTB_SLC0: u32 = 12;
/// ETS_SLC1_INTR_SOURCE: interrupt of SLC1, level
pub const INTB_SLC1: u32 = 13;
/// ETS_UHCI0_INTR_SOURCE: interrupt of UHCI0, level
pub const INTB_UHCI0: u32 = 14;
/// ETS_UHCI1_INTR_SOURCE: interrupt of UHCI1, level
pub const INTB_UHCI1: u32 = 15;
/// ETS_GPIO_INTR_SOURCE: interrupt of GPIO, level
pub const INTB_GPIO: u32 = 16;
/// ETS_GPIO_NMI_SOURCE: interrupt of GPIO, NMI
pub const INTB_GPIO_NMI: u32 = 17;
/// ETS_GPIO_INTR_SOURCE2: interrupt of GPIO, level
pub const INTB_GPIO2: u32 = 18;
/// ETS_GPIO_NMI_SOURCE2: interrupt of GPIO, NMI
pub const INTB_GPIO_NMI2: u32 = 19;
/// ETS_SPI1_INTR_SOURCE: interrupt of SPI1, level, SPI1 is for flash read/write, do not use this
pub const INTB_SPI1: u32 = 20;
/// ETS_SPI2_INTR_SOURCE: interrupt of SPI2, level
pub const INTB_SPI2: u32 = 21;
/// ETS_SPI3_INTR_SOURCE: interrupt of SPI3, level
pub const INTB_SPI3: u32 = 22;
/// ETS_LCD_CAM_INTR_SOURCE: interrupt of LCD camera, level
pub const INTB_LCD_CAM: u32 = 24;
/// ETS_I2S0_INTR_SOURCE: interrupt of I2S0, level
pub const INTB_I2S0: u32 = 25;
/// ETS_I2S1_INTR_SOURCE: interrupt of I2S1, level
pub const INTB_I2S1: u32 = 26;
/// ETS_UART0_INTR_SOURCE: interrupt of UART0, level
pub const INTB_UART0: u32 = 27;
/// ETS_UART1_INTR_SOURCE: interrupt of UART1, level
pub const INTB_UART1: u32 = 28;
/// ETS_UART2_INTR_SOURCE: interrupt of UART2, level
pub const INTB_UART2: u32 = 29;
/// ETS_SDIO_HOST_INTR_SOURCE: interrupt of SD/SDIO/MMC HOST, level
pub const INTB_SDIO_HOST: u32 = 30;
/// ETS_PWM0_INTR_SOURCE: interrupt of PWM0, level, Reserved
pub const INTB_PWM0: u32 = 31;
/// ETS_PWM1_INTR_SOURCE: interrupt of PWM1, level, Reserved
pub const INTB_PWM1: u32 = 32;
/// ETS_LEDC_INTR_SOURCE: interrupt of LED PWM, level
pub const INTB_LEDC: u32 = 35;
/// ETS_EFUSE_INTR_SOURCE: interrupt of efuse, level, not likely to use
pub const INTB_EFUSE: u32 = 36;
/// ETS_TWAI_INTR_SOURCE: interrupt of can, level
pub const INTB_TWAI: u32 = 37;
/// ETS_USB_INTR_SOURCE: interrupt of USB, level
pub const INTB_USB: u32 = 38;
/// ETS_RTC_CORE_INTR_SOURCE: interrupt of rtc core, level, include rtc watchdog
pub const INTB_RTC_CORE: u32 = 39;
/// ETS_RMT_INTR_SOURCE: interrupt of remote controller, level
pub const INTB_RMT: u32 = 40;
/// ETS_PCNT_INTR_SOURCE: interrupt of pulse count, level
pub const INTB_PCNT: u32 = 41;
/// ETS_I2C_EXT0_INTR_SOURCE: interrupt of I2C controller1, level
pub const INTB_I2C_EXT0: u32 = 42;
/// ETS_I2C_EXT1_INTR_SOURCE: interrupt of I2C controller0, level
pub const INTB_I2C_EXT1: u32 = 43;
/// ETS_SPI2_DMA_INTR_SOURCE: interrupt of SPI2 DMA, level
pub const INTB_SPI2_DMA: u32 = 44;
/// ETS_SPI3_DMA_INTR_SOURCE: interrupt of SPI3 DMA, level
pub const INTB_SPI3_DMA: u32 = 45;
/// ETS_WDT_INTR_SOURCE: will be cancelled
pub const INTB_WDT: u32 = 47;
/// ETS_TIMER1_INTR_SOURCE
pub const INTB_TIMER1: u32 = 48;
/// ETS_TIMER2_INTR_SOURCE
pub const INTB_TIMER2: u32 = 49;
/// ETS_TG0_T0_LEVEL_INTR_SOURCE: interrupt of TIMER_GROUP0, TIMER0, EDGE
pub const INTB_TG0_T0_LEVEL: u32 = 50;
/// ETS_TG0_T1_LEVEL_INTR_SOURCE: interrupt of TIMER_GROUP0, TIMER1, EDGE
pub const INTB_TG0_T1_LEVEL: u32 = 51;
/// ETS_TG0_WDT_LEVEL_INTR_SOURCE: interrupt of TIMER_GROUP0, WATCH DOG, EDGE
pub const INTB_TG0_WDT_LEVEL: u32 = 52;
/// ETS_TG1_T0_LEVEL_INTR_SOURCE: interrupt of TIMER_GROUP1, TIMER0, EDGE
pub const INTB_TG1_T0_LEVEL: u32 = 53;
/// ETS_TG1_T1_LEVEL_INTR_SOURCE: interrupt of TIMER_GROUP1, TIMER1, EDGE
pub const INTB_TG1_T1_LEVEL: u32 = 54;
/// ETS_TG1_WDT_LEVEL_INTR_SOURCE: interrupt of TIMER_GROUP1, WATCHDOG, EDGE
pub const INTB_TG1_WDT_LEVEL: u32 = 55;
/// ETS_CACHE_IA_INTR_SOURCE: interrupt of Cache Invalid Access, LEVEL
pub const INTB_CACHE_IA: u32 = 56;
/// ETS_SYSTIMER_TARGET0_INTR_SOURCE: interrupt of system timer 0
pub const INTB_SYSTIMER_TARGET0: u32 = 57;
/// ETS_SYSTIMER_TARGET1_INTR_SOURCE: interrupt of system timer 1
pub const INTB_SYSTIMER_TARGET1: u32 = 58;
/// ETS_SYSTIMER_TARGET2_INTR_SOURCE: interrupt of system timer 2
pub const INTB_SYSTIMER_TARGET2: u32 = 59;
/// ETS_SPI_MEM_REJECT_CACHE_INTR_SOURCE: interrupt of SPI0 Cache access and SPI1 access rejected, LEVEL
pub const INTB_SPI_MEM_REJECT_CACHE: u32 = 60;
/// ETS_DCACHE_PRELOAD0_INTR_SOURCE: interrupt of DCache preload operation, LEVEL
pub const INTB_DCACHE_PRELOAD0: u32 = 61;
/// ETS_ICACHE_PRELOAD0_INTR_SOURCE: interrupt of ICache perload operation, LEVEL
pub const INTB_ICACHE_PRELOAD0: u32 = 62;
/// ETS_DCACHE_SYNC0_INTR_SOURCE: interrupt of data cache sync done, LEVEL
pub const INTB_DCACHE_SYNC0: u32 = 63;
/// ETS_ICACHE_SYNC0_INTR_SOURCE: interrupt of instruction cache sync done, LEVEL
pub const INTB_ICACHE_SYNC0: u32 = 64;
/// ETS_APB_ADC_INTR_SOURCE: interrupt of APB ADC, LEVEL
pub const INTB_APB_ADC: u32 = 65;
/// ETS_DMA_IN_CH0_INTR_SOURCE: interrupt of general DMA RX channel 0, LEVEL
pub const INTB_DMA_IN_CH0: u32 = 66;
/// ETS_DMA_IN_CH1_INTR_SOURCE: interrupt of general DMA RX channel 1, LEVEL
pub const INTB_DMA_IN_CH1: u32 = 67;
/// ETS_DMA_IN_CH2_INTR_SOURCE: interrupt of general DMA RX channel 2, LEVEL
pub const INTB_DMA_IN_CH2: u32 = 68;
/// ETS_DMA_IN_CH3_INTR_SOURCE: interrupt of general DMA RX channel 3, LEVEL
pub const INTB_DMA_IN_CH3: u32 = 69;
/// ETS_DMA_IN_CH4_INTR_SOURCE: interrupt of general DMA RX channel 4, LEVEL
pub const INTB_DMA_IN_CH4: u32 = 70;
/// ETS_DMA_OUT_CH0_INTR_SOURCE: interrupt of general DMA TX channel 0, LEVEL
pub const INTB_DMA_OUT_CH0: u32 = 71;
/// ETS_DMA_OUT_CH1_INTR_SOURCE: interrupt of general DMA TX channel 1, LEVEL
pub const INTB_DMA_OUT_CH1: u32 = 72;
/// ETS_DMA_OUT_CH2_INTR_SOURCE: interrupt of general DMA TX channel 2, LEVEL
pub const INTB_DMA_OUT_CH2: u32 = 73;
/// ETS_DMA_OUT_CH3_INTR_SOURCE: interrupt of general DMA TX channel 3, LEVEL
pub const INTB_DMA_OUT_CH3: u32 = 74;
/// ETS_DMA_OUT_CH4_INTR_SOURCE: interrupt of general DMA TX channel 4, LEVEL
pub const INTB_DMA_OUT_CH4: u32 = 75;
/// ETS_RSA_INTR_SOURCE: interrupt of RSA accelerator, level
pub const INTB_RSA: u32 = 76;
/// ETS_AES_INTR_SOURCE: interrupt of AES accelerator, level
pub const INTB_AES: u32 = 77;
/// ETS_SHA_INTR_SOURCE: interrupt of SHA accelerator, level
pub const INTB_SHA: u32 = 78;
/// ETS_FROM_CPU_INTR0_SOURCE: interrupt0 generated from a CPU, level*/ /* Used for FreeRTOS
pub const INTB_FROM_CPU_INTR0: u32 = 79;
/// ETS_FROM_CPU_INTR1_SOURCE: interrupt1 generated from a CPU, level*/ /* Used for FreeRTOS
pub const INTB_FROM_CPU_INTR1: u32 = 80;
/// ETS_FROM_CPU_INTR2_SOURCE: interrupt2 generated from a CPU, level*/ /* Used for IPC_ISR
pub const INTB_FROM_CPU_INTR2: u32 = 81;
/// ETS_FROM_CPU_INTR3_SOURCE: interrupt3 generated from a CPU, level*/ /* Used for IPC_ISR
pub const INTB_FROM_CPU_INTR3: u32 = 82;
/// ETS_ASSIST_DEBUG_INTR_SOURCE: interrupt of Assist debug module, LEVEL
pub const INTB_ASSIST_DEBUG: u32 = 83;
/// ETS_DMA_APBPERI_PMS_INTR_SOURCE
pub const INTB_DMA_APBPERI_PMS: u32 = 84;
/// ETS_CORE0_IRAM0_PMS_INTR_SOURCE
pub const INTB_CORE0_IRAM0_PMS: u32 = 85;
/// ETS_CORE0_DRAM0_PMS_INTR_SOURCE
pub const INTB_CORE0_DRAM0_PMS: u32 = 86;
/// ETS_CORE0_PIF_PMS_INTR_SOURCE
pub const INTB_CORE0_PIF_PMS: u32 = 87;
/// ETS_CORE0_PIF_PMS_SIZE_INTR_SOURCE
pub const INTB_CORE0_PIF_PMS_SIZE: u32 = 88;
/// ETS_CORE1_IRAM0_PMS_INTR_SOURCE
pub const INTB_CORE1_IRAM0_PMS: u32 = 89;
/// ETS_CORE1_DRAM0_PMS_INTR_SOURCE
pub const INTB_CORE1_DRAM0_PMS: u32 = 90;
/// ETS_CORE1_PIF_PMS_INTR_SOURCE
pub const INTB_CORE1_PIF_PMS: u32 = 91;
/// ETS_CORE1_PIF_PMS_SIZE_INTR_SOURCE
pub const INTB_CORE1_PIF_PMS_SIZE: u32 = 92;
/// ETS_BACKUP_PMS_VIOLATE_INTR_SOURCE
pub const INTB_BACKUP_PMS_VIOLATE: u32 = 93;
/// ETS_CACHE_CORE0_ACS_INTR_SOURCE
pub const INTB_CACHE_CORE0_ACS: u32 = 94;
/// ETS_CACHE_CORE1_ACS_INTR_SOURCE
pub const INTB_CACHE_CORE1_ACS: u32 = 95;
/// ETS_USB_SERIAL_JTAG_INTR_SOURCE
pub const INTB_USB_SERIAL_JTAG: u32 = 96;
/// ETS_PERI_BACKUP_INTR_SOURCE
pub const INTB_PERI_BACKUP: u32 = 97;
/// ETS_DMA_EXTMEM_REJECT_SOURCE
pub const INTB_DMA_EXTMEM_REJECT: u32 = 98;

/// The number of sources: interrupt numbers are 0 to INTB_COUNT - 1.
pub const INTB_COUNT: u32 = 99;

comptime {
    // Spot checks against ESP-IDF's numbers.
    if (INTB_UART0 != 27 or INTB_TG0_T0_LEVEL != 50 or INTB_SYSTIMER_TARGET0 != 57 or
        INTB_DMA_IN_CH0 != 66 or INTB_DMA_OUT_CH0 != 71 or INTB_FROM_CPU_INTR0 != 79 or
        INTB_USB_SERIAL_JTAG != 96) @compileError("intbits doesn't match ESP-IDF's interrupts.h");
}
