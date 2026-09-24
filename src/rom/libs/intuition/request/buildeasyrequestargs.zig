// SPDX-License-Identifier: MPL-2.0
//! BuildEasyRequestArgs: opens a requester - a message and a row of
//! buttons in a window of their own - and hands it back to be answered.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classusr = intuition.classusr;
const wn = intuition.windows;
const sc = intuition.screens;
const ic = intuition.imageclass;
const gc = intuition.gadgetclass;
const Object = intuition.Object;
const IntuiText = intuition.IntuiText;
const EasyStruct = intuition.EasyStruct;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const Window = _window.Window;
const Screen = @import("../screen/_screen.zig").Screen;
const _request = @import("_request.zig");
const Request = _request.Request;

/// Around the frame and the buttons, and between the two.
const margin = 4;
/// Between two buttons, before the row is spread to the frame's width.
const button_gap = 12;
/// Beside the message, each side, inside its frame.
const text_margin = 20;
/// Round the message before its frame is measured: beside it and above
/// and below it.
const text_inset_x = 6;
const text_inset_y = 3;
/// The ground: every other pixel in the shine pen, a row's offset from the
/// next, over the background pen.
const ground_tile = [_]u8{ 0x55, 0x55, 0xAA, 0xAA };

/// Opens a requester and hands it back to be answered.
///
/// SYNOPSIS:
/// ```zig
/// fn BuildEasyRequestArgs(ib: *IntuitionBase, window: ?*Window,
///     easy_struct: *const EasyStruct, idcmp: u32,
///     args: ?*const anyopaque) ?*Window
/// ```
///
/// SINCE: 0.11. LVO -252.
///
/// INPUTS:
/// - `window` - the window the requester is about: it opens on this
///   window's screen and takes its title. Null puts it on the default
///   public screen.
/// - `easy_struct` - what it says: `text_format`, lines separated by `\n`,
///   and `gadget_format`, the buttons from the left separated by `|`;
///   `title`, or null for the window's title, or "System Request" without
///   a window.
/// - `idcmp` - IDCMP classes of the caller's own that answer it as well,
///   as `SysReqHandler`'s -1; 0 for none.
/// - `args` - the values for both formats, as RawDoFmt reads them: the
///   message's first, then the buttons' (`sdk.exec.fmtStream`). Null when
///   neither format has a `%`.
///
/// RESULT:
/// The requester's window, active, or null when it could not be made:
/// there was no memory, no screen, or the window would not open.
///
/// BEHAVIOR:
/// Both formats are expanded with RawDoFmt and then split, so a value may
/// add a line or a button. The message is laid out a line under the other
/// in the screen's font, sunk in a frame, and drawn once - the window is
/// smart refresh, so what is covered is kept. The buttons, framed and in a
/// row under it, are spread to the frame's width, a single one centred.
/// The frame is as wide as the message with room each side, the row of
/// buttons, or the title, whichever is widest, within the screen. The
/// window opens at the screen's top left, with a drag bar and a depth
/// gadget.
///
/// The buttons answer 1, 2, ... from the left and 0 for the rightmost,
/// which is where a cancel goes.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore and the layers' locks.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do. A process has its IoErr set: 0 when the
///   requester opened, `ERROR_NO_FREE_STORE` when it did not.
///
/// OWNERSHIP:
/// The window and everything made for it are the caller's until
/// `FreeSysRequest`. The EasyStruct and the values are read here and not
/// kept.
///
/// NOTES:
/// - Read the answers with `SysReqHandler`, which knows what the window's
///   messages mean.
///
/// BUGS:
/// - A message wider than the screen is cut off by it, and so is a row of
///   buttons that does not fit.
///
/// SEE ALSO:
/// `EasyRequestArgs`, `SysReqHandler`, `FreeSysRequest`
///
/// EXAMPLES:
/// ```zig
/// const ask = EasyStruct{ .text_format = "Save %s?", .gadget_format = "Save|Cancel" };
/// const stream = sdk.exec.fmtStream(.{name});
/// const req = ib.BuildEasyRequestArgs(window, &ask, 0, &stream) orelse return;
/// defer ib.FreeSysRequest(req);
/// ```
pub fn BuildEasyRequestArgs(ib: *IntuitionBase, window: ?*Window, easy_struct: *const EasyStruct, idcmp: u32, args: ?*const anyopaque) ?*Window {
    const sys = ib.sys_base;
    const it = ib.iface();
    processFail(ib, false);

    // What the words come to, and how many lines and buttons they make.
    var body = Measure{ .separator = '\n' };
    const after_body = sys.RawDoFmt(easy_struct.text_format, args, &measure, &body);
    var labels = Measure{ .separator = '|' };
    _ = sys.RawDoFmt(easy_struct.gadget_format, after_body, &measure, &labels);
    const line_count = body.separators + 1;
    const button_count = labels.separators + 1;

    // One block: the Request, the lines, the buttons, the words.
    const ub = ib.utility_base;
    const lines_at = ub.AlignUp(@sizeOf(Request), @alignOf(IntuiText));
    const buttons_at = ub.AlignUp(lines_at + line_count * @sizeOf(IntuiText), @alignOf(?*Object));
    const text_at = buttons_at + button_count * @sizeOf(?*Object);
    const size = text_at + body.chars + 1 + labels.chars + 1;
    const memory = sys.AllocVec(size, exec.MEMF_CLEAR) orelse return failed(ib);
    const block: [*]u8 = @ptrCast(memory);
    const request: *Request = @ptrCast(@alignCast(block));
    request.* = .{
        .size = size,
        .lines = @ptrCast(@alignCast(block + lines_at)),
        .line_count = line_count,
        .buttons = @ptrCast(@alignCast(block + buttons_at)),
        .button_count = button_count,
        .text = block + text_at,
    };

    // The words themselves, the message's and then the buttons'.
    var out = Write{ .at = request.text };
    const after_text = sys.RawDoFmt(easy_struct.text_format, args, &write, &out);
    const label_text: [*]u8 = out.at;
    _ = sys.RawDoFmt(easy_struct.gadget_format, after_text, &write, &out);

    const screen: *Screen = if (window) |w| w.screen else @ptrCast(@alignCast(it.LockPubScreen(null) orelse {
        sys.FreeVec(memory);
        return failed(ib);
    }));
    // Held until the window is open on it, which keeps it open after.
    defer if (window == null) it.UnlockPubScreen(null, @ptrCast(screen));

    const font = fontOf(ib, screen);
    const pitch: i32 = font.height + (font.height - font.baseline);

    // The message, a run a line.
    var text_width: i32 = 0;
    {
        var line: u32 = 0;
        var begin: usize = 0;
        var at: usize = 0;
        const end = @intFromPtr(label_text) - @intFromPtr(request.text) - 1;
        while (at <= end) : (at += 1) {
            const c = request.text[at];
            if (c != '\n' and c != 0) continue;
            request.text[at] = 0;
            request.lines[line] = .{
                .front_pen = screen.pens[sc.TEXTPEN],
                .draw_mode = graphics.DRMD_JAM1,
                .top = @as(i32, @intCast(line)) * pitch,
                .font = screen.font,
                .text = @ptrCast(request.text + begin),
                .next = if (line + 1 < line_count) &request.lines[line + 1] else null,
            };
            text_width = @max(text_width, it.IntuiTextLength(&request.lines[line]));
            line += 1;
            begin = at + 1;
        }
    }
    const text_height: i32 = @as(i32, @intCast(line_count - 1)) * pitch + font.height;
    splitLabels(label_text, button_count);

    // The frame the message sits in, and the one each button wears, give
    // the room they need round what is in them.
    const frame = it.NewObjectTagList(null, classusr.FRAMEICLASS, &[_]TagItem{
        .{ .tag = ic.IA_Recessed, .data = 1 },
        .{},
    }) orelse return failRequest(ib, request);
    defer it.DisposeObject(frame);
    const button_frame = it.NewObjectTagList(null, classusr.FRAMEICLASS, &[_]TagItem{
        .{ .tag = ic.IA_FrameType, .data = ic.FRAME_BUTTON },
        .{},
    }) orelse return failRequest(ib, request);
    defer it.DisposeObject(button_frame);
    const framed = frameAround(ib, frame, screen, text_width + 2 * text_inset_x, text_height + 2 * text_inset_y);
    const button_pad = frameAround(ib, button_frame, screen, 0, 0);

    // A button is its label with its frame's room and a little more.
    const button_extra = button_pad.width + @max(font.width, 20);
    const button_height = font.height + button_pad.height + (font.height - font.baseline);
    var buttons_width: i32 = (@as(i32, @intCast(button_count)) - 1) * button_gap;
    {
        var label = label_text;
        for (0..button_count) |_| {
            buttons_width += labelWidth(ib, screen, label) + button_extra;
            label = nextLabel(label);
        }
    }

    const title: ?[*:0]const u8 = easy_struct.title orelse if (window) |w| w.title else "System Request";
    var frame_width = @max(buttons_width, framed.width + 2 * text_margin);
    frame_width = @max(frame_width, @min(
        _window.depth_width + titleWidth(ib, screen, title),
        screen.width - 2 * _window.side_border - 2 * margin,
    ));
    const inner_width = frame_width + 2 * margin;
    const inner_height = margin + framed.height + margin + button_height + margin;

    const opened = it.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_CustomScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_InnerWidth, .data = @intCast(inner_width) },
        .{ .tag = wn.WA_InnerHeight, .data = @intCast(inner_height) },
        .{ .tag = wn.WA_Title, .data = @intFromPtr(title) },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_RMBTrap, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = idcmp | wn.IDCMP_GADGETUP | wn.IDCMP_VANILLAKEY },
        .{},
    }) orelse return failRequest(ib, request);
    const w: *Window = @ptrCast(@alignCast(opened));

    // The ground, the frame and the message, drawn once. The origin is the
    // interior's corner in the RastPort the program would draw in.
    {
        const rp = _window.innerRastPort(w);
        const layer = _window.innerLayer(w);
        const origin = _window.innerOrigin(w);
        const x0 = w.border_left - origin.x;
        const y0 = w.border_top - origin.y;
        ib.layers_base.LockLayer(layer);
        defer ib.layers_base.UnlockLayer(layer);
        // Without the ground the requester still works: it goes unfilled.
        if (it.NewObjectTagList(null, classusr.FILLRECTCLASS, &[_]TagItem{
            .{ .tag = ic.IA_Width, .data = @intCast(inner_width) },
            .{ .tag = ic.IA_Height, .data = @intCast(inner_height) },
            .{ .tag = ic.IA_FGPen, .data = screen.pens[sc.SHINEPEN] },
            .{ .tag = ic.IA_BGPen, .data = screen.pens[sc.BACKGROUNDPEN] },
            .{ .tag = ic.IA_APattern, .data = @intFromPtr(&ground_tile) },
            .{ .tag = ic.IA_APatSize, .data = 1 },
            .{ .tag = ic.IA_Mode, .data = graphics.DRMD_JAM2 },
            .{},
        })) |ground| {
            it.DrawImage(rp, ground, x0, y0);
            it.DisposeObject(ground);
        }
        var draw = ic.ImpDraw{
            .method_id = ic.IM_DRAWFRAME,
            .rast_port = rp,
            .offset = .{ .x = x0 + margin, .y = y0 + margin },
            .state = ic.IDS_NORMAL,
            .draw_info = &screen.draw_info,
            .dimensions = .{ .width = frame_width, .height = framed.height },
        };
        _ = it.SendMessage(frame, @ptrCast(&draw));
        it.PrintIText(
            rp,
            &request.lines[0],
            x0 + margin + @divTrunc(frame_width - text_width, 2),
            y0 + margin + @divTrunc(framed.height - text_height, 2),
        );
    }

    // The buttons, in a row under the frame, spread to its width.
    var left: i32 = margin;
    const top: i32 = margin + framed.height + margin;
    var spread_error: i32 = @as(i32, @intCast(button_count)) - 2;
    const spare = frame_width - buttons_width;
    var label = label_text;
    var previous: ?*Object = null;
    for (0..button_count) |k| {
        const width = labelWidth(ib, screen, label) + button_extra;
        const at = if (button_count == 1) margin + @divTrunc(frame_width - width, 2) else left;
        const id: usize = if (k + 1 == button_count) 0 else k + 1;
        const button = it.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
            .{ .tag = gc.GA_Left, .data = @intCast(w.border_left + at) },
            .{ .tag = gc.GA_Top, .data = @intCast(w.border_top + top) },
            .{ .tag = gc.GA_Width, .data = @intCast(width) },
            .{ .tag = gc.GA_Height, .data = @intCast(button_height) },
            .{ .tag = gc.GA_Text, .data = @intFromPtr(label) },
            .{ .tag = gc.GA_RelVerify, .data = 1 },
            .{ .tag = gc.GA_ID, .data = id },
            .{ .tag = gc.GA_Previous, .data = @intFromPtr(previous) },
            .{},
        }) orelse {
            it.CloseWindow(opened);
            return failRequest(ib, request);
        };
        request.buttons[k] = button;
        previous = button;
        // A single button is centred and there is no gap to spread over.
        if (button_count > 1) left += width + button_gap + divvyUp(@as(i32, @intCast(button_count)) - 1, spare, &spread_error);
        label = nextLabel(label);
    }
    const first = request.buttons[0].?;
    _ = it.AddGList(opened, first, -1, -1);
    it.RefreshGList(first, opened, -1);
    w.request = request;
    return w;
}

/// Counts what RawDoFmt puts out, and the separators among it.
const Measure = struct {
    separator: u8,
    chars: usize = 0,
    separators: u32 = 0,
};

fn measure(c: u8, data: ?*anyopaque) callconv(.c) void {
    const m: *Measure = @ptrCast(@alignCast(data.?));
    if (c == 0) return; // the final NUL
    m.chars += 1;
    if (c == m.separator) m.separators += 1;
}

/// Where RawDoFmt's next character goes, its final NUL included.
const Write = struct { at: [*]u8 };

fn write(c: u8, data: ?*anyopaque) callconv(.c) void {
    const out: *Write = @ptrCast(@alignCast(data.?));
    out.at[0] = c;
    out.at += 1;
}

/// The buttons' words as C strings one after the other: each `|` a NUL.
fn splitLabels(text: [*]u8, count: u32) void {
    var at: usize = 0;
    var left = count;
    while (left > 0) : (at += 1) {
        if (text[at] == '|') text[at] = 0;
        if (text[at] == 0) left -= 1;
    }
}

fn nextLabel(label: [*]u8) [*]u8 {
    var at: usize = 0;
    while (label[at] != 0) at += 1;
    return label + at + 1;
}

const Font = struct { height: i32, baseline: i32, width: i32 };

/// The screen's font, from its RastPort, which is set to it.
fn fontOf(ib: *IntuitionBase, screen: *Screen) Font {
    var height: u32 = 0;
    var baseline: u32 = 0;
    var width: u32 = 0;
    ib.graphics_base.GetRPAttrs(screen.rp, &[_]TagItem{
        .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&height) },
        .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
        .{ .tag = graphics.RPTAG_FontWidth, .data = @intFromPtr(&width) },
        .{},
    });
    return .{ .height = @intCast(height), .baseline = @intCast(baseline), .width = @intCast(width) };
}

fn labelWidth(ib: *IntuitionBase, screen: *Screen, label: [*]u8) i32 {
    const run = IntuiText{ .font = screen.font, .text = @ptrCast(label) };
    return ib.iface().IntuiTextLength(&run);
}

/// The title's width without the spaces it ends in.
fn titleWidth(ib: *IntuitionBase, screen: *Screen, title: ?[*:0]const u8) i32 {
    const t = title orelse return 0;
    var n: u32 = 0;
    while (t[n] != 0) n += 1;
    while (n > 0 and t[n - 1] == ' ') n -= 1;
    if (n == 0) return 0;
    return ib.graphics_base.TextLength(screen.rp, t, n);
}

/// How big `frame` has to be round a box of this size.
fn frameAround(ib: *IntuitionBase, frame: *Object, screen: *Screen, width: i32, height: i32) ic.Box {
    const contents = ic.Box{ .width = width, .height = height };
    var answer = ic.Box{};
    var msg = ic.ImpFrameBox{ .contents = &contents, .frame = &answer, .draw_info = &screen.draw_info };
    _ = ib.iface().SendMessage(frame, @ptrCast(&msg));
    return answer;
}

/// Spread `balls` pixels over `bins` gaps as evenly as whole pixels go: how
/// many this gap gets, with `error` carried from one gap to the next.
fn divvyUp(bins: i32, balls: i32, error_term: *i32) i32 {
    var count: i32 = 0;
    while (error_term.* < balls) {
        error_term.* += bins;
        count += 1;
    }
    error_term.* -= balls;
    return count;
}

/// A process says in its IoErr why a requester is not there.
fn processFail(ib: *IntuitionBase, fail: bool) void {
    const task = ib.sys_base.FindTask(null) orelse return;
    if (task.node.type != .process) return;
    const process: *sdk.dos.dosextens.Process = @fieldParentPtr("task", task);
    process.result2 = if (fail) sdk.dos.ERROR_NO_FREE_STORE else 0;
}

fn failed(ib: *IntuitionBase) ?*Window {
    processFail(ib, true);
    return null;
}

fn failRequest(ib: *IntuitionBase, request: *Request) ?*Window {
    _request.free(ib, request);
    return failed(ib);
}
