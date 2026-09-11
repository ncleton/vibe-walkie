#!/bin/bash
set -euo pipefail

# This is a real, persistent user desktop. Xvfb never listens on a TCP socket.
# The companion's own TLS listener binds only to the specified private address.
if [[ "${1:-}" != "--inside-session" ]]; then
  for command in xvfb-run dbus-run-session openbox xfce4-terminal vibewalkie; do
    command -v "$command" >/dev/null || {
      echo "Missing $command. Install the Linux prerequisites in Companion/README.md and activate the companion virtualenv." >&2
      exit 1
    }
  done
  exec xvfb-run -a -s '-screen 0 1440x900x24 -nolisten tcp' \
    dbus-run-session -- "$0" --inside-session "$@"
fi
shift
export XDG_SESSION_TYPE=x11
export NO_AT_BRIDGE=0
export GTK_MODULES=atk-bridge
openbox &
WINDOW_MANAGER_PID=$!
trap 'kill "$WINDOW_MANAGER_PID" 2>/dev/null || true' EXIT
xfce4-terminal --disable-server --title='Vibe Walkie VPS' &
vibewalkie serve "$@"
