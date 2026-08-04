# WHOOP 4 Firmware Compatibility

This runbook defines what OpenStrap can claim about WHOOP 4 firmware compatibility and
how to verify an authorized firmware update. It contains reusable evidence and procedure
only. Keep device identifiers, installed versions, database paths, captures, and results
under gitignored `docs/local/`.

## Safety boundary

- `REPORT_VERSION_INFO` (`0x07`) is a read-only query. OpenStrap sends it after
  subscribing, preserves the raw response, and displays the decoded core and Bluetooth
  versions.
- OpenStrap has no supported firmware updater. It does not own firmware images, signature
  validation, transfer recovery, or a tested rollback path. Never use firmware-load,
  force-trim, reboot, power-cycle, pairing-reset, or flash-erasure commands as part of
  compatibility testing.
- Use the official WHOOP app for an explicitly authorized update. WHOOP documents the
  route as Device Settings, Advanced Settings, Firmware Check, Update Now.[S2]
- Only one app may own the band connection. Force-quit OpenStrap before opening WHOOP,
  then force-quit WHOOP before returning to OpenStrap. Installing or inspecting WHOOP is
  not authorization to press Update Now.
- Preserve app data, database and import backups, and the original WHOOP export.

## Evidence ledger

### Published release state

On 2026-08-04, WHOOP's release-notes page listed core firmware `41.17.4.0` as current and
Bluetooth firmware `17.2.2.0` as current.[S1] The page supplied no itemized change list
for `41.17.4.0`. The page does not establish the target queued by any particular app
prompt.[S1]

### Historical records

A real WHOOP 4 capture on core firmware `41.17.6.0` produced 1,704 CRC-valid historical
V24 frames, all decoded by the established V24 map.[S3] This is direct evidence that V24
survived on that device and firmware. It proves frame-level decoding and the captured
offload only. It does not prove every command, a different WHOOP 4 hardware revision, or
`41.17.4.0` directly.

V24 and V25 are values of the historical-record layout byte inside packet type `0x2f`.
They are not firmware versions. Real published WHOOP 4 V25 frames establish an 84-byte
framed record with a Unix timestamp and three-axis gravity.[S5] The mapped optical region
has no verified per-second HR or RR field.[S4][S5]

OpenStrap currently sends V24 and V12 through physiological decoding. V25 is preserved as
`undecodable_rec_v25` by `_ingestHistoricalFrame` in `lib/ble/ble_engine.dart`; it is not
fed into HR, HRV, sleep, or readiness. Keep that behavior until varied, independent
ground truth establishes physiological fields. In particular, do not derive HR from
waveform autocorrelation across concatenated V25 records because record boundaries can
create a false periodic peak.[S6]

The exact V25 optical purpose and emission trigger remain unknown. No canonical evidence
establishes realtime-HR operation as its trigger. Do not label V25 as SpO2, calibration,
signal quality, or an HR source without new ground truth.

### Clock command

OpenStrap currently sends an 8-byte `SET_CLOCK` body containing Unix seconds and
subseconds, then verifies the result with `GET_CLOCK`. The implementation bounds
correction retries to three attempts.

Independent WHOOP 4C hardware evidence on core firmware `41.17.6.0` found that an 8-byte
body received no response while a 9-byte body latched and corrected the device clock.[S4]
The same source states that newer firmware may require 8 bytes.[S4] This is a real,
hardware-specific compatibility risk, not proof that every WHOOP 4 or `41.17.4.0` needs
9 bytes.

Until adaptive, readback-verified 8-byte and 9-byte handling is implemented, do not claim
complete compatibility with an untested firmware. A successful V24 decode does not clear
this control-plane risk.

## Compatibility decision

Treat compatibility as command-specific rather than version-string-specific:

- **History:** Later same-generation evidence retaining V24 lowers the risk that
  `41.17.4.0` removed the V24 map, but this is an inference, not direct `41.17.4.0`
  evidence.[S3]
- **Clock:** Compatibility is unresolved until `SET_CLOCK` readback succeeds on the
  actual hardware. The known 8-byte and 9-byte split is the primary pre-update gap.[S4]
- **V25:** Its presence is not evidence of a firmware update or a V24 replacement.
  Preserve it raw and keep it out of analytics.[S5][S6]
- **Full support:** Require a complete live and historical session on the physical band.
  A parser unit test, version string, or isolated frame is insufficient.

Do not recommend or reject an official firmware update solely from a release-note version
or a single captured frame. Record the exact remaining uncertainty for the person making
the update decision.

## Evidence gaps

- **Inferred:** V24 surviving on one later `41.17.6.0` device lowers the risk of a V24
  history-layout break on `41.17.4.0`; it does not establish direct compatibility.[S3]
- **Unknown:** The version queued by an app prompt that does not name its target, the
  clock-body length required by untested hardware, complete command compatibility, V25's
  optical purpose, and V25's emission trigger.
- **Inaccessible:** Device-specific maintainer captures and database snapshots are kept
  out of tracked documentation. They cannot serve as canonical evidence here.

## Authorized update procedure

### Before the update

1. Force-quit WHOOP and let OpenStrap obtain exclusive BLE ownership.
2. Complete a healthy history session and record its terminal status.
3. Record the decoded and raw `REPORT_VERSION_INFO` response.
4. Verify the clock readback, live HR, HR/RR history, ledger errors, dropped records,
   quarantine count, and SQLite integrity.
5. Create fresh database and import backups without deleting older backups or the
   original export.
6. Force-quit OpenStrap before opening WHOOP.

### During the update

1. Confirm explicit authorization before selecting Update Now.
2. Use only the official WHOOP update flow.[S2]
3. Do not run OpenStrap concurrently or issue any OpenStrap firmware command.
4. Record the version shown by the official app, if any. Do not substitute the public
   release-notes version when the prompt omits the target.

### After the update

1. Force-quit WHOOP before reopening OpenStrap.
2. Confirm OpenStrap reconnects without clearing pairing or app data.
3. Capture the new decoded and raw `REPORT_VERSION_INFO` response. The expected log
   prefix is `[FIRMWARE] core=`.
4. Require `GET_CLOCK` readback to emit `Clock correlated:` with wall-clock agreement.
   Treat bounded retry exhaustion or implausible timestamps as a compatibility failure.
5. Verify live HR and RR traffic.
6. Run history until `[SYNC] OFFLOAD SUMMARY` reports `complete=true`; verify cursor
   progress and durable commit before each batch acknowledgement.
7. Check V24/V12 decoding and inspect any new record-layout reason such as
   `undecodable_rec_v<version>`. If unsupported records arrive, verify their raw archive
   grows. Never route an unknown layout into analytics to make the check pass.
8. Verify zero unexpected drops or quarantine, no ledger error, and SQLite integrity
   `ok`.
9. Preserve the pre-update backup until repeated healthy sessions establish stability.

Stop at the first failed invariant. Preserve evidence and data; do not trim, re-pair,
clear databases, reboot the band, or attempt downgrade or recovery without a separately
reviewed procedure and explicit authorization.

## Sources

[S1]: [WHOOP 4.0 firmware release notes](https://support.whoop.com/s/article/WHOOP-4-0-Firmware-Release-Notes?language=en_US)
[S2]: [WHOOP firmware update procedure](https://support.whoop.com/s/article/WHOOP-3-0-and-4-0-How-to-Update-Your-Product-s-Firmware?language=en_US)
[S3]: [NOOP real WHOOP 4 V24 hardware tests at commit `3b86b6e`](https://github.com/ryanbr/noop/blob/3b86b6ef9e75292855202cc3931d44f77b9ac6f3/Packages/WhoopProtocol/Tests/WhoopProtocolTests/Whoop4HistoricalV24HardwareTests.swift)
[S4]: [NOOP BLE reverse-engineering evidence at commit `3b86b6e`](https://github.com/ryanbr/noop/blob/3b86b6ef9e75292855202cc3931d44f77b9ac6f3/docs/BLE_REVERSE_ENGINEERING.md#set_clock--the-payload-length-is-firmware-specific-hardware-verified)
[S5]: [NOOP real WHOOP 4 V25 frame tests at commit `3b86b6e`](https://github.com/ryanbr/noop/blob/3b86b6ef9e75292855202cc3931d44f77b9ac6f3/Packages/WhoopProtocol/Tests/WhoopProtocolTests/Whoop4HistoricalV25Tests.swift)
[S6]: [NOOP V25 false-HR regression test at commit `3b86b6e`](https://github.com/ryanbr/noop/blob/3b86b6ef9e75292855202cc3931d44f77b9ac6f3/Packages/WhoopProtocol/Tests/WhoopProtocolTests/Whoop4HistoricalV25PpgTests.swift)
