# ocaml-agent-graph

Typed, modular multi-agent orchestration in OCaml, shaped like a small
LangGraph/CrewAI runtime rather than a monolithic script.

The project keeps the research-facing concerns explicit:

- typed agent identifiers instead of ad hoc strings
- hierarchical modules instead of a single file blob
- runtime policies externalized in [`config/runtime.json`](config/runtime.json)
- real LLM communication delegated to [`aegis_lm`](../aegis-lm/README.md)
- explicit graph routing, not implicit control flow
- retries, timeouts, parallel fan-out, aggregation, and audit context
- `alcotest` coverage for the simple and parallel execution paths

## Docs

Beginner-friendly documentation lives in [`doc/`](doc/README.md).

Start with:

- [`doc/START_HERE.md`](doc/START_HERE.md)
- [`doc/MAKE_YOUR_OWN_AGENT.md`](doc/MAKE_YOUR_OWN_AGENT.md)

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
      llm_aegis_client.ml
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
- `llm_aegis_client.ml` talks to AegisLM and then to real provider routes
- `runtime_engine.ml` owns timeouts and retries
- `runtime_parallel_executor.ml` owns concurrent fan-out
- `core_context.ml` owns the auditable trace

## Build

```sh
opam pin add aegis_lm /Users/columeaulouis-philippe/dev/github/aegis-lm --yes --no-action
opam install . --deps-only --with-test --yes
dune build
dune runtest
```

`aegis_lm` is a sibling local library in this setup.

## LLM Setup

The framework now uses `AegisLM` for real chat calls:

- `config/runtime.json` chooses the `route_model` per agent
- `aegis-lm/config/example.gateway.json` chooses the provider routes
- provider API keys still come from the environment seen by `aegis_lm`
- startup validation now checks that every configured agent route exists in the loaded AegisLM gateway config

The shipped demo config currently uses the `claude-sonnet` route through
`AegisLM`.

## Demo

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
agent_graph -> runtime_services -> llm_aegis_client -> AegisLM Router -> provider backend
```

## Why This Version Is Better Than The Draft

The initial sketch proved the control-flow idea. This repository turns it into a
real codebase:

- the graph policy is separated from the engine
- the engine is separated from the agent registry
- the LLM provider layer is separated from both and injected as a runtime service
- the policies are configurable without touching code
- the payload model carries provenance and execution metrics
- the tests prove both the linear route and the planning/fan-out route
