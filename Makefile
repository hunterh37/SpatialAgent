# SpatialAgent. Every target runs without a headset; only `app` needs a Mac with Xcode.

VENV := services/agentd/.venv
PY   := $(VENV)/bin/python

.PHONY: help protocol test test-python test-swift lint serve headset clean app home-app

help:
	@grep -E '^[a-z-]+:.*?##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/'

$(VENV):
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install -q -e "services/agentd[dev]"

protocol: $(VENV) ## Regenerate the conformance corpus and check both languages for drift
	@cd services/agentd && .venv/bin/python -m agentd.conformance > /dev/null
	@python3 scripts/check_protocol.py

test-python: $(VENV) ## Headless agent loop, runs on Linux CI
	cd services/agentd && .venv/bin/python -m pytest -q

test-swift: ## Packages only; no simulator, no headset
	cd packages && swift test

test: protocol test-python test-swift ## Everything a contributor can run locally

live: $(VENV) ## End-to-end: ollama + agentd + the real Swift client stack
	@scripts/live-test.sh

live-app: $(VENV) ## End-to-end through the visionOS app itself, in the simulator
	@scripts/live-app-test.sh

home-app: ## Generate and build the macOS companion that owns HomeKit
	cd apps/SpatialAgentHome && xcodegen generate && \
		xcodebuild -project SpatialAgentHome.xcodeproj -scheme SpatialAgentHome \
		-destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

app: ## Generate the Xcode project and build the visionOS app
	cd apps/SpatialAgent && xcodegen generate && \
		xcodebuild -project SpatialAgent.xcodeproj -scheme SpatialAgent \
		-destination 'generic/platform=visionOS Simulator' build

lint: $(VENV)
	cd services/agentd && .venv/bin/ruff check .

serve: $(VENV) ## Local model on this machine, advertised over Bonjour
	cd services/agentd && .venv/bin/python -m agentd --port 8787

headset: $(VENV) ## Drive the agent from a terminal, no Vision Pro required
	cd services/agentd && .venv/bin/python -m mocks.fake_headset --scenario apartment

clean:
	rm -rf $(VENV) packages/.build
	find . -name __pycache__ -type d -prune -exec rm -rf {} +
