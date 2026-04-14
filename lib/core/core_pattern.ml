(* L3-EMERGENCE: Pattern stability classification and fitness measurement.
   Patterns are named coordination strategies.  Their stability class
   controls how they may evolve:

     Frozen   — breaking change requires a swarm fork (L0 contracts)
     Stable   — change requires supermajority approval (L1 coordination)
     Fluid    — opt-in adoption gated on fitness proof (L2 composition)
     Volatile — continuous experimentation permitted (L3 emergence sandbox)

   Fitness is a single dimensionless score derived from success rate,
   mean confidence, and mean latency.  Higher is better.  The formula is:

     fitness = success_rate × avg_confidence / (avg_latency_s + 1.0)

   The +1.0 denominator prevents division-by-zero for zero-latency mocks
   and applies gentle latency pressure even for sub-millisecond operations. *)

type stability =
  | Frozen
  | Stable
  | Fluid
  | Volatile

type metrics = {
  invocation_count : int;
  success_count    : int;
  total_latency_ms : int;
  total_confidence : float;
}

let zero_metrics : metrics =
  { invocation_count = 0; success_count = 0; total_latency_ms = 0; total_confidence = 0.0 }

type t = {
  id          : string;
  stability   : stability;
  description : string;
  metrics     : metrics;
}

let fitness (m : metrics) =
  if m.invocation_count = 0 then 0.0
  else
    let n             = float_of_int m.invocation_count in
    let success_rate  = float_of_int m.success_count /. n in
    let avg_conf      = m.total_confidence /. n in
    let avg_latency_s = float_of_int m.total_latency_ms /. (n *. 1000.0) in
    success_rate *. avg_conf /. (avg_latency_s +. 1.0)

let record_outcome (t : t) ~success ~latency_ms ~confidence =
  {
    t with
    metrics =
      {
        invocation_count = t.metrics.invocation_count + 1;
        success_count    = t.metrics.success_count + (if success then 1 else 0);
        total_latency_ms = t.metrics.total_latency_ms + latency_ms;
        total_confidence = t.metrics.total_confidence +. confidence;
      };
  }

(* A stability class may accept changes proposed at or above its own level.
   Frozen accepts nothing; Volatile accepts everything. *)
let can_mutate ~current ~proposed =
  match current with
  | Frozen   -> false
  | Stable   -> (match proposed with Stable | Fluid | Volatile -> true | Frozen -> false)
  | Fluid    -> (match proposed with Fluid | Volatile -> true | _ -> false)
  | Volatile -> true

let stability_to_string = function
  | Frozen   -> "frozen"
  | Stable   -> "stable"
  | Fluid    -> "fluid"
  | Volatile -> "volatile"

let make ~id ~stability ~description =
  { id; stability; description; metrics = zero_metrics }
