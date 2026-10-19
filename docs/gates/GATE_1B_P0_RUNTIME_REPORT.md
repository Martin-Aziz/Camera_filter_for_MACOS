# PrivateCam Gate 1B-P0 Runtime Verification Report

**Date:** 2026-10-18 (Europe/Berlin)
**Decision:** **FAIL / NOT ACCEPTED — stop at Gate 1B-P0.** No successor was installed or activated. No Gate 1B-P1 work was performed.

## Scope and stop conditions

This submission packages the current P0 source, full working-tree patch, synthetic test implementation and logs, prior build/signing evidence, current source and executable hashes, and a fresh read-only preflight reconciliation. No activation request, `/Applications` replacement, physical camera stream, reboot, security change, commit, or push occurred during this pass. No imagery was collected or saved.

The candidate cannot proceed to operator approval: its extension version is still `4`, exactly the installed extension version, so it is not a version-incremented successor. Static inspection also found a policy ambiguity in Release: `CameraPrivacyStateMachine.clientMayStart` returns `true` when no lease exists (or the build is not development). The output source presently starts at the generated pattern and the physical capture route is Debug-compiled, but an allow result on missing authorization is weaker than the directive's explicit fail-closed contract. Do not activate this binary. The next version must harden this contract, rebuild, and re-run the synthetic suite before proposing installation.

## Criterion-by-criterion status

| Directive criterion | Status | Evidence / reason |
|---|---|---|
| Complete current report, patch, tests/logs, signing evidence, source hashes | **PARTIAL** | Current package includes the Gate 1B report, source additions patch, full working-tree patch, test sources/logs, signing/build logs and refreshed source hashes. See evidence index. Historical v4 provenance artifacts are unavailable. |
| Read-only baseline: registry, inventory, installed hashes, IDs, SIP/Gatekeeper | **PARTIAL** | Registry and security-state snapshots are retained; executable hashes and bundle IDs are recorded in `evidence/gate1b-p0/`. Fresh process inventory was not taken in this pass. Historical v4 build artifacts/source unavailable. |
| Exact authorization algorithm / revocation linearization | **FAIL / NOT VERIFIED** | Static review shows authorization re-evaluated before send, serialized on state queue, generation-checked and lease tombstone-backed. But no single formally enforced linearization point across concurrent frames and `CMIO send` is established. Release `clientMayStart` returns true on absent lease. Pending raw frame and revocation race never exercised in running extension. |
| Release cannot publish raw without valid authorization | **PARTIAL** | `developmentPhysicalCaptureEnabled` is `#if DEBUG`; Release builds without `DEBUG`, and physical source selection is conditional. However policy helper permits starts with missing lease and there is no runtime proof of the exact signed candidate. Treat as a prerequisite defect/ambiguity, not a pass. |
| Preserve working v4 app/artifacts and supported recovery procedure | **PARTIAL** | Installed v4 remains untouched and its executable hashes are recorded. Its original source/build artifacts were not found in the project or supplied archives, so an intact reproducible v4 copy and full recovery procedure cannot be confirmed. Recovery requires a separately signed activation request and may require operator action; immediate rollback is not assumed. |
| Signed version-incremented successor / activation plan | **NOT READY** | Current app/extension IDs are `com.martinaziz.privatecam` and `com.martinaziz.privatecam.CameraExtension`; source project team is `MPLX762T5G`; app and extension entitlements and previous signature checks are in `signature-verification.txt`. Current candidate and installed extension both have CFBundleVersion `4`. A proper successor binary has not been built. No operator approval requested for an invalid same-version candidate. |
| Install and delegate callbacks | **NOT VERIFIED** | No supported `/Applications` + `OSSystemExtensionRequest` update performed. Delegate implements replacement callback returning `.replace`, plus approval/finish/failure logging, but no callback evidence exists. |
| Independent AVFoundation client / safe output without authorization | **NOT VERIFIED** | Only metadata discovery and harness compilation are available. The independent client was not run against this candidate. |
| Closed host, stale setting, crash, expiry | **SYNTHETIC ONLY** | Test suite exercises model cases; no active extension callbacks/frames were tested. Shared preferences no longer authorize raw, but runtime behavior is unverified. |
| TCC denied, capture interruption, unavailable device, processing/buffer failures | **PARTIAL / SYNTHETIC** | Source has denial/failure paths and fail-closed transitions. No controlled runtime fault injection against installed candidate. |
| Revocation with pending raw frames / two consumers | **NOT VERIFIED** | Generation checks and one-pending-frame relay exist. No deterministic injected race at dequeue/send boundary or two-client runtime test. |
| Two clients, final shutdown, physical release, stable identity | **NOT VERIFIED** | Stable UUIDs remain in source (`76A10B58-2C45-4B8C-BE2A-0D6F1C286101`, stream `...286102`). No live client overlap/shutdown or `inUse=false` evidence for candidate. |
| 720p/1080p discrepancy | **PARTIAL** | Producer advertises 1280×720; metadata-only device discovery measured 1280×720 420v 30 FPS, while retained earlier receiver baselines report 1920×1080. No current signed-candidate runtime negotiation matrix; cause remains undetermined. No speculative camera pipeline change made. |
| 60-second timing/performance and drops | **NOT VERIFIED** | Candidate has diagnostic counters but no runtime logs, PTS/FPS acceptance run, allocation result, CPU/RSS, or independent receiver timing. |
| No imagery, bypasses, historical cleanup, commit/push | **PASS (this pass)** | No images saved/uploaded; no SIP/Gatekeeper changes; no historical records removed; no commit/push. |

## Authorization and dataflow review

Current static path: CMIO stream start reads the development lease and current stream client list; in Debug a fresh lease bound to owner PID/signing ID permits physical capture. Physical capture frames enter a bounded one-frame relay, then return to the state queue where lease, current clients, session ID and capture generation are checked immediately before `stream.send`. The lease watchdog polls at 100 ms; heartbeat TTL is 1.5 seconds. Revocation writes a per-session tombstone to block later heartbeat restoration and increments capture generation when failure is handled.

This is not proof that no send crosses a revocation boundary. Revocation from the host and send on the extension state queue do not share an interprocess atomic linearization primitive. The directive requires deterministic fault injection at pending/dequeue/send with marker disclosure checks. No such operating-system integration proof exists. No raw marker or physical frame was observed in this pass.

Required next engineering change: define an explicit fail-closed authorization result for missing/expired authorization in every configuration; establish a serialized revocation/send boundary that can be tested deterministically; add an injected synthetic-frame marker harness without physical imagery; then build a signed version-incremented successor. Preserve the present signed v4 and do not clean historical records.

## Format evidence

| Layer | Observed property | Evidence |
|---|---|---|
| Physical device enumeration | 1280×720, 420v, 30 FPS advertised; discovery only | `device-formats-metadata-only.log` |
| Candidate CMIO source | 1280×720; pixel format selected from native 420 bi-planar source | Source review; no runtime log |
| Historical receiver | 1920×1080 buffers under retained High and 720 preset baseline runs | `format-high-baseline.log`, `format-720-baseline.log` |
| Receiver auto-sizing true/false matrix | **Not verified** | No candidate run; macOS SDK marks the cited output sizing controls unavailable in this project environment |

No explanation for the 1080p output is asserted. The measured receiver buffer dimensions need to be re-collected with an independent metadata-only client against the installed successor, alongside active format and settings at each layer.

## Evidence index

- `docs/gates/GATE_1B_P0_REPORT.md` — prior implementation/build report and limitations.
- `docs/gates/evidence/gate1b-p0/full-working-tree.patch` — complete patch versus repository HEAD, including currently untracked project/source/docs. It includes prior evidence files as part of the current working tree.
- `docs/gates/evidence/gate1b-p0/source-sha256-current.txt` — current hashes of non-ignored untracked project/source/docs files.
- `docs/gates/evidence/gate1b-p0/binary-sha256-current.txt` — built Release and installed executable hashes.
- `docs/gates/evidence/gate1b-p0/PrivacyStateMachineTests.swift`, `privacy-state-tests.log`, `run_privacy_state_tests.sh` — synthetic suite (13 tests, 28 assertions).
- `build-debug-final.log`, `build-release-final.log`, `build-result.txt`, `build-commands.txt`, `build-configuration.txt` — previous Debug/Release build evidence.
- `signature-verification.txt`, `artifact-sha256.txt` — previous candidate signature and artifact evidence.
- `system-state.txt`, `runtime-preflight-current.txt` — retained system state and current hash/version reconciliation.
- `device-formats-metadata-only.log`, `format-high-baseline.log`, `format-720-baseline.log` — metadata-only format evidence.
- `docs/gates/evidence/gate1a/PrivateCam_Gate1A_Closeout_Evidence.zip` — retained prior gate archive.

## Final gate decision

**Gate 1B-P0: FAIL / NOT ACCEPTED. Gate 1B-P1: NOT AUTHORIZED.** The required evidence package is substantially assembled, but runtime privacy behavior of the installed successor has not been demonstrated, and no valid successor binary exists yet. Do not activate the current v4 candidate. Continue only with static hardening, deterministic synthetic race/fault tests, a newly signed version-incremented build, and then return for operator approval before app replacement, activation, or restart.
