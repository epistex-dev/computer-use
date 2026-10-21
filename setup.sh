#!/usr/bin/env bash
# Idempotent. Installs the tools, builds vptr, turns on accessibility, and proves a pointer drag.
# Only the package install needs root; nothing here touches /dev/uinput or input settings.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# No tty (ssh, agent) means sudo cannot prompt: honour SUDO_ASKPASS when it is set.
sudo() { command sudo ${SUDO_ASKPASS:+-A} "$@"; }

need=(grim slurp wtype wl-copy jq gcc wayland-scanner tesseract python3)
missing=()
for cmd in "${need[@]}"; do command -v "$cmd" >/dev/null || missing+=("$cmd"); done
python3 -I -c 'import PIL, gi; gi.require_version("Atspi", "2.0")' 2>/dev/null || missing+=(python-modules)
if [ ${#missing[@]} -gt 0 ]; then
    if command -v pacman >/dev/null; then
        sudo pacman -S --noconfirm --needed grim slurp wtype wl-clipboard jq gcc wayland tesseract \
            tesseract-data-eng python-pillow python-gobject at-spi2-core
    else
        echo "✗ missing: ${missing[*]}. Install the packages listed in README.md for your distro." >&2
        exit 1
    fi
fi
echo "✓ tools"

# vptr: exact absolute pointer through the wlr virtual-pointer protocol. ydotool's `mousemove -a`
# is a relative sweep to a corner plus an offset: it lands relative to the pointer's output on a
# multi-output layout and trips hot corners.
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
wayland-scanner client-header "$here/wlr-virtual-pointer-unstable-v1.xml" "$build/wlr-virtual-pointer-unstable-v1-client-protocol.h"
wayland-scanner private-code "$here/wlr-virtual-pointer-unstable-v1.xml" "$build/protocol.c"
gcc -O2 -Wall -I"$build" -o "$here/vptr" "$here/vptr.c" "$build/protocol.c" -lwayland-client
echo "✓ vptr built"

# Accessibility for ax.py. Apps read it at launch, so already-running apps need a restart, and
# Chromium and Electron apps also need --force-renderer-accessibility to expose page content.
if command -v gsettings >/dev/null; then
    gsettings set org.gnome.desktop.interface toolkit-accessibility true && echo "✓ AT-SPI on (restart apps to expose their tree)"
fi

# Verify: slurp is the only ruler, since the cursor never appears in a screenshot.
read -r _ ox oy _ _ < <("$here/outputs.sh" | head -1)
x=$((ox + 500)); y=$((oy + 400))
slurp -f '%x,%y %wx%h' > "$build/slurp.out" 2>/dev/null &
slurp_pid=$!
# A failed step must not leave slurp's overlay grabbing the owner's mouse.
trap 'kill $slurp_pid 2>/dev/null || true; rm -rf "$build"' EXIT
sleep 1.2
"$here/pointer.sh" "$x" "$y" drag $((x + 200)) $((y + 200))
sleep 0.8
got=$(cat "$build/slurp.out")
# slurp's WxH includes the last pixel, so it reads 200 or 201.
pos=${got% *}; size=${got#* }; w=${size%x*}; h=${size#*x}
if [ "$pos" = "$x,$y" ] && [ "$w" -ge 199 ] && [ "$w" -le 201 ] && [ "$h" -ge 199 ] && [ "$h" -le 201 ]; then
    echo "✓ pointer exact: $got"
else
    echo "✗ pointer off: got '$got', want $x,$y ~200x200"; exit 1
fi
