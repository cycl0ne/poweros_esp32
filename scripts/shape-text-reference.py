#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Texts shaped by HarfBuzz, written as Zig for the host tests.

truetypeshaping.library's host tests shape texts and compare what comes out
- each glyph, its cluster, its advance and its offsets - with what the
system's libharfbuzz gives for the same text. This asks libharfbuzz, through
ctypes, and writes the answers down.

The texts are shaped with two kinds of fonts. The fetched ones
(scripts/fetch-fonts.sh) show a font's tables at work. And a font made of a
rule, which has no file: a glyph of its own number for each character up to
U+FFFF, an advance by the glyph's number, no tables. A case of it says which
characters its font lacks, so one text is shaped with a font that has a
letter with its marks as one character, one that has the parts, and one that
has neither - which is what decides how a text is made the characters a font
draws it with. Some of its cases are chosen by hand and named for what they
show; the others are drawn by lot from the letters and marks of fifteen
scripts, the same ones each time this runs.

The two are asked the same thing: positions in the font's own units, a
cluster for each character (HarfBuzz's cluster level 1), and the characters
a text does not show taken out. HarfBuzz gets the script and the direction
said; ShapeText finds the script itself, so a text here is of one script.

Where the two shape by different rules a text shows nothing, and the cases
keep away from it:

  - In a font without GPOS HarfBuzz sets a mark by its outline's box. The
    fetched fonts without GPOS get no mark that stays one: their marks
    stand behind letters the font has a character with the mark for. The
    made font has no outlines, and there both move a mark back by its
    advance.
  - HarfBuzz mirrors brackets in a text read from right to left and makes
    fractions around U+2044.
  - A text of a script written from left to right that is told to be read
    from right to left HarfBuzz turns around before it shapes it, a letter
    with its marks at a time; ShapeText turns the shaped glyphs around one
    by one. The made font's texts read from right to left are therefore
    given to HarfBuzz as Thaana, a script that is written that way and has
    no model of its own.
  - For some scripts HarfBuzz has a model of the script: syllables put in
    order, forms picked by the place in a word. Such a text is given to it
    as one of no script, with the tag the font lists the script under said
    in the language ("x-hbscdev2"), which is how HarfBuzz is told to shape
    it by its features alone - as ShapeText shapes it.
  - Of a character whose bytes are cut short, or one UTF-8 forbids,
    HarfBuzz makes a U+FFFD for each byte and ShapeText one for them all.
    The bytes here that are no UTF-8 stand alone.

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


# What a font made of a rule answers HarfBuzz with: a character's glyph, the
# glyph of a character and a selector, a glyph's advance.
NOMINAL = ctypes.CFUNCTYPE(
    ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32), ctypes.c_void_p
)
VARIATION = ctypes.CFUNCTYPE(
    ctypes.c_int,
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_uint32,
    ctypes.c_uint32,
    ctypes.POINTER(ctypes.c_uint32),
    ctypes.c_void_p,
)
ADVANCE = ctypes.CFUNCTYPE(ctypes.c_int32, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p)


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
        "hb_font_funcs_create": (pointer, []),
        "hb_font_funcs_set_nominal_glyph_func": (None, [pointer, NOMINAL, pointer, pointer]),
        "hb_font_funcs_set_variation_glyph_func": (None, [pointer, VARIATION, pointer, pointer]),
        "hb_font_funcs_set_glyph_h_advance_func": (None, [pointer, ADVANCE, pointer, pointer]),
        "hb_font_set_funcs": (None, [pointer, pointer, pointer, pointer]),
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


class MadeCase(Case):
    """A text for a font made of a rule instead of a file.

    The font has a glyph of the character's own number for every character
    up to U+FFFF but those of `lacking`, and beyond it for those of
    `having`. `variants` are (character, selector, glyph) for each pair it
    has a glyph for. A glyph's advance is 400 and ten times what its
    number leaves over 37; `em` units are an em. It has no tables.

    HarfBuzz is told a script it has no model for, whatever the text's is:
    Latin, and Thaana for a text read from right to left.

    `drawn` says the lists are longer than the text needs: of them, only
    what HarfBuzz asked for, the text's own characters and those a space
    is made of are written down.
    """

    def __init__(self, name, text, lacking=(), having=(), variants=(), em=1000, backward=False, drawn=False):
        super().__init__(name, text, "Thaa" if backward else "Latn", backward=backward)
        self.lacking = frozenset(lacking)
        self.having = frozenset(having)
        self.variants = {(char, selector): glyph for char, selector, glyph in variants}
        self.em = em
        self.drawn = drawn

    def glyph_of(self, char):
        if char <= 0xFFFF:
            return 0 if char in self.lacking else char
        return char if char in self.having else 0


def made_advance(glyph):
    return 400 + glyph % 37 * 10


class MadeFont:
    """The font of a `MadeCase`, open in libharfbuzz. `asked` is every
    character HarfBuzz asked a glyph for."""

    def __init__(self, hb, case):
        self.hb = hb
        self.file = "a made font"
        self.asked = set()

        def nominal(font, data, char, glyph, user):
            self.asked.add(char)
            found = case.glyph_of(char)
            if not found:
                return 0
            glyph[0] = found
            return 1

        def variation(font, data, char, selector, glyph, user):
            found = case.variants.get((char, selector), 0)
            if not found:
                return 0
            glyph[0] = found
            return 1

        def advance(font, data, glyph, user):
            return made_advance(glyph)

        # Kept, or Python frees what HarfBuzz still calls.
        self.calls = (NOMINAL(nominal), VARIATION(variation), ADVANCE(advance))
        funcs = hb.hb_font_funcs_create()
        hb.hb_font_funcs_set_nominal_glyph_func(funcs, self.calls[0], None, None)
        hb.hb_font_funcs_set_variation_glyph_func(funcs, self.calls[1], None, None)
        hb.hb_font_funcs_set_glyph_h_advance_func(funcs, self.calls[2], None, None)
        self.font = hb.hb_font_create(hb.hb_face_create(hb.hb_blob_create(b"", 0, 1, None, None), 0))
        hb.hb_font_set_funcs(self.font, funcs, None, None)
        hb.hb_font_set_scale(self.font, case.em, case.em)

    shape = Font.shape


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
            Case("letters and marks the font has as one character", "e{301}t u{308} A{30A} u{308}{301}", "Latn"),
            Case("a character and a mark the font has as one character", "{FC}{301} {E5}{301} {C5}{301}", "Latn"),
            Case("spaces the font lacks", "a{2009}b{202F}c{2003}d{2007}e{2008}f", "Latn"),
            Case("a hyphen the font lacks", "a{2011}b{2010}c", "Latn"),
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
            Case("letters and marks the font has as one character", "e{301}t A{30A} a{323}{302} a{302}{323}", "Latn"),
            Case("marks out of order on a letter there is no character for", "q{301}{323} x{308}{31B}{301}", "Latn"),
            Case("a character with a mark behind it", "{E9}{323} {1EAD}{301} {C5}{301}", "Latn"),
            Case("a character that is another one", "{212B}{2126} {212B}{323}", "Latn"),
            Case("the grapheme joiner between marks", "q{301}{34F}{323} q{323}{34F}{301} e{34F}{301}", "Latn"),
            Case("spaces and a hyphen the font lacks", "a{2011}b{2000}c{2001}d{2007}e{2008}f", "Latn"),
            Case("Greek with marks", "{3B1}{301} {3B9}{308}{301} {3B1}{345}{342}", "Grek"),
            Case("Cyrillic with marks", "{438}{306} {435}{308} {443}{306}{301}", "Cyrl"),
            Case("Hebrew points written out of order", "{5D1}{5B8}{5BC} {5E9}{5BC}{5C1}{5B8}", "Hebr", backward=True),
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


SPACES = "a{2002}b{2003}c{2004}d{2005}e{2006}f{2009}g{200A}h{205F}i{3000}j{2000}k{2001}l"
SPACES_LACKING = [0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2009, 0x200A, 0x205F, 0x3000]
SET_SPACES = "1{2007}2{2008}3{202F}4{A0}5"
MANY = "{301}" * 20 + "{323}" * 12

# The texts of the made font that are chosen by hand, each of one script.
MADE = [
    MadeCase("a letter and a mark the font has as one", "e{301}x"),
    MadeCase("a letter and a mark the font has no character for", "e{301}x", lacking=[0xE9]),
    MadeCase("a character the font lacks", "{E9}x", lacking=[0xE9]),
    MadeCase("a character the font lacks, and its first part too", "{1EAD}", lacking=[0x1EAD, 0x1EA1]),
    MadeCase("a character the font lacks whose first part it has", "{1EAD}", lacking=[0x1EAD]),
    MadeCase("a character the font lacks a part of", "a{E9}b", lacking=[0xE9, 0x301]),
    MadeCase("a character the font has, with a mark behind it", "{E9}{323}"),
    MadeCase("the same where the font lacks what the two would be", "{E9}{323}", lacking=[0x1EB9]),
    MadeCase("a mark put with the letter past one of a lower order", "a{301}{323}", lacking=[0x1EA1]),
    MadeCase("marks put in order, and the first of them put with the letter", "a{301}{323}"),
    MadeCase("marks put in order", "q{301}{323}{315}{327}"),
    MadeCase("two marks put with a letter one after the other", "u{308}{301}"),
    MadeCase("a mark does not pass one of its own order", "a{302}{301}", lacking=[0xE2]),
    MadeCase("marks of one order stay as they are written", "a{301}{300}{302}", lacking=[0xE1]),
    MadeCase("a mark that encloses stands in the way", "a{20DD}{301}"),
    MadeCase("marks alone", "{301}{323} {323}{301}"),
    MadeCase("a joiner behind a letter", "a{200D}{301}b{200C}{301}"),
    MadeCase("the grapheme joiner between marks out of order", "a{301}{34F}{323}"),
    MadeCase("the grapheme joiner between marks in order", "a{323}{34F}{301}"),
    MadeCase("the grapheme joiner at a text's ends", "{34F}a{301}{34F}"),
    MadeCase("as many marks as are put in order", "a" + MANY, lacking=[0xE1, 0x1EA1]),
    MadeCase("one mark more than are put in order", "a" + MANY + "{323}", lacking=[0xE1, 0x1EA1]),
    MadeCase("a character that is another one", "{212B}{2126}{37E}", lacking=[0x212B, 0x2126, 0x37E]),
    MadeCase("the same where the font has them", "{212B}{2126}{37E}"),
    MadeCase("a character that is another one, with a mark behind it", "{37E}{301}{212B}{323}"),
    MadeCase("a letter with a ring where the font lacks it", "A{30A}{212B}", lacking=[0xC5]),
    MadeCase("a letter and a selector the font has a glyph for", "a{FE00}{301}", variants=[(0x61, 0xFE00, 0x20000)]),
    MadeCase("a letter and a selector the font has nothing for", "e{FE0F}{301} e{301}{FE0F}"),
    MadeCase("two selectors", "a{FE00}{FE01}b", variants=[(0x61, 0xFE00, 0x20000)]),
    MadeCase("a selector beyond U+FFFF", "a{E0100}{323}", variants=[(0x61, 0xE0100, 0x20001)]),
    MadeCase("spaces of a set width in a font without them", SPACES, lacking=SPACES_LACKING, em=2048),
    MadeCase("the same in a font with them", SPACES, em=2048),
    MadeCase("an em that does not divide", SPACES, lacking=SPACES_LACKING, em=1001),
    MadeCase("spaces as wide as a figure, a period, half a space", SET_SPACES, lacking=[0x2007, 0x2008, 0x202F, 0xA0]),
    MadeCase("no figure 0 and no period", SET_SPACES, lacking=[0x2007, 0x2008, 0x202F, 0x30, 0x2E]),
    MadeCase("no figure and neither period nor comma", SET_SPACES, lacking=[0x2007, 0x2008] + list(range(0x30, 0x3A)) + [0x2E, 0x2C]),
    MadeCase("a space in a font without any", "a{2003}b c", lacking=[0x2003, 0x20]),
    MadeCase("a space with a mark behind it", "a{2003}{301}b", lacking=[0x2003]),
    MadeCase("a hyphen that does not break", "a{2011}b", lacking=[0x2011]),
    MadeCase("the same in a font without a hyphen", "a{2011}b{2010}", lacking=[0x2011, 0x2010]),
    MadeCase("a space mark that is no space", "{1681}{1680}{1682}", lacking=[0x1680]),
    MadeCase("a syllable of three taken apart", "{AC01}{D4DB}", lacking=[0xAC01, 0xAC00, 0xD4DB, 0xD4CC]),
    MadeCase("a syllable of three whose first two the font has", "{AC01}", lacking=[0xAC01]),
    MadeCase("a syllable of two taken apart", "{AC00}{D7A3}", lacking=[0xAC00]),
    MadeCase("single letters of a syllable stay single", "{1100}{1161}{11A8}{AC00}{11A8}"),
    MadeCase("Hebrew points put in order", "{5D1}{5B8}{5BC} {5E9}{5C1}{5BC}{5B8}"),
    MadeCase("Hebrew letters with a point taken apart", "{FB31}{FB2C}{FB4B}", lacking=[0xFB31, 0xFB2C, 0xFB49, 0xFB4B]),
    MadeCase("Hebrew letters with a point are not put together", "{5D1}{5BC}{5E9}{5BC}{5C1}"),
    MadeCase("Arabic marks put in order", "{628}{64E}{651} {628}{650}{651}{670}"),
    MadeCase("Arabic letters with a sign above", "{627}{653}{627}{654}{648}{654}", lacking=[0x623]),
    MadeCase("Tibetan vowel signs put in order", "{F40}{F72}{F74} {F40}{F74}{F72}{F71}{F39}"),
    MadeCase("Tibetan vowel signs taken apart", "{F40}{F73}{F42}{F75}{F81}", lacking=[0xF73, 0xF75]),
    MadeCase("Thai marks put in order", "{E01}{E48}{E38} {E02}{E3A}{E49}"),
    MadeCase("Lanna marks put in order", "{1A20}{1A75}{1A60} {1A21}{1A7F}{1A60}"),
    MadeCase("a Devanagari letter and its dot", "{915}{93C}{928}{93C}{958}{929}", lacking=[0x958]),
    MadeCase("a Telugu vowel sign of two", "{C15}{C46}{C56}{C15}{C48}", lacking=[]),
    MadeCase("the same where the font lacks it", "{C15}{C46}{C56}{C15}{C48}", lacking=[0xC48]),
    MadeCase("Katakana with a sound mark", "{30AB}{3099}{30CF}{309A}{30AC}", lacking=[0x30D1]),
    MadeCase("Greek with a mark below and one above", "{3B1}{345}{301} {3B1}{345}{301}", lacking=[0x1FB4]),
    MadeCase("Greek marks that are other marks", "{3B9}{344} {3B9}{308}{341} {3B1}{343}", lacking=[0x344]),
    MadeCase("Cyrillic", "{438}{306}{435}{308}{418}{306}{483}", lacking=[0x419]),
    MadeCase("notes of music", "{1D15E}{1D160}{1D157}{1D165}", having=[0x1D157, 0x1D158, 0x1D165, 0x1D16E]),
    MadeCase("notes of music the font has", "{1D15E}{1D160}", having=[0x1D15E, 0x1D160, 0x1D157, 0x1D165]),
    MadeCase("from right to left", "e{301}x a{301}{323}", backward=True),
    MadeCase("from right to left, without the characters", "e{301}x {E9} {2003}", lacking=[0xE9, 0x2003], backward=True),
]

# What the drawn texts are made of: for each script its letters, the
# characters that are a letter with marks (and those on the way to them),
# and its marks.
SCRIPTS = [
    (
        [0x61, 0x65, 0x6F, 0x75, 0x41, 0x4F, 0x55, 0x69, 0x71, 0x73, 0x17F],
        [0xE9, 0xE8, 0xEA, 0x1EBF, 0x1EC7, 0x1EB9, 0x1EA1, 0x1EAD, 0xE2, 0x1D8, 0x1E17, 0x113, 0xFC, 0x1FD, 0xE6, 0xC5, 0x212B]
        + [0x1E69, 0x1E63, 0x1E61, 0x1E0B, 0x1E0D, 0x1E9B],
        [0x300, 0x301, 0x302, 0x303, 0x304, 0x307, 0x308, 0x30A, 0x323, 0x327, 0x328, 0x315, 0x31B, 0x345, 0x334, 0x338]
        + [0x340, 0x341, 0x343, 0x344, 0x20DD],
    ),
    (
        [0x3A9, 0x3B1, 0x3B9, 0x3C5],
        [0x390, 0x3AC, 0x3CA, 0x1F82, 0x1F02, 0x1F00, 0x1F71, 0x1FB4, 0x2126, 0x1FD3],
        [0x300, 0x301, 0x308, 0x313, 0x342, 0x345, 0x340, 0x341, 0x343, 0x344],
    ),
    (
        [0x438, 0x418, 0x435],
        [0x439, 0x419, 0x451, 0x450],
        [0x306, 0x308, 0x300, 0x301, 0x483, 0x488],
    ),
    (
        [0x5D0, 0x5D1, 0x5E9, 0x5D9],
        [0xFB1D, 0xFB2A, 0xFB2C, 0xFB49, 0xFB31, 0xFB4B],
        [0x5B0, 0x5B4, 0x5B7, 0x5B8, 0x5B9, 0x5BC, 0x5BD, 0x5BF, 0x5C1, 0x5C2],
    ),
    (
        [0x627, 0x628, 0x648, 0x64A],
        [0x622, 0x623, 0x624, 0x626],
        [0x64B, 0x64E, 0x650, 0x651, 0x652, 0x670, 0x653, 0x654, 0x655],
    ),
    ([0x915, 0x928, 0x930], [0x958, 0x929, 0x931], [0x93C, 0x94D, 0x903, 0x93E, 0x951]),
    ([0xE01, 0xE02], [], [0xE38, 0xE3A, 0xE48, 0xE49]),
    ([0xC15], [0xC48], [0xC46, 0xC55, 0xC56, 0xC4D]),
    ([0xF40, 0xF42], [0xF73, 0xF75, 0xF81, 0xF43], [0xF71, 0xF72, 0xF74, 0xF39, 0xF80, 0xFB7, 0xFC6]),
    ([0x1100, 0x1161, 0x11A8, 0x1112, 0x1175], [0xAC00, 0xAC01, 0xD4DB, 0xD4CC, 0xD7A3], [0x302E, 0x302F]),
    ([0x30AB, 0x30CF], [0x30AC, 0x30D0, 0x30D1], [0x3099, 0x309A]),
    ([0x1A20, 0x1A21], [], [0x1A60, 0x1A75, 0x1A76, 0x1A7F]),
    ([0x8C48, 0x4E2D], [0xF900], [0x302A, 0x3099]),
    ([0x1D157, 0x1D158], [0x1D15E, 0x1D15F, 0x1D160], [0x1D165, 0x1D16E, 0x1D167]),
    ([0x16D63, 0x16D67], [0x16D68, 0x16D69, 0x16D6A], [0x301]),
]

# And what every script's texts share.
SHARED = [0x34F, 0x200D, 0x200C, 0xFE00, 0xFE0F, 0xE0100, 0xAD, 0x20, 0xA0, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005]
SHARED += [0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x202F, 0x205F, 0x3000, 0x2011, 0x2010, 0x30, 0x35, 0x2E, 0x2C]
SHARED += [0x374, 0x37E, 0x387, 0x2ADC]

# The characters a space is made of where the font lacks it.
MAKING = [0x20, 0x2010] + list(range(0x30, 0x3A)) + [0x2E, 0x2C]

DRAWN = 150

# The name of the file written for the made font.
MADE_STEM = "made"


class Lot:
    """Numbers as if drawn by lot, the same ones each time."""

    def __init__(self, seed):
        self.state = seed

    def below(self, limit):
        self.state = (self.state * 6364136223846793005 + 1442695040888963407) & 0xFFFFFFFFFFFFFFFF
        return (self.state >> 33) % limit

    def one(self, items):
        return items[self.below(len(items))]


def drawn(number):
    """The made font's text of that number, and its font, by lot."""
    lot = Lot(number)
    letters, composed, marks = lot.one(SCRIPTS)
    selectors = [0xFE00, 0xFE0F, 0xE0100]
    lack = lot.one([0, 10, 30, 60])
    lacking = []
    having = []
    for char in sorted(set(letters + composed + marks + SHARED + MAKING)):
        lacks = lot.below(100) < (lack * 4 // 10 if char in marks else lack)
        if char > 0xFFFF:
            if not lacks:
                having.append(char)
        elif lacks and char not in selectors:
            lacking.append(char)
    variants = [(lot.one(letters), lot.one(selectors), 0x20000 + place) for place in range(2)]
    if variants[0][:2] == variants[1][:2]:
        variants.pop()
    kinds = lot.one([(4, 3, 6, 1), (2, 6, 4, 1), (1, 1, 8, 2), (3, 2, 2, 4)])
    pools = []
    for pool, share in zip((letters, composed, marks, SHARED), kinds):
        if pool:
            pools.extend([pool] * share)
    chars = [lot.one(lot.one(pools)) for _ in range(lot.one([1, 2, 3, 4, 6, 9, 14]))]
    if lot.below(100) < 4:
        chars = [lot.one(letters)] + [lot.one(marks) for _ in range(lot.one([31, 32, 33, 40]))] + chars
    return MadeCase(
        "drawn %d" % number,
        "".join(chr(char) for char in chars).encode("utf-8"),
        lacking=lacking,
        having=having,
        variants=variants,
        em=lot.one([1000, 2048, 1024, 990]),
        backward=lot.below(100) < 15,
        drawn=True,
    )


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


def zig_list(entries):
    """A Zig list of tuples, spaced the way `zig fmt` leaves it."""
    entries = list(entries)
    if len(entries) == 1:
        return "&.{%s}" % entries[0]
    return "&.{ %s }" % ", ".join(entries)


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


def made_cases():
    """Every text of the made font: those chosen by hand, then the drawn."""
    return MADE + [drawn(number) for number in range(1, DRAWN + 1)]


def written_made(hb):
    """The Zig file of the made font's texts."""
    lines = [
        "// SPDX-License-Identifier: MIT",
        "//! A font made of a rule: a glyph of its own number for a character.",
        "//! HarfBuzz %s" % hb.hb_version_string().decode("ascii"),
        "//!",
        "//! What HarfBuzz shapes texts to with such a font, as",
        "//! `../text_reference.zig` says a made font's cases are written: what",
        "//! truetypeshaping.library's host tests compare its shaping of the",
        "//! same texts with. Written by scripts/shape-text-reference.py and",
        "//! never edited.",
        "",
        'const reference = @import("../text_reference.zig");',
        "",
        "pub const cases: []const reference.Made = &.{",
    ]
    for case in made_cases():
        font = MadeFont(hb, case)
        shaped = font.shape(case)
        named = case.lacking | case.having
        if case.drawn:
            named &= font.asked | set(ord(char) for char in case.data.decode("utf-8")) | set(MAKING)
        characters = [(char, case.glyph_of(char)) for char in sorted(named)]
        lines.append("    .{")
        lines.append('        .name = "%s",' % case.name)
        lines.append("        .text = %s," % quoted(case.data))
        if case.backward:
            lines.append("        .backward = true,")
        if case.em != 1000:
            lines.append("        .em = %d," % case.em)
        if characters:
            lines.append("        .characters = %s," % zig_list(".{ 0x%X, 0x%X }" % pair for pair in characters))
        if case.variants:
            triples = sorted((char, selector, glyph) for (char, selector), glyph in case.variants.items())
            lines.append("        .variants = %s," % zig_list(".{ 0x%X, 0x%X, 0x%X }" % triple for triple in triples))
        if shaped:
            lines.append("        .glyphs = &.{")
            lines.extend("            .{ %d, %d, %d, %d, %d }," % glyph for glyph in shaped)
            lines.append("        },")
        else:
            lines.append("        .glyphs = &.{},")
        lines.append("    },")
    lines.append("};")
    return "\n".join(lines) + "\n"


def show(hb, stem):
    """Prints each shaped text of a font: its name, then each glyph as
    glyph/cluster/advance/right/up."""
    if stem == MADE_STEM:
        for case in made_cases():
            print("%s: %s" % (case.name, " ".join("%d/%d/%d/%d/%d" % glyph for glyph in MadeFont(hb, case).shape(case))))
        return
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
    files = [(file, stem, written(hb, file, cases)) for file, stem, cases in FONTS]
    files.append(("the made font", MADE_STEM, written_made(hb)))
    for file, stem, text in files:
        target = os.path.join(OUT_DIR, stem + ".zig")
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
