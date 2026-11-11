#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Texts shaped with the fetched fonts by HarfBuzz, written as Zig for the host tests.

truetypeshaping.library's host tests shape texts with the fonts
scripts/fetch-fonts.sh fetches and compare what comes out - each glyph, its
cluster, its advance and its offsets - with what the system's libharfbuzz
gives for the same text. This asks libharfbuzz, through ctypes, and writes
the answers down.

The two are asked the same thing: positions in the font's own units, a
cluster for each character (HarfBuzz's cluster level 1), and the characters
a text does not show taken out. HarfBuzz gets the script and the direction
said; ShapeText finds the script itself, so a text here is of one script.

Where the two shape by different rules a text shows nothing, and the cases
keep away from it:

  - HarfBuzz puts a letter and a mark behind it together where the font has
    the one character for the two, and takes apart a character the font
    lacks. The marks here stand behind letters there is no such character
    for.
  - In a font without GPOS HarfBuzz sets a mark by its outline's box. The
    fonts without GPOS get no marks.
  - HarfBuzz mirrors brackets in a text read from right to left, makes
    fractions around U+2044, and makes up the spaces a font lacks.
  - For some scripts HarfBuzz has a model of the script: syllables put in
    order, forms picked by the place in a word. Such a text is given to it
    as one of no script, with the tag the font lists the script under said
    in the language ("x-hbscdev2"), which is how HarfBuzz is told to shape
    it by its features alone - as ShapeText shapes it.
  - Of a character whose bytes are cut short, or one UTF-8 forbids,
    HarfBuzz makes a U+FFFD for each byte and ShapeText one for them all.
    The bytes here that are no UTF-8 stand alone.
  - HarfBuzz lets a sequence end at the grapheme joiner (U+034F) where it
    stands between marks it keeps from changing places. No mark stands
    beside the one here.

The files are committed, and the tests need neither Python nor libharfbuzz.
A test stops by name when its font's SHA-256 is not the one written here, so
this runs again when a font's pin in scripts/fetch-fonts.sh changes or a
case is added. The version of libharfbuzz that answered stands in each file.

  python3 -I scripts/shape-text-reference.py              write the files
  python3 -I scripts/shape-text-reference.py --check      say whether they are as it would write them
  python3 -I scripts/shape-text-reference.py --show STEM  print each shaped text of a font

The fonts are files from elsewhere: -I keeps Python from loading anything
that lies beside them or beside this script.
"""

import ctypes
import hashlib
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONTS_DIR = os.path.join(ROOT, "toolchain", "fonts")
OUT_DIR = os.path.join(ROOT, "src", "disk", "libs", "truetypeshaping", "tests", "text_reference")

LEFT_TO_RIGHT = 4
RIGHT_TO_LEFT = 5
MONOTONE_CHARACTERS = 1
REMOVE_DEFAULT_IGNORABLES = 0x08
DO_NOT_INSERT_DOTTED_CIRCLE = 0x10
WHOLE = 0xFFFFFFFF


class HbFeature(ctypes.Structure):
    _fields_ = [("tag", ctypes.c_uint32), ("value", ctypes.c_uint32), ("start", ctypes.c_uint), ("end", ctypes.c_uint)]


class HbInfo(ctypes.Structure):
    _fields_ = [
        ("codepoint", ctypes.c_uint32),
        ("mask", ctypes.c_uint32),
        ("cluster", ctypes.c_uint32),
        ("var1", ctypes.c_uint32),
        ("var2", ctypes.c_uint32),
    ]


class HbPosition(ctypes.Structure):
    _fields_ = [
        ("x_advance", ctypes.c_int32),
        ("y_advance", ctypes.c_int32),
        ("x_offset", ctypes.c_int32),
        ("y_offset", ctypes.c_int32),
        ("var", ctypes.c_uint32),
    ]


def tag_of(letters):
    """Four letters as the number OpenType writes them as."""
    data = letters.encode("ascii")
    return (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3]


def library():
    """libharfbuzz, with the calls used here declared."""
    try:
        hb = ctypes.CDLL("libharfbuzz.so.0")
    except OSError:
        sys.exit("shape-text-reference: libharfbuzz.so.0 is not installed (harfbuzz)")
    pointer = ctypes.c_void_p
    calls = {
        "hb_version_string": (ctypes.c_char_p, []),
        "hb_blob_create": (pointer, [ctypes.c_char_p, ctypes.c_uint, ctypes.c_int, pointer, pointer]),
        "hb_face_create": (pointer, [pointer, ctypes.c_uint]),
        "hb_face_get_upem": (ctypes.c_uint, [pointer]),
        "hb_font_create": (pointer, [pointer]),
        "hb_font_set_scale": (None, [pointer, ctypes.c_int, ctypes.c_int]),
        "hb_buffer_create": (pointer, []),
        "hb_buffer_destroy": (None, [pointer]),
        "hb_buffer_add_utf8": (None, [pointer, ctypes.c_char_p, ctypes.c_int, ctypes.c_uint, ctypes.c_int]),
        "hb_buffer_set_direction": (None, [pointer, ctypes.c_int]),
        "hb_buffer_set_script": (None, [pointer, ctypes.c_uint32]),
        "hb_language_from_string": (pointer, [ctypes.c_char_p, ctypes.c_int]),
        "hb_buffer_set_language": (None, [pointer, pointer]),
        "hb_buffer_set_cluster_level": (None, [pointer, ctypes.c_int]),
        "hb_buffer_set_flags": (None, [pointer, ctypes.c_int]),
        "hb_shape": (None, [pointer, pointer, ctypes.POINTER(HbFeature), ctypes.c_uint]),
        "hb_buffer_get_glyph_infos": (ctypes.POINTER(HbInfo), [pointer, ctypes.POINTER(ctypes.c_uint)]),
        "hb_buffer_get_glyph_positions": (ctypes.POINTER(HbPosition), [pointer, ctypes.POINTER(ctypes.c_uint)]),
    }
    for name, (result, arguments) in calls.items():
        call = getattr(hb, name)
        call.restype = result
        call.argtypes = arguments
    return hb


class Case:
    """One text and how it is shaped.

    `script` is the script HarfBuzz is told, as ISO 15924 writes it. With
    `listed`, the text goes to HarfBuzz as one of no script and `listed` is
    the tag the font lists its script under. `language` is the language's
    OpenType tag. `features` are (tag, value, first byte, last byte), the
    last two left out for the whole text.

    A text names a character outside ASCII by its number in braces, in
    hex: "q{301}" is a q and an acute accent behind it. A text given as
    bytes is taken as it stands, for one that is no UTF-8.
    """

    def __init__(self, name, text, script, backward=False, listed="", language="", features=()):
        self.name = name
        if isinstance(text, bytes):
            self.data = text
        else:
            self.data = re.sub(r"\{([0-9A-F]+)\}", lambda found: chr(int(found.group(1), 16)), text).encode("utf-8")
        self.script = script
        self.backward = backward
        self.listed = listed
        self.language = language
        self.features = [tuple(feature) + (0, WHOLE) if len(feature) == 2 else tuple(feature) for feature in features]


class Font:
    """A fetched font, open in libharfbuzz."""

    def __init__(self, hb, file):
        self.hb = hb
        self.file = file
        with open(os.path.join(FONTS_DIR, file), "rb") as source:
            self.data = source.read()
        self.sha256 = hashlib.sha256(self.data).hexdigest()
        blob = hb.hb_blob_create(self.data, len(self.data), 1, None, None)
        face = hb.hb_face_create(blob, 0)
        self.font = hb.hb_font_create(face)
        upem = hb.hb_face_get_upem(face)
        hb.hb_font_set_scale(self.font, upem, upem)

    def shape(self, case):
        """The text of `case` shaped: (glyph, cluster, advance, right, up)
        for each glyph, as they are drawn."""
        hb = self.hb
        buffer = hb.hb_buffer_create()
        hb.hb_buffer_add_utf8(buffer, case.data, len(case.data), 0, len(case.data))
        hb.hb_buffer_set_direction(buffer, RIGHT_TO_LEFT if case.backward else LEFT_TO_RIGHT)
        hb.hb_buffer_set_script(buffer, tag_of("Zyyy" if case.listed else case.script))
        private = ""
        if case.listed:
            private += "-hbsc" + case.listed.strip()
        if case.language:
            private += "-hbot" + case.language.strip()
        if private:
            hb.hb_buffer_set_language(buffer, hb.hb_language_from_string(("x" + private).encode("ascii"), -1))
        hb.hb_buffer_set_cluster_level(buffer, MONOTONE_CHARACTERS)
        hb.hb_buffer_set_flags(buffer, REMOVE_DEFAULT_IGNORABLES | DO_NOT_INSERT_DOTTED_CIRCLE)
        features = (HbFeature * max(len(case.features), 1))()
        for place, (tag, value, first, last) in enumerate(case.features):
            features[place] = HbFeature(tag_of(tag), value, first, WHOLE if last == WHOLE else last + 1)
        hb.hb_shape(self.font, buffer, features, len(case.features))
        count = ctypes.c_uint(0)
        infos = hb.hb_buffer_get_glyph_infos(buffer, ctypes.byref(count))
        positions = hb.hb_buffer_get_glyph_positions(buffer, ctypes.byref(count))
        shaped = []
        for place in range(count.value):
            if positions[place].y_advance:
                sys.exit("shape-text-reference: %s: %s: a glyph advances upward" % (self.file, case.name))
            shaped.append(
                (
                    infos[place].codepoint,
                    infos[place].cluster,
                    positions[place].x_advance,
                    positions[place].x_offset,
                    positions[place].y_offset,
                )
            )
        hb.hb_buffer_destroy(buffer)
        return shaped


def deva(name, text, **more):
    """A Devanagari text for the font that lists the script as `dev2`."""
    return Case(name, text, "Deva", listed="dev2", **more)


def emoji(name, text, **more):
    return Case(name, text, "Zyyy", **more)


FAMILY = "{1F468}{200D}{1F469}{200D}{1F467}"
KERNED = "AVATAR Wave, To Type. LT Yo"
MARKED = "q{301} j{301} x{323} q{308}{304}"
CONJUNCTS = "{915}{94D}{937} {930}{941} {926}{94D}{927}{940}{902}"

# The fonts read, each as its path under toolchain/fonts, the name of the file
# written for it, and its texts. text_reference.zig lists the same files.
FONTS = [
    (
        "go/Go-Regular.ttf",
        "go_regular",
        [
            Case("letters, figures and signs", "Hello, World! 0123456789 (a+b)", "Latn"),
            Case("a soft hyphen inside and at the end", "co{AD}op{AD}", "Latn"),
            Case("a soft hyphen at the start", "{AD}ab", "Latn"),
            Case("joiners and a word joiner", "a{200D}b{200C}c{2060}d", "Latn"),
            Case("selectors the font has nothing for", "a{FE0F}b{FE0E}", "Latn"),
            Case("characters the font lacks", "{4E2D}{6587}", "Hani"),
            Case("Greek", "{391}{3B8}{3AE}{3BD}{3B1}, {3C9}{3BC}{3AD}{3B3}{3B1}", "Grek"),
            Case("Cyrillic", "{41F}{440}{438}{432}{435}{442}, {43C}{438}{440}", "Cyrl"),
            Case("from right to left", "abc, def", "Latn", backward=True),
            Case("bytes that are no UTF-8", b"a\xC3b\x80c\xFFd\xF8 \xBF", "Latn"),
        ],
    ),
    (
        "liberation-fonts-ttf-2.1.5/LiberationSans-Regular.ttf",
        "liberation_sans_regular",
        [
            Case("pairs set closer", KERNED, "Latn"),
            Case("pairs across a soft hyphen", "A{AD}V T{AD}o", "Latn"),
            Case("kerning switched off", KERNED, "Latn", features=[("kern", 0)]),
            Case("kerning switched off for a part", "AVAVAV", "Latn", features=[("kern", 0, 2, 3)]),
            Case("marks on letters", MARKED, "Latn"),
            Case("marks without their feature", MARKED, "Latn", features=[("mark", 0)]),
            Case("tone letters joined", "a{2E5}{2E9} {2E7}{2E5}{2E9}", "Latn"),
            Case(
                "tone letters and what stands between them",
                "a{2E5}{200C}{2E9} {2E5}{200D}{2E9} {2E5}{AD}{2E9} {2E5}{34F}{2E9}",
                "Latn",
            ),
            Case("tone letters left apart", "a{2E5}{2E9}{2E5}{2E9}", "Latn", features=[("ccmp", 0, 1, 4)]),
            Case("superior figures for a part", "x456 y456", "Latn", features=[("sups", 1, 1, 3)]),
            Case("inferior figures", "H2O", "Latn", features=[("subs", 1)]),
            Case("Greek", "{391}{3B8}{3AE}{3BD}{3B1} {3A4}{3AC}{3BE}{3B7}", "Grek"),
            Case("Cyrillic", "{41F}{440}{438}{432}{435}{442}, {422}{423}{414}{410}", "Cyrl"),
            Case("a mark in Cyrillic", "{431}{301}{432}", "Cyrl"),
            Case("a mark in Serbian", "{431}{301}{432}", "Cyrl", language="SRB "),
            Case("Hebrew", "{5E9}{5DC}{5D5}{5DD} {5E2}{5D5}{5DC}{5DD}", "Hebr", backward=True),
            Case("Hebrew with points", "{5D1}{5BC}{5D3}{5B8}{5D2} {5DC}{5D5}{5B9}", "Hebr", backward=True),
            Case("alef and lamed joined when asked", "{5D0}{5DC} {5D0}{5DC}", "Hebr", backward=True, features=[("dlig", 1, 0, 3)]),
        ],
    ),
    (
        "noto/NotoSansDevanagari-Regular.ttf",
        "noto_sans_devanagari_regular",
        [
            deva("vowel signs", "{915}{93E} {915}{93F} {915}{941} {915}{947} {915}{902}"),
            deva("a halant between letters", CONJUNCTS),
            deva(
                "the features of the script asked for",
                CONJUNCTS,
                features=[("akhn", 1), ("half", 1), ("blws", 1), ("psts", 1), ("abvs", 1)],
            ),
            deva(
                "a joiner and a non-joiner behind the halant",
                "{915}{94D}{200D}{937} {915}{94D}{200C}{937}",
                features=[("akhn", 1)],
            ),
            deva("the forms of Marathi", "{932}{936}{91D} {915}{941}", language="MAR "),
            deva("distances switched off", CONJUNCTS, features=[("dist", 0)]),
        ],
    ),
    (
        "noto/NotoColorEmoji.ttf",
        "noto_color_emoji",
        [
            emoji("a family joined", FAMILY),
            emoji("a family left apart", FAMILY, features=[("ccmp", 0)]),
            emoji("two families, the second left apart", FAMILY + FAMILY, features=[("ccmp", 0, 18, 35)]),
            emoji("a non-joiner in a family", "{1F468}{200C}{1F469}{200D}{1F467}"),
            emoji("skin tones", "{1F44D}{1F3FD}{1F44D}"),
            emoji("a skin tone behind a joiner", "{1F468}{200D}{1F3FD}"),
            emoji("flags", "{1F1E9}{1F1EA}{1F1EB}{1F1F7}{1F1E9}"),
            emoji("keycaps", "1{FE0F}{20E3}#{20E3}"),
            emoji("selectors", "{263A}{FE0F}{263A}{FE0E}{263A}"),
            emoji("a selector within a joined pair", "{2764}{FE0F}{200D}{1F525}"),
            emoji(
                "a flag of tag characters",
                "{1F3F4}{E0067}{E0062}{E0065}{E006E}{E0067}{E007F}{1F3F4}",
            ),
        ],
    ),
]


def quoted(data):
    """Bytes as a Zig string, everything but plain ASCII escaped."""
    parts = []
    for byte in data:
        if byte in (0x22, 0x5C):
            parts.append("\\" + chr(byte))
        elif 0x20 <= byte < 0x7F:
            parts.append(chr(byte))
        else:
            parts.append("\\x%02x" % byte)
    return '"' + "".join(parts) + '"'


def written(hb, file, cases):
    """The Zig file of one font's texts."""
    font = Font(hb, file)
    lines = [
        "// SPDX-License-Identifier: MIT",
        "//! %s" % font.file,
        "//! sha256 %s" % font.sha256,
        "//! HarfBuzz %s" % hb.hb_version_string().decode("ascii"),
        "//!",
        "//! What HarfBuzz shapes texts to with that font, as",
        "//! `../text_reference.zig` says a font's cases are written: what",
        "//! truetypeshaping.library's host tests compare its shaping of the",
        "//! same texts with. Written by scripts/shape-text-reference.py and",
        "//! never edited; it is written again when the font's pin in",
        "//! scripts/fetch-fonts.sh changes.",
        "",
        'const reference = @import("../text_reference.zig");',
        "",
        "pub const font: reference.Font = .{",
        '    .file = "%s",' % font.file,
        '    .sha256 = "%s",' % font.sha256,
        "    .cases = &.{",
    ]
    for case in cases:
        lines.append("        .{")
        lines.append('            .name = "%s",' % case.name)
        lines.append("            .text = %s," % quoted(case.data))
        if case.backward:
            lines.append("            .backward = true,")
        if case.language:
            lines.append('            .language = "%s",' % case.language)
        if case.features:
            lines.append("            .features = &.{")
            for tag, value, first, last in case.features:
                fields = ['.tag = "%s"' % tag]
                if value != 1:
                    fields.append(".value = %d" % value)
                if (first, last) != (0, WHOLE):
                    fields.append(".first = %d, .last = %d" % (first, last))
                lines.append("                .{ %s }," % ", ".join(fields))
            lines.append("            },")
        lines.append("            .glyphs = &.{")
        lines.extend("                .{ %d, %d, %d, %d, %d }," % glyph for glyph in font.shape(case))
        lines.append("            },")
        lines.append("        },")
    lines.append("    },")
    lines.append("};")
    return "\n".join(lines) + "\n"


def show(hb, stem):
    """Prints each shaped text of a font: its name, then each glyph as
    glyph/cluster/advance/right/up."""
    for file, name, cases in FONTS:
        if name != stem:
            continue
        font = Font(hb, file)
        for case in cases:
            print("%s: %s" % (case.name, " ".join("%d/%d/%d/%d/%d" % glyph for glyph in font.shape(case))))
        return
    sys.exit("shape-text-reference: no font is written as %s" % stem)


def main(arguments):
    hb = library()
    if len(arguments) == 2 and arguments[0] == "--show":
        show(hb, arguments[1])
        return
    check = arguments == ["--check"]
    if arguments and not check:
        sys.exit(__doc__)
    stale = 0
    for file, stem, cases in FONTS:
        target = os.path.join(OUT_DIR, stem + ".zig")
        text = written(hb, file, cases)
        if check:
            try:
                with open(target, encoding="utf-8") as source:
                    same = source.read() == text
            except FileNotFoundError:
                same = False
            if not same:
                stale += 1
                print("shape-text-reference: %s is not what %s gives" % (os.path.relpath(target, ROOT), file))
            continue
        os.makedirs(OUT_DIR, exist_ok=True)
        with open(target, "w", encoding="utf-8") as out:
            out.write(text)
        print("shape-text-reference: %s" % os.path.relpath(target, ROOT))
    if stale:
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1:])
