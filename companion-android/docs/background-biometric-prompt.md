# Showing the biometric prompt from the background without a notification tap

## Problem

On the TouchBridge Android companion:

- **Foreground:** when an auth challenge arrives and the app is open, the biometric
  prompt appears instantly.
- **Backgrounded + device unlocked:** the app posts a heads-up notification that the
  user must **tap** before the biometric prompt appears.
- **Screen off / device locked:** the prompt already appears automatically (no tap),
  via the full-screen intent.

Goal: make the prompt appear from the background **without a tap** while the device is
unlocked and in use.

## Why the tap is required today

The infrastructure to auto-launch the prompt already exists:

- `TouchBridgeService.presentPrompt` (`service/TouchBridgeService.kt`) posts a
  notification with `setFullScreenIntent(fsIntent, true)` + `CATEGORY_CALL`, **and**
  also calls `startActivity()` directly.
- `ChallengeActivity` is a transparent activity with `showWhenLocked` / `turnScreenOn`
  that hosts the platform `BiometricPrompt`.

Two Android rules force the tap:

1. **Full-screen intents only auto-launch when the screen is off / the device is
   locked.** When unlocked and in use, Android downgrades the full-screen intent to a
   heads-up notification that must be tapped.
2. **The direct `startActivity()` is blocked by Background Activity Launch (BAL)
   restrictions** when the app is backgrounded. It only succeeds when the app is
   already foreground — exactly the "instant prompt" case. The failure is caught and
   logged as `"Direct activity launch blocked (background)"`.

There is **no `SYSTEM_ALERT_WINDOW` (draw-over-other-apps) permission** in the app,
which is the standard mechanism for granting a BAL exemption so a backgrounded app can
launch an activity while the device is unlocked.

Relevant facts: `minSdk 28`, `targetSdk 34`, `compileSdk 34`. The prompt uses the
**platform** `android.hardware.biometrics.BiometricPrompt`, which must run inside an
Activity — so the fix must *enable launching that Activity from the background*, not
render the prompt as an overlay window.

## Chosen approach: `SYSTEM_ALERT_WINDOW` for a BAL exemption

Holding the "Display over other apps" special permission grants a documented exemption
from BAL, so the existing `startActivity()` in `presentPrompt` succeeds even when
backgrounded-and-unlocked. **No overlay window is actually drawn** — the permission is
used purely as the launch key, reusing the entire existing prompt path.

If the permission is *not* granted, behavior is unchanged from today (full-screen
intent when locked, tap when unlocked). The change is purely additive and degrades
gracefully.

### Steps

1. **Manifest** — declare
   `<uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW" />`.

2. **`PermissionUtils`** — add:
   - `canDrawOverlays(context): Boolean` (wraps `Settings.canDrawOverlays`, always true
     below API 23).
   - `overlaySettingsIntent(context): Intent` for
     `Settings.ACTION_MANAGE_OVERLAY_PERMISSION` scoped to our package.

3. **`TouchBridgeService.presentPrompt`** — keep the notification as the always-present
   fallback; keep attempting the direct `startActivity()` (it starts working once the
   permission is granted). Improve logging to distinguish "no overlay permission, so a
   background launch will fall back to the notification" from an unexpected failure.

4. **Opt-in UI (`MainActivity` + `HomeScreen`)** — this is a *special* permission
   requested via a settings screen, not a runtime permission dialog. Add an
   "Instant approval" card shown when the app is paired **and** overlay permission is
   missing, explaining the benefit ("show the Face ID / fingerprint prompt instantly
   even when TouchBridge is in the background") with a button that opens the overlay
   settings screen. Re-check `canDrawOverlays` on `ON_RESUME` so the card disappears
   once granted.

### Trade-offs / caveats

- `SYSTEM_ALERT_WINDOW` is a **sensitive permission**; Google Play scrutinizes it.
  The justification here (an authenticator that must surface instantly) is legitimate
  and must be clearly explained to the user.
- Some OEM skins (MIUI, ColorOS, etc.) tie background-launch behavior to their own
  "pop-up while running in background" toggles even with this permission — behavior can
  vary by device. The existing battery-optimization exemption already mitigates part of
  this.
- The prompt/crypto path is unchanged; only the launch gating and an opt-in UI are new.

### Rejected alternatives

- **No new permission:** nothing reliably beats BAL on `targetSdk 34` while unlocked.
- **Render the prompt as a `TYPE_APPLICATION_OVERLAY` window:** would require abandoning
  the platform `BiometricPrompt` (which needs an Activity) and hand-rolling a custom
  overlay that triggers biometrics — a much larger change with worse security
  ergonomics.
