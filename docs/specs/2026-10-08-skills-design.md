# Skills — persistent per-chat context skills

Date: 2026-10-08 · Status: approved · Branch: feat/skills-context (base: main)

## Goal

Claude-style skills inside LocalMind: named markdown skills (name +
description + markdown body) that are injected into EVERY chat's context;
manageable from a settings page (view/edit/delete) AND from the model via
chat tool calls; plus a context-usage breakdown (skills / chat history /
tools sections).

## Model & storage

- A skill = one `.md` file under the app documents dir `skills/`:
  `---\nname: <name>\ndescription: <one line>\n---
  <markdown body>`
- Names: lowercase-snake (unique); creation normalizes; edit = rewrite file.
- Kill switch: `skillsEnabled` global setting (default ON — the injection is
  the feature); when off: no injection and no skills tools registered.

## Injection

- `_buildMessagesForApi` appends a system-prompt-section listing every
  skill: `# Skills\n- {name}: {description}\n<body>` (a bounded rendering:
  the whole set truncates with the `[truncated]` marker at the context
  budget's skills slice — 12000 chars max).
- The injection counts toward the context-meter's skills segment.

## Model tooling — local://skills MCP server

- `skills.list` — bare names + descriptions (auto-approved, read)
- `skills.add {name, content, description?}` — write-gated: NEVER
  auto-approved (the approval dialog previews name+description+body)
- `skills.delete {name}` — write-gated the same way
- The write tools modify the store + invalidate the skills provider; the next
  request's system-builder picks them up (same conversation works
  mid-chain!)
- Remote-MCP name-shadowing never inherits auto-approval (isLocalTool).

## Settings UI

- New 'Skills' settings entry (route /skills, mirror mcp_tools_screen wiring):
  - the list: name + description + edit/delete icon buttons; a FAB to add
  - the editor screen: name/description inputs + the markdown body
    (monospace, larger TextField) + Save / Delete
  - a skills ON/OFF switch at the top

## Context meter

- The existing token-usage indicator gains a segmented bar: skills bytes /
  chat history bytes / tools (MCP lists) bytes with an approximate token
  count per segment (chars/4 approximation consistent with the existing
  estimator) + the total.

## Files

- lib/features/skills/data/skills_store.dart + skills_provider.dart
- lib/features/skills/data/skills_mcp_server.dart (+ manager wiring)
- lib/features/skills/views/skills_screen.dart + skill_editor_screen.dart
- system-builder wiring in chat_notifier/_buildMessagesForApi
- tooling_providers: registration + the approval branch
- token-usage indicator extension (the segments)
- routes (+ app_routes), settings entry row, l10n keys

## Out of scope v1

Per-chat skill toggles, multi-file skill bundles/references, skill
marketplace/import flows, per-provider listing, WASM/executed skills.

## Testing

Unit: store CRUD round-trips + name normalization + truncation + injection
rendering; manager/registry wiring tests; approval matrix (writes never
auto); provider invalidation flows.
Widget: skills list screen, editor screen, context-meter bar rendering.
Device: injection visible in real chats once built.
