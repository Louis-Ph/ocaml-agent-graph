open Lwt.Syntax

let log_decision decision =
  Runtime_logger.log
    Runtime_logger.Info
    (Fmt.str "Decision => %s" (Core_decision.to_string decision))

let rec loop ~services ~config ~registry context payload =
  let route = Orchestration_decider.decide config context payload in
  log_decision route.decision;
  match route.decision with
  | Stop _ -> Lwt.return (payload, context)
  | Next agent ->
      let* item =
        Runtime_engine.run_agent ~services ~config ~registry agent context payload
      in
      let next_context = Core_context.record_outcome context item in
      loop ~services ~config ~registry next_context item.payload
  | Parallel agents ->
      let* items =
        Runtime_parallel_executor.run_all
          ~services
          ~config
          ~registry
          agents
          context
          payload
      in
      let next_context =
        context
        |> Core_context.record_outcomes items
        |> Core_context.record_parallel_join agents
      in
      let merged_payload = Orchestration_aggregator.merge items in
      loop ~services ~config ~registry next_context merged_payload
