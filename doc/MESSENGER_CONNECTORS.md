# Messenger Connectors

This document defines the clean hierarchy for messenger-facing clients.

## Hierarchy

`BulkheadLM` remains the messenger transport and webhook edge.

It should continue to own:

- Telegram, WhatsApp, Messenger, Discord, and other webhook protocols
- connector verification and signature handling
- per-channel session memory
- outbound channel-specific reply delivery

`ocaml-agent-graph` remains the swarm runtime and the client-facing spokesperson.

It should own:

- the typed swarm execution itself
- the internal planner / summarizer / validator orchestration
- the final client-facing answer spoken in one voice on behalf of the swarm

## Integration Pattern

Expose the workflow server from this repository:

- `ocaml-agent-graph-client serve-http --client-config config/client.json --port 8087`

Use the OpenAI-compatible messenger spokesperson endpoint from this repository as
the upstream `api_base` for a `BulkheadLM` `openai_compat` route:

- `http://127.0.0.1:8087/v1/messenger`

`BulkheadLM` will append:

- `/chat/completions`

So the effective spokesperson endpoint is:

- `http://127.0.0.1:8087/v1/messenger/chat/completions`

## Public Versus Internal Models

The client config defines two distinct layers:

- `public_model`: the external model name exposed to `BulkheadLM` connectors
- `route_model`: the internal `BulkheadLM` route used here to narrate the final client reply

This separation is intentional:

- the messenger edge should see one stable spokesperson model
- the internal graph may still use different planner, summarizer, validator, and spokesperson routes

## Example Wiring

In `ocaml-agent-graph` client config:

- enable `messenger_spokesperson`
- choose `public_model = "swarm-spokesperson"`
- choose the internal `route_model`
- configure `authorization_token_env` if you want the endpoint protected

In the sibling `bulkhead-lm` gateway config:

- create an `openai_compat` backend whose `api_base` points to `http://127.0.0.1:8087/v1/messenger`
- set `upstream_model` to the `public_model`
- set `api_key_env` to the same bearer token expected by `ocaml-agent-graph`
- point the Telegram / WhatsApp / Messenger connector `route_model` to that route

## Operational Effect

With this wiring:

- the client speaks through Telegram, WhatsApp, or another messenger
- `BulkheadLM` handles the messenger protocol edge
- `ocaml-agent-graph` executes the real swarm
- one spokesperson reply is returned to the messenger client on behalf of the swarm
