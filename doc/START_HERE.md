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
doc/     = the guides
lib/     = the real framework code
test/    = the safety checks
```

Inside `lib/`, the code is split into small jobs:

- `core/` holds the main shared types
- `llm/` talks to BulkheadLM
- `agents/` holds the helpers
- `runtime/` runs helpers with retries and time limits
- `orchestration/` decides the path through the graph

## What Happens When You Run It?

If the text is short:

```text
your text -> summarizer -> done
```

If the text is longer:

```text
your text -> planner -> summarizer + validator -> merged result
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

You will see:

- which agent ran
- what the framework decided
- the final result

This project also needs `BulkheadLM`.

`./run.sh` prepares that local dependency for you.

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

You do not need to change the OCaml code just to change these settings.

## How To Know If It Still Works

Run:

```sh
dune runtest
```

If the tests are green, the framework still behaves the way the project expects.

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

`lib/agents/`

- contains the helpers themselves

## A Simple Way To Read The Output

When you see:

- `planner`, the framework is making a step-by-step plan
- `summarizer`, the framework is making things shorter
- `validator`, the framework is checking if the result looks okay

## If You Want To Learn More

Go next to:

- [MAKE_YOUR_OWN_AGENT.md](MAKE_YOUR_OWN_AGENT.md)
