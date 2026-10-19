# PrivateCam MVP Recovery Sprint — Directive 004

**Date:** 2026-10-18
**Result:** Implementation and offline prototype complete; v5 Debug/Release candidates signed; no installation or activation performed.
**Camera use:** None in this sprint. No physical-camera capture or virtual-camera runtime test was started.

## Executive summary

The safe virtual-camera stream is now independent of the Debug raw-frame lease: normal clients are admitted without a lease, and the Release extension produces the generated neutral test pattern. The raw sample-buffer send is inside a `#if DEBUG` implementation; the Release branch discards any internally received sample and leaves the safe pattern as the only CMIO output. The Debug raw diagnostic remains available behind the existing explicit, short-lived owner lease. Stable device and stream UUIDs and the Core Media I/O implementation were not changed.

Signed Debug and Release builds of app and extension version **1.0/5** succeeded. The Release static-path verifier passed on the signed candidate and checked both the source conditional and the compiled extension for Debug raw-delivery markers. Signed candidate copies are preserved at `artifacts/build-v5/candidates/PrivateCam-v5-Debug.app` and `artifacts/build-v5/candidates/PrivateCam-v5-Release.app`; both copies re-pass strict signature verification. They have not been copied to `/Applications`, activated, or run as system extensions. Installed v4 remains active and unchanged.

An independent Swift package now contains the offline Vision/Core Image prototype. With the CC0 fixture center-cropped to 1280×720, 20 Release-mode iterations after three warmups measured fast segmentation p50/p95 **2.487/3.130 ms** and composite p50/p95 **1.170/1.316 ms**; balanced measured **9.168/9.773 ms** and **1.350/1.532 ms**. Measured per-iteration total p50/p95 was **3.670/4.384 ms** for fast and **10.518/11.304 ms** for balanced. The prototype produces a good blurred-background comparison and also supports a neutral solid background. Missing input and processing/render errors produce a neutral solid frame. It is not connected to the virtual camera; these timings do not establish 30 FPS live performance.

All current source and tests are staged for the first clean local checkpoint; no commit has been made. A local commit still requires operator authorization. Nothing was pushed.

## Privacy design

| Concern | Implemented behavior |
|---|---|
| Virtual-camera connection | `CameraClientAccessPolicy.mayConnectToSafeStream` allows ordinary applications to connect independent of lease state. During an explicitly authorized Debug raw diagnostic, a different client revokes that raw mode and is still admitted to the neutral stream. |
| Normal/default state | Stream start selects the generated neutral test pattern. No lease or stored source-mode preference selects physical output. |
| Debug raw diagnostic | Retains the explicit UI confirmation and short-lived, owner-bound lease for existing diagnostics. The extension validates owner, freshness, client count, and generation before Debug raw sends. |
| Release output | The Release `receivePhysicalFrame` branch only consumes/discards a physical sample; it has no raw `CMIOExtensionStream.send(sampleBuffer, …)` call. The physical capture-start selection is also excluded from the Release `startStreaming` branch. Safe generated frames remain the only output. |
| Future processor states | No processor is integrated yet, so Release continues the neutral pattern through unavailable, initializing, expired, failed, and stopped conditions. The offline component returns a composited safe frame on success and a generated neutral frame on failure; it never returns the original source image. |
| Persistent authorization | `privateCamSourceMode` is no longer read or cleared as a runtime control. Shared preferences are not used as authorization. |

This is a source/build verification, not an activated-extension runtime privacy acceptance. Installed v4 still has its historical unfiltered physical-source behavior and must not be described as privacy-safe. The Debug diagnostic is intentionally not a shipping feature.

## Build, signing, version, and installation state

| Property | Debug candidate | Release candidate |
|---|---|---|
| App bundle ID | `com.martinaziz.privatecam` | `com.martinaziz.privatecam` |
| Extension bundle ID | `com.martinaziz.privatecam.CameraExtension` | `com.martinaziz.privatecam.CameraExtension` |
| App / extension version | `1.0/5` | `1.0/5` |
| Team | `MPLX762T5G` | `MPLX762T5G` |
| Signature | Apple Development; strict verification passed | Apple Development; strict verification passed |
| Provisioning | Embedded Mac Team provisioning profile; team, app ID, system-extension-install entitlement, and app/extension group values checked | Same; profile expires 2027-10-17 |
| Candidate app | `artifacts/build-v5/candidates/PrivateCam-v5-Debug.app` | `artifacts/build-v5/candidates/PrivateCam-v5-Release.app` |

Detailed executable hashes and entitlement/profile checks are in `artifacts/build-v5/signing-summary.txt`. Full build logs are in `artifacts/build-v5/debug-build.log` and `artifacts/build-v5/release-build.log`. The signing identity is a development certificate; these builds are suitable for controlled development activation, not evidence of a notarized customer-distribution release.

At report time `/Applications/PrivateCam.app` and the active system extension remain **v4**. Installed app executable SHA-256 is `d18e829da6aa0e78fb25966ce201bdeac40a9a5e845084008ff7cc7ca4394c0d`; installed extension executable SHA-256 is `82445085fdd3a638b43114cfce4ddda690e2b4257e9f127593484f0d39680880`. SIP is enabled and Gatekeeper assessments are enabled. Current state is preserved in `artifacts/build-v5/current-installed-state.txt`.

### Supported v5 replacement procedure (prepared only)

1. After explicit operator approval, ensure virtual-camera consumers are stopped and preserve the installed v4 app, extension binary, hashes, and current system-extension listing.
2. Place the signed v5 containing app in `/Applications/PrivateCam.app` using the approved operator workflow. Do not alter historical extension records.
3. Launch the v5 app and submit `OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier:queue:)` through `OSSystemExtensionManager.shared`. The containing app must be in an appropriate Applications directory and the extension remains embedded at `Contents/Library/SystemExtensions`.
4. The existing delegate logs the `actionForReplacingExtension` versions and returns `.replace`; macOS may call `requestNeedsUserApproval`, then reports completion or failure through the request delegate. Review any approval prompt and the delegate result.
5. Verify v5 is `[activated enabled]`, app and extension signatures/entitlements match, and installed executable hashes equal this candidate. If macOS says a restart is required, stop and request separate explicit approval before restarting.
6. If recovery is needed, restore the preserved v4 app and request its activation through the same supported mechanism; do not assume replacement can be rolled back without user approval or a restart.

Apple describes versioned replacement through the activation request and `actionForReplacingExtension` callback in [Installing System Extensions and Drivers](https://developer.apple.com/documentation/systemextensions/installing-system-extensions-and-drivers) and [`request(_:actionForReplacingExtension:withExtension:)`](https://developer.apple.com/documentation/systemextensions/ossystemextensionrequestdelegate/request%28_%3Aactionforreplacingextension%3Awithextension%3A%29). No activation request or install was performed.

## Offline segmentation prototype

Source is isolated in `Prototype/Segmentation/` and is not included in the app or extension targets.

- Reuses a `VNGeneratePersonSegmentationRequest` and `CIContext` per processor instance.
- Supports Vision `fast` and `balanced`; Apple describes these as preferring performance or a balance of quality/performance, respectively.
- Composites the person mask over either a neutral solid color or a Gaussian-blurred background. Blur radius is clamped to 0–48.
- Reports Vision segmentation and Core Image compositing times separately.
- Missing source, Vision errors/no mask, or render failure yields a generated neutral frame; the original image is never used as an error fallback.
- Automated prototype tests: **3 passed, 0 failed** (missing-input neutral fallback, licensed portrait blur composite, and solid-background composite).
- Release-mode benchmark: 20 iterations per setting after 3 warmups, source prepared to 1280×720, 0 fallback results. Full CSV: `artifacts/segmentation/processing-benchmark.csv`; summary: `artifacts/segmentation/processing-benchmark-summary.txt`.

| Vision quality | Segmentation p50 / p95 | Composite p50 / p95 | Total p50 / p95 |
|---|---:|---:|---:|
| Fast | 2.487 / 3.130 ms | 1.170 / 1.316 ms | 3.670 / 4.384 ms |
| Balanced | 9.168 / 9.773 ms | 1.350 / 1.532 ms | 10.518 / 11.304 ms |

The fixture is Wikimedia Commons `Portrait (CreativeCommons).jpg`, by Wendelin Jacober, CC0 1.0; see the fixture attribution file and [Commons license/source page](https://commons.wikimedia.org/wiki/File:Portrait_(CreativeCommons).jpg). It is a public model photo, not a camera capture. Before/after output is local in `artifacts/segmentation/before-after-balanced.png` and is provided separately in this conversation. No fixture or result was uploaded.

The benchmark is a still-image prototype measurement on this Mac. It omits camera capture, temporal mask stabilization, concurrency, buffer conversion, extension/CMIO delivery, thermal duration, and receiver behavior. It must not be advertised as real-time background filtering.

## Focused test and build evidence

- `Scripts/test-privacy-policy.sh`: **15 assertions passed** in Release and Debug compiler modes. These prove safe-stream admission is separate from Debug raw policy and that Release policy reports no raw publication capability.
- `swift test --package-path Prototype/Segmentation`: **3 tests passed**.
- `Scripts/verify-release-safe-path.sh`: **PASS** on the signed Release candidate. It checks source preprocessor branches, confirms no sample-buffer send in the Release branch, confirms the Debug-only raw-delivery marker is absent from the Release binary, verifies extension identifier/version, and runs strict signature checks.
- Xcode Debug and Release builds: **BUILD SUCCEEDED**. Xcode emitted only its AppIntents metadata omission and signed-extension strip warnings; neither build failed.
- The native diagnostic interface was not changed; no native UI screenshot applies.
- Build, privacy test, signature, and static-path logs remain locally under ignored `artifacts/build-v5/` and `artifacts/segmentation/` so generated evidence is not committed.
- `artifacts/build-v5/SHA256SUMS.txt` contains 39 verified hashes covering the staged source tree, focused logs, v5 app/extension executables, fixture, benchmark CSV, and before/after PNG.
- No system extension activation, installation, reboot, camera capture, or Gate 1A endurance test occurred.

## Source-control checkpoint

Version-controlled deliverables are the Xcode project, current Swift app/extension sources and entitlements, `README.md`, `.gitignore`, `Scripts/`, `Tests/`, the independent `Prototype/Segmentation/` package including its attributed CC0 test fixture, this focused sprint report, and the accepted gate/audit Markdown reports. Generated `DerivedData`, SwiftPM `.build`, local artifacts, recordings, signing profiles/secrets, `.DS_Store`, and `docs/gates/evidence/` are ignored.

The repository began with source and reports untracked, so the prepared staged diff is the initial source checkpoint against the empty project bootstrap; inspect it with `git diff --cached`. The checkpoint contains the native project/source, tests, scripts, segmentation package and licensed fixture, README, and focused reports. Generated evidence and candidates remain ignored. No commit or push was made. The first local commit awaits explicit operator authorization.

## Remaining limitations and next steps

1. Installed v4 remains active and is not privacy-safe; controlled v5 activation requires explicit operator approval.
2. No runtime test of the exact v5 extension was performed. After approval, validate the installed Release candidate’s safe output and lifecycle before making product privacy claims.
3. The segmentation package has no temporal smoothing or live extension integration. The image prototype is proof of offline replacement only.
4. Integrate the processor into the Release producer only after a separate measured design keeps the output invariant: safe composite when ready; neutral output whenever processing is absent or fails.
5. Revisit format negotiation only if it blocks the MVP; do not reopen Gate 1A. Do not investigate historical extension cleanup entries unless they cause a current failure.

## Decision status

Directive 004 implementation artifacts are ready for CPO review. Installed state is unchanged. The candidate is not installed or active. Await CPO review and operator approval before the v5 replacement step; await separate authorization before the first local commit.
