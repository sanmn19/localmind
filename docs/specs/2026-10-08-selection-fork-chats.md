# Selection-anchored fork chats (inline margin-chat)

Date: 2026-10-08 · Status: approved · Branch: feat/selection-fork-chats (stacked on feat/skills-context)

Locked decisions: forks persist across sessions (Q1) · fork context = main history
up to and including the anchor message + the fork's own turns (Q2) · as many
independent forks per chat as the user creates (Q3).

## UX contract

1. Long-press/select a text span inside an ASSISTANT bubble → an inline floating
   panel appears anchored near the selection. It has an input plus the fork's
   transcript (its own Q/A rows and a running stream).
2. Submit → the question plus a marked quoted span go to the LLM with the
   fork-point context: system (+ skills) + main history UP TO AND INCLUDING the
   anchor message (the one containing the selection) + the fork's accumulated
   turns. The main feed never shows the fork's turns.
3. The response streams inside the floating panel.
4. Forks persist: an ObjectBox `ForkAnchor` row {mainConversationId,
   anchorMessageId, spanStart, spanEnd, forkConversationId, createdAt}; the
   fork's turns live in a real (hidden) Conversation row; `forkOfMessageId` +
   `forkSpan` ride on the fork row itself.
5. The anchor span renders a light-yellow background in that assistant bubble
   while a fork exists; tapping it re-opens the same fork thread (transcript +
   input at the bottom). Multiple forks per message are fine — each selected
   span gets its own independent fork thread and its own highlight.
6. The floating panel closes on: (a) main-composer focus/send, (b) its own close
   button. Closing never deletes the fork.

## Model behavior

- Fork requests build Messages-for-API from the fork row's context:
  [system (+ skills index)] + main-timeline-up-to-anchor + the fork's own turns.
  The main post-fork tail is excluded.
- The user's selection is quoted in the fork's first user turn with a marked
  span: `[selected: "<span>"]` followed by the question.

## Files (per-task commits)

- message model: fork fields + `ForkAnchor` ObjectBox entity (build_runner
  regeneration required).
- lib/features/chat/data/fork_service.dart — anchor CRUD + fork-context
  assembly + hidden fork-conversation creation (reuse the conversations
  provider).
- Bubble text rendering: SelectionArea wiring, span highlight rendering
  (background via TextItem spans), tap-to-open gesture on the highlighted span.
- Floating panel widget: lib/features/chat/views/components/fork_chat_panel.dart
  — CompositedTransformFollower/anchored overlay with the fork's own chat
  pipeline (a dedicated fork-notifier per anchor so MAIN chat state/isStreaming
  never mixes).
- Auto-close bridge on composer focus.
- MCP: no new tools — the fork is UI-scoped, not a model tool.
- Fork provider plumbing: fork-notifier issues ChatService.sendMessage with the
  fork-context build, appends to the fork transcript, persists.

## Out of scope (v1)

Fork-merging back into the main thread, fork turn editing, audio/TTS inside the
fork, fork share/export, cross-conversation forks.

## Testing

Unit: anchor CRUD round-trips; fork-context assembly ordering and quoting;
stream isolation. Widget: selection → anchored panel appears; submit → a turn
streams in the panel; close-on-composer-focus contract; persisted highlight and
re-open flow; main thread unaffected by fork turns.
