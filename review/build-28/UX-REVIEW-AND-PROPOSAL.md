# Aurevix Cam: UX review (Build 27) and simpler UI proposal

Evidence: `before/` (Build 27) and `after/` (Build 28). File numbers match between the two folders.

## 1. UX review of Build 27

### Confusing or hard to find
- **The status header contradicted itself.** "Camera unavailable / Waiting for virtual camera" and "No external camera is available" showed while the camera was live (`before/01`, `before/13`). This was a startup-timing bug, fixed in Build 28 (`after/13`).
- **Retouch strength is hidden.** The slider only appears under "Custom" (`before/04`). With Subtle or Refined selected there's no visible strength control, which reads as "the slider disappeared".
- **"Start Preview" looks like it turns the camera on.** It only starts a local preview inside Studio. The virtual camera works for Zoom and other apps without it.
- **Background has six rows of near-synonyms:** Off / Neutral, Soft Blue, Natural, Soft and Strong Blur, Solid. Photos sit in a separate collapsed "My Photos (4)" group at the bottom (`before/03`), so it takes scrolling to find out that photos exist at all.
- **Photos are named by ID** (`278DAEF5-E4A7-4BAB`). A trash icon sits right next to every select target.
- **"Add Photo" and "Reset Effects" look like grey labels**, not buttons (`before/14`).
- **Activation is buried** in an unlabeled "…" menu (`before/10`).

### Duplicated between Studio and the popup
- Background choice: a list in Studio, a menu in the popup.
- Beauty preset: a picker in Studio, a menu in the popup (without Custom or strength).
- "Add Photo…" and "Start/Stop Local Preview" appear in both.

### Technical noise a normal user doesn't need
- "Delivered output FPS (receiver): 0.0" and "Unique processed-video FPS: unavailable (no fresh stream statistics)" on the main screen (`before/01`).
- The "Diagnostics" menu: raw processing status, stream health, device unique IDs (`before/16`).
- "Activate Camera Extension" and "Refresh Devices" (`before/10`).
- "Local preview idle", "Virtual camera available/unavailable", "Camera ready/unavailable", each shown as its own status line.

### Clicks to turn on beauty retouch from launch
- **Studio:** 1 click (choose Subtle or Refined). Adjusting strength takes 2: select Custom, then drag the slider.
- **Popup:** 3 clicks (menu bar icon → Beauty → preset), and strength can't be adjusted there.
- Since Build 28, new installs start with Subtle on, so 0 clicks.

## 2. Proposed simpler UI (not built; waiting for your OK)

### Studio: one screen, no scrolling at the default 900×640 size
```
┌──────────────────────────────────────────────────────────────┐
│  Aurevix Cam                         ● Ready for calls    ⚙︎  │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│                 LARGE LIVE PREVIEW (16:9)                    │
│      starts automatically while the window is open;          │
│      shows exactly what Zoom/FaceTime will see               │
│                                                              │
├──────────────────────────────────────────────────────────────┤
│ Background   [ None ] [ Blur ] [ Photo ]                     │
│              Blur:  less ───●─── more                        │
│              Photo: [▣][▣][▣][▣] [ + Add photo… ]            │
├──────────────────────────────────────────────────────────────┤
│ Look your best   [ Off ] [ Natural ] [ Polished ]            │
│                  Strength  ────●──────                       │
├──────────────────────────────────────────────────────────────┤
│ Lighting         [■ On]    Brightness ────●──────            │
└──────────────────────────────────────────────────────────────┘
```
- Three labelled sections with segmented buttons and **always one slider per section** (no "Custom" mode). The slider scales the chosen preset.
- **Photo** shows thumbnails only. Remove a photo by right-click → "Remove", or a small ✕ on hover, not a permanent trash icon. Names are hidden.
- **Blur** keeps one "less–more" slider instead of three blur presets. Soft Blue becomes the first built-in photo.
- **One status pill:** "Ready for calls" (green), "Starting…" (grey) or "Needs setup – click to fix" (orange; opens the setup sheet).
- The preview starts automatically when Studio is visible and stops when it's hidden, so there's no "Start Preview" button.

### Menu bar popup (no preview)
```
┌──────────────────────────────┐
│ Aurevix Cam      ● Ready     │
│ Effects            [  ON  ]  │ ← one switch: all effects on/off
│ Background [None][Blur][Photo]│
│ Look       [Off][Natural][Pol]│
│ Lighting           [  ON  ]  │
│ ──────────────────────────── │
│ Open Aurevix Cam…        ⌘O  │
│ Quit                         │
└──────────────────────────────┘
```

### Settings window (⚙︎ / ⌘,), all advanced options
- **General:** Launch at login, Show in Dock.
- **Background:** custom solid color, blur strength range, manage photos.
- **Camera setup:** extension status in plain words, a "Reinstall camera" button (activation), and Refresh devices.
- **Diagnostics** (collapsed): FPS, stream health and device IDs; "Copy diagnostics" for support.

### Plain-language wording
| Today | Proposed |
|---|---|
| Skin refinement: Off / Subtle / Refined / Custom | Look your best: Off / Natural / Polished + Strength |
| Light & tone | Lighting |
| Background filters, Off / Neutral | Background: None |
| Activate Camera Extension | Camera setup → Reinstall camera |
| Virtual camera available | Ready for calls |

**Target:** launch → choose Blur → choose Natural = 2 clicks, under 10 seconds.
