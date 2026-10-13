# Terminal

Terminal is a window joined to a serial line: what comes in on the line
is shown, and what is typed goes out on it. Use it to talk to a board on
a UART, a modem, or a USB serial adapter.

## Starting it

Double-click its icon, or type in a shell:

```
Terminal [DEVICE] [UNIT=n] [BAUD=n] [FRAME=8N1] [SETTINGS]
```

Without a line saved or given, the settings window opens first, so that
one can be chosen. `DEVICE` and `UNIT` name a line directly
(`Terminal serial.device UNIT=1 BAUD=9600`), and `SETTINGS` opens the
settings window at the start anyway.

## The window

The window is a terminal of the kind a far end expects - VT100 with
colours, line drawing, a second screen and the cursor keys - so a shell
on a Linux board, a boot loader's menu or a modem's commands look as
they should. Select text with the pointer to copy it; right-Amiga-V or
Shift-Insert pastes it, and it goes out on the line as though it were
typed. Make the window larger and the text is laid out again.

The window's title says which line it is on, at what speed and frame,
and whether what comes in is being captured to a file.

## The menus

- **Project:** Settings... (S), Send File... (U), Capture to File... (L),
  End Capture, About, Quit (Q)
- **Line:** Send Break (B), Clear Screen (K), Reset Terminal

Send File sends a file's bytes as they are. A file dropped on the window
from the desktop is sent the same way. Capture to File keeps everything
that comes in, exactly as it came, until End Capture.

## Settings

- **Line:** the serial line. Its button lists the serial lines this board
  has - its UART connectors, the USB serial port, USB serial adapters -
  with what the board calls each.
- **Speed:** bits per second.
- **Frame:** data bits, parity and stop bits, such as 8N1.
- **Handshake:** none, or xON/xOFF.
- **Return sends:** CR, LF, or CR LF - what the far end takes as the end
  of a line.
- **Echo typing:** shows what is typed, for a far end that does not
  send it back.
- **LF starts a new line:** for a far end that ends its lines with a line
  feed alone.

**Save** keeps the settings for the next time, **Use** for now, and
**Cancel** leaves them as they were. They are kept in
`ENVARC:Terminal.prefs`, one line of the same words the command takes:

```
DEVICE="serial.device" UNIT=1 BAUD=115200 FRAME=8N1 HANDSHAKE=NONE RETURN=CR ECHO=OFF LFNEWLINE=ON
```
