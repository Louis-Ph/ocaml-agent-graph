# Swarm Layers — L0 through L3

This document describes the four typed coordination layers introduced in
`feat(swarm): implement L0-L3 typed agentic swarm layers`.  Each layer is a
self-contained OCaml module under `lib/`; all are exposed through
`Agent_graph` and accessible in tests via `open Agent_graph`.

---

## Layer map

```
lib/core/
  core_envelope.ml          L0   — typed message envelope with provenance
  core_capability.ml        L0   — permission lattice for agent access control
  core_audit.ml             L0.5 — append-only, hash-chained audit log
  core_pattern.ml           L3   — pattern stability classification + fitness

lib/orchestration/
  orchestration_consensus.ml  L1 — quorum-based parallel coordination
  orchestration_pipeline.ml   L2 — composable agent sequence with guards
```

Public module paths after `open Agent_graph`:

| Source module              | Public path                     |
|----------------------------|---------------------------------|
| `Core_envelope`            | `Core.Envelope`                 |
| `Core_capability`          | `Core.Capability`               |
| `Core_audit`               | `Core.Audit`                    |
| `Core_pattern`             | `Core.Pattern`                  |
| `Orchestration_consensus`  | `Orchestration.Consensus`       |
| `Orchestration_pipeline`   | `Orchestration.Pipeline`        |

---

## L0 — Protocol

### `Core.Envelope` — typed message envelope

Every payload exchanged between agents can be wrapped in an envelope that
carries three provenance fields:

| Field            | Purpose                                            |
|------------------|----------------------------------------------------|
| `id`             | Unique envelope identifier (timestamp + random hex)|
| `correlation_id` | Logical request trace — shared across all hops     |
| `causation_id`   | `id` of the envelope that triggered this one        |
| `schema_version` | `{ major; minor }` — guards against shape changes  |

**Creating a root envelope**

```ocaml
open Agent_graph

let env =
  Core.Envelope.make
    ~correlation_id:"req-2026-001"
    (Core.Payload.Text "analyze this codebase")
```

**Deriving a child envelope** (inherits `correlation_id`, sets `causation_id`)

```ocaml
let child = Core.Envelope.child_of env (Core.Payload.Plan [ "step 1"; "step 2" ])
(* child.correlation_id = "req-2026-001"   *)
(* child.causation_id   = Some env.id      *)
```

**Custom schema version**

```ocaml
let env_v2 =
  Core.Envelope.make
    ~schema_version:{ Core.Envelope.major = 2; minor = 0 }
    ~correlation_id:"req-002"
    payload
```

---

### `Core.Capability` — permission lattice

Permissions form a total order: `Observe ⊑ Speak ⊑ Coordinate ⊑ Audit_write`.
Grant an agent the **minimum** capability its role requires.

| Level         | Allowed operations                          |
|---------------|---------------------------------------------|
| `Observe`     | Read context and payload; no output         |
| `Speak`       | Produce a turn or output message            |
| `Coordinate`  | Route or delegate work to other agents      |
| `Audit_write` | Append entries to the audit log             |

**Granting a token**

```ocaml
let tok =
  Core.Capability.grant
    ~agent:Core.Agent_name.Planner
    Core.Capability.Coordinate
```

**Granting a time-bounded token** (expires in 5 minutes)

```ocaml
let tok =
  Core.Capability.grant
    ~agent:Core.Agent_name.Summarizer
    ~expires_in_seconds:300.0
    Core.Capability.Speak
```

**Checking a permission before dispatch**

```ocaml
if Core.Capability.permits tok Core.Capability.Speak
   && Core.Capability.is_valid tok
then dispatch_agent ...
else Error "insufficient capability"
```

A token at level N automatically covers all levels below N — a `Coordinate`
token permits `Speak` and `Observe` without additional grants.

---

## L0.5 — Audit

### `Core.Audit` — hash-chained audit log

An audit chain is an immutable list of entries.  Each entry hashes
`previous_hash | label | detail | timestamp` so that mutating any past entry
breaks every subsequent `self_hash`.  Chains are stored in prepend order
(most recent at the head); `verify_chain` reverses once internally.

**Building a chain**

```ocaml
let chain =
  Core.Audit.empty
  |> Core.Audit.append ~label:"discussion.started" ~detail:"rounds=10"
  |> Core.Audit.append ~label:"discussion.turn"    ~detail:"speaker=architect"
  |> Core.Audit.append ~label:"discussion.turn"    ~detail:"speaker=critic"
  |> Core.Audit.append ~label:"discussion.ended"   ~detail:"turns=6"
```

**Verifying integrity**

```ocaml
assert (Core.Audit.verify_chain chain)
(* Returns false if any entry was tampered with after the fact *)
```

**Reading entries** (chronological order)

```ocaml
List.rev chain
|> List.iter (fun entry ->
     Printf.printf "[%d] %s — %s\n"
       entry.Core.Audit.sequence
       entry.label
       entry.detail)
```

**Key invariants**
- `verify_chain Core.Audit.empty` always returns `true`.
- Changing any `detail`, `label`, or `timestamp` field invalidates all
  entries that follow it.
- The genesis hash (`String.make 32 '0'`) anchors the chain; there is no
  trusted third party.

---

## L1 — Coordination

### `Orchestration.Consensus` — quorum-based coordination

Runs a list of agents in parallel and returns a `Quorum_reached` outcome when
at least ⌈n/2⌉+1 agents return non-error payloads.  Agents that produce
`Core.Payload.Error` are counted as abstentions.

**Outcome type**

```ocaml
type outcome =
  | Quorum_reached of {
      winner       : Core.Payload.t;  (* highest-confidence vote *)
      votes        : vote list;
      total_weight : float;
    }
  | No_quorum of {
      votes    : vote list;
      required : int;
      received : int;
    }
```

**Running a consensus round**

```ocaml
open Lwt.Syntax

let* outcome =
  Orchestration.Consensus.run
    ~services
    ~config
    ~registry
    ~agents:Core.Agent_name.[ Planner; Summarizer; Validator ]
    ~context
    ~payload
in
match outcome with
| Orchestration.Consensus.Quorum_reached { winner; votes; _ } ->
    Printf.printf "Quorum reached with %d votes\n" (List.length votes);
    Lwt.return winner
| Orchestration.Consensus.No_quorum { required; received; _ } ->
    Printf.printf "No quorum: needed %d, got %d\n" required received;
    Lwt.return (Core.Payload.Error "no consensus")
```

**Quorum threshold**

| Agents | Required votes |
|--------|----------------|
| 1      | 1              |
| 2      | 2              |
| 3      | 2              |
| 4      | 3              |
| 5      | 3              |

The winner is the vote with the highest `confidence` score.  When two votes
tie on confidence the first one (by agent list order) is selected.

---

## L2 — Composition

### `Orchestration.Pipeline` — composable agent sequence

A pipeline is an ordered list of steps.  Each step names an agent and carries
an optional guard predicate evaluated against the **incoming** payload.  When
a guard returns `false` the step is skipped and the payload is forwarded
unchanged.  Execution halts immediately if a step produces
`Core.Payload.Error`.

**Building a pipeline**

```ocaml
open Orchestration.Pipeline

let pipeline =
  empty
  |> step Planner
  |> step ~guard:(Fun.negate Core.Payload.is_error) Validator
  |> step Summarizer
```

**Running a pipeline**

```ocaml
open Lwt.Syntax

let* result_payload, result_context =
  Orchestration.Pipeline.run
    ~services
    ~config
    ~registry
    ~context
    ~payload:(Core.Payload.Text "design a typed swarm")
    pipeline
in
if Core.Payload.is_error result_payload
then Printf.printf "Pipeline halted early\n"
else Printf.printf "Pipeline completed: %s\n"
       (Core.Payload.summary result_payload)
```

**Combining with Consensus**

Consensus and Pipeline compose naturally — run a consensus round to pick the
best plan, then feed the winner through a validation pipeline:

```ocaml
let* outcome =
  Orchestration.Consensus.run ~services ~config ~registry
    ~agents:[ Planner; Summarizer ] ~context ~payload
in
let plan =
  match outcome with
  | Quorum_reached { winner; _ } -> winner
  | No_quorum _ -> Core.Payload.Error "no plan agreed"
in
let validation_pipeline =
  Orchestration.Pipeline.(empty |> step Validator)
in
let* final, _ctx =
  Orchestration.Pipeline.run
    ~services ~config ~registry ~context ~payload:plan
    validation_pipeline
in
Lwt.return final
```

---

## L3 — Emergence

### `Core.Pattern` — stability classification and fitness

Patterns are named coordination strategies.  Each carries a `stability` class
that governs how it may evolve and a `metrics` record accumulated over live
invocations.

**Stability classes**

| Class      | Mutation policy                                  |
|------------|--------------------------------------------------|
| `Frozen`   | No mutation permitted — requires a swarm fork    |
| `Stable`   | Mutation requires supermajority approval         |
| `Fluid`    | Opt-in adoption gated on fitness proof           |
| `Volatile` | Continuous experimentation permitted             |

**Creating and evolving a pattern**

```ocaml
let p =
  Core.Pattern.make
    ~id:"discussion-round-robin"
    ~stability:Core.Pattern.Fluid
    ~description:"rotate speakers round-robin, summarizer finalizes"

(* Record an outcome after each execution *)
let p =
  Core.Pattern.record_outcome p
    ~success:true
    ~latency_ms:1240
    ~confidence:0.91
```

**Computing fitness**

```ocaml
let score = Core.Pattern.fitness p.Core.Pattern.metrics
(* fitness = success_rate × avg_confidence / (avg_latency_s + 1.0) *)
(* Range: 0.0 (worst) to ~1.0 (instant, confident, always succeeds)  *)
```

**Checking mutation eligibility**

```ocaml
let ok =
  Core.Pattern.can_mutate
    ~current:Core.Pattern.Fluid
    ~proposed:Core.Pattern.Volatile
(* true — Fluid accepts Volatile proposals *)

let ok =
  Core.Pattern.can_mutate
    ~current:Core.Pattern.Frozen
    ~proposed:Core.Pattern.Volatile
(* false — Frozen accepts nothing *)
```

---

## Test coverage

| Test file              | Suites                          | Cases |
|------------------------|---------------------------------|-------|
| `test/test_protocol.ml`    | L0-envelope, L0-capability, L0.5-audit, L3-pattern | 27 |
| `test/test_coordination.ml` | L1-consensus, L2-pipeline      | 8  |

Run with:

```sh
dune exec test/test_protocol.exe
dune exec test/test_coordination.exe
```
