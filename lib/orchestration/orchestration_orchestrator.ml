open Lwt.Syntax

let log_decision decision =
  Runtime_logger.log
    Runtime_logger.Info
    (Fmt.str "Decision => %s" (Core_decision.to_string decision))

let rec execute_loop ~services ~config ~registry context payload =
  let route = Orchestration_decider.decide config context payload in
  log_decision route.decision;
  match route.decision with
  | Stop _ -> Lwt.return (payload, context)
  | Next agent ->
      let* item =
        Runtime_engine.run_agent ~services ~config ~registry agent context payload
      in
      let next_context = Core_context.record_outcome context item in
      execute_loop ~services ~config ~registry next_context item.payload
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
      execute_loop ~services ~config ~registry next_context merged_payload
  | Discuss ->
      let* discussion_payload, next_context =
        Orchestration_discussion.run ~services ~config context payload
      in
      execute_loop ~services ~config ~registry next_context discussion_payload

let loop ~services ~config ~registry context payload =
  let prepared_context =
    match services.Runtime_services.memory_runtime with
    | None ->
        Core_context.add_message
          context
          { Core_message.role = Core_message.User
          ; content = Core_payload.to_pretty_string payload
          }
    | Some runtime -> Memory_runtime.prepare_context runtime context payload
  in
  let* result_payload, result_context =
    execute_loop ~services ~config ~registry prepared_context payload
  in
  match services.Runtime_services.memory_runtime with
  | None -> Lwt.return (result_payload, result_context)
  | Some runtime ->
      let* persisted_context =
        Memory_runtime.persist_exchange
          runtime
          ~llm_client:services.llm_client
          ~llm_config:services.config.llm
          result_context
          ~input_payload:payload
          ~result_payload
      in
      Lwt.return (result_payload, persisted_context)
