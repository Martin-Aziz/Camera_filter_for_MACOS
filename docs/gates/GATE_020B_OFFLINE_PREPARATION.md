# Aurevix Cam Directive 020B — Offline Preparation

**Date:** 2026-10-19 (Europe/Berlin)  
**Candidate:** Aurevix Cam 1.0/16  
**Source commit:** `fd17fe858a9d59f98479343ac3478b355c2f1007`  
**Decision:** Isolated runtime acceptance **BLOCKED**. No suitable separate test Mac was discovered. Build 16 was not installed, launched, or activated. The active primary-Mac extension remains Build 14.

The offline evidence bundle is [PrivateCam_Directive020B_Offline_Evidence.zip](evidence/gate020b/PrivateCam_Directive020B_Offline_Evidence.zip); its SHA-256 is in the adjacent `.sha256` file. The expanded logs, measurements and synthetic background comparisons are also available in [evidence/gate020b](evidence/gate020b/).

## Environment discovery

The only available machine is the primary Mac: MacBook Pro `Mac16,8`, Apple M4 Pro, arm64, 24 GB RAM, macOS 27.0.1. There is no separate test Mac connected or otherwise identified in the available local environment. No remote test host is configured. This machine is explicitly excluded as a substitute because Build 14 is installed and active here.

The active system-extension inventory before and after preparation reports `com.martinaziz.privatecam.CameraExtension` version `1.0/14`, enabled and active. The local Build 16 product is under `/tmp/AurevixCam-Directive020B-Build/`; it was not copied to `/Applications`, launched, or sent to `OSSystemExtensionRequest`. No camera capture was started. No App Group container was opened or modified. No personal background photos were read or transferred.

## Candidate build and signing

The local Release build completed successfully. Both app and embedded extension report version `1.0/16` and bundle identifiers `com.martinaziz.privatecam` and `com.martinaziz.privatecam.CameraExtension`. Strict deep signature verification passed for each. Signing Team ID is `MPLX762T5G`. The embedded development profile is device-restricted to exactly one Mac (the current build host), and its entitlement allowlist does not include the App Group entitlement claimed by the signed app. Since no test-Mac UDID is available, profile membership and App Group provisioning compatibility for a test Mac remain **NOT VERIFIED**. Profile details are summarized without device identifiers in [signing-profile-summary.txt](evidence/gate020b/logs/signing-profile-summary.txt).

Executable SHA-256 values are recorded in `evidence/gate020b/logs/candidate-sha256.txt`; signature output is in `evidence/gate020b/logs/signature-verification.log`. The active extension inventory is retained in `evidence/gate020b/logs/active-extension-state.txt`. The exact signed artifact is in the `/tmp` build directory above and is not an installation package for an unverified target.

## Offline checks

- Segmentation and compositing package: **PASS**, 15 tests, 0 failures. Log: [segmentation-tests.log](evidence/gate020b/logs/segmentation-tests.log).
- Privacy/publication policy script: **PASS**, 43 assertions in each Release-policy and Debug-policy run; camera not started, no images saved. Log: [privacy-policy-tests.log](evidence/gate020b/logs/privacy-policy-tests.log).
- Release app and extension build: **PASS**. Log: [xcodebuild-release.log](evidence/gate020b/logs/xcodebuild-release.log).
- Strict code-signature verification: **PASS** for app and extension. See [signature-verification.log](evidence/gate020b/logs/signature-verification.log).
- Background-processing microbenchmark on the documented CC0 still fixture at 1280×720, 20 measured iterations after warmups: Fast integrated NV12 p50/p95 total 4.366/4.848 ms, zero fallbacks; Balanced 11.965/12.507 ms, zero fallbacks. These are local processor timings only; they exclude capture, scheduling, CMIO delivery, receiver age, thermal duration, and camera behavior. See `logs/offline-benchmark.log` and CSVs/images in `benchmark/`.
- Accurate integrated NV12 benchmark: **FAIL**. The processor returned `segmentation failed: invalid mask dimensions`; no accurate integrated output was produced. Still-image Accurate timings do not override this failure. No implementation changes were made in this directive. Full log and generated benchmark artifacts: [offline-benchmark.log](evidence/gate020b/logs/offline-benchmark.log), [benchmark directory](evidence/gate020b/benchmark/).
- Skin-refinement visual rendering on the documented CC0 fixture: **NOT VERIFIED**. The fixture contains no face detectable by Vision; the renderer stopped before writing comparison images. The other local portrait fixture has no license/source attribution in its README and was not used. Log: [skin-fixture-check.log](evidence/gate020b/logs/skin-fixture-check.log).

## Criterion status

| Criterion | Status | Evidence / limit |
|---|---|---|
| Separate macOS test machine discovered and independently baselined | **BLOCKED** | Only the primary Mac was available; it is not a permitted test target. |
| Candidate identifiers, version, signature and executable hashes | **PASS** | Local Release Build 16; strict signature checks pass; values in logs. |
| Signing/provisioning compatibility with intended test Mac | **NOT VERIFIED** | Profile is device-restricted; no target Mac UDID is available to check. |
| Supported activation callback flow / actual active version on test Mac | **BLOCKED** | Activation request was not submitted. Current active inventory is primary Build 14. |
| Independent AVFoundation stream delivery, FPS, dimensions, timestamps, age, latency, drops | **BLOCKED** | No isolated test Mac and no candidate activation. |
| Start/stop, multiple clients, privacy fallback and lifecycle | **BLOCKED** | No candidate runtime session was started. |
| Imported personal backgrounds during streaming and persistence/removal/failure fallback | **BLOCKED** | No test App Group or runtime available; primary photos/container untouched. |
| Skin Refinement Off/Subtle/Refined/Custom visual quality across faces, lighting and movement | **NOT VERIFIED** | Unit coverage exists, but no properly licensed or consented face fixture was available for a visual evaluation; no video was used. |
| Skin/background processing frame continuity and live performance | **BLOCKED** | Offline microbenchmarks do not exercise the extension or AVFoundation client. Accurate NV12 mode also fails offline. |
| Backup/export prototype using the candidate App Group | **BLOCKED** | The only matching App Group belongs to the primary installation and is expressly out of scope. No exporter is present in source; no protected container was accessed. |
| Supported replacement/recovery and restart requirement | **BLOCKED** | No test-Mac activation or rollback was performed. |
| Primary Build 14 and privacy boundary preserved | **PASS** | Active extension remains `1.0/14`; no camera, app-group, physical-camera, restart, activation, or personal-photo operation occurred. |
| Isolated Runtime acceptance | **BLOCKED** | Required live system-extension and independent-client evidence is absent. |
| Production Deployment readiness | **NOT VERIFIED** | Primary data-backup and deployment/recovery risks remain unassessed by design. |

## Next authorized boundary

Before activation work can begin, identify and baseline a separate physical Mac, verify that the candidate's signing and device-restricted profile cover that Mac, and obtain the operator's separate approval to modify that test Mac. Any restart required by macOS needs separate authorization. Until then, treat all delivery, background, skin-quality, lifecycle, export, and recovery runtime claims as unverified. Do not infer production readiness from this offline report.
