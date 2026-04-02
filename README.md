# ocaml-agent-graph

Typed, modular multi-agent orchestration in OCaml, shaped like a small
LangGraph/CrewAI runtime rather than a monolithic script.

The project keeps the research-facing concerns explicit:

- typed agent identifiers instead of ad hoc strings
- hierarchical modules instead of a single file blob
- runtime policies externalized in [`config/runtime.json`](config/runtime.json)
- explicit graph routing, not implicit control flow
- retries, timeouts, parallel fan-out, aggregation, and audit context
- `alcotest` coverage for the simple and parallel execution paths

## Docs

Beginner-friendly documentation lives in [`doc/`](doc/README.md).

Start with:

- [`doc/START_HERE.md`](doc/START_HERE.md)
- [`doc/MAKE_YOUR_OWN_AGENT.md`](doc/MAKE_YOUR_OWN_AGENT.md)

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
- `runtime_engine.ml` owns timeouts and retries
- `runtime_parallel_executor.ml` owns concurrent fan-out
- `core_context.ml` owns the auditable trace

## Build

```sh
opam install . --deps-only --with-test --yes
dune build
dune runtest
```

## Demo

```sh
dune exec ./bin/ocaml_agent_graph_demo.exe
```

Override the default prompt:

```sh
dune exec ./bin/ocaml_agent_graph_demo.exe -- \
  "Design an OCaml agent runtime with explicit graph routing and parallel validation."
```

## Why This Version Is Better Than The Draft

The initial sketch proved the control-flow idea. This repository turns it into a
real codebase:

- the graph policy is separated from the engine
- the engine is separated from the agent registry
- the policies are configurable without touching code
- the payload model carries provenance and execution metrics
- the tests prove both the linear route and the planning/fan-out route
