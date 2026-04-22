# AGENTS.md — ocaml-agent-graph

This file is for AI coding agents. It contains the exact facts you need to
modify, test, and review this project correctly.

---

## Project overview

`ocaml-agent-graph` is a typed, modular multi-agent orchestration framework in
OCaml. It provides LangGraph/CrewAI-style agent routing with explicit typed
state transitions, tamper-evident audit trails, retries, timeouts, and parallel
execution. It is designed to be driven from an interactive terminal, from
HTTP endpoints, or from other OCaml programs.

The framework talks to LLMs through [BulkheadLM](https://github.com/Louis-Ph/bulkhead-lm),
a sibling gateway dependency that is cloned automatically by the starter scripts.

### Technology stack

- **Language**: OCaml >= 5.2.0
- **Build system**: Dune >= 3.21
- **Package manager**: opam
- **Concurrency**: Lwt (async promises)
- **JSON**: yojson
- **Formatting**: fmt
- **Database**: sqlite3 (for memory persistence)
- **HTTP client/server**: cohttp-lwt-unix
- **CLI parsing**: cmdliner
- **Testing**: alcotest
- **Code formatting**: ocamlformat (profile = conventional)

### Key dependencies

- `bulkhead_lm` — pinned as a sibling directory (`../bulkhead-lm`)
- `lwt`, `lwt.unix` — cooperative threading
- `yojson` — JSON handling
- `fmt` — pretty-printing
- `sqlite3` — session memory storage
- `cohttp-lwt-unix` — HTTP transport
- `cmdliner` — CLI interfaces

---

## Project structure

```
lib/          — Framework library (public name: agent_graph)
  core/       — L0/L0.5/L3 swarm primitives: types, envelope, capability, audit, pattern
  config/     — JSON configuration loader (runtime.json schema)
  llm/        — BulkheadLM client and prompt builders
  agents/     — Built-in agents: planner, summarizer, validator
  runtime/    — Execution engine: registry, retry policy, timeout, parallel executor, services
  orchestration/ — Graph routing, discussion, consensus (L1), pipeline (L2), aggregator, decider
  client/     — Human terminal, machine worker, HTTP server, messenger spokesperson
  web_crawler/ — Adaptive web crawler demo modules
  agent_graph.ml — Public facade: re-exports all modules and a high-level run function

bin/          — Executables
  ocaml_agent_graph_demo.exe — Typed orchestration demo
  adaptive_webcrawler_demo.exe — Web crawler demo
  client.exe (public: ocaml-agent-graph-client) — Human terminal

test/         — Test suites (Alcotest)
  test_agent_graph.ml   — Main orchestration tests (routing, discussion, memory)
  test_client.ml        — Client-side tests
  test_demos.ml         — Demo smoke tests
  test_protocol.ml      — L0-envelope, L0-capability, L0.5-audit, L3-pattern
  test_coordination.ml  — L1-consensus, L2-pipeline

config/       — JSON runtime configuration
  runtime.json              — Default Kimi-based profile
  runtime.ollama.json       — Ollama local profile
  client.json               — Terminal client configuration
  client.ollama.json        — Ollama client configuration
  gateway.kimi-k2.6.json    — BulkheadLM gateway config
  memory_policy.json        — Swarm memory storage and compression policy
  discussion/personas/      — Versioned discussion personas
  discussion/rules/         — Versioned discussion rules
  prompts/                  — System prompt markdown files

doc/          — Operator guides (START_HERE.md, MULTI_MACHINE.md, etc.)
docs/         — API references (swarm-layers.md)
scripts/      — Starter and deployment shell scripts
  starter_common.sh, macos_starter.sh, linux_starter.sh, freebsd_starter.sh
  remote_human_terminal.sh, remote_machine_terminal.sh
  http_machine_server.sh, http_dist_server.sh
  remote_install.sh, bulkhead_gateway_common.sh
demos/        — Scenario packs and standalone demos
```

### Module naming convention

Source files use snake_case with a subsystem prefix:

- `core_*.ml` — Core types and primitives
- `runtime_*.ml` — Runtime infrastructure
- `orchestration_*.ml` — Routing and coordination
- `llm_*.ml` — LLM integration
- `agent_*.ml` / `*_agent.ml` — Agent interfaces and implementations
- `client_*.ml` — Client-side modules
- `memory_*.ml` — Memory subsystem
- `web_crawler_*.ml` — Web crawler modules

The public library module `lib/agent_graph.ml` re-exports them under clean
namespaces: `Core`, `Runtime`, `Orchestration`, `Agents`, `Llm`, `Client`,
`Memory`, `Web_crawler`, `Config`.

---

## Build and test commands

### Quick start (uses project-local opam switch)

```bash
./run.sh
```

This installs git/opam if missing, clones/updates BulkheadLM, builds
everything, and opens the human terminal.

### Manual build (assumes you manage your own opam switch)

```bash
# Pin the sibling dependency first
opam pin add bulkhead_lm ../bulkhead-lm --yes --no-action

# Install OCaml and test dependencies
opam install . --deps-only --with-test --yes

# Build everything
dune build
# or explicitly:
dune build @all

# Run all tests
dune runtest

# Run a specific test executable
dune exec test/test_protocol.exe
dune exec test/test_coordination.exe
dune exec test/test_agent_graph.exe

# Run demos
dune exec ./bin/ocaml_agent_graph_demo.exe
dune exec ./bin/adaptive_webcrawler_demo.exe
dune exec ./bin/client.exe
```

### Build artifacts

- `_build/default/lib/agent_graph.cma` / `.cmxa` — compiled library
- `_build/default/bin/ocaml_agent_graph_demo.exe`
- `_build/default/bin/adaptive_webcrawler_demo.exe`
- `_build/default/bin/client.exe`

---

## Code style guidelines

### OCaml formatting

- Run `ocamlformat` with the included `.ocamlformat`:
  - `profile = conventional`
- Keep lines reasonable; the project favors readability over compactness.

### Style preferences observed in the codebase

- **Explicit types and boundaries**: prefer record types and variant types over
  raw strings and tuples. Do not weaken typed routing.
- **Explicit module boundaries**: every subsystem has its own directory and a
  clean re-export path through `agent_graph.ml`.
- **No magic strings/numbers**: route names, timeouts, prompts, and thresholds
  belong in config files (`config/*.json`) or shared definitions — not inlined
  in business logic.
- **Auditable execution**: the runtime logs agent invocations, measures latency,
  and records events in the execution context. Do not remove event logging.
- **Lwt direct style**: use `open Lwt.Syntax` and `let* / let+` for promise
  binding.
- **Error handling**: return explicit `result` types or typed payloads
  (`Core.Payload.Error`) instead of raising exceptions at layer boundaries.

### `.intent` files

Many modules have a companion `.intent` file (e.g., `runtime_engine.ml` +
`runtime_engine.intent`). These are **not** code — they are design documents
that describe the purpose of the module and a numbered "linear intent" listing
the reasoning steps the module encodes.

When you modify a module, **update its `.intent` file** if the reasoning steps
change. The format is:

```text
Purpose
One-line summary of what this module does.

Linear intent
1. First design decision.
2. Second design decision.
...
```

---

## Testing instructions

### Test framework

Tests use **Alcotest**. Every test suite is a separate executable declared in
`test/dune`.

### Test organization

| File | Coverage |
|------|----------|
| `test_protocol.ml` | L0 envelope, L0 capability, L0.5 audit, L3 pattern |
| `test_coordination.ml` | L1 consensus, L2 pipeline |
| `test_agent_graph.ml` | Orchestrator routing, discussion workflow, memory persistence/compression, provider access tracking |
| `test_client.ml` | Client-side behavior |
| `test_demos.ml` | Demo smoke tests |

### Mocking strategy

The main test suite (`test_agent_graph.ml`) mocks the LLM layer using
`Bulkhead_lm.Provider_mock`. It builds a fake BulkheadLM runtime state with
pre-canned responses keyed by `route_model` name, then injects it through
`Runtime.Services.of_llm_client`. This allows testing the full orchestrator
without network calls.

### Writing new tests

- Use `open Agent_graph` to access public APIs.
- Use `Lwt_main.run` to execute Lwt promises in synchronous tests.
- Use `Alcotest.(check bool)`, `Alcotest.(check string)`, `Alcotest.(check int)`
  for assertions.
- Prefer testing observable outcomes (payload shape, context events, step count)
  over testing internal implementation details.
- When testing discussions, assert on `context.events` labels such as
  `"discussion.started"`, `"discussion.turn.completed"`.

### CI

GitHub Actions runs on `ubuntu-latest`:

1. Checks out this repo and the sibling `bulkhead-lm` repo.
2. Installs system deps: `libsqlite3-dev pkg-config m4 bubblewrap`.
3. Sets up OCaml 5.2.1.
4. Pins `bulkhead_lm`, installs deps, builds, tests.
5. Runs demo smoke coverage (`--help=plain` on each executable).

---

## Architecture

### Swarm layers (L0–L3)

The framework exposes four typed coordination layers. All are accessible after
`open Agent_graph`:

| Layer | Module | Purpose |
|-------|--------|---------|
| L0 | `Core.Envelope` | Message provenance: id, correlation_id, causation_id, schema_version |
| L0 | `Core.Capability` | Permission lattice: Observe < Speak < Coordinate < Audit_write |
| L0.5 | `Core.Audit` | Tamper-evident hash chain |
| L1 | `Orchestration.Consensus` | Quorum vote: parallel agents, majority required |
| L2 | `Orchestration.Pipeline` | Agent sequence with optional guards; errors halt the chain |
| L3 | `Core.Pattern` | Strategy fitness tracking: success rate, latency, confidence |

### Execution flow

Short input:
```text
user -> summarizer -> answer
```

Long input:
```text
user -> planner -> summarizer + validator (parallel) -> aggregator -> answer
```

Discussion enabled:
```text
user -> planner -> discussion (N rounds) -> summarizer -> answer
```

`/decide` command:
```text
topic -> discussion -> consensus vote -> validator -> pattern fitness -> audit chain -> archive
```

### Key runtime pieces

- `Runtime.Engine.run_agent` — runs one agent with timeout and retry.
- `Runtime.Parallel_executor` — runs agents in parallel.
- `Orchestration.Orchestrator.loop` — main graph dispatcher.
- `Orchestration.Graph` — decides the path (short vs long vs discussion).
- `Orchestration.Decider` — runs the full `/decide` workflow (L0-L3).

### Configuration-driven behavior

All routing, prompts, timeouts, retries, model selection, and discussion
parameters are loaded from `config/runtime.json`. The client behavior is
controlled by `config/client.json`. Never hardcode product behavior that could
be expressed in config.

### BulkheadLM integration

The framework does not call LLM providers directly. It speaks to a local
BulkheadLM gateway (default `http://127.0.0.1:4140`). The gateway config file
(`config/gateway.kimi-k2.6.json` by default) defines routes, backends, virtual
keys, and upstream models.

`Llm.Bulkhead_client` wraps the BulkheadLM HTTP API and converts responses into
the framework's payload types.

### Memory subsystem

`Memory.Store` persists conversation history in SQLite.
`Memory.Compressor` summarizes history when checkpoints are reached, governed by
`config/memory_policy.json`. `Memory.Bulkhead_bridge` can mirror sessions to the
BulkheadLM control plane.

---

## Development conventions

### Conventional Commits

All mergeable changes must use Conventional Commits:

- `feat: ...`
- `fix: ...`
- `docs: ...`
- `refactor: ...`, `test: ...`, `build: ...`, `ci: ...`, `chore: ...`
- Breaking changes: `feat!: ...` or include `BREAKING CHANGE:` in the body.

### Changelog policy

`CHANGELOG.md` is organized by commit type:

- `feat` → `Added`
- `fix` → `Fixed`
- `docs` → `Documentation`
- `refactor`/`test`/`build`/`ci`/`chore` → `Maintenance`

Only user-visible changes need changelog entries.

### Before submitting changes

- Preserve the module hierarchy in `lib/`.
- Keep graph execution auditable (events, logs, tests).
- Keep starter scripts thin wrappers; do not move product logic into shell.
- Update `README.md` and relevant docs for public-facing changes.
- Update tests for behavior changes.
- Open an issue before large features or major API changes.

---

## Deployment and runtime

### Local terminal

```bash
./run.sh
```

- Loads API keys from `~/.bashrc.secrets`, `~/.zshrc.secrets`, `~/.config/bulkhead-lm/env`, etc.
- Starts the BulkheadLM gateway automatically when the endpoint is loopback.
- Opens the interactive human terminal.

### Multi-machine

- `scripts/remote_human_terminal.sh` — SSH human terminal
- `scripts/remote_machine_terminal.sh` — Worker SSH JSONL terminal
- `scripts/http_machine_server.sh` — Workflow HTTP server
- `scripts/remote_install.sh --emit-installer` — SSH bootstrap installer

### Messenger connectors

Run `./scripts/start-with-messengers.sh` to start the swarm spokesperson server
alongside the gateway and terminal. Auto-detects Telegram, WhatsApp, Messenger,
etc. from environment tokens.

---

## Security considerations

- **API keys and tokens** must be exported through environment files loaded by
  the starter (e.g., `~/.bashrc.secrets`). The shipped `config/runtime.json`
  uses a placeholder token (`sk-bulkhead-lm-dev`) that the local gateway
  accepts; real provider keys belong in the gateway config or in env vars, not
  in committed files.
- **Audit chain**: `Core.Audit` produces tamper-evident logs. Changing any past
  entry invalidates all subsequent hashes. The `/decide` command archives the
  final chain to `var/decisions/`.
- **Capability tokens**: `Core.Capability` grants time-bounded permissions.
  Check `permits` and `is_valid` before dispatch.
- **Local operations**: the client has bounded local command execution
  (`local_ops.max_read_bytes`, `max_exec_output_bytes`, `command_timeout_ms`).
  Do not increase these without considering the blast radius.
- **Do not commit secrets**: `.gitignore` should already exclude build artifacts
  and local state; never add `*.secrets`, `*.env`, or SQLite files.

---

## Useful references

| File | What it is |
|------|------------|
| `lib/agent_graph.ml` | Public API facade |
| `lib/agent_graph.intent` | Design rationale for the facade |
| `docs/swarm-layers.md` | L0-L3 API reference with code examples |
| `doc/START_HERE.md` | First-time user guide |
| `doc/MAKE_YOUR_OWN_AGENT.md` | Developer guide for adding agents |
| `doc/MULTI_MACHINE.md` | Multi-machine deployment guide |
| `doc/MESSENGER_CONNECTORS.md` | Chat connector wiring |
| `doc/HUMAN_TERMINAL_ASSISTANT.md` | Terminal power user guide |
| `CONTRIBUTING.md` | Full contribution policy |
| `CHANGELOG.md` | Release history |
| `dune-project` | Package metadata and opam dependencies |
| `ocaml-agent-graph.opam` | Generated opam file (edit `dune-project` instead) |
