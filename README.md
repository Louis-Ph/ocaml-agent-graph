# ocaml-agent-graph

[![CI](https://github.com/Louis-Ph/ocaml-agent-graph/actions/workflows/ci.yml/badge.svg)](https://github.com/Louis-Ph/ocaml-agent-graph/actions/workflows/ci.yml)

Typed, modular multi-agent orchestration in OCaml, shaped like a small
LangGraph/CrewAI runtime rather than a monolithic script.

![Human terminal assistant startup](doc/OCamlGraph.jpeg)

Illustration of the human terminal assistant at startup.

The project keeps the research-facing concerns explicit:

- typed agent identifiers instead of ad hoc strings
- hierarchical modules instead of a single file blob
- runtime policies externalized in [`config/runtime.json`](config/runtime.json)
- durable swarm memory policy externalized in [`config/memory_policy.json`](config/memory_policy.json)
- real LLM communication delegated to [`bulkhead_lm`](../bulkhead-lm/README.md)
- explicit graph routing, not implicit control flow
- retries, timeouts, parallel fan-out, aggregation, and audit context
- persistent SQLite-backed swarm memory with reload + checkpoint compression
- L0-L3 typed agentic swarm layers for protocol, audit, coordination, composition, and emergence
- `/decide` verifiable decision command wiring all five layers end-to-end
- `alcotest` coverage for all execution paths including the swarm layers

## Docs

Beginner-friendly documentation lives in [`doc/`](doc/README.md).

Start with:

- [`doc/START_HERE.md`](doc/START_HERE.md)
- [`doc/HUMAN_TERMINAL_ASSISTANT.md`](doc/HUMAN_TERMINAL_ASSISTANT.md)
- [`doc/MULTI_MACHINE.md`](doc/MULTI_MACHINE.md)
- [`doc/MAKE_YOUR_OWN_AGENT.md`](doc/MAKE_YOUR_OWN_AGENT.md)
- [`doc/RELEASING.md`](doc/RELEASING.md)
- [`docs/swarm-layers.md`](docs/swarm-layers.md) — L0-L3 swarm layer API reference

Project health and community docs:

- [`CHANGELOG.md`](CHANGELOG.md)
- [`CONTRIBUTING.md`](CONTRIBUTING.md)
- [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)
- [`SECURITY.md`](SECURITY.md)
- [`SUPPORT.md`](SUPPORT.md)
- [`LICENSE`](LICENSE)

## Demos

Scenario packs live in [`demos/`](demos/README.md).

The main procurement-oriented pack is:

- [`demos/professional_buyer/README.md`](demos/professional_buyer/README.md)
- [`demos/adaptive_webcrawler/README.md`](demos/adaptive_webcrawler/README.md)

## Structure

```text
ocaml-agent-graph/
  bin/
    ocaml_agent_graph_demo.ml
  config/
    discussion/
      personas/          versioned persona files for discussion participants
      rules/             versioned rules files for discussion participants
    memory_policy.json
    runtime.json
  docs/
    swarm-layers.md      L0-L3 swarm layer API reference
  lib/
    core/
      core_agent_name.ml
      core_message.ml
      core_payload.ml
      core_context.ml
      core_decision.ml
      core_envelope.ml   L0  — typed message envelope with provenance
      core_capability.ml L0  — permission lattice for agent access control
      core_audit.ml      L0.5 — append-only hash-chained audit log
      core_pattern.ml    L3  — pattern stability classification + fitness
    config/
      runtime_config.ml
    llm/
      llm_prompt.ml
      llm_bulkhead_client.ml
    memory/
      memory_bulkhead_bridge.ml
      memory_store.ml
      memory_compressor.ml
      memory_runtime.ml
    agents/
      agent_intf.ml
      planner_agent.ml
      summarizer_agent.ml
      validator_agent.ml
      default_agents.ml
    runtime/
      runtime_logger.ml
      runtime_registry.ml
      runtime_retry_policy.ml
      runtime_engine.ml
      runtime_parallel_executor.ml
      runtime_services.ml
    orchestration/
      orchestration_graph.ml
      orchestration_decider.ml
      orchestration_aggregator.ml
      orchestration_discussion.ml
      orchestration_orchestrator.ml
      orchestration_consensus.ml  L1 — quorum-based parallel coordination
      orchestration_pipeline.ml   L2 — composable agent sequence with guards
    client/
      client_decide.ml   L0-L3 verifiable decision session runner
      ...
    agent_graph.ml
  test/
    test_agent_graph.ml
    test_protocol.ml     L0-envelope, L0-capability, L0.5-audit, L3-pattern (27 cases)
    test_coordination.ml L1-consensus, L2-pipeline (8 cases)
```

## Execution Graph

```text
Text(short)  -> summarizer -> Stop
Text(long)   -> planner    -> Plan
Plan         -> [ summarizer || validator ] -> Batch -> Stop
Error/Batch  -> Stop
```

Optional discussion workflow (when `discussion.enabled = true`):

```text
Text(long)   -> planner -> Plan
Plan         -> discussion(participant_1 -> participant_2 -> ... for N rounds)
Discussion   -> summarizer/validator -> Stop
```

`/decide` verifiable decision flow (L0-L3):

```text
topic  ->  L0 envelope
       ->  L0.5 audit chain open
       ->  Phase 1: discussion (above)
       ->  Phase 2: L1 consensus (Planner + Summarizer + Validator vote)
       ->  Phase 3: L2 validation pipeline (Validator gate on winner)
       ->  Phase 4: L3 pattern fitness recording
       ->  audit chain seal + verify
       ->  archive to var/decisions/
```

That gives a strongly typed shape close to a tiny LangGraph:

- `orchestration_graph.ml` describes the routing states
- `orchestration_orchestrator.ml` executes the loop
- `orchestration_discussion.ml` runs the structured multi-agent discussion rounds
- `orchestration_consensus.ml` runs quorum-based parallel agent coordination (L1)
- `orchestration_pipeline.ml` runs composable agent sequences with guards (L2)
- `core_envelope.ml` carries typed message provenance across hops (L0)
- `core_audit.ml` maintains a hash-chained tamper-evident log (L0.5)
- `core_pattern.ml` tracks pattern fitness for emergent strategy selection (L3)
- `client_decide.ml` wires all five layers into one terminal command
- `llm_bulkhead_client.ml` talks to BulkheadLM and then to real provider routes
- `runtime_engine.ml` owns timeouts and retries
- `runtime_parallel_executor.ml` owns concurrent fan-out
- `core_context.ml` owns the auditable trace

## Swarm Layers (L0-L3)

All layers are accessible after `open Agent_graph`:

| Layer | Module | Purpose |
|-------|--------|---------|
| L0 | `Core.Envelope` | Typed message envelope with `id`, `correlation_id`, `causation_id`, `schema_version` |
| L0 | `Core.Capability` | Permission lattice `Observe ⊑ Speak ⊑ Coordinate ⊑ Audit_write` with token expiry |
| L0.5 | `Core.Audit` | Append-only hash-chained audit log; `verify_chain` replays from genesis |
| L1 | `Orchestration.Consensus` | Quorum-based coordination: `⌈n/2⌉+1` votes required, winner by max confidence |
| L2 | `Orchestration.Pipeline` | Composable `step` sequence with optional guard predicates, halts on error |
| L3 | `Core.Pattern` | Stability classes `Frozen/Stable/Fluid/Volatile`, fitness = `success_rate × avg_conf / (avg_latency_s + 1)` |

See [`docs/swarm-layers.md`](docs/swarm-layers.md) for the full API reference and usage examples.

## Quick start

The fastest path on any machine (Linux, macOS, FreeBSD):

```bash
curl -fsSL https://raw.githubusercontent.com/Louis-Ph/ocaml-agent-graph/main/install.sh | sh
```

or with wget:

```bash
wget -qO- https://raw.githubusercontent.com/Louis-Ph/ocaml-agent-graph/main/install.sh | sh
```

That single command installs git if needed, clones the repo and BulkheadLM,
installs the OCaml toolchain, and launches the human terminal. Press ENTER
through every prompt to accept the defaults.

If you already cloned the repo:

```bash
./run.sh
```

The starter:

- works on any Linux distro (Debian, Fedora, Arch, Alpine, openSUSE ...), macOS, and FreeBSD
- installs git and opam automatically via the detected package manager
- clones BulkheadLM as a sibling if missing, and auto-pulls the latest version on every run
- recompiles the BulkheadLM dependency when a new version is detected
- creates a project-local opam switch by default when the active toolchain is not coherent
- reuses provider API keys from `~/.bashrc.secrets`, `~/.zshrc.secrets`, and `~/.config/bulkhead-lm/env`

If you want the manual path instead:

```sh
opam pin add bulkhead_lm ../bulkhead-lm --yes --no-action
opam install . --deps-only --with-test --yes
dune build
dune runtest
```

## LLM Setup

The framework uses `BulkheadLM` for real chat calls:

- `config/runtime.json` chooses the `route_model` per agent
- the optional `discussion` block declares named participants, rounds, and the final synthesis agent
- each discussion participant can carry a versioned `persona` block and a versioned `rules` block loaded from `config/discussion/`
- `config/memory_policy.json` chooses how durable memory is stored, reloaded, and checkpoint-compressed
- `bulkhead-lm/config/example.gateway.json` chooses the provider routes
- provider API keys still come from the environment seen by `bulkhead_lm`
- startup validation checks that every configured agent route exists in the loaded gateway config
- agents and discussion participants can mix different `route_model` values across providers

The shipped demo config mixes providers on purpose:

- planner: `claude-sonnet`
- summarizer: `kimi-latest`
- validator: `openrouter-gpt-5.2`
- discussion participants: `claude-sonnet`, `kimi-k2.5`, `openrouter-auto`

## Messenger Spokesperson

Each client config can expose one client-facing swarm spokesperson through an
OpenAI-compatible endpoint:

- `POST /v1/messenger/chat/completions`
- `GET /v1/messenger/models`

The intended hierarchy is:

- `BulkheadLM` keeps ownership of Telegram, WhatsApp, Messenger, Discord, and other connector webhooks
- `ocaml-agent-graph` executes the real swarm and returns one spokesperson reply for the client

For the full wiring pattern, see
[`doc/MESSENGER_CONNECTORS.md`](doc/MESSENGER_CONNECTORS.md).

## Human Terminal Commands

| Command | Purpose |
|---------|---------|
| `/graph TXT` | Execute the typed graph directly |
| `/discussion TXT` | Force the multi-agent discussion path |
| `/decide TXT [--rounds N] [--pattern ID]` | Verifiable L0-L3 decision session |
| `/models` | List BulkheadLM route models |
| `/inspect` | Show graph and route summary |
| `/mesh` | SSH, HTTP, and install transport map |
| `/wizard TXT` | Proactive guided workflow |
| `/docs TOPIC` | Surface relevant local documentation |

The `/decide` command runs a full verifiable decision session:
1. Opens an L0.5 audit chain
2. Wraps the topic in an L0 envelope
3. Runs the configured discussion rounds
4. Runs L1 quorum consensus across all three agents
5. Gates the winner through an L2 validator pipeline
6. Records L3 pattern fitness
7. Seals and verifies the audit chain
8. Archives to `var/decisions/` with the chain `head_hash`

## Demo

```bash
curl -fsSL https://raw.githubusercontent.com/Louis-Ph/ocaml-agent-graph/main/install.sh | sh
```

This installs everything and starts the human terminal client directly.

For the typed demo binary:

```sh
dune exec ./bin/ocaml_agent_graph_demo.exe
```

Run the real adaptive webcrawler demo:

```sh
dune exec ./bin/adaptive_webcrawler_demo.exe
```

## Multi-Machine

This repository ships explicit multi-machine entrypoints:

- human SSH terminal: `scripts/remote_human_terminal.sh`
- worker SSH JSONL terminal: `scripts/remote_machine_terminal.sh`
- workflow HTTP server: `scripts/http_machine_server.sh`
- SSH bootstrap installer: `scripts/remote_install.sh --emit-installer`
- HTTP bootstrap server: `scripts/http_dist_server.sh`

For the focused guide, see [`doc/MULTI_MACHINE.md`](doc/MULTI_MACHINE.md).

## Why This Version Is Better Than The Draft

The initial sketch proved the control-flow idea. This repository turns it into a
real codebase:

- the graph policy is separated from the engine
- the engine is separated from the agent registry
- the LLM provider layer is separated from both and injected as a runtime service
- the policies are configurable without touching code
- the payload model carries provenance and execution metrics
- L0-L3 swarm layers give typed provenance, tamper-evident audit, quorum coordination, composable pipelines, and emergent pattern fitness
- the `/decide` command makes any decision topic traceable and verifiable end-to-end
- the tests prove all execution paths including the L0-L3 swarm layer contracts
