# Concept: Continuous Improvement Loop for /decide

Status: design concept, not yet implemented.

## Core Insight

Memory is to space what perception is to time. A decision system that only
perceives (reads the prompt) and memorizes (archives the transcript) is half
blind. It also needs selective forgetting and anticipation.

## The Four Quadrants

|                  | Space (coexistence)              | Time (succession)                  |
|------------------|----------------------------------|------------------------------------|
| **Accumulate**   | Memory — store durable facts     | Perception — capture what arrives  |
| **Eliminate**     | Selective forgetting — purge noise | Anticipation — pre-stage what comes next |

## Proposed Stages for /decide

### 1. RECALL (memory, positive — exists partially via L3 pattern fitness)

Before the discussion begins, search `var/decisions/` and `var/knowledge/` for
prior decisions on similar topics. Inject relevant findings into the discussion
context so the swarm does not rediscover known facts.

### 2. DISCUSS (perception, positive — exists today)

The current aeropage: advisor, critic, synthesizer, sub-discussions, convergence
detection.

### 3. DISTILL (memory, positive — new)

After the decision, extract durable facts from the transcript and store them in
`var/knowledge/` as a cross-decision fact index. Facts outlive the decision that
produced them.

Example facts:
- "angel-berger.de: reliable, ships to Bavaria in 2-3 days"
- "Shimano Stradic C2000S: 115 EUR, good match for 7m Bolognese rod"

### 4. VALIDATE (perception, positive — new)

Verify extracted facts against external sources before promoting them to durable
knowledge. Three validation levels:

- **Level 0 — unverified**: raw extraction from discussion, may contain
  hallucinated prices or specs
- **Level 1 — web-checked**: confirmed via web search (webcrawler demo
  infrastructure reusable here)
- **Level 2 — document-checked**: confirmed against a local document corpus
  or authoritative reference

Granularity: each fact carries a validation level and a timestamp. Stale facts
decay to level 0 after a configurable TTL.

### 5. DECIDE (consensus + validation — exists today)

L1 quorum consensus, L2 validation pipeline, L3 pattern fitness. Unchanged.

### 6. FORGET (memory, negative — new)

Compress old decisions in `var/decisions/`. Keep patterns and distilled facts,
purge full transcripts. Reuse the Fibonacci compression policy already
implemented for conversation memory.

### 7. PRIME (time, negative — new)

After a decision, anticipate probable follow-up topics and pre-stage lightweight
research seeds in `var/primed/`. Not executed, just ready. When a future
`/decide` matches a primed topic, the recall phase starts warm instead of cold.

Example primed seeds after a fishing reel decision:
- "nylon line 0.16-0.18mm for Bolognese"
- "Bolognese fishing technique for beginners"
- "reel maintenance schedule"

## Learning Tool (future)

A dedicated `/learn` command or background process that:

1. Periodically reviews `var/knowledge/` for fact staleness
2. Re-validates decayed facts via web search
3. Promotes frequently-used facts to higher confidence
4. Surfaces patterns across decisions ("you always prefer German retailers
   with free shipping" → durable preference)
5. Feeds validated knowledge back into RECALL for future decisions

## Implementation Priority

1. DISTILL + fact index (low effort, high impact)
2. RECALL from fact index (medium effort, high impact)
3. FORGET with Fibonacci compression (low effort, medium impact)
4. VALIDATE with web search (medium effort, high impact — reuses webcrawler)
5. PRIME with seed generation (low effort, medium impact)
6. Learning tool (high effort, long-term value)

## Relationship to Existing Architecture

- RECALL and DISTILL use `var/knowledge/` (new directory, JSON fact store)
- FORGET reuses `Memory.Compression` from the existing memory policy
- VALIDATE reuses the adaptive webcrawler infrastructure
- PRIME uses `var/primed/` (new directory, lightweight seed files)
- L3 pattern fitness already tracks decision quality — RECALL queries it
- The Bulkhead bridge can mirror knowledge to the BulkheadLM control plane
