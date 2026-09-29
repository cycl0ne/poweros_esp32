# A document to read

This file is here so that `markdown.datatype` can be tried on the
machine itself. It uses every mark the class knows, so that what is
drawn can be looked at rather than argued about.

## Emphasis

A word in *italic*, a word in **bold**, and a name in `fixed pitch`.
A paragraph's own line ends are spaces, so these three lines are
one paragraph and are wrapped to the window rather than to the file.

## Lists

- The first item.
- The second, which is long enough that it has to be wrapped, so that
  the indent of a wrapped item can be seen.
  - An item one level in.
1. A numbered item keeps its number.
2. And so does this one.

## A listing

```
    while (at < from.len) : (at += 1) {
        if (from[at] == '\n') break;
    }
```

## Quoting and links

> A quoted line is indented and set back.

See [the datatypes guide](sdk/docs/guides/datatypes.md), and
![a picture](Colours.png) which is named rather than fetched.

---

The rule above ends the document.
