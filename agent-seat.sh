#!/usr/bin/env bash
# Usage: agent-seat.sh start | stop | env
# A second, invisible desktop for the agent: a headless Sway with its own Wayland socket, its own
# D-Bus session (so its own AT-SPI bus) and its own seat. Pointer, keyboard, screenshots and
# accessibility calls aimed at it never touch the owner's niri pointer or keyboard focus.
#   start  launches it (idempotent), prints `export` lines
#   env    prints the same lines (exit 1 when it is not running): eval "$(./agent-seat.sh env)"
#   stop   kills Sway, its apps, the D-Bus daemon and AT-SPI; removes the state dir
# After `eval`, pointer.sh, shot.sh, outputs.sh, focus.sh, wtype, grim and ax.py reach only that
# desktop: the env drops NIRI_SOCKET (outputs.sh prefers it to SWAYSOCK) and DISPLAY.
# Launch apps inside it with `eval "$(./agent-seat.sh env)"; chromium --ozone-platform=wayland
# --force-renderer-accessibility --user-data-dir=/tmp/agent-seat/profile ...`.
# Needs sway, dbus-daemon, jq (all present when computer-use works). Not installed: swaybg (the
# "failed to execute swaybg" line in sway.log is harmless).
set -euo pipefail
dir=${AGENT_SEAT_DIR:-/tmp/agent-seat}
res=${AGENT_SEAT_RES:-1280x800}
state=$dir/seat.env
uid=$(id -u)

alive() { [ -s "$state" ] && . "$state" && kill -0 "$SEAT_SWAY_PID" 2>/dev/null; }

emit() {
    . "$state"
    cat <<EOF
unset NIRI_SOCKET DISPLAY HYPRLAND_INSTANCE_SIGNATURE
export XDG_RUNTIME_DIR='${XDG_RUNTIME_DIR:-/run/user/$uid}'
export WAYLAND_DISPLAY='$SEAT_WAYLAND_DISPLAY'
export SWAYSOCK='$SEAT_SWAYSOCK'
export DBUS_SESSION_BUS_ADDRESS='$SEAT_DBUS'
export XDG_CURRENT_DESKTOP=sway GTK_A11Y=atspi QT_ACCESSIBILITY=1 GDK_BACKEND=wayland
export AGENT_SEAT_PIDS='$SEAT_SWAY_PID $SEAT_DBUS_PID'
EOF
}

case ${1:-} in
start)
    if alive; then emit; exit 0; fi
    export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$uid}
    rm -rf "$dir/run"; mkdir -p "$dir/run"
    # Private session bus; AT-SPI starts on it by D-Bus activation when the first app asks.
    # Its XDG_RUNTIME_DIR is private: the AT-SPI launcher it activates binds
    # $XDG_RUNTIME_DIR/at-spi/bus_<DISPLAY>, and with the owner's runtime dir and DISPLAY=:0 it
    # replaced the owner's live bus_0 socket (2026-11-03: new AT-SPI clients got ECONNREFUSED).
    mkdir -p -m 700 "$dir/xdg"
    env -u NIRI_SOCKET -u DISPLAY -u WAYLAND_DISPLAY -u SWAYSOCK -u HYPRLAND_INSTANCE_SIGNATURE \
        XDG_RUNTIME_DIR="$dir/xdg" XDG_CURRENT_DESKTOP=sway \
        dbus-daemon --session --fork --print-address=3 --print-pid=4 3>"$dir/run/dbus.addr" 4>"$dir/run/dbus.pid"
    dbus=$(cat "$dir/run/dbus.addr"); dbus_pid=$(tr -d '[:space:]' <"$dir/run/dbus.pid")
    cat >"$dir/run/sway.conf" <<EOF
output HEADLESS-1 resolution $res position 0 0
default_border none
xwayland disable
exec sh -c 'echo "\$WAYLAND_DISPLAY \$SWAYSOCK" > $dir/run/sockets'
EOF
    # Scrub every variable that could point sway or its children at the owner's session.
    env -u NIRI_SOCKET -u DISPLAY -u WAYLAND_DISPLAY -u SWAYSOCK -u HYPRLAND_INSTANCE_SIGNATURE \
        DBUS_SESSION_BUS_ADDRESS="$dbus" WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 \
        WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
        setsid sway -c "$dir/run/sway.conf" >"$dir/sway.log" 2>&1 &
    sway_pid=$!
    for _ in $(seq 50); do [ -s "$dir/run/sockets" ] && break; sleep 0.1; done
    if ! [ -s "$dir/run/sockets" ]; then
        kill "$sway_pid" "$dbus_pid" 2>/dev/null || true
        echo "agent-seat: sway did not start; see $dir/sway.log" >&2; exit 1
    fi
    read -r wd ss <"$dir/run/sockets"
    printf "SEAT_SWAY_PID=%s\nSEAT_DBUS_PID=%s\nSEAT_DBUS='%s'\nSEAT_WAYLAND_DISPLAY=%s\nSEAT_SWAYSOCK=%s\n" \
        "$sway_pid" "$dbus_pid" "$dbus" "$wd" "$ss" >"$state"
    # Start AT-SPI now and refuse to go on if its bus socket is not under the private dir.
    a11y=$(DBUS_SESSION_BUS_ADDRESS="$dbus" gdbus call --session --dest org.a11y.Bus \
        --object-path /org/a11y/bus --method org.a11y.Bus.GetAddress 2>/dev/null || true)
    case $a11y in
    *"$dir/xdg/"*) ;;
    *) echo "agent-seat: AT-SPI bus is not private ($a11y); stopping" >&2; "$0" stop >/dev/null; exit 1 ;;
    esac
    # The a11y bus cannot activate its registry here (--use-gnome-session fails without
    # gnome-session) and reads IsEnabled from a dconf cache that lives in the runtime dir, so start
    # the registry by hand and switch accessibility on, or apps never publish their tree.
    DBUS_SESSION_BUS_ADDRESS="$dbus" XDG_RUNTIME_DIR="$dir/xdg" \
        setsid /usr/lib/at-spi2-registryd >"$dir/registryd.log" 2>&1 &
    reg_pid=$!
    DBUS_SESSION_BUS_ADDRESS="$dbus" gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus \
        --method org.freedesktop.DBus.Properties.Set org.a11y.Status IsEnabled '<true>' >/dev/null
    echo "SEAT_REG_PID=$reg_pid" >>"$state"
    emit
    ;;
env)
    alive || { echo "agent-seat: not running (run start)" >&2; exit 1; }
    emit
    ;;
stop)
    if [ -s "$state" ]; then
        . "$state"
        # Everything started inside the seat is a descendant of sway (setsid made it a group
        # leader): terminate the group, then the bus, then at-spi processes bound to that bus.
        kill -TERM -- "-$SEAT_SWAY_PID" 2>/dev/null || kill -TERM "$SEAT_SWAY_PID" 2>/dev/null || true
        for _ in $(seq 30); do kill -0 "$SEAT_SWAY_PID" 2>/dev/null || break; sleep 0.1; done
        kill -KILL -- "-$SEAT_SWAY_PID" 2>/dev/null || true
        [ -z "${SEAT_REG_PID:-}" ] || kill -TERM "$SEAT_REG_PID" 2>/dev/null || true
        kill -TERM "$SEAT_DBUS_PID" 2>/dev/null || true
    fi
    # Services the private bus activated (at-spi, dconf, gvfsd and its FUSE mount, portals) are
    # double-forked and reparented away from it. Find them by the private XDG_RUNTIME_DIR.
    for env in /proc/[0-9]*/environ; do
        if grep -qaxF "XDG_RUNTIME_DIR=$dir/xdg" "$env" 2>/dev/null; then
            p=${env#/proc/}; kill -TERM "${p%/environ}" 2>/dev/null || true
        fi
    done
    sleep 0.5
    for m in "$dir/xdg/gvfs" "$dir/xdg/doc"; do
        if mountpoint -q "$m" 2>/dev/null; then fusermount3 -u "$m" 2>/dev/null || true; fi
    done
    rm -rf "$dir/run" "$dir/xdg" "$state"
    echo "agent-seat: stopped"
    ;;
*) echo "usage: agent-seat.sh start|stop|env" >&2; exit 2 ;;
esac
