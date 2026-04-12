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
  module Bulkhead_client = Llm_bulkhead_client
end

module Client = struct
  module Config = Client_config
  module Runtime = Client_runtime
  module Local_ops = Client_local_ops
  module Human_constants = Client_human_constants
  module Ui = Client_ui
  module Assistant_docs = Client_assistant_docs
  module Assistant = Client_assistant
  module Messenger_spokesperson = Client_messenger_spokesperson
  module Machine = Client_machine
  module Http_server = Client_http_server
  module Terminal = Client_terminal
  module Starter = Client_starter
end

module Web_crawler = struct
  module Types = Web_crawler_types
  module Config = Web_crawler_config
  module Url = Web_crawler_url
  module Keywords = Web_crawler_keywords
  module Html = Web_crawler_html
  module Http = Web_crawler_http
  module Search = Web_crawler_search
  module Ranker = Web_crawler_ranker
  module Llm = Web_crawler_llm
  module Runner = Web_crawler_runner
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

module Memory = struct
  module Bulkhead_bridge = Memory_bulkhead_bridge
  module Store = Memory_store
  module Compressor = Memory_compressor
  module Runtime = Memory_runtime
end

module Orchestration = struct
  module Graph = Orchestration_graph
  module Decider = Orchestration_decider
  module Aggregator = Orchestration_aggregator
  module Discussion = Orchestration_discussion
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
