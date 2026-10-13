# Background sub-agent tasks + notifications MCP

Date: 2026-10-09 · Status: approved · Branch: feat/background-subagents (stacked on feat/selection-fork-chats)

Locked decisions: background tasks are chat-owned sub-agent thread runs (Q1) ·
notifications reader = all apps, text only, post-grant (Q2).

## Feature 1 — chat-owned background sub-agent tasks

### Concept
1. The model spawns a background child task from an owning conversation via
   `bg.spawn`. A task is a REAL (hidden) Conversation that accumulates its own
   turns, like a fork thread but whole-life and looping-capable.
2. Modes per task config {prompt, loopMinutes?, maxRuns?}:
   - single-run: one generation, then it finishes and posts its result back;
   - looping: the prompt re-runs every loopMinutes (floor 10) up to maxRuns
     (default 10, cap 25); the child's reply ending with the literal marker
     `[BG_DONE]` (after strip-normalization) finishes the task early.
3. On finish (final run), the task's result is appended INTO the owning
   conversation as a normal assistant-visible row branded with a
   background-task label, and a system notification fires (tap → opens the
   owning chat, scroll-to-row). The main feed shows the task's OWN thread
   only if the user explicitly opens it from the task row/panel (v1: status
   text inline; full thread via a long-press sheet in the same card row).
4. Tasks are owned by the chat: deleting the owning conversation deletes its
   running/finished task threads, cancels live loops.
5. Tools surfacing to the MODEL in the owning chat:
   - `bg.spawn {prompt: string, loop_minutes?: int, max_runs?: int}` — creates
     the hidden task thread, seeds it with the prompt as first user turn.
     NEVER auto-approved.
   - `bg.status {}` — for the CURRENT conversation: running/finished tasks
     with state, last activity timestamp. Auto-approved when toggle on.
   - `bg.cancel {task_id}` — stops a looping task. Auto-approved when on.

### Execution engine
- Android foreground service started when the app enables the feature and a
  task exists, keeping a StatusBar notification ("LocalMind background
  tasks running").
- The service runs a background Dart isolate (flutter_background_service
  pattern). It opens its OWN ObjectBox Store instance on the same DB file,
  snapshots {model target, settings, tool subset} at spawn time, and runs
  generations using the same ChatService classes with a plain Dio built in
  the isolate (no Riverpod in the bg isolate).
- Child tasks may call tools, but ONLY the auto-approvable subset: the bg
  runner evaluates `shouldAutoApproveTool` with a snapshot of the toggles and
  treats non-approved as "tool skipped" (returned to the model as an error
  string). `mail.send`/non-whitelist terminal/dialog-needing tools never run
  unsupervised.
- Concurrency cap: 3 running tasks app-wide; spawn returns an error string
  when saturated.
- App restart: the foreground service auto-resumes (on-boot restart) and
  re-schedules pending looping tasks from persisted task rows.

### Storage
- Hidden conversations: `Conversation.isBackground = true` (mirroring the
  fork pattern) — excluded from history list, search, exports, resume-last.
- New `BackgroundTaskEntity` (ObjectBox): {id, ownerConversationId (indexed),
  taskConversationId (indexed), prompt, loopMinutes (int, 0 = single-run),
  maxRuns, runCount, state (running/finished/cancelled/failed),
  lastRunAt, createdAt, resultMessageId?, ownerMessageId?}.
- fromDomain/toDomain + a small `BackgroundTask` Dart model; build_runner
  regeneration.

### UI
- MCP Tools screen gains a **Background** card: master toggle
  (`backgroundTasksEnabled`, default OFF), live list of tasks with state
  chips, cancel buttons; battery-optimization hint row on first enable.
- In-chat: `bg.spawn/…` calls render through the existing tool-bubble
  machinery; finished results land as normal chat rows.
- Notification: posted via flutter_local_notifications (already a dep).

### Out of scope v1
Task thread editing/merge-back, media in bg runs, cross-chat task porting,
per-task model overrides (spawn uses the active target), notification-created
auto-runs.

## Feature 2 — notifications reader MCP

### Concept
1. `local://notifications` in-process server exposing
   `notifications.read_recent {max?: int (≤50, default 20), since_minutes?:
   int, package?: string}`.
2. Data source: a native Kotlin `NotificationListenerService` (house pattern:
   like ScreenCaptureAccessibilityService). Every captured notification →
   {packageName, title, text, postedAt} into an in-memory bounded ring (200,
   newest first). SESSION-scoped: a phone reboot/rebind resets it; the tool
   output says so when empty.
3. The service requires the user to grant "Notification access" (special
   settings); the Background card hosts the grant row that deep-links into
   the system screen and reflects the granted state (re-check on resume).
4. Toggle `notificationToolsEnabled` (default OFF) gates the server AND tool
   auto-approval (same pattern as deviceToolsEnabled).
5. Privacy: text only (no bundled extras, no conversations), no package
   allow/exclude list in v1 — the toggle is either all-on or all-off.

## Global constraints
- Interval floor 10 minutes; maxRuns ≤ 25; app-wide running-task cap 3.
- The bg isolate NEVER touches UI providers, notifications listener state, or
  the DB via the UI Store — its own Store instance only.
- `[BG_DONE]` detection on the FINAL assistant content only, after the same
  think-tag stripping the main pipeline uses.
- Auto-approve subset ONLY (same `shouldAutoApproveTool` function; dialog
  tools → skipped-with-error). `mail.send` and `bg.*` from WITHIN bg tasks:
  `bg.*` tools are NOT exposed to child tasks.
- New tools always enter `shouldAutoApproveTool` with explicit ownership via
  the registry (notifications → local://notifications; bg → local://device
  is WRONG — a separate `bgMcpServerLabel`/Url pair OWNED by the background
  card toggle).
- Testing: unit tests for spawn/status/cancel round-trips, auto-approve
  subset filtering, [BG_DONE] early-finish, notification ring pruning;
  widget tests for card + tool bubbles; native service verified on-device.

## Testing
Unit: task CRUD + state machine (spawn → run → [BG_DONE] → result row),
cadence math, cap enforcement. Widget: Background card, grant row states.
On-device: foreground service survival, notification capture, battery qs.
