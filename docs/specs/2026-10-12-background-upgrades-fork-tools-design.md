# Background task lifecycle upgrades + fork chat fixes

Date: 2026-10-12 · Status: approved · Branch: feat/bg-upgrades-fork-tools (stacked on feat/background-subagents)

Approved from the user's fix list; two judgment calls recorded below (pause
awareness via thread rows; approval reuse for fork tools).

## Feature 1 — background task lifecycle (page + pause + inline controls)

### Semantics
1. `BackgroundTaskState` gains `paused`. Legal transitions (service-enforced,
   idempotent): running→paused (pause), paused→running (resume; ALSO enqueues
   a fresh engine request), running→cancelled (stop; terminal), paused→
   cancelled (stop; terminal). finished/failed stay terminal.
2. **Pause** = halt scheduling + interrupt any live generation (the cancel
   relay wakes the run, the driver's authoritative poll sees `paused` and
   parks the loop driver WITHOUT finalize). **Resume** = state back to
   running + engine requestRun (the driver re-runs from the task thread's
   history).
3. **Agent awareness**: the pause path injects a user-role row
   `Background task paused by user at <HH:MM>` into the task conversation;
   the resume path injects `Background task resumed — continue from where
   this task left off.` Both persist as real rows (they ride the wire every
   subsequent run — the child sees its own pause history). System role is
   FORBIDDEN for injected rows (the LM-Studio service folds the first system
   row into its prompt).
4. Result-row semantics unchanged: only finished tasks append owner rows +
   notifications.

### Background tasks page
1. Route `/background` (`AppRoutes.background`). All tasks grouped per owner
   chat: section header = owner chat title (resolves once per owner);
   rows = state chip, prompt excerpt, run X/Y, last-run time, and inline
   Pause (running) / Resume (paused) / Stop (running|paused) buttons.
2. The chat top-bar triple-dot menu gains **"Background tasks"** → push
   `/background?focus=<ownerConversationId>`: the page scrolls to and
   briefly highlights (accent border/color pulse) that owner's section when
   present; no-op otherwise (list stays at top).
3. Background CARD (MCP Tools screen) gains the same pause/resume/stop
   buttons on rows; delete-owner cascade unchanged.

### Inline chat controls
1. Finished bg result rows in the owner chat keep rendering as before.
2. A compact live status row for tasks in the owner chat — [state chip +
   pause/resume/stop] — driven by the task rows provider; absent when the
   task is closed-terminal (its delivered result row remains).

## Feature 2 — fork chat fixes

### Panel anchored to the selected text
1. The overlay stops relying on a bubble-corner follower; at fork-open time
   the widget measures the highlight band's global Rect (RenderBox
   localToGlobal) and places a positioned overlay entry: prefer ABOVE the
   band (panel bottom sits bandTop - 8), fall back to BELOW the band when
   the space is thin, and always clamp within [8, hostHeight -
   viewPadding.bottom - 8] vertically and 12-margined horizontally.
   Position computed at open; not live-following (scrolling closes nothing;
   user closes or taps outside).
2. Transcript max-height 60% of the host with its own scroll; user rows +
   input + close button unchanged.

### Tool calls in forked chats
1. Fork submits run the SAME tool loop semantics as background tasks'
   runner — extracted shared machinery (tool rounds, assistant+tool row
   shapes, wire assembly) for both pipelines; forks supply the fork context
   assembly and the REAL approval gate.
2. Approval gate: the round executor awaits a
   `Future<bool> Function(ToolCallData call)` closure. Background tasks
   inject an always-dialog-skipping gate (today's behavior); the fork
   injects the real PendingToolApproval flow (reuse the main chat's
   approval structures — completer-backed, surfaced as approve/deny chips
   inside the fork panel while streaming; the panel renders a pending
   approval row with tool name + arguments summary).
3. Fork toolsets respect the app's tool toggles (the same
   auto-approvable/registry path the main chat uses for its wire — fork
   context includes tools when the chat's tools are enabled).
4. `bg.*`/`notifications.*` exclusion baseline applies to forks too —
   the shared machinery takes the fork-safe list from the same snapshot
   builder minus the prefix families.

## Out of scope v1
Task-thread media attachments; forking FROM a fork; page live-updates
beyond invalidate-on-actions (card-level polling only); background-task
export.

## Global constraints
- Constants/registers reuse the background plan's (floor 10, cap 25, ratio;
  ring 200).
- The injected pause/resume rows must pass `shouldIncludeMessageInChatContext`
  and never use the system role.
- Fork approval = NEVER silently-stale: the pending approval row disappears
  when the fork closes (completers completed false on panel close without
  losing the thread).
- Widget tests: no real IO (host constraint), mock channels per call, riverpod
  override lists as bare List, settle transitions, `flutter analyze` clean
  gates every task.
- On-device verification: pause/resume under a live looping task; fork tool
  bubble + approval; panel placement vs the system gesture bar.

## Testing
Unit: state-machine transitions (pause/resume/stop incl. terminal-refuse),
notice-row persistence/roles, child-safe toolset for forks, panel-geometry
pure solver (band rect + constraints → top/left/height). Widget: page
sections + controls + focus-scroll semantics; inline pill rows in chat;
fork panel anchored placement + approval chips + tool round flow; bg runner
with real approvals never triggered in bg mode.
