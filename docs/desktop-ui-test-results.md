# LocalMind desktop UI test results — pass 1

Driver: `~/.config/opencode/skills/macos-ui-automation/scripts/ui`.
Window: 1512×982 points, `VIEW_FACTOR 0.756`. Build: debug, sandboxed,
`data.mdb` in the container's Application Support.

## Results

| Case | Result | Evidence |
|------|--------|----------|
| A1 window controls | **PASS** | `button 3` → `AXMinimized=true`; restore → `false`; `button 2` toggled full screen |
| A2 tab strip | **PASS** | Chat + Servers tabs rendered, active tab highlighted |
| A3 switch tab | **PASS** | Clicking the Servers tab label shows the Servers screen |
| A4 close tab | **PASS** | × closes the tab; last tab → "No open tabs" |
| A5 `+` new tab | **PASS** | Opens a chat tab |
| A6 `⌘N` | **FAIL** | Resets the single Chat tab instead of opening a second chat tab (`startNewConversation` returns before the new id is readable) |
| A7 `⌘W` | **PASS** | Closes the active tab |
| A9 `⌘K` palette | **PASS after fix** | Was dead after closing the last tab; `_closeFocused` now re-requests shell focus. Palette lists windows, screens and chats |
| A10 `⌘,` settings | **FAIL (fixed, needs recheck)** | Same focus bug; fixed with A9 |
| B1 type | **PASS** | Text lands in the composer |
| B2 send + storage | **PASS** | Send button posts the message; `data.mdb` grew 131,072 → 229,376 bytes |
| B2 reply | **FAIL (environment)** | AI rig returned 404 `model_not_found` for `DeepSeek-V4.1-Flash`; the app shows an Ollama-specific "Pull or load the model in Ollama" copy on an OpenAI-compatible server |
| B3 model picker | **PASS** | "Select model · AI rig" opens the model sheet |

## Bugs found

1. **Two new chats share one tab.** `startNewConversation()` returns before
   `activeConversationIdProvider` holds the new id, so the shell opens the second
   chat with `conversationId == null` and the controller focuses the existing tab.
2. **Shortcuts die after closing the last tab.** Fixed in `fedeb8c` by re-requesting
   the shell focus after a close; re-verify with A9/A10.
3. **Wrong provider copy on 404.** `chat_error_formatter.dart:162` always says
   "in Ollama" even for an OpenAI-compatible server. It should name the active
   server type or stay provider-neutral.
4. **Add-server null check** reported by the user was not reproduced: adding the AI
   rig at `100.126.102.37:8000` saved, tested and persisted. Need the exact server
   type and fields from the failing attempt.

## Not yet run

B4–B12, C, D, E, F, G, H, I, J, K, L, M. Continue from B4 with a fresh
`ui shot` and one screenshot per case.

## Pass 2 — after the draft-tab and focus fixes

| Case | Result |
|------|--------|
| A5 `+` / A6 `⌘N` | **PASS** — three separate Chat tabs, each with its own draft scope |
| A7 `⌘W` | **PASS** — closes only the active tab |
| A9 `⌘K` | **PASS** — palette opens after the last tab was closed and closed again |
| A10 `⌘,` | **PASS** — same focus fix |
| C1 History | **PASS** — opens as a tab, sidebar stays visible |
| D1 Saved Messages | **PASS** — opens as a tab |
| E1 Personas | **PASS** — built-in personas list with category filters |
| F1 Servers | **PASS (screen reachable; tab list showed it opened)** |

Fixes committed: `fedeb8c` (new-chat tabs + shortcut focus) and the draft-tab
scope in `lib/app.dart` / `desktop_window_providers.dart`.

Still open from pass 1: two `⌘N` drafts now open two tabs, but both are titled
"Chat"; the tab title should become the conversation title after the first message.

## Remaining cases

B4–B12 (thinking, smart replies, attach, message actions, mic, voice mode, TTS,
scroll), C2–C6, D2–D4, E2–E4, F2–F7, G, H, I, J, K, L, M.

## Pass 3 — tab strip polish

- Equal tab widths that shrink as tabs are added, then scroll at the 140 pt minimum.
- Vertical separators between tabs.
- Selected tab: tinted background, bold label and a 2 pt accent bar.
- Close `×` appears on hover; the selected tab keeps it visible.
- Covered by `test/features/desktop/desktop_shell_test.dart` ("an inactive tab reveals its close button on hover", "the focused tab is highlighted").

## Pass 4 — crash fixes and settings

| Case | Result |
|------|--------|
| MCP Tools: Calendar Access toggle | **PASS** — no crash after the desktop shell gained a `Scaffold`; the toggle stays off through the macOS permission-denied path |
| Settings tab | **PASS** — General (theme, language, font size, haptics, code themes, Skills link) and Chat (streaming) render |
| Crash screen "Try again" | **PASS after fix** — the ObjectBox store is reused instead of opened twice |
| History / Saved messages / Personas tabs | **PASS** — each opens as its own tab |
| Enter sends | **PASS (widget test)** — `chat_input_bar_enter_test.dart` |
| Shift+Enter newline | **PASS (widget test)** — the draft survives and nothing is sent |

Root causes fixed in `09db13c`:
- Desktop shell had no `Scaffold`, so any hosted screen's `showSnackBar`
  (`mcp_tools_screen.dart:134`, server list) asserted
  `_scaffolds.isNotEmpty` and replaced the app with the crash screen.
- `CalendarService` constructed `DeviceCalendar.instance` eagerly; it is now lazy.
- Contacts permissions use the same macOS guard.
- "Try again" re-ran bootstrap and opened a second ObjectBox store; the store is
  now reused.

Still unverified in this pass (sidebar clicks did not always open the tab before
the screenshot): Servers add/edit/default/delete in the rebuilt binary, History
search/sort/select/delete, Saved message actions, Persona create/edit/delete,
Local Models, TTS, Cloud Sync interactions, Skills, Background.
