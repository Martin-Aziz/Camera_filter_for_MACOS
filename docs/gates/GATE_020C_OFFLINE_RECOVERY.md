# Aurevix Cam Directive 020C — Offline Recovery Report

**Date:** 2026-10-19  
**Source base:** `fd17fe858a9d59f98479343ac3478b355c2f1007`  
**Candidate:** Build 17, offline successor to Build 16  
**Decision:** Offline source repair and builds **PASS**. Isolated runtime acceptance remains **BLOCKED**. Skin Refinement visual acceptance is **PARTIAL**.

Build 17 is a distinct development-signed successor. The Build 16 artifact remains in `/tmp/AurevixCam-Directive020B-Build/` and its executable hashes still match the 020B record. No commits or pushes were made. Build 17 was not installed, launched, or activated. The primary Mac's active system extension remains Build 14. No camera, App Group container, or personal background image was accessed.

## 1. Accurate mode failure and repair

The 020B offline benchmark used the 1280×720 NV12 video-range path with `Portrait-CC0.jpg` and failed in Accurate with `segmentation failed: invalid mask dimensions`. The pre-fix source rejected the mask whenever either mask dimension exceeded the frame dimensions.

The same input now reports:

| Field | Measured value |
|---|---|
| Source and expected output | 1280×720, NV12 video-range (`0x34323076`) |
| Y plane | 1280×720, stride 1280 bytes |
| UV plane | 640×360, stride 1280 bytes |
| Vision request | Accurate, revision 1, orientation `.up` |
| Vision mask | 2016×1512, OneComponent8 (`0x4c303038`), extent origin (0, 0) |
| Frame crop rectangle | Full frame; this entry point has no separate crop input |
| Destination transform | X scale 0.634921, Y scale 0.476190; output extent 1280×720 |

The mask was valid; Accurate simply returned a mask larger than its source. The implementation now normalizes a mask's Core Image origin, maps its complete extent to the destination extent, and crops to output bounds. It accepts model-grid masks with different aspect ratios (Fast and Balanced return 256×192 and 512×384 masks on this 16:9 input) and rejects empty extents or implausible aspect bounds. Core Image keeps this as a GPU image graph; the integrated path adds no intermediate BGRA conversion or CPU pixel copy. The existing neutral-frame fallback remains in use for invalid or unavailable masks.

The failure record is in [the 020B benchmark log](evidence/gate020b/logs/offline-benchmark.log). The repaired run and instrumented plane/mask/transform details are in [accurate-repro-after.log](../../artifacts/aurevix-cam-directive-020c/logs/accurate-repro-after.log) and [segmentation-benchmark.log](../../artifacts/aurevix-cam-directive-020c/logs/segmentation-benchmark.log).

### Pixel format and dimension matrix

| Input | Qualities | Result |
|---|---|---|
| NV12 video-range, 640×480 | Fast, Balanced, Accurate | PASS; output dimensions/format preserved; no fallback |
| NV12 video-range, 1280×720 | Fast, Balanced, Accurate | PASS; output dimensions/format preserved; no fallback |
| NV12 video-range, 1920×1080 | Fast, Balanced, Accurate | PASS; output dimensions/format preserved; no fallback |
| NV12 video-range, portrait 480×640 | Fast, Balanced, Accurate | PASS; output dimensions/format preserved; no fallback |
| NV12 full-range, all four dimensions above | Fast, Balanced, Accurate | PASS; output dimensions/format preserved; no fallback |
| BGRA, 640×480 | Fast, Balanced, Accurate | PASS; output format preserved; no fallback |
| Empty, implausibly shaped, unavailable, or injected malformed mask | Safe fallback / geometry helper | PASS; neutral output, never the source buffer |
| Repeated and changing dimensions on one Accurate processor | 640×480 → 1280×720 → 640×480 → 1920×1080 → 480×640 | PASS; no fallback |

The tests check NV12 plane dimensions and stride, full/video range, BGRA, unchanged output dimensions, reduced and oversized masks, nonzero mask origins, malformed geometry, no-mask behavior, and diagnostic fields. The complete test output is in [segmentation-tests.log](../../artifacts/aurevix-cam-directive-020c/logs/segmentation-tests.log).

## 2. App Group signing and provisioning audit

The host and extension source entitlements both resolve to **`MPLX762T5G.com.martinaziz.privatecam`**. This is the macOS Team-ID-prefixed format, not a `group.`-prefixed registered group. The Debug and Release signed host and extension contain the same group value and are signed by Team `MPLX762T5G`.

Apple documents that a macOS Team-ID-prefixed App Group does not need a provisioning-profile App Group entry or separate Developer website registration; the system matches its prefix to the signing team's ID. Therefore, the absence of `com.apple.security.application-groups` from the host profile is **not a missing group authorization** for this identifier format. See [Apple's macOS App Group container guidance](https://developer.apple.com/documentation/xcode/accessing-app-group-containers) and [App Groups configuration](https://developer.apple.com/documentation/xcode/configuring-app-groups).

| Item | Audit result |
|---|---|
| Host bundle ID | `com.martinaziz.privatecam` |
| Extension bundle ID | `com.martinaziz.privatecam.CameraExtension` |
| Team ID | `MPLX762T5G` on both signed products |
| Signed App Group entitlement | Same Team-ID-prefixed value in host and extension, Debug and Release |
| Host profile | Mac Team Provisioning Profile for the host ID; profile application identifier matches the host |
| Host profile group entry | Absent; valid for the macOS Team-ID-prefixed group format above |
| Host profile devices | One provisioned device; device-restricted development profile |
| Extension profile | No separate embedded profile; extension is embedded and signed inside the host |
| Signing certificate | Apple Development, Debug and Release; not a Developer ID distribution signature |
| Strict signature validation | PASS for host app and extension in Debug and Release |
| Effective runtime entitlement validation | NOT VERIFIED; no host process was launched and no protected container was accessed |

The existing device-restricted profile is not evidence of compatibility with another Mac. Before a test-Mac install, add that Mac as a development device in the Apple Developer account and refresh/download a Mac development profile for the host App ID (or let Xcode's automatic signing create the compatible profile), then rebuild and re-audit. The Team-ID-prefixed App Group itself does not need profile registration. No test Mac is available in the current environment; the primary Mac is excluded. The signed entitlements and profile summary are in [signing-audit.txt](../../artifacts/aurevix-cam-directive-020c/logs/signing-audit.txt), with entitlement plist captures beside it. No signing private keys, certificates, or provisioning secrets were exported.

## 3. Facial fixture provenance

All four fixtures are synthetic adult portraits generated on 2026-10-19, without reference photographs or real-person likeness targets. Their generated output is owned by the user under the [OpenAI Terms of Use](https://openai.com/policies/terms-of-use/). No consented real-person media or private photographs were used. Vision detected one face in each 900×822 audit image before processing.

| Fixture | Varied condition | SHA-256 |
|---|---|---|
| `SkinTest-medium-brown.png` | Medium-brown complexion; soft side-window light | `fa2e4813aac9644d6e5352dff6bacb755bc739ccb103baca8ef46ba033f8adb1` |
| `SkinTest-light-textured.png` | Light, freckled complexion; warm indoor light and bright background | `51e59ae6d52e8112a8145a9035be6f8b30af52de37a2d1cf74338172371f2ac1` |
| `SkinTest-deep-lowkey.png` | Deep dark-brown complexion; mixed light/dark background | `725a7eb04621b2166684c2df4413916ad71b44003a8640bdf1a0926c1d098eee` |
| `SkinTest-light-medium.png` | Light-medium complexion; overcast light and pale background | `81c8a7009d559e076c2ec5683574091281fddb40f049643c5f4b32258382eb70` |

The complete provenance notes are in [Fixtures/README.md](../../Prototype/Segmentation/Tests/PrivateCamSegmentationTests/Fixtures/README.md). The previous `Portrait-Reference.jpg` has unknown provenance and is no longer used by Skin Refinement tests.

## 4. Skin Refinement quality

The audit exercised the candidate's `NaturalSkinRetouch.apply` implementation directly and the integrated NV12 `BackgroundReplacementProcessor` with blur background treatment. It saved original/Off, Subtle, Refined, and Custom 0.10, 0.20, and 0.40 outputs. The comparison sheets contain those six outputs in that order after the source, at native resolution; paired face-detail sheets zoom the face, hairline, cheeks, forehead, eyes, brows, and lips. Example evidence: [medium-brown face detail](../../artifacts/aurevix-cam-directive-020c/skin/SkinTest-medium-brown-face-detail-comparison.png), [light textured face detail](../../artifacts/aurevix-cam-directive-020c/skin/SkinTest-light-textured-face-detail-comparison.png), [deep complexion face detail](../../artifacts/aurevix-cam-directive-020c/skin/SkinTest-deep-lowkey-face-detail-comparison.png), and [light-medium face detail](../../artifacts/aurevix-cam-directive-020c/skin/SkinTest-light-medium-face-detail-comparison.png).

Automated comparison reports 8-bit RGB mean absolute difference within the Vision face bounding box, and outside that box. The signed mean is the average per-channel output-minus-source delta. Values average the four fixtures; lower values mean smaller changes. Outside-face includes hair and other pixels within the face bounding rectangle and is not a semantic skin/background mask.

| Setting | Face MAE (0–255) | Outside-face-box MAE | Face signed mean (0–255) | Assessment |
|---|---:|---:|---:|---|
| Off | 0.000 | 0.000 | 0.000 | Identity; PASS |
| Subtle (0.16) | 0.005 | 0.000 | 0.004 | Extremely mild; modest visible improvement not established; PARTIAL |
| Refined (0.30) | 0.090 | 0.003 | 0.025 | Mild and natural in close comparison; texture and details retained |
| Custom 0.10 | 0.000 | 0.000 | 0.000 | No measurable 8-bit change on these fixtures |
| Custom 0.20 | 0.016 | 0.001 | 0.009 | Very mild |
| Custom 0.40 | 0.229 | 0.006 | 0.044 | Most visible setting; texture remains visible in reviewed crops |

The implementation changes pixels within the detected face contour, excludes eye, eyebrow, lip, and nose landmark regions from the smoothing mask, and does not warp or resize the still image. Mean color shifts are small, and the reviewed face crops retain pores/freckles, eyebrows, eyes, hair, and lip edges without plastic-looking blur. The no-face identity case and a two-face synthetic composition pass unit tests. The small radius increase from `0.8 + strength × 2.5` to `0.8 + strength × 6.0` was retained: it raises the Subtle and Refined effect slightly while preserving visible texture, but does not make Subtle clearly apparent at normal viewing size.

The comparisons received an assistant visual review; **a human reviewer has not signed off**. Thus the requested human visual-quality verification remains NOT VERIFIED. No moving footage was used, so tracking stability, flicker, and temporal facial artifacts are also NOT VERIFIED. A soft subject-edge halo is visible in the integrated blurred-background output at Off and retouched settings alike; it is attributable to the existing segmentation/compositing path, not Skin Refinement, but remains a combined-pipeline visual issue to review on the isolated Mac. Raw outputs, comparison sheets, and pixel/timing metrics are in [the skin evidence directory](../../artifacts/aurevix-cam-directive-020c/skin).

## 5. Offline processing performance

Measurements ran on the primary build Mac only as an offline development host: MacBook Pro `Mac16,8`, Apple M4 Pro, arm64, 24 GB RAM; macOS 27.0.1 (26A434); Xcode 27.1. No live camera or CMIO client was used. Segmentation benchmark source was the CC0 portrait resized/cropped to 1280×720 and converted to NV12 video-range; background treatment was Gaussian blur, mask feather 1.1. Each quality had three warm-up iterations and 20 measured iterations. The table is integrated-buffer processing time per frame in milliseconds.

| Quality | Dimensions / format | n | p50 ms | p95 ms | Max ms | Fallbacks |
|---|---|---:|---:|---:|---:|---:|
| Fast | 1280×720 NV12 video-range | 20 | 3.467 | 3.654 | 3.657 | 0 |
| Balanced | 1280×720 NV12 video-range | 20 | 9.550 | 10.151 | 10.617 | 0 |
| Accurate | 1280×720 NV12 video-range | 20 | 31.505 | 32.657 | 32.725 | 0 |

Skin intensity timings used 640×480 NV12 video-range, Gaussian-blur background treatment, four synthetic portraits, one warm-up and eight measured iterations per fixture and setting (32 measured frames per setting):

| Skin setting | n | p50 ms | p95 ms | Max ms |
|---|---:|---:|---:|---:|
| Off | 32 | 3.607 | 4.660 | 5.096 |
| Subtle | 32 | 8.140 | 9.360 | 11.726 |
| Refined | 32 | 7.353 | 8.581 | 10.297 |
| Custom 0.10 | 32 | 7.461 | 9.941 | 10.867 |
| Custom 0.20 | 32 | 7.786 | 8.789 | 9.240 |
| Custom 0.40 | 32 | 7.380 | 8.684 | 9.401 |

The maxima/p95 values are measurements from local per-frame runs and vary with host scheduling. These timings are not delivered FPS, frame age, capture-to-output latency, CPU utilization, or thermal results. A bounded output-pool-pressure test passes, but memory growth was not profiled over a long run. Raw measurements are [integrated-processing-benchmark.csv](../../artifacts/aurevix-cam-directive-020c/benchmark/integrated-processing-benchmark.csv), [skin-quality-metrics.csv](../../artifacts/aurevix-cam-directive-020c/skin/skin-quality-metrics.csv), and [skin-processing-samples.csv](../../artifacts/aurevix-cam-directive-020c/skin/skin-processing-samples.csv).

## 6. Build, regression, and candidate integrity

Build 17 uses marketing version 1.0 and build number 17 for host and extension in Debug and Release. It is based on the Build 16 source commit with the changes documented here; it has Apple Development signatures and is not a distribution-signed production artifact.

- Debug build: **PASS** — [xcodebuild-debug.log](../../artifacts/aurevix-cam-directive-020c/logs/xcodebuild-debug.log)
- Release build: **PASS** — [xcodebuild-release.log](../../artifacts/aurevix-cam-directive-020c/logs/xcodebuild-release.log)
- Segmentation suite: **PASS**, 19 tests, 0 failures — [segmentation-tests.log](../../artifacts/aurevix-cam-directive-020c/logs/segmentation-tests.log)
- Privacy/publication-policy suite: **PASS**, 43 assertions, camera not started and no images saved — [privacy-policy-tests.log](../../artifacts/aurevix-cam-directive-020c/logs/privacy-policy-tests.log)
- Release privacy safe-path/static checks: **PASS** — [release-safe-path.log](../../artifacts/aurevix-cam-directive-020c/logs/release-safe-path.log)
- Strict code signature and identifiers: **PASS** — both bundles in both configurations; see [signing-audit.txt](../../artifacts/aurevix-cam-directive-020c/logs/signing-audit.txt)
- Imported-photo composition, invalid-photo fallback, and photo-cache tests: **PASS** in the segmentation suite; preference/photo migration assertions pass in the privacy suite.
- Primary extension inventory: **PASS / unchanged**, `com.martinaziz.privatecam.CameraExtension` `1.0/14` remains enabled and active — [active-extension-state.txt](../../artifacts/aurevix-cam-directive-020c/logs/active-extension-state.txt).

Release executable hashes are in [build17-executable-sha256.txt](../../artifacts/aurevix-cam-directive-020c/logs/build17-executable-sha256.txt). Build 16 comparison hashes are preserved in [release-candidate-comparison.txt](../../artifacts/aurevix-cam-directive-020c/logs/release-candidate-comparison.txt). Build 16 remains untouched at its prior artifact path. The privacy-boundary checks did not start a physical camera, inspect private photos, access the installed App Group, alter system security settings, restart macOS, or submit a system-extension activation request.

## 7. Criterion status and recommendation

| Criterion | Status | Evidence / limitation |
|---|---|---|
| Accurate mode failure diagnosed and repaired | **PASS** | Valid 2016×1512 mask now transforms to 1280×720; 20 measured Accurate frames, zero fallback |
| Fast/Balanced/Accurate resolution and pixel-format matrix | **PASS** | Four NV12 sizes in video/full range; BGRA at 640×480; portrait, repeated dimensions, malformed/no-mask fallback |
| Diagnostic metadata excludes camera image contents | **PASS** | Dimensions, formats, plane strides, request, orientation, transform only |
| App Group host/extension signed entitlement match | **PASS** | `MPLX762T5G.com.martinaziz.privatecam` signed by Team `MPLX762T5G` |
| Provisioning for a separate test Mac | **BLOCKED** | No test Mac available; current development profile covers one device |
| Runtime entitlement validation / actual protected-container access | **NOT VERIFIED** | Deliberately not launched or accessed |
| Licensed facial fixture set and face detection | **PASS** | Four synthetic user-owned outputs; one detected face per fixture |
| Skin Refinement naturalness | **PARTIAL** | Refined/custom are mild and preserve detail; Subtle is extremely weak; assistant visual review only |
| Human visual sign-off | **NOT VERIFIED** | No human reviewer sign-off recorded |
| Moving footage / temporal tracking and flicker | **NOT VERIFIED** | No moving test clip used |
| Offline performance measurements | **PASS** | p50/p95/max/sample counts reported; not live delivery measurements |
| Debug/Release builds, privacy regressions, strict signatures | **PASS** | Logs linked above |
| Independent AVFoundation virtual-camera delivery and live FPS | **BLOCKED** | No isolated native test Mac or authorized activation |
| Primary Build 14 and privacy boundary preserved | **PASS** | Read-only inventory still shows Build 14 active; no activation or primary data access |
| Isolated Runtime acceptance | **BLOCKED** | Live camera/client/lifecycle/recovery evidence remains absent |
| Production Deployment acceptance | **NOT VERIFIED** | Separate primary data backup, distribution signing, live acceptance, and recovery risk review remain outstanding |

**Recommendation:** Build 17 is suitable to advance to controlled testing on a separate native Mac after that Mac is added to a compatible development profile and the operator separately approves test-Mac activation. Keep Skin Refinement acceptance partial until a human reviews the comparison set and confirms the Subtle level is adequate. Do not use the primary Mac as a substitute, and do not infer live FPS or recovery behavior from these offline runs.

The offline evidence archive, including the report, raw measurement files, logs, fixture manifest, and comparison images, is [AurevixCam_Directive020C_Offline_Evidence.zip](evidence/gate020c/AurevixCam_Directive020C_Offline_Evidence.zip). Its SHA-256 is in the adjacent `SHA256SUMS.txt`.
