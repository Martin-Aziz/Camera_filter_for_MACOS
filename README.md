# Aurevix Cam

Aurevix Cam is a native macOS virtual camera with local Vision and Core Image background replacement. The CMIO extension captures NV12 frames into a bounded latest-frame relay, generates a person mask, composites the selected solid, blur, Soft Blue, or cached photo background, validates freshness and format, and publishes only processed output or neutral fallback.

## Current source state

The current source is build 15. It includes user-imported backgrounds and the App Sandbox read-only entitlement required to open user-selected image files. Build 15 has been built and signed as a candidate but has not been installed. The active system extension remains build 14. Camera UUID, stream UUID, bundle identifiers, Team ID, App Group, and existing preference keys remain stable. Opening the app does not start the camera.

Open `PrivateCam.xcodeproj`, select the `PrivateCam` scheme, and build Debug or Release. The scheme and internal product target retain their historical identifier for compatibility.

## Background library

Soft Blue is generated procedurally. Four sample scenes are from Poly Haven and licensed CC0: Beach Sunrise, Quiet Office, Warm Lounge, and Coastal Morning. The project contains source originals and provenance under `Assets/BackgroundLibrary`; the app and extension ship 1280×720 optimized copies, with thumbnails in the host app. The 1920×1080 exports are retained as quality masters. Imported images are normalized for orientation, downsampled to a bounded size, and stored locally in the shared App Group container. Studio shows the current upload as “Your Photo,” keeps it available when switching presets, and sends its local path to the extension for photo compositing.

See `Assets/BackgroundLibrary/manifest.json` and the [Poly Haven license](https://polyhaven.com/license) for source and export hashes and attribution.

## Naming

“Aurevix Cam” is a working product name. Aurevix is already used by an unrelated marketing, software, design, and services business. No trademark exclusivity or clearance is claimed. Complete EUIPO and German DPMA similarity and relevant-class searches before community distribution.
