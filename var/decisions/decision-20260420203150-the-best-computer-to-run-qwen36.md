# Decision Archive

- decision_id: decide-20260420203150-the-best-computer-to-run-qwen36
- archived_at: 20260420203150
- topic: the best computer to run qwen3.6
- rounds: 5
- pattern_id: decide-v1
- audit_chain_length: 8
- audit_verified: true
- head_hash: 9c96cdd1b5722a61db31c2130754728a

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
- head_hash: 9c96cdd1b5722a61db31c2130754728a

[00] decision.started                      908873743d60
[01] decision.envelope.created             f451c57c2233
[02] decision.discussion.completed         ab0b794fd9e3
[03] decision.consensus.started            4b89d756299b
[04] decision.consensus.completed          75c2b19e729b
[05] decision.pipeline.skipped             7a3cad9ca9af
[06] decision.pattern.recorded             566faaa07f98
[07] decision.sealed                       9c96cdd1b572
