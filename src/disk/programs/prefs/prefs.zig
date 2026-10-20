// SPDX-License-Identifier: MIT
//! Prefs: the system's settings in one window - the style every gadget,
//! window and menu is drawn in, the system's fonts, and intuition's own
//! settings, the colours of the screens, and the sound - changed, and
//! saved. Built against the SDK only.
//!
//!   SYS:Programs/Prefs
//!
//! Seven pages under tabs:
//!
//! - **Style**: the looks there are to pick from - a style file each in
//!   SYS:Prefs/Presets/Styles, its first comment saying what it is - and a
//!   few gadgets drawn in the one picked. Picking one makes it the style
//!   being edited, which the other pages may then change.
//! - **Advanced**: a part and a state chosen at the top, and that part's look
//!   in that state below - its border and the way a bevel's corners meet,
//!   its colours, its border's thickness, its
//!   corners' radius, its padding, a ridge's gap, its opacity and the
//!   milliseconds a change into the state takes. A field left empty is the
//!   system's default. A value that means nothing is refused, and the line
//!   at the bottom says why. The gadgets beside are drawn in the style as
//!   it is being edited. Beside each colour a chooser picks the default,
//!   one of the screen's pens, or a colour of its own on a colour wheel;
//!   the field beside it takes the same typed - a pen's name, `#RRGGBB`,
//!   `#AARRGGBB`, or for the background two colours `#top..#bottom`.
//! - **Colours**: the system's twelve pens, which every screen without
//!   pens of its own draws in - each typed as `#RRGGBB` or picked on the
//!   colour wheel, its button showing it - and a button for the built-in
//!   ones.
//! - **Fonts**: the screens', the windows', the consoles' and the
//!   desktop icons' fonts.
//! - **Desktop**: the desktop's ground - a colour, or two shaded from top
//!   to bottom, typed or picked on the colour wheel - a picture over it
//!   and how it is placed, how large icons are shown, whether an icon
//!   that is moved snaps to the grid, and how a drawer with no view of
//!   its own is shown.
//! - **System**: the double-click time, the height of a screen's font when
//!   it is given none, when the keyboard on the screen comes up, whether
//!   a window may be moved partly past the screen's edges, and whether the
//!   gadgets in the title bars are wide.
//! - **Sound**: the output preferred - played through whenever it is
//!   there, headphones that are plugged in taking the sound over - and
//!   how loud each output plays, those on the machine now and those the
//!   settings remember, which are marked as not there; both are heard at
//!   once, and Cancel puts them back. And the beep: whether the display
//!   flashes, and what is heard - nothing, a tone of a pitch, a loudness
//!   and a length, or a sound file - with a button that plays it as the
//!   page has it.
//!
//! **Save** writes the files to ENV:Sys and ENVARC:Sys, **Use** to
//! ENV:Sys alone - in force until the machine starts again - and both then
//! hand them to the system as S:Startup-Sequence does at boot, running
//! C:SetPrefs: every window open takes the
//! style, the colours and the title bars' gadgets at once; fonts are taken
//! by what opens from then on. The colours' file is written only when a colour was changed. **Cancel**
//! leaves everything as it was. The files' forms are `sdk.prefs`'s, and
//! the style file keeps its explanation and the default written out.
//!
//! The colour wheel is a window of its own, over the editor: the wheel and
//! its brightness beside it, the colour shown on a button and typed in a
//! field, and OK and Cancel. Until it is closed the editor takes no input.
//!
//! Lines of the style file that name several states at once, which the
//! page does not choose, are kept as they were read and written back.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const prefs = sdk.prefs;
const style_file = prefs.style;
const font_file = prefs.font;
const intuition_file = prefs.intuition;
const palette_file = prefs.palette;
const anvil_file = prefs.anvil;
const sound_file = prefs.sound;
const audio_file = prefs.audio;
const audio = sdk.devices.audio;
const audiocontrol = sdk.devices.audiocontrol;
const datatypes = sdk.datatypes;
const dtc = datatypes.datatypesclass;
const sdt = datatypes.soundclass;
const DataTypesBase = sdk.interface.datatypes.DataTypesBase;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const ColorWheelBase = sdk.interface.colorwheel.ColorWheelBase;
const Object = intuition.Object;
const TagItem = utility.TagItem;
const Printf = dos.stdio.Printf;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wn = intuition.windows;
const wc = intuition.windowclass;
const icc = intuition.icclass;
const classusr = intuition.classusr;
const ct = sdk.gadgets.clicktab;
const pgc = sdk.gadgets.page;
const ch = sdk.gadgets.chooser;
const st = sdk.gadgets.string;
const ig = sdk.gadgets.integer;
const tx = sdk.gadgets.text;
const gfo = sdk.gadgets.getfont;
const gf = sdk.gadgets.getfile;
const cb = sdk.gadgets.checkbox;
const sl = sdk.gadgets.slider;
const lv = sdk.gadgets.listview;
const cw = sdk.gadgets.colorwheel;
const gs = sdk.gadgets.gradientslider;
const pg = intuition.propgclass;
const sc = intuition.screens;
const looks = intuition.style;
const Pen = graphics.Pen;

pub const COMMAND_NAME = "Prefs";
const VERSION = "1.10";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (20.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
/// What the screen's bar says while one of its windows is active.
const SCREEN_TITLE = COMMAND_NAME ++ " " ++ VERSION;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOMEMORY = "No memory for the settings\n";
const MSG_NOWINDOW = "No window\n";
const MSG_NOTSAVED = "%s could not be written\n";

// --- the gadgets' IDs ----------------------------------------------------------------

const ID_TABS = 1;
const ID_PART = 2;
const ID_STATE = 3;
const ID_BORDER = 4;
const ID_JOINS = 5;
/// A style field's ID: this and its key's number.
const ID_FIELD = 16;
const ID_SAVE = 40;
const ID_USE = 41;
const ID_CANCEL = 42;
/// A font field's ID: this and which.
const ID_FONT = 48;
const ID_DOUBLE = 56;
const ID_HEIGHT = 57;
const ID_KEYBOARD = 58;
const ID_PRESET = 59;
const ID_BUILTIN = 60;
const ID_OFFSCREEN = 61;
const ID_WIDE = 62;
/// A colour field's chooser's ID: this and its key's number.
const ID_PEN_CHOICE = 64;
/// A system pen's field's ID, and its button's: these and the pen.
const ID_PEN_FIELD = 96;
const ID_PEN_PICK = 112;
/// The desktop page's.
const ID_GROUND = 128;
const ID_GROUND_PICK = 129;
/// The sound page's: the preferred output, an output's volume (this and
/// its row), the beep's.
const ID_PREFER = 130;
const ID_OUT_VOLUME = 136;
const ID_BEEP_SOUND = 145;
const ID_TEST = 150;

/// The colour wheel's window's gadgets.
const ID_WHEEL = 1;
const ID_BRIGHTNESS = 2;
const ID_HEX = 3;
const ID_OK = 4;
const ID_NOT = 5;

// --- the style's model -----------------------------------------------------------------

/// The most lines the style file may have.
const max_lines = 96;
/// The most of a file read.
const max_file = 16384;

/// The style as the file has it: its lines, which the page edits.
const Model = struct {
    lines: [max_lines]style_file.Line = undefined,
    count: usize = 0,
    /// Lines the file had that could not be read.
    skipped: u32 = 0,

    fn load(m: *Model, text: []const u8) void {
        var lines = prefs.Lines{ .text = text };
        while (lines.next()) |l| {
            if (!style_file.hasWords(l.text)) continue;
            if (m.count == max_lines) break;
            if (style_file.parse(l.text, &m.lines[m.count]) == null) m.count += 1 else m.skipped += 1;
        }
    }

    /// The line for one part in one state alone, if the file has one.
    fn find(m: *Model, part: []const u8, state: []const u8) ?*style_file.Line {
        for (m.lines[0..m.count]) |*line| {
            const p = line.get(.part) orelse continue;
            if (!style_file.same(p, part)) continue;
            const s = line.get(.state) orelse "NORMAL";
            if (style_file.same(s, state)) return line;
        }
        return null;
    }

    /// That line, made when there is none; null when there is no room.
    fn need(m: *Model, part: []const u8, state: []const u8) ?*style_file.Line {
        if (m.find(part, state)) |line| return line;
        if (m.count == max_lines) return null;
        const line = &m.lines[m.count];
        line.* = .{};
        _ = line.set(.part, part);
        if (!style_file.same(state, "NORMAL")) _ = line.set(.state, state);
        m.count += 1;
        return line;
    }

    /// The whole style as tags, into `tags`, shaded backgrounds' fills
    /// into `fills`: standing alone on the default, as the file does once
    /// it is the system's style - not on whatever style is in force now.
    fn toTags(m: *const Model, tags: []TagItem, fills: []graphics.FillStyle) void {
        tags[0] = .{ .tag = looks.STYLE_Alone, .data = 1 };
        var n: usize = 1;
        var f: usize = 0;
        for (m.lines[0..m.count]) |*line| {
            if (line.empty()) continue;
            n += style_file.toTags(line, tags[n .. n + style_file.tags_per_line], &fills[f]);
            if (style_file.shaded(line)) f += 1;
        }
        tags[n] = .{};
    }

    /// The file as it is written: the explanation, then a line for each
    /// part and state that says something. Its length.
    fn write(m: *const Model, into: []u8) usize {
        var n = style_file.header.len;
        @memcpy(into[0..n], style_file.header);
        for (m.lines[0..m.count]) |*line| {
            if (line.empty()) continue;
            if (n + style_file.max_line + 1 > into.len) break;
            n += style_file.write(line, into[n..]);
            into[n] = '\n';
            n += 1;
        }
        return n;
    }
};

// --- the choices' labels -------------------------------------------------------------

const part_labels = labels: {
    var made: [style_file.parts.len:null]?[*:0]const u8 = undefined;
    for (style_file.parts, 0..) |p, i| made[i] = @ptrCast(p.name.ptr);
    break :labels made;
};
const state_labels = labels: {
    var made: [style_file.states.len:null]?[*:0]const u8 = undefined;
    for (style_file.states, 0..) |s, i| made[i] = @ptrCast(s.name.ptr);
    break :labels made;
};
/// The first of each is "the default": the key left out.
const border_labels = [_:null]?[*:0]const u8{ "Default", "None", "Flat", "Raised", "Recessed", "Ridge", "Groove" };
const joins_labels = [_:null]?[*:0]const u8{ "Default", "None", "Angled" };
const keyboard_labels = [_:null]?[*:0]const u8{ "When the board has none", "Always", "Never" };
const place_labels = [_:null]?[*:0]const u8{ "Tiled", "Centred", "Scaled to cover" };
const view_labels = [_:null]?[*:0]const u8{ "Icons", "Names", "Dates", "Sizes" };
const tab_names = [_:null]?[*:0]const u8{ "Style", "Advanced", "Colours", "Fonts", "Desktop", "System", "Sound" };
const page_style = 0;
const page_advanced = 1;
const page_colours = 2;
const page_fonts = 3;
const page_desktop = 4;
const page_system = 5;
const page_sound = 6;
/// What a beep sounds like, in `sound_file.SOUND_`'s order.
const beep_sound_labels = [_:null]?[*:0]const u8{ "Nothing", "A tone", "A sound file" };

/// The most outputs the sound page shows a volume for.
const max_rows = 6;

/// The screen pens' names as the pages show them, in the pens' order.
const pen_labels = [sc.NUMDRIPENS]?[*:0]const u8{
    "Detail",    "Block",      "Text",           "Shine",      "Shadow",    "Fill",
    "Fill text", "Background", "Highlight text", "Bar detail", "Bar block", "Bar trim",
};
/// A colour field's chooser: the default, a pen, or a colour of its own.
const pen_choice_labels = labels: {
    var made: [sc.NUMDRIPENS + 2:null]?[*:0]const u8 = undefined;
    made[0] = "Default";
    for (pen_labels, 0..) |label, i| made[i + 1] = label;
    made[sc.NUMDRIPENS + 1] = "Own colour...";
    break :labels made;
};
const pen_choice_own = sc.NUMDRIPENS + 1;

/// Where the looks to pick from are.
const presets_dir = "SYS:Prefs/Presets/Styles";
const presets_suffix = ".prefs";
/// The most looks listed.
const max_presets = 32;

/// A look to pick, on the list the list view shows.
const Preset = struct {
    node: exec.Node = .{},
    name: [32:0]u8 = @splat(0),
};
const tab_to_page = [_]TagItem{
    .{ .tag = ct.CLICKTAB_Current, .data = pgc.PAGE_Current },
    .{ .tag = gc.GA_ID, .data = utility.TAG_IGNORE },
    .{},
};

/// The style's fields: a key each, its label, and its group.
const Field = struct { key: style_file.Key, label: [*:0]const u8 };
const colour_fields = [_]Field{
    .{ .key = .background, .label = "Background" },
    .{ .key = .border_colour, .label = "Border colour" },
    .{ .key = .shine, .label = "Shine" },
    .{ .key = .shadow, .label = "Shadow" },
    .{ .key = .text, .label = "Text" },
};
const shape_fields = [_]Field{
    .{ .key = .border_x, .label = "Border across" },
    .{ .key = .border_y, .label = "Border down" },
    .{ .key = .radius, .label = "Radius" },
    .{ .key = .padding_x, .label = "Padding across" },
    .{ .key = .padding_y, .label = "Padding down" },
    .{ .key = .gap, .label = "Ridge gap" },
    .{ .key = .opacity, .label = "Opacity" },
    .{ .key = .transition, .label = "Transition ms" },
};

/// Everything the window holds that the program reads or sets.
const Editor = struct {
    ib: *IntuitionBase,
    dl: *DosBase,
    sys: *ExecBase,
    model: Model = .{},
    part: usize = 0,
    state: usize = 0,
    part_chooser: *Object = undefined,
    state_chooser: *Object = undefined,
    border: *Object = undefined,
    joins: *Object = undefined,
    fields: [style_file.key_count]?*Object = @splat(null),
    /// Beside each colour field, its chooser.
    pen_choosers: [style_file.key_count]?*Object = @splat(null),
    status: *Object = undefined,
    /// The gadgets drawn in the style being edited: four on each of the
    /// two style pages.
    preview: [8]*Object = undefined,
    /// The looks to pick from, and what the one picked is.
    presets: exec.List = .{},
    preset_nodes: [max_presets]Preset = @splat(.{}),
    preset_count: usize = 0,
    preset_list: *Object = undefined,
    about: *Object = undefined,
    about_text: [120:0]u8 = @splat(0),
    fonts: [font_file.which_names.len]*Object = undefined,
    double: *Object = undefined,
    height: *Object = undefined,
    keyboard: *Object = undefined,
    off_screen: *Object = undefined,
    wide_gadgets: *Object = undefined,
    /// The system's pens as the colours page has them, and whether one
    /// was changed.
    pens: [sc.NUMDRIPENS]Pen = palette_file.defaults,
    pens_changed: bool = false,
    pen_fields: [sc.NUMDRIPENS]*Object = undefined,
    /// The buttons that open the colour wheel, each in its pen's colour.
    pen_buttons: [sc.NUMDRIPENS]*Object = undefined,
    pen_looks: [sc.NUMDRIPENS][4]TagItem = undefined,
    window: ?*intuition.Window = null,
    object: *Object = undefined,
    tabs: *Object = undefined,
    wheel_base: *ColorWheelBase = undefined,
    /// The fonts as the file had them, and whether each was picked anew.
    font_line: font_file.Line = .{},
    font_picked: [font_file.which_names.len]bool = @splat(false),
    /// The desktop's settings as the file had them, the ground as the
    /// page has it, and the page's gadgets.
    desktop: anvil_file.Settings = .{},
    ground_field: *Object = undefined,
    ground_button: *Object = undefined,
    ground_looks: [4]TagItem = undefined,
    picture: *Object = undefined,
    place: *Object = undefined,
    icon_size: *Object = undefined,
    snap: *Object = undefined,
    view: *Object = undefined,
    /// The sound page: audio.device, when the machine has one; the
    /// outputs as the page has them, and as they were when it opened, for
    /// Cancel; a row each for up to `max_rows` of them - those on the
    /// machine first - with its label and its slider.
    control: ?audiocontrol.Control = null,
    audio: audio_file.Settings = .{},
    audio_before: audio_file.Settings = .{},
    rows: [max_rows]usize = undefined,
    row_count: usize = 0,
    row_labels: [max_rows][audio.AUDIO_NAME_LEN + 16:0]u8 = @splat(@splat(0)),
    volume_sliders: [max_rows]*Object = undefined,
    /// The preferred output's chooser: "the first there is", then the
    /// rows' outputs.
    prefer: *Object = undefined,
    prefer_labels: [max_rows + 1:null]?[*:0]const u8 = @splat(null),
    /// The beep as the file had it, and the page's gadgets for it.
    beep: sound_file.Settings = .{},
    flash: *Object = undefined,
    beep_sound: *Object = undefined,
    beep_volume: *Object = undefined,
    tone: *Object = undefined,
    duration: *Object = undefined,
    sample: *Object = undefined,
    sound_status: *Object = undefined,
    sound_status_text: [80:0]u8 = @splat(0),
    /// What Test plays: a tone on a request of its own, sent, and its
    /// samples; or a sound file's object. datatypes.library once a file
    /// was played.
    test_io: ?*audio.IOAudio = null,
    test_sent: bool = false,
    test_samples: ?*anyopaque = null,
    test_object: ?*Object = null,
    dt_lib: ?*exec.Library = null,
    /// The tags the preview is drawn with, and the fills they point to.
    tags: [max_lines * style_file.tags_per_line + 2]TagItem = undefined,
    fills: [max_lines]graphics.FillStyle = undefined,
    status_text: [80:0]u8 = @splat(0),

    /// The looks in the directory, sorted by name, onto `presets`.
    fn readPresets(e: *Editor) void {
        e.presets.init(.unknown);
        const dl = e.dl;
        const lock = dl.Lock(presets_dir, dos.SHARED_LOCK) orelse return;
        defer dl.UnLock(lock);
        var fib: dos.FileInfoBlock = .{};
        if (!dl.Examine(lock, &fib)) return;
        while (dl.ExNext(lock, &fib)) {
            if (dos.isDirectory(fib.dir_entry_type) or e.preset_count == max_presets) continue;
            var len: usize = 0;
            while (fib.file_name[len] != 0) len += 1;
            if (len <= presets_suffix.len) continue;
            const stem = len - presets_suffix.len;
            if (!style_file.same(fib.file_name[stem..len], ".PREFS")) continue;
            const preset = &e.preset_nodes[e.preset_count];
            const n = @min(stem, preset.name.len);
            @memcpy(preset.name[0..n], fib.file_name[0..n]);
            preset.name[n] = 0;
            e.preset_count += 1;
        }
        // In order of their names.
        const all = e.preset_nodes[0..e.preset_count];
        var i: usize = 1;
        while (i < all.len) : (i += 1) {
            var j = i;
            while (j > 0 and sortsBefore(&all[j].name, &all[j - 1].name)) : (j -= 1) {
                const swap = all[j];
                all[j] = all[j - 1];
                all[j - 1] = swap;
            }
        }
        for (all) |*preset| {
            preset.node.name = @ptrCast(&preset.name);
            e.sys.AddTail(&e.presets, &preset.node);
        }
    }

    /// The look `index` made the style being edited, and said what it is.
    fn pickPreset(e: *Editor, index: usize) void {
        if (index >= e.preset_count) return;
        var path: [96:0]u8 = @splat(0);
        var n: usize = 0;
        for ([_][]const u8{ presets_dir, "/", std_span(&e.preset_nodes[index].name), presets_suffix }) |piece| {
            @memcpy(path[n..][0..piece.len], piece);
            n += piece.len;
        }
        const memory = e.sys.AllocVec(max_file, exec.MEMF_ANY) orelse return;
        defer e.sys.FreeVec(memory);
        const buffer: [*]u8 = @ptrCast(memory);
        const text = prefs.load(e.dl, &path, buffer[0..max_file]) orelse {
            e.say("The look could not be read");
            return;
        };
        e.model = .{};
        e.model.load(text);
        // What it is: its first comment.
        var said: []const u8 = "";
        var lines = prefs.Lines{ .text = text };
        while (lines.next()) |l| {
            if (l.text.len > 2 and l.text[0] == '#') {
                said = l.text[2..];
                break;
            }
        }
        const k = @min(said.len, e.about_text.len);
        @memcpy(e.about_text[0..k], said[0..k]);
        e.about_text[k] = 0;
        e.set(page_style, e.about, &.{ .{ .tag = tx.TEXT_Text, .data = @intFromPtr(&e.about_text) }, .{} });
        e.showLine();
        e.showPreview();
    }

    /// A gadget on page `page` set: drawn at once when that page is the
    /// one shown, kept to be drawn when it is shown otherwise - a gadget
    /// of a page out of sight would draw over the page in sight.
    fn set(e: *Editor, page: usize, o: *Object, tags: []const TagItem) void {
        const w = e.window orelse {
            _ = e.ib.SetAttrsTagList(o, tags.ptr);
            return;
        };
        var shown: usize = 0;
        _ = e.ib.GetAttr(ct.CLICKTAB_Current, e.tabs, &shown);
        if (shown == page) {
            _ = e.ib.SetGadgetAttrsTagList(o, w, tags.ptr);
        } else _ = e.ib.SetAttrsTagList(o, tags.ptr);
    }

    fn say(e: *Editor, text: []const u8) void {
        const n = @min(text.len, e.status_text.len);
        @memcpy(e.status_text[0..n], text[0..n]);
        e.status_text[n] = 0;
        e.set(page_advanced, e.status, &.{ .{ .tag = tx.TEXT_Text, .data = @intFromPtr(&e.status_text) }, .{} });
    }

    fn partName(e: *const Editor) []const u8 {
        return style_file.parts[e.part].name;
    }

    fn stateName(e: *const Editor) []const u8 {
        return style_file.states[e.state].name;
    }

    /// The page's fields filled from the chosen part's line in the chosen
    /// state.
    fn showLine(e: *Editor) void {
        const line = e.model.find(e.partName(), e.stateName());
        for (e.fields, 0..) |field, k| {
            const o = field orelse continue;
            var text: [style_file.value_len + 1:0]u8 = @splat(0);
            const value = if (line) |l| l.get(@enumFromInt(k)) else null;
            if (value) |v| @memcpy(text[0..v.len], v);
            e.set(page_advanced, o, &.{ .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr(&text) }, .{} });
            e.showChoice(@enumFromInt(k), value);
        }
        const border = if (line) |l| l.get(.border) else null;
        const joins = if (line) |l| l.get(.joins) else null;
        e.set(page_advanced, e.border, &.{ .{ .tag = ch.CHOOSER_Active, .data = choiceOf(&style_file.borders, border) }, .{} });
        e.set(page_advanced, e.joins, &.{ .{ .tag = ch.CHOOSER_Active, .data = choiceOf(&style_file.joins, joins) }, .{} });
    }

    /// The preview drawn in the style as it is now.
    fn showPreview(e: *Editor) void {
        e.model.toTags(&e.tags, &e.fills);
        // The first four are on the advanced page, the rest on the style
        // page.
        for (e.preview, 0..) |o, i| e.set(if (i < 4) page_advanced else page_style, o, &.{ .{ .tag = gc.GA_Style, .data = @intFromPtr(&e.tags) }, .{} });
    }

    /// A field's new text taken, or refused with the reason.
    fn takeField(e: *Editor, key: style_file.Key) void {
        const o = e.fields[@intFromEnum(key)] orelse return;
        const text = e.fieldText(o);
        if (text.len > 0) {
            if (style_file.check(key, text)) |wrong| {
                var said: [80]u8 = undefined;
                const n = joinSaid(&said, style_file.key_names[@intFromEnum(key)], std_span(wrong));
                e.say(said[0..n]);
                e.showLine();
                return;
            }
        }
        const line = e.model.need(e.partName(), e.stateName()) orelse {
            e.say("No room for another line");
            return;
        };
        if (!line.set(key, text)) {
            e.say("Too long");
            e.showLine();
            return;
        }
        e.say("");
        e.showChoice(key, text);
        e.showPreview();
    }

    /// What a string gadget holds, without the blanks round it.
    fn fieldText(e: *Editor, o: *Object) []const u8 {
        var got: usize = 0;
        _ = e.ib.GetAttr(gc.STRINGA_TextVal, o, &got);
        const given: [*:0]const u8 = if (got != 0) @ptrFromInt(got) else "";
        var len: usize = 0;
        while (given[len] != 0) len += 1;
        var from: usize = 0;
        while (from < len and given[from] == ' ') from += 1;
        var to = len;
        while (to > from and given[to - 1] == ' ') to -= 1;
        return given[from..to];
    }

    /// A colour field's chooser set to what the field says.
    fn showChoice(e: *Editor, key: style_file.Key, value: ?[]const u8) void {
        const o = e.pen_choosers[@intFromEnum(key)] orelse return;
        const text = value orelse "";
        const choice: usize = if (text.len == 0)
            0
        else if (style_file.lookUp(&style_file.pens, text)) |pen| pen + 1 else pen_choice_own;
        e.set(page_advanced, o, &.{ .{ .tag = ch.CHOOSER_Active, .data = choice }, .{} });
    }

    /// A colour field's chooser's choice taken: the field emptied, a pen's
    /// name put in it, or a colour picked on the wheel.
    fn takePenChoice(e: *Editor, key: style_file.Key, choice: usize) void {
        const o = e.fields[@intFromEnum(key)] orelse return;
        var text: [style_file.value_len + 1:0]u8 = @splat(0);
        if (choice >= 1 and choice <= sc.NUMDRIPENS) {
            const name = style_file.pens[choice - 1].name;
            @memcpy(text[0..name.len], name);
        } else if (choice == pen_choice_own) {
            const picked = e.pickColour(e.colourOf(e.fieldText(o))) orelse {
                e.showLine();
                return;
            };
            _ = colourText(&text, picked);
        }
        e.set(page_advanced, o, &.{ .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr(&text) }, .{} });
        e.takeField(key);
    }

    /// The colour a field's text is, as near as one colour says it: a
    /// pen's own, the first of two, or the background's when it is none.
    fn colourOf(e: *const Editor, text: []const u8) Pen {
        if (style_file.lookUp(&style_file.pens, text)) |pen| return e.pens[pen];
        const first = if (text.len >= 7) text[0..7] else text;
        return style_file.rgb(text) orelse style_file.rgb(first) orelse e.pens[sc.BACKGROUNDPEN];
    }

    /// A system pen shown: its field, and its button in its colour.
    fn showPen(e: *Editor, pen: usize) void {
        var text: [8:0]u8 = @splat(0);
        _ = colourText(&text, e.pens[pen]);
        e.set(page_colours, e.pen_fields[pen], &.{ .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr(&text) }, .{} });
        e.pen_looks[pen] = buttonLooks(e.pens[pen]);
        e.set(page_colours, e.pen_buttons[pen], &.{ .{ .tag = gc.GA_Style, .data = @intFromPtr(&e.pen_looks[pen]) }, .{} });
    }

    /// A system pen's field taken; what is not `#RRGGBB` is put back.
    fn takePen(e: *Editor, pen: usize) void {
        const text = e.fieldText(e.pen_fields[pen]);
        if (text.len == 7) if (style_file.rgb(text)) |colour| {
            e.pens[pen] = colour;
            e.pens_changed = true;
        };
        e.showPen(pen);
    }

    /// A system pen picked on the wheel.
    fn pickPen(e: *Editor, pen: usize) void {
        const picked = e.pickColour(e.pens[pen]) orelse return;
        e.pens[pen] = picked;
        e.pens_changed = true;
        e.showPen(pen);
    }

    /// The built-in pens back on the colours page.
    fn builtInPens(e: *Editor) void {
        e.pens = palette_file.defaults;
        e.pens_changed = true;
        for (0..sc.NUMDRIPENS) |pen| e.showPen(pen);
    }

    /// A colour picked on the colour wheel, in a window of its own over
    /// the editor, starting at `start`: null when it was called off.
    fn pickColour(e: *Editor, start: Pen) ?Pen {
        const ib = e.ib;
        const main = e.window orelse return null;
        var picker = Picker{ .colour = start | 0xFF00_0000, .wheel_base = e.wheel_base };
        const layout = picker.build(ib) orelse return null;
        const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
            pair(wn.WA_Title, @intFromPtr("A colour")),
            pair(wn.WA_ScreenTitle, @intFromPtr(SCREEN_TITLE)),
            pair(wn.WA_CloseGadget, 1),
            pair(wn.WA_DragBar, 1),
            pair(wn.WA_DepthGadget, 1),
            pair(wn.WA_Activate, 1),
            pair(wn.WA_Position, wn.WPOS_CENTERMOUSE),
            pair(wc.WINDOWA_Layout, @intFromPtr(layout)),
            .{},
        }) orelse {
            ib.DisposeObject(layout);
            return null;
        };
        defer ib.DisposeObject(object);
        var open = wc.WmOpen{};
        if (ib.SendMessage(object, @ptrCast(&open)) == 0) return null;
        var window_ptr: usize = 0;
        _ = ib.GetAttr(wc.WINDOWA_Window, object, &window_ptr);
        const window: *intuition.Window = @ptrFromInt(window_ptr);
        picker.window = window;
        ib.SetWindowPointerA(main, &[_]TagItem{ pair(wn.WA_BusyPointer, 1), .{} });
        defer {
            ib.SetWindowPointerA(main, null);
            e.drain();
        }

        var code: u32 = 0;
        var handle = wc.WmHandleInput{ .code = &code };
        while (true) {
            const got = ib.WaitIMsg(window, exec.SIGBREAKF_CTRL_C);
            if (got & exec.SIGBREAKF_CTRL_C != 0) return null;
            while (true) {
                const word = ib.SendMessage(object, @ptrCast(&handle));
                if (word == wc.WMHI_LASTMSG) break;
                switch (word & wc.WMHI_CLASSMASK) {
                    wc.WMHI_CLOSEWINDOW => return null,
                    wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
                        ID_OK => return picker.colour,
                        ID_NOT => return null,
                        ID_WHEEL, ID_BRIGHTNESS => picker.fromWheel(ib),
                        ID_HEX => picker.fromField(ib),
                        else => {},
                    },
                    else => {},
                }
            }
        }
    }

    /// What reached the editor's window while the wheel was up, let go.
    fn drain(e: *Editor) void {
        var code: u32 = 0;
        var handle = wc.WmHandleInput{ .code = &code };
        while (e.ib.SendMessage(e.object, @ptrCast(&handle)) != wc.WMHI_LASTMSG) {}
    }

    /// A chooser's choice taken: the default takes the key out.
    fn takeChoice(e: *Editor, key: style_file.Key, table: []const style_file.Name, choice: usize) void {
        const line = e.model.need(e.partName(), e.stateName()) orelse return;
        _ = line.set(key, if (choice == 0) "" else table[choice - 1].name);
        e.showPreview();
    }

    /// The fonts' line as it is to be written: each font as the file had
    /// it unless another was picked.
    fn fontLine(e: *Editor) font_file.Line {
        var line = e.font_line;
        for (e.fonts, 0..) |o, i| {
            if (!e.font_picked[i]) continue;
            var name: usize = 0;
            var size: usize = 0;
            _ = e.ib.GetAttr(gfo.GETFONT_Name, o, &name);
            _ = e.ib.GetAttr(gfo.GETFONT_Size, o, &size);
            if (name == 0 or size == 0) continue;
            var text: [font_file.value_len]u8 = undefined;
            const n = fontText(&text, @ptrFromInt(name), @intCast(size));
            _ = line.set(@enumFromInt(i), text[0..n]);
        }
        return line;
    }

    /// intuition's settings as the page has them.
    fn systemPrefs(e: *Editor) intuition_file.Settings {
        var p: intuition_file.Settings = .{};
        var value: usize = 0;
        _ = e.ib.GetAttr(ig.INTEGER_Number, e.double, &value);
        p.double_click = @intCast(@max(@as(isize, @bitCast(value)), 1));
        _ = e.ib.GetAttr(ig.INTEGER_Number, e.height, &value);
        p.screen_font = @intCast(@max(@as(isize, @bitCast(value)), 1));
        _ = e.ib.GetAttr(ch.CHOOSER_Active, e.keyboard, &value);
        p.keyboard = @intCast(@min(value, 2));
        _ = e.ib.GetAttr(cb.CHECKBOX_Checked, e.off_screen, &value);
        p.off_screen = @intFromBool(value != 0);
        _ = e.ib.GetAttr(cb.CHECKBOX_Checked, e.wide_gadgets, &value);
        p.wide_gadgets = @intFromBool(value != 0);
        return p;
    }

    /// The colour the ground's button shows: its top, or the screen's
    /// background when the ground is left to it.
    fn groundColour(e: *const Editor) Pen {
        return if (e.desktop.ground_given) e.desktop.top else e.pens[sc.BACKGROUNDPEN];
    }

    /// The ground as typed: `#RRGGBB`, `#top..#bottom`, or nothing for
    /// the screen's background. Its length.
    fn groundText(e: *const Editor, into: []u8) usize {
        if (!e.desktop.ground_given) return 0;
        var n = colourText(into, e.desktop.top);
        if (e.desktop.top != e.desktop.bottom) {
            @memcpy(into[n..][0..2], "..");
            n += 2;
            n += colourText(into[n..], e.desktop.bottom);
        }
        return n;
    }

    /// The ground shown: its field, and its button in its colour.
    fn showGround(e: *Editor) void {
        var text: [20:0]u8 = @splat(0);
        _ = e.groundText(&text);
        e.set(page_desktop, e.ground_field, &.{ .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr(&text) }, .{} });
        e.ground_looks = buttonLooks(e.groundColour());
        e.set(page_desktop, e.ground_button, &.{ .{ .tag = gc.GA_Style, .data = @intFromPtr(&e.ground_looks) }, .{} });
    }

    /// The ground's field taken: empty is the screen's background; what
    /// is neither a colour nor two is put back.
    fn takeGround(e: *Editor) void {
        const text = e.fieldText(e.ground_field);
        if (text.len == 0) {
            e.desktop.ground_given = false;
        } else if (anvil_file.groundOf(text)) |colours| {
            e.desktop.top = colours[0];
            e.desktop.bottom = colours[1];
            e.desktop.ground_given = true;
        }
        e.showGround();
    }

    /// The ground picked on the wheel: one colour.
    fn pickGround(e: *Editor) void {
        const picked = e.pickColour(e.groundColour()) orelse return;
        e.desktop.top = picked;
        e.desktop.bottom = picked;
        e.desktop.ground_given = true;
        e.showGround();
    }

    /// The desktop's settings as the page has them.
    fn desktopPrefs(e: *Editor) anvil_file.Settings {
        var p = e.desktop;
        var value: usize = 0;
        _ = e.ib.GetAttr(gf.GETFILE_FullFile, e.picture, &value);
        const name: []const u8 = if (value != 0) std_span(@ptrFromInt(value)) else "";
        if (!p.setPicture(name)) p.picture = e.desktop.picture;
        _ = e.ib.GetAttr(ch.CHOOSER_Active, e.place, &value);
        p.place = @enumFromInt(@min(value, anvil_file.place_names.len - 1));
        _ = e.ib.GetAttr(ig.INTEGER_Number, e.icon_size, &value);
        p.icon_size = @intCast(@min(@max(@as(isize, @bitCast(value)), anvil_file.icon_size_min), anvil_file.icon_size_max));
        _ = e.ib.GetAttr(cb.CHECKBOX_Checked, e.snap, &value);
        p.snap = value != 0;
        _ = e.ib.GetAttr(ch.CHOOSER_Active, e.view, &value);
        p.view = @enumFromInt(@min(value, anvil_file.view_names.len - 1));
        return p;
    }

    // --- the sound page ---------------------------------------------------

    /// The outputs: the settings file's, then audio.device's over them -
    /// what plays now; the rows, those on the machine first.
    fn readAudio(e: *Editor, text: []u8) void {
        if (prefs.load(e.dl, audio_file.ENV_FILE, text)) |read| _ = e.audio.load(read);
        const control = if (e.control) |*opened| opened else return;
        audio_file.gather(control, &e.audio);
        e.audio_before = e.audio;
        var outputs: audiocontrol.Outputs = .{};
        outputs.read(control);
        for (outputs.infos[0..outputs.count]) |*info| e.addRow(info.id, true);
        for (e.audio.outputs[0..e.audio.count]) |*output| {
            if (outputs.indexOf(output.id) == null) e.addRow(output.id, false);
        }
        e.prefer_labels[0] = "The first there is";
        for (0..e.row_count) |row_at| e.prefer_labels[row_at + 1] = &e.row_labels[row_at];
    }

    /// A row for the output of that number: its name, or its number, and
    /// whether it is there.
    fn addRow(e: *Editor, id: u32, here: bool) void {
        if (e.row_count == max_rows) return;
        const output = e.audio.find(id) orelse return;
        var at: usize = 0;
        for (e.audio.outputs[0..e.audio.count], 0..) |*each, place| {
            if (each.id == id) at = place;
        }
        const label = &e.row_labels[e.row_count];
        var n: usize = 0;
        const name = output.nameText();
        if (name.len != 0) {
            @memcpy(label[0..name.len], name);
            n = name.len;
        } else {
            audio_file.hexText(label[0..8], id);
            n = 8;
        }
        if (!here) {
            const gone = " (not here)";
            @memcpy(label[n..][0..gone.len], gone);
            n += gone.len;
        }
        label[n] = 0;
        e.rows[e.row_count] = at;
        e.row_count += 1;
    }

    /// The preferred output as the chooser's place: 0 for none.
    fn preferChoice(e: *Editor) usize {
        const preferred = e.audio.preferred() orelse return 0;
        for (e.rows[0..e.row_count], 0..) |at, row_at| {
            if (e.audio.outputs[at].id == preferred.id) return row_at + 1;
        }
        return 0;
    }

    /// The chooser's choice made the preferred output, heard at once.
    fn takePrefer(e: *Editor, choice: usize) void {
        const id: u32 = if (choice >= 1 and choice <= e.row_count) e.audio.outputs[e.rows[choice - 1]].id else 0;
        e.audio.prefer(id);
        if (e.control) |*control| _ = control.prefer(id);
    }

    /// A row's slider at `level`: its output's volume, heard at once.
    fn takeVolume(e: *Editor, row_at: usize, level: usize) void {
        if (row_at >= e.row_count) return;
        const output = &e.audio.outputs[e.rows[row_at]];
        output.volume = @intCast(@min(level, 100));
        if (e.control) |*control| control.setVolume(output.id, output.volume);
    }

    /// The volumes and the preferred output as they were when the window
    /// opened.
    fn restoreAudio(e: *Editor) void {
        if (e.control) |*control| audio_file.apply(control, &e.audio_before);
    }

    fn saySound(e: *Editor, text: []const u8) void {
        const n = @min(text.len, e.sound_status_text.len);
        @memcpy(e.sound_status_text[0..n], text[0..n]);
        e.sound_status_text[n] = 0;
        e.set(page_sound, e.sound_status, &.{ .{ .tag = tx.TEXT_Text, .data = @intFromPtr(&e.sound_status_text) }, .{} });
    }

    /// The beep as the page has it.
    fn beepPrefs(e: *Editor) sound_file.Settings {
        var p = e.beep;
        var value: usize = 0;
        _ = e.ib.GetAttr(cb.CHECKBOX_Checked, e.flash, &value);
        p.flash = @intFromBool(value != 0);
        _ = e.ib.GetAttr(ch.CHOOSER_Active, e.beep_sound, &value);
        p.sound = @intCast(@min(value, sound_file.SOUND_SAMPLE));
        _ = e.ib.GetAttr(sl.SLIDER_Level, e.beep_volume, &value);
        p.volume = @intCast(@min(@max(@as(isize, @bitCast(value)), 1), 100));
        _ = e.ib.GetAttr(ig.INTEGER_Number, e.tone, &value);
        p.tone = @intCast(@min(@max(@as(isize, @bitCast(value)), 100), 8000));
        _ = e.ib.GetAttr(ig.INTEGER_Number, e.duration, &value);
        p.duration = @intCast(@min(@max(@as(isize, @bitCast(value)), 10), 1000));
        _ = e.ib.GetAttr(gf.GETFILE_FullFile, e.sample, &value);
        const name: []const u8 = if (value != 0) std_span(@ptrFromInt(value)) else "";
        if (name.len <= sound_file.sample_len) {
            p.sample = @splat(0);
            @memcpy(p.sample[0..name.len], name);
        }
        return p;
    }

    /// The beep as the page has it played - not waited for: the tone as a
    /// trigger of audio.device's, a sound file through its sound
    /// datatype. The one before is stopped first.
    fn testBeep(e: *Editor) void {
        e.endTest();
        const settings = e.beepPrefs();
        switch (settings.sound) {
            sound_file.SOUND_BEEP => {
                const control = if (e.control) |*opened| opened else return e.saySound("This machine has no sound");
                const sys = e.sys;
                const io = e.test_io orelse made: {
                    const request = sys.CreateIORequest(control.port, @sizeOf(audio.IOAudio)) orelse return;
                    const fresh: *audio.IOAudio = @ptrCast(@alignCast(request));
                    fresh.* = control.io.*;
                    e.test_io = fresh;
                    break :made fresh;
                };
                const frames = sound_file.beepFrames(&settings);
                const memory = sys.AllocVec(frames * @sizeOf(i16), exec.MEMF_ANY) orelse return;
                e.test_samples = memory;
                const samples: [*]i16 = @ptrCast(@alignCast(memory));
                const beep = sound_file.makeBeep(&settings, samples[0..frames]);
                io.std.req.command = audio.AUDIOCMD_TRIGGER;
                io.std.req.flags = 0;
                io.std.data = memory;
                io.std.length = @as(usize, frames) * @sizeOf(i16);
                io.format = audio.AUDIO_S16;
                io.channels = 1;
                io.rate = beep.rate;
                io.volume = beep.volume;
                io.pan = 0;
                io.loops = 1;
                sys.SendIO(&io.std.req);
                e.test_sent = true;
                e.saySound("");
            },
            sound_file.SOUND_SAMPLE => {
                if (settings.sample[0] == 0) return e.saySound("Pick the sound file first");
                const lib = e.dt_lib orelse e.sys.OpenLibrary(datatypes.DATATYPESNAME, 0) orelse return e.saySound("No datatypes.library");
                e.dt_lib = lib;
                const dt: *DataTypesBase = @ptrCast(lib);
                const object = dt.NewDTObjectA(&settings.sample, &[_]TagItem{
                    pair(dtc.DTA_GroupID, datatypes.GID_SOUND),
                    pair(sdt.SDTA_Volume, sound_file.volumeOf(&settings)),
                    .{},
                }) orelse return e.saySound("The sound file cannot be read as a sound");
                e.test_object = object;
                var play = dtc.DtTrigger{ .function = dtc.STM_PLAY };
                _ = dt.DoDTMethodA(object, null, null, @ptrCast(&play));
                e.saySound("");
            },
            else => {},
        }
    }

    /// What Test played stopped and given back.
    fn endTest(e: *Editor) void {
        const sys = e.sys;
        if (e.test_sent) {
            const io = e.test_io.?;
            _ = sys.AbortIO(&io.std.req);
            _ = sys.WaitIO(&io.std.req);
            e.test_sent = false;
        }
        if (e.test_samples) |memory| sys.FreeVec(memory);
        e.test_samples = null;
        if (e.test_object) |object| {
            const dt: *DataTypesBase = @ptrCast(e.dt_lib.?);
            dt.DisposeDTObject(object);
        }
        e.test_object = null;
    }

    /// Everything the sound page holds given back: what Test plays, its
    /// request, datatypes.library, audio.device.
    fn closeSound(e: *Editor) void {
        e.endTest();
        if (e.test_io) |io| e.sys.DeleteIORequest(&io.std.req);
        e.test_io = null;
        if (e.dt_lib) |lib| e.sys.CloseLibrary(lib);
        e.dt_lib = null;
        if (e.control) |*control| control.close();
        e.control = null;
    }

    /// The files written to ENV:, and to ENVARC: too when kept, and
    /// handed to the system. Whether all were written.
    fn apply(e: *Editor, keep: bool) bool {
        const sys = e.sys;
        const room: usize = style_file.header.len + max_lines * (style_file.max_line + 1);
        const memory = sys.AllocVec(@intCast(room), exec.MEMF_ANY) orelse return false;
        defer sys.FreeVec(memory);
        const text: [*]u8 = @ptrCast(memory);
        var ok = true;

        const style_len = e.model.write(text[0..room]);
        ok = e.saveBoth(style_file.ENV_FILE, style_file.ENVARC_FILE, text[0..style_len], keep) and ok;

        var n = font_file.header.len;
        @memcpy(text[0..n], font_file.header);
        const fonts = e.fontLine();
        n += font_file.write(&fonts, text[n..room]);
        text[n] = '\n';
        n += 1;
        ok = e.saveBoth(font_file.ENV_FILE, font_file.ENVARC_FILE, text[0..n], keep) and ok;

        n = intuition_file.header.len;
        @memcpy(text[0..n], intuition_file.header);
        const system = e.systemPrefs();
        n += intuition_file.write(&system, text[n..room]);
        text[n] = '\n';
        n += 1;
        ok = e.saveBoth(intuition_file.ENV_FILE, intuition_file.ENVARC_FILE, text[0..n], keep) and ok;

        n = anvil_file.header.len;
        @memcpy(text[0..n], anvil_file.header);
        const desktop = e.desktopPrefs();
        n += anvil_file.write(&desktop, text[n..room]);
        text[n] = '\n';
        n += 1;
        ok = e.saveBoth(anvil_file.ENV_FILE, anvil_file.ENVARC_FILE, text[0..n], keep) and ok;

        n = sound_file.header.len;
        @memcpy(text[0..n], sound_file.header);
        const beep = e.beepPrefs();
        n += sound_file.write(&beep, text[n..room]);
        text[n] = '\n';
        n += 1;
        ok = e.saveBoth(sound_file.ENV_FILE, sound_file.ENVARC_FILE, text[0..n], keep) and ok;

        if (e.control != null) {
            n = audio_file.write(&e.audio, text[0..room]);
            ok = e.saveBoth(audio_file.ENV_FILE, audio_file.ENVARC_FILE, text[0..n], keep) and ok;
        }

        if (e.pens_changed) {
            n = palette_file.header.len;
            @memcpy(text[0..n], palette_file.header);
            n += palette_file.write(&e.pens, text[n..room]);
            text[n] = '\n';
            n += 1;
            ok = e.saveBoth(palette_file.ENV_FILE, palette_file.ENVARC_FILE, text[0..n], keep) and ok;
        }

        // Handed to the system as the boot does.
        _ = e.dl.SystemTagList("C:SetPrefs >NIL:", null);
        return ok;
    }

    fn saveBoth(e: *Editor, env: [*:0]const u8, envarc: [*:0]const u8, text: []const u8, keep: bool) bool {
        var ok = prefs.save(e.dl, env, text);
        if (!ok) _ = Printf(e.dl, MSG_NOTSAVED, .{env});
        if (keep) {
            if (!prefs.save(e.dl, envarc, text)) {
                _ = Printf(e.dl, MSG_NOTSAVED, .{envarc});
                ok = false;
            }
        }
        return ok;
    }
};

/// A table's entry for a value given as text, as a chooser's place: 0 for
/// the default, the entry's place after it otherwise.
fn choiceOf(table: []const style_file.Name, text: ?[]const u8) usize {
    const given = text orelse return 0;
    for (table, 0..) |entry, i| {
        if (style_file.same(given, entry.name)) return i + 1;
    }
    return 0;
}

/// The colour wheel's window: the wheel, its brightness, the colour on a
/// button and in a field, OK and Cancel.
const Picker = struct {
    colour: Pen,
    wheel_base: *ColorWheelBase,
    window: ?*intuition.Window = null,
    wheel: *Object = undefined,
    brightness: *Object = undefined,
    field: *Object = undefined,
    shown: *Object = undefined,
    /// The brightness slider's colours: the colour at its brightest down
    /// to black.
    shades: [3]Pen = .{ 0xFFFF_FFFF, 0xFF00_0000, gs.GRAD_PEN_END },
    shown_looks: [4]TagItem = undefined,
    text: [8:0]u8 = @splat(0),

    fn build(p: *Picker, ib: *IntuitionBase) ?*Object {
        _ = colourText(&p.text, p.colour);
        p.shown_looks = buttonLooks(p.colour);
        p.brightShade();
        const rgb = wheelRGB(p.colour);
        p.brightness = ib.NewObjectTagList(null, gs.GRAD_CLASS, &[_]TagItem{
            pair(gc.GA_ID, ID_BRIGHTNESS),
            pair(pg.PGA_Freedom, pg.FREEVERT),
            pair(gc.GA_Width, 18),
            pair(gc.GA_Height, 140),
            pair(gs.GRAD_PenArray, @intFromPtr(&p.shades)),
            pair(gs.GRAD_KnobPixels, 7),
            .{},
        }) orelse return null;
        p.wheel = ib.NewObjectTagList(null, cw.WHEEL_CLASS, &[_]TagItem{
            pair(gc.GA_ID, ID_WHEEL),
            pair(gc.GA_Width, 140),
            pair(gc.GA_Height, 140),
            pair(cw.WHEEL_RGB, @intFromPtr(&rgb)),
            pair(cw.WHEEL_GradientSlider, @intFromPtr(p.brightness)),
            .{},
        }) orelse {
            ib.DisposeObject(p.brightness);
            return null;
        };
        p.shown = ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
            pair(gc.GA_Text, @intFromPtr(&p.text)),
            pair(gc.GA_Style, @intFromPtr(&p.shown_looks)),
            .{},
        }) orelse return null;
        p.field = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
            pair(gc.GA_ID, ID_HEX),
            pair(gc.GA_RelVerify, 1),
            pair(gc.STRINGA_TextVal, @intFromPtr(&p.text)),
            pair(gc.STRINGA_MaxChars, 8),
            .{},
        }) orelse return null;
        const wheels = row(ib, &.{ p.wheel, p.brightness }) orelse return null;
        const typed = column(ib, null, &.{p.field}, &.{"_#RRGGBB"}) orelse return null;
        const buttons = row(ib, &.{ button(ib, "_OK", ID_OK), button(ib, "Ca_ncel", ID_NOT) }) orelse return null;
        return column(ib, null, &.{ wheels, p.shown, typed, buttons }, &.{});
    }

    /// The colour the wheel says taken.
    fn fromWheel(p: *Picker, ib: *IntuitionBase) void {
        var rgb: cw.ColorWheelRGB align(@alignOf(usize)) = .{};
        _ = ib.GetAttr(cw.WHEEL_RGB, p.wheel, @ptrCast(&rgb));
        p.colour = 0xFF00_0000 | (rgb.red >> 24) << 16 | (rgb.green >> 24) << 8 | rgb.blue >> 24;
        p.show(ib, false);
    }

    /// The colour typed taken; what is not `#RRGGBB` is put back.
    fn fromField(p: *Picker, ib: *IntuitionBase) void {
        var got: usize = 0;
        _ = ib.GetAttr(gc.STRINGA_TextVal, p.field, &got);
        if (got != 0) {
            const typed = std_span(@ptrFromInt(got));
            if (typed.len == 7) if (style_file.rgb(typed)) |colour| {
                p.colour = colour;
            };
        }
        p.show(ib, true);
    }

    /// The colour shown on the button, in the field, as the slider's top
    /// shade - and on the wheel when it did not come from there.
    fn show(p: *Picker, ib: *IntuitionBase, wheel_too: bool) void {
        const window = p.window orelse return;
        _ = colourText(&p.text, p.colour);
        p.shown_looks = buttonLooks(p.colour);
        _ = ib.SetGadgetAttrsTagList(p.shown, window, &[_]TagItem{
            pair(gc.GA_Text, @intFromPtr(&p.text)),
            pair(gc.GA_Style, @intFromPtr(&p.shown_looks)),
            .{},
        });
        _ = ib.SetGadgetAttrsTagList(p.field, window, &[_]TagItem{ pair(gc.STRINGA_TextVal, @intFromPtr(&p.text)), .{} });
        if (wheel_too) {
            const rgb = wheelRGB(p.colour);
            _ = ib.SetGadgetAttrsTagList(p.wheel, window, &[_]TagItem{ pair(cw.WHEEL_RGB, @intFromPtr(&rgb)), .{} });
        }
        p.brightShade();
        _ = ib.SetGadgetAttrsTagList(p.brightness, window, &[_]TagItem{ pair(gs.GRAD_PenArray, @intFromPtr(&p.shades)), .{} });
    }

    /// The slider's top shade: the colour at its brightest.
    fn brightShade(p: *Picker) void {
        var hsb: cw.ColorWheelHSB = .{};
        p.wheel_base.ConvertRGBToHSB(&wheelRGB(p.colour), &hsb);
        hsb.brightness = 0xFFFF_FFFF;
        var full: cw.ColorWheelRGB = .{};
        p.wheel_base.ConvertHSBToRGB(&hsb, &full);
        p.shades[0] = 0xFF00_0000 | (full.red >> 24) << 16 | (full.green >> 24) << 8 | full.blue >> 24;
    }
};

/// A colour as the wheel takes it: each part a 32-bit fraction.
fn wheelRGB(colour: Pen) cw.ColorWheelRGB {
    return .{
        .red = (colour >> 16 & 0xFF) * 0x0101_0101,
        .green = (colour >> 8 & 0xFF) * 0x0101_0101,
        .blue = (colour & 0xFF) * 0x0101_0101,
    };
}

/// `#RRGGBB` into `into`; its length.
fn colourText(into: []u8, colour: Pen) usize {
    const digits = "0123456789ABCDEF";
    into[0] = '#';
    var shift: u5 = 20;
    for (into[1..7]) |*c| {
        c.* = digits[(colour >> shift) & 0xF];
        shift -%= 4;
    }
    return 7;
}

/// A button's look in a colour, its text black or white, whichever reads.
fn buttonLooks(colour: Pen) [4]TagItem {
    const red = colour >> 16 & 0xFF;
    const green = colour >> 8 & 0xFF;
    const blue = colour & 0xFF;
    const light = red * 299 + green * 587 + blue * 114 > 140_000;
    return .{
        pair(looks.STYLE_Part, looks.PART_MAIN),
        pair(looks.STYLE_BackgroundRGB, 0xFF00_0000 | colour),
        pair(looks.STYLE_TextRGB, if (light) 0xFF00_0000 else 0xFFFF_FFFF),
        .{},
    };
}

fn std_span(text: [*:0]const u8) []const u8 {
    var n: usize = 0;
    while (text[n] != 0) n += 1;
    return text[0..n];
}

fn sameText(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// Whether `a` comes before `b`, letters' case aside.
fn sortsBefore(a: [*:0]const u8, b: [*:0]const u8) bool {
    var i: usize = 0;
    while (true) : (i += 1) {
        const x = style_file.upper(a[i]);
        const y = style_file.upper(b[i]);
        if (x != y) return x < y;
        if (x == 0) return false;
    }
}

/// "KEY: what" into `into`.
fn joinSaid(into: []u8, key: []const u8, what: []const u8) usize {
    var n: usize = 0;
    for ([_][]const u8{ key, ": ", what }) |piece| {
        const take = @min(piece.len, into.len - n);
        @memcpy(into[n..][0..take], piece[0..take]);
        n += take;
    }
    return n;
}

/// "name/size" into `into`.
fn fontText(into: []u8, name: [*:0]const u8, size: u32) usize {
    var n: usize = 0;
    while (name[n] != 0 and n + 6 < into.len) : (n += 1) into[n] = name[n];
    into[n] = '/';
    n += 1;
    var digits: [4]u8 = undefined;
    var count: usize = 0;
    var left = size;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(left % 10));
        count += 1;
        left /= 10;
        if (left == 0 or count == digits.len) break;
    }
    for (0..count) |i| into[n + i] = digits[count - 1 - i];
    return n + count;
}

fn pair(t: utility.Tag, data: usize) TagItem {
    return .{ .tag = t, .data = data };
}

/// A layout of `children` - each a gadget and its label, or none - one
/// under the other, framed with `title` when it has one.
fn column(ib: *IntuitionBase, title: ?[*:0]const u8, children: []const ?*Object, labels: []const ?[*:0]const u8) ?*Object {
    var tags: [64]TagItem = undefined;
    var n: usize = 0;
    tags[n] = pair(lg.LAYOUTA_Orientation, lg.LORIENT_VERT);
    n += 1;
    tags[n] = pair(lg.LAYOUTA_Spacing, 3);
    n += 1;
    if (title) |t| {
        tags[n] = pair(lg.LAYOUTA_FrameTitle, @intFromPtr(t));
        n += 1;
        tags[n] = pair(lg.LAYOUTA_Margin, 6);
        n += 1;
    }
    for (children, 0..) |child, i| {
        tags[n] = pair(lg.LAYOUTA_AddChild, @intFromPtr(child));
        n += 1;
        if (i < labels.len) if (labels[i]) |label| {
            tags[n] = pair(lg.CHILDA_Label, @intFromPtr(label));
            n += 1;
        };
        tags[n] = pair(lg.CHILDA_WeightHeight, 0);
        n += 1;
    }
    tags[n] = .{};
    return ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &tags);
}

fn row(ib: *IntuitionBase, children: []const ?*Object) ?*Object {
    var tags: [16]TagItem = undefined;
    var n: usize = 0;
    tags[n] = pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ);
    n += 1;
    tags[n] = pair(lg.LAYOUTA_Spacing, 6);
    n += 1;
    for (children) |child| {
        tags[n] = pair(lg.LAYOUTA_AddChild, @intFromPtr(child));
        n += 1;
    }
    tags[n] = .{};
    return ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &tags);
}

/// The pages, which the page gadget keeps a pointer to.
var pages: [tab_names.len:null]?*Object = @splat(null);

/// The window's whole layout, the editor's gadgets kept in it; null when
/// something could not be made.
fn build(e: *Editor) ?*Object {
    const ib = e.ib;
    // The style page.
    e.part_chooser = ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_PART),
        pair(gc.GA_RelVerify, 1),
        pair(ch.CHOOSER_Labels, @intFromPtr(&part_labels)),
        pair(ch.CHOOSER_MaxPanelLines, 10),
        .{},
    }) orelse return null;
    e.state_chooser = ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_STATE),
        pair(gc.GA_RelVerify, 1),
        pair(ch.CHOOSER_Labels, @intFromPtr(&state_labels)),
        .{},
    }) orelse return null;
    e.border = ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_BORDER),
        pair(gc.GA_RelVerify, 1),
        pair(ch.CHOOSER_Labels, @intFromPtr(&border_labels)),
        .{},
    }) orelse return null;
    e.joins = ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_JOINS),
        pair(gc.GA_RelVerify, 1),
        pair(ch.CHOOSER_Labels, @intFromPtr(&joins_labels)),
        .{},
    }) orelse return null;
    var colour_gadgets: [colour_fields.len]?*Object = undefined;
    var colour_labels: [colour_fields.len]?[*:0]const u8 = undefined;
    for (colour_fields, 0..) |f, i| {
        const field = stringField(ib, f.key) orelse return null;
        e.fields[@intFromEnum(f.key)] = field;
        const chooser = ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
            pair(gc.GA_ID, ID_PEN_CHOICE + @intFromEnum(f.key)),
            pair(gc.GA_RelVerify, 1),
            pair(ch.CHOOSER_Labels, @intFromPtr(&pen_choice_labels)),
            pair(ch.CHOOSER_MaxPanelLines, pen_choice_labels.len),
            .{},
        }) orelse return null;
        e.pen_choosers[@intFromEnum(f.key)] = chooser;
        colour_gadgets[i] = row(ib, &.{ chooser, field });
        colour_labels[i] = f.label;
    }
    var shape_gadgets: [shape_fields.len + 2]?*Object = undefined;
    var shape_labels: [shape_fields.len + 2]?[*:0]const u8 = undefined;
    shape_gadgets[0] = e.border;
    shape_labels[0] = "Border";
    shape_gadgets[1] = e.joins;
    shape_labels[1] = "Corners";
    for (shape_fields, 0..) |f, i| {
        shape_gadgets[i + 2] = stringField(ib, f.key);
        e.fields[@intFromEnum(f.key)] = shape_gadgets[i + 2];
        shape_labels[i + 2] = f.label;
    }
    e.status = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        pair(tx.TEXT_Text, @intFromPtr(&e.status_text)),
        pair(tx.TEXT_Clipped, 1),
        .{},
    }) orelse return null;
    e.preview[0] = ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{ pair(gc.GA_Text, @intFromPtr("A button")), .{} }) orelse return null;
    e.preview[1] = ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &[_]TagItem{ pair(gc.GA_Selected, 1), .{} }) orelse return null;
    e.preview[2] = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{ pair(gc.STRINGA_TextVal, @intFromPtr("A field")), pair(gc.STRINGA_MaxChars, 32), .{} }) orelse return null;
    e.preview[3] = ib.NewObjectTagList(null, sl.SLIDER_CLASS, &[_]TagItem{ pair(sl.SLIDER_Level, 40), pair(sl.SLIDER_Max, 100), .{} }) orelse return null;

    const choose = column(ib, null, &.{ e.part_chooser, e.state_chooser }, &.{ "_Part", "S_tate" }) orelse return null;
    const colours = column(ib, "Colours", &colour_gadgets, &colour_labels) orelse return null;
    const shape = column(ib, "Shape", &shape_gadgets, &shape_labels) orelse return null;
    const preview = column(ib, "Looks like", &.{ e.preview[0], e.preview[1], e.preview[2], e.preview[3] }, &.{ null, "A box", null, null }) orelse return null;
    const left = column(ib, null, &.{ choose, colours, preview }, &.{}) orelse return null;
    const fields = row(ib, &.{ left, shape }) orelse return null;
    pages[page_advanced] = column(ib, null, &.{ fields, e.status }, &.{}) orelse return null;

    // The style page: the looks, what the one picked is, and how it looks.
    e.preview[4] = ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{ pair(gc.GA_Text, @intFromPtr("A button")), .{} }) orelse return null;
    e.preview[5] = ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &[_]TagItem{ pair(gc.GA_Selected, 1), .{} }) orelse return null;
    e.preview[6] = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{ pair(gc.STRINGA_TextVal, @intFromPtr("A field")), pair(gc.STRINGA_MaxChars, 32), .{} }) orelse return null;
    e.preview[7] = ib.NewObjectTagList(null, sl.SLIDER_CLASS, &[_]TagItem{ pair(sl.SLIDER_Level, 40), pair(sl.SLIDER_Max, 100), .{} }) orelse return null;
    e.preset_list = ib.NewObjectTagList(null, lv.LISTVIEW_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_PRESET),
        pair(gc.GA_RelVerify, 1),
        pair(lv.LISTVIEW_Labels, @intFromPtr(&e.presets)),
        pair(lv.LISTVIEW_ShowSelected, 1),
        .{},
    }) orelse return null;
    e.about = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        pair(tx.TEXT_Markup, 1),
        pair(tx.TEXT_Wrap, 1),
        pair(gc.GA_Width, 220),
        pair(tx.TEXT_Text, @intFromPtr("Pick a look from the list. Until you pick one, the look in use now stays as it is.")),
        .{},
    }) orelse return null;
    const shown = column(ib, "Looks like", &.{ e.preview[4], e.preview[5], e.preview[6], e.preview[7] }, &.{ null, "A box", null, null }) orelse return null;
    const right = column(ib, null, &.{ e.about, shown }, &.{}) orelse return null;
    pages[page_style] = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
        pair(lg.LAYOUTA_Spacing, 8),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(e.preset_list)),
        pair(lg.CHILDA_MinWidth, 160),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(right)),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.CHILDA_Align, lg.CALIGN_TOP),
        .{},
    }) orelse return null;

    // The colours page: a field and a button for each pen, in two groups.
    var pen_rows: [sc.NUMDRIPENS]?*Object = undefined;
    for (0..sc.NUMDRIPENS) |pen| {
        var text: [8:0]u8 = @splat(0);
        _ = colourText(&text, e.pens[pen]);
        e.pen_looks[pen] = buttonLooks(e.pens[pen]);
        e.pen_fields[pen] = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
            pair(gc.GA_ID, ID_PEN_FIELD + pen),
            pair(gc.GA_RelVerify, 1),
            pair(gc.GA_Width, 80),
            pair(gc.STRINGA_TextVal, @intFromPtr(&text)),
            pair(gc.STRINGA_MaxChars, 8),
            .{},
        }) orelse return null;
        e.pen_buttons[pen] = ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
            pair(gc.GA_Text, @intFromPtr("Pick...")),
            pair(gc.GA_ID, ID_PEN_PICK + pen),
            pair(gc.GA_RelVerify, 1),
            pair(gc.GA_Style, @intFromPtr(&e.pen_looks[pen])),
            .{},
        }) orelse return null;
        pen_rows[pen] = row(ib, &.{ e.pen_fields[pen], e.pen_buttons[pen] });
    }
    const half = sc.NUMDRIPENS / 2;
    const drawing = column(ib, "Lines and fills", pen_rows[0..half], pen_labels[0..half]) orelse return null;
    const ground = column(ib, "Text, ground and bar", pen_rows[half..], pen_labels[half..]) orelse return null;
    const groups = row(ib, &.{ drawing, ground }) orelse return null;
    const note = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        pair(tx.TEXT_Wrap, 1),
        pair(tx.TEXT_Text, @intFromPtr("Every screen without colours of its own draws in these. Save or Use puts them in force.")),
        .{},
    }) orelse return null;
    const builtin = row(ib, &.{button(ib, "_Built-in colours", ID_BUILTIN)}) orelse return null;
    pages[page_colours] = column(ib, null, &.{ groups, note, builtin }, &.{}) orelse return null;

    // The fonts page.
    const font_titles = [font_file.which_names.len][*:0]const u8{ "Font of screens' bars and menus", "Font of windows and gadgets", "Font of consoles (fixed-width)", "Font of the desktop's icons" };
    for (&e.fonts, 0..) |*o, i| {
        var name: [font_file.value_len:0]u8 = undefined;
        const attr = if (e.font_line.get(@enumFromInt(i))) |text| font_file.attrOf(text, &name) else null;
        o.* = ib.NewObjectTagList(null, gfo.GETFONT_CLASS, &[_]TagItem{
            pair(gc.GA_ID, ID_FONT + i),
            pair(gfo.GETFONT_TitleText, @intFromPtr(font_titles[i])),
            pair(gfo.GETFONT_Name, if (attr) |a| @intFromPtr(a.name) else @intFromPtr(graphics.POSPAZNAME)),
            pair(gfo.GETFONT_Size, if (attr) |a| a.y_size else 16),
            pair(icc.ICA_TARGET, icc.ICTARGET_IDCMP),
            .{},
        }) orelse return null;
    }
    pages[page_fonts] = column(ib, "The system's fonts", &.{ e.fonts[0], e.fonts[1], e.fonts[2], e.fonts[3] }, &.{ "Sc_reen", "_Windows", "Conso_les", "Ic_ons" }) orelse return null;

    // The desktop page.
    var ground_text: [20:0]u8 = @splat(0);
    _ = e.groundText(&ground_text);
    e.ground_looks = buttonLooks(e.groundColour());
    e.ground_field = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_GROUND),
        pair(gc.GA_RelVerify, 1),
        pair(gc.GA_Width, field_width),
        pair(gc.STRINGA_TextVal, @intFromPtr(&ground_text)),
        pair(gc.STRINGA_MaxChars, 17),
        .{},
    }) orelse return null;
    e.ground_button = ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        pair(gc.GA_Text, @intFromPtr("Pick...")),
        pair(gc.GA_ID, ID_GROUND_PICK),
        pair(gc.GA_RelVerify, 1),
        pair(gc.GA_Style, @intFromPtr(&e.ground_looks)),
        .{},
    }) orelse return null;
    const ground_row = row(ib, &.{ e.ground_field, e.ground_button }) orelse return null;
    // The picture's name as the field shows it: its drawer and its own.
    var drawer: [anvil_file.picture_max + 1]u8 = @splat(0);
    var own: [anvil_file.picture_max + 1]u8 = @splat(0);
    if (e.desktop.pictureName()) |name| {
        var cut: usize = 0;
        for (name, 0..) |c, i| if (c == '/' or c == ':') {
            cut = i + 1;
        };
        @memcpy(drawer[0..cut], name[0..cut]);
        if (cut > 0 and drawer[cut - 1] == '/') drawer[cut - 1] = 0;
        @memcpy(own[0 .. name.len - cut], name[cut..]);
    }
    e.picture = ib.NewObjectTagList(null, gf.GETFILE_CLASS, &[_]TagItem{
        pair(gf.GETFILE_TitleText, @intFromPtr("The desktop's picture")),
        pair(gf.GETFILE_Drawer, @intFromPtr(&drawer)),
        pair(gf.GETFILE_File, @intFromPtr(&own)),
        .{},
    }) orelse return null;
    e.place = ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
        pair(ch.CHOOSER_Labels, @intFromPtr(&place_labels)),
        pair(ch.CHOOSER_Active, @intFromEnum(e.desktop.place)),
        .{},
    }) orelse return null;
    e.icon_size = ib.NewObjectTagList(null, ig.INTEGER_CLASS, &[_]TagItem{
        pair(ig.INTEGER_Min, anvil_file.icon_size_min),
        pair(ig.INTEGER_Max, anvil_file.icon_size_max),
        pair(ig.INTEGER_Step, 8),
        pair(ig.INTEGER_Number, e.desktop.icon_size),
        .{},
    }) orelse return null;
    e.snap = ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &[_]TagItem{
        pair(cb.CHECKBOX_Checked, @intFromBool(e.desktop.snap)),
        .{},
    }) orelse return null;
    e.view = ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
        pair(ch.CHOOSER_Labels, @intFromPtr(&view_labels)),
        pair(ch.CHOOSER_Active, @intFromEnum(e.desktop.view)),
        .{},
    }) orelse return null;
    const ground_note = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        pair(tx.TEXT_Wrap, 1),
        pair(tx.TEXT_Text, @intFromPtr("A colour #RRGGBB, or two #top..#bottom shaded down the desktop; empty for the screen's background.")),
        .{},
    }) orelse return null;
    const ground_group = column(ib, "Ground", &.{ ground_row, ground_note, e.picture, e.place }, &.{ "_Ground", null, "P_icture", "Pl_ace" }) orelse return null;
    const icons_group = column(ib, "Icons", &.{ e.icon_size, e.snap, e.view }, &.{ "Icon si_ze", "Snap _to grid", "Drawers' _view" }) orelse return null;
    pages[page_desktop] = column(ib, null, &.{ ground_group, icons_group }, &.{}) orelse return null;

    // The system page.
    var now: intuition_file.Settings = .{};
    _ = ib.GetPrefs(&[_]TagItem{
        pair(intuition.IPREFS_DoubleClick, @intFromPtr(&now.double_click)),
        pair(intuition.IPREFS_ScreenFontHeight, @intFromPtr(&now.screen_font)),
        pair(intuition.IPREFS_Keyboard, @intFromPtr(&now.keyboard)),
        pair(intuition.IPREFS_OffScreen, @intFromPtr(&now.off_screen)),
        pair(intuition.IPREFS_WideGadgets, @intFromPtr(&now.wide_gadgets)),
        .{},
    });
    e.double = ib.NewObjectTagList(null, ig.INTEGER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_DOUBLE),
        pair(ig.INTEGER_Min, 100),
        pair(ig.INTEGER_Max, 5000),
        pair(ig.INTEGER_Step, 100),
        pair(ig.INTEGER_Number, now.double_click),
        .{},
    }) orelse return null;
    e.height = ib.NewObjectTagList(null, ig.INTEGER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_HEIGHT),
        pair(ig.INTEGER_Min, 6),
        pair(ig.INTEGER_Max, 64),
        pair(ig.INTEGER_Number, now.screen_font),
        .{},
    }) orelse return null;
    e.keyboard = ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_KEYBOARD),
        pair(ch.CHOOSER_Labels, @intFromPtr(&keyboard_labels)),
        pair(ch.CHOOSER_Active, @min(now.keyboard, 2)),
        .{},
    }) orelse return null;
    e.off_screen = ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_OFFSCREEN),
        pair(cb.CHECKBOX_Checked, now.off_screen),
        .{},
    }) orelse return null;
    e.wide_gadgets = ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_WIDE),
        pair(cb.CHECKBOX_Checked, now.wide_gadgets),
        .{},
    }) orelse return null;
    pages[page_system] = column(ib, "intuition", &.{ e.double, e.height, e.keyboard, e.off_screen, e.wide_gadgets }, &.{ "_Double-click ms", "Screen _font rows", "_Keyboard on screen", "Windows past _edges", "Wide title bar gadgets" }) orelse return null;

    // The sound page: the outputs beside the beep.
    var output_gadgets: [max_rows + 1]?*Object = undefined;
    var output_labels: [max_rows + 1]?[*:0]const u8 = undefined;
    var output_count: usize = 0;
    if (e.control == null or e.row_count == 0) {
        output_gadgets[0] = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
            pair(tx.TEXT_Wrap, 1),
            pair(gc.GA_Width, 160),
            pair(tx.TEXT_Text, @intFromPtr(@as([*:0]const u8, if (e.control == null) "This machine has no sound." else "No output is plugged in."))),
            .{},
        }) orelse return null;
        output_labels[0] = null;
        output_count = 1;
    } else {
        e.prefer = ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
            pair(gc.GA_ID, ID_PREFER),
            pair(gc.GA_RelVerify, 1),
            pair(ch.CHOOSER_Labels, @intFromPtr(&e.prefer_labels)),
            pair(ch.CHOOSER_Active, e.preferChoice()),
            .{},
        }) orelse return null;
        output_gadgets[0] = e.prefer;
        output_labels[0] = "Preferred";
        output_count = 1;
        for (0..e.row_count) |row_at| {
            e.volume_sliders[row_at] = ib.NewObjectTagList(null, sl.SLIDER_CLASS, &[_]TagItem{
                pair(gc.GA_ID, ID_OUT_VOLUME + row_at),
                pair(gc.GA_RelVerify, 1),
                pair(sl.SLIDER_Max, 100),
                pair(sl.SLIDER_Level, e.audio.outputs[e.rows[row_at]].volume),
                pair(sl.SLIDER_LevelFormat, @intFromPtr("%ld%%")),
                pair(sl.SLIDER_MaxLevelLen, 4),
                pair(icc.ICA_TARGET, icc.ICTARGET_IDCMP),
                pair(gc.GA_Width, 100),
                .{},
            }) orelse return null;
            output_gadgets[output_count] = e.volume_sliders[row_at];
            output_labels[output_count] = &e.row_labels[row_at];
            output_count += 1;
        }
    }
    const outputs_group = column(ib, "Outputs and their volumes", output_gadgets[0..output_count], output_labels[0..output_count]) orelse return null;
    e.flash = ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &[_]TagItem{
        pair(cb.CHECKBOX_Checked, e.beep.flash),
        .{},
    }) orelse return null;
    e.beep_sound = ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_BEEP_SOUND),
        pair(ch.CHOOSER_Labels, @intFromPtr(&beep_sound_labels)),
        pair(ch.CHOOSER_Active, @min(e.beep.sound, sound_file.SOUND_SAMPLE)),
        .{},
    }) orelse return null;
    e.beep_volume = ib.NewObjectTagList(null, sl.SLIDER_CLASS, &[_]TagItem{
        pair(sl.SLIDER_Min, 1),
        pair(sl.SLIDER_Max, 100),
        pair(sl.SLIDER_Level, e.beep.volume),
        pair(sl.SLIDER_LevelFormat, @intFromPtr("%ld%%")),
        pair(sl.SLIDER_MaxLevelLen, 4),
        pair(gc.GA_Width, 100),
        .{},
    }) orelse return null;
    e.tone = ib.NewObjectTagList(null, ig.INTEGER_CLASS, &[_]TagItem{
        pair(ig.INTEGER_Min, 100),
        pair(ig.INTEGER_Max, 8000),
        pair(ig.INTEGER_Step, 10),
        pair(ig.INTEGER_Number, e.beep.tone),
        .{},
    }) orelse return null;
    e.duration = ib.NewObjectTagList(null, ig.INTEGER_CLASS, &[_]TagItem{
        pair(ig.INTEGER_Min, 10),
        pair(ig.INTEGER_Max, 1000),
        pair(ig.INTEGER_Step, 10),
        pair(ig.INTEGER_Number, e.beep.duration),
        .{},
    }) orelse return null;
    // The sound file's name as the field shows it: its drawer and its own.
    var sample_drawer: [sound_file.sample_len + 1]u8 = @splat(0);
    var sample_own: [sound_file.sample_len + 1]u8 = @splat(0);
    const sample_name = std_span(&e.beep.sample);
    var sample_cut: usize = 0;
    for (sample_name, 0..) |c, i| if (c == '/' or c == ':') {
        sample_cut = i + 1;
    };
    @memcpy(sample_drawer[0..sample_cut], sample_name[0..sample_cut]);
    if (sample_cut > 0 and sample_drawer[sample_cut - 1] == '/') sample_drawer[sample_cut - 1] = 0;
    @memcpy(sample_own[0 .. sample_name.len - sample_cut], sample_name[sample_cut..]);
    e.sample = ib.NewObjectTagList(null, gf.GETFILE_CLASS, &[_]TagItem{
        pair(gf.GETFILE_TitleText, @intFromPtr("The beep's sound")),
        pair(gf.GETFILE_Drawer, @intFromPtr(@as([*]const u8, if (sample_drawer[0] != 0) &sample_drawer else "SYS:"))),
        pair(gf.GETFILE_File, @intFromPtr(&sample_own)),
        .{},
    }) orelse return null;
    const test_row = row(ib, &.{button(ib, "Test", ID_TEST)}) orelse return null;
    const beep_group = column(ib, "Beep", &.{ e.flash, e.beep_sound, e.beep_volume, e.tone, e.duration, e.sample, test_row }, &.{ "Flash the display", "Sound", "Volume", "Tone Hz", "Length ms", "Sound file", null }) orelse return null;
    e.sound_status = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        pair(tx.TEXT_Text, @intFromPtr(&e.sound_status_text)),
        pair(tx.TEXT_Clipped, 1),
        .{},
    }) orelse return null;
    const sound_groups = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(outputs_group)),
        pair(lg.CHILDA_Align, lg.CALIGN_TOP),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(beep_group)),
        pair(lg.CHILDA_Align, lg.CALIGN_TOP),
        .{},
    }) orelse return null;
    pages[page_sound] = column(ib, null, &.{ sound_groups, e.sound_status }, &.{}) orelse return null;

    const book = ib.NewObjectTagList(null, pgc.PAGE_CLASS, &[_]TagItem{ pair(pgc.PAGE_Pages, @intFromPtr(&pages)), .{} }) orelse return null;
    e.tabs = ib.NewObjectTagList(null, ct.CLICKTAB_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_TABS),
        pair(ct.CLICKTAB_Labels, @intFromPtr(&tab_names)),
        pair(icc.ICA_TARGET, @intFromPtr(book)),
        pair(icc.ICA_MAP, @intFromPtr(&tab_to_page)),
        .{},
    }) orelse return null;
    const buttons = row(ib, &.{
        button(ib, "_Save", ID_SAVE),
        button(ib, "_Use", ID_USE),
        button(ib, "_Cancel", ID_CANCEL),
    }) orelse return null;
    return ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Margin, 6),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(e.tabs)),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(book)),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(buttons)),
        pair(lg.CHILDA_WeightHeight, 0),
        .{},
    });
}

fn stringField(ib: *IntuitionBase, key: style_file.Key) ?*Object {
    return ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_FIELD + @intFromEnum(key)),
        pair(gc.GA_RelVerify, 1),
        pair(gc.GA_Width, field_width),
        pair(gc.STRINGA_MaxChars, style_file.value_len - 1),
        .{},
    });
}

/// How wide a style field is: room for `#FAFBFC..#D8DCE2`.
const field_width = 150;

fn button(ib: *IntuitionBase, label: [*:0]const u8, id: usize) ?*Object {
    return ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        pair(gc.GA_Text, @intFromPtr(label)),
        pair(gc.GA_ID, id),
        pair(gc.GA_RelVerify, 1),
        .{},
    });
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);
    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);

    const wanted = [_][*:0]const u8{
        ct.CLICKTAB_LIBRARY, pgc.PAGE_LIBRARY,  ch.CHOOSER_LIBRARY,  st.STRING_LIBRARY,
        ig.INTEGER_LIBRARY,  tx.TEXT_LIBRARY,   gfo.GETFONT_LIBRARY, gf.GETFILE_LIBRARY,
        cb.CHECKBOX_LIBRARY, sl.SLIDER_LIBRARY, lv.LISTVIEW_LIBRARY, gs.GRAD_LIBRARY,
        cw.WHEEL_LIBRARY,
    };
    var libraries: [wanted.len]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    for (wanted, 0..) |name, i| {
        libraries[i] = sys.OpenLibrary(name, 0) orelse {
            _ = Printf(dl, MSG_NOLIBRARY, .{name});
            return dos.RETURN_FAIL;
        };
    }

    const memory = sys.AllocVec(@sizeOf(Editor) + max_file, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const e: *Editor = @ptrCast(@alignCast(memory));
    // The wheel's library, last, is also where its conversions are.
    e.* = .{ .ib = ib, .dl = dl, .sys = sys, .wheel_base = @ptrCast(libraries[wanted.len - 1]) };
    const file: [*]u8 = @as([*]u8, @ptrCast(memory)) + @sizeOf(Editor);

    // What is in force now: the files in ENV:.
    if (prefs.load(dl, style_file.ENV_FILE, file[0..max_file])) |text| e.model.load(text);
    if (prefs.load(dl, font_file.ENV_FILE, file[0..max_file])) |text| {
        if (prefs.firstLine(text)) |line| _ = font_file.parse(line, &e.font_line);
    }
    if (prefs.load(dl, anvil_file.ENV_FILE, file[0..max_file])) |text| {
        var desktop: anvil_file.Settings = .{};
        if (prefs.firstLine(text)) |line| if (anvil_file.parse(line, &desktop) == null) {
            e.desktop = desktop;
        };
    }

    // The system's pens: as the default screen has them, as the file says.
    if (ib.LockPubScreen(null)) |screen| {
        const dri = ib.GetScreenDrawInfo(screen);
        for (&e.pens, 0..) |*pen, i| pen.* = dri.pens[i];
        ib.FreeScreenDrawInfo(screen, dri);
        ib.UnlockPubScreen(null, screen);
    }
    if (prefs.load(dl, palette_file.ENV_FILE, file[0..max_file])) |text| {
        var palette = palette_file.Palette{ .pens = e.pens };
        if (prefs.firstLine(text)) |line| if (palette_file.parse(line, &palette) == null) {
            e.pens = palette.pens;
        };
    }

    if (prefs.load(dl, sound_file.ENV_FILE, file[0..max_file])) |text| {
        var beep: sound_file.Settings = .{};
        if (prefs.firstLine(text)) |line| if (sound_file.parse(line, &beep) == null) {
            e.beep = beep;
        };
    }
    e.control = audiocontrol.Control.open(sys);
    defer e.closeSound();
    e.readAudio(file[0..max_file]);

    e.readPresets();
    const layout = build(e) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        pair(wn.WA_Title, @intFromPtr("Preferences")),
        pair(wn.WA_ScreenTitle, @intFromPtr(SCREEN_TITLE)),
        pair(wn.WA_CloseGadget, 1),
        pair(wn.WA_DragBar, 1),
        pair(wn.WA_DepthGadget, 1),
        pair(wn.WA_Activate, 1),
        pair(wn.WA_IDCMP, wn.IDCMP_IDCMPUPDATE),
        pair(wc.WINDOWA_Layout, @intFromPtr(layout)),
        .{},
    }) orelse {
        ib.DisposeObject(layout);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.DisposeObject(object);
    e.object = object;
    e.showLine();
    e.showPreview();
    if (e.model.skipped != 0) e.say("Some lines of the style file could not be read: they are not kept");

    var open = wc.WmOpen{};
    if (ib.SendMessage(object, @ptrCast(&open)) == 0) {
        _ = Printf(dl, MSG_NOWINDOW, .{});
        return dos.RETURN_FAIL;
    }
    var window_ptr: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_Window, object, &window_ptr);
    const window: *intuition.Window = @ptrFromInt(window_ptr);
    e.window = window;

    var code: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code };
    while (true) {
        const got = ib.WaitIMsg(window, exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_WARN;
        while (true) {
            const word = ib.SendMessage(object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => {
                    e.restoreAudio();
                    return dos.RETURN_OK;
                },
                wc.WMHI_GADGETUP => {
                    const id = word & wc.WMHI_GADGETMASK;
                    switch (id) {
                        ID_PART => {
                            e.part = @min(code, style_file.parts.len - 1);
                            e.showLine();
                        },
                        ID_STATE => {
                            e.state = @min(code, style_file.states.len - 1);
                            e.showLine();
                        },
                        ID_BORDER => e.takeChoice(.border, &style_file.borders, code),
                        ID_JOINS => e.takeChoice(.joins, &style_file.joins, code),
                        ID_SAVE, ID_USE => {
                            const beep = e.beepPrefs();
                            if (beep.sound == sound_file.SOUND_SAMPLE and beep.sample[0] == 0) {
                                e.saySound("A sound file for the beep: pick one, or another sound");
                                continue;
                            }
                            if (e.apply(id == ID_SAVE)) return dos.RETURN_OK;
                            e.say("A file could not be written: see the shell");
                        },
                        ID_CANCEL => {
                            e.restoreAudio();
                            return dos.RETURN_OK;
                        },
                        ID_PREFER => e.takePrefer(code),
                        ID_TEST => e.testBeep(),
                        ID_PRESET => e.pickPreset(code & ~lv.LISTVIEW_DOUBLE),
                        ID_BUILTIN => e.builtInPens(),
                        ID_GROUND => e.takeGround(),
                        ID_GROUND_PICK => e.pickGround(),
                        else => if (id >= ID_FIELD and id < ID_FIELD + style_file.key_count) {
                            e.takeField(@enumFromInt(id - ID_FIELD));
                        } else if (id >= ID_PEN_CHOICE and id < ID_PEN_CHOICE + style_file.key_count) {
                            e.takePenChoice(@enumFromInt(id - ID_PEN_CHOICE), code);
                        } else if (id >= ID_PEN_FIELD and id < ID_PEN_FIELD + sc.NUMDRIPENS) {
                            e.takePen(id - ID_PEN_FIELD);
                        } else if (id >= ID_PEN_PICK and id < ID_PEN_PICK + sc.NUMDRIPENS) {
                            e.pickPen(id - ID_PEN_PICK);
                        } else if (id >= ID_OUT_VOLUME and id < ID_OUT_VOLUME + max_rows) {
                            e.takeVolume(id - ID_OUT_VOLUME, code);
                        },
                    }
                },
                // An output's volume moved, or a font picked in its
                // requester.
                wc.WMHI_IDCMPUPDATE => {
                    var updated: usize = 0;
                    _ = ib.GetAttr(wc.WINDOWA_GadgetID, object, &updated);
                    if (updated >= ID_OUT_VOLUME and updated < ID_OUT_VOLUME + max_rows) {
                        var level: usize = 0;
                        _ = ib.GetAttr(sl.SLIDER_Level, e.volume_sliders[updated - ID_OUT_VOLUME], &level);
                        e.takeVolume(updated - ID_OUT_VOLUME, level);
                        continue;
                    }
                    for (e.fonts, 0..) |o, i| {
                        var name: usize = 0;
                        _ = ib.GetAttr(gfo.GETFONT_Name, o, &name);
                        var size: usize = 0;
                        _ = ib.GetAttr(gfo.GETFONT_Size, o, &size);
                        var was: [font_file.value_len:0]u8 = undefined;
                        const before = if (e.font_line.get(@enumFromInt(i))) |text| font_file.attrOf(text, &was) else null;
                        const same_font = if (before) |b| name != 0 and sameText(std_span(@ptrFromInt(name)), std_span(b.name)) and b.y_size == size else false;
                        if (!same_font) e.font_picked[i] = true;
                    }
                },
                else => {},
            }
        }
    }
}
