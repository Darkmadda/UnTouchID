#!/bin/bash
set -euo pipefail

# TouchBridge Uninstaller
# Removes the daemon, PAM module, and the TouchBridge PAM hook.
#
# IMPORTANT: the PAM hook is always removed BEFORE the module file, so sudo can
# never be left referencing a deleted module (the lockout class of bugs).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pam-common.sh
source "$SCRIPT_DIR/pam-common.sh"

DAEMON_BIN="/usr/local/bin/touchbridged"
PAM_LIB="/usr/local/lib/pam/pam_touchbridge.so"
LAUNCH_AGENT_LABEL="dev.touchbridge.daemon"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "=== TouchBridge Uninstaller ==="
echo ""

# Check for root
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run with sudo."
    echo "  Usage: sudo bash scripts/uninstall.sh"
    exit 1
fi

ACTUAL_USER="${SUDO_USER:-$(whoami)}"
ACTUAL_HOME=$(eval echo "~$ACTUAL_USER")
ACTUAL_UID=$(id -u "$ACTUAL_USER")
LAUNCH_AGENT_PLIST="$ACTUAL_HOME/Library/LaunchAgents/dev.touchbridge.daemon.plist"

# --- Keychain-unlock lockout guard ---
# If the user opted into keychain unlock, their login keychain is decoupled to a
# RANDOM password. Removing the daemon removes the phone-unlock path, so unless
# they re-couple first they'd be left with a keychain only the saved random
# password can open. Warn before touching anything.
KC_STORE="$ACTUAL_HOME/Library/Application Support/TouchBridge/keychain-unlock.json"
if [ -f "$KC_STORE" ] && grep -q '"enabled"[[:space:]]*:[[:space:]]*true' "$KC_STORE" 2>/dev/null; then
    echo ""
    warn "Keychain unlock is ENABLED on this Mac."
    echo "  Your login keychain uses a RANDOM password (decoupled from your account"
    echo "  password). Uninstalling removes the phone-based unlock."
    echo ""
    echo "  Recommended BEFORE uninstalling — re-couple the keychain to a password"
    echo "  you know (run as your user, not root):"
    echo "      touchbridge-test keychain recover"
    echo ""
    echo "  If you skip this, keep the random password from your password manager"
    echo "  safe — it becomes the only way to unlock the login keychain."
    echo ""
    printf "  Continue uninstalling anyway? [y/N] "
    read -r reply
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        info "Aborted. Run 'touchbridge-test keychain recover' first, then re-run uninstall."
        exit 0
    fi
fi

# --- Unload LaunchAgent ---

info "Stopping daemon..."
launchctl bootout "gui/$ACTUAL_UID/$LAUNCH_AGENT_LABEL" 2>/dev/null || true

if [ -f "$LAUNCH_AGENT_PLIST" ]; then
    rm -f "$LAUNCH_AGENT_PLIST"
    info "Removed LaunchAgent plist."
else
    info "LaunchAgent plist not found — skipping."
fi

# --- Remove Menu-Bar App ---

MENU_LABEL="dev.touchbridge.menubar"
MENU_PLIST="$ACTUAL_HOME/Library/LaunchAgents/$MENU_LABEL.plist"
MENU_APP_DST="/Applications/TouchBridge.app"

info "Stopping menu-bar app..."
launchctl bootout "gui/$ACTUAL_UID/$MENU_LABEL" 2>/dev/null || true
sudo -u "$ACTUAL_USER" pkill -x TouchBridgeMenu 2>/dev/null || true

if [ -f "$MENU_PLIST" ]; then
    rm -f "$MENU_PLIST"
    info "Removed menu-bar app LaunchAgent."
fi
if [ -d "$MENU_APP_DST" ]; then
    rm -rf "$MENU_APP_DST"
    info "Removed $MENU_APP_DST"
fi

# --- Remove PAM self-heal LaunchDaemon ---
# MUST come before stripping the hooks below: its WatchPaths trigger would
# otherwise re-add them the moment tb_disable_* edits /etc/pam.d, undoing this.

HEAL_LABEL="dev.touchbridge.pam-heal"
HEAL_PLIST="/Library/LaunchDaemons/$HEAL_LABEL.plist"
HEAL_LIBEXEC="/usr/local/libexec/touchbridge"

info "Removing PAM self-heal LaunchDaemon..."
launchctl bootout system/"$HEAL_LABEL" 2>/dev/null || true
rm -f "$HEAL_PLIST"
rm -rf "$HEAL_LIBEXEC"
info "Removed PAM self-heal."

# --- Remove PAM hook (BEFORE the module, to avoid a dangling reference) ---

tb_disable_sudo
tb_disable_screensaver
tb_disable_gui_admin

# --- Remove Binaries ---

if [ -f "$DAEMON_BIN" ]; then
    rm -f "$DAEMON_BIN"
    info "Removed $DAEMON_BIN"
else
    info "Daemon binary not found — skipping."
fi

AUTOLOCK_TOOL="/usr/local/bin/touchbridge-autolock"
if [ -f "$AUTOLOCK_TOOL" ]; then
    rm -f "$AUTOLOCK_TOOL"
    info "Removed $AUTOLOCK_TOOL"
fi

TEST_BIN="/usr/local/bin/touchbridge-test"
if [ -f "$TEST_BIN" ]; then
    rm -f "$TEST_BIN"
    info "Removed $TEST_BIN"
fi

if [ -f "$PAM_LIB" ]; then
    rm -f "$PAM_LIB"
    info "Removed $PAM_LIB"
else
    info "PAM module not found — skipping."
fi

# --- Remove Socket ---

SOCK_PATH="$ACTUAL_HOME/Library/Application Support/TouchBridge/daemon.sock"
if [ -S "$SOCK_PATH" ]; then
    rm -f "$SOCK_PATH"
    info "Removed daemon socket."
fi

# --- Done ---

echo ""
info "=== Uninstallation Complete ==="
echo ""
echo "Note: User data at ~/Library/Application Support/TouchBridge/ was preserved."
echo "      To remove it: rm -rf ~/Library/Application\\ Support/TouchBridge/"
echo ""
echo "Note: Log files at ~/Library/Logs/TouchBridge/ were preserved."
echo "      To remove them: rm -rf ~/Library/Logs/TouchBridge/"
echo ""
