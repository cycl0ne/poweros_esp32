#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""What fontTools reads from the fetched fonts, written as Zig for the host tests.

truetype.library's host tests read the fonts scripts/fetch-fonts.sh fetches
and compare what they find with what another reader of fonts finds. This is
that other reader: fontTools opens each font named below, and what it says
of the font - its tables, its measures, every character map, the variation
sequences, the names, each glyph's measures - is written as a Zig file in
src/disk/libs/truetype/tests/reference/, headed by the font's file name and
its SHA-256. src/disk/libs/truetype/tests/reference.zig says what each value
is and how the long ones are counted and hashed; the same rule is applied
here and there, so a digest that differs is a reading that differs.

The files are committed, and the tests need neither Python nor fontTools. A
test stops by name when its font's SHA-256 is not the one written here, so
this runs again when a font's pin in scripts/fetch-fonts.sh changes, and at
no other time.

  python3 -I scripts/font-reference.py           write the files
  python3 -I scripts/font-reference.py --check   say whether they are as it would write them

The fonts are files from elsewhere: -I keeps Python from loading anything
that lies beside them or beside this script.
"""

import hashlib
import os
import struct
import sys

try:
    from fontTools.ttLib import TTFont
except ImportError:
    sys.exit("font-reference: fontTools is not installed (python-fonttools)")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONTS_DIR = os.path.join(ROOT, "toolchain", "fonts")
OUT_DIR = os.path.join(ROOT, "src", "disk", "libs", "truetype", "tests", "reference")

# The fonts read, each as its path under toolchain/fonts and the name of the
# file written for it. reference.zig lists the same files.
FONTS = [
    ("go/Go-Regular.ttf", "go_regular"),
    ("liberation-fonts-ttf-2.1.5/LiberationSans-Regular.ttf", "liberation_sans_regular"),
    ("noto/NotoSansDevanagari-Regular.ttf", "noto_sans_devanagari_regular"),
    ("noto/NotoColorEmoji.ttf", "noto_color_emoji"),
]

# How many values of a long list are written out beside its digest.
SAMPLE_PAIRS = 12
SAMPLE_SEQUENCES = 8


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


def read(path):
    """Everything written of one font, as a dictionary."""
    full = os.path.join(FONTS_DIR, path)
    if not os.path.exists(full):
        sys.exit("font-reference: %s is not there: run scripts/fetch-fonts.sh" % full)
    with open(full, "rb") as file:
        data = file.read()
    font = TTFont(full, lazy=False)
    head, hhea, post, os2 = font["head"], font["hhea"], font["post"], font["OS/2"]
    outlines = "glyf" in font
    order = font.getGlyphOrder()

    # Each glyph's advance, left side bearing and box, in the glyphs' order.
    metrics = []
    for name in order:
        advance, bearing = font["hmtx"].metrics[name]
        glyph = font["glyf"][name] if outlines else None
        metrics.append((
            advance,
            bearing,
            getattr(glyph, "xMin", 0),
            getattr(glyph, "yMin", 0),
            getattr(glyph, "xMax", 0),
            getattr(glyph, "yMax", 0),
        ))

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
        "outlines": outlines,
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
        "//! %s" % found["file"],
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
        "    .outlines = %s," % flag(found["outlines"]),
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
    for path, stem in FONTS:
        target = os.path.join(OUT_DIR, stem + ".zig")
        text = written(read(path))
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
