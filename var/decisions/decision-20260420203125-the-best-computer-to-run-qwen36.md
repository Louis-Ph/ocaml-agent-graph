# Decision Archive

- decision_id: decide-20260420203125-the-best-computer-to-run-qwen36
- archived_at: 20260420203125
- topic: the best computer to run qwen3.6
- rounds: 5
- pattern_id: decide-v1
- audit_chain_length: 8
- audit_verified: true
- head_hash: 9e80fa0d9950584469a4530c54b522d0

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
- head_hash: 9e80fa0d9950584469a4530c54b522d0

[00] decision.started                      548ed05f19d6
[01] decision.envelope.created             47435e7f0590
[02] decision.discussion.completed         e88505eec4e5
[03] decision.consensus.started            1f336c3630bd
[04] decision.consensus.completed          5d1dc15e2440
[05] decision.pipeline.skipped             a45554abdf09
[06] decision.pattern.recorded             b30a02c26ef2
[07] decision.sealed                       9e80fa0d9950
