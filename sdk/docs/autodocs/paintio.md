# paintio.library

paintio.library's functions: Paint's projects and pictures read from
and written to files. It is Paint's own, in Paint's drawer, and Paint
opens it by its path (sdk.paintio.PAINTIOPATH). A call that can fail
answers 0, or a dos error code that Fault puts into words.

Generated from the source by `./zig build autodoc`.

## Index

- [FreeProject](#freeproject) - Gives back what `LoadProject` allocated for a project.
- [LoadProject](#loadproject) - Reads a project, or a picture as a project of one layer.
- [SavePicture](#savepicture) - Writes pixels as a picture file.
- [SaveProject](#saveproject) - Writes a project as a file of its own: every layer, the palette.

## FreeProject

Gives back what `LoadProject` allocated for a project.

**SYNOPSIS**

```zig
fn FreeProject(base: *PaintIOBase, project: *paintio.Project) void
```

**SINCE**

1.0. LVO -32.

**INPUTS**

- `project`: one `LoadProject` filled in, or one it left empty.

**RESULT**

None. The project is empty afterwards: no layers, no size.

**BEHAVIOR**

Every layer's pixels are freed, then the layers, and the project is
set back to its defaults. An empty project is left as it is, so the
call may be made whatever `LoadProject` answered.

**CONTEXT**

- Waits: no.
- Interrupts: not from an interrupt.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The memory was the caller's from `LoadProject` on; it is gone now. A
project the caller made itself, with its own pixels, is not handed
in: those pixels are not the library's to free.

**NOTES**

A caller that keeps a layer's pixels sets that layer's `pixels` to
null first, and frees them itself later with `FreeVec`.

**BUGS**

None known.

**SEE ALSO**

`LoadProject`

**EXAMPLES**

```zig
var project = paintio.Project{};
if (pio.LoadProject("Work:sky.paint", &project) == 0) {
    // ... the layers taken over ...
    pio.FreeProject(&project);
}
```

## LoadProject

Reads a project, or a picture as a project of one layer.

**SYNOPSIS**

```zig
fn LoadProject(base: *PaintIOBase, name: [*:0]const u8, project: *paintio.Project) i32
```

**SINCE**

1.0. LVO -20.

**INPUTS**

- `name`: the file: a project `SaveProject` wrote, or any picture
  datatypes reads (PNG, ILBM, JPEG, GIF, ...).
- `project`: filled in; what it held before is not looked at.

**RESULT**

0 when the project is filled in, otherwise a dos error code: why the
file could not be read (`ERROR_OBJECT_NOT_FOUND`, say),
`ERROR_OBJECT_WRONG_TYPE` for a file that is neither a project nor a
picture, or a project that is damaged, `ERROR_OBJECT_TOO_LARGE` for a
picture with a side above `MAX_SIDE`, `ERROR_NO_FREE_STORE`, or
`ERROR_INVALID_RESIDENT_LIBRARY` when a library it needs cannot be
opened.

**BEHAVIOR**

A project comes back as it was saved: its size, its layers from the
bottom with their names, opacity, flags and blend modes, the layer
being painted and its palette; `kind` is `PIOKIND_PROJECT`. A picture comes back as
a project of one layer of the picture's size, unnamed and wholly
opaque, with `kind` `PIOKIND_PICTURE` and, when the file had one, its
palette - up to `MAX_PALETTE` colours, each wholly opaque. Pixels are
`0xAARRGGBB`, a picture's coverage in the alpha.

On a failure the project is empty: nothing of it is the caller's to
free, though `FreeProject` may still be called.

**CONTEXT**

- Waits: yes, for the file system.
- Interrupts: not from an interrupt.
- Locks: none taken.
- Process: a Process; the file is opened on its behalf, and
  datatypes reads a picture on it.

**OWNERSHIP**

The layers and their pixels are allocated with `AllocVec` and are the
caller's, given back with `FreeProject`.

**NOTES**

Each layer is the project's size, a row after another with nothing
between: four bytes a pixel. A picture is read whole into memory by
its datatype first, so it takes about twice its pixels while it is
read.

**BUGS**

None known.

**SEE ALSO**

`FreeProject`, `SaveProject`

**EXAMPLES**

```zig
var project = paintio.Project{};
const failure = pio.LoadProject("Work:sky.png", &project);
if (failure != 0) {
    _ = dl.PrintFault(failure, "Work:sky.png");
    return;
}
defer pio.FreeProject(&project);
```

## SavePicture

Writes pixels as a picture file.

**SYNOPSIS**

```zig
fn SavePicture(base: *PaintIOBase, name: [*:0]const u8, pixels: [*]const u32, width: u32, height: u32, format: u32) i32
```

**SINCE**

1.0. LVO -28.

**INPUTS**

- `name`: the file, made anew or written over.
- `pixels`: `width` times `height` pixels, `0xAARRGGBB`, a row after
  another with nothing between.
- `width`, `height`: from 1 to `MAX_SIDE` each.
- `format`: `PIOFORMAT_PNG` or `PIOFORMAT_ILBM`.

**RESULT**

0 when the file is written, otherwise a dos error code: why the file
could not be made or written, `ERROR_NO_FREE_STORE`,
`ERROR_INVALID_RESIDENT_LIBRARY` when datatypes.library or
intuition.library cannot be opened, `ERROR_OBJECT_WRONG_TYPE` when
there is no datatype that writes the format, or `ERROR_BAD_NUMBER`
for a size or a format there is not.

**BEHAVIOR**

A picture with any pixel not wholly opaque is written with its
coverage - a PNG with alpha, an ILBM of 32 planes - and one that is
opaque all over without: an RGB PNG, an ILBM of 24 planes. A PNG is
written by png.datatype, an ILBM by the picture group's own class.
A file that could not be written whole is deleted.

**CONTEXT**

- Waits: yes, for the file system.
- Interrupts: not from an interrupt.
- Locks: none taken.
- Process: a Process; the file is opened on its behalf.

**OWNERSHIP**

The pixels stay the caller's, and are only read. The datatype keeps a
copy of them while it writes: about the pixels' size again.

**NOTES**

A project of several layers is made into one picture by the caller
first; `LoadProject` reads either format back as a picture.

**BUGS**

None known.

**SEE ALSO**

`SaveProject`, `LoadProject`

**EXAMPLES**

```zig
const failure = pio.SavePicture("Work:sky.png", pixels, 320, 200, paintio.PIOFORMAT_PNG);
if (failure != 0) _ = dl.PrintFault(failure, "Work:sky.png");
```

## SaveProject

Writes a project as a file of its own: every layer, the palette.

**SYNOPSIS**

```zig
fn SaveProject(base: *PaintIOBase, name: [*:0]const u8, project: *const paintio.Project) i32
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `name`: the file, made anew or written over.
- `project`: the size, the layers from the bottom with their pixels,
  the layer being painted and the palette (`palette_count` colours of
  `palette`). `kind` is not written.

**RESULT**

0 when the file is written, otherwise a dos error code: why the file
could not be made or written (`ERROR_DISK_FULL`, say),
`ERROR_NO_FREE_STORE`, `ERROR_INVALID_RESIDENT_LIBRARY` when
iffparse.library or compression.library cannot be opened, or
`ERROR_BAD_NUMBER` for a project no file holds - a side of 0 or
above `MAX_SIDE`, no layers or more than `MAX_LAYERS`, a layer
without pixels, a current layer past the last, a palette of more
than `MAX_PALETTE`.

**BEHAVIOR**

The file is an IFF `FORM PNTG` (`sdk.paintio` has its chunks): the
header, the palette when it has colours, and each layer's header and
pixels, packed by Deflate in a zlib wrapping. A file that could not
be written whole is deleted, so a failure leaves no half a project
behind - nor the file that was there before.

**CONTEXT**

- Waits: yes, for the file system.
- Interrupts: not from an interrupt.
- Locks: none taken.
- Process: a Process; the file is opened on its behalf.

**OWNERSHIP**

The project and its pixels stay the caller's, and are only read.

**NOTES**

`LoadProject` reads the file back. A chunk it does not know is passed
over, so a later version may add some.

**BUGS**

None known.

**SEE ALSO**

`LoadProject`, `SavePicture`

**EXAMPLES**

```zig
var layer = paintio.Layer{ .pixels = pixels };
var project = paintio.Project{ .width = 320, .height = 200, .layer_count = 1, .layers = @ptrCast(&layer) };
const failure = pio.SaveProject("Work:sky.paint", &project);
if (failure != 0) _ = dl.PrintFault(failure, "Work:sky.paint");
```
