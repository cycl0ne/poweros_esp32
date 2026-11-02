# Shares

The shares of other machines added to this one. A server is typed in, it
is asked what shares it has, and one of them is mounted as a device - once,
and at every start after it.

```
Shares SERVER/K,USER/K,DOMAIN/K
```

`SERVER` is a server to look at as soon as the window opens, `USER` and
`DOMAIN` who to log on to it as. Without them the window opens on what this
machine already knows.

## The window

**Server.** The field at the top takes a server however it is written:
`nas.lan`, `//nas.lan`, `\\nas.lan`, `smb://nas.lan`, any of them with
`:port` after the name where the server is not on SMB's own port, and an
IPv6 address in brackets (`//[fd00::1]`). A share written after the server
is ignored - the shares are what is being asked for.

**Connect** logs on and asks the server what shares it has. With nothing
filled in the logon is anonymous, which many servers take and some refuse.
A server that will not have an anonymous logon, or that logs one on and
then will not say what shares it has, is asking for a user and a password:
a window opens for them, and the question is put again with what was typed.
**Log on...** opens that window at any time, to come back to the same
server as somebody else.

The line under the field says what came of the last look: the dialect, how
the session is signed and encrypted, how many shares there are - or where
it stopped, and why.

**Shares on the server** lists what the server answered: the share's name,
what kind of share it is, the comment the server's own settings give it,
and the device it is already mounted as, if any. Kind is what the server
calls the share: `Disk` holds files, `Pipe` is a pipe the server talks
over, `Printer` a print queue, and a star means the server keeps that name
for its own workings - `ADMIN$`, a drive's `C$`. Only a share that holds
files can be mounted; picking any other says why not.

Picking one fills in **Mount as** with a device name made from the share's
own: in capitals, with anything a device name may not hold made an
underscore, and cut to thirty characters. It can be typed over - a name
already taken is said so, and another name mounts the same share beside the
first. **Read only** writes nothing to the share whatever the server would
allow; **Encrypted** mounts it only if every message can be encrypted.

**Mount** writes the share's file in `DEVS:Shares/` and, when there is a
password to keep, its hash in `ENVARC:Sys/net/shares/`, then mounts it. The
share is on the device list at once, and it comes back at every start,
since the startup mounts every share there is a file for. A mount that does
not come off takes those files away again and says why.

**Shares on this machine** is everything this machine knows: a line for
every share file, whether its device is mounted or not. **Mount** and
**Dismount** put one on the device list and take it off - a share with
anything open or locked on it is not dismounted - and **Forget** takes the
share off the machine altogether, its file and its kept password with it.

## The password

The password is never kept as it was typed. It is hashed - MD4 over its
UTF-16, which is all the logon needs - and the hash is what is written in
`ENVARC:Sys/net/shares/<name>`, where the next start reads it. **Keep the
password** in the logon window says whether to write it down at all; with
it off, the share is mounted now and the next start asks for nothing,
mounting it anonymously or not at all.

## What it is built on

`C:net/MountShare` does the mounting and the dismounting, and `smb-handler`
serves the share once it is mounted; the share files are theirs as much as
this program's, so a share added here is a share `MountShare NAS` mounts
and `MountShare ALL` brings back. The share list itself is the server's own
account of what it has, asked of the `srvsvc` service on its `IPC$` pipe -
the same question `MountShare LIST SERVER=//nas.lan` asks from a shell.
