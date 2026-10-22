---
name: android-emulator-testing
description: Use the local Android emulator (AVD `localmind-test`) as the fast feedback loop for Localmind UI, flows, crashes, and screenshots instead of Taildropping every build to the phone. Trigger after any `fvm flutter build apk`, when reproducing a bug, verifying a screen or permission flow, or iterating on UI. Fall back to the physical phone only for things the emulator cannot exercise (Google OAuth, notifications, real sensors, performance, final install).
---

# Android Emulator Testing

The emulator is the default verification target. It boots in under a minute,
installs the same release APK, and gives logcat + screenshots. **Only Taildrop to
the phone once the emulator pass is clean, or when the change needs hardware the
emulator cannot provide.**

## One-time setup (already done on this Mac)

- `~/Library/Android/sdk/emulator` + `system-images;android-36;google_apis;arm64-v8a`
- AVD `localmind-test` (pixel_7, arm64-v8a, headless)

If the AVD is missing:

```bash
export ANDROID_HOME="$HOME/Library/Android/sdk"
"$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" "emulator" \
  "system-images;android-36;google_apis;arm64-v8a"
echo no | "$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager" create avd \
  -n localmind-test -k "system-images;android-36;google_apis;arm64-v8a" \
  -d pixel_7 --force
```

## The loop

Run everything from the repo root.

1. **Build** (resource guard on, Drive OAuth define required):
   ```bash
   bash ~/.config/opencode/skills/build-resource-hygiene/scripts/resource_guard.sh pause "apk"
   fvm flutter build apk --release --split-per-abi --target-platform android-arm64 \
     --dart-define=GOOGLE_SERVER_CLIENT_ID=<web-client-id>
   bash ~/.config/opencode/skills/build-resource-hygiene/scripts/resource_guard.sh resume
   ```
   Omitting the define leaves `serverClientId` empty and Drive sign-in fails
   with a typed configuration error (not a crash).
2. **Start the emulator** (headless; first boot ~30–60 s):
   ```bash
   bash .agents/skills/android-emulator-testing/scripts/emulator.sh start
   ```
3. **Install + launch** (logcat is cleared on launch):
   ```bash
   bash .agents/skills/android-emulator-testing/scripts/emulator.sh install
   bash .agents/skills/android-emulator-testing/scripts/emulator.sh launch
   ```
4. **Screenshot, then read the image** (the approved temp dir is pre-created):
   ```bash
   bash .agents/skills/android-emulator-testing/scripts/emulator.sh shot \
     /private/var/folders/2g/y0szl8p53cs137_3tbdpz0jw0000gn/T/opencode/emu.png
   ```
5. **Drive the UI** — the device is 1080x2400; screenshots are 1:1 pixels:
   ```bash
   emulator.sh tap 540 1390
   emulator.sh text "hello world"     # spaces are escaped for you
   emulator.sh key 66                 # KEYCODE_ENTER
   emulator.sh swipe 540 1800 540 600 300
   ```
6. **Read the logs after every interaction**:
   ```bash
   bash .agents/skills/android-emulator-testing/scripts/emulator.sh logs 80
   ```
   A crash shows `FATAL EXCEPTION` / `AndroidRuntime`; a Dart error shows
   `E/flutter`.

7. **Repeat** from step 1 only when Dart/native code changed. For a UI-only
   change, `flutter build` is still required in release mode; the emulator stays
   running between iterations, so just `install` + `launch` again.

## Navigation cheatsheet (Localmind)

- First launch: language screen → **Continue** (~540,2270); server screen →
  **Skip** (~995,206); lands in chat.
- Drawer: tap (~72,210) → **Settings**, **S3 Cloud Sync**, **Memories**.
- If the drawer language is not English, switch onboarding back to English first
  so labels are predictable.
- Prefer `ValueKey`s in widget tests; the emulator taps are a last-resort
  coordinate check.

## When to fall back to the phone

The emulator cannot stand in for these — Taildrop the APK and verify on
`s-s23-ultra`:

- **Google Sign-In / OAuth**: on a plain `google_apis` image the token request
  fails with `GoogleSignInException([16] Account reauth failed)`. A Play Store
  image (`google_apis_playstore`) can get further, but an emulator account may
  still fail at the token step. Verify Drive connect + upload on the phone.
- **Notifications**: Android notification access, heads-up delivery, and the
  notification listener service.
- **Hardware**: camera, microphone, real sensors, battery/thermal behavior, and
  performance of local models.
- **Taildrop / share target**: the real share sheet from other apps.
- **Final acceptance**: always install the built APK on the phone before calling a
  change done.

## OAuth on the emulator (best effort)

Create a Play Store AVD only if you need to get past the account picker:

```bash
sdkmanager "system-images;android-36;google_apis_playstore;arm64-v8a"
echo no | avdmanager create avd -n localmind-play \
  -k "system-images;android-36;google_apis_playstore;arm64-v8a" -d pixel_7
```

Then `Settings → Passwords & accounts → Add account → Google`, sign in once.
A missing/invalid OAuth client surfaces as a typed configuration error, not a
crash.

## Notes

- The emulator and the phone are separate devices. Taildrop only after the
  emulator pass is clean.
- Keep the AVD running between iterations; only rebuild + `install` again.
- `emulator.sh stop` kills it (`adb emu kill`).
- `adb` lives at `$ANDROID_HOME/platform-tools/adb`; the script resolves it.
- If `adb` says `device offline`, wait a few seconds and retry; the script's
  `start` waits for `sys.boot_completed`.
