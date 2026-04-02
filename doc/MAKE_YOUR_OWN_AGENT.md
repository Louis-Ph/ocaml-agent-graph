# Make Your Own Agent

This guide shows how to add a new helper.

## Step 1: Create The New File

Make a file in:

```text
lib/agents/
```

Example:

```text
lib/agents/explainer_agent.ml
```

## Step 2: Give The Agent A Name

Add the new name in:

```text
lib/core/core_agent_name.ml
```

That file is the official list of agent names.

## Step 3: Follow The Agent Shape

Each agent follows the same rule:

- it has an `id`
- it has a `run` function
- it receives `services`
- it receives `context`
- it receives `payload`
- it returns a new payload, some metrics, and notes

You can copy the shape of:

- `lib/agents/planner_agent.ml`
- `lib/agents/summarizer_agent.ml`
- `lib/agents/validator_agent.ml`

## Step 4: Register The Agent

Open:

```text
lib/agents/default_agents.ml
```

Add your new agent to the list.

If you skip this step, the framework will not know your agent exists.

## Step 5: Let The Graph Use It

Open:

```text
lib/orchestration/orchestration_graph.ml
```

This file decides which agent runs next.

Add a rule for your new agent if you want the framework to choose it.

## Step 6: Test It

Run:

```sh
dune runtest
```

If needed, add a new test in:

```text
test/test_agent_graph.ml
```

## Good Rule

Keep one clear job per agent.

That makes the framework easier to grow, easier to test, and easier to trust.
