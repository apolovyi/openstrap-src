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
network boundaries exist for one-time legacy-cloud import, companion status and
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
undecodable or unknown-version records and is never pruned. `raw_records` is a
legacy migration source that `_dropRawStore()` removes; do not assume decoded
frame hex remains available for replay. `day_result` is versioned by
`(day_id, algo_version)` and replaceable while that generation remains
recomputable; finalization locks it. An algorithm bump writes a separate
generation. `metric_series` is the replaceable current scalar surface keyed by
`(date, key)`.

**Historically high-churn files:** `lib/compute/derivation_engine.dart`,
`lib/state/app_state.dart`, `lib/data/db.dart`, `lib/ble/ble_engine.dart`,
`lib/data/local_repository_impl.dart`, `lib/main.dart`, and `lib/app.dart`. Treat
behavioral diffs there with extra scrutiny. `pubspec.yaml` churn is often release
metadata or dependency pins, so inspect intent rather than treating churn alone
as risk.

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
   fallback. Most-violated rule in the repo (§4.1).
4. **Bump `kAlgoVersion`** in `lib/compute/derivation_engine.dart` whenever any
   analytics *output* changes, including via a sibling re-pin. The version is
   part of the derived-row identity; without a bump the changed producer is
   indistinguishable from the existing generation. Add a changelog entry above
   the constant.
5. **A bump citing a sibling change must be backed by the pin.** Verify the SHA
   in `pubspec.yaml` actually contains the cited change. v43's changelog
   described an analytics fix its pin never contained; the bug stayed live three
   releases and only shipped at v46.
6. **Siblings pinned to full commit SHAs, never branch refs.** `ref: main` on
   analytics shipped main-thread ANRs into 0.9.13/0.9.14.
7. **Day labels are LOCAL.** Always `todayLabel()` / `dayLabelOf()` from
   `data/day_label.dart`; never `DateTime.now().toUtc()...substring(0,10)`. Epoch
   timestamps (rec_ts, session bounds, prune cutoffs) are absolute; do not
   "fix" those to local. Day-length arithmetic must not assume 86400 s (DST).
8. **One source per concern.** One raw decode point (`substrate.dart`), one sleep
   segmentation, one readiness, and one frame-ingest path (`RecordGate`). Event
   notifications go through `NotificationCenter.emit`; established OS scheduling
   and `DeviceAlerts` are narrow exceptions, not permission for another emitter.
9. **Never prune decoded substrate for a day that is not fully derived.** `day_result`
   has a `partial` column because days with good headline scalars but a failed
   second-half compute were finalized and pruned, making them unrecoverable.
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

## 4. Recurring bug patterns from shipped regressions

### 4.1 Fabricated / non-abstaining metrics ("honesty" violations)
The project has an explicit never-impute rule and keeps breaking it. Instances:
two copies of a `100 - readiness` stress fallback; RHR falling back to daytime HR
("Readiness 100" ten minutes after first wear); literal `"null"` rendered for
oxygen dips; a skin-temp section gated on `spo2` presence; `StageBars` drawing an
*invisible gap* for an absent sleep stage; pace showing absurd numbers instead of
"—"; a false empty state instead of a retryable error; Bluetooth-off reported as
"no strap found".
**Ask on any metric diff:** what does this return when the input is missing or
thin? Anything other than null/"—"/an honest low-confidence envelope is a bug.

### 4.2 Readiness / recompute-idempotence (the largest single cluster)
Repeated fixes targeted the same user-visible symptoms. Readiness recomputes as
new BLE data lands against a moving 28-day baseline, so any non-idempotent step
corrupts it: duplicate-day appends into the baseline
(MAD == 0 ⇒ robust z abstains ⇒ blank ring), rebuilding on persist but not on
read, withholding a score while the overnight builds but not preventing a
ready→ready drift, flashing a stale value before today settles, and saturation
bouncing the ring to 100.
**Ask:** if this runs three more times today with slightly more data, does the
persisted scalar stay stable? Does it append where it should replace?
**Footgun:** `LocalDb.metricSeries(limit: n)` is `ORDER BY date ASC LIMIT n` =
the **oldest** n. For a trailing window use `trailingSeriesValues(key, n)`.

### 4.3 Sticky boolean latches never reset on the failure path
Self-identified as recurring in the repo's own commit messages ("same shape as
the foregroundActive bug from a couple days ago"). A flag is set, an error path
returns early without clearing it, and sync wedges until force-close. Past
instances included `foregroundActive`, `markForegroundIntent`, `_offloadActive`,
`_drainingOffloadFrames` (no `try/finally`), a sticky standard-HR fallback that
silently zeroed step calibration, and trusting a stale `isConnected`.
**Ask:** every flag set in this diff — is it cleared in `finally`, on timeout, and
on the give-up branch?

### 4.4 Heavy compute on the main/UI isolate → ANR, jank, stuck launch
Recurred one build apart: `cardioStager`'s per-30s Lomb–Scargle on the main
isolate (Android ANRs every ~30 s), then the *entire second half* of
`_derivePreparedDay` running on the UI isolate for the foreground pass that fires
on every sync. Also: app freezing during backfills, unbounded pre-`runApp` inits
stalling launch, a dark-mode rebuild storm starving background BLE.

### 4.5 `context` / Provider used after `await` or after unmount
Repeated crash source: `Provider._inheritedElementOf` null in `dispose`,
`context.read` in `dispose`, bare `Navigator.pop()` after an `await`, missing
`mounted` guard on a post-navigation reload.

### 4.6 Notification re-fire, dedupe race, and gating bypass
Call sites promised "at most once per day" with nothing enforcing it, so
derivation re-runs re-fired them across illness, anomaly, temperature, readiness,
HR-shift, recovery-ready, step-goal and auto-workout alerts. Then the stress
screen called `NotificationService.presentEvent` **directly**, bypassing both the
prefs gate and the new dedupe guard. Then a TOCTOU race let two overlapping
`emit()`s both pass `hasFired`.
**Flag:** any direct immediate insight/event presentation that skips
`NotificationCenter.emit`, and any check-then-record without the lock. Established
OS scheduling and the narrow `DeviceAlerts` path are intentional exceptions.

### 4.7 Capability wired into one call path but not all N
The most damaging instance: `FirmwareAwareR24Decoder` existed but was not wired
into all three decode paths (`ble_engine.dart`, `db.dart`, `substrate.dart`), so
a real user's 88-byte v12 records were 100% silently archived, causing a total
sync outage. Also: HealthKit export gated on `day_result` and never session-triggered
(a workout finished offline never exported); auto-detected workouts never
reaching the `sessions` table, invisible to both AI Coach and Health export.
**Ask:** how many call sites exist for this concern, and does the diff cover all
of them?

### 4.8 UTC-vs-local and day-boundary math
Fixed, then reintroduced *in the same file* (SRI's hypnogram grid used raw UTC
time-of-day right below the fix for that exact mistake), then again in the
`v_sessions` view (AI Coach mis-dated workouts). Also: day math assuming 86400 s
breaking on DST, a briefing greeting "morning" in the afternoon, sleep not
detected in non-UTC timezones, and an alarm armed in the phone's clock frame
instead of the strap's RTC frame so it never fired.

### 4.9 Dependency pinning / lockfile / release metadata
Repeated failures include: committed path `dependency_overrides` broke a release;
`pubspec.lock` resolved a package via a stale local path; floating `ref: main`
rode analytics v42 into 0.9.13; a PR bumped `kAlgoVersion` while the lock still
pinned the pre-fix analytics commit, requiring a manual merge-order gate; and
`0.9.17+1` shipped versionCode 1 → `INSTALL_FAILED_VERSION_DOWNGRADE`, making
the release uninstallable.
`pubspec_overrides.yaml` redirects to the sibling analytics and protocol
repositories and is gitignored; it must never be committed. `pubspec.yaml` owns
the requested full SHAs, while `pubspec.lock` must resolve both siblings from
Git with a matching `resolved-ref`. The CI pin guard checks both before
`flutter pub get`. `version:` must keep its `+BUILD` suffix, and the iOS
widget/watch `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` are bumped
manually and can drift.

### 4.10 Duplicated / inconsistent values across screens
Today showed strain/sleep/stress twice; a week-load wheel duplicated the strain
figure; the steps figure disagreed across screens through several unification
attempts; two different HRV baselines were both labeled "baseline" on one screen.

### 4.11 Chart / hypnogram render regressions
`Hypnogram.plot` lost its `RepaintBoundary` in a refactor and stayed lost through
three rewrites before being restored. Also recap scrub-marker misalignment,
`GanttPainter` needing restoration, and `RangeError` from unpadded substrate
fields. Rendering regressions here surface as test failures rather than obvious
visual bugs; check whether removed wrapper widgets were load-bearing.

## 5. How to review this repo

`.github/workflows/test.yml` runs on pull requests and pushes to `main` with an
explicitly pinned Flutter version. It checks sibling-pin provenance before
dependency resolution, then runs `flutter analyze` and the full test suite
serially. Capture-backed tests
whose private fixture is absent skip in CI and must be run locally when that
fixture is relevant. Several regression tests are named for the bug they pin
(`readiness_flash_test`, `readiness_freeze_test`, `readiness_saturation_test`,
`readiness_baseline_pollution_test`). A behavior change without coverage on its
real ownership path is a finding.

`analysis_options.yaml` is stock `flutter_lints`: no custom rules, no excludes,
no strict language modes.

**Deprioritize:** formatting, import ordering, naming style, `const`
constructors, string-interpolation preference, missing dartdoc, "extract a
widget", and general Flutter/Dart idiom advice not tied to a behavior change.

**Prioritize:** the invariants in §3, the patterns in §4, absent-input handling on
every metric path, idempotence under repeated derivation, flag reset on failure
paths, transaction ordering and durability around BLE sync, isolate boundaries,
migration safety, and anything that could display a number the data does not
support.
