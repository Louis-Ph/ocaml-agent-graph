# ocaml-agent-graph

it is currently just an attempt, made public in order to open some apetites!..

Overview discussion: <https://github.com/Louis-Ph/ocaml-agent-graph/discussions/1>

[![CI](https://github.com/Louis-Ph/ocaml-agent-graph/actions/workflows/ci.yml/badge.svg)](https://github.com/Louis-Ph/ocaml-agent-graph/actions/workflows/ci.yml)

Typed, modular multi-agent orchestration in OCaml, shaped like a small
LangGraph/CrewAI runtime rather than a monolithic script.

![Human terminal assistant startup](doc/OCamlGraph.jpeg)

Illustration of the human terminal assistant at startup.

The project keeps the research-facing concerns explicit:

- typed agent identifiers instead of ad hoc strings
- hierarchical modules instead of a single file blob
- runtime policies externalized in [`config/runtime.json`](config/runtime.json)
- real LLM communication delegated to [`bulkhead_lm`](../bulkhead-lm/README.md)
- explicit graph routing, not implicit control flow
- retries, timeouts, parallel fan-out, aggregation, and audit context
- `alcotest` coverage for the simple and parallel execution paths

## Docs

Beginner-friendly documentation lives in [`doc/`](doc/README.md).

Start with:

- [`doc/START_HERE.md`](doc/START_HERE.md)
- [`doc/HUMAN_TERMINAL_ASSISTANT.md`](doc/HUMAN_TERMINAL_ASSISTANT.md)
- [`doc/MULTI_MACHINE.md`](doc/MULTI_MACHINE.md)
- [`doc/MAKE_YOUR_OWN_AGENT.md`](doc/MAKE_YOUR_OWN_AGENT.md)
- [`doc/RELEASING.md`](doc/RELEASING.md)

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
    runtime.json
  lib/
    core/
      core_agent_name.ml
      core_message.ml
      core_payload.ml
      core_context.ml
      core_decision.ml
    config/
      runtime_config.ml
    llm/
      llm_prompt.ml
      llm_bulkhead_client.ml
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
      orchestration_orchestrator.ml
    agent_graph.ml
  test/
    test_agent_graph.ml
```

## Execution Graph

```text
Text(short)  -> summarizer -> Stop
Text(long)   -> planner    -> Plan
Plan         -> [ summarizer || validator ] -> Batch -> Stop
Error/Batch  -> Stop
```

That gives a strongly typed shape close to a tiny LangGraph:

- `orchestration_graph.ml` describes the routing states
- `orchestration_orchestrator.ml` executes the loop
- `llm_bulkhead_client.ml` talks to BulkheadLM and then to real provider routes
- `runtime_engine.ml` owns timeouts and retries
- `runtime_parallel_executor.ml` owns concurrent fan-out
- `core_context.ml` owns the auditable trace

## Build

```sh
./run.sh
```

The starter:

- checks the active `opam` switch first
- offers a project-local fallback switch in `./_opam` when needed
- auto-clones `../bulkhead-lm` if the sibling checkout is missing
- pins `bulkhead_lm`, installs dependencies, builds the human terminal client, and launches it
- keeps SSH and HTTP bootstrap entrypoints ready for multi-machine rollout
- reuses provider keys from your usual shell secret files and `~/.config/bulkhead-lm/env`

If you want the manual path instead:

```sh
opam pin add bulkhead_lm ../bulkhead-lm --yes --no-action
opam install . --deps-only --with-test --yes
dune build
dune runtest
```

## LLM Setup

The framework now uses `BulkheadLM` for real chat calls:

- `config/runtime.json` chooses the `route_model` per agent
- `bulkhead-lm/config/example.gateway.json` chooses the provider routes
- provider API keys still come from the environment seen by `bulkhead_lm`
- startup validation now checks that every configured agent route exists in the loaded BulkheadLM gateway config
- `BulkheadLM` remains the router/provider layer that yields the rudimentary route-bound agents composed here into typed swarms

The shipped demo config currently uses the `claude-sonnet` route through
`BulkheadLM`.

## Demo

```sh
./run.sh
```

This starts the human terminal client directly.

For the typed demo binary:

```sh
dune exec ./bin/ocaml_agent_graph_demo.exe
```

Run the real adaptive webcrawler demo:

```sh
dune exec ./bin/adaptive_webcrawler_demo.exe
```

Override the default prompt:

```sh
dune exec ./bin/ocaml_agent_graph_demo.exe -- \
  "Design an OCaml agent runtime with explicit graph routing and parallel validation."
```

The live path is:

```text
agent_graph -> runtime_services -> llm_bulkhead_client -> BulkheadLM Router -> provider backend
```

Inside the human terminal, use `/wizard ...` for guided operator workflows and
`/docs ...` to surface the most relevant local documentation. The terminal also
surfaces `/mesh`, `/http-server`, `/curl`, `/install-ssh`, and `/install-http`
for multi-machine operation.

For the human terminal assistant contract and operating hierarchy, see
[`doc/HUMAN_TERMINAL_ASSISTANT.md`](doc/HUMAN_TERMINAL_ASSISTANT.md).

## Multi-Machine

This repository now ships explicit multi-machine entrypoints:

- human SSH terminal: `scripts/remote_human_terminal.sh`
- worker SSH JSONL terminal: `scripts/remote_machine_terminal.sh`
- workflow HTTP server: `scripts/http_machine_server.sh`
- SSH bootstrap installer: `scripts/remote_install.sh --emit-installer`
- HTTP bootstrap server: `scripts/http_dist_server.sh`

Human remote session over SSH:

```sh
ssh -t user@remote '/opt/ocaml-agent-graph/scripts/remote_human_terminal.sh'
```

Programmatic worker over SSH:

```sh
ssh -T user@remote '/opt/ocaml-agent-graph/scripts/remote_machine_terminal.sh --jobs 4'
```

Programmatic worker over HTTP:

```sh
/opt/ocaml-agent-graph/scripts/http_machine_server.sh --port 8087
curl -fsS -X POST http://host:8087/v1/run_graph \
  -H 'Content-Type: application/json' \
  -d '{"task_id":"mesh-demo","input":"Plan a bounded swarm rollout."}'
```

Bootstrap a fresh machine over SSH:

```sh
ssh user@remote \
  '/opt/ocaml-agent-graph/scripts/remote_install.sh --emit-installer --origin user@remote' \
  | sh
```

Bootstrap a fresh machine over HTTP:

```sh
/opt/ocaml-agent-graph/scripts/http_dist_server.sh \
  --public-base-url http://machine-a.example.net:8788
curl -fsSL http://machine-a.example.net:8788/install.sh | sh
```

For the focused guide, see [`doc/MULTI_MACHINE.md`](doc/MULTI_MACHINE.md).

## Why This Version Is Better Than The Draft

The initial sketch proved the control-flow idea. This repository turns it into a
real codebase:

- the graph policy is separated from the engine
- the engine is separated from the agent registry
- the LLM provider layer is separated from both and injected as a runtime service
- the policies are configurable without touching code
- the payload model carries provenance and execution metrics
- the tests prove both the linear route and the planning/fan-out route
