# serve

Hands out a release package over HTTP, so a machine installs itself or
brings itself up to date with nothing but a network.

```
serve [--port=<n>] [--host=<address>] <dir>
```

`./zig build serve -Dboard=<board>` gathers the package first and then
hands that one out (`-Dserve-port=`, 8080 by default), so one command is
the whole of the host's side:

```
serve: ./.zig-cache/.../package-qemu_virt on http://0.0.0.0:8099/ - in QEMU's user network http://10.0.2.2:8099/ (quit with Ctrl-C)
serve: GET /manifest 200 24635
serve: GET /boot/kernel.bin 200 1657216
```

GET and HEAD, and nothing else: there is no way to write anything through
it, no listing of a directory, and no path outside the one directory it
was given. What it will answer for is exactly what a manifest may name
(`sdk/libs/install/manifest.zig`'s `pathOk`) - relative, no `..`, no
device name, no control or pattern character - so the server, the tool
that writes a package and the commands that read one all take the same
view of what a path in a package is. `%20` and the rest are read back, so
a name with a blank in it is fetched as it stands in the manifest. `/`
answers with one line saying where to start, which is `GET /manifest`.

A directory with no `manifest` in it is not a package, and the server says
so and stops rather than letting a machine find out halfway through.

It serves one connection at a time, kept open while the client wants it: a
package is a few hundred files and one machine installs from it. A request
it refuses is answered and the connection closed.

On QEMU's user network the host is 10.0.2.2, so a machine in QEMU reaches
`http://10.0.2.2:<port>/` with nothing in the way:

```sh
./zig build package -Dboard=qemu_virt    # one terminal
./zig build serve -Dboard=qemu_virt      # the other, and it gathers it again
```

By hand it serves any directory that holds a package - one copied from
another machine, or one whose `boot/` was filled in by hand - and
`tools/mkpackage --check <dir>` says whether that package is whole.
