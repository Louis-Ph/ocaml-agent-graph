open Lwt.Syntax

(* L1-COORDINATION: Quorum-based coordination primitive.
   Runs a set of agents in parallel (via the existing parallel executor),
   collects their non-error results as confidence-weighted votes, and
   returns a Quorum_reached outcome when at least ⌈n/2⌉+1 agents respond
   successfully.

   The "winner" is the vote with the highest individual confidence score.
   This is a simplified plurality vote — Byzantine-fault-tolerant consensus
   (requiring 2f+1 agents to tolerate f failures) is a straightforward
   extension once the payload equality relation is defined.

   Agents that return Core_payload.Error are counted as abstentions;
   they contribute to the denominator for quorum calculation but not to
   the winner selection. *)

type vote = {
  agent      : Core_agent_name.t;
  payload    : Core_payload.t;
  confidence : float;
}

type outcome =
  | Quorum_reached of {
      winner       : Core_payload.t;
      votes        : vote list;
      total_weight : float;
    }
  | No_quorum of {
      votes    : vote list;
      required : int;
      received : int;
    }

let required_quorum agent_count = (agent_count / 2) + 1

let highest_confidence_vote = function
  | [] -> None
  | first :: rest ->
      Some
        (List.fold_left
           (fun best v -> if v.confidence > best.confidence then v else best)
           first
           rest)

let run
    ~(services : Runtime_services.t)
    ~(config : Runtime_config.t)
    ~(registry : Runtime_registry.t)
    ~(agents : Core_agent_name.t list)
    ~(context : Core_context.t)
    ~(payload : Core_payload.t)
  =
  let* items =
    Runtime_parallel_executor.run_all
      ~services
      ~config
      ~registry
      agents
      context
      payload
  in
  let votes =
    items
    |> List.filter_map (fun (item : Core_payload.batch_item) ->
           if Core_payload.is_error item.payload then None
           else
             Some
               {
                 agent      = item.agent;
                 payload    = item.payload;
                 confidence = item.metrics.confidence;
               })
  in
  let required = required_quorum (List.length agents) in
  let received = List.length votes in
  if received < required
  then Lwt.return (No_quorum { votes; required; received })
  else
    let total_weight =
      List.fold_left (fun acc v -> acc +. v.confidence) 0.0 votes
    in
    match highest_confidence_vote votes with
    | None -> Lwt.return (No_quorum { votes; required; received = 0 })
    | Some winner ->
        Lwt.return
          (Quorum_reached { winner = winner.payload; votes; total_weight })

let outcome_summary = function
  | Quorum_reached { votes; total_weight; winner } ->
      Printf.sprintf
        "quorum_reached votes=%d total_weight=%.2f winner=%s"
        (List.length votes)
        total_weight
        (Core_payload.summary winner)
  | No_quorum { votes; required; received } ->
      Printf.sprintf
        "no_quorum votes=%d required=%d received=%d"
        (List.length votes)
        required
        received
