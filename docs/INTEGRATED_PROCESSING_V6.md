# PrivateCam — Integrated Processing v6 Evidence

**Date:** 2026-10-18
**Result:** Synthetic NV12 processor integration and signed v6 candidates prepared. Installed v4 unchanged. No physical-camera session, system-extension activation, installation, or reboot performed.

## Summary

The existing Core Media I/O device and stream identifiers remain unchanged. The extension now uses the reusable `BackgroundReplacementProcessor` on camera `CVPixelBuffer`s in the selected NV12 format. The existing capture callback does only a nonblocking enqueue; the one-pending-frame relay replaces stale pending work while a serial worker runs the reused Vision request and Core Image context. The extension renders into a pooled, format-matched output buffer and sends a new sample buffer with the capture PTS. It never sends the physical capture sample.

Solid color and blur configuration is written from the app to the existing App Group preferences. These values configure effects only and are not treated as authorization. The extension reads the configuration before processing and compares it again at the publication boundary. A change during processing rejects that result; the neutral stream remains available. The UI reports an effect as active only after the extension publishes a processed frame and updates its shared status.

The output boundary checks stream generation, effect configuration, output/capture buffer identity, dimensions, pixel format, timestamp age (0–100 ms), and monotonic PTS immediately before `CMIOExtensionStream.send`. Interruption sets a neutral state and rejects in-flight frames; interruption end resumes processing. Camera unavailability, TCC denial, capture setup/runtime errors, stale frames, processing errors, and output-pool pressure keep or select neutral output. The capture buffer remains held only through the bounded relay and processing call.

## Reusable API and format compatibility

The offline prototype accepted `CGImage` and returned `CGImage`; the extension captures NV12 `CVPixelBuffer`s. The shared `BackgroundReplacementProcessor` now offers both APIs. Its realtime entry point accepts an NV12 source buffer and a `CVPixelBufferPool`, performs Vision directly on the buffer, composites in Core Image, and renders back into the pool’s advertised dimensions and pixel format. It does not construct a per-frame `CGImage` or convert the input to BGRA.

The physical camera selector remains constrained to a 1280×720 30 FPS bi-planar 4:2:0 format. The output stream description uses the selected capture subtype. Synthetic tests confirm a 1280×720 420v input returns a distinct 1280×720 420v result. Camera orientation is unchanged from the existing landscape pipeline. The mask is scaled to the full source extent and composited as the foreground mask; an all-zero mask therefore yields the background, which is privacy-safe though visually unsuccessful.

## Privacy boundary and tests

- Removed the development raw lease, Debug raw publication branch, and their app controls from the active product source. Safe virtual-camera clients remain admitted without an authorization lease.
- Neutral output is sent during stream initialization, camera unavailability, interruption, and whenever no recent processed frame is available. The fallback is a flat solid frame.
- The processing pool is capped at 16 outstanding buffers. Under pool pressure the processor uses a cached, immutable neutral NV12 buffer; it does not return the input buffer.
- A delayed or cancelled processing result is rejected by the generation, effect-configuration, format, identity, and age checks. Capture PTS is preserved; non-monotonic frames are rejected and the neutral producer supplies safe output.
- `swift test --package-path Prototype/Segmentation`: **8 tests passed, 0 failed**. Coverage includes offline composite/fallback, direct NV12 processing, Solid/Blur modes, injected Vision/mask/compositing failures, raw-marker chroma disclosure check, and 16-buffer pool pressure.
- `Scripts/test-privacy-policy.sh`: **15 assertions passed in each of Debug and Release compiler modes**. Includes settings bounds and publication rejection for cancellation, effect change, buffer identity, dimensions, format, malformed/future/over-age timestamps.
- Tests use a locally included CC0 portrait converted into synthetic NV12 test buffers plus generated solid-color marker buffers. No physical camera was started; no camera frame, recording, or preview was captured.

These tests exercise the processor and the pure publication policy. They do not run the CMIO extension as a system extension and do not establish runtime privacy acceptance.

## Synthetic NV12 integrated-buffer benchmark

Release benchmark on arm64 macOS 27.0.1, 1280×720 420v input; three warmups and 20 scored iterations per Vision mode. The integrated-buffer column uses the same `CVPixelBuffer` API called by the extension. It includes segmentation and compositing, but excludes AVCapture scheduling, the CMIO relay/send, client delivery, and camera sensor latency.

| Mode | Segmentation p50 / p95 / p99 ms | Composite p50 / p95 / p99 ms | Total p50 / p95 / p99 ms | Fallbacks |
|---|---:|---:|---:|---:|
| Fast | 2.868 / 6.206 / 6.206 | 1.151 / 2.443 / 2.443 | 4.341 / 7.230 / 7.230 | 0 |
| Balanced | 9.168 / 11.027 / 11.027 | 1.355 / 2.868 / 2.868 | 10.679 / 12.912 / 12.912 | 0 |

The latest suite additionally verifies malformed source dimensions return an advertised-format neutral buffer. The benchmark retains only the last output buffer so it exercises the bounded pool without artificially filling it. P95 and p99 coincide with this 20-sample percentile estimator; treat these as initial measurements, not tail-latency guarantees. Fast is the initial engine default because it has materially more 30 FPS budget. This does not establish a 30 FPS live stream; end-to-end cadence and frame-age must be measured after activation.

Synthetic before/after outputs: `artifacts/segmentation-v6/integrated-before-after-fast.png`, `integrated-before-after-balanced.png`, `integrated-solid-fast.png`, `integrated-solid-balanced.png`. The person-segmentation images derive from the attributed CC0 fixture in `Prototype/Segmentation/Tests/Fixtures`; they are not camera imagery. Visual inspection shows usable background replacement, with mask leakage/soft halos around fine arm/hair edges. No mask refinement or temporal smoothing is included.

## Build, signing, and Release-path verification

Debug and Release Xcode builds both report `BUILD SUCCEEDED`. Both app and embedded extension use bundle IDs `com.martinaziz.privatecam` and `com.martinaziz.privatecam.CameraExtension`, version `1.0/6`, Team ID `MPLX762T5G`, matching App Group and camera entitlements, and strict deep signature verification. Signing is Apple Development with the embedded development provisioning profile; it is not notarized customer-distribution signing.

- Candidate bundles: `artifacts/build-v6/candidates-submission/PrivateCam-v6-Debug.app` and `PrivateCam-v6-Release.app`.
- Executable SHA-256 values, provisioning/profile checks, and entitlement agreement: `artifacts/build-v6/signing-summary.txt`.
- Build logs: `artifacts/build-v6/debug-build.log`, `artifacts/build-v6/release-build.log`.
- Static Release-path check: `artifacts/build-v6/release-safe-path.txt` — PASS. It confirms no direct physical sample send, a processed-sample-only physical route, and pre-send generation/configuration/identity/dimension/format/age checks. It is static inspection of the signed candidate, not runtime testing.

The app’s Solid/Blur picker, color picker, blur slider, camera status, and processor status are connected to the shared configuration and extension status. The native control panel was opened for screenshots with no stream start; no UI action activated the extension or camera. The Solid and Blur panel screenshots are displayed in the CPO review conversation.

## Installed state and replacement

`artifacts/build-v6/installed-state.txt` records the unchanged active v4 extension `[activated enabled]`, installed v4 app/extension hashes, successful installed-signature checks, SIP enabled, and Gatekeeper assessments enabled. Historical system-extension records were not altered. No candidate was copied to `/Applications`.

The v6 candidate is prepared for the same supported replacement flow: preserve the current v4 app/evidence; after operator approval, install the signed v6 containing app under `/Applications`, launch it, and submit `OSSystemExtensionRequest.activationRequest` through `OSSystemExtensionManager`. The existing replacement delegate returns `.replace`; record approval/completion/failure callbacks. If macOS requires a restart, stop for separate explicit approval. Do not manually remove historical records.

## Source-control checkpoint

The existing staged initial checkpoint is preserved. Directive 005 source and report changes are staged alongside it; no commit or push was made. `git diff --cached` is the proposed source checkpoint. Generated `artifacts/`, DerivedData, SwiftPM build output, the benchmark images/CSVs, candidate app bundles, logs, and signing/profile material are excluded by `.gitignore` and should remain uncommitted.

## Runtime verification still required

The exact signed v6 candidate has not been installed or run as a system extension. The following remain unverified: physical-camera permission/TCC behavior, measured CMIO output cadence and PTS gap distribution, actual capture-to-output latency, memory/CPU under a 60-second integrated stream, multi-client lifecycle, interruption recovery on hardware, host termination with external clients, and device release. Live Telegram compatibility and production-ready privacy are not claimed. Fine-edge segmentation quality and temporal stability also require a separately authorized controlled scene. No physical-camera test should begin without explicit operator authorization.
