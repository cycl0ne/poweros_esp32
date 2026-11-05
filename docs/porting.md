# Porting PowerOS to a new machine

PowerOS runs on five CPU architectures, each under the firmware that
starts it: Xtensa on the ESP32-S3, 32-bit RISC-V on the ESP32-P4, 64-bit
RISC-V under SBI firmware, AArch64 under PSCI firmware, and x86-64 under
UEFI firmware. Eleven boards sit on those five.

This is the checklist those ports were made against: every place a new
machine has to be named, in the order it comes up, with what each of the
five does there. Nothing here is a guess - each item is a file in the
tree, and the greps that find them are given so the list can be checked
against the code rather than trusted.

**Two kinds of port.** A **chip** is a CPU and the firmware below it
(`sdk/hardware/hardware.zig`'s `Chip`); a **board** is a machine built on
one (`build.zig`'s `Board`). Adding a board to a chip that exists is
sections 8 and 9 alone, and is usually a day: a tag list, a ROM tag list,
and whatever its parts need that no other board has. Adding a chip is all
of it.

**What a chip costs.** The parts that are a chip's own, as they stand:

| Chip | Firmware below | `src/arch/<chip>/` | `sdk/hardware/<chip>/` | Kernel root |
|---|---|---|---|---|
| `esp32s3` | the chip's ROM loader | 3305 lines, 20 files | 2436 lines, 21 files | `src/main.zig`, 216 |
| `esp32p4` | the chip's ROM loader | 3492, 21 | 3463, 22 | `src/main_esp32p4.zig`, 242 |
| `rv64sbi` | OpenSBI, started by U-Boot's `booti` | 2265, 15 | 2334, 21 | `src/main_rv64sbi.zig`, 284 |
| `a64psci` | PSCI firmware, a device tree | 3369, 17 | 854, 12 | `src/main_a64psci.zig`, 306 |
| `x64uefi` | UEFI, with a stub of ours (`src/boot/uefi/`, 683) | 3490, 18 | 1162, 11 | `src/main_x64uefi.zig`, 555 |

The ESPs' hardware folders are large because those chips' own peripherals
live there - the GDMA, the I2C, the SPI, the 2D engine. A machine whose
peripherals are on PCI Express needs almost none of that: the x86-64
chip's folder is eleven files.

**Why it is this small.** exec never reaches into `src/arch/`, so its host
tests compile where no such CPU exists. A chip is reached through four
interfaces the kernel fills from there - the task switch
(`exec.TaskHardware`), the interrupt controller
(`exec.InterruptHardware`), the Guru (`exec.AlertFn`) and, optionally,
the debugger (`exec.DebugHardware`) - and two exec fills itself by the
chip's name, the raw console (`rawio/`) and the caches (`cache/`). Each
has a working default, so a chip that supplies none still compiles and
runs the host tests. Everything above exec - dos,
intuition, graphics, layers, rtg, motion, the handlers, the shell, the
desktop, and everything on the disk, which is over three hundred modules
and programs - is written against the SDK and needs only a build for the
new target.

---

## 1. The chip exists

- [ ] `sdk/hardware/hardware.zig`: the name into `Chip`, and an arm in the
      `builtin.cpu.arch` switch that picks it. **Mind the host guard**: an
      architecture the build host also is must ask
      `builtin.os.tag == .freestanding`, or every host test stops seeing
      the ESP32-S3's hardware, which is what they are written against.
      This matters most for x86-64 and AArch64, which are what this
      system is built on.
- [ ] `sdk/libs/dos/loadfile.zig`: `native_machine` and
      `native_word_size`, with the same `freestanding` question.
- [ ] `sdk/hardware/<chip>/`, the nine files every chip has:
      `hardware.zig` (what the folder offers), `cpu.zig`, `intbits.zig`
      (the interrupt sources by number), `map.zig` (base addresses),
      `mmio.zig` (a register by its address), `rng.zig`, `system.zig`
      (bus clocks and resets), `systimer.zig`, `uart.zig`. A machine
      whose disk comes in as an image adds `ramdisk.zig`.
- [ ] `sdk/hardware/barrier.zig`: the CPU's fences.
- [ ] `sdk/program_<chip>.ld`, and `sdk/build.zig`'s target query,
      `programTargetQuery` and `addProgram`.

**The console is usually nearly free.** `sdk/hardware/rv64sbi/uart.zig`
drives a 16550, `a64psci/uart.zig` a PL011, and the board tag list
carries `SYSTAG_ConsoleShift` and `SYSTAG_ConsoleWide` for the register
layouts those parts come in. The x86-64 console is the same 16550 in the
I/O port space, so only the accessor changed. exec's `RawIOHardware` is
three functions.

## 2. The handover from firmware

What the firmware leaves has to be read before exec exists, and turned
into the one structure the kernel root reads:

- [ ] Memory ranges and reserved ranges, the disk image's address and
      size, the console, and the cores.
- [ ] Where it comes from: the ESPs read their own ROM's state;
      `src/arch/rv64sbi/fdt.zig` and `src/arch/a64psci/fdt.zig` read a
      device tree; `sdk/hardware/acpi.zig` reads a firmware's description
      tables, which the kernel root asks for by the root pointer the stub
      found. That stub, `src/boot/uefi/`, is a PE32+ `BOOTX64.EFI` of
      ours that asks the firmware for its memory map, the framebuffer and
      that pointer, loads the kernel and the disk image, exits boot
      services and jumps in with `handover.zig`'s structure. A firmware
      that stays in memory can still be called afterwards, which is how
      that machine restarts and turns off
      (`src/arch/x64uefi/firmware.zig`).
- [ ] A machine whose disk is an image in RAM wants nothing else written:
      `hardware.ramdisk` and `flash.device`'s `ramdisk/` serve it, so the
      shell comes up before any storage driver exists.

## 3. exec's hardware: `src/arch/<chip>/`

Every chip has these, and each stands for one of exec's interfaces:

- [ ] `context.zig` - **`TaskHardware`**, seven members: `init_context`,
      `switch_now` (enter the kernel from task level), `idle`,
      `push_exception`, `leave_exception`, `call_on_stack` (NewStackRun's
      part), and `leaving` - a word per core holding the task the
      dispatcher has just switched away from, which the CPU clears once
      the core is off that task's stack.
- [ ] `start.S` and `trap.zig` - the entry, the exception vectors and the
      exit. The contract is the same on every chip:
      `<arch>_exception(frame)` answers the context to resume, the
      assembler compares it with its own stack pointer, moves if it
      differs, and clears the `leaving` word afterwards. Task level asks
      for a switch through a syscall or trap of its own - and mind that
      the firmware may own the obvious one: `ecall` is the SBI's, so that
      port enters itself with an `ebreak` and a magic word.
- [ ] The interrupt controller - **`InterruptHardware`**:
      `enable_source`, `disable_source`, `disable`, `restore`,
      `cause_softint` are required; `hold_others`, `release_others`,
      `park_if_asked` and `poke_core` are what the other cores need and
      have no-op defaults. One file per kind:
      `intmatrix.zig` (the ESPs' matrix), `plic.zig`, `gic.zig`,
      `apic.zig`.
- [ ] `timer.zig` and `clock.zig` - the tick, uptime, and core 0's driver
      alarms. `src/rom/devs/timer/` holds both halves already:
      `systimer_alarms.zig` for a chip with alarm comparators of its own,
      and `comparator_alarms.zig` for one comparator shared between them,
      which is what the three 64-bit machines use.
- [ ] `ram.zig` and `layout.zig` - the memory list, split where DMA can
      and cannot reach.
- [ ] `alert.zig` - **`AlertFn`**: a Guru with that CPU's registers.
- [ ] `cpu.zig`, `cpu1.zig`, `rendezvous.zig` - the cores: how many there
      are, how one is started, and how they meet.
- [ ] `psram.zig` - a stub where there is none, so platform.resource and
      the shell compile.
- [ ] A linker script: `src/arch/<chip>/kernel.ld` for four of the five,
      and the tree's own `kernel.ld` for the ESP32-S3, whose code runs
      from flash.
- [ ] Optional: `debugexc.zig` - **`DebugHardware`** (`stop`, `go`,
      `halt`, `reboot`, `readable`, `step`). `rv64sbi` and `x64uefi` ship
      without one and the ROM debugger degrades by itself.
- [ ] `mmu.zig` where the map wants refining (address 0 unmapped, the
      kernel's code read-only). `rv64sbi` never touches `satp` and runs
      on the firmware's mapping, so a port can start that way.
- [ ] `src/arch/arch.zig`: a fifth arm in each of its **nine** switches
      (`clock`, `psram`, `cpu`, `cpu1`, `intmatrix`, `layout`,
      `rendezvous`, `timer`, `trap`), and one in `src/bootstrap.zig`.

## 4. The kernel root

- [ ] `src/main_<chip>.zig`: `takeBoard()` from the handover, and the
      ROM's base module list - timer, flash, serial, input, keyboard,
      mouse, keymap, console, utility, expansion, dos, ramlib, the
      nil/ram/con/pipe handlers, the file system, the Shell, platform,
      battmem, rtg, graphics, layers, intuition, motion. The list lives
      in the kernel root rather than in the board.
- [ ] `tools/boardcheck.zig`: the new root into both allowlists, or the
      check flags its `src/boards/` import. The check is what keeps
      modules from importing a board.

## 5. The per-chip places inside exec and the ROM

These are the files that ask the chip's name. The list is what
`grep -rln 'hardware.chip' src sdk --include='*.zig'` answers, and it is
worth running rather than trusting - it grows.

Inside exec, where the code is the CPU's own:

- [ ] `exec_base.zig` - `max_cores`, and `coreId()` per architecture.
- [ ] `interrupt/_interrupt.zig` - `mask`/`unmask`, the only CPU state
      exec touches itself.
- [ ] `cache/_cache.zig` - and a coherent machine is the easy case: this
      becomes fences and a note that a writeback drops, as the RISC-V and
      x86-64 arms are.
- [ ] `rawio/_rawio.zig`, `debug/_debug.zig` (the backtrace walks the
      frame-pointer chain), and the shell's `fault.zig` and `trap.zig` -
      the illegal instruction, and **how far a return address sits past
      its call**, which is the one place needing real care on a
      variable-length instruction set.
- [ ] `resources/platform/platform.zig` - the chip's name and its core's.

In the ROM's devices and resources - each of these already switches on
the chip, so each is a place to add an arm or a `<chip>/` subfolder:

| Where | What it is |
|---|---|
| `devs/timer/timer.zig` | which counter the timer reads |
| `devs/serial/unit.zig` | the UART a unit drives |
| `devs/flash/` | `esp32s3/`, `esp32p4/`, `ramdisk/` - one per medium the kernel's own storage sits on |
| `devs/i2c/hw.zig` | the chip's I2C controllers and their matrix signals. It is a `@compileError` for a chip without one, which is the honest shape: the board then lists no I2C part and nothing opens the device |
| `devs/keyboard/`, `devs/mouse/` | whether the emulator's own input is there, which only the chip our emulator runs has. A real machine's keyboard and mouse come from USB and need nothing here |
| `resources/battclock/`, `resources/battmem/` | the clock and the few bytes that survive a reset: an RTC in the chip, one on the board, one behind firmware, or one in the port space |
| `resources/dma/`, `resources/gpio/`, `resources/usbport/` | `esp32s3/` and `esp32p4/` subfolders; a machine without these parts needs none |
| `resources/jpeg/`, `resources/videodec/` | the engine a chip may have, else `none` |
| `resources/power/`, `resources/thermal/`, `resources/watchdog/` | turning the machine off, its temperature and fan, the watchdog |
| `libs/rta_driver/i2s/` | `esp32s3/`, `esp32p4/` - a sound path the chip has |
| `libs/rtg_driver/fbboard/` | `ramfb.zig`, `virtio.zig`, `virtiopci.zig`, `jh7110.zig`, `bcm2712.zig`, `uefi.zig` - one file per kind of framebuffer |

**`exec/memory/words.zig` needs nothing** where unaligned loads are fast,
and the SDK's 4-byte alignment cap on extern structs is enforced only on
Xtensa.

## 6. The loader

- [ ] `sdk/tools/elf2seg/elf2seg.zig` keeps a relocation classifier per
      architecture (`EM_XTENSA`, `EM_RISCV`, `EM_AARCH64`, `EM_X86_64`):
      which relocation is an address word to fix up, which is already
      resolved inside the program, and which is refused with a message
      that names the code model to build with.
- [ ] `segmentAlign` (`sdk/libs/dos/loadfile.zig`): 64 bytes is the
      default; AArch64 needs 4096 because an ADRP pair only survives
      whole-page moves.
- [ ] The negative tests in `sdk/build.zig`, which check that a wrongly
      built program is refused with the right message.

## 7. The build

`build.zig` is deliberately exhaustive: the switches below refuse to
compile until the new chip has an arm, which is the list you want.

- [ ] `chipOf` - the board to its chip - and the name into `Board`.
- [ ] The functions that switch: `iconSize`, `bootFiles`,
      `refusePrivateTree`, `addBoardImage`, `ramDiskName`,
      `addBootPackage`, `addBoardArchive`, `boardConsole`, `addImage`,
      `addKernel` (its target, `red_zone`, the code model, the assembly
      file and the linker script), and some forty places in `build` -
      `most_cores`, the kernel target, the disk size, the RAM-disk
      directories, the image dispatch, `package`/`serve`, the storage and
      boot steps, `release`, the test step's targets and the board disk.
- [ ] The **fixed-size arrays**, which no compiler catches - `addImage`'s
      `[5]Chip` among them. Worth widening in one pass before anything
      else.
- [ ] A run step beside `qemu`, `emu`, `virt`, `virt64` and `q35`, so the
      machine can be exercised daily.
- [ ] `src/disk/build.zig`'s `builtFor`: which of the other chips'
      drivers this one does **not** get. It is written as a subtraction,
      so a new chip gets everything unless it is named - which is the
      right default and the reason `xhci.device`, `nvme.device`,
      `pci.library`, `install` and `update` came free on the newest two
      machines.
- [ ] The per-chip file lists beside it (`mac_files`, `p4_files`,
      `a64_files`): files only one machine's disk carries.

## 8. The board

- [ ] `src/boards/<board>/system.zig` - the board's system tag list, a
      ROM tag: its name, its RAM, the console and its register layout,
      the interrupt controller's bases, and a **part** per piece of
      hardware (`PARTKIND_PANEL`, `_USB`, `_PCI`, `_NET`, `_SDSLOT`,
      `_TOUCH`, `_CODEC`, `_RTC`, `_RNG`, `_DMA`, `_CRYPTO`, `_JPEG`,
      `_VIDEODEC`, `_THERMAL`, `_FAN`, `_GPU`, `_POWER`, ... - 30 kinds,
      121 tags). Modules ask expansion.library for these
      (`FindBoardPart`, `SystemTags`) and carry no board facts; the
      kernel reads the same list at compile time.
- [ ] `src/boards/<board>/romtags.zig` - the drivers this board's ROM
      links, which is the extras only: the display driver, `pci.library`,
      `nvme.device`, the file system, the sound sinks.
- [ ] `SYSTAG_Cores` 0 means "ask the machine", and then the same image
      runs on whatever it is started on. Never hardcode a core count: the
      firmware's tables say how many there are and the per-core state is
      allocated to fit.

## 9. The parts a machine has, and what drives them

### The order to want them

Each line is a stage that can be reached and shown before the next is
started.

| Stage | What drives it | What exists |
|---|---|---|
| Console | exec's raw port, then `serial.device` | 16550, PL011, the ESPs' UART and USB Serial/JTAG |
| Tick, tasks, the shell on the line | sections 3 and 4 | - |
| The disk | `flash.device` | the ESPs' flash, and an image in RAM |
| Programs | section 6 | - |
| A display | `rtg.library` and a driver | `fbboard` (a framebuffer someone else set up, virtio over MMIO and over PCI, the JH7110's DC8200, the BCM2712's HVS, the firmware's own), `rgbboard`, `dsiboard`, `dcsboard`. `fakeboard` is the one to read first: it exists for the host tests and is written the way a real driver is, with nothing in the module's own image |
| Keyboard and mouse | `xhci.device` + `usb.library` + `hid.device` | **nothing to write** where the machine's USB is xHCI: the controller is found by PCI class |
| A system disk | `pci.library` + `nvme.device`, or `sdcard.device` | the generic ECAM host is 18 lines; `nvme.device` claims its PCI class |
| Network | one of `networks/` | `emac` (three machines' MACs), `intelnet` (Intel's controllers on PCI, found by their PCI IDs), `openeth`, `cyw43455`, `esp32s3wifi`, `aic8800`, and `usb/ecm.device` for any adapter |
| Sound | `rta.library` + a sink, `audio.device` | the ESPs' I2S, HDMI, USB audio, and the null and file sinks, which mean a program that plays sound still runs |
| Accelerators | the resources | the P4's 2D engine and JPEG codec, the JH7110's JPEG, video decoder and crypto engine, the BCM2712's V3D through `facet.library` |

### How a part is found

No module carries a board fact. A machine says what it has as a list of
tags, and a module asks expansion.library for it:

```zig
const part = eb.FindBoardPart(null, st.PARTKIND_CRYPTO, st.CHIP_JH7110_CRYPTO) orelse return null;
```

- **A board that knows what it is** lists its parts at compile time, in
  `src/boards/<board>/system.zig`: a `PART_Kind`, a `PART_Chip`, a
  `PART_ChipName` for a listing to print, the bus it is on
  (`PART_Bus`: memory, PCI, I2C, I2S, SDIO, RMII, RGMII, the port
  space), its registers (`PART_Address`), its interrupt (`PART_Irq`),
  and whatever that kind of part needs besides - 121 tags in all.
- **A machine that describes itself** has the kernel build the same kind
  of list at run time from its firmware's tables and add it, which
  `src/main_x64uefi.zig` does for its framebuffer (`CHIP_UEFI_FB`), its
  clock (`CHIP_MC146818`), its power management (`CHIP_ACPI_PM`) and its
  PCI host (`CHIP_PCI_ECAM`). The module above cannot tell the
  difference, and that is the point.
- **A part nobody lists does not exist.** Every driver of a part answers
  null and goes away quietly, so a new machine starts with none of them
  and gains one at a time. This is what makes a port showable at every
  stage instead of at the end.

`sdk/libs/expansion/systemtags.zig` names **30 kinds of part and 54
chips**, which is the list of on-board hardware this system drives. It is
the file to read before writing a driver: a part much like one already
there usually wants the same tags.

### The engines, and what a machine without one gets

This is the question a port asks most often: the machine has some piece
of hardware for a job - is it already driven, how is it reached, and what
happens if it is not there?

| The job | What is driven | How it is reached | Without it |
|---|---|---|---|
| **Crypto** | the ESP32-S3's AES, SHA and RSA engines, fed through their registers; the JH7110's security block (AES in ECB/CBC/CTR/CCM/GCM, SHA, an RNG), fed by its own PL080 DMA | `crypto.library`: the register-fed engines are compiled for the chip that has them (`engine/_engine.zig`'s `on_chip`), the JH7110's by `chip == .rv64sbi` plus `FindBoardPart(PARTKIND_CRYPTO, CHIP_JH7110_CRYPTO)` | **nothing is lost**: every engine file falls back to a software model with the same inputs and the same state layout (`engine/soft_*.zig`), which is also what the host tests run. TLS, HTTPS, SMB and the Git client work on a machine with no engine at all |
| **JPEG** | the ESP32-P4's codec, which is the chip's and needs no part listed; the JH7110's CODAJ12, which the board lists (`PARTKIND_JPEG`) | `jpeg.resource`: an `Engine` enum arm per chip, and the engine's own file looks for its part | the `JPEG` datatype decodes in software |
| **Video** | the JH7110's WAVE511 (H.264, H.265), which runs a firmware the host loads | `videodec.resource`: an `Engine` arm, `PARTKIND_VIDEODEC`, and the firmware on the disk | the software decoders on the disk (`h264.vcodec` and the rest), on a machine whose disk carries them - the ESPs have neither, which `src/disk/build.zig` says by leaving them off |
| **3D** | the BCM2712's V3D 7.1 | `facet.library` and a driver on the disk (`v3d.fdriver`), `PARTKIND_GPU` | `facet.library`'s own rasteriser, where the machine is big enough to carry it |
| **2D** | the ESP32-P4's 2D engine | the display driver that has one (`rtg_driver/dsiboard/`: fills, copies, scaling and blending) | the CPU, through `graphics.library` |
| **Random** | the ESPs' RNG, the JH7110's TRNG (`PARTKIND_RNG`, which the kernel starts), and `rdrand` where the core has it - which every core this system runs on does | `sdk/hardware/<chip>/rng.zig` | a machine with none has to say so: this is the one place with no stand-in |
| **DMA** | the ESPs' GDMA, the JH7110's DesignWare AXI DMA and its security block's PL080 | `dma.resource`, a subfolder per controller, handed out as channels | a driver that needs DMA is not started; nothing else notices |
| **Sound out** | the ESPs' I2S into a codec or an amplifier (ES8311, NS4168, SC8002B), the JH7110's PWM-DAC and its HDMI, the BCM2712's HDMI, USB audio | `rta.library` and a sink per path, under `audio.device`; the board lists `PARTKIND_CODEC` or `PARTKIND_AMPLIFIER` | the null and file sinks, which are in the ROM: a program that plays sound still runs, and can record into a file |
| **A clock that keeps time** | the ESPs' RTC timer, the JH7110's RTC, a PCF8563 on I2C, the Raspberry Pi's behind its firmware, and the battery-backed clock an x86-64 machine has in its port space | `battclock.resource`, one file per source in `source/`, picked by the chip and by `PARTKIND_RTC` | the date is what the file system last wrote, and `C:Date` sets it |
| **Bytes that outlive a reset** | the ESPs keep them in the RTC's memory, past the clock's own (`hardware.rtc_timer.batt_memory`), and a `comptime` check refuses a build whose bits do not fit there | `battmem.resource`: `bits/_bits.zig` asks the chip whether there is such a memory, and the bits carry a magic number and a checksum so that what was never written reads as zeroes rather than as rubbish | the bits live in the resource's own base, so every call works and what they hold is lost at the next restart - which is what the three 64-bit machines do today. What is in them is the time zone's rule (`BATTMEM_ZONE`), which `C:SetClock ZONE` writes and the FAT and SMB handlers read to make sense of local timestamps - and the start-up sequence writes it back at every start (`C:SetClock ZONE`), so a machine whose bits do not survive loses nothing a user sees. A machine with a battery-backed clock usually has some bytes beside it - the clock an x86-64 machine has in its port space carries a hundred-odd - and putting them to use is a port's choice rather than a requirement |
| **Turning the machine off** | the firmware's own call: PSCI, SBI, a UEFI runtime service, or the chipset's power management block | `power.resource`: `machine/_machine.zig` per chip, `source/` per hardware, `PARTKIND_POWER` | `C:Shutdown` says the machine cannot be turned off rather than leaving it looking hung |
| **Temperature and fans** | the JH7110's sensor, the BCM2712's AVS monitor, a fan on an RP1 PWM channel | `thermal.resource`, a subfolder per chip, `PARTKIND_THERMAL` and `PARTKIND_FAN` | `C:Temperature` says there is no sensor |
| **A watchdog** | the ESPs' main watchdog timers | `watchdog.resource` | nothing bites |
| **Battery** | a charger with a readable voltage (CS8501), one whose status reaches only its LED (TP4054) | `battery.resource`, `PARTKIND_BATTERY` | no battery is reported |
| **Touch** | GT911, ST7123 controllers on I2C | `touch.device`, `PARTKIND_TOUCH` | the mouse |
| **IO expanders** | CH422G on I2C | `expander.resource`, `PARTKIND_EXPANDER`; `gpio.resource` reaches its pads like any other | the board wires what it needs directly |
| **USB** | the ESPs' DWC2, an xHCI function on PCI, the RP1's DWC3 (an xHCI that is no PCI function) | `usbotg.device` or `xhci.device`, `PARTKIND_USB` with the controller's kind | no USB; a machine with no other input needs a keyboard of its own |
| **PCI Express** | a host that is nothing but its configuration space and windows (what a firmware or an emulator leaves), the JH7110's XpressRICH ports, the BCM2712's STB bridge | `pci.library`, a host file per kind - the generic one is 18 lines - and `PARTKIND_PCI` | no PCI: no NVMe, no xHCI on PCI |
| **Ethernet** | the P4's, the JH7110's and the RP1's MACs through one `emac.device`, with a PHY file per part (IP101, YT8531, BCM54210); Intel's 82576 and I225/I226 on PCI through `intelnet.device`; the emulator's OpenCores MAC; any USB adapter | a MAC of the chip's own is a device under `networks/`, `PARTKIND_NET` with the bus (RMII, RGMII) and the PHY's address; a card on PCI needs no part at all - it is found by its PCI IDs, so a machine with a slot gets it without saying anything | `usb/ecm.device` with an adapter, or no network |
| **Radio** | the ESP32-S3's own, the CYW43455 on SDIO, the AIC8800 on USB | a device under `networks/`, `PARTKIND_NET` or the stick's own | no Wi-Fi |

### A third kind of engine: the CPU's own instructions

Every row above is a peripheral - something at an address, with a clock,
a reset and often an interrupt, which a board either has or has not. Two
of the five architectures also carry the work in the instruction set
itself: x86-64 has AES, SHA and carry-less multiply instructions, and
AArch64 has its crypto extension. **Nothing in the tree uses them yet**,
and the shape of the hook is why it is worth writing down rather than
assuming.

A peripheral is decided at compile time, because a chip either has it or
does not: `engine/_engine.zig`'s `on_chip` is one comptime constant, and
`jpeg.resource`'s `Engine` is a comptime switch. An instruction cannot be
decided that way, because **one image runs on any machine of its
architecture** - the same `kernel.bin` that runs on a 2010 processor runs
on this year's. So an instruction engine has to be asked for at run time
and fall back in the same image, which is what `sdk/hardware/x64uefi/rng.zig`
already does for `rdrand`: CPUID leaf 1, bit 30 of ECX, checked once and
remembered. A port that wants the crypto instructions wants that pattern,
not `on_chip`'s - a feature word read at the library's init, and a
function pointer per primitive chosen from it.

### The pattern

The hardware is named in `systemtags.zig`, listed by the board or added
by the kernel, found by `FindBoardPart`, and absent without consequence. A port that writes none
of them still reaches the desktop; each one it writes is a stage of its
own, which is why section 9's order is worth keeping to.

## 10. The one easily-missed class

About two dozen files size a buffer by the machine, written as
`if (chip == .rv64sbi or chip == .a64psci or chip == .x64uefi) <big> else <small>`:
`c/copy`, `c/net/httpget`, `c/test/crypto`, `devs/sdcard`,
`libs/anvil/desktop/work.zig`, `libs/bsdsocket/netif` and `tcp`,
`libs/http/connection`, `libs/smb/connection` and `session`, and the
`install` and `update` commands. **A chip left out of those chains gets
a microcontroller's buffers in silence** - nothing fails, it is merely
slow. `grep -rn 'chip == .rv64sbi' src sdk` finds the whole set.

## 11. What comes free

Everything above exec, and more than that: dos and its handlers, posfs
and fat, intuition, graphics, layers, rtg, motion, the datatypes, the
shell, the desktop, the network stack, TLS, and every program on the
disk. Three worth naming, because they are the ones a port expects to
have to write:

- **USB has no per-chip code at all.** A grep for the chip's name across
  `xhci.device`, `usb.library` and the `hid`, `disk`, `ecm`, `serial`,
  `audio` and `aic8800` class drivers finds nothing; everything they
  allocate is plain system memory. A machine with an xHCI controller on
  PCI gets keyboards, mice, sticks, serial adapters, Ethernet adapters
  and audio with nothing written.
- **`pci.library`** has a generic ECAM host; a machine whose firmware
  tables say where configuration space is needs no host driver of its
  own.
- **`crypto.library`** has a software path for everything, and reaches
  for an engine only where the board lists one.

## 12. Verification

- [ ] `./zig build test` after every stage. It is the gate: it
      cross-compiles every board's kernel, builds every disk image, runs
      the host tests, checks that no module imports a board, and checks
      the autodocs are current. The host guard in section 1 is the first
      thing it catches.
- [ ] An emulator step of the machine's own, so each stage can be shown:
      `./zig build qemu`, `emu`, `virt`, `virt64`, `q35`.
      `scripts/qemu-shot.py` talks QMP and is machine-independent, so
      screendumps and clicks are covered by the harness that exists.
- [ ] The real machine is the owner's to exercise: build a package, serve
      it, install it, and report from the serial console or the screen.

## 13. What goes with it

- [ ] Every module that gains the chip has its **revision** raised and
      its doc comment updated, with `./zig build autodoc` in the same
      change: exec, timer.device, serial.device, flash.device, the
      display driver, pci.library, the loader.
- [ ] The README's board list, the step list, and the guide the change
      belongs to.
- [ ] A `todo/` list for the machine, with the stages of section 9 as its
      items.
