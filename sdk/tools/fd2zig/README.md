# fd2zig

Generates a library's Zig interface (`sdk/interface/<lib>.zig`) from its
jump table (`sdk/fd/<lib>_lib.fd`). The `.fd` file is the source of truth
for what a library offers and in which slot.

```sh
fd2zig <in.fd> <out.zig>      # write the interface
fd2zig --check <in.fd> <out.zig>   # fail if it is out of date
```

`zig build fd` writes every interface; `zig build test` runs the `--check`
form, so a stale interface fails the tests. Hand edits to
`sdk/interface/*.zig` are therefore always lost: change the `.fd`.

## The .fd format

```
//! Doc comment for the generated file
##include exec/exec as exec        # types the signatures use
##basetype DosBase                 # the library's base
##name dos.library
##bias 4                           # first slot's offset (resources: 0)
##public
/// Doc comment for the next function
bool Open([*:0]const u8 name, i32 mode)
##reserve 2                        # gaps in a fixed jump table
##end
```

Each function line takes the next slot. New functions go at the end, except
for libraries whose slots are fixed (exec, utility, timer, serial),
where a function must stay in its ROM slot and `##reserve` marks the gaps.

## What it generates

- `NAME` and `VERSION` of the library,
- `LVO`: the slot of each function,
- `Fn`: the type of each function,
- the base (`DosBase`, `ExecBase`, …) with a method per function, which
  calls through the jump table.

The implementation side is checked against this: each library has an
`lvo<Name>` function whose type a comptime block compares with `Fn.<Name>`
(`exec.libraries.sameSignature`), so a signature that drifts from the `.fd`
fails to build.
