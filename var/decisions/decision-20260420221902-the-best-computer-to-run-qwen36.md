# Decision Archive

- decision_id: decide-20260420221902-the-best-computer-to-run-qwen36
- archived_at: 20260420221902
- topic: the best computer to run qwen3.6
- rounds: 5
- pattern_id: decide-v1
- audit_chain_length: 8
- audit_verified: true
- head_hash: 18ee49ce84b2cfe5423968d4d76e6015

## Discussion

- payload: Error(Summarizer LLM call failed: HTTP 404 404 Not Found: {"error":{"message":"Upstream status 404: {\"error\":{\"message\":\"model 'qwen3.6:35b' not found\",\"type\":\"not_found_error\",\"param\":null,\"code\":null}}\n","type":"api_error","code":"upstream_failure"}})
- step_count: 1

```text
Error: Summarizer LLM call failed: HTTP 404 404 Not Found: {"error":{"message":"Upstream status 404: {\"error\":{\"message\":\"model 'qwen3.6:35b' not found\",\"type\":\"not_found_error\",\"param\":null,\"code\":null}}\n","type":"api_error","code":"upstream_failure"}}
```

## Consensus (L1)

- outcome: no_quorum
- required: 2
- received: 0

## Validation (L2)

- result: _skipped — no quorum_

## Pattern Fitness (L3)

- pattern_id: decide-v1
- invocations: 1
- success_count: 0
- fitness: 0.0000

## Audit Chain (L0.5)

- verified: true
- head_hash: 18ee49ce84b2cfe5423968d4d76e6015

[00] decision.started                      c7bce5b4efa1
[01] decision.envelope.created             05e4a7b2311a
[02] decision.discussion.completed         669da3cb8c4a
[03] decision.consensus.started            1249f295b092
[04] decision.consensus.completed          a320fdc92c55
[05] decision.pipeline.skipped             7ae39f475637
[06] decision.pattern.recorded             ff0b10db1556
[07] decision.sealed                       18ee49ce84b2
