# GATE 020D — Skin quality, mask alignment, and offline acceptance

**Candidate:** Aurevix Cam 1.0/18 (Build 18)  
**Baseline:** preserved signed Aurevix Cam 1.0/17 (Build 17), recovered from Directive 020C evidence  
**Source commit:** `fd17fe858a9d59f98479343ac3478b355c2f1007`  
**Scope:** Offline engineering on synthetic portraits and licensed public test media. No application installation, system-extension activation, physical-camera capture, restart, or private-photo access occurred. Build 14 was not modified.

## Executive status

| Outcome | Result | Evidence |
|---|---|---|
| Algorithm correctness | **PASS** | 20 segmentation tests pass; Off identity, no-face identity, monotonic strengths on four synthetic portraits, multiple faces, shifted extent, neutral handling and existing photo-background path covered. |
| Offline appearance quality | **PARTIAL** | The double attenuation was removed and output changes are measurable, but Subtle remains difficult to distinguish from Off at 320×180 participant scale in the reviewed contact sheets. Human product-owner approval is outstanding. |
| Temporal processing | **PARTIAL** | Reproducible synthetic transformed-frame sequences were processed and logged; they are not captured video and do not validate real temporal tracking or camera behavior. |
| Live virtual-camera integration | **BLOCKED / NOT VERIFIED** | No activation or live camera session was authorized. |

## 1. Diagnosis and change

The earlier implementation attenuated the effect twice: preset strength controlled both the skin mask's gray opacity and the Gaussian blur radius (`0.8 + strength × 6`). Subtle therefore combined a low-opacity mask with only a 1.76-pixel blur. The mask also used a hard contour boundary. The prior MAE measurement included the complete face bounding rectangle, including excluded features and hair, and 8-bit rendering quantized small changes.

The revised `NaturalSkinRetouch` uses a single continuous monotonic mask-opacity mapping, a fixed 1.25-pixel feather at mask boundaries, and Core Image `CINoiseReduction` (`inputNoiseLevel=0.03`, `inputSharpness=0.65`) followed by one blend. Eye, eyebrow, lip, and nose landmark regions remain excluded. Off returns the original `CIImage` before face analysis. This improves actual face-skin changes without whitening, makeup, or geometry changes.

Automated tests verify exact Off identity and strictly increasing measured difference at strengths 0.10, 0.16, 0.20, 0.30 and 0.40 over four generated adult portraits. Those checks establish ordering and bounded behavior; they do not establish aesthetic acceptability. Visual inspection found that Subtle is still hard to distinguish at participant size. Do not promote this appearance to accepted without owner review and, if needed, another tuning iteration.

## 2. Appearance evidence

Four synthetic adult portraits (medium brown, light textured/freckled, deep low-key, and light-medium complexions) were evaluated. Per portrait, outputs include Original, Off, Subtle, Refined, Custom 0.10, 0.20 and 0.40, at native resolution, 1280×720 camera framing, 320×180 participant size, and enlarged facial detail. Skin masks, alpha coverage, face-box MAE, mask-weighted MAE and signed color deltas are in `artifacts/aurevix-cam-directive-020d/skin/skin-quality-metrics.csv`.

Comparison sheets are deliberately labeled for product-owner review. No human signoff is claimed. The images show that Refined is stronger than Subtle, but visual distinction at call size remains weak for some complexions. Metrics are diagnostic only; no arbitrary MAE threshold is used as acceptance.

## 3. Mask alignment and blur halo

Fast, Balanced and Accurate masks were overlaid against the licensed CC0 portrait at 640×480, 1280×720, 480×640 and 1920×1080. `mask-alignment.csv` records source mask extents and independent X/Y transforms. The 16:9 input's Vision model masks are 4:3; the transform maps the complete mask extent independently in X and Y. Review overlays show the subject located within the frame without the prior dimension-rejection fallback. Fast is visibly coarser around arms and torso; hair fringe remains segmentation-limited.

Blur composites for all three modes are provided in `halo-composite-comparison-1280x720.png`. The soft halo at fine hair/shoulder boundaries remains visible. The evidence does not isolate a universal single cause: mask geometry aligns, but segmentation accuracy and feathering contribute to the edge transition. The halo is a segmentation/compositing limitation, not introduced by Skin Refinement. No new fallback or extra production CPU copy was added.

## 4. Synthetic motion

`skin/motion-sequences/synthetic-motion.csv` and labeled frame sheets cover face translation, a geometric head-rotation proxy, temporary face disappearance, two faces, lighting changes, rapid alternating movement and a static repeat control. Each frame is independently face-detected and filtered; this implementation has no temporal state. Face disappearance returns identity input. These deterministic transformed stills are synthetic sequences, not prerecorded captured footage. They cannot validate real video flicker, tracking continuity, or natural head rotation.

## 5. Processing performance

`skin/balanced-processing-performance.csv` covers Balanced segmentation at 640×480, 1280×720 and 1920×1080 for Off/Subtle/Refined, with solid and background-blur treatments. It records segmentation, compositing and summed p50/p95/max for 20 measured iterations after three warm-up iterations, plus fallback counts. No fallback occurred in the recorded matrix. These are offline processing timings; they do not establish delivered FPS or live 30-FPS behavior. Balanced remains the provisional default. Accurate is not represented as a reliable 30-FPS mode.

## 6. Regression, build, and release integrity

- Segmentation suite: **20 tests, 0 failures** (`reports/segmentation-tests.log`). Includes mask extent/origin and dimension handling, invalid masks/fallback, no-face/Off identity, monotonic skin strength, multiple faces, and cached photo background processing.
- Privacy/output boundary suite: **43 assertions passed, 0 failed**, camera not started and images saved=0 (`reports/privacy-policy-tests.log`).
- Build 18 Debug and Release commands and logs are in `build-logs/`.
- Build 17 baseline app copy: `baseline-build17-020c-exact/Aurevix Cam.app`, copied from the prior Directive 020C release-evidence path. Its app and extension are signature-valid and match the previously recorded executable hashes (app `44663e55…`, extension `2784883c…`). This is an isolated recovery artifact, not a copy of the installed Build 14 app.
- Candidate app and embedded extension identifiers remain `com.martinaziz.privatecam` and `com.martinaziz.privatecam.CameraExtension`; versions 1.0/18. Team ID, signing identity, entitlements, App Group, signatures, and executable/package SHA-256 are recorded in the generated manifest after Release verification.
- The Build 18 source successor includes existing prior Build 17 working-tree changes as well as this directive's changes. The source patch and changed-file/hash manifest are included in the evidence directory. No commit or push was made.

## 7. Gates

| Gate | Result | Evidence / limitation |
|---|---|---|
| G1 — Candidate | **PASS** | Build 18 Debug/Release signed app; offline tests and SHA-256 manifest in package. |
| G2 — Recovery | **PARTIAL** | Exact signed Build 17 artifact preserved and verified. Installed Build 14 was not modified; it was not duplicated because this directive authorized source rebuilding and offline work only, and the prior recovery report's Build 14 bundle was not available in the workspace. |
| G3 — User data | **BLOCKED / NOT PERFORMED** | No App Group export or private-photo access was authorized in this directive. No personal data was read or changed. |
| G4 — Compatibility | **PASS** | Build 18 app/extension identifiers, signing, entitlements and version metadata checked against the acceptance manifest. |
| G5 — Recovery feasibility | **PARTIAL** | Build 17 is signed, but no extension replacement was attempted. No guaranteed restart-free rollback is claimed. A separate test Mac remains recommended for runtime validation. |
| G6 — Runtime state | **NOT VERIFIED** | No installed-extension/client/camera state inspection was performed during this offline-only directive. |
| G7 — Evidence | **PASS** | Durable evidence directory contains the signed candidate, baseline artifact, logs, comparisons, overlays, CSV diagnostics, source patch, manifest, and this report. |

## 8. Changed files and artifact map

Source changes are listed in `changed-files.txt`; SHA-256 values are in `source-sha256.txt`. `source.patch` captures tracked source edits; untracked audit/report files are included directly in this evidence package. Build products and test logs are under `artifacts/aurevix-cam-directive-020d/`.

**Recommendation:** Do not begin controlled activation on the working Mac under this directive. The algorithmic changes are correct by regression evidence, but Subtle quality needs product-owner visual review, temporal quality needs real prerecorded licensed video evaluation, and runtime/recovery requirements remain unverified. Use a separate test Mac for any future activation decision.
