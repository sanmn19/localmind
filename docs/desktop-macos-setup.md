# macOS desktop setup

LocalMind ships a macOS desktop target alongside the Android app. This page covers
the one-time toolchain setup and the Google OAuth client the desktop build needs.

The runner is generated in place:

- bundle id `pro.momin.localmind`, display name `LocalMind`
- minimum macOS version 14.0 (MLX and the on-device backends need it)
- sandboxed, hardened runtime, with network client/server, user-selected file
  read/write and audio-input entitlements

## 1. Enable Swift Package Manager

Flutter 3.44 resolves macOS plugins through Swift Package Manager, and this project
depends on `llamadart_llama_cpp_flutter`, which is Swift-Package-Manager-only.
Enable the feature **before** generating or building the runner:

```bash
flutter config --enable-swift-package-manager
flutter config --list | grep swift-package-manager   # enable-swift-package-manager: true
```

`macos/Runner.xcodeproj/project.pbxproj` must reference
`Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage` (the
`flutter create --platforms=macos` template adds it). Without the feature enabled
the build stops with the Swift-Package-Manager-only plugin error.

## 2. Install Xcode

Install Xcode 15 or newer from the App Store (or from
<https://developer.apple.com/download/all/>). Flutter only treats the project as
Swift-Package-Manager-capable when `xcodebuild` reports Xcode 15+.

Point the command line tools at the full Xcode install and accept the license:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
sudo xcodebuild -license accept
```

Verify:

```bash
xcodebuild -version   # Xcode 15.x or newer
```

## 3. CocoaPods


The runner uses both package managers: `llamadart_llama_cpp_flutter` is
Swift-Package-Manager-only and resolves through
`macos/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage`, while
`flutter_tts`, `objectbox_flutter_libs` and `sherpa_onnx_macos` are CocoaPods-only.
`macos/Podfile` pins `platform :osx, '14.0'`; raising it lower than 11.0 makes
`objectbox_flutter_libs` fail to resolve.

```bash
brew install cocoapods
pod --version
```

## 4. Run the app

```bash
fvm flutter pub get
fvm flutter run -d macos
```

Debug and release builds:

```bash
fvm flutter build macos --debug
fvm flutter build macos --release
```

Without FVM, replace `fvm flutter` with your Flutter 3.44.2 binary, e.g.
`~/fvm/versions/3.44.2/bin/flutter run -d macos`.

## 5. Google sign-in (Drive sync)

Google sign-in on macOS needs an OAuth **Desktop app** client; the existing
Android/iOS client cannot be reused. Create one once per Google Cloud project:

1. Open <https://console.cloud.google.com/apis/credentials> for the project.
2. **Create credentials → OAuth client ID → Application type: Desktop app**.
3. Copy the client id (ends in `.apps.googleusercontent.com`).

Register it in `macos/Runner/Info.plist`:

```xml
<key>GIDClientID</key>
<string>1234567890-abcdef.apps.googleusercontent.com</string>
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>com.googleusercontent.apps.1234567890-abcdef</string>
    </array>
  </dict>
</array>
```

The URL scheme is the client id **reversed** (`com.googleusercontent.apps.<id>`),
which is what the OAuth redirect returns to.

If the Drive/mail connectors also need a server (web) client id for token exchange,
pass it at build time instead of committing it:

```bash
fvm flutter run -d macos \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=1234567890-web.apps.googleusercontent.com
```

Until the macOS client id is configured, the cloud sync screen reports
"Google sign-in is not configured on this device" and the rest of the app keeps
working.

## 6. Known toolchain blocker

`flutter build macos` needs a full Xcode 15+ install even with Swift Package
Manager enabled. On a machine with only the Command Line Tools:

- Flutter cannot classify the project as Swift-Package-Manager-capable (that check
  asks `xcodebuild` for its version) and stops before the build with:

  ```
  The following plugin(s) are only compatible with Swift Package Manager:
    - llamadart_llama_cpp_flutter

  Your project does not currently support Swift Package Manager. To support Swift Package Manager:
    - Ensure Xcode 15+ is being used   - Enable Swift Package Manager feature by running "flutter config --enable-swift-package-manager"
  ```

- The underlying `xcodebuild` call reports:

  ```
  xcrun: error: unable to find utility "xcodebuild", not a developer tool or in PATH
  ```

  or, when the tools are installed but not selected:

  ```
  xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer directory '/Library/Developer/CommandLineTools' is a command line tools instance
  ```

Installing Xcode and running `sudo xcodebuild -runFirstLaunch` resolves it.
`flutter analyze` and `flutter test` do not need Xcode.

## Multi-device sync policy

LocalMind keeps one encrypted snapshot in an app-created `LocalMind` folder in My
Drive (`drive.file` scope, rotated to the three newest copies) and merges it with
the local snapshot on every sync.

- **Messages merge per record.** Two devices that each append to the same chat keep both
  sets, ordered by request time (`createdAt`, then `threadOrder`, then id). No `(Conflict)`
  copy is created for an appended chat.
- **The same message written twice** resolves deterministically: a completed or errored reply
  beats a streaming checkpoint; otherwise the later `updatedAt` wins, then longer content,
  then lexicographic content, then id.
- **Conversations** merge by id; title, pin, folder, persona, server and model use the later
  `updatedAt` (ties go to the lexicographically larger device id). `messageCount` and
  `lastMessagePreview` are recomputed from the merged active messages.
- **Tombstones** carry the deletion time. A record survives only when it was edited strictly
  after the deletion; legacy list-shaped tombstones read as deleted at the epoch and always win.
- **Order does not matter.** `merge(local, remote)` and `merge(remote, local)` produce the
  same payload, so both devices converge without a coordinator. The one exception is the
  first link: when a device has never synced, it adopts the remote settings instead of
  merging them, so settings resolve to whichever side was the existing snapshot.
- **Sync cadence.** A local change pushes after a 5 s debounce, the app pulls on resume, on the
  cloud-sync screen and every 30 s while the macOS app is open. Remote application is
  suppressed from re-triggering a push.
- `conflictCount` on the sync card counts overlapping edits that the merge had to resolve; it
  no longer means "chats were forked".

## Sandboxed storage

ObjectBox uses POSIX semaphores for its mutexes, and macOS only allows those inside an
application group. The store therefore passes
`macosApplicationGroup: 'pro.momin.localmind'` (see `lib/core/storage/objectbox_store.dart`)
and both entitlements files declare the same group under
`com.apple.security.application-groups`. Without the group the store fails to open with
`failed to create store ... (1: Operation not permitted)`.

The store itself lives in the sandbox container's Application Support directory; the app has no
data outside `~/Library/Containers/pro.momin.localmind/`.
