#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/privatecam-privacy-tests.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

swiftc -parse-as-library \
  "$ROOT/PrivateCam/CameraPrivacyState.swift" \
  "$ROOT/Tests/PrivacyPolicyTests.swift" \
  -o "$OUT/release-policy-tests"
"$OUT/release-policy-tests"

swiftc -DDEBUG -parse-as-library \
  "$ROOT/PrivateCam/CameraPrivacyState.swift" \
  "$ROOT/Tests/PrivacyPolicyTests.swift" \
  -o "$OUT/debug-policy-tests"
"$OUT/debug-policy-tests"
