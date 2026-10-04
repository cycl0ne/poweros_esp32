# modbus.library

modbus.library's functions: Modbus over RTU (an RS-485 bus, through
rs485.device) and TCP, as a client asking devices and as a server
answering from a program's tables. Open it with
OpenLibrary("modbus.library", 1); the structures are in sdk.modbus.

Generated from the source by `./zig build autodoc`.

## Index

- [CloseModbus](#closemodbus) - Closes a client's context.
- [ModbusErrorText](#modbuserrortext) - Says what a code the library answered means.
- [ModbusTransaction](#modbustransaction) - Asks a unit a question of any kind.
- [OpenModbusRTU](#openmodbusrtu) - Opens a client on an RTU bus.
- [OpenModbusTCP](#openmodbustcp) - Opens a client on a TCP connection.
- [ReadCoils](#readcoils) - Reads a run of a device's coils.
- [ReadDiscreteInputs](#readdiscreteinputs) - Reads a run of a device's discrete inputs.
- [ReadHoldingRegisters](#readholdingregisters) - Reads a run of a device's holding registers.
- [ReadInputRegisters](#readinputregisters) - Reads a run of a device's input registers.
- [ReadWriteRegisters](#readwriteregisters) - Writes holding registers and reads others in one exchange.
- [StartModbusServer](#startmodbusserver) - Starts a server.
- [StopModbusServer](#stopmodbusserver) - Stops a server.
- [WriteCoil](#writecoil) - Sets or clears one coil.
- [WriteCoils](#writecoils) - Sets a run of coils.
- [WriteRegister](#writeregister) - Sets one holding register.
- [WriteRegisters](#writeregisters) - Sets a run of holding registers.

## CloseModbus

Closes a client's context.

**SYNOPSIS**

```zig
fn CloseModbus(base: *ModbusBase, context: ?*modbus.ModbusContext) void
```

**SINCE**

1.0. LVO -28.

**INPUTS**

- `context`: what OpenModbusRTU or OpenModbusTCP made, or null.

**RESULT**

None.

**BEHAVIOR**

An RTU context's device is closed; a TCP context's connection is
closed if the library made it. The context is freed.

**CONTEXT**

- Waits: yes, on the device.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: the task that opened the context.

**OWNERSHIP**

The context is gone after the call. A socket the program gave with
MBA_Socket is still the program's.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`OpenModbusRTU`, `OpenModbusTCP`

**EXAMPLES**

```zig
mb.CloseModbus(bus);
```

## ModbusErrorText

Says what a code the library answered means.

**SYNOPSIS**

```zig
fn ModbusErrorText(base: *ModbusBase, code: i32) [*:0]const u8
```

**SINCE**

1.0. LVO -80.

**INPUTS**

- `code`: an MBERR_* or an MBEX_* a call answered.

**RESULT**

A short sentence without a full stop, "unknown error" for a code the
library does not have.

**BEHAVIOR**

The text is the library's, the same for every caller.

**CONTEXT**

- Waits: no.
- Interrupts: yes.
- Locks: none needed.
- Process: any.

**OWNERSHIP**

The text is the library's and stays while it is open; it is not
freed.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`ReadHoldingRegisters`

**EXAMPLES**

```zig
const result = mb.ReadHoldingRegisters(bus, 1, 0, 2, &registers);
if (result != modbus.MBERR_OK) _ = dos.stdio.Printf(dl, "Modbus: %s\n", .{mb.ModbusErrorText(result)});
```

## ModbusTransaction

Asks a unit a question of any kind.

**SYNOPSIS**

```zig
fn ModbusTransaction(base: *ModbusBase, context: *modbus.ModbusContext, unit: u32, question: *const modbus.ModbusPdu, answer: *modbus.ModbusPdu) i32
```

**SINCE**

1.0. LVO -68.

**INPUTS**

- `context`: the bus or connection.
- `unit`: the device asked: 1 to 247 on RTU (0 broadcasts), 0 to 255
  on TCP.
- `question`: the PDU, the function code first; `length` bytes of
  `data`, at most MB_MAX_PDU.
- `answer`: where the answer's PDU goes: `data` with room for `size`
  bytes. `length` is set.

**RESULT**

MBERR_OK with the answer in `answer`, the function code first - an
exception too, its code's top bit set, is an answer here. Below 0
when no answer came (MBERR_TIMEOUT, MBERR_CRC, MBERR_IO,
MBERR_CLOSED), or for a PDU that is empty or too long, or an answer
that does not fit `size` (MBERR_ARGS, MBERR_REPLY).

**BEHAVIOR**

The PDU is sent as it is, wrapped for the transport, and the answer
is unwrapped and handed back without being looked into: for the
functions the library has no call for.

**CONTEXT**

- Waits: yes, for the answer.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: the task that opened the context.

**OWNERSHIP**

Both PDUs are the caller's.

**NOTES**

A broadcast on RTU has no answer: `length` is 0.

**BUGS**

None known.

**SEE ALSO**

`ReadHoldingRegisters`, `ReadWriteRegisters`

**EXAMPLES**

```zig
// Report Server ID (function 17).
var question_bytes = [_]u8{0x11};
var answer_bytes: [modbus.MB_MAX_PDU]u8 = undefined;
const question = modbus.ModbusPdu{ .data = &question_bytes, .length = 1, .size = 1 };
var answer = modbus.ModbusPdu{ .data = &answer_bytes, .size = answer_bytes.len };
if (mb.ModbusTransaction(bus, 1, &question, &answer) == modbus.MBERR_OK) {
    // answer_bytes[0..answer.length]
}
```

## OpenModbusRTU

Opens a client on an RTU bus.

**SYNOPSIS**

```zig
fn OpenModbusRTU(base: *ModbusBase, tags: ?[*]const utility.TagItem, err: ?*i32) ?*modbus.ModbusContext
```

**SINCE**

1.0. LVO -20.

**INPUTS**

- `tags`: the bus, all optional:
  - MBA_Device (`[*:0]const u8`): the device, `rs485.device`.
  - MBA_DeviceUnit (u32): its unit, 0.
  - MBA_Baud (u32): bits per second, 19200.
  - MBA_Parity (u32): MB_PARITY_EVEN, MB_PARITY_ODD or
    MB_PARITY_NONE; even, as the protocol has it.
  - MBA_StopBits (u32): 1 or 2; 1.
  - MBA_Timeout (u32): how long a question waits for its answer, in
    milliseconds; 1000.
- `err`: where the reason goes when the answer is null, or null.

**RESULT**

The context, with the device open and its line set; `err` is then
MBERR_OK. Null for no memory (MBERR_NOMEM), for a device that cannot
be opened or refuses the line (MBERR_DEVICE), or for a time-out of 0
(MBERR_ARGS).

**BEHAVIOR**

The device is opened exclusively and set to the line asked for: eight
data bits, the parity and stop bits given, and a frame ending at a
quiet line of three and a half characters - or of 1750 µs above
19200 bit/s, as the protocol fixes it there.

**CONTEXT**

- Waits: yes, on the device.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do. The context's reply port is the caller's,
  so every call with it must come from the same task.

**OWNERSHIP**

The context and the open device are the caller's until CloseModbus.

**NOTES**

The device is a bus for one client: a second context on it fails
until the first is closed.

**BUGS**

None known.

**SEE ALSO**

`OpenModbusTCP`, `CloseModbus`, `ReadHoldingRegisters`

**EXAMPLES**

```zig
var err: i32 = 0;
const bus = mb.OpenModbusRTU(&[_]utility.TagItem{
    .{ .tag = modbus.MBA_Baud, .data = 9600 },
    .{},
}, &err) orelse return err;
defer mb.CloseModbus(bus);
```

## OpenModbusTCP

Opens a client on a TCP connection.

**SYNOPSIS**

```zig
fn OpenModbusTCP(base: *ModbusBase, socket_base: *SocketBase, tags: ?[*]const utility.TagItem, err: ?*i32) ?*modbus.ModbusContext
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `socket_base`: the program's bsdsocket.library base; the
  connection's calls are made through it.
- `tags`:
  - MBA_Host (`[*:0]const u8`): the server's name or address, IPv4
    or IPv6. Either it or MBA_Socket is required.
  - MBA_Port (u32): its port, 502.
  - MBA_Socket (i32): a stream socket the program has connected
    already, used instead of MBA_Host.
  - MBA_Timeout (u32): how long a question waits for its answer, in
    milliseconds; 1000.
- `err`: where the reason goes when the answer is null, or null.

**RESULT**

The context, connected; `err` is then MBERR_OK. Null for no memory
(MBERR_NOMEM), a name that was not found (MBERR_HOST), no connection
on any of its addresses (MBERR_CONNECT), or neither MBA_Host nor
MBA_Socket, or a time-out of 0 (MBERR_ARGS).

**BEHAVIOR**

The host's addresses are tried in the order GetAddrInfo gives them,
until one connects. The connection carries one question at a time,
each with its own transaction number.

**CONTEXT**

- Waits: yes, for the name and the connection.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Process, the one `socket_base` belongs to; every call
  with the context must come from it.

**OWNERSHIP**

The context is the caller's until CloseModbus. A socket the library
made is closed with it; one the program gave stays the program's.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`OpenModbusRTU`, `CloseModbus`, `ModbusTransaction`

**EXAMPLES**

```zig
var err: i32 = 0;
const plc = mb.OpenModbusTCP(sb, &[_]utility.TagItem{
    .{ .tag = modbus.MBA_Host, .data = @intFromPtr("192.168.1.20") },
    .{},
}, &err) orelse return err;
defer mb.CloseModbus(plc);
```

## ReadCoils

Reads a run of a device's coils.

**SYNOPSIS**

```zig
fn ReadCoils(base: *ModbusBase, context: *modbus.ModbusContext, unit: u32, address: u32, count: u32, values: [*]u8) i32
```

**SINCE**

1.0. LVO -32.

**INPUTS**

- `context`: the bus or connection.
- `unit`: the device: 1 to 247 on RTU, 0 to 255 on TCP.
- `address`: the first coil, from 0.
- `count`: how many, 1 to 2000.
- `values`: room for `count` bytes, each set to 0 or 1.

**RESULT**

MBERR_OK with `values` filled; the device's exception (MBEX_*, above 0); or,
below 0, what kept the question from being answered: MBERR_TIMEOUT,
MBERR_CRC, MBERR_REPLY, MBERR_IO, MBERR_CLOSED - or MBERR_ARGS for a
count of 0 or past 2000, a run past address 65535, or unit 0 on
RTU, where nobody answers.

**BEHAVIOR**

One question, function 0x01, and its answer unpacked - eight bits to a byte on the wire, a byte each here. `values` is
left as it was unless the answer is MBERR_OK.

**CONTEXT**

- Waits: yes, for the answer.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: the task that opened the context.

**OWNERSHIP**

`values` is the caller's.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`WriteCoil`, `WriteCoils`, `ReadDiscreteInputs`

**EXAMPLES**

```zig
var lamps: [8]u8 = undefined;
if (mb.ReadCoils(bus, 1, 0, 8, &lamps) == modbus.MBERR_OK and lamps[3] != 0) {
    // the fourth is on
}
```

## ReadDiscreteInputs

Reads a run of a device's discrete inputs.

**SYNOPSIS**

```zig
fn ReadDiscreteInputs(base: *ModbusBase, context: *modbus.ModbusContext, unit: u32, address: u32, count: u32, values: [*]u8) i32
```

**SINCE**

1.0. LVO -36.

**INPUTS**

- `context`: the bus or connection.
- `unit`: the device: 1 to 247 on RTU, 0 to 255 on TCP.
- `address`: the first input, from 0.
- `count`: how many, 1 to 2000.
- `values`: room for `count` bytes, each set to 0 or 1.

**RESULT**

MBERR_OK with `values` filled; the device's exception (MBEX_*, above 0); or,
below 0, what kept the question from being answered: MBERR_TIMEOUT,
MBERR_CRC, MBERR_REPLY, MBERR_IO, MBERR_CLOSED - or MBERR_ARGS for a
count of 0 or past 2000, a run past address 65535, or unit 0 on
RTU, where nobody answers.

**BEHAVIOR**

One question, function 0x02, and its answer unpacked - eight bits to a byte on the wire, a byte each here. `values` is
left as it was unless the answer is MBERR_OK.

**CONTEXT**

- Waits: yes, for the answer.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: the task that opened the context.

**OWNERSHIP**

`values` is the caller's.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`ReadCoils`

**EXAMPLES**

```zig
var switches: [4]u8 = undefined;
const result = mb.ReadDiscreteInputs(bus, 1, 0, 4, &switches);
```

## ReadHoldingRegisters

Reads a run of a device's holding registers.

**SYNOPSIS**

```zig
fn ReadHoldingRegisters(base: *ModbusBase, context: *modbus.ModbusContext, unit: u32, address: u32, count: u32, values: [*]u16) i32
```

**SINCE**

1.0. LVO -40.

**INPUTS**

- `context`: the bus or connection.
- `unit`: the device: 1 to 247 on RTU, 0 to 255 on TCP.
- `address`: the first register, from 0.
- `count`: how many, 1 to 125.
- `values`: room for `count` registers.

**RESULT**

MBERR_OK with `values` filled; the device's exception (MBEX_*, above 0); or,
below 0, what kept the question from being answered: MBERR_TIMEOUT,
MBERR_CRC, MBERR_REPLY, MBERR_IO, MBERR_CLOSED - or MBERR_ARGS for a
count of 0 or past 125, a run past address 65535, or unit 0 on
RTU, where nobody answers.

**BEHAVIOR**

One question, function 0x03, and its answer unpacked - big-endian on the wire, the machine's own order here. `values` is
left as it was unless the answer is MBERR_OK.

**CONTEXT**

- Waits: yes, for the answer.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: the task that opened the context.

**OWNERSHIP**

`values` is the caller's.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`WriteRegister`, `WriteRegisters`, `ReadWriteRegisters`, `ReadInputRegisters`

**EXAMPLES**

```zig
var registers: [2]u16 = undefined;
const result = mb.ReadHoldingRegisters(bus, 1, 100, 2, &registers);
if (result > 0) {
    // the device answered with an exception
}
```

## ReadInputRegisters

Reads a run of a device's input registers.

**SYNOPSIS**

```zig
fn ReadInputRegisters(base: *ModbusBase, context: *modbus.ModbusContext, unit: u32, address: u32, count: u32, values: [*]u16) i32
```

**SINCE**

1.0. LVO -44.

**INPUTS**

- `context`: the bus or connection.
- `unit`: the device: 1 to 247 on RTU, 0 to 255 on TCP.
- `address`: the first register, from 0.
- `count`: how many, 1 to 125.
- `values`: room for `count` registers.

**RESULT**

MBERR_OK with `values` filled; the device's exception (MBEX_*, above 0); or,
below 0, what kept the question from being answered: MBERR_TIMEOUT,
MBERR_CRC, MBERR_REPLY, MBERR_IO, MBERR_CLOSED - or MBERR_ARGS for a
count of 0 or past 125, a run past address 65535, or unit 0 on
RTU, where nobody answers.

**BEHAVIOR**

One question, function 0x04, and its answer unpacked - big-endian on the wire, the machine's own order here. `values` is
left as it was unless the answer is MBERR_OK.

**CONTEXT**

- Waits: yes, for the answer.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: the task that opened the context.

**OWNERSHIP**

`values` is the caller's.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`ReadHoldingRegisters`

**EXAMPLES**

```zig
var temperature: [1]u16 = undefined;
const result = mb.ReadInputRegisters(bus, 1, 0, 1, &temperature);
```

## ReadWriteRegisters

Writes holding registers and reads others in one exchange.

**SYNOPSIS**

```zig
fn ReadWriteRegisters(base: *ModbusBase, context: *modbus.ModbusContext, unit: u32, transfer: *const modbus.ModbusReadWrite) i32
```

**SINCE**

1.0. LVO -64.

**INPUTS**

- `context`: the bus or connection.
- `unit`: the device: 1 to 247 on RTU, 0 to 255 on TCP.
- `transfer`: `write_count` registers (1 to 121) from `write` to
  `write_address`, and `read_count` (1 to 125) from `read_address`
  into `read`.

**RESULT**

MBERR_OK with `read` filled; the device's exception (MBEX_*, above
0); or, below 0, what kept the question from being answered:
MBERR_TIMEOUT, MBERR_CRC, MBERR_REPLY, MBERR_IO, MBERR_CLOSED - or
MBERR_ARGS for a count out of range, a run past address 65535, or
unit 0 on RTU.

**BEHAVIOR**

One question, function 0x17. The device writes first and reads
after, so a run that overlaps reads what was just written.

**CONTEXT**

- Waits: yes, for the answer.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: the task that opened the context.

**OWNERSHIP**

`transfer` and its buffers are the caller's.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`ReadHoldingRegisters`, `WriteRegisters`

**EXAMPLES**

```zig
const command = [_]u16{1};
var status: [4]u16 = undefined;
const transfer = modbus.ModbusReadWrite{
    .write_address = 0, .write_count = 1, .write = &command,
    .read_address = 10, .read_count = 4, .read = &status,
};
const result = mb.ReadWriteRegisters(bus, 1, &transfer);
```

## StartModbusServer

Starts a server.

**SYNOPSIS**

```zig
fn StartModbusServer(base: *ModbusBase, tags: ?[*]const utility.TagItem, err: ?*i32) ?*modbus.ModbusServer
```

**SINCE**

1.0. LVO -72.

**INPUTS**

- `tags`:
  - MBS_Transport (u32): MBT_RTU (the default) or MBT_TCP.
  - MBS_Unit (u32): the unit it answers as, 1 to 247; required on
    RTU. On TCP 0, the default, answers every unit.
  - MBS_Coils, MBS_CoilCount; MBS_DiscreteInputs,
    MBS_DiscreteCount: the bit tables, a byte each, from address 0.
  - MBS_HoldingRegisters, MBS_HoldingCount; MBS_InputRegisters,
    MBS_InputCount: the register tables, from address 0.
  - MBS_Lock (`*exec.SignalSemaphore`): held while the server reads
    or writes the tables.
  - MBS_Hook (`*utility.Hook`): called after a client changed them.
  - RTU: MBA_Device, MBA_DeviceUnit, MBA_Baud, MBA_Parity,
    MBA_StopBits, as OpenModbusRTU takes them.
  - TCP: MBA_Port (u32), 502; MBS_MaxClients (u32), 4, at most 8.
- `err`: where the reason goes when the answer is null, or null.

**RESULT**

The server, running; `err` is then MBERR_OK. Null for no memory
(MBERR_NOMEM); no table at all, a unit out of range, or a line or
limit that cannot be (MBERR_ARGS); a bus device that cannot be opened
or set (MBERR_DEVICE); a port that cannot be listened on
(MBERR_CONNECT); or no network (MBERR_IO).

**BEHAVIOR**

A process is started that opens the bus or listens on the port, and
answers every question for its unit from the tables: reads from
them, writes into them - functions 1 to 6, 15, 16 and 23; any other
is answered with MBEX_ILLEGAL_FUNCTION, an address past a table's end
with MBEX_ILLEGAL_ADDRESS. On RTU a broadcast is carried out without
an answer. The call returns once the process is listening, or has
failed to.

After a question that wrote, the hook is called on the server's
process with the ModbusServer as its object and a ModbusWrite - the
function, the first address, the count, the unit - as its message,
the lock let go.

**CONTEXT**

- Waits: yes, for the process to start.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The tables, the lock and the hook stay the program's, and must be
there until StopModbusServer has returned. The server is the
program's to stop.

**NOTES**

The server writes a table with no word to the program: a value the
program reads without the lock may be half of one write and half of
the next.

**BUGS**

None known.

**SEE ALSO**

`StopModbusServer`

**EXAMPLES**

```zig
var registers: [16]u16 = @splat(0);
var err: i32 = 0;
const server = mb.StartModbusServer(&[_]utility.TagItem{
    .{ .tag = modbus.MBS_Transport, .data = modbus.MBT_TCP },
    .{ .tag = modbus.MBS_HoldingRegisters, .data = @intFromPtr(&registers) },
    .{ .tag = modbus.MBS_HoldingCount, .data = registers.len },
    .{},
}, &err) orelse return err;
defer mb.StopModbusServer(server);
```

## StopModbusServer

Stops a server.

**SYNOPSIS**

```zig
fn StopModbusServer(base: *ModbusBase, server: ?*modbus.ModbusServer) void
```

**SINCE**

1.0. LVO -76.

**INPUTS**

- `server`: what StartModbusServer made, or null.

**RESULT**

None.

**BEHAVIOR**

The server's process is told to stop (CTRL_C) and waited for: it
closes its device, or its connections and the port, and ends. A
question it is answering is answered first. The server is freed.

**CONTEXT**

- Waits: yes, for the process.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do; not the hook's, which runs on the server's
  own process.

**OWNERSHIP**

The tables, the lock and the hook are the program's again: nothing
touches them after the call.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`StartModbusServer`

**EXAMPLES**

```zig
mb.StopModbusServer(server);
```

## WriteCoil

Sets or clears one coil.

**SYNOPSIS**

```zig
fn WriteCoil(base: *ModbusBase, context: *modbus.ModbusContext, unit: u32, address: u32, value: u32) i32
```

**SINCE**

1.0. LVO -48.

**INPUTS**

- `context`: the bus or connection.
- `unit`: the device: 1 to 247 on RTU, 0 broadcasts to all; 0 to 255
  on TCP.
- `address`: the coil, from 0.
- `value`: not 0 to set it, 0 to clear it.

**RESULT**

MBERR_OK once the device has repeated the question, as it does to
say it is done; the device's exception (MBEX_*, above 0); or, below
0, what kept it from being answered: MBERR_TIMEOUT, MBERR_CRC,
MBERR_REPLY, MBERR_IO, MBERR_CLOSED - or MBERR_ARGS for an address past 65535. To unit 0
on RTU the write is broadcast to every device, none answers, and
MBERR_OK means it was sent.

**BEHAVIOR**

One question, function 0x05: the coil as 0xFF00 for on, 0 for off.

**CONTEXT**

- Waits: yes, for the answer.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: the task that opened the context.

**OWNERSHIP**

Nothing is kept.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`WriteCoils`, `ReadCoils`

**EXAMPLES**

```zig
_ = mb.WriteCoil(bus, 1, 3, 1); // the fourth lamp on
```

## WriteCoils

Sets a run of coils.

**SYNOPSIS**

```zig
fn WriteCoils(base: *ModbusBase, context: *modbus.ModbusContext, unit: u32, address: u32, count: u32, values: [*]const u8) i32
```

**SINCE**

1.0. LVO -56.

**INPUTS**

- `context`: the bus or connection.
- `unit`: the device: 1 to 247 on RTU, 0 broadcasts to all; 0 to 255
  on TCP.
- `address`: the first coil, from 0.
- `count`: how many, 1 to 1968.
- `values`: `count` bytes, each 0 to clear its coil or not 0 to set it.

**RESULT**

MBERR_OK once the device has repeated the question, as it does to
say it is done; the device's exception (MBEX_*, above 0); or, below
0, what kept it from being answered: MBERR_TIMEOUT, MBERR_CRC,
MBERR_REPLY, MBERR_IO, MBERR_CLOSED - or MBERR_ARGS for a count of 0 or past 1968, or a run past address 65535. To unit 0
on RTU the write is broadcast to every device, none answers, and
MBERR_OK means it was sent.

**BEHAVIOR**

One question, function 0x0F, the coils packed eight to a byte.

**CONTEXT**

- Waits: yes, for the answer.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: the task that opened the context.

**OWNERSHIP**

`values` is the caller's.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`WriteCoil`, `ReadCoils`

**EXAMPLES**

```zig
const pattern = [_]u8{ 1, 0, 1, 0 };
const result = mb.WriteCoils(bus, 1, 0, pattern.len, &pattern);
```

## WriteRegister

Sets one holding register.

**SYNOPSIS**

```zig
fn WriteRegister(base: *ModbusBase, context: *modbus.ModbusContext, unit: u32, address: u32, value: u32) i32
```

**SINCE**

1.0. LVO -52.

**INPUTS**

- `context`: the bus or connection.
- `unit`: the device: 1 to 247 on RTU, 0 broadcasts to all; 0 to 255
  on TCP.
- `address`: the register, from 0.
- `value`: what it is set to, 0 to 65535.

**RESULT**

MBERR_OK once the device has repeated the question, as it does to
say it is done; the device's exception (MBEX_*, above 0); or, below
0, what kept it from being answered: MBERR_TIMEOUT, MBERR_CRC,
MBERR_REPLY, MBERR_IO, MBERR_CLOSED - or MBERR_ARGS for an address or a value past 65535. To unit 0
on RTU the write is broadcast to every device, none answers, and
MBERR_OK means it was sent.

**BEHAVIOR**

One question, function 0x06.

**CONTEXT**

- Waits: yes, for the answer.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: the task that opened the context.

**OWNERSHIP**

Nothing is kept.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`WriteRegisters`, `ReadHoldingRegisters`

**EXAMPLES**

```zig
const result = mb.WriteRegister(bus, 1, 40, 1500); // a set point
```

## WriteRegisters

Sets a run of holding registers.

**SYNOPSIS**

```zig
fn WriteRegisters(base: *ModbusBase, context: *modbus.ModbusContext, unit: u32, address: u32, count: u32, values: [*]const u16) i32
```

**SINCE**

1.0. LVO -60.

**INPUTS**

- `context`: the bus or connection.
- `unit`: the device: 1 to 247 on RTU, 0 broadcasts to all; 0 to 255
  on TCP.
- `address`: the first register, from 0.
- `count`: how many, 1 to 123.
- `values`: `count` registers.

**RESULT**

MBERR_OK once the device has repeated the question, as it does to
say it is done; the device's exception (MBEX_*, above 0); or, below
0, what kept it from being answered: MBERR_TIMEOUT, MBERR_CRC,
MBERR_REPLY, MBERR_IO, MBERR_CLOSED - or MBERR_ARGS for a count of 0 or past 123, or a run past address 65535. To unit 0
on RTU the write is broadcast to every device, none answers, and
MBERR_OK means it was sent.

**BEHAVIOR**

One question, function 0x10.

**CONTEXT**

- Waits: yes, for the answer.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: the task that opened the context.

**OWNERSHIP**

`values` is the caller's.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`WriteRegister`, `ReadWriteRegisters`

**EXAMPLES**

```zig
const limits = [_]u16{ 100, 900 };
const result = mb.WriteRegisters(bus, 1, 10, limits.len, &limits);
```
