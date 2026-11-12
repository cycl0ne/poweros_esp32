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

A variable font is read further, at the places on its axes named with it
below: where each place is, the measures there, and every glyph's measures,
advance and points. fontTools' instancer makes a font of each place, but
writes whole units; the library keeps a point where its deltas put it, to
the last bit of a 32-bit number. So the points are worked out here from the
font's tables as fontTools reads them, step for step in the library's
order, and what comes of it is held against the instancer's font before a
line is written: the coordinates and the measures the same, every advance
the same, every point and every glyph put together of its parts no further
off than a 32-bit number rounds. A place where they differ stops the script.

A variable font of cubic curves (a CFF2 table) has its deltas in the
glyphs' programs. Those are run here as the library runs them - each number
of 32 bits, a number blended by a sum made in 64 - and that goes for the
font's default too, where a program's numbers need not be whole units. The
instancer rounds every number of a program, and a glyph's points are each
given from the one before; so the points are held against fontTools'
drawing of the font at the same coordinates, which rounds nothing, and the
advances and the measures against the instancer's font.

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
import io
import logging
import math
import os
import struct
import sys

try:
    from fontTools.misc.fixedTools import floatToFixed
    from fontTools.pens.recordingPen import RecordingPen
    from fontTools.ttLib import TTFont
    from fontTools.varLib import instancer
    from fontTools.varLib.models import normalizeValue, piecewiseLinearMap
except ImportError:
    sys.exit("font-reference: fontTools is not installed (python-fonttools)")
try:
    from PIL import Image
except ImportError:
    sys.exit("font-reference: Pillow is not installed (python-pillow)")

# What fontTools has to say of a font it reads all the same - more bytes in
# a table than its glyphs take - is not this script's to pass on.
logging.getLogger("fontTools").setLevel(logging.ERROR)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONTS_DIR = os.path.join(ROOT, "toolchain", "fonts")
OUT_DIR = os.path.join(ROOT, "src", "disk", "libs", "truetype", "tests", "reference")

# The fonts read, each as its path under toolchain/fonts, the name of the
# file written for it, and what is its own: which font of a collection it
# is (index), every which glyph is read where another font's values cover
# the same glyphs in full (glyph_step), and every which glyph libfreetype
# renders (ink_step); of a font of pictures the height of the line its
# pictures are scaled to (scaled_rows) and every which glyph's scaled
# picture is added up (scaled_step); of a variable font the places on its
# axes it is read at, each a value by an axis' tag (places).
# reference.zig lists the same files.
FONTS = [
    ("go/Go-Regular.ttf", "go_regular", {}),
    ("liberation-fonts-ttf-2.1.5/LiberationSans-Regular.ttf", "liberation_sans_regular", {}),
    ("noto/NotoSansDevanagari-Regular.ttf", "noto_sans_devanagari_regular", {}),
    ("noto/NotoColorEmoji.ttf", "noto_color_emoji", {"scaled_rows": 20, "scaled_step": 53}),
    ("spleen-2.2.0/spleen-8x16.otb", "spleen_8x16", {"scaled_rows": 24, "scaled_step": 7}),
    ("source-sans/SourceSans3-Regular.otf", "source_sans_3_regular", {"ink_step": 1}),
    (
        "source-sans/SourceSans3VF-Upright.ttf",
        "source_sans_3_vf",
        {"places": [{}, {"wght": 400}, {"wght": 650}, {"wght": 900}, {"wght": 1000}]},
    ),
    (
        "source-sans/SourceSans3VF-Upright.otf",
        "source_sans_3_vf_otf",
        {"ink_step": 1, "places": [{}, {"wght": 400}, {"wght": 650}, {"wght": 900}, {"wght": 1000}]},
    ),
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

# How many scaled pictures are written out beside their sums.
SAMPLE_SCALED = 3

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


def outline_of(path, glyphs, name, blended=None):
    """A glyph of cubic curves as fontTools draws it: its verbs, and its points.

    A list of (verb, points). A contour of one point - a move nothing is
    drawn from - is none. A point is a 32-bit number, as the library has
    it. fontTools adds a program's numbers up in 64 bits, which comes to
    the same where they are whole units: the script stops at a `CFF `
    table that has others. A `CFF2` table has, so its points are
    `blended`'s - the program run in 32 bits - and fontTools' drawing is
    held against each.
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
        drawn.append((verb, list(points)))
    if blended is None:
        for _, points in drawn:
            for x, y in points:
                if x != int(x) or y != int(y):
                    sys.exit("font-reference: %s: glyph %s has a point between whole units" % (path, name))
        return [(verb, [(single(x), single(y)) for x, y in points]) for verb, points in drawn]
    run = blended.contours(name)[0]
    if len(run) != sum(len(points) for _, points in drawn):
        sys.exit("font-reference: %s: glyph %s has %d points, and others by fontTools" % (path, name, len(run)))
    placed = iter(run)
    redrawn = []
    for verb, points in drawn:
        mine = [next(placed)[:2] for _ in points]
        for (x, y), (their_x, their_y) in zip(mine, points):
            held(path, "a point of %s" % name, max(abs(x - their_x), abs(y - their_y)), POINT_APART)
        redrawn.append((verb, mine))
    return redrawn


def box_of(drawn):
    """The box of a drawn glyph's points, control points among them,
    widened to whole units; 0 without one."""
    points = [point for _, points in drawn for point in points]
    if not points:
        return (0, 0, 0, 0)
    return (
        math.floor(min(x for x, _ in points)),
        math.floor(min(y for _, y in points)),
        math.ceil(max(x for x, _ in points)),
        math.ceil(max(y for _, y in points)),
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


def strikes_of(path, font, order):
    """The pictures of a font whose glyphs are bitmaps, as fontTools reads them.

    Whether they are of colour, and for each glyph that has one its largest:
    the strike's pixels an em across and down and its bits a pixel, the
    picture's width and rows, where its left top corner is from the point
    on the baseline, and its pixels - red, green, blue and coverage for
    colour, as Pillow reads the PNG file, a byte of coverage otherwise.
    None for a font without such tables.
    """
    for places, data in (("CBLC", "CBDT"), ("EBLC", "EBDT")):
        if places in font and data in font:
            break
    else:
        return None
    numbers = {name: number for number, name in enumerate(order)}
    found = {}
    for strike, pictures in zip(font[places].strikes, font[data].strikeData):
        size = strike.bitmapSizeTable
        shared = {}
        for table in strike.indexSubTables:
            if hasattr(table, "metrics"):
                shared.update((name, table.metrics) for name in table.names)
        for name, picture in pictures.items():
            glyph_id = numbers[name]
            if glyph_id in found and found[glyph_id][1] >= size.ppemY:
                continue
            measures = getattr(picture, "metrics", None) or shared[name]
            width, rows = measures.width, measures.height
            left = getattr(measures, "BearingX", None)
            top = getattr(measures, "BearingY", None)
            if left is None:
                left, top = measures.horiBearingX, measures.horiBearingY
            form = int(type(picture).__name__.rsplit("_", 1)[1])
            if form == 17:
                image = Image.open(io.BytesIO(picture.imageData))
                if image.size != (width, rows):
                    sys.exit("font-reference: %s: the picture of %s is not the size its measures say" % (path, name))
                pixels = image.convert("RGBA").tobytes()
            elif form == 1:
                depth = size.bitDepth
                stride = (width * depth + 7) // 8
                most = (1 << depth) - 1
                pixels = bytearray()
                for row in range(rows):
                    line = picture.imageData[row * stride : (row + 1) * stride]
                    for column in range(width):
                        bit = column * depth
                        pixels.append(((line[bit // 8] >> (8 - depth - bit % 8)) & most) * 255 // most)
                pixels = bytes(pixels)
            else:
                sys.exit("font-reference: %s: pictures of format %d are not read here" % (path, form))
            found[glyph_id] = (size.ppemX, size.ppemY, size.bitDepth, width, rows, left, top, pixels)
    return places == "CBLC", found


def placed(units_per_em, ascender, descender, line_rows, picture):
    """Where a picture goes on a line `line_rows` tall.

    The whole pixels it touches - left of the point, down from the line's
    top, across and down - then its left top corner within them, and how
    many pixels are drawn for one of its own, across and down. The line's
    em over the strike's is the scale, and the baseline is on a whole row.
    """
    ppem_x, ppem_y, _, width, rows, left, top, _ = picture
    span = ascender - descender
    across = line_rows * units_per_em / (span * ppem_x)
    down = line_rows * units_per_em / (span * ppem_y)
    baseline = math.floor(ascender * line_rows / span + 0.5)
    x0 = left * across
    x1 = x0 + width * across
    y0 = baseline - top * down
    y1 = y0 + rows * down
    snap = 1 / 1024
    box_left = math.floor(x0 + snap)
    box_top = math.floor(y0 + snap)
    box_width = max(math.ceil(x1 - snap) - box_left, 1)
    box_rows = max(math.ceil(y1 - snap) - box_top, 1)
    return box_left, box_top, box_width, box_rows, x0 - box_left, y0 - box_top, across, down


def scaled_of(colour, picture, place):
    """A picture scaled into its box: each pixel the mean over its area.

    What of a pixel's area the picture does not reach counts as nothing.
    Coverage comes out in fifteenths; colour as (red, green, blue,
    coverage), the colour the mean weighted by coverage. Row by row.
    """
    _, _, _, width, rows, _, _, pixels = picture
    _, _, box_width, box_rows, x, y, across, down = place
    each = 4 if colour else 1
    lines = []
    for box_row in range(box_rows):
        top = max((box_row - y) / down, 0)
        bottom = min((box_row + 1 - y) / down, rows)
        line = []
        for box_column in range(box_width):
            left = max((box_column - x) / across, 0)
            right = min((box_column + 1 - x) / across, width)
            cover = 0.0
            sums = [0.0, 0.0, 0.0]
            if bottom > top and right > left:
                for row in range(int(top), rows):
                    if row >= bottom:
                        break
                    tall = min(bottom, row + 1) - max(top, row)
                    for column in range(int(left), width):
                        if column >= right:
                            break
                        share = tall * (min(right, column + 1) - max(left, column))
                        at = (row * width + column) * each
                        if colour:
                            weight = share * pixels[at + 3]
                            cover += weight
                            for channel in range(3):
                                sums[channel] += weight * pixels[at + channel]
                        else:
                            cover += share * pixels[at]
            mean = min(cover * across * down, 255)
            if colour:
                line.append(tuple(min(int(value / cover + 0.5), 255) if cover > 0 else 0 for value in sums) + (int(mean + 0.5),))
            else:
                line.append(int(mean * 15 / 255 + 0.5))
        lines.append(line)
    return lines


# --- a variable font's instances ------------------------------------------------
#
# What a font is at a place on its axes is worked out here from what
# fontTools reads of its tables - the axes, the bends, each glyph's
# groups of deltas, the stores - by the rule reference.zig writes down,
# which is the library's: the sums are taken in the file's order and
# nothing is rounded before a point is placed. fontTools' own
# instancer rounds each point to a whole unit, so its font is not what
# is written; every value is held against it all the same, and the
# script stops when one is further from it than that rounding goes.

# The measures `MVAR` moves, in the order they are written, and each
# one's tag in that table.
MEASURES = ("x_height", "cap_height", "underline_position", "underline_thickness", "strikeout_position", "strikeout_thickness")
MEASURE_TAGS = {"xhgt": 0, "cpht": 1, "undo": 2, "unds": 3, "stro": 4, "strs": 5}

# How many varied glyphs are written out beside their digest, and the
# most points one of those has.
SAMPLE_VARIED = 4
VARIED_POINTS = 12

# The most parts within parts a glyph is followed through.
MAX_DEPTH = 4

# How far a point, in units, and an advance may be from fontTools'
# instance of the font: a point by what 32 bits round away - along a
# glyph of cubic curves too, whose points are each given from the one
# before - and an advance by one, where the instance takes it between
# two rounded sides.
POINT_APART = 1 / 1024
ADVANCE_APART = 1


def single(value):
    """`value` as a number of 32 bits keeps it."""
    return struct.unpack("<f", struct.pack("<f", value))[0]


def bits(value):
    """The 32 bits of a number that `single` gave."""
    return struct.unpack("<I", struct.pack("<f", value))[0]


def whole(value):
    """The whole number nearest, a half upward."""
    return math.floor(value + 0.5)


def normalized(value, lower, middle, upper):
    """A value's distance from the default as a part of the range on its side."""
    if value == middle or lower == upper:
        return 0.0
    if (value < middle and lower != middle) or (value > middle and upper == middle):
        return (value - middle) / (middle - lower)
    return (value - middle) / (upper - middle)


def bent(pairs, value):
    """`value` as an `avar` segment's pairs bend it: straight lines between
    them, and the distance kept outside them."""
    if not pairs:
        return value
    exact = below = above = None
    least = most = pairs[0]
    for start, to in pairs:
        if start == value:
            exact = to
        if start <= least[0]:
            least = (start, to)
        if start >= most[0]:
            most = (start, to)
        if start < value and (below is None or start >= below[0]):
            below = (start, to)
        if start > value and (above is None or start <= above[0]):
            above = (start, to)
    if exact is not None:
        return exact
    if value < least[0]:
        return value + least[1] - least[0]
    if value > most[0]:
        return value + most[1] - most[0]
    if below is None or above is None:
        return value
    return below[1] + (above[1] - below[1]) * (value - below[0]) / (above[0] - below[0])


def factor(value, lower, peak, upper):
    """How much of a region counts at `value` on one axis, all in 16384ths."""
    if peak == 0 or lower > peak or peak > upper or (lower < 0 and upper > 0) or value == peak:
        return 1.0
    if value <= lower or upper <= value:
        return 0.0
    if value < peak:
        return float(value - lower) / float(peak - lower)
    return float(value - upper) / float(peak - upper)


def part_of(coords, region):
    """How much of a region counts at `coords`: `region` a (lower, peak,
    upper) for each axis, in the axes' order."""
    part = 1.0
    for value, (lower, peak, upper) in zip(coords, region):
        part *= factor(value, lower, peak, upper)
        if part == 0:
            return 0.0
    return part


def fourteen(value):
    return int(round(value * 16384))


class Store:
    """An item variation store's deltas at one place."""

    def __init__(self, store, coords):
        self.store = store
        self.parts = [
            part_of(coords, [(fourteen(axis.StartCoord), fourteen(axis.PeakCoord), fourteen(axis.EndCoord)) for axis in region.VarRegionAxis])
            for region in store.VarRegionList.Region
        ]

    def delta(self, index):
        data = self.store.VarData[index >> 16]
        delta = 0.0
        for value, region in zip(data.Item[index & 0xFFFF], data.VarRegionIndex):
            if self.parts[region] != 0:
                delta += float(value) * self.parts[region]
        return delta


def between(place, one, one_delta, other, other_delta):
    """The delta of a coordinate no group names, from the named points
    beside it."""
    low, high, low_delta, high_delta = float(one), float(other), float(one_delta), float(other_delta)
    if low == high:
        return low_delta if low_delta == high_delta else 0.0
    if low > high:
        low, high, low_delta, high_delta = high, low, high_delta, low_delta
    slope = (high_delta - low_delta) / (high - low)
    here = float(place)
    if here <= low:
        return low_delta
    if here >= high:
        return high_delta
    return low_delta + (here - low) * slope


class Instance:
    """One font at one place on its axes."""

    def __init__(self, path, font, coords):
        self.path = path
        self.font = font
        self.glyf = font["glyf"]
        self.metrics = font["hmtx"].metrics
        self.coords = coords
        self.varied = any(coords)
        self.tags = [axis.axisTag for axis in font["fvar"].axes]
        self.variations = font["gvar"].variations if self.varied else {}
        self.sums = {}
        self.advances = None
        if self.varied and "HVAR" in font:
            table = font["HVAR"].table
            self.advances = (Store(table.VarStore, coords), table.AdvWidthMap.mapping if table.AdvWidthMap else None)

    def deltas(self, name):
        """The sums of a glyph's deltas: one for each point or part, and
        four after them."""
        if name in self.sums:
            return self.sums[name]
        glyph = self.glyf[name]
        if glyph.isComposite():
            count, places, ends = len(glyph.components), [], []
        elif glyph.numberOfContours > 0:
            places = list(glyph.coordinates)
            count, ends = len(places), [end + 1 for end in glyph.endPtsOfContours]
        else:
            count, places, ends = 0, [], []
        total = count + 4
        sums = [[0.0, 0.0] for _ in range(total)]
        for group in self.variations.get(name, []):
            region = []
            for tag in self.tags:
                lower, peak, upper = group.axes.get(tag, (0.0, 0.0, 0.0))
                region.append((fourteen(lower), fourteen(peak), fourteen(upper)))
            part = part_of(self.coords, region)
            if part == 0:
                continue
            moved = list(group.coordinates)[:total]
            moved += [None] * (total - len(moved))
            start = 0
            for end in ends:
                self.follow(sums, moved, places, start, end, part)
                start = end
            for index in range(start, total):
                if moved[index] is not None:
                    sums[index][0] += part * float(moved[index][0])
                    sums[index][1] += part * float(moved[index][1])
        self.sums[name] = sums
        return sums

    @staticmethod
    def follow(sums, moved, places, start, end, part):
        """One contour: a named point's delta added, and for each one not
        named the delta it has from the named ones round the contour."""
        named = [index for index in range(start, end) if moved[index] is not None]
        if not named:
            return
        before = named[-1]
        index = start
        while index < end:
            if moved[index] is not None:
                sums[index][0] += part * float(moved[index][0])
                sums[index][1] += part * float(moved[index][1])
                before = index
                index += 1
                continue
            after = index + 1
            while after < end and moved[after] is None:
                after += 1
            beside = after if after < end else named[0]
            for free in range(index, after):
                for axis in (0, 1):
                    sums[free][axis] += part * between(
                        places[free][axis], places[before][axis], moved[before][axis], places[beside][axis], moved[beside][axis]
                    )
            index = after

    def contours(self, name, m, depth, points, ends):
        """A glyph's points added to `points` as (x, y, on) and its
        contours' ends to `ends`, placed by `m`: every step of it a
        number of 32 bits, as the library takes it."""
        glyph = self.glyf[name]
        if glyph.isComposite():
            if depth >= MAX_DEPTH:
                sys.exit("font-reference: %s: %s has parts more than %d deep" % (self.path, name, MAX_DEPTH))
            sums = self.deltas(name)
            for number, part in enumerate(glyph.components):
                dx = dy = 0.0
                # fontTools keeps an offset as x and y, and two points to
                # be laid on each other as firstPt and secondPt.
                if hasattr(part, "x"):
                    dx = single(float(part.x) + sums[number][0])
                    dy = single(float(part.y) + sums[number][1])
                a, b, c, d = 1.0, 0.0, 0.0, 1.0
                if hasattr(part, "transform"):
                    (a, b), (c, d) = ((single(value) for value in row) for row in part.transform)
                own = (
                    single(single(m[0] * a) + single(m[2] * b)),
                    single(single(m[1] * a) + single(m[3] * b)),
                    single(single(m[0] * c) + single(m[2] * d)),
                    single(single(m[1] * c) + single(m[3] * d)),
                    single(single(single(m[0] * dx) + single(m[2] * dy)) + m[4]),
                    single(single(single(m[1] * dx) + single(m[3] * dy)) + m[5]),
                )
                self.contours(part.glyphName, own, depth + 1, points, ends)
            return
        if glyph.numberOfContours <= 0:
            return
        sums = self.deltas(name)
        base = len(points)
        for (x, y), flag, (sum_x, sum_y) in zip(glyph.coordinates, glyph.flags, sums):
            px = single(float(x) + sum_x)
            py = single(float(y) + sum_y)
            points.append(
                (
                    single(single(single(m[0] * px) + single(m[2] * py)) + m[4]),
                    single(single(single(m[1] * px) + single(m[3] * py)) + m[5]),
                    flag & 1,
                )
            )
        ends.extend(base + end + 1 for end in glyph.endPtsOfContours)

    def left_of(self, name):
        """The x of a glyph's left side as the file has it."""
        return getattr(self.glyf[name], "xMin", 0) - self.metrics[name][1]

    def sides_advance(self, name):
        """A glyph's advance by its two side points."""
        stated = self.metrics[name][0]
        if not self.varied:
            return stated
        glyph = self.glyf[name]
        count = len(glyph.components) if glyph.isComposite() else len(glyph.coordinates) if glyph.numberOfContours > 0 else 0
        sums = self.deltas(name)
        left = float(self.left_of(name)) + sums[count][0]
        right = float(self.left_of(name) + stated) + sums[count + 1][0]
        return max(0, whole(right - left))

    def advance(self, name, glyph_id):
        """A glyph's advance: by `HVAR` where the font has it."""
        stated = self.metrics[name][0]
        if not self.varied:
            return stated
        if self.advances is None:
            return self.sides_advance(name)
        store, mapping = self.advances
        return max(0, stated + whole(store.delta(mapping[name] if mapping else glyph_id)))

    def measures(self, name, glyph_id):
        """A glyph's advance, left side bearing and box, and its points."""
        points, ends = [], []
        self.contours(name, (1.0, 0.0, 0.0, 1.0, 0.0, 0.0), 0, points, ends)
        advance = self.advance(name, glyph_id)
        if not self.varied:
            glyph = self.glyf[name]
            box = (glyph.xMin, glyph.yMin, glyph.xMax, glyph.yMax) if glyph.numberOfContours else (0, 0, 0, 0)
            return (advance, self.metrics[name][1]) + box, points, ends
        glyph = self.glyf[name]
        count = len(glyph.components) if glyph.isComposite() else len(glyph.coordinates) if glyph.numberOfContours > 0 else 0
        origin = whole(float(self.left_of(name)) + self.deltas(name)[count][0])
        if not points:
            return (advance, -origin, 0, 0, 0, 0), points, ends
        x_min = math.floor(min(point[0] for point in points))
        y_min = math.floor(min(point[1] for point in points))
        x_max = math.ceil(max(point[0] for point in points))
        y_max = math.ceil(max(point[1] for point in points))
        return (advance, x_min - origin, x_min, y_min, x_max, y_max), points, ends


def bias_of(count):
    """What a subroutine's number is counted from, by how many there are."""
    return 107 if count < 1240 else 1131 if count < 33900 else 32768


class Blended:
    """One font of cubic curves (`CFF2`) at one place on its axes.

    A glyph's program is run the way truetype.library runs it: every
    number and every point a 32-bit one, a number blended by a sum made
    in 64 bits, its deltas in their order. The programs are fontTools'
    reading of them, number by number; an operator the fetched fonts do
    not use stops the script, which has no rule for it.
    """

    STACK = 513
    CALLS = 10
    FAR = 16777216.0
    POINTS = 0xFFFF

    def __init__(self, path, font, coords):
        self.path = path
        self.metrics = font["hmtx"].metrics
        self.varied = any(coords)
        table = font["CFF2"].cff
        top = table.topDictIndex[0]
        self.programs = top.CharStrings
        self.fonts = top.FDArray
        self.shared = table.GlobalSubrs
        # How much each region of each of the store's data counts here:
        # nothing at the default. A table without a store has no deltas.
        store = getattr(top, "VarStore", None)
        self.parts = None
        if store is not None:
            counted = Store(store.otVarStore, coords).parts
            self.parts = [[counted[region] if self.varied else 0.0 for region in data.VarRegionIndex] for data in store.otVarStore.VarData]
        self.advances = None
        if self.varied and "HVAR" in font:
            table = font["HVAR"].table
            self.advances = (Store(table.VarStore, coords), table.AdvWidthMap.mapping if table.AdvWidthMap else None)
        self.read = {}

    def stop(self, name, what):
        sys.exit("font-reference: %s: the program of %s has %s, which this script has no rule for" % (self.path, name, what))

    def vary(self, data):
        """The deltas are for the regions of the store's data `data` from here on."""
        if self.parts is None:
            self.regions = []
        else:
            self.regions = self.parts[data] if data < len(self.parts) else None

    def add(self, name, on):
        x = single(single(self.x + single(0.0 * self.y)) + 0.0)
        y = single(single(single(0.0 * self.x) + self.y) + 0.0)
        if not (-self.FAR <= x <= self.FAR and -self.FAR <= y <= self.FAR) or len(self.points) == self.POINTS:
            self.stop(name, "a point too far out, or too many")
        self.points.append((x, y, on))

    def begin(self, name):
        self.drawing = True
        self.first = len(self.points)
        self.add(name, 1)

    def finish(self):
        """The contour being drawn ended; one of a single point is none."""
        if not self.drawing:
            return
        self.drawing = False
        if len(self.points) - self.first < 2:
            del self.points[self.first :]
            return
        self.ends.append(len(self.points))

    def move(self, name, dx, dy):
        self.finish()
        self.x = single(self.x + dx)
        self.y = single(self.y + dy)
        self.begin(name)

    def line(self, name, dx, dy):
        if not self.drawing:
            self.begin(name)
        self.x = single(self.x + dx)
        self.y = single(self.y + dy)
        self.add(name, 1)

    def curve(self, name, dx1, dy1, dx2, dy2, dx3, dy3):
        if not self.drawing:
            self.begin(name)
        for dx, dy, on in ((dx1, dy1, 0), (dx2, dy2, 0), (dx3, dy3, 1)):
            self.x = single(self.x + dx)
            self.y = single(self.y + dy)
            self.add(name, on)

    def count_of(self, name, value):
        """A number that counts: a whole one."""
        if value != int(value):
            self.stop(name, "a count between whole numbers")
        return int(value)

    def interpret(self, name, program, nesting):
        """`program` run to its end; false once the glyph is ended."""
        if program.needsDecompilation():
            self.stop(name, "a subroutine fontTools has not read")
        s = self.stack
        for token in program.program:
            if isinstance(token, (int, float)):
                if len(s) == self.STACK:
                    self.stop(name, "more numbers than a program holds")
                s.append(single(float(token)))
                continue
            depth = len(s)
            if token in ("callsubr", "callgsubr"):
                if depth < 1 or nesting == self.CALLS:
                    self.stop(name, "a call it cannot make")
                subrs = self.locals if token == "callsubr" else self.shared
                number = self.count_of(name, s.pop()) + bias_of(len(subrs))
                if not 0 <= number < len(subrs):
                    self.stop(name, "a call of a subroutine that is not there")
                self.interpret(name, subrs[number], nesting + 1)
                continue
            if token == "vsindex":
                if depth < 1 or s[-1] < 0:
                    self.stop(name, "a vsindex without its number")
                self.vary(self.count_of(name, s[-1]))
                del s[:]
                continue
            if token == "blend":
                if depth < 1 or self.regions is None:
                    self.stop(name, "a blend without its deltas")
                count = self.count_of(name, s[-1])
                regions = len(self.regions)
                if count < 0 or count > depth - 1 or (regions != 0 and count > (depth - 1 - count) // regions):
                    self.stop(name, "a blend of more numbers than there are")
                base = depth - 1 - count * (regions + 1)
                for number in range(count):
                    total = 0.0
                    for index, part in enumerate(self.regions):
                        total += float(s[base + count + number * regions + index]) * part
                    s[base + number] = single(float(s[base + number]) + total)
                del s[base + count :]
                continue
            if token == "rmoveto" and depth >= 2:
                self.move(name, s[-2], s[-1])
            elif token == "hmoveto" and depth >= 1:
                self.move(name, s[-1], 0.0)
            elif token == "vmoveto" and depth >= 1:
                self.move(name, 0.0, s[-1])
            elif token == "rlineto":
                for i in range(0, depth - 1, 2):
                    self.line(name, s[i], s[i + 1])
            elif token in ("hlineto", "vlineto"):
                level = token == "hlineto"
                for by in s:
                    self.line(name, by if level else 0.0, 0.0 if level else by)
                    level = not level
            elif token == "rrcurveto":
                for i in range(0, depth - 5, 6):
                    self.curve(name, *s[i : i + 6])
            elif token == "rcurveline":
                i = 0
                while i + 8 <= depth:
                    self.curve(name, *s[i : i + 6])
                    i += 6
                if i + 2 <= depth:
                    self.line(name, s[i], s[i + 1])
            elif token == "rlinecurve":
                i = 0
                while i + 8 <= depth:
                    self.line(name, s[i], s[i + 1])
                    i += 2
                if i + 6 <= depth:
                    self.curve(name, *s[i : i + 6])
            elif token in ("vvcurveto", "hhcurveto"):
                i = depth % 2
                across = s[0] if i == 1 else 0.0
                while i + 4 <= depth:
                    if token == "vvcurveto":
                        self.curve(name, across, s[i], s[i + 1], s[i + 2], 0.0, s[i + 3])
                    else:
                        self.curve(name, s[i], across, s[i + 1], s[i + 2], s[i + 3], 0.0)
                    across = 0.0
                    i += 4
            elif token in ("vhcurveto", "hvcurveto"):
                level = token == "hvcurveto"
                i = 0
                while i + 4 <= depth:
                    off = s[i + 4] if depth - i == 5 else 0.0
                    if level:
                        self.curve(name, s[i], 0.0, s[i + 1], s[i + 2], off, s[i + 3])
                    else:
                        self.curve(name, 0.0, s[i], s[i + 1], s[i + 2], s[i + 3], off)
                    level = not level
                    i += 4
            else:
                self.stop(name, "%r with %d numbers" % (token, depth))
            del s[:]

    def contours(self, name):
        """A glyph's points - x, y, and whether on its curve - and where
        its contours end."""
        if name in self.read:
            return self.read[name]
        program, selected = self.programs.getItemAndSelector(name)
        private = self.fonts[selected or 0].Private
        program.decompile()
        self.locals = getattr(private, "Subrs", [])
        self.x = self.y = 0.0
        self.points, self.ends, self.stack = [], [], []
        self.drawing, self.first = False, 0
        self.vary(getattr(private, "vsindex", 0))
        self.interpret(name, program, 0)
        self.finish()
        self.read[name] = (self.points, self.ends)
        return self.read[name]

    def sides_advance(self, name):
        """A glyph's advance in a font without `HVAR`: its table's, at
        every place."""
        return self.metrics[name][0]

    advance = Instance.advance

    def measures(self, name, glyph_id):
        """A glyph's advance, left side bearing and box, and its points.
        Away from the default the bearing is the left of the box."""
        points, ends = self.contours(name)
        box = (0, 0, 0, 0)
        if ends:
            box = (
                math.floor(min(point[0] for point in points)),
                math.floor(min(point[1] for point in points)),
                math.ceil(max(point[0] for point in points)),
                math.ceil(max(point[1] for point in points)),
            )
        bearing = box[0] if self.varied else self.metrics[name][1]
        return (self.advance(name, glyph_id), bearing) + box, points, ends


def drawn_of(path, glyphs, name):
    """A glyph of cubic curves as fontTools draws it at a place: its
    points, each on its curve or off it, and where its contours end. A
    contour of one point is none."""
    pen = RecordingPen()
    glyphs[name].draw(pen)
    points, ends, first = [], [], 0
    for verb, at in pen.value:
        if verb == "moveTo":
            first = len(points)
            points.append(at[0] + (1,))
        elif verb == "lineTo":
            points.append(at[0] + (1,))
        elif verb == "curveTo" and len(at) == 3:
            points.extend((at[0] + (0,), at[1] + (0,), at[2] + (1,)))
        elif verb == "closePath":
            if len(points) - first < 2:
                del points[first:]
            else:
                ends.append(len(points))
        else:
            sys.exit("font-reference: %s: glyph %s is drawn with %s" % (path, name, verb))
    return points, ends


def place_of(font, asked):
    """Where `asked`, a value by an axis' tag, puts the font: each axis'
    value, cut to its range, and its coordinate in 16384ths."""
    values, coords = [], []
    bends = font["avar"].segments if "avar" in font else {}
    for axis in font["fvar"].axes:
        value = min(max(float(asked.get(axis.axisTag, axis.defaultValue)), axis.minValue), axis.maxValue)
        pairs = list(bends.get(axis.axisTag, {}).items())
        coord = whole(bent(pairs, normalized(value, axis.minValue, axis.defaultValue, axis.maxValue)) * 16384.0)
        values.append(value)
        coords.append(max(-16384, min(16384, coord)))
    return values, coords


def held(path, what, apart, most):
    """Stops when fontTools' instancer is further off than its rounding goes."""
    if apart > most:
        sys.exit("font-reference: %s: %s is %r from fontTools' instance of the font, more than %r" % (path, what, apart, most))


def instances_of(path, font, resting, places):
    """A variable font's axes, the instances it names, and what it is at
    each of `places`; `resting` its measures as its tables have them."""
    if "fvar" not in font:
        if places:
            sys.exit("font-reference: %s has no axes" % path)
        return [], [], []
    cubic = "CFF2" in font
    if not cubic and ("glyf" not in font or "gvar" not in font):
        sys.exit("font-reference: %s: a font is read at an instance by its glyf and gvar tables, or by CFF2" % path)
    fvar = font["fvar"]
    order = font.getGlyphOrder()
    axes = [(axis.axisTag, axis.minValue, axis.defaultValue, axis.maxValue, axis.axisNameID, axis.flags & 1 != 0) for axis in fvar.axes]
    named = [(one.subfamilyNameID, [one.coordinates[axis.axisTag] for axis in fvar.axes]) for one in fvar.instances]
    found = []
    for asked in places:
        values, coords = place_of(font, asked)
        instance = Blended(path, font, coords) if cubic else Instance(path, font, coords)
        what = "%s at %r" % (path, asked)

        # The place, as fontTools counts it.
        for axis, value, coord in zip(fvar.axes, values, coords):
            theirs = normalizeValue(value, (axis.minValue, axis.defaultValue, axis.maxValue))
            if "avar" in font:
                theirs = piecewiseLinearMap(theirs, font["avar"].segments[axis.axisTag])
            if floatToFixed(theirs, 14) != coord:
                sys.exit("font-reference: %s: axis %s is at %d, and at %d by fontTools" % (what, axis.axisTag, coord, floatToFixed(theirs, 14)))

        # The measures `MVAR` moves.
        measures = [resting[name] for name in MEASURES]
        if instance.varied and "MVAR" in font:
            table = font["MVAR"].table
            store = Store(table.VarStore, coords)
            for record in table.ValueRecord:
                if record.ValueTag in MEASURE_TAGS:
                    measures[MEASURE_TAGS[record.ValueTag]] += whole(store.delta(record.VarIdx))

        # fontTools' font of the same place: its points are not rounded
        # until it is written.
        static = None
        if instance.varied:
            static = instancer.instantiateVariableFont(
                TTFont(os.path.join(FONTS_DIR, path), lazy=False), {axis.axisTag: value for axis, value in zip(fvar.axes, values)}
            )
            theirs = [
                static["OS/2"].sxHeight,
                static["OS/2"].sCapHeight,
                static["post"].underlinePosition,
                static["post"].underlineThickness,
                static["OS/2"].yStrikeoutPosition,
                static["OS/2"].yStrikeoutSize,
            ]
            if theirs != measures:
                sys.exit("font-reference: %s: the measures are %r, and %r by fontTools" % (what, measures, theirs))

        # fontTools' drawing of a font of cubic curves at the coordinates:
        # its instance of the font has every number of a program rounded,
        # and a glyph's points are each given from the one before.
        drawn = None
        if cubic:
            drawn = font.getGlyphSet(location={axis.axisTag: coord / 16384.0 for axis, coord in zip(fvar.axes, coords)}, normalized=True)

        metrics, sides, simple, composite = [], [], [], []
        shapes = hashlib.sha256()
        for glyph_id, name in enumerate(order):
            measured, points, ends = instance.measures(name, glyph_id)
            metrics.append(measured)
            sides.append((instance.sides_advance(name),))
            shapes.update(struct.pack("<II", len(points), len(ends)))
            for x, y, on in points:
                shapes.update(struct.pack("<III", bits(x), bits(y), on))
            for end in ends:
                shapes.update(struct.pack("<I", end))
            if cubic:
                if 0 < len(points) <= VARIED_POINTS:
                    simple.append((glyph_id, ends, points))
                their_points, their_ends = drawn_of(path, drawn, name)
                if len(points) != len(their_points) or ends != their_ends:
                    sys.exit("font-reference: %s: %s has %d points in %d contours, and %d in %d by fontTools" % (what, name, len(points), len(ends), len(their_points), len(their_ends)))
                for (x, y, on), (their_x, their_y, their_on) in zip(points, their_points):
                    if on != their_on:
                        sys.exit("font-reference: %s: %s has a point on its curve that fontTools has off it" % (what, name))
                    held(path, "%s, a point of %s" % (what, name), max(abs(x - their_x), abs(y - their_y)), POINT_APART)
                if static is not None:
                    their_advance = static["hmtx"].metrics[name][0]
                    held(path, "%s, the advance of %s" % (what, name), abs(measured[0] - their_advance), ADVANCE_APART)
                continue
            glyph = font["glyf"][name]
            if 0 < len(points) <= VARIED_POINTS:
                (composite if glyph.isComposite() else simple).append((glyph_id, ends, points))
            if glyph.isComposite():
                # The glyph as fontTools puts it together of its parts.
                table = (font if static is None else static)["glyf"]
                joined = table[name].getCoordinates(table)[0]
                if len(points) != len(joined):
                    sys.exit("font-reference: %s: %s has %d points, and %d by fontTools" % (what, name, len(points), len(joined)))
                for (x, y, _), (their_x, their_y) in zip(points, joined):
                    held(path, "%s, a point of %s put together" % (what, name), abs(x - their_x), POINT_APART)
                    held(path, "%s, a point of %s put together" % (what, name), abs(y - their_y), POINT_APART)
            if static is None:
                continue
            theirs = static["glyf"][name]
            if glyph.isComposite():
                sums = instance.deltas(name)
                for number, (part, other) in enumerate(zip(glyph.components, theirs.components)):
                    if hasattr(part, "x"):
                        held(path, "%s, part %d of %s" % (what, number, name), abs(part.x + sums[number][0] - other.x), POINT_APART)
                        held(path, "%s, part %d of %s" % (what, number, name), abs(part.y + sums[number][1] - other.y), POINT_APART)
            elif glyph.numberOfContours > 0:
                if len(points) != len(theirs.coordinates):
                    sys.exit("font-reference: %s: %s has %d points, and %d by fontTools" % (what, name, len(points), len(theirs.coordinates)))
                for (x, y, _), (their_x, their_y) in zip(points, theirs.coordinates):
                    held(path, "%s, a point of %s" % (what, name), max(abs(x - their_x), abs(y - their_y)), POINT_APART)
            their_advance = static["hmtx"].metrics[name][0]
            held(path, "%s, the advance of %s" % (what, name), abs(measured[0] - their_advance), ADVANCE_APART)
            held(path, "%s, the advance of %s by its sides" % (what, name), abs(sides[-1][0] - their_advance), ADVANCE_APART)
        found.append(
            {
                "asked": sorted(asked.items()),
                "values": values,
                "coords": coords,
                "measures": measures,
                "metrics_sha256": digest("<iiiiii", metrics),
                "sides_sha256": digest("<i", sides),
                "contours_sha256": shapes.hexdigest(),
                "shapes": spread(simple, SAMPLE_VARIED) if cubic else spread(simple, SAMPLE_VARIED - SAMPLE_VARIED // 2) + spread(composite, SAMPLE_VARIED // 2),
            }
        )
    return axes, named, found


def number(value):
    """A number as Zig reads it back to the same 32 bits."""
    return "%d" % value if value == int(value) and (value != 0 or math.copysign(1, value) > 0) else repr(value)


def placed_lines(lines, found):
    """The fields of a variable font: its axes, the instances it names,
    and what it is at each place read."""
    listed(
        lines,
        "axes",
        [
            ".tag = %s, .minimum = %s, .default = %s, .maximum = %s, .name = %d, .hidden = %s"
            % (quoted(tag), number(lower), number(middle), number(upper), name, flag(hidden))
            for tag, lower, middle, upper, name, hidden in found["axes"]
        ],
    )
    listed(lines, "named", [".name = %d, .values = &.{%s}" % (name, plain([number(value) for value in values])) for name, values in found["named"]])
    lines.append("    .instances = &.{")
    for instance in found["instances"]:
        lines.append("        .{")
        asked = [".{ .tag = %s, .value = %s }" % (quoted(tag), number(value)) for tag, value in instance["asked"]]
        lines.append("            .asked = &.{%s}," % plain(asked))
        lines.append("            .values = &.{%s}," % plain([number(value) for value in instance["values"]]))
        lines.append("            .coords = &.{%s}," % plain(["%d" % coord for coord in instance["coords"]]))
        for name, value in zip(MEASURES, instance["measures"]):
            lines.append("            .%s = %d," % (name, value))
        lines.append('            .metrics_sha256 = "%s",' % instance["metrics_sha256"])
        lines.append('            .sides_sha256 = "%s",' % instance["sides_sha256"])
        lines.append('            .contours_sha256 = "%s",' % instance["contours_sha256"])
        lines.append("            .shapes = &.{")
        for glyph, ends, points in instance["shapes"]:
            lines.append("                .{")
            lines.append("                    .glyph = %d," % glyph)
            lines.append("                    .ends = &.{%s}," % plain(["%d" % end for end in ends]))
            lines.append("                    .points = &.{")
            lines.extend("                        .{ .x = %s, .y = %s, .on = %s }," % (number(x), number(y), flag(on)) for x, y, on in points)
            lines.append("                    },")
            lines.append("                },")
        lines.append("            },")
        lines.append("        },")
    lines.append("    },")


def read(path, index=0, glyph_step=1, ink_step=0, scaled_rows=0, scaled_step=0, places=()):
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
    outlines = "glyf" in font and font.reader.tables["glyf"].length > 0
    cubic = not outlines and ("CFF " in font or "CFF2" in font)
    order = font.getGlyphOrder()
    strikes = None if outlines or cubic else strikes_of(path, font, order)
    glyphs = font.getGlyphSet() if cubic else None
    blended = Blended(path, font, [0] * len(font["fvar"].axes)) if cubic and "CFF2" in font and "fvar" in font else None

    # Each glyph's advance, left side bearing and box, in the glyphs' order:
    # of every glyph, or of every `glyph_step`th. A glyph of cubic curves
    # has the box of its points, and its outline goes into a digest of its
    # own: the verbs and the points it has, then each verb's number and
    # points. A glyph that is a picture has the box of its largest one, in
    # units, widened to whole ones.
    metrics = []
    shapes = []
    outline_hash = hashlib.sha256()
    for glyph_id in range(0, len(order), glyph_step):
        name = order[glyph_id]
        advance, bearing = font["hmtx"].metrics[name]
        if cubic:
            drawn = outline_of(path, glyphs, name, blended)
            box = box_of(drawn)
            count = sum(len(points) for _, points in drawn)
            outline_hash.update(struct.pack("<II", len(drawn), count))
            for verb, points in drawn:
                outline_hash.update(struct.pack("<I", VERBS[verb][1]))
                for x, y in points:
                    outline_hash.update(struct.pack("<II", bits(x), bits(y)))
            if 0 < count <= SHAPE_POINTS:
                shapes.append((glyph_id, "".join(VERBS[verb][0] for verb, _ in drawn), [point for _, points in drawn for point in points]))
        elif strikes and glyph_id in strikes[1]:
            ppem_x, ppem_y, _, width, rows, left, top, _ = strikes[1][glyph_id]
            box = (
                left * head.unitsPerEm // ppem_x,
                (top - rows) * head.unitsPerEm // ppem_y,
                -(-(left + width) * head.unitsPerEm // ppem_x),
                -(-top * head.unitsPerEm // ppem_y),
            )
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

    # The pictures of a font of them: each one's measures and its pixels
    # hashed, by the glyph's number; and scaled to a line `scaled_rows`
    # tall, the sum of every `scaled_step`th glyph's coverage and a few
    # pixel by pixel.
    strike_measures = []
    strike_pixels = hashlib.sha256()
    scaled_inks = []
    scaled = []
    if strikes:
        colour, found = strikes
        for glyph_id in sorted(found):
            picture = found[glyph_id]
            strike_measures.append((glyph_id,) + picture[:7])
            strike_pixels.update(struct.pack("<I", glyph_id))
            strike_pixels.update(picture[7])
        if scaled_rows > 0 and scaled_step > 0:
            shown = []
            for glyph_id in range(0, len(order), scaled_step):
                if glyph_id not in found:
                    scaled_inks.append(0)
                    continue
                place = placed(head.unitsPerEm, hhea.ascent, hhea.descent, scaled_rows, found[glyph_id])
                lines = scaled_of(colour, found[glyph_id], place)
                ink = sum(sum(pixel[3] if colour else pixel for pixel in line) for line in lines)
                scaled_inks.append(ink)
                if ink > 0:
                    shown.append((glyph_id, place[0], place[1], place[2], lines))
            for glyph_id, left, top, width, lines in spread(shown, SAMPLE_SCALED):
                form = "%02x%02x%02x%02x" if colour else "%x"
                scaled.append((glyph_id, left, top, width, ["".join(form % pixel for pixel in line) for line in lines]))

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

    found = {
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
        "strikes": bool(strikes),
        "strike_colour": bool(strikes) and strikes[0],
        "strike_count": len(strike_measures),
        "strike_measures_sha256": digest("<IIIIIIii", strike_measures) if strikes else "",
        "strike_pixels_sha256": strike_pixels.hexdigest() if strikes else "",
        "scaled_rows": scaled_rows if scaled_inks else 0,
        "scaled_step": scaled_step if scaled_inks else 0,
        "scaled_inks": scaled_inks,
        "scaled": scaled,
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
    found["axes"], found["named"], found["instances"] = instances_of(path, font, found, places)
    return found


def listed(lines, name, rows):
    """A list field: one row a line, or the empty list."""
    if not rows:
        lines.append("    .%s = &.{}," % name)
        return
    lines.append("    .%s = &.{" % name)
    lines.extend("        .{ %s }," % row for row in rows)
    lines.append("    },")


def numbered(lines, name, values):
    """A list of numbers: twelve a line, in columns as `zig fmt` sets a list
    of several lines, each as wide as its widest number."""
    if not values:
        lines.append("    .%s = &.{}," % name)
        return
    cells = ["%d" % value for value in values]
    widths = [max(len(cell) for cell in cells[column::12]) for column in range(min(12, len(cells)))]
    lines.append("    .%s = &.{" % name)
    for start in range(0, len(cells), 12):
        row = cells[start : start + 12]
        padded = [(cell + ",").ljust(widths[column] + 1) for column, cell in enumerate(row[:-1])]
        lines.append("        %s," % " ".join(padded + [row[-1]]))
    lines.append("    },")


def drawn(lines, name, pictures):
    """A list of glyphs written out pixel by pixel."""
    if not pictures:
        lines.append("    .%s = &.{}," % name)
        return
    lines.append("    .%s = &.{" % name)
    for glyph, left, top, width, rows in pictures:
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
            % (glyph, verbs, plain([".{ %s, %s }" % (number(x), number(y)) for x, y in points]))
            for glyph, verbs, points in found["shapes"]
        ],
    )
    lines.append("    .ink_rows = %d," % found["ink_rows"])
    lines.append("    .ink_step = %d," % found["ink_step"])
    numbered(lines, "inks", found["inks"])
    lines.append("    .picture_rows = %d," % found["picture_rows"])
    drawn(lines, "pictures", found["pictures"])
    lines.append("    .strikes = %s," % flag(found["strikes"]))
    lines.append("    .strike_colour = %s," % flag(found["strike_colour"]))
    lines.append("    .strike_count = %d," % found["strike_count"])
    lines.append('    .strike_measures_sha256 = "%s",' % found["strike_measures_sha256"])
    lines.append('    .strike_pixels_sha256 = "%s",' % found["strike_pixels_sha256"])
    lines.append("    .scaled_rows = %d," % found["scaled_rows"])
    lines.append("    .scaled_step = %d," % found["scaled_step"])
    numbered(lines, "scaled_inks", found["scaled_inks"])
    drawn(lines, "scaled", found["scaled"])
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
    if found["axes"]:
        placed_lines(lines, found)
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
