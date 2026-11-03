#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Boot a QEMU virt machine with its display in a browser tab, for a host
# with no screen of its own - a machine developed on over the network.
#
#     scripts/qemu-web.sh                  the AArch64 machine (virt64-display)
#     scripts/qemu-web.sh virt-display     the RISC-V one
#     scripts/qemu-web.sh virt64-ramfb -Dgames=true
#                                          another step, and build options after it
#
# QEMU serves the picture over VNC, and over VNC in a WebSocket beside it
# (`websocket=on`), which is what a browser speaks; noVNC, the client
# that runs in the browser, is served from toolchain/novnc by Python's
# own web server (`scripts/fetch-novnc.sh` fetches it). The console stays
# on this terminal, as in every display step, and Ctrl-A X ends the
# machine - or close its tab and press Ctrl-C here.
#
# All three ports listen on the loopback alone: the machine's display
# takes no password, so nothing of it is offered to the network. Reach
# them from elsewhere through an SSH tunnel (`ssh -L 6080:localhost:6080
# -L 5700:localhost:5700 host`), or, in code-server, through its own
# proxy - it asks the browser for the password it was given and passes
# WebSockets through, and the script prints that address when it runs
# under one ($VSCODE_PROXY_URI).
#
# A host with no sound card of its own takes `-Daudio=none` after the
# step, or QEMU's audio backend writes its complaints into the console
# before the machine starts.
#
# Environment: VNC_DISPLAY the VNC display number (0: ports 5900 and
# 5700), WEB_PORT the port noVNC is served on, QMP the Unix socket
# scripts/qemu-shot.py takes pictures through.
set -eu

step=${1:-virt64-display}
if [ $# -gt 0 ]; then shift; fi
case $step in
    virt64-*) board=qemu_virt_a64 ;;
    virt-*)   board=qemu_virt ;;
    *) echo "$0: $step is not a display step (virt-display, virt-ramfb, virt64-display, virt64-ramfb)" >&2; exit 1 ;;
esac

root=$(cd "$(dirname "$0")/.." && pwd)
novnc=$root/toolchain/novnc
display=${VNC_DISPLAY:-0}
web_port=${WEB_PORT:-6080}
vnc_port=$((5900 + display))
ws_port=$((5700 + display))
qmp=${QMP:-$root/work/qemu.qmp}

[ -d "$novnc" ] || { echo "$0: no noVNC in $novnc - run scripts/fetch-novnc.sh" >&2; exit 1; }
cd "$root"
mkdir -p "$(dirname "$qmp")"
rm -f "$qmp"

# noVNC's pages, served to the browser; the picture itself does not go
# through this server but straight to the machine's WebSocket port.
python3 -m http.server "$web_port" --bind 127.0.0.1 --directory "$novnc" >/dev/null 2>&1 &
pages=$!
trap 'kill $pages 2>/dev/null || true' EXIT INT TERM

echo "noVNC    http://localhost:$web_port/vnc.html?host=localhost&port=$ws_port&autoconnect=1&resize=scale"
if [ -n "${VSCODE_PROXY_URI:-}" ]; then
    # https://host/proxy/{{port}}/ - the page through the proxy, and the
    # WebSocket through it as well, as a path for noVNC to open.
    page=$(printf '%s' "$VSCODE_PROXY_URI" | sed -e "s#{{port}}#$web_port#")
    socket=$(printf '%s' "$VSCODE_PROXY_URI" | sed -e "s#{{port}}#$ws_port#" -e 's#^[a-z]*://[^/]*##')
    echo "through  ${page%/}/vnc.html?path=$socket&autoconnect=1&resize=scale"
fi
echo "VNC      localhost:$vnc_port, QMP $qmp (scripts/qemu-shot.py)"

./zig build "$step" -Dboard="$board" -Dvirt-ui="vnc=localhost:$display,websocket=on" -Dvirt-qmp="$qmp" "$@"
