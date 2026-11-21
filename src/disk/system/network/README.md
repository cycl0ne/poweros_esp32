# Network

An interface's addresses, set in a window: DHCP or a fixed address, the
name servers, IPv6. What is saved is the interface's file, which the
system reads at every start; once asked, the interface is started again
with it at once.

```
Network INTERFACE/K
```

`INTERFACE` is the interface to start on, by its file's name (`ETH0`) or
the interface's (`eth0`); without it, the window starts on the first file
there is. SYS:System/WiFi's **Settings...** opens it on the radio's
interface.

## The window

**Interface.** Every file in `DEVS:NetInterfaces/` is an interface the
start brings up, named after the file in lower case: `ETH0` is `eth0`.
The chooser names each by its file, its device and its unit. The line
under it says whether the interface is up now - its address, its net as a
prefix length, and whether DHCP gave it, it is fixed, or the interface gave
itself one because no DHCP server answered - asked again every two
seconds.

**IPv4.** **Configure** is DHCP - a server on the network hands the
address, the net mask, the gateway and the name servers - or a fixed
address, given here:

- **Address** - the interface's address, `192.168.1.20`.
- **Net mask** - `255.255.255.0`, or the prefix length, `24` or `/24`,
  which is saved as the mask it means.
- **Gateway** - the router the default route goes through. Without one,
  only the interface's own net is reached.

Under DHCP the three fields are dimmed and the file keeps what it says
for them, so that setting the address back to fixed finds them again.

**Names.** **Name servers** are the servers names are asked of, IPv4 or
IPv6, with a space or a comma between them - up to four of each kind.
They are asked as well as those DHCP gives. **Domain** is where a name
without a dot is looked for: with `home.lan`, `nas` is asked as
`nas.home.lan`.

**IPv6.** **Automatic** gives the interface its link-local address and
one from every prefix the routers on its link announce; **Fixed address**
the link-local one and the **Address** given, with its **Prefix length**
(64 when it is empty) and a **Gateway** for the default route; **Off**
none at all.

**Save** sees first that every address is one, and says which is not.
It then writes the file: only what the window sets is changed - every
comment and every other keyword stay as they were written - and an empty
field takes its keyword out. When the interface is up, it asks whether to
start it again with the settings now. That ends every connection it
carries, a session over it as well: `C:net/RemNetInterface` takes it down
and `C:net/AddNetInterface` brings it up from the file, and if that fails
the line says what it said. Otherwise the settings are taken when the
interface is next brought up - at the next start, or with
`C:net/AddNetInterface`.

**Revert** reads the file again, and leaves what the window was changed
to.

## The file

The window writes the keywords of the interface file:

```
Device     = networks/emac.device
Unit       = 0
Configure  = FIXED
Address    = 192.168.1.20
NetMask    = 255.255.255.0
Gateway    = 192.168.1.1
NameServer = 192.168.1.1
NameServer = 2620:fe::fe
Domain     = home.lan
```

A keyword the file has keeps its place and its spelling and gets the new
value; one it lacks is added at the end. Everything else the file can
say - `Device`, `MTU`, the Wi-Fi `Network`, `Start` and the rest - is set
in the file itself, and the network guide says what each does.
