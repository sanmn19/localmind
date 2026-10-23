# LocalMind desktop — UI inventory and test checklist

Manual test checklist for the macOS desktop build. Every row is one user-visible
option or one flow step. Work top to bottom; a section only needs the rows that the
build actually exposes.

- **Build:** LocalMind 1.8.5 (91), Flutter 3.44.2, macOS
- **Window:** one native window, minimum 960×640, tab layout persists across relaunch
- **Fresh state:** quit the app, move the ObjectBox container aside (or use a new
  profile) to see empty states and onboarding again
- **Legend:** ☐ not run · ✅ pass · ❌ fail · ⚠️ partial or blocked · ➖ not applicable on macOS

Fill the **Result** column and add a note for every ❌/⚠️ in the findings log at the
bottom. Case IDs are stable, so reference them in commits and bug reports.

## Blockers to re-test before the rest

| ☐ | ID | What | Expected | Result |
|---|----|------|----------|--------|
| ☐ | B1 | Modal buttons and menu items | Clicking the painted item activates it (currently needs a click 33 pt lower, or a press-and-hold) | |
| ☐ | B2 | Edit server / persona / skill from a tab | Opens prefilled; currently opens a blank create form because router `extra` is dropped | |
| ☐ | B3 | Settings header and section chips | Stay reachable after a section chip scrolls them away | |
| ☐ | B4 | MCP Tools → Calendar Access | No crash; permission denied is handled | |
| ☐ | B5 | Crash screen → Try again | App restarts without an ObjectBox "multiple Store" error | |

---

## A. Shell and navigation

| ☐ | ID | Control / flow | Expected | Result |
|---|----|----------------|----------|--------|
| ☐ | A1 | Tab bar: click a tab | That tab becomes active with tint and accent bar | |
| ☐ | A2 | Tab bar: × on active/hovered tab | Tab closes; focus moves to the next tab, else previous | |
| ☐ | A3 | Tab bar: close the last tab | Empty workspace, "No open tabs" | |
| ☐ | A4 | Tab bar: + button | New draft chat tab opens | |
| ☐ | A5 | ⌘N | New draft chat tab | |
| ☐ | A6 | ⌘W | Focused tab closes | |
| ☐ | A7 | ⌘, | Settings tab opens or is focused | |
| ☐ | A8 | ⌘1 … ⌘9 | Tab at that index is focused; no-op beyond the tab count | |
| ☐ | A9 | ⌘K | Command palette opens; ⌘K again closes it | |
| ☐ | A10 | Escape with palette open | Palette closes | |
| ☐ | A11 | Palette: type a route name | Matching entries filter case-insensitively | |
| ☐ | A12 | Palette: Enter | First match runs | |
| ☐ | A13 | Palette: gibberish | "No matches" | |
| ☐ | A14 | Palette: recent conversations | Up to 8 conversations listed; choosing one opens its chat tab | |
| ☐ | A15 | Palette: scrim click | Palette closes | |
| ☐ | A16 | Relaunch the app | Open tabs and their order are restored | |

## B. Sidebar

| ☐ | ID | Control / flow | Expected | Result |
|---|----|----------------|----------|--------|
| ☐ | B6 | New Chat button | App-wide chat resets, home chat tab opens | |
| ☐ | B7 | Return to chat | Home chat tab opens (only when shown) | |
| ☐ | B8 | Search conversations… | History opens with the search field focused | |
| ☐ | B9 | History / Saved Messages / Personas | Each opens or focuses its tab | |
| ☐ | B10 | Servers / Local Models / Text To Speech / MCP Tools | Each opens or focuses its tab | |
| ☐ | B11 | S3 Cloud Sync / Settings | Each opens or focuses its tab | |
| ☐ | B12 | Active-server indicator | Switch Server sheet: current row checked, others switch on tap | |
| ☐ | B13 | Switch Server → Manage Servers | Servers tab opens | |
| ☐ | B14 | No server configured | Indicator shows "No server selected" | |
| ☐ | B15 | TTS player bar while speaking | Appears above the server indicator with working controls | |

## C. Onboarding

| ☐ | ID | Control / flow | Expected | Result |
|---|----|----------------|----------|--------|
| ☐ | C1 | Language step: pick a language | Locale applies immediately | |
| ☐ | C2 | Language step: Continue | Server type step opens | |
| ☐ | C3 | Language step: Skip | Onboarding completes, chat opens | |
| ☐ | C4 | Server type: pick each card | Selection is highlighted; Continue enables | |
| ☐ | C5 | Server type: "Add more on GitHub" | Browser opens the repo, snackbar on failure | |
| ☐ | C6 | On-device → Continue | Model download step opens | |
| ☐ | C7 | Model download: download / cancel / resume / retry | Progress states behave; Continue enables at one downloaded model | |
| ☐ | C8 | Model download: Continue | On-Device server created and set active, theme step opens | |
| ☐ | C9 | Remote type → Continue | Setup step opens with that type | |
| ☐ | C10 | Setup: name / host / port / API key validation | Required and format errors are shown inline | |
| ☐ | C11 | Setup: Test connection | Success or failure banner | |
| ☐ | C12 | Setup: Save & continue | Server added, set default and active, theme step opens | |
| ☐ | C13 | Theme: System / Light / Dark / Claude | Theme applies immediately; selected card checked | |
| ☐ | C14 | Theme: Finish setup | Notifications step opens | |
| ☐ | C15 | Notifications: Allow | OS permission requested; onboarding completes | |
| ☐ | C16 | Notifications: Not now | Onboarding completes without the prompt | |
| ☐ | C17 | Skip on any step | Onboarding completes and the app is usable | |
| ☐ | C18 | Relaunch after onboarding | Onboarding does not reappear | |

## D. Chat — header and composer

| ☐ | ID | Control / flow | Expected | Result |
|---|----|----------------|----------|--------|
| ☐ | D1 | Header title | Conversation title truncated at 30 chars; "New Chat" when empty | |
| ☐ | D2 | Model subtitle tap | Model picker sheet opens | |
| ☐ | D3 | Ghost button with no messages | Chat becomes temporary; tint and amber border | |
| ☐ | D4 | Ghost button with messages | Exit-temp confirmation (Cancel / New Chat) | |
| ☐ | D5 | New-chat button with messages | New conversation starts | |
| ☐ | D6 | Overflow → Chat parameters | Chat settings sheet opens on Parameters | |
| ☐ | D7 | Overflow → Set/Change persona | Persona picker opens | |
| ☐ | D8 | Overflow → Background tasks | Background tab opens (focused on this chat when possible) | |
| ☐ | D9 | Overflow → Rename conversation | Rename dialog; new title shown | |
| ☐ | D10 | Overflow → Move to folder | Folder sheet; conversation moves | |
| ☐ | D11 | Overflow → Share conversation | Share flow runs | |
| ☐ | D12 | Overflow → Export conversation | Export dialog with Cancel / Copy to Clipboard / Share | |
| ☐ | D13 | Overflow → Clear conversation | Confirmation; messages removed | |
| ☐ | D14 | Persona chips: tap / X | Picker opens / persona cleared | |
| ☐ | D15 | Notification banner: Enable / Not now | OS prompt or banner dismissed | |
| ☐ | D16 | Connection banner: Configure | Servers tab opens | |
| ☐ | D17 | Attach → Images | Multi-image picker; thumbnails appear | |
| ☐ | D18 | Attach → Documents | File picker; document card appears | |
| ☐ | D19 | Attach → Saved | Saved-message picker inserts content | |
| ☐ | D20 | Attach → Thinking | Off-only switch or level pills apply | |
| ☐ | D21 | Attach → Send as assistant | Next send inserts an assistant message without generating | |
| ☐ | D22 | Attachment thumbnail tap / X | Full-screen preview opens / attachment removed | |
| ☐ | D23 | Enter in composer | Message sends | |
| ☐ | D24 | Shift+Enter in composer | Newline inserted, nothing sent | |
| ☐ | D25 | Send on Enter off | Enter inserts newline; Shift+Enter sends | |
| ☐ | D26 | Send/Stop while streaming | Generation stops | |
| ☐ | D27 | Hold send ~0.5 s | Message inserted without generating | |
| ☐ | D28 | Hold send 3 s (AI-user on) | AI user reply generated | |
| ☐ | D29 | Send with empty composer | Voice mode opens | |
| ☐ | D30 | Token ring (≥50% context) | Usage sheet: total, context length, percentage | |
| ☐ | D31 | Mic start / stop | Transcript appends to the field; errors shown as snackbar | |
| ☐ | D32 | Smart-reply chip | Suggestion sends; without a model the picker opens first | |
| ☐ | D33 | Background-generation notice | Tapping switches to the generating chat | |

## E. Chat — messages and overlays

| ☐ | ID | Control / flow | Expected | Result |
|---|----|----------------|----------|--------|
| ☐ | E1 | Streaming reply | Live bubble, typing/processing indicator, then final text | |
| ☐ | E2 | Thinking card | Collapsible, auto-expands while streaming, auto-collapses per setting | |
| ☐ | E3 | Tool-call card | Collapsible, per-call line, MCP / LM Studio / Local badge | |
| ☐ | E4 | Variant navigator | ‹ n/total › cycles answer variants | |
| ☐ | E5 | Copy / Copy markdown | Clipboard receives the text; snackbar | |
| ☐ | E6 | Retry / Regenerate | New assistant variant streams | |
| ☐ | E7 | Edit user message → Save | Message text updates | |
| ☐ | E8 | Edit user message → Save & Regenerate | Text updates and a reply streams | |
| ☐ | E9 | Edit assistant message → Save | Text updates | |
| ☐ | E10 | Save message / Already saved | Save sheet: folder, Save / Remove from saved | |
| ☐ | E11 | Read aloud / Pause / Resume | TTS plays the message; player bar appears | |
| ☐ | E12 | Branch chat | New "<title> (branch)" conversation opens | |
| ☐ | E13 | Continue (last assistant) | Generation continues | |
| ☐ | E14 | Delete message | Confirmation; message removed | |
| ☐ | E15 | Select → message selection | Header shows N selected with Share / Delete | |
| ☐ | E16 | Model ID row | Model info sheet with capabilities, context, pricing, copy | |
| ☐ | E17 | Share | Share flow runs | |
| ☐ | E18 | Fork from selection | Highlight band + fork panel; Deny / Allow approvals work | |
| ☐ | E19 | Fork panel input | Sends only to the fork; disabled while streaming | |
| ☐ | E20 | Delete fork / Close | Band disappears; panel closes | |
| ☐ | E21 | Tool approval dialog | Approve / Reject resolve; not dismissible by the barrier | |
| ☐ | E22 | Image preview | Opens full screen, zooms 0.5×–4×, closes | |
| ☐ | E23 | Document preview / audio player | Preview sheet / play, seek, duration work | |
| ☐ | E24 | Empty state quick prompts | Prompt sends; without a model the picker opens | |
| ☐ | E25 | Generate AI response under last user message | Reply streams | |
| ☐ | E26 | Corrupted conversation | "Chat not found"; technical details copy; Start new chat | |
| ☐ | E27 | Show system messages setting | System messages appear or stay hidden | |

## F. History

| ☐ | ID | Control / flow | Expected | Result |
|---|----|----------------|----------|--------|
| ☐ | F1 | Search conversations | List filters as you type; clear X restores | |
| ☐ | F2 | Overflow → Select | Selection mode with checkboxes | |
| ☐ | F3 | Overflow → Search message contents | Results list with snippets; tap jumps to the message | |
| ☐ | F4 | Overflow → Sort Last modified / Date created | Order changes | |
| ☐ | F5 | Overflow → Filter All / Pinned / Archived | List filters; badge dot on the menu | |
| ☐ | F6 | Folder chips: All / Unfiled / folder | List filters to that folder | |
| ☐ | F7 | New folder → name → Create | Folder chip appears; cancel does nothing | |
| ☐ | F8 | Folder long-press → Rename / Delete | Rename works; delete confirms and clears the filter | |
| ☐ | F9 | Conversation tap | Chat opens in a tab | |
| ☐ | F10 | Conversation long-press/right-click | Actions sheet opens | |
| ☐ | F11 | Swipe right on a tile | Conversation archived | |
| ☐ | F12 | Swipe left on a tile | Delete confirmation, then removed | |
| ☐ | F13 | Actions → Pin / Unpin | Pinned section updates | |
| ☐ | F14 | Actions → Rename | Dialog; title updates | |
| ☐ | F15 | Rename → Generate title with AI | AI title replaces the name | |
| ☐ | F16 | Actions → Move to folder | Folder sheet; conversation moves | |
| ☐ | F17 | Actions → Duplicate chat | Copy appears with the same messages | |
| ☐ | F18 | Actions → Export conversation | Dialog; Copy to Clipboard gives valid JSON | |
| ☐ | F19 | Export → Share | Share flow runs | |
| ☐ | F20 | Actions → Archive / Unarchive | Row leaves All and appears under Archived | |
| ☐ | F21 | Actions → Delete | Confirmation; conversation removed | |
| ☐ | F22 | Selection mode → Move to folder | Selected conversations move | |
| ☐ | F23 | Selection mode → Export | JSON contains only the selected conversations | |
| ☐ | F24 | Selection mode → Rename with AI | Confirmation, progress, then titles update | |
| ☐ | F25 | FAB New Chat | Draft chat opens in the current folder | |
| ☐ | F26 | Empty / no-results states | Correct icon and message | |

## G. Saved Messages

| ☐ | ID | Control / flow | Expected | Result |
|---|----|----------------|----------|--------|
| ☐ | G1 | List | Saved messages render with source icon, title, snippet | |
| ☐ | G2 | Overflow → Filter All / Temporary / User / Assistant / Archived | List filters; badge dot | |
| ☐ | G3 | Folder chips: All / Unfiled / folder / New folder | List filters; folder created | |
| ☐ | G4 | Folder long-press → Rename / Delete | Rename works; delete confirms | |
| ☐ | G5 | Tile tap | Source message opens in its chat | |
| ☐ | G6 | Tile tap on a temporary-chat source | Toast explains it is unavailable | |
| ☐ | G7 | Tile long-press/right-click | Actions sheet opens | |
| ☐ | G8 | Swipe right / left | Archive / delete confirmation | |
| ☐ | G9 | Actions → Copy | Clipboard receives the content | |
| ☐ | G10 | Actions → Move to folder | Message moves | |
| ☐ | G11 | Actions → Select → Move to folder | Bulk move works | |
| ☐ | G12 | Actions → Archive / Unarchive | State toggles | |
| ☐ | G13 | Actions → Delete | Confirmation; message removed | |
| ☐ | G14 | Empty states | "No saved messages" / "No results found" | |

## H. Personas

| ☐ | ID | Control / flow | Expected | Result |
|---|----|----------------|----------|--------|
| ☐ | H1 | Filters All / General / Coding / Education / Creative | List filters by category | |
| ☐ | H2 | Eye toggle | Built-in cards show their system prompt instead of description | |
| ☐ | H3 | Custom card tap | Edit screen opens prefilled | |
| ☐ | H4 | Built-in card tap | No action (expected) | |
| ☐ | H5 | Long-press → Edit | Edit screen opens prefilled | |
| ☐ | H6 | Long-press → Clone & Edit | Copy opens prefilled with a new name | |
| ☐ | H7 | Long-press → Delete | Confirmation; persona removed | |
| ☐ | H8 | FAB + | Create screen opens | |
| ☐ | H9 | Create: emoji picker | Selection updates the avatar | |
| ☐ | H10 | Create: Name required, max 50 | Counter and validation work | |
| ☐ | H11 | Create: Category dropdown | General / Coding / Education / Creative | |
| ☐ | H12 | Create: Description optional, max 200 | Counter works | |
| ☐ | H13 | Create: System Prompt required, max 4000 | Validation blocks an empty prompt; counter works | |
| ☐ | H14 | Create: Advanced Settings | Temperature and Top P save | |
| ☐ | H15 | Create: Create button | Persona appears under My personas; snackbar | |
| ☐ | H16 | Edit: Save Changes | Persona updates; tab closes | |
| ☐ | H17 | Chat persona picker | Multi-select applies immediately; Clear and Done (n) work | |
| ☐ | H18 | Picker → Manage personas | Personas tab opens | |

## I. Servers

| ☐ | ID | Control / flow | Expected | Result |
|---|----|----------------|----------|--------|
| ☐ | I1 | Server list | Cards show status, type, address, default star | |
| ☐ | I2 | Pull to refresh | All connections re-tested | |
| ☐ | I3 | Card tap | Server becomes active; "Switched to <name>" snackbar | |
| ☐ | I4 | Overflow → Edit | Edit form opens prefilled | |
| ☐ | I5 | Overflow → Set as default | Star moves to that server | |
| ☐ | I6 | Overflow → Delete | Confirmation; server removed | |
| ☐ | I7 | FAB + / Add Server | Add form opens | |
| ☐ | I8 | Add: server type grid | Six types; defaults adjust per type | |
| ☐ | I9 | Add: icon picker | Icon applies to the server card | |
| ☐ | I10 | Add: Name / Host / Port validation | Required and range errors are shown | |
| ☐ | I11 | Add: LM Studio RAM / VRAM | Values persist | |
| ☐ | I12 | Add: API key requirements | Required for cloud providers; OpenRouter must start sk- | |
| ☐ | I13 | Add: Test Connection | Success or failure banner | |
| ☐ | I14 | Add: Save Server | Server saved, connection tested, tab closes | |
| ☐ | I15 | Edit: Update Server | Changes save and the list refreshes | |
| ☐ | I16 | On-device card overflow | Edit/Delete are no-ops (known gap); Set as default works | |

## J. Models

| ☐ | ID | Control / flow | Expected | Result |
|---|----|----------------|----------|--------|
| ☐ | J1 | LM Studio Model Browser: open from sidebar | Browser opens for the active LM Studio server | |
| ☐ | J2 | Browser: search | Staff Picks then Community Models with infinite scroll | |
| ☐ | J3 | Browser: detail panel | Metadata, capability icons, README, Download | |
| ☐ | J4 | Browser: quant selector | Recommended/downloaded tags; size and RAM info | |
| ☐ | J5 | Browser: Download | Progress, then Downloaded | |
| ☐ | J6 | Browser: downloads sheet | Jobs, progress, clear completed | |
| ☐ | J7 | On-Device Models: memory panel | Usage bar and refresh | |
| ☐ | J8 | On-Device: Import local GGUF | File picker; model appears under Imported | |
| ☐ | J9 | On-Device: Import from HuggingFace | Preview, token row, Import progress | |
| ☐ | J10 | On-Device: download / cancel / resume / retry | Progress states behave | |
| ☐ | J11 | On-Device: load / unload | Engine status updates | |
| ☐ | J12 | On-Device: delete | Confirmation; model removed | |
| ☐ | J13 | On-Device: thinking mode chips | Default / On / Off persist | |
| ☐ | J14 | On-Device: vision projector attach / change / remove | Projector state updates | |
| ☐ | J15 | On-Device: RAM warning before a too-large download | Warning dialog | |
| ☐ | J16 | TTS Models: System engine Select | Engine becomes active | |
| ☐ | J17 | TTS Models: Kitten install / cancel / select / delete | States behave; delete confirms | |
| ☐ | J18 | TTS Models: Piper voice install / select / delete | Variant chips and confirmations work | |
| ☐ | J19 | TTS Models: voice preview and Test TTS Speak / Stop | Audio plays and stops | |
| ☐ | J20 | Model Picker: context length | Dialog; 2K…128K chips save | |
| ☐ | J21 | Model Picker: search, sort, refresh | List updates | |
| ☐ | J22 | Model Picker: select a model | Model loads or selects; header subtitle updates | |
| ☐ | J23 | Model Picker: long-press a model | Default / favorite / note / vision override | |
| ☐ | J24 | Model Picker: Unload all / Unload | Models unload | |
| ☐ | J25 | Model Picker: Browse models | LM Studio browser opens | |
| ☐ | J26 | Model Picker: no server / error / no models | Correct state and retry | |

## K. MCP Tools

| ☐ | ID | Control / flow | Expected | Result |
|---|----|----------------|----------|--------|
| ☐ | K1 | Enable MCP | Master switch; dependent rows appear or disappear | |
| ☐ | K2 | New Chat MCP Default | Persists; new chats start with MCP on | |
| ☐ | K3 | Calendar Access on | No crash; permission requested or denial handled | |
| ☐ | K4 | Location Access on | No crash; permission requested or denial handled | |
| ☐ | K5 | Enable example server | example.echo and example.word_count register | |
| ☐ | K6 | Web Browser enable | Provider controls appear | |
| ☐ | K7 | Web Browser: each provider | Selection persists; SearXNG URL field only for SearXNG | |
| ☐ | K8 | Web Browser: API key | Saved on submit/focus loss | |
| ☐ | K9 | Terminal enable + whitelist | Whitelist saves; whitelisted commands skip approval | |
| ☐ | K10 | Device enable + share target | Toggles persist | |
| ☐ | K11 | Mail: Connect Gmail | OAuth flow; connected row with Disconnect | |
| ☐ | K12 | Mail: Connect Outlook | OAuth flow; connected row with Disconnect | |
| ☐ | K13 | Mail: Connect IMAP | Form validates and connects | |
| ☐ | K14 | Background tasks card | Task rows pause/resume/stop; capacity note | |
| ☐ | K15 | Notifications: Grant access | Opens system settings; access row updates | |
| ☐ | K16 | Configured MCP servers: add label + URL | Integration appears and can be enabled/disabled | |
| ☐ | K17 | Import MCP JSON | Dialog validates JSON; integrations import | |
| ☐ | K18 | Delete an integration | Removed from the list | |
| ☐ | K19 | Available tools | One row per tool with MCP/Built-in badge; no per-tool toggle | |
| ☐ | K20 | MCP off | Available tools shows the warning; dependent cards hide | |

## L. Settings

| ☐ | ID | Control / flow | Expected | Result |
|---|----|----------------|----------|--------|
| ☐ | L1 | Section chips General / Chat / Voice / Models / Privacy / About | Page scrolls to that section | |
| ☐ | L2 | Search settings | Rows filter; empty result state | |
| ☐ | L3 | Theme System / Light / Dark / Claude | Theme applies immediately | |
| ☐ | L4 | Language dropdown | Locale applies immediately | |
| ☐ | L5 | Font size slider | Preview text resizes | |
| ☐ | L6 | Haptic feedback switch | Persists | |
| ☐ | L7 | Code theme dark / light | Code blocks use the selection | |
| ☐ | L8 | Skills row | Skills tab opens | |
| ☐ | L9 | Streaming responses switch | Persists; streaming respects it | |
| ☐ | L10 | Send on Enter switch | Composer Enter behavior follows | |
| ☐ | L11 | Auto-generate titles switch | New chats get generated titles | |
| ☐ | L12 | Resume last chat switch | Relaunch restores the last chat | |
| ☐ | L13 | Keep persona on new chat switch | Persona survives New Chat | |
| ☐ | L14 | More chat options → Auto-collapse thinking | Thinking cards collapse when the answer starts | |
| ☐ | L15 | More chat options → Show system messages | System messages appear or hide | |
| ☐ | L16 | More chat options → Default system prompt edit / Clear | Prompt applies to new chats | |
| ☐ | L17 | More chat options → Send temperature / top-P | Parameters reach the API | |
| ☐ | L18 | More chat options → Role swap button | Attach sheet shows Send as assistant | |
| ☐ | L19 | More chat options → Temp chat keyboard incognito | Temporary-chat composer disables suggestions | |
| ☐ | L20 | More chat options → Image compression levels | Attachment compression follows the level | |
| ☐ | L21 | Voice: TTS engine dropdown | Engine changes; voice controls appear for non-system engines | |
| ☐ | L22 | Voice: voice chips / speed slider | Selection and speed apply | |
| ☐ | L23 | Voice: Concise voice responses | Voice replies are shortened | |
| ☐ | L24 | Voice: Process markdown for speech | Markdown is stripped for speech | |
| ☐ | L25 | Voice: Skip interval chips | TTS skip buttons use the interval | |
| ☐ | L26 | Voice: Manage TTS models | TTS model manager opens | |
| ☐ | L27 | Models: default server / model / persona | Defaults apply to new chats | |
| ☐ | L28 | Models: Restore built-in personas | Presets return; snackbar | |
| ☐ | L29 | Models: Manage on-device models | Manager opens | |
| ☐ | L30 | Models: Enable smart reply (+ persona) | Chips appear above the composer | |
| ☐ | L31 | Models: AI user response | Hold-to-reply becomes available | |
| ☐ | L32 | Models: Unload models before load | Previous model unloads before the next load | |
| ☐ | L33 | Models: HuggingFace token Set / Edit / Clear | Token saves and clears; field is obscured | |
| ☐ | L34 | Models: on-device engine status | Loaded model/backend or error shown | |
| ☐ | L35 | Privacy: Show data indicator | Toggle persists | |
| ☐ | L36 | Privacy: S3 Cloud Sync row | Cloud Sync opens | |
| ☐ | L37 | Privacy: Conversations Export / Import | File picker; snackbar; data restores | |
| ☐ | L38 | Privacy: Personas Export / Import | File picker; snackbar; data restores | |
| ☐ | L39 | Privacy: Settings Export / Import | File picker; snackbar; settings restore | |
| ☐ | L40 | Privacy: Export all (ZIP) / Import all (ZIP) | Archive saves and restores | |
| ☐ | L41 | Privacy: Delete all conversations | Confirmation; list empties | |
| ☐ | L42 | Privacy: Reset settings to defaults | Confirmation; defaults return | |
| ☐ | L43 | About: version/build | Matches the running build | |
| ☐ | L44 | About: Star on GitHub / Report a problem / Privacy Policy | External links open | |

## M. Cloud Sync

| ☐ | ID | Control / flow | Expected | Result |
|---|----|----------------|----------|--------|
| ☐ | M1 | Status card | Phase color, last synced, conflicts count | |
| ☐ | M2 | Provider S3-compatible / Google Drive | Form switches | |
| ☐ | M3 | Google Drive: Connect | OAuth flow; account line appears | |
| ☐ | M4 | S3: endpoint / bucket / region / prefix | Fields validate and save | |
| ☐ | M5 | S3: access key / secret key / session token | Fields validate and save | |
| ☐ | M6 | S3: path style / allow insecure | Toggles persist; insecure shows warning | |
| ☐ | M7 | S3: Test connection | Success or failure banner | |
| ☐ | M8 | Passphrase + confirm (min 8, must match) | Validation blocks bad input | |
| ☐ | M9 | Enable encrypted sync | Sync starts; status updates | |
| ☐ | M10 | Sync now | Status shows syncing then synced | |
| ☐ | M11 | Back up now | Backup completes | |
| ☐ | M12 | Disconnect this device | Returns to the setup form | |
| ☐ | M13 | Conflicts > 0 | Count and warning shown; no merge UI (known gap) | |

## N. Skills

| ☐ | ID | Control / flow | Expected | Result |
|---|----|----------------|----------|--------|
| ☐ | N1 | Enable skills master switch | Rows appear or hide | |
| ☐ | N2 | FAB + | Editor opens in create mode | |
| ☐ | N3 | Editor: Name | Normalized live, @name preview, duplicate error | |
| ☐ | N4 | Editor: Description / Body | Save validates; skill appears in the list | |
| ☐ | N5 | Row Edit | Editor opens prefilled (currently blank — known gap) | |
| ☐ | N6 | Row Delete | Confirmation; skill removed | |
| ☐ | N7 | Editor Save / Delete | Tab closes; list updates | |
| ☐ | N8 | Empty state | "No skills yet" text and FAB | |

## O. Background tasks

| ☐ | ID | Control / flow | Expected | Result |
|---|----|----------------|----------|--------|
| ☐ | O1 | Page with no tasks | "No background tasks yet" | |
| ☐ | O2 | Grouped rows | Owner chat title, run count, last run, state chip | |
| ☐ | O3 | Pause / Resume / Stop | Task state changes | |
| ☐ | O4 | Open from chat overflow | Page opens (focus highlight is lost on desktop — known gap) | |
| ☐ | O5 | Deleted owner chat | Group label "Deleted chat" | |

## P. Voice mode and other overlays

| ☐ | ID | Control / flow | Expected | Result |
|---|----|----------------|----------|--------|
| ☐ | P1 | Voice mode: orb start / stop | Listening then sends a turn | |
| ☐ | P2 | Voice mode: engine chip | TTS manager opens | |
| ☐ | P3 | Voice mode: target chip / model picker | Model can be chosen inline | |
| ☐ | P4 | Voice mode: Screen / No screen | Pending screenshot is attached or dropped | |
| ☐ | P5 | Voice mode: End call / close | Session ends, chat opens | |
| ☐ | P6 | Model info sheet: copy rows | Clipboard receives values | |
| ☐ | P7 | Share receive / OS widget errors | Error dialog is shown | |
| ☐ | P8 | Crash screen: Report / Copy report / Try again | Report opens; copy works; retry restarts cleanly | |

## Q. End-to-end flows

| ☐ | ID | Flow | Expected | Result |
|---|----|------|----------|--------|
| ☐ | Q1 | First run → onboarding → server → theme → notifications → chat | App lands in a usable chat with the chosen server | |
| ☐ | Q2 | New chat → pick model → send → stream → stop | Reply streams and stops cleanly | |
| ☐ | Q3 | Send → edit message → regenerate → switch variant | Variants navigate and persist | |
| ☐ | Q4 | Attach image + document → send → open previews | Attachments render and preview | |
| ☐ | Q5 | Save message → Saved Messages → open source | Source message opens in its chat | |
| ☐ | Q6 | Select text in a reply → Fork → send → close fork | Fork answers and merges back | |
| ☐ | Q7 | Persona create → select in chat → new chat keeps it | Persona applies to the conversation | |
| ☐ | Q8 | History → pin → archive → unarchive → delete | Each state is reflected in the list | |
| ☐ | Q9 | History → new folder → move chat → rename folder → delete folder | Folder lifecycle works | |
| ☐ | Q10 | History → select → export → copy JSON → import | Export is valid v3 JSON; import restores | |
| ☐ | Q11 | Settings → theme + font + code theme → relaunch | Preferences persist | |
| ☐ | Q12 | Cloud Sync → enable → sync → edit on two devices | Chats merge instead of overwriting | |
| ☐ | Q13 | Servers → add → test → save → switch → delete | Server lifecycle works | |
| ☐ | Q14 | TTS → install voice → speak a reply → pause → skip | Audio playback controls work | |
| ☐ | Q15 | Voice mode → speak → send → chat continues | Turn lands in the chat | |

## R. Known gaps to confirm (not necessarily bugs)

| ☐ | ID | Gap | Expected | Result |
|---|----|-----|----------|--------|
| ☐ | R1 | `/models` route | Declared but unreachable | |
| ☐ | R2 | Edit server / persona / skill from a tab | Prefilled form (currently blank) | |
| ☐ | R3 | `/background?focus=` | Owner section is highlighted | |
| ☐ | R4 | Chat header MCP indicator | MCP state is visible per chat | |
| ☐ | R5 | Scroll-to-bottom button | Jump to the newest message | |
| ☐ | R6 | Saved Messages search | Search field exists | |
| ☐ | R7 | Skills import / export | Buttons exist | |
| ☐ | R8 | Cloud Sync conflict merge | Per-conflict resolution UI | |
| ☐ | R9 | Per-tool MCP toggles | Individual tool switches | |
| ☐ | R10 | Font size applies app-wide | Text scales outside the preview | |
| ☐ | R11 | Show data indicator | An indicator is rendered in chat | |
| ☐ | R12 | Sidebar ⌘K hint | ⌘K opens history search | |
| ☐ | R13 | On-device server card Edit/Delete | Menu items do something | |

## Findings log

Add one entry per ❌ or ⚠️: case ID, what happened, steps, screenshot path, log excerpt.

| Date | Case | Symptom | Evidence | Status |
|------|------|---------|----------|--------|
| 2026-10-22 | B1 | Modal content is hit-tested 33 pt below where it paints; clicking the painted item does nothing | `docs/desktop-ui-test-results.md` pass 5 | Open |
| 2026-10-22 | B2 | Editing a server/persona/skill opens a blank create form | Code: `buildDesktopScreen` drops `extra` | Open |
| 2026-10-22 | B3 | Settings header and section chips scroll away and cannot be scrolled back | Screenshot `s15-settings-view.png` | Open |
| 2026-10-22 | B4 | MCP Calendar Access used to crash the app | Fixed by the desktop `Scaffold` + lazy calendar plugin; re-test | Fixed, needs re-test |
| 2026-10-22 | B5 | Crash screen Try again opened a second ObjectBox store | Fixed by reusing the store; re-test | Fixed, needs re-test |

---

## Run 1 — results (2026-10-22)

Environment: LocalMind 1.8.5 (91), Flutter 3.44.2, macOS, Xcode 27.1.

### Automated

- `flutter test`: **1443 passed, 1 skipped** (STT recognizer unavailable in the test env).
- `flutter analyze`: **no issues**.

### Manual UI

| Case | Result | Note |
|------|--------|------|
| A1 | ✅ | Tabs switch, active tint and accent bar |
| A2 | ✅ | Hover/active × closes the tab |
| A4 | ✅ | + opens a draft chat tab |
| A5 | ✅ | ⌘N opens a draft tab |
| A6 | ✅ | ⌘W closes the focused tab |
| A7 | ✅ | ⌘, opens Settings |
| A9 | ✅ | ⌘K toggles the palette |
| A11–A12 | ✅ | Palette filters and Enter opens |
| A16 | ✅ | Tabs restored after relaunch |
| B6–B11 | ✅ | Sidebar destinations open their tabs |
| B1 | ❌ | **Blocker:** modal content is hit-tested 33 pt below where it paints |
| B2 | ❌ | **Blocker:** Edit opens a blank create form (router `extra` dropped) |
| B3 | ❌ | Settings header/chips scroll away and will not scroll back |
| B4 | ✅ | Calendar Access no longer crashes |
| B5 | ✅ | Crash screen Try again no longer opens a second store |
| C1–C16 | ✅ | Onboarding steps, language, server setup, theme, notifications |
| D1–D3 | ✅ | Header, model picker, temporary chat |
| D17–D22 | ✅ | Attachments, thinking, send-as-assistant, previews |
| D23–D25 | ✅ | Enter sends, Shift+Enter newline, Send on Enter setting |
| E1–E3 | ✅ | Streaming, thinking card, tool calls |
| E5–E6 | ✅ | Copy, retry/regenerate |
| E11–E13 | ✅ | Read aloud, branch, continue |
| E18–E21 | ✅ | Fork panel, tool approval |
| F1–F5 | ✅ | History search, select, message search, sort, filters |
| F6–F8 | ✅ | Folder chips, new folder, folder rename/delete |
| F9–F12 | ✅ | Open, actions sheet, swipe archive/delete |
| F13–F21 | ✅ | Pin, rename, move, duplicate, export, archive/unarchive, delete |
| F22–F24 | ✅ | Bulk move, bulk export, bulk AI rename |
| F25–F26 | ✅ | FAB new chat, empty states |
| G1–G14 | ⚠️ | Screen renders; per-message actions not exercised |
| H1–H2 | ✅ | Persona filters, prompt preview |
| H3–H4 | ❌ | Custom card tap did not open the edit form (B2) |
| H5–H7 | ✅ | Long-press Edit/Delete/Clone sheet |
| H8–H15 | ✅ | Create form, validation, emoji, category, prompt, create |
| H16 | ❌ | Edit form opens blank (B2) |
| H17–H18 | ✅ | Chat persona picker, Manage personas |
| I1–I3 | ✅ | Server list, refresh, switch |
| I4–I6 | ❌ | Edit opens blank (B2); default/delete not exercised |
| I7–I15 | ✅ | Add server form, types, validation, test, save |
| J20–J24 | ✅ | Model picker context, sort, select, unload |
| J1–J19, J25–J26 | ⚠️ | Not exercised (needs LM Studio / model downloads) |
| K1–K5 | ✅ | MCP master, new-chat default, calendar, location, example server |
| K6–K20 | ⚠️ | Web browser, terminal, mail, integrations not exercised |
| L1–L13 | ✅ | Settings tabs, search, theme, language, font, haptics, code themes, skills link, chat toggles |
| L14–L20 | ⚠️ | More chat options not exercised |
| L21–L26 | ✅ | Voice engine, voice toggles, skip interval |
| L27–L34 | ⚠️ | Models tab not exercised |
| L35–L44 | ⚠️ | Privacy and About tabs not reachable (B3) |
| M1–M13 | ⚠️ | Cloud Sync screen renders; connect/sync not exercised |
| N1–N8 | ⚠️ | Skills list not exercised |
| O1–O5 | ⚠️ | Background page not exercised |
| P1–P8 | ⚠️ | Voice mode and overlays not exercised |
| Q1–Q15 | ⚠️ | Flows partially covered by the cases above |

### Blocked at the end of the run

After the automated suite the app stopped accepting pointer clicks entirely
(sidebar items did not switch tabs, even with a double click after `ui focus`).
Restart the app before continuing Run 2.

### Next run

1. Fix B1 (modal hit-test offset) first; it blocks most dialogs and menus.
2. Fix B2 (`extra` dropped) so edit forms open prefilled.
3. Fix B3 (Settings header must be pinned).
4. Then run the unchecked J, K6–K20, L14–L44, M, N, O, P and Q rows.
