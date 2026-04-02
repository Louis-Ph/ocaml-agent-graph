open Lwt.Infix

module Core = struct
  module Agent_name = Core_agent_name
  module Message = Core_message
  module Payload = Core_payload
  module Context = Core_context
  module Decision = Core_decision
end

module Config = struct
  module Runtime = Runtime_config
end

module Llm = struct
  module Prompt = Llm_prompt
  module Aegis_client = Llm_aegis_client
end

module Agents = struct
  module Intf = Agent_intf
  module Planner = Planner_agent
  module Summarizer = Summarizer_agent
  module Validator = Validator_agent
  module Defaults = Default_agents
end

module Runtime = struct
  module Logger = Runtime_logger
  module Registry = Runtime_registry
  module Retry_policy = Runtime_retry_policy
  module Engine = Runtime_engine
  module Parallel = Runtime_parallel_executor
  module Services = Runtime_services
end

module Orchestration = struct
  module Graph = Orchestration_graph
  module Decider = Orchestration_decider
  module Aggregator = Orchestration_aggregator
  module Orchestrator = Orchestration_orchestrator
end

let run ?(metadata = []) ~config ~task_id ~input () =
  match Runtime_services.create config with
  | Error _ as error -> Lwt.return error
  | Ok services ->
      let registry = Default_agents.make_registry () in
      let context = Core_context.empty ~task_id ~metadata in
      Orchestration_orchestrator.loop
        ~services
        ~config
        ~registry
        context
        (Core_payload.Text input)
      >|= fun result -> Ok result
