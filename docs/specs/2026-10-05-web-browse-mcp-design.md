# Embedded Web-Browse MCP Server — Design

Date: 2026-10-05 · Status: approved (configuration choices included) · Architecture: in-process MCP server (Approach A)

## Goal

The app itself hosts an MCP server that gives models (remote or on-device) two
web tools: `web_search` and `web_fetch`. The user-visible "app hosts an MCP"
expectation is satisfied without sockets by reusing the existing in-process
server precedent (`local://example-mcp` in `mcp_server_manager.dart`).

## Architecture

- **`lib/features/mcp/data/web_mcp_server.dart`** — mirrors the example server
  pattern in `McpServerManager`: label `web` (URL constant `local://web`),
  declarative tool list, in-registry interception so tool execution stays in
  Dart (no listener; the app keeps zero port bindings).
- **Registration** — behind a global toggle in app settings
  (`webToolsEnabled`); registered/unregistered in `toolRegistryProvider`
  together with the example server; appears in MCP Tools screen as a
  "Web Browser" server card with the standard MCP badge.
- **Approval behavior (user choice)**: when the toggle is ON, tools execute
  WITHOUT the per-call approval dialog (auto-approval entry; the toggle itself
  is explicit user consent).

## Tools

### web_search(query, max_results ≤ 8)

- Default: DuckDuckGo Lite (`lite.duckduckgo.com/lite/?q=`) HTML parse; zero
  configuration.
- If a provider key is configured in the Web Browser card (Tavily / Brave /
  Serper, in that order of preference), that API is used instead.
- Returns numbered results: title, url, snippet.

### web_fetch(url, max_chars ≤ 8000, default 6000)

- Dio GET with a current Chrome User-Agent and `Accept`/`Accept-Language`
  headers to avoid naive bot blocks (no cookie jar, no referer spoofing).
- Content pipeline: strip `<script>`/`<style>`/`<noscript>` → HTML→plain
  markdown-ish text via the `html` package + entity unescaping → truncate at
  `max_chars` with an explicit `[truncated]` marker + source-url footer.
- Blocks non-public targets (localhost, 127.0.0.0/8, ::1, 10/8, 172.16/12,
  192.168/16, 169.254/16) to prevent SSRF-style probing of local network.
- Timeout follows the tool loop's existing 30 s.

## Settings surface

- `webToolsEnabled` global toggle in **MCP Tools → Web Browser card** (new),
  same visual language as existing cards.
- Optional provider key field(s) in the same card (single provider
  configured at a time; keys stored in app settings, never synced).
- Chat-level enablement inherits the existing per-conversation MCP toggle.

## Files touched

- `lib/features/mcp/data/web_mcp_server.dart` (new) + split
  `web_search_service.dart` / `web_fetch_service.dart` for testability.
- `app_settings.dart` — `webToolsEnabled`, provider key + choice.
- `mcp_server_manager.dart` — registration + interception.
- `tooling_providers.dart` — registry wiring when enabled.
- `mcp_tools_screen.dart` — Web Browser card + key inputs.
- `chat_notifier.dart` — continuation-stream tool-call collection (fix: the
  follow-up streams ignore new tool calls today; search→fetch chains break).
- `pubspec.yaml` — `html` (DOM parsing).

## Out of scope (v1)

JS rendering/SPAs, cookies/sessions, page screenshots, robots.txt enforcement,
caching, pagination.

## Testing

- Unit: DDG Lite parse fixture; HTML→text conversion and truncation; UA
  header assertions; private-IP block; registry wiring; continuation
  tool-call collection.
- Device: search+fetch on the S23 chat; no-approval flow; per-chat gating.

## Amendment 1 (2026-10-07): keyless rings after device-validated blocks

On-device testing showed DDG blocks after ~10 calls. The proven pattern
(reference: hermes-agent's keyless_mcp ring) is layered anonymous vendors
behind browser-grade headers with rotate-on-ratelimit:

- `web_search`: [user-keyed provider (tavily/brave/serper)] → keyless ring
  (exa MCP `web_search_exa` → parallel MCP `web_search`; anonymous, session
  via `Mcp-Session-Id`, rotate cursor on rate-limit-shaped failures) →
  ddgLite → ddg html. New DEFAULT provider setting: `auto` (the chain above);
  explicit provider settings still honored as the FIRST choice.
- `web_fetch`: direct fetch (Chrome UA) → on 403/bot-detection → exa MCP
  `web_fetch_exa` (server-rendered) → ERROR text.
- Ring state (sessions, cursor, cooldown) lives per-service instance inside
  the manager's registration, stateless across app restarts.

## Amendment 2 (2026-10-07): self-hosted SearXNG as the private search tier

The user can point the app at their OWN SearXNG instance (JSON API enabled)
over the private network (Tailscale rig):

- New provider: `searxng` (settings string 'searxng'; option label
  "SearXNG (self-hosted, private)") + `webSearxUrl` base-URL setting
  (nullable; explicit null clears, matching the api-key pattern).
- Backend: GET `<base>/search?q=…&format=json&language=en&safesearch=1`
  — plain JSON, no HTML scraping. Rows with missing url/title are ignored;
  `content` is the snippet (nullable → ''). Non-200 or empty results throw
  `WebSearchBlockedException(searxUnreachableMessage)`.
- Chain resolution: whenever `webSearxUrl` is configured, the searx attempt
  joins FIRST in every chain except the explicit keyless ring — the
  self-hosted private tier outranks the anonymous vendors. Chains:
  - searxng / auto+searxUrl: [searx → ring → ddg chain]; auto without stays
    [ring → ddg].
  - ddg explicit: [searx → ddg chain → ring] when searxUrl is set.
  - keyed vendors: [searx → vendor-with-key → ring] as before, searx leading.
  - a 'searxng' pick without a URL defers to the ring chain (no dead fire).
- Folding: a searx failure continues to the next link; if the whole chain
  fails, the searx reason folds into the surfaced final message.
- UI: the Web Browser card shows a "SearXNG server URL" input when searxng
  is selected; saves on submit and on focus loss like the API-key field.
