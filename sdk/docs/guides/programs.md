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

