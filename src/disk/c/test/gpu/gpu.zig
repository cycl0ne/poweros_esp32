// SPDX-License-Identifier: MIT
//! Gpu: an AMD graphics device tried a part at a time, each step said:
//! its video BIOS read, the display's clocks asked for, the display
//! controller read or started, its hot-plug lines and notifications
//! counted, an AUX read through it, a monitor's EDID read over its DDC
//! line, the picture's checksum read, the display's pipe taken down and
//! brought up again in its mode or put in each mode it offers, its
//! monitor put to sleep and woken, its colours' range tried, its security
//! processor started and the video decoder's firmware loaded by it, the
//! graphics block's firmware loaded, the block started and its memory
//! hub turned on, its DMA engine's queue tried with jobs in the device's
//! memory and in the machine's mapped for it, its copies of rectangles
//! tried and its fills and copies timed beside graphics.library's, the
//! board's own fills and copies by that engine held to graphics.library's,
//! the block's compute engine's queue started and a kernel the build made
//! for it run on the device's memory and on the machine's, the display's
//! interrupt at each frame counted, or one flip of the picture the
//! display reads. Built against the SDK only.
//!
//!   Gpu TOC/K,FIRMWARE/K,FRAMES/S,FLIP/S,BIOS/S,CLOCKS/S,DMCUB/S,START/S,CRC/S,EVENTS/S,LINE/K/N,AUX/K/N,ADDRESS/K/N,LENGTH/K/N,I2C/S,CONTROLLER/S,EDID/S,CONNECTOR/K/N,PIPE/K/N,FETCHER/K/N,CYCLE/S,DUMP/K/N,SEGMENT/K/N,MODES/S,HOLD/K/N,
//!       SLEEP/K/N,RANGE/S,POINTER/S,MIRROR/S,OVERLAY/S,DIRECT/S,BANDS/S,VIDEO/S,GFX/S,DMA/S,GART/S,ENGINE/S,BLITS/S,COMPUTE/S,KERNELS/S,
//!       BLOCK/K/N,WATCHDOG/K/N
//!
//! BIOS prints the device's video BIOS image (GetGPUBios): where it is
//! and how long, its tables' header's version, the version of each of
//! the command tables the display's pipe is switched with and of each
//! data table it lists, and the display's connectors as amdgpu.resource read
//! them from it (GetGPUConnector) - each one's kind, the PHY that drives
//! it, its DDC line and its hot-plug pin. Nothing is written to the
//! device, and no watchdog is wanted.
//!
//! CLOCKS has the display's board ("amd.0") ask the device's power
//! manager, through the display's own mailbox, for its firmware's
//! version and its table of clock levels, and read the clocks running
//! now (RTGCTRL_AMD_CLOCKS): the levels of each of the display's clocks,
//! the SoC's with its voltage at each of the display controller clock's
//! levels, the data fabric's states, then the PLL the display's clocks
//! are divided from, the display clock as the engine reads it back - the
//! pipes' clock it does not - and each pipe's divider of the pipes'
//! clock; what the board asked of the manager for what it shows - the
//! display controller's least clock and its least in deep sleep, the
//! display clock, the pipes' clock and each pipe's share, the state that
//! serves it and whether the memory's clock may change in the active
//! picture - and what the manager answered to each of those four; the
//! fabric's clock now; the hub's watermarks the board last wrote, each of
//! the hub's four sets as it holds them, whether the hub lets the memory
//! into self-refresh, and which pipes' fetchers read with their time to
//! urgency. The messages change nothing, but they are written to the
//! device: the watchdog is armed for them.
//!
//! DMCUB prints the display controller - the display engine's own
//! processor - as its registers read (RTGCTRL_AMD_CONTROLLER): whether
//! it is enabled, in reset, running its firmware (its clock read twice),
//! its boot status and options, its rings, the windows it reaches memory
//! through, its last faults. Read only, no watchdog wanted. The board
//! starts it as it is made; with START the board starts it again
//! (RTGCTRL_AMD_START_CONTROLLER): the firmware
//! dcn_<version>_dmcub.bin loaded by the security processor, the memory
//! it runs with set up, the controller let out of reset and asked what
//! it can do; printed are how far that got, the controller as it then
//! reads, its answer and the start of its trace, and the picture's
//! checksum before and after, which should be the same. The watchdog is
//! armed for it.
//!
//! CRC prints the checksum the display's timing generator computes over
//! the picture (RTGCTRL_AMD_CRC), switching it on the first time: the
//! watchdog is armed for it.
//!
//! EVENTS prints what the display engine's hot-plug lines and its
//! controller's notifications have done (RTGCTRL_AMD_EVENTS): each
//! line's changes, whether it senses a monitor and whether it is on, and
//! the controller's notifications by kind. The first time after the
//! controller started it has the controller's notifications listened
//! to, so the watchdog is armed for it; a cable pulled and put
//! back between two EVENTS shows as a line's changes. With LINE the
//! line of that number is first made to raise its interrupt once, by
//! waiting for what it already senses - the path tested without a hand
//! at the cable.
//!
//! AUX reads LENGTH bytes (16 unless given, at most 16) at ADDRESS (0
//! unless given) through the socket's AUX channel AUX - its DDC line's
//! number - by the channel's own AUX engine (RTGCTRL_AMD_AUX), or with
//! CONTROLLER by the display controller, which must run: the sink's own
//! registers, or with I2C its I2C bus. Printed
//! are the result, the sink's reply, the bytes and the channel's
//! registers before and after. The watchdog is armed for it.
//!
//! EDID reads the EDID of the monitor on the board's connector, or on
//! connector CONNECTOR as BIOS numbers them, as the board's own look at
//! its connector does (RTGCTRL_AMD_EDID): over its DDC line by the
//! display engine's I2C engine on HDMI and DVI, by I2C over its AUX
//! channel on DisplayPort. Printed are the connector's lines, whether its
//! hot-plug line senses a monitor, how the read went, the engine's
//! registers before and after, what the EDID says of the monitor and its
//! bytes. The watchdog is armed for it.
//!
//! CYCLE has the board take the display's pipe down and bring it up
//! again in the mode it is in (RTGCTRL_AMD_PIPE): the timing generator
//! stopped, the link's front end let go, the PHY switched off and its PLL
//! powered down by the video BIOS's command tables, which the display
//! controller runs, then all of it the other way. Printed are what was taken (the pipe, the link's ends,
//! the PHY, the link's kind, its deep colour and its clocks), how far it
//! got and how long the pipe was down, the pipe's registers before, while
//! down and after, and the picture's checksum before and after, which
//! should be the same: a picture that changes by itself - a clock's
//! seconds - is first waited for to change and then to hold 100 ms (2 s
//! at the most), and the pipe taken down right after. The watchdog is
//! armed for it.
//!
//! MODES puts the display's board in each mode it offers, in turn, and
//! back in the one it was in. First the board's settings line is applied
//! as it stands (SetBoardSettings), which has the board's modes made
//! again of what the monitor names - all it can make while the display
//! controller runs, the one it scans where it does not. Each mode is
//! shown with a picture of its own size: eight bars of colour, a white
//! frame round the edge. Printed for each are the mode, how its set went
//! (RTGCTRL_AMD_MODE: the link, the pixel clock, how far it got, how long
//! the pipe was down, whether the fetcher or the output ran short of
//! pixels) and the picture's checksum read twice, a few frames after the
//! show and again more than a frame later, which should be the same; then
//! the display's clocks (RTGCTRL_AMD_CLOCKS): the display clock as it
//! runs, what the board asked for it, the pipes' clock, each pipe's share
//! and the display controller's, what the power manager answered to each,
//! and the state that serves them; and the hub's first watermark set as it
//! holds it, with whether it lets the memory into self-refresh; then it is
//! held HOLD seconds (2 unless given) for
//! a look at the monitor. Ctrl-C stops after the mode shown. The watchdog
//! is armed for it and fed after each mode.
//!
//! SLEEP puts the display's board's monitor to sleep for SLEEP seconds
//! (SetBoardPower, RTGPWR_ASLEEP) and wakes it (RTGPWR_ON). Printed are
//! the picture's checksum before, while asleep - the last frame's, the
//! timing generator stopped - and after, which should be the one before;
//! pipe 0's count of frames and how many it counts in 100 ms, before,
//! twice while asleep (none) and after; each answer and the power state
//! the board then says it is in. With MODES, the board is shown in the
//! first other mode it offers while asleep, and back in its own, each set
//! printed: the monitor is woken for each set and put to sleep after.
//! How long the PHY took to go off and come on is on the system's lines.
//! The watchdog is armed for it and fed while the monitor sleeps.
//!
//! RANGE shows the board's mode with a still picture - eight bars of
//! colour, a white frame - and reads the picture's checksum with the
//! colours in full range, in limited range and in full again, each
//! twice: the first and the last should be the same, the second
//! another, and each steady. The range is the board's settings line's
//! (SetBoardSettings), which is put back as it was, and so is the
//! picture. The watchdog is armed for it.
//!
//! POINTER shows the same still picture and reads its checksum with the
//! board's pointer hidden, shown at three places - the last partly off
//! the picture's top left - and hidden again, with what pipe 0's cursor
//! is told at each: shown or not, its place and its hot spot. The first
//! and the last checksum should be the same and the others each another.
//! The pointer is put back where it was, shown or not as it was, and so
//! is the picture. The watchdog is armed for it.
//!
//! MIRROR shows the still picture with a grey block in its top left, so
//! that it differs about either axis, and for each way of mirroring it -
//! none, left to right, top to bottom, both - reads two checksums: of a
//! picture this program mirrors itself, with the board's pointer image
//! drawn into it where the pointer would be, the board
//! unmirrored and its pointer hidden - once with no pointer, then at a
//! place on the picture, one partly off its top left and one partly off
//! its bottom right; and of the picture as it was, the board mirroring
//! it and laying the pointer there. Where the board
//! mirrors and lays the pointer as it should, the two are the same. The
//! board's mirror, its pointer and its picture are put back as they
//! were. The watchdog is armed for it.
//!
//! OVERLAY does the same with the board's overlay: an image of 120 by 80
//! with clear squares in it, at a place on the picture, one partly off
//! its top left and one partly off its bottom right, each with the
//! pointer hidden, over the overlay and across its edge - drawn by this
//! program, overlay under pointer, into the picture it mirrors itself,
//! against the board mirroring the picture and laying both. It says
//! which of the engine's pipes the overlay is a plane on, where it is
//! one. The board's overlay is taken off after, and its mirror, its
//! pointer and its picture are put back as they were. The watchdog is
//! armed for it.
//!
//! DIRECT shows two pictures in turn on a board that reads a program's
//! buffers in place of a frame, each drawn while the other is shown -
//! in the mode the board is in, and in another of another row length
//! where the board lists one: the first made in a frame - the picture
//! shown before is said to be written in first, so that this holds
//! whatever showed it - the next ones read by the display themselves;
//! then the one shown written in, which
//! has the next pictures made in frames again; then one drawn anew and
//! shown at once, read as it is, and written in. Each picture's
//! checksum against the same picture made in a frame, the address the
//! board's fetcher reads and whether that is a buffer's, through the
//! engine's page table, and how long each show took. The board's
//! picture is put back after. The watchdog is armed for it.
//!
//! BANDS shows several buffers at once, in bands, on a board whose
//! display reads bands itself - a picture pulled down over another, one
//! with its rows from part way down, three at once with one of them half
//! as wide and shown twice the size, one a quarter as wide shown four
//! times the size from part way into its first row, one whose rows end
//! before its band does - for each way of mirroring the picture, with
//! the pointer hidden; the first of them with the pointer in each band
//! and across their edge, and the first and the third with an overlay
//! across the edge as well, the third then taking all four of the
//! engine's pipes. Each read by the display as it is, against the same
//! bands made in a frame once one of them is written in; with how many
//! of the engine's fetchers read and how long the show took. The
//! board's mirror, pointer and picture are put back after, and the
//! overlay taken off. The watchdog is armed for it.
//!
//! VIDEO shows a film's frame on the board's video layer - 320 by 180
//! in NV12, its planes starting part way into the 256 bytes the
//! display's fetcher reads by - and says what the layer is. Under the
//! picture: the frame's black, white, red, green and blue - each
//! channel made exactly nothing or all of it - read as a window of the
//! glass against the same colours drawn beside it, and video's black
//! said as the greys it matches; then blocks of black and white, shown
//! as they are - whole, partly off the glass's top left and bottom right,
//! a part of the frame - for each way of mirroring, a place moved to
//! while the frame is shown, the picture's key colour only over part of
//! the place, the shades of it a shadow leaves, colours next to it, the
//! pointer over the film and across its edge, and the film after the
//! monitor slept and the board was shown in another mode and back
//! meanwhile, each against the same picture drawn by the program; made larger, smaller and by a
//! ratio that is no whole number, as windows inside the blocks against
//! the same windows of the blocks drawn the size they are shown, with the
//! display's clocks while each is shown, as MODES prints them. Then
//! nothing shown, a place with nothing in it and one off the glass, each
//! against the picture with no layer open. Over the picture: the frame
//! unmirrored and mirrored both ways, against the program's drawing, and
//! the pointer over it. The layer is closed after, and the board's
//! mirror, pointer and picture put back as they were. The watchdog is
//! armed for it.
//!
//! DUMP prints LENGTH (16 unless given, at most 512) of the display
//! engine's registers from DUMP on, in 32-bit words from the engine's
//! address SEGMENT (2 unless given: the one its pipes, links and
//! endpoints are counted from; 1 is its clocks'). With BLOCK, the
//! registers of the block the device's table numbers so (11 the graphics
//! block), from its address SEGMENT (0 unless given). Read only, but a
//! register of a block switched off can stop the machine: the watchdog
//! is armed for it.
//!
//! GFX starts the graphics block: its firmware files are read from
//! DEVS:firmware/amdgpu/, named for the blocks' versions as the device's
//! table gives them - gc_11_0_1_pfp.bin, _me.bin, _mec.bin, _rlc.bin,
//! _mes_2.bin, _mes1.bin and _imu.bin for the graphics block 11.0.1, of
//! which the last may be missing, sdma_6_0_1.bin for its DMA engine 6.0.1
//! - and the security processor's table of contents beside them. The
//! processor is made ready (StartGPUSecurity, at once where it is), the
//! block kept powered (SetGPUPower) and its registers printed, then its
//! firmware loaded, the block started and its memory hub turned on
//! (StartGPUGraphics), which waits until the engines have their code. How
//! long that took is printed, and the block's registers again with its
//! hub's, the vendor's settings it was given and its clock gating's, and
//! the graphics block's and the data fabric's clocks as the power manager
//! reads them (GetGPUClock), at once and again after the block has been
//! idle for a second; the block is left powered and started. The watchdog
//! is armed for it.
//!
//! DMA does what GFX does, then starts the block's DMA engine with its
//! queue (StartGPUDMA) and tries it: a job of eight NOPs; a hundred
//! empty jobs - each only the fence and the trap that end it - sent and
//! waited for one after another, timed, with the engine's interrupts
//! counted; 64 KiB of the device's memory, between guards of a page each
//! way, filled with a constant once with the fill's size 0 and once in
//! words, and read back; and a fill of 64 MiB in words (16 where the
//! device's memory has no room for it), timed. The queue's state and the
//! engine's registers are printed at the end, with the hub's. The
//! watchdog is armed for it.
//!
//! GART does what GFX does, starts the queue and tries the machine's
//! memory through the hub's page table (MapGPUMemory): 64 KiB of it,
//! placed 100 bytes into a page, between guards of a page each way,
//! mapped, filled in words through the mapping, unmapped and read back
//! by the CPU; two buffers filled one after the other through mappings
//! at the same place in the hub's range, each with its own value, so
//! that the second fill reaches the second buffer only if the hub's TLB
//! was dropped between them; and 16 MiB filled, timed. The queue and the
//! hub's registers are printed at the end. The watchdog is armed for it.
//!
//! ENGINE does what GFX does, starts the queue and tries the engine's
//! copies of rectangles on two buffers of the machine's memory, 2560 x
//! 2880 pixels of four bytes, mapped for it, each painted with a pattern
//! whose every pixel is its own: a copy between the two; one of two bytes
//! a pixel, at odd columns; copies within one buffer whose source and
//! destination overlap - moved down and right, up and right, right, left
//! - each cut into bands whose own source and destination are apart,
//! sent in the order that reads each band before another writes over it;
//! for what the engine does with it, a copy over itself by a row and by a
//! column in one packet, not counted; and fills copied from a row of the
//! colour read one pixel on for each row, of four bytes a pixel and of
//! two. Every pixel of the buffer written is checked. Then fills - a
//! packet a row, and copied from a row - copies between the buffers and
//! scrolls by 16 rows up and down, at 256 x 256, 1024 x 1024 and the
//! buffers' width at 64 to 2864 rows, are timed by the engine, its job
//! waited for and spun on, and by graphics.library on the same memory,
//! with the rectangles just written by the CPU and with them out of its
//! caches. The watchdog is armed for it.
//!
//! BLITS holds the board's own fills and copies (rtg.library's FillRect,
//! CopyRect and CopyRects, which rtg-amd hands to the DMA engine where a
//! job is more than the CPU's caches hold) to graphics.library's: two
//! buffers of the machine's memory, 2560 x 2880 pixels of four bytes, are
//! handed to the board (AttachBitMap), two more of plain memory are not,
//! and before each job the four are painted alike, each pixel its own.
//! Each job is done by the board on its two and by graphics.library on
//! the plain two - fills of whole rows, of part of the rows and a small
//! one; copies between the two, a small one and four at once; moves
//! within one buffer - clear of where it starts, scrolls by 16 rows up
//! and down and by one row, more bands than the board cuts a move into,
//! by 100 rows and 37 columns down and right and up and left, and by 16
//! columns right and left, which the board leaves to the cores; and of
//! two bytes a pixel, the same memory
//! as twice as many pixels, fills of whole rows and of part, a copy at
//! odd columns and a scroll - and every pixel of the four is compared. A
//! job the board does not take is done by graphics.library on the
//! board's buffers, as the library does it, and said so. Last a fill
//! and a copy are drawn through graphics.library into the board's buffer
//! itself (RPTAG_BitMap), as a program draws, and held to the same. Each
//! is timed beside graphics.library's. The watchdog is armed for it.
//!
//! COMPUTE does what GFX does, prints the compute engine's registers,
//! then starts its queue through the block's scheduler (StartGPUCompute),
//! which prints how long that took and the scheduler's firmware, and
//! tries it: four words written by the engine (WRITE_DATA) into the
//! device's memory beside guards, read back; a hundred empty jobs sent and
//! waited for one after another, timed, with the engine's interrupts
//! counted; then the code object the build made from kernels/fill.zig,
//! embedded in the command, loaded (LoadGPUCode) and its kernel `fill`
//! found (FindGPUKernel), and dispatched (SendGPUKernel) - over 64 KiB of
//! the device's memory between guards of a page each way, over as much of
//! the machine's, placed 100 bytes into a page and mapped for it
//! (MapGPUMemory), every word and every guard checked, and over 16 MiB of
//! each, timed, the machine's every word checked. The queue and the
//! engine's registers are printed at the end. The watchdog is armed for
//! it.
//!
//! KERNELS holds the board's own blends, scales, shapes and tiles (the
//! kernels rtg-amd runs on the compute engine for BlendPixels, BlendRect,
//! ScalePixels, BlitTemplate and BlitPattern) to graphics.library's: a
//! buffer of the machine's memory, 2560 x 2880 pixels of four bytes or
//! the same memory as twice as many of two, is handed to the board
//! (AttachBitMap), one more of plain memory is not, and before each job
//! the two are painted alike. Each job is drawn by graphics.library into
//! both - into the board's buffer itself (RPTAG_BitMap), which it hands
//! to the board, and into the plain one, which it draws itself - and
//! every pixel of the two is compared: a picture of the same size, each
//! pixel's coverage none, all or its own in patches, laid at full
//! strength, at half, covering fully at 200, as `rgba32` over part of
//! the buffer and over smaller rectangles down to 64 x 64; a colour laid
//! over part of it and over smaller ones; parts of the picture scaled
//! smoothly up by 2 and by 1.5, to the same size, down by 2, by 3 and by
//! 64, narrower and taller, and from 128 to 256 pixels a side; shapes
//! from bits of the machine's memory in both colours, over the buffer
//! and over 256 x 256, in ink alone over part of it from a bit within a
//! byte, and with their colours swapped, of four bytes a pixel and of
//! two; and tiles of 16 x 16 bits and of 13 x 7, the same ways. Whose the board's drawing was - the kernels'
//! or, where the board does not take it, the cores' - is told by the jobs
//! the compute engine's queue counts (GetGPUComputeState). Each is timed
//! beside graphics.library's on plain memory, each drawing begun with 64
//! MiB of other memory read through, so that nothing it reads or writes
//! is in the CPU's caches, as for a job larger than they are. It all
//! runs twice: with
//! every job the kernels can do handed to them (RTGCTRL_AMD_ENGINE,
//! RTG_AMD_ENGINE_ALL), then by the board's own rule, which it is left
//! with. The watchdog is armed for it.
//!
//! Without BIOS, CLOCKS, DMCUB, CRC, EVENTS, AUX, EDID, CYCLE, MODES,
//! SLEEP, RANGE, POINTER, MIRROR, OVERLAY, DIRECT, BANDS, VIDEO, GFX,
//! DMA, GART, ENGINE, BLITS, COMPUTE, DUMP, FRAMES or FLIP the two files
//! are read from
//! DEVS:firmware/amdgpu/, named for the blocks that use them as the
//! device's table gives their versions - psp_13_0_4_toc.bin for the
//! security processor 13.0.4, vcn_4_0_2.bin for the video decoder 4.0.2 -
//! unless TOC and FIRMWARE name others. amdgpu.resource is asked to make
//! the processor ready (StartGPUSecurity) and to load the firmware
//! (LoadGPUFirmware), and where it put it is printed. What the processor
//! answered to each command is on the system's lines (C:Log).
//!
//! FRAMES hooks the interrupt the display's pipe PIPE (0 unless given)
//! raises at each frame, where it takes up its double-buffered registers
//! (AddGPUIntServer), switches it on, and counts it for three seconds
//! beside the pipe's own count of frames; then switches it off. The first
//! server starts the device's interrupt ring, which says so on the
//! system's lines.
//!
//! FLIP has the fetcher FETCHER (0 unless given) of that pipe read a
//! frame of the device's own memory instead of the firmware's screen:
//! the frame holds a copy of the default public screen, rows as far
//! apart as the fetcher reads them, so the display shows what it showed -
//! but for the pointer, which is not in the screen's buffer. The flip is
//! the fetcher's new address, taken up at the pipe's next update; it is
//! waited for by the interrupt FRAMES counts, and how many frames and how
//! long it took is printed, with the address the fetcher then reads. Held
//! three seconds, then flipped back the same way, and the frame given
//! back.
//!
//! WATCHDOG is the watchdog's time in milliseconds, armed before the
//! first write to the device, fed after each step and disarmed at the
//! end: a block that stops the machine has it reset. Every step but BIOS
//! requires it, since nothing else brings a machine back that stopped
//! there.

const sdk = @import("sdk");
const dos = sdk.dos;
const datatypes = sdk.datatypes;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const watchdog = sdk.resources.watchdog;
const WatchdogBase = sdk.interface.watchdog.WatchdogBase;
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = sdk.interface.amdgpu.AMDGPUBase;
const exec = sdk.exec;
const intuition = sdk.intuition;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const timer = sdk.devices.timer;
const TimerBase = sdk.interface.timer.TimerBase;
const dcn = sdk.hardware.amd_dcn;
const reg = sdk.hardware.mmio.reg;
const Printf = dos.stdio.Printf;
const rtg = sdk.rtg;
const RtgBase = sdk.interface.rtg.RtgBase;
const TagItem = sdk.utility.TagItem;
const graphics_library = sdk.graphics;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;

pub const COMMAND_NAME = "Gpu";
const VERSION_STRING = "\x00$VER: Gpu 1.29 (27.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "TOC/K,FIRMWARE/K,FRAMES/S,FLIP/S,BIOS/S,CLOCKS/S,DMCUB/S,START/S,CRC/S,EVENTS/S,LINE/K/N,AUX/K/N,ADDRESS/K/N,LENGTH/K/N,I2C/S,CONTROLLER/S,EDID/S,CONNECTOR/K/N,PIPE/K/N,FETCHER/K/N,CYCLE/S,DUMP/K/N,SEGMENT/K/N,MODES/S,HOLD/K/N,SLEEP/K/N,RANGE/S,POINTER/S,MIRROR/S,OVERLAY/S,DIRECT/S,BANDS/S,VIDEO/S,GFX/S,DMA/S,GART/S,ENGINE/S,BLITS/S,COMPUTE/S,KERNELS/S,BLOCK/K/N,WATCHDOG/K/N";
const arg_toc = 0;
const arg_firmware = 1;
const arg_frames = 2;
const arg_flip = 3;
const arg_bios = 4;
const arg_clocks = 5;
const arg_dmcub = 6;
const arg_start = 7;
const arg_crc = 8;
const arg_events = 9;
const arg_line = 10;
const arg_aux = 11;
const arg_address = 12;
const arg_length = 13;
const arg_i2c = 14;
const arg_controller = 15;
const arg_edid = 16;
const arg_connector = 17;
const arg_pipe = 18;
const arg_fetcher = 19;
const arg_cycle = 20;
const arg_dump = 21;
const arg_segment = 22;
const arg_modes = 23;
const arg_hold = 24;
const arg_sleep = 25;
const arg_range = 26;
const arg_pointer = 27;
const arg_mirror = 28;
const arg_overlay = 29;
const arg_direct = 30;
const arg_bands = 31;
const arg_video = 32;
const arg_gfx = 33;
const arg_dma = 34;
const arg_gart = 35;
const arg_engine = 36;
const arg_blits = 37;
const arg_compute = 38;
const arg_kernels = 39;
const arg_block = 40;
const arg_watchdog = 41;
const arg_count = 42;

/// Where the files are.
const directory = "DEVS:firmware/amdgpu/";

/// The image's marks: where its tables' header's offset is, the header's
/// mark four bytes into it, and where the header names the list of
/// command tables and the list of data tables.
const atom_header_offset_at = 0x48;
const atom_mark_at = 4;
const atom_commands_at = 0x1E;
const atom_data_tables_at = 0x20;

/// A table of the BIOS's, by its place in its list.
const NamedTable = struct { index: u32, name: [*:0]const u8 };

/// The command tables the display driver runs.
const command_table_names = [_]NamedTable{
    .{ .index = 4, .name = "front end" },
    .{ .index = 12, .name = "pixel clock" },
    .{ .index = 13, .name = "display power gating" },
    .{ .index = 76, .name = "transmitter" },
};

/// The data tables the display driver reads.
const data_table_names = [_]NamedTable{
    .{ .index = 4, .name = "firmware info" },
    .{ .index = 8, .name = "power manager info" },
    .{ .index = 11, .name = "memory the firmware uses" },
    .{ .index = 12, .name = "GPIO pins" },
    .{ .index = 14, .name = "graphics info" },
    .{ .index = 15, .name = "power play" },
    .{ .index = 22, .name = "display objects" },
    .{ .index = 27, .name = "display engine info" },
    .{ .index = 30, .name = "integrated system info" },
    .{ .index = 32, .name = "voltage objects" },
};

/// A file's name, put together from its parts.
const Name = struct {
    room: [64]u8 = undefined,
    len: usize = 0,

    fn text(name: *Name, part: []const u8) void {
        for (part) |c| {
            if (name.len + 1 >= name.room.len) return;
            name.room[name.len] = c;
            name.len += 1;
        }
    }

    fn number(name: *Name, value: u32) void {
        var digits: [10]u8 = undefined;
        var count: usize = 0;
        var left = value;
        while (true) {
            digits[count] = @intCast('0' + left % 10);
            count += 1;
            left /= 10;
            if (left == 0) break;
        }
        while (count > 0) {
            count -= 1;
            name.text(digits[count .. count + 1]);
        }
    }

    /// `prefix` with the block's version, `suffix` after it.
    fn of(prefix: []const u8, block: amdgpu.GPUBlock, suffix: []const u8) Name {
        var name: Name = .{};
        name.text(directory);
        name.text(prefix);
        name.number(block.major);
        name.text("_");
        name.number(block.minor);
        name.text("_");
        name.number(block.revision);
        name.text(suffix);
        name.room[name.len] = 0;
        return name;
    }

    fn string(name: *const Name) [*:0]const u8 {
        return @ptrCast(&name.room);
    }
};

/// The file `name` read whole into memory of its own (FreeVec), or null
/// with why said.
fn readFile(sys: *ExecBase, dl: *DosBase, name: [*:0]const u8) ?[]u8 {
    var length: usize = 0;
    const bytes = dl.ReadFile(name, ~@as(usize, 0), exec.MEMF_ANY, &length) orelse {
        _ = Printf(dl, "%s: cannot be %s\n", .{ name, @as([*:0]const u8, if (dl.IoErr() == dos.ERROR_OBJECT_NOT_FOUND) "found" else "read") });
        return null;
    };
    if (length == 0) {
        sys.FreeVec(bytes);
        _ = Printf(dl, "%s: cannot be read\n", .{name});
        return null;
    }
    return bytes[0..length];
}

/// The 16-bit number at `at` in `image`, or null past its end.
fn half(image: []const u8, at: usize) ?u16 {
    if (at + 2 > image.len) return null;
    return @as(u16, image[at]) | @as(u16, image[at + 1]) << 8;
}

/// What a table at `at` says its version and its size are: its first
/// four bytes.
fn tableHeader(image: []const u8, at: usize) ?struct { bytes: u16, format: u8, content: u8 } {
    const bytes = half(image, at) orelse return null;
    if (at + 4 > image.len) return null;
    return .{ .bytes = bytes, .format = image[at + 2], .content = image[at + 3] };
}

/// The tables `names` of the list at `list` in `image`, each where it
/// is, its version and its length.
fn printTables(dl: *DosBase, image: []const u8, list: u16, names: []const NamedTable) void {
    for (names) |named| {
        const at = half(image, @as(usize, list) + 4 + named.index * 2) orelse continue;
        if (at == 0) {
            _ = Printf(dl, "  %2u %-26s none\n", .{ named.index, named.name });
            continue;
        }
        const table = tableHeader(image, at) orelse continue;
        _ = Printf(dl, "  %2u %-26s at 0x%04x, version %u.%u, %u bytes\n", .{
            named.index,            named.name,              @as(u32, at),
            @as(u32, table.format), @as(u32, table.content), @as(u32, table.bytes),
        });
    }
}

/// The video BIOS image and the connectors read from it, printed.
fn bios(dl: *DosBase, ab: *AMDGPUBase) i32 {
    var found: amdgpu.GPUBios = .{};
    if (!ab.GetGPUBios(&found)) {
        _ = Printf(dl, "The firmware kept no video BIOS image for the device: see C:Log\n", .{});
        return dos.RETURN_WARN;
    }
    const image = found.image.?[0..found.bytes];
    _ = Printf(dl, "Video BIOS: %u bytes at 0x%lx\n", .{ found.bytes, @as(u64, @intFromPtr(found.image.?)) });
    if (half(image, atom_header_offset_at)) |header| {
        if (tableHeader(image, header)) |atom| {
            _ = Printf(dl, "Tables' header at 0x%04x, version %u.%u\n", .{ @as(u32, header), @as(u32, atom.format), @as(u32, atom.content) });
        }
        const commands = half(image, @as(usize, header) + atom_commands_at) orelse 0;
        if (tableHeader(image, commands)) |list| {
            _ = Printf(dl, "Command tables: list at 0x%04x, %u entries\n", .{ @as(u32, commands), @as(u32, list.bytes -| 4) / 2 });
            printTables(dl, image, commands, &command_table_names);
        }
        const data = half(image, @as(usize, header) + atom_data_tables_at) orelse 0;
        if (tableHeader(image, data)) |list| {
            _ = Printf(dl, "Data tables: list at 0x%04x, %u entries\n", .{ @as(u32, data), @as(u32, list.bytes -| 4) / 2 });
            printTables(dl, image, data, &data_table_names);
        }
    }
    var connector: amdgpu.GPUConnector = .{};
    var index: u32 = 0;
    while (ab.GetGPUConnector(index, &connector)) : (index += 1) {
        const phy: u32 = if (connector.phy == amdgpu.GPULINE_NONE) '?' else 'A' + connector.phy;
        _ = Printf(dl, "Connector %u: %s %u on PHY %c, DDC line 0x%02x, hot plug 0x%02x (object 0x%04x, encoder 0x%04x)\n", .{
            index,         kindName(connector.kind), connector.number, phy,
            connector.ddc, connector.hpd,            connector.object, connector.encoder,
        });
    }
    if (index == 0) _ = Printf(dl, "The video BIOS lists no connectors this reads\n", .{});
    return dos.RETURN_OK;
}

/// The display's board, by the name its driver gives it.
const amd_board = "amd.0";

/// The display's clocks, asked of its board with the watchdog armed, and
/// printed.
fn clocks(sys: *ExecBase, dl: *DosBase, millis: u32) i32 {
    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);
    const board = rb.FindBoard(amd_board) orelse {
        _ = Printf(dl, "No board %s: the display is not driven by rtg-amd\n", .{amd_board});
        return dos.RETURN_WARN;
    };
    const wb: *WatchdogBase = @ptrCast(sys.OpenResource(watchdog.WATCHDOGNAME) orelse {
        _ = Printf(dl, "No %s\n", .{watchdog.WATCHDOGNAME});
        return dos.RETURN_FAIL;
    });
    if (!wb.ArmWatchdog(millis, watchdog.WATCHDOG_RESET_SYSTEM)) {
        _ = Printf(dl, "The watchdog refuses %u ms\n", .{millis});
        return dos.RETURN_FAIL;
    }
    _ = Printf(dl, "Watchdog armed: %u ms\n", .{millis});
    var found: rtg.tags.RtgAmdClocks = .{};
    const result = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_CLOCKS, @bitCast(@intFromPtr(&found)));
    wb.DisarmWatchdog();
    if (found.pll_khz != 0) {
        _ = Printf(dl, "Running: PLL %u kHz, display clock %u kHz (the pipes' clock is not read back)\n", .{ found.pll_khz, found.disp_khz });
    } else _ = Printf(dl, "Running: the clock generator is not known\n", .{});
    if (found.firmware != 0) {
        _ = Printf(dl, "Power manager's firmware %u.%u.%u\n", .{ found.firmware >> 16 & 0xff, found.firmware >> 8 & 0xff, found.firmware & 0xff });
    }
    if (result != rtg.errors.RTGERR_OK) {
        _ = Printf(dl, "The clocks were not had: error %ld, message 0x%x answered 0x%x\n", .{ @as(i64, result), found.message, found.answer });
        return dos.RETURN_ERROR;
    }
    printLevels(dl, "Display controller (DCFCLK)", found.dcf_mhz[0..found.dcf_count]);
    printLevels(dl, "Display (DISPCLK)", found.disp_mhz[0..found.disp_count]);
    printLevels(dl, "Pipes (DPPCLK)", found.dpp_mhz[0..found.disp_count]);
    printLevels(dl, "SoC (SOCCLK)", found.soc_mhz[0..found.soc_count]);
    _ = Printf(dl, "SoC's voltage at each:", .{});
    for (found.soc_voltage[0..found.dcf_count]) |voltage| _ = Printf(dl, " %u.%02u", .{ voltage / 4, voltage % 4 * 25 });
    _ = Printf(dl, " mV\n", .{});
    for (0..found.fabric_count) |index| {
        _ = Printf(dl, "Fabric state %u: fabric %u MHz, memory %u MHz, %u.%02u mV, WCK ratio %u\n", .{
            @as(u32, @intCast(index)),
            found.fabric_mhz[index],
            found.memory_mhz[index],
            found.fabric_voltage[index] / 4,
            found.fabric_voltage[index] % 4 * 25,
            found.fabric_ratio[index],
        });
    }
    _ = Printf(dl, "Pipes' dividers:", .{});
    for (found.dividers) |divider| {
        if (divider == 0) {
            _ = Printf(dl, " off", .{});
        } else _ = Printf(dl, " %u/%u", .{ divider & 0xff, divider >> 16 & 0xff });
    }
    _ = Printf(dl, "\n", .{});
    if (found.asked_disp_khz != 0) {
        _ = Printf(dl, "Asked: display controller at least %u kHz, %u kHz in deep sleep; display clock %u kHz, pipes' clock %u kHz, each pipe", .{ found.asked_dcf_khz, found.asked_deep_sleep_khz, found.asked_disp_khz, found.asked_dpp_khz });
        for (found.asked_pipe_khz) |khz| _ = Printf(dl, " %u", .{khz});
        _ = Printf(dl, " kHz; state %u, the memory's clock %s\n", .{ found.level, @as([*:0]const u8, if (found.change_in_active != 0) "changes in the active picture" else "changes in the blank") });
        _ = Printf(dl, "The power manager answered: display controller %u MHz, deep sleep %u MHz, display clock %u MHz, pipes' clock %u MHz (0 for one refused)\n", .{ found.answered_dcf_mhz, found.answered_deep_sleep_mhz, found.answered_disp_mhz, found.answered_dpp_mhz });
    } else _ = Printf(dl, "Asked: nothing yet\n", .{});
    if (found.fabric_now_mhz != 0) {
        _ = Printf(dl, "Fabric now: %u MHz\n", .{found.fabric_now_mhz});
    } else _ = Printf(dl, "Fabric now: not answered\n", .{});
    printHub(dl, &found);
    return dos.RETURN_OK;
}

/// The hub's watermarks: what the board last wrote, in nanoseconds and
/// thousandths; each of the hub's sets as it holds them, in its reference
/// cycles; whether it lets the memory into self-refresh, and which pipes'
/// fetchers read with their time to urgency.
fn printHub(dl: *DosBase, found: *const rtg.tags.RtgAmdClocks) void {
    const marks = &found.asked_marks;
    _ = Printf(dl, "Hub, written: urgency %u ns, a trip to the memory %u ns, self-refresh's entry and exit %u ns, the deeper state's %u ns,\n", .{ marks[0], marks[1], marks[2], marks[3] });
    _ = Printf(dl, "  self-refresh's exit %u ns, the deeper state's %u ns, the memory clock's change %u ns, the share of the return %u, with a flip %u (thousandths)\n", .{ marks[4], marks[5], marks[6], marks[7], marks[8] });
    for (found.hub_marks, 0..) |set, index| {
        _ = Printf(dl, "Hub set %c, as it holds it:", .{@as(u32, 'A') + @as(u32, @intCast(index))});
        for (set) |mark| _ = Printf(dl, " %u", .{mark});
        _ = Printf(dl, "\n", .{});
    }
    _ = Printf(dl, "Self-refresh %s; time to urgency on for pipes", .{@as([*:0]const u8, if (found.self_refresh != 0) "allowed" else "forbidden")});
    var any = false;
    for (0..rtg.tags.RTG_AMD_PIPES) |pipe_index| {
        if (found.timed_pipes >> @intCast(pipe_index) & 1 == 0) continue;
        _ = Printf(dl, " %u", .{@as(u32, @intCast(pipe_index))});
        any = true;
    }
    _ = Printf(dl, "%s\n", .{@as([*:0]const u8, if (any) "" else " none")});
}

/// The display's board, from rtg.library opened as `base`: null with why
/// said.
fn amdBoard(dl: *DosBase, rb: *RtgBase) ?*rtg.RtgBoard {
    return rb.FindBoard(amd_board) orelse {
        _ = Printf(dl, "No board %s: the display is not driven by rtg-amd\n", .{amd_board});
        return null;
    };
}

/// The watchdog armed for `millis`: its resource, or null with why said.
fn arm(sys: *ExecBase, dl: *DosBase, millis: u32) ?*WatchdogBase {
    const wb: *WatchdogBase = @ptrCast(sys.OpenResource(watchdog.WATCHDOGNAME) orelse {
        _ = Printf(dl, "No %s\n", .{watchdog.WATCHDOGNAME});
        return null;
    });
    if (!wb.ArmWatchdog(millis, watchdog.WATCHDOG_RESET_SYSTEM)) {
        _ = Printf(dl, "The watchdog refuses %u ms\n", .{millis});
        return null;
    }
    _ = Printf(dl, "Watchdog armed: %u ms\n", .{millis});
    return wb;
}

/// The display controller read, or - with the watchdog's `millis` -
/// started; printed either way.
fn controller(sys: *ExecBase, dl: *DosBase, millis: ?u32) i32 {
    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);
    const board = amdBoard(dl, rb) orelse return dos.RETURN_WARN;
    var found: rtg.tags.RtgAmdController = .{};
    const time = millis orelse {
        const result = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_CONTROLLER, @bitCast(@intFromPtr(&found)));
        if (result != rtg.errors.RTGERR_OK) {
            _ = Printf(dl, "The controller was not read: error %ld\n", .{@as(i64, result)});
            return dos.RETURN_ERROR;
        }
        printController(dl, &found);
        return dos.RETURN_OK;
    };
    const wb = arm(sys, dl, time) orelse return dos.RETURN_FAIL;
    var before: rtg.tags.RtgAmdCrc = .{};
    const crc_before = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_CRC, @bitCast(@intFromPtr(&before)));
    const result = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_START_CONTROLLER, @bitCast(@intFromPtr(&found)));
    var after: rtg.tags.RtgAmdCrc = .{};
    const crc_after = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_CRC, @bitCast(@intFromPtr(&after)));
    wb.DisarmWatchdog();
    const stages = [_][*:0]const u8{ "nothing done", "the files read", "the firmware loaded", "set up", "up", "answered" };
    _ = Printf(dl, "Start: error %ld, %s\n", .{ @as(i64, result), stages[@min(found.stage, stages.len - 1)] });
    printController(dl, &found);
    if (found.stage >= rtg.tags.RTG_AMD_STAGE_UP) {
        _ = Printf(dl, "Answer:", .{});
        for (found.reply) |reply_word| _ = Printf(dl, " %08lx", .{@as(u64, reply_word)});
        _ = Printf(dl, "\nTrace:", .{});
        for (found.trace) |trace_word| _ = Printf(dl, " %08lx", .{@as(u64, trace_word)});
        _ = Printf(dl, "\n", .{});
    }
    printCrc(dl, "Picture before", crc_before, &before);
    printCrc(dl, "Picture after ", crc_after, &after);
    if (crc_before == rtg.errors.RTGERR_OK and crc_after == rtg.errors.RTGERR_OK) {
        const same = before.red == after.red and before.green == after.green and before.blue == after.blue;
        _ = Printf(dl, "The picture is %s\n", .{@as([*:0]const u8, if (same) "unchanged" else "CHANGED")});
    }
    return if (result == rtg.errors.RTGERR_OK) dos.RETURN_OK else dos.RETURN_ERROR;
}

/// The controller as RtgAmdController holds it, a line a part.
fn printController(dl: *DosBase, found: *const rtg.tags.RtgAmdController) void {
    if (found.present == 0) {
        _ = Printf(dl, "The display engine has no controller\n", .{});
        return;
    }
    _ = Printf(dl, "Control %08lx: %s, %s; reset %08lx (%s); secure %08lx\n", .{
        @as(u64, found.control),
        @as([*:0]const u8, if (found.control & 1 << 16 != 0) "enabled" else "disabled"),
        @as([*:0]const u8, if (found.control & 1 << 20 != 0) "waiting" else "not waiting"),
        @as(u64, found.reset),
        @as([*:0]const u8, if (found.reset & 1 != 0) "held" else "released"),
        @as(u64, found.secure),
    });
    _ = Printf(dl, "Status %08lx: firmware %s, mailbox %s; options %08lx; clock %lu then %lu (%s)\n", .{
        @as(u64, found.status),
        @as([*:0]const u8, if (found.status & 1 != 0) "runs" else "does not run"),
        @as([*:0]const u8, if (found.status & 2 != 0) "ready" else "not ready"),
        @as(u64, found.options),
        @as(u64, found.timer[0]),
        @as(u64, found.timer[1]),
        @as([*:0]const u8, if (found.timer[0] != found.timer[1]) "running" else "still"),
    });
    if (found.firmware != 0) {
        _ = Printf(dl, "Firmware %u.%u.%u\n", .{ found.firmware >> 24, found.firmware >> 16 & 0xff, found.firmware >> 8 & 0xff });
    }
    _ = Printf(dl, "Inbox  base %08lx size %lu read %lu write %lu\n", .{ @as(u64, found.inbox[0]), @as(u64, found.inbox[1]), @as(u64, found.inbox[2]), @as(u64, found.inbox[3]) });
    _ = Printf(dl, "Outbox base %08lx size %lu read %lu write %lu\n", .{ @as(u64, found.outbox[0]), @as(u64, found.outbox[1]), @as(u64, found.outbox[2]), @as(u64, found.outbox[3]) });
    for (found.windows, 0..) |window, n| {
        if (window[1] & 1 << 31 == 0) continue;
        _ = Printf(dl, "Window %u: %08lx..%08lx onto %08lx%08lx\n", .{
            @as(u32, @intCast(n)), @as(u64, window[0]), @as(u64, window[1] & 0x1fff_ffff), @as(u64, window[3]), @as(u64, window[2]),
        });
    }
    _ = Printf(dl, "Faults: undefined %08lx, fetch %08lx, write %08lx\n", .{ @as(u64, found.faults[0]), @as(u64, found.faults[1]), @as(u64, found.faults[2]) });
}

/// A checksum as RtgAmdCrc holds it, or why there is none.
fn printCrc(dl: *DosBase, name: [*:0]const u8, result: isize, found: *const rtg.tags.RtgAmdCrc) void {
    if (result != rtg.errors.RTGERR_OK) {
        _ = Printf(dl, "%s: no checksum, error %ld\n", .{ name, @as(i64, result) });
        return;
    }
    _ = Printf(dl, "%s: pipe %u red %04x green %04x blue %04x%s\n", .{
        name,                                                                         found.pipe, found.red, found.green, found.blue,
        @as([*:0]const u8, if (found.started != 0) " (summing switched on)" else ""),
    });
}

/// The hot-plug lines' and the controller's events, listened to the first
/// time with the watchdog armed, and printed.
fn events(sys: *ExecBase, dl: *DosBase, millis: u32, line: u32) i32 {
    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);
    const board = amdBoard(dl, rb) orelse return dos.RETURN_WARN;
    const wb = arm(sys, dl, millis) orelse return dos.RETURN_FAIL;
    var found: rtg.tags.RtgAmdEvents = .{ .poke = line };
    const result = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_EVENTS, @bitCast(@intFromPtr(&found)));
    wb.DisarmWatchdog();
    if (result != rtg.errors.RTGERR_OK) {
        _ = Printf(dl, "No events: error %ld\n", .{@as(i64, result)});
        return dos.RETURN_ERROR;
    }
    _ = Printf(dl, "Hot-plug lines %s, %u interrupts\n", .{
        @as([*:0]const u8, if (found.lines_heard != 0) "listened to" else "not listened to"), found.hot_plug_interrupts,
    });
    for (0..rtg.tags.RTG_AMD_HOT_PLUG_LINES) |index| {
        const status = found.line_status[index];
        _ = Printf(dl, "  line %u: %s, %s, %u changes (status %08lx, control %08lx)\n", .{
            @as(u32, @intCast(index + 1)),
            @as([*:0]const u8, if (found.line_control[index] & 1 << 28 != 0) "on" else "off"),
            @as([*:0]const u8, if (status & 1 << 4 != 0) "a monitor" else "nothing"),
            found.line_changes[index],
            @as(u64, status),
            @as(u64, found.line_control[index]),
        });
    }
    _ = Printf(dl, "The board's connector looked at %u times\n", .{found.connector_looks});
    if (found.controller_heard == 0) {
        _ = Printf(dl, "The controller is not listened to: it does not run (DMCUB START starts it)\n", .{});
    } else {
        _ = Printf(dl, "Controller: %u interrupts, %u notifications - %u AUX replies, %u hot plugs, %u others\n", .{
            found.controller_interrupts, found.notes, found.aux_replies, found.hot_plug_notes, found.other_notes,
        });
    }
    return dos.RETURN_OK;
}

/// One AUX read with the watchdog armed, and printed.
fn auxRead(sys: *ExecBase, dl: *DosBase, millis: u32, request: *rtg.tags.RtgAmdAux) i32 {
    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);
    const board = amdBoard(dl, rb) orelse return dos.RETURN_WARN;
    const wb = arm(sys, dl, millis) orelse return dos.RETURN_FAIL;
    const result = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_AUX, @bitCast(@intFromPtr(request)));
    wb.DisarmWatchdog();
    if (result != rtg.errors.RTGERR_OK) {
        _ = Printf(dl, "No reply: error %ld%s\n", .{
            @as(i64, result),
            @as([*:0]const u8, if (result == rtg.errors.RTGERR_NOT_SUPPORTED) " - the controller does not run (DMCUB START starts it)" else ""),
        });
        return dos.RETURN_ERROR;
    }
    const results = [_][*:0]const u8{ "replied", "an unknown failure", "a reply that could not be read", "no reply in time", "nothing plugged in", "the channel busy", "refused", "a broken reply" };
    _ = Printf(dl, "AUX %u at %lx: %s, reply %x, %u bytes\n", .{
        request.instance,
        @as(u64, request.address),
        results[@min(request.result, results.len - 1)],
        request.reply,
        request.replied,
    });
    if (request.replied != 0) {
        for (request.data[0..request.replied]) |byte| _ = Printf(dl, " %02x", .{@as(u32, byte)});
        _ = Printf(dl, "\n", .{});
    }
    _ = Printf(dl, "Channel found: control %08lx arbitration %08lx status %08lx receive %08lx\n", .{
        @as(u64, request.found[0]), @as(u64, request.found[1]), @as(u64, request.found[2]), @as(u64, request.found[3]),
    });
    _ = Printf(dl, "Channel after: control %08lx arbitration %08lx status %08lx receive %08lx\n", .{
        @as(u64, request.after[0]), @as(u64, request.after[1]), @as(u64, request.after[2]), @as(u64, request.after[3]),
    });
    return if (request.result == rtg.tags.RTG_AMD_AUX_OK) dos.RETURN_OK else dos.RETURN_WARN;
}

/// A monitor's EDID read with the watchdog armed, and printed.
fn edidRead(sys: *ExecBase, dl: *DosBase, millis: u32, request: *rtg.tags.RtgAmdEdid) i32 {
    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);
    const board = amdBoard(dl, rb) orelse return dos.RETURN_WARN;
    const wb = arm(sys, dl, millis) orelse return dos.RETURN_FAIL;
    const result = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_EDID, @bitCast(@intFromPtr(request)));
    wb.DisarmWatchdog();
    if (result == rtg.errors.RTGERR_BAD_ARG) {
        _ = Printf(dl, "No connector %u\n", .{request.connector});
        return dos.RETURN_ERROR;
    }
    _ = Printf(dl, "Connector: kind %u, DDC line %u, hot-plug line %u (0 for none), %s\n", .{
        request.kind,
        if (request.ddc_line == 0xFF) @as(u32, 0) else request.ddc_line + 1,
        if (request.hpd_line == 0xFF) @as(u32, 0) else request.hpd_line + 1,
        @as([*:0]const u8, if (request.present != 0) "a monitor sensed" else "no monitor sensed"),
    });
    if (result == rtg.errors.RTGERR_NOT_SUPPORTED) {
        _ = Printf(dl, "Its monitor is not read here: a connector of another kind, or no engine for its DDC line\n", .{});
        return dos.RETURN_WARN;
    }
    if (result != rtg.errors.RTGERR_OK) {
        _ = Printf(dl, "No read: error %ld\n", .{@as(i64, result)});
        return dos.RETURN_ERROR;
    }
    const read_ok = if (request.kind == amdgpu.GPUCONNECTOR_DISPLAYPORT) request.result == rtg.tags.RTG_AMD_AUX_OK and request.answer == 0 else request.result == rtg.tags.RTG_AMD_DDC_OK;
    if (request.kind == amdgpu.GPUCONNECTOR_DISPLAYPORT) {
        const results = [_][*:0]const u8{ "read", "an unknown failure", "a reply that could not be read", "no reply in time", "nothing plugged in", "the channel busy", "refused", "a broken reply" };
        _ = Printf(dl, "EDID over AUX: %s, answer %x, %u bytes\n", .{ results[@min(request.result, results.len - 1)], request.answer, request.bytes });
        const names = [_][*:0]const u8{ "control", "arbitration", "status", "receive" };
        for (names, 0..) |name, index| {
            _ = Printf(dl, "  %-12s %08lx -> %08lx\n", .{ name, @as(u64, request.found[index]), @as(u64, request.after[index]) });
        }
    } else {
        const results = [_][*:0]const u8{ "read", "the engine taken", "no answer", "no end in time", "the engine gave up", "too long for the engine" };
        _ = Printf(dl, "EDID: %s, %u bytes\n", .{ results[@min(request.result, results.len - 1)], request.bytes });
        const names = [_][*:0]const u8{ "control", "arbitration", "status", "line status", "speed", "setup", "time base", "pads" };
        for (names, 0..) |name, index| {
            _ = Printf(dl, "  %-12s %08lx -> %08lx\n", .{ name, @as(u64, request.found[index]), @as(u64, request.after[index]) });
        }
    }
    if (request.bytes < 128) return if (read_ok) dos.RETURN_OK else dos.RETURN_WARN;
    const edid = request.edid[0..request.bytes];
    // The maker's three letters, five bits each from 'A' less one; the
    // product's number, little-endian; the year from 1990.
    const maker: u16 = @as(u16, edid[8]) << 8 | edid[9];
    const letters = [4]u8{ @intCast('@' + (maker >> 10 & 0x1f)), @intCast('@' + (maker >> 5 & 0x1f)), @intCast('@' + (maker & 0x1f)), 0 };
    _ = Printf(dl, "Monitor %s %04x, made %u, EDID %u.%u, %u extension(s)\n", .{
        @as([*:0]const u8, @ptrCast(&letters)),
        @as(u32, edid[10]) | @as(u32, edid[11]) << 8,
        @as(u32, edid[17]) + 1990,
        @as(u32, edid[18]),
        @as(u32, edid[19]),
        @as(u32, edid[126]),
    });
    var row: usize = 0;
    while (row < edid.len) : (row += 16) {
        _ = Printf(dl, "  %03x:", .{@as(u32, @intCast(row))});
        for (edid[row..][0..16]) |byte| _ = Printf(dl, " %02x", .{@as(u32, byte)});
        _ = Printf(dl, "\n", .{});
    }
    return if (read_ok) dos.RETURN_OK else dos.RETURN_WARN;
}

/// The picture's checksum read with the watchdog armed, and printed.
fn checksum(sys: *ExecBase, dl: *DosBase, millis: u32) i32 {
    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);
    const board = amdBoard(dl, rb) orelse return dos.RETURN_WARN;
    const wb = arm(sys, dl, millis) orelse return dos.RETURN_FAIL;
    var found: rtg.tags.RtgAmdCrc = .{};
    const result = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_CRC, @bitCast(@intFromPtr(&found)));
    wb.DisarmWatchdog();
    printCrc(dl, "Picture", result, &found);
    return if (result == rtg.errors.RTGERR_OK) dos.RETURN_OK else dos.RETURN_ERROR;
}

/// The display's pipe taken down and up again (RTGCTRL_AMD_PIPE), the
/// watchdog armed, the picture's checksum read before and after; printed.
fn pipeCycle(sys: *ExecBase, dl: *DosBase, millis: u32) i32 {
    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);
    const board = amdBoard(dl, rb) orelse return dos.RETURN_WARN;
    const wb = arm(sys, dl, millis) orelse return dos.RETURN_FAIL;
    var before: rtg.tags.RtgAmdCrc = .{};
    var crc_before = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_CRC, @bitCast(@intFromPtr(&before)));
    // A picture that changes by itself - a clock's seconds - is waited
    // for to change and then to hold, so that the pipe is down and up
    // again before it changes next.
    var waited: u32 = 0;
    var changed = false;
    var held: u32 = 0;
    while (crc_before == rtg.errors.RTGERR_OK and waited < change_wait_ticks) : (waited += 1) {
        dl.Delay(1);
        var now: rtg.tags.RtgAmdCrc = .{};
        crc_before = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_CRC, @bitCast(@intFromPtr(&now)));
        if (now.red == before.red and now.green == before.green and now.blue == before.blue) {
            held += 1;
            if (changed and held == held_ticks) break;
            continue;
        }
        before = now;
        changed = true;
        held = 0;
    }
    var request: rtg.tags.RtgAmdPipe = .{};
    const result = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_PIPE, @bitCast(@intFromPtr(&request)));
    var after: rtg.tags.RtgAmdCrc = .{};
    const crc_after = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_CRC, @bitCast(@intFromPtr(&after)));
    wb.DisarmWatchdog();
    const stages = [_][*:0]const u8{
        "nothing done",                 "the stream taken",     "the monitor muted",
        "the timing generator stopped", "the front end let go", "the PHY off",
        "down",                         "the clocks on",        "the timing generator started",
        "the stream set up",            "the PHY on",           "up",
    };
    _ = Printf(dl, "Cycle: error %ld, %s\n", .{ @as(i64, result), stages[@min(request.stage, stages.len - 1)] });
    if (request.stage >= rtg.tags.RTG_AMD_PIPE_TAKEN) {
        const link: [*:0]const u8 = if (request.link == rtg.tags.RTG_AMD_LINK_HDMI) "HDMI" else "DVI";
        const bits = [_]u32{ 8, 10, 12, 16 };
        _ = Printf(dl, "Pipe %u, front end %u, back end %u, PHY %c: %s, %u bits a colour, pixels %u kHz, symbols %u kHz; transmitter table revision %u\n", .{
            request.pipe,                 request.front,                request.back,      'A' + request.phy,
            link,                         bits[request.deep_color & 3], request.pixel_khz, request.symbol_khz,
            request.transmitter_revision,
        });
        _ = Printf(dl, "Down and up in %u us\n", .{request.down_us});
        _ = Printf(dl, "         timing   clocks   front    fifo     back     on       hdmi     gc\n", .{});
        printPipe(dl, "before", &request.before);
        if (request.stage > rtg.tags.RTG_AMD_PIPE_TAKEN) printPipe(dl, "down", &request.down);
        if (request.stage > rtg.tags.RTG_AMD_PIPE_DOWN) printPipe(dl, "after", &request.after);
    }
    if (waited < change_wait_ticks) {
        _ = Printf(dl, "The picture changed by itself and held %u ms after %u ms, the pipe was taken down then\n", .{ held_ticks * 20, (waited + 1) * 20 });
    } else if (changed) {
        _ = Printf(dl, "The picture changed by itself and did not hold %u ms in %u ms\n", .{ held_ticks * 20, change_wait_ticks * 20 });
    } else {
        _ = Printf(dl, "The picture did not change by itself in %u ms\n", .{change_wait_ticks * 20});
    }
    printCrc(dl, "Picture before", crc_before, &before);
    printCrc(dl, "Picture after ", crc_after, &after);
    if (crc_before == rtg.errors.RTGERR_OK and crc_after == rtg.errors.RTGERR_OK) {
        const same = before.red == after.red and before.green == after.green and before.blue == after.blue;
        _ = Printf(dl, "The picture is %s\n", .{@as([*:0]const u8, if (same) "unchanged" else "CHANGED")});
    }
    return if (result == rtg.errors.RTGERR_OK) dos.RETURN_OK else dos.RETURN_ERROR;
}

/// MODES: the board put in each mode it offers, in turn, a picture of
/// the mode's own shown in it, what the set did and the checksum printed,
/// each held `seconds`; then back in the mode it was in, showing
/// what it showed.
fn everyMode(sys: *ExecBase, dl: *DosBase, millis: u32, seconds: u32) i32 {
    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);
    const board = amdBoard(dl, rb) orelse return dos.RETURN_WARN;
    const wb = arm(sys, dl, millis) orelse return dos.RETURN_FAIL;
    defer wb.DisarmWatchdog();

    // The board's line applied as it stands: its modes made again.
    var line: rtg.RtgSettings = .{};
    _ = rb.GetBoardSettings(board, &line, @sizeOf(rtg.RtgSettings));
    _ = rb.SetBoardSettings(board, &line);
    wb.FeedWatchdog();
    var list: [modes_most]rtg.RtgMode = undefined;
    const count = @min(rb.GetBoardModes(board, &list, modes_most), modes_most);
    var was: u32 = 0;
    for (list[0..count]) |*one| {
        if (one.flags & rtg.modes.RTGMF_CURRENT != 0) was = one.id;
    }
    const before = rb.BoardDisplayBitMap(board);
    _ = Printf(dl, "%u modes\n", .{count});

    var failed: u32 = 0;
    // A picture is given back once another is shown: the board does not
    // let go of the one it reads.
    var shown_before: ?*rtg.RtgBitMap = null;
    defer if (shown_before) |last| rb.FreeBitMap(last);
    for (list[0..count]) |*one| {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) break;
        const name: [*:0]const u8 = @ptrCast(&one.name);
        _ = Printf(dl, "%-14s %4ux%-4u %3u.%03u Hz %6u kHz: ", .{ name, one.width, one.height, one.refresh_mhz / 1000, one.refresh_mhz % 1000, one.pixel_clock_hz / 1000 });
        const picture = rb.AllocBitMap(board, one.width, one.height, @intFromEnum(one.format), rtg.bitmaps.RTGBMF_DISPLAYABLE) orelse {
            _ = Printf(dl, "no room for its picture\n", .{});
            failed += 1;
            continue;
        };
        bars(picture);
        _ = rb.RefreshRect(picture, null);

        var account_before: rtg.tags.RtgAmdPipe = .{};
        _ = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_MODE, @bitCast(@intFromPtr(&account_before)));
        const band = [_]rtg.RtgBand{.{ .bitmap = picture }};
        const shown = rb.ShowBoard(board, one.id, &band, band.len);
        wb.FeedWatchdog();
        if (shown == rtg.errors.RTGERR_OK) {
            if (shown_before) |old| rb.FreeBitMap(old);
            shown_before = picture;
        } else {
            rb.FreeBitMap(picture);
        }
        var account: rtg.tags.RtgAmdPipe = .{};
        _ = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_MODE, @bitCast(@intFromPtr(&account)));
        if (shown != rtg.errors.RTGERR_OK) {
            _ = Printf(dl, "not shown: %s, set stopped at stage %u\n", .{ rb.RtgErrorText(shown), account.stage });
            failed += 1;
            continue;
        }
        if (sameAccount(&account_before, &account)) {
            _ = Printf(dl, "the mode the pipe scanned, not set; ", .{});
        } else {
            const link: [*:0]const u8 = if (account.link == rtg.tags.RTG_AMD_LINK_HDMI) "HDMI" else "DVI";
            _ = Printf(dl, "set on %s at %u kHz, down %u us%s; ", .{
                link,
                account.pixel_khz,
                account.down_us,
                @as([*:0]const u8, if (account.underflow & rtg.tags.RTG_AMD_UNDERFLOW_FETCHER != 0) ", the fetcher ran short" else if (account.underflow != 0) ", the output ran short" else ""),
            });
            if (account.underflow != 0) failed += 1;
        }
        // Read a few frames on, then again more than a frame later.
        var first: rtg.tags.RtgAmdCrc = .{};
        var second: rtg.tags.RtgAmdCrc = .{};
        dl.Delay(8);
        const read_first = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_CRC, @bitCast(@intFromPtr(&first)));
        dl.Delay(3);
        const read_second = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_CRC, @bitCast(@intFromPtr(&second)));
        if (read_first != rtg.errors.RTGERR_OK or read_second != rtg.errors.RTGERR_OK) {
            _ = Printf(dl, "no checksum\n", .{});
        } else {
            const same = first.red == second.red and first.green == second.green and first.blue == second.blue;
            _ = Printf(dl, "checksum %04x %04x %04x%s\n", .{ second.red, second.green, second.blue, @as([*:0]const u8, if (same) "" else " CHANGING") });
            if (!same) failed += 1;
        }
        clocksLine(dl, rb, board);
        hold(dl, wb, 2 * seconds);
    }

    // The mode it was in, showing what it showed; the last picture is
    // given back after.
    if (before) |picture| {
        const band = [_]rtg.RtgBand{.{ .bitmap = picture }};
        const back = rb.ShowBoard(board, was, &band, band.len);
        if (back != rtg.errors.RTGERR_OK) _ = Printf(dl, "Not put back: %s\n", .{rb.RtgErrorText(back)});
    }
    _ = Printf(dl, "%u of %u modes failed\n", .{ failed, count });
    return if (failed == 0) dos.RETURN_OK else dos.RETURN_ERROR;
}

/// The display's clocks in a line of their own: the display clock as it
/// runs, what the board asked for it, for the pipes' clock and each pipe's
/// share and for the display controller's, and what the power manager
/// answered to each; the state that serves them. Then the hub's first
/// watermark set as it holds it, and whether it lets the memory into
/// self-refresh.
fn clocksLine(dl: *DosBase, rb: *RtgBase, board: *rtg.RtgBoard) void {
    var found: rtg.tags.RtgAmdClocks = .{};
    if (rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_CLOCKS, @bitCast(@intFromPtr(&found))) != rtg.errors.RTGERR_OK) {
        _ = Printf(dl, "    clocks not had\n", .{});
        return;
    }
    _ = Printf(dl, "    display clock %u kHz, asked %u kHz (answered %u MHz); pipes' clock asked %u kHz (%u MHz), each pipe", .{
        found.disp_khz,
        found.asked_disp_khz,
        found.answered_disp_mhz,
        found.asked_dpp_khz,
        found.answered_dpp_mhz,
    });
    for (found.asked_pipe_khz) |khz| _ = Printf(dl, " %u", .{khz});
    _ = Printf(dl, " kHz; controller at least %u kHz (%u MHz), state %u\n", .{ found.asked_dcf_khz, found.answered_dcf_mhz, found.level });
    const set = &found.hub_marks[0];
    _ = Printf(dl, "    hub set A: urgency %u, self-refresh's entry and exit %u, exit %u, the memory clock's change %u reference cycles; self-refresh %s\n", .{
        set[0],
        set[2],
        set[4],
        set[6],
        @as([*:0]const u8, if (found.self_refresh != 0) "allowed" else "forbidden"),
    });
}

/// The most modes MODES goes through.
const modes_most = 32;

/// Whether two of the board's accounts of a mode set are the same: no
/// set came between them.
fn sameAccount(a: *const rtg.tags.RtgAmdPipe, b: *const rtg.tags.RtgAmdPipe) bool {
    const left: [*]const u8 = @ptrCast(a);
    const right: [*]const u8 = @ptrCast(b);
    for (0..@sizeOf(rtg.tags.RtgAmdPipe)) |index| {
        if (left[index] != right[index]) return false;
    }
    return true;
}

/// A picture of a mode's: eight bars of colour across it and a white
/// frame round its edge, a pixel wide. In 32 bits a pixel only; another
/// format is left as it is.
fn bars(picture: *rtg.RtgBitMap) void {
    if (picture.format != .bgra32) return;
    const colours = [_]u32{ 0xFFFFFF, 0xFFFF00, 0x00FFFF, 0x00FF00, 0xFF00FF, 0xFF0000, 0x0000FF, 0x202020 };
    const pixels = picture.pixels orelse return;
    var row: u32 = 0;
    while (row < picture.height) : (row += 1) {
        const line: [*]u32 = @ptrCast(@alignCast(pixels + @as(usize, row) * picture.pitch));
        var column: u32 = 0;
        while (column < picture.width) : (column += 1) {
            const edge = row == 0 or row == picture.height - 1 or column == 0 or column == picture.width - 1;
            line[column] = 0xFF000000 | (if (edge) 0xFFFFFF else colours[@as(usize, column) * colours.len / picture.width]);
        }
    }
}

/// `length` of the display engine's registers from `first` on, counted
/// from its address `segment`, the watchdog armed; printed eight a line.
fn dump(sys: *ExecBase, dl: *DosBase, ab: *AMDGPUBase, info: amdgpu.GPUInfo, millis: u32, id: u32, segment: u32, first: u32, length: u32) i32 {
    var block: amdgpu.GPUBlock = .{};
    if (!ab.FindGPUBlock(id, 0, &block) or segment >= block.count) {
        _ = Printf(dl, "The device has no block %u with an address %u\n", .{ id, segment });
        return dos.RETURN_WARN;
    }
    const words = @min(length, dump_most);
    const end = (@as(u64, block.addresses[segment]) + first + words) * 4;
    if (end > info.registers_bytes) {
        _ = Printf(dl, "Words %u to %u from address %u are past the registers' end\n", .{ first, first + words, segment });
        return dos.RETURN_WARN;
    }
    const wb = arm(sys, dl, millis) orelse return dos.RETURN_FAIL;
    defer wb.DisarmWatchdog();
    var index: u32 = 0;
    while (index < words) : (index += 1) {
        if (index % 8 == 0) _ = Printf(dl, "%s0x%04x:", .{ @as([*:0]const u8, if (index == 0) "" else "\n"), first + index });
        const at: usize = @intCast(info.registers + (@as(u64, block.addresses[segment]) + first + index) * 4);
        _ = Printf(dl, " %08lx", .{@as(u64, reg(at).*)});
    }
    _ = Printf(dl, "\n", .{});
    return dos.RETURN_OK;
}

/// The most registers DUMP prints.
const dump_most: u32 = 512;

/// A register of the graphics block GFX and DMA print, by the vendor's
/// name: its segment and number in it.
const GraphicsRegister = struct { name: [*:0]const u8, segment: u8, offset: u32 };

/// The block's own.
const graphics_registers = [_]GraphicsRegister{
    .{ .name = "GRBM_STATUS", .segment = 0, .offset = 0x0da4 },
    .{ .name = "GRBM_STATUS2", .segment = 0, .offset = 0x0da2 },
    .{ .name = "CP_STAT", .segment = 0, .offset = 0x0f40 },
    .{ .name = "CP_ME_CNTL", .segment = 1, .offset = 0x0803 },
    .{ .name = "CP_MEC_CNTL", .segment = 1, .offset = 0x0802 },
    .{ .name = "CP_MES_CNTL", .segment = 1, .offset = 0x2807 },
    .{ .name = "RLC_CNTL", .segment = 1, .offset = 0x4c00 },
    .{ .name = "RLC_GPM_STAT", .segment = 1, .offset = 0x4e6b },
    .{ .name = "RLC_RLCS_BOOTLOAD_STATUS", .segment = 1, .offset = 0x4e7e },
    .{ .name = "GFX_IMU_CORE_STATUS", .segment = 1, .offset = 0x40b7 },
    .{ .name = "GFX_IMU_SCRATCH_0", .segment = 1, .offset = 0x4068 },
    .{ .name = "SDMA0_F32_CNTL", .segment = 1, .offset = 0x589a },
};

/// Its memory hub's.
const hub_registers = [_]GraphicsRegister{
    .{ .name = "GCMC_VM_FB_LOCATION_BASE", .segment = 0, .offset = 0x1678 },
    .{ .name = "GCMC_VM_FB_LOCATION_TOP", .segment = 0, .offset = 0x1679 },
    .{ .name = "GCMC_VM_FB_OFFSET", .segment = 0, .offset = 0x15a7 },
    .{ .name = "GCMC_VM_SYSTEM_APERTURE_LOW_ADDR", .segment = 0, .offset = 0x167d },
    .{ .name = "GCMC_VM_SYSTEM_APERTURE_HIGH_ADDR", .segment = 0, .offset = 0x167e },
    .{ .name = "GCMC_VM_MX_L1_TLB_CNTL", .segment = 0, .offset = 0x167f },
    .{ .name = "GCVM_L2_CNTL", .segment = 0, .offset = 0x15bc },
    .{ .name = "GCVM_L2_CNTL3", .segment = 0, .offset = 0x15be },
    .{ .name = "GCVM_L2_PROTECTION_FAULT_CNTL", .segment = 0, .offset = 0x15c4 },
    .{ .name = "GCVM_L2_PROTECTION_FAULT_STATUS", .segment = 0, .offset = 0x15c8 },
    .{ .name = "GCVM_CONTEXT0_CNTL", .segment = 0, .offset = 0x1688 },
    .{ .name = "GCVM_CONTEXT0_PAGE_TABLE_BASE_ADDR_LO32", .segment = 0, .offset = 0x16f3 },
    .{ .name = "GCVM_CONTEXT0_PAGE_TABLE_BASE_ADDR_HI32", .segment = 0, .offset = 0x16f4 },
    .{ .name = "GCVM_CONTEXT0_PAGE_TABLE_START_ADDR_LO32", .segment = 0, .offset = 0x1713 },
    .{ .name = "GCVM_CONTEXT0_PAGE_TABLE_END_ADDR_LO32", .segment = 0, .offset = 0x1733 },
};

/// Its DMA engine's.
const dma_registers = [_]GraphicsRegister{
    .{ .name = "SDMA0_F32_CNTL", .segment = 1, .offset = 0x589a },
    .{ .name = "SDMA0_CNTL", .segment = 0, .offset = 0x001c },
    .{ .name = "SDMA0_STATUS_REG", .segment = 0, .offset = 0x0025 },
    .{ .name = "SDMA0_UTCL1_CNTL", .segment = 0, .offset = 0x003c },
    .{ .name = "SDMA0_UTCL1_PAGE", .segment = 0, .offset = 0x003f },
    .{ .name = "SDMA0_QUEUE0_RB_CNTL", .segment = 0, .offset = 0x0080 },
    .{ .name = "SDMA0_QUEUE0_RB_BASE", .segment = 0, .offset = 0x0081 },
    .{ .name = "SDMA0_QUEUE0_RB_RPTR", .segment = 0, .offset = 0x0083 },
    .{ .name = "SDMA0_QUEUE0_RB_WPTR", .segment = 0, .offset = 0x0085 },
    .{ .name = "SDMA0_QUEUE0_RB_RPTR_ADDR_LO", .segment = 0, .offset = 0x0089 },
    .{ .name = "SDMA0_QUEUE0_IB_CNTL", .segment = 0, .offset = 0x008a },
    .{ .name = "SDMA0_QUEUE0_CONTEXT_STATUS", .segment = 0, .offset = 0x0091 },
};

/// How long DMA waits for each job, and how many empty jobs it sends one
/// after another, each waited for.
const dma_job_ms: u32 = 2000;
const dma_round_trips: u32 = 100;
/// The fill DMA reads back: its bytes, between guards of a page each way
/// that the engine must leave as they are, and what each holds.
const fill_bytes: u32 = 64 * 1024;
const guard_bytes: u32 = 4096;
const fill_value: u32 = 0x1234_5678;
const guard_value: u32 = 0xA5A5_A5A5;
/// The long fill, and the shorter one where the device's memory has no
/// room for it.
const long_fills = [_]u32{ 64 << 20, 16 << 20 };

fn graphicsAt(info: amdgpu.GPUInfo, block: amdgpu.GPUBlock, register: GraphicsRegister) *volatile u32 {
    return reg(@intCast(info.registers + (@as(u64, block.addresses[register.segment]) + register.offset) * 4));
}

fn printGraphics(dl: *DosBase, info: amdgpu.GPUInfo, block: amdgpu.GPUBlock, registers: []const GraphicsRegister) void {
    for (registers) |register| {
        _ = Printf(dl, "  %-40s %08lx\n", .{ register.name, @as(u64, graphicsAt(info, block, register).*) });
    }
}

/// The graphics block's firmware file `suffix` of the block `block`,
/// read into `into`: false, with why said, where it cannot be - unless
/// `may_lack`, which leaves `into` empty.
fn graphicsFile(sys: *ExecBase, dl: *DosBase, prefix: []const u8, block: amdgpu.GPUBlock, suffix: []const u8, may_lack: bool, into: *amdgpu.GPUFile) bool {
    const name = Name.of(prefix, block, suffix);
    if (may_lack) {
        var length: usize = 0;
        const bytes = dl.ReadFile(name.string(), ~@as(usize, 0), exec.MEMF_ANY, &length) orelse {
            _ = Printf(dl, "%s: none, the machine's own is used\n", .{name.string()});
            return true;
        };
        into.* = .{ .image = bytes, .bytes = @intCast(length) };
    } else {
        const file = readFile(sys, dl, name.string()) orelse return false;
        into.* = .{ .image = file.ptr, .bytes = @intCast(file.len) };
    }
    _ = Printf(dl, "%s: %u bytes\n", .{ name.string(), into.bytes });
    return true;
}

/// The registers the vendor's settings for the block go into, and two of
/// its constants: the registers' read timeout and the occlusion counters'
/// split.
const settings_registers = [_]GraphicsRegister{
    .{ .name = "CGTT_GS_NGG_CLK_CTRL", .segment = 1, .offset = 0x5087 },
    .{ .name = "CGTT_WD_CLK_CTRL", .segment = 1, .offset = 0x5086 },
    .{ .name = "CPF_GCR_CNTL", .segment = 0, .offset = 0x1f53 },
    .{ .name = "GL2C_CTRL3", .segment = 1, .offset = 0x2e0c },
    .{ .name = "PA_CL_ENHANCE", .segment = 0, .offset = 0x1025 },
    .{ .name = "PA_SC_ENHANCE_3", .segment = 1, .offset = 0x0944 },
    .{ .name = "PA_SC_VRS_SURFACE_CNTL_1", .segment = 1, .offset = 0x0960 },
    .{ .name = "TA_CNTL_AUX", .segment = 0, .offset = 0x12e2 },
    .{ .name = "TCP_CNTL2", .segment = 1, .offset = 0x19a3 },
    .{ .name = "TCP_CNTL", .segment = 1, .offset = 0x19a2 },
    .{ .name = "GRBM_CNTL", .segment = 0, .offset = 0x0da0 },
    .{ .name = "DB_RING_CONTROL", .segment = 0, .offset = 0x13bb },
};

/// Its clock gating's: the overrides that keep each kind of it off, the
/// coarse-grain gating's control, and the power gating's, which is left
/// off.
const gating_registers = [_]GraphicsRegister{
    .{ .name = "RLC_CGTT_MGCG_OVERRIDE", .segment = 1, .offset = 0x4c48 },
    .{ .name = "RLC_CGCG_CGLS_CTRL", .segment = 1, .offset = 0x4c49 },
    .{ .name = "RLC_PG_CNTL", .segment = 1, .offset = 0x4c43 },
};

/// The graphics block's clock and the data fabric's, as the power
/// manager reads them; 0 where it does not answer.
fn printClocks(dl: *DosBase, ab: *AMDGPUBase) void {
    _ = Printf(dl, "  the graphics block's clock %u MHz, the data fabric's %u MHz\n", .{
        ab.GetGPUClock(amdgpu.GPUCLOCK_GRAPHICS), ab.GetGPUClock(amdgpu.GPUCLOCK_FABRIC),
    });
}

/// What GFX, DMA, GART, ENGINE and COMPUTE go on to once the block is
/// started.
const GraphicsThen = enum { nothing, dma, gart, engine, compute };

/// The graphics block's firmware loaded, the block started and its hub
/// turned on, its registers printed before and after - and then its DMA
/// engine's queue started and tried, on the device's memory or on the
/// machine's, or its compute engine's, as `then` says.
fn graphicsStart(sys: *ExecBase, dl: *DosBase, ab: *AMDGPUBase, info: amdgpu.GPUInfo, millis: u32, then: GraphicsThen) i32 {
    var graphics: amdgpu.GPUBlock = .{};
    var dma: amdgpu.GPUBlock = .{};
    var security: amdgpu.GPUBlock = .{};
    if (!ab.FindGPUBlock(amdgpu.GPUBLOCK_GRAPHICS, 0, &graphics) or graphics.count < 2 or
        !ab.FindGPUBlock(amdgpu.GPUBLOCK_DMA, 0, &dma) or !ab.FindGPUBlock(amdgpu.GPUBLOCK_SECURITY, 0, &security))
    {
        _ = Printf(dl, "The device %04x:%04x names no graphics block, DMA engine or security processor\n", .{ info.vendor, info.device });
        return dos.RETURN_FAIL;
    }
    _ = Printf(dl, "Graphics block %u.%u.%u, its DMA engine %u.%u.%u, security processor %u.%u.%u\n", .{
        @as(u32, graphics.major), @as(u32, graphics.minor), @as(u32, graphics.revision),
        @as(u32, dma.major),      @as(u32, dma.minor),      @as(u32, dma.revision),
        @as(u32, security.major), @as(u32, security.minor), @as(u32, security.revision),
    });

    var files: amdgpu.GPUGraphicsFiles = .{};
    defer for ([_]amdgpu.GPUFile{ files.pfp, files.me, files.mec, files.rlc, files.mes, files.mes_kiq, files.imu, files.dma }) |file| {
        if (file.image) |image| sys.FreeVec(@constCast(image));
    };
    const read_all = graphicsFile(sys, dl, "gc_", graphics, "_pfp.bin", false, &files.pfp) and
        graphicsFile(sys, dl, "gc_", graphics, "_me.bin", false, &files.me) and
        graphicsFile(sys, dl, "gc_", graphics, "_mec.bin", false, &files.mec) and
        graphicsFile(sys, dl, "gc_", graphics, "_rlc.bin", false, &files.rlc) and
        graphicsFile(sys, dl, "gc_", graphics, "_mes_2.bin", false, &files.mes) and
        graphicsFile(sys, dl, "gc_", graphics, "_mes1.bin", false, &files.mes_kiq) and
        graphicsFile(sys, dl, "gc_", graphics, "_imu.bin", true, &files.imu) and
        graphicsFile(sys, dl, "sdma_", dma, ".bin", false, &files.dma);
    if (!read_all) return dos.RETURN_ERROR;
    const toc_name = Name.of("psp_", security, "_toc.bin");
    const toc = readFile(sys, dl, toc_name.string()) orelse return dos.RETURN_ERROR;
    defer sys.FreeVec(toc.ptr);

    const wb = arm(sys, dl, millis) orelse return dos.RETURN_FAIL;
    defer wb.DisarmWatchdog();
    if (!ab.StartGPUSecurity(toc.ptr, @intCast(toc.len))) {
        _ = Printf(dl, "The security processor is not ready: see C:Log\n", .{});
        return dos.RETURN_ERROR;
    }
    wb.FeedWatchdog();
    if (!ab.SetGPUPower(amdgpu.GPUPOWER_GRAPHICS, 0, true)) {
        _ = Printf(dl, "The power manager does not keep the graphics block powered: see C:Log\n", .{});
        return dos.RETURN_ERROR;
    }
    wb.FeedWatchdog();
    _ = Printf(dl, "The graphics block kept powered; its registers:\n", .{});
    printGraphics(dl, info, graphics, &graphics_registers);

    const started_at = sys.UptimeUs();
    if (!ab.StartGPUGraphics(&files)) {
        wb.FeedWatchdog();
        _ = Printf(dl, "The graphics block's firmware is not loaded, the block not started or its hub not on: see C:Log\n", .{});
        printGraphics(dl, info, graphics, &graphics_registers);
        printGraphics(dl, info, graphics, &hub_registers);
        return dos.RETURN_ERROR;
    }
    wb.FeedWatchdog();
    _ = Printf(dl, "Its firmware loaded, the block started and its hub on in %lu ms; its registers:\n", .{(sys.UptimeUs() - started_at) / 1000});
    printGraphics(dl, info, graphics, &graphics_registers);
    _ = Printf(dl, "Its memory hub's:\n", .{});
    printGraphics(dl, info, graphics, &hub_registers);
    _ = Printf(dl, "The vendor's settings it was given:\n", .{});
    printGraphics(dl, info, graphics, &settings_registers);
    _ = Printf(dl, "Its clock gating's, and the clocks:\n", .{});
    printGraphics(dl, info, graphics, &gating_registers);
    printClocks(dl, ab);
    dl.Delay(50);
    wb.FeedWatchdog();
    _ = Printf(dl, "After a second idle:\n", .{});
    printClocks(dl, ab);
    return switch (then) {
        .nothing => dos.RETURN_OK,
        .dma => dmaCheck(sys, dl, ab, info, graphics, wb),
        .gart => gartCheck(sys, dl, ab, info, graphics, wb),
        .engine => engineCheck(sys, dl, ab, info, graphics, wb),
        .compute => computeCheck(sys, dl, ab, info, graphics, wb),
    };
}

/// The DMA engine's queue as it is, on one line.
fn printQueue(dl: *DosBase, ab: *AMDGPUBase) void {
    var state: amdgpu.GPUDMAState = .{};
    if (!ab.GetGPUDMAState(&state)) {
        _ = Printf(dl, "  its queue does not run\n", .{});
        return;
    }
    _ = Printf(dl, "  its queue: %u jobs sent, %u done, %u interrupts; read to %lx of %lx; status %08x\n", .{
        state.sent, state.done, state.traps, state.read, state.written, state.status,
    });
}

/// What `what` failed of the DMA engine, said with its queue and its
/// registers.
fn dmaFailed(dl: *DosBase, ab: *AMDGPUBase, info: amdgpu.GPUInfo, graphics: amdgpu.GPUBlock, what: [*:0]const u8) i32 {
    _ = Printf(dl, "%s: not done\n", .{what});
    printQueue(dl, ab);
    printGraphics(dl, info, graphics, &dma_registers);
    printGraphics(dl, info, graphics, &hub_registers);
    return dos.RETURN_ERROR;
}

/// The words of a piece of the device's memory, as the CPU reaches them.
fn wordsOf(piece: amdgpu.GPUMemory) [*]volatile u32 {
    return @ptrFromInt(@as(usize, @intCast(piece.cpu)));
}

/// What a fill between guards left: the first filled word, how many of
/// the filled words are the same as it, and how many of the guards' words
/// still hold `guard_value`.
const FillSeen = struct { filled: u32, alike: u32, kept: u32 };

fn fillSeen(words: [*]volatile u32, count: u32, guard_words: u32) FillSeen {
    var seen: FillSeen = .{ .filled = words[guard_words], .alike = 0, .kept = 0 };
    for (guard_words..count - guard_words) |index| {
        if (words[index] == seen.filled) seen.alike += 1;
    }
    for (0..guard_words) |index| {
        if (words[index] == guard_value) seen.kept += 1;
        if (words[count - 1 - index] == guard_value) seen.kept += 1;
    }
    return seen;
}

/// A constant fill of `bytes` at the device's address `device`, in words
/// or with the fill's size 0.
fn fillPacket(device: u64, bytes: u32, value: u32, size: u32) [5]u32 {
    return .{ amdgpu.GPUDMA_OP_CONST_FILL | size, @truncate(device), @truncate(device >> 32), value, bytes - 1 };
}

/// The DMA engine's queue started and tried: NOPs, empty jobs one after
/// another, a fill read back between guards, and a long fill.
fn dmaCheck(sys: *ExecBase, dl: *DosBase, ab: *AMDGPUBase, info: amdgpu.GPUInfo, graphics: amdgpu.GPUBlock, wb: *WatchdogBase) i32 {
    if (!ab.StartGPUDMA()) {
        wb.FeedWatchdog();
        _ = Printf(dl, "The DMA engine's queue does not run: see C:Log; its registers:\n", .{});
        printGraphics(dl, info, graphics, &dma_registers);
        return dos.RETURN_ERROR;
    }
    wb.FeedWatchdog();
    var state: amdgpu.GPUDMAState = .{};
    _ = ab.GetGPUDMAState(&state);
    _ = Printf(dl, "The DMA engine's queue runs: its ring at %lx, %u bytes\n", .{ state.ring, state.ring_bytes });
    printQueue(dl, ab);

    const nops = [_]u32{amdgpu.GPUDMA_OP_NOP} ** 8;
    var began = sys.UptimeUs();
    const first = ab.SendGPUDMA(&nops, nops.len);
    if (first == 0 or !ab.WaitGPUDMA(first, dma_job_ms)) return dmaFailed(dl, ab, info, graphics, "Eight NOPs");
    _ = Printf(dl, "Eight NOPs: job %u done in %lu us\n", .{ first, sys.UptimeUs() - began });
    wb.FeedWatchdog();

    _ = ab.GetGPUDMAState(&state);
    var traps = state.traps;
    began = sys.UptimeUs();
    var trip: u32 = 0;
    while (trip < dma_round_trips) : (trip += 1) {
        const job = ab.SendGPUDMA(&nops, 0);
        if (job == 0 or !ab.WaitGPUDMA(job, dma_job_ms)) return dmaFailed(dl, ab, info, graphics, "An empty job");
    }
    const trips_us = sys.UptimeUs() - began;
    _ = ab.GetGPUDMAState(&state);
    _ = Printf(dl, "%u empty jobs, each sent and waited for: %lu us in all, %lu us each; %u of the engine's interrupts\n", .{
        dma_round_trips, trips_us, trips_us / dma_round_trips, state.traps -% traps,
    });
    wb.FeedWatchdog();

    var all_right = true;
    var piece: amdgpu.GPUMemory = .{};
    const piece_bytes = fill_bytes + 2 * guard_bytes;
    if (!ab.AllocGPUMemory(piece_bytes, 4096, &piece)) {
        _ = Printf(dl, "No room in the device's memory for %u bytes\n", .{piece_bytes});
        return dos.RETURN_ERROR;
    }
    defer ab.FreeGPUMemory(&piece);
    const words = wordsOf(piece);
    const count = piece_bytes / 4;
    const guard_words = guard_bytes / 4;
    for ([_]u32{ 0, amdgpu.GPUDMA_FILL_WORDS }) |size| {
        for (0..count) |index| words[index] = guard_value;
        const fill = fillPacket(piece.device + guard_bytes, fill_bytes, fill_value, size);
        began = sys.UptimeUs();
        const job = ab.SendGPUDMA(&fill, fill.len);
        if (job == 0 or !ab.WaitGPUDMA(job, dma_job_ms)) return dmaFailed(dl, ab, info, graphics, "A fill");
        const took = sys.UptimeUs() - began;
        const seen = fillSeen(words, count, guard_words);
        const expected = if (size == amdgpu.GPUDMA_FILL_WORDS) fill_value else (fill_value & 0xff) * 0x0101_0101;
        _ = Printf(dl, "A fill of %u bytes with %08x, size %u: done in %lu us; %u of its %u words %08x (%08x meant), %u of the guards' %u kept\n", .{
            fill_bytes, fill_value, size >> 30, took, seen.alike, fill_bytes / 4, seen.filled, expected, seen.kept, 2 * guard_words,
        });
        if (seen.filled != expected or seen.alike != fill_bytes / 4 or seen.kept != 2 * guard_words) all_right = false;
        wb.FeedWatchdog();
    }

    for (long_fills) |bytes| {
        var long: amdgpu.GPUMemory = .{};
        if (!ab.AllocGPUMemory(bytes, 4096, &long)) {
            _ = Printf(dl, "No room in the device's memory for %u MiB\n", .{bytes >> 20});
            continue;
        }
        defer ab.FreeGPUMemory(&long);
        const long_words = wordsOf(long);
        const last = bytes / 4 - 1;
        long_words[0] = guard_value;
        long_words[last / 2] = guard_value;
        long_words[last] = guard_value;
        const fill = fillPacket(long.device, bytes, fill_value, amdgpu.GPUDMA_FILL_WORDS);
        _ = ab.GetGPUDMAState(&state);
        traps = state.traps;
        began = sys.UptimeUs();
        const job = ab.SendGPUDMA(&fill, fill.len);
        if (job == 0 or !ab.WaitGPUDMA(job, dma_job_ms)) return dmaFailed(dl, ab, info, graphics, "The long fill");
        const took = @max(1, sys.UptimeUs() - began);
        _ = ab.GetGPUDMAState(&state);
        _ = Printf(dl, "A fill of %u MiB in words: done in %lu us, %lu MB/s; its first, middle and last words %08x %08x %08x; %u interrupts\n", .{
            bytes >> 20, took, @as(u64, bytes) / took, long_words[0], long_words[last / 2], long_words[last], state.traps -% traps,
        });
        if (long_words[0] != fill_value or long_words[last / 2] != fill_value or long_words[last] != fill_value) all_right = false;
        wb.FeedWatchdog();
        break;
    }

    _ = Printf(dl, "At the end:\n", .{});
    printQueue(dl, ab);
    printGraphics(dl, info, graphics, &dma_registers);
    _ = Printf(dl, "Its memory hub's:\n", .{});
    printGraphics(dl, info, graphics, &hub_registers);
    return if (all_right) dos.RETURN_OK else dos.RETURN_WARN;
}

/// Where GART puts its buffers of the machine's memory: so many bytes
/// past a page's start, so that a mapping begins part way into a page;
/// and how much its long fill fills.
const ram_offset: usize = 100;
const ram_long_bytes: u32 = 16 << 20;
/// The values its two buffers are filled with, one each.
const first_value: u32 = 0x1111_1111;
const second_value: u32 = 0x2222_2222;

/// A buffer of the machine's memory: `bytes` from `ram_offset` past a
/// page's start, in an allocation of its own, and its words.
const RamBuffer = struct {
    allocation: *anyopaque,
    at: [*]u8,
    words: [*]volatile u32,
};

fn ramBuffer(sys: *ExecBase, bytes: u32) ?RamBuffer {
    const allocation = sys.AllocVec(bytes + 2 * 4096, exec.MEMF_ANY) orelse return null;
    const at = (@intFromPtr(allocation) + 4095 & ~@as(usize, 4095)) + ram_offset;
    return .{ .allocation = allocation, .at = @ptrFromInt(at), .words = @ptrFromInt(at) };
}

/// `buffer`'s `bytes` mapped, a fill of what lies between its guards in
/// words with `value` sent and waited for, and the mapping taken out
/// again: the device's address it was mapped at, or null with why said.
fn fillThroughMapping(dl: *DosBase, ab: *AMDGPUBase, info: amdgpu.GPUInfo, graphics: amdgpu.GPUBlock, buffer: RamBuffer, bytes: u32, value: u32) ?u64 {
    var mapped: amdgpu.GPUMemory = .{};
    if (!ab.MapGPUMemory(buffer.at, bytes, &mapped)) {
        _ = Printf(dl, "%u bytes of the machine's memory at %lx are not mapped: see C:Log\n", .{ bytes, @as(u64, @intFromPtr(buffer.at)) });
        return null;
    }
    defer ab.UnmapGPUMemory(&mapped);
    const fill = fillPacket(mapped.device + guard_bytes, bytes - 2 * guard_bytes, value, amdgpu.GPUDMA_FILL_WORDS);
    const job = ab.SendGPUDMA(&fill, fill.len);
    if (job == 0 or !ab.WaitGPUDMA(job, dma_job_ms)) {
        _ = dmaFailed(dl, ab, info, graphics, "A fill through a mapping");
        return null;
    }
    return mapped.device;
}

/// The DMA engine's queue started and tried on the machine's memory,
/// mapped into the hub's page table: a fill read back by the CPU, two
/// fills through mappings at the same place, and a long fill.
fn gartCheck(sys: *ExecBase, dl: *DosBase, ab: *AMDGPUBase, info: amdgpu.GPUInfo, graphics: amdgpu.GPUBlock, wb: *WatchdogBase) i32 {
    if (!ab.StartGPUDMA()) {
        wb.FeedWatchdog();
        _ = Printf(dl, "The DMA engine's queue does not run: see C:Log; its registers:\n", .{});
        printGraphics(dl, info, graphics, &dma_registers);
        return dos.RETURN_ERROR;
    }
    wb.FeedWatchdog();
    _ = Printf(dl, "The DMA engine's queue runs\n", .{});
    printQueue(dl, ab);

    var all_right = true;
    const piece_bytes = fill_bytes + 2 * guard_bytes;
    const count = piece_bytes / 4;
    const guard_words = guard_bytes / 4;
    const first = ramBuffer(sys, piece_bytes) orelse {
        _ = Printf(dl, "No memory for %u bytes\n", .{piece_bytes});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(first.allocation);
    const second = ramBuffer(sys, piece_bytes) orelse {
        _ = Printf(dl, "No memory for %u bytes\n", .{piece_bytes});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(second.allocation);

    for (0..count) |index| first.words[index] = guard_value;
    var began = sys.UptimeUs();
    const device = fillThroughMapping(dl, ab, info, graphics, first, piece_bytes, fill_value) orelse return dos.RETURN_ERROR;
    const took = sys.UptimeUs() - began;
    const seen = fillSeen(first.words, count, guard_words);
    _ = Printf(dl, "%u bytes of the machine's memory at %lx, mapped at %lx, filled in words with %08x and unmapped in %lu us: %u of %u words %08x, %u of the guards' %u kept\n", .{
        fill_bytes, @as(u64, @intFromPtr(first.at)), device, fill_value, took, seen.alike, fill_bytes / 4, seen.filled, seen.kept, 2 * guard_words,
    });
    if (seen.filled != fill_value or seen.alike != fill_bytes / 4 or seen.kept != 2 * guard_words) all_right = false;
    wb.FeedWatchdog();

    for (0..count) |index| {
        first.words[index] = guard_value;
        second.words[index] = guard_value;
    }
    const first_device = fillThroughMapping(dl, ab, info, graphics, first, piece_bytes, first_value) orelse return dos.RETURN_ERROR;
    const second_device = fillThroughMapping(dl, ab, info, graphics, second, piece_bytes, second_value) orelse return dos.RETURN_ERROR;
    const first_seen = fillSeen(first.words, count, guard_words);
    const second_seen = fillSeen(second.words, count, guard_words);
    _ = Printf(dl, "Two buffers filled through mappings at %lx and %lx (%s): the first %u of %u words %08x (%08x meant), the second %u of %u words %08x (%08x meant), %u and %u of the guards' %u kept\n", .{
        first_device,                                                                                      second_device,
        @as([*:0]const u8, if (first_device == second_device) "the same place" else "not the same place"), first_seen.alike,
        fill_bytes / 4,                                                                                    first_seen.filled,
        first_value,                                                                                       second_seen.alike,
        fill_bytes / 4,                                                                                    second_seen.filled,
        second_value,                                                                                      first_seen.kept,
        second_seen.kept,                                                                                  2 * guard_words,
    });
    if (first_seen.filled != first_value or first_seen.alike != fill_bytes / 4 or first_seen.kept != 2 * guard_words or
        second_seen.filled != second_value or second_seen.alike != fill_bytes / 4 or second_seen.kept != 2 * guard_words)
    {
        all_right = false;
    }
    wb.FeedWatchdog();

    const long = ramBuffer(sys, ram_long_bytes + 2 * guard_bytes) orelse {
        _ = Printf(dl, "No memory for %u MiB\n", .{ram_long_bytes >> 20});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(long.allocation);
    const last = (ram_long_bytes + 2 * guard_bytes) / 4 - 1;
    for ([_]u32{ guard_words, last / 2, last - guard_words }) |index| long.words[index] = guard_value;
    long.words[guard_words - 1] = guard_value;
    long.words[last - guard_words + 1] = guard_value;
    var state: amdgpu.GPUDMAState = .{};
    _ = ab.GetGPUDMAState(&state);
    const traps = state.traps;
    began = sys.UptimeUs();
    _ = fillThroughMapping(dl, ab, info, graphics, long, ram_long_bytes + 2 * guard_bytes, fill_value) orelse return dos.RETURN_ERROR;
    const long_took = @max(1, sys.UptimeUs() - began);
    _ = ab.GetGPUDMAState(&state);
    _ = Printf(dl, "%u MiB of the machine's memory filled through a mapping in %lu us, %lu MB/s: its first, middle and last words %08x %08x %08x, the guards beside them %08x %08x; %u interrupts\n", .{
        ram_long_bytes >> 20,        long_took,                          @as(u64, ram_long_bytes) / long_took,
        long.words[guard_words],     long.words[last / 2],               long.words[last - guard_words],
        long.words[guard_words - 1], long.words[last - guard_words + 1], state.traps -% traps,
    });
    if (long.words[guard_words] != fill_value or long.words[last / 2] != fill_value or long.words[last - guard_words] != fill_value or
        long.words[guard_words - 1] != guard_value or long.words[last - guard_words + 1] != guard_value)
    {
        all_right = false;
    }
    wb.FeedWatchdog();

    _ = Printf(dl, "At the end:\n", .{});
    printQueue(dl, ab);
    _ = Printf(dl, "Its memory hub's:\n", .{});
    printGraphics(dl, info, graphics, &hub_registers);
    return if (all_right) dos.RETURN_OK else dos.RETURN_WARN;
}

/// ENGINE's two buffers of the machine's memory: four bytes a pixel, two
/// displays of 2560 x 1440 one over the other - more than the CPU's
/// caches hold - rows of whole 256 bytes as the board makes its buffers;
/// and how many times each timed job is done.
const engine_width: u32 = 2560;
const engine_height: u32 = 2880;
const engine_pitch: u32 = engine_width * 4;
const engine_bytes: u32 = engine_pitch * engine_height;
const engine_rounds: u32 = 10;
/// The rectangles jobs are timed at - two squares, then the buffers' whole
/// width from a band to all but a scroll's rows - and the rows a scroll
/// moves by: a line of text.
const engine_sizes = [_][2]u32{ .{ 256, 256 }, .{ 1024, 1024 }, .{ 2560, 64 }, .{ 2560, 256 }, .{ 2560, 512 }, .{ 2560, 1024 }, .{ 2560, 1424 }, .{ 2560, 2048 }, .{ 2560, 2864 } };
const scroll_rows: u32 = 16;
/// The most words one of ENGINE's jobs takes - a fill of 1024 rows is
/// five words a row, a scroll of 2864 rows 179 bands - and the colour its
/// fills write.
const engine_job_words: u32 = 8192;
const engine_colour: u32 = 0xFF12_3456;

/// A pixel of the pattern ENGINE paints its buffers with, each pixel its
/// own and `seed` telling the buffers apart; and one of two bytes.
fn patternAt(x: u32, y: u32, seed: u32) u32 {
    return (x *% 0x9E37_79B1) ^ (y *% 0x85EB_CA77) ^ seed;
}

fn halfAt(x: u32, y: u32, seed: u32) u16 {
    return @truncate(patternAt(x, y, seed) >> 7);
}

/// One of ENGINE's buffers: its allocation, its pixels on a page's start,
/// and where the engine reaches them.
const EngineBuffer = struct {
    allocation: *anyopaque,
    pixels: [*]u32,
    mapped: amdgpu.GPUMemory = .{},

    fn halves(buffer: EngineBuffer) [*]u16 {
        return @ptrCast(buffer.pixels);
    }

    fn surface(buffer: EngineBuffer) rtg.Surface {
        return .{ .pixels = @ptrCast(buffer.pixels), .width = engine_width, .height = engine_height, .pitch = engine_pitch, .size_bytes = engine_bytes, .format = .bgra32 };
    }

    fn paint(buffer: EngineBuffer, seed: u32) void {
        for (0..engine_height) |y| {
            for (0..engine_width) |x| buffer.pixels[y * engine_width + x] = patternAt(@intCast(x), @intCast(y), seed);
        }
    }

    fn paintHalves(buffer: EngineBuffer, seed: u32) void {
        const all = buffer.halves();
        for (0..engine_height) |y| {
            for (0..engine_width * 2) |x| all[y * engine_width * 2 + x] = halfAt(@intCast(x), @intCast(y), seed);
        }
    }

    /// Where the engine reaches row `y`.
    fn row(buffer: EngineBuffer, y: u32) u64 {
        return buffer.mapped.device + @as(u64, y) * engine_pitch;
    }
};

fn engineBuffer(sys: *ExecBase, dl: *DosBase, ab: *AMDGPUBase) ?EngineBuffer {
    const allocation = sys.AllocVec(engine_bytes + 4096, exec.MEMF_ANY) orelse {
        _ = Printf(dl, "No memory for %u bytes\n", .{engine_bytes});
        return null;
    };
    var buffer: EngineBuffer = .{ .allocation = allocation, .pixels = @ptrFromInt(@intFromPtr(allocation) + 4095 & ~@as(usize, 4095)) };
    if (!ab.MapGPUMemory(buffer.pixels, engine_bytes, &buffer.mapped)) {
        _ = Printf(dl, "%u bytes at %lx are not mapped: see C:Log\n", .{ engine_bytes, @as(u64, @intFromPtr(buffer.pixels)) });
        sys.FreeVec(allocation);
        return null;
    }
    return buffer;
}

fn freeEngineBuffer(sys: *ExecBase, ab: *AMDGPUBase, buffer: *EngineBuffer) void {
    ab.UnmapGPUMemory(&buffer.mapped);
    sys.FreeVec(buffer.allocation);
}

/// A copy of `width` x `height` pixels from `sx, sy` to `dx, dy`.
const Copy = struct { sx: u32, sy: u32, width: u32, height: u32, dx: u32, dy: u32 };

/// The pixels of a buffer painted with `dest_seed` that a copy from one
/// painted with `src_seed` did not leave as it should: inside, the
/// source's pattern where it came from; outside, the buffer's own. Of
/// four bytes a pixel, or of two in `halves`.
fn copyWrong(dest: [*]const u32, copy: Copy, src_seed: u32, dest_seed: u32) u32 {
    var wrong: u32 = 0;
    for (0..engine_height) |row_index| {
        const y: u32 = @intCast(row_index);
        for (0..engine_width) |column| {
            const x: u32 = @intCast(column);
            const inside = x >= copy.dx and x < copy.dx + copy.width and y >= copy.dy and y < copy.dy + copy.height;
            const want = if (inside) patternAt(x - copy.dx + copy.sx, y - copy.dy + copy.sy, src_seed) else patternAt(x, y, dest_seed);
            if (dest[y * engine_width + x] != want) wrong += 1;
        }
    }
    return wrong;
}

fn copyWrongHalves(dest: [*]const u16, copy: Copy, src_seed: u32, dest_seed: u32) u32 {
    var wrong: u32 = 0;
    for (0..engine_height) |row_index| {
        const y: u32 = @intCast(row_index);
        for (0..engine_width * 2) |column| {
            const x: u32 = @intCast(column);
            const inside = x >= copy.dx and x < copy.dx + copy.width and y >= copy.dy and y < copy.dy + copy.height;
            const want = if (inside) halfAt(x - copy.dx + copy.sx, y - copy.dy + copy.sy, src_seed) else halfAt(x, y, dest_seed);
            if (dest[y * engine_width * 2 + x] != want) wrong += 1;
        }
    }
    return wrong;
}

/// The engine's sub-window copy of `width` x `height` pixels between two
/// linear surfaces of `1 << shift` bytes a pixel and `pitch` pixels a
/// row, each named by the address of the first row the rectangle is in,
/// the rectangle by its columns there.
fn copyPacket(shift: u32, src: u64, dest: u64, pitch: u32, src_x: u32, dest_x: u32, width: u32, height: u32) [13]u32 {
    return pitchedCopy(shift, src, pitch, src_x, dest, pitch, dest_x, width, height);
}

/// The same with a pitch of each surface's own: a source of one pixel a
/// row reads each row one pixel on from the last.
fn pitchedCopy(shift: u32, src: u64, src_pitch: u32, src_x: u32, dest: u64, dest_pitch: u32, dest_x: u32, width: u32, height: u32) [13]u32 {
    return .{
        amdgpu.GPUDMA_OP_COPY | amdgpu.GPUDMA_COPY_SUB_WINDOW | shift << amdgpu.GPUDMA_COPY_ELEMENT_SHIFT,
        @truncate(src),
        @truncate(src >> 32),
        src_x,
        (src_pitch - 1) << amdgpu.GPUDMA_COPY_PITCH_SHIFT,
        src_pitch * height - 1,
        @truncate(dest),
        @truncate(dest >> 32),
        dest_x,
        (dest_pitch - 1) << amdgpu.GPUDMA_COPY_PITCH_SHIFT,
        dest_pitch * height - 1,
        (width - 1) | (height - 1) << 16,
        0,
    };
}

/// A packet's words put into a job's at `count`, which moves on past
/// them.
fn put(words: []u32, count: *u32, packet: anytype) void {
    @memcpy(words[count.*..][0..packet.len], &packet);
    count.* += packet.len;
}

/// `copy` within one of ENGINE's buffers as the engine's packets, into
/// `words`: one sub-window copy where its source and destination are
/// apart, else bands each of whose source and destination are - rows as
/// high as the copy moves, from the bottom up when it moves down and the
/// top down when it moves up, or columns as wide as it moves along its
/// rows where it moves neither up nor down, from the right when it moves
/// right. A job's packets run in order, so each band is read before the
/// one after it writes over it. How many words, and how many bands.
const Banded = struct { words: u32, bands: u32 };

fn bandPackets(words: []u32, buffer: EngineBuffer, copy: Copy) Banded {
    const apart_x = if (copy.dx > copy.sx) copy.dx - copy.sx else copy.sx - copy.dx;
    const apart_y = if (copy.dy > copy.sy) copy.dy - copy.sy else copy.sy - copy.dy;
    var count: u32 = 0;
    if (apart_x >= copy.width or apart_y >= copy.height) {
        put(words, &count, copyPacket(2, buffer.row(copy.sy), buffer.row(copy.dy), engine_width, copy.sx, copy.dx, copy.width, copy.height));
        return .{ .words = count, .bands = 1 };
    }
    const across = apart_y != 0;
    const step = if (across) apart_y else apart_x;
    const length = if (across) copy.height else copy.width;
    const bands = (length + step - 1) / step;
    const backwards = if (across) copy.dy > copy.sy else copy.dx > copy.sx;
    for (0..bands) |index| {
        const band: u32 = @intCast(if (backwards) bands - 1 - index else index);
        const first = band * step;
        const size = @min(step, length - first);
        const packet = if (across)
            copyPacket(2, buffer.row(copy.sy + first), buffer.row(copy.dy + first), engine_width, copy.sx, copy.dx, copy.width, size)
        else
            copyPacket(2, buffer.row(copy.sy), buffer.row(copy.dy), engine_width, copy.sx + first, copy.dx + first, size, copy.height);
        put(words, &count, packet);
    }
    return .{ .words = count, .bands = bands };
}

/// A fill of `width` x `height` pixels at `0, 0` with `engine_colour` as
/// the engine's packets: one run where the rectangle is whole rows, else
/// one a row. How many words.
fn fillPackets(words: []u32, buffer: EngineBuffer, width: u32, height: u32) u32 {
    var count: u32 = 0;
    if (width == engine_width) {
        put(words, &count, fillPacket(buffer.row(0), width * 4 * height, engine_colour, amdgpu.GPUDMA_FILL_WORDS));
        return count;
    }
    for (0..height) |index| put(words, &count, fillPacket(buffer.row(@intCast(index)), width * 4, engine_colour, amdgpu.GPUDMA_FILL_WORDS));
    return count;
}

/// `count` of `words` sent as one job and waited for: true once it is
/// done.
fn engineJob(ab: *AMDGPUBase, words: []const u32, count: u32) bool {
    const job = ab.SendGPUDMA(words.ptr, count);
    return job != 0 and ab.WaitGPUDMA(job, dma_job_ms);
}

/// The same, its fence looked at over and over instead of waited for,
/// for at most `dma_job_ms`.
fn engineJobSpun(sys: *ExecBase, ab: *AMDGPUBase, words: []const u32, count: u32) bool {
    const job = ab.SendGPUDMA(words.ptr, count);
    if (job == 0) return false;
    const until = sys.UptimeUs() + @as(u64, dma_job_ms) * 1000;
    while (!ab.WaitGPUDMA(job, 0)) {
        if (sys.UptimeUs() > until) return false;
    }
    return true;
}

/// The compute engine's registers COMPUTE prints: the command
/// processor's, the scheduler's, the doorbells the engines answer to and
/// the compute engine's interrupt.
const compute_registers = [_]GraphicsRegister{
    .{ .name = "GRBM_STATUS", .segment = 0, .offset = 0x0da4 },
    .{ .name = "CP_STAT", .segment = 0, .offset = 0x0f40 },
    .{ .name = "CP_CPC_STATUS", .segment = 0, .offset = 0x0e24 },
    .{ .name = "CP_ME_CNTL", .segment = 1, .offset = 0x0803 },
    .{ .name = "CP_MEC_CNTL", .segment = 1, .offset = 0x0802 },
    .{ .name = "CP_MES_CNTL", .segment = 1, .offset = 0x2807 },
    .{ .name = "CP_MES_INSTR_PNTR", .segment = 1, .offset = 0x2813 },
    .{ .name = "RLC_CP_SCHEDULERS", .segment = 1, .offset = 0x098a },
    .{ .name = "SH_MEM_CONFIG", .segment = 1, .offset = 0x09e4 },
    .{ .name = "CP_RB_DOORBELL_RANGE_LOWER", .segment = 0, .offset = 0x1dfa },
    .{ .name = "CP_RB_DOORBELL_RANGE_UPPER", .segment = 0, .offset = 0x1dfb },
    .{ .name = "CP_MEC_DOORBELL_RANGE_LOWER", .segment = 0, .offset = 0x1dfc },
    .{ .name = "CP_MEC_DOORBELL_RANGE_UPPER", .segment = 0, .offset = 0x1dfd },
    .{ .name = "CP_ME1_PIPE0_INT_CNTL", .segment = 0, .offset = 0x1e25 },
    .{ .name = "SCRATCH_REG0", .segment = 1, .offset = 0x2040 },
};

/// How long COMPUTE waits for each job, and how much its long
/// dispatches fill.
const compute_job_ms: u32 = 2000;
const compute_long_bytes: u32 = 16 << 20;

/// The arguments of the kernel `fill` (kernels/fill.zig): where it
/// writes, the value it adds each word's number to, and how many words;
/// and the threads in each of its groups, as it is written for.
const FillArguments = extern struct { out: u64, value: u32, count: u32 };
const fill_group: u32 = 64;

/// The compute engine's queue as it is, on one line.
fn printComputeQueue(dl: *DosBase, ab: *AMDGPUBase) void {
    var state: amdgpu.GPUComputeState = .{};
    if (!ab.GetGPUComputeState(&state)) {
        _ = Printf(dl, "  its queue does not run\n", .{});
        return;
    }
    _ = Printf(dl, "  its queue: %u jobs sent, %u done, %u interrupts; read to %lx of %lx; mapped %u, its registers read to %x and told %x; GRBM_STATUS %08x, CP_CPC_STATUS %08x\n", .{
        state.sent,   state.done,       state.interrupts,    state.read,   state.written,
        state.active, state.queue_read, state.queue_written, state.status, state.compute_status,
    });
}

/// What `what` failed of the compute engine, said with its queue and its
/// registers.
fn computeFailed(dl: *DosBase, ab: *AMDGPUBase, info: amdgpu.GPUInfo, graphics: amdgpu.GPUBlock, what: [*:0]const u8) i32 {
    _ = Printf(dl, "%s: not done\n", .{what});
    printComputeQueue(dl, ab);
    printGraphics(dl, info, graphics, &compute_registers);
    printGraphics(dl, info, graphics, &hub_registers);
    return dos.RETURN_ERROR;
}

/// The kernel `fill` dispatched over `count` words at the device's
/// address `out`, in groups of `fill_group`, and waited for: the
/// microseconds it took, or null with why said.
fn dispatchFill(sys: *ExecBase, dl: *DosBase, ab: *AMDGPUBase, info: amdgpu.GPUInfo, graphics: amdgpu.GPUBlock, kernel: *const amdgpu.GPUKernel, out: u64, count: u32) ?u64 {
    const arguments: FillArguments = .{ .out = out, .value = fill_value, .count = count };
    const dispatch: amdgpu.GPUDispatch = .{
        .groups = .{ (count + fill_group - 1) / fill_group, 1, 1 },
        .threads = .{ fill_group, 1, 1 },
        .arguments = &arguments,
        .argument_bytes = @sizeOf(FillArguments),
    };
    const began = sys.UptimeUs();
    const job = ab.SendGPUKernel(kernel, &dispatch);
    if (job == 0 or !ab.WaitGPUCompute(job, compute_job_ms)) {
        _ = computeFailed(dl, ab, info, graphics, "A dispatch of the kernel");
        return null;
    }
    return @max(1, sys.UptimeUs() - began);
}

/// What a dispatch of `fill` over `count` words after `guard_words` of
/// guard left: how many of its words hold `fill_value` plus their
/// number, the first that does not and what it holds, and how many of
/// the guards' words on either side still hold `guard_value`.
const KernelSeen = struct { right: u32, first_wrong: u32, wrong_value: u32, kept: u32 };

fn kernelSeen(words: [*]volatile u32, count: u32, guard_words: u32) KernelSeen {
    var seen: KernelSeen = .{ .right = 0, .first_wrong = count, .wrong_value = 0, .kept = 0 };
    for (0..count) |index| {
        const value = words[guard_words + index];
        if (value == fill_value +% @as(u32, @intCast(index))) {
            seen.right += 1;
        } else if (seen.first_wrong == count) {
            seen.first_wrong = @intCast(index);
            seen.wrong_value = value;
        }
    }
    for (0..guard_words) |index| {
        if (words[index] == guard_value) seen.kept += 1;
        if (words[guard_words + count + index] == guard_value) seen.kept += 1;
    }
    return seen;
}

/// A dispatch's words said: how many were right, and the first that was
/// not; false where any was not or a guard was not kept.
fn kernelRight(dl: *DosBase, seen: KernelSeen, count: u32, guard_words: u32) bool {
    if (seen.right != count) {
        _ = Printf(dl, "  the first word not right is word %u: %08x, %08x meant\n", .{ seen.first_wrong, seen.wrong_value, fill_value +% seen.first_wrong });
    }
    return seen.right == count and seen.kept == 2 * guard_words;
}

/// The compute engine's queue started through the scheduler and tried:
/// words the engine writes, empty jobs one after another, and the kernel
/// the build made dispatched over the device's memory and the machine's.
fn computeCheck(sys: *ExecBase, dl: *DosBase, ab: *AMDGPUBase, info: amdgpu.GPUInfo, graphics: amdgpu.GPUBlock, wb: *WatchdogBase) i32 {
    _ = Printf(dl, "The compute engine before its queue is started:\n", .{});
    printGraphics(dl, info, graphics, &compute_registers);
    var began = sys.UptimeUs();
    if (!ab.StartGPUCompute()) {
        wb.FeedWatchdog();
        _ = Printf(dl, "The compute engine's queue does not run: see C:Log; its registers:\n", .{});
        printGraphics(dl, info, graphics, &compute_registers);
        return dos.RETURN_ERROR;
    }
    const start_us = sys.UptimeUs() - began;
    wb.FeedWatchdog();
    var state: amdgpu.GPUComputeState = .{};
    _ = ab.GetGPUComputeState(&state);
    _ = Printf(dl, "The compute engine's queue runs, started in %lu us: its ring at %lx, %u bytes; the scheduler's firmware %08x, its mapper's %08x\n", .{
        start_us, state.ring, state.ring_bytes, state.scheduler, state.scheduler_queues,
    });
    printComputeQueue(dl, ab);
    printGraphics(dl, info, graphics, &compute_registers);

    var all_right = true;
    var piece: amdgpu.GPUMemory = .{};
    const piece_bytes = fill_bytes + 2 * guard_bytes;
    if (!ab.AllocGPUMemory(piece_bytes, 4096, &piece)) {
        _ = Printf(dl, "No room in the device's memory for %u bytes\n", .{piece_bytes});
        return dos.RETURN_ERROR;
    }
    defer ab.FreeGPUMemory(&piece);
    const words = wordsOf(piece);
    const count = fill_bytes / 4;
    const guard_words = guard_bytes / 4;
    for (0..piece_bytes / 4) |index| words[index] = guard_value;
    const target = piece.device + guard_bytes;
    const write = [8]u32{
        amdgpu.GPUPACKET | amdgpu.GPUPACKET_WRITE_DATA << amdgpu.GPUPACKET_OP_SHIFT | (3 + 4 - 1) << amdgpu.GPUPACKET_COUNT_SHIFT,
        amdgpu.GPUWRITE_MEMORY | amdgpu.GPUWRITE_CONFIRM,
        @truncate(target),
        @truncate(target >> 32),
        0x1111_1111,
        0x2222_2222,
        0x3333_3333,
        0x4444_4444,
    };
    began = sys.UptimeUs();
    const first = ab.SendGPUCompute(&write, write.len);
    if (first == 0 or !ab.WaitGPUCompute(first, compute_job_ms)) return computeFailed(dl, ab, info, graphics, "Four words written by the engine");
    const write_us = sys.UptimeUs() - began;
    var alike: u32 = 0;
    for (write[4..], 0..) |value, index| {
        if (words[guard_words + index] == value) alike += 1;
    }
    const beside_kept = words[guard_words - 1] == guard_value and words[guard_words + 4] == guard_value;
    _ = Printf(dl, "Four words written by the engine at %lx: job %u done in %lu us; %u of 4 written - %08x %08x %08x %08x - the words beside them %s\n", .{
        target,                                                      first,                  write_us,               alike,
        words[guard_words],                                          words[guard_words + 1], words[guard_words + 2], words[guard_words + 3],
        @as([*:0]const u8, if (beside_kept) "kept" else "not kept"),
    });
    if (alike != 4 or !beside_kept) all_right = false;
    wb.FeedWatchdog();

    _ = ab.GetGPUComputeState(&state);
    const interrupts = state.interrupts;
    began = sys.UptimeUs();
    var trip: u32 = 0;
    while (trip < dma_round_trips) : (trip += 1) {
        const job = ab.SendGPUCompute(&write, 0);
        if (job == 0 or !ab.WaitGPUCompute(job, compute_job_ms)) return computeFailed(dl, ab, info, graphics, "An empty job");
    }
    const trips_us = sys.UptimeUs() - began;
    _ = ab.GetGPUComputeState(&state);
    _ = Printf(dl, "%u empty jobs, each sent and waited for: %lu us in all, %lu us each; %u of the engine's interrupts\n", .{
        dma_round_trips, trips_us, trips_us / dma_round_trips, state.interrupts -% interrupts,
    });
    wb.FeedWatchdog();

    const image = @embedFile("gpu_code");
    var code: amdgpu.GPUCode = .{};
    if (!ab.LoadGPUCode(image.ptr, image.len, &code)) {
        _ = Printf(dl, "The code object of %u bytes is not loaded: see C:Log\n", .{@as(u32, image.len)});
        return dos.RETURN_ERROR;
    }
    defer ab.FreeGPUCode(&code);
    var kernel: amdgpu.GPUKernel = .{};
    if (!ab.FindGPUKernel(&code, "fill", &kernel)) {
        _ = Printf(dl, "The code object has no kernel fill that can be run: see C:Log\n", .{});
        return dos.RETURN_ERROR;
    }
    _ = Printf(dl, "The code object of %u bytes loaded at %lx, %u bytes; its kernel fill at %lx: resource words %08x %08x %08x, %u bytes of arguments, %u of group memory, %u of private, properties %x\n", .{
        @as(u32, image.len), code.memory.device, code.memory.bytes,     kernel.code,        kernel.rsrc1,
        kernel.rsrc2,        kernel.rsrc3,       kernel.argument_bytes, kernel.group_bytes, kernel.private_bytes,
        kernel.properties,
    });

    for (0..piece_bytes / 4) |index| words[index] = guard_value;
    const device_us = dispatchFill(sys, dl, ab, info, graphics, &kernel, piece.device + guard_bytes, count) orelse return dos.RETURN_ERROR;
    var seen = kernelSeen(words, count, guard_words);
    _ = Printf(dl, "The kernel over %u words of the device's memory at %lx, %u groups of %u: done in %lu us; %u of its %u words right, %u of the guards' %u kept\n", .{
        count, piece.device + guard_bytes, count / fill_group, fill_group, device_us, seen.right, count, seen.kept, 2 * guard_words,
    });
    if (!kernelRight(dl, seen, count, guard_words)) all_right = false;
    wb.FeedWatchdog();

    const ram = ramBuffer(sys, piece_bytes) orelse {
        _ = Printf(dl, "No memory for %u bytes\n", .{piece_bytes});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(ram.allocation);
    for (0..piece_bytes / 4) |index| ram.words[index] = guard_value;
    var mapped: amdgpu.GPUMemory = .{};
    if (!ab.MapGPUMemory(ram.at, piece_bytes, &mapped)) {
        _ = Printf(dl, "%u bytes of the machine's memory are not mapped: see C:Log\n", .{piece_bytes});
        return dos.RETURN_ERROR;
    }
    const ram_us = dispatchFill(sys, dl, ab, info, graphics, &kernel, mapped.device + guard_bytes, count) orelse {
        ab.UnmapGPUMemory(&mapped);
        return dos.RETURN_ERROR;
    };
    const ram_device = mapped.device;
    ab.UnmapGPUMemory(&mapped);
    seen = kernelSeen(ram.words, count, guard_words);
    _ = Printf(dl, "The kernel over %u words of the machine's memory at %lx, mapped at %lx: done in %lu us; %u of its %u words right, %u of the guards' %u kept\n", .{
        count, @as(u64, @intFromPtr(ram.at)) + guard_bytes, ram_device + guard_bytes, ram_us, seen.right, count, seen.kept, 2 * guard_words,
    });
    if (!kernelRight(dl, seen, count, guard_words)) all_right = false;
    wb.FeedWatchdog();

    const long_bytes = compute_long_bytes + 2 * guard_bytes;
    const long_count = compute_long_bytes / 4;
    const long = ramBuffer(sys, long_bytes) orelse {
        _ = Printf(dl, "No memory for %u MiB\n", .{compute_long_bytes >> 20});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(long.allocation);
    for (0..long_bytes / 4) |index| long.words[index] = guard_value;
    var long_mapped: amdgpu.GPUMemory = .{};
    if (!ab.MapGPUMemory(long.at, long_bytes, &long_mapped)) {
        _ = Printf(dl, "%u MiB of the machine's memory are not mapped: see C:Log\n", .{compute_long_bytes >> 20});
        return dos.RETURN_ERROR;
    }
    _ = ab.GetGPUComputeState(&state);
    const long_interrupts = state.interrupts;
    const long_us = dispatchFill(sys, dl, ab, info, graphics, &kernel, long_mapped.device + guard_bytes, long_count) orelse {
        ab.UnmapGPUMemory(&long_mapped);
        return dos.RETURN_ERROR;
    };
    ab.UnmapGPUMemory(&long_mapped);
    _ = ab.GetGPUComputeState(&state);
    seen = kernelSeen(long.words, long_count, guard_words);
    _ = Printf(dl, "The kernel over %u MiB of the machine's memory, mapped, %u groups: done in %lu us, %lu MB/s; %u of its %u words right, %u of the guards' %u kept; %u interrupts\n", .{
        compute_long_bytes >> 20,            long_count / fill_group, long_us,   @as(u64, compute_long_bytes) / long_us,
        seen.right,                          long_count,              seen.kept, 2 * guard_words,
        state.interrupts -% long_interrupts,
    });
    if (!kernelRight(dl, seen, long_count, guard_words)) all_right = false;
    wb.FeedWatchdog();

    var long_piece: amdgpu.GPUMemory = .{};
    if (ab.AllocGPUMemory(compute_long_bytes, 4096, &long_piece)) {
        defer ab.FreeGPUMemory(&long_piece);
        const long_words = wordsOf(long_piece);
        const last = long_count - 1;
        for ([_]u32{ 0, last / 2, last }) |index| long_words[index] = guard_value;
        const piece_us = dispatchFill(sys, dl, ab, info, graphics, &kernel, long_piece.device, long_count) orelse return dos.RETURN_ERROR;
        _ = Printf(dl, "The kernel over %u MiB of the device's memory: done in %lu us, %lu MB/s; its first, middle and last words %08x %08x %08x (%08x %08x %08x meant)\n", .{
            compute_long_bytes >> 20, piece_us,               @as(u64, compute_long_bytes) / piece_us,
            long_words[0],            long_words[last / 2],   long_words[last],
            fill_value,               fill_value +% last / 2, fill_value +% last,
        });
        if (long_words[0] != fill_value or long_words[last / 2] != fill_value +% last / 2 or long_words[last] != fill_value +% last) all_right = false;
        wb.FeedWatchdog();
    } else {
        _ = Printf(dl, "No room in the device's memory for %u MiB\n", .{compute_long_bytes >> 20});
    }

    _ = Printf(dl, "At the end:\n", .{});
    printComputeQueue(dl, ab);
    printGraphics(dl, info, graphics, &compute_registers);
    _ = Printf(dl, "Its memory hub's:\n", .{});
    printGraphics(dl, info, graphics, &hub_registers);
    return if (all_right) dos.RETURN_OK else dos.RETURN_WARN;
}

/// ENGINE: the queue started, the engine's copies of rectangles and its
/// copied fills tried on the machine's memory, and fills and copies timed
/// beside graphics.library's own on the same buffers.
fn engineCheck(sys: *ExecBase, dl: *DosBase, ab: *AMDGPUBase, info: amdgpu.GPUInfo, graphics: amdgpu.GPUBlock, wb: *WatchdogBase) i32 {
    if (!ab.StartGPUDMA()) {
        wb.FeedWatchdog();
        _ = Printf(dl, "The DMA engine's queue does not run: see C:Log; its registers:\n", .{});
        printGraphics(dl, info, graphics, &dma_registers);
        return dos.RETURN_ERROR;
    }
    wb.FeedWatchdog();
    _ = Printf(dl, "The DMA engine's queue runs\n", .{});
    const library = sys.OpenLibrary("graphics.library", 0) orelse {
        _ = Printf(dl, "No graphics.library\n", .{});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(library);
    const gb: *GraphicsBase = @ptrCast(library);
    var first = engineBuffer(sys, dl, ab) orelse return dos.RETURN_FAIL;
    defer freeEngineBuffer(sys, ab, &first);
    var second = engineBuffer(sys, dl, ab) orelse return dos.RETURN_FAIL;
    defer freeEngineBuffer(sys, ab, &second);
    const words_memory = sys.AllocVec(engine_job_words * 4, exec.MEMF_ANY) orelse {
        _ = Printf(dl, "No memory for a job's words\n", .{});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(words_memory);
    const words = @as([*]u32, @ptrCast(@alignCast(words_memory)))[0..engine_job_words];
    _ = Printf(dl, "Two buffers of %u x %u, four bytes a pixel, at %lx and %lx, mapped at %lx and %lx\n", .{
        engine_width,                        engine_height,
        @as(u64, @intFromPtr(first.pixels)), @as(u64, @intFromPtr(second.pixels)),
        first.mapped.device,                 second.mapped.device,
    });

    var all_right = true;
    const between = Copy{ .sx = 13, .sy = 7, .width = 333, .height = 111, .dx = 101, .dy = 50 };
    first.paint(1);
    second.paint(2);
    var count: u32 = 0;
    put(words, &count, copyPacket(2, first.row(between.sy), second.row(between.dy), engine_width, between.sx, between.dx, between.width, between.height));
    if (!engineJob(ab, words, count)) return dmaFailed(dl, ab, info, graphics, "A copy between two buffers");
    var wrong = copyWrong(second.pixels, between, 1, 2);
    _ = Printf(dl, "A copy of %u x %u from %u,%u of one buffer to %u,%u of the other, four bytes a pixel: %u of the buffer's %u pixels wrong\n", .{
        between.width, between.height, between.sx, between.sy, between.dx, between.dy, wrong, engine_width * engine_height,
    });
    if (wrong != 0) all_right = false;
    wb.FeedWatchdog();

    const halves_copy = Copy{ .sx = 27, .sy = 9, .width = 401, .height = 77, .dx = 333, .dy = 100 };
    first.paintHalves(3);
    second.paintHalves(4);
    count = 0;
    put(words, &count, copyPacket(1, first.row(halves_copy.sy), second.row(halves_copy.dy), engine_width * 2, halves_copy.sx, halves_copy.dx, halves_copy.width, halves_copy.height));
    if (!engineJob(ab, words, count)) return dmaFailed(dl, ab, info, graphics, "A copy of two bytes a pixel");
    wrong = copyWrongHalves(second.halves(), halves_copy, 3, 4);
    _ = Printf(dl, "A copy of %u x %u from %u,%u to %u,%u, two bytes a pixel: %u of the buffer's %u pixels wrong\n", .{
        halves_copy.width, halves_copy.height, halves_copy.sx, halves_copy.sy, halves_copy.dx, halves_copy.dy, wrong, engine_width * 2 * engine_height,
    });
    if (wrong != 0) all_right = false;
    wb.FeedWatchdog();

    const Named = struct { name: [*:0]const u8, copy: Copy };
    const overlaps = [_]Named{
        .{ .name = "down 3 rows and right 5 columns", .copy = .{ .sx = 10, .sy = 10, .width = 300, .height = 200, .dx = 15, .dy = 13 } },
        .{ .name = "up 3 rows and right 2 columns", .copy = .{ .sx = 10, .sy = 20, .width = 300, .height = 200, .dx = 12, .dy = 17 } },
        .{ .name = "right 7 columns", .copy = .{ .sx = 10, .sy = 10, .width = 300, .height = 200, .dx = 17, .dy = 10 } },
        .{ .name = "left 7 columns", .copy = .{ .sx = 17, .sy = 10, .width = 300, .height = 200, .dx = 10, .dy = 10 } },
    };
    for (overlaps) |overlap| {
        first.paint(5);
        const banded = bandPackets(words, first, overlap.copy);
        if (!engineJob(ab, words, banded.words)) return dmaFailed(dl, ab, info, graphics, "A copy within one buffer");
        wrong = copyWrong(first.pixels, overlap.copy, 5, 5);
        _ = Printf(dl, "Within one buffer, %u x %u moved %s, in %u bands: %u pixels wrong\n", .{ overlap.copy.width, overlap.copy.height, overlap.name, banded.bands, wrong });
        if (wrong != 0) all_right = false;
        wb.FeedWatchdog();
    }

    const alone = [_]Named{
        .{ .name = "up a row", .copy = .{ .sx = 0, .sy = 1, .width = engine_width, .height = 1000, .dx = 0, .dy = 0 } },
        .{ .name = "down a row", .copy = .{ .sx = 0, .sy = 0, .width = engine_width, .height = 1000, .dx = 0, .dy = 1 } },
        .{ .name = "left a column", .copy = .{ .sx = 1, .sy = 0, .width = 2000, .height = 100, .dx = 0, .dy = 0 } },
        .{ .name = "right a column", .copy = .{ .sx = 0, .sy = 0, .width = 2000, .height = 100, .dx = 1, .dy = 0 } },
    };
    for (alone) |overlap| {
        first.paint(6);
        count = 0;
        put(words, &count, copyPacket(2, first.row(overlap.copy.sy), first.row(overlap.copy.dy), engine_width, overlap.copy.sx, overlap.copy.dx, overlap.copy.width, overlap.copy.height));
        if (!engineJob(ab, words, count)) return dmaFailed(dl, ab, info, graphics, "A copy over itself");
        wrong = copyWrong(first.pixels, overlap.copy, 6, 6);
        _ = Printf(dl, "One packet over itself, %u x %u moved %s: %u pixels wrong (the engine's own order, not counted)\n", .{ overlap.copy.width, overlap.copy.height, overlap.name, wrong });
        wb.FeedWatchdog();
    }

    {
        const scratch = scratchRow(sys, dl, ab) orelse return dos.RETURN_FAIL;
        defer {
            var mapped = scratch.mapped;
            ab.UnmapGPUMemory(&mapped);
            sys.FreeVec(scratch.allocation);
        }
        second.paint(10);
        count = copiedFill(words, scratch, second, 13, 7, 333, 111, engine_colour);
        if (!engineJob(ab, words, count)) return dmaFailed(dl, ab, info, graphics, "A fill copied from a row");
        wrong = fillWrong(second.pixels, 13, 7, 333, 111, engine_colour, 10);
        _ = Printf(dl, "A fill of 333 x 111 at 13,7 copied from a row of the colour read a pixel on each row, four bytes a pixel: %u of the buffer's %u pixels wrong\n", .{ wrong, engine_width * engine_height });
        if (wrong != 0) all_right = false;
        second.paintHalves(11);
        count = copiedHalvesFill(words, scratch, second, 27, 9, 401, 77, 0xBEEF);
        if (!engineJob(ab, words, count)) return dmaFailed(dl, ab, info, graphics, "A fill copied from a row of halves");
        wrong = fillWrongHalves(second.halves(), 27, 9, 401, 77, 0xBEEF, 11);
        _ = Printf(dl, "The same of 401 x 77 at 27,9, two bytes a pixel read two on each row: %u of the buffer's %u pixels wrong\n", .{ wrong, engine_width * 2 * engine_height });
        if (wrong != 0) all_right = false;
        wb.FeedWatchdog();
    }

    if (!engineTimes(sys, dl, ab, gb, &first, &second, words, wb)) return dmaFailed(dl, ab, info, graphics, "A timed job");

    _ = Printf(dl, "At the end:\n", .{});
    printQueue(dl, ab);
    return if (all_right) dos.RETURN_OK else dos.RETURN_WARN;
}

/// What ENGINE times: a fill a packet a row; a fill copied from a row of
/// the colour that is read one pixel on for each row; a copy between the
/// two buffers; and scrolls by `scroll_rows` up and down, in bands.
const Timed = enum { fill_rows, fill_copied, copy, scroll_up, scroll_down };
const timed_names = [_][*:0]const u8{ "fill, a packet a row", "fill, copied from a row", "copy between two", "scroll up", "scroll down" };

/// The memory ENGINE fills to take its buffers out of the CPU's caches,
/// four times the largest cache there is.
const evict_width: u32 = 4096;
const evict_height: u32 = 4096;

/// A piece of the machine's memory mapped for the engine: a row of a
/// fill's colour, `engine_width + engine_height` pixels.
const Scratch = struct {
    allocation: *anyopaque,
    pixels: [*]u32,
    mapped: amdgpu.GPUMemory = .{},
};

const scratch_bytes: u32 = (engine_width + engine_height) * 4;

fn scratchRow(sys: *ExecBase, dl: *DosBase, ab: *AMDGPUBase) ?Scratch {
    const allocation = sys.AllocVec(scratch_bytes, exec.MEMF_ANY) orelse {
        _ = Printf(dl, "No memory for %u bytes\n", .{scratch_bytes});
        return null;
    };
    var scratch: Scratch = .{ .allocation = allocation, .pixels = @ptrCast(@alignCast(allocation)) };
    if (!ab.MapGPUMemory(allocation, scratch_bytes, &scratch.mapped)) {
        _ = Printf(dl, "%u bytes at %lx are not mapped: see C:Log\n", .{ scratch_bytes, @as(u64, @intFromPtr(allocation)) });
        sys.FreeVec(allocation);
        return null;
    }
    return scratch;
}

/// A fill of `width` x `height` pixels at `x, y` of `buffer` as one copy
/// from `scratch`, whose first `width + height` pixels the CPU sets to
/// `colour` - or, in halves, its first `width + 2 * height` halves to the
/// colour's low half, read two halves on for each row.
fn copiedFill(words: []u32, scratch: Scratch, buffer: EngineBuffer, x: u32, y: u32, width: u32, height: u32, colour: u32) u32 {
    for (0..width + height) |index| scratch.pixels[index] = colour;
    var count: u32 = 0;
    put(words, &count, pitchedCopy(2, scratch.mapped.device, 1, 0, buffer.row(y), engine_width, x, width, height));
    return count;
}

fn copiedHalvesFill(words: []u32, scratch: Scratch, buffer: EngineBuffer, x: u32, y: u32, width: u32, height: u32, colour: u16) u32 {
    const halves: [*]u16 = @ptrCast(scratch.pixels);
    for (0..width + 2 * height) |index| halves[index] = colour;
    var count: u32 = 0;
    put(words, &count, pitchedCopy(1, scratch.mapped.device, 2, 0, buffer.row(y), engine_width * 2, x, width, height));
    return count;
}

/// The pixels a fill of `width` x `height` at `x, y` with `colour` did not
/// leave as it should in a buffer painted with `seed`; of four bytes a
/// pixel, or of two in `halves`.
fn fillWrong(dest: [*]const u32, x0: u32, y0: u32, width: u32, height: u32, colour: u32, seed: u32) u32 {
    var wrong: u32 = 0;
    for (0..engine_height) |row_index| {
        const y: u32 = @intCast(row_index);
        for (0..engine_width) |column| {
            const x: u32 = @intCast(column);
            const inside = x >= x0 and x < x0 + width and y >= y0 and y < y0 + height;
            if (dest[y * engine_width + x] != if (inside) colour else patternAt(x, y, seed)) wrong += 1;
        }
    }
    return wrong;
}

fn fillWrongHalves(dest: [*]const u16, x0: u32, y0: u32, width: u32, height: u32, colour: u16, seed: u32) u32 {
    var wrong: u32 = 0;
    for (0..engine_height) |row_index| {
        const y: u32 = @intCast(row_index);
        for (0..engine_width * 2) |column| {
            const x: u32 = @intCast(column);
            const inside = x >= x0 and x < x0 + width and y >= y0 and y < y0 + height;
            if (dest[y * engine_width * 2 + x] != if (inside) colour else halfAt(x, y, seed)) wrong += 1;
        }
    }
    return wrong;
}

/// What ENGINE's timings work with.
const Timing = struct {
    sys: *ExecBase,
    ab: *AMDGPUBase,
    gb: *GraphicsBase,
    first: *EngineBuffer,
    second: *EngineBuffer,
    scratch: Scratch,
    words: []u32,
    first_surface: *rtg.Surface,
    second_surface: *rtg.Surface,
    first_rp: *graphics_library.RastPort,
    second_rp: *graphics_library.RastPort,
    evict_rp: *graphics_library.RastPort,

    /// A round's start: the job's rectangles just written by the CPU, so
    /// that they are in its caches, or the caches filled with other
    /// memory.
    fn prepare(t: Timing, hot: bool, width: u32, height: u32) void {
        if (hot) {
            t.gb.RectFill(t.first_rp, &.{ .min_x = 0, .min_y = 0, .max_x = @intCast(width), .max_y = @intCast(height + scroll_rows) });
            t.gb.RectFill(t.second_rp, &.{ .min_x = 0, .min_y = 0, .max_x = @intCast(width), .max_y = @intCast(height) });
        } else {
            t.gb.RectFill(t.evict_rp, &.{ .min_x = 0, .min_y = 0, .max_x = evict_width, .max_y = evict_height });
        }
    }

    /// The job by the engine, waited for or spun on.
    fn engine(t: Timing, what: Timed, width: u32, height: u32, spun: bool) bool {
        var count: u32 = 0;
        switch (what) {
            .fill_rows => count = fillPackets(t.words, t.second.*, width, height),
            .fill_copied => count = copiedFill(t.words, t.scratch, t.second.*, 0, 0, width, height, engine_colour),
            .copy => put(t.words, &count, copyPacket(2, t.first.row(0), t.second.row(0), engine_width, 0, 0, width, height)),
            .scroll_up => count = bandPackets(t.words, t.first.*, .{ .sx = 0, .sy = scroll_rows, .width = width, .height = height, .dx = 0, .dy = 0 }).words,
            .scroll_down => count = bandPackets(t.words, t.first.*, .{ .sx = 0, .sy = 0, .width = width, .height = height, .dx = 0, .dy = scroll_rows }).words,
        }
        return if (spun) engineJobSpun(t.sys, t.ab, t.words, count) else engineJob(t.ab, t.words, count);
    }

    /// The same job by graphics.library.
    fn library(t: Timing, what: Timed, width: u32, height: u32) void {
        const w: i32 = @intCast(width);
        const h: i32 = @intCast(height);
        const rows: i32 = @intCast(scroll_rows);
        switch (what) {
            .fill_rows, .fill_copied => t.gb.RectFill(t.second_rp, &.{ .min_x = 0, .min_y = 0, .max_x = w, .max_y = h }),
            .copy => _ = t.gb.BltBitMap(t.first_surface, 0, 0, t.second_surface, 0, 0, w, h),
            .scroll_up => _ = t.gb.BltBitMap(t.first_surface, 0, rows, t.first_surface, 0, 0, w, h),
            .scroll_down => _ = t.gb.BltBitMap(t.first_surface, 0, 0, t.first_surface, 0, rows, w, h),
        }
    }
};

/// One of ENGINE's timings: `rounds` rounds of `what`, each prepared hot
/// or cold first and timed alone, by the engine - waited for or spun on -
/// or by graphics.library. The mean in microseconds, or null where a job
/// is not done.
fn timeRounds(t: Timing, what: Timed, width: u32, height: u32, hot: bool, by_engine: bool, spun: bool, rounds: u32) ?u64 {
    var total: u64 = 0;
    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        t.prepare(hot, width, height);
        const began = t.sys.UptimeUs();
        if (by_engine) {
            if (!t.engine(what, width, height, spun)) return null;
        } else {
            t.library(what, width, height);
        }
        total += t.sys.UptimeUs() - began;
    }
    return total / rounds;
}

/// Each of `Timed` at each of `engine_sides` and the whole buffer: with
/// its rectangles in the CPU's caches by the engine, waited for and spun
/// on, and by graphics.library; then with them out of the caches by the
/// engine and by graphics.library. False where a job is not done.
fn engineTimes(sys: *ExecBase, dl: *DosBase, ab: *AMDGPUBase, gb: *GraphicsBase, first: *EngineBuffer, second: *EngineBuffer, words: []u32, wb: *WatchdogBase) bool {
    const scratch = scratchRow(sys, dl, ab) orelse return true;
    defer {
        var mapped = scratch.mapped;
        ab.UnmapGPUMemory(&mapped);
        sys.FreeVec(scratch.allocation);
    }
    const evict_bytes = evict_width * evict_height * 4;
    const evict = sys.AllocVec(evict_bytes, exec.MEMF_ANY) orelse {
        _ = Printf(dl, "No memory for %u bytes\n", .{evict_bytes});
        return true;
    };
    defer sys.FreeVec(evict);
    var evict_surface = rtg.Surface{ .pixels = @ptrCast(evict), .width = evict_width, .height = evict_height, .pitch = evict_width * 4, .size_bytes = evict_bytes, .format = .bgra32 };
    var first_surface = first.surface();
    var second_surface = second.surface();
    var rps: [3]*graphics_library.RastPort = undefined;
    var made: usize = 0;
    defer for (rps[0..made]) |rp| gb.FreeRastPort(rp);
    for ([_]*rtg.Surface{ &first_surface, &second_surface, &evict_surface }) |surface| {
        const tags = [_]TagItem{
            .{ .tag = graphics_library.RPTAG_Surface, .data = @intFromPtr(surface) },
            .{ .tag = graphics_library.RPTAG_APen, .data = engine_colour },
            .{ .tag = graphics_library.RPTAG_DrMd, .data = graphics_library.DRMD_JAM1 },
            .{},
        };
        rps[made] = gb.CreateRastPortTagList(&tags) orelse {
            _ = Printf(dl, "No RastPort for the timings\n", .{});
            return true;
        };
        made += 1;
    }
    const t = Timing{
        .sys = sys,
        .ab = ab,
        .gb = gb,
        .first = first,
        .second = second,
        .scratch = scratch,
        .words = words,
        .first_surface = &first_surface,
        .second_surface = &second_surface,
        .first_rp = rps[0],
        .second_rp = rps[1],
        .evict_rp = rps[2],
    };

    var mapped: amdgpu.GPUMemory = .{};
    var began = sys.UptimeUs();
    if (ab.MapGPUMemory(first.pixels, engine_bytes, &mapped)) {
        const map_took = sys.UptimeUs() - began;
        began = sys.UptimeUs();
        ab.UnmapGPUMemory(&mapped);
        _ = Printf(dl, "A buffer of %u bytes mapped in %lu us and unmapped in %lu us\n", .{ engine_bytes, map_took, sys.UptimeUs() - began });
    }
    _ = Printf(dl, "Timed, the mean of %u rounds each, in microseconds: with the job's rectangles just written by the CPU - by the engine, its job waited for and spun on, and by graphics.library - and with them out of the CPU's caches, by the engine and by graphics.library:\n", .{engine_rounds});
    for (engine_sizes) |size| {
        const width = size[0];
        const height = size[1];
        _ = Printf(dl, "  %u x %u, %u bytes:%30s%6s %6s %6s   %6s %6s\n", .{ width, height, width * height * 4, "", "engine", "spun", "CPU", "engine", "CPU" });
        for (0..timed_names.len) |which| {
            const what: Timed = @enumFromInt(which);
            const hot_engine = timeRounds(t, what, width, height, true, true, false, engine_rounds) orelse return false;
            const hot_spun = timeRounds(t, what, width, height, true, true, true, engine_rounds) orelse return false;
            const hot_cpu = timeRounds(t, what, width, height, true, false, false, engine_rounds).?;
            const cold_engine = timeRounds(t, what, width, height, false, true, false, engine_rounds) orelse return false;
            const cold_cpu = timeRounds(t, what, width, height, false, false, false, engine_rounds).?;
            _ = Printf(dl, "    %-24s hot %6lu %6lu %6lu   cold %6lu %6lu\n", .{ timed_names[which], hot_engine, hot_spun, hot_cpu, cold_engine, cold_cpu });
            wb.FeedWatchdog();
        }
    }
    return true;
}

// --- BLITS: the board's own fills and copies -----------------------------------------

/// BLITS' buffers: 2560 x 2880 pixels of four bytes, more than the CPU's
/// caches hold, rows of whole 256 bytes; read as two bytes a pixel, twice
/// as many to a row. The colour its fills are drawn in.
const blits_width: u32 = 2560;
const blits_height: u32 = 2880;
const blits_pitch: u32 = blits_width * 4;
const blits_bytes: u32 = blits_pitch * blits_height;
const blits_colour: u32 = 0xFF12_3456;

/// One of BLITS' jobs: a fill of `rect` into the second buffer, or
/// `copies` from the first buffer to the second (`between`) or within the
/// second (`within`); of two bytes a pixel where `halves`. Done by
/// rtg.library on the board's buffers, or - `drawn` - drawn by
/// graphics.library into the board's buffer, as a program draws.
const Blit = struct {
    name: [*:0]const u8,
    kind: enum { fill, between, within },
    halves: bool = false,
    drawn: bool = false,
    rect: rtg.RtgRect = .{},
    copies: []const rtg.RtgCopy = &.{},
};

/// Four quarters of the first buffer, each to the quarter across from it
/// in the second: one job of CopyRects.
const blit_quarters = [_]rtg.RtgCopy{
    .{ .src_x = 0, .src_y = 0, .width = 1280, .height = 1440, .dest_x = 1280, .dest_y = 1440 },
    .{ .src_x = 1280, .src_y = 0, .width = 1280, .height = 1440, .dest_x = 0, .dest_y = 1440 },
    .{ .src_x = 0, .src_y = 1440, .width = 1280, .height = 1440, .dest_x = 1280, .dest_y = 0 },
    .{ .src_x = 1280, .src_y = 1440, .width = 1280, .height = 1440, .dest_x = 0, .dest_y = 0 },
};

const blit_jobs = [_]Blit{
    .{ .name = "fill, whole rows", .kind = .fill, .rect = .{ .x = 0, .y = 8, .width = 2560, .height = 2864 } },
    .{ .name = "fill, part of the rows", .kind = .fill, .rect = .{ .x = 13, .y = 7, .width = 2500, .height = 2850 } },
    .{ .name = "fill, small", .kind = .fill, .rect = .{ .x = 100, .y = 100, .width = 256, .height = 256 } },
    .{ .name = "copy between two", .kind = .between, .copies = &.{.{ .src_x = 3, .src_y = 5, .width = 2550, .height = 1430, .dest_x = 9, .dest_y = 1400 }} },
    .{ .name = "copy between two, small", .kind = .between, .copies = &.{.{ .src_x = 3, .src_y = 5, .width = 256, .height = 256, .dest_x = 9, .dest_y = 1400 }} },
    .{ .name = "four copies between two", .kind = .between, .copies = &blit_quarters },
    .{ .name = "move clear of itself", .kind = .within, .copies = &.{.{ .src_x = 0, .src_y = 0, .width = 2560, .height = 1430, .dest_x = 0, .dest_y = 1440 }} },
    .{ .name = "scroll up 16 rows", .kind = .within, .copies = &.{.{ .src_x = 0, .src_y = 16, .width = 2560, .height = 2864, .dest_x = 0, .dest_y = 0 }} },
    .{ .name = "scroll down 16 rows", .kind = .within, .copies = &.{.{ .src_x = 0, .src_y = 0, .width = 2560, .height = 2864, .dest_x = 0, .dest_y = 16 }} },
    .{ .name = "scroll up 1 row", .kind = .within, .copies = &.{.{ .src_x = 0, .src_y = 1, .width = 2560, .height = 2879, .dest_x = 0, .dest_y = 0 }} },
    .{ .name = "move right 16 columns", .kind = .within, .copies = &.{.{ .src_x = 0, .src_y = 0, .width = 2544, .height = 2880, .dest_x = 16, .dest_y = 0 }} },
    .{ .name = "move left 16 columns", .kind = .within, .copies = &.{.{ .src_x = 16, .src_y = 0, .width = 2544, .height = 2880, .dest_x = 0, .dest_y = 0 }} },
    .{ .name = "move down 100, right 37", .kind = .within, .copies = &.{.{ .src_x = 0, .src_y = 0, .width = 2523, .height = 2780, .dest_x = 37, .dest_y = 100 }} },
    .{ .name = "move up 100, left 37", .kind = .within, .copies = &.{.{ .src_x = 37, .src_y = 100, .width = 2523, .height = 2780, .dest_x = 0, .dest_y = 0 }} },
    .{ .name = "16-bit fill, whole rows", .kind = .fill, .halves = true, .rect = .{ .x = 0, .y = 0, .width = 5120, .height = 2880 } },
    .{ .name = "16-bit fill, part of the rows", .kind = .fill, .halves = true, .rect = .{ .x = 7, .y = 3, .width = 5001, .height = 2870 } },
    .{ .name = "16-bit copy, odd columns", .kind = .between, .halves = true, .copies = &.{.{ .src_x = 3, .src_y = 5, .width = 5101, .height = 1430, .dest_x = 11, .dest_y = 1400 }} },
    .{ .name = "16-bit scroll up 16 rows", .kind = .within, .halves = true, .copies = &.{.{ .src_x = 0, .src_y = 16, .width = 5120, .height = 2864, .dest_x = 0, .dest_y = 0 }} },
    .{ .name = "fill drawn by graphics.library", .kind = .fill, .drawn = true, .rect = .{ .x = 0, .y = 8, .width = 2560, .height = 2864 } },
    .{ .name = "copy drawn by graphics.library", .kind = .between, .drawn = true, .copies = &.{.{ .src_x = 3, .src_y = 5, .width = 2550, .height = 1430, .dest_x = 9, .dest_y = 1400 }} },
};

/// BLITS' four buffers - the board's two, then the plain two - and the
/// board's as rtg.library has them, of four bytes a pixel and of two.
const Blits = struct {
    sys: *ExecBase,
    rb: *RtgBase,
    gb: *GraphicsBase,
    pixels: [4][*]u8,
    bitmaps: [2][2]*rtg.RtgBitMap,

    /// Buffer `which` as plain memory, of four bytes a pixel or of two.
    fn surface(blits: Blits, which: usize, halves: bool) rtg.Surface {
        return .{
            .pixels = blits.pixels[which],
            .width = if (halves) 2 * blits_width else blits_width,
            .height = blits_height,
            .pitch = blits_pitch,
            .size_bytes = blits_bytes,
            .format = if (halves) .rgb565 else .bgra32,
        };
    }

    /// The board's two painted, each pixel its own, and copied into the
    /// plain two.
    fn paint(blits: Blits, halves: bool) void {
        for (0..2) |which| {
            const seed: u32 = @intCast(which + 1);
            for (0..blits_height) |row_index| {
                const y: u32 = @intCast(row_index);
                if (halves) {
                    const row: [*]u16 = @ptrCast(@alignCast(blits.pixels[which] + y * blits_pitch));
                    for (0..2 * blits_width) |x| row[x] = halfAt(@intCast(x), y, seed);
                } else {
                    const row: [*]u32 = @ptrCast(@alignCast(blits.pixels[which] + y * blits_pitch));
                    for (0..blits_width) |x| row[x] = patternAt(@intCast(x), y, seed);
                }
            }
            blits.sys.CopyMem(blits.pixels[which], blits.pixels[which + 2], blits_bytes);
        }
    }

    /// The pixels in which the board's two differ from the plain two.
    fn wrong(blits: Blits, halves: bool) u32 {
        var count: u32 = 0;
        for (0..2) |which| {
            if (halves) {
                const board: [*]const u16 = @ptrCast(@alignCast(blits.pixels[which]));
                const plain: [*]const u16 = @ptrCast(@alignCast(blits.pixels[which + 2]));
                for (0..blits_bytes / 2) |index| count += @intFromBool(board[index] != plain[index]);
            } else {
                const board: [*]const u32 = @ptrCast(@alignCast(blits.pixels[which]));
                const plain: [*]const u32 = @ptrCast(@alignCast(blits.pixels[which + 2]));
                for (0..blits_bytes / 4) |index| count += @intFromBool(board[index] != plain[index]);
            }
        }
        return count;
    }

    /// A RastPort drawing `blits_colour` into a surface, or into one of
    /// the board's buffers itself.
    fn port(blits: Blits, plain: ?*rtg.Surface, bitmap: ?*rtg.RtgBitMap) ?*graphics_library.RastPort {
        const tags = [_]TagItem{
            if (bitmap) |board_bitmap| .{ .tag = graphics_library.RPTAG_BitMap, .data = @intFromPtr(board_bitmap) } else .{ .tag = graphics_library.RPTAG_Surface, .data = @intFromPtr(plain.?) },
            .{ .tag = graphics_library.RPTAG_APen, .data = blits_colour },
            .{ .tag = graphics_library.RPTAG_DrMd, .data = graphics_library.DRMD_JAM1 },
            .{},
        };
        return blits.gb.CreateRastPortTagList(&tags);
    }

    /// `job` by graphics.library on plain memory: buffers `first` and
    /// `first + 1`. False where it has no RastPort.
    fn byLibrary(blits: Blits, job: Blit, first: usize) bool {
        var from = blits.surface(first, job.halves);
        var into = blits.surface(first + 1, job.halves);
        const gb = blits.gb;
        switch (job.kind) {
            .fill => {
                const rp = blits.port(&into, null) orelse return false;
                defer gb.FreeRastPort(rp);
                const rect = job.rect;
                gb.RectFill(rp, &.{ .min_x = rect.x, .min_y = rect.y, .max_x = rect.x + rect.width, .max_y = rect.y + rect.height });
            },
            .between, .within => {
                const source = if (job.kind == .between) &from else &into;
                if (job.drawn) {
                    const rp = blits.port(&into, null) orelse return false;
                    defer gb.FreeRastPort(rp);
                    for (job.copies) |copy| gb.BltBitMapRastPort(source, copy.src_x, copy.src_y, rp, copy.dest_x, copy.dest_y, copy.width, copy.height);
                } else {
                    for (job.copies) |copy| _ = gb.BltBitMap(source, copy.src_x, copy.src_y, &into, copy.dest_x, copy.dest_y, copy.width, copy.height);
                }
            },
        }
        return true;
    }

    /// `job` by the board: through rtg.library, or drawn through
    /// graphics.library into its buffer. rtg.library's answer, or
    /// RTGERR_OK for one drawn; one the board does not take done by
    /// graphics.library on the board's buffers, as the library does it.
    /// Null where graphics.library has no RastPort.
    fn byBoard(blits: Blits, job: Blit) ?i32 {
        const halves = @intFromBool(job.halves);
        const from = blits.bitmaps[0][halves];
        const into = blits.bitmaps[1][halves];
        const rb = blits.rb;
        if (job.drawn) {
            const rp = blits.port(null, into) orelse return null;
            defer blits.gb.FreeRastPort(rp);
            const rect = job.rect;
            switch (job.kind) {
                .fill => blits.gb.RectFill(rp, &.{ .min_x = rect.x, .min_y = rect.y, .max_x = rect.x + rect.width, .max_y = rect.y + rect.height }),
                .between, .within => for (job.copies) |copy| blits.gb.BltBitMapRastPort(@ptrCast(if (job.kind == .between) from else into), copy.src_x, copy.src_y, rp, copy.dest_x, copy.dest_y, copy.width, copy.height),
            }
            return rtg.errors.RTGERR_OK;
        }
        const answer = switch (job.kind) {
            // The colour as graphics.library packed it into the plain
            // buffer it filled first.
            .fill => rb.FillRect(into, &job.rect, packedAt(blits, job)),
            .between => if (job.copies.len == 1) rb.CopyRect(from, into, &job.copies[0]) else rb.CopyRects(from, into, job.copies.ptr, @intCast(job.copies.len)),
            .within => rb.CopyRect(into, into, &job.copies[0]),
        };
        if (answer == rtg.errors.RTGERR_NOT_SUPPORTED and !blits.byLibrary(job, 0)) return null;
        return answer;
    }
};

/// The pixel graphics.library filled first in the plain buffer: the
/// colour as it packs it for the buffer's format.
fn packedAt(blits: Blits, job: Blit) u32 {
    const x: u32 = @intCast(job.rect.x);
    const y: u32 = @intCast(job.rect.y);
    const row = blits.pixels[3] + y * blits_pitch;
    if (job.halves) return @as([*]const u16, @ptrCast(@alignCast(row)))[x];
    return @as([*]const u32, @ptrCast(@alignCast(row)))[x];
}

/// BLITS: the board's own fills and copies, through rtg.library and
/// drawn through graphics.library, each held to graphics.library's on
/// plain memory pixel for pixel and timed beside it.
fn blitsCheck(sys: *ExecBase, dl: *DosBase, millis: u32) i32 {
    const rtg_lib = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(rtg_lib);
    const rb: *RtgBase = @ptrCast(rtg_lib);
    const board = amdBoard(dl, rb) orelse return dos.RETURN_WARN;
    const graphics_lib = sys.OpenLibrary("graphics.library", 0) orelse {
        _ = Printf(dl, "No graphics.library\n", .{});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(graphics_lib);

    var allocations: [4]?*anyopaque = @splat(null);
    defer for (allocations) |allocation| if (allocation) |memory| sys.FreeVec(memory);
    var pixels: [4][*]u8 = undefined;
    for (&allocations, &pixels) |*allocation, *start| {
        const memory = sys.AllocVec(blits_bytes + 256, exec.MEMF_ANY) orelse {
            _ = Printf(dl, "No memory for %u bytes\n", .{blits_bytes});
            return dos.RETURN_FAIL;
        };
        allocation.* = memory;
        start.* = @ptrFromInt(@intFromPtr(memory) + 255 & ~@as(usize, 255));
    }
    var attached: [4]?*rtg.RtgBitMap = @splat(null);
    defer for (attached) |bitmap| rb.FreeBitMap(bitmap);
    var bitmaps: [2][2]*rtg.RtgBitMap = undefined;
    for (0..2) |which| {
        for (0..2) |halves| {
            const described = rtg.RtgBitMap{
                .pixels = pixels[which],
                .width = if (halves == 1) 2 * blits_width else blits_width,
                .height = blits_height,
                .pitch = blits_pitch,
                .size_bytes = blits_bytes,
                .format = if (halves == 1) .rgb565 else .bgra32,
            };
            const bitmap = rb.AttachBitMap(board, &described) orelse {
                _ = Printf(dl, "The board does not take a buffer at %lx\n", .{@as(u64, @intFromPtr(pixels[which]))});
                return dos.RETURN_FAIL;
            };
            attached[which * 2 + halves] = bitmap;
            bitmaps[which][halves] = bitmap;
        }
    }
    const blits = Blits{ .sys = sys, .rb = rb, .gb = @ptrCast(graphics_lib), .pixels = pixels, .bitmaps = bitmaps };
    const wb = arm(sys, dl, millis) orelse return dos.RETURN_FAIL;
    defer wb.DisarmWatchdog();
    // The board's start of its engine ended, whatever it came to.
    _ = rb.BoardControl(board, rtg.boards.RTGCTRL_SETTLED, 0);
    _ = Printf(dl, "The board's two buffers at %lx and %lx, the plain two at %lx and %lx, %u x %u, four bytes a pixel, or twice as many of two\n", .{
        @as(u64, @intFromPtr(pixels[0])), @as(u64, @intFromPtr(pixels[1])), @as(u64, @intFromPtr(pixels[2])), @as(u64, @intFromPtr(pixels[3])), blits_width, blits_height,
    });
    _ = Printf(dl, "  %-32s %-8s %9s %9s %8s\n", .{ "job", "board", "board us", "CPU us", "wrong" });

    var taken: u32 = 0;
    var refused: u32 = 0;
    var all_wrong: u32 = 0;
    var all_right = true;
    for (blit_jobs) |job| {
        blits.paint(job.halves);
        var began = sys.UptimeUs();
        if (!blits.byLibrary(job, 2)) {
            _ = Printf(dl, "No RastPort for %s\n", .{job.name});
            return dos.RETURN_FAIL;
        }
        const library_us = sys.UptimeUs() - began;
        began = sys.UptimeUs();
        const answer = blits.byBoard(job) orelse {
            _ = Printf(dl, "No RastPort for %s\n", .{job.name});
            return dos.RETURN_FAIL;
        };
        const board_us = sys.UptimeUs() - began;
        const wrong = blits.wrong(job.halves);
        const said: [*:0]const u8 = if (job.drawn) "drawn" else switch (answer) {
            rtg.errors.RTGERR_OK => "engine",
            rtg.errors.RTGERR_NOT_SUPPORTED => "refused",
            else => "failed",
        };
        _ = Printf(dl, "  %-32s %-8s %9lu %9lu %8u\n", .{ job.name, said, board_us, library_us, wrong });
        if (answer == rtg.errors.RTGERR_OK and !job.drawn) taken += 1;
        if (answer == rtg.errors.RTGERR_NOT_SUPPORTED) refused += 1;
        if (answer != rtg.errors.RTGERR_OK and answer != rtg.errors.RTGERR_NOT_SUPPORTED) {
            _ = Printf(dl, "The board answered %ld: see C:Log\n", .{@as(i64, answer)});
            all_right = false;
        }
        all_wrong += wrong;
        wb.FeedWatchdog();
    }
    _ = Printf(dl, "%u jobs taken by the board's engine, %u refused and done by graphics.library, %u pixels wrong\n", .{ taken, refused, all_wrong });
    return if (all_right and all_wrong == 0) dos.RETURN_OK else dos.RETURN_WARN;
}

// --- KERNELS: the board's own blends, scales, shapes and tiles -----------------------------

/// The bits of KERNELS' shapes - a row for each of the buffer's, as long
/// as a row of two bytes a pixel and a little more, and a few rows more -
/// and of its tiles, up to 16 x 16 bits. The pens they are drawn in.
const shape_pitch: u32 = (2 * blits_width + 64) / 8;
const shape_rows: u32 = blits_height + 8;
const tile_pitch: u32 = 2;
const tile_rows: u32 = 16;
/// The memory KERNELS reads through before it times a job, so that
/// nothing the job reads or writes is in the CPU's caches: more than
/// they hold, which is 24 MiB on the NucBox. Read, its lines are clean,
/// so the job writes none of them back as it takes their place.
const read_through_bytes: u32 = 64 << 20;
const shape_fg = graphics_library.penRGB(0xE0, 0x30, 0x91);
const shape_bg = graphics_library.penRGB(0x12, 0xC4, 0x5D);

/// One of KERNELS' jobs, drawn by graphics.library into a buffer: the
/// picture laid over `area` from its pixel at `from`'s corner, at
/// `alpha`, every pixel covering fully where `covering`
/// (BlendBitMapPixels); `pen` laid over it (BlendBitMapRect); the part
/// `from` of the picture scaled smoothly to it (ScalePixelArray); a shape
/// from its bit at `from`'s corner, or a `tile_width` x `tile_height`
/// tile, in `mode` (BltTemplate, BltPattern) - on four bytes a pixel, or
/// on two where `halves`. The picture is of `format`.
const Drawn = struct {
    name: [*:0]const u8,
    kind: enum { blend, tint, scale, shape, tile },
    area: rtg.RtgRect,
    from: rtg.RtgRect = .{},
    halves: bool = false,
    format: rtg.PixelFormat = .bgra32,
    covering: bool = false,
    alpha: u32 = 255,
    pen: u32 = 0,
    mode: graphics_library.DrawMode = graphics_library.DRMD_JAM2,
    tile_width: u32 = 0,
    tile_height: u32 = 0,
};

const whole_buffer: rtg.RtgRect = .{ .x = 0, .y = 0, .width = blits_width, .height = blits_height };
const whole_halves: rtg.RtgRect = .{ .x = 0, .y = 0, .width = 2 * blits_width, .height = blits_height };
const small_square: rtg.RtgRect = .{ .x = 100, .y = 100, .width = 256, .height = 256 };

const drawn_jobs = [_]Drawn{
    .{ .name = "blend, whole buffer", .kind = .blend, .area = whole_buffer },
    .{ .name = "blend at 128", .kind = .blend, .alpha = 128, .area = whole_buffer },
    .{ .name = "blend covering fully, at 200", .kind = .blend, .alpha = 200, .covering = true, .area = whole_buffer },
    .{ .name = "blend rgba32, part", .kind = .blend, .format = .rgba32, .from = .{ .x = 17, .y = 11 }, .area = .{ .x = 13, .y = 7, .width = 2500, .height = 2850 } },
    .{ .name = "blend 2560 x 1440", .kind = .blend, .area = .{ .x = 0, .y = 0, .width = 2560, .height = 1440 } },
    .{ .name = "blend 1024 x 1024", .kind = .blend, .area = .{ .x = 100, .y = 100, .width = 1024, .height = 1024 } },
    .{ .name = "blend 256 x 256", .kind = .blend, .area = small_square },
    .{ .name = "blend 64 x 64", .kind = .blend, .area = .{ .x = 100, .y = 100, .width = 64, .height = 64 } },
    .{ .name = "colour at 100, part", .kind = .tint, .pen = 0x64C0_4020, .area = .{ .x = 5, .y = 3, .width = 2550, .height = 2870 } },
    .{ .name = "colour 1024 x 1024", .kind = .tint, .pen = 0x8000_80FF, .area = .{ .x = 100, .y = 100, .width = 1024, .height = 1024 } },
    .{ .name = "colour 256 x 256", .kind = .tint, .pen = 0x8000_80FF, .area = small_square },
    .{ .name = "scale up 2x", .kind = .scale, .from = .{ .x = 0, .y = 0, .width = 1280, .height = 1440 }, .area = whole_buffer },
    .{ .name = "scale rgba32 up 2x", .kind = .scale, .format = .rgba32, .from = .{ .x = 0, .y = 0, .width = 1280, .height = 1440 }, .area = whole_buffer },
    .{ .name = "scale up 1.5x, odd", .kind = .scale, .from = .{ .x = 31, .y = 17, .width = 1700, .height = 1900 }, .area = .{ .x = 5, .y = 3, .width = 2550, .height = 2850 } },
    .{ .name = "scale, the same size", .kind = .scale, .from = .{ .x = 3, .y = 5, .width = 2550, .height = 2870 }, .area = .{ .x = 7, .y = 2, .width = 2550, .height = 2870 } },
    .{ .name = "scale down 2x", .kind = .scale, .from = .{ .x = 0, .y = 0, .width = 2560, .height = 2880 }, .area = .{ .x = 100, .y = 100, .width = 1280, .height = 1440 } },
    .{ .name = "scale down 3x", .kind = .scale, .from = .{ .x = 0, .y = 0, .width = 2560, .height = 2880 }, .area = .{ .x = 7, .y = 9, .width = 853, .height = 960 } },
    .{ .name = "scale narrower, taller", .kind = .scale, .from = .{ .x = 0, .y = 0, .width = 2560, .height = 720 }, .area = .{ .x = 0, .y = 0, .width = 1000, .height = 2880 } },
    .{ .name = "scale 128 to 256", .kind = .scale, .from = .{ .x = 3, .y = 3, .width = 128, .height = 128 }, .area = small_square },
    .{ .name = "scale down 64x", .kind = .scale, .from = .{ .x = 0, .y = 0, .width = 2560, .height = 2880 }, .area = .{ .x = 10, .y = 10, .width = 40, .height = 45 } },
    .{ .name = "shape, both colours", .kind = .shape, .area = whole_buffer },
    .{ .name = "shape, ink only, part", .kind = .shape, .mode = graphics_library.DRMD_JAM1, .from = .{ .x = 5, .y = 3 }, .area = .{ .x = 13, .y = 7, .width = 2500, .height = 2850 } },
    .{ .name = "shape, colours swapped", .kind = .shape, .mode = graphics_library.DRMD_JAM2 | graphics_library.DRMD_INVERSVID, .area = whole_buffer },
    .{ .name = "16-bit shape, both colours", .kind = .shape, .halves = true, .area = whole_halves },
    .{ .name = "16-bit shape, ink only, part", .kind = .shape, .halves = true, .mode = graphics_library.DRMD_JAM1, .from = .{ .x = 3, .y = 1 }, .area = .{ .x = 7, .y = 3, .width = 5001, .height = 2870 } },
    .{ .name = "shape 256 x 256", .kind = .shape, .area = small_square },
    .{ .name = "16-bit shape 256 x 256", .kind = .shape, .halves = true, .area = small_square },
    .{ .name = "tile 16 x 16", .kind = .tile, .tile_width = 16, .tile_height = 16, .area = whole_buffer },
    .{ .name = "tile 13 x 7, ink only, part", .kind = .tile, .mode = graphics_library.DRMD_JAM1, .tile_width = 13, .tile_height = 7, .area = .{ .x = 13, .y = 7, .width = 2500, .height = 2850 } },
    .{ .name = "16-bit tile 13 x 7, swapped", .kind = .tile, .halves = true, .mode = graphics_library.DRMD_JAM2 | graphics_library.DRMD_INVERSVID, .tile_width = 13, .tile_height = 7, .area = whole_halves },
    .{ .name = "tile 256 x 256", .kind = .tile, .tile_width = 16, .tile_height = 16, .area = small_square },
    .{ .name = "16-bit tile 256 x 256", .kind = .tile, .halves = true, .tile_width = 16, .tile_height = 16, .area = small_square },
};

/// One of KERNELS' buffers, as plain memory, of four bytes a pixel or of
/// two.
fn drawnSurface(pixels: [*]u8, halves: bool) rtg.Surface {
    return .{
        .pixels = pixels,
        .width = if (halves) 2 * blits_width else blits_width,
        .height = blits_height,
        .pitch = blits_pitch,
        .size_bytes = blits_bytes,
        .format = if (halves) .rgb565 else .bgra32,
    };
}

/// The same as a bitmap no board is behind.
fn drawnBitMap(pixels: [*]u8, halves: bool) rtg.RtgBitMap {
    return .{
        .pixels = pixels,
        .width = if (halves) 2 * blits_width else blits_width,
        .height = blits_height,
        .pitch = blits_pitch,
        .size_bytes = blits_bytes,
        .format = if (halves) .rgb565 else .bgra32,
    };
}

/// KERNELS' memory: the board's buffer, as rtg.library has it of four
/// bytes a pixel and of two; the plain buffer beside it; the picture; the
/// shapes' and the tiles' bits.
const Drawing = struct {
    sys: *ExecBase,
    gb: *GraphicsBase,
    board_pixels: [*]u8,
    plain_pixels: [*]u8,
    bitmaps: [2]*rtg.RtgBitMap,
    picture: [*]u8,
    shape: [*]u8,
    tile: [*]u8,
    evict: [*]const u8,

    /// The CPU's caches filled with other memory, a read of each line of
    /// it: what a job draws on and from is then in none of them, as for
    /// a job that covers more than they hold.
    fn evicted(drawing: Drawing) void {
        const lines: [*]const volatile u64 = @ptrCast(@alignCast(drawing.evict));
        var index: usize = 0;
        while (index < read_through_bytes / 8) : (index += 8) _ = lines[index];
    }

    /// The board's buffer and the plain one painted alike, each pixel its
    /// own.
    fn paint(drawing: Drawing, halves: bool, seed: u32) void {
        for (0..blits_height) |row_index| {
            const y: u32 = @intCast(row_index);
            if (halves) {
                const row: [*]u16 = @ptrCast(@alignCast(drawing.board_pixels + y * blits_pitch));
                for (0..2 * blits_width) |x| row[x] = halfAt(@intCast(x), y, seed);
            } else {
                const row: [*]u32 = @ptrCast(@alignCast(drawing.board_pixels + y * blits_pitch));
                for (0..blits_width) |x| row[x] = patternAt(@intCast(x), y, seed);
            }
        }
        drawing.sys.CopyMem(drawing.board_pixels, drawing.plain_pixels, blits_bytes);
    }

    /// The pixels in which the two differ.
    fn wrong(drawing: Drawing, halves: bool) u32 {
        var count: u32 = 0;
        if (halves) {
            const board: [*]const u16 = @ptrCast(@alignCast(drawing.board_pixels));
            const plain: [*]const u16 = @ptrCast(@alignCast(drawing.plain_pixels));
            for (0..blits_bytes / 2) |index| count += @intFromBool(board[index] != plain[index]);
        } else {
            const board: [*]const u32 = @ptrCast(@alignCast(drawing.board_pixels));
            const plain: [*]const u32 = @ptrCast(@alignCast(drawing.plain_pixels));
            for (0..blits_bytes / 4) |index| count += @intFromBool(board[index] != plain[index]);
        }
        return count;
    }

    /// A RastPort for `job` drawing into the board's buffer itself, or
    /// into `plain`: the shapes' pens and `job`'s mode, and smooth.
    fn port(drawing: Drawing, job: Drawn, on_board: bool, plain: *rtg.Surface) ?*graphics_library.RastPort {
        const tags = [_]TagItem{
            if (on_board) .{ .tag = graphics_library.RPTAG_BitMap, .data = @intFromPtr(drawing.bitmaps[@intFromBool(job.halves)]) } else .{ .tag = graphics_library.RPTAG_Surface, .data = @intFromPtr(plain) },
            .{ .tag = graphics_library.RPTAG_APen, .data = shape_fg },
            .{ .tag = graphics_library.RPTAG_BPen, .data = shape_bg },
            .{ .tag = graphics_library.RPTAG_DrMd, .data = job.mode },
            .{ .tag = graphics_library.RPTAG_Smooth, .data = 1 },
            .{},
        };
        return drawing.gb.CreateRastPortTagList(&tags);
    }

    /// `job` drawn by graphics.library into the board's buffer, which it
    /// hands to the board, or into the plain one, which it draws itself.
    /// False where it has no RastPort or did not draw.
    fn draw(drawing: Drawing, job: Drawn, on_board: bool) bool {
        const gb = drawing.gb;
        var plain = drawnSurface(drawing.plain_pixels, job.halves);
        var plain_bitmap = drawnBitMap(drawing.plain_pixels, job.halves);
        const into: *rtg.RtgBitMap = if (on_board) drawing.bitmaps[@intFromBool(job.halves)] else &plain_bitmap;
        const area = job.area;
        const rect: graphics_library.Rect = .{ .min_x = area.x, .min_y = area.y, .max_x = area.x + area.width, .max_y = area.y + area.height };
        switch (job.kind) {
            .blend => {
                const picture: rtg.RtgPixels = .{
                    .pixels = drawing.picture,
                    .pitch = blits_pitch,
                    .format = job.format,
                    .flags = if (job.covering) rtg.RTGPIXF_OPAQUE else 0,
                    .x = job.from.x,
                    .y = job.from.y,
                };
                return gb.BlendBitMapPixels(into, &area, &picture, job.alpha) == graphics_library.GERR_OK;
            },
            .tint => return gb.BlendBitMapRect(into, &area, job.pen) == graphics_library.GERR_OK,
            .scale, .shape, .tile => {
                const rp = drawing.port(job, on_board, &plain) orelse return false;
                defer gb.FreeRastPort(rp);
                const from = job.from;
                switch (job.kind) {
                    .scale => gb.ScalePixelArray(rp, drawing.picture, blits_pitch, @intFromEnum(job.format), &.{ .min_x = from.x, .min_y = from.y, .max_x = from.x + from.width, .max_y = from.y + from.height }, &rect),
                    .shape => gb.BltTemplate(rp, drawing.shape, shape_pitch, from.x, from.y, &rect),
                    else => gb.BltPattern(rp, drawing.tile, tile_pitch, job.tile_width, job.tile_height, &rect),
                }
                return true;
            },
        }
    }
};

/// KERNELS' picture: each pixel's colour its own, and its coverage none,
/// all or its own, in patches of 37 x 23 pixels, so that every way a
/// pixel is laid is taken.
fn paintPicture(pixels: [*]u8) void {
    for (0..blits_height) |row_index| {
        const y: u32 = @intCast(row_index);
        const row: [*]u32 = @ptrCast(@alignCast(pixels + y * blits_pitch));
        for (0..blits_width) |column| {
            const x: u32 = @intCast(column);
            const colour = patternAt(x, y, 0x5151_5151);
            const coverage: u32 = switch ((x / 37 + y / 23) % 4) {
                0 => 0,
                1 => 0xFF,
                else => colour >> 24,
            };
            row[column] = (colour & 0x00FF_FFFF) | (coverage << 24);
        }
    }
}

/// KERNELS: the board's own blends, scales, shapes and tiles, drawn
/// through graphics.library into the board's buffer and held to
/// graphics.library's on plain memory pixel for pixel, each timed beside
/// it: first with every job the board's kernels can do handed to them
/// (RTG_AMD_ENGINE_ALL), then by the board's own rule.
fn kernelsCheck(sys: *ExecBase, dl: *DosBase, ab: *AMDGPUBase, millis: u32) i32 {
    const rtg_lib = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(rtg_lib);
    const rb: *RtgBase = @ptrCast(rtg_lib);
    const board = amdBoard(dl, rb) orelse return dos.RETURN_WARN;
    const graphics_lib = sys.OpenLibrary("graphics.library", 0) orelse {
        _ = Printf(dl, "No graphics.library\n", .{});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(graphics_lib);

    // The board's buffer, the plain one, the picture, the shapes' bits,
    // the tiles' and the memory that fills the caches, each on 256 bytes.
    const sizes = [_]u32{ blits_bytes, blits_bytes, blits_bytes, shape_pitch * shape_rows, tile_pitch * tile_rows, read_through_bytes };
    var allocations: [sizes.len]?*anyopaque = @splat(null);
    defer for (allocations) |allocation| if (allocation) |memory| sys.FreeVec(memory);
    var starts: [sizes.len][*]u8 = undefined;
    for (sizes, &allocations, &starts) |bytes, *allocation, *start| {
        const memory = sys.AllocVec(bytes + 256, exec.MEMF_ANY) orelse {
            _ = Printf(dl, "No memory for %u bytes\n", .{bytes});
            return dos.RETURN_FAIL;
        };
        allocation.* = memory;
        start.* = @ptrFromInt(@intFromPtr(memory) + 255 & ~@as(usize, 255));
    }
    var attached: [2]?*rtg.RtgBitMap = @splat(null);
    defer for (attached) |bitmap| rb.FreeBitMap(bitmap);
    var bitmaps: [2]*rtg.RtgBitMap = undefined;
    for (0..2) |halves| {
        const described = drawnBitMap(starts[0], halves == 1);
        const bitmap = rb.AttachBitMap(board, &described) orelse {
            _ = Printf(dl, "The board does not take a buffer at %lx\n", .{@as(u64, @intFromPtr(starts[0]))});
            return dos.RETURN_FAIL;
        };
        attached[halves] = bitmap;
        bitmaps[halves] = bitmap;
    }
    paintPicture(starts[2]);
    for (0..sizes[3]) |index| starts[3][index] = @truncate(patternAt(@intCast(index), 0, 0x77) >> 11);
    for (0..sizes[4]) |index| starts[4][index] = @truncate(patternAt(@intCast(index), 1, 0x99) >> 11);
    const drawing: Drawing = .{
        .sys = sys,
        .gb = @ptrCast(graphics_lib),
        .board_pixels = starts[0],
        .plain_pixels = starts[1],
        .bitmaps = bitmaps,
        .picture = starts[2],
        .shape = starts[3],
        .tile = starts[4],
        .evict = starts[5],
    };
    const wb = arm(sys, dl, millis) orelse return dos.RETURN_FAIL;
    defer wb.DisarmWatchdog();
    // The board's start of its engines ended, whatever it came to; its
    // own rule again at the end, whatever happens.
    _ = rb.BoardControl(board, rtg.boards.RTGCTRL_SETTLED, 0);
    defer _ = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_ENGINE, rtg.tags.RTG_AMD_ENGINE_SIZE);
    _ = Printf(dl, "The board's buffer at %lx, the plain one at %lx, the picture at %lx, %u x %u, four bytes a pixel, or twice as many of two\n", .{
        @as(u64, @intFromPtr(starts[0])), @as(u64, @intFromPtr(starts[1])), @as(u64, @intFromPtr(starts[2])), blits_width, blits_height,
    });

    var all_right = true;
    var all_wrong: u32 = 0;
    for ([_]isize{ rtg.tags.RTG_AMD_ENGINE_ALL, rtg.tags.RTG_AMD_ENGINE_SIZE }) |rule| {
        const before = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_ENGINE, rule);
        if (before < 0) {
            _ = Printf(dl, "The board does not take RTGCTRL_AMD_ENGINE (%ld)\n", .{@as(i64, before)});
            return dos.RETURN_WARN;
        }
        _ = Printf(dl, "%s\n", .{@as([*:0]const u8, if (rule == rtg.tags.RTG_AMD_ENGINE_ALL) "Every job the board's kernels can do handed to them:" else "By the board's own rule:")});
        _ = Printf(dl, "  %-32s %-8s %9s %9s %8s\n", .{ "job", "board", "board us", "CPU us", "wrong" });
        var taken: u32 = 0;
        for (drawn_jobs, 0..) |job, index| {
            drawing.paint(job.halves, @intCast(index + 1));
            drawing.evicted();
            var began = sys.UptimeUs();
            if (!drawing.draw(job, false)) {
                _ = Printf(dl, "graphics.library did not draw %s\n", .{job.name});
                return dos.RETURN_FAIL;
            }
            const library_us = sys.UptimeUs() - began;
            // The kernels' jobs, as the compute engine's queue counts
            // them, tell whose the board's drawing was.
            var state: amdgpu.GPUComputeState = .{};
            _ = ab.GetGPUComputeState(&state);
            const sent = state.sent;
            drawing.evicted();
            began = sys.UptimeUs();
            if (!drawing.draw(job, true)) {
                _ = Printf(dl, "graphics.library did not draw %s into the board's buffer\n", .{job.name});
                return dos.RETURN_FAIL;
            }
            const board_us = sys.UptimeUs() - began;
            _ = ab.GetGPUComputeState(&state);
            const by_kernels = state.sent != sent;
            const wrong = drawing.wrong(job.halves);
            _ = Printf(dl, "  %-32s %-8s %9lu %9lu %8u\n", .{ job.name, @as([*:0]const u8, if (by_kernels) "kernels" else "cores"), board_us, library_us, wrong });
            taken += @intFromBool(by_kernels);
            all_wrong += wrong;
            wb.FeedWatchdog();
        }
        _ = Printf(dl, "%u of %u jobs taken by the board's kernels\n", .{ taken, @as(u32, drawn_jobs.len) });
        if (rule == rtg.tags.RTG_AMD_ENGINE_ALL and taken == 0) {
            _ = Printf(dl, "The board's kernels took no job: see C:Log\n", .{});
            all_right = false;
        }
    }
    _ = Printf(dl, "%u pixels wrong\n", .{all_wrong});
    return if (all_right and all_wrong == 0) dos.RETURN_OK else dos.RETURN_WARN;
}

/// How long CYCLE waits for a picture to change by itself and then to
/// hold, in ticks of 20 ms.
const change_wait_ticks: u32 = 100;
const held_ticks: u32 = 5;

/// The pipe's registers as RtgAmdPipe holds them, on one line.
fn printPipe(dl: *DosBase, name: [*:0]const u8, registers: *const [rtg.tags.RTG_AMD_PIPE_REGISTERS]u32) void {
    _ = Printf(dl, "%-8s", .{name});
    for (registers) |register| _ = Printf(dl, " %08lx", .{@as(u64, register)});
    _ = Printf(dl, "\n", .{});
}

/// A clock's levels on one line, in MHz.
fn printLevels(dl: *DosBase, name: [*:0]const u8, levels: []const u32) void {
    _ = Printf(dl, "%-28s", .{name});
    if (levels.len == 0) _ = Printf(dl, " none", .{});
    for (levels) |level| _ = Printf(dl, " %u", .{level});
    _ = Printf(dl, " MHz\n", .{});
}

/// What a connector's kind is called.
fn kindName(kind: u32) [*:0]const u8 {
    return switch (kind) {
        amdgpu.GPUCONNECTOR_DVI => "DVI",
        amdgpu.GPUCONNECTOR_HDMI => "HDMI",
        amdgpu.GPUCONNECTOR_DISPLAYPORT => "DP",
        amdgpu.GPUCONNECTOR_EDP => "eDP",
        amdgpu.GPUCONNECTOR_USBC => "USB-C",
        else => "other",
    };
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [arg_count]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_ERROR;
    };
    defer dl.FreeArgs(rda);
    const ab: *AMDGPUBase = @ptrCast(sys.OpenResource(amdgpu.AMDGPUNAME) orelse {
        _ = Printf(dl, "No %s\n", .{amdgpu.AMDGPUNAME});
        return dos.RETURN_FAIL;
    });
    var info: amdgpu.GPUInfo = .{};
    if (!ab.GetGPUInfo(&info)) {
        _ = Printf(dl, "No AMD graphics device\n", .{});
        return dos.RETURN_WARN;
    }
    if (argv[arg_bios] != 0) return bios(dl, ab);
    if (argv[arg_dmcub] != 0 and argv[arg_start] == 0) return controller(sys, dl, null);
    if (argv[arg_watchdog] == 0) {
        _ = Printf(dl, "%s: WATCHDOG is required for a step that writes to the device\n", .{COMMAND_NAME});
        return dos.RETURN_ERROR;
    }
    const millis: u32 = @intCast(@max(1, @as(*const i32, @ptrFromInt(argv[arg_watchdog])).*));
    if (argv[arg_clocks] != 0) return clocks(sys, dl, millis);
    if (argv[arg_dmcub] != 0) return controller(sys, dl, millis);
    if (argv[arg_crc] != 0) return checksum(sys, dl, millis);
    if (argv[arg_events] != 0) return events(sys, dl, millis, if (argv[arg_line] != 0) number(argv[arg_line]) else 0);
    if (argv[arg_aux] != 0) {
        var request: rtg.tags.RtgAmdAux = .{
            .instance = number(argv[arg_aux]),
            .kind = if (argv[arg_i2c] != 0) rtg.tags.RTG_AMD_AUX_I2C else rtg.tags.RTG_AMD_AUX_DPCD,
            .address = number(argv[arg_address]),
            .length = if (argv[arg_length] != 0) number(argv[arg_length]) else 16,
            .through = if (argv[arg_controller] != 0) rtg.tags.RTG_AMD_AUX_BY_CONTROLLER else rtg.tags.RTG_AMD_AUX_BY_ENGINE,
        };
        return auxRead(sys, dl, millis, &request);
    }
    if (argv[arg_edid] != 0) {
        var request: rtg.tags.RtgAmdEdid = .{};
        if (argv[arg_connector] != 0) request.connector = number(argv[arg_connector]);
        return edidRead(sys, dl, millis, &request);
    }
    if (argv[arg_cycle] != 0) return pipeCycle(sys, dl, millis);
    if (argv[arg_modes] != 0 and argv[arg_sleep] == 0) return everyMode(sys, dl, millis, if (argv[arg_hold] != 0) number(argv[arg_hold]) else 2);
    if (argv[arg_range] != 0) return rangeCheck(sys, dl, millis);
    if (argv[arg_pointer] != 0) return pointerCheck(sys, dl, ab, info, millis);
    if (argv[arg_mirror] != 0) return mirrorCheck(sys, dl, millis);
    if (argv[arg_overlay] != 0) return overlayCheck(sys, dl, ab, info, millis);
    if (argv[arg_direct] != 0) return directCheck(sys, dl, ab, info, millis);
    if (argv[arg_bands] != 0) return bandsCheck(sys, dl, ab, info, millis);
    if (argv[arg_video] != 0) return videoCheck(sys, dl, ab, info, millis);
    if (argv[arg_blits] != 0) return blitsCheck(sys, dl, millis);
    if (argv[arg_kernels] != 0) return kernelsCheck(sys, dl, ab, millis);
    if (argv[arg_sleep] != 0) return asleepFor(sys, dl, ab, info, millis, number(argv[arg_sleep]), argv[arg_modes] != 0);
    if (argv[arg_gfx] != 0 or argv[arg_dma] != 0 or argv[arg_gart] != 0 or argv[arg_engine] != 0 or argv[arg_compute] != 0) {
        const then: GraphicsThen = if (argv[arg_compute] != 0) .compute else if (argv[arg_engine] != 0) .engine else if (argv[arg_gart] != 0) .gart else if (argv[arg_dma] != 0) .dma else .nothing;
        return graphicsStart(sys, dl, ab, info, millis, then);
    }
    if (argv[arg_dump] != 0) {
        const length = if (argv[arg_length] != 0) number(argv[arg_length]) else 16;
        const id = if (argv[arg_block] != 0) number(argv[arg_block]) else amdgpu.GPUBLOCK_DISPLAY;
        const segment: u32 = if (argv[arg_segment] != 0) number(argv[arg_segment]) else if (argv[arg_block] != 0) 0 else 2;
        return dump(sys, dl, ab, info, millis, id, segment, number(argv[arg_dump]), length);
    }
    if (argv[arg_frames] != 0 or argv[arg_flip] != 0) {
        const pipe = number(argv[arg_pipe]);
        const fetcher = number(argv[arg_fetcher]);
        return display(sys, dl, ab, info, millis, pipe, fetcher, argv[arg_flip] != 0);
    }
    var security: amdgpu.GPUBlock = .{};
    var video: amdgpu.GPUBlock = .{};
    if (!ab.FindGPUBlock(amdgpu.GPUBLOCK_SECURITY, 0, &security) or !ab.FindGPUBlock(amdgpu.GPUBLOCK_VIDEO, 0, &video)) {
        _ = Printf(dl, "The device %04x:%04x names no security processor or no video decoder\n", .{ info.vendor, info.device });
        return dos.RETURN_FAIL;
    }
    _ = Printf(dl, "Device %04x:%04x: security processor %u.%u.%u, video decoder %u.%u.%u\n", .{
        info.vendor,                 info.device,           @as(u32, security.major), @as(u32, security.minor),
        @as(u32, security.revision), @as(u32, video.major), @as(u32, video.minor),    @as(u32, video.revision),
    });

    const toc_name = Name.of("psp_", security, "_toc.bin");
    const firmware_name = Name.of("vcn_", video, ".bin");
    const toc_path: [*:0]const u8 = if (argv[arg_toc] != 0) @ptrFromInt(argv[arg_toc]) else toc_name.string();
    const firmware_path: [*:0]const u8 = if (argv[arg_firmware] != 0) @ptrFromInt(argv[arg_firmware]) else firmware_name.string();
    const toc = readFile(sys, dl, toc_path) orelse return dos.RETURN_ERROR;
    defer sys.FreeVec(toc.ptr);
    const firmware = readFile(sys, dl, firmware_path) orelse return dos.RETURN_ERROR;
    defer sys.FreeVec(firmware.ptr);
    _ = Printf(dl, "%s: %lu bytes\n%s: %lu bytes\n", .{ toc_path, @as(u64, toc.len), firmware_path, @as(u64, firmware.len) });

    const wb: *WatchdogBase = @ptrCast(sys.OpenResource(watchdog.WATCHDOGNAME) orelse {
        _ = Printf(dl, "No %s\n", .{watchdog.WATCHDOGNAME});
        return dos.RETURN_FAIL;
    });
    if (!wb.ArmWatchdog(millis, watchdog.WATCHDOG_RESET_SYSTEM)) {
        _ = Printf(dl, "The watchdog refuses %u ms\n", .{millis});
        return dos.RETURN_FAIL;
    }
    defer wb.DisarmWatchdog();
    _ = Printf(dl, "Watchdog armed: %u ms\n", .{millis});

    if (!ab.StartGPUSecurity(toc.ptr, @intCast(toc.len))) {
        wb.FeedWatchdog();
        _ = Printf(dl, "The security processor is not ready: see C:Log\n", .{});
        return dos.RETURN_ERROR;
    }
    wb.FeedWatchdog();
    _ = Printf(dl, "The security processor is ready\n", .{});

    var address: u64 = 0;
    if (!ab.LoadGPUFirmware(amdgpu.GPUFIRMWARE_VIDEO, firmware.ptr, @intCast(firmware.len), &address)) {
        wb.FeedWatchdog();
        _ = Printf(dl, "The video decoder's firmware is not loaded: see C:Log\n", .{});
        return dos.RETURN_ERROR;
    }
    wb.FeedWatchdog();
    _ = Printf(dl, "The video decoder's firmware is at 0x%lx\n", .{address});
    return dos.RETURN_OK;
}

fn number(arg: usize) u32 {
    if (arg == 0) return 0;
    return @intCast(@max(0, @as(*const i32, @ptrFromInt(arg)).*));
}

// --- the display ---------------------------------------------------------------------

/// The display engine's registers, and the pipe and fetcher tried.
const Display = struct {
    registers: usize,
    segment: u32,
    pipe: u32,
    fetcher: u32,

    fn at(display_: Display, offset: u32) *volatile u32 {
        return reg(display_.registers + @as(usize, display_.segment + offset) * 4);
    }

    fn otg(display_: Display, offset: u32) *volatile u32 {
        return display_.at(offset + dcn.OTG_STRIDE * display_.pipe);
    }

    fn hubp(display_: Display, offset: u32) *volatile u32 {
        return display_.at(offset + dcn.HUBP_STRIDE * display_.fetcher);
    }

    /// The address the fetcher is told to read, and the one it reads.
    fn told(display_: Display) u64 {
        return @as(u64, display_.hubp(dcn.DCSURF_PRIMARY_SURFACE_ADDRESS_HIGH).* & dcn.ADDRESS_HIGH_MASK) << 32 |
            display_.hubp(dcn.DCSURF_PRIMARY_SURFACE_ADDRESS).*;
    }

    fn reading(display_: Display) u64 {
        return @as(u64, display_.hubp(dcn.DCSURF_SURFACE_EARLIEST_INUSE_HIGH).* & dcn.ADDRESS_HIGH_MASK) << 32 |
            display_.hubp(dcn.DCSURF_SURFACE_EARLIEST_INUSE).*;
    }
};

/// The pipe's interrupt at each frame: counted, acknowledged, and the
/// task told.
const Frames = struct {
    sys: *ExecBase,
    display: Display,
    count: u32 = 0,
    came: exec.Waitable = .{},
    server: exec.Interrupt = .{},
};

fn frameServer(data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const frames: *Frames = @ptrCast(@alignCast(data.?));
    const status = frames.display.otg(dcn.OTG_GLOBAL_SYNC_STATUS);
    status.* = status.* | dcn.VUPDATE_NO_LOCK_EVENT_CLEAR;
    @atomicStore(u32, &frames.count, frames.count +% 1, .release);
    frames.sys.SignalWaitable(&frames.came);
    return 1;
}

/// The server on and the interrupt switched on at the pipe; false where
/// the resource takes no server.
fn hook(ab: *AMDGPUBase, frames: *Frames) bool {
    frames.server = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = COMMAND_NAME },
        .data = frames,
        .code = &frameServer,
    };
    if (!ab.AddGPUIntServer(amdgpu.GPUINT_CLIENT_DISPLAY, amdgpu.GPUINT_DISPLAY_UPDATE + frames.display.pipe, &frames.server)) return false;
    const status = frames.display.otg(dcn.OTG_GLOBAL_SYNC_STATUS);
    frames.sys.Disable();
    status.* = status.* | dcn.VUPDATE_NO_LOCK_EVENT_CLEAR | dcn.VUPDATE_NO_LOCK_INT_EN;
    frames.sys.Enable();
    return true;
}

fn unhook(ab: *AMDGPUBase, frames: *Frames) void {
    const status = frames.display.otg(dcn.OTG_GLOBAL_SYNC_STATUS);
    frames.sys.Disable();
    status.* = status.* & ~dcn.VUPDATE_NO_LOCK_INT_EN | dcn.VUPDATE_NO_LOCK_EVENT_CLEAR;
    frames.sys.Enable();
    ab.RemGPUIntServer(&frames.server);
}

/// The E-clock in microseconds.
fn micros(tb: *TimerBase) u64 {
    var value: timer.EClockVal = .{};
    const rate = tb.ReadEClock(&value);
    const count = value.toTicks();
    return count / rate * 1_000_000 + count % rate * 1_000_000 / rate;
}

/// Half-seconds waited, the watchdog fed after each.
/// SLEEP: the board's monitor asleep for `seconds`, then woken, the
/// picture's checksum and pipe 0's count of frames read before, while
/// asleep and after; with `moving`, shown in another mode and back while
/// asleep.
fn asleepFor(sys: *ExecBase, dl: *DosBase, ab: *AMDGPUBase, info: amdgpu.GPUInfo, millis: u32, seconds: u32, moving: bool) i32 {
    var block: amdgpu.GPUBlock = .{};
    if (!ab.FindGPUBlock(amdgpu.GPUBLOCK_DISPLAY, 0, &block) or block.count < 3) {
        _ = Printf(dl, "The device %04x:%04x names no display engine\n", .{ info.vendor, info.device });
        return dos.RETURN_FAIL;
    }
    const engine = Display{ .registers = @intCast(info.registers), .segment = block.addresses[2], .pipe = 0, .fetcher = 0 };
    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);
    const board = amdBoard(dl, rb) orelse return dos.RETURN_WARN;
    const wb = arm(sys, dl, millis) orelse return dos.RETURN_FAIL;
    defer wb.DisarmWatchdog();

    printChecksum(dl, rb, board, "before");
    printFrames(dl, engine, "before");
    const slept = rb.SetBoardPower(board, rtg.boards.RTGPWR_ASLEEP);
    wb.FeedWatchdog();
    _ = Printf(dl, "asleep: %s, the board says %s\n", .{ powerAnswer(rb, slept), powerName(powerOf(rb, board)) });
    dl.Delay(8);
    printChecksum(dl, rb, board, "asleep");
    printFrames(dl, engine, "asleep");
    hold(dl, wb, 2 * seconds);
    printFrames(dl, engine, "later");
    var moved = true;
    if (moving) moved = anotherMode(dl, rb, board, wb);
    const woken = rb.SetBoardPower(board, rtg.boards.RTGPWR_ON);
    wb.FeedWatchdog();
    _ = Printf(dl, "awake: %s, the board says %s\n", .{ powerAnswer(rb, woken), powerName(powerOf(rb, board)) });
    dl.Delay(8);
    printChecksum(dl, rb, board, "after");
    printFrames(dl, engine, "after");
    if (slept != @as(i32, @intCast(rtg.boards.RTGPWR_ASLEEP)) or woken != @as(i32, @intCast(rtg.boards.RTGPWR_ON))) return dos.RETURN_WARN;
    return if (moved) dos.RETURN_OK else dos.RETURN_ERROR;
}

/// The board shown in the first mode it offers but the one it is in,
/// with a picture of bars, the set printed and the frames counted; then
/// back in its mode, showing what it showed. Whether both shows went.
fn anotherMode(dl: *DosBase, rb: *RtgBase, board: *rtg.RtgBoard, wb: *WatchdogBase) bool {
    var list: [modes_most]rtg.RtgMode = undefined;
    const count = @min(rb.GetBoardModes(board, &list, modes_most), modes_most);
    var was: ?*const rtg.RtgMode = null;
    var other: ?*const rtg.RtgMode = null;
    for (list[0..count]) |*one| {
        if (one.flags & rtg.modes.RTGMF_CURRENT != 0) was = one else if (other == null) other = one;
    }
    const from = was orelse return false;
    const to = other orelse {
        _ = Printf(dl, "no other mode\n", .{});
        return false;
    };
    const before = rb.BoardDisplayBitMap(board) orelse return false;
    const picture = rb.AllocBitMap(board, to.width, to.height, @intFromEnum(to.format), rtg.bitmaps.RTGBMF_DISPLAYABLE) orelse {
        _ = Printf(dl, "no room for a picture of %ux%u\n", .{ to.width, to.height });
        return false;
    };
    bars(picture);
    _ = rb.RefreshRect(picture, null);
    const band = [_]rtg.RtgBand{.{ .bitmap = picture }};
    const shown = rb.ShowBoard(board, to.id, &band, band.len);
    wb.FeedWatchdog();
    var account: rtg.tags.RtgAmdPipe = .{};
    _ = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_MODE, @bitCast(@intFromPtr(&account)));
    const name: [*:0]const u8 = @ptrCast(&to.name);
    _ = Printf(dl, "asleep, shown in %s: %s, set at %u kHz, the board says %s\n", .{ name, rb.RtgErrorText(shown), account.pixel_khz, powerName(powerOf(rb, board)) });
    const back_band = [_]rtg.RtgBand{.{ .bitmap = before }};
    const back = rb.ShowBoard(board, from.id, &back_band, back_band.len);
    wb.FeedWatchdog();
    _ = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_MODE, @bitCast(@intFromPtr(&account)));
    const back_name: [*:0]const u8 = @ptrCast(&from.name);
    _ = Printf(dl, "asleep, back in %s: %s, set at %u kHz, the board says %s\n", .{ back_name, rb.RtgErrorText(back), account.pixel_khz, powerName(powerOf(rb, board)) });
    // Shown no longer, the bars are given back.
    if (shown == rtg.errors.RTGERR_OK and back == rtg.errors.RTGERR_OK) rb.FreeBitMap(picture);
    return shown == rtg.errors.RTGERR_OK and back == rtg.errors.RTGERR_OK;
}

/// The picture's checksum, read twice a few frames apart, on a line.
fn printChecksum(dl: *DosBase, rb: *RtgBase, board: *rtg.RtgBoard, when: [*:0]const u8) void {
    var first: rtg.tags.RtgAmdCrc = .{};
    var second: rtg.tags.RtgAmdCrc = .{};
    const read_first = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_CRC, @bitCast(@intFromPtr(&first)));
    dl.Delay(3);
    const read_second = rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_CRC, @bitCast(@intFromPtr(&second)));
    if (read_first != rtg.errors.RTGERR_OK or read_second != rtg.errors.RTGERR_OK) {
        _ = Printf(dl, "%-7s no checksum\n", .{when});
        return;
    }
    const same = first.red == second.red and first.green == second.green and first.blue == second.blue;
    _ = Printf(dl, "%-7s checksum %04x %04x %04x%s\n", .{ when, second.red, second.green, second.blue, @as([*:0]const u8, if (same) "" else " CHANGING") });
}

/// A still picture of bars shown on the board in the mode it is in, and
/// the picture shown before, which `end` shows again.
const Still = struct {
    rb: *RtgBase,
    board: *rtg.RtgBoard,
    mode_id: u32,
    before: *rtg.RtgBitMap,
    picture: *rtg.RtgBitMap,

    fn begin(dl: *DosBase, rb: *RtgBase, board: *rtg.RtgBoard) ?Still {
        var list: [modes_most]rtg.RtgMode = undefined;
        const count = @min(rb.GetBoardModes(board, &list, modes_most), modes_most);
        var current: ?*const rtg.RtgMode = null;
        for (list[0..count]) |*one| {
            if (one.flags & rtg.modes.RTGMF_CURRENT != 0) current = one;
        }
        const shown = current orelse {
            _ = Printf(dl, "The board is in no mode\n", .{});
            return null;
        };
        const before = rb.BoardDisplayBitMap(board) orelse {
            _ = Printf(dl, "The board shows no picture\n", .{});
            return null;
        };
        const picture = rb.AllocBitMap(board, shown.width, shown.height, @intFromEnum(shown.format), rtg.bitmaps.RTGBMF_DISPLAYABLE) orelse {
            _ = Printf(dl, "No room for a picture of %ux%u\n", .{ shown.width, shown.height });
            return null;
        };
        bars(picture);
        _ = rb.RefreshRect(picture, null);
        const band = [_]rtg.RtgBand{.{ .bitmap = picture }};
        if (rb.ShowBoard(board, shown.id, &band, band.len) != rtg.errors.RTGERR_OK) {
            rb.FreeBitMap(picture);
            _ = Printf(dl, "The bars were not shown\n", .{});
            return null;
        }
        return .{ .rb = rb, .board = board, .mode_id = shown.id, .before = before, .picture = picture };
    }

    /// The picture before shown again, and the bars freed once they are
    /// no longer shown.
    fn end(still: Still) void {
        const band = [_]rtg.RtgBand{.{ .bitmap = still.before }};
        if (still.rb.ShowBoard(still.board, still.mode_id, &band, band.len) == rtg.errors.RTGERR_OK) still.rb.FreeBitMap(still.picture);
    }
};

/// RANGE: a still picture's checksum in full range, limited and full
/// again.
fn rangeCheck(sys: *ExecBase, dl: *DosBase, millis: u32) i32 {
    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);
    const board = amdBoard(dl, rb) orelse return dos.RETURN_WARN;
    var info: rtg.RtgBoardInfo = .{};
    _ = rb.GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    if (info.caps & rtg.boards.RTGBC_COLOR_RANGE == 0) {
        _ = Printf(dl, "The board does not send its colours in another range\n", .{});
        return dos.RETURN_WARN;
    }
    const wb = arm(sys, dl, millis) orelse return dos.RETURN_FAIL;
    defer wb.DisarmWatchdog();
    const still = Still.begin(dl, rb, board) orelse return dos.RETURN_FAIL;
    defer still.end();
    wb.FeedWatchdog();
    var line: rtg.RtgSettings = .{};
    _ = rb.GetBoardSettings(board, &line, @sizeOf(rtg.RtgSettings));
    const kept = line;

    dl.Delay(8);
    printChecksum(dl, rb, board, "full");
    line.flags |= rtg.RTGSET_RANGE | rtg.RTGSET_LIMITED_RANGE;
    _ = rb.SetBoardSettings(board, &line);
    wb.FeedWatchdog();
    dl.Delay(8);
    printChecksum(dl, rb, board, "limited");
    line.flags &= ~@as(u32, rtg.RTGSET_LIMITED_RANGE);
    _ = rb.SetBoardSettings(board, &line);
    wb.FeedWatchdog();
    dl.Delay(8);
    printChecksum(dl, rb, board, "full");

    var back = kept;
    _ = rb.SetBoardSettings(board, &back);
    return dos.RETURN_OK;
}

/// Pipe 0's cursor, a fetcher's stride apart: its control - bit 0 shown
/// - its place and its hot spot.
const cursor_control = 0x0678;
const cursor_position = 0x067c;
const cursor_hot_spot = 0x067d;

/// POINTER: a still picture's checksum with the pointer hidden, at
/// three places and hidden again, and what the cursor is told at each.
fn pointerCheck(sys: *ExecBase, dl: *DosBase, ab: *AMDGPUBase, info: amdgpu.GPUInfo, millis: u32) i32 {
    var block: amdgpu.GPUBlock = .{};
    if (!ab.FindGPUBlock(amdgpu.GPUBLOCK_DISPLAY, 0, &block) or block.count < 3) {
        _ = Printf(dl, "The device %04x:%04x names no display engine\n", .{ info.vendor, info.device });
        return dos.RETURN_FAIL;
    }
    const engine = Display{ .registers = @intCast(info.registers), .segment = block.addresses[2], .pipe = 0, .fetcher = 0 };
    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);
    const board = amdBoard(dl, rb) orelse return dos.RETURN_WARN;
    const was_x = board.pointer_x;
    const was_y = board.pointer_y;
    const was_shown = board.info.flags & rtg.boards.RTGBF_POINTER != 0;
    const wb = arm(sys, dl, millis) orelse return dos.RETURN_FAIL;
    defer wb.DisarmWatchdog();
    const still = Still.begin(dl, rb, board) orelse return dos.RETURN_FAIL;
    defer still.end();
    defer {
        rb.MoveBoardPointer(board, was_x, was_y);
        _ = rb.ShowBoardPointer(board, was_shown);
    }

    _ = rb.ShowBoardPointer(board, false);
    pointerAt(dl, rb, board, engine, "hidden");
    const places = [_][2]i32{ .{ 200, 150 }, .{ 900, 500 }, .{ -5, -5 } };
    for (places) |place| {
        rb.MoveBoardPointer(board, place[0], place[1]);
        _ = rb.ShowBoardPointer(board, true);
        wb.FeedWatchdog();
        var name: [24]u8 = undefined;
        const stream = exec.fmtStream(.{ place[0], place[1] });
        _ = sys.RawDoFmt("%d,%d", &stream, null, &name);
        pointerAt(dl, rb, board, engine, @ptrCast(&name));
    }
    _ = rb.ShowBoardPointer(board, false);
    wb.FeedWatchdog();
    pointerAt(dl, rb, board, engine, "hidden");
    return dos.RETURN_OK;
}

/// MIRROR: for each way of mirroring, the checksum of the picture and
/// the pointer as this program mirrors them, and as the board does.
fn mirrorCheck(sys: *ExecBase, dl: *DosBase, millis: u32) i32 {
    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);
    const board = amdBoard(dl, rb) orelse return dos.RETURN_WARN;
    var info: rtg.RtgBoardInfo = .{};
    _ = rb.GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    const image = board.pointer orelse {
        _ = Printf(dl, "The board has no pointer image\n", .{});
        return dos.RETURN_WARN;
    };
    if (image.format != .bgra32) {
        _ = Printf(dl, "The board's pointer is not in bgra32\n", .{});
        return dos.RETURN_WARN;
    }
    const was_x = board.pointer_x;
    const was_y = board.pointer_y;
    const was_shown = board.info.flags & rtg.boards.RTGBF_POINTER != 0;
    const wb = arm(sys, dl, millis) orelse return dos.RETURN_FAIL;
    defer wb.DisarmWatchdog();
    const still = Still.begin(dl, rb, board) orelse return dos.RETURN_FAIL;
    const picture = still.picture;
    marker(picture);
    _ = rb.RefreshRect(picture, null);
    const reference = rb.AllocBitMap(board, picture.width, picture.height, @intFromEnum(picture.format), rtg.bitmaps.RTGBMF_DISPLAYABLE) orelse {
        still.end();
        _ = Printf(dl, "No room for a second picture\n", .{});
        return dos.RETURN_FAIL;
    };
    const picture_band = [_]rtg.RtgBand{.{ .bitmap = picture }};
    const reference_band = [_]rtg.RtgBand{.{ .bitmap = reference }};
    const ways = [_][2]bool{ .{ false, false }, .{ true, false }, .{ false, true }, .{ true, true } };
    const names = [_][*:0]const u8{ "none", "x", "y", "x and y" };
    const near_end_x: i32 = @intCast(picture.width - 5);
    const near_end_y: i32 = @intCast(picture.height - 10);
    const places = [_]?[2]i32{ null, .{ 300, 200 }, .{ -3, -4 }, .{ near_end_x, near_end_y } };
    var differ: u32 = 0;
    for (ways, names) |way, name| {
        for (places) |maybe_place| {
            turned(reference, picture, way[0], way[1]);
            if (maybe_place) |place| drawPointer(reference, image, place[0] - @as(i32, @intCast(image.hot_x)), place[1] - @as(i32, @intCast(image.hot_y)), way[0], way[1]);
            _ = rb.RefreshRect(reference, null);
            _ = rb.MirrorBoard(board, false, false);
            _ = rb.ShowBoardPointer(board, false);
            _ = rb.ShowBoard(board, still.mode_id, &reference_band, reference_band.len);
            wb.FeedWatchdog();
            const drawn = steadyChecksum(dl, rb, board);
            _ = rb.ShowBoard(board, still.mode_id, &picture_band, picture_band.len);
            _ = rb.MirrorBoard(board, way[0], way[1]);
            if (maybe_place) |place| {
                rb.MoveBoardPointer(board, place[0], place[1]);
                _ = rb.ShowBoardPointer(board, true);
            }
            wb.FeedWatchdog();
            const mirrored = steadyChecksum(dl, rb, board);
            const same = drawn != null and mirrored != null and sameSum(drawn.?, mirrored.?);
            if (!same) differ += 1;
            const place = maybe_place orelse [2]i32{ 0, 0 };
            _ = Printf(dl, "%-8s pointer %-6s %d,%d: drawn %04x %04x %04x, the board's %04x %04x %04x%s\n", .{
                name,                              @as([*:0]const u8, if (maybe_place == null) "hidden" else "at"), place[0],                                                      place[1],
                if (drawn) |sum| sum[0] else 0,    if (drawn) |sum| sum[1] else 0,                                  if (drawn) |sum| sum[2] else 0,                                if (mirrored) |sum| sum[0] else 0,
                if (mirrored) |sum| sum[1] else 0, if (mirrored) |sum| sum[2] else 0,                               @as([*:0]const u8, if (same) ", the same" else ", DIFFERENT"),
            });
        }
    }
    _ = rb.MirrorBoard(board, info.mirror_x != 0, info.mirror_y != 0);
    rb.MoveBoardPointer(board, was_x, was_y);
    _ = rb.ShowBoardPointer(board, was_shown);
    still.end();
    rb.FreeBitMap(reference);
    return if (differ == 0) dos.RETURN_OK else dos.RETURN_WARN;
}

/// OVERLAY: for each way of mirroring and each place of the overlay, the
/// checksum of the picture, the overlay and the pointer as this program
/// mirrors them, and as the board does.
fn overlayCheck(sys: *ExecBase, dl: *DosBase, ab: *AMDGPUBase, info: amdgpu.GPUInfo, millis: u32) i32 {
    var block: amdgpu.GPUBlock = .{};
    if (!ab.FindGPUBlock(amdgpu.GPUBLOCK_DISPLAY, 0, &block) or block.count < 4) {
        _ = Printf(dl, "The device %04x:%04x names no display engine with a blender\n", .{ info.vendor, info.device });
        return dos.RETURN_FAIL;
    }
    const engine = Display{ .registers = @intCast(info.registers), .segment = block.addresses[2], .pipe = 0, .fetcher = 0 };
    const blender = Display{ .registers = @intCast(info.registers), .segment = block.addresses[3], .pipe = 0, .fetcher = 0 };
    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);
    const board = amdBoard(dl, rb) orelse return dos.RETURN_WARN;
    var info_board: rtg.RtgBoardInfo = .{};
    _ = rb.GetBoardInfo(board, &info_board, @sizeOf(rtg.RtgBoardInfo));
    const pointer = board.pointer orelse {
        _ = Printf(dl, "The board has no pointer image\n", .{});
        return dos.RETURN_WARN;
    };
    if (pointer.format != .bgra32) {
        _ = Printf(dl, "The board's pointer is not in bgra32\n", .{});
        return dos.RETURN_WARN;
    }
    // The overlay's image: shades across and down, clear squares in it.
    const overlay_width = 120;
    const overlay_height = 80;
    const pixels = sys.AllocVec(overlay_width * overlay_height * 4, exec.MEMF_CLEAR) orelse {
        _ = Printf(dl, "No room for the overlay's image\n", .{});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(pixels);
    const words: [*]u32 = @ptrCast(@alignCast(pixels));
    for (0..overlay_height) |row| {
        for (0..overlay_width) |column| {
            const clear = (row / 10 + column / 10) % 3 == 0;
            words[row * overlay_width + column] = if (clear) 0 else 0xFF00_0000 | @as(u32, @intCast(column * 2)) << 16 | @as(u32, @intCast(row * 3)) << 8 | 0x40;
        }
    }
    const surface = rtg.Surface{ .pixels = @ptrCast(pixels), .width = overlay_width, .height = overlay_height, .pitch = overlay_width * 4, .size_bytes = overlay_width * overlay_height * 4, .format = .bgra32 };
    const was_x = board.pointer_x;
    const was_y = board.pointer_y;
    const was_shown = board.info.flags & rtg.boards.RTGBF_POINTER != 0;
    const wb = arm(sys, dl, millis) orelse return dos.RETURN_FAIL;
    defer wb.DisarmWatchdog();
    if (rb.SetBoardOverlay(board, &surface, 0, 0) != rtg.errors.RTGERR_OK) {
        _ = Printf(dl, "The board took no overlay\n", .{});
        return dos.RETURN_WARN;
    }
    const overlay = board.overlay orelse {
        _ = Printf(dl, "The board keeps no overlay image\n", .{});
        return dos.RETURN_WARN;
    };
    const still = Still.begin(dl, rb, board) orelse {
        _ = rb.SetBoardOverlay(board, null, 0, 0);
        return dos.RETURN_FAIL;
    };
    const picture = still.picture;
    marker(picture);
    _ = rb.RefreshRect(picture, null);
    const reference = rb.AllocBitMap(board, picture.width, picture.height, @intFromEnum(picture.format), rtg.bitmaps.RTGBMF_DISPLAYABLE) orelse {
        still.end();
        _ = rb.SetBoardOverlay(board, null, 0, 0);
        _ = Printf(dl, "No room for a second picture\n", .{});
        return dos.RETURN_FAIL;
    };
    const picture_band = [_]rtg.RtgBand{.{ .bitmap = picture }};
    const reference_band = [_]rtg.RtgBand{.{ .bitmap = reference }};
    const ways = [_][2]bool{ .{ false, false }, .{ true, false }, .{ false, true }, .{ true, true } };
    const names = [_][*:0]const u8{ "none", "x", "y", "x and y" };
    const width: i32 = @intCast(picture.width);
    const height: i32 = @intCast(picture.height);
    // Each place of the overlay, with the pointer over it and across its
    // edge.
    const Case = struct { overlay: [2]i32, inside: [2]i32, edge: [2]i32 };
    const cases = [_]Case{
        .{ .overlay = .{ 400, 300 }, .inside = .{ 450, 320 }, .edge = .{ 395, 295 } },
        .{ .overlay = .{ -30, -20 }, .inside = .{ 20, 15 }, .edge = .{ 85, 30 } },
        .{ .overlay = .{ width - 50, height - 40 }, .inside = .{ width - 30, height - 25 }, .edge = .{ width - 55, height - 30 } },
    };
    var differ: u32 = 0;
    var said_plane = false;
    for (ways, names) |way, name| {
        for (cases) |case| {
            const pointers = [_]?[2]i32{ null, case.inside, case.edge };
            for (pointers) |maybe_pointer| {
                turned(reference, picture, way[0], way[1]);
                drawPointer(reference, overlay, case.overlay[0], case.overlay[1], way[0], way[1]);
                if (maybe_pointer) |place| drawPointer(reference, pointer, place[0] - @as(i32, @intCast(pointer.hot_x)), place[1] - @as(i32, @intCast(pointer.hot_y)), way[0], way[1]);
                _ = rb.RefreshRect(reference, null);
                // The board's own laid off the glass while its drawing is read.
                rb.MoveBoardOverlay(board, -10_000, -10_000);
                _ = rb.MirrorBoard(board, false, false);
                _ = rb.ShowBoardPointer(board, false);
                _ = rb.ShowBoard(board, still.mode_id, &reference_band, reference_band.len);
                wb.FeedWatchdog();
                const drawn = steadyChecksum(dl, rb, board);
                _ = rb.ShowBoard(board, still.mode_id, &picture_band, picture_band.len);
                _ = rb.MirrorBoard(board, way[0], way[1]);
                rb.MoveBoardOverlay(board, case.overlay[0], case.overlay[1]);
                if (maybe_pointer) |place| {
                    rb.MoveBoardPointer(board, place[0], place[1]);
                    _ = rb.ShowBoardPointer(board, true);
                }
                wb.FeedWatchdog();
                const laid = steadyChecksum(dl, rb, board);
                if (!said_plane) {
                    said_plane = true;
                    sayPlane(dl, engine, blender);
                }
                const same = drawn != null and laid != null and sameSum(drawn.?, laid.?);
                if (!same) differ += 1;
                const place = maybe_pointer orelse [2]i32{ 0, 0 };
                _ = Printf(dl, "%-8s overlay %d,%d pointer %-6s %d,%d: drawn %04x %04x %04x, the board's %04x %04x %04x%s\n", .{
                    name,                                                          case.overlay[0],               case.overlay[1],                @as([*:0]const u8, if (maybe_pointer == null) "hidden" else "at"),
                    place[0],                                                      place[1],                      if (drawn) |sum| sum[0] else 0, if (drawn) |sum| sum[1] else 0,
                    if (drawn) |sum| sum[2] else 0,                                if (laid) |sum| sum[0] else 0, if (laid) |sum| sum[1] else 0,  if (laid) |sum| sum[2] else 0,
                    @as([*:0]const u8, if (same) ", the same" else ", DIFFERENT"),
                });
            }
        }
    }
    _ = rb.SetBoardOverlay(board, null, 0, 0);
    _ = rb.MirrorBoard(board, info_board.mirror_x != 0, info_board.mirror_y != 0);
    rb.MoveBoardPointer(board, was_x, was_y);
    _ = rb.ShowBoardPointer(board, was_shown);
    wb.FeedWatchdog();
    dl.Delay(5);
    sayPlane(dl, engine, blender);
    still.end();
    rb.FreeBitMap(reference);
    return if (differ == 0) dos.RETURN_OK else dos.RETURN_WARN;
}

// --- VIDEO --------------------------------------------------------------------------

/// The film's frame VIDEO shows: 320 by 180 in NV12, rows 512 bytes
/// apart, each plane starting 64 bytes into a run of 256 - as a frame
/// cut from a larger one does - so that the board reads it from part way
/// into what its fetcher reads by; its blocks 40 by 36.
const Film = struct {
    memory: *anyopaque,
    luma: [*]u8,
    chroma: [*]u8,
    picture: rtg.RtgYuv,

    const width = 320;
    const height = 180;
    const pitch = 512;
    const offset = 64;
    const block_width = 40;
    const block_height = 36;

    fn make(sys: *ExecBase) ?Film {
        const bytes = pitch * height + pitch * height / 2 + 256 + offset;
        const memory = sys.AllocVec(bytes, exec.MEMF_ANY) orelse return null;
        const start = (@intFromPtr(memory) + 255) / 256 * 256 + offset;
        const luma: [*]u8 = @ptrFromInt(start);
        const chroma: [*]u8 = @ptrFromInt(start + pitch * height);
        return .{
            .memory = memory,
            .luma = luma,
            .chroma = chroma,
            .picture = .{ .y = luma, .cb = chroma, .y_pitch = pitch, .c_pitch = pitch },
        };
    }

    /// Every pixel the one colour.
    fn fill(film: *Film, y: u8, cb: u8, cr: u8) void {
        for (0..height) |row| @memset(film.luma[row * pitch ..][0..width], y);
        for (0..height / 2) |row| {
            const line = film.chroma[row * pitch ..];
            for (0..width / 2) |pair| {
                line[2 * pair] = cb;
                line[2 * pair + 1] = cr;
            }
        }
    }

    /// Blocks of black and white, in a pattern no mirroring leaves as it
    /// is: a step below video's black, 15, and its white, 235, the colour
    /// none - which the engine makes exactly nothing and all of each
    /// channel, where its rounding leaves the blue of video's black, 16, a
    /// part of a step above nothing.
    fn blocks(film: *Film) void {
        film.fill(128, 128, 128);
        for (0..height) |row| {
            for (0..width) |column| film.luma[row * pitch + column] = if (white(@intCast(column), @intCast(row))) 235 else 15;
        }
    }

    /// Whether the frame's pixel at (`column`, `row`) is white.
    fn white(column: u32, row: u32) bool {
        return (column / block_width * 7 + row / block_height * 3) % 5 < 2;
    }
};

/// The colours VIDEO draws its pictures in: the background; the key, the
/// shades of it a shadow leaves, and two next to it, which hide the film.
const video_background: u32 = 0xFF40_4040;
const video_key: u32 = 0xFF08_0008;
const video_shades = [_]u32{ 0xFF04_0004, 0xFF02_0002, 0xFF01_0001 };
const video_unkeyed = [_]u32{ 0xFF09_0009, 0xFF08_0108 };

/// `colour` in the part of `rect` on the picture.
fn fillRect(into: *rtg.RtgBitMap, rect: rtg.RtgRect, colour: u32) void {
    const pixels = into.pixels orelse return;
    const left: u32 = @intCast(@max(rect.x, 0));
    const top: u32 = @intCast(@max(rect.y, 0));
    const right: u32 = @intCast(@min(@as(i64, rect.x) + rect.width, into.width));
    const bottom: u32 = @intCast(@min(@as(i64, rect.y) + rect.height, into.height));
    var row = top;
    while (row < bottom) : (row += 1) {
        const line: [*]u32 = @ptrCast(@alignCast(pixels + @as(usize, row) * into.pitch));
        var column = left;
        while (column < right) : (column += 1) line[column] = colour;
    }
}

/// The film's `part` drawn into `place` of the picture, as much of it as
/// the picture has: each pixel the one of the part it falls in, black or
/// white - the frame shown as it is, or a block's inside shown scaled.
fn drawFilm(into: *rtg.RtgBitMap, part: rtg.RtgRect, place: rtg.RtgRect) void {
    const pixels = into.pixels orelse return;
    const left: u32 = @intCast(@max(place.x, 0));
    const top: u32 = @intCast(@max(place.y, 0));
    const right: u32 = @intCast(@min(@as(i64, place.x) + place.width, into.width));
    const bottom: u32 = @intCast(@min(@as(i64, place.y) + place.height, into.height));
    var row = top;
    while (row < bottom) : (row += 1) {
        const line: [*]u32 = @ptrCast(@alignCast(pixels + @as(usize, row) * into.pitch));
        const from_y: u32 = @intCast(part.y + @divFloor((@as(i64, row) - place.y) * part.height, place.height));
        var column = left;
        while (column < right) : (column += 1) {
            const from_x: u32 = @intCast(part.x + @divFloor((@as(i64, column) - place.x) * part.width, place.width));
            line[column] = if (Film.white(from_x, from_y)) 0xFFFF_FFFF else 0xFF00_0000;
        }
    }
}

/// What VIDEO compares: the cases that came out the same, and all.
const VideoTally = struct { same: u32 = 0, compared: u32 = 0 };

fn videoCompare(dl: *DosBase, what: [*:0]const u8, drawn: ?[3]u32, laid: ?[3]u32, tally: *VideoTally) void {
    const same = drawn != null and laid != null and sameSum(drawn.?, laid.?);
    tally.compared += 1;
    if (same) tally.same += 1;
    _ = Printf(dl, "%s: drawn %04x %04x %04x, the board's %04x %04x %04x%s\n", .{
        what,
        if (drawn) |sum| sum[0] else 0,
        if (drawn) |sum| sum[1] else 0,
        if (drawn) |sum| sum[2] else 0,
        if (laid) |sum| sum[0] else 0,
        if (laid) |sum| sum[1] else 0,
        if (laid) |sum| sum[2] else 0,
        @as([*:0]const u8, if (same) ", the same" else ", DIFFERENT"),
    });
}

/// The pipes the blender's tree for output 0 is made of, from the top
/// down, and which of the four fetchers fetch.
fn sayTree(dl: *DosBase, engine: Display, blender: Display) void {
    var stages: [4]u32 = @splat(0xf);
    var stage = blender.at(mpc_out_mux).* & 0xf;
    var count: usize = 0;
    while (stage < 4 and count < 4) : (count += 1) {
        stages[count] = stage;
        stage = blender.at(stage * mpcc_stride + mpcc_bottom_select).* & 0xf;
    }
    var fetching: [4]u32 = undefined;
    for (0..4) |index| fetching[index] = @intFromBool(engine.at(dchubp_control + @as(u32, @intCast(index)) * dcn.HUBP_STRIDE).* & 1 == 0);
    _ = Printf(dl, "        blender: output 0 from stage %u, then %u, %u, %u (15: none); fetchers fetching: %u %u %u %u\n", .{
        stages[0], stages[1], stages[2], stages[3], fetching[0], fetching[1], fetching[2], fetching[3],
    });
}

/// VIDEO: a film's frame on the board's video layer, under the picture
/// and over it, against the same pictures drawn by the program.
fn videoCheck(sys: *ExecBase, dl: *DosBase, ab: *AMDGPUBase, info: amdgpu.GPUInfo, millis: u32) i32 {
    var block: amdgpu.GPUBlock = .{};
    if (!ab.FindGPUBlock(amdgpu.GPUBLOCK_DISPLAY, 0, &block) or block.count < 4) {
        _ = Printf(dl, "The device %04x:%04x names no display engine with a blender\n", .{ info.vendor, info.device });
        return dos.RETURN_FAIL;
    }
    const engine = Display{ .registers = @intCast(info.registers), .segment = block.addresses[2], .pipe = 0, .fetcher = 0 };
    const blender = Display{ .registers = @intCast(info.registers), .segment = block.addresses[3], .pipe = 0, .fetcher = 0 };
    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);
    const board = amdBoard(dl, rb) orelse return dos.RETURN_WARN;
    var board_info: rtg.RtgBoardInfo = .{};
    _ = rb.GetBoardInfo(board, &board_info, @sizeOf(rtg.RtgBoardInfo));
    if (board_info.caps & rtg.boards.RTGBC_VIDEO == 0) {
        _ = Printf(dl, "The board has no video layer\n", .{});
        return dos.RETURN_WARN;
    }
    const pointer = board.pointer orelse {
        _ = Printf(dl, "The board has no pointer image\n", .{});
        return dos.RETURN_WARN;
    };
    var film = Film.make(sys) orelse {
        _ = Printf(dl, "No room for the film's frame\n", .{});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(film.memory);
    const was_x = board.pointer_x;
    const was_y = board.pointer_y;
    const was_shown = board.info.flags & rtg.boards.RTGBF_POINTER != 0;
    const wb = arm(sys, dl, millis) orelse return dos.RETURN_FAIL;
    defer wb.DisarmWatchdog();
    const still = Still.begin(dl, rb, board) orelse return dos.RETURN_FAIL;
    const picture = still.picture;
    const flat = rb.AllocBitMap(board, picture.width, picture.height, @intFromEnum(picture.format), rtg.bitmaps.RTGBMF_DISPLAYABLE);
    const reference = rb.AllocBitMap(board, picture.width, picture.height, @intFromEnum(picture.format), rtg.bitmaps.RTGBMF_DISPLAYABLE);
    if (flat == null or reference == null or picture.format != .bgra32) {
        still.end();
        if (flat) |one| rb.FreeBitMap(one);
        if (reference) |one| rb.FreeBitMap(one);
        _ = Printf(dl, "No room for two more pictures in bgra32\n", .{});
        return dos.RETURN_FAIL;
    }
    _ = rb.ShowBoardPointer(board, false);
    var tally: VideoTally = .{};
    const run: VideoRun = .{ .sys = sys, .dl = dl, .rb = rb, .board = board, .wb = wb, .mode_id = still.mode_id, .picture = picture, .flat = flat.?, .reference = reference.?, .film = &film, .pointer = pointer, .engine = engine, .blender = blender };
    run.under(&tally);
    run.over(&tally);
    _ = rb.MirrorBoard(board, board_info.mirror_x != 0, board_info.mirror_y != 0);
    rb.MoveBoardPointer(board, was_x, was_y);
    _ = rb.ShowBoardPointer(board, was_shown);
    wb.FeedWatchdog();
    still.end();
    rb.FreeBitMap(flat.?);
    rb.FreeBitMap(reference.?);
    _ = Printf(dl, "%u of %u the same\n", .{ tally.same, tally.compared });
    return if (tally.compared != 0 and tally.same == tally.compared) dos.RETURN_OK else dos.RETURN_WARN;
}

/// What VIDEO's steps share.
const VideoRun = struct {
    sys: *ExecBase,
    dl: *DosBase,
    rb: *RtgBase,
    board: *rtg.RtgBoard,
    wb: *WatchdogBase,
    mode_id: u32,
    /// The picture the board lays the film on, the program's drawing of
    /// what that shows before it is mirrored, and that drawing mirrored.
    picture: *rtg.RtgBitMap,
    flat: *rtg.RtgBitMap,
    reference: *rtg.RtgBitMap,
    film: *Film,
    pointer: *const rtg.RtgPointerImage,
    engine: Display,
    blender: Display,

    const whole = rtg.RtgRect{ .width = Film.width, .height = Film.height };

    fn open(run: VideoRun, below: bool) ?*rtg.RtgVideoLayer {
        const asked = [_]TagItem{ .{ .tag = rtg.RTGVA_Under, .data = @intFromBool(below) }, .{} };
        const layer = run.rb.OpenVideoLayer(run.board, &asked) orelse {
            _ = Printf(run.dl, "The board handed out no video layer %s the picture\n", .{@as([*:0]const u8, if (below) "under" else "over")});
            return null;
        };
        _ = Printf(run.dl, "A layer %s the picture: flags %u, key %06x, frames up to %ux%u, %u times larger to a %uth\n", .{
            @as([*:0]const u8, if (layer.flags & rtg.RTGVLF_UNDER != 0) "under" else "over"),
            layer.flags,
            layer.key,
            layer.max_width,
            layer.max_height,
            layer.max_up,
            layer.max_down,
        });
        return layer;
    }

    /// The picture shown with its background, and the key colour in
    /// `key` where there is one.
    fn showPicture(run: VideoRun, key: ?rtg.RtgRect) void {
        fillRect(run.picture, .{ .width = @intCast(run.picture.width), .height = @intCast(run.picture.height) }, video_background);
        if (key) |rect| fillRect(run.picture, rect, video_key);
        _ = run.rb.RefreshRect(run.picture, null);
        const band = [_]rtg.RtgBand{.{ .bitmap = run.picture }};
        _ = run.rb.ShowBoard(run.board, run.mode_id, &band, band.len);
    }

    /// The program's drawing - `flat`, drawn by the caller - shown
    /// mirrored as the board is to be, with nothing on the layer, and its
    /// checksum, or each of `windows`' into `into`.
    fn drawn(run: VideoRun, layer: *rtg.RtgVideoLayer, x: bool, y: bool, windows: []const rtg.tags.RtgAmdCrc, into: []?[3]u32) void {
        _ = run.rb.ShowVideoFrame(layer, null, null);
        turned(run.reference, run.flat, x, y);
        _ = run.rb.RefreshRect(run.reference, null);
        _ = run.rb.MirrorBoard(run.board, false, false);
        const band = [_]rtg.RtgBand{.{ .bitmap = run.reference }};
        _ = run.rb.ShowBoard(run.board, run.mode_id, &band, band.len);
        run.wb.FeedWatchdog();
        for (windows, into) |window, *sum| sum.* = steadyWindow(run.dl, run.rb, run.board, window);
        run.wb.FeedWatchdog();
    }

    /// The film's `part` shown at `place` on the picture - shown by the
    /// caller - mirrored as asked; false, said, where the board refused.
    fn laid(run: VideoRun, layer: *rtg.RtgVideoLayer, part: rtg.RtgRect, place: rtg.RtgRect, x: bool, y: bool) bool {
        _ = run.rb.MirrorBoard(run.board, x, y);
        const moved = run.rb.MoveVideoLayer(layer, &place);
        const shown = run.rb.ShowVideoFrame(layer, &run.film.picture, &part);
        run.wb.FeedWatchdog();
        if (moved != rtg.errors.RTGERR_OK or shown != rtg.errors.RTGERR_OK) {
            _ = Printf(run.dl, "        the board refused: move %ld, show %ld\n", .{ @as(i64, moved), @as(i64, shown) });
            return false;
        }
        return true;
    }

    /// The board's checksum, or each of `windows`'.
    fn sums(run: VideoRun, windows: []const rtg.tags.RtgAmdCrc, into: []?[3]u32) void {
        for (windows, into) |window, *sum| sum.* = steadyWindow(run.dl, run.rb, run.board, window);
        run.wb.FeedWatchdog();
    }

    /// Under the picture: the colours, the frame as it is in every place
    /// and turn, moved, keyed in part, with the pointer, scaled, and
    /// nothing shown.
    fn under(run: VideoRun, tally: *VideoTally) void {
        const layer = run.open(true) orelse return;
        run.colours(layer, tally);
        run.film.blocks();
        const width: i32 = @intCast(run.picture.width);
        const height: i32 = @intCast(run.picture.height);
        const Case = struct { part: rtg.RtgRect, place: rtg.RtgRect, name: [*:0]const u8 };
        const cases = [_]Case{
            .{ .part = whole, .place = .{ .x = 400, .y = 300, .width = Film.width, .height = Film.height }, .name = "whole" },
            .{ .part = whole, .place = .{ .x = -50, .y = -30, .width = Film.width, .height = Film.height }, .name = "off the top left" },
            .{ .part = whole, .place = .{ .x = width - 270, .y = height - 150, .width = Film.width, .height = Film.height }, .name = "off the bottom right" },
            .{ .part = .{ .x = 40, .y = 20, .width = 200, .height = 120 }, .place = .{ .x = 600, .y = 500, .width = 200, .height = 120 }, .name = "a part" },
        };
        const ways = [_][2]bool{ .{ false, false }, .{ true, false }, .{ false, true }, .{ true, true } };
        const names = [_][*:0]const u8{ "none", "x", "y", "x and y" };
        var said_tree = false;
        var buffer: [96]u8 = undefined;
        for (ways, names) |way, name| {
            for (cases) |case| {
                var drawn_sum: [1]?[3]u32 = .{null};
                fillRect(run.flat, .{ .width = width, .height = height }, video_background);
                drawFilm(run.flat, case.part, case.place);
                run.drawn(layer, way[0], way[1], &.{.{}}, &drawn_sum);
                run.showPicture(case.place);
                var laid_sum: [1]?[3]u32 = .{null};
                if (run.laid(layer, case.part, case.place, way[0], way[1])) run.sums(&.{.{}}, &laid_sum);
                if (!said_tree) {
                    said_tree = true;
                    sayTree(run.dl, run.engine, run.blender);
                }
                videoCompare(run.dl, label(&buffer, "under, mirrored ", name, ", ", case.name), drawn_sum[0], laid_sum[0], tally);
            }
        }
        const place: rtg.RtgRect = .{ .x = 600, .y = 300, .width = Film.width, .height = Film.height };

        // Moved while it is shown: lit at one place, then the key colour
        // and the layer moved to another.
        {
            var drawn_sum: [1]?[3]u32 = .{null};
            const moved_to: rtg.RtgRect = .{ .x = 900, .y = 200, .width = Film.width, .height = Film.height };
            fillRect(run.flat, .{ .width = width, .height = height }, video_background);
            drawFilm(run.flat, whole, moved_to);
            run.drawn(layer, false, false, &.{.{}}, &drawn_sum);
            run.showPicture(place);
            var laid_sum: [1]?[3]u32 = .{null};
            if (run.laid(layer, whole, place, false, false)) {
                run.showPicture(moved_to);
                const moved = run.rb.MoveVideoLayer(layer, &moved_to);
                if (moved == rtg.errors.RTGERR_OK) run.sums(&.{.{}}, &laid_sum);
            }
            videoCompare(run.dl, "under, moved while shown", drawn_sum[0], laid_sum[0], tally);
        }

        // The key colour over part of the place, its shades, and colours
        // next to it, which hide the film.
        {
            const left_half: rtg.RtgRect = .{ .x = place.x, .y = place.y, .width = place.width / 2, .height = place.height };
            var drawn_sum: [1]?[3]u32 = .{null};
            fillRect(run.flat, .{ .width = width, .height = height }, video_background);
            drawFilm(run.flat, whole, place);
            fillRect(run.flat, .{ .x = place.x + place.width / 2, .y = place.y, .width = place.width / 2, .height = place.height }, video_background);
            for (video_unkeyed, 0..) |colour, index| fillRect(run.flat, .{ .x = place.x + @as(i32, @intCast(index)) * 20, .y = place.y + 40, .width = 20, .height = 40 }, colour);
            run.drawn(layer, false, false, &.{.{}}, &drawn_sum);
            run.showPicture(left_half);
            for (video_unkeyed, 0..) |colour, index| fillRect(run.picture, .{ .x = place.x + @as(i32, @intCast(index)) * 20, .y = place.y + 40, .width = 20, .height = 40 }, colour);
            _ = run.rb.RefreshRect(run.picture, null);
            var laid_sum: [1]?[3]u32 = .{null};
            if (run.laid(layer, whole, place, false, false)) run.sums(&.{.{}}, &laid_sum);
            videoCompare(run.dl, "under, keyed over half the place, two colours next to the key", drawn_sum[0], laid_sum[0], tally);

            fillRect(run.flat, .{ .width = width, .height = height }, video_background);
            drawFilm(run.flat, whole, place);
            run.drawn(layer, false, false, &.{.{}}, &drawn_sum);
            run.showPicture(place);
            for (video_shades, 0..) |colour, index| fillRect(run.picture, .{ .x = place.x + 200 + @as(i32, @intCast(index)) * 40, .y = place.y, .width = 40, .height = place.height }, colour);
            _ = run.rb.RefreshRect(run.picture, null);
            if (run.laid(layer, whole, place, false, false)) run.sums(&.{.{}}, &laid_sum);
            videoCompare(run.dl, "under, the key's shades", drawn_sum[0], laid_sum[0], tally);
        }

        // The pointer over the film and across its edge.
        const pointer_places = [_][2]i32{ .{ place.x + 100, place.y + 50 }, .{ place.x - 5, place.y - 5 } };
        for (pointer_places) |at| {
            var drawn_sum: [1]?[3]u32 = .{null};
            fillRect(run.flat, .{ .width = width, .height = height }, video_background);
            drawFilm(run.flat, whole, place);
            drawPointer(run.flat, run.pointer, at[0] - @as(i32, @intCast(run.pointer.hot_x)), at[1] - @as(i32, @intCast(run.pointer.hot_y)), false, false);
            run.drawn(layer, false, false, &.{.{}}, &drawn_sum);
            run.showPicture(place);
            var laid_sum: [1]?[3]u32 = .{null};
            if (run.laid(layer, whole, place, false, false)) {
                run.rb.MoveBoardPointer(run.board, at[0], at[1]);
                _ = run.rb.ShowBoardPointer(run.board, true);
                run.sums(&.{.{}}, &laid_sum);
                _ = run.rb.ShowBoardPointer(run.board, false);
            }
            videoCompare(run.dl, if (at[0] > place.x) "under, the pointer over the film" else "under, the pointer across its edge", drawn_sum[0], laid_sum[0], tally);
        }

        // The monitor asleep, the board shown in another mode and back
        // meanwhile, and woken: the film laid again where it was.
        {
            var drawn_sum: [1]?[3]u32 = .{null};
            fillRect(run.flat, .{ .width = width, .height = height }, video_background);
            drawFilm(run.flat, whole, place);
            run.drawn(layer, false, false, &.{.{}}, &drawn_sum);
            run.showPicture(place);
            var laid_sum: [1]?[3]u32 = .{null};
            if (run.laid(layer, whole, place, false, false)) {
                const slept = run.rb.SetBoardPower(run.board, rtg.boards.RTGPWR_ASLEEP);
                run.wb.FeedWatchdog();
                hold(run.dl, run.wb, 2);
                const moved = anotherMode(run.dl, run.rb, run.board, run.wb);
                const woken = run.rb.SetBoardPower(run.board, rtg.boards.RTGPWR_ON);
                run.wb.FeedWatchdog();
                _ = Printf(run.dl, "        asleep: %s, awake: %s\n", .{ powerAnswer(run.rb, slept), powerAnswer(run.rb, woken) });
                if (moved and woken == @as(i32, @intCast(rtg.boards.RTGPWR_ON))) run.sums(&.{.{}}, &laid_sum);
            }
            videoCompare(run.dl, "under, after the monitor slept, shown in another mode and back meanwhile", drawn_sum[0], laid_sum[0], tally);
        }

        run.scaled(layer, tally);

        // Nothing shown, an empty place, a place off the glass: the
        // picture as it is, its key colour and all.
        run.showPicture(place);
        _ = run.laid(layer, whole, place, false, false);
        _ = run.rb.ShowVideoFrame(layer, null, null);
        var nothing: [1]?[3]u32 = .{null};
        run.sums(&.{.{}}, &nothing);
        _ = run.laid(layer, whole, place, false, false);
        const empty: rtg.RtgRect = .{ .x = place.x, .y = place.y };
        const emptied = run.rb.MoveVideoLayer(layer, &empty);
        var no_place: [1]?[3]u32 = .{null};
        run.sums(&.{.{}}, &no_place);
        const off: rtg.RtgRect = .{ .x = width + 10, .y = 0, .width = Film.width, .height = Film.height };
        const moved_off = run.rb.MoveVideoLayer(layer, &off);
        var off_glass: [1]?[3]u32 = .{null};
        run.sums(&.{.{}}, &off_glass);
        run.rb.CloseVideoLayer(layer);
        var closed: [1]?[3]u32 = .{null};
        run.sums(&.{.{}}, &closed);
        videoCompare(run.dl, "under, nothing shown, against no layer", closed[0], nothing[0], tally);
        if (emptied != rtg.errors.RTGERR_OK) _ = Printf(run.dl, "        an empty place: %ld\n", .{@as(i64, emptied)});
        videoCompare(run.dl, "under, an empty place, against no layer", closed[0], no_place[0], tally);
        if (moved_off != rtg.errors.RTGERR_OK) _ = Printf(run.dl, "        a place off the glass: %ld\n", .{@as(i64, moved_off)});
        videoCompare(run.dl, "under, a place off the glass, against no layer", closed[0], off_glass[0], tally);
    }

    /// The frame's colours as the board shows them, each read as a window
    /// of the glass inside the place: black and white as the blocks have
    /// them, and a red, a green and a blue each a little past the primary,
    /// so that the engine makes each channel exactly nothing or all of it,
    /// against the same colours drawn beside the place; then video's
    /// black, said as the greys it matches, channel by channel.
    fn colours(run: VideoRun, layer: *rtg.RtgVideoLayer, tally: *VideoTally) void {
        const place: rtg.RtgRect = .{ .x = 1000, .y = 600, .width = Film.width, .height = Film.height };
        const Colour = struct { y: u8, cb: u8, cr: u8, drawn: u32, name: [*:0]const u8 };
        const exact = [_]Colour{
            .{ .y = 15, .cb = 128, .cr = 128, .drawn = 0xFF00_0000, .name = "under, the frame's black" },
            .{ .y = 235, .cb = 128, .cr = 128, .drawn = 0xFFFF_FFFF, .name = "under, the frame's white" },
            .{ .y = 63, .cb = 100, .cr = 245, .drawn = 0xFFFF_0000, .name = "under, the frame's red" },
            .{ .y = 173, .cb = 38, .cr = 22, .drawn = 0xFF00_FF00, .name = "under, the frame's green" },
            .{ .y = 28, .cb = 248, .cr = 114, .drawn = 0xFF00_00FF, .name = "under, the frame's blue" },
        };
        const greys = [_]u32{ 0, 1, 2, 3 };
        run.showPicture(place);
        for (exact, 0..) |colour, index| fillRect(run.picture, .{ .x = 100 + @as(i32, @intCast(index)) * 64, .y = 100, .width = 48, .height = 48 }, colour.drawn);
        for (greys, 0..) |grey, index| fillRect(run.picture, .{ .x = 100 + @as(i32, @intCast(exact.len + index)) * 64, .y = 100, .width = 48, .height = 48 }, 0xFF00_0000 | grey * 0x01_0101);
        _ = run.rb.RefreshRect(run.picture, null);
        run.wb.FeedWatchdog();
        var drawn_sums: [exact.len + greys.len]?[3]u32 = undefined;
        for (&drawn_sums, 0..) |*sum, index| {
            sum.* = steadyWindow(run.dl, run.rb, run.board, .{ .x = 108 + @as(u32, @intCast(index)) * 64, .y = 108, .width = 32, .height = 32 });
        }
        run.wb.FeedWatchdog();
        const inside: rtg.tags.RtgAmdCrc = .{ .x = 1100, .y = 650, .width = 32, .height = 32 };
        for (exact, drawn_sums[0..exact.len]) |colour, drawn_sum| {
            run.film.fill(colour.y, colour.cb, colour.cr);
            var laid_sum: [1]?[3]u32 = .{null};
            if (run.laid(layer, whole, place, false, false)) run.sums(&.{inside}, &laid_sum);
            videoCompare(run.dl, colour.name, drawn_sum, laid_sum[0], tally);
        }
        run.film.fill(16, 128, 128);
        if (run.laid(layer, whole, place, false, false)) {
            const sum = steadyWindow(run.dl, run.rb, run.board, inside) orelse return;
            var found: [3]i32 = .{ -1, -1, -1 };
            for (0..3) |channel| {
                for (greys, drawn_sums[exact.len..]) |grey, maybe| {
                    const one = maybe orelse continue;
                    if (one[channel] == sum[channel]) found[channel] = @intCast(grey);
                }
            }
            _ = Printf(run.dl, "Video's black, Y 16, shown as red %ld, green %ld, blue %ld (-1: none of 0 to 3)\n", .{ @as(i64, found[0]), @as(i64, found[1]), @as(i64, found[2]) });
        }
        run.wb.FeedWatchdog();
    }

    /// Made larger, smaller and by a ratio that is no whole number: windows
    /// inside blocks, a block's edges left out where the scaler's taps mix
    /// the pixels on either side, against the blocks drawn that size.
    fn scaled(run: VideoRun, layer: *rtg.RtgVideoLayer, tally: *VideoTally) void {
        const width: i32 = @intCast(run.picture.width);
        const height: i32 = @intCast(run.picture.height);
        const Case = struct { place: rtg.RtgRect, name: [*:0]const u8 };
        const cases = [_]Case{
            .{ .place = .{ .x = 800, .y = 400, .width = 2 * Film.width, .height = 2 * Film.height }, .name = "twice the size" },
            .{ .place = .{ .x = 800, .y = 400, .width = Film.width / 2, .height = Film.height / 2 }, .name = "half the size" },
            .{ .place = .{ .x = 800, .y = 400, .width = 500, .height = 300 }, .name = "500 by 300" },
        };
        const blocks = [_][2]u32{ .{ 0, 0 }, .{ 1, 0 }, .{ 3, 1 }, .{ 5, 2 }, .{ 7, 4 }, .{ 2, 3 } };
        var buffer: [96]u8 = undefined;
        for (cases) |case| {
            var windows: [blocks.len]rtg.tags.RtgAmdCrc = undefined;
            for (blocks, &windows) |at, *window| window.* = blockWindow(case.place, at[0], at[1]);
            var drawn_sums: [blocks.len]?[3]u32 = undefined;
            fillRect(run.flat, .{ .width = width, .height = height }, video_background);
            drawFilm(run.flat, whole, case.place);
            run.drawn(layer, false, false, &windows, &drawn_sums);
            run.showPicture(case.place);
            var laid_sums: [blocks.len]?[3]u32 = @splat(null);
            if (run.laid(layer, whole, case.place, false, false)) run.sums(&windows, &laid_sums);
            for (blocks, drawn_sums, laid_sums) |at, drawn_sum, laid_sum| {
                var number_buffer: [32]u8 = undefined;
                const where = blockName(&number_buffer, at[0], at[1]);
                videoCompare(run.dl, label(&buffer, "under, ", case.name, ", inside ", where), drawn_sum, laid_sum, tally);
            }
            clocksLine(run.dl, run.rb, run.board);
        }
    }

    /// Over the picture: the frame as it is, unmirrored and mirrored both
    /// ways, and the pointer over it.
    fn over(run: VideoRun, tally: *VideoTally) void {
        const layer = run.open(false) orelse return;
        defer run.rb.CloseVideoLayer(layer);
        run.film.blocks();
        const width: i32 = @intCast(run.picture.width);
        const height: i32 = @intCast(run.picture.height);
        const place: rtg.RtgRect = .{ .x = 600, .y = 300, .width = Film.width, .height = Film.height };
        const ways = [_][2]bool{ .{ false, false }, .{ true, true } };
        const names = [_][*:0]const u8{ "over, mirrored none", "over, mirrored x and y" };
        var said_tree = false;
        for (ways, names) |way, name| {
            var drawn_sum: [1]?[3]u32 = .{null};
            fillRect(run.flat, .{ .width = width, .height = height }, video_background);
            drawFilm(run.flat, whole, place);
            run.drawn(layer, way[0], way[1], &.{.{}}, &drawn_sum);
            run.showPicture(null);
            var laid_sum: [1]?[3]u32 = .{null};
            if (run.laid(layer, whole, place, way[0], way[1])) run.sums(&.{.{}}, &laid_sum);
            if (!said_tree) {
                said_tree = true;
                sayTree(run.dl, run.engine, run.blender);
            }
            videoCompare(run.dl, name, drawn_sum[0], laid_sum[0], tally);
        }
        // The pointer over it is laid by the picture's pipe, under the
        // film: the same as the film alone.
        var drawn_sum: [1]?[3]u32 = .{null};
        fillRect(run.flat, .{ .width = width, .height = height }, video_background);
        drawFilm(run.flat, whole, place);
        run.drawn(layer, false, false, &.{.{}}, &drawn_sum);
        run.showPicture(null);
        var laid_sum: [1]?[3]u32 = .{null};
        if (run.laid(layer, whole, place, false, false)) {
            run.rb.MoveBoardPointer(run.board, place.x + 100, place.y + 50);
            _ = run.rb.ShowBoardPointer(run.board, true);
            run.sums(&.{.{}}, &laid_sum);
            _ = run.rb.ShowBoardPointer(run.board, false);
        }
        videoCompare(run.dl, "over, the pointer over the film, against the film alone", drawn_sum[0], laid_sum[0], tally);
    }
};

/// The window inside block (`column`, `row`) of the frame shown at
/// `place`: the block's part of the place, less 8 pixels at each edge
/// where the scaler's taps reach the next block's pixels, its left on
/// four pixels and its width a whole number of four.
fn blockWindow(place: rtg.RtgRect, column: u32, row: u32) rtg.tags.RtgAmdCrc {
    const margin = 8;
    const across_from = @divFloor(@as(i64, column) * Film.block_width * place.width + Film.width - 1, Film.width) + place.x + margin;
    const across_to = @divFloor(@as(i64, column + 1) * Film.block_width * place.width, Film.width) + place.x - margin;
    const down_from = @divFloor(@as(i64, row) * Film.block_height * place.height + Film.height - 1, Film.height) + place.y + margin;
    const down_to = @divFloor(@as(i64, row + 1) * Film.block_height * place.height, Film.height) + place.y - margin;
    const left: i64 = @divFloor(across_from + 3, 4) * 4;
    const span: i64 = @max(4, @divFloor(across_to - left, 4) * 4);
    return .{
        .x = @intCast(left),
        .y = @intCast(down_from),
        .width = @intCast(span),
        .height = @intCast(@max(1, down_to - down_from)),
    };
}

/// "block c,r" in `buffer`.
fn blockName(buffer: []u8, column: u32, row: u32) [*:0]const u8 {
    const text = "block ";
    @memcpy(buffer[0..text.len], text);
    var at: usize = text.len;
    at += decimal(buffer[at..], column);
    buffer[at] = ',';
    at += 1;
    at += decimal(buffer[at..], row);
    buffer[at] = 0;
    return @ptrCast(buffer.ptr);
}

fn decimal(into: []u8, value: u32) usize {
    var digits: [10]u8 = undefined;
    var count: usize = 0;
    var left = value;
    while (true) {
        digits[count] = @intCast('0' + left % 10);
        count += 1;
        left /= 10;
        if (left == 0) break;
    }
    for (0..count) |index| into[index] = digits[count - 1 - index];
    return count;
}

/// The four parts joined in `buffer`, cut to fit it.
fn label(buffer: []u8, first: [*:0]const u8, second: [*:0]const u8, third: [*:0]const u8, fourth: [*:0]const u8) [*:0]const u8 {
    var at: usize = 0;
    for ([_][*:0]const u8{ first, second, third, fourth }) |part| {
        var index: usize = 0;
        while (part[index] != 0 and at + 1 < buffer.len) : (index += 1) {
            buffer[at] = part[index];
            at += 1;
        }
    }
    buffer[at] = 0;
    return @ptrCast(buffer.ptr);
}

/// Which pipe the blender lays over output 0's picture at the top of
/// its tree, and below it, and whether each of the first two fetchers is
/// blanked: the overlay as a plane, where the top is not the picture's.
fn sayPlane(dl: *DosBase, engine: Display, blender: Display) void {
    const top = blender.at(mpc_out_mux).* & 0xf;
    const below = if (top < 4) blender.at(top * mpcc_stride + mpcc_bottom_select).* & 0xf else 0xf;
    const blanked_0 = engine.at(dchubp_control).* & 1 != 0;
    const blanked_1 = engine.at(dchubp_control + dcn.HUBP_STRIDE).* & 1 != 0;
    _ = Printf(dl, "        blender: output 0 from stage %u, below it %u; fetcher 0 %s, fetcher 1 %s\n", .{
        top,
        below,
        @as([*:0]const u8, if (blanked_0) "blanked" else "fetching"),
        @as([*:0]const u8, if (blanked_1) "blanked" else "fetching"),
    });
}

/// The registers sayPlane reads: a fetcher's control, its lowest bit
/// blanking it; and the blender's output 0's top stage, and a stage's
/// below, a stage's stride apart.
const dchubp_control = 0x05f3;
const mpc_out_mux = 0x0580;
const mpcc_bottom_select = 0x0001;
const mpcc_stride = 0x20;

/// A grey block in the picture's top left quarter, so that it differs
/// mirrored about either axis.
fn marker(picture: *rtg.RtgBitMap) void {
    const pixels = picture.pixels orelse return;
    const rows = @min(picture.height / 4, 100);
    const columns = @min(picture.width / 4, 200);
    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        const line: [*]u32 = @ptrCast(@alignCast(pixels + @as(usize, row + 40) * picture.pitch));
        var column: u32 = 0;
        while (column < columns) : (column += 1) line[column + 60] = 0xFF808080;
    }
}

/// `from` copied into `into`, of the same size, mirrored about each axis.
fn turned(into: *rtg.RtgBitMap, from: *const rtg.RtgBitMap, x: bool, y: bool) void {
    const source = from.pixels orelse return;
    const target = into.pixels orelse return;
    const width = from.width;
    const height = from.height;
    var row: u32 = 0;
    while (row < height) : (row += 1) {
        const line: [*]const u32 = @ptrCast(@alignCast(source + @as(usize, row) * from.pitch));
        const to_row = if (y) height - 1 - row else row;
        const to: [*]u32 = @ptrCast(@alignCast(target + @as(usize, to_row) * into.pitch));
        var column: u32 = 0;
        while (column < width) : (column += 1) to[if (x) width - 1 - column else column] = line[column];
    }
}

/// The pointer's image drawn into `into` with its top left at (`left`,
/// `top`) of the picture before it is mirrored about each axis - each of
/// its pixels that covers, where the mirrored picture has it.
fn drawPointer(into: *rtg.RtgBitMap, image: *const rtg.RtgPointerImage, left: i32, top: i32, x: bool, y: bool) void {
    const target = into.pixels orelse return;
    const width: i64 = into.width;
    const height: i64 = into.height;
    var row: u32 = 0;
    while (row < image.height) : (row += 1) {
        const at_y = @as(i64, top) + row;
        if (at_y < 0 or at_y >= height) continue;
        const line: [*]align(1) const u32 = @ptrCast(image.pixels + @as(usize, row) * image.pitch);
        var column: u32 = 0;
        while (column < image.width) : (column += 1) {
            const at_x = @as(i64, left) + column;
            if (at_x < 0 or at_x >= width) continue;
            const pixel = line[column];
            if (pixel >> 24 == 0) continue;
            const glass_x: usize = @intCast(if (x) width - 1 - at_x else at_x);
            const glass_y: usize = @intCast(if (y) height - 1 - at_y else at_y);
            const to: [*]u32 = @ptrCast(@alignCast(target + glass_y * into.pitch));
            to[glass_x] = pixel;
        }
    }
}

/// Where the board's engine's page table maps a program's buffers: the
/// top 512 MiB of the device's 48-bit addresses.
const direct_window: u64 = 0xFFFF_E000_0000;

/// DIRECT: two pictures shown in turn in the board's mode and in another
/// of another row length, read by the display in place of a frame, each
/// against the same picture made in a frame.
fn directCheck(sys: *ExecBase, dl: *DosBase, ab: *AMDGPUBase, info: amdgpu.GPUInfo, millis: u32) i32 {
    var block: amdgpu.GPUBlock = .{};
    if (!ab.FindGPUBlock(amdgpu.GPUBLOCK_DISPLAY, 0, &block) or block.count < 3) {
        _ = Printf(dl, "The device %04x:%04x names no display engine\n", .{ info.vendor, info.device });
        return dos.RETURN_FAIL;
    }
    const engine = Display{ .registers = @intCast(info.registers), .segment = block.addresses[2], .pipe = 0, .fetcher = 0 };
    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);
    const board = amdBoard(dl, rb) orelse return dos.RETURN_WARN;
    var board_info: rtg.RtgBoardInfo = .{};
    _ = rb.GetBoardInfo(board, &board_info, @sizeOf(rtg.RtgBoardInfo));
    if (board_info.flags & rtg.boards.RTGBF_DIRECT_FLIP == 0) {
        _ = Printf(dl, "The board reads no buffer in place of a frame\n", .{});
        return dos.RETURN_WARN;
    }
    var list: [modes_most]rtg.RtgMode = undefined;
    const count = @min(rb.GetBoardModes(board, &list, modes_most), modes_most);
    var current: ?*const rtg.RtgMode = null;
    for (list[0..count]) |*one| {
        if (one.flags & rtg.modes.RTGMF_CURRENT != 0) current = one;
    }
    const shown = current orelse {
        _ = Printf(dl, "The board is in no mode\n", .{});
        return dos.RETURN_FAIL;
    };
    // Another mode whose rows are of another length: 1920x1080 where
    // there is one.
    var second: ?*const rtg.RtgMode = null;
    for (list[0..count]) |*one| {
        if (one.pitch == shown.pitch or one.format != shown.format) continue;
        if (second == null or (one.width == 1920 and one.height == 1080)) second = one;
    }
    const before = rb.BoardDisplayBitMap(board) orelse {
        _ = Printf(dl, "The board shows no picture\n", .{});
        return dos.RETURN_FAIL;
    };
    const wb = arm(sys, dl, millis) orelse return dos.RETURN_FAIL;
    defer wb.DisarmWatchdog();
    // The picture shown said to be written in, so that the first of the
    // program's own is made in a frame whatever showed it before.
    _ = rb.RefreshRect(before, null);
    var made: [4]?*rtg.RtgBitMap = @splat(null);
    var tally = Tally{};
    directIn(sys, dl, rb, board, engine, wb, shown, made[0..2], &tally);
    if (second) |other| directIn(sys, dl, rb, board, engine, wb, other, made[2..4], &tally);
    const band = [_]rtg.RtgBand{.{ .bitmap = before }};
    if (rb.ShowBoard(board, shown.id, &band, band.len) == rtg.errors.RTGERR_OK) {
        for (made) |maybe| {
            if (maybe) |one| rb.FreeBitMap(one);
        }
    }
    _ = Printf(dl, "%u of %u the same as made in a frame, %u of %u read in place of a frame as they should be\n", .{ tally.same, tally.compared, tally.direct_right, tally.shows });
    return if (tally.same == tally.compared and tally.direct_right == tally.shows) dos.RETURN_OK else dos.RETURN_WARN;
}

const Tally = struct { same: u32 = 0, compared: u32 = 0, direct_right: u32 = 0, shows: u32 = 0 };

/// DIRECT's pictures in the mode `shown`, the two allocated kept in
/// `made` to be freed once the board shows another.
fn directIn(sys: *ExecBase, dl: *DosBase, rb: *RtgBase, board: *rtg.RtgBoard, engine: Display, wb: *WatchdogBase, shown: *const rtg.RtgMode, made: *[2]?*rtg.RtgBitMap, tally: *Tally) void {
    const displayable = rtg.bitmaps.RTGBMF_DISPLAYABLE;
    const one = rb.AllocBitMap(board, shown.width, shown.height, @intFromEnum(shown.format), displayable) orelse {
        _ = Printf(dl, "No room for a picture of %ux%u\n", .{ shown.width, shown.height });
        return;
    };
    made[0] = one;
    const other = rb.AllocBitMap(board, shown.width, shown.height, @intFromEnum(shown.format), displayable) orelse {
        _ = Printf(dl, "No room for a picture of %ux%u\n", .{ shown.width, shown.height });
        return;
    };
    made[1] = other;
    _ = Printf(dl, "%ux%u, rows %u bytes:\n", .{ shown.width, shown.height, shown.pitch });
    pattern(one, 0);
    pattern(other, 1);
    const first = directShow(sys, dl, rb, board, engine, shown.id, one, false, "first, in a frame", tally) orelse return;
    wb.FeedWatchdog();
    const other_direct = directShow(sys, dl, rb, board, engine, shown.id, other, true, "second, read as it is", tally) orelse return;
    wb.FeedWatchdog();
    const again = directShow(sys, dl, rb, board, engine, shown.id, one, true, "first, read as it is", tally) orelse return;
    compare(dl, first, again, tally);
    wb.FeedWatchdog();
    // Written in while it is shown: the pictures are made in frames again.
    _ = rb.RefreshRect(one, null);
    const written = directSum(sys, dl, rb, board, engine, false, 0, "first, written in", tally) orelse return;
    compare(dl, first, written, tally);
    wb.FeedWatchdog();
    const other_frame = directShow(sys, dl, rb, board, engine, shown.id, other, false, "second, in a frame", tally) orelse return;
    compare(dl, other_direct, other_frame, tally);
    wb.FeedWatchdog();
    // Drawn anew and shown at once: read as the CPU's caches hold it.
    pattern(one, 2);
    const fresh = directShow(sys, dl, rb, board, engine, shown.id, one, true, "third, drawn and read", tally) orelse return;
    wb.FeedWatchdog();
    _ = rb.RefreshRect(one, null);
    const fresh_frame = directSum(sys, dl, rb, board, engine, false, 0, "third, written in", tally) orelse return;
    compare(dl, fresh, fresh_frame, tally);
    wb.FeedWatchdog();
}

/// `picture` shown in the mode `mode_id` and its checksum read once
/// steady; said with where the fetcher reads, against `direct` - whether
/// it is to read the buffer itself.
fn directShow(sys: *ExecBase, dl: *DosBase, rb: *RtgBase, board: *rtg.RtgBoard, engine: Display, mode_id: u32, picture: *rtg.RtgBitMap, direct: bool, what: [*:0]const u8, tally: *Tally) ?[3]u32 {
    const band = [_]rtg.RtgBand{.{ .bitmap = picture }};
    const started = sys.UptimeUs();
    if (rb.ShowBoard(board, mode_id, &band, band.len) != rtg.errors.RTGERR_OK) {
        _ = Printf(dl, "  %-24s not shown\n", .{what});
        return null;
    }
    return directSum(sys, dl, rb, board, engine, direct, sys.UptimeUs() - started, what, tally);
}

fn directSum(sys: *ExecBase, dl: *DosBase, rb: *RtgBase, board: *rtg.RtgBoard, engine: Display, direct: bool, took_us: u64, what: [*:0]const u8, tally: *Tally) ?[3]u32 {
    _ = sys;
    const sum = steadyChecksum(dl, rb, board) orelse {
        _ = Printf(dl, "  %-24s no steady checksum\n", .{what});
        return null;
    };
    const address = @as(u64, engine.at(0x060b).* & 0xffff) << 32 | engine.at(0x060a).*;
    const read_direct = address >= direct_window;
    tally.shows += 1;
    if (read_direct == direct) tally.direct_right += 1;
    _ = Printf(dl, "  %-24s %04x %04x %04x, the fetcher at %lx: %s%s", .{
        what,                                                                            sum[0],
        sum[1],                                                                          sum[2],
        address,                                                                         @as([*:0]const u8, if (read_direct) "the buffer" else "a frame"),
        @as([*:0]const u8, if (read_direct == direct) "" else " - NOT AS IT SHOULD BE"),
    });
    if (took_us != 0) _ = Printf(dl, ", shown in %lu us", .{took_us});
    _ = Printf(dl, "\n", .{});
    return sum;
}

fn compare(dl: *DosBase, made: [3]u32, read: [3]u32, tally: *Tally) void {
    tally.compared += 1;
    if (sameSum(made, read)) {
        tally.same += 1;
        return;
    }
    _ = Printf(dl, "  DIFFERENT from %04x %04x %04x\n", .{ made[0], made[1], made[2] });
}

/// BANDS: each case in each way of mirroring, read by the display and
/// made in a frame.
fn bandsCheck(sys: *ExecBase, dl: *DosBase, ab: *AMDGPUBase, info: amdgpu.GPUInfo, millis: u32) i32 {
    var block: amdgpu.GPUBlock = .{};
    if (!ab.FindGPUBlock(amdgpu.GPUBLOCK_DISPLAY, 0, &block) or block.count < 3) {
        _ = Printf(dl, "The device %04x:%04x names no display engine\n", .{ info.vendor, info.device });
        return dos.RETURN_FAIL;
    }
    const engine = Display{ .registers = @intCast(info.registers), .segment = block.addresses[2], .pipe = 0, .fetcher = 0 };
    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);
    const board = amdBoard(dl, rb) orelse return dos.RETURN_WARN;
    var board_info: rtg.RtgBoardInfo = .{};
    _ = rb.GetBoardInfo(board, &board_info, @sizeOf(rtg.RtgBoardInfo));
    if (board_info.flags & rtg.boards.RTGBF_DIRECT_FLIP == 0) {
        _ = Printf(dl, "The board reads no buffer in place of a frame\n", .{});
        return dos.RETURN_WARN;
    }
    var list: [modes_most]rtg.RtgMode = undefined;
    const count = @min(rb.GetBoardModes(board, &list, modes_most), modes_most);
    var current: ?*const rtg.RtgMode = null;
    for (list[0..count]) |*one| {
        if (one.flags & rtg.modes.RTGMF_CURRENT != 0) current = one;
    }
    const shown = current orelse {
        _ = Printf(dl, "The board is in no mode\n", .{});
        return dos.RETURN_FAIL;
    };
    const before = rb.BoardDisplayBitMap(board) orelse {
        _ = Printf(dl, "The board shows no picture\n", .{});
        return dos.RETURN_FAIL;
    };
    const width = shown.width;
    const height = shown.height;
    const format = @intFromEnum(shown.format);
    const displayable = rtg.bitmaps.RTGBMF_DISPLAYABLE;
    // The overlay's image, in the heap - the program's stack is too small
    // for it: shades, clear squares in it.
    const overlay_width = 120;
    const overlay_height = 80;
    const overlay_memory = sys.AllocVec(overlay_width * overlay_height * 4, exec.MEMF_CLEAR) orelse {
        _ = Printf(dl, "No room for the overlay's image\n", .{});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(overlay_memory);
    const overlay_pixels: [*]u32 = @ptrCast(@alignCast(overlay_memory));
    for (0..overlay_height) |row| {
        for (0..overlay_width) |column| {
            const clear = (row / 10 + column / 10) % 3 == 0;
            overlay_pixels[row * overlay_width + column] = if (clear) 0 else 0xFF00_0000 | @as(u32, @intCast(column * 2)) << 16 | @as(u32, @intCast(row * 3)) << 8 | 0x40;
        }
    }
    const overlay_surface = rtg.Surface{ .pixels = @ptrCast(overlay_memory), .width = overlay_width, .height = overlay_height, .pitch = overlay_width * 4, .size_bytes = overlay_width * overlay_height * 4, .format = .bgra32 };
    var made: [5]?*rtg.RtgBitMap = @splat(null);
    const sizes = [_][2]u32{ .{ width, height }, .{ width, height }, .{ width / 2, height / 2 }, .{ width / 4, height / 4 }, .{ width, height / 4 } };
    for (sizes, 0..) |size, i| {
        made[i] = rb.AllocBitMap(board, size[0], size[1], format, displayable) orelse {
            _ = Printf(dl, "No room for a picture of %ux%u\n", .{ size[0], size[1] });
            for (made) |maybe| if (maybe) |one| rb.FreeBitMap(one);
            return dos.RETURN_FAIL;
        };
        pattern(made[i].?, @intCast(i % 3));
    }
    const back = made[0].?;
    const front = made[1].?;
    const halved = made[2].?;
    const quarter = made[3].?;
    const short = made[4].?;
    const cases = [_]struct { name: [*:0]const u8, bands: [3]rtg.RtgBand, count: u32 }{
        .{ .name = "pulled down", .count = 2, .bands = .{ .{ .bitmap = back }, .{ .bitmap = front, .line = height / 3, .origin = height / 3 }, undefined } },
        .{ .name = "part way down", .count = 2, .bands = .{ .{ .bitmap = back }, .{ .bitmap = front, .line = height / 4, .origin = height / 8 }, undefined } },
        .{ .name = "three, one 2x", .count = 3, .bands = .{ .{ .bitmap = back }, .{ .bitmap = front, .line = height / 4, .origin = height / 4 }, .{ .bitmap = halved, .line = height * 5 / 8, .origin = height * 5 / 8 - 1 } } },
        .{ .name = "4x, into a row", .count = 2, .bands = .{ .{ .bitmap = front }, .{ .bitmap = quarter, .line = height / 2 + 1, .origin = height / 2 - 2 }, undefined } },
        .{ .name = "black below", .count = 2, .bands = .{ .{ .bitmap = back }, .{ .bitmap = short, .line = height / 2, .origin = height / 2 - 37 }, undefined } },
    };
    const ways = [_][2]bool{ .{ false, false }, .{ true, false }, .{ false, true }, .{ true, true } };
    const names = [_][*:0]const u8{ "none", "x", "y", "x and y" };
    const was_shown = board.info.flags & rtg.boards.RTGBF_POINTER != 0;
    const wb = arm(sys, dl, millis) orelse return dos.RETURN_FAIL;
    defer wb.DisarmWatchdog();
    _ = rb.ShowBoardPointer(board, false);
    var tally = Tally{};
    const was_x = board.pointer_x;
    const was_y = board.pointer_y;
    const edge: i32 = @intCast(height / 3);
    const places = [_][2]i32{ .{ 300, edge - 200 }, .{ 900, edge + 200 }, .{ 1500, edge - 8 } };
    const place_names = [_][*:0]const u8{ "pointer above", "pointer below", "pointer across" };
    for (ways, names) |way, name| {
        _ = rb.MirrorBoard(board, way[0], way[1]);
        for (cases) |one| bandsOnce(sys, dl, rb, board, engine, wb, shown.id, one.bands[0..one.count], 0, name, one.name, &tally);
        if (board.pointer != null) {
            for (places, place_names) |place, place_name| {
                rb.MoveBoardPointer(board, place[0], place[1]);
                _ = rb.ShowBoardPointer(board, true);
                bandsOnce(sys, dl, rb, board, engine, wb, shown.id, cases[0].bands[0..cases[0].count], 0, name, place_name, &tally);
            }
            _ = rb.ShowBoardPointer(board, false);
        }
        // An overlay across the edge, a plane above the bands' planes.
        if (rb.SetBoardOverlay(board, &overlay_surface, 0, 0) == rtg.errors.RTGERR_OK) {
            rb.MoveBoardOverlay(board, 1000, edge - 40);
            bandsOnce(sys, dl, rb, board, engine, wb, shown.id, cases[0].bands[0..cases[0].count], 1, name, "overlay over 2", &tally);
            rb.MoveBoardOverlay(board, 1000, @as(i32, @intCast(height / 4)) - 40);
            bandsOnce(sys, dl, rb, board, engine, wb, shown.id, cases[2].bands[0..cases[2].count], 1, name, "overlay over 3", &tally);
            _ = rb.SetBoardOverlay(board, null, 0, 0);
        }
    }
    _ = rb.MirrorBoard(board, board_info.mirror_x != 0, board_info.mirror_y != 0);
    rb.MoveBoardPointer(board, was_x, was_y);
    if (was_shown) _ = rb.ShowBoardPointer(board, true);
    const band = [_]rtg.RtgBand{.{ .bitmap = before }};
    if (rb.ShowBoard(board, shown.id, &band, band.len) == rtg.errors.RTGERR_OK) {
        for (made) |maybe| if (maybe) |one| rb.FreeBitMap(one);
    }
    _ = Printf(dl, "%u of %u the same as made in a frame, %u of %u read by as many fetchers as they should be\n", .{ tally.same, tally.compared, tally.direct_right, tally.shows });
    return if (tally.same == tally.compared and tally.direct_right == tally.shows) dos.RETURN_OK else dos.RETURN_WARN;
}

/// One of BANDS's shows: the bands shown twice - the first show after a
/// band was written in is made in a frame, the next read by the display
/// - and its checksum and fetchers, then one of them written in and the
/// same of the frame it is made in; `planes` the board's own lit beside
/// them. Bands that with those want more pipes than the display has are
/// to be made in a frame both times.
fn bandsOnce(sys: *ExecBase, dl: *DosBase, rb: *RtgBase, board: *rtg.RtgBoard, engine: Display, wb: *WatchdogBase, mode_id: u32, bands: []const rtg.RtgBand, planes: u32, way: [*:0]const u8, what: [*:0]const u8, tally: *Tally) void {
    _ = rb.ShowBoard(board, mode_id, bands.ptr, @intCast(bands.len));
    wb.FeedWatchdog();
    const started = sys.UptimeUs();
    if (rb.ShowBoard(board, mode_id, bands.ptr, @intCast(bands.len)) != rtg.errors.RTGERR_OK) {
        _ = Printf(dl, "%-8s %-16s not shown\n", .{ way, what });
        return;
    }
    const took = sys.UptimeUs() - started;
    const read = steadyChecksum(dl, rb, board);
    const reading = fetchersReading(engine);
    wb.FeedWatchdog();
    _ = rb.RefreshRect(bands[0].bitmap, null);
    const framed = steadyChecksum(dl, rb, board);
    const framed_reading = fetchersReading(engine);
    wb.FeedWatchdog();
    tally.compared += 1;
    tally.shows += 1;
    const equal = read != null and framed != null and sameSum(read.?, framed.?);
    if (equal) tally.same += 1;
    // More bands and planes than the display has pipes for are made in
    // a frame.
    const fits = bands.len + planes <= board.direct_bands;
    const right = reading == (if (fits) bands.len else 1) + planes and framed_reading == 1 + planes;
    if (right) tally.direct_right += 1;
    const read_sum = read orelse [3]u32{ 0, 0, 0 };
    const framed_sum = framed orelse [3]u32{ 0, 0, 0 };
    _ = Printf(dl, "%-8s %-16s read %04x %04x %04x by %u fetchers in %lu us, made %04x %04x %04x by %u%s%s\n", .{
        way,           what,          read_sum[0],   read_sum[1],    read_sum[2],                                                    reading,                                                              took,
        framed_sum[0], framed_sum[1], framed_sum[2], framed_reading, @as([*:0]const u8, if (equal) ", the same" else ", DIFFERENT"), @as([*:0]const u8, if (right) "" else " - NOT READ AS IT SHOULD BE"),
    });
}

/// How many of the engine's four fetchers are not blanked.
fn fetchersReading(engine: Display) u32 {
    var reading: u32 = 0;
    for (0..4) |index| {
        if (engine.at(0x05f3 + @as(u32, @intCast(index)) * dcn.HUBP_STRIDE).* & 1 == 0) reading += 1;
    }
    return reading;
}

/// One of DIRECT's pictures: the bars (0), the bars the other way round
/// (1), or eight bands of colour down it (2). In 32 bits a pixel only.
fn pattern(picture: *rtg.RtgBitMap, kind: u32) void {
    if (kind == 0) return bars(picture);
    if (picture.format != .bgra32) return;
    const colours = [_]u32{ 0xFFFFFF, 0xFFFF00, 0x00FFFF, 0x00FF00, 0xFF00FF, 0xFF0000, 0x0000FF, 0x202020 };
    const pixels = picture.pixels orelse return;
    var row: u32 = 0;
    while (row < picture.height) : (row += 1) {
        const line: [*]u32 = @ptrCast(@alignCast(pixels + @as(usize, row) * picture.pitch));
        var column: u32 = 0;
        while (column < picture.width) : (column += 1) {
            const index = if (kind == 1) colours.len - 1 - @as(usize, column) * colours.len / picture.width else @as(usize, row) * colours.len / picture.height;
            line[column] = 0xFF000000 | colours[index];
        }
    }
}

fn sameSum(one: [3]u32, other: [3]u32) bool {
    return one[0] == other[0] and one[1] == other[1] and one[2] == other[2];
}

/// The picture's checksum once it is steady: read until two reads 60 ms
/// apart agree, at most five times; null where it does not settle.
fn steadyChecksum(dl: *DosBase, rb: *RtgBase, board: *rtg.RtgBoard) ?[3]u32 {
    return steadyWindow(dl, rb, board, .{});
}

/// The same for the window of the glass `window` names (its `x`, `y`,
/// `width` and `height`), all of the picture for none.
fn steadyWindow(dl: *DosBase, rb: *RtgBase, board: *rtg.RtgBoard, window: rtg.tags.RtgAmdCrc) ?[3]u32 {
    dl.Delay(8);
    var last: ?[3]u32 = null;
    for (0..5) |_| {
        var crc: rtg.tags.RtgAmdCrc = .{ .x = window.x, .y = window.y, .width = window.width, .height = window.height };
        if (rb.BoardControl(board, rtg.tags.RTGCTRL_AMD_CRC, @bitCast(@intFromPtr(&crc))) != rtg.errors.RTGERR_OK) return null;
        const sum = [3]u32{ crc.red, crc.green, crc.blue };
        if (last) |before| {
            if (sameSum(before, sum)) return sum;
        }
        last = sum;
        dl.Delay(3);
    }
    return null;
}

/// The checksum once the pipe has taken the pointer, and what its cursor
/// is told.
fn pointerAt(dl: *DosBase, rb: *RtgBase, board: *rtg.RtgBoard, engine: Display, when: [*:0]const u8) void {
    dl.Delay(5);
    printChecksum(dl, rb, board, when);
    const control = engine.hubp(cursor_control).*;
    const position = engine.hubp(cursor_position).*;
    const hot_spot = engine.hubp(cursor_hot_spot).*;
    _ = Printf(dl, "        cursor %s at %u,%u, hot spot %u,%u\n", .{
        @as([*:0]const u8, if (control & 1 != 0) "shown" else "hidden"),
        position >> 16 & 0x3fff,
        position & 0x3fff,
        hot_spot >> 16 & 0xff,
        hot_spot & 0xff,
    });
}

/// The pipe's count of frames, read twice 100 ms apart, on a line.
fn printFrames(dl: *DosBase, engine: Display, when: [*:0]const u8) void {
    const first = engine.otg(dcn.OTG_STATUS_FRAME_COUNT).*;
    dl.Delay(5);
    const second = engine.otg(dcn.OTG_STATUS_FRAME_COUNT).*;
    _ = Printf(dl, "%-7s frame %u, %u frames in 100 ms\n", .{ when, second, (second -% first) & frame_count_mask });
}

/// The bits a pipe's count of frames has.
const frame_count_mask: u32 = 0xff_ffff;

/// The power state the board says it is in.
fn powerOf(rb: *RtgBase, board: *rtg.RtgBoard) u32 {
    var info: rtg.RtgBoardInfo = .{};
    _ = rb.GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    return info.power;
}

fn powerName(state: u32) [*:0]const u8 {
    return switch (state) {
        rtg.boards.RTGPWR_ON => "on",
        rtg.boards.RTGPWR_BLANK => "blank",
        rtg.boards.RTGPWR_ASLEEP => "asleep",
        else => "?",
    };
}

/// What SetBoardPower answered: the state reached, or the error's text.
fn powerAnswer(rb: *RtgBase, answer: i32) [*:0]const u8 {
    if (answer < 0) return rb.RtgErrorText(answer);
    return powerName(@intCast(answer));
}

fn hold(dl: *DosBase, wb: *WatchdogBase, halves: u32) void {
    for (0..halves) |_| {
        dl.Delay(25);
        wb.FeedWatchdog();
    }
}

/// FRAMES or FLIP, the watchdog armed for both.
fn display(sys: *ExecBase, dl: *DosBase, ab: *AMDGPUBase, info: amdgpu.GPUInfo, millis: u32, pipe: u32, fetcher: u32, flipping: bool) i32 {
    var block: amdgpu.GPUBlock = .{};
    if (!ab.FindGPUBlock(amdgpu.GPUBLOCK_DISPLAY, 0, &block) or block.count < 3) {
        _ = Printf(dl, "The device %04x:%04x names no display engine\n", .{ info.vendor, info.device });
        return dos.RETURN_FAIL;
    }
    const engine = Display{ .registers = @intCast(info.registers), .segment = block.addresses[2], .pipe = pipe, .fetcher = fetcher };
    _ = Printf(dl, "Display engine %u.%u.%u: pipe %u, frame %u, interrupts %x; fetcher %u reads 0x%lx, told 0x%lx, flip control %x\n", .{
        @as(u32, block.major),                  @as(u32, block.minor),                    @as(u32, block.revision),
        pipe,                                   engine.otg(dcn.OTG_STATUS_FRAME_COUNT).*, engine.otg(dcn.OTG_GLOBAL_SYNC_STATUS).*,
        fetcher,                                engine.reading(),                         engine.told(),
        engine.hubp(dcn.DCSURF_FLIP_CONTROL).*,
    });

    var clock: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &clock.node, 0) != 0) return dos.RETURN_FAIL;
    defer sys.CloseDevice(&clock.node);
    const tb: *TimerBase = @ptrCast(@alignCast(clock.node.device.?));

    const wb: *WatchdogBase = @ptrCast(sys.OpenResource(watchdog.WATCHDOGNAME) orelse {
        _ = Printf(dl, "No %s\n", .{watchdog.WATCHDOGNAME});
        return dos.RETURN_FAIL;
    });
    if (!wb.ArmWatchdog(millis, watchdog.WATCHDOG_RESET_SYSTEM)) {
        _ = Printf(dl, "The watchdog refuses %u ms\n", .{millis});
        return dos.RETURN_FAIL;
    }
    defer wb.DisarmWatchdog();
    _ = Printf(dl, "Watchdog armed: %u ms\n", .{millis});
    _ = dl.Flush(dl.Output());

    var frames = Frames{ .sys = sys, .display = engine };
    if (!hook(ab, &frames)) {
        wb.FeedWatchdog();
        _ = Printf(dl, "No server for the pipe's interrupt: see C:Log\n", .{});
        return dos.RETURN_ERROR;
    }
    defer unhook(ab, &frames);
    wb.FeedWatchdog();
    _ = Printf(dl, "Its interrupt is on: %x\n", .{engine.otg(dcn.OTG_GLOBAL_SYNC_STATUS).*});
    _ = dl.Flush(dl.Output());

    if (!flipping) {
        const first_frame = engine.otg(dcn.OTG_STATUS_FRAME_COUNT).*;
        const first_count = @atomicLoad(u32, &frames.count, .acquire);
        const started = micros(tb);
        hold(dl, wb, 6);
        const took = micros(tb) - started;
        const counted = @atomicLoad(u32, &frames.count, .acquire) - first_count;
        const scanned = engine.otg(dcn.OTG_STATUS_FRAME_COUNT).* -% first_frame;
        _ = Printf(dl, "%u interrupts and %u frames in %lu ms: %lu a second\n", .{
            counted, scanned, took / 1000, @as(u64, counted) * 1_000_000 / @max(took, 1),
        });
        return if (counted == 0) dos.RETURN_ERROR else dos.RETURN_OK;
    }
    return flipOnce(sys, dl, ab, tb, wb, &frames);
}

/// What one flip took.
const Flip = struct { frames: u32, micros: u64, pending: bool, reading: u64 };

/// The fetcher told to read `address` from the pipe's next update, and
/// that waited for: until the flip is no longer pending and the fetcher
/// reads it, or four frames.
fn flipTo(frames: *Frames, tb: *TimerBase, address: u64) Flip {
    const sys = frames.sys;
    const engine = frames.display;
    const control = engine.hubp(dcn.DCSURF_FLIP_CONTROL);
    control.* = control.* & ~(dcn.SURFACE_FLIP_TYPE | dcn.SURFACE_UPDATE_LOCK);
    // Every write of the frame reaches the device's memory before the
    // fetcher is told: a locked instruction drains the gathered writes.
    var drain: u32 = 0;
    _ = @atomicRmw(u32, &drain, .Add, 0, .seq_cst);
    const first = @atomicLoad(u32, &frames.count, .acquire);
    const started = micros(tb);
    engine.hubp(dcn.DCSURF_PRIMARY_SURFACE_ADDRESS_HIGH).* = @truncate(address >> 32 & dcn.ADDRESS_HIGH_MASK);
    engine.hubp(dcn.DCSURF_PRIMARY_SURFACE_ADDRESS).* = @truncate(address);
    var waited: u32 = 0;
    while (waited < 4) {
        sys.ResetWaitable(&frames.came);
        if (@atomicLoad(u32, &frames.count, .acquire) == first +% waited) {
            _ = sys.WaitForAny(&[_]*exec.Waitable{&frames.came}, 1, 50_000);
        }
        waited = @atomicLoad(u32, &frames.count, .acquire) -% first;
        if (control.* & dcn.SURFACE_FLIP_PENDING == 0 and engine.reading() == address) break;
    }
    return .{
        .frames = waited,
        .micros = micros(tb) - started,
        .pending = control.* & dcn.SURFACE_FLIP_PENDING != 0,
        .reading = engine.reading(),
    };
}

fn sayFlip(dl: *DosBase, what: [*:0]const u8, address: u64, flip: Flip) bool {
    const taken = !flip.pending and flip.reading == address;
    _ = Printf(dl, "%s 0x%lx: %s after %u frames, %lu us; the fetcher reads 0x%lx\n", .{
        what,                                                    address,
        if (taken) @as([*:0]const u8, "taken") else "NOT taken", flip.frames,
        flip.micros,                                             flip.reading,
    });
    _ = dl.Flush(dl.Output());
    return taken;
}

/// One flip to a copy of the screen in the device's memory, held, and
/// one back.
fn flipOnce(sys: *ExecBase, dl: *DosBase, ab: *AMDGPUBase, tb: *TimerBase, wb: *WatchdogBase, frames: *Frames) i32 {
    const engine = frames.display;
    const lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const ib: *IntuitionBase = @ptrCast(lib);
    const screen = ib.LockPubScreen(null) orelse {
        _ = Printf(dl, "No default public screen\n", .{});
        return dos.RETURN_FAIL;
    };
    defer ib.UnlockPubScreen(null, screen);
    const buffer = ib.AllocScreenBuffer(screen, intuition.screens.SB_SCREEN_BITMAP) orelse {
        _ = Printf(dl, "The screen's buffer cannot be had\n", .{});
        return dos.RETURN_FAIL;
    };
    defer ib.FreeScreenBuffer(screen, buffer);
    const bitmap = buffer.bitmap;
    const pixels = bitmap.pixels orelse return dos.RETURN_FAIL;
    const pitch_pixels = (engine.hubp(dcn.DCSURF_SURFACE_PITCH).* & dcn.PITCH_MASK) + 1;
    const pitch: usize = @as(usize, pitch_pixels) * 4;
    if (bitmap.width > pitch_pixels or bitmap.pitch < bitmap.width * 4) {
        _ = Printf(dl, "The screen is %u wide, the fetcher's rows %u\n", .{ bitmap.width, pitch_pixels });
        return dos.RETURN_FAIL;
    }
    var frame: amdgpu.GPUMemory = .{};
    if (!ab.AllocGPUMemory(@intCast(pitch * bitmap.height), 4096, &frame)) {
        _ = Printf(dl, "No %lu bytes of the device's memory\n", .{@as(u64, pitch * bitmap.height)});
        return dos.RETURN_FAIL;
    }
    defer ab.FreeGPUMemory(&frame);
    const into: [*]u8 = @ptrFromInt(@as(usize, @intCast(frame.cpu)));
    for (0..bitmap.height) |y| {
        sys.CopyMem(pixels + y * bitmap.pitch, into + y * pitch, bitmap.width * 4);
    }
    _ = Printf(dl, "The screen, %ux%u, copied to 0x%lx (0x%lx to the device), rows %lu bytes apart\n", .{
        bitmap.width, bitmap.height, frame.cpu, frame.device, @as(u64, pitch),
    });
    _ = dl.Flush(dl.Output());
    wb.FeedWatchdog();

    const firmware = engine.told();
    const there = flipTo(frames, tb, frame.device);
    wb.FeedWatchdog();
    const went = sayFlip(dl, "Flipped to", frame.device, there);
    hold(dl, wb, 6);
    const back = flipTo(frames, tb, firmware);
    wb.FeedWatchdog();
    const came = sayFlip(dl, "Flipped back to", firmware, back);
    if (!came) {
        // Told again at once, wherever the scan is, so that the screen is
        // the firmware's whatever the update point did.
        const control = engine.hubp(dcn.DCSURF_FLIP_CONTROL);
        control.* = control.* | dcn.SURFACE_FLIP_TYPE;
        engine.hubp(dcn.DCSURF_PRIMARY_SURFACE_ADDRESS_HIGH).* = @truncate(firmware >> 32 & dcn.ADDRESS_HIGH_MASK);
        engine.hubp(dcn.DCSURF_PRIMARY_SURFACE_ADDRESS).* = @truncate(firmware);
        dl.Delay(5);
        control.* = control.* & ~dcn.SURFACE_FLIP_TYPE;
        _ = Printf(dl, "Told the firmware's screen at once: the fetcher reads 0x%lx\n", .{engine.reading()});
        // The frame may still be read: it is not given back.
        frame = .{};
    }
    return if (went and came) dos.RETURN_OK else dos.RETURN_ERROR;
}
