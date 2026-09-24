# zig-s3

A small bare-metal kernel for the ESP32-S3, written in Zig with the
[Espressif Zig toolchain](https://github.com/kassane/zig-espressif-bootstrap)
(`0.16.0-xtensa`, LLVM with Xtensa/esp32s3 support).

No ESP-IDF, no second-stage bootloader: the ROM bootloader loads the kernel's
RAM part (vectors, boot code, data) from flash offset `0x0` into SRAM and
jumps to `_start`; the boot code maps the rest of the code, which runs from
flash through the instruction cache (see
[docs/memory-map.md](docs/memory-map.md)).

## What it does

- **Boot** (`src/arch/esp32s3/start.S`): installs its own vector table (VECBASE), resets
  the register window, zeroes `.bss`, enables the FPU, calls `kernel_early`
  (from IRAM: watchdogs, clock, PSRAM, and the MMU mapping of the code in
  flash, `src/arch/esp32s3/flashmap.zig`), then `kmain`, with the windowed ABI.
- **Exceptions**: window overflow/underflow handlers, and a level-1
  exception entry that saves the full context into a frame and calls into
  Zig. It handles interrupts, `syscall`, and fatal exceptions (with a
  register dump).
- **Interrupts**: a dispatch table for level-1 interrupts. The kernel tick
  runs at 100 Hz on CCOMPARE0 (internal interrupt 6).
- **Clock** (`src/arch/esp32s3/clock.zig`): switches the CPU from the 40 MHz crystal to
  the 480 MHz BBPLL at 240 MHz (`clock.cpu_hz`), following ESP-IDF's
  sequence: PLL calibration, core voltage raised to IDF's default for 240 MHz,
  LDO slaves, then the clock switch. The UARTs run from the crystal
  (exec's `RawIOInit` and serial.device set them up), so the switch
  doesn't change their rates.
- **Time**: SYSTIMER (16 MHz, crystal-based) for uptime. The CCOUNT rate is
  measured against it. If the measurement is more than 5% away from 240 MHz,
  the tick uses the measured clock and the kernel logs a warning. This happens
  in stock QEMU, which keeps the CPU at 40 MHz. The QEMU built by
  `scripts/build-qemu.sh` runs it at 240 MHz.
- **Watchdogs**: the RTC and TIMG watchdogs are disabled, and the super
  watchdog feeds itself.
- **Kernel output**: exec's `kprintf` (`RawDoFmt` to `RawPutChar`) on
  UART0, polled, at 115200 baud: status lines, panics, the Guru, trap
  dumps. Nothing is printed before exec's init has done `RawIOInit`, which
  sets UART0 up with exec's own driver (`src/rom/libs/exec/rawio.zig`). Programs use serial.device and
  usbserial.device.
- **Memory** (`src/arch/esp32s3/ram.zig`, `src/rom/libs/exec/memory.zig`): exec owns all free
  RAM as memory regions. The chip's own SRAM is internal memory
  (`MEMF_INTERNAL | MEMF_DMA`, priority −10), and the PSRAM behind the data
  cache is external memory (`MEMF_EXTERNAL`, priority 0), so `MEMF_ANY` uses
  PSRAM first and internal SRAM stays free for what only it can do: a DMA
  engine's descriptor chains, and anything the caches are suspended over.
  Everything
  allocates through `AllocMem`/`FreeMem`, or `AllocVec`/`FreeVec`, which
  remember the size. `CopyMem`, `CopyMemQuick` and `SetMem` copy and fill
  memory. `avail`, `memlist` and `memtrace` show the
  state.
- **PSRAM** (`src/arch/esp32s3/psram.zig`): octal PSRAM bring-up following ESP-IDF. It
  sets up the cache and MMU, the octal pins, and SPI at 20 MHz to configure
  the chip, then switches to 80 MHz DTR and maps the PSRAM at `0x3C000000`.
  A memory test at the end disables PSRAM rather than handing out broken
  memory.
- **SDK** (`sdk/`): what programs build against. It is laid out as the system
  is: the structures and constants of the libraries in `sdk/libs` (exec,
  utility.library, dos.library, rtg.library), of the devices in
  `sdk/devices`, of the resources in `sdk/resources`, and of the chip itself
  in `sdk/hardware`; the libraries' jump tables are in `sdk/interface`. Each
  library's base has its functions as methods
  (`sys.Forbid()`, `sys.AllocVec(...)`, `ub.Amiga2Date(...)`), called
  through the jump table. The jump tables are written in `.fd` files
  (`sdk/fd`), and `zig build fd` generates the interfaces from them. The
  kernel builds against the SDK too, and its build checks each library's
  functions against the SDK's types for them. The SDK is a Zig package of its
  own (`poweros_sdk`): a program outside the tree depends on it and builds
  with its `addProgram`, and the disk's programs
  (`src/disk`) are a second package, `poweros_userland`, built against the
  SDK alone. See [docs/sdk.md](docs/sdk.md).
- **exec** (`src/rom/libs/exec`): lists and libraries: `OpenLibrary`, `CloseLibrary`, `MakeLibrary`, `AddLibrary`,
  `RemLibrary`, `SetFunction` and `CreateLibrary`. Libraries have jump tables
  and delayed expunge, and `exec.library` is itself a library. When memory
  runs out, exec's memory handlers flush unused libraries. Interrupts have
  handlers (`SetIntVector`), server chains (`AddIntServer`),
  `Disable`/`Enable`, on the ESP32-S3's interrupt sources
  (`src/arch/esp32s3/intmatrix.zig`). The rest of this part of exec: software interrupts
  with `Cause`, and CPU exceptions that go to trap code or end in `Alert`,
  a Guru Meditation on the raw serial port and the display. Tasks are preemptive
  with priorities and a 4-tick time slice (`CreateTask`, `AddTask`,
  `RemTask`, `SetTaskPri`), and they wait on signals (`Wait`, `Signal`,
  `AllocSignal`) or take them as task exceptions (`SetExcept`). Tasks
  exchange messages through message ports (`PutMsg`, `GetMsg`, `ReplyMsg`,
  `WaitPort`), public ones by name (`AddPort`, `FindPort`), and lock
  shared data with signal semaphores: exclusive, shared, a whole list at
  once, or public by name (`ObtainSemaphore`, `ObtainSemaphoreShared`,
  `ObtainSemaphoreList`, `FindSemaphore`, or by message with `Procure`
  and `Vacate`). Devices are libraries on their own list, opened with an
  `IORequest` (`AddDevice`, `RemDevice`, `OpenDevice`, `CloseDevice`), and
  I/O goes to them with `DoIO`, `SendIO`, `CheckIO`, `WaitIO` and `AbortIO`; devices finish
  requests with `ReplyIO`. `RawDoFmt` formats (32-bit values, 64 with
  `%l`), and `RawIOInit`, `RawPutChar` and `RawMayGetChar` are the raw
  serial port (UART0), which `kprintf` prints to. Resident modules (ROM tags) in the kernel's
  `.resident` section are found by exec's boot scan and started in
  three stages: single task, then cold start from an exec task, then
  after DOS; `FindResident` and `InitResident` look up and start one by
  hand. Task code gets SysBase as its argument. The shell is exec's first
  task, and an idle task runs
  when no other task is ready (`src/arch/esp32s3/context.zig` switches the Xtensa
  register windows). See [docs/exec.md](docs/exec.md).
- **timer.device** (`src/rom/devs/timer`): a
  ROM-resident device started at cold start. It waits on five units
  (`TR_ADDREQUEST`), keeps the system time (`TR_GETSYSTIME`,
  `TR_SETSYSTIME`), and provides `AddTime`, `SubTime`, `CmpTime`,
  `ReadEClock` and `GetSysTime`. Its units share three delay
  lists. A one-shot micro timer (SYSTIMER alarm 0) ends the MICROHZ and
  E-clock waits at their time. A 50 Hz VBLANK (alarm 1) checks the VBLANK
  and WAITUNTIL waits. Both come in through exec's `AddIntServer`. See [docs/timer.md](docs/timer.md).
- **serial.device** (`src/rom/devs/serial`): the chip's UARTs, raw: units
  0–2 are UART0–2 (UART1 and UART2 without pins yet), set up by the device
  itself. It takes
  `IOExtSer` requests: the exclusive
  open (`SERF_SHARED` to share), `CMD_READ` waiting for `io_Length` bytes
  or a termination character (EOF mode), `SDCMD_SETPARAMS` (rate, frame,
  parity, xON/xOFF, buffer size), `SDCMD_BREAK`, `SDCMD_QUERY` with
  `io_Status`, the `SerErr_*` errors, `CMD_STOP`/`CMD_START`,
  `CMD_CLEAR`, `CMD_FLUSH`, `CMD_RESET`. Input comes in by interrupt
  through `AddIntServer`; breaks are timed by timer.device. See
  [docs/serial.md](docs/serial.md).
- **flash.device** (`src/rom/devs/flash`, `src/rom/devs/flash/spiflash.zig`): the
  board's 16 MiB SPI flash as a block device. Unit 0 is the disk area, from
  the build's `-Ddisk-offset` (2 MiB by default) to the end of the chip. It takes the requests
  of `sdk/devices/trackdisk.zig` (`CMD_READ`, `CMD_WRITE`, `TD_GETGEOMETRY`, ...),
  with byte offsets, and `TDCMD_ERASE`, since flash must be erased before it is written. Reading
  costs nothing: the area is mapped through the MMU into the data window, so
  `CMD_READ` is a `memcpy`. Writing suspends both caches, so every erase and
  program runs on the device's own task, on a stack in internal SRAM, with
  interrupts off - one sector or one page at a time. See
  [docs/flash.md](docs/flash.md).
- **sd.device** (`src/disk/devs/sd`, in `DEVS:`): the card in the board's
  microSD slot as a block device, unit 0 the whole card. It is on the disk,
  not in the ROM: ramlib loads it the first time something opens it, and
  it learns which pads are the slot's from platform.resource. The
  same block device API flash.device answers, so a file system written
  against one works over the other. The controller has a DMA of its own,
  so none of dma.resource's five channels are taken; it reaches internal
  memory only, so every transfer passes through a 16 KiB buffer there.
  Commands run on the device's own task and wait for the controller's
  interrupt, except `TD_CHANGENUM` and `TD_CHANGESTATE`, which a handler
  asks between packets and must not wait for. The slot has no card-detect
  line, so a card that has been taken out is found out by its not
  answering: the unit says there is none, counts the change, and looks
  again on the next command. On a board without a slot it opens nothing.
  See [docs/sd.md](docs/sd.md).
- **touch.device** (`src/rom/devs/touch`): the board's touch panel as
  contacts, not a mouse: `TOUCH_READEVENT` waits for fingers landing,
  moving and lifting, each with an id from its DOWN to its UP;
  `TOUCH_READSTATE` and `TOUCH_GETINFO`. Either controller a board has -
  the 7B's GT911 on the bus, reset through the IO expander and read on its
  interrupt, or the ES3C35P's inside the panel, reset through a pad and
  looked at every ten milliseconds because its line never arrives. A screen
  turned from the glass has the contacts turned with it, so a program is
  told where on the picture the finger is. Brought up on first open and fed
  by its own task; `C:Touch` prints the events. The emulator has no panel:
  its window's pointer is mouse.device's.
- **audio.device** (`src/rom/devs/audio`): four channels of sound, asked
  for with a precedence and stolen by whatever outranks them, written to
  with a period, a volume and a count of cycles - the commands the API was
  built for. The machine has one stereo codec and no four-voice hardware,
  so the device is the hardware: a task mixes the four channels itself
  (0 and 3 left, 1 and 2 right) into a stream a DMA ring hands to the I2S
  controller and an ES8311 codec. `C:Audio` plays a note. Only a board
  with a codec has it. See [docs/audio.md](docs/audio.md).
- **mouse.device** (`src/rom/devs/mouse`): a mouse as `IECLASS_RAWMOUSE`
  events - a move, and each of the left, right and middle buttons going
  down or up, with the buttons' qualifiers - through `MOUSE_READEVENT`, and
  `MOUSE_READSTATE` for where it is now. The one mouse is the emulator's:
  the pointer over the virtual display and its three buttons (our QEMU
  build, `scripts/qemu/esp_rgb_input.patch`). See [docs/mouse.md](docs/mouse.md).
  See [docs/touch.md](docs/touch.md).
- **keyboard.device** (`src/rom/devs/keyboard`): the keys as rawkey
  InputEvents - the key's place on the keyboard, 0x00-0x77, with the up bit
  and the qualifiers held after it. `KBD_READEVENT` waits for keys,
  `KBD_READMATRIX` answers which are down. The one keyboard so far is QEMU's
  window (the same patch); on the board the open fails. `C:Keyboard` prints
  the events. See [docs/keyboard.md](docs/keyboard.md).
- **keymap.library** (`src/rom/libs/keymap`): what a key means. `MapRawKey`
  turns a key event into characters and `MapANSI` characters back into
  keys; `SetKeyMapDefault`, `AskKeyMapDefault` and `FindKeyMap` say which
  keymap that is. Two in the ROM, by position and in Latin-1: "deutsch",
  the default, and "usa", with strings on the cursor and function keys and
  dead keys for the accents. `C:SetMap` switches it. See
  [docs/keymap.md](docs/keymap.md).
- **console.device** (`src/rom/devs/console`): a terminal in a window.
  `CMD_WRITE` is drawn into it, `CMD_READ` is what was typed. VT100 with
  the parts of xterm a program expects - the scrolling region, erasing with
  every parameter, save and restore cursor, insert mode, 256 colours, the
  line-drawing set (drawn, since Latin-1 has no box characters), the other
  screen, and a window of the size a program asks for - reading both
  `ESC [` and `0x9B` and sending `ESC [`. A `CONU_CHARMAP` unit keeps its
  text and puts it back when the window is uncovered or sized, which it
  hears about because intuition writes window events down input.device's
  chain; a `CONU_SNIPMAP` unit selects with the pointer as well, and
  Shift+Insert or right-Amiga V types the snip back, while `AddSnipHook`
  tells a program that a selection is finished - the seam a clipboard will
  use. A program can have the pointer instead (`CSI ?1000h` and its like,
  reported as `CSI < b ; col ; row M`), with Shift taking it back so text
  can still be selected. The cursor is filled in on the active window and
  an outline on one that is not, so it is plain which window a key would go
  to. Scrolling moves the
  window's own pixels with `ScrollRaster`. `C:Console` shows it, and
  `C:Nyan` puts a terminal through what an animation asks of one - the
  cursor home every frame, a colour per cell, the other screen, and the
  terminal asked how big it is. See [docs/console.md](docs/console.md).
- **input.device** (`src/rom/devs/input`): every input as one stream of
  InputEvents down a priority-ordered chain of handlers, each of which may
  change, drop or add to what it passes on. Keys from keyboard.device with
  key repeat added, fingers from touch.device as `IECLASS_TOUCH` - the
  first finger down also the pointer (`IECLASS_NEWPOINTERPOS`, left button)
  - the mouse from mouse.device as `IECLASS_RAWMOUSE` with the pointer
  after it, all three buttons, a timer tick ten times a second, and `IND_WRITEEVENT`. `PeekQualifier`
  answers the qualifiers. `C:Input` puts a handler on the chain and prints
  what passes. See [docs/input.md](docs/input.md).
- **i2c.device** (`src/rom/devs/i2c`, `sdk/hardware/gpio.zig`): the chip's
  two I2C controllers, one unit each. A unit is a bus and a bus carries one
  transfer at a time, so the unit's queue is the arbitration - no task, no
  semaphore. `CMD_READ`, `CMD_WRITE`, `I2CCMD_WRITEREAD` (a register read,
  which nothing else may slip into), `I2CCMD_PROBE`, `I2CCMD_SETPARAMS`.
  Most of what the bus is used for is two or three bytes, so `BeginIO`
  starts the transfer and spins on the controller for 250 microseconds with
  its interrupt off: inside that window the caller keeps `IOF_QUICK` and
  nothing is queued or scheduled, past it the request goes to the
  interrupt. `C:I2C SCAN` prints what is out there. See
  [docs/i2c.md](docs/i2c.md).
- **usbserial.device** (`src/rom/devs/usbserial`): the USB-Serial-JTAG
  port as a serial line, with serial.device's API (and code) on one unit;
  it has no line, so no rate or breaks. The shell merges it and
  serial.device's unit 0 into its console. See
  [docs/usbserial.md](docs/usbserial.md).
- **utility.library 1.0** (`src/rom/libs/utility`): the
  utility functions at fixed slots, plus pattern matching, a ROM-resident
  library started first at cold start. Tag lists (`NextTagItem`, `FindTagItem`, `CloneTagItems`,
  `MapTags`, ...), hooks (`CallHookPkt`), dates (`Amiga2Date`,
  `Date2Amiga`, `CheckDate`), 32- and 64-bit multiplication and division,
  Latin-1 `Stricmp` and `ToUpper`, pack tables (`PackStructureTags`),
  named objects in name spaces, `GetUniqueID`, and patterns
  (`ParsePattern`, `MatchPattern`, their NoCase versions, `SetWildStar`).
  See
  [docs/utility.md](docs/utility.md).
- **dos.library** (`src/rom/libs/dos`): the packet level (`DoPkt`,
  `SendPkt`, `WaitPkt`, `ReplyPkt`, `AbortPkt`, on
  PowerOS's packet, which is its own message), `AllocDosObject(DOS_STDPKT)`,
  `IoErr`/`SetIoErr`, and processes (`struct Process`, a minimal
  `CreateNewProc`), the device list (`LockDosList`, `FindDosEntry`,
  `AddDosEntry`, ...), `GetDeviceProc` (handlers start on first use) and a
  NIL: handler, and the path helpers (`AddPart`, `FilePart`, `PathPart`,
  `SplitName`, PowerOS's `ParsePath`), and resident segments
  (`AddSegment`, `FindSegment`, `RemSegment`; the ROM's handlers are system
  segments), and locks (`Lock`, `UnLock`, `DupLock`, `ParentDir`,
  `SameLock`, `CurrentDir`, `CreateDir`, `DeleteFile`), DateStamp, and
  files without buffering (`Open` with its modes, `Close`, `Read`,
  `Write`, `Seek`, `Input`, `Output`, `IsInteractive`), and examining
  (`Examine`, `ExNext`, `ExamineFH`, `ExAll` with dos's emulation,
  `ExAllEnd`), and the process's context (`Cli`, `SelectError`,
  `ErrorOutput`, the console and file system tasks, the program's
  directory and name, the prompt, `GetCurrentDirName`, `NameFromLock`;
  `NP_Cli`), and assigns (`AssignLock`, `AssignLate`, `AssignPath`,
  `AssignAdd`, `RemAssignList`; multi-assigns, `PROGDIR:`), and pattern
  searches (`MatchFirst`, `MatchNext`, `MatchEnd`, ExAll's MatchString,
  with utility.library's patterns), and changing objects (`Rename`,
  `SetProtection`, `SetComment`, `SetFileDate`, `SetOwner`, `SetFileSize`,
  `DupLockFromFH`, `ParentOfFH`, `NameFromFH`, `OpenFromLock`,
  `ChangeMode`, `Info`, `IsFileSystem`, `SameDevice`), and buffered I/O
  (`FGetC`, `UnGetC`, `FPutC`, `FRead`, `FWrite`, `FGets`, `FPuts`,
  `Flush`, `SetVBuf`, `VFPrintf`/`FPrintf`, `VPrintf`/`Printf`, `PutStr`,
  `WriteChars`; a 1 KiB buffer on first use, which the unbuffered calls
  keep to), and ReadArgs (templates, from a string or Input();
  `FreeArgs`, `ReadItem`, `FindArg`, `StrToLong`), and consoles
  (`SetMode`, `WaitForChar`), and for the shell: error texts (`Fault`,
  `PrintFault`), variables (`SetVar`, `GetVar`, `DeleteVar`, `FindVar`;
  `ENV:` from `S:Startup-Sequence`), `CheckSignal`, `Delay`, `GetArgStr`, CLI numbers
  (`MaxCli`, `FindCliProc`), CreateNewProc's stream, directory,
  argument, variable and CLI tags with the process's end, and
  `RunCommand` (the shell's built-ins and programs from a file, each on a
  stack of its own through exec's `NewStackRun`), and shells (`SystemTagList`,
  `Execute`), with `T:` for scripts' work files, and programs from
  a file (`LoadSeg`, `UnLoadSeg`: a load file made from a linked program by
  `sdk/tools/elf2seg`, its code relocated into memory the CPU can run from
  through exec's `CodeAddress`; `src/disk/c/test/hello/hello.zig` is the first one,
  and the build puts them on the flash disk's `C:`), and mounting
  (`FileSysStartupMsg`, `DosEnvec`, `RigidDiskBlock`: a node per partition
  of the disk, with `SYS:`, `C:`, `S:`, `LIBS:` and `DEVS:` assigned into
  the bootable one).
  PIPE: channels
  (`src/rom/handler/pipe`, docs/pipe.md) carry `a | b` between two shells.
  It is the
  last cold-start resident; its init
  opens utility.library into its base (`dl_UtilityBase`) and starts the
  after-DOS residents (`InitCode(RTF_AFTERDOS)`). See
  [docs/dos.md](docs/dos.md).
- **ramlib.library** (`src/rom/libs/ramlib`): libraries and devices that are not
  in the ROM. It stands in front of exec's OpenLibrary and OpenDevice, and
  when a name is on neither list it looks in `LIBS:` or `DEVS:`, loads the
  file with LoadSeg, finds the ROM tag in it and lets InitResident make it -
  so a module in a file and a module in the ROM are the same thing. A
  process loads for itself; a task asks ramlib's own process, because dos
  wants a process to hang a file on. `src/disk/libs/hello` is one such
  module. See [docs/ramlib.md](docs/ramlib.md).
- **Commands in `C:`** (`src/disk/c`): AddBuffers, Anim, Assign, Avail, Backlight, Console,
  ChangeTaskPri, Copy, Delete, Dir, Fonts, Format, Gfx, I2C, Info, Input, Intuition, Keyboard, Lines, List, MakeDir,
  Mount, Nyan, Plasma, Platform, Protect, RDB, Rename, Rtg, SetMap, Show, ShowConfig, TestLib, Touch, Type, Version, Wait
  and Which,
  each a
  program built against the
  SDK alone, loaded by the shell through LoadSeg from the flash disk, with
  a ReadArgs template (so `?` gives it) and a `$VER:` string that
  `Version` reads out of the file. The shell's built-ins are only what a
  shell cannot do without; everything else is a program. See
  [docs/shell.md](docs/shell.md#commands-on-disk).
- **The shell** (`src/rom/shell`): the shell as its own ROM
  module: the prompt, aliases, `$variables`, redirection, comments and
  continuations, resident commands through RunCommand, return codes, and
  the built-ins (CD, Echo, Set/Setenv/Alias, Get, Path, Prompt, Failat,
  Why, Fault, Resident, Stack, Ask, Run, NewShell, EndShell, Quit).
  The machine comes up in one: dos's init opens a window across the display
  and starts it there, reading `S:Startup-Sequence`.
  See [docs/shell.md](docs/shell.md).
- **CON:, RAW: and AUX:** (`src/rom/handler/con`): the console handler.
  CON: and RAW: are a terminal in a window of its own - console.device on
  an intuition window, one window per Open, where the name says where the
  window goes and what it may do
  (`CON:0/0/640/200/Title/CLOSE/WAIT/SCREEN name`), or hands over a window
  the program opened itself (`/WINDOW 0x...`, which the console then owns
  and closes); AUX: is the same terminal on the serial port (the USB port on the board, where UART0 is
  the kernel's debug output only; UART0 in QEMU). Line editing with control
  keys and the terminal's ESC [ sequences, history and search, Ctrl-C
  breaks, Ctrl-S to hold what is being written and any key to let it go,
  Ctrl-\\ for the end, raw mode, WAIT_CHAR, text handed in to be read as
  though it were typed, and PowerOS's banner
  above a console's first output (`src/rom/release.zig` holds the system's
  release number, and a ROM tag a program reads it from at run time). See [docs/con.md](docs/con.md).
- **RAM:** (`src/rom/handler/ram`): the ram-handler, a file system in
  memory started on the first use of `RAM:`: directories, locks, files in
  1K blocks (open, read, write, seek, close by packets), examine. See
  [docs/ram.md](docs/ram.md).
- **The flash disk** (`src/rom/handler/flashfs`): a file system that stays,
  on flash.device's 14 MiB. The disk says what it is: a
  RigidDiskBlock in its first blocks lists the partitions, each with its
  name, its blocks and the file system that belongs on it, and dos.library's
  init adds a device node per partition - `DH0:` is not a constant anywhere
  in the kernel. The file system answers the packets RAM: does, so a program
  cannot tell them apart, but on the medium it is a log: a change is a
  record appended after the last one and the newest record wins, because
  flash sets bits only by erasing a whole 4 KiB sector. Mounting replays the
  log into a tree in memory with the file data left where it lies; the
  collector takes the oldest segment when the disk runs short, which levels
  the wear; a power cut leaves a record that fails its checksum and ends the
  log there, so there is nothing to validate. `tools/mkfs` builds the
  image the board is flashed with - the RDB, the partition and the file
  system - by driving the very same code on the host, and `s3> rdb init`
  writes a first RigidDiskBlock onto a blank chip. See
  [docs/flashfs.md](docs/flashfs.md).
- **The card** (`src/disk/handlers/fat`, `HANDLERS:fat-handler`): FAT32,
  read and write, on sd.device - `Mount SD0:`. A handler on the disk
  rather than in the ROM: dos loads it the first time the device is used.
  It finds the volume itself, behind the card's partition table, and
  answers the packets RAM: and the flash disk do. Long names are read and
  written; a name that fits eight and three in one case is stored short.
  Directories are read from the card as they are walked, not held in
  memory, so a 64 GB card costs what its open files cost. A card taken
  out and put back is noticed before the next packet. See
  [docs/fat.md](docs/fat.md).
- **watchdog.resource** (`src/rom/resources/watchdog`): the chip's watchdog
  timer (TIMG0's MWDT) for programs: `ArmWatchdog`, `FeedWatchdog`,
  `DisarmWatchdog`, `ReadWatchdog`. exec has resources for it
  (`AddResource`, `RemResource`, `OpenResource`), and `ColdReboot`. kmain
  still stops the ROM's watchdogs first thing. See
  [docs/watchdog.md](docs/watchdog.md).
- **Caches**: exec's `CacheClearU`, `CacheClearE`, `CachePreDMA` and
  `CachePostDMA` on the S3's cache controller, for DMA and for
  code loaded into PSRAM. See [docs/exec.md](docs/exec.md#caches).
- **dma.resource** (`src/rom/resources/dma`): the chip's DMA engine
  (GDMA), its 5 channels handed out to one owner each; connect, start, stop, and the channels' interrupts
  through exec's servers. See [docs/dma.md](docs/dma.md).
- **expansion.library** (`src/rom/libs/expansion`): what is soldered on
  the board. It reads the board's system tag list, a ROM tag of its own,
  and hands out one `BoardPart` per part (`FindBoardPart(old, kind,
  chip)`) and the board's own facts (`SystemTags()`); drivers find their
  pins and addresses there. `C:ShowConfig` prints it. See
  [docs/expansion.md](docs/expansion.md).
- **gpio.resource** (`src/rom/resources/gpio`): who holds which pad.
  A driver takes the pads it routes (`AllocGPIO`), a second one asking is
  told whose they are; the flash's, PSRAM's, USB port's and UART0's are
  taken from the start. `C:ShowConfig` lists them. See
  [docs/gpio.md](docs/gpio.md).
- **platform.resource** (`src/rom/resources/platform`): what machine this
  is - the chip, its clocks, where the code and the stacks are, whether
  there is PSRAM. ExecBase is opaque and these are the
  kernel's facts, not exec's, so they come out through a resource. `C:Platform`
  and `s3> info` both print it, from the one place. See
  [docs/platform.md](docs/platform.md).
- **rtg.library** (`src/rom/libs/rtg`): retargetable graphics - the
  displays of this machine and the drivers that drive them. A driver joins
  a list and everything above works in boards, modes, buffers and a
  blanking; the library holds no drawing of its own, so whoever has a
  buffer writes the pixels and hands the rows on with `RefreshBitMap`.
  Configuration goes in as `RTGA_*` tags, answers come back as structures
  with their size. The drivers in the ROM: `rgb`, the 7B's RGB panel;
  `dcs`, a controller panel that keeps its own picture (the ES3C35P's
  ST77922), on `qspi`, a QSPI command bus on SPI2; `i2c`, a display's
  command bus over i2c.device; and `qemu`, the emulator's virtual
  display, which registers only where the emulator is, so the whole stack
  above a board can be looked at before anything is flashed. Each image
  carries the ones its board needs. `C:Rtg` prints what the
  machine has - drivers, boards, modes, display memory and how a stream is
  doing. See [docs/rtg.md](docs/rtg.md).
- **graphics.library** (`src/rom/libs/graphics`): the layer that draws.
  At 0.17 it has the display, the RastPort, fonts and text in two sizes of
  Pospaz, the blits - bitmap to bitmap or into a RastPort, through a mask, a
  shape stencilled in the pens, a tile repeated across a rectangle, and a
  stretch - a scroll of a RastPort within itself, which reads through the
  clip so that a window moves its own pixels and not the display's, and the
  drawing primitives -
  pixels, runs, rectangles filled and outlined, lines, polygons, circles,
  ellipses and arcs, and the area calls that fill a shape of any of them,
  several at once so that one inside another is a hole - plus an erase that
  paints an area the way that RastPort's empty parts are painted, which for
  a window is its own ground and for anything else its background pen, so a
  picture taken off something leaves what was behind it - with the
  draw modes (JAM1, JAM2, COMPLEMENT,
  INVERSVID) applying to text as much as to lines, patterned lines, and
  bold, italic and underlined drawn rather than stored. Plus the tag calls that read and change a
  RastPort, bitmaps of one's own with a blit between them, regions to clip
  any shape, and an answer to what went wrong, kept in the RastPort so two
  tasks drawing at once cannot overwrite each other's. A
  program opens it and asks for a RastPort - with no tags, one on the
  display - and never touches rtg.library to do so, because this library
  opens rtg itself and finds the display for it. The RastPort is opaque and
  is reached through `RPTAG_` tags; a pen is `0xAARRGGBB`, packed into the
  surface's format once when it is set, and its alpha decides whether a
  board's engine can be handed the work - an engine takes one colour word
  and has nowhere to put a coverage, so anything less is composed in
  software. Every drawing call goes through one clip that hands back the
  pieces it may write - each with the surface it goes to and an offset, so
  that a window's pixels can land somewhere other than the display without
  a single drawing call knowing. `RPTAG_Bounds` is how a program
  asks how big a display is. `C:Gfx FILL` puts a pattern on it,
  `C:Gfx BLIT` keeps part of it off-screen and stamps it back, which is
  SMART_REFRESH's shape, and `C:Gfx LINES` fans lines past every edge to
  show the clipping; `C:Plasma` is a window with a picture of colour
  numbers put down through a turning table of 256 pens
  (`WriteLUTPixelArray`) and a bar of rgba32 pixels converted to the
  display (`WritePixelArray`), with menus for its palette and speed; `zig build qemu-display` shows them. `C:Anim` is all
  of the primitives in one moving picture, double-buffered, and `C:Lines`
  is the same picture's trail of lines drawn into an intuition window - what
  a program does differently when it draws into one; its window is fitted
  to a screen smaller than it asks for, and the startup-sequence starts it. See [docs/graphics.md](docs/graphics.md).
- **layers.library** (`src/rom/libs/layers`): windows that share one display
  buffer. A layer is a rectangle of the display that something draws into
  without having to know what is in front of it - and it draws at **its own
  corner**, `(0,0)` meaning its top-left wherever it happens to be. It never
  draws anything itself: it works out which pieces of each layer are visible
  and hands the answer to graphics.library as a list of clip targets, so
  graphics.library has no notion of a window and this library none of a
  pixel. The geometry is region arithmetic and nothing more - front to back,
  each layer loses what the ones in front have claimed. Compositing was
  rejected for this machine: a buffer per window would make every visible
  pixel a PSRAM read and a write on top of the copy already feeding the
  panel at 39 MB/s out of that same memory. `LAYERSIMPLE` is built, with
  damage and `BeginUpdate`/`EndUpdate` so a program can draw all of itself
  and touch only what was uncovered. `C:Gfx LAYERS` shows three of them.
  See [docs/layers.md](docs/layers.md).
- **intuition.library** (`src/rom/libs/intuition`): screens and windows,
  and the object system they will be built from - so far only that. Classes
  (`MakeClass`, `AddClass`, `FreeClass`, public by name or private by
  pointer), objects (`NewObjectTagList`, `DisposeObject`, `SetAttrsTagList`,
  `GetAttr`) and messages (`SendMessage`, `SendSuperMessage`,
  `CoerceMessage`), each class's dispatcher a utility Hook that passes on
  what it does not handle. rootclass allocates objects; imageclass is a box
  with a one-bit shape drawn in two ARGB pens, drawn with `DrawImage`;
  icclass passes what changed on to a target through a tag map, and
  modelclass to its members as well. Screens: one to a display, opaque and
  read with `GetScreenAttrs`, twelve ARGB pens in a `DrawInfo`, a title bar
  that is a layer, and the default "Workbench" screen opened the first
  time `LockPubScreen(null)` asks for it. Windows: layers of a screen with
  a border made of frameiclass and sysiclass images, moved, sized and
  re-ordered by call, one active, smart or simple refresh, and a message
  port (IDCMP) for refresh, size, move and activation. Input comes from
  input.device, where intuition is a handler from the first screen on: a
  click activates a window, the drag bar and size gadget move and size it,
  the depth gadget reorders, close sends `IDCMP_CLOSEWINDOW`, and the
  active window gets `IDCMP_RAWKEY`, `MOUSEBUTTONS`, `MOUSEMOVE` and
  `INTUITICKS`. Gadgets: gadgetclass and buttongclass (a labelled button
  is one object, pressed, followed off and on, let go), put in a window
  with `AddGList` or `WA_Gadgets`, `IDCMP_GADGETDOWN`/`GADGETUP`, and
  `ICA_TARGET` reaching the window as `IDCMP_IDCMPUPDATE`. The rest of the
  classes are there too: **propgclass**, a slider said either in things
  (how many there are, how many fit, which is first) or in fractions of
  its container, dragged or paged and telling its target where it stands;
  **strgclass**, a line of text with a cursor, the edit keys read through
  keymap.library, an undo and the text as a number; **groupgclass**, a
  gadget made of gadgets, which places its members in itself and routes
  what the window sends to whichever one was hit; **frbuttonclass**, a
  button that always wears a frame; and the two image classes
  **fillrectclass** (a box filled with a pattern, or one colour) and
  **itexticlass** (words).
  A window is opened with the whole tag vocabulary: its own two pens, its
  flags in one word, which border the size gadget takes its room from, a
  zoom gadget that flips it to another box and back, its own backfill hook,
  a bitmap of its own to keep what is covered, and **GimmeZeroZero** - the
  part inside the border as a layer of its own, so the program's (0,0) is
  that corner and nothing it draws can reach the border. Tab moves the
  keyboard from one gadget to the next, and a window slower than the
  pointer drops moves rather than growing its port without bound.
  `C:Intuition` shows the screen, `C:Intuition WINDOWS` three windows,
  `C:Intuition GADGETS` a window of buttons, `C:Intuition SLIDERS` two
  sliders, a line to type in and a group of buttons, and `C:Intuition TEXT`
  text and a box drawn from a description (`PrintIText`, `DrawBorder`,
  `IntuiTextLength`); `LockIBase` holds the screens and windows still for a
  reader, and a window's titles and limits change while it is open, it zips
  to its other box, and a gadget is turned off and on. The easy requester
  asks a question in a window of buttons (`C:Intuition REQUEST`).
  **Menus**: a window's strip shown in the screen's bar while the menu
  button is held, its panels and subitems as layers over everything,
  checkmarks that toggle or rule each other out, right-Amiga shortcuts,
  several picks in one go with the select button, `IDCMP_MENUVERIFY`
  before anything is shown, `IDCMP_MENUHELP` on the Help key, and one
  window's menus lent to another (`C:Intuition MENUS`). **Requesters**
  inside a window: a box of gadgets over its window that takes its input
  until an end gadget or `EndRequest` takes it down, stacked, moving and
  sizing with the window, and one a double-click of the menu button puts
  up; and the two-button requester from IntuiTexts
  (`C:Intuition REQUESTER`). A window that asks for `IDCMP_SIZEVERIFY` is
  asked before the user sizes or zooms it. What is still
  wrong or missing is numbered in
  [docs/intuition-audit.md](docs/intuition-audit.md). See
  [docs/intuition.md](docs/intuition.md).
- **Interrupt source names** in the SDK: `sdk/hardware/intbits.zig`
  (`INTB_UART0`, `INTB_DMA_IN_CH0`, …).
- **Panic**: a Zig panic goes to exec (`exec.kernelPanic`): the message
  with `kprintf`, then a dead-end Alert, the Guru Meditation, which halts.
- **Nothing is drawn before rtg.library has a board.** Until then the
  kernel speaks through exec's raw port - the boot notes, and a Guru
  Meditation, which needs nothing that may have broken. graphics.library's
  init (`src/rom/libs/graphics/display/`) brings the board's panel up
  through rtg.library at cold start and shows its first picture, black.
- **Shell** (`src/rom/libs/exec/_shell/`, a file per command in `cmds/`, on
  serial.device's unit 0 or usbserial.device, formatted by exec's
  `RawDoFmt`): `help info uptime memlist memtrace peek poke sleep
  libs devs constop ser residents resources tdelay tabort systime eclock date
  ints trigger cause alert trap tasks ports sems doslist segments clis
  newshell disk sd format rdb screen syscall fault panic wdt cache dma reboot`.
  It keeps what a kernel needs to look at itself and what has to work before
  there is a disk to load a command from. What a program would do belongs on
  the disk: the machine's own shell comes up in a window on the display, and
  `newshell [console]` starts another - on this terminal, or wherever it is
  told to. The commands in `C:` (below) take it from there.

## Boards

One kernel image is built per board, `-Dboard=<name>` picking
`src/boards/<name>/`: the board's system tag list (`system.zig`, what is
soldered on it and how it is wired) and the ROM tags its ROM carries
(`romtags.zig`). Drivers ask expansion.library for their part and carry
no board facts, so the ROM holds the driver for a part only where the part
is there. `C:ShowConfig` lists it all. The emulator is a board of its
own, `qemu`, which the `qemu*` steps always build and run.

| `-Dboard=` | Board | State |
|------------|-------|-------|
| `waveshare_7b` (default) | Waveshare ESP32-S3-Touch-LCD-7B: 16 MB flash, 8 MB PSRAM, 7" 1024x600 RGB panel, GT911 touch, IO expander | runs on the board |
| `qemu` | Espressif QEMU's ESP32-S3: 16 MB flash, 8 MB PSRAM, its virtual display at 1024x600 with the window's keys and pointer, console on UART0 | the `qemu*` steps' board; 1024x600 needs the QEMU from `scripts/build-qemu.sh` |
| `es3c35p` | LCDwiki ES3C35P: 16 MB flash, 8 MB PSRAM, 3.5" 320x480 ST77922 panel on QSPI with its own touch (I2C 0x55), ES8311 codec (I2C 0x18) with amplifier, speaker and microphone, 4-bit SDIO card slot, WS2812 LED, battery sense | described in full; the panel runs on the board (`qspi` and `dcs`), as a 480x320 landscape screen turned as it is sent, and so do its touch and its speaker |

### Waveshare ESP32-S3-Touch-LCD-7B

| Part | Details (from Waveshare's demo code) |
|------|--------------------------------------|
| Panel | RGB565 over the LCD_CAM RGB interface, 30 MHz pixel clock |
| RGB pins | VSYNC 3, HSYNC 46, DE 5, PCLK 7; B3–B7 14 38 18 17 10; G2–G7 39 0 45 48 47 21; R3–R7 1 2 42 41 40 |
| I2C | SDA 8, SCL 9 |
| IO expander | I2C address 0x24, a register file: `02` pin mode (1 = output), `03` pin output, `04` pin input, `05` backlight (0-255, **inverted**: 0 is full brightness and 255 is dark), `06` ADC (16-bit). The schematic's nets: `EXIO_PWM` is the backlight (through TP3 and R52 to `BL_EN`), `EXIO2` is `DISP`, `EXIO_ADC` is an analogue sense. So the backlight is that register, not a pin |
| Touch | GT911 on the same I2C bus |

In QEMU the display works through Espressif's virtual RGB device. On the real
board the `screen` module brings the panel up at cold start: the IO expander
lets it out of reset and lights it, a 1.2 MB framebuffer goes in PSRAM, two
GDMA channels keep LCD_CAM fed from it, and the picture stays up with nothing
running - writing to the framebuffer is all that changing it takes.

**PSRAM cannot feed it.** Measured on this board with the panel streaming
straight from PSRAM and nothing else running at all, the DMA fell behind by
66 pixels a frame - about two microseconds of stall, which is what the
memory's own refresh costs - and by half as much again with the CPU working.
The pixel FIFO holds about a microsecond, so each stall is pixels the panel
never gets, and every pixel after it arrives late: the picture sits sideways
with its right-hand end wrapped round to the left, and slips further every
frame. No amount of bandwidth helps. The panel needs a stream with no gaps in
it, and PSRAM has gaps.

So the panel is fed from **two ten-line buffers in internal memory**, which has
none, and a **second DMA channel copies the picture into them** ahead of the
panel reading them (`src/rom/libs/rtg_driver/rgbboard/panel.zig`). The panel's channel runs a
ring over the two buffers; when it finishes one it raises `DMAINTF_OUT_EOF`,
and that interrupt starts the copy of the next ten lines into the buffer just
freed - sixty times a frame. Each copy has a buffer's time, 460 µs, and takes
about half of it; under a CPU hammering PSRAM three copies in ninety thousand
have needed longer, and the one in flight is waited for rather than started
over. The copy is the DMA's and not the CPU's because the panel needs 39 MB/s
continuously and this machine's CPU copies memory at about half that: it
would leave nothing for anything else.

A frame is exactly sixty bufferfuls, so the copy and the panel stay in step
by construction, and measurably do. They are put in step once, at the first
blanking after the start (`INTB_LCD_CAM`), because `lcd_start` begins a frame
wherever the timing generator has got to: the generator is stopped, the DMA
stopped and reset, the pixel FIFO emptied, both buffers filled with the top
of the frame, and then the chain and the generator started together. That
sequence lives in internal RAM - run from flash, an instruction the cache did
not hold cost a read of the flash chip in the middle of it, and the panel's
sync signals stood still for 43 of a line's 46 microseconds.

The data cache is **64 KB with 64-byte lines** (`src/arch/esp32s3/psram.zig`) and
the framebuffer is aligned to a line: the DMA reaches PSRAM through the cache
controller and fetches a line at a time, and octal PSRAM spends a fixed
turnaround on every access whatever it carries, so 32-byte lines spend half
the bus on overhead.

`s3> screen` prints what the panel is doing: frames, frames that ran long,
bufferfuls copied and how many were late, and whether the copy is still in
step with the frame. `s3> screen ruler` draws a numbered scale across the
glass and `s3> screen shift <pixels>` moves the active area along the line,
taken at the next blanking: between them the picture's position can be
measured and corrected on the board rather than guessed at.

## Memory layout

For the full address map (peripherals, ROM, cache windows, flash), see
[docs/memory-map.md](docs/memory-map.md).

The board's module is an ESP32-S3-WROOM-1-N16R8. It has 512 KiB internal
SRAM, 384 KiB ROM, 16 MiB quad flash and 8 MiB octal PSRAM.

Internal SRAM is one memory seen through two buses: `0x4037_8000` on the
instruction bus is the same byte as `0x3FC8_8000` on the data bus. Code comes
first, and the data follows it on the data bus.

| Range | Contents |
|-------|----------|
| `0x40370000 – 0x40377FFF` | ICache (not used by the kernel) |
| `0x40378000 – ...` | vectors and code (about 45 KiB) |
| data-bus alias of the code end – `0x3FCE5700` | rodata, data, bss, then exec's "internal memory" |
| `0x3FCE5700 – 0x3FCE9700` | 16 KiB kernel stack |
| `0x3FCE9710 – 0x3FCEB710` | ROM boot stack, reclaimed as "internal memory (rom stack)" |
| `0x3FCED710 – 0x3FCEFFFF` | ROM data and bss (left alone: the ROM functions we call use it) |
| `0x3FCF0000 – 0x3FCFFFFF` | data cache memory, all 64 KiB of it; what a smaller cache left would be "internal memory (cache spare)" |
| `0x3FCF8000 – 0x3FCFFFFF` | 32 KiB data cache |
| `0x3C000000 – 0x3C7FFFFF` | 8 MiB PSRAM through the data cache (MMU entries 0–127) |
| flash `0x000000 – 0x1FFFFF` | kernel image (about 990 KiB), with room to grow |
| flash `0x200000 – 0xFFFFFF` | flash.device's unit 0: 14 MiB of disk (`DH0:`), mapped at `0x3CC00000`; its start is `-Ddisk-offset` |

The PSRAM runs at 80 MHz. It skips ESP-IDF's timing calibration and uses the
default timing point IDF falls back to. If the memory test fails on a board,
that calibration is the next thing to add.

QEMU runs with `-m 8M` and octal PSRAM, like the board. Its PSRAM needs no
setup, so QEMU confirms the mapping and exec's external memory but not the real
chip setup.

## Toolchain

Use the `./zig` wrapper in the project root, not the `zig` on your `PATH`.
It runs the Espressif Zig build from `toolchain/zig/` (git-ignored), and
downloads it there on first use:

```sh
./zig version      # 0.16.0
```

You also need `esptool` (v5) and, optionally, Espressif's
`qemu-system-xtensa`. ESP-IDF's `eim` installs it under
`~/.espressif/tools/qemu-xtensa/`.

## What is not done

[LATER.md](LATER.md) holds the work that is deferred and the reason it can
wait - what the safety checks cost, the rules in
[docs/codex.md](docs/codex.md) the tree has not caught up with, and the
documentation passes still owed. What a single module lacks is in that
module's own "Not done yet" in `docs/`.

## Build, run, flash

```sh
./zig build                      # zig-out/bin/{kernel,kernel.bin,flash.bin}
./zig build test                 # unit tests on the host, SDK up to date, every board compiles
./zig build -Dboard=es3c35p      # any step, for the 3.5" board (default waveshare_7b)
./zig build -Ddisk-offset=2048   # where the flash disk starts, in KiB (the default)
./zig build fd                   # regenerate the SDK's interfaces from sdk/fd
./zig build qemu                 # serial console only
./zig build qemu-display         # plus the board's screen in an SDL window
./zig build qemu-disk            # on an image whose disk keeps what is written
./zig build flash -Dport=/dev/ttyACM0
./zig build flash-disk -Dport=/dev/ttyACM0   # a fresh file system on the disk
./zig build flash-all -Dport=/dev/ttyACM0    # both: the kernel and a fresh disk
```

`sdk/` and `src/disk/` are packages the build takes as `.path`
dependencies (`build.zig.zon`); each also builds on its own
(`cd sdk && ../zig build test`, `cd src/disk && ../../zig build`).

After linking, `tools/ressize.zig` (built for the host) writes every ROM
tag's module size into the kernel ELF, for the shell's `residents`. Then
`esptool` makes the image from that ELF.

Stock Espressif QEMU runs the S3 CPU at a fixed 40 MHz and ignores the clock
registers. Its virtual display also stops at 800x600 and it has no window.
`scripts/build-qemu.sh` builds the same QEMU release into `toolchain/qemu/`
with three changes: the S3 core hardwired to 240 MHz, the display allowed up
to 1024 pixels wide, and SDL enabled for the window. The build takes a few
minutes, and the ROM boot then runs at 240 MHz too.

`zig build qemu` uses `toolchain/qemu/bin/qemu-system-xtensa` if it exists.
Otherwise it looks on `PATH`, then takes the newest version under
`~/.espressif/tools/qemu-xtensa/`. Override it with
`-Dqemu=/path/to/qemu-system-xtensa`.

In QEMU, quit by pressing `Ctrl-A`, releasing, then pressing `X`. On hardware, open the serial port at 115200
baud, e.g. `tio /dev/ttyACM0`.

`zig build flash` writes the kernel to offset `0x0`, which replaces the
ESP-IDF bootloader on the board. Flashing any IDF app brings the bootloader
back. It writes only the image, which the build keeps below
`-Ddisk-offset`, so flash.device's disk area from `0x200000` on survives a
reflash.
`zig build flash-disk` writes a fresh file system there, which is what puts
one on the board the first time - and what wipes it.

**`disk/` in the root of the tree goes on the image as it stands**, at the
same paths, directories and all: `disk/c/dm.seg` is `C:dm`,
`disk/dm/GRAPHICS.DAT` is `SYS:dm/GRAPHICS.DAT`. It is where a program
built in another repository is dropped to have it on the machine, and a
`.seg` suffix comes off, because that is the extension a load file is
built with and not the name a command is called by. A name beginning
with a dot stays behind, and so does `disk/README.md`, so the directory
can carry its own notes without them landing on the disk. For a file that
is to stay outside this tree altogether there
is `-Dextra=<path on the disk>=<file on the host>`, given once per file;
both are applied after the tree's own files, so either may replace one.

`zig build qemu` runs QEMU with `-snapshot`, so nothing the kernel writes to
the flash is kept. `zig build qemu-disk` runs without it, on
`zig-out/bin/qemu-flash.bin`: it puts the current kernel at offset `0x0` of
that image and leaves the disk alone, as flashing the board does (a fresh
image gets the built one), so the disk keeps what is written to it from one
boot to the next.

Optimize modes: `ReleaseSafe` (default) and `ReleaseFast` work. `ReleaseSmall`
fails to link because of undefined `compiler_rt.int.*` symbols in this
toolchain build. `Debug` does not fit into IRAM.

Symbolize a PC from a crash dump:

```sh
~/.espressif/tools/xtensa-esp-elf/*/xtensa-esp-elf/bin/xtensa-esp32s3-elf-addr2line -e zig-out/bin/kernel 0x4037b8e2
```

## Example session (QEMU)

```
PowerOS kernel for ESP32-S3, built with Zig 0.16.0 (ReleaseSafe)
[   0.026019] info(kernel): vector table at 0x40378000
[   0.026554] info(kernel): heap 145 KiB
[   0.036974] info(kernel): cpu clock 240 MHz, tick 100 Hz
[   0.037959] info(kernel): interrupts enabled
s3> syscall 0 41
syscall(0, 41) = 42
s3> fault
*** FATAL EXCEPTION 28 (load_prohibited)
  PC       0x4037b8e2  PS  0x00060d30  SAR    0x00000008
  EXCVADDR 0x00000010  ...
```

## Next steps

- Verify the 240 MHz setup on hardware, and read the calibrated core voltage
  from eFuse like ESP-IDF does.
- Tasks: context switching needs a full window spill on every switch.
- Start the APP CPU (core 1).

## License

Copyright (c) 2026 Claus Herrmann and the PowerOS contributors.

- **The system** - the kernel, the ROM's modules, the boards and the tools
  (everything outside `sdk/` and `src/disk/`) - is under the
  [Mozilla Public License 2.0](LICENSE): a changed file stays under it and
  its source is published with what ships it; new files of one's own - a
  driver, a board - may be under any license.
- **The SDK** (`sdk/`) and **the disk's programs** (`src/disk/`) are under
  the [MIT license](sdk/LICENSE), so a program built against the SDK, or
  started from one of the programs, is its author's to license as they
  like.
- `scripts/qemu/esp_rgb_input.patch` changes QEMU and is under QEMU's
  license, GPL-2.0-or-later.

Every source file says which it is under in its first line
(`SPDX-License-Identifier`).
