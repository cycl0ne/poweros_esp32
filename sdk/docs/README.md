# The SDK's documentation

`autodocs/` holds a reference for every library, device and resource the
SDK has a `.fd` file for: one file per module, in two forms.

- `<module>.doc` - plain text: a table of contents, then each call on a
  page of its own (separated by form feeds), with NAME, SYNOPSIS, INPUTS,
  RESULT, BEHAVIOR, CONTEXT, OWNERSHIP, NOTES, BUGS, SEE ALSO and EXAMPLES.
- `<module>.md` - the same as Markdown, its index linking to each call.

| Module | Plain text | Markdown |
|---|---|---|
| console.device | [console.doc](autodocs/console.doc) | [console.md](autodocs/console.md) |
| dma.resource | [dma.doc](autodocs/dma.doc) | [dma.md](autodocs/dma.md) |
| dos.library | [dos.doc](autodocs/dos.doc) | [dos.md](autodocs/dos.md) |
| exec.library | [exec.doc](autodocs/exec.doc) | [exec.md](autodocs/exec.md) |
| expander.resource | [expander.doc](autodocs/expander.doc) | [expander.md](autodocs/expander.md) |
| expansion.library | [expansion.doc](autodocs/expansion.doc) | [expansion.md](autodocs/expansion.md) |
| gpio.resource | [gpio.doc](autodocs/gpio.doc) | [gpio.md](autodocs/gpio.md) |
| graphics.library | [graphics.doc](autodocs/graphics.doc) | [graphics.md](autodocs/graphics.md) |
| input.device | [input.doc](autodocs/input.doc) | [input.md](autodocs/input.md) |
| intuition.library | [intuition.doc](autodocs/intuition.doc) | [intuition.md](autodocs/intuition.md) |
| keymap.library | [keymap.doc](autodocs/keymap.doc) | [keymap.md](autodocs/keymap.md) |
| layers.library | [layers.doc](autodocs/layers.doc) | [layers.md](autodocs/layers.md) |
| platform.resource | [platform.doc](autodocs/platform.doc) | [platform.md](autodocs/platform.md) |
| rtg.library | [rtg.doc](autodocs/rtg.doc) | [rtg.md](autodocs/rtg.md) |
| timer.device | [timer.doc](autodocs/timer.doc) | [timer.md](autodocs/timer.md) |
| utility.library | [utility.doc](autodocs/utility.doc) | [utility.md](autodocs/utility.md) |
| watchdog.resource | [watchdog.doc](autodocs/watchdog.doc) | [watchdog.md](autodocs/watchdog.md) |

The files are generated: `./zig build autodoc` writes them from the doc
comment above each call's `pub fn` in the source, and `./zig build test`
fails when one no longer matches. A call without such a comment is
described by the text of its `.fd` file.
