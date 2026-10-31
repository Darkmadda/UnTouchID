#!/bin/bash
set -euo pipefail

# TouchBridge PAM self-heal
# -------------------------
# macOS updates rewrite every file in /etc/pam.d/ back to Apple's stock
# contents, silently removing the TouchBridge auth hook from `screensaver`
# (lock/login screen) and the GUI admin-prompt file. `sudo` survives because it
# hooks via the unprotected sudo_local include, but screensaver and the GUI
# admin files have no *_local equivalent, so they get clobbered on every update.
#
# This script non-interactively re-applies the hooks. It is driven by the
# dev.touchbridge.pam-heal LaunchDaemon (RunAtLoad + WatchPaths on /etc/pam.d),
# so an update that resets the files self-heals on the next boot.
#
# SECURITY: this runs as root. It — and the pam-common.sh it sources — must live
# in a root-owned, non-user-writable directory (installed to
# /usr/local/libexec/touchbridge). Never point the LaunchDaemon at a copy inside
# a user-writable checkout: that would let a same-user attacker run code as root.
#
# The patch functions are idempotent: once the line is present they make no
# write, so the WatchPaths trigger settles after a single pass (no edit loop).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pam-common.sh
source "$SCRIPT_DIR/pam-common.sh"

PAM_LIB="/usr/local/lib/pam/pam_touchbridge.so"

echo "=== TouchBridge PAM self-heal: $(date '+%Y-%m-%d %H:%M:%S') ==="

if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] must run as root" >&2
    exit 1
fi

if [ ! -f "$PAM_LIB" ]; then
    echo "[ERROR] PAM module not found at $PAM_LIB — not healing (TouchBridge not installed?)." >&2
    exit 0
fi

# "" prompt = non-interactive; the functions skip any file already patched.
tb_enable_sudo ""
tb_enable_screensaver ""
tb_enable_gui_admin ""

echo "[INFO] PAM heal pass complete."
