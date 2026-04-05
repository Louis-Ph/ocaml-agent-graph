# Multi-Machine Workflows

`ocaml-agent-graph` now supports two terminal-facing lanes across machines:

- human lane: an interactive SSH terminal for operators
- worker lane: a programmatic interface over SSH JSONL or over HTTP JSON

The hierarchy remains explicit:

- `BulkheadLM` stays the provider gateway and route authority
- `ocaml-agent-graph` sits above it and exposes typed orchestration workflows

## Human Operator Over SSH

Use the human wrapper when a real person needs a TTY:

```sh
ssh -t user@host '/opt/ocaml-agent-graph/scripts/remote_human_terminal.sh'
```

That path is for operators, not for machine-to-machine traffic.

## Worker Over SSH

Use the worker wrapper when another program wants JSONL request/response traffic:

```sh
ssh -T user@host '/opt/ocaml-agent-graph/scripts/remote_machine_terminal.sh --jobs 4'
```

Example worker request line:

```json
{"id":"job-1","kind":"run_graph","request":{"task_id":"mesh-demo","input":"Plan a bounded swarm rollout."}}
```

## Worker Over HTTP

Start the HTTP workflow server on the remote machine:

```sh
/opt/ocaml-agent-graph/scripts/http_machine_server.sh --port 8087
```

Health check:

```sh
curl -fsS http://host:8087/health
```

Assistant call:

```sh
curl -fsS -X POST http://host:8087/v1/assistant \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Reply with OK."}'
```

Typed graph run:

```sh
curl -fsS -X POST http://host:8087/v1/run_graph \
  -H 'Content-Type: application/json' \
  -d '{"task_id":"mesh-demo","input":"Plan a bounded swarm rollout."}'
```

This HTTP path is suitable for a normal client/server split and also for direct
peer-style machine calls between two `ocaml-agent-graph` installations.

## SSH Bootstrap Install

If the client machine does not yet have a local checkout, a remote install can
emit an installer:

```sh
ssh user@host \
  '/opt/ocaml-agent-graph/scripts/remote_install.sh --emit-installer --origin user@host' \
  | sh
```

## HTTP Bootstrap Install

On the source machine:

```sh
/opt/ocaml-agent-graph/scripts/http_dist_server.sh \
  --public-base-url http://machine-a.example.net:8788
```

On the fresh target machine:

```sh
curl -fsSL http://machine-a.example.net:8788/install.sh | sh
```

The HTTP distribution server publishes:

- `/install.sh`
- `/ocaml-agent-graph.tar.gz`
- `/index.html`

## Pair-Style Topologies

Two common shapes are supported:

1. Normal client/server: one machine serves the HTTP workflow API and another
   machine calls it with `curl` or any JSON client.
2. Direct peer-style orchestration: one machine calls another over SSH worker
   JSONL or over the HTTP workflow API, while both keep their own local
   `BulkheadLM` routing context.

For BulkheadLM-level HTTP and SSH peer routing under the gateway itself, also read:

- `../bulkhead-lm/docs/SSH_REMOTE.md`
- `../bulkhead-lm/docs/PEER_MESH.md`
