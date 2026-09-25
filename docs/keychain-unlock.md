# Keychain Unlock (opt-in)

By default, unlocking your Mac's screen with TouchBridge (Face ID on your phone)
does **not** unlock your login keychain. Only Apple's own password/Touch ID paths
are wired into `securityd`'s keychain unlock; a third-party PAM module satisfies
the *session* unlock but the login keychain stays locked, so you fall back to
`security unlock-keychain`.

This optional feature closes that gap: after your phone approves a screen/login
unlock, the daemon asks it to unwrap your (decoupled, random) keychain password
so the keychain unlocks in lock-step with the session. **It is off by default and
changes the security model — read "Security & tradeoffs" before enabling it.**

## How it works

- The phone holds a dedicated **biometric-gated P-256 key-agreement key** in its
  Secure Enclave (separate from the signing key; the private key never leaves).
- At setup, the Mac re-keys the login keychain to a **random password**, wraps
  that password to each paired phone's key (ephemeral ECDH → HKDF → AES-GCM), and
  stores only the ciphertext. The plaintext password is never stored recoverably.
- To unlock, the phone performs a **blind ECDH** (after Face ID) and returns the
  shared secret; the Mac derives the AES key, unwraps the password, and calls
  `SecKeychainUnlock`. The phone never sees the password; the password never
  crosses BLE in the clear.
- At **login**, the daemon proactively runs this handshake once your phone
  connects, so a single Face ID at login unlocks the keychain — no lock/unlock
  dance. (The phone must be reachable and, if backgrounded, tapped via the
  notification so it can show Face ID.)
- After a **screen unlock**, the daemon repeats the handshake so the keychain
  unlocks in lock-step. The companion routinely drops and re-establishes the BLE
  link the instant the screen unlocks, so the daemon waits briefly (a few
  seconds) for the phone — or any enrolled phone — to be reachable rather than
  firing once and giving up. Every attempt is recorded in the audit log.

## Manual unlock (menu bar)

The keychain doesn't always unlock automatically — the phone may be out of range,
backgrounded, or the BLE link may not have re-established in time. The menu-bar
app shows the live keychain state (**Keychain locked / unlocked**) and, when
locked, an **Unlock Keychain Now** button that triggers the same phone handshake
on demand (Face ID on the phone). It talks to the running daemon over the local
`daemon.sock`; the outcome is reported inline in the menu.

If an automatic unlock ever fails to land, watch why:

```bash
tail -f "$HOME/Library/Logs/TouchBridge/touchbridge-$(date +%F).ndjson" | grep keychain_unlock
```

`keychain_unlock` results: `UNLOCKED` (success), `FAILED_NO_DEVICE` (no enrolled
phone was reachable in the wait window), `FAILED_SEND` (couldn't notify the
phone), `FAILED_TIMEOUT` (phone didn't answer — often the second Face ID prompt
was missed), `FAILED_NO_SESSION` / `FAILED_NO_SECRET` / `FAILED_UNWRAP`
(handshake/state problems).

## Enable it

1. **On your paired iPhone**: TouchBridge → Settings → turn on **Unlock Mac
   Keychain**. This creates the key and registers its public key with the Mac.
   Keep the phone connected.
2. **On your Mac**:
   ```bash
   touchbridge-test keychain setup
   ```
   You'll enter your current keychain password (your account password the first
   time), and TouchBridge will re-key the keychain to a random password and wrap
   it to every enrolled phone. **It prints the random password once — save it in
   your password manager.**
3. Check state anytime:
   ```bash
   touchbridge-test keychain status
   ```

## Recovery — you can never be locked out

Because the keychain password is decoupled and random, there are four independent
ways back in:

1. **The saved random password.** Shown once at setup; stored in your password
   manager. Type it into any keychain prompt. This works with no daemon and no
   phone.
2. **Multiple phones.** Every enrolled phone gets its own wrapped copy of the same
   password. Lose one phone and any other enrolled phone still unlocks. (Pair the
   second phone, enable the toggle, and re-run `keychain setup`.)
3. **`keychain recover`.** Re-couples the keychain to a password you choose (set
   it to your account password to restore native login unlock) and turns the
   feature off:
   ```bash
   touchbridge-test keychain recover
   ```
   Use this if the daemon is corrupted/removed or every phone is gone (you'll need
   the saved random password).
4. **Uninstall guard.** `uninstall.sh` detects the feature and tells you to run
   `keychain recover` first, so uninstalling can't strand your keychain.

## Security & tradeoffs

This feature is a deliberate, informed weakening of TouchBridge's default model.
Understand it before enabling:

- **The keychain password now exists at rest**, encrypted so only a paired
  phone's Secure Enclave can unwrap it. File theft alone reveals nothing.
- **We store a decoupled *random* password, not your account password.** So if
  the phone key is ever compromised, or a Face ID is compelled, the recovered
  secret is a useless random string scoped to this one keychain — not a reusable
  credential for remote login or other services.
- **Confused-deputy risk.** The phone cannot cryptographically distinguish a
  legitimate keychain-unlock from a malicious "unwrap this" request; any process
  that can reach the daemon and trigger a Face ID could, in principle, obtain the
  random keychain password. TouchBridge only consumes the plaintext inside the
  daemon's unlock path and never returns it to any caller, but a fully compromised
  daemon is game over for *this keychain's* password (vs. a session, by default).
- **Reboot UX.** Because the keychain password is decoupled and `loginwindow` is
  intentionally *not* hooked, at a fresh login the keychain won't unlock from your
  typed account password — the daemon's phone handshake unlocks it instead once
  your phone connects.

If you'd rather not accept any of this, don't enable the feature: keep the screen
unlock on Touch ID (which unlocks the keychain natively) and let TouchBridge own
`sudo` and admin prompts, where there's no keychain side effect.
