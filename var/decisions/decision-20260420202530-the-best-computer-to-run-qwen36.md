# Decision Archive

- decision_id: decide-20260420202530-the-best-computer-to-run-qwen36
- archived_at: 20260420202530
- topic: the best computer to run qwen3.6
- rounds: 5
- pattern_id: decide-v1
- audit_chain_length: 8
- audit_verified: true
- head_hash: 024713d98775406992a80a7e37ae8ef5

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
- head_hash: 024713d98775406992a80a7e37ae8ef5

[00] decision.started                      5dce7a0ad05a
[01] decision.envelope.created             f97568122649
[02] decision.discussion.completed         59a9ce8a3296
[03] decision.consensus.started            68ae23e42571
[04] decision.consensus.completed          14b76de15b10
[05] decision.pipeline.skipped             70120c80e039
[06] decision.pattern.recorded             c345bf0d9730
[07] decision.sealed                       024713d98775
