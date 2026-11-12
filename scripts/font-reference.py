#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""What fontTools reads from the fetched fonts, written as Zig for the host tests.

truetype.library's host tests read the fonts scripts/fetch-fonts.sh fetches
and compare what they find with what another reader of fonts finds. This is
that other reader: fontTools opens each font named below, and what it says
of the font - its tables, its measures, every character map, the variation
sequences, the names, each glyph's measures, and of a font whose outlines
are a CFF table's each glyph's outline - is written as a Zig file in
src/disk/libs/truetype/tests/reference/, headed by the font's file name and
its SHA-256. Glyphs of such a font are also rendered by libfreetype, which
reads the same outlines by its own code: how much ink each has, and a few
of them pixel by pixel. src/disk/libs/truetype/tests/reference.zig says
what each value is and how the long ones are counted and hashed; the same
rule is applied here and there, so a digest that differs is a reading that
differs.

The files are committed, and the tests need neither Python nor fontTools. A
test stops by name when its font's SHA-256 is not the one written here, so
this runs again when a font's pin in scripts/fetch-fonts.sh changes, and at
no other time.

  python3 -I scripts/font-reference.py           write the files
  python3 -I scripts/font-reference.py --check   say whether they are as it would write them

The fonts are files from elsewhere: -I keeps Python from loading anything
that lies beside them or beside this script.
"""

import ctypes
import hashlib
import math
import os
import struct
import sys

try:
    from fontTools.pens.recordingPen import RecordingPen
    from fontTools.ttLib import TTFont
except ImportError:
    sys.exit("font-reference: fontTools is not installed (python-fonttools)")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONTS_DIR = os.path.join(ROOT, "toolchain", "fonts")
OUT_DIR = os.path.join(ROOT, "src", "disk", "libs", "truetype", "tests", "reference")

# The fonts read, each as its path under toolchain/fonts, the name of the
# file written for it, and what is its own: which font of a collection it
# is (index), every which glyph is read where another font's values cover
# the same glyphs in full (glyph_step), and every which glyph libfreetype
# renders (ink_step). reference.zig lists the same files.
FONTS = [
    ("go/Go-Regular.ttf", "go_regular", {}),
    ("liberation-fonts-ttf-2.1.5/LiberationSans-Regular.ttf", "liberation_sans_regular", {}),
    ("noto/NotoSansDevanagari-Regular.ttf", "noto_sans_devanagari_regular", {}),
    ("noto/NotoColorEmoji.ttf", "noto_color_emoji", {}),
    ("source-sans/SourceSans3-Regular.otf", "source_sans_3_regular", {"ink_step": 1}),
    ("noto/NotoSansCJK-Regular.ttc", "noto_sans_cjk_jp_regular", {"index": 0, "ink_step": 61}),
    ("noto/NotoSansCJK-Regular.ttc", "noto_sans_cjk_sc_regular", {"index": 2, "glyph_step": 97, "ink_step": 997}),
]

# How many values of a long list are written out beside its digest.
SAMPLE_PAIRS = 12
SAMPLE_SEQUENCES = 8

# How many outlines are written out beside their digest, and the most
# points one of those has.
SAMPLE_SHAPES = 6
SHAPE_POINTS = 16

# The height of the line libfreetype renders glyphs for to add up their
# ink, and the one it renders the few written out pixel by pixel for.
INK_ROWS = 40
PICTURE_ROWS = 24
SAMPLE_PICTURES = 4

# The verbs of an outline: the letter written, and the number hashed.
VERBS = {"moveTo": ("M", 0), "lineTo": ("L", 1), "curveTo": ("C", 2), "closePath": ("Z", 3)}


def digest(form, records):
    """The SHA-256 of the records, each packed as `form` says, in hex."""
    sha = hashlib.sha256()
    for record in records:
        sha.update(struct.pack(form, *record))
    return sha.hexdigest()


def spread(items, most):
    """At most `most` of the items, evenly spaced, the first and last among them."""
    if len(items) <= most:
        return list(items)
    return [items[i * (len(items) - 1) // (most - 1)] for i in range(most)]


def quoted(text):
    """A Zig string literal of the text, in UTF-8."""
    out = []
    for char in text:
        if char == "\\":
            out.append("\\\\")
        elif char == '"':
            out.append('\\"')
        elif char == "\n":
            out.append("\\n")
        elif char == "\r":
            out.append("\\r")
        elif char == "\t":
            out.append("\\t")
        elif ord(char) < 0x20 or ord(char) == 0x7F:
            out.append("\\x%02x" % ord(char))
        else:
            out.append(char)
    return '"' + "".join(out) + '"'


def pairs_of(font, mapping):
    """A character map as (code, glyph) sorted by code, without glyph 0."""
    pairs = [(code, font.getGlyphID(name)) for code, name in mapping.items()]
    return sorted(pair for pair in pairs if pair[1] != 0)


def name_of(font, path, name_id):
    """The text of one name: its American English record on the Windows platform.

    A name that only a Macintosh record gives is none to the library, and is
    written as the empty string. Any other set of records has no rule here:
    the script stops rather than guess which one the library should take.
    """
    table = font["name"]
    record = table.getName(name_id, 3, 1, 0x409)
    if record is not None:
        return record.toUnicode()
    platforms = {r.platformID for r in table.names if r.nameID == name_id}
    if platforms == {1}:
        return ""
    sys.exit("font-reference: %s: name %d has records this script has no rule for" % (path, name_id))


def outline_of(path, glyphs, name):
    """A glyph of cubic curves as fontTools draws it: its verbs, and its points.

    A list of (verb, points). A contour of one point - a move nothing is
    drawn from - is none. The points are whole units: the script stops at
    a font that has others, for which the digest has no rule.
    """
    pen = RecordingPen()
    glyphs[name].draw(pen)
    drawn = []
    for verb, points in pen.value:
        if verb not in VERBS:
            sys.exit("font-reference: %s: glyph %s is drawn with %s" % (path, name, verb))
        if verb == "closePath" and drawn and drawn[-1][0] == "moveTo":
            drawn.pop()
            continue
        for x, y in points:
            if x != int(x) or y != int(y):
                sys.exit("font-reference: %s: glyph %s has a point between whole units" % (path, name))
        drawn.append((verb, [(int(x), int(y)) for x, y in points]))
    return drawn


def box_of(drawn):
    """The box of a drawn glyph's points, control points among them; 0 without one."""
    points = [point for _, points in drawn for point in points]
    if not points:
        return (0, 0, 0, 0)
    return (
        min(x for x, _ in points),
        min(y for _, y in points),
        max(x for x, _ in points),
        max(y for _, y in points),
    )


class Bitmap(ctypes.Structure):
    """libfreetype's FT_Bitmap."""

    _fields_ = [
        ("rows", ctypes.c_uint),
        ("width", ctypes.c_uint),
        ("pitch", ctypes.c_int),
        ("buffer", ctypes.POINTER(ctypes.c_ubyte)),
        ("num_grays", ctypes.c_ushort),
        ("pixel_mode", ctypes.c_ubyte),
        ("palette_mode", ctypes.c_ubyte),
        ("palette", ctypes.c_void_p),
    ]


class Renderer:
    """One font's glyphs rendered by libfreetype, as the library places them.

    A glyph's outline is loaded in the font's units, without hints, scaled
    so that the line from the ascender to the descender is `rows` pixels
    tall, and put where the point is at a pixel's left edge and the
    ascender at a row's top: where truetype.library renders it.
    """

    # Where FT_FaceRec keeps units_per_EM and its glyph slot, and
    # FT_GlyphSlotRec the format and the outline of the glyph loaded: the
    # places of a 64-bit host, checked when a font is opened.
    FACE_UNITS = 136
    FACE_SLOT = 152
    SLOT_FORMAT = 144
    SLOT_OUTLINE = 200
    LOAD_NO_SCALE = 1
    FORMAT_OUTLINE = 0x6F75746C
    PIXEL_MODE_GRAY = 2

    def __init__(self, full, index, units_per_em, ascender, descender):
        if ctypes.sizeof(ctypes.c_void_p) != 8 or ctypes.sizeof(ctypes.c_long) != 8:
            sys.exit("font-reference: libfreetype is read as a 64-bit host has it")
        try:
            self.ft = ctypes.CDLL("libfreetype.so.6")
        except OSError:
            sys.exit("font-reference: libfreetype.so.6 is not installed (freetype2)")
        self.ft.FT_Outline_Translate.argtypes = [ctypes.c_void_p, ctypes.c_long, ctypes.c_long]
        self.ft.FT_Outline_Translate.restype = None
        self.ft.FT_Outline_Transform.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        self.ft.FT_Outline_Transform.restype = None
        self.ft.FT_Outline_Get_CBox.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        self.ft.FT_Outline_Get_CBox.restype = None
        self.ft.FT_Outline_Get_Bitmap.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
        self.ft.FT_Load_Glyph.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int]
        self.ft.FT_New_Face.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_void_p]
        self.library = ctypes.c_void_p()
        if self.ft.FT_Init_FreeType(ctypes.byref(self.library)) != 0:
            sys.exit("font-reference: libfreetype does not start")
        self.face = ctypes.c_void_p()
        if self.ft.FT_New_Face(self.library, os.fsencode(full), index, ctypes.byref(self.face)) != 0:
            sys.exit("font-reference: libfreetype does not open %s" % full)
        if ctypes.c_ushort.from_address(self.face.value + self.FACE_UNITS).value != units_per_em:
            sys.exit("font-reference: libfreetype's face is not laid out as this script reads it")
        self.slot = ctypes.c_void_p.from_address(self.face.value + self.FACE_SLOT).value
        self.ascender = ascender
        self.line = ascender - descender

    def render(self, glyph, rows):
        """A glyph for a line `rows` tall: (left, top, width, a list of rows of bytes).

        The box is cut to the pixels with ink, counted from the point and
        from the line's top; (0, 0, 0, []) for a glyph of none.
        """
        if self.ft.FT_Load_Glyph(self.face, glyph, self.LOAD_NO_SCALE) != 0:
            sys.exit("font-reference: libfreetype does not load glyph %d" % glyph)
        if ctypes.c_uint.from_address(self.slot + self.SLOT_FORMAT).value != self.FORMAT_OUTLINE:
            sys.exit("font-reference: libfreetype's glyph %d is no outline" % glyph)
        outline = self.slot + self.SLOT_OUTLINE
        factor = rows / self.line
        # The units become 64ths of a pixel; the matrix is in 65536ths.
        matrix = (ctypes.c_long * 4)(round(factor * 64 * 65536), 0, 0, round(factor * 64 * 65536))
        self.ft.FT_Outline_Transform(outline, matrix)
        box = (ctypes.c_long * 4)()
        self.ft.FT_Outline_Get_CBox(outline, box)
        if box[0] >= box[2] or box[1] >= box[3]:
            return (0, 0, 0, [])
        # A canvas a pixel wider than the outline to every side. A row of
        # it is a row of the line; libfreetype counts rows upward from
        # the canvas' bottom.
        left = math.floor(box[0] / 64) - 1
        width = math.ceil(box[2] / 64) + 1 - left
        top = math.floor(self.ascender * factor - box[3] / 64) - 1
        height = math.ceil(self.ascender * factor - box[1] / 64) + 1 - top
        self.ft.FT_Outline_Translate(outline, -left * 64, round((top + height - self.ascender * factor) * 64))
        buffer = (ctypes.c_ubyte * (width * height))()
        bitmap = Bitmap(height, width, width, buffer, 256, self.PIXEL_MODE_GRAY, 0, None)
        if self.ft.FT_Outline_Get_Bitmap(self.library, outline, ctypes.byref(bitmap)) != 0:
            sys.exit("font-reference: libfreetype does not render glyph %d" % glyph)
        lines = [bytes(buffer[row * width : (row + 1) * width]) for row in range(height)]
        inked = [row for row in range(height) if any(lines[row])]
        if not inked:
            return (0, 0, 0, [])
        columns = [column for column in range(width) if any(line[column] for line in lines)]
        first, last = columns[0], columns[-1]
        return (left + first, top + inked[0], last - first + 1, [lines[row][first : last + 1] for row in range(inked[0], inked[-1] + 1)])


def read(path, index=0, glyph_step=1, ink_step=0):
    """Everything written of one font, as a dictionary."""
    full = os.path.join(FONTS_DIR, path)
    if not os.path.exists(full):
        sys.exit("font-reference: %s is not there: run scripts/fetch-fonts.sh" % full)
    with open(full, "rb") as file:
        data = file.read()
    # A collection's header says how many fonts it holds and where each
    # one's table directory is; a single font's is at the file's start.
    font_count, directory = 1, 0
    if data[:4] == b"ttcf":
        font_count = struct.unpack_from(">I", data, 8)[0]
        if index >= font_count:
            sys.exit("font-reference: %s has no font %d" % (path, index))
        directory = struct.unpack_from(">I", data, 12 + 4 * index)[0]
    elif index != 0:
        sys.exit("font-reference: %s is one font" % path)
    font = TTFont(full, fontNumber=index, lazy=False)
    head, hhea, post, os2 = font["head"], font["hhea"], font["post"], font["OS/2"]
    outlines = "glyf" in font
    cubic = not outlines and "CFF " in font
    order = font.getGlyphOrder()
    glyphs = font.getGlyphSet() if cubic else None

    # Each glyph's advance, left side bearing and box, in the glyphs' order:
    # of every glyph, or of every `glyph_step`th. A glyph of cubic curves
    # has the box of its points, and its outline goes into a digest of its
    # own: the verbs and the points it has, then each verb's number and
    # points.
    metrics = []
    shapes = []
    outline_hash = hashlib.sha256()
    for glyph_id in range(0, len(order), glyph_step):
        name = order[glyph_id]
        advance, bearing = font["hmtx"].metrics[name]
        if cubic:
            drawn = outline_of(path, glyphs, name)
            box = box_of(drawn)
            count = sum(len(points) for _, points in drawn)
            outline_hash.update(struct.pack("<II", len(drawn), count))
            for verb, points in drawn:
                outline_hash.update(struct.pack("<I", VERBS[verb][1]))
                for x, y in points:
                    outline_hash.update(struct.pack("<ii", x, y))
            if 0 < count <= SHAPE_POINTS:
                shapes.append((glyph_id, "".join(VERBS[verb][0] for verb, _ in drawn), [point for _, points in drawn for point in points]))
        else:
            glyph = font["glyf"][name] if outlines else None
            box = (
                getattr(glyph, "xMin", 0),
                getattr(glyph, "yMin", 0),
                getattr(glyph, "xMax", 0),
                getattr(glyph, "yMax", 0),
            )
        metrics.append((advance, bearing) + box)

    # libfreetype's rendering of the cubic glyphs: the ink of every
    # `ink_step`th, and a few pixel by pixel.
    inks = []
    pictures = []
    if cubic and ink_step > 0:
        renderer = Renderer(full, index, head.unitsPerEm, hhea.ascent, hhea.descent)
        inked = []
        for glyph_id in range(0, len(order), ink_step):
            ink = sum(sum(line) for line in renderer.render(glyph_id, INK_ROWS)[3])
            inks.append(ink)
            if ink > 0:
                inked.append(glyph_id)
        for glyph_id in spread(inked, SAMPLE_PICTURES):
            left, top, width, lines = renderer.render(glyph_id, PICTURE_ROWS)
            pictures.append((glyph_id, left, top, width, ["".join("%x" % round(value * 15 / 255) for value in line) for line in lines]))

    best = font.getBestCmap()
    if best is None:
        sys.exit("font-reference: %s has no Unicode character map" % path)
    best_pairs = pairs_of(font, best)

    # The character map's subtables in the table's order, and the variation
    # sequences of the one subtable that holds them.
    subtables = []
    sequences = []
    selectors = []
    variations = 0
    for subtable in font["cmap"].tables:
        if subtable.format == 14:
            variations += 1
            if variations > 1:
                sys.exit("font-reference: %s has two subtables of variation sequences" % path)
            for selector, entries in subtable.uvsDict.items():
                selectors.append(selector)
                for code, name in entries:
                    # A sequence without a glyph of its own is drawn as its
                    # character is.
                    glyph_name = name if name is not None else best.get(code)
                    glyph = font.getGlyphID(glyph_name) if glyph_name is not None else 0
                    if glyph != 0:
                        sequences.append((selector, code, glyph))
            subtables.append((subtable.platformID, subtable.platEncID, 14, 0, ""))
            continue
        pairs = pairs_of(font, subtable.cmap)
        subtables.append((subtable.platformID, subtable.platEncID, subtable.format, len(pairs), digest("<II", pairs)))
    sequences.sort()
    selectors.sort()

    names = [(i, name_of(font, path, i)) for i in sorted({r.nameID for r in font["name"].names})]
    tables = [(str(tag), entry.offset, entry.length) for tag, entry in font.reader.tables.items()]

    return {
        "file": path,
        "sha256": hashlib.sha256(data).hexdigest(),
        "size": len(data),
        "index": index,
        "font_count": font_count,
        "directory": directory,
        "outlines": outlines,
        "cubic": cubic,
        "glyph_step": glyph_step,
        "glyph_count": font["maxp"].numGlyphs,
        "units_per_em": head.unitsPerEm,
        "ascender": hhea.ascent,
        "descender": hhea.descent,
        "line_gap": hhea.lineGap,
        "x_height": os2.sxHeight if os2.version >= 2 else 0,
        "cap_height": os2.sCapHeight if os2.version >= 2 else 0,
        "underline_position": post.underlinePosition,
        "underline_thickness": post.underlineThickness,
        "strikeout_position": os2.yStrikeoutPosition,
        "strikeout_thickness": os2.yStrikeoutSize,
        "bold": head.macStyle & 1 != 0,
        "italic": head.macStyle & 2 != 0,
        "metrics_sha256": digest("<iiiiii", metrics),
        "outlines_sha256": outline_hash.hexdigest() if cubic else "",
        "shapes": spread(shapes, SAMPLE_SHAPES),
        "ink_rows": INK_ROWS if inks else 0,
        "ink_step": ink_step if inks else 0,
        "inks": inks,
        "picture_rows": PICTURE_ROWS if pictures else 0,
        "pictures": pictures,
        "tables": tables,
        "subtables": subtables,
        "best_count": len(best_pairs),
        "best_sha256": digest("<II", best_pairs),
        "pairs": spread(best_pairs, SAMPLE_PAIRS),
        "selectors": selectors,
        "sequence_count": len(sequences),
        "sequences_sha256": digest("<III", sequences),
        "sequences": spread(sequences, SAMPLE_SEQUENCES),
        "names": names,
    }


def listed(lines, name, rows):
    """A list field: one row a line, or the empty list."""
    if not rows:
        lines.append("    .%s = &.{}," % name)
        return
    lines.append("    .%s = &.{" % name)
    lines.extend("        .{ %s }," % row for row in rows)
    lines.append("    },")


def plain(values):
    """What stands between a list's braces when its values share a line."""
    return ", ".join(values) if len(values) < 2 else " " + ", ".join(values) + " "


def flag(value):
    return "true" if value else "false"


def written(found):
    """The Zig file of one font's values."""
    lines = [
        "// SPDX-License-Identifier: MIT",
        "//! %s" % found["file"]
        + (", font %d of its %d" % (found["index"], found["font_count"]) if found["font_count"] > 1 else ""),
        "//! sha256 %s" % found["sha256"],
        "//!",
        "//! What fontTools reads from that font, as `../reference.zig` says a",
        "//! font's values are written: what truetype.library's host tests",
        "//! compare its reading of the same file with. Written by",
        "//! scripts/font-reference.py and never edited; it is written again when",
        "//! the font's pin in scripts/fetch-fonts.sh changes.",
        "",
        'const reference = @import("../reference.zig");',
        "",
        "pub const font: reference.Font = .{",
        "    .file = %s," % quoted(found["file"]),
        '    .sha256 = "%s",' % found["sha256"],
        "    .size = %d," % found["size"],
        "    .index = %d," % found["index"],
        "    .font_count = %d," % found["font_count"],
        "    .directory = %d," % found["directory"],
        "    .outlines = %s," % flag(found["outlines"]),
        "    .cubic = %s," % flag(found["cubic"]),
        "    .glyph_step = %d," % found["glyph_step"],
    ]
    for field in (
        "glyph_count",
        "units_per_em",
        "ascender",
        "descender",
        "line_gap",
        "x_height",
        "cap_height",
        "underline_position",
        "underline_thickness",
        "strikeout_position",
        "strikeout_thickness",
    ):
        lines.append("    .%s = %d," % (field, found[field]))
    lines.append("    .bold = %s," % flag(found["bold"]))
    lines.append("    .italic = %s," % flag(found["italic"]))
    lines.append('    .metrics_sha256 = "%s",' % found["metrics_sha256"])
    lines.append('    .outlines_sha256 = "%s",' % found["outlines_sha256"])
    listed(
        lines,
        "shapes",
        [
            '.glyph = %d, .verbs = "%s", .points = &.{%s}'
            % (glyph, verbs, plain([".{ %d, %d }" % point for point in points]))
            for glyph, verbs, points in found["shapes"]
        ],
    )
    lines.append("    .ink_rows = %d," % found["ink_rows"])
    lines.append("    .ink_step = %d," % found["ink_step"])
    if found["inks"]:
        # Twelve a line, in columns as `zig fmt` sets a list of several
        # lines: each as wide as its widest number.
        inks = ["%d" % ink for ink in found["inks"]]
        widths = [max(len(ink) for ink in inks[column::12]) for column in range(min(12, len(inks)))]
        lines.append("    .inks = &.{")
        for start in range(0, len(inks), 12):
            row = inks[start : start + 12]
            cells = [(ink + ",").ljust(widths[column] + 1) for column, ink in enumerate(row[:-1])]
            lines.append("        %s," % " ".join(cells + [row[-1]]))
        lines.append("    },")
    else:
        lines.append("    .inks = &.{},")
    lines.append("    .picture_rows = %d," % found["picture_rows"])
    if found["pictures"]:
        lines.append("    .pictures = &.{")
        for glyph, left, top, width, rows in found["pictures"]:
            lines.append("        .{")
            lines.append("            .glyph = %d," % glyph)
            lines.append("            .left = %d," % left)
            lines.append("            .top = %d," % top)
            lines.append("            .width = %d," % width)
            lines.append("            .rows = &.{")
            lines.extend('                "%s",' % row for row in rows)
            lines.append("            },")
            lines.append("        },")
        lines.append("    },")
    else:
        lines.append("    .pictures = &.{},")
    listed(lines, "tables", ['.tag = %s, .at = %d, .len = %d' % (quoted(tag), at, length) for tag, at, length in found["tables"]])
    listed(
        lines,
        "subtables",
        [
            '.platform = %d, .encoding = %d, .format = %d, .count = %d, .sha256 = "%s"' % subtable
            for subtable in found["subtables"]
        ],
    )
    lines.append("    .best_count = %d," % found["best_count"])
    lines.append('    .best_sha256 = "%s",' % found["best_sha256"])
    listed(lines, "pairs", [".code = 0x%04X, .glyph = %d" % pair for pair in found["pairs"]])
    lines.append("    .selectors = &.{%s}," % plain(["0x%04X" % selector for selector in found["selectors"]]))
    lines.append("    .sequence_count = %d," % found["sequence_count"])
    lines.append('    .sequences_sha256 = "%s",' % found["sequences_sha256"])
    listed(
        lines,
        "sequences",
        [".selector = 0x%04X, .code = 0x%04X, .glyph = %d" % sequence for sequence in found["sequences"]],
    )
    listed(lines, "names", [".id = %d, .text = %s" % (name_id, quoted(text)) for name_id, text in found["names"]])
    lines.append("};")
    return "\n".join(lines) + "\n"


def main(arguments):
    check = arguments == ["--check"]
    if arguments and not check:
        sys.exit(__doc__)
    stale = 0
    for path, stem, options in FONTS:
        target = os.path.join(OUT_DIR, stem + ".zig")
        text = written(read(path, **options))
        if check:
            try:
                with open(target, encoding="utf-8") as file:
                    same = file.read() == text
            except FileNotFoundError:
                same = False
            if not same:
                stale += 1
                print("font-reference: %s is not what %s gives" % (os.path.relpath(target, ROOT), path))
            continue
        os.makedirs(OUT_DIR, exist_ok=True)
        with open(target, "w", encoding="utf-8") as file:
            file.write(text)
        print("font-reference: %s" % os.path.relpath(target, ROOT))
    if stale:
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1:])
