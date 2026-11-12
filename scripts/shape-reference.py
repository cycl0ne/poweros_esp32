#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""The fetched fonts' lookups applied by a second reader, written as Zig for the host tests.

truetypeshaping.library's host tests shape runs of glyphs with the fonts
scripts/fetch-fonts.sh fetches and compare what comes out with what another
applier of the same tables gives. This is that other applier. fontTools reads
each font's GDEF, GSUB and GPOS into objects of its own - it shares no table
reading with the library - and the rules below apply the lookups it read to
the runs: the lookups in the order of their list, the glyphs a lookup sees
and the ones it passes over, the parts of a ligature and the clusters, the
marks attached to what stands before them. Where the OpenType specification
leaves a choice the rule here is the library's, which is said once in
src/disk/libs/truetypeshaping/shape/. So a digest that differs is a table
read differently, and the shaping as a whole is proved elsewhere.

The runs of a font are: every glyph, eight to a run in the order of their
numbers; sequences made from the lookups themselves - a ligature's glyphs, a
context with what stands before and behind it, a pair, a base and its marks,
ligatures with marks among their glyphs; and mixtures of those. The sequences
and mixtures are written out, as hex text. The cases of a font are its
language systems with all their features and with each feature alone, one
case for each different list of lookups that gives; a script written from
right to left has its case in that direction too. Each case is written with
the SHA-256 of all its shaped runs; src/disk/libs/truetypeshaping/tests/
reference.zig says how a run is hashed.

A lookup kind none of the fonts has - alternates, cursive attachment, marks
on ligatures, reverse chaining, extension lookups, features replaced under
conditions - has no rule here: the script stops and says so, and the rule is
written when a font needs it.

The files are committed, and the tests need neither Python nor fontTools. A
test stops by name when its font's SHA-256 is not the one written here, so
this runs again when a font's pin in scripts/fetch-fonts.sh changes, and at
no other time.

  python3 -I scripts/shape-reference.py                     write the files
  python3 -I scripts/shape-reference.py --check             say whether they are as it would write them
  python3 -I scripts/shape-reference.py --show STEM CASE    print each shaped run of a font's case

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
    sys.exit("shape-reference: fontTools is not installed (python-fonttools)")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONTS_DIR = os.path.join(ROOT, "toolchain", "fonts")
OUT_DIR = os.path.join(ROOT, "src", "disk", "libs", "truetypeshaping", "tests", "reference")

# The fonts read, each as its path under toolchain/fonts and the name of the
# file written for it. reference.zig lists the same files.
FONTS = [
    ("go/Go-Regular.ttf", "go_regular"),
    ("liberation-fonts-ttf-2.1.5/LiberationSans-Regular.ttf", "liberation_sans_regular"),
    ("noto/NotoSansDevanagari-Regular.ttf", "noto_sans_devanagari_regular"),
    ("noto/NotoColorEmoji.ttf", "noto_color_emoji"),
]

# The scripts written from right to left.
BACKWARD_SCRIPTS = ("adlm", "arab", "hebr", "mand", "nko ", "rohg", "samr", "syrc", "thaa")

# What a glyph is, as GDEF says it.
KIND_NONE = 0
KIND_BASE = 1
KIND_LIGATURE = 2
KIND_MARK = 3
KIND_COMPONENT = 4

# What happened to a glyph.
SUBSTITUTED = 0x01
LIGATED = 0x02
MULTIPLIED = 0x04

# A lookup's flags.
IGNORE_BASES = 0x0002
IGNORE_LIGATURES = 0x0004
IGNORE_MARKS = 0x0008
USE_MARK_SET = 0x0010
MARK_CLASS = 0xFF00

# The library's limits: the glyphs of one sequence, and lookups within lookups.
CONTEXT_LIMIT = 64
NESTING_LIMIT = 8


class NoRule(Exception):
    """A font has something this applier has no rule for."""


class Item:
    """A glyph of a run, with what the lookups have to know of it."""

    __slots__ = (
        "glyph",
        "cluster",
        "advance",
        "x_offset",
        "y_offset",
        "attach_chain",
        "ligature",
        "part",
        "parts",
        "kind",
        "mark_class",
        "flags",
    )

    def __init__(self, glyph, cluster):
        self.glyph = glyph
        self.cluster = cluster
        self.advance = 0
        self.x_offset = 0
        self.y_offset = 0
        self.attach_chain = 0
        self.ligature = 0
        self.part = 0
        self.parts = 0
        self.kind = KIND_NONE
        self.mark_class = 0
        self.flags = 0

    def copy(self):
        made = Item(self.glyph, self.cluster)
        for name in Item.__slots__:
            setattr(made, name, getattr(self, name))
        return made

    def part_on(self):
        """The part of a ligature the glyph sits on; 0 for the ligature itself."""
        return 0 if self.parts else self.part

    def part_count(self):
        """How many parts the glyph stands for."""
        return self.parts if self.kind == KIND_LIGATURE and self.parts else 1


class Run:
    """The glyphs being shaped."""

    def __init__(self, glyphs):
        self.items = [Item(glyph, place) for place, glyph in enumerate(glyphs)]
        self.ligatures = 0
        self.limit = max(len(glyphs) * 64, 16384)

    def replace(self, at, count):
        """Puts `count` copies of the glyph at `at` in its place."""
        if len(self.items) + count - 1 > self.limit:
            raise NoRule("a run grows past the library's limit")
        first = self.items[at]
        self.items[at : at + 1] = [first.copy() for _ in range(count)]

    def remove(self, places):
        """Takes the glyphs at `places`, which rise, out of the run."""
        if not places or places[0] >= len(self.items):
            return
        kept = []
        taken = 0
        for index in range(places[0], len(self.items)):
            if taken < len(places) and places[taken] == index:
                taken += 1
                continue
            kept.append(self.items[index])
        self.items[places[0] :] = kept

    def merge_clusters(self, start, end):
        """Gives the glyphs from `start` up to `end` their lowest cluster."""
        items = self.items
        if end > len(items) or start >= end or end - start < 2:
            return
        lowest = min(item.cluster for item in items[start:end])
        first = start
        last = end
        if lowest != items[last - 1].cluster:
            while last < len(items) and items[last - 1].cluster == items[last].cluster:
                last += 1
        if lowest != items[first].cluster:
            while first > 0 and items[first - 1].cluster == items[first].cluster:
                first -= 1
        for item in items[first:last]:
            item.cluster = lowest

    def give_cluster(self, at):
        """Leaves the cluster of the glyph at `at`, which goes, to a neighbour."""
        items = self.items
        if at >= len(items):
            return
        cluster = items[at].cluster
        if at + 1 < len(items) and items[at + 1].cluster == cluster:
            return
        if at > 0:
            before = items[at - 1].cluster
            if before <= cluster:
                return
            index = at
            while index > 0 and items[index - 1].cluster == before:
                index -= 1
                items[index].cluster = cluster
            return
        self.merge_clusters(at, at + 2)

    def next_ligature(self):
        self.ligatures = (self.ligatures + 1) & 0xFFFF or 1
        return self.ligatures


class Gdef:
    """What GDEF says of the glyphs: kinds, marks' classes, sets of marks."""

    def __init__(self, font, ids):
        self.kinds = None
        self.mark_classes = {}
        self.mark_sets = []
        if "GDEF" not in font:
            return
        table = font["GDEF"].table
        if table.Version >> 16 != 1:
            return
        if table.GlyphClassDef is not None:
            self.kinds = {ids[name]: kind for name, kind in table.GlyphClassDef.classDefs.items()}
        if table.MarkAttachClassDef is not None:
            self.mark_classes = {ids[name]: kind for name, kind in table.MarkAttachClassDef.classDefs.items()}
        sets = getattr(table, "MarkGlyphSetsDef", None)
        if table.Version & 0xFFFF >= 2 and sets is not None and sets.MarkSetTableFormat == 1:
            self.mark_sets = [frozenset(ids[name] for name in coverage.glyphs) for coverage in sets.Coverage]

    def classify(self, item, guess):
        """Says what the glyph of `item` is; `guess` where the font does not say."""
        if self.kinds is None:
            if guess != KIND_NONE:
                item.kind = guess
            return
        kind = self.kinds.get(item.glyph, 0)
        item.kind = KIND_NONE if kind > KIND_COMPONENT else kind
        item.mark_class = 0
        if item.kind == KIND_MARK:
            mark_class = self.mark_classes.get(item.glyph, 0)
            item.mark_class = 0 if mark_class > 0xFF else mark_class

    def in_mark_set(self, number, glyph):
        return number < len(self.mark_sets) and glyph in self.mark_sets[number]


def by_glyph(glyph, said):
    return glyph == said


def by_class(classes):
    return lambda glyph, said: classes.get(glyph, 0) == said


def by_coverage(glyph, said):
    return glyph in said


class Applier:
    """Applies one table's lookups to a run."""

    def __init__(self, run, gdef, lookups, backward):
        self.run = run
        self.gdef = gdef
        self.lookups = lookups
        self.backward = backward
        self.places = [[0] * CONTEXT_LIMIT for _ in range(NESTING_LIMIT)]
        self.work = max(len(run.items) * 1024, 16384)
        self.present = None
        self.flags = 0
        self.mark_set = 0
        self.depth = 0

    def skips_by(self, item, flags):
        """Whether a lookup of `flags` passes over the glyph."""
        if item.kind == KIND_BASE:
            return flags & IGNORE_BASES != 0
        if item.kind == KIND_LIGATURE:
            return flags & IGNORE_LIGATURES != 0
        if item.kind == KIND_MARK:
            if flags & IGNORE_MARKS:
                return True
            if flags & USE_MARK_SET:
                return not self.gdef.in_mark_set(self.mark_set, item.glyph)
            if flags & MARK_CLASS:
                return (flags >> 8) != item.mark_class
        return False

    def skips(self, item):
        return self.skips_by(item, self.flags)

    def next(self, at):
        """The next glyph behind `at` the lookup sees, or None."""
        items = self.run.items
        for index in range(at + 1, len(items)):
            if not self.skips(items[index]):
                return index
        return None

    def prev(self, at):
        """The nearest glyph before `at` the lookup sees, or None."""
        items = self.run.items
        for index in range(at - 1, -1, -1):
            if not self.skips(items[index]):
                return index
        return None

    def match_input(self, at, rest, matches, places):
        """Matches the glyphs behind `at` against `rest`. Answers where the
        match ends and how many ligature parts it holds, or None."""
        if len(rest) >= CONTEXT_LIMIT:
            return None
        items = self.run.items
        first = items[at]
        first_ligature = first.ligature
        first_part = first.part_on()
        base_checked = False
        base_unseen = False
        parts = first.part_count()
        index = at
        places[0] = at
        for step, said in enumerate(rest):
            index = self.next(index)
            if index is None:
                return None
            item = items[index]
            if not matches(item.glyph, said):
                return None
            places[step + 1] = index
            if first_ligature != 0 and first_part != 0:
                if item.ligature != first_ligature or item.part_on() != first_part:
                    if not base_checked:
                        base_checked = True
                        back = at
                        while back > 0 and items[back - 1].ligature == first_ligature:
                            back -= 1
                            if items[back].part_on() == 0:
                                base_unseen = self.skips(items[back])
                                break
                    if not base_unseen:
                        return None
            elif item.ligature != 0 and item.part_on() != 0 and item.ligature != first_ligature:
                return None
            parts += item.part_count()
        return index + 1, parts

    def match_before(self, at, before, matches):
        if len(before) > CONTEXT_LIMIT:
            return False
        index = at
        for said in before:
            index = self.prev(index)
            if index is None or not matches(self.run.items[index].glyph, said):
                return False
        return True

    def match_after(self, end, after, matches):
        if len(after) > CONTEXT_LIMIT:
            return False
        index = end - 1
        for said in after:
            index = self.next(index)
            if index is None or not matches(self.run.items[index].glyph, said):
                return False
        return True

    def apply_at(self, lookup, at):
        """Applies the first of the lookup's subtables that has a rule for
        the glyph at `at`. Answers where the lookup goes on, or None."""
        for subtable in lookup.subtables:
            place = subtable.apply(self, at)
            if place is not None:
                return place
        return None

    def nested(self, index, at):
        """Applies the lookup `index` at `at` from within a lookup."""
        if self.depth + 1 >= NESTING_LIMIT:
            return False
        self.work -= 1
        if self.work < 0 or index >= len(self.lookups):
            return False
        lookup = self.lookups[index]
        flags, mark_set = self.flags, self.mark_set
        self.flags, self.mark_set = lookup.flags, lookup.mark_set
        self.depth += 1
        applied = self.apply_at(lookup, at) is not None
        self.depth -= 1
        self.flags, self.mark_set = flags, mark_set
        return applied

    def run_lookup(self, index):
        """Applies the lookup `index` along the run."""
        if index >= len(self.lookups):
            return
        lookup = self.lookups[index]
        items = self.run.items
        # A subtable begins at a glyph it covers: where the run has none of
        # them the lookup does nothing.
        if self.present is None:
            self.present = frozenset(item.glyph for item in items)
        if lookup.firsts.isdisjoint(self.present):
            return
        self.present = None
        self.flags, self.mark_set, self.depth = lookup.flags, lookup.mark_set, 0
        at = 0
        while at < len(items):
            if not self.skips(items[at]):
                length = len(items)
                place = self.apply_at(lookup, at)
                if place is not None:
                    at = place if place > at or len(items) < length else at + 1
                    continue
            at += 1

    def apply_rule(self, at, rule, matchers):
        """Applies a context's rule at `at` if what stands there is what the
        rule names. Answers where the lookup goes on, or None."""
        before, rest, after, records = rule
        if len(before) > CONTEXT_LIMIT or len(rest) > CONTEXT_LIMIT or len(after) > CONTEXT_LIMIT:
            return None
        places = self.places[self.depth]
        matched = self.match_input(at, rest, matchers[1], places)
        if matched is None:
            return None
        if not self.match_after(matched[0], after, matchers[2]):
            return None
        if not self.match_before(at, before, matchers[0]):
            return None
        return self.apply_records(places, len(rest) + 1, records, matched[0])

    def apply_records(self, places, matched, records, matched_end):
        """Applies a rule's lookups at the matched glyphs, which move as the
        lookups make the run longer or shorter."""
        items = self.run.items
        count = matched
        end = matched_end
        for place, lookup in records:
            if place >= count:
                continue
            length = len(items)
            if places[place] >= length:
                continue
            if self.work <= 0:
                break
            if not self.nested(lookup, places[place]):
                continue
            delta = len(items) - length
            if delta == 0:
                continue
            end += delta
            if end < places[place]:
                delta += places[place] - end
                end = places[place]
            following = place + 1
            if delta > 0:
                if delta + count > CONTEXT_LIMIT:
                    break
                for index in range(count - 1, following - 1, -1):
                    places[index + delta] = places[index]
            else:
                delta = max(delta, following - count)
                following -= delta
                for index in range(following, count):
                    places[index + delta] = places[index]
            following += delta
            count += delta
            for filled in range(place + 1, following):
                places[filled] = places[filled - 1] + 1
            for index in range(following, count):
                places[index] = max(places[index] + delta, 0)
        return max(end, 0)


def put(applier, at, glyph):
    """Makes the glyph at `at` the glyph `glyph`."""
    item = applier.run.items[at]
    item.glyph = glyph
    item.flags |= SUBSTITUTED
    applier.gdef.classify(item, KIND_NONE)


class Single:
    """A glyph for a glyph. `mapping` is glyph -> glyph."""

    def __init__(self, mapping):
        self.mapping = mapping
        self.firsts = frozenset(mapping)

    def apply(self, applier, at):
        glyph = self.mapping.get(applier.run.items[at].glyph)
        if glyph is None:
            return None
        put(applier, at, glyph)
        return at + 1


class Multiple:
    """Several glyphs for a glyph. `mapping` is glyph -> list of glyphs."""

    def __init__(self, mapping):
        self.mapping = mapping
        self.firsts = frozenset(mapping)

    def apply(self, applier, at):
        run = applier.run
        item = run.items[at]
        sequence = self.mapping.get(item.glyph)
        if sequence is None:
            return None
        count = len(sequence)
        if count == 1:
            put(applier, at, sequence[0])
            return at + 1
        if count == 0:
            run.give_cluster(at)
            run.remove([at])
            return at
        was_ligature = item.kind == KIND_LIGATURE
        on_ligature = item.ligature != 0
        run.replace(at, count)
        for place in range(count):
            made = run.items[at + place]
            if not on_ligature:
                made.part = min(place, 0xFF)
                made.parts = 0
            made.glyph = sequence[place]
            made.flags |= SUBSTITUTED | MULTIPLIED
            applier.gdef.classify(made, KIND_BASE if was_ligature else KIND_NONE)
        return at + count


def part_number(on, parts_so_far, last_parts):
    """The part of the new ligature a mark sits on that sat on the part
    `on` of the glyph that came last, of `last_parts` parts."""
    within = last_parts if on == 0 or on > last_parts else on
    return min(parts_so_far - last_parts + within, 0xFF)


def ligate(applier, places, glyph, matched):
    """Makes the glyphs at `places` the one glyph `glyph`."""
    run = applier.run
    items = run.items
    end, matched_parts = matched
    first = items[places[0]]
    rest_are_marks = all(items[place].kind == KIND_MARK for place in places[1:])
    on_base = first.kind == KIND_BASE and rest_are_marks
    of_marks = first.kind == KIND_MARK and rest_are_marks
    is_ligature = not on_base and not of_marks
    number = run.next_ligature() if is_ligature else 0
    last_ligature = first.ligature
    last_parts = first.part_count()
    parts_so_far = last_parts
    run.merge_clusters(places[0], end)
    if is_ligature:
        first.ligature = number
        first.part = 0
        first.parts = min(matched_parts, 0xFF)
    first.glyph = glyph
    first.flags = (first.flags | SUBSTITUTED | LIGATED) & ~MULTIPLIED
    applier.gdef.classify(first, KIND_LIGATURE if is_ligature else KIND_NONE)
    for before, place in enumerate(places[1:]):
        if is_ligature:
            for between in items[places[before] + 1 : place]:
                between.part = part_number(between.part_on(), parts_so_far, last_parts)
                between.ligature = number
                between.parts = 0
        last_ligature = items[place].ligature
        last_parts = items[place].part_count()
        parts_so_far += last_parts
    if not of_marks and last_ligature != 0:
        for behind in items[end:]:
            if behind.ligature != last_ligature or behind.part_on() == 0:
                break
            behind.part = part_number(behind.part_on(), parts_so_far, last_parts)
            behind.ligature = number
            behind.parts = 0
    run.remove(places[1:])


class Ligature:
    """One glyph for several. `sets` is first glyph -> list of (the glyphs
    behind it, the ligature), in the order the font lists them."""

    def __init__(self, sets):
        self.sets = sets
        self.firsts = frozenset(sets)

    def apply(self, applier, at):
        made = self.sets.get(applier.run.items[at].glyph)
        if made is None:
            return None
        places = applier.places[applier.depth]
        for rest, glyph in made:
            parts = len(rest) + 1
            if parts == 1:
                put(applier, at, glyph)
                return at + 1
            matched = applier.match_input(at, rest, by_glyph, places)
            if matched is None:
                continue
            ligate(applier, places[:parts], glyph, matched)
            return matched[0] - (parts - 1)
        return None


class RulesByGlyph:
    """A context of glyphs. `sets` is first glyph -> list of rules; a rule
    is (before, behind the first, after, lookups at places)."""

    def __init__(self, sets):
        self.sets = sets
        self.firsts = frozenset(sets)

    def apply(self, applier, at):
        for rule in self.sets.get(applier.run.items[at].glyph, ()):
            place = applier.apply_rule(at, rule, (by_glyph, by_glyph, by_glyph))
            if place is not None:
                return place
        return None


class RulesByClass:
    """A context of classes. `sets` holds a list of rules, or None, for
    each class of the first glyph; `classes` is the glyph -> class of what
    stands before, of the glyphs themselves, and of what stands after."""

    def __init__(self, coverage, classes, sets):
        self.firsts = coverage
        self.tables = classes
        self.classes = classes[1]
        self.matchers = tuple(by_class(one) for one in classes)
        self.sets = sets

    def apply(self, applier, at):
        glyph = applier.run.items[at].glyph
        if glyph not in self.firsts:
            return None
        number = self.classes.get(glyph, 0)
        if number >= len(self.sets):
            return None
        for rule in self.sets[number] or ():
            place = applier.apply_rule(at, rule, self.matchers)
            if place is not None:
                return place
        return None


class RuleByCoverage:
    """A context of coverages: one rule, each of its glyphs named by the
    set of glyphs that may stand there."""

    def __init__(self, first, rule):
        self.firsts = first
        self.rule = rule

    def apply(self, applier, at):
        if applier.run.items[at].glyph not in self.firsts:
            return None
        return applier.apply_rule(at, self.rule, (by_coverage, by_coverage, by_coverage))


def apply_value(item, value):
    """Moves a glyph by a value record: to the right, up, and its advance."""
    item.x_offset += value[0]
    item.y_offset += value[1]
    item.advance += value[2]


class SinglePosition:
    """A glyph moved. `values` is glyph -> value."""

    def __init__(self, values):
        self.values = values
        self.firsts = frozenset(values)

    def apply(self, applier, at):
        item = applier.run.items[at]
        value = self.values.get(item.glyph)
        if value is None:
            return None
        apply_value(item, value)
        return at + 1


class PairPosition:
    """Two glyphs moved. `find` answers the two values for a first and a
    second glyph, or None; `second_moves` says the second has a value;
    `pairs` are pairs of glyphs there are values for."""

    def __init__(self, coverage, find, second_moves, pairs):
        self.firsts = coverage
        self.find = find
        self.second_moves = second_moves
        self.pairs = pairs

    def apply(self, applier, at):
        items = applier.run.items
        first = items[at]
        if first.glyph not in self.firsts:
            return None
        second_at = applier.next(at)
        if second_at is None:
            return None
        second = items[second_at]
        values = self.find(first.glyph, second.glyph)
        if values is None:
            return None
        apply_value(first, values[0])
        apply_value(second, values[1])
        return second_at + 1 if self.second_moves else second_at


def attach(items, at, to, mark, anchors):
    """Puts the mark at `at` on the glyph at `to`: its anchor on the anchor
    the glyph has for the mark's class, as far off the line as the glyph
    stands now."""
    number, own = mark
    if number >= len(anchors) or anchors[number] is None:
        return None
    item = items[at]
    item.x_offset = anchors[number][0] - own[0]
    item.y_offset = anchors[number][1] - own[1] + items[to].y_offset
    item.attach_chain = to - at
    return at + 1


def carries_marks(items, at):
    """Whether marks behind the glyph at `at` sit on it: of the glyphs one
    glyph was made into, the first does."""
    item = items[at]
    if not item.flags & MULTIPLIED or item.part_on() == 0 or at == 0:
        return True
    before = items[at - 1]
    return (
        before.kind == KIND_MARK
        or not before.flags & MULTIPLIED
        or before.ligature != item.ligature
        or before.part_on() + 1 != item.part_on()
    )


class MarkToBase:
    """A mark on a base. `marks` is glyph -> (class, anchor), `bases` glyph
    -> the anchors for each class, None where it has none."""

    def __init__(self, marks, bases):
        self.marks = marks
        self.bases = bases
        self.firsts = frozenset(marks)

    def apply(self, applier, at):
        items = applier.run.items
        mark = self.marks.get(items[at].glyph)
        if mark is None:
            return None
        for index in range(at - 1, -1, -1):
            item = items[index]
            if item.kind == KIND_MARK:
                continue
            if not carries_marks(items, index) and item.glyph not in self.bases:
                continue
            anchors = self.bases.get(item.glyph)
            return None if anchors is None else attach(items, at, index, mark, anchors)
        return None


class MarkToMark:
    """A mark on a mark. `marks` is glyph -> (class, anchor), `unders`
    glyph -> the anchors for each class."""

    def __init__(self, marks, unders):
        self.marks = marks
        self.unders = unders
        self.firsts = frozenset(marks)

    def apply(self, applier, at):
        items = applier.run.items
        over = items[at]
        mark = self.marks.get(over.glyph)
        if mark is None:
            return None
        flags = applier.flags & ~(IGNORE_BASES | IGNORE_LIGATURES | IGNORE_MARKS)
        for index in range(at - 1, -1, -1):
            under = items[index]
            if applier.skips_by(under, flags):
                continue
            if under.kind != KIND_MARK:
                return None
            if over.ligature == under.ligature:
                if over.ligature != 0 and over.part_on() != under.part_on():
                    return None
            else:
                over_made = over.ligature != 0 and over.part_on() == 0
                under_made = under.ligature != 0 and under.part_on() == 0
                if not over_made and not under_made:
                    return None
            anchors = self.unders.get(under.glyph)
            return None if anchors is None else attach(items, at, index, mark, anchors)
        return None


def settle(items, child, parent, backward):
    """Adds to a mark's offset along the line what lies between it and what
    it sits on."""
    item = items[child]
    item.x_offset += items[parent].x_offset
    if parent >= child:
        return
    if backward:
        item.x_offset += sum(between.advance for between in items[parent + 1 : child + 1])
    else:
        item.x_offset -= sum(between.advance for between in items[parent:child])


def finish(items, backward):
    """Turns each attachment into offsets from where the glyph is drawn."""
    for start in range(len(items)):
        chain = []
        node = start
        while len(chain) < 64:
            step = items[node].attach_chain
            if step == 0:
                break
            items[node].attach_chain = 0
            target = node + step
            if target < 0 or target >= len(items):
                break
            chain.append(node)
            node = target
        parent = node
        while chain:
            child = chain.pop()
            settle(items, child, parent, backward)
            parent = child


class Lookup:
    """A lookup as fontTools read it: its flags and its subtables."""

    def __init__(self, flags, mark_set, subtables):
        self.flags = flags
        self.mark_set = mark_set
        self.subtables = subtables
        self.firsts = frozenset().union(*(subtable.firsts for subtable in subtables))


def covered(coverage, ids):
    """The glyphs of a coverage table."""
    return frozenset() if coverage is None else frozenset(ids[name] for name in coverage.glyphs)


def classes_of(table, ids):
    """A class table as glyph -> class; a glyph it leaves out has class 0."""
    return {} if table is None else {ids[name]: number for name, number in table.classDefs.items()}


def named(names, ids):
    return [ids[name] for name in names]


def context_rules(sub, ids, chained, word):
    """A context subtable of GSUB (`word` "Sub") or GPOS ("Pos")."""
    prefix = ("Chain" if chained else "") + word
    records_name = "SubstLookupRecord" if word == "Sub" else "PosLookupRecord"

    def records(rule):
        return [(record.SequenceIndex, record.LookupListIndex) for record in getattr(rule, records_name)]

    if sub.Format == 1:
        sets = {}
        listed = getattr(sub, prefix + "RuleSet")
        for index, name in enumerate(sub.Coverage.glyphs):
            if index >= len(listed) or listed[index] is None:
                continue
            rules = []
            for rule in getattr(listed[index], prefix + "Rule"):
                if chained:
                    rules.append((named(rule.Backtrack, ids), named(rule.Input, ids), named(rule.LookAhead, ids), records(rule)))
                else:
                    rules.append(([], named(rule.Input, ids), [], records(rule)))
            sets.setdefault(ids[name], rules)
        return RulesByGlyph(sets)
    if sub.Format == 2:
        if chained:
            classes = (
                classes_of(sub.BacktrackClassDef, ids),
                classes_of(sub.InputClassDef, ids),
                classes_of(sub.LookAheadClassDef, ids),
            )
        else:
            classes = (classes_of(sub.ClassDef, ids),) * 3
        sets = []
        for one in getattr(sub, prefix + "ClassSet"):
            if one is None:
                sets.append(None)
                continue
            rules = []
            for rule in getattr(one, prefix + "ClassRule"):
                if chained:
                    rules.append((list(rule.Backtrack), list(rule.Input), list(rule.LookAhead), records(rule)))
                else:
                    rules.append(([], list(rule.Class), [], records(rule)))
            sets.append(rules)
        return RulesByClass(covered(sub.Coverage, ids), classes, sets)
    if sub.Format == 3:
        if chained:
            before = [covered(coverage, ids) for coverage in sub.BacktrackCoverage]
            glyphs = [covered(coverage, ids) for coverage in sub.InputCoverage]
            after = [covered(coverage, ids) for coverage in sub.LookAheadCoverage]
        else:
            before, glyphs, after = [], [covered(coverage, ids) for coverage in sub.Coverage], []
        if not glyphs:
            return None
        return RuleByCoverage(glyphs[0], (before, glyphs[1:], after, records(sub)))
    raise NoRule("a context of format %d" % sub.Format)


def value_of(record):
    """What a value record moves: to the right, up, and the advance."""
    if record is None:
        return (0, 0, 0)
    return (getattr(record, "XPlacement", 0) or 0, getattr(record, "YPlacement", 0) or 0, getattr(record, "XAdvance", 0) or 0)


def anchor_of(anchor):
    if anchor is None:
        return None
    return (anchor.XCoordinate, anchor.YCoordinate) if anchor.Format in (1, 2, 3) else (0, 0)


def single_position(sub, ids):
    glyphs = named(sub.Coverage.glyphs, ids)
    if sub.Format == 1:
        return SinglePosition({glyph: value_of(sub.Value) for glyph in glyphs})
    if sub.Format == 2:
        return SinglePosition({glyph: value_of(value) for glyph, value in zip(glyphs, sub.Value)})
    raise NoRule("a single positioning of format %d" % sub.Format)


def pair_position(sub, ids):
    coverage = covered(sub.Coverage, ids)
    if sub.Format == 1:
        sets = {}
        for name, pairs in zip(sub.Coverage.glyphs, sub.PairSet):
            sets.setdefault(
                ids[name],
                [(ids[pair.SecondGlyph], value_of(pair.Value1), value_of(pair.Value2)) for pair in pairs.PairValueRecord],
            )

        def find(first, second):
            # The records of a first glyph are in the order of the second
            # glyphs' numbers, and are searched by halves.
            records = sets.get(first)
            if records is None:
                return None
            low, high = 0, len(records)
            while low < high:
                middle = low + (high - low) // 2
                listed = records[middle][0]
                if listed == second:
                    return records[middle][1:]
                if listed < second:
                    low = middle + 1
                else:
                    high = middle
            return None

        pairs = [(first, record[0]) for first, records in sorted(sets.items()) for record in records]
        return PairPosition(coverage, find, sub.ValueFormat2 != 0, pairs)
    if sub.Format == 2:
        firsts = classes_of(sub.ClassDef1, ids)
        seconds = classes_of(sub.ClassDef2, ids)
        matrix = [[(value_of(cell.Value1), value_of(cell.Value2)) for cell in row.Class2Record] for row in sub.Class1Record]

        def find(first, second):
            row = firsts.get(first, 0)
            column = seconds.get(second, 0)
            if row >= len(matrix) or column >= len(matrix[row]):
                return None
            return matrix[row][column]

        nothing = ((0, 0, 0), (0, 0, 0))
        pairs = []
        for row, cells in enumerate(matrix):
            first = min((glyph for glyph in coverage if firsts.get(glyph, 0) == row), default=None)
            for column, cell in enumerate(cells):
                second = min((glyph for glyph, number in seconds.items() if number == column), default=None)
                if cell != nothing and first is not None and second is not None:
                    pairs.append((first, second))
        return PairPosition(coverage, find, sub.ValueFormat2 != 0, pairs)
    raise NoRule("a pair positioning of format %d" % sub.Format)


def marks_of(coverage, array, ids):
    """A mark array as glyph -> (class, anchor)."""
    marks = {}
    for name, record in zip(coverage.glyphs, array.MarkRecord):
        marks.setdefault(ids[name], (record.Class, anchor_of(record.MarkAnchor) or (0, 0)))
    return marks


def mark_to_base(sub, ids):
    if sub.Format != 1:
        raise NoRule("marks on bases of format %d" % sub.Format)
    bases = {}
    for name, record in zip(sub.BaseCoverage.glyphs, sub.BaseArray.BaseRecord):
        bases.setdefault(ids[name], [anchor_of(anchor) for anchor in record.BaseAnchor])
    return MarkToBase(marks_of(sub.MarkCoverage, sub.MarkArray, ids), bases)


def mark_to_mark(sub, ids):
    if sub.Format != 1:
        raise NoRule("marks on marks of format %d" % sub.Format)
    unders = {}
    for name, record in zip(sub.Mark2Coverage.glyphs, sub.Mark2Array.Mark2Record):
        unders.setdefault(ids[name], [anchor_of(anchor) for anchor in record.Mark2Anchor])
    return MarkToMark(marks_of(sub.Mark1Coverage, sub.Mark1Array, ids), unders)


# The lookup kinds there is a rule for, by table and by the kind's number.
READERS = {
    "GSUB": {
        1: lambda sub, ids: Single({ids[name]: ids[other] for name, other in sub.mapping.items()}),
        2: lambda sub, ids: Multiple({ids[name]: named(others, ids) for name, others in sub.mapping.items()}),
        4: lambda sub, ids: Ligature(
            {
                ids[first]: [(named(made.Component, ids), ids[made.LigGlyph]) for made in listed]
                for first, listed in sub.ligatures.items()
            }
        ),
        5: lambda sub, ids: context_rules(sub, ids, False, "Sub"),
        6: lambda sub, ids: context_rules(sub, ids, True, "Sub"),
    },
    "GPOS": {
        1: single_position,
        2: pair_position,
        4: mark_to_base,
        6: mark_to_mark,
        7: lambda sub, ids: context_rules(sub, ids, False, "Pos"),
        8: lambda sub, ids: context_rules(sub, ids, True, "Pos"),
    },
}


class Layout:
    """GSUB or GPOS as fontTools read it: the scripts with their language
    systems, the features, the lookups."""

    def __init__(self, font, tag, ids):
        self.tag = tag
        self.scripts = {}
        self.features = []
        self.lookups = []
        if tag not in font:
            return
        table = font[tag].table
        if table.Version >> 16 != 1:
            raise NoRule("%s of a version not known" % tag)
        if getattr(table, "FeatureVariations", None) is not None:
            raise NoRule("%s replaces features under conditions" % tag)
        if table.LookupList is not None:
            self.lookups = [self.read(lookup, ids) for lookup in table.LookupList.Lookup]
        if table.FeatureList is not None:
            self.features = [
                (record.FeatureTag, list(record.Feature.LookupListIndex)) for record in table.FeatureList.FeatureRecord
            ]
        if table.ScriptList is not None:
            for record in table.ScriptList.ScriptRecord:
                languages = {}
                for language in record.Script.LangSysRecord:
                    languages.setdefault(language.LangSysTag, language.LangSys)
                self.scripts.setdefault(record.ScriptTag, (record.Script.DefaultLangSys, languages))

    def read(self, lookup, ids):
        readers = READERS[self.tag]
        if lookup.LookupType not in readers:
            raise NoRule("%s lookups of the kind %d" % (self.tag, lookup.LookupType))
        subtables = [readers[lookup.LookupType](sub, ids) for sub in lookup.SubTable]
        flags = lookup.LookupFlag
        mark_set = (getattr(lookup, "MarkFilteringSet", 0) or 0) if flags & USE_MARK_SET else 0
        return Lookup(flags, mark_set, [subtable for subtable in subtables if subtable is not None])

    def system(self, script, language):
        """The language system for a script and a language, "" for the
        default of either; None when the table has none for them."""
        for tag in (script, "DFLT", "dflt", "latn"):
            if tag and tag in self.scripts:
                default, languages = self.scripts[tag]
                break
        else:
            return None
        for tag in (language, "dflt"):
            if tag and tag in languages:
                return languages[tag]
        return default

    def tags(self, script, language):
        """The tags of the features the language system has, each once."""
        system = self.system(script, language)
        tags = []
        if system is not None:
            for index in system.FeatureIndex:
                if index < len(self.features) and self.features[index][0] not in tags:
                    tags.append(self.features[index][0])
        return tags

    def planned(self, script, language, tags):
        """The lookups applied for the features `tags`, in their order."""
        system = self.system(script, language)
        if system is None:
            return ()
        chosen = []
        if system.ReqFeatureIndex != 0xFFFF:
            chosen.append(system.ReqFeatureIndex)
        for tag in tags:
            for index in system.FeatureIndex:
                if index < len(self.features) and self.features[index][0] == tag:
                    chosen.append(index)
                    break
        lookups = set()
        for index in chosen:
            if index < len(self.features):
                lookups.update(lookup for lookup in self.features[index][1] if lookup < len(self.lookups))
        return tuple(sorted(lookups))


class Font:
    """A font as fontTools read it, and the shaping of a run with it."""

    def __init__(self, path):
        with open(os.path.join(FONTS_DIR, path), "rb") as file:
            self.sha256 = hashlib.sha256(file.read()).hexdigest()
        self.file = path
        font = TTFont(os.path.join(FONTS_DIR, path), lazy=False)
        ids = font.getReverseGlyphMap()
        order = font.getGlyphOrder()
        self.count = len(order)
        self.advances = [font["hmtx"].metrics[name][0] for name in order]
        self.gdef = Gdef(font, ids)
        self.gsub = Layout(font, "GSUB", ids)
        self.gpos = Layout(font, "GPOS", ids)

    def shape(self, glyphs, substitutions, positionings, backward):
        """The run `glyphs` shaped by the GSUB lookups `substitutions` and
        the GPOS lookups `positionings`, as the glyphs it is drawn with."""
        run = Run(glyphs)
        for item in run.items:
            self.gdef.classify(item, KIND_NONE)
        applier = Applier(run, self.gdef, self.gsub.lookups, backward)
        for index in substitutions:
            applier.run_lookup(index)
        for item in run.items:
            item.advance = self.advances[item.glyph] if item.glyph < self.count else 0
        applier = Applier(run, self.gdef, self.gpos.lookups, backward)
        for index in positionings:
            applier.run_lookup(index)
        finish(run.items, backward)
        if backward:
            run.items.reverse()
        return run.items


# How many glyphs stand in a run of every glyph, how many a written run has
# at most, how many sequences are made from one subtable of a kind, how many
# ligatures get marks among their glyphs, and how many mixtures are made.
EVERY = 8
MOST_GLYPHS = 24
MOST_OF = {
    Ligature: 12,
    RulesByGlyph: 8,
    RulesByClass: 8,
    RuleByCoverage: 3,
    PairPosition: 48,
    MarkToBase: 12,
    MarkToMark: 12,
}
MARKED = 24
MIXTURES = 256


def spread(items, most):
    """At most `most` of the items, evenly spaced, the first and last among them."""
    if len(items) <= most:
        return list(items)
    return [items[i * (len(items) - 1) // (most - 1)] for i in range(most)]


def member(classes, number, last, count):
    """A glyph of the class `number`: the lowest, or the highest for `last`."""
    if number == 0:
        glyphs = range(count - 1, -1, -1) if last else range(count)
        return next((glyph for glyph in glyphs if glyph not in classes), None)
    found = [glyph for glyph, one in classes.items() if one == number]
    if not found:
        return None
    return max(found) if last else min(found)


def samples(font, subtable):
    """Runs of glyphs the subtable has a rule for."""
    made = []
    if isinstance(subtable, Ligature):
        for first, listed in sorted(subtable.sets.items()):
            made.extend([first] + rest for rest, _ in listed)
    elif isinstance(subtable, RulesByGlyph):
        for first, rules in sorted(subtable.sets.items()):
            made.extend(before[::-1] + [first] + rest + after for before, rest, after, _ in rules)
    elif isinstance(subtable, RulesByClass):
        before_classes, classes, after_classes = subtable.tables
        for number, rules in enumerate(subtable.sets):
            firsts = sorted(glyph for glyph in subtable.firsts if classes.get(glyph, 0) == number)
            if not firsts:
                continue
            for before, rest, after, _ in rules or ():
                for last in (False, True):
                    glyphs = (
                        [member(before_classes, one, last, font.count) for one in reversed(before)]
                        + [firsts[-1] if last else firsts[0]]
                        + [member(classes, one, last, font.count) for one in rest]
                        + [member(after_classes, one, last, font.count) for one in after]
                    )
                    if None not in glyphs:
                        made.append(glyphs)
    elif isinstance(subtable, RuleByCoverage):
        before, rest, after, _ = subtable.rule
        coverages = [sorted(coverage) for coverage in before[::-1] + [subtable.firsts] + rest + after]
        if all(coverages):
            made.append([coverage[0] for coverage in coverages])
            made.append([coverage[len(coverage) // 2] for coverage in coverages])
            made.append([coverage[-1] for coverage in coverages])
    elif isinstance(subtable, PairPosition):
        made.extend([first, second] for first, second in subtable.pairs)
    elif isinstance(subtable, (MarkToBase, MarkToMark)):
        stands = sorted(subtable.bases if isinstance(subtable, MarkToBase) else subtable.unders)
        marks = spread(sorted(subtable.marks), 3)
        for stand in spread(stands, 3):
            made.extend([stand, mark] for mark in marks)
        if stands and marks:
            made.append([stands[0], marks[0], marks[-1]])
            made.append([stands[-1], marks[-1], marks[0], marks[0]])
    return made


def written_runs(font):
    """The runs written out for a font: sequences made from its lookups,
    ligatures with marks among their glyphs, marks on marks on a base, and
    mixtures of all of them."""
    sequences = []
    ligatures = []
    stands = {}
    stacks = []
    for layout in (font.gsub, font.gpos):
        for lookup in layout.lookups:
            for subtable in lookup.subtables:
                made = samples(font, subtable)
                sequences.extend(spread(made, MOST_OF.get(type(subtable), 0)) if made else [])
                if isinstance(subtable, Ligature):
                    ligatures.extend(made)
                if isinstance(subtable, MarkToBase):
                    for mark, (number, _) in sorted(subtable.marks.items()):
                        for base, anchors in sorted(subtable.bases.items()):
                            if number < len(anchors) and anchors[number] is not None:
                                stands.setdefault(mark, base)
                                break
                if isinstance(subtable, MarkToMark):
                    stacks.extend(spread(made, MOST_OF[MarkToMark]))
    marks = []
    if font.gdef.kinds is not None:
        marks = spread(sorted(glyph for glyph, kind in font.gdef.kinds.items() if kind == KIND_MARK), 2)
    for glyphs in spread(ligatures, MARKED):
        for mark in marks:
            sequences.append(glyphs[:1] + [mark] + glyphs[1:])
            sequences.append(glyphs + [mark])
            sequences.append(glyphs[:1] + [mark] + glyphs[1:] + [mark])
    for glyphs in stacks:
        if glyphs[0] in stands:
            sequences.append([stands[glyphs[0]]] + glyphs)
    kept = []
    for glyphs in sequences:
        if glyphs and len(glyphs) <= MOST_GLYPHS and max(glyphs) < font.count and glyphs not in kept:
            kept.append(glyphs)
    state = 0x2545F491

    def draw():
        nonlocal state
        state = (state * 1664525 + 1013904223) & 0xFFFFFFFF
        return state >> 16

    mixed = []
    for _ in range(MIXTURES if len(kept) > 1 else 0):
        glyphs = []
        for _ in range(2 + draw() % 3):
            glyphs = glyphs + kept[draw() % len(kept)]
        mixed.append(glyphs[:MOST_GLYPHS])
    return kept + mixed


def every_glyph(font):
    """Every glyph of the font, `EVERY` to a run, in the order of their numbers."""
    return [list(range(start, min(start + EVERY, font.count))) for start in range(0, font.count, EVERY)]


def cases_of(font):
    """The cases of a font, each as (script, language, feature tags,
    backward, GSUB lookups, GPOS lookups): no features at all, and then for
    each language system all its features and each feature alone, as far as
    that gives lookups no case before it has."""
    cases = []
    seen = set()

    def add(script, language, tags, backward):
        substitutions = font.gsub.planned(script, language, tags)
        positionings = font.gpos.planned(script, language, tags)
        key = (substitutions, positionings, backward)
        if key not in seen:
            seen.add(key)
            cases.append((script, language, tags, backward, substitutions, positionings))

    add("", "", [], False)
    systems = [("", "")]
    for script in sorted(set(font.gsub.scripts) | set(font.gpos.scripts)):
        languages = set()
        for layout in (font.gsub, font.gpos):
            if script in layout.scripts:
                languages.update(layout.scripts[script][1])
        systems.append((script, ""))
        systems.extend((script, language) for language in sorted(languages))
    for script, language in systems:
        tags = font.gsub.tags(script, language)
        tags = tags + [tag for tag in font.gpos.tags(script, language) if tag not in tags]
        add(script, language, tags, False)
        if script in BACKWARD_SCRIPTS:
            add(script, language, tags, True)
        for tag in tags:
            add(script, language, [tag], False)
    return cases


def shaped(font, case, runs):
    """Each of `runs` shaped for a case, as lists of (glyph, cluster,
    advance, offset to the right, offset up)."""
    _, _, _, backward, substitutions, positionings = case
    return [
        [
            (item.glyph, item.cluster, item.advance, item.x_offset, item.y_offset)
            for item in font.shape(glyphs, substitutions, positionings, backward)
        ]
        for glyphs in runs
    ]


def digest(results):
    """The SHA-256 of shaped runs, as reference.zig says they are hashed."""
    sha = hashlib.sha256()
    for glyphs in results:
        sha.update(struct.pack("<I", len(glyphs)))
        for glyph in glyphs:
            sha.update(struct.pack("<IIiii", *glyph))
    return sha.hexdigest()


def changed(font, runs, results):
    """How many of the runs came out other than they went in."""
    count = 0
    for glyphs, result in zip(runs, results):
        same = [(glyph, place, font.advances[glyph], 0, 0) for place, glyph in enumerate(glyphs)]
        count += result != same
    return count


def written(font):
    """The Zig file of one font's cases."""
    runs = written_runs(font)
    every = every_glyph(font) + runs
    lines = [
        "// SPDX-License-Identifier: MIT",
        "//! %s" % font.file,
        "//! sha256 %s" % font.sha256,
        "//!",
        "//! What a second applier of that font's lookups shapes its runs to, as",
        "//! `../reference.zig` says a font's cases are written: what",
        "//! truetypeshaping.library's host tests compare its shaping of the",
        "//! same runs with. Written by scripts/shape-reference.py and never",
        "//! edited; it is written again when the font's pin in",
        "//! scripts/fetch-fonts.sh changes.",
        "",
        'const reference = @import("../reference.zig");',
        "",
        "pub const font: reference.Font = .{",
        '    .file = "%s",' % font.file,
        '    .sha256 = "%s",' % font.sha256,
        "    .glyph_count = %d," % font.count,
    ]
    if runs:
        lines.append("    .runs =")
        lines.extend("    \\\\" + " ".join("%04X" % glyph for glyph in glyphs) for glyphs in runs)
        lines.append("    ,")
    else:
        lines.append('    .runs = "",')
    lines.append("    .cases = &.{")
    for case in cases_of(font):
        script, language, tags, backward, _, _ = case
        results = shaped(font, case, every)
        lines.append(
            '        .{ .script = "%s", .language = "%s", .features = "%s", .backward = %s, .changed = %d, .sha256 = "%s" },'
            % (script, language, "".join(tags), "true" if backward else "false", changed(font, every, results), digest(results))
        )
    lines.append("    },")
    lines.append("};")
    return "\n".join(lines) + "\n"


def show(stem, number):
    """Prints each shaped run of a font's case, a run a line: its place
    among the runs, then each glyph as glyph/cluster/advance/right/up."""
    paths = [path for path, name in FONTS if name == stem]
    if not paths:
        sys.exit("shape-reference: no font is written as %s" % stem)
    font = Font(paths[0])
    cases = cases_of(font)
    if number >= len(cases):
        sys.exit("shape-reference: %s has %d cases" % (stem, len(cases)))
    runs = every_glyph(font) + written_runs(font)
    for place, glyphs in enumerate(shaped(font, cases[number], runs)):
        print("%d: %s" % (place, " ".join("%d/%d/%d/%d/%d" % glyph for glyph in glyphs)))


def main(arguments):
    if len(arguments) == 3 and arguments[0] == "--show" and arguments[2].isdigit():
        show(arguments[1], int(arguments[2]))
        return
    check = arguments == ["--check"]
    if arguments and not check:
        sys.exit(__doc__)
    stale = 0
    for path, stem in FONTS:
        target = os.path.join(OUT_DIR, stem + ".zig")
        try:
            text = written(Font(path))
        except NoRule as missing:
            sys.exit("shape-reference: %s: no rule for %s" % (path, missing))
        if check:
            try:
                with open(target, encoding="utf-8") as file:
                    same = file.read() == text
            except FileNotFoundError:
                same = False
            if not same:
                stale += 1
                print("shape-reference: %s is not what %s gives" % (os.path.relpath(target, ROOT), path))
            continue
        os.makedirs(OUT_DIR, exist_ok=True)
        with open(target, "w", encoding="utf-8") as file:
            file.write(text)
        print("shape-reference: %s" % os.path.relpath(target, ROOT))
    if stale:
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1:])
