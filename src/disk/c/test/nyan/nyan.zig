// SPDX-License-Identifier: MIT
//! Nyan: a coloured animation on whatever terminal the program is talking
//! to. Built against the SDK only.
//!
//!   Nyan TIME/K/N,FRAMES/K/N,ROWS/K/N,COLS/K/N,PLAIN/S
//!
//! It exercises the terminal rather than any one device: everything goes
//! to Output(), so the picture travels the whole way a program's output
//! travels - the shell's stream, the console handler, and from there
//! console.device in a window or the serial port on the other side of
//! AUX:. What it asks of a terminal is what an animation asks: the cursor
//! put back at the corner for every frame (`CSI H`), the cursor hidden
//! (`CSI ? 25 l`), a screen of its own to draw on (`CSI ? 1049 h`), and a
//! colour per cell - one of the 256 (`CSI 48;5;n m`), or the sixteen a
//! terminal has by name with `PLAIN`. A terminal that gets any of those
//! wrong says so in the picture: a frame that scrolls, a cursor crawling
//! through the cat, colours that stay where the last cell left them.
//!
//! It also asks the terminal how big it is - `CSI 18 t`, answered with
//! `CSI 8 ; rows ; cols t` - and cuts the picture to what came back, since
//! a frame is 64 cells square and a window is whatever the person made it.
//! The answer is read with the input in raw mode, so the reply is not
//! taken for something typed; `ROWS` and `COLS` say it outright instead,
//! for a terminal that does not answer, and 80 by 25 is what it falls back
//! to.
//!
//! A cell is two characters wide, so the picture is as square on the glass
//! as the font allows, and a cell costs nothing but its colour: the escape
//! is written only where the colour changes from the cell before, which is
//! what keeps a frame down to a few thousand bytes.
//!
//! Ctrl-C ends it, and so does FRAMES once that many have been drawn.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const art = @import("frames.zig");
const rdargs = dos.rdargs;
const DosBase = sdk.interface.dos.DosBase;
const ExecBase = sdk.interface.exec.ExecBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Nyan";
const VERSION_STRING = "\x00$VER: Nyan 1.0 (20.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "TIME/K/N,FRAMES/K/N,ROWS/K/N,COLS/K/N,PLAIN/S";
const arg_time = 0;
const arg_frames = 1;
const arg_rows = 2;
const arg_cols = 3;
const arg_plain = 4;

const MSG_NOBUFFER = "Nyan: no memory for a frame\n";

/// How long a frame is on the screen when TIME says nothing, in ticks of
/// a fiftieth of a second: twelve frames a second and something left over
/// for the drawing.
const default_time: u32 = 4;

/// The terminal to draw on when it does not say how big it is.
const default_rows: i32 = 25;
const default_cols: i32 = 80;

/// What a cell is painted with. Two characters, so a cell is about as wide
/// as it is tall.
const cell = "  ";

/// How long the buffer is that frames are built in. A cell costs two
/// bytes, or thirteen where the colour changes, so a frame of a large
/// window is a few thousand: the buffer is emptied whenever the next cell
/// might not fit, and a frame of an ordinary window goes out in one piece.
const buffer_size = 8192;

/// The six stripes of the trail, with the sky above and below them. Which
/// byte a cell of the trail takes depends on how far back it is and on
/// which half of the beat the animation is in, so the stripes appear to
/// travel with the cat.
const trail = ",,>>&&&+++###==;;;,,";

/// The escape that paints a cell of colour `c`, out of the 256: the cube's
/// numbers, which is what the picture was drawn in.
fn colour256(c: u8) ?[]const u8 {
    return switch (c) {
        ',' => "\x1b[48;5;17m", // the sky
        '.' => "\x1b[48;5;231m", // a star
        '\'' => "\x1b[48;5;16m", // the outline
        '@' => "\x1b[48;5;230m", // the pastry
        '$' => "\x1b[48;5;175m", // its icing
        '-' => "\x1b[48;5;162m", // the cherries on it
        '>' => "\x1b[48;5;196m", // the trail, red
        '&' => "\x1b[48;5;214m", // orange
        '+' => "\x1b[48;5;226m", // yellow
        '#' => "\x1b[48;5;118m", // green
        '=' => "\x1b[48;5;33m", // blue
        ';' => "\x1b[48;5;19m", // indigo
        '*' => "\x1b[48;5;240m", // the cat
        '%' => "\x1b[48;5;175m", // its cheeks
        else => null,
    };
}

/// The same picture in the sixteen colours a terminal has by name, for one
/// that has no colour cube: the eight (`CSI 40 m` and on) and their bright
/// halves (`CSI 100 m` and on), which is exactly enough to keep the
/// fourteen kinds of cell apart but for the two pairs that share one. The
/// picture is coarser, and that is what asking for it shows.
fn colour16(c: u8) ?[]const u8 {
    return switch (c) {
        ',' => "\x1b[44m", // the sky, blue
        '.' => "\x1b[107m", // a star, bright white
        '\'' => "\x1b[40m", // the outline, black
        '@' => "\x1b[47m", // the pastry, white
        '$' => "\x1b[105m", // its icing, bright magenta
        '-' => "\x1b[41m", // the cherries on it, red
        '>' => "\x1b[101m", // the trail, bright red
        '&' => "\x1b[43m", // yellow, which stands in for orange
        '+' => "\x1b[103m", // bright yellow
        '#' => "\x1b[102m", // bright green
        '=' => "\x1b[106m", // bright cyan
        ';' => "\x1b[104m", // bright blue
        '*' => "\x1b[100m", // the cat, bright black
        '%' => "\x1b[45m", // its cheeks, magenta
        else => null,
    };
}

/// Which byte stands at (`x`, `y`) of frame `frame`, in the frame's own
/// coordinates: inside the picture it is the picture's, to the left of it
/// and beside the cat it is the trail, and anywhere else it is the sky. So
/// a terminal wider than 64 cells is not a picture with edges but a sky
/// the trail runs out of.
fn cellAt(frame: usize, x: i32, y: i32) u8 {
    if (y > 23 and y < 43 and x < 0) {
        // The stripes are a square wave: eight cells of one row of the
        // trail, eight of the next, and the phase turns over every other
        // frame, which is what makes them travel.
        var step: i32 = @divTrunc(@mod(-x + 2, 16), 8);
        if ((frame / 2) % 2 == 1) step = 1 - step;
        const i = step + y - 23;
        if (i < 0 or i >= trail.len) return ',';
        return trail[@intCast(i)];
    }
    if (x < 0 or y < 0 or y >= art.height or x >= art.width) return ',';
    return art.frames[frame][@intCast(y)][@intCast(x)];
}

/// What is written, and where it goes. Text is gathered until the buffer
/// is nearly full and then handed to Output() in one piece, so a frame
/// costs a packet or two rather than one per cell.
const Painter = struct {
    dl: *DosBase,
    out: ?*dos.FileHandle,
    buf: []u8,
    len: usize = 0,
    /// A write that failed: the stream is gone, and nothing more is
    /// written to it.
    failed: bool = false,

    fn put(p: *Painter, text: []const u8) void {
        if (p.len + text.len > p.buf.len) p.flush();
        if (p.len + text.len > p.buf.len) return;
        for (text, 0..) |c, i| p.buf[p.len + i] = c;
        p.len += text.len;
    }

    fn flush(p: *Painter) void {
        if (p.len == 0 or p.failed) {
            p.len = 0;
            return;
        }
        if (p.dl.Write(p.out, p.buf.ptr, @intCast(p.len)) < 0) p.failed = true;
        p.len = 0;
    }
};

/// The picture the terminal is cut to: where the top left cell of it sits
/// in the frame's coordinates, and how many cells there are.
const View = struct {
    left: i32,
    top: i32,
    cols: i32,
    rows: i32,

    /// The middle of the frame in the middle of the terminal. A cell is
    /// two characters wide, so half of the terminal's columns is how many
    /// cells fit across it; a row is kept back for the cursor, so that a
    /// terminal which scrolls on the last cell of the last row does not
    /// take the whole frame up with it.
    fn of(rows: i32, cols: i32) View {
        const across = @divTrunc(cols, 2);
        const down = rows - 1;
        return .{
            .left = @divTrunc(art.width - across, 2),
            .top = @divTrunc(art.height - down, 2),
            .cols = across,
            .rows = down,
        };
    }
};

/// One frame, from the corner of the terminal down.
fn paint(p: *Painter, frame: usize, view: View, plain: bool) void {
    p.put("\x1b[H");
    // Nothing is known about what the terminal's colour is at the corner,
    // so the first cell of every frame states its own.
    var last: u8 = 0;
    var y = view.top;
    while (y < view.top + view.rows) : (y += 1) {
        var x = view.left;
        while (x < view.left + view.cols) : (x += 1) {
            const c = cellAt(frame, x, y);
            if (c != last) {
                if (if (plain) colour16(c) else colour256(c)) |seq| {
                    last = c;
                    p.put(seq);
                }
            }
            p.put(cell);
        }
        p.put("\n");
    }
}

/// `CSI 8 ; rows ; cols t`, read out of `reply`: whether that is what it
/// holds, and what it says.
fn parseSize(reply: []const u8, rows: *i32, cols: *i32) bool {
    if (reply.len < 8 or reply[0] != 0x1B or reply[1] != '[' or reply[2] != '8') return false;
    var i: usize = 3;
    var value: [2]i32 = .{ 0, 0 };
    for (&value) |*n| {
        if (i == reply.len or reply[i] != ';') return false;
        i += 1;
        const start = i;
        while (i < reply.len and reply[i] >= '0' and reply[i] <= '9') : (i += 1) {
            n.* = n.* * 10 + (reply[i] - '0');
        }
        if (i == start) return false;
    }
    if (i == reply.len or reply[i] != 't') return false;
    // A terminal of one row or one column is an answer nothing can be
    // drawn in, and more likely a terminal that answered with nonsense.
    if (value[0] < 2 or value[1] < 2) return false;
    rows.* = value[0];
    cols.* = value[1];
    return true;
}

/// How big the terminal says it is. `CSI 18 t` is asked and the answer
/// read, one byte at a time, with the input in raw mode so that the reply
/// is not held back waiting for a line that nobody is going to type. What
/// has not answered within half a second is a terminal that does not
/// answer at all, and `rows` and `cols` are left as they were.
///
/// A key pressed in that half second is read here and lost, since there is
/// nowhere to put a byte back; it is the one thing this costs, and it buys
/// a picture the size of the window it is in. What is already queued when
/// the asking starts - the newline that ended the line this was started
/// from - goes the same way.
fn askSize(dl: *DosBase, rows: *i32, cols: *i32) void {
    const out = dl.Output();
    const in = dl.Input();
    if (!dl.IsInteractive(out) or !dl.IsInteractive(in)) return;

    if (!dl.SetMode(in, 1)) return;
    defer _ = dl.SetMode(in, 0);

    if (dl.Write(out, "\x1b[18t", 5) < 0) return;
    _ = dl.Flush(out);

    var reply: [24]u8 = undefined;
    var len: usize = 0;
    var waits: u32 = 0;
    while (len < reply.len and waits < 5) {
        if (!dl.WaitForChar(in, 100_000)) {
            waits += 1;
            continue;
        }
        var c: u8 = 0;
        if (dl.Read(in, @ptrCast(&c), 1) != 1) return;
        // What arrives before the escape was typed, not answered - the
        // newline of the line this was started from, most often - and the
        // answer is what comes after it.
        if (len == 0 and c != 0x1B) continue;
        reply[len] = c;
        len += 1;
        if (c == 't') break;
    }
    _ = parseSize(reply[0..len], rows, cols);
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [5]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const time: u32 = if (rdargs.number(argv[arg_time])) |n| @intCast(@max(0, n)) else default_time;
    const wanted: u32 = if (rdargs.number(argv[arg_frames])) |n| @intCast(@max(0, n)) else 0;
    const plain = argv[arg_plain] != 0;

    var rows: i32 = default_rows;
    var cols: i32 = default_cols;
    const given_rows = rdargs.number(argv[arg_rows]);
    const given_cols = rdargs.number(argv[arg_cols]);
    // A size that was not given is asked for; one that was is taken as it
    // stands, which is how a terminal that answers nothing is driven.
    if (given_rows == null or given_cols == null) askSize(dl, &rows, &cols);
    if (given_rows) |n| rows = n;
    if (given_cols) |n| cols = n;
    const view = View.of(@max(2, rows), @max(2, cols));

    const buffer = sys.AllocVec(buffer_size, exec.MEMF_ANY) orelse {
        _ = dl.PutStr(MSG_NOBUFFER);
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(buffer);

    var p: Painter = .{
        .dl = dl,
        .out = dl.Output(),
        .buf = @as([*]u8, @ptrCast(buffer))[0..buffer_size],
    };

    // A screen of its own, with no cursor on it: what was on the terminal
    // before comes back when the animation ends.
    p.put("\x1b[?1049h\x1b[?25l\x1b[2J");

    var frame: usize = 0;
    var drawn: u32 = 0;
    var broke = false;
    while (!p.failed) {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
            broke = true;
            break;
        }
        paint(&p, frame, view, plain);
        p.flush();
        drawn += 1;
        if (wanted != 0 and drawn >= wanted) break;
        frame = (frame + 1) % art.frames.len;
        if (time != 0) dl.Delay(time);
    }

    p.put("\x1b[0m\x1b[2J\x1b[H\x1b[?25h\x1b[?1049l");
    p.flush();
    _ = dl.Flush(dl.Output());

    if (broke) {
        // A break says so: a picture that simply stops looks like a
        // program that fell over.
        _ = dl.PrintFault(dos.ERROR_BREAK, null);
        _ = dl.SetIoErr(dos.ERROR_BREAK);
        return dos.RETURN_WARN;
    }
    return dos.RETURN_OK;
}
