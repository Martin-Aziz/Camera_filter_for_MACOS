# PrivateCam — Current State Audit and Technical Handoff

**Audit date:** 2026-10-18
**Disposition:** Gate 1A remains **APPROVED** per CPO direction. Gate 1B-P0 remains **PARTIAL / runtime acceptance not established**. Gate 1B-P1 remains **NOT AUTHORIZED**.
**Scope:** Read-only reconstruction of the current working tree, previously submitted evidence, installed extension, and unactivated P0 candidate. No camera was started; no source or installed system state was changed for this audit.

## Executive summary

PrivateCam currently works as a native macOS virtual-camera diagnostic application: the installed v4 extension is active, serves its existing camera output path, and the approved Gate 1A metadata-only runs demonstrated stable ~30 FPS operation, client lifecycle, and final camera release. The latest supplemental Gate 1A run completed the three 20-second cycles, two-client overlap, and 302-second run. Its measured receiver was 1280x720/420v at the physical producer but 1920x1080/420v at the receiver. That remains a measured negotiation discrepancy, not a demonstrated image-quality or timing failure. Gate 1A is not reopened.

The product is **not a privacy-safe background replacement app**. Installed v4 uses a persisted app-group `privateCamSourceMode` selection and can stream unfiltered physical camera input when an external virtual-camera consumer starts it. The source change for P0 replaces that model with a neutral test-pattern default and a short-lived development lease, but the changed candidate has not been activated or runtime-tested. No segmentation, mask processing, blur, or replacement exists in the source. The current installation’s successful Gate 1A passthrough evidence says nothing about the unactivated P0 authorization code.

A Release policy helper has a real fail-open admission behavior: `CameraPrivacyStateMachine.clientMayStart` returns `true` when the build is not development or the lease is missing/expired. This is an authorization-contract defect and should be corrected before treating the policy as production quality. The evidence does **not** establish that this helper alone lets a Release build send raw frames: the candidate’s physical-capture compile flag is false without `DEBUG`, its output decision rejects Release, and the output starts at the test pattern. Thus classify this as a Release client-admission fail-open and policy ambiguity, not proven Release raw-frame disclosure. The signed Release candidate is unactivated and is not a valid successor because its extension version remains 4.

The shortest credible route is a small, sequential product plan: (1) keep the installed v4 and approved Gate 1A evidence intact; (2) make the Release client-admission/output contract unambiguously fail-closed and simplify/remove development raw passthrough from a shipping candidate; (3) build and sign a version-incremented successor and run the mandated privacy acceptance against that exact signed candidate after operator approval; (4) only then add one narrowly scoped background-replacement pipeline and measure quality/performance on synthetic or explicitly authorized local tests. Do not repeat Gate 1A or create additional process gates absent a concrete decision risk. No install/activation/restart was performed or requested in this audit.

## Current state and provenance

| Item | Observed state | Evidence / meaning |
|---|---|---|
| Working tree | `main` at `5246b59 Initial commit`; product, project, and docs are untracked (`??`). No staged/tracked product patch and no commit/push. | Current `git status --short`; the deliverable ZIP includes the actual source files, not just a diff against an empty commit. |
| Installed app | `/Applications/PrivateCam.app`, bundle `com.martinaziz.privatecam`; app executable SHA-256 `d18e829da6aa0e78fb25966ce201bdeac40a9a5e845084008ff7cc7ca4394c0d`. Strict deep codesign verification passed. | Read-only live verification captured in archive system-state snapshot. |
| Installed extension | `com.martinaziz.privatecam.CameraExtension`, version `1.0/4`, `[activated enabled]`; executable SHA-256 `82445085fdd3a638b43114cfce4ddda690e2b4257e9f127593484f0d39680880`. Strict deep codesign verification passed. | `systemextensionsctl list`, installed plist, codesign. Historical v1/v2/v3 records remain as observed (`uninstalling` or awaiting reboot); none were modified. |
| Current P0 Release candidate | Built at `/tmp/PrivateCam-Gate1B-P0-Derived/Build/Products/Release/PrivateCam.app`; app executable SHA-256 `cce3a7fe12d8fd6954e4e05d6f3ddbfd227a124f626fdcb1bfc3a60f227d69ea`; embedded extension SHA-256 `b988ec578435bbaafcf5f620efe347724b865805e473f18956c72a95167d2f87`. App and extension strict signature verification passed. | Candidate differs from the installed v4 executables, but its extension plist is also version `1.0/4`. It was **not activated** and does not replace or validate the installed binary. |
| Identifiers / signing | App `com.martinaziz.privatecam`; extension `com.martinaziz.privatecam.CameraExtension`; team `MPLX762T5G`. Candidate app claims system-extension install and team-prefixed app group; extension claims camera and matching group entitlements. Signatures use Apple Development signing (not distribution/notarization evidence); the Release build is not evidence of a shippable notarized release. | Existing sanitized `signature-verification.txt`; audit archive omits provisioning profiles and signing secrets. |
| System security | SIP enabled; Gatekeeper assessments enabled. | Read-only `csrutil status`, `spctl --status`; no security bypass. |
| Camera operation for this audit | No camera capture was started. | This task was an audit; the prior operator-authorized metadata-only runs remain the only camera runs referenced. |

### Installed v4 versus current candidate

The installed v4 is the historically working camera-extension binary and the one exercised by the Gate 1A runs. The current source tree and its signed Debug/Release outputs are P0 authorization work. The current candidate has different executable hashes but the same extension bundle identifier and **same extension bundle version 4** as the active installation. It is therefore not a version-incremented successor. It was not installed, activated, or exercised in a running system extension. Do not infer runtime privacy acceptance from v4’s passthrough/reliability measurements, nor from the P0 state-machine test binary.

## Privacy implementation status

### Installed v4 (active)

- The accepted Gate 1A evidence archive contains a separately extracted `v4-source` snapshot. Its `CameraProvider.swift` reads the shared app-group `privateCamSourceMode` at stream start and starts `physicalCamera` when selected; its host writes this preference. The snapshot matches the prior `v4-source-reconciliation.txt` hashes for the listed source files. This is direct source evidence for v4 behavior, alongside the installed v4 binary hash and runtime observations.
- The extension can start from an external camera client without the PrivateCam diagnostic window. Consequently a persisted physical-source selection can initiate unfiltered passthrough without a fresh per-session human confirmation.
- Gate 1A’s explicit consent covered local metadata-only measurement, not a product claim of privacy-safe behavior. It did not inspect/store pixel-buffer contents, and the runs were on installed v4.
- **Product privacy status: not fail-closed and not suitable to present as privacy-safe for calls.**

### Unactivated P0 source/candidate

- The state machine’s normal decision defaults to `.testPattern`. Physical output requires a development build, a fresh 1.5-second lease, matching owner PID and signing ID, exactly one client, and physical availability. Lease heartbeat/expiry, tombstone revocation, generation checks, and a pre-send check are present in source.
- Debug builds define `DEBUG`; Release builds do not. `developmentPhysicalCaptureEnabled` therefore compiles to `false` in Release, and `evaluate` selects the test pattern for Release.
- **Fail-open detail:** `clientMayStart` says `true` for non-development builds and for missing or expired leases. That permits a client to be admitted to the safe stream absent an active dev lease; it is not an authorization result that should be called “fail-closed.” This helper’s `true` does not, by itself, prove raw output: Release’s physical source route is compile-disabled and the state machine rejects the Release decision. The actual signed candidate has not been exercised in CMIO, so this code-level separation is not a runtime privacy proof.
- Authorization/revocation and marker tests are synthetic Swift state-machine/store tests (13 named tests, 28 assertions per the submitted log). They do not run the extension callbacks, CMIO send path, concurrent consumers, pending native buffers, or OS restart/crash lifecycle.
- The P0 candidate does not yet establish a single cross-process revocation/send linearization point. Static generation and lease checks are useful guards but are not evidence that a queued raw frame cannot cross revocation in a live process.
- No segmentation, person mask, background blur, or replacement implementation is present. Test-pattern generation is not background replacement.

## Gate 1A results and present impact

Gate 1A was approved by the CPO; these are accepted historical reliability findings and supplemental evidence. The latest run in `docs/gates/evidence/gate1a/runtime-20261018T111121Z` used explicit operator consent and a metadata-only AVFoundation client. It did not access, save, decode, display, transmit, or attach pixel-buffer contents.

- Three sequential receiver cycles: approximately 20.17–20.63 s each; first frame approximately 410–722 ms; no AVFoundation drops; stable virtual camera identity; final device inventory reports release.
- Two simultaneous clients: receiver A stopped while B continued; physical capture ended after the final client stopped.
- Endurance: 302.049 s; 9,045 receiver frames; 29.946 wall FPS / 29.995 PTS FPS; zero AVFoundation drops; zero PTS gaps over 100 ms; two callback intervals over 50 ms. Producer run summary: 9,046 frames, approximately 29.963 FPS, no allocation failures, no relay replacement during endurance. Final camera release verified.
- Extension resource samples: CPU p50/p95/max 4.7/5.3/57.2%; RSS p50/p95/max 38,016/80,672/118,160 KB. The captured first/last medians do not indicate monotonic growth. GPU/power not verified because `powermetrics` required superuser access; thermal status reported no warning.
- Producer reports 1280×720 `420v`; receiver reports 1920×1080 `420v`. The discrepancy is real; its cause is not established. The directive’s auto-sizing true/false matrix was not completed. Do not speculate, relabel, or make pipeline changes without that measurement.
- One pending relay frame plus one in-flight consumer frame is statically bounded. Five-minute evidence showed zero AVFoundation drop callbacks and zero relay replacements during endurance, but does not expose internal AVFoundation pool pressure or prove downstream `CMSampleBuffer` lifetime. This remains a bounded observability/API-lifetime limitation, not a demonstrated active defect in the accepted run.
- Host `startRunning()` UI-path hitching remains unprofiled; no reproduced impact. TCC denial/interruption/hardware-loss paths were not fault-injected; no settings were reset. These are unverified edge cases, not current Gate 1A blockers.

The prior Gate 1A run is not evidence for P0 privacy transitions because the installed binary remained v4. No further camera testing was performed for this audit.

## Engineering complexity and gate recommendations

The P0 path adds a state machine, shared JSON lease store, revocation tombstone, heartbeat, watchdog, generation cancellation, incoming-client authorization checks, bounded relay accounting, and telemetry. That machinery exists to permit an explicitly confirmed development-only raw passthrough mode. For a shipping privacy product, carrying a second raw-output authorization mode expands the security surface and complicates race proofs. Prefer a smaller invariant: shipping builds emit only a neutral synthetic frame until a completed processing pipeline produces a safe frame; no direct raw passthrough route exists in Release. Keep any development raw mode isolated from the shipping target or remove it.

The test suite provides useful deterministic policy coverage, but repeating variants of source-only tests does not substitute for running the exact signed extension. Avoid duplicating state-machine tests with redundant mocks. Keep a compact unit suite for transitions and deterministic marker ordering, then one exact-binary runtime acceptance suite that exercises the boundaries that unit tests cannot.

Gate recommendation: preserve the already-approved Gate 1A decision; do not rerun endurance, repeat already-complete reliability checks, or reopen that milestone. The next necessary evidence step is a corrected, version-incremented P0 successor plus its controlled privacy runtime acceptance. Gate 1B-P1 remains unauthorized. The CPO should inspect the audit and decide whether to authorize that bounded successor validation; this audit itself does not authorize installation or activation.

## Remaining work for usable background blur/replacement

1. **Make the privacy invariant simple and testable.** Correct client admission semantics and ensure every Release path emits only neutral output until a processed safe frame is available. Remove raw passthrough from the Release product route. Define the revocation boundary and deterministic pending-frame cancellation test.
2. **Prepare a real successor.** Increment extension `CFBundleVersion` above 4, verify matching identifiers/team/entitlements and sign the containing app and extension. Preserve v4 and its artifacts. Install only through `/Applications` plus `OSSystemExtensionRequest` after explicit operator approval. A reboot, if requested by macOS, requires separate approval.
3. **Runtime-verify the exact signed candidate.** Use the directive’s independent metadata-only client and synthetic known-output/fault-injection checks. Include closed host, missing/expired/revoked authorization, crash, TCC denial simulation, processing failure, pending marker race, two clients and final device release. A failing raw-marker check means stop and FAIL.
4. **Implement background replacement as one narrow pipeline.** Add foreground/person segmentation, mask refinement/temporal stability, background blur or replacement composite, and a neutral/black safe frame for absent/initializing/denied/failed processing. None of those capabilities currently exists. Establish quality and frame-time targets before polishing UI.
5. **Measure rather than overbuild.** Characterize 720p/1080p with the prescribed receiver sizing matrix; retain only metrics needed to assess cadence, dropped frames, resource use, and camera release. Profile the UI start path before any threading refactor. Do not add premium Studio, effects, cloud, or unrelated redesign work.
6. **Then deliver a minimal native app.** A small SwiftUI control surface for source/status, explicit camera permission, background choice, and virtual-camera lifecycle is enough. Keep the CMIO extension only if compatibility with third-party conferencing clients is a product requirement; otherwise a native in-app camera experience can be delivered sooner without extension replacement/lifecycle complexity.

## Audit criteria

| Criterion | Status | Finding |
|---|---|---|
| Current tree, installed state, signing and hashes reconstructed | **PASS** | Current `git status`, system extension inventory, executable SHA-256, strict code-sign checks, candidate hashes, identifiers/version and system security state captured. |
| Gate 1A milestone disposition | **PASS** | Kept approved as directed; new measurement evidence is supplemental, not a reopening. |
| Distinguish installed v4 from P0 candidate | **PASS** | Installed v4 hashes differ from unactivated candidate; both report extension version 4. No runtime claim transfers from v4 to candidate. |
| Release authorization behavior characterized | **PARTIAL** | Client-admission helper is fail-open for non-development/missing or stale lease; Release output decision and compile-time raw path are safe by static inspection. No exact-candidate runtime proof. |
| Installed v4 privacy behavior | **FAIL for privacy-safe product claim** | Persisted physical-source setting allows an external client to trigger unfiltered physical passthrough. Gate 1A reliability/metadata tests do not make it safe. |
| P0 privacy runtime | **NOT VERIFIED** | Candidate not activated; no live host/crash/revocation/fault/two-client privacy marker tests. |
| Blur/replacement capability | **NOT IMPLEMENTED** | No segmentation/mask/compositing code in current source. |
| Gate complexity and shortest route | **PASS (audit recommendation)** | Preserve Gate 1A approval; focus next on one corrected P0 successor/runtime proof, then a narrow processing pipeline and minimal native control surface. |
| Camera image retention/transmission in this audit | **PASS** | No camera session or image collection was started. ZIP excludes visual media and nested archive payloads. |

## Evidence package and reproduction

The companion `PRIVATECAM_CURRENT_STATE_AUDIT_EVIDENCE.zip` contains the current project source and Xcode project, privacy test implementation, metadata-only harness source, applicable prior reports and selected sanitized test/build/runtime/signing evidence. It excludes nested ZIPs, `.git`, `.DS_Store`, quarantined/private recordings, image/video files, provisioning profiles, and signing secrets. `MANIFEST.sha256` inventories and hashes every payload member. The ZIP’s own SHA-256 is in `PRIVATECAM_CURRENT_STATE_AUDIT_EVIDENCE.zip.sha256`.

The archive includes `audit-live-system-state.txt`, generated during this read-only audit, with current installed/candidate identifiers, versions, hashes, `systemextensionsctl list`, signature verification outcomes, claimed entitlements, and SIP/Gatekeeper state. It also includes a source snapshot extracted from the accepted Gate 1A evidence archive under `source/v4-snapshot/`; the old ZIP itself is not included. `source/SOURCE_SHA256SUMS.txt` hashes the current working-tree source, while `evidence/v4-source-SHA256SUMS.txt` hashes the extracted v4 snapshot. The top-level `MANIFEST.sha256` hashes every package payload. Build logs and prior runtime logs are historical evidence; they are not claimed as fresh runs performed for this audit.

## Decision requested

CPO review of this audit and evidence package only. No install, activation, reboot, further camera test, source edit, Gate 1B-P1 work, commit, or push was performed. Stop here pending CPO review.
