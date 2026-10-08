# Device Integration MCP + Mail Connectors — Design

Date: 2026-10-08 · Status: approved · Architecture: two tiers stacked as one PR
Base: main @ 36ee12b (post web-browse MCP + terminal MCP merges) · Branch: feat/device-mail-connectors

## Goal

Interfacing with other apps on the Android device + real mail access:

**Tier 1 — local://device (on-device app interop):**
- `apps.compose_email {to, subject, body, cc?}` — mailto:/ACTION_SEND intent;
  sending = the user's own tap in their mail app (no API send)
- `apps.open {package | deep_link}` — launch apps/deep links
- `apps.list_installed` — installed packages (QUERY_ALL_PACKAGES allowed: sideloaded)
- `contacts.search {query}` / `contacts.by_phone` / `contacts.by_email` —
  device contacts ContentProvider (flutter_contacts dep)
- Share-target receiving: register SEND/SEND_MULTIPLE/VIEW intent filters;
  shared text/images/links open a pre-filled chat (share-receive wiring)
- All ToolProviderType.mcp; approvals: read/launch everywhere auto-approved
  (contacts read-only); compose_email auto (the mail app is the gate)

**Tier 2 — local://mail (OAuth connectors):
- Gmail: google_sign_in (native sheet) + Gmail REST; scopes gmail.readonly +
  gmail.send; MS Outlook personal: msal_auth consumer flow + Microsoft Graph
- Tools: mail.list_unread, mail.search {query}, mail.read_thread {threadId},
  mail.draft {...} (in chat), mail.send {...} — send ALWAYS produces an
  explicit in-app Approve/Send confirmation surface before the API call fires
- Tokens: flutter_secure_storage (never prefs/cloud-sync); per-provider toggles
  in a Mail connectors settings card (connect/revoke/account shown)
- Gmail requires user-configured Google Cloud OAuth client (SHA-1 of the
  signing keystore) — the app surfaces a "not configured" state with setup
  guidance rather than failing silently

## Safety posture

Read/list/search/launch auto-run; any outbound-send (mail.send, compose-API)
= explicit in-app approval; whitelist machinery from terminal flows extended
only where semantics agree (mail sends are NOT whitelist-able — approval only).

## Files (planned; per-task commits)

- lib/features/mcp/data/device_mcp_server.dart (Tier 1) + contacts_service wiring
- lib/features/mcp/data/mail_mcp_server.dart + mail/gmail_repository.dart +
  mail/graph_repository.dart + mail/mail_token_store.dart (Tier 2)
- lib/core/services/share_receive_service.dart + MainActivity intent handling
- app_settings: mailConnectorAccounts + deviceToolsEnabled (+ shareTargetEnabled)
- mcp_tools_screen: Device card + Mail connectors card (connect/revoke rows)
- android manifest: QUERY_ALL_PACKAGES (+ READ/SEND intent-filters), MSAL/web
  intent plumbing per package requirements
- pubspec: google_sign_in, flutter_secure_storage, msal_auth, flutter_contacts,
  googleapis(+auth), receive_sharing_intent
- Out of scope v1: calendar write-back via OAuth (device calendar tools exist),
  attachments upload/packing, Gmail labels-write, shared mailbox.

## Testing

Unit: intent builders (no platform calls), whitelist/approval matrix,
mail repository mapping against fixture JSON (Gmail + Graph shapes), token
store abstraction (in-memory fake), share-payload parsing.
Widget: mail connectors card, device card; graceful not-configured states.
Manual/device: real account connect, read/summarize, approve-send flow,
share-from-other-apps flow.
