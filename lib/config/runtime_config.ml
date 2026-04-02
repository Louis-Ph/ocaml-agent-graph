open Yojson.Safe.Util

module Engine = struct
  type t = {
    timeout_seconds : float;
    retry_attempts : int;
    retry_backoff_seconds : float;
    max_steps : int;
  }
end

module Routing = struct
  type t = {
    long_text_threshold : int;
    short_text_agent : Core_agent_name.t;
    planner_agent : Core_agent_name.t;
    parallel_agents : Core_agent_name.t list;
  }
end

module Demo = struct
  type t = {
    task_id : string;
    input : string;
  }
end

module Llm = struct
  module Agent_profile = struct
    type t = {
      model : string;
      system_prompt : string;
      max_tokens : int option;
      confidence : float;
    }
  end

  type t = {
    gateway_config_path : string;
    authorization_token_plaintext : string option;
    authorization_token_env : string option;
    planner : Agent_profile.t;
    summarizer : Agent_profile.t;
    validator : Agent_profile.t;
  }

  let profile_for_agent t = function
    | Core_agent_name.Planner -> t.planner
    | Summarizer -> t.summarizer
    | Validator -> t.validator
end

type t = {
  engine : Engine.t;
  routing : Routing.t;
  demo : Demo.t;
  llm : Llm.t;
}

let default_path = "config/runtime.json"

let member_string_option name json =
  match json |> member name with
  | `String value -> Some value
  | _ -> None

let member_int_option name json =
  match json |> member name with
  | `Int value -> Some value
  | `Intlit value -> Some (int_of_string value)
  | _ -> None

let resolve_relative_path ~base_dir path =
  if Filename.is_relative path then Filename.concat base_dir path else path

let agent_of_string value =
  match Core_agent_name.of_string value with
  | Ok agent -> agent
  | Error message -> invalid_arg message

let parse_engine json =
  {
    Engine.timeout_seconds = json |> member "timeout_seconds" |> to_float;
    retry_attempts = json |> member "retry_attempts" |> to_int;
    retry_backoff_seconds =
      json |> member "retry_backoff_seconds" |> to_float;
    max_steps = json |> member "max_steps" |> to_int;
  }

let parse_routing json =
  {
    Routing.long_text_threshold =
      json |> member "long_text_threshold" |> to_int;
    short_text_agent =
      json |> member "short_text_agent" |> to_string |> agent_of_string;
    planner_agent =
      json |> member "planner_agent" |> to_string |> agent_of_string;
    parallel_agents =
      json
      |> member "parallel_agents"
      |> to_list
      |> List.map to_string
      |> List.map agent_of_string;
  }

let parse_demo json =
  {
    Demo.task_id = json |> member "task_id" |> to_string;
    input = json |> member "input" |> to_string;
  }

let parse_agent_profile json =
  {
    Llm.Agent_profile.model = json |> member "model" |> to_string;
    system_prompt = json |> member "system_prompt" |> to_string;
    max_tokens = member_int_option "max_tokens" json;
    confidence = json |> member "confidence" |> to_float;
  }

let parse_llm ~base_dir json =
  {
    Llm.gateway_config_path =
      json
      |> member "gateway_config_path"
      |> to_string
      |> resolve_relative_path ~base_dir;
    authorization_token_plaintext =
      member_string_option "authorization_token_plaintext" json;
    authorization_token_env = member_string_option "authorization_token_env" json;
    planner = json |> member "planner" |> parse_agent_profile;
    summarizer = json |> member "summarizer" |> parse_agent_profile;
    validator = json |> member "validator" |> parse_agent_profile;
  }

let load path =
  try
    let json = Yojson.Safe.from_file path in
    let base_dir = Filename.dirname path in
    Ok
      {
        engine = json |> member "engine" |> parse_engine;
        routing = json |> member "routing" |> parse_routing;
        demo = json |> member "demo" |> parse_demo;
        llm = json |> member "llm" |> parse_llm ~base_dir;
      }
  with
  | Sys_error message -> Error (Fmt.str "Cannot read %s: %s" path message)
  | Yojson.Json_error message ->
      Error (Fmt.str "Invalid JSON in %s: %s" path message)
  | Yojson.Safe.Util.Type_error (message, _) ->
      Error (Fmt.str "Invalid configuration shape in %s: %s" path message)
  | Invalid_argument message ->
      Error (Fmt.str "Invalid configuration value in %s: %s" path message)
