#!/usr/bin/env bash
# The app layer, end to end: a local model, agentd owning the home, and the real visionOS
# app driven through its UI in the simulator.
#
# `AGENTD_HOME=mock` is deliberate: HomeKit does not exist in the visionOS SDK, so a device
# list on the headset would be fiction. The server owns the home and the app's job narrows
# to asking a human — which is what the confirmation test checks.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL="${AGENTD_MODEL:-llama3.2:3b}"
SIM="${SPATIAL_SIM:-Apple Vision Pro}"

curl -sf http://127.0.0.1:11434/api/version > /dev/null || {
  echo "ollama is not running: brew services start ollama" >&2; exit 1; }

# The simulator reaches the Mac as its own localhost, and AppModel auto-connects to
# 127.0.0.1:8787 there, so the port is not arbitrary.
AGENTD_HOME=mock AGENTD_MODEL="${MODEL}" \
  "${ROOT}/services/agentd/.venv/bin/python" -m agentd --port 8787 --log-level info &
AGENTD_PID=$!
trap 'kill ${AGENTD_PID} 2>/dev/null || true' EXIT

for _ in $(seq 1 40); do
  curl -sf http://127.0.0.1:8787/health > /dev/null && break
  sleep 0.25
done
curl -sf http://127.0.0.1:8787/health || { echo "agentd did not come up" >&2; exit 1; }
echo

cd "${ROOT}/apps/SpatialAgent"
xcodegen generate
xcodebuild -project SpatialAgent.xcodeproj -scheme SpatialAgent \
  -destination "platform=visionOS Simulator,name=${SIM}" \
  -derivedDataPath "${ROOT}/.build/xcode" test
