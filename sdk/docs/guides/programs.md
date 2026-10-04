# Writing programs

The SDK (`sdk/`) is a Zig package of its own. A program depends on it and
builds with `addProgram`, which knows the chip, the linker script and how
to make the load file. Every library, device and resource call is
described in the [autodocs](../README.md), and the other guides say how
they work together.

```zig
// build.zig
const std = @import("std");
const poweros_sdk = @import("poweros_sdk");

pub fn build(b: *std.Build) void {
    const sdk = b.dependency("poweros_sdk", .{});
    const seg = poweros_sdk.addProgram(b, sdk, .{ .name = "hello", .root = b.path("hello.zig") });
    b.getInstallStep().dependOn(&b.addInstallBinFile(seg, "hello.seg").step);
}
```

## Hello, world - in the shell

A command is a function `_program_entry` that gets exec's base. It opens
the libraries it needs by name and closes them again:

```zig
// hello.zig
const sdk = @import("sdk");
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;

export fn _program_entry(sys: *ExecBase, _: [*]const u8, _: usize) callconv(.c) i32 {
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    _ = dos.stdio.Printf(dl, "Hello, world!\n", .{});
    return dos.RETURN_OK;
}
```

`zig build` makes `zig-out/bin/hello.seg`; put it on the disk with
`-Dextra=c/hello=path/to/hello.seg` and run `hello` from the shell.

## Hello, world - in a window

The shell's hello-world, with intuition.library and graphics.library
instead of dos.library: a window on the default screen, the words drawn into its RastPort, and its messages
waited for until the close gadget is used or Ctrl-C comes:

```zig
// window.zig
const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const wn = intuition.windows;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;

export fn _program_entry(sys: *ExecBase, _: [*]const u8, _: usize) callconv(.c) i32 {
    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);
    const gfx_lib = sys.OpenLibrary(graphics.GRAPHICSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(gfx_lib);
    const gb: *GraphicsBase = @ptrCast(gfx_lib);

    // A window on the default screen, with a close gadget that tells us so.
    const w = ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Hello") },
        .{ .tag = wn.WA_InnerWidth, .data = 240 },
        .{ .tag = wn.WA_InnerHeight, .data = 60 },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_CLOSEWINDOW },
        .{},
    }) orelse return dos.RETURN_FAIL;
    defer ib.CloseWindow(w);

    // The window's RastPort, and where the inside starts.
    var rp_addr: usize = 0;
    var left: usize = 0;
    var top: usize = 0;
    ib.GetWindowAttrs(w, &[_]TagItem{
        .{ .tag = wn.WA_RastPort, .data = @intFromPtr(&rp_addr) },
        .{ .tag = wn.WA_BorderLeft, .data = @intFromPtr(&left) },
        .{ .tag = wn.WA_BorderTop, .data = @intFromPtr(&top) },
        .{},
    });
    const rp: *graphics.RastPort = @ptrFromInt(rp_addr);

    // The words, in the screen's text pen.
    const text = "Hello, world!";
    gb.Move(rp, @intCast(left + 20), @intCast(top + 35));
    gb.Text(rp, text, text.len);

    // Wait until the close gadget is used, or Ctrl-C comes.
    while (true) {
        const got = ib.WaitIMsg(w, exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_WARN;
        while (ib.GetIMsg(w)) |im| {
            const class = im.class;
            ib.ReplyIMsg(im);
            if (class == wn.IDCMP_CLOSEWINDOW) return dos.RETURN_OK;
        }
    }
}
```

## Buttons in a window

A window of gadgets is described rather than built: a layout
(`layoutgclass`) sizes and places the buttons, and a window object
(`windowclass`) opens a window around it - as big as the layout looks
right at, in the middle of the screen, no smaller than the layout fits
in - and hands over each message as one word, already replied:

```zig
// buttons.zig
const sdk = @import("sdk");
const dos = sdk.dos;
const intuition = sdk.intuition;
const wn = intuition.windows;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wc = intuition.windowclass;
const classusr = intuition.classusr;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;

fn button(ib: *IntuitionBase, text: [*:0]const u8, id: usize) ?*intuition.Object {
    return ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr(text) },
        .{ .tag = gc.GA_ID, .data = id },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{},
    });
}

export fn _program_entry(sys: *ExecBase, _: [*]const u8, _: usize) callconv(.c) i32 {
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);
    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);

    // Two buttons in a row, sized and placed by the layout; the window
    // around them sized, placed and taken down by the window object.
    const row = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
        .{ .tag = lg.LAYOUTA_Margin, .data = 8 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(button(ib, "Hello", 1)) },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(button(ib, "Goodbye", 2)) },
        .{},
    }) orelse return dos.RETURN_FAIL;
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Buttons") },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(row) },
        .{},
    }) orelse return dos.RETURN_FAIL;
    defer ib.DisposeObject(object); // the window, the layout, the buttons

    var open = wc.WmOpen{};
    const window: *intuition.Window = @ptrFromInt(ib.SendMessage(object, @ptrCast(&open)));
    if (@intFromPtr(window) == 0) return dos.RETURN_FAIL;

    // Each message as one word: what happened, and which gadget.
    var handle = wc.WmHandleInput{};
    while (true) {
        _ = ib.WaitIMsg(window, 0);
        while (true) {
            const word = ib.SendMessage(object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => return dos.RETURN_OK,
                wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
                    1 => _ = dos.stdio.Printf(dl, "Hello!\n", .{}),
                    else => return dos.RETURN_OK,
                },
                else => {},
            }
        }
    }
}
```

Each gets its own `addProgram` in `build.zig`, as `hello` above,
and `zig build` makes `zig-out/bin/window.seg` and `buttons.seg`. Put them on the disk with
`-Dextra=c/hello=path/to/hello.seg` (or drop them into the tree's
`disk/c/`), and run them from the shell: `run window` keeps the shell free while
the window is open.

The programs in `src/disk/c/` are all built this way and are the best
examples: each opens its libraries, reads its arguments with a `ReadArgs`
template and carries a `$VER:` string.

### When it stops

`s3>` is a task: it needs the scheduler, a console device and memory, so
it is gone exactly when it is wanted most. The ROM debugger is the other
half - it runs with interrupts masked, on no task, through no device,
and allocates nothing:

```
dbg> bt
   0  0x428DF23C (the ROM)
   1  0x428DCCF1 (the ROM)
   2  0x428DBDD3 (the ROM)
   3  0x40378844 (the ROM)
dbg> r                       the registers and the trap frame
dbg> d 3fc89a00 64           memory, in words
dbg> m 3fc89a00 0            one word written
dbg> b 428e5de4              a breakpoint; b off [n] takes one away
dbg> w 3fc9bbf8 8 w          a watchpoint: 8 bytes, on writing
dbg> s                       one instruction
dbg> g                       go on
```

The breakpoints and watchpoints are the core's own - two of each - so
nothing is written into the code, which could not be done anyway: it is
in flash, mapped for reading. `s` steps one instruction with every
interrupt held off, so what is stepped is the code that was stopped and
not whichever interrupt happened to be next; the stopped code's own
interrupt level is left alone, because it may be inside a `Disable`.

Going on from a breakpoint is not just returning - the address is still
the one the core stops at - so the breakpoint is held off, the one
instruction stepped, and it is put back. That step is the one visit to
the debugger that says nothing.

There are three ways in: a dead-end Guru offers it for a few seconds and
halts as it always has if nobody answers; `debug` at the `s3>` prompt
stops a working machine and `g` sets it going again; and `Debug()` from
code. It talks on **both** raw ports at once - UART0 and the chip's own
USB port - and takes a character from whichever has one, because which
cable is plugged in is not something a stopped machine can ask. A Guru
is copied to both for the same reason.

An address is named with the code it is in, which for a program loaded
from disk is its file and the offset into it - the same offset its ELF
has, so `llvm-addr2line` turns it into a line.

### More than buttons

Beyond the classes the ROM holds, `SYS:classes/gadgets/` has one library
per gadget kind, and a program opens the ones it uses before it makes
them: `checkbox`, `cycle`, `radiobutton`, `string`, `text`, `slider`,
`scroller`, `listview`, `palette`, `colorwheel`, `gradientslider`,
`tapedeck`, `fuelgauge` (a bar showing how far along something is),
`spinner` (a ring of dots going round while something goes on),
`meter` (a dial with a scale and a needle), `arc` (a ring filled to a
level, or turned by its knob), `roller` (a wheel of choices turned by
dragging), `calendar` (a month to pick a day from), `canvas` (a picture
the program draws into and the gadget shows), `qrcode` and `barcode` (a
text as a QR code, a Code 128 or an EAN-13), `chart` (values over time
as lines or bars, kept by the gadget), `keyboard` (keys on the screen,
written to input.device as a keyboard's are),
`integer` (a number field with a range and stepping arrows), `chooser` (a
button that pops a list up to pick from), and `clicktab` with `page` (a
row of tabs over pages of gadgets), and `getfile` with `getfont` (a
field with a button beside it that opens asl.library's requester). Each
has its tags in `sdk/libs/gadgets/<name>.zig`, named after the class:

```zig
const ig = sdk.gadgets.integer;

const lib = sys.OpenLibrary(ig.INTEGER_LIBRARY, 0) orelse return;
defer sys.CloseLibrary(lib); // after the gadget is disposed of
const port = ib.NewObjectTagList(null, ig.INTEGER_CLASS, &.{
    .{ .tag = gc.GA_ID, .data = 1 },
    .{ .tag = ig.INTEGER_Min, .data = 1 },
    .{ .tag = ig.INTEGER_Max, .data = 65535 },
    .{ .tag = ig.INTEGER_Number, .data = 23 },
    .{},
});
```

A `getfile` or `getfont` gadget opens its requester on a process of its
own, because the press that asks for it arrives on the input handler,
which may neither draw nor wait. What was picked is written into the
field and told to the gadget's `ICA_TARGET`, so a gadget whose target is
`ICTARGET_IDCMP` tells its window and the program hears
`WMHI_IDCMPUPDATE`:

```zig
const file = ib.NewObjectTagList(null, gfi.GETFILE_CLASS, &.{
    .{ .tag = gc.GA_ID, .data = 7 },
    .{ .tag = gfi.GETFILE_TitleText, .data = @intFromPtr("Which file?") },
    .{ .tag = gfi.GETFILE_Drawer, .data = @intFromPtr("SYS:") },
    .{ .tag = icc.ICA_TARGET, .data = icc.ICTARGET_IDCMP },
    .{},
});
```

A layout groups what belongs together: `LAYOUTA_Frame` draws a frame
round it and `LAYOUTA_FrameTitle` puts a title in the frame's top edge,
both taking their room before the children are placed. `C:test/Settings`
is a window of all of this - tabs over pages, framed groups, a number
field, a chooser and a fuel gauge.

### Text in more than one look

`text.gadget` shows runs of text each in its own font, soft style and
colour - an array of `TextRun`s (`TEXT_Runs`), or its text read as a
small markup (`TEXT_Markup`): `<b>`, `<i>`, `<u>`, `<c=#RRGGBB>`,
`<s=N>` for a size, `</>` to end the last, `<br>` for a new line and
`<<` for a `<`. With `TEXT_Wrap` it breaks the runs into lines as wide as
the gadget:

```zig
const help = ib.NewObjectTagList(null, tx.TEXT_CLASS, &.{
    .{ .tag = tx.TEXT_Markup, .data = 1 },
    .{ .tag = tx.TEXT_Wrap, .data = 1 },
    .{ .tag = gc.GA_Width, .data = 200 },
    .{ .tag = tx.TEXT_Text, .data = @intFromPtr("Press <b>OK</b> to go on.") },
    .{},
});
```

### A keyboard on the screen

On a board whose only input is a touch panel, intuition brings a
keyboard up at the bottom of the screen whenever a field gets the input,
and takes it away when the field lets go: a program does nothing for
it. `IPREFS_Keyboard` says when - `KEYBOARD_AUTO` (no keyboard on
the board, the default), `KEYBOARD_ALWAYS` or `KEYBOARD_NEVER`.
`C:test/Keyboard` turns it on and opens a field to try it with.
The setting is kept in `ENVARC:Sys/intuition.prefs` with intuition's
other two - `DOUBLECLICK=1500 SCREENFONT=16 KEYBOARD=AUTO` - which
`C:SetPrefs` hands to intuition at boot and `SYS:Programs/Prefs` edits.

Every setting the system keeps is a tag: `SetPrefs` changes those
given and tells every window that listens (`IDCMP_NEWPREFS`), `GetPrefs`
writes each where its tag's data points, and `GetDefPrefs` the ones the
system starts with:

```zig
var ms: u32 = 0;
_ = ib.GetPrefs(&[_]TagItem{ .{ .tag = intuition.IPREFS_DoubleClick, .data = @intFromPtr(&ms) }, .{} });
_ = ib.SetPrefs(&[_]TagItem{ .{ .tag = intuition.IPREFS_Keyboard, .data = intuition.KEYBOARD_NEVER }, .{} });
```

`C:SetPrefs` gives them all from `ENV:Sys` in one call: intuition.prefs,
font.prefs, palette.prefs (the [screens' pens](styles.md#the-screens-pens))
and style.prefs.

The keyboard is a window opened with `WA_NoActivate`: a press on it
reaches its gadgets and leaves the active window - and the field being
typed into - as they were. A program may open one of those too, for a
palette of tools that should not take the keys from the window being
worked in.


## When a check fails

Programs are built ReleaseSafe, so an overflow, an index out of bounds or a
null unwrapped is caught where it happens. `addProgram` gives every program
the SDK's panic handler (`sdk/program.zig`, `sdk.exec.panic`), and a failed
check stops the machine with a Guru on the serial console that says what
failed and where:

```
*** Software Failure.
*** Guru Meditation #81000101.42071B16
*** index out of bounds: index 5, len 2
*** in EchoArgs at +0x51A
*** Task "Shell Process [2]" at 0x3C084148
*** system halted
```

`81000101` is `AN_ProgramPanic`. The fourth line names the loaded file and
the offset into its code, which is the address in the program's linked ELF
(its code is linked at 0). The offset is the return address of the call
into the handler, so the check itself is 3 bytes before it:

```sh
llvm-symbolizer --obj=<the program's ELF> 0x517
```

The ELF is what `addProgram` links before it makes the load file: the
`compile exe <name>` step's output in Zig's cache. A failure in the ROM
says `in the ROM` instead, and its address is looked up in
`zig-out/bin/kernel`.

A panic handler is handed no base, so it finds exec through
`sdk.exec.AbsExecBase`, the one fixed address in the system, and reports
with `AlertAt`. Code that is handed SysBase keeps using what it was
handed.

### A stack that runs out

A command runs on a stack of its own, `CLI_DEFAULT_STACK` (16 KiB) unless
the shell's `Stack` command set another size. A window of gadgets uses
more of it than its size suggests: a layout in a group in a page, and
every message passing through several calls, each with a frame on a
register-window stack.

The bottom words of every stack - a task's, and the one a command runs on
- hold a guard. exec looks at it each time it switches away from the task,
and once more when the command ends; a stack that ran past its end has
written over it, and the machine stops at that moment rather than in
whatever memory the overflow landed on:

```
*** Software Failure.
*** Guru Meditation #8100000E.7C063C20
*** a task's stack ran past its end
*** Task "Shell Process [1]" at 0x3C06C518
```

`8100000E` is `AN_StackProbe`. A command that needs more is run after
`Stack 32000`; a task a program makes is given more with `CreateTask`'s or
`NP_StackSize`'s size. The bottom 16 bytes of a stack are the guard's, not
the task's.

## The system log

Everything written to the serial console - `sdk.exec.kprintf`, which is
`RawDoFmt` to `RawPutChar`, and the kernel's own lines - is kept by exec
in a ring from the first byte of the boot: 16 KiB, unless the board says
otherwise (`SYSTAG_LogSize`). Each line gets the time since the boot and
its writer in front, the running task's name, or `int` in an interrupt:

```
[   1.595693 Background CLI [2]] openeth.device: the Ethernet MAC does not answer
```

**Levels.** A line is an error, a warning, information or a debugging
detail. `kprintf` writes information; `sdk.exec.klog` writes at the level
it is given, and a line that is not information has its level's letter
after the prefix:

```zig
sdk.exec.klog(sys, sdk.exec.LOG_WARNING, "sdcard.device: card %d not answering\n", .{unit});
// [  12.345678 sdcard] W: sdcard.device: card 0 not answering
```

exec keeps information and up. A line below the level kept is not
written at all - not to the port, which is polled and slow, not to the
log - so a debug line costs nothing until it is asked for. `Log LEVEL
debug` keeps everything from then on, `Log LEVEL warning` only errors and
warnings; at boot the level is `ENV:Sys/loglevel`'s when it names one. A
program changes it with `LogControl(LOGCTRL_LEVEL, level)`, which answers
the level before. An alert's lines are written whatever the level.

**Reading it.** `Log` shows it (`LINES 20` for the last twenty lines,
`FROM 12.5` from 12.5 seconds after the boot on), follows it (`FOLLOW`,
until Ctrl-C) and saves it (`SAVE` into `RAM:Log/system.log`, `TO <file>`
anywhere else). A program reads it the same way: every byte has a
running number, and `ReadLog` copies what follows a number and moves the
number on; `SetLogSignal` has a task signalled when the log grows, at
most every ten ticks.

```zig
var position: u64 = 0; // the oldest byte the ring still holds
var buffer: [512]u8 = undefined;
while (true) {
    const count = sys.ReadLog(&position, &buffer, buffer.len);
    if (count == 0) break;
    _ = dl.Write(dl.Output(), &buffer, count);
}
```

**On the USB console.** Both boards' console is the chip's USB port,
and the raw port is UART0 - a second cable on the 7B, not wired at all on
the ES3C35P. Where the board says so (the ES3C35P) the log goes to the USB
console too, from the first line of the boot: the raw port writes it
there itself until usbserial.device starts, and from then on that
device's own task copies it between the console's writes. `Log MIRROR ON`
and `OFF` switch it on any board.

**To a syslog server.** `Run >NIL: Log SYSLOG 10.0.0.2` sends what the
log holds and then every line as it comes, a UDP datagram each, to port
514 (or `host:port`). S:Network-Startup starts it when
`ENVARC:Sys/net/syslog` names a server.

**The last words.** A dead end that nobody answers - no debugger asked
for within a few seconds - restarts the machine rather than halting it,
and keeps the last 4 KiB of the log in RTC memory, which a software reset
does not touch. The next boot puts them at the head of its log, between
`---- the last words of the boot before ----` and `---- the end of them
----`, and says so on its second line; `Log` shows them. Reboot in the
Software Failure requester keeps them too. The reset button clears that
memory: it powers the chip down.

## Keeping others out: Forbid, semaphores and spinlocks

Three ways keep two pieces of code from changing the same thing at once,
each for its own case:

| | Holds for | The others | For |
|---|---|---|---|
| `Forbid`/`Permit` | a few lines | no other task inside Forbid runs, and no task starts running; interrupts do | exec's lists, walked by a task |
| `ObtainSemaphore`/`ReleaseSemaphore` | as long as needed, waits included | a task that wants it sleeps until it is given back | a file, a screen, a device's unit |
| `AcquireLock`/`ReleaseLock` | a few hundred cycles | one that wants it tries again until it is free | what an interrupt or another core touches too |

A **spinlock** is an `exec.Lock`, made once with `InitLock`: a name for
the alerts that mention it, its place in the lock order, and
`LOCKF_INTERRUPT` when an interrupt takes it as well.

```zig
sys.InitLock(&unit.lock, "mydev unit", sdk.exec.LOCKORDER_DRIVER, sdk.exec.LOCKF_INTERRUPT);

// In a task, and in the unit's interrupt server alike:
sys.AcquireLock(&unit.lock);
unit.pending += 1;
sys.ReleaseLock(&unit.lock);
```

While a lock is held, task switching on the core stops, and with
`LOCKF_INTERRUPT` its interrupts are masked too, so a task holding a lock
its own interrupt needs cannot be interrupted into a spin. `AttemptLock`
takes the lock only if it is free and answers at once.

**The rules**, which exec checks on every call:

- Nothing that may wait while a lock is held: no `Wait`, `DoIO`,
  `ObtainSemaphore` or file. `Wait` with a lock held is an alert. Nor
  `AllocMem`: when memory runs short it runs the low-memory handlers,
  which expunge libraries.
- Locks in one order. Each has a number (`LOCKORDER_DRIVER` and up for a
  program's or a driver's own, `LOCKORDER_SYSTEM` and up for exec's), and
  a lock is taken only while every lock held has a smaller one. Taking
  them in different orders on two cores could leave each waiting for the
  other; taking them out of order is an alert naming both.
- A lock an interrupt takes is a `LOCKF_INTERRUPT` lock; a plain one taken
  in an interrupt is an alert.

A broken rule is a recoverable alert (`AN_LockRule`), and the call goes on.
A lock taken again on the core that holds it would spin for good, so it is
a dead end (`AN_LockDeadlock`) instead.

A lock may live anywhere. In internal memory taking it is one
compare-and-set instruction; in PSRAM, where this chip has none, exec takes
it under a guard word in internal memory, with interrupts masked for those
few instructions.

## Two cores

The kernel runs on both of the chip's cores where the board says so (and
always in QEMU; `-Dcores=1` builds one that keeps to one). Each core has a
dispatcher of its own, both take tasks from one ready list, and a task
runs on whichever core is free - so two tasks really do run at once, and
what keeps them apart has to hold on both cores:

- **Forbid** is one lock for the whole machine. Two Forbid sections never
  run at once, and while one runs the other core keeps the task it has
  but starts no other: a task made ready inside Forbid runs after the
  `Permit`, as on one core. So a task that signals its parent inside
  Forbid and ends is gone before the parent runs. What Forbid does not do
  is stop the task already running on the other core - it guards what
  everybody touches only inside Forbid, which exec's lists are.
- **Disable** masks this core's interrupts and holds off the other core's
  interrupts and Disables as well. The devices' interrupts are all core
  0's.
- **A spinlock** stops task switching on its own core only, which is all
  it needs: the other core spins until it is free.
- **The cycle counter** (`sdk.hardware.cpu.ccount`) is each core's own,
  and the two do not agree. A wait of a few microseconds is
  `cpu.spinCycles`, which keeps the task on one core while it counts.
- **SYSTEM's clock and reset registers** are shared by every driver on
  both cores: a driver changes them inside `Disable`.

A task that has to stay on one core - code written for one core, or one
that drives a core's own hardware - is pinned with `SetTaskAffinity`, or
from its first instruction with `NP_Affinity` when dos makes it:

```zig
sys.Forbid(); // no core starts it before it is pinned
const task = sys.CreateTask("radio", 5, &radioCode, 8192) orelse return error.NoMemory;
_ = sys.SetTaskAffinity(task, sdk.exec.TF_CORE0);
sys.Permit();
```

The idle tasks are pinned one to each core, and so is the Wi-Fi vendor
code, to core 0. A running task is on neither of exec's task queues:
`CoreTask(core)` answers what a core runs - asked inside `Disable`, from
core 0 up until it answers null - which is how `ShowInfo TASKS` lists every
task once, with the core it runs on and the core it is pinned to.
`ReadCoreTimes(core, &times)` answers how a core has spent its time since
it started - in tasks, idle, in interrupts, in cycles of its clock, counted
at every exception rather than sampled; read it twice and divide the
differences for how busy the core was in between, which is what
`SYS:Programs/CPULoad` charts. On the `s3>` console `cores` shows what each
core runs and what has held its interrupts off longest - the system's
interrupt lock, the cache engine, each device source and interrupt line -
which is what makes a driver's interrupt late (`cores reset` starts the
count again), and `cores share off` keeps the second core to its own
tasks, which is how a fault is told from one that only shows with two
cores.
`C:test/Cores` sets tasks on each other through all of the above - FREE
lets them run flat out, PIN puts half on each core - and checks that
nothing overlapped and nothing was lost.
