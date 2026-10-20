# Aurevix Cam Directive 022B — Discovery Diagnosis

**Date:** 2026-10-19 (Europe/Berlin)  
**Decision:** **BLOCKED — current AVFoundation inventory proves the expected device is absent, but Build 21 provider startup and its delivery artifact provenance cannot be established from available evidence.**  
**Scope:** Read-only version, signature, source, UI, log and metadata-only device inspection. No extension activation, app replacement, capture session, frame access, preference access, reboot or extension cleanup was performed.

## Executive finding

The live host is `/Applications/PrivateCam.app`, PID observed as `24764` on the final inventory, build `1.0/14`. The system reports Build 21 as the active enabled camera extension; Builds 19 and 20 remain terminated pending system-managed uninstall on reboot. This is a confirmed host/extension version split.

A standalone AVFoundation probe enumerated two devices: the built-in Mac camera and Martin’s iPhone 16 Pro Max Continuity Camera. It did not enumerate Aurevix Cam, and `AVCaptureDevice(uniqueID:)` returned nil for Aurevix’s configured ID `76A10B58-2C45-4B8C-BE2A-0D6F1C286101`. The Build 14 host independently reported one external camera and no Aurevix match. Thus the intended virtual camera is absent from the current AVFoundation discovery snapshot. The evidence does not show whether Build 21 failed to start/register, exited, or registered with an OS discovery problem.

The misleading Ready state is explained directly by Build 21 source: `statusBadge` falls through to “Ready” whenever `processingStatus` does not contain “processing active” and the controller is neither capturing nor starting. Discovery state is not consulted. Build 14 visibly lacks Skin Refinement controls; source for Build 21 defines Off, Subtle, Refined, Custom and the conditional Custom slider. There is no Build 21 host bundle available here to verify its rendered UI.

## 1. Installed and running inventory

| Item | Exact path / identity | Version and evidence |
|---|---|---|
| Running host | `/Applications/PrivateCam.app/Contents/MacOS/Aurevix Cam`; PID `24764` at final process listing | App Info.plist: `1.0/14`; bundle ID `com.martinaziz.privatecam`. Executable SHA-256 `6e64463639f6d0373478e451f99cfbd781142abd3e2476da6b2aa8d304b96c5c`. |
| Installed host signature | `/Applications/PrivateCam.app` | `codesign --verify --deep --strict`: valid. Apple Development identity `Apple Development: Bijan Aziz (22ZLM38WTQ)`, Team ID `MPLX762T5G`. |
| Host embedded extension | `/Applications/PrivateCam.app/Contents/Library/SystemExtensions/com.martinaziz.privatecam.CameraExtension.systemextension` | Build 14, matching the installed host; this is not the active Build 21 bundle. |
| Active extension | `/Library/SystemExtensions/D1DC1038-25FB-4ACC-A5AE-CFB85772FCC0/com.martinaziz.privatecam.CameraExtension.systemextension` | `systemextensionsctl list`: `com.martinaziz.privatecam.CameraExtension (1.0/21) [activated enabled]`; Team `MPLX762T5G`. Info.plist ID matches. Executable SHA-256 `9e071d783002f16feabb97a6d7d82f728169183fc4acf84f09bacac0a725dc56`. Strict signature verification: valid. |
| Build 19 | `/Library/SystemExtensions/FE257DDA-CB66-4E5C-BBFC-241E3C72B6A1/com.martinaziz.privatecam.CameraExtension.systemextension` | `1.0/19`, terminated waiting to uninstall on reboot. |
| Build 20 | `/Library/SystemExtensions/AD6CBBE0-B58D-4A80-87C3-DFC10C0ADD78/com.martinaziz.privatecam.CameraExtension.systemextension` | `1.0/20`, terminated waiting to uninstall on reboot. |
| Build 21 source | Current project files, especially `PrivateCam.xcodeproj/project.pbxproj` and `PrivateCam/Camera Extension/Info.plist` | Both host and extension configured `1.0/21`. This is source configuration, not proof of an available signed host artifact. |
| Build 21 candidate app | Not found in `/Applications`, workspace `build/`, `/tmp`, or searched Downloads paths | No complete candidate host bundle or source-linked Build 21 manifest found. |
| Build 16 signed artifact | `build/evidence/PrivateCam-signed-dev.app` | Present, signed Apple Development Team `MPLX762T5G`, but metadata keys `CFBundleShortVersionString` and `CFBundleVersion` are absent; cannot establish its build from that plist alone. Not Build 21 evidence. |
| Build 3 debug products | `build/DerivedData/Build/Products/Debug/` | Present; product extension Info.plist says `1.0/3`. Not a recovery artifact. |

**How Build 21 became active:** not established. Current source contains an explicit menu action that submits `OSSystemExtensionRequest.activationRequest`, but no activation event, installer package, complete Build 21 app bundle, or launch history proving which host supplied Build 21 was found. Since installing an app bundle embeds its extension but does not itself prove activation, the sequence cannot be inferred from current version numbers. Historical gate records describe earlier offline candidates that were not installed; they do not explain the later transition to Build 21.

## 2. Source revision and Build 21 provenance

- Git HEAD: `fd17fe858a9d59f98479343ac3478b355c2f1007` (`Complete Build 16 acceptance recovery`, dated 2026-10-19 11:35:03+02:00).
- The working tree is substantially modified and has numerous untracked files. The Build 21 source and project version 21 edits are part of that mutable tree; HEAD itself is not Build 21 source provenance.
- Build 21 candidate source commit, exact build invocation, signed host bundle path and signature manifest: **not found**.
- The active Build 21 extension is signed by Team `MPLX762T5G`; extracted signature authority is Apple Development `Bijan Aziz (22ZLM38WTQ)`. Exact identity/hash show the installed extension binary but do not identify a source commit.
- The currently installed Build 14 app embeds extension 14, so it cannot be the same bundle from which active extension 21 was embedded. An earlier Build 21 host may have been installed/launched and subsequently replaced, or another delivery workflow may have placed/activated the extension. Both remain hypotheses.

## 3. Host-extension compatibility matrix

| Contract | Build 14 host (installed) | Build 21 extension/source | Assessment |
|---|---|---|---|
| Host / extension bundle IDs | `com.martinaziz.privatecam` / `com.martinaziz.privatecam.CameraExtension` | Same IDs in current source and active installed extension | Match, but bundle ID alone is insufficient. |
| Team ID | `MPLX762T5G` | `MPLX762T5G` | Match. |
| Virtual camera ID | Host source matches stable ID `76A10B58-2C45-4B8C-BE2A-0D6F1C286101` (installed Build 14 binary cannot be source-compared exactly here) | Current extension source uses same ID | Intended identity appears compatible. |
| Stream ID | Not observable from host contract | `76A10B58-2C45-4B8C-BE2A-0D6F1C286102` in current extension source | No host-side stream-ID contract found. |
| Shared processing settings | Build 14 source/historical contract is not independently reconstructed from the installed binary | Current source uses Team-prefixed suite `MPLX762T5G.com.martinaziz.privatecam`; background keys in `CameraPrivacyState.swift`; skin keys `aurevixSkinPreset` and `aurevixSkinIntensity` | Likely aligned for these explicit current-source values, but no authenticated Build 14 schema inventory or Build 21 host artifact exists to complete the comparison. Do not claim full compatibility. |
| Skin filter implementation | Installed Build 14 UI screenshot has no Skin Refinement controls | Current processor reads shared `SkinRefinementConfiguration` and forwards effective intensity into `NaturalSkinRetouch` | Present in current source; not proof of Build 21 runtime behavior or UI/package match. |
| Full bundle/signature pairing | Installed Build 14 host embeds extension 14 | Active extension 21 is separately registered; complete Build 21 host unavailable | Pairing/provenance unverified. |

**Conclusion:** A few explicit contracts match (IDs, Team, settings keys in current source), but a full Build 14 ↔ Build 21 compatibility determination is **inconclusive**. The intended Build 21 host is not available for binary or UI inspection. Do not replace the host based on same bundle identifiers alone.

## 4. Independent AVFoundation device inventory

Read-only Swift probe used `AVCaptureDevice.DiscoverySession` over `.builtInWideAngleCamera`, `.external`, and deprecated `.externalUnknown`, video media type, unspecified position. It did not instantiate a capture session or access frames. On this macOS SDK `.externalUnknown` is deprecated as renamed to `.external`; the two external labels resolve to the same raw type.

| Name | Unique ID | Type | Connected | Formats |
|---|---|---|---|---|
| MacBook Pro Camera | `6C707041-05AC-0010-0008-000000000001` | BuiltInWideAngleCamera | yes | 640×480, 1280×720, 1760×1328, 1328×1760, 1552×1552, 1920×1080, 1080×1920; 420v; 15–30 fps |
| Martin’s iPhone 16 Pro Max Camera | `94585093-7281-45D3-A9A7-24AC00000001` | External | yes | 640×480 (1–30, 1–60), 1280×720 (1–30, 1–60), 1920×1080 (1–30, 1–60), 1920×1440 (1–30, 1–60); 420v |

Expected Aurevix ID: `76A10B58-2C45-4B8C-BE2A-0D6F1C286101`. `AVCaptureDevice(uniqueID:)` result: **nil**. No camera named Aurevix Cam was found.

Classification: **A — virtual camera absent from current AVFoundation inventory**. This excludes B in the observed snapshot (no alternate Aurevix-like device was found), and the host’s same-run count of one external device matches the standalone probe. C is therefore not indicated for the currently inspected Build 14 logic; a Build 21 host-side filtering bug remains untestable. D could not be evaluated over time because no connect/disconnect event occurred during this short observation and no prior discovery snapshot from the same process was available.

## 5. Core Media I/O registration evidence

**Confirmed:** `systemextensionsctl list` reports extension 21 active and enabled. Its installed bundle has a valid strict code signature and the intended bundle identifier/version. Source `PrivateCam/Camera Extension/main.swift` calls `CMIOExtensionProvider.startService(provider: providerSource.provider)` then `CFRunLoopRun()`. Source `CameraProvider.swift` constructs the device, attempts `device.addStream`, constructs the provider, attempts `provider.addDevice`, and logs failures/initialization.

**Not confirmed:** a provider process was not running in process inventory. Existing logs contain a Build 14 host discovery line (`external_count=1`, expected camera unavailable) but no Build 21 `CameraExtension` startup, `startService`, provider add-device, device initialization, stream registration, exception, or exit diagnostics. The fact that extension 21 is active does not show its CMIO provider reached `startService` or successfully registered device/stream. No provider registration result can be concluded from source alone.

**Smallest future diagnostic instrumentation if logs stay unavailable:** add explicit structured startup logs immediately before and after provider construction, `startService`, `device.addStream`, and `provider.addDevice`; include extension bundle version, provider service name, device UUID, stream UUID, returned error domain/code, and termination reason. Keep logs free of frame/image data. Collect a unified-log window around one user-approved metadata-only provider launch, and run the AVFoundation inventory before and after. Do not activate a successor just to add these logs.

## 6. Misleading Ready badge

In `PrivateCam/AppMain.swift`, `statusBadge` returns “Processing active” only when a free-form processing string contains that phrase; otherwise it shows “Privacy fallback” while capturing, “Connecting” while starting, and **“Ready” for every other state**. It does not test `isDeviceAvailable` or discovery completion. The reproduced UI simultaneously reports “Waiting for virtual camera,” a disabled Start Preview button, and one unrelated external camera, yet the badge is Ready. This is a confirmed source-level bug.

Minimal correction proposal: replace string-substring-derived status with a typed operational state owned by the controller; distinguish initial discovery, unavailable, camera-ready, preview-starting/running, processing-unavailable and error. Gate camera-ready on an exact-ID discovery result; gate processing-applied on extension-reported successful processed frames, separately from selected preset. Add deterministic controller/state-machine tests for the seven cases requested. No source edits were made in this diagnostic directive.

## 7. Skin Refinement UI diagnosis

The installed Build 14 app’s live accessibility tree reports an Effects list with Off/Neutral and background presets, then Backgrounds; it has no Skin Refinement heading, segmented controls or intensity slider. The supplied screenshot shows a scrollable pane with controls and clipping consistent with that older UI. This is **outdated host code**, not evidence of a Build 21 view-condition or schema defect.

Current working-tree source defines `.off`, `.subtle`, `.refined`, `.custom`; the SwiftUI panel declares the “SKIN REFINEMENT” heading and picker, and shows the Custom intensity slider when `.custom` is selected. The same source’s camera provider reads the settings and passes effective intensity to the image processor. However, no complete Build 21 host bundle exists here, so the latest intended host’s actual UI and scrolling/layout behavior cannot be verified. Configuration compatibility is explicit at the source level for keys, but end-to-end binary compatibility is unproven.

## 8. Discovery root-cause assessment and recovery option

**Most likely class:** system extension is marked active but the CMIO virtual device is not currently published/discoverable. Confidence: **high that it is absent from AVFoundation now; low on the underlying registration cause**. The record does not support choosing between provider non-launch, provider startup failure, failed device/stream registration, unexpected provider exit, or an OS discovery issue.

**Recommendation: BLOCKED; no installation/recovery action yet.** First recover the exact signed Build 21 containing host bundle and its build/signing provenance, or obtain runtime startup logs for the already active Build 21 extension using existing system diagnostics. Compare embedded extension executable hash/version to the active installed extension, then repeat only metadata enumeration. If Build 21 is absent from its parent host yet active, establish the earlier deployment event before any replacement. If registration failure is confirmed, prepare a minimal source repair and new candidate; do not activate it in this gate. If it publishes the expected ID in an independent probe but the current host omits it, correct only host discovery and test it.

The only currently present full signed host is Build 14 and embeds extension 14. Build 16 signed evidence and Build 3 Debug outputs are not Build 21. No safe host-only recovery package can be recommended until the intended signed host is located and its host/extension contract is verified. Any eventual installation or extension activation requires separate explicit authorization; a reboot requirement requires separate approval as well.

## 9. Evidence and limits

- Native UI before-change evidence: [Build 21-named screenshot supplied in workspace](../../artifacts/directive-022-retry/studio-build21-preview-off.png). It is a screenshot file with UI showing the version split’s symptoms; the file itself does not establish which host binary was running. A fresh no-capture native view was also inspected during this directive and matches the described Build 14 state, but no new screenshot file was written.
- Independent AVFoundation probe: source was created only under `/tmp/aurevix022b/main.swift`; output is transcribed above. Warning about deprecated `.externalUnknown` is expected on this SDK.
- Current active system-extension inventory and signatures were read with `systemextensionsctl list` and `codesign --verify`; no extension management commands were run.
- Host log query yielded the discovery count line only. The preceding broad multi-day query timed out; a focused 15-minute query completed.
- No deterministic tests were added or run. The required test cases belong with the proposed typed operational-state implementation after the diagnosis is reviewed/authorized.
- No personal photos, App Group preferences, camera permissions, camera sessions, frames or recordings were accessed.

