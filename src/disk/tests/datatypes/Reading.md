# A document to read

This file is here so that `markdown.datatype` can be tried on the
machine itself. It uses every mark the class knows, so that what is
drawn can be looked at rather than argued about - and set beside the
same file on GitHub, it should look much the same.

## Emphasis

A word in *italic*, a word in **bold**, both at once in ***both***,
one ~~struck through~~, and a name in `fixed pitch`. A paragraph's own
line ends are spaces, so these lines are one paragraph and are wrapped
to the window rather than to the file.\
A backslash at the end of a line breaks it there, and so do two spaces.

## Lists

- The first item.
- The second, which is long enough that it has to be wrapped, so that
  the indent of a wrapped item can be seen.
  - An item one level in.
    - And one two levels in.
- The last.

1. A numbered item keeps its number.
2. And so does this one.
   1. A list inside counts in Roman numerals.
   2. As GitHub does.
      1. And one inside that in letters.

- [x] A task that is done.
- [ ] A task that is not.

A list with blank lines between its items is loose:

1. Its items stand apart.

2. As far apart as paragraphs.

## Headings

### The third level

#### The fourth level

##### The fifth level

###### The sixth level

## A listing

```zig
while (at < from.len) : (at += 1) {
    if (from[at] == '\n') break;
}
```

## A table

| Board         | Processor   | Memory | Screen |
|:--------------|:-----------:|-------:|--------|
| ESP32-S3      | Xtensa LX7  | 8 MB   | yes    |
| VisionFive 2  | RISC-V U74  | 8 GB   | HDMI   |
| QEMU virt     | Cortex-A76  | 512 MB | virtio |

## Quoting and links

> A quote stands behind a bar, set back in a paler ink.
>
> > And a quote inside a quote behind two.

See [the datatypes guide](sdk/docs/guides/datatypes.md), the address
<https://github.com/cycl0ne/poweros_esp32>, and
![a picture](Colours.png) which is named rather than fetched.

---

The rule above ends the document.
