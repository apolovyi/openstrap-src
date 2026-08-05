# AGENTS.md: OpenStrap `edge`

This file records stable review constraints, not a release snapshot. Read dynamic
values from their owners: `kAlgoVersion` in `lib/compute/derivation_engine.dart`,
`LocalDb.schemaVersion` in `lib/data/db.dart`, and `version` in `pubspec.yaml`.
Where documentation disagrees with implementation, **implementation wins**.
Treat comments and this file as hypotheses whenever current behavior is readable
or executable.

## 0. Mandatory recommendation gate

**Complete this gate before proposing work, ranking a review finding as a fix, or
turning an observation into an action item.** Do not recommend a change from an
isolated inconsistency, an unfamiliar label, a missing test, or a locally
plausible improvement.

1. **Define the decision and outcome.** State the concrete user or operational
   deficiency being considered. Separate correctness and data safety from
   diagnostic convenience, regression hardening, accessibility, and product
   policy.
2. **Trace the complete ownership path.** Follow the producer through lifecycle
   transitions, persistence, every consumer, and the user-visible owner. Read all
   callers and callees. Establish what each field or status semantically means;
   do not infer meaning from its name or from values that merely look
   contradictory.
3. **Inventory what already exists.** Search durable tables, retained raw data,
   append-only logs, fallbacks, repair and replay paths, diagnostics, and tests.
   Determine whether the proposal adds unavailable evidence or duplicates an
   existing source in a second form.
4. **Prove the remaining deficiency.** Reproduce it on the real ownership path
   where possible. A helper-level anomaly, stale-looking debug value, or absent
   end-to-end test is not by itself a user-visible defect. If there is no current
   failure, label the idea optional rather than a fix.
5. **Evaluate the counterfactual.** Explain precisely what changes if the work is
   done, what it cannot prevent, recover, or attribute, what happens if nothing
   is done, and whether added state can itself become stale or ambiguous. Count
   maintenance, storage, UI complexity, false alarms, and competing sources of
   truth as costs.
6. **Reject unsupported policy.** Do not reuse a threshold or rule from another
   layer merely because it is available. Product policy needs its own evidence
   or an explicit user decision.
7. **Classify each candidate independently.** Mark it required, recommended,
   optional, or rejected. "Do nothing" is preferred when the system already
   meets the outcome. Add tests for changed behavior or a demonstrated high-risk
   ownership path, not to compensate for uncertainty in the analysis.

A recommendation must state the evidence for necessity, its marginal benefit
over existing mechanisms, tradeoffs, what it cannot accomplish, and remaining
unknowns. If any of those are UNKNOWN, say so before proposing implementation.

## 1. What this is

A Flutter app for a reverse-engineered WHOOP 4.0 band. Its primary system of
record is local: BLE offload → SQLite → on-device analytics → UI. Explicit
network boundaries exist for one-time cloud-history import, companion status and
OTA, opt-in telemetry and full-database health sharing, BYOK LLM calls, and map
tiles. Do not describe the app as network-free or imply that opt-in uploads stay
on-device.

Three sibling repos, strict separation; push work to the right one:
- `OpenStrap/protocol` — bytes: GATT, framing, CRC, opcodes, record decode.
- `OpenStrap/analytics` — metrics: HRV, sleep staging, readiness, strain.
- `OpenStrap/edge` (**this repo**) — flows, BLE link management, storage, UI.

New opcode/record → protocol. New metric → analytics. New screen/flow/table →
edge. A PR implementing a metric inside `edge/lib/compute` is in the wrong repo
unless it is pure orchestration.

## 2. Architecture map

| file | owns |
|---|---|
| `lib/data/db.dart` | `LocalDb`: schema and migration ladder, CRUD, durable ledgers, coach views |
| `lib/compute/derivation_engine.dart` | `DerivationEngine`, algorithm version, day scheduling, isolate offload |
| `lib/state/app_state.dart` | `AppState`: BLE, database, derivation, and UI orchestration |
| `lib/ble/ble_engine.dart` | GATT connection, continuous history drain, ACK, and reconnect state machine |
| `lib/data/local_repository_impl.dart` | Derived-store read seam to screen payloads; no heavy compute on read |

- `ble/` owns the link engine and pure connection/offload policies in
  `ble_state.dart`.
- `sync/` owns pure sync policies, shared headless serialization, background
  entry points, and OTA.
- `compute/` owns the single raw-to-`Substrate` decode in `substrate.dart`, the
  day model, isolate-safe per-day computation, cross-day computation, and
  orchestration.
- `data/` owns SQLite and repository reads. `day_label.dart` is the only
  day-label helper.
- `notify/` owns event notification gating and persistent fire-once guards.
- `coach/` runs read-only SQL over allow-listed `v_*` views.
- `ui/` owns the design system, shared charts, screens, and presentation.
- `ai/`, `gps/`, `health/`, `telemetry/`, and `widget/` own their named boundary
  integrations.

**Storage.** `decoded_onehz` is the canonical 1 Hz substrate, unique by
`rec_ts`, written with replace semantics, and paired with `decoded_rr`. It is
retention-bounded only after derivation succeeds. `raw_archive` stores
undecodable or unknown-version records and is never pruned. Successfully decoded
frame hex is not retained for replay. `day_result` is versioned by
`(day_id, algo_version)` and replaceable while that generation remains
recomputable; finalization locks it. An algorithm bump writes a separate
generation. `metric_series` is the replaceable current scalar surface keyed by
`(date, key)`.

## 3. Hard invariants (violating these is a P0 regression)

1. **Commit before ACK.** In the history-sync drain in `lib/ble/ble_engine.dart`,
   decoded rows + cursor commit in one transaction *before*
   `buildHistoryResultOk` echoes the verbatim 8-byte HISTORY_END token. The band
   trims flash on ACK. Reordering, or echoing a regenerated/mangled token, causes
   permanent data loss or an infinite re-flood. Never ACK a partial chunk.
2. **`decoded_onehz` stays INSERT-OR-REPLACE keyed on `rec_ts`.** INSERT-OR-IGNORE
   breaks counter-reset recovery. Evicting a row must delete that counter's
   `decoded_rr` beats in the same batch.
3. **Never fabricate a metric.** Absent input ⇒ null / `Metric.absent` / "—". No
   imputation, no substituted defaults, no deriving one metric from another as a
   fallback. Apply the absent-input check in §4.
4. **Bump `kAlgoVersion`** in `lib/compute/derivation_engine.dart` whenever any
   analytics *output* changes, including via a sibling re-pin. The version is
   part of the derived-row identity; without a bump the changed producer is
   indistinguishable from the existing generation. Add a changelog entry above
   the constant.
5. **A bump citing a sibling change must be backed by the pin.** Verify the SHA
   in `pubspec.yaml` actually contains the cited change.
6. **Siblings stay pinned to full commit SHAs.** Never use branch refs or commit
   `pubspec_overrides.yaml`. `pubspec.lock` must resolve both siblings from Git
   with `resolved-ref` matching `pubspec.yaml`.
7. **Day labels are LOCAL.** Always `todayLabel()` / `dayLabelOf()` from
   `data/day_label.dart`; never `DateTime.now().toUtc()...substring(0,10)`. Epoch
   timestamps (rec_ts, session bounds, prune cutoffs) are absolute; do not
   "fix" those to local. Day-length arithmetic must not assume 86400 s (DST).
8. **One source per concern.** One raw decode point (`substrate.dart`), one sleep
   segmentation, one readiness, and one frame-ingest path (`RecordGate`). Event
   notifications go through `NotificationCenter.emit`; established OS scheduling
   and `DeviceAlerts` are narrow exceptions, not permission for another emitter.
9. **Never prune decoded substrate for a day that is not fully derived.**
   `skipped` and `partial` `day_result` rows do not make a day safe to prune.
   `raw_archive` is never pruned.
10. **Heavy compute never on the UI isolate.** Staging/derivation goes through
    `Isolate.run`; analytics ambient globals do not cross the boundary and must
    be re-armed inside the closure.
11. **Migrations additive and idempotent.** `onUpgrade` is a sequential
    `if (oldV < N)` ladder; `onOpen`'s `_repairOpenSchema` re-runs creators so
    same-version merged builds self-heal. Migrations run inside `openDatabase`
    under iOS's CPU watchdog, so keep them cheap. `PRAGMA journal_mode=WAL` must go
    through `rawQuery` (it returns a row; `execute` bricks iOS Darwin sqflite).
12. **Headless/background sync serializes through `HeadlessSyncGate.tryRun`** in
    `lib/sync/headless_gate.dart`: skip, don't queue.
13. **The coach reads only allow-listed `v_*` views** — never `decoded_*`,
    `raw_*`, or base tables.
14. **Live high-rate streams (0x28/0x2B/0x33) are never persisted** — RAM-only.
15. **Dangerous opcodes are never auto-sent** (`dangerousCmds`, gated in
    `lib/ble/ble_engine.dart`): force-trim, reboot, power-cycle, firmware load.

## 4. Review checks

- **Absent input:** metrics return null, `Metric.absent`, "—", or an explicit
  low-confidence state. Never substitute another metric or a plausible default.
- **Repeated derivation:** recomputing a day with incremental data replaces its
  state rather than appending duplicate baseline input or drifting a settled
  scalar. `LocalDb.metricSeries(limit: n)` returns the oldest values; use
  `trailingSeriesValues(key, n)` for a trailing window.
- **Lifecycle flags:** every set flag clears in `finally`, on timeout, and on each
  give-up path.
- **Widget lifecycle:** capture dependencies before `await`; check `mounted`
  before navigation or state updates; do not read Provider from `dispose`.
- **All paths:** wire protocol decode, export, persistence, and notification
  changes into every ownership path, including foreground and headless flows.
- **Notifications:** immediate insight/event presentation uses
  `NotificationCenter.emit`, and fire-once checks remain atomic. OS scheduling
  and `DeviceAlerts` keep their established narrow paths.
- **Presentation:** one semantic value has one source across screens. Preserve
  load-bearing render boundaries and test changed chart behavior.
- **Release metadata:** keep `version:` with its `+BUILD` suffix and align iOS
  widget/watch version fields with the release.

## 5. How to review this repo

`.github/workflows/test.yml` runs on pull requests and pushes to `main` with an
explicitly pinned Flutter version. It checks sibling-pin provenance before
dependency resolution, then runs `flutter analyze` and the full test suite
serially. Capture-backed tests whose private fixture is absent skip in CI and
must be run locally when that fixture is relevant. A behavior change without
coverage on its real ownership path is a finding.

`analysis_options.yaml` is stock `flutter_lints`: no custom rules, no excludes,
no strict language modes.

**Deprioritize:** formatting, import ordering, naming style, `const`
constructors, string-interpolation preference, missing dartdoc, "extract a
widget", and general Flutter/Dart idiom advice not tied to a behavior change.

**Prioritize:** the invariants in §3, the checks in §4, absent-input handling on
every metric path, idempotence under repeated derivation, flag reset on failure
paths, transaction ordering and durability around BLE sync, isolate boundaries,
migration safety, and anything that could display a number the data does not
support.
