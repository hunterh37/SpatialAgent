# SpatialAgent. Every target runs without a headset; only `app` needs a Mac with Xcode.

VENV := services/agentd/.venv
PY   := $(VENV)/bin/python

.PHONY: help protocol test test-python test-swift lint serve headset clean

help:
	@grep -E '^[a-z-]+:.*?##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/'

$(VENV):
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install -q -e "services/agentd[dev]"

protocol: ## Check Swift and Python wire types against the schema (CI fails on drift)
	@python3 scripts/check_protocol.py

test-python: $(VENV) ## Headless agent loop, runs on Linux CI
	cd services/agentd && .venv/bin/python -m pytest -q

test-swift: ## Packages only; no simulator, no headset
	cd packages && swift test

test: protocol test-python test-swift ## Everything a contributor can run locally

lint: $(VENV)
	cd services/agentd && .venv/bin/ruff check .

serve: $(VENV) ## Local model on this machine, advertised over Bonjour
	cd services/agentd && .venv/bin/python -m agentd --port 8787

headset: $(VENV) ## Drive the agent from a terminal, no Vision Pro required
	cd services/agentd && .venv/bin/python -m mocks.fake_headset --scenario apartment

clean:
	rm -rf $(VENV) packages/.build
	find . -name __pycache__ -type d -prune -exec rm -rf {} +
