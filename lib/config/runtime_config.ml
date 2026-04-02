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

type t = {
  engine : Engine.t;
  routing : Routing.t;
  demo : Demo.t;
}

let default_path = "config/runtime.json"

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

let load path =
  try
    let json = Yojson.Safe.from_file path in
    Ok
      {
        engine = json |> member "engine" |> parse_engine;
        routing = json |> member "routing" |> parse_routing;
        demo = json |> member "demo" |> parse_demo;
      }
  with
  | Sys_error message -> Error (Fmt.str "Cannot read %s: %s" path message)
  | Yojson.Json_error message ->
      Error (Fmt.str "Invalid JSON in %s: %s" path message)
  | Yojson.Safe.Util.Type_error (message, _) ->
      Error (Fmt.str "Invalid configuration shape in %s: %s" path message)
  | Invalid_argument message ->
      Error (Fmt.str "Invalid configuration value in %s: %s" path message)

