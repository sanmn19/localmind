# Manual models + availability + rig load-on-pick

Date: 2026-10-19 · Status: draft

## Intent

A provider's models are discovered live from its `/v1/models` endpoint and never
persisted, so a model the endpoint does not advertise (a proxy that hides it, a
model that is currently unloaded on the rig, a custom fine-tune) cannot be attached
to a provider at all. Users need to register such models by hand, keep them across
restarts, see whether each one is usable right now, and — for the rig — load a
listed-but-not-active model without leaving the app.

## Goals

1. Per-provider **manual models** (id + optional display name) that persist and
   appear in every model list next to detected ones.
2. **Availability** per model from the latest detection, shown as a badge, with
   unavailable entries greyed out.
3. Picking an unavailable-but-loadable model opens a **confirmation dialog**,
   triggers the rig's model switcher (`POST /v1/switch/{name}`), and shows **load
   progress** in the app.
4. The load runs on the rig; **quitting the app never cancels it**. Reopening the
   app shows the in-flight switch and resumes polling.

## Non-goals

- Downloading/installing model weights (the rig owns its roster).
- Switching models for providers without a switcher URL.
- Auto-loading on chat send: loading always requires the confirmation dialog.
- Changing the existing provider add/edit form's connection fields.

## Anti-goals

- Never call `POST /v1/cancel` because the app is closing, backgrounded, or the
  progress surface is dismissed.
- Never hide a manual model because detection failed — it stays, greyed out, with
  the failure visible.
- Never block the UI while a switch is in flight (6–20+ minutes).

## Constraints

- Feature-based slices per `.agents/skills/flutter-feature-based-architecture`;
  models code lives in `lib/features/models`, provider storage in
  `lib/features/servers`.
- ObjectBox is the only generated code; a new entity requires
  `dart run build_runner build`.
- All icons `HugeIcon` + `HugeIcons.*`; new strings in `lib/l10n/app_en.arb`
  and regenerated.
- Rig switcher API: `GET /v1/list` (roster: `name`, `label`, `enabled`, `active`),
  `GET /v1/status` (`phase`, `progress`, `target`, `stage`, `attempt`,
  `max_attempts`, `log_tail`, `error`, `message`), `POST /v1/switch/{name}`
  (async), `POST /v1/cancel`. Phases: `idle`, `healthy`, `stopping`,
  `starting`, `loading`, `failed`, `cancelled`.

## Design

### Persistence

New ObjectBox entity `ManualModelEntity`:

| field | type | notes |
|---|---|---|
| `internalId` | int (id) | ObjectBox |
| `serverId` | String, @Index | owning provider |
| `modelId` | String | the API model id (what chat sends, matched against `served_model_name`) |
| `displayName` | String? | optional human label |
| `createdAt` | DateTime | |

Uniqueness on `(serverId, modelId)` is enforced in the repository
(insert-or-ignore + a dedupe query), not by ObjectBox.

The rig exposes two identifiers: the roster `name` (the `POST /v1/switch/{name}`
target) and `served_model_name` (the id chat requests). A manual model stores
only `modelId` — the served model id. The app resolves the roster entry by
matching `served_model_name`. When two roster entries share a served id, the load
confirmation dialog lists the matching targets (label + `name`) and the user picks
one; when none matches, the model is `unavailable` (still selectable, just not
loadable).


Repository `ManualModelRepository` (in `lib/features/models/data/`) exposes
`listForServer`, `add`, `remove`, `removeAllForServer` (called when a provider is
deleted).

### Merge and availability

`availableModelsProvider(serverId)` becomes the single merge point:

1. Fetch detected models (existing `fetchModels`, unchanged).
2. Load manual models for the server.
3. Map each manual entry to a `ModelInfo` (same server type/id, `status:
   unloaded`) and merge, deduped by `id` (detected wins on collision).
4. Annotate availability:

| state | condition | UI |
|---|---|---|
| `available` | present in the detection result | normal |
| `loadable` | manual, roster has an entry whose `served_model_name == modelId`, `enabled && !active` | greyed text + "Load" affordance |
| `unavailable` | manual, no matching roster entry, or the match is `enabled: false`, or no switcher configured | greyed text + "Unavailable" badge, still selectable |
| `unknown` | detection or roster check failed (offline, timeout) | greyed text + "Status unknown" badge, still selectable |

Detection itself is "latest successful fetch"; a failed fetch keeps the last known
list and shows a retry banner instead of emptying the picker. A failed detection is
`unknown`, not `unavailable` — the app never claims a model is gone just because
the network hiccuped. Manual models are always selectable: `unavailable` means
"not advertised right now", not "dead entry". Picking an `unavailable` manual model
selects it and shows a one-line info dialog; picking a `loadable` one opens the load
confirmation. Availability is driven by the switcher roster whenever a switcher URL is
configured, independent of detection — an idle rig (no model active, port 8000 down)
still yields `loadable` entries.

### Switcher URL

`ServerEntity` gains an optional `switcherBaseUrl` (`String?`), edited in the
existing add/edit provider screen as a "Model switcher URL" field (placeholder
`http://<rig>:9000`). Empty means no load flow for that provider. My call: a
field, not a hardcoded rig address, so any switcher-managed box works.

### Load flow

Picking a `loadable` model in any model list (chat picker, voice mode, settings):

1. Confirmation dialog: "Load `<label>` on the rig? The current model is
   unloaded first and loading can take 6–20 minutes."
2. Confirm → `POST {switcher}/v1/switch/{modelId}`. Dismiss → nothing.
3. A progress surface (modal sheet; non-dismissable by accident, with an explicit
   close that only hides it) polls `GET /v1/status` every 3 s and shows: phase,
   `progress` bar, `stage`, last `log_tail` line, `attempt/max_attempts`, and a
   Cancel action (`POST /v1/cancel`) behind a second confirmation.
4. On `phase: healthy`: refresh detection, close the surface, and select the model
   if it now appears.
5. On `phase: failed`/`cancelled`: show `error`/`message`, keep the surface open
   for retry, leave the model greyed.

The progress surface is reconstructed from `GET /v1/status` on app start and on
opening the picker: if `phase` is `stopping`/`starting`/`loading`, it shows the
in-flight switch. No local job persistence is needed — the rig is the source of
truth. Closing the app or the surface never calls `/v1/cancel`.

### Provider models section

The add/edit provider screen gains a **Models** section (edit mode and after a
successful connection test):

- Detected models with a refresh action.
- Manual models with an "Add model" row (model id + optional name) and per-row
  remove.
- Availability badges/greyed styling shared with the picker.

Deleting a provider removes its manual models.

### Resolved during review (my calls)

- **Add-provider staging:** manual rows live in the add screen's form state
  until Save; they are committed with the new provider id. Cancel discards them,
  so no rows can be orphaned by a provisional id.
- **Selection semantics:** the chat picker and voice mode select on tap; the
  settings default-model dropdown only triggers the load flow. After `healthy`, the
  list refreshes; only a load initiated from a picker selects the model. Settings
  leaves the default unchanged.
- **App start:** an in-flight switch resumes as a passive banner plus a resumable
  progress surface inside the picker; never a modal on launch. A completion while
  the surface is hidden refreshes availability but does not change selection.
- **Concurrency:** one switch per provider at a time; load affordances are
  disabled while a switch is in flight. When a reply is streaming, the confirmation
  dialog says the current model is in use and the switch will stop it.
- **Slice ownership:** `availableModelsProvider` stays in `lib/features/servers`
  (servers → models imports are allowed; models never imports servers). The manual
  model repository/entity lives in `lib/features/models`. Provider deletion calls
  `removeAllForServer` on that repository from `ServersNotifier`.
- **Removing a manual model** that is the selected model or the default clears
  that selection/default (no dangling ids).
- **Polling:** only the active server's switcher is polled on app start; the
  progress surface belongs to that provider.
- **Manual model identity:** the form asks only for the served model id (and an
  optional display name). The roster is matched by `served_model_name`; if several
  entries match, the load dialog lists them and the user picks the target; no match
  means the model is selectable but not loadable.

## Testing

- Unit: merge/dedupe, availability mapping (available/loadable/unavailable),
  insert-or-ignore, switcher client (switch/status/cancel) against a fake Dio.
- Widget: greyed + badge rendering, confirmation dialog, progress surface states,
  models section add/remove.
- Regression: picker still lists detected models when detection fails; provider
  deletion cascades.
