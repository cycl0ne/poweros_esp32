# Update

This system brought up to a newer release package, in a window: what
would change is shown before anything is written, the update is done with
a gauge, and the machine is restarted on it.

```
Update FROM
```

`FROM` is the package to look at - a directory on a volume, or an address
a server answers (`http://10.0.2.2:8080/`). Without it the window looks
where `ENVARC:Sys/update.prefs` says, else where the system was installed
from.

## The window

**A check as it opens.** The package's list is held against the one this
machine was given, and the field at the top shows the package that was
read. Every path something would happen to is a row: what would happen to
it, the path, and how much would be written for it -

- `new` a file the build has begun to ship, `newer` one it changed,
  `again` one that went missing here;
- `kept` a file changed on this machine where the package changed it too,
  which stays as it is;
- `gone` one the build dropped, `drawer` a drawer to be made;
- `list` the package's list, written as this machine's own at the end.

The two lines over the list say what it comes to - how many files would be
written and how much, deleted, kept and made - and what to do about it.

**Check** looks again, at what the field holds: another package is typed
in and checked, Return in the field doing the same. Two switches change
what is looked at, and changing either checks again:

- **With the kernel** writes the files the firmware reads as well, into
  the partition it reads them from. It starts as `BOOT` in `update.prefs`
  has it.
- **Replace changed files** writes the package's own over a file that was
  changed on this machine, where the package changed it too. A file that
  only this machine changed is never touched.

**Update** writes what the check found, the gauge filling by the bytes
written. Every file is fetched beside the one it replaces, checked
against the list's length and sum, and only then put in its place, and
the system volume is given a snapshot before the first one.

**Stop** ends the update where it is. What was written stays, the
machine's list stays as it was, and the next check finds what is left.

**Restart** is there once an update has written something, and starts the
machine again through `C:Reboot`. With the kernel written to a machine
whose firmware starts from either of a pair of partitions, the new one is
written into the partition not in use, and Restart starts on it for one
start only: a kernel that does not come up costs one start, and the one
after it is on the partition that worked.

**Keep this system** is there when this system came up on the partition
the firmware was told to try, as the firmware itself says, and makes
that partition the one the firmware starts from - the step that says the
new kernel is good. Before the restart, after a try that did not come up
and once it is kept, the button is not there.

The work is done on a process of its own, so the window answers while a
package is read over the network; closing the window stops the update
first.

## See also

- `C:Update`, the same from the shell, and how it compares and what it
  writes: the install guide's *Bringing it up to date*.
- **Update** in `SYS:Programs/Prefs`: where the machine looks, and
  whether it looks at every start.
