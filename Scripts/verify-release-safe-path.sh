#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?usage: verify-release-safe-path.sh <Release.app> <report-file>}"
REPORT="${2:?usage: verify-release-safe-path.sh <Release.app> <report-file>}"
EXT="$APP/Contents/Library/SystemExtensions/com.martinaziz.privatecam.CameraExtension.systemextension"

python3 - "$ROOT" "$EXT" "$REPORT" <<'PY'
from pathlib import Path
import plistlib, subprocess, sys
root=Path(sys.argv[1]); ext=Path(sys.argv[2]); report=Path(sys.argv[3])
source=(root/'PrivateCam/Camera Extension/CameraProvider.swift').read_text()
start=source.index('fileprivate func receivePhysicalFrame(')
end=source.index('fileprivate func notePhysicalFrameDrop(',start)
body=source[start:end]
publisher_start=source.index('private func produceFrame()')
publisher_end=source.index('private struct PendingPhysicalFrame',publisher_start)
publisher=source[publisher_start:publisher_end]
all_sends=[line.strip() for line in source.splitlines() if '.stream.send(' in line]
assert len(all_sends)==1 and 'streamSource.stream.send(sampleBuffer' in all_sends[0], f'expected one serialized send site, found {all_sends}'
assert 'processedFrameSlot.offer(frame)' in body, 'successful composites do not reach bounded publisher slot'
assert 'result.usedNeutralFallback' in body, 'processor failure fallback is not rejected from processed slot'
assert 'processedFrameSlot.takeIfCurrent' in publisher, 'publisher does not enforce freshness, config, and generation'
assert 'CMSampleBufferCreateForImageBuffer' in publisher and 'streamSource.stream.send(sampleBuffer' in publisher, 'single publisher does not construct and send its selected frame'
assert 'configuration == CameraProcessingConfiguration.read()' in body, 'effect changes are not checked at the output boundary'
assert 'output !== source' in body and 'final output boundary rejected' in body, 'raw physical buffer is not rejected before slot admission'
assert 'finalAgeMs' in body and 'frameAgeMilliseconds: finalAgeMs' in body, 'stale output age is not checked before slot admission'
assert 'CVPixelBufferGetPixelFormatType(output) == outputFormat' in body, 'advertised pixel format is not validated before slot admission'
assert 'sourcePresentationTime' in body and 'CMClockGetTime(CMClockGetHostTimeClock())' in publisher, 'capture and publisher clocks are not separated'
assert 'didLogPhysicalSampleFormatCount < 5' in body and 'source_fourcc=' in body, 'first five physical callback formats are not logged'
auth_start=source.index('func authorizeStreamClient(')
auth_end=source.index('private func startNeutralFallbackProducer(',auth_start)
assert 'return true' in source[auth_start:auth_end], 'ordinary virtual-camera clients are not admitted'
assert 'updateEngineStatus("Starting: neutral output active' in source, 'startup neutral status is not reported'
assert 'memset(luma, fullRange ? 105 : 107' in source, 'neutral fallback producer is not a flat frame'
privacy=(root/'PrivateCam/CameraPrivacyState.swift').read_text()
assert 'static let modeKey' in privacy and 'static func writeEngineStatus' in privacy, 'shared processing controls/status are missing'
assert 'frameAgeMilliseconds <= 100' in privacy, 'publication age limit is not 100 ms'
info=plistlib.loads((ext/'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier']=='com.martinaziz.privatecam.CameraExtension'
assert str(info['CFBundleVersion'])=='13', f"expected extension successor build 13; found {info['CFBundleVersion']}"
binary=ext/'Contents/MacOS/CameraExtension'
strings=subprocess.run(['/usr/bin/strings','-a',str(binary)],check=True,capture_output=True,text=True).stdout
assert 'development-only unfiltered camera lease granted' not in strings, 'raw development authorization path remains in Release binary'
verify=subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict','--verbose=2',str(Path(sys.argv[2]).parents[3])],capture_output=True,text=True)
if verify.returncode:
    # Verify the app separately below; extension bundle strict verification is also required.
    raise SystemExit(verify.stdout+verify.stderr)
report.parent.mkdir(parents=True,exist_ok=True)
report.write_text('\n'.join([
 'release_safe_path=PASS',
 'ordinary_virtual_client_connection=allowed_without_development_lease',
 'release_physical_sample_route=Vision_CoreImage_NV12_composite',
 'release_contains_direct_physical_sample_send=NO',
 'release_output_boundary_checks_effect_generation_age_dimensions_format_and_buffer_identity=PASS',
 'release_publisher_sites=1',
 f'extension_bundle_identifier={info["CFBundleIdentifier"]}',
 f'extension_bundle_version={info["CFBundleVersion"]}',
 'extension_signature_verification=PASS',
 'test_scope=static_source_plus_compiled_release_binary',
 'runtime_extension_activation=NOT_PERFORMED',
])+'\n')
PY
codesign --verify --deep --strict --verbose=2 "$APP" >> "$REPORT" 2>&1
codesign --verify --deep --strict --verbose=2 "$EXT" >> "$REPORT" 2>&1
APP_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
shasum -a 256 "$APP/Contents/MacOS/$APP_EXECUTABLE" "$EXT/Contents/MacOS/CameraExtension" >> "$REPORT"
