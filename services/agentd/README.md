# agentd

The middle layer. Agent loop, tool dispatch, model adapters, and the mock headset.

Python so that contributors without a Mac can build and test the whole agent brain — no
Xcode, no headset, no Apple developer account (see `docs/architecture.md` §2d).

## Run

```bash
python -m venv .venv && .venv/bin/pip install -e ".[dev]"

# no model required — deterministic echo adapter
AGENTD_BACKEND=echo .venv/bin/python -m agentd --port 8787

# real local model
ollama serve && ollama pull llama3.2
AGENTD_MODEL=llama3.2 .venv/bin/python -m agentd --port 8787
```

Binds `0.0.0.0` because Vision Pro is a separate device on the LAN and cannot reach
localhost.

## Drive it without a headset

```bash
.venv/bin/python -m mocks.fake_headset --scenario apartment
.venv/bin/python -m mocks.fake_headset --scenario apartment --say "turn off the kitchen lights"
.venv/bin/python -m mocks.fake_headset --list-scenarios
```

`fake_headset` opens a real WebSocket and speaks the real schema — it is not a shortcut past
the transport. Tokens stream, `[character]` lines show directives, `[tool]` lines show tool
calls, and `unsafe` tools prompt for confirmation unless `--yes` is passed.

## Test

```bash
.venv/bin/python -m pytest
```

Runs headless on Linux CI. `tests/test_session.py` exercises the full agent loop: scenario
in, assert on the sequence of `ServerEvent`s out.

## Layout

```
agentd/protocol.py      wire types, validated against packages/AgentProtocol/schema
agentd/server.py        WebSocket endpoint, message dispatch
agentd/session.py       conversation state + agent loop
agentd/directives.py    model text -> symbolic character intent
agentd/prompt.py        runtime system prompt from scene + devices
agentd/tools/           tool registry, safety classification
agentd/adapters/        echo (deterministic), ollama (streaming)
mocks/                  fake headset, scenario fixtures, mock smart home
```

## Environment

| Var | Default | |
|---|---|---|
| `AGENTD_BACKEND` | `ollama` | `echo` for no-model development |
| `AGENTD_MODEL` | `llama3.2` | |
| `OLLAMA_URL` | `http://127.0.0.1:11434` | |

## Phase 1 boundaries

Hand-written Pydantic models, kept honest by schema tests; codegen replaces them in phase 2.
No Bonjour advertisement yet (connect by IP). No ambient event push. Tool execution is
client-side; `mocks/mock_home.py` stands in for HomeKit.
