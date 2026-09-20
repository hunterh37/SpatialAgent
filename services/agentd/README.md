# agentd

The middle layer. Agent loop, tool dispatch, model adapters, ambient events, and the mock
headset.

Python so that contributors without a Mac can build and test the whole agent brain — no
Xcode, no headset, no Apple developer account (see `docs/architecture.md` §2d).

## Run

```bash
python -m venv .venv && .venv/bin/pip install -e ".[dev]"

# no model required — deterministic echo adapter
AGENTD_BACKEND=echo .venv/bin/python -m agentd --port 8787

# real local model, via Ollama
ollama serve && ollama pull llama3.2
AGENTD_MODEL=llama3.2 .venv/bin/python -m agentd --port 8787

# real local model, via anything OpenAI-compatible (llama.cpp server, LM Studio, vLLM)
AGENTD_BACKEND=lmstudio AGENTD_MODEL=qwen2.5-7b-instruct .venv/bin/python -m agentd
```

Binds `0.0.0.0` because Vision Pro is a separate device on the LAN and cannot reach
localhost, and advertises `_spatialagent._tcp` over Bonjour so the headset finds it without
anyone typing an IP. `--no-bonjour` turns the advertisement off; the client's manual IP
field is the fallback for conference Wi-Fi that blocks mDNS.

## Drive it without a headset

```bash
.venv/bin/python -m mocks.fake_headset --scenario apartment
.venv/bin/python -m mocks.fake_headset --scenario apartment --say "turn off the kitchen lights"
.venv/bin/python -m mocks.fake_headset --resume <sessionId>   # sleep/wake, same conversation
.venv/bin/python -m mocks.fake_headset --list-scenarios
```

`fake_headset` opens a real WebSocket and speaks the real schema — it is not a shortcut past
the transport. Tokens stream, `[character]` lines show directives, `[tool]` lines show tool
calls, `[ambient]` lines show the home speaking first, and `unsafe` tools prompt for
confirmation unless `--yes` is passed.

At the prompt: `/devices` lists state, `/ring` fires the doorbell (an ambient event with
nobody having said anything), `/place NAME` names a place, `/quit` exits.

## Who executes a tool

Two modes, same safety rule: an `unsafe` tool never runs without an approval carrying its
`callId`.

| `AGENTD_HOME` | `toolCall.executedBy` | What the client does |
|---|---|---|
| `client` (default) | `client` | confirms, executes, returns `toolResult` |
| `mock` | `server` | confirms only, returns `confirmationResult` |

HomeKit is not in the visionOS SDK, so the shipping answer is the second row with a macOS
companion in place of `mocks/mock_home.py`: it implements `HomeExecutor` and nothing else
changes. The headset then never claims to have done something it did not do.

## Test

```bash
.venv/bin/python -m pytest        # from services/agentd
make test                         # from the repo root: schema check + python + swift
```

Runs headless on Linux CI. `tests/test_session.py` exercises the full agent loop: scenario
in, assert on the sequence of `ServerEvent`s out.

## Layout

```
agentd/protocol.py      wire types, validated against packages/AgentProtocol/schema
agentd/server.py        WebSocket endpoint, message dispatch, outbound queue
agentd/session.py       conversation state, agent loop, session store for resume
agentd/executors.py     who fulfils a tool call: the client, or this machine
agentd/ambient.py       home state -> classified, rate-limited ambient events
agentd/discovery.py     Bonjour advertisement of _spatialagent._tcp
agentd/directives.py    model text -> symbolic character intent
agentd/prompt.py        runtime system prompt from scene + devices
agentd/tools/           tool registry, safety classification
agentd/adapters/        echo (deterministic), ollama, openai-compatible
mocks/                  fake headset, scenario fixtures, mock smart home
```

## Environment

| Var | Default | |
|---|---|---|
| `AGENTD_BACKEND` | `ollama` | `echo`, `ollama`, or `lmstudio`/`llamacpp`/`vllm`/`openai` |
| `AGENTD_MODEL` | `llama3.2` | |
| `OLLAMA_URL` | `http://127.0.0.1:11434` | |
| `OPENAI_BASE_URL` | `http://127.0.0.1:1234/v1` | for the OpenAI-compatible backend |
| `AGENTD_HOME` | `client` | `mock` executes tools here instead of on the headset |
| `AGENTD_SCENARIO` | `apartment` | which fixture `AGENTD_HOME=mock` loads |
| `AGENTD_TOOL_TIMEOUT` | `30` | seconds to wait for a result or a confirmation |

## Phase boundaries

Hand-written Pydantic models, kept honest by schema tests and `make protocol`; generated
models are still the phase-3 goal. Speech input is client work and is not implemented — the
protocol carries `isFinal` so the schema change happens once rather than twice.
