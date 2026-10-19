# Aurevix Cam Directive 022C — Camera Service Lifecycle Diagnosis

**Date:** 2026-10-19 (Europe/Berlin)  
**Decision:** **Outcome E — BLOCKED on provider launch evidence.** The active Build 21 bundle is intact and its identifiers match current source, but no evidence shows the CMIO service was launched or that provider/device/stream registration ran. The virtual camera remains absent from AVFoundation.  
**Recommendation:** Preserve the current installation. Prepare an Apple Feedback Assistant report for a possible macOS lifecycle defect, but do not submit it until a service launch attempt is observed and captured. Do not rebuild or activate Build 22.

## Camera Extensions settings

Inspected System Settings → General → Login Items & Extensions → Extensions → Camera Extensions. The native settings pane showed one entry, **Aurevix Cam Camera**, with its toggle **on**. No warning, approval prompt, or second Aurevix entry was visible. No control was changed. A native screenshot was captured in the UI inspection output for this directive; it is not a separate file in the repository.

## Active Build 21 bundle

Active path: `/Library/SystemExtensions/D1DC1038-25FB-4ACC-A5AE-CFB85772FCC0/com.martinaziz.privatecam.CameraExtension.systemextension`.

| Field | Read-only result |
|---|---|
| Bundle identifier | `com.martinaziz.privatecam.CameraExtension` |
| Version | `1.0` / build `21` |
| Executable | `Contents/MacOS/CameraExtension` |
| Executable SHA-256 | `9e071d783002f16feabb97a6d7d82f728169183fc4acf84f09bacac0a725dc56` |
| Code signature | Strict verification passes; Apple Development identity `Apple Development: Bijan Aziz (22ZLM38WTQ)`; Team ID `MPLX762T5G`; CDHash `54fb8fd349754e19fe9037f29f23a9d3dc114ba4` |
| Mach service | `MPLX762T5G.com.martinaziz.privatecam.CameraExtension` |
| CMIO configuration | `Info.plist` has `CMIOExtension.CMIOExtensionMachServiceName`; no `NSExtension` dictionary is present. This matches the CMIO extension packaging form in Apple’s camera-extension guidance. |
| Signed entitlements | App sandbox; camera access; App Group `MPLX762T5G.com.martinaziz.privatecam`; `get-task-allow=true`. No host-only system-extension-install entitlement in the extension. |
| Device/stream constants in executable | `strings` finds device ID `76A10B58-2C45-4B8C-BE2A-0D6F1C286101`, stream ID `76A10B58-2C45-4B8C-BE2A-0D6F1C286102`, and Team-prefixed App Group. This verifies embedded identity strings, not successful runtime registration. |
| System state | `systemextensionsctl list`: build 21 `activated enabled`; builds 19 and 20 `terminated waiting to uninstall on reboot`. |
| Operating system | macOS `27.0.1`, build `26A434`. |

The active extension bundle has only its expected `Info.plist`, executable, and code-signature resource files. Its Mach service name and compiled device/stream identifiers match the current Build 21 source values. No exact Build 21 containing host app or source-linked signed manifest was located, so the origin commit and pairing with a host remain unknown.

## Provider launch and registration evidence

The source entry point calls `CMIOExtensionProvider.startService(provider:)` after constructing the provider source. The current source attempts `device.addStream` and `provider.addDevice`, with error logging. The installed binary contains matching identifier strings and log message templates for device initialization and stream lifecycle.

The provider executable was absent from process inventory before and after the watch. A focused unified-log query for `CameraExtension`, its Mach service, privatecam subsystem, sysextd and launchd showed extension database state and policy/CDHash lookups, but no service launch attempt, rejection, provider startup, registration result, crash, or unexpected exit. No matching CameraExtension crash report was found in DiagnosticReports; one older unrelated PrivateCam CPU resource diagnostic exists.

**Important lifecycle distinction:** an inactive provider process is not itself evidence of a crash. Apple describes CMIO registration assistance as launching the provider by its `CMIOExtensionMachServiceName` when the service is needed; `startService(provider:)` is the extension’s bootstrap call. Metadata discovery can return an inventory without proving that a provider launch occurred. This diagnostic did not explicitly start the dormant provider, request extension activation, create a capture session, or stream frames. Therefore provider construction, `startService`, device registration, and stream registration remain unconfirmed.

## AVFoundation timeline

A read-only Swift watcher enumerated `.builtInWideAngleCamera` and `.external`, looked up the expected ID, and observed `AVCaptureDevice.wasConnectedNotification` / `wasDisconnectedNotification` for 60 seconds. It did not construct an `AVCaptureSession` or read frames.

| Elapsed | Expected Aurevix ID | Inventory | Notifications |
|---:|---|---|---|
| 0 s | Absent | MacBook Pro Camera (`6C707041-05AC-0010-0008-000000000001`, connected); Martin’s iPhone 16 Pro Max Camera (`94585093-7281-45D3-A9A7-24AC00000001`, connected) | None |
| 10 s | Absent | Same two devices | None |
| 20 s | Absent | Same two devices | None |
| 30 s | Absent | Same two devices | None |
| 40 s | Absent | Same two devices | None |
| 50 s | Absent | Same two devices | None |
| 60 s | Absent | Same two devices | None |

There was no observed discovery change and no camera connection/disconnection event. The host’s existing metadata-only discovery log similarly reported one external camera and no Aurevix match. This is a continued absence from AVFoundation, not proof of where registration failed.

## macOS lifecycle report comparison

The [Apple Developer Forums report](https://developer.apple.com/forums/thread/756234) describes a CMIO camera extension that remained `[activated enabled]` after replacement while its daemon did not run; the author reported needing a reboot. The machine here also has an active enabled camera extension, no provider process during inspection, an undiscoverable virtual device, and older versions 19/20 pending reboot removal. Those are similar symptoms, but this record does not prove the same cause: no launch rejection or provider exit was observed, and no explicit provider start was attempted.

Apple DTS’s response says to file a bug for this class of behavior on modern macOS 26 systems and attach a sysdiagnose collected shortly after reproduction. This Mac reports macOS 27.0.1. The comparison justifies preparing a Feedback Assistant report; it does not justify asserting an OS defect yet. No sysdiagnose was collected because it can include sensitive system information and was not authorized.

**Prepared report text (not submitted):**

> On macOS 27.0.1 (26A434), Core Media I/O camera extension `com.martinaziz.privatecam.CameraExtension`, Team `MPLX762T5G`, version `1.0/21`, reports `[activated enabled]` in `systemextensionsctl list` and is enabled in Camera Extensions settings. Its Mach service is `MPLX762T5G.com.martinaziz.privatecam.CameraExtension`. A metadata-only AVFoundation inventory at seven points over 60 seconds found built-in camera `6C707041-05AC-0010-0008-000000000001` and external Continuity Camera `94585093-7281-45D3-A9A7-24AC00000001`; expected virtual camera `76A10B58-2C45-4B8C-BE2A-0D6F1C286101` was absent at every sample. No camera device notifications occurred. The provider process was absent. Unified logs showed extension state and CDHash queries but no service launch, provider startup, registration, rejection, or termination records. Builds 19 and 20 remain terminated pending uninstall on reboot. The installed host app is `1.0/14`; its embedded extension is build 14. We have not explicitly started the provider, captured frames, activated an extension, or rebooted. Please advise how to capture service-launch diagnostics and whether this active-but-undiscoverable state matches a known CMIO service lifecycle defect. A sysdiagnose can be supplied after operator approval.

## Offline Ready-state correction

Added a typed `CameraOperationalState` and wired the Studio badge to it. It reports Discovering camera until a discovery snapshot completes; Camera unavailable unless the exact configured device ID is present; Camera ready after a matching discovery; Preview starting while a start attempt is active; Preview running only when the preview runs and the extension reports active processing; Processing unavailable while a preview runs without that confirmation; and Camera error after all bounded preview retries fail. Selecting a preset does not affect operational state. Discovery completion is set only after the host takes an AVFoundation inventory snapshot.

Changes are limited to `PrivateCam/CameraOperationalState.swift`, the status badge/controller wiring, Xcode source membership, and `Tests/CameraOperationalStateTests.swift`. The extension source and installed Build 14 application were not changed. All 12 deterministic state checks passed, covering initial/empty discovery, unrelated external device, matching device, disconnect/reconnect, stale discovery, preview starting/running, processing unavailable, and preview failure. An unsigned Debug Xcode build completed successfully in `/tmp/aurevix022b/DerivedData`; the app was not launched or installed.

## Version provenance and recovery

The running host remains `/Applications/PrivateCam.app`, build 14, with embedded extension 14. The active system extension remains build 21. Current working-tree source configures build 21, but it has many pre-existing modifications and no complete signed Build 21 host bundle or linked source/signing manifest was found. Consequently, no exact host-only recovery candidate can be identified safely from available artifacts.

**Recommended next action:** keep the current application, extension, settings and saved user data intact. If the operator wants to establish whether this is the macOS lifecycle issue described by DTS, authorize a narrowly scoped provider service launch attempt with a short unified-log capture and a fresh AVFoundation inventory. If the issue reproduces, capture a sysdiagnose only with explicit approval and submit the prepared Feedback Assistant report. Do not install/activate Build 22, remove pending versions, or reboot as part of this recovery step. Host reconciliation can follow only after the exact intended signed host artifact is recovered or built from a frozen, reviewed source snapshot.

## Scope and evidence limits

- No app or extension was installed, replaced, removed, activated or deactivated.
- No camera session, physical-camera capture, image/frame access, App Group preference access, personal-photo access or system restart occurred.
- Settings screenshot was captured via native UI and shown in the diagnostic session; it is not saved as a local report attachment.
- The system log store did not contain enough provider-launch data to determine whether Core Media I/O attempted and failed to start the service. No OS failure is confirmed.
- No commit or push was made.

