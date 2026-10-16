# Debugging

What the system gives to find a bug: the log it keeps from the first byte
of the boot, what a failure prints and asks, the tools in a shell, the
serial console's `s3>`, the ROM debugger for a machine that has stopped,
memory debugging, and JTAG. A section per symptom at the end says which
to reach for first.

## The tools, and when each is there

| Tool | Where | What it needs | Gone when |
|---|---|---|---|
| `C:Log`, `C:Top`, `C:Avail OWNERS`, `C:MemDebug`, `ShowInfo TASKS` | a shell, in a window or on the serial console | dos, a console, memory | the shell's console or dos is stuck |
| `s3>` | the serial console | the scheduler, a console device, memory | the scheduler or memory is broken |
| `dbg>`, the ROM debugger | both raw ports at once | nothing: no task, no device, no memory | never; only a blown stack stops it |
| the system log | `Log`, the raw port, a syslog server | nothing: exec writes it | never; its last 4 KiB survive a dead end's restart |
| JTAG | the chip's USB port, OpenOCD and gdb on the PC | the chip | never |

**The serial console** is UART0 in QEMU and on the CrowPanel, and the
chip's own USB port on the 7B, the ES3C35P and the Olimex. Its `s3>`
prompt is the ROM's console, not a CLI: `newshell` starts a dos shell on
it (`List`, `Info`, `Mount`, ...), and `EndCLI` comes back. A number
typed at `s3>` is decimal unless it starts with `0x`; one typed at
`dbg>` is hex unless it starts with `#`.

## What a failure looks like

A failure prints a Guru on the raw port, and on the chip's USB port as
well, whatever level the log keeps:

```
*** Software Failure.
*** Guru Meditation #81000101.42071B16
*** index out of bounds: index 5, len 2
*** in EchoArgs at +0x51A
*** Task "Shell Process [2]" at 0x3C084148
```

- **The title:** `Software Failure.` for a dead end, which the failing
  code cannot go on from; `Recoverable Alert.` for one it goes on from.
- **`#AAAAAAAA.PPPPPPPP`:** the alert number, then the address. The
  address is the exact instruction for a CPU exception, and a return
  address for a call to `Alert` or a panic, so the call is just before
  it.
- **The text**, when there is one: what failed.
- **`in ...`:** the code the address is in - `the ROM`, or a file loaded
  from disk and the offset into it.
- **The task** that was running.

A CPU exception adds its cause, the address it was about and the trap
frame:

```
*** CPU exception 29 (store_prohibited) at 0x4201A2C4, address 0x00000004
```

**The alert numbers.** The top bit is `AT_DeadEnd`. A CPU exception is
`AT_DeadEnd` with the CPU's own exception number below it (EXCCAUSE on
the ESP32-S3, mcause on the ESP32-P4): `8000001D` is the S3's
`store_prohibited`, a write through a bad pointer. The others
(`sdk.exec.alerts`):

| Number | Name | What happened |
|---|---|---|
| `81000101` | `AN_ProgramPanic` | a failed check in a program, library, device or handler from disk: overflow, index, `unreachable`, a null unwrapped |
| `81000100` | `AN_KernelPanic` | the same in the ROM |
| `8100000E` | `AN_StackProbe` | a stack ran past its end: its guard is written over ([A stack that runs out](programs.md#a-stack-that-runs-out)) |
| `01000102`, `81000102` | `AN_LockRule` | a spinlock's rule broken; the text names the locks. A dead end for `Wait` with a spinlock held |
| `81000103` | `AN_LockDeadlock` | a spinlock taken again on the core that holds it |
| `01000009` | `AN_FreeTwice` | `FreeMem` of a block not in use: freed already, or its header written over. The block is left |
| `01000104` | `AN_BadFreeSize` | `FreeMem` with a size that is not the block's. The block is left |
| `01000105` | `AN_MemWall` | a block written past its end, found by its wall ([Memory debugging](#memory-debugging)). The block is freed |
| `01000008` | `AN_SemCorrupt` | a semaphore released that the task does not hold |

**What happens next.** A dead end of a task that can be held - not in an
interrupt, no spinlock held, nothing masked, a screen open to ask on -
holds that task and asks on the display: **Suspend**, **Kill** or
**Reboot**; the machine runs on ([When a check fails](programs.md#when-a-check-fails)
has the details). Any other dead end stops the machine: it keeps the end
of the log over the restart, offers the ROM debugger for a few seconds
(`*** enter the debugger? (y)`), and restarts if nobody answers. The next
boot's log starts with the last words of the one before; `Log` shows
them.

## From an address to a line

**In the ROM.** The address as the Guru printed it, looked up in the
kernel's ELF of the same build - `zig-out/bin/kernel` is the board built
last:

```sh
llvm-symbolizer --obj=zig-out/bin/kernel <address>
```

**In a file loaded from disk.** The offset after `at +` is the address in
that file's linked ELF, which is linked at 0. The ELF is the program's
`compile exe` output in Zig's cache, named like the file with dots and
dashes made underscores (`bsdsocket_library`); `file` tells which chip it
is for, since the S3 and the P4 builds have the same name:

```sh
$ ls -t .zig-cache/o/*/memowner | head -1
.zig-cache/o/9ed058008cec369ce26f439ab5cc60f7/memowner
$ llvm-symbolizer --obj=.zig-cache/o/9ed058008cec369ce26f439ab5cc60f7/memowner 0x1882
libs.exec.libraries.call
.../sdk/libs/exec/libraries.zig:135:35
interface.exec.ExecBase.FreeMem
.../sdk/interface/exec.zig:386:30
memowner.misuse
.../src/disk/c/test/memowner/memowner.zig:191:20
```

**A return address points after the call.** Take 3 off on the ESP32-S3
and 4 on the ESP32-P4 to land inside it, as above for a Guru's `+0x1885`.
A CPU exception's address is exact. The lines `bt` prints in the ROM
debugger are inside the call already.

## The ROM debugger

The debugger runs with interrupts masked, on no task and through no
device, and allocates nothing, so it works when everything else has
stopped. It reads and writes on both raw ports at once, UART0 and the
chip's USB port, because a stopped machine cannot ask which cable is in.

**Three ways in:**
- `debug` at `s3>` stops a working machine; `g` sets it going again.
- A dead end offers it for a few seconds.
- `Debug(0)` from code, where something impossible has happened.

A breakpoint or a watchpoint enters it too, saying what stopped where.

| Command | What it does |
|---|---|
| `r` | the registers of the trap frame |
| `bt` | the call chain, each address with the code it is in |
| `d <addr> [bytes]` | memory, in words (64 bytes unless given) |
| `m <addr> <value>` | one word written |
| `b [<addr>]` | a breakpoint at that address, or the ones set |
| `b off [<n>]` | one breakpoint off, or all |
| `w <addr> [<size>] [r\|w\|rw]` | a watchpoint on `size` bytes (4), on writing unless told |
| `w off` | every watchpoint off |
| `s` | one instruction, after a breakpoint or a watchpoint |
| `g`, `q` | go on |
| `reset` | the machine started again |
| `?` | the commands |

**Breakpoints and watchpoints are the core's own.** The ESP32-S3 has two
of each. The ESP32-P4 has three triggers, used as two breakpoints and
one watchpoint. Nothing is written into the code, which is in flash
anyway. A watchpoint beyond the last slot replaces the oldest. `b` lists
each address with the code it is in, so typing an address to `b` and
taking it off again names it.

**They are set on one core:** the one the debugger runs on, which is
core 0 when it was entered from `s3>`. Code that runs on the other core
passes them. A kernel built with `-Dcores=1` runs everything on core 0,
so every task meets them; a task can also be pinned to core 0
(`SetTaskAffinity`).

**Going on.** From a breakpoint, `g` steps over the breakpoint's own
instruction and puts it back. From a dead end there is nothing to go
back to: `g` halts the machine, and `reset` starts it again. `s` steps
with every interrupt held off, so what is stepped is the code that was
stopped.

**The call chain.** On the ESP32-P4 `bt` follows the frame pointers the
kernel is built with. On the ESP32-S3 it reads what the register windows
have spilled to the stacks, so it can stop early: it says so rather than
guess the rest.

**A session.** A breakpoint on `AllocMem`'s vector, found with
`llvm-nm zig-out/bin/kernel | grep lvoAllocMem`, and the shell made to
allocate:

```
s3> debug
ROM debugger. ? for the commands.
stopped in task "shell"
dbg> b 42816c34
  0  0x42816C34 (the ROM)
dbg> g
s3> newshell
ROM debugger. ? for the commands.
breakpoint at 0x42816C34 (the ROM)
stopped in task "shell"
dbg> bt
   0  0x42816C34 (the ROM)
   1  0x4289E062 (the ROM)
   2  0x4289DE97 (the ROM)
   ...
dbg> b off
all off
dbg> g
```

`llvm-symbolizer --obj=zig-out/bin/kernel 0x4289E062 0x4289DE97` then
names the calls: `AllocVec` from dos's `AllocDosObject`.

**Who writes a word.** A watchpoint on it - `w <addr> 4 w`, then `g` -
stops the machine at the code that writes it, in whichever task runs it
on that core, and `bt` shows how that code got there. The same boot in
QEMU often puts the same blocks at the same addresses, so an address
found once can be watched early in the next run.

## The serial console: `s3>`

`help` lists every command. By what each is for:

**Tasks, cores and locks**
- `tasks` - what each core runs, then the ready and the waiting tasks:
  priority, state, the core it runs on and the one it is pinned to, the
  signals it waits for and has.
- `cores` - per core: what it runs, its dispatches and idle rounds, and
  the longest it held or waited for the interrupt lock, with the code
  that did ([Two cores](programs.md#two-cores)).
- `locks` - which task holds which semaphore, how often and whether
  shared, and which one each task waits for.
- `sems`, `ports` - the public semaphores and message ports.
- `clis` - the CLIs and their processes.
- `kill <number>` - ends a task as Kill on the Software Failure requester
  does.

**Memory**
- `memlist` - the memory regions.
- `memowners [<number>]` - who holds the memory: the system, each task,
  and tasks that have ended with what they left; with a number, that
  owner's blocks.
- `memdebug [on|off|check]` - memory debugging, below.
- `memtrace [on|count|off|min <bytes>]` - counts what is allocated and
  freed around a measurement: `on` prints each event too, `count` only
  counts, which disturbs the timing less, `off` says what is still out.
- `peek <addr> [words]`, `poke <addr> <value>` - memory read and written.

**Modules and the machine**
- `libs`, `devs`, `resources`, `residents`, `segments`, `doslist`,
  `ints` - what is loaded, resident, mounted and hooked.
- `info`, `uptime`, `eclock`, `date`, `systime` - the CPU and its
  clocks, the time.
- `cache`, `wdt`, `reboot` - the caches, the watchdog, a restart.

**Failures on purpose**
- `alert <code>` raises an alert; `0x8...` is a dead end.
- `fault [load|ill]` raises a CPU exception, and `panic` a Zig panic.
- `trap [skip|off]` installs task trap code that steps over a faulting
  instruction.
- `syscall`, `cause`, `trigger` go into the kernel, raise a software
  interrupt, or raise an interrupt from the CPU.

**Devices**, each through its own device: `disk`, `sdcard`, `ser`,
`dma`, `screen`, `constop`, `tdelay`, `tabort`, `rdb`, `format`.

**And** `newshell [console]` for a dos shell, `debug` for the ROM
debugger.

## The system log

Everything written to the raw port is kept in a ring, each line with the
time since the boot and its writer: `Log` shows it, follows it, saves it
and sends it to a syslog server, and `Log LEVEL debug` keeps the debug
lines too. A dead end that restarts the machine keeps the last 4 KiB in
RTC memory for the next boot. [The system log](programs.md#the-system-log)
has the details.

What a task's end gave back is a line each:

```
exec: task "MemOwner crash" #27 ended holding 1 semaphore - released: 3C030B18 "MemOwner"
intuition: task "MemOwner crash" #27 ended with 1 window open - closed
exec: task "MemOwner crash" #27 ended with 2 private blocks, 20480 bytes - freed
```

A program that ends cleanly prints none of them, so each one points at a
program that forgot something.

## Memory debugging

Memory debugging puts a wall of 16 bytes behind every new block, fills
new memory with `0xABADCAFE` unless it was asked cleared, fills freed
memory with `0xDEADBEEF`, and gives new stacks of 4 KiB or more a guard
of 256 bytes. `FreeMem` checks the wall, and `AllocMem` checks that
freed memory still holds its pattern when it hands it out again. What
they find is a line on the log naming the block and its owner. A wall
written over is a recoverable alert (`AN_MemWall`) as well.

| Switched | How |
|---|---|
| for a whole run | build the kernel with `-Dmemdebug=true`: on from exec's start, so the blocks the system makes as it comes up are walled too |
| from a shell | `MemDebug ON`, `MemDebug OFF` |
| at the serial console | `memdebug on`, `memdebug off` |
| from a program | `sys.MemDebug(exec.MEMDEBUG_ON, null, null, 0)` |

A block allocated before the mode was on has no wall. **`MemDebug
CHECK`** looks at every wall and all free memory now and names what is
wrong: a block written past its end with its owner, free memory written
after its free, or a block header written over, where the region can no
longer be walked. It ends with `WARN` when it finds anything, so a script
can stop on it:

```
MemDebug ON
C:MyProgram
MemDebug CHECK
If WARN
  Log LINES 20
EndIf
```

`C:test/MemOwner OVERRUN` and `AFTERFREE` make both mistakes on purpose.
The mode costs memory and time on every allocation; it is for hunting one
bug.

## By symptom

**A program stops with a Guru.** Read the alert number and the text,
then turn the `in ... at +` into a line. Kill it in the requester; its
end gives back its semaphores, windows and private memory, and
`Avail OWNERS` shows what is left under its number. A program run from a
shell runs on the shell's process, so Kill ends that shell too.

**The machine or a window stops answering.**
- `tasks` at `s3>`: a task waiting with signals nobody sends, or a busy
  one that never waits.
- `locks`: the task holding the semaphore another waits for.
- `cores`: a core that holds its interrupts off for long, or one whose
  dispatches no longer move.
- Where a spinlock's rule was broken, the log has `AN_LockRule` with both
  locks named ([the rules](programs.md#keeping-others-out-semaphores-spinlocks-and-disable)).

A program in the foreground holds its shell until its window closes,
which looks exactly like a hang.

**Memory is written where it should not be.** Strange values in a
structure, a `FreeMem` refused, a crash far from its cause.
- Turn memory debugging on, best with `-Dmemdebug=true`, and run the
  suspect again.
- A wall alert names the block and its owner; `MemDebug CHECK` finds
  what no free has looked at yet.
- To catch the writer itself, put a watchpoint on the damaged word.

**Memory runs out.**
- `Avail OWNERS` before and after the suspect; `memowners <number>` at
  `s3>` lists that owner's blocks.
- `memtrace count` and `memtrace off` around one action show what it
  left allocated.
- An ended task's number with blocks under it is memory that program, or
  a library on its behalf, never gave back.

**A stack runs out.** `AN_StackProbe`. Give the command more with
`Stack 32000`, and a task more with `CreateTask`'s or `NP_StackSize`'s
size. With memory debugging on, the guard is wide enough to catch a large
frame that jumps over the narrow one.

**The machine restarts by itself.** The first lines of `Log` after the
boot are the last words of the boot before, if it ended in a dead end.
From the reset button there are none: it powers the chip down.

**It fails before the console is up.** The raw port has the log from the
first line of the boot. A CPU exception before exec is up prints
`*** FATAL EXCEPTION` with the trap frame and halts. In QEMU the same boot
fails the same way.

## In an emulator

`./zig build qemu` boots the S3 with the serial console in the terminal,
and `qemu-display` adds the screen. Each run starts from the same image,
so a failure comes back, often at the same addresses; `qemu-disk` keeps
what is written to the disk. A test runs at boot without typing when its
commands are put on the disk as `s/User-Startup` with
`-Dextra=s/User-Startup=<file>`.
`./zig build emu` runs the ESP32-P4 kernel in esp-emulator, without a
screen. QEMU's time is not the chip's: compare speeds on a board.

## Over JTAG

Both chips' USB port is a JTAG port too, so a board that prints nothing
can still be stopped and read. OpenOCD from ESP-IDF's tools takes
`board/esp32s3-builtin.cfg` or `board/esp32p4-builtin.cfg`, with
`-c "set ESP_RTOS none"`, since the system has no tasks OpenOCD knows.
gdb from ESP-IDF's toolchain - `xtensa-esp32s3-elf-gdb`, or
`riscv32-esp-elf-gdb` for the P4 - loads `zig-out/bin/kernel` and
attaches to `target extended-remote :3333`. While the core is halted,
registers and memory can be read and a peripheral's registers written
by hand. OpenOCD holds the port: stop it before flashing.

Attaching halts the core, and opening the port can reset the chip. For a
state that should be looked at as it is, `s3>` is often the better
first tool.

## In the host tests

`./zig build test` runs the ROM modules and the disk modules on the PC.
A test sets exec up with `exec.setUp()`, makes the module with
`exec.InitResident`, frees what it made and ends with
`exec.expectNoLeaks()`, so a leak fails the test with the blocks still
out. A bug that can be reproduced there
is the cheapest to find: the code runs under the PC's own debugger.
