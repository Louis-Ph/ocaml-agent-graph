open Lwt.Syntax

(* L2-COMPOSITION: Composable agent pipeline — the >> (sequence) operator.
   A pipeline is an ordered list of steps.  Each step names an agent and
   carries an optional guard predicate.  When a step's guard returns false
   the step is skipped and the payload is forwarded unchanged.

   Execution halts immediately if an agent produces Core_payload.Error;
   the error payload and the context up to that point are returned so
   callers can decide how to handle partial progress.

   Usage:
     let open Orchestration_pipeline in
     let p =
       empty
       |> step Planner
       |> step ~guard:(Fun.negate Core_payload.is_error) Validator
     in
     run ~services ~config ~registry ~context ~payload p

   The guard is evaluated against the payload *entering* the step, not the
   one produced by the previous step, so callers compose guards on a known
   type boundary. *)

type step = {
  agent : Core_agent_name.t;
  guard : Core_payload.t -> bool;
}

type t = step list

let empty : t = []

let always _ = true

(* Append a step to the pipeline. *)
let ( >> ) (pipeline : t) (s : step) : t = pipeline @ [ s ]

(* Pipeline builder — returns a t -> t function so it composes with |>.
   Usage: empty |> step Planner |> step ~guard:... Validator *)
let step ?(guard = always) agent pipeline = pipeline @ [ { agent; guard } ]

let run
    ~(services : Runtime_services.t)
    ~(config : Runtime_config.t)
    ~(registry : Runtime_registry.t)
    ~(context : Core_context.t)
    ~(payload : Core_payload.t)
    (pipeline : t)
  =
  let rec loop context payload = function
    | [] -> Lwt.return (payload, context)
    | s :: rest ->
        if not (s.guard payload)
        then loop context payload rest
        else
          let* item =
            Runtime_engine.run_agent
              ~services
              ~config
              ~registry
              s.agent
              context
              payload
          in
          let next_context = Core_context.record_outcome context item in
          if Core_payload.is_error item.payload
          then Lwt.return (item.payload, next_context)
          else loop next_context item.payload rest
  in
  loop context payload pipeline
