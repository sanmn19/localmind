# Ask Local — system-wide selection overlay card

Date: 2026-10-12 · Status: approved · Branch: feat/ask-local-overlay (stacked on feat/bg-upgrades-fork-tools)

Locked: compact overlay card, stays afloat over any app (Q1-1) · capture at
menu-tap, instant send, re-capture icon (Q2-1) · one REAL "Ask Local"
conversation visible in history (Q3-1 variant) · ALL MCP tools allowed with
in-card approval chips (extra).

## UX contract

1. Any app: long-press/select text → OS selection menu shows **"Ask Local"**
   (Android PROCESS_TEXT intent-filter). Tappe:
   - the app screenshots the CURRENT screen first via the existing
     accessibility capture service (clean frame: nothing of ours is on
     screen yet);
   - then a floating overlay card appears over the underlying app showing
     the capture thumbnail + the selected text as quoted context + a typing
     field + the send (arrow) button.
2. Send: the queued capture + the selected text + the question go to the
   model (full context framing). The answer STREAMS inside the card.
3. Re-capture icon re-shoots the screen at that moment (if the screen
   changed while typing).
4. The card closes via its X; it survives app-switches; the newest asks
   replace the active prompt (one live card; a new "Ask Local" invocation
   opens the same card with a fresh round).
5. Results live in the **"Ask Local" conversation** (created on first use,
   visible in history per user lock); every question = a normal user row
   (with the capture attached to the ask — attachmentPaths) + the streamed
   assistant answer row; reasoning + tool activity render compact rows in
   the CARD (post-liveness patterns) and as normal rows in the conversation.
6. Approvals (mail.send / non-whitelisted terminal / anything dialog-worthy)
   = approve/deny chips INSIDE the card (fork-panel pattern; close = deny).

## Platform design

- New activity `AskLocalTextActivity` with intent-filter PROCESS_TEXT
  (label "Ask Local"); on RESULT: (a) extracts EXTRA_PROCESS_TEXT, (b) asks
  the assistant capture service for an immediate screenshot
  (ScreenCaptureAccessibilityService.takeScreenshot — house path, already
  stitched scrolling-capable but single-frame here), (c) starts/binds the
  floating overlay window and hands it {capturePath, selectedText} via the
  `localmind/ask_local` channel.
- Overlay window: `TYPE_APPLICATION_OVERLAY` + `SYSTEM_ALERT_WINDOW`
  permission ("display over other apps" — one-time settings trip, grant row
  on the MCP Tools 'Ask Local' card w/ live state + re-check on resume).
  Compact card ~ (min(420dp, screen-32), ~38% height), top-right by
  default, drag-handle future-proof hook; FlutterView from the engine
  group's second engine running the `askLocalCardMain` entrypoint.
- Card isolate bootstrap: own ProviderContainer over providers that accept
  an attached ObjectBoxStore (`ObjectBoxStore.attachAsSecondaryIsolate`
  exists from the background-task work) + settings/server/model resolution
  like the widget-era bootstrap; the Ask Local conversation id resolves
  by a marker field... concrete: `ConversationsRepository` create/lookup by
  a `specialKind == 'ask_local'` column (ConversationEntity + model +
  build_runner regen) — VISIBLE history rows unaffected except a title.
- Runs: `ChatService` via the shared factory; toolset = main-chat parity
  (master switch + family toggles + registry) minus bg.*/notifications.
  families; approval chips (no modal dialogs available in an overlay).
- Capture-before-card ordering guaranteed: the intent handler captures
  BEFORE the window's first frame; the card shows a local thumbnail.

## Files (per-task commits; regen when entities change)

- android: AskLocalTextActivity.kt (+manifest PROCESS_TEXT filter),
  AskLocalOverlay.kt (window + FlutterView host + drag stub), MainActivity
  channel handlers (`localmind/ask_local`), capture service reuse.
- lib/features/ask_local/: ask_local_channel.dart (channel + grant checks),
  ask_local_entrypoint.dart (`askLocalCardMain` + mini-bootstrap),
  ask_local_notifier.dart (send/stream with attachment + tools + approval
  chips, merges into the Ask Local conversation), views/fork-style card.
- entities: ConversationEntity.specialKind + model field (+regen).
- MCP Tools screen: 'Ask Local' card (overlay-permission grant row + toggle
  `askLocalToolsEnabled`?? — v1: NO extra toggle; the card = grant row +
  status only; tool gating stays global).
- (deferred) history-list integration: the Ask Local conversation is a
  normal conversation — history already lists it.

## Out of scope v1
Bubble chat API variant; multi-card; per-ask model override; image results
rendering IN the card thumbnails of TOOL outputs; card history browsing
(use the real conversation for that).

## Testing
Unit: PROCESS_TEXT payload parse; capture-path plumbing round-trip; toolset
parity filter; special convo lookup/create concurrency. Widget: card send
flow w/ fake service (rows stream in-card; approval chip; re-capture);
channel harnesses. Device-bid: menu item appears in a non-app surface; the
overlay permission trip; captures do NOT include the card; answer streams
while other apps are foreground.
