# LocalMind Desktop (macOS) and Multi-Device Sync — Design

**Date:** 2026-10-20
**Branch:** `feat/desktop-macos` (worktree `/Users/sanmn19/Code/Localmind-desktop`, based on `origin/main`)

## Intent and the why

LocalMind is an Android-first Flutter app. Running it on a Mac is the fastest way to
iterate on desktop layout, window behaviour and the sync bugs that only show up when
two devices touch the same data. The Mac build is not a port: it is a second client
for the same local store and the same Google Drive backup, and it must reach the same
feature set as the phone.

The motivating moment: a chat is open on the phone, the Mac wakes up and shows the same
chat, and both devices have written to it while the other was asleep. Neither side
should lose messages and the user should never see a "Conflict" copy of a chat they
only replied in.

## Goals

- A macOS desktop target that builds and launches with the existing Dart code.
- A desktop shell that feels native: traffic-light window, sidebar, workspace, floating
  windows with close / minimise / maximise / restore, a dock for minimised windows, and
  keyboard shortcuts (⌘K palette, ⌘N new chat, ⌘W close, ⌘M minimise, ⌘, settings).
- Every phone feature reachable from the desktop shell: chat, history, saved messages,
  servers, personas, MCP tools, skills, on-device models, TTS models, background tasks,
  settings and cloud sync.
- Google Drive sign-in as the primary sync path, reusing the existing encrypted
  backup transport (app-created `LocalMind` folder in My Drive (`drive.file` scope),
  encrypted snapshot, rotation).
- Message-level merge: conversations that only exist on one device are unioned; messages
  inside the same conversation are unioned and ordered chronologically; the same message
  written by two devices resolves deterministically by completion state and timestamp.
- Continuous multi-device sync: a push after local edits, a pull on focus and on a
  periodic timer, with remote application suppressed from re-triggering a push.

## Non-goals (this plan)

- Windows and Linux targets. The desktop shell is platform-neutral Dart, but only the
  macOS runner and entitlements are produced here.
- Cloud sync providers other than Google Drive. The S3 path stays as-is.
- Real-time push (Drive changes feed / webhooks). Pull is timer- and focus-driven.
- Encrypting anything beyond what the existing cloud sync crypto already does.

## Anti-goals

- A separate desktop codebase that forks the phone features. Desktop is a shell over the
  existing feature slices.
- Conflict copies for chats that were only appended to on two devices. That is the current
  behaviour and it is what this work removes.
- Silent data loss. A merge that drops a message without a tombstone or a later version is
  a failure even if it syncs "cleanly".

## Constraints

- Flutter 3.44.2 (`.fvmrc`) and Dart `>=3.12.0 <4.0.0`.
- Feature-slice architecture: a feature imports itself and `core/`, never a sibling.
  The desktop shell is its own slice, `lib/features/desktop/`, and may import `core/`
  and its own components only; screens are injected through a small route map owned by
  `app.dart`.
- `HugeIcon`/`HugeIcons` only, no Material `Icon`; Cue for motion.
- ObjectBox is the only generated code; models and providers are handwritten.
- No secrets in the repo. The Google macOS OAuth client ID is read from
  `--dart-define` / Info.plist and documented as a setup step.
- macOS deployment target 14.0 (MLX and the existing on-device backends need it).

## Decisions

### Platform and runner

The macOS runner is generated in place (`flutter create --platforms=macos`), bundle id
`pro.momin.localmind`, display name `LocalMind`. It uses Swift Package Manager for the
SPM-only plugin (`llamadart_llama_cpp_flutter`) and CocoaPods for the rest, with
`macos/Podfile` pinned to `platform :osx, '14.0'`.
Entitlements: network client (Drive,
model servers), network server (the local web/MCP server), user-selected read/write files
(imports, attachments), audio input (STT, voice mode). Hardened runtime stays on.

Features whose plugin has no macOS implementation degrade instead of crashing:
background service and Android assistant are Android-only; haptics, calendar and the home
widget no-op on macOS; `JustAudioBackground.init` is called only on Android/iOS.

Google sign-in on macOS needs an OAuth **Desktop** client: `GIDClientID` in Info.plist and
the reversed client id in `CFBundleURLTypes`. The Google Cloud project's existing client is
an Android/iOS client, so a macOS client must be created once by the user. Until then the
cloud sync screen reports "Google sign-in is not configured on this device".

### Desktop shell

One native macOS window (traffic lights, resize, full screen) hosting an in-app window
manager. Inside it:

- a resizable sidebar (220–340 pt) built from the existing `SidebarWidget`;
- a workspace canvas where every screen opens as a window;
- a floating window frame: title bar with close / minimise / maximise, eight resize
  handles, drag to move, drag to an edge to snap to half / full, click to focus
  (z-order), double-click the title bar to maximise;
- a dock at the bottom for minimised windows and a new-chat button.

The active chat opens maximised; utility screens (settings, models, history, personas,
servers, MCP, skills, saved messages, cloud sync, background) open as centred floating
windows. Layout (kind, rect, minimised, maximised, z-order, conversation id) is persisted
in SharedPreferences under `desktop.layout.v1` and restored on launch. Geometry is clamped
to the workspace and never saved off-screen.

Multi-chat is a separate stage: the existing `chatProvider` is a single notifier for the
active conversation, so floating chat windows first ship as one live chat plus floating
utility windows. True concurrent chats need the chat session state to become a family keyed
by conversation id, which is the last task in the plan.

### Sync transport

Reuse the unmerged `feat/google-drive-backup` branch: `GoogleDriveApi` (Drive v3 REST),
`GoogleDriveCloudSyncRepository` (encrypted objects in the app-created `LocalMind`
folder in My Drive (`drive.file` scope)), the Google sign-in
session, backup rotation and the `CloudSyncProviderKind.googleDrive` config. This work adds
the merge and lifecycle layers on top; it does not rewrite the transport.

### Merge policy

Merge is deterministic and convergent: `merge(local, remote)` and `merge(remote, local)`
produce the same payload. It runs per record, not per conversation, so two devices that
each appended to the same chat keep both sets of messages.

1. **Messages** are unioned by id. For the same id:
   - a completed or errored message beats a streaming or processing one;
   - otherwise the later `updatedAt` (falling back to `createdAt`) wins;
   - an exact timestamp tie falls back to longer content, then lexicographic content,
     then id.
   The output is ordered by `createdAt` ascending, then `threadOrder`, then id.
2. **Conversations** are unioned by id. Metadata fields resolve by the record's
   `updatedAt` (tie: lexicographically larger device id). `messageCount` and
   `lastMessagePreview` are recomputed from the merged messages.
3. **Personas, saved messages, folders** are unioned by id with last-write-wins on
   `updatedAt` / `savedAt` / `createdAt`.
4. **Tombstones** carry a deletion timestamp (`{id: deletedAt}`). A legacy list of ids
   reads as deleted at the epoch. A record survives a tombstone only when its
   `updatedAt` is strictly later than the deletion; otherwise the deletion wins.
5. Orphan messages (conversation absent after tombstone application) are dropped.
6. The result revision is `max(local, remote) + 1`, device id is the local one.

The old per-conversation conflict copies are removed. A "conflict" count is still
reported for the UI, but it now means "overlapping edits resolved", not "chat forked".

### Timestamps

`Message` and `MessageEntity` gain `updatedAt` (nullable, falling back to `createdAt`).
`MessageSaveService` stamps it on every enqueue, so a streamed reply's final checkpoint
carries the completion time while a request keeps its `createdAt`. Backup/export writes it
and import reads it with the fallback.

### Lifecycle

Push: 5 s debounce after a local store or settings change (existing). Pull: on app
resume, on cloud-sync screen open, and every 30 s while the app is foreground on desktop.
Remote application is wrapped in `_applyingRemote` so it does not schedule a push.

## What's left to the builder

- Exact widget structure, colours and spacing of the desktop shell; follow
  `frontend-design` and the existing theme.
- Whether a window remembers its size per kind or globally (this design: per window id,
  restored by kind when the id is new).
- Which shortcuts beyond the listed ones are worth adding.
- The macOS OAuth client setup steps wording in the docs.
