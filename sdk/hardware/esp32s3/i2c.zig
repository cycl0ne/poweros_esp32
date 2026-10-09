// SPDX-License-Identifier: MIT
//! The two I2C controllers' registers: the same block at each one's base
//! (`base`), so the registers are offsets into it.
//!
//! A controller runs a list of up to eight command words (COMD0-7): each
//! says START, repeated START, write so many bytes, read so many, STOP or
//! END, and the bytes go through a 32-byte FIFO each way.
//!
//! Only names and numbers: nothing here touches the hardware.

const map = @import("map.zig");

/// A controller's registers, by its number (0-1).
pub fn baseOf(n: u1) usize {
    return if (n == 0) map.I2C0 else map.I2C1;
}

// The registers, as offsets from a controller's base.
pub const SCL_LOW_PERIOD = 0x00;
pub const CTR = 0x04;
pub const SR = 0x08;
pub const TO = 0x0C;
pub const FIFO_CONF = 0x18;
pub const DATA = 0x1C;
pub const INT_RAW = 0x20;
pub const INT_CLR = 0x24;
pub const INT_ENA = 0x28;
pub const SDA_HOLD = 0x30;
pub const SDA_SAMPLE = 0x34;
pub const SCL_HIGH_PERIOD = 0x38;
pub const SCL_START_HOLD = 0x40;
pub const SCL_RSTART_SETUP = 0x44;
pub const SCL_STOP_HOLD = 0x48;
pub const SCL_STOP_SETUP = 0x4C;
pub const FILTER_CFG = 0x50;
pub const CLK_CONF = 0x54;
/// The first command word; the others follow a word apart.
pub const COMD0 = 0x58;
pub const SCL_SP_CONF = 0x80;

/// How many bytes either FIFO holds.
pub const FIFO_LEN: u32 = 32;
/// How many command words there are.
pub const CMD_COUNT: u32 = 8;

// CTR
pub const CTR_SDA_FORCE_OUT: u32 = 1 << 0;
pub const CTR_SCL_FORCE_OUT: u32 = 1 << 1;
pub const CTR_MS_MODE: u32 = 1 << 4;
pub const CTR_TRANS_START: u32 = 1 << 5;
pub const CTR_CLK_EN: u32 = 1 << 8;
pub const CTR_FSM_RST: u32 = 1 << 10;
/// The controller latches its configuration on this edge.
pub const CTR_CONF_UPGATE: u32 = 1 << 11;

// SR
pub const SR_BUS_BUSY: u32 = 1 << 4;
pub const SR_RXFIFO_CNT_SHIFT: u5 = 8;
pub const SR_FIFO_CNT_MASK: u32 = 0x3F;

// FIFO_CONF
pub const FIFO_RX_RST: u32 = 1 << 12;
pub const FIFO_TX_RST: u32 = 1 << 13;
pub const FIFO_PRT_EN: u32 = 1 << 14;

// CLK_CONF: the divider (bits 0-7) and the source clock gated on.
pub const CLK_SCLK_DIV_NUM: u32 = 0xFF;
pub const CLK_SCLK_ACTIVE: u32 = 1 << 21;

// TO
pub const TO_TIME_OUT_EN: u32 = 1 << 5;

// SCL_SP_CONF: pulse SCL (bits 0-4: how often) until a slave that holds
// SDA down lets go.
pub const SP_SCL_RST_SLV_NUM: u32 = 0x1F;
pub const SP_SCL_RST_SLV_EN: u32 = 1 << 5;

// The interrupt bits, in INT_RAW, INT_CLR, INT_ENA and INT_STATUS.
pub const INT_END_DETECT: u32 = 1 << 3;
pub const INT_ARBITRATION_LOST: u32 = 1 << 5;
pub const INT_TRANS_COMPLETE: u32 = 1 << 7;
pub const INT_TIME_OUT: u32 = 1 << 8;
pub const INT_NACK: u32 = 1 << 10;

// A command word: byte_num [7:0], ack_en [8], ack_exp [9], ack_val [10],
// op_code [13:11].
pub const COMD_BYTE_NUM: u32 = 0xFF;
pub const COMD_ACK_EN: u32 = 1 << 8;
pub const COMD_ACK_VAL: u32 = 1 << 10;
pub const COMD_OP_SHIFT = 11;
pub const OP_WRITE: u3 = 1;
pub const OP_STOP: u3 = 2;
pub const OP_READ: u3 = 3;
pub const OP_END: u3 = 4;
pub const OP_RSTART: u3 = 6;
