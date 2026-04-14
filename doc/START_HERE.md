# Start Here

This framework is like a small team of robot helpers.

You give the team one job.
The framework decides which helper should work next.
Sometimes one helper works alone.
Sometimes two helpers work at the same time.
Then the framework puts the answers together.

## The Big Idea

Think about a school project:

- one kid makes a plan
- one kid writes a short summary
- one kid checks if the work looks correct

That is what this framework does, but in OCaml code.

## What Is In This Project?

```text
bin/     = the button you run
config/  = the settings
docs/    = the swarm layer API reference
doc/     = the operator guides
lib/     = the real framework code
test/    = the safety checks
```

Inside `lib/`, the code is split into small jobs:

- `core/` holds the main shared types and the L0-L3 swarm layer primitives
- `llm/` talks to BulkheadLM
- `agents/` holds the helpers
- `runtime/` runs helpers with retries and time limits
- `orchestration/` decides the path through the graph, runs discussions, consensus, and pipelines
- `client/` holds the human terminal, the machine worker, and the decision runner

## What Happens When You Run It?

If the text is short:

```text
your text -> summarizer -> done
```

If the text is longer:

```text
your text -> planner -> summarizer + validator -> merged result
```

If discussion is enabled in `config/runtime.json`:

```text
your text -> planner -> discussion(participant rounds) -> summarizer -> done
```

If you use the `/decide` command, it runs a full verifiable decision:

```text
topic
  -> discussion (as above)
  -> consensus: all three agents vote on the result
  -> validation: the winning vote gets checked by the validator
  -> pattern fitness recorded
  -> audit chain sealed and verified
  -> archive saved to var/decisions/
```

## How To Run It

Open a terminal in this project folder.

Then run:

```sh
./run.sh
```

The starter script:

- prepares an `opam` environment if needed
- clones `../bulkhead-lm` automatically if it is missing
- pins the local `bulkhead_lm` dependency
- builds the human terminal client
- opens the human terminal directly

Inside the terminal, you can:

- chat with the assistant
- run `/graph ...` to execute the typed orchestration graph
- run `/discussion ...` to force the multi-agent discussion path
- run `/decide TOPIC [--rounds N] [--pattern ID]` for a verifiable decision session
- run `/wizard ...` for build, test, install, cron, messenger, ssh, http, peer, or swarm guidance
- run `/docs ...` to surface the most relevant local documentation
- run `/mesh` to print the SSH and HTTP transport map
- run `/curl` to print HTTP workflow examples
- inspect graph routes and config
- attach files
- browse the workspace
- run approved local commands

For a focused multi-machine guide, also read:

- [MULTI_MACHINE.md](MULTI_MACHINE.md)
- [MESSENGER_CONNECTORS.md](MESSENGER_CONNECTORS.md)

## The Swarm Layers (L0-L3)

The framework now ships five typed coordination layers that any OCaml program
can use directly by opening `Agent_graph`:

| Layer | What it does |
|-------|-------------|
| L0 `Core.Envelope` | Wraps any payload with `id`, `correlation_id`, `causation_id`, and `schema_version` for full message provenance |
| L0 `Core.Capability` | Grants agents the minimum permission they need: `Observe`, `Speak`, `Coordinate`, or `Audit_write` |
| L0.5 `Core.Audit` | Keeps a tamper-evident hash-chained log; changing any past entry breaks every hash that follows it |
| L1 `Orchestration.Consensus` | Runs agents in parallel and requires a quorum of successful votes before picking a winner |
| L2 `Orchestration.Pipeline` | Chains agents in order; a guard can skip a step; an error stops the chain immediately |
| L3 `Core.Pattern` | Names coordination strategies, tracks their success rate and latency, and computes a fitness score |

The `/decide` command wires all five layers together for any topic you give it.

For the complete API reference and code examples, see
[`docs/swarm-layers.md`](../docs/swarm-layers.md).

## How To Try Your Own Text

Run this:

```sh
dune exec ./bin/ocaml_agent_graph_demo.exe -- \
  "Build a safe OCaml agent system with planning and checking."
```

Put your own sentence between the quotes.

## How To Change The Settings

Open:

```text
config/runtime.json
```

This file is the control panel.

You can change:

- the timeout
- the number of retries
- when a text counts as "long"
- which agents run in parallel
- which `route_model` each agent uses through BulkheadLM
- which BulkheadLM gateway config file is used
- whether the discussion workflow is enabled and how many rounds it runs

You do not need to change the OCaml code just to change these settings.

## How To Know If It Still Works

Run:

```sh
dune runtest
```

If the tests are green, the framework still behaves the way the project expects.
The test suite covers the linear route, the planning route, the discussion
workflow, and all L0-L3 swarm layer contracts.

## What The Main Parts Do

`lib/orchestration/orchestration_graph.ml`

- decides the path

`lib/runtime/runtime_engine.ml`

- runs one agent
- handles retry
- handles timeout

`lib/runtime/runtime_parallel_executor.ml`

- runs many agents at once

`lib/orchestration/orchestration_aggregator.ml`

- puts many answers into one batch

`lib/orchestration/orchestration_consensus.ml`

- runs agents in parallel and counts successful votes (L1)

`lib/orchestration/orchestration_pipeline.ml`

- runs agents in sequence with optional guard predicates (L2)

`lib/core/core_audit.ml`

- keeps the tamper-evident hash-chained log (L0.5)

`lib/client/client_decide.ml`

- runs the full L0-L3 verifiable decision session

`lib/agents/`

- contains the helpers themselves

## A Simple Way To Read The Output

When you see:

- `planner`, the framework is making a step-by-step plan
- `summarizer`, the framework is making things shorter
- `validator`, the framework is checking if the result looks okay
- `consensus: quorum_reached`, all or most agents agreed
- `audit_verified: true`, the tamper-evident chain is intact

## If You Want To Learn More

Go next to:

- [MAKE_YOUR_OWN_AGENT.md](MAKE_YOUR_OWN_AGENT.md)
- [docs/swarm-layers.md](../docs/swarm-layers.md) for the L0-L3 API reference
