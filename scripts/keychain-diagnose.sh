#!/usr/bin/env bash
# Read-only-ish diagnostics for "menu bar says keychain unlocked, but apps
# can't read/save passwords". Run as your normal user (NOT sudo):
#   bash scripts/keychain-diagnose.sh 2>&1 | tee /tmp/tb-kc-diag.txt
# The only write is a throwaway test item that is deleted again. No secrets
# are printed (no -w / -g flags anywhere).

LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"
hr() { printf '\n=== %s ===\n' "$1"; }

hr "macOS"
sw_vers

hr "Keychain files"
ls -la "$HOME/Library/Keychains/" | grep -v -E '^total'

hr "Search list / default / login keychain (as seen from this shell)"
echo "list-keychains:";  security list-keychains -d user
echo "default-keychain:"; security default-keychain -d user
echo "login-keychain:";   security login-keychain 2>&1

hr "Lock settings of login keychain"
security show-keychain-info "$LOGIN_KC" 2>&1

hr "TouchBridge config (path it manages)"
python3 - <<'PY' 2>&1
import json, os
p = os.path.expanduser("~/Library/Application Support/TouchBridge/keychain-unlock.json")
try:
    d = json.load(open(p))
    print("enabled:", d.get("enabled"), "| keychainPath:", d.get("keychainPath"))
    for k, e in (d.get("enrollments") or {}).items():
        print("  device:", e.get("displayName"), "| wrapped:", e.get("wrapped") is not None)
except Exception as ex:
    print("could not read:", ex)
PY

hr "Write/read/delete test against the DEFAULT keychain"
security add-generic-password -a tb-diag -s touchbridge-diagnostic -w diag-test -U; echo "add (default)   exit=$?"
security find-generic-password -a tb-diag -s touchbridge-diagnostic >/dev/null; echo "find (default)  exit=$?"
security delete-generic-password -a tb-diag -s touchbridge-diagnostic >/dev/null; echo "delete          exit=$?"

hr "Write/read/delete test against login.keychain-db EXPLICITLY"
security add-generic-password -a tb-diag -s touchbridge-diagnostic -w diag-test -U "$LOGIN_KC"; echo "add (login)     exit=$?"
security find-generic-password -a tb-diag -s touchbridge-diagnostic "$LOGIN_KC" >/dev/null; echo "find (login)    exit=$?"
security delete-generic-password -a tb-diag -s touchbridge-diagnostic "$LOGIN_KC" >/dev/null; echo "delete          exit=$?"

hr "Existing Claude CLI credential item present? (metadata only)"
security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; echo "Claude Code-credentials find exit=$? (0 = present, 44 = not found)"

hr "Daemon / menu-bar launchd state"
for L in dev.touchbridge.daemon dev.touchbridge.menubar; do
  echo "-- $L"; launchctl print "gui/$(id -u)/$L" 2>&1 | grep -E '^\s*(state|pid|domain|session|runs|last exit code)' 
done
echo "-- this shell's audit session:"; ps -o pid,sess,command -p $$ 2>/dev/null
for P in touchbridged TouchBridgeMenu loginwindow; do
  pgrep -x "$P" >/dev/null && ps -o pid,sess,lstart,command -p "$(pgrep -x "$P" | head -1)" | tail -1
done

hr "Today's keychain_unlock audit events"
grep -h keychain "$HOME/Library/Logs/TouchBridge/touchbridge-$(date +%F).ndjson" 2>/dev/null | tail -15 || echo "(none)"

hr "Daemon unified log, last 2h (keychain)"
log show --last 2h --style compact --predicate 'subsystem == "dev.touchbridge"' 2>/dev/null | grep -i keychain | tail -25

hr "securityd errors, last 30m"
log show --last 30m --style compact --predicate 'process == "securityd"' 2>/dev/null \
  | grep -i -E 'error|fail|denied|locked|-25293|-25308|-128' | tail -30
