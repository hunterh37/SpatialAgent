#!/usr/bin/env bash
# End to end: a local model, the real middle layer, and the real Swift client stack.
#
# Nothing here is mocked except the room and the home. The Swift tests in
# packages/Tests/LiveIntegrationTests connect over a real WebSocket, so this is the run that
# catches a Swift/Python disagreement — the kind of bug that otherwise only shows up on a
# headset, which is the worst place to debug (docs/architecture.md §3a).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${AGENTD_PORT:-8791}"
MODEL="${AGENTD_MODEL:-llama3.2:3b}"
URL="ws://127.0.0.1:${PORT}/agent"

if ! curl -sf http://127.0.0.1:11434/api/version > /dev/null; then
  echo "ollama is not running: brew services start ollama" >&2
  exit 1
fi

if ! ollama list | grep -q "^${MODEL}"; then
  echo "pulling ${MODEL}" >&2
  ollama pull "${MODEL}"
fi

echo "starting agentd on ${PORT} with ${MODEL}"
AGENTD_MODEL="${MODEL}" "${ROOT}/services/agentd/.venv/bin/python" -m agentd \
  --port "${PORT}" --no-bonjour --log-level warning &
AGENTD_PID=$!
trap 'kill ${AGENTD_PID} 2>/dev/null || true' EXIT

for _ in $(seq 1 40); do
  curl -sf "http://127.0.0.1:${PORT}/health" > /dev/null && break
  sleep 0.25
done
curl -sf "http://127.0.0.1:${PORT}/health" || { echo "agentd did not come up" >&2; exit 1; }
echo

# Warm the model so the first test is not paying for a cold load.
AGENTD_LIVE_URL="${URL}" "${ROOT}/services/agentd/.venv/bin/python" \
  -m mocks.fake_headset --url "${URL}" --scenario apartment --yes \
  --say "hello" > /dev/null 2>&1 || true

cd "${ROOT}/packages"
AGENTD_LIVE_URL="${URL}" swift test --filter LiveAgentTests
