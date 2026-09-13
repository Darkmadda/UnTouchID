# Security Policy

## Reporting Vulnerabilities

If you discover a security vulnerability in TouchBridge, please report it responsibly:

1. **Do NOT open a public issue**
2. Email: security@touchbridge.dev (or open a private security advisory on GitHub)
3. Include: description, reproduction steps, impact assessment
4. We will acknowledge within 48 hours and provide a fix timeline

## Threat Model

### What TouchBridge protects against

- **Remote authentication attacks**: Biometric confirmation happens on a physical device you hold
- **Replay attacks**: 32-byte nonces with 10-second expiry and 60-second seen-nonces window
- **Man-in-the-middle**: ECDH ephemeral session keys with AES-256-GCM encryption on BLE channel
- **Key theft**: Private signing key lives inside Secure Enclave — never exported, never leaves the chip
- **Local privilege escalation through the daemon socket**: a same-user process cannot impersonate the daemon to mint a `sudo` or admin approval — see below

### What TouchBridge does NOT protect against

- **Physical access to unlocked companion device**: If someone has your unlocked iPhone, they can approve auth requests
- **Keychain items with `kSecAccessControlBiometryCurrentSet`**: Cryptographically impossible — hardware ACL wall
- **Sandboxed third-party apps calling `LAContext`**: Blocked by SIP and sandbox
- **Compromised macOS kernel**: If the kernel is compromised, no user-space security holds
- **A same-user attacker who can pair their own phone**: pairing is a user-level operation (`touchbridge-test pair`), so code running as you, with a phone in Bluetooth range, could pair it and approve its own requests. This requires physical presence, unlike the socket attack below.

### Daemon identity verification (socket spoofing)

The PAM module talks to the daemon over a Unix socket in the user's home
directory. Anything running as that user could unlink the socket and bind an
impostor that answers every request with `"result":"success"` — and because
`sudo` grants root on a PAM success, that would be a local root escalation from
ordinary user code. A shared secret cannot fix this: the daemon runs as the user,
so any key it can read, the attacker can read too.

Instead, after connecting, `pam_touchbridge` asks the kernel who the peer is and
refuses to send a request unless all of the following hold:

| Check | Mechanism | Defeats |
|-------|-----------|---------|
| Peer runs as the user being authenticated | `LOCAL_PEERCRED` | sockets served by another account |
| Peer executable is the installed daemon (`daemon=` option, default `/usr/local/bin/touchbridged`) | `LOCAL_PEERTOKEN` + `proc_pidpath_audittoken` | any other binary bound to the socket path |
| That binary and its directory are root-owned and not group/world writable | `stat` | swapping the file without root |
| Peer's running code satisfies the on-disk binary's designated requirement | `SecCodeCopyGuestWithAttributes` + `SecCodeCheckValidity` | modified or foreign code claiming the path (ad-hoc builds pin the exact cdhash) |
| Daemon reports `"mode":"production"` | JSON response field | the genuine binary started in `--simulator`, `--interactive`, or `--web` mode, which approve without a phone |

The GUI admin-prompt PAM service is `authorization` on older macOS and
`screensaver_new` on macOS 26; the installer patches whichever exists. The
module reports the service name to the daemon as the surface, and unknown
surfaces default to biometric-required — so a service we have not enumerated
still gets the strongest policy, never a weaker one.

The mode check can be relaxed per PAM line with `allow_mode=simulator` or
`allow_mode=web`; since `/etc/pam.d` is root-owned, that is a root decision.
Any failed check is logged to the auth log as `REFUSING socket peer` and PAM
falls through to the password. `make -C pam test` exercises these checks.

Consequences to be aware of: after upgrading the daemon binary, the *running*
daemon no longer matches the file on disk and will be refused until it restarts
(`install.sh` restarts it). On Intel Macs where Homebrew has made
`/usr/local/bin` user-owned, the ownership check fails closed; `install.sh`
warns and prints the `chown` to fix it.

### Availability note: PAM fallback vs. a dangling module reference

TouchBridge installs `pam_touchbridge.so` as `auth sufficient`, so if the daemon
is down or the phone is unreachable, PAM falls through to your password — you are
never locked out by a *failed* authentication.

There is one exception, and it is an **availability** issue, not an
authentication bypass: if the module *file* is deleted while a PAM config still
references it, `sudo` cannot initialize PAM and refuses to run entirely. The
`sufficient` flag only falls through when the module loads and returns failure —
a missing module file is a hard failure.

To avoid this, on macOS Sonoma+ we install the hook into the unprotected
`/etc/pam.d/sudo_local` (Apple's sanctioned include) rather than the SIP-protected
`/etc/pam.d/sudo`, and our uninstaller always removes the hook **before** the
module. If you ever hit `sudo: unable to initialize PAM: No such file or
directory`, recover without needing sudo (GUI admin auth uses a different PAM
stack):

```bash
# Sonoma+ (hook in sudo_local — just delete it):
osascript -e 'do shell script "rm -f /etc/pam.d/sudo_local" with administrator privileges'
```

If `/etc/pam.d/sudo` itself is protected on your system and the hook was written
there by an older version, the most reliable fix is to restore the module so the
reference resolves again — download the latest `.pkg`, then:

```bash
pkgutil --expand-full TouchBridge-*.pkg /tmp/tb-x
osascript -e 'do shell script "cp /tmp/tb-x/Payload/usr/local/lib/pam/pam_touchbridge.so /usr/local/lib/pam/" with administrator privileges'
```

### Cryptographic properties

| Property | Implementation |
|----------|---------------|
| Nonce | 32 bytes from `SecRandomCopyBytes` |
| Nonce expiry | 10 seconds (hard minimum) |
| Replay protection | Seen-nonces ring buffer, 60-second TTL |
| Signing algorithm | ECDSA P-256 (`ecdsaSignatureMessageX962SHA256`) |
| Key storage (iOS) | Secure Enclave (`kSecAttrTokenIDSecureEnclave`) |
| Key storage (Mac) | Companion *public* keys only, in `~/Library/Application Support/TouchBridge/paired-devices.json` (mode 0600) |
| Session encryption | AES-256-GCM over ECDH-derived key (HKDF-SHA256) |
| Transport | BLE GATT (encrypted) or local Wi-Fi (Bonjour) |

### Audit logging

Every authentication event is logged to `~/Library/Logs/TouchBridge/` as NDJSON:
- Session ID, result, device, surface, RSSI, latency
- **Nonce values are NEVER logged**

## Supported versions

| Version | Supported |
|---------|-----------|
| 1.0.x   | Yes       |
| 0.1.x   | No — upgrade to 1.0 |
