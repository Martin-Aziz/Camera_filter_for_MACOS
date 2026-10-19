# PrivateCam Gate 1B-P0 Report

**Date:** 2026-10-18
**Result:** PARTIAL — implementation and deterministic privacy tests are complete; the candidate was not activated because Decision 008 prohibits changing historical extension records. No Gate 1B-P1 work was performed.

## Scope and privacy

This work implements the Gate 1B-P0 objectives included in the user’s Decision 008 message. The separately mentioned Directive 003 attachment was not present in the workspace or the accessible Desktop/Downloads file inventory, so this report maps to the explicit objectives in Decision 008. No physical-camera stream was started during this task. No frame pixels were read, displayed, encoded, recorded, or saved by the new tests. The prior accepted Gate 1A evidence was left in place.

## Acceptance status

| Requirement | Status | Evidence / limitation |
|---|---|---|
| Fail-closed camera state machine | **PARTIAL** | New extension source defaults to a generated test pattern; physical output requires a fresh Debug-only lease, matching owner PID and signing ID, one active consumer, and a live camera. Incoming CMIO client identity is checked directly before consulting `streamingClients`, which can lag authorization. Unit tests pass. The candidate is not active, so the real CMIO callback sequence was not exercised. |
| Explicit, revocable development-only physical authorization | **PARTIAL** | Persistent source-mode preference is removed and no longer read. The Debug app requires an explicit destructive confirmation, writes a 1.5-second lease with a 300 ms heartbeat, revokes it on stop/exit, and the extension returns to the synthetic pattern on timeout, client mismatch, multiple clients, camera denial, or capture failure. A tombstone prevents a racing heartbeat from restoring a revoked lease. Synthetic tests cover the policy and store. App exit/crash behavior has not been exercised against the active extension. |
| 1280×720 producer versus 1920×1080 receiver discrepancy | **PARTIAL** | Metadata-only AVFoundation enumeration in this task measured PrivateCam as one 1280×720 420v format fixed at 30 FPS. Prior accepted metadata-only receiver runs measured 1920×1080 buffers with both High and 1280×720 session presets. The CMIO source in the candidate advertises 1280×720 in code, but a runtime CMIO format log from that candidate is unavailable because it was not activated. The macOS 27 SDK header marks `automaticallyConfiguresOutputBufferDimensions` and `deliversPreviewSizedOutputBuffers` unavailable on macOS; its `videoSettings` width/height guidance is iOS-only. The receiver-side size is not yet reconciled. See `evidence/gate1b-p0/device-formats-metadata-only.log` and the retained prior logs `format-high-baseline.log` / `format-720-baseline.log`. |
| Distinct drop and discontinuity diagnostics | **PARTIAL** | Source now separates `AVCaptureVideoDataOutput.didDrop`, bounded-relay pending-frame replacement, relay lock contention, physical PTS discontinuities, and producer timer lateness. It emits corresponding CMIO discontinuity flags. No runtime statistics from this candidate were collected. |
| Preserve v4 implementation, IDs, and bounded processing | **PASS (source/build)** | Device and stream identifiers remain `76A10B58-2C45-4B8C-BE2A-0D6F1C286101` and `...286102`. No pipeline rewrite was made. Relay remains bounded to one queued pending frame plus its in-flight consumer. Timing sample arrays use bounded 18,000-entry windows. Debug and Release builds succeeded. The signed candidate was not installed. |
| Deterministic synthetic privacy tests | **PASS** | 13 named tests / 28 assertions passed. Cases include default pattern, owner authorization, pre-enumeration incoming-client denial, multiple clients, exit, heartbeat expiry, future heartbeat, stop, revocation, Release denial, signer mismatch, and a revocation-tombstone race. Test output states `physical_images=0 recordings=0`. |
| Focused performance and two-client regression | **PARTIAL** | Synthetic policy covers the two-client fail-closed decision. No real two-client CMIO run or new 30-FPS producer/receiver measurement was made because the candidate was not activated. Prior Gate 1A 5-second receiver measurements are retained as historical baseline only, not represented as this task’s result. |
| Signing and build verification | **PASS (candidate)** | Debug and Release app schemes built successfully. Release app and embedded extension both passed `codesign --verify --deep --strict --verbose=2` (app) and strict extension verification. Profile authorizes `com.apple.developer.system-extension.install`. Signed app and extension claims, team-matched identifiers, profile subset, and embedded bundle path are in `evidence/gate1b-p0/signature-verification.txt`. |
| macOS security protections | **PASS** | `csrutil status` reported SIP enabled; `spctl --status` reported assessments enabled. No bypass was used. |
| Candidate extension activation / real runtime proof | **NOT VERIFIED** | `systemextensionsctl list` still shows v4 (`1.0/4`) active. v3/v2/v1 historical entries were left untouched. The P0 candidate was built under `/tmp/PrivateCam-Gate1B-P0-Derived` and was not copied to `/Applications`, activated, or used to start a stream because doing so would alter the active/historical system-extension state prohibited by Decision 008. |

## Implementation changes

- `PrivateCam/CameraPrivacyState.swift`: added a testable privacy decision state machine and shared lease store. Leases are bound to owner PID/signing ID, expire after 1.5 seconds, and have per-session revocation tombstones. Store URL injection exists only to test the same file semantics against a temporary directory.
- `PrivateCam/CameraController.swift`: removed the persistent raw-source preference path. Safe capture is the default. The Debug-only path creates an explicit lease and heartbeat; stop, launch, terminate, and errors revoke it. Receiver timing samples are bounded.
- `PrivateCam/AppMain.swift`: added lifecycle revocation and a Debug-only confirmation before unfiltered passthrough. No final Studio UI or Gate 1B-P1 effects were added.
- `PrivateCam/Camera Extension/CameraProvider.swift`: physical samples are gated by the fresh lease, the active client set, the requesting client identity, and Debug configuration. A second stream start or any invalidation transitions to the synthetic test pattern and schedules physical-session stop. Physical capture-session references remain on the serial capture-control queue; CMIO ownership/timer state remains serialized on its state queue. Drop reasons and PTS/timer diagnostics are distinct. Timing arrays are bounded.
- `PrivateCam.xcodeproj/project.pbxproj`: includes the shared state machine source in both targets.
- The Debug build configuration explicitly defines `DEBUG` for both targets; Release leaves the condition empty. This was necessary because the project had not previously defined `DEBUG`, which would have omitted the development-only authorization UI and extension path.
- `docs/gates/evidence/gate1a/MetadataOnlyCapture.swift`: removed macOS-unavailable sizing controls; it requests 420v and reports measured buffer dimensions without reading image planes.
- `docs/gates/evidence/gate1a/CameraInventory.swift`: narrowed enumeration to the PrivateCam virtual device and reports advertised formats without starting capture.
- `docs/gates/evidence/gate1b-p0/PrivacyStateMachineTests.swift` and `run_privacy_state_tests.sh`: deterministic synthetic policy/store tests.

The repository’s only commit is `5246b59 Initial commit`; the project source and documentation directories were already untracked at task start. Thus ordinary `git diff HEAD` does not express this source state. A complete source-additions snapshot against the empty initial commit is supplied as `evidence/gate1b-p0/source-additions-from-empty-HEAD.patch`, and SHA-256 values are in `evidence/gate1b-p0/source-sha256.txt`. No commit or push was made.

## Build and test results

Exact commands are preserved in `evidence/gate1b-p0/build-commands.txt`.

- Debug build: **succeeded** (`build-debug-final.log`).
- Release build: **succeeded** (`build-release-final.log`).
- Build-setting verification: `DEBUG` is present in both Debug targets and absent from both Release targets (`build-configuration.txt`).
- Final build process exit status: **0** for Debug and Release (`build-result.txt`).
- Swift metadata harness compile: **succeeded** (`metadata-harness-build.log`). The harness was not run against a camera in this task.
- Harness executable: built for arm64 macOS (`build-result.txt`); not launched or attached to any camera.
- Synthetic state/store suite: **13 tests, 28 assertions, 0 failures**, physical images 0, recordings 0 (`privacy-state-tests.log`).
- Metadata-only device-format discovery: PrivateCam found, connected, idle; 1280×720, 420v, 30.0–30.0 FPS (`device-formats-metadata-only.log`). Discovery did not start a capture session.
- Release signature checks: app and extension valid on disk and satisfy their designated requirements. The signed app claims System Extension install and its team-prefixed app group; the embedded profile authorizes System Extension install. Apple documents that the `<Team ID>.<group>` macOS App Group form does not require a provisioning profile, unlike `group.` identifiers: [Accessing app group containers](https://developer.apple.com/documentation/xcode/accessing-app-group-containers). See sanitized signature evidence file.
- OS state: SIP enabled, Gatekeeper assessments enabled, installed v4 active, old extension records unchanged (`system-state.txt`).

## Runtime evidence not collected

No activation delegate callback, new extension lifecycle log, live AVFoundation frame count, multi-client stream, allocation count, or P0 producer timing summary exists for this candidate. No camera screenshot or video was created. These are deliberate non-results, not inferred passes. The currently active v4 extension is a different binary from the candidate source; old v4 runtime evidence cannot prove the P0 changes.

## Remaining problems / blockers

1. **Runtime update constraint:** testing the P0 CMIO implementation requires activating it, which would replace active v4 and cause macOS to alter the active extension registration. Decision 008 says not to alter historical extension records. This was treated as a stop condition; no extension registry state was changed.
2. **Live two-client and performance proof:** the authorization model is covered synthetically, but active extension behavior, real stream ownership, timer shutdown, and actual 30-FPS delivery remain unverified.
3. **Receiver format:** the virtual device advertises 1280×720 while AVFoundation sample buffers were measured at 1920×1080. macOS exposes no documented AVFoundation output-dimension control used here; further resolution needs either a supported CMIO/AVFoundation consumer configuration or acceptance that AVFoundation scales the receiver buffer.
4. **Actual lease lifecycle:** process-exit, crash timeout, stream-stop, and second-client behavior need a run against the signed P0 extension. Do not treat synthetic tests as an operating-system integration test.
5. **Directive attachment:** the full Directive 003 file was not available locally; this report follows the complete acceptance objectives present in Decision 008.

## Evidence index

- `evidence/gate1b-p0/source-additions-from-empty-HEAD.patch`
- `evidence/gate1b-p0/source-sha256.txt`
- `evidence/gate1b-p0/artifact-sha256.txt`
- `evidence/gate1b-p0/repository-status-after.txt`
- `evidence/gate1b-p0/build-commands.txt`
- `evidence/gate1b-p0/build-debug-final.log`
- `evidence/gate1b-p0/build-release-final.log`
- `evidence/gate1b-p0/build-result.txt`
- `evidence/gate1b-p0/build-configuration.txt`
- `evidence/gate1b-p0/privacy-state-tests.log`
- `evidence/gate1b-p0/metadata-harness-build.log`
- `evidence/gate1b-p0/device-formats-metadata-only.log`
- `evidence/gate1b-p0/signature-verification.txt`
- `evidence/gate1b-p0/system-state.txt`
- Prior format baselines: `evidence/gate1b-p0/format-high-baseline.log`, `format-720-baseline.log`

**Stop point:** Gate 1B-P0 only. Gate 1B-P1 remains unauthorized and unimplemented.

## Apple documentation consulted

- [AVCaptureSession.Preset.hd1280x720](https://developer.apple.com/documentation/avfoundation/avcapturesession/preset/hd1280x720) — preset definition; the receiver sample buffer is still measured separately.
- [AVCaptureVideoDataOutput](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput) — receiver output API; the installed macOS 27 SDK header is the source for the platform-unavailable annotations recorded above.
- [Accessing app group containers](https://developer.apple.com/documentation/xcode/accessing-app-group-containers) — team-prefixed macOS App Group entitlement behavior.
