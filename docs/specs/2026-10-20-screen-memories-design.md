# Screen Memories — sampled, inferred, tagged, expiring context

Date: 2026-10-20 · Status: shipped · Extends
[`2026-10-19-memories-design.md`](2026-10-19-memories-design.md)

## Intent

Localmind should notice what the user is doing in **other apps** — a browser
page, a chat, a document — and quietly form memories from it. These are
`inferred` memories, not things the user asked to remember. They carry tags, a
short summary for context injection, and an expiry date when — and only when — the
model judges the memory to be temporary (a meeting, a deadline, a task). They live, retrieve, filter, back up, and sync exactly like
every other memory.

Sampling is cheap and frequent (every 0.5 s); **understanding is batched** so the
model is not called 120 times a minute. The sampler appends to a disk queue, and a
batch processor drains it every minute, on app open, and when the floating window
is brought up.

## Goals

1. Add `inferred` as a memory **kind** (shown as a type badge, never prefixed to
   the title).
2. Every memory gains `tags`, `shortSummary`, `expiresAt`, and `sourceApp`.
   Tags are generated when the memory is created.
3. Sample the foreground app's visible text every **500 ms** through the
   accessibility service, and append changed samples to an on-disk queue.
4. Process the queue in **batches**: every 60 s, on app open/resume, and when the
   floating Ask Local window is shown. Each batch makes **one** hidden extraction
   call and writes `inferred` memories.
5. Inferred memories inject **only their short summary** into `# Memories`;
   explicit memories keep injecting their content.
6. The Memories screen filters by **kind**, filters/searches by **tag**, and keeps
   semantic search through the existing retriever.
7. Expired memories are excluded from retrieval and stay visible as expired
   (no automatic prune).
8. Backup and cloud sync carry the new fields.

## Non-goals

- No OCR engine and no new model dependency in this version: screen text comes
  from the accessibility node tree. A screenshot + vision fallback for
  canvas/PDF content is a follow-up.
- No always-on microphone or camera capture.
- No multi-user or cross-device screen history.
- No server-side processing: extraction uses the same configured provider.
- No per-sample model calls.

## Anti-goals

- Never read password fields, OTPs, card numbers, or password-manager screens.
- Never store or upload screen pixels; only derived text, and only in the existing
  encrypted backup.
- Never read Localmind's own UI, the keyboard, or the system UI.
- Never let the sampler run while the screen is off or locked.
- Never call the model per sample; only on a batch, with a changed-screen check.
- Never inject an inferred memory as an instruction; it is context only.
- Never let a broken extraction loop burn battery or tokens: changed screens only,
  a batch cap, and backoff after failures.

## Constraints

- Accessibility service config: remove `android:packageNames`, add
  `android:canRetrieveWindowContent="true"` and
  `android:accessibilityFlags="flagRetrieveInteractiveWindows|flagReportViewIds"`.
- `ScreenCaptureAccessibilityService` stays the single bound service and exposes
  `readScreenText()`; it does no model work and no long-lived timer.
- Sampling and batching live in Dart under `lib/features/memories/`; the settings
  row lives in `lib/features/settings/`.
- The sample queue is an ObjectBox entity (`ScreenSampleEntity`) in the existing
  database; no new database and no new dependency.
- ObjectBox is the store; new fields are additive, no migration code.
- One context composition point: `ChatNotifier._assembleApiMessages`.
- No network in tests; fake the screen gateway, the clock, and the extractor.

## Design

### Data model

`MemoryKind` gains `inferred` **appended last**, so existing `kindIndex` values
do not shift.

`MemoryEntity` (and the domain `Memory`) gains:

| field | type | notes |
|---|---|---|
| `tags` | `List<String>` | lowercase, deduped, max 8; generated at creation |
| `shortSummary` | String | one line, used for inferred context injection |
| `expiresAt` | DateTime? | null = no expiry; date-only semantics |
| `sourceApp` | String? | package name for screen memories |

`Memory` gains `bool get isExpired => expiresAt != null && !expiresAt!.isAfter(now)`.

New `ScreenSampleEntity` (the disk queue):

| field | type | notes |
|---|---|---|
| `internalId` | int (id) | ObjectBox |
| `capturedAt` | DateTime | sample time |
| `packageName` | String, @Index | foreground app |
| `text` | String | normalized visible text, cap 8000 |
| `hash` | String, @Index | hash of package + text |
| `processedAt` | DateTime? | null until a batch consumes it |

### Capture pipeline

```
Kotlin readScreenText()                      (no timer, no model)
  ├─ screen interactive + unlocked? null otherwise
  ├─ walk windows/rootInActiveWindow
  ├─ collect text + contentDescription
  ├─ skip own package, keyboard, system UI, isPassword
  └─ cap 8000 chars
        ↓ MethodChannel localmind/screen (on demand)
Dart ScreenSampler (Timer 500 ms)
  ├─ settings.screenMemoryEnabled?
  ├─ package blocked?
  ├─ normalize + hash
  ├─ same hash as last sample? skip
  └─ ScreenSampleStore.add(package, text, hash)
        ↓ ObjectBox (on disk, short-lived)
Dart ScreenMemoryBatchProcessor
  ├─ 60 s timer
  ├─ app opened/resumed
  ├─ floating window shown
  ├─ pending samples → latest per package, merged, cap 4000
  ├─ mark processed
  └─ MemoryExtractionService.extractScreen(...)
        ↓
MemoryRepository.remember(kind: inferred, tags, shortSummary,
                         expiresAt, sourceApp)
```

- The sampler runs at **500 ms** and only writes a row when the screen text
  changed. It never calls the model.
- The batch processor drains the queue at **60 s**, on **app open/resume**, and
  when the **floating window** is shown. Each batch makes **one** hidden call.
- The queue is pruned: processed samples older than **24 hours** are deleted, and
  at most 4000 samples are kept, so the database stays small.
- Hourly extraction cap: 6 batches per hour; failures back off for 5 minutes.
- The tick is paused while the screen is off/locked (`readScreenText()` returns
  null) and while the feature is off.
- Shipped defaults: the feature is **off**; sample every **500 ms**; batch every
  **60 s**; prune samples after **24 hours** and keep at most **4000**.
- Switching the feature off stops the timers and prunes the queue, so text captured
  before disabling cannot outlive its retention window while sampling is paused.

### Extraction

`MemoryExtractionService.extractScreen(...)` shares the parser and hidden-call
plumbing with `extract(...)`:

- Input: the merged batch text (cap 4000 chars), the foreground package, the
  existing titles, and the current time.
- Output per item:
  `{"kind":"inferred","title","summary","content","tags":["..."],
    "importance":0-100,"expiresAt":"YYYY-MM-DD"|null}`
- Rules: durable observations only; skip transient UI chrome; skip secrets. The
  model decides permanence per memory: `expiresAt` is `null` for a permanent fact,
  or the predicted `YYYY-MM-DD` when the memory is temporary (a meeting, a
  deadline, a task, a dated event). There is no default expiry.
- At most 2 memories per batch; tags lowercase, 2–6 per memory.
- The hidden call disables reasoning: it asks for structured JSON, so a thinking
  model must not spend the output budget before emitting any content.
- Dedupe: the repository's near-duplicate title merge updates an existing inferred
  memory (content, summary, tags, expiry) instead of inserting.

The existing auto-remember extractor also gains `tags` and `shortSummary`, so every
memory created by the model has them.

### Retrieval and injection

- `MemoryRetriever.retrieve` excludes `archived`, `superseded`, and **expired**
  rows.
- Scoring text becomes `title + shortSummary + content + tags`; an exact tag match
  adds `+0.1` to the base score.
- `buildMemoriesSystemSection` renders:
  - `inferred`: `- [inferred] title: shortSummary` (fallback to content when the
    summary is empty)
  - other kinds: `- [kind] title: content`
  - tags appended as `[#tag #tag]` when present
  - unchanged 2000-character budget and truncation marker.

### Memories screen

- Search matches title, content, and tags.
- A horizontal kind filter row: All / Fact / Preference / Entity / Event /
  Inferred (`ValueKey('memory_kind_filter_<kind>')`).
- A tag filter row built from the live tags (`ValueKey('memory_tag_filter_<tag>')`);
  tapping toggles the tag.
- Row subtitle: type badge + short summary (inferred) or content (others) + tags;
  an expiry badge ("expires in N days" / "expired").
- Editor: tags (comma-separated), short summary, kind dropdown with the four
  manual kinds (inferred rows come only from the screen extractor), expiry date
  picker (clearable).

### Settings

- `screenMemoryEnabled` (default **false**): master switch.
- `screenMemorySampleIntervalMs` (default **500**; options 500/1000/2000):
  sampling cadence.
- `screenMemoryBatchIntervalSeconds` (default **60**): batch cadence.
- `screenMemoryBlockedApps` (default the known banking/password-manager
  packages): comma-separated package names.
- Settings UI: a **Screen memories** card with the toggle, the sample and batch
  intervals, and a "Blocked apps" dialog; the card states that samples are stored
  on-device for at most 24 hours and text never leaves the device.

### Backup and cloud sync

`DataBackupService` exports/imports `tags`, `shortSummary`, `expiresAt`, and
`sourceApp` for every memory. The screen-sample queue is **not** exported: it is
short-lived working data. `exportCloudSync` derives from the same payload, so cloud
sync carries the memory fields automatically. Absent fields import as empty tags, an
empty summary, and no expiry — tolerant, no failure.

## My calls (check these)

- `inferred` is appended to the enum, not inserted, to protect stored indices.
- Sample every **500 ms**, batch every **60 s**, plus app open and overlay open.
- Permanence is the model's call: no expiry means permanent; no default window.
- Samples are plaintext in ObjectBox, pruned after **24 hours**, never exported.
- Node text only in v1; screenshot + vision fallback is a follow-up.
- The sampler is Dart (`Timer.periodic`); the existing foreground service keeps
  the process alive.
- Tags are free-form lowercase strings, not a tag entity, for v1.
- Expiry never auto-prunes or archives; expired rows stay visible as expired,
  while retrieval excludes them.

## Testing

- Model/store: inferred index mapping; tags/summary/expiry/sourceApp round-trip;
  sample queue add/pending/mark/prune.
- Repository: tag normalization; expiry filter; `pruneExpired` archives expired
  rows for explicit maintenance only (nothing calls it automatically); near-dup
  merge updates inferred fields.
- Lifecycle: app open/resume and the Ask Local overlay call `batchNow`; the
  sampler starts and stops with the settings toggle.
- Extraction: parser accepts inferred + tags + summary + expiry; rejects secrets;
  auto-remember still works.
- Retrieval: expired excluded; tag boost; short summary injected; budget unchanged.
- Sampler: 500 ms cadence; unchanged hash skipped; blocked package skipped;
  screen-off skipped; no model call.
- Batch: one call per batch; merged text; cap; trigger on app open and overlay;
  hourly cap and failure backoff.
- UI: kind filter, tag filter, tag search, expiry badge, editor fields.
- Backup: new memory fields round-trip; sample queue not exported; cloud payload
  includes the memory fields.
