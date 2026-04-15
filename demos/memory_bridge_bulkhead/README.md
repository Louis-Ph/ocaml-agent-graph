# Memory Bridge Demo

This demo makes the memory chain visible end to end:

1. `ocaml-agent-graph` accumulates several turns under one `session_id`.
2. The Fibonacci memory policy compresses the durable session.
3. The bridge sends `PUT /_bulkhead/control/api/memory/session` to `BulkheadLM`.
4. The demo fetches the mirrored session back from the BulkheadLM control plane.

## What it proves

- the compression rule is now explicit and configurable
- the value hierarchy used during compression is externalized in JSON
- a real `memory.compressed` event appears in the graph output
- the mirrored remote session can be inspected immediately through `BulkheadLM`

## Requirements

Set one supported provider key before running:

- `OPEN_ROUTER_KEY`
- `ANTHROPIC_API_KEY`
- `OPENAI_API_KEY`
- `GOOGLE_API_KEY`

The script auto-detects the first available provider in that order.

## Run

```sh
./demos/memory_bridge_bulkhead/run.sh
```

The demo keeps its generated files under `var/memory-bridge-demo/`, including:

- generated `gateway.json`, `runtime.json`, `client.json`, and `memory_policy.json`
- each turn response from `ocaml-agent-graph`
- the final mirrored session fetched from `BulkheadLM`

## Expected signal

In the last graph response, look for the event label:

```text
memory.compressed
```

In the final BulkheadLM session JSON, look for:

- `summary`
- `compressed_turn_count`
- `recent_turns`
- `stats.summary_char_count`
