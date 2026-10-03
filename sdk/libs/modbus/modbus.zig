// SPDX-License-Identifier: MIT
//! modbus.library's structures and constants: the context a client
//! speaks through, the server a program runs, the tags both are made
//! with, and the error codes. The calls are in `sdk.interface.modbus`.
//!
//! Modbus is a question and an answer: a client asks a device - a unit,
//! by its number - for a run of its data, or to change it, and the
//! device answers. A device's data is four tables, each numbered from 0:
//!
//!   coils               bits the client may read and write
//!   discrete inputs     bits it may only read
//!   holding registers   16-bit words it may read and write
//!   input registers     16-bit words it may only read
//!
//! The library carries this two ways: RTU, binary frames with a CRC on
//! an RS-485 bus (through rs485.device), and TCP, the same questions
//! with a short header over a stream socket (port 502). It is a client -
//! OpenModbusRTU or OpenModbusTCP, then a call per question - and a
//! server, which answers from tables the program hands it.
//!
//! A bit travels as a byte here, 0 or 1, one per coil or input; a
//! register as a u16 in the machine's own order. The library puts them
//! into the protocol's packing and byte order and back.

const utility = @import("../utility/utility.zig");

/// The library's name, for OpenLibrary.
pub const MODBUSNAME = "modbus.library";

/// What OpenModbusRTU and OpenModbusTCP make: one bus or one connection,
/// and how questions are put on it. Only modbus.library knows what is in
/// it.
pub const ModbusContext = opaque {};

/// What StartModbusServer makes. Only modbus.library knows what is in it.
pub const ModbusServer = opaque {};

/// The most a single question may ask for.
pub const MB_MAX_READ_BITS: u32 = 2000;
pub const MB_MAX_READ_REGISTERS: u32 = 125;
pub const MB_MAX_WRITE_BITS: u32 = 1968;
pub const MB_MAX_WRITE_REGISTERS: u32 = 123;
/// ReadWriteRegisters' write, which shares the frame with the read.
pub const MB_MAX_READWRITE_REGISTERS: u32 = 121;
/// A protocol data unit: the function code and what follows it.
pub const MB_MAX_PDU: u32 = 253;

/// The unit number that is every device on an RTU bus at once: nothing
/// answers it, so only writes are sent to it.
pub const MB_BROADCAST: u32 = 0;

/// The function codes the library asks and answers.
pub const MBFC_READ_COILS: u8 = 0x01;
pub const MBFC_READ_DISCRETE_INPUTS: u8 = 0x02;
pub const MBFC_READ_HOLDING_REGISTERS: u8 = 0x03;
pub const MBFC_READ_INPUT_REGISTERS: u8 = 0x04;
pub const MBFC_WRITE_SINGLE_COIL: u8 = 0x05;
pub const MBFC_WRITE_SINGLE_REGISTER: u8 = 0x06;
pub const MBFC_WRITE_MULTIPLE_COILS: u8 = 0x0F;
pub const MBFC_WRITE_MULTIPLE_REGISTERS: u8 = 0x10;
pub const MBFC_READ_WRITE_REGISTERS: u8 = 0x17;

/// A question of any kind, for ModbusTransaction: the PDU - the function
/// code, then its data - in `data`.
pub const ModbusPdu = extern struct {
    /// The bytes.
    data: [*]u8,
    /// How many of them are the PDU: set by the caller for the question,
    /// by the library for the answer.
    length: u32 = 0,
    /// How many `data` has room for; at least MB_MAX_PDU for an answer.
    size: u32 = 0,
};

/// ReadWriteRegisters' question: the registers written first, then the
/// ones read, in one exchange.
pub const ModbusReadWrite = extern struct {
    read_address: u32 = 0,
    read_count: u32 = 0,
    read: [*]u16,
    write_address: u32 = 0,
    write_count: u32 = 0,
    write: [*]const u16,
};

/// What a server's hook is handed after a client changed its tables:
/// the function, and where and how much it wrote.
pub const ModbusWrite = extern struct {
    function: u32 = 0,
    address: u32 = 0,
    count: u32 = 0,
    /// The unit the question was for.
    unit: u32 = 0,
};

// --- tags ---------------------------------------------------------------------

pub const MBA_Dummy = utility.TAG_USER + 0x60500;
/// `[*:0]const u8`: the RTU bus's device (rs485.device).
pub const MBA_Device = MBA_Dummy + 0x01;
/// u32: the device's unit (0).
pub const MBA_DeviceUnit = MBA_Dummy + 0x02;
/// u32: the bus's rate in bits per second (19200).
pub const MBA_Baud = MBA_Dummy + 0x03;
/// u32: MB_PARITY_* (MB_PARITY_EVEN, the protocol's own).
pub const MBA_Parity = MBA_Dummy + 0x04;
/// u32: 1 or 2 stop bits (1; the protocol asks for 2 without parity).
pub const MBA_StopBits = MBA_Dummy + 0x05;
/// u32: how long a client waits for an answer, in milliseconds (1000).
pub const MBA_Timeout = MBA_Dummy + 0x06;
/// `[*:0]const u8`: TCP: the server's name or address.
pub const MBA_Host = MBA_Dummy + 0x07;
/// u32: TCP: the port (502). A server listens on it.
pub const MBA_Port = MBA_Dummy + 0x08;
/// i32: TCP client: a stream socket the program has connected, used
/// instead of MBA_Host; it stays the program's, to close.
pub const MBA_Socket = MBA_Dummy + 0x09;

/// u32: StartModbusServer: MBT_RTU or MBT_TCP (MBT_RTU).
pub const MBS_Transport = MBA_Dummy + 0x40;
/// u32: the unit the server answers as, 1 to 247. Required on RTU; on
/// TCP 0 (the default) answers every unit.
pub const MBS_Unit = MBA_Dummy + 0x41;
/// `[*]u8` and u32: the coils, a byte each, and how many.
pub const MBS_Coils = MBA_Dummy + 0x42;
pub const MBS_CoilCount = MBA_Dummy + 0x43;
/// `[*]const u8` and u32: the discrete inputs, a byte each, and how many.
pub const MBS_DiscreteInputs = MBA_Dummy + 0x44;
pub const MBS_DiscreteCount = MBA_Dummy + 0x45;
/// `[*]u16` and u32: the holding registers, and how many.
pub const MBS_HoldingRegisters = MBA_Dummy + 0x46;
pub const MBS_HoldingCount = MBA_Dummy + 0x47;
/// `[*]const u16` and u32: the input registers, and how many.
pub const MBS_InputRegisters = MBA_Dummy + 0x48;
pub const MBS_InputCount = MBA_Dummy + 0x49;
/// `*exec.SignalSemaphore`: held by the server while it reads or writes
/// the tables, so the program changes them under it too.
pub const MBS_Lock = MBA_Dummy + 0x4A;
/// `*utility.Hook`: called on the server's process after a client
/// changed the tables, the lock let go: object the ModbusServer,
/// message a ModbusWrite.
pub const MBS_Hook = MBA_Dummy + 0x4B;
/// u32: TCP: how many clients may be connected at once (4).
pub const MBS_MaxClients = MBA_Dummy + 0x4C;

/// MBA_Parity.
pub const MB_PARITY_NONE: u32 = 0;
pub const MB_PARITY_EVEN: u32 = 1;
pub const MB_PARITY_ODD: u32 = 2;

/// MBS_Transport.
pub const MBT_RTU: u32 = 0;
pub const MBT_TCP: u32 = 1;

// --- errors -------------------------------------------------------------------

/// What a call answers: 0, an exception the device answered with (above
/// 0), or something that kept the question from being answered (below 0).
pub const MBERR_OK: i32 = 0;

/// The device's exceptions.
pub const MBEX_ILLEGAL_FUNCTION: i32 = 1;
pub const MBEX_ILLEGAL_ADDRESS: i32 = 2;
pub const MBEX_ILLEGAL_VALUE: i32 = 3;
pub const MBEX_DEVICE_FAILURE: i32 = 4;
pub const MBEX_ACKNOWLEDGE: i32 = 5;
pub const MBEX_DEVICE_BUSY: i32 = 6;
pub const MBEX_GATEWAY_PATH: i32 = 10;
pub const MBEX_GATEWAY_TARGET: i32 = 11;

/// No answer came within MBA_Timeout.
pub const MBERR_TIMEOUT: i32 = -1;
/// An RTU answer whose CRC was wrong, or that was damaged on the line.
pub const MBERR_CRC: i32 = -2;
/// An answer that does not fit the question.
pub const MBERR_REPLY: i32 = -3;
/// The device or the socket failed.
pub const MBERR_IO: i32 = -4;
/// A count or an address out of range, or a missing table or tag.
pub const MBERR_ARGS: i32 = -5;
pub const MBERR_NOMEM: i32 = -6;
/// TCP: no connection could be made.
pub const MBERR_CONNECT: i32 = -7;
/// TCP: the host's name was not found.
pub const MBERR_HOST: i32 = -8;
/// RTU: the bus's device could not be opened, or refused the line.
pub const MBERR_DEVICE: i32 = -9;
/// TCP: the other side closed the connection.
pub const MBERR_CLOSED: i32 = -10;
