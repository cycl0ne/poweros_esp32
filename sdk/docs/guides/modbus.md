# Modbus

Modbus is how controllers, meters, drives and sensors are read and set
in a cabinet: a client asks a device - a unit, by its number - for a run
of its data or to change it, and the device answers. `modbus.library`,
in `LIBS:`, speaks it both ways: as a client asking devices, and as a
server that makes the board a device itself. It carries the protocol
over an RS-485 bus (RTU) and over the network (TCP).

This guide is the bus first, then the client, the server and the
commands.

## A device's data

Every device has four tables, each numbered from 0:

| Table | What | Read with | Written with |
|---|---|---|---|
| coils | bits | `ReadCoils` | `WriteCoil`, `WriteCoils` |
| discrete inputs | bits | `ReadDiscreteInputs` | - |
| holding registers | 16-bit words | `ReadHoldingRegisters` | `WriteRegister`, `WriteRegisters`, `ReadWriteRegisters` |
| input registers | 16-bit words | `ReadInputRegisters` | - |

What a device keeps where is in its manual: a meter's voltage may be
input register 0, a drive's speed set point holding register 40. A
manual that counts from 1, or writes holding register 0 as `40001`,
means address 0 here.

A bit travels as a byte in the library's calls, 0 or 1, one per coil or
input; a register as a `u16` in the machine's own order. The library
packs bits eight to a byte and turns registers big-endian on the way.

## The bus: rs485.device

`DEVS:rs485.device` is the board's RS-485 port. It is there on a board
that has one - the 7B, and QEMU, where it is the second serial port - and
opening it fails on one that has none. Unit 0 is the port; it is
exclusive.

The device works in frames, as every RS-485 protocol does: bytes sent
one after the other, each frame ended by the line going quiet. A
`CMD_WRITE` sends one frame and is replied when its last bit is on the
wire; a `CMD_READ` returns one whole frame, the bytes until the line was
quiet for the unit's gap, waiting at most the request's `timeout`.
Frames that come while no read waits are kept, four of them, for the
reads to come; `CMD_CLEAR` drops them. The port is half-duplex, and what
the device sends never comes back to it as a frame received.

```zig
const port = sys.CreateMsgPort() orelse return;
defer sys.DeleteMsgPort(port);
const io: *rs485.IORS485 = @ptrCast(@alignCast(sys.CreateIORequest(port, @sizeOf(rs485.IORS485)) orelse return));
defer sys.DeleteIORequest(&io.std.req);
if (sys.OpenDevice(rs485.RS485NAME, 0, &io.std.req, 0) != 0) return;
defer sys.CloseDevice(&io.std.req);

io.std.req.command = rs485.RS485CMD_SETPARAMS;
io.baud = 9600;
io.data_bits = 8;
io.parity = rs485.RS485_PARITY_NONE;
io.stop_bits = 1;
io.gap = 35; // three and a half characters
_ = sys.DoIO(&io.std.req);

var frame: [rs485.RS485_MAX_FRAME]u8 = undefined;
io.std.req.command = exec.CMD_READ;
io.std.data = &frame;
io.std.length = frame.len;
io.timeout = 500_000; // µs
if (sys.DoIO(&io.std.req) == 0) {
    // frame[0..@intCast(io.std.actual)]
}
```

The gap is in tenths of a character, so it holds at any rate. On the 7B
the transceiver switches to sending by itself whenever the line is
driven, so a program never turns the bus round; its 120 Ω terminator is
switched in by hand (SW2) at the ends of the bus only.

## A client

A context is one bus or one connection. `OpenModbusRTU` opens the
bus's device and sets its line - 19200 bit/s, even parity, one stop
bit unless the tags say otherwise, as the protocol has it;
`OpenModbusTCP` connects to a host's port 502 with the program's own
bsdsocket.library base. Every call after that is the same for both:

```zig
const mb: *ModbusBase = @ptrCast(sys.OpenLibrary(modbus.MODBUSNAME, 1) orelse return);
defer sys.CloseLibrary(mb.lib());

var err: i32 = 0;
const bus = mb.OpenModbusRTU(&[_]utility.TagItem{
    .{ .tag = modbus.MBA_Baud, .data = 9600 },
    .{ .tag = modbus.MBA_Parity, .data = modbus.MB_PARITY_NONE },
    .{ .tag = modbus.MBA_StopBits, .data = 2 },
    .{},
}, &err) orelse return;
defer mb.CloseModbus(bus);

var registers: [2]u16 = undefined;
const result = mb.ReadInputRegisters(bus, 1, 0, 2, &registers);
```

```zig
const plc = mb.OpenModbusTCP(sb, &[_]utility.TagItem{
    .{ .tag = modbus.MBA_Host, .data = @intFromPtr("plc.local") },
    .{ .tag = modbus.MBA_Timeout, .data = 500 },
    .{},
}, &err) orelse return;
defer mb.CloseModbus(plc);
_ = mb.WriteCoil(plc, 1, 0, 1);
```

Every call waits for its answer, up to the context's time-out (a
second). A context belongs to the task that opened it: its request,
and on TCP its socket, are used on that task.

On RTU, unit 0 is every device at once: a write to it is carried out by
all of them and answered by none, so the call returns once it is sent,
and a read of unit 0 is refused. On TCP the unit is passed on for a
gateway to route; a device on its own usually ignores it.

`ModbusTransaction` asks anything at all - the PDU as bytes, the
function code first - and hands back the answer's PDU as it came, for a
function the library has no call for.

## What a call answers

| Result | |
|---|---|
| `MBERR_OK` (0) | done; what was read is in the buffer |
| above 0 | the device answered with an exception: `MBEX_ILLEGAL_FUNCTION` (it does not do that), `MBEX_ILLEGAL_ADDRESS` (no such address, or a run past its end), `MBEX_ILLEGAL_VALUE`, `MBEX_DEVICE_FAILURE`, `MBEX_ACKNOWLEDGE` (taken, still working), `MBEX_DEVICE_BUSY`, and a gateway's two |
| below 0 | no answer came (`MBERR_TIMEOUT`), it came damaged (`MBERR_CRC`), it was not an answer to the question (`MBERR_REPLY`), the device or the connection failed (`MBERR_IO`, `MBERR_CLOSED`), or the question itself was out of range (`MBERR_ARGS`) |

`OpenModbusRTU`, `OpenModbusTCP` and `StartModbusServer` answer null
when they fail and put why in their `err`: `MBERR_DEVICE` (the bus's
device would not open), `MBERR_HOST` (no such host), `MBERR_CONNECT`
(no connection), `MBERR_NOMEM` or `MBERR_ARGS`.

`ModbusErrorText` gives any of them in words.

## A server

`StartModbusServer` makes the board a Modbus device: it answers
questions from tables the program hands it - from address 0, as many of
each as the program has - on a process of its own, until
`StopModbusServer`. On RTU it is one unit on the bus, the one
`MBS_Unit` names (1 to 247, and without it the server does not start);
on TCP it listens on port 502, for IPv4 and IPv6, and answers every
unit, or only the one a non-zero `MBS_Unit` names.

```zig
var lock: exec.SignalSemaphore = .{};
sys.InitSemaphore(&lock);
var holding: [16]u16 = @splat(0);
var inputs: [4]u16 = .{ 0, 0, 0, 0 };

const server = mb.StartModbusServer(&[_]utility.TagItem{
    .{ .tag = modbus.MBS_Transport, .data = modbus.MBT_TCP },
    .{ .tag = modbus.MBS_HoldingRegisters, .data = @intFromPtr(&holding) },
    .{ .tag = modbus.MBS_HoldingCount, .data = holding.len },
    .{ .tag = modbus.MBS_InputRegisters, .data = @intFromPtr(&inputs) },
    .{ .tag = modbus.MBS_InputCount, .data = inputs.len },
    .{ .tag = modbus.MBS_Lock, .data = @intFromPtr(&lock) },
    .{},
}, &err) orelse return;
defer mb.StopModbusServer(server);

// A new reading, put where clients read it.
sys.ObtainSemaphore(&lock);
inputs[0] = temperature;
sys.ReleaseSemaphore(&lock);
```

The server holds `MBS_Lock` while it reads or writes the tables, so a
program that changes a run of registers under it too never has a client
read half of the change. A hook (`MBS_Hook`) is told of every write a
client made - the function, the first address, how many - after the
lock is let go. It runs on the server's process, so it should do little:
note what changed and signal the program, which acts on it.

An address past a table's end, or a table the program did not give, is
answered with `MBEX_ILLEGAL_ADDRESS`, and a function the server does
not do with `MBEX_ILLEGAL_FUNCTION`; the program never sees either.

## From the shell

`C:Modbus` asks a device anything the calls can:

```
Modbus 0 COUNT 4 ID 7                      four holding registers of unit 7 on the bus
Modbus 40 1500                             holding register 40 of unit 1 set to 1500
Modbus 0 COUNT 8 COILS                     eight coils
Modbus 3 1 0 1 COILS                       coils 3 to 5 set, cleared, set
Modbus 0 COUNT 2 INPUT HOST 192.168.1.20   two input registers over TCP
Modbus 0 BAUD 9600 PARITY NONE             the bus at another line
```

`C:test/ModbusServer` is a device to try a client against: sixteen of
each table, holding register 0 counting the seconds, every write a
client makes printed. `ModbusServer TCP` serves the network,
`ModbusServer UNIT 3` the bus as unit 3.

`SYS:Programs/Battery` is a whole program on the library: it reads a
battery's registers from a Victron GX device over TCP every two seconds
and shows them with the disk's gadgets - the charge on a ring, the
health on a bar, the power on a meter and as a chart, the rest as
labelled text:

```
Battery HOST 192.168.1.13 ID 225
```

`ID` is the unit ID the GX device lists for the battery under Settings,
Services, Modbus TCP, Available services - not the battery's VRM
instance, which is a number of its own.

## In QEMU

QEMU's second serial port is the RS-485 port there. `-Drs485=` hands it
to one of QEMU's serial backends, so a program on the host can be the
other end of the bus:

```sh
./zig build qemu -Drs485=tcp::5020,server,nowait
```

A Modbus device simulator, or a script that speaks RTU, then connects to
port 5020. Over TCP, a client in QEMU reaches a server on the host at
10.0.2.2; a server in QEMU is reached through a forwarded port:

```sh
./zig build qemu -Dnet=user,hostfwd=tcp::5502-:502
```
