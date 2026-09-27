# BsdSockTest

`C:test/BsdSockTest` measures bsdsocket.library against the BSD socket
API: 142 tests in twelve categories, covering a socket's life, data
transfer, options, `WaitSelect`, signals and socket events, names,
address utilities, handing a socket on, the error number, the descriptor
table, ICMP echo and throughput.

Its license is GPL-3.0-only ([LICENSE](LICENSE)). It is Thomas Dye's
bsdsocktest (github.com/tbdye/bsdsocktest) written in Zig against the SDK.

## Running it

```
BsdSockTest CATEGORY/K,HOST/K,PORT/N,LOG/K,ALL/S,LOOPBACK/S,NETWORK/S,LIST/S,VERBOSE/S
```

| Argument   | What it does |
|------------|--------------|
| `CATEGORY` | Run one category (`CATEGORY sockopt`) |
| `HOST`     | The address or name of a machine running `helper.py`: the network tests run too |
| `PORT`     | The first port the tests use (7700; they use up to 200 above it) |
| `LOG`      | Write the whole run as TAP version 12 to this file |
| `ALL`      | Every category (what runs without arguments) |
| `LOOPBACK` | Only the categories that need no helper |
| `NETWORK`  | Only the categories that use the helper |
| `LIST`     | Name the categories and stop |
| `VERBOSE`  | A line per test on the screen, not only per category |

Without `HOST` everything runs over the loopback interface and the tests
that need a peer on the network are skipped. The screen gets a line per
category with its count, the tests that failed by number, and what the
category noted (rates, round trips); the log gets every test and every
detail. Ctrl-C stops the run between tests.

The return code is 0 when every test passed or was skipped, 5 when one
failed, 20 when the run could not start or was stopped.

## Skips

A test of a call or tag the library does not have is skipped with its
name (`no Dup2Socket`, `no SBTC_ERRNOLONGPTR`), so the skips in the log
are also the list of what is missing. A test that needs the helper says
`host helper not connected`.

## The host helper

`helper.py` runs on another machine (Python 3, no packages):

```
python3 helper.py [-v] [--bind ADDR] [--ctrl-port PORT]
```

It listens on 8700 (control: `OK` on connecting, `CONNECT <port>`, `QUIT`),
8701 (TCP echo), 8702 (UDP echo), 8703 (TCP sink) and 8704 (TCP source).
Then `BsdSockTest HOST <its address>`.

In QEMU's user network the host is `10.0.2.2`, so
`BsdSockTest HOST 10.0.2.2` with the helper running on the host machine.
Test 41, where the helper connects back, fails there: the host sees the
connection come from itself, and nothing forwards the port to the
machine.

## Categories

| Category     | Tests   | Needs   | What |
|--------------|---------|---------|------|
| `socket`     | 1-23    | -       | Socket, Bind, Listen, Connect, Accept, Shutdown, CloseSocket, GetSockName, GetPeerName |
| `sendrecv`   | 24-42   | helper for 39-42 | Send/Recv, SendTo/RecvFrom, MSG_PEEK, MSG_OOB, sockets that never wait, 64 and 256 KiB echoed |
| `sockopt`    | 43-57   | -       | SO_* and TCP_NODELAY set and read back, SO_ERROR, FIONBIO, FIONREAD, FIOASYNC |
| `waitselect` | 58-72   | -       | readiness, timeouts, signals, `count`, descriptors past 64, connect and close |
| `signals`    | 73-87   | -       | SocketBaseTagList masks and table size, SO_EVENTMASK, GetSocketEvents |
| `dns`        | 88-104  | helper for 103-104 | GetHostByName, GetHostByAddr, GetHostName |
| `utility`    | 105-114 | -       | Inet_NtoA, Inet_Addr |
| `transfer`   | 115-119 | -       | ReleaseSocket and ObtainSocket |
| `errno`      | 120-126 | -       | Errno, SetErrnoPtr of 1, 2 and 4 bytes, a stale error and Connect |
| `misc`       | 127-131 | -       | GetDTableSize, CloseSocket after Shutdown, a full table of sockets |
| `icmp`       | 132-136 | helper for 133-135 | echo requests on a raw socket |
| `throughput` | 137-142 | helper for 138, 140, 142 | TCP and UDP rates |

A test's number stays the same from run to run: every test ends in
exactly one result.

## Files

- `bsdsocktest.zig` - the arguments and the category table.
- `tap.zig` - the screen's summary and the TAP log.
- `run.zig` - what the tests share: the libraries, the buffers, loopback
  pairs, the test pattern, the time.
- `helper.zig` - the helper's control protocol.
- a file per category.
- `helper.py` - the host helper.
