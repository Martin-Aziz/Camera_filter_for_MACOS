# PrivateCam Gate 1A — Headless Reliability Closeout

**Run date:** 2026-10-18 (UTC in evidence logs)
**Disposition:** **PARTIAL — submitted for CPO review**
**Scope:** CPO Directive 002-C headless physical-camera reliability closeout. No Gate 1B work.

## Result

The signed v4 extension remained installed and unchanged. With the operator's explicit authorization for metadata-only camera access, the independent AVFoundation harness completed three single-client restart cycles, a two-client overlap, and a continuous five-minute capture. It read timing and format metadata only. It did not lock, map, copy, display, encode, save, or record image planes. The final AVFoundation inventory reported the physical camera `inUse=false`; the v4 extension remained active.

The five-minute client received 9,045 frames over 301.979 seconds: 29.952 FPS by wall time and 29.997 FPS by presentation timestamps. AVFoundation reported zero dropped-frame callbacks; the receiver observed zero PTS intervals above 50 ms and seven callback intervals above 50 ms. The extension reported 9,046 physical frames sent, one bounded-relay replacement at startup, zero allocation failures, and a clean stop. This is evidence of reliable timing with one explained producer-side startup drop, not evidence of pixel-content correctness.

The report remains PARTIAL because the consumer negotiated 1920×1080 although the extension configured its physical capture at 1280×720, GPU telemetry was unavailable without superuser privileges, and the product's persisted unfiltered physical-camera mode still needs the fail-closed authorization design described below. No production source change was warranted for this evidence run.

## Acceptance criteria

| Criterion | Status | Evidence and limits |
|---|---|---|
| Operator authorization and privacy-safe capture | **PASS** | Explicit user authorization was received for the metadata-only suite. Harness summaries report `image_bytes_accessed=0` and `image_frames_saved=0`; no image/video files were created. See `evidence/gate1a/runtime-20261018T1030Z/`. |
| Preserve signed v4 installation | **PASS** | Installed app and extension signatures verify. The extension executable SHA-256 remains `82445085fdd3a638b43114cfce4ddda690e2b4257e9f127593484f0d39680880`. No product rebuild, replacement, or activation request was made. |
| Three external-client start/stop/restart cycles | **PASS** | Three separate AVFoundation helper processes opened, received frames, stopped, and released the camera. Extension generations 25, 27, and 29 stopped at zero consumers before the next generation started. Final inventory is `inUse=false`. |
| Two-client ownership and remaining-client delivery | **PASS** | Two separate helper PIDs received concurrently. Client A ended after 20.884 s / 616 frames; client B continued receiving through 46.569 s / 1,394 frames. The extension stopped only after B ended. CMIO's observed start/stop callback count remained `consumers=1`/`0`; it did not expose a count of both AVFoundation sessions, so ownership was proven by independent receiver logs and final shutdown behavior. |
| Five-minute physical-stream endurance | **PASS** | 301.979 s; 9,045 received frames; 29.997 FPS by PTS; zero AVFoundation drop callbacks; zero PTS gaps above 50 ms; seven callback intervals above 50 ms; one extension relay replacement; zero allocation failures; clean stop and physical-camera release. |
| Producer/receiver timing and drop attribution | **PASS** | Producer and receiver metrics are separated in the raw logs below. Callback jitter is not counted as a PTS discontinuity. One relay replacement is explicitly logged; there are no AVFoundation drops or PTS gaps in the five-minute run. |
| Sample-buffer relay lifetime and boundedness review | **PARTIAL** | Source review confirms one waiting `PendingPhysicalFrame` slot plus a frame currently consumed by the serial delivery worker, with AVFoundation configured to discard late frames. Swift ARC retains the pending `CMSampleBuffer` until consumption or replacement. The public `CMIOExtensionStream.send` API documents sending a sample and host-time semantics, but does not specify the precise downstream retain/copy lifetime. Runtime evidence cannot prove the framework's internal ownership behavior; keep this as a production review item. |
| CPU and memory measurement | **PASS** | 1-second `ps` sampling during endurance. See `resource-summary.txt` and `resources.csv`. Values include sampled peaks and may contain short scheduling/startup spikes. |
| GPU / thermal telemetry | **PARTIAL** | `powermetrics --samplers gpu_power -n 1 -i 1000` returned “must be invoked as the superuser”; no privilege escalation was attempted. `pmset -g therm` reported no thermal, performance, or CPU power status warning. GPU utilization/power was not measured. |
| Camera format and nominal rate | **PARTIAL** | Extension logs show physical input 1280×720, `420v`, requested 30 FPS. The external AVFoundation receiver reported 1920×1080 `420v`; receiver PTS rate remained approximately 30 FPS. The downstream format negotiation discrepancy requires a later targeted investigation. |
| Persistent unfiltered-mode risk and fail-closed proposal | **PARTIAL** | Existing source persists `physicalCamera` in the shared app-group `UserDefaults`; a later camera client may therefore reactivate raw physical passthrough without fresh per-session acknowledgement. Proposal is documented below; not implemented in this closeout. |
| System security and stale extension records | **PASS** | SIP reports enabled; Gatekeeper assessments enabled. Existing v1/v2/v3 records were left untouched. v4 remains activated and enabled. |
| Crashes / stability | **PASS** | All five planned client sessions ended cleanly; extension logged clean stop/restart transitions and zero allocation failures. No crash was observed in the captured run. |
| Evidence integrity / reproducibility | **PASS** | Raw privacy-safe logs, source hashes, signing verification, test runner, exact command and a SHA-256 evidence archive are included. Initial runner failure is preserved and explained. |

## Exact run and results

### Harness

New test utility: `evidence/gate1a/MetadataOnlyCapture.swift`. It discovers `PrivateCam Test Camera`, creates an `AVCaptureSession`, and requests `420v`. In each output callback it reads only the sample PTS, arrival time, dimensions, and pixel-format code. It does not lock or read pixel planes and does not retain sample buffers beyond callback scope. The app is an accessory process with no window. `AVCaptureVideoDataOutput.alwaysDiscardsLateVideoFrames` is enabled.

The harness was built and signed separately; it did not rebuild the product:

```sh
swiftc -parse-as-library \
  docs/gates/evidence/gate1a/MetadataOnlyCapture.swift \
  -o /tmp/PrivateCamMetadataHarness.app/Contents/MacOS/PrivateCamMetadataHarness
codesign --force --options runtime --timestamp=none \
  --sign 62E3A7059685F64B0FD5C57ABA56E749A262FBD3 \
  /tmp/PrivateCamMetadataHarness.app
codesign --verify --deep --strict --verbose=2 \
  /tmp/PrivateCamMetadataHarness.app
bash -n docs/gates/evidence/gate1a/run_headless_closeout.sh
PRIVATECAM_OPERATOR_CONSENT=YES \
PRIVATECAM_EVIDENCE_DIR=docs/gates/evidence/gate1a/runtime-20261018T1030Z \
  bash docs/gates/evidence/gate1a/run_headless_closeout.sh
```

The runner enforces `PRIVATECAM_OPERATOR_CONSENT=YES`. The first suite attempt is preserved in `runner-initial-failure.txt`: its first 12-second client completed, then Bash could not `wait` for a PID launched inside command substitution. The runner was corrected to launch clients in its parent shell; the complete suite below was rerun successfully. No product source was modified to address this harness-only issue.

### Received-frame statistics

| Client | Frames | Elapsed | Wall FPS | PTS FPS | Callback gaps >50 ms | PTS gaps >50 ms | AVFoundation drops | PTS interval p50 / p95 / p99 / max (ms) |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| lifecycle-1 | 350 | 12.194 s | 28.703 | 29.997 | 0 | 0 | 0 | 33.340 / 33.340 / 33.340 / 33.340 |
| lifecycle-2 | 368 | 12.675 s | 29.033 | 29.997 | 0 | 0 | 0 | 33.340 / 33.340 / 33.340 / 33.340 |
| lifecycle-3 | 358 | 12.338 s | 29.016 | 29.955 | 1 | 0 | 0 | 33.340 / 33.340 / 33.340 / 50.000 |
| two-client A | 616 | 20.884 s | 29.497 | 29.972 | 3 | 0 | 0 | 33.340 / 33.340 / 33.340 / 50.000 |
| two-client B | 1,394 | 46.569 s | 29.934 | 29.954 | 2 | 1 | 0 | 33.340 / 33.340 / 33.340 / 100.010 |
| five-minute endurance | 9,045 | 301.979 s | 29.952 | 29.997 | 7 | 0 | 0 | 33.340 / 33.340 / 33.340 / 33.340 |

Each run also records callback interval percentiles and capture-PTS age percentiles in its raw log. For endurance, receiver callback intervals were p50 33.368 ms, p95 41.654 ms, p99 43.776 ms, max 64.868 ms. Capture timestamp age was p50 77.406 ms, p95 109.012 ms, p99 112.691 ms. These PTS-age values measure frame timestamp age at observation; they are not added relay processing latency.

The extension's endurance stop log reports 9,046 frames delivered by its physical capture path, one bounded pending-frame replacement, zero allocation failures, 29.961 producer frames/s, and zero reported producer missed periods. Physical-camera callback intervals were p50 33.367 ms, p95 41.542 ms, p99 43.492 ms. Callback-to-send processing was p50 0.041 ms / p95 0.067 ms / p99 0.084 ms; `CMIOExtensionStream.send` call duration p95 was 0.029 ms. The extra producer-side frame versus receiver-side count is consistent with the one logged relay replacement and must not be interpreted as an AVFoundation drop.

Seven receiver callback intervals exceeded 50 ms during endurance, but no adjacent receiver PTS interval exceeded 50 ms. This indicates callback scheduling jitter in the receiver measurements rather than a measured missing timestamp interval. The two-client B run had one PTS interval above 50 ms (100.010 ms) and one above 100 ms; this isolated discontinuity is visible in its log and did not recur during the five-minute run.

### Producer resource samples

During the five-minute capture, 291 helper and 292 extension one-second samples were collected:

| Process | CPU p50 / p95 / sampled max | RSS p50 / p95 / sampled max |
|---|---:|---:|
| Metadata harness | 2.4% / 3.9% / 62.8% | 38,256 / 53,984 / 115,824 KB |
| CameraExtension | 5.0% / 7.2% / 73.1% | 32,064 / 43,568 / 118,960 KB |

The highest CPU and RSS samples occurred in the first one or two seconds as each process attached to the stream (extension peak 73.1% CPU / 118,960 KB at 08:25:55 UTC; helper peak 62.8% CPU and 115,824 KB RSS at 08:25:55–56 UTC). The short peaks are retained as measured. GPU metrics were not collected because this environment requires `powermetrics` to run as superuser; no escalation was attempted. No thermal or CPU-power warning was recorded by `pmset`.

### Producer/receiver format discrepancy

The extension's session log reports a 1280×720 `420v` physical source at requested 30 FPS. AVFoundation reported a 1920×1080 `420v` format at the receiver for each run. The stream delivered near 30 FPS, but the receiver-side dimensions do not match the configured physical input. The harness was intentionally metadata-only and did not alter the source or negotiate a forced format. This discrepancy is a remaining issue; no rebuild or reinstall was performed.

## Lifecycle and release evidence

The extension lifecycle log contains generations 25, 27, and 29 for the three sequential restarts, generation 31 for the overlapping clients, and generation 33 for the five-minute stream. Each zero-consumer transition is followed by physical capture stop; in the overlap, client B continued after A stopped and the producer stopped only when B ended. Final AVFoundation inventory reports the built-in camera `inUse=false`, and `systemextensionsctl list` still shows v4 `[activated enabled]`.

The app-group source preference remains persistently settable to `physicalCamera`. A production fail-closed design should default to a neutral test pattern or black output, require an explicit one-shot/session-scoped authorization lease before physical capture, expire or clear that lease when all clients stop and when the host app exits, and fail closed if authorization is absent or stale. The UI should disclose that the current physical path is unfiltered. This proposal was not implemented here.

## Sample-buffer ownership review

`PendingPhysicalFrame` strongly holds a `CMSampleBuffer` while waiting in the relay slot. The slot is bounded to one waiting frame; a serial worker can additionally hold one in-flight frame during `send`. Replacing the pending slot releases the replaced value through Swift ARC. AVFoundation's late-frame policy is enabled, limiting its own backlog. The test harness independently retained no frame across callbacks and accessed no image bytes.

Apple documents that the AVFoundation delegate receives captured sample buffers and can receive drop callbacks; with `alwaysDiscardsLateVideoFrames` enabled, frames are dropped when the delegate queue is blocked. Apple documents `CMIOExtensionStream.send` as sending a sample and specifies that timestamps are relative to the stream clock, but does not publish a precise downstream buffer lifetime contract. The relay's local ownership is bounded and reviewable; downstream ownership remains an API-contract limitation to resolve before relying on buffer reuse or zero-copy assumptions.

## Signing, security, and extension state

- macOS: 27.0.1 (build 26A434); Apple Silicon arm64.
- Installed PrivateCam app and embedded v4 extension both pass `codesign --verify --deep --strict`.
- Installed extension executable SHA-256: `82445085fdd3a638b43114cfce4ddda690e2b4257e9f127593484f0d39680880`.
- v4 state: `[activated enabled]`.
- Existing older v1/v2/v3 uninstall/reboot records were observed but not changed.
- SIP: enabled. Gatekeeper assessments: enabled.
- No credentials, private signing material, images, or recordings are included.

## Files and hashes

Product source was not changed. The new implementation in this closeout is test tooling: `MetadataOnlyCapture.swift`, `CameraInventory.swift`, and `run_headless_closeout.sh`. `source-additions.patch` records those additions; `source-manifest.sha256` records product and harness source hashes. `PrivateCam_Gate1A_Closeout_Evidence.zip` contains the report, current project sources, privacy-safe logs, and hash manifest. Its SHA-256 is in `archive.sha256`.

## Remaining issues

1. Receiver negotiated 1920×1080 while physical producer capture is configured at 1280×720.
2. GPU utilization/power could not be measured without superuser privileges.
3. Physical-camera source mode persists in app-group preferences; implement and review a fail-closed, session-scoped authorization design before any production release.
4. Apple does not document a precise downstream CMSampleBuffer retain/copy lifetime for `CMIOExtensionStream.send`; do not assume zero-copy lifetime beyond the local relay's own references.
5. A two-client overlap passed at receiver level, while CMIO's callback count remained one active stream user rather than exposing both client sessions separately.

## Official API references

- [AVCaptureVideoDataOutput.alwaysDiscardsLateVideoFrames](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/alwaysdiscardslatevideoframes)
- [AVCaptureVideoDataOutputSampleBufferDelegate](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutputsamplebufferdelegate)
- [CMIOExtensionStream](https://developer.apple.com/documentation/coremediaio/cmioextensionstream)
- [CMIOExtensionStream.send(_:discontinuity:hostTimeInNanoseconds:)](https://developer.apple.com/documentation/coremediaio/cmioextensionstream/send%28_%3Adiscontinuity%3Ahosttimeinnanoseconds%3A%29)
- [Apple TN2445 — Handling Frame Drops with AVCaptureVideoDataOutput](https://developer.apple.com/library/archive/technotes/tn2445/_index.html)

## Worktree status

No commit or push was made. The repository has no tracked base source in this checkout; current project files remain untracked. The before/after Git status is recorded in the evidence directory. No stale extension record or system security setting was modified.

## Directive 002-C closeout addendum (2026-10-18)

The prior metadata-only run remains the runtime evidence for v4. The new read-only revalidation recorded in `docs/gates/evidence/gate1a/preflight-20261018.txt` confirms installed extension v4, bundle identifiers, effective signature verification, installed executable hash, SIP/Gatekeeper, camera inventory and stale extension states. The built-in camera and virtual camera were both idle during preflight; the stable PrivateCam device ID remained `76A10B58-2C45-4B8C-BE2A-0D6F1C286101`. The preflight did not start a camera stream.

### Directive 002-C criterion status

| Criterion | Status | Evidence / limitation |
|---|---|---|
| Exact installed v4/signature/security/system-state preflight | **PASS** | `evidence/gate1a/preflight-20261018.txt`, `v4-signature-verification.txt`, `platform-security-state.txt`; no registry cleanup. |
| Current source SHA-256 reconciliation | **PARTIAL** | The accepted Gate 1A source manifest was reconciled against the v4 source snapshot in the new archive; every product-source entry matches. The active checkout also contains later Gate 1B edits and is not claimed byte-identical to installed v4. See `evidence/gate1a/v4-source-reconciliation.txt`. |
| Three external-client start/stop/restart cycles | **PARTIAL (prior authorized run)** | `runtime-20261018T1030Z/lifecycle-{1,2,3}.log`; each ran about 12 seconds with 350, 368 and 358 frames. The directive threshold is at least 20 seconds per cycle, so these prior 12-second runs do not satisfy the specified cycle duration; first-frame latency is also **NOT VERIFIED**. |
| Five-minute physical passthrough | **PASS (prior authorized run)** | 301.979 seconds, 9,045 receiver frames, 29.952 wall FPS / 29.997 PTS FPS, zero AVFoundation drops, zero PTS gaps >50 or >100 ms. `endurance-five-minutes.log`. |
| Two-client ownership and final release | **PASS (prior authorized run)** | Independent receiver A stopped while B continued; producer stopped on final receiver stop. CMIO callback count is not treated as client count. `two-client-a.log`, `two-client-b.log`, `extension-lifecycle.log`. |
| Stable identity / physical device release | **PASS (prior authorized run and current preflight)** | Stable virtual camera UUID; inventory reports physical and virtual `inUse=false` after run and at current preflight. |
| Callback/PTS/drop/producer telemetry | **PASS with limits** | Logs separate callback scheduling gaps from PTS gaps, identify one startup relay replacement and zero AVFoundation drops. First-frame latency and full physical/virtual `inUse` sampling during each cycle were not recorded. |
| CPU and resident memory | **PASS** | One-second `ps` samples: extension CPU p50/p95/max 5.0/7.2/73.1%; RSS p50/p95/max 32,064/43,568/118,960 KB. |
| Thermal/GPU/power | **PARTIAL** | `pmset -g therm` showed no warnings. GPU power/utilization unavailable because `powermetrics` required superuser; no escalation attempted. |
| Format negotiation | **PARTIAL** | Source configured 1280×720 `420v`; receiver measured 1920×1080 `420v`. No speculative pipeline edits. |
| Buffer ownership/pool pressure | **PARTIAL** | One relay replacement and zero AVFoundation drop callbacks/allocation failures in five minutes. The AVFoundation internal pool and CMIO downstream retain lifetime are not observable from these logs. |
| Source selection / production privacy | **PARTIAL** | Historical run metadata states `source_mode=physicalCamera`; current defaults lookup found no readable key in the current user context. v4 persisted shared preference can select unfiltered physical input from an external stream start. It must not be treated as a privacy-safe product. See `source-review-answers.txt`. |
| Host UI blocking behavior | **NOT VERIFIED** | `startRunning()` is on the host UI path; no UI profiling was done. Defer a threading change until a measurable hitch is reproduced. |
| TCC denial, interruption, hardware loss/runtime error | **NOT VERIFIED** | No TCC reset or disruptive injection. Static failure handling is documented in `source-review-answers.txt`; supported runtime notification instrumentation remains a follow-up. |
| No retained/shared imagery, private recording, security bypass, cleanup, commit/push | **PASS** | Harness records `image_bytes_accessed=0`, `image_frames_saved=0`, `recording=0`, `encoding=0`. No such artifacts included in archive. |

### Operator action before another physical-camera run

No new camera run was started during this addendum. A fresh run is needed to meet the 20-second cycle duration and collect first-frame timing. Obtain explicit consent immediately before starting: the app may locally see the normal camera field of view, while no raw video, screenshots, still frames, or pixel-buffer contents will be persisted, transmitted, or attached to reports. Until that consent is given, status is **HUMAN ACTION REQUIRED** for any new physical-camera run. Existing authorized telemetry is retained as evidence and is not supplemented with new camera data here.

### Issues table

| Issue | Severity | Evidence | Disposition |
|---|---|---|---|
| Receiver reports 1920×1080 although producer is configured for 1280×720 | Medium | Producer lifecycle and receiver format lines | Characterize later with a format matrix; do not guess or relabel. |
| App Group preference may cause unfiltered physical source to start on an external request | High privacy risk | v4 source and historical run metadata | Keep current v4 out of privacy-safe call use; product fix requires session-scoped explicit authorization and neutral fail-closed output. |
| Relay retains one waiting plus one in-flight native sample buffer | Medium | bounded relay source; one startup replacement in endurance | Keep unchanged; measured run showed no sustained pressure. Internal framework pool behavior remains unknown. |
| Host calls `startRunning()` on UI path | Low / unproven | Source inspection only | Defer until profiling reproduces hitch. |
| No fault injection for TCC/interruption/runtime hardware failure | Medium | No runtime fault logs | Add supported notification logging and test with a controlled test double in a future scoped change. |
| First-frame latency and per-cycle inUse timeline absent | Low evidence gap | Existing harness logs | Add metadata-only telemetry if another run is authorized. |

Gate 1B remains unauthorized. No product source change, activation, reinstall, or restart was performed for this closeout addendum.

## Fresh CPO 002-C authorized runtime run — 2026-10-18

The operator explicitly authorized a fresh local metadata-only camera run immediately before activation. The notice stated that the app may locally see the camera's normal field of view and that no raw video, screenshots, still frames, or pixel-buffer contents would be persisted, transmitted, or attached. The harness read only metadata and discarded buffers in callback scope. It did not decode, hash, lock, map, copy, display, encode, or store image planes. `run-metadata.txt` records `images_saved=0`, `recording=0`, and `encoding=0`.

Run directory: `docs/gates/evidence/gate1a/runtime-20261018T111121Z/`. Before capture, source selection was explicitly set to `physicalCamera`; after every consumer stopped and the extension logged physical-capture closure, it was set back to `testPattern`. The final preference read confirmed `testPattern`. No app replacement, extension activation, reboot, product-source edit, TCC reset, security change, or historical-record cleanup occurred.

### Fresh criterion results

| Criterion | Status | Fresh evidence |
|---|---|---|
| Three sequential external-client cycles >=20 seconds | **PASS** | 20.166 s / 587 frames; 20.361 s / 599; 20.630 s / 607. First-frame times: 722.433, 435.260, 410.261 ms. Zero receiver AVFoundation drops. |
| Five-minute continuous physical passthrough | **PASS** | 302.049 s; 9,045 received frames; 29.946 wall FPS / 29.995 PTS FPS. No crash, deadlock, or permanent stall observed. |
| Receiver drop and gap thresholds | **PASS** | Endurance: zero AVFoundation drops, two callback intervals >50 ms, zero PTS intervals >50 ms and >100 ms. Max callback interval 52.531 ms; max PTS interval 50.000 ms. |
| Producer closeout and frame path | **PASS** | Producer summary: 9,046 frames, 29.963 FPS, zero producer drops, zero allocation failures, zero missed periods; 0 relay replacements during endurance. One relay replacement occurred at startup in cycle 1 and was logged with reason. |
| Two-client ownership | **PASS (receiver evidence)** | Distinct helper PIDs 67765 (A) and 67797 (B) overlap. A stopped at 20.612 s / 607 frames; B continued through 46.383 s / 1,390 frames. Producer stopped only after B stopped. Do not infer client count from CMIO stream callback counts. |
| Final physical/virtual camera release | **PASS** | After producer closure, metadata inventory reported built-in camera `inUseByAnotherApplication=false` and PrivateCam virtual camera `inUseByAnotherApplication=false`; both `capture_started=false`. Extension remained active. |
| Stable camera identity and advertised physical format | **PASS** | PrivateCam ID remains `76A10B58-2C45-4B8C-BE2A-0D6F1C286101`; built-in camera ID `6C707041-05AC-0010-0008-000000000001`; producer configured 1280×720 `420v` at 30 FPS. |
| 720p-to-1080p receiver discrepancy | **PARTIAL** | All six receiver sessions negotiated 1920×1080 `420v`; session preset logged as High. Physical producer was configured at 1280×720 `420v`; virtual device advertises 1280×720. No source/pipeline change made. Receiver auto-sizing true/false and independent active-format internals were not measured. |
| Producer/receiver timestamp comparison | **PARTIAL** | Receiver interval distributions and capture PTS-age distributions were recorded. Endurance callback p50/p95/p99/max: 33.343/35.428/37.000/52.531 ms; PTS interval: 33.340/33.340/33.340/50.000 ms; PTS age: 76.807/79.652/81.295 ms. Producer callback-to-send p50/p95/p99: 0.039/0.073/0.125 ms; send-call p95 0.031 ms; producer capture PTS age p50/p95/p99 75.630/78.146/79.627 ms. Absolute first/last receiver PTS values and maximum PTS age were not logged (**NOT VERIFIED**). PTS age is not sensor-to-display latency. |
| CPU and resident memory | **PARTIAL** | One-second samples: endurance CameraExtension 289 samples, CPU p50/p95/max 4.7/5.3/57.2%, RSS p50/p95/max 38,016/80,672/118,160 KB. First/last 60-second median RSS 60,336/31,120 KB, no monotonic growth observed. A true idle pre-stream baseline was not captured (**NOT VERIFIED**); after-stop sample is 0.3% CPU / 39,296 KB. |
| Thermal/GPU/power | **PARTIAL** | `pmset -g therm` recorded no thermal/performance/CPU power warning. A non-privileged `powermetrics --samplers gpu_power -n 1 -i 1000` attempt returned “must be invoked as the superuser”; GPU/power not measured, no escalation attempted. |
| Buffer retention/drop pressure | **PARTIAL** | One waiting slot plus one in-flight relay frame; harness maximum owned sample buffers=1. Endurance had zero relay replacements, AVFoundation drops, and allocation failures. Internal AVFoundation pool pressure and CMIO downstream retain/copy lifetime remain unobservable. |
| TCC denied, interruption, unavailable hardware, runtime error | **NOT VERIFIED** | Normal camera operation succeeded. No TCC reset or disruptive fault injection was performed. Supported error paths were not stimulated in this run. |
| Host UI `startRunning()` responsiveness | **NOT VERIFIED** | Run was headless; UI hitch profiling was not attempted. Keep fix deferred until a repro/profile demonstrates impact. |
| Images/private-content retention | **PASS** | No pixel-buffer content read; no images/video/screenshots were produced or attached. No quarantined recording was accessed or deleted. |

### Resource and format evidence

The raw per-second CPU/RSS samples are in `runtime-20261018T111121Z/resources.csv`; the complete computed summary and limitations are in `runtime-summary.txt`. Thermal and GPU attempts are in `thermal-after.txt` and `powermetrics-attempt.txt`. The physical camera source ran at 1280×720 420v, while the independent AVFoundation receiver reported 1920×1080 420v in each session. Each receiver used the default High session preset. This does not establish where or why scaling occurred. No camera-pipeline experiment was made.

The CMIO source's `CMSampleBuffer` relay holds at most one pending frame plus an in-flight consumer frame. One startup replacement was logged in the first cycle; no replacement occurred over the five-minute run. This run did not expose internal source-pool pressure, so the existing relay remains unchanged.

### Updated disposition

Gate 1A is **PARTIAL** for CPO review. The required cycle/endurance/two-client/release timing criteria passed in a fresh authorized run. Remaining evidence gaps are absolute first/last PTS values, maximum capture PTS age, an idle process-resource baseline, GPU/power telemetry, and fault-injected camera failure modes. The source-mode risk and 720p/1080p discrepancy remain open issues. Current v4 remains an unfiltered development path and must not be presented as privacy-safe for calls. After the run, the shared source selector is set to Test Pattern and all camera consumers are stopped. Gate 1B remains unauthorized.

### Open issues at CPO handoff

| Issue | Severity | Evidence | Next action |
|---|---|---|---|
| v4 physical source is unfiltered and selected by shared preference | High privacy risk | Prior source snapshot; this run selected physical mode only after explicit consent and restored Test Pattern afterward | Keep v4 out of privacy-safe calls; require a reviewed, session-scoped fail-closed product design before release. |
| Receiver buffers are 1920×1080 while producer is 1280×720 | Medium | Six receiver format logs vs producer activeFormat logs | Measure negotiation layers in a separate controlled investigation; do not guess or alter the camera pipeline. |
| Absolute first/last receiver PTS and max PTS age omitted | Low evidence gap | Aggregated receiver summary has PTS intervals and age percentiles only | Add metadata fields to the harness for a future authorized run. |
| Idle pre-run process baseline absent; GPU/power unavailable | Low evidence gap | Resource CSV starts at stream startup; powermetrics requires superuser | Capture idle baseline next run; do not elevate solely for GPU telemetry. |
| TCC denial, interruption, hardware removal and runtime errors not injected | Medium | Normal successful run only | Add supported non-disruptive notification checks and controlled fault tests in a scoped follow-up. |
| AVFoundation/CMIO internal retained-buffer lifetime is not observable | Medium | One startup replacement; zero endurance relay replacements/drop/allocation failures | Keep relay unchanged; do not assume downstream zero-copy lifetime. |
| Host startRunning UI responsiveness unprofiled | Low / unproven | Headless test only | Defer threading changes until a reproducible UI hitch is measured. |

### Apple API references used for interpretation

- [TN2445: Handling Frame Drops with AVCaptureVideoDataOutput](https://developer.apple.com/library/archive/technotes/tn2445/_index.html) describes delegate efficiency and dropped-frame callbacks; the observed relay replacement is reported separately from AVFoundation drops.
- [AVCaptureVideoDataOutput sample-buffer delegate](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutputsamplebufferdelegate/captureoutput%28_%3Adidoutput%3Afrom%3A%29) defines frame delivery callbacks; this harness reads metadata and does not access image planes.
- [Creating a camera extension with Core Media I/O](https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o) describes provider/device/stream roles and the stream source lifecycle used to interpret producer start/stop logs.
- [OSSignposter](https://developer.apple.com/documentation/os/OSSignposter) supports interval instrumentation viewable in Instruments. OSSignposter/Instruments were not used: current timing came from existing monotonic runtime counters, and adding product instrumentation would require a product source change outside this evidence-only run. The measured callback-to-send and send-call numbers are instrumented counters, not end-to-end sensor-to-display latency.
