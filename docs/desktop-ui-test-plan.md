# LocalMind desktop UI test plan

Driven with `~/.config/opencode/skills/macos-ui-automation/scripts/ui`.
Every action is followed by a screenshot; storage and sync are verified from the
database and the app log, not from pixels alone.

Coordinates below are **view coordinates** (the 2000 px `-view.png` shot).

## A. Window and tabs

- [ ] A1 Native window controls: minimize, zoom, close (AX buttons on window 1)
- [ ] A2 Tab strip lists the open tabs; active tab is highlighted
- [ ] A3 Switch tabs by clicking a tab
- [ ] A4 Close a tab with its ×
- [ ] A5 `+` opens a new chat tab
- [ ] A6 `⌘N` opens a new chat tab
- [ ] A7 `⌘W` closes the active tab
- [ ] A8 `⌘1` / `⌘2` switch tabs
- [ ] A9 `⌘K` opens the command palette; `Esc` closes it
- [ ] A10 `⌘,` opens Settings
- [ ] A11 Tab state survives a relaunch

## B. Chat

- [ ] B1 Type in the composer; text appears
- [ ] B2 Send with the arrow; message is stored (`data.mdb` grows) and a reply arrives
- [ ] B3 Model picker opens and lists models; select one; sheet closes
- [ ] B4 Thinking block expands and collapses
- [ ] B5 Smart-reply chip fills/sends the composer
- [ ] B6 Attach `+` opens the attachment sheet; pick file/image; cancel
- [ ] B7 Message actions: copy, regenerate, speak, more menu
- [ ] B8 More menu: edit, delete, fork, save
- [ ] B9 Mic button starts/stops dictation
- [ ] B10 Voice-mode button opens the voice overlay; close it
- [ ] B11 TTS player bar appears while speaking; stop it
- [ ] B12 Scroll the message list

## C. History

- [ ] C1 Open History from the sidebar
- [ ] C2 Search filters conversations
- [ ] C3 Sort menu changes order
- [ ] C4 Open a conversation from the list; it loads in a tab
- [ ] C5 Selection mode: select, delete
- [ ] C6 Folder filter / create folder

## D. Saved Messages

- [ ] D1 Open Saved Messages
- [ ] D2 Search
- [ ] D3 Open a saved message
- [ ] D4 Delete a saved message

## E. Personas

- [ ] E1 Open Personas; built-ins listed
- [ ] E2 Create a persona; it appears in the list
- [ ] E3 Edit the persona
- [ ] E4 Delete the persona

## F. Servers

- [ ] F1 Open Servers; both servers listed with status
- [ ] F2 Add server (OpenAI-compatible) → Test Connection → Save; tab closes, server listed
- [ ] F3 Add server with a missing host → validation error, no crash
- [ ] F4 Edit a server
- [ ] F5 Set a server as default
- [ ] F6 Delete a server
- [ ] F7 Server status refresh

## G. Local Models (on-device)

- [ ] G1 Open Local Models; backend selector and model list
- [ ] G2 Select a model (download is heavy — check the prompt, then cancel)
- [ ] G3 Delete/unload a model

## H. Text To Speech

- [ ] H1 Open TTS; model list
- [ ] H2 Select a voice and play a sample
- [ ] H3 Download/delete a TTS model (heavy — cancel)

## I. MCP Tools

- [ ] I1 Open MCP Tools; server list
- [ ] I2 Toggle an MCP server
- [ ] I3 Open a server's tool list

## J. Settings

- [ ] J1 Open Settings from the sidebar
- [ ] J2 Change theme; it persists
- [ ] J3 Change language; UI updates
- [ ] J4 Change font size / send-on-enter
- [ ] J5 Open Skills from Settings
- [ ] J6 Open Background tasks

## K. Cloud Sync

- [ ] K1 Open Cloud Sync; provider options S3 / Google Drive
- [ ] K2 Switch provider; fields update
- [ ] K3 S3: invalid endpoint shows validation error
- [ ] K4 Google: Connect shows the OAuth/not-configured state
- [ ] K5 Disconnect clears the config
- [ ] K6 Back up now is disabled until configured

## L. Skills

- [ ] L1 Open Skills; list
- [ ] L2 Create a skill; it appears
- [ ] L3 Edit and delete it

## M. Background tasks

- [ ] M1 Open Background; list and empty state

## Verification sources

- Storage: `~/Library/Containers/pro.momin.localmind/Data/Library/Application Support/pro.momin.localmind/localmind_objectbox/data.mdb` size/mtime
- Log: `flutter run` stdout, `Log.*` lines
- Prefs: `defaults read ~/Library/Containers/pro.momin.localmind/Data/Library/Preferences/pro.momin.localmind`
