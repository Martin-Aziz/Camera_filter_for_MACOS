# Aurevix Cam

Aurevix Cam is a native macOS virtual camera with local Vision and Core Image background replacement. The CMIO extension captures NV12 frames into a bounded latest-frame relay, generates a person mask, composites the selected solid, blur, Soft Blue, or cached photo background, validates freshness and format, and publishes only processed output or neutral fallback.

## Current source state

The current source is build 24. It includes balanced Vision segmentation, temporally stabilized and slightly contracted mattes, face-local skin refinement, and optional Light & tone controls. Build 23 was confirmed discoverable by AVFoundation after reboot. Camera UUID, stream UUID, bundle identifiers, Team ID, App Group, and established preference keys remain stable. Opening the app does not start camera capture.

Open `PrivateCam.xcodeproj`, select the `PrivateCam` scheme, and build Debug or Release. The scheme and internal product target retain their historical identifier for compatibility.

### Install and activate

Before every installation, run `systemextensionsctl list`. If any older Aurevix Cam extension version is waiting for removal after reboot, stop the install and restart macOS first. After reboot, verify only the intended extension version remains active. Build Release, copy the signed `PrivateCam.app` to `/Applications/Aurevix Cam.app`, and launch that copy; system camera extensions must be activated from the installed app. Use the in-app Activate Camera Extension control if macOS has not activated it, then approve it in System Settings → General → Login Items & Extensions → Camera Extensions if prompted. Confirm the expected version with `systemextensionsctl list`, discover `Aurevix Cam` in AVFoundation, and check that a live processed frame is being published before relying on it in a call app. A listed device may still be publishing neutral fallback frames if physical camera capture has not delivered frames.

## Backgrounds

Aurevix Cam provides local Soft Blue, solid-color, and blur treatments. Users can import personal photographs, which are normalized and stored in the shared App Group container for use by the camera extension. Removed bundled photographic scenes are no longer selectable or included in the application.

## Naming

“Aurevix Cam” is a working product name. Aurevix is already used by an unrelated marketing, software, design, and services business. No trademark exclusivity or clearance is claimed. Complete EUIPO and German DPMA similarity and relevant-class searches before community distribution.
