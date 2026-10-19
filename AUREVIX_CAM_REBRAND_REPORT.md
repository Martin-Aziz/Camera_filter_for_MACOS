# Aurevix Cam — CPO Directive 017 implementation report

Date: 2026-10-18 (Europe/Berlin)

## Status

Source implementation is prepared in signed build 13 and the host app has been restarted from that candidate. The system extension installed on this Mac remains v11 (`1.0/11`, activated and enabled). Build 13 is not installed or activated. The user-visible gallery works in the candidate UI, but the installed v11 extension cannot render the new photo-background mode; live photo switching therefore remains unverified until an authorized successor install.

## Changes

| File/resource | Functional change | Area | Risk / coverage |
|---|---|---|---|
| `PrivateCam/AppMain.swift` | Soft Blue and CC0 scene gallery, import UI, effect/status controls, Aurevix naming and credits; menu icon constrained to 8×8 points (half the previous 16×16 size); local preview status reflects active capture; Studio window disappearance calls `stopCapture`; Quit requests preview stop; About credits include “Developed by Martin.” | UI, preview lifecycle | Closing Studio now stops its own AVCapture client. This should not stop an independent CMIO consumer. Source/build checked; no active-stream close-window test was run in this pass. |
| `PrivateCam/CameraController.swift` | Gallery selection and imports now update published controller state as one selection operation and write a completed configuration snapshot rather than several intermediate property-triggered snapshots. | Effect configuration | Lower chance of an intermediate mixed setting. Covered by configuration tests; the app-group preference store still consists of legacy separate keys. |
| `PrivateCam/CameraPrivacyState.swift` | Added reusable selection transition logic for photo modes and Soft Blue while preserving existing preference key names. | Effect configuration/privacy | Existing 100 ms bound and preference identifiers remain unchanged. Covered by policy tests. |
| `PrivateCam/Assets.xcassets/AurevixMenuMark.imageset/AurevixMenuMark.png` | Replaced the large A-like menu glyph with a compact monochrome camera mark. | UI | Template rendering retains native menu-bar tint. |
| `PrivateCam/Assets.xcassets/AurevixMenuMark.imageset/Contents.json` | Declares template rendering for the monochrome menu mark. | UI | Asset-catalog build verified. |
| `Tests/PrivacyPolicyTests.swift` | Added tests for selecting a packaged photo after an imported image and returning to Soft Blue. | Test | Both DEBUG and Release-safe policy harnesses pass (42 assertions each). |
| `Scripts/verify-release-safe-path.sh` | Updated the expected successor extension build to 13 and resolves the host executable name from Info.plist for hashing. | Build/privacy verification | Static release-safe-path verification passes. |

Other Directive 017 source additions from the earlier implementation remain present: `PrivateCam/Camera Extension/CameraProvider.swift`, `Prototype/Segmentation/Sources/PrivateCamSegmentation/BackgroundReplacementProcessor.swift`, `PrivateCam.xcodeproj/project.pbxproj`, `README.md`, segmentation tests, image asset catalogs, and the CC0 background library/manifest and exports under `Assets/BackgroundLibrary/`. The four source scenes remain Poly Haven CC0 resources. No Pexels, Unsplash, or Teams assets were bundled.

### Exact v11 source-diff limitation

The checkout has no tracked v11 source tree: `git ls-files` contains only the original `README.md`, while current application and extension sources are untracked working files. The preserved v11 installed binary and historical reports are available, but they do not provide an exact source snapshot for a mechanical v11-to-build-13 patch. The table above identifies all changes for this follow-up and the principal Directive 017 source files; it is not represented as a complete byte-for-byte v11 source diff.

## Gallery selection diagnosis

The candidate's photo effects require the extension's `.image` processing mode and packaged image lookup. Build 13 contains this path and its bundle includes the 1280×720 scenes. The active installed extension is `1.0/11`; it predates that path. Thus candidate UI selection can persist a photo preset, but the installed processor cannot produce the requested image composite. This is the concrete install boundary behind the reported view-switch problem; a UI-only correction cannot make the installed v11 processor render photo backgrounds. Build 13 has not been installed, per the operator's installation boundary.

The follow-up selection helper prevents the host from writing a chain of partly updated controller states during a card selection. Packaged selections clear any prior imported path; Soft Blue restores its cached gradient treatment. Tests pass for those transitions.

## UI and local preview

The menu-bar image is now a 16×16 template camera mark rather than the large A-shaped logo. The menu preview action is based on capture state. Closing the Studio window now requests cleanup of its local preview session; the independent extension's consumer lifecycle is unchanged. No camera was intentionally activated as an acceptance test.

The candidate app was quit and relaunched from `artifacts/aurevix-cam-directive-017/candidate/Aurevix Cam.app`. It initially showed Preview OFF. During subsequent UI inspection, the app state changed to Preview LIVE and a different selected background; the local preview was stopped immediately. The latest visible UI state showed Preview OFF / local preview idle. No frame or video was saved. This event is not evidence of gallery output quality or camera lifecycle acceptance.

A Studio UI screenshot was inspected in-session; live Dock/Finder/menu-bar screenshots were not saved as report artifacts. The icon size and template pixels were reviewed from the asset itself and the UI build shows the new Studio app icon. The About view content is source-verified; a final live screenshot of that separate window was not captured.

## Tests and verification

- `Scripts/test-privacy-policy.sh`: 42 assertions pass in Release-safe mode and 42 in DEBUG mode; camera started false, zero images saved.
- `swift test --package-path Prototype/Segmentation`: 11 tests pass, including photo cache and malformed-image neutral fallback.
- `xcodebuild` Release build: success, project `PrivateCam`, version `1.0`, build 13.
- `codesign --verify --deep --strict`: app and embedded extension pass. Signing authority: Apple Development `Bijan Aziz (22ZLM38WTQ)`, Team `MPLX762T5G`.
- `Scripts/verify-release-safe-path.sh`: PASS; one serialized publisher send site, processed-only buffer identity validation, effect/generation/age/dimensions/format checks, and 100 ms freshness bound. No raw physical sample send path.
- App executable SHA-256 after the half-size icon update: `a6fdb2cd546f695d7571ba80effd762ded59095e0f9e2396fa2e72b45b069bcd`.
- Embedded extension executable SHA-256: `435d87914417d610cc43e76e2b02a28dae53d0972a174c6cfd00dd315cc1955f`.
- Signed candidate archive with the half-size icon: `artifacts/aurevix-cam-directive-017/AurevixCam-build13-icon-half-signed.zip`, SHA-256 `71d58326eecd0b2ae3a45b73fcd78565978e6df6a94c5baa78a5c9d64771f61c`.

The pre-existing static fixture benchmark remains the only performance comparison: Soft Blue p50/p95/p99 11.750/12.542/13.354 ms; Quiet Office 9.156/9.740/10.957 ms; Gaussian blur 12.405/21.284/21.495 ms. These are synthetic still-frame processing times, not live delivered/unique FPS or temporal-quality evidence.

## Installation and privacy

Installed app remains `/Applications/PrivateCam.app`, v11; active extension remains `com.martinaziz.privatecam.CameraExtension` `1.0/11` `[activated enabled]`. Build 13 is source-built and signed only. No extension activation, replacement, system configuration edit, reboot, commit, or push occurred. Stable camera/stream IDs, bundle identifiers, extension identifier, Team ID, App Group, and existing preference keys were preserved. The privacy-safe processed-output path and neutral fallback remain verified in the signed build.

## Recommendation

Keep v11 installed pending CPO review and explicit approval to install a successor. Build 13 is needed to make the photo gallery render through the camera extension; it is not yet runtime validated, and the source-only selection fixes do not overcome the installed v11 extension's missing image mode. No recommendation to install build 13 is made without its separate controlled runtime validation and operator approval.
