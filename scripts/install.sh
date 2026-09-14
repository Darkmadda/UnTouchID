#!/bin/bash
set -euo pipefail

# TouchBridge Installer
# Builds and installs the daemon, PAM module, and LaunchAgent.
# Patches /etc/pam.d/sudo, /etc/pam.d/screensaver and the GUI admin-prompt
# service file (screensaver_new on macOS 26, authorization on older) with
# user confirmation.
# Fully idempotent — safe to run multiple times.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DAEMON_BIN="/usr/local/bin/touchbridged"
PAM_LIB="/usr/local/lib/pam/pam_touchbridge.so"
LAUNCH_AGENT_PLIST="$HOME/Library/LaunchAgents/dev.touchbridge.daemon.plist"
APP_SUPPORT_DIR="$HOME/Library/Application Support/TouchBridge"
LOG_DIR="$HOME/Library/Logs/TouchBridge"
LAUNCH_AGENT_LABEL="dev.touchbridge.daemon"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Preflight Checks ---

echo "=== TouchBridge Installer ==="
echo ""

# --- Options ---
#   --auto-lock          enable proximity auto-lock in the LaunchAgent
#   --lock-delay <sec>   seconds after phone disconnect before locking (default 30)
#   --no-auto-lock       disable auto-lock (even if a previous install enabled it)
# With no options, an existing install's auto-lock settings are preserved.
# Can be changed later without reinstalling: touchbridge-autolock on|off|status
AUTO_LOCK=""          # "" = keep existing, 1 = enable, 0 = disable
LOCK_DELAY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --auto-lock) AUTO_LOCK=1; shift ;;
        --no-auto-lock) AUTO_LOCK=0; shift ;;
        --lock-delay)
            [ $# -ge 2 ] || { error "--lock-delay requires a value"; exit 1; }
            LOCK_DELAY="$2"; AUTO_LOCK="${AUTO_LOCK:-1}"; shift 2 ;;
        --lock-delay=*) LOCK_DELAY="${1#--lock-delay=}"; AUTO_LOCK="${AUTO_LOCK:-1}"; shift ;;
        -h|--help)
            sed -n '/^# --- Options ---/,/^AUTO_LOCK=/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) error "unknown option: $1"; exit 1 ;;
    esac
done
if [ -n "$LOCK_DELAY" ] && ! [[ "$LOCK_DELAY" =~ ^[0-9]+$ ]]; then
    error "--lock-delay must be a whole number of seconds (got '$LOCK_DELAY')"
    exit 1
fi

# Check macOS version >= 13.0
MACOS_VERSION=$(sw_vers -productVersion)
MAJOR_VERSION=$(echo "$MACOS_VERSION" | cut -d. -f1)
if [ "$MAJOR_VERSION" -lt 13 ]; then
    error "macOS 13.0 (Ventura) or later is required. You have $MACOS_VERSION."
    exit 1
fi
info "macOS version: $MACOS_VERSION"

# Check SIP status
SIP_STATUS=$(csrutil status 2>/dev/null || echo "unknown")
if echo "$SIP_STATUS" | grep -q "disabled"; then
    warn "System Integrity Protection is disabled. This is unusual."
    warn "TouchBridge works with SIP enabled — consider re-enabling it."
fi

# Check for root (needed for PAM file modification)
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run with sudo."
    echo "  Usage: sudo bash scripts/install.sh"
    exit 1
fi

# Get the actual user (not root)
ACTUAL_USER="${SUDO_USER:-$(whoami)}"
ACTUAL_HOME=$(eval echo "~$ACTUAL_USER")
APP_SUPPORT_DIR="$ACTUAL_HOME/Library/Application Support/TouchBridge"
LOG_DIR="$ACTUAL_HOME/Library/Logs/TouchBridge"
LAUNCH_AGENT_PLIST="$ACTUAL_HOME/Library/LaunchAgents/dev.touchbridge.daemon.plist"

info "Installing for user: $ACTUAL_USER"

# --- Build ---

info "Building daemon..."
cd "$PROJECT_DIR/daemon"
sudo -u "$ACTUAL_USER" swift build -c release 2>&1 | tail -1
DAEMON_BUILD="$PROJECT_DIR/daemon/.build/release/touchbridged"
if [ ! -f "$DAEMON_BUILD" ]; then
    error "Daemon build failed — binary not found."
    exit 1
fi
info "Daemon built successfully."

info "Building PAM module..."
cd "$PROJECT_DIR"
make -C pam 2>&1 | tail -1
PAM_BUILD="$PROJECT_DIR/pam/pam_touchbridge.so"
if [ ! -f "$PAM_BUILD" ]; then
    error "PAM module build failed."
    exit 1
fi
info "PAM module built successfully."

# --- Install Binaries ---

# Never overwrite a signed Mach-O in place. `cp` onto an existing file reuses
# the inode, and the kernel keeps serving the old code-signature blob for it —
# the next process to map the file dies with "Killed: 9" (CODESIGNING Invalid
# Page). That process is `sudo` for the PAM module, and this very script is
# what runs it. Remove first so the copy lands on a fresh inode.
install_fresh() {
    local src="$1" dst="$2"
    rm -f "$dst"
    cp "$src" "$dst"
}

info "Installing daemon binary..."
mkdir -p "$(dirname "$DAEMON_BIN")"
install_fresh "$DAEMON_BUILD" "$DAEMON_BIN"
# The PAM module only trusts a daemon whose binary and parent directory are
# root-owned and not writable by anyone else, and whose running code matches
# the file on disk. `cp` over an existing file keeps the old owner, so set
# ownership explicitly, and make sure the binary carries a code signature
# (ad-hoc is fine; set TB_CODESIGN_IDENTITY to use a real one).
chown root:wheel "$DAEMON_BIN"
chmod 755 "$DAEMON_BIN"
if [ -n "${TB_CODESIGN_IDENTITY:-}" ]; then
    codesign --force --sign "$TB_CODESIGN_IDENTITY" "$DAEMON_BIN"
elif ! codesign --verify "$DAEMON_BIN" 2>/dev/null; then
    codesign --force --sign - "$DAEMON_BIN"
fi
DAEMON_DIR="$(dirname "$DAEMON_BIN")"
DAEMON_DIR_OWNER=$(stat -f '%u' "$DAEMON_DIR")
if [ "$DAEMON_DIR_OWNER" != "0" ] || [ -n "$(find "$DAEMON_DIR" -maxdepth 0 -perm +022)" ]; then
    warn "$DAEMON_DIR is not root-owned and unwritable by others (owner uid $DAEMON_DIR_OWNER)."
    warn "pam_touchbridge will refuse to trust the daemon until it is, e.g.:"
    warn "  sudo chown root:wheel $DAEMON_DIR && sudo chmod 755 $DAEMON_DIR"
fi
info "Installed $DAEMON_BIN"

AUTOLOCK_TOOL="/usr/local/bin/touchbridge-autolock"
install_fresh "$SCRIPT_DIR/touchbridge-autolock" "$AUTOLOCK_TOOL"
chown root:wheel "$AUTOLOCK_TOOL"
chmod 755 "$AUTOLOCK_TOOL"
info "Installed $AUTOLOCK_TOOL"

info "Installing PAM module..."
mkdir -p "$(dirname "$PAM_LIB")"
install_fresh "$PAM_BUILD" "$PAM_LIB"
chown root:wheel "$PAM_LIB"
chmod 444 "$PAM_LIB"
info "Installed $PAM_LIB"

# --- Create Directories ---

sudo -u "$ACTUAL_USER" mkdir -p "$APP_SUPPORT_DIR"
chmod 700 "$APP_SUPPORT_DIR"
sudo -u "$ACTUAL_USER" mkdir -p "$LOG_DIR"
info "Created application support and log directories."

# --- Patch PAM Files ---
# Uses the shared helper: prefers the unprotected /etc/pam.d/sudo_local hook on
# macOS Sonoma+, falls back to editing /etc/pam.d/sudo directly on older macOS.

# shellcheck source=pam-common.sh
source "$SCRIPT_DIR/pam-common.sh"

tb_enable_sudo "prompt"
tb_enable_screensaver "prompt"
tb_enable_gui_admin "prompt"

# --- Install LaunchAgent ---

info "Installing LaunchAgent..."

# Work out auto-lock settings: explicit flags win, otherwise keep whatever the
# existing plist had so a reinstall/upgrade doesn't silently turn it off.
EXISTING_ENABLED=0
EXISTING_DELAY=30
if [ -f "$LAUNCH_AGENT_PLIST" ]; then
    i=0
    while val=$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:$i" "$LAUNCH_AGENT_PLIST" 2>/dev/null); do
        case "$val" in
            --auto-lock) EXISTING_ENABLED=1 ;;
            --lock-delay)
                EXISTING_DELAY=$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:$((i + 1))" "$LAUNCH_AGENT_PLIST" 2>/dev/null || echo 30) ;;
        esac
        i=$((i + 1))
    done
fi
[ -n "$AUTO_LOCK" ] || AUTO_LOCK="$EXISTING_ENABLED"
[ -n "$LOCK_DELAY" ] || LOCK_DELAY="$EXISTING_DELAY"

EXTRA_ARGS_XML=""
if [ "$AUTO_LOCK" = 1 ]; then
    EXTRA_ARGS_XML="        <string>--auto-lock</string>
        <string>--lock-delay</string>
        <string>$LOCK_DELAY</string>"
    info "Proximity auto-lock: enabled (lock ${LOCK_DELAY}s after phone disconnects)"
else
    info "Proximity auto-lock: disabled (enable later with: touchbridge-autolock on)"
fi

# Unload existing agent if running
ACTUAL_UID=$(id -u "$ACTUAL_USER")
launchctl bootout "gui/$ACTUAL_UID/$LAUNCH_AGENT_LABEL" 2>/dev/null || true

# Write the plist (with correct paths for the actual user)
cat > "$LAUNCH_AGENT_PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LAUNCH_AGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DAEMON_BIN</string>
        <string>serve</string>
$EXTRA_ARGS_XML
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/daemon.stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/daemon.stderr.log</string>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST

chown "$ACTUAL_USER" "$LAUNCH_AGENT_PLIST"
chmod 644 "$LAUNCH_AGENT_PLIST"

# Load the agent. A bootstrap immediately after a bootout can leave the job
# registered but never launched (state "not running", runs = 0), so always
# follow it with a kickstart to force the launch.
launchctl bootstrap "gui/$ACTUAL_UID" "$LAUNCH_AGENT_PLIST" 2>/dev/null || true
launchctl kickstart -k "gui/$ACTUAL_UID/$LAUNCH_AGENT_LABEL" 2>/dev/null || true
info "LaunchAgent installed and started."

# --- Verification ---

echo ""
info "=== Installation Complete ==="
echo ""

# Check daemon is actually running (not just registered with launchd)
if launchctl print "gui/$ACTUAL_UID/$LAUNCH_AGENT_LABEL" 2>/dev/null | grep -q 'state = running'; then
    info "Daemon is running."
else
    warn "Daemon is registered but not running. Try: launchctl kickstart -k gui/$ACTUAL_UID/$LAUNCH_AGENT_LABEL"
fi

# Check socket
SOCK_PATH="$APP_SUPPORT_DIR/daemon.sock"
if [ -S "$SOCK_PATH" ]; then
    info "Socket available at: $SOCK_PATH"
else
    info "Socket will be created when daemon starts: $SOCK_PATH"
fi

echo ""
echo "Next steps:"
echo "  1. Open TouchBridge on your iPhone to pair"
echo "  2. Run: touchbridge-test pair"
echo "  3. Test: sudo echo 'TouchBridge works!'"
echo "  4. GUI admin prompts: leave the password empty, click OK, approve on your phone"
echo ""
