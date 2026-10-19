# Aurevix Cam

Aurevix Cam is a native macOS virtual camera with local Vision and Core Image background replacement. The CMIO extension captures NV12 frames into a bounded latest-frame relay, generates a person mask, composites the selected solid, blur, Soft Blue, or cached photo background, validates freshness and format, and publishes only processed output or neutral fallback.

## Current source state

The current source and installed app are build 23. The embedded CoreMediaIO camera extension is build 23 and reports activated and enabled. Build 22's extension and older builds 19, 20, and 21 remain terminated while waiting for reboot cleanup. Build 23 adds the menu-bar-only app setting and a compact menu with preview, background, beauty preset, photo import, and Studio controls. It retains build 22's background and camera processing behavior. Camera UUID, stream UUID, bundle identifiers, Team ID, App Group, and existing preference keys remain stable. Opening the app does not start camera capture.

Open `PrivateCam.xcodeproj`, select the `PrivateCam` scheme, and build Debug or Release. The scheme and internal product target retain their historical identifier for compatibility.

## Backgrounds

Aurevix Cam provides local Soft Blue, solid-color, and blur treatments. Users can import personal photographs, which are normalized and stored in the shared App Group container for use by the camera extension. Removed bundled photographic scenes are no longer selectable or included in the application.

## Naming

“Aurevix Cam” is a working product name. Aurevix is already used by an unrelated marketing, software, design, and services business. No trademark exclusivity or clearance is claimed. Complete EUIPO and German DPMA similarity and relevant-class searches before community distribution.
