# Aurevix Cam

Aurevix Cam is a native macOS virtual camera with local Vision and Core Image background replacement. The CMIO extension captures NV12 frames into a bounded latest-frame relay, generates a person mask, composites the selected solid, blur, Soft Blue, or cached photo background, validates freshness and format, and publishes only processed output or neutral fallback.

## Current source state

The current source candidate is build 21. The recorded installation evidence shows the installed app at build 14 and the active system extension at build 21; the current source candidate is not established as installed. It includes user-imported backgrounds and the App Sandbox read-only entitlement required to open user-selected image files. Camera UUID, stream UUID, bundle identifiers, Team ID, App Group, and existing preference keys remain stable. Opening the app does not start the camera.

Open `PrivateCam.xcodeproj`, select the `PrivateCam` scheme, and build Debug or Release. The scheme and internal product target retain their historical identifier for compatibility.

## Backgrounds

Aurevix Cam provides local Soft Blue, solid-color, and blur treatments. Users can import personal photographs, which are normalized and stored in the shared App Group container for use by the camera extension. Removed bundled photographic scenes are no longer selectable or included in the application.

## Naming

“Aurevix Cam” is a working product name. Aurevix is already used by an unrelated marketing, software, design, and services business. No trademark exclusivity or clearance is claimed. Complete EUIPO and German DPMA similarity and relevant-class searches before community distribution.
